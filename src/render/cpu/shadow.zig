//! Analytic box shadows (D9, D10). This file is the contract: the Vulkan
//! renderer's draw.frag mirrors it formula for formula.
//!
//! A shadow (`scene.Shadow`) is evaluated at each device pixel center p,
//! mapped into the layer's coordinates as q = M⁻¹ p, where s = √|det M| is
//! the layer's scale in device pixels:
//!
//! - The shadow shape S is the casting rectangle moved by `offset` and
//!   grown by `spread` (shrunk for inset shadows). Each corner radius
//!   component r > 0 becomes max(0, r ± spread); zero radii stay sharp;
//!   the radii are then fitted to the new rectangle.
//! - The effective sigma is σ' = √(σ² + 1/(12 s²)): the Gaussian of the
//!   shadow combined with the pixel's own box footprint (variance 1/12 px²),
//!   so even a sharp shadow is antialiased.
//! - B(q), the blur of S, is integrated exactly along x and piecewise along
//!   y: each row of S is one span [xl(y), xr(y)] whose Gaussian blur is
//!   ½(erf((qx − xl)/σ'√2) − erf((qx − xr)/σ'√2)). Rows between the corner
//!   bands share one span, so their y integral is exact (an erf
//!   difference); each corner band (heights max(tl.y, tr.y) and
//!   max(bl.y, br.y), the bottom one starting no earlier than the top one
//!   ends) is integrated over u by the midpoint rule (`band`), where
//!   y = edge + height·(1 − cos(u·π/2)) runs from the band's outer edge
//!   (which smooths the spans' square-root onset there). Rows further
//!   than `scene.Shadow.reach` σ' from q are left out. erf is Abramowitz
//!   and Stegun 7.1.27 (error below 5e-4), and exactly ±1 beyond ±4.
//! - The casting rectangle's coverage is c = clamp(0.5 − s·d(q), 0, 1), d
//!   the signed distance to it (`coverage.ellipseDistance` in corners).
//! - The shadow's alpha is B·(1 − c) outset and c·(1 − B) inset, computed
//!   in f32 and applied as 16-bit coverage of the premultiplied color.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const coverage = @import("coverage.zig");

const Point = raster.Point;
const Rect = raster.Rect;
const Radii = raster.Radii;
const Affine = raster.Affine;

/// Samples per corner band: one per half sigma of the rows integrated,
/// within these limits.
pub const min_band_samples = 4;
pub const max_band_samples = 16;

/// A shadow ready to evaluate in device space.
pub const Prepared = struct {
    /// Device to layer coordinates.
    inv: Affine,
    /// Device pixels per layer unit.
    scale: f32,
    cast: Rect,
    cast_radii: Radii,
    /// The blurred shape; empty when spread consumed it.
    shape: Rect,
    radii: Radii,
    /// Effective sigma, in layer units.
    sigma: f32,
    inset: bool,
};

pub fn prepare(s: scene.Shadow, m: Affine) ?Prepared {
    const inv = m.invert() orelse return null;
    const scale = @sqrt(@abs(m.determinant()));
    if (!(scale > 0)) return null;
    const grow = if (s.inset) -s.spread else s.spread;
    const r = s.shape.rect;
    const moved: Rect = .{ .x0 = r.x0 + s.offset.x, .y0 = r.y0 + s.offset.y, .x1 = r.x1 + s.offset.x, .y1 = r.y1 + s.offset.y };
    var shape = moved.outset(grow);
    var radii: Radii = .{};
    if (shape.x0 < shape.x1 and shape.y0 < shape.y1) {
        inline for (.{ "tl", "tr", "br", "bl" }) |f| {
            const c = @field(s.shape.radii, f);
            @field(radii, f) = .{ .x = if (c.x > 0) @max(c.x + grow, 0) else 0, .y = if (c.y > 0) @max(c.y + grow, 0) else 0 };
        }
        radii = radii.fit(shape);
    } else shape = Rect.empty;
    return .{
        .inv = inv,
        .scale = scale,
        .cast = r,
        .cast_radii = s.shape.radii,
        .shape = shape,
        .radii = radii,
        .sigma = @sqrt(s.sigma * s.sigma + 1.0 / (12.0 * scale * scale)),
        .inset = s.inset,
    };
}

