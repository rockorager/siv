//! Compositor behavior on the headless backend: configure acks, damage and
//! buffer age, content release, animations without UI commits, scroll
//! routing, scale changes, suspension, and teardown. Golden images and
//! latency measurements are in test/compositor/.

const std = @import("std");
const testing = std.testing;
const scene = @import("scene");
const platform = @import("platform");
const pool = @import("pool");
const loop_mod = @import("loop");
const update = @import("update.zig");
const Compositor = @import("Compositor.zig");

const Loop = loop_mod.Loop;
const Event = update.Event;
const Op = update.Op;
const Headless = platform.Headless;

const red = scene.Color.srgb8(0xff, 0, 0, 0xff);
const blue = scene.Color.srgb8(0, 0, 0xff, 0xff);

const Harness = struct {
    loop: Loop = undefined,
    comp: *Compositor = undefined,
    events: std.ArrayList(Event) = .empty,
    builders: [16]scene.Builder = undefined,
    free: std.ArrayList(*scene.Builder) = .empty,

    fn start(h: *Harness, thread: bool) !void {
        h.loop = try Loop.init(testing.allocator);
        for (&h.builders) |*b| {
            b.* = .init(testing.allocator);
            try h.free.append(testing.allocator, b);
        }
        h.comp = try Compositor.create(.{
            .allocator = testing.allocator,
            .executor = .serial,
            .ui_loop = &h.loop,
            .sink = .{ .ctx = h, .func = onEvent },
            .backend = .{ .headless = .{ .refresh_ns = 2 * std.time.ns_per_ms } },
            .thread = thread,
        });
    }

    fn stop(h: *Harness) void {
        h.comp.destroy();
        h.loop.deinit();
        for (&h.builders) |*b| b.deinit();
        h.free.deinit(testing.allocator);
        h.events.deinit(testing.allocator);
    }

    fn onEvent(ctx: ?*anyopaque, ev: *const Event) void {
        const h: *Harness = @ptrCast(@alignCast(ctx));
        if (ev.* == .released) h.free.append(testing.allocator, ev.released) catch unreachable;
        h.events.append(testing.allocator, ev.*) catch unreachable;
    }

    /// Content filling `r` with `color`, from a free builder.
    fn rect(h: *Harness, r: update.Rect, color: scene.Color) !update.Content {
        const b = h.free.pop().?;
        b.reset();
        try b.fillRect(r, .color(color));
        return .{ .list = try b.finish(0), .builder = b };
    }

    fn headless(h: *Harness) *Headless {
        return h.comp.platform.headless;
    }

    fn count(h: *const Harness, tag: std.meta.Tag(Event)) usize {
        var n: usize = 0;
        for (h.events.items) |e| n += @intFromBool(e == tag);
        return n;
    }

    fn last(h: *const Harness, tag: std.meta.Tag(Event)) ?Event {
        var i = h.events.items.len;
        while (i > 0) {
            i -= 1;
            if (h.events.items[i] == tag) return h.events.items[i];
        }
        return null;
    }

    fn run(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        const deadline = Loop.now() + 5 * std.time.ns_per_s;
        while (!cond(ctx)) {
            if (Loop.now() > deadline) return error.Timeout;
            try h.loop.dispatch(5);
        }
    }

    fn runMs(h: *Harness, ms: u64) !void {
        const deadline = Loop.now() + ms * std.time.ns_per_ms;
        while (Loop.now() < deadline) try h.loop.dispatch(1);
    }

    /// Creates a 100x80 window with a white root layer 1 and waits until
    /// it is presented.
    fn window(h: *Harness) !platform.WindowId {
        const id = try h.comp.createWindow(.{ .width = 100, .height = 80 });
        try h.run(h, struct {
            fn f(x: *Harness) bool {
                return x.count(.configure) >= 1;
            }
        }.f);
        const serial = h.last(.configure).?.configure.serial;
        _ = try h.comp.commit(id, &.{
            .{ .create = 1 },
            .{ .set_content = .{ .layer = 1, .content = try h.rect(.xywh(0, 0, 100, 80), .white) } },
            .{ .set_root = 1 },
            .{ .ack_configure = serial },
        });
        try h.run(h, struct {
            fn f(x: *Harness) bool {
                return x.count(.presented) >= 1;
            }
        }.f);
        return id;
    }

    fn pixel(h: *Harness, id: platform.WindowId, x: u32, y: u32) [4]u8 {
        const img = h.headless().presented(id).?;
        return img.pixels[y * img.stride + x * 4 ..][0..4].*;
    }
};

