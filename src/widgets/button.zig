//! Push buttons and toggle buttons: a flex row with a centered label, its
//! fill following the pointer (rest, hover, pressed) in themed colors.
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
};

pub export fn siv_push_button(txn: Txn, parent: Node, desc: ?*const siv.ButtonDesc) Node {
    const d = w.readDesc(siv.ButtonDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@backingInt(d.style) < 0 or @backingInt(d.style) > 3) return w.fail(txn, .error_unsupported);
    if (!validFlags(d.flags)) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    return build(txn, parent, .button, label, d.style, d.flags.disabled, false);
}

pub export fn siv_toggle_button(txn: Txn, parent: Node, desc: ?*const siv.ToggleDesc) Node {
    const d = w.readDesc(siv.ToggleDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (!validFlags(d.flags) or @backingInt(d.checked) < 0 or @backingInt(d.checked) > 2) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    return build(txn, parent, .toggle_button, label, .default, d.flags.disabled, d.checked == .on);
}

pub fn validFlags(f: siv.WidgetFlags) bool {
    return @as(u32, @bitCast(f)) & ~@as(u32, 1) == 0;
}

fn build(txn: Txn, parent: Node, kind: w.Kind, label: []const u8, style: siv.ButtonStyle, disabled: bool, on: bool) Node {
    const root = c.siv_flex(txn, parent, &.{ .axis = .row, .justify = .center, .align_items = .center });
    if (root == .null) return .null;
    _ = c.siv_set_layout(txn, root, &.{
        .min_height = tk.control_height,
        .padding = .{ .start = tk.pad_x, .end = tk.pad_x, .top = tk.pad_y, .bottom = tk.pad_y },
    });
    const text = c.siv_text(txn, root, label.ptr, label.len);
    const st = w.create(Button, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = kind, .disabled = disabled }, .style = style, .on = on, .root = root, .label = text };
    w.onDefault(txn, root, .pointer, onPointer, st);
    if (kind == .toggle_button) w.onDefault(txn, root, .activate, onActivate, st);
    apply(txn, st);
    return root;
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
        .border_width = if (bordered or h.disabled) tk.border else 0,
        .border_token = .border,
        .background_token = bg,
    });
    _ = c.siv_set_text_style(txn, st.label, &w.textStyle(fg, .body));
    _ = c.siv_set_semantics(txn, st.root, &.{
        .role = if (h.kind == .toggle_button) .toggle_button else .button,
        .pressed = if (h.kind == .toggle_button) (if (st.on) .on else .off) else .unset,
        .flags = .{ .focusable = !h.disabled, .disabled = h.disabled },
    });
}

pub fn setLabel(txn: Txn, st: *Button, label: []const u8) void {
    _ = c.siv_set_text(txn, st.label, label.ptr, label.len);
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
pub fn onPointer(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Button = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (feedback(&st.hdr, e)) {
        const txn = w.begin(e.window) orelse return false;
        apply(txn, st);
        _ = w.commit(txn);
    }
    return false;
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

fn onActivate(ud: ?*anyopaque, node: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Button = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return false;
    const txn = w.begin(ev.?.window) orelse return false;
    st.on = !st.on;
    apply(txn, st);
    if (!w.commit(txn)) return true;
    w.emitChange(node, value(st), 0);
    return true;
}
