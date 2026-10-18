//! Navigation stacks (D40): pages pushed on top of each other, of which
//! only the last shows. A push slides the new page in from the end edge
//! over the page below, which moves a little toward the start edge and
//! is hidden (so it keeps its state); going back slides the last page out
//! toward the end edge and removes it, and the page below comes back. The
//! motion is D38's, set on both pages just before each change, so reduced
//! motion makes it jump; the stack clips, so pages never slide over what
//! is beside it.
//!
//! Going back is the last page's `close`: a header bar's back button,
//! Alt+Left (Alt+Right in RTL), XF86Back, Escape, and the mouse's back
//! button (the keys while focus is in the stack, the button while the
//! pointer is) report it on the page, and its default handler removes the
//! page and reports `change` on the stack. An application's handler that
//! returns handled keeps the page (unsaved changes). The stack's value is
//! its number of pages; setting fewer removes the pages above at once.

const std = @import("std");
const w = @import("widgets.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Stack = extern struct {
    hdr: w.Header,
    root: Node,
    count: u32 = 0,
    no_escape: bool = false,
};

pub const Page = extern struct {
    hdr: w.Header,
    stack: Node,
    root: Node,
    /// Its position in the stack, from 0; pages leave only from the top,
    /// so it never changes.
    index: u32,
    /// What had focus in it when a page was pushed over it, for going
    /// back.
    focus: Node = .null,
    /// A header bar inside it that shows its title.
    bar: Node = .null,
};

pub export fn siv_navigation_stack(txn: Txn, parent: Node, desc: ?*const siv.NavigationStackDesc) Node {
    const d = w.readDesc(siv.NavigationStackDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 1) != 0) return w.fail(txn, .error_unsupported);
    const root = c.siv_stack(txn, parent, &.{ .align_x = .stretch, .align_y = .stretch });
    if (root == .null) return .null;
    _ = c.siv_set_default_layout(txn, root, &.{ .grow = 1, .align_x = .stretch, .align_y = .stretch });
    _ = c.siv_set_visual(txn, root, &.{ .flags = .{ .clip = true } });
    const st = w.create(Stack, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .navigation_stack }, .root = root, .no_escape = d.flags.no_escape };
    w.onDefault(txn, root, .key, onKey, st);
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.setInterface(txn, root, Stack, st, .{ .set_value = setValue, .get_value = getValue, .get_part = getPart, .focus = focusTop });
    return root;
}

pub export fn siv_navigation_page(txn: Txn, stack: Node, desc: ?*const siv.NavigationPageDesc) Node {
    const st = w.stateOf(Stack, stack, &.{.navigation_stack}) orelse return w.fail(txn, .error_invalid_argument);
    const d = w.readDesc(siv.NavigationPageDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    const title = w.str(d.title, d.title_len) orelse return w.fail(txn, .error_invalid_argument);
    const below = top(st);
    const focus = c.siv_window_get_focus(w.windowOf(stack));
    const focus_here = focus == .null or within(focus, st.root);
    const level = levelFor(txn, st, st.count);
    if (level == .null) return .null;
    const root = c.siv_flex(txn, level, &.{ .axis = .column, .align_items = .stretch });
    if (root == .null) return .null;
    const pg = w.create(Page, txn, root) orelse return .null;
    pg.* = .{ .hdr = .{ .kind = .navigation_page }, .stack = stack, .root = root, .index = st.count };
    st.count += 1;
    // Opaque, so that the page below does not show through while this
    // one slides over it, with a soft shadow on its leading edge that the
    // stack clips away once it is in place.
    const shadow: siv.Shadow = .{ .blur = 16, .color_token = .shadow };
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg, .flags = .{ .no_focus_ring = true }, .shadows = @ptrCast(&shadow), .shadows_count = 1 });
    applySemantics(txn, pg, title);
    w.onDefault(txn, root, .close, onClose, pg);
    w.setInterface(txn, root, Page, pg, .{ .set_label = setTitle, .focus = focusPage });
    // Every page has its motion, and so its layer, from the start: a
    // page covered in the frame that first gave it motion would have no
    // layer showing to slide away.
    slide(txn, root, below != null, below != null);
    if (below) |b| {
        if (focus_here and focus != .null and within(focus, b.root)) b.focus = focus;
        slide(txn, b.root, false, true);
        _ = c.siv_set_hidden(txn, b.root, true);
        if (focus_here) _ = c.siv_node_focus(root);
    }
    return root;
}

