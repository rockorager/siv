//! A window's layer tree on the compositor thread: applies `Op`s, runs
//! animations and flings, routes pointer scroll, and composes the tree
//! into one display list per frame for damage tracking and rendering.
//!
//! Composition wraps each layer's content in a scene layer whose id is the
//! layer's id, so that `scene.damage.Tracker` matches layers across frames
//! (D9). Ids inside content are cleared: content changes are covered by
//! the layer's version and declared damage. A scroll container's children
//! go inside a second scene layer, with id `id | scroll_bit`, that clips
//! them to the viewport and translates them by the offset.

const std = @import("std");
const Allocator = std.mem.Allocator;
const raster = @import("raster");
const scene = @import("scene");
const platform = @import("platform");
const update = @import("update.zig");
const anim = @import("anim.zig");

const Point = raster.Point;
const Rect = raster.Rect;
const Affine = raster.Affine;
const Command = scene.Command;
const LayerId = update.LayerId;
const Op = update.Op;
const Transform = update.Transform;
const Value = update.Value;
const Property = update.Property;

const log = std.log.scoped(.compositor);

/// Layer ids must stay below this; the bit marks scroll wrappers.
pub const scroll_bit: u32 = 1 << 31;
/// Retired content kept for damage tracking beyond this is released at
/// once, at the cost of a full redraw (a window that stopped rendering).
const max_retired = 64;

pub const Finished = struct { layer: LayerId, id: u32, property: Property };

pub const Layer = struct {
    alive: bool = false,
    parent: LayerId = 0,
    first: LayerId = 0,
    last: LayerId = 0,
    prev: LayerId = 0,
    next: LayerId = 0,

    transform: Transform = .identity,
    opacity: f32 = 1,
    clip: ?update.Clip = null,
    scroll: ?update.Scroll = null,
    offset: Point = .zero,
    /// Scale of a zoomable scroll container's children (see
    /// `update.Scroll`).
    zoom: f32 = 1,
    wheel: ?Rect = null,
    blur: ?update.BlurShape = null,
    external: ?update.ExternalPlacement = null,
    content: ?update.Content = null,

    /// Scene layer versions (D9) and damage since the last composition.
    version: u32 = 0,
    scroll_version: u32 = 0,
    damage: ?Rect = null,
    damage_all: bool = false,

    anims: [std.enums.values(Property).len]?anim.Running = @splat(null),
    fling: ?anim.Fling = null,
    animated: bool = false,
    scrolled: bool = false,
    /// Shown while its animation runs (`update.Value.reveal`).
    reveal: ?update.Clip = null,
    /// Given up by the UI (`Op.exit`).
    exiting: bool = false,

    fn animating(l: *const Layer) bool {
        if (l.fling != null) return true;
        for (l.anims) |a| if (a != null) return true;
        return false;
    }

    /// Runs an animation that ends.
    fn ending(l: *const Layer) bool {
        for (l.anims) |a| if (a) |r| if (r.anim.iterations != 0) return true;
        return false;
    }
};

pub const Route = union(enum) {
    /// Deliver to the UI.
    ui,
    /// Scroll (or, for a pinch, zoom) this container in the compositor.
    scroll: LayerId,
};

/// Maps a scroll container's child coordinates to its own: zoomed about
/// the viewport's top-left corner, then moved by the offset.
fn childMap(l: *const Layer) Affine {
    const s = l.scroll orelse return .identity;
    const o: Point = .{ .x = s.viewport.x0, .y = s.viewport.y0 };
    if (l.zoom == 1) return Affine.translate(-l.offset.x, -l.offset.y);
    return Affine.translate(-o.x, -o.y).then(.scale(l.zoom, l.zoom)).then(.translate(o.x - l.offset.x, o.y - l.offset.y));
}

/// The inverse of `childMap` for a point.
fn childPoint(l: *const Layer, p: Point) Point {
    const s = l.scroll orelse return p;
    const o: Point = .{ .x = s.viewport.x0, .y = s.viewport.y0 };
    return .{ .x = o.x + (p.x - o.x + l.offset.x) / l.zoom, .y = o.y + (p.y - o.y + l.offset.y) / l.zoom };
}

/// How composition draws an external.
pub const Draw = struct {
    what: What = .none,
    /// The content is on a subsurface.
    promoted: bool = false,
    /// The placement's background is on a subsurface (D17): the window
    /// paints none, and a hole covers the whole box. Otherwise the window
    /// paints it: below the content, or around it where the content is on
    /// a subsurface (which may be translucent, so they must not overlap).
    solid: bool = false,

    pub const What = union(enum) {
        /// Nothing: on a subsurface above the window, or no frame yet.
        none,
        /// Composite this frame.
        image: scene.ImageRef,
        /// On a subsurface below the window: clear the window to
        /// transparent there, so that the subsurface shows through and
        /// what is painted later (video controls) composites over it.
        hole,
    };
};

/// How composition draws external content: the compositor decides which
/// externals are on subsurfaces (promoted) and maps the others' frames.
pub const Externals = struct {
    ctx: *anyopaque,
    draw: *const fn (ctx: *anyopaque, id: update.ExternalId) Draw,
};

/// An external's placement in the window, from `externalPlacements`.
pub const Found = struct {
    id: update.ExternalId,
    layer: LayerId,
    /// In surface (logical) coordinates.
    rect: Rect,
    /// The part the clips leave visible, in surface coordinates.
    visible: Rect,
    /// That part as a fraction of the content (0..1 on each axis).
    source: Rect,
    /// Axis-aligned with positive scale and clipped only by rectangles,
    /// with something left visible: a subsurface can show it (at
    /// `opacity`, if alpha-modifier-v1 is there).
    promotable: bool,
    /// Something painted later overlaps it (or its background's box): a
    /// subsurface must go below the window, with a hole punched in the
    /// window's pixels.
    covered: bool,
    /// The product of its layer's and every ancestor's opacity.
    opacity: f32 = 1,
    /// The placement's background, and the part of its box the clips
    /// leave visible (surface coordinates; empty without a background).
    background: scene.Color = .transparent,
    box: Rect = Rect.empty,
    /// The placement's content box, unclipped (surface coordinates); its
    /// rect when the placement has none.
    content: Rect = Rect.empty,
};

