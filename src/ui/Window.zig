//! One window's retained tree and everything derived from it on the UI
//! thread: layout, layers, input routing, focus, and semantics.
//!
//! The tree changes only through transactions (`begin`, D4). A frame
//! (`frame`) lays out what changed, repaints the layers whose content
//! changed, and sends the layer tree to the compositor through `Sink`
//! (D8). Platform events go to `handleEvent`, in the loop's dispatch
//! phase (D5).
//!
//! Nodes are plain indices (D20). Removed nodes are recycled after the
//! next frame, so an index held while events are dispatched never names a
//! different node.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const text = @import("text");
const platform = @import("platform");
const compositor = @import("compositor");

const node_mod = @import("node.zig");
const Fonts = @import("fonts.zig");
const Txn = @import("txn.zig").Txn;
const layout = @import("layout.zig");
const paint_mod = @import("paint.zig");
const layers = @import("layers.zig");
const input_mod = @import("input.zig");
const semantics_mod = @import("semantics.zig");
const text_node = @import("text_node.zig");

const Window = @This();

pub const NodeId = node_mod.NodeId;
pub const Node = node_mod.Node;
pub const Kind = node_mod.Kind;
const Point = raster.Point;
const Rect = raster.Rect;

pub const Error = error{OutOfMemory};

gpa: std.mem.Allocator,
fonts: *Fonts,
nodes: std.ArrayList(Node) = .empty,
states: std.ArrayList(State) = .empty,
free_head: NodeId = .none,
/// Removed nodes waiting for the next frame to be recycled.
dead: std.ArrayList(NodeId) = .empty,
txn: Txn = .{},

/// Logical size and buffer scale, from the last configure.
width: f32,
height: f32,
scale: f32 = 1,
/// Direction of the window's locale; nodes inherit it (D21).
rtl: bool = false,
/// Interned window language (Fonts names).
language: u32 = 0,
/// Serial of the last configure, until a commit acknowledges it.
configure_serial: ?u64 = null,

sink: layers.Sink,
host: Host,

dirty: Dirty = .{},
/// Per-frame scratch memory, reset after each frame (capacity kept).
scratch: std.heap.ArenaAllocator,
paint: paint_mod.State = .{},
input: input_mod.State = .{},
semantics: semantics_mod.Tree = .{},
stats: Stats = .{},

/// What the window needs from its owner.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// Asks for a frame; the owner calls `frame` when it comes.
    request_frame: *const fn (ctx: ?*anyopaque) void = noop,

    fn noop(_: ?*anyopaque) void {}
};

pub const Options = struct {
    fonts: *Fonts,
    sink: layers.Sink,
    host: Host = .{},
    width: f32 = 640,
    height: f32 = 480,
    scale: f32 = 1,
    rtl: bool = false,
    language: []const u8 = "",
};

/// Window-wide work outstanding for the next frame.
pub const Dirty = struct {
    /// Layer assignment (structure or layer-making properties changed).
    layers: bool = true,
    /// Some layer property (scroll offset, opacity, transform) changed.
    props: bool = true,
    semantics: bool = true,
};

/// Counters for tests and the inspector.
pub const Stats = struct {
    frames: u64 = 0,
    /// Nodes laid out (cache misses).
    layouts: u64 = 0,
    /// ShapedParagraph builds.
    shapes: u64 = 0,
    /// Text Layout builds.
    text_layouts: u64 = 0,
    /// Layer contents rebuilt.
    layer_builds: u64 = 0,
};

pub const Size = layout.Size;
pub const Constraints = layout.Constraints;

