//! Gradients in PDF (D9). Linear and two-point conical gradients become
//! axial and radial shadings; sweep gradients, which PDF lacks, become a
//! Coons patch mesh fanned around the center (each patch spans an angle,
//! so its color depends only on the angle, as a sweep's does).
//!
//! Colors follow the renderers' contract (render/cpu/paint.zig): stops
//! interpolate premultiplied in linear light, and repeat and reflect use
//! the stop range as the period. PDF interpolates in the shading's color
//! space, so the color function is sampled: each stop interval is cut
//! into segments whose ends are exact, and only between them does PDF
//! interpolate sRGB-encoded values. Repeat and reflect are unrolled over
//! the periods the painted area needs. Alpha below 1 goes into a soft
//! mask with the same geometry in DeviceGray.
//!
//! The caller has set the clip; `paint` fills it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scene = @import("scene");
const raster = @import("raster");
const content = @import("content.zig");

const Rect = raster.Rect;
const Point = raster.Point;
const num = content.num;

/// Segments per stop interval.
const segments = 6;
/// Most periods a repeating gradient is unrolled over.
const max_periods = 256;
/// Patches around a sweep.
const sweep_patches = 96;

const F4 = [4]f32;

/// Premultiplied linear color at t, as render/cpu/paint.zig `colorAt`.
fn colorAt(stops: []const scene.Stop, extend: scene.Extend, t_in: f32) F4 {
    const n = stops.len;
    if (n == 1) return premul(stops[0].color);
    const lo = stops[0].offset;
    const hi = stops[n - 1].offset;
    const span = hi - lo;
    var t = t_in;
    if (span <= 0) return premul(if (t < lo) stops[0].color else stops[n - 1].color);
    switch (extend) {
        .pad => t = std.math.clamp(t, lo, hi),
        .repeat => t = lo + (t - lo) - span * @floor((t - lo) / span),
        .reflect => {
            const u = (t - lo) - 2 * span * @floor((t - lo) / (2 * span));
            t = lo + (if (u > span) 2 * span - u else u);
        },
    }
    var i: usize = 1;
    while (i < n - 1 and stops[i].offset < t) : (i += 1) {}
    const a = premul(stops[i - 1].color);
    const b = premul(stops[i].color);
    const w = stops[i].offset - stops[i - 1].offset;
    if (w <= 0) return b;
    const f = std.math.clamp((t - stops[i - 1].offset) / w, 0, 1);
    var out: F4 = undefined;
    for (&out, a, b) |*o, x, y| o.* = x + (y - x) * f;
    return out;
}

fn premul(c: scene.Color) F4 {
    const a = std.math.clamp(c.a, 0, 1);
    return .{ c.r * a, c.g * a, c.b * a, a };
}

/// sRGB-encoded straight color of a premultiplied linear color.
fn encoded(c: F4) [3]f32 {
    if (c[3] <= 0) return .{ 0, 0, 0 };
    var out: [3]f32 = undefined;
    for (&out, c[0..3]) |*o, v| o.* = scene.linearToSrgb(std.math.clamp(v / c[3], 0, 1));
    return out;
}

/// The gradient parameter at q, as render/cpu/paint.zig `gradientT`.
fn gradientT(geometry: scene.Gradient.Geometry, q: Point) ?f32 {
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
                if (b == 0) return null;
                const t = c / (2 * b);
                return if (r.r0 + t * dr >= 0) t else null;
            }
            const disc = b * b - a * c;
            if (disc < 0) return null;
            const sq = @sqrt(disc);
            const hi = @max((b + sq) / a, (b - sq) / a);
            const lo = @min((b + sq) / a, (b - sq) / a);
            if (r.r0 + hi * dr >= 0) return hi;
            if (r.r0 + lo * dr >= 0) return lo;
            return null;
        },
        .sweep => return null,
    }
}

