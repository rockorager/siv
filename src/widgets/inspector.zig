//! The inspector (D46): a stock widget on the public introspection API
//! that browses another window of the application. A toolbar picks a
//! node by pointing at it and turns the bounds and repaint overlays on;
//! beside a tree of the window's nodes, tabs show the selected node's
//! boxes and properties (edited as typed, siv_set_property), its theme's
//! colors and subtree theme (D43), and the window's frame and
//! presentation counters.
//!
//! It hooks into the window it inspects (siv_window_set_inspect_hook)
//! with its root's handle as user data, so a hook that outlives it finds
//! nothing; each frame the window presents refreshes what it shows. Its
//! widget interface's destroy-notify, whose user data is the inspected
//! window's handle, takes the hook and overlays off that window when the
//! inspector goes or looks elsewhere.

const std = @import("std");
const w = @import("widgets.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Inspector = extern struct {
    hdr: w.Header,
    root: Node,
    target: siv.Window = .null,
    selected: Node = .null,
    tree: Node = .null,
    pick: Node = .null,
    bounds: Node = .null,
    repaints: Node = .null,
    summary: Node = .null,
    /// Properties: the selected node's title, its box model, and the
    /// rows, one per property (rows_key).
    title: Node = .null,
    box: Node = .null,
    props: Node = .null,
    rows: u32 = 0,
    /// Theme: the subtree theme's line, and a row per color token.
    scope: Node = .null,
    swatches: Node = .null,
    /// Frames: the counters' values and the chart of frame intervals.
    counters: Node = .null,
    chart: Node = .null,
    flags: siv.InspectFlags = .{},
    /// The inspected window's tree_changes when the tree was last read.
    tree_changes: u64 = 0,
    /// The selected node's boxes, for the box model.
    rect: siv.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    content: siv.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// Intervals between the latest presented frames, in nanoseconds,
    /// oldest first.
    intervals: [chart_frames]u64 = @splat(0),
    interval_count: u32 = 0,
};

const chart_frames = 60;

/// A property's row: the node showing its value (an editor when it can
/// be edited, else a text), and its property index.
const Row = extern struct {
    value: Node,
    editable: bool,
};

var rows_key: u8 = 0;

const tokens = std.enums.values(siv.ColorToken)[1..];

