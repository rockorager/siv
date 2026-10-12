//! A portal session (org.freedesktop.portal.Session), as ScreenCast and
//! GlobalShortcuts create: a path the client chooses with
//! `session_handle_token`, a Closed signal when the portal ends it, and
//! Close to end it from this side.
//!
//! Owned by the caller; it must stay in place while open.

const std = @import("std");
const dbus = @import("dbus");
const Client = @import("Client.zig");

const Session = @This();
const Connection = dbus.Connection;

/// Runs when the portal closed the session.
on_closed: ?*const fn (s: *Session) void = null,
client: *Client = undefined,
token_buf: [24]u8 = undefined,
token_len: u8 = 0,
path_buf: [Client.max_path]u8 = undefined,
path_len: u8 = 0,
sub: Connection.Subscription = .{ .rule = .{}, .func = onClosed },
subscribed: bool = false,
/// The portal created the session (its CreateSession request succeeded).
open: bool = false,

/// Chooses the session token for `session_handle_token`.
pub fn token(s: *Session, client: *Client) []const u8 {
    s.client = client;
    const t = client.nextToken(&s.token_buf);
    s.token_len = @intCast(t.len);
    return t;
}

pub fn tokenSlice(s: *const Session) []const u8 {
    return s.token_buf[0..s.token_len];
}

pub fn path(s: *const Session) []const u8 {
    return s.path_buf[0..s.path_len];
}

/// The CreateSession request succeeded with `handle` (the
/// session_handle result): follow its Closed signal.
pub fn opened(s: *Session, handle: []const u8) Connection.Error!void {
    if (handle.len > s.path_buf.len) return error.InvalidMessage;
    @memcpy(s.path_buf[0..handle.len], handle);
    s.path_len = @intCast(handle.len);
    s.sub = .{
        .rule = .{ .type = .signal, .sender = Client.portal_name, .interface = "org.freedesktop.portal.Session", .member = "Closed", .path = s.path() },
        .func = onClosed,
    };
    try s.client.conn.subscribe(&s.sub);
    s.subscribed = true;
    s.open = true;
}

/// Ends the session. Harmless when it is not open.
pub fn close(s: *Session) void {
    if (s.subscribed) s.client.conn.unsubscribe(&s.sub);
    s.subscribed = false;
    if (!s.open) return;
    s.open = false;
    const conn = s.client.conn;
    if (!conn.connected()) return;
    var b = conn.methodCall(Client.portal_name, s.path(), "org.freedesktop.portal.Session", "Close");
    b.header.flags.no_reply_expected = true;
    _ = conn.send(&b) catch {};
}

fn onClosed(sub: *Connection.Subscription, _: *const dbus.Message) void {
    const s: *Session = @fieldParentPtr("sub", sub);
    if (!s.open) return;
    s.open = false;
    s.client.conn.unsubscribe(&s.sub);
    s.subscribed = false;
    if (s.on_closed) |f| f(s);
}
