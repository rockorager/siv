//! Navigation widgets (D17, D22, D40) through the C ABI on the headless
//! backend: a sidebar, header bars, and a navigation stack, built with
//! the exported builders, driven by injected keys and clicks, and
//! checked against golden images under test/golden/widgets/ and the
//! semantics tree.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const ui = @import("ui");
const platform = @import("platform");
const harness = @import("../abi/harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const A = abi.application;
const Harness = harness.Harness;
const ok = harness.ok;

const ks = struct {
    const @"return": u32 = 0xff0d;
    const escape: u32 = 0xff1b;
    const home: u32 = 0xff50;
    const left: u32 = 0xff51;
    const up: u32 = 0xff52;
    const right: u32 = 0xff53;
    const down: u32 = 0xff54;
    const end: u32 = 0xff57;
    const back: u32 = 0x1008ff26;
};

/// What the application's handlers saw.
const Log = struct {
    changes: u32 = 0,
    value: f64 = -100,
    index: u32 = 0,
    node: t.Node = .null,
    closes: u32 = 0,
    /// Keep pages that ask to close.
    keep: bool = false,

    fn onChange(ud: ?*anyopaque, node: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.changes += 1;
        log.value = ev.value;
        log.index = ev.index;
        log.node = node;
        return .handled;
    }

    fn onClose(ud: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.closes += 1;
        return if (log.keep) .handled else .pass;
    }
};

const Mail = struct {
    sidebar: t.Node,
    items: [5]t.Node,
    stack: t.Node,
    inbox: t.Node,
    open: t.Node,
    bar: t.Node,
};

/// A mail window: a sidebar of mailboxes with its own header bar, and a
/// navigation stack whose first page lists the inbox.
fn buildMail(h: *Harness, log: *Log) !Mail {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const row = c.siv_flex(txn, root, &.{ .align_items = .stretch });
    _ = c.siv_set_layout(txn, row, &.{ .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
    var m: Mail = undefined;
    m.sidebar = c.siv_sidebar(txn, row, &.{ .label = "Mailboxes", .label_len = 9 });
    _ = c.siv_header_bar(txn, c.siv_widget_get_part(m.sidebar, .start, 0), &.{ .title = "Mail", .title_len = 4, .flags = .{ .no_window_controls = true } });
    m.items[0] = c.siv_sidebar_item(txn, m.sidebar, &.{ .label = "Inbox", .label_len = 5, .icon = "folder", .icon_len = 6 });
    const count = c.siv_text(txn, c.siv_widget_get_part(m.items[0], .end, 0), "3", 1);
    _ = c.siv_set_text_style(txn, count, &.{ .color_token = .muted_fg, .size_role = .caption });
    m.items[1] = c.siv_sidebar_item(txn, m.sidebar, &.{ .label = "Drafts", .label_len = 6, .icon = "document-new", .icon_len = 12 });
    const labels = c.siv_sidebar_section(txn, m.sidebar, &.{ .title = "Labels", .title_len = 6 });
    m.items[2] = c.siv_sidebar_item(txn, labels, &.{ .label = "Work", .label_len = 4, .icon = "folder-documents", .icon_len = 16 });
    m.items[3] = c.siv_sidebar_item(txn, labels, &.{ .label = "Family", .label_len = 6, .icon = "folder", .icon_len = 6, .flags = .{ .disabled = true } });
    m.items[4] = c.siv_sidebar_item(txn, labels, &.{ .label = "Travel", .label_len = 6, .icon = "folder", .icon_len = 6 });
    _ = c.siv_widget_set_value(txn, m.sidebar, 0);
    _ = c.siv_on(txn, m.sidebar, .change, Log.onChange, null, log);

    m.stack = c.siv_navigation_stack(txn, row, null);
    _ = c.siv_on(txn, m.stack, .change, Log.onChange, null, log);
    m.inbox = c.siv_navigation_page(txn, m.stack, &.{ .title = "Inbox", .title_len = 5 });
    m.bar = c.siv_header_bar(txn, m.inbox, null);
    _ = c.siv_push_button(txn, c.siv_widget_get_part(m.bar, .start, 0), &.{ .label = "Compose", .label_len = 7, .style = .flat, .icon = "document-new", .icon_len = 12, .flags = .{ .icon_only = true } });
    _ = c.siv_push_button(txn, c.siv_widget_get_part(m.bar, .end, 0), &.{ .label = "Mark as Read", .label_len = 12, .style = .flat, .icon = "emblem-ok-symbolic", .icon_len = 18, .flags = .{ .icon_only = true } });
    const body = c.siv_flex(txn, m.inbox, &.{ .axis = .column, .gap = 8, .align_items = .start });
    _ = c.siv_set_layout(txn, body, &.{ .padding = .{ .start = 16, .end = 16, .top = 16, .bottom = 16 } });
    _ = c.siv_text(txn, body, "3 messages", 10);
    m.open = c.siv_push_button(txn, body, &.{ .label = "Open", .label_len = 4 });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    return m;
}

/// Pushes a page with a header bar of its own and a button.
fn pushMessage(h: *Harness, m: *const Mail, log: *Log) !t.Node {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const page = c.siv_navigation_page(txn, m.stack, &.{ .title = "Lunch on Friday?", .title_len = 16 });
    _ = c.siv_on(txn, page, .close, Log.onClose, null, log);
    _ = c.siv_header_bar(txn, page, null);
    const body = c.siv_flex(txn, page, &.{ .axis = .column, .gap = 8, .align_items = .start });
    _ = c.siv_set_layout(txn, body, &.{ .padding = .{ .start = 16, .end = 16, .top = 16, .bottom = 16 } });
    _ = c.siv_text(txn, body, "From Ada: shall we meet at noon?", 32);
    _ = c.siv_push_button(txn, body, &.{ .label = "Reply", .label_len = 5, .style = .primary });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    return page;
}

fn center(n: t.Node) ![2]f64 {
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(n, &r));
    return .{ r.x + r.width / 2, r.y + r.height / 2 };
}

fn value(n: t.Node) !f64 {
    var v: f64 = undefined;
    try ok(c.siv_widget_get_value(n, &v));
    return v;
}

fn find(h: *Harness, role: t.Role, name: []const u8) !?t.TestNode {
    var found = false;
    var node: t.TestNode = undefined;
    try ok(c.siv_test_find(h.window, &.{ .role = role, .name = name.ptr, .name_len = name.len }, &found, &node));
    return if (found) node else null;
}

fn focused(h: *Harness) t.Node {
    return c.siv_window_get_focus(h.window);
}

fn key(h: *Harness, sym: u32, mods: platform.Mods) !void {
    try h.typeKey(sym, "", mods);
    try h.settle();
}

fn pointerButton(h: *Harness, x: f64, y: f64, button: u32) !void {
    const id = (try h.win()).win.id;
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = id, .seat = 0, .x = x, .y = y } },
        .{ .pointer_button = .{ .window = id, .seat = 0, .button = button, .pressed = true, .time = 0, .serial = 5 } },
        .{ .pointer_button = .{ .window = id, .seat = 0, .button = button, .pressed = false, .time = 0, .serial = 6 } },
    });
    try h.settle();
}

