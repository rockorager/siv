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
        // Tree items say where they are among their siblings: "2 of 4,
        // level 2".
        try testing.expectEqual(@as(u32, 2), tree.find(.tree_item, "Node 2001").?.position);
        try testing.expectEqual(@as(u32, 4), tree.find(.tree_item, "Node 2001").?.set_size);
        try testing.expectEqual(@as(u32, 1), tree.find(.tree_item, "Item 1000").?.position);
        try testing.expectEqual(@as(u32, 3), tree.find(.tree_item, "Item 1000").?.set_size);
        try testing.expectEqual(@as(u32, 2), tree.find(.tree_item, "Item 1001").?.position);
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

/// Rows of three heights: 24, 40, and 56 px in turn, or `fixed` when set.
const Heights = struct {
    fixed: f32 = 0,
    asked: u32 = 0,

    fn of(hs: *const Heights, i: u64) f32 {
        return if (hs.fixed != 0) hs.fixed else 24 + @as(f32, @floatFromInt(i % 3)) * 16;
    }

    fn top(hs: *const Heights, i: u64) f32 {
        var y: f32 = 0;
        for (0..i) |k| y += hs.of(k);
        return y;
    }
};

/// The application's model with a height callback.
const Sized = struct {
    m: Model = .{},
    hs: Heights = .{},

    fn height(ud: ?*anyopaque, item: u64, _: u32, _: u32) callconv(.c) f32 {
        const s: *Sized = @ptrCast(@alignCast(ud.?));
        s.hs.asked += 1;
        return s.hs.of(item);
    }
};

fn itemBounds(view: t.Node, name: []const u8) !?ui.semantics.Node {
    const uw, _ = try uiId(view);
    const tree = try uw.semanticsTree();
    return if (tree.find(.list_item, name)) |n| n.* else null;
}

test "list view: rows of their own heights, placed by arithmetic, scrolled on the compositor" {
    var h: Harness = .{};
    try h.start(240, 320, null, null);
    defer h.stop();
    var s: Sized = .{};
    const txn = try begin(h.window);
    const list = c.siv_list_view(txn, c.siv_window_root(h.window), &.{
        .label = "Notes",
        .label_len = 5,
        .count = 10_000,
        .selection = .single,
        .bind = Model.bind,
        .height = Sized.height,
        .user_data = &s,
    });
    _ = c.siv_on(txn, list, .select, Model.onSelect, null, &s.m);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    // Every height asked once, not again while frames go by.
    try testing.expectEqual(@as(u32, 10_000), s.hs.asked);
    // 320 px of rows averaging 40 px, plus overscan: about 16 rows.
    const rows = try rowCount(list);
    try testing.expect(rows >= 8 and rows <= 30);
    const b0 = (try itemBounds(list, "Item 0")).?.bounds;
    const b1 = (try itemBounds(list, "Item 1")).?.bounds;
    const b2 = (try itemBounds(list, "Item 2")).?.bounds;
    try testing.expectApproxEqAbs(@as(f32, 24), b1.y0 - b0.y0, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), b2.y0 - b1.y0, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 56), b2.y1 - b2.y0, 0.01);

    // Wheel scrolling 3200 px: the compositor scrolls, the rows at the
    // new offset are bound, by bisection of the tops.
    const id = (try h.win()).win.id;
    try h.inject(&.{.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 100, .y = 100 } }});
    for (0..20) |_| try h.inject(&.{.{ .scroll = .{ .window = id, .seat = 0, .dx = 0, .dy = 160, .v120_x = 0, .v120_y = 0 } }});
    try h.settle();
    var first: u64 = 0;
    while (s.hs.top(first + 1) <= 3200) first += 1;
    var items: [64]u64 = undefined;
    const n = try shownRows(list, &items);
    try testing.expect(n <= 40);
    var lo: u64 = std.math.maxInt(u64);
    for (items[0..n]) |it| lo = @min(lo, it);
    try testing.expectEqual(first - 8, lo);
    try testing.expectEqual(@as(u32, 10_000), s.hs.asked);

    // Scrolling to an item puts it in view at its arithmetic top.
    var t2 = try begin(h.window);
    try ok(c.siv_view_scroll_to(t2, list, 5000));
    try ok(c.siv_txn_commit(t2));
    try h.settle();
    const b5000 = (try itemBounds(list, "Item 5000")).?.bounds;
    try testing.expect(b5000.y0 >= -0.5 and b5000.y1 <= 320.5);
    try testing.expectApproxEqAbs(s.hs.of(5000), b5000.y1 - b5000.y0, 0.01);

    // Page Down moves by the view's height, not a row count.
    const uw, _ = try uiId(list);
    ui.input.setFocus(uw, (try itemBounds(list, "Item 5000")).?.node, true);
    try h.typeKey(ks.page_down, "", .{});
    try h.settle();
    var expect: u64 = 5000;
    while (s.hs.top(expect + 1) <= s.hs.top(5000) + 320) expect += 1;
    try testing.expectEqual(@as(u32, @intCast(expect)), s.m.index);

    // A refresh asks the heights again.
    s.hs.fixed = 50;
    t2 = try begin(h.window);
    try ok(c.siv_view_refresh(t2, list));
    try ok(c.siv_view_scroll_to(t2, list, 0));
    try ok(c.siv_txn_commit(t2));
    try h.settle();
    try testing.expectEqual(@as(u32, 20_000), s.hs.asked);
    const r0 = (try itemBounds(list, "Item 0")).?.bounds;
    const r1 = (try itemBounds(list, "Item 1")).?.bounds;
    try testing.expectApproxEqAbs(@as(f32, 50), r1.y0 - r0.y0, 0.01);
}

