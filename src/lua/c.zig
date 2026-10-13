//! The Lua 5.5 C API as translated from lua.h, lauxlib.h, and lualib.h,
//! with the macros translate-c cannot carry.

const std = @import("std");
pub const c = @import("lua_c");

pub const State = c.lua_State;
pub const CFunction = *const fn (?*State) callconv(.c) c_int;

pub const registry: c_int = -(std.math.maxInt(c_int) / 2 + 1000);
pub const ridx_mainthread: c.lua_Integer = c.LUA_RIDX_MAINTHREAD;

pub fn upvalue(i: c_int) c_int {
    return registry - i;
}

pub const tnone: c_int = -1;
pub const tnil: c_int = 0;
pub const tboolean: c_int = 1;
pub const tlightuserdata: c_int = 2;
pub const tnumber: c_int = 3;
pub const tstring: c_int = 4;
pub const ttable: c_int = 5;
pub const tfunction: c_int = 6;
pub const tuserdata: c_int = 7;
pub const tthread: c_int = 8;

pub const ok: c_int = 0;
pub const yield: c_int = 1;
pub const errrun: c_int = 2;
pub const errsyntax: c_int = 3;
pub const errmem: c_int = 4;
pub const errerr: c_int = 5;

pub const noref: c_int = -2;
pub const refnil: c_int = -1;
pub const multret: c_int = -1;

pub inline fn pop(L: *State, n: c_int) void {
    c.lua_settop(L, -n - 1);
}

pub inline fn newtable(L: *State) void {
    c.lua_createtable(L, 0, 0);
}

pub inline fn pushcfunction(L: *State, f: CFunction) void {
    c.lua_pushcclosure(L, f, 0);
}

pub inline fn typeOf(L: *State, i: c_int) c_int {
    return c.lua_type(L, i);
}

pub inline fn isnoneornil(L: *State, i: c_int) bool {
    return c.lua_type(L, i) <= 0;
}

pub inline fn insert(L: *State, i: c_int) void {
    c.lua_rotate(L, i, 1);
}

pub inline fn remove(L: *State, i: c_int) void {
    c.lua_rotate(L, i, -1);
    pop(L, 1);
}

pub inline fn replace(L: *State, i: c_int) void {
    c.lua_copy(L, -1, i);
    pop(L, 1);
}

pub inline fn call(L: *State, nargs: c_int, nresults: c_int) void {
    c.lua_callk(L, nargs, nresults, 0, null);
}

pub inline fn pcall(L: *State, nargs: c_int, nresults: c_int, msgh: c_int) c_int {
    return c.lua_pcallk(L, nargs, nresults, msgh, 0, null);
}

pub inline fn pushString(L: *State, s: []const u8) void {
    _ = c.lua_pushlstring(L, s.ptr, s.len);
}

pub fn toString(L: *State, i: c_int) ?[]const u8 {
    var len: usize = 0;
    const p = c.lua_tolstring(L, i, &len) orelse return null;
    return p[0..len];
}

/// Raises a Lua error with a formatted message, as luaL_error does.
pub fn raise(L: *State, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    c.luaL_where(L, 1);
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    pushString(L, msg);
    c.lua_concat(L, 2);
    _ = c.lua_error(L);
    unreachable;
}

/// Raises "bad argument #arg to 'fn' (msg)".
pub fn argError(L: *State, arg: c_int, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch "invalid value";
    _ = c.luaL_argerror(L, arg, msg.ptr);
    unreachable;
}

pub fn typeName(L: *State, i: c_int) []const u8 {
    return std.mem.span(c.lua_typename(L, c.lua_type(L, i)));
}
