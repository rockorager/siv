//! Combo boxes: a button showing the selected option, which opens the
//! list of options below it in a popup (xdg_popup, D17) made with the
//! public siv_popup_create.
//!
//! The options are a model in the tree, like a menu's items: a hidden
//! box under the combo box with one hidden child per option holding its
//! label, so the application relabels, disables, and removes options like
//! any nodes. Opening builds the popup from the model: a card with one row
//! per option, the selected one focused.
//!
//! Closed, Up, Down, Home, and End select an enabled option at once and
//! report `change`; Space, Enter, clicks, and Alt+Down open the list.
//! Open, the same keys move the focus between enabled rows, Space, Enter,
//! and clicks choose, and Escape closes; the popup's grab makes a click
//! outside dismiss it. Typing finds an option by the start of its label
//! (typeahead), closed or open. Layout is logical, so the button and the
//! list mirror in right-to-left layouts.

const std = @import("std");
const w = @import("widgets.zig");
const button = @import("button.zig");
const menu = @import("menu.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Combo = extern struct {
    hdr: w.Header,
    root: Node,
    /// The selected option's label, shown.
    label: Node,
    chevron: Node,
    /// The hidden box holding the options.
    model: Node,
    /// A hidden text node holding the accessible name.
    name: Node,
    /// Index of the selected option, or -1.
    selected: i32 = 0,
    /// The open list, or null.
    popup: siv.Window = .null,
    /// What was typed for typeahead, and when the last key came (the
    /// event's time, in milliseconds).
    typed: [32]u8 = undefined,
    typed_len: u32 = 0,
    typed_at: u32 = 0,
};

pub const Item = extern struct {
    hdr: w.Header,
    combo: Node,
    root: Node,
    label: Node,
};

/// An option's row in the open list.
pub const Row = extern struct {
    hdr: w.Header,
    combo: Node,
    index: u32,
    root: Node,
    label: Node,
    /// A check mark at the end edge of the selected option's row.
    mark: Node = .null,
    selected: bool = false,
    focused: bool = false,
};

/// Typed characters within this long of each other make one search.
const typeahead_ms: u32 = 1000;

pub export fn siv_combo_box(txn: Txn, parent: Node, desc: ?*const siv.ComboBoxDesc) Node {
    const d = w.readDesc(siv.ComboBoxDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 1) != 0 or d.reserved0 != 0) return w.fail(txn, .error_unsupported);
    const name = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    if (root == .null) return .null;
    const st = w.create(Combo, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .combo_box, .disabled = d.flags.disabled }, .root = root, .label = .null, .chevron = .null, .model = .null, .name = .null };
    st.label = c.siv_text(txn, root, "", 0);
    c.siv_set_layout(txn, st.label, &.{ .grow = 1 });
    st.chevron = c.siv_canvas(txn, root, &.{ .user_data = st, .draw = drawChevron, .width = 12, .height = 16 });
    st.model = c.siv_box(txn, root);
    c.siv_set_visual(txn, st.model, &.{ .flags = .{ .hidden = true } });
    c.siv_set_default_layout(txn, root, &.{
        .min_height = tk.control_height,
        .min_width = 120,
        .padding = .{ .start = tk.pad_x, .end = tk.pad_x - 2, .top = 4, .bottom = 4 },
    });
    st.name = w.hiddenText(txn, root, name);
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .activate, onActivate, st);
    w.onDefault(txn, root, .key, onKey, st);
    w.setInterface(txn, root, Combo, st, .{ .set_label = setName, .set_value = setValue, .get_value = value, .get_part = part, .apply = apply });
    apply(txn, st);
    return root;
}

pub export fn siv_combo_box_item(txn: Txn, combo: Node, desc: ?*const siv.ComboBoxItemDesc) Node {
    const cb = comboOf(combo) orelse return w.fail(txn, .error_invalid_argument);
    const d = w.readDesc(siv.ComboBoxItemDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 1) != 0 or d.reserved0 != 0) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_box(txn, cb.model);
    if (root == .null) return .null;
    const st = w.create(Item, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .combo_item, .disabled = d.flags.disabled }, .combo = combo, .root = root, .label = c.siv_text(txn, root, label.ptr, label.len) };
    w.setInterface(txn, root, Item, st, .{ .set_label = setItemLabel, .apply = applyItem });
    apply(txn, cb);
    return root;
}

fn comboOf(node: Node) ?*Combo {
    return w.stateOf(Combo, node, &.{.combo_box});
}

fn itemOf(node: Node) ?*Item {
    return w.stateOf(Item, node, &.{.combo_item});
}

/// The combo box's option at `index`.
fn nth(st: *const Combo, index: u32) ?*Item {
    var i: u32 = 0;
    var cur = w.related(st.model, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const it = itemOf(cur) orelse continue;
        if (i == index) return it;
        i += 1;
    }
    return null;
}