const bgra_red = [4]u8{ 0, 0, 0xff, 0xff };
const bgra_blue = [4]u8{ 0xff, 0, 0, 0xff };
const bgra_white = [4]u8{ 0xff, 0xff, 0xff, 0xff };

test "the first frame waits for the UI's layout and acks with it" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.comp.createWindow(.{ .width = 100, .height = 80 });
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.configure) >= 1;
        }
    }.f);
    const cf = h.last(.configure).?.configure;
    try testing.expectEqual(@as(u64, 1), cf.serial);
    try testing.expectEqual(@as(u32, 100), cf.state.width);
    // Nothing is shown or acknowledged until the UI answers.
    try h.runMs(10);
    try testing.expect(h.headless().presented(id) == null);
    try testing.expect(h.headless().pendingConfigure(id) != null);

    const seq = try h.comp.commit(id, &.{
        .{ .create = 1 },
        .{ .set_content = .{ .layer = 1, .content = try h.rect(.xywh(0, 0, 100, 80), red) } },
        .{ .set_root = 1 },
        .{ .ack_configure = cf.serial },
    });
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.presented) >= 1;
        }
    }.f);
    try testing.expectEqual(seq, h.last(.presented).?.presented.seq);
    const ack = h.headless().lastAck(id).?;
    try testing.expect(ack.with_buffer);
    try testing.expectEqual(bgra_red, h.pixel(id, 50, 40));
}

test "a window's frames wait for its popup's first frame, then show with it" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const parent = try h.window();
    const pop = try h.comp.createPopup(.{ .parent = parent, .positioner = .{ .width = 40, .height = 30, .anchor_rect = .{ .x = 10, .y = 10, .width = 20, .height = 10 } } });
    // The response to the input that opened it, before the popup has drawn.
    const seq = try h.comp.commit(parent, &.{.{ .set_content = .{ .layer = 1, .content = try h.rect(.xywh(0, 0, 100, 80), red) } }});
    try h.runMs(10);
    try testing.expectEqual(bgra_white, h.pixel(parent, 50, 40));
    // The popup's first frame; the parent's goes in the same iteration.
    const cf = h.last(.configure).?.configure;
    try testing.expectEqual(pop, cf.window);
    _ = try h.comp.commit(pop, &.{
        .{ .create = 1 },
        .{ .set_content = .{ .layer = 1, .content = try h.rect(.xywh(0, 0, 40, 30), blue) } },
        .{ .set_root = 1 },
        .{ .ack_configure = cf.serial },
    });
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            var windows: u2 = 0;
            for (x.events.items) |e| if (e == .presented and e.presented.seq > 1) {
                windows |= @as(u2, 1) << @intCast(e.presented.window);
            };
            return windows == 3;
        }
    }.f);
    try testing.expectEqual(bgra_red, h.pixel(parent, 50, 40));
    try testing.expectEqual(bgra_blue, h.pixel(pop, 20, 15));
    // Both presentations carry the same frame time.
    var popup_ns: ?u64 = null;
    var parent_ns: ?u64 = null;
    for (h.events.items) |e| if (e == .presented) {
        if (e.presented.window == pop and popup_ns == null) popup_ns = e.presented.present_ns;
        if (e.presented.window == parent and e.presented.seq == seq) parent_ns = e.presented.present_ns;
    };
    try testing.expectEqual(popup_ns.?, parent_ns.?);

    // A popup that never draws holds its parent only so long.
    const start = Loop.now();
    _ = try h.comp.createPopup(.{ .parent = parent, .positioner = .{ .width = 40, .height = 30, .anchor_rect = .{ .x = 10, .y = 10, .width = 20, .height = 10 } } });
    _ = try h.comp.commit(parent, &.{.{ .set_content = .{ .layer = 1, .content = try h.rect(.xywh(0, 0, 100, 80), blue) } }});
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return std.mem.eql(u8, &x.pixel(0, 50, 40), &bgra_blue);
        }
    }.f);
    try testing.expect(Loop.now() - start >= 40 * std.time.ns_per_ms);
}

