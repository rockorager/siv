//! One-way constraint layout. Constraints go down, sizes come up, and
//! parents place their children. Horizontal text only, so widths never
//! depend on heights: a container that sizes to its content asks its
//! children for their max-content width (computed bottom-up, cached per
//! node) instead of laying them out twice, and lays out each child once
//! with its final width.
//!
//! Every node caches the constraints of its last layout (its children's
//! positions are valid for those) and the sizes of its last two layouts,
//! so a clean node costs one comparison. Changing a node marks it and its
//! ancestors; clean subtrees are skipped.
//!
//! Containers size to their content within their constraints. Stretch
//! alignment (the default in boxes, flex cross axes, and grids) or an
//! explicit size makes a child fill; flex free space and fr tracks only
//! exist when the container is larger than its content.
//!
//! Variants (D39): a node's parent decides which of its variants hold
//! from the space it offers its children, which its constraints fix
//! before any child is measured, and applies them before reading the
//! children, so a layout is still one pass. Max-content widths take
//! descendants' variants at unbounded space, so that what a node is
//! offered never depends on the variant that offer chose.

const std = @import("std");
const raster = @import("raster");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const text_node = @import("text_node.zig");

const NodeId = node_mod.NodeId;
const Node = node_mod.Node;
const Align = node_mod.Align;
const Point = raster.Point;
const Error = Window.Error;

const inf = std.math.inf(f32);

/// Width of an editor's caret.
pub const caret_width: f32 = 1.5;

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,

    pub fn eql(a: Size, b: Size) bool {
        return a.w == b.w and a.h == b.h;
    }
};

pub const Constraints = struct {
    min_w: f32 = 0,
    max_w: f32 = inf,
    min_h: f32 = 0,
    max_h: f32 = inf,

    pub fn tight(w: f32, h: f32) Constraints {
        return .{ .min_w = w, .max_w = w, .min_h = h, .max_h = h };
    }

    pub fn eql(a: Constraints, b: Constraints) bool {
        return a.min_w == b.min_w and a.max_w == b.max_w and a.min_h == b.min_h and a.max_h == b.max_h;
    }

    pub fn tightW(c: Constraints) bool {
        return c.min_w == c.max_w;
    }

    pub fn tightH(c: Constraints) bool {
        return c.min_h == c.max_h;
    }

    pub fn admits(c: Constraints, s: Size) bool {
        return s.w >= c.min_w and s.w <= c.max_w and s.h >= c.min_h and s.h <= c.max_h;
    }

    pub fn clampW(c: Constraints, w: f32) f32 {
        return @max(c.min_w, @min(w, c.max_w));
    }

    pub fn clampH(c: Constraints, h: f32) f32 {
        return @max(c.min_h, @min(h, c.max_h));
    }

    fn shrink(c: Constraints, dw: f32, dh: f32) Constraints {
        return .{
            .min_w = @max(c.min_w - dw, 0),
            .max_w = @max(c.max_w - dw, 0),
            .min_h = @max(c.min_h - dh, 0),
            .max_h = @max(c.max_h - dh, 0),
        };
    }
};

pub const Cached = struct { c: Constraints, size: Size };

/// A grid item's resolved cell.
pub const Cell = struct { col: u16 = 0, row: u16 = 0, cols: u16 = 1, rows: u16 = 1 };

/// Lays out the window's tree at the window size.
pub fn run(win: *Window) Error!void {
    if (!win.state(.root).needs_layout) return;
    win.state(.root).rtl = win.rtl;
    // The root's variants see the window.
    try applyVariants(win, .root, win.width, win.height);
    const size = try place(win, .root, .tight(win.width, win.height));
    setPos(win, .root, .zero);
    _ = size;
}

/// The node's size under `c`, from its cache when possible. Positions of
/// its children are valid only for its last `place`.
pub fn measure(win: *Window, id: NodeId, c: Constraints) Error!Size {
    const s = win.state(id);
    if (!s.needs_layout) {
        for (s.cache) |entry| if (entry) |e| if (e.c.eql(c)) return e.size;
    }
    return compute(win, id, c);
}

/// Lays out the node under `c` and returns its size.
pub fn place(win: *Window, id: NodeId, c: Constraints) Error!Size {
    const s = win.state(id);
    if (!s.needs_layout) if (s.final) |f| {
        if (f.eql(c)) return s.size;
        // Tight at the size the last layout chose under constraints that
        // allowed it: that layout already is this one.
        // Not when its children's variants (D39) depend on what the
        // constraints offer.
        if (c.tightW() and c.tightH() and c.min_w == s.size.w and c.min_h == s.size.h and f.admits(s.size) and !s.variant_children) return s.size;
    };
    return compute(win, id, c);
}

fn setPos(win: *Window, id: NodeId, p: Point) void {
    const s = win.state(id);
    if (!s.pos.eql(p)) {
        s.pos = p;
        markMoved(win, id);
    }
}

/// A node moved, and its subtree with it. A layer root moves as a layer
/// property, its content in its own coordinates; anything else repaints,
/// and so do its descendants up to the layers they root: they paint into
/// layers the moved node does not root (its container's, or a chunk after
/// a descendant's layer), at offsets that changed.
fn markMoved(win: *Window, id: NodeId) void {
    const s = win.state(id);
    win.markPaint(id);
    if (s.own_layer != @import("paint.zig").no_layer and s.layer == s.own_layer) {
        win.dirty.props = true;
        return;
    }
    var it = win.shown(id);
    while (it.next()) |ch| markMoved(win, ch);
}

