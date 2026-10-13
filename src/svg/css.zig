//! The CSS that icon themes use: `<style>` sheets of rules whose
//! selectors are element names, classes, ids, attribute tests, and
//! descendant or child combinators (Breeze's `.ColorScheme-Text`,
//! Inkscape's `#path12`), and `style` attributes. Declarations keep
//! their raw values; `parse.zig` interprets the properties it knows.
//! At-rules are skipped, and a rule with a selector this subset cannot
//! express is dropped, as CSS drops rules it cannot parse.

const std = @import("std");
const xml = @import("xml.zig");

pub const Combinator = enum(u8) { descendant, child };

pub const AttrSel = struct {
    name: []const u8,
    /// Null tests presence only.
    value: ?[]const u8 = null,
};

/// A compound selector: every part must match one element.
pub const Compound = struct {
    /// Null matches any element.
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
    attrs: []const AttrSel = &.{},
    first_child: bool = false,
    /// How the element relates to the one the compound before it matched.
    combinator: Combinator = .descendant,
};

pub const Selector = struct {
    compounds: []const Compound,
    /// Ids, then classes and attributes, then names, in base 1024.
    specificity: u32,
};

pub const Decl = struct {
    name: []const u8,
    value: []const u8,
    important: bool = false,
};

pub const Rule = struct {
    selector: Selector,
    decls: []const Decl,
};

pub const Error = error{OutOfMemory};

/// Appends the rules of `text` to `rules`, one per selector of each rule
/// set, in source order.
pub fn parseSheet(arena: std.mem.Allocator, text: []const u8, rules: *std.ArrayList(Rule)) Error!void {
    const src = try stripComments(arena, text);
    var i: usize = 0;
    while (i < src.len) {
        i = skipSpace(src, i);
        if (i >= src.len) break;
        if (src[i] == '@') {
            i = skipAtRule(src, i);
            continue;
        }
        const open = std.mem.indexOfScalarPos(u8, src, i, '{') orelse break;
        const close = matchingBrace(src, open) orelse src.len;
        const prelude = src[i..open];
        const body = src[open + 1 .. @min(close, src.len)];
        i = @min(close + 1, src.len);
        const decls = try parseDecls(arena, body);
        if (decls.len == 0) continue;
        // One selector failing to parse drops the rule set.
        var sels: std.ArrayList(Selector) = .empty;
        var it = std.mem.splitScalar(u8, prelude, ',');
        const ok = while (it.next()) |part| {
            const sel = try parseSelector(arena, part) orelse break false;
            try sels.append(arena, sel);
        } else true;
        if (!ok) continue;
        for (sels.items) |sel| try rules.append(arena, .{ .selector = sel, .decls = decls });
    }
}

/// Declarations of a rule body or a `style` attribute.
pub fn parseDecls(arena: std.mem.Allocator, body: []const u8) Error![]const Decl {
    var out: std.ArrayList(Decl) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        // Up to the next semicolon outside parentheses and quotes.
        var j = i;
        var depth: u32 = 0;
        var quote: u8 = 0;
        while (j < body.len) : (j += 1) {
            const ch = body[j];
            if (quote != 0) {
                if (ch == quote) quote = 0;
            } else switch (ch) {
                '"', '\'' => quote = ch,
                '(' => depth += 1,
                ')' => depth -|= 1,
                ';' => if (depth == 0) break,
                else => {},
            }
        }
        const decl = body[i..j];
        i = j + 1;
        const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
        const name = trim(decl[0..colon]);
        var value = trim(decl[colon + 1 ..]);
        if (name.len == 0 or value.len == 0) continue;
        var important = false;
        if (std.mem.lastIndexOfScalar(u8, value, '!')) |bang| {
            if (std.ascii.eqlIgnoreCase(trim(value[bang + 1 ..]), "important")) {
                important = true;
                value = trim(value[0..bang]);
            }
        }
        try out.append(arena, .{ .name = try lower(arena, name), .value = value, .important = important });
    }
    return out.items;
}