test "a resize the UI never answers is shown after the timeout" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    const start = Loop.now();
    h.headless().configure(id, .{ .width = 120, .height = 90 }, null);
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.headless().presented(0).?.width == 120;
        }
    }.f);
    try testing.expect(Loop.now() - start >= update.configure_timeout_ns);
    // The old layout at the new size: white where it reaches, transparent
    // beyond.
    try testing.expectEqual(bgra_white, h.pixel(id, 50, 40));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, h.pixel(id, 110, 85));
}

test "damage covers only what changed, in buffer pixels" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    h.headless().setScale(id, .int(2));
    // A scale change re-renders without the UI.
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.headless().presented(0).?.width == 200 and x.count(.configure) == 2;
        }
    }.f);
    try testing.expectEqual(@as(u32, 200), h.headless().presented(id).?.width);

    _ = try h.comp.commit(id, &.{
        .{ .create = 2 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .set_content = .{ .layer = 2, .content = try h.rect(.xywh(0, 0, 10, 10), blue) } },
        .{ .set_transform = .{ .layer = 2, .transform = .offset(20, 30) } },
    });
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.presented) >= 2;
        }
    }.f);
    try testing.expectEqual(platform.Rect{ .x = 40, .y = 60, .width = 20, .height = 20 }, h.headless().presented(id).?.damage.?);
    try testing.expectEqual(bgra_blue, h.pixel(id, 45, 65));

    // Moving it damages the old and new places; the other buffer, last
    // shown two frames ago, is brought up to date from the framebuffer.
    _ = try h.comp.commit(id, &.{.{ .set_transform = .{ .layer = 2, .transform = .offset(60, 30) } }});
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.presented) >= 3;
        }
    }.f);
    try testing.expectEqual(platform.Rect{ .x = 40, .y = 60, .width = 100, .height = 20 }, h.headless().presented(id).?.damage.?);
    try testing.expectEqual(bgra_white, h.pixel(id, 45, 65));
    try testing.expectEqual(bgra_blue, h.pixel(id, 125, 65));
}

test "replaced and destroyed content is released after its last frame" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    const first = h.free.items.len;
    _ = try h.comp.commit(id, &.{.{ .set_content = .{ .layer = 1, .content = try h.rect(.xywh(0, 0, 100, 80), red) } }});
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.released) >= 1;
        }
    }.f);
    try testing.expectEqual(first, h.free.items.len);
    try testing.expectEqual(bgra_red, h.pixel(id, 1, 1));
    try h.comp.destroyWindow(id);
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.released) >= 2;
        }
    }.f);
    try testing.expectEqual(h.builders.len, h.free.items.len);
}

test "animations run on the compositor and land on frame times" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    _ = try h.comp.commit(id, &.{
        .{ .create = 2 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .set_content = .{ .layer = 2, .content = try h.rect(.xywh(0, 0, 10, 10), blue) } },
        .{ .animate = .{ .layer = 2, .animation = .{
            .id = 5,
            .from = .{ .transform = .offset(0, 0) },
            .to = .{ .transform = .offset(80, 0) },
            .duration_ns = 40 * std.time.ns_per_ms,
            .easing = .linear,
        } } },
    });
    const presented_before = h.count(.presented);
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.animation_finished) >= 1;
        }
    }.f);
    // Only the commit itself was announced; the motion needed no UI.
    try testing.expectEqual(presented_before + 1, h.count(.presented));
    const fin = h.last(.animation_finished).?.animation_finished;
    try testing.expectEqual(@as(u32, 5), fin.id);
    try testing.expectEqual(update.Property.transform, fin.property);
    try testing.expectEqual(bgra_blue, h.pixel(id, 85, 5));
    try testing.expectEqual(bgra_white, h.pixel(id, 5, 5));
}

