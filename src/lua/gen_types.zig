//! Generates lua-language-server annotations (LuaCATS) for require("siv")
//! from the API schema, by the same rules as the binding (mapping.zig),
//! so editors check Lua code against the API that libsiv-lua exposes.
//! The prelude's additions are hand-written in types_extra.lua.
//!
//! Usage: siv-lua-gen-types <output>

const std = @import("std");
const m = @import("mapping.zig");
const schema = m.schema;
const Schema = schema.Schema;
const Type = schema.Type;
const Writer = std.Io.Writer;

const extra = @embedFile("types_extra.lua");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.log.err("usage: {s} <output>", .{args[0]});
        std.process.exit(2);
    }
    var w: Writer.Allocating = .init(arena);
    try write(&w.writer, m.spec);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = w.written() });
}

/// Writes `doc` as `---` comment lines.
fn writeDoc(w: *Writer, doc: []const u8) !void {
    if (doc.len == 0) return;
    try w.print("--- {s}\n", .{doc});
}

/// One line of a comment: the doc without line breaks.
fn oneLine(w: *Writer, doc: []const u8) !void {
    for (doc) |ch| try w.writeByte(if (ch == '\n') ' ' else ch);
}

pub fn write(w: *Writer, s: Schema) !void {
    try w.print(
        \\---@meta siv
        \\-- Generated from {s} by src/lua/gen_types.zig. Do not edit.
        \\-- Annotations for lua-language-server: add this directory to
        \\-- workspace.library.
        \\
        \\---{s}
        \\---@class siv
        \\local siv = {{}}
        \\
        \\
    , .{ s.source, s.doc });

    // Types.
    for (s.decls) |d| switch (d) {
        .handle => |h| {
            try writeDoc(w, h.doc);
            try w.print("---@class siv.{s}\n", .{m.stem(s, h.name)});
            try w.print("local {s} = {{}}\n\n", .{m.stem(s, h.name)});
        },
        .@"enum" => |e| {
            if (std.mem.eql(u8, e.name, s.result)) continue;
            try writeDoc(w, e.doc);
            try w.print("---@alias siv.{s}\n", .{m.stem(s, e.name)});
            for (e.values) |v| {
                try w.print("---| \"{s}\" # ", .{v.name});
                try oneLine(w, v.doc);
                try w.writeByte('\n');
            }
            // Closed enums take their values' integers too, but names read
            // better; open ones take any integer.
            try w.writeAll(if (e.open) "---| integer\n\n" else "\n");
        },
        .flags => |f| {
            const st = m.stem(s, f.name);
            try writeDoc(w, f.doc);
            try w.print("---@alias siv.{s}.name\n", .{st});
            for (f.bits) |b| {
                try w.print("---| \"{s}\" # ", .{b.name});
                try oneLine(w, b.doc);
                try w.writeByte('\n');
            }
            try w.print("---A name, a list of names, a set of names, or the bits.\n", .{});
            try w.print("---@alias siv.{s} siv.{s}.name|siv.{s}.name[]|table<siv.{s}.name, boolean>|integer\n\n", .{ st, st, st, st });
        },
        .@"struct" => |st| try writeStruct(w, s, st),
        .callback => |cb| {
            try writeDoc(w, cb.doc);
            try w.print("---@alias siv.{s} ", .{m.stem(s, cb.name)});
            try writeFunType(w, s, cb);
            try w.writeAll("\n\n");
        },
    };

    // Properties of a builder's node: the setters that take one value.
    try w.writeAll("---Properties of a new node, applied with the setters they name: `layout` runs siv.set_layout.\n---@class siv.properties\n");
    try w.writeAll("---@field on? table<siv.event_type, siv.event_fn> Event handlers (siv.on).\n");
    try w.writeAll("---@field on_capture? table<siv.event_type, siv.event_fn> Capture handlers (siv.on_capture).\n");
    for (s.functions) |f| {
        if (!std.mem.startsWith(u8, f.name, "siv_set_")) continue;
        const key = f.name["siv_set_".len..];
        const setter = m.propertySetter(s, key) orelse continue;
        if (!std.mem.eql(u8, setter.name, f.name)) continue;
        try w.print("---@field {s}? ", .{key});
        try writeType(w, s, f.params[2].type, .input);
        try w.print(" siv.{s}\n", .{m.luaName(s, f.name)});
    }
    try w.writeAll("\n");

    // Functions and methods.
    for (s.functions) |f| {
        if (m.isUnbound(f.name)) continue;
        try writeFunction(w, s, f, false);
        if (m.owner(s, f) != null) try writeFunction(w, s, f, true);
    }

    try w.writeAll("\n");
    try w.writeAll(extra);
    try w.writeAll("\nreturn siv\n");
}