/// The shadow's alpha at device point (x, y), usually a pixel center.
pub fn alpha(p: *const Prepared, x: f32, y: f32) f32 {
    const q = p.inv.apply(.{ .x = x, .y = y });
    const c = std.math.clamp(0.5 - p.scale * distance(p.cast, p.cast_radii, q), 0, 1);
    // Nothing to blur where the result is zero anyway.
    if (if (p.inset) c == 0 else c == 1) return 0;
    const b = if (p.shape.isEmpty()) 0 else blurred(p.shape, p.radii, p.sigma, q);
    return if (p.inset) c * (1 - b) else b * (1 - c);
}

/// Evaluates a whole row of pixel centers at once (`alpha` for each), for
/// axis-aligned transforms: the rows of the shape sampled along y, and
/// their weights, are the same for every pixel of the row.
pub const Row = struct {
    p: *const Prepared,
    qy: f32,
    k: f32,
    /// Weight of the straight span (an erf difference in y).
    mid: f32,
    spans: [2 * max_band_samples][2]f32 = undefined,
    weights: [2 * max_band_samples]f32 = undefined,
    n: usize = 0,
    /// Where every band sample's erf pair saturates: x inside all spans
    /// by 4/k (the band adds 2·Σw) or outside all of them (it adds 0).
    inner: [2]f32 = .{ 0, 0 },
    outer: [2]f32 = .{ 0, 0 },
    total: f32 = 0,

    /// Null when the transform is not axis-aligned.
    pub fn init(p: *const Prepared, y: f32) ?Row {
        if (p.inv.b != 0 or p.inv.c != 0) return null;
        const qy = p.inv.d * y + p.inv.f;
        const sigma = p.sigma;
        var row: Row = .{ .p = p, .qy = qy, .k = 1 / (sigma * std.math.sqrt2), .mid = 0 };
        if (p.shape.isEmpty()) return row;
        const r = p.shape;
        const radii = p.radii;
        const lo = @max(r.y0, qy - scene.Shadow.reach * sigma);
        const hi = @min(r.y1, qy + scene.Shadow.reach * sigma);
        if (!(lo < hi)) return row;
        const c1 = @min(r.y0 + @max(radii.tl.y, radii.tr.y), r.y1);
        const c2 = @max(r.y1 - @max(radii.bl.y, radii.br.y), c1);
        const mlo = @max(lo, c1);
        const mhi = @min(hi, c2);
        if (mlo < mhi) row.mid = 0.25 * (erf((qy - mlo) * row.k) - erf((qy - mhi) * row.k));
        row.band(r.y0, c1 - r.y0, lo, @min(hi, c1));
        row.band(r.y1, c2 - r.y1, @max(lo, c2), hi);
        const pad = 4 / row.k;
        row.inner = .{ -std.math.inf(f32), std.math.inf(f32) };
        row.outer = .{ std.math.inf(f32), -std.math.inf(f32) };
        for (row.spans[0..row.n], row.weights[0..row.n]) |sp, w| {
            row.inner = .{ @max(row.inner[0], sp[0] + pad), @min(row.inner[1], sp[1] - pad) };
            row.outer = .{ @min(row.outer[0], sp[0] - pad), @max(row.outer[1], sp[1] + pad) };
            row.total += 2 * w;
        }
        return row;
    }

    fn band(row: *Row, edge: f32, height: f32, a: f32, b: f32) void {
        const p = row.p;
        if (!(a < b) or height == 0) return;
        const half_pi: f32 = std.math.pi / 2.0;
        const ua = std.math.acos(std.math.clamp(1 - (a - edge) / height, -1, 1)) / half_pi;
        const ub = std.math.acos(std.math.clamp(1 - (b - edge) / height, -1, 1)) / half_pi;
        const n: u32 = @intFromFloat(std.math.clamp(@ceil(2 * (b - a) / p.sigma), min_band_samples, max_band_samples));
        const du = (ub - ua) / @as(f32, @floatFromInt(n));
        const norm = 1 / (p.sigma * @sqrt(2 * std.math.pi));
        for (0..n) |i| {
            const u = ua + (@as(f32, @floatFromInt(i)) + 0.5) * du;
            const y = edge + height * (1 - @cos(u * half_pi));
            const sp = span(p.shape, p.radii, y);
            if (!(sp[1] > sp[0])) continue;
            const dy = @abs(height * @sin(u * half_pi) * half_pi * du);
            const t = row.qy - y;
            row.spans[row.n] = sp;
            row.weights[row.n] = @exp(-t * t * (row.k * row.k)) * norm * dy * 0.5;
            row.n += 1;
        }
    }

    /// The straight span's x term at x, the same for every row; callers
    /// may compute it once per column and pass it to `alphaWith`.
    pub fn column(p: *const Prepared, x: f32) f32 {
        const k = 1 / (p.sigma * std.math.sqrt2);
        const qx = p.inv.a * x + p.inv.e;
        return erf((qx - p.shape.x0) * k) - erf((qx - p.shape.x1) * k);
    }

    pub fn alpha(row: *const Row, x: f32) f32 {
        return row.alphaWith(x, if (row.mid != 0) column(row.p, x) else 0);
    }

    pub fn alphaWith(row: *const Row, x: f32, col: f32) f32 {
        const p = row.p;
        const q: Point = .{ .x = p.inv.a * x + p.inv.e, .y = row.qy };
        const c = std.math.clamp(0.5 - p.scale * distance(p.cast, p.cast_radii, q), 0, 1);
        if (if (p.inset) c == 0 else c == 1) return 0;
        const k = row.k;
        var b: f32 = row.mid * col;
        if (row.n == 0 or q.x <= row.outer[0] or q.x >= row.outer[1]) {
            // Every pair cancels.
        } else if (q.x >= row.inner[0] and q.x <= row.inner[1]) {
            b += row.total;
        } else for (row.spans[0..row.n], row.weights[0..row.n]) |sp, w| {
            b += w * (erf((q.x - sp[0]) * k) - erf((q.x - sp[1]) * k));
        }
        return if (p.inset) c * (1 - b) else b * (1 - c);
    }
};

