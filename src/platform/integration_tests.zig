//! Integration tests: the Wayland backend against sway running headless
//! (`zig build test-integration`). They are left out of `zig build test`,
//! which stays hermetic.

const std = @import("std");
const testing = std.testing;
const wl = @import("wayland").client.wl;
const platform = @import("platform.zig");
const Loop = platform.Loop;
const Wayland = @import("Wayland.zig");
const Seat = @import("Seat.zig");
const Sway = @import("test_sway.zig").Sway;
const VirtualPointer = @import("test_sway.zig").VirtualPointer;
const Size = platform.Size;
const Scale = platform.Scale;
const WindowId = platform.WindowId;

const TestApp = struct {
    backend: *Wayland = undefined,
    events: std.ArrayList(platform.Event) = .empty,
    frames: usize = 0,
    frame_times: std.ArrayList(u64) = .empty,
    /// The frame clock's state when each frame began.
    frame_basis: std.ArrayList(struct { begin: u64, last_present: ?u64, refresh: u64, last_error: ?i64 }) = .empty,
    last_buffer: Size = .{},
    frames_of: [4]usize = @splat(0),
    buffer_of: [4]Size = @splat(.{}),
    /// The window conditions passed to `runUntil` look at.
    watch: WindowId = 0,
    animate: bool = false,
    closed: bool = false,
    /// Defer configures instead of answering them with a buffer.
    hold_configures: bool = false,
    deferred: usize = 0,
    refused: usize = 0,

    fn deinit(app: *TestApp) void {
        app.events.deinit(testing.allocator);
        app.frame_times.deinit(testing.allocator);
        app.frame_basis.deinit(testing.allocator);
    }

    fn sink(app: *TestApp) platform.Sink {
        return .{ .ctx = app, .func = onEvent };
    }

    fn onEvent(ctx: ?*anyopaque, ev: *const platform.Event) void {
        const app: *TestApp = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .frame => |f| {
                app.frames += 1;
                app.frames_of[f.window] += 1;
                app.frame_times.append(testing.allocator, f.time.present_ns) catch unreachable;
                const clock = app.backend.get(f.window).clock;
                app.frame_basis.append(testing.allocator, .{
                    .begin = Loop.now(),
                    .last_present = clock.last_present_ns,
                    .refresh = clock.refresh_ns,
                    .last_error = clock.last_error_ns,
                }) catch unreachable;
                if (app.hold_configures and app.backend.get(f.window).ack_serial != null) {
                    if (app.backend.deferConfigure(f.window)) app.deferred += 1 else app.refused += 1;
                    app.events.append(testing.allocator, ev.*) catch unreachable;
                    return;
                }
                const buf = app.backend.acquireBuffer(f.window) catch |err| std.debug.panic("acquire: {t}", .{err});
                @memset(std.mem.bytesAsSlice(u32, buf.pixels), 0xff2266aa);
                app.last_buffer = .{ .width = buf.width, .height = buf.height };
                app.buffer_of[f.window] = app.last_buffer;
                app.backend.present(f.window, buf, null);
                if (app.animate) app.backend.requestFrame(f.window);
            },
            .close_requested => |id| {
                app.closed = true;
                app.backend.destroyWindow(id);
            },
            .failed => |err| std.debug.panic("platform failed: {t}", .{err}),
            else => {},
        }
        app.events.append(testing.allocator, ev.*) catch unreachable;
    }

    fn count(app: *const TestApp, tag: std.meta.Tag(platform.Event)) usize {
        var n: usize = 0;
        for (app.events.items) |e| n += @intFromBool(e == tag);
        return n;
    }

    fn last(app: *const TestApp, tag: std.meta.Tag(platform.Event)) ?platform.Event {
        var i = app.events.items.len;
        while (i > 0) {
            i -= 1;
            if (app.events.items[i] == tag) return app.events.items[i];
        }
        return null;
    }

    fn watched(app: *const TestApp) *Wayland.Window {
        return app.backend.get(app.watch);
    }
};

fn runUntil(loop: *Loop, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    return runFor(loop, ctx, cond, 5);
}

