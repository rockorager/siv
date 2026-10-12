//! org.freedesktop.Application: D-Bus activation and single instance
//! (D19). The primary instance owns the application id as a bus name and
//! exports the interface at the id's object path; desktops (and
//! dbus-daemon, for DBusActivatable applications) call Activate, Open,
//! and ActivateAction on it. A second instance finds the name taken and
//! forwards its own activation to the primary with the same calls.

const std = @import("std");
const dbus = @import("dbus");
const vardict = @import("vardict.zig");

const Connection = dbus.Connection;

pub const interface = "org.freedesktop.Application";

/// The object path of an application id: "/" and the id with dots as
/// slashes and dashes as underscores ("org.example.App" is
/// /org/example/App). Null if the id is not a valid bus name.
pub fn objectPath(buf: []u8, app_id: []const u8) ?[]const u8 {
    if (!dbus.names.isBusName(app_id) or dbus.names.isUniqueName(app_id) or app_id.len + 1 > buf.len) return null;
    buf[0] = '/';
    for (app_id, buf[1..][0..app_id.len]) |c, *o| o.* = switch (c) {
        '.' => '/',
        '-' => '_',
        else => c,
    };
    return buf[0 .. app_id.len + 1];
}

/// The activation token of platform data: "activation-token", or X11's
/// "desktop-startup-id", or empty.
fn tokenOf(platform_data: vardict.Reader) []const u8 {
    return platform_data.string("activation-token") orelse platform_data.string("desktop-startup-id") orelse "";
}

/// What the primary instance is asked to do.
pub const Handler = struct {
    ctx: ?*anyopaque,
    activate: *const fn (ctx: ?*anyopaque, token: []const u8) void,
    /// `uris` iterates the URIs to open.
    open: *const fn (ctx: ?*anyopaque, uris: *vardict.StringIterator, token: []const u8) void,
    /// `target` is the action's parameter if it is a string, else empty.
    action: *const fn (ctx: ?*anyopaque, name: []const u8, target: []const u8, token: []const u8) void,
};

/// The primary instance's side: owns the name and serves the interface.
/// Owned by the caller; stays in place while started.
pub const Server = struct {
    handler: Handler,
    /// Called when the name request settles: `owner.state` is primary,
    /// exists (another instance has it), or failed.
    on_name: ?*const fn (s: *Server) void = null,
    conn: *Connection = undefined,
    path_buf: [256]u8 = undefined,
    name_buf: [256]u8 = undefined,
    obj: dbus.Object = undefined,
    owner: Connection.NameOwner = .{ .name = "" },
    exported: bool = false,

    const iface: dbus.Interface = .{
        .name = interface,
        .methods = &.{
            .{ .name = "Activate", .in = "a{sv}", .in_names = &.{"platform_data"}, .func = onActivate },
            .{ .name = "Open", .in = "asa{sv}", .in_names = &.{ "uris", "platform_data" }, .func = onOpen },
            .{ .name = "ActivateAction", .in = "sava{sv}", .in_names = &.{ "action_name", "parameter", "platform_data" }, .func = onAction },
        },
    };

    pub const Error = Connection.Error || error{InvalidAppId};

    /// Exports the interface and asks for the name, without queueing.
    pub fn start(s: *Server, conn: *Connection, app_id: []const u8) Error!void {
        const path = objectPath(&s.path_buf, app_id) orelse return error.InvalidAppId;
        @memcpy(s.name_buf[0..app_id.len], app_id);
        s.conn = conn;
        s.obj = .{ .path = path, .ctx = s, .interfaces = &.{&iface} };
        try conn.exportObject(&s.obj);
        s.exported = true;
        errdefer s.stop();
        s.owner = .{ .name = s.name_buf[0..app_id.len], .flags = .{ .do_not_queue = true }, .func = onOwner };
        try conn.requestName(&s.owner);
    }

    pub fn stop(s: *Server) void {
        if (s.owner.state != .idle) s.conn.releaseName(&s.owner);
        if (s.exported) s.conn.unexportObject(&s.obj);
        s.exported = false;
    }

    pub fn primary(s: *const Server) bool {
        return s.owner.state == .primary;
    }

    fn onOwner(o: *Connection.NameOwner) void {
        const s: *Server = @fieldParentPtr("owner", o);
        if (o.state == .requesting) return;
        if (o.state != .primary and s.exported) {
            // Not ours: another instance serves the interface.
            s.conn.unexportObject(&s.obj);
            s.exported = false;
        }
        if (s.on_name) |f| f(s);
    }

    fn serverOf(r: *dbus.Request) *Server {
        return @ptrCast(@alignCast(r.node.ctx));
    }

    fn onActivate(r: *dbus.Request) anyerror!void {
        const s = serverOf(r);
        var d = r.args();
        const pd = try vardict.Reader.take(&d);
        try r.reply(.{});
        s.handler.activate(s.handler.ctx, tokenOf(pd));
    }

    fn onOpen(r: *dbus.Request) anyerror!void {
        const s = serverOf(r);
        var d = r.args();
        const arr_start = d;
        try d.skip();
        const pd = try vardict.Reader.take(&d);
        var it: vardict.StringIterator = .{ .d = arr_start, .a = undefined };
        it.a = try it.d.beginArray();
        try r.reply(.{});
        s.handler.open(s.handler.ctx, &it, tokenOf(pd));
    }

    fn onAction(r: *dbus.Request) anyerror!void {
        const s = serverOf(r);
        var d = r.args();
        const name = try d.readString();
        const target = @import("notification.zig").firstString(&d);
        // firstString may stop inside the array; read the platform data
        // from a fresh decoder past the first two arguments.
        var d2 = r.args();
        _ = try d2.readString();
        try d2.skip();
        const pd = try vardict.Reader.take(&d2);
        try r.reply(.{});
        s.handler.action(s.handler.ctx, name, target, tokenOf(pd));
    }
};

