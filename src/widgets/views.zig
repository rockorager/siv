//! Virtualized views (D22): lists, trees, tables, and grids that make
//! nodes only for the rows in view.
//!
//! A view is a column of an optional table header over a scroll node
//! whose content is a stack as tall as every row together. Rows are
//! positioned children of that stack (inset from the top, and from the
//! start edge in grids, so they mirror in RTL), taken from a pool: when
//! the scroll node reports its viewport (the `viewport` event, after the
//! compositor scrolled it, D8), rows that left the range plus overscan are
//! moved to items that entered it and bound again by the application's
//! bind callback, inside the view's transaction. A list of millions costs
//! what is on screen.
//!
//! Rows have one height, or with a height callback each its own: then
//! the rows' tops are prefix sums in node data, rebuilt when the rows
//! change (count, refresh, a tree item expanding) and searched by
//! bisection for the range in view, so rows are still placed by
//! arithmetic and the compositor scrolls them as before.
//!
//! Table columns have header cells that sort (reporting `sort`; the
//! header shows the order the application accepts) and a handle at their
//! end edge that resizes them, by pointer, by Ctrl+arrows on the header,
//! or by assistive technology through the handle's value.
//!
//! Selection is a bitset in node data, one bit per row, resized with the
//! count. The cursor is the focused row (roving focus); its row stays
//! bound while it is out of view so it keeps focus. Trees keep their
//! visible items flattened in node data (id, depth, expanded), inserted
//! and removed as items expand and collapse, with the selection's bits
//! shifted along.

const std = @import("std");
const w = @import("widgets.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

const overscan: u32 = 8;
/// Most rows a range holds: views taller than this many rows bind the
/// first of them.
const max_range: u32 = 1024;
const indent: f32 = 16;
const max_columns = 32;
/// A column's resize handle, how far Ctrl+arrows resize, and the widest
/// a column gets.
const handle_width: f32 = 6;
const resize_step: f32 = 8;
const max_column_width: f32 = 4096;

pub const Mode = enum(u8) { list, tree, table, grid };

pub const View = extern struct {
    hdr: w.Header,
    mode: Mode,
    selection: siv.SelectionMode,
    count: u32,
    cursor: i32 = -1,
    anchor: i32 = -1,
    selected: u32 = 0,
    columns: u32 = 1,
    column_count: u32 = 0,
    /// Bumped when every row must be bound again.
    gen: u32 = 0,
    item_h: f32,
    item_w: f32,
    view_y: f32 = 0,
    view_w: f32 = 0,
    view_h: f32 = 0,
    root: Node,
    header: Node = .null,
    scroll: Node,
    content: Node,
    user_data: ?*anyopaque,
    bind: ?siv.BindFn,
    children: ?siv.TreeCountFn,
    child: ?siv.TreeChildFn,
    height: ?siv.ViewHeightFn,
    /// The gen and count the row tops were built for.
    heights_gen: u32 = 0,
    heights_count: u32 = 0,
    heights_built: bool = false,
    /// The header cell that takes focus (roving).
    header_focus: u32 = 0,
    /// A plain press on an item of a larger selection keeps the selection
    /// (a drag carries all of it); the release collapses it to this item
    /// unless a drag started. -1 for none.
    pending: i32 = -1,
    /// Items whose selection changed since the last select event: every
    /// one lies in changed_lo..changed_hi (empty when lo > hi).
    changed_lo: u32 = std.math.maxInt(u32),
    changed_hi: u32 = 0,
};

/// A table column's header cell.
pub const Column = extern struct {
    hdr: w.Header,
    view: Node,
    index: u32,
    sortable: bool,
    fixed: bool,
    dragging: bool = false,
    sort: siv.Sort = .none,
    min: f32,
    grab: f32 = 0,
    cell: Node,
    title: Node,
    arrow: Node,
    handle: Node = .null,
};

pub const Row = extern struct {
    hdr: w.Header,
    gen: u32 = 0,
    /// The row index it shows, or -1.
    index: i64 = -1,
    /// Some bind filled it: the next bind is told it is recycled.
    bound: bool = false,
    view: Node,
    root: Node,
    disclosure: Node = .null,
    body: Node,
};

const TreeRow = extern struct {
    id: u64,
    depth: u32,
    flags: packed struct(u32) { expanded: bool = false, parent: bool = false, _: u30 = 0 },
    /// Its position among its parent's children, and their number.
    position: u32,
    siblings: u32,
};

var selection_key: u8 = 0;
var tree_key: u8 = 0;
var columns_key: u8 = 0;
var heights_key: u8 = 0;

pub export fn siv_list_view(txn: Txn, parent: Node, desc: ?*const siv.ViewDesc) Node {
    return create(txn, parent, desc, .list);
}

pub export fn siv_tree_view(txn: Txn, parent: Node, desc: ?*const siv.ViewDesc) Node {
    return create(txn, parent, desc, .tree);
}

pub export fn siv_table_view(txn: Txn, parent: Node, desc: ?*const siv.ViewDesc) Node {
    return create(txn, parent, desc, .table);
}

pub export fn siv_grid_view(txn: Txn, parent: Node, desc: ?*const siv.ViewDesc) Node {
    return create(txn, parent, desc, .grid);
}

fn create(txn: Txn, parent: Node, desc: ?*const siv.ViewDesc, mode: Mode) Node {
    const d = w.readDesc(siv.ViewDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@backingInt(d.selection) < 0 or @backingInt(d.selection) > 2) return w.fail(txn, .error_unsupported);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 1) != 0 or d.reserved0 != 0) return w.fail(txn, .error_unsupported);
    const flat = d.flags.flat;
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    if (!std.math.isFinite(d.item_height) or !std.math.isFinite(d.item_width) or d.item_height < 0 or d.item_width < 0) return w.fail(txn, .error_invalid_argument);
    if (mode == .tree and (d.children == null or d.child == null)) return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = .column });
    if (root == .null) return .null;
    // The header and rows sit inside the frame's border, with their outer
    // corners rounded to the border's inner curve, so neither paints over
    // it nor loses an edge (a row's focus ring) under it. A flat view has
    // no frame: square, edge to edge.
    const border: f32 = if (flat) 0 else tk.border;
    const inner: f32 = if (flat) 0 else tk.radius - tk.border;
    _ = c.siv_set_default_layout(txn, root, &.{ .grow = 1, .align_x = .stretch, .align_y = .stretch, .padding = .{ .start = border, .end = border, .top = border, .bottom = border } });
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .view_bg, .border_width = border, .border_token = .border, .radius = w.corners(if (flat) 0 else tk.radius), .flags = .{ .clip = true } });
    const v = w.create(View, txn, root) orelse return .null;
    v.* = .{
        .hdr = .{ .kind = .view },
        .mode = mode,
        .selection = d.selection,
        .count = if (mode == .tree) 0 else d.count,
        .item_h = if (d.item_height == 0) 32 else d.item_height,
        .item_w = if (d.item_width == 0) 96 else d.item_width,
        .root = root,
        .scroll = .null,
        .content = .null,
        .user_data = d.user_data,
        .bind = d.bind,
        .children = d.children,
        .child = d.child,
        .height = if (mode == .grid) null else d.height,
    };
    // The application's user data goes with the view: a handler that
    // never runs carries its destroy-notify.
    _ = c.siv_on_default(txn, root, .close, never, d.destroy, d.user_data);
    if (mode == .table) {
        v.header = c.siv_grid(txn, root, null);
        _ = c.siv_set_layout(txn, v.header, &.{ .min_height = 28, .padding = .{ .start = 8, .end = 8 } });
        _ = c.siv_set_visual(txn, v.header, &.{ .background_token = .control_bg, .radius = .{ .top_start = inner, .top_end = inner }, .flags = .{ .clip = true } });
        _ = c.siv_set_semantics(txn, v.header, &.{ .role = .row });
        const rule = c.siv_box(txn, root);
        _ = c.siv_set_layout(txn, rule, &.{ .height = w.px(1) });
        _ = c.siv_set_visual(txn, rule, &.{ .background_token = .separator });
    }
    v.scroll = c.siv_scroll(txn, root, .vertical);
    _ = c.siv_set_layout(txn, v.scroll, &.{ .grow = 1, .basis = w.px(0) });
    {
        const top: f32 = if (mode == .table) 0 else inner;
        _ = c.siv_set_visual(txn, v.scroll, &.{ .radius = .{ .top_start = top, .top_end = top, .bottom_start = inner, .bottom_end = inner }, .flags = .{ .clip = true } });
    }
    v.content = c.siv_stack(txn, v.scroll, null);
    _ = c.siv_set_semantics(txn, v.scroll, &.{
        .role = switch (mode) {
            .tree => .tree,
            .table => .table,
            else => .list,
        },
        .label = label.ptr,
        .label_len = label.len,
    });
    w.onDefault(txn, v.scroll, .viewport, onViewport, v);
    w.onDefault(txn, root, .pointer, onEmptyPointer, v);
    w.setInterface(txn, root, View, v, .{ .set_label = setLabel, .get_part = viewPart, .apply = apply, .focus = focusTarget });
    if (!resizeSelection(txn, v)) return .null;
    if (mode == .tree and !buildTop(txn, v)) return .null;
    // The first rows are bound at once against the window's height, so
    // the first frame shows them; the viewport event refines the range.
    var size: siv.Size = .{ .width = 0, .height = 0 };
    _ = c.siv_window_get_size(w.windowOf(root), &size);
    v.view_w = size.width;
    v.view_h = size.height;
    update(txn, v);
    return root;
}

