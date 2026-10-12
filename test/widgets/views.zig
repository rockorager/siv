//! Virtualized list, tree, table, and grid views (D22) through the C ABI
//! on the headless backend: only rows in view are nodes, scrolling on
//! the compositor (D8) rebinds them, and selection, keyboard, RTL, and
//! semantics work across items that have no rows.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const ui = @import("ui");
const harness = @import("../abi/harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const A = abi.application;
const Harness = harness.Harness;
const ok = harness.ok;

const ks = struct {
    const space: u32 = 0x20;
    const @"return": u32 = 0xff0d;
    const home: u32 = 0xff50;
    const left: u32 = 0xff51;
    const up: u32 = 0xff52;
    const right: u32 = 0xff53;
    const down: u32 = 0xff54;
    const page_down: u32 = 0xff56;
    const end: u32 = 0xff57;
};

/// The application's side: items are numbers, rows show "Item N" (or a
/// tree's names), and the log records binds and events.
const Model = struct {
    binds: u32 = 0,
    recycled: u32 = 0,
    selects: u32 = 0,
    index: u32 = 0,
    selected: u32 = 0,
    activations: u32 = 0,
    destroyed: u32 = 0,
    columns: u32 = 0,

    fn bind(ud: ?*anyopaque, txn: t.Txn, row: t.Node, item: u64, _: u32, depth: u32, recycled: bool) callconv(.c) void {
        const m: *Model = @ptrCast(@alignCast(ud.?));
        m.binds += 1;
        if (recycled) m.recycled += 1;
        var buf: [32]u8 = undefined;
        const s = if (depth > 0)
            std.fmt.bufPrint(&buf, "Node {d}", .{item}) catch unreachable
        else
            std.fmt.bufPrint(&buf, "Item {d}", .{item}) catch unreachable;
        // A recycled row keeps its children: update the label in place.
        var label: t.Node = .null;
        _ = c.siv_node_get_related(row, .first_child, &label);
        if (label == .null) {
            const cells = @max(1, m.columns);
            for (0..cells) |k| {
                const n = c.siv_text(txn, row, s.ptr, s.len);
                _ = c.siv_set_text_style(txn, n, &.{ .color_token = .view_fg, .size_role = .body, .flags = .{ .no_wrap = true } });
                _ = k;
            }
        } else {
            var cur = label;
            while (cur != .null) {
                _ = c.siv_set_text(txn, cur, s.ptr, s.len);
                var next: t.Node = .null;
                _ = c.siv_node_get_related(cur, .next, &next);
                cur = next;
            }
        }
    }

    fn onSelect(ud: ?*anyopaque, _: t.Node, ev: ?*const t.Event) callconv(.c) bool {
        const m: *Model = @ptrCast(@alignCast(ud.?));
        m.selects += 1;
        m.index = ev.?.index;
        m.selected = ev.?.count;
        return true;
    }

    fn onActivate(ud: ?*anyopaque, _: t.Node, ev: ?*const t.Event) callconv(.c) bool {
        const m: *Model = @ptrCast(@alignCast(ud.?));
        m.activations += 1;
        m.index = ev.?.index;
        return true;
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const m: *Model = @ptrCast(@alignCast(ud.?));
        m.destroyed += 1;
    }

    // A tree: items 1000 + k at the top (k < 3); item 1000 has children
    // 2000 + k (k < 4); item 2001 has 3000 + k (k < 2).
    fn children(_: ?*anyopaque, parent: u64) callconv(.c) u32 {
        return switch (parent) {
            0 => 3,
            1000 => 4,
            2001 => 2,
            else => 0,
        };
    }

    fn child(_: ?*anyopaque, parent: u64, index: u32) callconv(.c) u64 {
        return switch (parent) {
            0 => 1000 + @as(u64, index),
            1000 => 2000 + @as(u64, index),
            else => 3000 + @as(u64, index),
        };
    }
};

fn begin(window: t.Window) !t.Txn {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(window, &txn));
    return txn;
}

fn uiId(n: t.Node) !struct { *ui.Window, ui.NodeId } {
    const w, const id = try abi.tree.lookup(n);
    return .{ w.uiWin(), id };
}

