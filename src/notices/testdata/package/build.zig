//! A package that depends on siv and installs its NOTICES, as the guide's
//! zig-package sample does. src/notices/build_steps.zig builds it in
//! `zig build test`: siv's builder and its dependencies' builders then
//! carry this package's path to them (D25).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const siv = b.dependency("siv", .{ .webview = false });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(siv.namedLazyPath("notices"), .prefix, "NOTICES").step);
}