pub export fn siv_inspector(txn: Txn, parent: Node, desc: ?*const siv.InspectorDesc) Node {
    const d = w.readDesc(siv.InspectorDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = .column });
    if (root == .null) return .null;
    const st = w.create(Inspector, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .inspector }, .root = root };
    c.siv_set_default_layout(txn, root, &.{ .grow = 1, .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
    c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    c.siv_set_semantics(txn, root, &.{ .role = .group, .label = "Inspector", .label_len = 9 });

    const bar = c.siv_flex(txn, root, &.{ .gap = 6, .align_items = .center });
    c.siv_set_layout(txn, bar, &.{ .flags = .{ .no_shrink = true }, .padding = .{ .start = 8, .end = 8, .top = 6, .bottom = 6 } });
    c.siv_set_semantics(txn, bar, &.{ .role = .toolbar, .label = "Inspector tools", .label_len = 15 });
    st.pick = c.siv_toggle_button(txn, bar, &.{ .label = "Pick", .label_len = 4 });
    st.bounds = c.siv_toggle_button(txn, bar, &.{ .label = "Bounds", .label_len = 6 });
    st.repaints = c.siv_toggle_button(txn, bar, &.{ .label = "Repaints", .label_len = 8 });
    _ = c.siv_on(txn, st.pick, .change, onToggle, null, w.handleData(root));
    _ = c.siv_on(txn, st.bounds, .change, onToggle, null, w.handleData(root));
    _ = c.siv_on(txn, st.repaints, .change, onToggle, null, w.handleData(root));
    st.summary = label(txn, bar, "", .muted_fg, .caption);
    c.siv_set_layout(txn, st.summary, &.{ .grow = 1, .padding = .{ .start = 8 } });
    const rule = c.siv_box(txn, root);
    c.siv_set_layout(txn, rule, &.{ .height = w.px(1), .flags = .{ .no_shrink = true } });
    c.siv_set_visual(txn, rule, &.{ .background_token = .separator });

    const split = c.siv_split_pane(txn, root, &.{ .position = 320, .min_start = 160, .min_end = 280, .label = "Node tree", .label_len = 9 });
    const start = c.siv_widget_get_part(split, .start, 0);
    const end = c.siv_widget_get_part(split, .end, 0);
    st.tree = c.siv_tree_view(txn, start, &.{ .label = "Nodes", .label_len = 5, .user_data = st, .bind = bind, .children = children, .child = child, .item_height = 24, .selection = .single, .flags = .{ .flat = true } });
    c.siv_set_layout(txn, st.tree, &.{ .height = .{ .unit = .fraction, .value = 1 } });
    c.siv_set_visual(txn, st.tree, &.{ .background_token = .view_bg });
    _ = c.siv_on(txn, st.tree, .select, onSelect, null, w.handleData(root));

    const tabs = c.siv_tabs(txn, end, &.{ .label = "Details", .label_len = 7 });
    c.siv_set_layout(txn, tabs, &.{ .height = .{ .unit = .fraction, .value = 1 }, .padding = .{ .start = 8, .top = 6 } });
    const props_panel = page(txn, c.siv_tab(txn, tabs, &.{ .label = "Properties", .label_len = 10 }));
    st.title = label(txn, props_panel, "", .window_fg, .heading);
    st.box = c.siv_canvas(txn, props_panel, &.{ .user_data = w.handleData(root), .draw = drawBox, .height = 132 });
    c.siv_set_semantics(txn, st.box, &.{ .role = .image, .label = "Box model", .label_len = 9 });
    st.props = c.siv_flex(txn, props_panel, &.{ .axis = .column, .gap = 2 });

    const theme_panel = page(txn, c.siv_tab(txn, tabs, &.{ .label = "Theme", .label_len = 5 }));
    st.scope = label(txn, theme_panel, "", .window_fg, .body);
    c.siv_set_text_style(txn, st.scope, &.{ .color_token = .window_fg, .size_role = .body });
    st.swatches = c.siv_grid(txn, theme_panel, &.{ .columns = &tracks3, .columns_count = 3, .column_gap = 10, .row_gap = 4, .align_y = .center });
    for (tokens) |tok| {
        const sw = c.siv_box(txn, st.swatches);
        c.siv_set_layout(txn, sw, &.{ .width = w.px(28), .height = w.px(18) });
        _ = label(txn, st.swatches, @tagName(tok), .window_fg, .body);
        _ = label(txn, st.swatches, "", .muted_fg, .body);
    }

    const frames_panel = page(txn, c.siv_tab(txn, tabs, &.{ .label = "Frames", .label_len = 6 }));
    st.counters = c.siv_grid(txn, frames_panel, &.{ .columns = &tracks2, .columns_count = 2, .column_gap = 16, .row_gap = 4 });
    for (counter_names) |name| {
        _ = label(txn, st.counters, name, .muted_fg, .body);
        _ = label(txn, st.counters, "", .window_fg, .body);
    }
    _ = label(txn, frames_panel, "Intervals between the latest presented frames (the line is 60 Hz)", .muted_fg, .caption);
    st.chart = c.siv_canvas(txn, frames_panel, &.{ .user_data = w.handleData(root), .draw = drawChart, .height = 120 });
    c.siv_set_semantics(txn, st.chart, &.{ .role = .image, .label = "Frame intervals", .label_len = 15 });

    inspect(txn, st, d.window, d.node);
    return root;
}

const tracks2 = [_]siv.Track{ .{ .unit = .px, .value = 190 }, .{ .unit = .fr, .value = 1 } };
const tracks3 = [_]siv.Track{ .{ .unit = .px, .value = 28 }, .{ .unit = .px, .value = 170 }, .{ .unit = .fr, .value = 1 } };

const counter_names = [_][]const u8{
    "Frames built",
    "Nodes laid out",
    "Texts shaped",
    "Text layouts",
    "Layer repaints",
    "Tree changes",
    "Commits",
    "Frames presented",
    "Latest latency",
    "Nodes",
    "Layers",
};

/// A tab's content: a scroll filling the panel over a padded column.
fn page(txn: Txn, panel: Node) Node {
    const scroll = c.siv_scroll(txn, panel, .vertical);
    c.siv_set_layout(txn, scroll, &.{ .height = .{ .unit = .fraction, .value = 1 } });
    const col = c.siv_flex(txn, scroll, &.{ .axis = .column, .gap = 6 });
    c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 4, .end = 12, .bottom = 12 } });
    return col;
}

fn label(txn: Txn, parent: Node, s: []const u8, token: siv.ColorToken, role: siv.SizeRole) Node {
    const n = c.siv_text(txn, parent, s.ptr, s.len);
    c.siv_set_text_style(txn, n, &w.textStyle(token, role));
    return n;
}

pub export fn siv_inspector_inspect(txn: Txn, inspector: Node, window: siv.Window, node: Node) void {
    const st = stateOf(inspector) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    inspect(txn, st, window, node);
}

fn stateOf(node: Node) ?*Inspector {
    return w.stateOf(Inspector, node, &.{.inspector});
}

