//! Menus, popovers, dialogs, tabs, split panes, and toasts (D22) through
//! the C ABI on the headless backend, whose popups follow xdg_popup's
//! placement and grab rules (D17).
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
    const tab: u32 = 0xff09;
    const @"return": u32 = 0xff0d;
    const escape: u32 = 0xff1b;
    const home: u32 = 0xff50;
    const left: u32 = 0xff51;
    const up: u32 = 0xff52;
    const right: u32 = 0xff53;
    const down: u32 = 0xff54;
    const end: u32 = 0xff57;
};

const Log = struct {
    selects: u32 = 0,
    index: u32 = 0,
    changes: u32 = 0,
    value: f64 = 0,
    closes: u32 = 0,
    keep: bool = false,
    node: t.Node = .null,

    fn onSelect(ud: ?*anyopaque, node: t.Node, ev: ?*const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.selects += 1;
        log.index = ev.?.index;
        log.node = node;
        return .handled;
    }

    fn onChange(ud: ?*anyopaque, node: t.Node, ev: ?*const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.changes += 1;
        log.value = ev.?.value;
        log.node = node;
        return .handled;
    }

    fn onClose(ud: ?*anyopaque, node: t.Node, _: ?*const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.closes += 1;
        log.node = node;
        return if (log.keep) .handled else .pass;
    }
};

fn center(n: t.Node) ![2]f64 {
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(n, &r));
    return .{ r.x + r.width / 2, r.y + r.height / 2 };
}

fn uiId(n: t.Node) !struct { *ui.Window, ui.NodeId } {
    const w, const id = try abi.tree.lookup(n);
    return .{ w.uiWin(), id };
}

fn sem(n: t.Node) !ui.semantics.Node {
    const uw, const id = try uiId(n);
    const tree = try uw.semanticsTree();
    for (tree.nodes.items) |s| if (s.node == id) return s;
    return error.NotInSemanticsTree;
}

fn begin(window: t.Window) !t.Txn {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(window, &txn));
    return txn;
}

/// The application's open popup, if any.
fn openPopup(h: *Harness) !?t.Window {
    const self = try h.internal();
    var found: ?t.Window = null;
    for (self.windows.items) |slot| if (slot) |w| {
        if (!w.dead and w.parent != null and w.win.shown) found = @fromBackingInt(w.handle);
    };
    return found;
}

fn focusedIn(window: t.Window) !ui.NodeId {
    const w = try A.App.window(@backingInt(window), A.window_tag);
    return w.uiWin().input.focus;
}

fn idOf(n: t.Node) !ui.NodeId {
    _, const id = try uiId(n);
    return id;
}

fn root(h: *Harness) t.Node {
    return c.siv_window_root(h.window);
}

fn background(txn: t.Txn, h: *Harness) void {
    _ = c.siv_set_visual(txn, root(h), &.{ .background_token = .window_bg });
}

const MenuFixture = struct {
    button: t.Node,
    items: [5]t.Node,
};

fn buildMenu(h: *Harness, log: *Log) !MenuFixture {
    const txn = try begin(h.window);
    background(txn, h);
    const col = c.siv_flex(txn, root(h), &.{ .axis = .column, .align_items = .start });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 16, .top = 16 } });
    var f: MenuFixture = undefined;
    f.button = c.siv_menu_button(txn, col, &.{ .label = "File", .label_len = 4 });
    const items = [_]t.MenuItemDesc{
        .{ .label = "New", .label_len = 3, .shortcut = "Ctrl+N", .shortcut_len = 6, .mnemonic = 'n' },
        .{ .label = "Open", .label_len = 4, .shortcut = "Ctrl+O", .shortcut_len = 6 },
        .{ .flags = .{ .separator = true } },
        .{ .label = "Autosave", .label_len = 8, .flags = .{ .checked = true } },
        .{ .label = "Print", .label_len = 5, .flags = .{ .disabled = true } },
    };
    for (&f.items, &items) |*n, *d| n.* = c.siv_menu_item(txn, f.button, d);
    _ = c.siv_on(txn, f.button, .select, Log.onSelect, null, log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    return f;
}