/// Derived per-node state; never part of a transaction's snapshot, so an
/// aborted transaction can only leave extra dirty flags behind.
pub const State = struct {
    touched: u32 = 0,
    // Layout.
    needs_layout: bool = true,
    needs_shape: bool = false,
    rtl: bool = false,
    cache: [2]?layout.Cached = .{ null, null },
    final: ?Constraints = null,
    /// Max-content width, or negative when unknown.
    max_content: f32 = -1,
    /// Position in the parent's coordinates (a scroll's children: its
    /// content coordinates), and border-box size.
    pos: Point = .zero,
    size: Size = .{},
    /// Scroll: content size; grid items: their cell.
    content: Size = .{},
    cell: layout.Cell = .{},
    text: ?*text_node.Cache = null,
    /// Scroll: the node's offset changed and the compositor must be told.
    scroll_pending: bool = false,
    /// Editor: horizontal scroll of a single line that keeps the caret in
    /// view, and the x that vertical caret movement aims for.
    editor_scroll: f32 = 0,
    preferred_x: ?f32 = null,
    // Paint.
    paint_dirty: bool = true,
    /// Layer that receives the node's own painting.
    layer: u32 = paint_mod.no_layer,
    /// Layer the node roots.
    own_layer: u32 = paint_mod.no_layer,
    /// Scroll: the layer of its scrolled content.
    content_layer: u32 = paint_mod.no_layer,
    /// Layer for content painted after the node's layer subtree.
    chunk_layer: u32 = paint_mod.no_layer,
    /// What the node painted last, in its layer's coordinates.
    bounds: Rect = Rect.empty,
};

pub fn init(gpa: std.mem.Allocator, options: Options) Error!*Window {
    const win = try gpa.create(Window);
    errdefer gpa.destroy(win);
    win.* = .{
        .gpa = gpa,
        .fonts = options.fonts,
        .width = options.width,
        .height = options.height,
        .scale = options.scale,
        .rtl = options.rtl,
        .sink = options.sink,
        .host = options.host,
        .scratch = .init(gpa),
    };
    errdefer win.deinitStorage();
    win.language = try options.fonts.intern(options.language);
    try win.nodes.append(gpa, .{ .kind = .stack, .data = .{ .stack = .{ .align_x = .stretch, .align_y = .stretch } } });
    win.nodes.items[0].semantics.role = .window;
    try win.states.append(gpa, .{});
    try win.paint.init(win);
    try options.fonts.addListener(.{ .ctx = win, .func = onFontsLoaded });
    return win;
}

pub fn deinit(win: *Window) void {
    std.debug.assert(!win.txn.open);
    win.fonts.removeListener(win);
    win.deinitStorage();
    win.gpa.destroy(win);
}

fn deinitStorage(win: *Window) void {
    for (win.nodes.items, win.states.items) |*n, *s| {
        if (n.status != .free) freeNodeData(win.gpa, n);
        if (s.text) |c| c.destroy(win.gpa);
    }
    win.nodes.deinit(win.gpa);
    win.states.deinit(win.gpa);
    win.dead.deinit(win.gpa);
    win.txn.deinit(win.gpa);
    win.paint.deinit(win.gpa);
    win.input.deinit(win.gpa);
    win.semantics.deinit(win.gpa);
    win.scratch.deinit();
}

/// Frees what a node owns (text, tracks, strings).
pub fn freeNodeData(gpa: std.mem.Allocator, n: *const Node) void {
    gpa.free(n.semantics.label);
    gpa.free(n.semantics.description);
    switch (n.data) {
        .text => |t| gpa.free(t.content),
        .editor => |e| gpa.free(e.text.content),
        .grid => |g| {
            gpa.free(g.columns);
            gpa.free(g.rows);
        },
        else => {},
    }
}

// Tree access ---------------------------------------------------------------

pub fn node(win: *const Window, id: NodeId) *Node {
    return &win.nodes.items[id.index()];
}

pub fn state(win: *const Window, id: NodeId) *State {
    return &win.states.items[id.index()];
}

/// Whether `id` names a node in the tree (live, or created by the open
/// transaction).
pub fn isLive(win: *const Window, id: NodeId) bool {
    return id != .none and id.index() < win.nodes.items.len and win.node(id).status == .live;
}

pub const Children = struct {
    win: *const Window,
    cur: NodeId,

    pub fn next(it: *Children) ?NodeId {
        const id = it.cur;
        if (id == .none) return null;
        it.cur = it.win.node(id).next;
        return id;
    }
};