pub const Tree = struct {
    gpa: Allocator,
    /// Set by the compositor before `compose`.
    externals: ?Externals = null,
    layers: std.ArrayList(Layer) = .empty,
    root: LayerId = 0,
    background: scene.Color = .transparent,
    /// The background changed: everything needs redrawing.
    background_changed: bool = false,
    /// Highest configure serial the UI's commits answered.
    acked_configure: u64 = 0,
    /// Layers with a blur shape.
    blurs: u32 = 0,

    animated: std.ArrayList(LayerId) = .empty,
    scrolled: std.ArrayList(LayerId) = .empty,
    finished: std.ArrayList(Finished) = .empty,
    /// Layers given up with `Op.exit`, and those destroyed since the
    /// last frame (reported in `Event.exited`).
    exiting: std.ArrayList(LayerId) = .empty,
    exited: std.ArrayList(LayerId) = .empty,
    /// Content replaced or removed since the last composition; the
    /// previous list may still point into it.
    retired: std.ArrayList(*scene.Builder) = .empty,
    /// Content released by the last `endFrame`.
    releasing: std.ArrayList(*scene.Builder) = .empty,

    lists: [2]std.ArrayList(Command) = .{ .empty, .empty },
    /// Index of the list composed last, if it is still valid.
    current: ?u1 = null,
    stack: std.ArrayList(Open) = .empty,

    const Open = struct { index: u32, bounds: Rect };

    pub fn init(gpa: Allocator) Tree {
        return .{ .gpa = gpa };
    }

    pub fn deinit(t: *Tree) void {
        t.layers.deinit(t.gpa);
        t.animated.deinit(t.gpa);
        t.scrolled.deinit(t.gpa);
        t.finished.deinit(t.gpa);
        t.exiting.deinit(t.gpa);
        t.exited.deinit(t.gpa);
        t.retired.deinit(t.gpa);
        t.releasing.deinit(t.gpa);
        for (&t.lists) |*l| l.deinit(t.gpa);
        t.stack.deinit(t.gpa);
        t.* = undefined;
    }

    pub fn get(t: *Tree, id: LayerId) ?*Layer {
        if (id == 0 or id >= t.layers.items.len) return null;
        const l = &t.layers.items[id];
        return if (l.alive) l else null;
    }

    /// Every builder the tree holds, for teardown. The tree must not be
    /// used afterwards except to deinit it.
    pub fn collectAll(t: *Tree, out: *std.ArrayList(*scene.Builder)) Allocator.Error!void {
        for (t.layers.items) |*l| if (l.alive) if (l.content) |c| {
            try out.append(t.gpa, c.builder);
            l.content = null;
        };
        try out.appendSlice(t.gpa, t.retired.items);
        t.retired.clearRetainingCapacity();
    }

    // Ops ---------------------------------------------------------------

    /// Applies one op. Returns false, after logging, for an op that does
    /// not fit the tree.
    pub fn apply(t: *Tree, op: Op) Allocator.Error!bool {
        switch (op) {
            .create => |id| {
                if (id & scroll_bit != 0) return t.reject(op, "id too large");
                if (t.get(id) != null) return t.reject(op, "layer exists");
                if (id >= t.layers.items.len) try t.layers.appendNTimes(t.gpa, .{}, id + 1 - t.layers.items.len);
                t.layers.items[id] = .{ .alive = true };
            },
            .destroy => |id| {
                const l = t.get(id) orelse return t.reject(op, "no such layer");
                if (l.parent != 0) t.unlink(id) else if (t.root == id) {
                    t.root = 0;
                }
                try t.destroyTree(id);
            },
            .set_root => |id| {
                if (id != 0) {
                    const l = t.get(id) orelse return t.reject(op, "no such layer");
                    if (l.parent != 0) return t.reject(op, "root has a parent");
                }
                t.root = id;
            },
            .insert => |ins| {
                const l = t.get(ins.layer) orelse return t.reject(op, "no such layer");
                _ = t.get(ins.parent) orelse return t.reject(op, "no such parent");
                if (ins.layer == t.root) return t.reject(op, "cannot insert the root");
                if (ins.before != 0) {
                    const b = t.get(ins.before) orelse return t.reject(op, "no such sibling");
                    if (b.parent != ins.parent) return t.reject(op, "sibling has another parent");
                }
                var a = ins.parent;
                while (a != 0) : (a = t.layers.items[a].parent) {
                    if (a == ins.layer) return t.reject(op, "cycle");
                }
                if (l.parent != 0) t.unlink(ins.layer);
                t.link(ins.layer, ins.parent, ins.before);
            },
            .detach => |id| {
                const l = t.get(id) orelse return t.reject(op, "no such layer");
                if (l.parent != 0) t.unlink(id);
            },
            .set_content => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                if (l.content) |old| {
                    const same = if (s.content) |c| c.builder == old.builder else false;
                    if (!same) try t.retired.append(t.gpa, old.builder);
                }
                l.content = s.content;
                if (s.damage) |d| {
                    l.damage = if (l.damage) |prev| prev.unite(d) else d;
                } else l.damage_all = true;
                l.version +%= 1;
            },
            .set_transform => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                l.anims[@intFromEnum(Property.transform)] = null;
                l.transform = s.transform;
            },
            .set_opacity => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                l.anims[@intFromEnum(Property.opacity)] = null;
                l.opacity = std.math.clamp(s.opacity, 0, 1);
            },
            .set_clip => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                l.clip = s.clip;
                l.damage_all = true;
                l.version +%= 1;
            },
            .set_scroll => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                l.scroll = s.scroll;
                if (s.scroll) |sc| {
                    l.zoom = sc.clampZoom(l.zoom);
                    try t.setOffset(s.layer, l.offset, false);
                } else {
                    l.offset = .zero;
                    l.zoom = 1;
                    l.fling = null;
                    l.anims[@intFromEnum(Property.scroll)] = null;
                }
                l.scroll_version +%= 1;
                l.damage_all = true;
                l.version +%= 1;
            },
            .scroll_to => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                if (l.scroll == null) return t.reject(op, "not a scroll container");
                t.stopScrolling(l);
                try t.setOffset(s.layer, s.offset, false);
            },
            .scroll_by => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                if (l.scroll == null) return t.reject(op, "not a scroll container");
                _ = try t.scrollBy(s.layer, s.delta);
            },
            .fling => |s| {
                if (!try t.startFling(s.layer, s.velocity)) return t.reject(op, "not a scroll container");
            },
            .zoom_to => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                if (l.scroll == null) return t.reject(op, "not a scroll container");
                t.stopScrolling(l);
                try t.zoomAt(s.layer, s.zoom, s.focus, false);
            },
            .zoom_by => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                if (l.scroll == null) return t.reject(op, "not a scroll container");
                t.stopScrolling(l);
                try t.zoomAt(s.layer, l.zoom * s.factor, s.focus, true);
            },
            .animate => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                const prop = std.meta.activeTag(s.animation.to);
                if (prop == .scroll) {
                    if (l.scroll == null) return t.reject(op, "not a scroll container");
                    l.fling = null;
                }
                var r: anim.Running = .init(s.animation);
                // A reveal continues from the one shown (D38).
                if (prop == .reveal and l.reveal != null) r.from = null;
                // A spring keeps the velocity of what it replaces.
                if (s.animation.easing == .spring and r.from == null) {
                    if (l.anims[@intFromEnum(prop)]) |old| r.velocity = old.velocityNow();
                }
                l.anims[@intFromEnum(prop)] = r;
                try t.markAnimated(s.layer);
            },
            .exit => |id| {
                const l = t.get(id) orelse return t.reject(op, "no such layer");
                if (l.exiting) return t.reject(op, "already given up");
                if (id == t.root) return t.reject(op, "cannot give up the root");
                l.exiting = true;
                try t.exiting.append(t.gpa, id);
            },
            .set_wheel_region => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                l.wheel = s.region;
            },
            .set_blur => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                if ((l.blur == null) != (s.shape == null)) {
                    if (s.shape == null) t.blurs -= 1 else t.blurs += 1;
                }
                l.blur = s.shape;
            },
            .set_background => |c| {
                if (!c.eql(t.background)) t.background_changed = true;
                t.background = c;
            },
            .set_external => |s| {
                const l = t.get(s.layer) orelse return t.reject(op, "no such layer");
                l.external = s.external;
                l.version +%= 1;
                l.damage_all = true;
            },
            .ack_configure => |serial| t.acked_configure = @max(t.acked_configure, serial),
        }
        return true;
    }

    fn reject(t: *Tree, op: Op, why: []const u8) bool {
        _ = t;
        log.warn("skipped {t} op: {s}", .{ op, why });
        return false;
    }

    fn destroyTree(t: *Tree, id: LayerId) Allocator.Error!void {
        var child = t.layers.items[id].first;
        while (child != 0) {
            const next = t.layers.items[child].next;
            try t.destroyTree(child);
            child = next;
        }
        const l = &t.layers.items[id];
        if (l.content) |c| try t.retired.append(t.gpa, c.builder);
        if (l.animated) removeId(&t.animated, id);
        if (l.scrolled) removeId(&t.scrolled, id);
        if (l.exiting) {
            removeId(&t.exiting, id);
            try t.exited.append(t.gpa, id);
        }
        if (l.blur != null) t.blurs -= 1;
        l.* = .{};
    }

    fn removeId(list: *std.ArrayList(LayerId), id: LayerId) void {
        if (std.mem.indexOfScalar(LayerId, list.items, id)) |i| _ = list.orderedRemove(i);
    }

    fn link(t: *Tree, id: LayerId, parent: LayerId, before: LayerId) void {
        const ls = t.layers.items;
        const p = &ls[parent];
        ls[id].parent = parent;
        if (before == 0) {
            ls[id].prev = p.last;
            ls[id].next = 0;
            if (p.last != 0) ls[p.last].next = id else p.first = id;
            p.last = id;
        } else {
            const prev = ls[before].prev;
            ls[id].prev = prev;
            ls[id].next = before;
            ls[before].prev = id;
            if (prev != 0) ls[prev].next = id else p.first = id;
        }
        // Paint order changed only around this layer: redrawing its old
        // and new bounds covers it. Added and removed layers need nothing;
        // damage tracking sees them appear and disappear.
        ls[id].version +%= 1;
        ls[id].damage_all = true;
    }

    fn unlink(t: *Tree, id: LayerId) void {
        const ls = t.layers.items;
        const l = &ls[id];
        const p = &ls[l.parent];
        if (l.prev != 0) ls[l.prev].next = l.next else p.first = l.next;
        if (l.next != 0) ls[l.next].prev = l.prev else p.last = l.prev;
        l.parent = 0;
        l.prev = 0;
        l.next = 0;
    }

    fn markAnimated(t: *Tree, id: LayerId) Allocator.Error!void {
        const l = &t.layers.items[id];
        if (l.animated) return;
        try t.animated.append(t.gpa, id);
        l.animated = true;
    }

    // Scrolling ---------------------------------------------------------

    fn maxOffset(s: update.Scroll, zoom: f32) Point {
        return .{
            .x = @max(0, s.content.width * zoom - s.viewport.width()),
            .y = @max(0, s.content.height * zoom - s.viewport.height()),
        };
    }

    fn clampOffset(s: update.Scroll, zoom: f32, p: Point) Point {
        const m = maxOffset(s, zoom);
        return .{ .x = std.math.clamp(p.x, 0, m.x), .y = std.math.clamp(p.y, 0, m.y) };
    }

    /// Sets a clamped offset; `report` queues an `Event.scrolled`.
    fn setOffset(t: *Tree, id: LayerId, p: Point, report: bool) Allocator.Error!void {
        const l = &t.layers.items[id];
        const c = clampOffset(l.scroll.?, l.zoom, p);
        if (c.eql(l.offset)) return;
        l.offset = c;
        l.scroll_version +%= 1;
        if (report) try t.markScrolled(id);
    }

    fn markScrolled(t: *Tree, id: LayerId) Allocator.Error!void {
        const l = &t.layers.items[id];
        if (l.scrolled) return;
        try t.scrolled.append(t.gpa, id);
        l.scrolled = true;
    }

    /// Zooms a scroll container to `zoom` (clamped to its range), keeping
    /// `focus` (layer coordinates) over the same content point.
    pub fn zoomAt(t: *Tree, id: LayerId, zoom: f32, focus: Point, report: bool) Allocator.Error!void {
        const l = &t.layers.items[id];
        const s = l.scroll orelse return;
        const z = s.clampZoom(zoom);
        if (z == l.zoom) return;
        const o: Point = .{ .x = s.viewport.x0, .y = s.viewport.y0 };
        const k = z / l.zoom;
        const off: Point = .{
            .x = k * (focus.x - o.x + l.offset.x) - (focus.x - o.x),
            .y = k * (focus.y - o.y + l.offset.y) - (focus.y - o.y),
        };
        l.zoom = z;
        l.scroll_version +%= 1;
        l.offset = clampOffset(s, z, off);
        if (report) try t.markScrolled(id);
    }

    /// Stops every fling in the tree: fingers came to rest on a touchpad
    /// (a hold gesture).
    pub fn stopFlings(t: *Tree) void {
        for (t.animated.items) |id| t.layers.items[id].fling = null;
    }

    /// A window point in a layer's coordinates, through every transform
    /// and scroll container above it; null if a transform is singular.
    pub fn toLayer(t: *Tree, id: LayerId, p: Point) ?Point {
        var m: Affine = .identity;
        var cur = id;
        while (cur != 0) {
            const l = &t.layers.items[cur];
            m = m.then(l.transform.affine());
            if (l.parent != 0) m = m.then(childMap(&t.layers.items[l.parent]));
            cur = l.parent;
        }
        const inv = m.invert() orelse return null;
        return inv.apply(p);
    }

    /// Stops a container's fling and scroll animation, as input does.
    pub fn stopLayer(t: *Tree, id: LayerId) void {
        if (t.get(id)) |l| t.stopScrolling(l);
    }

    fn stopScrolling(t: *Tree, l: *Layer) void {
        _ = t;
        l.fling = null;
        l.anims[@intFromEnum(Property.scroll)] = null;
    }

    /// Scrolls by input. Returns whether the offset moved.
    pub fn scrollBy(t: *Tree, id: LayerId, delta: Point) Allocator.Error!bool {
        const l = t.get(id) orelse return false;
        if (l.scroll == null) return false;
        t.stopScrolling(l);
        return t.pan(id, delta);
    }

    /// Moves the offset by `delta` without stopping flings or animations.
    pub fn pan(t: *Tree, id: LayerId, delta: Point) Allocator.Error!bool {
        const l = t.get(id) orelse return false;
        if (l.scroll == null) return false;
        const before = l.offset;
        try t.setOffset(id, before.add(delta), true);
        return !t.layers.items[id].offset.eql(before);
    }

    pub fn startFling(t: *Tree, id: LayerId, velocity: Point) Allocator.Error!bool {
        const l = t.get(id) orelse return false;
        if (l.scroll == null) return false;
        l.anims[@intFromEnum(Property.scroll)] = null;
        l.fling = .{ .start = l.offset, .velocity = velocity };
        try t.markAnimated(id);
        return true;
    }

    /// Where a pointer scroll by `delta` at `p` (window coordinates) goes,
    /// with modifiers `mods` held (see `update.Scroll` for the rules).
    pub fn routeScroll(t: *Tree, p: Point, delta: Point, mods: platform.Mods) Route {
        if (mods.ctrl or mods.alt or mods.super) return .ui;
        return t.route(p, delta);
    }

    /// Where a touchpad pinch at `p` goes: by the rules of `routeScroll`,
    /// with zoomable containers in place of those that can scroll.
    pub fn routePinch(t: *Tree, p: Point, mods: platform.Mods) Route {
        if (mods.ctrl or mods.alt or mods.super) return .ui;
        return t.routeFor(p, .zoom);
    }

    /// What a container must be able to do to take an input.
    pub const Want = union(enum) {
        /// Scroll by this delta.
        wheel: Point,
        /// Zoom.
        zoom,
    };

    /// The modifier-free part of `routeScroll`.
    pub fn route(t: *Tree, p: Point, delta: Point) Route {
        return t.routeFor(p, .{ .wheel = delta });
    }

    fn routeFor(t: *Tree, p: Point, want: Want) Route {
        if (t.root == 0) return .ui;
        return switch (t.routeLayer(t.root, p, want)) {
            .miss, .pending => .ui,
            .ui => .ui,
            .scroll => |id| .{ .scroll = id },
        };
    }

    const Hit = union(enum) { miss, pending, ui, scroll: LayerId };

    fn routeLayer(t: *Tree, id: LayerId, parent_p: Point, want: Want) Hit {
        const l = &t.layers.items[id];
        if (l.exiting) return .miss;
        const inv = l.transform.affine().invert() orelse return .miss;
        const p = inv.apply(parent_p);
        if (l.clip) |c| if (!contains(c.rect, p)) return .miss;
        if (l.reveal) |c| if (!contains(c.rect, p)) return .miss;
        var hit: Hit = .miss;
        const in_viewport = if (l.scroll) |s| contains(s.viewport, p) else true;
        if (in_viewport) {
            const cp = childPoint(l, p);
            var child = l.last;
            while (child != 0) : (child = t.layers.items[child].prev) {
                hit = t.routeLayer(child, cp, want);
                if (hit != .miss) break;
            }
        }
        const wheel = if (l.wheel) |w| contains(w, p) else false;
        if (hit == .miss) {
            // A scroll container is hit anywhere in its viewport.
            const on_content = if (l.content) |c| contains(c.list.bounds, p) else false;
            if (!on_content and !wheel and !(l.scroll != null and in_viewport)) return .miss;
            hit = .pending;
        }
        if (hit != .pending) return hit;
        if (wheel) return .ui;
        if (l.scroll) |s| if (s.input and in_viewport) switch (want) {
            .wheel => |delta| if (canMove(s, l.zoom, l.offset, delta)) return .{ .scroll = id },
            .zoom => if (s.zoomable()) return .{ .scroll = id },
        };
        return .pending;
    }

    fn canMove(s: update.Scroll, zoom: f32, offset: Point, d: Point) bool {
        const m = maxOffset(s, zoom);
        return (d.x > 0 and offset.x < m.x) or (d.x < 0 and offset.x > 0) or
            (d.y > 0 and offset.y < m.y) or (d.y < 0 and offset.y > 0);
    }

    fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x0 and p.x < r.x1 and p.y >= r.y0 and p.y < r.y1;
    }

    // Animation ---------------------------------------------------------

    pub const Tick = struct {
        /// Some animation shows motion at this time: keep rendering.
        active: bool,
        /// Earliest start of an animation that has not started yet.
        next_start_ns: ?u64,
        /// A single-run animation (started or waiting to) or a fling is
        /// left: it ends, so its frames are owed (`Compositor.owesFrames`).
        holding: bool = false,
    };

    /// Samples every animation at `t_ns`, the frame's predicted
    /// presentation time. Finished animations go to `finished`.
    pub fn tick(t: *Tree, t_ns: u64) Allocator.Error!Tick {
        var result: Tick = .{ .active = false, .next_start_ns = null };
        var i: usize = 0;
        while (i < t.animated.items.len) {
            const id = t.animated.items[i];
            const l = &t.layers.items[id];
            inline for (comptime std.enums.values(Property)) |prop| {
                if (l.anims[@intFromEnum(prop)]) |*r| {
                    const current: Value = switch (prop) {
                        .transform => .{ .transform = l.transform },
                        .opacity => .{ .opacity = l.opacity },
                        .scroll => .{ .scroll = l.offset },
                        .reveal => .{ .reveal = l.reveal orelse r.anim.to.reveal },
                    };
                    const s = r.sample(t_ns, current);
                    switch (prop) {
                        .transform => l.transform = s.value.transform,
                        .opacity => l.opacity = std.math.clamp(s.value.opacity, 0, 1),
                        .scroll => try t.setOffset(id, s.value.scroll, true),
                        .reveal => if (t_ns >= r.start_ns) {
                            // A changed clip is a content change (D9).
                            l.reveal = if (s.done) null else s.value.reveal;
                            l.version +%= 1;
                            l.damage_all = true;
                        },
                    }
                    if (s.done) {
                        try t.finished.append(t.gpa, .{ .layer = id, .id = r.anim.id, .property = prop });
                        l.anims[@intFromEnum(prop)] = null;
                    } else {
                        if (r.anim.iterations == 1) result.holding = true;
                        if (t_ns < r.start_ns) {
                            result.next_start_ns = @min(result.next_start_ns orelse r.start_ns, r.start_ns);
                        } else result.active = true;
                    }
                }
            }
            if (l.fling) |*f| {
                const s = f.sample(t_ns);
                const before = l.offset;
                try t.setOffset(id, s.offset, true);
                // Stops at rest or once it runs into the edge.
                const stuck = l.offset.eql(before) and f.start_ns != t_ns;
                if (s.done or stuck) l.fling = null else {
                    result.active = true;
                    result.holding = true;
                }
            }
            if (l.animating()) {
                i += 1;
            } else {
                l.animated = false;
                _ = t.animated.swapRemove(i);
            }
        }
        // Layers given up go once nothing given up in them still moves.
        var k = t.exiting.items.len;
        while (k > 0) {
            k -= 1;
            if (k >= t.exiting.items.len) continue;
            const id = t.exiting.items[k];
            const l = &t.layers.items[id];
            if (l.parent != 0 and t.layers.items[l.parent].exiting) continue;
            if (l.parent != 0 and t.exitPending(id)) {
                result.holding = true;
                continue;
            }
            if (l.parent != 0) t.unlink(id);
            try t.destroyTree(id);
        }
        return result;
    }

    /// Whether a layer given up, or one given up inside it, runs an
    /// animation that ends.
    fn exitPending(t: *const Tree, id: LayerId) bool {
        const l = &t.layers.items[id];
        if (l.exiting and l.ending()) return true;
        var child = l.first;
        while (child != 0) : (child = t.layers.items[child].next) {
            if (t.exitPending(child)) return true;
        }
        return false;
    }

    // Composition -------------------------------------------------------

    /// The list composed by the last frame, while the content it points
    /// into is alive.
    pub fn previous(t: *const Tree) ?scene.DisplayList {
        const c = t.current orelse return null;
        return .{ .commands = t.lists[c].items, .version = 0 };
    }

    /// Marks the layers showing external `id` changed (a new frame, or
    /// promotion changed how it is drawn): `part` of the frame, as
    /// fractions of its width and height, or all of it when null.
    pub fn touchExternal(t: *Tree, id: update.ExternalId, part: ?Rect) void {
        for (t.layers.items) |*l| if (l.alive) if (l.external) |pl| if (pl.id == id) {
            l.version +%= 1;
            const p = part orelse {
                l.damage_all = true;
                continue;
            };
            if (p.isEmpty()) continue;
            const r = pl.rect;
            const d: Rect = .{ .x0 = r.x0 + p.x0 * r.width(), .y0 = r.y0 + p.y0 * r.height(), .x1 = r.x0 + p.x1 * r.width(), .y1 = r.y0 + p.y1 * r.height() };
            l.damage = if (l.damage) |prev| prev.unite(d) else d;
        };
    }

    /// The externals in the tree, in paint order, with where they are and
    /// whether a subsurface could show them.
    /// `bounds` is the window (surface coordinates): nothing shows outside
    /// it, so it clips every placement.
    pub fn externalPlacements(t: *Tree, out: *std.ArrayList(Found), bounds: Rect) Allocator.Error!void {
        out.clearRetainingCapacity();
        if (t.root == 0) return;
        try t.place(out, t.root, .identity, 1, bounds, false);
    }

    /// Something painted at `r` (surface coordinates) covers the externals
    /// placed before it.
    fn occlude(out: []Found, r: Rect) void {
        if (r.isEmpty()) return;
        for (out) |*f| if (!f.visible.intersect(r).isEmpty() or !f.box.intersect(r).isEmpty()) {
            f.covered = true;
        };
    }

    fn place(t: *Tree, out: *std.ArrayList(Found), id: LayerId, parent: Affine, parent_opacity: f32, parent_clip: Rect, parent_round: bool) Allocator.Error!void {
        const l = &t.layers.items[id];
        const m = l.transform.affine().then(parent);
        const opacity = parent_opacity * l.opacity;
        var clip = parent_clip;
        var round = parent_round;
        for ([_]?update.Clip{ l.clip, l.reveal }) |lc| if (lc) |c| {
            clip = clip.intersect(m.applyRect(c.rect));
            round = round or !c.radii.eql(.{}) or !m.isAxisAligned();
        };
        if (l.content) |c| occlude(out.items, m.applyRect(c.list.bounds).intersect(clip));
        if (l.external) |pl| {
            const r = m.applyRect(pl.rect);
            const visible = r.intersect(clip);
            const box = if (pl.background.a > 0) m.applyRect(pl.box).intersect(clip) else Rect.empty;
            occlude(out.items, visible);
            occlude(out.items, box);
            const shown = !visible.isEmpty() and r.width() > 0 and r.height() > 0;
            try out.append(t.gpa, .{
                .id = pl.id,
                .layer = id,
                .rect = r,
                .visible = if (shown) visible else Rect.empty,
                .source = if (shown) .{
                    .x0 = (visible.x0 - r.x0) / r.width(),
                    .y0 = (visible.y0 - r.y0) / r.height(),
                    .x1 = (visible.x1 - r.x0) / r.width(),
                    .y1 = (visible.y1 - r.y0) / r.height(),
                } else Rect.empty,
                // Rectangular clips crop through the viewport; rounded or
                // rotated ones would cut it: composite instead.
                .promotable = m.b == 0 and m.c == 0 and m.a > 0 and m.d > 0 and shown and !round,
                .covered = false,
                .opacity = opacity,
                .background = if (box.isEmpty()) .transparent else pl.background,
                .box = if (box.isEmpty()) Rect.empty else box,
                .content = if (pl.box.isEmpty()) r else m.applyRect(pl.box),
            });
        }
        var cm = m;
        var child_clip = clip;
        if (l.scroll) |s| {
            child_clip = clip.intersect(m.applyRect(s.viewport));
            cm = childMap(l).then(m);
        }
        var child = l.first;
        while (child != 0) : (child = t.layers.items[child].next) try t.place(out, child, cm, opacity, child_clip, round);
    }

    /// The window's blur region (D31) as the tree shows it now: every
    /// shown layer's blur shape through its transforms, scroll offsets,
    /// and zoom, clipped by its clips and `bounds`, in whole surface
    /// pixels. Rounded corners become a stack of rectangles inside the
    /// curve; a rotated or skewed shape becomes its bounding box, and
    /// rounded clips are taken as their rectangles. Layers that are fully
    /// transparent blur nothing.
    pub fn blurRegion(t: *Tree, out: *std.ArrayList(platform.Rect), bounds: Rect) Allocator.Error!void {
        out.clearRetainingCapacity();
        if (t.root == 0 or t.blurs == 0) return;
        try t.blurFrom(out, t.root, .identity, 1, bounds);
    }

    fn blurFrom(t: *Tree, out: *std.ArrayList(platform.Rect), id: LayerId, parent: Affine, parent_opacity: f32, parent_clip: Rect) Allocator.Error!void {
        const l = &t.layers.items[id];
        const m = l.transform.affine().then(parent);
        const opacity = parent_opacity * l.opacity;
        if (opacity <= 0) return;
        var clip = parent_clip;
        if (l.clip) |c| clip = clip.intersect(m.applyRect(c.rect));
        if (l.reveal) |c| clip = clip.intersect(m.applyRect(c.rect));
        if (clip.isEmpty()) return;
        if (l.blur) |b| try blurShape(t.gpa, out, b, m, clip);
        var cm = m;
        var child_clip = clip;
        if (l.scroll) |s| {
            child_clip = clip.intersect(m.applyRect(s.viewport));
            cm = childMap(l).then(m);
        }
        var child = l.first;
        while (child != 0) : (child = t.layers.items[child].next) try t.blurFrom(out, child, cm, opacity, child_clip);
    }

    /// Composes the tree into a display list in window coordinates. Valid
    /// until the next call.
    pub fn compose(t: *Tree) Allocator.Error!scene.DisplayList {
        const index: u1 = if (t.current) |c| ~c else 0;
        const out = &t.lists[index];
        out.clearRetainingCapacity();
        t.stack.clearRetainingCapacity();
        try t.stack.append(t.gpa, .{ .index = 0, .bounds = Rect.empty });
        if (t.root != 0) try t.emit(out, t.root);
        const bounds = t.stack.items[0].bounds;
        // Damage is baked into this list; start collecting anew.
        for (t.layers.items) |*l| {
            l.damage = null;
            l.damage_all = false;
        }
        return .{ .commands = out.items, .version = 0, .bounds = bounds };
    }

    /// Finishes a frame after damage tracking: the list just composed
    /// becomes `previous`, and content retired before it is released into
    /// `releasing`.
    pub fn endFrame(t: *Tree) []const *scene.Builder {
        t.current = if (t.current) |c| ~c else 0;
        t.background_changed = false;
        t.releasing.clearRetainingCapacity();
        std.mem.swap(std.ArrayList(*scene.Builder), &t.releasing, &t.retired);
        return t.releasing.items;
    }

    /// Releases retired content without a frame if too much piled up
    /// (the window stopped rendering), forgetting the previous list.
    pub fn trimRetired(t: *Tree) []const *scene.Builder {
        if (t.retired.items.len <= max_retired) return &.{};
        t.current = null;
        t.releasing.clearRetainingCapacity();
        std.mem.swap(std.ArrayList(*scene.Builder), &t.releasing, &t.retired);
        return t.releasing.items;
    }

    fn emit(t: *Tree, out: *std.ArrayList(Command), id: LayerId) Allocator.Error!void {
        const l = &t.layers.items[id];
        // A reveal inside the layer's own clip is a second, anonymous
        // layer; its changes bump the layer's version.
        const own = l.clip orelse l.reveal;
        const inner = if (l.clip != null) l.reveal else null;
        const clip: ?scene.Clip = if (own) |c| .{ .shape = clipShape(c.rect, c.radii) } else null;
        try t.push(out, .{
            .id = id,
            .version = l.version,
            .transform = l.transform.affine(),
            .opacity = l.opacity,
            .clip = clip,
            .damage = if (l.damage_all) null else l.damage orelse Rect.empty,
        });
        if (inner) |c| try t.push(out, .{ .clip = .{ .shape = clipShape(c.rect, c.radii) } });
        if (l.content) |c| {
            const base: u32 = @intCast(out.items.len);
            try out.ensureUnusedCapacity(t.gpa, c.list.commands.len);
            for (c.list.commands) |cmd| {
                var copy = cmd;
                if (copy == .push) {
                    copy.push.end += base;
                    copy.push.layer.id = 0;
                }
                out.appendAssumeCapacity(copy);
            }
            t.include(c.list.bounds);
        }
        if (l.external) |pl| if (t.externals) |ext| {
            const d = ext.draw(ext.ctx, pl.id);
            if (!d.solid and pl.background.a > 0 and !pl.box.isEmpty()) {
                const b = pl.box;
                const r = pl.rect;
                const bands: [4]Rect = if (!d.promoted) .{ b, Rect.empty, Rect.empty, Rect.empty } else .{
                    .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = @min(r.y0, b.y1) },
                    .{ .x0 = b.x0, .y0 = @max(r.y1, b.y0), .x1 = b.x1, .y1 = b.y1 },
                    .{ .x0 = b.x0, .y0 = @max(r.y0, b.y0), .x1 = @min(r.x0, b.x1), .y1 = @min(r.y1, b.y1) },
                    .{ .x0 = @max(r.x1, b.x0), .y0 = @max(r.y0, b.y0), .x1 = b.x1, .y1 = @min(r.y1, b.y1) },
                };
                for (bands) |band| if (!band.isEmpty()) {
                    try out.append(t.gpa, .{ .fill = .{ .shape = .{ .rect = band }, .paint = .color(pl.background) } });
                    t.include(band);
                };
            }
            try t.emitExternal(out, pl, d);
        };
        if (l.scroll) |s| {
            try t.push(out, .{
                .id = id | scroll_bit,
                .version = l.scroll_version,
                .clip = .{ .shape = .{ .rect = s.viewport } },
            });
            try t.push(out, .{ .transform = childMap(l) });
        }
        var child = l.first;
        while (child != 0) : (child = t.layers.items[child].next) try t.emit(out, child);
        if (l.scroll != null) {
            try t.pop(out);
            try t.pop(out);
        }
        if (inner != null) try t.pop(out);
        try t.pop(out);
    }

    fn emitExternal(t: *Tree, out: *std.ArrayList(Command), pl: update.ExternalPlacement, d: Draw) Allocator.Error!void {
        switch (d.what) {
            .none => {},
            .image => |img| {
                try out.append(t.gpa, .{ .image = .{
                    .image = img,
                    .src = .xywh(0, 0, @floatFromInt(img.width), @floatFromInt(img.height)),
                    .dst = pl.rect,
                } });
                t.include(pl.rect);
            },
            // Enclosing clips limit the hole to the visible part; it
            // covers the background's box too when a subsurface shows it.
            .hole => {
                const r = if (d.solid and pl.background.a > 0) pl.rect.unite(pl.box) else pl.rect;
                try t.push(out, .{ .blend = .src, .clip = .{ .shape = .{ .rect = r } } });
                try out.append(t.gpa, .{ .fill = .{ .shape = .{ .rect = r }, .paint = .color(.transparent) } });
                t.include(r);
                try t.pop(out);
            },
        }
    }

    fn push(t: *Tree, out: *std.ArrayList(Command), layer: scene.Layer) Allocator.Error!void {
        try t.stack.append(t.gpa, .{ .index = @intCast(out.items.len), .bounds = Rect.empty });
        try out.append(t.gpa, .{ .push = .{ .layer = layer, .end = 0, .bounds = Rect.empty } });
    }

    fn pop(t: *Tree, out: *std.ArrayList(Command)) Allocator.Error!void {
        const open = t.stack.pop().?;
        try out.append(t.gpa, .pop);
        const p = &out.items[open.index].push;
        p.end = @intCast(out.items.len - 1);
        var bounds = open.bounds;
        if (p.layer.clip) |c| bounds = bounds.intersect(c.shape.bounds());
        if (bounds.isEmpty()) bounds = Rect.empty;
        p.bounds = bounds;
        t.include(p.layer.transform.applyRect(bounds));
    }

    fn include(t: *Tree, r: Rect) void {
        if (r.isEmpty()) return;
        const top = &t.stack.items[t.stack.items.len - 1];
        top.bounds = top.bounds.unite(r);
    }
};

