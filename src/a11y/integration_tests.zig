//! Integration tests against the real AT-SPI stack (`zig build
//! test-integration-a11y`): a private session bus, at-spi-bus-launcher
//! with its accessibility bus and at-spi2-registryd, and libatspi through
//! pyatspi as the assistive technology. The bridge discovers the bus
//! through org.a11y.Bus once IsEnabled turns on, as in a desktop session.
//! A second test runs Orca on headless sway and checks what it speaks.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const dbus = @import("dbus");
const ui = @import("ui");
const Loop = @import("loop").Loop;
const Bridge = @import("Bridge.zig");
const Fixture = @import("test_fixture.zig");

const Connection = dbus.Connection;
const td = dbus.testing.daemon;
const gpa = testing.allocator;

const client_script =
    \\import sys, time, pyatspi
    \\from gi.repository import GLib
    \\name = sys.argv[1]
    \\def find():
    \\    d = pyatspi.Registry.getDesktop(0)
    \\    for a in d:
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
    \\def dump(o, depth):
    \\    st = sorted(pyatspi.stateToString(s) for s in o.getState().getStates())
    \\    print("NODE", depth, role(o), repr(o.name), ",".join(st), ",".join(o.get_interfaces()), flush=True)
    \\    for c in o: dump(c, depth + 1)
    \\dump(app, 0)
    \\def find_role(r):
    \\    return pyatspi.findDescendant(app, lambda x: role(x) == r)
    \\b = find_role("push button")
    \\a = b.queryAction()
    \\print("ACTION", a.getName(0), a.doAction(0), flush=True)
    \\lab = pyatspi.findDescendant(app, lambda x: x.getRoleName() == "label" and x.name.startswith("Hello"))
    \\t = lab.queryText()
    \\print("TEXT", repr(t.getText(0, -1)), t.characterCount, repr(t.getTextAtOffset(7, pyatspi.TEXT_BOUNDARY_WORD_START)), flush=True)
    \\e = lab.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
    \\c0 = t.getCharacterExtents(0, pyatspi.WINDOW_COORDS)
    \\c5 = t.getCharacterExtents(5, pyatspi.WINDOW_COORDS)
    \\print("EXTENTS", e.width > 0 and e.height > 0, c5[0] > c0[0] and c0[2] > 0, flush=True)
    \\ed = find_role("entry")
    \\et = ed.queryText()
    \\print("ENTRY", repr(ed.name), repr(et.getText(0, -1)), ed.queryEditableText().insertText(3, "!", 1), flush=True)
    \\v = find_role("slider").queryValue()
    \\print("VALUE", v.currentValue, v.maximumValue, flush=True)
    \\print("FOCUS", find_role("check box").queryComponent().grabFocus(), flush=True)
    \\def on(ev):
    \\    data = ev.any_data if isinstance(ev.any_data, str) else ""
    \\    print("EVENT", ev.type, repr(ev.source.name if ev.source else None), ev.detail1, repr(data), flush=True)
    \\pyatspi.Registry.registerEventListener(on, "object:state-changed:checked", "object:state-changed:focused",
    \\    "object:text-changed:insert", "object:text-caret-moved", "object:children-changed",
    \\    "object:property-change:accessible-name", "object:announcement")
    \\print("READY", flush=True)
    \\GLib.timeout_add(1500, lambda: pyatspi.Registry.stop())
    \\pyatspi.Registry.start()
    \\print("DONE", flush=True)
    \\
;

