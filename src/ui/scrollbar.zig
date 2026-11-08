//! Scrollbars (D47): what the UI decides about them. The compositor draws
//! them over each scroll node's children, shows them while it scrolls or
//! the pointer moves over it, widens the one near the pointer, and fades
//! them when idle (`compositor.Scrollbars`), so they follow its own
//! scrolling, flings, and the application's `scroll_to` without the UI.
//! The UI gives them their look (from the node's palette), places them
//! (the end edge, in a gutter when the desktop wants them always shown or
//! the node asks for one),
//! and handles presses: dragging a thumb scrolls its node to where the
//! thumb is, and a press on a track pages toward it, and on while held.

const std = @import("std");
const raster = @import("raster");
const compositor = @import("compositor");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const paint = @import("paint.zig");
const input = @import("input.zig");
const text_node = @import("text_node.zig");
const layout = @import("layout.zig");

const NodeId = node_mod.NodeId;
const Point = raster.Point;
const Bars = compositor.Scrollbars;
const Bar = compositor.Bar;
const Axis = compositor.Axis;

/// A primary press on a scrollbar, which holds the pointer until it is
/// released: dragging its thumb, or paging from its track.
pub const Grab = struct {
    node: NodeId,
    axis: Axis,
    thumb: bool,
    /// Where the press was along the axis (window coordinates), and the
    /// physical offset then.
    from: f32 = 0,
    offset: f32 = 0,
    /// Offset per pixel the thumb moves.
    scale: f32 = 0,
};

/// A scroll node's scrollbars as the compositor draws them: the axes it
/// scrolls, its direction, the desktop's choice of always-shown bars,
/// the bar being dragged, motion, and colors from the text color of its
/// palette, as libadwaita mixes them from `currentColor` (stronger in
/// high contrast), with an outline in the view's background.
pub fn look(win: *const Window, nid: NodeId) Bars {
    const n = win.node(nid);
    // Multi-line editors scroll down only (D15).
    const axis: node_mod.ScrollAxis = if (n.kind == .scroll) n.data.scroll.axis else .vertical;
    const pal = win.paletteOf(nid);
    const high = pal.variant == .light_high_contrast or pal.variant == .dark_high_contrast;
    const fg = pal.color(.view_fg);
    const bg = pal.color(.view_bg);
    const a: [4]f32 = if (high) .{ 0.6, 0.8, 1, 0.3 } else .{ 0.35, 0.55, 0.75, 0.12 };
    const grab = win.input.bar;
    return .{
        .vertical = axis != .horizontal,
        .horizontal = axis != .vertical,
        .left = win.state(nid).rtl,
        .always = !win.desktop.overlay_scrolling,
        .active = if (grab) |g| if (g.node == nid and g.thumb) g.axis else null else null,
        .animate = !win.reducedMotion(),
        .thumb = fg.withAlpha(fg.a * a[0]),
        .thumb_hover = fg.withAlpha(fg.a * a[1]),
        .thumb_active = fg.withAlpha(fg.a * a[2]),
        .track = fg.withAlpha(fg.a * a[3]),
        .outline = bg.withAlpha(bg.a * @as(f32, if (high) 1 else 0.6)),
    };
}

/// A scroll node's container as the UI last sent it, if it shows one.
fn container(win: *const Window, nid: NodeId) ?compositor.Scroll {
    if (!win.paint.ownsLayerNow(win, nid)) return null;
    return win.paint.layers.items[win.state(nid).own_layer].scroll;
}

/// A scroll node's bars where the UI has its offset, in its coordinates.
fn barsOf(win: *const Window, nid: NodeId) ?struct { compositor.Scroll, [2]?Bar } {
    const sc = container(win, nid) orelse return null;
    if (!sc.bars.any()) return null;
    return .{ sc, sc.barsAt(paint.zoomOf(win, nid), paint.scrollTranslation(win, nid)) };
}

const Found = struct { node: NodeId, bar: Bar, local: Point, viewport: raster.Rect };

/// The scrollbar at window point `p`, or near it: of the innermost scroll
/// node under it, or of one around that one.
pub fn at(win: *const Window, p: Point) ?Found {
    var cur = innermost(win, .root, p).scroll;
    const m = input.modalRoot(win);
    while (cur != .none) : (cur = win.node(cur).parent) {
        if (!scrolls(win.node(cur))) continue;
        if (m != .root and !win.isAncestor(m, cur)) return null;
        const sc, const bars = barsOf(win, cur) orelse continue;
        const local = input.toLocal(win, cur, p);
        // Beside a gutter, presses reach the content it keeps clear.
        const reach = if (layout.scrollGutter(win, cur) > 0) Bars.margin else Bars.near;
        for (bars) |ob| if (ob) |bar| {
            if (bar.near(sc.viewport, local, reach)) return .{ .node = cur, .bar = bar, .local = local, .viewport = sc.viewport };
        };
    }
    return null;
}

