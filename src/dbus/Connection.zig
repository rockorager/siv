//! A D-Bus connection on the event loop (D5, D6, D19).
//!
//! The connection is a loop source. Its io handler only moves bytes: it
//! reads into a receive buffer (with any fds that arrive) and schedules
//! the dispatch task. The dispatch task, a safe point, finishes SASL,
//! parses and validates messages in place, and runs reply callbacks,
//! signal subscriptions, and method handlers. Outgoing messages are
//! queued and written in one sendmsg per batch from the prepare hook,
//! before the loop sleeps (sending outside an iteration wakes the loop).
//!
//! The client pipelines authentication with its first messages (SASL,
//! then Hello on a bus), so a call made right after `init` costs one round
//! trip. Messages carrying fds wait until the server has agreed to fd
//! passing; if it refuses, their calls fail with `error.FdsNotSupported`.
//!
//! Everything the connection calls back is registered by pointer and owned
//! by the caller (subscriptions, name watches, name requests, objects), so
//! routing allocates nothing per message. Received messages are views
//! into the receive buffer, valid only during the callback.
//!
//! Loop thread only. Callbacks may use the connection freely except to
//! `deinit` it.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const List = std.DoublyLinkedList;
const loop_mod = @import("loop");
const Loop = loop_mod.Loop;
const Timer = loop_mod.Timer;
const codec = @import("codec.zig");
const message = @import("message.zig");
const auth = @import("auth.zig");
const address = @import("address.zig");
const match = @import("match.zig");
const object = @import("object.zig");
const names = @import("names.zig");

const Message = message.Message;
const Builder = message.Builder;
const Interface = object.Interface;
const Object = object.Object;
const Node = object.Node;

const Connection = @This();

gpa: Allocator,
loop: *Loop,
options: Options,
fd: i32 = -1,
source: Loop.Source = undefined,
hook: Loop.Hook = .{ .func = onPrepare },
task: Loop.Task = .{ .func = onDispatch },
timer: Timer = .{ .func = onTimeout },
state: Status = .authenticating,
sasl: auth.Client,
/// The socket failed or reached EOF; the dispatch task closes the
/// connection once the bytes already received are dispatched.
broken: bool = false,
read_paused: bool = false,
dispatching: bool = false,
unix_fds: bool = false,
serial: u32 = 0,
unique_name: Name = .{},

in: std.ArrayList(u8) = .empty,
in_start: usize = 0,
in_fds: std.ArrayList(i32) = .empty,
in_fds_head: usize = 0,
out: std.ArrayList(Out) = .empty,
out_head: usize = 0,

pending: std.AutoHashMapUnmanaged(u32, Pending) = .empty,
subs: List = .{},
sub_cursor: ?*List.Node = null,
watches: List = .{},
watch_cursor: ?*List.Node = null,
owners: List = .{},
objects: std.StringHashMapUnmanaged(*Object) = .empty,
machine_id: ?[32]u8 = null,
hello_serial: u32 = 0,
/// Buffers of sent messages kept for reuse, so steady traffic allocates
/// nothing.
spare: std.ArrayList(std.ArrayList(u8)) = .empty,

pub const Status = enum { authenticating, running, closed };

pub const Options = struct {
    /// Register with a message bus (Hello). False for a peer-to-peer
    /// connection.
    bus: bool = true,
    /// Ask for unix fd passing.
    unix_fds: bool = true,
    /// Called at a safe point when the connection is ready (the bus
    /// assigned a unique name, or authentication finished on a
    /// peer-to-peer connection) and when it closes.
    on_event: ?*const fn (ctx: ?*anyopaque, conn: *Connection, event: Event) void = null,
    ctx: ?*anyopaque = null,
};

pub const Event = enum { ready, disconnected };

pub const Error = error{
    /// The connection is closed or failed.
    Disconnected,
    /// No address in the list could be connected to.
    ConnectFailed,
    /// A message has fds and the server refused fd passing.
    FdsNotSupported,
    /// An object is already exported at the path.
    ObjectExists,
    /// Name watching and ownership need a message bus.
    NoBus,
} || address.Error || match.Rule.Error || message.Message.Error || codec.EncodeError;

/// A bus name, stored inline.
pub const Name = struct {
    buf: [names.max_name_len]u8 = undefined,
    len: u8 = 0,

    pub fn set(n: *Name, s: []const u8) void {
        const len = @min(s.len, n.buf.len);
        @memcpy(n.buf[0..len], s[0..len]);
        n.len = @intCast(len);
    }

    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }
};

/// Well-known error names.
pub const errors = struct {
    pub const failed = "org.freedesktop.DBus.Error.Failed";
    pub const no_memory = "org.freedesktop.DBus.Error.NoMemory";
    pub const service_unknown = "org.freedesktop.DBus.Error.ServiceUnknown";
    pub const name_has_no_owner = "org.freedesktop.DBus.Error.NameHasNoOwner";
    pub const no_reply = "org.freedesktop.DBus.Error.NoReply";
    pub const access_denied = "org.freedesktop.DBus.Error.AccessDenied";
    pub const not_supported = "org.freedesktop.DBus.Error.NotSupported";
    pub const invalid_args = "org.freedesktop.DBus.Error.InvalidArgs";
    pub const unknown_method = "org.freedesktop.DBus.Error.UnknownMethod";
    pub const unknown_object = "org.freedesktop.DBus.Error.UnknownObject";
    pub const unknown_interface = "org.freedesktop.DBus.Error.UnknownInterface";
    pub const unknown_property = "org.freedesktop.DBus.Error.UnknownProperty";
    pub const property_read_only = "org.freedesktop.DBus.Error.PropertyReadOnly";
};

pub const bus_name = "org.freedesktop.DBus";
pub const bus_path = "/org/freedesktop/DBus";
const peer_interface = "org.freedesktop.DBus.Peer";
const introspectable_interface = "org.freedesktop.DBus.Introspectable";
const properties_interface = "org.freedesktop.DBus.Properties";

/// The default reply timeout, as in libdbus.
pub const default_timeout_ms = 25_000;
/// Unparsed received bytes above which reading pauses until dispatch
/// catches up.
const read_high_water = 8 << 20;
const read_chunk = 64 << 10;
const max_spare = 32;
const max_spare_capacity = 64 << 10;

// Lifecycle ------------------------------------------------------------------

