//! The public D-Bus API (D19) through the exports, between two
//! connections to an in-process bus (dbus.testing.TestBus) on the
//! application's loop: calls with every type round tripping through a
//! server written against the API, error replies, timeouts, deferred
//! replies, signals and match rules, name ownership and watching, exported
//! properties, and teardown with destroy-notifies.

const std = @import("std");
const linux = std.os.linux;
const abi = @import("abi");
const dbus = @import("dbus");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const D = abi.dbus;
const ok = harness.ok;

fn str(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

fn readString(r: t.DbusReader, buf: []u8) ![]const u8 {
    var len: usize = 0;
    try ok(D.siv_dbus_reader_read_string(r, buf.ptr, buf.len, &len));
    if (len > buf.len) return error.TooLong;
    return buf[0..len];
}

fn readInt(r: t.DbusReader) !i64 {
    var v: i64 = 0;
    try ok(D.siv_dbus_reader_read_int(r, &v));
    return v;
}

fn nextType(r: t.DbusReader) u8 {
    var ty: u8 = 0;
    _ = D.siv_dbus_reader_read_type(r, &ty);
    return ty;
}

fn writeStr(m: t.DbusMessage, ty: u8, s: []const u8) void {
    D.siv_dbus_message_write_string(m, ty, s.ptr, s.len);
}

/// Copies one complete value from `r` to `m` with the generic calls, as a
/// binding would.
fn copyValue(r: t.DbusReader, m: t.DbusMessage) !void {
    const ty = nextType(r);
    switch (ty) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'h' => D.siv_dbus_message_write_int(m, ty, try readInt(r)),
        'd' => {
            var v: f64 = 0;
            try ok(D.siv_dbus_reader_read_double(r, &v));
            D.siv_dbus_message_write_double(m, v);
        },
        's', 'o', 'g' => {
            var buf: [256]u8 = undefined;
            writeStr(m, ty, try readString(r, &buf));
        },
        'a', '(', '{', 'v' => {
            var sig_buf: [256]u8 = undefined;
            var len: usize = 0;
            try ok(D.siv_dbus_reader_read_signature(r, &sig_buf, sig_buf.len, &len));
            try ok(D.siv_dbus_reader_read_enter(r));
            switch (ty) {
                'a' => writeStr2(m, 'a', sig_buf[1..len]),
                '(' => writeStr2(m, 'r', ""),
                '{' => writeStr2(m, 'e', ""),
                'v' => {
                    try ok(D.siv_dbus_reader_read_signature(r, &sig_buf, sig_buf.len, &len));
                    writeStr2(m, 'v', sig_buf[0..len]);
                },
                else => unreachable,
            }
            while (nextType(r) != 0) try copyValue(r, m);
            try ok(D.siv_dbus_reader_read_exit(r));
            D.siv_dbus_message_write_close(m);
        },
        else => return error.UnexpectedType,
    }
}

fn writeStr2(m: t.DbusMessage, ty: u8, sig: []const u8) void {
    D.siv_dbus_message_write_open(m, ty, sig.ptr, sig.len);
}

const iface = "org.siv.Test";
const path = "/org/siv/Test";