fn compute(win: *Window, id: NodeId, c: Constraints) Error!Size {
    const n = win.node(id);
    const s = win.state(id);
    if (s.needs_layout) s.cache = .{ null, null };
    resolveDirection(win, id);
    const cc = own(n, c);
    const pad = n.layout.padding;
    const inner = cc.shrink(pad.horizontal(), pad.vertical());
    const origin: Point = .{ .x = pad.left(s.rtl), .y = pad.top };
    if (s.variant_children) try applyChildVariants(win, id, inner);
    const content: Size = switch (n.kind) {
        .box => try block(win, id, inner, origin),
        .scroll => try scroll(win, id, inner),
        .flex => try flex(win, id, inner, origin),
        .grid => try grid(win, id, inner, origin),
        .stack => try stack(win, id, inner, origin),
        .text, .editor => blk: {
            // New glyphs can keep the same size; repaint regardless.
            win.markPaint(id);
            break :blk try textSize(win, id, inner);
        },
        .image => imageSize(n.data.image.intrinsic(), inner),
        .canvas => canvasSize(win, id, inner),
        .external => imageSize(intrinsic(n.data.external), inner),
    };
    const size: Size = .{ .w = cc.clampW(content.w + pad.horizontal()), .h = cc.clampH(content.h + pad.vertical()) };
    if (!s.size.eql(size)) {
        s.size = size;
        win.markPaint(id);
        if (s.own_layer != @import("paint.zig").no_layer) win.dirty.props = true;
    }
    s.needs_layout = false;
    s.final = c;
    s.cache = .{ .{ .c = c, .size = size }, if (s.cache[0]) |e| (if (e.c.eql(c)) s.cache[1] else e) else s.cache[1] };
    win.stats.layouts += 1;
    return size;
}

/// Sets the node's resolved direction from its parent's, which is resolved
/// first (layout and max-content both run top-down).
fn resolveDirection(win: *Window, id: NodeId) void {
    const n = win.node(id);
    win.state(id).rtl = switch (n.layout.direction) {
        .ltr => false,
        .rtl => true,
        .inherit => if (n.parent == .none) win.rtl else win.state(n.parent).rtl,
    };
}

/// The node's own constraints: the parent's, narrowed by its size props.
fn own(n: *const Node, c: Constraints) Constraints {
    const l = n.layout;
    var r = c;
    // The node's own largest size wins over a parent that stretches it
    // (a minimum from the parent above it), as CSS max-width does; its
    // own smallest size wins over both, but not over the parent's
    // largest. A stretched node held narrower is placed at the start.
    const min_w = @min(l.min_width, c.max_w);
    r.max_w = @max(min_w, @min(c.max_w, l.max_width));
    r.min_w = @min(@max(c.min_w, min_w), r.max_w);
    const min_h = @min(l.min_height, c.max_h);
    r.max_h = @max(min_h, @min(c.max_h, l.max_height));
    r.min_h = @min(@max(c.min_h, min_h), r.max_h);
    if (resolve(l.width, c.max_w)) |w| {
        r.min_w = r.clampW(w);
        r.max_w = r.min_w;
    }
    if (resolve(l.height, c.max_h)) |h| {
        r.min_h = r.clampH(h);
        r.max_h = r.min_h;
    }
    return r;
}

fn resolve(d: node_mod.Dimension, available: f32) ?f32 {
    return switch (d) {
        .auto => null,
        .px => |v| v,
        .fraction => |f| if (std.math.isFinite(available)) f * available else null,
    };
}

/// Max-content border-box width: the widest the node gets without
/// wrapping, which is what it takes when it sizes to its content. Its
/// descendants' variants (D39) are those that hold at unbounded space,
/// since the space they get is what this width decides.
pub fn maxContent(win: *Window, id: NodeId) Error!f32 {
    const s = win.state(id);
    if (s.max_content >= 0) return s.max_content;
    const n = win.node(id);
    const r = try maxContentOf(win, id, n.layout, if (n.kind == .flex) n.data.flex else .{});
    s.max_content = r;
    return r;
}

/// The max-content width with the node's own variants at unbounded space
/// too: what its parent's max-content width counts.
fn maxContentInf(win: *Window, id: NodeId) Error!f32 {
    const a = win.node(id).adaptive orelse return maxContent(win, id);
    const s = win.state(id);
    if (s.max_content_inf >= 0) return s.max_content_inf;
    const v = atInf(win, a);
    const r = try maxContentOf(win, id, v.layout, v.flex);
    s.max_content_inf = r;
    return r;
}

/// The node's layout with the variants that hold at unbounded space.
fn layoutInf(win: *const Window, id: NodeId) node_mod.Layout {
    const a = win.node(id).adaptive orelse return win.node(id).layout;
    return atInf(win, a).layout;
}

/// A node's values with the variants that hold when its parent offers
/// unbounded space; those on the window's size see the window.
fn atInf(win: *const Window, a: *const node_mod.Adaptive) node_mod.Adaptable {
    return a.resolve(a.holding(inf, inf, win.width, win.height, 0));
}

