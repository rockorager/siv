//! libsiv-lua (D23): siv for Lua 5.5, built on the public C ABI only.
//!
//! - bind.zig: one Lua function per schema function, generated at
//!   compile time from src/abi/api.zig by the rules in mapping.zig.
//! - prelude.lua: what Lua makes pleasant on top (transactions as
//!   functions, coroutines for asynchronous calls, hot reload).
//! - hot.zig: the file watcher behind hot reload.
//! - siv_lua_new and siv_lua_run: the embedding API (siv_lua.h), which
//!   the siv-lua runner (main.zig) uses. Only libsiv-lua, which bundles
//!   Lua, exports them; siv.so, the same binding as a Lua C module for a
//!   host's own Lua 5.5, exports luaopen_siv alone.

const std = @import("std");
const lua = @import("c.zig");
const c = lua.c;
const bind = @import("bind.zig");
const m = @import("mapping.zig");
const hot = @import("hot.zig");
const job = @import("job.zig");
const siv = @import("siv");

pub const mapping = m;
pub const State = bind.State;
const spec = m.spec;
const L_ = lua.State;

pub const c_api = c;

const prelude = @embedFile("prelude.lua");

/// libsiv-lua bundles Lua and exports the embedding API; siv.so, the Lua
/// C module, has only luaopen_siv and takes Lua from its host.
const bundled = @import("lua_options").bundled;

comptime {
    @export(&luaopen_siv, .{ .name = "luaopen_siv" });
    if (bundled) {
        @export(&siv_lua_new, .{ .name = "siv_lua_new" });
        @export(&siv_lua_run, .{ .name = "siv_lua_run" });
        @export(&siv_lua_push_handle, .{ .name = "siv_lua_push_handle" });
    }
    // The headless tests link the binding as an object and read handles
    // through C (test/lua/api.zig).
    if (@import("lua_options").test_exports) @export(&testToHandle, .{ .name = "siv_lua_test_to_handle" });
}

fn testToHandle(L: *L_, idx: c_int) callconv(.c) u64 {
    return toHandle(L, idx);
}

fn setRegistry(L: *L_, key: [:0]const u8) void {
    c.lua_setfield(L, lua.registry, key.ptr);
}

fn pushState(L: *L_, st: *State) void {
    c.lua_pushlightuserdata(L, st);
}

/// A C closure with the state as its upvalue.
fn pushFn(L: *L_, st: *State, f: lua.CFunction) void {
    pushState(L, st);
    c.lua_pushcclosure(L, f, 1);
}