/// Whether `node` is `ancestor` or inside it.
fn within(node: Node, ancestor: Node) bool {
    var n = node;
    while (n != .null) : (n = w.related(n, .parent)) if (n == ancestor) return true;
    return false;
}

fn pageOf(node: Node) ?*Page {
    return w.stateOf(Page, node, &.{.navigation_page});
}

/// Each depth has a level: a stack of its own, with a layer, that holds
/// the page at that depth. A page going back exits inside its level,
/// which stays, so it slides out above the page it uncovers: D38 keeps
/// an exiting layer below every live sibling, and the uncovered page
/// would otherwise be drawn over the page leaving it. Levels pass the
/// pointer through, and are reused by later pages at their depth.
fn levelFor(txn: Txn, st: *Stack, depth: u32) Node {
    var i: u32 = 0;
    var cur = w.related(st.root, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        if (i == depth) return cur;
        i += 1;
    }
    var level: Node = .null;
    while (i <= depth) : (i += 1) {
        level = c.siv_stack(txn, st.root, &.{ .align_x = .stretch, .align_y = .stretch });
        _ = c.siv_set_visual(txn, level, &.{ .flags = .{ .layer = true, .no_hit_test = true } });
    }
    return level;
}

/// The page that shows, if any.
fn top(st: *const Stack) ?*Page {
    if (st.count == 0) return null;
    return nth(st, st.count - 1);
}

fn nth(st: *const Stack, index: u32) ?*Page {
    if (index >= st.count) return null;
    var i: u32 = 0;
    var cur = w.related(st.root, .first_child);
    while (cur != .null) : (cur = w.related(cur, .next)) {
        if (i == index) return pageOf(w.related(cur, .last_child));
        i += 1;
    }
    return null;
}

/// The motion of a page that is pushed or popped (`moving`), sliding a
/// whole width from or to the end edge, or of the page below it, moving
/// a little toward the start edge as it is covered or uncovered.
/// The first page gets no enter: it shows at once, also when the stack
/// is built after the window's first frame.
fn slide(txn: Txn, page: Node, moving: bool, enter: bool) void {
    const x: f32 = if (moving) 1 else -tk.parallax;
    _ = c.siv_set_motion(txn, page, &.{
        .flags = .{ .enter = enter, .exit = true, .relative = true, .mirror_rtl = true },
        .duration_ms = tk.spring_ms,
        .enter_opacity = 1,
        .enter_x = x,
        .exit_opacity = 1,
        .exit_x = x,
    });
}

/// A page other than the first is a Tab stop of its own, so that focus
/// can move to it when it is pushed: a group named by its title, which a
/// screen reader announces.
fn applySemantics(txn: Txn, pg: *Page, title: []const u8) void {
    _ = c.siv_set_semantics(txn, pg.root, &.{ .role = .group, .label = title.ptr, .label_len = title.len, .flags = .{ .focusable = pg.index > 0 } });
}

fn setTitle(txn: Txn, pg: *Page, title: []const u8) void {
    applySemantics(txn, pg, title);
    if (pg.bar != .null) @import("header_bar.zig").pageTitle(txn, pg.bar, title);
}

/// The page's title, its accessible name.
pub fn titleOf(page: Node, buf: []u8) []const u8 {
    return w.labelOf(page, buf);
}

/// A header bar built inside `node`'s page: the page, or null.
pub fn enclosingPage(node: Node) ?*Page {
    var n = node;
    while (n != .null) : (n = w.related(n, .parent)) if (pageOf(n)) |pg| return pg;
    return null;
}