test "pointer scroll moves containers in the compositor unless the UI wants it" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    _ = try h.comp.commit(id, &.{
        .{ .create = 2 },
        .{ .create = 3 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .insert = .{ .layer = 3, .parent = 2 } },
        .{ .set_scroll = .{ .layer = 2, .scroll = .{ .viewport = .xywh(0, 0, 100, 40), .content = .{ .width = 100, .height = 200 } } } },
        .{ .set_content = .{ .layer = 3, .content = try h.rect(.xywh(0, 40, 100, 160), blue) } },
        .{ .set_wheel_region = .{ .layer = 1, .region = .xywh(0, 40, 100, 40) } },
    });
    const hl = h.headless();
    hl.inject(.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 50, .y = 20 } });
    hl.inject(.{ .scroll = .{ .window = id, .seat = 0, .dy = 30, .source = .wheel } });
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.scrolled) >= 1;
        }
    }.f);
    const s = h.last(.scrolled).?.scrolled;
    try testing.expectEqual(@as(u32, 2), s.layer);
    try testing.expectEqual(@as(f32, 30), s.offset.y);
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.pixel(0, 50, 15)[0] == 0xff and x.pixel(0, 50, 15)[1] == 0;
        }
    }.f);

    var forwarded: usize = 0;
    for (h.events.items) |e| if (e == .platform and e.platform == .scroll) {
        forwarded += 1;
    };
    try testing.expectEqual(@as(usize, 0), forwarded);

    // Ctrl held: the UI gets it. Over the wheel region: the UI gets it.
    hl.inject(.{ .modifiers = .{ .window = id, .seat = 0, .mods = .{ .ctrl = true } } });
    hl.inject(.{ .scroll = .{ .window = id, .seat = 0, .dy = 30, .source = .wheel } });
    hl.inject(.{ .modifiers = .{ .window = id, .seat = 0, .mods = .{} } });
    hl.inject(.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 50, .y = 60 } });
    hl.inject(.{ .scroll = .{ .window = id, .seat = 0, .dy = 30, .source = .wheel } });
    try h.runMs(10);
    forwarded = 0;
    for (h.events.items) |e| if (e == .platform and e.platform == .scroll) {
        forwarded += 1;
    };
    try testing.expectEqual(@as(usize, 2), forwarded);
    try testing.expectEqual(@as(usize, 1), h.count(.scrolled));

    // A touchpad gesture that ends while moving keeps scrolling.
    hl.inject(.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 50, .y = 20 } });
    for (0..5) |i| hl.inject(.{ .scroll = .{ .window = id, .seat = 0, .dy = 8, .time = @intCast(1000 + i * 10), .source = .finger } });
    hl.inject(.{ .scroll = .{ .window = id, .seat = 0, .time = 1050, .source = .finger, .stop_y = true } });
    try h.runMs(100);
    const flung = h.last(.scrolled).?.scrolled.offset.y;
    try testing.expect(flung > 30 + 40 + 20);
}

