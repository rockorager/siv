//! Stroking: converts a stroked path into a path to fill with the nonzero
//! rule. Curves are flattened first (with a tolerance in path units), then
//! each polyline becomes one closed outline (open subpaths) or an outer and
//! an inner outline of opposite orientation (closed subpaths). Inner joins
//! pass through the vertex, as in Skia, so overlapping offset segments keep
//! a positive winding everywhere.

const std = @import("std");
const geom = @import("geom.zig");
const Point = geom.Point;
const Rect = geom.Rect;
const Affine = geom.Affine;
const path_mod = @import("path.zig");
const Path = path_mod.Path;
const PathBuilder = path_mod.PathBuilder;
const flatten = @import("flatten.zig");

pub const Join = enum(u8) { miter, round, bevel };
pub const Cap = enum(u8) { butt, round, square };

pub const StrokeStyle = struct {
    width: f32 = 1,
    join: Join = .miter,
    cap: Cap = .butt,
    /// Ratio of miter length to stroke width beyond which a miter join
    /// becomes a bevel (SVG stroke-miterlimit).
    miter_limit: f32 = 4,
    /// Alternating on and off lengths. An odd count repeats once (SVG).
    /// Empty, all-zero, or any negative length means a solid stroke.
    dashes: []const f32 = &.{},
    dash_offset: f32 = 0,

    /// How far the outline can extend beyond the path's bounds.
    pub fn outset(s: StrokeStyle) f32 {
        const hw = s.width / 2;
        const join_factor: f32 = if (s.join == .miter) @max(s.miter_limit, 1) else 1;
        const cap_factor: f32 = if (s.cap == .square) std.math.sqrt2 else 1;
        return hw * @max(join_factor, cap_factor);
    }

    pub fn eql(a: StrokeStyle, b: StrokeStyle) bool {
        return a.width == b.width and a.join == b.join and a.cap == b.cap and
            a.miter_limit == b.miter_limit and a.dash_offset == b.dash_offset and
            std.mem.eql(f32, a.dashes, b.dashes);
    }
};

