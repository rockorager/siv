//! The public D-Bus API (D19): siv_dbus_* over the internal `dbus`
//! module on the application's loop. The session bus is the application's
//! own connection (portals, accessibility, settings), shared by every
//! handle to it; the system bus, addresses, and sockets get connections of
//! their own. Every application callback runs at a safe point in the
//! dispatch phase, inside enter/leave, so destroy-notifies and teardown
//! called from them are deferred like everywhere else (D2, D5).
//!
//! Each kind of object has a slot list in `State`; a handle's payload is
//! its index. Readers exist only during the callback they are passed to.
//! Objects made on a connection go with it.

const std = @import("std");
const linux = std.os.linux;
const t = @import("siv");
const dbus = @import("dbus");
const loop_mod = @import("loop");
const api = @import("api.zig");
const runtime = @import("runtime.zig");
const application = @import("application.zig");

const App = application.App;
const Error = application.Error;
const Root = runtime.Root;
const Connection = dbus.Connection;
const Encoder = dbus.Encoder;
const Decoder = dbus.Decoder;

const dbus_tag = api.spec.handleTag("siv_dbus");
const message_tag = api.spec.handleTag("siv_dbus_message");
const reader_tag = api.spec.handleTag("siv_dbus_reader");
const subscription_tag = api.spec.handleTag("siv_dbus_subscription");
const name_tag = api.spec.handleTag("siv_dbus_name");
const watch_tag = api.spec.handleTag("siv_dbus_name_watch");
const object_tag = api.spec.handleTag("siv_dbus_object");
const invocation_tag = api.spec.handleTag("siv_dbus_invocation");

const max_depth = 64;

pub const State = struct {
    conns: std.ArrayList(?*Conn) = .empty,
    messages: std.ArrayList(?*Message) = .empty,
    readers: std.ArrayList(?*Reader) = .empty,
    subs: std.ArrayList(?*Sub) = .empty,
    names: std.ArrayList(?*NameReq) = .empty,
    watches: std.ArrayList(?*Watch) = .empty,
    objects: std.ArrayList(?*Obj) = .empty,
    invocations: std.ArrayList(?*Invocation) = .empty,
    /// Calls waiting for a reply; no handles.
    calls: std.ArrayList(?*Call) = .empty,
    /// Owned connections closed from one of their own callbacks, freed by
    /// their task.
    dying: std.ArrayList(*Conn) = .empty,
};

// Slots ------------------------------------------------------------------------

/// Gives `item` a slot in `list` and a handle with `tag`.
fn register(self: *App, comptime T: type, list: *std.ArrayList(?*T), item: *T, tag: u8) Error!void {
    const gpa = self.gpa();
    const index: u32 = for (list.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        try list.append(gpa, null);
        break :blk @intCast(list.items.len - 1);
    };
    try self.root.handles.ensureUnusedCapacity(gpa);
    item.index = index;
    item.handle = self.root.handles.insert(gpa, tag, index) catch unreachable;
    list.items[index] = item;
}

fn unregister(self: *App, comptime T: type, list: *std.ArrayList(?*T), item: *T, tag: u8) void {
    _ = self.root.handles.remove(item.handle, tag) catch unreachable;
    list.items[item.index] = null;
}

fn lookup(comptime T: type, comptime field: []const u8, handle: u64, tag: u8) Error!*T {
    const self, const index = try Root.owner(App, application.app_tag, handle, tag);
    const list = &@field(self.dbus, field);
    if (index >= list.items.len) return error.InvalidHandle;
    return list.items[index] orelse error.InvalidHandle;
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Disconnected, error.ConnectFailed, error.NoBus, error.FdsNotSupported => error.Unavailable,
        error.ObjectExists => error.Busy,
        error.Unsupported => error.Unsupported,
        error.InvalidHandle => error.InvalidHandle,
        else => error.InvalidArgument,
    };
}

fn copyOut(s: []const u8, buffer: ?[*]u8, cap: usize, len: ?*usize) Error!void {
    const buf = try runtime.buffer(buffer, cap);
    const dest = try runtime.out(usize, len);
    const k = @min(s.len, buf.len);
    @memcpy(buf[0..k], s[0..k]);
    dest.* = s.len;
}

/// A call failed after it was handed user_data: release it (D2).
fn failed(self: *App, destroy: ?t.DestroyFn, user_data: ?*anyopaque, err: anyerror) t.Result {
    self.release(destroy, user_data);
    return t.resultOf(mapError(err));
}

// Connections --------------------------------------------------------------------

const Conn = struct {
    self: *App,
    index: u32 = 0,
    handle: u64 = 0,
    bus: *Connection,
    /// The connection is this handle's own (not the session bus).
    owned: bool,
    storage: Connection = undefined,
    task: loop_mod.Loop.Task = .{ .func = freeLater },

    fn freeLater(task: *loop_mod.Loop.Task) void {
        const c: *Conn = @fieldParentPtr("task", task);
        const st = &c.self.dbus;
        for (st.dying.items, 0..) |d, i| if (d == c) {
            _ = st.dying.swapRemove(i);
            break;
        };
        c.free();
    }

    fn free(c: *Conn) void {
        if (c.owned) c.storage.deinit();
        c.self.gpa().destroy(c);
    }
};

/// Drops everything made on `c`, then the connection.
fn disconnect(c: *Conn) void {
    const self = c.self;
    const st = &self.dbus;
    for (st.calls.items) |slot| if (slot) |x| if (x.conn == c) x.forget();
    for (st.subs.items) |slot| if (slot) |x| if (x.conn == c) x.remove();
    for (st.names.items) |slot| if (slot) |x| if (x.conn == c) x.remove();
    for (st.watches.items) |slot| if (slot) |x| if (x.conn == c) x.remove();
    for (st.objects.items) |slot| if (slot) |x| if (x.conn == c) x.remove();
    for (st.invocations.items) |slot| if (slot) |x| if (x.obj.conn == c) x.answerGone();
    for (st.messages.items) |slot| if (slot) |x| if (x.conn == c and x.kind != .property) x.remove();
    unregister(self, Conn, &st.conns, c, dbus_tag);
    if (c.owned and c.storage.dispatching) {
        // Connection.deinit must not run inside its own dispatch.
        st.dying.append(self.gpa(), c) catch {
            c.storage.flush();
            return; // leaks the connection rather than freeing it in use
        };
        self.app.loop.schedule(&c.task, .dispatch);
        return;
    }
    c.free();
}

