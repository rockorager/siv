//! Input methods through text-input-v3 (D15). The seat's text input enters
//! the window; while a (non-masked) editor has focus the window enables it
//! and keeps it told the surrounding text, caret, content type, and caret
//! rectangle, sent after each frame so the rectangle matches what is
//! shown. Input method changes arrive as `platform.TextInput` events:
//! deletions and commits edit the editor (with undo), and the preedit is
//! shown inline, underlined, without becoming part of the text.
//!
//! The window never touches the display: requests go to `Host.text_input`,
//! which the application runs on the compositor thread with
//! `Compositor.post`, in order with layer commits (D8).

const std = @import("std");
const platform = @import("platform");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const editor = @import("editor.zig");
const text_node = @import("text_node.zig");

const NodeId = node_mod.NodeId;

/// Surrounding text sent on each side of the caret, at most.
const context_bytes = 1000;

pub const State = struct {
    /// The seat whose text input entered this window.
    seat: ?platform.SeatId = null,
    /// The editor the input method works on.
    target: NodeId = .none,
    preedit: std.ArrayList(u8) = .empty,
    cursor_begin: i32 = 0,
    cursor_end: i32 = 0,
    /// The next update reports a change the input method made.
    from_input_method: bool = false,
    /// Something the input method should hear about may have changed.
    dirty: bool = false,
    /// What was last sent, to send only changes.
    sent: ?Sent = null,

    const Sent = struct {
        seat: platform.SeatId,
        enabled: bool,
        hash: u64,
    };

    pub fn deinit(st: *State, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, st.preedit.items);
        st.preedit.deinit(gpa);
    }

    /// The preedit shown in `id`, if any.
    pub fn preeditFor(st: *const State, id: NodeId) ?[]const u8 {
        if (st.target != id or st.preedit.items.len == 0) return null;
        return st.preedit.items;
    }
};

fn wants(win: *const Window, id: NodeId) bool {
    if (id == .none or !win.isLive(id)) return false;
    const n = win.node(id);
    return n.kind == .editor and !n.data.editor.editor.masked and !n.semantics.disabled;
}

fn clearPreedit(win: *Window) void {
    const st = &win.ime;
    if (st.preedit.items.len == 0) return;
    std.crypto.secureZero(u8, st.preedit.items);
    st.preedit.clearRetainingCapacity();
    if (win.isLive(st.target)) win.markShape(st.target);
}

/// Drops the preedit (the user clicked elsewhere in the text); the input
/// method resets when it hears the new caret.
pub fn reset(win: *Window) void {
    clearPreedit(win);
    win.ime.dirty = true;
}

/// Focus changed: the input method follows to the new editor.
pub fn focusChanged(win: *Window) void {
    const st = &win.ime;
    const focus = win.input.focus;
    if (st.target != focus) {
        clearPreedit(win);
        st.target = if (wants(win, focus)) focus else .none;
    }
    st.dirty = true;
}

pub fn handle(win: *Window, event: *const platform.Event) void {
    const st = &win.ime;
    switch (event.*) {
        .text_input_enter => |e| {
            st.seat = e.seat;
            st.sent = null;
            st.dirty = true;
            win.requestFrame();
        },
        .text_input_leave => |e| if (st.seat == e.seat) {
            st.seat = null;
            st.sent = null;
            clearPreedit(win);
            win.requestFrame();
        },
        .text_input => |*e| apply(win, e),
        else => {},
    }
}

fn apply(win: *Window, e: *const platform.TextInput) void {
    const st = &win.ime;
    const id = st.target;
    if (st.seat != e.seat or !wants(win, id) or win.input.focus != id) return;
    // The old preedit goes first, then deletion and commit, then the new
    // preedit (the protocol's order).
    if (e.delete_before != 0 or e.delete_after != 0 or e.commit_len != 0 or !e.more) clearPreedit(win);
    if (e.delete_before != 0 or e.delete_after != 0 or e.commit_len != 0)
        editor.imeCommit(win, id, e.delete_before, e.delete_after, e.commit());
    if (!e.more and e.preedit_len != 0) {
        st.preedit.appendSlice(win.gpa, e.preedit()) catch return;
        st.cursor_begin = e.cursor_begin;
        st.cursor_end = e.cursor_end;
        win.markShape(id);
    }
    st.from_input_method = true;
    st.dirty = true;
    win.requestFrame();
}

/// Sends the input method what changed since the last frame. Called at the
/// end of each frame.
pub fn sync(win: *Window) void {
    const st = &win.ime;
    const seat = st.seat orelse {
        st.dirty = false;
        return;
    };
    if (st.target != win.input.focus) focusChanged(win);
    var state: platform.TextInputState = .{};
    if (wants(win, st.target) and win.input.focus == st.target) fill(win, st.target, &state);
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, .{ state.enabled, state.cursor, state.anchor, state.hint, state.purpose, state.cursor_rect.x, state.cursor_rect.y, state.cursor_rect.width, state.cursor_rect.height });
    hasher.update(state.surrounding);
    const now: State.Sent = .{ .seat = seat, .enabled = state.enabled, .hash = hasher.final() };
    st.dirty = false;
    if (st.sent) |prev| if (std.meta.eql(prev, now)) return;
    // Nothing to disable that was never enabled.
    if (st.sent == null and !state.enabled) {
        st.sent = now;
        return;
    }
    st.sent = now;
    state.from_input_method = st.from_input_method;
    st.from_input_method = false;
    win.host.text_input(win.host.ctx, seat, &state);
}

fn fill(win: *Window, id: NodeId, state: *platform.TextInputState) void {
    const n = win.node(id);
    const e = n.data.editor;
    const content = e.text.content;
    // A window of text around the caret, cut at character boundaries.
    var start: usize = (@min(e.caret, e.anchor)) -| context_bytes;
    while (start > 0 and start < content.len and content[start] & 0xc0 == 0x80) start -= 1;
    var end: usize = @min(content.len, @as(usize, @max(e.caret, e.anchor)) + context_bytes);
    while (end < content.len and content[end] & 0xc0 == 0x80) end += 1;
    if (end - start > platform.TextInputState.max_surrounding) {
        start = e.caret -| platform.TextInputState.max_surrounding / 2;
        while (start < content.len and content[start] & 0xc0 == 0x80) start += 1;
        end = @min(content.len, start + platform.TextInputState.max_surrounding);
        while (end > start and end < content.len and content[end] & 0xc0 == 0x80) end -= 1;
    }
    state.enabled = true;
    state.surrounding = content[start..end];
    state.cursor = @intCast(std.math.clamp(e.caret, start, end) - start);
    state.anchor = @intCast(std.math.clamp(e.anchor, start, end) - start);
    state.hint = .{ .multiline = e.editor.multiline };
    if (text_node.current(win, id)) |l| {
        const r = win.windowRect(id);
        const s = win.state(id);
        const c = editor.caretRect(win, id, l) catch return;
        const x = r.x0 + n.layout.padding.left(s.rtl) - s.editor_scroll + c.x0;
        const y = r.y0 + n.layout.padding.top + c.y0;
        state.cursor_rect = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)), .width = @intFromFloat(@ceil(c.width())), .height = @intFromFloat(@ceil(c.height())) };
    }
}