/// Reusable stroker; its scratch buffers keep their capacity.
pub const Stroker = struct {
    gpa: std.mem.Allocator,
    pts: std.ArrayList(Point) = .empty,
    piece: std.ArrayList(Point) = .empty,
    first_piece: std.ArrayList(Point) = .empty,

    // Per-call state.
    out: *PathBuilder = undefined,
    style: StrokeStyle = .{},
    hw: f32 = 0,
    tolerance: f32 = 0,
    has_segment: bool = false,
    need_move: bool = false,

    pub fn init(gpa: std.mem.Allocator) Stroker {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Stroker) void {
        s.pts.deinit(s.gpa);
        s.piece.deinit(s.gpa);
        s.first_piece.deinit(s.gpa);
        s.* = undefined;
    }

    /// Appends the outline of `path` stroked with `style` to `out`.
    /// `tolerance` is in path units: divide the device tolerance by the
    /// transform's maxScale when stroking before transforming.
    pub fn stroke(s: *Stroker, path: Path, style: StrokeStyle, tolerance: f32, out: *PathBuilder) error{OutOfMemory}!void {
        if (!(style.width > 0) or !std.math.isFinite(style.width)) return;
        s.out = out;
        s.style = style;
        s.hw = style.width / 2;
        s.tolerance = @max(tolerance, 1e-4);
        try flatten.flatten(path, .identity, s.tolerance, s);
    }

    pub fn begin(s: *Stroker, p: Point) error{OutOfMemory}!void {
        s.pts.clearRetainingCapacity();
        try s.pts.append(s.gpa, p);
        s.has_segment = false;
    }

    pub fn lineTo(s: *Stroker, p: Point) error{OutOfMemory}!void {
        s.has_segment = true;
        // Drop repeated points; they have no direction.
        const last = s.pts.items[s.pts.items.len - 1];
        if (p.sub(last).length() <= 1e-6 * @max(1, s.hw)) return;
        try s.pts.append(s.gpa, p);
    }

    pub fn end(s: *Stroker, closed: bool) error{OutOfMemory}!void {
        var pts = s.pts.items;
        if (closed and pts.len > 2 and pts[pts.len - 1].sub(pts[0]).length() <= 1e-6 * @max(1, s.hw)) {
            pts = pts[0 .. pts.len - 1];
        }
        if (pts.len == 1) {
            if (s.has_segment) try s.dot(pts[0]);
            return;
        }
        if (dashPattern(s.style)) |pattern| {
            try s.dash(pts, closed, pattern);
        } else if (closed) {
            try s.closedPolyline(pts);
        } else {
            try s.openPolyline(pts);
        }
    }

    /// Zero-length subpath: round and square caps still draw (SVG).
    fn dot(s: *Stroker, p: Point) error{OutOfMemory}!void {
        switch (s.style.cap) {
            .butt => {},
            .round => try s.out.ellipse(.{ .x0 = p.x - s.hw, .y0 = p.y - s.hw, .x1 = p.x + s.hw, .y1 = p.y + s.hw }),
            .square => try s.out.rect(.{ .x0 = p.x - s.hw, .y0 = p.y - s.hw, .x1 = p.x + s.hw, .y1 = p.y + s.hw }),
        }
    }

    fn openPolyline(s: *Stroker, pts: []const Point) error{OutOfMemory}!void {
        std.debug.assert(pts.len >= 2);
        const n = pts.len;
        // Left side forward, end cap, left side of the reversed polyline,
        // start cap.
        const d0 = dir(pts[0], pts[1]);
        try s.out.moveTo(pts[0].x + perp(d0).x * s.hw, pts[0].y + perp(d0).y * s.hw);
        for (1..n - 1) |i| try s.join(pts[i], dir(pts[i - 1], pts[i]), dir(pts[i], pts[i + 1]));
        const dl = dir(pts[n - 2], pts[n - 1]);
        try s.lineToOffset(pts[n - 1], dl);
        try s.cap(pts[n - 1], dl);
        try s.lineToOffset(pts[n - 1], dir(pts[n - 1], pts[n - 2]));
        var i = n - 2;
        while (i > 0) : (i -= 1) try s.join(pts[i], dir(pts[i + 1], pts[i]), dir(pts[i], pts[i - 1]));
        const db = dir(pts[1], pts[0]);
        try s.lineToOffset(pts[0], db);
        try s.cap(pts[0], db);
        try s.out.close();
    }

    fn closedPolyline(s: *Stroker, pts: []const Point) error{OutOfMemory}!void {
        const n = pts.len;
        for (0..2) |side| {
            s.need_move = true;
            for (0..n) |k| {
                // Side 0 walks forward, side 1 backward.
                const i = if (side == 0) k else (n - k) % n;
                const prev = if (side == 0) (i + n - 1) % n else (i + 1) % n;
                const next = if (side == 0) (i + 1) % n else (i + n - 1) % n;
                try s.join(pts[i], dir(pts[prev], pts[i]), dir(pts[i], pts[next]));
            }
            try s.out.close();
        }
    }

    /// Emits the left-side offset points around vertex `p` between
    /// incoming direction `u` and outgoing direction `v`.
    fn join(s: *Stroker, p: Point, u: Point, v: Point) error{OutOfMemory}!void {
        const c = u.cross(v);
        const d = u.dot(v);
        const nu = perp(u).scale(s.hw);
        const nv = perp(v).scale(s.hw);
        // Nearly straight: one point.
        if (@abs(c) < 1e-6 and d > 0) return s.lineToPt(p.add(nu));
        if (c > 0) {
            // Turning toward this side: inner join through the vertex.
            try s.lineToPt(p.add(nu));
            try s.lineToPt(p);
            return s.lineToPt(p.add(nv));
        }
        try s.lineToPt(p.add(nu));
        switch (s.style.join) {
            .bevel => {},
            .miter => {
                const h = perp(u).add(perp(v));
                const hl2 = h.dot(h);
                // 1 / cos(theta / 2) = 2 / |h|.
                if (hl2 > 1e-12 and 4 <= s.style.miter_limit * s.style.miter_limit * hl2) {
                    try s.lineToPt(p.add(h.scale(2 * s.hw / hl2)));
                }
            },
            .round => {
                const sweep = if (c == 0) -std.math.pi else std.math.atan2(c, d);
                try s.arc(p, nu, sweep);
            },
        }
        try s.lineToPt(p.add(nv));
    }

    fn cap(s: *Stroker, p: Point, d: Point) error{OutOfMemory}!void {
        const n = perp(d).scale(s.hw);
        switch (s.style.cap) {
            .butt => {},
            .square => {
                const e = d.scale(s.hw);
                try s.lineToPt(p.add(n).add(e));
                try s.lineToPt(p.sub(n).add(e));
            },
            .round => try s.arc(p, n, -std.math.pi),
        }
    }

    /// Points strictly inside the arc from `center + start` rotated by
    /// `sweep` radians.
    fn arc(s: *Stroker, center: Point, start: Point, sweep: f32) error{OutOfMemory}!void {
        const ratio = @min(s.tolerance / s.hw, 1);
        const max_step = 2 * std.math.acos(1 - ratio);
        const steps: u32 = @intFromFloat(@min(@ceil(@abs(sweep) / @max(max_step, 1e-3)), 1024));
        if (steps < 2) return;
        const step = sweep / @as(f32, @floatFromInt(steps));
        for (1..steps) |k| {
            const a = step * @as(f32, @floatFromInt(k));
            const co = @cos(a);
            const si = @sin(a);
            try s.lineToPt(center.add(.{ .x = start.x * co - start.y * si, .y = start.x * si + start.y * co }));
        }
    }

    fn lineToOffset(s: *Stroker, p: Point, d: Point) error{OutOfMemory}!void {
        try s.lineToPt(p.add(perp(d).scale(s.hw)));
    }

    fn lineToPt(s: *Stroker, p: Point) error{OutOfMemory}!void {
        if (s.need_move) {
            s.need_move = false;
            return s.out.moveTo(p.x, p.y);
        }
        try s.out.lineTo(p.x, p.y);
    }

    fn dash(s: *Stroker, pts: []const Point, closed: bool, pattern: Pattern) error{OutOfMemory}!void {
        const n = pts.len;
        const seg_count = if (closed) n else n - 1;
        var idx: usize = 0;
        var remaining: f32 = undefined;
        var on: bool = undefined;
        pattern.start(s.style.dash_offset, &idx, &remaining, &on);
        const starts_on = on;
        var first_done = false;

        s.piece.clearRetainingCapacity();
        s.first_piece.clearRetainingCapacity();
        if (on) try s.piece.append(s.gpa, pts[0]);

        for (0..seg_count) |i| {
            const a = pts[i];
            const b = pts[(i + 1) % n];
            const len = b.sub(a).length();
            var t: f32 = 0; // distance along the segment
            while (len - t > remaining) {
                t += remaining;
                const q = a.lerp(b, t / len);
                if (on) {
                    try s.piece.append(s.gpa, q);
                    try s.flushPiece(closed and starts_on and !first_done);
                    first_done = true;
                } else {
                    s.piece.clearRetainingCapacity();
                    try s.piece.append(s.gpa, q);
                }
                on = !on;
                idx = (idx + 1) % pattern.lengths.len;
                remaining = pattern.lengths[idx];
            }
            remaining -= len - t;
            if (on) try s.piece.append(s.gpa, b);
            if (!on) first_done = true;
        }
        if (on) {
            if (closed and starts_on and s.first_piece.items.len > 0) {
                // The dash runs through the start point: join both ends.
                try s.piece.appendSlice(s.gpa, s.first_piece.items[1..]);
                s.first_piece.clearRetainingCapacity();
            }
            try s.flushPiece(false);
        }
        if (s.first_piece.items.len > 0) {
            try s.strokeOpen(s.first_piece.items);
        }
    }

    fn flushPiece(s: *Stroker, keep_as_first: bool) error{OutOfMemory}!void {
        if (keep_as_first) {
            s.first_piece.clearRetainingCapacity();
            try s.first_piece.appendSlice(s.gpa, s.piece.items);
        } else {
            try s.strokeOpen(s.piece.items);
        }
        s.piece.clearRetainingCapacity();
    }

    fn strokeOpen(s: *Stroker, raw: []Point) error{OutOfMemory}!void {
        // Remove repeated points introduced by dash boundaries on vertices.
        var n: usize = 0;
        for (raw) |p| {
            if (n > 0 and p.sub(raw[n - 1]).length() <= 1e-6 * @max(1, s.hw)) continue;
            raw[n] = p;
            n += 1;
        }
        if (n == 1) return s.dot(raw[0]);
        if (n >= 2) try s.openPolyline(raw[0..n]);
    }
};

