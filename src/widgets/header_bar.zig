//! Header bars (D17, D22): a bar with a centered title between a start
//! box and an end box that the application fills with controls, or,
//! with `expand_content`, sides that size to their controls around
//! content that takes the rest (a path bar in place of a title). It has
//! no background of its own, so it takes the color of what it sits on (a
//! page, a sidebar), and a separator under it.
//!
//! While the window draws its own decorations (siv_window_get_controls
//! is not empty: the compositor offers no server-side decorations, or the
//! application asked for client-side ones) the header bar is the title
//! bar: the window controls the compositor allows show at its end edge,
//! a press on the bar itself (not on a control in it) moves the window, a
//! double click maximizes or restores it, and a secondary click shows the
//! compositor's window menu. Settings events with `window_changed`
//! bring the controls and the maximize glyph in line.
//!
//! Inside a navigation page other than a stack's first, a back button
//! comes first in the start box; it asks the page to close, which is
//! going back (navigation.zig). Without a title of its own the bar
//! shows the page's.
//!
//! Glyphs (back, minimize, maximize, restore, close) are drawn, not
//! themed icons: siv ships no icons, and a desktop without the icon theme
//! would show blank controls.

const std = @import("std");
const w = @import("widgets.zig");
const button = @import("button.zig");
const navigation = @import("navigation.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const HeaderBar = extern struct {
    hdr: w.Header,
    root: Node,
    bar: Node,
    start: Node,
    center: Node,
    title: Node,
    end_box: Node,
    end: Node,
    controls: Node,
    minimize: Node = .null,
    maximize: Node = .null,
    close: Node = .null,
    back: Node = .null,
    /// The navigation page it sits in, and whether it shows that page's
    /// title (it has none of its own).
    page: Node = .null,
    page_title: bool = false,
    no_controls: bool = false,
    /// It has an accessible name of its own, which titles do not change.
    named: bool = false,
};

const Glyph = enum(u8) { back, minimize, maximize, restore, close };

pub export fn siv_header_bar(txn: Txn, parent: Node, desc: ?*const siv.HeaderBarDesc) Node {
    const d = w.readDesc(siv.HeaderBarDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 3) != 0) return w.fail(txn, .error_unsupported);
    var title = w.str(d.title, d.title_len) orelse return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = .column, .align_items = .stretch });
    if (root == .null) return .null;
    const st = w.create(HeaderBar, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .header_bar }, .root = root, .bar = .null, .start = .null, .center = .null, .title = .null, .end_box = .null, .end = .null, .controls = .null, .no_controls = d.flags.no_window_controls, .named = label.len != 0 };
    // The sides share what the title leaves equally, so the title is
    // centered while both fit; or they size to their controls and the
    // content takes the rest.
    const expand = d.flags.expand_content;
    const side: siv.LayoutDesc = if (expand) .{ .flags = .{ .no_shrink = true } } else .{ .grow = 1, .basis = w.px(0) };
    st.bar = c.siv_flex(txn, root, &.{ .axis = .row, .align_items = .center, .gap = tk.bar_pad });
    _ = c.siv_set_layout(txn, st.bar, &.{ .min_height = tk.bar_height - 1, .padding = .{ .start = tk.bar_pad, .end = tk.bar_pad, .top = tk.bar_pad, .bottom = tk.bar_pad } });
    st.start = c.siv_flex(txn, st.bar, &.{ .axis = .row, .align_items = .center, .gap = tk.bar_pad });
    _ = c.siv_set_layout(txn, st.start, &side);
    st.center = c.siv_flex(txn, st.bar, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    _ = c.siv_set_layout(txn, st.center, if (expand) &.{ .grow = 1, .basis = w.px(0) } else &.{ .shrink = 1 });
    st.end_box = c.siv_flex(txn, st.bar, &.{ .axis = .row, .justify = .end, .align_items = .center, .gap = tk.bar_pad });
    _ = c.siv_set_layout(txn, st.end_box, &side);
    st.end = c.siv_flex(txn, st.end_box, &.{ .axis = .row, .align_items = .center, .gap = tk.bar_pad });
    st.controls = c.siv_flex(txn, st.end_box, &.{ .axis = .row, .align_items = .center, .gap = 2 });
    const rule = c.siv_box(txn, root);
    _ = c.siv_set_layout(txn, rule, &.{ .height = w.px(tk.border) });
    _ = c.siv_set_visual(txn, rule, &.{ .background_token = .separator });

    var buf: [1024]u8 = undefined;
    if (navigation.enclosingPage(parent)) |pg| {
        st.page = pg.root;
        if (title.len == 0) {
            title = navigation.titleOf(pg.root, &buf);
            st.page_title = true;
            pg.bar = root;
        }
        if (pg.index > 0) {
            st.back = button.glyphButton(txn, st.start, "Back", @intFromEnum(Glyph.back), drawGlyph);
            c.siv_set_shortcut(txn, st.back, .{ .key = navigation.backArrow(parent), .modifiers = .{ .alt = true } });
            w.onDefault(txn, st.back, .activate, onBack, st);
        }
    }
    st.title = c.siv_text(txn, st.center, title.ptr, title.len);
    _ = c.siv_set_text_style(txn, st.title, &.{ .color_token = .window_fg, .size_role = .body, .weight = .bold, .flags = .{ .no_wrap = true, .ellipsize = true } });
    // The bar carries the title as its name, or its own.
    _ = c.siv_set_semantics(txn, st.title, &.{ .role = .none });
    if (st.named) _ = c.siv_set_semantics(txn, root, &.{ .role = .toolbar, .label = label.ptr, .label_len = label.len });
    setTitle(txn, st, title);

    st.minimize = button.glyphButton(txn, st.controls, "Minimize", @intFromEnum(Glyph.minimize), drawGlyph);
    st.maximize = button.glyphButton(txn, st.controls, "Maximize", @intFromEnum(Glyph.maximize), drawGlyph);
    st.close = button.glyphButton(txn, st.controls, "Close", @intFromEnum(Glyph.close), drawGlyph);
    for ([_]Node{ st.minimize, st.maximize, st.close }) |b| w.onDefault(txn, b, .activate, onControl, st);
    applyControls(txn, st);

    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .settings, onSettings, st);
    w.setInterface(txn, root, HeaderBar, st, .{ .set_label = setLabel, .get_part = part });
    return root;
}