/// The range of t over a gradient-space rectangle, sampled.
fn tRange(geometry: scene.Gradient.Geometry, r: Rect) ?[2]f32 {
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    const n = 24;
    for (0..n + 1) |iy| for (0..n + 1) |ix| {
        const q: Point = .{
            .x = r.x0 + (r.x1 - r.x0) * @as(f32, @floatFromInt(ix)) / n,
            .y = r.y0 + (r.y1 - r.y0) * @as(f32, @floatFromInt(iy)) / n,
        };
        const t = gradientT(geometry, q) orelse continue;
        lo = @min(lo, t);
        hi = @max(hi, t);
    };
    if (!(lo <= hi)) return null;
    return .{ lo, hi };
}

/// The domain the shading's function covers, and its breakpoints.
const Domain = struct {
    t0: f32,
    t1: f32,
    /// Increasing, starting at t0 and ending at t1.
    points: std.ArrayList(f32) = .empty,

    fn deinit(d: *Domain, gpa: Allocator) void {
        d.points.deinit(gpa);
    }
};

fn domain(gpa: Allocator, g: scene.Gradient, range: ?[2]f32) Allocator.Error!Domain {
    const stops = g.stops;
    const lo = stops[0].offset;
    const hi = stops[stops.len - 1].offset;
    const span = hi - lo;
    var d: Domain = .{ .t0 = lo, .t1 = hi };
    if (g.extend != .pad and span > 0) {
        if (range) |r| {
            d.t0 = @min(r[0], lo);
            d.t1 = @max(r[1], hi);
            // Too many periods: keep the middle ones (the rest is finer
            // than the output can show anyway).
            const periods = (d.t1 - d.t0) / span;
            if (periods > max_periods) {
                const mid = (d.t0 + d.t1) / 2;
                d.t0 = mid - span * max_periods / 2;
                d.t1 = mid + span * max_periods / 2;
            }
        }
    }
    if (!(d.t1 > d.t0)) d.t1 = d.t0 + 1e-3;
    errdefer d.deinit(gpa);
    try d.points.append(gpa, d.t0);
    if (span <= 0) {
        try d.points.append(gpa, d.t1);
        return d;
    }
    // Stop offsets in every period the domain touches, each interval cut
    // into segments.
    const first_period = @floor((d.t0 - lo) / span);
    var k = first_period;
    while (lo + k * span < d.t1) : (k += 1) {
        for (stops[0 .. stops.len - 1], stops[1..], 0..) |a, b, si| {
            _ = si;
            for (0..segments) |j| {
                const f = @as(f32, @floatFromInt(j + 1)) / segments;
                // In reflected periods the stops run backwards, but the
                // breakpoints are the same set of positions.
                const t = lo + k * span + (a.offset - lo) + (b.offset - a.offset) * f;
                if (t > d.points.items[d.points.items.len - 1] + 1e-6 and t < d.t1) try d.points.append(gpa, t);
            }
        }
    }
    try d.points.append(gpa, d.t1);
    return d;
}

/// A stitching function of linear segments between the breakpoints:
/// colors (3 components) or alphas (1).
fn function(gpa: Allocator, out: *std.ArrayList(u8), g: scene.Gradient, d: *const Domain, comptime alpha: bool) Allocator.Error!void {
    const pts = d.points.items;
    try out.print(gpa, "<< /FunctionType 3 /Domain [{f} {f}] /Functions [", .{ num(d.t0), num(d.t1) });
    for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
        // The value just inside each end, so hard stops land on the
        // correct side of the breakpoint.
        const ca = colorAt(g.stops, g.extend, a + (b - a) * 1e-4);
        const cb = colorAt(g.stops, g.extend, b - (b - a) * 1e-4);
        if (alpha) {
            try out.print(gpa, " << /FunctionType 2 /Domain [0 1] /C0 [{f}] /C1 [{f}] /N 1 >>", .{ num(ca[3]), num(cb[3]) });
        } else {
            const ea = encoded(ca);
            const eb = encoded(cb);
            try out.print(gpa, " << /FunctionType 2 /Domain [0 1] /C0 [{f} {f} {f}] /C1 [{f} {f} {f}] /N 1 >>", .{ num(ea[0]), num(ea[1]), num(ea[2]), num(eb[0]), num(eb[1]), num(eb[2]) });
        }
    }
    try out.appendSlice(gpa, " ] /Bounds [");
    for (pts[1 .. pts.len - 1]) |b| try out.print(gpa, " {f}", .{num(b)});
    try out.appendSlice(gpa, " ] /Encode [");
    for (pts[0 .. pts.len - 1]) |_| try out.appendSlice(gpa, " 0 1");
    try out.appendSlice(gpa, " ] >>");
}