pub fn children(win: *const Window, id: NodeId) Children {
    return .{ .win = win, .cur = win.node(id).first };
}

pub fn isAncestor(win: *const Window, ancestor: NodeId, id: NodeId) bool {
    var cur = id;
    while (cur != .none) : (cur = win.node(cur).parent) {
        if (cur == ancestor) return true;
    }
    return false;
}

/// The node's top-left corner in window coordinates (ignoring transforms
/// other than translation), and its size.
pub fn windowRect(win: *const Window, id: NodeId) Rect {
    const s = win.state(id);
    var p = s.pos;
    var cur = win.node(id).parent;
    while (cur != .none) : (cur = win.node(cur).parent) {
        const n = win.node(cur);
        const cs = win.state(cur);
        if (n.kind == .scroll) {
            const pad = n.layout.padding;
            p.x += pad.left(cs.rtl) - paint_mod.scrollTranslation(win, cur).x;
            p.y += pad.top - paint_mod.scrollTranslation(win, cur).y;
        }
        const t = n.visual.transform;
        if (!t.eql(.identity)) p = t.affine().apply(p);
        p.x += cs.pos.x;
        p.y += cs.pos.y;
    }
    return .xywh(p.x, p.y, s.size.w, s.size.h);
}

// Dirty marking -------------------------------------------------------------

/// The node must be laid out again, and so must its ancestors (their size
/// may depend on it).
pub fn markLayout(win: *Window, id: NodeId) void {
    var cur = id;
    while (cur != .none) {
        const s = win.state(cur);
        if (s.needs_layout and cur != id) break;
        s.needs_layout = true;
        s.max_content = -1;
        cur = win.node(cur).parent;
    }
    win.dirty.semantics = true;
}

/// Marks the node and its whole subtree for layout (direction changes).
pub fn markSubtreeLayout(win: *Window, id: NodeId) void {
    win.markLayout(id);
    var it = win.children(id);
    while (it.next()) |c| {
        const s = win.state(c);
        s.needs_layout = true;
        s.max_content = -1;
        if (win.node(c).isText()) s.needs_shape = true;
        win.markSubtreeLayout(c);
    }
}

/// The node's own painting changed; its layer repaints.
pub fn markPaint(win: *Window, id: NodeId) void {
    const s = win.state(id);
    s.paint_dirty = true;
    win.paint.markLayer(s.layer);
}

pub fn markShape(win: *Window, id: NodeId) void {
    win.state(id).needs_shape = true;
    win.markLayout(id);
}

pub fn markLayers(win: *Window) void {
    win.dirty.layers = true;
}

/// Whether a frame has work to do.
pub fn needsFrame(win: *const Window) bool {
    return win.state(.root).needs_layout or win.dirty.layers or win.dirty.props or
        win.dirty.semantics or win.paint.anyDirty();
}

pub fn requestFrame(win: *Window) void {
    if (win.needsFrame()) win.host.request_frame(win.host.ctx);
}

// Transactions --------------------------------------------------------------

/// Starts a transaction. Only one can be open; frames wait until it is
/// committed or aborted.
pub fn begin(win: *Window) error{ OutOfMemory, TransactionOpen }!*Txn {
    if (win.txn.open) return error.TransactionOpen;
    win.txn.start(win);
    return &win.txn;
}

// Window state --------------------------------------------------------------

/// A new logical size or scale. Configures from the compositor go
/// through `handleEvent`, which also acknowledges them.
pub fn configure(win: *Window, width: f32, height: f32, scale: f32) void {
    if (width != win.width or height != win.height) {
        win.width = width;
        win.height = height;
        win.markLayout(.root);
    }
    if (scale != win.scale) {
        win.scale = scale;
        win.dirty.props = true;
    }
    if (win.configure_serial != null) win.dirty.props = true;
    win.requestFrame();
}

