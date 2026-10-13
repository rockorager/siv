//! Writes libsiv-lua's NOTICES (D25): siv's licence, the Zig runtime's,
//! and, when Lua is compiled in, Lua's, which lua.h carries in its final
//! comment (the release tarball has no licence file).
//!
//! Usage: siv-lua-notices <output> <siv LICENSE> <Zig LICENSE> [lua.h]

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4 and args.len != 5) {
        std.log.err("usage: {s} <output> <siv LICENSE> <Zig LICENSE> [lua.h]", .{args[0]});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    var w: std.Io.Writer.Allocating = .init(arena);
    const out = &w.writer;
    try out.writeAll("Notices for libsiv-lua and siv-lua, which link libsiv (see its NOTICES).\n");
    try section(out, "siv (MIT)", try cwd.readFileAlloc(io, args[2], arena, .limited(1 << 20)));
    try section(out, "Zig standard library, compiler-rt, and UBSan runtime (MIT)", try cwd.readFileAlloc(io, args[3], arena, .limited(1 << 20)));
    if (args.len == 5) {
        const header = try cwd.readFileAlloc(io, args[4], arena, .limited(1 << 20));
        try section(out, "Lua 5.5 (MIT)", try luaNotice(arena, header));
    }
    try cwd.writeFile(io, .{ .sub_path = args[1], .data = w.written() });
}

fn section(out: *std.Io.Writer, title: []const u8, body: []const u8) !void {
    try out.print("\n================================================================\n{s}\n================================================================\n\n{s}", .{ title, body });
    if (body.len == 0 or body[body.len - 1] != '\n') try out.writeByte('\n');
}

/// The copyright comment at the end of lua.h, without its frame.
fn luaNotice(arena: std.mem.Allocator, header: []const u8) ![]const u8 {
    const start = std.mem.lastIndexOf(u8, header, "* Copyright (C)") orelse return error.NoLuaNotice;
    const end = std.mem.indexOfPos(u8, header, start, "\n*****") orelse return error.NoLuaNotice;
    var w: std.Io.Writer.Allocating = .init(arena);
    var lines = std.mem.splitScalar(u8, header[start..end], '\n');
    while (lines.next()) |line| {
        const l = if (std.mem.startsWith(u8, line, "* ")) line[2..] else if (std.mem.eql(u8, line, "*")) "" else line;
        try w.writer.print("{s}\n", .{l});
    }
    return w.written();
}

test "the Lua notice comes out of lua.h" {
    const header =
        \\#endif
        \\/****
        \\* Copyright (C) 1994-2026 Lua.org, PUC-Rio.
        \\*
        \\* Permission is hereby granted.
        \\******************************************************************************/
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Copyright (C) 1994-2026 Lua.org, PUC-Rio.\n\nPermission is hereby granted.\n", try luaNotice(arena.allocator(), header));
}
