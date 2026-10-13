//! C header generator, and the C spelling of schema types that the JSON and
//! documentation generators reuse.

const std = @import("std");
const schema = @import("../schema.zig");
const Schema = schema.Schema;
const Type = schema.Type;
const Writer = std.Io.Writer;

/// One C parameter or field. A schema string expands to two.
pub const Decl = struct {
    type: []const u8,
    name: []const u8,

    pub fn format(d: Decl, w: *Writer) Writer.Error!void {
        const sep = if (std.mem.endsWith(u8, d.type, "*")) "" else " ";
        try w.print("{s}{s}{s}", .{ d.type, sep, d.name });
    }
};

/// The C declarations a parameter or field of type `t` named `name` becomes.
pub fn decls(arena: std.mem.Allocator, t: Type, name: []const u8) ![]const Decl {
    switch (t) {
        .string => return arena.dupe(Decl, &.{
            .{ .type = "const char *", .name = name },
            .{ .type = "size_t", .name = try std.fmt.allocPrint(arena, "{s}_len", .{name}) },
        }),
        .array => |e| return arena.dupe(Decl, &.{
            .{ .type = try std.fmt.allocPrint(arena, "const {s} *", .{try typeName(arena, e.*)}), .name = name },
            .{ .type = "size_t", .name = try std.fmt.allocPrint(arena, "{s}_count", .{name}) },
        }),
        .buffer => return arena.dupe(Decl, &.{
            .{ .type = "char *", .name = name },
            .{ .type = "size_t", .name = try std.fmt.allocPrint(arena, "{s}_cap", .{name}) },
        }),
        else => {},
    }
    return arena.dupe(Decl, &.{.{ .type = try typeName(arena, t), .name = name }});
}

/// The C spelling of a type that is a single C value.
pub fn typeName(arena: std.mem.Allocator, t: Type) ![]const u8 {
    return switch (t) {
        .void => "void",
        .bool => "bool",
        .u8 => "uint8_t",
        .u16 => "uint16_t",
        .u32 => "uint32_t",
        .u64 => "uint64_t",
        .i8 => "int8_t",
        .i16 => "int16_t",
        .i32 => "int32_t",
        .i64 => "int64_t",
        .f32 => "float",
        .f64 => "double",
        .usize => "size_t",
        .ref => |n| n,
        .string, .array, .buffer => unreachable,
        .static_string => "const char *",
        .user_data, .pointer => "void *",
        .desc => |n| try std.fmt.allocPrint(arena, "const {s} *", .{n}),
        .out => |o| try std.fmt.allocPrint(arena, "{s} *", .{try typeName(arena, o.*)}),
    };
}

/// A function or callback parameter list, "void" when empty.
pub fn paramList(arena: std.mem.Allocator, w: *Writer, leading_user_data: bool, params: []const schema.Param) !void {
    var first = true;
    if (leading_user_data) {
        try w.writeAll("void *user_data");
        first = false;
    }
    for (params) |p| for (try decls(arena, p.type, p.name)) |d| {
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("{f}", .{d});
    };
    if (first) try w.writeAll("void");
}

/// The prototype of a function, without the trailing semicolon.
pub fn prototype(arena: std.mem.Allocator, w: *Writer, f: schema.Function) !void {
    try w.print("{f}(", .{Decl{ .type = try typeName(arena, f.ret), .name = f.name }});
    try paramList(arena, w, false, f.params);
    try w.writeAll(")");
}

