//! The UI side of a compositor for headless tests: a UI loop, the
//! application worker pool, builders that come back in `released`
//! events, and automatic configure acks.

const std = @import("std");
const scene = @import("scene");
const pool = @import("pool");
const loop_mod = @import("loop");
const platform = @import("platform");
const compositor = @import("compositor");

const Loop = loop_mod.Loop;
const Event = compositor.Event;
const Compositor = compositor.Compositor;
const testing = std.testing;

pub const Ui = struct {
    gpa: std.mem.Allocator = testing.allocator,
    loop: Loop = undefined,
    workers: pool.Pool = undefined,
    comp: *Compositor = undefined,
    events: std.ArrayList(Event) = .empty,
    builders: [32]scene.Builder = undefined,
    free: std.ArrayList(*scene.Builder) = .empty,
    /// Answer every configure with an ack (the scenes do not depend on
    /// the window size).
    auto_ack: bool = true,
    /// Last commit sequence number per window.
    seqs: [8]u64 = @splat(0),
    /// Called for every event, after recording it.
    hook: ?*const fn (ui: *Ui, ev: *const Event) void = null,

    pub fn start(ui: *Ui, thread: bool, backend: compositor.Backend) !void {
        ui.loop = try Loop.init(ui.gpa);
        ui.workers = pool.Pool.init(ui.gpa, 3);
        for (&ui.builders) |*b| {
            b.* = .init(ui.gpa);
            try ui.free.append(ui.gpa, b);
        }
        ui.comp = try Compositor.create(.{
            .allocator = ui.gpa,
            .executor = ui.workers.executor(),
            .ui_loop = &ui.loop,
            .sink = .{ .ctx = ui, .func = onEvent },
            .backend = backend,
            .thread = thread,
        });
    }

    pub fn stop(ui: *Ui) void {
        ui.comp.destroy();
        ui.workers.deinit();
        ui.loop.deinit();
        for (&ui.builders) |*b| b.deinit();
        ui.free.deinit(ui.gpa);
        ui.events.deinit(ui.gpa);
    }

    fn onEvent(ctx: ?*anyopaque, ev: *const Event) void {
        const ui: *Ui = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .released => |b| ui.free.append(ui.gpa, b) catch unreachable,
            .configure => |c| if (ui.auto_ack) {
                _ = ui.commit(c.window, &.{.{ .ack_configure = c.serial }}) catch unreachable;
            },
            .platform => |p| if (p == .failed) std.debug.panic("platform failed: {t}", .{p.failed}),
            else => {},
        }
        ui.events.append(ui.gpa, ev.*) catch unreachable;
        if (ui.hook) |h| h(ui, ev);
    }

    pub fn commit(ui: *Ui, window: platform.WindowId, ops: []const compositor.Op) !u64 {
        const seq = try ui.comp.commit(window, ops);
        ui.seqs[window] = seq;
        return seq;
    }

    /// Dispatches until everything committed to `window` was presented.
    pub fn waitSettled(ui: *Ui, window: platform.WindowId) !void {
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        while (true) {
            var done = false;
            for (ui.events.items) |e| if (e == .presented and e.presented.window == window and e.presented.seq >= ui.seqs[window]) {
                done = true;
            };
            if (done) return;
            if (Loop.now() > deadline) return error.Timeout;
            try ui.loop.dispatch(5);
        }
    }

    pub fn builder(ui: *Ui) *scene.Builder {
        const b = ui.free.pop() orelse @panic("out of builders");
        b.reset();
        return b;
    }

    pub fn content(b: *scene.Builder) !compositor.Content {
        return .{ .list = try b.finish(0), .builder = b };
    }

    pub fn count(ui: *const Ui, tag: std.meta.Tag(Event)) usize {
        var n: usize = 0;
        for (ui.events.items) |e| n += @intFromBool(e == tag);
        return n;
    }

    pub fn countFor(ui: *const Ui, tag: std.meta.Tag(Event), window: platform.WindowId) usize {
        var n: usize = 0;
        for (ui.events.items) |e| n += @intFromBool(e == tag and e.window() == window);
        return n;
    }

    pub fn last(ui: *const Ui, tag: std.meta.Tag(Event)) ?Event {
        var i = ui.events.items.len;
        while (i > 0) {
            i -= 1;
            if (ui.events.items[i] == tag) return ui.events.items[i];
        }
        return null;
    }

    /// Dispatches the UI loop until `cond(ctx)`.
    pub fn run(ui: *Ui, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        while (!cond(ctx)) {
            if (Loop.now() > deadline) return error.Timeout;
            try ui.loop.dispatch(5);
        }
    }

    /// The window's presented pixels as RGBA (headless backend).
    pub fn capture(ui: *Ui, window: platform.WindowId) ![]u8 {
        const Ctx = struct {
            gpa: std.mem.Allocator,
            window: platform.WindowId,
            out: anyerror![]u8 = error.NothingPresented,
            width: u32 = 0,
            fn f(ctx: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(ctx));
                const img = comp.platform.headless.presented(s.window) orelse return;
                const out = s.gpa.alloc(u8, @as(usize, img.width) * img.height * 4) catch |e| {
                    s.out = e;
                    return;
                };
                for (0..img.height) |y| for (0..img.width) |x| {
                    const p = img.pixels[y * img.stride + x * 4 ..][0..4];
                    out[(y * img.width + x) * 4 ..][0..4].* = .{ p[2], p[1], p[0], p[3] };
                };
                s.out = out;
                s.width = img.width;
            }
        };
        var ctx: Ctx = .{ .gpa = ui.gpa, .window = window };
        try ui.comp.call(&ctx, Ctx.f);
        return ctx.out;
    }
};
