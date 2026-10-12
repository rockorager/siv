//! A wl_seat (D16): keyboard with XKB keymaps, compose, and key repeat;
//! pointer with high-resolution scrolling and axis source; touch. Listeners
//! translate events and queue them; scroll and touch events are grouped by
//! the protocol's frame events.

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wayland").client.wl;
const platform = @import("platform.zig");
const Loop = platform.Loop;
const Timer = @import("loop").Timer;
const Wayland = @import("Wayland.zig");
const Keyboard = @import("Keyboard.zig");
const Seat = @This();

const WindowId = platform.WindowId;
const SeatId = platform.SeatId;

backend: *Wayland,
id: SeatId,
global: u32,
proxy: *wl.Seat,
pointer: ?*wl.Pointer = null,
keyboard_proxy: ?*wl.Keyboard = null,
touch: ?*wl.Touch = null,

keyboard: Keyboard,
keyboard_focus: ?WindowId = null,
/// Keys per second; 0 disables repeat.
repeat_rate: i32 = 25,
repeat_delay_ms: i32 = 600,
repeat_timer: Timer = .{ .func = onRepeat },
repeat_key: platform.Key = undefined,

pointer_focus: ?WindowId = null,
scroll: platform.Scroll = undefined,
scrolling: bool = false,

points: [max_points]Point = @splat(.{}),

const max_points = 16;

const Point = struct {
    active: bool = false,
    down: bool = false,
    moved: bool = false,
    up: bool = false,
    touch: platform.Touch = undefined,
};

pub fn create(backend: *Wayland, id: SeatId, registry: *wl.Registry, name: u32, version: u32) !*Seat {
    const proxy = try registry.bind(name, wl.Seat, version);
    errdefer proxy.destroy();
    const seat = try backend.allocator.create(Seat);
    seat.* = .{
        .backend = backend,
        .id = id,
        .global = name,
        .proxy = proxy,
        .keyboard = .{ .context = backend.xkb_context },
    };
    seat.keyboard.setComposeTable(backend.compose_table);
    proxy.setListener(*Seat, onSeat, seat);
    return seat;
}

pub fn destroy(seat: *Seat) void {
    seat.backend.loop.cancelTimer(&seat.repeat_timer);
    seat.setCapabilities(.{});
    seat.keyboard.deinit();
    if (seat.proxy.getVersion() >= 5) seat.proxy.release() else seat.proxy.destroy();
    seat.backend.allocator.destroy(seat);
}

/// Drops references to a destroyed window.
pub fn forgetWindow(seat: *Seat, id: WindowId) void {
    if (seat.keyboard_focus == id) {
        seat.keyboard_focus = null;
        seat.stopRepeat();
    }
    if (seat.pointer_focus == id) {
        seat.pointer_focus = null;
        seat.scrolling = false;
    }
    for (&seat.points) |*p| if (p.active and p.touch.window == id) {
        p.* = .{};
    };
}

fn push(seat: *Seat, event: platform.Event) void {
    seat.backend.queue.push(event);
}

fn onSeat(_: *wl.Seat, event: wl.Seat.Event, seat: *Seat) void {
    switch (event) {
        .capabilities => |c| seat.setCapabilities(c.capabilities),
        .name => {},
    }
}

