//! Spinners, chips, avatars, cards, and suggestion lists (D22), and the
//! anchored placement suggestion lists stand on (siv_set_anchor, D26),
//! through the C ABI on the headless backend: built with the exported
//! builders, driven by injected keys and clicks, and checked against
//! golden images under test/golden/widgets/ and the semantics tree.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const ui = @import("ui");
const platform = @import("platform");
const harness = @import("../abi/harness.zig");
const themes = @import("themes.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const Harness = harness.Harness;
const ok = harness.ok;

const ks = struct {
    const tab: u32 = 0xff09;
    const @"return": u32 = 0xff0d;
    const escape: u32 = 0xff1b;
    const up: u32 = 0xff52;
    const down: u32 = 0xff54;
    const space: u32 = 0x20;
    const delete: u32 = 0xffff;
    const backspace: u32 = 0xff08;
};

const Log = struct {
    activates: u32 = 0,
    closes: u32 = 0,
    selects: u32 = 0,
    index: u32 = 0,
    keep: bool = false,

    fn onActivate(ud: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.activates += 1;
        return .handled;
    }

    fn onClose(ud: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.closes += 1;
        return if (log.keep) .handled else .pass;
    }

    fn onSelect(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.selects += 1;
        log.index = ev.index;
        return .handled;
    }
};

fn px(v: f32) t.Dimension {
    return .{ .unit = .px, .value = v };
}

const whole: t.Dimension = .{ .unit = .fraction, .value = 1 };

fn rect(n: t.Node) !t.Rect {
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(n, &r));
    return r;
}

fn center(n: t.Node) ![2]f64 {
    const r = try rect(n);
    return .{ r.x + r.width / 2, r.y + r.height / 2 };
}

fn find(h: *Harness, role: t.Role, name: []const u8) !?t.TestNode {
    var found = false;
    var node: t.TestNode = undefined;
    try ok(c.siv_test_find(h.window, &.{ .role = role, .name = name.ptr, .name_len = name.len }, &found, &node));
    return if (found) node else null;
}

fn key(h: *Harness, sym: u32) !void {
    try h.typeKey(sym, "", .{});
    try h.settle();
}

fn move(h: *Harness, x: f64, y: f64) !void {
    try h.inject(&.{.{ .pointer_motion = .{ .window = (try h.win()).win.id, .seat = 0, .x = x, .y = y } }});
    try h.settle();
}

fn shown(n: t.Node) !bool {
    var s = false;
    try ok(c.siv_node_is_shown(n, &s));
    return s;
}

fn value(n: t.Node) !f64 {
    var v: f64 = 0;
    try ok(c.siv_widget_get_value(n, &v));
    return v;
}

fn dumpHas(h: *Harness, needle: []const u8) !bool {
    var buf: [16384]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_test_dump(h.window, &buf, buf.len, &len));
    return std.mem.indexOf(u8, buf[0..@min(len, buf.len)], needle) != null;
}

fn text(txn: t.Txn, parent: t.Node, s: []const u8, token: t.ColorToken) t.Node {
    const n = c.siv_text(txn, parent, s.ptr, s.len);
    _ = c.siv_set_text_style(txn, n, &.{ .color_token = token, .size_role = .body });
    return n;
}

const Gallery = struct {
    spinner: t.Node,
    open: t.Node,
    filter: t.Node,
    label: t.Node,
    avatar: t.Node,
};

