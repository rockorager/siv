//! Headless backend (D20, D24): windows, outputs, and input without a
//! compositor, on the same loop and frame clock as the Wayland backend.
//! Tests drive the simulated compositor (configure, scale, close, input,
//! hotplug) and read back presented pixels for golden images.
//!
//! Frame callbacks complete at simulated vblanks: multiples of `refresh_ns`
//! from backend creation, timed with loop timers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("platform.zig");
const Loop = platform.Loop;
const Timer = @import("loop").Timer;
const FrameClock = platform.FrameClock;
const Headless = @This();

const Error = platform.Error;
const WindowId = platform.WindowId;
const OutputId = platform.OutputId;
const SeatId = platform.SeatId;
const WindowState = platform.WindowState;
const Buffer = platform.Buffer;
const Rect = platform.Rect;
const Size = platform.Size;

loop: *Loop,
allocator: Allocator,
queue: platform.EventQueue,
windows: std.ArrayList(?*Window) = .empty,
outputs: std.ArrayList(?platform.OutputInfo) = .empty,
refresh_ns: u64,
epoch_ns: u64,

pub const Options = struct {
    refresh_ns: u64 = FrameClock.default_refresh_ns,
    /// The initial output. Windows take its integer scale.
    output: platform.OutputInfo = defaultOutput(),
};

fn defaultOutput() platform.OutputInfo {
    var info: platform.OutputInfo = .{ .width = 1920, .height = 1080, .refresh_mhz = 60000 };
    info.name.set("HEADLESS-1");
    info.description.set("siv headless output");
    return info;
}

const Window = struct {
    hl: *Headless,
    id: WindowId,
    state: WindowState,
    title: platform.BoundedString(256) = .{},
    clock: FrameClock = .{},
    frame_task: Loop.Task = .{ .func = runFrame },
    vblank: Timer = .{ .func = onVblank },
    slots: [2]Slot = .{ .{}, .{} },
    /// Slot shown on the simulated screen.
    front: ?u8 = null,
    damage: ?Rect = null,

    const Slot = struct { pixels: []u8 = &.{}, width: u32 = 0, height: u32 = 0 };
};

/// Presented pixels, in the format of `platform.Buffer`.
pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    /// Bounding box of the damage passed to the last present.
    damage: ?Rect,
};

pub fn create(loop: *Loop, allocator: Allocator, sink: platform.Sink, options: Options) Error!*Headless {
    const hl = try allocator.create(Headless);
    errdefer allocator.destroy(hl);
    hl.* = .{
        .loop = loop,
        .allocator = allocator,
        .queue = .{ .loop = loop, .allocator = allocator, .sink = sink },
        .refresh_ns = options.refresh_ns,
        .epoch_ns = Loop.now(),
    };
    _ = try hl.addOutput(options.output);
    return hl;
}

pub fn destroy(hl: *Headless) void {
    for (hl.windows.items, 0..) |w, i| if (w != null) hl.destroyWindow(@intCast(i));
    hl.windows.deinit(hl.allocator);
    hl.outputs.deinit(hl.allocator);
    hl.queue.deinit();
    hl.allocator.destroy(hl);
}

fn get(hl: *Headless, id: WindowId) *Window {
    return hl.windows.items[id].?;
}

fn primaryScale(hl: *Headless) platform.Scale {
    for (hl.outputs.items) |o| if (o) |info| return .int(@intCast(@max(info.scale, 1)));
    return .{};
}

// Platform interface ------------------------------------------------------

pub fn createWindow(hl: *Headless, options: platform.WindowOptions) Error!WindowId {
    const slot = for (hl.windows.items, 0..) |w, i| {
        if (w == null) break i;
    } else blk: {
        try hl.windows.append(hl.allocator, null);
        break :blk hl.windows.items.len - 1;
    };
    const w = try hl.allocator.create(Window);
    w.* = .{
        .hl = hl,
        .id = @intCast(slot),
        .state = .{
            .width = options.width,
            .height = options.height,
            .scale = hl.primaryScale(),
            .decoration = options.decoration,
            .states = .{ .activated = true },
        },
    };
    w.title.set(options.title);
    hl.windows.items[slot] = w;
    // Like a compositor: the initial configure, answered by a frame.
    hl.sendConfigure(w);
    return w.id;
}

