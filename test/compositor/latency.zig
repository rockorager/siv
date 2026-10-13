//! Input-to-photon latency and animation smoothness (D8, D25) on the
//! headless backend at 60 Hz, with the UI thread idle and deliberately
//! stalled. "Photon" is the predicted presentation time (the vblank) of
//! the first frame that shows the input's effect; input time is when the
//! platform received the event.
//!
//! Print the measurements with SIV_MEASURE=1 zig build test-headless.

const std = @import("std");
const scene = @import("scene");
const platform = @import("platform");
const loop_mod = @import("loop");
const compositor = @import("compositor");
const Ui = @import("harness.zig").Ui;

const Loop = loop_mod.Loop;
const Compositor = compositor.Compositor;
const testing = std.testing;

const refresh_ns = platform.FrameClock.default_refresh_ns;
const trials = 20;

fn measuring() bool {
    return testing.environ.getPosix("SIV_MEASURE") != null;
}

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

const Summary = struct {
    min: u64,
    median: u64,
    max: u64,

    fn of(samples: []u64) Summary {
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        return .{ .min = samples[0], .median = samples[samples.len / 2], .max = samples[samples.len - 1] };
    }

    fn print(s: Summary, what: []const u8) void {
        if (!measuring()) return;
        const ms = 1e-6;
        std.debug.print("{s}: min {d:.2} ms, median {d:.2} ms, max {d:.2} ms (refresh {d:.2} ms)\n", .{
            what,
            @as(f64, @floatFromInt(s.min)) * ms,
            @as(f64, @floatFromInt(s.median)) * ms,
            @as(f64, @floatFromInt(s.max)) * ms,
            @as(f64, @floatFromInt(refresh_ns)) * ms,
        });
    }
};

/// A 400x300 window: a background layer 1 and a scroll container 2 with
/// a tall striped child 3.
fn setup(ui: *Ui) !platform.WindowId {
    const id = try ui.comp.createWindow(.{ .width = 400, .height = 300 });
    var bg = ui.builder();
    try bg.fillRect(.xywh(0, 0, 400, 300), .color(.white));
    var tall = ui.builder();
    for (0..50) |i| {
        const y: f32 = @floatFromInt(i * 40);
        try tall.fillRect(.xywh(0, y, 400, 20), .color(.srgb8(@intCast(i * 5), 0x40, 0x80, 0xff)));
    }
    _ = try ui.commit(id, &.{
        .{ .create = 1 },
        .{ .create = 2 },
        .{ .create = 3 },
        .{ .set_root = 1 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .insert = .{ .layer = 3, .parent = 2 } },
        .{ .set_content = .{ .layer = 1, .content = try Ui.content(bg) } },
        .{ .set_scroll = .{ .layer = 2, .scroll = .{ .viewport = .xywh(0, 0, 400, 300), .content = .{ .width = 400, .height = 2000 } } } },
        .{ .set_content = .{ .layer = 3, .content = try Ui.content(tall) } },
    });
    try ui.waitSettled(id);
    return id;
}

/// Injects a platform event on the compositor thread and returns when.
fn inject(comp: *Compositor, ev: platform.Event) !u64 {
    const Ctx = struct {
        ev: platform.Event,
        t: u64 = 0,
        fn f(ctx: ?*anyopaque, c: *Compositor) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.t = Loop.now();
            c.platform.headless.inject(s.ev);
        }
    };
    var ctx: Ctx = .{ .ev = ev };
    try comp.call(&ctx, Ctx.f);
    return ctx.t;
}

const Probe = struct {
    window: platform.WindowId,
    frames: u64 = 0,
    last: u64 = 0,
    offset: f32 = 0,
    history: [128]u64 = undefined,

    fn f(ctx: ?*anyopaque, c: *Compositor) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        const s = c.frameStats(p.window).?;
        p.frames = s.frames;
        p.last = s.last();
        p.history = s.history;
        p.offset = c.scrollOffset(p.window, 2).?.y;
    }

    fn read(comp: *Compositor, window: platform.WindowId) !Probe {
        var p: Probe = .{ .window = window };
        try comp.call(&p, f);
        return p;
    }
};