/// A card holding spinners, chips of every kind, and avatars.
fn buildGallery(h: *Harness, log: *Log) !Gallery {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const pad = c.siv_flex(txn, root, &.{ .axis = .column, .align_items = .stretch });
    _ = c.siv_set_layout(txn, pad, &.{ .padding = .{ .start = 16, .end = 16, .top = 16, .bottom = 16 } });
    const card = c.siv_card(txn, pad, &.{ .label = "Inbox", .label_len = 5, .flags = .{ .accent = true } });
    _ = c.siv_set_layout(txn, card, &.{ .padding = .{ .start = 16, .end = 16, .top = 14, .bottom = 14 } });
    _ = c.siv_set_flex(txn, card, &.{ .axis = .column, .gap = 14, .align_items = .start });
    var g: Gallery = undefined;

    const busy = c.siv_flex(txn, card, &.{ .gap = 12, .align_items = .center });
    g.spinner = c.siv_spinner(txn, busy, null);
    _ = c.siv_spinner(txn, busy, &.{ .label = "Syncing", .label_len = 7, .diameter = 24 });
    _ = text(txn, busy, "Syncing mail", .card_fg);

    const chips = c.siv_flex(txn, card, &.{ .gap = 8, .align_items = .center, .flags = .{ .wrap = true } });
    _ = c.siv_chip(txn, chips, &.{ .label = "Inbox", .label_len = 5 });
    g.label = c.siv_chip(txn, chips, &.{ .label = "Work", .label_len = 4, .color = .blue });
    _ = c.siv_chip(txn, chips, &.{ .label = "Family", .label_len = 6, .color = .green });
    _ = c.siv_chip(txn, chips, &.{ .label = "Urgent", .label_len = 6, .color = .red });
    _ = c.siv_chip(txn, chips, &.{ .label = "Receipts", .label_len = 8, .color = .yellow });
    g.open = c.siv_chip(txn, chips, &.{ .label = "Travel", .label_len = 6, .color = .cyan, .flags = .{ .clickable = true } });
    _ = c.siv_on(txn, g.open, .activate, Log.onActivate, null, log);
    g.filter = c.siv_chip(txn, chips, &.{ .label = "from:maya", .label_len = 9, .color = .magenta, .flags = .{ .removable = true } });
    _ = c.siv_on(txn, g.filter, .close, Log.onClose, null, log);
    _ = c.siv_chip(txn, chips, &.{ .label = "has:attachment", .label_len = 14, .icon = "folder", .icon_len = 6, .flags = .{ .removable = true } });
    _ = c.siv_chip(txn, chips, &.{ .label = "Archived", .label_len = 8, .flags = .{ .clickable = true, .disabled = true } });

    const avatars = c.siv_flex(txn, card, &.{ .gap = 10, .align_items = .center });
    g.avatar = c.siv_avatar(txn, avatars, &.{ .name = "Maya Okafor", .name_len = 11 });
    for ([_][]const u8{ "Mark Ito", "ada", "Élodie Zola", "Jo <jo@example.com>", "" }) |name| _ = c.siv_avatar(txn, avatars, &.{ .name = name.ptr, .name_len = name.len });
    _ = c.siv_avatar(txn, avatars, &.{ .name = "Grace Hopper", .name_len = 12, .diameter = 44 });
    _ = c.siv_avatar(txn, avatars, &.{ .name = "Me", .name_len = 2, .diameter = 24, .color = .blue });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    return g;
}