/// Sets the locale direction every node inherits (D21).
pub fn setRtl(win: *Window, rtl: bool) void {
    if (win.rtl == rtl) return;
    win.rtl = rtl;
    win.markSubtreeLayout(.root);
    win.requestFrame();
}

// Frames --------------------------------------------------------------------

/// Lays out, repaints, and sends the layer tree. Does nothing while a
/// transaction is open (its commit requests another frame).
pub fn frame(win: *Window) Error!void {
    if (win.txn.open) return;
    win.recycleDead();
    defer _ = win.scratch.reset(.retain_capacity);
    try layout.run(win);
    if (win.dirty.layers) {
        try win.paint.assign(win);
        win.dirty.layers = false;
    }
    try win.paint.build(win);
    try win.paint.emit(win);
    win.dirty.props = false;
    if (win.dirty.semantics) {
        try win.semantics.rebuild(win);
        win.dirty.semantics = false;
    }
    win.stats.frames += 1;
}

fn recycleDead(win: *Window) void {
    for (win.dead.items) |id| {
        const n = win.node(id);
        n.* = .{ .kind = .box, .status = .free, .next = win.free_head, .data = .{ .box = {} } };
        const s = win.state(id);
        if (s.text) |c| c.destroy(win.gpa);
        s.* = .{};
        win.free_head = id;
    }
    win.dead.clearRetainingCapacity();
}

/// Removed nodes: clear input state that refers to them and damage their
/// layers. Called by the transaction at commit, before they are marked dead.
pub fn forget(win: *Window, id: NodeId) void {
    win.input.forget(win, id);
    const s = win.state(id);
    win.paint.damage(s.layer, s.bounds);
}

// Events --------------------------------------------------------------------

/// Handles an event the compositor sent for this window (D8): platform
/// input and configures, frames, scroll offsets it changed, and released
/// builders. Call in the dispatch phase (D5).
pub fn handleEvent(win: *Window, event: *const compositor.Event) Error!void {
    switch (event.*) {
        .platform => |*p| win.handlePlatform(p),
        .configure => |c| {
            win.configure_serial = c.serial;
            win.configure(@floatFromInt(c.state.width), @floatFromInt(c.state.height), @floatCast(c.state.scale.toFloat()));
        },
        .frame => try win.frame(),
        .scrolled => |s| win.scrolled(s.layer, s.offset, s.seq),
        .released => |b| win.paint.released(win.gpa, b),
        .presented, .animation_finished => {},
    }
}

/// Whether a builder in `Event.released` belongs to this window.
pub fn ownsBuilder(win: *const Window, b: *const scene.Builder) bool {
    for (win.paint.all_builders.items) |own| if (own == b) return true;
    return false;
}

/// A forwarded platform event for this window: pointer, keyboard, touch,
/// and scroll input the compositor did not consume.
pub fn handlePlatform(win: *Window, event: *const platform.Event) void {
    input_mod.handle(win, event);
}

/// The compositor scrolled a container. Reports older than the UI's own
/// last `scroll_to` for it are stale.
fn scrolled(win: *Window, layer: compositor.LayerId, offset: Point, seq: u64) void {
    const index = paint_mod.indexOf(layer);
    if (index >= win.paint.layers.items.len) return;
    const l = &win.paint.layers.items[index];
    if (seq < l.scroll_seq or !win.isLive(l.owner) or win.node(l.owner).kind != .scroll) return;
    if (!win.paint.ownsLayerNow(win, l.owner)) return;
    l.scroll_offset = offset;
    win.node(l.owner).data.scroll.offset = paint_mod.logicalScroll(win, l.owner, offset);
    win.dirty.semantics = true;
    win.requestFrame();
}

fn onFontsLoaded(ctx: *anyopaque) void {
    const win: *Window = @ptrCast(@alignCast(ctx));
    for (win.nodes.items, win.states.items, 0..) |*n, s, i| {
        if (n.status != .live or !n.isText()) continue;
        const c = s.text orelse continue;
        if (c.waiting(win.fonts)) win.markShape(@enumFromInt(i));
    }
    win.requestFrame();
}