fn startMail(h: *Harness, rtl: bool) !void {
    try h.startWith(.{ .width = 600, .height = 300, .flags = .{ .client_decorations = true, .rtl = rtl } });
}

test "navigation: a sidebar, header bars, and a stack, pushed and popped" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try startMail(&h, false);
    defer h.stop();
    var log: Log = .{};
    const m = try buildMail(&h, &log);
    try h.expectGolden("navigation", 600, 300);

    // The sidebar is a navigation landmark whose current item says so;
    // sections are lists named by their titles.
    const nav = (try find(&h, .navigation, "Mailboxes")).?;
    try testing.expectEqual(t.Current.none, nav.current);
    try testing.expectEqual(t.Current.page, (try find(&h, .list_item, "Inbox 3")).?.current);
    try testing.expectEqual(t.Current.none, (try find(&h, .list_item, "Drafts")).?.current);
    try testing.expect((try find(&h, .list, "Labels")) != null);
    // The page's header bar shows the page's title and, since the window
    // decorates itself, the window controls; the sidebar's shows neither.
    try testing.expect((try find(&h, .toolbar, "Inbox")) != null);
    try testing.expect((try find(&h, .toolbar, "Mail")) != null);
    for ([_][]const u8{ "Minimize", "Maximize", "Close" }) |name| try testing.expect((try find(&h, .button, name)) != null);
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_test_dump(h.window, &buf, buf.len, &len));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, buf[0..len], "button \"Close\"") + std.mem.count(u8, buf[0..len], "button \"Minimize\"") + std.mem.count(u8, buf[0..len], "button \"Maximize\""));
    try testing.expect((try find(&h, .button, "Back")) == null);
    try testing.expectEqual(@as(f64, 1), try value(m.stack));

    // A push from the first page moves focus to the new page, which shows
    // a back button exposing its key.
    try ok(c.siv_node_focus(m.open));
    const page = try pushMessage(&h, &m, &log);
    try h.expectGolden("navigation-pushed", 600, 300);
    try testing.expectEqual(@as(f64, 2), try value(m.stack));
    try testing.expectEqual(page, focused(&h));
    try testing.expect((try find(&h, .toolbar, "Lunch on Friday?")) != null);
    try testing.expect((try find(&h, .button, "Open")) == null);
    try testing.expect(std.mem.indexOf(u8, blk: {
        try ok(c.siv_test_dump(h.window, &buf, buf.len, &len));
        break :blk buf[0..len];
    }, "button \"Back\" shortcut=Alt+Left") != null);
    try testing.expectEqual(page, c.siv_widget_get_part(m.stack, .panel, 1));

    // The back button asks the page to close; it goes, the stack reports
    // its new depth, and focus returns to the button that had it.
    const back = (try find(&h, .button, "Back")).?;
    try h.click(back.bounds.x + back.bounds.width / 2, back.bounds.y + back.bounds.height / 2);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.closes);
    try testing.expectEqual(@as(u32, 1), log.changes);
    try testing.expectEqual(m.stack, log.node);
    try testing.expectEqual(@as(f64, 1), log.value);
    try testing.expectEqual(@as(u32, 0), log.index);
    try testing.expectEqual(@as(f64, 1), try value(m.stack));
    try testing.expectEqual(m.open, focused(&h));
    try testing.expect(c.siv_node_get_window(page) == .null);
    // The first page shows as before, once the pointer leaves the button
    // that took the back button's place.
    try h.inject(&.{.{ .pointer_motion = .{ .window = (try h.win()).win.id, .seat = 0, .x = 400, .y = 250 } }});
    try h.settle();
    try h.expectGolden("navigation", 600, 300);
}