/// Children shown at unbounded space.
const ShownInf = struct {
    win: *const Window,
    cur: NodeId,

    fn next(it: *ShownInf) ?NodeId {
        while (it.cur != .none) {
            const id = it.cur;
            const n = it.win.node(id);
            it.cur = n.next;
            const hidden = if (n.adaptive) |a| atInf(it.win, a).hidden else n.hidden;
            if (!n.visual.hidden and !hidden) return id;
        }
        return null;
    }
};

fn shownInf(win: *const Window, id: NodeId) ShownInf {
    return .{ .win = win, .cur = win.node(id).first };
}

/// Max-content width with the node's layout `l` and flex options `f`.
fn maxContentOf(win: *Window, id: NodeId, l: node_mod.Layout, f: node_mod.Flex) Error!f32 {
    resolveDirection(win, id);
    const n = win.node(id);
    const w: f32 = if (l.width == .px) l.width.px else blk: {
        var content: f32 = 0;
        switch (n.kind) {
            .box, .scroll => {
                var it = shownInf(win, id);
                while (it.next()) |ch| content = @max(content, try maxContentInf(win, ch));
            },
            .stack => {
                var it = shownInf(win, id);
                while (it.next()) |ch| {
                    const in = layoutInf(win, ch).inset;
                    content = @max(content, try maxContentInf(win, ch) + (in.start orelse 0) + (in.end orelse 0));
                }
            },
            .flex => {
                var it = shownInf(win, id);
                var count: f32 = 0;
                while (it.next()) |ch| {
                    const m = try maxContentInf(win, ch);
                    if (f.axis == .row) content += m else content = @max(content, m);
                    count += 1;
                }
                if (f.axis == .row and count > 1) content += f.gap * (count - 1);
            },
            .grid => content = try gridMaxContent(win, id),
            .text => content = try text_node.maxContent(win, id),
            // Room for the caret after the last character.
            .editor => content = try text_node.maxContent(win, id) + caret_width,
            .image => content = if (n.data.image.intrinsic()) |wh| wh[0] else 0,
            .canvas => content = canvasSize(win, id, .{}).w,
            .external => content = n.data.external.width,
        }
        break :blk content + l.padding.horizontal();
    };
    return @max(l.min_width, @min(w, l.max_width));
}

// Variants (D39) ---------------------------------------------------------------

/// Decides the variants of the node's children from the space it offers
/// them: its content box under its constraints, unbounded along the axes
/// a scroll node scrolls.
fn applyChildVariants(win: *Window, id: NodeId, inner: Constraints) Error!void {
    const n = win.node(id);
    var w = inner.max_w;
    var h = inner.max_h;
    if (n.kind == .scroll) switch (n.data.scroll.axis) {
        .vertical => h = inf,
        .horizontal => w = inf,
        .both => {
            w = inf;
            h = inf;
        },
    };
    var any = false;
    var it = win.children(id);
    while (it.next()) |ch| {
        if (win.node(ch).adaptive != null) any = true;
        try applyVariants(win, ch, w, h);
    }
    win.state(id).variant_children = any;
}

/// Applies the variants of the node that hold in `w` by `h`. Its parent
/// is laying it out, so it marks only the node and its subtree.
fn applyVariants(win: *Window, id: NodeId, w: f32, h: f32) Error!void {
    const n = win.node(id);
    const s = win.state(id);
    const a = n.adaptive orelse {
        // Variants removed: the node already shows its own values.
        s.variant_mask = 0;
        return;
    };
    const max_content = if (a.needsMaxContent()) try maxContentInf(win, id) else 0;
    const mask = a.holding(w, h, win.width, win.height, max_content);
    if (mask == s.variant_mask) return;
    s.variant_mask = mask;
    win.variants_switched = true;
    win.dirty.semantics = true;
    const v = a.resolve(mask);
    if (!std.meta.eql(n.layout, v.layout)) {
        const direction_changed = n.layout.direction != v.layout.direction;
        n.layout = v.layout;
        dirty(win, id);
        if (direction_changed) dirtySubtree(win, id);
    }
    if (n.kind == .flex and !std.meta.eql(n.data.flex, v.flex)) {
        n.data.flex = v.flex;
        dirty(win, id);
    }
    if (n.hidden != v.hidden) {
        const was_hidden = n.isHidden();
        n.hidden = v.hidden;
        if (was_hidden != n.isHidden()) {
            // As a transaction hides or shows it (`Txn.visibilityChanged`).
            if (n.isHidden()) @import("txn.zig").Txn.hideSubtree(win, id) else s.appear = true;
            dirty(win, id);
            dirtySubtree(win, id);
            win.markLayers();
        }
    }
}

fn dirty(win: *Window, id: NodeId) void {
    const s = win.state(id);
    s.needs_layout = true;
    s.max_content = -1;
}

fn dirtySubtree(win: *Window, id: NodeId) void {
    var it = win.children(id);
    while (it.next()) |c| {
        const s = win.state(c);
        s.needs_layout = true;
        s.max_content = -1;
        s.max_content_inf = -1;
        if (win.node(c).isText()) s.needs_shape = true;
        dirtySubtree(win, c);
    }
}