/// The application is going: everything goes, without callbacks.
pub fn teardown(self: *App) void {
    const st = &self.dbus;
    for (st.conns.items) |slot| if (slot) |c| disconnect(c);
    for (st.dying.items) |c| {
        self.app.loop.unschedule(&c.task);
        c.free();
    }
    const gpa = self.gpa();
    st.conns.deinit(gpa);
    st.messages.deinit(gpa);
    st.readers.deinit(gpa);
    st.subs.deinit(gpa);
    st.names.deinit(gpa);
    st.watches.deinit(gpa);
    st.objects.deinit(gpa);
    st.invocations.deinit(gpa);
    st.calls.deinit(gpa);
    st.dying.deinit(gpa);
    st.* = .{};
}

pub export fn siv_dbus_connect(app: t.App, desc: ?*const t.DbusDesc, out: ?*t.Dbus) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, dp: ?*const t.DbusDesc, o: ?*t.Dbus) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.DbusDesc, dp);
            const dest = try runtime.out(t.Dbus, o);
            const bus = try runtime.enumValue(t.DbusBus, d.bus);
            const address = try runtime.string(d.address, d.address_len);
            const gpa = self.gpa();
            const c = try gpa.create(Conn);
            errdefer gpa.destroy(c);
            c.* = .{ .self = self, .bus = undefined, .owned = bus != .session };
            const options: Connection.Options = .{};
            switch (bus) {
                .session => {
                    if (!self.app.desktop.connected) return error.Unavailable;
                    c.bus = &self.app.desktop.bus;
                },
                .system => c.storage.init(gpa, &self.app.loop, dbus.address.system(), options) catch |err| return mapError(err),
                .address => {
                    if (address.len == 0) return error.InvalidArgument;
                    c.storage.init(gpa, &self.app.loop, address, options) catch |err| return mapError(err);
                },
                .fd => {
                    if (d.fd < 0) return error.InvalidArgument;
                    c.storage.initFd(gpa, &self.app.loop, d.fd, options) catch |err| return mapError(err);
                },
                _ => unreachable,
            }
            if (c.owned) c.bus = &c.storage;
            errdefer if (c.owned) c.storage.deinit();
            try register(self, Conn, &self.dbus.conns, c, dbus_tag);
            dest.* = @fromBackingInt(c.handle);
        }
    }.f(app, desc, out));
}

pub export fn siv_dbus_disconnect(handle: t.Dbus) void {
    const c = lookup(Conn, "conns", @backingInt(handle), dbus_tag) catch return;
    disconnect(c);
}

pub export fn siv_dbus_get_unique_name(handle: t.Dbus, buffer: ?[*]u8, cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.Dbus, b: ?[*]u8, n: usize, l: ?*usize) Error!void {
            const c = try lookup(Conn, "conns", @backingInt(h), dbus_tag);
            try copyOut(c.bus.uniqueName(), b, n, l);
        }
    }.f(handle, buffer, cap, len));
}

// Writing messages -------------------------------------------------------------------

const Message = struct {
    self: *App,
    index: u32 = 0,
    handle: u64 = 0,
    conn: *Conn,
    kind: enum { call, signal, reply, property },
    builder: dbus.Builder = undefined,
    /// The builder's body, or a property's value being written.
    enc: *Encoder = undefined,
    /// The header's strings, which the builder borrows.
    text: []u8 = &.{},
    /// For replies.
    invocation: ?*Invocation = null,
    err: ?Error = null,
    open: [max_depth]u8 = undefined,
    depth: u8 = 0,

    fn fail(m: *Message, err: anyerror) void {
        if (m.err == null) m.err = mapError(err);
    }

    /// Unregisters and frees the message without sending it.
    fn remove(m: *Message) void {
        const self = m.self;
        unregister(self, Message, &self.dbus.messages, m, message_tag);
        if (m.kind != .property) {
            m.builder.deinit();
            self.gpa().free(m.text);
            self.gpa().destroy(m);
        }
    }
};

fn messageOf(h: t.DbusMessage) Error!*Message {
    return lookup(Message, "messages", @backingInt(h), message_tag);
}

/// A new message on `c` with a builder made by `header`; header strings
/// are copied into the message.
fn newMessage(c: *Conn, kind: anytype, header: dbus.message.Header, secret: bool) Error!*Message {
    const self = c.self;
    const gpa = self.gpa();
    var h = header;
    var total: usize = 0;
    inline for (.{ "destination", "path", "interface", "member", "error_name" }) |f| {
        if (@field(h, f)) |s| total += s.len;
    }
    const text = try gpa.alloc(u8, total);
    errdefer gpa.free(text);
    var at: usize = 0;
    inline for (.{ "destination", "path", "interface", "member", "error_name" }) |f| {
        if (@field(h, f)) |s| {
            @memcpy(text[at..][0..s.len], s);
            @field(h, f) = text[at..][0..s.len];
            at += s.len;
        }
    }
    h.validate() catch return error.InvalidArgument;
    const m = try gpa.create(Message);
    errdefer gpa.destroy(m);
    m.* = .{ .self = self, .conn = c, .kind = kind, .text = text };
    m.builder = if (secret) c.bus.newSecretBuilder(h) else c.bus.newBuilder(h);
    m.enc = &m.builder.body;
    errdefer m.builder.deinit();
    try register(self, Message, &self.dbus.messages, m, message_tag);
    return m;
}

fn optString(ptr: ?[*]const u8, len: usize) Error!?[]const u8 {
    const s = try runtime.string(ptr, len);
    return if (s.len == 0) null else s;
}

pub export fn siv_dbus_new_call(handle: t.Dbus, desc: ?*const t.DbusMessageDesc, out: ?*t.DbusMessage) t.Result {
    return application.wrap(struct {
        fn f(h: t.Dbus, dp: ?*const t.DbusMessageDesc, o: ?*t.DbusMessage) Error!void {
            const c = try lookup(Conn, "conns", @backingInt(h), dbus_tag);
            const d = try runtime.readDesc(t.DbusMessageDesc, dp);
            const dest = try runtime.out(t.DbusMessage, o);
            const fl = try runtime.flags(t.DbusMessageFlags, d.flags);
            const path = (try optString(d.path, d.path_len)) orelse return error.InvalidArgument;
            const member = (try optString(d.member, d.member_len)) orelse return error.InvalidArgument;
            const destination = try optString(d.destination, d.destination_len);
            if (destination == null and c.bus.options.bus) return error.InvalidArgument;
            const m = try newMessage(c, .call, .{
                .type = .method_call,
                .destination = destination,
                .path = path,
                .interface = try optString(d.interface, d.interface_len),
                .member = member,
                .flags = .{
                    .no_reply_expected = fl.no_reply,
                    .no_auto_start = fl.no_auto_start,
                    .allow_interactive_authorization = fl.interactive,
                },
            }, fl.secret);
            dest.* = @fromBackingInt(m.handle);
        }
    }.f(handle, desc, out));
}