fn count(st: *const Combo) u32 {
    var i: u32 = 0;
    var cur = w.related(st.model, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        if (itemOf(cur) != null) i += 1;
    }
    return i;
}

fn value(st: *const Combo) f64 {
    return if (st.selected < @as(i32, @intCast(count(st)))) @floatFromInt(st.selected) else -1;
}

fn part(st: *const Combo, p: siv.WidgetPart, index: u32) Node {
    if (p != .item) return .null;
    return if (nth(st, index)) |it| it.root else .null;
}

/// Selects an option, or none with -1, without reporting it.
fn setValue(txn: Txn, st: *Combo, v: f64) void {
    const n: f64 = @floatFromInt(count(st));
    if (!std.math.isFinite(v) or @round(v) < -1 or @round(v) >= n) {
        c.siv_txn_fail(txn, .error_invalid_argument);
        return;
    }
    st.selected = @intFromFloat(@round(v));
    apply(txn, st);
}

fn setName(txn: Txn, st: *Combo, name: []const u8) void {
    c.siv_set_text(txn, st.name, name.ptr, name.len);
    apply(txn, st);
}

fn setItemLabel(txn: Txn, st: *Item, label: []const u8) void {
    c.siv_set_text(txn, st.label, label.ptr, label.len);
    if (comboOf(st.combo)) |cb| apply(txn, cb);
}

/// Options show their state when the list opens; a disabled selected
/// option stays selected.
fn applyItem(_: Txn, _: *Item) void {}

/// Shows the state: the selected label, fill, border, and semantics.
fn apply(txn: Txn, st: *Combo) void {
    // Removed options clamp the index; before any were added, the first
    // to come is selected.
    const n = count(st);
    if (n > 0 and st.selected >= @as(i32, @intCast(n))) st.selected = @as(i32, @intCast(n)) - 1;
    var buf: [1024]u8 = undefined;
    const shown = if (st.selected >= 0) if (nth(st, @intCast(st.selected))) |it| w.textOf(it.label, &buf) else "" else "";
    c.siv_set_text(txn, st.label, shown.ptr, shown.len);
    const h = st.hdr;
    const bg: siv.ColorToken = if (h.disabled) .control_bg else if (h.pressed) .control_active else if (h.hover) .control_hover else .control_bg;
    c.siv_set_visual(txn, st.root, &.{
        .radius = w.corners(tk.radius),
        .border_width = tk.border,
        .border_token = .border,
        .background_token = bg,
    });
    c.siv_set_text_style(txn, st.label, &w.textStyle(if (h.disabled) .disabled_fg else .control_fg, .body));
    c.siv_invalidate(txn, st.chevron);
    var name_buf: [1024]u8 = undefined;
    const name = w.textOf(st.name, &name_buf);
    c.siv_set_semantics(txn, st.root, &.{
        .label = name.ptr,
        .label_len = name.len,
        .role = .combo_box,
        .expanded = if (w.windowAlive(st.popup)) .on else .off,
        .flags = .{ .focusable = !h.disabled, .disabled = h.disabled },
    });
}

/// Applies the combo box's state in a transaction of its own.
fn refresh(st: *Combo) void {
    const txn = w.begin(w.windowOf(st.root)) orelse return;
    apply(txn, st);
    _ = w.commit(txn);
}

/// A chevron pointing down: the list opens below.
fn drawChevron(ud: ?*anyopaque, node: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const st: *Combo = @ptrCast(@alignCast(ud.?));
    const cx = width / 2;
    const cy = height / 2;
    c.siv_draw_move_to(draw, cx - 4, cy - 2);
    c.siv_draw_line_to(draw, cx, cy + 2);
    c.siv_draw_line_to(draw, cx + 4, cy - 2);
    c.siv_draw_stroke(draw, &.{ .width = 1.5, .join = .round, .cap = .round }, &.{ .color = w.color(w.windowOf(node), if (st.hdr.disabled) .disabled_fg else .muted_fg) });
}

fn onPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Combo = @ptrCast(@alignCast(ud.?));
    if (button.feedback(&st.hdr, ev)) refresh(st);
    return .pass;
}

fn onActivate(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Combo = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .pass;
    open(st);
    return .handled;
}

fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Combo = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled or !ev.flags.pressed) return .pass;
    const k = w.keysym;
    if (ev.keysym == k.down and ev.modifiers.alt) {
        open(st);
        return .handled;
    }
    if (ev.modifiers.ctrl or ev.modifiers.alt or ev.modifiers.super) return .pass;
    const cur: i64 = st.selected;
    const n: i64 = count(st);
    const to: ?u32 = switch (ev.keysym) {
        k.up => step(st, cur - 1, -1),
        k.down => step(st, cur + 1, 1),
        k.home => step(st, 0, 1),
        k.end => step(st, n - 1, -1),
        else => typeahead(st, ev, if (cur < 0) null else @intCast(cur)) orelse return .pass,
    };
    if (to) |i| choose(st, i);
    return .handled;
}

