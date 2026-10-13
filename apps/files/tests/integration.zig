//! The file manager on headless sway with real input, read by a screen
//! reader's view of it (`zig build test-integration-files`, part of
//! `zig build test-integration`): a private session bus with
//! at-spi2-core's bus launcher and registry, the application on sway's
//! Wayland socket, the virtual pointer and wtype for input, and libatspi
//! (pyatspi) as the assistive technology, which reads the window's tree,
//! the table's rows and cells, the places, the focused row, and hears
//! focus moves and the status line's announcements as keys move through
//! the folder.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const abi = @import("abi");
const platform = @import("platform");
const dbus = @import("dbus");
const Loop = @import("loop").Loop;
const text = @import("text");
const harness = @import("harness.zig");

const A = abi.application;
const Sway = platform.test_sway.Sway;
const VirtualPointer = platform.test_sway.VirtualPointer;
const td = dbus.testing.daemon;
const Fixture = harness.Fixture;
const Files = harness.Files;
const ok = harness.ok;
const gpa = testing.allocator;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const client_script =
    \\import sys, time, pyatspi
    \\from gi.repository import GLib
    \\name = sys.argv[1]
    \\def find():
    \\    for a in pyatspi.Registry.getDesktop(0):
    \\        if a is not None and a.name == name:
    \\            return a
    \\app = None
    \\for i in range(500):
    \\    app = find()
    \\    if app: break
    \\    time.sleep(0.02)
    \\if not app:
    \\    print("NOAPP", flush=True); sys.exit(1)
    \\def role(o):
    \\    r = o.getRoleName()
    \\    return "push button" if r == "button" else r
    \\def states(o):
    \\    return sorted(pyatspi.stateToString(s) for s in o.getState().getStates())
    \\frame = app[0]
    \\print("FRAME", role(frame), repr(frame.name), flush=True)
    \\def find_role(r, n=None):
    \\    return pyatspi.findDescendant(app, lambda x: role(x) == r and (n is None or x.name == n))
    \\table = find_role("table", "Files")
    \\rows = [c for c in table if role(c) == "table row"]
    \\for r in rows:
    \\    cells = [c for c in r if role(c) == "table cell"]
    \\    attrs = dict(a.split(":", 1) for a in r.getAttributes())
    \\    print("ROW", attrs.get("rowindex", "?"), repr(r.name), len(cells), "selected" in states(r), flush=True)
    \\for h in [c for c in pyatspi.findAllDescendants(table.parent, lambda x: role(x) == "column header")]:
    \\    attrs = dict(a.split(":", 1) for a in h.getAttributes())
    \\    print("HEADER", repr(h.name), attrs.get("sort", "none"), flush=True)
    \\places = find_role("list", "Places")
    \\print("PLACES", [c.name for c in places], flush=True)
    \\for b in ["Back", "Forward", "Up"]:
    \\    btn = find_role("push button", b)
    \\    print("BUTTON", b, "enabled" in states(btn), flush=True)
    \\s = find_role("entry", "Search")
    \\print("SEARCH", s is not None, flush=True)
    \\st = find_role("status bar")
    \\print("STATUS", repr(st.name), flush=True)
    \\f = pyatspi.findDescendant(app, lambda x: "focused" in states(x))
    \\print("FOCUSED", role(f) if f else None, repr(f.name) if f else None, flush=True)
    \\def on(ev):
    \\    data = ev.any_data if isinstance(ev.any_data, str) else ""
    \\    print("EVENT", ev.type, role(ev.source) if ev.source else None, repr(ev.source.name if ev.source else None), ev.detail1, repr(data), flush=True)
    \\pyatspi.Registry.registerEventListener(on, "object:state-changed:focused", "object:announcement", "object:property-change:accessible-name")
    \\print("READY", flush=True)
    \\GLib.timeout_add(int(sys.argv[2]), lambda: pyatspi.Registry.stop())
    \\pyatspi.Registry.start()
    \\print("DONE", flush=True)
    \\
;

