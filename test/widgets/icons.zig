//! Themed icons (D19) through the C ABI on the headless backend: icon
//! buttons, icon and label, icon-only buttons named by their label,
//! menu items with icons, image nodes showing icons by name, canvases
//! drawing them, and siv_icon_load, from siv's test themes
//! (test/icons/themes). Golden images under test/golden/widgets/.
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

fn uiId(n: t.Node) !struct { *ui.Window, ui.NodeId } {
    const w, const id = try abi.tree.lookup(n);
    return .{ w.uiWin(), id };
}

fn semName(n: t.Node) ![]const u8 {
    const uw, const id = try uiId(n);
    const tree = try uw.semanticsTree();
    for (tree.nodes.items) |s| if (s.node == id) return tree.name(s);
    return error.NotInSemanticsTree;
}

fn drawIcons(_: ?*anyopaque, _: t.Node, draw: t.Draw, _: f32, _: f32) callconv(.c) void {
    // A symbolic icon in a color of its own, a full-color one, and a
    // missing one that draws nothing.
    _ = c.siv_draw_icon(draw, "edit-copy-symbolic", 18, .{ .x = 0, .y = 4, .width = 32, .height = 32 }, .{ .r = 0.9, .g = 0.2, .b = 0.5, .a = 1 }, .{});
    _ = c.siv_draw_icon(draw, "siv-test-app", 12, .{ .x = 40, .y = 4, .width = 32, .height = 32 }, .{}, .{});
    _ = c.siv_draw_icon(draw, "no-such-icon", 12, .{ .x = 80, .y = 4, .width = 32, .height = 32 }, .{}, .{});
}

const Fixture = struct {
    copy: t.Node,
    warning: t.Node,
    toggle: t.Node,
    folder: t.Node,
    menu: t.Node,
};

fn build(h: *Harness) !Fixture {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .gap = 12, .align_items = .start });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 16, .end = 16, .top = 16, .bottom = 16 } });
    const row = c.siv_flex(txn, col, &.{ .gap = 8 });
    var f: Fixture = undefined;
    f.copy = c.siv_push_button(txn, row, &.{ .label = "Copy", .label_len = 4, .icon = "edit-copy-symbolic", .icon_len = 18 });
    _ = c.siv_push_button(txn, row, &.{ .label = "Next", .label_len = 4, .style = .primary, .icon = "go-next-symbolic", .icon_len = 16 });
    f.warning = c.siv_push_button(txn, row, &.{ .label = "Warning", .label_len = 7, .style = .flat, .icon = "dialog-warning-symbolic", .icon_len = 23, .flags = .{ .icon_only = true } });
    _ = c.siv_push_button(txn, row, &.{ .label = "Delete", .label_len = 6, .style = .destructive, .icon = "dialog-error-symbolic", .icon_len = 21, .flags = .{ .icon_only = true } });
    _ = c.siv_push_button(txn, row, &.{ .label = "Off", .label_len = 3, .icon = "edit-copy-symbolic", .icon_len = 18, .flags = .{ .disabled = true } });
    const row2 = c.siv_flex(txn, col, &.{ .gap = 12, .align_items = .center });
    f.toggle = c.siv_toggle_button(txn, row2, &.{ .label = "Done", .label_len = 4, .checked = .on, .icon = "emblem-ok-symbolic", .icon_len = 18 });
    f.menu = c.siv_menu_button(txn, row2, &.{ .label = "Places", .label_len = 6, .icon = "folder", .icon_len = 6 });
    _ = c.siv_menu_item(txn, f.menu, &.{ .label = "Documents", .label_len = 9, .icon = "folder-documents", .icon_len = 16 });
    _ = c.siv_menu_item(txn, f.menu, &.{ .label = "Copy", .label_len = 4, .icon = "edit-copy-symbolic", .icon_len = 18, .shortcut = "Ctrl+C", .shortcut_len = 6 });
    _ = c.siv_menu_item(txn, f.menu, &.{ .label = "No icon", .label_len = 7 });
    const row3 = c.siv_flex(txn, col, &.{ .gap = 12, .align_items = .center });
    f.folder = c.siv_image_view(txn, row3, &.{ .icon = "folder", .icon_len = 6, .icon_size = 48 });
    // Symbolic icons take the node's color; a missing icon keeps its space.
    _ = c.siv_image_view(txn, row3, &.{ .icon = "dialog-error-symbolic", .icon_len = 21, .icon_size = 24, .color_token = .accent });
    const missing = c.siv_image_view(txn, row3, &.{ .icon = "no-such-icon", .icon_len = 12, .icon_size = 24 });
    _ = c.siv_set_visual(txn, missing, &.{ .border_width = 1, .border_token = .border });
    // Fallback names: the first the theme has.
    _ = c.siv_image_view(txn, row3, &.{ .icon = "no-such-icon\nsiv-test-app", .icon_len = 25, .icon_size = 32 });
    _ = c.siv_canvas(txn, row3, &.{ .draw = drawIcons, .width = 112, .height = 40 });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    return f;
}