fn setCapabilities(seat: *Seat, caps: wl.Seat.Capability) void {
    const v3 = seat.proxy.getVersion() >= 3;
    if (caps.pointer and seat.pointer == null) {
        if (seat.proxy.getPointer()) |p| {
            p.setListener(*Seat, onPointer, seat);
            seat.pointer = p;
        } else |_| seat.backend.queue.fail(error.OutOfMemory);
    } else if (!caps.pointer and seat.pointer != null) {
        const p = seat.pointer.?;
        if (v3) p.release() else p.destroy();
        seat.pointer = null;
        seat.scrolling = false;
        if (seat.pointer_focus) |w| seat.push(.{ .pointer_leave = .{ .window = w, .seat = seat.id, .serial = 0 } });
        seat.pointer_focus = null;
    }
    if (caps.keyboard and seat.keyboard_proxy == null) {
        if (seat.proxy.getKeyboard()) |k| {
            k.setListener(*Seat, onKeyboard, seat);
            seat.keyboard_proxy = k;
        } else |_| seat.backend.queue.fail(error.OutOfMemory);
    } else if (!caps.keyboard and seat.keyboard_proxy != null) {
        const k = seat.keyboard_proxy.?;
        if (v3) k.release() else k.destroy();
        seat.keyboard_proxy = null;
        seat.stopRepeat();
        if (seat.keyboard_focus) |w| seat.push(.{ .keyboard_leave = .{ .window = w, .seat = seat.id, .serial = 0 } });
        seat.keyboard_focus = null;
    }
    if (caps.touch and seat.touch == null) {
        if (seat.proxy.getTouch()) |t| {
            t.setListener(*Seat, onTouch, seat);
            seat.touch = t;
        } else |_| seat.backend.queue.fail(error.OutOfMemory);
    } else if (!caps.touch and seat.touch != null) {
        const t = seat.touch.?;
        if (v3) t.release() else t.destroy();
        seat.touch = null;
        for (seat.points) |p| if (p.active) {
            seat.push(.{ .touch_cancel = seat.id });
            break;
        };
        seat.points = @splat(.{});
    }
}

// Keyboard -----------------------------------------------------------------

fn onKeyboard(_: *wl.Keyboard, event: wl.Keyboard.Event, seat: *Seat) void {
    switch (event) {
        .keymap => |k| {
            defer _ = linux.close(k.fd);
            if (k.format != .xkb_v1 or k.size == 0) return;
            // Private mapping: required from wl_keyboard v7.
            const addr = linux.mmap(null, k.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, k.fd, 0);
            if (linux.errno(addr) != .SUCCESS) return seat.backend.queue.fail(error.SystemResources);
            defer _ = linux.munmap(@ptrFromInt(addr), k.size);
            const text: [*:0]const u8 = @ptrFromInt(addr);
            seat.stopRepeat();
            seat.keyboard.setKeymap(text) catch std.log.scoped(.wayland).err("invalid keymap from the compositor", .{});
        },
        .enter => |e| {
            const window = Wayland.windowOf(e.surface) orelse return;
            seat.keyboard_focus = window;
            // Keys already held at enter produce no events.
            seat.push(.{ .keyboard_enter = .{ .window = window, .seat = seat.id, .serial = e.serial } });
        },
        .leave => |e| {
            seat.stopRepeat();
            seat.keyboard.resetCompose();
            const window = seat.keyboard_focus orelse return;
            seat.keyboard_focus = null;
            seat.push(.{ .keyboard_leave = .{ .window = window, .seat = seat.id, .serial = e.serial } });
        },
        .key => |k| seat.handleKey(k.key + 8, k.state == .pressed, k.time, k.serial),
        .modifiers => |m| {
            seat.keyboard.updateMask(m.mods_depressed, m.mods_latched, m.mods_locked, m.group);
            const window = seat.keyboard_focus orelse return;
            seat.push(.{ .modifiers = .{ .window = window, .seat = seat.id, .mods = seat.keyboard.mods() } });
        },
        .repeat_info => |r| {
            seat.repeat_rate = r.rate;
            seat.repeat_delay_ms = r.delay;
            if (r.rate <= 0) seat.stopRepeat();
        },
    }
}

