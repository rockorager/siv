//! The date, time, color, font, and emoji pickers (D41) through the C ABI
//! on the headless backend: their locales (D21), keys, semantics, values,
//! and compact forms in popovers.
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

/// A subset of Noto Color Emoji (OFL, test/golden/fonts/README.md): the
/// emoji the goldens show.
const emoji_font = @embedFile("../golden/fonts/NotoColorEmoji-subset.ttf");
const roboto = @embedFile("../golden/fonts/Roboto-Regular.ttf");

const ks = struct {
    const space: u32 = 0x20;
    const tab: u32 = 0xff09;
    const @"return": u32 = 0xff0d;
    const escape: u32 = 0xff1b;
    const home: u32 = 0xff50;
    const left: u32 = 0xff51;
    const up: u32 = 0xff52;
    const right: u32 = 0xff53;
    const down: u32 = 0xff54;
    const page_up: u32 = 0xff55;
    const page_down: u32 = 0xff56;
    const end: u32 = 0xff57;
};

const Log = struct {
    changes: u32 = 0,
    value: f64 = 0,
    index: u32 = 0,
    activates: u32 = 0,

    fn onChange(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.changes += 1;
        log.value = ev.value;
        log.index = ev.index;
        return .handled;
    }

    fn onActivate(ud: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.activates += 1;
        return .handled;
    }
};

fn begin(window: t.Window) !t.Txn {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(window, &txn));
    return txn;
}

fn root(h: *Harness) t.Node {
    return c.siv_window_get_root(h.window);
}

/// A padded column on the window's background to put a picker in.
fn column(txn: t.Txn, h: *Harness) t.Node {
    _ = c.siv_set_visual(txn, root(h), &.{ .background_token = .window_bg });
    const col = c.siv_flex(txn, root(h), &.{ .axis = .column, .align_items = .start });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 12, .end = 12, .top = 12, .bottom = 12 } });
    return col;
}

fn tree(window: t.Window) !*const ui.semantics.Tree {
    const w = try A.App.window(@backingInt(window), A.window_tag);
    return w.uiWin().semanticsTree();
}

fn sem(n: t.Node) !ui.semantics.Node {
    const w, const id = try abi.tree.lookup(n);
    const tr = try w.uiWin().semanticsTree();
    for (tr.nodes.items) |s| if (s.node == id) return s;
    return error.NotInSemanticsTree;
}

/// The focused node's role and name.
fn expectFocused(window: t.Window, role: ui.Role, name: []const u8) !void {
    const tr = try tree(window);
    const f = tr.focused() orelse return error.NothingFocused;
    try testing.expectEqualStrings(name, tr.name(f.*));
    try testing.expectEqual(role, f.role);
}

fn value(node: t.Node) !f64 {
    var v: f64 = 0;
    try ok(c.siv_widget_get_value(node, &v));
    return v;
}

fn setLanguage(h: *Harness, lang: []const u8) !void {
    try ok(c.siv_app_set_language(h.app, lang.ptr, lang.len, .inherit));
    try h.settle();
}

fn center(n: t.Node) ![2]f64 {
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(n, &r));
    return .{ r.x + r.width / 2, r.y + r.height / 2 };
}

fn openPopup(h: *Harness) !?t.Window {
    const self = try h.internal();
    var found: ?t.Window = null;
    for (self.windows.items) |slot| if (slot) |w| {
        if (!w.dead and w.parent != null and w.win.shown) found = @fromBackingInt(w.handle);
    };
    return found;
}

fn formatDate(h: *Harness, days: i32, style: t.DateStyle, buf: []u8) ![]const u8 {
    var len: usize = 0;
    try ok(c.siv_app_format_date(h.app, days, style, buf.ptr, buf.len, &len));
    return buf[0..len];
}

// 1999-03-15, a Monday: far from any day the tests run on, so no day
// shows as today.
const mar15: i32 = 10665;

