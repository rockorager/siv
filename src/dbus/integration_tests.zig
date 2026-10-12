//! Integration tests against a private dbus-daemon (`zig build
//! test-integration`), and against GLib's gdbus as a second client
//! implementation. dbus-daemon validates every message strictly and
//! disconnects a sender of an invalid one, so these also check the wire
//! format against the reference implementation. Left out of `zig build
//! test`, which stays hermetic.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const Loop = @import("loop").Loop;
const Connection = @import("Connection.zig");
const object = @import("object.zig");
const codec = @import("codec.zig");
const Message = @import("message.zig").Message;
const Settings = @import("Settings.zig");
const FakePortal = @import("test_portal.zig").FakePortal;
const Observer = @import("test_portal.zig").Observer;

const gpa = testing.allocator;

const test_daemon = @import("test_daemon.zig");
const Daemon = test_daemon.Daemon;
const findExecutable = test_daemon.findExecutable;

const Harness = struct {
    loop: Loop,
    daemon: Daemon = .{},

    fn init(h: *Harness) !void {
        h.* = .{ .loop = try Loop.init(gpa) };
        errdefer h.loop.deinit();
        try h.daemon.start();
    }

    fn deinit(h: *Harness) void {
        h.daemon.stop();
        h.loop.deinit();
    }

    fn connect(h: *Harness, c: *Connection) !void {
        try c.init(gpa, &h.loop, h.daemon.address, .{});
        try h.until(c, struct {
            fn f(conn: *Connection) bool {
                return conn.uniqueName().len > 0 or !conn.connected();
            }
        }.f);
        if (!c.connected()) return error.Disconnected;
    }

    fn until(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        const deadline = Loop.now() + 5 * std.time.ns_per_s;
        while (!cond(ctx)) {
            if (Loop.now() > deadline) return error.TestTimeout;
            try h.loop.dispatch(100);
        }
    }

    fn settle(h: *Harness) !void {
        for (0..20) |_| try h.loop.dispatch(5);
    }
};

const Result = struct {
    done: bool = false,
    kind: enum { ok, err, failed } = .ok,
    err_name: [128]u8 = undefined,
    err_len: usize = 0,
    text: [8192]u8 = undefined,
    text_len: usize = 0,
    number: u32 = 0,

    fn cb(ctx: ?*anyopaque, reply: Connection.Reply) void {
        const r: *Result = @ptrCast(@alignCast(ctx));
        r.done = true;
        const m = switch (reply) {
            .ok => |m| m,
            .err => |m| blk: {
                r.kind = .err;
                @memcpy(r.err_name[0..m.error_name.?.len], m.error_name.?);
                r.err_len = m.error_name.?.len;
                break :blk m;
            },
            .failed => {
                r.kind = .failed;
                return;
            },
        };
        var d = m.body();
        if (d.peek()) |code| switch (code) {
            's' => {
                const s = d.readString() catch unreachable;
                const n = @min(s.len, r.text.len);
                @memcpy(r.text[0..n], s[0..n]);
                r.text_len = n;
            },
            'u' => r.number = d.readUint32() catch unreachable,
            else => {},
        };
    }

    fn isDone(r: *Result) bool {
        return r.done;
    }

    fn errName(r: *const Result) []const u8 {
        return r.err_name[0..r.err_len];
    }

    fn str(r: *const Result) []const u8 {
        return r.text[0..r.text_len];
    }
};

const Service = struct {
    deferred: ?Connection.Deferred = null,

    const iface: object.Interface = .{
        .name = "org.example.Service",
        .methods = &.{
            .{ .name = "Echo", .in = "s", .out = "s", .func = echo },
            .{ .name = "Sum", .in = "a{sv}", .out = "u", .func = sum },
            .{ .name = "ReadFd", .in = "h", .out = "s", .func = readFd },
            .{ .name = "Never", .out = "u", .func = never },
        },
        .properties = &.{.{ .name = "Version", .signature = "u", .get = version }},
        .signals = &.{.{ .name = "Ping", .signature = "so" }},
    };

    fn echo(r: *object.Request) anyerror!void {
        var d = r.args();
        try r.reply(.{try d.readString()});
    }

    /// Sums the u32 values of a dictionary, skipping others.
    fn sum(r: *object.Request) anyerror!void {
        var d = r.args();
        var total: u32 = 0;
        const a = try d.beginArray();
        while (a.next(&d)) {
            try d.beginDictEntry();
            _ = try d.readString();
            const vs = try d.beginVariant();
            if (std.mem.eql(u8, vs, "u")) total += try d.readUint32();
            try d.endVariant();
            try d.endDictEntry();
        }
        try r.reply(.{total});
    }

    fn readFd(r: *object.Request) anyerror!void {
        var d = r.args();
        var buf: [64]u8 = undefined;
        const n = linux.read(try d.readFd(), &buf, buf.len);
        try r.reply(.{buf[0..n]});
    }

    fn never(r: *object.Request) anyerror!void {
        const s: *Service = @ptrCast(@alignCast(r.node.ctx));
        s.deferred = r.deferReply();
    }

    fn version(_: object.PropertyContext, out: *codec.Encoder) anyerror!void {
        try out.writeUint32(3);
    }
};

