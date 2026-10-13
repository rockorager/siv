//! Zig wrapper generator. The wrapper has three layers:
//!
//! - ABI types (extern structs, `enum(u64)` handles, non-exhaustive enums,
//!   `packed struct(u32)` flags) that match the C header exactly. libsiv's
//!   own implementation uses these types too, so the exports and the
//!   wrapper cannot disagree.
//! - `signatures` and `c`: the C function types and their extern
//!   declarations.
//! - Idiomatic functions: error unions instead of result codes, slices
//!   instead of pointer and length, a single trailing out parameter
//!   returned.

const std = @import("std");
const schema = @import("../schema.zig");
const Schema = schema.Schema;
const Type = schema.Type;
const Writer = std.Io.Writer;
const id = std.zig.fmtId;

pub fn write(arena: std.mem.Allocator, w: *Writer, s: Schema, version: std.SemanticVersion) !void {
    var nbuf: [128]u8 = undefined;
    try w.print(
        \\//! Generated from {s} by src/abi/gen.zig. Do not edit.
        \\//! {s}
        \\
        \\const std = @import("std");
        \\
        \\/// The version of the headers this wrapper was generated from.
        \\pub const header_version: std.SemanticVersion = .{{ .major = {d}, .minor = {d}, .patch = {d} }};
        \\
    , .{ s.source, s.doc, version.major, version.minor, version.patch });

    for (s.decls) |d| {
        try w.print("\n/// {s}\n", .{d.doc()});
        const tn = try arena.dupe(u8, schema.zigTypeName(&nbuf, d.name()));
        switch (d) {
            .handle => try w.print("pub const {f} = enum(u64) {{ null = 0, _ }};\n", .{id(tn)}),
            .@"enum" => |e| {
                try w.print("pub const {f} = enum(i32) {{\n", .{id(tn)});
                for (e.values) |v| try w.print("    /// {s}\n    {f} = {d},\n", .{ v.doc, id(v.name), v.value });
                try w.writeAll("    _,\n");
                if (e.open) try w.writeAll("\n    /// Open: values other than those named are valid (runtime.enumValue passes them).\n    pub const open = true;\n");
                try w.writeAll("};\n");
            },
            .flags => |f| {
                try w.print("pub const {f} = packed struct(u32) {{\n", .{id(tn)});
                var known: u32 = 0;
                var bit: u6 = 0;
                while (bit < 32) {
                    const flag = for (f.bits) |b| {
                        if (b.bit == bit) break b;
                    } else null;
                    if (flag) |b| {
                        try w.print("    /// {s}\n    {f}: bool = false,\n", .{ b.doc, id(b.name) });
                        known |= @as(u32, 1) << b.bit;
                        bit += 1;
                    } else {
                        var end = bit;
                        while (end < 32 and for (f.bits) |b| {
                            if (b.bit == end) break false;
                        } else true) end += 1;
                        try w.print("    _bit{d}: u{d} = 0,\n", .{ bit, end - bit });
                        bit = end;
                    }
                }
                try w.print("\n    /// Every bit this version defines.\n    pub const known_bits: u32 = 0x{x};\n}};\n", .{known});
            },
            .@"struct" => |st| {
                try w.print("pub const {f} = extern struct {{\n", .{id(tn)});
                if (st.kind == .descriptor) try w.print("    size: usize = @sizeOf({f}),\n", .{id(tn)});
                for (st.fields) |f| {
                    try w.print("    /// {s}\n", .{f.doc});
                    if (f.type == .string) {
                        try w.print("    {f}: ?[*]const u8 = null,\n    {f}: usize = 0,\n", .{ id(f.name), id(try std.fmt.allocPrint(arena, "{s}_len", .{f.name})) });
                    } else if (f.type == .array) {
                        try w.print("    {f}: ?[*]const {s} = null,\n    {f}: usize = 0,\n", .{ id(f.name), try typeName(arena, s, f.type.array.*), id(try std.fmt.allocPrint(arena, "{s}_count", .{f.name})) });
                    } else {
                        try w.print("    {f}: {s} = {s},\n", .{ id(f.name), try typeName(arena, s, f.type), try zero(s, f.type) });
                    }
                }
                if (st.kind == .descriptor) try w.writeAll("\n    /// Size-prefixed and extensible; see runtime.readDesc.\n    pub const descriptor = true;\n");
                var any_reserved = false;
                for (st.fields) |f| any_reserved = any_reserved or f.reserved;
                if (any_reserved) {
                    try w.writeAll("    /// Fields that must be zero (runtime.readDesc rejects others).\n    pub const reserved = .{");
                    for (st.fields) |f| if (f.reserved) try w.print(" \"{s}\",", .{f.name});
                    try w.writeAll(" };\n");
                }
                try w.writeAll("};\n");
            },
            .callback => |cb| {
                try w.print("pub const {f} = *const fn (user_data: ?*anyopaque", .{id(tn)});
                for (cb.params) |p| try writeParam(arena, w, s, p, ", ");
                try w.print(") callconv(.c) {s};\n", .{try typeName(arena, s, cb.ret)});
            },
        }
    }

    try w.writeAll("\n/// The C function types.\npub const signatures = struct {\n");
    for (s.functions) |f| {
        try w.print("    pub const {s} = fn (", .{f.name});
        try writeParams(arena, w, s, f.params);
        try w.print(") callconv(.c) {s};\n", .{try typeName(arena, s, f.ret)});
    }
    try w.writeAll("};\n\n/// The C functions.\npub const c = struct {\n");
    for (s.functions) |f| {
        try w.print("    /// {s}\n    pub extern fn {s}(", .{ f.doc, f.name });
        try writeParams(arena, w, s, f.params);
        try w.print(") {s};\n", .{try typeName(arena, s, f.ret)});
    }
    try w.writeAll("};\n");

    // Result codes as Zig errors.
    const result = s.get(s.result).@"enum";
    const result_type = try arena.dupe(u8, schema.zigTypeName(&nbuf, s.result));
    try w.writeAll("\n/// The error results as Zig errors.\npub const AbiError = error{\n");
    for (result.values) |v| if (v.value != 0) try w.print("    {s},\n", .{schema.pascal(&nbuf, v.name["error_".len..])});
    try w.writeAll(
        \\};
        \\
        \\/// AbiError, and error.Unexpected for a result this version does not define.
        \\pub const Error = AbiError || error{Unexpected};
        \\
        \\
    );
    try w.print("/// Converts a result code into an error.\npub fn check(result: {s}) Error!void {{\n    return switch (result) {{\n", .{result_type});
    for (result.values) |v| {
        if (v.value == 0) {
            try w.print("        .{f} => {{}},\n", .{id(v.name)});
        } else {
            try w.print("        .{f} => error.{s},\n", .{ id(v.name), schema.pascal(&nbuf, v.name["error_".len..]) });
        }
    }
    try w.writeAll("        _ => error.Unexpected,\n    };\n}\n\n");
    try w.print("/// Converts an error into its result code.\npub fn resultOf(err: AbiError) {s} {{\n    return switch (err) {{\n", .{result_type});
    for (result.values) |v| if (v.value != 0) try w.print("        error.{s} => .{f},\n", .{ schema.pascal(&nbuf, v.name["error_".len..]), id(v.name) });
    try w.writeAll("    };\n}\n");

    // Idiomatic functions.
    for (s.functions) |f| {
        const fallible = s.isResult(f.ret);
        const ret_out: ?schema.Param = if (fallible and f.params.len > 0 and f.params[f.params.len - 1].type == .out and
            (f.params.len < 2 or f.params[f.params.len - 2].type != .out)) f.params[f.params.len - 1] else null;
        const params = if (ret_out != null) f.params[0 .. f.params.len - 1] else f.params;

        try w.print("\n/// {s}\npub fn {f}(", .{ f.doc, id(schema.zigFnName(&nbuf, f.name)) });
        for (params, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            const pn = try argName(arena, s, p.name);
            if (p.type == .string) {
                try w.print("{f}: []const u8", .{id(pn)});
            } else if (p.type == .array) {
                try w.print("{f}: []const {s}", .{ id(pn), try typeName(arena, s, p.type.array.*) });
            } else if (p.type == .buffer) {
                try w.print("{f}: []u8", .{id(pn)});
            } else {
                try w.print("{f}: {s}", .{ id(pn), try typeName(arena, s, p.type) });
            }
        }
        try w.writeAll(") ");
        if (fallible) {
            try w.print("Error!{s}", .{if (ret_out) |o| try typeName(arena, s, o.type.out.*) else "void"});
        } else if (f.ret == .static_string) {
            try w.writeAll("[:0]const u8");
        } else {
            try w.writeAll(try typeName(arena, s, f.ret));
        }
        try w.writeAll(" {\n");
        if (ret_out) |o| try w.print("    var {f}: {s} = undefined;\n", .{ id(try argName(arena, s, o.name)), try typeName(arena, s, o.type.out.*) });
        try w.writeAll("    ");
        if (fallible) {
            try w.writeAll("try check(");
        } else if (f.ret == .static_string) {
            try w.writeAll("return std.mem.span(");
        } else {
            try w.writeAll("return ");
        }
        try w.print("c.{s}(", .{f.name});
        for (f.params, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            const pn = try argName(arena, s, p.name);
            if (p.type == .string or p.type == .array or p.type == .buffer) {
                try w.print("{f}.ptr, {f}.len", .{ id(pn), id(pn) });
            } else if (ret_out != null and i == f.params.len - 1) {
                try w.print("&{f}", .{id(pn)});
            } else {
                try w.print("{f}", .{id(pn)});
            }
        }
        try w.writeAll(if (fallible or f.ret == .static_string) "));\n" else ");\n");
        if (ret_out) |o| try w.print("    return {f};\n", .{id(try argName(arena, s, o.name))});
        try w.writeAll("}\n");
    }
}

