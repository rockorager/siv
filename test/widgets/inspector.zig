//! The inspector (D46): the introspection API on a window of stock
//! widgets with subtree themes (node info, properties read and set as
//! text, accessible names, the node at a point, counters), picking by
//! pointing, the overlays, the repaint flashes, the keys, and siv's
//! inspector window, checked against golden images under
//! test/golden/widgets/.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const harness = @import("../abi/harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const A = abi.application;
const Harness = harness.Harness;
const ok = harness.ok;

const width = 420;
const height = 220;

fn px(v: f32) t.Dimension {
    return .{ .unit = .px, .value = v };
}

const Scene = struct {
    sidebar: t.Node,
    heading: t.Node,
    content: t.Node,
    save: t.Node,
    cancel: t.Node,
};

/// A dark sidebar (a subtree theme, D43) beside a padded column with a
/// heading and two buttons.
fn build(h: *Harness, on_activate: ?t.EventFn, activations: *u32) !Scene {
    var s: Scene = undefined;
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const row = c.siv_flex(txn, root, &.{});
    _ = c.siv_set_layout(txn, row, &.{ .height = .{ .unit = .fraction, .value = 1 } });
    s.sidebar = c.siv_flex(txn, row, &.{ .axis = .column, .gap = 4 });
    _ = c.siv_set_theme(txn, s.sidebar, &.{ .scheme = .dark });
    _ = c.siv_set_layout(txn, s.sidebar, &.{ .width = px(120), .padding = .{ .start = 10, .end = 10, .top = 10, .bottom = 10 } });
    _ = c.siv_set_visual(txn, s.sidebar, &.{ .background_token = .sidebar_bg });
    for ([_][]const u8{ "Home", "Music" }) |name| {
        const n = c.siv_text(txn, s.sidebar, name.ptr, name.len);
        _ = c.siv_set_text_style(txn, n, &.{ .color_token = .view_fg, .size_role = .body, .flags = .{ .no_wrap = true } });
    }
    s.content = c.siv_flex(txn, row, &.{ .axis = .column, .gap = 12, .align_items = .start });
    _ = c.siv_set_layout(txn, s.content, &.{ .grow = 1, .padding = .{ .start = 16, .end = 16, .top = 14, .bottom = 14 } });
    s.heading = c.siv_text(txn, s.content, "Documents", 9);
    _ = c.siv_set_text_style(txn, s.heading, &.{ .color_token = .window_fg, .size_role = .heading, .flags = .{ .no_wrap = true } });
    const buttons = c.siv_flex(txn, s.content, &.{ .gap = 6 });
    s.cancel = c.siv_push_button(txn, buttons, &.{ .label = "Cancel", .label_len = 6 });
    s.save = c.siv_push_button(txn, buttons, &.{ .label = "Save", .label_len = 4, .style = .primary });
    if (on_activate) |f| {
        _ = c.siv_on(txn, s.save, .activate, f, null, activations);
        _ = c.siv_on(txn, s.cancel, .activate, f, null, activations);
    }
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    return s;
}

fn count(ud: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
    const n: *u32 = @ptrCast(@alignCast(ud.?));
    n.* += 1;
    return .handled;
}

fn info(n: t.Node) !t.NodeInfo {
    var i: t.NodeInfo = undefined;
    try ok(c.siv_node_get_info(n, &i));
    return i;
}

/// A property's index by name.
fn property(n: t.Node, name: []const u8) !u32 {
    const total = (try info(n)).properties;
    var buf: [64]u8 = undefined;
    for (0..total) |i| {
        var len: usize = 0;
        try ok(c.siv_node_get_property_name(n, @intCast(i), &buf, buf.len, &len));
        if (std.mem.eql(u8, buf[0..len], name)) return @intCast(i);
    }
    std.debug.print("no property {s}\n", .{name});
    return error.TestUnexpectedResult;
}

fn value(n: t.Node, name: []const u8, buf: []u8) ![]const u8 {
    var len: usize = 0;
    try ok(c.siv_node_get_property_value(n, try property(n, name), buf.ptr, buf.len, &len));
    return buf[0..len];
}

fn setProperty(h: *Harness, n: t.Node, name: []const u8, v: []const u8) t.Result {
    var txn: t.Txn = .null;
    if (c.siv_txn_begin(h.window, &txn) != .ok) return .error_invalid_argument;
    c.siv_set_property(txn, n, name.ptr, name.len, v.ptr, v.len);
    return c.siv_txn_commit(txn);
}

