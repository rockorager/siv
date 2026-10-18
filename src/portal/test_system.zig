//! Stand-ins for what system signals and the trash portal talk to (D42),
//! for hermetic tests on a test bus: xdg-desktop-portal's
//! PowerProfileMonitor, MemoryMonitor, NetworkMonitor, and Trash, and the
//! system services behind the fallbacks (power-profiles-daemon,
//! low-memory-monitor, NetworkManager). Not part of libsiv.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus");
const Client = @import("Client.zig");
const monitor = @import("monitor.zig");
const trash = @import("trash.zig");

const Connection = dbus.Connection;
const gpa = std.testing.allocator;

pub const System = struct {
    conn: *Connection,
    /// Serve the portal interfaces (as org.freedesktop.portal.Desktop).
    portal: bool = true,
    /// Serve the system services.
    services: bool = false,
    /// power-profiles-daemon under its old name only.
    old_ppd: bool = false,

    power_saver: bool = false,
    profile: []const u8 = "balanced",
    network: monitor.Network = .{},
    nm_state: u32 = 70,
    nm_connectivity: u32 = 4,
    nm_metered: u32 = 2,
    /// TrashFile's answer, and the paths of the files it was given.
    trash_code: u32 = 1,
    trashed: std.ArrayList([]u8) = .empty,

    owners: [4]Connection.NameOwner = undefined,
    owner_count: usize = 0,
    objects: [4]dbus.Object = undefined,
    object_count: usize = 0,

    fn prop(name: []const u8, sig: []const u8, get: anytype) dbus.Property {
        return .{ .name = name, .signature = sig, .get = get };
    }

    const power_iface: dbus.Interface = .{ .name = monitor.power_interface, .properties = &.{
        prop("power-saver-enabled", "b", getPowerSaver),
        prop("version", "u", getVersion),
    } };
    const memory_iface: dbus.Interface = .{ .name = monitor.memory_interface, .properties = &.{prop("version", "u", getVersion)}, .signals = &.{.{ .name = "LowMemoryWarning", .signature = "y" }} };
    const network_iface: dbus.Interface = .{ .name = monitor.network_interface, .methods = &.{.{ .name = "GetStatus", .out = "a{sv}", .func = getStatus }}, .signals = &.{.{ .name = "changed" }} };
    const trash_iface: dbus.Interface = .{ .name = trash.interface, .methods = &.{.{ .name = "TrashFile", .in = "h", .out = "u", .func = trashFile }} };
    const ppd_iface: dbus.Interface = .{ .name = monitor.ppd_name, .properties = &.{prop("ActiveProfile", "s", getProfile)} };
    const ppd_old_iface: dbus.Interface = .{ .name = monitor.ppd_old_name, .properties = &.{prop("ActiveProfile", "s", getProfile)} };
    const lmm_iface: dbus.Interface = .{ .name = monitor.lmm_name, .signals = &.{.{ .name = "LowMemoryWarning", .signature = "y" }} };
    const nm_iface: dbus.Interface = .{ .name = monitor.nm_name, .properties = &.{
        prop("State", "u", getNm),
        prop("Connectivity", "u", getNm),
        prop("Metered", "u", getNm),
    } };

    pub fn start(s: *System) !void {
        if (s.portal) {
            try s.serve(Client.portal_name, Client.portal_path, &.{ &power_iface, &memory_iface, &network_iface, &trash_iface });
        }
        if (s.services) {
            if (s.old_ppd) {
                try s.serve(monitor.ppd_old_name, monitor.ppd_old_path, &.{&ppd_old_iface});
            } else {
                try s.serve(monitor.ppd_name, monitor.ppd_path, &.{&ppd_iface});
            }
            try s.serve(monitor.lmm_name, monitor.lmm_path, &.{&lmm_iface});
            try s.serve(monitor.nm_name, monitor.nm_path, &.{&nm_iface});
        }
    }

    fn serve(s: *System, name: []const u8, path: []const u8, ifaces: []const *const dbus.Interface) !void {
        const o = &s.objects[s.object_count];
        o.* = .{ .path = path, .ctx = s, .interfaces = ifaces };
        try s.conn.exportObject(o);
        s.object_count += 1;
        const w = &s.owners[s.owner_count];
        w.* = .{ .name = name };
        try s.conn.requestName(w);
        s.owner_count += 1;
    }

    pub fn owns(s: *const System) bool {
        for (s.owners[0..s.owner_count]) |*o| if (o.state != .primary) return false;
        return true;
    }

    pub fn deinit(s: *System) void {
        for (s.trashed.items) |p| gpa.free(p);
        s.trashed.deinit(gpa);
    }

    fn of(ctx: dbus.object.PropertyContext) *System {
        return @ptrCast(@alignCast(ctx.node.ctx));
    }

    fn getPowerSaver(ctx: dbus.object.PropertyContext, out: *dbus.Encoder) anyerror!void {
        try out.writeBool(of(ctx).power_saver);
    }

    fn getVersion(_: dbus.object.PropertyContext, out: *dbus.Encoder) anyerror!void {
        try out.writeUint32(1);
    }

    fn getProfile(ctx: dbus.object.PropertyContext, out: *dbus.Encoder) anyerror!void {
        try out.writeString(of(ctx).profile);
    }

    fn getNm(ctx: dbus.object.PropertyContext, out: *dbus.Encoder) anyerror!void {
        const s = of(ctx);
        const name = ctx.property.name;
        try out.writeUint32(if (std.mem.eql(u8, name, "State")) s.nm_state else if (std.mem.eql(u8, name, "Connectivity")) s.nm_connectivity else s.nm_metered);
    }

    fn getStatus(r: *dbus.Request) anyerror!void {
        const s: *System = @ptrCast(@alignCast(r.node.ctx));
        var b = r.newReply();
        errdefer b.deinit();
        try b.body.beginArray("{sv}");
        inline for (.{ .{ "available", s.network.available }, .{ "metered", s.network.metered }, .{ "connectivity", @as(u32, @intFromEnum(s.network.connectivity)) } }) |kv| {
            try b.body.beginDictEntry();
            try b.body.writeString(kv[0]);
            try b.body.write(dbus.variant(kv[1]));
            try b.body.endDictEntry();
        }
        try b.body.endArray();
        try r.sendReply(&b);
    }

    fn trashFile(r: *dbus.Request) anyerror!void {
        const s: *System = @ptrCast(@alignCast(r.node.ctx));
        var pbuf: [64]u8 = undefined;
        var lbuf: [std.fs.max_path_bytes]u8 = undefined;
        const fd = if (r.msg.fds.len > 0) r.msg.fds[0] else -1;
        const proc = try std.fmt.bufPrintSentinel(&pbuf, "/proc/self/fd/{d}", .{fd}, 0);
        const n = linux.readlink(proc, &lbuf, lbuf.len);
        if (linux.errno(n) == .SUCCESS) try s.trashed.append(gpa, try gpa.dupe(u8, lbuf[0..n]));
        try r.reply(.{s.trash_code});
    }

    fn node(s: *System, path: []const u8) dbus.Node {
        for (s.objects[0..s.object_count]) |o| if (std.mem.eql(u8, o.path, path)) return .{ .ctx = s, .interfaces = o.interfaces };
        unreachable;
    }

    pub fn setPowerSaver(s: *System, on: bool) !void {
        s.power_saver = on;
        try s.conn.emitPropertiesChanged(Client.portal_path, s.node(Client.portal_path), &power_iface, &.{"power-saver-enabled"});
    }

    pub fn setProfile(s: *System, profile: []const u8) !void {
        s.profile = profile;
        const path = if (s.old_ppd) monitor.ppd_old_path else monitor.ppd_path;
        try s.conn.emitPropertiesChanged(path, s.node(path), if (s.old_ppd) &ppd_old_iface else &ppd_iface, &.{"ActiveProfile"});
    }

    pub fn warnMemory(s: *System, level: u8) !void {
        if (s.portal) try s.conn.emitSignal(Client.portal_path, monitor.memory_interface, "LowMemoryWarning", .{level});
        if (s.services) try s.conn.emitSignal(monitor.lmm_path, monitor.lmm_name, "LowMemoryWarning", .{level});
    }

    pub fn setNetwork(s: *System, n: monitor.Network) !void {
        s.network = n;
        try s.conn.emitSignal(Client.portal_path, monitor.network_interface, "changed", .{});
    }

    pub fn setNm(s: *System, state: u32, connectivity: u32, metered: u32) !void {
        s.nm_state = state;
        s.nm_connectivity = connectivity;
        s.nm_metered = metered;
        try s.conn.emitPropertiesChanged(monitor.nm_path, s.node(monitor.nm_path), &nm_iface, &.{ "Connectivity", "Metered" });
    }
};
