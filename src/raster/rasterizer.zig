//! Analytic coverage rasterizer.
//!
//! Each line segment adds its exact signed area to an accumulation buffer:
//! a cell receives the area of the segment's trapezoid inside it, and the
//! cell to its right the remainder of the segment's height, so a running
//! sum along a row yields the signed area covered at every pixel. Nonzero
//! coverage is min(1, |sum|); even-odd folds the sum into [0, 1]. This is
//! exact for paths whose subpaths do not overlap and the standard
//! approximation where they do.
//!
//! Rasterization happens inside a window (an integer pixel rectangle, e.g.
//! a renderer tile or a glyph's bounding box). Geometry outside the window
//! is clipped without changing coverage inside it: parts to the left become
//! vertical edges on the window's left side, parts to the right are dropped.
//! A pixel's coverage therefore does not depend on the window it is
//! rasterized in.

const std = @import("std");
const geom = @import("geom.zig");
const Point = geom.Point;
const IRect = geom.IRect;
const Affine = geom.Affine;
const Path = @import("path.zig").Path;
const flatten = @import("flatten.zig");

pub const FillRule = enum(u8) {
    nonzero,
    even_odd,
};

/// 8-bit coverage over an integer pixel rectangle. Row y of the mask holds
/// pixels (rect.x0 .. rect.x1, rect.y0 + y).
pub const Mask = struct {
    data: []u8,
    stride: usize,
    rect: IRect,

    pub fn row(m: Mask, y: usize) []u8 {
        const w: usize = @intCast(m.rect.width());
        return m.data[y * m.stride ..][0..w];
    }

    /// Coverage at device pixel (x, y), zero outside the mask.
    pub fn at(m: Mask, x: i32, y: i32) u8 {
        if (x < m.rect.x0 or y < m.rect.y0 or x >= m.rect.x1 or y >= m.rect.y1) return 0;
        return m.data[@as(usize, @intCast(y - m.rect.y0)) * m.stride + @as(usize, @intCast(x - m.rect.x0))];
    }
};

