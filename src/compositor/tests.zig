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