const Stack = struct {
    loop: Loop,
    daemon: td.Daemon = .{},
    launcher: linux.pid_t = 0,
    session: Connection = undefined,
    env_bufs: [3][192]u8 = undefined,
    env: [5:null]?[*:0]const u8 = @splat(null),

    fn init(s: *Stack) !void {
        s.* = .{ .loop = try Loop.init(gpa) };
        errdefer s.loop.deinit();
        try s.daemon.start();
        errdefer s.daemon.stop();
        s.env[0] = try std.fmt.bufPrintSentinel(&s.env_bufs[0], "DBUS_SESSION_BUS_ADDRESS={s}", .{s.daemon.address}, 0);
        s.env[1] = try std.fmt.bufPrintSentinel(&s.env_bufs[1], "XDG_RUNTIME_DIR={s}", .{s.daemon.dir}, 0);
        s.env[2] = "PATH=/usr/bin:/bin";
        // The launcher keeps IsEnabled in GSettings; without a dconf
        // service it must stay in memory.
        s.env[3] = "GSETTINGS_BACKEND=memory";
        // Where at-spi2-core defaults to dbus-broker (Arch), its launcher
        // activates the registry through systemd user units, which a
        // private bus does not have.
        s.env[4] = "ATSPI_DBUS_IMPLEMENTATION=dbus-daemon";
        var launcher_buf: [64]u8 = undefined;
        const launcher = td.findLibexec(&launcher_buf, "at-spi-bus-launcher") orelse {
            std.log.err("at-spi2-core is not installed; run .agents/setup", .{});
            return error.AtspiNotInstalled;
        };
        const argv = [_:null]?[*:0]const u8{ launcher, "--launch-immediately" };
        s.launcher = try td.spawn(launcher, &argv, &s.env, null);
        try s.session.init(gpa, &s.loop, s.daemon.address, .{});
        // Wait for the launcher, then turn accessibility on as a screen
        // reader or the desktop's setting would.
        var w: Connection.NameWatch = .{ .name = "org.a11y.Bus" };
        try s.session.watchName(&w);
        defer s.session.unwatchName(&w);
        try s.until(&w, struct {
            fn f(x: *Connection.NameWatch) bool {
                return x.state == .owned;
            }
        }.f);
    }

    fn enable(s: *Stack) !void {
        var b = s.session.methodCall("org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties", "Set");
        try b.body.writeAll(.{ "org.a11y.Status", "IsEnabled", dbus.variant(true) });
        _ = try s.session.send(&b);
    }

    fn deinit(s: *Stack) void {
        s.session.deinit();
        td.kill(s.launcher);
        var buf: [128]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&buf, "{s}/at-spi/bus", .{s.daemon.dir}, 0)) |p| _ = linux.unlink(p) else |_| {}
        if (std.fmt.bufPrintSentinel(&buf, "{s}/at-spi", .{s.daemon.dir}, 0)) |p| _ = linux.rmdir(p) else |_| {}
        s.daemon.stop();
        s.loop.deinit();
    }

    fn until(s: *Stack, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        const deadline = Loop.now() + 5 * std.time.ns_per_s;
        while (!cond(ctx)) {
            if (Loop.now() > deadline) return error.TestTimeout;
            try s.loop.dispatch(50);
        }
    }
};

/// The client's output, read while the loop keeps serving its calls.
const Client = struct {
    pid: linux.pid_t,
    fd: i32,
    out: std.ArrayList(u8) = .empty,
    done: bool = false,

    fn start(s: *Stack, name: []const u8) !Client {
        var path_buf: [128]u8 = undefined;
        const script = try std.fmt.bufPrintSentinel(&path_buf, "{s}/client.py", .{s.daemon.dir}, 0);
        try td.writeFile(script, client_script);
        var fds: [2]i32 = undefined;
        _ = linux.pipe2(&fds, .{ .CLOEXEC = true });
        var name_buf: [64]u8 = undefined;
        const name_z = try std.fmt.bufPrintSentinel(&name_buf, "{s}", .{name}, 0);
        const argv = [_:null]?[*:0]const u8{ "/usr/bin/python3", script, name_z };
        const pid = try td.spawn("/usr/bin/python3", &argv, &s.env, fds[1]);
        _ = linux.close(fds[1]);
        _ = linux.fcntl(fds[0], linux.F.SETFL, linux.SOCK.NONBLOCK);
        return .{ .pid = pid, .fd = fds[0] };
    }

    /// Reads what is available; returns false at EOF.
    fn poll(c: *Client) !void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = linux.read(c.fd, &buf, buf.len);
            if (linux.errno(n) == .AGAIN) return;
            if (linux.errno(n) != .SUCCESS or n == 0) {
                c.done = true;
                return;
            }
            try c.out.appendSlice(gpa, buf[0..n]);
        }
    }

    fn has(c: *const Client, needle: []const u8) bool {
        return std.mem.indexOf(u8, c.out.items, needle) != null;
    }

    fn finish(c: *Client) void {
        td.kill(c.pid);
        _ = linux.close(c.fd);
        c.out.deinit(gpa);
    }
};