/// Null when the selector uses something this subset does not support.
pub fn parseSelector(arena: std.mem.Allocator, text: []const u8) Error!?Selector {
    var compounds: std.ArrayList(Compound) = .empty;
    var spec: u32 = 0;
    var i: usize = 0;
    var comb: Combinator = .descendant;
    const s = trim(text);
    if (s.len == 0) return null;
    while (i < s.len) {
        var c: Compound = .{ .combinator = comb };
        var classes: std.ArrayList([]const u8) = .empty;
        var attrs: std.ArrayList(AttrSel) = .empty;
        var any = false;
        while (i < s.len and !std.ascii.isWhitespace(s[i]) and s[i] != '>') {
            switch (s[i]) {
                '*' => i += 1,
                '.', '#' => {
                    const kind = s[i];
                    const start = i + 1;
                    i = identEnd(s, start);
                    if (i == start) return null;
                    if (kind == '.') {
                        try classes.append(arena, s[start..i]);
                        spec += 1 << 10;
                    } else {
                        c.id = s[start..i];
                        spec += 1 << 20;
                    }
                },
                '[' => {
                    const end = std.mem.indexOfScalarPos(u8, s, i, ']') orelse return null;
                    const inner = s[i + 1 .. end];
                    i = end + 1;
                    spec += 1 << 10;
                    if (std.mem.indexOfScalar(u8, inner, '=')) |eq| {
                        if (eq > 0 and std.mem.indexOfScalar(u8, "~|^$*", inner[eq - 1]) != null) return null;
                        try attrs.append(arena, .{ .name = trim(inner[0..eq]), .value = unquote(trim(inner[eq + 1 ..])) });
                    } else try attrs.append(arena, .{ .name = trim(inner) });
                },
                ':' => {
                    const start = i + 1;
                    i = identEnd(s, start);
                    if (!std.mem.eql(u8, s[start..i], "first-child")) return null;
                    c.first_child = true;
                    spec += 1 << 10;
                },
                else => {
                    const start = i;
                    i = identEnd(s, start);
                    if (i == start) return null;
                    c.tag = s[start..i];
                    spec += 1;
                },
            }
            any = true;
        }
        if (!any) return null;
        c.classes = classes.items;
        c.attrs = attrs.items;
        try compounds.append(arena, c);
        // A combinator: whitespace, '>', or both.
        comb = .descendant;
        while (i < s.len and (std.ascii.isWhitespace(s[i]) or s[i] == '>')) : (i += 1) {
            if (s[i] == '>') comb = .child;
        }
        if (i >= s.len and comb == .child) return null;
    }
    return .{ .compounds = compounds.items, .specificity = spec };
}

/// Whether `sel` matches element `node`.
pub fn matches(sel: Selector, doc: *const xml.Document, node: u32) bool {
    const cs = sel.compounds;
    if (cs.len == 0 or !matchCompound(cs[cs.len - 1], doc, node)) return false;
    return matchUp(cs[0 .. cs.len - 1], cs[cs.len - 1].combinator, doc, doc.nodes[node].parent);
}

/// Matches `rest` (right to left) against ancestors starting at `start`.
fn matchUp(rest: []const Compound, comb: Combinator, doc: *const xml.Document, start: u32) bool {
    if (rest.len == 0) return true;
    const c = rest[rest.len - 1];
    var n = start;
    while (n != xml.none) : (n = doc.nodes[n].parent) {
        if (matchCompound(c, doc, n) and matchUp(rest[0 .. rest.len - 1], c.combinator, doc, doc.nodes[n].parent)) return true;
        if (comb == .child) return false;
    }
    return false;
}