/// The content width a container takes: all of a tight constraint, else
/// its content's max-content width within the constraint.
fn fitWidth(win: *Window, id: NodeId, inner: Constraints) Error!f32 {
    if (inner.tightW()) return inner.max_w;
    var w: f32 = 0;
    var it = win.shown(id);
    while (it.next()) |ch| w = @max(w, try maxContent(win, ch));
    return inner.clampW(w);
}

fn resolveAlign(a: Align, default: Align) Align {
    return if (a == .auto) default else a;
}

/// Offset of a child of size `size` in `space` on the horizontal axis.
fn alignX(a: Align, space: f32, size: f32, rtl: bool) f32 {
    return switch (a) {
        .start, .stretch, .auto => if (rtl) space - size else 0,
        .end => if (rtl) 0 else space - size,
        .center => (space - size) / 2,
    };
}

fn alignY(a: Align, space: f32, size: f32) f32 {
    return switch (a) {
        .start, .stretch, .auto => 0,
        .end => space - size,
        .center => (space - size) / 2,
    };
}

/// Width constraints of a child aligned with `a` in `space`. Stretching
/// applies only to children without an explicit width.
fn widthFor(win: *const Window, ch: NodeId, a: Align, space: f32) Constraints {
    return if (a == .stretch and std.math.isFinite(space) and win.node(ch).layout.width == .auto) .{ .min_w = space, .max_w = space } else .{ .max_w = space };
}

/// Height constraints likewise.
fn heightFor(win: *const Window, ch: NodeId, a: Align, space: f32) Constraints {
    return if (a == .stretch and std.math.isFinite(space) and win.node(ch).layout.height == .auto) .{ .min_h = space, .max_h = space } else .{ .max_h = space };
}

fn both(w: Constraints, h: Constraints) Constraints {
    return .{ .min_w = w.min_w, .max_w = w.max_w, .min_h = h.min_h, .max_h = h.max_h };
}

// Box: block flow ------------------------------------------------------------

fn block(win: *Window, id: NodeId, inner: Constraints, origin: Point) Error!Size {
    const rtl = win.state(id).rtl;
    const cw = try fitWidth(win, id, inner);
    const h = try stackBlock(win, id, cw, rtl, origin, inner.max_h);
    return .{ .w = cw, .h = inner.clampH(h) };
}

/// Children stacked vertically in width `cw`; returns their height. A
/// child with a fraction height takes that fraction of `ch_space`, the
/// box's height when it is definite (a pane stretched by its parent);
/// other children size to their content.
fn stackBlock(win: *Window, id: NodeId, cw: f32, rtl: bool, origin: Point, ch_space: f32) Error!f32 {
    var y: f32 = 0;
    var it = win.shown(id);
    while (it.next()) |ch| {
        const a = resolveAlign(win.node(ch).layout.align_x, .stretch);
        var cc = widthFor(win, ch, a, cw);
        if (win.node(ch).layout.height == .fraction) cc.max_h = ch_space;
        const sz = try place(win, ch, cc);
        setPos(win, ch, .{ .x = origin.x + alignX(a, cw, sz.w, rtl), .y = origin.y + y });
        y += sz.h;
    }
    return y;
}

// Scroll ---------------------------------------------------------------------

/// The viewport is the content box. Children flow as in a box, in content
/// coordinates (origin at the content box's top-left corner, unscrolled).
fn scroll(win: *Window, id: NodeId, inner: Constraints) Error!Size {
    const s = win.state(id);
    const axis = win.node(id).data.scroll.axis;
    const vw = try fitWidth(win, id, inner);
    var content_w = vw;
    if (axis != .vertical) {
        var it = win.shown(id);
        while (it.next()) |ch| content_w = @max(content_w, try maxContent(win, ch));
    }
    const h = try stackBlock(win, id, content_w, s.rtl, .zero, std.math.inf(f32));
    const vh = inner.clampH(h);
    s.content = .{ .w = content_w, .h = if (axis == .horizontal) @max(h, vh) else h };
    return .{ .w = vw, .h = vh };
}

// Flex -----------------------------------------------------------------------

const FlexItem = struct {
    id: NodeId,
    base: f32,
    main: f32 = 0,
    cross: f32 = 0,
    grow: f32,
    shrink: f32,
    min: f32,
    max: f32,
    align_: Align,
    frozen: bool = false,
};

