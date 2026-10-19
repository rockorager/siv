//! The inspector's hooks in a window (D46): overlays over the window's
//! content, picking a node by pointing at it, and the nodes a frame
//! repainted. The inspector itself is a stock widget on the public API;
//! this is what it needs from inside the tree.
//!
//! The overlays are layers of their own above every other (paint.zig):
//! the highlighted node's border, padding, and content boxes, every
//! shown node's border box (bounds), and the boxes of the nodes the last
//! frame repainted (repaints), which fade out on the compositor.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const platform = @import("platform");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const input = @import("input.zig");

const NodeId = node_mod.NodeId;
const Point = raster.Point;
const Rect = raster.Rect;

pub const Event = enum { hovered, picked };

/// Tells the owner what picking found: the node under the pointer as it
/// moves, and the node a press picked (none when picking was cancelled).
/// Runs in the dispatch phase, like a node handler.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, win: *Window, event: Event, node: NodeId) void,
};

pub const Overlay = struct {
    /// Outline every shown node's border box.
    bounds: bool = false,
    /// Flash the boxes of the nodes each frame repaints.
    repaints: bool = false,
    /// Pointer input picks nodes instead of reaching the tree.
    pick: bool = false,
};

pub const State = struct {
    highlight: NodeId = .none,
    overlay: Overlay = .{},
    /// Picking: the node under the pointer, highlighted instead.
    hovered: NodeId = .none,
    /// A press picked a node: its release goes nowhere either.
    swallow: bool = false,
    host: ?Host = null,
    /// Repaints: nodes the frame being built repainted, and the boxes of
    /// the last frame that repainted any (window coordinates).
    damaged: std.ArrayList(NodeId) = .empty,
    flashes: std.ArrayList(Rect) = .empty,
    /// Bumped when `flashes` changes, which restarts their fade.
    flash_serial: u32 = 0,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.damaged.deinit(gpa);
        s.flashes.deinit(gpa);
    }

    /// Whether the overlay layer shows anything.
    pub fn overlaid(s: *const State) bool {
        return s.highlight != .none or s.overlay.bounds or s.overlay.pick;
    }
};

/// Highlights a node (none for none) and sets the overlays.
pub fn set(win: *Window, highlight: NodeId, overlay: Overlay) void {
    const s = &win.inspect;
    const was_picking = s.overlay.pick;
    s.highlight = highlight;
    s.overlay = overlay;
    if (!overlay.pick) s.hovered = .none;
    if (overlay.pick and !was_picking) {
        s.hovered = if (win.input.pointer) |p| nodeAt(win, p) else .none;
    }
    if (!overlay.repaints) {
        s.damaged.clearRetainingCapacity();
        s.flashes.clearRetainingCapacity();
    }
    win.markLayers();
    win.requestFrame();
}

/// The node a removed one was: highlights and picks of it go.
pub fn forget(win: *Window, id: NodeId) void {
    const s = &win.inspect;
    if (s.highlight == id) s.highlight = .none;
    if (s.hovered == id) s.hovered = .none;
}

/// The deepest shown node whose border box holds a window point, the
/// topmost of siblings, whether or not it takes pointer input; the root
/// when no other does.
pub fn nodeAt(win: *const Window, p: Point) NodeId {
    return input.hitAll(win, p) orelse .root;
}

/// Pointer input while picking; true when it was used here.
pub fn pointer(win: *Window, event: *const platform.Event) bool {
    const s = &win.inspect;
    switch (event.*) {
        .pointer_enter, .pointer_motion => |m| {
            if (!s.overlay.pick) return false;
            const p: Point = .{ .x = @floatCast(m.x), .y = @floatCast(m.y) };
            win.input.pointer = p;
            const id = nodeAt(win, p);
            if (id == s.hovered) return true;
            s.hovered = id;
            win.requestFrame();
            if (s.host) |h| h.func(h.ctx, win, .hovered, id);
            return true;
        },
        .pointer_button => |b| {
            if (s.swallow and !b.pressed) {
                s.swallow = false;
                return true;
            }
            if (!s.overlay.pick or !b.pressed) return false;
            const id = if (win.input.pointer) |p| nodeAt(win, p) else s.hovered;
            s.overlay.pick = false;
            s.hovered = .none;
            s.highlight = id;
            s.swallow = true;
            win.markLayers();
            win.requestFrame();
            if (s.host) |h| h.func(h.ctx, win, .picked, id);
            return true;
        },
        else => return false,
    }
}

/// Escape while picking cancels it; true when it did.
pub fn cancelKey(win: *Window, k: *const platform.Key) bool {
    const s = &win.inspect;
    if (!s.overlay.pick or k.keysym != 0xff1b) return false;
    if (k.state == .pressed) {
        s.overlay.pick = false;
        s.hovered = .none;
        win.markLayers();
        win.requestFrame();
        if (s.host) |h| h.func(h.ctx, win, .picked, .none);
    }
    return true;
}

// Drawing ----------------------------------------------------------------------

