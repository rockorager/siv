//! A wl_seat (D16): keyboard with XKB keymaps, compose, and key repeat;
//! pointer with high-resolution scrolling and axis source, and touchpad
//! gestures (pointer-gestures); touch. Listeners translate events and
//! queue them; scroll and touch events are grouped by the protocol's frame
//! events.

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wayland").client.wl;
const platform = @import("platform.zig");
const Loop = platform.Loop;
const Timer = @import("loop").Timer;
const Wayland = @import("Wayland.zig");
const Keyboard = @import("Keyboard.zig");
const TextInput = @import("TextInput.zig");
const DataDevice = @import("DataDevice.zig");
const Tablet = @import("Tablet.zig");
const cursor = @import("cursor.zig");
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
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
text_input: ?*TextInput = null,
data: *DataDevice = undefined,
/// Tablet tools and pads (tablet-v2), once the manager is known.
tablet: ?*Tablet = null,

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

/// Touchpad gestures on the pointer (pointer-gestures), and the window
/// each kind's gesture in progress began on.
swipe: ?*zwp.PointerGestureSwipeV1 = null,
pinch: ?*zwp.PointerGesturePinchV1 = null,
hold: ?*zwp.PointerGestureHoldV1 = null,
gesture_window: [3]?WindowId = @splat(null),
gesture_fingers: [3]u32 = @splat(0),

/// Pointer constraints windows asked for (pointer-constraints), relative
/// motion (relative-pointer, made on first request), and shortcut
/// inhibitors (keyboard-shortcuts-inhibit), each per window.
constraints: std.ArrayList(*Constraint) = .empty,
relative: ?*zwp.RelativePointerV1 = null,
inhibitors: std.ArrayList(*Inhibitor) = .empty,

/// Serial of the pointer's last enter, which cursor requests name.
enter_serial: u32 = 0,
/// cursor-shape-v1 for the pointer, if the compositor offers it.
shape_device: ?*wp.CursorShapeDeviceV1 = null,
/// Otherwise a surface showing themed cursor images, scaled with a
/// viewport when there is one.
cursor_surface: ?*wl.Surface = null,
cursor_viewport: ?*wp.Viewport = null,
/// The animated cursor being shown, and its frame.
cursor_anim: ?*cursor.Loaded = null,
cursor_frame: usize = 0,
cursor_timer: Timer = .{ .func = onCursorFrame },

points: [max_points]Point = @splat(.{}),

const max_points = 16;

pub const Constraint = struct {
    seat: *Seat,
    window: WindowId,
    locked: ?*zwp.LockedPointerV1 = null,
    confined: ?*zwp.ConfinedPointerV1 = null,
    persistent: bool,
    active: bool = false,
};

pub const Inhibitor = struct {
    seat: *Seat,
    window: WindowId,
    proxy: *zwp.KeyboardShortcutsInhibitorV1,
};

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
    seat.data = DataDevice.create(backend, id) catch |err| {
        backend.allocator.destroy(seat);
        return err;
    };
    seat.data.bind(proxy);
    proxy.setListener(*Seat, onSeat, seat);
    return seat;
}

/// Creates the seat's text input once the manager is known.
pub fn addTextInput(seat: *Seat, manager: *zwp.TextInputManagerV3) void {
    if (seat.text_input != null) return;
    seat.text_input = TextInput.create(seat.backend, manager, seat.id, seat.proxy) catch {
        seat.backend.queue.fail(error.OutOfMemory);
        return;
    };
}

/// Creates the seat's tablet seat once the manager is known.
pub fn addTablet(seat: *Seat, manager: *zwp.TabletManagerV2) void {
    if (seat.tablet != null) return;
    seat.tablet = Tablet.create(seat.backend, manager, seat.id, seat.proxy) catch {
        seat.backend.queue.fail(error.OutOfMemory);
        return;
    };
}

pub fn destroy(seat: *Seat) void {
    for (seat.inhibitors.items) |i| {
        i.proxy.destroy();
        seat.backend.allocator.destroy(i);
    }
    seat.inhibitors.deinit(seat.backend.allocator);
    if (seat.tablet) |t| t.destroy();
    if (seat.text_input) |ti| ti.destroy();
    seat.data.destroy();
    seat.backend.loop.cancelTimer(&seat.repeat_timer);
    seat.backend.loop.cancelTimer(&seat.cursor_timer);
    if (seat.cursor_viewport) |v| v.destroy();
    if (seat.cursor_surface) |c| c.destroy();
    seat.setCapabilities(.{});
    seat.constraints.deinit(seat.backend.allocator);
    seat.keyboard.deinit();
    if (seat.proxy.getVersion() >= 5) seat.proxy.release() else seat.proxy.destroy();
    seat.backend.allocator.destroy(seat);
}

