//! Where a window's layer updates go, and a synchronous stand-in for the
//! compositor thread for tests.
//!
//! A window commits `compositor.Op` batches through a `Sink`; the
//! application connects it to the compositor thread and feeds the events
//! that come back (`compositor.Event`) to `Window.handleEvent`.
//! `TestCompositor` applies the ops on the calling thread and flattens the
//! layer tree into one display list for the CPU renderer, with layer ids
//! and versions that `scene.damage.Tracker` turns into device damage.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const compositor = @import("compositor");

const Op = compositor.Op;
const LayerId = compositor.LayerId;
const Point = raster.Point;
const Rect = raster.Rect;

pub const Sink = struct {
    ctx: ?*anyopaque,
    /// Commits a batch of ops atomically and returns its sequence number.
    /// The ops refer to builders the receiver now owns until it releases
    /// them; on error nothing was applied.
    commit: *const fn (ctx: ?*anyopaque, ops: []const Op) error{OutOfMemory}!u64,
};

/// Applies layer ops like the compositor thread would, without a thread.
pub const TestCompositor = struct {
    gpa: std.mem.Allocator,
    layers: std.AutoHashMapUnmanaged(LayerId, Layer) = .empty,
    root: LayerId = 0,
    background: scene.Color = .transparent,
    seq: u64 = 0,
    /// Builders replaced or destroyed since the last `flatten`, released
    /// after it (no frame reads them any more).
    retired: std.ArrayList(*scene.Builder) = .empty,
    /// Released builders for the window to take back (`Event.released`).
    released: std.ArrayList(*scene.Builder) = .empty,
    builders: [2]scene.Builder,
    current: u1 = 0,
    /// Offsets the compositor changed (by input or `scroll_by`), to report
    /// in `Event.scrolled`.
    reports: std.ArrayList(Report) = .empty,
    /// Highest configure serial acknowledged.
    acked_configure: u64 = 0,
    /// Ops applied, for tests that inspect what was sent.
    log: std.ArrayList(Op) = .empty,
    keep_log: bool = false,

    pub const Report = struct { layer: LayerId, offset: Point, seq: u64 };

    pub const Layer = struct {
        parent: LayerId = 0,
        children: std.ArrayList(LayerId) = .empty,
        transform: compositor.Transform = .identity,
        opacity: f32 = 1,
        clip: ?compositor.Clip = null,
        scroll: ?compositor.Scroll = null,
        offset: Point = .zero,
        wheel: ?Rect = null,
        content: ?compositor.Content = null,
        /// Bumped on anything that changes what the layer draws other than
        /// its transform and opacity.
        version: u32 = 0,
        /// Content damage since the last flatten.
        damage: ?Rect = null,
        damage_all: bool = true,
    };

    pub fn init(gpa: std.mem.Allocator) TestCompositor {
        return .{ .gpa = gpa, .builders = .{ .init(gpa), .init(gpa) } };
    }

    pub fn deinit(tc: *TestCompositor) void {
        var it = tc.layers.valueIterator();
        while (it.next()) |l| l.children.deinit(tc.gpa);
        tc.layers.deinit(tc.gpa);
        tc.retired.deinit(tc.gpa);
        tc.released.deinit(tc.gpa);
        tc.reports.deinit(tc.gpa);
        tc.log.deinit(tc.gpa);
        for (&tc.builders) |*b| b.deinit();
    }

    pub fn sink(tc: *TestCompositor) Sink {
        return .{ .ctx = tc, .commit = commitFn };
    }

    fn commitFn(ctx: ?*anyopaque, ops: []const Op) error{OutOfMemory}!u64 {
        const tc: *TestCompositor = @ptrCast(@alignCast(ctx));
        return tc.commit(ops);
    }

    pub fn commit(tc: *TestCompositor, ops: []const Op) error{OutOfMemory}!u64 {
        try tc.retired.ensureUnusedCapacity(tc.gpa, ops.len + tc.layers.count());
        if (tc.keep_log) try tc.log.appendSlice(tc.gpa, ops);
        for (ops) |op| {
            op.validate() catch std.debug.panic("invalid op {any}", .{op});
            try tc.apply(op);
        }
        tc.seq += 1;
        return tc.seq;
    }

    pub fn get(tc: *TestCompositor, id: LayerId) *Layer {
        return tc.layers.getPtr(id) orelse std.debug.panic("op names missing layer {d}", .{id});
    }

    fn detach(tc: *TestCompositor, id: LayerId) void {
        const l = tc.get(id);
        if (l.parent == 0) return;
        const p = tc.get(l.parent);
        for (p.children.items, 0..) |c, i| if (c == id) {
            _ = p.children.orderedRemove(i);
            break;
        };
        l.parent = 0;
    }

    fn destroy(tc: *TestCompositor, id: LayerId) void {
        const l = tc.get(id);
        while (l.children.pop()) |c| {
            tc.get(c).parent = 0;
            tc.destroy(c);
        }
        l.children.deinit(tc.gpa);
        if (l.content) |c| tc.retired.appendAssumeCapacity(c.builder);
        _ = tc.layers.remove(id);
        if (tc.root == id) tc.root = 0;
    }

    fn apply(tc: *TestCompositor, op: Op) error{OutOfMemory}!void {
        switch (op) {
            .create => |id| {
                if (tc.layers.contains(id)) std.debug.panic("layer {d} exists", .{id});
                try tc.layers.put(tc.gpa, id, .{});
            },
            .destroy => |id| {
                tc.detach(id);
                tc.destroy(id);
            },
            .set_root => |id| tc.root = id,
            .insert => |ins| {
                var p = ins.parent;
                while (p != 0) : (p = tc.get(p).parent) if (p == ins.layer) std.debug.panic("cycle", .{});
                tc.detach(ins.layer);
                const parent = tc.get(ins.parent);
                const at = if (ins.before == 0) parent.children.items.len else std.mem.indexOfScalar(LayerId, parent.children.items, ins.before).?;
                try parent.children.insert(tc.gpa, at, ins.layer);
                tc.get(ins.layer).parent = ins.parent;
            },
            .detach => |id| tc.detach(id),
            .set_content => |sc| {
                const l = tc.get(sc.layer);
                if (l.content) |c| if (sc.content == null or c.builder != sc.content.?.builder) tc.retired.appendAssumeCapacity(c.builder);
                l.content = sc.content;
                l.version +%= 1;
                if (sc.damage) |d| {
                    l.damage = if (l.damage) |old| old.unite(d) else d;
                } else l.damage_all = true;
            },
            .set_transform => |s| tc.get(s.layer).transform = s.transform,
            .set_opacity => |s| tc.get(s.layer).opacity = std.math.clamp(s.opacity, 0, 1),
            .set_clip => |s| {
                const l = tc.get(s.layer);
                l.clip = s.clip;
                l.version +%= 1;
                l.damage_all = true;
            },
            .set_scroll => |s| {
                const l = tc.get(s.layer);
                l.scroll = s.scroll;
                if (s.scroll) |sc| l.offset = clampOffset(l.offset, sc);
                l.version +%= 1;
                l.damage_all = true;
            },
            .scroll_to => |s| {
                const l = tc.get(s.layer);
                l.offset = if (l.scroll) |sc| clampOffset(s.offset, sc) else s.offset;
            },
            .scroll_by => |s| {
                const l = tc.get(s.layer);
                if (l.scroll) |sc| {
                    l.offset = clampOffset(l.offset.add(s.delta), sc);
                    try tc.reports.append(tc.gpa, .{ .layer = s.layer, .offset = l.offset, .seq = tc.seq + 1 });
                }
            },
            .set_wheel_region => |s| tc.get(s.layer).wheel = s.region,
            .ack_configure => |serial| tc.acked_configure = @max(tc.acked_configure, serial),
            .fling, .animate => {},
            .set_background => |c| tc.background = c,
        }
    }

    fn clampOffset(p: Point, s: compositor.Scroll) Point {
        return .{
            .x = std.math.clamp(p.x, 0, @max(0, s.content.width - s.viewport.width())),
            .y = std.math.clamp(p.y, 0, @max(0, s.content.height - s.viewport.height())),
        };
    }

    /// Scrolls a container as pointer input would; returns the clamped
    /// offset to report in `Event.scrolled`.
    pub fn scrollBy(tc: *TestCompositor, id: LayerId, delta: Point) Point {
        const l = tc.get(id);
        l.offset = clampOffset(l.offset.add(delta), l.scroll.?);
        return l.offset;
    }

    pub const Route = union(enum) { ui, scroll: LayerId };

    /// Where pointer scroll by `delta` at window point `p` goes, by the
    /// compositor's rules (D8): modifiers and wheel regions go to the UI,
    /// else the nearest input-taking scroll container above the topmost
    /// hit layer that can move.
    pub fn route(tc: *TestCompositor, p: Point, delta: Point, mods: @import("platform").Mods) Route {
        if (tc.root == 0 or mods.ctrl or mods.alt or mods.super) return .ui;
        return switch (tc.routeLayer(tc.root, p, delta)) {
            .miss, .pending, .ui => .ui,
            .scroll => |id| .{ .scroll = id },
        };
    }

    const Hit = union(enum) { miss, pending, ui, scroll: LayerId };

    fn routeLayer(tc: *TestCompositor, id: LayerId, parent_p: Point, delta: Point) Hit {
        const l = tc.get(id);
        const inv = l.transform.affine().invert() orelse return .miss;
        const p = inv.apply(parent_p);
        if (l.clip) |c| if (!contains(c.rect, p)) return .miss;
        var hit: Hit = .miss;
        const in_viewport = if (l.scroll) |s| contains(s.viewport, p) else true;
        if (in_viewport) {
            const cp = p.add(l.offset);
            var i = l.children.items.len;
            while (i > 0) {
                i -= 1;
                hit = tc.routeLayer(l.children.items[i], cp, delta);
                if (hit != .miss) break;
            }
        }
        const wheel = if (l.wheel) |w| contains(w, p) else false;
        if (hit == .miss) {
            const on_content = if (l.content) |c| contains(c.list.bounds, p) else false;
            if (!on_content and !wheel) return .miss;
            hit = .pending;
        }
        if (hit != .pending) return hit;
        if (wheel) return .ui;
        if (l.scroll) |s| if (s.input and in_viewport and canMove(s, l.offset, delta)) return .{ .scroll = id };
        return .pending;
    }

    fn canMove(s: compositor.Scroll, offset: Point, d: Point) bool {
        const m = clampOffset(.{ .x = std.math.inf(f32), .y = std.math.inf(f32) }, s);
        return (d.x > 0 and offset.x < m.x) or (d.x < 0 and offset.x > 0) or
            (d.y > 0 and offset.y < m.y) or (d.y < 0 and offset.y > 0);
    }

    fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x0 and p.x < r.x1 and p.y >= r.y0 and p.y < r.y1;
    }

    /// The layer tree as one display list. Valid until the next call but
    /// one (two builders alternate, so the previous list stays valid for
    /// damage tracking). Releases builders retired before it.
    pub fn flatten(tc: *TestCompositor) scene.Error!scene.DisplayList {
        tc.current +%= 1;
        const b = &tc.builders[tc.current];
        b.reset();
        if (tc.root != 0) try tc.emit(b, tc.root);
        const list = try b.finish(0);
        try tc.released.appendSlice(tc.gpa, tc.retired.items);
        tc.retired.clearRetainingCapacity();
        return list;
    }

    fn emit(tc: *TestCompositor, b: *scene.Builder, id: LayerId) scene.Error!void {
        const l = tc.get(id);
        try b.pushLayer(.{
            .id = id,
            .version = l.version,
            .transform = l.transform.affine(),
            .opacity = l.opacity,
            .clip = if (l.clip) |c| .{ .shape = if (isZero(c.radii)) .{ .rect = c.rect } else .{ .rounded_rect = .{ .rect = c.rect, .radii = c.radii } } } else null,
            .damage = if (l.damage_all) null else l.damage orelse Rect.empty,
        });
        l.damage = null;
        l.damage_all = false;
        if (l.content) |c| try replay(b, c.list);
        if (l.scroll) |s| {
            try b.pushLayer(.{ .clip = .{ .shape = .{ .rect = s.viewport } } });
            try b.pushLayer(.{ .id = id | 0x8000_0000, .transform = .translate(-l.offset.x, -l.offset.y) });
        }
        for (l.children.items) |c| try tc.emit(b, c);
        if (l.scroll != null) {
            try b.popLayer();
            try b.popLayer();
        }
        try b.popLayer();
    }

    fn isZero(r: raster.Radii) bool {
        return r.tl.x == 0 and r.tl.y == 0 and r.tr.x == 0 and r.tr.y == 0 and r.br.x == 0 and r.br.y == 0 and r.bl.x == 0 and r.bl.y == 0;
    }
};

/// Re-issues a display list's commands into a builder. Layers inside keep
/// their ids, so give content layers no ids (the UI never does).
pub fn replay(b: *scene.Builder, list: scene.DisplayList) scene.Error!void {
    for (list.commands) |cmd| switch (cmd) {
        .push => |p| try b.pushLayer(p.layer),
        .pop => try b.popLayer(),
        .fill => |f| try b.fill(f.shape, f.rule, f.paint),
        .stroke => |s| try b.stroke(s.shape, s.style, s.paint),
        .glyphs => |g| try b.glyphs(g),
        .image => |i| try b.image(i),
        .backdrop_blur => |bb| try b.backdropBlur(bb.shape, bb.sigma),
    };
}