/// Strips per rounded corner in a blur region: enough that the steps stay
/// within about a pixel for radii up to 16, few enough that a region
/// stays small.
const corner_strips = 6;

/// Appends a blur shape's rectangles in surface pixels, rounded inward.
fn blurShape(gpa: Allocator, out: *std.ArrayList(platform.Rect), b: update.BlurShape, m: Affine, clip: Rect) Allocator.Error!void {
    const r = m.applyRect(b.rect);
    const axis_aligned = m.b == 0 and m.c == 0;
    if (!axis_aligned or b.radii.eql(.{})) return appendRect(gpa, out, r, clip);
    // Radii scale with the transform; m.a and m.d may be negative (a flip).
    const sx = @abs(m.a);
    const sy = @abs(m.d);
    const w = r.width();
    const h = r.height();
    // Each corner's radii, clamped to half the box like a renderer does.
    const corner = struct {
        fn f(rad: raster.Point, sx_: f32, sy_: f32, w_: f32, h_: f32) raster.Point {
            return .{ .x = @min(rad.x * sx_, w_ / 2), .y = @min(rad.y * sy_, h_ / 2) };
        }
    }.f;
    const tl = corner(b.radii.tl, sx, sy, w, h);
    const tr = corner(b.radii.tr, sx, sy, w, h);
    const bl = corner(b.radii.bl, sx, sy, w, h);
    const br = corner(b.radii.br, sx, sy, w, h);
    const top = @max(tl.y, tr.y);
    const bottom = @max(bl.y, br.y);
    // The middle band spans the full width.
    try appendRect(gpa, out, .{ .x0 = r.x0, .y0 = r.y0 + top, .x1 = r.x1, .y1 = r.y1 - bottom }, clip);
    // Bands from the edge inward: each is inset by the curve at its outer
    // edge, where the inset is largest, so the rectangles stay inside.
    var i: u32 = 0;
    while (i < corner_strips) : (i += 1) {
        const f0: f32 = @as(f32, @floatFromInt(i)) / corner_strips;
        const f1: f32 = @as(f32, @floatFromInt(i + 1)) / corner_strips;
        try appendRect(gpa, out, .{
            .x0 = r.x0 + inset(tl, top, f0),
            .y0 = r.y0 + top * f0,
            .x1 = r.x1 - inset(tr, top, f0),
            .y1 = r.y0 + top * f1,
        }, clip);
        try appendRect(gpa, out, .{
            .x0 = r.x0 + inset(bl, bottom, f0),
            .y0 = r.y1 - bottom * f1,
            .x1 = r.x1 - inset(br, bottom, f0),
            .y1 = r.y1 - bottom * f0,
        }, clip);
    }
}