/// Reusable rasterizer. The accumulation buffer grows to the largest window
/// used and is kept, so steady-state use allocates nothing.
///
///     try r.begin(window);
///     r.addPath(path, transform, tolerance);   // or addLine
///     r.finish(.nonzero, mask_bytes, stride);  // also resets for reuse
pub const Rasterizer = struct {
    gpa: std.mem.Allocator,
    /// Accumulation cells, `stride` per row. Invariant: all zero between
    /// `finish` (or `discard`) and the next `begin`.
    cells: []f32 = &.{},
    window: IRect = .empty,
    width: u32 = 0,
    height: u32 = 0,
    stride: usize = 0,
    /// Rows that received area, [row_min, row_max).
    row_min: u32 = 0,
    row_max: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Rasterizer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *Rasterizer) void {
        r.gpa.free(r.cells);
        r.* = undefined;
    }

    /// Starts rasterizing into `window`.
    pub fn begin(r: *Rasterizer, window: IRect) error{OutOfMemory}!void {
        const w: u32 = @intCast(@max(window.width(), 0));
        const h: u32 = @intCast(@max(window.height(), 0));
        // Two spare cells per row: a segment ending exactly on the right
        // edge writes at index width and width + 1.
        const stride = @as(usize, w) + 2;
        const need = stride * h;
        if (need > r.cells.len) {
            const cells = try r.gpa.alloc(f32, need);
            @memset(cells, 0);
            r.gpa.free(r.cells);
            r.cells = cells;
        }
        r.window = window;
        r.width = w;
        r.height = h;
        r.stride = stride;
        r.row_min = h;
        r.row_max = 0;
    }

    /// Adds a path, transformed into device space by `m` and closed.
    pub fn addPath(r: *Rasterizer, path: Path, m: Affine, tolerance: f32) void {
        var sink: FillSink = .{ .r = r };
        flatten.flatten(path, m, tolerance, &sink) catch unreachable;
    }

    /// Adds one directed edge in device coordinates. Edges must form
    /// closed loops for coverage to be meaningful.
    pub fn addLine(r: *Rasterizer, a: Point, b: Point) void {
        const ox: f32 = @floatFromInt(r.window.x0);
        const oy: f32 = @floatFromInt(r.window.y0);
        const p0: Point = .{ .x = a.x - ox, .y = a.y - oy };
        const p1: Point = .{ .x = b.x - ox, .y = b.y - oy };
        if (p0.y == p1.y) return;
        const h: f32 = @floatFromInt(r.height);
        if ((p0.y <= 0 and p1.y <= 0) or (p0.y >= h and p1.y >= h)) return;
        if (!(std.math.isFinite(p0.x) and std.math.isFinite(p0.y) and std.math.isFinite(p1.x) and std.math.isFinite(p1.y))) return;
        const w: f32 = @floatFromInt(r.width);

        if (p0.x <= 0 and p1.x <= 0) return r.accumulate(.{ .x = 0, .y = p0.y }, .{ .x = 0, .y = p1.y });
        if (p0.x >= w and p1.x >= w) return;
        if (p0.x >= 0 and p1.x >= 0 and p0.x <= w and p1.x <= w) return r.accumulate(p0, p1);

        // Split where the segment crosses x = 0 and x = w.
        var ts: [4]f32 = .{ 0, 1, 1, 1 };
        var n: usize = 1;
        const dx = p1.x - p0.x;
        if (dx != 0) {
            for ([_]f32{ 0, w }) |edge| {
                const t = (edge - p0.x) / dx;
                if (t > 0 and t < 1) {
                    ts[n] = t;
                    n += 1;
                }
            }
        }
        ts[n] = 1;
        n += 1;
        std.mem.sort(f32, ts[0..n], {}, std.sort.asc(f32));
        for (0..n - 1) |i| {
            const t0 = ts[i];
            const t1 = ts[i + 1];
            if (t1 <= t0) continue;
            const q0 = if (t0 == 0) p0 else p0.lerp(p1, t0);
            const q1 = if (t1 == 1) p1 else p0.lerp(p1, t1);
            const mid = (q0.x + q1.x) / 2;
            if (mid <= 0) {
                r.accumulate(.{ .x = 0, .y = q0.y }, .{ .x = 0, .y = q1.y });
            } else if (mid < w) {
                r.accumulate(
                    .{ .x = std.math.clamp(q0.x, 0, w), .y = q0.y },
                    .{ .x = std.math.clamp(q1.x, 0, w), .y = q1.y },
                );
            }
        }
    }

    /// Adds a window-local edge with 0 <= x <= width.
    fn accumulate(r: *Rasterizer, a: Point, b: Point) void {
        if (a.y == b.y) return;
        const dir: f32 = if (a.y < b.y) 1 else -1;
        var p0 = if (a.y < b.y) a else b;
        var p1 = if (a.y < b.y) b else a;
        const h: f32 = @floatFromInt(r.height);
        const dxdy = (p1.x - p0.x) / (p1.y - p0.y);
        if (p0.y < 0) {
            p0.x -= p0.y * dxdy;
            p0.y = 0;
        }
        if (p1.y > h) {
            p1.x -= (p1.y - h) * dxdy;
            p1.y = h;
        }
        if (p0.y >= p1.y) return;
        const wmax: f32 = @floatFromInt(r.width);

        const row0: u32 = @intFromFloat(@floor(p0.y));
        const row1: u32 = @intFromFloat(@ceil(p1.y));
        r.row_min = @min(r.row_min, row0);
        r.row_max = @max(r.row_max, row1);

        var x = std.math.clamp(p0.x, 0, wmax);
        var y = row0;
        while (y < row1) : (y += 1) {
            const cells = r.cells[@as(usize, y) * r.stride ..][0..r.stride];
            const yf: f32 = @floatFromInt(y);
            const dy = @min(yf + 1, p1.y) - @max(yf, p0.y);
            const xnext = std.math.clamp(x + dxdy * dy, 0, wmax);
            const d = dy * dir;
            const x0 = @min(x, xnext);
            const x1 = @max(x, xnext);
            const x0floor = @floor(x0);
            const x0i: usize = @intFromFloat(x0floor);
            const x1ceil = @ceil(x1);
            const x1i: usize = @intFromFloat(x1ceil);
            if (x1i <= x0i + 1) {
                // The segment stays within one cell in this row.
                const xmf = 0.5 * (x + xnext) - x0floor;
                cells[x0i] += d - d * xmf;
                cells[x0i + 1] += d * xmf;
            } else {
                const s = 1 / (x1 - x0);
                const x0f = x0 - x0floor;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = x1 - x1ceil + 1;
                const am = 0.5 * s * x1f * x1f;
                cells[x0i] += d * a0;
                if (x1i == x0i + 2) {
                    cells[x0i + 1] += d * (1 - a0 - am);
                } else {
                    const a1 = s * (1.5 - x0f);
                    cells[x0i + 1] += d * (a1 - a0);
                    var xi = x0i + 2;
                    while (xi < x1i - 1) : (xi += 1) cells[xi] += d * s;
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    cells[x1i - 1] += d * (1 - a2 - am);
                }
                cells[x1i] += d * am;
            }
            x = xnext;
        }
    }

    /// Writes coverage for every pixel of the window into `out` (row y at
    /// out[y * out_stride ..]) and clears the accumulation buffer.
    pub fn finish(r: *Rasterizer, rule: FillRule, out: []u8, out_stride: usize) void {
        const w: usize = r.width;
        for (0..r.height) |y| {
            const dst = out[y * out_stride ..][0..w];
            if (y < r.row_min or y >= r.row_max) {
                @memset(dst, 0);
                continue;
            }
            const cells = r.cells[y * r.stride ..][0..r.stride];
            switch (rule) {
                inline else => |ct_rule| accumulateRow(ct_rule, cells, dst),
            }
        }
        r.row_min = r.height;
        r.row_max = 0;
    }

    /// Like `finish` but returns the coverage in a Mask view of `out`.
    pub fn finishMask(r: *Rasterizer, rule: FillRule, out: []u8, out_stride: usize) Mask {
        const window = r.window;
        r.finish(rule, out, out_stride);
        return .{ .data = out, .stride = out_stride, .rect = window };
    }

    /// Clears the accumulation buffer without producing coverage.
    pub fn discard(r: *Rasterizer) void {
        if (r.row_min < r.row_max) @memset(r.cells[r.row_min * r.stride .. r.row_max * r.stride], 0);
        r.row_min = r.height;
        r.row_max = 0;
    }

    /// Rows [row_min, row_max) of the window that may have coverage.
    pub fn touchedRows(r: *const Rasterizer) [2]u32 {
        return .{ r.row_min, @max(r.row_min, r.row_max) };
    }
};

