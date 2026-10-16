//! Lowering the tree into compositor layers (D8, D9).
//!
//! Layers: the root; every node with opacity below 1, a transform, or a
//! layer hint; every clipping node with layers below it (so its clip
//! applies to them); and every scroll node, whose layer is a compositor
//! scroll container (its decoration is the container's own content) with
//! one child layer for the scrolled content. Content painted after a child
//! layer, in the same parent, goes into a "chunk" layer that follows it,
//! so paint order survives without the compositor knowing about nodes.
//!
//! Each layer's content is a display list in the coordinates of the node
//! that roots it. Only layers whose nodes changed are repainted; their
//! damage is the old and new bounds of the nodes that changed. Moving,
//! fading, or transforming a layer root, and scrolling, change layer
//! properties only. Layer ids are layer indices plus one, reused after
//! the layer is destroyed (the compositor's contract, D20).

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const compositor = @import("compositor");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const text_node = @import("text_node.zig");
const text = @import("text");
const editor = @import("editor.zig");
const layout = @import("layout.zig");
const isLayerRoot = @import("txn.zig").isLayerRoot;
const Image = @import("image.zig").Image;
const svg = @import("svg");
const theme = @import("theme.zig");

const NodeId = node_mod.NodeId;
const Point = raster.Point;
const Rect = raster.Rect;
const Op = compositor.Op;
const Error = Window.Error;

pub const no_layer: u32 = std.math.maxInt(u32);

/// The color of keyboard focus rings.
pub const focus_ring_color = scene.Color.srgb8(0x25, 0x63, 0xeb, 0xff);
pub const focus_ring_width: f32 = 2;

const LayerKind = enum { root, node, clip_content, scroll_content, chunk, caret };

const Layer = struct {
    kind: LayerKind,
    owner: NodeId,
    /// Assignment pass that claimed it; older means dead.
    pass: u32,
    parent: u32,
    // What the compositor has.
    created: bool = false,
    sent_parent: u32 = no_layer,
    transform: compositor.Transform = .identity,
    opacity: f32 = 1,
    clip: ?compositor.Clip = null,
    scroll: ?compositor.Scroll = null,
    /// Sequence of the last `scroll_to`, to ignore older `scrolled` reports.
    scroll_seq: u64 = 0,
    /// The compositor's offset and zoom as last sent or reported.
    scroll_offset: Point = .zero,
    zoom: f32 = 1,
    wheel: ?Rect = null,
    blur: ?compositor.BlurShape = null,
    external: ?compositor.ExternalPlacement = null,
    /// Caret layers: what the content shows, and what the running blink
    /// started from (it restarts when this changes).
    caret_h: f32 = 0,
    caret_w: f32 = 0,
    caret_color: scene.Color = .transparent,
    /// A block caret in a selection: outlined, so it stands out from the
    /// selection's color.
    caret_outline: bool = false,
    blink_key: u64 = 0,
    /// Properties were sent once, and the owner's own transform then:
    /// transitions animate changes of it, not the first value or moves
    /// from layout.
    props_sent: bool = false,
    own_transform: compositor.Transform = .identity,
    /// The owner's animation as last sent (with `start_ns` 0); it is sent
    /// again, restarting, when what it resolves to changes.
    anim: ?compositor.Animation = null,
    // Content.
    dirty: bool = true,
    subtree_dirty: bool = false,
    full_damage: bool = true,
    damage: Rect = Rect.empty,
    builder: ?*scene.Builder = null,
    /// Clip entries open in `builder` while it is built.
    open: std.ArrayList(u32) = .empty,
    version: u32 = 0,
};

/// Input the UI passes on to a scroll node's container: a scroll by
/// `delta`, or (`zoom` other than 1) a zoom by that factor about `focus`
/// in the node's coordinates.
pub const ScrollBy = struct {
    node: NodeId,
    delta: Point = .zero,
    zoom: f32 = 1,
    focus: Point = .zero,
    /// Goes before the commit's other ops: a correction that moves up
    /// to content that shrank above (D13), before the container's new
    /// extent clamps the offset.
    early: bool = false,
};

const ClipEntry = struct {
    serial: u32,
    shape: scene.Shape,
    /// Intersection with the enclosing clips (for bounds).
    rect: Rect,
};

/// A builder and the images its display list draws: it holds a reference
/// to each until the compositor releases the list or it is reset.
const Slot = struct {
    builder: scene.Builder,
    images: std.ArrayList(*Image) = .empty,

    fn of(b: *scene.Builder) *Slot {
        return @fieldParentPtr("builder", b);
    }

    fn dropImages(slot: *Slot) void {
        for (slot.images.items) |img| img.release();
        slot.images.clearRetainingCapacity();
    }
};

/// See `Window.holdImage`.
pub fn holdImage(gpa: std.mem.Allocator, b: *scene.Builder, img: *Image) error{OutOfMemory}!void {
    const images = &Slot.of(b).images;
    try images.ensureUnusedCapacity(gpa, 1);
    images.appendAssumeCapacity(img.retain());
}

