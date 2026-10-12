//! The session bus against a private dbus-daemon (`zig build
//! test-integration`). Desktop settings: a stand-in portal answers on its
//! own thread, the first frame waits for its answer (or 100 ms), values
//! reach every window and follow changes live, and the first frame's cost
//! with settings fits D25's 20 ms budget (print the numbers with
//! SIV_MEASURE=1). Accessibility: libatspi, through the real AT-SPI
//! registry, finds the application's windows and acts on them.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const dbus = @import("dbus");
const app_mod = @import("app.zig");
const loop_mod = @import("loop");

const Loop = loop_mod.Loop;
const App = app_mod.App;
const Settings = dbus.Settings;
const td = dbus.testing.daemon;
const Daemon = td.Daemon;
const gpa = testing.allocator;

fn measuring() bool {
    return testing.environ.getPosix("SIV_MEASURE") != null;
}

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
        .accessibility = false,
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

const atspi_script =
    \\import sys, time, pyatspi
    \\name = sys.argv[1]
    \\def find():
    \\    for a in pyatspi.Registry.getDesktop(0):
    \\        if a is not None and a.name == name:
    \\            return a
    \\app = None
    \\for i in range(250):
    \\    app = find()
    \\    if app: break
    \\    time.sleep(0.02)
    \\if not app:
    \\    print("NOAPP", flush=True); sys.exit(1)
    \\def role(o):
    \\    # Newer libatspi (2.60) names ATSPI_ROLE_PUSH_BUTTON "button".
    \\    r = o.getRoleName()
    \\    return "push button" if r == "button" else r
    \\print("APP", role(app), app.get_toolkit_name(), flush=True)
    \\for w in app:
    \\    print("WINDOW", role(w), repr(w.name), flush=True)
    \\    for c in w: print("CHILD", role(c), repr(c.name), flush=True)
    \\b = pyatspi.findDescendant(app, lambda x: role(x) == "push button")
    \\print("ACTION", b.queryAction().doAction(0), flush=True)
    \\print("DONE", flush=True)
    \\
;

fn onClick(user: ?*anyopaque, _: *@import("ui").Window, _: @import("ui").NodeId, _: *const @import("ui").Event) bool {
    const clicks: *u32 = @ptrCast(@alignCast(user));
    clicks.* += 1;
    return true;
}

test "assistive technology finds the application's windows and acts on them" {
    var daemon: Daemon = .{};
    try daemon.start();
    defer daemon.stop();
    var env_bufs: [2][192]u8 = undefined;
    var env: [5:null]?[*:0]const u8 = @splat(null);
    env[0] = try std.fmt.bufPrintSentinel(&env_bufs[0], "DBUS_SESSION_BUS_ADDRESS={s}", .{daemon.address}, 0);
    env[1] = try std.fmt.bufPrintSentinel(&env_bufs[1], "XDG_RUNTIME_DIR={s}", .{daemon.dir}, 0);
    env[2] = "PATH=/usr/bin:/bin";
    env[3] = "GSETTINGS_BACKEND=memory";
    env[4] = "ATSPI_DBUS_IMPLEMENTATION=dbus-daemon"; // not dbus-broker (Arch's default), which needs systemd
    var launcher_buf: [64]u8 = undefined;
    const launcher = td.findLibexec(&launcher_buf, "at-spi-bus-launcher") orelse return error.AtspiNotInstalled;
    const launcher_pid = try td.spawn(launcher, &[_:null]?[*:0]const u8{ launcher, "--launch-immediately" }, &env, null);
    defer td.kill(launcher_pid);

    const app = try App.create(gpa, .{
        .backend = .headless,
        .headless = .{ .refresh_ns = std.time.ns_per_ms },
        .system_fonts = false,
        .threads = 2,
        .desktop_settings = false,
        .bus_address = daemon.address,
        .name = "siv-app-a11y-test",
        .toolkit_version = "0.1",
    });
    defer app.destroy();
    try testing.expect(app.accessible);
    try app.addFont("Droid", @import("text").font.test_fonts.latin);
    try app.setDefaultFont("Droid");
    const win = try app.createWindow(.{ .title = "Hello window", .width = 120, .height = 80 }, .{});
    var clicks: u32 = 0;
    const t = try win.ui.begin();
    const button = try t.create(.root, .box, .none);
    try t.setSemantics(button, .{ .role = .button, .focusable = true });
    try t.on(button, .activate, .{ .func = onClick, .user = &clicks });
    const label = try t.create(button, .text, .none);
    try t.setText(label, "OK");
    t.commit();

    // Turn accessibility on as a screen reader would, once the launcher
    // owns its name.
    var deadline = Loop.now() + 5 * std.time.ns_per_s;
    while (!app.bridge.active()) {
        if (Loop.now() > deadline) return error.Timeout;
        var b = app.desktop.bus.methodCall("org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties", "Set");
        try b.body.writeAll(.{ "org.a11y.Status", "IsEnabled", dbus.variant(true) });
        _ = try app.desktop.bus.send(&b);
        const until = Loop.now() + 100 * std.time.ns_per_ms;
        while (Loop.now() < until and !app.bridge.active()) try app.dispatch(10);
    }

    var path_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrintSentinel(&path_buf, "{s}/client.py", .{daemon.dir}, 0);
    try td.writeFile(script, atspi_script);
    var fds: [2]i32 = undefined;
    _ = linux.pipe2(&fds, .{ .CLOEXEC = true });
    const pid = try td.spawn("/usr/bin/python3", &[_:null]?[*:0]const u8{ "/usr/bin/python3", script, "siv-app-a11y-test" }, &env, fds[1]);
    defer td.kill(pid);
    _ = linux.close(fds[1]);
    defer _ = linux.close(fds[0]);
    _ = linux.fcntl(fds[0], linux.F.SETFL, linux.SOCK.NONBLOCK);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    deadline = Loop.now() + 20 * std.time.ns_per_s;
    while (true) {
        if (Loop.now() > deadline) return error.Timeout;
        try app.dispatch(10);
        var buf: [4096]u8 = undefined;
        const n = linux.read(fds[0], &buf, buf.len);
        if (linux.errno(n) == .AGAIN) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    for ([_][]const u8{
        "APP application siv",
        "WINDOW frame 'Hello window'",
        "CHILD push button 'OK'",
        "ACTION True",
        "DONE",
    }) |want| if (std.mem.indexOf(u8, out.items, want) == null) {
        std.debug.print("missing {s} in client output:\n{s}\n", .{ want, out.items });
        return error.TestExpectedEqual;
    };
    // The action ran in a dispatch at a safe point.
    deadline = Loop.now() + 5 * std.time.ns_per_s;
    while (clicks == 0) {
        if (Loop.now() > deadline) return error.Timeout;
        try app.dispatch(10);
    }
    try testing.expectEqual(1, clicks);
}