test "pinches zoom containers in the compositor unless the UI wants them; holds stop flings" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    // A zoomable container over the window with a red stripe at x 40 to 50
    // on blue, and a wheel region on its child's bottom half.
    const b = h.free.pop().?;
    b.reset();
    try b.fillRect(.xywh(0, 0, 100, 80), .color(blue));
    try b.fillRect(.xywh(40, 0, 10, 80), .color(red));
    _ = try h.comp.commit(id, &.{
        .{ .create = 2 },
        .{ .create = 3 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .insert = .{ .layer = 3, .parent = 2 } },
        .{ .set_scroll = .{ .layer = 2, .scroll = .{ .viewport = .xywh(0, 0, 100, 80), .content = .{ .width = 100, .height = 80 }, .max_zoom = 4 } } },
        .{ .set_content = .{ .layer = 3, .content = .{ .list = try b.finish(0), .builder = b } } },
        .{ .set_wheel_region = .{ .layer = 3, .region = .xywh(0, 40, 100, 40) } },
    });
    const hl = h.headless();
    hl.inject(.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 50, .y = 20 } });
    hl.inject(.{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .begin, .fingers = 2 } });
    hl.inject(.{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .update, .fingers = 2, .scale = 2 } });
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            const s = x.last(.scrolled) orelse return false;
            return s.scrolled.zoom == 2;
        }
    }.f);
    // Zoomed about the pointer: the stripe now covers x 30 to 50.
    try testing.expectEqual(update.Point{ .x = 50, .y = 20 }, h.last(.scrolled).?.scrolled.offset);
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return std.mem.eql(u8, &x.pixel(0, 35, 20), &bgra_red);
        }
    }.f);
    // The content follows the fingers: 10 px right.
    hl.inject(.{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .update, .fingers = 2, .scale = 2, .dx = 10 } });
    hl.inject(.{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .end, .fingers = 2 } });
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return std.mem.eql(u8, &x.pixel(0, 55, 20), &bgra_red) and std.mem.eql(u8, &x.pixel(0, 35, 20), &bgra_blue);
        }
    }.f);
    var forwarded: usize = 0;
    for (h.events.items) |e| if (e == .platform and e.platform == .gesture) {
        forwarded += 1;
    };
    try testing.expectEqual(@as(usize, 0), forwarded);

    // Over the wheel region (now from y 60), and with ctrl held, the UI
    // gets the pinch.
    hl.inject(.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 50, .y = 70 } });
    hl.inject(.{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .begin, .fingers = 2 } });
    hl.inject(.{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .update, .fingers = 2, .scale = 3 } });
    hl.inject(.{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .end, .fingers = 2 } });
    hl.inject(.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 50, .y = 20 } });
    hl.inject(.{ .modifiers = .{ .window = id, .seat = 0, .mods = .{ .ctrl = true } } });
    hl.inject(.{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .begin, .fingers = 2 } });
    hl.inject(.{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .end, .fingers = 2 } });
    hl.inject(.{ .modifiers = .{ .window = id, .seat = 0, .mods = .{} } });
    try h.runMs(10);
    forwarded = 0;
    for (h.events.items) |e| if (e == .platform and e.platform == .gesture) {
        forwarded += 1;
    };
    try testing.expectEqual(@as(usize, 5), forwarded);
    try testing.expectEqual(@as(f32, 2), h.last(.scrolled).?.scrolled.zoom);

    // A fling stops when fingers come to rest, and the hold goes on to the
    // UI.
    _ = try h.comp.commit(id, &.{.{ .fling = .{ .layer = 2, .velocity = .{ .x = 0, .y = 300 } } }});
    try h.runMs(10);
    hl.inject(.{ .gesture = .{ .window = id, .seat = 0, .kind = .hold, .phase = .begin, .fingers = 2 } });
    try h.runMs(10);
    const held = h.last(.scrolled).?.scrolled.offset.y;
    try testing.expect(held > 20 and held < 80);
    try h.runMs(50);
    try testing.expectEqual(held, h.last(.scrolled).?.scrolled.offset.y);
    try testing.expect(h.last(.platform).?.platform == .gesture);
}

test "suspended windows render nothing until resumed" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    const hl = h.headless();
    hl.configure(id, null, .{ .suspended = true });
    try h.runMs(5);
    const frames = h.count(.presented);
    _ = try h.comp.commit(id, &.{.{ .animate = .{ .layer = 1, .animation = .{ .to = .{ .opacity = 0 }, .duration_ns = 20 * std.time.ns_per_ms } } }});
    try h.runMs(40);
    try testing.expectEqual(frames, h.count(.presented));
    try testing.expectEqual(@as(usize, 0), h.count(.animation_finished));
    hl.configure(id, null, .{});
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.animation_finished) >= 1;
        }
    }.f);
}

test "on its own thread, the compositor keeps animating while the UI thread is stalled" {
    var h: Harness = .{};
    try h.start(true);
    defer h.stop();
    const id = try h.window();
    _ = try h.comp.commit(id, &.{.{ .animate = .{ .layer = 1, .animation = .{
        .to = .{ .opacity = 0.5 },
        .duration_ns = 60 * std.time.ns_per_ms,
        .easing = .linear,
    } } }});
    // The UI thread does not dispatch at all.
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
    const Probe = struct {
        alpha: u8 = 0,
        fn run(ctx: ?*anyopaque, comp: *Compositor) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            const img = comp.platform.headless.presented(0).?;
            p.alpha = img.pixels[3];
        }
    };
    var probe: Probe = .{};
    try h.comp.call(&probe, Probe.run);
    try testing.expectEqual(@as(u8, 0x80), probe.alpha);
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.animation_finished) >= 1;
        }
    }.f);
}