test "display: spinners, chips, avatars, and a card in light, dark, and an Omarchy theme" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(480, 250, null, null);
    defer h.stop();
    var log: Log = .{};
    const g = try buildGallery(&h, &log);
    try h.expectGolden("display-light", 480, 250);

    // A spinner is busy progress without a value, named Loading unless
    // its label says otherwise.
    const spin = (try find(&h, .progress_bar, "Loading")).?;
    try testing.expect(spin.flags.busy and !spin.flags.has_value and !spin.flags.focusable);
    try testing.expect((try find(&h, .progress_bar, "Syncing")).?.flags.busy);
    // Chips: only interactive ones are buttons and focusable; a disabled
    // one is neither focusable nor operable.
    try testing.expect((try find(&h, .button, "Travel")).?.flags.focusable);
    try testing.expect((try find(&h, .button, "from:maya")).?.flags.focusable);
    try testing.expect((try find(&h, .button, "Work")) == null);
    const archived = (try find(&h, .button, "Archived")).?;
    try testing.expect(archived.flags.disabled and !archived.flags.focusable);
    // Avatars are images named by the name; the card is a group.
    try testing.expect((try find(&h, .image, "Maya Okafor")) != null);
    try testing.expect((try find(&h, .group, "Inbox")) != null);
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    // The initials show; the picture part is empty until an image comes.
    try testing.expect(c.siv_widget_get_part(g.avatar, .image, 0) != .null);
    try ok(c.siv_node_get_text(c.siv_node_get_related(g.avatar, .first_child), &buf, buf.len, &len));
    try testing.expectEqualStrings("MO", buf[0..len]);

    // siv_widget_set_label renames the spinner and the avatar, whose
    // initials follow.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_widget_set_label(txn, g.spinner, "Sending", 7);
    c.siv_widget_set_label(txn, g.avatar, "Ada Lovelace", 12);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expect((try find(&h, .progress_bar, "Sending")) != null);
    try testing.expect((try find(&h, .image, "Ada Lovelace")) != null);
    try ok(c.siv_node_get_text(c.siv_node_get_related(g.avatar, .first_child), &buf, buf.len, &len));
    try testing.expectEqualStrings("AL", buf[0..len]);
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_widget_set_label(txn, g.spinner, "", 0);
    c.siv_widget_set_label(txn, g.avatar, "Maya Okafor", 11);
    try ok(c.siv_txn_commit(txn));
    try h.settle();

    try ok(c.siv_app_set_theme(h.app, &.{ .scheme = .dark }));
    try h.settle();
    try h.expectGolden("display-dark", 480, 250);

    // The hues and their tints follow the user's theme live: tokyo
    // night's red, at the tint's opacity.
    try ok(c.siv_app_set_theme(h.app, &.{}));
    try themes.useOmarchy(&h, @embedFile("../themes/omarchy/tokyo-night/colors.toml"));
    try h.expectGolden("display-tokyo-night", 480, 250);
    var red: t.Color = undefined;
    var tint: t.Color = undefined;
    try ok(c.siv_window_get_color(h.window, .red, &red));
    try ok(c.siv_window_get_color(h.window, .red_bg, &tint));
    try testing.expectApproxEqAbs(@as(f32, 0xf7) / 255, red.r, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0x76) / 255, red.g, 1e-3);
    try testing.expectApproxEqAbs(red.r, tint.r, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.3), tint.a, 1e-3);
}

test "display: invalid descriptors fail the transaction" {
    var h: Harness = .{};
    try h.start(100, 100, null, null);
    defer h.stop();
    const root = c.siv_window_get_root(h.window);
    const Case = struct { f: *const fn (t.Txn, t.Node) t.Node, want: t.Result };
    const cases = [_]Case{
        .{ .f = struct {
            fn f(txn: t.Txn, p: t.Node) t.Node {
                return c.siv_spinner(txn, p, &.{ .diameter = -1 });
            }
        }.f, .want = .error_invalid_argument },
        .{ .f = struct {
            fn f(txn: t.Txn, p: t.Node) t.Node {
                return c.siv_chip(txn, p, &.{ .flags = @bitCast(@as(u32, 8)) });
            }
        }.f, .want = .error_unsupported },
        .{ .f = struct {
            fn f(txn: t.Txn, p: t.Node) t.Node {
                return c.siv_avatar(txn, p, &.{ .color = @fromBackingInt(200) });
            }
        }.f, .want = .error_unsupported },
        .{ .f = struct {
            fn f(txn: t.Txn, p: t.Node) t.Node {
                // No anchor.
                return c.siv_suggestion_list(txn, p, null);
            }
        }.f, .want = .error_invalid_argument },
    };
    for (cases) |cs| {
        var txn: t.Txn = .null;
        try ok(c.siv_txn_begin(h.window, &txn));
        try testing.expectEqual(t.Node.null, cs.f(txn, root));
        try testing.expectEqual(cs.want, c.siv_txn_commit(txn));
    }
}