/// A parameter name in an idiomatic function, renamed when it would
/// shadow one of the wrapper's own declarations (Zig forbids shadowing).
fn argName(arena: std.mem.Allocator, s: Schema, name: []const u8) ![]const u8 {
    var nbuf: [128]u8 = undefined;
    const reserved = [_][]const u8{ "std", "c", "signatures", "check", "resultOf", "header_version" };
    for (reserved) |r| if (std.mem.eql(u8, r, name)) return std.fmt.allocPrint(arena, "{s}_arg", .{name});
    for (s.functions) |f| if (std.mem.eql(u8, schema.zigFnName(&nbuf, f.name), name)) return std.fmt.allocPrint(arena, "{s}_arg", .{name});
    return name;
}

fn writeParams(arena: std.mem.Allocator, w: *Writer, s: Schema, params: []const schema.Param) !void {
    for (params, 0..) |p, i| try writeParam(arena, w, s, p, if (i == 0) "" else ", ");
}

fn writeParam(arena: std.mem.Allocator, w: *Writer, s: Schema, p: schema.Param, sep: []const u8) !void {
    if (p.type == .string) {
        try w.print("{s}{f}: ?[*]const u8, {f}: usize", .{ sep, id(p.name), id(try std.fmt.allocPrint(arena, "{s}_len", .{p.name})) });
    } else if (p.type == .array) {
        try w.print("{s}{f}: ?[*]const {s}, {f}: usize", .{ sep, id(p.name), try typeName(arena, s, p.type.array.*), id(try std.fmt.allocPrint(arena, "{s}_count", .{p.name})) });
    } else if (p.type == .buffer) {
        try w.print("{s}{f}: ?[*]u8, {f}: usize", .{ sep, id(p.name), id(try std.fmt.allocPrint(arena, "{s}_cap", .{p.name})) });
    } else {
        try w.print("{s}{f}: {s}", .{ sep, id(p.name), try typeName(arena, s, p.type) });
    }
}