/// Points the inspector at a window and selects a node there.
fn inspect(txn: Txn, st: *Inspector, window: siv.Window, node: Node) void {
    if (window != .null and (!w.windowAlive(window) or window == w.windowOf(st.root))) return c.siv_txn_fail(txn, .error_invalid_argument);
    if (node != .null and c.siv_node_get_window(node) != window) return c.siv_txn_fail(txn, .error_invalid_argument);
    if (window != st.target) {
        // The interface's destroy-notify takes the hook and overlays off
        // the window inspected before.
        c.siv_set_widget(txn, st.root, &.{ .user_data = @ptrFromInt(@backingInt(window)), .destroy = onDetach });
        st.target = window;
        st.flags = .{};
        st.tree_changes = 0;
        st.selected = .null;
        if (window != .null and c.siv_window_set_inspect_hook(window, onHook, onHookGone, w.handleData(st.root)) != .ok) return c.siv_txn_fail(txn, .error_out_of_memory);
        for ([_]Node{ st.pick, st.bounds, st.repaints }) |b| c.siv_widget_set_value(txn, b, 0);
        readTree(txn, st);
    }
    select(txn, st, if (node != .null) node else c.siv_window_get_root(window));
}

/// The inspected window: its overlays follow the inspector's state.
fn applyOverlay(st: *const Inspector) void {
    if (st.target == .null) return;
    _ = c.siv_window_set_inspect_overlay(st.target, st.flags, st.selected);
}

fn onDetach(ud: ?*anyopaque) callconv(.c) void {
    const window: siv.Window = @fromBackingInt(@intFromPtr(ud));
    if (window == .null) return;
    _ = c.siv_window_set_inspect_overlay(window, .{}, .null);
    _ = c.siv_window_set_inspect_hook(window, null, null, null);
}

/// The hook went: the inspected window is gone, or another inspector
/// took it.
fn onHookGone(ud: ?*anyopaque) callconv(.c) void {
    const st = stateOf(w.dataHandle(ud)) orelse return;
    if (st.target == .null or w.windowAlive(st.target)) return;
    const txn = w.begin(w.windowOf(st.root)) orelse return;
    st.target = .null;
    st.selected = .null;
    readTree(txn, st);
    select(txn, st, .null);
    _ = w.commit(txn);
}

fn onHook(ud: ?*anyopaque, window: siv.Window, kind: siv.InspectEventType, node: Node) callconv(.c) void {
    const st = stateOf(w.dataHandle(ud)) orelse return;
    if (window != st.target) return;
    const txn = w.begin(w.windowOf(st.root)) orelse return;
    switch (kind) {
        .presented => refresh(txn, st),
        .hovered => {},
        .picked => {
            st.flags.pick = false;
            c.siv_widget_set_value(txn, st.pick, 0);
            if (node != .null) select(txn, st, node) else applyOverlay(st);
        },
        else => {},
    }
    _ = w.commit(txn);
}

fn onToggle(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st = stateOf(w.dataHandle(ud)) orelse return .pass;
    const on = ev.value != 0;
    if (node == st.pick) st.flags.pick = on else if (node == st.bounds) st.flags.bounds = on else st.flags.repaints = on;
    applyOverlay(st);
    return .handled;
}

fn onSelect(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st = stateOf(w.dataHandle(ud)) orelse return .pass;
    if (ev.count == 0 or ev.index < 0) return .pass;
    var item: u64 = 0;
    if (c.siv_view_get_item(st.tree, @intCast(ev.index), &item) != .ok) return .handled;
    const node: Node = @fromBackingInt(item);
    if (node == st.selected) return .handled;
    const txn = w.begin(w.windowOf(st.root)) orelse return .handled;
    show(txn, st, node);
    _ = w.commit(txn);
    return .handled;
}

// The tree --------------------------------------------------------------------------

fn nthChild(parent: Node, index: u32) Node {
    var cur = w.related(parent, .first_child);
    var i: u32 = 0;
    while (cur != .null and i < index) : (i += 1) cur = w.related(cur, .next);
    return cur;
}

fn children(ud: ?*anyopaque, parent: u64) callconv(.c) u32 {
    const st: *Inspector = @ptrCast(@alignCast(ud.?));
    if (parent == 0) return if (st.target != .null and w.windowAlive(st.target)) 1 else 0;
    var info: siv.NodeInfo = undefined;
    if (c.siv_node_get_info(@fromBackingInt(parent), &info) != .ok) return 0;
    return info.children;
}