fn part(st: *const HeaderBar, p: siv.WidgetPart, _: u32) Node {
    return switch (p) {
        .start => st.start,
        .end => st.end,
        .content => st.center,
        else => .null,
    };
}

fn setTitle(txn: Txn, st: *HeaderBar, title: []const u8) void {
    _ = c.siv_set_text(txn, st.title, title.ptr, title.len);
    _ = c.siv_set_visual(txn, st.title, &.{ .flags = .{ .hidden = title.len == 0 } });
    if (!st.named) _ = c.siv_set_semantics(txn, st.root, &.{ .role = .toolbar, .label = title.ptr, .label_len = title.len });
}

/// The application's title replaces the page's for good.
fn setLabel(txn: Txn, st: *HeaderBar, title: []const u8) void {
    st.page_title = false;
    setTitle(txn, st, title);
}

/// The page it shows the title of was renamed.
pub fn pageTitle(txn: Txn, bar: Node, title: []const u8) void {
    const st = w.stateOf(HeaderBar, bar, &.{.header_bar}) orelse return;
    if (st.page_title) setTitle(txn, st, title);
}

/// Shows the window controls the window draws itself, and the maximize
/// button's glyph for its state.
fn applyControls(txn: Txn, st: *HeaderBar) void {
    const window = w.windowOf(st.root);
    var have: siv.WindowControls = .{};
    if (!st.no_controls) _ = c.siv_window_get_controls(window, &have);
    var states: siv.WindowStates = .{};
    _ = c.siv_window_get_states(window, &states);
    _ = c.siv_set_hidden(txn, st.controls, !(have.close or have.minimize or have.maximize));
    _ = c.siv_set_hidden(txn, st.minimize, !have.minimize);
    _ = c.siv_set_hidden(txn, st.maximize, !have.maximize);
    _ = c.siv_set_hidden(txn, st.close, !have.close);
    if (w.stateOf(button.Button, st.maximize, &.{.button})) |b| {
        const kind: Glyph = if (states.maximized) .restore else .maximize;
        if (b.glyph_kind != @intFromEnum(kind)) {
            b.glyph_kind = @intFromEnum(kind);
            button.setLabel(txn, b, if (kind == .restore) "Restore" else "Maximize");
            c.siv_invalidate(txn, b.glyph);
        }
    }
}

fn onSettings(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *HeaderBar = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.window_changed) return .pass;
    const txn = w.begin(ev.window) orelse return .pass;
    applyControls(txn, st);
    _ = w.commit(txn);
    return .pass;
}

fn onBack(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *HeaderBar = @ptrCast(@alignCast(ud.?));
    if (st.page != .null) navigation.askClose(st.page);
    return .handled;
}

fn onControl(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *HeaderBar = @ptrCast(@alignCast(ud.?));
    const window = ev.window;
    if (node == st.close) {
        _ = c.siv_window_request_close(window);
    } else if (node == st.minimize) {
        _ = c.siv_window_minimize(window);
    } else if (node == st.maximize) {
        toggleMaximized(window);
    }
    return .handled;
}