/// The row nodes a view has (shown ones), and the item each shows.
fn shownRows(view: t.Node, items: []u64) !usize {
    const uw, const vid = try uiId(view);
    var n: usize = 0;
    // view > [header, rule,] scroll > stack > rows.
    var scroll = uw.node(vid).first;
    while (uw.node(scroll).kind != .scroll) scroll = uw.node(scroll).next;
    const stack = uw.node(scroll).first;
    var it = uw.children(stack);
    while (it.next()) |row| {
        if (uw.node(row).visual.hidden) continue;
        const sem = uw.node(row).semantics;
        if (n < items.len) items[n] = if (sem.position != 0) sem.position - 1 else if (sem.row != 0) sem.row - 1 else 0;
        n += 1;
    }
    return n;
}

fn rowCount(view: t.Node) !usize {
    var buf: [1]u64 = undefined;
    return shownRows(view, &buf);
}

fn focusedRole(h: *Harness) !?ui.semantics.Node {
    const w = try h.win();
    const tree = try w.uiWin().semanticsTree();
    return if (tree.focused()) |f| f.* else null;
}

fn listOf(h: *Harness, m: *Model, count: u32, mode: t.SelectionMode) !t.Node {
    const txn = try begin(h.window);
    _ = c.siv_set_visual(txn, c.siv_window_root(h.window), &.{ .background_token = .window_bg });
    const list = c.siv_list_view(txn, c.siv_window_root(h.window), &.{
        .label = "Files",
        .label_len = 5,
        .count = count,
        .selection = mode,
        .bind = Model.bind,
        .destroy = Model.destroy,
        .user_data = m,
    });
    _ = c.siv_set_layout(txn, list, &.{ .padding = .{ .start = 0 } });
    _ = c.siv_on(txn, list, .select, Model.onSelect, null, m);
    _ = c.siv_on(txn, list, .activate, Model.onActivate, null, m);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    return list;
}

test "list view: 100000 items cost the rows in view; scrolling rebinds them" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(240, 320, null, null);
    defer h.stop();
    var m: Model = .{};
    const list = try listOf(&h, &m, 100_000, .single);
    // 320 px of 32 px rows, plus overscan below: about 18 rows, not 100000.
    const rows = try rowCount(list);
    try testing.expect(rows >= 10 and rows <= 30);
    try testing.expectEqual(@as(u32, @intCast(rows)), m.binds);
    try h.expectGolden("list", 240, 320);
    // The list announces where its rows are among all items.
    const uw, _ = try uiId(list);
    const tree = try uw.semanticsTree();
    const item0 = tree.find(.list_item, "Item 0").?;
    try testing.expectEqual(@as(u32, 1), item0.position);
    try testing.expectEqual(@as(u32, 100_000), item0.set_size);
    try testing.expect(tree.find(.list, "Files") != null);

    // Wheel scrolling over the list: the compositor scrolls it (D8), the
    // viewport event rebinds rows, and the count stays bounded.
    const id = (try h.win()).win.id;
    const binds = m.binds;
    try h.inject(&.{.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 100, .y = 100 } }});
    for (0..20) |_| try h.inject(&.{.{ .scroll = .{ .window = id, .seat = 0, .dx = 0, .dy = 160, .v120_x = 0, .v120_y = 0 } }});
    try h.settle();
    var items: [64]u64 = undefined;
    const n = try shownRows(list, &items);
    try testing.expect(n <= 40);
    var lo: u64 = std.math.maxInt(u64);
    for (items[0..n]) |it| lo = @min(lo, it);
    // 3200 px down is item 100; overscan keeps 8 rows above.
    try testing.expect(lo >= 90 and lo <= 100);
    try testing.expect(m.binds - binds <= 3 * n);
    try testing.expect(m.recycled > 0);
}

