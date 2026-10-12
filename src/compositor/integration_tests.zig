//! The compositor thread against sway running headless (`zig build
//! test-integration`): real wl_shm presentation, configure acks that
//! follow content, and timing from wp_presentation feedback while the UI
//! thread is stalled; and the same through a Vulkan swapchain on lavapipe
//! in MAILBOX and FIFO present modes (D10, D12). Print the measurements
//! with SIV_MEASURE=1.

const std = @import("std");
const testing = std.testing;
const scene = @import("scene");
const platform = @import("platform");
const loop_mod = @import("loop");
const Sway = platform.test_sway.Sway;
const VirtualPointer = platform.test_sway.VirtualPointer;
const update = @import("update.zig");
const Compositor = @import("Compositor.zig");
const pool = @import("pool");

const Loop = loop_mod.Loop;
const Event = update.Event;
const WindowId = platform.WindowId;

fn sleepNs(ns: u64) void {
    var ts: std.c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = std.c.nanosleep(&ts, null);
}

fn spinNs(ns: u64) void {
    const end = Loop.now() + ns;
    var x: u64 = 0;
    while (Loop.now() < end) x +%= 1;
    std.mem.doNotOptimizeAway(x);
}

fn measuring() bool {
    return testing.environ.getPosix("SIV_MEASURE") != null;
}

/// sway, a UI loop, and a threaded compositor on sway's display. The UI
/// answers every configure by laying out a full-window scroll view.
const Harness = struct {
    sway: Sway = .{},
    loop: Loop = undefined,
    comp: *Compositor = undefined,
    events: std.ArrayList(Event) = .empty,
    builders: [16]scene.Builder = undefined,
    free: std.ArrayList(*scene.Builder) = .empty,
    seq: u64 = 0,
    size: platform.Size = .{},
    /// Windows whose layers exist.
    setup_done: [4]bool = @splat(false),
    workers: pool.Pool = undefined,
    renderer: Compositor.Renderer = .cpu,
    vulkan: Compositor.VulkanOptions = .{},

    fn start(h: *Harness) !void {
        try h.sway.start();
        errdefer h.sway.stop();
        h.loop = try Loop.init(testing.allocator);
        h.workers = pool.Pool.init(testing.allocator, 3);
        for (&h.builders) |*b| {
            b.* = .init(testing.allocator);
            try h.free.append(testing.allocator, b);
        }
        h.comp = try Compositor.create(.{
            .allocator = testing.allocator,
            .executor = h.workers.executor(),
            .ui_loop = &h.loop,
            .sink = .{ .ctx = h, .func = onEvent },
            .backend = .{ .wayland = .{ .display = h.sway.display } },
            .renderer = h.renderer,
            .vulkan = h.vulkan,
        });
    }

    fn stop(h: *Harness) void {
        h.comp.destroy();
        h.workers.deinit();
        h.loop.deinit();
        for (&h.builders) |*b| b.deinit();
        h.free.deinit(testing.allocator);
        h.events.deinit(testing.allocator);
        h.sway.stop();
    }

    fn onEvent(ctx: ?*anyopaque, ev: *const Event) void {
        const h: *Harness = @ptrCast(@alignCast(ctx));
        h.events.append(testing.allocator, ev.*) catch unreachable;
        switch (ev.*) {
            .released => |b| h.free.append(testing.allocator, b) catch unreachable,
            .configure => |c| h.layout(c.window, c.state, c.serial) catch |err| std.debug.panic("layout: {t}", .{err}),
            .platform => |p| if (p == .failed) std.debug.panic("platform failed: {t}", .{p.failed}),
            else => {},
        }
    }

    /// A background and a scroll container over the whole window, with
    /// striped content ten windows tall.
    fn layout(h: *Harness, id: WindowId, state: platform.WindowState, serial: u64) !void {
        const w: f32 = @floatFromInt(state.width);
        const ht: f32 = @floatFromInt(state.height);
        const bg = h.free.pop().?;
        bg.reset();
        try bg.fillRect(.xywh(0, 0, w, ht), .color(.white));
        const card = h.free.pop().?;
        card.reset();
        try card.fillRoundedRect(.xywh(0, 0, 120, 120), .uniform(16, 16), .color(.srgb8(0xf5, 0x9e, 0x0b, 0xff)));
        const tall = h.free.pop().?;
        tall.reset();
        var y: f32 = 0;
        var i: u8 = 0;
        while (y < ht * 10) : ({
            y += 40;
            i +%= 1;
        }) try tall.fillRect(.xywh(0, y, w, 20), .color(.srgb8(i *% 7, 0x40, 0x90, 0xff)));
        const first = !h.setup_done[id];
        h.setup_done[id] = true;
        h.size = .{ .width = state.width, .height = state.height };
        const setup = [_]update.Op{
            .{ .create = 1 },
            .{ .create = 2 },
            .{ .create = 3 },
            .{ .set_root = 1 },
            .{ .insert = .{ .layer = 2, .parent = 1 } },
            .{ .insert = .{ .layer = 3, .parent = 2 } },
            .{ .create = 4 },
            .{ .insert = .{ .layer = 4, .parent = 1 } },
        };
        const ops = [_]update.Op{
            .{ .set_content = .{ .layer = 1, .content = .{ .list = try bg.finish(0), .builder = bg } } },
            .{ .set_scroll = .{ .layer = 2, .scroll = .{ .viewport = .xywh(0, 0, w, ht), .content = .{ .width = w, .height = ht * 10 } } } },
            .{ .set_content = .{ .layer = 3, .content = .{ .list = try tall.finish(0), .builder = tall } } },
            .{ .set_content = .{ .layer = 4, .content = .{ .list = try card.finish(0), .builder = card } } },
            .{ .ack_configure = serial },
        };
        if (first) _ = try h.comp.commit(id, &setup);
        h.seq = try h.comp.commit(id, &ops);
    }

    fn presentedSeq(h: *const Harness) u64 {
        var i = h.events.items.len;
        while (i > 0) {
            i -= 1;
            if (h.events.items[i] == .presented) return h.events.items[i].presented.seq;
        }
        return 0;
    }

    /// Dispatches until everything committed so far was presented.
    fn settle(h: *Harness) !void {
        const deadline = Loop.now() + 5 * std.time.ns_per_s;
        while (h.seq == 0 or h.presentedSeq() < h.seq) {
            if (Loop.now() > deadline) return error.Timeout;
            try h.loop.dispatch(10);
        }
    }
};