/// How far an elliptical corner of radii `c` cuts into a horizontal band
/// at `frac` of `band` from the edge (0 at the edge).
fn inset(c: raster.Point, band: f32, frac: f32) f32 {
    if (c.x <= 0 or c.y <= 0) return 0;
    // Distance from the corner's center line, in the corner's own height.
    const y = band * frac;
    if (y >= c.y) return 0;
    const dy = (c.y - y) / c.y;
    return c.x * (1 - @sqrt(@max(0, 1 - dy * dy)));
}

fn appendRect(gpa: Allocator, out: *std.ArrayList(platform.Rect), r: Rect, clip: Rect) Allocator.Error!void {
    const v = r.intersect(clip);
    if (v.isEmpty()) return;
    const x0: i32 = @intFromFloat(@ceil(v.x0));
    const y0: i32 = @intFromFloat(@ceil(v.y0));
    const x1: i32 = @intFromFloat(@floor(v.x1));
    const y1: i32 = @intFromFloat(@floor(v.y1));
    if (x1 <= x0 or y1 <= y0) return;
    try out.append(gpa, .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 });
}

fn clipShape(r: Rect, radii: raster.Radii) scene.Shape {
    if (radii.eql(.{})) return .{ .rect = r };
    return .{ .rounded_rect = .{ .rect = r, .radii = radii.fit(r) } };
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const IRect = raster.IRect;

const Fixture = struct {
    tree: Tree,
    builders: [8]scene.Builder,
    tracker: scene.damage.Tracker,

    fn init(f: *Fixture) void {
        f.tree = .init(testing.allocator);
        for (&f.builders) |*b| b.* = .init(testing.allocator);
        f.tracker = .init(testing.allocator);
    }

    fn deinit(f: *Fixture) void {
        f.tree.deinit();
        for (&f.builders) |*b| b.deinit();
        f.tracker.deinit();
    }

    /// Content filling `r` in builder `i`.
    fn rect(f: *Fixture, i: usize, r: Rect) !update.Content {
        const b = &f.builders[i];
        b.reset();
        try b.fillRect(r, .color(.black));
        return .{ .list = try b.finish(0), .builder = b };
    }

    fn apply(f: *Fixture, ops: []const Op) !void {
        for (ops) |op| try testing.expect(try f.tree.apply(op));
    }

    /// Composes a frame and returns its damage in a 200x200 viewport.
    fn frame(f: *Fixture) ![]const IRect {
        const list = try f.tree.compose();
        const d = try f.tracker.diff(f.tree.previous(), list, .identity, .xywh(0, 0, 200, 200));
        _ = f.tree.endFrame();
        return d;
    }
};

test "ops build a tree that composes into nested scene layers" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.apply(&.{
        .{ .create = 1 },
        .{ .create = 2 },
        .{ .create = 3 },
        .{ .set_root = 1 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .insert = .{ .layer = 3, .parent = 1, .before = 2 } },
        .{ .set_content = .{ .layer = 2, .content = try f.rect(0, .xywh(0, 0, 10, 10)) } },
        .{ .set_transform = .{ .layer = 2, .transform = .offset(50, 60) } },
    });
    const list = try f.tree.compose();
    // push 1, push 3, pop, push 2, fill, pop, pop: 3 paints below 2.
    try testing.expectEqual(@as(usize, 7), list.commands.len);
    try testing.expectEqual(@as(u32, 3), list.commands[1].push.layer.id);
    try testing.expectEqual(@as(u32, 2), list.commands[3].push.layer.id);
    try testing.expectEqual(@as(u32, 6), list.commands[0].push.end);
    try testing.expectEqual(Rect.xywh(50, 60, 10, 10), list.bounds);

}

