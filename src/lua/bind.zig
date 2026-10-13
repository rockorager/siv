//! The binding, generated at compile time from the API schema (D3, D23):
//! one Lua function per schema function, conversions between Lua values
//! and every schema type, and C trampolines that run Lua callbacks. The
//! rules are in mapping.zig; this file only applies them.
//!
//! Lua errors are raised only while no siv call is on the stack: a
//! wrapper converts every argument before calling siv and raises after
//! siv returns. Callbacks run under lua_pcall, so an error never unwinds
//! through siv's frames.

const std = @import("std");
const lua = @import("c.zig");
const c = lua.c;
const siv = @import("siv");
const m = @import("mapping.zig");

const schema = m.schema;
const spec = m.spec;
const L_ = lua.State;

comptime {
    @setEvalBranchQuota(1_000_000);
    if (m.validate(spec)) |p| @compileError("src/lua/mapping.zig: " ++ p);
}

// Names and types.

fn zigName(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [128]u8 = undefined;
        const n = schema.zigTypeName(&buf, name);
        const out: [n.len]u8 = n[0..n.len].*;
        return &out;
    }
}

fn ZigType(comptime name: []const u8) type {
    return @field(siv, zigName(name));
}

/// A schema declaration, comptime-known wherever it is used.
fn Info(comptime name: []const u8) type {
    return struct {
        const d: schema.Decl = blk: {
            @setEvalBranchQuota(1_000_000);
            break :blk spec.get(name);
        };
    };
}

pub const handle_names: []const []const u8 = blk: {
    var names: []const []const u8 = &.{};
    for (spec.decls) |d| if (d == .handle) {
        names = names ++ .{d.handle.name};
    };
    break :blk names;
};