test "posted closures run on the compositor in order with commits" {
    var h: Harness = .{};
    try h.start(true);
    defer h.stop();
    const id = try h.window();
    const Title = struct {
        fn set(ctx: ?*anyopaque, comp: *Compositor) void {
            const t: *const []const u8 = @ptrCast(@alignCast(ctx));
            comp.platform.setTitle(0, t.*);
        }
        fn read(ctx: ?*anyopaque, comp: *Compositor) void {
            const out: *[]const u8 = @ptrCast(@alignCast(ctx));
            out.* = comp.platform.headless.title(0);
        }
    };
    var first: []const u8 = "first";
    var second: []const u8 = "second";
    try h.comp.post(@ptrCast(&first), Title.set, null);
    _ = try h.comp.commit(id, &.{.{ .set_opacity = .{ .layer = 1, .opacity = 0.5 } }});
    try h.comp.post(@ptrCast(&second), Title.set, null);
    var got: []const u8 = "";
    try h.comp.call(@ptrCast(&got), Title.read);
    try testing.expectEqualStrings("second", got);
}

test "a frame request with nothing new presents nothing" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    try h.runMs(10);
    const frames = h.comp.frameStats(id).?.frames;
    const ui_frames = h.count(.frame);
    // The UI asks for a frame and commits nothing, then an empty commit.
    try h.comp.requestFrame(id);
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.frame) >= 1;
        }
    }.f);
    try testing.expect(h.count(.frame) > ui_frames);
    const seq = try h.comp.commit(id, &.{.{ .set_opacity = .{ .layer = 1, .opacity = 1 } }});
    try h.runMs(20);
    try testing.expectEqual(frames, h.comp.frameStats(id).?.frames);
    // The empty commit still counts as presented: it is on screen already.
    try testing.expect(h.last(.presented).?.presented.seq >= seq);
    // A real change presents.
    _ = try h.comp.commit(id, &.{.{ .set_opacity = .{ .layer = 1, .opacity = 0.5 } }});
    try h.runMs(20);
    try testing.expectEqual(frames + 1, h.comp.frameStats(id).?.frames);
}

test "discrete wheel steps without a distance scroll like Wayland wheels" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    _ = try h.comp.commit(id, &.{
        .{ .create = 2 },
        .{ .create = 3 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .insert = .{ .layer = 3, .parent = 2 } },
        .{ .set_scroll = .{ .layer = 2, .scroll = .{ .viewport = .xywh(0, 0, 100, 40), .content = .{ .width = 100, .height = 200 } } } },
        .{ .set_content = .{ .layer = 3, .content = try h.rect(.xywh(0, 0, 100, 200), blue) } },
    });
    const hl = h.headless();
    hl.inject(.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 50, .y = 20 } });
    hl.inject(.{ .scroll = .{ .window = id, .seat = 0, .v120_y = 240, .source = .wheel } });
    try h.run(&h, struct {
        fn f(x: *Harness) bool {
            return x.count(.scrolled) >= 1;
        }
    }.f);
    try testing.expectEqual(@as(f32, 2 * platform.Scroll.detent_px), h.last(.scrolled).?.scrolled.offset.y);
}

/// A memfd holding an opaque w x h frame of one BGRX color.
fn memfdFrame(w: u32, h: u32, bgrx: [4]u8, key: u64) !update.ExternalFrame {
    const linux = std.os.linux;
    const fd: i32 = @intCast(linux.memfd_create("siv-test-frame", linux.MFD.CLOEXEC));
    const size = w * h * 4;
    _ = linux.ftruncate(fd, size);
    const pixels = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(pixels);
    for (0..w * h) |i| pixels[i * 4 ..][0..4].* = bgrx;
    _ = linux.pwrite(fd, pixels.ptr, size, 0);
    return .{ .fd = fd, .width = w, .height = h, .stride = w * 4, .key = key };
}

