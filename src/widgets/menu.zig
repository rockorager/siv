//! Menus and popovers, shown in popups (xdg_popup, D17) made with the
//! public siv_popup_create.
//!
//! A menu is a model in the tree: a node that takes no space, with one
//! hidden child per item holding its label, shortcut, and icon name as
//! text, so the
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
    /// The popup took the keyboard (it was opened by a press or key, not
    /// by hovering over its item).
    grabbed: bool = false,
    /// Open as a submenu: the menu it came from and the row there.
    parent: Node = .null,
    parent_row: Node = .null,
    /// The submenu open from this menu, if any.
    child: Node = .null,
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
    submenu: Node = .null,
    /// The themed icon's name (D19), empty for none.
    icon: Node = .null,
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
    submenu: Node = .null,
    arrow: Node = .null,
    focused: bool = false,
    /// The icon's image node, when some item of the menu has one.
    icon: Node = .null,
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
    w.setInterface(txn, root, Menu, st, .{ .set_label = setMenuLabel });
    return root;
}

fn setMenuLabel(txn: Txn, st: *Menu, label: []const u8) void {
    _ = c.siv_set_semantics(txn, st.root, &.{ .role = .menu, .label = label.ptr, .label_len = label.len });
}

/// A menu, or the menu part of a widget that has one (a menu button, or
/// an application's widget, through its interface).
fn menuOf(node: Node) ?*Menu {
    if (w.stateOf(Menu, node, &.{.menu})) |m| return m;
    var part: Node = .null;
    if (c.siv_widget_get_part(node, .menu, 0, &part) != .ok) return null;
    return w.stateOf(Menu, part, &.{.menu});
}

pub export fn siv_menu_item(txn: Txn, menu_node: Node, desc: ?*const siv.MenuItemDesc) Node {
    const m = menuOf(menu_node) orelse return w.fail(txn, .error_invalid_argument);
    const d = w.readDesc(siv.MenuItemDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 15) != 0) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const shortcut = w.str(d.shortcut, d.shortcut_len) orelse return w.fail(txn, .error_invalid_argument);
    const icon = w.str(d.icon, d.icon_len) orelse return w.fail(txn, .error_invalid_argument);
    if (d.submenu != .null) {
        const sub = w.stateOf(Menu, d.submenu, &.{.menu}) orelse return w.fail(txn, .error_invalid_argument);
        if (sub.root == m.root) return w.fail(txn, .error_invalid_argument);
    }
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
        .submenu = d.submenu,
        .icon = c.siv_text(txn, root, icon.ptr, icon.len),
    };
    _ = c.siv_set_semantics(txn, root, &.{ .role = if (st.separator) .separator else .menu_item });
    w.setInterface(txn, root, Item, st, .{ .set_label = setItemLabel, .set_icon = setItemIcon, .set_value = setItemValue, .get_value = itemValue, .apply = applyItem });
    return root;
}

/// Items show their state when their menu opens.
fn applyItem(_: Txn, _: *Item) void {}

pub fn setItemLabel(txn: Txn, st: *Item, label: []const u8) void {
    _ = c.siv_set_text(txn, st.label, label.ptr, label.len);
}

pub fn setItemIcon(txn: Txn, st: *Item, icon: []const u8) void {
    _ = c.siv_set_text(txn, st.icon, icon.ptr, icon.len);
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

pub export fn siv_menu_get_item(menu_node: Node, index: u32, item: ?*Node) siv.Result {
    const out = item orelse return .error_invalid_argument;
    const m = menuOf(menu_node) orelse return .error_invalid_argument;
    var i: u32 = 0;
    var cur = w.related(m.root, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        if (itemOf(cur) == null) continue;
        if (i == index) {
            out.* = cur;
            return .ok;
        }
        i += 1;
    }
    return .error_invalid_argument;
}

fn textOf(node: Node, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_node_get_text(node, buf.ptr, buf.len, &len) != .ok) return "";
    return buf[0..@min(len, buf.len)];
}

pub export fn siv_menu_open(menu_node: Node, anchor: Node) siv.Result {
    const m = menuOf(menu_node) orelse return .error_invalid_argument;
    const at = if (anchor != .null) anchor else w.related(m.owner, .parent);
    return openMenu(m, at, null, true, true, null);
}

