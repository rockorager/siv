//! Connection tests against the in-process `TestBus`: hermetic, on a real
//! loop and real sockets.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const Loop = @import("loop").Loop;
const Connection = @import("Connection.zig");
const TestBus = @import("TestBus.zig");
const object = @import("object.zig");
const codec = @import("codec.zig");
const Message = @import("message.zig").Message;

const gpa = testing.allocator;

/// A loop, a bus, and helpers to run until a condition holds.
const Harness = struct {
    loop: Loop,
    bus: TestBus,

    fn init(h: *Harness) !void {
        h.loop = try Loop.init(gpa);
        h.bus = .init(gpa, &h.loop);
    }

    fn deinit(h: *Harness) void {
        h.bus.deinit();
        h.loop.deinit();
    }

    fn connect(h: *Harness, c: *Connection, opts: Connection.Options) !void {
        try c.initFd(gpa, &h.loop, try h.bus.connect(), opts);
    }

    /// Dispatches until `cond(ctx)` holds. Everything here runs on this
    /// thread's loop, so the test is stuck only while the loop has
    /// nothing to do: fail after two seconds of that, however long a
    /// loaded machine makes the work itself take.
    fn until(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        var idle: u64 = 0;
        while (!cond(ctx)) {
            if (idle > 2 * std.time.ns_per_s) return error.TestTimeout;
            var pfd = [_]linux.pollfd{.{ .fd = h.loop.fd(), .events = linux.POLL.IN, .revents = 0 }};
            const t0 = Loop.now();
            if (linux.poll(&pfd, 1, 100) == 0) idle += Loop.now() - t0;
            try h.loop.dispatch(0);
        }
    }

    fn ready(h: *Harness, c: *Connection) !void {
        try h.until(c, struct {
            fn f(conn: *Connection) bool {
                return conn.uniqueName().len > 0;
            }
        }.f);
    }

    /// Dispatches a few idle iterations so that anything in flight lands.
    fn settle(h: *Harness) !void {
        for (0..20) |_| try h.loop.dispatch(5);
    }
};