test "navigation: with motion, pages settle where reduced motion puts them" {
    // Springs run on the compositor (D38); settling waits for them, and
    // the page that went back is gone with its layer.
    var h: Harness = .{ .golden = "test/golden/widgets", .reduced_motion = false };
    try startMail(&h, false);
    defer h.stop();
    var log: Log = .{};
    const m = try buildMail(&h, &log);
    try ok(c.siv_node_focus(m.open));
    _ = try pushMessage(&h, &m, &log);
    try h.expectGolden("navigation-pushed", 600, 300);
    // The mouse's back button, so focus returns without a ring.
    try pointerButton(&h, 400, 250, 0x113);
    try testing.expectEqual(m.open, focused(&h));
    try h.expectGolden("navigation", 600, 300);
}

test "navigation: focus stays outside the stack; titles follow the page" {
    var h: Harness = .{};
    try startMail(&h, false);
    defer h.stop();
    var log: Log = .{};
    const m = try buildMail(&h, &log);
    // Pushing while the sidebar has focus leaves it there, as choosing a
    // destination by keys pushes pages without taking the keyboard away.
    try ok(c.siv_node_focus(m.sidebar));
    const page = try pushMessage(&h, &m, &log);
    try testing.expectEqual(m.items[0], focused(&h));
    // Renaming the page renames its header bar, which has no title of
    // its own; the page's group is named the same.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_widget_set_label(txn, page, "Re: Lunch", 9);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expect((try find(&h, .toolbar, "Re: Lunch")) != null);
    try testing.expect((try find(&h, .group, "Re: Lunch")) != null);
    // siv_node_focus on the stack focuses the page that shows.
    try ok(c.siv_node_focus(m.stack));
    try testing.expectEqual(page, focused(&h));
}

