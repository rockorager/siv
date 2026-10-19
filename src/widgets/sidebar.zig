//! Sidebars (D22): the destinations of an application (places, mail
//! folders, settings panels) in titled sections, on the sidebar color,
//! with a separator at the end edge and boxes above and below the items
//! for a header bar or a footer.
//!
//! The sidebar is a navigation landmark named by its label; each section
//! is a list named by its title, each item a list item, and the current
//! item has current=page (aria-current), as WAI-ARIA's navigation
//! pattern marks the page shown. Focus roves: only the current item (or
//! the first enabled one) is in the Tab order, Up, Down, Home, and End
//! move between enabled, shown items across sections, and moving chooses
//! (automatic activation, as tabs do). A click chooses and focuses the
//! item. Choosing reports `change` with the item's index among all items.
//!
//! Collapsing is siv_set_hidden: the sidebar sets no motion of its own,
//! since D38's enter and exit would also run whenever an ancestor
//! appears or disappears (a navigation page holding it); content beside
//! it with `layout` motion slides into the space it leaves.
//!
//! While it is hidden (siv_set_hidden, an ancestor, or a variant, D39),
//! siv_sidebar_show_overlay shows it over the window's content: its
//! panel (everything but the separator) moves into a modal overlay at
//! the end of the window's root, a scrim with the panel sliding in from
//! the start edge, and moves back when the overlay closes. The
//! application's variants stay on the sidebar's root, which stays
//! hidden. Escape and a press on the scrim report `close` on the
//! sidebar, whose default handler closes the overlay; choosing an item
//! closes it too. In the overlay, arrows move focus without choosing,
//! since choosing closes it.

const std = @import("std");
const w = @import("widgets.zig");
const button = @import("button.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Sidebar = extern struct {
    hdr: w.Header,
    current: i32 = -1,
    root: Node,
    start: Node,
    sections: Node,
    end: Node,
    /// The separator at the end edge.
    rule: Node = .null,
    /// Everything else: the start and end boxes and the items, which
    /// move into the overlay.
    panel: Node = .null,
    /// The overlay while it shows (siv_sidebar_show_overlay), and the
    /// item focus is on in it, by index, or -1 for the current one.
    overlay: Node = .null,
    slot: Node = .null,
    roving: i32 = -1,
    /// Where items added to the sidebar itself go.
    first: Node = .null,
};

pub const Section = extern struct {
    hdr: w.Header,
    sidebar: Node,
    title: Node,
    list: Node,
};

pub const Item = extern struct {
    hdr: w.Header,
    sidebar: Node,
    root: Node,
    icon: Node = .null,
    icon_name: Node = .null,
    label: Node,
    end: Node,
};

pub export fn siv_sidebar(txn: Txn, parent: Node, desc: ?*const siv.SidebarDesc) Node {
    const d = w.readDesc(siv.SidebarDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = .row, .align_items = .stretch });
    if (root == .null) return .null;
    _ = c.siv_set_default_layout(txn, root, &.{ .width = w.px(tk.sidebar_width), .flags = .{ .no_shrink = true } });
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .sidebar_bg });
    const st = w.create(Sidebar, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .sidebar }, .root = root, .start = .null, .sections = .null, .end = .null };
    const panel = c.siv_flex(txn, root, &.{ .axis = .column, .align_items = .stretch });
    _ = c.siv_set_layout(txn, panel, &.{ .grow = 1, .basis = w.px(0) });
    st.panel = panel;
    st.start = c.siv_flex(txn, panel, &.{ .axis = .column, .align_items = .stretch });
    const scroll = c.siv_scroll(txn, panel, .vertical);
    _ = c.siv_set_layout(txn, scroll, &.{ .grow = 1, .basis = w.px(0) });
    st.sections = c.siv_flex(txn, scroll, &.{ .axis = .column, .align_items = .stretch, .gap = 2 });
    _ = c.siv_set_layout(txn, st.sections, &.{ .padding = .{ .start = tk.sidebar_pad, .end = tk.sidebar_pad, .top = tk.sidebar_pad, .bottom = tk.sidebar_pad } });
    st.end = c.siv_flex(txn, panel, &.{ .axis = .column, .align_items = .stretch });
    st.rule = c.siv_box(txn, root);
    _ = c.siv_set_layout(txn, st.rule, &.{ .width = w.px(tk.border) });
    _ = c.siv_set_visual(txn, st.rule, &.{ .background_token = .separator });
    setLabel(txn, st, label);
    w.setInterface(txn, root, Sidebar, st, .{ .set_label = setLabel, .set_value = setValue, .get_value = getValue, .get_part = part, .focus = focusItem, .apply = apply });
    w.onDefault(txn, root, .close, onClose, st);
    return root;
}

