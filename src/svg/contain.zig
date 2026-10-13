//! Whether one filled region holds another, for clip paths that coincide
//! with what they clip (D19). Renderers combine a clip's coverage with a
//! draw's by multiplying them, which along an edge the two share gives
//! the square of the edge's coverage: icons exported with a clip path
//! around every shape (Adwaita since 45) would get thin, light outlines.
//! Where one region holds the other, their intersection is the inner one,
//! which the lowering then draws without the clip, exactly.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const Point = raster.Point;

const Line = struct { p0: Point, p1: Point };

/// Above this many segments the test is not worth it.
const max_lines = 4096;

/// Whether `inner` lies within `outer` (each filled with its rule), up to
/// `eps`: every point of inner's outline is inside outer or within eps of
/// its outline, and no point of outer's outline is inside inner farther
/// than eps from inner's outline. Outlines are checked at the vertices and
/// midpoints of their flattened segments.
pub fn contains(tmp: std.mem.Allocator, outer: raster.Path, outer_rule: scene.FillRule, inner: raster.Path, inner_rule: scene.FillRule, eps: f32) bool {
    var a: std.ArrayList(Line) = .empty;
    defer a.deinit(tmp);
    var b: std.ArrayList(Line) = .empty;
    defer b.deinit(tmp);
    flattenInto(tmp, outer, eps / 4, &a) catch return false;
    flattenInto(tmp, inner, eps / 4, &b) catch return false;
    if (a.items.len == 0 or b.items.len == 0 or a.items.len + b.items.len > max_lines) return false;
    for (b.items) |l| for ([_]Point{ l.p0, mid(l) }) |p| {
        if (!inside(a.items, outer_rule, p) and distance(a.items, p) > eps) return false;
    };
    for (a.items) |l| for ([_]Point{ l.p0, mid(l) }) |p| {
        if (inside(b.items, inner_rule, p) and distance(b.items, p) > eps) return false;
    };
    return true;
}

fn mid(l: Line) Point {
    return .{ .x = (l.p0.x + l.p1.x) / 2, .y = (l.p0.y + l.p1.y) / 2 };
}

const Sink = struct {
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    start: Point = .zero,
    last: Point = .zero,

    pub fn begin(s: *Sink, p: Point) error{OutOfMemory}!void {
        s.start = p;
        s.last = p;
    }
    pub fn lineTo(s: *Sink, p: Point) error{OutOfMemory}!void {
        if (s.lines.items.len > max_lines) return;
        if (s.last.x != p.x or s.last.y != p.y) try s.lines.append(s.gpa, .{ .p0 = s.last, .p1 = p });
        s.last = p;
    }
    pub fn end(s: *Sink, _: bool) error{OutOfMemory}!void {
        try s.lineTo(s.start);
    }
};

fn flattenInto(gpa: std.mem.Allocator, p: raster.Path, tolerance: f32, out: *std.ArrayList(Line)) error{OutOfMemory}!void {
    var sink: Sink = .{ .gpa = gpa, .lines = out };
    try raster.flatten(p, .identity, tolerance, &sink);
}

/// The winding number at `p` under `rule`.
fn inside(lines: []const Line, rule: scene.FillRule, p: Point) bool {
    var w: i32 = 0;
    for (lines) |l| {
        if (l.p0.y <= p.y) {
            if (l.p1.y > p.y and cross(l, p) > 0) w += 1;
        } else if (l.p1.y <= p.y and cross(l, p) < 0) w -= 1;
    }
    return switch (rule) {
        .nonzero => w != 0,
        .even_odd => @mod(w, 2) != 0,
    };
}

fn cross(l: Line, p: Point) f32 {
    return (l.p1.x - l.p0.x) * (p.y - l.p0.y) - (p.x - l.p0.x) * (l.p1.y - l.p0.y);
}

fn distance(lines: []const Line, p: Point) f32 {
    var best: f32 = std.math.inf(f32);
    for (lines) |l| {
        const dx = l.p1.x - l.p0.x;
        const dy = l.p1.y - l.p0.y;
        const dd = dx * dx + dy * dy;
        const t = if (dd > 0) std.math.clamp(((p.x - l.p0.x) * dx + (p.y - l.p0.y) * dy) / dd, 0, 1) else 0;
        const ex = l.p0.x + dx * t - p.x;
        const ey = l.p0.y + dy * t - p.y;
        best = @min(best, ex * ex + ey * ey);
    }
    return @sqrt(best);
}

test "regions that hold others, and ones that do not" {
    const gpa = std.testing.allocator;
    var big: raster.PathBuilder = .init(gpa);
    defer big.deinit();
    try big.rect(.xywh(0, 0, 10, 10));
    var small: raster.PathBuilder = .init(gpa);
    defer small.deinit();
    try small.ellipse(.xywh(2, 2, 6, 6));
    var edge: raster.PathBuilder = .init(gpa);
    defer edge.deinit();
    // Shares the big square's left edge.
    try edge.rect(.xywh(0, 2, 5, 5));
    var across: raster.PathBuilder = .init(gpa);
    defer across.deinit();
    try across.rect(.xywh(5, 5, 10, 10));
    try std.testing.expect(contains(gpa, big.path(), .nonzero, small.path(), .nonzero, 0.01));
    try std.testing.expect(contains(gpa, big.path(), .nonzero, edge.path(), .nonzero, 0.01));
    try std.testing.expect(!contains(gpa, small.path(), .nonzero, big.path(), .nonzero, 0.01));
    try std.testing.expect(!contains(gpa, big.path(), .nonzero, across.path(), .nonzero, 0.01));
    try std.testing.expect(!contains(gpa, across.path(), .nonzero, big.path(), .nonzero, 0.01));
    // A ring: the hole is not inside under even-odd.
    var ring: raster.PathBuilder = .init(gpa);
    defer ring.deinit();
    try ring.rect(.xywh(0, 0, 10, 10));
    try ring.rect(.xywh(3, 3, 4, 4));
    var hole: raster.PathBuilder = .init(gpa);
    defer hole.deinit();
    try hole.rect(.xywh(4, 4, 2, 2));
    try std.testing.expect(!contains(gpa, ring.path(), .even_odd, hole.path(), .nonzero, 0.01));
    try std.testing.expect(contains(gpa, ring.path(), .nonzero, hole.path(), .nonzero, 0.01));
}
