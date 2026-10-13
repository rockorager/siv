//! The compositor thread against sway running headless (`zig build
//! test-integration`): real wl_shm presentation, configure acks that
//! follow content, and timing from wp_presentation feedback while the UI
//! thread is stalled; the same through a Vulkan swapchain in MAILBOX and
//! FIFO present modes (D10, D12); and dma-buf external frames (D17), which
//! need sway on a GPU (SIV_SWAY_RENDERER=vulkan) and /dev/udmabuf, and for
//! fence gating vgem. Print the measurements with SIV_MEASURE=1.
//!
//! Tests named "pacing: ..." assert here only what siv controls: each
//! frame handed off within a refresh of becoming due, no more than one
//! frame per refresh, presentation feedback recorded, device loss and
//! hidden windows handled. Dropped frames, wheel-to-photon latency, and
//! prediction error are end to end: on lavapipe and sway's pixman
//! renderer every frame is CPU work that other processes delay whatever
//! siv does. `zig build bench-pacing`, for a quiet machine or real
//! hardware, prints them and checks them against D12's thresholds.

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

/// Whether this is `zig build bench-pacing`.
const bench = @import("integration").bench;
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
    clock: platform.FrameClock = .{},

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
        p.clock = w.clock;
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
    if (bench) return error.SkipZigTest;
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

test "pacing: scrolling and animation stay smooth on sway while the UI thread is stalled" {
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

    const refresh = (try Probe.read(h.comp, id)).refresh;
    if (bench) {
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
        std.debug.print("sway: wheel to photon (feedback), stalled UI: min {d:.2} ms, median {d:.2} ms, max {d:.2} ms; refresh {d:.2} ms\n", .{
            @as(f64, @floatFromInt(wheel[0])) / 1e6,
            @as(f64, @floatFromInt(wheel[wheel.len / 2])) / 1e6,
            @as(f64, @floatFromInt(wheel[wheel.len - 1])) / 1e6,
            @as(f64, @floatFromInt(refresh)) / 1e6,
        });
        try testing.expect(wheel[wheel.len / 2] <= 2 * refresh + 2 * std.time.ns_per_ms);
    }

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
    if (bench or measuring()) {
        std.debug.print("sway: 500 ms animations, UI thread spinning: card {d} frames, {d} presentations, {d} dropped, handed off at most {d:.2} ms after due; full-window scroll {d} frames, {d} presentations, {d} dropped, at most {d:.2} ms\n", .{
            slide.frames,  slide.presentations,  slide.dropped,  @as(f64, @floatFromInt(slide.max_latency_ns)) / 1e6,
            scroll.frames, scroll.presentations, scroll.dropped, @as(f64, @floatFromInt(scroll.max_latency_ns)) / 1e6,
        });
    }
    // siv's: the compositor thread animates while the UI thread spins, no
    // more than one frame per refresh, each handed off within a refresh
    // (Debug builds of the CPU renderer take most of a refresh here).
    for ([_]Pacing{ slide, scroll }) |r| {
        try testing.expect(r.frames > 0);
        try testing.expect(r.frames <= anim_ns / refresh + 4);
    }
    if (@import("builtin").mode != .debug) try testing.expectEqual(@as(usize, 0), slide.late_handoffs);
    if (bench) {
        try testing.expect(slide.presentations >= anim_ns / refresh - 3);
        try testing.expectEqual(@as(usize, 0), slide.dropped);
        if (@import("builtin").mode != .debug) try testing.expectEqual(@as(usize, 0), scroll.dropped);
    }
}

const anim_ns = 500 * std.time.ns_per_ms;

/// Runs `op` (an animation of `anim_ns`) while this thread, the UI
/// thread, spins, and reads the frame clock's record of the window's
/// presentations (from feedback) and hand-offs during it.
fn droppedDuringStall(h: *Harness, id: WindowId, refresh: u64, op: @FieldType(update.Op, "animate")) !Pacing {
    _ = try h.comp.commit(id, &.{.{ .animate = op }});
    try h.settle();
    const before = try Probe.read(h.comp, id);
    const start = Loop.now();
    spinNs(anim_ns);
    const end = Loop.now();
    const after = try Probe.read(h.comp, id);
    // Let the animation finish before the next one.
    sleepNs(50 * std.time.ns_per_ms);
    try h.loop.dispatch(0);
    var r: Pacing = .measure(after.clock, refresh, start, end);
    r.frames = after.frames - before.frames;
    return r;
}

