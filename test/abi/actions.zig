//! Actions and accelerators (D34) through the C ABI on the headless
//! backend: which keys reach accelerators past a focused editor and the
//! window's handlers, scopes and shadowing, widgets and menu items that
//! follow their action and run it, what assistive technology hears, and
//! listing a window's actions.

const std = @import("std");
const abi = @import("abi");
const ui = @import("ui");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const A = abi.application;
const Harness = harness.Harness;
const ok = harness.ok;

const ks = struct {
    const @"return": u32 = 0xff0d;
    const left: u32 = 0xff51;
    const down: u32 = 0xff54;
};

/// One action's invocations.
const Ran = struct {
    count: u32 = 0,
    value: f64 = -1,
    window: t.Window = .null,

    fn on(ud: ?*anyopaque, ev: *const t.ActionEvent) callconv(.c) void {
        const r: *Ran = @ptrCast(@alignCast(ud.?));
        r.count += 1;
        r.value = ev.value;
        r.window = ev.window;
    }
};

fn begin(window: t.Window) !t.Txn {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(window, &txn));
    return txn;
}

fn create(h: *Harness, desc: t.ActionDesc, ran: *Ran) !t.Action {
    var a: t.Action = .null;
    try ok(c.siv_action_create(h.app, &desc, Ran.on, null, ran, &a));
    return a;
}

fn accel(key: u32, mods: t.Modifiers, target: f64) t.Accel {
    return .{ .key = @enumFromInt(@as(i32, @bitCast(key))), .modifiers = mods, .target = target };
}

fn value(n: t.Node) !f64 {
    var v: f64 = -1;
    try ok(c.siv_widget_get_value(n, &v));
    return v;
}

fn sem(n: t.Node) !ui.semantics.Node {
    const w, const id = try abi.tree.lookup(n);
    const tree = try w.uiWin().semanticsTree();
    for (tree.nodes.items) |s| if (s.node == id) return s;
    return error.NotInSemanticsTree;
}

fn center(n: t.Node) ![2]f64 {
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(n, &r));
    return .{ r.x + r.width / 2, r.y + r.height / 2 };
}

const Pressed = struct {
    var count: u32 = 0;
    fn on(_: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        count += 1;
        return .pass;
    }
};

const Prevent = struct {
    fn on(_: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        if (ev.keysym == .f5) return .prevent;
        if (ev.keysym == .f6) return .stop;
        return .pass;
    }
};