fn setLabel(txn: Txn, st: *Sidebar, label: []const u8) void {
    _ = c.siv_set_semantics(txn, st.root, &.{ .role = .navigation, .label = label.ptr, .label_len = label.len });
    if (st.overlay != .null) overlaySemantics(txn, st.overlay, label);
}

pub export fn siv_sidebar_section(txn: Txn, sidebar: Node, desc: ?*const siv.SidebarSectionDesc) Node {
    const sb = w.stateOf(Sidebar, sidebar, &.{.sidebar}) orelse return w.fail(txn, .error_invalid_argument);
    const d = w.readDesc(siv.SidebarSectionDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    const title = w.str(d.title, d.title_len) orelse return w.fail(txn, .error_invalid_argument);
    return addSection(txn, sb, title);
}

fn addSection(txn: Txn, sb: *Sidebar, title: []const u8) Node {
    const root = c.siv_flex(txn, sb.sections, &.{ .axis = .column, .align_items = .stretch, .gap = 2 });
    if (root == .null) return .null;
    const st = w.create(Section, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .sidebar_section }, .sidebar = sb.root, .title = .null, .list = .null };
    st.title = c.siv_text(txn, root, title.ptr, title.len);
    _ = c.siv_set_text_style(txn, st.title, &.{ .color_token = .muted_fg, .size_role = .caption, .weight = .bold, .flags = .{ .no_wrap = true, .ellipsize = true } });
    // The list carries the title as its name.
    _ = c.siv_set_semantics(txn, st.title, &.{ .role = .none });
    st.list = c.siv_flex(txn, root, &.{ .axis = .column, .align_items = .stretch, .gap = 2 });
    setTitle(txn, st, title);
    w.setInterface(txn, root, Section, st, .{ .set_label = setTitle });
    return root;
}

fn setTitle(txn: Txn, st: *Section, title: []const u8) void {
    _ = c.siv_set_text(txn, st.title, title.ptr, title.len);
    // A title stands its section apart by more than items are.
    _ = c.siv_set_layout(txn, st.title, &.{ .padding = .{ .start = tk.field_pad_x, .end = tk.field_pad_x, .top = tk.section_gap, .bottom = 4 } });
    _ = c.siv_set_visual(txn, st.title, &.{ .flags = .{ .hidden = title.len == 0 } });
    _ = c.siv_set_semantics(txn, st.list, &.{ .role = .list, .label = title.ptr, .label_len = title.len });
}