/// Records a reply: its kind, error name, and first string or u32 argument.
const Result = struct {
    done: bool = false,
    kind: enum { ok, err, failed } = .ok,
    err_name: [128]u8 = undefined,
    err_len: usize = 0,
    text: [8192]u8 = undefined,
    text_len: usize = 0,
    number: u32 = 0,
    failure: ?Connection.CallError = null,

    fn cb(ctx: ?*anyopaque, reply: Connection.Reply) void {
        const r: *Result = @ptrCast(@alignCast(ctx));
        r.done = true;
        switch (reply) {
            .ok => |m| {
                r.kind = .ok;
                r.capture(m);
            },
            .err => |m| {
                r.kind = .err;
                @memcpy(r.err_name[0..m.error_name.?.len], m.error_name.?);
                r.err_len = m.error_name.?.len;
                r.capture(m);
            },
            .failed => |e| {
                r.kind = .failed;
                r.failure = e;
            },
        }
    }

    fn capture(r: *Result, m: *const Message) void {
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

fn waitReply(h: *Harness, r: *Result) !void {
    try h.until(r, Result.isDone);
}

// A small service: org.example.Calc with Add, Echo, Fail, Later, and a
// property.
const Calc = struct {
    total: u32 = 0,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    deferred: ?Connection.Deferred = null,

    const iface: object.Interface = .{
        .name = "org.example.Calc",
        .methods = &.{
            .{ .name = "Add", .in = "uu", .out = "u", .func = add },
            .{ .name = "Echo", .in = "s", .out = "s", .func = echo },
            .{ .name = "Fail", .func = fail },
            .{ .name = "Later", .out = "u", .func = later },
            .{ .name = "Bad", .out = "u", .func = bad },
            .{ .name = "ReadFd", .in = "h", .out = "s", .func = readFd },
        },
        .properties = &.{
            .{ .name = "Total", .signature = "u", .get = getTotal },
            .{ .name = "Name", .signature = "s", .access = .readwrite, .get = getName, .set = setName },
            .{ .name = "Secret", .signature = "s", .access = .write, .set = setName, .emits_changed = .invalidates },
        },
        .signals = &.{.{ .name = "Changed", .signature = "u" }},
    };

    fn self(r: *object.Request) *Calc {
        return @ptrCast(@alignCast(r.node.ctx));
    }

    fn add(r: *object.Request) anyerror!void {
        var d = r.args();
        const a, const b = try d.readAll(struct { u32, u32 });
        self(r).total += a + b;
        try r.reply(.{a + b});
    }

    fn echo(r: *object.Request) anyerror!void {
        var d = r.args();
        try r.reply(.{try d.readString()});
    }

    fn fail(_: *object.Request) anyerror!void {
        return error.AccessDenied;
    }

    fn later(r: *object.Request) anyerror!void {
        self(r).deferred = r.deferReply();
    }

    fn bad(r: *object.Request) anyerror!void {
        try r.reply(.{"not a u32"});
    }

    fn readFd(r: *object.Request) anyerror!void {
        var d = r.args();
        const fd = try d.readFd();
        var buf: [64]u8 = undefined;
        const n = linux.read(fd, &buf, buf.len);
        try r.reply(.{buf[0..n]});
    }

    fn getTotal(ctx: object.PropertyContext, out: *codec.Encoder) anyerror!void {
        const c: *Calc = @ptrCast(@alignCast(ctx.node.ctx));
        try out.writeUint32(c.total);
    }

    fn getName(ctx: object.PropertyContext, out: *codec.Encoder) anyerror!void {
        const c: *Calc = @ptrCast(@alignCast(ctx.node.ctx));
        try out.writeString(c.name_buf[0..c.name_len]);
    }

    fn setName(ctx: object.PropertyContext, in: *codec.Decoder) anyerror!void {
        const c: *Calc = @ptrCast(@alignCast(ctx.node.ctx));
        const s = try in.readString();
        @memcpy(c.name_buf[0..s.len], s);
        c.name_len = s.len;
    }
};

test "calls, replies, and error replies between two clients" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var a: Connection = undefined;
    var b: Connection = undefined;
    try h.connect(&a, .{});
    defer a.deinit();
    try h.connect(&b, .{});
    defer b.deinit();
    var calc: Calc = .{};
    var obj: object.Object = .{ .path = "/calc", .ctx = &calc, .interfaces = &.{&Calc.iface} };
    try b.exportObject(&obj);
    try h.ready(&a);
    try h.ready(&b);
    try testing.expect(!std.mem.eql(u8, a.uniqueName(), b.uniqueName()));
    const dest = b.uniqueName();

    var r: Result = .{};
    _ = try a.callMethod(dest, "/calc", "org.example.Calc", "Add", .{ @as(u32, 2), @as(u32, 40) }, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expect(r.kind == .ok);
    try testing.expectEqual(@as(u32, 42), r.number);

    // Without an interface the member is looked up in every interface.
    r = .{};
    _ = try a.callMethod(dest, "/calc", null, "Echo", .{"héllo"}, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expectEqualStrings("héllo", r.str());

    const cases = [_]struct { []const u8, ?[]const u8, []const u8, []const u8 }{
        .{ "/nothing", "org.example.Calc", "Add", Connection.errors.unknown_object },
        .{ "/calc", "org.example.Nope", "Add", Connection.errors.unknown_interface },
        .{ "/calc", "org.example.Calc", "Nope", Connection.errors.unknown_method },
        .{ "/calc", "org.example.Calc", "Fail", Connection.errors.access_denied },
        .{ "/calc", "org.example.Calc", "Bad", Connection.errors.failed },
    };
    for (cases) |cs| {
        r = .{};
        _ = try a.callMethod(dest, cs[0], cs[1], cs[2], .{ @as(u32, 1), @as(u32, 2) }, Result.cb, &r);
        try waitReply(&h, &r);
        try testing.expect(r.kind == .err);
        // Fail and Bad take no arguments, so they fail on the signature.
        const expected = if (std.mem.eql(u8, cs[2], "Fail") or std.mem.eql(u8, cs[2], "Bad")) Connection.errors.invalid_args else cs[3];
        try testing.expectEqualStrings(expected, r.errName());
    }
    for ([_]struct { []const u8, []const u8 }{ .{ "Fail", Connection.errors.access_denied }, .{ "Bad", Connection.errors.failed } }) |cs| {
        r = .{};
        _ = try a.callMethod(dest, "/calc", "org.example.Calc", cs[0], .{}, Result.cb, &r);
        try waitReply(&h, &r);
        try testing.expectEqualStrings(cs[1], r.errName());
    }

    // No such name on the bus.
    r = .{};
    _ = try a.callMethod("org.example.Missing", "/", null, "X", .{}, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expectEqualStrings(Connection.errors.service_unknown, r.errName());

    // Peer works on any path.
    r = .{};
    _ = try a.callMethod(dest, "/any/path", "org.freedesktop.DBus.Peer", "GetMachineId", .{}, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expect(r.kind == .ok);
    try testing.expectEqual(@as(usize, 32), r.str().len);
}

test "deferred replies, cancelled calls, and timeouts" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var a: Connection = undefined;
    var b: Connection = undefined;
    try h.connect(&a, .{});
    defer a.deinit();
    try h.connect(&b, .{});
    defer b.deinit();
    var calc: Calc = .{};
    var obj: object.Object = .{ .path = "/calc", .ctx = &calc, .interfaces = &.{&Calc.iface} };
    try b.exportObject(&obj);
    try h.ready(&b);

    var r: Result = .{};
    _ = try a.callMethod(b.uniqueName(), "/calc", null, "Later", .{}, Result.cb, &r);
    try h.until(&calc, struct {
        fn f(c: *Calc) bool {
            return c.deferred != null;
        }
    }.f);
    try testing.expect(!r.done);
    var reply = calc.deferred.?.newReply(&b);
    try reply.body.writeUint32(7);
    try calc.deferred.?.send(&b, &reply);
    try waitReply(&h, &r);
    try testing.expectEqual(@as(u32, 7), r.number);

    // A cancelled call's callback never runs.
    var cancelled: Result = .{};
    const serial = try a.callMethod(b.uniqueName(), "/calc", null, "Echo", .{"x"}, Result.cb, &cancelled);
    a.cancelCall(serial);
    try h.settle();
    try testing.expect(!cancelled.done);

    // A call nobody answers times out, 30 ms after it was made at the
    // earliest.
    var timed: Result = .{};
    var call = a.methodCall(b.uniqueName(), "/calc", null, "Later");
    const start = Loop.now();
    _ = try a.call(&call, Result.cb, &timed, .{ .timeout_ms = 30 });
    try waitReply(&h, &timed);
    try testing.expect(timed.kind == .failed and timed.failure.? == error.Timeout);
    try testing.expect(Loop.now() - start >= 30 * std.time.ns_per_ms);
}

const Signals = struct {
    count: usize = 0,
    last: u32 = 0,
    sub: Connection.Subscription,

    fn cb(s: *Connection.Subscription, m: *const Message) void {
        const self: *Signals = @fieldParentPtr("sub", s);
        self.count += 1;
        var d = m.body();
        if (d.peek() == 'u') self.last = d.readUint32() catch 0;
    }
};

test "signals reach subscriptions whose rules match" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var a: Connection = undefined;
    var b: Connection = undefined;
    var c: Connection = undefined;
    inline for (.{ &a, &b, &c }) |conn| try h.connect(conn, .{});
    defer inline for (.{ &a, &b, &c }) |conn| conn.deinit();
    inline for (.{ &a, &b, &c }) |conn| try h.ready(conn);

    // B owns a well-known name; A follows its signals by that name, and
    // also has a broad subscription.
    var owner: Connection.NameOwner = .{ .name = "org.example.Svc" };
    try b.requestName(&owner);
    var by_name: Signals = .{ .sub = .{ .rule = .{ .sender = "org.example.Svc", .interface = "org.example.Calc", .member = "Changed" }, .func = Signals.cb } };
    var broad: Signals = .{ .sub = .{ .rule = .{ .interface = "org.example.Calc" }, .func = Signals.cb } };
    var by_path: Signals = .{ .sub = .{ .rule = .{ .path_namespace = "/calc/sub" }, .func = Signals.cb } };
    try a.subscribe(&by_name.sub);
    try a.subscribe(&broad.sub);
    try a.subscribe(&by_path.sub);
    try h.until(&owner, struct {
        fn f(o: *Connection.NameOwner) bool {
            return o.state == .primary;
        }
    }.f);
    try h.settle(); // the matches and name lookup land

    try b.emitSignal("/calc", "org.example.Calc", "Changed", .{@as(u32, 5)});
    try c.emitSignal("/calc/sub/x", "org.example.Calc", "Changed", .{@as(u32, 6)});
    try h.until(&broad, struct {
        fn f(s: *Signals) bool {
            return s.count == 2;
        }
    }.f);
    try h.settle();
    // C's signal passed the broad rule but not the one for B's name.
    try testing.expectEqual(@as(usize, 1), by_name.count);
    try testing.expectEqual(@as(u32, 5), by_name.last);
    try testing.expectEqual(@as(usize, 1), by_path.count);
    try testing.expectEqual(@as(u32, 6), by_path.last);

    a.unsubscribe(&broad.sub);
    try b.emitSignal("/calc", "org.example.Calc", "Changed", .{@as(u32, 9)});
    try h.until(&by_name, struct {
        fn f(s: *Signals) bool {
            return s.count == 2;
        }
    }.f);
    try h.settle();
    try testing.expectEqual(@as(usize, 2), broad.count);
    a.unsubscribe(&by_name.sub);
    a.unsubscribe(&by_path.sub);
}

const Watcher = struct {
    watch: Connection.NameWatch,
    changes: usize = 0,
    owner_buf: [64]u8 = undefined,
    owner_len: usize = 0,

    fn cb(w: *Connection.NameWatch) void {
        const self: *Watcher = @fieldParentPtr("watch", w);
        self.changes += 1;
        const o = w.owner() orelse "";
        @memcpy(self.owner_buf[0..o.len], o);
        self.owner_len = o.len;
    }

    fn owner(self: *const Watcher) []const u8 {
        return self.owner_buf[0..self.owner_len];
    }
};

test "name ownership and watching follow the bus" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var a: Connection = undefined;
    var b: Connection = undefined;
    var c: Connection = undefined;
    inline for (.{ &a, &b, &c }) |conn| try h.connect(conn, .{});
    defer inline for (.{ &a, &c }) |conn| conn.deinit();
    inline for (.{ &a, &b, &c }) |conn| try h.ready(conn);

    var w: Watcher = .{ .watch = .{ .name = "org.example.Svc", .func = Watcher.cb } };
    try a.watchName(&w.watch);
    try h.until(&w, struct {
        fn f(x: *Watcher) bool {
            return x.changes == 1;
        }
    }.f);
    try testing.expect(w.watch.owner() == null);

    const States = struct {
        var log: [8]Connection.NameOwner.State = undefined;
        var n: usize = 0;
        fn cb(o: *Connection.NameOwner) void {
            log[n] = o.state;
            n += 1;
        }
    };
    var ob: Connection.NameOwner = .{ .name = "org.example.Svc", .func = States.cb, .flags = .{ .allow_replacement = true } };
    try b.requestName(&ob);
    try h.until(&w, struct {
        fn f(x: *Watcher) bool {
            return x.changes == 2;
        }
    }.f);
    try testing.expectEqualStrings(b.uniqueName(), w.owner());
    try testing.expectEqual(Connection.NameOwner.State.primary, ob.state);

    var oc: Connection.NameOwner = .{ .name = "org.example.Svc", .flags = .{ .do_not_queue = true } };
    try c.requestName(&oc);
    try h.until(&oc, struct {
        fn f(o: *Connection.NameOwner) bool {
            return o.state == .exists;
        }
    }.f);
    c.releaseName(&oc);
    oc = .{ .name = "org.example.Svc", .flags = .{ .replace_existing = true } };
    try c.requestName(&oc);
    try h.until(&ob, struct {
        fn f(o: *Connection.NameOwner) bool {
            return o.state == .lost;
        }
    }.f);
    try testing.expectEqual(Connection.NameOwner.State.primary, oc.state);
    try h.until(&w, struct {
        fn f(x: *Watcher) bool {
            return x.changes == 3;
        }
    }.f);
    try testing.expectEqualStrings(c.uniqueName(), w.owner());
    try testing.expectEqualSlices(Connection.NameOwner.State, &.{ .primary, .lost }, States.log[0..States.n]);

    // The owner disconnecting releases the name.
    b.deinit();
    h.bus.kill(c.uniqueName());
    try h.until(&w, struct {
        fn f(x: *Watcher) bool {
            return x.changes == 4;
        }
    }.f);
    try testing.expect(w.watch.owner() == null);
    a.unwatchName(&w.watch);
}

test "properties: Get, GetAll, Set, and PropertiesChanged" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var a: Connection = undefined;
    var b: Connection = undefined;
    try h.connect(&a, .{});
    defer a.deinit();
    try h.connect(&b, .{});
    defer b.deinit();
    var calc: Calc = .{ .total = 11 };
    var obj: object.Object = .{ .path = "/calc", .ctx = &calc, .interfaces = &.{&Calc.iface} };
    try b.exportObject(&obj);
    try h.ready(&a);
    try h.ready(&b);
    const dest = b.uniqueName();
    const props = "org.freedesktop.DBus.Properties";

    const GetResult = struct {
        done: bool = false,
        value: u32 = 0,
        names: usize = 0,
        err: bool = false,
        fn get(ctx: ?*anyopaque, reply: Connection.Reply) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.done = true;
            const m = switch (reply) {
                .ok => |m| m,
                else => {
                    r.err = true;
                    return;
                },
            };
            var d = m.body();
            if (std.mem.eql(u8, m.signature, "v")) {
                _ = d.beginVariant() catch unreachable;
                r.value = d.readUint32() catch unreachable;
            } else {
                const arr = d.beginArray() catch unreachable;
                while (arr.next(&d)) : (r.names += 1) d.skip() catch unreachable;
            }
        }
        fn isDone(r: *@This()) bool {
            return r.done;
        }
    };
    var g: GetResult = .{};
    _ = try a.callMethod(dest, "/calc", props, "Get", .{ "org.example.Calc", "Total" }, GetResult.get, &g);
    try h.until(&g, GetResult.isDone);
    try testing.expectEqual(@as(u32, 11), g.value);

    g = .{};
    _ = try a.callMethod(dest, "/calc", props, "GetAll", .{"org.example.Calc"}, GetResult.get, &g);
    try h.until(&g, GetResult.isDone);
    try testing.expectEqual(@as(usize, 2), g.names); // Secret is write-only

    var r: Result = .{};
    _ = try a.callMethod(dest, "/calc", props, "Set", .{ "org.example.Calc", "Name", codec.variant(@as([]const u8, "abc")) }, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expect(r.kind == .ok);
    try testing.expectEqualStrings("abc", calc.name_buf[0..calc.name_len]);

    const set_errors = [_]struct { []const u8, []const u8 }{
        .{ "Total", Connection.errors.property_read_only },
        .{ "Nope", Connection.errors.unknown_property },
    };
    for (set_errors) |cs| {
        r = .{};
        _ = try a.callMethod(dest, "/calc", props, "Set", .{ "org.example.Calc", cs[0], codec.variant(@as(u32, 1)) }, Result.cb, &r);
        try waitReply(&h, &r);
        try testing.expectEqualStrings(cs[1], r.errName());
    }
    r = .{};
    _ = try a.callMethod(dest, "/calc", props, "Set", .{ "org.example.Calc", "Name", codec.variant(@as(u32, 1)) }, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expectEqualStrings(Connection.errors.invalid_args, r.errName());

    // PropertiesChanged carries values and invalidated names.
    const Changed = struct {
        sub: Connection.Subscription,
        got: bool = false,
        total: u32 = 0,
        invalidated: [32]u8 = undefined,
        inv_len: usize = 0,
        fn cb(s: *Connection.Subscription, m: *const Message) void {
            const self: *@This() = @fieldParentPtr("sub", s);
            self.got = true;
            var d = m.body();
            _ = d.readString() catch unreachable;
            const arr = d.beginArray() catch unreachable;
            while (arr.next(&d)) {
                d.beginDictEntry() catch unreachable;
                _ = d.readString() catch unreachable;
                _ = d.beginVariant() catch unreachable;
                self.total = d.readUint32() catch unreachable;
                d.endVariant() catch unreachable;
                d.endDictEntry() catch unreachable;
            }
            d.endArray(arr) catch unreachable;
            const inv = d.beginArray() catch unreachable;
            while (inv.next(&d)) {
                const s2 = d.readString() catch unreachable;
                @memcpy(self.invalidated[0..s2.len], s2);
                self.inv_len = s2.len;
            }
        }
        fn isGot(self: *@This()) bool {
            return self.got;
        }
    };
    var changed: Changed = .{ .sub = .{ .rule = .{ .interface = props, .member = "PropertiesChanged", .path = "/calc" }, .func = Changed.cb } };
    try a.subscribe(&changed.sub);
    try h.settle();
    calc.total = 99;
    try b.emitPropertiesChanged("/calc", .{ .ctx = &calc, .interfaces = obj.interfaces }, &Calc.iface, &.{ "Total", "Secret" });
    try h.until(&changed, Changed.isGot);
    try testing.expectEqual(@as(u32, 99), changed.total);
    try testing.expectEqualStrings("Secret", changed.invalidated[0..changed.inv_len]);
    a.unsubscribe(&changed.sub);
}

/// A tree of `count` nodes exported as one subtree: /tree/<n>, children of
/// node n are 2n+1 and 2n+2, as in a heap.
const Tree = struct {
    count: u32,
    calls: u32 = 0,

    const node_iface: object.Interface = .{
        .name = "org.example.Node",
        .methods = &.{.{ .name = "Id", .out = "u", .func = id }},
    };

    fn parse(path: []const u8) ?u32 {
        if (path.len <= "/tree/".len) return null;
        return std.fmt.parseInt(u32, path["/tree/".len..], 10) catch null;
    }

    fn lookup(o: *object.Object, path: []const u8) ?object.Node {
        const t: *Tree = @ptrCast(@alignCast(o.ctx));
        if (std.mem.eql(u8, path, "/tree")) return .{ .ctx = t };
        const n = parse(path) orelse return null;
        if (n >= t.count) return null;
        return .{ .ctx = t, .interfaces = &.{&node_iface} };
    }

    fn children(o: *object.Object, path: []const u8, out: *object.ChildList) std.mem.Allocator.Error!void {
        const t: *Tree = @ptrCast(@alignCast(o.ctx));
        if (std.mem.eql(u8, path, "/tree")) return out.add("0");
        const n = parse(path) orelse return;
        var buf: [16]u8 = undefined;
        for ([_]u64{ 2 * @as(u64, n) + 1, 2 * @as(u64, n) + 2 }) |child| {
            if (child < t.count) try out.add(std.fmt.bufPrint(&buf, "{d}", .{child}) catch unreachable);
        }
    }

    fn id(r: *object.Request) anyerror!void {
        const t: *Tree = @ptrCast(@alignCast(r.node.ctx));
        t.calls += 1;
        try r.reply(.{parse(r.path).?});
    }
};

test "a subtree serves a large tree from one registration, with introspection" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var a: Connection = undefined;
    var b: Connection = undefined;
    try h.connect(&a, .{});
    defer a.deinit();
    try h.connect(&b, .{});
    defer b.deinit();
    var tree: Tree = .{ .count = 100_000 };
    var obj: object.Object = .{ .path = "/tree", .ctx = &tree, .subtree = .{ .lookup = Tree.lookup, .children = Tree.children } };
    var calc: Calc = .{};
    var calc_obj: object.Object = .{ .path = "/other/calc", .ctx = &calc, .interfaces = &.{&Calc.iface} };
    try b.exportObject(&obj);
    try b.exportObject(&calc_obj);
    try h.ready(&b);
    const dest = b.uniqueName();

    var r: Result = .{};
    _ = try a.callMethod(dest, "/tree/99999", "org.example.Node", "Id", .{}, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expectEqual(@as(u32, 99999), r.number);
    r = .{};
    _ = try a.callMethod(dest, "/tree/100000", "org.example.Node", "Id", .{}, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expectEqualStrings(Connection.errors.unknown_object, r.errName());

    const xml_cases = [_]struct { []const u8, []const []const u8, []const []const u8 }{
        .{ "/", &.{ "<node name=\"tree\"/>", "<node name=\"other\"/>" }, &.{"org.example"} },
        .{ "/other", &.{"<node name=\"calc\"/>"}, &.{"org.example"} },
        .{ "/other/calc", &.{ "org.example.Calc", "org.freedesktop.DBus.Properties" }, &.{"<node name="} },
        .{ "/tree", &.{"<node name=\"0\"/>"}, &.{"org.example.Node"} },
        .{ "/tree/1", &.{ "org.example.Node", "<node name=\"3\"/>", "<node name=\"4\"/>" }, &.{"Properties"} },
        .{ "/tree/60000", &.{"org.example.Node"}, &.{"<node name="} },
    };
    for (xml_cases) |cs| {
        r = .{};
        _ = try a.callMethod(dest, cs[0], "org.freedesktop.DBus.Introspectable", "Introspect", .{}, Result.cb, &r);
        try waitReply(&h, &r);
        try testing.expect(r.kind == .ok);
        for (cs[1]) |want| if (std.mem.indexOf(u8, r.str(), want) == null) {
            std.debug.print("{s}: missing {s} in\n{s}\n", .{ cs[0], want, r.str() });
            return error.TestExpectedEqual;
        };
        for (cs[2]) |unwanted| try testing.expect(std.mem.indexOf(u8, r.str(), unwanted) == null);
    }
    r = .{};
    _ = try a.callMethod(dest, "/nothing", "org.freedesktop.DBus.Introspectable", "Introspect", .{}, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expectEqualStrings(Connection.errors.unknown_object, r.errName());
}

test "fds pass with calls, and calls with fds fail when the bus refuses them" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var a: Connection = undefined;
    var b: Connection = undefined;
    try h.connect(&a, .{});
    defer a.deinit();
    try h.connect(&b, .{});
    defer b.deinit();
    var calc: Calc = .{};
    var obj: object.Object = .{ .path = "/calc", .ctx = &calc, .interfaces = &.{&Calc.iface} };
    try b.exportObject(&obj);
    try h.ready(&b);

    var pipe: [2]i32 = undefined;
    _ = linux.pipe2(&pipe, .{ .CLOEXEC = true });
    defer _ = linux.close(pipe[0]);
    _ = linux.write(pipe[1], "through the socket", 18);
    _ = linux.close(pipe[1]);
    var r: Result = .{};
    _ = try a.callMethod(b.uniqueName(), "/calc", null, "ReadFd", .{codec.Fd{ .fd = pipe[0] }}, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expectEqualStrings("through the socket", r.str());

    // A bus that refuses fds: the call queued before authentication
    // finished fails, and later ones are refused at once.
    h.bus.agree_fds = false;
    var c: Connection = undefined;
    try h.connect(&c, .{});
    defer c.deinit();
    r = .{};
    _ = try c.callMethod(b.uniqueName(), "/calc", null, "ReadFd", .{codec.Fd{ .fd = pipe[0] }}, Result.cb, &r);
    try waitReply(&h, &r);
    try testing.expect(r.kind == .failed and r.failure.? == error.FdsNotSupported);
    try h.ready(&c);
    try testing.expectError(error.FdsNotSupported, c.callMethod(b.uniqueName(), "/calc", null, "ReadFd", .{codec.Fd{ .fd = pipe[0] }}, Result.cb, &r));
}

test "large messages and many pipelined calls" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var a: Connection = undefined;
    var b: Connection = undefined;
    try h.connect(&a, .{});
    defer a.deinit();
    try h.connect(&b, .{});
    defer b.deinit();
    var calc: Calc = .{};
    var obj: object.Object = .{ .path = "/calc", .ctx = &calc, .interfaces = &.{&Calc.iface} };
    try b.exportObject(&obj);
    try h.ready(&b);

    // A 9 MiB string crosses many reads and partial writes, and the
    // pause in reading above 8 MiB of undispatched bytes.
    const big = try gpa.alloc(u8, 9 << 20);
    defer gpa.free(big);
    for (big, 0..) |*x, i| x.* = 'a' + @as(u8, @intCast(i % 26));
    const Big = struct {
        done: bool = false,
        ok: bool = false,
        expected: []const u8,
        fn cb(ctx: ?*anyopaque, reply: Connection.Reply) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done = true;
            var d = reply.ok.body();
            self.ok = std.mem.eql(u8, d.readString() catch "", self.expected);
        }
        fn isDone(self: *@This()) bool {
            return self.done;
        }
    };
    var bg: Big = .{ .expected = big };
    _ = try a.callMethod(b.uniqueName(), "/calc", null, "Echo", .{big}, Big.cb, &bg);
    try h.until(&bg, Big.isDone);
    try testing.expect(bg.ok);

    const Count = struct {
        n: u32 = 0,
        sum: u64 = 0,
        fn cb(ctx: ?*anyopaque, reply: Connection.Reply) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n += 1;
            var d = reply.ok.body();
            self.sum += d.readUint32() catch 0;
        }
        fn all(self: *@This()) bool {
            return self.n == 1000;
        }
    };
    var count: Count = .{};
    for (0..1000) |i| _ = try a.callMethod(b.uniqueName(), "/calc", null, "Add", .{ @as(u32, @intCast(i)), @as(u32, 0) }, Count.cb, &count);
    try h.until(&count, Count.all);
    try testing.expectEqual(@as(u64, 999 * 1000 / 2), count.sum);
}

test "a closed connection fails pending calls and reports it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const Events = struct {
        ready: usize = 0,
        disconnected: usize = 0,
        fn cb(ctx: ?*anyopaque, _: *Connection, e: Connection.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (e) {
                .ready => self.ready += 1,
                .disconnected => self.disconnected += 1,
            }
        }
        fn gone(self: *@This()) bool {
            return self.disconnected == 1;
        }
    };
    var ev: Events = .{};
    var a: Connection = undefined;
    var b: Connection = undefined;
    try h.connect(&a, .{ .on_event = Events.cb, .ctx = &ev });
    defer a.deinit();
    try h.connect(&b, .{});
    defer b.deinit();
    var calc: Calc = .{};
    var obj: object.Object = .{ .path = "/calc", .ctx = &calc, .interfaces = &.{&Calc.iface} };
    try b.exportObject(&obj);
    try h.ready(&a);
    try h.ready(&b);
    try testing.expectEqual(@as(usize, 1), ev.ready);

    var r: Result = .{};
    _ = try a.callMethod(b.uniqueName(), "/calc", null, "Later", .{}, Result.cb, &r);
    try h.until(&calc, struct {
        fn f(c: *Calc) bool {
            return c.deferred != null;
        }
    }.f);
    h.bus.kill(a.uniqueName());
    try h.until(&ev, Events.gone);
    try testing.expect(r.done and r.kind == .failed and r.failure.? == error.Disconnected);
    try testing.expect(!a.connected());
    try testing.expectError(error.Disconnected, a.callMethod(b.uniqueName(), "/calc", null, "Echo", .{"x"}, Result.cb, &r));
}

