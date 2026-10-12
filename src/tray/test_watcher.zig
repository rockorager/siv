//! A stand-in org.kde.StatusNotifierWatcher for tests: it records the
//! items that register (the service string and the sender) and announces
//! them, or refuses them when told to. Not part of libsiv.

const std = @import("std");
const dbus = @import("dbus");
const Item = @import("Item.zig");

const Connection = dbus.Connection;

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    conn: *Connection,
    owner: Connection.NameOwner = .{ .name = Item.watcher_name },
    obj: dbus.Object = undefined,
    /// "<sender> <service>" of each registration.
    items: std.ArrayList([]u8) = .empty,
    refuse: bool = false,

    const iface: dbus.Interface = .{
        .name = Item.watcher_name,
        .methods = &.{
            .{ .name = "RegisterStatusNotifierItem", .in = "s", .func = register },
            .{ .name = "RegisterStatusNotifierHost", .in = "s", .func = host },
        },
        .properties = &.{
            .{ .name = "IsStatusNotifierHostRegistered", .signature = "b", .get = struct {
                fn get(_: dbus.object.PropertyContext, e: *dbus.Encoder) anyerror!void {
                    try e.writeBool(true);
                }
            }.get },
            .{ .name = "ProtocolVersion", .signature = "i", .get = struct {
                fn get(_: dbus.object.PropertyContext, e: *dbus.Encoder) anyerror!void {
                    try e.writeInt32(0);
                }
            }.get },
        },
        .signals = &.{.{ .name = "StatusNotifierItemRegistered", .signature = "s" }},
    };

    pub fn start(w: *Watcher) !void {
        w.obj = .{ .path = Item.watcher_path, .ctx = w, .interfaces = &.{&iface} };
        try w.conn.exportObject(&w.obj);
        w.owner = .{ .name = Item.watcher_name };
        try w.conn.requestName(&w.owner);
    }

    /// Leaves the bus name, as a desktop shell exiting does.
    pub fn stop(w: *Watcher) void {
        w.conn.releaseName(&w.owner);
        w.conn.unexportObject(&w.obj);
    }

    pub fn owns(w: *const Watcher) bool {
        return w.owner.state == .primary;
    }

    pub fn deinit(w: *Watcher) void {
        for (w.items.items) |i| w.gpa.free(i);
        w.items.deinit(w.gpa);
    }

    fn register(r: *dbus.Request) anyerror!void {
        const w: *Watcher = @ptrCast(@alignCast(r.node.ctx));
        if (w.refuse) return r.replyError("org.freedesktop.DBus.Error.AccessDenied", "refused by the test");
        var d = r.args();
        const service = try d.readString();
        try w.items.append(w.gpa, try std.fmt.allocPrint(w.gpa, "{s} {s}", .{ r.sender() orelse "", service }));
        try r.reply(.{});
        try w.conn.emitSignal(Item.watcher_path, Item.watcher_name, "StatusNotifierItemRegistered", .{service});
    }

    fn host(r: *dbus.Request) anyerror!void {
        try r.reply(.{});
    }
};
