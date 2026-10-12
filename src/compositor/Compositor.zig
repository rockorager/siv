//! The compositor thread (D8) and its interface to the UI thread.
//!
//! The platform runs on the compositor's own loop. Its events arrive in
//! `onPlatformEvent`: frames are rendered here, configures and input are
//! forwarded to the UI (pointer scroll only when no scroll container takes
//! it), and everything the UI sends arrives through one ordered inbox:
//! commits, frame requests, window teardown, and closures (`post`,
//! `call`). Events for the UI go through an outbox that the UI loop drains
//! in its dispatch phase.
//!
//! Without a thread (`Options.thread = false`) the compositor runs on the
//! UI loop itself, deterministically, for tests and for comparing against
//! rendering on the UI thread (D8's reversal criterion).

const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;
const raster = @import("raster");
const scene = @import("scene");
const platform_mod = @import("platform");
const loop_mod = @import("loop");
const render_cpu = @import("render_cpu");
const update = @import("update.zig");
const anim = @import("anim.zig");
const tree_mod = @import("tree.zig");
const surface_mod = @import("surface.zig");

const Loop = loop_mod.Loop;
const Timer = loop_mod.Timer;
const Point = raster.Point;
const IRect = raster.IRect;
const Tree = tree_mod.Tree;
const Op = update.Op;
const Event = update.Event;
const WindowId = update.WindowId;
const LayerId = update.LayerId;

const Compositor = @This();
const log = std.log.scoped(.compositor);

gpa: Allocator,
executor: render_cpu.Executor,
ui_loop: *Loop,
threaded: bool,
thread: ?std.Thread = null,
/// The compositor thread's loop; unused without a thread.
own_loop: Loop = undefined,
/// The loop the platform and rendering run on.
loop: *Loop = undefined,
/// Only for the compositor thread, or inside `post` and `call`.
platform: platform_mod.Platform = undefined,

mutex: c.pthread_mutex_t = .{},
call_done: c.pthread_cond_t = .{},
inbox: Inbox = .{},
processing: Inbox = .{},
inbox_posted: bool = false,
inbox_remote: Loop.Remote = .{ .func = onInboxRemote },
inbox_task: Loop.Task = .{ .func = onInboxTask },
next_seq: u64 = 1,
draining: bool = false,
stopping: bool = false,

outbox: *Outbox,
windows: std.ArrayList(?*Window) = .empty,
seats: [max_seats]Seat = @splat(.{}),
released: std.ArrayList(*scene.Builder) = .empty,

const max_seats = 8;

pub const Backend = union(enum) {
    wayland: platform_mod.Wayland.Options,
    headless: platform_mod.Headless.Options,
};

pub const Options = struct {
    /// Must be thread-safe with a thread.
    allocator: Allocator,
    /// The application's worker pool (D6), for render tiles.
    executor: render_cpu.Executor,
    /// The UI thread's loop; events are delivered in its dispatch phase.
    ui_loop: *Loop,
    sink: Sink,
    backend: Backend,
    /// Run on a thread of its own (D8). Without one, everything runs on
    /// `ui_loop`.
    thread: bool = true,
};

/// Receives compositor events on the UI thread.
pub const Sink = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, event: *const Event) void,
};

/// Presentation timing of a window, for the inspector (D24) and latency
/// measurements.
pub const FrameStats = struct {
    /// Frames presented.
    frames: u64 = 0,
    /// Predicted presentation times of the most recent frames, oldest
    /// first within the ring; `frames % history.len` is the next slot.
    history: [128]u64 = @splat(0),

    pub fn last(s: *const FrameStats) u64 {
        if (s.frames == 0) return 0;
        return s.history[(s.frames - 1) % s.history.len];
    }
};

/// A window's frame statistics. Compositor thread only (inside `call`).
pub fn frameStats(self: *Compositor, id: WindowId) ?FrameStats {
    const w = self.getWindow(id) orelse return null;
    return w.stats;
}