/// Reads presentation state on the compositor thread.
const Probe = struct {
    window: WindowId,
    frames: u64 = 0,
    predicted: u64 = 0,
    /// From wp_presentation feedback.
    presented: ?u64 = null,
    refresh: u64 = 0,
    offset: f32 = 0,
    acked: bool = false,
    buffer: platform.Size = .{},
    state: platform.WindowState = .{},
    presenter: ?std.meta.Tag(@import("surface.zig").Surface) = null,
    /// Presented minus predicted time of the latest frame with feedback.
    error_ns: ?i64 = null,
    callback_pending: bool = false,

    fn f(ctx: ?*anyopaque, c: *Compositor) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        const s = c.frameStats(p.window).?;
        p.frames = s.frames;
        p.predicted = s.last();
        p.offset = if (c.scrollOffset(p.window, 2)) |o| o.y else 0;
        const w = c.platform.wayland.get(p.window);
        p.presented = w.clock.last_present_ns;
        p.refresh = w.clock.refresh_ns;
        p.acked = w.ack_serial == null;
        p.state = w.state;
        p.presenter = c.presenter(p.window);
        p.error_ns = w.clock.last_error_ns;
        p.callback_pending = w.frame_callback != null;
        const cpu = w.swapchain.slots;
        for (cpu) |slot| if (slot) |b| {
            p.buffer = .{ .width = b.width, .height = b.height };
        };
    }

    fn read(comp: *Compositor, window: WindowId) !Probe {
        var p: Probe = .{ .window = window };
        try comp.call(&p, f);
        return p;
    }
};

