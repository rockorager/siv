//! The micro-syntaxes of SVG attributes: numbers and number lists, path
//! data (`d`, with elliptical arcs converted to cubics), point lists, and
//! transform lists.

const std = @import("std");
const raster = @import("raster");
const Affine = raster.Affine;
const PathBuilder = raster.PathBuilder;

/// Reads numbers separated by whitespace and at most one comma, as path
/// data and lists write them ("1.5.5-2" is 1.5, .5, -2).
pub const Lexer = struct {
    s: []const u8,
    i: usize = 0,

    pub fn skipSep(l: *Lexer) void {
        l.skipSpace();
        if (l.i < l.s.len and l.s[l.i] == ',') {
            l.i += 1;
            l.skipSpace();
        }
    }

    pub fn skipSpace(l: *Lexer) void {
        while (l.i < l.s.len and isSpace(l.s[l.i])) l.i += 1;
    }

    pub fn atEnd(l: *Lexer) bool {
        l.skipSpace();
        return l.i >= l.s.len;
    }

    /// Whether a number starts here.
    pub fn atNumber(l: *Lexer) bool {
        l.skipSep();
        if (l.i >= l.s.len) return false;
        const ch = l.s[l.i];
        return std.ascii.isDigit(ch) or ch == '-' or ch == '+' or ch == '.';
    }

    pub fn number(l: *Lexer) ?f32 {
        l.skipSep();
        const start = l.i;
        var i = l.i;
        const s = l.s;
        if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
        const digits_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i < s.len and s[i] == '.') {
            i += 1;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        }
        if (i == digits_start or (i == digits_start + 1 and s[digits_start] == '.')) return null;
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            var j = i + 1;
            if (j < s.len and (s[j] == '-' or s[j] == '+')) j += 1;
            if (j < s.len and std.ascii.isDigit(s[j])) {
                while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
                i = j;
            }
        }
        const v = std.fmt.parseFloat(f32, s[start..i]) catch return null;
        if (!std.math.isFinite(v)) return null;
        l.i = i;
        return v;
    }

    /// An arc flag: a single 0 or 1, which may run into what follows.
    pub fn flag(l: *Lexer) ?bool {
        l.skipSep();
        if (l.i >= l.s.len) return null;
        const ch = l.s[l.i];
        if (ch != '0' and ch != '1') return null;
        l.i += 1;
        return ch == '1';
    }
};

pub fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0c';
}