/// Connects to the first reachable entry of `addr` (see `address`), starts
/// authentication, and on a bus queues Hello. Messages may be sent at once.
pub fn init(c: *Connection, gpa: Allocator, loop: *Loop, addr: []const u8, options: Options) Error!void {
    var it: address.Iterator = .init(addr);
    while (try it.next()) |s| {
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
        const fd: i32 = @intCast(rc);
        // A unix connect completes at once unless the listen backlog is
        // full, so it is made blocking and the socket switched after.
        if (linux.errno(linux.connect(fd, &s.addr, s.len)) != .SUCCESS) {
            _ = linux.close(fd);
            continue;
        }
        return c.initFd(gpa, loop, fd, options) catch |err| {
            _ = linux.close(fd);
            return err;
        };
    }
    return error.ConnectFailed;
}

/// Takes ownership of a connected stream socket.
pub fn initFd(c: *Connection, gpa: Allocator, loop: *Loop, fd: i32, options: Options) Error!void {
    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(fl) != .SUCCESS) return error.SystemResources;
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, fl | linux.SOCK.NONBLOCK)) != .SUCCESS) return error.SystemResources;
    c.* = .{
        .gpa = gpa,
        .loop = loop,
        .options = options,
        .fd = fd,
        .sasl = .{ .negotiate_fds = options.unix_fds },
    };
    c.source = .{ .fd = fd, .events = linux.EPOLL.IN, .func = onIo };
    errdefer c.freeBuffers();
    try c.spare.ensureTotalCapacity(gpa, max_spare);
    var hello_buf: [64]u8 = undefined;
    const hello = auth.clientHello(&hello_buf, linux.getuid(), options.unix_fds);
    try c.out.append(gpa, .{});
    try c.out.items[0].head.appendSlice(gpa, hello);
    if (options.bus) {
        var b = c.busCall("Hello");
        c.hello_serial = try c.call(&b, onHello, c, .{});
    }
    loop.addSource(&c.source) catch return error.SystemResources;
    loop.addHook(&c.hook);
    c.flushIfIdle();
}

/// Closes the connection without running any callback: pending calls are
/// dropped, and queued messages that cannot be written at once are lost.
/// Must not be called from one of this connection's callbacks.
pub fn deinit(c: *Connection) void {
    std.debug.assert(!c.dispatching);
    c.flushOut();
    c.loop.removeHook(&c.hook);
    c.loop.unschedule(&c.task);
    c.loop.cancelTimer(&c.timer);
    c.closeSocket();
    c.freeBuffers();
    c.* = undefined;
}

fn closeSocket(c: *Connection) void {
    if (c.fd < 0) return;
    c.loop.removeSource(&c.source);
    _ = linux.close(c.fd);
    c.fd = -1;
}

fn freeBuffers(c: *Connection) void {
    c.in.deinit(c.gpa);
    for (c.in_fds.items[c.in_fds_head..]) |fd| _ = linux.close(fd);
    c.in_fds.deinit(c.gpa);
    for (c.out.items[c.out_head..]) |*o| o.deinit(c.gpa);
    c.out.deinit(c.gpa);
    c.pending.deinit(c.gpa);
    c.objects.deinit(c.gpa);
    for (c.spare.items) |*b| b.deinit(c.gpa);
    c.spare.deinit(c.gpa);
}

/// The unique name the bus assigned, empty until ready.
pub fn uniqueName(c: *const Connection) []const u8 {
    return c.unique_name.slice();
}

/// Whether the connection can still send.
pub fn connected(c: *const Connection) bool {
    return c.state != .closed and !c.broken;
}

// Sending --------------------------------------------------------------------

const Out = struct {
    head: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    fds: std.ArrayList(i32) = .empty,
    serial: u32 = 0,
    sent: usize = 0,

    fn len(o: *const Out) usize {
        return o.head.items.len + o.body.items.len;
    }

    fn deinit(o: *Out, gpa: Allocator) void {
        o.head.deinit(gpa);
        o.body.deinit(gpa);
        for (o.fds.items) |fd| _ = linux.close(fd);
        o.fds.deinit(gpa);
    }
};

pub fn methodCall(c: *Connection, destination: ?[]const u8, path: []const u8, interface: ?[]const u8, member: []const u8) Builder {
    return c.newBuilder(.{ .type = .method_call, .destination = destination, .path = path, .interface = interface, .member = member });
}

pub fn signal(c: *Connection, path: []const u8, interface: []const u8, member: []const u8) Builder {
    return c.newBuilder(.{ .type = .signal, .path = path, .interface = interface, .member = member });
}

/// A builder whose body reuses a buffer of a sent message.
pub fn newBuilder(c: *Connection, header: message.Header) Builder {
    var b: Builder = .init(c.gpa, header);
    b.body.buf = c.spare.pop() orelse .empty;
    return b;
}

fn recycle(c: *Connection, buf: *std.ArrayList(u8)) void {
    if (buf.capacity == 0 or buf.capacity > max_spare_capacity or c.spare.items.len == c.spare.capacity) {
        buf.deinit(c.gpa);
    } else {
        buf.clearRetainingCapacity();
        c.spare.appendAssumeCapacity(buf.*);
    }
    buf.* = .empty;
}

/// Frees a message that went out, keeping its buffers.
fn sent(c: *Connection, o: *Out) void {
    c.recycle(&o.head);
    c.recycle(&o.body);
    o.deinit(c.gpa);
}

/// A call to the bus itself.
pub fn busCall(c: *Connection, member: []const u8) Builder {
    return c.methodCall(bus_name, bus_path, bus_name, member);
}

/// Queues the message and returns its serial. Always consumes `b`.
pub fn send(c: *Connection, b: *Builder) Error!u32 {
    defer b.deinit();
    return c.queue(b);
}

fn queue(c: *Connection, b: *Builder) Error!u32 {
    if (!c.connected()) return error.Disconnected;
    if (!b.body.complete()) return error.SignatureMismatch;
    try b.header.validate();
    const has_fds = b.body.fds.items.len > 0;
    if (has_fds and c.state == .running and !c.unix_fds) return error.FdsNotSupported;
    try c.out.ensureUnusedCapacity(c.gpa, 1);
    var o: Out = .{ .head = c.spare.pop() orelse .empty };
    errdefer c.recycle(&o.head);
    const serial = c.nextSerial();
    try message.encodeHeader(c.gpa, &o.head, &b.header, serial, b.body.signature(), b.body.bytes().len, b.body.fds.items.len);
    o.serial = serial;
    o.body = b.body.buf;
    o.fds = b.body.fds;
    b.body.buf = .empty;
    b.body.fds = .empty;
    c.out.appendAssumeCapacity(o);
    c.flushIfIdle();
    return serial;
}