pub const State = struct {
    layers: std.ArrayList(Layer) = .empty,
    free: std.ArrayList(u32) = .empty,
    /// Live layers, parents before children, in paint order.
    order: std.ArrayList(u32) = .empty,
    /// Builders the compositor released, ready for reuse.
    builders: std.ArrayList(*scene.Builder) = .empty,
    /// Every builder this window made, freed with it.
    all_builders: std.ArrayList(*scene.Builder) = .empty,
    ops: std.ArrayList(Op) = .empty,
    /// Scroll input to pass on to the compositor at the next commit.
    scroll_by: std.ArrayList(ScrollBy) = .empty,
    clips: std.ArrayList(ClipEntry) = .empty,
    glyphs: std.ArrayList(scene.Glyph) = .empty,
    pass: u32 = 0,
    serial: u32 = 0,
    /// Bumped to restart caret blinks (settings changed).
    blink_epoch: u32 = 0,
    root_sent: bool = false,
    dirty_count: u32 = 0,

    pub fn init(st: *State, win: *Window) Error!void {
        try st.layers.append(win.gpa, .{ .kind = .root, .owner = .root, .pass = 0, .parent = no_layer });
        st.dirty_count = 1;
        win.state(.root).own_layer = 0;
        win.state(.root).layer = 0;
    }

    pub fn deinit(st: *State, gpa: std.mem.Allocator) void {
        for (st.layers.items) |*l| l.open.deinit(gpa);
        st.layers.deinit(gpa);
        st.free.deinit(gpa);
        st.order.deinit(gpa);
        for (st.all_builders.items) |b| {
            const slot = Slot.of(b);
            slot.dropImages();
            slot.images.deinit(gpa);
            b.deinit();
            gpa.destroy(slot);
        }
        st.all_builders.deinit(gpa);
        st.builders.deinit(gpa);
        st.ops.deinit(gpa);
        st.scroll_by.deinit(gpa);
        st.clips.deinit(gpa);
        st.glyphs.deinit(gpa);
    }

    pub fn markLayer(st: *State, index: u32) void {
        if (index == no_layer or index >= st.layers.items.len) return;
        const l = &st.layers.items[index];
        if (!l.dirty) {
            l.dirty = true;
            st.dirty_count += 1;
        }
    }

    /// Adds `r` (layer coordinates) to a layer's damage.
    pub fn damage(st: *State, index: u32, r: Rect) void {
        if (index == no_layer or index >= st.layers.items.len or r.isEmpty()) return;
        st.markLayer(index);
        const l = &st.layers.items[index];
        l.damage = l.damage.unite(r);
    }

    /// Repaints every layer in full (the accent color changed).
    pub fn repaintAll(st: *State) void {
        for (st.order.items) |i| {
            st.layers.items[i].full_damage = true;
            st.markLayer(i);
        }
    }

    pub fn restartBlink(st: *State) void {
        st.blink_epoch +%= 1;
    }

    pub fn anyDirty(st: *const State) bool {
        return st.dirty_count != 0;
    }

    /// A builder the compositor no longer reads.
    pub fn released(st: *State, gpa: std.mem.Allocator, b: *scene.Builder) void {
        Slot.of(b).dropImages();
        st.builders.append(gpa, b) catch {
            // Keep it in all_builders; it is freed with the window.
        };
    }

    // Assignment ----------------------------------------------------------

    /// Decides which nodes root layers and which layer each node paints
    /// into, and queues the structural ops.
    pub fn assign(st: *State, win: *Window) Error!void {
        const gpa = win.gpa;
        const a = win.scratch.allocator();
        const flags = try a.alloc(Flags, win.nodes.items.len);
        _ = scan(win, .root, flags);

        st.pass +%= 1;
        st.order.clearRetainingCapacity();
        st.layers.items[0].pass = st.pass;
        try st.order.append(gpa, 0);
        var cur: Cursor = .{ .layer = 0 };
        var it = win.shown(.root);
        while (it.next()) |ch| try st.visit(win, flags, ch, 0, &cur);

        // Structural ops: move survivors out of dying parents, destroy the
        // dead, create the new, then insert everything in paint order.
        try st.ops.ensureUnusedCapacity(gpa, 2 * st.layers.items.len + 1);
        for (st.order.items) |i| {
            const l = &st.layers.items[i];
            if (l.created and l.sent_parent != l.parent and l.sent_parent != no_layer) {
                st.ops.appendAssumeCapacity(.{ .detach = id(i) });
                l.sent_parent = no_layer;
            }
        }
        for (st.layers.items, 0..) |*l, i| {
            if (l.pass == st.pass or l.kind == .root) continue;
            if (l.pass == 0 and !l.created) continue; // free slot
            const parent_dead = l.sent_parent != no_layer and st.layers.items[l.sent_parent].pass != st.pass;
            if (l.created and !parent_dead) st.ops.appendAssumeCapacity(.{ .destroy = id(@intCast(i)) });
            if (l.dirty) st.dirty_count -= 1;
            l.open.deinit(gpa);
            l.* = .{ .kind = .chunk, .owner = .none, .pass = 0, .parent = no_layer, .dirty = false };
            try st.free.append(gpa, @intCast(i));
        }
        for (st.order.items) |i| {
            const l = &st.layers.items[i];
            if (!l.created) {
                st.ops.appendAssumeCapacity(.{ .create = id(i) });
                l.created = true;
            }
        }
        try st.ops.ensureUnusedCapacity(gpa, st.order.items.len + 1);
        for (st.order.items[1..]) |i| {
            const l = &st.layers.items[i];
            st.ops.appendAssumeCapacity(.{ .insert = .{ .layer = id(i), .parent = id(l.parent) } });
            l.sent_parent = l.parent;
        }
        if (!st.root_sent) {
            st.ops.appendAssumeCapacity(.{ .set_root = id(0) });
            st.root_sent = true;
        }
        win.dirty.props = true;
    }

    const Flags = packed struct(u8) {
        /// Some descendant roots a layer.
        layer_below: bool = false,
        _: u7 = 0,
    };

    /// Returns the flags a node contributes to its ancestors.
    fn scan(win: *Window, nid: NodeId, flags: []Flags) Flags {
        var f: Flags = .{};
        var it = win.shown(nid);
        while (it.next()) |ch| {
            const cf = scan(win, ch, flags);
            f.layer_below = f.layer_below or cf.layer_below;
        }
        flags[nid.index()] = f;
        return .{ .layer_below = f.layer_below or ownsLayer(win, nid, f) };
    }

    /// Nodes with scroll or gesture handlers root a layer so that their
    /// wheel region sends scroll input and pinches over them to the UI
    /// first (D8).
    fn ownsLayer(win: *const Window, nid: NodeId, f: Flags) bool {
        const n = win.node(nid);
        return nid == .root or n.kind == .scroll or isLayerRoot(n.visual) or (n.visual.clip and f.layer_below) or
            wantsWheel(n) or hasCaret(win, nid) or n.kind == .external;
    }

    /// A clipping node with shadows clips its children in a child layer,
    /// so its own layer, which holds the shadows, is not clipped.
    fn clipsInChild(v: node_mod.Visual) bool {
        return v.clip and v.shadow_count != 0;
    }

    /// The focused editor roots a layer with its caret in a child layer, so
    /// the caret moves and blinks as layer properties.
    fn hasCaret(win: *const Window, nid: NodeId) bool {
        return win.input.focus == nid and win.node(nid).kind == .editor;
    }

    const Cursor = struct {
        layer: u32,
        /// Content from here on follows this node's layer subtree.
        after: NodeId = .none,
    };

    fn visit(st: *State, win: *Window, flags: []const Flags, nid: NodeId, container: u32, cur: *Cursor) Error!void {
        const s = win.state(nid);
        const n = win.node(nid);
        if (ownsLayer(win, nid, flags[nid.index()])) {
            const l = try st.claim(win, &s.own_layer, .node, nid, container);
            st.setLayer(win, nid, l);
            var inner_container = l;
            if (clipsInChild(n.visual)) {
                inner_container = try st.claim(win, &s.clip_layer, .clip_content, nid, l);
            }
            if (n.kind == .scroll) {
                inner_container = try st.claim(win, &s.content_layer, .scroll_content, nid, inner_container);
            }
            var inner: Cursor = .{ .layer = inner_container };
            var it = win.shown(nid);
            while (it.next()) |ch| try st.visit(win, flags, ch, inner_container, &inner);
            if (hasCaret(win, nid)) _ = try st.claim(win, &s.content_layer, .caret, nid, l);
            cur.after = nid;
            return;
        }
        if (cur.after != .none) {
            const owner = cur.after;
            cur.layer = try st.claim(win, &win.state(owner).chunk_layer, .chunk, owner, container);
            cur.after = .none;
        }
        st.setLayer(win, nid, cur.layer);
        var it = win.shown(nid);
        while (it.next()) |ch| try st.visit(win, flags, ch, container, cur);
    }

    fn claim(st: *State, win: *Window, slot: *u32, kind: LayerKind, owner: NodeId, parent: u32) Error!u32 {
        const gpa = win.gpa;
        try st.order.ensureUnusedCapacity(gpa, 1);
        if (slot.* != no_layer and slot.* < st.layers.items.len) {
            const l = &st.layers.items[slot.*];
            if (l.kind == kind and l.owner == owner and l.pass != st.pass and l.pass != 0) {
                l.pass = st.pass;
                l.parent = parent;
                st.order.appendAssumeCapacity(slot.*);
                return slot.*;
            }
        }
        const index: u32 = if (st.free.pop()) |i| i else blk: {
            try st.layers.append(gpa, undefined);
            break :blk @intCast(st.layers.items.len - 1);
        };
        st.layers.items[index] = .{ .kind = kind, .owner = owner, .pass = st.pass, .parent = parent };
        st.dirty_count += 1;
        st.order.appendAssumeCapacity(index);
        slot.* = index;
        return index;
    }

    fn setLayer(st: *State, win: *Window, nid: NodeId, l: u32) void {
        const s = win.state(nid);
        if (s.layer == l) return;
        st.damage(s.layer, s.bounds);
        s.layer = l;
        s.paint_dirty = true;
        st.markLayer(l);
    }

    // Content -------------------------------------------------------------

    /// Repaints the layers whose content changed and queues their content.
    pub fn build(st: *State, win: *Window) Error!void {
        for (st.order.items) |i| {
            const l = &st.layers.items[i];
            if (l.kind != .caret) continue;
            const w, const h, const color, const outline = caretLook(win, l.owner);
            if (h != l.caret_h or w != l.caret_w or !std.meta.eql(color, l.caret_color) or outline != l.caret_outline) {
                l.caret_h = h;
                l.caret_w = w;
                l.caret_color = color;
                l.caret_outline = outline;
                st.markLayer(i);
            }
        }
        if (st.dirty_count == 0) return;
        const gpa = win.gpa;
        for (st.order.items) |i| st.layers.items[i].subtree_dirty = st.layers.items[i].dirty;
        var k = st.order.items.len;
        while (k > 1) {
            k -= 1;
            const l = st.layers.items[st.order.items[k]];
            if (l.subtree_dirty) st.layers.items[l.parent].subtree_dirty = true;
        }
        try st.ops.ensureUnusedCapacity(gpa, st.dirty_count);
        for (st.order.items) |i| {
            const l = &st.layers.items[i];
            if (!l.dirty) continue;
            const b = st.builders.pop() orelse blk: {
                try st.all_builders.ensureUnusedCapacity(gpa, 1);
                const slot = try gpa.create(Slot);
                slot.* = .{ .builder = .init(gpa) };
                st.all_builders.appendAssumeCapacity(&slot.builder);
                break :blk &slot.builder;
            };
            b.reset();
            Slot.of(b).dropImages();
            l.builder = b;
            l.open.clearRetainingCapacity();
        }
        st.clips.clearRetainingCapacity();
        try st.builders.ensureTotalCapacity(gpa, st.all_builders.items.len);
        errdefer for (st.order.items) |i| {
            const l = &st.layers.items[i];
            if (l.builder) |b| {
                Slot.of(b).dropImages();
                st.builders.appendAssumeCapacity(b);
                l.builder = null;
            }
        };
        try st.paintTree(win, .root, .zero, 0);

        for (st.order.items) |i| {
            const l = &st.layers.items[i];
            const b = l.builder orelse continue;
            if (l.kind == .caret and l.caret_h > 0) drawCaret(b, l) catch |e| return oom(e);
            for (l.open.items) |_| b.popLayer() catch |e| return oom(e);
            l.open.clearRetainingCapacity();
            l.version +%= 1;
            const list = b.finish(l.version) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            st.ops.appendAssumeCapacity(.{ .set_content = .{
                .layer = id(i),
                .content = .{ .list = list, .builder = b },
                .damage = if (l.full_damage) null else if (l.damage.isEmpty()) Rect.xywh(0, 0, 0, 0) else l.damage,
            } });
            l.builder = null;
            l.dirty = false;
            l.full_damage = false;
            l.damage = Rect.empty;
            win.stats.layer_builds += 1;
        }
        st.dirty_count = 0;
    }

    fn paintTree(st: *State, win: *Window, nid: NodeId, off: Point, level: usize) Error!void {
        const n = win.node(nid);
        const s = win.state(nid);
        if (st.ownsLayerNow(win, nid)) {
            const l = s.own_layer;
            if (!st.layers.items[l].subtree_dirty) return;
            const lvl = st.clips.items.len;
            try st.paintNode(win, nid, .zero, lvl);
            const child_level = st.clips.items.len;
            var it = win.shown(nid);
            while (it.next()) |ch| try st.paintTree(win, ch, win.state(ch).pos, child_level);
            return;
        }
        try st.paintNode(win, nid, off, level);
        const clipped = n.visual.clip;
        if (clipped) try st.pushClip(win, nid, off);
        var it = win.shown(nid);
        while (it.next()) |ch| {
            const cp = win.state(ch).pos;
            try st.paintTree(win, ch, .{ .x = off.x + cp.x, .y = off.y + cp.y }, level);
        }
        if (clipped) _ = st.clips.pop();
    }

    fn pushClip(st: *State, win: *Window, nid: NodeId, off: Point) Error!void {
        const s = win.state(nid);
        const r = Rect.xywh(off.x, off.y, s.size.w, s.size.h);
        const v = win.node(nid).visual;
        const shape: scene.Shape = if (v.radius.isZero()) .{ .rect = r } else .{ .rounded_rect = .{ .rect = r, .radii = v.radius.physical(s.rtl) } };
        const outer = if (st.clips.items.len != 0) st.clips.items[st.clips.items.len - 1].rect else infinite;
        st.serial +%= 1;
        try st.clips.append(win.gpa, .{ .serial = st.serial, .shape = shape, .rect = outer.intersect(r) });
    }

    /// Brings a layer's open clips in line with the clip stack from `level`.
    fn syncClips(st: *State, win: *Window, l: *Layer, level: usize) Error!void {
        const want = st.clips.items[level..];
        var common: usize = 0;
        while (common < l.open.items.len and common < want.len and l.open.items[common] == want[common].serial) common += 1;
        const b = l.builder.?;
        while (l.open.items.len > common) {
            b.popLayer() catch |e| return oom(e);
            _ = l.open.pop();
        }
        for (want[common..]) |e| {
            try l.open.append(win.gpa, e.serial);
            b.pushLayer(.{ .clip = .{ .shape = e.shape } }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
        }
    }

    fn paintNode(st: *State, win: *Window, nid: NodeId, off: Point, level: usize) Error!void {
        const s = win.state(nid);
        const l = &st.layers.items[s.layer];
        if (l.builder == null) return;
        try st.syncClips(win, l, level);
        const b = l.builder.?;
        const bounds = drawNode(st, win, nid, b, off) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => Rect.empty, // invalid canvas content: drawn as nothing
        };
        const clip = if (st.clips.items.len > level) st.clips.items[st.clips.items.len - 1].rect else infinite;
        var clipped = bounds.intersect(clip);
        if (clipped.isEmpty()) clipped = Rect.empty;
        if (s.paint_dirty or !clipped.eql(s.bounds)) {
            l.damage = l.damage.unite(s.bounds).unite(clipped);
        }
        s.bounds = clipped;
        s.paint_dirty = false;
    }

    // Properties ----------------------------------------------------------

    /// Queues property changes and programmatic scrolls, then commits
    /// everything queued this frame.
    pub fn emit(st: *State, win: *Window) Error!void {
        const gpa = win.gpa;
        var scroll_layers: std.ArrayList(u32) = .empty;
        var early: usize = 0;
        for (st.scroll_by.items) |sb| {
            if (!sb.early or !win.isLive(sb.node) or !st.ownsLayerNow(win, sb.node)) continue;
            try st.ops.insert(gpa, early, .{ .scroll_by = .{ .layer = id(win.state(sb.node).own_layer), .delta = sb.delta } });
            early += 1;
        }
        if (win.dirty.props or st.ops.items.len != 0) {
            try st.ops.ensureUnusedCapacity(gpa, 13 * st.order.items.len + st.scroll_by.items.len + 1);
            for (st.order.items) |i| {
                const l = &st.layers.items[i];
                const p = props(st, win, l.*);
                // Transitions (D29): the node's own opacity and transform
                // changes animate on the compositor unless motion is
                // reduced.
                const owner_visual = if (l.kind == .node or l.kind == .root) win.node(l.owner).visual else null;
                const ms: u32 = if (owner_visual) |v| (if (win.reducedMotion()) 0 else v.transition_ms) else 0;
                const own_t = if (owner_visual) |v| v.transform else compositor.Transform.identity;
                // A running animation (D29) owns its property: changes of
                // the base value send it again instead.
                const anim = if (owner_visual) |v| animationOf(win, l.owner, v.animation, p) else null;
                const anim_prop: ?compositor.Property = if (anim) |a| std.meta.activeTag(a.to) else null;
                if (!l.transform.eql(p.transform) and anim_prop == .transform) {
                    l.transform = p.transform;
                } else if (!l.transform.eql(p.transform)) {
                    if (ms != 0 and l.props_sent and !own_t.eql(l.own_transform)) {
                        st.ops.appendAssumeCapacity(.{ .animate = .{ .layer = id(i), .animation = transition(.{ .transform = p.transform }, ms) } });
                    } else st.ops.appendAssumeCapacity(.{ .set_transform = .{ .layer = id(i), .transform = p.transform } });
                    l.transform = p.transform;
                }
                l.own_transform = own_t;
                if (l.opacity != p.opacity and anim_prop == .opacity) {
                    l.opacity = p.opacity;
                } else if (l.opacity != p.opacity) {
                    if (ms != 0 and l.props_sent) {
                        st.ops.appendAssumeCapacity(.{ .animate = .{ .layer = id(i), .animation = transition(.{ .opacity = p.opacity }, ms) } });
                    } else st.ops.appendAssumeCapacity(.{ .set_opacity = .{ .layer = id(i), .opacity = p.opacity } });
                    l.opacity = p.opacity;
                }
                if (!std.meta.eql(l.anim, anim)) {
                    // Setting a property cancels its animation.
                    if (l.anim) |old| if (anim_prop != std.meta.activeTag(old.to)) switch (old.to) {
                        .transform => st.ops.appendAssumeCapacity(.{ .set_transform = .{ .layer = id(i), .transform = p.transform } }),
                        .opacity => st.ops.appendAssumeCapacity(.{ .set_opacity = .{ .layer = id(i), .opacity = p.opacity } }),
                        .scroll => unreachable,
                    };
                    if (anim) |a| {
                        var started = a;
                        const delay = win.node(l.owner).visual.animation.delay_ms;
                        if (delay != 0) started.start_ns = @import("loop").Loop.now() + @as(u64, delay) * std.time.ns_per_ms;
                        st.ops.appendAssumeCapacity(.{ .animate = .{ .layer = id(i), .animation = started } });
                    }
                    l.anim = anim;
                }
                l.props_sent = true;
                if (!std.meta.eql(l.clip, p.clip)) {
                    st.ops.appendAssumeCapacity(.{ .set_clip = .{ .layer = id(i), .clip = p.clip } });
                    l.clip = p.clip;
                }
                if (!std.meta.eql(l.scroll, p.scroll)) {
                    st.ops.appendAssumeCapacity(.{ .set_scroll = .{ .layer = id(i), .scroll = p.scroll } });
                    l.scroll = p.scroll;
                }
                if (!std.meta.eql(l.wheel, p.wheel)) {
                    st.ops.appendAssumeCapacity(.{ .set_wheel_region = .{ .layer = id(i), .region = p.wheel } });
                    l.wheel = p.wheel;
                }
                if (!std.meta.eql(l.blur, p.blur)) {
                    st.ops.appendAssumeCapacity(.{ .set_blur = .{ .layer = id(i), .shape = p.blur } });
                    l.blur = p.blur;
                }
                if (!std.meta.eql(l.external, p.external)) {
                    st.ops.appendAssumeCapacity(.{ .set_external = .{ .layer = id(i), .external = p.external } });
                    l.external = p.external;
                }
                if (l.kind == .caret) {
                    // Any caret change shows it solid, then blinks for a
                    // while on the compositor and stops, so an idle window
                    // makes no wakeups (D25). No blinking with reduced
                    // motion or when the desktop turned blinking off.
                    const e = win.node(l.owner).data.editor;
                    var hasher = std.hash.Wyhash.init(st.blink_epoch);
                    std.hash.autoHash(&hasher, .{ e.caret, e.anchor, e.revision, e.shown_caret });
                    const key = hasher.final() | 1;
                    if (key != l.blink_key) {
                        l.blink_key = key;
                        st.ops.appendAssumeCapacity(.{ .set_opacity = .{ .layer = id(i), .opacity = 1 } });
                        l.opacity = 1;
                        const d = win.desktop;
                        const half_ns = @as(u64, @max(d.cursor_blink_ms, 2) / 2) * std.time.ns_per_ms;
                        if (!win.reducedMotion() and d.cursor_blink) st.ops.appendAssumeCapacity(.{ .animate = .{ .layer = id(i), .animation = .{
                            .to = .{ .opacity = 0 },
                            .from = .{ .opacity = 1 },
                            .duration_ns = half_ns,
                            .start_ns = @import("loop").Loop.now() + half_ns,
                            .iterations = blinkHalves(d),
                            .alternate = true,
                            .easing = .ease_in_out,
                        } } });
                    }
                }
                if (l.kind == .node and win.node(l.owner).kind == .scroll) {
                    const s = win.state(l.owner);
                    // A zoom the application set; the content at the
                    // viewport's corner stays (the offset follows below).
                    const zoom = win.node(l.owner).data.scroll.zoom;
                    if (zoom != l.zoom) {
                        const pad = win.node(l.owner).layout.padding;
                        st.ops.appendAssumeCapacity(.{ .zoom_to = .{ .layer = id(i), .zoom = zoom, .focus = .{ .x = pad.left(s.rtl), .y = pad.top } } });
                        l.zoom = zoom;
                        s.scroll_pending = true;
                    }
                    const phys = scrollTranslation(win, l.owner);
                    // In RTL the start edge is at the far end of the content,
                    // so the offset follows the content width.
                    if (s.scroll_pending or (s.rtl and phys.x != l.scroll_offset.x)) {
                        st.ops.appendAssumeCapacity(.{ .scroll_to = .{ .layer = id(i), .offset = phys } });
                        l.scroll_offset = phys;
                        s.scroll_pending = false;
                        try scroll_layers.append(win.scratch.allocator(), i);
                    }
                }
            }
        }
        // Scroll input the UI passed on, relative to wherever the
        // compositor has the offset now.
        try st.ops.ensureUnusedCapacity(gpa, 2 * st.scroll_by.items.len + 1);
        for (st.scroll_by.items) |sb| {
            if (sb.early or !win.isLive(sb.node) or !st.ownsLayerNow(win, sb.node)) continue;
            const layer = id(win.state(sb.node).own_layer);
            if (sb.zoom != 1) st.ops.appendAssumeCapacity(.{ .zoom_by = .{ .layer = layer, .factor = sb.zoom, .focus = sb.focus } });
            if (!sb.delta.eql(.zero)) st.ops.appendAssumeCapacity(.{ .scroll_by = .{ .layer = layer, .delta = sb.delta } });
        }
        st.scroll_by.clearRetainingCapacity();
        if (win.configure_serial) |serial| {
            st.ops.appendAssumeCapacity(.{ .ack_configure = serial });
            win.configure_serial = null;
        }
        if (st.ops.items.len == 0) return;
        defer st.ops.clearRetainingCapacity();
        const seq = try win.sink.commit(win.sink.ctx, st.ops.items);
        for (scroll_layers.items) |i| st.layers.items[i].scroll_seq = seq;
    }

    /// What a node's animation sends to the compositor, from its base
    /// properties `p`; null when it does not run.
    fn animationOf(win: *Window, nid: NodeId, a: node_mod.Animation, p: Props) ?compositor.Animation {
        if (a.property == .none or win.reducedMotion()) return null;
        const s = win.state(nid);
        const flip: f32 = if (a.mirror and s.rtl) -1 else 1;
        const size = s.size;
        const at = struct {
            fn f(base: Props, sz: layout.Size, an: node_mod.Animation, value: f32, fl: f32) compositor.Value {
                const v = if (an.property == .translate_x or an.property == .rotate) value * fl else value;
                var t = base.transform;
                const center: Point = .{ .x = sz.w / 2, .y = sz.h / 2 };
                switch (an.property) {
                    .none => unreachable,
                    .opacity => return .{ .opacity = std.math.clamp(base.opacity * v, 0, 1) },
                    .translate_x => t.translate.x += if (an.relative) v * sz.w else v,
                    .translate_y => t.translate.y += if (an.relative) v * sz.h else v,
                    .scale => {
                        t.scale = .{ .x = t.scale.x * v, .y = t.scale.y * v };
                        t.origin = center;
                    },
                    .rotate => {
                        t.rotate += v;
                        t.origin = center;
                    },
                }
                return .{ .transform = t };
            }
        }.f;
        return .{
            .to = at(p, size, a, a.to, flip),
            .from = at(p, size, a, a.from, flip),
            .duration_ns = @as(u64, a.duration_ms) * std.time.ns_per_ms,
            .easing = switch (a.easing) {
                .ease => .ease,
                .linear => .linear,
                .ease_in => .ease_in,
                .ease_out => .ease_out,
                .ease_in_out => .ease_in_out,
            },
            .iterations = a.iterations,
            .alternate = a.alternate,
        };
    }

    const Props = struct {
        transform: compositor.Transform = .identity,
        opacity: f32 = 1,
        clip: ?compositor.Clip = null,
        scroll: ?compositor.Scroll = null,
        wheel: ?Rect = null,
        blur: ?compositor.BlurShape = null,
        external: ?compositor.ExternalPlacement = null,
    };

    fn props(st: *const State, win: *const Window, l: Layer) Props {
        switch (l.kind) {
            .chunk => return .{},
            .caret => {
                const l_ = text_node.current(win, l.owner) orelse return .{};
                const n = win.node(l.owner);
                const s = win.state(l.owner);
                const c = editor.caretRect(win, l.owner, l_) catch return .{};
                return .{ .transform = .offset(n.layout.padding.left(s.rtl) - s.editor_scroll + c.x0, n.layout.padding.top + c.y0) };
            },
            .clip_content => {
                const n = win.node(l.owner);
                const s = win.state(l.owner);
                return .{ .clip = .{ .rect = .xywh(0, 0, s.size.w, s.size.h), .radii = n.visual.radius.physical(s.rtl) } };
            },
            .scroll_content => {
                const s = win.state(l.owner);
                const pad = win.node(l.owner).layout.padding;
                return .{ .transform = .offset(pad.left(s.rtl), pad.top) };
            },
            .root, .node => {
                const n = win.node(l.owner);
                const s = win.state(l.owner);
                var t = n.visual.transform;
                if (l.kind == .node) {
                    const off = st.offsetInContainer(win, l.owner);
                    t.translate.x += off.x;
                    t.translate.y += off.y;
                }
                var p: Props = .{ .transform = t, .opacity = n.visual.opacity };
                if (n.visual.clip and !clipsInChild(n.visual)) p.clip = .{ .rect = .xywh(0, 0, s.size.w, s.size.h), .radii = n.visual.radius.physical(s.rtl) };
                if (n.kind == .scroll) {
                    const pad = n.layout.padding;
                    p.scroll = .{
                        .viewport = .xywh(pad.left(s.rtl), pad.top, @max(0, s.size.w - pad.horizontal()), @max(0, s.size.h - pad.vertical())),
                        .content = .{ .width = s.content.w, .height = s.content.h },
                        .min_zoom = n.data.scroll.min_zoom,
                        .max_zoom = n.data.scroll.max_zoom,
                    };
                }
                if (wantsWheel(n)) p.wheel = .xywh(0, 0, s.size.w, s.size.h);
                if (n.visual.window_blur) p.blur = .{ .rect = .xywh(0, 0, s.size.w, s.size.h), .radii = n.visual.radius.physical(s.rtl) };
                if (n.kind == .external) {
                    p.external = externalPlacement(win, l.owner);
                    // Covering content overflows its box: clip it there (and
                    // composite it, since a subsurface cannot be cropped).
                    if (n.data.external.fit == .cover and p.clip == null) p.clip = .{ .rect = .xywh(0, 0, s.size.w, s.size.h) };
                }
                return p;
            },
        }
    }

    /// Whether the node roots a layer in the current assignment.
    pub fn ownsLayerNow(st: *const State, win: *const Window, nid: NodeId) bool {
        const l = win.state(nid).own_layer;
        if (l == no_layer or l >= st.layers.items.len) return false;
        const layer = st.layers.items[l];
        return layer.owner == nid and layer.pass == st.pass and (layer.kind == .node or layer.kind == .root);
    }

    /// A layer root's position in its parent layer's coordinates.
    fn offsetInContainer(st: *const State, win: *const Window, nid: NodeId) Point {
        var p = win.state(nid).pos;
        var cur = win.node(nid).parent;
        while (cur != .none) : (cur = win.node(cur).parent) {
            const cs = win.state(cur);
            if (st.ownsLayerNow(win, cur)) break;
            p.x += cs.pos.x;
            p.y += cs.pos.y;
        }
        return p;
    }
};

