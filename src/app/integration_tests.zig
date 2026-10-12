//! Desktop settings against a private dbus-daemon (`zig build
//! test-integration`): a stand-in portal answers on its own thread, the
//! first frame waits for its answer (or 100 ms), values reach every
//! window and follow changes live, and the first frame's cost with
//! settings fits D25's 20 ms budget. Print the numbers with
//! SIV_MEASURE=1.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const dbus = @import("dbus");
const app_mod = @import("app.zig");
const loop_mod = @import("loop");

const Loop = loop_mod.Loop;
const App = app_mod.App;
const Settings = dbus.Settings;
const gpa = testing.allocator;

fn measuring() bool {
    return testing.environ.getPosix("SIV_MEASURE") != null;
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
}

/// dbus-daemon with a private configuration.
const Daemon = struct {
    dir_buf: [64]u8 = undefined,
    dir: [:0]const u8 = "",
    addr_buf: [96]u8 = undefined,
    address: [:0]const u8 = "",
    pid: linux.pid_t = 0,

    fn start(d: *Daemon) !void {
        d.dir = try std.fmt.bufPrintSentinel(&d.dir_buf, "/tmp/siv-app-dbus-{d}", .{linux.getpid()}, 0);
        _ = linux.mkdir(d.dir, 0o700);
        var config_buf: [128]u8 = undefined;
        const config = try std.fmt.bufPrintSentinel(&config_buf, "{s}/bus.conf", .{d.dir}, 0);
        var text_buf: [1024]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buf,
            \\<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
            \\ "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
            \\<busconfig>
            \\  <type>session</type>
            \\  <listen>unix:path={s}/bus</listen>
            \\  <auth>EXTERNAL</auth>
            \\  <policy context="default">
            \\    <allow send_destination="*" eavesdrop="true"/>
            \\    <allow eavesdrop="true"/>
            \\    <allow own="*"/>
            \\  </policy>
            \\</busconfig>
            \\
        , .{d.dir});
        const fd: i32 = @intCast(linux.open(config, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600));
        if (fd < 0) return error.WriteFailed;
        _ = linux.write(fd, text.ptr, text.len);
        _ = linux.close(fd);
        d.address = try std.fmt.bufPrintSentinel(&d.addr_buf, "unix:path={s}/bus", .{d.dir}, 0);
        var arg_buf: [160]u8 = undefined;
        const config_arg = try std.fmt.bufPrintSentinel(&arg_buf, "--config-file={s}", .{config}, 0);
        const argv = [_:null]?[*:0]const u8{ "dbus-daemon", "--nofork", "--nopidfile", config_arg };
        const envp = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
        const pid = std.c.fork();
        if (pid == 0) {
            _ = std.c.execve("/usr/bin/dbus-daemon", &argv, &envp);
            std.c._exit(127);
        }
        if (pid < 0) return error.SpawnFailed;
        d.pid = pid;
        var waited: u32 = 0;
        while (linux.access(d.address["unix:path=".len..], 0) != 0) : (waited += 1) {
            if (waited > 500) return error.DbusDaemonDidNotStart;
            sleepMs(10);
        }
    }

    fn stop(d: *Daemon) void {
        if (d.pid != 0) {
            _ = std.c.kill(d.pid, .TERM);
            var status: c_int = 0;
            _ = std.c.waitpid(d.pid, &status, 0);
        }
        var path_buf: [128]u8 = undefined;
        for ([_][]const u8{ "bus", "bus.conf" }) |name| {
            const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ d.dir, name }, 0) catch continue;
            _ = linux.unlink(path);
        }
        _ = linux.rmdir(d.dir);
    }
};