fn matchCompound(c: Compound, doc: *const xml.Document, node: u32) bool {
    const n = &doc.nodes[node];
    if (c.tag) |t| if (!std.mem.eql(u8, t, n.name)) return false;
    if (c.id) |id| if (!std.mem.eql(u8, id, n.attr("id") orelse return false)) return false;
    if (c.classes.len != 0) {
        const list = n.attr("class") orelse return false;
        for (c.classes) |want| if (!hasClass(list, want)) return false;
    }
    for (c.attrs) |a| {
        const v = n.attr(a.name) orelse return false;
        if (a.value) |want| if (!std.mem.eql(u8, v, want)) return false;
    }
    if (c.first_child) {
        if (n.parent == xml.none or doc.nodes[n.parent].first_child != node) return false;
    }
    return true;
}

pub fn hasClass(list: []const u8, want: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
    while (it.next()) |cls| if (std.mem.eql(u8, cls, want)) return true;
    return false;
}

fn identEnd(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch >= 0x80)) break;
    }
    return i;
}

fn skipSpace(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    return i;
}

fn skipAtRule(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) : (i += 1) {
        if (s[i] == ';') return i + 1;
        if (s[i] == '{') return (matchingBrace(s, i) orelse s.len - 1) + 1;
    }
    return s.len;
}

fn matchingBrace(s: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn stripComments(arena: std.mem.Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.indexOf(u8, text, "/*") == null) return text;
    var out: std.ArrayList(u8) = try .initCapacity(arena, text.len);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "/*")) |start| {
        out.appendSliceAssumeCapacity(text[i..start]);
        out.appendAssumeCapacity(' ');
        i = if (std.mem.indexOfPos(u8, text, start + 2, "*/")) |end| end + 2 else text.len;
    }
    if (i < text.len) out.appendSliceAssumeCapacity(text[i..]);
    return out.items;
}

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

fn lower(arena: std.mem.Allocator, s: []const u8) Error![]const u8 {
    for (s) |ch| {
        if (std.ascii.isUpper(ch)) break;
    } else return s;
    return std.ascii.allocLowerString(arena, s);
}

const testing = std.testing;

test "sheets, selectors, and specificity" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rules: std.ArrayList(Rule) = .empty;
    try parseSheet(a,
        \\/* Breeze */ @import url(x.css);
        \\.ColorScheme-Text { color:#232629; }
        \\rect, circle , path { fill: #000 !important; }
        \\g > path.a#b[data-x="1"]:first-child { opacity: .5 }
        \\@media screen { path { fill: red } }
        \\path::before { fill: blue }
    , &rules);
    try testing.expectEqual(@as(usize, 5), rules.items.len);
    try testing.expectEqualStrings("ColorScheme-Text", rules.items[0].selector.compounds[0].classes[0]);
    try testing.expectEqualStrings("color", rules.items[0].decls[0].name);
    try testing.expectEqualStrings("#232629", rules.items[0].decls[0].value);
    try testing.expect(rules.items[2].decls[0].important);
    try testing.expectEqualStrings("#000", rules.items[2].decls[0].value);
    const last = rules.items[4].selector;
    try testing.expectEqual(@as(usize, 2), last.compounds.len);
    try testing.expectEqual(Combinator.child, last.compounds[1].combinator);
    try testing.expectEqual(@as(u32, (1 << 20) + (3 << 10) + 2), last.specificity);

    const doc = try xml.parse(a, "<svg><g><path class='a' id='b' data-x='1'/><path class='a'/></g></svg>", .{});
    try testing.expect(matches(last, &doc, 2));
    try testing.expect(!matches(last, &doc, 3));
    const desc = (try parseSelector(a, "svg path")).?;
    try testing.expect(matches(desc, &doc, 3));
    try testing.expect(!matches((try parseSelector(a, "svg > path")).?, &doc, 3));
}

test "declarations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try parseDecls(arena.allocator(), "fill:url(#a;b) ; Stroke : none !IMPORTANT;;bad;opacity:");
    try testing.expectEqual(@as(usize, 2), d.len);
    try testing.expectEqualStrings("url(#a;b)", d[0].value);
    try testing.expectEqualStrings("stroke", d[1].name);
    try testing.expect(d[1].important);
}
