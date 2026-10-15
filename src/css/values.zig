//! Lengths, percentages, numbers, and math functions (CSS Values Level 4):
//! calc(), min(), max(), clamp(), with font-relative, viewport, and
//! absolute units. A specified length keeps its unit; computing resolves
//! everything but percentages to pixels (`Computed`), which layout
//! resolves against its basis.

const std = @import("std");
const tk = @import("tokenizer.zig");
const Token = tk.Token;

pub const Unit = enum(u8) {
    px,
    percent,
    em,
    rem,
    ex,
    rex,
    ch,
    rch,
    cap,
    ic,
    lh,
    rlh,
    vw,
    vh,
    vmin,
    vmax,
    cm,
    mm,
    q,
    in,
    pt,
    pc,
    /// A unitless number where a length is expected (0, or quirks).
    number,
};

pub fn unitOf(s: []const u8) ?Unit {
    const map = [_]struct { []const u8, Unit }{
        .{ "px", .px },     .{ "em", .em },     .{ "rem", .rem },   .{ "ex", .ex },   .{ "rex", .rex },     .{ "ch", .ch },
        .{ "rch", .rch },   .{ "cap", .cap },   .{ "ic", .ic },     .{ "lh", .lh },   .{ "rlh", .rlh },     .{ "vw", .vw },
        .{ "vh", .vh },     .{ "vmin", .vmin }, .{ "vmax", .vmax }, .{ "cm", .cm },   .{ "mm", .mm },       .{ "q", .q },
        .{ "in", .in },     .{ "pt", .pt },     .{ "pc", .pc },     .{ "svw", .vw },  .{ "svh", .vh },      .{ "lvw", .vw },
        .{ "lvh", .vh },    .{ "dvw", .vw },    .{ "dvh", .vh },    .{ "vi", .vw },   .{ "vb", .vh },       .{ "svmin", .vmin },
        .{ "svmax", .vmax }, .{ "dvmin", .vmin }, .{ "dvmax", .vmax },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(s, m[0])) return m[1];
    return null;
}

/// What resolving units needs.
pub const Context = struct {
    font_size: f32 = 16,
    root_font_size: f32 = 16,
    /// Line height in pixels, for lh.
    line_height: f32 = 19.2,
    root_line_height: f32 = 19.2,
    viewport_width: f32 = 800,
    viewport_height: f32 = 600,
    /// The font's x-height and '0' advance as fractions of the em.
    ex: f32 = 0.5,
    ch: f32 = 0.5,
};

pub fn toPx(v: f32, unit: Unit, c: *const Context) f32 {
    return switch (unit) {
        .px, .number => v,
        .percent => v, // handled by callers
        .em => v * c.font_size,
        .rem => v * c.root_font_size,
        .ex => v * c.font_size * c.ex,
        .rex => v * c.root_font_size * c.ex,
        .ch => v * c.font_size * c.ch,
        .rch => v * c.root_font_size * c.ch,
        .cap => v * c.font_size * 0.7,
        .ic => v * c.font_size,
        .lh => v * c.line_height,
        .rlh => v * c.root_line_height,
        .vw => v * c.viewport_width / 100,
        .vh => v * c.viewport_height / 100,
        .vmin => v * @min(c.viewport_width, c.viewport_height) / 100,
        .vmax => v * @max(c.viewport_width, c.viewport_height) / 100,
        .cm => v * 96 / 2.54,
        .mm => v * 96 / 25.4,
        .q => v * 96 / 101.6,
        .in => v * 96,
        .pt => v * 96 / 72,
        .pc => v * 16,
    };
}

