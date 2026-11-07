//! Chips (D22): a label, optionally after an icon, in a pill: neutral on
//! the control color, or tinted with a hue (display.tintOf), with the
//! surface's text color on it. A clickable chip is a button the
//! application handles (`activate`); a removable one has a remove button
//! at its end, and it, Delete, or BackSpace report `close`, whose default
//! handler removes the chip. A chip that is removable and not clickable
//! removes itself when activated too, as a filter a click takes away.
//! Interactive chips are focusable (the core's ring shows focus) and show
//! hover with a border in their hue or the border color, and press with
//! the pressed control color or a stronger border.

const std = @import("std");
const w = @import("widgets.zig");
const display = @import("display.zig");
const button = @import("button.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Chip = extern struct {
    hdr: w.Header,
    root: Node,
    label: Node,
    icon: Node = .null,
    icon_name: Node = .null,
    remove: Node = .null,
    remove_hover: bool = false,
    clickable: bool,
    removable: bool,
    color: siv.ColorToken,
};

pub export fn siv_chip(txn: Txn, parent: Node, desc: ?*const siv.ChipDesc) Node {
    const d = w.readDesc(siv.ChipDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 7) != 0) return w.fail(txn, .error_unsupported);
    if (!display.validToken(d.color)) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const icon = w.str(d.icon, d.icon_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = .row, .align_items = .center, .gap = tk.icon_gap });
    if (root == .null) return .null;
    const st = w.create(Chip, txn, root) orelse return .null;
    st.* = .{
        .hdr = .{ .kind = .chip, .disabled = d.flags.disabled },
        .root = root,
        .label = c.siv_text(txn, root, label.ptr, label.len),
        .clickable = d.flags.clickable,
        .removable = d.flags.removable,
        .color = d.color,
    };
    if (icon.len != 0) setIconNodes(txn, st, icon);
    if (st.removable) {
        st.remove = c.siv_canvas(txn, root, &.{ .user_data = st, .draw = drawRemove, .width = tk.chip_remove, .height = tk.chip_remove });
        _ = c.siv_on_default(txn, st.remove, .activate, onRemoveActivate, null, w.handleData(root));
        _ = c.siv_on_default(txn, st.remove, .pointer, onRemovePointer, null, st);
        _ = c.siv_set_cursor(txn, st.remove, .pointer);
        _ = c.siv_set_semantics(txn, st.remove, &.{ .role = .button, .label = "Remove", .label_len = 6 });
    }
    _ = c.siv_set_default_layout(txn, root, &.{
        .min_height = tk.chip_height,
        .padding = .{ .start = tk.chip_pad_x, .end = if (st.removable) (tk.chip_height - tk.chip_remove) / 2 else tk.chip_pad_x },
    });
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .key, onKey, st);
    w.onDefault(txn, root, .close, onClose, st);
    if (st.removable and !st.clickable) w.onDefault(txn, root, .activate, onActivate, st);
    if (st.clickable or st.removable) _ = c.siv_set_cursor(txn, root, .pointer);
    w.setInterface(txn, root, Chip, st, .{ .set_label = setLabel, .set_icon = setIcon, .apply = apply });
    apply(txn, st);
    return root;
}

fn interactive(st: *const Chip) bool {
    return (st.clickable or st.removable) and !st.hdr.disabled;
}

pub fn apply(txn: Txn, st: *Chip) void {
    const h = st.hdr;
    const tinted = st.color != .none;
    var fill: siv.ColorToken = if (tinted) display.tintOf(st.color) else .control_bg;
    // Hover and press show as a border in the chip's hue (its tint's
    // solid color) or the border color; a neutral chip also darkens.
    // A neutral chip keeps an outline, since control_bg can be the
    // surface's own color (dark cards).
    var edge: siv.ColorToken = if (tinted) .none else .border;
    var edge_width: f32 = tk.border;
    if (interactive(st) and (h.hover or h.pressed)) {
        edge = if (tinted) st.color else .border;
        if (h.pressed) {
            if (tinted) edge_width = 2 * tk.border else fill = .control_active;
        } else if (!tinted) fill = .control_hover;
    }
    _ = c.siv_set_visual(txn, st.root, &.{
        .background_token = fill,
        .border_token = edge,
        .border_width = edge_width,
        .radius = w.corners(tk.chip_height / 2),
    });
    const fg: siv.ColorToken = if (h.disabled) .disabled_fg else if (tinted) .view_fg else .control_fg;
    _ = c.siv_set_text_style(txn, st.label, &.{ .color_token = fg, .size_role = .caption, .weight = .medium, .flags = .{ .no_wrap = true } });
    if (st.icon != .null) w.setIcon(txn, st.icon, st.icon_name, tk.icon_size, fg);
    if (st.remove != .null) {
        _ = c.siv_set_semantics(txn, st.remove, &.{ .role = .button, .label = "Remove", .label_len = 6, .flags = .{ .disabled = h.disabled } });
        c.siv_invalidate(txn, st.remove);
    }
    var buf: [1024]u8 = undefined;
    const name = w.textOf(st.label, &buf);
    _ = c.siv_set_semantics(txn, st.root, &.{
        .role = if (st.clickable or st.removable) .button else .default,
        .label = name.ptr,
        .label_len = name.len,
        .description = if (st.removable) "Delete removes it" else "",
        .description_len = if (st.removable) 17 else 0,
        .flags = .{ .focusable = interactive(st), .disabled = h.disabled },
    });
}