test "display: a spinner turns on the compositor while shown, and holds still under reduced motion" {
    for ([_]bool{ false, true }) |reduced| {
        var h: Harness = .{ .reduced_motion = reduced };
        try h.start(100, 100, null, null);
        defer h.stop();
        var txn: t.Txn = .null;
        try ok(c.siv_txn_begin(h.window, &txn));
        const holder = c.siv_box(txn, c.siv_window_get_root(h.window));
        const spinner = c.siv_spinner(txn, holder, null);
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        try testing.expectEqual(!reduced, try turning(spinner));
        if (reduced) continue;
        // Hidden, it stops; shown, it turns again.
        try ok(c.siv_txn_begin(h.window, &txn));
        c.siv_set_hidden(txn, spinner, true);
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        try testing.expect(!try turning(spinner));
        try ok(c.siv_txn_begin(h.window, &txn));
        c.siv_set_hidden(txn, spinner, false);
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        try testing.expect(try turning(spinner));
    }
}

/// Whether the compositor runs a repeating turn of the spinner's orbit
/// (its second child).
fn turning(spinner: t.Node) !bool {
    const w, const id = try abi.tree.lookup(spinner);
    const uw = w.uiWin();
    const orbit = uw.node(uw.node(id).first).next;
    const li = uw.state(orbit).own_layer;
    if (li >= uw.paint.layers.items.len) return false;
    const l = uw.paint.layers.items[li];
    if (l.owner != orbit) return false;
    const a = l.anim orelse return false;
    return a.iterations == 0;
}

test "chips: clicks and keys activate and remove them; a handler keeps one" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(480, 250, null, null);
    defer h.stop();
    var log: Log = .{};
    const g = try buildGallery(&h, &log);

    // A clickable chip reports activate on a click, Enter, and Space.
    const open = try center(g.open);
    try h.click(open[0], open[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.activates);
    try testing.expectEqual(g.open, c.siv_window_get_focus(h.window));
    try key(&h, ks.@"return");
    try key(&h, ks.space);
    try testing.expectEqual(@as(u32, 3), log.activates);
    // Delete does nothing to a chip that is not removable.
    try key(&h, ks.delete);
    try testing.expect(c.siv_node_get_window(g.open) != .null);

    // Hover and focus show on a removable chip.
    try ok(c.siv_node_focus(g.filter));
    const filter = try center(g.filter);
    try move(&h, filter[0] - 10, filter[1]);
    try h.expectGolden("chips-hover-focus", 480, 250);

    // A removable chip asks to close on Delete, BackSpace, a click, and its
    // remove button; the handler keeps it, then lets it go.
    log.keep = true;
    try key(&h, ks.delete);
    try key(&h, ks.backspace);
    try h.click(filter[0] - 10, filter[1]);
    try h.settle();
    const cross = c.siv_node_get_related(g.filter, .last_child);
    const x = try center(cross);
    try h.click(x[0], x[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 4), log.closes);
    try testing.expect(c.siv_node_get_window(g.filter) != .null);
    try testing.expect((try find(&h, .button, "Remove")) != null);
    log.keep = false;
    try h.click(x[0], x[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 5), log.closes);
    try testing.expect(c.siv_node_get_window(g.filter) == .null);

    // A disabled chip takes no click.
    const archived = (try find(&h, .button, "Archived")).?;
    try h.click(archived.bounds.x + archived.bounds.width / 2, archived.bounds.y + archived.bounds.height / 2);
    try h.settle();
    try testing.expectEqual(@as(u32, 3), log.activates);
}

// Suggestion lists ---------------------------------------------------------------------

const people = [_][2][]const u8{
    .{ "Maya Okafor", "maya@example.com" },
    .{ "Mark Ito", "mark@example.com" },
    .{ "Marta Díaz", "marta@example.com" },
    .{ "Max Weber", "max@example.com" },
    .{ "Ada Lovelace", "ada@example.com" },
};

