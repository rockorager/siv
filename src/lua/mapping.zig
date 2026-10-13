//! How the schema maps to Lua (D23). The binding (bind.zig, at compile
//! time) and the annotation generator (gen_types.zig, at build time) both
//! follow these rules, so the Lua API, its annotations, and the C ABI
//! cannot drift apart. Every function here works at compile time and
//! allocates nothing: names are slices of schema names.
//!
//! - Every function is `siv.<name>` without the prefix (`siv.flex`), and
//!   a method of the handle type of its first parameter, without that
//!   type's stem (`siv_window_set_title` is `window:set_title`,
//!   `siv_flex` is `txn:flex`).
//! - Out parameters are return values, in order; a buffer and its `len`
//!   are one string return.
//! - A callback parameter is a Lua function; its destroy-notify and
//!   user_data are the binding's. Functions taking a one-shot completion
//!   (`async_callbacks`) are asynchronous: the prelude waits for them in
//!   a coroutine when no function is given. Given one, they return their
//!   out values (an image load's request, to cancel it); waiting drops
//!   them.
//! - Descriptors are tables; value structs are tables with named or
//!   positional fields. Reserved fields are not in them.
//! - Enums are names or integers: any integer for open enums (keysyms),
//!   only the values named for closed ones.
//! - A Lua function returning an enum to a callback returns its name, an
//!   integer, or a boolean (true for 1, false or nil for 0), so an event
//!   handler returns true for handled, "stop", or "prevent".

const std = @import("std");
/// src/abi/api.zig, or the abi module that holds it when the binding is
/// compiled with libsiv's exports (the headless tests).
const api = blk: {
    const imported = @import("siv_schema");
    break :blk if (@hasDecl(imported, "spec")) imported else imported.api;
};
pub const schema = api.schema;
pub const spec = api.spec;

const Schema = schema.Schema;
const Function = schema.Function;
const Param = schema.Param;
const Type = schema.Type;

/// Functions the binding leaves out, with the reason. Checked against the
/// schema at compile time.
pub const unbound = [_]struct { []const u8, []const u8 }{
    .{ "siv_set_data", "raw node memory under a pointer key; Lua keeps state in tables" },
    .{ "siv_node_get_data", "raw node memory under a pointer key; Lua keeps state in tables" },
    .{ "siv_external_get_wayland", "hands native embedders wl_display and wl_surface pointers" },
    .{ "siv_job_start", "work runs on a worker thread, where Lua cannot" },
};

/// Descriptor fields the binding leaves at zero.
pub const unbound_fields = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "siv_app_desc", "allocator", "allocator hooks are C functions; Lua uses its own allocator" },
    .{ "siv_external_desc", "release", "runs on the compositor thread, where Lua cannot; releases arrive as events instead" },
};

/// Callbacks that run once to complete an asynchronous call.
pub const async_callbacks = [_][]const u8{ "siv_image_load_fn", "siv_portal_fn", "siv_clipboard_fn" };

/// Handle types whose objects the Lua value owns: collecting it (or
/// leaving the scope of a `<close>` variable) destroys the object, which
/// `destroy` names. The other handles name objects that live on their own
/// (windows until closed, nodes until removed) or only during a call
/// (draw contexts).
pub const owned = [_]struct { []const u8, []const u8 }{
    .{ "siv_app", "siv_app_destroy" },
    .{ "siv_image", "siv_image_destroy" },
    .{ "siv_inhibition", "siv_inhibition_destroy" },
    .{ "siv_file_chooser", "siv_file_chooser_destroy" },
    .{ "siv_global_shortcuts", "siv_global_shortcuts_destroy" },
    .{ "siv_screencast", "siv_screencast_destroy" },
    .{ "siv_tray_item", "siv_tray_item_destroy" },
};

pub const borrowed = [_][]const u8{ "siv_window", "siv_txn", "siv_node", "siv_timer", "siv_watch", "siv_image_request", "siv_draw", "siv_external" };

/// Functions whose out handle is a new object the caller owns (when its
/// type is `owned`).
pub const constructors = [_][]const u8{
    "siv_app_create",
    "siv_image_create",
    "siv_inhibit",
    "siv_file_chooser_create",
    "siv_global_shortcuts_create",
    "siv_screencast_start",
    "siv_tray_item_create",
};

pub fn isUnbound(name: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    for (unbound) |u| if (std.mem.eql(u8, u[0], name)) return true;
    return false;
}

/// Fields the binding leaves at zero: those in `unbound_fields`, and
/// reserved fields (D2), which have no meaning yet.
pub fn isUnboundField(st: []const u8, field: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    for (unbound_fields) |u| if (std.mem.eql(u8, u[0], st) and std.mem.eql(u8, u[1], field)) return true;
    if (spec.find(st)) |d| if (d == .@"struct") for (d.@"struct".fields) |f| {
        if (f.reserved and std.mem.eql(u8, f.name, field)) return true;
    };
    return false;
}