pub fn destroyWindow(hl: *Headless, id: WindowId) void {
    const w = hl.get(id);
    hl.loop.unschedule(&w.frame_task);
    hl.loop.cancelTimer(&w.vblank);
    for (w.slots) |s| hl.allocator.free(s.pixels);
    hl.queue.purge(id);
    hl.allocator.destroy(w);
    hl.windows.items[id] = null;
}

pub fn windowState(hl: *Headless, id: WindowId) *const WindowState {
    return &hl.get(id).state;
}

pub fn requestFrame(hl: *Headless, id: WindowId) void {
    const w = hl.get(id);
    w.clock.request();
    hl.scheduleFrame(w);
}

pub fn acquireBuffer(hl: *Headless, id: WindowId) Error!Buffer {
    const w = hl.get(id);
    const index: u8 = if (w.front) |f| 1 - f else 0;
    const s = &w.slots[index];
    const width = w.state.bufferWidth();
    const height = w.state.bufferHeight();
    if (s.width != width or s.height != height) {
        const pixels = try hl.allocator.alloc(u8, @as(usize, width) * height * 4);
        hl.allocator.free(s.pixels);
        s.* = .{ .pixels = pixels, .width = width, .height = height };
    }
    return .{ .pixels = s.pixels, .width = width, .height = height, .stride = width * 4, .slot = index };
}

pub fn present(hl: *Headless, id: WindowId, buffer: Buffer, damage: ?[]const Rect) void {
    const w = hl.get(id);
    w.front = buffer.slot;
    w.damage = if (damage) |rects| bounds(rects) else .{
        .x = 0,
        .y = 0,
        .width = @intCast(buffer.width),
        .height = @intCast(buffer.height),
    };
    w.clock.committed();
    const now = Loop.now();
    const vblank = hl.epoch_ns + ((now - hl.epoch_ns) / hl.refresh_ns + 1) * hl.refresh_ns;
    hl.loop.startTimer(&w.vblank, vblank, 0) catch {
        // Without a timer the frame callback would never come.
        w.clock.done();
        hl.queue.fail(error.OutOfMemory);
    };
}

pub fn output(hl: *Headless, id: OutputId) ?*const platform.OutputInfo {
    if (id >= hl.outputs.items.len) return null;
    return if (hl.outputs.items[id]) |*info| info else null;
}

pub fn setTitle(hl: *Headless, id: WindowId, text: []const u8) void {
    hl.get(id).title.set(text);
}

pub fn setMaximized(hl: *Headless, id: WindowId, maximized: bool) void {
    hl.get(id).state.states.maximized = maximized;
    hl.fillOutput(id);
}

pub fn setFullscreen(hl: *Headless, id: WindowId, fullscreen: bool) void {
    hl.get(id).state.states.fullscreen = fullscreen;
    hl.fillOutput(id);
}

pub fn setMinimized(_: *Headless, _: WindowId) void {}
pub fn setSizeLimits(_: *Headless, _: WindowId, _: Size, _: Size) void {}
pub fn beginMove(_: *Headless, _: WindowId, _: SeatId, _: u32) void {}
pub fn beginResize(_: *Headless, _: WindowId, _: SeatId, _: u32, _: platform.Edge) void {}
pub fn showWindowMenu(_: *Headless, _: WindowId, _: SeatId, _: u32, _: i32, _: i32) void {}
pub fn setWindowGeometry(_: *Headless, _: WindowId, _: Rect) void {}
pub fn setRegion(_: *Headless, _: WindowId, _: platform.Region, _: ?[]const Rect) Error!void {}

fn fillOutput(hl: *Headless, id: WindowId) void {
    const w = hl.get(id);
    const info = hl.output(0) orelse return;
    const scale: u32 = @intCast(@max(info.scale, 1));
    if (w.state.states.maximized or w.state.states.fullscreen) {
        w.state.width = @as(u32, @intCast(info.width)) / scale;
        w.state.height = @as(u32, @intCast(info.height)) / scale;
    }
    hl.sendConfigure(w);
}