/// Appends path data to `b`. On an error the path keeps what came before
/// it, as SVG renders a path up to its first error.
pub fn parsePath(b: *PathBuilder, d: []const u8) error{OutOfMemory}!void {
    var l: Lexer = .{ .s = d };
    var cmd: u8 = 0;
    var cur: raster.Point = .zero;
    var start: raster.Point = .zero;
    // The last control point, for S and T reflection.
    var last_ctrl: raster.Point = .zero;
    var last_cmd: u8 = 0;
    while (true) {
        l.skipSpace();
        if (l.i >= l.s.len) return;
        const ch = l.s[l.i];
        if (std.ascii.isAlphabetic(ch)) {
            cmd = ch;
            l.i += 1;
        } else if (cmd == 0 or !l.atNumber()) {
            return;
        } else if (cmd == 'M') {
            cmd = 'L';
        } else if (cmd == 'm') {
            cmd = 'l';
        }
        const rel = std.ascii.isLower(cmd);
        const base: raster.Point = if (rel) cur else .zero;
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const x = l.number() orelse return;
                const y = l.number() orelse return;
                cur = .{ .x = base.x + x, .y = base.y + y };
                start = cur;
                try b.moveTo(cur.x, cur.y);
            },
            'L' => {
                const x = l.number() orelse return;
                const y = l.number() orelse return;
                cur = .{ .x = base.x + x, .y = base.y + y };
                try lineTo(b, start, cur);
            },
            'H' => {
                const x = l.number() orelse return;
                cur.x = base.x + x;
                try lineTo(b, start, cur);
            },
            'V' => {
                const y = l.number() orelse return;
                cur.y = base.y + y;
                try lineTo(b, start, cur);
            },
            'C', 'S' => {
                var c1: raster.Point = undefined;
                if (std.ascii.toUpper(cmd) == 'C') {
                    const x1 = l.number() orelse return;
                    const y1 = l.number() orelse return;
                    c1 = .{ .x = base.x + x1, .y = base.y + y1 };
                } else {
                    const prev = std.ascii.toUpper(last_cmd);
                    c1 = if (prev == 'C' or prev == 'S') .{ .x = 2 * cur.x - last_ctrl.x, .y = 2 * cur.y - last_ctrl.y } else cur;
                }
                const x2 = l.number() orelse return;
                const y2 = l.number() orelse return;
                const x = l.number() orelse return;
                const y = l.number() orelse return;
                const c2: raster.Point = .{ .x = base.x + x2, .y = base.y + y2 };
                const p: raster.Point = .{ .x = base.x + x, .y = base.y + y };
                try ensureStart(b, start);
                try b.cubicTo(c1.x, c1.y, c2.x, c2.y, p.x, p.y);
                last_ctrl = c2;
                cur = p;
            },
            'Q', 'T' => {
                var c: raster.Point = undefined;
                if (std.ascii.toUpper(cmd) == 'Q') {
                    const x1 = l.number() orelse return;
                    const y1 = l.number() orelse return;
                    c = .{ .x = base.x + x1, .y = base.y + y1 };
                } else {
                    const prev = std.ascii.toUpper(last_cmd);
                    c = if (prev == 'Q' or prev == 'T') .{ .x = 2 * cur.x - last_ctrl.x, .y = 2 * cur.y - last_ctrl.y } else cur;
                }
                const x = l.number() orelse return;
                const y = l.number() orelse return;
                const p: raster.Point = .{ .x = base.x + x, .y = base.y + y };
                try ensureStart(b, start);
                try b.quadTo(c.x, c.y, p.x, p.y);
                last_ctrl = c;
                cur = p;
            },
            'A' => {
                const rx = l.number() orelse return;
                const ry = l.number() orelse return;
                const rot = l.number() orelse return;
                const large = l.flag() orelse return;
                const sweep = l.flag() orelse return;
                const x = l.number() orelse return;
                const y = l.number() orelse return;
                const p: raster.Point = .{ .x = base.x + x, .y = base.y + y };
                try ensureStart(b, start);
                try arcTo(b, cur, @abs(rx), @abs(ry), rot, large, sweep, p);
                cur = p;
            },
            'Z' => {
                try b.close();
                cur = start;
            },
            else => return,
        }
        last_cmd = cmd;
    }
}

fn lineTo(b: *PathBuilder, start: raster.Point, p: raster.Point) error{OutOfMemory}!void {
    try ensureStart(b, start);
    try b.lineTo(p.x, p.y);
}

/// After a close, drawing continues from the closed subpath's start.
fn ensureStart(b: *PathBuilder, start: raster.Point) error{OutOfMemory}!void {
    if (!b.open) try b.moveTo(start.x, start.y);
}

