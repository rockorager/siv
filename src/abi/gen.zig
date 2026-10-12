//! Build-time generator (D3). Usage: siv-abi-gen <install-dir> <build-dir>
//!
//! <install-dir> is installed under the prefix as is, so new outputs need no
//! build.zig change:
//!   include/siv.h            C header
//!   share/siv/siv.zig        Zig wrapper (also the `siv` module in build.zig)
//!   share/siv/siv.json       JSON description for external generators
//!   share/doc/siv/siv.md     reference documentation
//!
//! <build-dir> holds inputs of the build that are not installed:
//!   siv.map                  linker version script for libsiv.so
//!   sivtest.{h,zig,map}      the same for the ABI test library (test_api.zig)

const std = @import("std");
const build_options = @import("build_options");
const schema = @import("schema.zig");
const api = @import("api.zig");
const test_api = @import("test_api.zig");

const Generator = *const fn (std.mem.Allocator, *std.Io.Writer, schema.Schema, std.SemanticVersion) anyerror!void;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.log.err("usage: {s} <install-dir> <build-dir>", .{args[0]});
        std.process.exit(2);
    }
    const version = build_options.version;
    for ([_]schema.Schema{ api.spec, test_api.spec }) |s| {
        if (schema.validate(s, version)) |p| {
            std.log.err("{s}: {s}: {s}", .{ s.source, p.where, p.what });
            std.process.exit(1);
        }
    }

    var install = try std.Io.Dir.cwd().createDirPathOpen(io, args[1], .{});
    defer install.close(io);
    var build = try std.Io.Dir.cwd().createDirPathOpen(io, args[2], .{});
    defer build.close(io);

    const outputs = [_]struct { std.Io.Dir, []const u8, schema.Schema, Generator }{
        .{ install, "include/siv.h", api.spec, @import("gen/c.zig").write },
        .{ install, "share/siv/siv.zig", api.spec, @import("gen/zig.zig").write },
        .{ install, "share/siv/siv.json", api.spec, @import("gen/json.zig").write },
        .{ install, "share/doc/siv/siv.md", api.spec, @import("gen/doc.zig").write },
        .{ build, "siv.map", api.spec, @import("gen/map.zig").write },
        .{ build, "sivtest.h", test_api.spec, @import("gen/c.zig").write },
        .{ build, "sivtest.zig", test_api.spec, @import("gen/zig.zig").write },
        .{ build, "sivtest.map", test_api.spec, @import("gen/map.zig").write },
    };
    for (outputs) |o| {
        const dir, const path, const s, const generate = o;
        var w: std.Io.Writer.Allocating = .init(arena);
        try generate(arena, &w.writer, s, version);
        if (std.fs.path.dirname(path)) |sub| try dir.createDirPath(io, sub);
        try dir.writeFile(io, .{ .sub_path = path, .data = w.written() });
    }
}

test {
    _ = @import("gen/map.zig");
}