/// Drops references to a destroyed window.
pub fn forgetWindow(seat: *Seat, id: WindowId) void {
    if (seat.text_input) |ti| ti.forgetWindow(id);
    if (seat.tablet) |t| t.forgetWindow(id);
    seat.data.forgetWindow(id);
    if (seat.keyboard_focus == id) {
        seat.keyboard_focus = null;
        seat.stopRepeat();
    }
    if (seat.pointer_focus == id) {
        seat.pointer_focus = null;
        seat.scrolling = false;
    }
    for (&seat.gesture_window) |*g| if (g.* == id) {
        g.* = null;
    };
    seat.dropConstraint(id, false);
    for (seat.inhibitors.items, 0..) |inh, i| if (inh.window == id) {
        inh.proxy.destroy();
        seat.backend.allocator.destroy(inh);
        _ = seat.inhibitors.swapRemove(i);
        break;
    };
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
            seat.addShapeDevice();
            seat.addGestures();
            for (seat.backend.windows.items) |w| if (w) |win| seat.applyConstraint(win);
        } else |_| seat.backend.queue.fail(error.OutOfMemory);
    } else if (!caps.pointer and seat.pointer != null) {
        const p = seat.pointer.?;
        if (seat.shape_device) |d| d.destroy();
        seat.shape_device = null;
        seat.removeGestures();
        while (seat.constraints.items.len != 0) seat.dropConstraint(seat.constraints.items[0].window, true);
        if (seat.relative) |r| r.destroy();
        seat.relative = null;
        seat.stopCursorAnimation();
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
            seat.push(.{ .key_repeat = .{ .seat = seat.id, .delay_ms = @intCast(@max(r.delay, 0)), .rate = @intCast(@max(r.rate, 0)) } });
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
            seat.enter_serial = e.serial;
            seat.applyCursor();
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
            seat.stopCursorAnimation();
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

// Constraints and relative motion --------------------------------------------

/// Makes the seat's pointer follow a window's constraint request: drops
/// the old constraint and makes the new one.
pub fn applyConstraint(seat: *Seat, w: *Wayland.Window) void {
    const b = seat.backend;
    const o = w.constraint;
    seat.dropConstraint(w.id, true);
    const p = seat.pointer orelse return;
    if ((o.relative or o.kind != .none) and seat.relative == null) if (b.relative_manager) |m| {
        const r = m.getRelativePointer(p) catch return b.queue.fail(error.OutOfMemory);
        r.setListener(*Seat, onRelative, seat);
        seat.relative = r;
    };
    if (o.kind == .none) return;
    const manager = b.pointer_constraints orelse return;
    const region = if (o.region) |r| blk: {
        const reg = b.compositor.?.createRegion() catch return b.queue.fail(error.OutOfMemory);
        reg.add(r.x, r.y, r.width, r.height);
        break :blk reg;
    } else null;
    defer if (region) |r| r.destroy();
    const c = b.allocator.create(Constraint) catch return b.queue.fail(error.OutOfMemory);
    c.* = .{ .seat = seat, .window = w.id, .persistent = o.persistent };
    seat.constraints.append(b.allocator, c) catch {
        b.allocator.destroy(c);
        return b.queue.fail(error.OutOfMemory);
    };
    const lifetime: zwp.PointerConstraintsV1.Lifetime = if (o.persistent) .persistent else .oneshot;
    switch (o.kind) {
        .none => unreachable,
        .lock => {
            const l = manager.lockPointer(w.surface, p, region, lifetime) catch return b.queue.fail(error.OutOfMemory);
            l.setListener(*Constraint, onLocked, c);
            c.locked = l;
        },
        .confine => {
            const cf = manager.confinePointer(w.surface, p, region, lifetime) catch return b.queue.fail(error.OutOfMemory);
            cf.setListener(*Constraint, onConfined, c);
            c.confined = cf;
        },
    }
}

/// Destroys a window's constraint, reporting it inactive if it was
/// active and `report` is set.
fn dropConstraint(seat: *Seat, window: WindowId, report: bool) void {
    for (seat.constraints.items, 0..) |c, i| if (c.window == window) {
        if (c.locked) |l| l.destroy();
        if (c.confined) |cf| cf.destroy();
        if (report and c.active) seat.push(.{ .pointer_constraint = .{ .window = window, .seat = seat.id, .active = false, .ended = true } });
        seat.backend.allocator.destroy(c);
        _ = seat.constraints.swapRemove(i);
        return;
    };
}

fn constraintChanged(c: *Constraint, active: bool) void {
    const seat = c.seat;
    c.active = active;
    seat.push(.{ .pointer_constraint = .{ .window = c.window, .seat = seat.id, .active = active, .ended = !active and !c.persistent } });
    // A one-shot constraint is dead once deactivated.
    if (!active and !c.persistent) seat.dropConstraint(c.window, false);
}

fn onLocked(_: *zwp.LockedPointerV1, event: zwp.LockedPointerV1.Event, c: *Constraint) void {
    constraintChanged(c, event == .locked);
}

fn onConfined(_: *zwp.ConfinedPointerV1, event: zwp.ConfinedPointerV1.Event, c: *Constraint) void {
    constraintChanged(c, event == .confined);
}

fn onRelative(_: *zwp.RelativePointerV1, event: zwp.RelativePointerV1.Event, seat: *Seat) void {
    const m = switch (event) {
        .relative_motion => |m| m,
    };
    const id = seat.pointer_focus orelse return;
    const w = seat.backend.windows.items[id] orelse return;
    // Only windows that asked for it.
    if (!w.constraint.relative and w.constraint.kind == .none) return;
    seat.push(.{ .relative_motion = .{
        .window = id,
        .seat = seat.id,
        .dx = m.dx.toDouble(),
        .dy = m.dy.toDouble(),
        .dx_unaccel = m.dx_unaccel.toDouble(),
        .dy_unaccel = m.dy_unaccel.toDouble(),
        .time_us = @as(u64, m.utime_hi) << 32 | m.utime_lo,
    } });
}

// Shortcut inhibition -------------------------------------------------------

/// Makes or destroys the seat's inhibitor for a window.
pub fn applyInhibitor(seat: *Seat, w: *Wayland.Window) void {
    const b = seat.backend;
    for (seat.inhibitors.items, 0..) |inh, i| if (inh.window == w.id) {
        if (w.inhibit_shortcuts) return;
        inh.proxy.destroy();
        b.allocator.destroy(inh);
        _ = seat.inhibitors.swapRemove(i);
        seat.push(.{ .shortcuts_inhibit = .{ .window = w.id, .seat = seat.id, .active = false } });
        return;
    };
    if (!w.inhibit_shortcuts) return;
    const m = b.shortcuts_manager orelse return;
    const inh = b.allocator.create(Inhibitor) catch return b.queue.fail(error.OutOfMemory);
    inh.* = .{ .seat = seat, .window = w.id, .proxy = m.inhibitShortcuts(w.surface, seat.proxy) catch {
        b.allocator.destroy(inh);
        return b.queue.fail(error.OutOfMemory);
    } };
    seat.inhibitors.append(b.allocator, inh) catch {
        inh.proxy.destroy();
        b.allocator.destroy(inh);
        return b.queue.fail(error.OutOfMemory);
    };
    inh.proxy.setListener(*Inhibitor, onInhibitor, inh);
}

fn onInhibitor(_: *zwp.KeyboardShortcutsInhibitorV1, event: zwp.KeyboardShortcutsInhibitorV1.Event, inh: *Inhibitor) void {
    inh.seat.push(.{ .shortcuts_inhibit = .{ .window = inh.window, .seat = inh.seat.id, .active = event == .active } });
}

// Gestures ------------------------------------------------------------------

/// Gets the pointer's gesture objects once both the pointer and the
/// manager exist.
pub fn addGestures(seat: *Seat) void {
    const m = seat.backend.gestures orelse return;
    const p = seat.pointer orelse return;
    if (seat.swipe != null) return;
    const fail = struct {
        fn f(s: *Seat) void {
            s.backend.queue.fail(error.OutOfMemory);
        }
    }.f;
    const swipe = m.getSwipeGesture(p) catch return fail(seat);
    swipe.setListener(*Seat, onSwipe, seat);
    seat.swipe = swipe;
    const pinch = m.getPinchGesture(p) catch return fail(seat);
    pinch.setListener(*Seat, onPinch, seat);
    seat.pinch = pinch;
    if (m.getVersion() >= 3) {
        const hold = m.getHoldGesture(p) catch return fail(seat);
        hold.setListener(*Seat, onHold, seat);
        seat.hold = hold;
    }
}

fn removeGestures(seat: *Seat) void {
    // Gesture objects have a destructor request from version 2.
    if (seat.swipe) |g| if (g.getVersion() >= 2) g.destroy() else @as(*wl.Proxy, @ptrCast(g)).destroy();
    if (seat.pinch) |g| if (g.getVersion() >= 2) g.destroy() else @as(*wl.Proxy, @ptrCast(g)).destroy();
    if (seat.hold) |g| g.destroy();
    seat.swipe = null;
    seat.pinch = null;
    seat.hold = null;
    // A gesture in progress ends with its device.
    for (seat.gesture_window, 0..) |w, i| if (w) |window| seat.push(.{ .gesture = .{
        .window = window,
        .seat = seat.id,
        .kind = @enumFromInt(i),
        .phase = .end,
        .cancelled = true,
    } });
    seat.gesture_window = @splat(null);
}

fn beginGesture(seat: *Seat, kind: platform.GestureKind, surface: ?*wl.Surface, fingers: u32, time: u32, serial: u32) void {
    const window = Wayland.windowOf(surface) orelse return;
    seat.gesture_window[@intFromEnum(kind)] = window;
    seat.gesture_fingers[@intFromEnum(kind)] = fingers;
    seat.push(.{ .gesture = .{ .window = window, .seat = seat.id, .kind = kind, .phase = .begin, .fingers = fingers, .time = time, .serial = serial } });
}

fn gestureEvent(seat: *Seat, kind: platform.GestureKind, phase: platform.GesturePhase) ?platform.Gesture {
    const window = seat.gesture_window[@intFromEnum(kind)] orelse return null;
    if (phase == .end) seat.gesture_window[@intFromEnum(kind)] = null;
    return .{ .window = window, .seat = seat.id, .kind = kind, .phase = phase, .fingers = seat.gesture_fingers[@intFromEnum(kind)] };
}

/// Public for tests: sway cannot inject gestures on its headless backend.
pub fn onSwipe(_: *zwp.PointerGestureSwipeV1, event: zwp.PointerGestureSwipeV1.Event, seat: *Seat) void {
    switch (event) {
        .begin => |b| seat.beginGesture(.swipe, b.surface, b.fingers, b.time, b.serial),
        .update => |u| if (seat.gestureEvent(.swipe, .update)) |g| {
            var ev = g;
            ev.time = u.time;
            ev.dx = u.dx.toDouble();
            ev.dy = u.dy.toDouble();
            seat.push(.{ .gesture = ev });
        },
        .end => |e| if (seat.gestureEvent(.swipe, .end)) |g| {
            var ev = g;
            ev.time = e.time;
            ev.serial = e.serial;
            ev.cancelled = e.cancelled != 0;
            seat.push(.{ .gesture = ev });
        },
    }
}

pub fn onPinch(_: *zwp.PointerGesturePinchV1, event: zwp.PointerGesturePinchV1.Event, seat: *Seat) void {
    switch (event) {
        .begin => |b| seat.beginGesture(.pinch, b.surface, b.fingers, b.time, b.serial),
        .update => |u| if (seat.gestureEvent(.pinch, .update)) |g| {
            var ev = g;
            ev.time = u.time;
            ev.dx = u.dx.toDouble();
            ev.dy = u.dy.toDouble();
            ev.scale = u.scale.toDouble();
            ev.rotation = u.rotation.toDouble();
            seat.push(.{ .gesture = ev });
        },
        .end => |e| if (seat.gestureEvent(.pinch, .end)) |g| {
            var ev = g;
            ev.time = e.time;
            ev.serial = e.serial;
            ev.cancelled = e.cancelled != 0;
            seat.push(.{ .gesture = ev });
        },
    }
}

pub fn onHold(_: *zwp.PointerGestureHoldV1, event: zwp.PointerGestureHoldV1.Event, seat: *Seat) void {
    switch (event) {
        .begin => |b| seat.beginGesture(.hold, b.surface, b.fingers, b.time, b.serial),
        .end => |e| if (seat.gestureEvent(.hold, .end)) |g| {
            var ev = g;
            ev.time = e.time;
            ev.serial = e.serial;
            ev.cancelled = e.cancelled != 0;
            seat.push(.{ .gesture = ev });
        },
    }
}

// Cursors -------------------------------------------------------------------

/// Gets the pointer's cursor-shape device once both exist.
pub fn addShapeDevice(seat: *Seat) void {
    if (seat.shape_device != null) return;
    const m = seat.backend.cursor_shape_manager orelse return;
    const p = seat.pointer orelse return;
    seat.shape_device = m.getPointer(p) catch return seat.backend.queue.fail(error.OutOfMemory);
}

/// Shows the cursor of the window under the pointer.
pub fn applyCursor(seat: *Seat) void {
    const b = seat.backend;
    const p = seat.pointer orelse return;
    const id = seat.pointer_focus orelse return;
    if (id >= b.windows.items.len) return;
    const w = b.windows.items[id] orelse return;
    seat.stopCursorAnimation();
    const shape = w.cursor;
    if (shape == .hidden) return p.setCursor(seat.enter_serial, null, 0, 0);
    if (seat.shape_device) |d| {
        const s = if (d.getVersion() >= 2) shape else cursor.v1Shape(shape);
        return d.setShape(seat.enter_serial, @enumFromInt(@intFromEnum(s)));
    }
    // Themed: images of the theme's size times the window's scale.
    const theme = &b.cursor_theme;
    const px: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(theme.size)) * w.state.scale.toFloat()));
    const loaded = theme.get(b.shm.?, shape, px) orelse theme.get(b.shm.?, .default, px) orelse return;
    seat.showFrame(loaded, 0);
    if (loaded.frames.len > 1) {
        seat.cursor_anim = loaded;
        seat.scheduleCursorFrame();
    }
}