test "navigation: going back by keys and the mouse, kept by a handler" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try startMail(&h, false);
    defer h.stop();
    var log: Log = .{};
    const m = try buildMail(&h, &log);

    // Alt+Left, Escape, XF86Back, and the mouse's back button each go back
    // one page; on the first page they do nothing.
    const Way = enum { alt_left, escape, back_key, back_button };
    for (std.enums.values(Way)) |way| {
        _ = try pushMessage(&h, &m, &log);
        const before = log.changes;
        switch (way) {
            .alt_left => try key(&h, ks.left, .{ .alt = true }),
            .escape => try key(&h, ks.escape, .{}),
            .back_key => try key(&h, ks.back, .{}),
            .back_button => try pointerButton(&h, 400, 200, 0x113),
        }
        try testing.expectEqual(before + 1, log.changes);
        try testing.expectEqual(@as(f64, 1), try value(m.stack));
    }
    const closes = log.closes;
    try ok(c.siv_node_focus(m.open));
    try key(&h, ks.left, .{ .alt = true });
    try key(&h, ks.escape, .{});
    try testing.expectEqual(closes, log.closes);
    try testing.expectEqual(@as(f64, 1), try value(m.stack));

    // Alt+Right is forward, not back, in a left-to-right window.
    _ = try pushMessage(&h, &m, &log);
    try key(&h, ks.right, .{ .alt = true });
    try testing.expectEqual(@as(f64, 2), try value(m.stack));

    // A handler that keeps the page keeps it, with no change.
    log.keep = true;
    const changes = log.changes;
    try key(&h, ks.escape, .{});
    try testing.expectEqual(closes + 1, log.closes);
    try testing.expectEqual(changes, log.changes);
    try testing.expectEqual(@as(f64, 2), try value(m.stack));

    // The application pops without a report, and cannot push past the
    // pages it has.
    _ = try pushMessage(&h, &m, &log);
    try testing.expectEqual(@as(f64, 3), try value(m.stack));
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_widget_set_value(txn, m.stack, 1);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(@as(f64, 1), try value(m.stack));
    try testing.expectEqual(changes, log.changes);
    try testing.expect((try find(&h, .button, "Open")) != null);
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_widget_set_value(txn, m.stack, 2);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
}

