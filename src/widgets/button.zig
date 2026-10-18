//! Push buttons and toggle buttons: a flex row with a centered label and
//! an optional themed icon before it (D19), or the icon alone with the
//! label as the accessible name, its fill following the pointer (rest,
//! hover, pressed) in themed colors, the icon in the label's.
//! Clicks, Enter, Space, and assistive technology activate it through
//! the core's default action (D16); a toggle button's default activate
//! handler flips it and reports `change`.

const std = @import("std");
const w = @import("widgets.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Button = extern struct {
    hdr: w.Header,
    style: siv.ButtonStyle,
    /// Toggle buttons: pressed.
    on: bool = false,
    root: Node,
    label: Node,
    /// Menu buttons: the menu.
    menu: Node = .null,
    /// Menu buttons: the menu is open.
    expanded: bool = false,
    /// The icon's image node, and a hidden text node holding its name
    /// (the image node's setter needs it again to recolor it).
    icon: Node = .null,
    icon_name: Node = .null,
    /// Only the icon shows, when there is one; the label names the
    /// button.
    icon_only: bool = false,
    /// The button set its label as its tooltip.
    auto_tooltip: bool = false,
    /// The keysym that presses it in a dialog; 0 for none.
    mnemonic: u32 = 0,
    /// A canvas drawing a glyph in place of an icon (`glyphButton`), and
    /// which one, for its draw callback.
    glyph: Node = .null,
    glyph_kind: u8 = 0,
};

pub export fn siv_push_button(txn: Txn, parent: Node, desc: ?*const siv.ButtonDesc) Node {
    const d = w.readDesc(siv.ButtonDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@backingInt(d.style) < 0 or @backingInt(d.style) > 3) return w.fail(txn, .error_unsupported);
    if (!validFlags(d.flags)) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const icon = w.str(d.icon, d.icon_len) orelse return w.fail(txn, .error_invalid_argument);
    return w.bindAction(txn, withMnemonic(txn, build(txn, parent, .button, label, icon, d.style, d.flags, false), d.mnemonic), d.action, d.action_target);
}

fn withMnemonic(txn: Txn, root: Node, mnemonic: u32) Node {
    if (root == .null) return .null;
    const st = w.stateOf(Button, root, &.{ .button, .toggle_button }).?;
    st.mnemonic = mnemonic;
    w.underlineMnemonic(txn, st.label, mnemonic);
    return root;
}