/// A layer's scroll offset as last composed. Compositor thread only.
pub fn scrollOffset(self: *Compositor, id: WindowId, layer: LayerId) ?Point {
    const w = self.getWindow(id) orelse return null;
    const l = w.tree.get(layer) orelse return null;
    return l.offset;
}

/// Code run on the compositor thread by `post` and `call`. It may use
/// `compositor.platform`, e.g. for Wayland requests the UI owns logically.
pub const Func = *const fn (ctx: ?*anyopaque, compositor: *Compositor) void;

const Inbox = struct {
    msgs: std.ArrayList(Msg) = .empty,
    ops: std.ArrayList(Op) = .empty,

    fn deinit(in: *Inbox, gpa: Allocator) void {
        in.msgs.deinit(gpa);
        in.ops.deinit(gpa);
    }
};

const Msg = union(enum) {
    commit: struct { window: WindowId, seq: u64, start: u32, len: u32 },
    request_frame: WindowId,
    destroy_window: WindowId,
    call: *Call,
    post: struct { func: Func, destroy: ?*const fn (?*anyopaque) void, ctx: ?*anyopaque },
    stop,
};

const Call = struct { func: Func, ctx: ?*anyopaque, done: bool = false };

const Seat = struct {
    window: ?WindowId = null,
    pos: Point = .zero,
    mods: platform_mod.Mods = .{},
    /// The target of the touchpad gesture in progress.
    latch: ?tree_mod.Route = null,
    latch_window: WindowId = 0,
    velocity: anim.VelocityTracker = .{},
};

const Window = struct {
    id: WindowId,
    tree: Tree,
    tracker: scene.damage.Tracker,
    surface: surface_mod.Surface,
    /// Last commit applied, and the last one presented.
    seq: u64 = 0,
    presented_seq: u64 = 0,
    /// The UI asked for an `Event.frame`.
    ui_frame: bool = false,
    configure_serial: u64 = 0,
    /// Serial of the last configure that changed the logical size; frames
    /// wait for the UI's layout for it.
    size_serial: u64 = 0,
    size: platform_mod.Size = .{},
    stats: FrameStats = .{},
    /// Retries a frame when no buffer was free, or starts delayed
    /// animations.
    timer: Timer = .{ .func = onWindowTimer },
    compositor: *Compositor,
};

/// Starts the compositor and its platform backend.
pub fn create(options: Options) !*Compositor {
    const gpa = options.allocator;
    const self = try gpa.create(Compositor);
    errdefer gpa.destroy(self);
    const outbox = try gpa.create(Outbox);
    errdefer gpa.destroy(outbox);
    outbox.* = .{ .gpa = gpa, .ui_loop = options.ui_loop, .sink = options.sink, .threaded = options.thread };
    self.* = .{
        .gpa = gpa,
        .executor = options.executor,
        .ui_loop = options.ui_loop,
        .threaded = options.thread,
        .outbox = outbox,
    };
    if (options.thread) {
        self.own_loop = try Loop.init(gpa);
        self.loop = &self.own_loop;
    } else self.loop = options.ui_loop;
    errdefer if (options.thread) self.own_loop.deinit();

    const sink: platform_mod.Sink = .{ .ctx = self, .func = onPlatformEvent };
    self.platform = switch (options.backend) {
        .wayland => |o| .{ .wayland = try platform_mod.Wayland.create(self.loop, gpa, sink, o) },
        .headless => |o| .{ .headless = try platform_mod.Headless.create(self.loop, gpa, sink, o) },
    };
    errdefer self.destroyPlatform();
    if (options.thread) self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    return self;
}

