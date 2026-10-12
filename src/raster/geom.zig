//! 2D geometry shared by the rasterizer, the display list, and the renderers.
//!
//! Coordinates are f32 in a y-down space: device pixels for the rasterizer,
//! layer-local units in display lists. Pixel (x, y) covers the square
//! [x, x+1) × [y, y+1); its center is (x + 0.5, y + 0.5).

const std = @import("std");

pub const Point = extern struct {
    x: f32,
    y: f32,

    pub const zero: Point = .{ .x = 0, .y = 0 };

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(a: Point, s: f32) Point {
        return .{ .x = a.x * s, .y = a.y * s };
    }

    pub fn dot(a: Point, b: Point) f32 {
        return a.x * b.x + a.y * b.y;
    }

    /// z component of the 3D cross product. Positive when b turns clockwise
    /// from a on screen (y down).
    pub fn cross(a: Point, b: Point) f32 {
        return a.x * b.y - a.y * b.x;
    }

    pub fn length(a: Point) f32 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }

    pub fn lerp(a: Point, b: Point, t: f32) Point {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }

    /// Unit vector in the direction of a, or zero for a zero vector.
    pub fn normalize(a: Point) Point {
        const len = a.length();
        if (len == 0) return zero;
        return a.scale(1 / len);
    }

    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }
};

/// Axis-aligned rectangle with x0 <= x1 and y0 <= y1 when not empty.
pub const Rect = extern struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    /// The identity for `unite`.
    pub const empty: Rect = .{ .x0 = std.math.inf(f32), .y0 = std.math.inf(f32), .x1 = -std.math.inf(f32), .y1 = -std.math.inf(f32) };

    pub fn xywh(x: f32, y: f32, w: f32, h: f32) Rect {
        return .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h };
    }

    pub fn width(r: Rect) f32 {
        return r.x1 - r.x0;
    }

    pub fn height(r: Rect) f32 {
        return r.y1 - r.y0;
    }

    pub fn isEmpty(r: Rect) bool {
        return !(r.x0 < r.x1 and r.y0 < r.y1);
    }

    pub fn unite(a: Rect, b: Rect) Rect {
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        return .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    }

    pub fn includePoint(r: Rect, p: Point) Rect {
        return .{ .x0 = @min(r.x0, p.x), .y0 = @min(r.y0, p.y), .x1 = @max(r.x1, p.x), .y1 = @max(r.y1, p.y) };
    }

    pub fn outset(r: Rect, d: f32) Rect {
        return .{ .x0 = r.x0 - d, .y0 = r.y0 - d, .x1 = r.x1 + d, .y1 = r.y1 + d };
    }

    pub fn eql(a: Rect, b: Rect) bool {
        return a.x0 == b.x0 and a.y0 == b.y0 and a.x1 == b.x1 and a.y1 == b.y1;
    }

    /// Smallest integer rectangle containing r. Empty input gives an empty
    /// result; infinite coordinates saturate.
    pub fn roundOut(r: Rect) IRect {
        if (r.isEmpty()) return IRect.empty;
        return .{ .x0 = satFloor(r.x0), .y0 = satFloor(r.y0), .x1 = satCeil(r.x1), .y1 = satCeil(r.y1) };
    }
};

const sat_limit: f32 = 1 << 30;

fn satFloor(v: f32) i32 {
    return @intFromFloat(std.math.clamp(@floor(v), -sat_limit, sat_limit));
}

fn satCeil(v: f32) i32 {
    return @intFromFloat(std.math.clamp(@ceil(v), -sat_limit, sat_limit));
}

/// Integer pixel rectangle, half-open: [x0, x1) × [y0, y1).
pub const IRect = extern struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub const empty: IRect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

    pub fn xywh(x: i32, y: i32, w: i32, h: i32) IRect {
        return .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h };
    }

    pub fn width(r: IRect) i32 {
        return r.x1 - r.x0;
    }

    pub fn height(r: IRect) i32 {
        return r.y1 - r.y0;
    }

    pub fn isEmpty(r: IRect) bool {
        return !(r.x0 < r.x1 and r.y0 < r.y1);
    }

    pub fn intersect(a: IRect, b: IRect) IRect {
        const r: IRect = .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
        return if (r.isEmpty()) empty else r;
    }

    pub fn unite(a: IRect, b: IRect) IRect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }

    pub fn intersects(a: IRect, b: IRect) bool {
        return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1;
    }

    pub fn contains(a: IRect, b: IRect) bool {
        return b.isEmpty() or (a.x0 <= b.x0 and a.y0 <= b.y0 and a.x1 >= b.x1 and a.y1 >= b.y1);
    }

    pub fn outset(r: IRect, d: i32) IRect {
        return .{ .x0 = r.x0 - d, .y0 = r.y0 - d, .x1 = r.x1 + d, .y1 = r.y1 + d };
    }

    pub fn toRect(r: IRect) Rect {
        return .{ .x0 = @floatFromInt(r.x0), .y0 = @floatFromInt(r.y0), .x1 = @floatFromInt(r.x1), .y1 = @floatFromInt(r.y1) };
    }

    pub fn eql(a: IRect, b: IRect) bool {
        return a.x0 == b.x0 and a.y0 == b.y0 and a.x1 == b.x1 and a.y1 == b.y1;
    }
};