test "external content: a subsurface when unobstructed, composited otherwise" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    const ext = try h.comp.createExternal(id);
    const red_frame = try memfdFrame(40, 30, .{ 0, 0, 0xff, 0 }, 1);
    defer _ = std.os.linux.close(red_frame.fd);
    try h.comp.setExternalFrame(id, ext, red_frame);
    _ = try h.comp.commit(id, &.{
        .{ .create = 2 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .set_transform = .{ .layer = 2, .transform = .offset(10, 10) } },
        .{ .set_external = .{ .layer = 2, .external = .{ .id = ext, .rect = .xywh(0, 0, 40, 30) } } },
    });
    try h.runMs(20);
    const hl = h.headless();
    // Promoted: on a subsurface at its place, not in the window's pixels.
    var subs = hl.subsurfaces(id);
    try testing.expectEqual(@as(usize, 1), subs.len);
    try testing.expect(subs[0].?.visible);
    try testing.expectEqual(platform.Rect{ .x = 10, .y = 10, .width = 40, .height = 30 }, subs[0].?.rect);
    try testing.expectEqual(bgra_white, h.pixel(id, 20, 20));

    // A new frame changes only the subsurface: no present, a bare commit.
    const frames = h.comp.frameStats(id).?.frames;
    const bare = hl.bareCommits(id);
    const blue_frame = try memfdFrame(40, 30, .{ 0xff, 0, 0, 0 }, 2);
    defer _ = std.os.linux.close(blue_frame.fd);
    try h.comp.setExternalFrame(id, ext, blue_frame);
    try h.runMs(20);
    subs = hl.subsurfaces(id);
    try testing.expectEqual(@as(u64, 2), subs[0].?.frame.?.key);
    try testing.expectEqual(frames, h.comp.frameStats(id).?.frames);
    try testing.expect(hl.bareCommits(id) > bare);
    // The replaced frame was released.
    var released = false;
    for (h.events.items) |e| if (e == .external_released and e.external_released.key == 1) {
        released = true;
    };
    try testing.expect(released);

    // Something drawn over part of it (video controls): the subsurface
    // goes below the window, which is transparent over it except for the
    // overlay.
    _ = try h.comp.commit(id, &.{
        .{ .create = 3 },
        .{ .insert = .{ .layer = 3, .parent = 1 } },
        .{ .set_content = .{ .layer = 3, .content = try h.rect(.xywh(40, 30, 20, 20), red) } },
    });
    try h.runMs(20);
    subs = hl.subsurfaces(id);
    try testing.expect(subs[0].?.visible and subs[0].?.below);
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, h.pixel(id, 20, 20));
    try testing.expectEqual(bgra_red, h.pixel(id, 45, 35));
    try testing.expectEqual(bgra_white, h.pixel(id, 5, 5));

    // Cropped by a rectangular clip: the viewport shows the visible part.
    _ = try h.comp.commit(id, &.{
        .{ .destroy = 3 },
        .{ .set_clip = .{ .layer = 2, .clip = .{ .rect = .xywh(0, 0, 20, 30) } } },
    });
    try h.runMs(20);
    subs = hl.subsurfaces(id);
    try testing.expect(subs[0].?.visible and !subs[0].?.below);
    try testing.expectEqual(platform.Rect{ .x = 10, .y = 10, .width = 20, .height = 30 }, subs[0].?.rect);
    try testing.expectEqual(@as(f32, 20), subs[0].?.source.?.width);
    try testing.expectEqual(@as(f32, 30), subs[0].?.source.?.height);
    // A rounded clip cannot be cropped that way: composited.
    _ = try h.comp.commit(id, &.{.{ .set_clip = .{ .layer = 2, .clip = .{ .rect = .xywh(0, 0, 40, 30), .radii = .uniform(8, 8) } } }});
    try h.runMs(20);
    try testing.expect(!hl.subsurfaces(id)[0].?.visible);
    try testing.expectEqual(bgra_blue, h.pixel(id, 20, 20));
    _ = try h.comp.commit(id, &.{.{ .set_clip = .{ .layer = 2, .clip = null } }});

    // Translucent: composited.
    _ = try h.comp.commit(id, &.{.{ .set_opacity = .{ .layer = 2, .opacity = 0.5 } }});
    try h.runMs(20);
    try testing.expect(!hl.subsurfaces(id)[0].?.visible);
    const px = h.pixel(id, 20, 20);
    try testing.expect(px[0] > 0x80 and px[2] > 0x80 and px[1] > 0x80); // blue over white
    // Opaque again: back on the subsurface.
    _ = try h.comp.commit(id, &.{.{ .set_opacity = .{ .layer = 2, .opacity = 1 } }});
    try h.runMs(20);
    try testing.expect(hl.subsurfaces(id)[0].?.visible);
    try testing.expectEqual(bgra_white, h.pixel(id, 20, 20));
}

fn wasReleased(h: *const Harness, key: u64) bool {
    for (h.events.items) |e| if (e == .external_released and e.external_released.key == key) return true;
    return false;
}