fn hasAlpha(g: scene.Gradient) bool {
    for (g.stops) |s| if (s.color.a < 1) return true;
    return false;
}

/// Fills the current clip with `g`. `bounds` is the painted area in the
/// current coordinates (before the gradient's transform).
pub fn paint(c: *content.Content, g: scene.Gradient, bounds: Rect) content.Error!void {
    const inv = g.transform.invert() orelse return;
    const gb = content.transformRect(bounds, inv);
    const gpa = c.w.gpa;
    const color_shading = try shadingObject(c, g, gb, false) orelse return;
    try c.print("q\n", .{});
    if (hasAlpha(g)) {
        // The alpha as a luminosity soft mask in the current coordinates.
        const alpha_shading = (try shadingObject(c, g, gb, true)).?;
        var mask: content.Content = .init(c.w);
        defer mask.deinit();
        try mask.matrix(g.transform);
        try mask.useShading(alpha_shading);
        const group = try mask.finishForm(bounds, "/Group << /S /Transparency /CS /DeviceGray >>");
        var gs: [96]u8 = undefined;
        try c.useState(std.fmt.bufPrint(&gs, "/SMask << /Type /Mask /S /Luminosity /G {d} 0 R >>", .{group}) catch unreachable);
    }
    try c.matrix(g.transform);
    try c.useShading(color_shading);
    try c.print("Q\n", .{});
    _ = gpa;
}

/// A shading object for the color (or the alpha) of `g` over the
/// gradient-space rectangle `gb`; null when nothing is painted.
fn shadingObject(c: *content.Content, g: scene.Gradient, gb: Rect, comptime alpha: bool) content.Error!?u32 {
    const gpa = c.w.gpa;
    const cs = if (alpha) "/DeviceGray" else "/DeviceRGB";
    switch (g.geometry) {
        .sweep => |s| return try sweepMesh(c, g, s, gb, alpha),
        else => {},
    }
    var d = try domain(gpa, g, tRange(g.geometry, gb));
    defer d.deinit(gpa);
    var dict: std.ArrayList(u8) = .empty;
    defer dict.deinit(gpa);
    switch (g.geometry) {
        .linear => |l| {
            if (l.p0.x == l.p1.x and l.p0.y == l.p1.y) return null;
            const a = lerpPoint(l.p0, l.p1, d.t0);
            const b = lerpPoint(l.p0, l.p1, d.t1);
            try dict.print(gpa, "<< /ShadingType 2 /ColorSpace {s} /Coords [{f} {f} {f} {f}]", .{ cs, num(a.x), num(a.y), num(b.x), num(b.y) });
        },
        .radial => |r| {
            const dr = r.r1 - r.r0;
            // Radii below zero are outside the gradient.
            if (dr != 0) {
                const t_zero = -r.r0 / dr;
                if (dr > 0) d.t0 = @max(d.t0, t_zero) else d.t1 = @min(d.t1, t_zero);
                if (!(d.t1 > d.t0)) return null;
                d.points.items[0] = d.t0;
                d.points.items[d.points.items.len - 1] = d.t1;
                // Drop breakpoints the clamping passed.
                var keep: usize = 1;
                for (d.points.items[1 .. d.points.items.len - 1]) |p| if (p > d.t0 and p < d.t1) {
                    d.points.items[keep] = p;
                    keep += 1;
                };
                d.points.items[keep] = d.t1;
                d.points.shrinkRetainingCapacity(keep + 1);
            } else if (r.r0 < 0) return null;
            const c0 = lerpPoint(r.c0, r.c1, d.t0);
            const c1 = lerpPoint(r.c0, r.c1, d.t1);
            try dict.print(gpa, "<< /ShadingType 3 /ColorSpace {s} /Coords [{f} {f} {f} {f} {f} {f}]", .{ cs, num(c0.x), num(c0.y), num(@max(r.r0 + dr * d.t0, 0)), num(c1.x), num(c1.y), num(@max(r.r0 + dr * d.t1, 0)) });
        },
        .sweep => unreachable,
    }
    try dict.print(gpa, " /Domain [{f} {f}] /Extend [true true] /Function ", .{ num(d.t0), num(d.t1) });
    try function(gpa, &dict, g, &d, alpha);
    try dict.appendSlice(gpa, " >>");
    return try c.w.add(dict.items);
}