fn runFor(loop: *Loop, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool, seconds: u64) !void {
    const deadline = Loop.now() + seconds * std.time.ns_per_s;
    while (!cond(ctx)) {
        if (Loop.now() > deadline) return error.Timeout;
        try loop.dispatch(50);
    }
}

/// Dispatches for `ms` milliseconds.
fn runMs(loop: *Loop, ms: u64) !void {
    const deadline = Loop.now() + ms * std.time.ns_per_ms;
    while (Loop.now() < deadline) try loop.dispatch(10);
}

const Harness = struct {
    sway: Sway = .{},
    loop: Loop = undefined,
    app: TestApp = .{},

    fn start(h: *Harness) !void {
        try h.sway.start();
        errdefer h.sway.stop();
        h.loop = try Loop.init(testing.allocator);
        errdefer h.loop.deinit();
        h.app.backend = try Wayland.create(&h.loop, testing.allocator, h.app.sink(), .{ .display = h.sway.display });
    }

    fn stop(h: *Harness) void {
        h.app.backend.destroy();
        h.loop.deinit();
        h.app.deinit();
        h.sway.stop();
    }

    /// Creates a window and waits until its first frame was presented.
    fn mapWindow(h: *Harness, options: platform.WindowOptions) !WindowId {
        const id = try h.app.backend.createWindow(options);
        h.app.watch = id;
        try runUntil(&h.loop, &h.app, struct {
            fn f(a: *TestApp) bool {
                return a.frames_of[a.watch] >= 1;
            }
        }.f);
        return id;
    }

    /// Animates the watched window until it has produced `n` more frames.
    fn animate(h: *Harness, n: usize) !void {
        const app = &h.app;
        const S = struct {
            var target: usize = 0;
            fn f(a: *TestApp) bool {
                return a.frames_of[a.watch] >= target;
            }
        };
        S.target = app.frames_of[app.watch] + n;
        app.animate = true;
        app.backend.requestFrame(app.watch);
        try runUntil(&h.loop, app, S.f);
        app.animate = false;
    }
};

test "configure, server-side decorations, frame clock, close" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    const app = &h.app;
    const backend = app.backend;

    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.count(.output_added) >= 1;
        }
    }.f);
    const out = backend.output(app.last(.output_added).?.output_added).?;
    try testing.expectEqualStrings("HEADLESS-1", out.name.slice());
    try testing.expectEqual(@as(i32, 1280), out.width);
    try testing.expectEqual(@as(i32, 60000), out.refresh_mhz);

    const id = try h.mapWindow(.{ .decoration = .server });
    // The first configure lets the client choose (640x480 by default); once
    // mapped, sway tiles the only window over the whole output.
    try testing.expectEqual(@as(u32, 640), app.last(.configure).?.configure.state.width);
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.last_buffer.width == 1280;
        }
    }.f);
    const state = backend.windowState(id);
    try testing.expectEqual(@as(u32, 1280), state.width);
    try testing.expectEqual(@as(u32, 720), state.height);
    try testing.expectEqual(platform.Decoration.server, state.decoration);
    try testing.expect(state.states.activated);
    try testing.expectEqual(Size{ .width = 1280, .height = 720 }, app.last_buffer);

    // wlroots' headless output presents on a 60 Hz timer and reports it;
    // frames are predicted from that feedback.
    try h.animate(20);
    const clock = &backend.get(id).clock;
    const last = clock.last_present_ns.?;
    const now = Loop.now();
    try testing.expect(last <= now + std.time.ns_per_ms and now - last < 200 * std.time.ns_per_ms);
    try testing.expect(clock.refresh_ns > 16 * std.time.ns_per_ms and clock.refresh_ns < 17 * std.time.ns_per_ms);
    try expectPredictionsFromFeedback(app, 10);

    try h.sway.command("kill");
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.closed;
        }
    }.f);
}