fn nextSerial(c: *Connection) u32 {
    c.serial +%= 1;
    if (c.serial == 0) c.serial = 1;
    return c.serial;
}

/// Writes queued messages now instead of before the loop sleeps.
pub fn flush(c: *Connection) void {
    c.flushOut();
}

fn flushIfIdle(c: *Connection) void {
    // Inside an iteration the prepare hook flushes. Outside one, make the
    // next iteration run instead of sleeping; a burst of sends still goes
    // out in one write.
    if (!c.loop.isDispatching()) c.loop.wake();
}

fn onPrepare(h: *Loop.Hook) void {
    const c: *Connection = @fieldParentPtr("hook", h);
    c.flushOut();
}

fn flushOut(c: *Connection) void {
    if (c.fd < 0 or c.broken) return;
    while (c.out_head < c.out.items.len) {
        const max_iov = 64;
        var iov: [max_iov]std.posix.iovec_const = undefined;
        var n_iov: usize = 0;
        var control: [cmsgSpace(codec.max_fds)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 0, .control = null, .controllen = 0, .flags = 0 };
        const first = &c.out.items[c.out_head];
        if (first.fds.items.len > 0) {
            if (c.state != .running) break; // fd passing not agreed yet
            const n = first.fds.items.len;
            const hdr: *linux.cmsghdr = @ptrCast(&control);
            hdr.* = .{ .len = cmsgLen(n * 4), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
            @memcpy(control[@sizeOf(linux.cmsghdr)..][0 .. n * 4], std.mem.sliceAsBytes(first.fds.items));
            msg.control = &control;
            msg.controllen = cmsgSpace(n);
        }
        for (c.out.items[c.out_head..], 0..) |*o, i| {
            if (i > 0 and o.fds.items.len > 0) break;
            if (n_iov + 2 > max_iov) break;
            var skip = o.sent;
            for ([_][]const u8{ o.head.items, o.body.items }) |part| {
                if (skip >= part.len) {
                    skip -= part.len;
                    continue;
                }
                iov[n_iov] = .{ .base = part.ptr + skip, .len = part.len - skip };
                n_iov += 1;
                skip = 0;
            }
        }
        msg.iovlen = n_iov;
        const rc = linux.sendmsg(c.fd, &msg, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            .AGAIN => {
                c.setEvents(true);
                return;
            },
            else => return c.fail(),
        }
        // The kernel holds the fds now; ours are closed as the message is
        // freed, or here if only part of it went out.
        if (msg.control != null) {
            for (first.fds.items) |fd| _ = linux.close(fd);
            first.fds.clearRetainingCapacity();
        }
        var n = rc;
        while (n > 0) {
            const o = &c.out.items[c.out_head];
            const rem = o.len() - o.sent;
            if (n < rem) {
                o.sent += n;
                break;
            }
            n -= rem;
            c.sent(o);
            c.out_head += 1;
        }
        // Empty messages (none exist on the wire) cannot stall the loop.
        while (c.out_head < c.out.items.len and c.out.items[c.out_head].len() == 0) : (c.out_head += 1) c.out.items[c.out_head].deinit(c.gpa);
    }
    if (c.out_head == c.out.items.len) {
        c.out.clearRetainingCapacity();
        c.out_head = 0;
        c.setEvents(false);
    }
}

fn setEvents(c: *Connection, want_out: bool) void {
    if (c.fd < 0) return;
    var ev: u32 = if (want_out) linux.EPOLL.OUT else 0;
    if (!c.read_paused) ev |= linux.EPOLL.IN;
    c.loop.modifySource(&c.source, ev) catch c.fail();
}

fn wantsOut(c: *const Connection) bool {
    return c.source.events & linux.EPOLL.OUT != 0;
}

fn cmsgLen(n: usize) usize {
    return @sizeOf(linux.cmsghdr) + n;
}

fn cmsgSpace(comptime_or_runtime_fds: usize) usize {
    return @sizeOf(linux.cmsghdr) + std.mem.alignForward(usize, comptime_or_runtime_fds * 4, @sizeOf(usize));
}

// Receiving ------------------------------------------------------------------

fn onIo(s: *Loop.Source, events: u32) void {
    const c: *Connection = @fieldParentPtr("source", s);
    if (events & linux.EPOLL.OUT != 0) c.flushOut();
    if (c.fd >= 0 and events & (linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) c.readSome();
}

fn readSome(c: *Connection) void {
    // Make room for a whole frame once its length is known, so a large
    // message is read straight into place.
    var want: usize = read_chunk;
    const buffered = c.in.items[c.in_start..];
    if (c.state == .running and buffered.len >= message.fixed_header_len) {
        if (Message.frameLength(buffered[0..message.fixed_header_len])) |n| {
            if (n > buffered.len) want = @max(want, n - buffered.len);
        } else |_| {}
    }
    c.in.ensureUnusedCapacity(c.gpa, want) catch return c.fail();
    const space = c.in.unusedCapacitySlice();
    var iov = [_]std.posix.iovec{.{ .base = space.ptr, .len = space.len }};
    var control: [cmsgSpace(codec.max_fds)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
    const rc = linux.recvmsg(c.fd, &msg, linux.MSG.CMSG_CLOEXEC | linux.MSG.DONTWAIT);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .INTR => return,
        else => return c.fail(),
    }
    // Take the fds before anything else so that they are never leaked.
    var off: usize = 0;
    while (off + @sizeOf(linux.cmsghdr) <= msg.controllen) {
        const hdr: *align(1) const linux.cmsghdr = @ptrCast(control[off..]);
        if (hdr.len < @sizeOf(linux.cmsghdr) or off + hdr.len > msg.controllen) break;
        if (hdr.level == linux.SOL.SOCKET and hdr.type == linux.SCM.RIGHTS) {
            const data = control[off + @sizeOf(linux.cmsghdr) .. off + hdr.len];
            var i: usize = 0;
            while (i + 4 <= data.len) : (i += 4) {
                const fd = std.mem.readInt(i32, data[i..][0..4], @import("builtin").cpu.arch.endian());
                c.in_fds.append(c.gpa, fd) catch {
                    _ = linux.close(fd);
                    c.fail();
                };
            }
        }
        off += std.mem.alignForward(usize, hdr.len, @sizeOf(usize));
    }
    if (msg.flags & linux.MSG.CTRUNC != 0) return c.fail(); // fds were lost
    if (rc == 0) return c.fail(); // EOF
    c.in.items.len += rc;
    c.loop.schedule(&c.task, .dispatch);
    if (c.in.items.len - c.in_start > read_high_water and !c.read_paused) {
        c.read_paused = true;
        c.setEvents(c.wantsOut());
    }
}

/// Marks the connection broken and stops polling; the dispatch task
/// delivers what was received and then closes it.
fn fail(c: *Connection) void {
    c.broken = true;
    c.closeSocket();
    c.loop.schedule(&c.task, .dispatch);
}

const max_dispatch = 128;

fn onDispatch(t: *Loop.Task) void {
    const c: *Connection = @fieldParentPtr("task", t);
    c.dispatching = true;
    defer c.dispatching = false;
    var count: usize = 0;
    while (c.state != .closed) {
        const data = c.in.items[c.in_start..];
        if (c.state == .authenticating) {
            const used = c.sasl.feed(data) catch {
                c.close();
                break;
            };
            c.in_start += used;
            if (!c.sasl.done()) break;
            c.authenticated();
            continue;
        }
        if (count == max_dispatch) {
            // Let frames run; continue next iteration.
            c.loop.schedule(&c.task, .dispatch);
            break;
        }
        if (data.len < message.fixed_header_len) break;
        const len = Message.frameLength(data[0..message.fixed_header_len]) catch {
            c.close();
            break;
        };
        if (data.len < len) break;
        var m = Message.parse(data[0..len]) catch {
            c.close();
            break;
        };
        const avail = c.in_fds.items.len - c.in_fds_head;
        if (m.unix_fds > avail) {
            c.close();
            break;
        }
        m.fds = c.in_fds.items[c.in_fds_head..][0..m.unix_fds];
        c.dispatchMessage(&m);
        for (m.fds) |fd| if (fd >= 0) {
            _ = linux.close(fd);
        };
        c.in_fds_head += m.unix_fds;
        c.in_start += len;
        count += 1;
    }
    c.compact();
    // A broken connection closes once the complete messages it received
    // are dispatched; a partial one is lost.
    if (c.broken and c.state != .closed and !c.task.scheduled()) c.close();
}

fn compact(c: *Connection) void {
    if (c.in_start > 0) {
        const rest = c.in.items.len - c.in_start;
        std.mem.copyForwards(u8, c.in.items[0..rest], c.in.items[c.in_start..]);
        c.in.items.len = rest;
        c.in_start = 0;
        if (rest == 0 and c.in.capacity > 1 << 20) c.in.clearAndFree(c.gpa);
    }
    if (c.in_fds_head == c.in_fds.items.len) {
        c.in_fds.clearRetainingCapacity();
        c.in_fds_head = 0;
    }
    // Dispatch has taken every complete message (or is scheduled to take
    // more); a partial one, however large, needs more bytes.
    if (c.read_paused and !c.task.scheduled() and c.fd >= 0) {
        c.read_paused = false;
        c.setEvents(c.wantsOut());
    }
}

fn authenticated(c: *Connection) void {
    c.state = .running;
    c.unix_fds = c.sasl.unix_fds;
    if (!c.unix_fds) {
        // Fail queued messages that carry fds.
        var i = c.out_head;
        while (i < c.out.items.len) {
            if (c.out.items[i].fds.items.len == 0) {
                i += 1;
                continue;
            }
            var o = c.out.orderedRemove(i);
            o.deinit(c.gpa);
            if (c.pending.fetchRemove(o.serial)) |kv| kv.value.func(kv.value.ctx, .{ .failed = error.FdsNotSupported });
        }
    }
    if (!c.options.bus) c.emit(.ready);
    c.flushOut();
}

/// Closes the connection at a safe point: fails pending calls and reports
/// `disconnected`.
fn close(c: *Connection) void {
    if (c.state == .closed) return;
    c.state = .closed;
    c.broken = true;
    c.closeSocket();
    c.loop.cancelTimer(&c.timer);
    for (c.out.items[c.out_head..]) |*o| o.deinit(c.gpa);
    c.out.clearRetainingCapacity();
    c.out_head = 0;
    var pending = c.pending;
    c.pending = .empty;
    defer pending.deinit(c.gpa);
    var it = pending.valueIterator();
    while (it.next()) |p| p.func(p.ctx, .{ .failed = error.Disconnected });
    c.emit(.disconnected);
}

fn emit(c: *Connection, event: Event) void {
    if (c.options.on_event) |f| f(c.options.ctx, c, event);
}

fn dispatchMessage(c: *Connection, m: *const Message) void {
    switch (m.type) {
        .method_return, .@"error" => {
            const kv = c.pending.fetchRemove(m.reply_serial.?) orelse return;
            kv.value.func(kv.value.ctx, if (m.type == .method_return) .{ .ok = m } else .{ .err = m });
        },
        .signal => c.dispatchSignal(m),
        .method_call => c.dispatchCall(m),
        _ => {}, // unknown types are ignored
    }
}

// Calls ----------------------------------------------------------------------

/// The outcome of a call, passed to its callback at a safe point. The
/// messages are borrowed for the duration of the callback.
pub const Reply = union(enum) {
    ok: *const Message,
    /// An error reply; see `Message.error_name` and `errorMessage`.
    err: *const Message,
    /// No reply will come.
    failed: CallError,

    /// The error name, for `err`.
    pub fn errorName(r: Reply) ?[]const u8 {
        return switch (r) {
            .err => |m| m.error_name,
            else => null,
        };
    }
};

pub const CallError = error{ Disconnected, Timeout, FdsNotSupported };

pub const ReplyFn = *const fn (ctx: ?*anyopaque, reply: Reply) void;

const Pending = struct {
    func: ReplyFn,
    ctx: ?*anyopaque,
    deadline: u64,
};

pub const CallOptions = struct {
    /// Null waits forever.
    timeout_ms: ?u32 = default_timeout_ms,
};

/// Sends a method call; `func` runs once with the reply, an error reply,
/// or a failure. Returns the serial, which `cancelCall` accepts. Always
/// consumes `b`.
pub fn call(c: *Connection, b: *Builder, func: ReplyFn, ctx: ?*anyopaque, opts: CallOptions) Error!u32 {
    defer b.deinit();
    std.debug.assert(b.header.type == .method_call and !b.header.flags.no_reply_expected);
    try c.pending.ensureUnusedCapacity(c.gpa, 1);
    const serial = try c.queue(b);
    const deadline = if (opts.timeout_ms) |ms| Loop.now() + @as(u64, ms) * std.time.ns_per_ms else std.math.maxInt(u64);
    c.pending.putAssumeCapacity(serial, .{ .func = func, .ctx = ctx, .deadline = deadline });
    if (opts.timeout_ms != null and (!c.timer.armed() or deadline < c.timer.deadline)) {
        // Without a timer the call just never times out.
        c.loop.startTimer(&c.timer, deadline, 0) catch {};
    }
    return serial;
}

/// Calls `member` with `args` (a tuple of values).
pub fn callMethod(
    c: *Connection,
    destination: ?[]const u8,
    path: []const u8,
    interface: ?[]const u8,
    member: []const u8,
    args: anytype,
    func: ReplyFn,
    ctx: ?*anyopaque,
) Error!u32 {
    var b = c.methodCall(destination, path, interface, member);
    b.body.writeAll(args) catch |err| {
        b.deinit();
        return err;
    };
    return c.call(&b, func, ctx, .{});
}

/// Forgets a pending call; its callback will not run.
pub fn cancelCall(c: *Connection, serial: u32) void {
    _ = c.pending.remove(serial);
}

fn onTimeout(t: *Timer) void {
    const c: *Connection = @fieldParentPtr("timer", t);
    const now = Loop.now();
    var next: u64 = std.math.maxInt(u64);
    var expired: [16]u32 = undefined;
    var n: usize = 0;
    var it = c.pending.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.deadline <= now) {
            if (n < expired.len) {
                expired[n] = e.key_ptr.*;
                n += 1;
            } else next = now; // the rest on the next round
        } else next = @min(next, e.value_ptr.deadline);
    }
    if (next != std.math.maxInt(u64)) c.loop.startTimer(&c.timer, next, 0) catch {};
    for (expired[0..n]) |serial| {
        const kv = c.pending.fetchRemove(serial) orelse continue;
        kv.value.func(kv.value.ctx, .{ .failed = error.Timeout });
    }
}

