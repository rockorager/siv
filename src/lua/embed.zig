//! The `siv-lua-static` module, for Zig programs that link siv statically
//! (the `siv-static` module) and embed Lua for their users' scripts: the
//! Lua 5.5 C API that libsiv-lua embeds, with helpers for the macros
//! translate-c cannot carry (src/lua/c.zig), and siv_lua.h's functions.
//! The module carries the binding and Lua as objects; their siv_* calls
//! resolve to libsiv.a in the program.

const c_zig = @import("c.zig");

/// The translated lua.h, lauxlib.h, and lualib.h.
pub const c = c_zig.c;
/// Helpers for Lua's macros (pop, pcall, pushString, ...).
pub const helpers = c_zig;
pub const State = c_zig.State;

pub extern fn luaopen_siv(L: ?*State) c_int;
pub extern fn siv_lua_new(libs: c_int) ?*State;
pub extern fn siv_lua_run(L: ?*State, path: [*:0]const u8, argc: c_int, argv: ?[*]const ?[*:0]const u8, flags: c_uint) c_int;
pub extern fn siv_lua_push_handle(L: ?*State, type: [*:0]const u8, handle: u64) c_int;

/// siv_lua_run: reload the main chunk when it or a module it required
/// changes.
pub const watch: c_uint = 1;
