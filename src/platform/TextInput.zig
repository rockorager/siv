//! A seat's zwp_text_input_v3 (D15): input method focus, preedit, commit,
//! and surrounding-text deletion collected until `done` and queued as
//! `platform.TextInput` events; and the client's state sent as one commit.

const std = @import("std");
const wl = @import("wayland").client.wl;
const zwp = @import("wayland").client.zwp;
const platform = @import("platform.zig");
const Wayland = @import("Wayland.zig");
const TextInput = @This();

backend: *Wayland,
seat: platform.SeatId,
proxy: *zwp.TextInputV3,
/// The window the input method focuses.
focus: ?platform.WindowId = null,
/// Changes since the last `done`.
preedit: std.ArrayList(u8) = .empty,
commit: std.ArrayList(u8) = .empty,
cursor_begin: i32 = 0,
cursor_end: i32 = 0,
delete_before: u32 = 0,
delete_after: u32 = 0,
/// Whether the client enabled it (enable/disable are sent on change).
enabled: bool = false,

pub fn create(backend: *Wayland, manager: *zwp.TextInputManagerV3, seat: platform.SeatId, seat_proxy: *wl.Seat) !*TextInput {
    const proxy = try manager.getTextInput(seat_proxy);
    errdefer proxy.destroy();
    const ti = try backend.allocator.create(TextInput);
    ti.* = .{ .backend = backend, .seat = seat, .proxy = proxy };
    proxy.setListener(*TextInput, onEvent, ti);
    return ti;
}

pub fn destroy(ti: *TextInput) void {
    ti.proxy.destroy();
    ti.preedit.deinit(ti.backend.allocator);
    ti.commit.deinit(ti.backend.allocator);
    ti.backend.allocator.destroy(ti);
}

pub fn forgetWindow(ti: *TextInput, id: platform.WindowId) void {
    if (ti.focus == id) ti.focus = null;
}

fn set(ti: *TextInput, list: *std.ArrayList(u8), text: ?[*:0]const u8) void {
    list.clearRetainingCapacity();
    const s = if (text) |t| std.mem.span(t) else return;
    list.appendSlice(ti.backend.allocator, s) catch ti.backend.queue.fail(error.OutOfMemory);
}

fn onEvent(_: *zwp.TextInputV3, event: zwp.TextInputV3.Event, ti: *TextInput) void {
    switch (event) {
        .enter => |e| if (Wayland.windowOf(e.surface)) |w| {
            ti.focus = w;
            ti.backend.queue.push(.{ .text_input_enter = .{ .window = w, .seat = ti.seat, .serial = 0 } });
        },
        .leave => |e| if (Wayland.windowOf(e.surface)) |w| {
            if (ti.focus == w) ti.focus = null;
            ti.backend.queue.push(.{ .text_input_leave = .{ .window = w, .seat = ti.seat, .serial = 0 } });
        },
        .preedit_string => |e| {
            ti.set(&ti.preedit, e.text);
            ti.cursor_begin = e.cursor_begin;
            ti.cursor_end = e.cursor_end;
        },
        .commit_string => |e| ti.set(&ti.commit, e.text),
        .delete_surrounding_text => |e| {
            ti.delete_before = e.before_length;
            ti.delete_after = e.after_length;
        },
        .done => |e| {
            if (ti.focus) |w| platform.TextInput.split(w, ti.seat, e.serial, ti.delete_before, ti.delete_after, ti.commit.items, ti.preedit.items, ti.cursor_begin, ti.cursor_end, ti, emit);
            ti.commit.clearRetainingCapacity();
            ti.preedit.clearRetainingCapacity();
            ti.cursor_begin = 0;
            ti.cursor_end = 0;
            ti.delete_before = 0;
            ti.delete_after = 0;
        },
    }
}

fn emit(ti: *TextInput, ev: platform.TextInput) void {
    ti.backend.queue.push(.{ .text_input = ev });
}

/// Sends the client's state and commits.
pub fn update(ti: *TextInput, state: *const platform.TextInputState) void {
    if (!state.enabled) {
        if (!ti.enabled) return;
        ti.enabled = false;
        ti.proxy.disable();
        ti.proxy.commit();
        return;
    }
    if (!ti.enabled) ti.proxy.enable();
    ti.enabled = true;
    var buf: [platform.TextInputState.max_surrounding + 1]u8 = undefined;
    const n = @min(state.surrounding.len, platform.TextInputState.max_surrounding);
    @memcpy(buf[0..n], state.surrounding[0..n]);
    buf[n] = 0;
    ti.proxy.setSurroundingText(buf[0..n :0], @intCast(@min(state.cursor, n)), @intCast(@min(state.anchor, n)));
    ti.proxy.setTextChangeCause(if (state.from_input_method) .input_method else .other);
    ti.proxy.setContentType(@bitCast(state.hint), @enumFromInt(@intFromEnum(state.purpose)));
    const r = state.cursor_rect;
    ti.proxy.setCursorRectangle(r.x, r.y, r.width, r.height);
    ti.proxy.commit();
}