fn onHello(ctx: ?*anyopaque, reply: Reply) void {
    const c: *Connection = @ptrCast(@alignCast(ctx));
    c.hello_serial = 0;
    switch (reply) {
        .ok => |m| {
            var d = m.body();
            const name = d.readString() catch return c.close();
            c.unique_name.set(name);
            c.emit(.ready);
        },
        .err, .failed => c.close(),
    }
}

// Signals --------------------------------------------------------------------

/// Sends a signal with `args` (a tuple of values).
pub fn emitSignal(c: *Connection, path: []const u8, interface: []const u8, member: []const u8, args: anytype) Error!void {
    var b = c.signal(path, interface, member);
    b.body.writeAll(args) catch |err| {
        b.deinit();
        return err;
    };
    _ = try c.send(&b);
}

/// A signal handler, owned by the caller. On a bus the rule is also sent
/// to it with AddMatch.
pub const Subscription = struct {
    /// Borrowed while subscribed. `type` defaults to signals.
    rule: match.Rule,
    func: *const fn (sub: *Subscription, msg: *const Message) void,
    node: List.Node = .{},
    /// Tracks the owner of a well-known `rule.sender`: signals carry the
    /// owner's unique name.
    sender_watch: NameWatch = undefined,
    watching_sender: bool = false,
};