test "accelerators get the keys the focused node and the window's handlers leave" {
    var h: Harness = .{};
    try h.start(300, 120, null, null);
    defer h.stop();
    var select_all: Ran = .{};
    var save: Ran = .{};
    var new_folder: Ran = .{};
    var back: Ran = .{};
    var app_close: Ran = .{};
    var win_close: Ran = .{};
    var reload: Ran = .{};
    var help: Ran = .{};
    const sa = try create(&h, .{ .name = "select-all", .name_len = 10, .accels = &.{accel('a', .{ .ctrl = true }, 0)}, .accels_count = 1 }, &select_all);
    _ = try create(&h, .{ .name = "save", .name_len = 4, .window = h.window, .accels = &.{accel('s', .{ .ctrl = true }, 0)}, .accels_count = 1 }, &save);
    _ = try create(&h, .{ .name = "new-folder", .name_len = 10, .accels = &.{accel('N', .{ .ctrl = true, .shift = true }, 0)}, .accels_count = 1 }, &new_folder);
    _ = try create(&h, .{ .name = "back", .name_len = 4, .accels = &.{accel(ks.left, .{ .alt = true }, 0)}, .accels_count = 1 }, &back);
    // The window's close shadows the application's, keys and all.
    _ = try create(&h, .{ .name = "close", .name_len = 5, .accels = &.{accel('w', .{ .ctrl = true }, 0)}, .accels_count = 1 }, &app_close);
    _ = try create(&h, .{ .name = "close", .name_len = 5, .window = h.window, .accels = &.{accel('q', .{ .ctrl = true }, 0)}, .accels_count = 1 }, &win_close);
    _ = try create(&h, .{ .name = "reload", .name_len = 6, .accels = &.{accel(0xffc2, .{}, 0)}, .accels_count = 1 }, &reload);
    _ = try create(&h, .{ .name = "help", .name_len = 4, .accels = &.{accel(0xffc3, .{}, 0)}, .accels_count = 1 }, &help);

    const root = c.siv_window_get_root(h.window);
    var txn = try begin(h.window);
    const col = c.siv_flex(txn, root, &.{ .axis = .column });
    const field = c.siv_text_field(txn, col, &.{});
    const button = c.siv_push_button(txn, col, &.{ .label = "OK", .label_len = 2 });
    c.siv_on(txn, button, .activate, Pressed.on, null, null);
    // F5 prevented, F6 stopped, by a handler on the way up.
    c.siv_on(txn, root, .key, Prevent.on, null, null);
    try ok(c.siv_txn_commit(txn));
    try h.settle();

    // In the editor: Ctrl+A is the editor's, Ctrl+S is not, and Alt+Left
    // is never an editor's key.
    try ok(c.siv_node_focus(field));
    try h.typeKey('h', "h", .{});
    try h.typeKey('i', "i", .{});
    try h.typeKey('a', "", .{ .ctrl = true });
    try h.typeKey('s', "", .{ .ctrl = true });
    try h.typeKey(ks.left, "", .{ .alt = true });
    try h.settle();
    try testing.expectEqual(@as(u32, 0), select_all.count);
    try testing.expectEqual(@as(u32, 1), save.count);
    try testing.expectEqual(h.window, save.window);
    try testing.expectEqual(@as(u32, 1), back.count);
    var caret: u32 = 9;
    var anchor: u32 = 9;
    try ok(c.siv_node_get_selection(field, &caret, &anchor));
    try testing.expectEqual(@as(u32, 2), @max(caret, anchor));
    try testing.expectEqual(@as(u32, 0), @min(caret, anchor));

    // Elsewhere Ctrl+A is the application's. Letters match in either
    // case with Shift exact.
    try ok(c.siv_node_focus(button));
    try h.typeKey('a', "", .{ .ctrl = true });
    try h.typeKey('N', "", .{ .ctrl = true, .shift = true });
    try h.typeKey('n', "", .{ .ctrl = true });
    try h.settle();
    try testing.expectEqual(@as(u32, 1), select_all.count);
    try testing.expectEqual(h.window, select_all.window);
    try testing.expectEqual(@as(u32, 1), new_folder.count);

    // Disabled, its keys go on to siv's defaults.
    try ok(c.siv_action_set_enabled(sa, false));
    try h.typeKey('a', "", .{ .ctrl = true });
    try h.settle();
    try testing.expectEqual(t.Result.error_busy, c.siv_action_activate(sa, .null, 0));
    try ok(c.siv_action_set_enabled(sa, true));
    try ok(c.siv_action_activate(sa, h.window, 0));
    try h.settle();
    try testing.expectEqual(@as(u32, 2), select_all.count);

    // Shadowed: Ctrl+W does nothing here, Ctrl+Q is the window's.
    try h.typeKey('w', "", .{ .ctrl = true });
    try h.typeKey('q', "", .{ .ctrl = true });
    try h.settle();
    try testing.expectEqual(@as(u32, 0), app_close.count);
    try testing.expectEqual(@as(u32, 1), win_close.count);

    // A handler that prevents the default keeps the key from
    // accelerators; one that only stops it does not.
    try h.typeKey(0xffc2, "", .{});
    try h.typeKey(0xffc3, "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 0), reload.count);
    try testing.expectEqual(@as(u32, 1), help.count);

    // Enter activates the focused button rather than an accelerator.
    var enter: Ran = .{};
    _ = try create(&h, .{ .name = "enter", .name_len = 5, .accels = &.{accel(ks.@"return", .{}, 0)}, .accels_count = 1 }, &enter);
    try h.typeKey(ks.@"return", "\r", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 0), enter.count);
    try testing.expectEqual(@as(u32, 1), Pressed.count);
    try ok(c.siv_node_focus(field));
    try h.typeKey(ks.@"return", "\r", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 1), enter.count);

    // A modal dialog leaves only the application's accelerators.
    txn = try begin(h.window);
    _ = c.siv_dialog(txn, root, &.{ .title = "Sure?", .title_len = 5 });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.typeKey('s', "", .{ .ctrl = true });
    try h.typeKey('a', "", .{ .ctrl = true });
    try h.settle();
    try testing.expectEqual(@as(u32, 1), save.count);
    try testing.expectEqual(@as(u32, 3), select_all.count);
}

