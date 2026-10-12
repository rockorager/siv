//! Curve flattening. Curves are transformed first (affine maps Béziers to
//! Béziers) and then subdivided uniformly in device space so that no point
//! of the polyline is farther than `tolerance` from the true curve.

const std = @import("std");
const geom = @import("geom.zig");
const Point = geom.Point;
const Affine = geom.Affine;
const Path = @import("path.zig").Path;

/// Default flattening tolerance in device pixels. Chords lie inside convex
/// curves, so analytic coverage turns chord error into an inward shift of
/// the edge by about 2/3 of the tolerance on average. 1/40 px keeps that
/// shift near 4/255 of coverage; segment counts grow only with the inverse
/// square root of the tolerance.
pub const default_tolerance: f32 = 0.025;

/// Upper bound on segments per curve, against degenerate input.
const max_segments: u32 = 1 << 10;

/// Walks `path` through `m` and reports polylines to `sink`, which must have:
///
///     fn begin(sink, p: Point) void        // start of a subpath
///     fn lineTo(sink, p: Point) void
///     fn end(sink, closed: bool) void      // after the last point
///
/// `closed` is true when the subpath ended with `close`. The sink decides
/// whether open subpaths are closed (fills) or capped (strokes). The sink
/// methods may return an error union; the first error stops the walk.
pub fn flatten(path: Path, m: Affine, tolerance: f32, sink: anytype) SinkError(@TypeOf(sink))!void {
    var it = path.iterator();
    var cur: Point = .zero;
    var open = false;
    while (it.next()) |seg| switch (seg) {
        .move => |p| {
            if (open) try call(sink.end(false));
            cur = m.apply(p);
            try call(sink.begin(cur));
            open = true;
        },
        .line => |p| {
            cur = m.apply(p);
            try call(sink.lineTo(cur));
        },
        .quad => |q| {
            const p1 = m.apply(q[0]);
            const p2 = m.apply(q[1]);
            try quad(cur, p1, p2, tolerance, sink);
            cur = p2;
        },
        .cubic => |q| {
            const p1 = m.apply(q[0]);
            const p2 = m.apply(q[1]);
            const p3 = m.apply(q[2]);
            try cubic(cur, p1, p2, p3, tolerance, sink);
            cur = p3;
        },
        .close => {
            if (open) try call(sink.end(true));
            open = false;
        },
    };
    if (open) try call(sink.end(false));
}

fn SinkError(comptime S: type) type {
    const T = switch (@typeInfo(S)) {
        .pointer => |p| p.child,
        else => S,
    };
    const R = @typeInfo(@TypeOf(T.lineTo)).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.error_set,
        else => error{},
    };
}

inline fn call(result: anytype) SinkErrorOf(@TypeOf(result))!void {
    if (@typeInfo(@TypeOf(result)) == .error_union) return result;
}

fn SinkErrorOf(comptime R: type) type {
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.error_set,
        else => error{},
    };
}

/// Segments needed for a quadratic: the chord error of a parameter step h
/// is |B''|·h²/8 with |B''| = 2·|p0 − 2p1 + p2|.
pub fn quadSegments(p0: Point, p1: Point, p2: Point, tolerance: f32) u32 {
    const dd = p0.sub(p1.scale(2)).add(p2).length();
    return segmentCount(@sqrt(dd / (4 * tolerance)));
}

/// Segments needed for a cubic (Wang's formula): |B''| ≤ 6·max(|p0 − 2p1 +
/// p2|, |p1 − 2p2 + p3|).
pub fn cubicSegments(p0: Point, p1: Point, p2: Point, p3: Point, tolerance: f32) u32 {
    const d1 = p0.sub(p1.scale(2)).add(p2).length();
    const d2 = p1.sub(p2.scale(2)).add(p3).length();
    return segmentCount(@sqrt(0.75 * @max(d1, d2) / tolerance));
}

fn segmentCount(n: f32) u32 {
    if (!(n >= 1)) return 1; // also catches NaN
    if (n >= max_segments) return max_segments;
    return @intFromFloat(@ceil(n));
}

fn quad(p0: Point, p1: Point, p2: Point, tolerance: f32, sink: anytype) SinkError(@TypeOf(sink))!void {
    const n = quadSegments(p0, p1, p2, tolerance);
    const dt = 1 / @as(f32, @floatFromInt(n));
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) * dt;
        const mt = 1 - t;
        try call(sink.lineTo(.{
            .x = mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x,
            .y = mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y,
        }));
    }
    try call(sink.lineTo(p2));
}

fn cubic(p0: Point, p1: Point, p2: Point, p3: Point, tolerance: f32, sink: anytype) SinkError(@TypeOf(sink))!void {
    const n = cubicSegments(p0, p1, p2, p3, tolerance);
    const dt = 1 / @as(f32, @floatFromInt(n));
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) * dt;
        const mt = 1 - t;
        const a = mt * mt * mt;
        const b = 3 * mt * mt * t;
        const c = 3 * mt * t * t;
        const d = t * t * t;
        try call(sink.lineTo(.{
            .x = a * p0.x + b * p1.x + c * p2.x + d * p3.x,
            .y = a * p0.y + b * p1.y + c * p2.y + d * p3.y,
        }));
    }
    try call(sink.lineTo(p3));
}

test "flattened quarter circle stays within tolerance" {
    const PathBuilder = @import("path.zig").PathBuilder;
    var b = PathBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.ellipse(.xywh(-100, -100, 200, 200));

    const Check = struct {
        prev: Point = .zero,
        max_err: f32 = 0,
        count: usize = 0,
        fn begin(c: *@This(), p: Point) void {
            c.prev = p;
        }
        fn lineTo(c: *@This(), p: Point) void {
            // Distance of the chord midpoint from the circle bounds the
            // sagitta error for short chords.
            const mid = c.prev.lerp(p, 0.5);
            c.max_err = @max(c.max_err, @abs(100 - mid.length()));
            c.prev = p;
            c.count += 1;
        }
        fn end(_: *@This(), closed: bool) void {
            std.debug.assert(closed);
        }
    };
    var check: Check = .{};
    try flatten(b.path(), .identity, 0.1, &check);
    // The cubic approximation of a circle itself deviates by 0.027%
    // (0.027 px at r = 100); the rest is flattening error.
    try std.testing.expect(check.max_err < 0.1 + 0.03);
    try std.testing.expect(check.count < 200);
}