test "tree view: rows of their own heights follow expansion" {
    var h: Harness = .{};
    try h.start(240, 400, null, null);
    defer h.stop();
    var s: Sized = .{};
    const txn = try begin(h.window);
    const tree_view = c.siv_tree_view(txn, c.siv_window_root(h.window), &.{
        .label = "Outline",
        .label_len = 7,
        .bind = Model.bind,
        .children = Model.children,
        .child = Model.child,
        .height = Sized.height,
        .user_data = &s,
    });
    try ok(c.siv_view_set_expanded(txn, tree_view, 0, true));
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    // Items 1000, 2000..2003, 1001: heights by item id.
    const uw, _ = try uiId(tree_view);
    const tree = try uw.semanticsTree();
    const a = tree.find(.tree_item, "Item 1000").?.bounds;
    const b = tree.find(.tree_item, "Node 2000").?.bounds;
    const d = tree.find(.tree_item, "Item 1001").?.bounds;
    try testing.expectApproxEqAbs(s.hs.of(1000), b.y0 - a.y0, 0.01);
    var below: f32 = 0;
    for (2000..2004) |item| below += s.hs.of(item);
    try testing.expectApproxEqAbs(s.hs.of(1000) + below, d.y0 - a.y0, 0.01);
    try testing.expectApproxEqAbs(s.hs.of(1001), d.y1 - d.y0, 0.01);
}

const Sorter = struct {
    sorts: u32 = 0,
    column: u32 = 99,
    value: f64 = 0,
    /// Columns the application sorts by.
    accept: [3]bool = .{ true, false, true },
    widths: u32 = 0,
    width: f64 = 0,

    fn onSort(ud: ?*anyopaque, _: t.Node, ev: ?*const t.Event) callconv(.c) bool {
        const s: *Sorter = @ptrCast(@alignCast(ud.?));
        s.sorts += 1;
        s.column = ev.?.index;
        s.value = ev.?.value;
        return s.accept[ev.?.index];
    }

    fn onWidth(ud: ?*anyopaque, _: t.Node, ev: ?*const t.Event) callconv(.c) bool {
        const s: *Sorter = @ptrCast(@alignCast(ud.?));
        s.widths += 1;
        s.width = ev.?.value;
        return true;
    }
};