test "windows map with content laid out for their configured size" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    const id = try h.comp.createWindow(.{ .width = 300, .height = 200 });
    try h.settle();
    // Sway tiles the only window over the 1280x720 output. Every size it
    // configured was presented with the UI's layout for it.
    const deadline = Loop.now() + 5 * std.time.ns_per_s;
    while (h.size.width != 1280) {
        if (Loop.now() > deadline) return error.Timeout;
        try h.loop.dispatch(10);
    }
    try h.settle();
    const p = try Probe.read(h.comp, id);
    try testing.expect(p.acked);
    try testing.expectEqual(platform.Size{ .width = 1280, .height = 720 }, p.buffer);
    try testing.expectEqual(@as(u32, 1280), p.state.width);

    // A second window: sway splits the output; both relayout and present.
    const second = try h.comp.createWindow(.{});
    try h.settle();
    const deadline2 = Loop.now() + 5 * std.time.ns_per_s;
    while (true) {
        const a = try Probe.read(h.comp, id);
        const b = try Probe.read(h.comp, second);
        if (a.acked and b.acked and a.buffer.width == 640 and b.buffer.width == 640) break;
        if (Loop.now() > deadline2) return error.Timeout;
        try h.loop.dispatch(10);
    }
    try h.comp.destroyWindow(second);
    try h.settle();
}

test "scrolling and animation stay smooth on sway while the UI thread is stalled" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    const id = try h.comp.createWindow(.{ .app_id = "siv-smooth" });
    const tiled = Loop.now() + 5 * std.time.ns_per_s;
    while (h.size.width != 1280) {
        if (Loop.now() > tiled) return error.Timeout;
        try h.loop.dispatch(10);
    }
    try h.settle();
    // Warm up presentation feedback.
    _ = try h.comp.commit(id, &.{.{ .animate = .{ .layer = 2, .animation = .{ .to = .{ .scroll = .{ .x = 0, .y = 50 } }, .duration_ns = 200 * std.time.ns_per_ms } } }});
    try h.settle();
    sleepNs(300 * std.time.ns_per_ms);

    // Wheel input from a virtual pointer while the UI thread sleeps: a
    // helper thread sends it and watches presentation feedback.
    var vp = try VirtualPointer.connect(&h.sway);
    defer vp.deinit();
    vp.moveTo(640, 360);
    try vp.sync();
    const Wheel = struct {
        fn run(comp: *Compositor, window: WindowId, pointer: *VirtualPointer, out: *[10]u64, err: *?anyerror) void {
            measure(comp, window, pointer, out) catch |e| {
                err.* = e;
            };
        }

        fn measure(comp: *Compositor, window: WindowId, pointer: *VirtualPointer, out: *[10]u64) !void {
            var prng = std.Random.DefaultPrng.init(3);
            for (out) |*sample| {
                sleepNs(20 * std.time.ns_per_ms + prng.random().uintLessThan(u64, 17 * std.time.ns_per_ms));
                const before = try Probe.read(comp, window);
                const t0 = Loop.now();
                pointer.wheel(15, 1);
                try pointer.sync();
                const limit = Loop.now() + std.time.ns_per_s;
                // The first frame showing the scroll, then the first
                // presentation feedback after it. (Sway's headless output
                // stamps presentations when it repaints, which can precede
                // the predicted vblank, so match by order, not by time.)
                var shown_frame = false;
                while (true) {
                    if (Loop.now() > limit) return error.Timeout;
                    sleepNs(250 * std.time.ns_per_us);
                    const p = try Probe.read(comp, window);
                    if (!shown_frame and p.offset != before.offset and p.frames > before.frames) shown_frame = true;
                    if (!shown_frame) continue;
                    const shown = p.presented orelse continue;
                    if (shown > t0 and shown != before.presented) {
                        sample.* = shown - t0;
                        break;
                    }
                }
            }
        }
    };
    var wheel: [10]u64 = undefined;
    var err: ?anyerror = null;
    const helper = try std.Thread.spawn(.{}, Wheel.run, .{ h.comp, id, &vp, &wheel, &err });
    sleepNs(1200 * std.time.ns_per_ms); // the stalled UI thread
    helper.join();
    if (err) |e| {
        std.debug.print("wheel measurement failed: {t}\n", .{e});
        return e;
    }
    std.mem.sort(u64, &wheel, {}, std.sort.asc(u64));
    const refresh = (try Probe.read(h.comp, id)).refresh;

    if (measuring()) std.debug.print("sway: wheel to photon (feedback), stalled UI: min {d:.2} ms, median {d:.2} ms, max {d:.2} ms; refresh {d:.2} ms\n", .{
        @as(f64, @floatFromInt(wheel[0])) / 1e6,
        @as(f64, @floatFromInt(wheel[wheel.len / 2])) / 1e6,
        @as(f64, @floatFromInt(wheel[wheel.len - 1])) / 1e6,
        @as(f64, @floatFromInt(refresh)) / 1e6,
    });
    try testing.expect(wheel[wheel.len / 2] <= 2 * refresh + 2 * std.time.ns_per_ms);

    // A small card sliding: compositor scheduling, cheap to render.
    const slide = try droppedDuringStall(&h, id, refresh, .{ .layer = 4, .animation = .{
        .to = .{ .transform = .offset(1000, 300) },
        .duration_ns = anim_ns,
        .easing = .linear,
    } });
    // The whole window scrolling: a full 1280x720 redraw per frame, which
    // unoptimized builds of the CPU renderer cannot always fit in 16 ms.
    const scroll = try droppedDuringStall(&h, id, refresh, .{ .layer = 2, .animation = .{
        .to = .{ .scroll = .{ .x = 0, .y = 3000 } },
        .duration_ns = anim_ns,
        .easing = .linear,
    } });
    if (measuring()) {
        std.debug.print("sway: 500 ms animations, UI thread spinning: card {d} presentations, {d} dropped; full-window scroll {d} presentations, {d} dropped\n", .{ slide.presentations, slide.dropped, scroll.presentations, scroll.dropped });
    }
    try testing.expect(slide.presentations >= anim_ns / refresh - 3);
    try testing.expectEqual(@as(usize, 0), slide.dropped);
    if (@import("builtin").mode != .debug) try testing.expectEqual(@as(usize, 0), scroll.dropped);
}

