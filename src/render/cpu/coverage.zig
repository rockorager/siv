//! Analytic coverage for axis-aligned rectangles and rounded rectangles in
//! device space. These formulas are the contract the Vulkan renderer's
//! analytic quads must match (D10): exact box overlap for rectangles, and
//! for rounded corners clamp(0.5 − d, 0, 1) with d the (approximate)
//! signed distance to the corner ellipse at the pixel center, limited by
//! the box coverage.

const std = @import("std");
const raster = @import("raster");
const Rect = raster.Rect;
const IRect = raster.IRect;
const Point = raster.Point;
const Radii = raster.Radii;

inline fn overlap(lo: f32, hi: f32, p: f32) f32 {
    return std.math.clamp(@min(p + 1, hi) - @max(p, lo), 0, 1);
}

/// Writes rectangle coverage for `region` into out (row y at
/// out[(y - region.y0) * stride ..]).
pub fn rect(r: Rect, region: IRect, out: []u8, stride: usize) void {
    var y = region.y0;
    while (y < region.y1) : (y += 1) {
        const cy = overlap(r.y0, r.y1, @floatFromInt(y));
        const row = out[@as(usize, @intCast(y - region.y0)) * stride ..];
        var x = region.x0;
        while (x < region.x1) : (x += 1) {
            const cx = overlap(r.x0, r.x1, @floatFromInt(x));
            row[@intCast(x - region.x0)] = @intFromFloat(cx * cy * 255 + 0.5);
        }
    }
}

/// Rounded rectangle coverage; radii must already fit the rectangle.
pub fn roundedRect(r: Rect, radii: Radii, region: IRect, out: []u8, stride: usize) void {
    var y = region.y0;
    while (y < region.y1) : (y += 1) {
        const yf: f32 = @floatFromInt(y);
        const cy = overlap(r.y0, r.y1, yf);
        const py = yf + 0.5;
        const row = out[@as(usize, @intCast(y - region.y0)) * stride ..];
        var x = region.x0;
        while (x < region.x1) : (x += 1) {
            const xf: f32 = @floatFromInt(x);
            var c = overlap(r.x0, r.x1, xf) * cy;
            const px = xf + 0.5;
            if (c > 0) {
                const corner: ?struct { Point, Point } =
                    if (px < r.x0 + radii.tl.x and py < r.y0 + radii.tl.y)
                        .{ .{ .x = r.x0 + radii.tl.x, .y = r.y0 + radii.tl.y }, radii.tl }
                    else if (px > r.x1 - radii.tr.x and py < r.y0 + radii.tr.y)
                        .{ .{ .x = r.x1 - radii.tr.x, .y = r.y0 + radii.tr.y }, radii.tr }
                    else if (px > r.x1 - radii.br.x and py > r.y1 - radii.br.y)
                        .{ .{ .x = r.x1 - radii.br.x, .y = r.y1 - radii.br.y }, radii.br }
                    else if (px < r.x0 + radii.bl.x and py > r.y1 - radii.bl.y)
                        .{ .{ .x = r.x0 + radii.bl.x, .y = r.y1 - radii.bl.y }, radii.bl }
                    else
                        null;
                if (corner) |cr| {
                    const d = ellipseDistance(.{ .x = px - cr[0].x, .y = py - cr[0].y }, cr[1]);
                    c = @min(c, std.math.clamp(0.5 - d, 0, 1));
                }
            }
            row[@intCast(x - region.x0)] = @intFromFloat(c * 255 + 0.5);
        }
    }
}

/// Signed distance from q (relative to the center) to an axis-aligned
/// ellipse with radii r: exact for circles, first-order otherwise.
pub fn ellipseDistance(q: Point, r: Point) f32 {
    if (r.x <= 0 or r.y <= 0) return -1e9;
    if (r.x == r.y) return q.length() - r.x;
    const k0 = (Point{ .x = q.x / r.x, .y = q.y / r.y }).length();
    const k1 = (Point{ .x = q.x / (r.x * r.x), .y = q.y / (r.y * r.y) }).length();
    if (k1 == 0) return -@min(r.x, r.y);
    return k0 * (k0 - 1) / k1;
}

test "rect coverage is the box overlap" {
    var out: [9]u8 = undefined;
    rect(.{ .x0 = 0.5, .y0 = 0, .x1 = 2.25, .y1 = 3 }, .xywh(0, 0, 3, 3), &out, 3);
    try std.testing.expectEqualSlices(u8, &.{ 128, 255, 64, 128, 255, 64, 128, 255, 64 }, &out);
}

test "rounded corners cut circle area" {
    var out: [40 * 40]u8 = undefined;
    roundedRect(.xywh(0, 0, 40, 40), Radii.uniform(20, 20), .xywh(0, 0, 40, 40), &out, 40);
    var total: f64 = 0;
    for (out) |v| total += @as(f64, @floatFromInt(v)) / 255;
    try std.testing.expectApproxEqRel(std.math.pi * 400.0, total, 2e-3);
}