/// A math function's tree, built once per declaration.
pub const Calc = struct {
    nodes: []const Node,

    pub const Op = enum(u8) { value, add, sub, mul, div, min, max, clamp, neg };

    pub const Node = struct {
        op: Op,
        /// value: the number and its unit (`number` for plain numbers).
        v: f32 = 0,
        unit: Unit = .number,
        /// Children (node indices); min and max list theirs in `args`.
        a: u32 = 0,
        b: u32 = 0,
        c: u32 = 0,
        args: []const u32 = &.{},
    };

    /// A computed value: pixels plus a percentage share, or `none` when a
    /// min/max/clamp mixes percentages with pixels (resolved at layout).
    pub const Linear = struct { px: f32, pct: f32, number: f32, nonlinear: bool = false };

    /// Resolves units except percentages; min and max over mixed terms
    /// need the basis, which `eval` takes.
    pub fn linear(self: Calc, ctx: *const Context) Linear {
        return self.lin(@intCast(self.nodes.len - 1), ctx);
    }

    fn lin(self: Calc, i: u32, ctx: *const Context) Linear {
        const n = self.nodes[i];
        switch (n.op) {
            .value => return switch (n.unit) {
                .number => .{ .px = 0, .pct = 0, .number = n.v },
                .percent => .{ .px = 0, .pct = n.v / 100, .number = 0 },
                else => .{ .px = toPx(n.v, n.unit, ctx), .pct = 0, .number = 0 },
            },
            .neg => {
                const x = self.lin(n.a, ctx);
                return .{ .px = -x.px, .pct = -x.pct, .number = -x.number, .nonlinear = x.nonlinear };
            },
            .add, .sub => {
                const x = self.lin(n.a, ctx);
                const y = self.lin(n.b, ctx);
                const s: f32 = if (n.op == .sub) -1 else 1;
                return .{ .px = x.px + s * y.px, .pct = x.pct + s * y.pct, .number = x.number + s * y.number, .nonlinear = x.nonlinear or y.nonlinear };
            },
            .mul => {
                const x = self.lin(n.a, ctx);
                const y = self.lin(n.b, ctx);
                // One side is a plain number.
                if (x.px == 0 and x.pct == 0) return .{ .px = y.px * x.number, .pct = y.pct * x.number, .number = y.number * x.number, .nonlinear = x.nonlinear or y.nonlinear };
                return .{ .px = x.px * y.number, .pct = x.pct * y.number, .number = x.number * y.number, .nonlinear = x.nonlinear or y.nonlinear };
            },
            .div => {
                const x = self.lin(n.a, ctx);
                const y = self.lin(n.b, ctx);
                const d = if (y.number == 0) std.math.inf(f32) else y.number;
                return .{ .px = x.px / d, .pct = x.pct / d, .number = x.number / d, .nonlinear = x.nonlinear or y.nonlinear };
            },
            .min, .max, .clamp => {
                var any_pct = false;
                var any_px = false;
                const kids: []const u32 = if (n.op == .clamp) &.{ n.a, n.b, n.c } else n.args;
                for (kids) |k| {
                    const x = self.lin(k, ctx);
                    if (x.pct != 0 or x.nonlinear) any_pct = true;
                    if (x.px != 0) any_px = true;
                }
                if (any_pct and any_px) return .{ .px = 0, .pct = 0, .number = 0, .nonlinear = true };
                if (any_pct) return .{ .px = 0, .pct = self.evalNode(i, ctx, 1), .number = 0 };
                const v = self.evalNode(i, ctx, 0);
                return if (any_px) .{ .px = v, .pct = 0, .number = 0 } else .{ .px = 0, .pct = 0, .number = v };
            },
        }
    }

    /// The value in pixels (or as a number) against a percentage basis.
    pub fn eval(self: Calc, ctx: *const Context, basis: f32) f32 {
        return self.evalNode(@intCast(self.nodes.len - 1), ctx, basis);
    }

    fn evalNode(self: Calc, i: u32, ctx: *const Context, basis: f32) f32 {
        const n = self.nodes[i];
        return switch (n.op) {
            .value => switch (n.unit) {
                .number => n.v,
                .percent => n.v / 100 * basis,
                else => toPx(n.v, n.unit, ctx),
            },
            .neg => -self.evalNode(n.a, ctx, basis),
            .add => self.evalNode(n.a, ctx, basis) + self.evalNode(n.b, ctx, basis),
            .sub => self.evalNode(n.a, ctx, basis) - self.evalNode(n.b, ctx, basis),
            .mul => self.evalNode(n.a, ctx, basis) * self.evalNode(n.b, ctx, basis),
            .div => blk: {
                const d = self.evalNode(n.b, ctx, basis);
                break :blk if (d == 0) 0 else self.evalNode(n.a, ctx, basis) / d;
            },
            .min, .max => blk: {
                var r: f32 = if (n.op == .min) std.math.inf(f32) else -std.math.inf(f32);
                for (n.args) |k| {
                    const v = self.evalNode(k, ctx, basis);
                    r = if (n.op == .min) @min(r, v) else @max(r, v);
                }
                break :blk r;
            },
            .clamp => @max(self.evalNode(n.a, ctx, basis), @min(self.evalNode(n.b, ctx, basis), self.evalNode(n.c, ctx, basis))),
        };
    }
};

/// Parses a math function whose `function` token is at `pos.*` (already
/// consumed: `pos` is after it), up to its `)`.
pub fn parseCalc(a: std.mem.Allocator, tokens: []const Token, pos: *usize, name: []const u8) error{OutOfMemory}!?Calc {
    var p: CalcParser = .{ .a = a, .tokens = tokens, .pos = pos.* };
    const root = (try p.function(name)) orelse return null;
    _ = root;
    pos.* = p.pos;
    return .{ .nodes = p.nodes.items };
}

pub fn isMathFunction(name: []const u8) bool {
    for ([_][]const u8{ "calc", "min", "max", "clamp", "-webkit-calc", "-moz-calc" }) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}