const anim_ns = 500 * std.time.ns_per_ms;

/// Runs `op` (an animation of `anim_ns`) while this thread, the UI
/// thread, spins; a helper thread records every presentation timestamp
/// from feedback. Each whole extra refresh between two is a dropped frame.
fn droppedDuringStall(h: *Harness, id: WindowId, refresh: u64, op: @FieldType(update.Op, "animate")) !struct { presentations: usize, dropped: usize } {
    const Watch = struct {
        stop: std.atomic.Value(bool) = .init(false),
        times: [256]u64 = undefined,
        len: usize = 0,
        fn run(w: *@This(), comp: *Compositor, window: WindowId) void {
            var last: u64 = 0;
            while (!w.stop.load(.acquire) and w.len < w.times.len) {
                sleepNs(1 * std.time.ns_per_ms);
                const p = Probe.read(comp, window) catch return;
                const t = p.presented orelse continue;
                if (t != last) {
                    w.times[w.len] = t;
                    w.len += 1;
                    last = t;
                }
            }
        }
    };
    var watch: Watch = .{};
    _ = try h.comp.commit(id, &.{.{ .animate = op }});
    try h.settle();
    const start = Loop.now();
    const watcher = try std.Thread.spawn(.{}, Watch.run, .{ &watch, h.comp, id });
    spinNs(anim_ns);
    watch.stop.store(true, .release);
    watcher.join();
    // The first timestamp read may predate the animation.
    var first: usize = 0;
    while (first < watch.len and watch.times[first] < start) first += 1;
    const times = watch.times[first..watch.len];
    var dropped: usize = 0;
    if (times.len > 1) for (times[1..], times[0 .. times.len - 1]) |b, a| {
        dropped += @intCast((b - a + refresh / 2) / refresh - 1);
    };
    // Let the animation finish before the next one.
    sleepNs(50 * std.time.ns_per_ms);
    try h.loop.dispatch(0);
    return .{ .presentations = times.len, .dropped = dropped };
}