test "libatspi reads the tree, acts on it, and hears its events through the registry" {
    var s: Stack = undefined;
    try s.init();
    defer s.deinit();
    var fx: Fixture = undefined;
    try fx.init(gpa);
    defer fx.deinit();

    var bridge: Bridge = undefined;
    bridge.init(gpa, &s.loop, .{ .app_name = "siv-a11y-test", .toolkit_version = "0.1" });
    defer bridge.deinit();
    const wid = try bridge.addWindow(fx.win, "Test window");
    try bridge.start(&s.session);
    try s.loop.dispatch(10);
    try testing.expect(!bridge.active()); // nobody asked yet
    try s.enable();
    try s.until(&bridge, struct {
        fn f(b: *Bridge) bool {
            return b.active() and b.embed_call == 0 and b.desktop_path_len > 0;
        }
    }.f);

    var client = try Client.start(&s, "siv-a11y-test");
    defer client.finish();
    var changed = false;
    const deadline = Loop.now() + 20 * std.time.ns_per_s;
    while (!client.done) {
        if (Loop.now() > deadline) return error.TestTimeout;
        try s.loop.dispatch(10);
        try client.poll();
        if (!changed and client.has("READY\n")) {
            changed = true;
            // Changes for the listening client: a checkbox checked, focus
            // moved, the editor's edit from InsertText, a live region.
            const t = try fx.win.begin();
            try t.setSemantics(fx.nodes.check, .{ .role = .checkbox, .label = "Remember", .focusable = true, .checked = .on });
            try t.setText(fx.nodes.status_text, "Saved");
            t.commit();
            ui.input.setFocus(fx.win, fx.nodes.editor, true);
            try fx.win.frame();
            try bridge.update(wid);
        }
    }
    const out = client.out.items;
    const expected = [_][]const u8{
        "APP application siv",
        "NODE 1 frame 'Test window' enabled,resizable,sensitive,showing,visible Accessible,Component",
        "NODE 2 push button 'OK' enabled,focusable,sensitive,showing,visible Accessible,Action,Component",
        "NODE 2 label 'Hello wörld. Second sentence.' enabled,sensitive,showing,visible Accessible,Component,Text",
        "NODE 2 entry 'Name' editable,enabled,focusable,selectable text,sensitive,showing,single line,visible Accessible,Component,EditableText,Text",
        "NODE 2 check box 'Remember' checkable,enabled,focusable,sensitive,showing,visible Accessible,Component",
        "NODE 2 slider 'Volume' enabled,horizontal,sensitive,showing,visible Accessible,Component,Value",
        "NODE 2 status bar 'Ready'",
        "NODE 2 list '' enabled,sensitive,showing,visible Accessible,Component,Selection",
        "NODE 3 list item 'Two' enabled,selectable,selected,sensitive,showing,visible Accessible,Action,Component",
        "ACTION click True",
        "TEXT 'Hello wörld. Second sentence.' 29 ('wörld. ', 6, 13)",
        "EXTENTS True True",
        "ENTRY 'Name' 'abc' True",
        "VALUE 3.0 10.0",
        "FOCUS True",
        "READY",
        "EVENT object:state-changed:checked 'Remember' 1",
        "EVENT object:state-changed:focused 'Name' 1",
        "EVENT object:text-changed:insert 'Name' 3 '!'",
        "EVENT object:text-caret-moved 'Name' 4",
        "EVENT object:announcement 'Saved' 1 'Saved'",
        "DONE",
    };
    for (expected) |want| if (std.mem.indexOf(u8, out, want) == null) {
        std.debug.print("missing {s} in client output:\n{s}\n", .{ want, out });
        return error.TestExpectedEqual;
    };
    // libatspi took the tree from Cache.GetItems and no call failed.
    if (std.mem.indexOf(u8, out, "WARNING") != null or std.mem.indexOf(u8, out, "Traceback") != null) {
        std.debug.print("client warnings:\n{s}\n", .{out});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 1), fx.clicks);
    try testing.expectEqualStrings("abc!", fx.win.node(fx.nodes.editor).data.editor.text.content);
}

