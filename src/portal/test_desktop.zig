//! A real xdg-desktop-portal for integration tests: a private dbus-daemon,
//! xdg-permission-store, xdg-desktop-portal (1.16, Debian's) with a
//! backend of siv's own (`Backend`, the org.freedesktop.impl.portal.*
//! interfaces on a thread of its own, answering as the test says), a
//! file manager (org.freedesktop.FileManager1) for OpenDirectory, and a
//! .desktop handler that records what OpenURI launched. Not part of
//! libsiv.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus");
const Loop = @import("loop").Loop;
const vardict = @import("vardict.zig");
const td = dbus.testing.daemon;

const Connection = dbus.Connection;
const gpa = std.heap.smp_allocator;

/// The backend's records are shared with the test's thread.
const SpinLock = struct {
    v: std.atomic.Value(bool) = .init(false),

    fn lock(l: *SpinLock) void {
        while (l.v.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(l: *SpinLock) void {
        l.v.store(false, .release);
    }
};

pub const backend_name = "org.freedesktop.impl.portal.desktop.siv";
const impl_path = "/org/freedesktop/portal/desktop";

/// The portal backend: every impl method is recorded and answered with
/// `code` and the results `results` writes.
pub const Backend = struct {
    loop: Loop = undefined,
    conn: Connection = undefined,
    owner: Connection.NameOwner = .{ .name = backend_name },
    fm_owner: Connection.NameOwner = .{ .name = "org.freedesktop.FileManager1" },
    obj: dbus.Object = undefined,
    fm_obj: dbus.Object = undefined,
    thread: std.Thread = undefined,
    stop_flag: std.atomic.Value(bool) = .init(false),
    mutex: SpinLock = .{},
    calls: std.ArrayList(Call) = .empty,
    closed: std.ArrayList([]u8) = .empty,
    code: u32 = 0,
    results: ?*const fn (call: *const Call, w: vardict.Writer) anyerror!void = null,

    pub const Call = struct {
        interface: []u8,
        member: []u8,
        signature: []u8,
        body: []u8,
        /// The contents of the call's first fd, if it is a readable file.
        fd_data: []u8 = &.{},

        pub fn decoder(c: *const Call) dbus.Decoder {
            return .init(c.body, c.signature, .little, &.{});
        }

        /// The last a{sv} argument.
        pub fn options(c: *const Call) vardict.Reader {
            var d = c.decoder();
            var found: vardict.Reader = .empty;
            while (d.peek() != null) {
                if (std.mem.startsWith(u8, d.remainingSignature(), "a{sv}")) {
                    found = vardict.Reader.take(&d) catch return found;
                } else d.skip() catch return found;
            }
            return found;
        }

        /// String argument `n` (counting strings only).
        pub fn string(c: *const Call, n: usize) []const u8 {
            var d = c.decoder();
            var i: usize = 0;
            while (d.peek()) |code| {
                if (code == 's') {
                    const s = d.readString() catch return "";
                    if (i == n) return s;
                    i += 1;
                } else d.skip() catch return "";
            }
            return "";
        }

        /// Object path argument `n`.
        pub fn path(c: *const Call, n: usize) []const u8 {
            var d = c.decoder();
            var i: usize = 0;
            while (d.peek()) |code| {
                if (code == 'o') {
                    const s = d.readObjectPath() catch return "";
                    if (i == n) return s;
                    i += 1;
                } else d.skip() catch return "";
            }
            return "";
        }
    };

    fn m(name: []const u8, in: []const u8, out: []const u8) dbus.Method {
        return .{ .name = name, .in = in, .out = out, .func = handle };
    }

    fn u32Prop(comptime name: []const u8, comptime v: u32) dbus.Property {
        return .{ .name = name, .signature = "u", .get = struct {
            fn get(_: dbus.object.PropertyContext, e: *dbus.Encoder) anyerror!void {
                try e.writeUint32(v);
            }
        }.get };
    }

    const ifaces = [_]*const dbus.Interface{
        &.{ .name = "org.freedesktop.impl.portal.FileChooser", .methods = &.{ m("OpenFile", "osssa{sv}", "ua{sv}"), m("SaveFile", "osssa{sv}", "ua{sv}") } },
        &.{ .name = "org.freedesktop.impl.portal.Screenshot", .methods = &.{ m("Screenshot", "ossa{sv}", "ua{sv}"), m("PickColor", "ossa{sv}", "ua{sv}") }, .properties = &.{u32Prop("version", 2)} },
        &.{ .name = "org.freedesktop.impl.portal.Access", .methods = &.{m("AccessDialog", "osssssa{sv}", "ua{sv}")} },
        &.{ .name = "org.freedesktop.impl.portal.AppChooser", .methods = &.{ m("ChooseApplication", "ossasa{sv}", "ua{sv}"), m("UpdateChoices", "oas", "") } },
        &.{ .name = "org.freedesktop.impl.portal.Notification", .methods = &.{ m("AddNotification", "ssa{sv}", ""), m("RemoveNotification", "ss", "") }, .signals = &.{.{ .name = "ActionInvoked", .signature = "sssav" }} },
        &.{ .name = "org.freedesktop.impl.portal.Inhibit", .methods = &.{m("Inhibit", "ossua{sv}", "")} },
        &.{ .name = "org.freedesktop.impl.portal.GlobalShortcuts", .methods = &.{ m("CreateSession", "oosa{sv}", "ua{sv}"), m("BindShortcuts", "ooa(sa{sv})sa{sv}", "ua{sv}"), m("ListShortcuts", "oo", "ua{sv}") }, .properties = &.{u32Prop("version", 1)} },
        &.{ .name = "org.freedesktop.impl.portal.ScreenCast", .methods = &.{ m("CreateSession", "oosa{sv}", "ua{sv}"), m("SelectSources", "oosa{sv}", "ua{sv}"), m("Start", "oossa{sv}", "ua{sv}") }, .properties = &.{ u32Prop("AvailableSourceTypes", 7), u32Prop("AvailableCursorModes", 7), u32Prop("version", 4) } },
        &.{ .name = "org.freedesktop.impl.portal.Print", .methods = &.{ m("PreparePrint", "osssa{sv}a{sv}a{sv}", "ua{sv}"), m("Print", "osssha{sv}", "ua{sv}") } },
    };
    const request_iface: dbus.Interface = .{ .name = "org.freedesktop.impl.portal.Request", .methods = &.{.{ .name = "Close", .func = close }} };
    const session_iface: dbus.Interface = .{ .name = "org.freedesktop.impl.portal.Session", .methods = &.{.{ .name = "Close", .func = close }}, .signals = &.{.{ .name = "Closed" }} };
    const fm_iface: dbus.Interface = .{ .name = "org.freedesktop.FileManager1", .methods = &.{m("ShowItems", "ass", "")} };

    pub const interfaces = "org.freedesktop.impl.portal.FileChooser;org.freedesktop.impl.portal.Screenshot;org.freedesktop.impl.portal.Access;org.freedesktop.impl.portal.AppChooser;org.freedesktop.impl.portal.Notification;org.freedesktop.impl.portal.Inhibit;org.freedesktop.impl.portal.GlobalShortcuts;org.freedesktop.impl.portal.ScreenCast;org.freedesktop.impl.portal.Print;";

    fn start(b: *Backend, address: []const u8) !void {
        b.loop = try Loop.init(gpa);
        try b.conn.init(gpa, &b.loop, address, .{});
        b.obj = .{ .path = impl_path, .ctx = b, .subtree = .{ .lookup = lookup } };
        b.fm_obj = .{ .path = "/org/freedesktop/FileManager1", .ctx = b, .interfaces = &.{&fm_iface} };
        try b.conn.exportObject(&b.obj);
        try b.conn.exportObject(&b.fm_obj);
        try b.conn.requestName(&b.owner);
        try b.conn.requestName(&b.fm_owner);
        while (b.owner.state != .primary or b.fm_owner.state != .primary) try b.loop.dispatch(10);
        b.thread = try std.Thread.spawn(.{}, run, .{b});
    }

    fn run(b: *Backend) void {
        while (!b.stop_flag.load(.acquire)) b.loop.dispatch(-1) catch return;
    }

    fn stop(b: *Backend) void {
        b.stop_flag.store(true, .release);
        b.loop.wake();
        b.thread.join();
        b.conn.deinit();
        b.loop.deinit();
        for (b.calls.items) |c| {
            inline for (.{ "interface", "member", "signature", "body", "fd_data" }) |f| gpa.free(@field(c, f));
        }
        b.calls.deinit(gpa);
        for (b.closed.items) |p| gpa.free(p);
        b.closed.deinit(gpa);
    }

    fn lookup(o: *dbus.Object, path: []const u8) ?dbus.Node {
        if (std.mem.eql(u8, path, impl_path)) return .{ .ctx = o.ctx, .interfaces = &ifaces };
        if (std.mem.startsWith(u8, path, impl_path ++ "/request/")) return .{ .ctx = o.ctx, .interfaces = &.{&request_iface} };
        if (std.mem.startsWith(u8, path, impl_path ++ "/session/")) return .{ .ctx = o.ctx, .interfaces = &.{&session_iface} };
        return null;
    }

    fn close(r: *dbus.Request) anyerror!void {
        const b: *Backend = @ptrCast(@alignCast(r.node.ctx));
        b.mutex.lock();
        defer b.mutex.unlock();
        try b.closed.append(gpa, try gpa.dupe(u8, r.path));
    }

    /// A file's contents from offset 0, or nothing.
    fn readFd(fd: i32) []u8 {
        const size = linux.lseek(fd, 0, linux.SEEK.END);
        if (linux.errno(size) != .SUCCESS or size == 0) return &.{};
        const data = gpa.alloc(u8, size) catch return &.{};
        if (linux.pread(fd, data.ptr, data.len, 0) != size) {
            gpa.free(data);
            return &.{};
        }
        return data;
    }

    fn handle(r: *dbus.Request) anyerror!void {
        const b: *Backend = @ptrCast(@alignCast(r.node.ctx));
        const msg = r.msg;
        const call: Call = .{
            .interface = try gpa.dupe(u8, msg.interface orelse ""),
            .member = try gpa.dupe(u8, msg.member.?),
            .signature = try gpa.dupe(u8, msg.signature),
            .body = try gpa.dupe(u8, msg.bodyBytes()),
            .fd_data = if (msg.fds.len > 0) readFd(msg.fds[0]) else &.{},
        };
        b.mutex.lock();
        const code = b.code;
        const results = b.results;
        b.calls.append(gpa, call) catch {};
        b.mutex.unlock();
        if (r.method.?.out.len == 0) return r.reply(.{});
        var reply = r.newReply();
        errdefer reply.deinit();
        try reply.body.writeUint32(code);
        const w = try vardict.Writer.begin(&reply.body);
        if (std.mem.eql(u8, call.member, "ChooseApplication")) {
            // The user picks the first application offered.
            var d = call.decoder();
            _ = try d.readObjectPath();
            _ = try d.readString();
            _ = try d.readString();
            const a = try d.beginArray();
            const first = if (a.next(&d)) try d.readString() else "siv-test-handler";
            try w.put("choice", first);
        } else if (results) |f| try f(&call, w);
        try w.end();
        try r.sendReply(&reply);
    }

    /// The last call of `member` on `interface` (a suffix such as
    /// "FileChooser"), copied into the caller's arena-free storage: valid
    /// until the backend stops.
    pub fn find(b: *Backend, interface: []const u8, member: []const u8) ?*const Call {
        b.mutex.lock();
        defer b.mutex.unlock();
        var i = b.calls.items.len;
        while (i > 0) {
            i -= 1;
            const c = &b.calls.items[i];
            if (std.mem.endsWith(u8, c.interface, interface) and std.mem.eql(u8, c.member, member)) return c;
        }
        return null;
    }

    pub fn wasClosed(b: *Backend, path: []const u8) bool {
        b.mutex.lock();
        defer b.mutex.unlock();
        for (b.closed.items) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }

    pub fn setResponse(b: *Backend, code: u32, results: ?*const fn (call: *const Call, w: vardict.Writer) anyerror!void) void {
        b.mutex.lock();
        defer b.mutex.unlock();
        b.code = code;
        b.results = results;
    }

    /// Emits the impl Notification's ActionInvoked, as a desktop does
    /// when the user activates a notification button.
    pub fn invokeAction(b: *Backend, app_id: []const u8, id: []const u8, action: []const u8, target: []const u8) !void {
        const S = struct {
            var args: [4][]const u8 = undefined;
            fn write(e: *dbus.Encoder) anyerror!void {
                try e.writeAll(.{ args[0], args[1], args[2] });
                try e.beginArray("v");
                if (args[3].len > 0) try e.write(dbus.variant(args[3]));
                try e.endArray();
            }
        };
        S.args = .{ app_id, id, action, target };
        try b.emit(impl_path, "org.freedesktop.impl.portal.Notification", "ActionInvoked", S.write);
    }

    /// Emits a signal from the backend's thread.
    pub fn emit(b: *Backend, path: []const u8, interface: []const u8, member: []const u8, comptime write: fn (e: *dbus.Encoder) anyerror!void) !void {
        const Ctx = struct {
            b: *Backend,
            path: []const u8,
            interface: []const u8,
            member: []const u8,
            done: std.atomic.Value(bool) = .init(false),
            remote: Loop.Remote = .{ .func = go, .cancel = go },
            fn go(rm: *Loop.Remote) void {
                const c: *@This() = @fieldParentPtr("remote", rm);
                var s = c.b.conn.signal(c.path, c.interface, c.member);
                if (write(&s.body)) {
                    _ = c.b.conn.send(&s) catch {};
                } else |_| s.deinit();
                c.done.store(true, .release);
            }
        };
        var ctx: Ctx = .{ .b = b, .path = path, .interface = interface, .member = member };
        b.loop.postRemote(&ctx.remote);
        while (!ctx.done.load(.acquire)) td.sleepMs(1);
    }
};

/// The whole desktop: bus, permission store, portal, backend, handler.
/// An application id with a desktop file, for portals that want one.
pub const test_app_id = "org.siv.Test";

pub const Desktop = struct {
    daemon: td.Daemon = .{},
    backend: Backend = .{},
    dir_buf: [64]u8 = undefined,
    dir: [:0]const u8 = "",
    store_pid: linux.pid_t = 0,
    portal_pid: linux.pid_t = 0,
    pipewire_pid: linux.pid_t = 0,
    log_fd: i32 = -1,

    var counter: u32 = 0;

    pub fn start(d: *Desktop) !void {
        var portal_buf: [64]u8 = undefined;
        const portal = td.findLibexec(&portal_buf, "xdg-desktop-portal") orelse {
            std.log.err("xdg-desktop-portal is not installed; run .agents/setup", .{});
            return error.PortalNotInstalled;
        };
        try d.daemon.start();
        errdefer d.daemon.stop();
        counter += 1;
        d.dir = try std.fmt.bufPrintSentinel(&d.dir_buf, "/tmp/siv-xdp-{d}-{d}", .{ linux.getpid(), counter }, 0);
        _ = linux.mkdir(d.dir, 0o700);
        for ([_][]const u8{ "portals", "data", "data/applications", "config", "run" }) |sub| {
            var buf: [128]u8 = undefined;
            _ = linux.mkdir(try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ d.dir, sub }, 0), 0o700);
        }
        var buf: [256]u8 = undefined;
        var text: [1024]u8 = undefined;
        try td.writeFile(try std.fmt.bufPrintSentinel(&buf, "{s}/portals/siv.portal", .{d.dir}, 0), try std.fmt.bufPrint(&text,
            \\[portal]
            \\DBusName={s}
            \\Interfaces={s}
            \\UseIn=siv-test
            \\
        , .{ backend_name, Backend.interfaces }));
        // OpenURI launches this handler, which records the URI.
        try td.writeFile(try std.fmt.bufPrintSentinel(&buf, "{s}/data/applications/siv-test-handler.desktop", .{d.dir}, 0), try std.fmt.bufPrint(&text,
            \\[Desktop Entry]
            \\Type=Application
            \\Name=siv test handler
            \\Exec=/bin/sh -c 'echo "$1" >> {s}/opened' sh %u
            \\MimeType=x-scheme-handler/sivtest;text/plain;application/octet-stream;
            \\
        , .{d.dir}));
        // The app id tests register (`Client.register`): the portal wants
        // its desktop file.
        try td.writeFile(try std.fmt.bufPrintSentinel(&buf, "{s}/data/applications/" ++ test_app_id ++ ".desktop", .{d.dir}, 0),
            \\[Desktop Entry]
            \\Type=Application
            \\Name=siv test
            \\Exec=/bin/true
            \\
        );
        try td.writeFile(try std.fmt.bufPrintSentinel(&buf, "{s}/config/mimeapps.list", .{d.dir}, 0),
            \\[Default Applications]
            \\x-scheme-handler/sivtest=siv-test-handler.desktop
            \\text/plain=siv-test-handler.desktop
            \\application/octet-stream=siv-test-handler.desktop
            \\
        );
        try d.backend.start(d.daemon.address);
        errdefer d.backend.stop();

        var env_bufs: [9][300]u8 = undefined;
        const envp = [_:null]?[*:0]const u8{
            "PATH=/usr/bin:/bin",
            try std.fmt.bufPrintSentinel(&env_bufs[0], "DBUS_SESSION_BUS_ADDRESS={s}", .{d.daemon.address}, 0),
            try std.fmt.bufPrintSentinel(&env_bufs[1], "HOME={s}", .{d.dir}, 0),
            try std.fmt.bufPrintSentinel(&env_bufs[2], "XDG_DATA_HOME={s}/data", .{d.dir}, 0),
            try std.fmt.bufPrintSentinel(&env_bufs[3], "XDG_CONFIG_HOME={s}/config", .{d.dir}, 0),
            try std.fmt.bufPrintSentinel(&env_bufs[4], "XDG_RUNTIME_DIR={s}/run", .{d.dir}, 0),
            try std.fmt.bufPrintSentinel(&env_bufs[5], "XDG_DESKTOP_PORTAL_DIR={s}/portals", .{d.dir}, 0),
            "XDG_CURRENT_DESKTOP=siv-test",
            "GIO_USE_VFS=local",
            "GSETTINGS_BACKEND=memory",
            "G_MESSAGES_DEBUG=all",
        };
        const log = try std.fmt.bufPrintSentinel(&buf, "{s}/portal.log", .{d.dir}, 0);
        const rc = linux.open(log, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(rc) == .SUCCESS) d.log_fd = @intCast(rc);
        var store_buf: [64]u8 = undefined;
        if (td.findLibexec(&store_buf, "xdg-permission-store")) |store| {
            d.store_pid = try td.spawn(store, &[_:null]?[*:0]const u8{ store, "--replace" }, &envp, if (d.log_fd >= 0) d.log_fd else null);
            try d.waitName("org.freedesktop.impl.portal.PermissionStore");
        }
        // A PipeWire daemon for screen casts' OpenPipeWireRemote, if
        // installed.
        const pipewire = "/usr/bin/pipewire";
        if (linux.access(pipewire, 1) == 0) {
            d.pipewire_pid = try td.spawn(pipewire, &[_:null]?[*:0]const u8{pipewire}, &envp, if (d.log_fd >= 0) d.log_fd else null);
            const sock = try std.fmt.bufPrintSentinel(&buf, "{s}/run/pipewire-0", .{d.dir}, 0);
            var waited: u32 = 0;
            while (linux.access(sock, 0) != 0) : (waited += 1) {
                if (waited > 500) return error.PipewireDidNotStart;
                td.sleepMs(10);
            }
        }
        d.portal_pid = try td.spawn(portal, &[_:null]?[*:0]const u8{ portal, "--replace", "--verbose" }, &envp, if (d.log_fd >= 0) d.log_fd else null);
        errdefer d.stop();
        try d.waitName("org.freedesktop.portal.Desktop");
    }

    /// Waits until `name` has an owner on the bus.
    fn waitName(d: *Desktop, name: []const u8) !void {
        var loop = try Loop.init(gpa);
        defer loop.deinit();
        var conn: Connection = undefined;
        try conn.init(gpa, &loop, d.daemon.address, .{});
        defer conn.deinit();
        var w: Connection.NameWatch = .{ .name = name };
        try conn.watchName(&w);
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        while (w.state != .owned) {
            if (Loop.now() > deadline) return error.PortalDidNotStart;
            try loop.dispatch(20);
        }
    }

    pub fn stop(d: *Desktop) void {
        if (d.portal_pid != 0) td.kill(d.portal_pid);
        if (d.store_pid != 0) td.kill(d.store_pid);
        if (d.pipewire_pid != 0) td.kill(d.pipewire_pid);
        d.pipewire_pid = 0;
        d.portal_pid = 0;
        d.store_pid = 0;
        d.backend.stop();
        d.daemon.stop();
        if (d.log_fd >= 0) _ = linux.close(d.log_fd);
        d.log_fd = -1;
        if (std.c.getenv("SIV_KEEP_PORTAL_DIR") == null) td.removeTree(d.dir);
    }

    pub fn hasPipewire(d: *const Desktop) bool {
        return d.pipewire_pid != 0;
    }

    /// What the handler recorded, or empty.
    pub fn opened(d: *const Desktop, buf: []u8) []const u8 {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/opened", .{d.dir}, 0) catch return "";
        const rc = linux.open(path, .{ .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return "";
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        const n = linux.read(fd, buf.ptr, buf.len);
        if (linux.errno(n) != .SUCCESS) return "";
        return std.mem.trimEnd(u8, buf[0..n], "\n");
    }
};