test "navigation: keys in the sidebar move the current item" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try startMail(&h, false);
    defer h.stop();
    var log: Log = .{};
    const m = try buildMail(&h, &log);

    // Only the current item is a Tab stop; focusing the sidebar focuses it.
    try ok(c.siv_node_focus(m.sidebar));
    try testing.expectEqual(m.items[0], focused(&h));
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_test_dump(h.window, &buf, buf.len, &len));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, buf[0..len], "current=page"));

    // Down chooses the next item across sections, skipping the disabled
    // one, and reports it; End and Home go to the ends.
    const Step = struct { u32, usize };
    for ([_]Step{ .{ ks.down, 1 }, .{ ks.down, 2 }, .{ ks.down, 4 }, .{ ks.down, 4 }, .{ ks.up, 2 }, .{ ks.home, 0 }, .{ ks.end, 4 } }) |s| {
        try key(&h, s[0], .{});
        try testing.expectEqual(m.items[s[1]], focused(&h));
        try testing.expectEqual(@as(f64, @floatFromInt(s[1])), try value(m.sidebar));
        try testing.expectEqual(t.Current.page, (try find(&h, .list_item, switch (s[1]) {
            0 => "Inbox 3",
            1 => "Drafts",
            2 => "Work",
            else => "Travel",
        })).?.current);
    }
    try testing.expectEqual(@as(u32, 6), log.changes);
    try testing.expectEqual(m.sidebar, log.node);
    try testing.expectEqual(@as(u32, 4), log.index);
    try testing.expectEqual(m.items[2], c.siv_widget_get_part(m.sidebar, .item, 2));

    // A click chooses and focuses, so keys go on from the item clicked;
    // one on the disabled item does nothing.
    try ok(c.siv_node_focus(m.open));
    const drafts = try center(m.items[1]);
    try h.click(drafts[0], drafts[1]);
    try h.settle();
    try testing.expectEqual(@as(f64, 1), try value(m.sidebar));
    try testing.expectEqual(m.items[1], focused(&h));
    const family = try center(m.items[3]);
    try h.click(family[0], family[1]);
    try h.settle();
    try testing.expectEqual(@as(f64, 1), try value(m.sidebar));
    try testing.expectEqual(@as(u32, 7), log.changes);

    // Hover on one item, keyboard focus on another.
    const travel = try center(m.items[4]);
    try h.inject(&.{.{ .pointer_motion = .{ .window = (try h.win()).win.id, .seat = 0, .x = travel[0], .y = travel[1] } }});
    try ok(c.siv_node_focus(m.sidebar));
    try key(&h, ks.down, .{});
    try h.expectGolden("navigation-sidebar-focus", 600, 300);

    // Its separator is the divider part, which a sidebar in a split pane
    // hides: the items take its pixel.
    var r: t.Rect = undefined;
    const start = c.siv_widget_get_part(m.sidebar, .start, 0);
    try ok(c.siv_node_get_rect(start, &r));
    try testing.expectEqual(@as(f32, 219), r.width);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_set_hidden(txn, c.siv_widget_get_part(m.sidebar, .divider, 0), true);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_get_rect(start, &r));
    try testing.expectEqual(@as(f32, 220), r.width);

    // Hidden, the sidebar takes no space: the stack fills the window.
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_set_hidden(txn, m.sidebar, true);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_get_rect(m.stack, &r));
    try testing.expectEqual(@as(f32, 0), r.x);
    try testing.expectEqual(@as(f32, 600), r.width);
}

test "navigation: right to left mirrors the sidebar, the bars, and going back" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try startMail(&h, true);
    defer h.stop();
    var log: Log = .{};
    const m = try buildMail(&h, &log);
    _ = try pushMessage(&h, &m, &log);
    try h.expectGolden("navigation-rtl", 600, 300);
    // Back points to the start edge, on the right: Alt+Right.
    try key(&h, ks.left, .{ .alt = true });
    try testing.expectEqual(@as(f64, 2), try value(m.stack));
    try key(&h, ks.right, .{ .alt = true });
    try testing.expectEqual(@as(f64, 1), try value(m.stack));
}

