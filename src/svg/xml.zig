//! A small non-validating XML parser, enough for SVG files: elements,
//! attributes, character data, and CDATA sections become a tree of
//! nodes; comments, processing instructions, and the DOCTYPE are
//! skipped, apart from the DOCTYPE's internal entity declarations, which
//! Illustrator's exports use for namespace names. Input is bounded by
//! `Limits`, so hostile files cost time and memory linear in their size.

const std = @import("std");

pub const Error = error{ OutOfMemory, InvalidSvg };

pub const none: u32 = std.math.maxInt(u32);

pub const Attr = struct {
    /// The qualified name as written (`xlink:href`).
    name: []const u8,
    /// Entity references decoded.
    value: []const u8,
};

pub const Node = struct {
    /// The local name: an `svg:` prefix is dropped, other prefixes kept
    /// (`sodipodi:namedview`), so foreign elements never match SVG names.
    name: []const u8,
    attrs: []const Attr,
    parent: u32,
    first_child: u32 = none,
    last_child: u32 = none,
    next_sibling: u32 = none,
    /// The element's own character data and CDATA, concatenated.
    text: []const u8 = "",

    pub fn attr(n: *const Node, name: []const u8) ?[]const u8 {
        for (n.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

pub const Limits = struct {
    max_nodes: u32 = 100_000,
    max_depth: u32 = 256,
};

pub const Document = struct {
    /// Node 0 is the root element.
    nodes: []const Node,

    pub fn children(doc: *const Document, parent: u32) ChildIterator {
        return .{ .doc = doc, .next_index = doc.nodes[parent].first_child };
    }
};

pub const ChildIterator = struct {
    doc: *const Document,
    next_index: u32,

    pub fn next(it: *ChildIterator) ?u32 {
        const i = it.next_index;
        if (i == none) return null;
        it.next_index = it.doc.nodes[i].next_sibling;
        return i;
    }
};

/// Parses `src` into nodes allocated from `arena` (strings borrow `src`
/// where no entity needed decoding).
pub fn parse(arena: std.mem.Allocator, src: []const u8, limits: Limits) Error!Document {
    var p: Parser = .{ .arena = arena, .src = src, .limits = limits };
    try p.document();
    if (p.nodes.items.len == 0) return error.InvalidSvg;
    return .{ .nodes = p.nodes.items };
}

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    limits: Limits,
    nodes: std.ArrayList(Node) = .empty,
    entities: std.ArrayList(Attr) = .empty,
    /// Open elements.
    stack: std.ArrayList(u32) = .empty,
    /// Text of the innermost open element, gathered until it closes.
    text: std.ArrayList(TextPiece) = .empty,

    const TextPiece = struct { node: u32, bytes: []const u8 };

    fn document(p: *Parser) Error!void {
        while (p.pos < p.src.len) {
            const lt = std.mem.indexOfScalarPos(u8, p.src, p.pos, '<') orelse {
                try p.chars(p.src[p.pos..], true);
                p.pos = p.src.len;
                break;
            };
            if (lt > p.pos) try p.chars(p.src[p.pos..lt], true);
            p.pos = lt;
            const rest = p.src[p.pos..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                p.pos = (std.mem.indexOfPos(u8, p.src, p.pos + 4, "-->") orelse return error.InvalidSvg) + 3;
            } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                const end = std.mem.indexOfPos(u8, p.src, p.pos + 9, "]]>") orelse return error.InvalidSvg;
                try p.chars(p.src[p.pos + 9 .. end], false);
                p.pos = end + 3;
            } else if (std.mem.startsWith(u8, rest, "<?")) {
                p.pos = (std.mem.indexOfPos(u8, p.src, p.pos + 2, "?>") orelse return error.InvalidSvg) + 2;
            } else if (std.mem.startsWith(u8, rest, "<!DOCTYPE") or std.mem.startsWith(u8, rest, "<!doctype")) {
                try p.doctype();
            } else if (std.mem.startsWith(u8, rest, "</")) {
                try p.endTag();
            } else {
                try p.startTag();
            }
        }
        if (p.stack.items.len != 0) return error.InvalidSvg;
        try p.flushText();
    }

    fn chars(p: *Parser, raw: []const u8, decode: bool) Error!void {
        if (p.stack.items.len == 0) return;
        const top = p.stack.items[p.stack.items.len - 1];
        const bytes = if (decode) try p.decodeEntities(raw) else raw;
        try p.text.append(p.arena, .{ .node = top, .bytes = bytes });
    }

    /// Joins the text pieces of each element.
    fn flushText(p: *Parser) Error!void {
        var i: usize = 0;
        while (i < p.text.items.len) {
            const node = p.text.items[i].node;
            var j = i + 1;
            var len = p.text.items[i].bytes.len;
            while (j < p.text.items.len and p.text.items[j].node == node) : (j += 1) len += p.text.items[j].bytes.len;
            const n = &p.nodes.items[node];
            if (j == i + 1 and n.text.len == 0) {
                n.text = p.text.items[i].bytes;
            } else {
                const out = try p.arena.alloc(u8, n.text.len + len);
                @memcpy(out[0..n.text.len], n.text);
                var o = n.text.len;
                for (p.text.items[i..j]) |piece| {
                    @memcpy(out[o..][0..piece.bytes.len], piece.bytes);
                    o += piece.bytes.len;
                }
                n.text = out;
            }
            i = j;
        }
        p.text.clearRetainingCapacity();
    }

    fn doctype(p: *Parser) Error!void {
        p.pos += 9;
        while (p.pos < p.src.len) {
            const ch = p.src[p.pos];
            if (ch == '>') {
                p.pos += 1;
                return;
            }
            if (ch == '[') {
                p.pos += 1;
                try p.internalSubset();
                continue;
            }
            if (ch == '"' or ch == '\'') {
                p.pos = (std.mem.indexOfScalarPos(u8, p.src, p.pos + 1, ch) orelse return error.InvalidSvg) + 1;
                continue;
            }
            p.pos += 1;
        }
        return error.InvalidSvg;
    }

    fn internalSubset(p: *Parser) Error!void {
        while (p.pos < p.src.len) {
            const rest = p.src[p.pos..];
            if (rest[0] == ']') {
                p.pos += 1;
                return;
            }
            if (std.mem.startsWith(u8, rest, "<!--")) {
                p.pos = (std.mem.indexOfPos(u8, p.src, p.pos + 4, "-->") orelse return error.InvalidSvg) + 3;
            } else if (std.mem.startsWith(u8, rest, "<!ENTITY")) {
                p.pos += 8;
                _ = p.skipSpace();
                if (p.pos < p.src.len and p.src[p.pos] == '%') return p.skipDecl(); // parameter entity
                const ent_name = p.name();
                _ = p.skipSpace();
                if (ent_name.len == 0 or p.pos >= p.src.len) return error.InvalidSvg;
                const q = p.src[p.pos];
                if (q != '"' and q != '\'') {
                    try p.skipDecl(); // external entity
                    continue;
                }
                const end = std.mem.indexOfScalarPos(u8, p.src, p.pos + 1, q) orelse return error.InvalidSvg;
                // Entity values are inserted as text: one level, no markup.
                const value = try p.decodeEntities(p.src[p.pos + 1 .. end]);
                if (p.entities.items.len < 256) try p.entities.append(p.arena, .{ .name = ent_name, .value = value });
                p.pos = end + 1;
                try p.skipDecl();
            } else if (std.mem.startsWith(u8, rest, "<")) {
                try p.skipDecl();
            } else {
                p.pos += 1;
            }
        }
        return error.InvalidSvg;
    }

    /// Skips to the end of a markup declaration, past quoted strings.
    fn skipDecl(p: *Parser) Error!void {
        while (p.pos < p.src.len) {
            const ch = p.src[p.pos];
            if (ch == '>') {
                p.pos += 1;
                return;
            }
            if (ch == '"' or ch == '\'') {
                p.pos = (std.mem.indexOfScalarPos(u8, p.src, p.pos + 1, ch) orelse return error.InvalidSvg) + 1;
            } else p.pos += 1;
        }
        return error.InvalidSvg;
    }

    fn startTag(p: *Parser) Error!void {
        p.pos += 1;
        const qname = p.name();
        if (qname.len == 0) return error.InvalidSvg;
        if (p.stack.items.len == 0 and p.nodes.items.len != 0) return error.InvalidSvg; // a second root
        if (p.stack.items.len >= p.limits.max_depth or p.nodes.items.len >= p.limits.max_nodes) return error.InvalidSvg;
        var attrs: std.ArrayList(Attr) = .empty;
        var self_closing = false;
        while (true) {
            const had_space = p.skipSpace();
            if (p.pos >= p.src.len) return error.InvalidSvg;
            const ch = p.src[p.pos];
            if (ch == '>') {
                p.pos += 1;
                break;
            }
            if (ch == '/') {
                if (p.pos + 1 >= p.src.len or p.src[p.pos + 1] != '>') return error.InvalidSvg;
                p.pos += 2;
                self_closing = true;
                break;
            }
            if (!had_space) return error.InvalidSvg;
            const an = p.name();
            if (an.len == 0) return error.InvalidSvg;
            _ = p.skipSpace();
            if (p.pos >= p.src.len or p.src[p.pos] != '=') return error.InvalidSvg;
            p.pos += 1;
            _ = p.skipSpace();
            if (p.pos >= p.src.len) return error.InvalidSvg;
            const q = p.src[p.pos];
            if (q != '"' and q != '\'') return error.InvalidSvg;
            const end = std.mem.indexOfScalarPos(u8, p.src, p.pos + 1, q) orelse return error.InvalidSvg;
            const raw = p.src[p.pos + 1 .. end];
            if (std.mem.indexOfScalar(u8, raw, '<') != null) return error.InvalidSvg;
            p.pos = end + 1;
            // Later duplicates are ignored, as browsers do.
            for (attrs.items) |a| {
                if (std.mem.eql(u8, a.name, an)) break;
            } else try attrs.append(p.arena, .{ .name = an, .value = try p.decodeEntities(raw) });
        }
        const index: u32 = @intCast(p.nodes.items.len);
        const parent = if (p.stack.items.len == 0) none else p.stack.items[p.stack.items.len - 1];
        try p.nodes.append(p.arena, .{ .name = localName(qname), .attrs = attrs.items, .parent = parent });
        if (parent != none) {
            const pn = &p.nodes.items[parent];
            if (pn.last_child == none) pn.first_child = index else p.nodes.items[pn.last_child].next_sibling = index;
            pn.last_child = index;
        }
        if (!self_closing) try p.stack.append(p.arena, index);
    }

    fn endTag(p: *Parser) Error!void {
        p.pos += 2;
        const qname = p.name();
        _ = p.skipSpace();
        if (p.pos >= p.src.len or p.src[p.pos] != '>') return error.InvalidSvg;
        p.pos += 1;
        const top = p.stack.pop() orelse return error.InvalidSvg;
        if (!std.mem.eql(u8, p.nodes.items[top].name, localName(qname))) return error.InvalidSvg;
        // Text only matters for leaves (<style>); flush per element so
        // pieces of different elements never interleave.
        if (p.text.items.len != 0) try p.flushText();
    }

    fn name(p: *Parser) []const u8 {
        const start = p.pos;
        while (p.pos < p.src.len) : (p.pos += 1) {
            switch (p.src[p.pos]) {
                ' ', '\t', '\r', '\n', '=', '>', '/', '<', '"', '\'', '[', ']' => break,
                else => {},
            }
        }
        return p.src[start..p.pos];
    }

    fn skipSpace(p: *Parser) bool {
        const start = p.pos;
        while (p.pos < p.src.len and isSpace(p.src[p.pos])) p.pos += 1;
        return p.pos != start;
    }

    fn decodeEntities(p: *Parser, raw: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
        var out: std.ArrayList(u8) = try .initCapacity(p.arena, raw.len);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '&') {
                try out.append(p.arena, raw[i]);
                i += 1;
                continue;
            }
            const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse return error.InvalidSvg;
            const ent = raw[i + 1 .. semi];
            i = semi + 1;
            if (ent.len > 1 and ent[0] == '#') {
                const cp = (if (ent[1] == 'x' or ent[1] == 'X')
                    std.fmt.parseInt(u21, ent[2..], 16)
                else
                    std.fmt.parseInt(u21, ent[1..], 10)) catch return error.InvalidSvg;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidSvg;
                try out.appendSlice(p.arena, buf[0..n]);
                continue;
            }
            const predefined = [_]Attr{
                .{ .name = "lt", .value = "<" },  .{ .name = "gt", .value = ">" },
                .{ .name = "amp", .value = "&" }, .{ .name = "quot", .value = "\"" },
                .{ .name = "apos", .value = "'" },
            };
            const value = for (predefined ++ [_]Attr{}) |e| {
                if (std.mem.eql(u8, e.name, ent)) break e.value;
            } else for (p.entities.items) |e| {
                if (std.mem.eql(u8, e.name, ent)) break e.value;
            } else return error.InvalidSvg;
            if (out.items.len + value.len > raw.len * 16 + 4096) return error.InvalidSvg;
            try out.appendSlice(p.arena, value);
        }
        return out.items;
    }
};

