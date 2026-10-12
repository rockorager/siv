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
const editor_mod = @import("editor.zig");
const Image = @import("image.zig").Image;
const secret = @import("secret.zig");
const ime_mod = @import("ime.zig");
pub const Clipboard = @import("clipboard.zig");
const dnd_mod = @import("dnd.zig");
pub const theme = @import("theme.zig");

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
/// Input that arrived while the application held a transaction open (or
/// behind such input), replayed in order at the next frame: user input is
/// never lost.
pending_input: std.ArrayList(platform.Event) = .empty,
/// Undo histories of editors, by node.
histories: std.AutoHashMapUnmanaged(NodeId, editor_mod.History) = .empty,
/// The application turned motion off, whatever the desktop says.
force_reduced_motion: bool = false,
/// Desktop settings (D19), from `setDesktop`.
desktop: Desktop = .{},
/// The application's theme choices (D29), from `setTheme`.
theme_choice: theme.Theme = .{},
/// Themed colors and sizes, resolved from `desktop` and `theme_choice`.
palette: theme.Palette = .{},
/// Nodes made modal, in that order (some may be gone or no longer modal).
modals: std.ArrayList(NodeId) = .empty,
/// Scroll nodes with viewport handlers (some may be gone), and whether
/// layout changed one's viewport since it was last told.
viewports: std.ArrayList(NodeId) = .empty,
viewport_dirty: bool = false,
/// The application's clipboard, if it has one.
clipboard: ?*Clipboard = null,
/// Drag-and-drop requests; without them drags neither start nor drop.
drag_host: ?dnd_mod.Host = null,
dnd: dnd_mod.State = .{},
/// A cursor for the whole window over every node's, such as a busy
/// cursor; null for none.
cursor_override: ?node_mod.CursorShape = null,
/// The cursor last sent to the platform.
cursor_shown: node_mod.CursorShape = .default,
/// Pastes and assistive technology edits that arrived while a transaction
/// was open, applied in order at the next frame like queued input.
pending_edits: std.ArrayList(editor_mod.Pending) = .empty,
/// What this window last offered as the primary selection.
primary: struct { node: NodeId = .none, lo: u32 = 0, hi: u32 = 0, revision: u32 = 0 } = .{},
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
ime: ime_mod.State = .{},
semantics: semantics_mod.Tree = .{},
stats: Stats = .{},

/// What the window needs from its owner.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// Asks for a frame; the owner calls `frame` when it comes.
    request_frame: *const fn (ctx: ?*anyopaque) void = noop,
    /// Sends a seat's text input state (text-input-v3). Run it on the
    /// compositor thread with `Compositor.post` and
    /// `Platform.setTextInput`, copying `state.surrounding`.
    text_input: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, state: *const platform.TextInputState) void = noopTextInput,
    /// Sets the window's pointer cursor (D16). Run it on the compositor
    /// thread with `Compositor.post` and `Platform.setCursor`.
    set_cursor: *const fn (ctx: ?*anyopaque, shape: node_mod.CursorShape) void = noopCursor,

    fn noop(_: ?*anyopaque) void {}
    fn noopTextInput(_: ?*anyopaque, _: platform.SeatId, _: *const platform.TextInputState) void {}
    fn noopCursor(_: ?*anyopaque, _: node_mod.CursorShape) void {}
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
    /// No caret blinking or other motion, whatever `desktop` says.
    reduced_motion: bool = false,
    desktop: Desktop = .{},
    theme: theme.Theme = .{},
    clipboard: ?*Clipboard = null,
    /// Drag and drop (`dnd.CompositorHost`); needs `clipboard` too.
    drag: ?dnd_mod.Host = null,
};