/// Stops the thread and tears everything down. Builders still held are
/// not released through events: once this returns, nothing refers to
/// them. Call before deinitializing the worker pool and the UI loop.
pub fn destroy(self: *Compositor) void {
    if (self.thread) |t| {
        self.send(.stop) catch {
            // Without memory for the message, stop through the flag.
            _ = c.pthread_mutex_lock(&self.mutex);
            self.stopping = true;
            _ = c.pthread_mutex_unlock(&self.mutex);
            self.loop.wake();
        };
        t.join();
    } else self.loop.unschedule(&self.inbox_task);
    // Undelivered closures release what they own.
    for ([_]*Inbox{ &self.processing, &self.inbox }) |in| for (in.msgs.items) |m| switch (m) {
        .post => |p| if (p.destroy) |d| d(p.ctx),
        else => {},
    };
    for (self.windows.items) |w| if (w) |win| self.freeWindow(win);
    self.windows.deinit(self.gpa);
    self.destroyPlatform();
    if (self.threaded) self.own_loop.deinit();
    self.inbox.deinit(self.gpa);
    self.processing.deinit(self.gpa);
    self.released.deinit(self.gpa);
    self.outbox.close();
    _ = c.pthread_cond_destroy(&self.call_done);
    _ = c.pthread_mutex_destroy(&self.mutex);
    self.gpa.destroy(self);
}

fn destroyPlatform(self: *Compositor) void {
    switch (self.platform) {
        inline else => |b| b.destroy(),
    }
}

fn threadMain(self: *Compositor) void {
    while (true) {
        _ = c.pthread_mutex_lock(&self.mutex);
        const stop = self.stopping;
        _ = c.pthread_mutex_unlock(&self.mutex);
        if (stop) break;
        self.loop.dispatch(-1) catch |err| {
            log.err("compositor loop failed: {t}", .{err});
            break;
        };
    }
}

// UI thread interface -------------------------------------------------------

/// Commits `ops` to `window` as one atomic batch and returns its sequence
/// number. Values are validated here; ops that do not fit the tree are
/// skipped on the compositor thread.
pub fn commit(self: *Compositor, window: WindowId, ops: []const Op) !u64 {
    for (ops) |op| try op.validate();
    _ = c.pthread_mutex_lock(&self.mutex);
    defer _ = c.pthread_mutex_unlock(&self.mutex);
    const start = self.inbox.ops.items.len;
    try self.inbox.ops.appendSlice(self.gpa, ops);
    errdefer self.inbox.ops.shrinkRetainingCapacity(start);
    const seq = self.next_seq;
    try self.inbox.msgs.append(self.gpa, .{ .commit = .{ .window = window, .seq = seq, .start = @intCast(start), .len = @intCast(ops.len) } });
    self.next_seq += 1;
    self.wakeLocked();
    return seq;
}

/// Asks for an `Event.frame` for `window` at its next frame.
pub fn requestFrame(self: *Compositor, window: WindowId) Allocator.Error!void {
    return self.send(.{ .request_frame = window });
}

/// Creates a window. Its first configure arrives as an event; it is
/// shown once a commit answers it (or after the configure timeout).
pub fn createWindow(self: *Compositor, options: platform_mod.WindowOptions) !WindowId {
    const Ctx = struct {
        options: platform_mod.WindowOptions,
        result: anyerror!WindowId = error.OutOfMemory,
        fn run(ctx: ?*anyopaque, comp: *Compositor) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.result = comp.openWindow(s.options);
        }
    };
    var ctx: Ctx = .{ .options = options };
    try self.call(&ctx, Ctx.run);
    const id = try ctx.result;
    // The batch being delivered may hold events for an earlier window
    // with this id. (Pending ones were purged when it closed.)
    self.outbox.purgeBatch(id);
    return id;
}

/// Destroys a window. Its content comes back in `released` events;
/// other events for it are dropped.
pub fn destroyWindow(self: *Compositor, window: WindowId) Allocator.Error!void {
    try self.send(.{ .destroy_window = window });
    self.outbox.purge(window);
    self.outbox.purgeBatch(window);
}

/// Runs `func(ctx, compositor)` on the compositor thread, in order with
/// commits, and returns without waiting. `ctx` must stay valid until
/// `func` or, if the compositor is destroyed first, `destroy` runs.
pub fn post(self: *Compositor, ctx: ?*anyopaque, func: Func, destroy_ctx: ?*const fn (?*anyopaque) void) Allocator.Error!void {
    return self.send(.{ .post = .{ .func = func, .destroy = destroy_ctx, .ctx = ctx } });
}