test "peer-to-peer connections need no bus" {
    var loop = try Loop.init(gpa);
    defer loop.deinit();
    var fds: [2]i32 = undefined;
    _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds);
    defer _ = linux.close(fds[1]);
    const Ready = struct {
        var ready = false;
        fn cb(_: ?*anyopaque, _: *Connection, e: Connection.Event) void {
            if (e == .ready) ready = true;
        }
    };
    var c: Connection = undefined;
    try c.initFd(gpa, &loop, fds[0], .{ .bus = false, .unix_fds = false, .on_event = Ready.cb });
    defer c.deinit();
    // Play the server by hand.
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    while (std.mem.indexOf(u8, buf[0..n], "BEGIN\r\n") == null) {
        try loop.dispatch(10);
        const rc = linux.read(fds[1], buf[n..].ptr, buf.len - n);
        if (linux.errno(rc) == .SUCCESS) n += rc;
    }
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "\x00AUTH EXTERNAL "));
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "NEGOTIATE_UNIX_FD") == null);
    _ = linux.write(fds[1], "OK 0123456789abcdef0123456789abcdef\r\n", 37);
    while (!Ready.ready) try loop.dispatch(100);
    try testing.expectEqualStrings("", c.uniqueName());
}

const Settings = @import("Settings.zig");
const FakePortal = @import("test_portal.zig").FakePortal;
const Observer = @import("test_portal.zig").Observer;

