//! Subtree themes (D29) on the stock widgets: an always-dark sidebar, an
//! inverse panel, and a section with its own accent, under the desktop's
//! light and dark schemes and high contrast, and a menu opened from the
//! sidebar, checked against golden images under test/golden/widgets/.
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

const width = 560;
const height = 300;

const purple: t.Color = .{ .r = 0.49, .g = 0.23, .b = 0.93, .a = 1 };

fn px(v: f32) t.Dimension {
    return .{ .unit = .px, .value = v };
}

fn label(txn: t.Txn, parent: t.Node, s: []const u8, token: t.ColorToken, role: t.SizeRole) t.Node {
    const n = c.siv_text(txn, parent, s.ptr, s.len);
    _ = c.siv_set_text_style(txn, n, &.{ .color_token = token, .size_role = role, .flags = .{ .no_wrap = true } });
    return n;
}

const radius: @FieldType(t.VisualDesc, "radius") = .{ .top_start = 4, .top_end = 4, .bottom_start = 4, .bottom_end = 4 };

/// A swatch drawn in the canvas's own subtree colors: the accent read
/// with siv_node_get_color, text in a themed color.
fn drawSwatch(_: ?*anyopaque, node: t.Node, d: t.Draw, w: f32, h: f32) callconv(.c) void {
    var accent: t.Color = undefined;
    if (c.siv_node_get_color(node, .accent, &accent) != .ok) return;
    c.siv_draw_rounded_rect(d, .{ .x = 0, .y = 0, .width = h, .height = h }, .{ .top_left = 4, .top_right = 4, .bottom_right = 4, .bottom_left = 4 });
    c.siv_draw_fill(d, &.{ .color = accent }, .{});
    c.siv_draw_text(d, h + 6, 1, w - h - 6, "Accent", 6, &.{ .color_token = .muted_fg, .size_role = .caption });
}

const Scene = struct {
    sidebar: t.Node,
    menu: t.Node,
    inverse: t.Node,
    section: t.Node,
    swatch: t.Node,
    save: t.Node,
};

fn build(h: *Harness) !Scene {
    var s: Scene = undefined;
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const row = c.siv_flex(txn, root, &.{});
    _ = c.siv_set_layout(txn, row, &.{ .height = .{ .unit = .fraction, .value = 1 } });

    // Always dark, whatever the desktop says.
    s.sidebar = c.siv_flex(txn, row, &.{ .axis = .column, .gap = 2 });
    _ = c.siv_set_theme(txn, s.sidebar, &.{ .scheme = .dark });
    _ = c.siv_set_layout(txn, s.sidebar, &.{ .width = px(150), .padding = .{ .start = 8, .end = 8, .top = 10, .bottom = 10 } });
    _ = c.siv_set_visual(txn, s.sidebar, &.{ .background_token = .sidebar_bg });
    const head = label(txn, s.sidebar, "Places", .muted_fg, .caption);
    _ = c.siv_set_layout(txn, head, &.{ .padding = .{ .start = 6, .bottom = 4 } });
    for ([_][]const u8{ "Home", "Music", "Trash" }, 0..) |name, i| {
        const r = c.siv_box(txn, s.sidebar);
        _ = c.siv_set_layout(txn, r, &.{ .padding = .{ .start = 6, .end = 6, .top = 3, .bottom = 3 } });
        if (i == 0) _ = c.siv_set_visual(txn, r, &.{ .radius = radius, .background_token = .selection_bg });
        _ = label(txn, r, name, if (i == 0) .selection_fg else .view_fg, .body);
    }
    _ = c.siv_switch(txn, s.sidebar, &.{ .label = "Hidden", .label_len = 6, .checked = .on });
    s.menu = c.siv_menu_button(txn, s.sidebar, &.{ .label = "More", .label_len = 4 });
    _ = c.siv_menu_item(txn, s.menu, &.{ .label = "New folder", .label_len = 10 });
    _ = c.siv_menu_item(txn, s.menu, &.{ .label = "Show hidden", .label_len = 11, .flags = .{ .checked = true } });
    _ = c.siv_menu_item(txn, s.menu, &.{ .label = "Empty trash", .label_len = 11, .flags = .{ .disabled = true } });
    s.swatch = c.siv_canvas(txn, s.sidebar, &.{ .draw = drawSwatch, .width = 120, .height = 16 });

    // The view follows the desktop.
    const view = c.siv_flex(txn, row, &.{ .axis = .column, .gap = 10, .align_items = .start });
    _ = c.siv_set_layout(txn, view, &.{ .grow = 1, .padding = .{ .start = 14, .end = 14, .top = 12, .bottom = 12 } });
    _ = c.siv_set_visual(txn, view, &.{ .background_token = .view_bg });
    _ = label(txn, view, "Documents", .view_fg, .heading);
    const buttons = c.siv_flex(txn, view, &.{ .gap = 6 });
    _ = c.siv_push_button(txn, buttons, &.{ .label = "Cancel", .label_len = 6 });
    s.save = c.siv_push_button(txn, buttons, &.{ .label = "Save", .label_len = 4, .style = .primary });
    _ = c.siv_check_box(txn, view, &.{ .label = "Keep a copy", .label_len = 11, .checked = .on });

    // The opposite of what is around it: a dark panel in a light window.
    s.inverse = c.siv_flex(txn, view, &.{ .gap = 10, .align_items = .center });
    _ = c.siv_set_theme(txn, s.inverse, &.{ .scheme = .inverse });
    _ = c.siv_set_layout(txn, s.inverse, &.{ .padding = .{ .start = 10, .end = 6, .top = 6, .bottom = 6 } });
    _ = c.siv_set_visual(txn, s.inverse, &.{ .radius = radius, .background_token = .card_bg, .border_token = .border, .border_width = 1 });
    _ = label(txn, s.inverse, "Moved 3 files", .card_fg, .body);
    _ = c.siv_push_button(txn, s.inverse, &.{ .label = "Undo", .label_len = 4 });

    // Its own accent, in every variant: what derives from it follows.
    s.section = c.siv_flex(txn, view, &.{ .gap = 12, .align_items = .center });
    _ = c.siv_set_theme_color(txn, s.section, .all, .accent, purple);
    _ = c.siv_push_button(txn, s.section, &.{ .label = "Share", .label_len = 5, .style = .primary });
    _ = c.siv_switch(txn, s.section, &.{ .label = "Public", .label_len = 6, .checked = .on });
    const slider = c.siv_slider(txn, s.section, &.{ .label = "Zoom", .label_len = 4, .value = 60, .step = 1 });
    _ = c.siv_set_layout(txn, slider, &.{ .width = px(110) });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    return s;
}