test "inspector: node info, properties as text, names, and the node at a point" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(width, height, null, null);
    defer h.stop();
    var n: u32 = 0;
    const s = try build(&h, null, &n);

    const side = try info(s.sidebar);
    try testing.expectEqual(t.NodeKind.flex, side.kind);
    try testing.expect(side.flags.theme and side.flags.shown and !side.flags.hidden);
    try testing.expectEqual(t.ThemeVariant.dark, side.variant);
    try testing.expectEqual(@as(u32, 2), side.children);
    try testing.expectEqual(@as(f32, 120), side.rect.width);
    // The content box is the border box less the padding.
    try testing.expectEqual(side.rect.x + 10, side.content.x);
    try testing.expectEqual(side.rect.width - 20, side.content.width);
    try testing.expectEqual(side.rect.height - 20, side.content.height);
    try testing.expectEqual(t.ThemeVariant.light, (try info(s.content)).variant);

    const save = try info(s.save);
    try testing.expectEqual(t.Role.button, save.role);
    try testing.expect(save.flags.widget and save.flags.focusable and save.flags.accessible);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_node_get_name(s.save, &buf, buf.len, &len));
    try testing.expectEqualStrings("Save", buf[0..len]);
    try ok(c.siv_node_get_name(s.heading, &buf, buf.len, &len));
    try testing.expectEqualStrings("Documents", buf[0..len]);

    // Properties read in the form siv_set_property takes, with whether
    // the application set them.
    var vb: [128]u8 = undefined;
    try testing.expectEqualStrings("120", try value(s.sidebar, "width", &vb));
    try testing.expectEqualStrings("10", try value(s.sidebar, "padding", &vb));
    try testing.expectEqualStrings("auto", try value(s.content, "width", &vb));
    try testing.expectEqualStrings("dark", try value(s.sidebar, "scheme", &vb));
    try testing.expectEqualStrings("Documents", try value(s.heading, "text", &vb));
    var prop: t.Property = undefined;
    try ok(c.siv_node_get_property(s.sidebar, try property(s.sidebar, "width"), &prop));
    try testing.expectEqual(t.PropertyGroup.layout, prop.group);
    try testing.expectEqual(t.PropertyType.length, prop.type);
    try testing.expect(prop.flags.set and prop.flags.editable);
    try ok(c.siv_node_get_property(s.content, try property(s.content, "width"), &prop));
    try testing.expect(!prop.flags.set);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_node_get_property(s.sidebar, side.properties, &prop));

    // Editing live: the layout follows, and bad input fails the
    // transaction without changing anything.
    try ok(setProperty(&h, s.sidebar, "width", "160"));
    try h.settle();
    try testing.expectEqual(@as(f32, 160), (try info(s.sidebar)).rect.width);
    try ok(setProperty(&h, s.content, "padding", "4 8"));
    try h.settle();
    const content = try info(s.content);
    try testing.expectEqual(content.rect.x + 8, content.content.x);
    try testing.expectEqual(content.rect.y + 4, content.content.y);
    try testing.expectEqualStrings("4 8", try value(s.content, "padding", &vb));
    // Colors take a token, and read back with what it resolves to there.
    try ok(setProperty(&h, s.heading, "color", "accent"));
    try testing.expect(std.mem.startsWith(u8, try value(s.heading, "color", &vb), "accent #"));
    try testing.expectEqual(t.Result.error_invalid_argument, setProperty(&h, s.heading, "color", "#12345"));
    try testing.expectEqual(t.Result.error_invalid_argument, setProperty(&h, s.sidebar, "width", "wide"));
    try testing.expectEqual(t.Result.error_unsupported, setProperty(&h, s.sidebar, "no-such-property", "1"));
    try h.settle();
    try testing.expectEqual(@as(f32, 160), (try info(s.sidebar)).rect.width);

    // The node at a point is the deepest there, the button's label
    // inside it; the column holding them below them.
    const moved = try info(s.save);
    const at = c.siv_window_get_node_at(h.window, moved.rect.x + moved.rect.width / 2, moved.rect.y + moved.rect.height / 2);
    var cur = at;
    while (cur != .null and cur != s.save) cur = c.siv_node_get_related(cur, .parent);
    try testing.expectEqual(s.save, cur);
    try testing.expectEqual(s.content, c.siv_window_get_node_at(h.window, width - 2, height - 2));
    try testing.expectEqual(t.Node.null, c.siv_window_get_node_at(.null, 1, 1));

    // The counters grow with the frames.
    var before: t.WindowStats = undefined;
    try ok(c.siv_window_get_stats(h.window, &before));
    try testing.expect(before.frames > 0 and before.presented > 0 and before.nodes > 8 and before.tree_changes > 8);
    var t0: u64 = 0;
    try ok(c.siv_window_get_frame_time(h.window, 0, &t0));
    try testing.expect(t0 > 0);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_window_get_frame_time(h.window, @intCast(before.presented), &t0));
    try ok(setProperty(&h, s.heading, "text", "Pictures"));
    try h.settle();
    var after: t.WindowStats = undefined;
    try ok(c.siv_window_get_stats(h.window, &after));
    try testing.expect(after.frames > before.frames and after.presented > before.presented and after.shapes > before.shapes);
    try testing.expectEqual(before.tree_changes, after.tree_changes);
}