fn getValue(st: *const Stack) f64 {
    return @floatFromInt(st.count);
}

fn getPart(st: *const Stack, part: siv.WidgetPart, index: u32) Node {
    if (part != .panel) return .null;
    const pg = nth(st, index) orelse return .null;
    return pg.root;
}

/// Focus in the stack goes to the page that shows.
fn focusTop(st: *Stack) Node {
    const pg = top(st) orelse return .null;
    return focusPage(pg);
}

/// Where focus in a page goes: back to where it was, else the page.
fn focusPage(pg: *Page) Node {
    if (pg.focus != .null and w.windowOf(pg.focus) != .null and within(pg.focus, pg.root)) return pg.focus;
    return if (pg.index > 0) pg.root else .null;
}

/// The application's siv_widget_set_value: removes the pages above
/// `v`, without a report.
fn setValue(txn: Txn, st: *Stack, v: f64) void {
    if (!(v >= 0) or v > @as(f64, @floatFromInt(st.count))) {
        _ = c.siv_txn_fail(txn, .error_invalid_argument);
        return;
    }
    popTo(txn, st, @intFromFloat(v));
}

/// Removes the pages from `count` up and shows the one below them,
/// with focus back where it was if it was among the removed pages.
fn popTo(txn: Txn, st: *Stack, count: u32) void {
    if (count >= st.count) return;
    const focus = c.siv_window_get_focus(w.windowOf(st.root));
    const focus_here = focus == .null or within(focus, st.root);
    while (st.count > count) : (st.count -= 1) {
        const pg = top(st) orelse break;
        slide(txn, pg.root, true, true);
        _ = c.siv_remove(txn, pg.root);
    }
    const shown = top(st) orelse return;
    slide(txn, shown.root, false, true);
    _ = c.siv_set_hidden(txn, shown.root, false);
    if (focus_here) {
        const target = focusPage(shown);
        if (target != .null) _ = c.siv_node_focus(target);
        shown.focus = .null;
    }
}

/// Going back from the page that shows: reports `close` on it. False
/// when there is no page to go back to.
pub fn back(st: *Stack) bool {
    if (st.count < 2) return false;
    const pg = top(st) orelse return false;
    askClose(pg.root);
    return true;
}

/// Asks a page to close, as going back from it does.
pub fn askClose(page: Node) void {
    var handled = false;
    _ = c.siv_node_emit(page, &.{ .type = .close }, &handled);
}

/// The default `close`: removes the page (and any above it) and reports
/// the stack's new depth.
fn onClose(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const pg: *Page = @ptrCast(@alignCast(ud.?));
    const st = w.stateOf(Stack, pg.stack, &.{.navigation_stack}) orelse return .pass;
    if (pg.index == 0) return .pass;
    const stack = pg.stack;
    const index = pg.index;
    const txn = w.begin(ev.window) orelse return .pass;
    popTo(txn, st, index);
    if (!w.commit(txn)) return .handled;
    w.emitChange(stack, @floatFromInt(index), index - 1);
    return .handled;
}

/// Alt+Left (Alt+Right in RTL), XF86Back, and Escape go back.
fn onKey(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Stack = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.pressed) return .pass;
    const m = ev.modifiers;
    const k = w.keysym;
    const go = switch (ev.keysym) {
        k.back => !m.ctrl and !m.alt and !m.shift and !m.super,
        k.escape => !st.no_escape and !m.ctrl and !m.alt and !m.shift and !m.super,
        k.left, k.right => m.alt and !m.ctrl and !m.shift and !m.super and ev.keysym == backArrow(node),
        else => false,
    };
    return w.resultOf(go and back(st));
}

/// The arrow that points back: toward the start edge.
pub fn backArrow(node: Node) siv.Key {
    return if (w.isRtl(node)) w.keysym.right else w.keysym.left;
}

/// The mouse's back button goes back.
fn onPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Stack = @ptrCast(@alignCast(ud.?));
    if (ev.phase != .down or ev.button != .back) return .pass;
    return w.resultOf(back(st));
}