fn handleKey(seat: *Seat, keycode: u32, pressed: bool, time: u32, serial: u32) void {
    const window = seat.keyboard_focus orelse return;
    var key: platform.Key = .{
        .window = window,
        .seat = seat.id,
        .keycode = keycode,
        .keysym = 0,
        .state = if (pressed) .pressed else .released,
        .mods = seat.keyboard.mods(),
        .time = time,
        .serial = serial,
    };
    if (pressed) {
        const p = seat.keyboard.press(keycode);
        key.keysym = p.keysym;
        key.text_buf = p.text_buf;
        key.text_len = p.text_len;
        key.composing = p.composing;
    } else {
        key.keysym = seat.keyboard.keysym(keycode);
    }
    seat.push(.{ .key = key });

    if (pressed and seat.repeat_rate > 0 and seat.keyboard.repeats(keycode)) {
        seat.repeat_key = key;
        seat.repeat_key.state = .repeated;
        const delay = @as(u64, @intCast(@max(seat.repeat_delay_ms, 0))) * std.time.ns_per_ms;
        const interval = std.time.ns_per_s / @as(u64, @intCast(seat.repeat_rate));
        seat.backend.loop.startTimer(&seat.repeat_timer, Loop.now() + delay, interval) catch
            seat.backend.queue.fail(error.OutOfMemory);
    } else if (!pressed and seat.repeat_timer.armed() and seat.repeat_key.keycode == keycode) {
        seat.stopRepeat();
    }
}

fn stopRepeat(seat: *Seat) void {
    seat.backend.loop.cancelTimer(&seat.repeat_timer);
}

fn onRepeat(timer: *Timer) void {
    const seat: *Seat = @fieldParentPtr("repeat_timer", timer);
    if (seat.keyboard_focus != seat.repeat_key.window) return seat.stopRepeat();
    seat.push(.{ .key = seat.repeat_key });
}

// Pointer ----------------------------------------------------------------

fn onPointer(_: *wl.Pointer, event: wl.Pointer.Event, seat: *Seat) void {
    switch (event) {
        .enter => |e| {
            const window = Wayland.windowOf(e.surface) orelse return;
            seat.pointer_focus = window;
            seat.push(.{ .pointer_enter = .{
                .window = window,
                .seat = seat.id,
                .x = e.surface_x.toDouble(),
                .y = e.surface_y.toDouble(),
                .serial = e.serial,
            } });
        },
        .leave => |e| {
            seat.flushScroll();
            const window = seat.pointer_focus orelse return;
            seat.pointer_focus = null;
            seat.push(.{ .pointer_leave = .{ .window = window, .seat = seat.id, .serial = e.serial } });
        },
        .motion => |m| {
            const window = seat.pointer_focus orelse return;
            seat.push(.{ .pointer_motion = .{
                .window = window,
                .seat = seat.id,
                .x = m.surface_x.toDouble(),
                .y = m.surface_y.toDouble(),
                .time = m.time,
            } });
        },
        .button => |b| {
            const window = seat.pointer_focus orelse return;
            seat.push(.{ .pointer_button = .{
                .window = window,
                .seat = seat.id,
                .button = b.button,
                .pressed = b.state == .pressed,
                .time = b.time,
                .serial = b.serial,
            } });
        },
        .axis => |a| {
            const s = seat.beginScroll() orelse return;
            s.time = a.time;
            switch (a.axis) {
                .vertical_scroll => s.dy += a.value.toDouble(),
                .horizontal_scroll => s.dx += a.value.toDouble(),
                _ => {},
            }
            // Before wl_pointer v5 there are no frames.
            if (seat.pointer.?.getVersion() < 5) seat.flushScroll();
        },
        .frame => seat.flushScroll(),
        .axis_source => |a| {
            const s = seat.beginScroll() orelse return;
            s.source = switch (a.axis_source) {
                .wheel => .wheel,
                .finger => .finger,
                .continuous => .continuous,
                .wheel_tilt => .wheel_tilt,
                _ => .unknown,
            };
        },
        .axis_stop => |a| {
            const s = seat.beginScroll() orelse return;
            s.time = a.time;
            switch (a.axis) {
                .vertical_scroll => s.stop_y = true,
                .horizontal_scroll => s.stop_x = true,
                _ => {},
            }
        },
        .axis_discrete => |a| {
            // Replaced by axis_value120 from v8.
            if (seat.pointer.?.getVersion() >= 8) return;
            const s = seat.beginScroll() orelse return;
            addV120(s, a.axis, a.discrete * 120);
        },
        .axis_value120 => |a| {
            const s = seat.beginScroll() orelse return;
            addV120(s, a.axis, a.value120);
        },
        .axis_relative_direction => |a| {
            const s = seat.beginScroll() orelse return;
            const inverted = a.direction == .inverted;
            switch (a.axis) {
                .vertical_scroll => s.inverted_y = inverted,
                .horizontal_scroll => s.inverted_x = inverted,
                _ => {},
            }
        },
    }
}

