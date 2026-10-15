//! Stylesheets (CSS Syntax 3 rule parsing, Cascade 5 at-rules): style
//! rules, `@media`, `@supports`, `@import`, `@layer`, and `@font-face`;
//! other at-rules (`@page`, `@keyframes`, `@container`, ...) are skipped.
//! Everything a sheet holds lives in its arena.

const std = @import("std");
const tk = @import("tokenizer.zig");
const selector = @import("selector.zig");
const media = @import("media.zig");
const properties = @import("properties.zig");
const style = @import("style.zig");

const Token = tk.Token;
const Allocator = std.mem.Allocator;
const Error = error{OutOfMemory};

pub const none: u32 = std.math.maxInt(u32);

pub const Rule = struct {
    /// Range of `store.selectors`.
    selectors: [2]u32,
    /// Range of `decls`.
    decls: [2]u32,
    /// Range of `customs`.
    customs: [2]u32,
    /// Index into `media_sets` (all of whose lists must match), or none.
    media: u32 = none,
    /// Cascade layer order; unlayered rules have the highest.
    layer: u16 = std.math.maxInt(u16),
};

pub const Custom = struct { name: []const u8, value: []const u8, important: bool };

pub const FontFace = struct {
    family: []const u8 = "",
    sources: []const Source = &.{},
    weight: [2]u16 = .{ 400, 400 },
    style: style.FontStyle = .normal,
    stretch: [2]f32 = .{ 100, 100 },
    /// Empty covers everything.
    unicode_range: []const [2]u21 = &.{},
    media: u32 = none,

    pub const Source = struct { url: []const u8, local: bool = false, format: []const u8 = "" };
};

pub const Import = struct { url: []const u8, media: u32 = none, layer: u16 = std.math.maxInt(u16) };

pub const Sheet = struct {
    arena: std.heap.ArenaAllocator,
    store: selector.Store = .{},
    rules: []const Rule = &.{},
    decls: []const properties.Declaration = &.{},
    customs: []const Custom = &.{},
    media_lists: []const media.List = &.{},
    media_sets: []const []const u32 = &.{},
    font_faces: []const FontFace = &.{},
    imports: []const Import = &.{},
    layer_names: []const []const u8 = &.{},

    pub fn deinit(s: *Sheet) void {
        s.arena.deinit();
    }

    pub fn memory(s: *const Sheet) usize {
        return s.arena.queryCapacity();
    }

    pub fn mediaMatches(s: *const Sheet, set: u32, env: *const media.Env) bool {
        if (set == none) return true;
        for (s.media_sets[set]) |l| if (!s.media_lists[l].matches(env)) return false;
        return true;
    }

    pub fn ruleDecls(s: *const Sheet, r: Rule) []const properties.Declaration {
        return s.decls[r.decls[0]..][0..r.decls[1]];
    }

    pub fn ruleCustoms(s: *const Sheet, r: Rule) []const Custom {
        return s.customs[r.customs[0]..][0..r.customs[1]];
    }

    pub fn ruleSelectors(s: *const Sheet, r: Rule) []const selector.Selector {
        return s.store.selectors.items[r.selectors[0]..][0..r.selectors[1]];
    }

    /// Whether any media query in the sheet depends on the color scheme
    /// or the width (to know what a theme or resize change restyles).
    pub fn mediaDepends(s: *const Sheet) struct { width: bool, scheme: bool } {
        var w = false;
        var sc = false;
        for (s.media_lists) |l| for (l.nodes) |n| if (n.op == .feature) switch (n.feature) {
            .width, .height, .aspect_ratio, .orientation => w = true,
            .color_scheme => sc = true,
            else => {},
        };
        return .{ .width = w, .scheme = sc };
    }
};

pub const Options = struct {
    /// Lowercase type selectors (HTML).
    html: bool = true,
};