/// The service, written against the API.
const Server = struct {
    count: u32 = 7,
    calls: u32 = 0,
    later: t.DbusInvocation = .null,
    destroyed: u32 = 0,
    name_state: ?t.DbusNameState = null,
    reply_result: t.Result = .ok,

    fn onCall(ud: ?*anyopaque, info: *const t.DbusMessageInfo, args: t.DbusReader, inv: t.DbusInvocation) callconv(.c) void {
        const s: *Server = @ptrCast(@alignCast(ud));
        s.calls += 1;
        const member = str(info.member, info.member_len);
        if (std.mem.eql(u8, member, "Echo")) {
            var m: t.DbusMessage = .null;
            ok(D.siv_dbus_invocation_new_reply(inv, &m)) catch return;
            while (nextType(args) != 0) copyValue(args, m) catch return;
            s.reply_result = D.siv_dbus_message_send(m);
        } else if (std.mem.eql(u8, member, "Fail")) {
            const name = "org.siv.Test.Error.Nope";
            _ = D.siv_dbus_invocation_reply_error(inv, name, name.len, "nope", 4);
        } else if (std.mem.eql(u8, member, "Bad")) {
            var m: t.DbusMessage = .null;
            ok(D.siv_dbus_invocation_new_reply(inv, &m)) catch return;
            D.siv_dbus_message_write_int(m, 'i', 3);
            s.reply_result = D.siv_dbus_message_send(m);
        } else if (std.mem.eql(u8, member, "Later")) {
            s.later = inv;
        }
    }

    fn getProperty(ud: ?*anyopaque, name: ?[*]const u8, len: usize, m: t.DbusMessage) callconv(.c) t.Result {
        const s: *Server = @ptrCast(@alignCast(ud));
        const n = str(name, len);
        if (std.mem.eql(u8, n, "Count")) {
            D.siv_dbus_message_write_int(m, 'u', s.count);
        } else if (std.mem.eql(u8, n, "Title")) {
            writeStr(m, 's', "files");
        } else return .error_invalid_argument;
        return D.siv_dbus_message_status(m);
    }

    fn setProperty(ud: ?*anyopaque, name: ?[*]const u8, len: usize, r: t.DbusReader) callconv(.c) t.Result {
        const s: *Server = @ptrCast(@alignCast(ud));
        if (!std.mem.eql(u8, str(name, len), "Count")) return .error_invalid_argument;
        var v: i64 = 0;
        const res = D.siv_dbus_reader_read_int(r, &v);
        if (res != .ok) return res;
        if (v > 100) return .error_invalid_argument;
        s.count = @intCast(v);
        return .ok;
    }

    fn onName(ud: ?*anyopaque, _: t.DbusName, state: t.DbusNameState) callconv(.c) void {
        const s: *Server = @ptrCast(@alignCast(ud));
        s.name_state = state;
    }

    fn onDestroy(ud: ?*anyopaque) callconv(.c) void {
        const s: *Server = @ptrCast(@alignCast(ud));
        s.destroyed += 1;
    }
};

/// What the client received.
const Got = struct {
    n: u32 = 0,
    destroyed: u32 = 0,
    type: t.DbusMessageType = .method_call,
    error_name: [128]u8 = undefined,
    error_len: usize = 0,
    member: [64]u8 = undefined,
    member_len: usize = 0,
    /// The first string argument, or the whole message checked by `check`.
    text: [256]u8 = undefined,
    text_len: usize = 0,
    int: i64 = 0,
    check: ?*const fn (r: t.DbusReader) anyerror!void = null,
    check_err: ?anyerror = null,

    fn errorName(g: *const Got) []const u8 {
        return g.error_name[0..g.error_len];
    }

    fn textOf(g: *const Got) []const u8 {
        return g.text[0..g.text_len];
    }

    fn onMessage(ud: ?*anyopaque, info: *const t.DbusMessageInfo, r: t.DbusReader) callconv(.c) void {
        const g: *Got = @ptrCast(@alignCast(ud));
        g.n += 1;
        g.type = info.type;
        const e = str(info.error_name, info.error_name_len);
        @memcpy(g.error_name[0..e.len], e);
        g.error_len = e.len;
        const m = str(info.member, info.member_len);
        @memcpy(g.member[0..m.len], m);
        g.member_len = m.len;
        g.text_len = 0;
        if (g.check) |c| {
            c(r) catch |err| {
                g.check_err = err;
            };
            return;
        }
        switch (nextType(r)) {
            's' => g.text_len = if (readString(r, &g.text)) |x| x.len else |_| 0,
            'v' => {
                _ = D.siv_dbus_reader_read_enter(r);
                if (nextType(r) == 's') {
                    g.text_len = if (readString(r, &g.text)) |x| x.len else |_| 0;
                } else g.int = readInt(r) catch -1;
                _ = D.siv_dbus_reader_read_exit(r);
            },
            'y', 'b', 'n', 'q', 'i', 'u', 'x', 't' => g.int = readInt(r) catch -1,
            else => {},
        }
    }

    fn onDestroy(ud: ?*anyopaque) callconv(.c) void {
        const g: *Got = @ptrCast(@alignCast(ud));
        g.destroyed += 1;
    }

    fn onOwner(ud: ?*anyopaque, _: t.DbusNameWatch, owner: ?[*]const u8, len: usize) callconv(.c) void {
        const g: *Got = @ptrCast(@alignCast(ud));
        g.n += 1;
        const o = str(owner, len);
        @memcpy(g.text[0..o.len], o);
        g.text_len = o.len;
    }
};

