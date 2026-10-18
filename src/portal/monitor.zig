//! System signals (D42), as GIO's GPowerProfileMonitor, GMemoryMonitor,
//! and GNetworkMonitor give them: whether power saving is on, warnings of
//! low memory, and whether the network is available, metered, and how
//! far it reaches.
//!
//! The portals come first (org.freedesktop.portal.PowerProfileMonitor,
//! MemoryMonitor, NetworkMonitor): xdg-desktop-portal implements them
//! itself, on top of the same system services, and answers sandboxed and
//! host applications alike. A monitor whose portal call fails (no portal,
//! or one without the interface) asks the system bus instead:
//! power-profiles-daemon (org.freedesktop.UPower.PowerProfiles, else its
//! old name net.hadess.PowerProfiles, which tuned-ppd also serves),
//! low-memory-monitor, and NetworkManager. Without either the defaults
//! stay: power saving off, the network available, unmetered, and full,
//! as GIO assumes.
//!
//! Changes reach `func` at safe points (D5), only when a value changed;
//! every memory warning does.

const std = @import("std");
const dbus = @import("dbus");
const loop_mod = @import("loop");
const Client = @import("Client.zig");
const vardict = @import("vardict.zig");

const Connection = dbus.Connection;
const Message = dbus.Message;
const Allocator = std.mem.Allocator;

pub const power_interface = "org.freedesktop.portal.PowerProfileMonitor";
pub const memory_interface = "org.freedesktop.portal.MemoryMonitor";
pub const network_interface = "org.freedesktop.portal.NetworkMonitor";
const properties_interface = "org.freedesktop.DBus.Properties";

pub const ppd_name = "org.freedesktop.UPower.PowerProfiles";
pub const ppd_path = "/org/freedesktop/UPower/PowerProfiles";
pub const ppd_old_name = "net.hadess.PowerProfiles";
pub const ppd_old_path = "/net/hadess/PowerProfiles";
pub const lmm_name = "org.freedesktop.LowMemoryMonitor";
pub const lmm_path = "/org/freedesktop/LowMemoryMonitor";
pub const nm_name = "org.freedesktop.NetworkManager";
pub const nm_path = "/org/freedesktop/NetworkManager";

/// GNetworkConnectivity's values, which the portal uses.
pub const Connectivity = enum(u32) {
    /// No route beyond this host.
    local = 1,
    /// A network, but not the Internet.
    limited = 2,
    /// A captive portal stands between this host and the Internet.
    captive_portal = 3,
    full = 4,
};

pub const Network = struct {
    available: bool = true,
    metered: bool = false,
    connectivity: Connectivity = .full,

    pub fn eql(a: Network, b: Network) bool {
        return a.available == b.available and a.metered == b.metered and a.connectivity == b.connectivity;
    }
};

/// low-memory-monitor's levels: 50 and up low, 100 and up medium, 255
/// critical.
pub const MemoryLevel = enum {
    low,
    medium,
    critical,

    pub fn of(level: u8) MemoryLevel {
        return if (level >= 255) .critical else if (level >= 100) .medium else .low;
    }
};

pub const Change = union(enum) {
    power_saver: bool,
    memory: MemoryLevel,
    network: Network,
};

pub const Source = enum { pending, portal, system, none };

/// How to reach the system bus for the fallbacks.
pub const SystemBus = union(enum) {
    none,
    address: []const u8,
    /// A connected socket, owned by the monitor (tests).
    fd: i32,
};

