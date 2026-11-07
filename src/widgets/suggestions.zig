//! Suggestion lists (D22): suggestions for what is typed into a node,
//! usually a text field, in a card under it that the core lays out
//! against it (`siv_set_anchor`, D26): as wide as it, flipped above it
//! when only that fits, slid and clamped inside the parent stack. The
//! anchor keeps the keyboard focus. Its keys come here first: a stock
//! text field forwards them (field.zig), any other anchor gets this
//! module's default key and focus handlers. Down and Up move the
//! highlight, Enter and Tab choose, Escape closes; the pointer
//! highlights on hover and chooses on click without taking the focus.
//!
//! The highlighted item is `selected` for assistive technology and,
//! since the focus stays in the anchor and siv has no active descendant,
//! announced through a live status in the list (D18).

const std = @import("std");
const w = @import("widgets.zig");
const field = @import("field.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const List = extern struct {
    hdr: w.Header,
    root: Node,
    anchor: Node,
    /// A live status that announces the highlighted item.
    status: Node,
    scroll: Node,
    rows: Node,
    /// The highlighted item's index; -1 for none.
    highlighted: i32 = -1,
    open: bool = false,
};

pub const Item = extern struct {
    hdr: w.Header,
    list: Node,
    root: Node,
    label: Node,
    detail: Node,
    icon: Node = .null,
    icon_name: Node = .null,
    highlighted: bool = false,
};

pub export fn siv_suggestion_list(txn: Txn, parent: Node, desc: ?*const siv.SuggestionListDesc) Node {
    const d = w.readDesc(siv.SuggestionListDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    if (d.anchor == .null or !inside(d.anchor, parent)) return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = .column, .align_items = .stretch });
    if (root == .null) return .null;
    const st = w.create(List, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .suggestion_list }, .root = root, .anchor = d.anchor, .status = .null, .scroll = .null, .rows = .null };
    _ = c.siv_set_anchor(txn, root, &.{ .anchor = d.anchor, .gap = tk.suggestion_gap, .flags = .{ .match_width = true } });
    _ = c.siv_set_visual(txn, root, &.{
        .background_token = .card_bg,
        .border_token = .border,
        .border_width = tk.border,
        .radius = w.corners(tk.radius),
        .flags = .{ .clip = true },
        .shadows = @ptrCast(&shadow),
        .shadows_count = 1,
    });
    _ = c.siv_set_default_layout(txn, root, &.{ .max_height = 8 * tk.suggestion_row + 8 + 2 * tk.border });
    const name = if (label.len == 0) "Suggestions" else label;
    _ = c.siv_set_semantics(txn, root, &.{ .role = .list, .label = name.ptr, .label_len = name.len });
    st.status = c.siv_box(txn, root);
    _ = c.siv_set_semantics(txn, st.status, &.{ .role = .status, .flags = .{ .live_polite = true } });
    st.scroll = c.siv_scroll(txn, root, .vertical);
    _ = c.siv_set_layout(txn, st.scroll, &.{ .shrink = 1 });
    st.rows = c.siv_flex(txn, st.scroll, &.{ .axis = .column, .align_items = .stretch });
    _ = c.siv_set_layout(txn, st.rows, &.{ .padding = .{ .start = 4, .end = 4, .top = 4, .bottom = 4 } });
    _ = c.siv_set_semantics(txn, st.rows, &.{ .role = .none });
    _ = c.siv_set_hidden(txn, root, true);
    w.onDefault(txn, root, .close, onClose, st);
    if (w.stateOf(field.Field, d.anchor, &.{.text_field})) |f| {
        f.list = root;
        field.apply(txn, f);
    } else {
        _ = c.siv_on_default(txn, d.anchor, .key, onAnchorKey, null, w.handleData(root));
        _ = c.siv_on_default(txn, d.anchor, .focus, onAnchorFocus, null, w.handleData(root));
    }
    w.setInterface(txn, root, List, st, .{ .set_value = setValue, .get_value = getValue, .get_part = getPart });
    return root;
}

const shadow = [1]siv.Shadow{.{ .offset_y = 8, .blur = 24, .color_token = .shadow }};

/// Whether `node` is `ancestor` or inside it.
fn inside(node: Node, ancestor: Node) bool {
    var n = node;
    while (n != .null) : (n = w.related(n, .parent)) if (n == ancestor) return true;
    return false;
}