fn never(_: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    return .pass;
}

fn viewOf(node: Node) ?*View {
    return w.stateOf(View, node, &.{.view});
}

// Storage -----------------------------------------------------------------------

fn bits(v: *const View) []u8 {
    var p: ?*anyopaque = null;
    _ = c.siv_node_get_data(v.root, &selection_key, &p);
    const ptr: [*]u8 = @ptrCast(p orelse return &.{});
    return ptr[0..bitBytes(v.count)];
}

fn bitBytes(count: u32) usize {
    return @max(1, (@as(usize, count) + 7) / 8);
}

/// Sizes the selection to the count, dropping bits past it.
fn resizeSelection(txn: Txn, v: *View) bool {
    var p: ?*anyopaque = null;
    if (c.siv_set_data(txn, v.root, &selection_key, bitBytes(v.count), &p) != .ok) return false;
    const b: [*]u8 = @ptrCast(p.?);
    const n = bitBytes(v.count);
    const used = v.count % 8;
    if (used != 0) b[n - 1] &= @as(u8, 0xff) >> @intCast(8 - used);
    if (v.count == 0) b[0] = 0;
    var total: u32 = 0;
    for (b[0..n]) |x| total += @popCount(x);
    v.selected = total;
    return true;
}

fn isSelected(v: *const View, i: u32) bool {
    if (i >= v.count) return false;
    const b = bits(v);
    return b[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

fn setSelected(v: *View, i: u32, on: bool) void {
    if (i >= v.count) return;
    const b = bits(v);
    const mask = @as(u8, 1) << @intCast(i % 8);
    const was = b[i / 8] & mask != 0;
    if (was == on) return;
    if (on) b[i / 8] |= mask else b[i / 8] &= ~mask;
    if (on) v.selected += 1 else v.selected -= 1;
    markChanged(v, i, i);
}

fn clearSelection(v: *View) void {
    const b = bits(v);
    if (v.selected != 0) {
        const first = std.mem.indexOfNone(u8, b, &.{0}).?;
        const last = std.mem.lastIndexOfNone(u8, b, &.{0}).?;
        markChanged(v, @intCast(first * 8 + @ctz(b[first])), @intCast(last * 8 + 7 - @clz(b[last])));
    }
    @memset(b, 0);
    v.selected = 0;
}

fn markChanged(v: *View, lo: u32, hi: u32) void {
    v.changed_lo = @min(v.changed_lo, lo);
    v.changed_hi = @max(v.changed_hi, hi);
}

/// Forgets changes the application made itself (they are not reported).
fn resetChanged(v: *View) void {
    v.changed_lo = std.math.maxInt(u32);
    v.changed_hi = 0;
}

fn treeRows(v: *const View) []TreeRow {
    var p: ?*anyopaque = null;
    _ = c.siv_node_get_data(v.root, &tree_key, &p);
    const ptr: [*]TreeRow = @ptrCast(@alignCast(p orelse return &.{}));
    return ptr[0..v.count];
}

/// Room for `n` tree rows (at least one, as node data cannot be empty).
fn reserveTree(txn: Txn, v: *View, n: u32) ?[*]TreeRow {
    var p: ?*anyopaque = null;
    if (c.siv_set_data(txn, v.root, &tree_key, @max(1, n) * @sizeOf(TreeRow), &p) != .ok) return null;
    return @ptrCast(@alignCast(p.?));
}

fn treeRow(v: *const View, parent: u64, i: u32, siblings: u32, depth: u32) TreeRow {
    const id = v.child.?(v.user_data, parent, i);
    return .{ .id = id, .depth = depth, .flags = .{ .parent = v.children.?(v.user_data, id) != 0 }, .position = i, .siblings = siblings };
}

fn buildTop(txn: Txn, v: *View) bool {
    const n = v.children.?(v.user_data, 0);
    const rows = reserveTree(txn, v, n) orelse return false;
    for (0..n) |i| rows[i] = treeRow(v, 0, @intCast(i), n, 0);
    v.count = n;
    if (v.cursor >= @as(i64, n)) v.cursor = -1;
    v.anchor = v.cursor;
    return resizeSelection(txn, v);
}

/// Inserts `k` rows after `at`, shifting selection bits and the cursor.
fn insertRows(txn: Txn, v: *View, at: u32, k: u32) ?[*]TreeRow {
    const old = v.count;
    const rows = reserveTree(txn, v, old + k) orelse return null;
    std.mem.copyBackwards(TreeRow, rows[at + 1 + k .. old + k], rows[at + 1 .. old]);
    v.count = old + k;
    if (!resizeSelection(txn, v)) return null;
    var i = v.count;
    while (i > at + 1 + k) {
        i -= 1;
        setSelected(v, i, isSelected(v, i - k));
    }
    for (at + 1..at + 1 + k) |j| setSelected(v, @intCast(j), false);
    if (v.cursor > at) v.cursor += @intCast(k);
    if (v.anchor > at) v.anchor += @intCast(k);
    return rows;
}

fn removeRows(txn: Txn, v: *View, at: u32, k: u32) void {
    const rows = treeRows(v);
    for (at + 1 + k..v.count) |i| setSelected(v, @intCast(i - k), isSelected(v, @intCast(i)));
    std.mem.copyForwards(TreeRow, rows[at + 1 .. v.count - k], rows[at + 1 + k .. v.count]);
    v.count -= k;
    _ = resizeSelection(txn, v);
    if (v.cursor > at + k) v.cursor -= @intCast(k) else if (v.cursor > at) v.cursor = @intCast(at);
    if (v.anchor > at + k) v.anchor -= @intCast(k) else if (v.anchor > at) v.anchor = @intCast(at);
}

fn setExpanded(txn: Txn, v: *View, at: u32, on: bool) void {
    if (v.mode != .tree or at >= v.count) return;
    var r = treeRows(v)[at];
    if (!r.flags.parent or r.flags.expanded == on) return;
    if (on) {
        const k = v.children.?(v.user_data, r.id);
        const rows = insertRows(txn, v, at, k) orelse return;
        for (0..k) |i| rows[at + 1 + i] = treeRow(v, r.id, @intCast(i), k, r.depth + 1);
        rows[at].flags.expanded = true;
    } else {
        var end = at + 1;
        const rows = treeRows(v);
        while (end < v.count and rows[end].depth > r.depth) end += 1;
        removeRows(txn, v, at, end - at - 1);
        r = treeRows(v)[at];
        treeRows(v)[at].flags.expanded = false;
    }
    v.gen +%= 1;
}

// Rows ------------------------------------------------------------------------------

fn lines(v: *const View) u32 {
    return if (v.mode == .grid) (v.count + v.columns - 1) / v.columns else v.count;
}

// Row heights -----------------------------------------------------------------

/// The rows' tops with a height callback: count + 1 of them, the last the
/// total height.
fn tops(v: *const View) []f64 {
    var p: ?*anyopaque = null;
    _ = c.siv_node_get_data(v.root, &heights_key, &p);
    const ptr: [*]f64 = @ptrCast(@alignCast(p orelse return &.{}));
    return ptr[0 .. v.heights_count + 1];
}

fn variable(v: *const View) bool {
    return v.height != null and v.heights_built and v.heights_count == v.count;
}

/// Asks every row's height when the rows changed since the last time.
fn buildHeights(txn: Txn, v: *View) bool {
    const height = v.height orelse return true;
    if (v.heights_built and v.heights_gen == v.gen and v.heights_count == v.count) return true;
    var p: ?*anyopaque = null;
    if (c.siv_set_data(txn, v.root, &heights_key, (@as(usize, v.count) + 1) * @sizeOf(f64), &p) != .ok) return false;
    const out: [*]f64 = @ptrCast(@alignCast(p.?));
    var y: f64 = 0;
    for (0..v.count) |i| {
        out[i] = y;
        const item: u64, const depth: u32 = if (v.mode == .tree) .{ treeRows(v)[i].id, treeRows(v)[i].depth } else .{ i, 0 };
        const h = height(v.user_data, item, @intCast(i), depth);
        y += if (h > 0 and std.math.isFinite(h)) h else v.item_h;
    }
    out[v.count] = y;
    v.heights_gen = v.gen;
    v.heights_count = v.count;
    v.heights_built = true;
    return true;
}

fn rowTop(v: *const View, i: u32) f32 {
    if (variable(v)) return @floatCast(tops(v)[i]);
    const per: u32 = if (v.mode == .grid) v.columns else 1;
    return @as(f32, @floatFromInt(i / per)) * v.item_h;
}

fn rowHeight(v: *const View, i: u32) f32 {
    if (!variable(v)) return v.item_h;
    const t = tops(v);
    return @floatCast(t[i + 1] - t[i]);
}

fn contentHeight(v: *const View) f32 {
    if (variable(v)) return @floatCast(tops(v)[v.count]);
    return @as(f32, @floatFromInt(lines(v))) * v.item_h;
}

/// The row at `y` from the top: the last whose top is at or above it.
fn rowAt(v: *const View, y: f32) u32 {
    if (v.count == 0) return 0;
    if (!variable(v)) {
        const per: u32 = if (v.mode == .grid) v.columns else 1;
        const line: u32 = @intFromFloat(@max(0, @floor(y / v.item_h)));
        return @min(v.count - 1, line * per);
    }
    const t = tops(v)[0..v.count];
    var low: usize = 0;
    var high = t.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (t[mid] <= y) low = mid + 1 else high = mid;
    }
    return @intCast(@max(1, low) - 1);
}

/// Positions, height, and rows for the current count and viewport.
fn update(txn: Txn, v: *View) void {
    if (v.mode == .grid) v.columns = @max(1, @as(u32, @intFromFloat(@floor(v.view_w / v.item_w))));
    if (!buildHeights(txn, v)) return;
    _ = c.siv_set_layout(txn, v.content, &.{ .height = w.px(contentHeight(v)) });
    materialize(txn, v);
}

/// Binds the rows of the range in view (plus overscan) from the pool.
fn materialize(txn: Txn, v: *View) void {
    const per = if (v.mode == .grid) v.columns else 1;
    var lo: u32 = 0;
    var hi: u32 = 0;
    if (variable(v)) {
        const first = rowAt(v, v.view_y);
        const last = rowAt(v, v.view_y + v.view_h) + 1;
        lo = @min(v.count, first -| overscan);
        hi = @min(v.count, @min(lo + max_range, last + overscan));
    } else {
        const first_line: u32 = @intFromFloat(@max(0, @floor(v.view_y / v.item_h)));
        const last_line: u32 = @intFromFloat(@max(0, @ceil((v.view_y + v.view_h) / v.item_h)));
        lo = @min(v.count, (first_line -| overscan) * per);
        hi = @min(v.count, @min(lo + max_range, (last_line + overscan) * per));
    }
    var present: [max_range]bool = @splat(false);
    // Rows that stay; the cursor's row stays even out of range.
    var free: [max_range + 1]Node = undefined;
    var nfree: usize = 0;
    var cur = w.related(v.content, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const r = rowOf(cur) orelse continue;
        const keep = r.index >= 0 and r.index < v.count and
            ((r.index >= lo and r.index < hi) or r.index == v.cursor);
        if (keep) {
            if (r.index >= lo and r.index < hi) present[@intCast(r.index - lo)] = true;
            // A row keeps its index across a rebind of everything, so
            // the focused row stays where it was.
            if (r.gen != v.gen) bindRow(txn, v, r, @intCast(r.index)) else applyRow(txn, v, r);
        } else if (nfree < free.len) {
            free[nfree] = cur;
            nfree += 1;
        }
    }
    var i = lo;
    while (i < hi) : (i += 1) {
        if (present[i - lo]) continue;
        const node = if (nfree > 0) blk: {
            nfree -= 1;
            break :blk free[nfree];
        } else createRow(txn, v);
        const r = rowOf(node) orelse return;
        bindRow(txn, v, r, i);
    }
    for (free[0..nfree]) |n| if (rowOf(n)) |r| {
        _ = c.siv_set_visual(txn, n, &.{ .flags = .{ .hidden = true } });
        r.index = -1;
    };
}

fn rowOf(node: Node) ?*Row {
    return w.stateOf(Row, node, &.{.view_row});
}

fn createRow(txn: Txn, v: *View) Node {
    const row = c.siv_flex(txn, v.content, &.{ .axis = .row, .align_items = .stretch });
    if (row == .null) return .null;
    const r = w.create(Row, txn, row) orelse return .null;
    r.* = .{ .hdr = .{ .kind = .view_row }, .view = v.root, .root = row, .body = .null };
    if (v.mode == .tree) {
        r.disclosure = c.siv_canvas(txn, row, &.{ .user_data = r, .draw = drawDisclosure, .width = indent, .height = indent });
        _ = c.siv_set_layout(txn, r.disclosure, &.{ .width = w.px(indent + 4), .flags = .{ .no_shrink = true } });
    }
    r.body = if (v.mode == .table) c.siv_grid(txn, row, &.{ .align_y = .center }) else c.siv_box(txn, row);
    _ = c.siv_set_layout(txn, r.body, &.{ .grow = 1, .align_y = .center });
    if (v.mode == .table) setColumns(txn, v, r.body);
    w.onDefault(txn, row, .pointer, onRowPointer, r);
    w.onDefault(txn, row, .key, onRowKey, r);
    w.onDefault(txn, row, .activate, onRowActivate, r);
    return row;
}

fn bindRow(txn: Txn, v: *View, r: *Row, index: u32) void {
    // A row hidden in the pool (index -1) still holds its old children.
    const recycled = r.bound;
    r.bound = true;
    r.index = index;
    r.gen = v.gen;
    const item: u64, const depth: u32 = if (v.mode == .tree) .{ treeRows(v)[index].id, treeRows(v)[index].depth } else .{ index, 0 };
    applyRow(txn, v, r);
    if (v.bind) |bind| bind(v.user_data, txn, r.body, item, index, depth, recycled);
}

/// A bound row's place, look, and semantics.
fn applyRow(txn: Txn, v: *View, r: *Row) void {
    const i: u32 = @intCast(r.index);
    const per: u32 = if (v.mode == .grid) v.columns else 1;
    const line: f32 = @floatFromInt(i / per);
    const col: f32 = @floatFromInt(i % per);
    const tr: ?TreeRow = if (v.mode == .tree) treeRows(v)[i] else null;
    const pad_start: f32 = if (tr) |t| 4 + @as(f32, @floatFromInt(t.depth)) * indent else 8;
    if (v.mode == .grid) {
        _ = c.siv_set_layout(txn, r.root, &.{
            .width = w.px(v.item_w),
            .height = w.px(v.item_h),
            .inset_top = line * v.item_h,
            .inset_start = col * v.item_w,
            .padding = .{ .start = 4, .end = 4, .top = 4, .bottom = 4 },
            .flags = .{ .inset_top = true, .inset_start = true },
        });
    } else {
        _ = c.siv_set_layout(txn, r.root, &.{
            .height = w.px(rowHeight(v, i)),
            .inset_top = rowTop(v, i),
            .inset_start = 0,
            .inset_end = 0,
            .padding = .{ .start = pad_start, .end = 8 },
            .flags = .{ .inset_top = true, .inset_start = true, .inset_end = true },
        });
    }
    const sel = isSelected(v, i);
    _ = c.siv_set_visual(txn, r.root, &.{
        .radius = w.corners(if (v.mode == .grid) tk.radius else 0),
        .background_token = if (sel) .selection_bg else if (r.hdr.hover) .control_hover else .none,
    });
    const stop = if (v.cursor >= 0) v.cursor == i else i == 0;
    _ = c.siv_set_semantics(txn, r.root, &.{
        .role = switch (v.mode) {
            .tree => .tree_item,
            .table => .row,
            else => .list_item,
        },
        .selected = if (v.selection == .none) .unset else if (sel) .on else .off,
        .expanded = if (tr) |t| (if (!t.flags.parent) .unset else if (t.flags.expanded) .on else .off) else .unset,
        .flags = .{ .focusable = stop and !v.hdr.disabled, .disabled = v.hdr.disabled },
        // Only the rows in view exist: their place among all items, or
        // a tree item's among its siblings.
        .level = if (tr) |t| t.depth + 1 else 0,
        .position = if (tr) |t| t.position + 1 else if (v.mode == .list or v.mode == .grid) i + 1 else 0,
        .set_size = if (tr) |t| t.siblings else if (v.mode == .table) 0 else v.count,
        .row = if (v.mode == .table) i + 1 else 0,
    });
    if (r.disclosure != .null) _ = c.siv_invalidate(txn, r.disclosure);
}

fn applyAll(txn: Txn, v: *View) void {
    var cur = w.related(v.content, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const r = rowOf(cur) orelse continue;
        if (r.index >= 0 and r.index < v.count and r.gen == v.gen) applyRow(txn, v, r);
    }
}

/// A triangle pointing at the end edge when collapsed, down when open.
fn drawDisclosure(ud: ?*anyopaque, node: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const r: *Row = @ptrCast(@alignCast(ud.?));
    const v = viewOf(r.view) orelse return;
    if (r.index < 0 or r.index >= v.count) return;
    const t = treeRows(v)[@intCast(r.index)];
    if (!t.flags.parent) return;
    const cx = width / 2 + 2;
    const cy = height / 2;
    const s: f32 = 4;
    if (t.flags.expanded) {
        _ = c.siv_draw_move_to(draw, cx - s, cy - s / 2);
        _ = c.siv_draw_line_to(draw, cx + s, cy - s / 2);
        _ = c.siv_draw_line_to(draw, cx, cy + s / 2 + 1);
    } else {
        const dir: f32 = if (w.isRtl(node)) -1 else 1;
        _ = c.siv_draw_move_to(draw, cx - dir * s / 2, cy - s);
        _ = c.siv_draw_line_to(draw, cx + dir * (s / 2 + 1), cy);
        _ = c.siv_draw_line_to(draw, cx - dir * s / 2, cy + s);
    }
    _ = c.siv_draw_close(draw);
    _ = c.siv_draw_fill(draw, &.{ .color = w.color(w.windowOf(node), .muted_fg) }, .{});
}

// Table columns ---------------------------------------------------------------

fn columnTracks(v: *const View) []siv.Track {
    var p: ?*anyopaque = null;
    _ = c.siv_node_get_data(v.root, &columns_key, &p);
    const ptr: [*]siv.Track = @ptrCast(@alignCast(p orelse return &.{}));
    return ptr[0..v.column_count];
}

fn setColumns(txn: Txn, v: *const View, grid: Node) void {
    const tracks = columnTracks(v);
    _ = c.siv_set_grid(txn, grid, &.{ .columns = tracks.ptr, .columns_count = tracks.len, .column_gap = 8, .align_y = .center });
}

pub export fn siv_table_column(txn: Txn, table: Node, desc: ?*const siv.ColumnDesc) Node {
    const v = viewOf(table) orelse return w.fail(txn, .error_invalid_argument);
    if (v.mode != .table) return w.fail(txn, .error_invalid_argument);
    const d = w.readDesc(siv.ColumnDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    const title = w.str(d.title, d.title_len) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 3) != 0) return w.fail(txn, .error_unsupported);
    if (!std.math.isFinite(d.min_width) or d.min_width < 0) return w.fail(txn, .error_invalid_argument);
    if (v.column_count >= max_columns) return w.fail(txn, .error_limit_exceeded);
    var p: ?*anyopaque = null;
    if (c.siv_set_data(txn, v.root, &columns_key, max_columns * @sizeOf(siv.Track), &p) != .ok) return .null;
    const tracks: [*]siv.Track = @ptrCast(@alignCast(p.?));
    tracks[v.column_count] = if (d.width.unit == .auto) .{ .unit = .fr, .value = 1 } else d.width;
    // A row of the title, the sort indicator, and the resize handle at
    // the end edge.
    const cell = c.siv_flex(txn, v.header, &.{ .axis = .row, .align_items = .stretch, .gap = 4 });
    const col = w.create(Column, txn, cell) orelse return .null;
    col.* = .{
        .hdr = .{ .kind = .view_column },
        .view = v.root,
        .index = v.column_count,
        .sortable = d.flags.sortable,
        .fixed = d.flags.fixed,
        .min = if (d.min_width == 0) 32 else d.min_width,
        .cell = cell,
        .title = c.siv_text(txn, cell, title.ptr, title.len),
        .arrow = .null,
    };
    v.column_count += 1;
    _ = c.siv_set_layout(txn, col.title, &.{ .grow = 1, .basis = w.px(0), .align_y = .center });
    _ = c.siv_set_text_style(txn, col.title, &.{ .color_token = .muted_fg, .size_role = .caption, .weight = .semibold, .flags = .{ .no_wrap = true } });
    col.arrow = c.siv_canvas(txn, cell, &.{ .user_data = col, .draw = drawSortArrow, .width = 10, .height = 10 });
    _ = c.siv_set_layout(txn, col.arrow, &.{ .align_y = .center, .flags = .{ .no_shrink = true } });
    if (!col.fixed) {
        col.handle = c.siv_box(txn, cell);
        _ = c.siv_set_layout(txn, col.handle, &.{ .width = w.px(handle_width), .flags = .{ .no_shrink = true } });
        _ = c.siv_set_cursor(txn, col.handle, .col_resize);
        w.onDefault(txn, col.handle, .pointer, onHandlePointer, col);
        w.onDefault(txn, col.handle, .set_value, onHandleSetValue, col);
    }
    w.onDefault(txn, cell, .key, onHeaderKey, col);
    w.onDefault(txn, cell, .focus, onHeaderFocus, col);
    if (col.sortable) w.onDefault(txn, cell, .activate, onHeaderActivate, col);
    w.setInterface(txn, cell, Column, col, .{ .set_label = setColumnLabel, .set_value = setColumnValue, .get_value = columnValue });
    setColumns(txn, v, v.header);
    applyHeader(txn, v);
    var cur = w.related(v.content, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        if (rowOf(cur)) |r| setColumns(txn, v, r.body);
    }
    return cell;
}