const Pattern = struct {
    lengths: []const f32,
    total: f32,

    fn start(p: Pattern, offset: f32, idx: *usize, remaining: *f32, on: *bool) void {
        var o = @mod(offset, p.total);
        if (!(o >= 0)) o = 0;
        var i: usize = 0;
        var is_on = true;
        while (o >= p.lengths[i]) {
            o -= p.lengths[i];
            i = (i + 1) % p.lengths.len;
            is_on = !is_on;
        }
        idx.* = i;
        remaining.* = p.lengths[i] - o;
        on.* = is_on;
    }
};

fn dashPattern(style: StrokeStyle) ?Pattern {
    const d = style.dashes;
    if (d.len == 0) return null;
    var total: f32 = 0;
    for (d) |v| {
        if (!(v >= 0) or !std.math.isFinite(v)) return null;
        total += v;
    }
    if (d.len % 2 == 1) total *= 2;
    // Patterns far below the flattening tolerance are not visible as
    // dashes and would produce unbounded output.
    if (!(total > 1e-3 * style.width) or total < 1e-4) return null;
    // An odd list repeats: [a, b, c] is [a, b, c, a, b, c]. On and off
    // alternate independently of the index, so wrapping through the list
    // twice flips the parity on the second pass, as required.
    return .{ .lengths = d, .total = total };
}