pub fn luaopen_siv(Lq: ?*L_) callconv(.c) c_int {
    @setEvalBranchQuota(10_000_000);
    const L = Lq.?;
    // A host's Lua must be 5.5 with this build's number types.
    c.luaL_checkversion_(L, c.LUA_VERSION_NUM, @sizeOf(c.lua_Integer) * 16 + @sizeOf(c.lua_Number));
    if (c.lua_getfield(L, lua.registry, "siv.module") == lua.ttable) return 1;
    lua.pop(L, 1);

    // The state, kept by the registry.
    const st: *State = @ptrCast(@alignCast(c.lua_newuserdatauv(L, @sizeOf(State), 0)));
    _ = c.lua_rawgeti(L, lua.registry, lua.ridx_mainthread);
    const main = c.lua_tothread(L, -1).?;
    lua.pop(L, 1);
    st.* = .{ .main = main, .L = main };
    c.lua_createtable(L, 0, 1);
    pushFn(L, st, stateGc);
    c.lua_setfield(L, -2, "__gc");
    _ = c.lua_setmetatable(L, -2);
    setRegistry(L, "siv.state");

    pushFn(L, st, traceback);
    st.traceback = c.luaL_ref(L, lua.registry);

    c.lua_createtable(L, 0, 3);
    pushFn(L, st, errorToString);
    c.lua_setfield(L, -2, "__tostring");
    lua.pushString(L, "siv.error");
    c.lua_setfield(L, -2, "__name");
    st.err_mt = c.luaL_ref(L, lua.registry);

    lua.newtable(L);
    c.lua_createtable(L, 0, 1);
    lua.pushString(L, "v");
    c.lua_setfield(L, -2, "__mode");
    _ = c.lua_setmetatable(L, -2);
    st.cache = c.luaL_ref(L, lua.registry);

    // The module and the methods of each handle type.
    c.lua_createtable(L, 0, spec.functions.len + 16);
    const module = c.lua_gettop(L);
    c.lua_createtable(L, 0, bind.handle_names.len);
    const methods = c.lua_gettop(L);
    inline for (bind.handle_names, 0..) |name, hi| {
        const stem = comptime m.stem(spec, name);
        lua.newtable(L);
        c.lua_pushvalue(L, -1);
        c.lua_setfield(L, methods, stem.ptr);
        c.lua_pushvalue(L, -1);
        st.methods[hi] = c.luaL_ref(L, lua.registry);
        // The metatable.
        c.lua_createtable(L, 0, 6);
        lua.insert(L, -2);
        c.lua_setfield(L, -2, "__index");
        lua.pushString(L, "siv." ++ stem);
        c.lua_setfield(L, -2, "__name");
        pushFn(L, st, bind.handleToString);
        c.lua_setfield(L, -2, "__tostring");
        if (comptime m.isOwned(name)) {
            pushFn(L, st, bind.handleGc(hi));
            c.lua_pushvalue(L, -1);
            c.lua_setfield(L, -3, "__gc");
            c.lua_setfield(L, -2, "__close");
        } else if (comptime std.mem.eql(u8, name, "siv_txn")) {
            pushFn(L, st, bind.txnClose);
            c.lua_setfield(L, -2, "__close");
        }
        st.meta[hi] = c.luaL_ref(L, lua.registry);
    }
    inline for (spec.functions, 0..) |f, fi| {
        if (comptime !m.isUnbound(f.name)) {
            pushFn(L, st, bind.wrappers[fi]);
            if (comptime m.owner(spec, f)) |o| {
                _ = c.lua_getfield(L, methods, comptime m.stem(spec, o).ptr);
                c.lua_pushvalue(L, -2);
                c.lua_setfield(L, -2, comptime m.methodName(spec, f).ptr);
                lua.pop(L, 1);
            }
            c.lua_setfield(L, module, comptime m.luaName(spec, f.name).ptr);
        }
    }
    c.lua_setfield(L, module, "methods");

    // What the prelude needs from here.
    c.lua_createtable(L, 0, 8);
    const internal = c.lua_gettop(L);
    c.lua_createtable(L, 8, 0);
    var n: c.lua_Integer = 0;
    inline for (spec.functions) |f| {
        if (comptime !m.isUnbound(f.name)) if (comptime m.asyncParam(spec, f)) |pi| {
            c.lua_createtable(L, 0, 4);
            lua.pushString(L, comptime m.luaName(spec, f.name));
            c.lua_setfield(L, -2, "name");
            if (comptime m.owner(spec, f)) |o| {
                lua.pushString(L, comptime m.stem(spec, o));
                c.lua_setfield(L, -2, "owner");
                lua.pushString(L, comptime m.methodName(spec, f));
                c.lua_setfield(L, -2, "method");
            }
            c.lua_pushinteger(L, comptime m.luaArgsBefore(spec, f, pi) + 1);
            c.lua_setfield(L, -2, "pos");
            n += 1;
            c.lua_rawseti(L, -2, n);
        };
    }
    c.lua_setfield(L, internal, "async");
    pushFn(L, st, traceback);
    c.lua_setfield(L, internal, "traceback");
    pushFn(L, st, report);
    c.lua_setfield(L, internal, "report");
    pushFn(L, st, setErrorHandler);
    c.lua_setfield(L, internal, "set_error_handler");
    pushFn(L, st, hot.start);
    c.lua_setfield(L, internal, "watch_start");
    pushFn(L, st, hot.add);
    c.lua_setfield(L, internal, "watch_add");
    pushFn(L, st, isError);
    c.lua_setfield(L, internal, "is_error");
    pushFn(L, st, handleValue);
    c.lua_setfield(L, internal, "handle_value");
    pushFn(L, st, job.start);
    c.lua_setfield(L, internal, "job_start");
    c.lua_pushvalue(L, internal);
    setRegistry(L, "siv.internal");

    if (c.luaL_loadbufferx(L, prelude.ptr, prelude.len, "=[siv prelude]", "t") != lua.ok) _ = c.lua_error(L);
    c.lua_pushvalue(L, module);
    c.lua_pushvalue(L, internal);
    lua.call(L, 2, 1);
    c.lua_pushvalue(L, -1);
    setRegistry(L, "siv.module");
    return 1;
}