const Under = struct { hit: bool = false, scroll: NodeId = .none };

/// The innermost scroll node on the path hit testing takes to `p`
/// (`input.hitTest`), where scroll nodes count as hit anywhere in their
/// viewport, as they do for the compositor's scrolling (D8).
fn innermost(win: *const Window, id: NodeId, parent_p: Point) Under {
    const n = win.node(id);
    if (n.isHidden()) return .{};
    const s = win.state(id);
    var p: Point = .{ .x = parent_p.x - s.pos.x, .y = parent_p.y - s.pos.y };
    if (!n.visual.transform.eql(.identity)) {
        const inv = n.visual.transform.affine().invert() orelse return .{};
        p = inv.apply(p);
    }
    const inside = p.x >= 0 and p.y >= 0 and p.x < s.size.w and p.y < s.size.h;
    if ((n.visual.clip or n.kind == .scroll) and !inside) return .{};
    var cp = p;
    if (n.kind == .scroll) {
        const pad = n.layout.padding;
        if (p.x < pad.left(s.rtl) or p.x >= s.size.w - (if (s.rtl) pad.start else pad.end) or p.y < pad.top or p.y >= s.size.h - pad.bottom)
            return .{ .hit = n.visual.hit_test };
        cp = paint.toContent(win, id, p);
    }
    var c = n.last;
    while (c != .none) : (c = win.node(c).prev) {
        const u = innermost(win, c, cp);
        if (u.hit) return if (u.scroll == .none and scrolls(n)) .{ .hit = true, .scroll = id } else u;
    }
    if (scrolls(n) and inside) return .{ .hit = true, .scroll = id };
    return .{ .hit = inside and n.visual.hit_test };
}

/// Scroll nodes and multi-line editors have scrollbars.
fn scrolls(n: *const node_mod.Node) bool {
    return n.kind == .scroll or paint.scrollsText(n);
}

/// A primary press at window point `p`: on a thumb, starts dragging it;
/// elsewhere on a track, pages toward the press, by what Page Down
/// scrolls, and held, scrolls on toward it. Returns whether a scrollbar
/// took it.
pub fn press(win: *Window, p: Point) bool {
    const f = at(win, p) orelse return false;
    const v = f.bar.axis;
    const along = if (v == .vertical) f.local.y else f.local.x;
    const thumb0 = if (v == .vertical) f.bar.thumb.y0 else f.bar.thumb.x0;
    const thumb1 = if (v == .vertical) f.bar.thumb.y1 else f.bar.thumb.x1;
    const offset = paint.scrollTranslation(win, f.node);
    if (along >= thumb0 and along < thumb1) {
        win.input.bar = .{
            .node = f.node,
            .axis = v,
            .thumb = true,
            .from = if (v == .vertical) p.y else p.x,
            .offset = if (v == .vertical) offset.y else offset.x,
            .scale = f.bar.scale,
        };
        // The bar shows as dragged.
        win.dirty.props = true;
        win.requestFrame();
        return true;
    }
    win.input.bar = .{ .node = f.node, .axis = v, .thumb = false };
    const page = 0.9 * if (v == .vertical) f.viewport.height() else f.viewport.width();
    // Physical, as the compositor scrolls: in right-to-left layouts too.
    const d = if (along < thumb0) -page else page;
    const delta: Point = if (v == .vertical) .{ .x = 0, .y = d } else .{ .x = d, .y = 0 };
    // Multi-line editors scroll their text in the UI, and reduced motion
    // jumps (D29).
    if (win.node(f.node).kind != .scroll or win.reducedMotion()) {
        input.scrollBy(win, f.node, delta);
        return true;
    }
    // A page glides as Page Down's does, and held, the node scrolls on
    // as a held key does until the thumb reaches the press (D8).
    const reach = if (along < thumb0) along - thumb0 else along - thumb1;
    var limit = offset;
    if (v == .vertical) limit.y += reach * f.bar.scale else limit.x += reach * f.bar.scale;
    const st = &win.input;
    win.paint.scroll_by.append(win.gpa, .{
        .node = f.node,
        .delta = delta,
        .smooth = true,
        .key = .{ .seat = st.seat, .code = st.button_code, .button = true },
        .limit = limit,
    }) catch return true;
    win.dirty.props = true;
    win.requestFrame();
    return true;
}