test "list view: keyboard cursor, single and multiple selection, activation" {
    var h: Harness = .{};
    try h.start(240, 320, null, null);
    defer h.stop();
    var m: Model = .{};
    const list = try listOf(&h, &m, 100_000, .multiple);
    const uw, _ = try uiId(list);
    const first = (try uw.semanticsTree()).find(.list_item, "Item 0").?.node;
    ui.input.setFocus(uw, first, true);
    try h.typeKey(ks.down, "", .{});
    try h.typeKey(ks.down, "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 2), m.index);
    try testing.expectEqual(@as(u32, 1), m.selected);
    try testing.expectEqualStrings("Item 2", (try uw.semanticsTree()).name((try focusedRole(&h)).?));
    // Shift extends from the anchor; Ctrl+Space toggles one more.
    try h.typeKey(ks.down, "", .{ .shift = true });
    try h.typeKey(ks.down, "", .{ .shift = true });
    try h.settle();
    try testing.expectEqual(@as(u32, 3), m.selected);
    try h.typeKey(ks.down, "", .{ .ctrl = true });
    try h.typeKey(ks.down, "", .{ .ctrl = true });
    try h.typeKey(ks.space, " ", .{ .ctrl = true });
    try h.settle();
    try testing.expectEqual(@as(u32, 4), m.selected);
    var sel = false;
    try ok(c.siv_view_is_selected(list, 6, &sel));
    try testing.expect(sel);
    try ok(c.siv_view_is_selected(list, 5, &sel));
    try testing.expect(!sel);
    // End reaches the last item: scrolled there, its row bound and focused.
    try h.typeKey(ks.end, "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 99_999), m.index);
    try testing.expectEqualStrings("Item 99999", (try uw.semanticsTree()).name((try focusedRole(&h)).?));
    try testing.expect(try rowCount(list) <= 40);
    var v: f64 = 0;
    try ok(c.siv_widget_get_value(list, &v));
    try testing.expectEqual(@as(f64, 99_999), v);
    // Ctrl+A selects every item, rows or not; Enter activates the cursor.
    try h.typeKey('a', "a", .{ .ctrl = true });
    try h.typeKey(ks.@"return", "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 100_000), m.selected);
    try testing.expectEqual(@as(u32, 1), m.activations);
    try testing.expectEqual(@as(u32, 99_999), m.index);
    // A click selects only that row.
    try h.typeKey(ks.home, "", .{});
    try h.settle();
    var r: t.Rect = undefined;
    _ = &r;
    try h.click(100, 3 * 32 + 16);
    try h.settle();
    try testing.expectEqual(@as(u32, 3), m.index);
    try testing.expectEqual(@as(u32, 1), m.selected);
    // A double click activates the item under it.
    const acts = m.activations;
    try h.click(100, 4 * 32 + 16);
    try h.click(100, 4 * 32 + 16);
    try h.settle();
    try testing.expectEqual(acts + 1, m.activations);
    try testing.expectEqual(@as(u32, 4), m.index);
    // Shrinking the count drops selection past the end.
    var txn = try begin(h.window);
    try ok(c.siv_view_set_selected(txn, list, 50, true));
    try ok(c.siv_view_set_count(txn, list, 10));
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_view_is_selected(list, 50, &sel));
    try testing.expect(try rowCount(list) == 10);
    // Removing the view releases the application's user data.
    txn = try begin(h.window);
    try ok(c.siv_remove(txn, list));
    try ok(c.siv_txn_commit(txn));
    try testing.expectEqual(@as(u32, 1), m.destroyed);
}

test "tree view: expanding and collapsing, keys mirrored in RTL" {
    for ([_]bool{ false, true }) |rtl| {
        var h: Harness = .{ .golden = "test/golden/widgets" };
        try h.startWith(.{ .width = 240, .height = 240, .flags = .{ .rtl = rtl } });
        defer h.stop();
        var m: Model = .{};
        const txn = try begin(h.window);
        _ = c.siv_set_visual(txn, c.siv_window_root(h.window), &.{ .background_token = .window_bg });
        const tree_view = c.siv_tree_view(txn, c.siv_window_root(h.window), &.{
            .label = "Outline",
            .label_len = 7,
            .selection = .single,
            .bind = Model.bind,
            .children = Model.children,
            .child = Model.child,
            .user_data = &m,
        });
        _ = c.siv_on(txn, tree_view, .select, Model.onSelect, null, &m);
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        try testing.expectEqual(@as(usize, 3), try rowCount(tree_view));
        const uw, _ = try uiId(tree_view);
        var tree = try uw.semanticsTree();
        const top = tree.find(.tree_item, "Item 1000").?;
        try testing.expectEqual(ui.Toggle.off, top.expanded);
        try testing.expectEqual(@as(u8, 1), top.level);
        ui.input.setFocus(uw, top.node, true);
        // Forward (right in LTR, left in RTL) expands, then enters.
        const forward: u32 = if (rtl) ks.left else ks.right;
        const back: u32 = if (rtl) ks.right else ks.left;
        try h.typeKey(forward, "", .{});
        try h.settle();
        try testing.expectEqual(@as(usize, 7), try rowCount(tree_view));
        tree = try uw.semanticsTree();
        try testing.expectEqual(ui.Toggle.on, tree.find(.tree_item, "Item 1000").?.expanded);
        try testing.expectEqual(@as(u8, 2), tree.find(.tree_item, "Node 2001").?.level);
        try h.typeKey(forward, "", .{});
        try h.typeKey(ks.down, "", .{});
        try h.typeKey(forward, "", .{});
        try h.settle();
        try testing.expectEqual(@as(usize, 9), try rowCount(tree_view));
        if (!rtl) try h.expectGolden("tree", 240, 240);
        var item: u64 = 0;
        try ok(c.siv_view_get_item(tree_view, 3, &item));
        try testing.expectEqual(@as(u64, 3000), item);
        // Back goes to the parent, then collapses it with its subtree.
        try h.typeKey(back, "", .{});
        try h.settle();
        try testing.expectEqual(@as(u32, 2), m.index);
        try h.typeKey(ks.up, "", .{});
        try h.typeKey(back, "", .{});
        try h.typeKey(back, "", .{});
        try h.settle();
        try testing.expectEqual(@as(usize, 3), try rowCount(tree_view));
        try testing.expectEqual(@as(u32, 0), m.index);
    }
}

test "table view: a header over rows of cells" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(320, 200, null, null);
    defer h.stop();
    var m: Model = .{ .columns = 2 };
    const txn = try begin(h.window);
    _ = c.siv_set_visual(txn, c.siv_window_root(h.window), &.{ .background_token = .window_bg });
    const table = c.siv_table_view(txn, c.siv_window_root(h.window), &.{ .label = "People", .label_len = 6, .count = 1000, .selection = .single, .bind = Model.bind, .user_data = &m, .item_height = 28 });
    _ = c.siv_table_column(txn, table, &.{ .title = "Name", .title_len = 4 });
    _ = c.siv_table_column(txn, table, &.{ .title = "Size", .title_len = 4, .width = .{ .unit = .px, .value = 90 } });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.expectGolden("table", 320, 200);
    const uw, _ = try uiId(table);
    const tree = try uw.semanticsTree();
    try testing.expect(tree.find(.table, "People") != null);
    try testing.expect(tree.find(.column_header, "Name") != null);
    var rows: u32 = 0;
    for (tree.nodes.items) |n| if (n.role == .row and n.row != 0) {
        rows += 1;
        if (n.row == 1) try testing.expect(tree.find(.cell, "") == null);
    };
    try testing.expect(rows > 3);
    try testing.expect(try rowCount(table) < 30);
}

test "grid view: cells in reading order, two-dimensional keys, mirrored in RTL" {
    for ([_]bool{ false, true }) |rtl| {
        var h: Harness = .{ .golden = "test/golden/widgets" };
        try h.startWith(.{ .width = 320, .height = 200, .flags = .{ .rtl = rtl } });
        defer h.stop();
        var m: Model = .{};
        const txn = try begin(h.window);
        _ = c.siv_set_visual(txn, c.siv_window_root(h.window), &.{ .background_token = .window_bg });
        const grid = c.siv_grid_view(txn, c.siv_window_root(h.window), &.{ .label = "Photos", .label_len = 6, .count = 10_000, .selection = .single, .bind = Model.bind, .user_data = &m, .item_width = 100, .item_height = 60 });
        _ = c.siv_on(txn, grid, .select, Model.onSelect, null, &m);
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        if (!rtl) try h.expectGolden("grid", 320, 200);
        // 318 px wide (inside the border) fits three 100 px cells a row.
        const uw, _ = try uiId(grid);
        const tree = try uw.semanticsTree();
        const second = tree.find(.list_item, "Item 1").?;
        const first = tree.find(.list_item, "Item 0").?;
        if (rtl) try testing.expect(second.bounds.x0 < first.bounds.x0) else try testing.expect(second.bounds.x0 > first.bounds.x0);
        ui.input.setFocus(uw, first.node, true);
        try h.typeKey(ks.down, "", .{});
        try h.settle();
        try testing.expectEqual(@as(u32, 3), m.index);
        try h.typeKey(if (rtl) ks.left else ks.right, "", .{});
        try h.settle();
        try testing.expectEqual(@as(u32, 4), m.index);
        try testing.expect(try rowCount(grid) < 60);
    }
}