fn accumulateRow(comptime rule: FillRule, cells: []f32, dst: []u8) void {
    var acc: f32 = 0;
    for (dst, cells[0..dst.len]) |*o, *c| {
        acc += c.*;
        c.* = 0;
        o.* = coverageByte(rule, acc);
    }
    // Spare cells past the right edge.
    for (cells[dst.len..]) |*c| c.* = 0;
}

pub inline fn coverageByte(comptime rule: FillRule, acc: f32) u8 {
    var v = @abs(acc);
    switch (rule) {
        .nonzero => v = @min(v, 1),
        .even_odd => {
            v = v - 2 * @floor(v * 0.5);
            if (v > 1) v = 2 - v;
        },
    }
    return @intFromFloat(v * 255 + 0.5);
}

const FillSink = struct {
    r: *Rasterizer,
    start: Point = .zero,
    last: Point = .zero,

    pub fn begin(s: *FillSink, p: Point) void {
        s.start = p;
        s.last = p;
    }

    pub fn lineTo(s: *FillSink, p: Point) void {
        s.r.addLine(s.last, p);
        s.last = p;
    }

    pub fn end(s: *FillSink, _: bool) void {
        s.r.addLine(s.last, s.start);
        s.last = s.start;
    }
};

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const PathBuilder = @import("path.zig").PathBuilder;

