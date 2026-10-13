//! Radio groups: a flex container of radios, each a circle and a label.
//! The group's value is the selected radio's index; choosing one (click,
//! Space, arrows, or assistive technology's action) reports `change` on
//! the group. Arrow keys move the selection and focus, wrapping, swapped
//! in right-to-left layouts; only the selected radio is in the Tab order
//! (WAI-ARIA's roving focus).

const std = @import("std");
const w = @import("widgets.zig");
const button = @import("button.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Group = extern struct {
    hdr: w.Header,
    /// Index of the selected radio, or -1.
    selected: i32 = 0,
    root: Node,

    pub fn selectedValue(g: *const Group) f64 {
        return @floatFromInt(g.selected);
    }
};

pub const Radio = extern struct {
    hdr: w.Header,
    group: Node,
    root: Node,
    circle: Node,
    dot: Node,
    label: Node,
};

pub export fn siv_radio_group(txn: Txn, parent: Node, desc: ?*const siv.RadioGroupDesc) Node {
    const d = w.readDesc(siv.RadioGroupDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (!button.validFlags(d.flags) or @backingInt(d.axis) < 0 or @backingInt(d.axis) > 1) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = d.axis, .gap = if (d.axis == .row) 2 * tk.gap else tk.gap, .align_items = .start });
    if (root == .null) return .null;
    const g = w.create(Group, txn, root) orelse return .null;
    g.* = .{ .hdr = .{ .kind = .radio_group, .disabled = d.flags.disabled }, .root = root };
    _ = c.siv_set_semantics(txn, root, &.{ .role = .group, .label = label.ptr, .label_len = label.len });
    applyGroup(txn, g);
    return root;
}

pub export fn siv_radio(txn: Txn, group: Node, label_ptr: ?[*]const u8, label_len: usize) Node {
    if (w.stateOf(Group, group, &.{.radio_group}) == null) return w.fail(txn, .error_invalid_argument);
    const label = w.str(label_ptr, label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, group, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    if (root == .null) return .null;
    const st = w.create(Radio, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .radio }, .group = group, .root = root, .circle = .null, .dot = .null, .label = .null };
    st.circle = c.siv_stack(txn, root, &.{ .align_x = .center, .align_y = .center });
    _ = c.siv_set_layout(txn, st.circle, &.{ .width = px(tk.check_size), .height = px(tk.check_size), .flags = .{ .no_shrink = true } });
    st.dot = c.siv_box(txn, st.circle);
    _ = c.siv_set_layout(txn, st.dot, &.{ .width = px(tk.radio_dot), .height = px(tk.radio_dot) });
    st.label = c.siv_text(txn, root, label.ptr, label.len);
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .activate, onActivate, st);
    w.onDefault(txn, root, .key, onKey, st);
    apply(txn, st);
    return root;
}

fn px(v: f32) siv.Dimension {
    return .{ .unit = .px, .value = v };
}

fn corners(r: f32) siv.Corners {
    return .{ .top_start = r, .top_end = r, .bottom_end = r, .bottom_start = r };
}

fn groupOf(st: *const Radio) ?*Group {
    return w.stateOf(Group, st.group, &.{.radio_group});
}

fn radioOf(node: Node) ?*Radio {
    return w.stateOf(Radio, node, &.{.radio});
}

/// The radio's position among the group's radios.
fn indexOf(st: *const Radio) u32 {
    var i: u32 = 0;
    var cur = w.related(st.group, .first_child);
    while (cur != .null and cur != st.root) : (cur = w.related(cur, .next)) {
        if (radioOf(cur) != null) i += 1;
    }
    return i;
}

/// The group's radio at `index`.
fn nth(g: *const Group, index: u32) ?*Radio {
    var i: u32 = 0;
    var cur = w.related(g.root, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const r = radioOf(cur) orelse continue;
        if (i == index) return r;
        i += 1;
    }
    return null;
}

fn count(g: *const Group) u32 {
    var i: u32 = 0;
    var cur = w.related(g.root, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        if (radioOf(cur) != null) i += 1;
    }
    return i;
}

