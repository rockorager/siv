//! Variants through the C ABI (D39): a window whose sidebar goes and
//! whose header stacks when it is narrow, from one tree, without a
//! resize handler (test/golden/abi/adaptive-wide.png and
//! adaptive-narrow.png), and the calls' errors.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const Harness = harness.Harness;
const ok = harness.ok;

fn rect(n: t.Node) !t.Rect {
    var r: t.Rect = .{};
    try ok(c.siv_node_get_rect(n, &r));
    return r;
}

const Ui = struct { sidebar: t.Node, content: t.Node, title: t.Node, buttons: t.Node, save: t.Node };

fn build(h: *Harness) !Ui {
    const root = c.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const narrow: t.ConditionDesc = .{ .max_width = 480 };
    const col = c.siv_flex(txn, root, &.{ .axis = .column });

    // A header whose title and buttons share a row while they fit, and
    // stack when they do not: no width written down.
    const header = c.siv_flex(txn, col, &.{ .gap = 8, .align_items = .center, .justify = .space_between });
    c.siv_set_layout(txn, header, &.{ .padding = .{ .start = 12, .end = 12, .top = 8, .bottom = 8 } });
    c.siv_set_flex_when(txn, header, &.{ .flags = .{ .overflow = true } }, &.{ .axis = .column, .gap = 8, .align_items = .start });
    const title = c.siv_text(txn, header, "Adaptive layout", 15);
    c.siv_set_text_style(txn, title, &.{ .size_role = .heading, .weight = .bold });
    const buttons = c.siv_flex(txn, header, &.{ .gap = 6 });
    _ = c.siv_push_button(txn, buttons, &.{ .label = "New", .label_len = 3 });
    _ = c.siv_push_button(txn, buttons, &.{ .label = "Open", .label_len = 4 });
    const save = c.siv_push_button(txn, buttons, &.{ .label = "Save", .label_len = 4, .style = .primary });
    // Wider in a narrow window; the button's own padding stays (its
    // default layout). Its parent offers it only the row's max-content
    // width, so the condition is on the window.
    c.siv_set_layout_when(txn, save, &.{ .max_width = 480, .flags = .{ .window = true } }, &.{ .width = .{ .unit = .px, .value = 90 } });

    const main = c.siv_flex(txn, col, null);
    c.siv_set_layout(txn, main, &.{ .grow = 1 });
    // The sidebar goes when the row it is in is narrow.
    const sidebar = c.siv_box(txn, main);
    c.siv_set_layout(txn, sidebar, &.{ .width = .{ .unit = .px, .value = 160 }, .padding = .{ .start = 12, .top = 12 } });
    c.siv_set_visual(txn, sidebar, &.{ .background_token = .sidebar_bg });
    c.siv_set_hidden_when(txn, sidebar, &narrow, true);
    _ = c.siv_text(txn, sidebar, "Sidebar", 7);
    const content = c.siv_box(txn, main);
    c.siv_set_layout(txn, content, &.{ .grow = 1, .padding = .{ .start = 12, .top = 12 } });
    _ = c.siv_text(txn, content, "Content", 7);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    return .{ .sidebar = sidebar, .content = content, .title = title, .buttons = buttons, .save = save };
}

test "variants: a sidebar goes and a header stacks on a narrow window, and come back, from one tree" {
    var h: Harness = .{};
    try h.start(640, 240, null, null);
    defer h.stop();
    const u = try build(&h);
    const wide_save = try rect(u.save);
    try testing.expectEqual(@as(f32, 160), (try rect(u.content)).x);
    // Title and buttons on one row.
    try testing.expect((try rect(u.buttons)).y < (try rect(u.title)).y + (try rect(u.title)).height);
    try h.expectGolden("adaptive-wide", 640, 240);

    try ok(c.siv_test_resize(h.window, 320, 240));
    try h.settle();
    const content = try rect(u.content);
    try testing.expectEqual(@as(f32, 0), content.x);
    try testing.expectEqual(@as(f32, 320), content.width);
    // Hidden by its variant, not by siv_set_hidden.
    var hidden = true;
    try ok(c.siv_node_is_hidden(u.sidebar, &hidden));
    try testing.expect(!hidden);
    // The buttons went below the title.
    try testing.expect((try rect(u.buttons)).y >= (try rect(u.title)).y + (try rect(u.title)).height);
    const narrow_save = try rect(u.save);
    try testing.expectEqual(@as(f32, 90), narrow_save.width);
    try testing.expectEqual(wide_save.height, narrow_save.height);
    try h.expectGolden("adaptive-narrow", 320, 240);

    try ok(c.siv_test_resize(h.window, 640, 240));
    try h.settle();
    try testing.expectEqual(@as(f32, 160), (try rect(u.content)).x);
    try testing.expectEqual(wide_save, try rect(u.save));

    // Cleared: the sidebar stays at any width.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_clear_variants(txn, u.sidebar);
    try ok(c.siv_txn_commit(txn));
    try ok(c.siv_test_resize(h.window, 320, 240));
    try h.settle();
    try testing.expectEqual(@as(f32, 160), (try rect(u.content)).x);
}

test "variants: errors fail the transaction" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    const root = c.siv_window_get_root(h.window);
    const Case = struct { t.Result, *const fn (t.Txn, t.Node) void };
    const cases = [_]Case{
        // Flex options on a box.
        .{ .error_invalid_argument, struct {
            fn f(txn: t.Txn, n: t.Node) void {
                c.siv_set_flex_when(txn, n, null, null);
            }
        }.f },
        .{ .error_invalid_argument, struct {
            fn f(txn: t.Txn, n: t.Node) void {
                c.siv_set_hidden_when(txn, n, &.{ .min_width = -1 }, true);
            }
        }.f },
        .{ .error_invalid_argument, struct {
            fn f(txn: t.Txn, n: t.Node) void {
                c.siv_set_hidden_when(txn, n, &.{ .max_width = std.math.inf(f32) }, true);
            }
        }.f },
        .{ .error_unsupported, struct {
            fn f(txn: t.Txn, n: t.Node) void {
                c.siv_set_hidden_when(txn, n, &.{ .flags = @bitCast(@as(u32, 4)) }, true);
            }
        }.f },
        // A 33rd condition; changing one of the 32 is fine.
        .{ .error_limit_exceeded, struct {
            fn f(txn: t.Txn, n: t.Node) void {
                for (0..32) |i| c.siv_set_hidden_when(txn, n, &.{ .min_width = @floatFromInt(i) }, true);
                c.siv_set_hidden_when(txn, n, &.{ .min_width = 5 }, false);
                c.siv_set_hidden_when(txn, n, &.{ .min_width = 32 }, true);
            }
        }.f },
    };
    for (cases) |case| {
        var txn: t.Txn = .null;
        try ok(c.siv_txn_begin(h.window, &txn));
        const n = c.siv_box(txn, root);
        case[1](txn, n);
        try testing.expectEqual(case[0], c.siv_txn_commit(txn));
    }
}