fn child(ud: ?*anyopaque, parent: u64, index: u32) callconv(.c) u64 {
    const st: *Inspector = @ptrCast(@alignCast(ud.?));
    if (parent == 0) return @backingInt(c.siv_window_get_root(st.target));
    return @backingInt(nthChild(@fromBackingInt(parent), index));
}

/// A node as the tree names it: its kind, then its role where its kind
/// does not imply it and its accessible name.
fn describe(node: Node, buf: []u8) struct { []const u8, usize, siv.NodeInfo } {
    var info: siv.NodeInfo = undefined;
    if (c.siv_node_get_info(node, &info) != .ok) return .{ "", 0, undefined };
    var name_buf: [64]u8 = undefined;
    var len: usize = 0;
    _ = c.siv_node_get_name(node, &name_buf, name_buf.len, &len);
    var name = w.fitUtf8(&name_buf, len);
    if (std.mem.indexOfAny(u8, name, "\n\t")) |i| name = name[0..i];
    const kind = @tagName(info.kind);
    var fbs: std.Io.Writer = .fixed(buf);
    fbs.writeAll(kind) catch {};
    const head = fbs.end;
    const role = @tagName(info.role);
    if (!std.mem.eql(u8, role, kindRole(info.kind)) and info.role != .generic) fbs.print(" {s}", .{role}) catch {};
    if (name.len != 0) fbs.print(" “{s}{s}”", .{ name, if (len > name.len) "…" else "" }) catch {};
    if (info.flags.theme) fbs.writeAll(" themed") catch {};
    if (info.flags.hidden) fbs.writeAll(" hidden") catch {};
    return .{ fbs.buffered(), head, info };
}

fn kindRole(k: siv.NodeKind) []const u8 {
    return switch (k) {
        .box, .flex, .grid, .stack, .canvas => "generic",
        .text => "label",
        .editor => "text_input",
        .scroll => "scroll_area",
        .image, .external => "image",
        else => "",
    };
}

fn bind(ud: ?*anyopaque, txn: Txn, row: Node, item: u64, _: u32, _: u32, recycled: bool) callconv(.c) void {
    _ = ud;
    const text = if (recycled) w.related(row, .first_child) else c.siv_text(txn, row, "", 0);
    if (!recycled) c.siv_set_layout(txn, text, &.{ .padding = .{ .start = 4, .end = 8, .top = 3 } });
    var buf: [160]u8 = undefined;
    const s, const head, const info = describe(@fromBackingInt(item), &buf);
    c.siv_set_text(txn, text, s.ptr, s.len);
    const dim = info.flags.hidden or !info.flags.shown;
    c.siv_set_text_style(txn, text, &w.textStyle(if (dim) .disabled_fg else .view_fg, .body));
    const span: siv.TextSpan = .{ .start = @intCast(head), .end = @intCast(s.len), .flags = .{ .color = true }, .color_token = .muted_fg };
    if (s.len > head and !dim) c.siv_set_text_spans(txn, text, &.{ .spans = @ptrCast(&span), .spans_count = 1 }) else c.siv_set_text_spans(txn, text, &.{ .spans = null, .spans_count = 0 });
    c.siv_set_semantics(txn, row, &.{ .label = s.ptr, .label_len = s.len });
}

fn rowCount(tree: Node) u32 {
    var n: u32 = 0;
    var item: u64 = 0;
    while (c.siv_view_get_item(tree, n, &item) == .ok) n += 1;
    return n;
}

fn itemAt(tree: Node, row: u32) Node {
    var item: u64 = 0;
    if (c.siv_view_get_item(tree, row, &item) != .ok) return .null;
    return @fromBackingInt(item);
}

fn findRow(tree: Node, from: u32, node: Node) ?u32 {
    var r = from;
    var item: u64 = 0;
    while (c.siv_view_get_item(tree, r, &item) == .ok) : (r += 1) if (item == @backingInt(node)) return r;
    return null;
}

/// Reads the tree again, keeping the items that were expanded expanded.
fn readTree(txn: Txn, st: *Inspector) void {
    var expanded: [512]Node = undefined;
    var k: usize = 0;
    const rows = rowCount(st.tree);
    var r: u32 = 0;
    while (r + 1 < rows and k < expanded.len) : (r += 1) {
        const a = itemAt(st.tree, r);
        if (w.related(itemAt(st.tree, r + 1), .parent) == a) {
            expanded[k] = a;
            k += 1;
        }
    }
    c.siv_view_set_count(txn, st.tree, 0);
    if (st.target == .null) return;
    var stats: siv.WindowStats = undefined;
    if (c.siv_window_get_stats(st.target, &stats) == .ok) st.tree_changes = stats.tree_changes;
    // The root starts expanded.
    if (k == 0) {
        expanded[0] = c.siv_window_get_root(st.target);
        k = 1;
    }
    for (expanded[0..k]) |n| {
        const row = findRow(st.tree, 0, n) orelse continue;
        c.siv_view_set_expanded(txn, st.tree, row, true);
    }
}

