//! Vector paths: an immutable `Path` view and the `PathBuilder` that
//! produces it. The builder's verbs match HarfBuzz's draw callbacks
//! (move_to, line_to, quadratic_to, cubic_to, close_path) one to one, so a
//! glyph outline feeds straight into it.

const std = @import("std");
const geom = @import("geom.zig");
const Point = geom.Point;
const Rect = geom.Rect;
const Affine = geom.Affine;

pub const Verb = enum(u8) {
    /// Starts a subpath. 1 point.
    move,
    /// 1 point.
    line,
    /// Quadratic Bézier: control, end. 2 points.
    quad,
    /// Cubic Bézier: control 1, control 2, end. 3 points.
    cubic,
    /// Closes the current subpath with a line to its start. 0 points.
    close,

    pub fn pointCount(v: Verb) usize {
        return switch (v) {
            .move, .line => 1,
            .quad => 2,
            .cubic => 3,
            .close => 0,
        };
    }
};

/// Immutable view of a path. Every subpath starts with `move`. Filling
/// closes open subpaths implicitly; stroking does not.
pub const Path = struct {
    verbs: []const Verb = &.{},
    points: []const Point = &.{},

    pub const empty: Path = .{};

    pub fn isEmpty(p: Path) bool {
        return p.verbs.len == 0;
    }

    /// Bounds of all points, including control points. The curve lies
    /// inside its control polygon, so this contains the path.
    pub fn bounds(p: Path) Rect {
        var r = Rect.empty;
        for (p.points) |pt| r = r.includePoint(pt);
        return r;
    }

    /// Bounds of the path after a transform (of the transformed control
    /// points, so still conservative).
    pub fn transformedBounds(p: Path, m: Affine) Rect {
        var r = Rect.empty;
        for (p.points) |pt| r = r.includePoint(m.apply(pt));
        return r;
    }

    pub fn iterator(p: Path) Iterator {
        return .{ .path = p };
    }

    /// Checks the structural invariants: verbs and points agree in count,
    /// every subpath starts with move, and coordinates are finite.
    pub fn validate(p: Path) error{InvalidPath}!void {
        var n: usize = 0;
        var open = false;
        for (p.verbs) |v| {
            switch (v) {
                .move => open = true,
                .close => {
                    if (!open) return error.InvalidPath;
                    open = false;
                },
                else => if (!open) return error.InvalidPath,
            }
            n += v.pointCount();
        }
        if (n != p.points.len) return error.InvalidPath;
        for (p.points) |pt| {
            if (!std.math.isFinite(pt.x) or !std.math.isFinite(pt.y)) return error.InvalidPath;
        }
    }

    pub const Segment = union(enum) {
        move: Point,
        line: Point,
        quad: [2]Point,
        cubic: [3]Point,
        close,
    };

    pub const Iterator = struct {
        path: Path,
        verb: usize = 0,
        point: usize = 0,

        pub fn next(it: *Iterator) ?Segment {
            if (it.verb >= it.path.verbs.len) return null;
            const v = it.path.verbs[it.verb];
            const pts = it.path.points[it.point..];
            it.verb += 1;
            it.point += v.pointCount();
            return switch (v) {
                .move => .{ .move = pts[0] },
                .line => .{ .line = pts[0] },
                .quad => .{ .quad = .{ pts[0], pts[1] } },
                .cubic => .{ .cubic = .{ pts[0], pts[1], pts[2] } },
                .close => .close,
            };
        }
    };
};