test "icons: buttons, menus, image nodes, and canvases follow the theme" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(400, 220, null, null);
    defer h.stop();
    const f = try build(&h);
    try h.expectGolden("icons-light", 400, 220);
    // The icon-only button is named by its label; icons add nothing to
    // a labelled button's name.
    try testing.expectEqualStrings("Warning", try semName(f.warning));
    try testing.expectEqualStrings("Copy", try semName(f.copy));
    try testing.expectEqualStrings("Done", try semName(f.toggle));
    var rect: t.Rect = undefined;
    try ok(c.siv_node_get_rect(f.folder, &rect));
    try testing.expectEqual(@as(f32, 48), rect.width);

    try ok(c.siv_app_set_theme(h.app, &.{ .scheme = .dark }));
    try h.settle();
    try h.expectGolden("icons-dark", 400, 220);

    // Another icon theme: SivColor draws its own folder, recolored by the
    // accent; the symbolic icons come from its parent.
    try ok(c.siv_app_set_theme(h.app, &.{}));
    try ok(c.siv_app_set_icon_theme(h.app, "SivColor", 8));
    try h.settle();
    try h.expectGolden("icons-theme", 400, 220);
}

test "icons: menu items line up their icons" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(400, 220, null, null);
    defer h.stop();
    const f = try build(&h);
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(f.menu, &r));
    try h.click(r.x + r.width / 2, r.y + r.height / 2);
    try h.settle();
    const self = try h.internal();
    var popup: t.Window = .null;
    for (self.windows.items) |slot| if (slot) |w| {
        if (!w.dead and w.parent != null and w.win.shown) popup = @fromBackingInt(w.handle);
    };
    if (popup == .null) return error.NoPopup;
    try h.settle();
    var size: t.Size = undefined;
    try ok(c.siv_window_get_size(popup, &size));
    try h.expectGoldenOf(popup, "menu-icons", @intFromFloat(size.width), @intFromFloat(size.height));
}

const Loaded = struct {
    result: t.Result = .error_busy,
    image: t.Image = .null,
    destroyed: bool = false,

    fn done(ud: ?*anyopaque, result: t.Result, image: t.Image) callconv(.c) void {
        const l: *Loaded = @ptrCast(@alignCast(ud.?));
        l.result = result;
        l.image = image;
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const l: *Loaded = @ptrCast(@alignCast(ud.?));
        l.destroyed = true;
    }
};

test "icons: siv_icon_load delivers vector and pixel icons, and misses" {
    var h: Harness = .{};
    try h.start(64, 64, null, null);
    defer h.stop();
    var req: t.ImageRequest = .null;
    var vec: Loaded = .{};
    try ok(c.siv_icon_load(h.app, &.{ .name = "edit-copy", .name_len = 9, .logical_size = 24, .style = .symbolic }, Loaded.done, Loaded.destroy, &vec, &req));
    // Never inside the call.
    try testing.expectEqual(t.Result.error_busy, vec.result);
    var px: Loaded = .{};
    try ok(c.siv_icon_load(h.app, &.{ .name = "document-new", .name_len = 12, .scale = 2 }, Loaded.done, Loaded.destroy, &px, &req));
    var none: Loaded = .{};
    try ok(c.siv_icon_load(h.app, &.{ .name = "folder-music", .name_len = 12, .flags = .{ .no_fallbacks = true } }, Loaded.done, Loaded.destroy, &none, &req));
    // A cancelled load releases its user data at once and never calls back.
    var cancelled: Loaded = .{};
    var creq: t.ImageRequest = .null;
    try ok(c.siv_icon_load(h.app, &.{ .name = "edit-copy", .name_len = 9, .logical_size = 32 }, Loaded.done, Loaded.destroy, &cancelled, &creq));
    c.siv_image_request_cancel(creq);
    try testing.expect(cancelled.destroyed);
    c.siv_image_request_cancel(creq);
    while (!(vec.destroyed and px.destroyed and none.destroyed)) try ok(c.siv_app_dispatch(h.app, 10));
    try ok(vec.result);
    defer _ = c.siv_image_destroy(vec.image);
    var size: t.Size = undefined;
    try ok(c.siv_image_get_size(vec.image, &size));
    try testing.expectEqual(t.Size{ .width = 24, .height = 24 }, size);
    try ok(px.result);
    defer _ = c.siv_image_destroy(px.image);
    try ok(c.siv_image_get_size(px.image, &size));
    // 32 pixels at scale 2.
    try testing.expectEqual(t.Size{ .width = 16, .height = 16 }, size);
    try testing.expectEqual(t.Result.error_unavailable, none.result);
    try testing.expectEqual(t.Result.error_busy, cancelled.result);
    // A finished load's request is gone.
    c.siv_image_request_cancel(req);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_icon_load(h.app, &.{}, Loaded.done, null, null, &req));
}