test "settings: defaults without a portal, then live values once it starts" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var app: Connection = undefined;
    var portal_conn: Connection = undefined;
    try h.connect(&app, .{});
    defer app.deinit();
    try h.connect(&portal_conn, .{});
    defer portal_conn.deinit();

    var obs: Observer = .{};
    var settings: Settings = undefined;
    try settings.init(&app, .{ .on_change = Observer.cb, .ctx = &obs });
    defer settings.deinit();
    try h.until(&settings, struct {
        fn f(s: *Settings) bool {
            return s.ready;
        }
    }.f);
    // No portal: ready with the defaults, reported once.
    try testing.expectEqual(@as(usize, 1), obs.calls);
    try testing.expect(!obs.last.any());
    try testing.expectEqual(Settings.ColorScheme.no_preference, settings.values.color_scheme);
    try testing.expectEqualStrings("sans-serif", settings.values.font.family.slice());

    // The portal appears: the client reads everything.
    var portal: FakePortal = .{ .conn = &portal_conn };
    try portal.start();
    try h.until(&obs, struct {
        fn f(o: *Observer) bool {
            return o.calls == 2;
        }
    }.f);
    try testing.expectEqualStrings("org.freedesktop.appearance,org.gnome.desktop.interface,org.gnome.desktop.a11y.interface,org.gnome.desktop.peripherals.mouse,org.kde.kdeglobals.General,org.kde.kdeglobals.KDE,org.kde.kdeglobals.Icons", portal.askedFor());
    const v = settings.values;
    try testing.expectEqual(Settings.ColorScheme.dark, v.color_scheme);
    try testing.expectEqual([3]f64{ 0.2, 0.4, 0.8 }, v.accent_color.?);
    try testing.expect(v.reduced_motion);
    try testing.expectEqual(@as(f64, 1.5), v.text_scale);
    try testing.expectEqualStrings("Cantarell", v.font.family.slice());
    try testing.expectEqualStrings("Cantarell", v.document_font.family.slice());
    try testing.expectEqualStrings("Source Code Pro", v.monospace_font.family.slice());
    try testing.expectEqualStrings("Adwaita", v.cursor_theme.slice());
    try testing.expectEqualStrings("breeze", v.icon_theme.slice());
    try testing.expectEqual(@as(u32, 32), v.cursor_size);
    try testing.expectEqual(@as(u32, 300), v.double_click_ms);
    // GNOME's period, and KDE's string "0" turning blinking off.
    try testing.expectEqual(@as(u32, 1000), v.cursor_blink_ms);
    try testing.expect(!v.cursor_blink);
    try testing.expect(obs.last.color_scheme and obs.last.accent_color and obs.last.cursor_size and !obs.last.contrast);

    // Live changes.
    try portal.change("org.freedesktop.appearance", "color-scheme", .{ .u = 2 });
    try h.until(&obs, struct {
        fn f(o: *Observer) bool {
            return o.calls == 3;
        }
    }.f);
    try testing.expectEqual(Settings.ColorScheme.light, settings.values.color_scheme);
    try testing.expectEqual(Settings.Changed{ .color_scheme = true }, obs.last);

    // An out-of-range accent clears it; an unknown key changes nothing.
    try portal.change("org.example", "x", .{ .u = 1 });
    try portal.change("org.freedesktop.appearance", "accent-color", .{ .rgb = .{ 2, 0, 0 } });
    try h.until(&obs, struct {
        fn f(o: *Observer) bool {
            return o.calls == 4;
        }
    }.f);
    try testing.expect(settings.values.accent_color == null);
    try testing.expectEqual(Settings.Changed{ .accent_color = true }, obs.last);

    // The same signal from another connection is not the portal's.
    var other_conn: Connection = undefined;
    try h.connect(&other_conn, .{});
    defer other_conn.deinit();
    var impostor: FakePortal = .{ .conn = &other_conn };
    try impostor.change("org.freedesktop.appearance", "color-scheme", .{ .u = 1 });
    try h.settle();
    try testing.expectEqual(Settings.ColorScheme.light, settings.values.color_scheme);

    // The portal restarting is read again; going away keeps the values.
    portal.stop();
    try h.settle();
    try testing.expectEqual(@as(usize, 4), obs.calls);
    portal.color_scheme = 0;
    try portal.start();
    try h.until(&obs, struct {
        fn f(o: *Observer) bool {
            return o.calls == 5;
        }
    }.f);
    try testing.expectEqual(Settings.ColorScheme.no_preference, settings.values.color_scheme);
    try testing.expectEqual(@as(u32, 2), portal.reads);
}

