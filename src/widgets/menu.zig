//! Menus and popovers, shown in popups (xdg_popup, D17) made with the
//! public siv_popup_create.
//!
//! A menu is a model in the tree: a node that takes no space, with one
//! hidden child per item holding its label and shortcut as text, so the
//! application adds, relabels, disables, and removes items like any
//! nodes. siv_menu_open builds a popup from the model: a card with one
//! row per item. Up and Down move focus between enabled rows (wrapping),
//! Home and End go to the ends, Enter, Space, and clicks choose, and
//! Escape closes; the popup's grab makes a click outside dismiss it.
//! Choosing reports `select` with the item's index on the menu (or the
//! menu button that owns it) after the popup is gone.
//!
//! A popover is a popup whose root is a themed card with a content part
//! the application fills; Escape and dismissal report `close` on the
//! content, whose default handler destroys the popup.

const std = @import("std");
const w = @import("widgets.zig");
const button = @import("button.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Menu = extern struct {
    hdr: w.Header,
    root: Node,
    /// Where `select` is reported: the menu, or its menu button.
    owner: Node,
    /// The open popup, or null.
    popup: siv.Window = .null,
};

pub const Item = extern struct {
    hdr: w.Header,
    separator: bool = false,
    checkable: bool = false,
    checked: bool = false,
    mnemonic: u32 = 0,
    root: Node,
    label: Node,
    shortcut: Node,
};

/// A menu item's row in an open popup.
pub const Row = extern struct {
    hdr: w.Header,
    index: u32,
    item: Node,
    menu: Node,
    root: Node,
    label: Node,
    shortcut: Node,
    mark: Node = .null,
};

pub const Popover = extern struct {
    hdr: w.Header,
    root: Node,
    content: Node,
    popup: siv.Window,
};

pub export fn siv_menu(txn: Txn, parent: Node, desc: ?*const siv.MenuDesc) Node {
    const d = w.readDesc(siv.MenuDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    return createModel(txn, parent, label, .null);
}

/// A menu model under `parent`; `owner` gets its `select` events (0: the
/// model itself).
pub fn createModel(txn: Txn, parent: Node, label: []const u8, owner: Node) Node {
    const root = c.siv_box(txn, parent);
    if (root == .null) return .null;
    _ = c.siv_set_visual(txn, root, &.{ .flags = .{ .hidden = true } });
    _ = c.siv_set_semantics(txn, root, &.{ .role = .menu, .label = label.ptr, .label_len = label.len });
    const st = w.create(Menu, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .menu }, .root = root, .owner = if (owner == .null) root else owner };
    return root;
}

fn menuOf(node: Node) ?*Menu {
    const h = w.header(node) orelse return null;
    return switch (h.kind) {
        .menu => @ptrCast(h),
        .menu_button => w.stateOf(Menu, @as(*button.Button, @ptrCast(h)).menu, &.{.menu}),
        else => null,
    };
}

pub export fn siv_menu_item(txn: Txn, menu_node: Node, desc: ?*const siv.MenuItemDesc) Node {
    const m = menuOf(menu_node) orelse return w.fail(txn, .error_invalid_argument);
    const d = w.readDesc(siv.MenuItemDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 15) != 0) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const shortcut = w.str(d.shortcut, d.shortcut_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_box(txn, m.root);
    if (root == .null) return .null;
    const st = w.create(Item, txn, root) orelse return .null;
    st.* = .{
        .hdr = .{ .kind = .menu_item, .disabled = d.flags.disabled },
        .separator = d.flags.separator,
        .checkable = d.flags.checkable or d.flags.checked,
        .checked = d.flags.checked,
        .mnemonic = d.mnemonic,
        .root = root,
        .label = c.siv_text(txn, root, label.ptr, label.len),
        .shortcut = c.siv_text(txn, root, shortcut.ptr, shortcut.len),
    };
    _ = c.siv_set_semantics(txn, root, &.{ .role = if (st.separator) .separator else .menu_item });
    return root;
}

pub fn setItemLabel(txn: Txn, st: *Item, label: []const u8) void {
    _ = c.siv_set_text(txn, st.label, label.ptr, label.len);
}

pub fn itemValue(st: *const Item) f64 {
    return if (st.checked) 1 else 0;
}

pub fn setItemValue(txn: Txn, st: *Item, v: f64) void {
    if (!st.checkable) {
        _ = c.siv_txn_fail(txn, .error_invalid_argument);
        return;
    }
    st.checked = v >= 0.5;
}