/// Expands the tree down to a node and selects its row.
fn reveal(txn: Txn, st: *Inspector, node: Node) void {
    var chain: [256]Node = undefined;
    var k: usize = 0;
    var cur = node;
    while (cur != .null and k < chain.len) : (cur = w.related(cur, .parent)) {
        chain[k] = cur;
        k += 1;
    }
    var row: u32 = 0;
    var i = k;
    while (i > 1) {
        i -= 1;
        row = findRow(st.tree, row, chain[i]) orelse return;
        c.siv_view_set_expanded(txn, st.tree, row, true);
        row += 1;
    }
    const at = findRow(st.tree, row, node) orelse return;
    c.siv_view_set_selected(txn, st.tree, at, true);
    c.siv_view_set_cursor(txn, st.tree, @intCast(at));
}

// The selected node --------------------------------------------------------------

/// Selects a node, in the tree too.
fn select(txn: Txn, st: *Inspector, node: Node) void {
    show(txn, st, node);
    if (node != .null) reveal(txn, st, node);
}

/// Shows a node's details and highlights it in its window.
fn show(txn: Txn, st: *Inspector, node: Node) void {
    st.selected = node;
    applyOverlay(st);
    buildRows(txn, st);
    refresh(txn, st);
}

fn propertyCount(node: Node) u32 {
    var info: siv.NodeInfo = undefined;
    if (node == .null or c.siv_node_get_info(node, &info) != .ok) return 0;
    return info.properties;
}

fn rowsOf(st: *const Inspector) []Row {
    var p: ?*anyopaque = null;
    if (c.siv_node_get_data(st.root, &rows_key, &p) != .ok) return &.{};
    const base: [*]Row = @ptrCast(@alignCast(p orelse return &.{}));
    return base[0..st.rows];
}

fn propertyName(node: Node, i: u32, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_node_get_property_name(node, i, buf.ptr, buf.len, &len) != .ok) return "";
    return w.fitUtf8(buf, len);
}

fn propertyValue(node: Node, i: u32, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_node_get_property_value(node, i, buf.ptr, buf.len, &len) != .ok) return "";
    return w.fitUtf8(buf, len);
}

const group_names = [_][]const u8{ "Layout", "Container", "Visual", "Text", "Semantics", "Subtree theme" };

/// Makes a row per property of the selected node, under its group's
/// heading.
fn buildRows(txn: Txn, st: *Inspector) void {
    var cur = w.related(st.props, .first_child);
    while (cur != .null) {
        const next = w.related(cur, .next);
        c.siv_remove(txn, cur);
        cur = next;
    }
    const n = propertyCount(st.selected);
    var p: ?*anyopaque = null;
    if (c.siv_set_data(txn, st.root, &rows_key, @max(n, 1) * @sizeOf(Row), &p) != .ok) return;
    const rows: [*]Row = @ptrCast(@alignCast(p.?));
    st.rows = n;
    var group: i32 = -1;
    var name_buf: [64]u8 = undefined;
    for (0..n) |i_| {
        const i: u32 = @intCast(i_);
        var prop: siv.Property = undefined;
        if (c.siv_node_get_property(st.selected, i, &prop) != .ok) {
            rows[i] = .{ .value = .null, .editable = false };
            continue;
        }
        if (@backingInt(prop.group) != group) {
            group = @backingInt(prop.group);
            const g: usize = @intCast(group);
            const head = label(txn, st.props, if (g < group_names.len) group_names[g] else "", .muted_fg, .caption);
            c.siv_set_text_style(txn, head, &.{ .color_token = .muted_fg, .size_role = .caption, .weight = .bold, .flags = .{ .no_wrap = true } });
            c.siv_set_layout(txn, head, &.{ .padding = .{ .top = if (i == 0) 4 else 10, .bottom = 2 } });
            c.siv_set_semantics(txn, head, &.{ .role = .heading, .level = 3 });
        }
        const row = c.siv_grid(txn, st.props, &.{ .columns = &tracks2, .columns_count = 2, .column_gap = 8, .align_y = .center });
        const name = propertyName(st.selected, i, &name_buf);
        const name_node = label(txn, row, name, if (prop.flags.set) .window_fg else .muted_fg, .body);
        c.siv_set_text_style(txn, name_node, &.{ .color_token = if (prop.flags.set) .window_fg else .muted_fg, .size_role = .body, .weight = if (prop.flags.set) .semibold else .regular, .flags = .{ .no_wrap = true } });
        const editable = prop.flags.editable;
        const value = if (editable) blk: {
            const field = c.siv_text_field(txn, row, &.{ .label = name.ptr, .label_len = name.len });
            _ = c.siv_on(txn, field, .change, onEdit, null, w.handleData(st.root));
            break :blk field;
        } else label(txn, row, "", .window_fg, .body);
        if (!editable) c.siv_set_text_style(txn, value, &.{ .color_token = .window_fg, .size_role = .body });
        rows[i] = .{ .value = value, .editable = editable };
    }
}