test "damage follows layer changes across frames" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.apply(&.{
        .{ .create = 1 },
        .{ .create = 2 },
        .{ .set_root = 1 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .set_content = .{ .layer = 1, .content = try f.rect(0, .xywh(0, 0, 200, 200)) } },
        .{ .set_content = .{ .layer = 2, .content = try f.rect(1, .xywh(0, 0, 10, 10)) } },
    });
    try testing.expectEqualSlices(IRect, &.{.xywh(0, 0, 200, 200)}, try f.frame());
    try testing.expectEqual(@as(usize, 0), (try f.frame()).len);

    // Moving a layer damages where it was and where it is.
    try f.apply(&.{.{ .set_transform = .{ .layer = 2, .transform = .offset(100, 100) } }});
    const moved = try f.frame();
    try testing.expectEqual(@as(usize, 2), moved.len);

    // New content with declared damage damages only that.
    try f.apply(&.{.{ .set_content = .{ .layer = 2, .content = try f.rect(2, .xywh(0, 0, 10, 10)), .damage = .xywh(0, 0, 5, 5) } }});
    try testing.expectEqualSlices(IRect, &.{.xywh(100, 100, 5, 5)}, try f.frame());
    // The replaced builder comes back after the first frame without it,
    // whose damage tracking read the list that still used it.
    try testing.expectEqualSlices(*scene.Builder, &.{&f.builders[1]}, f.tree.releasing.items);
    try f.apply(&.{.{ .destroy = 2 }});
    try testing.expectEqualSlices(IRect, &.{.xywh(100, 100, 10, 10)}, try f.frame());
    try testing.expectEqual(@as(usize, 1), f.tree.releasing.items.len);
    try testing.expectEqual(&f.builders[2], f.tree.releasing.items[0]);
}