pub export fn siv_dbus_new_signal(handle: t.Dbus, desc: ?*const t.DbusMessageDesc, out: ?*t.DbusMessage) t.Result {
    return application.wrap(struct {
        fn f(h: t.Dbus, dp: ?*const t.DbusMessageDesc, o: ?*t.DbusMessage) Error!void {
            const c = try lookup(Conn, "conns", @backingInt(h), dbus_tag);
            const d = try runtime.readDesc(t.DbusMessageDesc, dp);
            const dest = try runtime.out(t.DbusMessage, o);
            if (@as(u32, @bitCast(d.flags)) != 0) return error.InvalidArgument;
            const m = try newMessage(c, .signal, .{
                .type = .signal,
                .destination = try optString(d.destination, d.destination_len),
                .path = (try optString(d.path, d.path_len)) orelse return error.InvalidArgument,
                .interface = (try optString(d.interface, d.interface_len)) orelse return error.InvalidArgument,
                .member = (try optString(d.member, d.member_len)) orelse return error.InvalidArgument,
            }, false);
            dest.* = @fromBackingInt(m.handle);
        }
    }.f(handle, desc, out));
}

pub export fn siv_dbus_invocation_new_reply(invocation: t.DbusInvocation, out: ?*t.DbusMessage) t.Result {
    return application.wrap(struct {
        fn f(h: t.DbusInvocation, o: ?*t.DbusMessage) Error!void {
            const inv = try invocationOf(h);
            const dest = try runtime.out(t.DbusMessage, o);
            const d = &inv.deferred;
            const m = try newMessage(inv.obj.conn, .reply, .{
                .type = .method_return,
                .destination = if (d.has_sender) d.sender.slice() else null,
                .reply_serial = d.serial,
            }, false);
            m.invocation = inv;
            dest.* = @fromBackingInt(m.handle);
        }
    }.f(invocation, out));
}

pub export fn siv_dbus_message_destroy(message: t.DbusMessage) void {
    const m = messageOf(message) catch return;
    if (m.kind == .property) return;
    m.remove();
}

/// The message to write to, or null if it failed already.
fn writable(message: t.DbusMessage) ?*Message {
    const m = messageOf(message) catch return null;
    return if (m.err == null) m else null;
}

fn writeInt(e: *Encoder, ty: u8, v: i64) !void {
    switch (ty) {
        'y' => try e.writeByte(std.math.cast(u8, v) orelse return error.InvalidArgument),
        'b' => try e.writeBool(switch (v) {
            0 => false,
            1 => true,
            else => return error.InvalidArgument,
        }),
        'n' => try e.writeInt16(std.math.cast(i16, v) orelse return error.InvalidArgument),
        'q' => try e.writeUint16(std.math.cast(u16, v) orelse return error.InvalidArgument),
        'i' => try e.writeInt32(std.math.cast(i32, v) orelse return error.InvalidArgument),
        'u' => try e.writeUint32(std.math.cast(u32, v) orelse return error.InvalidArgument),
        'x' => try e.writeInt64(v),
        't' => try e.writeUint64(@bitCast(v)),
        'h' => try e.writeFd(std.math.cast(i32, v) orelse return error.InvalidArgument),
        else => return error.InvalidArgument,
    }
}

pub export fn siv_dbus_message_write_int(message: t.DbusMessage, ty: u8, v: i64) void {
    const m = writable(message) orelse return;
    writeInt(m.enc, ty, v) catch |err| m.fail(err);
}

pub export fn siv_dbus_message_write_double(message: t.DbusMessage, v: f64) void {
    const m = writable(message) orelse return;
    m.enc.writeDouble(v) catch |err| m.fail(err);
}

pub export fn siv_dbus_message_write_string(message: t.DbusMessage, ty: u8, ptr: ?[*]const u8, len: usize) void {
    const m = writable(message) orelse return;
    const s = runtime.string(ptr, len) catch |err| return m.fail(err);
    const r = switch (ty) {
        's' => m.enc.writeString(s),
        'o' => m.enc.writeObjectPath(s),
        'g' => m.enc.writeSignature(s),
        else => return m.fail(error.InvalidArgument),
    };
    r catch |err| m.fail(err);
}

pub export fn siv_dbus_message_write_open(message: t.DbusMessage, ty: u8, ptr: ?[*]const u8, len: usize) void {
    const m = writable(message) orelse return;
    const s = runtime.string(ptr, len) catch |err| return m.fail(err);
    if (m.depth == max_depth) return m.fail(error.InvalidArgument);
    const r = switch (ty) {
        'a' => m.enc.beginArray(s),
        'v' => m.enc.beginVariant(s),
        'r' => if (s.len == 0) m.enc.beginStruct() else error.InvalidArgument,
        'e' => if (s.len == 0) m.enc.beginDictEntry() else error.InvalidArgument,
        else => error.InvalidArgument,
    };
    r catch |err| return m.fail(err);
    m.open[m.depth] = ty;
    m.depth += 1;
}

pub export fn siv_dbus_message_write_close(message: t.DbusMessage) void {
    const m = writable(message) orelse return;
    if (m.depth == 0) return m.fail(error.InvalidArgument);
    m.depth -= 1;
    const r = switch (m.open[m.depth]) {
        'a' => m.enc.endArray(),
        'v' => m.enc.endVariant(),
        'r' => m.enc.endStruct(),
        'e' => m.enc.endDictEntry(),
        else => unreachable,
    };
    r catch |err| m.fail(err);
}

pub export fn siv_dbus_message_status(message: t.DbusMessage) t.Result {
    const m = messageOf(message) catch |err| return t.resultOf(err);
    if (m.err) |e| return t.resultOf(e);
    return .ok;
}

/// The message is complete and sendable.
fn finished(m: *Message) Error!void {
    if (m.err) |e| return e;
    if (m.depth != 0 or !m.enc.complete()) return error.InvalidArgument;
}