fn itemOf(node: Node) ?*Item {
    return w.stateOf(Item, node, &.{.menu_item});
}

fn textOf(node: Node, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_node_get_text(node, buf.ptr, buf.len, &len) != .ok) return "";
    return buf[0..@min(len, buf.len)];
}

pub export fn siv_menu_open(menu_node: Node, anchor: Node) siv.Result {
    const m = menuOf(menu_node) orelse return .error_invalid_argument;
    if (w.windowAlive(m.popup)) return .ok;
    const at = if (anchor != .null) anchor else w.related(m.owner, .parent);
    const parent_window = w.windowOf(at);
    if (parent_window == .null) return .error_invalid_argument;
    var popup: siv.Window = .null;
    var r = c.siv_popup_create(parent_window, &.{
        .anchor = at,
        .placement = .below,
        .user_data = w.handleData(m.root),
        .on_event = onMenuPopupEvent,
    }, &popup);
    if (r != .ok) return r;
    var checkable = false;
    var cur = w.related(m.root, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        if (itemOf(cur)) |it| checkable = checkable or it.checkable;
    }
    var txn: Txn = .null;
    r = c.siv_txn_begin(popup, &txn);
    if (r != .ok) {
        _ = c.siv_window_destroy(popup);
        return r;
    }
    const root = c.siv_window_root(popup);
    cardVisual(txn, root);
    var buf: [1024]u8 = undefined;
    const name = w.labelOf(m.root, &buf);
    const col = c.siv_flex(txn, root, &.{ .axis = .column });
    _ = c.siv_set_layout(txn, col, &.{ .min_width = 180, .padding = .{ .start = 4, .end = 4, .top = 4, .bottom = 4 } });
    _ = c.siv_set_semantics(txn, col, &.{ .role = .menu, .label = name.ptr, .label_len = name.len });
    var first: Node = .null;
    var index: u32 = 0;
    cur = w.related(m.root, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const it = itemOf(cur) orelse continue;
        defer index += 1;
        if (it.separator) {
            const sep = c.siv_box(txn, col);
            _ = c.siv_set_layout(txn, sep, &.{ .height = w.px(1), .padding = .{ .top = 0 } });
            _ = c.siv_set_visual(txn, sep, &.{ .background_token = .separator });
            _ = c.siv_set_semantics(txn, sep, &.{ .role = .separator });
            continue;
        }
        const row = buildRow(txn, col, m, it, index, checkable, &buf);
        if (first == .null and !it.hdr.disabled) first = row;
    }
    r = c.siv_txn_commit(txn);
    if (r == .ok) r = c.siv_popup_show(popup);
    if (r != .ok) {
        _ = c.siv_window_destroy(popup);
        return r;
    }
    m.popup = popup;
    if (first != .null) _ = c.siv_node_focus(first);
    button.setExpanded(m.owner, true);
    return .ok;
}

fn buildRow(txn: Txn, col: Node, m: *Menu, it: *Item, index: u32, checkable: bool, buf: []u8) Node {
    const row = c.siv_flex(txn, col, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    _ = c.siv_set_layout(txn, row, &.{ .min_height = 28, .padding = .{ .start = 10, .end = 10, .top = 2, .bottom = 2 } });
    const st = w.create(Row, txn, row) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .menu_row, .disabled = it.hdr.disabled }, .index = index, .item = it.root, .menu = m.root, .root = row, .label = .null, .shortcut = .null };
    if (checkable) {
        st.mark = c.siv_canvas(txn, row, &.{ .user_data = st, .draw = drawRowMark, .width = 16, .height = 16 });
    }
    const label = textOf(it.label, buf);
    st.label = c.siv_text(txn, row, label.ptr, label.len);
    _ = c.siv_set_layout(txn, st.label, &.{ .grow = 1 });
    const shortcut = textOf(it.shortcut, buf);
    st.shortcut = c.siv_text(txn, row, shortcut.ptr, shortcut.len);
    _ = c.siv_set_visual(txn, st.shortcut, &.{ .flags = .{ .hidden = shortcut.len == 0 } });
    w.onDefault(txn, row, .pointer, onRowPointer, st);
    w.onDefault(txn, row, .focus, onRowFocus, st);
    w.onDefault(txn, row, .activate, onRowActivate, st);
    w.onDefault(txn, row, .key, onRowKey, st);
    applyRow(txn, st, false);
    return row;
}