pub export fn siv_suggestion_list_item(txn: Txn, list: Node, desc: ?*const siv.SuggestionListItemDesc) Node {
    const d = w.readDesc(siv.SuggestionListItemDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 1) != 0 or d.reserved0 != 0) return w.fail(txn, .error_unsupported);
    const ls = w.stateOf(List, list, &.{.suggestion_list}) orelse return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const detail = w.str(d.detail, d.detail_len) orelse return w.fail(txn, .error_invalid_argument);
    const icon = w.str(d.icon, d.icon_len) orelse return w.fail(txn, .error_invalid_argument);
    const row = c.siv_flex(txn, ls.rows, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    if (row == .null) return .null;
    const st = w.create(Item, txn, row) orelse return .null;
    st.* = .{
        .hdr = .{ .kind = .suggestion_item, .disabled = d.flags.disabled },
        .list = list,
        .root = row,
        .label = c.siv_text(txn, row, label.ptr, label.len),
        .detail = c.siv_text(txn, row, detail.ptr, detail.len),
    };
    _ = c.siv_set_default_layout(txn, row, &.{ .min_height = tk.suggestion_row, .padding = .{ .start = tk.pad_x - 4, .end = tk.pad_x - 4 } });
    _ = c.siv_set_layout(txn, st.label, &.{ .shrink = 1 });
    _ = c.siv_set_layout(txn, st.detail, &.{ .grow = 1, .shrink = 1, .basis = w.px(0) });
    if (icon.len != 0) {
        st.icon = c.siv_image_view(txn, row, &.{ .icon = icon.ptr, .icon_len = icon.len, .icon_size = tk.icon_size });
        _ = c.siv_move(txn, st.icon, row, st.label);
        st.icon_name = w.hiddenText(txn, row, icon);
    }
    w.onDefault(txn, row, .pointer, onItemPointer, st);
    w.setInterface(txn, row, Item, st, .{ .set_label = setItemLabel, .apply = applyItem });
    // Every item's position and the set's size change.
    var i: u32 = 0;
    while (nth(ls, i)) |other| : (i += 1) applyItem(txn, other);
    if (!st.hdr.disabled) {
        if (ls.highlighted < 0) highlight(txn, ls, @intCast(count(ls) - 1));
        setOpen(txn, ls, true);
    }
    // The set grew.
    announce(txn, ls);
    return row;
}

pub export fn siv_suggestion_list_clear(txn: Txn, list: Node) void {
    const st = w.stateOf(List, list, &.{.suggestion_list}) orelse {
        _ = w.fail(txn, .error_invalid_argument);
        return;
    };
    var row = w.related(st.rows, .first_child);
    while (row != .null) {
        const next = w.related(row, .next);
        _ = c.siv_remove(txn, row);
        row = next;
    }
    st.highlighted = -1;
    _ = c.siv_set_semantics(txn, st.status, &.{ .role = .status, .flags = .{ .live_polite = true } });
    setOpen(txn, st, false);
}

/// Shows or hides the list, and tells a stock text field anchor.
fn setOpen(txn: Txn, st: *List, open: bool) void {
    st.open = open;
    _ = c.siv_set_hidden(txn, st.root, !open);
    if (w.stateOf(field.Field, st.anchor, &.{.text_field})) |f| field.apply(txn, f);
}

fn count(st: *const List) u32 {
    var n: u32 = 0;
    var row = w.related(st.rows, .first_child);
    while (row != .null) : (row = w.related(row, .next)) {
        if (w.stateOf(Item, row, &.{.suggestion_item}) != null) n += 1;
    }
    return n;
}

fn nth(st: *const List, index: u32) ?*Item {
    var i: u32 = 0;
    var row = w.related(st.rows, .first_child);
    while (row != .null) : (row = w.related(row, .next)) {
        const it = w.stateOf(Item, row, &.{.suggestion_item}) orelse continue;
        if (i == index) return it;
        i += 1;
    }
    return null;
}

fn indexOf(it: *const Item) ?u32 {
    const st = w.stateOf(List, it.list, &.{.suggestion_list}) orelse return null;
    var i: u32 = 0;
    var row = w.related(st.rows, .first_child);
    while (row != .null) : (row = w.related(row, .next)) {
        if (row == it.root) return i;
        if (w.stateOf(Item, row, &.{.suggestion_item}) != null) i += 1;
    }
    return null;
}

/// Whether a stock text field anchor shows its list (field.zig).
pub fn isOpen(list: Node) bool {
    const st = w.stateOf(List, list, &.{.suggestion_list}) orelse return false;
    return st.open;
}