test "steady calls, replies, and signals allocate nothing after warm-up" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var counting = std.testing.FailingAllocator.init(gpa, .{});
    const alloc = counting.allocator();
    var a: Connection = undefined;
    var b: Connection = undefined;
    try a.initFd(alloc, &h.loop, try h.bus.connect(), .{});
    defer a.deinit();
    try b.initFd(alloc, &h.loop, try h.bus.connect(), .{});
    defer b.deinit();
    var calc: Calc = .{};
    var obj: object.Object = .{ .path = "/calc", .ctx = &calc, .interfaces = &.{&Calc.iface} };
    try b.exportObject(&obj);
    var sig: Signals = .{ .sub = .{ .rule = .{ .interface = "org.example.Calc", .member = "Changed" }, .func = Signals.cb } };
    try a.subscribe(&sig.sub);
    defer a.unsubscribe(&sig.sub);
    try h.ready(&a);
    try h.ready(&b);

    const Round = struct {
        fn run(hh: *Harness, ca: *Connection, cs: *Connection, s: *Signals, n: usize) !void {
            const Count = struct {
                left: usize,
                fn cb(ctx: ?*anyopaque, _: Connection.Reply) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    self.left -= 1;
                }
                fn done(self: *@This()) bool {
                    return self.left == 0;
                }
            };
            var count: Count = .{ .left = n };
            const want = s.count + n;
            for (0..n) |i| {
                _ = try ca.callMethod(cs.uniqueName(), "/calc", null, "Add", .{ @as(u32, @intCast(i)), @as(u32, 1) }, Count.cb, &count);
                try cs.emitSignal("/calc", "org.example.Calc", "Changed", .{@as(u32, @intCast(i))});
            }
            try hh.until(&count, Count.done);
            const Want = struct {
                s: *Signals,
                want: usize,
                fn f(x: @This()) bool {
                    return x.s.count == x.want;
                }
            };
            try hh.until(Want{ .s = s, .want = want }, Want.f);
        }
    };
    // Bursts of 8 calls and 8 signals at a time: the first rounds fill the
    // buffer pools and tables, the rest must not allocate.
    for (0..10) |_| try Round.run(&h, &a, &b, &sig, 8);
    const allocs = counting.allocations;
    const resizes = counting.resize_index;
    for (0..50) |_| try Round.run(&h, &a, &b, &sig, 8);
    try testing.expectEqual(allocs, counting.allocations);
    try testing.expectEqual(resizes, counting.resize_index);
}