const ViewLog = struct {
    selects: u32 = 0,

    fn onSelect(ud: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        const l: *ViewLog = @ptrCast(@alignCast(ud.?));
        l.selects += 1;
        return .pass;
    }
};

test "widgets bound to an action follow it and run it; menu items show its label and key" {
    var h: Harness = .{};
    try h.start(320, 200, null, null);
    defer h.stop();
    var copy_ran: Ran = .{};
    var hidden_ran: Ran = .{};
    var view_ran: Ran = .{};
    const copy = try create(&h, .{ .name = "copy", .name_len = 4, .label = "Copy", .label_len = 4, .flags = .{ .disabled = true }, .accels = &.{accel('c', .{ .ctrl = true }, 0)}, .accels_count = 1 }, &copy_ran);
    const hidden = try create(&h, .{ .name = "show-hidden", .name_len = 11, .label = "Show Hidden Files", .label_len = 17, .kind = .toggle, .accels = &.{accel('h', .{ .ctrl = true }, 0)}, .accels_count = 1 }, &hidden_ran);
    const view_keys = [_]t.Accel{ accel('1', .{ .ctrl = true }, 0), accel('2', .{ .ctrl = true }, 1) };
    const view = try create(&h, .{ .name = "view", .name_len = 4, .window = h.window, .kind = .choice, .accels = &view_keys, .accels_count = 2 }, &view_ran);

    const root = c.siv_window_get_root(h.window);
    var txn = try begin(h.window);
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .align_items = .start });
    const button = c.siv_push_button(txn, col, &.{ .label = "Copy", .label_len = 4, .action = copy });
    const check = c.siv_check_box(txn, col, &.{ .label = "Hidden", .label_len = 6, .action = hidden });
    const grid = c.siv_toggle_button(txn, col, &.{ .label = "Grid", .label_len = 4, .action = view, .action_target = 1 });
    const menu = c.siv_menu_button(txn, col, &.{ .label = "Menu", .label_len = 4 });
    const copy_item = c.siv_menu_item(txn, menu, &.{ .action = copy });
    const hidden_item = c.siv_menu_item(txn, menu, &.{ .label = "Hidden Files", .label_len = 12, .action = hidden });
    const list_item = c.siv_menu_item(txn, menu, &.{ .label = "List", .label_len = 4, .action = view, .action_target = 0 });
    const grid_item = c.siv_menu_item(txn, menu, &.{ .label = "Grid", .label_len = 4, .action = view, .action_target = 1 });
    var log: ViewLog = .{};
    c.siv_on(txn, menu, .select, ViewLog.onSelect, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();

    // Bound at creation: disabled like the action, unchecked like its value.
    try testing.expect((try sem(button)).disabled);
    try testing.expectEqual(@as(f64, 0), try value(check));
    try testing.expectEqual(@as(f64, 0), try value(grid));
    try testing.expectEqual(@as(f64, 1), try value(list_item));
    try testing.expectEqual(@as(f64, 0), try value(grid_item));
    var bound: t.Action = .null;
    var target: f64 = -1;
    try ok(c.siv_node_get_action(grid_item, &bound, &target));
    try testing.expectEqual(view, bound);
    try testing.expectEqual(@as(f64, 1), target);

    // Changes reach them at once, or once the transaction open on their
    // window ends.
    try ok(c.siv_action_set_enabled(copy, true));
    try testing.expect(!(try sem(button)).disabled);
    txn = try begin(h.window);
    try ok(c.siv_action_set_value(hidden, 1));
    try testing.expectEqual(@as(f64, 0), try value(check));
    try ok(c.siv_txn_commit(txn));
    try testing.expectEqual(@as(f64, 1), try value(check));
    try testing.expectEqual(@as(f64, 1), try value(hidden_item));
    try testing.expectEqual(@as(u32, 0), hidden_ran.count);

    // A key flips the toggle; a click on the check box flips it back, once.
    try h.typeKey('h', "", .{ .ctrl = true });
    try h.settle();
    try testing.expectEqual(@as(u32, 1), hidden_ran.count);
    try testing.expectEqual(@as(f64, 0), hidden_ran.value);
    try testing.expectEqual(@as(f64, 0), try value(check));
    const cc = try center(check);
    try h.click(cc[0], cc[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 2), hidden_ran.count);
    try testing.expectEqual(@as(f64, 1), hidden_ran.value);
    try testing.expectEqual(@as(f64, 1), try value(check));

    // Ctrl+2 chooses the grid; a click on the pressed Grid toggle keeps
    // it pressed, since the choice stays.
    try h.typeKey('2', "", .{ .ctrl = true });
    try h.settle();
    try testing.expectEqual(@as(f64, 1), view_ran.value);
    try testing.expectEqual(@as(f64, 1), try value(grid));
    try testing.expectEqual(@as(f64, 1), try value(grid_item));
    try testing.expectEqual(@as(f64, 0), try value(list_item));
    const gc = try center(grid);
    try h.click(gc[0], gc[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 2), view_ran.count);
    try testing.expectEqual(@as(f64, 1), try value(grid));

    // The button runs its action, and tells assistive technology its key.
    const bc = try center(button);
    try h.click(bc[0], bc[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), copy_ran.count);
    // So does an activation a widget reports itself (a dialog's mnemonic).
    try ok(c.siv_node_emit(button, &.{ .type = .activate }, null));
    try testing.expectEqual(@as(u32, 2), copy_ran.count);
    try testing.expectEqual(ui.Accel.of('c', .{ .ctrl = true }), (try sem(button)).shortcut);
    try testing.expectEqual(ui.Accel.of('2', .{ .ctrl = true }), (try sem(grid)).shortcut);

    // The menu: the copy item takes the action's label, every bound item
    // its key, and checks follow the values.
    const mc = try center(menu);
    try h.click(mc[0], mc[1]);
    try h.settle();
    const popup = c.siv_test_get_popup(h.app);
    try testing.expect(popup != .null);
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_test_dump(popup, &buf, buf.len, &len));
    const dump = buf[0..len];
    errdefer std.debug.print("{s}\n", .{dump});
    try testing.expect(std.mem.indexOf(u8, dump, "menu_item \"Copy\" focused shortcut=Ctrl+C") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "menu_item \"Hidden Files\" checked=on shortcut=Ctrl+H") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "menu_item \"List\" checked=off shortcut=Ctrl+1") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "menu_item \"Grid\" checked=on shortcut=Ctrl+2") != null);
    const pw = try A.App.window(@backingInt(popup), A.window_tag);
    const tree = try pw.uiWin().semanticsTree();
    const row = tree.find(.menu_item, "List").?;
    const label_shown = blk: {
        // The row shows the key at its end edge.
        var it = pw.uiWin().children(row.node);
        var found = false;
        while (it.next()) |child| {
            if (pw.uiWin().node(child).kind != .text) continue;
            var tb: [32]u8 = undefined;
            var tl: usize = 0;
            try ok(c.siv_node_get_text(@fromBackingInt(pw.nodes.handle(child)), &tb, tb.len, &tl));
            if (std.mem.eql(u8, tb[0..@min(tl, tb.len)], "Ctrl+1")) found = true;
        }
        break :blk found;
    };
    try testing.expect(label_shown);
    // Choosing List reports the select, then runs the action.
    try h.clickIn(popup, (row.bounds.x0 + row.bounds.x1) / 2, (row.bounds.y0 + row.bounds.y1) / 2);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.selects);
    try testing.expectEqual(@as(u32, 3), view_ran.count);
    try testing.expectEqual(@as(f64, 0), view_ran.value);
    try testing.expectEqual(@as(f64, 0), try value(grid));
    try testing.expectEqual(@as(f64, 1), try value(list_item));

    // Destroyed, the action leaves its nodes as they are and they run
    // nothing.
    c.siv_action_destroy(copy);
    try ok(c.siv_node_get_action(copy_item, &bound, null));
    try testing.expectEqual(t.Action.null, bound);
    try h.click(bc[0], bc[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 2), copy_ran.count);
}