/// The desktop's settings change, as the portal reports them (D19).
fn setDesktop(h: *Harness, scheme: ui.Desktop.ColorScheme, contrast: ui.Desktop.Contrast, accent: ?[3]f64) !void {
    const self = try h.internal();
    const values = &self.app.desktop.values;
    values.color_scheme = scheme;
    values.contrast = contrast;
    values.accent_color = accent;
    for (self.app.windows.items) |slot| if (slot) |win| {
        const old = win.ui.palette;
        win.ui.setDesktop(values.*);
        win.paletteApplied(&old);
    };
    try h.settle();
}

fn color(n: t.Node, token: t.ColorToken) !t.Color {
    var out: t.Color = undefined;
    try ok(c.siv_node_get_color(n, token, &out));
    return out;
}

fn windowColor(w: t.Window, token: t.ColorToken) !t.Color {
    var out: t.Color = undefined;
    try ok(c.siv_window_get_color(w, token, &out));
    return out;
}

fn expectColor(want: t.Color, got: t.Color) !void {
    for ([_]f32{ want.r, want.g, want.b, want.a }, [_]f32{ got.r, got.g, got.b, got.a }) |a, b| try testing.expectApproxEqAbs(a, b, 1e-3);
}

fn eqlColor(a: t.Color, b: t.Color) bool {
    return @abs(a.r - b.r) < 1e-3 and @abs(a.g - b.g) < 1e-3 and @abs(a.b - b.b) < 1e-3 and @abs(a.a - b.a) < 1e-3;
}

/// Counts the settings events that report theme colors changed.
const Settings = struct {
    themes: u32 = 0,

    fn on(ud: ?*anyopaque, _: t.Node, e: *const t.Event) callconv(.c) t.EventResult {
        const self: *Settings = @ptrCast(@alignCast(ud.?));
        if (e.type == .settings and e.flags.theme_changed) self.themes += 1;
        return .pass;
    }
};

fn openPopup(h: *Harness) !t.Window {
    const self = try h.internal();
    for (self.windows.items) |slot| if (slot) |w| {
        if (!w.dead and w.parent != null and w.win.shown) return @fromBackingInt(w.handle);
    };
    return error.NoPopup;
}

fn center(n: t.Node) ![2]f64 {
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(n, &r));
    return .{ r.x + r.width / 2, r.y + r.height / 2 };
}