const Call = struct {
    self: *App,
    index: u32 = 0,
    conn: *Conn,
    serial: u32 = 0,
    callback: t.DbusMessageFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn onReply(ctx: ?*anyopaque, reply: Connection.Reply) void {
        const x: *Call = @ptrCast(@alignCast(ctx));
        const self = x.self;
        const cb = x.callback;
        const ud = x.user_data;
        const destroy = x.destroy;
        x.drop();
        self.enter();
        switch (reply) {
            .ok => |m| deliver(self, cb, ud, m, .method_return),
            .err => |m| deliver(self, cb, ud, m, .@"error"),
            .failed => |err| {
                var info = emptyInfo();
                info.type = .failed;
                const name = if (err == error.Timeout) Connection.errors.no_reply else Connection.errors.failed;
                const disconnected = "org.freedesktop.DBus.Error.Disconnected";
                setStr(&info, "error_name", if (err == error.Disconnected) disconnected else name);
                withReader(self, Decoder.init(&.{}, "", .little, &.{}), struct {
                    fn run(c: t.DbusMessageFn, u: ?*anyopaque, i: *const t.DbusMessageInfo, r: t.DbusReader) void {
                        c(u, i, r);
                    }
                }.run, .{ cb, ud, &info });
            },
        }
        self.release(destroy, ud);
        self.leave();
    }

    /// Frees the record; the destroy-notify is the caller's.
    fn drop(x: *Call) void {
        const self = x.self;
        self.dbus.calls.items[x.index] = null;
        self.gpa().destroy(x);
    }

    /// The connection is going: the callback never runs.
    fn forget(x: *Call) void {
        const self = x.self;
        x.conn.bus.cancelCall(x.serial);
        self.release(x.destroy, x.user_data);
        x.drop();
    }
};

pub export fn siv_dbus_message_call(message: t.DbusMessage, timeout_ms: i32, callback: ?t.DbusMessageFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const m = messageOf(message) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    const self = m.self;
    if (m.kind == .property) return failed(self, destroy, user_data, error.InvalidArgument);
    defer m.remove();
    const cb = callback orelse return failed(self, destroy, user_data, error.InvalidArgument);
    if (m.kind != .call or m.builder.header.flags.no_reply_expected) return failed(self, destroy, user_data, error.InvalidArgument);
    if (timeout_ms < -1) return failed(self, destroy, user_data, error.InvalidArgument);
    finished(m) catch |err| return failed(self, destroy, user_data, err);
    const gpa = self.gpa();
    const x = gpa.create(Call) catch |err| return failed(self, destroy, user_data, err);
    x.* = .{ .self = self, .conn = m.conn, .callback = cb, .destroy = destroy, .user_data = user_data };
    const st = &self.dbus;
    x.index = for (st.calls.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        st.calls.append(gpa, null) catch |err| {
            gpa.destroy(x);
            return failed(self, destroy, user_data, err);
        };
        break :blk @intCast(st.calls.items.len - 1);
    };
    const timeout: ?u32 = switch (timeout_ms) {
        -1 => null,
        0 => Connection.default_timeout_ms,
        else => @intCast(timeout_ms),
    };
    x.serial = m.conn.bus.call(&m.builder, Call.onReply, x, .{ .timeout_ms = timeout }) catch |err| {
        m.builder = dbus.Builder.init(gpa, .{ .type = .method_call }); // consumed
        gpa.destroy(x);
        return failed(self, destroy, user_data, err);
    };
    m.builder = dbus.Builder.init(gpa, .{ .type = .method_call }); // consumed
    st.calls.items[x.index] = x;
    return .ok;
}

pub export fn siv_dbus_message_send(message: t.DbusMessage) t.Result {
    const m = messageOf(message) catch |err| return t.resultOf(err);
    if (m.kind == .property) return .error_invalid_argument;
    defer m.remove();
    return application.wrap(send(m));
}

fn send(m: *Message) Error!void {
    try finished(m);
    const gpa = m.self.gpa();
    defer m.builder = dbus.Builder.init(gpa, .{ .type = .method_call }); // consumed
    if (m.kind == .reply) {
        // Null once the invocation was answered another way.
        const inv = m.invocation orelse return error.InvalidHandle;
        const declared = inv.method.out;
        if (!std.mem.eql(u8, m.enc.signature(), declared)) {
            var buf: [512]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{s} replied with signature '{s}', declared '{s}'", .{ inv.member(), m.enc.signature(), declared }) catch "the reply has the wrong signature";
            inv.answerError(Connection.errors.failed, text);
            m.builder.deinit();
            return error.InvalidArgument;
        }
        defer inv.remove();
        inv.deferred.send(m.conn.bus, &m.builder) catch |err| return mapError(err);
        return;
    }
    _ = m.conn.bus.send(&m.builder) catch |err| return mapError(err);
}

// Reading messages -----------------------------------------------------------------

const Reader = struct {
    self: *App,
    index: u32 = 0,
    handle: u64 = 0,
    d: Decoder,
    open: [max_depth]Frame = undefined,
    depth: u8 = 0,

    const Frame = union(enum) {
        array: Decoder.Array,
        @"struct",
        dict_entry,
        variant,
    };
};

fn emptyInfo() t.DbusMessageInfo {
    var info = std.mem.zeroes(t.DbusMessageInfo);
    info.size = @sizeOf(t.DbusMessageInfo);
    return info;
}

fn setStr(info: *t.DbusMessageInfo, comptime field: []const u8, s: []const u8) void {
    @field(info, field) = s.ptr;
    @field(info, field ++ "_len") = s.len;
}

fn infoOf(m: *const dbus.Message, ty: t.DbusMessageType) t.DbusMessageInfo {
    var info = emptyInfo();
    inline for (.{ "sender", "path", "interface", "member", "error_name" }) |f| {
        setStr(&info, f, @field(m, f) orelse "");
    }
    setStr(&info, "signature", m.signature);
    info.type = ty;
    info.serial = m.serial;
    return info;
}

/// Calls `func(args..., reader)` with a reader over `d`, valid during the
/// call. Without memory for its slot the reader is the null handle, which
/// every read refuses.
fn withReader(self: *App, d: Decoder, comptime func: anytype, args: anytype) void {
    var r: Reader = .{ .self = self, .d = d };
    const registered = if (register(self, Reader, &self.dbus.readers, &r, reader_tag)) true else |_| false;
    defer if (registered) unregister(self, Reader, &self.dbus.readers, &r, reader_tag);
    const handle: t.DbusReader = if (registered) @fromBackingInt(r.handle) else .null;
    @call(.auto, func, args ++ .{handle});
}