/// A key press that the UI answers with new content. Returns latencies.
fn keyToPhoton(thread: bool, out: *[trials]u64) !void {
    var ui: Ui = .{};
    try ui.start(thread, .{ .headless = .{} });
    defer ui.stop();
    const id = try setup(&ui);
    const UiState = struct {
        var seq: u64 = 0;
        var flip: bool = false;
        fn hook(u: *Ui, ev: *const compositor.Event) void {
            if (ev.* != .platform or ev.platform != .key) return;
            flip = !flip;
            var b = u.builder();
            b.fillRect(.xywh(0, 0, 400, 300), .color(if (flip) .black else .white)) catch unreachable;
            seq = u.commit(0, &.{.{ .set_content = .{ .layer = 1, .content = Ui.content(b) catch unreachable } }}) catch unreachable;
        }
    };
    ui.hook = UiState.hook;
    var prng = std.Random.DefaultPrng.init(42);
    for (out) |*sample| {
        // Arrive at a random point in the refresh cycle.
        const pause = Loop.now() + refresh_ns + prng.random().uintLessThan(u64, refresh_ns);
        while (Loop.now() < pause) try ui.loop.dispatch(1);
        const before = UiState.seq;
        const t0 = try inject(ui.comp, .{ .key = .{ .window = id, .seat = 0, .keycode = 38, .keysym = 'a', .state = .pressed, .mods = .{}, .time = 0, .serial = 1 } });
        const deadline = Loop.now() + std.time.ns_per_s;
        const present_ns = while (Loop.now() < deadline) {
            try ui.loop.dispatch(1);
            if (UiState.seq == before) continue;
            if (ui.last(.presented)) |p| if (p.presented.seq >= UiState.seq) break p.presented.present_ns;
        } else return error.Timeout;
        sample.* = present_ns - t0;
    }
}

test "input-to-photon: compositor thread versus rendering on the UI thread" {
    var threaded: [trials]u64 = undefined;
    var inline_: [trials]u64 = undefined;
    try keyToPhoton(true, &threaded);
    try keyToPhoton(false, &inline_);
    const t = Summary.of(&threaded);
    const u = Summary.of(&inline_);
    t.print("key to photon, compositor thread, idle UI");
    u.print("key to photon, UI-thread rendering, idle UI");
    // D25: within one frame. D8's reversal criterion: no more than one
    // frame worse than rendering on the UI thread.
    try testing.expect(t.median <= refresh_ns + 2 * std.time.ns_per_ms);
    try testing.expect(t.median <= u.median + refresh_ns);
    try testing.expect(t.max <= 2 * refresh_ns + 2 * std.time.ns_per_ms);
}