/// Parses a stylesheet. Never fails on bad CSS: invalid parts are dropped
/// as the standard says.
pub fn parse(gpa: Allocator, src_: []const u8, options: Options) Error!Sheet {
    var sheet: Sheet = .{ .arena = .init(gpa) };
    errdefer sheet.arena.deinit();
    const a = sheet.arena.allocator();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const src = try a.dupe(u8, src_);
    const tokens = try tk.tokenizeInto(a, scratch.allocator(), src);
    var p: Parser = .{ .a = a, .sheet = &sheet, .tokens = tokens, .options = options, .src = src };
    try p.ruleList(0, tokens.len, none, std.math.maxInt(u16), true);
    sheet.rules = p.rules.items;
    sheet.decls = p.decls.items;
    sheet.customs = p.customs.items;
    sheet.media_lists = p.media_lists.items;
    sheet.media_sets = p.media_sets.items;
    sheet.font_faces = p.font_faces.items;
    sheet.imports = p.imports.items;
    sheet.layer_names = p.layers.items;
    return sheet;
}

/// Parses a `style` attribute's declarations into `out` (for inline
/// styles, which the cascade treats as one rule of their own).
pub fn parseInline(a: Allocator, src: []const u8, out: *std.ArrayList(properties.Declaration), customs: *std.ArrayList(Custom)) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const copy = try a.dupe(u8, src);
    const tokens = try tk.tokenizeInto(a, scratch.allocator(), copy);
    var dummy: Sheet = .{ .arena = undefined };
    var p: Parser = .{ .a = a, .sheet = &dummy, .tokens = tokens, .options = .{}, .src = copy };
    try p.declarations(0, tokens.len - 1, out, customs);
}