test "date picker: a locale's calendar, mirrored in RTL; arrows, pages, and Enter choose" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(290, 290, null, null);
    defer h.stop();
    var log: Log = .{};
    var txn = try begin(h.window);
    const picker = c.siv_date_picker(txn, column(txn, &h), &.{ .label = "Due date", .label_len = 8 });
    c.siv_widget_set_value(txn, picker, mar15);
    _ = c.siv_on(txn, picker, .change, Log.onChange, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(@as(f64, mar15), try value(picker));
    try h.expectGolden("date-picker", 290, 290);

    // WAI-ARIA's date grid: a table named by its month, weekday column
    // headers from Sunday (en-US), cells named by their full date, one
    // Tab stop at the selected day.
    const tr = try tree(h.window);
    try testing.expect(tr.find(.table, "March 1999") != null);
    try testing.expect(tr.find(.heading, "March 1999") != null);
    try testing.expect(tr.find(.column_header, "Sunday") != null);
    const cell = tr.find(.cell, "Monday, March 15, 1999").?;
    try testing.expectEqual(ui.Toggle.on, cell.selected);
    try testing.expect(cell.focusable);
    try testing.expect(!tr.find(.cell, "Tuesday, March 16, 1999").?.focusable);
    try testing.expect(tr.find(.button, "Previous month") != null);
    try testing.expect(tr.find(.group, "Due date") != null);

    try ok(c.siv_node_focus(picker));
    try h.settle();
    try expectFocused(h.window, .cell, "Monday, March 15, 1999");
    try h.typeKey(ks.right, "", .{});
    try h.settle();
    try expectFocused(h.window, .cell, "Tuesday, March 16, 1999");
    // Moving the cursor is not choosing.
    try testing.expectEqual(@as(u32, 0), log.changes);
    try h.typeKey(ks.page_down, "", .{});
    try h.settle();
    try expectFocused(h.window, .cell, "Friday, April 16, 1999");
    try testing.expect((try tree(h.window)).find(.table, "April 1999") != null);
    try h.typeKey(ks.page_up, "", .{ .shift = true });
    try h.settle();
    try expectFocused(h.window, .cell, "Thursday, April 16, 1998");
    try h.typeKey(ks.home, "", .{});
    try h.settle();
    try expectFocused(h.window, .cell, "Sunday, April 12, 1998");
    try h.typeKey(ks.@"return", "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.changes);
    try testing.expectEqual(@as(f64, 10328), log.value);
    try testing.expectEqual(@as(f64, 10328), try value(picker));

    // A range keeps the cursor inside it and disables the days outside.
    txn = try begin(h.window);
    c.siv_widget_set_value(txn, picker, mar15);
    c.siv_widget_set_range(txn, picker, 10660, 10670, 0);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_focus(picker));
    try h.typeKey(ks.page_down, "", .{});
    try h.settle();
    try expectFocused(h.window, .cell, "Saturday, March 20, 1999");
    try testing.expect((try tree(h.window)).find(.cell, "Monday, March 22, 1999").?.disabled);
    txn = try begin(h.window);
    c.siv_widget_set_range(txn, picker, -1e9, 1e9, 0);
    c.siv_widget_set_value(txn, picker, mar15);
    try ok(c.siv_txn_commit(txn));

    // German: weeks start on Monday, names and patterns are German.
    try setLanguage(&h, "de");
    try h.expectGolden("date-picker-de", 290, 290);
    const de = try tree(h.window);
    try testing.expect(de.find(.table, "März 1999") != null);
    try testing.expect(de.find(.cell, "Montag, 15. März 1999") != null);
    try ok(c.siv_node_focus(picker));
    try h.typeKey(ks.right, "", .{});
    try h.typeKey(ks.home, "", .{});
    try h.settle();
    try expectFocused(h.window, .cell, "Montag, 15. März 1999");

    // Egyptian Arabic: right to left, weeks from Saturday, Arabic-Indic
    // digits; Left moves forward in time.
    try setLanguage(&h, "ar-EG");
    try h.expectGolden("date-picker-ar", 290, 290);
    try testing.expect((try tree(h.window)).find(.column_header, "السبت") != null);
    try ok(c.siv_node_focus(picker));
    try h.typeKey(ks.left, "", .{});
    try h.settle();
    try expectFocused(h.window, .cell, "الثلاثاء، ١٦ مارس ١٩٩٩");
}