pub fn apply(txn: Txn, st: *Radio) void {
    const g = groupOf(st) orelse return;
    const index = indexOf(st);
    const checked = g.selected >= 0 and index == @as(u32, @intCast(g.selected));
    const disabled = st.hdr.disabled or g.hdr.disabled;
    // Roving focus: the selected radio, or the first without a selection.
    const tab_stop = if (g.selected >= 0) checked else index == 0;
    const ring: siv.ColorToken = if (disabled) .border else if (checked) .accent else .border;
    _ = c.siv_set_visual(txn, st.circle, &.{
        .radius = corners(tk.check_size / 2),
        .border_width = if (checked and !disabled) 2 * tk.border else tk.border,
        .border_token = ring,
        .background_token = if (disabled) .control_bg else if (st.hdr.hover) .control_hover else .view_bg,
    });
    _ = c.siv_set_visual(txn, st.dot, &.{
        .radius = corners(tk.radio_dot / 2),
        .background_token = if (disabled) .disabled_fg else .accent,
        .flags = .{ .hidden = !checked },
    });
    _ = c.siv_set_text_style(txn, st.label, &w.textStyle(if (disabled) .disabled_fg else .window_fg, .body));
    _ = c.siv_set_semantics(txn, st.root, &.{
        .role = .radio,
        .checked = if (checked) .on else .off,
        .flags = .{ .focusable = tab_stop and !disabled, .disabled = disabled },
    });
}

pub fn applyGroup(txn: Txn, g: *Group) void {
    var buf: [1024]u8 = undefined;
    const label = w.labelOf(g.root, &buf);
    _ = c.siv_set_semantics(txn, g.root, &.{ .role = .group, .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = g.hdr.disabled } });
    var cur = w.related(g.root, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        if (radioOf(cur)) |r| apply(txn, r);
    }
}

pub fn setLabel(txn: Txn, st: *Radio, label: []const u8) void {
    _ = c.siv_set_text(txn, st.label, label.ptr, label.len);
}

pub fn setGroupLabel(txn: Txn, g: *Group, label: []const u8) void {
    _ = c.siv_set_semantics(txn, g.root, &.{ .role = .group, .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = g.hdr.disabled } });
}

/// Selects the radio at `v` (-1 or out of range: none).
pub fn select(txn: Txn, g: *Group, v: f64) void {
    const n = count(g);
    const i: i64 = @intFromFloat(@round(v));
    g.selected = if (i >= 0 and i < n) @intCast(i) else -1;
    applyGroup(txn, g);
}

/// The user chose `st`: selects it, commits, and reports it on the group.
fn choose(st: *Radio, window: siv.Window, focus: bool) void {
    const g = groupOf(st) orelse return;
    const index = indexOf(st);
    const txn = w.begin(window) orelse return;
    const changed = g.selected != @as(i32, @intCast(index));
    g.selected = @intCast(index);
    applyGroup(txn, g);
    if (!w.commit(txn)) return;
    if (focus) _ = c.siv_node_focus(st.root);
    if (changed) w.emitChange(g.root, g.selectedValue(), index);
}

fn onPointer(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Radio = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    const g = groupOf(st) orelse return .pass;
    if (g.hdr.disabled) return .pass;
    if (button.feedback(&st.hdr, e)) {
        const txn = w.begin(e.window) orelse return .pass;
        apply(txn, st);
        _ = w.commit(txn);
    }
    return .pass;
}

fn onActivate(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Radio = @ptrCast(@alignCast(ud.?));
    const g = groupOf(st) orelse return .pass;
    if (st.hdr.disabled or g.hdr.disabled) return .pass;
    choose(st, ev.?.window, false);
    return .handled;
}

/// Arrows select and focus the next or previous enabled radio, wrapping.
fn onKey(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Radio = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.pressed) return .pass;
    const dir = w.arrowDirection(e.keysym, w.isRtl(st.root));
    if (dir == 0) return .pass;
    const g = groupOf(st) orelse return .pass;
    const n = count(g);
    if (n == 0 or g.hdr.disabled) return .handled;
    var i = indexOf(st);
    var tries: u32 = 0;
    while (tries < n) : (tries += 1) {
        i = if (dir > 0) (i + 1) % n else (i + n - 1) % n;
        const r = nth(g, i) orelse break;
        if (!r.hdr.disabled) {
            choose(r, e.window, true);
            break;
        }
    }
    return .handled;
}