pub fn subscribe(c: *Connection, s: *Subscription) Error!void {
    if (s.rule.type == null) s.rule.type = .signal;
    try s.rule.validate();
    if (c.options.bus) try c.sendMatch("AddMatch", &s.rule);
    s.watching_sender = false;
    if (s.rule.sender) |sender| {
        if (c.options.bus and !names.isUniqueName(sender) and !std.mem.eql(u8, sender, bus_name)) {
            s.sender_watch = .{ .name = sender };
            try c.watchName(&s.sender_watch);
            s.watching_sender = true;
        }
    }
    c.subs.append(&s.node);
}

pub fn unsubscribe(c: *Connection, s: *Subscription) void {
    if (c.options.bus and c.connected()) c.sendMatch("RemoveMatch", &s.rule) catch {};
    if (s.watching_sender) c.unwatchName(&s.sender_watch);
    if (c.sub_cursor == &s.node) c.sub_cursor = s.node.next;
    c.subs.remove(&s.node);
}

fn sendMatch(c: *Connection, member: []const u8, rule: *const match.Rule) Error!void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(c.gpa);
    try rule.format(c.gpa, &text);
    var b = c.busCall(member);
    // A rule is validated here, so the bus has no reason to refuse it
    // except quota; nobody waits for the reply.
    b.header.flags.no_reply_expected = true;
    b.body.writeString(text.items) catch |err| {
        b.deinit();
        return err;
    };
    _ = try c.send(&b);
}

fn dispatchSignal(c: *Connection, m: *const Message) void {
    if (m.sender != null and std.mem.eql(u8, m.sender.?, bus_name) and m.interface != null and std.mem.eql(u8, m.interface.?, bus_name)) {
        c.busSignal(m);
    }
    c.sub_cursor = c.subs.first;
    while (c.sub_cursor) |n| {
        c.sub_cursor = n.next;
        const s: *Subscription = @fieldParentPtr("node", n);
        if (!c.subscriptionMatches(s, m)) continue;
        s.func(s, m);
    }
}

fn subscriptionMatches(_: *Connection, s: *Subscription, m: *const Message) bool {
    if (!s.watching_sender) return s.rule.matches(m);
    if (!s.rule.matchesExceptSender(m)) return false;
    return switch (s.sender_watch.state) {
        // The owner is not known yet; the bus filtered by sender.
        .unknown => true,
        .owned => m.sender != null and std.mem.eql(u8, m.sender.?, s.sender_watch.owner_name.slice()),
        .unowned => false,
    };
}

// Name watching ----------------------------------------------------------------

/// Follows the owner of a bus name, owned by the caller.
pub const NameWatch = struct {
    /// Borrowed while watched.
    name: []const u8,
    /// Called when the owner becomes known or changes.
    func: ?*const fn (w: *NameWatch) void = null,
    state: enum { unknown, owned, unowned } = .unknown,
    owner_name: Name = .{},
    node: List.Node = .{},
    lookup: u32 = 0,
    arg: match.Arg = undefined,

    /// The unique name of the current owner, or null.
    pub fn owner(w: *const NameWatch) ?[]const u8 {
        return if (w.state == .owned) w.owner_name.slice() else null;
    }
};