fn dir(a: Point, b: Point) Point {
    return b.sub(a).normalize();
}

/// Left-hand normal in a y-down space (rotates (1, 0) to (0, 1)).
fn perp(d: Point) Point {
    return .{ .x = -d.y, .y = d.x };
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const Rasterizer = @import("rasterizer.zig").Rasterizer;

fn coverageSum(gpa: std.mem.Allocator, p: Path, window: geom.IRect) !f64 {
    var r = Rasterizer.init(gpa);
    defer r.deinit();
    try r.begin(window);
    r.addPath(p, .identity, 0.05);
    const w: usize = @intCast(window.width());
    const h: usize = @intCast(window.height());
    const out = try gpa.alloc(u8, w * h);
    defer gpa.free(out);
    r.finish(.nonzero, out, w);
    var total: f64 = 0;
    for (out) |v| total += @as(f64, @floatFromInt(v)) / 255;
    return total;
}

test "straight stroke covers width times length" {
    var src = PathBuilder.init(testing.allocator);
    defer src.deinit();
    var out = PathBuilder.init(testing.allocator);
    defer out.deinit();
    var s = Stroker.init(testing.allocator);
    defer s.deinit();

    try src.moveTo(4, 10);
    try src.lineTo(24, 10);
    try s.stroke(src.path(), .{ .width = 3 }, 0.05, &out);
    try testing.expectApproxEqAbs(60, try coverageSum(testing.allocator, out.path(), .xywh(0, 0, 32, 32)), 0.1);

    out.reset();
    try s.stroke(src.path(), .{ .width = 3, .cap = .square }, 0.05, &out);
    try testing.expectApproxEqAbs(69, try coverageSum(testing.allocator, out.path(), .xywh(0, 0, 32, 32)), 0.1);

    out.reset();
    try s.stroke(src.path(), .{ .width = 3, .cap = .round }, 0.005, &out);
    const round_area = 60 + std.math.pi * 1.5 * 1.5;
    try testing.expectApproxEqAbs(round_area, try coverageSum(testing.allocator, out.path(), .xywh(0, 0, 32, 32)), 0.1);
}

test "closed rectangle stroke is a ring with mitered corners" {
    var src = PathBuilder.init(testing.allocator);
    defer src.deinit();
    var out = PathBuilder.init(testing.allocator);
    defer out.deinit();
    var s = Stroker.init(testing.allocator);
    defer s.deinit();
    for ([_]bool{ false, true }) |ccw| {
        src.reset();
        out.reset();
        if (ccw) {
            try src.moveTo(8, 8);
            try src.lineTo(8, 24);
            try src.lineTo(24, 24);
            try src.lineTo(24, 8);
            try src.close();
        } else {
            try src.rect(.xywh(8, 8, 16, 16));
        }
        try s.stroke(src.path(), .{ .width = 4 }, 0.05, &out);
        // Outer 20x20 minus inner 12x12, independent of orientation.
        try testing.expectApproxEqAbs(400 - 144, try coverageSum(testing.allocator, out.path(), .xywh(0, 0, 32, 32)), 0.1);
    }
    // Bevel joins cut each corner by a 2x2 right triangle.
    src.reset();
    out.reset();
    try src.rect(.xywh(8, 8, 16, 16));
    try s.stroke(src.path(), .{ .width = 4, .join = .bevel }, 0.05, &out);
    try testing.expectApproxEqAbs(400 - 144 - 4 * 2, try coverageSum(testing.allocator, out.path(), .xywh(0, 0, 32, 32)), 0.1);
}

test "sharp turn: inner join keeps positive winding" {
    var src = PathBuilder.init(testing.allocator);
    defer src.deinit();
    var out = PathBuilder.init(testing.allocator);
    defer out.deinit();
    var s = Stroker.init(testing.allocator);
    defer s.deinit();
    // A hairpin: there must be no hole at the inner side.
    try src.moveTo(4, 10);
    try src.lineTo(28, 12);
    try src.lineTo(4, 14);
    try s.stroke(src.path(), .{ .width = 6, .join = .round }, 0.05, &out);
    var r = Rasterizer.init(testing.allocator);
    defer r.deinit();
    var mask: [32 * 32]u8 = undefined;
    try r.begin(.xywh(0, 0, 32, 32));
    r.addPath(out.path(), .identity, 0.05);
    r.finish(.nonzero, &mask, 32);
    for (6..20) |x| try testing.expectEqual(@as(u8, 255), mask[12 * 32 + x]);
}

test "dashes split a line into on segments" {
    var src = PathBuilder.init(testing.allocator);
    defer src.deinit();
    var out = PathBuilder.init(testing.allocator);
    defer out.deinit();
    var s = Stroker.init(testing.allocator);
    defer s.deinit();
    try src.moveTo(0, 10);
    try src.lineTo(30, 10);
    try s.stroke(src.path(), .{ .width = 2, .dashes = &.{ 4, 2 } }, 0.05, &out);
    // 30 = 5 periods of 6: 5 dashes of 4x2.
    try testing.expectApproxEqAbs(40, try coverageSum(testing.allocator, out.path(), .xywh(0, 0, 32, 32)), 0.1);
    // An offset of 5 starts 1 unit into the gap: 1 off, then 4 on ...
    out.reset();
    try s.stroke(src.path(), .{ .width = 2, .dashes = &.{ 4, 2 }, .dash_offset = 5 }, 0.05, &out);
    // On ranges: [1,5) [7,11) ... [25,29): 5 dashes again.
    try testing.expectApproxEqAbs(40, try coverageSum(testing.allocator, out.path(), .xywh(0, 0, 32, 32)), 0.1);
    // Odd lists repeat: [3] is 3 on, 3 off.
    out.reset();
    try s.stroke(src.path(), .{ .width = 2, .dashes = &.{3} }, 0.05, &out);
    try testing.expectApproxEqAbs(30, try coverageSum(testing.allocator, out.path(), .xywh(0, 0, 32, 32)), 0.1);
}

test "closed dashed path joins the dash through the start point" {
    var src = PathBuilder.init(testing.allocator);
    defer src.deinit();
    var out = PathBuilder.init(testing.allocator);
    defer out.deinit();
    var s = Stroker.init(testing.allocator);
    defer s.deinit();
    try src.rect(.xywh(8, 8, 16, 16));
    // Perimeter 64, pattern 8 on / 8 off with offset 4: the first dash
    // covers the last 4 units before the start corner and 4 after it.
    try s.stroke(src.path(), .{ .width = 2, .dashes = &.{ 8, 8 }, .dash_offset = 4, .join = .miter }, 0.05, &out);
    // Four dashes each centred on a corner, each 8 long with a miter join:
    // two 4x2 arms that overlap in a 1x1 square, plus the 1x1 miter tip.
    const area = try coverageSum(testing.allocator, out.path(), .xywh(0, 0, 32, 32));
    try testing.expectApproxEqAbs(4 * 16, area, 0.2);
}

test "zero-length subpaths draw caps" {
    var src = PathBuilder.init(testing.allocator);
    defer src.deinit();
    var out = PathBuilder.init(testing.allocator);
    defer out.deinit();
    var s = Stroker.init(testing.allocator);
    defer s.deinit();
    try src.moveTo(10, 10);
    try src.lineTo(10, 10);
    try s.stroke(src.path(), .{ .width = 4, .cap = .square }, 0.05, &out);
    try testing.expectApproxEqAbs(16, try coverageSum(testing.allocator, out.path(), .xywh(0, 0, 32, 32)), 0.05);
    out.reset();
    try s.stroke(src.path(), .{ .width = 4, .cap = .butt }, 0.05, &out);
    try testing.expect(out.path().isEmpty());
}