/// Builds paths. Reusing a builder through `reset` keeps its capacity, so a
/// steady state allocates nothing.
///
/// Drawing without a preceding `moveTo` starts a subpath at the current
/// point (or the origin), as HarfBuzz and PostScript do.
pub const PathBuilder = struct {
    gpa: std.mem.Allocator,
    verbs: std.ArrayList(Verb) = .empty,
    points: std.ArrayList(Point) = .empty,
    start: Point = .zero,
    current: Point = .zero,
    open: bool = false,

    pub fn init(gpa: std.mem.Allocator) PathBuilder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *PathBuilder) void {
        b.verbs.deinit(b.gpa);
        b.points.deinit(b.gpa);
        b.* = undefined;
    }

    pub fn reset(b: *PathBuilder) void {
        b.verbs.clearRetainingCapacity();
        b.points.clearRetainingCapacity();
        b.start = .zero;
        b.current = .zero;
        b.open = false;
    }

    /// The path built so far. Valid until the builder is modified.
    pub fn path(b: *const PathBuilder) Path {
        return .{ .verbs = b.verbs.items, .points = b.points.items };
    }

    pub fn moveTo(b: *PathBuilder, x: f32, y: f32) error{OutOfMemory}!void {
        const p: Point = .{ .x = x, .y = y };
        // Consecutive moves collapse into one.
        if (b.verbs.items.len > 0 and b.verbs.items[b.verbs.items.len - 1] == .move) {
            b.points.items[b.points.items.len - 1] = p;
        } else {
            try b.push(.move, &.{p});
        }
        b.start = p;
        b.current = p;
        b.open = true;
    }

    pub fn lineTo(b: *PathBuilder, x: f32, y: f32) error{OutOfMemory}!void {
        try b.ensureOpen();
        const p: Point = .{ .x = x, .y = y };
        try b.push(.line, &.{p});
        b.current = p;
    }

    pub fn quadTo(b: *PathBuilder, cx: f32, cy: f32, x: f32, y: f32) error{OutOfMemory}!void {
        try b.ensureOpen();
        const p: Point = .{ .x = x, .y = y };
        try b.push(.quad, &.{ .{ .x = cx, .y = cy }, p });
        b.current = p;
    }

    pub fn cubicTo(b: *PathBuilder, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) error{OutOfMemory}!void {
        try b.ensureOpen();
        const p: Point = .{ .x = x, .y = y };
        try b.push(.cubic, &.{ .{ .x = c1x, .y = c1y }, .{ .x = c2x, .y = c2y }, p });
        b.current = p;
    }

    pub fn close(b: *PathBuilder) error{OutOfMemory}!void {
        if (!b.open) return;
        try b.push(.close, &.{});
        b.current = b.start;
        b.open = false;
    }

    /// Appends a path, transformed.
    pub fn append(b: *PathBuilder, p: Path, m: Affine) error{OutOfMemory}!void {
        var it = p.iterator();
        while (it.next()) |seg| switch (seg) {
            .move => |q| {
                const t = m.apply(q);
                try b.moveTo(t.x, t.y);
            },
            .line => |q| {
                const t = m.apply(q);
                try b.lineTo(t.x, t.y);
            },
            .quad => |q| {
                const c = m.apply(q[0]);
                const t = m.apply(q[1]);
                try b.quadTo(c.x, c.y, t.x, t.y);
            },
            .cubic => |q| {
                const c1 = m.apply(q[0]);
                const c2 = m.apply(q[1]);
                const t = m.apply(q[2]);
                try b.cubicTo(c1.x, c1.y, c2.x, c2.y, t.x, t.y);
            },
            .close => try b.close(),
        };
    }

    pub fn rect(b: *PathBuilder, r: Rect) error{OutOfMemory}!void {
        try b.moveTo(r.x0, r.y0);
        try b.lineTo(r.x1, r.y0);
        try b.lineTo(r.x1, r.y1);
        try b.lineTo(r.x0, r.y1);
        try b.close();
    }

    /// Rounded rectangle, clockwise on screen. Radii are per corner
    /// (top-left, top-right, bottom-right, bottom-left), each with an x and
    /// y component, and are scaled down uniformly if they overlap (as CSS
    /// does).
    pub fn roundedRect(b: *PathBuilder, r: Rect, radii: Radii) error{OutOfMemory}!void {
        const rr = radii.fit(r);
        const k = 1 - kappa;
        try b.moveTo(r.x0 + rr.tl.x, r.y0);
        try b.lineTo(r.x1 - rr.tr.x, r.y0);
        if (rr.tr.x > 0 and rr.tr.y > 0)
            try b.cubicTo(r.x1 - rr.tr.x * k, r.y0, r.x1, r.y0 + rr.tr.y * k, r.x1, r.y0 + rr.tr.y);
        try b.lineTo(r.x1, r.y1 - rr.br.y);
        if (rr.br.x > 0 and rr.br.y > 0)
            try b.cubicTo(r.x1, r.y1 - rr.br.y * k, r.x1 - rr.br.x * k, r.y1, r.x1 - rr.br.x, r.y1);
        try b.lineTo(r.x0 + rr.bl.x, r.y1);
        if (rr.bl.x > 0 and rr.bl.y > 0)
            try b.cubicTo(r.x0 + rr.bl.x * k, r.y1, r.x0, r.y1 - rr.bl.y * k, r.x0, r.y1 - rr.bl.y);
        try b.lineTo(r.x0, r.y0 + rr.tl.y);
        if (rr.tl.x > 0 and rr.tl.y > 0)
            try b.cubicTo(r.x0, r.y0 + rr.tl.y * k, r.x0 + rr.tl.x * k, r.y0, r.x0 + rr.tl.x, r.y0);
        try b.close();
    }

    /// Ellipse inscribed in `r`, clockwise on screen.
    pub fn ellipse(b: *PathBuilder, r: Rect) error{OutOfMemory}!void {
        const rx = r.width() / 2;
        const ry = r.height() / 2;
        try b.roundedRect(r, Radii.uniform(rx, ry));
    }

    fn ensureOpen(b: *PathBuilder) error{OutOfMemory}!void {
        if (!b.open) try b.moveTo(b.current.x, b.current.y);
    }

    fn push(b: *PathBuilder, v: Verb, pts: []const Point) error{OutOfMemory}!void {
        try b.verbs.ensureUnusedCapacity(b.gpa, 1);
        try b.points.appendSlice(b.gpa, pts);
        b.verbs.appendAssumeCapacity(v);
    }
};