// Vulkan presentation (D10, D12) ----------------------------------------------

/// A harness presenting through a Vulkan swapchain on lavapipe; skipped
/// without a Vulkan Wayland device.
fn startVulkan(h: *Harness, mode: @import("render_vulkan").Swapchain.PresentMode) !WindowId {
    h.renderer = .vulkan;
    h.vulkan = .{ .present_mode = mode, .validation = true };
    try h.start();
    errdefer h.stop();
    // lavapipe renders on the CPU, as does sway's headless output and
    // Mesa's software WSI (a copy into wl_shm per frame); a smaller output
    // keeps the frame clock, not their cost, the subject.
    try h.sway.command("output HEADLESS-1 mode 640x360@60Hz");
    const id = try h.comp.createWindow(.{ .app_id = "siv-vulkan" });
    const tiled = Loop.now() + 10 * std.time.ns_per_s;
    while (h.size.width != 640) {
        if (Loop.now() > tiled) return error.Timeout;
        try h.loop.dispatch(10);
    }
    try h.settle();
    // The window starts on the CPU renderer and switches once the device,
    // created on a thread of its own, is ready.
    const ready = Loop.now() + 10 * std.time.ns_per_s;
    while ((try Probe.read(h.comp, id)).presenter != .vulkan) {
        if (Loop.now() > ready) return error.SkipZigTest;
        _ = try h.comp.commit(id, &.{.{ .animate = .{ .layer = 4, .animation = .{ .to = .{ .transform = .offset(1, 1) }, .duration_ns = 20 * std.time.ns_per_ms } } }});
        try h.loop.dispatch(20);
    }
    try h.settle();
    return id;
}

/// Runs a 500 ms card animation and checks it is paced by the frame clock
/// with presentation feedback: one presentation per refresh, none dropped,
/// predictions within a refresh of the feedback.
fn checkPacing(h: *Harness, id: WindowId, label: []const u8) !void {
    // Warm up presentation feedback.
    _ = try h.comp.commit(id, &.{.{ .animate = .{ .layer = 4, .animation = .{ .to = .{ .transform = .offset(10, 10) }, .duration_ns = 200 * std.time.ns_per_ms } } }});
    try h.settle();
    sleepNs(300 * std.time.ns_per_ms);
    try h.loop.dispatch(0);
    const refresh = (try Probe.read(h.comp, id)).refresh;
    const before = try Probe.read(h.comp, id);
    const r = try droppedDuringStall(h, id, refresh, .{ .layer = 4, .animation = .{
        .to = .{ .transform = .offset(1000, 300) },
        .duration_ns = anim_ns,
        .easing = .linear,
    } });
    const after = try Probe.read(h.comp, id);
    const frames = after.frames - before.frames;
    if (measuring()) std.debug.print("sway, Vulkan {s}: 500 ms animation, UI thread spinning: {d} frames rendered, {d} presentations, {d} dropped, last prediction error {d:.2} ms, refresh {d:.2} ms\n", .{
        label,                                                  frames,                                 r.presentations, r.dropped,
        @as(f64, @floatFromInt(after.error_ns orelse 0)) / 1e6, @as(f64, @floatFromInt(refresh)) / 1e6,
    });
    try testing.expect(r.presentations >= anim_ns / refresh - 3);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    // Frames follow the frame clock: no more than one per refresh.
    try testing.expect(frames <= anim_ns / refresh + 4);
    const err = after.error_ns orelse return error.NoFeedback;
    try testing.expect(@abs(err) <= @as(i64, @intCast(refresh)));
}