/// A context menu: at a point of `anchor` instead of below it.
pub export fn siv_menu_open_at(menu_node: Node, anchor: Node, x: f32, y: f32) siv.Result {
    const m = menuOf(menu_node) orelse return .error_invalid_argument;
    if (anchor == .null or !std.math.isFinite(x) or !std.math.isFinite(y)) return .error_invalid_argument;
    return openMenu(m, anchor, null, true, true, .{ .x = x, .y = y });
}

/// Shows `m` in a popup against `at`: below it, or beside it for a
/// submenu of `parent`. With `grab` the popup takes the keyboard (it
/// answers a press or key); `focus` focuses its first enabled item.
fn openMenu(m: *Menu, at: Node, parent: ?*Menu, grab: bool, focus: bool, point: ?siv.Rect) siv.Result {
    if (w.windowAlive(m.popup)) {
        if (!grab or m.grabbed) {
            if (focus) focusFirst(m);
            return .ok;
        }
        // Opened by hovering, now asked for by a key or press: again, with
        // the keyboard.
        closeMenu(m);
    }
    const parent_window = w.windowOf(at);
    if (parent_window == .null) return .error_invalid_argument;
    var popup: siv.Window = .null;
    var r = c.siv_popup_create(parent_window, &.{
        .anchor = at,
        .placement = if (parent != null) .beside else .below,
        .flags = .{ .no_grab = !grab, .at_rect = point != null },
        .anchor_rect = point orelse .{},
        .user_data = w.handleData(m.root),
        .on_event = onMenuPopupEvent,
    }, &popup);
    if (r != .ok) return r;
    var checkable = false;
    var icons = false;
    var cur = w.related(m.root, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        const it = itemOf(cur) orelse continue;
        checkable = checkable or it.checkable;
        var len: usize = 0;
        icons = icons or (!it.separator and c.siv_node_get_text(it.icon, null, 0, &len) == .ok and len != 0);
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
        _ = buildRow(txn, col, m, it, index, checkable, icons, &buf);
    }
    r = c.siv_txn_commit(txn);
    if (r == .ok) r = c.siv_popup_show(popup);
    if (r != .ok) {
        _ = c.siv_window_destroy(popup);
        return r;
    }
    m.popup = popup;
    m.grabbed = grab;
    m.parent = if (parent) |p| p.root else .null;
    m.parent_row = if (parent != null) at else .null;
    if (parent) |p| p.child = m.root;
    if (focus) focusFirst(m);
    if (parent == null) button.setExpanded(m.owner, true);
    return .ok;
}

fn focusFirst(m: *Menu) void {
    if (!w.windowAlive(m.popup)) return;
    const col = w.related(c.siv_window_root(m.popup), .first_child);
    focusStep(col, .first_child, false);
}

/// Closes a menu's popup, and with it the submenus open from it.
fn closeMenu(m: *Menu) void {
    var child = m.child;
    while (child != .null) {
        const cm = w.stateOf(Menu, child, &.{.menu}) orelse break;
        cm.popup = .null;
        cm.parent = .null;
        child = cm.child;
        cm.child = .null;
    }
    m.child = .null;
    if (w.windowAlive(m.popup)) _ = c.siv_window_destroy(m.popup);
    m.popup = .null;
    if (m.parent != .null) {
        if (w.stateOf(Menu, m.parent, &.{.menu})) |p| {
            if (p.child == m.root) p.child = .null;
            refreshRow(m.parent_row);
        }
        m.parent = .null;
    } else button.setExpanded(m.owner, false);
}

/// The menu at the top of a chain of submenus.
fn rootOf(m: *Menu) *Menu {
    var cur = m;
    while (cur.parent != .null) cur = w.stateOf(Menu, cur.parent, &.{.menu}) orelse break;
    return cur;
}

/// Opens a row's submenu beside it.
fn openSubmenu(st: *Row, grab: bool, focus: bool) void {
    const m = w.stateOf(Menu, st.menu, &.{.menu}) orelse return;
    const sub = w.stateOf(Menu, st.submenu, &.{.menu}) orelse return;
    if (m.child != .null and m.child != sub.root) {
        if (w.stateOf(Menu, m.child, &.{.menu})) |old| closeMenu(old);
    }
    _ = openMenu(sub, st.root, m, grab, focus, null);
    refreshRow(st.root);
}