fn applyRow(txn: Txn, st: *Row, focused: bool) void {
    const it = itemOf(st.item);
    const disabled = st.hdr.disabled;
    const lit = focused and !disabled;
    _ = c.siv_set_visual(txn, st.root, &.{ .radius = w.corners(tk.radius - 2), .background_token = if (lit) .selection_bg else .none });
    _ = c.siv_set_text_style(txn, st.label, &w.textStyle(if (disabled) .disabled_fg else if (lit) .selection_fg else .card_fg, .body));
    _ = c.siv_set_text_style(txn, st.shortcut, &w.textStyle(if (lit) .selection_fg else .muted_fg, .caption));
    const checkable = if (it) |i| i.checkable else false;
    const checked = if (it) |i| i.checked else false;
    // Named by the label alone: the shortcut is not part of the name.
    var buf: [1024]u8 = undefined;
    const label = if (it) |i| textOf(i.label, &buf) else "";
    _ = c.siv_set_semantics(txn, st.root, &.{
        .role = .menu_item,
        .label = label.ptr,
        .label_len = label.len,
        .checked = if (checkable) (if (checked) .on else .off) else .unset,
        .flags = .{ .focusable = !disabled, .disabled = disabled },
    });
    if (st.mark != .null) _ = c.siv_invalidate(txn, st.mark);
}

fn drawRowMark(ud: ?*anyopaque, node: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    const it = itemOf(st.item) orelse return;
    if (!it.checked) return;
    w.drawCheck(draw, width, height, w.color(w.windowOf(node), .card_fg), false);
}

/// A popup's root as a raised card.
pub fn cardVisual(txn: Txn, root: Node) void {
    _ = c.siv_set_visual(txn, root, &.{
        .radius = w.corners(tk.radius),
        .border_width = tk.border,
        .border_token = .border,
        .background_token = .card_bg,
        .flags = .{ .clip = true },
    });
}

fn onRowPointer(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    if (ev.?.phase == .enter and !st.hdr.disabled) _ = c.siv_node_focus(st.root);
    return false;
}

fn onRowFocus(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    const txn = w.begin(e.window) orelse return false;
    applyRow(txn, st, e.flags.gained);
    _ = w.commit(txn);
    return false;
}

fn onRowActivate(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return true;
    choose(st.menu, st.item, st.index, ev.?.window);
    return true;
}

/// Closes the popup, flips a checkable item, and reports the choice.
fn choose(menu_node: Node, item_node: Node, index: u32, popup: siv.Window) void {
    // The row's state goes with the popup: everything needed is a copy.
    const m = w.stateOf(Menu, menu_node, &.{.menu}) orelse return;
    const owner = m.owner;
    close(m, popup);
    if (itemOf(item_node)) |it| if (it.checkable) {
        it.checked = !it.checked;
    };
    var handled = false;
    _ = c.siv_emit(owner, &.{ .type = .select, .index = index, .value = @floatFromInt(index), .count = 1 }, &handled);
}

fn close(m: *Menu, popup: siv.Window) void {
    _ = c.siv_window_destroy(popup);
    m.popup = .null;
    button.setExpanded(m.owner, false);
}

fn onRowKey(ud: ?*anyopaque, node: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.pressed) return false;
    const k = w.keysym;
    switch (e.keysym) {
        k.escape => {
            const m = w.stateOf(Menu, st.menu, &.{.menu}) orelse return true;
            close(m, e.window);
        },
        k.up, k.down => focusStep(node, if (e.keysym == k.down) .next else .previous, true),
        k.home => focusStep(w.related(node, .parent), .first_child, false),
        k.end => focusStep(w.related(node, .parent), .last_child, false),
        else => return chooseMnemonic(st, e.keysym, e.window),
    }
    return true;
}

/// A key that is an enabled item's mnemonic chooses it.
fn chooseMnemonic(st: *Row, sym: u32, popup: siv.Window) bool {
    const lower = struct {
        fn f(k: u32) u32 {
            return if (k >= 'A' and k <= 'Z') k + 32 else k;
        }
    }.f;
    var cur = w.related(st.root, .parent);
    cur = w.related(cur, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const r = w.stateOf(Row, cur, &.{.menu_row}) orelse continue;
        const it = itemOf(r.item) orelse continue;
        if (it.mnemonic == 0 or r.hdr.disabled or lower(it.mnemonic) != lower(sym)) continue;
        choose(r.menu, r.item, r.index, popup);
        return true;
    }
    return false;
}