/// An elliptical arc as cubics (SVG implementation notes F.6).
pub fn arcTo(b: *PathBuilder, from: raster.Point, rx0: f32, ry0: f32, rot_deg: f32, large: bool, sweep: bool, to: raster.Point) error{OutOfMemory}!void {
    if (from.eql(to)) return;
    if (rx0 == 0 or ry0 == 0) return b.lineTo(to.x, to.y);
    const phi = rot_deg * std.math.pi / 180;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);
    const dx = (from.x - to.x) / 2;
    const dy = (from.y - to.y) / 2;
    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;
    var rx = rx0;
    var ry = ry0;
    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
        const s = @sqrt(lambda);
        rx *= s;
        ry *= s;
    }
    const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var coef = if (den == 0) 0 else @sqrt(@max(0, num / den));
    if (large == sweep) coef = -coef;
    const cxp = coef * rx * y1p / ry;
    const cyp = -coef * ry * x1p / rx;
    const cx = cos_phi * cxp - sin_phi * cyp + (from.x + to.x) / 2;
    const cy = sin_phi * cxp + cos_phi * cyp + (from.y + to.y) / 2;
    const theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep and dtheta > 0) dtheta -= 2 * std.math.pi;
    if (sweep and dtheta < 0) dtheta += 2 * std.math.pi;
    if (!std.math.isFinite(dtheta) or !std.math.isFinite(cx) or !std.math.isFinite(cy)) return b.lineTo(to.x, to.y);
    // At most a quarter turn per cubic.
    const n: usize = @intFromFloat(@max(1, @ceil(@abs(dtheta) / (std.math.pi / 2.0) - 1e-4)));
    const step = dtheta / @as(f32, @floatFromInt(n));
    const k = 4.0 / 3.0 * @tan(step / 4);
    var t = theta1;
    for (0..n) |i| {
        const t2 = t + step;
        const c1 = @cos(t);
        const s1 = @sin(t);
        const c2 = @cos(t2);
        const s2 = @sin(t2);
        const p1x = c1 - k * s1;
        const p1y = s1 + k * c1;
        const p2x = c2 + k * s2;
        const p2y = s2 - k * c2;
        const map = struct {
            fn f(ux: f32, uy: f32, rxx: f32, ryy: f32, cp: f32, sp: f32, ccx: f32, ccy: f32) raster.Point {
                const x = ux * rxx;
                const y = uy * ryy;
                return .{ .x = cp * x - sp * y + ccx, .y = sp * x + cp * y + ccy };
            }
        }.f;
        const q1 = map(p1x, p1y, rx, ry, cos_phi, sin_phi, cx, cy);
        const q2 = map(p2x, p2y, rx, ry, cos_phi, sin_phi, cx, cy);
        const end = if (i == n - 1) to else map(c2, s2, rx, ry, cos_phi, sin_phi, cx, cy);
        try b.cubicTo(q1.x, q1.y, q2.x, q2.y, end.x, end.y);
        t = t2;
    }
}

fn angle(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
    return std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
}

/// `points` of polylines and polygons. An odd coordinate is dropped.
pub fn parsePoints(b: *PathBuilder, s: []const u8, close: bool) error{OutOfMemory}!void {
    var l: Lexer = .{ .s = s };
    var first = true;
    while (true) {
        const x = l.number() orelse break;
        const y = l.number() orelse break;
        if (first) try b.moveTo(x, y) else try b.lineTo(x, y);
        first = false;
    }
    if (close and !first) try b.close();
}

/// A transform list; null when it is invalid (SVG then ignores it... and
/// browsers render without it).
pub fn parseTransform(s: []const u8) ?Affine {
    var l: Lexer = .{ .s = s };
    var m: Affine = .identity;
    while (true) {
        l.skipSep();
        if (l.i >= l.s.len) return m;
        const name_start = l.i;
        while (l.i < l.s.len and std.ascii.isAlphabetic(l.s[l.i])) l.i += 1;
        const name = l.s[name_start..l.i];
        l.skipSpace();
        if (l.i >= l.s.len or l.s[l.i] != '(') return null;
        l.i += 1;
        var args: [6]f32 = undefined;
        var n: usize = 0;
        while (true) {
            l.skipSep();
            if (l.i < l.s.len and l.s[l.i] == ')') {
                l.i += 1;
                break;
            }
            if (n == 6) return null;
            args[n] = l.number() orelse return null;
            n += 1;
        }
        const t: Affine = if (std.mem.eql(u8, name, "matrix")) blk: {
            if (n != 6) return null;
            break :blk .{ .a = args[0], .b = args[1], .c = args[2], .d = args[3], .e = args[4], .f = args[5] };
        } else if (std.mem.eql(u8, name, "translate")) blk: {
            if (n != 1 and n != 2) return null;
            break :blk .translate(args[0], if (n == 2) args[1] else 0);
        } else if (std.mem.eql(u8, name, "scale")) blk: {
            if (n != 1 and n != 2) return null;
            break :blk .scale(args[0], if (n == 2) args[1] else args[0]);
        } else if (std.mem.eql(u8, name, "rotate")) blk: {
            const r = Affine.rotate(args[0] * std.math.pi / 180);
            if (n == 1) break :blk r;
            if (n != 3) return null;
            break :blk Affine.translate(-args[1], -args[2]).then(r).then(.translate(args[1], args[2]));
        } else if (std.mem.eql(u8, name, "skewX")) blk: {
            if (n != 1) return null;
            break :blk .{ .c = @tan(args[0] * std.math.pi / 180) };
        } else if (std.mem.eql(u8, name, "skewY")) blk: {
            if (n != 1) return null;
            break :blk .{ .b = @tan(args[0] * std.math.pi / 180) };
        } else return null;
        // Each transform applies inside the ones before it.
        m = t.then(m);
    }
}