fn deliver(self: *App, cb: t.DbusMessageFn, ud: ?*anyopaque, m: *const dbus.Message, ty: t.DbusMessageType) void {
    const info = infoOf(m, ty);
    withReader(self, m.body(), struct {
        fn run(c: t.DbusMessageFn, u: ?*anyopaque, i: *const t.DbusMessageInfo, r: t.DbusReader) void {
            c(u, i, r);
        }
    }.run, .{ cb, ud, &info });
}

fn readerOf(h: t.DbusReader) Error!*Reader {
    return lookup(Reader, "readers", @backingInt(h), reader_tag);
}

/// The next value's type code; 0 at the end of the arguments or of the
/// container entered last.
fn nextType(r: *Reader) u8 {
    const c = r.d.peek() orelse return 0;
    return if (c == ')' or c == '}') 0 else c;
}

pub export fn siv_dbus_reader_read_type(reader: t.DbusReader, ty: ?*u8) t.Result {
    const r = readerOf(reader) catch |err| return t.resultOf(err);
    const dest = runtime.out(u8, ty) catch |err| return t.resultOf(err);
    dest.* = nextType(r);
    return .ok;
}

pub export fn siv_dbus_reader_read_signature(reader: t.DbusReader, buffer: ?[*]u8, cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.DbusReader, b: ?[*]u8, n: usize, l: ?*usize) Error!void {
            const r = try readerOf(h);
            if (nextType(r) == 0) return copyOut("", b, n, l);
            const c = &r.d.stack[r.d.depth];
            // At the start of another array element the cursor is at the
            // end of the element's signature.
            const rest = if (c.pos == c.sig.len) c.sig else c.sig[c.pos..];
            try copyOut(rest[0..dbus.signature.skipLen(rest)], b, n, l);
        }
    }.f(reader, buffer, cap, len));
}

fn readInt(d: *Decoder, ty: u8) !i64 {
    return switch (ty) {
        'y' => try d.readByte(),
        'b' => @intFromBool(try d.readBool()),
        'n' => try d.readInt16(),
        'q' => try d.readUint16(),
        'i' => try d.readInt32(),
        'u' => try d.readUint32(),
        'x' => try d.readInt64(),
        't' => @bitCast(try d.readUint64()),
        'h' => try d.readFd(),
        else => error.InvalidArgument,
    };
}

pub export fn siv_dbus_reader_read_int(reader: t.DbusReader, value: ?*i64) t.Result {
    return application.wrap(struct {
        fn f(h: t.DbusReader, o: ?*i64) Error!void {
            const r = try readerOf(h);
            const dest = try runtime.out(i64, o);
            const v: i64 = readInt(&r.d, nextType(r)) catch return error.InvalidArgument;
            dest.* = v;
        }
    }.f(reader, value));
}

pub export fn siv_dbus_reader_read_double(reader: t.DbusReader, value: ?*f64) t.Result {
    return application.wrap(struct {
        fn f(h: t.DbusReader, o: ?*f64) Error!void {
            const r = try readerOf(h);
            const dest = try runtime.out(f64, o);
            if (nextType(r) != 'd') return error.InvalidArgument;
            dest.* = r.d.readDouble() catch return error.InvalidArgument;
        }
    }.f(reader, value));
}

pub export fn siv_dbus_reader_read_string(reader: t.DbusReader, buffer: ?[*]u8, cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.DbusReader, b: ?[*]u8, n: usize, l: ?*usize) Error!void {
            const r = try readerOf(h);
            const buf = try runtime.buffer(b, n);
            const dest = try runtime.out(usize, l);
            var d = r.d;
            const s = switch (nextType(r)) {
                's' => d.readString(),
                'o' => d.readObjectPath(),
                'g' => d.readSignature(),
                else => return error.InvalidArgument,
            } catch return error.InvalidArgument;
            dest.* = s.len;
            // Too small: nothing is read, so the caller can ask again.
            if (s.len > buf.len) return;
            @memcpy(buf[0..s.len], s);
            r.d = d;
        }
    }.f(reader, buffer, cap, len));
}

pub export fn siv_dbus_reader_read_enter(reader: t.DbusReader) t.Result {
    return application.wrap(struct {
        fn f(h: t.DbusReader) Error!void {
            const r = try readerOf(h);
            if (r.depth == max_depth) return error.InvalidArgument;
            const d = &r.d;
            const frame: Reader.Frame = switch (nextType(r)) {
                'a' => .{ .array = d.beginArray() catch return error.InvalidArgument },
                '(' => blk: {
                    d.beginStruct() catch return error.InvalidArgument;
                    break :blk .@"struct";
                },
                '{' => blk: {
                    d.beginDictEntry() catch return error.InvalidArgument;
                    break :blk .dict_entry;
                },
                'v' => blk: {
                    _ = d.beginVariant() catch return error.InvalidArgument;
                    break :blk .variant;
                },
                else => return error.InvalidArgument,
            };
            r.open[r.depth] = frame;
            r.depth += 1;
        }
    }.f(reader));
}

pub export fn siv_dbus_reader_read_exit(reader: t.DbusReader) t.Result {
    return application.wrap(struct {
        fn f(h: t.DbusReader) Error!void {
            const r = try readerOf(h);
            if (r.depth == 0) return error.InvalidArgument;
            const d = &r.d;
            switch (r.open[r.depth - 1]) {
                .array => |a| d.endArray(a) catch return error.InvalidArgument,
                .@"struct" => {
                    while (nextType(r) != 0) d.skip() catch return error.InvalidArgument;
                    d.endStruct() catch return error.InvalidArgument;
                },
                .dict_entry => {
                    while (nextType(r) != 0) d.skip() catch return error.InvalidArgument;
                    d.endDictEntry() catch return error.InvalidArgument;
                },
                .variant => d.endVariant() catch return error.InvalidArgument,
            }
            r.depth -= 1;
        }
    }.f(reader));
}

pub export fn siv_dbus_reader_read_skip(reader: t.DbusReader) t.Result {
    return application.wrap(struct {
        fn f(h: t.DbusReader) Error!void {
            const r = try readerOf(h);
            if (nextType(r) == 0) return error.InvalidArgument;
            r.d.skip() catch return error.InvalidArgument;
        }
    }.f(reader));
}

// Subscriptions ------------------------------------------------------------------

const Sub = struct {
    self: *App,
    index: u32 = 0,
    handle: u64 = 0,
    conn: *Conn,
    sub: Connection.Subscription,
    arg: dbus.match.Arg = undefined,
    text: []u8,
    callback: t.DbusMessageFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn onSignal(s: *Connection.Subscription, m: *const dbus.Message) void {
        const x: *Sub = @fieldParentPtr("sub", s);
        const self = x.self;
        self.enter();
        deliver(self, x.callback, x.user_data, m, .signal);
        self.leave();
    }

    fn remove(x: *Sub) void {
        const self = x.self;
        x.conn.bus.unsubscribe(&x.sub);
        unregister(self, Sub, &self.dbus.subs, x, subscription_tag);
        self.release(x.destroy, x.user_data);
        self.gpa().free(x.text);
        self.gpa().destroy(x);
    }
};