test "subtree themes: a dark sidebar, an inverse panel, and an accent section in light, dark, and high contrast" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(width, height, null, null);
    defer h.stop();
    const s = try build(&h);
    try h.expectGolden("subtree-light", width, height);
    // The sidebar is the dark variant in a light window; the window's
    // colors stay light.
    try testing.expect(!eqlColor(try color(s.sidebar, .view_bg), try windowColor(h.window, .view_bg)));
    try expectColor(try color(s.inverse, .view_bg), try color(s.sidebar, .view_bg));
    try expectColor(purple, try color(s.section, .accent));
    try expectColor(try windowColor(h.window, .accent), try color(s.save, .accent));

    try setDesktop(&h, .dark, .normal, null);
    try h.expectGolden("subtree-dark", width, height);
    // The inverse panel turned light with the window dark.
    try expectColor(try color(s.sidebar, .view_bg), try windowColor(h.window, .view_bg));
    try testing.expect(!eqlColor(try color(s.inverse, .view_bg), try windowColor(h.window, .view_bg)));

    try setDesktop(&h, .no_preference, .high, null);
    try h.expectGolden("subtree-high-contrast", width, height);

    // The desktop's accent reaches the dark sidebar, not the section
    // with an accent of its own.
    const red: [3]f64 = .{ 0.86, 0.15, 0.15 };
    try setDesktop(&h, .no_preference, .normal, red);
    try expectColor(.{ .r = 0.86, .g = 0.15, .b = 0.15, .a = 1 }, try color(s.sidebar, .accent));
    try expectColor(purple, try color(s.section, .accent));
}

test "subtree themes: popups opened from a themed subtree take its theme" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(width, height, null, null);
    defer h.stop();
    const s = try build(&h);
    const at = try center(s.menu);
    try h.click(at[0], at[1]);
    try h.settle();
    const popup = try openPopup(&h);
    // The popup's window colors are the sidebar's, live: the desktop
    // switching to dark leaves the forced dark as it was, but its accent
    // still reaches the open menu.
    try expectColor(try color(s.sidebar, .card_bg), try windowColor(popup, .card_bg));
    var size: t.Size = undefined;
    try ok(c.siv_window_get_size(popup, &size));
    try h.expectGoldenOf(popup, "subtree-menu", @intFromFloat(size.width), @intFromFloat(size.height));
    try setDesktop(&h, .no_preference, .normal, .{ 0.1, 0.6, 0.3 });
    try expectColor(try color(s.sidebar, .accent), try windowColor(popup, .accent));
}

test "subtree themes: setting, changing, and clearing a theme repaints its subtree; aborting leaves it" {
    var h: Harness = .{};
    try h.start(width, height, null, null);
    defer h.stop();
    const s = try build(&h);
    const light = try windowColor(h.window, .view_bg);
    // Clearing the sidebar's scheme: its colors are the window's.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_theme(txn, s.sidebar, null);
    try expectColor(light, try color(s.sidebar, .view_bg));
    try expectColor(light, try color(s.swatch, .view_bg));
    c.siv_txn_abort(txn);
    try testing.expect(!eqlColor(light, try color(s.sidebar, .view_bg)));
    // Committed, the subtree repaints in the window's colors: the
    // sidebar's pixels change, the view's do not.
    const before = try h.capture();
    defer testing.allocator.free(before);
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_theme(txn, s.sidebar, null);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    const after = try h.capture();
    defer testing.allocator.free(after);
    const at = struct {
        fn f(img: []const u8, x: usize, y: usize) [4]u8 {
            return img[(y * width + x) * 4 ..][0..4].*;
        }
    }.f;
    try testing.expect(!std.mem.eql(u8, &at(before, 4, 280), &at(after, 4, 280)));
    try testing.expectEqualSlices(u8, &at(before, 540, 280), &at(after, 540, 280));
    // A node with nothing chosen carries no theme.
    const uw, const id = try abi.tree.lookup(s.sidebar);
    try testing.expect(uw.uiWin().node(id).theme == null);
    // An inverse panel moved into a forced-dark subtree is light there,
    // and settings handlers in it hear that its colors changed.
    var settings: Settings = .{};
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_on(txn, s.swatch, .settings, Settings.on, null, &settings);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_theme(txn, s.sidebar, &.{ .scheme = .dark });
    c.siv_move(txn, s.inverse, s.sidebar, .null);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try expectColor(light, try color(s.inverse, .view_bg));
    try testing.expectEqual(@as(u32, 1), settings.themes);
    // A desktop change that moves the window's colors and some subtrees'
    // is one event.
    try setDesktop(&h, .dark, .normal, null);
    try testing.expectEqual(@as(u32, 2), settings.themes);
    // Bad arguments fail the transaction.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_theme_color(txn, s.sidebar, .all, .none, purple);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_theme(txn, s.sidebar, &.{ .scheme = @enumFromInt(9) });
    try testing.expectEqual(t.Result.error_unsupported, c.siv_txn_commit(txn));
}