/// The selected node's property values, boxes, and colors, and the
/// window's counters, as they are now.
fn refresh(txn: Txn, st: *Inspector) void {
    if (st.target != .null and !w.windowAlive(st.target)) st.target = .null;
    var stats: siv.WindowStats = std.mem.zeroes(siv.WindowStats);
    if (st.target != .null) _ = c.siv_window_get_stats(st.target, &stats);
    if (st.target != .null and stats.tree_changes != st.tree_changes) {
        readTree(txn, st);
        var info: siv.NodeInfo = undefined;
        if (st.selected == .null or c.siv_node_get_info(st.selected, &info) != .ok) {
            st.selected = c.siv_window_get_root(st.target);
            applyOverlay(st);
            buildRows(txn, st);
        }
        reveal(txn, st, st.selected);
    }
    var info: siv.NodeInfo = std.mem.zeroes(siv.NodeInfo);
    const live = st.selected != .null and c.siv_node_get_info(st.selected, &info) == .ok;
    if (live and info.properties != st.rows) buildRows(txn, st);
    if (!live and st.rows != 0) {
        st.selected = .null;
        buildRows(txn, st);
    }
    refreshProperties(txn, st, live, info);
    refreshTheme(txn, st, live, info);
    refreshFrames(txn, st, stats);
    var buf: [160]u8 = undefined;
    const summary = if (st.target == .null) "No window" else blk: {
        var size: siv.Size = .{ .width = 0, .height = 0 };
        _ = c.siv_window_get_size(st.target, &size);
        break :blk std.fmt.bufPrint(&buf, "Window {d} × {d} · {d} nodes · {d} layers", .{ size.width, size.height, stats.nodes, stats.layers }) catch "";
    };
    c.siv_set_text(txn, st.summary, summary.ptr, summary.len);
}

fn refreshProperties(txn: Txn, st: *Inspector, live: bool, info: siv.NodeInfo) void {
    var buf: [160]u8 = undefined;
    const title = if (live) describe(st.selected, &buf)[0] else "Nothing selected";
    c.siv_set_text(txn, st.title, title.ptr, title.len);
    st.rect = info.rect;
    st.content = info.content;
    c.siv_set_hidden(txn, st.box, !live);
    c.siv_invalidate(txn, st.box);
    const focus = c.siv_window_get_focus(w.windowOf(st.root));
    var value_buf: [4096]u8 = undefined;
    var old_buf: [4096]u8 = undefined;
    for (rowsOf(st), 0..) |row, i| {
        if (row.value == .null) continue;
        // What the user is typing stays until the field loses focus.
        if (row.editable and row.value == focus) continue;
        const v = propertyValue(st.selected, @intCast(i), &value_buf);
        if (std.mem.eql(u8, w.textOf(row.value, &old_buf), v)) continue;
        c.siv_set_text(txn, row.value, v.ptr, v.len);
    }
}

fn refreshTheme(txn: Txn, st: *Inspector, live: bool, info: siv.NodeInfo) void {
    var buf: [256]u8 = undefined;
    const line: []const u8 = if (!live) "" else blk: {
        // The nearest subtree theme around the node (D43).
        var cur = st.selected;
        var scope: Node = .null;
        while (cur != .null) : (cur = w.related(cur, .parent)) {
            var ci: siv.NodeInfo = undefined;
            if (c.siv_node_get_info(cur, &ci) == .ok and ci.flags.theme) {
                scope = cur;
                break;
            }
        }
        var fbs: std.Io.Writer = .fixed(&buf);
        fbs.print("Variant {s}. ", .{@tagName(info.variant)}) catch {};
        if (scope == .null) {
            fbs.writeAll("The window's theme: no subtree theme around this node.") catch {};
        } else {
            var dbuf: [160]u8 = undefined;
            fbs.print("Subtree theme from {s}", .{describe(scope, &dbuf)[0]}) catch {};
            var vbuf: [64]u8 = undefined;
            var nbuf: [32]u8 = undefined;
            for (0..propertyCount(scope)) |i| {
                if (!std.mem.eql(u8, propertyName(scope, @intCast(i), &nbuf), "scheme")) continue;
                fbs.print(": scheme {s}.", .{propertyValue(scope, @intCast(i), &vbuf)}) catch {};
            }
        }
        break :blk fbs.buffered();
    };
    c.siv_set_text(txn, st.scope, line.ptr, line.len);
    var cell = w.related(st.swatches, .first_child);
    for (tokens) |tok| {
        const sw = cell;
        const value = w.related(w.related(sw, .next), .next);
        cell = w.related(value, .next);
        var col: siv.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        var win_col = col;
        if (live) {
            _ = c.siv_node_get_color(st.selected, tok, &col);
            _ = c.siv_window_get_color(st.target, tok, &win_col);
        }
        c.siv_set_visual(txn, sw, &.{ .background = col, .border_width = 1, .border_token = .border, .radius = w.corners(4) });
        var hb: [64]u8 = undefined;
        const differs = !std.meta.eql(byte(col), byte(win_col));
        const b = byte(col);
        const s = if (live) std.fmt.bufPrint(&hb, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}{s}", .{ b[0], b[1], b[2], b[3], if (differs) "  (subtree)" else "" }) catch "" else "";
        c.siv_set_text(txn, value, s.ptr, s.len);
    }
}

