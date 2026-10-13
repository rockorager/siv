//! Per-layer damage (D9): which device pixels differ between two display
//! lists.
//!
//! Layers with the same nonzero id are matched across the lists. A matched
//! layer whose device transform or accumulated opacity changed damages its
//! old and new bounds. One whose version changed damages its declared
//! damage rectangle, or its old and new bounds without one. Layers present
//! in only one list damage their bounds there. A changed root version
//! damages everything. Unchanged layers cost one hash lookup.
//!
//! Callers keep the contract in `Layer.version`: everything about a layer
//! except its transform and opacity is versioned, including the order of
//! its child layers.

const std = @import("std");
const raster = @import("raster");
const Rect = raster.Rect;
const IRect = raster.IRect;
const Affine = raster.Affine;
const list = @import("list.zig");
const DisplayList = list.DisplayList;
const Command = list.Command;

/// More rectangles than this collapse into their bounding box.
pub const max_rects = 16;
/// While merging, more disjoint rectangles than this collapse at once.
const collapse_rects = 4 * max_rects;

pub const Tracker = struct {
    gpa: std.mem.Allocator,
    old_layers: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    stack: std.ArrayList(State) = .empty,
    rects: std.ArrayList(IRect) = .empty,
    /// Root transform and viewport of the previous call; a change damages
    /// everything.
    prev_root: ?Affine = null,
    prev_viewport: IRect = .empty,

    const Entry = struct {
        transform: Affine,
        opacity: f32,
        version: u32,
        bounds: IRect,
        matched: bool = false,
    };

    const State = struct {
        transform: Affine,
        opacity: f32,
        clip: Rect,
    };

    pub fn init(gpa: std.mem.Allocator) Tracker {
        return .{ .gpa = gpa };
    }

    pub fn deinit(t: *Tracker) void {
        t.old_layers.deinit(t.gpa);
        t.stack.deinit(t.gpa);
        t.rects.deinit(t.gpa);
        t.* = undefined;
    }

    /// Device rectangles (inside `viewport`) that may differ between
    /// rendering `old` and `new` through the device transform `root`.
    /// Without `old`, or when `root` or `viewport` differ from the previous
    /// call, the whole viewport. Use one tracker per surface. The result is
    /// valid until the next call.
    pub fn diff(t: *Tracker, old: ?DisplayList, new: DisplayList, root: Affine, viewport: IRect) error{OutOfMemory}![]const IRect {
        t.rects.clearRetainingCapacity();
        const same_target = if (t.prev_root) |r| r.eql(root) and t.prev_viewport.eql(viewport) else false;
        t.prev_root = root;
        t.prev_viewport = viewport;
        if (!same_target) return t.all(viewport);
        const prev = old orelse return t.all(viewport);
        if (prev.version != new.version) {
            try t.add(deviceBounds(root, prev.bounds, viewport.toRect()), viewport);
            try t.add(deviceBounds(root, new.bounds, viewport.toRect()), viewport);
            return t.finish(viewport);
        }

        // Index the old list's layers.
        t.old_layers.clearRetainingCapacity();
        var duplicate = false;
        {
            var walk = try Walk.start(t, root, viewport);
            for (prev.commands) |cmd| switch (cmd) {
                .push => |p| {
                    const s = try walk.push(p);
                    if (p.layer.id != 0) {
                        const gop = try t.old_layers.getOrPut(t.gpa, p.layer.id);
                        if (gop.found_existing) duplicate = true;
                        gop.value_ptr.* = .{ .transform = s.transform, .opacity = s.opacity, .version = p.layer.version, .bounds = s.bounds };
                    }
                },
                .pop => walk.pop(),
                else => {},
            };
        }

        var walk = try Walk.start(t, root, viewport);
        for (new.commands) |cmd| switch (cmd) {
            .push => |p| {
                const s = try walk.push(p);
                if (p.layer.id == 0) continue;
                const e = t.old_layers.getPtr(p.layer.id) orelse {
                    try t.add(s.bounds, viewport);
                    continue;
                };
                if (e.matched) duplicate = true;
                e.matched = true;
                if (!e.transform.eql(s.transform) or e.opacity != s.opacity) {
                    try t.add(e.bounds, viewport);
                    try t.add(s.bounds, viewport);
                } else if (e.version != p.layer.version) {
                    if (p.layer.damage) |d| {
                        try t.add(deviceBounds(s.transform, d, s.clip), viewport);
                    } else {
                        try t.add(e.bounds, viewport);
                        try t.add(s.bounds, viewport);
                    }
                }
            },
            .pop => walk.pop(),
            else => {},
        };
        if (duplicate) return t.all(viewport);

        var it = t.old_layers.valueIterator();
        while (it.next()) |e| if (!e.matched) try t.add(e.bounds, viewport);
        return t.finish(viewport);
    }

    fn all(t: *Tracker, viewport: IRect) error{OutOfMemory}![]const IRect {
        t.rects.clearRetainingCapacity();
        if (!viewport.isEmpty()) try t.rects.append(t.gpa, viewport);
        return t.rects.items;
    }

    fn add(t: *Tracker, r: IRect, viewport: IRect) error{OutOfMemory}!void {
        const c = r.intersect(viewport);
        if (c.isEmpty()) return;
        try t.rects.append(t.gpa, c);
    }

    /// Merges overlapping rectangles; too many collapse into one.
    ///
    /// Each rectangle merges into the disjoint ones kept so far (at the
    /// front of the list), absorbing every one it overlaps. Once more than
    /// `collapse_rects` stay disjoint, the result is the bounding box
    /// without looking further: merging thousands of rectangles pairwise
    /// (2,560 animated layers damage 5,120) took most of a frame.
    fn finish(t: *Tracker, viewport: IRect) []const IRect {
        _ = viewport;
        const rects = t.rects.items;
        var n: usize = 0;
        for (rects, 0..) |next, i| {
            var r = next;
            var k: usize = 0;
            while (k < n) {
                if (r.intersects(rects[k]) or r.contains(rects[k]) or rects[k].contains(r)) {
                    // The union may overlap rectangles already passed.
                    r = r.unite(rects[k]);
                    rects[k] = rects[n - 1];
                    n -= 1;
                    k = 0;
                } else k += 1;
            }
            rects[n] = r;
            n += 1;
            if (n > collapse_rects) {
                var u = IRect.empty;
                for (rects[0..n]) |kept| u = u.unite(kept);
                for (rects[i + 1 ..]) |rest| u = u.unite(rest);
                rects[0] = u;
                n = 1;
                break;
            }
        }
        if (n > max_rects) {
            var u = IRect.empty;
            for (rects[0..n]) |r| u = u.unite(r);
            rects[0] = u;
            n = 1;
        }
        t.rects.items.len = n;
        return t.rects.items;
    }

    const Walk = struct {
        t: *Tracker,
        viewport: IRect,

        const Pushed = struct { transform: Affine, opacity: f32, clip: Rect, bounds: IRect };

        fn start(t: *Tracker, root: Affine, viewport: IRect) error{OutOfMemory}!Walk {
            t.stack.clearRetainingCapacity();
            try t.stack.append(t.gpa, .{ .transform = root, .opacity = 1, .clip = viewport.toRect() });
            return .{ .t = t, .viewport = viewport };
        }

        fn push(w: *Walk, p: list.Push) error{OutOfMemory}!Pushed {
            const parent = w.t.stack.items[w.t.stack.items.len - 1];
            const m = p.layer.transform.then(parent.transform);
            var clip = parent.clip;
            if (p.layer.clip) |c| clip = clip.intersect(m.applyRect(c.shape.bounds()));
            const s: State = .{ .transform = m, .opacity = parent.opacity * p.layer.opacity, .clip = clip };
            try w.t.stack.append(w.t.gpa, s);
            return .{ .transform = m, .opacity = s.opacity, .clip = clip, .bounds = deviceBounds(m, p.bounds, parent.clip) };
        }

        fn pop(w: *Walk) void {
            if (w.t.stack.items.len > 1) w.t.stack.items.len -= 1;
        }
    };
};

