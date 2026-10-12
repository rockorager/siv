//! Paint evaluation: solid colors, gradients, and image sampling, shaded at
//! pixel centers in device space into premultiplied linear pixels.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const color = @import("color.zig");
const Pixel = color.Pixel;
const Point = raster.Point;
const Affine = raster.Affine;
const Rect = raster.Rect;

const F4 = @Vector(4, f32);

pub const Stop = struct {
    offset: f32,
    /// Premultiplied linear color.
    c: F4,
};

pub const Gradient = struct {
    /// Device space to gradient space.
    inv: Affine,
    geometry: scene.Gradient.Geometry,
    stops: []const Stop,
    extend: scene.Extend,
};

pub const Image = struct {
    /// Device space to image pixel coordinates.
    inv: Affine,
    ref: scene.ImageRef,
    /// Integer texel range sampling is clamped to (inside the image).
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    filter: scene.Filter,
    opacity16: u32,
};

pub const Paint = union(enum) {
    solid: Pixel,
    gradient: Gradient,
    image: Image,

    pub fn isSolid(p: *const Paint) bool {
        return p.* == .solid;
    }
};

pub fn solid(c: scene.Color, opacity: f32) Pixel {
    return color.premultiply(c.r, c.g, c.b, c.a * opacity);
}

/// Premultiplies stops into `out` (which has stops.len entries).
pub fn prepareStops(stops: []const scene.Stop, opacity: f32, out: []Stop) void {
    for (stops, out) |s, *o| {
        const a = std.math.clamp(s.color.a * opacity, 0, 1);
        o.* = .{ .offset = s.offset, .c = .{ s.color.r * a, s.color.g * a, s.color.b * a, a } };
    }
}

/// Shades pixels (x0 + i, y) for i in [0, out.len).
pub fn shadeRow(p: *const Paint, luts: *const color.Luts, x0: i32, y: i32, out: []Pixel) void {
    switch (p.*) {
        .solid => |c| @memset(out, c),
        .gradient => |*g| shadeGradient(g, x0, y, out),
        .image => |*im| shadeImage(im, luts, x0, y, out),
    }
}

const lanes = 8;
const V = @Vector(lanes, f32);
const B = @Vector(lanes, bool);

/// Gradients shade eight pixels at a time: the parameter t, its validity,
/// and the extend mode run in vector registers; the stop lookup is exact
/// per lane (`colorAt` semantics), so results match the scalar formulas.
fn shadeGradient(g: *const Gradient, x0: i32, y: i32, out: []Pixel) void {
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    const iota: V = std.simd.iota(f32, lanes);
    const inv = g.inv;
    var i: usize = 0;
    while (i < out.len) : (i += lanes) {
        const px = iota + @as(V, @splat(@as(f32, @floatFromInt(x0)) + @as(f32, @floatFromInt(i)) + 0.5));
        const qx = px * @as(V, @splat(inv.a)) + @as(V, @splat(inv.c * py + inv.e));
        const qy = px * @as(V, @splat(inv.b)) + @as(V, @splat(inv.d * py + inv.f));
        var t: V = undefined;
        var valid: B = @splat(true);
        switch (g.geometry) {
            .linear => |l| {
                const dx = l.p1.x - l.p0.x;
                const dy = l.p1.y - l.p0.y;
                const dd = dx * dx + dy * dy;
                if (dd == 0) {
                    valid = @splat(false);
                    t = @splat(0);
                } else {
                    t = ((qx - @as(V, @splat(l.p0.x))) * @as(V, @splat(dx)) + (qy - @as(V, @splat(l.p0.y))) * @as(V, @splat(dy))) / @as(V, @splat(dd));
                }
            },
            .radial => |r| radialT(r, qx, qy, &t, &valid),
            .sweep => {
                // atan2 has no vector form in std; sweeps are rare.
                const ax: [lanes]f32 = qx;
                const ay: [lanes]f32 = qy;
                var ta: [lanes]f32 = undefined;
                var va: [lanes]bool = undefined;
                for (0..lanes) |k| {
                    const v = gradientT(g.geometry, .{ .x = ax[k], .y = ay[k] });
                    ta[k] = v orelse 0;
                    va[k] = v != null;
                }
                t = ta;
                valid = va;
            },
        }
        const n = @min(lanes, out.len - i);
        const stops = g.stops;
        const ok: [lanes]bool = valid;
        if (stops.len == 1 or stops[stops.len - 1].offset <= stops[0].offset) {
            const ta: [lanes]f32 = t;
            for (0..n) |k| out[i + k] = if (ok[k]) toPixel(colorAt(stops, g.extend, ta[k])) else .{ 0, 0, 0, 0 };
            continue;
        }
        const te: [lanes]f32 = extendT(stops[0].offset, stops[stops.len - 1].offset, g.extend, t);
        for (0..n) |k| out[i + k] = if (ok[k]) toPixel(colorInRange(stops, te[k])) else .{ 0, 0, 0, 0 };
    }
}

