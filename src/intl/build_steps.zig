//! The intl module's part of the build graph (D21, D41), called from
//! build.zig: src/intl/gen.zig runs on the build host and writes the CLDR
//! calendar tables and the emoji catalogue from the pinned CLDR packages
//! (cldr_core, cldr_dates, cldr_numbers in build.zig.zon) and the emoji
//! data kept in src/intl/emoji; the module embeds what it writes.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn add(b: *std.Build, o: Options) *std.Build.Module {
    const gen = b.addExecutable(.{
        .name = "siv-intl-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/intl/gen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(gen);
    const cldr = run.addOutputFileArg("cldr.zig");
    const emoji = run.addOutputFileArg("emoji.zig");
    // Zig strips the npm tarballs' top-level package/ directory.
    run.addDirectoryArg(b.dependency("cldr_core", .{}).path("."));
    run.addDirectoryArg(b.dependency("cldr_dates", .{}).path("."));
    run.addDirectoryArg(b.dependency("cldr_numbers", .{}).path("."));
    run.addFileArg(b.path("src/intl/emoji/emoji-test.txt"));
    return b.createModule(.{
        .root_source_file = b.path("src/intl/intl.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        .pic = true,
        .imports = &.{
            .{ .name = "cldr_data", .module = b.createModule(.{ .root_source_file = cldr }) },
            .{ .name = "emoji_data", .module = b.createModule(.{ .root_source_file = emoji }) },
        },
    });
}