/// A transition to `to` from whatever the layer shows.
fn transition(to: compositor.Value, ms: u32) compositor.Animation {
    return .{ .to = to, .duration_ns = @as(u64, ms) * std.time.ns_per_ms, .easing = .ease_out };
}

fn oom(err: scene.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // The UI only emits balanced, finite commands.
        else => unreachable,
    };
}

fn id(index: u32) compositor.LayerId {
    return index + 1;
}

/// The layer index of a compositor layer id.
pub fn indexOf(layer: compositor.LayerId) u32 {
    return layer - 1;
}

const infinite: Rect = .{ .x0 = -std.math.inf(f32), .y0 = -std.math.inf(f32), .x1 = std.math.inf(f32), .y1 = std.math.inf(f32) };

/// Whether scroll input and pinches over the node go to the UI first: it
/// has a scroll or gesture handler.
fn wantsWheel(n: *const node_mod.Node) bool {
    return n.handler(.scroll) != null or n.handler(.gesture) != null;
}

/// Largest physical scroll offset of a scroll node, in zoomed pixels.
pub fn maxScroll(win: *const Window, nid: NodeId) Point {
    const s = win.state(nid);
    const pad = win.node(nid).layout.padding;
    const z = zoomOf(win, nid);
    return .{
        .x = @max(0, s.content.w * z - (s.size.w - pad.horizontal())),
        .y = @max(0, s.content.h * z - (s.size.h - pad.vertical())),
    };
}

