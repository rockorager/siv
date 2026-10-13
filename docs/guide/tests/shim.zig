//! Writes a copy of the generated Zig wrapper (share/siv/siv.zig) in
//! which four C functions are the guide harness's instead: siv_app_create,
//! siv_window_create, siv_app_run, and siv_app_dispatch call guide_app_create
//! and so on (tests/guide.zig), which pick the headless backend and run
//! the test's scenario. The Zig samples import this copy in the test
//! binary and the real wrapper as programs, so they run unchanged.
//!
//! Usage: guide-shim <siv.zig> <output>

const std = @import("std");

const renamed = [_][]const u8{ "app_create", "window_create", "app_run", "app_dispatch" };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.log.err("usage: {s} <siv.zig> <output>", .{args[0]});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    var source = try cwd.readFileAlloc(io, args[1], arena, .limited(16 << 20));
    for (renamed) |name| {
        const old = try std.fmt.allocPrint(arena, "pub extern fn siv_{s}(", .{name});
        const new = try std.fmt.allocPrint(arena, "pub const siv_{s} = guide_{s};\n    pub extern fn guide_{s}(", .{ name, name, name });
        if (std.mem.count(u8, source, old) != 1) {
            std.log.err("expected one declaration of siv_{s} in {s}", .{ name, args[1] });
            std.process.exit(1);
        }
        source = try std.mem.replaceOwned(u8, arena, source, old, new);
    }
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = source });
}