test "rejected ops leave the tree unchanged" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.apply(&.{ .{ .create = 1 }, .{ .create = 2 }, .{ .insert = .{ .layer = 2, .parent = 1 } }, .{ .set_root = 1 } });
    const bad = [_]Op{
        .{ .insert = .{ .layer = 1, .parent = 2 } }, // the root, and a cycle
        .{ .create = 2 },
        .{ .destroy = 9 },
        .{ .insert = .{ .layer = 9, .parent = 1 } },
        .{ .scroll_to = .{ .layer = 2, .offset = .zero } }, // not a scroll container
    };
    const level = testing.log_level;
    testing.log_level = .err; // the warnings are expected
    defer testing.log_level = level;
    for (bad) |op| try testing.expect(!try f.tree.apply(op));
    const list = try f.tree.compose();
    try testing.expectEqual(@as(usize, 4), list.commands.len);
    try testing.expectEqual(@as(u32, 2), list.commands[1].push.layer.id);
}

test "scroll containers clamp, report, and route input" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.apply(&.{
        .{ .create = 1 },
        .{ .create = 2 },
        .{ .create = 3 },
        .{ .set_root = 1 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .insert = .{ .layer = 3, .parent = 2 } },
        .{ .set_scroll = .{ .layer = 2, .scroll = .{ .viewport = .xywh(0, 0, 100, 100), .content = .{ .width = 100, .height = 300 } } } },
        .{ .set_content = .{ .layer = 3, .content = try f.rect(0, .xywh(0, 0, 100, 300)) } },
        .{ .set_content = .{ .layer = 1, .content = try f.rect(1, .xywh(0, 0, 200, 200)) } },
    });
    // Inside the viewport, scrolling down goes to the container; up cannot
    // move, so it goes to the UI; outside the viewport, too.
    try testing.expectEqual(Route{ .scroll = 2 }, f.tree.route(.{ .x = 50, .y = 50 }, .{ .x = 0, .y = 10 }));
    try testing.expectEqual(Route.ui, f.tree.route(.{ .x = 50, .y = 50 }, .{ .x = 0, .y = -10 }));
    try testing.expectEqual(Route.ui, f.tree.route(.{ .x = 150, .y = 50 }, .{ .x = 0, .y = 10 }));

    try testing.expect(try f.tree.scrollBy(2, .{ .x = 0, .y = 500 }));
    try testing.expectEqual(@as(f32, 200), f.tree.get(2).?.offset.y); // clamped
    try testing.expectEqualSlices(LayerId, &.{2}, f.tree.scrolled.items);
    try testing.expect(!try f.tree.scrollBy(2, .{ .x = 0, .y = 1 }));

    // The children move by the offset: push 1, fill, push 2, the viewport
    // wrapper, then the translation.
    const list = try f.tree.compose();
    try testing.expectEqual(@as(u32, 2 | scroll_bit), list.commands[3].push.layer.id);
    try testing.expectEqual(@as(f32, -200), list.commands[4].push.layer.transform.f);

    // A wheel region nearer than the container takes the event.
    try f.apply(&.{.{ .set_wheel_region = .{ .layer = 3, .region = .xywh(0, 200, 100, 50) } }});
    try testing.expectEqual(Route.ui, f.tree.route(.{ .x = 50, .y = 10 }, .{ .x = 0, .y = -10 }));
    try testing.expectEqual(Route{ .scroll = 2 }, f.tree.route(.{ .x = 50, .y = 60 }, .{ .x = 0, .y = -10 }));
}

test "a scroll container's viewport takes scroll input where nothing is drawn" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    // A 100x100 viewport whose only child draws a 20 px strip at its top;
    // the rest of the viewport is transparent, as is the root.
    try f.apply(&.{
        .{ .create = 1 },
        .{ .create = 2 },
        .{ .create = 3 },
        .{ .set_root = 1 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .insert = .{ .layer = 3, .parent = 2 } },
        .{ .set_transform = .{ .layer = 2, .transform = .offset(50, 50) } },
        .{ .set_scroll = .{ .layer = 2, .scroll = .{ .viewport = .xywh(0, 0, 100, 100), .content = .{ .width = 100, .height = 500 } } } },
        .{ .set_content = .{ .layer = 3, .content = try f.rect(0, .xywh(0, 0, 100, 20)) } },
    });
    const down: Point = .{ .x = 0, .y = 10 };
    try testing.expectEqual(Route{ .scroll = 2 }, f.tree.route(.{ .x = 100, .y = 120 }, down));
    try testing.expectEqual(Route{ .scroll = 2 }, f.tree.route(.{ .x = 149, .y = 149 }, down));
    // Outside the viewport, and with ctrl held, the UI gets it.
    try testing.expectEqual(Route.ui, f.tree.route(.{ .x = 100, .y = 151 }, down));
    try testing.expectEqual(Route.ui, f.tree.routeScroll(.{ .x = 100, .y = 120 }, down, .{ .ctrl = true }));
    try testing.expectEqual(Route{ .scroll = 2 }, f.tree.routeScroll(.{ .x = 100, .y = 120 }, down, .{ .shift = true }));
}