/// A scroll node's zoom; 1 for other nodes.
pub fn zoomOf(win: *const Window, nid: NodeId) f32 {
    const n = win.node(nid);
    return if (n.kind == .scroll) n.data.scroll.zoom else 1;
}

/// A point in a scroll node's coordinates in its content's (the
/// coordinates its children are placed in).
pub fn toContent(win: *const Window, nid: NodeId, p: Point) Point {
    const n = win.node(nid);
    const s = win.state(nid);
    const t = scrollTranslation(win, nid);
    const z = zoomOf(win, nid);
    return .{ .x = (p.x - n.layout.padding.left(s.rtl) + t.x) / z, .y = (p.y - n.layout.padding.top + t.y) / z };
}

/// A scroll node's offset in physical content coordinates (how far its
/// content is moved up and left), clamped. In RTL, logical offset 0 shows
/// the right edge of the content.
pub fn scrollTranslation(win: *const Window, nid: NodeId) Point {
    const n = win.node(nid);
    if (n.kind != .scroll) return .zero;
    const max = maxScroll(win, nid);
    const off = n.data.scroll.offset;
    const lx = std.math.clamp(off.x, 0, max.x);
    return .{ .x = if (win.state(nid).rtl) max.x - lx else lx, .y = std.math.clamp(off.y, 0, max.y) };
}