fn flex(win: *Window, id: NodeId, inner: Constraints, origin: Point) Error!Size {
    const n = win.node(id);
    const f = n.data.flex;
    const rtl = win.state(id).rtl;
    const row = f.axis == .row;
    const a = win.scratch.allocator();

    var count: usize = 0;
    var it = win.shown(id);
    while (it.next()) |_| count += 1;
    const items = try a.alloc(FlexItem, count);

    const main_min = if (row) inner.min_w else inner.min_h;
    const main_max = if (row) inner.max_w else inner.max_h;
    const cross_tight = if (row) inner.tightH() else inner.tightW();
    // A column knows its width before its children: what it fits.
    const column_w: f32 = if (row) 0 else try fitWidth(win, id, inner);

    // Base sizes.
    it = win.shown(id);
    var i: usize = 0;
    while (it.next()) |ch| : (i += 1) {
        const l = win.node(ch).layout;
        const al = resolveAlign(if (row) l.align_y else l.align_x, f.align_items);
        const base: f32 = if (resolve(l.basis, main_max)) |b| b else if (row)
            try maxContent(win, ch)
        else
            (try measure(win, ch, widthFor(win, ch, al, column_w))).h;
        items[i] = .{
            .id = ch,
            .base = base,
            .grow = l.grow,
            .shrink = l.shrink,
            .min = if (row) l.min_width else l.min_height,
            .max = if (row) l.max_width else l.max_height,
            .align_ = al,
        };
    }

    // Lines.
    const LineSpan = struct { start: usize, end: usize, cross: f32 = 0 };
    var lines: std.ArrayList(LineSpan) = .empty;
    {
        var start: usize = 0;
        var used: f32 = 0;
        for (items, 0..) |item, k| {
            const add = item.base + if (k > start) f.gap else 0;
            if (f.wrap and k > start and used + add > main_max) {
                try lines.append(a, .{ .start = start, .end = k });
                start = k;
                used = item.base;
            } else used += add;
        }
        try lines.append(a, .{ .start = start, .end = items.len });
    }

    // Main size of the container: the widest line within the constraints.
    var widest: f32 = 0;
    for (lines.items) |ln| widest = @max(widest, lineMain(items[ln.start..ln.end], f.gap));
    const main_size = if (main_min == main_max) main_max else @max(main_min, @min(widest, main_max));

    // Resolve main sizes and lay out.
    for (lines.items) |*ln| {
        const line = items[ln.start..ln.end];
        resolveLengths(line, main_size, f.gap);
        for (line) |*item| {
            const cross_space = if (row) (if (cross_tight) inner.max_h else inf) else column_w;
            const sz = try place(win, item.id, itemConstraints(win, item.id, row, item.main, item.align_, cross_space));
            item.cross = if (row) sz.h else sz.w;
            ln.cross = @max(ln.cross, item.cross);
        }
    }

    // Cross size.
    const line_gap = f.line_gap orelse f.gap;
    var cross_sum: f32 = 0;
    for (lines.items, 0..) |ln, k| cross_sum += ln.cross + if (k > 0) line_gap else 0;
    const cross_size = if (row) inner.clampH(cross_sum) else column_w;
    if (lines.items.len == 1) lines.items[0].cross = cross_size;

    // Stretch children to their line, then position.
    var cross_pos: f32 = 0;
    for (lines.items) |ln| {
        const line = items[ln.start..ln.end];
        var used: f32 = 0;
        for (line) |*item| {
            const explicit = if (row) win.node(item.id).layout.height != .auto else win.node(item.id).layout.width != .auto;
            if (item.align_ == .stretch and item.cross != ln.cross and !explicit) {
                const sz = try place(win, item.id, itemConstraints(win, item.id, row, item.main, .stretch, ln.cross));
                item.cross = if (row) sz.h else sz.w;
            }
            used += item.main;
        }
        const nf: f32 = @floatFromInt(line.len);
        const free = main_size - used - f.gap * (nf - 1);
        var lead: f32 = 0;
        var between = f.gap;
        switch (f.justify) {
            .start => {},
            .center => lead = free / 2,
            .end => lead = free,
            .space_between => if (free > 0 and line.len > 1) {
                between += free / (nf - 1);
            },
            .space_around => if (free > 0) {
                lead = free / (2 * nf);
                between += free / nf;
            },
            .space_evenly => if (free > 0) {
                lead = free / (nf + 1);
                between += free / (nf + 1);
            },
        }
        var pos = lead;
        for (line) |item| {
            const c_off = if (row) alignY(item.align_, ln.cross, item.cross) else alignX(item.align_, ln.cross, item.cross, rtl);
            const p: Point = if (row) .{
                .x = if (rtl) main_size - pos - item.main else pos,
                .y = cross_pos + c_off,
            } else .{ .x = c_off, .y = pos };
            setPos(win, item.id, .{ .x = origin.x + p.x, .y = origin.y + p.y });
            pos += item.main + between;
        }
        cross_pos += ln.cross + line_gap;
    }
    return if (row) .{ .w = main_size, .h = cross_size } else .{ .w = cross_size, .h = main_size };
}

/// Main sizes of a line's items: free space goes by grow or shrink
/// weights, and items that a share would push past their min or max size
/// are frozen there while the rest is shared again (CSS Flexbox 9.7). A
/// share was not clamped to the max before, so a growing list view with a
/// max height filled its column.
fn resolveLengths(line: []FlexItem, main_size: f32, gap: f32) void {
    const growing = lineMain(line, gap) < main_size;
    for (line) |*item| {
        item.main = item.base;
        item.frozen = if (growing) item.grow == 0 else item.shrink == 0;
    }
    if (lineMain(line, gap) == main_size) return;
    for (0..line.len + 1) |_| {
        var used: f32 = 0;
        var weights: f32 = 0;
        for (line, 0..) |item, k| {
            used += (if (item.frozen) item.main else item.base) + if (k > 0) gap else 0;
            if (!item.frozen) weights += if (growing) item.grow else item.shrink * item.base;
        }
        if (!(weights > 0)) break;
        const free = main_size - used;
        var violation: f32 = 0;
        for (line) |*item| {
            if (item.frozen) continue;
            const share = free * (if (growing) item.grow else item.shrink * item.base) / weights;
            const target = item.base + share;
            item.main = @max(item.min, @min(target, item.max));
            violation += item.main - target;
        }
        if (violation == 0) break;
        // Freeze the min violators when clamping added space, the max
        // violators when it took some away.
        for (line) |*item| {
            if (item.frozen) continue;
            const target = item.base + free * (if (growing) item.grow else item.shrink * item.base) / weights;
            if ((violation > 0 and item.main > target) or (violation < 0 and item.main < target)) item.frozen = true;
        }
    }
}