/// The desktop settings the UI follows (D19). The fields have the names
/// and types of `dbus.Settings.Values`, so the application copies them
/// from there and applies them with `setDesktop`. The defaults are GTK's.
pub const Desktop = struct {
    /// No caret blinking or other motion.
    reduced_motion: bool = false,
    /// sRGB components in [0, 1] for the focus ring and selection, or null
    /// for the toolkit's blue.
    accent_color: ?[3]f64 = null,
    /// Multiplies every text size.
    text_scale: f64 = 1.0,
    /// Most time between the presses of a double or triple click.
    double_click_ms: u32 = 400,
    cursor_blink: bool = true,
    /// One whole blink cycle, shown and hidden, in milliseconds.
    cursor_blink_ms: u32 = 1200,
    /// The caret stops blinking, visible, this long after it last moved.
    cursor_blink_timeout_s: u32 = 10,
    /// The theme's scheme and contrast follow these (D29).
    color_scheme: ColorScheme = .no_preference,
    contrast: Contrast = .normal,
    /// The UI font's size in points; themed text sizes follow it.
    font_size: f64 = 11,

    pub const ColorScheme = enum { no_preference, dark, light };
    pub const Contrast = enum { normal, high };

    pub fn themeInput(d: Desktop) theme.DesktopInput {
        return .{ .dark = d.color_scheme == .dark, .high_contrast = d.contrast == .high, .accent = d.accent_color, .font_pt = d.font_size };
    }
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
    /// Scroll nodes with a viewport handler: what it was last told.
    viewport: ?node_mod.Viewport = null,
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
        .force_reduced_motion = options.reduced_motion,
        .desktop = options.desktop,
        .theme_choice = options.theme,
        .palette = theme.resolve(&options.theme, options.desktop.themeInput()),
        .clipboard = options.clipboard,
        .drag_host = options.drag,
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
    win.dnd.deinit(win);
    if (win.clipboard) |cb| {
        cb.cancel(win);
        cb.cancel(&win.dnd);
        cb.forgetWindow(win);
    }
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
    for (win.pending_input.items) |*ev| std.crypto.secureZero(u8, std.mem.asBytes(ev));
    win.pending_input.deinit(win.gpa);
    for (win.pending_edits.items) |p| p.deinit(win.gpa);
    win.pending_edits.deinit(win.gpa);
    var hist = win.histories.valueIterator();
    while (hist.next()) |h| h.deinit(win.gpa);
    win.histories.deinit(win.gpa);
    win.txn.deinit(win.gpa);
    win.paint.deinit(win.gpa);
    win.input.deinit(win.gpa);
    win.ime.deinit(win.gpa);
    win.semantics.deinit(win.gpa);
    win.viewports.deinit(win.gpa);
    win.modals.deinit(win.gpa);
    win.scratch.deinit();
}

