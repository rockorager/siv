//! Toasts: a brief message in the inverse colors at the bottom of its
//! parent, a live region that assistive technology announces (status, or
//! alert when assertive). It rises into place and, after its timeout,
//! reports `close`; the default handler removes it, and it fades out on
//! the compositor (D38; both jumps under reduced motion, D29). Timers
//! carry the node's handle, not its state, so a toast the application
//! removed early is simply not found.
//! An action ("Undo") is a button in the card: pressing it reports
//! `activate` on the toast, which then closes.

const std = @import("std");
const w = @import("widgets.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Toast = extern struct {
    hdr: w.Header,
    root: Node,
    text: Node,
    action: Node = .null,
};

pub export fn siv_toast(txn: Txn, parent: Node, desc: ?*const siv.ToastDesc) Node {
    const d = w.readDesc(siv.ToastDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 3) != 0) return w.fail(txn, .error_unsupported);
    const text = w.str(d.text, d.text_len) orelse return w.fail(txn, .error_invalid_argument);
    const action = w.str(d.action, d.action_len) orelse return w.fail(txn, .error_invalid_argument);
    // The root keeps the toast off the parent's bottom edge; the card in
    // it shows the message. An application's layout on the root moves it.
    const root = c.siv_stack(txn, parent, &.{ .align_x = .center });
    if (root == .null) return .null;
    _ = c.siv_set_default_layout(txn, root, &.{
        .align_x = .center,
        .align_y = .end,
        .padding = .{ .start = 16, .end = 16, .top = 16, .bottom = 24 },
    });
    // Clicks pass through a toast, except to its action.
    _ = c.siv_set_visual(txn, root, &.{ .flags = .{ .no_hit_test = action.len == 0 } });
    // It rises from below, and leaves fading and shrinking a little; a
    // longer message grows it in place.
    _ = c.siv_set_motion(txn, root, &.{
        .flags = .{ .layout = true, .enter = true, .exit = true },
        .duration_ms = tk.spring_ms,
        .enter_y = 24,
        .exit_scale = 0.9,
    });
    _ = c.siv_set_semantics(txn, root, &.{
        .role = if (d.flags.assertive) .alert else .status,
        .flags = if (d.flags.assertive) .{ .live_assertive = true } else .{ .live_polite = true },
    });
    const card = c.siv_flex(txn, root, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    _ = c.siv_set_layout(txn, card, &.{ .max_width = 480, .padding = .{ .start = 16, .end = 16, .top = 10, .bottom = 10 } });
    _ = c.siv_set_visual(txn, card, &.{ .radius = w.corners(tk.radius + 2), .background_token = .inverse_bg });
    const st = w.create(Toast, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .toast }, .root = root, .text = c.siv_text(txn, card, text.ptr, text.len) };
    _ = c.siv_set_text_style(txn, st.text, &.{ .color_token = .inverse_fg, .size_role = .body });
    if (action.len != 0) {
        // The accent reads on the inverse surface in every theme, where a
        // flat button's control color would not.
        st.action = c.siv_push_button(txn, card, &.{ .label = action.ptr, .label_len = action.len, .style = .primary });
        _ = c.siv_set_layout(txn, card, &.{ .max_width = 480, .padding = .{ .start = 16, .end = 6, .top = 6, .bottom = 6 } });
        _ = c.siv_on_default(txn, st.action, .activate, onAction, null, w.handleData(root));
    }
    w.onDefault(txn, root, .close, onClose, st);
    w.setInterface(txn, root, Toast, st, .{ .set_label = setText });
    if (!d.flags.persistent) {
        const app = w.appOf(w.windowOf(root));
        var timer: siv.Timer = .null;
        const default_ms: u32 = if (action.len != 0) 8000 else 4000;
        _ = c.siv_timer_start(app, if (d.timeout_ms == 0) default_ms else d.timeout_ms, onTimeout, null, w.handleData(root), &timer);
    }
    return root;
}

pub fn setText(txn: Txn, st: *Toast, text: []const u8) void {
    _ = c.siv_set_text(txn, st.text, text.ptr, text.len);
}

/// The action: the toast reports activate, then closes.
fn onAction(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const node = w.dataHandle(ud);
    if (w.stateOf(Toast, node, &.{.toast}) == null) return .handled;
    var handled = false;
    _ = c.siv_node_emit(node, &.{ .type = .activate }, &handled);
    if (w.stateOf(Toast, node, &.{.toast}) == null) return .handled;
    _ = c.siv_node_emit(node, &.{ .type = .close }, &handled);
    return .handled;
}

fn onTimeout(ud: ?*anyopaque) callconv(.c) void {
    const node = w.dataHandle(ud);
    if (w.stateOf(Toast, node, &.{.toast}) == null) return;
    var handled = false;
    _ = c.siv_node_emit(node, &.{ .type = .close }, &handled);
}

/// Removes it; its exit transition fades it out.
fn onClose(_: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const txn = w.begin(ev.window) orelse return .pass;
    _ = c.siv_remove(txn, node);
    if (!w.commit(txn)) return .pass;
    return .handled;
}