pub export fn siv_sidebar_item(txn: Txn, parent: Node, desc: ?*const siv.SidebarItemDesc) Node {
    const d = w.readDesc(siv.SidebarItemDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 1) != 0) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const icon = w.str(d.icon, d.icon_len) orelse return w.fail(txn, .error_invalid_argument);
    var section = w.stateOf(Section, parent, &.{.sidebar_section});
    if (section == null) {
        const sb = w.stateOf(Sidebar, parent, &.{.sidebar}) orelse return w.fail(txn, .error_invalid_argument);
        if (sb.first == .null) {
            sb.first = addSection(txn, sb, "");
            if (sb.first == .null) return .null;
            // First, before any section added already.
            const head = w.related(sb.sections, .first_child);
            if (head != sb.first) _ = c.siv_move(txn, sb.first, sb.sections, head);
        }
        section = w.stateOf(Section, sb.first, &.{.sidebar_section});
    }
    const sec = section.?;
    const root = c.siv_flex(txn, sec.list, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    if (root == .null) return .null;
    _ = c.siv_set_default_layout(txn, root, &.{ .min_height = tk.control_height, .padding = .{ .start = tk.field_pad_x, .end = tk.field_pad_x } });
    const st = w.create(Item, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .sidebar_item, .disabled = d.flags.disabled }, .sidebar = sec.sidebar, .root = root, .label = .null, .end = .null };
    st.label = c.siv_text(txn, root, label.ptr, label.len);
    _ = c.siv_set_layout(txn, st.label, &.{ .grow = 1, .basis = w.px(0) });
    st.end = c.siv_flex(txn, root, &.{ .axis = .row, .align_items = .center, .gap = 4 });
    if (icon.len != 0) setIconNodes(txn, st, icon);
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .activate, onActivate, st);
    w.onDefault(txn, root, .key, onKey, st);
    w.setInterface(txn, root, Item, st, .{ .set_label = setItemLabel, .set_icon = setIcon, .apply = applyItem, .get_part = itemPart });
    if (w.stateOf(Sidebar, sec.sidebar, &.{.sidebar})) |sb| apply(txn, sb);
    return root;
}

fn itemOf(node: Node) ?*Item {
    return w.stateOf(Item, node, &.{.sidebar_item});
}

fn itemPart(st: *const Item, p: siv.WidgetPart, _: u32) Node {
    return if (p == .end) st.end else .null;
}

fn setItemLabel(txn: Txn, st: *Item, label: []const u8) void {
    _ = c.siv_set_text(txn, st.label, label.ptr, label.len);
}

fn setIconNodes(txn: Txn, st: *Item, icon: []const u8) void {
    st.icon = c.siv_image_view(txn, st.root, &.{ .icon = icon.ptr, .icon_len = icon.len, .icon_size = tk.icon_size });
    _ = c.siv_move(txn, st.icon, st.root, st.label);
    st.icon_name = w.hiddenText(txn, st.root, icon);
}

fn setIcon(txn: Txn, st: *Item, icon: []const u8) void {
    if (st.icon == .null) {
        if (icon.len == 0) return;
        setIconNodes(txn, st, icon);
    } else _ = c.siv_set_text(txn, st.icon_name, icon.ptr, icon.len);
    _ = c.siv_set_visual(txn, st.icon, &.{ .flags = .{ .hidden = icon.len == 0 } });
    applyItem(txn, st);
}

/// Every item, in order, across sections: the visitor gets each with its
/// index and returns false to stop.
fn each(sb: *const Sidebar, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *Item, u32) bool) void {
    var i: u32 = 0;
    var sec = w.related(sb.sections, .first_child);
    while (sec != .null) : (sec = w.related(sec, .next)) {
        const s = w.stateOf(Section, sec, &.{.sidebar_section}) orelse continue;
        var cur = w.related(s.list, .first_child);
        while (cur != .null) : (cur = w.related(cur, .next)) {
            const it = itemOf(cur) orelse continue;
            if (!visit(ctx, it, i)) return;
            i += 1;
        }
    }
}

fn nth(sb: *const Sidebar, index: u32) ?*Item {
    const Ctx = struct { want: u32, found: ?*Item = null };
    var ctx: Ctx = .{ .want = index };
    each(sb, &ctx, struct {
        fn f(x: *Ctx, it: *Item, i: u32) bool {
            if (i != x.want) return true;
            x.found = it;
            return false;
        }
    }.f);
    return ctx.found;
}

fn indexOf(sb: *const Sidebar, item: *const Item) ?u32 {
    const Ctx = struct { want: *const Item, found: ?u32 = null };
    var ctx: Ctx = .{ .want = item };
    each(sb, &ctx, struct {
        fn f(x: *Ctx, it: *Item, i: u32) bool {
            if (it != x.want) return true;
            x.found = i;
            return false;
        }
    }.f);
    return ctx.found;
}

fn count(sb: *const Sidebar) u32 {
    var n: u32 = 0;
    each(sb, &n, struct {
        fn f(x: *u32, _: *Item, _: u32) bool {
            x.* += 1;
            return true;
        }
    }.f);
    return n;
}