const Parser = struct {
    a: Allocator,
    sheet: *Sheet,
    tokens: []const Token,
    options: Options,
    src: []const u8,
    rules: std.ArrayList(Rule) = .empty,
    decls: std.ArrayList(properties.Declaration) = .empty,
    customs: std.ArrayList(Custom) = .empty,
    media_lists: std.ArrayList(media.List) = .empty,
    media_sets: std.ArrayList([]const u32) = .empty,
    font_faces: std.ArrayList(FontFace) = .empty,
    imports: std.ArrayList(Import) = .empty,
    layers: std.ArrayList([]const u8) = .empty,
    anon_layers: u32 = 0,

    /// The index after the block or function starting at `i` (whose
    /// opening token is tokens[i]).
    fn skipBlock(p: *const Parser, i: usize, end: usize) usize {
        var depth: usize = 0;
        var j = i;
        while (j < end) : (j += 1) switch (p.tokens[j].kind) {
            .lbrace, .lbracket, .lparen, .function => depth += 1,
            .rbrace, .rbracket, .rparen => {
                if (depth > 0) depth -= 1;
                if (depth == 0) return j + 1;
            },
            else => {},
        };
        return end;
    }

    fn ruleList(p: *Parser, start: usize, end: usize, media_set: u32, layer: u16, top: bool) Error!void {
        var i = start;
        while (i < end) {
            const t = p.tokens[i];
            switch (t.kind) {
                .whitespace, .semicolon => i += 1,
                .cdo, .cdc => {
                    if (top) i += 1 else i = try p.qualified(i, end, media_set, layer);
                },
                .eof => return,
                .at_keyword => i = try p.atRule(i, end, media_set, layer),
                else => i = try p.qualified(i, end, media_set, layer),
            }
        }
    }

    /// A qualified rule: prelude up to `{`, then a declaration block.
    fn qualified(p: *Parser, start: usize, end: usize, media_set: u32, layer: u16) Error!usize {
        var i = start;
        while (i < end and p.tokens[i].kind != .lbrace) {
            switch (p.tokens[i].kind) {
                .lparen, .lbracket, .function => i = p.skipBlock(i, end),
                .eof => return end,
                else => i += 1,
            }
        }
        if (i >= end) return end;
        const block_end = p.skipBlock(i, end);
        const prelude = p.tokens[start..i];
        var sp: selector.Parser = .{ .a = p.a, .store = &p.sheet.store, .tokens = prelude, .html = p.options.html };
        const sels = try sp.list(false, false);
        if (sels) |range| {
            const d0: u32 = @intCast(p.decls.items.len);
            const c0: u32 = @intCast(p.customs.items.len);
            try p.declarations(i + 1, block_end - 1, &p.decls, &p.customs);
            const d1: u32 = @intCast(p.decls.items.len);
            const c1: u32 = @intCast(p.customs.items.len);
            if (d1 > d0 or c1 > c0) try p.rules.append(p.a, .{
                .selectors = range,
                .decls = .{ d0, d1 - d0 },
                .customs = .{ c0, c1 - c0 },
                .media = media_set,
                .layer = layer,
            });
        }
        return block_end;
    }

    /// Declarations in `tokens[start..end]` (a block's inside). Nested
    /// rules (CSS Nesting) are skipped.
    fn declarations(p: *Parser, start: usize, end: usize, out: *std.ArrayList(properties.Declaration), customs: *std.ArrayList(Custom)) Error!void {
        var i = start;
        while (i < end) {
            const t = p.tokens[i];
            switch (t.kind) {
                .whitespace, .semicolon => {
                    i += 1;
                    continue;
                },
                .ident => {},
                .at_keyword => {
                    // Nested at-rules: skip to the end of their block.
                    while (i < end and p.tokens[i].kind != .lbrace and p.tokens[i].kind != .semicolon) i += 1;
                    if (i < end and p.tokens[i].kind == .lbrace) i = p.skipBlock(i, end);
                    continue;
                },
                else => {
                    // A nested rule or junk: skip to `;` or past a block.
                    while (i < end and p.tokens[i].kind != .semicolon and p.tokens[i].kind != .lbrace) {
                        i = if (p.tokens[i].kind == .lparen or p.tokens[i].kind == .function or p.tokens[i].kind == .lbracket) p.skipBlock(i, end) else i + 1;
                    }
                    if (i < end and p.tokens[i].kind == .lbrace) i = p.skipBlock(i, end);
                    continue;
                },
            }
            // name : value [!important] ;
            const name = t.text;
            var j = i + 1;
            while (j < end and p.tokens[j].kind == .whitespace) j += 1;
            if (j >= end or p.tokens[j].kind != .colon) {
                // Not a declaration (maybe a nested rule `a:hover {}` would
                // have a colon...): skip.
                while (j < end and p.tokens[j].kind != .semicolon and p.tokens[j].kind != .lbrace) j += 1;
                if (j < end and p.tokens[j].kind == .lbrace) j = p.skipBlock(j, end);
                i = j;
                continue;
            }
            j += 1;
            const vstart = j;
            var nested = false;
            while (j < end and p.tokens[j].kind != .semicolon) {
                const k = p.tokens[j].kind;
                if (k == .lbrace) {
                    nested = true;
                    j = p.skipBlock(j, end);
                    continue;
                }
                j = if (k == .lparen or k == .function or k == .lbracket) p.skipBlock(j, end) else j + 1;
            }
            var vend = j;
            i = j;
            if (nested and !std.mem.startsWith(u8, name, "--")) continue;
            // !important
            var important = false;
            var e = vend;
            while (e > vstart and p.tokens[e - 1].kind == .whitespace) e -= 1;
            if (e > vstart and p.tokens[e - 1].isIdent("important")) {
                var b = e - 1;
                while (b > vstart and p.tokens[b - 1].kind == .whitespace) b -= 1;
                if (b > vstart and p.tokens[b - 1].isDelim('!')) {
                    important = true;
                    vend = b - 1;
                }
            }
            const value = p.tokens[vstart..vend];
            if (std.mem.startsWith(u8, name, "--")) {
                var v = value;
                while (v.len > 0 and v[0].kind == .whitespace) v = v[1..];
                while (v.len > 0 and v[v.len - 1].kind == .whitespace) v = v[0 .. v.len - 1];
                try customs.append(p.a, .{ .name = try p.a.dupe(u8, name), .value = try properties.tokenText(p.a, v), .important = important });
                continue;
            }
            const prop = properties.lookup(name) orelse continue;
            try properties.parse(p.a, prop, value, important, out);
        }
    }

    fn mediaList(p: *Parser, prelude: []const Token) Error!u32 {
        var toks: std.ArrayList(Token) = .empty;
        try toks.appendSlice(p.a, prelude);
        try toks.append(p.a, .{ .kind = .eof });
        const list = try media.parse(p.a, toks.items, 16);
        try p.media_lists.append(p.a, list);
        return @intCast(p.media_lists.items.len - 1);
    }

    fn withMedia(p: *Parser, outer: u32, list: u32) Error!u32 {
        var set: std.ArrayList(u32) = .empty;
        if (outer != none) try set.appendSlice(p.a, p.media_sets.items[outer]);
        try set.append(p.a, list);
        try p.media_sets.append(p.a, set.items);
        return @intCast(p.media_sets.items.len - 1);
    }

    fn layerOrder(p: *Parser, name: []const u8) Error!u16 {
        for (p.layers.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
        try p.layers.append(p.a, try p.a.dupe(u8, name));
        return @intCast(@min(p.layers.items.len - 1, std.math.maxInt(u16) - 1));
    }

    fn atRule(p: *Parser, start: usize, end: usize, media_set: u32, layer: u16) Error!usize {
        const name = p.tokens[start].text;
        var i = start + 1;
        // Prelude up to `{` or `;`.
        while (i < end and p.tokens[i].kind != .lbrace and p.tokens[i].kind != .semicolon) {
            i = switch (p.tokens[i].kind) {
                .lparen, .lbracket, .function => p.skipBlock(i, end),
                else => i + 1,
            };
        }
        const prelude = p.tokens[start + 1 .. @min(i, end)];
        const has_block = i < end and p.tokens[i].kind == .lbrace;
        const block_end = if (has_block) p.skipBlock(i, end) else @min(i + 1, end);
        const inner_start = i + 1;
        const inner_end = if (has_block) block_end - 1 else inner_start;
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(name, "media") and has_block) {
            const list = try p.mediaList(prelude);
            try p.ruleList(inner_start, inner_end, try p.withMedia(media_set, list), layer, false);
        } else if (eq(name, "supports") and has_block) {
            var c: Cond = .{ .p = p, .t = prelude };
            if (c.condition()) try p.ruleList(inner_start, inner_end, media_set, layer, false);
        } else if (eq(name, "layer")) {
            var lname: std.ArrayList(u8) = .empty;
            var names_done = false;
            for (prelude) |t| switch (t.kind) {
                .ident => try lname.appendSlice(p.a, t.text),
                .delim => if (t.delim == '.') try lname.append(p.a, '.'),
                .comma => {
                    if (!has_block) _ = try p.layerOrder(lname.items);
                    lname = .empty;
                    names_done = true;
                },
                else => {},
            };
            if (has_block) {
                const order = if (lname.items.len == 0) blk: {
                    p.anon_layers += 1;
                    break :blk try p.layerOrder(try std.fmt.allocPrint(p.a, "\x00anon{d}", .{p.anon_layers}));
                } else try p.layerOrder(lname.items);
                try p.ruleList(inner_start, inner_end, media_set, order, false);
            } else if (lname.items.len > 0) _ = try p.layerOrder(lname.items);
        } else if (eq(name, "import") and !has_block) {
            var j: usize = 0;
            while (j < prelude.len and prelude[j].kind == .whitespace) j += 1;
            if (j < prelude.len) {
                const t = prelude[j];
                var url: ?[]const u8 = null;
                if (t.kind == .url or t.kind == .string) url = t.text;
                if (t.isFunction("url")) {
                    j += 1;
                    while (j < prelude.len and prelude[j].kind == .whitespace) j += 1;
                    if (j < prelude.len and prelude[j].kind == .string) url = prelude[j].text;
                    while (j < prelude.len and prelude[j].kind != .rparen) j += 1;
                }
                if (url) |u| {
                    var imp_layer = layer;
                    var rest = prelude[j + 1 ..];
                    while (rest.len > 0 and rest[0].kind == .whitespace) rest = rest[1..];
                    if (rest.len > 0 and (rest[0].isIdent("layer") or rest[0].isFunction("layer"))) {
                        p.anon_layers += 1;
                        imp_layer = try p.layerOrder(try std.fmt.allocPrint(p.a, "\x00import{d}", .{p.anon_layers}));
                        rest = if (rest[0].kind == .function) blk: {
                            var k: usize = 0;
                            while (k < rest.len and rest[k].kind != .rparen) k += 1;
                            break :blk rest[@min(rest.len, k + 1)..];
                        } else rest[1..];
                    }
                    const mset = if (rest.len > 0) try p.withMedia(media_set, try p.mediaList(rest)) else media_set;
                    try p.imports.append(p.a, .{ .url = try p.a.dupe(u8, u), .media = mset, .layer = imp_layer });
                }
            }
        } else if (eq(name, "font-face") and has_block) {
            try p.fontFace(inner_start, inner_end, media_set);
        }
        return block_end;
    }

    fn fontFace(p: *Parser, start: usize, end: usize, media_set: u32) Error!void {
        var face: FontFace = .{ .media = media_set };
        var i = start;
        while (i < end) {
            while (i < end and p.tokens[i].kind != .ident) i += 1;
            if (i >= end) break;
            const name = p.tokens[i].text;
            var j = i + 1;
            while (j < end and p.tokens[j].kind == .whitespace) j += 1;
            if (j >= end or p.tokens[j].kind != .colon) {
                i = j;
                continue;
            }
            j += 1;
            const vs = j;
            while (j < end and p.tokens[j].kind != .semicolon) {
                j = switch (p.tokens[j].kind) {
                    .lparen, .function, .lbracket => p.skipBlock(j, end),
                    else => j + 1,
                };
            }
            const value = p.tokens[vs..j];
            i = j + 1;
            var c: properties.Cursor = .{ .t = value, .a = p.a };
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(name, "font-family")) {
                const t = c.take();
                if (t.kind == .string) face.family = try p.a.dupe(u8, t.text) else if (t.kind == .ident) {
                    var n: std.ArrayList(u8) = .empty;
                    try n.appendSlice(p.a, t.text);
                    while (c.peek().kind == .ident) {
                        try n.append(p.a, ' ');
                        try n.appendSlice(p.a, c.take().text);
                    }
                    face.family = n.items;
                }
            } else if (eq(name, "src")) {
                var srcs: std.ArrayList(FontFace.Source) = .empty;
                while (!c.done()) {
                    const t = c.take();
                    var src: ?FontFace.Source = null;
                    if (t.kind == .url) {
                        src = .{ .url = try p.a.dupe(u8, t.text) };
                    } else if (t.isFunction("url")) {
                        var s = c.sub(c.args());
                        const st = s.take();
                        if (st.kind == .string) src = .{ .url = try p.a.dupe(u8, st.text) };
                    } else if (t.isFunction("local")) {
                        var s = c.sub(c.args());
                        const st = s.take();
                        if (st.kind == .string or st.kind == .ident) src = .{ .url = try p.a.dupe(u8, st.text), .local = true };
                    } else if (t.kind == .comma) continue else {
                        if (t.kind == .function) _ = c.args();
                        continue;
                    }
                    // format(...) and tech(...) hints.
                    while (c.peek().kind == .function) {
                        const f = c.take();
                        var s = c.sub(c.args());
                        if (f.isFunction("format")) {
                            const st = s.take();
                            if (src) |*sr| sr.format = try p.a.dupe(u8, st.text);
                        }
                    }
                    if (src) |sr| try srcs.append(p.a, sr);
                }
                face.sources = srcs.items;
            } else if (eq(name, "font-weight")) {
                var w: [2]u16 = .{ 400, 400 };
                var n: usize = 0;
                while (!c.done() and n < 2) : (n += 1) {
                    const t = c.take();
                    w[n] = if (t.kind == .number) @intFromFloat(std.math.clamp(t.number, 1, 1000)) else if (t.isIdent("bold")) 700 else 400;
                }
                if (n == 1) w[1] = w[0];
                face.weight = w;
            } else if (eq(name, "font-style")) {
                const t = c.take();
                face.style = if (t.isIdent("italic")) .italic else if (t.isIdent("oblique")) .oblique else .normal;
            } else if (eq(name, "font-stretch")) {
                var s: [2]f32 = .{ 100, 100 };
                var n: usize = 0;
                while (!c.done() and n < 2) : (n += 1) {
                    const t = c.take();
                    s[n] = if (t.kind == .percentage) @floatCast(t.number) else 100;
                }
                if (n == 1) s[1] = s[0];
                face.stretch = s;
            } else if (eq(name, "unicode-range")) {
                if (value.len > 0) face.unicode_range = try unicodeRanges(p.a, p.src[value[0].start..value[value.len - 1].end]);
            }
        }
        if (face.family.len > 0 and face.sources.len > 0) try p.font_faces.append(p.a, face);
    }
};