fn columnOf(node: Node) ?*Column {
    return w.stateOf(Column, node, &.{.view_column});
}

/// The header cell of column `k`.
fn columnAt(v: *const View, k: u32) ?*Column {
    if (v.header == .null) return null;
    var cur = w.related(v.header, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const col = columnOf(cur) orelse continue;
        if (col.index == k) return col;
    }
    return null;
}

/// A column's width: its px track, else its header cell's from the last
/// layout.
fn columnWidth(v: *const View, col: *const Column) f32 {
    const tr = columnTracks(v)[col.index];
    if (tr.unit == .px) return tr.value;
    var r: siv.Rect = undefined;
    if (c.siv_node_get_rect(col.cell, &r) == .ok and r.width > 0) return r.width;
    return col.min;
}

/// Every header cell's semantics, indicator, and handle: the focused one
/// takes focus (roving), sorted ones say how, and handles expose the
/// width as their value.
fn applyHeader(txn: Txn, v: *View) void {
    var cur = w.related(v.header, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const col = columnOf(cur) orelse continue;
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        _ = c.siv_node_get_text(col.title, &buf, buf.len, &len);
        const title = buf[0..@min(len, buf.len)];
        _ = c.siv_set_semantics(txn, col.cell, &.{
            .role = .column_header,
            .label = title.ptr,
            .label_len = title.len,
            .sort = col.sort,
            .column = col.index + 1,
            .flags = .{ .focusable = col.index == v.header_focus and !v.hdr.disabled, .disabled = v.hdr.disabled },
        });
        _ = c.siv_set_visual(txn, col.cell, &.{ .background_token = if (col.hdr.pressed) .control_active else if (col.hdr.hover and col.sortable) .control_hover else .none });
        _ = c.siv_set_visual(txn, col.arrow, &.{ .flags = .{ .hidden = col.sort == .none } });
        _ = c.siv_invalidate(txn, col.arrow);
        if (col.handle != .null) {
            const width = columnWidth(v, col);
            _ = c.siv_set_visual(txn, col.handle, &.{ .background_token = if (col.dragging or col.hdr.hover) .separator else .none });
            _ = c.siv_set_semantics(txn, col.handle, &.{
                .role = .separator,
                .label = title.ptr,
                .label_len = title.len,
                .value_min = col.min,
                .value_max = @max(max_column_width, width),
                .value_now = width,
                .value_step = resize_step,
                .flags = .{ .has_value = true, .disabled = v.hdr.disabled },
            });
        }
    }
}

