//! A minimal message bus for hermetic tests: SASL EXTERNAL server side,
//! Hello, name ownership with NameAcquired, NameLost, and NameOwnerChanged,
//! AddMatch and RemoveMatch, GetNameOwner, routing of calls and replies by
//! destination with fds, and signal broadcast by match rules. Clients
//! connect through socketpairs on the test's loop. Not part of libsiv.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Loop = @import("loop").Loop;
const message = @import("message.zig");
const match = @import("match.zig");
const codec = @import("codec.zig");
const Message = message.Message;

const TestBus = @This();

gpa: Allocator,
loop: *Loop,
clients: std.ArrayList(*Client) = .empty,
next_id: u32 = 1,
serial: u32 = 0,
/// Well-known name to owner (primary first, then queue).
names: std.StringHashMapUnmanaged(std.ArrayList(*Client)) = .empty,
/// Messages each client sent, for assertions on wire behavior.
log: std.ArrayList([]u8) = .empty,
agree_fds: bool = true,

const Client = struct {
    bus: *TestBus,
    fd: i32,
    source: Loop.Source,
    id: u32,
    name: [16]u8 = undefined,
    name_len: usize = 0,
    authed: bool = false,
    in: std.ArrayList(u8) = .empty,
    fds: std.ArrayList(i32) = .empty,
    rules: std.ArrayList([]u8) = .empty,
    /// Queued output: messages not yet fully written.
    out: std.ArrayList(Pending) = .empty,

    const Pending = struct { bytes: []u8, fds: []i32, sent: usize = 0 };

    fn uniqueName(c: *const Client) []const u8 {
        return c.name[0..c.name_len];
    }
};

pub fn init(gpa: Allocator, loop: *Loop) TestBus {
    return .{ .gpa = gpa, .loop = loop };
}

pub fn deinit(b: *TestBus) void {
    for (b.clients.items) |c| b.freeClient(c);
    b.clients.deinit(b.gpa);
    var it = b.names.iterator();
    while (it.next()) |e| {
        b.gpa.free(e.key_ptr.*);
        e.value_ptr.deinit(b.gpa);
    }
    b.names.deinit(b.gpa);
    for (b.log.items) |m| b.gpa.free(m);
    b.log.deinit(b.gpa);
}

fn freeClient(b: *TestBus, c: *Client) void {
    if (c.fd >= 0) {
        b.loop.removeSource(&c.source);
        _ = linux.close(c.fd);
    }
    c.in.deinit(b.gpa);
    for (c.fds.items) |fd| _ = linux.close(fd);
    c.fds.deinit(b.gpa);
    for (c.rules.items) |r| b.gpa.free(r);
    c.rules.deinit(b.gpa);
    for (c.out.items) |p| {
        b.gpa.free(p.bytes);
        for (p.fds) |fd| _ = linux.close(fd);
        b.gpa.free(p.fds);
    }
    c.out.deinit(b.gpa);
    b.gpa.destroy(c);
}

/// Returns the client's end of a new connection to the bus.
pub fn connect(b: *TestBus) !i32 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS) return error.SystemResources;
    try b.adopt(fds[1]);
    return fds[0];
}

/// Serves a connected socket as a client's connection (a socket
/// accepted from a listening one), taking ownership of it.
pub fn adopt(b: *TestBus, fd: i32) !void {
    const c = try b.gpa.create(Client);
    c.* = .{ .bus = b, .fd = fd, .source = .{ .fd = fd, .events = linux.EPOLL.IN, .func = onIo }, .id = b.next_id };
    c.name_len = (try std.fmt.bufPrint(&c.name, ":1.{d}", .{b.next_id})).len;
    b.next_id += 1;
    try b.clients.append(b.gpa, c);
    try b.loop.addSource(&c.source);
}

/// Disconnects the client owning `unique` (as if it crashed).
pub fn kill(b: *TestBus, unique: []const u8) void {
    for (b.clients.items) |c| if (std.mem.eql(u8, c.uniqueName(), unique)) return b.drop(c);
}