/// `U+0-7F, U+0400-04FF, U+4??`, from the source text (tokens split
/// them oddly).
fn unicodeRanges(a: Allocator, text: []const u8) Error![]const [2]u21 {
    var out: std.ArrayList([2]u21) = .empty;
    var it = std.mem.tokenizeAny(u8, text, ", ");
    while (it.next()) |raw| {
        var s = raw;
        if (s.len < 3 or !(s[0] == 'u' or s[0] == 'U') or s[1] != '+') continue;
        s = s[2..];
        // Remove spaces the serializer added.
        var buf: [32]u8 = undefined;
        var n: usize = 0;
        for (s) |ch| if (ch != ' ' and n < buf.len) {
            buf[n] = ch;
            n += 1;
        };
        const r = buf[0..n];
        if (std.mem.indexOfScalar(u8, r, '-')) |dash| {
            const lo = std.fmt.parseInt(u21, r[0..dash], 16) catch continue;
            const hi = std.fmt.parseInt(u21, r[dash + 1 ..], 16) catch continue;
            try out.append(a, .{ lo, hi });
        } else if (std.mem.indexOfScalar(u8, r, '?')) |_| {
            var lo_buf: [8]u8 = undefined;
            var hi_buf: [8]u8 = undefined;
            if (r.len > 8) continue;
            for (r, 0..) |ch, k| {
                lo_buf[k] = if (ch == '?') '0' else ch;
                hi_buf[k] = if (ch == '?') 'F' else ch;
            }
            const lo = std.fmt.parseInt(u21, lo_buf[0..r.len], 16) catch continue;
            const hi = std.fmt.parseInt(u21, hi_buf[0..r.len], 16) catch continue;
            try out.append(a, .{ lo, hi });
        } else {
            const v = std.fmt.parseInt(u21, r, 16) catch continue;
            try out.append(a, .{ v, v });
        }
    }
    return out.items;
}