/// Frees what a node owns (text, tracks, strings).
pub fn freeNodeData(gpa: std.mem.Allocator, n: *const Node) void {
    gpa.free(n.semantics.label);
    gpa.free(n.semantics.description);
    gpa.free(n.drop.mimes);
    switch (n.data) {
        .text => |t| gpa.free(t.content),
        .editor => |e| {
            gpa.free(e.text.content);
            gpa.free(e.placeholder);
            secret.free(e.secret);
        },
        .grid => |g| {
            gpa.free(g.columns);
            gpa.free(g.rows);
        },
        .image => |v| if (v.image) |img| img.release(),
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

/// Children that are not hidden: what layout, painting, hit testing,
/// focus, and semantics see.
pub const Shown = struct {
    win: *const Window,
    cur: NodeId,

    pub fn next(it: *Shown) ?NodeId {
        while (it.cur != .none) {
            const id = it.cur;
            const n = it.win.node(id);
            it.cur = n.next;
            if (!n.visual.hidden) return id;
        }
        return null;
    }
};

pub fn shown(win: *const Window, id: NodeId) Shown {
    return .{ .win = win, .cur = win.node(id).first };
}

/// Whether neither the node nor an ancestor is hidden.
pub fn isShown(win: *const Window, id: NodeId) bool {
    var cur = id;
    while (cur != .none) : (cur = win.node(cur).parent) {
        if (win.node(cur).visual.hidden) return false;
    }
    return true;
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
    // Semantics alone need no frame: they rebuild on query or with the
    // next frame (`semanticsTree`), so scrolling makes no extra frames.
    return win.state(.root).needs_layout or win.dirty.layers or win.dirty.props or win.viewport_dirty or
        win.paint.anyDirty() or win.pending_input.items.len != 0 or win.ime.dirty or win.pending_edits.items.len != 0 or
        win.dnd.pending != null;
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
    win.replayInput();
    if (win.txn.open) return;
    // Rows a viewport handler adds are laid out in this frame.
    win.viewport_dirty = false;
    win.deliverViewports();
    if (win.txn.open) return;
    defer _ = win.scratch.reset(.retain_capacity);
    const laid_out = win.state(.root).needs_layout;
    try layout.run(win);
    if (laid_out) win.checkViewports();
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
    ime_mod.sync(win);
    editor_mod.updatePrimary(win);
    // The tree may have changed under a pointer that did not move.
    input_mod.updateCursor(win);
    win.stats.frames += 1;
}

/// The node's visible region: its logical scroll offset and the size of
/// its content box.
pub fn viewportOf(win: *const Window, id: NodeId) node_mod.Viewport {
    const n = win.node(id);
    const s = win.state(id);
    const pad = n.layout.padding;
    return .{
        .x = n.data.scroll.offset.x,
        .y = n.data.scroll.offset.y,
        .width = @max(0, s.size.w - pad.horizontal()),
        .height = @max(0, s.size.h - pad.vertical()),
    };
}

/// Tells viewport handlers whose node's visible region changed since
/// they were last told. Handlers run here (D5: a safe point, like replayed
/// input) and may change the tree.
pub fn deliverViewports(win: *Window) void {
    var i: usize = 0;
    while (i < win.viewports.items.len) {
        const id = win.viewports.items[i];
        if (!win.isLive(id) or win.node(id).kind != .scroll or win.node(id).handler(.viewport) == null) {
            _ = win.viewports.swapRemove(i);
            continue;
        }
        i += 1;
        // Not laid out yet: there is no viewport to tell of.
        if (!win.isShown(id) or win.state(id).final == null) continue;
        const v = win.viewportOf(id);
        const s = win.state(id);
        if (s.viewport) |old| if (std.meta.eql(old, v)) continue;
        s.viewport = v;
        input_mod.callHandler(win, id, .viewport, &.{ .viewport = v });
        if (win.txn.open) return;
    }
}

/// After layout: a viewport that changed size is told at the next frame.
fn checkViewports(win: *Window) void {
    for (win.viewports.items) |id| {
        if (!win.isLive(id) or win.node(id).kind != .scroll or !win.isShown(id)) continue;
        const old = win.state(id).viewport orelse {
            win.viewport_dirty = true;
            continue;
        };
        const v = win.viewportOf(id);
        if (old.width != v.width or old.height != v.height) win.viewport_dirty = true;
    }
    if (win.viewport_dirty) win.requestFrame();
}

/// Delivers input queued behind a transaction, in order, until a handler
/// leaves a transaction open again.
fn replayInput(win: *Window) void {
    var i: usize = 0;
    while (i < win.pending_input.items.len and !win.txn.open) : (i += 1) {
        const ev = win.pending_input.items[i];
        // Key text may belong to a masked field.
        std.crypto.secureZero(u8, std.mem.asBytes(&win.pending_input.items[i]));
        input_mod.handle(win, &ev);
    }
    const rest = win.pending_input.items.len - i;
    std.mem.copyForwards(platform.Event, win.pending_input.items[0..rest], win.pending_input.items[i..]);
    win.pending_input.shrinkRetainingCapacity(rest);
    while (win.pending_edits.items.len != 0 and !win.txn.open and win.pending_input.items.len == 0) {
        editor_mod.apply(win, win.pending_edits.orderedRemove(0));
    }
    if (!win.txn.open and win.pending_input.items.len == 0 and win.pending_edits.items.len == 0) dnd_mod.flush(win);
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
    dnd_mod.forget(win, id);
    if (win.histories.fetchRemove(id)) |kv| {
        var h = kv.value;
        h.deinit(win.gpa);
    }
    const s = win.state(id);
    win.paint.damage(s.layer, s.bounds);
}

/// Where a popup goes relative to the node it belongs to. Horizontal sides
/// are logical: in RTL, `below` hangs from the node's right edge and
/// `beside` opens to its left (D21).
pub const PopupPlacement = enum {
    /// Menus and combo boxes: below, aligned at the start edge; flips
    /// above and slides sideways to stay on the output.
    below,
    /// Submenus: beside the end edge, top-aligned; flips to the start side.
    beside,
    /// Tooltips: centered below.
    tooltip,
};

/// An xdg_positioner for a popup of `width` x `height` anchored to `id`
/// (its window rectangle, rounded out).
pub fn popupPositioner(win: *const Window, id: NodeId, width: u32, height: u32, placement: PopupPlacement) platform.Positioner {
    const r = win.windowRect(id);
    const x0: i32 = @intFromFloat(@floor(r.x0));
    const y0: i32 = @intFromFloat(@floor(r.y0));
    const anchor_rect: platform.positioner.Rect = .{
        .x = x0,
        .y = y0,
        .width = @as(i32, @intFromFloat(@ceil(r.x1))) - x0,
        .height = @as(i32, @intFromFloat(@ceil(r.y1))) - y0,
    };
    const rtl = win.state(id).rtl;
    return switch (placement) {
        .below => .{
            .width = width,
            .height = height,
            .anchor_rect = anchor_rect,
            .anchor = if (rtl) .bottom_right else .bottom_left,
            .gravity = if (rtl) .bottom_left else .bottom_right,
            .adjustment = .{ .flip_y = true, .slide_x = true, .resize_y = true },
        },
        .beside => .{
            .width = width,
            .height = height,
            .anchor_rect = anchor_rect,
            .anchor = if (rtl) .top_left else .top_right,
            .gravity = if (rtl) .bottom_left else .bottom_right,
            .adjustment = .{ .flip_x = true, .slide_y = true, .resize_y = true },
        },
        .tooltip => .{
            .width = width,
            .height = height,
            .anchor_rect = anchor_rect,
            .anchor = .bottom,
            .gravity = .bottom,
            .adjustment = .{ .flip_y = true, .slide_x = true },
            .offset_y = 4,
        },
    };
}

/// The size the content wants with no limit, for windows that size to
/// their content (popups): the root measured with loose constraints, its
/// width at most `max_width`.
pub fn preferredSize(win: *Window, max_width: f32) Error!Size {
    if (win.txn.open) return .{ .w = win.width, .h = win.height };
    win.state(.root).rtl = win.rtl;
    const sz = try layout.measure(win, .root, .{ .max_w = max_width });
    _ = win.scratch.reset(.retain_capacity);
    return sz;
}

/// The semantics tree, rebuilt first if anything it shows changed since.
/// Nodes laid out by the last frame keep its bounds.
pub fn semanticsTree(win: *Window) Error!*const semantics_mod.Tree {
    if (win.dirty.semantics) {
        try win.semantics.rebuild(win);
        win.dirty.semantics = false;
    }
    return &win.semantics;
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
        // External frames belong to their producer, not the window.
        .presented, .animation_finished, .external_released, .external_configure => {},
    }
}

/// Whether a builder in `Event.released` belongs to this window.
pub fn ownsBuilder(win: *const Window, b: *const scene.Builder) bool {
    for (win.paint.all_builders.items) |own| if (own == b) return true;
    return false;
}

/// Whether the compositor has released every display list this window
/// sent it (each came back in `Event.released`). After
/// `Compositor.destroyWindow`, the window may be freed once this holds.
pub fn buildersHome(win: *const Window) bool {
    return win.paint.builders.items.len == win.paint.all_builders.items.len;
}

/// Keeps `img` alive while the display list in `b` can be shown, for
/// canvases that draw images (the builder passed to `Canvas.draw`).
/// Takes a reference of its own.
pub fn holdImage(win: *Window, b: *scene.Builder, img: *Image) error{OutOfMemory}!void {
    try paint_mod.holdImage(win.gpa, b, img);
}

/// A forwarded platform event for this window: pointer, keyboard, touch,
/// and scroll input the compositor did not consume.
pub fn handlePlatform(win: *Window, event: *const platform.Event) void {
    if (win.txn.open or win.pending_input.items.len != 0) {
        win.pending_input.append(win.gpa, event.*) catch {
            // Out of memory: deliver now rather than drop it; edits that
            // need a transaction are then lost, which only OOM can cause.
            input_mod.handle(win, event);
            return;
        };
        win.requestFrame();
        return;
    }
    input_mod.handle(win, event);
}

pub const DragOptions = struct {
    /// The data in each mime type it is offered in, preferred first
    /// (copied).
    items: []const Clipboard.DragItem,
    actions: platform.DragActions = .{ .copy = true },
    /// Only this application's windows can take it.
    in_app: bool = false,
    /// Follows the pointer, one image pixel per logical pixel, with the
    /// hotspot (in image pixels) under the pointer.
    icon: ?*Image = null,
    hotspot_x: f32 = 0,
    hotspot_y: f32 = 0,
};

pub const DragError = error{
    OutOfMemory,
    /// No items, no actions, an invalid mime type, or no such node.
    InvalidArgument,
    /// No button or touch is held on the window, or no platform to drag
    /// with.
    Unavailable,
};

/// Starts a drag from `id` while a button or touch press on the window is
/// held, typically from a pointer `move` handler once the pointer moved
/// far enough. `id` gets `drag` events as it progresses; after a `move`
/// it deletes the data. The pointer belongs to the drag from now on: the
/// node that had the press gets a pointer `cancel` before this returns.
pub fn startDrag(win: *Window, id: NodeId, o: DragOptions) DragError!void {
    const host = win.drag_host orelse return error.Unavailable;
    const cb = win.clipboard orelse return error.Unavailable;
    if (!win.isLive(id) or o.items.len == 0 or o.actions.none()) return error.InvalidArgument;
    for (o.items) |item| {
        if (item.mime.len == 0) return error.InvalidArgument;
        for (item.mime) |c| if (c <= ' ' or c >= 0x7f) return error.InvalidArgument;
    }
    if (win.input.capture == .none) return error.Unavailable;
    var out = try cb.copyDrag(o.items);
    errdefer cb.freeDrag(out);
    defer _ = win.scratch.reset(.retain_capacity);
    var icon: platform.DragIcon = undefined;
    if (o.icon) |img| icon = try dragIcon(win.scratch.allocator(), img, o.hotspot_x, o.hotspot_y);
    const mimes: []const []const u8 = if (o.in_app) &.{dnd_mod.in_app_mime} else out.mimes;
    const st = &win.input;
    const source = host.start(host.ctx, st.seat, st.press_serial, mimes, o.actions, if (o.icon != null) &icon else null) orelse return error.Unavailable;
    out.seat = st.seat;
    out.source = source;
    out.actions = o.actions;
    out.in_app = o.in_app;
    out.origin = win;
    out.node = id;
    cb.adoptDrag(out);
    // The compositor sends no pointer events during the drag, not even the
    // release: the press is taken away.
    const capture = st.capture;
    st.capture = .none;
    st.pressed = .none;
    st.selecting = .none;
    _ = input_mod.bubblePointer(win, capture, .cancel, .primary);
}

/// An image as a drag icon: premultiplied, sRGB-encoded BGRA.
fn dragIcon(a: std.mem.Allocator, img: *const Image, hx: f32, hy: f32) error{OutOfMemory}!platform.DragIcon {
    const w = img.width;
    const h = img.height;
    const px = try a.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const src = img.pixels[y * img.stride + x * img.format.bytesPerPixel() ..];
        var rgba: [4]u8 = switch (img.format) {
            .rgba8_srgb => src[0..4].*,
            .bgra8_srgb => .{ src[2], src[1], src[0], src[3] },
            .bgrx8_srgb => .{ src[2], src[1], src[0], 255 },
            .rgba16_linear_premul => blk: {
                const c = std.mem.bytesAsSlice(u16, src[0..8]);
                const alpha: f32 = @as(f32, @floatFromInt(c[3])) / 65535;
                var out: [4]u8 = undefined;
                for (0..3) |i| {
                    const lin = if (alpha > 0) @as(f32, @floatFromInt(c[i])) / 65535 / alpha else 0;
                    out[i] = @intFromFloat(@round(std.math.clamp(srgbEncode(lin), 0, 1) * 255));
                }
                out[3] = @intFromFloat(@round(alpha * 255));
                break :blk out;
            },
        };
        const alpha: u32 = rgba[3];
        for (rgba[0..3]) |*ch| ch.* = @intCast((@as(u32, ch.*) * alpha + 127) / 255);
        px[(y * w + x) * 4 ..][0..4].* = .{ rgba[2], rgba[1], rgba[0], rgba[3] };
    };
    return .{ .pixels = px, .width = w, .height = h, .stride = w * 4, .hotspot_x = @intFromFloat(@round(hx)), .hotspot_y = @intFromFloat(@round(hy)) };
}

