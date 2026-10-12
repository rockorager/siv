//! The C ABI (D1, D2): the exports of libsiv, one per function in api.zig.
//! Their parameter and return types come from the generated Zig wrapper
//! (`siv`), which matches the generated header; the comptime block below
//! checks every export against its schema signature. Exports go through
//! runtime.zig for argument checking, roots, and handles. The application
//! and windows are in application.zig, the tree in tree.zig.
//!
//! Imports: every internal module, build_options, siv (generated).

const std = @import("std");
const build_options = @import("build_options");
const t = @import("siv");
const schema = @import("schema.zig");
const api = @import("api.zig");

pub const runtime = @import("runtime.zig");
pub const handles = @import("handles.zig");
pub const alloc = @import("alloc.zig");
/// The application, its loop, and windows.
pub const application = @import("application.zig");
/// Transactions, nodes, and node events.
pub const tree = @import("tree.zig");
/// Canvases, drawing, and images.
pub const canvas = @import("canvas.zig");
/// External content: submitted frames and embedder surfaces.
pub const external = @import("external.zig");
/// Drag and drop.
pub const dnd = @import("dnd.zig");

/// The generated wrapper's types, which the exports use.
pub const types = t;

/// The files that export schema functions.
const implementations = .{ @This(), application, tree, canvas, external, dnd };

const version = build_options.version;

pub export fn siv_version() u32 {
    return api.makeVersion(version.major, version.minor, version.patch);
}

pub export fn siv_result_name(result: t.Result) [*:0]const u8 {
    inline for (comptime resultNames()) |entry| {
        if (@backingInt(result) == entry[0]) return entry[1];
    }
    return "SIV_RESULT_UNKNOWN";
}

fn resultNames() [api.result.@"enum".values.len]struct { i32, [:0]const u8 } {
    const e = api.result.@"enum";
    var names: [e.values.len]struct { i32, [:0]const u8 } = undefined;
    var buf: [64]u8 = undefined;
    for (e.values, &names) |v, *n| n.* = .{ v.value, std.fmt.comptimePrint("{s}{s}", .{ e.value_prefix.?, schema.upper(&buf, v.name) }) };
    return names;
}

// Every schema function is exported here with the signature the schema
// implies, and the schema follows the conventions.
comptime {
    @setEvalBranchQuota(100_000);
    if (schema.validate(api.spec, version)) |p| @compileError(api.spec.source ++ ": " ++ p.where ++ ": " ++ p.what);
    for (api.spec.functions) |f| {
        var found = false;
        for (implementations) |impl| if (@hasDecl(impl, f.name)) {
            if (found) @compileError("schema function exported twice: " ++ f.name);
            found = true;
            if (@TypeOf(@field(impl, f.name)) != @field(t.signatures, f.name)) @compileError("export does not match its schema signature: " ++ f.name);
        };
        if (!found) @compileError("schema function not exported: " ++ f.name);
    }
    runtime.checkDescriptors(t);
}

test {
    std.testing.refAllDecls(@This());
    _ = schema;
}

test "siv_version encodes the build version" {
    try std.testing.expectEqual(version.major, siv_version() >> 16);
    try std.testing.expectEqual(version.minor, siv_version() >> 8 & 0xff);
    try std.testing.expectEqual(version.patch, siv_version() & 0xff);
}

test "siv_result_name" {
    try std.testing.expectEqualStrings("SIV_OK", std.mem.span(siv_result_name(.ok)));
    try std.testing.expectEqualStrings("SIV_ERROR_OUT_OF_MEMORY", std.mem.span(siv_result_name(.error_out_of_memory)));
    try std.testing.expectEqualStrings("SIV_RESULT_UNKNOWN", std.mem.span(siv_result_name(@fromBackingInt(-1000))));
}
