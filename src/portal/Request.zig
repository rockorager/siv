//! A portal request (D19): the request/response pattern of
//! org.freedesktop.portal.Request.
//!
//! The caller picks a token, writes it as `handle_token` into the call's
//! options, and starts the request with the call. The request subscribes
//! to Response on its predictable path before the call goes out, so a
//! response cannot be missed. If the portal answers with another path
//! (portals before 0.9 ignored the token), the subscription moves there.
//! `func` runs once, at a safe point (D5), with the response and its
//! results, or with a failure: no portal, an error reply, or the bus gone.
//!
//! The request is owned by the caller and must stay in place until `func`
//! has run or `cancel` returned. Results are borrowed during `func`.

const std = @import("std");
const dbus = @import("dbus");
const Client = @import("Client.zig");
const vardict = @import("vardict.zig");

const Request = @This();
const Connection = dbus.Connection;

func: *const fn (r: *Request, outcome: Outcome) void,
client: *Client = undefined,
token_buf: [24]u8 = undefined,
token_len: u8 = 0,
path_buf: [Client.max_path]u8 = undefined,
path_len: u8 = 0,
arg: [1]dbus.match.Arg = undefined,
sub: Connection.Subscription = .{ .rule = .{}, .func = onResponse },
subscribed: bool = false,
serial: u32 = 0,
/// The call, held until the connection has a unique name.
pending: ?dbus.Builder = null,
queued: bool = false,
queue_node: std.DoublyLinkedList.Node = .{},
active: bool = false,

pub const Response = enum(u32) {
    success = 0,
    /// The user cancelled the interaction.
    cancelled = 1,
    /// The interaction ended some other way (closed, denied).
    other = 2,
};

pub const Failure = enum {
    /// No portal runs, or it lacks the interface or method.
    unavailable,
    /// The portal replied with an error (invalid arguments, denied).
    failed,
    /// The bus connection closed, or the call timed out.
    disconnected,
};

pub const Outcome = union(enum) {
    response: struct { code: Response, results: vardict.Reader },
    failed: Failure,
};

/// Chooses the request's token; write it as `handle_token` into the
/// call's options, then `start` the request.
pub fn token(r: *Request, client: *Client) []const u8 {
    r.client = client;
    const t = client.nextToken(&r.token_buf);
    r.token_len = @intCast(t.len);
    return t;
}

pub fn tokenSlice(r: *const Request) []const u8 {
    return r.token_buf[0..r.token_len];
}

/// The request's object path; empty until the call went out.
pub fn path(r: *const Request) []const u8 {
    return r.path_buf[0..r.path_len];
}

/// Sends the call `b` (a method call with `handle_token` from `token`).
/// Always consumes `b`. On failure `func` will not run.
pub fn start(r: *Request, b: *dbus.Builder) Connection.Error!void {
    std.debug.assert(!r.active and r.token_len > 0);
    if (!r.client.conn.connected()) {
        b.deinit();
        return error.Disconnected;
    }
    r.active = true;
    r.path_len = 0;
    if (!r.client.ready()) {
        r.pending = b.*;
        r.queued = true;
        r.client.queued.append(&r.queue_node);
        return;
    }
    r.send(b) catch |err| {
        r.active = false;
        return err;
    };
}

/// Called by the client once the connection has a unique name.
pub fn go(r: *Request) void {
    var b = r.pending.?;
    r.pending = null;
    r.send(&b) catch |err| r.fail(switch (err) {
        error.Disconnected => .disconnected,
        else => .failed,
    });
}

fn send(r: *Request, b: *dbus.Builder) Connection.Error!void {
    const c = r.client;
    const p = c.objectPath(&r.path_buf, "request", r.tokenSlice()) orelse {
        b.deinit();
        return error.Disconnected;
    };
    r.path_len = @intCast(p.len);
    r.subscribe() catch |err| {
        b.deinit();
        return err;
    };
    errdefer r.unsubscribe();
    r.serial = try c.conn.call(b, onReply, r, .{ .timeout_ms = null });
}