/// A compose form: the suggestions follow what the To field holds, as
/// the application finds them, and a chosen one replaces it.
const Compose = struct {
    field: t.Node = .null,
    body: t.Node = .null,
    list: t.Node = .null,
    log: Log = .{},
    /// The person whose suggestion is disabled.
    off: usize = 3,

    fn onChange(ud: ?*anyopaque, node: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const self: *Compose = @ptrCast(@alignCast(ud.?));
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        _ = c.siv_node_get_text(node, &buf, buf.len, &len);
        self.suggest(ev.window, buf[0..@min(len, buf.len)]);
        return .pass;
    }

    fn suggest(self: *Compose, window: t.Window, typed: []const u8) void {
        var txn: t.Txn = .null;
        if (c.siv_txn_begin(window, &txn) != .ok) return;
        c.siv_suggestion_list_clear(txn, self.list);
        if (typed.len != 0) for (people, 0..) |p, i| {
            if (!std.ascii.startsWithIgnoreCase(p[0], typed)) continue;
            _ = c.siv_suggestion_list_item(txn, self.list, &.{ .label = p[0].ptr, .label_len = p[0].len, .detail = p[1].ptr, .detail_len = p[1].len, .flags = .{ .disabled = i == self.off } });
        };
        _ = c.siv_txn_commit(txn);
    }

    fn onSelect(ud: ?*anyopaque, node: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const self: *Compose = @ptrCast(@alignCast(ud.?));
        _ = Log.onSelect(&self.log, node, ev);
        // The chosen item's label replaces what was typed.
        const item = c.siv_widget_get_part(node, .item, ev.index);
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        _ = c.siv_node_get_text(c.siv_node_get_related(item, .first_child), &buf, buf.len, &len);
        var txn: t.Txn = .null;
        if (c.siv_txn_begin(ev.window, &txn) != .ok) return .handled;
        c.siv_set_text(txn, self.field, &buf, len);
        _ = c.siv_txn_commit(txn);
        return .handled;
    }
};

/// The To field at `top` in a window `height` tall, a text area below it,
/// and the list over everything.
fn buildCompose(h: *Harness, cm: *Compose, top: f32) !void {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .gap = 10, .align_items = .stretch });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 20, .end = 60, .top = top, .bottom = 16 } });
    const row = c.siv_flex(txn, col, &.{ .gap = 12, .align_items = .center });
    const caption = text(txn, row, "To", .muted_fg);
    _ = c.siv_set_layout(txn, caption, &.{ .width = px(40) });
    cm.field = c.siv_text_field(txn, row, &.{ .placeholder = "Recipients", .placeholder_len = 10, .label = "To", .label_len = 2 });
    _ = c.siv_set_layout(txn, cm.field, &.{ .grow = 1, .shrink = 1, .basis = px(0) });
    _ = c.siv_on(txn, cm.field, .change, Compose.onChange, null, cm);
    cm.body = c.siv_text_field(txn, col, &.{ .text = "Lunch on Friday?", .text_len = 16, .label = "Message", .label_len = 7, .flags = .{ .multiline = true }, .rows = 3 });
    cm.list = c.siv_suggestion_list(txn, root, &.{ .anchor = cm.field });
    _ = c.siv_on(txn, cm.list, .select, Compose.onSelect, null, cm);
    _ = c.siv_on(txn, cm.list, .close, Log.onClose, null, &cm.log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_focus(cm.field));
    try h.settle();
}

fn typeText(h: *Harness, s: []const u8) !void {
    for (s) |ch| try h.typeKey(ch, &.{ch}, .{});
    try h.settle();
}

fn fieldText(cm: *const Compose, buf: []u8) ![]const u8 {
    var len: usize = 0;
    try ok(c.siv_node_get_text(cm.field, buf.ptr, buf.len, &len));
    return buf[0..len];
}