fn toggleMaximized(window: siv.Window) void {
    var states: siv.WindowStates = .{};
    _ = c.siv_window_get_states(window, &states);
    _ = c.siv_window_set_maximized(window, !states.maximized);
}

/// The title bar: presses on the bar itself, its boxes, or the title
/// move the window, maximize it on a double click, and show the window
/// menu on a secondary click; presses on controls are theirs.
fn onPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *HeaderBar = @ptrCast(@alignCast(ud.?));
    if (ev.phase != .down) return .pass;
    const t = ev.target;
    const own = for ([_]Node{ st.root, st.bar, st.start, st.center, st.title, st.end_box, st.end, st.controls }) |n| {
        if (t == n) break true;
    } else false;
    if (!own) return .pass;
    var have: siv.WindowControls = .{};
    if (st.no_controls or c.siv_window_get_controls(ev.window, &have) != .ok) return .pass;
    if (!(have.close or have.minimize or have.maximize)) return .pass;
    switch (ev.button) {
        .primary => if (ev.clicks == 2) {
            if (have.maximize) toggleMaximized(ev.window);
        } else {
            _ = c.siv_window_begin_move(ev.window);
        },
        .secondary => {
            if (!have.menu) return .pass;
            var r: siv.Rect = undefined;
            if (c.siv_node_get_rect(st.root, &r) != .ok) return .pass;
            _ = c.siv_window_show_menu(ev.window, r.x + ev.x, r.y + ev.y);
        },
        else => return .pass,
    }
    return .handled;
}

/// Draws a glyph in a 16-pixel square, in the button's color: chevrons
/// and window controls are strokes, as the symbolic icons beside them.
fn drawGlyph(ud: ?*anyopaque, node: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const b: *button.Button = @ptrCast(@alignCast(ud.?));
    const col = w.color(w.windowOf(node), button.foreground(b));
    const s = @min(width, height) / 16;
    const ox = (width - 16 * s) / 2;
    const oy = (height - 16 * s) / 2;
    const P = struct {
        fn at(dr: siv.Draw, x: f32, y: f32, first: bool, sc: f32, x0: f32, y0: f32) void {
            if (first) c.siv_draw_move_to(dr, x0 + x * sc, y0 + y * sc) else c.siv_draw_line_to(dr, x0 + x * sc, y0 + y * sc);
        }
    };
    switch (@as(Glyph, @enumFromInt(b.glyph_kind))) {
        .back => {
            // Points toward the start edge.
            const rtl = w.isRtl(node);
            const tip: f32 = if (rtl) 10.5 else 5.5;
            const tail: f32 = if (rtl) 5.5 else 10.5;
            P.at(draw, tail, 3, true, s, ox, oy);
            P.at(draw, tip, 8, false, s, ox, oy);
            P.at(draw, tail, 13, false, s, ox, oy);
        },
        .minimize => {
            P.at(draw, 4, 11.5, true, s, ox, oy);
            P.at(draw, 12, 11.5, false, s, ox, oy);
        },
        .maximize => {
            P.at(draw, 4, 4, true, s, ox, oy);
            P.at(draw, 12, 4, false, s, ox, oy);
            P.at(draw, 12, 12, false, s, ox, oy);
            P.at(draw, 4, 12, false, s, ox, oy);
            c.siv_draw_close(draw);
        },
        .restore => {
            P.at(draw, 3.5, 6.5, true, s, ox, oy);
            P.at(draw, 9.5, 6.5, false, s, ox, oy);
            P.at(draw, 9.5, 12.5, false, s, ox, oy);
            P.at(draw, 3.5, 12.5, false, s, ox, oy);
            c.siv_draw_close(draw);
            P.at(draw, 6.5, 6.5, true, s, ox, oy);
            P.at(draw, 6.5, 3.5, false, s, ox, oy);
            P.at(draw, 12.5, 3.5, false, s, ox, oy);
            P.at(draw, 12.5, 9.5, false, s, ox, oy);
            P.at(draw, 9.5, 9.5, false, s, ox, oy);
        },
        .close => {
            P.at(draw, 4.5, 4.5, true, s, ox, oy);
            P.at(draw, 11.5, 11.5, false, s, ox, oy);
            P.at(draw, 11.5, 4.5, true, s, ox, oy);
            P.at(draw, 4.5, 11.5, false, s, ox, oy);
        },
    }
    c.siv_draw_stroke(draw, &.{ .width = tk.glyph_stroke, .join = .round, .cap = .round }, &.{ .color = col });
}
