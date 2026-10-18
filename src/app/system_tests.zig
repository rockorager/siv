//! System signals in the coordinator (D42): stand-in portals on a test
//! bus on a thread of its own, and what siv does with the signals.

const std = @import("std");
const testing = std.testing;
const dbus = @import("dbus");
const portal = @import("portal");
const app_mod = @import("app.zig");

const App = app_mod.App;
const Loop = @import("loop").Loop;
const System = portal.testing.System;

const BusThread = struct {
    loop: Loop = undefined,
    bus: dbus.testing.TestBus = undefined,
    conn: dbus.Connection = undefined,
    stand: System = undefined,
    thread: std.Thread = undefined,
    stop_flag: std.atomic.Value(bool) = .init(false),
    running: bool = false,

    /// Starts the bus with `stand` and returns a socket for the
    /// application's session bus and one for its system bus.
    fn start(b: *BusThread, stand: System) ![2]i32 {
        b.loop = try Loop.init(std.heap.smp_allocator);
        b.bus = .init(testing.allocator, &b.loop);
        try b.conn.initFd(testing.allocator, &b.loop, try b.bus.connect(), .{});
        b.stand = stand;
        b.stand.conn = &b.conn;
        try b.stand.start();
        while (!b.stand.owns()) try b.loop.dispatch(10);
        const fds: [2]i32 = .{ try b.bus.connect(), try b.bus.connect() };
        try b.resume_();
        return fds;
    }

    fn resume_(b: *BusThread) !void {
        b.stop_flag.store(false, .release);
        b.thread = try std.Thread.spawn(.{}, run, .{b});
        b.running = true;
    }

    fn run(b: *BusThread) void {
        while (!b.stop_flag.load(.acquire)) b.loop.dispatch(-1) catch return;
    }

    fn stop(b: *BusThread) void {
        if (!b.running) return;
        b.running = false;
        b.stop_flag.store(true, .release);
        b.loop.wake();
        b.thread.join();
    }

    /// Runs `func` on the stand-in with the bus thread stopped.
    fn emit(b: *BusThread, comptime func: anytype, args: anytype) !void {
        b.stop();
        try @call(.auto, func, .{&b.stand} ++ args);
        b.conn.flush();
        try b.loop.dispatch(0);
        try b.resume_();
    }

    fn deinit(b: *BusThread) void {
        b.stop();
        b.stand.deinit();
        b.conn.deinit();
        b.bus.deinit();
        b.loop.deinit();
    }
};

fn runUntil(app: *App, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (!cond(ctx)) {
        if (Loop.now() > deadline) return error.Timeout;
        try app.dispatch(5);
    }
}

const Heard = struct {
    changes: std.ArrayList(app_mod.system.Change) = .empty,

    fn cb(ctx: ?*anyopaque, c: app_mod.system.Change) void {
        const h: *Heard = @ptrCast(@alignCast(ctx));
        h.changes.append(testing.allocator, c) catch unreachable;
    }
};

test "power saving stops caret blinking; memory warnings trim caches; the application hears both" {
    var bt: BusThread = .{};
    const fds = try bt.start(.{ .conn = undefined, .power_saver = true });
    defer bt.deinit();
    const app = try App.create(testing.allocator, .{
        .backend = .headless,
        .system_fonts = false,
        .threads = 2,
        .desktop_settings = false,
        .accessibility = false,
        .bus_fd = fds[0],
        .system_signals = true,
        .system_bus_fd = fds[1],
    });
    defer app.destroy();
    var heard: Heard = .{};
    defer heard.changes.deinit(testing.allocator);
    app.system.listener = .{ .ctx = &heard, .func = Heard.cb };
    const win = try app.createWindow(.{}, .{});
    try testing.expect(win.ui.desktop.cursor_blink);

    try runUntil(app, &app.system, app_mod.system.System.powerSaver);
    try testing.expect(!app.desktop.values.cursor_blink);
    try testing.expect(!win.ui.desktop.cursor_blink);
    // Reduced motion is the user's, not power's.
    try testing.expect(!win.ui.reducedMotion());
    // New windows start with it.
    const other = try app.createWindow(.{}, .{});
    try testing.expect(!other.ui.desktop.cursor_blink);

    try bt.emit(System.setPowerSaver, .{false});
    try runUntil(app, &app.system, struct {
        fn f(s: *app_mod.system.System) bool {
            return !s.powerSaver();
        }
    }.f);
    try testing.expect(win.ui.desktop.cursor_blink);

    try bt.emit(System.warnMemory, .{@as(u8, 100)});
    try runUntil(app, &app.system, struct {
        fn f(s: *app_mod.system.System) bool {
            return s.trims == 1;
        }
    }.f);
    try testing.expectEqual(@as(usize, 3), heard.changes.items.len);
    try testing.expectEqual(app_mod.system.Change{ .power_saver = true }, heard.changes.items[0]);
    try testing.expectEqual(app_mod.system.Change{ .power_saver = false }, heard.changes.items[1]);
    try testing.expectEqual(app_mod.system.Change{ .memory = .medium }, heard.changes.items[2]);
}

test "without system signals nothing is asked and the defaults stand" {
    var bt: BusThread = .{};
    const fds = try bt.start(.{ .conn = undefined, .power_saver = true });
    defer bt.deinit();
    const app = try App.create(testing.allocator, .{
        .backend = .headless,
        .system_fonts = false,
        .threads = 1,
        .desktop_settings = false,
        .accessibility = false,
        .bus_fd = fds[0],
        .system_bus_fd = fds[1],
    });
    defer app.destroy();
    for (0..20) |_| try app.dispatch(5);
    try testing.expect(!app.system.running);
    try testing.expect(!app.system.powerSaver());
    try testing.expectEqual(app_mod.system.Network{}, app.system.network());
}
