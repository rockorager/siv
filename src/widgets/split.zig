//! Split panes: a start pane of a given size, a divider, and an end pane
//! that takes the rest. The divider is a focusable separator whose value
//! is the start pane's size: dragging it, arrow keys (10 px; left and
//! right swapped in RTL for side-by-side panes), Home, and End move it,
//! clamped to the panes' least sizes, and each move reports `change`. The
//! largest size depends on layout, so assistive technology sees it from
//! the first time the divider is focused or moved.

const std = @import("std");
const w = @import("widgets.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

/// The divider's thickness, and how far a key moves it.
const thickness: f32 = 6;
const key_step: f32 = 10;

pub const Split = extern struct {
    hdr: w.Header,
    vertical: bool,
    dragging: bool = false,
    grab: f32 = 0,
    position: f64,
    min_start: f64,
    min_end: f64,
    root: Node,
    start: Node,
    divider: Node,
    line: Node,
    end: Node,
};

pub export fn siv_split_pane(txn: Txn, parent: Node, desc: ?*const siv.SplitDesc) Node {
    const d = w.readDesc(siv.SplitDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@backingInt(d.axis) < 0 or @backingInt(d.axis) > 1) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    inline for (.{ d.position, d.min_start, d.min_end }) |v| if (!std.math.isFinite(v) or v < 0) return w.fail(txn, .error_invalid_argument);
    const vertical = d.axis == .column;
    const root = c.siv_flex(txn, parent, &.{ .axis = d.axis });
    if (root == .null) return .null;
    _ = c.siv_set_default_layout(txn, root, &.{ .grow = 1, .align_x = .stretch, .align_y = .stretch });
    const st = w.create(Split, txn, root) orelse return .null;
    st.* = .{
        .hdr = .{ .kind = .split_pane },
        .vertical = vertical,
        .position = if (d.position == 0) 200 else d.position,
        .min_start = d.min_start,
        .min_end = d.min_end,
        .root = root,
        .start = c.siv_box(txn, root),
        .divider = c.siv_flex(txn, root, &.{ .axis = if (vertical) .column else .row, .justify = .center, .align_items = .stretch }),
        .line = .null,
        .end = c.siv_box(txn, root),
    };
    st.line = c.siv_box(txn, st.divider);
    _ = c.siv_set_layout(txn, st.end, &.{ .grow = 1, .basis = w.px(0) });
    _ = c.siv_set_semantics(txn, st.divider, &.{ .label = label.ptr, .label_len = label.len });
    w.onDefault(txn, st.divider, .pointer, onPointer, st);
    w.onDefault(txn, st.divider, .key, onKey, st);
    w.onDefault(txn, st.divider, .set_value, onSetValue, st);
    w.onDefault(txn, st.divider, .focus, onFocus, st);
    w.setInterface(txn, root, Split, st, .{ .set_label = setLabel, .set_value = setPosition, .get_value = position, .get_part = part, .apply = apply, .focus = divider });
    apply(txn, st);
    return root;
}

fn position(st: *const Split) f64 {
    return st.position;
}

/// The start and end panes.
fn part(st: *const Split, p: siv.WidgetPart, _: u32) Node {
    return switch (p) {
        .start => st.start,
        .end => st.end,
        else => .null,
    };
}

/// The divider takes the focus: it holds the value.
fn divider(st: *Split) Node {
    return st.divider;
}

/// The largest position depends on layout: it is exposed again when the
/// divider gains focus, as well as whenever it moves.
fn onFocus(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Split = @ptrCast(@alignCast(ud.?));
    if (ev.flags.gained) restyle(st, ev.window);
    return .pass;
}

/// The largest position the panes allow, from the last layout.
fn maxPosition(st: *const Split) f64 {
    var r: siv.Rect = undefined;
    if (c.siv_node_get_rect(st.root, &r) != .ok) return std.math.inf(f64);
    const total: f64 = if (st.vertical) r.height else r.width;
    if (total <= 0) return std.math.inf(f64);
    return @max(st.min_start, total - thickness - st.min_end);
}

pub fn apply(txn: Txn, st: *Split) void {
    const pos: f32 = @floatCast(st.position);
    if (st.vertical) {
        _ = c.siv_set_layout(txn, st.start, &.{ .height = w.px(pos), .flags = .{ .no_shrink = true } });
        _ = c.siv_set_layout(txn, st.divider, &.{ .height = w.px(thickness), .flags = .{ .no_shrink = true } });
        _ = c.siv_set_layout(txn, st.line, &.{ .height = w.px(1) });
    } else {
        _ = c.siv_set_layout(txn, st.start, &.{ .width = w.px(pos), .flags = .{ .no_shrink = true } });
        _ = c.siv_set_layout(txn, st.divider, &.{ .width = w.px(thickness), .flags = .{ .no_shrink = true } });
        _ = c.siv_set_layout(txn, st.line, &.{ .width = w.px(1) });
    }
    const lit = st.dragging or st.hdr.hover;
    _ = c.siv_set_visual(txn, st.divider, &.{ .background_token = if (lit) .control_hover else .none });
    _ = c.siv_set_visual(txn, st.line, &.{ .background_token = if (lit) .accent else .separator });
    var buf: [1024]u8 = undefined;
    const label = w.labelOf(st.divider, &buf);
    const max = maxPosition(st);
    _ = c.siv_set_semantics(txn, st.divider, &.{
        .role = .separator,
        .label = label.ptr,
        .label_len = label.len,
        .value_min = st.min_start,
        .value_max = if (std.math.isFinite(max)) max else @max(st.position, st.min_start),
        .value_now = st.position,
        .value_step = key_step,
        .flags = .{ .focusable = !st.hdr.disabled, .disabled = st.hdr.disabled, .has_value = true },
    });
}

pub fn setLabel(txn: Txn, st: *Split, label: []const u8) void {
    _ = c.siv_set_semantics(txn, st.divider, &.{ .label = label.ptr, .label_len = label.len });
    apply(txn, st);
}

fn clamp(st: *const Split, v: f64) f64 {
    return std.math.clamp(v, st.min_start, @max(st.min_start, maxPosition(st)));
}

pub fn setPosition(txn: Txn, st: *Split, v: f64) void {
    st.position = @max(st.min_start, v);
    if (std.math.isFinite(maxPosition(st))) st.position = clamp(st, v);
    apply(txn, st);
}

fn userSet(st: *Split, window: siv.Window, v: f64) void {
    const nv = clamp(st, v);
    const txn = w.begin(window) orelse return;
    const changed = nv != st.position;
    st.position = nv;
    apply(txn, st);
    if (!w.commit(txn) or !changed) return;
    w.emitChange(st.root, st.position, 0);
}

fn restyle(st: *Split, window: siv.Window) void {
    const txn = w.begin(window) orelse return;
    apply(txn, st);
    _ = w.commit(txn);
}

/// Dragging moves the divider with the pointer: `grab` is where in the
/// divider it was pressed, so the divider stays under it.
fn onPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Split = @ptrCast(@alignCast(ud.?));
    const e = ev;
    if (st.hdr.disabled) return .pass;
    const along = if (st.vertical) e.y else e.x;
    switch (e.phase) {
        .down => if (e.button == .primary) {
            st.dragging = true;
            st.grab = along;
            restyle(st, e.window);
        },
        .move => if (st.dragging) {
            // In window coordinates, from the last layout, so that moves
            // arriving before the next frame do not add up twice.
            var root: siv.Rect = undefined;
            var div: siv.Rect = undefined;
            if (c.siv_node_get_rect(st.root, &root) != .ok or c.siv_node_get_rect(st.divider, &div) != .ok) return .pass;
            const pos: f64 = if (st.vertical)
                div.y + e.y - st.grab - root.y
            else if (w.isRtl(st.root))
                root.x + root.width - thickness - (div.x + e.x - st.grab)
            else
                div.x + e.x - st.grab - root.x;
            userSet(st, e.window, pos);
        },
        .up, .cancel => if (st.dragging) {
            st.dragging = false;
            restyle(st, e.window);
        },
        .enter, .leave => {
            st.hdr.hover = e.phase == .enter;
            restyle(st, e.window);
        },
        else => {},
    }
    return .pass;
}

fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Split = @ptrCast(@alignCast(ud.?));
    const e = ev;
    if (st.hdr.disabled or !e.flags.pressed) return .pass;
    const k = w.keysym;
    const rtl = !st.vertical and w.isRtl(st.root);
    const step: f64 = key_step;
    const target: f64 = switch (e.keysym) {
        k.left => if (st.vertical) return .pass else if (rtl) st.position + step else st.position - step,
        k.right => if (st.vertical) return .pass else if (rtl) st.position - step else st.position + step,
        k.up => if (!st.vertical) return .pass else st.position - step,
        k.down => if (!st.vertical) return .pass else st.position + step,
        k.home => st.min_start,
        k.end => maxPosition(st),
        else => return .pass,
    };
    userSet(st, e.window, target);
    return .handled;
}

fn onSetValue(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Split = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .pass;
    userSet(st, ev.window, ev.value);
    return .handled;
}