/// erf by Abramowitz and Stegun 7.1.27 (no exponential; error below
/// 5e-4, invisible in a shadow), saturated beyond ±4.
pub fn erf(x: f32) f32 {
    const a = @abs(x);
    if (a >= 4) return if (x < 0) -1 else 1;
    const d = 1 + a * (0.278393 + a * (0.230389 + a * (0.000972 + a * 0.078108)));
    const d2 = d * d;
    const y = 1 - 1 / (d2 * d2);
    return if (x < 0) -y else y;
}

/// The row of the rounded rectangle at height y, as [xl, xr].
fn span(r: Rect, radii: Radii, y: f32) [2]f32 {
    var xl = r.x0;
    var xr = r.x1;
    if (radii.tl.y > 0 and y < r.y0 + radii.tl.y) xl = @max(xl, r.x0 + radii.tl.x * inset(r.y0 + radii.tl.y - y, radii.tl.y));
    if (radii.bl.y > 0 and y > r.y1 - radii.bl.y) xl = @max(xl, r.x0 + radii.bl.x * inset(y - (r.y1 - radii.bl.y), radii.bl.y));
    if (radii.tr.y > 0 and y < r.y0 + radii.tr.y) xr = @min(xr, r.x1 - radii.tr.x * inset(r.y0 + radii.tr.y - y, radii.tr.y));
    if (radii.br.y > 0 and y > r.y1 - radii.br.y) xr = @min(xr, r.x1 - radii.br.x * inset(y - (r.y1 - radii.br.y), radii.br.y));
    return .{ xl, xr };
}

/// How far (as a fraction of the corner's x radius) the corner ellipse is
/// inset at height `dy` into a corner of y radius `ry`.
fn inset(dy: f32, ry: f32) f32 {
    const d = dy / ry;
    return 1 - @sqrt(@max(0, 1 - d * d));
}

