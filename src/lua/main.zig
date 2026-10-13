//! siv-lua: runs a Lua application (D23).
//!
//!     siv-lua [--watch] app.lua [args...]
//!
//! --watch reloads the application when it or a Lua module it required
//! changes (see siv.reload).

const std = @import("std");

const State = opaque {};
extern fn siv_lua_new(libs: c_int) ?*State;
extern fn siv_lua_run(L: *State, path: [*:0]const u8, argc: c_int, argv: [*]const ?[*:0]const u8, flags: c_uint) c_int;
extern fn lua_close(L: *State) void;

const usage = "usage: siv-lua [--watch] app.lua [args...]\n";

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    var i: usize = 1;
    var flags: c_uint = 0;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "--watch")) {
            flags |= 1;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(usage, .{});
            return 0;
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("siv-lua: unknown option {s}\n" ++ usage, .{a});
            return 2;
        } else break;
    }
    if (i >= argv.len) {
        std.debug.print(usage, .{});
        return 2;
    }
    const L = siv_lua_new(~@as(c_int, 0)) orelse {
        std.debug.print("siv-lua: out of memory\n", .{});
        return 1;
    };
    defer lua_close(L);
    const rest = argv[i + 1 ..];
    const status = siv_lua_run(L, argv[i], @intCast(rest.len), @ptrCast(rest.ptr), flags);
    return @intCast(status);
}