/// A stand-in for xdg-desktop-portal's Settings, on a thread of its own.
const Portal = struct {
    loop: Loop = undefined,
    conn: dbus.Connection = undefined,
    owner: dbus.Connection.NameOwner = .{ .name = Settings.portal_name },
    obj: dbus.Object = undefined,
    thread: std.Thread = undefined,
    stop_flag: std.atomic.Value(bool) = .init(false),
    /// Never answer ReadAll (a portal being activated).
    silent: bool = false,
    reduced_motion: std.atomic.Value(u32) = .init(1),

    const iface: dbus.Interface = .{
        .name = Settings.portal_interface,
        .methods = &.{.{ .name = "ReadAll", .in = "as", .out = "a{sa{sv}}", .func = readAll }},
        .signals = &.{.{ .name = "SettingChanged", .signature = "ssv" }},
    };

    fn start(p: *Portal, address: []const u8) !void {
        p.loop = try Loop.init(std.heap.smp_allocator);
        try p.conn.init(std.heap.smp_allocator, &p.loop, address, .{});
        p.obj = .{ .path = Settings.portal_path, .ctx = p, .interfaces = &.{&iface} };
        try p.conn.exportObject(&p.obj);
        try p.conn.requestName(&p.owner);
        while (p.owner.state != .primary) try p.loop.dispatch(10);
        p.thread = try std.Thread.spawn(.{}, run, .{p});
    }

    fn run(p: *Portal) void {
        while (!p.stop_flag.load(.acquire)) p.loop.dispatch(-1) catch return;
    }

    fn stop(p: *Portal) void {
        p.stop_flag.store(true, .release);
        p.loop.wake();
        p.thread.join();
        p.conn.deinit();
        p.loop.deinit();
    }

    fn readAll(r: *dbus.Request) anyerror!void {
        const p: *Portal = @ptrCast(@alignCast(r.node.ctx));
        if (p.silent) {
            _ = r.deferReply();
            return;
        }
        var b = r.newReply();
        errdefer b.deinit();
        try b.body.beginArray("{sa{sv}}");
        try b.body.beginDictEntry();
        try b.body.writeString("org.freedesktop.appearance");
        try b.body.beginArray("{sv}");
        try b.body.beginDictEntry();
        try b.body.writeString("reduced-motion");
        try b.body.write(dbus.variant(p.reduced_motion.load(.acquire)));
        try b.body.endDictEntry();
        try b.body.beginDictEntry();
        try b.body.writeString("accent-color");
        try b.body.write(dbus.variant(.{ @as(f64, 0.2), @as(f64, 0.4), @as(f64, 0.8) }));
        try b.body.endDictEntry();
        try b.body.endArray();
        try b.body.endDictEntry();
        try b.body.beginDictEntry();
        try b.body.writeString("org.gnome.desktop.interface");
        try b.body.beginArray("{sv}");
        try b.body.beginDictEntry();
        try b.body.writeString("font-name");
        try b.body.write(dbus.variant(@as([]const u8, "Droid Sans 11")));
        try b.body.endDictEntry();
        try b.body.beginDictEntry();
        try b.body.writeString("text-scaling-factor");
        try b.body.write(dbus.variant(@as(f64, 1.25)));
        try b.body.endDictEntry();
        try b.body.endArray();
        try b.body.endDictEntry();
        try b.body.endArray();
        try r.sendReply(&b);
    }

    /// Emits SettingChanged for reduced-motion, from the portal's thread.
    fn changeReducedMotion(p: *Portal, value: u32) !void {
        p.reduced_motion.store(value, .release);
        const Ctx = struct {
            fn run(ctx: ?*anyopaque) void {
                const portal: *Portal = @ptrCast(@alignCast(ctx));
                var b = portal.conn.signal(Settings.portal_path, Settings.portal_interface, "SettingChanged");
                b.body.writeAll(.{ "org.freedesktop.appearance", "reduced-motion" }) catch return b.deinit();
                b.body.write(dbus.variant(portal.reduced_motion.load(.acquire))) catch return b.deinit();
                _ = portal.conn.send(&b) catch {};
            }
        };
        try p.loop.post(Ctx.run, null, p);
    }
};

const Started = struct { app: *App, win: *app_mod.Window, t0: u64 };

fn open(address: ?[]const u8, settings: bool) !Started {
    const t0 = Loop.now();
    const app = try App.create(gpa, .{
        .backend = .headless,
        .headless = .{ .refresh_ns = std.time.ns_per_ms },
        .system_fonts = false,
        .threads = 2,
        .desktop_settings = settings,
        .bus_address = address,
    });
    errdefer app.destroy();
    const win = try app.createWindow(.{ .width = 64, .height = 48 }, .{});
    const txn = try win.ui.begin();
    try txn.setVisual(.root, .{ .background = .white });
    txn.commit();
    return .{ .app = app, .win = win, .t0 = t0 };
}