pub export fn siv_dbus_subscribe(handle: t.Dbus, match: ?*const t.DbusMatch, callback: ?t.DbusMessageFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, out: ?*t.DbusSubscription) t.Result {
    const c = lookup(Conn, "conns", @backingInt(handle), dbus_tag) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    const self = c.self;
    subscribe(c, match, callback, destroy, user_data, out) catch |err| return failed(self, destroy, user_data, err);
    return .ok;
}

fn subscribe(c: *Conn, mp: ?*const t.DbusMatch, callback: ?t.DbusMessageFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, out: ?*t.DbusSubscription) !void {
    const self = c.self;
    const gpa = self.gpa();
    const cb = callback orelse return error.InvalidArgument;
    const mt = try runtime.readDesc(t.DbusMatch, mp);
    const dest = try runtime.out(t.DbusSubscription, out);
    const fields = .{ "sender", "path", "path_namespace", "interface", "member", "arg0" };
    var total: usize = 0;
    inline for (fields) |f| total += (try runtime.string(@field(mt, f), @field(mt, f ++ "_len"))).len;
    const text = try gpa.alloc(u8, total);
    errdefer gpa.free(text);
    var copies: [fields.len]?[]const u8 = undefined;
    var at: usize = 0;
    inline for (fields, 0..) |f, i| {
        const s = try runtime.string(@field(mt, f), @field(mt, f ++ "_len"));
        @memcpy(text[at..][0..s.len], s);
        copies[i] = if (s.len == 0) null else text[at..][0..s.len];
        at += s.len;
    }
    const x = try gpa.create(Sub);
    errdefer gpa.destroy(x);
    x.* = .{
        .self = self,
        .conn = c,
        .sub = .{
            .rule = .{ .sender = copies[0], .path = copies[1], .path_namespace = copies[2], .interface = copies[3], .member = copies[4] },
            .func = Sub.onSignal,
        },
        .text = text,
        .callback = cb,
        .destroy = destroy,
        .user_data = user_data,
    };
    if (copies[5]) |a| {
        x.arg = .{ .index = 0, .value = a };
        x.sub.rule.args = (&x.arg)[0..1];
    }
    try register(self, Sub, &self.dbus.subs, x, subscription_tag);
    errdefer unregister(self, Sub, &self.dbus.subs, x, subscription_tag);
    try c.bus.subscribe(&x.sub);
    dest.* = @fromBackingInt(x.handle);
}

pub export fn siv_dbus_subscription_destroy(subscription: t.DbusSubscription) void {
    const x = lookup(Sub, "subs", @backingInt(subscription), subscription_tag) catch return;
    x.remove();
}

// Names --------------------------------------------------------------------------

const NameReq = struct {
    self: *App,
    index: u32 = 0,
    handle: u64 = 0,
    conn: *Conn,
    owner: Connection.NameOwner,
    name: Connection.Name = .{},
    callback: ?t.DbusNameFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn onState(o: *Connection.NameOwner) void {
        const x: *NameReq = @fieldParentPtr("owner", o);
        const cb = x.callback orelse return;
        const state: t.DbusNameState = switch (o.state) {
            .idle, .requesting => return,
            .primary => .primary,
            .queued => .queued,
            .exists => .exists,
            .lost => .lost,
            .failed => .failed,
        };
        const self = x.self;
        self.enter();
        cb(x.user_data, @fromBackingInt(x.handle), state);
        self.leave();
    }

    fn remove(x: *NameReq) void {
        const self = x.self;
        x.conn.bus.releaseName(&x.owner);
        unregister(self, NameReq, &self.dbus.names, x, name_tag);
        self.release(x.destroy, x.user_data);
        self.gpa().destroy(x);
    }
};

fn startName(c: *Conn, name: []const u8, fl: t.DbusNameFlags, callback: ?t.DbusNameFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, out: ?*t.DbusName) !void {
    const self = c.self;
    const gpa = self.gpa();
    const f = try runtime.flags(t.DbusNameFlags, fl);
    const dest = try runtime.out(t.DbusName, out);
    if (name.len == 0 or name.len > dbus.names.max_name_len) return error.InvalidArgument;
    const x = try gpa.create(NameReq);
    errdefer gpa.destroy(x);
    x.* = .{ .self = self, .conn = c, .owner = undefined, .callback = callback, .destroy = destroy, .user_data = user_data };
    x.name.set(name);
    x.owner = .{
        .name = x.name.slice(),
        .flags = .{ .allow_replacement = f.allow_replacement, .replace_existing = f.replace_existing, .do_not_queue = f.do_not_queue },
        .func = NameReq.onState,
    };
    try register(self, NameReq, &self.dbus.names, x, name_tag);
    errdefer unregister(self, NameReq, &self.dbus.names, x, name_tag);
    try c.bus.requestName(&x.owner);
    dest.* = @fromBackingInt(x.handle);
}

pub export fn siv_dbus_own_name(handle: t.Dbus, name: ?[*]const u8, name_len: usize, fl: t.DbusNameFlags, callback: ?t.DbusNameFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, out: ?*t.DbusName) t.Result {
    const c = lookup(Conn, "conns", @backingInt(handle), dbus_tag) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    const s = runtime.string(name, name_len) catch |err| return failed(c.self, destroy, user_data, err);
    startName(c, s, fl, callback, destroy, user_data, out) catch |err| return failed(c.self, destroy, user_data, err);
    return .ok;
}

pub export fn siv_dbus_name_release(request: t.DbusName) void {
    const x = lookup(NameReq, "names", @backingInt(request), name_tag) catch return;
    x.remove();
}

const Watch = struct {
    self: *App,
    index: u32 = 0,
    handle: u64 = 0,
    conn: *Conn,
    watch: Connection.NameWatch,
    name: Connection.Name = .{},
    callback: t.DbusNameWatchFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn onOwner(w: *Connection.NameWatch) void {
        const x: *Watch = @fieldParentPtr("watch", w);
        const owner = w.owner() orelse "";
        const self = x.self;
        self.enter();
        x.callback(x.user_data, @fromBackingInt(x.handle), owner.ptr, owner.len);
        self.leave();
    }

    fn remove(x: *Watch) void {
        const self = x.self;
        x.conn.bus.unwatchName(&x.watch);
        unregister(self, Watch, &self.dbus.watches, x, watch_tag);
        self.release(x.destroy, x.user_data);
        self.gpa().destroy(x);
    }
};