const Fixture = struct {
    h: harness.Harness = .{},
    bus: dbus.testing.TestBus = undefined,
    server: t.Dbus = .null,
    client: t.Dbus = .null,

    fn start(f: *Fixture) !void {
        try f.h.start(32, 32, null, null);
        const app = try A.App.get(@backingInt(f.h.app));
        f.bus = .init(testing.allocator, &app.app.loop);
        try ok(D.siv_dbus_connect(f.h.app, &.{ .bus = .fd, .fd = try f.bus.connect() }, &f.server));
        try ok(D.siv_dbus_connect(f.h.app, &.{ .bus = .fd, .fd = try f.bus.connect() }, &f.client));
        var i: u32 = 0;
        while (uniqueName(f.server).len == 0 or uniqueName(f.client).len == 0) : (i += 1) {
            if (i == 100) return error.Timeout;
            try ok(A.siv_app_dispatch(f.h.app, 10));
        }
    }

    fn stop(f: *Fixture) void {
        f.bus.deinit();
        f.h.stop();
    }

    /// Dispatches until `cond` holds.
    fn until(f: *Fixture, cond: anytype) !void {
        var i: u32 = 0;
        while (!cond.done()) : (i += 1) {
            if (i == 200) return error.Timeout;
            try ok(A.siv_app_dispatch(f.h.app, 10));
        }
    }
};

var name_buf: [64]u8 = undefined;

fn uniqueName(c: t.Dbus) []const u8 {
    var len: usize = 0;
    ok(D.siv_dbus_get_unique_name(c, &name_buf, name_buf.len, &len)) catch return "";
    return name_buf[0..len];
}

fn newCall(c: t.Dbus, destination: []const u8, p: []const u8, i: []const u8, member: []const u8) !t.DbusMessage {
    var m: t.DbusMessage = .null;
    try ok(D.siv_dbus_new_call(c, &.{
        .destination = destination.ptr,
        .destination_len = destination.len,
        .path = p.ptr,
        .path_len = p.len,
        .interface = i.ptr,
        .interface_len = i.len,
        .member = member.ptr,
        .member_len = member.len,
    }, &m));
    return m;
}

fn exportServer(f: *Fixture, s: *Server, obj: *t.DbusObject) !void {
    const methods = [_]t.DbusMethod{
        .{ .name = "Echo", .name_len = 4, .in_signature = echo_sig, .in_signature_len = echo_sig.len, .out_signature = echo_sig, .out_signature_len = echo_sig.len },
        .{ .name = "Fail", .name_len = 4 },
        .{ .name = "Bad", .name_len = 3, .out_signature = "s", .out_signature_len = 1 },
        .{ .name = "Later", .name_len = 5, .in_signature = "s", .in_signature_len = 1, .out_signature = "s", .out_signature_len = 1 },
    };
    const props = [_]t.DbusProperty{
        .{ .name = "Count", .name_len = 5, .signature = "u", .signature_len = 1, .access = .readwrite },
        .{ .name = "Title", .name_len = 5, .signature = "s", .signature_len = 1, .access = .read },
    };
    const signals = [_]t.DbusSignal{.{ .name = "Ping", .name_len = 4, .signature = "s", .signature_len = 1 }};
    try ok(D.siv_dbus_export(f.server, &.{
        .path = path,
        .path_len = path.len,
        .interface = iface,
        .interface_len = iface.len,
        .methods = &methods,
        .methods_count = methods.len,
        .properties = &props,
        .properties_count = props.len,
        .signals = &signals,
        .signals_count = signals.len,
        .user_data = s,
        .on_call = Server.onCall,
        .get_property = Server.getProperty,
        .set_property = Server.setProperty,
        .destroy = Server.onDestroy,
    }, obj));
}

