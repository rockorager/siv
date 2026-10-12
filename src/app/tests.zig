//! The coordinator on the headless backend: the real loop, worker pool,
//! and compositor thread, with events injected into the platform.

const std = @import("std");
const testing = std.testing;
const platform = @import("platform");
const compositor = @import("compositor");
const ui = @import("ui");
const app_mod = @import("app.zig");

const App = app_mod.App;
const Window = app_mod.Window;
const Loop = @import("loop").Loop;

fn create(thread: bool) !*App {
    return App.create(testing.allocator, .{
        .backend = .headless,
        .headless = .{ .refresh_ns = std.time.ns_per_ms },
        .system_fonts = false,
        .threads = 2,
        .compositor_thread = thread,
        .desktop_settings = false,
        .accessibility = false,
    });
}

/// Dispatches until `cond(ctx)`.
fn runUntil(app: *App, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (!cond(ctx)) {
        if (Loop.now() > deadline) return error.Timeout;
        try app.dispatch(5);
    }
}

fn settled(win: *Window) bool {
    return win.presented_seq > 0 and win.settled();
}

/// Runs `func(headless, id)` on the compositor thread.
fn onHeadless(app: *App, id: platform.WindowId, comptime func: fn (*platform.Headless, platform.WindowId) void) !void {
    const Ctx = struct {
        id: platform.WindowId,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            func(comp.platform.headless, c.id);
        }
    };
    var ctx: Ctx = .{ .id = id };
    try app.comp.call(&ctx, Ctx.run);
}

/// The top-left pixel of the presented frame, as B, G, R, A.
fn firstPixel(app: *App, id: platform.WindowId) ![4]u8 {
    const Ctx = struct {
        id: platform.WindowId,
        out: ?[4]u8 = null,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            const img = comp.platform.headless.presented(c.id) orelse return;
            c.out = img.pixels[0..4].*;
        }
    };
    var ctx: Ctx = .{ .id = id };
    try app.comp.call(&ctx, Ctx.run);
    return ctx.out orelse error.NothingPresented;
}

test "a window presents its tree, on and off the compositor thread" {
    for ([_]bool{ true, false }) |thread| {
        const app = try create(thread);
        defer app.destroy();
        const win = try app.createWindow(.{ .width = 64, .height = 48 }, .{});
        const t = try win.ui.begin();
        try t.setVisual(.root, .{ .background = .srgb8(0xff, 0x00, 0x00, 0xff) });
        t.commit();
        try runUntil(app, win, settled);
        try testing.expectEqual([4]u8{ 0, 0, 0xff, 0xff }, try firstPixel(app, win.id));
    }
}

const Recorder = struct {
    closes: usize = 0,
    configures: usize = 0,
    last: platform.WindowState = .{},
    keep_open: bool = false,

    fn listener(r: *Recorder) app_mod.Listener {
        return .{ .ctx = r, .func = onEvent };
    }

    fn onEvent(ctx: ?*anyopaque, _: *Window, ev: *const app_mod.WindowEvent) bool {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .close_requested => r.closes += 1,
            .configure => |c| {
                r.configures += 1;
                r.last = c.new;
            },
            .external_released, .external_configure => {},
        }
        return r.keep_open;
    }
};

test "configures reach the listener; an unhandled close request destroys the window and ends run" {
    const app = try create(true);
    defer app.destroy();
    var rec: Recorder = .{ .keep_open = true };
    const win = try app.createWindow(.{ .width = 64, .height = 48 }, rec.listener());
    try runUntil(app, win, settled);
    try testing.expect(rec.configures >= 1);
    try testing.expectEqual(@as(u32, 64), rec.last.width);

    try onHeadless(app, win.id, struct {
        fn f(hl: *platform.Headless, id: platform.WindowId) void {
            hl.configure(id, .{ .width = 100, .height = 30 }, null);
        }
    }.f);
    try runUntil(app, &rec, struct {
        fn f(r: *Recorder) bool {
            return r.last.width == 100;
        }
    }.f);
    try testing.expectEqual(@as(f32, 100), win.ui.width);

    // Handled: the window stays.
    try onHeadless(app, win.id, platform.Headless.requestClose);
    try runUntil(app, &rec, struct {
        fn f(r: *Recorder) bool {
            return r.closes == 1;
        }
    }.f);
    try testing.expectEqual(1, app.open_windows);

    // Unhandled: destroyed, and run returns with no windows left.
    rec.keep_open = false;
    try onHeadless(app, win.id, platform.Headless.requestClose);
    try app.run();
    try testing.expectEqual(2, rec.closes);
    try testing.expectEqual(0, app.open_windows);
}

test "a window destroyed from its own event handler lives until its lists come back" {
    const app = try create(true);
    defer app.destroy();
    const win = try app.createWindow(.{ .width = 64, .height = 48 }, .{});
    const Handler = struct {
        fn onActivate(user: ?*anyopaque, _: *ui.Window, _: ui.NodeId, _: *const ui.Event) bool {
            const w: *Window = @ptrCast(@alignCast(user));
            w.destroy() catch unreachable;
            return true;
        }
    };
    const t = try win.ui.begin();
    const button = try t.create(.root, .box, .none);
    try t.setVisual(button, .{ .background = .black });
    try t.on(button, .activate, .{ .func = Handler.onActivate, .user = win });
    t.commit();
    try runUntil(app, win, settled);

    try onHeadless(app, win.id, struct {
        fn f(hl: *platform.Headless, id: platform.WindowId) void {
            hl.inject(.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 10, .y = 10 } });
            hl.inject(.{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 1 } });
            hl.inject(.{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 2 } });
        }
    }.f);
    try app.run();
    try testing.expectEqual(0, app.open_windows);
    try runUntil(app, app, struct {
        fn f(a: *App) bool {
            return a.zombies.items.len == 0;
        }
    }.f);
}

test "posted closures run on the loop thread, then their destroy; at teardown only destroy" {
    const Counts = struct {
        runs: std.atomic.Value(u32) = .init(0),
        destroys: std.atomic.Value(u32) = .init(0),
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            _ = c.runs.fetchAdd(1, .seq_cst);
        }
        fn destroy(ctx: ?*anyopaque) callconv(.c) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            _ = c.destroys.fetchAdd(1, .seq_cst);
        }
    };
    var counts: Counts = .{};
    {
        const app = try create(true);
        defer app.destroy();
        const Poster = struct {
            fn post(a: *App, c: *Counts) void {
                for (0..100) |_| a.post(Counts.run, Counts.destroy, c) catch unreachable;
            }
        };
        const thread = try std.Thread.spawn(.{}, Poster.post, .{ app, &counts });
        thread.join();
        try runUntil(app, &counts, struct {
            fn f(c: *Counts) bool {
                return c.runs.load(.seq_cst) == 100;
            }
        }.f);
        try testing.expectEqual(100, counts.destroys.load(.seq_cst));
        // Never dispatched: destroyed with the application.
        try app.post(Counts.run, Counts.destroy, &counts);
    }
    try testing.expectEqual(100, counts.runs.load(.seq_cst));
    try testing.expectEqual(101, counts.destroys.load(.seq_cst));
}
