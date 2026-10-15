//! Media queries (Media Queries Level 4 and 5, the features documents
//! use): media types, `not` and `only`, `and`/`or` conditions, ranges
//! (`width >= 600px`, `400px < width < 800px`) and min-/max- prefixes for
//! width, height, aspect-ratio, and resolution, and prefers-color-scheme,
//! prefers-reduced-motion, prefers-contrast, orientation, hover, pointer,
//! and color. Unknown features are false, so their rules never apply.

const std = @import("std");
const tk = @import("tokenizer.zig");
const values = @import("values.zig");
const Token = tk.Token;

/// Where a document is shown.
pub const Env = struct {
    width: f32 = 800,
    height: f32 = 600,
    dark: bool = false,
    print: bool = false,
    reduced_motion: bool = false,
    high_contrast: bool = false,
    font_size: f32 = 16,
    /// Device pixels per CSS pixel.
    resolution: f32 = 1,
};

/// A parsed query list: a tree of conditions evaluated against an `Env`.
pub const List = struct {
    nodes: []const Node,
    /// Roots of the comma-separated queries; the list matches when any
    /// does. Empty matches everything.
    queries: []const u32,

    pub fn matches(l: List, env: *const Env) bool {
        if (l.queries.len == 0) return true;
        for (l.queries) |q| if (l.eval(q, env)) return true;
        return false;
    }

    fn eval(l: List, i: u32, env: *const Env) bool {
        const n = l.nodes[i];
        return switch (n.op) {
            .always => true,
            .never => false,
            .not => !l.eval(n.a, env),
            .@"and" => l.eval(n.a, env) and l.eval(n.b, env),
            .@"or" => l.eval(n.a, env) or l.eval(n.b, env),
            .media_type => switch (n.media) {
                .all => true,
                .screen => !env.print,
                .print => env.print,
                .other => false,
            },
            .feature => feature(n, env),
        };
    }
};

pub const Op = enum(u8) { always, never, not, @"and", @"or", media_type, feature };
pub const MediaType = enum(u8) { all, screen, print, other };
pub const Feature = enum(u8) { width, height, aspect_ratio, resolution, color_scheme, reduced_motion, contrast, orientation, hover, any_hover, pointer, any_pointer, color, monochrome, grid, scripting, unknown };
pub const Cmp = enum(u8) { exists, eq, lt, le, gt, ge };

pub const Node = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
    media: MediaType = .all,
    feature: Feature = .unknown,
    cmp: Cmp = .exists,
    /// Number in px (lengths), dppx, or a ratio; or a keyword hash.
    value: f32 = 0,
    keyword: Keyword = .none,
};

pub const Keyword = enum(u8) { none, dark, light, reduce, no_preference, more, less, custom, landscape, portrait, hover, fine, coarse, other };

fn feature(n: Node, env: *const Env) bool {
    const num: ?f32 = switch (n.feature) {
        .width => env.width,
        .height => env.height,
        .aspect_ratio => if (env.height > 0) env.width / env.height else 0,
        .resolution => env.resolution,
        .color => 8,
        .monochrome => 0,
        .grid => 0,
        else => null,
    };
    if (num) |v| return switch (n.cmp) {
        .exists => v != 0,
        .eq => @abs(v - n.value) < 0.01,
        .lt => v < n.value,
        .le => v <= n.value + 0.001,
        .gt => v > n.value,
        .ge => v >= n.value - 0.001,
    };
    return switch (n.feature) {
        .color_scheme => n.cmp == .exists or (n.keyword == .dark) == env.dark and (n.keyword == .dark or n.keyword == .light),
        .reduced_motion => if (n.cmp == .exists) env.reduced_motion else (n.keyword == .reduce) == env.reduced_motion and (n.keyword == .reduce or n.keyword == .no_preference),
        .contrast => if (n.cmp == .exists) env.high_contrast else switch (n.keyword) {
            .more => env.high_contrast,
            .no_preference => !env.high_contrast,
            else => false,
        },
        .orientation => (n.keyword == .landscape) == (env.width > env.height) and (n.keyword == .landscape or n.keyword == .portrait),
        .hover, .any_hover => n.cmp == .exists or n.keyword == .hover,
        .pointer, .any_pointer => n.cmp == .exists or n.keyword == .fine,
        .scripting => n.keyword == .none and n.cmp != .exists,
        else => false,
    };
}