/// The rounded rectangle's Gaussian blur at q (see the file comment).
pub fn blurred(r: Rect, radii: Radii, sigma: f32, q: Point) f32 {
    const k = 1 / (sigma * std.math.sqrt2);
    const lo = @max(r.y0, q.y - scene.Shadow.reach * sigma);
    const hi = @min(r.y1, q.y + scene.Shadow.reach * sigma);
    if (!(lo < hi)) return 0;
    const c1 = @min(r.y0 + @max(radii.tl.y, radii.tr.y), r.y1);
    const c2 = @max(r.y1 - @max(radii.bl.y, radii.br.y), c1);
    var sum: f32 = 0;
    // Straight rows: one span, an exact double erf difference.
    const mlo = @max(lo, c1);
    const mhi = @min(hi, c2);
    if (mlo < mhi) sum += 0.25 * (erf((q.x - r.x0) * k) - erf((q.x - r.x1) * k)) * (erf((q.y - mlo) * k) - erf((q.y - mhi) * k));
    sum += band(r, radii, sigma, k, q, r.y0, c1 - r.y0, lo, @min(hi, c1));
    sum += band(r, radii, sigma, k, q, r.y1, c2 - r.y1, @max(lo, c2), hi);
    return sum;
}

/// The integral over rows [a, b] of a corner band that starts at its
/// outer edge `edge` and spans `height` (negative for the bottom band).
/// Rows are y(u) = edge + height·(1 − cos(u·π/2)) for u in [0, 1],
/// integrated over the u of [a, b] by the midpoint rule with
/// clamp(⌈2·(b − a)/σ⌉, 4, 16) samples: the spans' square-root onset at the
/// outer edge becomes smooth in u, and the Gaussian is resolved.
fn band(r: Rect, radii: Radii, sigma: f32, k: f32, q: Point, edge: f32, height: f32, a: f32, b: f32) f32 {
    if (!(a < b) or height == 0) return 0;
    const half_pi: f32 = std.math.pi / 2.0;
    const ua = std.math.acos(std.math.clamp(1 - (a - edge) / height, -1, 1)) / half_pi;
    const ub = std.math.acos(std.math.clamp(1 - (b - edge) / height, -1, 1)) / half_pi;
    const n: u32 = @intFromFloat(std.math.clamp(@ceil(2 * (b - a) / sigma), min_band_samples, max_band_samples));
    const du = (ub - ua) / @as(f32, @floatFromInt(n));
    const norm = 1 / (sigma * @sqrt(2 * std.math.pi));
    var sum: f32 = 0;
    for (0..n) |i| {
        const u = ua + (@as(f32, @floatFromInt(i)) + 0.5) * du;
        const y = edge + height * (1 - @cos(u * half_pi));
        const sp = span(r, radii, y);
        if (!(sp[1] > sp[0])) continue;
        const dy = @abs(height * @sin(u * half_pi) * half_pi * du);
        const t = q.y - y;
        sum += @exp(-t * t * (k * k)) * norm * dy * 0.5 * (erf((q.x - sp[0]) * k) - erf((q.x - sp[1]) * k));
    }
    return sum;
}

/// Signed distance from q to the rounded rectangle (negative inside).
pub fn distance(r: Rect, radii: Radii, q: Point) f32 {
    const Corner = struct { c: Point, r: Point };
    const corner: ?Corner = if (radii.tl.x > 0 and radii.tl.y > 0 and q.x < r.x0 + radii.tl.x and q.y < r.y0 + radii.tl.y)
        .{ .c = .{ .x = r.x0 + radii.tl.x, .y = r.y0 + radii.tl.y }, .r = radii.tl }
    else if (radii.tr.x > 0 and radii.tr.y > 0 and q.x > r.x1 - radii.tr.x and q.y < r.y0 + radii.tr.y)
        .{ .c = .{ .x = r.x1 - radii.tr.x, .y = r.y0 + radii.tr.y }, .r = radii.tr }
    else if (radii.br.x > 0 and radii.br.y > 0 and q.x > r.x1 - radii.br.x and q.y > r.y1 - radii.br.y)
        .{ .c = .{ .x = r.x1 - radii.br.x, .y = r.y1 - radii.br.y }, .r = radii.br }
    else if (radii.bl.x > 0 and radii.bl.y > 0 and q.x < r.x0 + radii.bl.x and q.y > r.y1 - radii.bl.y)
        .{ .c = .{ .x = r.x0 + radii.bl.x, .y = r.y1 - radii.bl.y }, .r = radii.bl }
    else
        null;
    if (corner) |cr| return coverage.ellipseDistance(.{ .x = q.x - cr.c.x, .y = q.y - cr.c.y }, cr.r);
    const dx = @max(r.x0 - q.x, q.x - r.x1);
    const dy = @max(r.y0 - q.y, q.y - r.y1);
    if (dx > 0 and dy > 0) return @sqrt(dx * dx + dy * dy);
    return @max(dx, dy);
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

test "erf matches known values" {
    try testing.expectApproxEqAbs(@as(f32, 0), erf(0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5204999), erf(0.5), 5e-4);
    try testing.expectApproxEqAbs(@as(f32, -0.9953223), erf(-2), 5e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.9999999), erf(3.9), 5e-4);
}