/// Sets column `k` to a px width, on the header and every row.
fn setColumnWidth(txn: Txn, v: *View, col: *Column, width: f32) void {
    const tracks = columnTracks(v);
    tracks[col.index] = .{ .unit = .px, .value = std.math.clamp(width, col.min, @max(col.min, max_column_width)) };
    setColumns(txn, v, v.header);
    var cur = w.related(v.content, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        if (rowOf(cur)) |r| setColumns(txn, v, r.body);
    }
    applyHeader(txn, v);
}

/// The user resized a column: apply it and tell the application.
fn userResize(v: *View, col: *Column, window: siv.Window, width: f32, report: bool) void {
    const txn = w.begin(window) orelse return;
    setColumnWidth(txn, v, col, width);
    if (!w.commit(txn)) return;
    if (report) w.emitChange(col.cell, columnTracks(v)[col.index].value, col.index);
}

fn setSort(txn: Txn, v: *View, k: u32, sort: siv.Sort) void {
    var cur = w.related(v.header, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const col = columnOf(cur) orelse continue;
        col.sort = if (col.index == k) sort else .none;
    }
    applyHeader(txn, v);
}

/// An arrow pointing up for ascending, down for descending.
fn drawSortArrow(ud: ?*anyopaque, node: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const col: *Column = @ptrCast(@alignCast(ud.?));
    if (col.sort == .none) return;
    const cx = width / 2;
    const cy = height / 2;
    const s: f32 = 4;
    const dir: f32 = if (col.sort == .ascending) -1 else 1;
    _ = c.siv_draw_move_to(draw, cx - s, cy - dir * s / 2);
    _ = c.siv_draw_line_to(draw, cx + s, cy - dir * s / 2);
    _ = c.siv_draw_line_to(draw, cx, cy + dir * s / 2);
    _ = c.siv_draw_close(draw);
    _ = c.siv_draw_fill(draw, &.{ .color = w.color(w.windowOf(node), .muted_fg) }, .{});
}