const Picks = struct {
    hovered: u32 = 0,
    picked: ?t.Node = null,
    presented: u32 = 0,
    destroyed: bool = false,

    fn hook(ud: ?*anyopaque, _: t.Window, kind: t.InspectEventType, node: t.Node) callconv(.c) void {
        const p: *Picks = @ptrCast(@alignCast(ud.?));
        switch (kind) {
            .hovered => p.hovered += 1,
            .picked => p.picked = node,
            .presented => p.presented += 1,
            else => {},
        }
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const p: *Picks = @ptrCast(@alignCast(ud.?));
        p.destroyed = true;
    }
};

test "inspector: picking by pointing, the overlays, and repaint flashes" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(width, height, null, null);
    defer h.stop();
    var activations: u32 = 0;
    const s = try build(&h, count, &activations);
    const save = try info(s.save);
    const wid = (try h.win()).win.id;

    var picks: Picks = .{};
    try ok(c.siv_window_set_inspect_hook(h.window, Picks.hook, Picks.destroy, &picks));
    try ok(c.siv_window_set_inspect_overlay(h.window, .{ .pick = true }, .null));
    try h.settle();
    try testing.expect(picks.presented > 0);

    // Pointing highlights the node under the pointer; the press picks it
    // and reaches no handler.
    const x = save.rect.x + save.rect.width / 2;
    const y = save.rect.y + save.rect.height / 2;
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 30, .y = 30 } },
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = x, .y = y } },
    });
    try h.settle();
    try testing.expect(picks.hovered >= 2);
    try testing.expectEqual(@as(?t.Node, null), picks.picked);
    try h.click(x, y);
    try h.settle();
    try testing.expectEqual(@as(u32, 0), activations);
    const picked = picks.picked orelse return error.TestUnexpectedResult;
    try testing.expectEqual(c.siv_window_get_node_at(h.window, @floatCast(x), @floatCast(y)), picked);
    // Picking ended: the next click is the application's.
    try h.click(x, y);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), activations);

    // Escape cancels picking, reporting no node.
    try ok(c.siv_window_set_inspect_overlay(h.window, .{ .pick = true }, .null));
    try h.settle();
    try h.typeKey(0xff1b, "", .{});
    try h.settle();
    try testing.expectEqual(@as(?t.Node, .null), picks.picked);
    try h.click(x, y);
    try h.settle();
    try testing.expectEqual(@as(u32, 2), activations);

    // The highlight (border, padding, and content boxes) and every node's
    // bounds, over everything the window draws.
    try ok(c.siv_window_set_inspect_overlay(h.window, .{ .bounds = true }, s.sidebar));
    try h.settle();
    try h.expectGolden("inspector-overlay", width, height);

    // Repaints: the nodes a frame repainted flash, and nothing else.
    try ok(c.siv_window_set_inspect_overlay(h.window, .{ .repaints = true }, .null));
    try h.settle();
    try ok(setProperty(&h, s.heading, "text", "Pictures"));
    try h.settle();
    const flashes = (try h.win()).uiWin().inspect.flashes.items;
    try testing.expect(flashes.len >= 1);
    const heading = try info(s.heading);
    var found = false;
    for (flashes) |r| {
        try testing.expect(r.y1 <= heading.rect.y + heading.rect.height + 1 or r.y0 >= heading.rect.y + heading.rect.height);
        if (r.x0 == heading.rect.x and r.y0 == heading.rect.y) found = true;
    }
    try testing.expect(found);

    // Overlays off: the window looks as it did.
    try ok(c.siv_window_set_inspect_overlay(h.window, .{}, .null));
    try ok(setProperty(&h, s.heading, "text", "Documents"));
    try h.settle();
    try h.expectGolden("inspector-plain", width, height);

    // Another hook replaces this one.
    try ok(c.siv_window_set_inspect_hook(h.window, null, null, null));
    try testing.expect(picks.destroyed);
}