pub fn write(arena: std.mem.Allocator, w: *Writer, s: Schema, version: std.SemanticVersion) !void {
    var ubuf: [128]u8 = undefined;
    const up = try arena.dupe(u8, schema.upper(&ubuf, s.name));

    try w.print(
        \\/* Generated from {[source]s} by src/abi/gen.zig. Do not edit. */
        \\/* {[doc]s} */
        \\#ifndef {[up]s}_H
        \\#define {[up]s}_H
        \\
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\extern "C" {{
        \\#endif
        \\
        \\#define {[up]s}_MAKE_VERSION(major, minor, patch) \
        \\    ((uint32_t)(major) << 16 | (uint32_t)(minor) << 8 | (uint32_t)(patch))
        \\#define {[up]s}_VERSION_MAJOR {[major]d}
        \\#define {[up]s}_VERSION_MINOR {[minor]d}
        \\#define {[up]s}_VERSION_PATCH {[patch]d}
        \\#define {[up]s}_VERSION {[up]s}_MAKE_VERSION({[up]s}_VERSION_MAJOR, {[up]s}_VERSION_MINOR, {[up]s}_VERSION_PATCH)
        \\
        \\/* Marks functions whose result must be checked. */
        \\#if defined(__GNUC__) || defined(__clang__)
        \\#define {[up]s}_NODISCARD __attribute__((warn_unused_result))
        \\#else
        \\#define {[up]s}_NODISCARD
        \\#endif
        \\
        \\/* A pointer to a descriptor with its size set and the given fields;
        \\ * every other field is zero, which means default:
        \\ *     {[up]s}_DESC(type, .field = value, ...) */
        \\#ifndef __cplusplus
        \\#define {[up]s}_DESC(type, ...) (&(type){{ .size = sizeof(type), __VA_ARGS__ }})
        \\#endif
        \\
    , .{ .source = s.source, .doc = s.doc, .up = up, .major = version.major, .minor = version.minor, .patch = version.patch });

    for (s.decls) |d| {
        try w.writeAll("\n");
        try comment(w, "", d.doc());
        switch (d) {
            .handle => |h| try w.print("typedef uint64_t {s};\n", .{h.name}),
            .@"enum" => |e| {
                var pbuf: [128]u8 = undefined;
                const prefix = schema.enumValuePrefix(&pbuf, e);
                if (e.open) try w.writeAll("/* An open enum: values other than those named are valid. */\n");
                try w.print("typedef enum {s} {{\n", .{e.name});
                for (e.values) |v| {
                    try comment(w, "    ", v.doc);
                    try w.print("    {s}{s} = {d},\n", .{ prefix, schema.upper(&ubuf, v.name), v.value });
                }
                try w.print("    {s}_MAX_ENUM = 0x7fffffff\n}} {s};\n", .{ schema.upper(&ubuf, e.name), e.name });
            },
            .flags => |f| {
                var pbuf: [128]u8 = undefined;
                const prefix = schema.flagsValuePrefix(&pbuf, f);
                try w.print("typedef uint32_t {s};\n", .{f.name});
                for (f.bits) |b| {
                    try comment(w, "", b.doc);
                    try w.print("#define {s}{s} (({s})1u << {d})\n", .{ prefix, schema.upper(&ubuf, b.name), f.name, b.bit });
                }
            },
            .@"struct" => |st| {
                try w.print("typedef struct {s} {{\n", .{st.name});
                if (st.kind == .descriptor) {
                    try w.print("    /** sizeof({s}); {s}_DESC sets it. */\n    size_t size;\n", .{ st.name, up });
                }
                for (st.fields) |f| {
                    try comment(w, "    ", f.doc);
                    for (try decls(arena, f.type, f.name)) |cd| try w.print("    {f};\n", .{cd});
                }
                try w.print("}} {s};\n", .{st.name});
            },
            .callback => |cb| {
                try w.print("typedef {s}", .{try typeName(arena, cb.ret)});
                if (!std.mem.endsWith(u8, try typeName(arena, cb.ret), "*")) try w.writeAll(" ");
                try w.print("(*{s})(", .{cb.name});
                try paramList(arena, w, true, cb.params);
                try w.writeAll(");\n");
            },
        }
    }

    for (s.functions) |f| {
        try w.writeAll("\n");
        try w.print("/**\n * {s}\n", .{f.doc});
        if (f.params.len > 0) try w.writeAll(" *\n");
        for (f.params) |p| try w.print(" * {s}: {s}\n", .{ p.name, p.doc });
        try w.writeAll(" */\n");
        if (s.isResult(f.ret) and f.must_use) try w.print("{s}_NODISCARD ", .{up});
        try prototype(arena, w, f);
        try w.writeAll(";\n");
    }

    try w.print(
        \\
        \\#ifdef __cplusplus
        \\}}
        \\#endif
        \\
        \\#endif /* {s}_H */
        \\
    , .{up});
}

fn comment(w: *Writer, indent: []const u8, text: []const u8) !void {
    try w.print("{s}/** {s} */\n", .{ indent, text });
}