test "calls, fds, and errors through dbus-daemon" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var a: Connection = undefined;
    var b: Connection = undefined;
    try h.connect(&a);
    defer a.deinit();
    try h.connect(&b);
    defer b.deinit();
    var svc: Service = .{};
    var obj: object.Object = .{ .path = "/svc", .ctx = &svc, .interfaces = &.{&Service.iface} };
    try b.exportObject(&obj);
    var name: Connection.NameOwner = .{ .name = "org.example.Service" };
    try b.requestName(&name);
    try h.until(&name, struct {
        fn f(o: *Connection.NameOwner) bool {
            return o.state == .primary;
        }
    }.f);

    var r: Result = .{};
    _ = try a.callMethod("org.example.Service", "/svc", "org.example.Service", "Echo", .{"through the daemon"}, Result.cb, &r);
    try h.until(&r, Result.isDone);
    try testing.expectEqualStrings("through the daemon", r.str());

    const E = codec.DictEntry([]const u8, codec.Variant(u32));
    r = .{};
    _ = try a.callMethod("org.example.Service", "/svc", null, "Sum", .{@as([]const E, &.{
        .{ .key = "a", .value = codec.variant(@as(u32, 40)) },
        .{ .key = "b", .value = codec.variant(@as(u32, 2)) },
    })}, Result.cb, &r);
    try h.until(&r, Result.isDone);
    try testing.expectEqual(@as(u32, 42), r.number);

    var pipe: [2]i32 = undefined;
    _ = linux.pipe2(&pipe, .{ .CLOEXEC = true });
    defer _ = linux.close(pipe[0]);
    _ = linux.write(pipe[1], "an fd", 5);
    _ = linux.close(pipe[1]);
    r = .{};
    _ = try a.callMethod("org.example.Service", "/svc", null, "ReadFd", .{codec.Fd{ .fd = pipe[0] }}, Result.cb, &r);
    try h.until(&r, Result.isDone);
    try testing.expectEqualStrings("an fd", r.str());

    // Errors from the bus and from the service.
    r = .{};
    _ = try a.callMethod("org.example.Missing", "/", null, "X", .{}, Result.cb, &r);
    try h.until(&r, Result.isDone);
    try testing.expectEqualStrings(Connection.errors.service_unknown, r.errName());
    r = .{};
    _ = try a.callMethod("org.example.Service", "/svc", "org.example.Service", "Echo", .{@as(u32, 1)}, Result.cb, &r);
    try h.until(&r, Result.isDone);
    try testing.expectEqualStrings(Connection.errors.invalid_args, r.errName());

    // A large message through the daemon.
    const big = try gpa.alloc(u8, 4 << 20);
    defer gpa.free(big);
    @memset(big, 'x');
    r = .{};
    _ = try a.callMethod("org.example.Service", "/svc", null, "Echo", .{big}, Result.cb, &r);
    try h.until(&r, Result.isDone);
    try testing.expect(r.kind == .ok);

    // The callee going away answers a pending call with NoReply.
    r = .{};
    _ = try a.callMethod("org.example.Service", "/svc", null, "Never", .{}, Result.cb, &r);
    try h.until(&svc, struct {
        fn f(s: *Service) bool {
            return s.deferred != null;
        }
    }.f);
    b.deinit();
    b = undefined;
    try h.until(&r, Result.isDone);
    try testing.expectEqualStrings(Connection.errors.no_reply, r.errName());
    try h.connect(&b); // for the deferred deinit
}

const Counter = struct {
    sub: Connection.Subscription,
    count: usize = 0,

    fn cb(s: *Connection.Subscription, _: *const Message) void {
        const self: *Counter = @fieldParentPtr("sub", s);
        self.count += 1;
    }
};

