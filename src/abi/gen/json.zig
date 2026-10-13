//! JSON description generator: the schema for external binding generators,
//! with the derived C names and spellings included so that they do not
//! reimplement the naming rules. `format_version` changes when the shape of
//! this document changes incompatibly.

const std = @import("std");
const schema = @import("../schema.zig");
const cgen = @import("c.zig");
const Schema = schema.Schema;
const Type = schema.Type;

pub const format_version = 1;

pub fn write(arena: std.mem.Allocator, w: *std.Io.Writer, s: Schema, version: std.SemanticVersion) !void {
    var j: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    var buf: [128]u8 = undefined;
    var ubuf: [128]u8 = undefined;

    try j.beginObject();
    try field(&j, "format_version", format_version);
    try field(&j, "name", s.name);
    try field(&j, "prefix", s.prefix);
    try field(&j, "version", try std.fmt.allocPrint(arena, "{f}", .{version}));
    try field(&j, "doc", s.doc);
    try field(&j, "result", s.result);
    try j.objectField("conventions");
    try j.beginObject();
    try field(&j, "handle_c_type", "uint64_t");
    try field(&j, "null_handle", 0);
    try field(&j, "descriptor_size_field", "size");
    try field(&j, "descriptor_size_c_type", "size_t");
    try field(&j, "string_length_suffix", "_len");
    try field(&j, "array_count_suffix", "_count");
    try field(&j, "buffer_capacity_suffix", "_cap");
    try field(&j, "callback_user_data", "first parameter");
    try field(&j, "default_thread", "app");
    try field(&j, "enum_c_type", "int32_t");
    try field(&j, "flags_c_type", "uint32_t");
    try j.endObject();

    try j.objectField("types");
    try j.beginArray();
    for (s.decls) |d| {
        try j.beginObject();
        try field(&j, "kind", @tagName(d));
        try field(&j, "name", d.name());
        try field(&j, "doc", d.doc());
        try field(&j, "since", try since(arena, d.since()));
        switch (d) {
            .handle => |h| try field(&j, "root", h.root),
            .@"enum" => |e| {
                const prefix = try arena.dupe(u8, schema.enumValuePrefix(&buf, e));
                try field(&j, "open", e.open);
                try j.objectField("values");
                try j.beginArray();
                for (e.values) |v| {
                    try j.beginObject();
                    try field(&j, "name", v.name);
                    try field(&j, "c_name", try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, schema.upper(&ubuf, v.name) }));
                    try field(&j, "value", v.value);
                    try field(&j, "doc", v.doc);
                    if (v.since) |vs| try field(&j, "since", try since(arena, vs));
                    try j.endObject();
                }
                try j.endArray();
            },
            .flags => |f| {
                const prefix = try arena.dupe(u8, schema.flagsValuePrefix(&buf, f));
                try j.objectField("bits");
                try j.beginArray();
                for (f.bits) |b| {
                    try j.beginObject();
                    try field(&j, "name", b.name);
                    try field(&j, "c_name", try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, schema.upper(&ubuf, b.name) }));
                    try field(&j, "bit", b.bit);
                    try field(&j, "value", @as(u32, 1) << b.bit);
                    try field(&j, "doc", b.doc);
                    if (b.since) |bs| try field(&j, "since", try since(arena, bs));
                    try j.endObject();
                }
                try j.endArray();
            },
            .@"struct" => |st| {
                try field(&j, "descriptor", st.kind == .descriptor);
                try j.objectField("fields");
                try j.beginArray();
                if (st.kind == .descriptor) try member(arena, &j, s, "size", .usize, "sizeof the struct.", st.since, false);
                for (st.fields) |f| try member(arena, &j, s, f.name, f.type, f.doc, f.since orelse st.since, f.reserved);
                try j.endArray();
            },
            .callback => |cb| {
                try j.objectField("params");
                try j.beginArray();
                try member(arena, &j, s, "user_data", .user_data, "The user_data registered with the callback.", null, false);
                for (cb.params) |p| try member(arena, &j, s, p.name, p.type, p.doc, null, false);
                try j.endArray();
                try j.objectField("return");
                try typeValue(arena, &j, s, cb.ret);
                try field(&j, "thread", @tagName(cb.thread));
            },
        }
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("functions");
    try j.beginArray();
    for (s.functions) |f| {
        try j.beginObject();
        try field(&j, "name", f.name);
        try field(&j, "doc", f.doc);
        try field(&j, "since", try since(arena, f.since));
        try field(&j, "symbol_version", try arena.dupe(u8, schema.versionNode(&buf, s, version, f)));
        try field(&j, "fallible", s.isResult(f.ret));
        if (s.isResult(f.ret)) try field(&j, "must_use", f.must_use);
        try field(&j, "thread", @tagName(f.thread));
        if (f.deprecated) |d| {
            try j.objectField("deprecated");
            try j.beginObject();
            try field(&j, "since", try since(arena, d.since));
            try field(&j, "replacement", d.replacement);
            try j.endObject();
        }
        try j.objectField("params");
        try j.beginArray();
        for (f.params) |p| try member(arena, &j, s, p.name, p.type, p.doc, null, false);
        try j.endArray();
        try j.objectField("return");
        try typeValue(arena, &j, s, f.ret);
        var proto: std.Io.Writer.Allocating = .init(arena);
        try cgen.prototype(arena, &proto.writer, f);
        try field(&j, "c_prototype", proto.written());
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
    try w.writeAll("\n");
}

fn field(j: *std.json.Stringify, name: []const u8, v: anytype) !void {
    try j.objectField(name);
    try j.write(v);
}

fn since(arena: std.mem.Allocator, v: schema.Version) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}.{d}", .{ v.major, v.minor });
}

/// A parameter or field: its schema type and the C declarations it becomes.
fn member(arena: std.mem.Allocator, j: *std.json.Stringify, s: Schema, name: []const u8, t: Type, doc: []const u8, v: ?schema.Version, reserved: bool) !void {
    try j.beginObject();
    try field(j, "name", name);
    try field(j, "doc", doc);
    if (reserved) try field(j, "reserved", true);
    if (v) |vs| try field(j, "since", try since(arena, vs));
    try j.objectField("type");
    try typeValue(arena, j, s, t);
    try j.objectField("c");
    try j.beginArray();
    for (try cgen.decls(arena, t, name)) |d| {
        try j.beginObject();
        try field(j, "name", d.name);
        try field(j, "type", d.type);
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
}

fn typeValue(arena: std.mem.Allocator, j: *std.json.Stringify, s: Schema, t: Type) !void {
    try j.beginObject();
    try field(j, "kind", @tagName(t));
    switch (t) {
        .ref => |n| {
            try field(j, "name", n);
            try field(j, "ref_kind", @tagName(s.get(n)));
        },
        .desc => |n| try field(j, "name", n),
        .out => |o| {
            try j.objectField("type");
            try typeValue(arena, j, s, o.*);
        },
        .array => |e| {
            try j.objectField("element");
            try typeValue(arena, j, s, e.*);
        },
        else => {},
    }
    if (t != .string and t != .array and t != .buffer) try field(j, "c_type", try cgen.typeName(arena, t));
    try j.endObject();
}