const bounds_color = scene.Color.srgb8(0xd9, 0x46, 0xef, 0xcc);
const border_color = scene.Color.srgb8(0x25, 0x63, 0xeb, 0xff);
const padding_color = scene.Color.srgb8(0x22, 0xc5, 0x5e, 0x55);
const content_color = scene.Color.srgb8(0x3b, 0x82, 0xf6, 0x55);
const flash_color = scene.Color.srgb8(0xef, 0x44, 0x44, 0x60);

/// The overlay layer's content, in window coordinates.
pub fn draw(win: *Window, b: *scene.Builder) scene.Error!void {
    const s = &win.inspect;
    if (s.overlay.bounds) {
        var it = win.shown(.root);
        while (it.next()) |ch| try drawBounds(win, b, ch);
    }
    const target = if (s.overlay.pick) s.hovered else s.highlight;
    if (target == .none or !win.isLive(target) or !win.isShown(target)) return;
    const r, const content = boxes(win, target);
    // The padding: the border box around the content box.
    try b.fillRect(.{ .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = content.y0 }, .color(padding_color));
    try b.fillRect(.{ .x0 = r.x0, .y0 = content.y1, .x1 = r.x1, .y1 = r.y1 }, .color(padding_color));
    try b.fillRect(.{ .x0 = r.x0, .y0 = content.y0, .x1 = content.x0, .y1 = content.y1 }, .color(padding_color));
    try b.fillRect(.{ .x0 = content.x1, .y0 = content.y0, .x1 = r.x1, .y1 = content.y1 }, .color(padding_color));
    try b.fillRect(content, .color(content_color));
    try outline(b, r, border_color);
}

/// A node's border box and content box (less its padding), in window
/// coordinates as of the last frame.
pub fn boxes(win: *const Window, id: NodeId) [2]Rect {
    const r = win.windowRect(id);
    const n = win.node(id);
    const st = win.state(id);
    // Zoomed scroll containers above scale the box.
    const k: f32 = if (st.size.w > 0) (r.x1 - r.x0) / st.size.w else 1;
    const pad = n.layout.padding;
    const left = pad.left(st.rtl) * k;
    const right = (if (st.rtl) pad.start else pad.end) * k;
    return .{ r, .{
        .x0 = r.x0 + left,
        .y0 = r.y0 + pad.top * k,
        .x1 = @max(r.x0 + left, r.x1 - right),
        .y1 = @max(r.y0 + pad.top * k, r.y1 - pad.bottom * k),
    } };
}

/// Outlines a node's border box and its shown descendants', clipped
/// where the node clips them.
fn drawBounds(win: *Window, b: *scene.Builder, id: NodeId) scene.Error!void {
    const r = win.windowRect(id);
    try outline(b, r, bounds_color);
    const n = win.node(id);
    const clips = n.visual.clip or n.kind == .scroll;
    if (clips) try b.pushLayer(.{ .clip = .{ .shape = .{ .rect = r } } });
    var it = win.shown(id);
    while (it.next()) |ch| try drawBounds(win, b, ch);
    if (clips) try b.popLayer();
}

/// A one-pixel line just inside a rectangle.
fn outline(b: *scene.Builder, r: Rect, col: scene.Color) scene.Error!void {
    if (r.x1 - r.x0 <= 0 or r.y1 - r.y0 <= 0) return;
    const t = @min(1, @min(r.x1 - r.x0, r.y1 - r.y0) / 2);
    try b.fillRect(.{ .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = r.y0 + t }, .color(col));
    try b.fillRect(.{ .x0 = r.x0, .y0 = r.y1 - t, .x1 = r.x1, .y1 = r.y1 }, .color(col));
    try b.fillRect(.{ .x0 = r.x0, .y0 = r.y0 + t, .x1 = r.x0 + t, .y1 = r.y1 - t }, .color(col));
    try b.fillRect(.{ .x0 = r.x1 - t, .y0 = r.y0 + t, .x1 = r.x1, .y1 = r.y1 - t }, .color(col));
}

/// After a frame's layers were built: the nodes it repainted become the
/// flashes, unless it repainted none. Returns whether they changed.
pub fn takeDamage(win: *Window) error{OutOfMemory}!bool {
    const s = &win.inspect;
    defer s.damaged.clearRetainingCapacity();
    if (!s.overlay.repaints or s.damaged.items.len == 0) return false;
    s.flashes.clearRetainingCapacity();
    try s.flashes.ensureTotalCapacity(win.gpa, s.damaged.items.len);
    for (s.damaged.items) |id| {
        if (!win.isLive(id) or !win.isShown(id)) continue;
        const r = win.windowRect(id);
        if (r.x1 > r.x0 and r.y1 > r.y0) s.flashes.appendAssumeCapacity(r);
    }
    s.flash_serial +%= 1;
    return true;
}

/// The flash layer's content.
pub fn drawFlashes(win: *Window, b: *scene.Builder) scene.Error!void {
    for (win.inspect.flashes.items) |r| try b.fillRect(r, .color(flash_color));
}

/// A node's own painting changed in the layer being built (paint.zig).
pub fn noteDamage(win: *Window, id: NodeId) void {
    const s = &win.inspect;
    if (!s.overlay.repaints) return;
    // Without memory, a node does not flash.
    s.damaged.append(win.gpa, id) catch {};
}