test "inspector: siv's inspector window and its keys" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(width, height, null, null);
    defer h.stop();
    var n: u32 = 0;
    const s = try build(&h, null, &n);
    const self = try h.internal();

    // Off unless the application or SIV_INSPECTOR turns the keys on.
    try h.typeKey('I', "", .{ .ctrl = true, .shift = true });
    try h.settle();
    try testing.expectEqual(@as(u64, 0), self.inspector.window);
    self.inspector.keys = true;

    // Ctrl+Shift+D opens it on the node under the pointer.
    const save = try info(s.save);
    const wid = (try h.win()).win.id;
    try h.inject(&.{.{ .pointer_motion = .{ .window = wid, .seat = 0, .x = save.rect.x + 4, .y = save.rect.y + save.rect.height / 2 } }});
    try h.typeKey('D', "", .{ .ctrl = true, .shift = true });
    try h.settle();
    const iw: t.Window = @fromBackingInt(self.inspector.window);
    try testing.expect(iw != .null);
    const tw = try h.win();
    const at = c.siv_window_get_node_at(h.window, save.rect.x + 4, save.rect.y + save.rect.height / 2);
    try testing.expectEqual(@backingInt(at), tw.nodes.handle(tw.uiWin().inspect.highlight));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_inspector_open(iw, .null));

    // Selecting the button shows its properties and highlights it.
    try ok(c.siv_inspector_open(h.window, s.save));
    try h.settle();
    try testing.expectEqual(iw, @as(t.Window, @fromBackingInt(self.inspector.window)));
    try h.expectGoldenOf(iw, "inspector-properties", 960, 640);
    try h.expectGolden("inspector-highlight", width, height);

    // Typing in a property's field edits the node live.
    try h.clickIn(iw, width_field_x, width_field_y);
    try h.typeKeyIn(iw, 'a', "", .{ .ctrl = true });
    for ("96") |ch| try h.typeKeyIn(iw, ch, &.{ch}, .{});
    try h.settle();
    try testing.expectEqual(@as(f32, 96), (try info(s.save)).rect.width);
    var vb: [32]u8 = undefined;
    try testing.expectEqualStrings("96", try value(s.save, "width", &vb));

    // A node in the dark sidebar, on the Theme tab: its colors are the
    // subtree theme's.
    try ok(c.siv_inspector_open(h.window, s.sidebar));
    try h.settle();
    try h.clickIn(iw, theme_tab_x, theme_tab_y);
    try h.settle();
    try h.expectGoldenOf(iw, "inspector-theme", 960, 640);

    // The toolbar: Bounds turns the overlay on in the inspected window;
    // Pick, then a click there, selects what was clicked.
    const ui_win = (try h.win()).uiWin();
    try h.clickIn(iw, bounds_x, toolbar_y);
    try h.settle();
    try testing.expect(ui_win.inspect.overlay.bounds);
    try h.clickIn(iw, pick_x, toolbar_y);
    try h.settle();
    try testing.expect(ui_win.inspect.overlay.pick);
    const heading = try info(s.heading);
    try h.click(heading.rect.x + 4, heading.rect.y + heading.rect.height / 2);
    try h.settle();
    try testing.expect(!ui_win.inspect.overlay.pick and ui_win.inspect.overlay.bounds);
    try testing.expectEqual(@backingInt(s.heading), (try h.win()).nodes.handle(ui_win.inspect.highlight));
    // The counters are this window's, not the inspector's beside it.
    var stats: t.WindowStats = undefined;
    try ok(c.siv_window_get_stats(h.window, &stats));
    try testing.expect(stats.commits > 0 and stats.commits <= stats.frames);

    // The inspector closes with the window it inspects.
    A.siv_window_destroy(h.window);
    h.window = .null;
    try h.settle();
    try testing.expectEqual(@as(u64, 0), self.inspector.window);
    try testing.expect(A.App.window(@backingInt(iw), A.window_tag) == error.InvalidHandle or (try A.App.window(@backingInt(iw), A.window_tag)).dead);
}

/// Where the inspector window shows the Theme tab and, for the Save
/// button, the width property's field (inspector-properties.png).
const theme_tab_x = 465;
const theme_tab_y = 66;
const width_field_x = 740;
const toolbar_y = 21;
const pick_x = 33;
const bounds_x = 100;
const width_field_y = 298;

test "inspector: SIV_APP_INSPECTOR turns the keys on" {
    var app: t.App = .null;
    try ok(A.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true, .no_system_icons = true, .inspector = true } }, &app));
    defer _ = A.siv_app_destroy(app);
    try testing.expect((try A.App.get(@backingInt(app))).inspector.keys);
}