test "time picker: the locale's clock; fields step, type, and read as their text" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(200, 60, null, null);
    defer h.stop();
    var log: Log = .{};
    var txn = try begin(h.window);
    const picker = c.siv_time_picker(txn, column(txn, &h), &.{ .label = "Alarm", .label_len = 5 });
    c.siv_widget_set_value(txn, picker, 22 * 3600 + 30 * 60);
    _ = c.siv_on(txn, picker, .change, Log.onChange, null, &log);
    _ = c.siv_on(txn, picker, .activate, Log.onActivate, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.expectGolden("time-picker", 200, 60);

    // Spin buttons in the pattern's order; the period reads as its text.
    const tr = try tree(h.window);
    try testing.expect(tr.find(.group, "Alarm") != null);
    const hour = tr.find(.spin_button, "Hour").?;
    try testing.expectEqual(@as(f64, 10), hour.value.?.now);
    try testing.expectEqual(@as(f64, 12), hour.value.?.max);
    try testing.expectEqualStrings("PM", tr.find(.spin_button, "AM/PM").?.value_label);
    try testing.expect(tr.find(.spin_button, "Hour").?.bounds.x0 < tr.find(.spin_button, "Minutes").?.bounds.x0);

    try ok(c.siv_node_focus(picker));
    try h.typeKey(ks.up, "", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 23 * 3600 + 30 * 60), log.value);
    // Up wraps the hour past midnight without changing the minutes.
    try h.typeKey(ks.up, "", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 30 * 60), try value(picker));
    // Typing "7" is a whole hour (no 70): it sets 7 AM and moves on.
    try h.typeKey('7', "7", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 7 * 3600 + 30 * 60), try value(picker));
    try expectFocused(h.window, .spin_button, "Minutes");
    try h.typeKey('4', "4", .{});
    try h.typeKey('5', "5", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 7 * 3600 + 45 * 60), try value(picker));
    try expectFocused(h.window, .spin_button, "AM/PM");
    try h.typeKey('p', "p", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 19 * 3600 + 45 * 60), try value(picker));
    try h.typeKey(ks.left, "", .{});
    try h.settle();
    try expectFocused(h.window, .spin_button, "Minutes");
    try h.typeKey(ks.@"return", "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.activates);

    // German counts 24 hours: no period field.
    try setLanguage(&h, "de");
    try h.expectGolden("time-picker-de", 200, 60);
    try testing.expect((try tree(h.window)).find(.spin_button, "AM/PM") == null);
    try testing.expectEqual(@as(f64, 19), (try tree(h.window)).find(.spin_button, "Hour").?.value.?.now);

    // Egyptian Arabic: the numbers in Arabic-Indic digits read left to
    // right, the period on the left of a right-to-left row; Left from
    // the hour reaches it, as the screen has them.
    try setLanguage(&h, "ar-EG");
    try h.expectGolden("time-picker-ar", 200, 60);
    const ar = try tree(h.window);
    try testing.expectEqualStrings("م", ar.find(.spin_button, "AM/PM").?.value_label);
    try testing.expectEqualStrings("٧", ar.find(.spin_button, "Hour").?.value_label);
    try testing.expect(ar.find(.spin_button, "AM/PM").?.bounds.x0 < ar.find(.spin_button, "Hour").?.bounds.x0);
    try ok(c.siv_node_focus(picker));
    try h.typeKey(ks.left, "", .{});
    try h.settle();
    try expectFocused(h.window, .spin_button, "AM/PM");
    // Arabic-Indic digits type too.
    try h.typeKey(ks.right, "", .{});
    try h.typeKey(0, "٩", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 21 * 3600 + 45 * 60), try value(picker));
    txn = try begin(h.window);
    c.siv_widget_set_value(txn, picker, 86400 + 60);
    try ok(c.siv_txn_commit(txn));
    try testing.expectEqual(@as(f64, 60), try value(picker));
}