fn setLabel(txn: Txn, st: *Chip, label: []const u8) void {
    _ = c.siv_set_text(txn, st.label, label.ptr, label.len);
    apply(txn, st);
}

fn setIcon(txn: Txn, st: *Chip, icon: []const u8) void {
    if (st.icon == .null) {
        if (icon.len == 0) return;
        setIconNodes(txn, st, icon);
    } else _ = c.siv_set_text(txn, st.icon_name, icon.ptr, icon.len);
    _ = c.siv_set_visual(txn, st.icon, &.{ .flags = .{ .hidden = icon.len == 0 } });
    apply(txn, st);
}

fn setIconNodes(txn: Txn, st: *Chip, icon: []const u8) void {
    st.icon = c.siv_image_view(txn, st.root, &.{ .icon = icon.ptr, .icon_len = icon.len, .icon_size = tk.icon_size });
    _ = c.siv_move(txn, st.icon, st.root, st.label);
    st.icon_name = w.hiddenText(txn, st.root, icon);
}

/// A cross, on a round fill while the pointer is over it.
fn drawRemove(ud: ?*anyopaque, node: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const st: *Chip = @ptrCast(@alignCast(ud.?));
    const fg: siv.ColorToken = if (st.hdr.disabled) .disabled_fg else if (st.color != .none) .view_fg else .control_fg;
    if (st.remove_hover and !st.hdr.disabled) {
        _ = c.siv_draw_ellipse(draw, .{ .x = 0, .y = 0, .width = width, .height = height });
        var bg: siv.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        _ = c.siv_node_get_color(node, fg, &bg);
        bg.a *= 0.15;
        _ = c.siv_draw_fill(draw, &.{ .color = bg }, .{});
    }
    var col: siv.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    _ = c.siv_node_get_color(node, fg, &col);
    const r = width * 0.22;
    const cx = width / 2;
    const cy = height / 2;
    _ = c.siv_draw_move_to(draw, cx - r, cy - r);
    _ = c.siv_draw_line_to(draw, cx + r, cy + r);
    _ = c.siv_draw_move_to(draw, cx + r, cy - r);
    _ = c.siv_draw_line_to(draw, cx - r, cy + r);
    _ = c.siv_draw_stroke(draw, &.{ .width = tk.glyph_stroke, .cap = .round }, &.{ .color = col });
}

fn refresh(st: *Chip, window: siv.Window) void {
    const txn = w.begin(window) orelse return;
    apply(txn, st);
    _ = w.commit(txn);
}

fn onPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Chip = @ptrCast(@alignCast(ud.?));
    if (interactive(st) and button.feedback(&st.hdr, ev)) refresh(st, ev.window);
    return .pass;
}

fn onRemovePointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Chip = @ptrCast(@alignCast(ud.?));
    const hover = switch (ev.phase) {
        .enter => true,
        .leave => false,
        else => return .pass,
    };
    if (hover != st.remove_hover) {
        st.remove_hover = hover;
        refresh(st, ev.window);
    }
    return .pass;
}

/// Delete and BackSpace remove a removable chip.
fn onKey(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Chip = @ptrCast(@alignCast(ud.?));
    if (!st.removable or st.hdr.disabled or !ev.flags.pressed or ev.target != node) return .pass;
    if (ev.modifiers.ctrl or ev.modifiers.alt or ev.modifiers.super) return .pass;
    if (ev.keysym != w.keysym.delete and ev.keysym != w.keysym.backspace) return .pass;
    askClose(node);
    return .handled;
}

fn onActivate(ud: ?*anyopaque, node: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Chip = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .pass;
    askClose(node);
    return .handled;
}

fn onRemoveActivate(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const node = w.dataHandle(ud);
    const st = w.stateOf(Chip, node, &.{.chip}) orelse return .handled;
    if (!st.hdr.disabled) askClose(node);
    return .handled;
}

fn askClose(node: Node) void {
    var handled = false;
    _ = c.siv_node_emit(node, &.{ .type = .close }, &handled);
}

/// Removes the chip.
fn onClose(_: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const txn = w.begin(ev.window) orelse return .pass;
    _ = c.siv_remove(txn, node);
    if (!w.commit(txn)) return .pass;
    return .handled;
}