test "pinches route like scrolling to zoomable containers, which zoom about the fingers" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    // A zoomable container at (50, 50) whose viewport starts at (10, 10) in
    // its own coordinates, and a plain one beside it.
    try f.apply(&.{
        .{ .create = 1 },
        .{ .create = 2 },
        .{ .create = 3 },
        .{ .create = 4 },
        .{ .set_root = 1 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .insert = .{ .layer = 3, .parent = 2 } },
        .{ .insert = .{ .layer = 4, .parent = 1 } },
        .{ .set_transform = .{ .layer = 2, .transform = .offset(50, 50) } },
        .{ .set_scroll = .{ .layer = 2, .scroll = .{ .viewport = .xywh(10, 10, 100, 100), .content = .{ .width = 100, .height = 500 }, .min_zoom = 0.5, .max_zoom = 4 } } },
        .{ .set_content = .{ .layer = 3, .content = try f.rect(0, .xywh(10, 10, 100, 500)) } },
        .{ .set_transform = .{ .layer = 4, .transform = .offset(200, 0) } },
        .{ .set_scroll = .{ .layer = 4, .scroll = .{ .viewport = .xywh(0, 0, 50, 50), .content = .{ .width = 50, .height = 500 } } } },
    });
    try testing.expectEqual(Route{ .scroll = 2 }, f.tree.routePinch(.{ .x = 100, .y = 120 }, .{}));
    try testing.expectEqual(Route.ui, f.tree.routePinch(.{ .x = 100, .y = 120 }, .{ .ctrl = true }));
    // A container that only scrolls does not take pinches.
    try testing.expectEqual(Route.ui, f.tree.routePinch(.{ .x = 220, .y = 20 }, .{}));

    // Zooming to 2 about (60, 40) in the container keeps the content
    // point under it, (60, 40) of the child (window point (110, 90)).
    try f.tree.zoomAt(2, 2, .{ .x = 60, .y = 40 }, true);
    try testing.expectEqual(@as(f32, 2), f.tree.get(2).?.zoom);
    try testing.expectEqual(Point{ .x = 50, .y = 30 }, f.tree.get(2).?.offset);
    try testing.expectEqual(Point{ .x = 60, .y = 40 }, f.tree.toLayer(3, .{ .x = 110, .y = 90 }).?);
    try testing.expectEqualSlices(LayerId, &.{2}, f.tree.scrolled.items);
    // Composition scales the children about the viewport's corner, then
    // moves them by the offset: x' = 10 + 2 (x - 10) - 50.
    const list = try f.tree.compose();
    try testing.expectEqual(@as(f32, 2), list.commands[3].push.layer.transform.a);
    try testing.expectEqual(@as(f32, -60), list.commands[3].push.layer.transform.e);

    // Hit testing goes through the zoom: a wheel region on the child at
    // (60, 40)-(70, 50) shows at window (110, 90)-(130, 110).
    try f.apply(&.{.{ .set_wheel_region = .{ .layer = 3, .region = .xywh(60, 40, 10, 10) } }});
    const down: Point = .{ .x = 0, .y = 10 };
    try testing.expectEqual(Route.ui, f.tree.route(.{ .x = 129, .y = 92 }, down));
    try testing.expectEqual(Route{ .scroll = 2 }, f.tree.route(.{ .x = 131, .y = 92 }, down));

    // Offsets are clamped to the zoomed content (200 x 1000 in a
    // 100 x 100 viewport), and the zoom to its range.
    _ = try f.tree.scrollBy(2, .{ .x = 1000, .y = 5000 });
    try testing.expectEqual(Point{ .x = 100, .y = 900 }, f.tree.get(2).?.offset);
    try f.tree.zoomAt(2, 100, .{ .x = 10, .y = 10 }, false);
    try testing.expectEqual(@as(f32, 4), f.tree.get(2).?.zoom);
    try testing.expectEqual(Point{ .x = 200, .y = 1800 }, f.tree.get(2).?.offset);
    try f.apply(&.{.{ .zoom_by = .{ .layer = 2, .factor = 0.01, .focus = .{ .x = 10, .y = 10 } } }});
    try testing.expectEqual(@as(f32, 0.5), f.tree.get(2).?.zoom);
    try testing.expectEqual(Point{ .x = 0, .y = 150 }, f.tree.get(2).?.offset);
}

test "animations sample at frame times and finish" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.apply(&.{
        .{ .create = 1 },
        .{ .animate = .{ .layer = 1, .animation = .{ .id = 7, .to = .{ .opacity = 0 }, .duration_ns = 100, .easing = .linear } } },
        .{ .animate = .{ .layer = 1, .animation = .{ .to = .{ .transform = .offset(10, 0) }, .duration_ns = 100, .start_ns = 1050, .easing = .linear } } },
    });
    var tk = try f.tree.tick(1000);
    try testing.expect(tk.active);
    try testing.expectEqual(@as(?u64, 1050), tk.next_start_ns);
    tk = try f.tree.tick(1050);
    try testing.expectApproxEqAbs(@as(f32, 0.5), f.tree.get(1).?.opacity, 1e-6);
    try testing.expectEqual(@as(f32, 0), f.tree.get(1).?.transform.translate.x);
    tk = try f.tree.tick(1100);
    try testing.expectEqual(@as(f32, 0), f.tree.get(1).?.opacity);
    try testing.expectEqual(@as(usize, 1), f.tree.finished.items.len);
    try testing.expectEqual(@as(u32, 7), f.tree.finished.items[0].id);
    tk = try f.tree.tick(1150);
    try testing.expectEqual(@as(f32, 10), f.tree.get(1).?.transform.translate.x);
    try testing.expect(!tk.active and tk.next_start_ns == null);
    try testing.expectEqual(@as(usize, 0), f.tree.animated.items.len);

    // Setting a property cancels its animation.
    try f.apply(&.{
        .{ .animate = .{ .layer = 1, .animation = .{ .to = .{ .opacity = 1 }, .duration_ns = 100 } } },
        .{ .set_opacity = .{ .layer = 1, .opacity = 0.25 } },
    });
    tk = try f.tree.tick(2000);
    try testing.expect(!tk.active);
    try testing.expectEqual(@as(f32, 0.25), f.tree.get(1).?.opacity);
}

test "layers given up stay drawn without input until their animations end, then go and are reported" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    // Root 1; 2 exits with a fade and carries 3, which exits with a
    // slower slide; 4 exits with nothing to wait for.
    try f.apply(&.{
        .{ .create = 1 },
        .{ .set_root = 1 },
        .{ .create = 2 },
        .{ .create = 3 },
        .{ .create = 4 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .insert = .{ .layer = 3, .parent = 2 } },
        .{ .insert = .{ .layer = 4, .parent = 1 } },
        .{ .set_content = .{ .layer = 2, .content = try f.rect(0, .xywh(0, 0, 50, 50)) } },
        .{ .set_wheel_region = .{ .layer = 2, .region = .xywh(0, 0, 50, 50) } },
        .{ .set_content = .{ .layer = 4, .content = try f.rect(1, .xywh(100, 0, 50, 50)) } },
    });
    _ = try f.tree.tick(1000);
    _ = try f.frame();
    try testing.expectEqual(Route.ui, f.tree.route(.{ .x = 10, .y = 10 }, .{ .x = 0, .y = 1 }));
    try f.apply(&.{
        .{ .animate = .{ .layer = 2, .animation = .{ .to = .{ .opacity = 0 }, .duration_ns = 100, .easing = .linear } } },
        .{ .exit = 2 },
        .{ .animate = .{ .layer = 3, .animation = .{ .to = .{ .transform = .offset(0, 20) }, .duration_ns = 200, .easing = .linear } } },
        .{ .exit = 3 },
        .{ .exit = 4 },
        // A repeating animation does not hold an exit back.
        .{ .animate = .{ .layer = 4, .animation = .{ .to = .{ .opacity = 0.5 }, .duration_ns = 100, .iterations = 0 } } },
    });
    var tk = try f.tree.tick(2000);
    try testing.expect(tk.holding);
    try testing.expect(f.tree.get(4) == null);
    try testing.expectEqualSlices(LayerId, &.{4}, f.tree.exited.items);
    // Still drawn, fading, but no longer hit.
    try testing.expect(f.tree.get(2) != null);
    try testing.expectEqual(Route.ui, f.tree.route(.{ .x = 10, .y = 10 }, .{ .x = 0, .y = 1 }));
    try testing.expect(f.tree.routeLayer(2, .{ .x = 10, .y = 10 }, .{ .wheel = .{ .x = 0, .y = 1 } }) == .miss);
    tk = try f.tree.tick(2050);
    try testing.expectApproxEqAbs(@as(f32, 0.5), f.tree.get(2).?.opacity, 1e-6);
    // 2's fade is done, but 3, given up inside it, still slides.
    tk = try f.tree.tick(2150);
    try testing.expect(f.tree.get(2) != null and tk.holding);
    tk = try f.tree.tick(2250);
    try testing.expect(f.tree.get(2) == null and f.tree.get(3) == null);
    try testing.expectEqualSlices(LayerId, &.{ 4, 3, 2 }, f.tree.exited.items);
    try testing.expectEqual(@as(usize, 0), f.tree.exiting.items.len);
    try testing.expect(!tk.holding);

    // Destroying an ancestor takes layers given up below it along.
    f.tree.exited.clearRetainingCapacity();
    try f.apply(&.{
        .{ .create = 5 },
        .{ .create = 6 },
        .{ .insert = .{ .layer = 5, .parent = 1 } },
        .{ .insert = .{ .layer = 6, .parent = 5 } },
        .{ .animate = .{ .layer = 6, .animation = .{ .to = .{ .opacity = 0 }, .duration_ns = 100 } } },
        .{ .exit = 6 },
        .{ .destroy = 5 },
    });
    try testing.expectEqualSlices(LayerId, &.{6}, f.tree.exited.items);
    try testing.expectEqual(@as(usize, 0), f.tree.exiting.items.len);
}