test "menus: a menu button opens its menu in a popup; keys and clicks choose" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(300, 260, null, null);
    defer h.stop();
    var log: Log = .{};
    const f = try buildMenu(&h, &log);
    const bc = try center(f.button);
    try h.click(bc[0], bc[1]);
    try h.settle();
    const popup = (try openPopup(&h)) orelse return error.NoPopup;
    try testing.expectEqual(ui.Toggle.on, (try sem(f.button)).expanded);
    var size: t.Size = undefined;
    try ok(c.siv_window_get_size(popup, &size));
    try h.expectGoldenOf(popup, "menu", @intFromFloat(size.width), @intFromFloat(size.height));
    // The first item has focus; Down skips nothing, Down again skips the
    // separator, End skips the disabled item.
    const pw = try A.App.window(@backingInt(popup), A.window_tag);
    const tree = try pw.uiWin().semanticsTree();
    try testing.expectEqualStrings("New", tree.name(tree.focused().?.*));
    try testing.expectEqual(ui.Role.menu_item, tree.focused().?.role);
    try testing.expect(tree.find(.menu_item, "Print").?.disabled);
    try testing.expectEqual(ui.Toggle.on, tree.find(.menu_item, "Autosave").?.checked);
    try h.typeKeyIn(popup, ks.down, "", .{});
    try h.typeKeyIn(popup, ks.down, "", .{});
    try h.settle();
    const t2 = try pw.uiWin().semanticsTree();
    try testing.expectEqualStrings("Autosave", t2.name(t2.focused().?.*));
    try h.typeKeyIn(popup, ks.end, "", .{});
    try h.settle();
    const t3 = try pw.uiWin().semanticsTree();
    try testing.expectEqualStrings("Autosave", t3.name(t3.focused().?.*));
    // Enter chooses: the popup goes, the item flips, the button reports
    // its index (separators count).
    try h.typeKeyIn(popup, ks.@"return", "", .{});
    try h.settle();
    try testing.expect((try openPopup(&h)) == null);
    try testing.expectEqual(@as(u32, 1), log.selects);
    try testing.expectEqual(@as(u32, 3), log.index);
    try testing.expectEqual(f.button, log.node);
    var v: f64 = 1;
    try ok(c.siv_widget_get_value(f.items[3], &v));
    try testing.expectEqual(@as(f64, 0), v);
    try testing.expectEqual(ui.Toggle.off, (try sem(f.button)).expanded);

    // A mnemonic chooses at once; Escape closes without choosing.
    try h.click(bc[0], bc[1]);
    try h.settle();
    try h.typeKeyIn((try openPopup(&h)).?, 'N', "N", .{ .shift = true });
    try h.settle();
    try testing.expectEqual(@as(u32, 2), log.selects);
    try testing.expectEqual(@as(u32, 0), log.index);
    try h.click(bc[0], bc[1]);
    try h.settle();
    try h.typeKeyIn((try openPopup(&h)).?, ks.escape, "", .{});
    try h.settle();
    try testing.expect((try openPopup(&h)) == null);
    try testing.expectEqual(@as(u32, 2), log.selects);

    // A click on an item chooses it; a click outside dismisses the menu.
    try h.click(bc[0], bc[1]);
    try h.settle();
    const p2 = (try openPopup(&h)).?;
    const open_row = blk: {
        const w2 = try A.App.window(@backingInt(p2), A.window_tag);
        const tr = try w2.uiWin().semanticsTree();
        const n = tr.find(.menu_item, "Open").?;
        break :blk n.bounds;
    };
    try h.clickIn(p2, (open_row.x0 + open_row.x1) / 2, (open_row.y0 + open_row.y1) / 2);
    try h.settle();
    try testing.expectEqual(@as(u32, 3), log.selects);
    try testing.expectEqual(@as(u32, 1), log.index);
    try h.click(bc[0], bc[1]);
    try h.settle();
    try testing.expect((try openPopup(&h)) != null);
    try h.click(250, 230);
    try h.settle();
    try testing.expect((try openPopup(&h)) == null);
    try testing.expectEqual(ui.Toggle.off, (try sem(f.button)).expanded);
    try testing.expectEqual(@as(u32, 3), log.selects);
}