fn lineMain(line: []const FlexItem, gap: f32) f32 {
    var sum: f32 = 0;
    for (line, 0..) |item, k| sum += item.base + if (k > 0) gap else 0;
    return sum;
}

/// Constraints for a flex child: tight on the main axis, aligned on the
/// cross axis.
fn itemConstraints(win: *const Window, ch: NodeId, row: bool, main: f32, al: Align, cross_space: f32) Constraints {
    if (row) return both(.{ .min_w = main, .max_w = main }, heightFor(win, ch, al, cross_space));
    return both(widthFor(win, ch, al, cross_space), .{ .min_h = main, .max_h = main });
}

// Grid -----------------------------------------------------------------------

const GridItem = struct { id: NodeId, cell: Cell };

/// Places every child in a cell: explicit positions first, then auto items
/// in row-major order into the first free cells that fit them.
/// With `inf`, as at unbounded space (max-content widths, D39), without
/// keeping the cells.
fn placeItems(win: *Window, id: NodeId, inf_space: bool) Error!struct { items: []GridItem, cols: usize, rows: usize } {
    const g = win.node(id).data.grid;
    const a = win.scratch.allocator();
    var count: usize = 0;
    var it = win.shown(id);
    var it_inf = shownInf(win, id);
    while (if (inf_space) it_inf.next() else it.next()) |_| count += 1;
    const items = try a.alloc(GridItem, count);
    const layouts = try a.alloc(node_mod.Layout, count);
    var cols: usize = @max(g.columns.len, 1);
    var rows: usize = g.rows.len;
    var occupied: std.AutoHashMapUnmanaged(u32, void) = .empty;
    it = win.shown(id);
    it_inf = shownInf(win, id);
    var i: usize = 0;
    while (if (inf_space) it_inf.next() else it.next()) |ch| : (i += 1) {
        const l = if (inf_space) layoutInf(win, ch) else win.node(ch).layout;
        layouts[i] = l;
        items[i] = .{ .id = ch, .cell = .{ .col = l.column orelse 0, .row = l.row orelse 0, .cols = l.column_span, .rows = l.row_span } };
        if (l.column != null) cols = @max(cols, @as(usize, l.column.?) + l.column_span);
    }
    for (items, layouts) |*item, l| {
        if (l.column == null and l.row == null) continue;
        if (l.column == null or l.row == null) {
            item.cell.col = l.column orelse 0;
            item.cell.row = l.row orelse 0;
        }
        try occupy(a, &occupied, item.cell);
        rows = @max(rows, @as(usize, item.cell.row) + item.cell.rows);
    }
    var cursor: usize = 0;
    for (items, layouts) |*item, l| {
        if (l.column != null or l.row != null) continue;
        const span: usize = @min(item.cell.cols, cols);
        item.cell.cols = @intCast(span);
        while (true) : (cursor += 1) {
            const r = cursor / cols;
            const c = cursor % cols;
            if (c + span > cols) continue;
            var free = true;
            for (0..item.cell.rows) |dr| for (0..span) |dc| {
                if (occupied.contains(key(c + dc, r + dr))) free = false;
            };
            if (!free) continue;
            item.cell.col = @intCast(c);
            item.cell.row = @intCast(r);
            break;
        }
        try occupy(a, &occupied, item.cell);
        rows = @max(rows, @as(usize, item.cell.row) + item.cell.rows);
    }
    if (!inf_space) for (items) |item| {
        win.state(item.id).cell = item.cell;
    };
    return .{ .items = items, .cols = cols, .rows = rows };
}

fn key(c: usize, r: usize) u32 {
    return @intCast(r * 65536 + c);
}

fn occupy(a: std.mem.Allocator, occupied: *std.AutoHashMapUnmanaged(u32, void), cell: Cell) Error!void {
    for (0..cell.rows) |dr| for (0..cell.cols) |dc| try occupied.put(a, key(@as(usize, cell.col) + dc, @as(usize, cell.row) + dr), {});
}

fn track(tracks: []const node_mod.Track, i: usize) node_mod.Track {
    return if (i < tracks.len) tracks[i] else .auto;
}