/// Runs `func(ctx, compositor)` on the compositor thread, in order with
/// commits, and waits for it. Blocks for at most about one frame's
/// rendering. Not for use from the compositor thread.
pub fn call(self: *Compositor, ctx: ?*anyopaque, func: Func) Allocator.Error!void {
    var cl: Call = .{ .func = func, .ctx = ctx };
    if (!self.threaded) {
        // Called from inside a closure: everything before it already ran.
        if (self.draining) return func(ctx, self);
        try self.send(.{ .call = &cl });
        self.drain();
        return;
    }
    _ = c.pthread_mutex_lock(&self.mutex);
    defer _ = c.pthread_mutex_unlock(&self.mutex);
    try self.inbox.msgs.append(self.gpa, .{ .call = &cl });
    self.wakeLocked();
    while (!cl.done) _ = c.pthread_cond_wait(&self.call_done, &self.mutex);
}

fn send(self: *Compositor, msg: Msg) Allocator.Error!void {
    _ = c.pthread_mutex_lock(&self.mutex);
    defer _ = c.pthread_mutex_unlock(&self.mutex);
    try self.inbox.msgs.append(self.gpa, msg);
    self.wakeLocked();
}

fn wakeLocked(self: *Compositor) void {
    if (self.inbox_posted) return;
    self.inbox_posted = true;
    if (self.threaded) self.loop.postRemote(&self.inbox_remote) else self.loop.schedule(&self.inbox_task, .dispatch);
}

// Inbox ---------------------------------------------------------------------

fn onInboxRemote(r: *Loop.Remote) void {
    const self: *Compositor = @fieldParentPtr("inbox_remote", r);
    self.drain();
}

fn onInboxTask(t: *Loop.Task) void {
    const self: *Compositor = @fieldParentPtr("inbox_task", t);
    self.drain();
}

fn drain(self: *Compositor) void {
    self.draining = true;
    defer self.draining = false;
    _ = c.pthread_mutex_lock(&self.mutex);
    std.mem.swap(Inbox, &self.inbox, &self.processing);
    self.inbox_posted = false;
    _ = c.pthread_mutex_unlock(&self.mutex);

    const in = &self.processing;
    for (in.msgs.items) |m| switch (m) {
        .commit => |cm| self.applyCommit(cm.window, cm.seq, in.ops.items[cm.start..][0..cm.len]),
        .request_frame => |id| if (self.getWindow(id)) |w| {
            w.ui_frame = true;
            self.platform.requestFrame(id);
        },
        .destroy_window => |id| if (self.getWindow(id)) |w| {
            self.closeWindow(w);
        },
        .post => |p| p.func(p.ctx, self),
        .call => |cl| {
            cl.func(cl.ctx, self);
            _ = c.pthread_mutex_lock(&self.mutex);
            cl.done = true;
            _ = c.pthread_cond_broadcast(&self.call_done);
            _ = c.pthread_mutex_unlock(&self.mutex);
        },
        .stop => {
            _ = c.pthread_mutex_lock(&self.mutex);
            self.stopping = true;
            _ = c.pthread_mutex_unlock(&self.mutex);
        },
    };
    in.msgs.clearRetainingCapacity();
    in.ops.clearRetainingCapacity();
}

fn applyCommit(self: *Compositor, id: WindowId, seq: u64, ops: []const Op) void {
    const w = self.getWindow(id) orelse return;
    for (ops) |op| _ = w.tree.apply(op) catch {
        self.outbox.push(.{ .platform = .{ .failed = error.OutOfMemory } });
        break;
    };
    w.seq = seq;
    self.releaseAll(w.tree.trimRetired());
    self.platform.requestFrame(id);
}

// Windows -------------------------------------------------------------------

fn getWindow(self: *Compositor, id: WindowId) ?*Window {
    if (id >= self.windows.items.len) return null;
    return self.windows.items[id];
}