fn rasterize(gpa: std.mem.Allocator, path: Path, m: Affine, rule: FillRule, window: IRect, out: []u8) !void {
    var r = Rasterizer.init(gpa);
    defer r.deinit();
    try r.begin(window);
    r.addPath(path, m, flatten.default_tolerance);
    r.finish(rule, out, @intCast(window.width()));
}

fn sum(mask: []const u8) f64 {
    var s: f64 = 0;
    for (mask) |v| s += @as(f64, @floatFromInt(v)) / 255;
    return s;
}

test "pixel-aligned rectangle is exactly covered" {
    var b = PathBuilder.init(testing.allocator);
    defer b.deinit();
    try b.rect(.xywh(1, 1, 2, 2));
    var out: [16]u8 = undefined;
    try rasterize(testing.allocator, b.path(), .identity, .nonzero, .xywh(0, 0, 4, 4), &out);
    try testing.expectEqualSlices(u8, &.{
        0, 0,   0,   0,
        0, 255, 255, 0,
        0, 255, 255, 0,
        0, 0,   0,   0,
    }, &out);
}

test "fractional rectangle gives area coverage, independent of orientation" {
    var b = PathBuilder.init(testing.allocator);
    defer b.deinit();
    // Counter-clockwise this time: coverage must not depend on winding sign.
    try b.moveTo(0.25, 0.5);
    try b.lineTo(0.25, 2.5);
    try b.lineTo(2.75, 2.5);
    try b.lineTo(2.75, 0.5);
    try b.close();
    var out: [9]u8 = undefined;
    try rasterize(testing.allocator, b.path(), .identity, .nonzero, .xywh(0, 0, 3, 3), &out);
    // Column coverage 0.75, 1, 0.75; row coverage 0.5, 1, 0.5.
    const expect = [9]f32{ 0.375, 0.5, 0.375, 0.75, 1, 0.75, 0.375, 0.5, 0.375 };
    for (out, expect) |got, e| try testing.expectEqual(@as(u8, @intFromFloat(e * 255 + 0.5)), got);
}

test "diagonal edge splits pixels in half" {
    var b = PathBuilder.init(testing.allocator);
    defer b.deinit();
    // Triangle below the diagonal of a 4x4 square.
    try b.moveTo(0, 0);
    try b.lineTo(4, 4);
    try b.lineTo(0, 4);
    try b.close();
    var out: [16]u8 = undefined;
    try rasterize(testing.allocator, b.path(), .identity, .nonzero, .xywh(0, 0, 4, 4), &out);
    for (0..4) |y| for (0..4) |x| {
        const v = out[y * 4 + x];
        const e: u8 = if (x < y) 255 else if (x == y) 128 else 0;
        try testing.expectEqual(e, v);
    };
}

test "circle area matches analytically" {
    var b = PathBuilder.init(testing.allocator);
    defer b.deinit();
    const r: f32 = 13.3;
    try b.ellipse(.xywh(16.4 - r, 15.7 - r, 2 * r, 2 * r));
    var out: [32 * 32]u8 = undefined;
    try rasterize(testing.allocator, b.path(), .identity, .nonzero, .xywh(0, 0, 32, 32), &out);
    const area = std.math.pi * @as(f64, r) * r;
    try testing.expectApproxEqRel(area, sum(&out), 2e-3);
}