fn colorOf(node: t.Node) !t.Color {
    var col: t.Color = .{};
    try ok(c.siv_color_chooser_get_color(node, &col));
    return col;
}

test "color chooser: an HSV area and strips as sliders, a hex field, and the screen picker" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(310, 300, null, null);
    defer h.stop();
    var log: Log = .{};
    var txn = try begin(h.window);
    const chooser = c.siv_color_chooser(txn, column(txn, &h), &.{
        .label = "Accent",
        .label_len = 6,
        .color = .{ .r = 0.2, .g = 0.4, .b = 0.8, .a = 1 },
        .flags = .{ .alpha = true },
    });
    _ = c.siv_on(txn, chooser, .change, Log.onChange, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.expectGolden("color-chooser", 310, 300);
    // No widget value: a color is four numbers.
    var v: f64 = 0;
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_widget_get_value(chooser, &v));
    const col = try colorOf(chooser);
    try testing.expectApproxEqAbs(@as(f32, 0.4), col.g, 1e-5);

    // #3366CC is hue 220°, saturation 75%, brightness 80%.
    const tr = try tree(h.window);
    const hue = tr.find(.slider, "Hue").?;
    try testing.expectEqualStrings("220°", hue.value_label);
    try testing.expectEqual(@as(f64, 360), hue.value.?.max);
    try testing.expectEqualStrings("saturation 75%, brightness 80%", tr.find(.slider, "Saturation and brightness").?.value_label);
    try testing.expectEqualStrings("100%", tr.find(.slider, "Opacity").?.value_label);
    try testing.expect(tr.find(.image, "Color #3366CCFF") != null);

    // The area takes the focus first; Right adds saturation, Up value.
    try ok(c.siv_node_focus(chooser));
    try h.typeKey(ks.right, "", .{ .shift = true });
    try h.typeKey(ks.up, "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 2), log.changes);
    try testing.expectEqualStrings("saturation 85%, brightness 81%", (try tree(h.window)).find(.slider, "Saturation and brightness").?.value_label);
    // Tab to the hue: End is the last whole degree, 359°.
    try h.typeKey(ks.tab, "", .{});
    try h.typeKey(ks.end, "", .{});
    try h.settle();
    try testing.expectEqualStrings("359°", (try tree(h.window)).find(.slider, "Hue").?.value_label);
    // Through black and back, the hue stays.
    txn = try begin(h.window);
    c.siv_color_chooser_set_color(txn, chooser, .{ .r = 0, .g = 0, .b = 0, .a = 1 });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqualStrings("359°", (try tree(h.window)).find(.slider, "Hue").?.value_label);
    try testing.expectEqual(@as(u32, 3), log.changes);

    // Typing a whole hex color takes it, alpha included.
    const tr2 = try tree(h.window);
    const hex = tr2.find(.text_input, "Hexadecimal").?;
    try h.click((hex.bounds.x0 + hex.bounds.x1) / 2, (hex.bounds.y0 + hex.bounds.y1) / 2);
    try h.typeKey('a', "", .{ .ctrl = true });
    for ("#ff800080") |ch| try h.typeKey(ch, &.{ch}, .{});
    try h.settle();
    const typed = try colorOf(chooser);
    try testing.expectEqual(@as(f32, 1), typed.r);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), typed.g, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), typed.a, 1e-5);
    try testing.expectEqualStrings("30°", (try tree(h.window)).find(.slider, "Hue").?.value_label);

    // No portal on the headless backend: the button disables itself.
    const pick = (try tree(h.window)).find(.button, "Pick from Screen").?;
    try testing.expect(!pick.disabled);
    try h.click((pick.bounds.x0 + pick.bounds.x1) / 2, (pick.bounds.y0 + pick.bounds.y1) / 2);
    try h.settle();
    try testing.expect((try tree(h.window)).find(.button, "Pick from Screen").?.disabled);

    // Right to left: the row mirrors, the area and strips do not.
    try setLanguage(&h, "he");
    try h.expectGolden("color-chooser-rtl", 310, 300);
}