test "input-to-photon of compositor scrolling while the UI thread is stalled" {
    var ui: Ui = .{};
    try ui.start(true, .{ .headless = .{} });
    defer ui.stop();
    const id = try setup(&ui);
    _ = try inject(ui.comp, .{ .pointer_motion = .{ .window = id, .seat = 0, .x = 200, .y = 150 } });

    // Another thread scrolls and watches the screen; this one, the UI
    // thread, sleeps through all of it without dispatching.
    const Scroller = struct {
        fn run(comp: *Compositor, window: platform.WindowId, out: *[trials]u64, err: *?anyerror) void {
            measure(comp, window, out) catch |e| {
                err.* = e;
            };
        }

        fn measure(comp: *Compositor, window: platform.WindowId, out: *[trials]u64) !void {
            var prng = std.Random.DefaultPrng.init(7);
            for (out) |*sample| {
                sleepNs(refresh_ns + prng.random().uintLessThan(u64, refresh_ns));
                const before = try Probe.read(comp, window);
                const t0 = try inject(comp, .{ .scroll = .{ .window = window, .seat = 0, .dy = 10, .source = .wheel } });
                const deadline = Loop.now() + std.time.ns_per_s;
                while (true) {
                    if (Loop.now() > deadline) return error.Timeout;
                    sleepNs(200 * std.time.ns_per_us);
                    const p = try Probe.read(comp, window);
                    if (p.offset != before.offset and p.frames > before.frames) {
                        sample.* = p.last - t0;
                        break;
                    }
                }
            }
        }
    };
    var samples: [trials]u64 = undefined;
    var err: ?anyerror = null;
    const helper = try std.Thread.spawn(.{}, Scroller.run, .{ ui.comp, id, &samples, &err });
    sleepNs(trials * 2 * refresh_ns + 200 * std.time.ns_per_ms);
    helper.join();
    if (err) |e| return e;
    const s = Summary.of(&samples);
    s.print("wheel to photon, compositor scrolling, stalled UI");
    try testing.expect(s.median <= refresh_ns + 2 * std.time.ns_per_ms);
    try testing.expect(s.max <= 2 * refresh_ns + 2 * std.time.ns_per_ms);
}

/// Runs a 300 ms animation while the UI thread spins without dispatching
/// and returns how many vblanks in the animation had no frame. With the
/// compositor thread, the UI thread spins until the compositor has run
/// the whole animation on its own; rendering on the UI thread, it spins
/// for 400 ms.
fn missedDuringStall(thread: bool) !struct { frames: usize, missed: usize } {
    var ui: Ui = .{};
    try ui.start(thread, .{ .headless = .{} });
    defer ui.stop();
    const id = try setup(&ui);
    const start = (try Probe.read(ui.comp, id)).frames;
    _ = try ui.commit(id, &.{.{ .animate = .{ .layer = 2, .animation = .{
        .to = .{ .scroll = .{ .x = 0, .y = 1000 } },
        .duration_ns = 300 * std.time.ns_per_ms,
        .easing = .linear,
    } } }});
    if (thread) {
        // Let the commit reach the compositor, then stall. How many
        // vblanks go without a frame depends on when a loaded machine
        // runs the compositor thread; that it animates while the UI
        // thread does not dispatch is siv's.
        try ui.waitSettled(id);
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        while ((try Probe.read(ui.comp, id)).offset != 1000) {
            if (Loop.now() > deadline) return error.Timeout;
            spinNs(10 * std.time.ns_per_ms);
        }
    } else {
        // On the UI thread, the stall lands between two frames.
        try ui.waitSettled(id);
        try ui.loop.dispatch(0);
        spinNs(400 * std.time.ns_per_ms);
    }
    try ui.run(&ui, struct {
        fn f(x: *Ui) bool {
            return x.count(.animation_finished) >= 1;
        }
    }.f);
    const p = try Probe.read(ui.comp, id);
    const n: usize = @intCast(p.frames - start);
    var missed: usize = 0;
    var i: u64 = start + 1;
    while (i < p.frames) : (i += 1) {
        const a = p.history[(i - 1) % p.history.len];
        const b = p.history[i % p.history.len];
        missed += @intCast((b - a + refresh_ns / 2) / refresh_ns - 1);
    }
    return .{ .frames = n, .missed = missed };
}

test "animation smoothness while the UI thread is stalled" {
    const t = try missedDuringStall(true);
    const u = try missedDuringStall(false);
    if (measuring()) {
        std.debug.print("300 ms animation, UI thread spinning: compositor thread {d} frames, {d} missed vblanks; UI-thread rendering (400 ms spin) {d} frames, {d} missed\n", .{ t.frames, t.missed, u.frames, u.missed });
    }
    // The compositor thread ran the animation alone (missedDuringStall
    // waits for it to finish); rendering on the UI thread freezes for the
    // stall (D8's motivation).
    try testing.expect(u.missed >= 15);
}