fn radialT(r: anytype, qx: V, qy: V, t: *V, valid: *B) void {
    const cdx = r.c1.x - r.c0.x;
    const cdy = r.c1.y - r.c0.y;
    const dr = r.r1 - r.r0;
    const a = cdx * cdx + cdy * cdy - dr * dr;
    const pdx = qx - @as(V, @splat(r.c0.x));
    const pdy = qy - @as(V, @splat(r.c0.y));
    const b = pdx * @as(V, @splat(cdx)) + pdy * @as(V, @splat(cdy)) + @as(V, @splat(r.r0 * dr));
    const c = pdx * pdx + pdy * pdy - @as(V, @splat(r.r0 * r.r0));
    const zero: V = @splat(0);
    if (@abs(a) < 1e-6 * @max(1, cdx * cdx + cdy * cdy + dr * dr)) {
        const tt = c / (@as(V, @splat(2)) * b);
        t.* = tt;
        valid.* = @as(B, b != zero) & (@as(V, @splat(r.r0)) + tt * @as(V, @splat(dr)) >= zero);
        return;
    }
    const disc = b * b - @as(V, @splat(a)) * c;
    const sq = @sqrt(@max(disc, zero));
    const t1 = (b + sq) / @as(V, @splat(a));
    const t2 = (b - sq) / @as(V, @splat(a));
    const hi = @max(t1, t2);
    const lo = @min(t1, t2);
    const hi_ok = @as(V, @splat(r.r0)) + hi * @as(V, @splat(dr)) >= zero;
    const lo_ok = @as(V, @splat(r.r0)) + lo * @as(V, @splat(dr)) >= zero;
    t.* = @select(f32, hi_ok, hi, lo);
    valid.* = @as(B, disc >= zero) & (hi_ok | lo_ok);
}

/// Applies the extend mode, mapping t into [lo, hi] (hi > lo).
fn extendT(lo: f32, hi: f32, extend: scene.Extend, t: V) V {
    const span = hi - lo;
    const vlo: V = @splat(lo);
    const vspan: V = @splat(span);
    return switch (extend) {
        .pad => @min(@max(t, vlo), @as(V, @splat(hi))),
        .repeat => vlo + (t - vlo) - vspan * @floor((t - vlo) / vspan),
        .reflect => blk: {
            const two: V = @splat(2 * span);
            const u = (t - vlo) - two * @floor((t - vlo) / two);
            break :blk vlo + @select(f32, u > vspan, two - u, u);
        },
    };
}

/// The gradient parameter at q (gradient space), or null where the
/// gradient is undefined (degenerate geometry, outside a conical gradient).
pub fn gradientT(geometry: scene.Gradient.Geometry, q: Point) ?f32 {
    switch (geometry) {
        .linear => |l| {
            const d = l.p1.sub(l.p0);
            const dd = d.dot(d);
            if (dd == 0) return null;
            return q.sub(l.p0).dot(d) / dd;
        },
        .radial => |r| {
            const cd = r.c1.sub(r.c0);
            const dr = r.r1 - r.r0;
            const pd = q.sub(r.c0);
            const a = cd.dot(cd) - dr * dr;
            const b = pd.dot(cd) + r.r0 * dr;
            const c = pd.dot(pd) - r.r0 * r.r0;
            if (@abs(a) < 1e-6 * @max(1, cd.dot(cd) + dr * dr)) {
                // One circle contains the other's center path: linear case.
                if (b == 0) return null;
                const t = c / (2 * b);
                return if (r.r0 + t * dr >= 0) t else null;
            }
            const disc = b * b - a * c;
            if (disc < 0) return null;
            const sq = @sqrt(disc);
            const t1 = (b + sq) / a;
            const t2 = (b - sq) / a;
            const hi = @max(t1, t2);
            const lo = @min(t1, t2);
            if (r.r0 + hi * dr >= 0) return hi;
            if (r.r0 + lo * dr >= 0) return lo;
            return null;
        },
        .sweep => |s| {
            const span = s.end_angle - s.start_angle;
            if (span == 0) return null;
            var angle = std.math.atan2(q.y - s.center.y, q.x - s.center.x);
            if (angle < 0) angle += 2 * std.math.pi;
            return (angle - s.start_angle) / span;
        },
    }
}