test "menus: a context menu opens against any node; disabled items cannot be chosen" {
    var h: Harness = .{};
    try h.start(300, 260, null, null);
    defer h.stop();
    var log: Log = .{};
    var txn = try begin(h.window);
    const target = c.siv_box(txn, root(&h));
    _ = c.siv_set_layout(txn, target, &.{ .width = .{ .unit = .px, .value = 100 }, .height = .{ .unit = .px, .value = 40 } });
    const menu = c.siv_menu(txn, root(&h), &.{ .label = "Edit", .label_len = 4 });
    _ = c.siv_menu_item(txn, menu, &.{ .label = "Cut", .label_len = 3, .flags = .{ .disabled = true } });
    const copy = c.siv_menu_item(txn, menu, &.{ .label = "Copy", .label_len = 4 });
    _ = c.siv_on(txn, menu, .select, Log.onSelect, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.click(20, 20);
    try h.settle();
    try ok(c.siv_menu_open(menu, target));
    try h.settle();
    const popup = (try openPopup(&h)).?;
    const pw = try A.App.window(@backingInt(popup), A.window_tag);
    // Focus starts on the first enabled item.
    const tree = try pw.uiWin().semanticsTree();
    try testing.expectEqualStrings("Copy", tree.name(tree.focused().?.*));
    try testing.expectEqualStrings("Edit", tree.name(tree.find(.menu, "Edit").?.*));
    // The popup hangs from the target's bottom edge.
    var pos: t.Rect = undefined;
    try ok(c.siv_node_get_rect(target, &pos));
    try testing.expectEqual(@as(i32, 40), pw.win.state.popup.?.y);
    try h.typeKeyIn(popup, ks.up, "", .{});
    try h.typeKeyIn(popup, ks.@"return", "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.index);
    // Relabelled and removed items follow the model.
    txn = try begin(h.window);
    try ok(c.siv_widget_set_label(txn, copy, "Duplicate", 9));
    try ok(c.siv_txn_commit(txn));
    try h.click(20, 20);
    try h.settle();
    try ok(c.siv_menu_open(menu, target));
    try h.settle();
    const p2 = (try openPopup(&h)).?;
    const w2 = try A.App.window(@backingInt(p2), A.window_tag);
    try testing.expect((try w2.uiWin().semanticsTree()).find(.menu_item, "Duplicate") != null);
}

test "menus: a context menu opens at the click's point, in LTR and RTL" {
    for ([_]bool{ false, true }) |rtl| {
        var h: Harness = .{};
        try h.startWith(.{ .width = 300, .height = 260, .flags = .{ .rtl = rtl } });
        defer h.stop();
        const txn = try begin(h.window);
        const col = c.siv_flex(txn, root(&h), &.{ .axis = .column });
        _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .top = 30 } });
        const target = c.siv_box(txn, col);
        _ = c.siv_set_layout(txn, target, &.{ .height = .{ .unit = .px, .value = 150 } });
        const menu = c.siv_menu(txn, root(&h), &.{ .label = "Edit", .label_len = 4 });
        _ = c.siv_menu_item(txn, menu, &.{ .label = "Copy", .label_len = 4 });
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        // A right click at (px, 50) in the window, (px, 20) in the
        // target, with room for the menu on its start side.
        const px: f32 = if (rtl) 250 else 70;
        try h.click(px, 50);
        try h.settle();
        try ok(c.siv_menu_open_at(menu, target, px, 20));
        try h.settle();
        const popup = (try openPopup(&h)).?;
        const at = (try A.App.window(@backingInt(popup), A.window_tag)).win.state.popup.?;
        // Below the point at its start side: right of it in LTR, left of
        // it (ending there) in RTL.
        try testing.expect(at.y >= 50 and at.y <= 52);
        const size = (try A.App.window(@backingInt(popup), A.window_tag)).uiWin().width;
        const x0: f32 = @floatFromInt(at.x);
        if (rtl) {
            try testing.expect(x0 + size >= px and x0 + size <= px + 2);
        } else {
            try testing.expect(x0 >= px - 1 and x0 <= px + 1);
        }
        try testing.expectEqual(t.Result.error_invalid_argument, c.siv_menu_open_at(menu, .null, 0, 0));
    }
}