/// sway on its headless backend in the stack's runtime directory: Orca
/// needs a display connection.
fn startSway(s: *Stack) !linux.pid_t {
    const exe = td.findExecutable("sway") orelse return error.SwayNotInstalled;
    var buf: [128]u8 = undefined;
    const config = try std.fmt.bufPrintSentinel(&buf, "{s}/sway.conf", .{s.daemon.dir}, 0);
    try td.writeFile(config, "output HEADLESS-1 mode 1280x720@60Hz\n");
    var env_bufs: [2][192]u8 = undefined;
    const env = [_:null]?[*:0]const u8{
        try std.fmt.bufPrintSentinel(&env_bufs[0], "XDG_RUNTIME_DIR={s}", .{s.daemon.dir}, 0),
        "PATH=/usr/local/bin:/usr/bin:/bin",
        "WLR_BACKENDS=headless",
        "WLR_RENDERER=pixman",
        "WLR_LIBINPUT_NO_DEVICES=1",
    };
    const argv = [_:null]?[*:0]const u8{ exe, "-c", config };
    const pid = try td.spawn(exe, &argv, &env, null);
    const sock = try std.fmt.bufPrintSentinel(&env_bufs[1], "{s}/wayland-1", .{s.daemon.dir}, 0);
    var waited: u32 = 0;
    while (linux.access(sock, 0) != 0) : (waited += 1) {
        if (waited > 500) {
            td.kill(pid);
            return error.SwayDidNotStart;
        }
        td.sleepMs(10);
    }
    return pid;
}

fn readFile(path: [*:0]const u8, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    const rc = linux.open(path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        try out.appendSlice(gpa, buf[0..n]);
    }
}