/// Cubic Bézier control distance for a quarter circle of radius 1.
pub const kappa: f32 = 0.5522847498;

/// Corner radii of a rounded rectangle.
pub const Radii = extern struct {
    tl: Point = .zero,
    tr: Point = .zero,
    br: Point = .zero,
    bl: Point = .zero,

    pub fn uniform(rx: f32, ry: f32) Radii {
        const p: Point = .{ .x = rx, .y = ry };
        return .{ .tl = p, .tr = p, .br = p, .bl = p };
    }

    pub fn eql(a: Radii, b: Radii) bool {
        return a.tl.eql(b.tl) and a.tr.eql(b.tr) and a.br.eql(b.br) and a.bl.eql(b.bl);
    }

    /// Clamps negative radii to zero and scales all radii down uniformly so
    /// that adjacent corners do not overlap (CSS Backgrounds 3, 5.5).
    pub fn fit(radii: Radii, r: Rect) Radii {
        var out = radii;
        inline for (.{ &out.tl, &out.tr, &out.br, &out.bl }) |c| {
            c.x = @max(c.x, 0);
            c.y = @max(c.y, 0);
        }
        const w = @max(r.width(), 0);
        const h = @max(r.height(), 0);
        var f: f32 = 1;
        f = @min(f, ratio(w, out.tl.x + out.tr.x));
        f = @min(f, ratio(w, out.bl.x + out.br.x));
        f = @min(f, ratio(h, out.tl.y + out.bl.y));
        f = @min(f, ratio(h, out.tr.y + out.br.y));
        if (f < 1) inline for (.{ &out.tl, &out.tr, &out.br, &out.bl }) |c| {
            c.* = c.scale(f);
        };
        return out;
    }

    fn ratio(len: f32, sum: f32) f32 {
        return if (sum > len) len / sum else 1;
    }
};

test "builder produces a valid path and reuses capacity" {
    var b = PathBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.moveTo(0, 0);
    try b.lineTo(10, 0);
    try b.quadTo(10, 10, 0, 10);
    try b.close();
    // Drawing after close starts a new subpath at the start point.
    try b.cubicTo(1, 1, 2, 2, 3, 3);
    const p = b.path();
    try p.validate();
    try std.testing.expectEqualSlices(Verb, &.{ .move, .line, .quad, .close, .move, .cubic }, p.verbs);
    try std.testing.expectEqual(Point{ .x = 0, .y = 0 }, p.points[4]);
    const r = p.bounds();
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 }, r);

    const cap = b.points.capacity;
    b.reset();
    try b.rect(.xywh(0, 0, 1, 1));
    try std.testing.expectEqual(cap, b.points.capacity);
}

test "radii fit scales overlapping corners" {
    const r = Radii.uniform(30, 30).fit(.xywh(0, 0, 40, 100));
    try std.testing.expectApproxEqAbs(20, r.tl.x, 1e-5);
    try std.testing.expectApproxEqAbs(20, r.br.y, 1e-5);
}

test "validate rejects malformed paths" {
    try std.testing.expectError(error.InvalidPath, (Path{ .verbs = &.{.line}, .points = &.{.zero} }).validate());
    try std.testing.expectError(error.InvalidPath, (Path{ .verbs = &.{.move}, .points = &.{} }).validate());
    const nan: Point = .{ .x = std.math.nan(f32), .y = 0 };
    try std.testing.expectError(error.InvalidPath, (Path{ .verbs = &.{.move}, .points = &.{nan} }).validate());
}