fn openWindow(self: *Compositor, options: platform_mod.WindowOptions) !WindowId {
    const w = try self.gpa.create(Window);
    errdefer self.gpa.destroy(w);
    const surface = try surface_mod.Surface.create(self.gpa, self.executor);
    errdefer surface.destroy();
    const id = try self.platform.createWindow(options);
    errdefer self.platform.destroyWindow(id);
    if (id >= self.windows.items.len) try self.windows.appendNTimes(self.gpa, null, id + 1 - self.windows.items.len);
    w.* = .{
        .id = id,
        .tree = .init(self.gpa),
        .tracker = .init(self.gpa),
        .surface = surface,
        .compositor = self,
    };
    self.windows.items[id] = w;
    return id;
}

fn closeWindow(self: *Compositor, w: *Window) void {
    const id = w.id;
    self.released.clearRetainingCapacity();
    w.tree.collectAll(&self.released) catch {};
    for (self.released.items) |b| self.outbox.push(.{ .released = b });
    self.platform.destroyWindow(id);
    self.freeWindow(w);
    self.windows.items[id] = null;
    self.outbox.purge(id);
    for (&self.seats) |*s| if (s.window == id) {
        s.* = .{ .mods = s.mods };
    };
}

fn freeWindow(self: *Compositor, w: *Window) void {
    self.loop.cancelTimer(&w.timer);
    w.tree.deinit();
    w.tracker.deinit();
    w.surface.destroy();
    self.gpa.destroy(w);
}

fn releaseAll(self: *Compositor, builders: []const *scene.Builder) void {
    for (builders) |b| self.outbox.push(.{ .released = b });
}

fn onWindowTimer(timer: *Timer) void {
    const w: *Window = @fieldParentPtr("timer", timer);
    w.compositor.platform.requestFrame(w.id);
}

// Platform events -----------------------------------------------------------

fn onPlatformEvent(ctx: ?*anyopaque, ev: *const platform_mod.Event) void {
    const self: *Compositor = @ptrCast(@alignCast(ctx));
    switch (ev.*) {
        .frame => |f| return self.renderFrame(f),
        .configure => |cf| {
            const w = self.getWindow(cf.window) orelse return;
            w.configure_serial += 1;
            const size: platform_mod.Size = .{ .width = cf.state.width, .height = cf.state.height };
            if (!std.meta.eql(size, w.size)) w.size_serial = w.configure_serial;
            w.size = size;
            self.outbox.push(.{ .configure = .{ .window = cf.window, .state = cf.state, .serial = w.configure_serial } });
            return;
        },
        .pointer_enter, .pointer_motion => |m| if (m.seat < max_seats) {
            self.seats[m.seat].window = m.window;
            self.seats[m.seat].pos = .{ .x = @floatCast(m.x), .y = @floatCast(m.y) };
        },
        .pointer_leave => |l| if (l.seat < max_seats) {
            self.seats[l.seat].window = null;
        },
        .modifiers => |m| if (m.seat < max_seats) {
            self.seats[m.seat].mods = m.mods;
        },
        .scroll => |s| if (self.scroll(s)) return,
        else => {},
    }
    self.outbox.push(.{ .platform = ev.* });
}

/// Scrolls a container for pointer scroll input, if one takes it.
fn scroll(self: *Compositor, s: platform_mod.Scroll) bool {
    if (s.seat >= max_seats) return false;
    const seat = &self.seats[s.seat];
    const w = self.getWindow(s.window) orelse return false;

    var delta: Point = .{ .x = @floatCast(s.dx), .y = @floatCast(s.dy) };
    if (seat.mods.shift and s.source == .wheel and delta.x == 0) delta = .{ .x = delta.y, .y = 0 };
    const gesture = s.source == .finger or s.source == .continuous;
    const stop = s.stop_x or s.stop_y;
    const time_ms: u32 = if (s.time != 0) s.time else @truncate(Loop.now() / std.time.ns_per_ms);

    const target: tree_mod.Route = if (gesture and seat.latch != null and seat.latch_window == s.window)
        seat.latch.?
    else
        w.tree.routeScroll(seat.pos, delta, seat.mods);
    if (gesture and seat.latch == null) {
        seat.latch = target;
        seat.latch_window = s.window;
        seat.velocity.reset();
    }
    const layer = switch (target) {
        .ui => {
            if (stop) seat.latch = null;
            return false;
        },
        .scroll => |id| id,
    };
    if (delta.x != 0 or delta.y != 0) {
        _ = w.tree.scrollBy(layer, delta) catch return false;
        if (gesture) seat.velocity.add(time_ms, delta);
    }
    if (gesture and stop) {
        const v = seat.velocity.velocity(time_ms);
        if (v.length() >= anim.Fling.min_start_speed) _ = w.tree.startFling(layer, v) catch {};
        seat.latch = null;
        seat.velocity.reset();
    }
    self.platform.requestFrame(s.window);
    return true;
}