/// Sizes tracks from item contributions (`contrib`, per item) into `sizes`.
/// `definite` is the space the tracks share when known.
fn sizeTracks(
    tracks: []const node_mod.Track,
    sizes: []f32,
    items: []const GridItem,
    contrib: []const f32,
    vertical: bool,
    gap: f32,
    min: f32,
    max: f32,
) void {
    const n = sizes.len;
    var fr_total: f32 = 0;
    for (sizes, 0..) |*sz, i| sz.* = switch (track(tracks, i)) {
        .px => |v| v,
        .fr => |v| blk: {
            fr_total += v;
            break :blk 0;
        },
        .auto => 0,
    };
    // Single-span contributions to auto and fr tracks.
    for (items, contrib) |item, c| {
        const start: usize = if (vertical) item.cell.row else item.cell.col;
        const span: usize = if (vertical) item.cell.rows else item.cell.cols;
        if (span != 1) continue;
        switch (track(tracks, start)) {
            .px => {},
            .auto, .fr => sizes[start] = @max(sizes[start], c),
        }
    }
    // Spanning items grow the auto tracks they span when they do not fit.
    for (items, contrib) |item, c| {
        const start: usize = if (vertical) item.cell.row else item.cell.col;
        const span: usize = if (vertical) item.cell.rows else item.cell.cols;
        if (span == 1) continue;
        var have: f32 = gap * @as(f32, @floatFromInt(span - 1));
        var autos: f32 = 0;
        for (start..start + span) |k| {
            have += sizes[k];
            if (track(tracks, k) == .auto) autos += 1;
        }
        if (c > have and autos > 0) for (start..start + span) |k| {
            if (track(tracks, k) == .auto) sizes[k] += (c - have) / autos;
        };
    }
    if (fr_total == 0) {
        // Definite space left over grows the auto tracks evenly.
        var autos: f32 = 0;
        for (0..n) |i| if (track(tracks, i) == .auto) {
            autos += 1;
        };
        const left = min - total(sizes, gap);
        if (autos > 0 and left > 0) for (sizes, 0..) |*sz, i| if (track(tracks, i) == .auto) {
            sz.* += left / autos;
        };
        return;
    }
    // fr tracks: one flex fraction that fits every fr track's content...
    var fraction: f32 = 0;
    var fixed: f32 = gap * @as(f32, @floatFromInt(n -| 1));
    for (sizes, 0..) |sz, i| switch (track(tracks, i)) {
        .fr => |v| if (v > 0) {
            fraction = @max(fraction, sz / v);
        },
        else => fixed += sz,
    };
    const used = fixed + fraction * fr_total;
    // ...unless the space is definite or the content does not fit it.
    if (min == max or used > max or used < min) {
        const space = if (min == max) max else if (used > max) max else min;
        fraction = @max(0, space - fixed) / fr_total;
    }
    for (sizes, 0..) |*sz, i| switch (track(tracks, i)) {
        .fr => |v| sz.* = fraction * v,
        else => {},
    };
}

fn spanSize(sizes: []const f32, start: usize, span: usize, gap: f32) f32 {
    var s: f32 = gap * @as(f32, @floatFromInt(span - 1));
    for (sizes[start .. start + span]) |v| s += v;
    return s;
}

fn total(sizes: []const f32, gap: f32) f32 {
    if (sizes.len == 0) return 0;
    return spanSize(sizes, 0, sizes.len, gap);
}

fn gridMaxContent(win: *Window, id: NodeId) Error!f32 {
    const g = win.node(id).data.grid;
    const placed = try placeItems(win, id, true);
    const a = win.scratch.allocator();
    const contrib = try a.alloc(f32, placed.items.len);
    for (placed.items, contrib) |item, *c| c.* = try maxContentInf(win, item.id);
    const cols = try a.alloc(f32, placed.cols);
    sizeTracks(g.columns, cols, placed.items, contrib, false, g.column_gap, 0, inf);
    return total(cols, g.column_gap);
}

fn grid(win: *Window, id: NodeId, inner: Constraints, origin: Point) Error!Size {
    const g = win.node(id).data.grid;
    const rtl = win.state(id).rtl;
    const a = win.scratch.allocator();
    const placed = try placeItems(win, id, false);
    const items = placed.items;

    const contrib = try a.alloc(f32, items.len);
    for (items, contrib) |item, *c| c.* = try maxContent(win, item.id);
    const cols = try a.alloc(f32, placed.cols);
    sizeTracks(g.columns, cols, items, contrib, false, g.column_gap, inner.min_w, inner.max_w);
    const width = inner.clampW(total(cols, g.column_gap));

    // Row heights from the items laid out in their columns.
    for (items, contrib) |item, *c| {
        const l = win.node(item.id).layout;
        const cw = spanSize(cols, item.cell.col, item.cell.cols, g.column_gap);
        c.* = (try measure(win, item.id, widthFor(win, item.id, resolveAlign(l.align_x, g.align_x), cw))).h;
    }
    const rows = try a.alloc(f32, placed.rows);
    sizeTracks(g.rows, rows, items, contrib, true, g.row_gap, inner.min_h, inner.max_h);
    const height = inner.clampH(total(rows, g.row_gap));

    for (items) |item| {
        const l = win.node(item.id).layout;
        const ax = resolveAlign(l.align_x, g.align_x);
        const ay = resolveAlign(l.align_y, g.align_y);
        const cw = spanSize(cols, item.cell.col, item.cell.cols, g.column_gap);
        const ch = spanSize(rows, item.cell.row, item.cell.rows, g.row_gap);
        const sz = try place(win, item.id, both(widthFor(win, item.id, ax, cw), heightFor(win, item.id, ay, ch)));
        const x0 = spanSize(cols, 0, item.cell.col + 1, g.column_gap) - cols[item.cell.col];
        const y0 = spanSize(rows, 0, item.cell.row + 1, g.row_gap) - rows[item.cell.row];
        const left = if (rtl) width - x0 - cw else x0;
        setPos(win, item.id, .{ .x = origin.x + left + alignX(ax, cw, sz.w, rtl), .y = origin.y + y0 + alignY(ay, ch, sz.h) });
    }
    return .{ .w = width, .h = height };
}