test "a reveal clips a layer inside its own clip while it animates, then goes" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.apply(&.{
        .{ .create = 1 },
        .{ .set_root = 1 },
        .{ .create = 2 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .set_content = .{ .layer = 2, .content = try f.rect(0, .xywh(0, 0, 100, 100)) } },
        .{ .set_clip = .{ .layer = 2, .clip = .{ .rect = .xywh(0, 0, 100, 100), .radii = .uniform(8, 8) } } },
        .{ .animate = .{ .layer = 2, .animation = .{
            .to = .{ .reveal = .{ .rect = .xywh(0, 0, 100, 100), .radii = .uniform(8, 8) } },
            .from = .{ .reveal = .{ .rect = .xywh(0, 0, 100, 20) } },
            .duration_ns = 100,
            .easing = .linear,
        } } },
    });
    _ = try f.tree.tick(1000);
    _ = try f.frame();
    _ = try f.tree.tick(1050);
    try testing.expectEqual(Rect.xywh(0, 0, 100, 60), f.tree.get(2).?.reveal.?.rect);
    var list = try f.tree.compose();
    // push 1, push 2 (own clip), push (reveal), fill, pop, pop, pop.
    try testing.expectEqual(@as(usize, 7), list.commands.len);
    try testing.expectEqual(@as(u32, 0), list.commands[2].push.layer.id);
    try testing.expectEqual(Rect.xywh(0, 0, 100, 60), list.commands[2].push.layer.clip.?.shape.bounds());
    try testing.expectEqual(Rect.xywh(0, 0, 100, 60), list.bounds);
    // The growing part is damaged though no content changed.
    const d = try f.tracker.diff(f.tree.previous(), list, .identity, .xywh(0, 0, 200, 200));
    _ = f.tree.endFrame();
    try testing.expect(d.len != 0);

    // Retargeted while it runs, it continues from the clip shown, not
    // from the new animation's `from`.
    try f.apply(&.{.{ .animate = .{ .layer = 2, .animation = .{
        .to = .{ .reveal = .{ .rect = .xywh(0, 0, 100, 80) } },
        .from = .{ .reveal = .{ .rect = .xywh(0, 0, 100, 0) } },
        .duration_ns = 100,
        .easing = .linear,
    } } }});
    _ = try f.tree.tick(1060);
    try testing.expectEqual(Rect.xywh(0, 0, 100, 60), f.tree.get(2).?.reveal.?.rect);
    _ = try f.tree.tick(1160);
    try testing.expect(f.tree.get(2).?.reveal == null);
    list = try f.tree.compose();
    try testing.expectEqual(@as(usize, 5), list.commands.len);
    _ = f.tree.endFrame();
}

test "the blur region follows transforms, scrolling, and clips, with rounded corners inside the curve" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var out: std.ArrayList(platform.Rect) = .empty;
    defer out.deinit(testing.allocator);
    const window = Rect.xywh(0, 0, 200, 200);
    try f.apply(&.{
        .{ .create = 1 },
        .{ .create = 2 },
        .{ .create = 3 },
        .{ .set_root = 1 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .insert = .{ .layer = 3, .parent = 2 } },
        // A scroll container at (20, 30) with a 100x50 viewport.
        .{ .set_transform = .{ .layer = 2, .transform = .offset(20, 30) } },
        .{ .set_scroll = .{ .layer = 2, .scroll = .{ .viewport = .xywh(0, 0, 100, 50), .content = .{ .width = 100, .height = 200 } } } },
        // A plain 40x20 shape 10 px into the content.
        .{ .set_transform = .{ .layer = 3, .transform = .offset(10, 10) } },
        .{ .set_blur = .{ .layer = 3, .shape = .{ .rect = .xywh(0, 0, 40, 20) } } },
    });
    try f.tree.blurRegion(&out, window);
    try testing.expectEqualSlices(platform.Rect, &.{.{ .x = 30, .y = 40, .width = 40, .height = 20 }}, out.items);

    // Scrolled by 15: it moves up and the viewport cuts its top.
    try f.apply(&.{.{ .scroll_to = .{ .layer = 2, .offset = .{ .x = 0, .y = 15 } } }});
    try f.tree.blurRegion(&out, window);
    try testing.expectEqualSlices(platform.Rect, &.{.{ .x = 30, .y = 30, .width = 40, .height = 15 }}, out.items);

    // Scrolled out of view: nothing; a hidden layer blurs nothing either.
    try f.apply(&.{.{ .scroll_to = .{ .layer = 2, .offset = .{ .x = 0, .y = 100 } } }});
    try f.tree.blurRegion(&out, window);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try f.apply(&.{
        .{ .scroll_to = .{ .layer = 2, .offset = .zero } },
        .{ .set_opacity = .{ .layer = 3, .opacity = 0 } },
    });
    try f.tree.blurRegion(&out, window);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // Rounded corners of radius 12 at scale 2: a full-width middle band,
    // and bands toward each edge inset by the curve, never outside it.
    try f.apply(&.{
        .{ .set_opacity = .{ .layer = 3, .opacity = 1 } },
        .{ .set_transform = .{ .layer = 3, .transform = .{ .translate = .{ .x = 10, .y = 10 }, .scale = .{ .x = 2, .y = 2 } } } },
        .{ .set_blur = .{ .layer = 3, .shape = .{ .rect = .xywh(0, 0, 40, 20), .radii = .uniform(6, 6) } } },
    });
    try f.tree.blurRegion(&out, window);
    // The shape is 80x40 at (30, 40); the viewport (20..120, 30..80)
    // cuts it at x 120 and y 80.
    try testing.expectEqual(platform.Rect{ .x = 30, .y = 52, .width = 80, .height = 16 }, out.items[0]);
    var area: i64 = 0;
    for (out.items) |r| {
        // Inside the shape and the viewport.
        try testing.expect(r.x >= 30 and r.y >= 40 and r.x + r.width <= 110 and r.y + r.height <= 80);
        // Each band avoids the corner's curve: its corners are within
        // the ellipse of radius 12 around the corner centers.
        for ([_][2]i32{ .{ r.x, r.y }, .{ r.x + r.width, r.y }, .{ r.x, r.y + r.height }, .{ r.x + r.width, r.y + r.height } }) |pt| {
            const cx: f32 = if (pt[0] < 42) 42 else if (pt[0] > 98) 98 else @floatFromInt(pt[0]);
            const cy: f32 = if (pt[1] < 52) 52 else if (pt[1] > 68) 68 else @floatFromInt(pt[1]);
            const dx = @as(f32, @floatFromInt(pt[0])) - cx;
            const dy = @as(f32, @floatFromInt(pt[1])) - cy;
            try testing.expect(dx * dx + dy * dy <= 12 * 12 + 0.01);
        }
        area += @as(i64, r.width) * r.height;
    }
    // Most of the rounded rectangle (80*40 minus 4 corners of
    // (1 - pi/4) * 144 = about 124) is covered.
    try testing.expect(area > 80 * 40 - 4 * 31 - 6 * 4 * 12 and area < 80 * 40 - 4 * 31);

    // Removing the shape empties the region.
    try f.apply(&.{.{ .set_blur = .{ .layer = 3, .shape = null } }});
    try testing.expectEqual(@as(u32, 0), f.tree.blurs);
    try f.tree.blurRegion(&out, window);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
