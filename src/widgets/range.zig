//! Range widgets: sliders, spin buttons, and progress bars. The value is
//! clamped to [min, max] and snapped to min plus multiples of step.
//!
//! Positions come from layout, not pixels: the filled part and the part
//! after it are flex items growing in proportion to the value, so a
//! slider's thumb and a progress bar's fill mirror in right-to-left
//! layouts without widget code (D21). Sliders follow the pointer while
//! pressed, step with the arrow keys (left and right swapped in RTL),
//! page with Page Up and Page Down, and go to the ends with Home and End;
//! assistive technology sets their value through `set_value` (D18).

const std = @import("std");
const w = @import("widgets.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Range = extern struct {
    hdr: w.Header,
    indeterminate: bool = false,
    dragging: bool = false,
    digits: u32 = 0,
    min: f64,
    max: f64,
    value: f64,
    step: f64,
    page: f64,
    root: Node,
    /// The node with the value's semantics: the root, or a spin button's
    /// field.
    target: Node = .null,
    /// Grows with the value: a slider's or progress bar's filled part.
    fill: Node = .null,
    /// Grows with the rest.
    rest: Node = .null,
    thumb: Node = .null,
    /// Spin buttons: the decrement and increment buttons and their labels.
    dec: Node = .null,
    inc: Node = .null,
    dec_label: Node = .null,
    inc_label: Node = .null,

    /// Arrow keys move this far.
    fn keyStep(r: *const Range) f64 {
        if (r.step > 0) return r.step;
        return if (r.hdr.kind == .spin_button) 1 else (r.max - r.min) / 100;
    }

    fn pageStep(r: *const Range) f64 {
        return if (r.page > 0) r.page else 10 * r.keyStep();
    }

    fn fraction(r: *const Range) f64 {
        if (r.max <= r.min) return 0;
        return (r.value - r.min) / (r.max - r.min);
    }

    fn snapped(r: *const Range, v: f64) f64 {
        return w.snap(v, r.min, r.max, r.step);
    }
};

pub export fn siv_slider(txn: Txn, parent: Node, desc: ?*const siv.RangeDesc) Node {
    return create(txn, parent, desc, .slider);
}

pub export fn siv_spin_button(txn: Txn, parent: Node, desc: ?*const siv.RangeDesc) Node {
    return create(txn, parent, desc, .spin_button);
}

pub export fn siv_progress_bar(txn: Txn, parent: Node, desc: ?*const siv.RangeDesc) Node {
    return create(txn, parent, desc, .progress_bar);
}

fn create(txn: Txn, parent: Node, desc: ?*const siv.RangeDesc, kind: w.Kind) Node {
    const d = w.readDesc(siv.RangeDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 3) != 0) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    inline for (.{ d.min, d.max, d.value, d.step, d.page }) |v| if (!std.math.isFinite(v)) return w.fail(txn, .error_invalid_argument);
    if (d.min > d.max or d.step < 0 or d.page < 0 or d.digits > 15) return w.fail(txn, .error_invalid_argument);
    const max = if (d.min == d.max) 100 else d.max;
    const min = if (d.min == d.max) 0 else d.min;
    const root = switch (kind) {
        .spin_button => c.siv_flex(txn, parent, &.{ .axis = .row, .gap = tk.gap / 2 }),
        .slider => c.siv_stack(txn, parent, &.{ .align_x = .stretch, .align_y = .center }),
        else => c.siv_box(txn, parent),
    };
    if (root == .null) return .null;
    const r = w.create(Range, txn, root) orelse return .null;
    r.* = .{
        .hdr = .{ .kind = kind, .disabled = d.flags.disabled },
        .indeterminate = d.flags.indeterminate and kind == .progress_bar,
        .digits = d.digits,
        .min = min,
        .max = max,
        .value = 0,
        .step = d.step,
        .page = d.page,
        .root = root,
        .target = root,
    };
    r.value = r.snapped(d.value);
    switch (kind) {
        .slider => buildSlider(txn, r),
        .spin_button => buildSpin(txn, r),
        else => buildProgress(txn, r),
    }
    _ = c.siv_set_semantics(txn, r.target, &.{ .label = label.ptr, .label_len = label.len });
    apply(txn, r);
    return root;
}

fn px(v: f32) siv.Dimension {
    return .{ .unit = .px, .value = v };
}