const echo_sig = "ybnqiuxtdsogha{sv}(iad)av";

fn writeEcho(m: t.DbusMessage, fd: i32) void {
    D.siv_dbus_message_write_int(m, 'y', 200);
    D.siv_dbus_message_write_int(m, 'b', 1);
    D.siv_dbus_message_write_int(m, 'n', -300);
    D.siv_dbus_message_write_int(m, 'q', 60000);
    D.siv_dbus_message_write_int(m, 'i', -70000);
    D.siv_dbus_message_write_int(m, 'u', 4_000_000_000);
    D.siv_dbus_message_write_int(m, 'x', -5_000_000_000);
    D.siv_dbus_message_write_int(m, 't', -1); // 2^64 - 1
    D.siv_dbus_message_write_double(m, 2.5);
    writeStr(m, 's', "héllo");
    writeStr(m, 'o', "/a/b");
    writeStr(m, 'g', "a{sv}");
    D.siv_dbus_message_write_int(m, 'h', fd);
    writeStr2(m, 'a', "{sv}");
    writeStr2(m, 'e', "");
    writeStr(m, 's', "k");
    writeStr2(m, 'v', "u");
    D.siv_dbus_message_write_int(m, 'u', 9);
    D.siv_dbus_message_write_close(m);
    D.siv_dbus_message_write_close(m);
    D.siv_dbus_message_write_close(m);
    writeStr2(m, 'r', "");
    D.siv_dbus_message_write_int(m, 'i', 1);
    writeStr2(m, 'a', "d");
    D.siv_dbus_message_write_double(m, 0.5);
    D.siv_dbus_message_write_double(m, -0.25);
    D.siv_dbus_message_write_close(m);
    D.siv_dbus_message_write_close(m);
    writeStr2(m, 'a', "v"); // empty
    D.siv_dbus_message_write_close(m);
}

fn checkEcho(r: t.DbusReader) !void {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    try ok(D.siv_dbus_reader_read_signature(r, &buf, buf.len, &len));
    try testing.expectEqualStrings("y", buf[0..len]);
    try testing.expectEqual(@as(i64, 200), try readInt(r));
    try testing.expectEqual(@as(i64, 1), try readInt(r));
    try testing.expectEqual(@as(i64, -300), try readInt(r));
    try testing.expectEqual(@as(i64, 60000), try readInt(r));
    try testing.expectEqual(@as(i64, -70000), try readInt(r));
    try testing.expectEqual(@as(i64, 4_000_000_000), try readInt(r));
    try testing.expectEqual(@as(i64, -5_000_000_000), try readInt(r));
    try testing.expectEqual(@as(i64, -1), try readInt(r));
    // The wrong kind of read is refused and reads nothing.
    var wrong: i64 = 0;
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_dbus_reader_read_int(r, &wrong));
    var d: f64 = 0;
    try ok(D.siv_dbus_reader_read_double(r, &d));
    try testing.expectEqual(@as(f64, 2.5), d);
    // Too small a buffer: nothing read, the length says how much.
    try ok(D.siv_dbus_reader_read_string(r, &buf, 2, &len));
    try testing.expectEqual(@as(usize, 6), len);
    try testing.expectEqualStrings("héllo", try readString(r, &buf));
    try testing.expectEqualStrings("/a/b", try readString(r, &buf));
    try testing.expectEqualStrings("a{sv}", try readString(r, &buf));
    const fd = try readInt(r);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(@intCast(fd), linux.F.GETFD, 0)));
    try ok(D.siv_dbus_reader_read_signature(r, &buf, buf.len, &len));
    try testing.expectEqualStrings("a{sv}", buf[0..len]);
    try ok(D.siv_dbus_reader_read_enter(r));
    try testing.expectEqual(@as(u8, '{'), nextType(r));
    try ok(D.siv_dbus_reader_read_signature(r, &buf, buf.len, &len));
    try testing.expectEqualStrings("{sv}", buf[0..len]);
    try ok(D.siv_dbus_reader_read_enter(r));
    try testing.expectEqualStrings("k", try readString(r, &buf));
    try ok(D.siv_dbus_reader_read_enter(r));
    try testing.expectEqual(@as(i64, 9), try readInt(r));
    try testing.expectEqual(@as(u8, 0), nextType(r));
    try ok(D.siv_dbus_reader_read_exit(r));
    try testing.expectEqual(@as(u8, 0), nextType(r));
    try ok(D.siv_dbus_reader_read_exit(r));
    try testing.expectEqual(@as(u8, 0), nextType(r));
    try ok(D.siv_dbus_reader_read_exit(r));
    // A struct, left early: exit skips the rest.
    try testing.expectEqual(@as(u8, '('), nextType(r));
    try ok(D.siv_dbus_reader_read_enter(r));
    try testing.expectEqual(@as(i64, 1), try readInt(r));
    try ok(D.siv_dbus_reader_read_exit(r));
    try ok(D.siv_dbus_reader_read_enter(r));
    try testing.expectEqual(@as(u8, 0), nextType(r));
    try ok(D.siv_dbus_reader_read_exit(r));
    try testing.expectEqual(@as(u8, 0), nextType(r));
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_dbus_reader_read_exit(r));
}