fn byte(col: siv.Color) [4]u8 {
    const f = struct {
        fn f(v: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    }.f;
    return .{ f(col.r), f(col.g), f(col.b), f(col.a) };
}

fn refreshFrames(txn: Txn, st: *Inspector, s: siv.WindowStats) void {
    const latency_ms = if (s.present_ns > s.commit_ns and s.commit_ns != 0) @as(f64, @floatFromInt(s.present_ns - s.commit_ns)) / 1e6 else 0;
    const values = [counter_names.len]u64{ s.frames, s.layouts, s.shapes, s.text_layouts, s.layer_builds, s.tree_changes, s.commits, s.presented, 0, s.nodes, s.layers };
    var cell = w.related(st.counters, .first_child);
    for (values, 0..) |v, i| {
        const value = w.related(cell, .next);
        cell = w.related(value, .next);
        var buf: [64]u8 = undefined;
        const text = if (i == 8) std.fmt.bufPrint(&buf, "{d:.1} ms", .{latency_ms}) catch "" else std.fmt.bufPrint(&buf, "{d}", .{v}) catch "";
        c.siv_set_text(txn, value, text.ptr, text.len);
    }
    // Intervals between the frames presented most recently.
    var times: [chart_frames + 1]u64 = undefined;
    var k: u32 = 0;
    while (k < times.len and st.target != .null and c.siv_window_get_frame_time(st.target, k, &times[k]) == .ok) k += 1;
    st.interval_count = if (k > 1) k - 1 else 0;
    for (0..st.interval_count) |i| {
        // times[0] is the latest; the chart runs oldest first.
        const newer = times[st.interval_count - 1 - i];
        const older = times[st.interval_count - i];
        st.intervals[i] = if (newer > older) newer - older else 0;
    }
    c.siv_invalidate(txn, st.chart);
}

fn onEdit(ud: ?*anyopaque, field: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st = stateOf(w.dataHandle(ud)) orelse return .pass;
    if (st.target == .null or st.selected == .null) return .pass;
    for (rowsOf(st), 0..) |row, i| {
        if (row.value != field) continue;
        var name_buf: [64]u8 = undefined;
        var value_buf: [4096]u8 = undefined;
        const name = propertyName(st.selected, @intCast(i), &name_buf);
        const value = w.textOf(field, &value_buf);
        // Values that do not parse yet, as typed, change nothing.
        const txn = w.begin(st.target) orelse return .handled;
        c.siv_set_property(txn, st.selected, name.ptr, name.len, value.ptr, value.len);
        _ = w.commit(txn);
        return .handled;
    }
    return .pass;
}

// Drawing ---------------------------------------------------------------------

/// The box model: the border box with its size and place, the padding on
/// each side, and the content box inside.
fn drawBox(ud: ?*anyopaque, node: Node, d: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const st = stateOf(w.dataHandle(ud)) orelse return;
    const window = w.windowOf(node);
    const border = w.color(window, .border);
    const fg = w.color(window, .window_fg);
    const pad_fill: siv.Color = .{ .r = 0.13, .g = 0.77, .b = 0.37, .a = 0.25 };
    const content_fill: siv.Color = .{ .r = 0.23, .g = 0.51, .b = 0.96, .a = 0.3 };
    const bw = @min(width - 2, 420);
    const outer: siv.Rect = .{ .x = 1, .y = 1, .width = bw, .height = height - 2 };
    const inner: siv.Rect = .{ .x = outer.x + 70, .y = outer.y + 34, .width = outer.width - 140, .height = outer.height - 68 };
    c.siv_draw_rect(d, outer);
    c.siv_draw_fill(d, &.{ .color = pad_fill }, .{});
    c.siv_draw_rect(d, outer);
    c.siv_draw_stroke(d, &.{ .width = 1 }, &.{ .color = border });
    c.siv_draw_rect(d, inner);
    c.siv_draw_fill(d, &.{ .color = content_fill }, .{});
    c.siv_draw_rect(d, inner);
    c.siv_draw_stroke(d, &.{ .width = 1 }, &.{ .color = border });
    const r = st.rect;
    const cr = st.content;
    const style: siv.TextStyleDesc = .{ .color = fg, .size_role = .caption, .flags = .{ .no_wrap = true }, .@"align" = .center };
    var buf: [96]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "border box {f} × {f} at {f}, {f}", .{ num(r.width), num(r.height), num(r.x), num(r.y) }) catch "";
    c.siv_draw_text(d, outer.x + 6, outer.y + 6, 0, head.ptr, head.len, &.{ .color = fg, .size_role = .caption, .flags = .{ .no_wrap = true } });
    const sz = std.fmt.bufPrint(&buf, "{f} × {f}", .{ num(cr.width), num(cr.height) }) catch "";
    c.siv_draw_text(d, inner.x, inner.y + inner.height / 2 - 8, inner.width, sz.ptr, sz.len, &style);
    // The padding on each side, physical, as the boxes differ.
    const top = cr.y - r.y;
    const bottom = (r.y + r.height) - (cr.y + cr.height);
    const left = cr.x - r.x;
    const right = (r.x + r.width) - (cr.x + cr.width);
    const sides = [_]struct { f32, f32, f32, f32 }{
        .{ top, inner.x, outer.y + 12 + 6, inner.width },
        .{ bottom, inner.x, inner.y + inner.height + 8, inner.width },
        .{ left, outer.x, inner.y + inner.height / 2 - 8, 70 },
        .{ right, inner.x + inner.width, inner.y + inner.height / 2 - 8, 70 },
    };
    for (sides) |s| {
        const t = std.fmt.bufPrint(&buf, "{f}", .{num(s[0])}) catch "";
        c.siv_draw_text(d, s[1], s[2], s[3], t.ptr, t.len, &style);
    }
}