/// The logical offset for a physical one reported by the compositor.
pub fn logicalScroll(win: *const Window, nid: NodeId, physical: Point) Point {
    const max = maxScroll(win, nid);
    return .{ .x = if (win.state(nid).rtl) max.x - physical.x else physical.x, .y = physical.y };
}

// Drawing --------------------------------------------------------------------

const DrawError = scene.Error;

/// Where an external node shows its content: its content box, fitted to
/// the content's aspect ratio.
fn externalPlacement(win: *const Window, nid: NodeId) ?compositor.ExternalPlacement {
    const n = win.node(nid);
    const x = n.data.external;
    if (x.id == 0) return null;
    const s = win.state(nid);
    const pad = n.layout.padding;
    const box = Rect.xywh(pad.left(s.rtl), pad.top, s.size.w - pad.horizontal(), s.size.h - pad.vertical());
    if (box.isEmpty()) return null;
    var r = box;
    if (x.width >= 1 and x.height >= 1 and x.fit != .fill) {
        const k = switch (x.fit) {
            .contain => @min(box.width() / x.width, box.height() / x.height),
            .cover => @max(box.width() / x.width, box.height() / x.height),
            .none, .fill => 1,
        };
        const w = x.width * k;
        const h = x.height * k;
        r = .xywh(box.x0 + (box.width() - w) / 2, box.y0 + (box.height() - h) / 2, w, h);
    }
    return .{ .id = x.id, .rect = r, .background = x.background, .box = box };
}