const Dir = enum { input, output };

fn writeStruct(w: *Writer, s: Schema, st: schema.Struct) !void {
    const name = m.stem(s, st.name);
    // Structs that callbacks receive have every field but strings,
    // arrays, and handles; the others are inputs where every field is
    // optional.
    const output = st.kind == .value or isCallbackArg(s, st.name);
    try writeDoc(w, st.doc);
    try w.print("---@class siv.{s}\n", .{name});
    for (st.fields) |f| {
        if (m.isUnboundField(st.name, f.name) or f.type == .user_data) continue;
        const optional = !output or f.type == .string or f.type == .array or m.isHandle(s, f.type) or m.isCallback(s, f.type);
        try w.print("---@field {s}{s} ", .{ f.name, if (optional) "?" else "" });
        try writeType(w, s, f.type, if (output) .output else .input);
        try w.writeByte(' ');
        try oneLine(w, f.doc);
        try w.writeByte('\n');
        if (m.fieldAlias(st.name, f.name)) |a| {
            // Either name in, both out.
            try w.print("---@field {s}? ", .{a});
            try writeType(w, s, f.type, if (output) .output else .input);
            try w.print(" The same as `{s}`, which is a Lua keyword.\n", .{f.name});
        }
    }
    try w.writeByte('\n');
    if (st.kind == .value) {
        // What a value struct parameter or field accepts.
        try w.print("---@alias siv.{s}.value siv.{s}|[", .{ name, name });
        for (st.fields, 0..) |f, i| {
            if (f.reserved) continue;
            if (i > 0) try w.writeAll(", ");
            try writeType(w, s, f.type, .input);
        }
        try w.writeAll("]");
        if (std.mem.eql(u8, st.name, "siv_color")) try w.writeAll("|string");
        if (m.isUniform(st.name) or m.isPxDimension(st.name)) try w.writeAll("|number");
        if (m.isPxDimension(st.name)) try w.writeAll("|table");
        try w.writeAll("\n\n");
    }
}

fn isCallbackArg(s: Schema, name: []const u8) bool {
    for (s.decls) |d| if (d == .callback) for (d.callback.params) |p| {
        if (p.type == .desc and std.mem.eql(u8, p.type.desc, name)) return true;
    };
    return false;
}

fn writeType(w: *Writer, s: Schema, t: Type, dir: Dir) !void {
    switch (t) {
        .void => try w.writeAll("nil"),
        .bool => try w.writeAll("boolean"),
        .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .usize => try w.writeAll("integer"),
        .f32, .f64 => try w.writeAll("number"),
        .string, .static_string, .buffer => try w.writeAll("string"),
        .pointer, .user_data => try w.writeAll("lightuserdata"),
        .desc => |n| try w.print("siv.{s}", .{m.stem(s, n)}),
        .out => |o| try writeType(w, s, o.*, .output),
        .array => |e| if (e.* == .u8) try w.writeAll("string") else {
            try writeType(w, s, e.*, dir);
            try w.writeAll("[]");
        },
        .ref => |r| {
            const d = s.get(r);
            if (std.mem.eql(u8, r, s.result)) return w.writeAll("siv.error?");
            switch (d) {
                .@"struct" => |st| if (st.kind == .value and dir == .input) {
                    try w.print("siv.{s}.value", .{m.stem(s, r)});
                } else try w.print("siv.{s}", .{m.stem(s, r)}),
                .flags => if (dir == .output) try w.print("table<siv.{s}.name, true>", .{m.stem(s, r)}) else try w.print("siv.{s}", .{m.stem(s, r)}),
                else => try w.print("siv.{s}", .{m.stem(s, r)}),
            }
        },
    }
}

/// `fun(node: siv.node, event: siv.event): boolean?`. A result parameter
/// is a trailing error argument.
fn writeFunType(w: *Writer, s: Schema, cb: schema.Callback) !void {
    try w.writeAll("fun(");
    var first = true;
    var result = false;
    for (cb.params) |p| {
        if (s.isResult(p.type)) {
            result = true;
            continue;
        }
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("{s}: ", .{p.name});
        try writeType(w, s, p.type, .output);
    }
    if (result) try w.print("{s}err: siv.error?", .{if (first) "" else ", "});
    try w.writeAll(")");
    switch (cb.ret) {
        .void => {},
        .bool => try w.writeAll(": boolean?"),
        .ref => |r| if (s.get(r) == .@"enum")
            try w.print(": siv.{s}|boolean?", .{m.stem(s, r)})
        else
            try w.print(": siv.{s}.value|number, number?", .{m.stem(s, r)}),
        else => {
            try w.writeAll(": ");
            try writeType(w, s, cb.ret, .output);
        },
    }
}