const Pacing = struct {
    /// Frames rendered during the animation.
    frames: u64 = 0,
    presentations: usize = 0,
    /// Refreshes without a presentation between two presentations.
    dropped: usize = 0,
    /// Frames siv took more than a refresh to hand off once due (its
    /// frame callback, or its start): siv's own budget (D12). Shorter
    /// is no proof of a met deadline (the compositor's callback may come
    /// late), which is why dropped frames are counted too.
    late_handoffs: usize = 0,
    /// The longest any frame took.
    max_latency_ns: u64 = 0,

    fn measure(clock: platform.FrameClock, refresh: u64, start: u64, end: u64) Pacing {
        const n = platform.FrameClock.history_len;
        var r: Pacing = .{};
        var prev: ?u64 = null;
        var i = clock.presents_count -| n;
        while (i < clock.presents_count) : (i += 1) {
            const t = clock.presents[i % n];
            if (t < start or t > end) continue;
            r.presentations += 1;
            if (prev) |a| r.dropped += @intCast((t - a + refresh / 2) / refresh - 1);
            prev = t;
        }
        i = clock.handoffs_count -| n;
        while (i < clock.handoffs_count) : (i += 1) {
            const ho = clock.handoffs[i % n];
            if (ho.due_ns < start or ho.at_ns > end) continue;
            const latency = ho.at_ns - ho.due_ns;
            r.max_latency_ns = @max(r.max_latency_ns, latency);
            if (latency > refresh) r.late_handoffs += 1;
        }
        return r;
    }
};

// Vulkan presentation (D10, D12) ----------------------------------------------

/// A harness presenting through a Vulkan swapchain on lavapipe; skipped
/// without a Vulkan Wayland device.
fn startVulkan(h: *Harness, mode: @import("render_vulkan").Swapchain.PresentMode) !WindowId {
    h.renderer = .vulkan;
    h.vulkan = .{ .present_mode = mode, .validation = true, .retry_ns = 200 * std.time.ns_per_ms, .pipeline_cache = .none };
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
/// with presentation feedback: hand-offs within a refresh, no more than
/// one frame per refresh; for bench-pacing also one presentation per
/// refresh, none dropped, predictions within a refresh of the feedback.
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
    if (bench or measuring()) std.debug.print("sway, Vulkan {s}: 500 ms animation, UI thread spinning: {d} frames rendered, {d} presentations, {d} dropped, frames handed off at most {d:.2} ms after due, last prediction error {d:.2} ms, refresh {d:.2} ms\n", .{
        label,                                           frames,                                                 r.presentations,                        r.dropped,
        @as(f64, @floatFromInt(r.max_latency_ns)) / 1e6, @as(f64, @floatFromInt(after.error_ns orelse 0)) / 1e6, @as(f64, @floatFromInt(refresh)) / 1e6,
    });
    // siv's: every frame handed off within a refresh of becoming due, no
    // more than one per refresh, and presentation feedback reaching the
    // frame clock.
    try testing.expectEqual(@as(usize, 0), r.late_handoffs);
    try testing.expect(frames <= anim_ns / refresh + 4);
    const err = after.error_ns orelse return error.NoFeedback;
    // End to end, on a quiet machine: lavapipe and sway kept up too, and
    // the predictions matched the feedback.
    if (bench) {
        try testing.expect(r.presentations >= anim_ns / refresh - 3);
        try testing.expectEqual(@as(usize, 0), r.dropped);
        try testing.expect(@abs(err) <= @as(i64, @intCast(refresh)));
    }
}