/// 2D affine transform in PDF/cairo order:
///
///     x' = a·x + c·y + e
///     y' = b·x + d·y + f
pub const Affine = extern struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub const identity: Affine = .{};

    pub fn translate(x: f32, y: f32) Affine {
        return .{ .e = x, .f = y };
    }

    pub fn scale(sx: f32, sy: f32) Affine {
        return .{ .a = sx, .d = sy };
    }

    /// Rotation by `radians`, clockwise on screen (y down).
    pub fn rotate(radians: f32) Affine {
        const s = @sin(radians);
        const co = @cos(radians);
        return .{ .a = co, .b = s, .c = -s, .d = co };
    }

    pub fn skew(x_radians: f32, y_radians: f32) Affine {
        return .{ .b = @tan(y_radians), .c = @tan(x_radians) };
    }

    /// The transform that applies `inner` first, then `outer`.
    pub fn then(inner: Affine, outer: Affine) Affine {
        return .{
            .a = outer.a * inner.a + outer.c * inner.b,
            .b = outer.b * inner.a + outer.d * inner.b,
            .c = outer.a * inner.c + outer.c * inner.d,
            .d = outer.b * inner.c + outer.d * inner.d,
            .e = outer.a * inner.e + outer.c * inner.f + outer.e,
            .f = outer.b * inner.e + outer.d * inner.f + outer.f,
        };
    }

    pub fn apply(m: Affine, p: Point) Point {
        return .{ .x = m.a * p.x + m.c * p.y + m.e, .y = m.b * p.x + m.d * p.y + m.f };
    }

    /// Applies only the linear part (for vectors).
    pub fn applyVector(m: Affine, p: Point) Point {
        return .{ .x = m.a * p.x + m.c * p.y, .y = m.b * p.x + m.d * p.y };
    }

    pub fn determinant(m: Affine) f32 {
        return m.a * m.d - m.b * m.c;
    }

    /// The inverse, or null when the transform is singular.
    pub fn invert(m: Affine) ?Affine {
        const det = m.determinant();
        if (det == 0 or !std.math.isFinite(det)) return null;
        const inv = 1 / det;
        return .{
            .a = m.d * inv,
            .b = -m.b * inv,
            .c = -m.c * inv,
            .d = m.a * inv,
            .e = (m.c * m.f - m.d * m.e) * inv,
            .f = (m.b * m.e - m.a * m.f) * inv,
        };
    }

    /// True when the transform maps axis-aligned rectangles to axis-aligned
    /// rectangles (scale and translation, possibly with axis flips).
    pub fn isAxisAligned(m: Affine) bool {
        return m.b == 0 and m.c == 0;
    }

    pub fn isTranslation(m: Affine) bool {
        return m.a == 1 and m.b == 0 and m.c == 0 and m.d == 1;
    }

    /// Largest factor by which the transform stretches any vector (the
    /// larger singular value). Used to convert device tolerances to local
    /// units.
    pub fn maxScale(m: Affine) f32 {
        const p = m.a * m.a + m.b * m.b;
        const q = m.c * m.c + m.d * m.d;
        const r = m.a * m.c + m.b * m.d;
        const mean = (p + q) / 2;
        const diff = (p - q) / 2;
        return @sqrt(mean + @sqrt(diff * diff + r * r));
    }

    /// Bounding box of a transformed rectangle.
    pub fn applyRect(m: Affine, r: Rect) Rect {
        if (r.isEmpty()) return Rect.empty;
        var out = Rect.empty;
        out = out.includePoint(m.apply(.{ .x = r.x0, .y = r.y0 }));
        out = out.includePoint(m.apply(.{ .x = r.x1, .y = r.y0 }));
        out = out.includePoint(m.apply(.{ .x = r.x0, .y = r.y1 }));
        out = out.includePoint(m.apply(.{ .x = r.x1, .y = r.y1 }));
        return out;
    }

    pub fn eql(x: Affine, y: Affine) bool {
        return x.a == y.a and x.b == y.b and x.c == y.c and x.d == y.d and x.e == y.e and x.f == y.f;
    }
};

test "affine composition and inverse" {
    const m = Affine.translate(10, 5).then(Affine.scale(2, 3)).then(Affine.rotate(0.3));
    const p: Point = .{ .x = 3, .y = -7 };
    // `then` applies left to right.
    const expect = Affine.rotate(0.3).apply(Affine.scale(2, 3).apply(Affine.translate(10, 5).apply(p)));
    const got = m.apply(p);
    try std.testing.expectApproxEqAbs(expect.x, got.x, 1e-4);
    try std.testing.expectApproxEqAbs(expect.y, got.y, 1e-4);
    const back = m.invert().?.apply(got);
    try std.testing.expectApproxEqAbs(p.x, back.x, 1e-4);
    try std.testing.expectApproxEqAbs(p.y, back.y, 1e-4);
    try std.testing.expect(Affine.scale(0, 1).invert() == null);
}

test "max scale is the larger singular value" {
    try std.testing.expectApproxEqAbs(3, Affine.scale(2, -3).maxScale(), 1e-5);
    try std.testing.expectApproxEqAbs(5, Affine.scale(5, 1).then(Affine.rotate(1.1)).maxScale(), 1e-4);
}

test "rect round out" {
    const r = Rect.xywh(0.5, -1.25, 2, 1).roundOut();
    try std.testing.expectEqual(IRect{ .x0 = 0, .y0 = -2, .x1 = 3, .y1 = 0 }, r);
    try std.testing.expect(Rect.empty.roundOut().isEmpty());
}