test "popovers: content the application builds, closed by Escape unless kept" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(300, 260, null, null);
    defer h.stop();
    var log: Log = .{};
    var txn = try begin(h.window);
    background(txn, &h);
    const anchor = c.siv_push_button(txn, root(&h), &.{ .label = "Info", .label_len = 4 });
    _ = c.siv_set_layout(txn, anchor, &.{ .align_x = .start, .align_y = .start });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    const ac = try center(anchor);
    try h.click(ac[0], ac[1]);
    try h.settle();
    var popup: t.Window = .null;
    var content: t.Node = .null;
    try ok(c.siv_popover_create(anchor, &.{ .label = "Details", .label_len = 7 }, &popup, &content));
    txn = try begin(popup);
    const text = c.siv_text(txn, content, "Saved 2 minutes ago", 19);
    _ = c.siv_set_text_style(txn, text, &.{ .color_token = .card_fg, .size_role = .body });
    _ = c.siv_check_box(txn, content, &.{ .label = "Notify me", .label_len = 9 });
    _ = c.siv_on(txn, content, .close, Log.onClose, null, &log);
    try ok(c.siv_txn_commit(txn));
    try ok(c.siv_popup_show(popup));
    try testing.expectEqual(t.Result.error_busy, c.siv_popup_show(popup));
    try h.settle();
    var size: t.Size = undefined;
    try ok(c.siv_window_get_size(popup, &size));
    try h.expectGoldenOf(popup, "popover", @intFromFloat(size.width), @intFromFloat(size.height));
    const pw = try A.App.window(@backingInt(popup), A.window_tag);
    try testing.expect((try pw.uiWin().semanticsTree()).find(.dialog, "Details") != null);
    // Kept by the application, then let go.
    log.keep = true;
    try h.typeKeyIn(popup, ks.escape, "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.closes);
    try testing.expect((try openPopup(&h)) != null);
    log.keep = false;
    try h.typeKeyIn(popup, ks.escape, "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 2), log.closes);
    try testing.expect((try openPopup(&h)) == null);
}

test "dialogs: modal over the window, focused, closed by Escape or the scrim" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(400, 300, null, null);
    defer h.stop();
    var log: Log = .{};
    var txn = try begin(h.window);
    background(txn, &h);
    const behind = c.siv_push_button(txn, root(&h), &.{ .label = "Behind", .label_len = 6 });
    _ = c.siv_set_layout(txn, behind, &.{ .align_x = .start, .align_y = .start });
    try ok(c.siv_txn_commit(txn));
    // The opener has focus when the dialog appears.
    try ok(c.siv_node_focus(behind));
    txn = try begin(h.window);
    const dialog = c.siv_dialog(txn, root(&h), &.{ .title = "Discard changes?", .title_len = 16, .text = "Your edits will be lost.", .text_len = 24 });
    var actions: t.Node = .null;
    try ok(c.siv_widget_get_part(dialog, .actions, 0, &actions));
    const cancel = c.siv_push_button(txn, actions, &.{ .label = "Cancel", .label_len = 6 });
    const discard = c.siv_push_button(txn, actions, &.{ .label = "Discard", .label_len = 7, .style = .destructive });
    _ = c.siv_on(txn, dialog, .close, Log.onClose, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.expectGolden("dialog", 400, 300);
    const s = try sem(dialog);
    try testing.expectEqual(ui.Role.dialog, s.role);
    try testing.expect(s.modal and s.focused);
    try testing.expectEqualStrings("Discard changes?", (try (try uiId(dialog))[0].semanticsTree()).name(s));
    // Tab cycles inside the dialog only.
    for ([_]t.Node{ cancel, discard, dialog, cancel }) |want| {
        try h.typeKey(ks.tab, "", .{});
        try h.settle();
        try testing.expectEqual(try idOf(want), try focusedIn(h.window));
    }
    // The button behind can neither be clicked (the press lands on the
    // scrim) nor focused.
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_node_focus(behind));
    log.keep = true;
    const bc = try center(behind);
    try h.click(bc[0], bc[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.closes);
    // Kept: Escape asks again; let go: the dialog is removed.
    try h.typeKey(ks.escape, "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 2), log.closes);
    log.keep = false;
    try h.typeKey(ks.escape, "", .{});
    try h.settle();
    var gone: t.Rect = undefined;
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_node_get_rect(dialog, &gone));
    // Focus is back on the opener.
    try testing.expectEqual(try idOf(behind), try focusedIn(h.window));
}

test "tabs: one panel at a time, arrows move the selection, mirrored in RTL" {
    for ([_]bool{ false, true }) |rtl| {
        var h: Harness = .{ .golden = "test/golden/widgets" };
        try h.startWith(.{ .width = 320, .height = 200, .flags = .{ .rtl = rtl } });
        defer h.stop();
        var log: Log = .{};
        const txn = try begin(h.window);
        background(txn, &h);
        const tabs = c.siv_tabs(txn, root(&h), &.{ .label = "Settings", .label_len = 8 });
        _ = c.siv_set_layout(txn, tabs, &.{ .padding = .{ .start = 12, .end = 12, .top = 12, .bottom = 12 } });
        var panels: [3]t.Node = undefined;
        for (&panels, [_][]const u8{ "General", "Privacy", "About" }) |*p, label| {
            p.* = c.siv_tab(txn, tabs, label.ptr, label.len);
            const text = c.siv_text(txn, p.*, label.ptr, label.len);
            _ = c.siv_set_text_style(txn, text, &.{ .color_token = .window_fg, .size_role = .body });
        }
        _ = c.siv_on(txn, tabs, .change, Log.onChange, null, &log);
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        if (!rtl) try h.expectGolden("tabs", 320, 200);
        var tab0: t.Node = .null;
        try ok(c.siv_widget_get_part(tabs, .tab, 0, &tab0));
        try testing.expectEqual(ui.Role.tab, (try sem(tab0)).role);
        try testing.expectEqual(ui.Toggle.on, (try sem(tab0)).selected);
        try testing.expectEqual(ui.Role.tab_panel, (try sem(panels[0])).role);
        // Hidden panels are not in the semantics tree.
        try testing.expectError(error.NotInSemanticsTree, sem(panels[1]));
        try ok(c.siv_node_focus(tab0));
        try h.typeKey(ks.right, "", .{});
        try h.settle();
        const want: u32 = if (rtl) 2 else 1;
        try testing.expectEqual(@as(f64, @floatFromInt(want)), log.value);
        var tab: t.Node = .null;
        try ok(c.siv_widget_get_part(tabs, .tab, want, &tab));
        try testing.expectEqual(try idOf(tab), try focusedIn(h.window));
        try testing.expectEqual(ui.Role.tab_panel, (try sem(panels[want])).role);
        try testing.expectError(error.NotInSemanticsTree, sem(panels[0]));
        try h.typeKey(ks.home, "", .{});
        try h.settle();
        var v: f64 = -1;
        try ok(c.siv_widget_get_value(tabs, &v));
        try testing.expectEqual(@as(f64, 0), v);
        // A click on the last tab.
        var last: t.Node = .null;
        try ok(c.siv_widget_get_part(tabs, .tab, 2, &last));
        const lc = try center(last);
        try h.click(lc[0], lc[1]);
        try h.settle();
        try testing.expectEqual(@as(f64, 2), log.value);
    }
}

test "split panes: the divider follows drags and keys within the panes' limits" {
    for ([_]bool{ false, true }) |rtl| {
        var h: Harness = .{};
        try h.startWith(.{ .width = 400, .height = 200, .flags = .{ .rtl = rtl } });
        defer h.stop();
        var log: Log = .{};
        const txn = try begin(h.window);
        const split = c.siv_split_pane(txn, root(&h), &.{ .position = 150, .min_start = 100, .min_end = 100, .label = "Sidebar", .label_len = 7 });
        _ = c.siv_on(txn, split, .change, Log.onChange, null, &log);
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        var start: t.Node = .null;
        try ok(c.siv_widget_get_part(split, .start, 0, &start));
        var r: t.Rect = undefined;
        try ok(c.siv_node_get_rect(start, &r));
        try testing.expectEqual(@as(f32, 150), r.width);
        try testing.expectEqual(@as(f32, if (rtl) 250 else 0), r.x);
        var divider: t.Node = .null;
        try ok(c.siv_node_get_related(start, .next, &divider));
        try ok(c.siv_node_focus(divider));
        try h.settle();
        const d = try sem(divider);
        try testing.expectEqual(ui.Role.separator, d.role);
        try testing.expectEqual(ui.Range{ .min = 100, .max = 294, .now = 150, .step = 10 }, d.value.?);
        try h.typeKey(ks.right, "", .{});
        try h.settle();
        try testing.expectEqual(@as(f64, if (rtl) 140 else 160), log.value);
        try testing.expectEqual(@as(u32, 1), log.changes);
        try h.typeKey(ks.end, "", .{});
        try h.settle();
        try testing.expectEqual(@as(u32, 2), log.changes);
        try testing.expectEqual(@as(f64, 294), log.value);
        // Drag the divider 50 px toward the start edge.
        const dc = try center(divider);
        const toward: f64 = if (rtl) 50 else -50;
        const id = (try h.win()).win.id;
        try h.inject(&.{
            .{ .pointer_motion = .{ .window = id, .seat = 0, .x = dc[0], .y = dc[1] } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 1 } },
            .{ .pointer_motion = .{ .window = id, .seat = 0, .x = dc[0] + toward, .y = dc[1] } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 2 } },
        });
        try h.settle();
        try testing.expectEqual(@as(f64, 244), log.value);
        try ok(c.siv_node_get_rect(start, &r));
        try testing.expectEqual(@as(f32, 244), r.width);
        // Assistive technology sets the size, clamped.
        const uw, const did = try uiId(divider);
        try testing.expect(ui.input.setValue(uw, did, 20));
        try h.settle();
        try testing.expectEqual(@as(f64, 100), log.value);
    }
}