const testing = std.testing;

test "numbers run together as SVG writes them" {
    var l: Lexer = .{ .s = " 1.5.5-2e1,3 ,4e" };
    try testing.expectEqual(@as(f32, 1.5), l.number().?);
    try testing.expectEqual(@as(f32, 0.5), l.number().?);
    try testing.expectEqual(@as(f32, -20), l.number().?);
    try testing.expectEqual(@as(f32, 3), l.number().?);
    try testing.expectEqual(@as(f32, 4), l.number().?);
    try testing.expect(l.number() == null);
}

test "path data with implicit commands, shorthands, and packed arc flags" {
    var b: PathBuilder = .init(testing.allocator);
    defer b.deinit();
    try parsePath(&b, "M10 10 20 10 v10 h-10 z m5 5 l1 1 S 5 5 6 6 q1 1 2 2 t 1 1 a5 5 0 014 4 L");
    const p = b.path();
    try testing.expectEqualSlices(raster.Verb, &.{ .move, .line, .line, .line, .close, .move, .line, .cubic, .quad, .quad, .cubic }, p.verbs);
    // m5 5 after z is relative to the closed subpath's start.
    try testing.expectEqual(raster.Point{ .x = 15, .y = 15 }, p.points[4]);
    // S without a preceding C uses the current point as first control.
    try testing.expectEqual(raster.Point{ .x = 16, .y = 16 }, p.points[6]);
    // The arc ends at its end point exactly.
    try testing.expectEqual(raster.Point{ .x = 13, .y = 13 }, p.points[p.points.len - 1]);
}

test "arcs approximate circles" {
    var b: PathBuilder = .init(testing.allocator);
    defer b.deinit();
    try parsePath(&b, "M 0 10 A 10 10 0 1 1 0 10.001 Z");
    // A full circle needs four cubics; every on-curve point is 10 from the center.
    const p = b.path();
    const center = raster.Point{ .x = 10, .y = 10.0005 };
    var i: usize = 1;
    var curves: usize = 0;
    for (p.verbs[1..]) |v| {
        if (v == .cubic) {
            curves += 1;
            try testing.expectApproxEqAbs(@as(f32, 10), p.points[i + 2].sub(center).length(), 1e-2);
        }
        i += v.pointCount();
    }
    try testing.expectEqual(@as(usize, 4), curves);
}

test "transform lists" {
    const m = parseTransform("translate(10,20) scale(2) rotate(90 1 1)").?;
    const p = m.apply(.{ .x = 2, .y = 1 });
    try testing.expectApproxEqAbs(@as(f32, 12), p.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 24), p.y, 1e-4);
    try testing.expect(parseTransform("matrix(1 2 3)") == null);
    try testing.expect(parseTransform("foo(1)") == null);
    try testing.expectEqual(Affine.identity, parseTransform("  ").?);
}