test "navigation: a header bar's content can take the width its controls leave" {
    var h: Harness = .{};
    try h.start(400, 120, null, null);
    defer h.stop();
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const col = c.siv_flex(txn, c.siv_window_get_root(h.window), &.{ .axis = .column, .align_items = .stretch });
    _ = c.siv_set_layout(txn, col, &.{ .width = .{ .unit = .fraction, .value = 1 } });
    // One with a centered title between equal sides, one with a path bar.
    var parts: [2][3]t.Node = undefined;
    for ([_]bool{ false, true }, &parts) |expand, *p| {
        const bar = c.siv_header_bar(txn, col, &.{ .flags = .{ .expand_content = expand } });
        p[0] = c.siv_widget_get_part(bar, .start, 0);
        p[1] = c.siv_widget_get_part(bar, .content, 0);
        p[2] = c.siv_widget_get_part(bar, .end, 0);
        for ([_]t.Node{ p[0], p[0], p[2] }) |box| _ = c.siv_push_button(txn, box, &.{ .label = "Go", .label_len = 2, .style = .flat, .icon = "folder", .icon_len = 6, .flags = .{ .icon_only = true } });
        const path = c.siv_box(txn, p[1]);
        _ = c.siv_set_layout(txn, path, &.{ .grow = 1, .height = .{ .unit = .px, .value = 20 } });
    }
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    var r: [2][3]t.Rect = undefined;
    for (parts, &r) |p, *rr| for (p, rr) |n, *x| try ok(c.siv_node_get_rect(n, x));
    // Equal sides take half each and leave the content nothing; with
    // expand_content the sides take their buttons' width and the content
    // the rest, up to the gaps between them.
    try testing.expectEqual(@as(f32, 0), r[0][1].width);
    try testing.expect(r[0][0].width > 150);
    const start = r[1][0];
    const content = r[1][1];
    const end = r[1][2];
    try testing.expect(start.width < 100);
    try testing.expectApproxEqAbs(start.x + start.width + 6, content.x, 0.5);
    try testing.expectApproxEqAbs(content.x + content.width + 6, end.x, 0.5);
    // Unknown flags are refused.
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_header_bar(txn, col, &.{ .flags = @bitCast(@as(u32, 4)) });
    try testing.expectEqual(t.Result.error_unsupported, c.siv_txn_commit(txn));
}

fn keepOpen(ud: ?*anyopaque, _: t.Window, ev: *const t.WindowEvent) callconv(.c) bool {
    const n: *u32 = @ptrCast(@alignCast(ud.?));
    if (ev.type == .close_requested) n.* += 1;
    return true;
}

test "navigation: window controls follow the decorations and the window's states" {
    // The compositor decorates: no controls, and the bar is a toolbar.
    {
        var h: Harness = .{};
        try h.start(400, 120, null, null);
        defer h.stop();
        try h.settle();
        var controls: t.WindowControls = .{ .close = true };
        try ok(c.siv_window_get_controls(h.window, &controls));
        try testing.expectEqual(t.WindowControls{}, controls);
        var txn: t.Txn = .null;
        try ok(c.siv_txn_begin(h.window, &txn));
        _ = c.siv_header_bar(txn, c.siv_window_get_root(h.window), &.{ .title = "Notes", .title_len = 5 });
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        try testing.expect((try find(&h, .toolbar, "Notes")) != null);
        try testing.expect((try find(&h, .button, "Close")) == null);
    }
    var closes: u32 = 0;
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.startWith(.{ .width = 400, .height = 120, .flags = .{ .client_decorations = true }, .on_event = keepOpen, .user_data = &closes });
    defer h.stop();
    try h.settle();
    var controls: t.WindowControls = .{};
    try ok(c.siv_window_get_controls(h.window, &controls));
    try testing.expectEqual(t.WindowControls{ .close = true, .minimize = true, .maximize = true, .menu = true }, controls);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .align_items = .stretch });
    _ = c.siv_set_layout(txn, col, &.{ .width = .{ .unit = .fraction, .value = 1 } });
    _ = c.siv_header_bar(txn, col, &.{ .title = "Notes", .title_len = 5 });
    try ok(c.siv_txn_commit(txn));
    try h.settle();

    // Maximized, the maximize button restores.
    try ok(c.siv_test_set_states(h.window, .{ .maximized = true, .activated = true }));
    try h.settle();
    try testing.expect((try find(&h, .button, "Restore")) != null);
    try testing.expect((try find(&h, .button, "Maximize")) == null);
    try h.expectGolden("navigation-header-maximized", 400, 120);
    try ok(c.siv_test_set_states(h.window, .{ .activated = true }));
    try h.settle();
    try testing.expect((try find(&h, .button, "Maximize")) != null);

    // Close asks the application, as the compositor's close button does.
    const close = (try find(&h, .button, "Close")).?;
    try h.click(close.bounds.x + close.bounds.width / 2, close.bounds.y + close.bounds.height / 2);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), closes);
    try testing.expect(c.siv_window_get_app(h.window) != .null);
}
