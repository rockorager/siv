//! Linker version script generator. The script exports exactly the schema's
//! functions, each under its version node (schema.versionNode), and makes
//! every other symbol local, including runtime symbols such as UBSan's.

const std = @import("std");
const schema = @import("../schema.zig");
const Schema = schema.Schema;

pub fn write(arena: std.mem.Allocator, w: *std.Io.Writer, s: Schema, version: std.SemanticVersion) !void {
    // Nodes in ascending order; each inherits from the previous one.
    var nodes: std.ArrayList([]const u8) = .empty;
    var buf: [64]u8 = undefined;
    for (s.functions) |f| {
        const n = schema.versionNode(&buf, s, version, f);
        for (nodes.items) |m| {
            if (std.mem.eql(u8, m, n)) break;
        } else try nodes.append(arena, try arena.dupe(u8, n));
    }
    std.mem.sort([]const u8, nodes.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return order(a, b) == .lt;
        }
    }.lessThan);

    try w.print("/* Generated from {s} by src/abi/gen.zig. Do not edit. */\n", .{s.source});
    for (nodes.items, 0..) |node, i| {
        try w.print("{s} {{\n  global:\n", .{node});
        for (s.functions) |f| {
            if (std.mem.eql(u8, schema.versionNode(&buf, s, version, f), node)) try w.print("    {s};\n", .{f.name});
        }
        if (i == 0) try w.writeAll("  local:\n    *;\n");
        try w.writeAll("}");
        if (i > 0) try w.print(" {s}", .{nodes.items[i - 1]});
        try w.writeAll(";\n");
    }
}

/// Orders "NAME_major.minor" numerically.
fn order(a: []const u8, b: []const u8) std.math.Order {
    const pa = parse(a);
    const pb = parse(b);
    return pa.order(pb);
}

fn parse(node: []const u8) schema.Version {
    const us = std.mem.lastIndexOfScalar(u8, node, '_').?;
    var it = std.mem.splitScalar(u8, node[us + 1 ..], '.');
    return .{
        .major = std.fmt.parseInt(u16, it.next().?, 10) catch unreachable,
        .minor = std.fmt.parseInt(u16, it.next().?, 10) catch unreachable,
    };
}

test "nodes from 1.0 on chain by the version that added each symbol" {
    const v1_0: schema.Version = .{ .major = 1, .minor = 0 };
    const v1_2: schema.Version = .{ .major = 1, .minor = 2 };
    const s: Schema = .{ .name = "x", .prefix = "x_", .source = "t", .doc = "", .result = "", .decls = &.{}, .functions = &.{
        .{ .name = "x_new", .doc = "", .since = v1_2 },
        .{ .name = "x_old", .doc = "", .since = v1_0 },
    } };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try write(arena.allocator(), &out.writer, s, .{ .major = 1, .minor = 2, .patch = 0 });
    try std.testing.expectEqualStrings(
        \\/* Generated from t by src/abi/gen.zig. Do not edit. */
        \\X_1.0 {
        \\  global:
        \\    x_old;
        \\  local:
        \\    *;
        \\};
        \\X_1.2 {
        \\  global:
        \\    x_new;
        \\} X_1.0;
        \\
    , out.written());

    out.clearRetainingCapacity();
    try write(arena.allocator(), &out.writer, s, .{ .major = 0, .minor = 3, .patch = 1 });
    try std.testing.expectEqualStrings(
        \\/* Generated from t by src/abi/gen.zig. Do not edit. */
        \\X_0.3 {
        \\  global:
        \\    x_new;
        \\    x_old;
        \\  local:
        \\    *;
        \\};
        \\
    , out.written());
}