fn focusHeader(v: *View) void {
    const col = columnAt(v, v.header_focus) orelse columnAt(v, 0) orelse return;
    _ = c.siv_node_focus(col.cell);
}

fn moveHeaderFocus(v: *View, k: u32, window: siv.Window) void {
    if (k >= v.column_count) return;
    v.header_focus = k;
    const txn = w.begin(window) orelse return;
    applyHeader(txn, v);
    if (!w.commit(txn)) return;
    focusHeader(v);
}

/// A sortable header asks the application to sort: ascending first, then
/// flipping; the header shows it once the application's handler accepts.
fn onHeaderActivate(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const col: *Column = @ptrCast(@alignCast(ud.?));
    const v = viewOf(col.view) orelse return .pass;
    if (v.hdr.disabled) return .pass;
    const next: siv.Sort = if (col.sort == .ascending) .descending else .ascending;
    var handled = false;
    _ = c.siv_node_emit(v.root, &.{ .type = .sort, .index = col.index, .value = if (next == .ascending) 1 else -1 }, &handled);
    const txn = w.begin(ev.window) orelse return .handled;
    v.header_focus = col.index;
    if (handled) setSort(txn, v, col.index, next) else applyHeader(txn, v);
    _ = w.commit(txn);
    return .handled;
}

fn onHeaderFocus(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const col: *Column = @ptrCast(@alignCast(ud.?));
    const v = viewOf(col.view) orelse return .pass;
    // Widths from layout reach the handles' values.
    if (ev.flags.gained) {
        const txn = w.begin(ev.window) orelse return .pass;
        applyHeader(txn, v);
        _ = w.commit(txn);
    }
    return .pass;
}

/// Left and Right (mirrored in RTL) move between header cells, Home and
/// End to the first and last; Ctrl with them narrows and widens the
/// column; Down goes to the rows. Enter and Space sort through the
/// activate handler.
fn onHeaderKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const col: *Column = @ptrCast(@alignCast(ud.?));
    const e = ev;
    const v = viewOf(col.view) orelse return .pass;
    if (!e.flags.pressed or v.hdr.disabled) return .pass;
    const k = w.keysym;
    const rtl = w.isRtl(v.root);
    const forward = (e.keysym == k.right) != rtl;
    switch (e.keysym) {
        k.left, k.right => {
            if (e.modifiers.ctrl) {
                if (col.fixed) return .handled;
                userResize(v, col, e.window, columnWidth(v, col) + if (forward) resize_step else -resize_step, true);
            } else if (forward) {
                moveHeaderFocus(v, col.index + 1, e.window);
            } else if (col.index > 0) {
                moveHeaderFocus(v, col.index - 1, e.window);
            }
        },
        k.home => moveHeaderFocus(v, 0, e.window),
        k.end => moveHeaderFocus(v, v.column_count -| 1, e.window),
        k.down => {
            if (v.count == 0) return .handled;
            moveCursor(v, if (v.cursor >= 0) v.cursor else 0, e.window, .{}, false);
        },
        else => return .pass,
    }
    return .handled;
}