pub fn handleIndex(comptime name: []const u8) u16 {
    @setEvalBranchQuota(1_000_000);
    for (handle_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    @compileError("not a handle: " ++ name);
}

fn concat(comptime a: []const u8, comptime b: []const u8) []const u8 {
    return a ++ b;
}

// State.

pub const max_apps = 16;

/// Per Lua state, in a userdata in the registry ("siv.state").
pub const State = struct {
    main: *L_,
    /// The thread that made the siv call now on the stack; callbacks run
    /// on it. The main thread when no call is.
    L: *L_,
    meta: [handle_names.len]c_int = @splat(lua.noref),
    methods: [handle_names.len]c_int = @splat(lua.noref),
    cache: c_int = lua.noref,
    err_mt: c_int = lua.noref,
    traceback: c_int = lua.noref,
    /// The application's error handler for callbacks (siv.set_error_handler).
    handler: c_int = lua.noref,
    /// The first error a callback raised with no handler set, raised again
    /// by the next binding call that returns to Lua.
    pending: c_int = lua.noref,
    /// Callbacks now running.
    depth: u32 = 0,
    /// The application siv_app_run is running, quit when a callback fails.
    running: u64 = 0,
    apps: [max_apps]u64 = @splat(0),
    /// Hot reload (hot.zig), if started.
    watcher: ?*anyopaque = null,
    watcher_stop: ?*const fn (*anyopaque) void = null,

    pub fn get(L: *L_) *State {
        return @ptrCast(@alignCast(c.lua_touserdata(L, lua.upvalue(1))));
    }

    fn addApp(st: *State, app: u64) void {
        for (&st.apps) |*a| if (a.* == 0) {
            a.* = app;
            return;
        };
    }

    fn removeApp(st: *State, app: u64) void {
        for (&st.apps) |*a| if (a.* == app) {
            a.* = 0;
        };
    }

    pub fn pushTraceback(st: *State, L: *L_) void {
        _ = c.lua_rawgeti(L, lua.registry, st.traceback);
    }

    /// Reports the error on top of L's stack from a callback: to the
    /// handler if there is one, else kept for the next call to raise
    /// (quitting siv_app_run). Pops it. Never raises.
    pub fn report(st: *State, L: *L_) void {
        if (c.lua_checkstack(L, 4) == 0) {
            lua.pop(L, 1);
            return;
        }
        c.lua_pushlightuserdata(L, st);
        lua.pushcfunction(L, reportProtected);
        lua.insert(L, -3);
        if (lua.pcall(L, 2, 0, 0) != lua.ok) {
            const msg = lua.toString(L, -1) orelse "(error object is not a string)";
            std.debug.print("siv-lua: error while reporting an error: {s}\n", .{msg});
            lua.pop(L, 1);
        }
    }

    fn reportProtected(Lq: ?*L_) callconv(.c) c_int {
        const L = Lq.?;
        const st: *State = @ptrCast(@alignCast(c.lua_touserdata(L, 2)));
        if (st.handler != lua.noref) {
            _ = c.lua_rawgeti(L, lua.registry, st.handler);
            c.lua_pushvalue(L, 1);
            lua.call(L, 1, 0);
            return 0;
        }
        if (st.pending == lua.noref) {
            c.lua_pushvalue(L, 1);
            st.pending = c.luaL_ref(L, lua.registry);
            if (st.running != 0) _ = siv.c.siv_app_quit(@enumFromInt(st.running));
            return 0;
        }
        // A second error before the first was raised.
        const msg = c.luaL_tolstring(L, 1, null);
        std.debug.print("siv-lua: another error in a callback: {s}\n", .{std.mem.span(msg)});
        return 0;
    }

    /// Raises the pending callback error, if any, when no callback is
    /// running.
    fn raisePending(st: *State, L: *L_) void {
        if (st.pending == lua.noref or st.depth != 0) return;
        _ = c.lua_rawgeti(L, lua.registry, st.pending);
        c.luaL_unref(L, lua.registry, st.pending);
        st.pending = lua.noref;
        _ = c.lua_error(L);
    }
};

// Handles: userdata of one metatable per type, one userdata per handle
// while it is referenced (a weak table maps handles to them), so they
// compare equal and work as table keys.

const handle_magic: u32 = 0x5156_4c41;

pub const Handle = extern struct {
    magic: u32 = handle_magic,
    type: u16,
    flags: Flags = .{},
    value: u64,

    pub const Flags = packed struct(u16) {
        /// Collecting the userdata destroys the object.
        owned: bool = false,
        /// Destroyed through the binding; the handle is not passed again.
        destroyed: bool = false,
        _: u14 = 0,
    };
};

pub fn toHandleUd(L: *L_, idx: c_int) ?*Handle {
    if (c.lua_type(L, idx) != lua.tuserdata) return null;
    if (c.lua_rawlen(L, idx) != @sizeOf(Handle)) return null;
    const h: *Handle = @ptrCast(@alignCast(c.lua_touserdata(L, idx)));
    if (h.magic != handle_magic) return null;
    return h;
}

pub fn pushHandle(st: *State, L: *L_, type_index: u16, value: u64, owned: bool) void {
    if (value == 0) return c.lua_pushnil(L);
    _ = c.lua_rawgeti(L, lua.registry, st.cache);
    if (c.lua_rawgeti(L, -1, @bitCast(value)) == lua.tuserdata) {
        if (owned) toHandleUd(L, -1).?.flags.owned = true;
        lua.remove(L, -2);
        return;
    }
    lua.pop(L, 1);
    const h: *Handle = @ptrCast(@alignCast(c.lua_newuserdatauv(L, @sizeOf(Handle), 0)));
    h.* = .{ .type = type_index, .value = value, .flags = .{ .owned = owned } };
    _ = c.lua_rawgeti(L, lua.registry, st.meta[type_index]);
    _ = c.lua_setmetatable(L, -2);
    c.lua_pushvalue(L, -1);
    c.lua_rawseti(L, -3, @bitCast(value));
    lua.remove(L, -2);
}

/// Marks every cached handle of the root that `app` names as destroyed:
/// destroying an application invalidates every handle it issued (D2).
fn sweepRoot(st: *State, L: *L_, app: u64) void {
    const root = (app >> 46) & 0x3ff;
    _ = c.lua_rawgeti(L, lua.registry, st.cache);
    c.lua_pushnil(L);
    while (c.lua_next(L, -2) != 0) {
        if (toHandleUd(L, -1)) |h| {
            if ((h.value >> 46) & 0x3ff == root) h.flags.destroyed = true;
        }
        lua.pop(L, 1);
    }
    lua.pop(L, 1);
    st.removeApp(app);
}

// Errors: tables with the result code, raised as Lua errors.

fn resultCode(comptime r: i32) []const u8 {
    @setEvalBranchQuota(1_000_000);
    for (Info(spec.result).d.@"enum".values) |v| if (v.value == r) {
        return if (std.mem.startsWith(u8, v.name, "error_")) v.name["error_".len..] else v.name;
    };
    unreachable;
}

const result_values = Info(spec.result).d.@"enum".values;

/// Pushes an error object: { code = "busy", result = -6, func =
/// "siv_txn_begin", message = "where: siv_txn_begin: SIV_ERROR_BUSY" }.
pub fn pushError(st: *State, L: *L_, result: i32, func: []const u8, level: c_int) void {
    c.lua_createtable(L, 0, 5);
    var code: []const u8 = "unknown";
    inline for (result_values) |v| if (v.value == result) {
        code = comptime resultCode(v.value);
    };
    lua.pushString(L, code);
    c.lua_setfield(L, -2, "code");
    c.lua_pushinteger(L, result);
    c.lua_setfield(L, -2, "result");
    lua.pushString(L, func);
    c.lua_setfield(L, -2, "func");
    if (level > 0) c.luaL_where(L, level) else lua.pushString(L, "");
    lua.pushString(L, func);
    lua.pushString(L, ": ");
    _ = c.lua_pushstring(L, siv.c.siv_result_name(@enumFromInt(result)));
    c.lua_concat(L, 4);
    c.lua_setfield(L, -2, "message");
    _ = c.lua_rawgeti(L, lua.registry, st.err_mt);
    _ = c.lua_setmetatable(L, -2);
}

fn raiseResult(st: *State, L: *L_, result: i32, func: []const u8) noreturn {
    pushError(st, L, result, func, 1);
    _ = c.lua_error(L);
    unreachable;
}

// Per-call conversion context.

const Where = struct {
    arg: c_int = 0,
    st: []const u8 = "",
    field: []const u8 = "",
};

const Box = struct {
    st: *State,
    ref: c_int = lua.noref,
};

const Ctx = struct {
    st: *State,
    L: *L_,
    func: []const u8,
    /// A stack slot with nil or a table anchoring buffers and boxes made
    /// for this call until it returns.
    anchor_slot: c_int,
    anchors: c_int = 0,
    boxes: [4]struct { box: *Box, anchor: c_int } = undefined,
    nboxes: usize = 0,

    fn fail(ctx: *Ctx, w: Where, comptime fmt: []const u8, args: anytype) noreturn {
        if (w.arg > 0) lua.argError(ctx.L, w.arg, fmt, args);
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "invalid value";
        if (w.st.len > 0) lua.raise(ctx.L, "{s}.{s}: {s}", .{ w.st, w.field, msg });
        lua.raise(ctx.L, "{s}: {s}", .{ ctx.func, msg });
    }

    fn typeError(ctx: *Ctx, w: Where, idx: c_int, expected: []const u8) noreturn {
        ctx.fail(w, "{s} expected, got {s}", .{ expected, lua.typeName(ctx.L, idx) });
    }

    /// Anchors the value on top of the stack and pops it; returns its
    /// key in the anchor table.
    fn anchor(ctx: *Ctx) c_int {
        const L = ctx.L;
        if (c.lua_type(L, ctx.anchor_slot) != lua.ttable) {
            lua.newtable(L);
            lua.replace(L, ctx.anchor_slot);
        }
        ctx.anchors += 1;
        c.lua_rawseti(L, ctx.anchor_slot, ctx.anchors);
        return ctx.anchors;
    }

    /// Zeroed memory that lives until the call returns.
    fn alloc(ctx: *Ctx, comptime T: type, n: usize) []T {
        if (n == 0) return &.{};
        const p = c.lua_newuserdatauv(ctx.L, n * @sizeOf(T), 0);
        _ = ctx.anchor();
        const s: [*]T = @ptrCast(@alignCast(p));
        @memset(std.mem.sliceAsBytes(s[0..n]), 0);
        return s[0..n];
    }

    /// A box holding `slots` Lua functions for one set of callbacks.
    fn newBox(ctx: *Ctx, slots: c_int) struct { *Box, c_int } {
        const p = c.lua_newuserdatauv(ctx.L, @sizeOf(Box), slots);
        const box: *Box = @ptrCast(@alignCast(p));
        box.* = .{ .st = ctx.st };
        const key = ctx.anchor();
        ctx.boxes[ctx.nboxes] = .{ .box = box, .anchor = key };
        ctx.nboxes += 1;
        return .{ box, key };
    }

    /// Sets slot `slot` of the box anchored under `key` to the value on
    /// top of the stack, and pops it.
    fn setBoxSlot(ctx: *Ctx, key: c_int, slot: c_int) void {
        _ = c.lua_rawgeti(ctx.L, ctx.anchor_slot, key);
        lua.insert(ctx.L, -2);
        _ = c.lua_setiuservalue(ctx.L, -2, slot);
        lua.pop(ctx.L, 1);
    }

    /// Before the call: the registry keeps each box until siv releases it.
    fn commitBoxes(ctx: *Ctx) void {
        for (ctx.boxes[0..ctx.nboxes]) |b| {
            _ = c.lua_rawgeti(ctx.L, ctx.anchor_slot, b.anchor);
            b.box.ref = c.luaL_ref(ctx.L, lua.registry);
        }
    }
};

// Lua to C.

fn readInt(ctx: *Ctx, idx: c_int, comptime T: type, w: Where) T {
    const L = ctx.L;
    var isnum: c_int = 0;
    const v = c.lua_tointegerx(L, idx, &isnum);
    if (isnum == 0) {
        if (c.lua_type(L, idx) == lua.tnumber) ctx.fail(w, "number has no integer representation", .{});
        ctx.typeError(w, idx, "integer");
    }
    if (T == u64) return @bitCast(v);
    return std.math.cast(T, v) orelse ctx.fail(w, "{d} is out of range", .{v});
}

fn readFloat(ctx: *Ctx, idx: c_int, comptime T: type, w: Where) T {
    var isnum: c_int = 0;
    const v = c.lua_tonumberx(ctx.L, idx, &isnum);
    if (isnum == 0) ctx.typeError(w, idx, "number");
    return @floatCast(v);
}

fn enumMap(comptime name: []const u8) type {
    return struct {
        const e = Info(name).d.@"enum";
        const map = blk: {
            var kvs: [e.values.len]struct { []const u8, i32 } = undefined;
            for (e.values, 0..) |v, i| kvs[i] = .{ v.name, v.value };
            break :blk std.StaticStringMap(i32).initComptime(kvs);
        };
    };
}

fn readEnum(ctx: *Ctx, idx: c_int, comptime name: []const u8, w: Where) ZigType(name) {
    const L = ctx.L;
    switch (c.lua_type(L, idx)) {
        lua.tnil, lua.tnone => return @enumFromInt(0),
        lua.tstring => {
            const s = lua.toString(L, idx).?;
            const v = enumMap(name).map.get(s) orelse ctx.fail(w, "unknown {s} '{s}'", .{ name, s });
            return @enumFromInt(v);
        },
        lua.tnumber => {
            const v = readInt(ctx, idx, i32, w);
            // Closed enums take only the values they name (D2).
            if (comptime !Info(name).d.@"enum".open) {
                if (for (Info(name).d.@"enum".values) |ev| {
                    if (ev.value == v) break false;
                } else true) ctx.fail(w, "unknown {s} {d}", .{ name, v });
            }
            return @enumFromInt(v);
        },
        else => ctx.typeError(w, idx, "string"),
    }
}

fn flagsMap(comptime name: []const u8) type {
    return struct {
        const f = Info(name).d.flags;
        const map = blk: {
            var kvs: [f.bits.len]struct { []const u8, u5 } = undefined;
            for (f.bits, 0..) |b, i| kvs[i] = .{ b.name, b.bit };
            break :blk std.StaticStringMap(u5).initComptime(kvs);
        };
    };
}

fn flagBit(ctx: *Ctx, idx: c_int, comptime name: []const u8, w: Where) u32 {
    const s = lua.toString(ctx.L, idx) orelse ctx.typeError(w, idx, "string");
    const bit = flagsMap(name).map.get(s) orelse ctx.fail(w, "unknown {s} flag '{s}'", .{ name, s });
    return @as(u32, 1) << bit;
}

/// Flags are an integer, one name, a list of names, or a set of names.
fn readFlags(ctx: *Ctx, idx_: c_int, comptime name: []const u8, w: Where) ZigType(name) {
    const L = ctx.L;
    const idx = c.lua_absindex(L, idx_);
    var bits: u32 = 0;
    switch (c.lua_type(L, idx)) {
        lua.tnil, lua.tnone => {},
        lua.tnumber => bits = readInt(ctx, idx, u32, w),
        lua.tstring => bits = flagBit(ctx, idx, name, w),
        lua.ttable => {
            c.lua_pushnil(L);
            while (c.lua_next(L, idx) != 0) {
                if (c.lua_type(L, -2) == lua.tnumber) {
                    bits |= flagBit(ctx, -1, name, w);
                } else if (c.lua_type(L, -2) == lua.tstring) {
                    c.lua_pushvalue(L, -2);
                    const bit = flagBit(ctx, -1, name, w);
                    lua.pop(L, 1);
                    if (c.lua_toboolean(L, -1) != 0) bits |= bit;
                } else ctx.fail(w, "flags are names", .{});
                lua.pop(L, 1);
            }
        },
        else => ctx.typeError(w, idx, "flags"),
    }
    return @bitCast(bits);
}

fn readHandle(ctx: *Ctx, idx: c_int, comptime name: []const u8, w: Where) ZigType(name) {
    const L = ctx.L;
    if (lua.isnoneornil(L, idx)) return @enumFromInt(0);
    const h = toHandleUd(L, idx) orelse ctx.typeError(w, idx, "siv." ++ comptime m.stem(spec, name));
    if (h.type != comptime handleIndex(name)) ctx.typeError(w, idx, "siv." ++ comptime m.stem(spec, name));
    if (h.flags.destroyed) return @enumFromInt(0);
    return @enumFromInt(h.value);
}

fn readString(ctx: *Ctx, idx: c_int, w: Where) []const u8 {
    const L = ctx.L;
    if (lua.isnoneornil(L, idx)) return "";
    if (c.lua_type(L, idx) != lua.tstring) ctx.typeError(w, idx, "string");
    return lua.toString(L, idx).?;
}

fn hexDigit(ch: u8) ?u8 {
    return std.fmt.charToDigit(ch, 16) catch null;
}

/// "#rgb", "#rgba", "#rrggbb", or "#rrggbbaa", sRGB like CSS.
fn parseColor(s: []const u8) ?siv.Color {
    if (s.len < 1 or s[0] != '#') return null;
    const h = s[1..];
    var v: [4]f32 = .{ 0, 0, 0, 1 };
    switch (h.len) {
        3, 4 => for (h, 0..) |ch, i| {
            const d = hexDigit(ch) orelse return null;
            v[i] = @as(f32, @floatFromInt(d * 17)) / 255;
        },
        6, 8 => for (0..h.len / 2) |i| {
            const hi = hexDigit(h[2 * i]) orelse return null;
            const lo = hexDigit(h[2 * i + 1]) orelse return null;
            v[i] = @as(f32, @floatFromInt(hi * 16 + lo)) / 255;
        },
        else => return null,
    }
    return .{ .r = v[0], .g = v[1], .b = v[2], .a = v[3] };
}

fn isNumericStruct(comptime name: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    for (Info(name).d.@"struct".fields) |f| {
        if (f.reserved) return false;
        switch (f.type) {
            .f32, .f64, .u32, .i32 => {},
            else => return false,
        }
    }
    return true;
}

/// The number of a struct's fields a Lua table sets by position: reserved
/// fields come last and are not among them (D2).
fn positionalFields(comptime name: []const u8) usize {
    var n: usize = 0;
    for (Info(name).d.@"struct".fields) |f| {
        if (!f.reserved) n += 1;
    }
    return n;
}

/// A value struct from one Lua value: a table (named or positional
/// fields), a color string, or one number where mapping.zig allows it.
fn readValue(ctx: *Ctx, idx_: c_int, comptime name: []const u8, w: Where) ZigType(name) {
    const L = ctx.L;
    const idx = c.lua_absindex(L, idx_);
    const T = ZigType(name);
    var out: T = std.mem.zeroes(T);
    switch (c.lua_type(L, idx)) {
        lua.tnil, lua.tnone => {},
        lua.ttable => {
            if (comptime std.mem.eql(u8, name, "siv_color")) out.a = 1;
            fillStruct(ctx, idx, name, &out, w);
        },
        lua.tstring => {
            if (comptime !std.mem.eql(u8, name, "siv_color")) ctx.typeError(w, idx, "table");
            out = parseColor(lua.toString(L, idx).?) orelse ctx.fail(w, "invalid color '{s}'", .{lua.toString(L, idx).?});
        },
        lua.tnumber => {
            if (comptime m.isUniform(name)) {
                const v = readFloat(ctx, idx, f32, w);
                inline for (Info(name).d.@"struct".fields) |f| @field(out, f.name) = v;
            } else if (comptime m.isPxDimension(name)) {
                out.unit = .px;
                out.value = readFloat(ctx, idx, f32, w);
            } else ctx.typeError(w, idx, "table");
        },
        else => ctx.typeError(w, idx, "table"),
    }
    return out;
}

/// Array elements from a Lua sequence, in memory anchored for the call.
/// An array of bytes is a Lua string.
fn readArray(ctx: *Ctx, idx_: c_int, comptime t: schema.Type, w: Where) struct { ?[*]const ElemType(t), usize } {
    const L = ctx.L;
    const idx = c.lua_absindex(L, idx_);
    const E = ElemType(t);
    if (lua.isnoneornil(L, idx)) return .{ null, 0 };
    if (comptime t == .u8) {
        const s = readString(ctx, idx, w);
        return .{ s.ptr, s.len };
    }
    if (c.lua_type(L, idx) != lua.ttable) ctx.typeError(w, idx, "table");
    const n: usize = @intCast(c.lua_rawlen(L, idx));
    const items = ctx.alloc(E, n);
    for (items, 1..) |*item, i| {
        _ = c.lua_rawgeti(L, idx, @intCast(i));
        item.* = readScalar(ctx, -1, t, E, w);
        lua.pop(L, 1);
    }
    return .{ items.ptr, n };
}

fn ElemType(comptime t: schema.Type) type {
    return switch (t) {
        .bool => bool,
        .u8 => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .f32 => f32,
        .f64 => f64,
        .usize => usize,
        .ref => |r| ZigType(r),
        else => @compileError("not an element type"),
    };
}

/// One C value of a type that takes one Lua value.
fn readScalar(ctx: *Ctx, idx: c_int, comptime t: schema.Type, comptime CT: type, w: Where) CT {
    const L = ctx.L;
    return switch (t) {
        .bool => c.lua_toboolean(L, idx) != 0,
        .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .usize => if (lua.isnoneornil(L, idx)) 0 else readInt(ctx, idx, CT, w),
        .f32, .f64 => if (lua.isnoneornil(L, idx)) 0 else readFloat(ctx, idx, CT, w),
        .ref => |r| switch (comptime Info(r).d) {
            .handle => readHandle(ctx, idx, r, w),
            .@"enum" => readEnum(ctx, idx, r, w),
            .flags => readFlags(ctx, idx, r, w),
            .@"struct" => readValue(ctx, idx, r, w),
            .callback => @compileError("callbacks are read with their box"),
        },
        else => @compileError("not a scalar"),
    };
}

/// Index of a struct's callback fields (and destroy-notify) among its
/// box's slots, 1-based; 0 for other fields.
fn callbackSlot(comptime name: []const u8, comptime field: []const u8) c_int {
    @setEvalBranchQuota(1_000_000);
    var slot: c_int = 0;
    for (Info(name).d.@"struct".fields) |f| {
        if (!m.isCallback(spec, f.type) or m.isUnboundField(name, f.name)) continue;
        slot += 1;
        if (std.mem.eql(u8, f.name, field)) return slot;
    }
    return 0;
}

fn callbackSlots(comptime name: []const u8) c_int {
    @setEvalBranchQuota(1_000_000);
    var slot: c_int = 0;
    for (Info(name).d.@"struct".fields) |f| {
        if (m.isCallback(spec, f.type) and !m.isUnboundField(name, f.name)) slot += 1;
    }
    return slot;
}

fn fieldMap(comptime name: []const u8) type {
    return struct {
        const st = Info(name).d.@"struct";
        const map = blk: {
            var kvs: []const struct { []const u8, usize } = &.{};
            for (st.fields, 0..) |f, i| {
                if (!m.isUnboundField(name, f.name) and f.type != .user_data) {
                    kvs = kvs ++ .{.{ f.name, i }};
                    if (m.fieldAlias(name, f.name)) |a| kvs = kvs ++ .{.{ a, i }};
                }
            }
            break :blk std.StaticStringMap(usize).initComptime(kvs);
        };
    };
}

/// Fills `out` from the table at `idx`: named fields, or positional ones
/// for value structs. Unknown names are errors, so typos do not pass
/// silently.
fn fillStruct(ctx: *Ctx, idx: c_int, comptime name: []const u8, out: *ZigType(name), w0: Where) void {
    const L = ctx.L;
    const st = comptime Info(name).d.@"struct";
    var box_key: c_int = 0;
    var box: ?*Box = null;
    var given: u32 = 0;
    c.lua_pushnil(L);
    while (c.lua_next(L, idx) != 0) {
        var fi: usize = undefined;
        switch (c.lua_type(L, -2)) {
            lua.tstring => {
                const key = lua.toString(L, -2).?;
                fi = fieldMap(name).map.get(key) orelse {
                    var w = w0;
                    w.arg = 0;
                    w.st = name;
                    w.field = key;
                    ctx.fail(w, "unknown field", .{});
                };
            },
            lua.tnumber => {
                if (st.kind != .value) ctx.fail(w0, "{s} has named fields only", .{name});
                const k = readInt(ctx, -2, i64, w0);
                const n = comptime positionalFields(name);
                if (k < 1 or k > n) ctx.fail(w0, "{s} has {d} fields", .{ name, n });
                fi = @intCast(k - 1);
            },
            else => ctx.fail(w0, "{s} has named fields only", .{name}),
        }
        inline for (st.fields, 0..) |f, i| if (comptime !m.isUnboundField(name, f.name) and f.type != .user_data) if (i == fi) {
            const w: Where = .{ .st = name, .field = f.name };
            if (comptime m.isCallback(spec, f.type)) {
                if (!lua.isnoneornil(L, -1)) {
                    if (c.lua_type(L, -1) != lua.tfunction) ctx.typeError(w, -1, "function");
                    if (box == null) {
                        const b = ctx.newBox(comptime callbackSlots(name));
                        box = b[0];
                        box_key = b[1];
                    }
                    const slot = comptime callbackSlot(name, f.name);
                    given |= @as(u32, 1) << slot;
                    c.lua_pushvalue(L, -1);
                    ctx.setBoxSlot(box_key, slot);
                }
            } else switch (f.type) {
                .string => {
                    const s = readString(ctx, -1, w);
                    @field(out, f.name) = s.ptr;
                    @field(out, f.name ++ "_len") = s.len;
                },
                .array => |e| {
                    const a = readArray(ctx, -1, e.*, w);
                    @field(out, f.name) = a[0];
                    @field(out, f.name ++ "_count") = a[1];
                },
                .desc => @compileError("nested descriptors are not bound: " ++ name),
                else => @field(out, f.name) = readScalar(ctx, -1, f.type, @FieldType(ZigType(name), f.name), w),
            }
        };
        lua.pop(L, 1);
    }
    if (box) |b| {
        inline for (st.fields) |f| {
            if (comptime m.isCallback(spec, f.type) and !m.isUnboundField(name, f.name)) {
                const slot = comptime callbackSlot(name, f.name);
                if (comptime m.isDestroy(f.type)) {
                    @field(out, f.name) = &release(slot);
                } else if (given & (@as(u32, 1) << slot) != 0) {
                    @field(out, f.name) = trampoline(f.type.ref, slot, false);
                }
            } else if (f.type == .user_data) {
                @field(out, f.name) = b;
            }
        }
    }
}

// C to Lua.

fn pushEnum(L: *L_, comptime name: []const u8, v: ZigType(name)) void {
    const iv = @intFromEnum(v);
    inline for (Info(name).d.@"enum".values) |ev| if (ev.value == iv) return lua.pushString(L, ev.name);
    c.lua_pushinteger(L, iv);
}

fn pushFlags(L: *L_, comptime name: []const u8, v: ZigType(name)) void {
    const bits: u32 = @bitCast(v);
    c.lua_createtable(L, 0, 2);
    inline for (Info(name).d.flags.bits) |b| if (bits & (@as(u32, 1) << b.bit) != 0) {
        c.lua_pushboolean(L, 1);
        c.lua_setfield(L, -2, b.name ++ "");
    };
}

fn pushScalar(st: *State, L: *L_, comptime t: schema.Type, v: anytype, owned: bool) void {
    switch (t) {
        .bool => c.lua_pushboolean(L, @intFromBool(v)),
        .u64 => c.lua_pushinteger(L, @bitCast(v)),
        .u8, .u16, .u32, .i8, .i16, .i32, .i64 => c.lua_pushinteger(L, v),
        .usize => c.lua_pushinteger(L, @intCast(v)),
        .f32, .f64 => c.lua_pushnumber(L, v),
        .pointer => c.lua_pushlightuserdata(L, v),
        .ref => |r| switch (comptime Info(r).d) {
            .handle => pushHandle(st, L, comptime handleIndex(r), @intFromEnum(v), owned),
            .@"enum" => pushEnum(L, r, v),
            .flags => pushFlags(L, r, v),
            .@"struct" => pushStruct(st, L, r, &v),
            .callback => c.lua_pushnil(L),
        },
        else => @compileError("not a scalar"),
    }
}

/// A struct as a table of its fields. Strings that are NULL are absent;
/// descriptor fields past the struct's size read as zero.
pub fn pushStruct(st: *State, L: *L_, comptime name: []const u8, p: *const ZigType(name)) void {
    const T = ZigType(name);
    const sd = comptime Info(name).d.@"struct";
    c.lua_createtable(L, 0, sd.fields.len);
    inline for (sd.fields) |f| {
        const present = if (sd.kind == .descriptor) @offsetOf(T, f.name) + @sizeOf(@FieldType(T, f.name)) <= p.size else true;
        if (present and !comptime m.isCallback(spec, f.type) and f.type != .user_data and !m.isUnboundField(name, f.name)) {
            switch (f.type) {
                .string => if (@field(p, f.name)) |s| {
                    _ = c.lua_pushlstring(L, s, @field(p, f.name ++ "_len"));
                    c.lua_setfield(L, -2, f.name ++ "");
                },
                .array => |e| if (@field(p, f.name)) |items| {
                    const n = @field(p, f.name ++ "_count");
                    if (comptime e.* == .u8) {
                        _ = c.lua_pushlstring(L, items, n);
                    } else {
                        c.lua_createtable(L, @intCast(n), 0);
                        for (items[0..n], 1..) |item, i| {
                            pushScalar(st, L, e.*, item, false);
                            c.lua_rawseti(L, -2, @intCast(i));
                        }
                    }
                    c.lua_setfield(L, -2, f.name ++ "");
                },
                .desc, .pointer => {},
                else => {
                    pushScalar(st, L, f.type, @field(p, f.name), false);
                    c.lua_setfield(L, -2, f.name ++ "");
                    if (comptime m.fieldAlias(name, f.name)) |a| {
                        pushScalar(st, L, f.type, @field(p, f.name), false);
                        c.lua_setfield(L, -2, a ++ "");
                    }
                },
            }
        }
    }
}

// Callbacks.

/// Runs the user's destroy-notify, if the box has one in `slot`, and lets
/// the box go.
fn release(comptime slot: c_int) fn (?*anyopaque) callconv(.c) void {
    return struct {
        fn f(ud: ?*anyopaque) callconv(.c) void {
            const box: *Box = @ptrCast(@alignCast(ud.?));
            const st = box.st;
            const L = st.L;
            if (slot > 0 and c.lua_checkstack(L, 4) != 0) {
                _ = c.lua_rawgeti(L, lua.registry, box.ref);
                if (c.lua_getiuservalue(L, -1, slot) == lua.tfunction) {
                    st.depth += 1;
                    if (lua.pcall(L, 0, 0, 0) != lua.ok) st.report(L);
                    st.depth -= 1;
                    lua.pop(L, 1);
                } else lua.pop(L, 2);
            }
            c.luaL_unref(L, lua.registry, box.ref);
            box.ref = lua.noref;
        }
    }.f;
}

fn CallbackFn(comptime name: []const u8) type {
    return @typeInfo(ZigType(name)).pointer.child;
}

/// The C function that runs slot `slot` of the box in its user data for
/// callback type `name`. `owned_handles`: handle arguments of owned types
/// are new objects for the callee (an image a load completes with).
fn trampoline(comptime name: []const u8, comptime slot: c_int, comptime owned_handles: bool) ZigType(name) {
    const F = @typeInfo(CallbackFn(name)).@"fn";
    const P = F.param_types;
    const R = F.return_type.?;
    const I = Invoke(name, slot, R, owned_handles);
    return switch (P.len - 1) {
        0 => &struct {
            fn f(ud: ?*anyopaque) callconv(.c) R {
                return I.go(ud, .{});
            }
        }.f,
        1 => &struct {
            fn f(ud: ?*anyopaque, a: P[1].?) callconv(.c) R {
                return I.go(ud, .{a});
            }
        }.f,
        2 => &struct {
            fn f(ud: ?*anyopaque, a: P[1].?, b: P[2].?) callconv(.c) R {
                return I.go(ud, .{ a, b });
            }
        }.f,
        3 => &struct {
            fn f(ud: ?*anyopaque, a: P[1].?, b: P[2].?, d: P[3].?) callconv(.c) R {
                return I.go(ud, .{ a, b, d });
            }
        }.f,
        4 => &struct {
            fn f(ud: ?*anyopaque, a: P[1].?, b: P[2].?, d: P[3].?, e: P[4].?) callconv(.c) R {
                return I.go(ud, .{ a, b, d, e });
            }
        }.f,
        5 => &struct {
            fn f(ud: ?*anyopaque, a: P[1].?, b: P[2].?, d: P[3].?, e: P[4].?, g: P[5].?) callconv(.c) R {
                return I.go(ud, .{ a, b, d, e, g });
            }
        }.f,
        6 => &struct {
            fn f(ud: ?*anyopaque, a: P[1].?, b: P[2].?, d: P[3].?, e: P[4].?, g: P[5].?, h: P[6].?) callconv(.c) R {
                return I.go(ud, .{ a, b, d, e, g, h });
            }
        }.f,
        else => @compileError("callback with too many parameters: " ++ name),
    };
}

fn Invoke(comptime name: []const u8, comptime slot: c_int, comptime R: type, comptime owned_handles: bool) type {
    const cb = Info(name).d.callback;
    return struct {
        fn go(ud: ?*anyopaque, args: anytype) R {
            const Frame = struct { box: *Box, args: @TypeOf(args), ret: R };
            const box: *Box = @ptrCast(@alignCast(ud.?));
            const st = box.st;
            const L = st.L;
            var frame: Frame = .{ .box = box, .args = args, .ret = std.mem.zeroes(R) };
            if (c.lua_checkstack(L, 8) == 0) return frame.ret;
            const top = c.lua_gettop(L);
            st.pushTraceback(L);
            lua.pushcfunction(L, struct {
                fn run(Lq: ?*L_) callconv(.c) c_int {
                    const Ls = Lq.?;
                    const fr: *Frame = @ptrCast(@alignCast(c.lua_touserdata(Ls, 1)));
                    _ = c.lua_rawgeti(Ls, lua.registry, fr.box.ref);
                    if (c.lua_getiuservalue(Ls, -1, slot) != lua.tfunction) return 0;
                    const s = fr.box.st;
                    luaL_checkstack(Ls, cb.params.len + 4);
                    var nargs: c_int = 0;
                    var result: ?i32 = null;
                    inline for (cb.params, 0..) |p, pi| {
                        const i = comptime cbIndex(cb, pi);
                        if (comptime spec.isResult(p.type)) {
                            result = @intFromEnum(fr.args[i]);
                        } else {
                            switch (p.type) {
                                .desc => |dn| pushStruct(s, Ls, dn, fr.args[i]),
                                // A string is pointer and length; NULL is nil.
                                .string => if (fr.args[i]) |sp| {
                                    _ = c.lua_pushlstring(Ls, sp, fr.args[i + 1]);
                                } else c.lua_pushnil(Ls),
                                .array => @compileError("callbacks with arrays are not bound: " ++ name),
                                else => pushScalar(s, Ls, p.type, fr.args[i], owned_handles),
                            }
                            nargs += 1;
                        }
                    }
                    if (result) |r| {
                        if (r == 0) c.lua_pushnil(Ls) else pushError(s, Ls, r, name, 0);
                        nargs += 1;
                    }
                    const nret: c_int = switch (cb.ret) {
                        .void => 0,
                        .ref => |r| if (comptime Info(r).d == .@"struct") @intCast(Info(r).d.@"struct".fields.len) else 1,
                        else => 1,
                    };
                    lua.call(Ls, nargs, nret);
                    fr.ret = readReturn(Ls, nret);
                    return 0;
                }

                fn readReturn(Ls: *L_, comptime nret: c_int) R {
                    if (R == void) return;
                    var ctx: Ctx = .{ .st = undefined, .L = Ls, .func = name, .anchor_slot = 0 };
                    const w: Where = .{ .st = name, .field = "return value" };
                    switch (cb.ret) {
                        .bool => return c.lua_toboolean(Ls, -1) != 0,
                        .ref => |r| {
                            // An enum also takes a boolean, true for 1
                            // (mapping.zig): handlers return true for
                            // handled.
                            if (comptime Info(r).d == .@"enum") {
                                if (c.lua_type(Ls, -1) == lua.tboolean) return @enumFromInt(c.lua_toboolean(Ls, -1));
                                return readScalar(&ctx, -1, cb.ret, R, w);
                            }
                            // A handle, or nil for 0 (a widget's part).
                            if (comptime Info(r).d == .handle) return readScalar(&ctx, -1, cb.ret, R, w);
                            // A value struct: a table, or its fields as
                            // several return values.
                            if (c.lua_type(Ls, -nret) == lua.ttable) return readValue(&ctx, -nret, r, w);
                            var out: R = std.mem.zeroes(R);
                            inline for (Info(r).d.@"struct".fields, 0..) |f, i| {
                                @field(out, f.name) = readScalar(&ctx, -nret + @as(c_int, i), f.type, @FieldType(R, f.name), w);
                            }
                            return out;
                        },
                        else => return readScalar(&ctx, -1, cb.ret, R, w),
                    }
                }
            }.run);
            c.lua_pushlightuserdata(L, &frame);
            st.depth += 1;
            if (lua.pcall(L, 1, 0, top + 1) != lua.ok) st.report(L);
            st.depth -= 1;
            c.lua_settop(L, top);
            return frame.ret;
        }
    };
}

/// Index of a callback parameter among the C parameters after
/// user_data: strings and arrays take two.
fn cbIndex(comptime cb: schema.Callback, comptime pi: usize) usize {
    var n: usize = 0;
    for (cb.params[0..pi]) |p| n += switch (p.type) {
        .string, .array => 2,
        else => 1,
    };
    return n;
}

fn luaL_checkstack(L: *L_, n: usize) void {
    c.luaL_checkstack(L, @intCast(n), "siv callback");
}

// Function wrappers.

/// Index of the first C argument of schema parameter `pi`.
fn cIndex(comptime f: schema.Function, comptime pi: usize) usize {
    @setEvalBranchQuota(1_000_000);
    var n: usize = 0;
    for (f.params[0..pi]) |p| n += switch (p.type) {
        .string, .array, .buffer => 2,
        else => 1,
    };
    return n;
}

/// Whose sticky status a void function's failure goes to: a
/// transaction's (its first parameter, except siv_txn_abort, which ends
/// it) or a drawing's.
fn stickyOf(comptime f: schema.Function) enum { none, txn, draw } {
    if (f.params.len == 0 or f.params[0].type != .ref) return .none;
    const t = f.params[0].type.ref;
    if (std.mem.eql(u8, t, "siv_txn") and !std.mem.eql(u8, f.name, "siv_txn_abort")) return .txn;
    if (std.mem.eql(u8, t, "siv_draw")) return .draw;
    return .none;
}

fn ownedDestroy(comptime name: []const u8) ?[]const u8 {
    @setEvalBranchQuota(1_000_000);
    for (m.owned) |o| if (std.mem.eql(u8, o[1], name)) return o[0];
    return null;
}

fn functionIndex(comptime name: []const u8) usize {
    @setEvalBranchQuota(1_000_000);
    for (spec.functions, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
    @compileError("no function " ++ name);
}

pub fn Wrapper(comptime fi: usize) type {
    const f = spec.functions[fi];
    const cfn = @field(siv.c, f.name);
    const Args = std.meta.ArgsTuple(@TypeOf(cfn));
    return struct {
        pub fn call(Lq: ?*L_) callconv(.c) c_int {
            @setEvalBranchQuota(100_000);
            const L = Lq.?;
            const st = State.get(L);
            const top = c.lua_gettop(L);
            c.lua_pushnil(L);
            var ctx: Ctx = .{ .st = st, .L = L, .func = f.name, .anchor_slot = top + 1 };
            var args: Args = undefined;
            var arg: c_int = 1;
            // Storage for descriptors, outputs, and buffers.
            var slots: Slots = undefined;
            var buf: [256]u8 = undefined;
            inline for (f.params, 0..) |p, pi| {
                const ci = comptime cIndex(f, pi);
                const w: Where = .{ .arg = arg };
                switch (comptime m.role(spec, f, pi)) {
                    .input => {
                        switch (p.type) {
                            .string => {
                                const s = readString(&ctx, arg, w);
                                args[ci] = s.ptr;
                                args[ci + 1] = s.len;
                                arg += 1;
                            },
                            .array => |e| {
                                const a = readArray(&ctx, arg, e.*, w);
                                args[ci] = a[0];
                                args[ci + 1] = a[1];
                                arg += 1;
                            },
                            .desc => |dn| {
                                const T = ZigType(dn);
                                const d: *T = &slots[pi];
                                if (lua.isnoneornil(L, arg)) {
                                    args[ci] = null;
                                } else {
                                    if (c.lua_type(L, arg) != lua.ttable) ctx.typeError(w, arg, "table");
                                    d.* = .{};
                                    fillStruct(&ctx, arg, dn, d, w);
                                    args[ci] = d;
                                }
                                arg += 1;
                            },
                            .ref => |r| if (comptime Info(r).d == .@"struct" and isNumericStruct(r) and !m.isUniform(r) and !m.isPxDimension(r)) {
                                // A value struct of numbers also takes its
                                // fields as consecutive arguments:
                                // draw:rect(x, y, w, h).
                                if (c.lua_type(L, arg) == lua.tnumber) {
                                    var v: ZigType(r) = undefined;
                                    inline for (Info(r).d.@"struct".fields) |sf| {
                                        @field(v, sf.name) = readScalar(&ctx, arg, sf.type, @FieldType(ZigType(r), sf.name), .{ .arg = arg });
                                        arg += 1;
                                    }
                                    args[ci] = v;
                                } else {
                                    args[ci] = readValue(&ctx, arg, r, w);
                                    arg += 1;
                                }
                            } else {
                                args[ci] = readScalar(&ctx, arg, p.type, @TypeOf(args[ci]), w);
                                arg += 1;
                            },
                            else => {
                                args[ci] = readScalar(&ctx, arg, p.type, @TypeOf(args[ci]), w);
                                arg += 1;
                            },
                        }
                    },
                    .callback => {
                        // The callback, its destroy-notify, and user_data.
                        const di = comptime pi + 1;
                        const ui = comptime pi + 2;
                        comptime std.debug.assert(m.isDestroy(f.params[di].type) and f.params[ui].type == .user_data);
                        if (lua.isnoneornil(L, arg)) {
                            args[ci] = null;
                            args[comptime cIndex(f, di)] = null;
                            args[comptime cIndex(f, ui)] = null;
                        } else {
                            if (c.lua_type(L, arg) != lua.tfunction) ctx.typeError(w, arg, "function");
                            const b = ctx.newBox(1);
                            c.lua_pushvalue(L, arg);
                            ctx.setBoxSlot(b[1], 1);
                            args[ci] = trampoline(p.type.ref, 1, comptime m.isAsyncCallback(p.type.ref));
                            args[comptime cIndex(f, di)] = &release(0);
                            args[comptime cIndex(f, ui)] = b[0];
                        }
                        arg += 1;
                    },
                    .hidden => {},
                    .out, .len => args[ci] = &slots[pi],
                    .buffer => {
                        args[ci] = &buf;
                        args[ci + 1] = buf.len;
                    },
                }
            }
            // Only an argument the caller passed: past them is the anchor
            // slot, a table once a callback was boxed.
            const props = if (comptime m.isBuilder(spec, f)) (if (arg <= top) arg else 0) else 0;
            ctx.commitBoxes();

            const prev = st.L;
            st.L = L;
            if (comptime std.mem.eql(u8, f.name, "siv_app_run")) st.running = @intFromEnum(args[0]);
            var r = @call(.auto, cfn, args);
            if (comptime std.mem.eql(u8, f.name, "siv_app_run")) st.running = 0;
            st.L = prev;
            st.raisePending(L);

            // A buffer too small for the string: once more, big enough.
            var text: []const u8 = &.{};
            if (comptime bufferParam(f)) |bp| {
                if (r == .ok) {
                    const len = slots[comptime lenParam(f)];
                    if (len <= buf.len) {
                        text = buf[0..len];
                    } else {
                        const big = ctx.alloc(u8, len);
                        args[comptime cIndex(f, bp)] = big.ptr;
                        args[comptime cIndex(f, bp) + 1] = big.len;
                        st.L = L;
                        r = @call(.auto, cfn, args);
                        st.L = prev;
                        const len2 = slots[comptime lenParam(f)];
                        text = big[0..@min(len2, big.len)];
                    }
                }
            }

            if (comptime f.ret == .void) {
                // Transaction and drawing operations return nothing, their
                // failure being the transaction's or the drawing's (D2);
                // Lua raises at the operation that failed (D23).
                const code: i32 = switch (comptime stickyOf(f)) {
                    .txn => @intFromEnum(siv.c.siv_txn_status(args[0])),
                    .draw => @intFromEnum(siv.c.siv_draw_status(args[0])),
                    .none => 0,
                };
                if (code != 0) raiseResult(st, L, code, f.name);
                if (comptime ownedDestroy(f.name)) |h| {
                    if (toHandleUd(L, 1)) |ud| {
                        ud.flags.destroyed = true;
                        if (comptime std.mem.eql(u8, h, "siv_app")) sweepRoot(st, L, ud.value);
                    }
                }
                return 0;
            }
            if (comptime spec.isResult(f.ret)) {
                const code = @intFromEnum(r);
                if (code != 0) raiseResult(st, L, code, f.name);
                if (comptime ownedDestroy(f.name)) |h| {
                    if (toHandleUd(L, 1)) |ud| {
                        ud.flags.destroyed = true;
                        if (comptime std.mem.eql(u8, h, "siv_app")) sweepRoot(st, L, ud.value);
                    }
                }
                var nret: c_int = 0;
                inline for (f.params, 0..) |p, pi| switch (comptime m.role(spec, f, pi)) {
                    .out => {
                        const v = slots[pi];
                        const t = p.type.out.*;
                        const owned = comptime m.isConstructor(f.name) and m.isHandle(spec, t) and m.isOwned(t.ref);
                        pushScalar(st, L, t, v, owned);
                        if (comptime std.mem.eql(u8, f.name, "siv_app_create")) st.addApp(@intFromEnum(v));
                        nret += 1;
                    },
                    .buffer => {
                        lua.pushString(L, text);
                        nret += 1;
                    },
                    else => {},
                };
                return nret;
            }
            switch (f.ret) {
                .void => return 0,
                .static_string => {
                    _ = c.lua_pushstring(L, r);
                    return 1;
                },
                .ref => |rn| {
                    if (comptime m.isHandle(spec, f.ret)) {
                        if (@intFromEnum(r) == 0) {
                            if (comptime m.isBuilder(spec, f)) {
                                const status = siv.c.siv_txn_status(args[0]);
                                raiseResult(st, L, if (@intFromEnum(status) != 0) @intFromEnum(status) else -2, f.name);
                            }
                            // A query's 0 is "none" (D2): nil.
                            c.lua_pushnil(L);
                            return 1;
                        }
                        pushHandle(st, L, comptime handleIndex(rn), @intFromEnum(r), false);
                        if (props > 0 and c.lua_type(L, props) == lua.ttable) applyProperties(st, L, props);
                        return 1;
                    }
                    pushScalar(st, L, f.ret, r, false);
                    return 1;
                },
                else => {
                    pushScalar(st, L, f.ret, r, false);
                    return 1;
                },
            }
        }

        /// Storage for each parameter that needs some: descriptors and
        /// out parameters.
        const Slots = blk: {
            var types: [f.params.len]type = undefined;
            for (f.params, 0..) |p, pi| types[pi] = switch (p.type) {
                .desc => |dn| if (m.role(spec, f, pi) == .input) ZigType(dn) else void,
                .out => @typeInfo(@typeInfo(@typeInfo(Args).@"struct".field_types[cIndex(f, pi)]).optional.child).pointer.child,
                else => void,
            };
            break :blk @Tuple(&types);
        };
    };
}

fn bufferParam(comptime f: schema.Function) ?usize {
    for (f.params, 0..) |p, i| if (p.type == .buffer) return i;
    return null;
}

fn lenParam(comptime f: schema.Function) usize {
    for (f.params, 0..) |_, i| if (m.role(spec, f, i) == .len) return i;
    unreachable;
}

/// Setters a builder's properties table can name: `layout` runs
/// siv_set_layout on the new node.
const property_setters = blk: {
    var kvs: []const struct { []const u8, usize } = &.{};
    for (spec.functions, 0..) |f, i| {
        if (m.isUnbound(f.name) or !std.mem.startsWith(u8, f.name, "siv_set_")) continue;
        const key = f.name["siv_set_".len..];
        const setter = m.propertySetter(spec, key) orelse continue;
        if (std.mem.eql(u8, setter.name, f.name)) kvs = kvs ++ .{.{ key, i }};
    }
    break :blk std.StaticStringMap(usize).initComptime(kvs);
};

/// Applies a builder's properties table to the node on top of the stack:
/// `{ layout = {...}, visual = {...}, on = { activate = fn } }`. The txn
/// is argument 1.
fn applyProperties(st: *State, L: *L_, props: c_int) void {
    _ = st;
    const node = c.lua_gettop(L);
    c.lua_pushnil(L);
    while (c.lua_next(L, props) != 0) {
        if (c.lua_type(L, -2) != lua.tstring) lua.raise(L, "properties are named", .{});
        const key = lua.toString(L, -2).?;
        if (std.mem.eql(u8, key, "on")) {
            if (c.lua_type(L, -1) != lua.ttable) lua.raise(L, "on: table of handlers expected", .{});
            const handlers = c.lua_gettop(L);
            c.lua_pushnil(L);
            while (c.lua_next(L, handlers) != 0) {
                c.lua_pushvalue(L, lua.upvalue(1));
                c.lua_pushcclosure(L, Wrapper(comptime functionIndex("siv_on")).call, 1);
                c.lua_pushvalue(L, 1);
                c.lua_pushvalue(L, node);
                c.lua_pushvalue(L, -5);
                c.lua_pushvalue(L, -5);
                lua.call(L, 4, 0);
                lua.pop(L, 1);
            }
        } else {
            const fi = property_setters.get(key) orelse lua.raise(L, "unknown property '{s}'", .{key});
            c.lua_pushvalue(L, lua.upvalue(1));
            c.lua_pushcclosure(L, wrappers[fi], 1);
            c.lua_pushvalue(L, 1);
            c.lua_pushvalue(L, node);
            c.lua_pushvalue(L, -4);
            lua.call(L, 3, 0);
        }
        lua.pop(L, 1);
    }
}

/// Every schema function's wrapper (unbound ones raise).
pub const wrappers: [spec.functions.len]lua.CFunction = blk: {
    @setEvalBranchQuota(10_000_000);
    var w: [spec.functions.len]lua.CFunction = undefined;
    for (spec.functions, 0..) |f, i| w[i] = if (m.isUnbound(f.name)) unboundFn else Wrapper(i).call;
    break :blk w;
};

fn unboundFn(Lq: ?*L_) callconv(.c) c_int {
    lua.raise(Lq.?, "not available from Lua", .{});
}

// Metamethods of handle userdata.

pub fn handleGc(comptime hi: usize) lua.CFunction {
    const name = handle_names[hi];
    return struct {
        fn f(Lq: ?*L_) callconv(.c) c_int {
            const L = Lq.?;
            const h = toHandleUd(L, 1) orelse return 0;
            if (!h.flags.owned or h.flags.destroyed) return 0;
            const st = State.get(L);
            h.flags.destroyed = true;
            inline for (m.owned) |o| if (comptime std.mem.eql(u8, o[0], name)) {
                const prev = st.L;
                st.L = L;
                _ = @field(siv.c, o[1])(@enumFromInt(h.value));
                st.L = prev;
                if (comptime std.mem.eql(u8, name, "siv_app")) sweepRoot(st, L, h.value);
            };
            return 0;
        }
    }.f;
}

/// `<close>` on a transaction aborts it unless it was committed.
pub fn txnClose(Lq: ?*L_) callconv(.c) c_int {
    const L = Lq.?;
    const h = toHandleUd(L, 1) orelse return 0;
    const st = State.get(L);
    const prev = st.L;
    st.L = L;
    _ = siv.c.siv_txn_abort(@enumFromInt(h.value));
    st.L = prev;
    return 0;
}

pub fn handleToString(Lq: ?*L_) callconv(.c) c_int {
    const L = Lq.?;
    const h = toHandleUd(L, 1) orelse return 0;
    var buf: [64]u8 = undefined;
    const name = inline for (handle_names, 0..) |n, i| {
        if (i == h.type) break comptime m.stem(spec, n);
    } else "handle";
    const s = std.fmt.bufPrint(&buf, "siv.{s}: 0x{x:0>16}{s}", .{ name, h.value, if (h.flags.destroyed) " (destroyed)" else "" }) catch unreachable;
    lua.pushString(L, s);
    return 1;
}