// Stack ----------------------------------------------------------------------

fn stack(win: *Window, id: NodeId, inner: Constraints, origin: Point) Error!Size {
    const st = win.node(id).data.stack;
    const rtl = win.state(id).rtl;
    var cw: f32 = inner.max_w;
    if (!inner.tightW()) {
        var w: f32 = 0;
        var it = win.shown(id);
        while (it.next()) |ch| if (!win.node(ch).layout.inset.any()) {
            w = @max(w, try maxContent(win, ch));
        };
        cw = inner.clampW(w);
    }
    // Flowing children decide the height.
    var ch_h: f32 = 0;
    var it = win.shown(id);
    while (it.next()) |ch| {
        const l = win.node(ch).layout;
        if (l.inset.any()) continue;
        const ax = resolveAlign(l.align_x, st.align_x);
        const ay = resolveAlign(l.align_y, st.align_y);
        const c = both(widthFor(win, ch, ax, cw), if (inner.tightH()) heightFor(win, ch, ay, inner.max_h) else .{});
        ch_h = @max(ch_h, (try place(win, ch, c)).h);
    }
    const height = inner.clampH(ch_h);
    it = win.shown(id);
    while (it.next()) |ch| {
        const l = win.node(ch).layout;
        const in = l.inset;
        const ax = resolveAlign(l.align_x, st.align_x);
        const ay = resolveAlign(l.align_y, st.align_y);
        var c: Constraints = undefined;
        if (in.any()) {
            const avail_w = @max(0, cw - (in.start orelse 0) - (in.end orelse 0));
            const avail_h = @max(0, height - (in.top orelse 0) - (in.bottom orelse 0));
            c = .{ .max_w = avail_w, .max_h = avail_h };
            if (in.start != null and in.end != null) c.min_w = avail_w;
            if (in.top != null and in.bottom != null) c.min_h = avail_h;
            if (l.width == .auto and ax == .stretch) c.min_w = avail_w;
            if (l.height == .auto and ay == .stretch) c.min_h = avail_h;
        } else {
            c = both(widthFor(win, ch, ax, cw), heightFor(win, ch, ay, height));
        }
        const sz = try place(win, ch, c);
        const x: f32 = if (in.start) |v|
            (if (rtl) cw - v - sz.w else v)
        else if (in.end) |v|
            (if (rtl) v else cw - v - sz.w)
        else
            alignX(ax, cw, sz.w, rtl);
        const y: f32 = if (in.top) |v| v else if (in.bottom) |v| height - v - sz.h else alignY(ay, height, sz.h);
        setPos(win, ch, .{ .x = origin.x + x, .y = origin.y + y });
    }
    return .{ .w = cw, .h = height };
}

// Leaves ---------------------------------------------------------------------

fn textSize(win: *Window, id: NodeId, inner: Constraints) Error!Size {
    const n = win.node(id);
    const wrap = if (n.kind == .editor) n.data.editor.editor.multiline and n.data.editor.text.props.wrap else n.data.text.props.wrap;
    const width: ?f32 = if (wrap and std.math.isFinite(inner.max_w)) inner.max_w else null;
    const fit: ?f32 = if (std.math.isFinite(inner.max_w)) inner.max_w else null;
    const l = try text_node.layoutIn(win, id, width, fit) orelse return .{ .w = inner.min_w, .h = inner.min_h };
    return .{ .w = if (inner.tightW()) inner.max_w else inner.clampW(l.width()), .h = inner.clampH(l.height()) };
}

/// An external's intrinsic size, if it has one.
fn intrinsic(x: node_mod.External) ?[2]f32 {
    if (x.width < 1 or x.height < 1) return null;
    return .{ @floor(x.width), @floor(x.height) };
}

/// The size of content with intrinsic size `wh`, scaled down to fit.
fn imageSize(wh: ?[2]f32, inner: Constraints) Size {
    const dims = wh orelse return .{ .w = inner.min_w, .h = inner.min_h };
    const iw = dims[0];
    const ih = dims[1];
    if (inner.tightW() and inner.tightH()) return .{ .w = inner.max_w, .h = inner.max_h };
    if (inner.tightW()) return .{ .w = inner.max_w, .h = inner.clampH(inner.max_w * ih / iw) };
    if (inner.tightH()) return .{ .w = inner.clampW(inner.max_h * iw / ih), .h = inner.max_h };
    const k = @min(1, @min(inner.max_w / iw, inner.max_h / ih));
    return .{ .w = inner.clampW(iw * k), .h = inner.clampH(ih * k) };
}

/// A canvas's size within `c`: from its measure callback, else its
/// intrinsic size.
fn canvasSize(win: *Window, id: NodeId, c: Constraints) Size {
    const cv = win.node(id).data.canvas;
    const s: node_mod.CanvasSize = if (cv.measure) |m| m(cv.user, win, id, c.min_w, c.max_w, c.min_h, c.max_h) else .{ .width = cv.width, .height = cv.height };
    const w = if (std.math.isFinite(s.width)) @max(0, s.width) else 0;
    const h = if (std.math.isFinite(s.height)) @max(0, s.height) else 0;
    return .{ .w = c.clampW(w), .h = c.clampH(h) };
}