/// Draws a node's own content (not its children) at `off`; returns its
/// bounds in the builder's coordinates.
fn drawNode(st: *State, win: *Window, nid: NodeId, b: *scene.Builder, off: Point) DrawError!Rect {
    const n = win.node(nid);
    const s = win.state(nid);
    const v = n.visual;
    const r = Rect.xywh(off.x, off.y, s.size.w, s.size.h);
    const radii = v.radius.physical(s.rtl);
    const rounded = !v.radius.isZero();
    var bounds = Rect.empty;
    if (!r.isEmpty()) {
        var i = v.shadow_count;
        while (i > 0) {
            i -= 1;
            const sh = v.shadows[i];
            const color = win.palette.pick(sh.color, sh.color_token);
            if (color.a == 0) continue;
            const shadow: scene.Shadow = .{
                .shape = .{ .rect = r, .radii = radii },
                .offset = .{ .x = sh.offset_x, .y = sh.offset_y },
                .sigma = sh.sigma,
                .spread = sh.spread,
                .color = color,
                .inset = sh.inset,
            };
            try b.shadow(shadow);
            bounds = bounds.unite(shadow.bounds());
        }
    }
    const background = win.palette.pick(v.background, v.background_token);
    const border_color = win.palette.pick(v.border_color, v.border_token);
    if (background.a > 0 and !r.isEmpty()) {
        if (rounded) try b.fillRoundedRect(r, radii, .color(background)) else try b.fillRect(r, .color(background));
        bounds = bounds.unite(r);
    }
    if (v.border_width > 0 and border_color.a > 0) {
        const hw = v.border_width / 2;
        const inset: Rect = .{ .x0 = r.x0 + hw, .y0 = r.y0 + hw, .x1 = r.x1 - hw, .y1 = r.y1 - hw };
        if (!inset.isEmpty()) {
            try b.stroke(.{ .rounded_rect = .{ .rect = inset, .radii = shrinkRadii(radii, hw) } }, .{ .width = v.border_width }, .color(border_color));
            bounds = bounds.unite(r);
        }
    }
    switch (n.kind) {
        .text => bounds = bounds.unite(try drawText(st, win, nid, b, off, 0)),
        .editor => {
            try drawEditor(st, win, nid, b, off);
            bounds = bounds.unite(r);
        },
        // SIV_VISUAL_CLIP clips a node's own content too, to its rounded
        // border box: a photo with rounded corners is one image node.
        .image => {
            if (v.clip) try b.pushLayer(.{ .clip = .{ .shape = if (rounded) .{ .rounded_rect = .{ .rect = r, .radii = radii } } else .{ .rect = r } } });
            const drawn = drawImage(win, nid, b, off) catch |err| {
                if (v.clip) b.popLayer() catch {};
                return err;
            };
            if (v.clip) try b.popLayer();
            bounds = bounds.unite(if (v.clip) drawn.intersect(r) else drawn);
        },
        .canvas => if (n.data.canvas.draw) |draw| {
            if (n.data.canvas.banded) try canvasBand(win, nid);
            const box = Rect.xywh(0, 0, s.size.w, s.size.h);
            const shape: scene.Shape = if (v.clip and rounded) .{ .rounded_rect = .{ .rect = box, .radii = radii } } else .{ .rect = box };
            try b.pushLayer(.{ .transform = .translate(off.x, off.y), .clip = .{ .shape = shape } });
            // Keep the builder balanced when the content fails.
            draw(n.data.canvas.user, win, nid, b, s.size.w, s.size.h) catch |err| {
                b.popLayer() catch {};
                return err;
            };
            try b.popLayer();
            bounds = bounds.unite(r);
        },
        else => {},
    }
    if (win.input.focus == nid and win.input.focus_visible and v.focus_ring) {
        const g = focus_ring_width;
        var ring = r.outset(g / 2 + 1);
        // Within its scroll node's content, where the viewport can show
        // it: a row as wide as its view keeps its ring inside its box at
        // the edges instead of losing it to the viewport's clip.
        if (scrollExtent(win, nid, off)) |extent| {
            const inside = ring.intersect(extent.outset(-g / 2));
            if (!inside.isEmpty()) ring = inside;
        }
        try b.stroke(.{ .rounded_rect = .{ .rect = ring, .radii = growRadii(radii, g / 2 + 1) } }, .{ .width = g }, .color(focusRingColor(win)));
        bounds = bounds.unite(ring.outset(g / 2));
    }
    return bounds;
}

/// The extent of the content of `nid`'s nearest scroll ancestor, in the
/// coordinates `nid` paints in at `off`: the content box, or the viewport
/// where the content is smaller. Null outside scroll nodes.
fn scrollExtent(win: *const Window, nid: NodeId, off: Point) ?Rect {
    var p = win.state(nid).pos;
    var cur = win.node(nid).parent;
    while (cur != .none) : (cur = win.node(cur).parent) {
        if (win.node(cur).kind == .scroll) {
            const s = win.state(cur);
            const pad = win.node(cur).layout.padding;
            return .xywh(off.x - p.x, off.y - p.y, @max(s.content.w, s.size.w - pad.horizontal()), @max(s.content.h, s.size.h - pad.vertical()));
        }
        const cs = win.state(cur);
        p.x += cs.pos.x;
        p.y += cs.pos.y;
    }
    return null;
}

fn shrinkRadii(r: raster.Radii, d: f32) raster.Radii {
    return growRadii(r, -d);
}

fn growRadii(r: raster.Radii, d: f32) raster.Radii {
    const f = struct {
        fn g(p: Point, dd: f32) Point {
            if (p.x == 0 and p.y == 0) return p;
            return .{ .x = @max(0, p.x + dd), .y = @max(0, p.y + dd) };
        }
    }.g;
    return .{ .tl = f(r.tl, d), .tr = f(r.tr, d), .br = f(r.br, d), .bl = f(r.bl, d) };
}

/// Selection, text, and (when focused) caret, clipped to the content box
/// and scrolled to keep the caret in view.
fn drawEditor(st: *State, win: *Window, nid: NodeId, b: *scene.Builder, off: Point) DrawError!void {
    const l = text_node.current(win, nid) orelse return;
    const n = win.node(nid);
    const s = win.state(nid);
    const e = n.data.editor;
    const pad = n.layout.padding;
    const cw = s.size.w - pad.horizontal();
    const box = Rect.xywh(off.x + pad.left(s.rtl), off.y + pad.top, cw, s.size.h - pad.vertical());
    editor.scrollToCaret(win, nid);
    const scroll = s.editor_scroll;
    const focused = win.input.focus == nid;
    // A multiline editor's text may hang into its padding (a negative
    // first-line indent: list markers, heading marks); a single-line
    // editor scrolls sideways, so it clips to its content box.
    const clip = if (e.editor.multiline) Rect.xywh(off.x, off.y, s.size.w, s.size.h) else box.outset(layout.caret_width);
    try b.pushLayer(.{ .clip = .{ .shape = .{ .rect = clip } } });
    if (editor.preeditRange(win, nid)) |range| {
        // The preedit is underlined; the selection waits behind it.
        var rects: std.ArrayList(text.layout.Rect) = .empty;
        defer rects.deinit(win.gpa);
        try l.selectionRects(win.gpa, range[0], range[1], &rects, null);
        for (rects.items) |r| {
            const line = try l.line(try l.lineAt(r.y + r.height / 2));
            const x = box.x0 - scroll + r.x + text_node.lineShift(win, nid, line, cw);
            try b.fillRect(.xywh(x, box.y0 + r.y + r.height - 1.5, r.width, 1), .color(textColor(win, &e.text.props.style)));
        }
    } else if (e.caret != e.anchor) {
        var rects: std.ArrayList(text.layout.Rect) = .empty;
        defer rects.deinit(win.gpa);
        // A long text's selection is drawn where its lines are (D13).
        try l.selectionRects(win.gpa, @min(e.caret, e.anchor), @max(e.caret, e.anchor), &rects, try textBand(win, nid, l));
        const color = if (focused) win.palette.color(.selection_bg) else win.palette.color(.control_hover);
        for (rects.items) |r| {
            const line = try l.line(try l.lineAt(r.y + r.height / 2));
            const x = box.x0 - scroll + r.x + text_node.lineShift(win, nid, line, cw);
            try b.fillRect(.xywh(x, box.y0 + r.y, r.width, r.height), .color(color));
        }
    }
    if (e.text.content.len() == 0 and e.placeholder.len != 0 and editor.preeditRange(win, nid) == null) {
        _ = try drawPlaceholder(st, win, nid, b, box);
    } else _ = try drawText(st, win, nid, b, off, -scroll);
    try b.popLayer();
}