fn stateGc(Lq: ?*L_) callconv(.c) c_int {
    const st = State.get(Lq.?);
    if (st.watcher) |w| st.watcher_stop.?(w);
    st.watcher = null;
    return 0;
}

/// Message handler: a string gains a traceback; an error table gains a
/// `traceback` field.
fn traceback(Lq: ?*L_) callconv(.c) c_int {
    const L = Lq.?;
    if (c.lua_type(L, 1) == lua.tthread) {
        // traceback(co, msg): the traceback of a coroutine.
        const co = c.lua_tothread(L, 1).?;
        const msg = c.lua_tolstring(L, 2, null);
        c.luaL_traceback(L, co, msg, 0);
        return 1;
    }
    if (c.lua_type(L, 1) == lua.ttable) {
        if (c.lua_getfield(L, 1, "traceback") == lua.tnil) {
            c.luaL_traceback(L, L, null, 1);
            c.lua_setfield(L, 1, "traceback");
        }
        c.lua_settop(L, 1);
        return 1;
    }
    const msg = c.luaL_tolstring(L, 1, null);
    c.luaL_traceback(L, L, msg, 1);
    return 1;
}

fn errorToString(Lq: ?*L_) callconv(.c) c_int {
    const L = Lq.?;
    _ = c.lua_getfield(L, 1, "message");
    return 1;
}

fn report(Lq: ?*L_) callconv(.c) c_int {
    const L = Lq.?;
    const st = State.get(L);
    c.lua_settop(L, 1);
    st.report(L);
    return 0;
}

fn setErrorHandler(Lq: ?*L_) callconv(.c) c_int {
    const L = Lq.?;
    const st = State.get(L);
    if (!lua.isnoneornil(L, 1)) c.luaL_checktype(L, 1, lua.tfunction);
    c.luaL_unref(L, lua.registry, st.handler);
    st.handler = lua.noref;
    if (!lua.isnoneornil(L, 1)) {
        c.lua_settop(L, 1);
        st.handler = c.luaL_ref(L, lua.registry);
    }
    return 0;
}

fn isError(Lq: ?*L_) callconv(.c) c_int {
    const L = Lq.?;
    const st = State.get(L);
    var is = false;
    if (c.lua_getmetatable(L, 1) != 0) {
        _ = c.lua_rawgeti(L, lua.registry, st.err_mt);
        is = c.lua_rawequal(L, -1, -2) != 0;
    }
    c.lua_pushboolean(L, @intFromBool(is));
    return 1;
}

fn handleValue(Lq: ?*L_) callconv(.c) c_int {
    const L = Lq.?;
    const h = bind.toHandleUd(L, 1) orelse return 0;
    c.lua_pushinteger(L, @bitCast(h.value));
    return 1;
}

/// The handle a siv userdata at `idx` holds, or 0.
pub fn toHandle(L: *L_, idx: c_int) u64 {
    const h = bind.toHandleUd(L, idx) orelse return 0;
    return h.value;
}

// Embedding.

const Lib = struct { name: [:0]const u8, bit: c_int, open: lua.CFunction };

/// The standard libraries compiled in (src/lua/build_steps.zig), with
/// lualib.h's bits.
const libs = [_]Lib{
    .{ .name = "_G", .bit = 1 << 0, .open = c.luaopen_base },
    .{ .name = "package", .bit = 1 << 1, .open = c.luaopen_package },
    .{ .name = "coroutine", .bit = 1 << 2, .open = c.luaopen_coroutine },
    .{ .name = "io", .bit = 1 << 4, .open = c.luaopen_io },
    .{ .name = "math", .bit = 1 << 5, .open = c.luaopen_math },
    .{ .name = "os", .bit = 1 << 6, .open = c.luaopen_os },
    .{ .name = "string", .bit = 1 << 7, .open = c.luaopen_string },
    .{ .name = "table", .bit = 1 << 8, .open = c.luaopen_table },
    .{ .name = "utf8", .bit = 1 << 9, .open = c.luaopen_utf8 },
};

fn openLibs(Lq: ?*L_) callconv(.c) c_int {
    const L = Lq.?;
    const want: c_int = @intCast(c.lua_tointegerx(L, 1, null));
    for (libs) |lib| if (want & lib.bit != 0) {
        c.luaL_requiref(L, lib.name.ptr, lib.open, 1);
        lua.pop(L, 1);
    };
    // require("siv"), without a global.
    if (c.lua_getfield(L, lua.registry, "_PRELOAD") == lua.ttable) {
        lua.pushcfunction(L, luaopen_siv);
        c.lua_setfield(L, -2, "siv");
    }
    return 0;
}