fn refreshRow(row: Node) void {
    const st = w.stateOf(Row, row, &.{.menu_row}) orelse return;
    const txn = w.begin(w.windowOf(row)) orelse return;
    applyRow(txn, st, st.focused);
    _ = w.commit(txn);
}

fn buildRow(txn: Txn, col: Node, m: *Menu, it: *Item, index: u32, checkable: bool, icons: bool, buf: []u8) Node {
    const row = c.siv_flex(txn, col, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    _ = c.siv_set_layout(txn, row, &.{ .min_height = 28, .padding = .{ .start = 10, .end = 10, .top = 2, .bottom = 2 } });
    const st = w.create(Row, txn, row) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .menu_row, .disabled = it.hdr.disabled }, .index = index, .item = it.root, .menu = m.root, .root = row, .label = .null, .shortcut = .null, .submenu = it.submenu };
    if (checkable) {
        st.mark = c.siv_canvas(txn, row, &.{ .user_data = st, .draw = drawRowMark, .width = 16, .height = 16 });
    }
    // Every row of a menu with icons has the slot, so labels line up.
    if (icons) {
        st.icon = c.siv_image_view(txn, row, &.{ .icon_size = tk.icon_size });
        _ = c.siv_set_layout(txn, st.icon, &.{ .width = w.px(tk.icon_size), .height = w.px(tk.icon_size) });
    }
    const label = textOf(it.label, buf);
    st.label = c.siv_text(txn, row, label.ptr, label.len);
    _ = c.siv_set_layout(txn, st.label, &.{ .grow = 1 });
    const shortcut = textOf(it.shortcut, buf);
    st.shortcut = c.siv_text(txn, row, shortcut.ptr, shortcut.len);
    _ = c.siv_set_visual(txn, st.shortcut, &.{ .flags = .{ .hidden = shortcut.len == 0 } });
    if (st.submenu != .null) {
        st.arrow = c.siv_canvas(txn, row, &.{ .user_data = st, .draw = drawArrow, .width = 12, .height = 16 });
    }
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
    if (st.icon != .null) if (it) |i| w.setIcon(txn, st.icon, i.icon, tk.icon_size, if (disabled) .disabled_fg else if (lit) .selection_fg else .card_fg);
    const checkable = if (it) |i| i.checkable else false;
    const checked = if (it) |i| i.checked else false;
    const open = if (w.stateOf(Menu, st.submenu, &.{.menu})) |sub| w.windowAlive(sub.popup) else false;
    // Named by the label alone: the shortcut is not part of the name.
    var buf: [1024]u8 = undefined;
    const label = if (it) |i| textOf(i.label, &buf) else "";
    _ = c.siv_set_semantics(txn, st.root, &.{
        .role = .menu_item,
        .label = label.ptr,
        .label_len = label.len,
        .checked = if (checkable) (if (checked) .on else .off) else .unset,
        // An item with a submenu is expanded while it is open.
        .expanded = if (st.submenu == .null) .unset else if (open) .on else .off,
        .flags = .{ .focusable = !disabled, .disabled = disabled },
    });
    if (st.mark != .null) _ = c.siv_invalidate(txn, st.mark);
}