fn expectPredictionsFromFeedback(app: *const TestApp, min: usize) !void {
    var predicted_from_feedback: usize = 0;
    for (app.frame_times.items, app.frame_basis.items) |t, basis| {
        const last_present = basis.last_present orelse continue;
        try testing.expect(t > basis.begin);
        try testing.expectEqual(@as(u64, 0), (t - last_present) % basis.refresh);
        try testing.expect(t - basis.begin <= basis.refresh);
        predicted_from_feedback += 1;
    }
    try testing.expect(predicted_from_feedback >= min);
}

test "fractional scale with viewporter, and preferred buffer scale" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    const app = &h.app;
    const backend = app.backend;

    // One window with fractional-scale-v1, and one without it so that it
    // follows wl_surface.preferred_buffer_scale (wl_compositor v6).
    const fractional = try h.mapWindow(.{});
    try testing.expect(backend.get(fractional).fractional != null);
    const manager = backend.fractional_manager;
    backend.fractional_manager = null;
    const integer = h.mapWindow(.{});
    backend.fractional_manager = manager;
    const int_id = try integer;
    try testing.expect(backend.get(int_id).fractional == null);

    try h.sway.command("output HEADLESS-1 scale 1.5");
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            const w0 = a.backend.get(0);
            const w1 = a.backend.get(1);
            return w0.state.scale.v120 == 180 and w1.state.scale.v120 == 240 and
                a.buffer_of[0].width == w0.state.bufferWidth() and a.buffer_of[1].width == w1.state.bufferWidth();
        }
    }.f);
    const f_state = backend.windowState(fractional);
    const i_state = backend.windowState(int_id);
    // Sway tiles the two windows side by side on a 1280/1.5 logical output.
    try testing.expectEqual(@as(u32, 853), f_state.width + i_state.width);
    try testing.expectEqual(Scale.apply(.{ .v120 = 180 }, f_state.width), app.buffer_of[fractional].width);
    try testing.expectEqual(2 * i_state.width, app.buffer_of[int_id].width);
    // The fractional window draws 1:1 into a viewport; the other one uses a
    // buffer scale of 2 and lets the compositor downscale.
    try testing.expectEqual(Size{ .width = f_state.width, .height = f_state.height }, backend.get(fractional).applied_destination);
    try testing.expectEqual(@as(i32, 1), backend.get(fractional).applied_buffer_scale);
    try testing.expectEqual(@as(i32, 2), backend.get(int_id).applied_buffer_scale);
    try testing.expectEqual(@as(i32, 2), backend.get(int_id).preferred_buffer_scale);
}