fn renderFrame(self: *Compositor, f: platform_mod.Frame) void {
    const w = self.getWindow(f.window) orelse return;
    const t = f.time.present_ns;
    const next: platform_mod.FrameClock.Time = .{ .present_ns = t + f.time.interval_ns, .interval_ns = f.time.interval_ns };

    // A new size waits for the UI's layout for it, within the timeout.
    if (w.tree.acked_configure < w.size_serial and self.platform.deferConfigure(w.id)) {
        if (w.ui_frame) {
            w.ui_frame = false;
            self.outbox.push(.{ .frame = .{ .window = w.id, .time = next } });
        }
        return;
    }

    const tick = w.tree.tick(t) catch return self.outOfMemory(w);
    const state = self.platform.window(w.id);
    const vp = IRect.xywh(0, 0, @intCast(state.bufferWidth()), @intCast(state.bufferHeight()));
    const s: f32 = @floatCast(state.scale.toFloat());
    const root = raster.Affine.scale(s, s);
    const list = w.tree.compose() catch return self.outOfMemory(w);
    var damage = w.tracker.diff(w.tree.previous(), list, root, vp) catch return self.outOfMemory(w);
    const all = [_]IRect{vp};
    if (w.tree.background_changed) damage = &all;

    var presented = false;
    if (damage.len > 0 or w.ui_frame or tick.active) {
        presented = w.surface.present(self.platform, w.id, .{
            .list = list,
            .damage = damage,
            .root = root,
            .background = w.tree.background,
        }) catch |err| blk: {
            log.err("presenting window {d} failed: {t}", .{ w.id, err });
            break :blk false;
        };
        if (!presented) {
            // No buffer was free: redraw everything shortly.
            w.tree.current = null;
            self.loop.startTimer(&w.timer, Loop.now() + f.time.interval_ns / 2, 0) catch {};
        }
    }
    self.releaseAll(w.tree.endFrame());

    for (w.tree.scrolled.items) |id| {
        const l = &w.tree.layers.items[id];
        l.scrolled = false;
        self.outbox.push(.{ .scrolled = .{ .window = w.id, .layer = id, .offset = l.offset, .seq = w.seq } });
    }
    w.tree.scrolled.clearRetainingCapacity();
    for (w.tree.finished.items) |fin| {
        self.outbox.push(.{ .animation_finished = .{ .window = w.id, .layer = fin.layer, .id = fin.id, .property = fin.property } });
    }
    w.tree.finished.clearRetainingCapacity();
    if (presented) {
        w.stats.history[w.stats.frames % w.stats.history.len] = t;
        w.stats.frames += 1;
    }
    // A commit that changed nothing visible is on screen already.
    if (w.seq > w.presented_seq and (presented or damage.len == 0)) {
        w.presented_seq = w.seq;
        self.outbox.push(.{ .presented = .{ .window = w.id, .seq = w.seq, .present_ns = t } });
    }
    if (w.ui_frame) {
        w.ui_frame = false;
        self.outbox.push(.{ .frame = .{ .window = w.id, .time = next } });
    }

    if (tick.active) {
        self.platform.requestFrame(w.id);
    } else if (tick.next_start_ns) |start| {
        if (!w.timer.armed()) self.loop.startTimer(&w.timer, start -| f.time.interval_ns, 0) catch {};
    }
}

fn outOfMemory(self: *Compositor, w: *Window) void {
    w.tree.current = null;
    self.outbox.push(.{ .platform = .{ .failed = error.OutOfMemory } });
}

