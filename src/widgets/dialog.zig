//! Modal dialogs inside the window: a scrim over the parent with a card
//! holding the title, an optional message, the content part, and the
//! actions part at the end edge. The dialog is a modal node (D22), so the
//! pointer and Tab stay inside it, and it takes focus when created, so
//! screen readers announce it by its title. Escape and presses on the
//! scrim report `close`; the default handler removes the dialog.

const std = @import("std");
const w = @import("widgets.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Dialog = extern struct {
    hdr: w.Header,
    root: Node,
    card: Node,
    title: Node,
    text: Node,
    content: Node,
    actions: Node,
};

pub export fn siv_dialog(txn: Txn, parent: Node, desc: ?*const siv.DialogDesc) Node {
    const d = w.readDesc(siv.DialogDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    const title = w.str(d.title, d.title_len) orelse return w.fail(txn, .error_invalid_argument);
    const message = w.str(d.text, d.text_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_stack(txn, parent, &.{ .align_x = .center, .align_y = .center });
    if (root == .null) return .null;
    _ = c.siv_set_default_layout(txn, root, &.{
        .align_x = .stretch,
        .align_y = .stretch,
        .grow = 1,
        .padding = .{ .start = 24, .end = 24, .top = 24, .bottom = 24 },
    });
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .scrim });
    const st = w.create(Dialog, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .dialog }, .root = root, .card = .null, .title = .null, .text = .null, .content = .null, .actions = .null };
    st.card = c.siv_flex(txn, root, &.{ .axis = .column, .gap = 12 });
    _ = c.siv_set_layout(txn, st.card, &.{ .min_width = 280, .max_width = 560, .padding = .{ .start = 20, .end = 20, .top = 20, .bottom = 16 } });
    _ = c.siv_set_visual(txn, st.card, &.{ .radius = w.corners(tk.card_radius), .border_width = tk.border, .border_token = .border, .background_token = .card_bg });
    st.title = c.siv_text(txn, st.card, title.ptr, title.len);
    _ = c.siv_set_text_style(txn, st.title, &.{ .color_token = .card_fg, .size_role = .heading, .weight = .bold });
    _ = c.siv_set_semantics(txn, st.title, &.{ .role = .heading });
    st.text = c.siv_text(txn, st.card, message.ptr, message.len);
    _ = c.siv_set_text_style(txn, st.text, &.{ .color_token = .muted_fg, .size_role = .body });
    _ = c.siv_set_visual(txn, st.text, &.{ .flags = .{ .hidden = message.len == 0 } });
    st.content = c.siv_flex(txn, st.card, &.{ .axis = .column, .gap = tk.gap });
    st.actions = c.siv_flex(txn, st.card, &.{ .axis = .row, .justify = .end, .gap = tk.gap });
    applySemantics(txn, st, title);
    w.setInterface(txn, root, Dialog, st, .{ .set_label = setTitle, .get_part = part });
    w.onDefault(txn, root, .key, onKey, st);
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .close, onClose, st);
    // Focus moves into the dialog at once; Tab then reaches its controls.
    _ = c.siv_node_focus(root);
    return root;
}

fn applySemantics(txn: Txn, st: *Dialog, title: []const u8) void {
    _ = c.siv_set_semantics(txn, st.root, &.{
        .role = .dialog,
        .label = title.ptr,
        .label_len = title.len,
        .flags = .{ .modal = true, .focusable = true },
    });
}

/// The content and actions parts.
fn part(st: *const Dialog, p: siv.WidgetPart, _: u32) Node {
    return switch (p) {
        .content => st.content,
        .actions => st.actions,
        else => .null,
    };
}

pub fn setTitle(txn: Txn, st: *Dialog, title: []const u8) void {
    _ = c.siv_set_text(txn, st.title, title.ptr, title.len);
    applySemantics(txn, st, title);
}

fn askClose(root: Node) void {
    var handled = false;
    _ = c.siv_node_emit(root, &.{ .type = .close }, &handled);
}

fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Dialog = @ptrCast(@alignCast(ud.?));
    const e = ev;
    if (!e.flags.pressed or e.keysym != w.keysym.escape) return .pass;
    askClose(st.root);
    return .handled;
}

/// A press on the scrim, outside the card, asks to close.
fn onPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Dialog = @ptrCast(@alignCast(ud.?));
    const e = ev;
    if (e.phase != .down or e.button != .primary) return .pass;
    var root: siv.Rect = undefined;
    var card: siv.Rect = undefined;
    if (c.siv_node_get_rect(st.root, &root) != .ok or c.siv_node_get_rect(st.card, &card) != .ok) return .pass;
    const x = root.x + e.x;
    const y = root.y + e.y;
    if (x >= card.x and x < card.x + card.width and y >= card.y and y < card.y + card.height) return .pass;
    askClose(st.root);
    return .handled;
}

fn onClose(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    _ = ud;
    const txn = w.begin(ev.window) orelse return .pass;
    _ = c.siv_remove(txn, node);
    _ = w.commit(txn);
    return .handled;
}