test "toasts: announced, closed after their timeout, removed unless kept" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(320, 160, null, null);
    defer h.stop();
    // Kept when it first closes, so that its 30 ms timeout, which a
    // loaded machine may well see pass before the capture, cannot take it
    // out of the golden image.
    var log: Log = .{ .keep = true };
    var txn = try begin(h.window);
    background(txn, &h);
    const toast = c.siv_toast(txn, root(&h), &.{ .text = "Message sent", .text_len = 12, .timeout_ms = 30 });
    _ = c.siv_on(txn, toast, .close, Log.onClose, null, &log);
    const sticky = c.siv_toast(txn, root(&h), &.{ .text = "Offline", .text_len = 7, .flags = .{ .persistent = true, .assertive = true } });
    _ = c.siv_set_layout(txn, sticky, &.{ .align_y = .start });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.expectGolden("toasts", 320, 160);
    const s = try sem(toast);
    try testing.expectEqual(ui.Role.status, s.role);
    try testing.expectEqual(ui.Live.polite, s.live);
    try testing.expectEqual(ui.Live.assertive, (try sem(sticky)).live);
    try testing.expectEqual(ui.Role.alert, (try sem(sticky)).role);
    // Kept once: it stays.
    const deadline = @import("loop").Loop.now() + 2 * std.time.ns_per_s;
    while (log.closes == 0 and @import("loop").Loop.now() < deadline) try ok(c.siv_app_dispatch(h.app, 10));
    try testing.expectEqual(@as(u32, 1), log.closes);
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(toast, &r));
    // Closed again, not kept: it fades and is removed.
    log.keep = false;
    var handled = false;
    try ok(c.siv_emit(toast, &.{ .type = .close }, &handled));
    while (c.siv_node_get_rect(toast, &r) == .ok and @import("loop").Loop.now() < deadline) try ok(c.siv_app_dispatch(h.app, 10));
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_node_get_rect(toast, &r));
    try ok(c.siv_node_get_rect(sticky, &r));
    // Removing a toast early leaves its timer nothing to do.
    txn = try begin(h.window);
    const quick = c.siv_toast(txn, root(&h), &.{ .text = "Bye", .text_len = 3, .timeout_ms = 10 });
    try ok(c.siv_txn_commit(txn));
    txn = try begin(h.window);
    try ok(c.siv_remove(txn, quick));
    try ok(c.siv_txn_commit(txn));
    const until = @import("loop").Loop.now() + 50 * std.time.ns_per_ms;
    while (@import("loop").Loop.now() < until) try ok(c.siv_app_dispatch(h.app, 10));
}