test "coverage does not depend on the window" {
    var b = PathBuilder.init(testing.allocator);
    defer b.deinit();
    try b.moveTo(-5.3, 2.2);
    try b.cubicTo(10, -8, 30, 30, 20.7, 27.1);
    try b.quadTo(3, 40, -2, 12);
    try b.close();
    var full: [24 * 24]u8 = undefined;
    try rasterize(testing.allocator, b.path(), .identity, .nonzero, .xywh(0, 0, 24, 24), &full);
    // Rasterize the same path in four quadrant windows.
    var r = Rasterizer.init(testing.allocator);
    defer r.deinit();
    var part: [12 * 12]u8 = undefined;
    for ([_][2]i32{ .{ 0, 0 }, .{ 12, 0 }, .{ 0, 12 }, .{ 12, 12 } }) |o| {
        try r.begin(.xywh(o[0], o[1], 12, 12));
        r.addPath(b.path(), .identity, flatten.default_tolerance);
        r.finish(.nonzero, &part, 12);
        for (0..12) |y| for (0..12) |x| {
            const g = full[(y + @as(usize, @intCast(o[1]))) * 24 + x + @as(usize, @intCast(o[0]))];
            try testing.expect(@abs(@as(i32, g) - part[y * 12 + x]) <= 1);
        };
    }
}

test "even-odd punches the overlap; nonzero keeps it" {
    var b = PathBuilder.init(testing.allocator);
    defer b.deinit();
    try b.rect(.xywh(0, 0, 4, 4));
    try b.rect(.xywh(1, 1, 2, 2)); // same orientation
    var nz: [16]u8 = undefined;
    var eo: [16]u8 = undefined;
    try rasterize(testing.allocator, b.path(), .identity, .nonzero, .xywh(0, 0, 4, 4), &nz);
    try rasterize(testing.allocator, b.path(), .identity, .even_odd, .xywh(0, 0, 4, 4), &eo);
    try testing.expectEqual(@as(u8, 255), nz[5]);
    try testing.expectEqual(@as(u8, 0), eo[5]);
    try testing.expectEqual(@as(u8, 255), eo[0]);

    // An inner rectangle with opposite orientation is a hole under nonzero.
    b.reset();
    try b.rect(.xywh(0, 0, 4, 4));
    try b.moveTo(1, 1);
    try b.lineTo(1, 3);
    try b.lineTo(3, 3);
    try b.lineTo(3, 1);
    try b.close();
    try rasterize(testing.allocator, b.path(), .identity, .nonzero, .xywh(0, 0, 4, 4), &nz);
    try testing.expectEqual(@as(u8, 0), nz[5]);
}

test "geometry outside the window and degenerate input" {
    var b = PathBuilder.init(testing.allocator);
    defer b.deinit();
    // Covers the whole window, extending far outside on every side.
    try b.rect(.xywh(-1000, -1000, 3000, 3000));
    var out: [8 * 8]u8 = undefined;
    try rasterize(testing.allocator, b.path(), .identity, .nonzero, .xywh(100, 100, 8, 8), &out);
    for (out) |v| try testing.expectEqual(@as(u8, 255), v);

    // NaN and infinite coordinates are ignored rather than corrupting state.
    b.reset();
    try b.moveTo(std.math.nan(f32), 0);
    try b.lineTo(std.math.inf(f32), 5);
    try b.lineTo(2, 2);
    try rasterize(testing.allocator, b.path(), .identity, .nonzero, .xywh(0, 0, 8, 8), &out);
}

test "rasterizer is reusable and its buffer stays clean" {
    var b = PathBuilder.init(testing.allocator);
    defer b.deinit();
    try b.ellipse(.xywh(1.5, 1.5, 9, 9));
    var r = Rasterizer.init(testing.allocator);
    defer r.deinit();
    var first: [12 * 12]u8 = undefined;
    var second: [12 * 12]u8 = undefined;
    try r.begin(.xywh(0, 0, 12, 12));
    r.addPath(b.path(), .identity, 0.1);
    r.discard();
    try r.begin(.xywh(0, 0, 12, 12));
    r.addPath(b.path(), .identity, 0.1);
    r.finish(.nonzero, &first, 12);
    try r.begin(.xywh(0, 0, 12, 12));
    r.addPath(b.path(), .identity, 0.1);
    r.finish(.nonzero, &second, 12);
    try testing.expectEqualSlices(u8, &first, &second);
    for (r.cells) |c| try testing.expectEqual(@as(f32, 0), c);
}