/// @supports conditions.
const Cond = struct {
    p: *Parser,
    t: []const Token,
    i: usize = 0,

    fn skipWs(c: *Cond) void {
        while (c.i < c.t.len and c.t[c.i].kind == .whitespace) c.i += 1;
    }

    fn peek(c: *Cond) Token {
        c.skipWs();
        return if (c.i < c.t.len) c.t[c.i] else .{ .kind = .eof };
    }

    fn condition(c: *Cond) bool {
        if (c.peek().isIdent("not")) {
            c.i += 1;
            return !c.inParens();
        }
        var r = c.inParens();
        while (true) {
            const t = c.peek();
            if (t.isIdent("and")) {
                c.i += 1;
                r = c.inParens() and r;
            } else if (t.isIdent("or")) {
                c.i += 1;
                r = c.inParens() or r;
            } else return r;
        }
    }

    fn closeOf(c: *Cond, open: usize) usize {
        var depth: usize = 0;
        var j = open;
        while (j < c.t.len) : (j += 1) switch (c.t[j].kind) {
            .lparen, .function => depth += 1,
            .rparen => {
                depth -= 1;
                if (depth == 0) return j;
            },
            else => {},
        };
        return c.t.len;
    }

    fn inParens(c: *Cond) bool {
        const t = c.peek();
        const open = c.i;
        const close = c.closeOf(open);
        defer c.i = @min(c.t.len, close + 1);
        if (t.isFunction("selector")) {
            var sp: selector.Parser = .{ .a = c.p.a, .store = &c.p.sheet.store, .tokens = c.t[open + 1 .. close] };
            return (sp.list(false, false) catch null) != null;
        }
        if (t.kind == .function) return false;
        if (t.kind != .lparen) return false;
        var inner: Cond = .{ .p = c.p, .t = c.t[open + 1 .. close] };
        const it = inner.peek();
        if (it.kind == .lparen or it.isIdent("not") or it.kind == .function) return inner.condition();
        // (property: value)
        if (it.kind != .ident) return false;
        inner.i += 1;
        if (inner.peek().kind != .colon) return false;
        inner.i += 1;
        if (std.mem.startsWith(u8, it.text, "--")) return true;
        const prop = properties.lookup(it.text) orelse return false;
        var out: std.ArrayList(properties.Declaration) = .empty;
        properties.parse(c.p.a, prop, inner.t[inner.i..], false, &out) catch return false;
        return out.items.len > 0;
    }
};