/// A length in logical pixels as the box model shows it: to a tenth,
/// without a trailing .0.
fn num(v: f32) Num {
    return .{ .v = @round(v * 10) / 10 };
}

const Num = struct {
    v: f32,
    pub fn format(n: Num, wr: *std.Io.Writer) std.Io.Writer.Error!void {
        if (n.v == @trunc(n.v)) return wr.print("{d}", .{n.v});
        return wr.print("{d:.1}", .{n.v});
    }
};

/// Bars of the intervals between presented frames, to 50 ms, with a line
/// at a 60 Hz refresh.
fn drawChart(ud: ?*anyopaque, node: Node, d: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const st = stateOf(w.dataHandle(ud)) orelse return;
    const window = w.windowOf(node);
    const top_ms: f32 = 50;
    c.siv_draw_rect(d, .{ .x = 0, .y = 0, .width = width, .height = height });
    c.siv_draw_fill(d, &.{ .color = w.color(window, .view_bg) }, .{});
    const bar_w = width / @as(f32, chart_frames);
    const accent = w.color(window, .accent);
    const warn = w.color(window, .destructive);
    for (st.intervals[0..st.interval_count], 0..) |ns, i| {
        const ms = @as(f32, @floatFromInt(ns)) / 1e6;
        const h = @min(ms / top_ms, 1) * (height - 2);
        const x = @as(f32, @floatFromInt(chart_frames - st.interval_count + i)) * bar_w;
        c.siv_draw_rect(d, .{ .x = x + 1, .y = height - h, .width = @max(bar_w - 2, 1), .height = h });
        c.siv_draw_fill(d, &.{ .color = if (ms > 17.5) warn else accent }, .{});
    }
    const y = height - (16.7 / top_ms) * (height - 2);
    c.siv_draw_move_to(d, 0, y);
    c.siv_draw_line_to(d, width, y);
    c.siv_draw_stroke(d, &.{ .width = 1, .dashes = &dashes, .dashes_count = 2 }, &.{ .color = w.color(window, .muted_fg) });
    c.siv_draw_rect(d, .{ .x = 0.5, .y = 0.5, .width = width - 1, .height = height - 1 });
    c.siv_draw_stroke(d, &.{ .width = 1 }, &.{ .color = w.color(window, .border) });
}

const dashes = [_]f32{ 4, 4 };