fn onIo(s: *Loop.Source, events: u32) void {
    const c: *Client = @fieldParentPtr("source", s);
    const b = c.bus;
    if (events & linux.EPOLL.OUT != 0) b.flush(c) catch return b.drop(c);
    if (events & (linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR) == 0) return;
    var buf: [65536]u8 = undefined;
    var iov = [_]std.posix.iovec{.{ .base = &buf, .len = buf.len }};
    var control: [1040]u8 align(8) = undefined;
    var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
    const rc = linux.recvmsg(c.fd, &msg, linux.MSG.CMSG_CLOEXEC | linux.MSG.DONTWAIT);
    if (linux.errno(rc) == .AGAIN) return;
    if (linux.errno(rc) != .SUCCESS or rc == 0) return b.drop(c);
    if (msg.controllen >= @sizeOf(linux.cmsghdr)) {
        const hdr: *const linux.cmsghdr = @ptrCast(&control);
        const n = (hdr.len - @sizeOf(linux.cmsghdr)) / 4;
        for (0..n) |i| c.fds.append(b.gpa, std.mem.readInt(i32, control[@sizeOf(linux.cmsghdr) + 4 * i ..][0..4], .little)) catch unreachable;
    }
    c.in.appendSlice(b.gpa, buf[0..rc]) catch unreachable;
    b.process(c) catch b.drop(c);
}

fn process(b: *TestBus, c: *Client) !void {
    while (!c.authed) {
        const nl = std.mem.indexOf(u8, c.in.items, "\r\n") orelse return;
        var line = c.in.items[0..nl];
        if (line.len > 0 and line[0] == 0) line = line[1..];
        if (std.mem.startsWith(u8, line, "AUTH EXTERNAL ")) {
            try b.write(c, "OK 0123456789abcdef0123456789abcdef\r\n");
        } else if (std.mem.eql(u8, line, "NEGOTIATE_UNIX_FD")) {
            try b.write(c, if (b.agree_fds) "AGREE_UNIX_FD\r\n" else "ERROR\r\n");
        } else if (std.mem.eql(u8, line, "BEGIN")) {
            c.authed = true;
        } else return error.Protocol;
        try c.in.replaceRange(b.gpa, 0, nl + 2, &.{});
    }
    while (c.in.items.len >= 16) {
        const len = try Message.frameLength(c.in.items[0..16]);
        if (c.in.items.len < len) return;
        const data = try b.gpa.dupe(u8, c.in.items[0..len]);
        try b.log.append(b.gpa, data);
        try c.in.replaceRange(b.gpa, 0, len, &.{});
        var m = try Message.parse(data);
        const fds = try b.gpa.dupe(i32, c.fds.items[0..m.unix_fds]);
        defer b.gpa.free(fds);
        try c.fds.replaceRange(b.gpa, 0, m.unix_fds, &.{});
        m.fds = fds;
        defer for (fds) |fd| if (fd >= 0) {
            _ = linux.close(fd);
        };
        try b.route(c, &m);
    }
}

fn write(b: *TestBus, c: *Client, bytes: []const u8) !void {
    try c.out.append(b.gpa, .{ .bytes = try b.gpa.dupe(u8, bytes), .fds = &.{} });
    try b.flush(c);
}

/// Sends `m` (from `from`, or the bus) to `to` with the sender field set.
fn deliver(b: *TestBus, to: *Client, m: *const Message, sender: []const u8) !void {
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(b.gpa);
    const h: message.Header = .{
        .type = m.type,
        .flags = m.flags,
        .path = m.path,
        .interface = m.interface,
        .member = m.member,
        .error_name = m.error_name,
        .destination = m.destination,
        .sender = sender,
        .reply_serial = m.reply_serial,
    };
    try message.encodeHeader(b.gpa, &head, &h, m.serial, m.signature, m.bodyBytes().len, m.fds.len);
    try head.appendSlice(b.gpa, m.bodyBytes());
    const fds = try b.gpa.alloc(i32, m.fds.len);
    for (fds, m.fds) |*d, fd| d.* = @intCast(linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 3));
    try to.out.append(b.gpa, .{ .bytes = try head.toOwnedSlice(b.gpa), .fds = fds });
    try b.flush(to);
}

