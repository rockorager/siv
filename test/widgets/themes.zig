//! User themes (D29) on the stock widgets: a gallery of every color token
//! (the surfaces from sidebar to card, text, controls, selections, and
//! the named colors) under Omarchy themes from test/themes/omarchy,
//! checked against golden images under test/golden/widgets/.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const ui = @import("ui");
const harness = @import("../abi/harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const Harness = harness.Harness;
const ok = harness.ok;

pub const width = 560;
pub const height = 340;

fn px(v: f32) t.Dimension {
    return .{ .unit = .px, .value = v };
}

fn label(txn: t.Txn, parent: t.Node, s: []const u8, token: t.ColorToken, role: t.SizeRole) t.Node {
    const n = c.siv_text(txn, parent, s.ptr, s.len);
    _ = c.siv_set_text_style(txn, n, &.{ .color_token = token, .size_role = role, .flags = .{ .no_wrap = true } });
    return n;
}

/// A pane of rows, the first selected, as a column browser shows them.
fn pane(txn: t.Txn, parent: t.Node, bg: t.ColorToken, title: []const u8, rows: []const []const u8) void {
    const p = c.siv_flex(txn, parent, &.{ .axis = .column, .gap = 2 });
    _ = c.siv_set_layout(txn, p, &.{ .width = px(104), .padding = .{ .start = 6, .end = 6, .top = 10, .bottom = 10 } });
    _ = c.siv_set_visual(txn, p, &.{ .background_token = bg });
    const head = label(txn, p, title, .muted_fg, .caption);
    _ = c.siv_set_layout(txn, head, &.{ .padding = .{ .start = 6, .bottom = 4 } });
    for (rows, 0..) |r, i| {
        const row = c.siv_box(txn, p);
        _ = c.siv_set_layout(txn, row, &.{ .padding = .{ .start = 6, .end = 6, .top = 3, .bottom = 3 } });
        if (i == 0) _ = c.siv_set_visual(txn, row, &.{ .radius = .{ .top_start = 4, .top_end = 4, .bottom_start = 4, .bottom_end = 4 }, .background_token = .selection_bg });
        _ = label(txn, row, r, if (i == 0) .selection_fg else if (i == 1) .accent else .view_fg, .body);
    }
}

/// Every token in one window: two recessed panes, the view with stock
/// controls and inputs, the named colors, a card, and an inverse toast.
pub fn build(h: *Harness) !void {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const panes = c.siv_flex(txn, root, &.{});
    _ = c.siv_set_layout(txn, panes, &.{ .grow = 1, .height = .{ .unit = .fraction, .value = 1 } });
    pane(txn, panes, .sidebar_bg, "Places", &.{ "Home", "Projects", "Music", "Trash" });
    pane(txn, panes, .secondary_sidebar_bg, "Home", &.{ "Documents", "Downloads", "notes.txt", "photo.png" });
    const view = c.siv_flex(txn, panes, &.{ .axis = .column, .gap = 10, .align_items = .start });
    _ = c.siv_set_layout(txn, view, &.{ .grow = 1, .padding = .{ .start = 14, .end = 14, .top = 12, .bottom = 12 } });
    _ = c.siv_set_visual(txn, view, &.{ .background_token = .view_bg, .border_token = .separator, .border_width = 1 });

    const buttons = c.siv_flex(txn, view, &.{ .gap = 6 });
    _ = c.siv_push_button(txn, buttons, &.{ .label = "Cancel", .label_len = 6 });
    _ = c.siv_push_button(txn, buttons, &.{ .label = "Save", .label_len = 4, .style = .primary });
    _ = c.siv_push_button(txn, buttons, &.{ .label = "Delete", .label_len = 6, .style = .destructive });
    _ = c.siv_push_button(txn, buttons, &.{ .label = "Off", .label_len = 3, .flags = .{ .disabled = true } });
    const checks = c.siv_flex(txn, view, &.{ .gap = 12 });
    _ = c.siv_check_box(txn, checks, &.{ .label = "Hidden", .label_len = 6, .checked = .on });
    _ = c.siv_switch(txn, checks, &.{ .label = "Preview", .label_len = 7, .checked = .on });
    _ = c.siv_switch(txn, checks, &.{ .label = "Icons", .label_len = 5 });
    const field = c.siv_text_field(txn, view, &.{ .placeholder = "Filter", .placeholder_len = 6 });
    _ = c.siv_set_layout(txn, field, &.{ .width = px(220) });
    const slider = c.siv_slider(txn, view, &.{ .label = "Zoom", .label_len = 4, .value = 40, .step = 1 });
    _ = c.siv_set_layout(txn, slider, &.{ .width = px(220) });
    const progress = c.siv_progress_bar(txn, view, &.{ .label = "Copying", .label_len = 7, .value = 60 });
    _ = c.siv_set_layout(txn, progress, &.{ .width = px(220) });
    const named = c.siv_flex(txn, view, &.{ .gap = 10 });
    _ = label(txn, named, "Muted", .muted_fg, .body);
    _ = label(txn, named, "Disabled", .disabled_fg, .body);
    _ = label(txn, named, "Added", .success, .body);
    _ = label(txn, named, "Changed", .warning, .body);
    _ = label(txn, named, "Error", .destructive, .body);
    const cards = c.siv_flex(txn, view, &.{ .gap = 10, .align_items = .center });
    const card = c.siv_box(txn, cards);
    _ = c.siv_set_layout(txn, card, &.{ .padding = .{ .start = 10, .end = 10, .top = 6, .bottom = 6 } });
    _ = c.siv_set_visual(txn, card, &.{ .radius = .{ .top_start = 6, .top_end = 6, .bottom_start = 6, .bottom_end = 6 }, .background_token = .card_bg, .border_token = .border, .border_width = 1 });
    _ = label(txn, card, "Card", .card_fg, .body);
    const toast = c.siv_box(txn, cards);
    _ = c.siv_set_layout(txn, toast, &.{ .padding = .{ .start = 10, .end = 10, .top = 6, .bottom = 6 } });
    _ = c.siv_set_visual(txn, toast, &.{ .radius = .{ .top_start = 6, .top_end = 6, .bottom_start = 6, .bottom_end = 6 }, .background_token = .inverse_bg });
    _ = label(txn, toast, "Copied 3 files", .inverse_fg, .body);
    try ok(c.siv_txn_commit(txn));
}

/// Applies an Omarchy theme as the application would read it.
pub fn useOmarchy(h: *Harness, colors_toml: []const u8) !void {
    (try h.internal()).app.setUserTheme(&ui.user_theme.omarchy(colors_toml, false));
    try h.settle();
}

test "theme: the widget gallery under Omarchy themes, dark and light" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(width, height, null, null);
    defer h.stop();
    try build(&h);
    try h.settle();
    try useOmarchy(&h, @embedFile("../themes/omarchy/tokyo-night/colors.toml"));
    try h.expectGolden("omarchy-tokyo-night", width, height);
    try useOmarchy(&h, @embedFile("../themes/omarchy/catppuccin-latte/colors.toml"));
    try h.expectGolden("omarchy-catppuccin-latte", width, height);
}
