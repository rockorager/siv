//! What every portal call shares (D19): the session bus connection, the
//! request and session path prefix derived from the connection's unique
//! name, unique tokens, and whether the application runs in Flatpak.
//!
//! Requests and sessions live at paths the client chooses through
//! `handle_token` and `session_handle_token`, under
//! /org/freedesktop/portal/desktop/{request,session}/SENDER/TOKEN, where
//! SENDER is the unique name without its colon and with dots as
//! underscores. A request subscribes to its Response signal before the
//! call goes out, so it needs the unique name; calls made before the bus
//! answered Hello wait in `queued` until `connectionReady`.

const std = @import("std");
const dbus = @import("dbus");
const Request = @import("Request.zig");

const Client = @This();

conn: *dbus.Connection,
/// The application runs inside Flatpak (/.flatpak-info exists). Portals
/// then know its application id; outside, `register` tells them.
flatpak: bool = false,
counter: u32 = 0,
/// The Notification interface's version, once `queryVersions` learned
/// it; 0 until then.
notification_version: u32 = 0,
version_serial: u32 = 0,
/// Requests waiting for the connection's unique name.
queued: std.DoublyLinkedList = .{},

pub const portal_name = "org.freedesktop.portal.Desktop";
pub const portal_path = "/org/freedesktop/portal/desktop";
pub const documents_name = "org.freedesktop.portal.Documents";
pub const documents_path = "/org/freedesktop/portal/documents";

pub const max_path = 160;
pub const Path = dbus.Connection.Name;

pub fn init(conn: *dbus.Connection) Client {
    return .{ .conn = conn, .flatpak = std.os.linux.access("/.flatpak-info", 0) == 0 };
}

/// Fails every queued request; the client is unusable afterwards.
pub fn deinit(c: *Client) void {
    if (c.version_serial != 0) c.conn.cancelCall(c.version_serial);
    c.connectionLost();
}

/// Asks for the interface versions that change what may be sent.
pub fn queryVersions(c: *Client) void {
    c.version_serial = c.conn.callMethod(portal_name, portal_path, "org.freedesktop.DBus.Properties", "Get", .{ @as([]const u8, "org.freedesktop.portal.Notification"), @as([]const u8, "version") }, onVersion, c) catch 0;
}

fn onVersion(ctx: ?*anyopaque, reply: dbus.Connection.Reply) void {
    const c: *Client = @ptrCast(@alignCast(ctx));
    c.version_serial = 0;
    const m = switch (reply) {
        .ok => |m| m,
        else => return,
    };
    var d = m.body();
    const v = d.read(dbus.Variant(u32)) catch return;
    c.notification_version = v.value;
}

pub fn ready(c: *const Client) bool {
    return c.conn.uniqueName().len > 0;
}

/// A token for handle_token or session_handle_token: unique per client,
/// a valid object path element.
pub fn nextToken(c: *Client, buf: *[24]u8) []const u8 {
    c.counter +%= 1;
    return std.fmt.bufPrint(buf, "siv{d}", .{c.counter}) catch unreachable;
}

/// The object path of a request (`kind` "request") or session ("session")
/// with `token`, or null before the bus assigned a unique name.
pub fn objectPath(c: *const Client, buf: *[max_path]u8, kind: []const u8, token: []const u8) ?[]const u8 {
    const unique = c.conn.uniqueName();
    if (unique.len < 2) return null;
    const out = std.fmt.bufPrint(buf, "{s}/{s}/{s}/{s}", .{ portal_path, kind, unique[1..], token }) catch return null;
    const start = portal_path.len + kind.len + 2;
    for (out[start..][0 .. unique.len - 1]) |*ch| {
        if (ch.* == '.') ch.* = '_';
    }
    return out;
}

/// The bus assigned the unique name: queued requests go out.
pub fn connectionReady(c: *Client) void {
    while (c.queued.popFirst()) |n| {
        const r: *Request = @fieldParentPtr("queue_node", n);
        r.queued = false;
        r.go();
    }
}

/// The bus went away: queued requests fail. Requests in flight fail
/// through their calls.
pub fn connectionLost(c: *Client) void {
    while (c.queued.popFirst()) |n| {
        const r: *Request = @fieldParentPtr("queue_node", n);
        r.queued = false;
        r.fail(.disconnected);
    }
}

/// Tells xdg-desktop-portal (1.19 and later) the application id of a
/// host application, which it otherwise derives from the systemd scope.
/// Must precede every other portal call on the connection. Inside
/// Flatpak, or with an empty id, nothing is sent; older portals answer
/// with an error that is ignored.
pub fn register(conn: *dbus.Connection, app_id: []const u8) dbus.Connection.Error!void {
    if (app_id.len == 0 or std.os.linux.access("/.flatpak-info", 0) == 0) return;
    var b = conn.methodCall(portal_name, portal_path, "org.freedesktop.host.portal.Registry", "Register");
    b.header.flags.no_reply_expected = true;
    errdefer b.deinit();
    try b.body.writeString(app_id);
    try b.body.beginArray("{sv}");
    try b.body.endArray();
    _ = try conn.send(&b);
}