/// `memfdFrame` described as a dma-buf (a memfd maps like a linear one).
fn dmabufFrame(w: u32, ht: u32, bgrx: [4]u8, key: u64, modifier: u64) !update.ExternalFrame {
    var f = try memfdFrame(w, ht, bgrx, key);
    f.dmabuf = .{ .format = scene.Dmabuf.xrgb8888, .modifier = modifier, .plane_count = 1 };
    return f;
}

test "external dma-buf frames: promoted when the compositor takes them, read or rejected otherwise" {
    var h: Harness = .{};
    try h.start(false);
    defer h.stop();
    const id = try h.window();
    const hl = h.headless();
    const ext = try h.comp.createExternal(id);
    // No dma-buf formats yet: composited, and a linear XRGB8888 dma-buf is
    // read through a mapping like shared memory.
    const red_frame = try dmabufFrame(40, 30, .{ 0, 0, 0xff, 0 }, 1, scene.Dmabuf.modifier_linear);
    defer _ = std.os.linux.close(red_frame.fd);
    try h.comp.setExternalFrame(id, ext, red_frame);
    _ = try h.comp.commit(id, &.{
        .{ .create = 2 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .set_transform = .{ .layer = 2, .transform = .offset(10, 10) } },
        .{ .set_external = .{ .layer = 2, .external = .{ .id = ext, .rect = .xywh(0, 0, 40, 30) } } },
    });
    try h.runMs(20);
    try testing.expectEqual(@as(usize, 0), hl.subsurfaces(id).len);
    try testing.expectEqual(bgra_red, h.pixel(id, 20, 20));

    // A tiled one cannot be read without Vulkan: not drawn, still released.
    const tiled = try dmabufFrame(40, 30, .{ 0xff, 0, 0, 0 }, 2, 0x0100000000000001); // I915_FORMAT_MOD_X_TILED
    defer _ = std.os.linux.close(tiled.fd);
    try h.comp.setExternalFrame(id, ext, tiled);
    try h.runMs(20);
    try testing.expectEqual(bgra_white, h.pixel(id, 20, 20));
    try testing.expect(wasReleased(&h, 1));

    // The compositor takes linear XRGB8888: promoted, as a dma-buf.
    try hl.addDmabufFormat(scene.Dmabuf.xrgb8888, scene.Dmabuf.modifier_linear);
    const green_frame = try dmabufFrame(40, 30, .{ 0, 0xff, 0, 0 }, 3, scene.Dmabuf.modifier_linear);
    defer _ = std.os.linux.close(green_frame.fd);
    try h.comp.setExternalFrame(id, ext, green_frame);
    try h.runMs(20);
    var subs = hl.subsurfaces(id);
    try testing.expect(subs[0].?.visible);
    try testing.expectEqual(@as(u64, 3), subs[0].?.frame.?.key);
    try testing.expect(subs[0].?.frame.?.dmabuf != null);
    try testing.expect(wasReleased(&h, 2));

    // A frame whose writes are still pending (a pipe stands in for a
    // dma-buf with unsignaled fences) is not shown until they are done.
    var pipe: [2]i32 = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.SkipZigTest;
    defer _ = std.os.linux.close(pipe[0]);
    defer _ = std.os.linux.close(pipe[1]);
    var busy: update.ExternalFrame = .{ .fd = pipe[0], .width = 40, .height = 30, .stride = 160, .key = 4 };
    busy.dmabuf = .{ .format = scene.Dmabuf.xrgb8888, .modifier = scene.Dmabuf.modifier_linear, .plane_count = 1 };
    try h.comp.setExternalFrame(id, ext, busy);
    try h.runMs(40);
    try testing.expectEqual(@as(u64, 3), hl.subsurfaces(id)[0].?.frame.?.key);
    try testing.expect(!wasReleased(&h, 3));
    _ = std.os.linux.write(pipe[1], "x", 1);
    try h.runMs(40);
    subs = hl.subsurfaces(id);
    try testing.expectEqual(@as(u64, 4), subs[0].?.frame.?.key);
    // The promoted frame it replaced goes back once the compositor let go
    // of it.
    try testing.expect(wasReleased(&h, 3));
    try h.comp.destroyExternal(id, ext);
    try h.runMs(20);
    try testing.expect(wasReleased(&h, 4));
}
