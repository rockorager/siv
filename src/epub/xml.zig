//! A small XML pull tokenizer for EPUB's package files (container.xml,
//! the OPF package, the NCX): start and end tags with attributes, text
//! with the predefined and numeric character references decoded,
//! comments, processing instructions, and the doctype skipped, CDATA as
//! text. Not validating: malformed input ends the stream instead of
//! failing, as reading systems tolerate broken packages.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Token = union(enum) {
    start: struct { name: []const u8, attrs: []const Attr, empty: bool },
    end: []const u8,
    text: []const u8,
};

pub const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    /// Attributes and decoded text, valid until the next token.
    arena: std.heap.ArenaAllocator,
    attrs: std.ArrayList(Attr) = .empty,

    pub fn init(gpa: Allocator, src: []const u8) Tokenizer {
        return .{ .src = src, .arena = .init(gpa) };
    }

    pub fn deinit(t: *Tokenizer) void {
        t.arena.deinit();
    }

    pub fn next(t: *Tokenizer) error{OutOfMemory}!?Token {
        const s = t.src;
        while (t.pos < s.len) {
            if (s[t.pos] != '<') {
                const end = std.mem.indexOfScalarPos(u8, s, t.pos, '<') orelse s.len;
                const raw = s[t.pos..end];
                t.pos = end;
                _ = t.arena.reset(.retain_capacity);
                t.attrs = .empty;
                return .{ .text = try decode(t.arena.allocator(), raw) };
            }
            const rest = s[t.pos..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                t.pos = if (std.mem.indexOfPos(u8, s, t.pos + 4, "-->")) |k| k + 3 else s.len;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                const end = std.mem.indexOfPos(u8, s, t.pos + 9, "]]>") orelse s.len;
                const text = s[t.pos + 9 .. end];
                t.pos = @min(s.len, end + 3);
                return .{ .text = text };
            }
            if (std.mem.startsWith(u8, rest, "<?") or std.mem.startsWith(u8, rest, "<!")) {
                t.pos = if (std.mem.indexOfScalarPos(u8, s, t.pos, '>')) |k| k + 1 else s.len;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "</")) {
                const end = std.mem.indexOfScalarPos(u8, s, t.pos, '>') orelse return null;
                const name = std.mem.trim(u8, s[t.pos + 2 .. end], " \t\r\n");
                t.pos = end + 1;
                return .{ .end = name };
            }
            return try t.startTag();
        }
        return null;
    }

    fn startTag(t: *Tokenizer) error{OutOfMemory}!?Token {
        const s = t.src;
        _ = t.arena.reset(.retain_capacity);
        t.attrs = .empty;
        const a = t.arena.allocator();
        var i = t.pos + 1;
        const name_start = i;
        while (i < s.len and !isSpace(s[i]) and s[i] != '>' and s[i] != '/') i += 1;
        const name = s[name_start..i];
        while (true) {
            while (i < s.len and isSpace(s[i])) i += 1;
            if (i >= s.len) return null;
            if (s[i] == '>') {
                t.pos = i + 1;
                return .{ .start = .{ .name = name, .attrs = t.attrs.items, .empty = false } };
            }
            if (s[i] == '/') {
                t.pos = if (std.mem.indexOfScalarPos(u8, s, i, '>')) |k| k + 1 else s.len;
                return .{ .start = .{ .name = name, .attrs = t.attrs.items, .empty = true } };
            }
            const an = i;
            while (i < s.len and !isSpace(s[i]) and s[i] != '=' and s[i] != '>' and s[i] != '/') i += 1;
            const attr_name = s[an..i];
            while (i < s.len and isSpace(s[i])) i += 1;
            var value: []const u8 = "";
            if (i < s.len and s[i] == '=') {
                i += 1;
                while (i < s.len and isSpace(s[i])) i += 1;
                if (i >= s.len) return null;
                const q = s[i];
                if (q == '"' or q == '\'') {
                    const end = std.mem.indexOfScalarPos(u8, s, i + 1, q) orelse return null;
                    value = try decode(a, s[i + 1 .. end]);
                    i = end + 1;
                } else {
                    const vs = i;
                    while (i < s.len and !isSpace(s[i]) and s[i] != '>') i += 1;
                    value = try decode(a, s[vs..i]);
                }
            }
            if (attr_name.len == 0) {
                i += 1;
                continue;
            }
            try t.attrs.append(a, .{ .name = attr_name, .value = value });
        }
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Decodes character references (the five predefined ones and numeric).
pub fn decode(a: Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') if (std.mem.indexOfScalarPos(u8, raw, i, ';')) |semi| if (semi - i <= 10) {
            const ref = raw[i + 1 .. semi];
            const named = [_]struct { []const u8, u8 }{ .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "quot", '"' }, .{ "apos", '\'' } };
            var done = false;
            for (named) |n| if (std.mem.eql(u8, ref, n[0])) {
                try out.append(a, n[1]);
                done = true;
            };
            if (!done and ref.len > 1 and ref[0] == '#') {
                const cp = (if (ref[1] == 'x' or ref[1] == 'X') std.fmt.parseInt(u21, ref[2..], 16) else std.fmt.parseInt(u21, ref[1..], 10)) catch 0xfffd;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(if (cp == 0) 0xfffd else cp, &buf) catch std.unicode.utf8Encode(0xfffd, &buf) catch unreachable;
                try out.appendSlice(a, buf[0..n]);
                done = true;
            }
            if (done) {
                i = semi + 1;
                continue;
            }
        };
        try out.append(a, raw[i]);
        i += 1;
    }
    return out.items;
}

/// The local part of a qualified name (`dc:title` is `title`).
pub fn local(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, ':')) |k| name[k + 1 ..] else name;
}

pub fn attr(attrs: []const Attr, name: []const u8) ?[]const u8 {
    for (attrs) |at| if (std.mem.eql(u8, local(at.name), name)) return at.value;
    return null;
}

test "tags, attributes, text, and references" {
    var t: Tokenizer = .init(std.testing.allocator, "<?xml version='1.0'?><!-- c --><a x=\"1 &amp; 2\" y='&#x41;'><b/>t&lt;x<![CDATA[<raw>]]></a>");
    defer t.deinit();
    const a = (try t.next()).?.start;
    try std.testing.expectEqualStrings("a", a.name);
    try std.testing.expectEqualStrings("1 & 2", attr(a.attrs, "x").?);
    try std.testing.expectEqualStrings("A", attr(a.attrs, "y").?);
    try std.testing.expect((try t.next()).?.start.empty);
    try std.testing.expectEqualStrings("t<x", (try t.next()).?.text);
    try std.testing.expectEqualStrings("<raw>", (try t.next()).?.text);
    try std.testing.expectEqualStrings("a", (try t.next()).?.end);
    try std.testing.expect((try t.next()) == null);
}