/// Dragging a handle moves the column's end edge with the pointer;
/// `grab` is where in the handle it was pressed.
fn onHandlePointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const col: *Column = @ptrCast(@alignCast(ud.?));
    const e = ev;
    const v = viewOf(col.view) orelse return .pass;
    if (v.hdr.disabled) return .pass;
    switch (e.phase) {
        .down => {
            if (e.button != .primary) return .pass;
            col.dragging = true;
            col.grab = e.x;
            restyleHeader(v, e.window);
            return .handled;
        },
        .move => if (col.dragging) {
            // Window coordinates from the last layout, so that moves
            // arriving before the next frame do not add up.
            var cell: siv.Rect = undefined;
            var handle: siv.Rect = undefined;
            if (c.siv_node_get_rect(col.cell, &cell) != .ok or c.siv_node_get_rect(col.handle, &handle) != .ok) return .pass;
            const left = handle.x + e.x - col.grab;
            const width = if (w.isRtl(v.root)) cell.x + cell.width - left else left + handle_width - cell.x;
            userResize(v, col, e.window, width, false);
            return .handled;
        },
        .up, .cancel => if (col.dragging) {
            col.dragging = false;
            restyleHeader(v, e.window);
            w.emitChange(col.cell, columnWidth(v, col), col.index);
            return .handled;
        },
        .enter, .leave => {
            col.hdr.hover = e.phase == .enter;
            restyleHeader(v, e.window);
        },
        else => {},
    }
    return .pass;
}

fn onHandleSetValue(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const col: *Column = @ptrCast(@alignCast(ud.?));
    const v = viewOf(col.view) orelse return .pass;
    if (v.hdr.disabled) return .pass;
    const width: f32 = @floatCast(@round(ev.value / resize_step) * resize_step);
    userResize(v, col, ev.window, width, true);
    return .handled;
}

fn restyleHeader(v: *View, window: siv.Window) void {
    const txn = w.begin(window) orelse return;
    applyHeader(txn, v);
    _ = w.commit(txn);
}

// Navigation and selection -----------------------------------------------------

/// Moves the cursor to `to`, selecting per the mode and modifiers, keeps
/// it in view and focused, and reports the selection.
fn moveCursor(v: *View, to: i64, window: siv.Window, mods: siv.Modifiers, toggle: bool) void {
    if (v.count == 0) return;
    const target: u32 = @intCast(std.math.clamp(to, 0, @as(i64, v.count) - 1));
    const txn = w.begin(window) orelse return;
    v.cursor = @intCast(target);
    const before = v.selected;
    var changed = false;
    switch (v.selection) {
        .single => if (!mods.ctrl or toggle) {
            changed = !isSelected(v, target) or v.selected != 1;
            clearSelection(v);
            setSelected(v, target, true);
        },
        .multiple => if (toggle) {
            setSelected(v, target, !isSelected(v, target));
            changed = true;
            v.anchor = @intCast(target);
        } else if (mods.shift and v.anchor >= 0) {
            if (!mods.ctrl) clearSelection(v);
            const a: u32 = @intCast(v.anchor);
            var i = @min(a, target);
            while (i <= @max(a, target)) : (i += 1) setSelected(v, i, true);
            changed = true;
        } else if (!mods.ctrl) {
            changed = !isSelected(v, target) or v.selected != 1;
            clearSelection(v);
            setSelected(v, target, true);
            v.anchor = @intCast(target);
        },
        else => {},
    }
    if (v.anchor < 0 or v.selection != .multiple) v.anchor = @intCast(target);
    reveal(txn, v, target);
    applyAll(txn, v);
    if (!w.commit(txn)) return;
    focusCursor(v);
    if (changed or before != v.selected) emitSelect(v);
}

fn emitSelect(v: *View) void {
    var handled = false;
    const i: u32 = if (v.cursor >= 0) @intCast(v.cursor) else 0;
    const lo, const n = if (v.changed_lo <= v.changed_hi) .{ v.changed_lo, v.changed_hi - v.changed_lo + 1 } else .{ i, 0 };
    resetChanged(v);
    _ = c.siv_node_emit(v.root, &.{ .type = .select, .index = i, .value = @floatFromInt(v.cursor), .count = v.selected, .changed_index = lo, .changed_count = n }, &handled);
}

/// Moves the cursor to `to` and focuses it without changing the
/// selection.
fn moveCursorOnly(v: *View, to: u32, window: siv.Window) void {
    const txn = w.begin(window) orelse return;
    v.cursor = @intCast(to);
    v.anchor = @intCast(to);
    reveal(txn, v, to);
    applyAll(txn, v);
    if (!w.commit(txn)) return;
    focusCursor(v);
}

/// Scrolls so that row `i` is in view, and binds rows for the new range.
fn reveal(txn: Txn, v: *View, i: u32) void {
    const top = rowTop(v, i);
    const h = rowHeight(v, i);
    var y = v.view_y;
    if (top < y) y = top else if (top + h > y + v.view_h) y = top + h - v.view_h;
    if (y != v.view_y) {
        v.view_y = @max(0, y);
        _ = c.siv_scroll_to(txn, v.scroll, 0, v.view_y);
    }
    materialize(txn, v);
}

fn focusCursor(v: *View) void {
    if (v.cursor < 0) return;
    if (boundRow(v, @intCast(v.cursor))) |r| _ = c.siv_node_focus(r.root);
}

/// A primary press on the view's own empty space (below the rows, or its
/// frame) focuses the view and is done: without this, its release would
/// activate the view's root, where applications listen for an item's
/// activation, and report item 0. Rows, the header, and controls in them
/// take their own presses first.
fn onEmptyPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const v: *View = @ptrCast(@alignCast(ud.?));
    if (ev.phase != .down or ev.button != .primary or v.hdr.disabled) return .pass;
    if (ev.target != v.root and ev.target != v.scroll and ev.target != v.content) return .pass;
    _ = c.siv_node_focus(v.root);
    return .handled;
}

fn onViewport(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const v: *View = @ptrCast(@alignCast(ud.?));
    const e = ev;
    v.view_y = e.y;
    v.view_w = e.width;
    v.view_h = e.height;
    const txn = w.begin(e.window) orelse return .pass;
    update(txn, v);
    _ = w.commit(txn);
    return .handled;
}