test "Vulkan windows present on sway in MAILBOX mode, paced by the frame clock" {
    var h: Harness = .{};
    const id = try startVulkan(&h, .auto);
    defer h.stop();
    try checkPacing(&h, id, "MAILBOX");

    // Device loss (here marked, as VK_ERROR_DEVICE_LOST would): the window
    // falls back to the CPU renderer and wl_shm and keeps presenting, and
    // new windows use the CPU renderer.
    const Lose = struct {
        fn f(_: ?*anyopaque, c: *Compositor) void {
            c.vulkan.?.note(error.DeviceLost) catch {};
        }
    };
    try h.comp.call(null, Lose.f);
    const before = (try Probe.read(h.comp, id)).frames;
    const deadline = Loop.now() + 3 * std.time.ns_per_s;
    while (true) {
        const p = try Probe.read(h.comp, id);
        if (p.presenter == .cpu and p.frames > before + 2) break;
        if (Loop.now() > deadline) return error.Timeout;
        _ = try h.comp.commit(id, &.{.{ .animate = .{ .layer = 4, .animation = .{ .to = .{ .transform = .offset(30, 30) }, .duration_ns = 100 * std.time.ns_per_ms } } }});
        try h.loop.dispatch(20);
    }
    try h.settle();
    const second = try h.comp.createWindow(.{});
    try h.settle();
    try testing.expectEqual(@as(?std.meta.Tag(@import("surface.zig").Surface), .cpu), (try Probe.read(h.comp, second)).presenter);
}

test "Vulkan FIFO: frame clock and presentation feedback stay correct, hidden windows never block" {
    var h: Harness = .{};
    const id = try startVulkan(&h, .fifo);
    defer h.stop();
    try checkPacing(&h, id, "FIFO");

    // Hide the window (another workspace gets the output, so sway stops
    // its frame callbacks), then toggle fullscreen twice: the window keeps
    // its size (it fills the output either way), so the swapchain is kept,
    // and each configure forces a frame. The configure that hiding sends
    // presents and leaves a frame callback that never comes; Mesa 22.3's
    // FIFO would block the next present in vkQueuePresentKHR until the
    // window is shown again. The compositor thread must keep answering and
    // acknowledge both configures.
    try h.sway.command("workspace 2");
    sleepNs(200 * std.time.ns_per_ms);
    try h.loop.dispatch(0);
    for ([_]bool{ true, false }, [_][]const u8{ "[app_id=siv-vulkan] fullscreen enable", "[app_id=siv-vulkan] fullscreen disable" }) |fullscreen, cmd| {
        try h.sway.command(cmd);
        const Ping = struct {
            done: std.atomic.Value(bool) = .init(false),
            fn run(p: *@This(), comp: *Compositor, window: WindowId) void {
                for (0..20) |_| {
                    _ = Probe.read(comp, window) catch return;
                    sleepNs(10 * std.time.ns_per_ms);
                }
                p.done.store(true, .release);
            }
        };
        var ping: Ping = .{};
        const t = try std.Thread.spawn(.{}, Ping.run, .{ &ping, h.comp, id });
        const limit = Loop.now() + 3 * std.time.ns_per_s;
        while (!ping.done.load(.acquire) and Loop.now() < limit) try h.loop.dispatch(10);
        const responsive = ping.done.load(.acquire);
        // Unblock a stuck compositor thread so the test can end.
        if (!responsive) try h.sway.command("workspace 1");
        t.join();
        try testing.expect(responsive);
        const deadline = Loop.now() + 3 * std.time.ns_per_s;
        while (true) {
            const p = try Probe.read(h.comp, id);
            if (p.acked and p.state.states.fullscreen == fullscreen and p.callback_pending) break;
            if (Loop.now() > deadline) return error.Timeout;
            try h.loop.dispatch(10);
        }
    }
    // Shown again, it presents through Vulkan.
    const shown = (try Probe.read(h.comp, id)).frames;
    try h.sway.command("workspace 1");
    const deadline2 = Loop.now() + 3 * std.time.ns_per_s;
    while (true) {
        const p = try Probe.read(h.comp, id);
        if (p.frames > shown and p.presenter == .vulkan) break;
        if (Loop.now() > deadline2) return error.Timeout;
        _ = try h.comp.commit(id, &.{.{ .animate = .{ .layer = 4, .animation = .{ .to = .{ .transform = .offset(20, 20) }, .duration_ns = 50 * std.time.ns_per_ms } } }});
        try h.loop.dispatch(20);
    }
    try h.settle();
}