test "stylesheet" {
    var s = try parse(std.testing.allocator,
        \\@charset "utf-8";
        \\@import url("base.css") screen;
        \\:root { --accent: #06c; }
        \\body { margin: 0; font: 16px/1.5 system-ui, sans-serif }
        \\a { color: var(--accent) !important }
        \\@media (prefers-color-scheme: dark) { body { background: #111; color: #eee } }
        \\@supports (display: grid) and (not (display: frobnicate)) { .g { display: grid } }
        \\@supports (display: frobnicate) { .x { color: red } }
        \\@font-face { font-family: "Inter Var"; src: url(inter.woff2) format("woff2"), local(Inter); font-weight: 100 900; unicode-range: U+0000-00FF, U+4?? }
        \\@layer base { p { color: gray } }
        \\@keyframes spin { from { transform: rotate(0) } }
        \\h1 { color: red; nonsense: 3; width: ; }
        \\.bad! { color: red }
        \\nav { & a { color: blue } color: green }
    , .{});
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 1), s.imports.len);
    try std.testing.expectEqualStrings("base.css", s.imports[0].url);
    // :root, body, a, body (dark), .g, p, h1, nav.
    try std.testing.expectEqual(@as(usize, 8), s.rules.len);
    try std.testing.expectEqual(@as(usize, 1), s.font_faces.len);
    const ff = s.font_faces[0];
    try std.testing.expectEqualStrings("Inter Var", ff.family);
    try std.testing.expectEqual([2]u16{ 100, 900 }, ff.weight);
    try std.testing.expectEqual(@as(usize, 2), ff.sources.len);
    try std.testing.expect(ff.sources[1].local);
    try std.testing.expectEqual(@as(usize, 2), ff.unicode_range.len);
    try std.testing.expectEqual([2]u21{ 0x400, 0x4FF }, ff.unicode_range[1]);
    const a_rule = s.rules[2];
    try std.testing.expect(s.ruleDecls(a_rule)[0].important);
    try std.testing.expect(s.ruleDecls(a_rule)[0].value == .unparsed);
    try std.testing.expect(s.mediaDepends().scheme);
    try std.testing.expectEqual(@as(u16, 0), s.rules[5].layer);
    // nav keeps its own declaration, not the nested rule's.
    try std.testing.expectEqual(@as(usize, 1), s.ruleDecls(s.rules[7]).len);
}