/// A second instance's side: forwards an activation to the primary.
/// Owned by the caller; stays in place until `func` ran.
pub const Forward = struct {
    func: *const fn (f: *Forward, ok: bool) void,
    conn: *Connection = undefined,
    serial: u32 = 0,

    pub fn activate(f: *Forward, conn: *Connection, app_id: []const u8, token: []const u8) Server.Error!void {
        try f.send(conn, app_id, "Activate", {}, token);
    }

    pub fn open(f: *Forward, conn: *Connection, app_id: []const u8, uris: []const []const u8, token: []const u8) Server.Error!void {
        try f.send(conn, app_id, "Open", uris, token);
    }

    pub fn action(f: *Forward, conn: *Connection, app_id: []const u8, name: []const u8, target: []const u8, token: []const u8) Server.Error!void {
        try f.send(conn, app_id, "ActivateAction", [2][]const u8{ name, target }, token);
    }

    /// The header's strings only need to live until the call is queued.
    fn send(f: *Forward, conn: *Connection, app_id: []const u8, member: []const u8, args: anytype, token: []const u8) Server.Error!void {
        var buf: [256]u8 = undefined;
        const path = objectPath(&buf, app_id) orelse return error.InvalidAppId;
        f.conn = conn;
        var b = conn.methodCall(app_id, path, interface, member);
        writeArgs(&b.body, args, token) catch |err| {
            b.deinit();
            return err;
        };
        f.serial = try conn.call(&b, onReply, f, .{});
    }

    pub fn cancel(f: *Forward) void {
        if (f.serial != 0) f.conn.cancelCall(f.serial);
        f.serial = 0;
    }

    fn onReply(ctx: ?*anyopaque, reply: Connection.Reply) void {
        const f: *Forward = @ptrCast(@alignCast(ctx));
        f.serial = 0;
        f.func(f, reply == .ok);
    }
};

fn writeArgs(e: *dbus.Encoder, args: anytype, token: []const u8) dbus.codec.EncodeError!void {
    switch (@TypeOf(args)) {
        void => {},
        []const []const u8 => try e.write(args),
        [2][]const u8 => {
            try e.writeString(args[0]);
            try e.beginArray("v");
            if (args[1].len > 0) try e.write(dbus.variant(args[1]));
            try e.endArray();
        },
        else => @compileError("unexpected arguments"),
    }
    const w = try vardict.Writer.begin(e);
    if (token.len > 0) try w.put("activation-token", token);
    try w.end();
}
