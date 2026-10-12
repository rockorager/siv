//! Check boxes and switches: a control and its label in a flex row, the
//! whole row focusable and clickable. Activating flips the value and
//! reports `change`. A check box's mark is a canvas drawn in the theme's
//! colors; a switch's knob is a layer that slides with a transition
//! (D29), so reduced motion makes it jump.

const std = @import("std");
const w = @import("widgets.zig");
const button = @import("button.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const State = enum(u8) { off, on, mixed };

pub const Toggle = extern struct {
    hdr: w.Header,
    state: State,
    root: Node,
    /// The check box or switch track.
    control: Node,
    /// The check mark canvas, or the switch knob.
    inner: Node,
    label: Node,
};

pub export fn siv_check_box(txn: Txn, parent: Node, desc: ?*const siv.ToggleDesc) Node {
    return create(txn, parent, desc, .check_box);
}

pub export fn siv_switch(txn: Txn, parent: Node, desc: ?*const siv.ToggleDesc) Node {
    return create(txn, parent, desc, .@"switch");
}

fn create(txn: Txn, parent: Node, desc: ?*const siv.ToggleDesc, kind: w.Kind) Node {
    const d = w.readDesc(siv.ToggleDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (!button.validFlags(d.flags) or @backingInt(d.checked) < 0 or @backingInt(d.checked) > 3) return w.fail(txn, .error_unsupported);
    if (kind == .@"switch" and d.checked == .mixed) return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    if (root == .null) return .null;
    const st = w.create(Toggle, txn, root) orelse return .null;
    st.* = .{
        .hdr = .{ .kind = kind, .disabled = d.flags.disabled },
        .state = switch (d.checked) {
            .on => .on,
            .mixed => .mixed,
            else => .off,
        },
        .root = root,
        .control = .null,
        .inner = .null,
        .label = .null,
    };
    if (kind == .check_box) {
        st.control = c.siv_stack(txn, root, &.{ .align_x = .stretch, .align_y = .stretch });
        _ = c.siv_set_layout(txn, st.control, &.{ .width = px(tk.check_size), .height = px(tk.check_size), .flags = .{ .no_shrink = true } });
        st.inner = c.siv_canvas(txn, st.control, &.{ .user_data = st, .draw = drawMark });
    } else {
        st.control = c.siv_stack(txn, root, &.{ .align_y = .center });
        _ = c.siv_set_layout(txn, st.control, &.{
            .width = px(tk.switch_width),
            .height = px(tk.switch_height),
            .padding = .{ .start = tk.switch_pad, .end = tk.switch_pad },
            .flags = .{ .no_shrink = true },
        });
        st.inner = c.siv_box(txn, st.control);
        _ = c.siv_set_layout(txn, st.inner, &.{ .width = px(tk.knob), .height = px(tk.knob) });
        _ = c.siv_set_transition(txn, st.inner, tk.motion_ms);
    }
    st.label = c.siv_text(txn, root, label.ptr, label.len);
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .activate, onActivate, st);
    apply(txn, st);
    return root;
}

fn px(v: f32) siv.Dimension {
    return .{ .unit = .px, .value = v };
}

fn corners(r: f32) siv.Corners {
    return .{ .top_start = r, .top_end = r, .bottom_end = r, .bottom_start = r };
}

pub fn apply(txn: Txn, st: *Toggle) void {
    const h = st.hdr;
    const on = st.state != .off;
    var label_hidden = false;
    var len: usize = 0;
    if (c.siv_node_get_text(st.label, null, 0, &len) == .ok) label_hidden = len == 0;
    _ = c.siv_set_visual(txn, st.label, &.{ .flags = .{ .hidden = label_hidden } });
    _ = c.siv_set_text_style(txn, st.label, &w.textStyle(if (h.disabled) .disabled_fg else .window_fg, .body));
    if (h.kind == .check_box) {
        const bg: siv.ColorToken = if (h.disabled) .control_bg else if (on) (if (h.pressed) .accent_active else if (h.hover) .accent_hover else .accent) else if (h.hover) .control_hover else .view_bg;
        _ = c.siv_set_visual(txn, st.control, &.{
            .radius = corners(tk.check_radius),
            .border_width = if (on and !h.disabled) 0 else tk.border,
            .border_token = .border,
            .background_token = bg,
        });
        _ = c.siv_invalidate(txn, st.inner);
    } else {
        const track: siv.ColorToken = if (h.disabled) .control_bg else if (on) (if (h.hover) .accent_hover else .accent) else if (h.hover) .control_active else .track;
        _ = c.siv_set_visual(txn, st.control, &.{
            .radius = corners(tk.switch_height / 2),
            .background_token = track,
            .border_width = if (h.disabled) tk.border else 0,
            .border_token = .border,
        });
        _ = c.siv_set_visual(txn, st.inner, &.{
            .radius = corners(tk.knob / 2),
            .background_token = if (h.disabled) .disabled_fg else .knob,
            .flags = .{ .layer = true },
        });
        // The knob slides to the end edge, which is on the left in RTL.
        const travel = tk.switch_width - 2 * tk.switch_pad - tk.knob;
        const x: f32 = if (on) (if (w.isRtl(st.root)) -travel else travel) else 0;
        _ = c.siv_set_transform(txn, st.inner, .{ .translate_x = x, .scale_x = 1, .scale_y = 1 });
    }
    _ = c.siv_set_semantics(txn, st.root, &.{
        .role = if (h.kind == .check_box) .checkbox else .@"switch",
        .checked = switch (st.state) {
            .off => .off,
            .on => .on,
            .mixed => .mixed,
        },
        .flags = .{ .focusable = !h.disabled, .disabled = h.disabled },
    });
}

/// The check mark, or a dash for mixed, in the color on the accent.
fn drawMark(ud: ?*anyopaque, node: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const st: *Toggle = @ptrCast(@alignCast(ud.?));
    if (st.state == .off) return;
    var win: siv.Window = .null;
    _ = c.siv_node_get_window(node, &win);
    var color: siv.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    _ = c.siv_window_get_color(win, if (st.hdr.disabled) .disabled_fg else .accent_fg, &color);
    if (st.state == .on) {
        _ = c.siv_draw_move_to(draw, width * 0.24, height * 0.53);
        _ = c.siv_draw_line_to(draw, width * 0.43, height * 0.71);
        _ = c.siv_draw_line_to(draw, width * 0.77, height * 0.31);
    } else {
        _ = c.siv_draw_move_to(draw, width * 0.27, height * 0.5);
        _ = c.siv_draw_line_to(draw, width * 0.73, height * 0.5);
    }
    _ = c.siv_draw_stroke(draw, &.{ .width = tk.check_stroke, .join = .round, .cap = .round }, &.{ .color = color });
}

pub fn setLabel(txn: Txn, st: *Toggle, label: []const u8) void {
    _ = c.siv_set_text(txn, st.label, label.ptr, label.len);
    apply(txn, st);
}

pub fn value(st: *const Toggle) f64 {
    return switch (st.state) {
        .off => 0,
        .on => 1,
        .mixed => 0.5,
    };
}

pub fn setValue(txn: Txn, st: *Toggle, v: f64) void {
    st.state = if (st.hdr.kind == .@"switch")
        (if (v >= 0.5) .on else .off)
    else if (v >= 1) .on else if (v <= 0) .off else .mixed;
    apply(txn, st);
}

fn onPointer(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Toggle = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (button.feedback(&st.hdr, e)) {
        const txn = w.begin(e.window) orelse return false;
        apply(txn, st);
        _ = w.commit(txn);
    }
    return false;
}

/// Flips the state; mixed becomes on.
fn onActivate(ud: ?*anyopaque, node: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Toggle = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return false;
    const txn = w.begin(ev.?.window) orelse return false;
    st.state = if (st.state == .on) .off else .on;
    apply(txn, st);
    if (!w.commit(txn)) return true;
    w.emitChange(node, value(st), 0);
    return true;
}