/// Moves the highlight to item `index`, or to none with -1, and
/// announces it.
fn highlight(txn: Txn, st: *List, index: i32) void {
    const n = count(st);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const it = nth(st, i) orelse break;
        const on = @as(i32, @intCast(i)) == index;
        if (it.highlighted == on) continue;
        it.highlighted = on;
        applyItem(txn, it);
    }
    st.highlighted = index;
    announce(txn, st);
}

/// Names the live status after the highlighted item and its place, which
/// assistive technology announces when it changes.
fn announce(txn: Txn, st: *List) void {
    const index = st.highlighted;
    const n = count(st);
    var buf: [1100]u8 = undefined;
    var text: []const u8 = "";
    if (index >= 0) if (nth(st, @intCast(index))) |it| {
        var lb: [512]u8 = undefined;
        var db: [512]u8 = undefined;
        const label = w.textOf(it.label, &lb);
        const detail = w.textOf(it.detail, &db);
        text = if (detail.len == 0)
            std.fmt.bufPrint(&buf, "{s}, {d} of {d}", .{ label, index + 1, n }) catch label
        else
            std.fmt.bufPrint(&buf, "{s}, {s}, {d} of {d}", .{ label, detail, index + 1, n }) catch label;
    };
    _ = c.siv_set_semantics(txn, st.status, &.{ .role = .status, .label = text.ptr, .label_len = text.len, .flags = .{ .live_polite = true } });
}

/// The next enabled item from `from` going `dir`, wrapping; null when
/// none is enabled.
fn step(st: *const List, from: i32, dir: i32) ?u32 {
    const n: i32 = @intCast(count(st));
    if (n == 0) return null;
    var i = if (from < 0) (if (dir > 0) n - 1 else 0) else from;
    var k: i32 = 0;
    while (k < n) : (k += 1) {
        i = @mod(i + dir, n);
        const it = nth(st, @intCast(i)) orelse return null;
        if (!it.hdr.disabled) return @intCast(i);
    }
    return null;
}

/// Scrolls the highlighted row into view, from the rows' places in the
/// last frame.
fn reveal(st: *List) void {
    if (st.highlighted < 0) return;
    const it = nth(st, @intCast(st.highlighted)) orelse return;
    const first = nth(st, 0) orelse return;
    var view: siv.Rect = .{};
    var row: siv.Rect = .{};
    var top: siv.Rect = .{};
    if (c.siv_node_get_rect(st.scroll, &view) != .ok or c.siv_node_get_rect(it.root, &row) != .ok or c.siv_node_get_rect(first.root, &top) != .ok) return;
    if (view.height <= 0) return;
    const offset = view.y + 4 - top.y;
    const to = if (row.y < view.y)
        offset - (view.y - row.y) - 4
    else if (row.y + row.height > view.y + view.height)
        offset + (row.y + row.height - view.y - view.height) + 4
    else
        return;
    const txn = w.begin(w.windowOf(st.root)) orelse return;
    _ = c.siv_scroll_to(txn, st.scroll, 0, @max(0, to));
    _ = w.commit(txn);
}

/// Hides the list and reports the item chosen.
fn choose(st: *List, index: u32) void {
    const it = nth(st, index) orelse return;
    if (it.hdr.disabled) return;
    const node = st.root;
    const txn = w.begin(w.windowOf(node)) orelse return;
    setOpen(txn, st, false);
    if (!w.commit(txn)) return;
    var handled = false;
    _ = c.siv_node_emit(node, &.{ .type = .select, .index = index, .count = 1 }, &handled);
}

fn askClose(node: Node) void {
    var handled = false;
    _ = c.siv_node_emit(node, &.{ .type = .close }, &handled);
}

/// The anchor's keys while the list shows; whether they were the list's.
pub fn anchorKey(list: Node, ev: *const siv.Event) bool {
    const st = w.stateOf(List, list, &.{.suggestion_list}) orelse return false;
    if (!st.open or !ev.flags.pressed) return false;
    if (ev.modifiers.ctrl or ev.modifiers.alt or ev.modifiers.super) return false;
    const k = w.keysym;
    switch (ev.keysym) {
        k.down, k.up => {
            const to = step(st, st.highlighted, if (ev.keysym == k.down) 1 else -1) orelse return true;
            const txn = w.begin(ev.window) orelse return true;
            highlight(txn, st, @intCast(to));
            _ = w.commit(txn);
            reveal(st);
            return true;
        },
        k.@"return", k.kp_enter, k.tab => {
            if (ev.modifiers.shift or st.highlighted < 0) return false;
            choose(st, @intCast(st.highlighted));
            return true;
        },
        k.escape => {
            askClose(list);
            return true;
        },
        else => return false,
    }
}