fn corners(v: f32) siv.Corners {
    return .{ .top_start = v, .top_end = v, .bottom_end = v, .bottom_start = v };
}

fn buildSlider(txn: Txn, r: *Range) void {
    _ = c.siv_set_layout(txn, r.root, &.{ .min_width = tk.slider_min_width, .height = px(tk.slider_height) });
    const track = c.siv_box(txn, r.root);
    _ = c.siv_set_layout(txn, track, &.{ .height = px(tk.track) });
    _ = c.siv_set_visual(txn, track, &.{ .radius = corners(tk.track / 2), .background_token = .track });
    // fill, thumb, rest: the thumb starts where a fill of fraction f of the
    // free width ends, so its center maps the value linearly between the
    // track's ends, mirrored in RTL by layout.
    const row = c.siv_flex(txn, r.root, &.{ .axis = .row, .align_items = .center });
    _ = c.siv_set_layout(txn, row, &.{ .align_y = .stretch });
    r.fill = c.siv_box(txn, row);
    r.thumb = c.siv_box(txn, row);
    r.rest = c.siv_box(txn, row);
    _ = c.siv_set_layout(txn, r.thumb, &.{ .width = px(tk.thumb), .height = px(tk.thumb), .flags = .{ .no_shrink = true } });
    w.onDefault(txn, r.root, .pointer, onSliderPointer, r);
    w.onDefault(txn, r.root, .key, onKey, r);
    w.onDefault(txn, r.root, .set_value, onSetValue, r);
}

fn buildProgress(txn: Txn, r: *Range) void {
    _ = c.siv_set_layout(txn, r.root, &.{ .min_width = tk.progress_min_width, .height = px(tk.progress_height) });
    _ = c.siv_set_visual(txn, r.root, &.{ .radius = corners(tk.progress_height / 2), .background_token = .track, .flags = .{ .clip = true } });
    const row = c.siv_flex(txn, r.root, &.{ .axis = .row });
    _ = c.siv_set_layout(txn, row, &.{ .height = px(tk.progress_height) });
    r.fill = c.siv_box(txn, row);
    r.rest = c.siv_box(txn, row);
    _ = c.siv_set_visual(txn, r.fill, &.{ .radius = corners(tk.progress_height / 2), .background_token = .accent });
}

fn buildSpin(txn: Txn, r: *Range) void {
    const field = c.siv_editor(txn, r.root, .{});
    _ = c.siv_set_layout(txn, field, &.{
        .width = px(tk.spin_field_width),
        .grow = 1,
        .min_height = tk.control_height,
        .padding = .{ .start = tk.field_pad_x, .end = tk.field_pad_x, .top = tk.pad_y + 1, .bottom = tk.pad_y + 1 },
    });
    r.target = field;
    r.dec, r.dec_label = spinButton(txn, r.root, "\u{2212}");
    r.inc, r.inc_label = spinButton(txn, r.root, "+");
    _ = c.siv_on_default(txn, r.dec, .activate, onDecrement, null, r);
    _ = c.siv_on_default(txn, r.inc, .activate, onIncrement, null, r);
    _ = c.siv_on_default(txn, r.dec, .pointer, onSpinPointer, null, r);
    _ = c.siv_on_default(txn, r.inc, .pointer, onSpinPointer, null, r);
    w.onDefault(txn, field, .key, onKey, r);
    w.onDefault(txn, field, .focus, onFieldFocus, r);
    w.onDefault(txn, field, .set_value, onSetValue, r);
    showNumber(txn, r);
}

/// A decrement or increment button: clickable but not in the Tab order,
/// as WAI-ARIA has it; the field takes the keys.
fn spinButton(txn: Txn, parent: Node, label: []const u8) struct { Node, Node } {
    const b = c.siv_flex(txn, parent, &.{ .axis = .row, .justify = .center, .align_items = .center });
    _ = c.siv_set_layout(txn, b, &.{ .width = px(tk.control_height), .min_height = tk.control_height, .flags = .{ .no_shrink = true } });
    const text = c.siv_text(txn, b, label.ptr, label.len);
    return .{ b, text };
}