pub fn isOwned(handle: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    for (owned) |o| if (std.mem.eql(u8, o[0], handle)) return true;
    return false;
}

pub fn isConstructor(name: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    for (constructors) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

pub fn isAsyncCallback(name: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    for (async_callbacks) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// "siv_window_set_title" -> "window_set_title".
pub fn luaName(s: Schema, name: []const u8) []const u8 {
    return name[s.prefix.len..];
}

/// "siv_node" -> "node".
pub fn stem(s: Schema, name: []const u8) []const u8 {
    return name[s.prefix.len..];
}

pub fn declKind(s: Schema, t: Type) ?std.meta.Tag(schema.Decl) {
    @setEvalBranchQuota(1_000_000);
    if (t != .ref) return null;
    const d = s.find(t.ref) orelse return null;
    return std.meta.activeTag(d);
}

pub fn isHandle(s: Schema, t: Type) bool {
    return declKind(s, t) == .handle;
}

pub fn isCallback(s: Schema, t: Type) bool {
    return declKind(s, t) == .callback;
}

pub fn isDestroy(t: Type) bool {
    return t == .ref and std.mem.eql(u8, t.ref, "siv_destroy_fn");
}

/// What a C parameter is on the Lua side.
pub const Role = enum {
    /// A Lua argument.
    input,
    /// A Lua function argument (or nil).
    callback,
    /// Filled by the binding: a destroy-notify or user_data.
    hidden,
    /// A return value.
    out,
    /// A return value: the string a buffer and its `len` fill.
    buffer,
    /// The `len` out parameter that goes with `buffer`.
    len,
};

pub fn role(s: Schema, f: Function, i: usize) Role {
    @setEvalBranchQuota(1_000_000);
    const p = f.params[i];
    return switch (p.type) {
        .user_data => .hidden,
        .buffer => .buffer,
        .out => |o| if (o.* == .usize and std.mem.eql(u8, p.name, "len") and hasBuffer(f)) .len else .out,
        .ref => if (isDestroy(p.type)) .hidden else if (isCallback(s, p.type)) .callback else .input,
        else => .input,
    };
}

fn hasBuffer(f: Function) bool {
    @setEvalBranchQuota(1_000_000);
    for (f.params) |p| if (p.type == .buffer) return true;
    return false;
}

/// The handle type a function is a method of: that of its first
/// parameter, if a handle.
pub fn owner(s: Schema, f: Function) ?[]const u8 {
    if (f.params.len == 0) return null;
    const t = f.params[0].type;
    if (!isHandle(s, t)) return null;
    return t.ref;
}

/// The method name: the Lua name without the owner's stem.
/// `siv_window_set_title` -> "set_title", `siv_flex` -> "flex".
pub fn methodName(s: Schema, f: Function) []const u8 {
    const n = luaName(s, f.name);
    const o = owner(s, f) orelse return n;
    const st = stem(s, o);
    if (n.len > st.len + 1 and std.mem.startsWith(u8, n, st) and n[st.len] == '_') return n[st.len + 1 ..];
    return n;
}

/// The one-shot completion callback parameter of an asynchronous
/// function, if it has one.
pub fn asyncParam(s: Schema, f: Function) ?usize {
    @setEvalBranchQuota(1_000_000);
    for (f.params, 0..) |p, i| if (role(s, f, i) == .callback and isAsyncCallback(p.type.ref)) return i;
    return null;
}

/// Number of Lua arguments before parameter `i` (counting a value struct
/// as one).
pub fn luaArgsBefore(s: Schema, f: Function, i: usize) usize {
    @setEvalBranchQuota(1_000_000);
    var n: usize = 0;
    for (0..i) |j| switch (role(s, f, j)) {
        .input, .callback => n += 1,
        else => {},
    };
    return n;
}

/// Builders return a node, or 0 once their transaction has failed.
pub fn isBuilder(s: Schema, f: Function) bool {
    return f.ret == .ref and std.mem.eql(u8, f.ret.ref, "siv_node") and f.params.len > 0 and
        isHandle(s, f.params[0].type) and std.mem.eql(u8, f.params[0].type.ref, "siv_txn");
}

/// The setter a builder's properties table key names: `layout` is
/// `siv_set_layout(txn, node, x)`. Null if there is none.
pub fn propertySetter(s: Schema, key: []const u8) ?Function {
    @setEvalBranchQuota(1_000_000);
    for (s.functions) |f| {
        if (isUnbound(f.name)) continue;
        if (!std.mem.startsWith(u8, f.name, "siv_set_")) continue;
        if (!std.mem.eql(u8, f.name["siv_set_".len..], key)) continue;
        // siv_set_<key>(txn, node, value): one value, so that the key's
        // value is the setter's argument.
        if (f.params.len != 3 or !std.mem.eql(u8, f.params[0].name, "txn") or !std.mem.eql(u8, f.params[1].name, "node")) continue;
        return f;
    }
    return null;
}

/// Value structs whose fields are all floats take one number for every
/// field (`padding = 8`, `radius = 4`).
pub const uniform_structs = [_][]const u8{ "siv_edges", "siv_corners", "siv_radii" };

pub fn isUniform(name: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    for (uniform_structs) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Value structs `{unit, value}` where a plain number means pixels
/// (`width = 200`).
pub fn isPxDimension(name: []const u8) bool {
    return std.mem.eql(u8, name, "siv_dimension") or std.mem.eql(u8, name, "siv_track");
}

/// Checks the tables above against the schema. Returns the first problem.
pub fn validate(comptime s: Schema) ?[]const u8 {
    @setEvalBranchQuota(100_000_000);
    for (unbound) |u| if (!hasFunction(s, u[0])) return "unbound lists a function the schema lacks";
    for (unbound_fields) |u| {
        const d = s.find(u[0]) orelse return "unbound_fields lists a struct the schema lacks";
        if (d != .@"struct") return "unbound_fields lists a non-struct";
        for (d.@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, u[1])) break;
        } else return "unbound_fields lists a field the schema lacks";
    }
    for (async_callbacks) |n| if (declKind(s, .{ .ref = n }) != .callback) return "async_callbacks lists a non-callback";
    for (constructors) |n| if (!hasFunction(s, n)) return "constructors lists a function the schema lacks";
    for (s.decls) |d| switch (d) {
        .handle => |h| {
            var found = false;
            for (owned) |o| if (std.mem.eql(u8, o[0], h.name)) {
                if (!hasFunction(s, o[1])) return "an owned handle's destroy function is missing";
                found = true;
            };
            for (borrowed) |n| if (std.mem.eql(u8, n, h.name)) {
                found = true;
            };
            if (!found) return "a handle is neither owned nor borrowed (src/lua/mapping.zig)";
        },
        .@"struct" => |st| {
            // Callbacks reach Lua through a box that the destroy-notify
            // releases.
            var callbacks = false;
            var destroy = false;
            for (st.fields) |f| {
                if (isDestroy(f.type)) destroy = true else if (isCallback(s, f.type) and !isUnboundField(st.name, f.name)) callbacks = true;
            }
            if (callbacks and !destroy and !std.mem.eql(u8, st.name, "siv_allocator")) return "a struct with callbacks lacks a destroy-notify";
        },
        else => {},
    };
    var keys: [s.functions.len][]const u8 = undefined;
    for (s.functions, 0..) |f, i| keys[i] = (if (owner(s, f)) |o| o else "") ++ "." ++ methodName(s, f);
    for (s.functions, 0..) |f, i| {
        if (isUnbound(f.name)) continue;
        // Method names are unique per owner.
        for (s.functions[0..i], 0..) |g, j| {
            if (!isUnbound(g.name) and std.mem.eql(u8, keys[i], keys[j])) return "two functions map to the same method";
        }
        var callbacks: usize = 0;
        var destroys: usize = 0;
        for (f.params, 0..) |p, j| {
            switch (role(s, f, j)) {
                .callback => callbacks += 1,
                .hidden => if (isDestroy(p.type)) {
                    destroys += 1;
                },
                .input => switch (p.type) {
                    .pointer => return "a bound function takes a pointer",
                    .out, .buffer, .user_data => unreachable,
                    else => {},
                },
                else => {},
            }
        }
        if (callbacks > 1) return "a function takes more than one callback";
        if (callbacks == 1 and destroys != 1) return "a function's callback lacks a destroy-notify";
    }
    return null;
}

fn hasFunction(s: Schema, name: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    for (s.functions) |f| if (std.mem.eql(u8, f.name, name)) return true;
    return false;
}

test "the mapping tables match the schema" {
    if (comptime validate(spec)) |p| {
        std.debug.print("src/lua/mapping.zig: {s}\n", .{p});
        return error.InvalidMapping;
    }
}

test "names" {
    const s = spec;
    var f = for (s.functions) |f| {
        if (std.mem.eql(u8, f.name, "siv_window_set_title")) break f;
    } else unreachable;
    try std.testing.expectEqualStrings("siv_window", owner(s, f).?);
    try std.testing.expectEqualStrings("set_title", methodName(s, f));
    f = for (s.functions) |g| {
        if (std.mem.eql(u8, g.name, "siv_flex")) break g;
    } else unreachable;
    try std.testing.expectEqualStrings("siv_txn", owner(s, f).?);
    try std.testing.expectEqualStrings("flex", methodName(s, f));
    try std.testing.expect(isBuilder(s, f));
    f = for (s.functions) |g| {
        if (std.mem.eql(u8, g.name, "siv_app_create")) break g;
    } else unreachable;
    try std.testing.expectEqual(null, owner(s, f));
    try std.testing.expectEqual(Role.out, role(s, f, 1));
    try std.testing.expectEqualStrings("layout", propertySetter(s, "layout").?.name["siv_set_".len..]);
    try std.testing.expectEqual(null, propertySetter(s, "data"));
}
