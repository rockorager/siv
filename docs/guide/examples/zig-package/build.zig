//! A Zig program that depends on siv as a package.
//!
//!     zig build run

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Builds libsiv.so and the `siv` module: the Zig API generated from
    // the same schema as siv.h, linked against libsiv.so.
    const siv = b.dependency("siv", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "siv", .module = siv.module("siv") }},
        }),
    });
    b.installArtifact(exe);

    // Runs the program against the libsiv.so this build made.
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the program").dependOn(&run.step);
}