/// The first enabled option from `from` in direction `dir`, without
/// wrapping.
fn step(st: *const Combo, from: i64, dir: i2) ?u32 {
    var i = from;
    const n: i64 = count(st);
    while (i >= 0 and i < n) : (i += dir) {
        const it = nth(st, @intCast(i)) orelse return null;
        if (!it.hdr.disabled) return @intCast(i);
    }
    return null;
}

/// Adds a key's text to what was typed and finds the enabled option it
/// leads to from `current`: the next whose label starts with the typed
/// text, or, when one character was typed repeatedly, the next starting
/// with it. Null when the key typed nothing; `.{null}` when nothing
/// matches.
fn typeahead(st: *Combo, ev: *const siv.Event, current: ?u32) ??u32 {
    const text = w.str(ev.text, ev.text_len) orelse return null;
    if (text.len == 0 or text[0] < 0x20 or text[0] == 0x7f) return null;
    if (st.typed_len != 0 and ev.time -% st.typed_at > typeahead_ms) st.typed_len = 0;
    st.typed_at = ev.time;
    if (st.typed_len + text.len <= st.typed.len) {
        @memcpy(st.typed[st.typed_len..][0..text.len], text);
        st.typed_len += @intCast(text.len);
    }
    const typed = st.typed[0..st.typed_len];
    // The same character again cycles through the options it starts.
    var same = true;
    for (typed) |b| same = same and b == typed[0];
    const needle = if (same and typed.len > 1) typed[0..1] else typed;
    // A new search starts after the current option; a longer one may
    // still match it.
    const n = count(st);
    if (n == 0) return @as(?u32, null);
    const start: u32 = if (current) |cur| (if (needle.len == typed.len and typed.len > 1) cur else cur + 1) else 0;
    var buf: [1024]u8 = undefined;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const i = (start + k) % n;
        const it = nth(st, i) orelse continue;
        if (it.hdr.disabled) continue;
        const label = w.textOf(it.label, &buf);
        if (label.len >= needle.len and std.ascii.eqlIgnoreCase(label[0..needle.len], needle)) return i;
    }
    return @as(?u32, null);
}

/// Selects an option the user chose, and reports it.
fn choose(st: *Combo, index: u32) void {
    const node = st.root;
    if (st.selected == @as(i32, @intCast(index))) return;
    st.selected = @intCast(index);
    refresh(st);
    w.emitChange(node, @floatFromInt(index), index);
}

// The list ---------------------------------------------------------------------

/// Opens the list below the combo box, the selected option focused.
fn open(st: *Combo) void {
    if (w.windowAlive(st.popup)) return;
    const parent_window = w.windowOf(st.root);
    var popup: siv.Window = .null;
    if (c.siv_popup_create(parent_window, &.{ .anchor = st.root, .placement = .below, .user_data = w.handleData(st.root), .on_event = onPopupEvent }, &popup) != .ok) return;
    const txn = w.begin(popup) orelse {
        c.siv_window_destroy(popup);
        return;
    };
    const root = c.siv_window_get_root(popup);
    menu.cardVisual(txn, root);
    var rect: siv.Rect = undefined;
    if (c.siv_node_get_rect(st.root, &rect) != .ok) rect.width = 0;
    const scroll = c.siv_scroll(txn, root, .vertical);
    c.siv_set_layout(txn, scroll, &.{ .max_height = 320 });
    const col = c.siv_flex(txn, scroll, &.{ .axis = .column });
    c.siv_set_layout(txn, col, &.{ .min_width = @max(0, rect.width - 2 * tk.border), .padding = .{ .start = 4, .end = 4, .top = 4, .bottom = 4 } });
    var buf: [1024]u8 = undefined;
    const name = w.textOf(st.name, &buf);
    c.siv_set_semantics(txn, col, &.{ .role = .list, .label = name.ptr, .label_len = name.len });
    const n = count(st);
    var focus: Node = .null;
    var first: Node = .null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const it = nth(st, i) orelse break;
        const row = buildRow(txn, col, st, it, i, &buf);
        if (it.hdr.disabled) continue;
        if (first == .null) first = row;
        if (st.selected == @as(i32, @intCast(i))) focus = row;
    }
    if (!w.commit(txn) or c.siv_popup_show(popup) != .ok) {
        c.siv_window_destroy(popup);
        return;
    }
    st.popup = popup;
    st.typed_len = 0;
    if (focus == .null) focus = first;
    if (focus != .null) _ = c.siv_node_focus(focus);
    refresh(st);
}