pub export fn siv_toggle_button(txn: Txn, parent: Node, desc: ?*const siv.ToggleDesc) Node {
    const d = w.readDesc(siv.ToggleDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (!validFlags(d.flags) or @backingInt(d.checked) < 0 or @backingInt(d.checked) > 2) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const icon = w.str(d.icon, d.icon_len) orelse return w.fail(txn, .error_invalid_argument);
    return w.bindAction(txn, withMnemonic(txn, build(txn, parent, .toggle_button, label, icon, .default, d.flags, d.checked == .on), d.mnemonic), d.action, d.action_target);
}

pub export fn siv_menu_button(txn: Txn, parent: Node, desc: ?*const siv.ButtonDesc) Node {
    const d = w.readDesc(siv.ButtonDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@backingInt(d.style) < 0 or @backingInt(d.style) > 3) return w.fail(txn, .error_unsupported);
    if (!validFlags(d.flags)) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const icon = w.str(d.icon, d.icon_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = build(txn, parent, .menu_button, label, icon, d.style, d.flags, false);
    if (root == .null) return .null;
    const st = w.stateOf(Button, root, &.{.menu_button}).?;
    st.menu = @import("menu.zig").createModel(txn, root, label, root);
    w.onDefault(txn, root, .activate, onMenuActivate, st);
    w.onDefault(txn, root, .key, onMenuKey, st);
    return root;
}

fn onMenuActivate(ud: ?*anyopaque, node: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Button = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .pass;
    _ = c.siv_menu_open(st.menu, node);
    return .handled;
}

/// Down opens the menu too, as in WAI-ARIA's menu button.
fn onMenuKey(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Button = @ptrCast(@alignCast(ud.?));
    const e = ev;
    if (st.hdr.disabled or !e.flags.pressed or e.keysym != w.keysym.down) return .pass;
    _ = c.siv_menu_open(st.menu, node);
    return .handled;
}

/// Shows whether a menu button's menu is open.
pub fn setExpanded(button: Node, expanded: bool) void {
    const st = w.stateOf(Button, button, &.{.menu_button}) orelse return;
    if (st.expanded == expanded) return;
    st.expanded = expanded;
    const txn = w.begin(w.windowOf(button)) orelse return;
    apply(txn, st);
    _ = w.commit(txn);
}

/// Disabled, and icon_only for buttons that have an icon.
pub fn validFlags(f: siv.WidgetFlags) bool {
    return @as(u32, @bitCast(f)) & ~@as(u32, 3) == 0;
}

fn build(txn: Txn, parent: Node, kind: w.Kind, label: []const u8, icon: []const u8, style: siv.ButtonStyle, flags: siv.WidgetFlags, on: bool) Node {
    const root = c.siv_flex(txn, parent, &.{ .axis = .row, .justify = .center, .align_items = .center, .gap = tk.icon_gap });
    if (root == .null) return .null;
    const text = c.siv_text(txn, root, label.ptr, label.len);
    const st = w.create(Button, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = kind, .disabled = flags.disabled }, .style = style, .on = on, .root = root, .label = text, .icon_only = flags.icon_only };
    if (icon.len != 0) setIconNodes(txn, st, icon);
    layoutIcon(txn, st);
    w.onDefault(txn, root, .pointer, onPointer, st);
    if (kind == .toggle_button) w.onDefault(txn, root, .activate, onActivate, st);
    switch (kind) {
        .toggle_button => w.setInterface(txn, root, Button, st, .{ .set_label = setLabel, .set_icon = setIcon, .apply = apply, .set_value = setValue, .get_value = value }),
        .menu_button => w.setInterface(txn, root, Button, st, .{ .set_label = setLabel, .set_icon = setIcon, .apply = apply, .get_part = menuPart }),
        else => w.setInterface(txn, root, Button, st, .{ .set_label = setLabel, .set_icon = setIcon, .apply = apply }),
    }
    apply(txn, st);
    return root;
}

/// A menu button's menu.
fn menuPart(st: *const Button, part: siv.WidgetPart, _: u32) Node {
    return if (part == .menu) st.menu else .null;
}

/// A flat button showing a glyph that `draw` draws (16 pixels square,
/// with `st.glyph_kind` saying which, in `foreground`'s color), alone, the
/// label naming it as an icon-only button's does: a header bar's back
/// button and window controls, which must show without an icon theme.
pub fn glyphButton(txn: Txn, parent: Node, label: []const u8, kind: u8, draw: siv.DrawFn) Node {
    const root = build(txn, parent, .button, label, "", .flat, .{ .icon_only = true }, false);
    if (root == .null) return .null;
    const st = w.stateOf(Button, root, &.{.button}).?;
    st.glyph_kind = kind;
    st.glyph = c.siv_canvas(txn, root, &.{ .user_data = st, .draw = draw, .width = tk.icon_size, .height = tk.icon_size });
    _ = c.siv_set_semantics(txn, st.glyph, &.{ .role = .none });
    layoutIcon(txn, st);
    apply(txn, st);
    return root;
}

/// The color of the label, icon, or glyph for the button's state.
pub fn foreground(st: *const Button) siv.ColorToken {
    const filled = st.style == .primary or (st.hdr.kind == .toggle_button and st.on);
    if (st.hdr.disabled) return .disabled_fg;
    return switch (st.style) {
        .destructive => .destructive_fg,
        else => if (filled) .accent_fg else .control_fg,
    };
}

/// Shows the state: fill, border, label color, and semantics.
pub fn apply(txn: Txn, st: *Button) void {
    const h = st.hdr;
    const filled = st.style == .primary or (st.hdr.kind == .toggle_button and st.on);
    var bg: siv.ColorToken = switch (st.style) {
        .flat => .none,
        .destructive => .destructive,
        else => if (filled) .accent else .control_bg,
    };
    var fg: siv.ColorToken = switch (st.style) {
        .destructive => .destructive_fg,
        else => if (filled) .accent_fg else .control_fg,
    };
    if (h.disabled) {
        bg = if (st.style == .flat) .none else .control_bg;
        fg = .disabled_fg;
    } else if (h.pressed) {
        bg = if (filled) .accent_active else if (st.style == .destructive) .destructive else .control_active;
    } else if (h.hover) {
        bg = if (filled) .accent_hover else if (st.style == .destructive) .destructive else .control_hover;
    }
    const bordered = st.style == .default and !filled;
    _ = c.siv_set_visual(txn, st.root, &.{
        .radius = .{ .top_start = tk.radius, .top_end = tk.radius, .bottom_end = tk.radius, .bottom_start = tk.radius },
        // A disabled flat button stays flat: its dimmed label says enough.
        .border_width = if (bordered or (h.disabled and st.style != .flat)) tk.border else 0,
        .border_token = .border,
        .background_token = bg,
    });
    _ = c.siv_set_text_style(txn, st.label, &w.textStyle(fg, .body));
    if (st.icon != .null) w.setIcon(txn, st.icon, st.icon_name, tk.icon_size, fg);
    if (st.glyph != .null) c.siv_invalidate(txn, st.glyph);
    // A hidden label does not name the button: say it outright.
    var buf: [1024]u8 = undefined;
    const name = if (alone(st)) w.textOf(st.label, &buf) else "";
    _ = c.siv_set_semantics(txn, st.root, &.{
        .label = name.ptr,
        .label_len = name.len,
        .role = if (h.kind == .toggle_button) .toggle_button else .button,
        .pressed = if (h.kind == .toggle_button) (if (st.on) .on else .off) else .unset,
        .expanded = if (h.kind == .menu_button) (if (st.expanded) .on else .off) else .unset,
        .flags = .{ .focusable = !h.disabled, .disabled = h.disabled },
    });
}

pub fn setLabel(txn: Txn, st: *Button, label: []const u8) void {
    _ = c.siv_set_text(txn, st.label, label.ptr, label.len);
    w.underlineMnemonic(txn, st.label, st.mnemonic);
    if (alone(st)) {
        apply(txn, st);
        showTooltip(txn, st);
    }
}

/// A button showing only its icon shows its label as a tooltip (D17),
/// set when the label or icon changes so that an application's own
/// tooltip stays until then.
fn showTooltip(txn: Txn, st: *Button) void {
    var buf: [1024]u8 = undefined;
    const tip = if (alone(st)) w.textOf(st.label, &buf) else "";
    if (tip.len == 0 and !st.auto_tooltip) return;
    c.siv_set_tooltip(txn, st.root, tip.ptr, tip.len);
    st.auto_tooltip = tip.len != 0;
}

/// Shows another icon, or none.
pub fn setIcon(txn: Txn, st: *Button, icon: []const u8) void {
    if (st.icon == .null) {
        if (icon.len == 0) return;
        setIconNodes(txn, st, icon);
    } else _ = c.siv_set_text(txn, st.icon_name, icon.ptr, icon.len);
    _ = c.siv_set_visual(txn, st.icon, &.{ .flags = .{ .hidden = icon.len == 0 } });
    layoutIcon(txn, st);
    apply(txn, st);
}

/// The icon's image node before the label, and its name in a hidden
/// text node.
fn setIconNodes(txn: Txn, st: *Button, icon: []const u8) void {
    st.icon = c.siv_image_view(txn, st.root, &.{ .icon = icon.ptr, .icon_len = icon.len, .icon_size = tk.icon_size });
    _ = c.siv_move(txn, st.icon, st.root, st.label);
    st.icon_name = w.hiddenText(txn, st.root, icon);
}

/// Only the icon shows.
fn alone(st: *const Button) bool {
    if (st.icon_only and st.glyph != .null) return true;
    if (!st.icon_only or st.icon == .null) return false;
    var len: usize = 0;
    return c.siv_node_get_text(st.icon_name, null, 0, &len) == .ok and len != 0;
}

/// Padding, and the label hidden when the icon is alone, which sits in a
/// square button.
fn layoutIcon(txn: Txn, st: *Button) void {
    const square = alone(st);
    const pad_x = if (square) (tk.control_height - tk.icon_size) / 2 else tk.pad_x;
    _ = c.siv_set_default_layout(txn, st.root, &.{
        .min_height = tk.control_height,
        .min_width = if (square) tk.control_height else 0,
        .padding = .{ .start = pad_x, .end = pad_x, .top = tk.pad_y, .bottom = tk.pad_y },
    });
    _ = c.siv_set_visual(txn, st.label, &.{ .flags = .{ .hidden = square } });
    showTooltip(txn, st);
}

pub fn value(st: *const Button) f64 {
    return if (st.on) 1 else 0;
}

pub fn setValue(txn: Txn, st: *Button, v: f64) void {
    st.on = v >= 0.5;
    apply(txn, st);
}

/// Hover and press feedback; never consumes the event, so the core still
/// focuses and activates (D16).
pub fn onPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Button = @ptrCast(@alignCast(ud.?));
    const e = ev;
    if (feedback(&st.hdr, e)) {
        const txn = w.begin(e.window) orelse return .pass;
        apply(txn, st);
        _ = w.commit(txn);
    }
    return .pass;
}

/// Updates hover and pressed from a pointer event; returns whether they
/// changed.
pub fn feedback(h: *w.Header, e: *const siv.Event) bool {
    if (h.disabled) return false;
    const hover, const pressed = switch (e.phase) {
        .enter => .{ true, h.pressed },
        .leave => .{ false, false },
        .down => .{ h.hover, e.button == .primary or h.pressed },
        .up, .cancel => .{ h.hover, false },
        else => return false,
    };
    if (hover == h.hover and pressed == h.pressed) return false;
    h.hover = hover;
    h.pressed = pressed;
    return true;
}

/// Flips the state. Stop rather than handled: the activation goes on to
/// the action the button is bound to (D34), which brings it back in line.
fn onActivate(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Button = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .pass;
    const txn = w.begin(ev.window) orelse return .pass;
    st.on = !st.on;
    apply(txn, st);
    if (!w.commit(txn)) return .stop;
    w.emitChange(node, value(st), 0);
    return .stop;
}