// Simulated compositor ----------------------------------------------------

/// A compositor-initiated configure. Null keeps the current value.
pub fn configure(hl: *Headless, id: WindowId, size: ?Size, states: ?platform.WindowStates) void {
    const w = hl.get(id);
    if (size) |s| {
        w.state.width = s.width;
        w.state.height = s.height;
    }
    if (states) |s| w.state.states = s;
    w.clock.suspended = w.state.states.suspended;
    hl.sendConfigure(w);
}

/// Sets a window's preferred scale, as fractional-scale-v1 would.
pub fn setScale(hl: *Headless, id: WindowId, scale: platform.Scale) void {
    const w = hl.get(id);
    w.state.scale = scale;
    hl.sendConfigure(w);
}

pub fn requestClose(hl: *Headless, id: WindowId) void {
    hl.queue.push(.{ .close_requested = id });
}

/// Delivers an input event in the dispatch phase, like a seat would.
pub fn inject(hl: *Headless, event: platform.Event) void {
    hl.queue.push(event);
}

pub fn addOutput(hl: *Headless, info: platform.OutputInfo) Error!OutputId {
    try hl.outputs.append(hl.allocator, info);
    const id: OutputId = @intCast(hl.outputs.items.len - 1);
    hl.queue.push(.{ .output_added = id });
    return id;
}

pub fn removeOutput(hl: *Headless, id: OutputId) void {
    hl.outputs.items[id] = null;
    hl.queue.push(.{ .output_removed = id });
}

/// The window's last presented frame.
pub fn presented(hl: *Headless, id: WindowId) ?Image {
    const w = hl.get(id);
    const s = w.slots[w.front orelse return null];
    return .{ .pixels = s.pixels, .width = s.width, .height = s.height, .stride = s.width * 4, .damage = w.damage };
}

/// The window's title as last set.
pub fn title(hl: *Headless, id: WindowId) []const u8 {
    return hl.get(id).title.slice();
}

// Frames ------------------------------------------------------------------

fn sendConfigure(hl: *Headless, w: *Window) void {
    hl.queue.push(.{ .configure = .{ .window = w.id, .state = w.state } });
    w.clock.configured = true;
    w.clock.force();
    hl.scheduleFrame(w);
}

fn scheduleFrame(hl: *Headless, w: *Window) void {
    if (w.clock.ready()) hl.loop.schedule(&w.frame_task, .frame);
}

fn runFrame(task: *Loop.Task) void {
    const w: *Window = @fieldParentPtr("frame_task", task);
    if (!w.clock.ready()) return;
    const time = w.clock.begin(Loop.now());
    w.hl.queue.sink.send(&.{ .frame = .{ .window = w.id, .time = time } });
}

fn onVblank(timer: *Timer) void {
    const w: *Window = @fieldParentPtr("vblank", timer);
    w.clock.done();
    w.clock.presented(timer.deadline, w.hl.refresh_ns);
    w.hl.scheduleFrame(w);
}

fn bounds(rects: []const Rect) ?Rect {
    if (rects.len == 0) return null;
    var x0: i32 = std.math.maxInt(i32);
    var y0: i32 = std.math.maxInt(i32);
    var x1: i32 = std.math.minInt(i32);
    var y1: i32 = std.math.minInt(i32);
    for (rects) |r| {
        x0 = @min(x0, r.x);
        y0 = @min(y0, r.y);
        x1 = @max(x1, r.x + r.width);
        y1 = @max(y1, r.y + r.height);
    }
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

const testing = std.testing;

/// A minimal application: answers every frame by filling the window with
/// a color and records events.
const TestApp = struct {
    hl: *Headless = undefined,
    frames: usize = 0,
    configures: usize = 0,
    last_frame: ?platform.Frame = null,
    color: u32 = 0xff336699,
    keep_animating: bool = false,
    closed: bool = false,
    keys: usize = 0,

    fn onEvent(ctx: ?*anyopaque, ev: *const platform.Event) void {
        const app: *TestApp = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .configure => app.configures += 1,
            .frame => |f| {
                app.frames += 1;
                app.last_frame = f;
                const buf = app.hl.acquireBuffer(f.window) catch unreachable;
                const words = std.mem.bytesAsSlice(u32, buf.pixels);
                @memset(words, app.color);
                app.hl.present(f.window, buf, null);
                if (app.keep_animating) app.hl.requestFrame(f.window);
            },
            .close_requested => |id| {
                app.closed = true;
                app.hl.destroyWindow(id);
            },
            .key => app.keys += 1,
            else => {},
        }
    }
};