test "font chooser: installed families in their own faces, searched; the value is a family id" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(330, 330, null, null);
    defer h.stop();
    try ok(c.siv_app_add_font(h.app, "Roboto", 6, roboto.ptr, roboto.len));
    var count: u32 = 0;
    try ok(c.siv_app_get_font_family_count(h.app, &count));
    try testing.expectEqual(@as(u32, 2), count);
    var id: u32 = 0;
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_app_get_font_family_at(h.app, 1, &id));
    try ok(c.siv_app_get_font_family_name(h.app, id, &buf, buf.len, &len));
    try testing.expectEqualStrings("Roboto", buf[0..len]);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_get_font_family_at(h.app, 2, &id));
    var roboto_id: u32 = 0;
    try ok(c.siv_app_get_font_family(h.app, "Roboto", 6, &roboto_id));

    var log: Log = .{};
    var txn = try begin(h.window);
    const chooser = c.siv_font_chooser(txn, column(txn, &h), &.{ .label = "Body font", .label_len = 9, .preview = "Sphinx of black quartz", .preview_len = 22 });
    _ = c.siv_on(txn, chooser, .change, Log.onChange, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(@as(f64, 0), try value(chooser));
    const tr = try tree(h.window);
    try testing.expect(tr.find(.list_item, "Droid") != null);
    try testing.expect(tr.find(.list_item, "Roboto") != null);

    // Search, Down to the list, Space chooses.
    try ok(c.siv_node_focus(chooser));
    for ("rob") |ch| try h.typeKey(ch, &.{ch}, .{});
    try h.settle();
    try testing.expect((try tree(h.window)).find(.list_item, "Droid") == null);
    try h.typeKey(ks.down, "", .{});
    try h.settle();
    try expectFocused(h.window, .list_item, "Roboto");
    try h.typeKey(ks.space, " ", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.changes);
    try testing.expectEqual(@as(f64, @floatFromInt(roboto_id)), log.value);
    try testing.expectEqual(@as(f64, @floatFromInt(roboto_id)), try value(chooser));
    try testing.expect((try tree(h.window)).find(.label, "Preview: Roboto") != null);
    // Clearing the search shows every family, the chosen one selected.
    try h.typeKey(ks.tab, "", .{ .shift = true });
    try h.typeKey('a', "", .{ .ctrl = true });
    try h.typeKey(0xff08, "", .{});
    try h.settle();
    try testing.expectEqual(ui.Toggle.on, (try tree(h.window)).find(.list_item, "Roboto").?.selected);
    try h.expectGolden("font-chooser", 330, 330);
    // Not a family: refused.
    txn = try begin(h.window);
    c.siv_widget_set_value(txn, chooser, 99999);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
}