test "a window lists its actions, then the application's it does not shadow; accelerators format" {
    var h: Harness = .{};
    try h.start(100, 60, null, null);
    defer h.stop();
    var ran: Ran = .{};
    const quit = try create(&h, .{ .name = "quit", .name_len = 4, .label = "Quit", .label_len = 4, .accels = &.{accel('q', .{ .ctrl = true }, 0)}, .accels_count = 1 }, &ran);
    const app_close = try create(&h, .{ .name = "close", .name_len = 5 }, &ran);
    const win_close = try create(&h, .{ .name = "close", .name_len = 5, .window = h.window, .label = "Close Window", .label_len = 12 }, &ran);
    const zoom = try create(&h, .{ .name = "zoom", .name_len = 4, .window = h.window, .kind = .choice, .value = 2 }, &ran);
    try testing.expectEqual(win_close, c.siv_app_get_action(h.app, h.window, 0));
    try testing.expectEqual(zoom, c.siv_app_get_action(h.app, h.window, 1));
    try testing.expectEqual(quit, c.siv_app_get_action(h.app, h.window, 2));
    try testing.expectEqual(t.Action.null, c.siv_app_get_action(h.app, h.window, 3));
    try testing.expectEqual(quit, c.siv_app_get_action(h.app, .null, 0));
    try testing.expectEqual(app_close, c.siv_app_get_action(h.app, .null, 1));
    try testing.expectEqual(t.Action.null, c.siv_app_get_action(h.app, .null, 2));

    var st: t.ActionState = undefined;
    try ok(c.siv_action_get_state(zoom, &st));
    try testing.expectEqual(h.window, st.window);
    try testing.expectEqual(t.ActionKind.choice, st.kind);
    try testing.expectEqual(@as(f64, 2), st.value);
    try ok(c.siv_action_get_state(quit, &st));
    try testing.expectEqual(@as(u32, 1), st.accel_count);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_action_get_label(win_close, &buf, buf.len, &len));
    try testing.expectEqualStrings("Close Window", buf[0..len]);
    try ok(c.siv_action_get_name(win_close, &buf, buf.len, &len));
    try testing.expectEqualStrings("close", buf[0..len]);
    var k: t.Accel = undefined;
    try ok(c.siv_action_get_accel(quit, 0, &k));
    try ok(c.siv_accel_format(k, &buf, buf.len, &len));
    try testing.expectEqualStrings("Ctrl+Q", buf[0..len]);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_action_get_accel(quit, 1, &k));
    try ok(c.siv_action_set_accels(quit, &.{ accel(0xffff, .{ .shift = true }, 0), accel('q', .{ .ctrl = true }, 0) }, 2));
    try ok(c.siv_action_get_accel(quit, 0, &k));
    try ok(c.siv_accel_format(k, &buf, buf.len, &len));
    try testing.expectEqualStrings("Shift+Delete", buf[0..len]);

    // Invalid: Caps Lock in an accelerator, a toggle's value of 2, a
    // plain action's value.
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_action_set_accels(quit, &.{accel('q', .{ .caps_lock = true }, 0)}, 1));
    var a: t.Action = .null;
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_action_create(h.app, &.{ .name = "t", .name_len = 1, .kind = .toggle, .value = 2 }, null, null, null, &a));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_action_set_value(quit, 1));

    // A window's actions go with it.
    c.siv_window_destroy(h.window);
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_action_get_state(zoom, &st));
    try testing.expectEqual(app_close, c.siv_app_get_action(h.app, .null, 1));
}
