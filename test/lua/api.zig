//! The Lua binding as the headless test binary reaches it: through its C
//! API. The binding is linked in as an object compiled from the generated
//! wrapper and the schema alone (src/lua/build_steps.zig), so a change in
//! siv does not compile it again; its siv_* calls resolve to the exports
//! in this binary.

const std = @import("std");

/// src/lua/c.zig: the translated Lua headers and helpers for their macros.
pub const helpers = @import("lua_helpers");
pub const c_api = helpers.c;
const State = helpers.State;

/// Whether Lua is the system's (-fsys=lua).
pub const system_lua = @import("lua_options").system_lua;

pub extern fn siv_lua_new(libs_mask: c_int) ?*State;
pub extern fn siv_lua_run(L: ?*State, path: [*:0]const u8, argc: c_int, argv: ?[*]const ?[*:0]const u8, flags: c_uint) c_int;
extern fn siv_lua_test_to_handle(L: *State, idx: c_int) u64;

/// The handle a binding userdata holds, 0 for anything else.
pub fn toHandle(L: *State, idx: c_int) u64 {
    return siv_lua_test_to_handle(L, idx);
}

/// Prints the error at `idx`, with its traceback when it has one.
pub fn printError(L: *State, idx: c_int) void {
    var len: usize = 0;
    const msg = c_api.luaL_tolstring(L, idx, &len);
    std.debug.print("{s}\n", .{msg[0..len]});
    helpers.pop(L, 1);
    if (c_api.lua_type(L, idx) == helpers.ttable) {
        if (c_api.lua_getfield(L, idx, "traceback") == helpers.tstring) std.debug.print("{s}\n", .{helpers.toString(L, -1).?});
        helpers.pop(L, 1);
    }
}