/// Whether keys and choosing reach an item: enabled and shown.
fn reachable(sb: *const Sidebar, it: *const Item) bool {
    if (sb.hdr.disabled or it.hdr.disabled) return false;
    var hidden = false;
    _ = c.siv_node_is_hidden(it.root, &hidden);
    return !hidden;
}

/// The item in the Tab order: in the overlay the one focus moved to,
/// else the current one, else the first reachable.
fn stop(sb: *const Sidebar) ?*Item {
    if (sb.roving >= 0) if (nth(sb, @intCast(sb.roving))) |it| if (reachable(sb, it)) return it;
    if (sb.current >= 0) if (nth(sb, @intCast(sb.current))) |it| if (reachable(sb, it)) return it;
    const Ctx = struct { sb: *const Sidebar, found: ?*Item = null };
    var ctx: Ctx = .{ .sb = sb };
    each(sb, &ctx, struct {
        fn f(x: *Ctx, it: *Item, _: u32) bool {
            if (!reachable(x.sb, it)) return true;
            x.found = it;
            return false;
        }
    }.f);
    return ctx.found;
}

fn focusItem(sb: *Sidebar) Node {
    const it = stop(sb) orelse return .null;
    return it.root;
}

fn getValue(sb: *const Sidebar) f64 {
    return @floatFromInt(sb.current);
}

fn setValue(txn: Txn, sb: *Sidebar, v: f64) void {
    const i: i64 = @intFromFloat(@round(v));
    sb.current = if (i >= 0 and i < count(sb)) @intCast(i) else -1;
    apply(txn, sb);
}

fn part(sb: *const Sidebar, p: siv.WidgetPart, index: u32) Node {
    return switch (p) {
        .start => sb.start,
        .end => sb.end,
        .divider => sb.rule,
        .item => if (nth(sb, index)) |it| it.root else .null,
        else => .null,
    };
}

/// Shows every item's state.
pub fn apply(txn: Txn, sb: *Sidebar) void {
    const tab = stop(sb);
    const Ctx = struct { txn: Txn, sb: *Sidebar, tab: ?*Item };
    var ctx: Ctx = .{ .txn = txn, .sb = sb, .tab = tab };
    each(sb, &ctx, struct {
        fn f(x: *Ctx, it: *Item, i: u32) bool {
            show(x.txn, x.sb, it, i == x.sb.current, x.tab == it);
            return true;
        }
    }.f);
}

fn applyItem(txn: Txn, it: *Item) void {
    const sb = w.stateOf(Sidebar, it.sidebar, &.{.sidebar}) orelse return;
    apply(txn, sb);
}

fn show(txn: Txn, sb: *const Sidebar, it: *Item, current: bool, tab: bool) void {
    const disabled = sb.hdr.disabled or it.hdr.disabled;
    const fg: siv.ColorToken = if (disabled) .disabled_fg else if (current) .selection_fg else .view_fg;
    const bg: siv.ColorToken = if (current) .selection_bg else if (it.hdr.pressed and !disabled) .control_active else if (it.hdr.hover and !disabled) .control_hover else .none;
    _ = c.siv_set_visual(txn, it.root, &.{ .radius = w.corners(tk.radius), .background_token = bg });
    _ = c.siv_set_text_style(txn, it.label, &.{ .color_token = fg, .size_role = .body, .flags = .{ .no_wrap = true, .ellipsize = true } });
    if (it.icon != .null) w.setIcon(txn, it.icon, it.icon_name, tk.icon_size, fg);
    _ = c.siv_set_semantics(txn, it.root, &.{
        .role = .list_item,
        .current = if (current) .page else .none,
        .flags = .{ .focusable = tab and !disabled, .disabled = disabled },
    });
}