test "pacing: Vulkan windows present on sway in MAILBOX mode, paced by the frame clock" {
    var h: Harness = .{};
    const id = try startVulkan(&h, .auto);
    defer h.stop();
    try checkPacing(&h, id, "MAILBOX");

    // Device loss (here marked, as VK_ERROR_DEVICE_LOST would): the window
    // falls back to the CPU renderer and wl_shm and keeps presenting; the
    // device is re-created after the backoff and the window switches back.
    const Lose = struct {
        fn f(_: ?*anyopaque, c: *Compositor) void {
            c.vulkan.?.note(error.DeviceLost) catch {};
        }
    };
    // The device's warning is expected.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
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
    const back = Loop.now() + 5 * std.time.ns_per_s;
    while ((try Probe.read(h.comp, id)).presenter != .vulkan) {
        if (Loop.now() > back) return error.Timeout;
        _ = try h.comp.commit(id, &.{.{ .animate = .{ .layer = 4, .animation = .{ .to = .{ .transform = .offset(40, 40) }, .duration_ns = 50 * std.time.ns_per_ms } } }});
        try h.loop.dispatch(20);
    }
    try h.settle();
    const second = try h.comp.createWindow(.{});
    try h.settle();
    try testing.expectEqual(@as(?std.meta.Tag(@import("surface.zig").Surface), .vulkan), (try Probe.read(h.comp, second)).presenter);
}