fn onRowPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const r: *Row = @ptrCast(@alignCast(ud.?));
    const e = ev;
    const v = viewOf(r.view) orelse return .pass;
    if (v.hdr.disabled or r.index < 0) return .pass;
    switch (e.phase) {
        .enter, .leave => {
            r.hdr.hover = e.phase == .enter;
            const txn = w.begin(e.window) orelse return .pass;
            applyRow(txn, v, r);
            _ = w.commit(txn);
            return .pass;
        },
        .down => {
            if (e.button != .primary) return .pass;
            // A press in an editor inside the row (renaming an item) is
            // the editor's: it places the caret, and focus stays there.
            // So is a press on a control in the row (a drive's eject
            // button), which activates it on release.
            if (e.target != r.root and (isEditor(e.target) or inControl(e.target, r.root))) return .pass;
            // The disclosure toggles the item instead of selecting it.
            if (v.mode == .tree and r.disclosure != .null) {
                var rr: siv.Rect = undefined;
                var dr: siv.Rect = undefined;
                if (c.siv_node_get_rect(r.root, &rr) == .ok and c.siv_node_get_rect(r.disclosure, &dr) == .ok) {
                    const x = rr.x + e.x;
                    if (x >= dr.x and x < dr.x + dr.width) {
                        toggleExpanded(v, @intCast(r.index), e.window);
                        return .handled;
                    }
                }
            }
            const index = r.index;
            const plain = !e.modifiers.ctrl and !e.modifiers.shift;
            if (plain and v.selection == .multiple and v.selected > 1 and isSelected(v, @intCast(index))) {
                // Keep the selection for a drag; the release collapses it.
                v.pending = @intCast(index);
                moveCursorOnly(v, @intCast(index), e.window);
            } else {
                v.pending = -1;
                moveCursor(v, index, e.window, e.modifiers, e.modifiers.ctrl and v.selection == .multiple);
            }
            // A double click activates the item, like Enter.
            if (e.clicks == 2 and plain) {
                var handled = false;
                _ = c.siv_node_emit(v.root, &.{ .type = .activate, .index = @intCast(index), .value = @floatFromInt(index) }, &handled);
            }
            return .handled;
        },
        .up => {
            if (e.button != .primary or v.pending < 0) return .pass;
            const index = v.pending;
            v.pending = -1;
            // No drag started: select only the pressed item.
            moveCursor(v, index, e.window, .{}, false);
            return .handled;
        },
        // A drag started (or the compositor took the press).
        .cancel => {
            v.pending = -1;
            return .pass;
        },
        else => return .pass,
    }
}

/// Editors are the nodes with a selection.
/// Whether `n`, or a node between it and the row's root, is a stock
/// control that takes presses.
fn inControl(n: Node, root: Node) bool {
    const controls = [_]w.Kind{ .button, .toggle_button, .check_box, .@"switch", .radio, .slider, .spin_button, .menu_button, .combo_box };
    var cur = n;
    while (cur != .null and cur != root) : (cur = c.siv_node_get_related(cur, .parent)) {
        const h = w.header(cur) orelse continue;
        for (controls) |k| if (h.kind == k) return true;
    }
    return false;
}

fn isEditor(n: Node) bool {
    var caret: u32 = 0;
    var anchor: u32 = 0;
    return c.siv_node_get_selection(n, &caret, &anchor) == .ok;
}

fn toggleExpanded(v: *View, at: u32, window: siv.Window) void {
    const txn = w.begin(window) orelse return;
    v.cursor = @intCast(at);
    setExpanded(txn, v, at, !treeRows(v)[at].flags.expanded);
    update(txn, v);
    _ = w.commit(txn);
    focusCursor(v);
}

/// Assistive technology's SelectChild activates a row: it selects it.
fn onRowActivate(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const r: *Row = @ptrCast(@alignCast(ud.?));
    const v = viewOf(r.view) orelse return .pass;
    if (v.hdr.disabled or r.index < 0) return .pass;
    moveCursor(v, r.index, ev.window, .{}, false);
    return .handled;
}

fn onRowKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const r: *Row = @ptrCast(@alignCast(ud.?));
    const e = ev;
    const v = viewOf(r.view) orelse return .pass;
    if (!e.flags.pressed or v.hdr.disabled or v.count == 0) return .pass;
    // Keys for a focused node inside the row (an editor renaming the item,
    // a button) are that node's: Space types a space, arrows move the
    // caret.
    if (e.target != r.root) return .pass;
    // Alt and Super with any key, and Enter with any modifier, are the
    // application's (Alt+Up goes to the parent folder in a file manager,
    // Ctrl+Enter opens in a new tab).
    if (e.modifiers.alt or e.modifiers.super) return .pass;
    const k = w.keysym;
    const cur: i64 = if (v.cursor >= 0) v.cursor else r.index;
    const per: i64 = if (v.mode == .grid) v.columns else 1;
    const page: i64 = @max(1, @as(i64, @intFromFloat(@floor(v.view_h / v.item_h)))) * per;
    const rtl = w.isRtl(v.root);
    const forward_key = if (rtl) k.left else k.right;
    // With rows of their own heights, a page is the view's height.
    const at: u32 = @intCast(std.math.clamp(cur, 0, @as(i64, v.count) - 1));
    const page_up: i64 = if (variable(v)) rowAt(v, rowTop(v, at) - v.view_h + rowHeight(v, at)) else cur - page;
    const page_down: i64 = if (variable(v)) rowAt(v, rowTop(v, at) + v.view_h) else cur + page;
    switch (e.keysym) {
        k.up => if (cur == 0 and v.mode == .table and v.header != .null) focusHeader(v) else moveCursor(v, cur - per, e.window, e.modifiers, false),
        k.down => moveCursor(v, cur + per, e.window, e.modifiers, false),
        k.page_up => moveCursor(v, @min(page_up, cur - 1), e.window, e.modifiers, false),
        k.page_down => moveCursor(v, @max(page_down, cur + 1), e.window, e.modifiers, false),
        k.home => moveCursor(v, 0, e.window, e.modifiers, false),
        k.end => moveCursor(v, @as(i64, v.count) - 1, e.window, e.modifiers, false),
        k.left, k.right => {
            const forward = e.keysym == forward_key;
            switch (v.mode) {
                .grid => moveCursor(v, if (forward) cur + 1 else cur - 1, e.window, e.modifiers, false),
                .tree => treeKey(v, @intCast(cur), forward, e.window),
                else => return .pass,
            }
        },
        k.space => {
            if (v.selection == .none) return .pass;
            moveCursor(v, cur, e.window, .{}, v.selection == .multiple and e.modifiers.ctrl);
        },
        k.@"return", k.kp_enter => {
            if (e.modifiers.ctrl or e.modifiers.shift) return .pass;
            var handled = false;
            _ = c.siv_node_emit(v.root, &.{ .type = .activate, .index = @intCast(cur), .value = @floatFromInt(cur) }, &handled);
        },
        @as(siv.Key, @enumFromInt('a')), @as(siv.Key, @enumFromInt('A')) => {
            if (!e.modifiers.ctrl or v.selection != .multiple) return .pass;
            const txn = w.begin(e.window) orelse return .handled;
            for (0..v.count) |i| setSelected(v, @intCast(i), true);
            applyAll(txn, v);
            if (w.commit(txn)) emitSelect(v);
        },
        else => return .pass,
    }
    return .handled;
}

/// Forward expands a collapsed item or moves to its first child; back
/// collapses an expanded item or moves to its parent.
fn treeKey(v: *View, at: u32, forward: bool, window: siv.Window) void {
    const t = treeRows(v)[at];
    if (forward) {
        if (t.flags.parent and !t.flags.expanded) return toggleExpanded(v, at, window);
        if (t.flags.expanded and at + 1 < v.count) return moveCursor(v, at + 1, window, .{}, false);
    } else {
        if (t.flags.expanded) return toggleExpanded(v, at, window);
        var p = at;
        while (p > 0) {
            p -= 1;
            if (treeRows(v)[p].depth < t.depth) return moveCursor(v, p, window, .{}, false);
        }
    }
}

// Exports -------------------------------------------------------------------------

pub export fn siv_view_set_count(txn: Txn, view: Node, count: u32) void {
    const v = viewOf(view) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    if (v.mode == .tree) {
        if (!buildTop(txn, v)) return;
    } else {
        v.count = count;
        if (!resizeSelection(txn, v)) return;
        if (v.cursor >= @as(i64, count)) v.cursor = if (count == 0) -1 else @intCast(count - 1);
        if (v.anchor >= @as(i64, count)) v.anchor = v.cursor;
    }
    resetChanged(v);
    v.gen +%= 1;
    update(txn, v);
    return;
}

pub export fn siv_view_refresh(txn: Txn, view: Node) void {
    const v = viewOf(view) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    v.gen +%= 1;
    update(txn, v);
    return;
}

