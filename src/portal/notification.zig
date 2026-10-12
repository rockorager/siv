//! org.freedesktop.portal.Notification: desktop notifications, and the
//! actions their buttons invoke (ActionInvoked). Not request based: a
//! notification is replaced by sending one with the same id.

const std = @import("std");
const dbus = @import("dbus");
const Client = @import("Client.zig");
const vardict = @import("vardict.zig");

pub const interface = "org.freedesktop.portal.Notification";

pub const Priority = enum { normal, low, high, urgent };

pub const Button = struct {
    label: []const u8,
    action: []const u8,
    /// A string parameter for the action; empty for none.
    target: []const u8 = "",
};

pub const Icon = union(enum) {
    none,
    /// A themed icon name, such as "mail-unread".
    themed: []const u8,
    /// Encoded image data (PNG).
    bytes: []const u8,
};

pub const Notification = struct {
    title: []const u8 = "",
    body: []const u8 = "",
    icon: Icon = .none,
    priority: Priority = .normal,
    /// The action activating the notification invokes; empty for the
    /// default (the application is activated).
    default_action: []const u8 = "",
    default_target: []const u8 = "",
    buttons: []const Button = &.{},
    /// Not kept in the notification list (display-hint "transient",
    /// version 2; left out for older portals, which refuse unknown keys).
    transient: bool = false,
};

/// Shows (or replaces) notification `id`.
pub fn add(client: *Client, id: []const u8, n: Notification) dbus.Connection.Error!void {
    var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "AddNotification");
    b.header.flags.no_reply_expected = true;
    write(&b.body, id, n, client.notification_version) catch |err| {
        b.deinit();
        return err;
    };
    _ = try client.conn.send(&b);
}

fn write(e: *dbus.Encoder, id: []const u8, n: Notification, version: u32) dbus.codec.EncodeError!void {
    try e.writeString(id);
    const w = try vardict.Writer.begin(e);
    if (n.title.len > 0) try w.put("title", n.title);
    if (n.body.len > 0) try w.put("body", n.body);
    switch (n.icon) {
        .none => {},
        // A serialized GIcon: ('themed', <['name']>) or ('bytes', <ay>).
        .themed => |name| {
            try w.open("icon", "(sv)");
            try e.write(.{ @as([]const u8, "themed"), dbus.variant(@as([]const []const u8, &.{name})) });
            try w.close();
        },
        .bytes => |data| {
            try w.open("icon", "(sv)");
            try e.write(.{ @as([]const u8, "bytes"), dbus.variant(dbus.Bytes{ .bytes = data }) });
            try w.close();
        },
    }
    if (n.priority != .normal) try w.put("priority", @as([]const u8, @tagName(n.priority)));
    if (n.default_action.len > 0) {
        try w.put("default-action", n.default_action);
        if (n.default_target.len > 0) try w.put("default-action-target", n.default_target);
    }
    if (n.buttons.len > 0) {
        try w.open("buttons", "aa{sv}");
        try e.beginArray("a{sv}");
        for (n.buttons) |btn| {
            const bw = try vardict.Writer.begin(e);
            try bw.put("label", btn.label);
            try bw.put("action", btn.action);
            if (btn.target.len > 0) try bw.put("target", btn.target);
            try bw.end();
        }
        try e.endArray();
        try w.close();
    }
    if (n.transient and version >= 2) {
        try w.open("display-hint", "as");
        try e.write(@as([]const []const u8, &.{"transient"}));
        try w.close();
    }
    try w.end();
}

/// Withdraws notification `id`.
pub fn remove(client: *Client, id: []const u8) dbus.Connection.Error!void {
    var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "RemoveNotification");
    b.header.flags.no_reply_expected = true;
    b.body.writeString(id) catch |err| {
        b.deinit();
        return err;
    };
    _ = try client.conn.send(&b);
}

/// Follows ActionInvoked: the user activated a notification or one of
/// its buttons. Owned by the caller.
pub const Actions = struct {
    func: *const fn (a: *Actions, id: []const u8, action: []const u8, target: []const u8) void,
    sub: dbus.Connection.Subscription = undefined,
    client: *Client = undefined,

    pub fn subscribe(a: *Actions, client: *Client) dbus.Connection.Error!void {
        a.client = client;
        a.sub = .{
            .rule = .{ .type = .signal, .sender = Client.portal_name, .path = Client.portal_path, .interface = interface, .member = "ActionInvoked" },
            .func = onAction,
        };
        try client.conn.subscribe(&a.sub);
    }

    pub fn unsubscribe(a: *Actions) void {
        a.client.conn.unsubscribe(&a.sub);
    }

    fn onAction(sub: *dbus.Connection.Subscription, m: *const dbus.Message) void {
        const a: *Actions = @fieldParentPtr("sub", sub);
        if (!std.mem.eql(u8, m.signature, "ssav")) return;
        var d = m.body();
        const id = d.readString() catch return;
        const action = d.readString() catch return;
        a.func(a, id, action, firstString(&d));
    }
};

/// The first element of an av if it is a string, else empty.
pub fn firstString(d: *dbus.Decoder) []const u8 {
    const arr = d.beginArray() catch return "";
    if (!arr.next(d)) return "";
    const vs = d.beginVariant() catch return "";
    if (!std.mem.eql(u8, vs, "s")) return "";
    return d.readString() catch "";
}