/// The pointer moved to `p` while a scrollbar holds it: the dragged
/// thumb follows it, and its node scrolls to match, through `scroll_to`
/// as the application's own offsets do (D8), so viewport handlers hear
/// of it at the next frame.
pub fn drag(win: *Window, p: Point) void {
    const g = win.input.bar orelse return;
    if (!g.thumb or !win.isLive(g.node) or !scrolls(win.node(g.node))) return;
    const along = if (g.axis == .vertical) p.y else p.x;
    const max = paint.maxScroll(win, g.node);
    var phys = paint.scrollTranslation(win, g.node);
    switch (g.axis) {
        .vertical => phys.y = std.math.clamp(g.offset + (along - g.from) * g.scale, 0, max.y),
        .horizontal => phys.x = std.math.clamp(g.offset + (along - g.from) * g.scale, 0, max.x),
    }
    scrollTo(win, g.node, phys);
}

/// Assistive technology set a scrollbar's value (D47): its node's
/// logical offset along `axis`, as `siv_scroll_to` takes it.
pub fn setValue(win: *Window, nid: NodeId, axis: Axis, value: f64) bool {
    if (!win.isLive(nid) or !std.math.isFinite(value) or !scrolls(win.node(nid))) return false;
    const max = paint.maxScroll(win, nid);
    var phys = paint.scrollTranslation(win, nid);
    const v: f32 = @floatCast(value);
    switch (axis) {
        .vertical => phys.y = std.math.clamp(v, 0, max.y),
        // Logical and physical offsets mirror each other in right-to-left
        // layouts, so the same conversion goes both ways.
        .horizontal => phys.x = paint.logicalScroll(win, nid, .{ .x = std.math.clamp(v, 0, max.x), .y = 0 }).x,
    }
    scrollTo(win, nid, phys);
    return true;
}

/// Scrolls a node to a physical offset as the application's own offsets
/// do, through `scroll_to` (D8), so viewport handlers hear of it at the
/// next frame.
fn scrollTo(win: *Window, nid: NodeId, phys: Point) void {
    const s = win.state(nid);
    const n = win.node(nid);
    if (n.kind == .editor) {
        if (phys.y == s.editor_scroll_y) return;
        s.editor_scroll_y = phys.y;
        s.scroll_pending = true;
        win.dirty.props = true;
        win.dirty.semantics = true;
        win.requestFrame();
        return;
    }
    const logical = paint.logicalScroll(win, nid, phys);
    if (logical.eql(n.data.scroll.offset)) return;
    n.data.scroll.offset = logical;
    s.scroll_pending = true;
    win.app_scrolled = true;
    win.dirty.props = true;
    win.dirty.semantics = true;
    text_node.scrolled(win, nid);
    win.requestFrame();
}

pub const Range = struct { axis: Axis, track: raster.Rect, range: node_mod.Range };

/// A scroll node's scrollbars for assistive technology: each axis with
/// overflow, its track in the node's coordinates, and its range in
/// logical offsets.
pub fn ranges(win: *const Window, nid: NodeId) [2]?Range {
    var out: [2]?Range = .{ null, null };
    if (!scrolls(win.node(nid))) return out;
    _, const bars = barsOf(win, nid) orelse return out;
    const max = paint.maxScroll(win, nid);
    const logical = paint.logicalScroll(win, nid, paint.scrollTranslation(win, nid));
    for (bars, 0..) |ob, i| if (ob) |bar| {
        const v = bar.axis == .vertical;
        out[i] = .{ .axis = bar.axis, .track = bar.track, .range = .{
            .min = 0,
            .max = if (v) max.y else max.x,
            .now = if (v) logical.y else logical.x,
            .step = 0,
        } };
    };
    return out;
}

/// The press that a scrollbar took ended.
pub fn release(win: *Window) void {
    const g = win.input.bar orelse return;
    win.input.bar = null;
    if (g.thumb) {
        win.dirty.props = true;
        win.requestFrame();
    }
}

/// Whether the pointer at `p` is on a scrollbar (or held by one), which
/// shows the default cursor whatever is under it.
pub fn covers(win: *const Window, p: Point) bool {
    return win.input.bar != null or at(win, p) != null;
}