/// A chevron toward the end edge: the item opens a submenu there.
fn drawArrow(_: ?*anyopaque, node: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const dir: f32 = if (w.isRtl(node)) -1 else 1;
    const cx = width / 2;
    const cy = height / 2;
    _ = c.siv_draw_move_to(draw, cx - dir * 2, cy - 4);
    _ = c.siv_draw_line_to(draw, cx + dir * 2, cy);
    _ = c.siv_draw_line_to(draw, cx - dir * 2, cy + 4);
    _ = c.siv_draw_stroke(draw, &.{ .width = 1.5, .join = .round, .cap = .round }, &.{ .color = w.color(w.windowOf(node), .muted_fg) });
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

/// Hovering focuses the row, opens its submenu (without the keyboard),
/// and closes a sibling's.
fn onRowPointer(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    if (ev.?.phase != .enter or st.hdr.disabled) return .pass;
    _ = c.siv_node_focus(st.root);
    if (st.submenu != .null) {
        openSubmenu(st, false, false);
    } else if (w.stateOf(Menu, st.menu, &.{.menu})) |m| if (m.child != .null) {
        if (w.stateOf(Menu, m.child, &.{.menu})) |child| closeMenu(child);
    };
    return .pass;
}

fn onRowFocus(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    st.focused = e.flags.gained;
    const txn = w.begin(e.window) orelse return .pass;
    applyRow(txn, st, e.flags.gained);
    _ = w.commit(txn);
    return .pass;
}

fn onRowActivate(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .handled;
    if (st.submenu != .null) {
        openSubmenu(st, true, true);
        return .handled;
    }
    choose(st.menu, st.item, st.index, ev.?.window);
    return .handled;
}

/// Closes the menu and the menus it opened from, flips a checkable item,
/// and reports the choice to the menu the item is in.
fn choose(menu_node: Node, item_node: Node, index: u32, _: siv.Window) void {
    // The row's state goes with the popup: everything needed is a copy.
    const m = w.stateOf(Menu, menu_node, &.{.menu}) orelse return;
    const owner = m.owner;
    closeMenu(rootOf(m));
    if (itemOf(item_node)) |it| if (it.checkable) {
        it.checked = !it.checked;
    };
    var handled = false;
    _ = c.siv_emit(owner, &.{ .type = .select, .index = index, .value = @floatFromInt(index), .count = 1 }, &handled);
}

fn onRowKey(ud: ?*anyopaque, node: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Row = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.pressed) return .pass;
    const k = w.keysym;
    const forward = if (w.isRtl(node)) k.left else k.right;
    switch (e.keysym) {
        // Escape and back close a submenu, focus going back to its item;
        // Escape closes a top menu.
        k.escape, k.left, k.right => {
            const m = w.stateOf(Menu, st.menu, &.{.menu}) orelse return .handled;
            if (e.keysym == forward) {
                if (st.submenu == .null or st.hdr.disabled) return .pass;
                openSubmenu(st, true, true);
            } else if (m.parent != .null) {
                const row = m.parent_row;
                closeMenu(m);
                _ = c.siv_node_focus(row);
            } else if (e.keysym == k.escape) {
                closeMenu(m);
            } else return .pass;
        },
        k.up, k.down => focusStep(node, if (e.keysym == k.down) .next else .previous, true),
        k.home => focusStep(w.related(node, .parent), .first_child, false),
        k.end => focusStep(w.related(node, .parent), .last_child, false),
        else => return w.resultOf(chooseMnemonic(st, @bitCast(@intFromEnum(e.keysym)), e.window)),
    }
    return .handled;
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
        if (r.submenu != .null) {
            openSubmenu(r, true, true);
            return true;
        }
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
        // The compositor destroys the popup's children with it.
        m.popup = .null;
        closeMenu(m);
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
        w.setInterface(txn, root, Popover, st, .{ .set_label = setPopoverLabel, .get_part = popoverPart });
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

fn setPopoverLabel(txn: Txn, st: *Popover, label: []const u8) void {
    _ = c.siv_set_semantics(txn, st.content, &.{ .role = .dialog, .label = label.ptr, .label_len = label.len });
}

fn popoverPart(st: *const Popover, part: siv.WidgetPart, _: u32) Node {
    return if (part == .content) st.content else .null;
}

fn popoverOf(popup: siv.Window) ?*Popover {
    return w.stateOf(Popover, c.siv_window_root(popup), &.{.popover});
}

fn askClose(st: *Popover) bool {
    var handled = false;
    _ = c.siv_emit(st.content, &.{ .type = .close }, &handled);
    return handled;
}

fn onPopoverKey(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Popover = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.pressed or e.keysym != w.keysym.escape) return .pass;
    _ = askClose(st);
    return .handled;
}

fn onPopoverClose(ud: ?*anyopaque, _: Node, _: ?*const siv.Event) callconv(.c) siv.EventResult {
    const st: *Popover = @ptrCast(@alignCast(ud.?));
    _ = c.siv_window_destroy(st.popup);
    return .handled;
}

/// Dismissed by the compositor: kept only if the application's close
/// handler says so.
fn onPopoverEvent(_: ?*anyopaque, popup: siv.Window, ev: ?*const siv.WindowEvent) callconv(.c) bool {
    if (ev.?.type != .close_requested) return false;
    const st = popoverOf(popup) orelse return false;
    return askClose(st);
}