fn startWatch(c: *Conn, name: []const u8, callback: ?t.DbusNameWatchFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, out: ?*t.DbusNameWatch) !void {
    const self = c.self;
    const gpa = self.gpa();
    const cb = callback orelse return error.InvalidArgument;
    const dest = try runtime.out(t.DbusNameWatch, out);
    if (name.len == 0 or name.len > dbus.names.max_name_len) return error.InvalidArgument;
    const x = try gpa.create(Watch);
    errdefer gpa.destroy(x);
    x.* = .{ .self = self, .conn = c, .watch = undefined, .callback = cb, .destroy = destroy, .user_data = user_data };
    x.name.set(name);
    x.watch = .{ .name = x.name.slice(), .func = Watch.onOwner };
    try register(self, Watch, &self.dbus.watches, x, watch_tag);
    errdefer unregister(self, Watch, &self.dbus.watches, x, watch_tag);
    try c.bus.watchName(&x.watch);
    dest.* = @fromBackingInt(x.handle);
}

pub export fn siv_dbus_watch_name(handle: t.Dbus, name: ?[*]const u8, name_len: usize, callback: ?t.DbusNameWatchFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, out: ?*t.DbusNameWatch) t.Result {
    const c = lookup(Conn, "conns", @backingInt(handle), dbus_tag) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    const s = runtime.string(name, name_len) catch |err| return failed(c.self, destroy, user_data, err);
    startWatch(c, s, callback, destroy, user_data, out) catch |err| return failed(c.self, destroy, user_data, err);
    return .ok;
}

pub export fn siv_dbus_name_watch_destroy(watch: t.DbusNameWatch) void {
    const x = lookup(Watch, "watches", @backingInt(watch), watch_tag) catch return;
    x.remove();
}

// Objects ------------------------------------------------------------------------

const Obj = struct {
    self: *App,
    index: u32 = 0,
    handle: u64 = 0,
    conn: *Conn,
    arena: std.heap.ArenaAllocator,
    object: dbus.Object = undefined,
    iface: dbus.Interface = undefined,
    ifaces: [1]*const dbus.Interface = undefined,
    on_call: ?t.DbusMethodCallFn,
    get_property: ?t.DbusGetPropertyFn,
    set_property: ?t.DbusSetPropertyFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn remove(x: *Obj) void {
        const self = x.self;
        for (self.dbus.invocations.items) |slot| if (slot) |inv| if (inv.obj == x) inv.answerGone();
        x.conn.bus.unexportObject(&x.object);
        unregister(self, Obj, &self.dbus.objects, x, object_tag);
        self.release(x.destroy, x.user_data);
        x.arena.deinit();
        self.gpa().destroy(x);
    }

    fn node(x: *Obj) dbus.Node {
        return .{ .ctx = x, .interfaces = &x.ifaces };
    }

    fn onMethod(req: *dbus.Request) anyerror!void {
        const x: *Obj = @ptrCast(@alignCast(req.node.ctx));
        const cb = x.on_call orelse return req.replyError(Connection.errors.unknown_method, "the object handles no calls");
        const self = x.self;
        const gpa = self.gpa();
        const inv = try gpa.create(Invocation);
        errdefer gpa.destroy(inv);
        inv.* = .{ .self = self, .obj = x, .method = req.method.?, .deferred = undefined };
        try register(self, Invocation, &self.dbus.invocations, inv, invocation_tag);
        inv.deferred = req.deferReply();
        const info = infoOf(req.msg, .method_call);
        const handle: t.DbusInvocation = @fromBackingInt(inv.handle);
        self.enter();
        withReader(self, req.args(), struct {
            fn run(c: t.DbusMethodCallFn, u: ?*anyopaque, i: *const t.DbusMessageInfo, h: t.DbusInvocation, r: t.DbusReader) void {
                c(u, i, r, h);
            }
        }.run, .{ cb, x.user_data, &info, handle });
        self.leave();
    }

    fn getProperty(ctx: dbus.object.PropertyContext, out: *Encoder) anyerror!void {
        const x: *Obj = @ptrCast(@alignCast(ctx.node.ctx));
        const cb = x.get_property orelse return error.NotSupported;
        const self = x.self;
        var m: Message = .{ .self = self, .conn = x.conn, .kind = .property, .enc = out };
        try register(self, Message, &self.dbus.messages, &m, message_tag);
        const name = ctx.property.name;
        self.enter();
        const r = cb(x.user_data, name.ptr, name.len, @fromBackingInt(m.handle));
        // The property's value may not have been written completely.
        unregister(self, Message, &self.dbus.messages, &m, message_tag);
        self.leave();
        if (r != .ok) return error.Failed;
        if (m.err != null or m.depth != 0) return error.InvalidValue;
    }

    fn setProperty(ctx: dbus.object.PropertyContext, in: *Decoder) anyerror!void {
        const x: *Obj = @ptrCast(@alignCast(ctx.node.ctx));
        const cb = x.set_property orelse return error.NotSupported;
        const self = x.self;
        const name = ctx.property.name;
        var result: t.Result = .ok;
        self.enter();
        withReader(self, in.*, struct {
            fn run(c: t.DbusSetPropertyFn, u: ?*anyopaque, n: []const u8, res: *t.Result, r: t.DbusReader) void {
                res.* = c(u, n.ptr, n.len, r);
            }
        }.run, .{ cb, x.user_data, name, &result });
        self.leave();
        // Connection skips the rest of the variant itself.
        in.skip() catch {};
        switch (result) {
            .ok => {},
            .error_invalid_argument => return error.InvalidArgs,
            .error_unsupported => return error.NotSupported,
            else => return error.Failed,
        }
    }
};

fn copyStr(a: std.mem.Allocator, ptr: ?[*]const u8, len: usize) ![]const u8 {
    return a.dupe(u8, try runtime.string(ptr, len));
}