fn srgbEncode(l: f32) f32 {
    return if (l <= 0.0031308) l * 12.92 else 1.055 * std.math.pow(f32, l, 1.0 / 2.4) - 0.055;
}

/// Shows `shape` over the whole window, whatever the nodes under the
/// pointer set (a busy cursor), or with null stops.
pub fn setCursorOverride(win: *Window, shape: ?node_mod.CursorShape) void {
    win.cursor_override = shape;
    input_mod.updateCursor(win);
}

/// Resolves a drop whose action was `ask` (`ui.Drop.action`): copy or
/// move as the user chose, or none to refuse it.
pub fn finishDrop(win: *Window, action: platform.DragAction) void {
    dnd_mod.finishDrop(win, action);
}

/// The contents of a masked editor (locked memory; do not copy it into
/// ordinary memory).
pub fn secretOf(win: *const Window, id: NodeId) []const u8 {
    return win.node(id).data.editor.secret;
}

/// Applies new desktop settings: text reshapes if its scale changed,
/// carets restart their blink, and theme changes repaint (D29).
pub fn setDesktop(win: *Window, d: Desktop) void {
    const old = win.desktop;
    if (std.meta.eql(old, d)) return;
    win.desktop = d;
    if (!(d.text_scale > 0) or !std.math.isFinite(d.text_scale)) win.desktop.text_scale = 1;
    if (win.desktop.text_scale != old.text_scale) {
        for (win.nodes.items, 0..) |n, i| if (n.status == .live and n.isText()) win.markShape(@enumFromInt(i));
    }
    win.applyPalette();
    win.paint.restartBlink();
    win.dirty.props = true;
    win.requestFrame();
}