/// The Zig spelling of a type that is a single C value.
fn typeName(arena: std.mem.Allocator, s: Schema, t: Type) ![]const u8 {
    var nbuf: [128]u8 = undefined;
    return switch (t) {
        .void, .bool, .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f32, .f64, .usize => @tagName(t),
        .ref => |n| blk: {
            const tn = try std.fmt.allocPrint(arena, "{f}", .{id(schema.zigTypeName(&nbuf, n))});
            break :blk if (s.get(n) == .callback) try std.fmt.allocPrint(arena, "?{s}", .{tn}) else tn;
        },
        .string, .array, .buffer => unreachable,
        .static_string => "[*:0]const u8",
        .user_data, .pointer => "?*anyopaque",
        .desc => |n| try std.fmt.allocPrint(arena, "?*const {f}", .{id(schema.zigTypeName(&nbuf, n))}),
        .out => |o| try std.fmt.allocPrint(arena, "?*{s}", .{try typeName(arena, s, o.*)}),
    };
}

/// The default value of a struct field: what zero means.
fn zero(s: Schema, t: Type) ![]const u8 {
    return switch (t) {
        .bool => "false",
        .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f32, .f64, .usize => "0",
        .ref => |n| switch (s.get(n)) {
            .handle => ".null",
            .@"enum" => "@fromBackingInt(0)",
            .flags, .@"struct" => ".{}",
            .callback => "null",
        },
        .user_data, .pointer, .desc => "null",
        .void, .string, .static_string, .out, .array, .buffer => unreachable,
    };
}