/// Dispatches until the first frame is presented; returns its time since
/// `t0`.
fn firstFrame(s: Started) !u64 {
    const deadline = s.t0 + 5 * std.time.ns_per_s;
    while (s.win.presented_seq == 0) {
        if (Loop.now() > deadline) return error.Timeout;
        try s.app.dispatch(1);
    }
    return Loop.now() - s.t0;
}

fn median(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

test "desktop settings reach the first frame within the budget and follow changes" {
    var daemon: Daemon = .{};
    try daemon.start();
    defer daemon.stop();
    var portal: Portal = .{};
    try portal.start(daemon.address);
    defer portal.stop();

    // The first frame shows the portal's values.
    {
        const s = try open(daemon.address, true);
        defer s.app.destroy();
        _ = try firstFrame(s);
        try testing.expect(s.app.desktop.ready_ns != null);
        try testing.expect(s.win.ui.desktop.reduced_motion);
        try testing.expectEqual(@as(?[3]f64, .{ 0.2, 0.4, 0.8 }), s.win.ui.desktop.accent_color);
        try testing.expectEqual(@as(f64, 1.25), s.win.ui.desktop.text_scale);
        try testing.expectEqualStrings("Droid Sans", s.app.fonts.name(s.app.fonts.default_family));

        // Changes apply live to every window, new ones included.
        try portal.changeReducedMotion(0);
        const deadline = Loop.now() + 5 * std.time.ns_per_s;
        while (s.win.ui.desktop.reduced_motion) {
            if (Loop.now() > deadline) return error.Timeout;
            try s.app.dispatch(5);
        }
        try testing.expect(!s.win.ui.reducedMotion());
        const second = try s.app.createWindow(.{ .width = 32, .height = 32 }, .{});
        try testing.expectEqual(@as(f64, 1.25), second.ui.desktop.text_scale);
        // The application's own choices win over the desktop's.
        try s.app.setDefaultFont("Other");
        try portal.changeReducedMotion(1);
        while (!s.win.ui.desktop.reduced_motion) {
            if (Loop.now() > deadline) return error.Timeout;
            try s.app.dispatch(5);
        }
        try testing.expectEqualStrings("Other", s.app.fonts.name(s.app.fonts.default_family));
    }

    // D25: the first frame with settings costs about what it costs
    // without them.
    var with: [15]u64 = undefined;
    var without: [15]u64 = undefined;
    var ready: [15]u64 = undefined;
    for (&with, &without, &ready) |*w, *wo, *r| {
        const a = try open(daemon.address, true);
        w.* = try firstFrame(a);
        r.* = a.app.desktop.ready_ns.? - a.app.desktop.started_ns;
        a.app.destroy();
        const b = try open(null, false);
        wo.* = try firstFrame(b);
        b.app.destroy();
    }
    const m_with = median(&with);
    const m_without = median(&without);
    const m_ready = median(&ready);
    if (measuring()) std.debug.print("\nfirst frame from App.create: median {d} us with settings (ready after {d} us), {d} us without\n", .{ m_with / 1000, m_ready / 1000, m_without / 1000 });
    try testing.expect(m_with < 20 * std.time.ns_per_ms);
}

test "a portal that does not answer delays the first frame by at most 100 ms" {
    var daemon: Daemon = .{};
    try daemon.start();
    defer daemon.stop();
    var portal: Portal = .{ .silent = true };
    try portal.start(daemon.address);
    defer portal.stop();

    const s = try open(daemon.address, true);
    defer s.app.destroy();
    const t = try firstFrame(s);
    if (measuring()) std.debug.print("\nfirst frame with a silent portal: {d} us\n", .{t / 1000});
    try testing.expect(t >= 100 * std.time.ns_per_ms);
    try testing.expect(t < 400 * std.time.ns_per_ms);
    try testing.expect(s.app.desktop.ready_ns == null);
    // The defaults are in effect.
    try testing.expect(!s.win.ui.desktop.reduced_motion);
}

test "without a bus there is nothing to wait for" {
    const s = try open("unix:path=/nonexistent/siv-bus", true);
    defer s.app.destroy();
    const t = try firstFrame(s);
    try testing.expect(!s.app.desktop.connected);
    try testing.expect(t < 100 * std.time.ns_per_ms);
}