// Outbox --------------------------------------------------------------------

/// Events for the UI thread. Heap-allocated so that a delivery already
/// posted to the UI loop can outlive the compositor.
const Outbox = struct {
    gpa: Allocator,
    ui_loop: *Loop,
    sink: Sink,
    threaded: bool,
    mutex: c.pthread_mutex_t = .{},
    events: std.ArrayList(Event) = .empty,
    /// The batch being delivered (UI thread only).
    batch: std.ArrayList(Event) = .empty,
    cursor: usize = 0,
    delivering: bool = false,
    posted: bool = false,
    closed: bool = false,
    failed: bool = false,
    remote: Loop.Remote = .{ .func = onRemote, .cancel = onCancel },
    task: Loop.Task = .{ .func = onTask },

    fn push(o: *Outbox, ev: Event) void {
        _ = c.pthread_mutex_lock(&o.mutex);
        defer _ = c.pthread_mutex_unlock(&o.mutex);
        o.events.append(o.gpa, ev) catch {
            o.failed = true;
        };
        if (o.posted) return;
        o.posted = true;
        if (o.threaded) o.ui_loop.postRemote(&o.remote) else o.ui_loop.schedule(&o.task, .dispatch);
    }

    /// Drops undelivered events for a window, except releases. Pending
    /// events from any thread; the batch being delivered on the UI thread.
    fn purge(o: *Outbox, id: WindowId) void {
        _ = c.pthread_mutex_lock(&o.mutex);
        filter(&o.events, 0, id);
        _ = c.pthread_mutex_unlock(&o.mutex);
    }

    fn purgeBatch(o: *Outbox, id: WindowId) void {
        if (o.delivering) filter(&o.batch, o.cursor + 1, id);
    }

    fn filter(list: *std.ArrayList(Event), from: usize, id: WindowId) void {
        var keep = from;
        for (list.items[from..]) |ev| {
            if (ev.window() == id) continue;
            list.items[keep] = ev;
            keep += 1;
        }
        list.shrinkRetainingCapacity(keep);
    }

    fn deliver(o: *Outbox) void {
        _ = c.pthread_mutex_lock(&o.mutex);
        if (o.closed) {
            _ = c.pthread_mutex_unlock(&o.mutex);
            return o.free();
        }
        std.mem.swap(std.ArrayList(Event), &o.events, &o.batch);
        o.posted = false;
        const failed = o.failed;
        o.failed = false;
        _ = c.pthread_mutex_unlock(&o.mutex);
        o.delivering = true;
        o.cursor = 0;
        while (o.cursor < o.batch.items.len) : (o.cursor += 1) {
            const ev = o.batch.items[o.cursor];
            o.sink.func(o.sink.ctx, &ev);
        }
        o.delivering = false;
        o.batch.clearRetainingCapacity();
        if (failed) o.sink.func(o.sink.ctx, &.{ .platform = .{ .failed = error.OutOfMemory } });
    }

    fn onRemote(r: *Loop.Remote) void {
        const o: *Outbox = @fieldParentPtr("remote", r);
        o.deliver();
    }

    fn onCancel(r: *Loop.Remote) void {
        const o: *Outbox = @fieldParentPtr("remote", r);
        o.free();
    }

    fn onTask(t: *Loop.Task) void {
        const o: *Outbox = @fieldParentPtr("task", t);
        o.deliver();
    }

    /// The compositor is gone. A delivery already posted frees the outbox
    /// when it runs (or is cancelled); otherwise it goes now.
    fn close(o: *Outbox) void {
        if (!o.threaded) o.ui_loop.unschedule(&o.task);
        _ = c.pthread_mutex_lock(&o.mutex);
        o.closed = true;
        const pending = o.posted and o.threaded;
        _ = c.pthread_mutex_unlock(&o.mutex);
        if (!pending) o.free();
    }

    fn free(o: *Outbox) void {
        o.events.deinit(o.gpa);
        o.batch.deinit(o.gpa);
        _ = c.pthread_mutex_destroy(&o.mutex);
        o.gpa.destroy(o);
    }
};