test "pacing: Vulkan FIFO: frame clock and presentation feedback stay correct, hidden windows never block" {
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

// dma-buf external frames (D17) -----------------------------------------------

/// A dma-buf holding an opaque w x h XRGB8888 frame of one color: udmabuf
/// over a sealed memfd. Null where /dev/udmabuf does not open.
fn udmabufFrame(w: u32, ht: u32, bgrx: [4]u8, key: u64) !?update.ExternalFrame {
    const linux = std.os.linux;
    const stride = w * 4;
    const size = std.mem.alignForward(usize, stride * ht, std.heap.page_size_min);
    const memfd: i32 = @intCast(linux.memfd_create("siv-udmabuf", linux.MFD.ALLOW_SEALING | linux.MFD.CLOEXEC));
    defer _ = linux.close(memfd);
    _ = linux.ftruncate(memfd, @intCast(size));
    const pixels = try testing.allocator.alloc(u8, stride * ht);
    defer testing.allocator.free(pixels);
    for (0..w * ht) |i| pixels[i * 4 ..][0..4].* = bgrx;
    _ = linux.pwrite(memfd, pixels.ptr, pixels.len, 0);
    _ = linux.fcntl(memfd, linux.F.ADD_SEALS, linux.F.SEAL_SHRINK);
    const dev_rc = linux.open("/dev/udmabuf", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(dev_rc) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(dev_rc));
    var create = extern struct { memfd: u32, flags: u32, offset: u64, size: u64 }{ .memfd = @intCast(memfd), .flags = 1, .offset = 0, .size = size }; // UDMABUF_FLAGS_CLOEXEC
    const rc = linux.ioctl(@intCast(dev_rc), 0x40187542, @intFromPtr(&create)); // UDMABUF_CREATE
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    var f: update.ExternalFrame = .{ .fd = fd, .width = w, .height = ht, .stride = stride, .key = key };
    f.dmabuf = .{ .format = scene.Dmabuf.xrgb8888, .modifier = scene.Dmabuf.modifier_linear, .plane_count = 1 };
    f.dmabuf.?.planes[0] = .{ .fd = fd, .offset = 0, .stride = stride };
    return f;
}

/// An unsignaled fence that the test signals: vgem's (the kernel's virtual
/// GEM driver, `modprobe vgem`), as a sync_file. Null without vgem.
const VgemFence = struct {
    drm: i32,
    fence: u32,
    sync_file: i32,

    fn create() ?VgemFence {
        const linux = std.os.linux;
        // vgem's primary node: dumb buffers need one.
        var path_buf: [64]u8 = undefined;
        var link_buf: [256]u8 = undefined;
        const drm: i32 = for (0..16) |n| {
            const sys = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/drm/card{d}/device", .{n}, 0) catch unreachable;
            const len = linux.readlink(sys, &link_buf, link_buf.len);
            if (linux.errno(len) != .SUCCESS or !std.mem.endsWith(u8, link_buf[0..len], "/vgem")) continue;
            const dev = std.fmt.bufPrintSentinel(&path_buf, "/dev/dri/card{d}", .{n}, 0) catch unreachable;
            const rc = linux.open(dev, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) return null;
            break @intCast(rc);
        } else return null;
        errdefer _ = linux.close(drm);
        var dumb = extern struct { height: u32, width: u32, bpp: u32, flags: u32 = 0, handle: u32 = 0, pitch: u32 = 0, size: u64 = 0 }{ .height = 1, .width = 1024, .bpp = 32 };
        if (linux.errno(linux.ioctl(drm, 0xc02064b2, @intFromPtr(&dumb))) != .SUCCESS) return null; // DRM_IOCTL_MODE_CREATE_DUMB
        var attach = extern struct { handle: u32, flags: u32, out_fence: u32 = 0, pad: u32 = 0 }{ .handle = dumb.handle, .flags = 1 }; // VGEM_FENCE_WRITE
        if (linux.errno(linux.ioctl(drm, 0xc0106441, @intFromPtr(&attach))) != .SUCCESS) return null; // DRM_IOCTL_VGEM_FENCE_ATTACH
        var prime = extern struct { handle: u32, flags: u32, fd: i32 = -1 }{ .handle = dumb.handle, .flags = 0o2000000 }; // O_CLOEXEC
        if (linux.errno(linux.ioctl(drm, 0xc00c642d, @intFromPtr(&prime))) != .SUCCESS) return null; // DRM_IOCTL_PRIME_HANDLE_TO_FD
        defer _ = linux.close(prime.fd);
        // The fences a reader waits for: the write fence just attached.
        var sync = extern struct { flags: u32, fd: i32 = -1 }{ .flags = 1 }; // DMA_BUF_SYNC_READ
        if (linux.errno(linux.ioctl(prime.fd, 0xc0086202, @intFromPtr(&sync))) != .SUCCESS) return null; // DMA_BUF_IOCTL_EXPORT_SYNC_FILE
        return .{ .drm = drm, .fence = attach.out_fence, .sync_file = sync.fd };
    }

    /// Makes `dmabuf`'s pending writes wait for the fence, as a GPU
    /// producer's driver would (Mesa's WSI does the same).
    fn gate(v: VgemFence, dmabuf: i32) !void {
        var import = extern struct { flags: u32, fd: i32 }{ .flags = 2, .fd = v.sync_file }; // DMA_BUF_SYNC_WRITE
        if (std.os.linux.errno(std.os.linux.ioctl(dmabuf, 0x40086203, @intFromPtr(&import))) != .SUCCESS) return error.Unexpected; // DMA_BUF_IOCTL_IMPORT_SYNC_FILE
    }

    fn signal(v: VgemFence) void {
        var arg = extern struct { fence: u32, flags: u32 = 0 }{ .fence = v.fence };
        _ = std.os.linux.ioctl(v.drm, 0x40086442, @intFromPtr(&arg)); // DRM_IOCTL_VGEM_FENCE_SIGNAL
    }

    fn deinit(v: VgemFence) void {
        v.signal();
        _ = std.os.linux.close(v.sync_file);
        _ = std.os.linux.close(v.drm);
    }
};

/// The window's subsurface for external content as the platform last set
/// it up, and whether sway still holds the wl_buffer of frame `key`.
const SubProbe = struct {
    window: WindowId,
    key: u64,
    shown: u64 = 0,
    dmabuf: bool = false,
    attached: bool = false,
    busy: bool = false,

    fn f(ctx: ?*anyopaque, c: *Compositor) void {
        const p: *SubProbe = @ptrCast(@alignCast(ctx));
        const w = c.platform.wayland.get(p.window);
        for (w.subsurfaces.items) |s| if (s) |sub| {
            p.shown = sub.key;
            p.dmabuf = sub.dmabuf != null;
            p.attached = sub.attached;
        };
        p.busy = c.platform.wayland.dmabufBusy(p.window, p.key);
    }

    fn read(comp: *Compositor, window: WindowId, key: u64) !SubProbe {
        var p: SubProbe = .{ .window = window, .key = key };
        try comp.call(&p, f);
        return p;
    }

    /// Dispatches until frame `key` is attached.
    fn waitShown(h: *Harness, window: WindowId, key: u64) !void {
        const deadline = Loop.now() + 3 * std.time.ns_per_s;
        while (true) {
            const p = try read(h.comp, window, key);
            if (p.shown == key and p.attached and p.dmabuf) return;
            if (Loop.now() > deadline) return error.Timeout;
            try h.loop.dispatch(10);
        }
    }
};

fn dispatchMs(h: *Harness, ms: u64) !void {
    const until = Loop.now() + ms * std.time.ns_per_ms;
    while (Loop.now() < until) try h.loop.dispatch(10);
}

fn waitReleased(h: *Harness, key: u64) !void {
    const deadline = Loop.now() + 3 * std.time.ns_per_s;
    while (!wasReleased(h, key)) {
        if (Loop.now() > deadline) return error.Timeout;
        try h.loop.dispatch(10);
    }
}

test "dma-buf frames on sway: promoted, shown once their fences signal, released after sway lets go" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    const id = try h.comp.createWindow(.{});
    const tiled = Loop.now() + 10 * std.time.ns_per_s;
    while (h.size.width != 1280) {
        if (Loop.now() > tiled) return error.Timeout;
        try h.loop.dispatch(10);
    }
    try h.settle();
    // Only a GPU renderer offers linux-dmabuf (SIV_SWAY_RENDERER=vulkan).
    const Supports = struct {
        yes: bool = false,
        fn f(ctx: ?*anyopaque, c: *Compositor) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.yes = c.platform.wayland.supportsDmabuf(scene.Dmabuf.xrgb8888, scene.Dmabuf.modifier_linear);
        }
    };
    var supports: Supports = .{};
    try h.comp.call(&supports, Supports.f);
    if (!supports.yes) return error.SkipZigTest;
    // 64 px rows: 256 bytes, the stride RADV's import wants.
    var frames: [3]update.ExternalFrame = undefined;
    for (&frames, 0..) |*f, i| f.* = (try udmabufFrame(64, 48, .{ 0x40, @intCast(i * 0x60), 0xff, 0 }, i + 1)) orelse return error.SkipZigTest;
    defer for (frames) |f| f.close();

    // Topmost and opaque: promoted to a subsurface, as a dma-buf
    // wl_buffer (create_immed).
    const ext = try h.comp.createExternal(id);
    try h.comp.setExternalFrame(id, ext, frames[0]);
    h.seq = try h.comp.commit(id, &.{
        .{ .create = 5 },
        .{ .insert = .{ .layer = 5, .parent = 1 } },
        .{ .set_transform = .{ .layer = 5, .transform = .offset(100, 80) } },
        .{ .set_external = .{ .layer = 5, .external = .{ .id = ext, .rect = .xywh(0, 0, 128, 96) } } },
    });
    try h.settle();
    try SubProbe.waitShown(&h, id, 1);

    // A frame whose writes are pending stays off screen until its fence
    // signals, and the frame before stays.
    if (VgemFence.create()) |vgem| {
        defer vgem.deinit();
        try vgem.gate(frames[1].fd);
        try h.comp.setExternalFrame(id, ext, frames[1]);
        try dispatchMs(&h, 200);
        try testing.expectEqual(@as(u64, 1), (try SubProbe.read(h.comp, id, 1)).shown);
        try testing.expect(!wasReleased(&h, 1));
        vgem.signal();
    } else {
        std.log.warn("vgem is not loaded; fence gating not checked", .{});
        try h.comp.setExternalFrame(id, ext, frames[1]);
    }
    try SubProbe.waitShown(&h, id, 2);
    try waitReleased(&h, 1);

    // A replaced frame goes back to the producer only after sway released
    // its wl_buffer: with sway stopped, frame 3 replaces frame 2 on siv's
    // side, but frame 2 stays in use until sway runs again.
    _ = std.c.kill(h.sway.pid, .STOP);
    var stopped = true;
    defer if (stopped) {
        _ = std.c.kill(h.sway.pid, .CONT);
    };
    try h.comp.setExternalFrame(id, ext, frames[2]);
    try SubProbe.waitShown(&h, id, 3);
    try dispatchMs(&h, 100);
    try testing.expect((try SubProbe.read(h.comp, id, 2)).busy);
    try testing.expect(!wasReleased(&h, 2));
    _ = std.c.kill(h.sway.pid, .CONT);
    stopped = false;
    try waitReleased(&h, 2);
    try testing.expect(!(try SubProbe.read(h.comp, id, 2)).busy);

    try testing.expect(!wasReleased(&h, 3));
    try h.comp.destroyExternal(id, ext);
    try waitReleased(&h, 3);
}

fn wasReleased(h: *const Harness, key: u64) bool {
    for (h.events.items) |e| if (e == .external_released and e.external_released.key == key) return true;
    return false;
}