test "a blurred shape keeps its area" {
    // A Gaussian blur preserves mass: the blur summed over the plane is
    // the shape's area, rounded corners included (π r² per four corners).
    const cases = [_]struct { r: Rect, radii: Radii, sigma: f32 }{
        .{ .r = .xywh(0, 0, 40, 30), .radii = .{}, .sigma = 3 },
        .{ .r = .xywh(0, 0, 40, 30), .radii = .uniform(10, 10), .sigma = 4 },
        .{ .r = .xywh(0, 0, 40, 30), .radii = .uniform(15, 6), .sigma = 0.5 },
    };
    for (cases) |cs| {
        var total: f64 = 0;
        var y: f32 = -30;
        while (y < 60) : (y += 0.25) {
            var x: f32 = -30;
            while (x < 70) : (x += 0.25) total += blurred(cs.r, cs.radii, cs.sigma, .{ .x = x + 0.125, .y = y + 0.125 });
        }
        total *= 0.25 * 0.25;
        const corners = cs.radii.tl.x * cs.radii.tl.y * (4 - std.math.pi);
        try testing.expectApproxEqRel(40.0 * 30.0 - corners, total, 2.5e-3);
    }
}

test "edges of a large blurred rectangle are half covered, corners a quarter" {
    const r: Rect = .xywh(0, 0, 200, 200);
    try testing.expectApproxEqAbs(@as(f32, 1), blurred(r, .{}, 5, .{ .x = 100, .y = 100 }), 5e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), blurred(r, .{}, 5, .{ .x = 0, .y = 100 }), 5e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), blurred(r, .{}, 5, .{ .x = 0, .y = 0 }), 5e-4);
}

test "row evaluation agrees with per-pixel evaluation" {
    const s: scene.Shadow = .{ .shape = .{ .rect = .xywh(10, 10, 60, 40), .radii = .{ .tl = .{ .x = 20, .y = 8 }, .br = .{ .x = 6, .y = 6 } } }, .offset = .{ .x = 2, .y = 5 }, .sigma = 3, .spread = 2, .color = .black };
    for ([_]bool{ false, true }) |in| {
        var sh = s;
        sh.inset = in;
        const p = prepare(sh, Affine.scale(1.5, 1.5).then(.translate(3, 4))).?;
        var y: f32 = 0.5;
        while (y < 120) : (y += 1) {
            const row = Row.init(&p, y).?;
            var x: f32 = 0.5;
            while (x < 130) : (x += 1) try testing.expectApproxEqAbs(alpha(&p, x, y), row.alpha(x), 2e-5);
        }
    }
}

test "outset shadows stay out from under their shape, inset ones inside" {
    const s: scene.Shadow = .{ .shape = .{ .rect = .xywh(10, 10, 40, 40), .radii = .uniform(8, 8) }, .sigma = 4, .color = .black };
    const out = prepare(s, .identity).?;
    try testing.expectEqual(@as(f32, 0), alpha(&out, 30.5, 30.5));
    try testing.expect(alpha(&out, 8.5, 30.5) > 0.2);
    var in_s = s;
    in_s.inset = true;
    in_s.spread = 4;
    const in_p = prepare(in_s, .identity).?;
    try testing.expectEqual(@as(f32, 0), alpha(&in_p, 5.5, 30.5));
    try testing.expect(alpha(&in_p, 11.5, 30.5) > 0.5);
    try testing.expect(alpha(&in_p, 30.5, 30.5) < 0.01);
}