/// Color at t. Repeat and reflect use the stop range [first, last] as the
/// period (CSS repeating gradients, COLRv1); pad clamps to it.
pub fn colorAt(stops: []const Stop, extend: scene.Extend, t_in: f32) F4 {
    const n = stops.len;
    if (n == 1) return stops[0].c;
    const lo = stops[0].offset;
    const hi = stops[n - 1].offset;
    var t = t_in;
    const span = hi - lo;
    if (span <= 0) {
        // All stops at one offset: a hard edge.
        return if (t < lo) stops[0].c else stops[n - 1].c;
    }
    switch (extend) {
        .pad => t = std.math.clamp(t, lo, hi),
        .repeat => t = lo + (t - lo) - span * @floor((t - lo) / span),
        .reflect => {
            const u = (t - lo) - 2 * span * @floor((t - lo) / (2 * span));
            t = lo + (if (u > span) 2 * span - u else u);
        },
    }
    return colorInRange(stops, t);
}

/// Color at t already inside [first, last] offset.
fn colorInRange(stops: []const Stop, t: f32) F4 {
    const n = stops.len;
    var i: usize = 1;
    while (i < n - 1 and stops[i].offset < t) : (i += 1) {}
    const a = stops[i - 1];
    const b = stops[i];
    const w = b.offset - a.offset;
    if (w <= 0) return b.c;
    const f = std.math.clamp((t - a.offset) / w, 0, 1);
    return a.c + (b.c - a.c) * @as(F4, @splat(f));
}

pub fn toPixel(c: F4) Pixel {
    const a = std.math.clamp(c[3], 0, 1);
    return .{ color.toU16(@min(c[0], a)), color.toU16(@min(c[1], a)), color.toU16(@min(c[2], a)), color.toU16(a) };
}

fn shadeImage(im: *const Image, luts: *const color.Luts, x0: i32, y: i32, out: []Pixel) void {
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    for (out, 0..) |*o, i| {
        const px = @as(f32, @floatFromInt(x0 + @as(i32, @intCast(i)))) + 0.5;
        const q = im.inv.apply(.{ .x = px, .y = py });
        var p: Pixel = switch (im.filter) {
            .nearest => texel(im, luts, clampI(@floor(q.x), im.x0, im.x1), clampI(@floor(q.y), im.y0, im.y1)),
            .linear => bilinear(im, luts, q),
        };
        if (im.opacity16 != 65535) {
            const v: @Vector(4, u32) = p;
            p = color.narrow(color.div65535v(v * @as(@Vector(4, u32), @splat(im.opacity16))));
        }
        o.* = p;
    }
}

fn clampI(v: f32, lo: i32, hi: i32) i32 {
    if (!(v >= @as(f32, @floatFromInt(lo)))) return lo;
    if (v >= @as(f32, @floatFromInt(hi - 1))) return hi - 1;
    return @intFromFloat(v);
}

fn bilinear(im: *const Image, luts: *const color.Luts, q: Point) Pixel {
    const u = q.x - 0.5;
    const v = q.y - 0.5;
    const fu = @floor(u);
    const fv = @floor(v);
    const ix = clampI(fu, im.x0, im.x1);
    const iy = clampI(fv, im.y0, im.y1);
    const ix1 = clampI(fu + 1, im.x0, im.x1);
    const iy1 = clampI(fv + 1, im.y0, im.y1);
    const wx: u32 = @intFromFloat(std.math.clamp(u - fu, 0, 1) * 256);
    const wy: u32 = @intFromFloat(std.math.clamp(v - fv, 0, 1) * 256);
    const U4 = @Vector(4, u32);
    const t00: U4 = texel(im, luts, ix, iy);
    const t10: U4 = texel(im, luts, ix1, iy);
    const t01: U4 = texel(im, luts, ix, iy1);
    const t11: U4 = texel(im, luts, ix1, iy1);
    const top = t00 * @as(U4, @splat(256 - wx)) + t10 * @as(U4, @splat(wx));
    const bot = t01 * @as(U4, @splat(256 - wx)) + t11 * @as(U4, @splat(wx));
    const r = (top * @as(U4, @splat(256 - wy)) + bot * @as(U4, @splat(wy)) + @as(U4, @splat(32768))) >> @splat(16);
    return color.narrow(r);
}