test "initial configure produces one frame; animation follows vblanks" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();
    var app: TestApp = .{};
    const hl = try create(&loop, testing.allocator, .{ .ctx = &app, .func = TestApp.onEvent }, .{
        .refresh_ns = 2 * std.time.ns_per_ms,
    });
    defer hl.destroy();
    app.hl = hl;

    const id = try hl.createWindow(.{ .width = 40, .height = 30, .title = "test" });
    try loop.dispatch(0);
    try testing.expectEqual(@as(usize, 1), app.configures);
    try testing.expectEqual(@as(usize, 1), app.frames);
    const img = hl.presented(id).?;
    try testing.expectEqual(@as(u32, 40), img.width);
    try testing.expectEqual(@as(u32, 0xff336699), std.mem.readInt(u32, img.pixels[0..4], .little));

    // Nothing requested: the loop goes idle.
    try loop.dispatch(10);
    try testing.expectEqual(@as(usize, 1), app.frames);

    // Animating: one frame per vblank, each predicted one interval apart.
    app.keep_animating = true;
    hl.requestFrame(id);
    var times: [4]u64 = undefined;
    for (&times, 0..) |*t, i| {
        while (app.frames < 2 + i) try loop.dispatch(-1);
        t.* = app.last_frame.?.time.present_ns;
    }
    for (times[1..], times[0..3]) |b, a| try testing.expectEqual(hl.refresh_ns, b - a);
}

test "scale and maximize reconfigure; buffers follow the buffer size" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();
    var app: TestApp = .{};
    const hl = try create(&loop, testing.allocator, .{ .ctx = &app, .func = TestApp.onEvent }, .{});
    defer hl.destroy();
    app.hl = hl;

    const id = try hl.createWindow(.{ .width = 100, .height = 50 });
    try loop.dispatch(0);
    hl.setScale(id, .{ .v120 = 150 });
    try loop.dispatch(0);
    try testing.expectEqual(@as(usize, 2), app.frames);
    try testing.expectEqual(@as(u32, 125), hl.presented(id).?.width);
    try testing.expectEqual(@as(u32, 63), hl.presented(id).?.height); // 62.5 rounds up

    hl.setMaximized(id, true);
    try loop.dispatch(0);
    const s = hl.windowState(id);
    try testing.expect(s.states.maximized);
    try testing.expectEqual(@as(u32, 1920), s.width);
    try testing.expectEqual(@as(u32, 2400), hl.presented(id).?.width);
}

test "close, input injection, and output hotplug arrive in the dispatch phase" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();
    var app: TestApp = .{};
    const hl = try create(&loop, testing.allocator, .{ .ctx = &app, .func = TestApp.onEvent }, .{});
    defer hl.destroy();
    app.hl = hl;

    const id = try hl.createWindow(.{});
    try loop.dispatch(0);
    hl.inject(.{ .key = .{ .window = id, .seat = 0, .keycode = 38, .keysym = 'a', .state = .pressed, .mods = .{}, .time = 0, .serial = 1 } });
    hl.requestClose(id);
    // Queued after the close: purged when the app destroys the window.
    hl.inject(.{ .key = .{ .window = id, .seat = 0, .keycode = 38, .keysym = 'a', .state = .released, .mods = .{}, .time = 0, .serial = 2 } });
    const out = try hl.addOutput(.{ .scale = 2 });
    try loop.dispatch(0);
    try testing.expect(app.closed);
    try testing.expectEqual(@as(usize, 1), app.keys);
    try testing.expectEqual(@as(i32, 2), hl.output(out).?.scale);
    hl.removeOutput(out);
    try testing.expect(hl.output(out) == null);
}