const Wait = struct {
    p: *const u32,
    n: u32,
    fn done(w: Wait) bool {
        return w.p.* >= w.n;
    }
};

fn wait(p: *const u32, n: u32) Wait {
    return .{ .p = p, .n = n };
}

fn callAndWait(f: *Fixture, m: t.DbusMessage, got: *Got, timeout_ms: i32) !void {
    const before = got.n;
    try ok(D.siv_dbus_message_call(m, timeout_ms, Got.onMessage, Got.onDestroy, got));
    try f.until(wait(&got.n, before + 1));
}

test "dbus: names, calls with every type, errors, and deferred replies" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();
    var s: Server = .{};
    var name: t.DbusName = .null;
    try ok(D.siv_dbus_own_name(f.server, iface, iface.len, .{ .do_not_queue = true }, Server.onName, Server.onDestroy, &s, &name));
    var obj: t.DbusObject = .null;
    try exportServer(&f, &s, &obj);
    // A second object at the same path is refused, and its user_data released.
    var s2: Server = .{};
    var obj2: t.DbusObject = .null;
    try testing.expectEqual(t.Result.error_busy, D.siv_dbus_export(f.server, &.{ .path = path, .path_len = path.len, .interface = iface, .interface_len = iface.len, .user_data = &s2, .destroy = Server.onDestroy }, &obj2));
    try testing.expectEqual(@as(u32, 1), s2.destroyed);

    var owner: Got = .{};
    var watch: t.DbusNameWatch = .null;
    try ok(D.siv_dbus_watch_name(f.client, iface, iface.len, Got.onOwner, Got.onDestroy, &owner, &watch));
    // The owner may be reported as nobody first, if the bus answered the
    // lookup before the request.
    try f.until(wait(&owner.n, 1));
    if (owner.text_len == 0) try f.until(wait(&owner.n, 2));
    const server_name = try testing.allocator.dupe(u8, uniqueName(f.server));
    defer testing.allocator.free(server_name);
    try testing.expectEqual(t.DbusNameState.primary, s.name_state.?);
    try testing.expectEqualStrings(server_name, owner.textOf());

    // Every type, through the server's generic copy and back.
    var got: Got = .{ .check = checkEcho };
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };
    var m = try newCall(f.client, iface, path, iface, "Echo");
    writeEcho(m, fds[0]);
    try ok(D.siv_dbus_message_status(m));
    try callAndWait(&f, m, &got, 0);
    try testing.expectEqual(t.Result.ok, s.reply_result);
    try testing.expectEqual(t.DbusMessageType.method_return, got.type);
    if (got.check_err) |err| return err;
    try testing.expectEqual(@as(u32, 1), got.destroyed);
    got.check = null;

    // An error reply, and errors siv makes.
    m = try newCall(f.client, iface, path, iface, "Fail");
    try callAndWait(&f, m, &got, 0);
    try testing.expectEqual(t.DbusMessageType.@"error", got.type);
    try testing.expectEqualStrings("org.siv.Test.Error.Nope", got.errorName());
    try testing.expectEqualStrings("nope", got.textOf());
    m = try newCall(f.client, iface, path, iface, "Missing");
    try callAndWait(&f, m, &got, 0);
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownMethod", got.errorName());
    m = try newCall(f.client, iface, path, iface, "Later"); // without its argument
    try callAndWait(&f, m, &got, 0);
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.InvalidArgs", got.errorName());
    // A reply with another signature than declared becomes an error.
    m = try newCall(f.client, iface, path, iface, "Bad");
    try callAndWait(&f, m, &got, 0);
    try testing.expectEqual(t.Result.error_invalid_argument, s.reply_result);
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.Failed", got.errorName());

    // A deferred reply, sent after the callback returned.
    m = try newCall(f.client, iface, path, iface, "Later");
    writeStr(m, 's', "x");
    // Unknown methods and wrong arguments never reached the server.
    try testing.expectEqual(@as(u32, 3), s.calls);
    try ok(D.siv_dbus_message_call(m, 0, Got.onMessage, null, &got));
    const before = got.n;
    try f.until(wait(&s.calls, 4));
    try testing.expect(s.later != .null);
    try testing.expectEqual(before, got.n);
    var reply: t.DbusMessage = .null;
    var second: t.DbusMessage = .null;
    try ok(D.siv_dbus_invocation_new_reply(s.later, &reply));
    try ok(D.siv_dbus_invocation_new_reply(s.later, &second));
    writeStr(reply, 's', "done");
    writeStr(second, 's', "again");
    try ok(D.siv_dbus_message_send(reply));
    // Only one reply goes out.
    try testing.expectEqual(t.Result.error_invalid_handle, D.siv_dbus_message_send(second));
    try f.until(wait(&got.n, before + 1));
    try testing.expectEqualStrings("done", got.textOf());
    // The invocation is answered: its handle is stale.
    try testing.expectEqual(t.Result.error_invalid_handle, D.siv_dbus_invocation_new_reply(s.later, &reply));

    // A secret's message (a passphrase) goes out like any other; siv
    // wipes its copies (dbus/message.zig tests the wiping).
    {
        var sm: t.DbusMessage = .null;
        try ok(D.siv_dbus_new_call(f.client, &.{ .destination = iface, .destination_len = iface.len, .path = path, .path_len = path.len, .interface = iface, .interface_len = iface.len, .member = "Later", .member_len = 5, .flags = .{ .secret = true } }, &sm));
        writeStr(sm, 's', "hunter2");
        const n = got.n;
        const calls_before = s.calls;
        try ok(D.siv_dbus_message_call(sm, 0, Got.onMessage, null, &got));
        try f.until(wait(&s.calls, calls_before + 1));
        var r2: t.DbusMessage = .null;
        try ok(D.siv_dbus_invocation_new_reply(s.later, &r2));
        writeStr(r2, 's', "unlocked");
        try ok(D.siv_dbus_message_send(r2));
        try f.until(wait(&got.n, n + 1));
        try testing.expectEqualStrings("unlocked", got.textOf());
    }

    // A call nobody answers times out.
    m = try newCall(f.client, iface, path, iface, "Later");
    writeStr(m, 's', "y");
    try callAndWait(&f, m, &got, 30);
    try testing.expectEqual(t.DbusMessageType.failed, got.type);
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.NoReply", got.errorName());

    // Destroying the object answers its pending invocation with an error.
    m = try newCall(f.client, iface, path, iface, "Later");
    writeStr(m, 's', "z");
    try ok(D.siv_dbus_message_call(m, 0, Got.onMessage, null, &got));
    const calls = s.calls;
    try f.until(wait(&s.calls, calls + 1));
    D.siv_dbus_object_destroy(obj);
    try testing.expectEqual(@as(u32, 1), s.destroyed);
    try f.until(wait(&got.n, got.n + 1));
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownObject", got.errorName());

    // Releasing the name: the watch sees it go.
    const seen = owner.n;
    D.siv_dbus_name_release(name);
    try testing.expectEqual(@as(u32, 2), s.destroyed);
    try f.until(wait(&owner.n, seen + 1));
    try testing.expectEqualStrings("", owner.textOf());
    D.siv_dbus_name_watch_destroy(watch);
    D.siv_dbus_name_watch_destroy(watch); // stale: nothing
    try testing.expectEqual(@as(u32, 1), owner.destroyed);
}

