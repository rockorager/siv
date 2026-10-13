//! Tabs: a tab list over a stack of panels, one shown at a time (the
//! others are hidden nodes, so they keep their state). Choosing a tab by
//! click, arrow keys (left and right swapped in RTL), Home, or End shows
//! its panel, moves focus to it, and reports `change` with its index.
//! Only the selected tab is in the Tab order (WAI-ARIA's roving focus,
//! with automatic activation).

const std = @import("std");
const w = @import("widgets.zig");
const button = @import("button.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Tabs = extern struct {
    hdr: w.Header,
    selected: i32 = 0,
    root: Node,
    list: Node,
    panels: Node,
};

pub const Tab = extern struct {
    hdr: w.Header,
    tabs: Node,
    root: Node,
    label: Node,
    indicator: Node,
    panel: Node,
};

pub export fn siv_tabs(txn: Txn, parent: Node, desc: ?*const siv.TabsDesc) Node {
    const d = w.readDesc(siv.TabsDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = .column });
    if (root == .null) return .null;
    const st = w.create(Tabs, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .tabs }, .root = root, .list = .null, .panels = .null };
    st.list = c.siv_flex(txn, root, &.{ .axis = .row, .gap = 4 });
    _ = c.siv_set_semantics(txn, st.list, &.{ .role = .tab_list, .label = label.ptr, .label_len = label.len });
    // The line under the tab list.
    const rule = c.siv_box(txn, root);
    _ = c.siv_set_layout(txn, rule, &.{ .height = w.px(1) });
    _ = c.siv_set_visual(txn, rule, &.{ .background_token = .separator });
    st.panels = c.siv_stack(txn, root, &.{ .align_x = .stretch, .align_y = .stretch });
    _ = c.siv_set_layout(txn, st.panels, &.{ .grow = 1, .padding = .{ .top = 12 } });
    w.setInterface(txn, root, Tabs, st, .{ .set_label = setLabel, .set_value = select, .get_value = selected, .get_part = tabsPart, .apply = apply, .focus = focusTab });
    return root;
}

fn selected(ts: *const Tabs) f64 {
    return @floatFromInt(ts.selected);
}

fn tabsPart(ts: *const Tabs, p: siv.WidgetPart, index: u32) Node {
    return switch (p) {
        .tab, .panel => part(ts, p == .tab, index),
        else => .null,
    };
}

/// The selected tab takes the focus: it is the tab list's one Tab stop.
fn focusTab(ts: *Tabs) Node {
    if (ts.hdr.disabled or ts.selected < 0) return .null;
    const t = nth(ts, @intCast(ts.selected)) orelse return .null;
    return t.root;
}

pub export fn siv_tab(txn: Txn, tabs_node: Node, label_ptr: ?[*]const u8, label_len: usize) Node {
    const ts = w.stateOf(Tabs, tabs_node, &.{.tabs}) orelse return w.fail(txn, .error_invalid_argument);
    const label = w.str(label_ptr, label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, ts.list, &.{ .axis = .column, .align_items = .stretch });
    if (root == .null) return .null;
    const st = w.create(Tab, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .tab }, .tabs = tabs_node, .root = root, .label = .null, .indicator = .null, .panel = .null };
    st.label = c.siv_text(txn, root, label.ptr, label.len);
    _ = c.siv_set_layout(txn, st.label, &.{ .padding = .{ .start = tk.pad_x, .end = tk.pad_x, .top = 6, .bottom = 6 } });
    st.indicator = c.siv_box(txn, root);
    _ = c.siv_set_layout(txn, st.indicator, &.{ .height = w.px(2) });
    st.panel = c.siv_box(txn, ts.panels);
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .activate, onActivate, st);
    w.onDefault(txn, root, .key, onKey, st);
    w.setInterface(txn, root, Tab, st, .{ .set_label = setTabLabel });
    apply(txn, ts);
    return st.panel;
}

fn tabOf(node: Node) ?*Tab {
    return w.stateOf(Tab, node, &.{.tab});
}

fn indexOf(ts: *const Tabs, tab: Node) u32 {
    var i: u32 = 0;
    var cur = w.related(ts.list, .first_child);
    while (cur != .null and cur != tab) : (cur = w.related(cur, .next)) i += 1;
    return i;
}