/// A private session bus with the accessibility bus launcher, and
/// accessibility turned on as a screen reader turns it on.
const Stack = struct {
    loop: Loop,
    daemon: td.Daemon = .{},
    launcher: linux.pid_t = 0,
    session: dbus.Connection = undefined,
    env_bufs: [3][192]u8 = undefined,
    env: [6:null]?[*:0]const u8 = @splat(null),

    fn init(s: *Stack) !void {
        s.* = .{ .loop = try Loop.init(gpa) };
        errdefer s.loop.deinit();
        try s.daemon.start();
        errdefer s.daemon.stop();
        s.env[0] = try std.fmt.bufPrintSentinel(&s.env_bufs[0], "DBUS_SESSION_BUS_ADDRESS={s}", .{s.daemon.address}, 0);
        s.env[1] = try std.fmt.bufPrintSentinel(&s.env_bufs[1], "XDG_RUNTIME_DIR={s}", .{s.daemon.dir}, 0);
        s.env[2] = "PATH=/usr/bin:/bin";
        s.env[3] = "GSETTINGS_BACKEND=memory";
        s.env[4] = "ATSPI_DBUS_IMPLEMENTATION=dbus-daemon";
        var launcher_buf: [64]u8 = undefined;
        const launcher = td.findLibexec(&launcher_buf, "at-spi-bus-launcher") orelse {
            std.log.err("at-spi2-core is not installed; run .agents/setup", .{});
            return error.AtspiNotInstalled;
        };
        const argv = [_:null]?[*:0]const u8{ launcher, "--launch-immediately" };
        s.launcher = try td.spawn(launcher, &argv, &s.env, null);
        try s.session.init(gpa, &s.loop, s.daemon.address, .{});
        var w: dbus.Connection.NameWatch = .{ .name = "org.a11y.Bus" };
        try s.session.watchName(&w);
        defer s.session.unwatchName(&w);
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        while (w.state != .owned) {
            if (Loop.now() > deadline) return error.Timeout;
            try s.loop.dispatch(20);
        }
        var b = s.session.methodCall("org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties", "Set");
        try b.body.writeAll(.{ "org.a11y.Status", "IsEnabled", dbus.variant(true) });
        _ = try s.session.send(&b);
        try s.loop.dispatch(20);
    }

    fn deinit(s: *Stack) void {
        s.session.deinit();
        td.kill(s.launcher);
        s.daemon.stop();
        s.loop.deinit();
    }
};

const Client = struct {
    pid: linux.pid_t,
    fd: i32,
    out: std.ArrayList(u8) = .empty,
    done: bool = false,

    fn start(s: *Stack, name: [:0]const u8, listen_ms: [:0]const u8) !Client {
        var path_buf: [128]u8 = undefined;
        const script = try std.fmt.bufPrintSentinel(&path_buf, "{s}/files-client.py", .{s.daemon.dir}, 0);
        try td.writeFile(script, client_script);
        var fds: [2]i32 = undefined;
        _ = linux.pipe2(&fds, .{ .CLOEXEC = true });
        const argv = [_:null]?[*:0]const u8{ "/usr/bin/python3", script, name, listen_ms };
        const pid = try td.spawn("/usr/bin/python3", &argv, &s.env, fds[1]);
        _ = linux.close(fds[1]);
        _ = linux.fcntl(fds[0], linux.F.SETFL, linux.SOCK.NONBLOCK);
        return .{ .pid = pid, .fd = fds[0] };
    }

    fn poll(cl: *Client) !void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = linux.read(cl.fd, &buf, buf.len);
            if (linux.errno(n) == .AGAIN) return;
            if (linux.errno(n) != .SUCCESS or n == 0) {
                cl.done = true;
                return;
            }
            try cl.out.appendSlice(gpa, buf[0..n]);
        }
    }

    fn has(cl: *const Client, needle: []const u8) bool {
        return std.mem.indexOf(u8, cl.out.items, needle) != null;
    }

    fn finish(cl: *Client) void {
        td.kill(cl.pid);
        _ = linux.close(cl.fd);
        cl.out.deinit(gpa);
    }
};

const App = struct {
    app: abi.types.App = .null,
    files: *Files = undefined,

    fn dispatch(a: *App, ms: i32) !void {
        try ok(A.siv_app_dispatch(a.app, ms));
    }

    fn window(a: *App) !*A.Window {
        return A.App.window(@intFromEnum(a.files.window), A.window_tag);
    }

    /// Dispatches until the window shows its folder at sway's size.
    fn ready(a: *App) !void {
        const deadline = Loop.now() + 15 * std.time.ns_per_s;
        while (true) {
            try a.dispatch(10);
            const w = try a.window();
            if (a.files.listing != null and a.files.loading == null and w.win.presented_seq > 0 and w.win.settled() and w.win.ui.width == 1280) return;
            if (Loop.now() > deadline) return error.Timeout;
        }
    }

    fn semantics(a: *App) !*const @import("ui").semantics.Tree {
        return (try a.window()).uiWin().semanticsTree();
    }

    fn item(a: *App, name: []const u8) !@import("ui").semantics.Node {
        const tree = try a.semantics();
        for (tree.nodes.items) |n| {
            if (n.role != .row) continue;
            const nm = tree.name(n);
            if (std.mem.startsWith(u8, nm, name) and (nm.len == name.len or nm[name.len] == ' ')) return n;
        }
        return error.NotFound;
    }
};

fn typeKeys(sway: *const Sway, app: *App, argv: [*:null]const ?[*:0]const u8) !void {
    const pid = try sway.spawnClient(argv);
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, std.c.W.NOHANG) == 0) try app.dispatch(10);
    try testing.expectEqual(0, status);
}

const sample = [_]Fixture.Item{
    .{ .name = "Projects", .dir = true },
    .{ .name = "notes.txt", .size = 1_234 },
    .{ .name = "photo.png", .size = 52_000 },
    .{ .name = "report.pdf", .size = 2_400_000 },
};