fn featureOf(name: []const u8) struct { Feature, Cmp } {
    var base = name;
    var cmp: Cmp = .eq;
    if (std.ascii.startsWithIgnoreCase(name, "min-")) {
        base = name[4..];
        cmp = .ge;
    } else if (std.ascii.startsWithIgnoreCase(name, "max-")) {
        base = name[4..];
        cmp = .le;
    }
    const map = [_]struct { []const u8, Feature }{
        .{ "width", .width },                     .{ "height", .height },                 .{ "aspect-ratio", .aspect_ratio },
        .{ "resolution", .resolution },           .{ "prefers-color-scheme", .color_scheme }, .{ "prefers-reduced-motion", .reduced_motion },
        .{ "prefers-contrast", .contrast },       .{ "orientation", .orientation },       .{ "hover", .hover },
        .{ "any-hover", .any_hover },             .{ "pointer", .pointer },               .{ "any-pointer", .any_pointer },
        .{ "color", .color },                     .{ "monochrome", .monochrome },         .{ "grid", .grid },
        .{ "scripting", .scripting },             .{ "device-width", .width },            .{ "device-height", .height },
        .{ "-webkit-device-pixel-ratio", .resolution }, .{ "device-aspect-ratio", .aspect_ratio },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(base, m[0])) return .{ m[1], cmp };
    return .{ .unknown, cmp };
}

fn keywordOf(s: []const u8) Keyword {
    const map = [_]struct { []const u8, Keyword }{
        .{ "dark", .dark },       .{ "light", .light }, .{ "reduce", .reduce },       .{ "no-preference", .no_preference }, .{ "more", .more },
        .{ "less", .less },       .{ "custom", .custom }, .{ "landscape", .landscape }, .{ "portrait", .portrait },         .{ "hover", .hover },
        .{ "fine", .fine },       .{ "coarse", .coarse }, .{ "none", .none },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(s, m[0])) return m[1];
    return .other;
}

pub fn parse(a: std.mem.Allocator, tokens: []const Token, font_size: f32) error{OutOfMemory}!List {
    var p: Parser = .{ .a = a, .tokens = tokens, .font_size = font_size };
    var queries: std.ArrayList(u32) = .empty;
    while (true) {
        p.skipWs();
        if (p.pos >= tokens.len or tokens[p.pos].kind == .eof) break;
        const start = p.pos;
        const q = (try p.query()) orelse blk: {
            // A malformed query is "not all".
            p.pos = start;
            while (p.pos < tokens.len and tokens[p.pos].kind != .comma and tokens[p.pos].kind != .eof) p.pos += 1;
            break :blk try p.add(.{ .op = .never });
        };
        try queries.append(a, q);
        p.skipWs();
        if (p.pos < tokens.len and tokens[p.pos].kind == .comma) {
            p.pos += 1;
            continue;
        }
        if (p.pos < tokens.len and tokens[p.pos].kind != .eof) {
            // Junk after a query makes it false.
            queries.items[queries.items.len - 1] = try p.add(.{ .op = .never });
            while (p.pos < tokens.len and tokens[p.pos].kind != .comma and tokens[p.pos].kind != .eof) p.pos += 1;
            if (p.pos < tokens.len and tokens[p.pos].kind == .comma) p.pos += 1;
        }
    }
    return .{ .nodes = p.nodes.items, .queries = queries.items };
}