fn deviceBounds(m: Affine, r: Rect, clip: Rect) IRect {
    if (r.isEmpty()) return IRect.empty;
    const b = if (std.math.isInf(r.x0) or std.math.isInf(r.x1) or std.math.isInf(r.y0) or std.math.isInf(r.y1))
        clip
    else
        m.applyRect(r).intersect(clip);
    return b.roundOut();
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const Builder = list.Builder;
const Color = list.Color;

const Scene = struct {
    a: Rect = .xywh(10, 10, 20, 20),
    a_version: u32 = 0,
    a_damage: ?Rect = null,
    b_offset: f32 = 0,
    b_opacity: f32 = 1,
    with_c: bool = false,

    fn build(s: Scene, b: *Builder) !DisplayList {
        b.reset();
        try b.fillRect(.xywh(0, 0, 200, 200), .color(.white));
        try b.pushLayer(.{ .id = 1, .version = s.a_version, .damage = s.a_damage });
        try b.fillRect(s.a, .color(.black));
        try b.popLayer();
        try b.pushLayer(.{ .id = 2, .transform = .translate(s.b_offset, 100), .opacity = s.b_opacity });
        try b.fillRect(.xywh(0, 0, 10, 10), .color(.black));
        try b.popLayer();
        if (s.with_c) {
            try b.pushLayer(.{ .id = 3 });
            try b.fillRect(.xywh(150, 150, 5, 5), .color(.black));
            try b.popLayer();
        }
        return b.finish(0);
    }
};

test "damage follows layer changes" {
    var b0 = Builder.init(testing.allocator);
    defer b0.deinit();
    var b1 = Builder.init(testing.allocator);
    defer b1.deinit();
    var t = Tracker.init(testing.allocator);
    defer t.deinit();
    const vp = IRect.xywh(0, 0, 200, 200);

    const base = try (Scene{}).build(&b0);
    try testing.expectEqualSlices(IRect, &.{vp}, try t.diff(null, base, .identity, vp));

    // Identical lists: no damage.
    try testing.expectEqual(@as(usize, 0), (try t.diff(base, try (Scene{}).build(&b1), .identity, vp)).len);

    // Version change without declared damage: old and new bounds.
    var s: Scene = .{ .a = .xywh(10, 10, 20, 30), .a_version = 1 };
    try testing.expectEqualSlices(IRect, &.{.xywh(10, 10, 20, 30)}, try t.diff(base, try s.build(&b1), .identity, vp));

    // Version change with declared damage.
    s = .{ .a_version = 1, .a_damage = .xywh(12.5, 12, 2, 2) };
    try testing.expectEqualSlices(IRect, &.{.xywh(12, 12, 3, 2)}, try t.diff(base, try s.build(&b1), .identity, vp));

    // Transform change: old and new position, which do not overlap.
    s = .{ .b_offset = 50 };
    const moved = try t.diff(base, try s.build(&b1), .identity, vp);
    try testing.expectEqual(@as(usize, 2), moved.len);

    // Opacity change.
    s = .{ .b_opacity = 0.5 };
    try testing.expectEqualSlices(IRect, &.{.xywh(0, 100, 10, 10)}, try t.diff(base, try s.build(&b1), .identity, vp));

    // Added and removed layers.
    s = .{ .with_c = true };
    const with_c = try s.build(&b1);
    try testing.expectEqualSlices(IRect, &.{.xywh(150, 150, 5, 5)}, try t.diff(base, with_c, .identity, vp));
    try testing.expectEqualSlices(IRect, &.{.xywh(150, 150, 5, 5)}, try t.diff(with_c, base, .identity, vp));

    // A different root transform damages everything.
    try testing.expectEqualSlices(IRect, &.{vp}, try t.diff(base, try (Scene{}).build(&b1), .scale(2, 2), vp));
}

test "root version change damages everything drawn" {
    var b0 = Builder.init(testing.allocator);
    defer b0.deinit();
    var b1 = Builder.init(testing.allocator);
    defer b1.deinit();
    var t = Tracker.init(testing.allocator);
    defer t.deinit();
    try b0.fillRect(.xywh(0, 0, 50, 50), .color(.black));
    const l0 = try b0.finish(1);
    try b1.fillRect(.xywh(0, 0, 50, 50), .color(.white));
    const l1 = try b1.finish(2);
    _ = try t.diff(null, l0, .identity, .xywh(0, 0, 100, 100));
    try testing.expectEqualSlices(IRect, &.{.xywh(0, 0, 50, 50)}, try t.diff(l0, l1, .identity, .xywh(0, 0, 100, 100)));
}