/// An empty editor's placeholder, in the muted color, at the start edge.
fn drawPlaceholder(st: *State, win: *Window, nid: NodeId, b: *scene.Builder, box: Rect) DrawError!Rect {
    const l = (text_node.placeholder(win, nid) catch return Rect.empty) orelse return Rect.empty;
    const s = win.state(nid);
    const dx = if (s.rtl) box.width() - l.width() else 0;
    return drawLayout(st, win, l, b, box.x0 + dx, box.y0, box.width(), win.palette.color(.muted_fg), null, null);
}

/// How many halves of a blink (visible to hidden or back) fit in the
/// timeout: an even number, so the caret ends visible.
fn blinkHalves(d: Window.Desktop) u32 {
    const halves = @as(u64, d.cursor_blink_timeout_s) * 2000 / @max(d.cursor_blink_ms, 1);
    return @intCast(@max(2, @min(halves, 1 << 20) & ~@as(u64, 1)));
}

/// A focused editor's caret width, height, color, and whether it is
/// outlined: a block caret is translucent, so the character it covers
/// shows through, and in a selection a faint fill inside a solid outline
/// in the text's color, which stands out from any selection color.
fn caretLook(win: *Window, nid: NodeId) struct { f32, f32, scene.Color, bool } {
    const l = text_node.current(win, nid) orelse return .{ 0, 0, .transparent, false };
    const c = editor.caretRect(win, nid, l) catch return .{ 0, 0, .transparent, false };
    const e = &win.node(nid).data.editor;
    const color = textColor(win, &e.text.props.style);
    const block = e.editor.block_caret and c.width() > layout.caret_width;
    if (!block) return .{ c.width(), c.height(), color, false };
    const in_selection = e.anchor != e.caret and win.ime.preeditFor(nid) == null;
    return .{ c.width(), c.height(), if (in_selection) color else color.withAlpha(color.a * 0.4), in_selection };
}

/// The caret layer's content.
fn drawCaret(b: *scene.Builder, l: *const Layer) !void {
    const w = l.caret_w;
    const h = l.caret_h;
    if (!l.caret_outline) return b.fillRect(.xywh(0, 0, w, h), .color(l.caret_color));
    const c = l.caret_color;
    const t: f32 = @min(1.5, w / 3);
    try b.fillRect(.xywh(0, 0, w, h), .color(c.withAlpha(c.a * 0.15)));
    try b.fillRect(.xywh(0, 0, w, t), .color(c));
    try b.fillRect(.xywh(0, h - t, w, t), .color(c));
    try b.fillRect(.xywh(0, t, t, h - 2 * t), .color(c));
    try b.fillRect(.xywh(w - t, t, t, h - 2 * t), .color(c));
}

/// A text style's color, themed or literal (D29).
pub fn textColor(win: *const Window, style: *const node_mod.TextStyle) scene.Color {
    return win.palette.pick(style.color, style.color_token);
}

/// The theme's focus ring: the desktop's accent, or the toolkit's blue.
fn focusRingColor(win: *const Window) scene.Color {
    return win.palette.color(.focus_ring);
}

fn drawText(st: *State, win: *Window, nid: NodeId, b: *scene.Builder, off: Point, dx: f32) DrawError!Rect {
    const l = text_node.current(win, nid) orelse return Rect.empty;
    const n = win.node(nid);
    const s = win.state(nid);
    const pad = n.layout.padding;
    const content_w = s.size.w - pad.horizontal();
    const ox = off.x + pad.left(s.rtl) + dx;
    const oy = off.y + pad.top;
    const band = try textBand(win, nid, l);
    return drawLayout(st, win, l, b, ox, oy, content_w, textColor(win, &n.textData().props.style), nid, band);
}

/// The band of layout coordinates a text paints: text taller than four
/// viewports of its scroll container paints the lines within a viewport
/// of what it shows, and paints again when scrolling leaves them
/// (`Window.checkCulled`): a keystroke in a long document costs the lines
/// in view, not all of them (D8, D13). Shorter text paints whole (null),
/// so scrolling it never repaints.
fn textBand(win: *Window, nid: NodeId, l: *const text.TextLayout) error{OutOfMemory}!?[2]f32 {
    const s = win.state(nid);
    const pad = win.node(nid).layout.padding;
    s.painted_band = null;
    const shown = visibleBand(win, nid) orelse return null;
    const h = shown[1] - shown[0];
    if (!(h > 0 and l.height() > 4 * h)) return null;
    const around: [2]f32 = .{ shown[0] - h, shown[1] + h };
    s.painted_band = around;
    if (std.mem.indexOfScalar(NodeId, win.culled.items, nid) == null) try win.culled.append(win.gpa, nid);
    return .{ around[0] - pad.top, around[1] - pad.top };
}

/// A banded canvas's band (`Canvas.banded`), like a long text's.
fn canvasBand(win: *Window, nid: NodeId) error{OutOfMemory}!void {
    const s = win.state(nid);
    s.painted_band = null;
    const shown = visibleBand(win, nid) orelse return;
    const h = shown[1] - shown[0];
    if (!(h > 0 and s.size.h > 4 * h)) return;
    s.painted_band = .{ shown[0] - h, shown[1] + h };
    if (std.mem.indexOfScalar(NodeId, win.culled.items, nid) == null) try win.culled.append(win.gpa, nid);
}

/// The band of a node's own y coordinates its nearest scroll container
/// shows now, or null outside any.
pub fn visibleBand(win: *const Window, nid: NodeId) ?[2]f32 {
    var cur = win.node(nid).parent;
    while (cur != .none and win.node(cur).kind != .scroll) cur = win.node(cur).parent;
    if (cur == .none) return null;
    const v = win.viewportOf(cur);
    const top = win.windowRect(cur).y0 + win.node(cur).layout.padding.top;
    const y = win.windowRect(nid).y0 - top;
    const z = zoomOf(win, cur);
    return .{ -y / z, (v.height - y) / z };
}