/// Makes an item current, from the user: reports `change` after its
/// transaction.
fn choose(sb: *Sidebar, it: *Item, window: siv.Window, focus: bool) void {
    const index = indexOf(sb, it) orelse return;
    const txn = w.begin(window) orelse return;
    const changed = sb.current != @as(i32, @intCast(index));
    sb.current = @intCast(index);
    // Choosing in the overlay closes it; focus goes back to where it
    // was before the overlay.
    const overlaid = sb.overlay != .null;
    if (overlaid) closeOverlay(txn, sb);
    apply(txn, sb);
    if (!w.commit(txn)) return;
    if (focus and !overlaid) _ = c.siv_node_focus(it.root);
    if (changed) w.emitChange(sb.root, @floatFromInt(index), index);
}

fn onPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const it: *Item = @ptrCast(@alignCast(ud.?));
    const sb = w.stateOf(Sidebar, it.sidebar, &.{.sidebar}) orelse return .pass;
    if (sb.hdr.disabled) return .pass;
    if (button.feedback(&it.hdr, ev)) {
        const txn = w.begin(ev.window) orelse return .pass;
        apply(txn, sb);
        _ = w.commit(txn);
    }
    return .pass;
}

fn onActivate(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const it: *Item = @ptrCast(@alignCast(ud.?));
    const sb = w.stateOf(Sidebar, it.sidebar, &.{.sidebar}) orelse return .pass;
    if (!reachable(sb, it)) return .pass;
    // A clicked item takes the focus too, which a press could not give
    // it while it was not the Tab stop, so keys go on from there.
    choose(sb, it, ev.window, true);
    return .handled;
}

/// Up and Down move to the previous and next reachable item, Home and
/// End to the first and last, choosing it.
fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const it: *Item = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.pressed or ev.target != it.root) return .pass;
    const m = ev.modifiers;
    if (m.ctrl or m.alt or m.super or m.shift) return .pass;
    const sb = w.stateOf(Sidebar, it.sidebar, &.{.sidebar}) orelse return .pass;
    const k = w.keysym;
    const n = count(sb);
    const at = indexOf(sb, it) orelse return .pass;
    const Dir = enum { back, forward };
    const start: i64, const dir: Dir = switch (ev.keysym) {
        k.up => .{ @as(i64, at) - 1, .back },
        k.down => .{ @as(i64, at) + 1, .forward },
        k.home => .{ 0, .forward },
        k.end => .{ @as(i64, n) - 1, .back },
        else => return .pass,
    };
    var i = start;
    while (i >= 0 and i < n) : (i = if (dir == .forward) i + 1 else i - 1) {
        const target = nth(sb, @intCast(i)) orelse break;
        if (!reachable(sb, target)) continue;
        if (sb.overlay != .null) rove(sb, i, target, ev.window) else choose(sb, target, ev.window, true);
        break;
    }
    return .handled;
}

/// In the overlay, moves focus to an item without choosing it: it is the
/// Tab stop until the overlay closes.
fn rove(sb: *Sidebar, index: i64, it: *Item, window: siv.Window) void {
    const txn = w.begin(window) orelse return;
    sb.roving = @intCast(index);
    apply(txn, sb);
    if (!w.commit(txn)) return;
    _ = c.siv_node_focus(it.root);
}

// The overlay ---------------------------------------------------------------

/// Overlays carry their sidebar's handle in node data, not its state,
/// which goes with the sidebar if the application removes it first.
const Overlay = extern struct { sidebar: Node };
var overlay_key: u8 = 0;