fn subscribe(r: *Request) Connection.Error!void {
    r.sub = .{
        .rule = .{
            .type = .signal,
            .sender = Client.portal_name,
            .interface = "org.freedesktop.portal.Request",
            .member = "Response",
            .path = r.path(),
        },
        .func = onResponse,
    };
    try r.client.conn.subscribe(&r.sub);
    r.subscribed = true;
}

fn unsubscribe(r: *Request) void {
    if (!r.subscribed) return;
    r.client.conn.unsubscribe(&r.sub);
    r.subscribed = false;
}

/// Closes the request: the portal dismisses its dialog (or, for Inhibit,
/// ends the inhibition), and `func` does not run. Closing a request that
/// already answered sends Close anyway, which only Inhibit needs.
pub fn cancel(r: *Request) void {
    if (r.queued) {
        r.client.queued.remove(&r.queue_node);
        r.queued = false;
        if (r.pending) |*b| b.deinit();
        r.pending = null;
        r.active = false;
        return;
    }
    if (r.token_len == 0) return;
    r.active = false;
    const conn = r.client.conn;
    if (r.serial != 0) conn.cancelCall(r.serial);
    r.serial = 0;
    r.unsubscribe();
    if (r.path_len > 0 and conn.connected()) {
        var b = conn.methodCall(Client.portal_name, r.path(), "org.freedesktop.portal.Request", "Close");
        b.header.flags.no_reply_expected = true;
        _ = conn.send(&b) catch {};
    }
    r.path_len = 0;
}

/// Cancels the request if it has not answered yet.
pub fn abandon(r: *Request) void {
    if (r.active) r.cancel();
}

/// Ends the request with a failure.
pub fn fail(r: *Request, failure: Failure) void {
    if (!r.active) return;
    r.active = false;
    if (r.pending) |*b| b.deinit();
    r.pending = null;
    r.unsubscribe();
    r.func(r, .{ .failed = failure });
}

fn onReply(ctx: ?*anyopaque, reply: Connection.Reply) void {
    const r: *Request = @ptrCast(@alignCast(ctx));
    r.serial = 0;
    switch (reply) {
        .ok => |m| {
            var d = m.body();
            const handle = d.readObjectPath() catch return r.fail(.failed);
            if (std.mem.eql(u8, handle, r.path())) return;
            // An old portal chose its own path; follow it. A response sent
            // before this point is lost, as with every client of such
            // portals.
            if (handle.len > r.path_buf.len) return r.fail(.failed);
            r.unsubscribe();
            @memcpy(r.path_buf[0..handle.len], handle);
            r.path_len = @intCast(handle.len);
            r.subscribe() catch r.fail(.failed);
        },
        .err => |m| r.fail(failureOf(m.error_name.?)),
        .failed => r.fail(.disconnected),
    }
}

/// Maps an error reply to a failure: a missing portal, interface, or
/// method means the feature is unavailable.
pub fn failureOf(name: []const u8) Failure {
    const unavailable = [_][]const u8{
        Connection.errors.service_unknown,
        Connection.errors.unknown_interface,
        Connection.errors.unknown_method,
        Connection.errors.unknown_object,
        Connection.errors.name_has_no_owner,
        "org.freedesktop.DBus.Error.ServiceUnknown",
    };
    for (unavailable) |u| if (std.mem.eql(u8, name, u)) return .unavailable;
    return .failed;
}

fn onResponse(sub: *Connection.Subscription, m: *const dbus.Message) void {
    const r: *Request = @fieldParentPtr("sub", sub);
    if (!r.active or !std.mem.eql(u8, m.signature, "ua{sv}")) return;
    var d = m.body();
    const code = d.readUint32() catch return;
    const results = vardict.Reader.take(&d) catch return;
    r.active = false;
    r.unsubscribe();
    r.func(r, .{ .response = .{
        .code = switch (code) {
            0 => .success,
            1 => .cancelled,
            else => .other,
        },
        .results = results,
    } });
}