test "dbus: properties, signals, and match rules" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();
    var s: Server = .{};
    var obj: t.DbusObject = .null;
    try exportServer(&f, &s, &obj);
    const dest = try testing.allocator.dupe(u8, uniqueName(f.server));
    defer testing.allocator.free(dest);
    const props = "org.freedesktop.DBus.Properties";

    var got: Got = .{};
    var m = try newCall(f.client, dest, path, props, "Get");
    writeStr(m, 's', iface);
    writeStr(m, 's', "Count");
    try callAndWait(&f, m, &got, 0);
    try testing.expectEqual(@as(i64, 7), got.int);

    m = try newCall(f.client, dest, path, props, "Set");
    writeStr(m, 's', iface);
    writeStr(m, 's', "Count");
    writeStr2(m, 'v', "u");
    D.siv_dbus_message_write_int(m, 'u', 42);
    D.siv_dbus_message_write_close(m);
    try callAndWait(&f, m, &got, 0);
    try testing.expectEqual(t.DbusMessageType.method_return, got.type);
    try testing.expectEqual(@as(u32, 42), s.count);
    // The setter refuses: an error reply.
    m = try newCall(f.client, dest, path, props, "Set");
    writeStr(m, 's', iface);
    writeStr(m, 's', "Count");
    writeStr2(m, 'v', "u");
    D.siv_dbus_message_write_int(m, 'u', 1000);
    D.siv_dbus_message_write_close(m);
    try callAndWait(&f, m, &got, 0);
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.InvalidArgs", got.errorName());
    try testing.expectEqual(@as(u32, 42), s.count);
    m = try newCall(f.client, dest, path, props, "Get");
    writeStr(m, 's', iface);
    writeStr(m, 's', "Title");
    try callAndWait(&f, m, &got, 0);
    try testing.expectEqualStrings("files", got.textOf());

    // PropertiesChanged carries the value from get_property.
    var changed: Got = .{ .check = struct {
        fn check(r: t.DbusReader) !void {
            var buf: [64]u8 = undefined;
            try testing.expectEqualStrings(iface, try readString(r, &buf));
            try ok(D.siv_dbus_reader_read_enter(r));
            try ok(D.siv_dbus_reader_read_enter(r));
            try testing.expectEqualStrings("Count", try readString(r, &buf));
            try ok(D.siv_dbus_reader_read_enter(r));
            try testing.expectEqual(@as(i64, 5), try readInt(r));
        }
    }.check };
    var sub: t.DbusSubscription = .null;
    try ok(D.siv_dbus_subscribe(f.client, &.{ .path = path, .path_len = path.len, .interface = props, .interface_len = props.len, .member = "PropertiesChanged", .member_len = 17 }, Got.onMessage, Got.onDestroy, &changed, &sub));
    // Signals with arg0 "hi" only.
    var pings: Got = .{};
    var ping_sub: t.DbusSubscription = .null;
    try ok(D.siv_dbus_subscribe(f.client, &.{ .sender = dest.ptr, .sender_len = dest.len, .interface = iface, .interface_len = iface.len, .member = "Ping", .member_len = 4, .arg0 = "hi", .arg0_len = 2 }, Got.onMessage, Got.onDestroy, &pings, &ping_sub));
    // Let AddMatch reach the bus before anything is emitted.
    m = try newCall(f.client, dest, path, props, "Get");
    writeStr(m, 's', iface);
    writeStr(m, 's', "Count");
    try callAndWait(&f, m, &got, 0);

    s.count = 5;
    try ok(D.siv_dbus_object_emit_properties_changed(obj, "Count", 5));
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_dbus_object_emit_properties_changed(obj, "Nope", 4));
    for ([_][]const u8{ "ho", "hi" }) |arg| {
        var sig: t.DbusMessage = .null;
        try ok(D.siv_dbus_new_signal(f.server, &.{ .path = path, .path_len = path.len, .interface = iface, .interface_len = iface.len, .member = "Ping", .member_len = 4 }, &sig));
        writeStr(sig, 's', arg);
        try ok(D.siv_dbus_message_send(sig));
    }
    try f.until(wait(&pings.n, 1));
    try f.until(wait(&changed.n, 1));
    if (changed.check_err) |err| return err;
    try testing.expectEqual(t.DbusMessageType.signal, pings.type);
    try testing.expectEqualStrings("hi", pings.textOf());
    // A round trip later, "ho" still did not arrive.
    try callAndWait(&f, try newCall(f.client, dest, path, iface, "Fail"), &got, 0);
    try testing.expectEqual(@as(u32, 1), pings.n);

    D.siv_dbus_subscription_destroy(sub);
    try testing.expectEqual(@as(u32, 1), changed.destroyed);
    // Disconnecting takes the rest along, with their destroy-notifies.
    D.siv_dbus_disconnect(f.client);
    try testing.expectEqual(@as(u32, 1), pings.destroyed);
    var len: usize = 0;
    try testing.expectEqual(t.Result.error_invalid_handle, D.siv_dbus_get_unique_name(f.client, null, 0, &len));
    D.siv_dbus_disconnect(f.server);
    try testing.expectEqual(@as(u32, 1), s.destroyed);
}