test "pointer, scrolling, keyboard text and repeat, touch" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    const app = &h.app;
    const id = try h.mapWindow(.{});

    var vp = try VirtualPointer.connect(&h.sway);
    defer vp.deinit();
    // The virtual device gives the seat its pointer capability.
    try vp.sync();
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            const seat = a.backend.seats.items[0] orelse return false;
            return seat.pointer != null;
        }
    }.f);
    vp.moveTo(100, 120);
    vp.button(0x110, true);
    vp.button(0x110, false);
    vp.wheel(15, 1);
    try vp.sync();
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.count(.scroll) >= 1 and a.count(.pointer_button) >= 2;
        }
    }.f);
    const motion = app.last(.pointer_motion) orelse app.last(.pointer_enter).?;
    const pos = switch (motion) {
        .pointer_motion, .pointer_enter => |m| m,
        else => unreachable,
    };
    try testing.expectEqual(id, pos.window);
    try testing.expectEqual(@as(f64, 100), pos.x);
    try testing.expectEqual(@as(f64, 120), pos.y);
    const button = app.last(.pointer_button).?.pointer_button;
    try testing.expectEqual(@as(u32, 0x110), button.button); // BTN_LEFT
    try testing.expect(!button.pressed);
    const scroll = app.last(.scroll).?.scroll;
    try testing.expectEqual(platform.ScrollSource.wheel, scroll.source);
    try testing.expectEqual(@as(i32, 120), scroll.v120_y); // one detent down
    try testing.expectEqual(@as(f64, 15), scroll.dy);
    try testing.expectEqual(@as(f64, 0), scroll.dx);

    // Text through wtype's virtual keyboard and the keymap it uploads, then
    // a key held past the repeat delay (sway: 600 ms at 25 Hz). The first
    // pause lets the seat gain its keyboard before keys arrive.
    const wtype = try h.sway.spawnClient(&[_:null]?[*:0]const u8{ "wtype", "-s", "300", "hé", "-P", "x", "-s", "900", "-p", "x" });
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            const l = a.last(.key) orelse return false;
            return l.key.state == .released and l.key.keysym == 'x';
        }
    }.f);
    try h.sway.wait(wtype);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (app.events.items) |e| if (e == .key and e.key.state == .pressed) try text.appendSlice(testing.allocator, e.key.text());
    try testing.expectEqualStrings("héx", text.items);
    try testing.expect(app.count(.keyboard_enter) >= 1);

    var repeats: usize = 0;
    for (app.events.items) |e| {
        if (e == .key and e.key.state == .repeated) {
            try testing.expectEqualStrings("x", e.key.text());
            repeats += 1;
        }
    }
    // About (900 - 600) ms at 25 Hz; allow for scheduling slack.
    try testing.expect(repeats >= 3 and repeats <= 12);

    // Sway cannot inject touch on its headless backend, so feed wl_touch
    // events for the real surface to the seat's listener. Two contacts in
    // one frame, then a frame with a move, a shape change, and a lift.
    const seat = app.backend.seats.items[0].?;
    const surface = app.backend.get(id).surface;
    const touch: *wl.Touch = @ptrFromInt(0x1000); // the listener ignores it
    const fx = wl.Fixed.fromDouble;
    const before = app.events.items.len;
    Seat.onTouch(touch, .{ .down = .{ .serial = 5, .time = 1, .surface = surface, .id = 7, .x = fx(10), .y = fx(20) } }, seat);
    Seat.onTouch(touch, .{ .down = .{ .serial = 6, .time = 1, .surface = surface, .id = 8, .x = fx(30), .y = fx(40) } }, seat);
    Seat.onTouch(touch, .frame, seat);
    Seat.onTouch(touch, .{ .motion = .{ .time = 2, .id = 7, .x = fx(11), .y = fx(21) } }, seat);
    Seat.onTouch(touch, .{ .shape = .{ .id = 7, .major = fx(6), .minor = fx(4) } }, seat);
    Seat.onTouch(touch, .{ .up = .{ .serial = 9, .time = 2, .id = 8 } }, seat);
    Seat.onTouch(touch, .frame, seat);
    try h.loop.dispatch(0);
    var touch_events: std.ArrayList(platform.Event) = .empty;
    defer touch_events.deinit(testing.allocator);
    for (app.events.items[before..]) |e| switch (e) {
        .touch_down, .touch_motion, .touch_up, .touch_frame, .touch_cancel => try touch_events.append(testing.allocator, e),
        else => {},
    };
    const got = touch_events.items;
    const tags = [_]std.meta.Tag(platform.Event){ .touch_down, .touch_down, .touch_frame, .touch_motion, .touch_up, .touch_frame };
    try testing.expectEqual(tags.len, got.len);
    for (tags, got) |tag, e| try testing.expectEqual(tag, std.meta.activeTag(e));
    try testing.expectEqual(@as(i32, 7), got[0].touch_down.id);
    try testing.expectEqual(id, got[0].touch_down.window);
    try testing.expectEqual(@as(f64, 11), got[3].touch_motion.x);
    try testing.expectEqual(@as(f64, 6), got[3].touch_motion.major);
    try testing.expectEqual(@as(i32, 8), got[4].touch_up.id);
    try testing.expectEqual(@as(f64, 30), got[4].touch_up.x);
}