pub fn apply(txn: Txn, r: *Range) void {
    const h = r.hdr;
    const f: f32 = if (r.indeterminate) tk.indeterminate_share else @floatCast(r.fraction());
    if (r.fill != .null) {
        _ = c.siv_set_layout(txn, r.fill, &.{ .grow = f, .basis = px(0), .height = px(if (h.kind == .slider) tk.track else tk.progress_height) });
        _ = c.siv_set_layout(txn, r.rest, &.{ .grow = 1 - f, .basis = px(0) });
    }
    switch (h.kind) {
        .slider => {
            _ = c.siv_set_visual(txn, r.fill, &.{ .radius = corners(tk.track / 2), .background_token = if (h.disabled) .disabled_fg else .accent });
            _ = c.siv_set_visual(txn, r.thumb, &.{
                .radius = corners(tk.thumb / 2),
                .border_width = 2 * tk.border,
                .border_token = if (h.disabled) .disabled_fg else .accent,
                .background_token = if (h.pressed or r.dragging) .control_active else if (h.hover) .control_hover else .knob,
            });
        },
        .spin_button => {
            _ = c.siv_set_visual(txn, r.target, &.{
                .radius = corners(tk.radius),
                .border_width = tk.border,
                .border_token = .border,
                .background_token = if (h.disabled) .control_bg else .view_bg,
            });
            _ = c.siv_set_text_style(txn, r.target, &.{ .color_token = if (h.disabled) .disabled_fg else .view_fg, .size_role = .body, .@"align" = .end });
            inline for (.{ .{ r.dec, r.dec_label, r.value <= r.min }, .{ r.inc, r.inc_label, r.value >= r.max } }) |b| {
                const off = h.disabled or b[2];
                _ = c.siv_set_visual(txn, b[0], &.{
                    .radius = corners(tk.radius),
                    .border_width = tk.border,
                    .border_token = .border,
                    .background_token = .control_bg,
                });
                _ = c.siv_set_text_style(txn, b[1], &w.textStyle(if (off) .disabled_fg else .control_fg, .body));
                _ = c.siv_set_semantics(txn, b[0], &.{ .role = .button, .flags = .{ .disabled = off } });
            }
        },
        else => _ = c.siv_set_visual(txn, r.fill, &.{ .radius = corners(tk.progress_height / 2), .background_token = if (h.disabled) .disabled_fg else .accent }),
    }
    var buf: [1024]u8 = undefined;
    const label = w.labelOf(r.target, &buf);
    _ = c.siv_set_semantics(txn, r.target, &.{
        .role = switch (h.kind) {
            .slider => .slider,
            .spin_button => .spin_button,
            else => .progress_bar,
        },
        .label = label.ptr,
        .label_len = label.len,
        .value_min = r.min,
        .value_max = r.max,
        .value_now = r.value,
        .value_step = if (h.kind == .progress_bar) 0 else r.keyStep(),
        .flags = .{
            .focusable = h.kind == .slider and !h.disabled,
            .disabled = h.disabled,
            .has_value = !r.indeterminate,
        },
    });
}

/// A spin button's field shows the value with its decimals.
fn showNumber(txn: Txn, r: *Range) void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ r.value, r.digits }) catch return;
    _ = c.siv_set_text(txn, r.target, s.ptr, s.len);
}

pub fn setLabel(txn: Txn, r: *Range, label: []const u8) void {
    _ = c.siv_set_semantics(txn, r.target, &.{ .label = label.ptr, .label_len = label.len });
    apply(txn, r);
}

pub fn setValue(txn: Txn, r: *Range, v: f64) void {
    r.value = r.snapped(v);
    if (r.hdr.kind == .spin_button) showNumber(txn, r);
    apply(txn, r);
}

pub fn setRange(txn: Txn, r: *Range, min: f64, max: f64, step: f64) void {
    r.min = if (min == max) 0 else min;
    r.max = if (min == max) 100 else max;
    r.step = step;
    setValue(txn, r, r.value);
}

/// The user moved the value: commits it and reports `change`.
fn userSet(r: *Range, window: siv.Window, v: f64) void {
    const nv = r.snapped(v);
    const txn = w.begin(window) orelse return;
    const changed = nv != r.value;
    setValue(txn, r, nv);
    if (!w.commit(txn) or !changed) return;
    w.emitChange(r.root, r.value, 0);
}

fn onSetValue(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const r: *Range = @ptrCast(@alignCast(ud.?));
    if (r.hdr.disabled) return false;
    userSet(r, ev.?.window, ev.?.value);
    return true;
}