fn flush(b: *TestBus, c: *Client) !void {
    while (c.out.items.len > 0) {
        const p = &c.out.items[0];
        var iov = [_]std.posix.iovec_const{.{ .base = p.bytes.ptr + p.sent, .len = p.bytes.len - p.sent }};
        var control: [1040]u8 align(8) = undefined;
        var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
        if (p.fds.len > 0) {
            const hdr: *linux.cmsghdr = @ptrCast(&control);
            hdr.* = .{ .len = @sizeOf(linux.cmsghdr) + p.fds.len * 4, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
            @memcpy(control[@sizeOf(linux.cmsghdr)..][0 .. p.fds.len * 4], std.mem.sliceAsBytes(p.fds));
            msg.control = &control;
            msg.controllen = @sizeOf(linux.cmsghdr) + std.mem.alignForward(usize, p.fds.len * 4, 8);
        }
        const rc = linux.sendmsg(c.fd, &msg, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return b.loop.modifySource(&c.source, linux.EPOLL.IN | linux.EPOLL.OUT),
            else => return error.Write,
        }
        for (p.fds) |fd| _ = linux.close(fd);
        b.gpa.free(p.fds);
        p.fds = &.{};
        p.sent += rc;
        if (p.sent < p.bytes.len) continue;
        b.gpa.free(p.bytes);
        _ = c.out.orderedRemove(0);
    }
    try b.loop.modifySource(&c.source, linux.EPOLL.IN);
}

/// Sends a message from the bus.
fn busSend(b: *TestBus, to: *Client, builder: *message.Builder) !void {
    defer builder.deinit();
    b.serial += 1;
    const data = try builder.encode(b.gpa, b.serial);
    defer b.gpa.free(data);
    var m = try Message.parse(data);
    m.serial = b.serial;
    try b.deliver(to, &m, "org.freedesktop.DBus");
}

fn reply(b: *TestBus, to: *Client, call: *const Message, values: anytype) !void {
    var builder: message.Builder = .init(b.gpa, .{ .type = .method_return, .destination = to.uniqueName(), .reply_serial = call.serial });
    try builder.body.writeAll(values);
    try b.busSend(to, &builder);
}

fn replyError(b: *TestBus, to: *Client, call: *const Message, name: []const u8, text: []const u8) !void {
    if (call.flags.no_reply_expected) return;
    var builder: message.Builder = .init(b.gpa, .{ .type = .@"error", .destination = to.uniqueName(), .reply_serial = call.serial, .error_name = name });
    try builder.body.writeString(text);
    try b.busSend(to, &builder);
}

fn busSignal(b: *TestBus, to: ?*Client, member: []const u8, args: anytype) !void {
    var builder: message.Builder = .init(b.gpa, .{ .type = .signal, .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = member, .destination = if (to) |t| t.uniqueName() else null });
    try builder.body.writeAll(args);
    defer builder.deinit();
    b.serial += 1;
    const data = try builder.encode(b.gpa, b.serial);
    defer b.gpa.free(data);
    var m = try Message.parse(data);
    if (to) |t| return b.deliver(t, &m, "org.freedesktop.DBus");
    m.sender = "org.freedesktop.DBus";
    try b.broadcast(&m, "org.freedesktop.DBus");
}

fn broadcast(b: *TestBus, m: *const Message, sender: []const u8) !void {
    var mm = m.*;
    mm.sender = sender;
    for (b.clients.items) |c| {
        for (c.rules.items) |text| {
            var strings: [512]u8 = undefined;
            var args: [match.max_args]match.Arg = undefined;
            const rule = match.Rule.parse(text, &strings, &args) catch continue;
            if (!b.ruleMatches(&rule, &mm)) continue;
            try b.deliver(c, m, sender);
            break;
        }
    }
}

fn ruleMatches(b: *TestBus, rule: *const match.Rule, m: *const Message) bool {
    if (rule.sender) |s| {
        const resolved = if (s[0] == ':' or std.mem.eql(u8, s, "org.freedesktop.DBus")) s else if (b.owner(s)) |o| o.uniqueName() else return false;
        if (!std.mem.eql(u8, resolved, m.sender.?)) return false;
    }
    return rule.matchesExceptSender(m);
}

fn owner(b: *TestBus, name: []const u8) ?*Client {
    if (name.len > 0 and name[0] == ':') {
        for (b.clients.items) |c| if (std.mem.eql(u8, c.uniqueName(), name)) return c;
        return null;
    }
    const q = b.names.get(name) orelse return null;
    return if (q.items.len > 0) q.items[0] else null;
}

fn route(b: *TestBus, from: *Client, m: *const Message) !void {
    const dest = m.destination orelse {
        if (m.type == .signal) try b.broadcast(m, from.uniqueName());
        return;
    };
    if (std.mem.eql(u8, dest, "org.freedesktop.DBus")) return b.driver(from, m);
    const to = b.owner(dest) orelse {
        if (m.type == .method_call) try b.replyError(from, m, "org.freedesktop.DBus.Error.ServiceUnknown", "no such name");
        return;
    };
    try b.deliver(to, m, from.uniqueName());
    // Signals with a destination also reach matching eavesdroppers in a
    // real bus; not needed here.
}

fn driver(b: *TestBus, c: *Client, m: *const Message) !void {
    const member = m.member.?;
    var d = m.body();
    if (std.mem.eql(u8, member, "Hello")) {
        try b.reply(c, m, .{c.uniqueName()});
        try b.busSignal(c, "NameAcquired", .{c.uniqueName()});
        try b.busSignal(null, "NameOwnerChanged", .{ c.uniqueName(), "", c.uniqueName() });
    } else if (std.mem.eql(u8, member, "AddMatch")) {
        try c.rules.append(b.gpa, try b.gpa.dupe(u8, try d.readString()));
    } else if (std.mem.eql(u8, member, "RemoveMatch")) {
        const text = try d.readString();
        for (c.rules.items, 0..) |r, i| if (std.mem.eql(u8, r, text)) {
            b.gpa.free(c.rules.orderedRemove(i));
            break;
        };
    } else if (std.mem.eql(u8, member, "GetNameOwner")) {
        const name = try d.readString();
        if (b.owner(name)) |o| try b.reply(c, m, .{o.uniqueName()}) else try b.replyError(c, m, "org.freedesktop.DBus.Error.NameHasNoOwner", "no owner");
    } else if (std.mem.eql(u8, member, "RequestName")) {
        const name = try d.readString();
        const flags = try d.readUint32();
        const gop = try b.names.getOrPut(b.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try b.gpa.dupe(u8, name);
            gop.value_ptr.* = .empty;
        }
        const q = gop.value_ptr;
        for (q.items, 0..) |o, i| if (o == c) return b.reply(c, m, .{@as(u32, if (i == 0) 4 else 2)});
        if (q.items.len == 0) {
            try q.append(b.gpa, c);
            try b.reply(c, m, .{@as(u32, 1)});
            try b.busSignal(c, "NameAcquired", .{name});
            try b.busSignal(null, "NameOwnerChanged", .{ name, "", c.uniqueName() });
        } else if (flags & 2 != 0) { // replace existing (assumes the owner allows it)
            const old = q.items[0];
            q.items[0] = c;
            try b.reply(c, m, .{@as(u32, 1)});
            try b.busSignal(old, "NameLost", .{name});
            try b.busSignal(c, "NameAcquired", .{name});
            try b.busSignal(null, "NameOwnerChanged", .{ name, old.uniqueName(), c.uniqueName() });
        } else if (flags & 4 != 0) {
            try b.reply(c, m, .{@as(u32, 3)});
        } else {
            try q.append(b.gpa, c);
            try b.reply(c, m, .{@as(u32, 2)});
        }
    } else if (std.mem.eql(u8, member, "ReleaseName")) {
        const name = try d.readString();
        try b.release(c, name);
        if (!m.flags.no_reply_expected) try b.reply(c, m, .{@as(u32, 1)});
    } else {
        try b.replyError(c, m, "org.freedesktop.DBus.Error.UnknownMethod", member);
    }
}

fn release(b: *TestBus, c: *Client, name: []const u8) !void {
    const q = b.names.getPtr(name) orelse return;
    for (q.items, 0..) |o, i| if (o == c) {
        _ = q.orderedRemove(i);
        if (i == 0) {
            const new = if (q.items.len > 0) q.items[0].uniqueName() else "";
            if (q.items.len > 0) try b.busSignal(q.items[0], "NameAcquired", .{name});
            try b.busSignal(null, "NameOwnerChanged", .{ name, c.uniqueName(), new });
        }
        return;
    };
}

fn drop(b: *TestBus, c: *Client) void {
    for (b.clients.items, 0..) |x, i| if (x == c) {
        _ = b.clients.orderedRemove(i);
        break;
    };
    var it = b.names.iterator();
    while (it.next()) |e| b.release(c, e.key_ptr.*) catch {};
    b.busSignal(null, "NameOwnerChanged", .{ c.uniqueName(), c.uniqueName(), "" }) catch {};
    b.freeClient(c);
}