fn lerpPoint(a: Point, b: Point, t: f32) Point {
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
}

/// A sweep as a Coons patch mesh (shading type 6) around its center,
/// reaching past every corner of `gb`.
fn sweepMesh(c: *content.Content, g: scene.Gradient, s: anytype, gb: Rect, comptime alpha: bool) content.Error!?u32 {
    const gpa = c.w.gpa;
    const span = s.end_angle - s.start_angle;
    if (span == 0) return null;
    var radius: f32 = 1;
    for ([_]Point{ .{ .x = gb.x0, .y = gb.y0 }, .{ .x = gb.x1, .y = gb.y0 }, .{ .x = gb.x0, .y = gb.y1 }, .{ .x = gb.x1, .y = gb.y1 } }) |p| {
        radius = @max(radius, @sqrt((p.x - s.center.x) * (p.x - s.center.x) + (p.y - s.center.y) * (p.y - s.center.y)));
    }
    radius *= 1.01;
    const ox = s.center.x - radius;
    const oy = s.center.y - radius;
    const size = 2 * radius;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    const comps: usize = if (alpha) 1 else 3;
    const tau = 2 * std.math.pi;
    for (0..sweep_patches) |k| {
        const a0 = tau * @as(f32, @floatFromInt(k)) / sweep_patches;
        const a1 = tau * @as(f32, @floatFromInt(k + 1)) / sweep_patches;
        // Angles in [0, 2π), as the renderers measure them; the colors at
        // the patch edges come from just inside the patch.
        const t0 = (a0 + 1e-5 - s.start_angle) / span;
        const t1 = (a1 - 1e-5 - s.start_angle) / span;
        const col0 = colorAt(g.stops, g.extend, t0);
        const col1 = colorAt(g.stops, g.extend, t1);
        const center = s.center;
        const p0: Point = .{ .x = center.x + radius * @cos(a0), .y = center.y + radius * @sin(a0) };
        const p1: Point = .{ .x = center.x + radius * @cos(a1), .y = center.y + radius * @sin(a1) };
        const kk = 4.0 / 3.0 * @tan((a1 - a0) / 4) * radius;
        const q0: Point = .{ .x = p0.x - kk * @sin(a0), .y = p0.y + kk * @cos(a0) };
        const q1: Point = .{ .x = p1.x + kk * @sin(a1), .y = p1.y - kk * @cos(a1) };
        // The boundary: center to p0, the arc to p1, back to the center,
        // and a degenerate edge at the center.
        const pts = [12]Point{
            center,                           lerpPoint(center, p0, 1.0 / 3.0), lerpPoint(center, p0, 2.0 / 3.0), p0,
            q0,                               q1,                               p1,                               lerpPoint(center, p1, 2.0 / 3.0),
            lerpPoint(center, p1, 1.0 / 3.0), center,                           center,                           center,
        };
        try data.append(gpa, 0); // flag: a new patch
        for (pts) |p| {
            try appendU32(gpa, &data, coord(p.x, ox, size));
            try appendU32(gpa, &data, coord(p.y, oy, size));
        }
        const corners = [4]F4{ col0, col0, col1, col1 };
        for (corners) |col| {
            if (alpha) {
                try appendU16(gpa, &data, comp(col[3]));
            } else {
                const e = encoded(col);
                for (e) |v| try appendU16(gpa, &data, comp(v));
            }
        }
    }
    var dict: std.ArrayList(u8) = .empty;
    defer dict.deinit(gpa);
    try dict.print(gpa, "/ShadingType 6 /ColorSpace {s} /BitsPerCoordinate 32 /BitsPerComponent 16 /BitsPerFlag 8 /Decode [{f} {f} {f} {f}", .{ if (alpha) "/DeviceGray" else "/DeviceRGB", num(ox), num(ox + size), num(oy), num(oy + size) });
    for (0..comps) |_| try dict.appendSlice(gpa, " 0 1");
    try dict.appendSlice(gpa, "]");
    return try c.w.addStream(dict.items, data.items);
}