fn onKey(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const r: *Range = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (r.hdr.disabled or !e.flags.pressed) return false;
    const k = w.keysym;
    const rtl = w.isRtl(r.root);
    const target: f64 = switch (e.keysym) {
        k.up => r.value + r.keyStep(),
        k.down => r.value - r.keyStep(),
        k.page_up => r.value + r.pageStep(),
        k.page_down => r.value - r.pageStep(),
        else => blk: {
            if (r.hdr.kind == .spin_button) {
                if (e.keysym == k.@"return" or e.keysym == k.kp_enter) {
                    commitText(r, e.window);
                    return true;
                }
                return false;
            }
            break :blk switch (e.keysym) {
                k.right => if (rtl) r.value - r.keyStep() else r.value + r.keyStep(),
                k.left => if (rtl) r.value + r.keyStep() else r.value - r.keyStep(),
                k.home => r.min,
                k.end => r.max,
                else => return false,
            };
        },
    };
    userSet(r, e.window, target);
    return true;
}

/// Where the pointer is along the track, as a value.
fn valueAt(r: *const Range, x: f32) f64 {
    var rect: siv.Rect = undefined;
    if (c.siv_node_get_rect(r.root, &rect) != .ok) return r.value;
    const span = rect.width - tk.thumb;
    if (span <= 0) return r.min;
    var f: f64 = std.math.clamp((x - tk.thumb / 2) / span, 0, 1);
    if (w.isRtl(r.root)) f = 1 - f;
    return r.min + f * (r.max - r.min);
}

fn onSliderPointer(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const r: *Range = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (r.hdr.disabled) return false;
    switch (e.phase) {
        .down => if (e.button == .primary) {
            r.dragging = true;
            userSet(r, e.window, valueAt(r, e.x));
        },
        .move => if (r.dragging) userSet(r, e.window, valueAt(r, e.x)),
        .up, .cancel => if (r.dragging) {
            r.dragging = false;
            restyle(r, e.window);
        },
        .enter, .leave => {
            r.hdr.hover = e.phase == .enter;
            restyle(r, e.window);
        },
        else => {},
    }
    // The core still focuses the slider on the press (D16).
    return false;
}

fn restyle(r: *Range, window: siv.Window) void {
    const txn = w.begin(window) orelse return;
    apply(txn, r);
    _ = w.commit(txn);
}

fn onDecrement(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const r: *Range = @ptrCast(@alignCast(ud.?));
    if (r.hdr.disabled) return false;
    userSet(r, ev.?.window, r.value - r.keyStep());
    return true;
}

fn onIncrement(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const r: *Range = @ptrCast(@alignCast(ud.?));
    if (r.hdr.disabled) return false;
    userSet(r, ev.?.window, r.value + r.keyStep());
    return true;
}

fn onSpinPointer(ud: ?*anyopaque, node: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const r: *Range = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (r.hdr.disabled or (e.phase != .enter and e.phase != .leave and e.phase != .down and e.phase != .up)) return false;
    const txn = w.begin(e.window) orelse return false;
    const bg: siv.ColorToken = switch (e.phase) {
        .enter, .up => .control_hover,
        .down => .control_active,
        else => .control_bg,
    };
    _ = c.siv_set_visual(txn, node, &.{ .radius = corners(tk.radius), .border_width = tk.border, .border_token = .border, .background_token = bg });
    _ = w.commit(txn);
    return false;
}

/// Leaving the field takes what was typed.
fn onFieldFocus(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const r: *Range = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.gained) commitText(r, e.window);
    return false;
}

/// Parses the field: a number sets the value (clamped and stepped), and
/// anything else puts the old value back.
fn commitText(r: *Range, window: siv.Window) void {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    if (c.siv_node_get_text(r.target, &buf, buf.len, &len) != .ok) return;
    const typed = std.mem.trim(u8, buf[0..@min(len, buf.len)], " \t");
    const v = std.fmt.parseFloat(f64, typed) catch r.value;
    const nv = if (std.math.isFinite(v)) r.snapped(v) else r.value;
    const txn = w.begin(window) orelse return;
    const changed = nv != r.value;
    setValue(txn, r, nv);
    if (!w.commit(txn) or !changed) return;
    w.emitChange(r.root, r.value, 0);
}