pub fn siv_lua_new(libs_mask: c_int) callconv(.c) ?*L_ {
    const L = c.luaL_newstate() orelse return null;
    lua.pushcfunction(L, openLibs);
    c.lua_pushinteger(L, libs_mask);
    if (lua.pcall(L, 1, 0, 0) != lua.ok) {
        c.lua_close(L);
        return null;
    }
    return L;
}

const RunArgs = struct {
    path: [*:0]const u8,
    argc: c_int,
    argv: ?[*]const ?[*:0]const u8,
    flags: c_uint,
};

fn runMain(Lq: ?*L_) callconv(.c) c_int {
    const L = Lq.?;
    const a: *const RunArgs = @ptrCast(@alignCast(c.lua_touserdata(L, 1)));
    c.luaL_requiref(L, "siv", luaopen_siv, 0);
    _ = c.lua_getfield(L, lua.registry, "siv.internal");
    _ = c.lua_getfield(L, -1, "run_main");
    _ = c.lua_pushstring(L, a.path);
    c.lua_pushboolean(L, @intFromBool(a.flags & 1 != 0));
    var i: c_int = 0;
    while (i < a.argc) : (i += 1) _ = c.lua_pushstring(L, a.argv.?[@intCast(i)]);
    lua.call(L, a.argc + 2, 0);
    return 0;
}

/// Pushes a handle the host made, of the handle type named `type` as
/// siv.methods names it ("app", "window", "node", ...), as the binding's
/// userdata for it: the same userdata Lua holds for that handle if any,
/// never owned by Lua. Pushes nil and returns -1 for an unknown type or
/// a zero handle. The handle is not checked: a stale or mistyped one
/// raises invalid_handle when Lua uses it, as any stale handle does.
pub fn siv_lua_push_handle(Lq: ?*L_, type_name: [*:0]const u8, handle: u64) callconv(.c) c_int {
    const L = Lq.?;
    const name = std.mem.span(type_name);
    const index: ?u16 = blk: {
        inline for (bind.handle_names, 0..) |h, i| {
            if (std.mem.eql(u8, name, comptime m.stem(spec, h))) break :blk i;
        }
        break :blk null;
    };
    if (index == null or handle == 0 or c.lua_checkstack(L, 4) == 0) {
        c.lua_pushnil(L);
        return -1;
    }
    // The binding's state, made by require("siv") if Lua has not yet.
    c.luaL_requiref(L, "siv", luaopen_siv, 0);
    lua.pop(L, 1);
    _ = c.lua_getfield(L, lua.registry, "siv.state");
    const st: *State = @ptrCast(@alignCast(c.lua_touserdata(L, -1)));
    lua.pop(L, 1);
    bind.pushHandle(st, L, index.?, handle, false);
    return 0;
}

/// Prints an error object: its message and traceback.
pub fn printError(L: *L_, idx: c_int) void {
    var len: usize = 0;
    const msg = c.luaL_tolstring(L, idx, &len);
    std.debug.print("{s}\n", .{msg[0..len]});
    lua.pop(L, 1);
    if (c.lua_type(L, idx) == lua.ttable) {
        if (c.lua_getfield(L, idx, "traceback") == lua.tstring) std.debug.print("{s}\n", .{lua.toString(L, -1).?});
        lua.pop(L, 1);
    }
}

pub fn siv_lua_run(Lq: ?*L_, path: [*:0]const u8, argc: c_int, argv: ?[*]const ?[*:0]const u8, flags: c_uint) callconv(.c) c_int {
    const L = Lq.?;
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    var args: RunArgs = .{ .path = path, .argc = argc, .argv = argv, .flags = flags };
    if (c.lua_checkstack(L, argc + 8) == 0) return 1;
    lua.pushcfunction(L, traceback);
    lua.pushcfunction(L, runMain);
    c.lua_pushlightuserdata(L, &args);
    if (lua.pcall(L, 1, 0, top + 1) != lua.ok) {
        printError(L, -1);
        return 1;
    }
    return 0;
}

test {
    std.testing.refAllDecls(@This());
    _ = m;
    _ = bind;
}