pub export fn siv_sidebar_show_overlay(txn: Txn, sidebar: Node, on: bool) void {
    const sb = w.stateOf(Sidebar, sidebar, &.{.sidebar}) orelse {
        _ = w.fail(txn, .error_invalid_argument);
        return;
    };
    if (!on) {
        if (sb.overlay != .null) closeOverlay(txn, sb);
        apply(txn, sb);
        return;
    }
    if (sb.overlay != .null) return;
    // A sidebar that shows needs no overlay.
    var shown = false;
    if (c.siv_node_is_shown(sb.root, &shown) != .ok or shown) return;
    const window = w.windowOf(sb.root);
    const wroot = c.siv_window_get_root(window);
    const host = c.siv_stack(txn, wroot, &.{ .align_x = .start, .align_y = .stretch });
    if (host == .null) return;
    var p: ?*anyopaque = null;
    if (c.siv_set_data(txn, host, &overlay_key, @sizeOf(Overlay), &p) != .ok) return;
    const ov: *Overlay = @ptrCast(@alignCast(p.?));
    ov.* = .{ .sidebar = sb.root };
    _ = c.siv_set_visual(txn, host, &.{ .background_token = .scrim });
    _ = c.siv_set_motion(txn, host, &.{ .flags = .{ .enter = true, .exit = true }, .duration_ms = tk.spring_ms });
    var buf: [1024]u8 = undefined;
    overlaySemantics(txn, host, w.labelOf(sb.root, &buf));
    // The panel slides in from the start edge over a scrim that fades,
    // as wide as the sidebar's default and leaving some scrim to press.
    var r: siv.Rect = .{};
    _ = c.siv_node_get_rect(wroot, &r);
    const width = if (r.width > 0) @min(tk.sidebar_width, r.width * 0.85) else tk.sidebar_width;
    const slot = c.siv_flex(txn, host, &.{ .axis = .row, .align_items = .stretch });
    _ = c.siv_set_layout(txn, slot, &.{ .width = w.px(width) });
    const shadow: siv.Shadow = .{ .blur = 16, .color_token = .shadow };
    _ = c.siv_set_visual(txn, slot, &.{ .background_token = .sidebar_bg, .shadows = @ptrCast(&shadow), .shadows_count = 1 });
    _ = c.siv_set_motion(txn, slot, &.{
        .flags = .{ .enter = true, .relative = true, .mirror_rtl = true },
        .duration_ms = tk.spring_ms,
        .enter_opacity = 1,
        .enter_x = -1,
    });
    _ = c.siv_move(txn, sb.panel, slot, .null);
    w.onDefault(txn, host, .key, onOverlayKey, ov);
    w.onDefault(txn, host, .pointer, onOverlayPointer, ov);
    sb.overlay = host;
    sb.slot = slot;
    sb.roving = -1;
    // A modal node that appears takes the focus, on its first focusable
    // node: the Tab stop.
    apply(txn, sb);
}

fn overlaySemantics(txn: Txn, host: Node, label: []const u8) void {
    _ = c.siv_set_semantics(txn, host, &.{ .role = .navigation, .label = label.ptr, .label_len = label.len, .flags = .{ .modal = true } });
}

/// Moves the panel back and removes the overlay; the modal node going
/// returns focus to what had it before.
fn closeOverlay(txn: Txn, sb: *Sidebar) void {
    _ = c.siv_move(txn, sb.panel, sb.root, sb.rule);
    _ = c.siv_remove(txn, sb.overlay);
    sb.overlay = .null;
    sb.slot = .null;
    sb.roving = -1;
}

fn onClose(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const sb: *Sidebar = @ptrCast(@alignCast(ud.?));
    if (sb.overlay == .null) return .pass;
    const txn = w.begin(ev.window) orelse return .pass;
    closeOverlay(txn, sb);
    apply(txn, sb);
    _ = w.commit(txn);
    return .handled;
}

/// Asks the sidebar to close its overlay; an overlay whose sidebar is
/// gone removes itself.
fn askClose(ov: *const Overlay, host: Node, window: siv.Window) void {
    if (w.stateOf(Sidebar, ov.sidebar, &.{.sidebar}) == null) {
        const txn = w.begin(window) orelse return;
        _ = c.siv_remove(txn, host);
        _ = w.commit(txn);
        return;
    }
    var handled = false;
    _ = c.siv_node_emit(ov.sidebar, &.{ .type = .close }, &handled);
}

fn onOverlayKey(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const ov: *Overlay = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.pressed or ev.keysym != w.keysym.escape) return .pass;
    askClose(ov, node, ev.window);
    return .handled;
}

/// A press on the scrim, outside the panel, asks to close.
fn onOverlayPointer(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const ov: *Overlay = @ptrCast(@alignCast(ud.?));
    if (ev.phase != .down or ev.target != node) return .pass;
    askClose(ov, node, ev.window);
    return .handled;
}