fn exportObject(c: *Conn, desc: ?*const t.DbusObjectDesc, out: ?*t.DbusObject) !void {
    const self = c.self;
    const gpa = self.gpa();
    const d = try runtime.readDesc(t.DbusObjectDesc, desc);
    const dest = try runtime.out(t.DbusObject, out);
    const x = try gpa.create(Obj);
    errdefer gpa.destroy(x);
    x.* = .{
        .self = self,
        .conn = c,
        .arena = .init(gpa),
        .on_call = d.on_call,
        .get_property = d.get_property,
        .set_property = d.set_property,
        .destroy = d.destroy,
        .user_data = d.user_data,
    };
    errdefer x.arena.deinit();
    const a = x.arena.allocator();
    const path = try copyStr(a, d.path, d.path_len);
    const iface_name = try copyStr(a, d.interface, d.interface_len);
    if (!dbus.names.isObjectPath(path) or !dbus.names.isInterfaceName(iface_name)) return error.InvalidArgument;

    const ms = try runtime.array(t.DbusMethod, d.methods, d.methods_count);
    const methods = try a.alloc(dbus.Method, ms.len);
    for (ms, methods) |src, *m| {
        m.* = .{
            .name = try copyStr(a, src.name, src.name_len),
            .in = try copyStr(a, src.in_signature, src.in_signature_len),
            .out = try copyStr(a, src.out_signature, src.out_signature_len),
            .func = Obj.onMethod,
        };
        if (!dbus.names.isMemberName(m.name) or !dbus.signature.isValid(m.in) or !dbus.signature.isValid(m.out)) return error.InvalidArgument;
    }
    const ps = try runtime.array(t.DbusProperty, d.properties, d.properties_count);
    const props = try a.alloc(dbus.Property, ps.len);
    for (ps, props) |src, *p| {
        try runtime.reservedZero(src);
        const access = try runtime.enumValue(t.DbusAccess, src.access);
        p.* = .{
            .name = try copyStr(a, src.name, src.name_len),
            .signature = try copyStr(a, src.signature, src.signature_len),
            .access = switch (access) {
                .read => .read,
                .write => .write,
                .readwrite => .readwrite,
                _ => unreachable,
            },
            .get = if (access != .write) Obj.getProperty else null,
            .set = if (access != .read) Obj.setProperty else null,
        };
        if (!dbus.names.isMemberName(p.name) or !dbus.signature.isSingle(p.signature)) return error.InvalidArgument;
        if (p.get != null and d.get_property == null) return error.InvalidArgument;
        if (p.set != null and d.set_property == null) return error.InvalidArgument;
    }
    const ss = try runtime.array(t.DbusSignal, d.signals, d.signals_count);
    const signals = try a.alloc(dbus.object.Signal, ss.len);
    for (ss, signals) |src, *s| {
        s.* = .{ .name = try copyStr(a, src.name, src.name_len), .signature = try copyStr(a, src.signature, src.signature_len) };
        if (!dbus.names.isMemberName(s.name) or !dbus.signature.isValid(s.signature)) return error.InvalidArgument;
    }
    x.iface = .{ .name = iface_name, .methods = methods, .properties = props, .signals = signals };
    x.ifaces = .{&x.iface};
    x.object = .{ .path = path, .ctx = x, .interfaces = &x.ifaces };
    try register(self, Obj, &self.dbus.objects, x, object_tag);
    errdefer unregister(self, Obj, &self.dbus.objects, x, object_tag);
    try c.bus.exportObject(&x.object);
    dest.* = @fromBackingInt(x.handle);
}

pub export fn siv_dbus_export(handle: t.Dbus, desc: ?*const t.DbusObjectDesc, out: ?*t.DbusObject) t.Result {
    const c = lookup(Conn, "conns", @backingInt(handle), dbus_tag) catch |err| {
        if (desc) |d| if (d.destroy) |f| f(d.user_data);
        return t.resultOf(err);
    };
    exportObject(c, desc, out) catch |err| {
        if (desc) |d| c.self.release(d.destroy, d.user_data);
        return t.resultOf(mapError(err));
    };
    return .ok;
}

pub export fn siv_dbus_object_destroy(object: t.DbusObject) void {
    const x = lookup(Obj, "objects", @backingInt(object), object_tag) catch return;
    x.remove();
}

pub export fn siv_dbus_object_emit_properties_changed(object: t.DbusObject, name: ?[*]const u8, name_len: usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.DbusObject, p: ?[*]const u8, n: usize) Error!void {
            const x = try lookup(Obj, "objects", @backingInt(h), object_tag);
            const s = try runtime.string(p, n);
            const prop = x.iface.findProperty(s) orelse return error.InvalidArgument;
            if (prop.get == null) return error.InvalidArgument;
            x.conn.bus.emitPropertiesChanged(x.object.path, x.node(), &x.iface, &.{s}) catch |err| return mapError(err);
        }
    }.f(object, name, name_len));
}

// Invocations ----------------------------------------------------------------------

const Invocation = struct {
    self: *App,
    index: u32 = 0,
    handle: u64 = 0,
    obj: *Obj,
    method: *const dbus.Method,
    deferred: dbus.Connection.Deferred,

    fn member(inv: *const Invocation) []const u8 {
        return inv.method.name;
    }

    fn remove(inv: *Invocation) void {
        const self = inv.self;
        // Replies made for it can no longer be sent.
        for (self.dbus.messages.items) |slot| if (slot) |m| if (m.invocation == inv) {
            m.invocation = null;
        };
        unregister(self, Invocation, &self.dbus.invocations, inv, invocation_tag);
        self.gpa().destroy(inv);
    }

    fn answerError(inv: *Invocation, name: []const u8, text: []const u8) void {
        const bus = inv.obj.conn.bus;
        var b = inv.deferred.newError(bus, name);
        if (b.body.writeString(text)) {
            inv.deferred.send(bus, &b) catch {};
        } else |_| b.deinit();
    }

    /// The object or connection is going: the caller gets an error.
    fn answerGone(inv: *Invocation) void {
        inv.answerError(Connection.errors.unknown_object, "the object went away");
        inv.remove();
    }
};

fn invocationOf(h: t.DbusInvocation) Error!*Invocation {
    return lookup(Invocation, "invocations", @backingInt(h), invocation_tag);
}

pub export fn siv_dbus_invocation_reply_error(invocation: t.DbusInvocation, name: ?[*]const u8, name_len: usize, message: ?[*]const u8, message_len: usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.DbusInvocation, n: ?[*]const u8, nl: usize, m: ?[*]const u8, ml: usize) Error!void {
            const inv = try invocationOf(h);
            const ename = try runtime.string(n, nl);
            const text = try runtime.string(m, ml);
            if (!dbus.names.isErrorName(ename) or !std.unicode.utf8ValidateSlice(text)) return error.InvalidArgument;
            inv.answerError(ename, text);
            inv.remove();
        }
    }.f(invocation, name, name_len, message, message_len));
}