test "dbus: argument checks, unsent messages, and teardown" {
    var f: Fixture = .{};
    try f.start();
    // The headless backend has no session bus.
    var c: t.Dbus = .null;
    try testing.expectEqual(t.Result.error_unavailable, D.siv_dbus_connect(f.h.app, null, &c));
    // Calls on a bus need a destination.
    var m: t.DbusMessage = .null;
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_dbus_new_call(f.client, &.{ .path = "/", .path_len = 1, .member = "M", .member_len = 1 }, &m));
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_dbus_new_call(f.client, &.{ .destination = "a.b", .destination_len = 3, .path = "bad", .path_len = 3, .member = "M", .member_len = 1 }, &m));
    // A write the signature does not allow fails the message, and sending
    // it fails and releases user_data.
    m = try newCall(f.client, "a.b", "/", "a.b", "M");
    D.siv_dbus_message_write_int(m, 'y', 256);
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_dbus_message_status(m));
    var got: Got = .{};
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_dbus_message_call(m, 0, Got.onMessage, Got.onDestroy, &got));
    try testing.expectEqual(@as(u32, 1), got.destroyed);
    try testing.expectEqual(t.Result.error_invalid_handle, D.siv_dbus_message_status(m));
    // A container left open.
    m = try newCall(f.client, "a.b", "/", "a.b", "M");
    writeStr2(m, 'a', "s");
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_dbus_message_send(m));
    // Closing what is not open; a variant holding another type.
    m = try newCall(f.client, "a.b", "/", "a.b", "M");
    D.siv_dbus_message_write_close(m);
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_dbus_message_status(m));
    D.siv_dbus_message_destroy(m);
    m = try newCall(f.client, "a.b", "/", "a.b", "M");
    writeStr2(m, 'v', "u");
    writeStr(m, 's', "x");
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_dbus_message_status(m));
    // Left unsent: the application's teardown frees it, a call pending
    // on the bus runs its destroy-notify, and so does an exported object.
    var s: Server = .{};
    var obj: t.DbusObject = .null;
    try exportServer(&f, &s, &obj);
    try ok(D.siv_dbus_message_call(try newCall(f.client, "org.nobody", "/", "a.b", "M"), -1, Got.onMessage, Got.onDestroy, &got));
    f.stop();
    try testing.expectEqual(@as(u32, 2), got.destroyed);
    try testing.expectEqual(@as(u32, 1), s.destroyed);
}
