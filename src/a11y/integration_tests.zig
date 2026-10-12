//! Integration tests against the real AT-SPI stack (`zig build
//! test-integration-a11y`): a private session bus, at-spi-bus-launcher
//! with its accessibility bus and at-spi2-registryd, and libatspi through
//! pyatspi as the assistive technology. The bridge discovers the bus
//! through org.a11y.Bus once IsEnabled turns on, as in a desktop session.

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
    \\print("APP", app.getRoleName(), app.get_toolkit_name(), flush=True)
    \\def dump(o, depth):
    \\    st = sorted(pyatspi.stateToString(s) for s in o.getState().getStates())
    \\    print("NODE", depth, o.getRoleName(), repr(o.name), ",".join(st), ",".join(o.get_interfaces()), flush=True)
    \\    for c in o: dump(c, depth + 1)
    \\dump(app, 0)
    \\def find_role(role):
    \\    return pyatspi.findDescendant(app, lambda x: x.getRoleName() == role)
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
        const launcher = "/usr/libexec/at-spi-bus-launcher";
        if (linux.access(launcher, 1) != 0) {
            std.log.err("at-spi2-core is not installed; run .agents/setup", .{});
            return error.AtspiNotInstalled;
        }
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