test "match rules and name ownership on dbus-daemon" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var a: Connection = undefined;
    var b: Connection = undefined;
    var c: Connection = undefined;
    inline for (.{ &a, &b, &c }) |conn| try h.connect(conn);
    defer inline for (.{ &a, &b, &c }) |conn| conn.deinit();

    var w: Connection.NameWatch = .{ .name = "org.example.Svc" };
    try a.watchName(&w);
    defer a.unwatchName(&w);
    var ob: Connection.NameOwner = .{ .name = "org.example.Svc", .flags = .{ .allow_replacement = true } };
    try b.requestName(&ob);
    try h.until(&w, struct {
        fn f(x: *Connection.NameWatch) bool {
            return x.state == .owned;
        }
    }.f);
    try testing.expectEqualStrings(b.uniqueName(), w.owner().?);

    // The daemon parses the rules siv formats, including quotes and args.
    var by_name: Counter = .{ .sub = .{ .rule = .{ .sender = "org.example.Svc", .member = "Ping", .args = &.{.{ .index = 0, .value = "it's" }} }, .func = Counter.cb } };
    var by_path: Counter = .{ .sub = .{ .rule = .{ .interface = "org.example.Service", .args = &.{.{ .index = 1, .kind = .path, .value = "/a/" }} }, .func = Counter.cb } };
    try a.subscribe(&by_name.sub);
    try a.subscribe(&by_path.sub);
    defer a.unsubscribe(&by_name.sub);
    defer a.unsubscribe(&by_path.sub);
    try h.settle();
    try b.emitSignal("/svc", "org.example.Service", "Ping", .{ "it's", codec.ObjectPath{ .path = "/a/b" } });
    try b.emitSignal("/svc", "org.example.Service", "Ping", .{ "other", codec.ObjectPath{ .path = "/b" } });
    try c.emitSignal("/svc", "org.example.Service", "Ping", .{ "it's", codec.ObjectPath{ .path = "/a/c" } });
    try h.until(&by_path, struct {
        fn f(x: *Counter) bool {
            return x.count == 2;
        }
    }.f);
    try h.settle();
    try testing.expectEqual(@as(usize, 1), by_name.count);

    // Replacement moves the name and tells both sides.
    var oc: Connection.NameOwner = .{ .name = "org.example.Svc", .flags = .{ .replace_existing = true } };
    try c.requestName(&oc);
    try h.until(&ob, struct {
        fn f(o: *Connection.NameOwner) bool {
            return o.state == .lost;
        }
    }.f);
    try waitOwner(&h, &w, c.uniqueName());
    try testing.expectEqual(Connection.NameOwner.State.primary, oc.state);
    // b was queued behind c, so it gets the name back.
    c.releaseName(&oc);
    try waitOwner(&h, &w, b.uniqueName());
    try h.until(&ob, struct {
        fn f(o: *Connection.NameOwner) bool {
            return o.state == .primary;
        }
    }.f);
    b.releaseName(&ob);
    try waitOwner(&h, &w, null);
}

fn waitOwner(h: *Harness, w: *Connection.NameWatch, expected: ?[]const u8) !void {
    const Ctx = struct {
        w: *Connection.NameWatch,
        expected: ?[]const u8,
        fn f(x: @This()) bool {
            const o = x.w.owner();
            if (x.expected) |e| return o != null and std.mem.eql(u8, o.?, e);
            return o == null and x.w.state == .unowned;
        }
    };
    try h.until(Ctx{ .w = w, .expected = expected }, Ctx.f);
}

test "portal settings through dbus-daemon" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var app: Connection = undefined;
    var portal_conn: Connection = undefined;
    try h.connect(&app);
    defer app.deinit();
    try h.connect(&portal_conn);
    defer portal_conn.deinit();

    var obs: Observer = .{};
    var settings: Settings = undefined;
    try settings.init(&app, .{ .on_change = Observer.cb, .ctx = &obs });
    defer settings.deinit();
    try h.until(&obs, struct {
        fn f(o: *Observer) bool {
            return o.calls == 1;
        }
    }.f);
    try testing.expect(settings.ready and !obs.last.any());

    var portal: FakePortal = .{ .conn = &portal_conn };
    try portal.start();
    try h.until(&obs, struct {
        fn f(o: *Observer) bool {
            return o.calls == 2;
        }
    }.f);
    try testing.expectEqual(Settings.ColorScheme.dark, settings.values.color_scheme);
    try testing.expectEqualStrings("Cantarell", settings.values.font.family.slice());

    try portal.change("org.gnome.desktop.interface", "cursor-size", .{ .i = 48 });
    try h.until(&obs, struct {
        fn f(o: *Observer) bool {
            return o.calls == 3;
        }
    }.f);
    try testing.expectEqual(@as(u32, 48), settings.values.cursor_size);
    try testing.expectEqual(Settings.Changed{ .cursor_size = true }, obs.last);
}