fn nth(ts: *const Tabs, index: u32) ?*Tab {
    var i: u32 = 0;
    var cur = w.related(ts.list, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        if (i == index) return tabOf(cur);
        i += 1;
    }
    return null;
}

fn count(ts: *const Tabs) u32 {
    var i: u32 = 0;
    var cur = w.related(ts.list, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) i += 1;
    return i;
}

pub fn part(ts: *const Tabs, tab: bool, index: u32) Node {
    const t = nth(ts, index) orelse return .null;
    return if (tab) t.root else t.panel;
}

pub fn apply(txn: Txn, ts: *Tabs) void {
    var i: i32 = 0;
    var cur = w.related(ts.list, .first_child);
    while (cur != .null) : ({
        cur = w.related(cur, .next);
        i += 1;
    }) {
        const t = tabOf(cur) orelse continue;
        const on = i == ts.selected;
        const disabled = ts.hdr.disabled;
        _ = c.siv_set_visual(txn, t.root, &.{ .radius = w.corners(tk.radius), .background_token = if (t.hdr.hover and !disabled) .control_hover else .none });
        _ = c.siv_set_text_style(txn, t.label, &w.textStyle(if (disabled) .disabled_fg else if (on) .accent else .muted_fg, .body));
        _ = c.siv_set_visual(txn, t.indicator, &.{ .background_token = if (on) .accent else .none });
        _ = c.siv_set_semantics(txn, t.root, &.{
            .role = .tab,
            .selected = if (on) .on else .off,
            .flags = .{ .focusable = on and !disabled, .disabled = disabled },
        });
        _ = c.siv_set_visual(txn, t.panel, &.{ .flags = .{ .hidden = !on } });
        _ = c.siv_set_semantics(txn, t.panel, &.{ .role = .tab_panel });
    }
}

pub fn setLabel(txn: Txn, ts: *Tabs, label: []const u8) void {
    _ = c.siv_set_semantics(txn, ts.list, &.{ .role = .tab_list, .label = label.ptr, .label_len = label.len });
}

fn setTabLabel(txn: Txn, t: *Tab, label: []const u8) void {
    _ = c.siv_set_text(txn, t.label, label.ptr, label.len);
}

pub fn select(txn: Txn, ts: *Tabs, v: f64) void {
    const n = count(ts);
    const i: i64 = @intFromFloat(@round(v));
    ts.selected = if (i >= 0 and i < n) @intCast(i) else -1;
    apply(txn, ts);
}

fn choose(ts: *Tabs, index: u32, window: siv.Window, focus: bool) void {
    const txn = w.begin(window) orelse return;
    const changed = ts.selected != @as(i32, @intCast(index));
    ts.selected = @intCast(index);
    apply(txn, ts);
    if (!w.commit(txn)) return;
    if (focus) if (nth(ts, index)) |t| {
        _ = c.siv_node_focus(t.root);
    };
    if (changed) w.emitChange(ts.root, @floatFromInt(index), index);
}

fn onPointer(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Tab = @ptrCast(@alignCast(ud.?));
    const ts = w.stateOf(Tabs, st.tabs, &.{.tabs}) orelse return .pass;
    if (button.feedback(&st.hdr, ev.?)) {
        const txn = w.begin(ev.?.window) orelse return .pass;
        apply(txn, ts);
        _ = w.commit(txn);
    }
    return .pass;
}

fn onActivate(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Tab = @ptrCast(@alignCast(ud.?));
    const ts = w.stateOf(Tabs, st.tabs, &.{.tabs}) orelse return .pass;
    if (ts.hdr.disabled) return .pass;
    choose(ts, indexOf(ts, st.root), ev.?.window, false);
    return .handled;
}

fn onKey(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Tab = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.pressed) return .pass;
    const ts = w.stateOf(Tabs, st.tabs, &.{.tabs}) orelse return .pass;
    const n = count(ts);
    if (n == 0 or ts.hdr.disabled) return .pass;
    const i = indexOf(ts, st.root);
    const k = w.keysym;
    const rtl = w.isRtl(st.root);
    const next: u32 = switch (e.keysym) {
        k.left => if (rtl) (i + 1) % n else (i + n - 1) % n,
        k.right => if (rtl) (i + n - 1) % n else (i + 1) % n,
        k.home => 0,
        k.end => n - 1,
        else => return .pass,
    };
    choose(ts, next, e.window, true);
    return .handled;
}
