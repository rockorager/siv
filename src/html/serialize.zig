//! Writing a tree out: HTML (for tests and the Markdown conformance
//! suite) and the html5lib test format.

const std = @import("std");
const Dom = @import("Dom.zig");
const NodeId = Dom.NodeId;
const Writer = std.Io.Writer;

fn isVoid(d: *const Dom, id: NodeId) bool {
    const n = d.node(id);
    if (n.ns != .html) return false;
    return switch (n.name) {
        .area, .base, .basefont, .bgsound, .br, .col, .embed, .frame, .hr, .img, .input, .keygen, .link, .meta, .param, .source, .track, .wbr => true,
        else => false,
    };
}

fn escape(w: *Writer, s: []const u8, attr: bool) Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll(if (attr) "<" else "&lt;"),
        '>' => try w.writeAll(if (attr) ">" else "&gt;"),
        '"' => try w.writeAll(if (attr) "&quot;" else "\""),
        else => try w.writeByte(c),
    };
}

/// The children of `id` as HTML (innerHTML).
pub fn html(d: *const Dom, w: *Writer, id: NodeId) Writer.Error!void {
    var it = d.children(id);
    while (it.next()) |c| try outer(d, w, c);
}

/// A node as HTML (outerHTML).
pub fn outer(d: *const Dom, w: *Writer, id: NodeId) Writer.Error!void {
    const n = d.node(id);
    switch (n.kind) {
        .document => try html(d, w, id),
        .doctype => try w.print("<!DOCTYPE {s}>", .{d.doctype(id).name}),
        .comment => try w.print("<!--{s}-->", .{d.text(id)}),
        .text => {
            const p = n.parent;
            const raw = p != .none and d.node(p).ns == .html and switch (d.node(p).name) {
                .style, .script, .xmp, .iframe, .noembed, .noframes, .plaintext => true,
                else => false,
            };
            if (raw) try w.writeAll(d.text(id)) else try escape(w, d.text(id), false);
        },
        .element => {
            try w.print("<{s}", .{d.nameOf(n.name)});
            for (d.attributes(id)) |at| {
                try w.writeByte(' ');
                switch (at.prefix) {
                    .none => {},
                    .xlink => try w.writeAll("xlink:"),
                    .xml => try w.writeAll("xml:"),
                    .xmlns => try w.writeAll("xmlns:"),
                }
                try w.print("{s}=\"", .{d.nameOf(at.name)});
                try escape(w, d.str(at.value), true);
                try w.writeByte('"');
            }
            try w.writeByte('>');
            if (isVoid(d, id)) return;
            try html(d, w, id);
            try w.print("</{s}>", .{d.nameOf(n.name)});
        },
    }
}

/// The html5lib tree-construction test format ("| <html>" lines).
pub fn testFormat(d: *const Dom, w: *Writer, root: NodeId) Writer.Error!void {
    var it = d.children(root);
    while (it.next()) |c| try testNode(d, w, c, 0);
}

fn indent(w: *Writer, depth: usize) Writer.Error!void {
    try w.writeAll("| ");
    for (0..depth) |_| try w.writeAll("  ");
}

fn testNode(d: *const Dom, w: *Writer, id: NodeId, depth: usize) Writer.Error!void {
    const n = d.node(id);
    try indent(w, depth);
    switch (n.kind) {
        .document => {},
        .doctype => {
            const dt = d.doctype(id);
            try w.print("<!DOCTYPE {s}", .{dt.name});
            if (dt.public_id != null or dt.system_id != null) try w.print(" \"{s}\" \"{s}\"", .{ dt.public_id orelse "", dt.system_id orelse "" });
            try w.writeAll(">\n");
        },
        .comment => try w.print("<!-- {s} -->\n", .{d.text(id)}),
        .text => try w.print("\"{s}\"\n", .{d.text(id)}),
        .element => {
            const prefix: []const u8 = switch (n.ns) {
                .html => "",
                .svg => "svg ",
                .mathml => "math ",
            };
            try w.print("<{s}{s}>\n", .{ prefix, d.nameOf(n.name) });
            // Attributes sorted by name.
            const attrs = d.attributes(id);
            var order: [64]u8 = undefined;
            const count = @min(attrs.len, order.len);
            for (0..count) |i| order[i] = @intCast(i);
            const Ctx = struct {
                d: *const Dom,
                attrs: []const Dom.Attr,
                fn key(c: @This(), i: u8, buf: []u8) []const u8 {
                    const at = c.attrs[i];
                    const p: []const u8 = switch (at.prefix) {
                        .none => "",
                        .xlink => "xlink ",
                        .xml => "xml ",
                        .xmlns => "xmlns ",
                    };
                    return std.fmt.bufPrint(buf, "{s}{s}", .{ p, c.d.nameOf(at.name) }) catch c.d.nameOf(at.name);
                }
                fn less(c: @This(), a: u8, b: u8) bool {
                    var ba: [128]u8 = undefined;
                    var bb: [128]u8 = undefined;
                    return std.mem.order(u8, c.key(a, &ba), c.key(b, &bb)) == .lt;
                }
            };
            const ctx: Ctx = .{ .d = d, .attrs = attrs };
            std.mem.sort(u8, order[0..count], ctx, Ctx.less);
            for (order[0..count]) |i| {
                var buf: [128]u8 = undefined;
                try indent(w, depth + 1);
                try w.print("{s}=\"{s}\"\n", .{ ctx.key(i, &buf), d.str(attrs[i].value) });
            }
            if (n.flags.template_contents or (n.ns == .html and n.name == .template)) {
                try indent(w, depth + 1);
                try w.writeAll("content\n");
                var it = d.children(id);
                while (it.next()) |c| try testNode(d, w, c, depth + 2);
                return;
            }
            var it = d.children(id);
            while (it.next()) |c| try testNode(d, w, c, depth + 1);
        },
    }
}