pub export fn siv_view_set_selected(txn: Txn, view: Node, index: u32, selected: bool) void {
    const v = viewOf(view) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    if (index >= v.count or v.selection == .none) return c.siv_txn_fail(txn, .error_invalid_argument);
    if (v.selection == .single and selected) {
        clearSelection(v);
        v.cursor = @intCast(index);
        setSelected(v, index, selected);
        resetChanged(v);
        applyAll(txn, v);
        return;
    }
    setSelected(v, index, selected);
    resetChanged(v);
    // Only the row showing the item changes, if it is bound: restyling
    // every row per call made selecting many items one by one quadratic.
    var cur = w.related(v.content, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const r = rowOf(cur) orelse continue;
        if (r.index == index and r.gen == v.gen) applyRow(txn, v, r);
    }
    return;
}

pub export fn siv_view_set_expanded(txn: Txn, view: Node, index: u32, expanded: bool) void {
    const v = viewOf(view) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    if (v.mode != .tree or index >= v.count) return c.siv_txn_fail(txn, .error_invalid_argument);
    setExpanded(txn, v, index, expanded);
    update(txn, v);
    return;
}

pub export fn siv_view_scroll_to(txn: Txn, view: Node, index: u32) void {
    const v = viewOf(view) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    if (index >= v.count) return c.siv_txn_fail(txn, .error_invalid_argument);
    reveal(txn, v, index);
    return;
}

pub export fn siv_view_set_sort(txn: Txn, view: Node, column: u32, sort: siv.Sort) void {
    const v = viewOf(view) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    if (v.mode != .table or column >= v.column_count) return c.siv_txn_fail(txn, .error_invalid_argument);
    if (@backingInt(sort) < 0 or @backingInt(sort) > 2) return c.siv_txn_fail(txn, .error_unsupported);
    setSort(txn, v, column, sort);
    return;
}

pub export fn siv_view_is_selected(view: Node, index: u32, selected: ?*bool) siv.Result {
    const out = selected orelse return .error_invalid_argument;
    const v = viewOf(view) orelse return .error_invalid_argument;
    if (index >= v.count) return .error_invalid_argument;
    out.* = isSelected(v, index);
    return .ok;
}

pub export fn siv_view_set_selection(txn: Txn, view: Node, bitset: ?[*]const u8, bitset_count: usize) void {
    const v = viewOf(view) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    if (bitset_count != 0 and bitset == null) return c.siv_txn_fail(txn, .error_invalid_argument);
    const src = if (bitset_count == 0) &[_]u8{} else bitset.?[0..bitset_count];
    const b = bits(v);
    const n = @min(src.len, (@as(usize, v.count) + 7) / 8);
    var total: u32 = 0;
    for (src[0..n], 0..) |x, i| {
        // Bits past the count are not items.
        const keep: u8 = if ((i + 1) * 8 <= v.count) 0xff else @as(u8, 0xff) >> @intCast((i + 1) * 8 - v.count);
        total += @popCount(x & keep);
    }
    if (total != 0 and v.selection == .none) return c.siv_txn_fail(txn, .error_invalid_argument);
    if (total > 1 and v.selection == .single) return c.siv_txn_fail(txn, .error_invalid_argument);
    @memset(b, 0);
    for (src[0..n], 0..) |x, i| {
        const keep: u8 = if ((i + 1) * 8 <= v.count) 0xff else @as(u8, 0xff) >> @intCast((i + 1) * 8 - v.count);
        b[i] = x & keep;
    }
    v.selected = total;
    resetChanged(v);
    applyAll(txn, v);
    return;
}

pub export fn siv_view_get_selection(view: Node, out: ?[*]u8, out_cap: usize, len: ?*usize) siv.Result {
    const total = len orelse return .error_invalid_argument;
    if (out_cap != 0 and out == null) return .error_invalid_argument;
    const v = viewOf(view) orelse return .error_invalid_argument;
    const n = (@as(usize, v.count) + 7) / 8;
    const k = @min(n, out_cap);
    if (k != 0) @memcpy(out.?[0..k], bits(v)[0..k]);
    total.* = n;
    return .ok;
}

pub export fn siv_view_get_cursor(view: Node, index: ?*i32) siv.Result {
    const out = index orelse return .error_invalid_argument;
    const v = viewOf(view) orelse return .error_invalid_argument;
    out.* = v.cursor;
    return .ok;
}

pub export fn siv_view_set_cursor(txn: Txn, view: Node, index: i32) void {
    const v = viewOf(view) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    if (index >= @as(i64, v.count) or index < -1) return c.siv_txn_fail(txn, .error_invalid_argument);
    setCursor(txn, v, @floatFromInt(index));
    return;
}

/// Focusing a view focuses its cursor's row (roving focus), moving the
/// cursor to the first row if it has none; an empty view focuses its
/// scroll node.
fn focusTarget(v: *View) Node {
    if (v.hdr.disabled) return .null;
    if (v.count == 0) return v.scroll;
    if (v.cursor < 0) {
        const txn = w.begin(w.windowOf(v.root)) orelse return .null;
        setCursor(txn, v, 0);
        if (!w.commit(txn)) return .null;
    }
    const row = boundRow(v, @intCast(v.cursor)) orelse return .null;
    return row.root;
}

/// Tables: the header cell of a column.
fn viewPart(v: *const View, p: siv.WidgetPart, index: u32) Node {
    if (p != .column) return .null;
    const col = columnAt(v, index) orelse return .null;
    return col.cell;
}

pub export fn siv_view_get_row(view: Node, index: u32) Node {
    const v = viewOf(view) orelse return .null;
    if (index >= v.count) return .null;
    return if (boundRow(v, index)) |r| r.body else .null;
}

/// The row bound to item `i`, if it is in view (or is the cursor's).
fn boundRow(v: *const View, i: u32) ?*Row {
    var cur = w.related(v.content, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const r = rowOf(cur) orelse continue;
        if (r.index == i and r.gen == v.gen) return r;
    }
    return null;
}

pub export fn siv_view_get_item(view: Node, index: u32, item: ?*u64) siv.Result {
    const out = item orelse return .error_invalid_argument;
    const v = viewOf(view) orelse return .error_invalid_argument;
    if (index >= v.count) return .error_invalid_argument;
    out.* = if (v.mode == .tree) treeRows(v)[index].id else index;
    return .ok;
}

/// A column's label is its title; its value is its width.
pub fn setColumnLabel(txn: Txn, col: *Column, label: []const u8) void {
    _ = c.siv_set_text(txn, col.title, label.ptr, label.len);
    if (viewOf(col.view)) |v| applyHeader(txn, v);
}

pub fn columnValue(col: *const Column) f64 {
    const v = viewOf(col.view) orelse return 0;
    return columnWidth(v, col);
}

pub fn setColumnValue(txn: Txn, col: *Column, width: f64) void {
    const v = viewOf(col.view) orelse return;
    setColumnWidth(txn, v, col, @floatCast(width));
}

pub fn setLabel(txn: Txn, v: *View, label: []const u8) void {
    var role: siv.Role = .list;
    if (v.mode == .tree) role = .tree;
    if (v.mode == .table) role = .table;
    _ = c.siv_set_semantics(txn, v.scroll, &.{ .role = role, .label = label.ptr, .label_len = label.len });
}

pub fn setCursor(txn: Txn, v: *View, to: f64) void {
    const i: i64 = @intFromFloat(@round(to));
    v.cursor = if (i >= 0 and i < v.count) @intCast(i) else -1;
    v.anchor = v.cursor;
    if (v.cursor >= 0) reveal(txn, v, @intCast(v.cursor));
    applyAll(txn, v);
}

pub fn apply(txn: Txn, v: *View) void {
    applyAll(txn, v);
    if (v.header != .null) applyHeader(txn, v);
}