test "emoji catalogue: groups, tones, names, and search" {
    const count = c.siv_emoji_get_count();
    try testing.expect(count > 1800);
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_emoji_get(0, .none, &buf, buf.len, &len));
    try testing.expectEqualStrings("😀", buf[0..len]);
    try ok(c.siv_emoji_get_name(0, .dark, &buf, buf.len, &len));
    try testing.expectEqualStrings("grinning face", buf[0..len]);
    var found = false;
    var index: u32 = 0;
    try ok(c.siv_emoji_find("thumbs up", 9, 0, &found, &index));
    try testing.expect(found);
    var info: t.EmojiInfo = undefined;
    try ok(c.siv_emoji_get_info(index, &info));
    try testing.expectEqual(t.EmojiGroup.people_body, info.group);
    try testing.expect(info.flags.skin_tones);
    try ok(c.siv_emoji_get(index, .medium, &buf, buf.len, &len));
    try testing.expectEqualStrings("👍🏽", buf[0..len]);
    try ok(c.siv_emoji_get_name(index, .medium, &buf, buf.len, &len));
    try testing.expectEqualStrings("thumbs up: medium skin tone", buf[0..len]);
    // Words start words of the name, in any case.
    try ok(c.siv_emoji_find("SMIL cat", 8, 0, &found, &index));
    try ok(c.siv_emoji_get_name(index, .none, &buf, buf.len, &len));
    try testing.expectEqualStrings("grinning cat with smiling eyes", buf[0..len]);
    try ok(c.siv_emoji_find("", 0, 0, &found, &index));
    try testing.expect(!found);
    try testing.expectEqual(count, index);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_emoji_get(count, .none, &buf, buf.len, &len));
}

test "emoji chooser: group tabs, a grid of named emoji, search, and skin tones" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(360, 390, null, null);
    defer h.stop();
    try ok(c.siv_app_add_font(h.app, "Droid", 5, emoji_font.ptr, emoji_font.len));
    var log: Log = .{};
    var txn = try begin(h.window);
    const first = column(txn, &h);
    const chooser = c.siv_emoji_chooser(txn, first, &.{ .label = "Reaction", .label_len = 8 });
    _ = c.siv_on(txn, chooser, .change, Log.onChange, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(@as(f64, -1), try value(chooser));
    try h.expectGolden("emoji-chooser", 360, 390);
    const tr = try tree(h.window);
    try testing.expect(tr.find(.tab_list, "Categories") != null);
    try testing.expectEqual(ui.Toggle.on, tr.find(.tab, "Smileys & Emotion").?.selected);
    try testing.expect(tr.find(.list, "Smileys & Emotion") != null);
    try testing.expect(tr.find(.list_item, "grinning face") != null);
    try testing.expect(tr.find(.combo_box, "Skin tone") != null);

    // Down from the search to the grid; Right and Enter choose.
    try ok(c.siv_node_focus(chooser));
    try h.typeKey(ks.down, "", .{});
    try h.settle();
    try expectFocused(h.window, .list_item, "grinning face");
    try h.typeKey(ks.right, "", .{});
    try h.typeKey(ks.@"return", "", .{});
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.changes);
    try testing.expectEqual(@as(f64, 1), log.value);
    try testing.expectEqual(@as(u32, 0), log.index);
    try testing.expectEqual(@as(f64, 1), try value(chooser));

    // The tabs: one Tab stop, arrows select the next group.
    const smileys = (try tree(h.window)).find(.tab, "Smileys & Emotion").?;
    try h.click((smileys.bounds.x0 + smileys.bounds.x1) / 2, (smileys.bounds.y0 + smileys.bounds.y1) / 2);
    try h.typeKey(ks.right, "", .{});
    try h.settle();
    try expectFocused(h.window, .tab, "People & Body");
    try testing.expectEqual(ui.Toggle.on, (try tree(h.window)).find(.tab, "People & Body").?.selected);
    try testing.expect((try tree(h.window)).find(.list_item, "waving hand") != null);

    // A skin tone applies to the emoji that take one, and to their names.
    var found = false;
    var wave: u32 = 0;
    try ok(c.siv_emoji_find("waving hand", 11, 0, &found, &wave));
    txn = try begin(h.window);
    c.siv_remove(txn, first);
    const toned = c.siv_emoji_chooser(txn, column(txn, &h), &.{ .label = "Toned", .label_len = 5, .tone = .medium });
    c.siv_widget_set_value(txn, toned, @floatFromInt(wave));
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(ui.Toggle.on, (try tree(h.window)).find(.list_item, "waving hand: medium skin tone").?.selected);
    try h.expectGolden("emoji-chooser-tones", 360, 390);

    // Search: words start words of names.
    _ = c.siv_node_focus(toned);
    for ("cat") |ch| try h.typeKey(ch, &.{ch}, .{});
    try h.settle();
    const found_tree = try tree(h.window);
    try testing.expect(found_tree.find(.list, "Search results") != null);
    try testing.expect(found_tree.find(.list_item, "grinning cat") != null);
    try testing.expect(found_tree.find(.list_item, "grinning face") == null);
    try testing.expectEqual(ui.Toggle.off, found_tree.find(.tab, "People & Body").?.selected);

    // Hebrew: the tab row mirrors, and Left moves to the next group.
    try setLanguage(&h, "he");
    const smileys2 = (try tree(h.window)).find(.tab, "Smileys & Emotion").?;
    try h.click((smileys2.bounds.x0 + smileys2.bounds.x1) / 2, (smileys2.bounds.y0 + smileys2.bounds.y1) / 2);
    try h.settle();
    try h.typeKey(ks.left, "", .{});
    try h.settle();
    try expectFocused(h.window, .tab, "People & Body");
    const he = try tree(h.window);
    try testing.expect(he.find(.tab, "People & Body").?.bounds.x0 < he.find(.tab, "Smileys & Emotion").?.bounds.x0);
    try h.expectGolden("emoji-chooser-rtl", 360, 390);
}