/// The anchor lost the focus: the list asks to close.
pub fn anchorFocus(list: Node, gained: bool) void {
    const st = w.stateOf(List, list, &.{.suggestion_list}) orelse return;
    if (!gained and st.open) askClose(list);
}

fn onAnchorKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    return w.resultOf(anchorKey(w.dataHandle(ud), ev));
}

fn onAnchorFocus(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    anchorFocus(w.dataHandle(ud), ev.flags.gained);
    return .pass;
}

/// Hides the list.
fn onClose(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *List = @ptrCast(@alignCast(ud.?));
    const txn = w.begin(ev.window) orelse return .pass;
    setOpen(txn, st, false);
    _ = w.commit(txn);
    return .handled;
}

fn getValue(st: *const List) f64 {
    return @floatFromInt(st.highlighted);
}

fn setValue(txn: Txn, st: *List, v: f64) void {
    const n: f64 = @floatFromInt(count(st));
    const i: i32 = if (v < 0 or n == 0) -1 else @intFromFloat(@min(@floor(v), n - 1));
    highlight(txn, st, i);
}

fn getPart(st: *const List, part: siv.WidgetPart, index: u32) Node {
    if (part != .item) return .null;
    return if (nth(st, index)) |it| it.root else .null;
}

// Items ----------------------------------------------------------------------------

fn applyItem(txn: Txn, st: *Item) void {
    const off = st.hdr.disabled;
    const lit = st.highlighted and !off;
    _ = c.siv_set_visual(txn, st.root, &.{ .radius = w.corners(tk.radius - 2), .background_token = if (lit) .selection_bg else .none });
    _ = c.siv_set_text_style(txn, st.label, &.{
        .color_token = if (off) .disabled_fg else if (lit) .selection_fg else .card_fg,
        .size_role = .body,
        .weight = .medium,
        .flags = .{ .no_wrap = true, .ellipsize = true },
    });
    _ = c.siv_set_text_style(txn, st.detail, &.{
        .color_token = if (off) .disabled_fg else if (lit) .selection_fg else .muted_fg,
        .size_role = .body,
        .flags = .{ .no_wrap = true, .ellipsize = true },
    });
    if (st.icon != .null) w.setIcon(txn, st.icon, st.icon_name, tk.icon_size, if (off) .disabled_fg else if (lit) .selection_fg else .card_fg);
    var lb: [512]u8 = undefined;
    var db: [512]u8 = undefined;
    var buf: [1100]u8 = undefined;
    const label = w.textOf(st.label, &lb);
    const detail = w.textOf(st.detail, &db);
    const name = if (detail.len == 0) label else std.fmt.bufPrint(&buf, "{s}, {s}", .{ label, detail }) catch label;
    const ls = w.stateOf(List, st.list, &.{.suggestion_list});
    const pos = indexOf(st);
    _ = c.siv_set_semantics(txn, st.root, &.{
        .role = .list_item,
        .label = name.ptr,
        .label_len = name.len,
        .selected = if (lit) .on else .off,
        .position = if (pos) |p| p + 1 else 0,
        .set_size = if (ls) |l| count(l) else 0,
        .flags = .{ .disabled = off },
    });
}

fn setItemLabel(txn: Txn, st: *Item, label: []const u8) void {
    _ = c.siv_set_text(txn, st.label, label.ptr, label.len);
    applyItem(txn, st);
}

/// Hovering highlights; a press keeps the focus where it is, and its
/// release over the item chooses it.
fn onItemPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Item = @ptrCast(@alignCast(ud.?));
    const ls = w.stateOf(List, st.list, &.{.suggestion_list}) orelse return .pass;
    switch (ev.phase) {
        .enter, .move => {
            st.hdr.hover = true;
            if (st.hdr.disabled or st.highlighted) return .pass;
            const i = indexOf(st) orelse return .pass;
            const txn = w.begin(ev.window) orelse return .pass;
            highlight(txn, ls, @intCast(i));
            _ = w.commit(txn);
            return .pass;
        },
        .leave => {
            st.hdr.hover = false;
            st.hdr.pressed = false;
            return .pass;
        },
        .down => {
            if (ev.button != .primary) return .pass;
            st.hdr.pressed = !st.hdr.disabled;
            return .handled;
        },
        .up => {
            if (ev.button != .primary) return .pass;
            const chosen = st.hdr.pressed and st.hdr.hover;
            st.hdr.pressed = false;
            if (chosen) if (indexOf(st)) |i| choose(ls, i);
            return .handled;
        },
        .cancel => {
            st.hdr.pressed = false;
            return .pass;
        },
        else => return .pass,
    }
}