pub fn watchName(c: *Connection, w: *NameWatch) Error!void {
    if (!c.options.bus) return error.NoBus;
    if (!names.isBusName(w.name)) return error.InvalidRule;
    w.state = .unknown;
    try c.sendMatch("AddMatch", &watchRule(w));
    var b = c.busCall("GetNameOwner");
    b.body.writeString(w.name) catch |err| {
        b.deinit();
        return err;
    };
    w.lookup = try c.call(&b, onNameOwner, w, .{});
    c.watches.append(&w.node);
}

pub fn unwatchName(c: *Connection, w: *NameWatch) void {
    if (c.connected()) c.sendMatch("RemoveMatch", &watchRule(w)) catch {};
    if (w.lookup != 0) c.cancelCall(w.lookup);
    if (c.watch_cursor == &w.node) c.watch_cursor = w.node.next;
    c.watches.remove(&w.node);
}

fn watchRule(w: *NameWatch) match.Rule {
    w.arg = .{ .index = 0, .value = w.name };
    return .{
        .type = .signal,
        .sender = bus_name,
        .interface = bus_name,
        .member = "NameOwnerChanged",
        .path = bus_path,
        .args = (&w.arg)[0..1],
    };
}

fn onNameOwner(ctx: ?*anyopaque, reply: Reply) void {
    const w: *NameWatch = @ptrCast(@alignCast(ctx));
    w.lookup = 0;
    switch (reply) {
        .ok => |m| {
            var d = m.body();
            setOwner(w, d.readString() catch "");
        },
        .err => setOwner(w, ""),
        .failed => {},
    }
}

fn setOwner(w: *NameWatch, owner: []const u8) void {
    if (owner.len == 0) {
        if (w.state == .unowned) return;
        w.state = .unowned;
    } else {
        if (w.state == .owned and std.mem.eql(u8, w.owner_name.slice(), owner)) return;
        w.state = .owned;
        w.owner_name.set(owner);
    }
    if (w.func) |f| f(w);
}

fn busSignal(c: *Connection, m: *const Message) void {
    const member = m.member.?;
    var d = m.body();
    if (std.mem.eql(u8, member, "NameOwnerChanged")) {
        const args = d.readAll(struct { []const u8, []const u8, []const u8 }) catch return;
        c.watch_cursor = c.watches.first;
        while (c.watch_cursor) |n| {
            c.watch_cursor = n.next;
            const w: *NameWatch = @fieldParentPtr("node", n);
            if (std.mem.eql(u8, w.name, args[0])) setOwner(w, args[2]);
        }
    } else if (std.mem.eql(u8, member, "NameAcquired") or std.mem.eql(u8, member, "NameLost")) {
        const name = d.readString() catch return;
        const acquired = member[4] == 'A';
        var it = c.owners.first;
        while (it) |n| {
            it = n.next;
            const o: *NameOwner = @fieldParentPtr("node", n);
            if (!std.mem.eql(u8, o.name, name)) continue;
            o.setState(if (acquired) .primary else .lost);
        }
    }
}

// Name ownership ---------------------------------------------------------------

/// A request to own a bus name, owned by the caller.
pub const NameOwner = struct {
    /// Borrowed while requested.
    name: []const u8,
    flags: Flags = .{},
    /// Called when `state` changes.
    func: ?*const fn (o: *NameOwner) void = null,
    state: State = .idle,
    node: List.Node = .{},
    request: u32 = 0,

    pub const Flags = packed struct(u32) {
        allow_replacement: bool = false,
        replace_existing: bool = false,
        do_not_queue: bool = false,
        _: u29 = 0,
    };

    pub const State = enum {
        idle,
        requesting,
        /// This connection owns the name.
        primary,
        /// Waiting in the bus's queue for the name.
        queued,
        /// Another connection owns it and the request did not queue.
        exists,
        /// The name was taken over by another connection.
        lost,
        /// The bus refused the request (policy, invalid name).
        failed,
    };

    fn setState(o: *NameOwner, s: State) void {
        if (o.state == s) return;
        o.state = s;
        if (o.func) |f| f(o);
    }
};

pub fn requestName(c: *Connection, o: *NameOwner) Error!void {
    if (!c.options.bus) return error.NoBus;
    if (!names.isBusName(o.name) or names.isUniqueName(o.name)) return error.InvalidMessage;
    var b = c.busCall("RequestName");
    b.body.writeAll(.{ o.name, @as(u32, @bitCast(o.flags)) }) catch |err| {
        b.deinit();
        return err;
    };
    o.request = try c.call(&b, onRequestName, o, .{});
    o.state = .requesting;
    c.owners.append(&o.node);
}

/// Gives the name up (or leaves the queue). The request's callback does
/// not run again.
pub fn releaseName(c: *Connection, o: *NameOwner) void {
    if (o.request != 0) c.cancelCall(o.request);
    if (c.connected()) {
        var b = c.busCall("ReleaseName");
        b.header.flags.no_reply_expected = true;
        if (b.body.writeString(o.name)) {
            _ = c.send(&b) catch {};
        } else |_| b.deinit();
    }
    c.owners.remove(&o.node);
    o.state = .idle;
}

fn onRequestName(ctx: ?*anyopaque, reply: Reply) void {
    const o: *NameOwner = @ptrCast(@alignCast(ctx));
    o.request = 0;
    switch (reply) {
        .ok => |m| {
            var d = m.body();
            const code = d.readUint32() catch 0;
            o.setState(switch (code) {
                1, 4 => .primary,
                2 => .queued,
                3 => .exists,
                else => .failed,
            });
        },
        .err, .failed => o.setState(.failed),
    }
}

// Objects ----------------------------------------------------------------------

pub fn exportObject(c: *Connection, o: *Object) Error!void {
    if (!names.isObjectPath(o.path)) return error.InvalidMessage;
    const gop = try c.objects.getOrPut(c.gpa, o.path);
    if (gop.found_existing) return error.ObjectExists;
    gop.value_ptr.* = o;
}

pub fn unexportObject(c: *Connection, o: *Object) void {
    if (c.objects.get(o.path) == o) _ = c.objects.remove(o.path);
}

/// The node at `path`: an exported object, or a node of the nearest
/// subtree above it.
pub fn lookup(c: *Connection, path: []const u8) ?Node {
    if (c.objects.get(path)) |o| {
        if (o.subtree) |st| return st.lookup(o, path);
        return .{ .ctx = o.ctx, .interfaces = o.interfaces };
    }
    if (c.subtreeAbove(path)) |o| return o.subtree.?.lookup(o, path);
    return null;
}

fn subtreeAbove(c: *Connection, path: []const u8) ?*Object {
    var p = path;
    while (parentPath(p)) |pp| : (p = pp) {
        if (c.objects.get(pp)) |o| if (o.subtree != null) return o;
    }
    return null;
}