fn writeFunction(w: *Writer, s: Schema, f: schema.Function, method: bool) !void {
    try writeDoc(w, f.doc);
    if (f.deprecated) |d| try w.print("---@deprecated Since {d}.{d}: use {s}.\n", .{ d.since.major, d.since.minor, m.luaName(s, d.replacement) });
    const async_param = m.asyncParam(s, f);
    if (async_param != null) try w.writeAll("--- Without a callback, waits for the result in a coroutine (siv.spawn).\n");
    if (s.isResult(f.ret)) {
        try w.writeAll("--- Raises a siv.error when it fails.\n");
    } else if (m.isBuilder(s, f)) try w.writeAll("--- Raises a siv.error when the transaction has failed.\n");
    var names: [16][]const u8 = undefined;
    var n: usize = 0;
    for (f.params, 0..) |p, i| {
        if (method and i == 0) continue;
        switch (m.role(s, f, i)) {
            .input => {
                // Zero is a default for these, and nil is zero.
                const optional = switch (p.type) {
                    .desc, .string, .array => true,
                    .ref => |r| s.get(r) != .callback,
                    else => false,
                };
                try w.print("---@param {s}{s} ", .{ luaParam(p.name), if (optional) "?" else "" });
                try writeType(w, s, p.type, .input);
                try w.writeByte(' ');
                try oneLine(w, p.doc);
                try w.writeByte('\n');
                names[n] = luaParam(p.name);
                n += 1;
            },
            .callback => {
                const cb = s.get(p.type.ref).callback;
                try w.print("---@param {s}? siv.{s} ", .{ luaParam(p.name), m.stem(s, cb.name) });
                try oneLine(w, p.doc);
                try w.writeByte('\n');
                names[n] = luaParam(p.name);
                n += 1;
            },
            else => {},
        }
    }
    if (m.isBuilder(s, f)) {
        try w.writeAll("---@param props? siv.properties Properties of the new node.\n");
        names[n] = "props";
        n += 1;
    }
    for (f.params, 0..) |p, i| switch (m.role(s, f, i)) {
        .out => {
            try w.writeAll("---@return ");
            try writeType(w, s, p.type, .output);
            try w.print(" {s}\n", .{p.name});
        },
        .buffer => try w.print("---@return string {s}\n", .{p.name}),
        else => {},
    };
    if (async_param) |ap| {
        // What waiting returns: the completion's arguments.
        const cb = s.get(f.params[ap].type.ref).callback;
        for (cb.params) |p| {
            if (s.isResult(p.type)) continue;
            try w.writeAll("---@return ");
            try writeType(w, s, p.type, .output);
            try w.print("{s} {s}\n", .{ if (p.type == .string) "?" else "", p.name });
        }
    }
    if (!s.isResult(f.ret) and f.ret != .void) {
        try w.writeAll("---@return ");
        try writeType(w, s, f.ret, .output);
        try w.writeByte('\n');
    }
    if (method) {
        try w.print("function {s}:{s}(", .{ m.stem(s, m.owner(s, f).?), m.methodName(s, f) });
    } else {
        try w.print("function siv.{s}(", .{m.luaName(s, f.name)});
    }
    for (names[0..n], 0..) |name, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(name);
    }
    try w.writeAll(") end\n\n");
}

/// Lua keywords cannot be parameter names.
fn luaParam(name: []const u8) []const u8 {
    const keywords = [_]struct { []const u8, []const u8 }{ .{ "end", "end_" }, .{ "function", "function_" }, .{ "repeat", "repeat_" }, .{ "local", "local_" } };
    for (keywords) |k| if (std.mem.eql(u8, k[0], name)) return k[1];
    return name;
}

test {
    // The mapping's checks against the schema run here, in the one test
    // binary that has the mapping without the binding.
    _ = m;
}

test "annotations name every bound function" {
    var w: Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try write(&w.writer, m.spec);
    const out = w.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "function siv.flex(txn, parent, desc, props) end") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "function txn:flex(parent, desc, props) end") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "function window:set_title(title) end") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "---@return siv.app app\nfunction siv.app_create(desc) end") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "---@field layout? siv.layout_desc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "siv_set_data") == null);
}