fn showFrame(seat: *Seat, loaded: *cursor.Loaded, index: usize) void {
    const b = seat.backend;
    const p = seat.pointer orelse return;
    const surface = seat.cursor_surface orelse blk: {
        const s = b.compositor.?.createSurface() catch return b.queue.fail(error.OutOfMemory);
        seat.cursor_surface = s;
        if (b.viewporter) |v| seat.cursor_viewport = v.getViewport(s) catch null;
        break :blk s;
    };
    const f = loaded.frames[index];
    // Images of the nominal size show at the theme's logical size.
    const size: f64 = @floatFromInt(b.cursor_theme.size);
    const nominal: f64 = @floatFromInt(@max(loaded.nominal, 1));
    var hx: i32 = undefined;
    var hy: i32 = undefined;
    if (seat.cursor_viewport) |v| {
        const k = size / nominal;
        v.setDestination(@max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(f.width)) * k)))), @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(f.height)) * k)))));
        hx = @intFromFloat(@round(@as(f64, @floatFromInt(f.xhot)) * k));
        hy = @intFromFloat(@round(@as(f64, @floatFromInt(f.yhot)) * k));
    } else {
        const scale: i32 = @max(1, @as(i32, @intFromFloat(@round(nominal / size))));
        if (surface.getVersion() >= 3) surface.setBufferScale(scale);
        hx = @divTrunc(@as(i32, @intCast(f.xhot)), scale);
        hy = @divTrunc(@as(i32, @intCast(f.yhot)), scale);
    }
    p.setCursor(seat.enter_serial, surface, hx, hy);
    surface.attach(f.buffer, 0, 0);
    if (surface.getVersion() >= 4) surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32)) else surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    surface.commit();
    seat.cursor_frame = index;
}

fn scheduleCursorFrame(seat: *Seat) void {
    const l = seat.cursor_anim orelse return;
    const delay: u64 = @max(l.frames[seat.cursor_frame].delay, 10);
    seat.backend.loop.startTimer(&seat.cursor_timer, Loop.now() + delay * std.time.ns_per_ms, 0) catch {};
}

fn onCursorFrame(timer: *Timer) void {
    const seat: *Seat = @fieldParentPtr("cursor_timer", timer);
    const l = seat.cursor_anim orelse return;
    seat.showFrame(l, (seat.cursor_frame + 1) % l.frames.len);
    seat.scheduleCursorFrame();
}

pub fn stopCursorAnimation(seat: *Seat) void {
    seat.cursor_anim = null;
    seat.backend.loop.cancelTimer(&seat.cursor_timer);
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