/// Premultiplied linear texel at integer coordinates (already clamped).
pub fn texel(im: *const Image, luts: *const color.Luts, x: i32, y: i32) Pixel {
    const ref = im.ref;
    const row = ref.pixels + @as(usize, @intCast(y)) * ref.stride;
    switch (ref.format) {
        .rgba8_srgb, .bgra8_srgb => {
            const p = row[@as(usize, @intCast(x)) * 4 ..][0..4];
            const r, const b = if (ref.format == .rgba8_srgb) .{ p[0], p[2] } else .{ p[2], p[0] };
            const a16: u32 = @as(u32, p[3]) * 257;
            return .{
                @intCast(color.div65535(@as(u32, luts.srgb8_to_linear[r]) * a16)),
                @intCast(color.div65535(@as(u32, luts.srgb8_to_linear[p[1]]) * a16)),
                @intCast(color.div65535(@as(u32, luts.srgb8_to_linear[b]) * a16)),
                @intCast(a16),
            };
        },
        .rgba16_linear_premul => {
            const p: *align(1) const [4]u16 = @ptrCast(row + @as(usize, @intCast(x)) * 8);
            return p.*;
        },
    }
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

test "stop lookup with extend modes" {
    const stops = [_]Stop{
        .{ .offset = 0.25, .c = .{ 0, 0, 0, 1 } },
        .{ .offset = 0.75, .c = .{ 1, 1, 1, 1 } },
    };
    try testing.expectApproxEqAbs(@as(f32, 0), colorAt(&stops, .pad, 0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), colorAt(&stops, .pad, 0.5)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), colorAt(&stops, .pad, 2)[0], 1e-6);
    // Period is the stop range: t = 0.85 repeats to 0.35.
    try testing.expectApproxEqAbs(@as(f32, 0.2), colorAt(&stops, .repeat, 0.85)[0], 1e-5);
    // Reflect mirrors: t = 0.85 reflects to 0.65.
    try testing.expectApproxEqAbs(@as(f32, 0.8), colorAt(&stops, .reflect, 0.85)[0], 1e-5);
}

test "gradient parameters" {
    const lin: scene.Gradient.Geometry = .{ .linear = .{ .p0 = .{ .x = 10, .y = 0 }, .p1 = .{ .x = 20, .y = 0 } } };
    try testing.expectApproxEqAbs(@as(f32, 0.5), gradientT(lin, .{ .x = 15, .y = 99 }).?, 1e-6);

    // Concentric radial: t is the distance ratio between radii.
    const rad: scene.Gradient.Geometry = .{ .radial = .{ .c0 = .zero, .r0 = 0, .c1 = .zero, .r1 = 10 } };
    try testing.expectApproxEqAbs(@as(f32, 0.3), gradientT(rad, .{ .x = 0, .y = 3 }).?, 1e-5);

    // Two-point conical where the start circle is outside the end circle:
    // points behind the cone are undefined.
    const cone: scene.Gradient.Geometry = .{ .radial = .{ .c0 = .{ .x = -20, .y = 0 }, .r0 = 1, .c1 = .{ .x = 20, .y = 0 }, .r1 = 2 } };
    try testing.expect(gradientT(cone, .{ .x = -40, .y = 30 }) == null);
    const t = gradientT(cone, .{ .x = 20, .y = 0 }).?;
    try testing.expect(t >= 1);

    // Sweep: a quarter turn clockwise on screen is t = 0.25.
    const sw: scene.Gradient.Geometry = .{ .sweep = .{ .center = .zero, .start_angle = 0, .end_angle = 2 * std.math.pi } };
    try testing.expectApproxEqAbs(@as(f32, 0.25), gradientT(sw, .{ .x = 0, .y = 5 }).?, 1e-5);
}