const CalcParser = struct {
    a: std.mem.Allocator,
    tokens: []const Token,
    pos: usize,
    nodes: std.ArrayList(Calc.Node) = .empty,
    depth: u32 = 0,

    fn skipWs(p: *CalcParser) void {
        while (p.pos < p.tokens.len and p.tokens[p.pos].kind == .whitespace) p.pos += 1;
    }

    fn peek(p: *CalcParser) Token {
        p.skipWs();
        return if (p.pos < p.tokens.len) p.tokens[p.pos] else .{ .kind = .eof };
    }

    fn add(p: *CalcParser, n: Calc.Node) error{OutOfMemory}!u32 {
        try p.nodes.append(p.a, n);
        return @intCast(p.nodes.items.len - 1);
    }

    /// After a function token: its arguments and `)`.
    fn function(p: *CalcParser, name: []const u8) error{OutOfMemory}!?u32 {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > 32) return null;
        if (std.ascii.eqlIgnoreCase(name, "min") or std.ascii.eqlIgnoreCase(name, "max")) {
            var args: std.ArrayList(u32) = .empty;
            while (true) {
                const e = (try p.sum()) orelse return null;
                try args.append(p.a, e);
                const t = p.peek();
                p.pos += 1;
                if (t.kind == .comma) continue;
                if (t.kind == .rparen) break;
                return null;
            }
            return try p.add(.{ .op = if (std.ascii.eqlIgnoreCase(name, "min")) .min else .max, .args = args.items });
        }
        if (std.ascii.eqlIgnoreCase(name, "clamp")) {
            var k: [3]u32 = undefined;
            for (0..3) |i| {
                k[i] = (try p.sum()) orelse return null;
                const t = p.peek();
                p.pos += 1;
                if (i < 2 and t.kind != .comma) return null;
                if (i == 2 and t.kind != .rparen) return null;
            }
            return try p.add(.{ .op = .clamp, .a = k[0], .b = k[1], .c = k[2] });
        }
        const e = (try p.sum()) orelse return null;
        if (p.peek().kind != .rparen) return null;
        p.pos += 1;
        return e;
    }

    fn sum(p: *CalcParser) error{OutOfMemory}!?u32 {
        var left = (try p.product()) orelse return null;
        while (true) {
            // + and - need whitespace around them; the tokenizer has made
            // "+5" a number already when it had none.
            const save = p.pos;
            const t = p.peek();
            if (t.isDelim('+') or t.isDelim('-')) {
                p.pos += 1;
                const right = (try p.product()) orelse return null;
                left = try p.add(.{ .op = if (t.delim == '+') .add else .sub, .a = left, .b = right });
            } else {
                p.pos = save;
                return left;
            }
        }
    }

    fn product(p: *CalcParser) error{OutOfMemory}!?u32 {
        var left = (try p.value()) orelse return null;
        while (true) {
            const save = p.pos;
            const t = p.peek();
            if (t.isDelim('*') or t.isDelim('/')) {
                p.pos += 1;
                const right = (try p.value()) orelse return null;
                left = try p.add(.{ .op = if (t.delim == '*') .mul else .div, .a = left, .b = right });
            } else {
                p.pos = save;
                return left;
            }
        }
    }

    fn value(p: *CalcParser) error{OutOfMemory}!?u32 {
        const t = p.peek();
        p.pos += 1;
        switch (t.kind) {
            .number => return try p.add(.{ .op = .value, .v = @floatCast(t.number), .unit = .number }),
            .percentage => return try p.add(.{ .op = .value, .v = @floatCast(t.number), .unit = .percent }),
            .dimension => {
                const u = unitOf(t.text) orelse return null;
                return try p.add(.{ .op = .value, .v = @floatCast(t.number), .unit = u });
            },
            .lparen => return p.function("calc"),
            .function => {
                if (std.ascii.eqlIgnoreCase(t.text, "calc") or std.ascii.eqlIgnoreCase(t.text, "min") or std.ascii.eqlIgnoreCase(t.text, "max") or std.ascii.eqlIgnoreCase(t.text, "clamp")) return p.function(t.text);
                return null;
            },
            .ident => {
                if (t.isIdent("pi")) return try p.add(.{ .op = .value, .v = std.math.pi });
                if (t.isIdent("e")) return try p.add(.{ .op = .value, .v = std.math.e });
                return null;
            },
            else => return null,
        }
    }
};

test "calc" {
    const gpa = std.testing.allocator;
    var l = try tk.tokenize(gpa, "calc(100% - 2 * 1em + 10px) min(50%, 300px) clamp(1rem, 2.5vw, 2rem)");
    defer l.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ctx: Context = .{ .font_size = 20, .viewport_width = 1000 };
    var pos: usize = 1;
    const c1 = (try parseCalc(arena.allocator(), l.tokens, &pos, "calc")).?;
    const lin = c1.linear(&ctx);
    try std.testing.expectEqual(@as(f32, 1), lin.pct);
    try std.testing.expectEqual(@as(f32, -30), lin.px);
    pos += 2; // whitespace, min(
    const c2 = (try parseCalc(arena.allocator(), l.tokens, &pos, "min")).?;
    try std.testing.expect(c2.linear(&ctx).nonlinear);
    try std.testing.expectEqual(@as(f32, 200), c2.eval(&ctx, 400));
    try std.testing.expectEqual(@as(f32, 300), c2.eval(&ctx, 1000));
    pos += 2;
    const c3 = (try parseCalc(arena.allocator(), l.tokens, &pos, "clamp")).?;
    try std.testing.expectEqual(@as(f32, 25), c3.linear(&ctx).px);
}