test "suggestions: keys and the pointer choose under a field that keeps the focus" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(420, 280, null, null);
    defer h.stop();
    var cm: Compose = .{};
    try buildCompose(&h, &cm, 20);
    try testing.expect(!try shown(cm.list));
    try testing.expect(try dumpHas(&h, "text_input \"To\" focused expanded=off"));

    // Typing shows the matches under the field, as wide as it, the first
    // highlighted; the field keeps the focus and says it is expanded.
    try typeText(&h, "ma");
    try testing.expect(try shown(cm.list));
    try testing.expectEqual(cm.field, c.siv_window_get_focus(h.window));
    try testing.expect(try dumpHas(&h, "text_input \"To\" focused expanded=on"));
    try testing.expectEqual(@as(f64, 0), try value(cm.list));
    const fr = try rect(cm.field);
    const lr = try rect(cm.list);
    try testing.expectApproxEqAbs(fr.x, lr.x, 0.01);
    try testing.expectApproxEqAbs(fr.width, lr.width, 0.01);
    try testing.expectApproxEqAbs(fr.y + fr.height + 4, lr.y, 0.01);
    try h.expectGolden("suggestions-below", 420, 280);
    // A list of list items, the highlighted one selected and announced.
    try testing.expect((try find(&h, .list, "Suggestions")) != null);
    const first = (try find(&h, .list_item, "Maya Okafor, maya@example.com")).?;
    try testing.expectEqual(t.Toggle.on, first.selected);
    try testing.expectEqual(@as(u32, 1), first.position);
    try testing.expectEqual(@as(u32, 4), first.set_size);
    try testing.expect((try find(&h, .status, "Maya Okafor, maya@example.com, 1 of 4")) != null);

    // Down and Up move the highlight, wrapping and skipping Max, whose
    // item is disabled; the caret stays where it was.
    try key(&h, ks.down);
    try testing.expectEqual(@as(f64, 1), try value(cm.list));
    try testing.expect((try find(&h, .status, "Mark Ito, mark@example.com, 2 of 4")) != null);
    try key(&h, ks.up);
    try key(&h, ks.up);
    try testing.expectEqual(@as(f64, 2), try value(cm.list));
    try key(&h, ks.down);
    try testing.expectEqual(@as(f64, 0), try value(cm.list));
    var caret: u32 = 0;
    var anchor: u32 = 0;
    try ok(c.siv_node_get_selection(cm.field, &caret, &anchor));
    try testing.expectEqual(@as(u32, 2), caret);

    // Enter chooses: the list reports select and hides; the field keeps
    // the focus.
    try key(&h, ks.down);
    try key(&h, ks.@"return");
    try testing.expectEqual(@as(u32, 1), cm.log.selects);
    try testing.expectEqual(@as(u32, 1), cm.log.index);
    try testing.expect(!try shown(cm.list));
    try testing.expectEqual(cm.field, c.siv_window_get_focus(h.window));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Mark Ito", try fieldText(&cm, &buf));
    // With the list closed, Enter and Down are the field's again.
    try key(&h, ks.down);
    try testing.expectEqual(@as(u32, 1), cm.log.selects);

    // Escape asks to close; a handler keeps it, then lets it go. The text
    // stays as typed.
    try ok(c.siv_txn_begin(h.window, &txn_slot));
    c.siv_set_text(txn_slot, cm.field, "", 0);
    try ok(c.siv_txn_commit(txn_slot));
    try typeText(&h, "m");
    cm.log.keep = true;
    try key(&h, ks.escape);
    try testing.expect(try shown(cm.list));
    cm.log.keep = false;
    try key(&h, ks.escape);
    try testing.expectEqual(@as(u32, 2), cm.log.closes);
    try testing.expect(!try shown(cm.list));
    try testing.expectEqualStrings("m", try fieldText(&cm, &buf));

    // The pointer: hovering highlights, a click chooses, and the focus
    // stays in the field all along.
    try typeText(&h, "a");
    const third = c.siv_widget_get_part(cm.list, .item, 2);
    const p = try center(third);
    try move(&h, p[0], p[1]);
    try testing.expectEqual(@as(f64, 2), try value(cm.list));
    try h.expectGolden("suggestions-hover", 420, 280);
    try h.click(p[0], p[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 2), cm.log.selects);
    try testing.expectEqual(@as(u32, 2), cm.log.index);
    try testing.expectEqual(cm.field, c.siv_window_get_focus(h.window));
    try testing.expectEqualStrings("Marta Díaz", try fieldText(&cm, &buf));
    // A click on a disabled item chooses nothing.
    try ok(c.siv_txn_begin(h.window, &txn_slot));
    c.siv_set_text(txn_slot, cm.field, "", 0);
    try ok(c.siv_txn_commit(txn_slot));
    try typeText(&h, "ma");
    const max = try center(c.siv_widget_get_part(cm.list, .item, 3));
    try h.click(max[0], max[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 2), cm.log.selects);
    try testing.expect(try shown(cm.list));

    // Tab chooses too, and Shift+Tab leaves the list for the focus.
    try key(&h, ks.tab);
    try testing.expectEqual(@as(u32, 3), cm.log.selects);
    try testing.expectEqual(cm.field, c.siv_window_get_focus(h.window));

    // Focus leaving the field closes the list.
    try ok(c.siv_txn_begin(h.window, &txn_slot));
    c.siv_set_text(txn_slot, cm.field, "", 0);
    try ok(c.siv_txn_commit(txn_slot));
    try typeText(&h, "a");
    try testing.expect(try shown(cm.list));
    try ok(c.siv_node_focus(cm.body));
    try h.settle();
    try testing.expect(!try shown(cm.list));
    try testing.expect(try dumpHas(&h, "text_input \"To\" expanded=off"));

    // The value moves the highlight; -1 is none, and Enter then is the
    // field's.
    try ok(c.siv_node_focus(cm.field));
    try ok(c.siv_txn_begin(h.window, &txn_slot));
    c.siv_set_text(txn_slot, cm.field, "", 0);
    try ok(c.siv_txn_commit(txn_slot));
    try typeText(&h, "ma");
    try ok(c.siv_txn_begin(h.window, &txn_slot));
    c.siv_widget_set_value(txn_slot, cm.list, 2);
    try ok(c.siv_txn_commit(txn_slot));
    try testing.expectEqual(@as(f64, 2), try value(cm.list));
    try ok(c.siv_txn_begin(h.window, &txn_slot));
    c.siv_widget_set_value(txn_slot, cm.list, -1);
    try ok(c.siv_txn_commit(txn_slot));
    try key(&h, ks.@"return");
    try testing.expectEqual(@as(u32, 3), cm.log.selects);
}