test "a deferred configure is acked by the next present or after the timeout" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    const app = &h.app;
    const id = try h.mapWindow(.{});
    const w = app.backend.get(id);

    // Floating the window resizes it; the configure stays unanswered.
    app.hold_configures = true;
    try h.sway.command("floating enable, resize set 400 300");
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.deferred >= 1;
        }
    }.f);
    try testing.expect(w.ack_serial != null);
    // The next present acknowledges it, at the new size.
    app.hold_configures = false;
    app.backend.requestFrame(id);
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.watched().ack_serial == null;
        }
    }.f);
    try testing.expectEqual(@as(usize, 0), app.refused);
    try testing.expectEqual(Size{ .width = w.state.bufferWidth(), .height = w.state.bufferHeight() }, app.buffer_of[id]);

    // A resize that is never answered is acknowledged anyway after the
    // timeout, from a forced frame that refuses to defer again.
    app.hold_configures = true;
    const deferred = app.deferred;
    try h.sway.command("resize set 300 200");
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.deferred > 1;
        }
    }.f);
    const start = Loop.now();
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.watched().ack_serial == null;
        }
    }.f);
    try testing.expect(app.deferred > deferred);
    try testing.expectEqual(@as(usize, 1), app.refused);
    try testing.expect(Loop.now() - start < 2 * platform.configure_timeout_ns);
    try testing.expectEqual(@as(u32, 300), w.state.width);
}

test "output hotplug" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    const app = &h.app;
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.count(.output_added) == 1;
        }
    }.f);

    try h.sway.command("create_output");
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.count(.output_added) == 2;
        }
    }.f);
    const added = app.last(.output_added).?.output_added;
    try testing.expectEqualStrings("HEADLESS-2", app.backend.output(added).?.name.slice());

    try h.sway.command("output HEADLESS-2 unplug");
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.count(.output_removed) == 1;
        }
    }.f);
    try testing.expectEqual(added, app.last(.output_removed).?.output_removed);
    try testing.expect(app.backend.output(added) == null);
}

test "popups are placed by the compositor within the output, then dismissed" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    const app = &h.app;
    const backend = app.backend;
    const id = try h.mapWindow(.{});
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.last_buffer.width == 1280;
        }
    }.f);
    // Anchored near the bottom right corner: sway must flip it above the
    // anchor and slide it left to keep it on the output.
    const popup = try backend.createPopup(.{ .parent = id, .positioner = .{
        .width = 200,
        .height = 100,
        .anchor_rect = .{ .x = 1200, .y = 690, .width = 40, .height = 10 },
    } });
    app.watch = popup;
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.frames_of[a.watch] >= 1;
        }
    }.f);
    const st = backend.windowState(popup);
    const pos = st.popup.?;
    try testing.expectEqual(@as(u32, 200), st.width);
    try testing.expectEqual(@as(u32, 100), st.height);
    try testing.expect(pos.y + 100 <= 690);
    try testing.expect(pos.x + 200 <= 1280);
    try testing.expectEqual(Size{ .width = 200, .height = 100 }, app.buffer_of[popup]);
    backend.destroyWindow(popup);
    try runMs(&h.loop, 50);
}

test "a subsurface shows an external frame without protocol errors" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    const app = &h.app;
    const backend = app.backend;
    const id = try h.mapWindow(.{});
    const linux = std.os.linux;
    const fd: i32 = @intCast(linux.memfd_create("siv-ext", linux.MFD.CLOEXEC));
    defer _ = linux.close(fd);
    _ = linux.ftruncate(fd, 64 * 48 * 4);
    const sub = try backend.createSubsurface(id);
    const state: platform.SubsurfaceState = .{
        .visible = true,
        .rect = .{ .x = 20, .y = 30, .width = 128, .height = 96 },
        .frame = .{ .fd = fd, .width = 64, .height = 48, .stride = 64 * 4, .key = 1 },
    };
    try backend.setSubsurface(id, sub, &state);
    backend.commitWindow(id);
    try h.animate(3);
    // Hidden, shown again, then destroyed.
    try backend.setSubsurface(id, sub, &.{});
    backend.commitWindow(id);
    try backend.setSubsurface(id, sub, &state);
    try h.animate(2);
    backend.destroySubsurface(id, sub);
    try h.animate(2);
    try testing.expect(!backend.dead);
    try testing.expectEqual(@as(usize, 0), app.count(.failed));
}