/// Runs gdbus (GLib's implementation) against the bus and returns its
/// output. Null if gdbus is not installed.
fn gdbus(h: *Harness, args: []const [*:0]const u8, out: []u8) !?[]const u8 {
    const exe = findExecutable("gdbus") orelse return null;
    var fds: [2]i32 = undefined;
    _ = linux.pipe2(&fds, .{ .CLOEXEC = true });
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    argv[0] = exe;
    for (args, 1..) |a, i| argv[i] = a;
    const envp = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
    const rc = linux.fork();
    if (rc == 0) {
        _ = linux.dup2(fds[1], 1);
        _ = linux.execve(exe, &argv, &envp);
        linux.exit_group(127);
    }
    _ = linux.close(fds[1]);
    defer _ = linux.close(fds[0]);
    // Serve the bus while gdbus runs.
    _ = linux.fcntl(fds[0], linux.F.SETFL, linux.SOCK.NONBLOCK);
    var n: usize = 0;
    const deadline = Loop.now() + 5 * std.time.ns_per_s;
    while (Loop.now() < deadline) {
        try h.loop.dispatch(10);
        const got = linux.read(fds[0], out[n..].ptr, out.len - n);
        if (linux.errno(got) == .AGAIN) continue;
        if (linux.errno(got) != .SUCCESS or got == 0) break;
        n += got;
    }
    var status: c_int = 0;
    _ = std.c.waitpid(@intCast(rc), &status, 0);
    if (status != 0) {
        std.debug.print("gdbus failed: {s}\n", .{out[0..n]});
        return error.GdbusFailed;
    }
    return out[0..n];
}

test "GLib's gdbus calls exported methods and reads introspection" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var b: Connection = undefined;
    try h.connect(&b);
    defer b.deinit();
    var svc: Service = .{};
    var obj: object.Object = .{ .path = "/svc", .ctx = &svc, .interfaces = &.{&Service.iface} };
    try b.exportObject(&obj);
    var name: Connection.NameOwner = .{ .name = "org.example.Service" };
    try b.requestName(&name);
    try h.settle();

    var buf: [8192]u8 = undefined;
    const addr = h.daemon.address.ptr;
    const call = (try gdbus(&h, &.{ "call", "--address", addr, "--dest", "org.example.Service", "--object-path", "/svc", "--method", "org.example.Service.Sum", "{'x': <uint32 5>, 'y': <'skip'>, 'z': <uint32 6>}" }, &buf)) orelse {
        std.log.warn("gdbus is not installed; skipping", .{});
        return;
    };
    try testing.expectEqualStrings("(uint32 11,)\n", call);

    const xml = (try gdbus(&h, &.{ "introspect", "--address", addr, "--dest", "org.example.Service", "--object-path", "/svc" }, &buf)).?;
    for ([_][]const u8{ "interface org.example.Service", "Echo(in  s arg_0,", "readonly u Version = 3;", "Ping(s arg_0," }) |want| {
        if (std.mem.indexOf(u8, xml, want) == null) {
            std.debug.print("missing {s} in\n{s}\n", .{ want, xml });
            return error.TestExpectedEqual;
        }
    }
}

fn measuring() bool {
    return testing.environ.getPosix("SIV_MEASURE") != null;
}

test "settings are ready well within the first-frame budget" {
    // D19: the first frame waits for the settings (at most 100 ms), so
    // their typical cost, from connecting to the session bus to the
    // portal's answer, must fit D25's 20 ms first-frame budget.
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var portal_conn: Connection = undefined;
    try h.connect(&portal_conn);
    defer portal_conn.deinit();
    var portal: FakePortal = .{ .conn = &portal_conn };
    try portal.start();
    try h.until(&portal, FakePortal.owns);

    var samples: [25]u64 = undefined;
    for (&samples) |*sample| {
        const t0 = Loop.now();
        var app: Connection = undefined;
        try app.init(gpa, &h.loop, h.daemon.address, .{});
        defer app.deinit();
        var settings: Settings = undefined;
        try settings.init(&app, .{});
        defer settings.deinit();
        try h.until(&settings, struct {
            fn f(s: *Settings) bool {
                return s.ready;
            }
        }.f);
        sample.* = Loop.now() - t0;
        try testing.expectEqual(Settings.ColorScheme.dark, settings.values.color_scheme);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const median = samples[samples.len / 2];
    if (measuring()) std.debug.print("\nsettings ready after connecting: median {d} us, max {d} us\n", .{ median / 1000, samples[samples.len - 1] / 1000 });
    try testing.expect(median < 20 * std.time.ns_per_ms);
}