fn semOf(n: t.Node) !ui.Semantics {
    const uw, const id = try uiId(n);
    return uw.node(id).semantics;
}

test "table view: sortable and resizable columns by pointer, keyboard, and assistive technology" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(360, 200, null, null);
    defer h.stop();
    var m: Model = .{ .columns = 3 };
    var s: Sorter = .{};
    const txn = try begin(h.window);
    _ = c.siv_set_visual(txn, c.siv_window_root(h.window), &.{ .background_token = .window_bg });
    const table = c.siv_table_view(txn, c.siv_window_root(h.window), &.{ .label = "Files", .label_len = 5, .count = 100, .selection = .single, .bind = Model.bind, .user_data = &m, .item_height = 28 });
    const name = c.siv_table_column(txn, table, &.{ .title = "Name", .title_len = 4, .flags = .{ .sortable = true } });
    const size = c.siv_table_column(txn, table, &.{ .title = "Size", .title_len = 4, .width = .{ .unit = .px, .value = 90 }, .flags = .{ .sortable = true }, .min_width = 60 });
    const kind = c.siv_table_column(txn, table, &.{ .title = "Kind", .title_len = 4, .width = .{ .unit = .px, .value = 80 }, .flags = .{ .fixed = true } });
    _ = c.siv_on(txn, table, .sort, Sorter.onSort, null, &s);
    for ([_]t.Node{ name, size, kind }) |cell| _ = c.siv_on(txn, cell, .change, Sorter.onWidth, null, &s);
    try ok(c.siv_txn_commit(txn));
    try h.settle();

    // A click on a sortable header asks to sort, ascending first; the
    // application accepts, so the header shows it, and a second click
    // flips it.
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(name, &r));
    try h.click(r.x + 20, r.y + r.height / 2);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), s.sorts);
    try testing.expectEqual(@as(u32, 0), s.column);
    try testing.expectEqual(@as(f64, 1), s.value);
    try testing.expectEqual(ui.Sort.ascending, (try semOf(name)).sort);
    try h.expectGolden("table-sorted", 360, 200);
    try h.click(r.x + 20, r.y + r.height / 2);
    try h.settle();
    try testing.expectEqual(@as(f64, -1), s.value);
    try testing.expectEqual(ui.Sort.descending, (try semOf(name)).sort);
    // The column the application refuses shows nothing; the fixed one
    // does not sort at all.
    try ok(c.siv_node_get_rect(size, &r));
    try h.click(r.x + 20, r.y + r.height / 2);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), s.column);
    try testing.expectEqual(ui.Sort.none, (try semOf(size)).sort);
    try testing.expectEqual(ui.Sort.descending, (try semOf(name)).sort);
    try ok(c.siv_node_get_rect(kind, &r));
    const sorts = s.sorts;
    try h.click(r.x + 20, r.y + r.height / 2);
    try h.settle();
    try testing.expectEqual(sorts, s.sorts);

    // The keyboard: the header is one Tab stop, the cell last used
    // (Size); Up from the first row reaches it, Home goes to Name and
    // Right back to Size, Enter sorts it, Ctrl+Right widens it by 8 px
    // and reports the width, Down goes to the rows and Up back.
    const uw, _ = try uiId(name);
    var first_row: ?ui.NodeId = null;
    for ((try uw.semanticsTree()).nodes.items) |n| if (n.role == .row and n.row == 1) {
        first_row = n.node;
    };
    ui.input.setFocus(uw, first_row.?, true);
    try h.typeKey(ks.up, "", .{});
    try h.settle();
    try testing.expectEqual(ui.Role.column_header, (try focusedRole(&h)).?.role);
    try testing.expectEqualStrings("Size", (try uw.semanticsTree()).name((try focusedRole(&h)).?));
    try h.typeKey(ks.home, "", .{});
    try h.typeKey(ks.right, "", .{});
    try h.settle();
    try testing.expect((try semOf(size)).focusable and !(try semOf(name)).focusable);
    try h.typeKey(ks.@"return", "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 1), s.column);
    try h.typeKey(ks.right, "", .{ .ctrl = true });
    try h.settle();
    var width: f32 = 0;
    try ok(c.siv_view_get_column_width(table, 1, &width));
    try testing.expectEqual(@as(f32, 98), width);
    try testing.expectEqual(@as(f64, 98), s.width);
    // Narrowing stops at the column's least width.
    for (0..10) |_| try h.typeKey(ks.left, "", .{ .ctrl = true });
    try h.settle();
    try ok(c.siv_view_get_column_width(table, 1, &width));
    try testing.expectEqual(@as(f32, 60), width);
    try h.typeKey(ks.down, "", .{});
    try h.settle();
    try testing.expectEqual(ui.Role.row, (try focusedRole(&h)).?.role);
    try h.typeKey(ks.up, "", .{});
    try h.settle();
    try testing.expectEqual(ui.Role.column_header, (try focusedRole(&h)).?.role);

    // Dragging Name's handle 30 px toward the end widens it by 30 px.
    try ok(c.siv_view_get_column_width(table, 0, &width));
    const before = width;
    var handle: t.Node = .null;
    try ok(c.siv_node_get_related(name, .last_child, &handle));
    var hr: t.Rect = undefined;
    try ok(c.siv_node_get_rect(handle, &hr));
    const wid = (try h.win()).win.id;
    const hx = hr.x + hr.width / 2;
    const hy = hr.y + hr.height / 2;
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = hx, .y = hy } },
        .{ .pointer_button = .{ .window = wid, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 10 } },
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = hx + 30, .y = hy } },
    });
    try h.settle();
    try h.inject(&.{.{ .pointer_button = .{ .window = wid, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 11 } }});
    try h.settle();
    try ok(c.siv_view_get_column_width(table, 0, &width));
    try testing.expectApproxEqAbs(before + 30, width, 0.5);
    try testing.expectApproxEqAbs(@as(f64, width), s.width, 0.01);
    // Rows follow the header's tracks.
    try ok(c.siv_node_get_rect(size, &r));
    const uwin, const handle_id = try uiId(handle);
    // The handle is a separator whose value is the width; assistive
    // technology sets it, stepped to 8 px.
    const hsem = uwin.node(handle_id).semantics;
    try testing.expectEqual(ui.Role.separator, hsem.role.?);
    try testing.expectApproxEqAbs(@as(f64, width), hsem.value.?.now, 0.01);
    try testing.expect(ui.input.setValue(uwin, handle_id, 150));
    try h.settle();
    try ok(c.siv_view_get_column_width(table, 0, &width));
    try testing.expectEqual(@as(f32, 152), width);
    // The fixed column has no handle.
    var last: t.Node = .null;
    try ok(c.siv_node_get_related(kind, .last_child, &last));
    const last_role = (try semOf(last)).role;
    try testing.expect(last_role == null or last_role.? != .separator);

    // From the application, without reports.
    const reports = s.widths;
    var t2 = try begin(h.window);
    try ok(c.siv_view_set_column_width(t2, table, 2, 120));
    try ok(c.siv_view_set_sort(t2, table, 2, .ascending));
    try ok(c.siv_txn_commit(t2));
    try h.settle();
    try ok(c.siv_view_get_column_width(table, 2, &width));
    try testing.expectEqual(@as(f32, 120), width);
    try testing.expectEqual(ui.Sort.ascending, (try semOf(kind)).sort);
    try testing.expectEqual(ui.Sort.none, (try semOf(name)).sort);
    try testing.expectEqual(reports, s.widths);
    t2 = try begin(h.window);
    _ = c.siv_view_set_sort(t2, table, 7, .ascending);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(t2));
}