pub const Monitor = struct {
    gpa: Allocator,
    loop: *loop_mod.Loop,
    func: *const fn (m: *Monitor, change: Change) void,
    session: ?*Connection = null,
    system_bus: SystemBus = .none,
    system: Connection = undefined,
    system_state: enum { unused, up, failed } = .unused,

    power_saver: bool = false,
    network: Network = .{},
    power_source: Source = .pending,
    memory_source: Source = .pending,
    network_source: Source = .pending,

    power_serial: u32 = 0,
    memory_serial: u32 = 0,
    network_serial: u32 = 0,
    portal_power: Connection.Subscription = undefined,
    portal_memory: Connection.Subscription = undefined,
    portal_network: Connection.Subscription = undefined,
    portal_subscribed: bool = false,
    portal_watch: Connection.NameWatch = .{ .name = Client.portal_name, .func = onPortalOwner },
    portal_watching: bool = false,
    portal_owner: Connection.Name = .{},

    ppd_serial: u32 = 0,
    ppd_old: bool = false,
    ppd_props: Connection.Subscription = undefined,
    ppd_subscribed: bool = false,
    lmm_warning: Connection.Subscription = undefined,
    lmm_subscribed: bool = false,
    nm_serial: u32 = 0,
    nm_props: Connection.Subscription = undefined,
    nm_subscribed: bool = false,
    nm_state: u32 = 0,
    nm_connectivity: u32 = 0,
    nm_metered: u32 = 0,

    const power_args = [_]dbus.match.Arg{.{ .index = 0, .value = power_interface }};
    const ppd_args = [_]dbus.match.Arg{.{ .index = 0, .value = ppd_name }};
    const ppd_old_args = [_]dbus.match.Arg{.{ .index = 0, .value = ppd_old_name }};
    const nm_args = [_]dbus.match.Arg{.{ .index = 0, .value = nm_name }};

    /// Starts reading. `session` is the application's session bus, if
    /// it has one; the system bus is connected only when a portal fails.
    /// The monitor stays in place until `deinit`.
    pub fn start(m: *Monitor, session: ?*Connection, system_bus: SystemBus) void {
        m.session = session;
        m.system_bus = system_bus;
        const conn = session orelse return m.allToSystem();
        m.portal_power = .{ .rule = .{ .sender = Client.portal_name, .path = Client.portal_path, .interface = properties_interface, .member = "PropertiesChanged", .args = &power_args }, .func = onPortalPower };
        m.portal_memory = .{ .rule = .{ .sender = Client.portal_name, .path = Client.portal_path, .interface = memory_interface, .member = "LowMemoryWarning" }, .func = onPortalMemory };
        m.portal_network = .{ .rule = .{ .sender = Client.portal_name, .path = Client.portal_path, .interface = network_interface, .member = "changed" }, .func = onPortalNetwork };
        subscribeAll(conn, &.{ &m.portal_power, &m.portal_memory, &m.portal_network }) catch return m.allToSystem();
        m.portal_subscribed = true;
        if (conn.watchName(&m.portal_watch)) m.portal_watching = true else |_| {}
        m.readPortal();
    }

    pub fn deinit(m: *Monitor) void {
        if (m.session) |conn| {
            for ([_]*u32{ &m.power_serial, &m.memory_serial, &m.network_serial }) |s| if (s.* != 0) conn.cancelCall(s.*);
            if (m.portal_subscribed) for ([_]*Connection.Subscription{ &m.portal_power, &m.portal_memory, &m.portal_network }) |s| conn.unsubscribe(s);
            if (m.portal_watching) conn.unwatchName(&m.portal_watch);
        }
        if (m.system_state == .up) {
            // The connection goes, and its calls and subscriptions with it.
            m.system.deinit();
        } else if (m.system_state == .unused) {
            if (m.system_bus == .fd) _ = std.os.linux.close(m.system_bus.fd);
        }
        m.system_state = .failed;
    }

    fn subscribeAll(conn: *Connection, subs: []const *Connection.Subscription) Connection.Error!void {
        for (subs, 0..) |s, i| conn.subscribe(s) catch |err| {
            for (subs[0..i]) |x| conn.unsubscribe(x);
            return err;
        };
    }

    // The portals -------------------------------------------------------------------

    fn readPortal(m: *Monitor) void {
        const conn = m.session.?;
        if (m.power_source != .system and m.power_serial == 0)
            m.power_serial = conn.callMethod(Client.portal_name, Client.portal_path, properties_interface, "Get", .{ @as([]const u8, power_interface), @as([]const u8, "power-saver-enabled") }, onPowerReply, m) catch 0;
        if (m.power_serial == 0 and m.power_source == .pending) m.powerToSystem();
        if (m.memory_source == .pending and m.memory_serial == 0)
            m.memory_serial = conn.callMethod(Client.portal_name, Client.portal_path, properties_interface, "Get", .{ @as([]const u8, memory_interface), @as([]const u8, "version") }, onMemoryReply, m) catch 0;
        if (m.memory_serial == 0 and m.memory_source == .pending) m.memoryToSystem();
        m.readPortalNetwork();
    }

    fn readPortalNetwork(m: *Monitor) void {
        if (m.network_source == .system or m.network_serial != 0) return;
        m.network_serial = m.session.?.callMethod(Client.portal_name, Client.portal_path, network_interface, "GetStatus", .{}, onNetworkReply, m) catch 0;
        if (m.network_serial == 0 and m.network_source == .pending) m.networkToSystem();
    }

    fn onPowerReply(ctx: ?*anyopaque, reply: Connection.Reply) void {
        const m: *Monitor = @ptrCast(@alignCast(ctx));
        m.power_serial = 0;
        const v = switch (reply) {
            .ok => |msg| blk: {
                var d = msg.body();
                break :blk (d.read(dbus.Variant(bool)) catch break :blk null);
            },
            else => null,
        };
        if (v) |x| {
            m.power_source = .portal;
            m.setPowerSaver(x.value);
        } else if (m.power_source == .pending) m.powerToSystem();
    }

    fn onMemoryReply(ctx: ?*anyopaque, reply: Connection.Reply) void {
        const m: *Monitor = @ptrCast(@alignCast(ctx));
        m.memory_serial = 0;
        switch (reply) {
            .ok => m.memory_source = .portal,
            else => if (m.memory_source == .pending) m.memoryToSystem(),
        }
    }

    fn onNetworkReply(ctx: ?*anyopaque, reply: Connection.Reply) void {
        const m: *Monitor = @ptrCast(@alignCast(ctx));
        m.network_serial = 0;
        const status: ?Network = switch (reply) {
            .ok => |msg| parseStatus(msg),
            else => null,
        };
        if (status) |n| {
            m.network_source = .portal;
            m.setNetwork(n);
        } else if (m.network_source == .pending) m.networkToSystem();
    }

    /// GetStatus's a{sv}: available, metered, connectivity.
    fn parseStatus(msg: *const Message) ?Network {
        var d = msg.body();
        const r = vardict.Reader.take(&d) catch return null;
        var n: Network = .{};
        if (r.boolean("available")) |b| n.available = b;
        if (r.boolean("metered")) |b| n.metered = b;
        if (r.uint("connectivity")) |c| n.connectivity = if (c >= 1 and c <= 4) @enumFromInt(c) else .full;
        return n;
    }

    fn onPortalPower(sub: *Connection.Subscription, msg: *const Message) void {
        const m: *Monitor = @fieldParentPtr("portal_power", sub);
        if (m.power_source != .portal) return;
        switch (changedBool(msg, "power-saver-enabled")) {
            .value => |b| m.setPowerSaver(b),
            .invalidated => m.readPortal(),
            .none => {},
        }
    }

    fn onPortalMemory(sub: *Connection.Subscription, msg: *const Message) void {
        const m: *Monitor = @fieldParentPtr("portal_memory", sub);
        if (m.memory_source != .portal) return;
        var d = msg.body();
        const level = d.readByte() catch return;
        m.func(m, .{ .memory = .of(level) });
    }

    fn onPortalNetwork(sub: *Connection.Subscription, _: *const Message) void {
        const m: *Monitor = @fieldParentPtr("portal_network", sub);
        if (m.network_source == .portal) m.readPortalNetwork();
    }

    /// A restarted portal: read again what it answers for.
    fn onPortalOwner(w: *Connection.NameWatch) void {
        const m: *Monitor = @fieldParentPtr("portal_watch", w);
        const owner = w.owner() orelse return;
        const known = m.portal_owner.slice();
        const restarted = known.len > 0 and !std.mem.eql(u8, known, owner);
        m.portal_owner.set(owner);
        if (restarted and (m.power_source == .portal or m.network_source == .portal)) m.readPortal();
    }

    const BoolChange = union(enum) { none, invalidated, value: bool };

    /// A boolean property in a PropertiesChanged signal.
    fn changedBool(msg: *const Message, name: []const u8) BoolChange {
        if (!std.mem.eql(u8, msg.signature, "sa{sv}as")) return .none;
        var d = msg.body();
        _ = d.readString() catch return .none;
        const r = vardict.Reader.take(&d) catch return .none;
        if (r.boolean(name)) |b| return .{ .value = b };
        if (invalidates(&d, name)) return .invalidated;
        return .none;
    }

    fn invalidates(d: *dbus.Decoder, name: []const u8) bool {
        const a = d.beginArray() catch return false;
        while (a.next(d)) {
            const s = d.readString() catch return false;
            if (std.mem.eql(u8, s, name)) return true;
        }
        return false;
    }

    // The system bus ------------------------------------------------------------------

    fn systemConn(m: *Monitor) ?*Connection {
        switch (m.system_state) {
            .up => return &m.system,
            .failed => return null,
            .unused => {},
        }
        m.system_state = .failed;
        switch (m.system_bus) {
            .none => return null,
            .address => |a| m.system.init(m.gpa, m.loop, a, .{}) catch return null,
            .fd => |fd| m.system.initFd(m.gpa, m.loop, fd, .{}) catch {
                _ = std.os.linux.close(fd);
                return null;
            },
        }
        m.system_state = .up;
        return &m.system;
    }

    fn allToSystem(m: *Monitor) void {
        m.powerToSystem();
        m.memoryToSystem();
        m.networkToSystem();
    }

    fn powerToSystem(m: *Monitor) void {
        m.power_source = .none;
        const conn = m.systemConn() orelse return;
        m.power_source = .system;
        m.readPpd(conn);
    }

    fn readPpd(m: *Monitor, conn: *Connection) void {
        const name, const path = if (m.ppd_old) .{ ppd_old_name, ppd_old_path } else .{ ppd_name, ppd_path };
        m.ppd_serial = conn.callMethod(name, path, properties_interface, "Get", .{ name, @as([]const u8, "ActiveProfile") }, onPpdReply, m) catch 0;
    }

    fn onPpdReply(ctx: ?*anyopaque, reply: Connection.Reply) void {
        const m: *Monitor = @ptrCast(@alignCast(ctx));
        m.ppd_serial = 0;
        const profile = switch (reply) {
            .ok => |msg| blk: {
                var d = msg.body();
                break :blk (d.read(dbus.Variant([]const u8)) catch break :blk null);
            },
            else => null,
        };
        const conn = &m.system;
        if (profile) |p| {
            if (!m.ppd_subscribed) {
                const name, const path, const args = if (m.ppd_old) .{ ppd_old_name, ppd_old_path, &ppd_old_args } else .{ ppd_name, ppd_path, &ppd_args };
                m.ppd_props = .{ .rule = .{ .sender = name, .path = path, .interface = properties_interface, .member = "PropertiesChanged", .args = args }, .func = onPpdChanged };
                if (conn.subscribe(&m.ppd_props)) m.ppd_subscribed = true else |_| {}
            }
            m.setPowerSaver(std.mem.eql(u8, p.value, "power-saver"));
        } else if (!m.ppd_old and !m.ppd_subscribed) {
            // power-profiles-daemon before 0.20, and tuned-ppd.
            m.ppd_old = true;
            m.readPpd(conn);
        }
    }

    fn onPpdChanged(sub: *Connection.Subscription, msg: *const Message) void {
        const m: *Monitor = @fieldParentPtr("ppd_props", sub);
        if (!std.mem.eql(u8, msg.signature, "sa{sv}as")) return;
        var d = msg.body();
        _ = d.readString() catch return;
        const r = vardict.Reader.take(&d) catch return;
        if (r.string("ActiveProfile")) |p| m.setPowerSaver(std.mem.eql(u8, p, "power-saver"));
    }

    fn memoryToSystem(m: *Monitor) void {
        m.memory_source = .none;
        const conn = m.systemConn() orelse return;
        m.lmm_warning = .{ .rule = .{ .sender = lmm_name, .path = lmm_path, .interface = lmm_name, .member = "LowMemoryWarning" }, .func = onLmmWarning };
        conn.subscribe(&m.lmm_warning) catch return;
        m.lmm_subscribed = true;
        m.memory_source = .system;
    }

    fn onLmmWarning(sub: *Connection.Subscription, msg: *const Message) void {
        const m: *Monitor = @fieldParentPtr("lmm_warning", sub);
        var d = msg.body();
        const level = d.readByte() catch return;
        m.func(m, .{ .memory = .of(level) });
    }

    fn networkToSystem(m: *Monitor) void {
        m.network_source = .none;
        const conn = m.systemConn() orelse return;
        m.nm_props = .{ .rule = .{ .sender = nm_name, .path = nm_path, .interface = properties_interface, .member = "PropertiesChanged", .args = &nm_args }, .func = onNmChanged };
        conn.subscribe(&m.nm_props) catch return;
        m.nm_subscribed = true;
        m.network_source = .system;
        m.nm_serial = conn.callMethod(nm_name, nm_path, properties_interface, "GetAll", .{@as([]const u8, nm_name)}, onNmReply, m) catch 0;
    }

    fn onNmReply(ctx: ?*anyopaque, reply: Connection.Reply) void {
        const m: *Monitor = @ptrCast(@alignCast(ctx));
        m.nm_serial = 0;
        const msg = switch (reply) {
            .ok => |x| x,
            else => return,
        };
        var d = msg.body();
        const r = vardict.Reader.take(&d) catch return;
        m.applyNm(&r);
    }

    fn onNmChanged(sub: *Connection.Subscription, msg: *const Message) void {
        const m: *Monitor = @fieldParentPtr("nm_props", sub);
        if (!std.mem.eql(u8, msg.signature, "sa{sv}as")) return;
        var d = msg.body();
        _ = d.readString() catch return;
        const r = vardict.Reader.take(&d) catch return;
        m.applyNm(&r);
    }

    fn applyNm(m: *Monitor, r: *const vardict.Reader) void {
        if (r.uint("State")) |v| m.nm_state = v;
        if (r.uint("Connectivity")) |v| m.nm_connectivity = v;
        if (r.uint("Metered")) |v| m.nm_metered = v;
        m.setNetwork(networkOfNm(m.nm_state, m.nm_connectivity, m.nm_metered));
    }

    // Changes --------------------------------------------------------------------------

    fn setPowerSaver(m: *Monitor, on: bool) void {
        if (m.power_saver == on) return;
        m.power_saver = on;
        m.func(m, .{ .power_saver = on });
    }

    fn setNetwork(m: *Monitor, n: Network) void {
        if (m.network.eql(n)) return;
        m.network = n;
        m.func(m, .{ .network = n });
    }
};

/// NetworkManager's state (NMState), connectivity (NMConnectivityState),
/// and metered (NMMetered) values as GIO's network monitor reads them.
pub fn networkOfNm(state: u32, connectivity: u32, metered: u32) Network {
    const conn: Connectivity = switch (connectivity) {
        1 => .local, // none
        2 => .captive_portal, // portal
        3 => .limited,
        4 => .full,
        // Unknown: NetworkManager did not check; go by its state.
        else => if (state >= 70) .full else if (state >= 50) .limited else if (state == 0) .full else .local,
    };
    return .{
        .available = conn != .local,
        // yes and guess-yes.
        .metered = metered == 1 or metered == 3,
        .connectivity = conn,
    };
}
