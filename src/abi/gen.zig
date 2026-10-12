//! Build-time generator: writes the C header (and later the other bindings)
//! from schema.zig into the directory given as the only argument. build.zig
//! installs that directory under the prefix as is, so new outputs need no
//! build.zig change.

const std = @import("std");
const build_options = @import("build_options");
const schema = @import("schema.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.log.err("usage: {s} <output-dir>", .{args[0]});
        std.process.exit(2);
    }

    var out = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer out.close(init.io);
    try out.createDirPath(init.io, "include");
    try out.writeFile(init.io, .{ .sub_path = "include/siv.h", .data = try header(arena) });
}

fn header(arena: std.mem.Allocator) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    const version = build_options.version;
    try w.writer.print(
        \\/* Generated from src/abi/schema.zig. Do not edit. */
        \\#ifndef SIV_H
        \\#define SIV_H
        \\
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\extern "C" {{
        \\#endif
        \\
        \\#define SIV_MAKE_VERSION(major, minor, patch) \
        \\    ((uint32_t)(major) << 16 | (uint32_t)(minor) << 8 | (uint32_t)(patch))
        \\#define SIV_VERSION_MAJOR {d}
        \\#define SIV_VERSION_MINOR {d}
        \\#define SIV_VERSION_PATCH {d}
        \\#define SIV_VERSION SIV_MAKE_VERSION(SIV_VERSION_MAJOR, SIV_VERSION_MINOR, SIV_VERSION_PATCH)
        \\
    , .{ version.major, version.minor, version.patch });

    for (schema.functions) |f| {
        try w.writer.print("\n/* {s} */\n{s} {s}(", .{ f.doc, f.ret.c(), f.name });
        if (f.params.len == 0) try w.writer.writeAll("void");
        for (f.params, 0..) |p, i| {
            if (i > 0) try w.writer.writeAll(", ");
            try w.writer.print("{s} {s}", .{ p.type.c(), p.name });
        }
        try w.writer.writeAll(");\n");
    }

    try w.writer.writeAll(
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* SIV_H */
        \\
    );
    return w.written();
}