/// Applies the application's theme choices (D29).
pub fn setTheme(win: *Window, t: *const theme.Theme) void {
    win.theme_choice = t.*;
    win.applyPalette();
    win.requestFrame();
}

/// Resolves the palette again: changed colors repaint every layer and
/// redraw canvases; a changed body size reshapes text with a size role.
fn applyPalette(win: *Window) void {
    const p = theme.resolve(&win.theme_choice, win.desktop.themeInput());
    const old = win.palette;
    win.palette = p;
    const colors = !p.eqlColors(&old);
    const size = p.body_px != old.body_px;
    if (!colors and !size) return;
    if (colors) win.paint.repaintAll();
    for (win.nodes.items, 0..) |n, i| {
        if (n.status != .live) continue;
        const id: NodeId = @enumFromInt(i);
        if (n.kind == .canvas) {
            // Canvases draw themed colors and measure themed text.
            if (size) win.markLayout(id);
            win.markPaint(id);
        }
        if (size and n.isText() and n.textData().props.style.size_role != .fixed) win.markShape(id);
    }
}

/// Whether motion (caret blinking, animations) is off.
pub fn reducedMotion(win: *const Window) bool {
    return win.force_reduced_motion or win.desktop.reduced_motion;
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
    if (win.node(l.owner).handler(.viewport) != null and !win.txn.open) win.deliverViewports();
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