pub fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn localName(qname: []const u8) []const u8 {
    if (std.mem.startsWith(u8, qname, "svg:")) return qname[4..];
    return qname;
}

const testing = std.testing;

test "elements, attributes, text, and entities" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\<?xml version="1.0"?>
        \\<!DOCTYPE svg [ <!ENTITY ns "http://www.w3.org/2000/svg"> ]>
        \\<!-- a comment -->
        \\<svg:svg xmlns="&ns;" a='1 &amp; 2'>
        \\  <style><![CDATA[ .a { fill: red } ]]></style>
        \\  <g><path d="M0 0"/><sodipodi:x/></g>
        \\</svg:svg>
    , .{});
    try testing.expectEqual(@as(usize, 5), doc.nodes.len);
    const root = doc.nodes[0];
    try testing.expectEqualStrings("svg", root.name);
    try testing.expectEqualStrings("http://www.w3.org/2000/svg", root.attr("xmlns").?);
    try testing.expectEqualStrings("1 & 2", root.attr("a").?);
    try testing.expectEqualStrings(" .a { fill: red } ", doc.nodes[1].text);
    var it = doc.children(2);
    try testing.expectEqualStrings("path", doc.nodes[it.next().?].name);
    try testing.expectEqualStrings("sodipodi:x", doc.nodes[it.next().?].name);
    try testing.expect(it.next() == null);
}

test "malformed documents fail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", "<svg>", "<svg></g>", "<svg a=1/>", "<svg/><svg/>", "<svg a='&unknown;'/>", "<svg a='x'b='y'/>" }) |src|
        try testing.expectError(error.InvalidSvg, parse(arena.allocator(), src, .{}));
    var deep: [900]u8 = undefined;
    for (0..300) |i| @memcpy(deep[i * 3 ..][0..3], "<g>");
    try testing.expectError(error.InvalidSvg, parse(arena.allocator(), &deep, .{}));
}