/// Draws a text layout's glyphs with its box's top left at (ox, oy), only
/// the lines that reach into `band` (layout coordinates) when given.
/// Lines are aligned like the node's when `nid` is given, whose spans
/// (D22) give runs their colors and decorations.
fn drawLayout(st: *State, win: *Window, l: *const text.TextLayout, b: *scene.Builder, ox: f32, oy: f32, content_w: f32, color: scene.Color, nid: ?NodeId, band: ?[2]f32) DrawError!Rect {
    var bounds = Rect.empty;
    const cache = if (nid) |n| win.state(n).text else null;
    const own = if (cache) |c| (if (c.layout) |*cl| cl == l else false) else false;
    const first: u32 = if (band) |bd| l.blockAtY(bd[0]) else 0;
    // Far down a long text, floats are coarser than a pixel: the band's
    // lines go in a layer at its first block's top, placed relative to it
    // in doubles, so that they keep their spacing (D13).
    const origin: f64 = if (band != null and l.tops[first] > far_text) l.tops[first] else 0;
    const shift_y: f32 = @floatCast(origin);
    if (origin != 0) try b.pushLayer(.{ .transform = .translate(0, shift_y) });
    var bi = first;
    // A long text keeps the glyphs of the blocks it paints only (D13).
    defer l.dropGlyphs(first, bi);
    while (bi < l.blocks.len) : (bi += 1) {
        if (band) |bd| if (l.tops[bi] > bd[1]) break;
        const bl = try l.withGlyphs(win.scratch.allocator(), bi);
        // Measuring it may have moved the blocks after it.
        const block_top = l.tops[bi];
        const style_first = l.shaped.style_firsts[bi];
        var li: usize = if (band) |bd| bl.lineAt(@floatCast(bd[0] - block_top)) else 0;
        while (li < bl.lines.len) : (li += 1) {
            const block_line = bl.lines[li];
            if (band) |bd| if (block_top + block_line.top > bd[1]) break;
            const line = l.globalLine(bi, block_line);
            const shift = if (nid) |n| text_node.lineShift(win, n, line, content_w) else 0;
            for (bl.lineRuns(block_line)) |run| {
                const face = win.fonts.cache.face(run.font) orelse continue;
                const sp: node_mod.SpanStyle = if (own) cache.?.runStyle(style_first + run.style) else .{};
                const run_color = if (sp.color_token != .none) win.palette.color(sp.color_token) else sp.color orelse color;
                st.glyphs.clearRetainingCapacity();
                var x0: f32 = std.math.inf(f32);
                var x1: f32 = -std.math.inf(f32);
                const baseline = oy + @as(f32, @floatCast(block_top - origin + block_line.baseline));
                const pen = ox + shift + line.x;
                const glyphs = bl.runGlyphs(run);
                try st.glyphs.ensureUnusedCapacity(win.gpa, glyphs.len);
                for (glyphs) |g| {
                    const x = pen + g.x;
                    x0 = @min(x0, x);
                    x1 = @max(x1, x + g.advance);
                    st.glyphs.appendAssumeCapacity(.{ .id = g.id, .x = x, .y = baseline + g.y });
                }
                // The layout measured the run's ink.
                var rb = if (run.ink.width > 0) Rect.xywh(pen + run.ink.x, baseline + run.ink.y, run.ink.width, run.ink.height) else Rect.empty;
                // Underline below the baseline, strikethrough through the
                // middle of lowercase letters; about a sixteenth of the size
                // thick, at least a pixel.
                if ((sp.underline or sp.strikethrough) and x1 > x0) {
                    // Whole device pixels, so the lines stay crisp.
                    const k: f32 = @floatCast(win.scale);
                    const thick = @max(1, @round(run.size / 16 * k)) / k;
                    for ([_]struct { bool, f32 }{ .{ sp.underline, baseline + run.size / 10 }, .{ sp.strikethrough, baseline - run.size * 0.28 } }) |deco| {
                        if (!deco[0]) continue;
                        const r = Rect.xywh(x0, @round((deco[1] - thick / 2) * k) / k, x1 - x0, thick);
                        try b.fillRect(r, .color(run_color));
                        bounds = bounds.unite(r);
                    }
                }
                if (rb.isEmpty()) continue;
                rb = rb.outset(1);
                try b.glyphs(.{
                    .font = .{ .handle = face.font, .key = face.key },
                    .size = run.size,
                    .glyphs = st.glyphs.items,
                    .paint = .color(run_color),
                    .bounds = rb,
                });
                bounds = bounds.unite(rb);
            }
        }
    }
    if (origin != 0) {
        try b.popLayer();
        if (!bounds.isEmpty()) bounds = .{ .x0 = bounds.x0, .y0 = bounds.y0 + shift_y, .x1 = bounds.x1, .y1 = bounds.y1 + shift_y };
    }
    return bounds;
}

/// Layout coordinates past which a band of a long text is painted
/// relative to its top: floats are a sixteenth of a pixel apart there.
const far_text = 1 << 19;

fn drawImage(win: *Window, nid: NodeId, b: *scene.Builder, off: Point) DrawError!Rect {
    const n = win.node(nid);
    const img = n.data.image;
    const image = win.nodeImage(nid) orelse return Rect.empty;
    const s = win.state(nid);
    const pad = n.layout.padding;
    const box = Rect.xywh(off.x + pad.left(s.rtl), off.y + pad.top, s.size.w - pad.horizontal(), s.size.h - pad.vertical());
    if (box.isEmpty()) return Rect.empty;
    if (image.vector) |doc| {
        // Embedded images' pixels are the document's: the list keeps it.
        if (doc.has_images) {
            const images = &Slot.of(b).images;
            try images.ensureUnusedCapacity(win.gpa, 1);
            images.appendAssumeCapacity(image.retain());
        }
        return drawVector(win, nid, b, doc, image.logicalSize(), box);
    }
    const shown: struct { image: *Image, ref: scene.ImageRef } = if (img.icon.len != 0)
        .{ .image = image, .ref = image.sceneRef() }
    else blk: {
        const sh = win.shownImage(nid).?;
        break :blk .{ .image = sh.image, .ref = sh.ref };
    };
    const ref = shown.ref;
    // Layout is in logical pixels, the source rectangle in image pixels.
    const lw, const lh = image.logicalSize();
    const scale = image.scale;
    var src = Rect.xywh(0, 0, @floatFromInt(ref.width), @floatFromInt(ref.height));
    var dst = box;
    switch (img.fit) {
        .fill => {},
        .contain, .none => {
            const k = if (img.fit == .none) 1 else @min(box.width() / lw, box.height() / lh);
            const w = lw * k;
            const h = lh * k;
            dst = .xywh(box.x0 + (box.width() - w) / 2, box.y0 + (box.height() - h) / 2, w, h);
            if (img.fit == .none) {
                // Crop what does not fit.
                const vis = dst.intersect(box);
                src = .xywh((vis.x0 - dst.x0) * scale, (vis.y0 - dst.y0) * scale, vis.width() * scale, vis.height() * scale);
                dst = vis;
            }
        },
        .cover => {
            const k = @max(box.width() / lw, box.height() / lh);
            const w = box.width() / k;
            const h = box.height() / k;
            src = .xywh((lw - w) / 2 * scale, (lh - h) / 2 * scale, w * scale, h * scale);
        },
    }
    const mirror = img.mirror and s.rtl;
    if (mirror) try b.pushLayer(.{ .transform = raster.Affine.translate(-(dst.x0 + dst.x1) / 2, 0).then(.scale(-1, 1)).then(.translate((dst.x0 + dst.x1) / 2, 0)) });
    // The list keeps the pixels alive until the compositor releases it.
    const images = &Slot.of(b).images;
    try images.ensureUnusedCapacity(win.gpa, 1);
    try b.image(.{ .image = ref, .src = src, .dst = dst, .filter = img.filter });
    images.appendAssumeCapacity(shown.image.retain());
    if (mirror) try b.popLayer();
    return dst;
}

/// A vector image or icon (D19): the document drawn into the node's box
/// as the fit says, its role colors from the theme (the foreground the
/// node's color). The display list copies the paths, so only a document
/// with embedded images, whose pixels it references, is kept alive.
fn drawVector(win: *Window, nid: NodeId, b: *scene.Builder, doc: *const svg.Document, logical: [2]f32, box: Rect) DrawError!Rect {
    const v = win.node(nid).data.image;
    const lw, const lh = logical;
    var dst = box;
    var clip = false;
    switch (v.fit) {
        .fill => {},
        .contain, .none, .cover => {
            const k = switch (v.fit) {
                .none => 1,
                .contain => @min(box.width() / lw, box.height() / lh),
                else => @max(box.width() / lw, box.height() / lh),
            };
            const w = lw * k;
            const h = lh * k;
            dst = .xywh(box.x0 + (box.width() - w) / 2, box.y0 + (box.height() - h) / 2, w, h);
            clip = v.fit != .contain;
        },
    }
    const mirror = v.mirror and win.state(nid).rtl;
    var layer: scene.Layer = .{};
    if (mirror) layer.transform = raster.Affine.translate(-(box.x0 + box.x1) / 2, 0).then(.scale(-1, 1)).then(.translate((box.x0 + box.x1) / 2, 0));
    if (clip) layer.clip = .{ .shape = .{ .rect = box } };
    const pushed = mirror or clip;
    if (pushed) try b.pushLayer(layer);
    var colors: svg.Colors = .{};
    const fg = if (v.color_token != .none) win.palette.color(v.color_token) else if (v.color.a > 0) v.color else win.palette.color(.window_fg);
    iconColors(&colors, &win.palette, fg);
    // A document's own <svg> sizing maps its view box into the box.
    doc.draw(b, dst, if (doc.recolors) &colors else null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    if (pushed) try b.popLayer();
    return if (clip) box else dst;
}

/// The colors symbolic icons and KDE's color scheme classes take (D19):
/// `fg` for the foreground, the theme for the rest.
pub fn iconColors(colors: *svg.Colors, palette: *const theme.Palette, fg: scene.Color) void {
    colors.set(.foreground, fg);
    colors.set(.background, palette.color(.window_bg));
    colors.set(.accent, palette.color(.accent));
    colors.set(.accent_foreground, palette.color(.accent_fg));
    colors.set(.success, palette.color(.success));
    colors.set(.warning, palette.color(.warning));
    colors.set(.@"error", palette.color(.destructive));
}