fn parentPath(p: []const u8) ?[]const u8 {
    if (p.len <= 1) return null;
    const i = std.mem.lastIndexOfScalar(u8, p, '/').?;
    return if (i == 0) "/" else p[0..i];
}

/// Emits PropertiesChanged for the named properties of `interface` on the
/// node at `path`: values for properties that emit them, names only for
/// those that invalidate.
pub fn emitPropertiesChanged(c: *Connection, path: []const u8, node: Node, interface: *const Interface, changed: []const []const u8) (Error || error{UnknownProperty})!void {
    var b = c.signal(path, properties_interface, "PropertiesChanged");
    errdefer b.deinit();
    try b.body.writeString(interface.name);
    try b.body.beginArray("{sv}");
    for (changed) |name| {
        const p = interface.findProperty(name) orelse return error.UnknownProperty;
        if (p.emits_changed != .true or !p.readable()) continue;
        const ctx: object.PropertyContext = .{ .path = path, .node = node, .interface = interface, .property = p };
        try b.body.beginDictEntry();
        try b.body.writeString(p.name);
        try b.body.beginVariant(p.signature);
        p.get.?(ctx, &b.body) catch return error.InvalidValue;
        try b.body.endVariant();
        try b.body.endDictEntry();
    }
    try b.body.endArray();
    try b.body.beginArray("s");
    for (changed) |name| {
        const p = interface.findProperty(name).?;
        if (p.emits_changed == .invalidates) try b.body.writeString(p.name);
    }
    try b.body.endArray();
    _ = try c.send(&b);
}

/// An incoming method call being handled.
pub const Request = struct {
    conn: *Connection,
    msg: *const Message,
    path: []const u8,
    node: Node = .{},
    interface: ?*const Interface = null,
    method: ?*const object.Method = null,
    state: enum { pending, replied, deferred } = .pending,

    pub fn args(r: *const Request) codec.Decoder {
        return r.msg.body();
    }

    /// The caller's unique name (absent on peer-to-peer connections).
    pub fn sender(r: *const Request) ?[]const u8 {
        return r.msg.sender;
    }

    pub fn newReply(r: *const Request) Builder {
        return r.conn.newBuilder(.{ .type = .method_return, .destination = r.msg.sender, .reply_serial = r.msg.serial });
    }

    /// Replies with `values` (a tuple).
    pub fn reply(r: *Request, values: anytype) Error!void {
        var b = r.newReply();
        b.body.writeAll(values) catch |err| {
            b.deinit();
            return err;
        };
        return r.sendReply(&b);
    }

    /// Sends a reply built with `newReply`. Always consumes `b`.
    pub fn sendReply(r: *Request, b: *Builder) Error!void {
        std.debug.assert(r.state == .pending);
        r.state = .replied;
        if (r.method) |m| {
            if (!std.mem.eql(u8, b.body.signature(), m.out)) {
                var buf: [512]u8 = undefined;
                const text = bufText(&buf, "{s}.{s} replied with signature '{s}', declared '{s}'", .{ r.interface.?.name, m.name, b.body.signature(), m.out });
                b.deinit();
                r.state = .pending;
                return r.replyError(errors.failed, text);
            }
        }
        if (r.msg.flags.no_reply_expected) {
            b.deinit();
            return;
        }
        _ = try r.conn.send(b);
    }

    pub fn replyError(r: *Request, name: []const u8, text: []const u8) Error!void {
        std.debug.assert(r.state == .pending);
        r.state = .replied;
        if (r.msg.flags.no_reply_expected) return;
        var b = r.conn.newBuilder(.{ .type = .@"error", .destination = r.msg.sender, .reply_serial = r.msg.serial, .error_name = name });
        b.body.writeString(text) catch |err| {
            b.deinit();
            return err;
        };
        _ = try r.conn.send(&b);
    }

    /// Takes over the reply: the handler returns and replies later with
    /// `Connection.replyDeferred`.
    pub fn deferReply(r: *Request) Deferred {
        std.debug.assert(r.state == .pending);
        r.state = .deferred;
        var d: Deferred = .{ .serial = r.msg.serial, .no_reply = r.msg.flags.no_reply_expected, .has_sender = r.msg.sender != null };
        if (r.msg.sender) |s| d.sender.set(s);
        return d;
    }
};

/// A reply to send later.
pub const Deferred = struct {
    serial: u32,
    sender: Name = .{},
    has_sender: bool,
    no_reply: bool,

    pub fn newReply(d: *const Deferred, c: *Connection) Builder {
        return c.newBuilder(.{ .type = .method_return, .destination = if (d.has_sender) d.sender.slice() else null, .reply_serial = d.serial });
    }

    pub fn newError(d: *const Deferred, c: *Connection, name: []const u8) Builder {
        return c.newBuilder(.{ .type = .@"error", .destination = if (d.has_sender) d.sender.slice() else null, .reply_serial = d.serial, .error_name = name });
    }

    /// Sends a reply built with `newReply` or `newError`. Consumes `b`.
    pub fn send(d: *const Deferred, c: *Connection, b: *Builder) Error!void {
        if (d.no_reply) {
            b.deinit();
            return;
        }
        _ = try c.send(b);
    }
};

fn dispatchCall(c: *Connection, m: *const Message) void {
    var r: Request = .{ .conn = c, .msg = m, .path = m.path.? };
    c.handleCall(&r) catch |err| {
        if (r.state != .pending) return;
        // The reply itself failed to send (out of memory, disconnected).
        r.replyError(errorName(err), @errorName(err)) catch {};
    };
}