/// Focuses the next enabled row from `from` in direction `rel`, wrapping.
fn focusStep(from: Node, rel: siv.Relation, wrap: bool) void {
    const step: siv.Relation = switch (rel) {
        .first_child, .next => .next,
        else => .previous,
    };
    var cur = w.related(from, rel);
    var wrapped = false;
    while (true) {
        if (cur == .null) {
            if (!wrap or wrapped) return;
            wrapped = true;
            cur = w.related(w.related(from, .parent), if (step == .next) .first_child else .last_child);
            continue;
        }
        if (cur == from) return;
        if (w.stateOf(Row, cur, &.{.menu_row})) |r| if (!r.hdr.disabled) {
            _ = c.siv_node_focus(cur);
            return;
        };
        cur = w.related(cur, step);
    }
}

/// Dismissed by the compositor (a click outside): the popup goes.
fn onMenuPopupEvent(ud: ?*anyopaque, _: siv.Window, ev: ?*const siv.WindowEvent) callconv(.c) bool {
    if (ev.?.type != .close_requested) return false;
    if (w.stateOf(Menu, w.dataHandle(ud), &.{.menu})) |m| {
        m.popup = .null;
        button.setExpanded(m.owner, false);
    }
    return false;
}

// Popovers ---------------------------------------------------------------------

pub export fn siv_popover_create(anchor: Node, desc: ?*const siv.PopoverDesc, popup_out: ?*siv.Window, content_out: ?*Node) siv.Result {
    const d = w.readDesc(siv.PopoverDesc, desc) orelse return .error_invalid_argument;
    const label = w.str(d.label, d.label_len) orelse return .error_invalid_argument;
    if (popup_out == null or content_out == null) return .error_invalid_argument;
    const parent_window = w.windowOf(anchor);
    if (parent_window == .null) return .error_invalid_handle;
    var popup: siv.Window = .null;
    var r = c.siv_popup_create(parent_window, &.{ .anchor = anchor, .placement = d.placement, .flags = d.flags, .on_event = onPopoverEvent }, &popup);
    if (r != .ok) return r;
    var txn: Txn = .null;
    r = c.siv_txn_begin(popup, &txn);
    if (r != .ok) {
        _ = c.siv_window_destroy(popup);
        return r;
    }
    const root = c.siv_window_root(popup);
    cardVisual(txn, root);
    const content = c.siv_flex(txn, root, &.{ .axis = .column, .gap = tk.gap });
    _ = c.siv_set_layout(txn, content, &.{ .padding = .{ .start = 12, .end = 12, .top = 12, .bottom = 12 } });
    _ = c.siv_set_semantics(txn, content, &.{ .role = .dialog, .label = label.ptr, .label_len = label.len });
    if (w.create(Popover, txn, root)) |st| {
        st.* = .{ .hdr = .{ .kind = .popover }, .root = root, .content = content, .popup = popup };
        w.onDefault(txn, root, .key, onPopoverKey, st);
        w.onDefault(txn, content, .close, onPopoverClose, st);
    }
    r = c.siv_txn_commit(txn);
    if (r != .ok) {
        _ = c.siv_window_destroy(popup);
        return r;
    }
    popup_out.?.* = popup;
    content_out.?.* = content;
    return .ok;
}

fn popoverOf(popup: siv.Window) ?*Popover {
    return w.stateOf(Popover, c.siv_window_root(popup), &.{.popover});
}

fn askClose(st: *Popover) bool {
    var handled = false;
    _ = c.siv_emit(st.content, &.{ .type = .close }, &handled);
    return handled;
}

fn onPopoverKey(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Popover = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.pressed or e.keysym != w.keysym.escape) return false;
    _ = askClose(st);
    return true;
}

fn onPopoverClose(ud: ?*anyopaque, _: Node, _: ?*const siv.Event) callconv(.c) bool {
    const st: *Popover = @ptrCast(@alignCast(ud.?));
    _ = c.siv_window_destroy(st.popup);
    return true;
}

/// Dismissed by the compositor: kept only if the application's close
/// handler says so.
fn onPopoverEvent(_: ?*anyopaque, popup: siv.Window, ev: ?*const siv.WindowEvent) callconv(.c) bool {
    if (ev.?.type != .close_requested) return false;
    const st = popoverOf(popup) orelse return false;
    return askClose(st);
}