var txn_slot: t.Txn = .null;

test "suggestions: an anchor that is not a text field gives the list its keys and focus" {
    var h: Harness = .{};
    try h.start(300, 200, null, null);
    defer h.stop();
    var log: Log = .{};
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .gap = 8, .align_items = .start });
    const editor = c.siv_editor(txn, col, .{});
    _ = c.siv_set_layout(txn, editor, &.{ .width = px(200) });
    const other = c.siv_push_button(txn, col, &.{ .label = "Other", .label_len = 5 });
    const list = c.siv_suggestion_list(txn, root, &.{ .anchor = editor, .label = "Commands", .label_len = 8 });
    _ = c.siv_on(txn, list, .select, Log.onSelect, null, &log);
    for ([_][]const u8{ "open", "save", "quit" }) |s| _ = c.siv_suggestion_list_item(txn, list, &.{ .label = s.ptr, .label_len = s.len });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_focus(editor));
    try h.settle();
    try testing.expect((try find(&h, .list, "Commands")) != null);
    try key(&h, ks.down);
    try key(&h, ks.down);
    try key(&h, ks.@"return");
    try testing.expectEqual(@as(u32, 1), log.selects);
    try testing.expectEqual(@as(u32, 2), log.index);
    try testing.expect(!try shown(list));
    // Shown again, it closes when the focus leaves the anchor.
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_suggestion_list_item(txn, list, &.{ .label = "help", .label_len = 4 });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expect(try shown(list));
    try ok(c.siv_node_focus(other));
    try h.settle();
    try testing.expect(!try shown(list));
}