fn handleCall(c: *Connection, r: *Request) !void {
    const m = r.msg;
    const member = m.member.?;
    var buf: [512]u8 = undefined;
    if (m.interface) |iface| {
        if (std.mem.eql(u8, iface, peer_interface)) {
            if (std.mem.eql(u8, member, "Ping") and m.signature.len == 0) return r.reply(.{});
            if (std.mem.eql(u8, member, "GetMachineId") and m.signature.len == 0) {
                const id = c.machineId() orelse return r.replyError(errors.failed, "no machine id");
                return r.reply(.{@as([]const u8, &id)});
            }
            return r.replyError(errors.unknown_method, "Unknown Peer method");
        }
    }
    const introspect_iface = m.interface == null or std.mem.eql(u8, m.interface.?, introspectable_interface);
    if (introspect_iface and std.mem.eql(u8, member, "Introspect") and m.signature.len == 0) {
        return c.introspect(r);
    }
    r.node = c.lookup(r.path) orelse {
        return r.replyError(errors.unknown_object, bufText(&buf, "No such object path '{s}'", .{r.path}));
    };
    if (m.interface) |iface| {
        if (std.mem.eql(u8, iface, properties_interface)) return c.properties(r);
        const i = r.node.findInterface(iface) orelse {
            return r.replyError(errors.unknown_interface, bufText(&buf, "No such interface '{s}' at '{s}'", .{ iface, r.path }));
        };
        r.interface = i;
        r.method = i.findMethod(member);
    } else {
        for (r.node.interfaces) |i| {
            r.method = i.findMethod(member) orelse continue;
            r.interface = i;
            break;
        }
    }
    const method = r.method orelse {
        return r.replyError(errors.unknown_method, bufText(&buf, "No such method '{s}'", .{member}));
    };
    if (!std.mem.eql(u8, m.signature, method.in)) {
        r.method = null; // the reply is an error, not the declared signature
        return r.replyError(errors.invalid_args, bufText(&buf, "Expected signature '{s}', got '{s}'", .{ method.in, m.signature }));
    }
    method.func(r) catch |err| {
        if (r.state != .pending) return;
        r.method = null;
        return r.replyError(errorName(err), @errorName(err));
    };
    if (r.state == .pending) {
        if (method.out.len == 0) return r.reply(.{});
        r.method = null;
        return r.replyError(errors.failed, "the method returned no reply");
    }
}

fn bufText(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch buf;
}

/// Maps a handler's error to a D-Bus error name.
fn errorName(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArgs, error.SignatureMismatch, error.InvalidMessage, error.InvalidValue => errors.invalid_args,
        error.OutOfMemory => errors.no_memory,
        error.AccessDenied => errors.access_denied,
        error.NotSupported, error.Unsupported => errors.not_supported,
        error.UnknownProperty => errors.unknown_property,
        error.UnknownObject => errors.unknown_object,
        else => errors.failed,
    };
}

fn properties(c: *Connection, r: *Request) !void {
    _ = c;
    const m = r.msg;
    const member = m.member.?;
    var buf: [512]u8 = undefined;
    var d = m.body();
    const iface_name = d.readString() catch return r.replyError(errors.invalid_args, "expected an interface name");
    if (std.mem.eql(u8, member, "GetAll") and std.mem.eql(u8, m.signature, "s")) {
        var b = r.newReply();
        errdefer b.deinit();
        try b.body.beginArray("{sv}");
        for (r.node.interfaces) |i| {
            if (iface_name.len > 0 and !std.mem.eql(u8, i.name, iface_name)) continue;
            for (i.properties) |*p| {
                if (!p.readable()) continue;
                const ctx: object.PropertyContext = .{ .path = r.path, .node = r.node, .interface = i, .property = p };
                try b.body.beginDictEntry();
                try b.body.writeString(p.name);
                try b.body.beginVariant(p.signature);
                try p.get.?(ctx, &b.body);
                try b.body.endVariant();
                try b.body.endDictEntry();
            }
        }
        try b.body.endArray();
        if (iface_name.len > 0 and r.node.findInterface(iface_name) == null) {
            b.deinit();
            return r.replyError(errors.unknown_interface, bufText(&buf, "No such interface '{s}'", .{iface_name}));
        }
        return r.sendReply(&b);
    }
    const get = std.mem.eql(u8, member, "Get") and std.mem.eql(u8, m.signature, "ss");
    const set = std.mem.eql(u8, member, "Set") and std.mem.eql(u8, m.signature, "ssv");
    if (!get and !set) return r.replyError(errors.unknown_method, "Unknown Properties method or signature");
    const prop_name = try d.readString();
    const i = r.node.findInterface(iface_name) orelse {
        return r.replyError(errors.unknown_interface, bufText(&buf, "No such interface '{s}'", .{iface_name}));
    };
    const p = i.findProperty(prop_name) orelse {
        return r.replyError(errors.unknown_property, bufText(&buf, "No such property '{s}'", .{prop_name}));
    };
    const ctx: object.PropertyContext = .{ .path = r.path, .node = r.node, .interface = i, .property = p };
    if (get) {
        if (!p.readable()) return r.replyError(errors.access_denied, bufText(&buf, "Property '{s}' is not readable", .{prop_name}));
        var b = r.newReply();
        errdefer b.deinit();
        try b.body.beginVariant(p.signature);
        try p.get.?(ctx, &b.body);
        try b.body.endVariant();
        return r.sendReply(&b);
    }
    if (!p.writable()) return r.replyError(errors.property_read_only, bufText(&buf, "Property '{s}' is read-only", .{prop_name}));
    const vs = try d.beginVariant();
    if (!std.mem.eql(u8, vs, p.signature)) {
        return r.replyError(errors.invalid_args, bufText(&buf, "Property '{s}' has type '{s}', not '{s}'", .{ prop_name, p.signature, vs }));
    }
    try p.set.?(ctx, &d);
    return r.reply(.{});
}

fn introspect(c: *Connection, r: *Request) !void {
    const node = c.lookup(r.path);
    var children: object.ChildList = .{ .gpa = c.gpa };
    defer children.deinit();
    var it = c.objects.iterator();
    while (it.next()) |e| {
        const p = e.key_ptr.*;
        if (p.len <= r.path.len or !names.pathInNamespace(p, r.path)) continue;
        const rest = p[r.path.len + @intFromBool(r.path.len > 1) ..];
        try children.add(rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len]);
    }
    const owner = if (c.objects.get(r.path)) |o| (if (o.subtree != null) o else null) else c.subtreeAbove(r.path);
    if (owner) |o| if (o.subtree.?.children) |f| try f(o, r.path, &children);
    if (node == null and children.ends.items.len == 0 and r.path.len > 1) {
        var buf: [512]u8 = undefined;
        return r.replyError(errors.unknown_object, bufText(&buf, "No such object path '{s}'", .{r.path}));
    }
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(c.gpa);
    try object.introspect(c.gpa, &xml, node, &children);
    return r.reply(.{xml.items});
}

fn machineId(c: *Connection) ?[32]u8 {
    if (c.machine_id) |id| return id;
    for ([_][*:0]const u8{ "/etc/machine-id", "/var/lib/dbus/machine-id" }) |path| {
        const rc = linux.open(path, .{ .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) continue;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var buf: [33]u8 = undefined;
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n < 32) continue;
        c.machine_id = buf[0..32].*;
        return c.machine_id;
    }
    return null;
}