fn close(st: *Combo) void {
    if (w.windowAlive(st.popup)) c.siv_window_destroy(st.popup);
    st.popup = .null;
    refresh(st);
}

fn buildRow(txn: Txn, col: Node, cb: *Combo, it: *Item, index: u32, buf: []u8) Node {
    const row = c.siv_flex(txn, col, &.{ .axis = .row, .align_items = .center });
    c.siv_set_layout(txn, row, &.{ .min_height = 28, .padding = .{ .start = tk.pad_x - 4, .end = tk.pad_x - 4, .top = 2, .bottom = 2 } });
    const st = w.create(Row, txn, row) orelse return .null;
    const label = w.textOf(it.label, buf);
    st.* = .{ .hdr = .{ .kind = .combo_row, .disabled = it.hdr.disabled }, .combo = cb.root, .index = index, .root = row, .label = c.siv_text(txn, row, label.ptr, label.len), .selected = cb.selected == @as(i32, @intCast(index)) };
    c.siv_set_layout(txn, st.label, &.{ .grow = 1 });
    st.mark = c.siv_canvas(txn, row, &.{ .user_data = st, .draw = drawMark, .width = 16, .height = 16 });
    w.onDefault(txn, row, .pointer, onRowPointer, st);
    w.onDefault(txn, row, .focus, onRowFocus, st);
    w.onDefault(txn, row, .activate, onRowActivate, st);
    w.onDefault(txn, row, .key, onRowKey, st);
    applyRow(txn, st);
    return row;
}

fn applyRow(txn: Txn, st: *Row) void {
    const disabled = st.hdr.disabled;
    const lit = st.focused and !disabled;
    const selected = st.selected;
    c.siv_set_visual(txn, st.root, &.{ .radius = w.corners(tk.radius - 2), .background_token = if (lit) .selection_bg else .none });
    c.siv_set_text_style(txn, st.label, &w.textStyle(if (disabled) .disabled_fg else if (lit) .selection_fg else .card_fg, .body));
    c.siv_set_semantics(txn, st.root, &.{
        .role = .list_item,
        .selected = if (selected) .on else .off,
        .flags = .{ .focusable = !disabled, .disabled = disabled },
    });
    c.siv_invalidate(txn, st.mark);
}

fn drawMark(ud: ?*anyopaque, node: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    if (!st.selected) return;
    const lit = st.focused and !st.hdr.disabled;
    w.drawCheck(draw, width, height, w.color(w.windowOf(node), if (lit) .selection_fg else .card_fg), false);
}

fn rowCombo(st: *const Row) ?*Combo {
    return comboOf(st.combo);
}

fn onRowPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    if (ev.phase == .enter and !st.hdr.disabled) _ = c.siv_node_focus(st.root);
    return .pass;
}

fn onRowFocus(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    st.focused = ev.flags.gained;
    const txn = w.begin(ev.window) orelse return .pass;
    applyRow(txn, st);
    _ = w.commit(txn);
    return .pass;
}

fn onRowActivate(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .handled;
    // The row's state goes with the popup: copy what is needed first.
    const index = st.index;
    const cb = rowCombo(st) orelse return .handled;
    close(cb);
    choose(cb, index);
    return .handled;
}

fn onRowKey(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.pressed) return .pass;
    const cb = rowCombo(st) orelse return .pass;
    const k = w.keysym;
    const list = w.related(node, .parent);
    switch (ev.keysym) {
        k.escape, k.tab => close(cb),
        k.up => focusRow(cb, list, step(cb, @as(i64, st.index) - 1, -1)),
        k.down => if (ev.modifiers.alt) close(cb) else focusRow(cb, list, step(cb, @as(i64, st.index) + 1, 1)),
        k.home => focusRow(cb, list, step(cb, 0, 1)),
        k.end => focusRow(cb, list, step(cb, @as(i64, count(cb)) - 1, -1)),
        else => {
            if (ev.modifiers.ctrl or ev.modifiers.alt or ev.modifiers.super) return .pass;
            const to = typeahead(cb, ev, st.index) orelse return .pass;
            focusRow(cb, list, to);
        },
    }
    return .handled;
}

/// Focuses the list's row for option `index`.
fn focusRow(_: *Combo, list: Node, index: ?u32) void {
    const i = index orelse return;
    var cur = w.related(list, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const r = w.stateOf(Row, cur, &.{.combo_row}) orelse continue;
        if (r.index == i) {
            _ = c.siv_node_focus(cur);
            return;
        }
    }
}

/// Dismissed by the compositor (a click outside): the list goes.
fn onPopupEvent(ud: ?*anyopaque, _: siv.Window, ev: *const siv.WindowEvent) callconv(.c) bool {
    if (ev.type != .close_requested) return false;
    if (comboOf(w.dataHandle(ud))) |st| {
        st.popup = .null;
        refresh(st);
    }
    return false;
}