test "Orca turns accessibility on, finds the application, and speaks focus changes" {
    var orca_buf: [256]u8 = undefined;
    const orca = try std.fmt.bufPrintSentinel(&orca_buf, "{s}", .{td.findExecutable("orca") orelse {
        std.log.warn("orca is not installed; skipping", .{});
        return;
    }}, 0);
    var s: Stack = undefined;
    try s.init();
    defer s.deinit();
    const sway = try startSway(&s);
    defer td.kill(sway);
    var fx: Fixture = undefined;
    try fx.init(gpa);
    defer fx.deinit();
    var bridge: Bridge = undefined;
    bridge.init(gpa, &s.loop, .{ .app_name = "siv-orca-test", .toolkit_version = "0.1" });
    defer bridge.deinit();
    const wid = try bridge.addWindow(fx.win, "Orca test");
    try bridge.start(&s.session);

    // Orca 43 reads the X keymap with xkbcomp at startup; on Wayland a
    // stub stands in for it.
    var buf: [3][192]u8 = undefined;
    const stub_dir = try std.fmt.bufPrintSentinel(&buf[0], "{s}/stub", .{s.daemon.dir}, 0);
    _ = linux.mkdir(stub_dir, 0o700);
    const stub = try std.fmt.bufPrintSentinel(&buf[1], "{s}/xkbcomp", .{stub_dir}, 0);
    try td.writeFile(stub, "#!/bin/sh\nexit 0\n");
    _ = linux.chmod(stub, 0o700);
    var env_bufs: [4][192]u8 = undefined;
    const env = [_:null]?[*:0]const u8{
        s.env[0].?,
        s.env[1].?,
        "GSETTINGS_BACKEND=memory",
        try std.fmt.bufPrintSentinel(&env_bufs[0], "HOME={s}", .{s.daemon.dir}, 0),
        try std.fmt.bufPrintSentinel(&env_bufs[1], "PATH={s}:/usr/local/bin:/usr/bin:/bin", .{stub_dir}, 0),
        "DISPLAY=:0",
        "WAYLAND_DISPLAY=wayland-1",
        "GDK_BACKEND=wayland",
    };
    const log_path = try std.fmt.bufPrintSentinel(&buf[2], "{s}/orca.log", .{s.daemon.dir}, 0);
    // Orca writes its debug file block-buffered; open it line-buffered so
    // that the test sees each line as Orca logs it.
    const wrapper =
        \\import builtins, runpy
        \\_open = builtins.open
        \\def line_buffered(f, mode="r", *a, **k):
        \\    if not a and "b" not in mode and "w" in mode: k.setdefault("buffering", 1)
        \\    return _open(f, mode, *a, **k)
        \\builtins.open = line_buffered
        \\runpy.run_path("/usr/bin/orca", run_name="__main__")
    ;
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/python3", "-c", wrapper, "--debug-file", log_path };
    const out_path = try std.fmt.bufPrintSentinel(&env_bufs[2], "{s}/orca.out", .{s.daemon.dir}, 0);
    const out_fd: i32 = @intCast(linux.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600));
    defer _ = linux.close(out_fd);
    _ = orca;
    const pid = try td.spawn("/usr/bin/python3", &argv, &env, out_fd);
    defer td.kill(pid);

    // Orca sets IsEnabled; the bridge connects by itself.
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    const start_deadline = Loop.now() + 30 * std.time.ns_per_s;
    while (!(bridge.active() and bridge.embed_call == 0)) {
        if (Loop.now() > start_deadline) {
            try readFile(out_path, &log);
            std.debug.print("the bridge never connected; Orca's output:\n{s}\n", .{log.items[log.items.len -| 4000..]});
            return error.TestTimeout;
        }
        try s.loop.dispatch(50);
    }

    const Step = struct { node: ui.NodeId, want: []const []const u8 };
    // Orca speaks a focused control as its name and role (and state).
    const steps = [_]Step{
        .{ .node = fx.nodes.button, .want = &.{ "OK", "push button" } },
        .{ .node = fx.nodes.check, .want = &.{ "Remember", "check box", "not checked" } },
    };
    // Orca needs a moment to load its scripts and the application list.
    const ready_deadline = Loop.now() + 30 * std.time.ns_per_s;
    while (true) {
        try s.loop.dispatch(50);
        try readFile(log_path, &log);
        if (std.mem.indexOf(u8, log.items, "siv-orca-test") != null) break;
        if (Loop.now() > ready_deadline) {
            std.debug.print("Orca never saw the application:\n{s}\n", .{log.items[log.items.len -| 1500..]});
            return error.TestTimeout;
        }
    }
    bridge.setActive(wid, true);
    for (steps) |step| {
        ui.input.setFocus(fx.win, step.node, true);
        try fx.win.frame();
        try bridge.update(wid);
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        while (!spoke(log.items, step.want)) {
            if (Loop.now() > deadline) {
                std.debug.print("Orca did not say {s}:\n{s}\n", .{ step.want[0], log.items[log.items.len -| 6000..] });
                return error.TestTimeout;
            }
            try s.loop.dispatch(50);
            try readFile(log_path, &log);
        }
    }
}

/// Whether some "SPEECH OUTPUT" line of Orca's log contains every word.
fn spoke(log: []const u8, words: []const []const u8) bool {
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "SPEECH OUTPUT: '") == null) continue;
        for (words) |w| {
            if (std.mem.indexOf(u8, line, w) == null) break;
        } else return true;
    }
    return false;
}