test "suggestions: above the field at the window's bottom, inside it, and mirrored in RTL" {
    // Near the bottom only the room above takes the list.
    {
        var h: Harness = .{ .golden = "test/golden/widgets" };
        try h.start(420, 280, null, null);
        defer h.stop();
        var cm: Compose = .{};
        try buildCompose(&h, &cm, 150);
        try typeText(&h, "ma");
        const fr = try rect(cm.field);
        const lr = try rect(cm.list);
        try testing.expectApproxEqAbs(fr.y - 4, lr.y + lr.height, 0.01);
        try testing.expect(lr.y >= 0);
        try h.expectGolden("suggestions-above", 420, 280);
    }
    // Right to left: aligned with the field's start edge, on the right.
    {
        var h: Harness = .{ .golden = "test/golden/widgets" };
        try h.startWith(.{ .width = 420, .height = 280, .flags = .{ .rtl = true } });
        defer h.stop();
        var cm: Compose = .{};
        try buildCompose(&h, &cm, 20);
        try typeText(&h, "ma");
        const fr = try rect(cm.field);
        const lr = try rect(cm.list);
        try testing.expectApproxEqAbs(fr.x + fr.width, lr.x + lr.width, 0.01);
        try h.expectGolden("suggestions-rtl", 420, 280);
    }
    // Room on neither side: the roomier one, the list as tall as its room.
    {
        var h: Harness = .{};
        try h.start(420, 150, null, null);
        defer h.stop();
        var cm: Compose = .{};
        try buildCompose(&h, &cm, 40);
        try typeText(&h, "ma");
        const fr = try rect(cm.field);
        const lr = try rect(cm.list);
        try testing.expect(lr.y >= fr.y + fr.height);
        try testing.expectApproxEqAbs(@as(f32, 150), lr.y + lr.height, 0.01);
    }
}

test "anchor: a stack child follows its anchor, flips, and slides inside the stack" {
    var h: Harness = .{};
    try h.start(300, 200, null, null);
    defer h.stop();
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .align_items = .end });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 10, .end = 10, .top = 30, .bottom = 10 } });
    const target = c.siv_box(txn, col);
    _ = c.siv_set_layout(txn, target, &.{ .width = px(40), .height = px(20) });
    const pop = c.siv_box(txn, root);
    _ = c.siv_set_layout(txn, pop, &.{ .width = px(120), .height = px(50) });
    c.siv_set_anchor(txn, pop, &.{ .anchor = target, .gap = 2 });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    // Below the target at its start edge, slid left to stay in the stack;
    // the stack does not grow for it.
    var r = try rect(pop);
    try testing.expectEqual(t.Rect{ .x = 180, .y = 52, .width = 120, .height = 50 }, r);
    // Above, as asked; below when only that fits.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_anchor(txn, pop, &.{ .anchor = target, .gap = 2, .flags = .{ .above = true } });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    r = try rect(pop);
    try testing.expectEqual(@as(f32, 52), r.y);
    // The target moves down; the overlay follows in the same layout.
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 10, .end = 10, .top = 120, .bottom = 10 } });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    r = try rect(pop);
    try testing.expectEqual(@as(f32, 120 - 2 - 50), r.y);
    // As wide as the anchor.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_anchor(txn, pop, &.{ .anchor = target, .flags = .{ .match_width = true } });
    _ = c.siv_set_layout(txn, pop, &.{ .height = px(50) });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    r = try rect(pop);
    try testing.expectEqual(t.Rect{ .x = 250, .y = 140, .width = 40, .height = 50 }, r);
    // Cleared, the stack places it again; an anchor inside the node, or
    // the node itself, is refused.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_anchor(txn, pop, null);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    r = try rect(pop);
    try testing.expectEqual(@as(f32, 0), r.y);
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_anchor(txn, pop, &.{ .anchor = pop });
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_anchor(txn, col, &.{ .anchor = target });
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
}