const Parser = struct {
    a: std.mem.Allocator,
    tokens: []const Token,
    pos: usize = 0,
    nodes: std.ArrayList(Node) = .empty,
    font_size: f32,

    fn skipWs(p: *Parser) void {
        while (p.pos < p.tokens.len and p.tokens[p.pos].kind == .whitespace) p.pos += 1;
    }

    fn peek(p: *Parser) Token {
        p.skipWs();
        return if (p.pos < p.tokens.len) p.tokens[p.pos] else .{ .kind = .eof };
    }

    fn add(p: *Parser, n: Node) error{OutOfMemory}!u32 {
        try p.nodes.append(p.a, n);
        return @intCast(p.nodes.items.len - 1);
    }

    fn query(p: *Parser) error{OutOfMemory}!?u32 {
        var t = p.peek();
        if (t.kind == .lparen) return p.condition();
        var negate = false;
        if (t.isIdent("not")) {
            negate = true;
            p.pos += 1;
            t = p.peek();
            if (t.kind == .lparen) {
                const c = (try p.condition()) orelse return null;
                return try p.add(.{ .op = .not, .a = c });
            }
        } else if (t.isIdent("only")) {
            p.pos += 1;
            t = p.peek();
        }
        if (t.kind != .ident) return null;
        p.pos += 1;
        const mt: MediaType = if (t.isIdent("all")) .all else if (t.isIdent("screen")) .screen else if (t.isIdent("print")) .print else .other;
        var node = try p.add(.{ .op = .media_type, .media = mt });
        if (p.peek().isIdent("and")) {
            p.pos += 1;
            const c = (try p.conditionNoOr()) orelse return null;
            node = try p.add(.{ .op = .@"and", .a = node, .b = c });
        }
        if (negate) node = try p.add(.{ .op = .not, .a = node });
        return node;
    }

    fn condition(p: *Parser) error{OutOfMemory}!?u32 {
        if (p.peek().isIdent("not")) {
            p.pos += 1;
            const c = (try p.inParens()) orelse return null;
            return try p.add(.{ .op = .not, .a = c });
        }
        var left = (try p.inParens()) orelse return null;
        while (true) {
            const t = p.peek();
            if (t.isIdent("and") or t.isIdent("or")) {
                p.pos += 1;
                const right = (try p.inParens()) orelse return null;
                left = try p.add(.{ .op = if (t.isIdent("and")) .@"and" else .@"or", .a = left, .b = right });
            } else return left;
        }
    }

    fn conditionNoOr(p: *Parser) error{OutOfMemory}!?u32 {
        var left = (try p.inParens()) orelse return null;
        while (p.peek().isIdent("and")) {
            p.pos += 1;
            const right = (try p.inParens()) orelse return null;
            left = try p.add(.{ .op = .@"and", .a = left, .b = right });
        }
        return left;
    }

    fn inParens(p: *Parser) error{OutOfMemory}!?u32 {
        const t = p.peek();
        if (t.kind != .lparen) return null;
        p.pos += 1;
        const close = p.matching();
        defer p.pos = close + 1;
        const t2 = p.peek();
        if (t2.kind == .lparen or t2.isIdent("not")) {
            const c = try p.condition();
            return c orelse try p.add(.{ .op = .never });
        }
        return (try p.featureExpr(close)) orelse try p.add(.{ .op = .never });
    }

    /// The index of the `)` matching the `(` before `pos`.
    fn matching(p: *Parser) usize {
        var depth: usize = 1;
        var i = p.pos;
        while (i < p.tokens.len) : (i += 1) switch (p.tokens[i].kind) {
            .lparen, .function => depth += 1,
            .rparen => {
                depth -= 1;
                if (depth == 0) return i;
            },
            .eof => return i - 1,
            else => {},
        };
        return p.tokens.len - 1;
    }

    fn featureExpr(p: *Parser, close: usize) error{OutOfMemory}!?u32 {
        const t = p.peek();
        if (t.kind == .ident) {
            p.pos += 1;
            const f, const prefix_cmp = featureOf(t.text);
            const nt = p.peek();
            if (p.pos >= close) return try p.add(.{ .op = .feature, .feature = f, .cmp = .exists });
            if (nt.kind == .colon) {
                p.pos += 1;
                var n: Node = .{ .op = .feature, .feature = f, .cmp = prefix_cmp };
                const vt = p.peek();
                if (vt.kind == .ident) {
                    n.keyword = keywordOf(vt.text);
                    p.pos += 1;
                } else n.value = p.value() orelse return null;
                return try p.add(n);
            }
            // Range: feature op value.
            const op = p.cmpOp() orelse return null;
            const v = p.value() orelse return null;
            return try p.add(.{ .op = .feature, .feature = f, .cmp = op, .value = v });
        }
        // value op feature [op value].
        const v1 = p.value() orelse return null;
        const op1 = p.cmpOp() orelse return null;
        const ft = p.peek();
        if (ft.kind != .ident) return null;
        p.pos += 1;
        const f, _ = featureOf(ft.text);
        const first = try p.add(.{ .op = .feature, .feature = f, .cmp = flip(op1), .value = v1 });
        if (p.pos < close) {
            const op2 = p.cmpOp() orelse return null;
            const v2 = p.value() orelse return null;
            const second = try p.add(.{ .op = .feature, .feature = f, .cmp = op2, .value = v2 });
            return try p.add(.{ .op = .@"and", .a = first, .b = second });
        }
        return first;
    }

    fn flip(c: Cmp) Cmp {
        return switch (c) {
            .lt => .gt,
            .le => .ge,
            .gt => .lt,
            .ge => .le,
            else => c,
        };
    }

    fn cmpOp(p: *Parser) ?Cmp {
        const t = p.peek();
        if (t.kind != .delim) return null;
        p.pos += 1;
        const eq_next = p.pos < p.tokens.len and p.tokens[p.pos].isDelim('=');
        switch (t.delim) {
            '=' => return .eq,
            '<' => {
                if (eq_next) p.pos += 1;
                return if (eq_next) .le else .lt;
            },
            '>' => {
                if (eq_next) p.pos += 1;
                return if (eq_next) .ge else .gt;
            },
            else => return null,
        }
    }

    fn value(p: *Parser) ?f32 {
        const t = p.peek();
        p.pos += 1;
        switch (t.kind) {
            .number => {
                const n: f32 = @floatCast(t.number);
                // A ratio a / b.
                const save = p.pos;
                if (p.peek().isDelim('/')) {
                    p.pos += 1;
                    const d = p.peek();
                    if (d.kind == .number and d.number != 0) {
                        p.pos += 1;
                        return n / @as(f32, @floatCast(d.number));
                    }
                }
                p.pos = save;
                return n;
            },
            .dimension => {
                if (std.ascii.eqlIgnoreCase(t.text, "dppx") or std.ascii.eqlIgnoreCase(t.text, "x")) return @floatCast(t.number);
                if (std.ascii.eqlIgnoreCase(t.text, "dpi")) return @floatCast(t.number / 96);
                if (std.ascii.eqlIgnoreCase(t.text, "dpcm")) return @floatCast(t.number * 2.54 / 96);
                const u = values.unitOf(t.text) orelse return null;
                const ctx: values.Context = .{ .font_size = p.font_size, .root_font_size = p.font_size };
                return values.toPx(@floatCast(t.number), u, &ctx);
            },
            else => return null,
        }
    }
};

fn matchesStr(s: []const u8, env: Env) !bool {
    var l = try tk.tokenize(std.testing.allocator, s);
    defer l.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parse(arena.allocator(), l.tokens, 16);
    return list.matches(&env);
}

test "media queries" {
    const env: Env = .{ .width = 700, .height = 500, .dark = true };
    try std.testing.expect(try matchesStr("screen and (min-width: 600px)", env));
    try std.testing.expect(!try matchesStr("print", env));
    try std.testing.expect(try matchesStr("(prefers-color-scheme: dark)", env));
    try std.testing.expect(!try matchesStr("(prefers-color-scheme: light)", env));
    try std.testing.expect(try matchesStr("(400px < width <= 700px)", env));
    try std.testing.expect(!try matchesStr("(width > 50em)", env));
    try std.testing.expect(try matchesStr("print, (orientation: landscape)", env));
    try std.testing.expect(try matchesStr("not print", env));
    try std.testing.expect(!try matchesStr("(fancy-feature)", env));
    try std.testing.expect(try matchesStr("", env));
    try std.testing.expect(try matchesStr("(max-width: 800px) and (not (hover: none))", env));
}