test "on sway with a screen reader: rows, cells, places, focus, and announcements through AT-SPI" {
    var s: Stack = undefined;
    try s.init();
    defer s.deinit();
    var sway: Sway = .{};
    try sway.start();
    defer sway.stop();
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    try fx.add(.{ .name = "Projects/siv", .dir = true });

    // The application joins the private session bus, finds the
    // accessibility bus there, and publishes its tree.
    _ = setenv("DBUS_SESSION_BUS_ADDRESS", s.daemon.address.ptr, 1);
    defer _ = unsetenv("DBUS_SESSION_BUS_ADDRESS");
    var app: App = .{};
    try ok(A.siv_app_create(&.{
        .display = sway.display.ptr,
        .display_len = sway.display.len,
        .name = "siv-files-test",
        .name_len = 14,
        .flags = .{ .no_system_fonts = true, .reduced_motion = true, .no_desktop_settings = true },
    }, &app.app));
    defer _ = A.siv_app_destroy(app.app);
    const tf = text.font.test_fonts;
    try ok(A.siv_app_add_font(app.app, "Droid", 5, tf.latin.ptr, tf.latin.len));
    try ok(A.siv_app_set_default_font(app.app, "Droid", 5));
    app.files = try Files.create(@enumFromInt(@intFromEnum(app.app)), .{
        .gpa = std.heap.c_allocator,
        .path = fx.path,
        .home = fx.path,
        .config_home = "/nonexistent",
        .data_home = fx.path,
        .thumbnails = false,
        .watch = true,
    });
    try app.ready();

    // A real click on a row selects it and focuses it.
    var vp = try VirtualPointer.connect(&sway);
    defer vp.deinit();
    try vp.sync();
    const keyboard = try sway.spawnClient(&[_:null]?[*:0]const u8{ "wtype", "-s", "60000" });
    defer {
        _ = std.c.kill(keyboard, std.c.SIG.TERM);
        var status: c_int = 0;
        _ = std.c.waitpid(keyboard, &status, 0);
    }
    const notes = (try app.item("notes.txt")).bounds;
    vp.moveTo(@intFromFloat((notes.x0 + notes.x1) / 2), @intFromFloat((notes.y0 + notes.y1) / 2));
    vp.button(0x110, true);
    vp.button(0x110, false);
    try vp.sync();
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (true) {
        try app.dispatch(10);
        const sel = try app.files.selectedIndices();
        defer app.files.gpa.free(sel);
        if (sel.len == 1) break;
        if (Loop.now() > deadline) return error.Timeout;
    }
    try app.ready();

    var client = try Client.start(&s, "siv-files-test", "3000");
    defer client.finish();
    var typed = false;
    const client_deadline = Loop.now() + 60 * std.time.ns_per_s;
    while (!client.done) {
        if (Loop.now() > client_deadline) {
            std.debug.print("client output so far:\n{s}\n", .{client.out.items});
            return error.Timeout;
        }
        try app.dispatch(10);
        try s.loop.dispatch(0);
        try client.poll();
        if (!typed and client.has("READY\n")) {
            typed = true;
            // Down to the next row, then into a folder and back.
            try typeKeys(&sway, &app, &[_:null]?[*:0]const u8{ "wtype", "-k", "Down" });
            try typeKeys(&sway, &app, &[_:null]?[*:0]const u8{ "wtype", "-k", "Up", "-k", "Up" });
            try typeKeys(&sway, &app, &[_:null]?[*:0]const u8{ "wtype", "-k", "Return" });
        }
    }
    const out = client.out.items;
    const expected = [_][]const u8{
        // The window's name is its title.
        "FRAME frame 'Home \u{2014} Files'",
        // Rows named from their cells (Python shows the left-to-right
        // mark before the date as \u200e), four cells each, the clicked
        // one selected.
        "ROW 1 'Projects \u{2014} \\u200e2026-10-13 ",
        "ROW 2 'notes.txt 1.2 kB \\u200e2026-10-13 14:05 Text' 4 True",
        "HEADER 'Name' ascending",
        "HEADER 'Size' none",
        "PLACES ['Home', 'Trash', 'Computer']",
        "BUTTON Back False",
        "BUTTON Up True",
        "SEARCH True",
        "STATUS '\u{201c}notes.txt\u{201d} selected (1.2 kB)'",
        "FOCUSED table row 'notes.txt",
        "READY",
        // The keyboard moves focus to photo.png's row; the status line, a
        // live region, announces the selection.
        "EVENT object:state-changed:focused table row 'photo.png",
        "EVENT object:announcement status bar '\u{201c}photo.png\u{201d} selected (52.0 kB)'",
        "DONE",
    };
    var missing = false;
    for (expected) |want| if (std.mem.indexOf(u8, out, want) == null) {
        std.debug.print("missing \"{s}\"\n", .{want});
        missing = true;
    };
    if (missing) {
        std.debug.print("client output:\n{s}\n", .{out});
        return error.TestUnexpectedResult;
    }
    // Enter on Projects opened it.
    const deadline2 = Loop.now() + 10 * std.time.ns_per_s;
    while (!std.mem.endsWith(u8, app.files.path, "/Projects")) {
        if (Loop.now() > deadline2) return error.Timeout;
        try app.dispatch(10);
    }
    try app.ready();
    _ = try app.item("siv");
}