/// The application's open popups, innermost last.
fn openPopups(h: *Harness, out: []t.Window) !usize {
    const self = try h.internal();
    var n: usize = 0;
    for (self.windows.items) |slot| if (slot) |w| {
        if (w.dead or w.parent == null or !w.win.shown) continue;
        out[n] = @fromBackingInt(w.handle);
        n += 1;
    };
    return n;
}

fn focusedName(window: t.Window) ![]const u8 {
    const w = try A.App.window(@backingInt(window), A.window_tag);
    const tree = try w.uiWin().semanticsTree();
    return tree.name((tree.focused() orelse return "").*);
}

test "menus: keys the compositor sends the toplevel during a grab go to the topmost grabbing popup" {
    var h: Harness = .{};
    try h.start(300, 200, null, null);
    defer h.stop();
    var log: Log = .{};
    const txn = try begin(h.window);
    const col = c.siv_flex(txn, root(&h), &.{ .axis = .column, .align_items = .start });
    const button = c.siv_menu_button(txn, col, &.{ .label = "File", .label_len = 4 });
    _ = c.siv_menu_item(txn, button, &.{ .label = "New", .label_len = 3 });
    _ = c.siv_menu_item(txn, button, &.{ .label = "Open", .label_len = 4 });
    _ = c.siv_on(txn, button, .select, Log.onSelect, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    const bc = try center(button);
    try h.click(bc[0], bc[1]);
    try h.settle();
    const popup = (try openPopup(&h)).?;
    // As sway does: the keyboard focus stays on the toplevel.
    try h.typeKey(ks.down, "", .{});
    try h.settle();
    try testing.expectEqualStrings("Open", try focusedName(popup));
    try h.typeKey(ks.@"return", "", .{});
    try h.settle();
    try testing.expect((try openPopup(&h)) == null);
    try testing.expectEqual(@as(u32, 1), log.selects);
    try testing.expectEqual(@as(u32, 1), log.index);
}

test "menus: submenus open beside their item, by keys, clicks, and hover, mirrored in RTL" {
    for ([_]bool{ false, true }) |rtl| {
        var h: Harness = .{};
        try h.startWith(.{ .width = 400, .height = 300, .flags = .{ .rtl = rtl } });
        defer h.stop();
        var log: Log = .{};
        var sub_log: Log = .{};
        const txn = try begin(h.window);
        // At the start edge, so the submenu has room on the end side.
        const col = c.siv_flex(txn, root(&h), &.{ .axis = .column, .align_items = .start });
        const button = c.siv_menu_button(txn, col, &.{ .label = "File", .label_len = 4 });
        const recent = c.siv_menu(txn, col, &.{ .label = "Recent", .label_len = 6 });
        _ = c.siv_menu_item(txn, recent, &.{ .label = "a.txt", .label_len = 5 });
        _ = c.siv_menu_item(txn, recent, &.{ .label = "b.txt", .label_len = 5 });
        _ = c.siv_menu_item(txn, button, &.{ .label = "New", .label_len = 3 });
        _ = c.siv_menu_item(txn, button, &.{ .label = "Recent", .label_len = 6, .submenu = recent });
        _ = c.siv_menu_item(txn, button, &.{ .label = "Quit", .label_len = 4 });
        _ = c.siv_on(txn, button, .select, Log.onSelect, null, &log);
        _ = c.siv_on(txn, recent, .select, Log.onSelect, null, &sub_log);
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        const forward: u32 = if (rtl) ks.left else ks.right;
        const back: u32 = if (rtl) ks.right else ks.left;
        const bc = try center(button);

        var ps: [8]t.Window = undefined;
        try h.click(bc[0], bc[1]);
        try h.settle();
        try testing.expectEqual(@as(usize, 1), try openPopups(&h, &ps));
        const top = ps[0];
        try h.typeKeyIn(top, ks.down, "", .{});
        try h.typeKeyIn(top, forward, "", .{});
        try h.settle();
        try testing.expectEqual(@as(usize, 2), try openPopups(&h, &ps));
        const sub = ps[1];
        try testing.expectEqualStrings("a.txt", try focusedName(sub));
        // The item shows it is expanded; the submenu hangs beside it, on
        // the end side.
        const tw = try A.App.window(@backingInt(top), A.window_tag);
        const sw = try A.App.window(@backingInt(sub), A.window_tag);
        const ttree = try tw.uiWin().semanticsTree();
        try testing.expectEqual(ui.Toggle.on, ttree.find(.menu_item, "Recent").?.expanded);
        const at = sw.win.state.popup.?;
        if (rtl) try testing.expect(at.x < 0) else try testing.expect(at.x >= @as(i32, @intFromFloat(tw.uiWin().width)) - 8);
        // Back closes the submenu, focus returning to its item.
        try h.typeKeyIn(sub, back, "", .{});
        try h.settle();
        try testing.expectEqual(@as(usize, 1), try openPopups(&h, &ps));
        try testing.expectEqualStrings("Recent", try focusedName(top));
        try testing.expectEqual(ui.Toggle.off, (try tw.uiWin().semanticsTree()).find(.menu_item, "Recent").?.expanded);
        // Enter opens it again; choosing reports on the submenu and closes
        // the whole chain.
        try h.typeKeyIn(top, ks.@"return", "", .{});
        try h.settle();
        try testing.expectEqual(@as(usize, 2), try openPopups(&h, &ps));
        try h.typeKeyIn(ps[1], ks.down, "", .{});
        try h.typeKeyIn(ps[1], ks.@"return", "", .{});
        try h.settle();
        try testing.expectEqual(@as(usize, 0), try openPopups(&h, &ps));
        try testing.expectEqual(@as(u32, 1), sub_log.selects);
        try testing.expectEqual(@as(u32, 1), sub_log.index);
        try testing.expectEqual(@as(u32, 0), log.selects);
        try testing.expectEqual(ui.Toggle.off, (try sem(button)).expanded);

        // Hover opens a submenu without moving focus there, and hovering a
        // sibling closes it.
        try h.click(bc[0], bc[1]);
        try h.settle();
        _ = try openPopups(&h, &ps);
        const top2 = ps[0];
        const t2 = try A.App.window(@backingInt(top2), A.window_tag);
        const tree2 = try t2.uiWin().semanticsTree();
        const rr = tree2.find(.menu_item, "Recent").?.bounds;
        const nr = tree2.find(.menu_item, "New").?.bounds;
        try h.inject(&.{.{ .pointer_motion = .{ .window = t2.win.id, .seat = 0, .x = (rr.x0 + rr.x1) / 2, .y = (rr.y0 + rr.y1) / 2 } }});
        try h.settle();
        try testing.expectEqual(@as(usize, 2), try openPopups(&h, &ps));
        try testing.expectEqualStrings("Recent", try focusedName(top2));
        try h.inject(&.{.{ .pointer_motion = .{ .window = t2.win.id, .seat = 0, .x = (nr.x0 + nr.x1) / 2, .y = (nr.y0 + nr.y1) / 2 } }});
        try h.settle();
        try testing.expectEqual(@as(usize, 1), try openPopups(&h, &ps));
        // Escape closes the top menu.
        try h.typeKeyIn(top2, ks.escape, "", .{});
        try h.settle();
        try testing.expectEqual(@as(usize, 0), try openPopups(&h, &ps));
    }
}