test "compact pickers: a button with the value opens the picker in a popover" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(320, 120, null, null);
    defer h.stop();
    try ok(c.siv_app_add_font(h.app, "Droid", 5, emoji_font.ptr, emoji_font.len));
    var log: Log = .{};
    var txn = try begin(h.window);
    const col = c.siv_flex(txn, column(txn, &h), &.{ .axis = .column, .gap = 8 });
    const row = c.siv_flex(txn, col, &.{ .axis = .row, .gap = 8 });
    const date = c.siv_date_picker(txn, row, &.{ .label = "Due date", .label_len = 8, .flags = .{ .compact = true } });
    c.siv_widget_set_value(txn, date, mar15);
    _ = c.siv_on(txn, date, .change, Log.onChange, null, &log);
    const time = c.siv_time_picker(txn, row, &.{ .label = "Alarm", .label_len = 5, .flags = .{ .compact = true } });
    c.siv_widget_set_value(txn, time, 9 * 3600 + 5 * 60);
    const row2 = c.siv_flex(txn, col, &.{ .axis = .row, .gap = 8 });
    const color = c.siv_color_chooser(txn, row2, &.{ .label = "Accent", .label_len = 6, .color = .{ .r = 0.2, .g = 0.4, .b = 0.8, .a = 1 }, .flags = .{ .compact = true } });
    const font = c.siv_font_chooser(txn, row2, &.{ .label = "Body font", .label_len = 9, .flags = .{ .compact = true } });
    const emoji = c.siv_emoji_chooser(txn, row2, &.{ .label = "Reaction", .label_len = 8, .flags = .{ .compact = true } });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.expectGolden("pickers-compact", 320, 120);
    // Buttons named by their label and value.
    const tr = try tree(h.window);
    try testing.expectEqual(ui.Toggle.off, tr.find(.button, "Due date, Mar 15, 1999").?.expanded);
    try testing.expect(tr.find(.button, "Alarm, 9:05\u{202f}AM") != null);
    try testing.expect(tr.find(.button, "Accent, #3366CC") != null);
    try testing.expect(tr.find(.button, "Body font, Droid") != null);
    try testing.expect(tr.find(.button, "Reaction") != null);
    try testing.expectEqual(@as(f64, mar15), try value(date));

    // The date: a click opens the calendar with the focus on the value;
    // choosing a day closes it, reports it on the button, and returns
    // the focus.
    const dc = try center(date);
    try h.click(dc[0], dc[1]);
    try h.settle();
    const popup = (try openPopup(&h)) orelse return error.NoPopup;
    try testing.expectEqual(ui.Toggle.on, (try sem(date)).expanded);
    try expectFocused(popup, .cell, "Monday, March 15, 1999");
    var size: t.Size = undefined;
    try ok(c.siv_window_get_size(popup, &size));
    try h.expectGoldenOf(popup, "date-picker-popover", @intFromFloat(size.width), @intFromFloat(size.height));
    try h.typeKeyIn(popup, ks.right, "", .{});
    try h.typeKeyIn(popup, ks.@"return", "", .{});
    try h.settle();
    try testing.expect((try openPopup(&h)) == null);
    try testing.expectEqual(@as(u32, 1), log.changes);
    try testing.expectEqual(@as(f64, mar15 + 1), log.value);
    try testing.expectEqual(@as(f64, mar15 + 1), try value(date));
    try expectFocused(h.window, .button, "Due date, Mar 16, 1999");
    // Down opens it too, Escape closes it unchosen.
    try h.typeKey(ks.down, "", .{});
    try h.settle();
    try testing.expect((try openPopup(&h)) != null);
    try h.typeKeyIn((try openPopup(&h)).?, ks.escape, "", .{});
    try h.settle();
    try testing.expect((try openPopup(&h)) == null);
    try testing.expectEqual(@as(u32, 1), log.changes);
    try expectFocused(h.window, .button, "Due date, Mar 16, 1999");

    // The color: get and set go through the button.
    txn = try begin(h.window);
    c.siv_color_chooser_set_color(txn, color, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(@as(f32, 1), (try colorOf(color)).r);
    try testing.expect((try tree(h.window)).find(.button, "Accent, #FF0000") != null);
    const cc = try center(color);
    try h.click(cc[0], cc[1]);
    try h.settle();
    const cp = (try openPopup(&h)).?;
    try testing.expectEqualStrings("0°", (try tree(cp)).find(.slider, "Hue").?.value_label);
    try h.typeKeyIn(cp, ks.escape, "", .{});
    try h.settle();

    // The emoji: choosing one closes the popover; the button shows it.
    const ec = try center(emoji);
    try h.click(ec[0], ec[1]);
    try h.settle();
    const ep = (try openPopup(&h)).?;
    try h.typeKeyIn(ep, ks.down, "", .{});
    try h.typeKeyIn(ep, ks.space, " ", .{});
    try h.settle();
    try testing.expect((try openPopup(&h)) == null);
    try testing.expectEqual(@as(f64, 0), try value(emoji));
    try testing.expect((try tree(h.window)).find(.button, "Reaction, 😀") != null);

    // The time: changes show on the button at once; Enter closes.
    const tc = try center(time);
    try h.click(tc[0], tc[1]);
    try h.settle();
    const tp = (try openPopup(&h)).?;
    try expectFocused(tp, .spin_button, "Hour");
    try h.typeKeyIn(tp, ks.up, "", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 10 * 3600 + 5 * 60), try value(time));
    try testing.expect((try openPopup(&h)) != null);
    try h.typeKeyIn(tp, ks.@"return", "", .{});
    try h.settle();
    try testing.expect((try openPopup(&h)) == null);
    try testing.expect((try tree(h.window)).find(.button, "Alarm, 10:05\u{202f}AM") != null);

    // The font: the list in the popover, the search field focused.
    const fc = try center(font);
    try h.click(fc[0], fc[1]);
    try h.settle();
    const fp = (try openPopup(&h)).?;
    try expectFocused(fp, .text_input, "Search fonts");
    try testing.expect((try tree(fp)).find(.list_item, "Droid") != null);
    try h.typeKeyIn(fp, ks.escape, "", .{});
    try h.settle();
    try testing.expect((try openPopup(&h)) == null);

    // The language changes what the buttons show.
    try setLanguage(&h, "de");
    try testing.expect((try tree(h.window)).find(.button, "Due date, 16.03.1999") != null);
    try testing.expect((try tree(h.window)).find(.button, "Alarm, 10:05") != null);
}