fn coord(v: f32, origin: f32, size: f32) u32 {
    const f: f64 = std.math.clamp((v - origin) / size, 0, 1);
    return @intFromFloat(@round(f * std.math.maxInt(u32)));
}

fn comp(v: f32) u16 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 65535));
}

fn appendU32(gpa: Allocator, out: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try out.appendSlice(gpa, &b);
}

fn appendU16(gpa: Allocator, out: *std.ArrayList(u8), v: u16) Allocator.Error!void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try out.appendSlice(gpa, &b);
}

test "colors follow the renderers' stop rules" {
    const red: scene.Color = .{ .r = 1, .g = 0, .b = 0 };
    const clear: scene.Color = .{ .r = 0, .g = 0, .b = 1, .a = 0 };
    const stops = [_]scene.Stop{ .{ .offset = 0, .color = red }, .{ .offset = 1, .color = clear } };
    // Premultiplied: halfway is half-transparent red, not purple.
    const mid = colorAt(&stops, .pad, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid[0], 1e-6);
    try std.testing.expectEqual(@as(f32, 0), mid[2]);
    try std.testing.expectEqual(@as(f32, 0.5), mid[3]);
    const rgb = encoded(mid);
    try std.testing.expectApproxEqAbs(@as(f32, 1), rgb[0], 1e-6);
    try std.testing.expectEqual(@as(f32, 0), rgb[1]);
    try std.testing.expectEqual(@as(f32, 0), rgb[2]);
    // Repeat and reflect use the stop range as the period.
    try std.testing.expectApproxEqAbs(colorAt(&stops, .repeat, 0.25)[3], colorAt(&stops, .repeat, 1.25)[3], 1e-6);
    try std.testing.expectApproxEqAbs(colorAt(&stops, .reflect, 0.25)[3], colorAt(&stops, .reflect, 1.75)[3], 1e-6);
}

test "repeating domains unroll the periods the area needs" {
    const gpa = std.testing.allocator;
    const stops = [_]scene.Stop{ .{ .offset = 0, .color = .black }, .{ .offset = 0.5, .color = .white } };
    const g: scene.Gradient = .{ .geometry = .{ .linear = .{ .p0 = .zero, .p1 = .{ .x = 10, .y = 0 } } }, .stops = &stops, .extend = .repeat };
    var d = try domain(gpa, g, tRange(g.geometry, .{ .x0 = -10, .y0 = 0, .x1 = 30, .y1 = 5 }));
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(f32, -1), d.t0);
    try std.testing.expectEqual(@as(f32, 3), d.t1);
    // Eight periods of one interval each, cut into segments.
    try std.testing.expectEqual(@as(usize, 8 * segments + 1), d.points.items.len);
    for (d.points.items[0 .. d.points.items.len - 1], d.points.items[1..]) |a, b| try std.testing.expect(b > a);
}