fn addV120(s: *platform.Scroll, axis: wl.Pointer.Axis, v: i32) void {
    switch (axis) {
        .vertical_scroll => s.v120_y += v,
        .horizontal_scroll => s.v120_x += v,
        _ => {},
    }
}

fn beginScroll(seat: *Seat) ?*platform.Scroll {
    const window = seat.pointer_focus orelse return null;
    if (!seat.scrolling) {
        seat.scroll = .{ .window = window, .seat = seat.id };
        seat.scrolling = true;
    }
    return &seat.scroll;
}

fn flushScroll(seat: *Seat) void {
    if (!seat.scrolling) return;
    seat.scrolling = false;
    seat.push(.{ .scroll = seat.scroll });
}

// Touch ------------------------------------------------------------------

fn findPoint(seat: *Seat, id: i32) ?*Point {
    for (&seat.points) |*p| if (p.active and p.touch.id == id) return p;
    return null;
}

/// Public for tests: no headless compositor available here can inject touch.
pub fn onTouch(_: *wl.Touch, event: wl.Touch.Event, seat: *Seat) void {
    switch (event) {
        .down => |d| {
            const window = Wayland.windowOf(d.surface) orelse return;
            const p = for (&seat.points) |*p| {
                if (!p.active) break p;
            } else return; // more contacts than siv tracks
            p.* = .{ .active = true, .down = true, .touch = .{
                .window = window,
                .seat = seat.id,
                .id = d.id,
                .x = d.x.toDouble(),
                .y = d.y.toDouble(),
                .time = d.time,
                .serial = d.serial,
            } };
        },
        .motion => |m| {
            const p = seat.findPoint(m.id) orelse return;
            p.touch.x = m.x.toDouble();
            p.touch.y = m.y.toDouble();
            p.touch.time = m.time;
            p.moved = true;
        },
        .up => |u| {
            const p = seat.findPoint(u.id) orelse return;
            p.touch.time = u.time;
            p.touch.serial = u.serial;
            p.up = true;
        },
        .shape => |s| {
            const p = seat.findPoint(s.id) orelse return;
            p.touch.major = s.major.toDouble();
            p.touch.minor = s.minor.toDouble();
            p.moved = true;
        },
        .orientation => |o| {
            const p = seat.findPoint(o.id) orelse return;
            p.touch.orientation = o.orientation.toDouble();
            p.moved = true;
        },
        .frame => {
            var any = false;
            for (&seat.points) |*p| {
                if (!p.active) continue;
                if (p.down) {
                    seat.push(.{ .touch_down = p.touch });
                } else if (p.moved) {
                    seat.push(.{ .touch_motion = p.touch });
                }
                if (p.up) seat.push(.{ .touch_up = p.touch });
                any = any or p.down or p.moved or p.up;
                if (p.up) p.* = .{} else {
                    p.down = false;
                    p.moved = false;
                }
            }
            if (any) seat.push(.{ .touch_frame = seat.id });
        },
        .cancel => {
            seat.points = @splat(.{});
            seat.push(.{ .touch_cancel = seat.id });
        },
    }
}
