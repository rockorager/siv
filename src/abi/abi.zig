//! The C ABI (D1, D2): exported functions described by schema.zig. The
//! generated header (zig-out/include/siv.h) declares them.
//!
//! Imports: every internal module, build_options.

const std = @import("std");
const build_options = @import("build_options");
const schema = @import("schema.zig");

const version = build_options.version;

export fn siv_version() u32 {
    return schema.makeVersion(version.major, version.minor, version.patch);
}

// Every schema function must be exported from this file.
comptime {
    for (schema.functions) |f| {
        if (!@hasDecl(@This(), f.name)) @compileError("schema function not exported: " ++ f.name);
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "siv_version encodes the build version" {
    try std.testing.expectEqual(version.major, siv_version() >> 16);
    try std.testing.expectEqual(version.minor, siv_version() >> 8 & 0xff);
    try std.testing.expectEqual(version.patch, siv_version() & 0xff);
}
