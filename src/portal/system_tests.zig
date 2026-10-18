//! System signals and the trash portal (D42) against stand-ins on the
//! in-process test bus: the portals first, the system services when the
//! portal fails, and the defaults without either.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const dbus = @import("dbus");
const Loop = @import("loop").Loop;
const portal = @import("portal.zig");
const System = @import("test_system.zig").System;

const monitor = portal.monitor;
const gpa = testing.allocator;

const Harness = struct {
    loop: Loop = undefined,
    bus: dbus.testing.TestBus = undefined,
    app_conn: dbus.Connection = undefined,
    stand_conn: dbus.Connection = undefined,
    stand: System = undefined,
    mon: monitor.Monitor = undefined,
    changes: std.ArrayList(monitor.Change) = .empty,

    fn init(h: *Harness, stand: System) !void {
        h.loop = try Loop.init(gpa);
        h.bus = .init(gpa, &h.loop);
        try h.stand_conn.initFd(gpa, &h.loop, try h.bus.connect(), .{});
        h.stand = stand;
        h.stand.conn = &h.stand_conn;
        try h.stand.start();
        try h.until(&h.stand, System.owns);
        try h.app_conn.initFd(gpa, &h.loop, try h.bus.connect(), .{});
        h.mon = .{ .gpa = gpa, .loop = &h.loop, .func = onChange };
    }

    fn deinit(h: *Harness) void {
        h.mon.deinit();
        h.changes.deinit(gpa);
        h.app_conn.deinit();
        h.stand.deinit();
        h.stand_conn.deinit();
        h.bus.deinit();
        h.loop.deinit();
    }

    fn onChange(m: *monitor.Monitor, c: monitor.Change) void {
        const h: *Harness = @fieldParentPtr("mon", m);
        h.changes.append(gpa, c) catch unreachable;
    }

    fn until(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        const deadline = Loop.now() + 2 * std.time.ns_per_s;
        while (!cond(ctx)) {
            if (Loop.now() > deadline) return error.TestTimeout;
            try h.loop.dispatch(50);
        }
    }

    fn changeCount(h: *Harness, n: usize) !void {
        const Ctx = struct {
            h: *Harness,
            n: usize,
            fn done(c: @This()) bool {
                return c.h.changes.items.len >= c.n;
            }
        };
        try h.until(Ctx{ .h = h, .n = n }, Ctx.done);
    }

    fn settle(h: *Harness) !void {
        for (0..20) |_| try h.loop.dispatch(5);
    }
};

test "power saving, memory warnings, and the network come from the portals" {
    var h: Harness = .{};
    try h.init(.{ .conn = undefined, .power_saver = true, .network = .{ .metered = true, .connectivity = .limited } });
    defer h.deinit();
    const system_fd = try h.bus.connect();
    h.mon.start(&h.app_conn, .{ .fd = system_fd });
    try h.changeCount(2);
    try testing.expect(h.mon.power_saver);
    try testing.expect(h.mon.network.metered);
    try testing.expectEqual(monitor.Connectivity.limited, h.mon.network.connectivity);
    try h.settle();
    try testing.expectEqual(monitor.Source.portal, h.mon.power_source);
    try testing.expectEqual(monitor.Source.portal, h.mon.memory_source);
    try testing.expectEqual(monitor.Source.portal, h.mon.network_source);
    // The portals answered: the system bus was never connected.
    try testing.expectEqual(.unused, h.mon.system_state);
    try testing.expectEqual(@as(usize, 2), h.changes.items.len);

    try h.stand.setPowerSaver(false);
    try h.changeCount(3);
    try testing.expectEqual(monitor.Change{ .power_saver = false }, h.changes.items[2]);
    // The same value again is no change.
    try h.stand.setPowerSaver(false);
    try h.stand.warnMemory(100);
    try h.changeCount(4);
    try testing.expectEqual(monitor.Change{ .memory = .medium }, h.changes.items[3]);
    try h.stand.warnMemory(255);
    try h.stand.warnMemory(50);
    try h.changeCount(6);
    try testing.expectEqual(monitor.Change{ .memory = .critical }, h.changes.items[4]);
    try testing.expectEqual(monitor.Change{ .memory = .low }, h.changes.items[5]);

    try h.stand.setNetwork(.{ .available = false, .connectivity = .local });
    try h.changeCount(7);
    try testing.expect(!h.mon.network.available);
    try testing.expectEqual(monitor.Connectivity.local, h.mon.network.connectivity);
    try h.settle();
    try testing.expectEqual(@as(usize, 7), h.changes.items.len);
}

test "without the portal, the system services answer" {
    var h: Harness = .{};
    try h.init(.{ .conn = undefined, .portal = false, .services = true, .profile = "power-saver", .nm_state = 70, .nm_connectivity = 2, .nm_metered = 3 });
    defer h.deinit();
    h.mon.start(&h.app_conn, .{ .fd = try h.bus.connect() });
    try h.changeCount(2);
    try h.settle();
    try testing.expectEqual(monitor.Source.system, h.mon.power_source);
    try testing.expectEqual(monitor.Source.system, h.mon.memory_source);
    try testing.expectEqual(monitor.Source.system, h.mon.network_source);
    try testing.expect(h.mon.power_saver);
    try testing.expectEqual(monitor.Network{ .available = true, .metered = true, .connectivity = .captive_portal }, h.mon.network);

    try h.stand.setProfile("performance");
    try h.changeCount(3);
    try testing.expectEqual(monitor.Change{ .power_saver = false }, h.changes.items[2]);
    try h.stand.warnMemory(255);
    try h.changeCount(4);
    try testing.expectEqual(monitor.Change{ .memory = .critical }, h.changes.items[3]);
    try h.stand.setNm(20, 1, 2);
    try h.changeCount(5);
    try testing.expectEqual(monitor.Network{ .available = false, .metered = false, .connectivity = .local }, h.mon.network);
}

test "power-profiles-daemon under its old name" {
    var h: Harness = .{};
    try h.init(.{ .conn = undefined, .portal = false, .services = true, .old_ppd = true, .profile = "power-saver" });
    defer h.deinit();
    h.mon.start(null, .{ .fd = try h.bus.connect() });
    try h.until(&h.mon, struct {
        fn f(m: *monitor.Monitor) bool {
            return m.power_saver;
        }
    }.f);
    try h.stand.setProfile("balanced");
    try h.until(&h.mon, struct {
        fn f(m: *monitor.Monitor) bool {
            return !m.power_saver;
        }
    }.f);
}

test "without a portal or a system bus the defaults stay" {
    var h: Harness = .{};
    try h.init(.{ .conn = undefined, .portal = false });
    defer h.deinit();
    h.mon.start(&h.app_conn, .none);
    try h.settle();
    try testing.expectEqual(monitor.Source.none, h.mon.power_source);
    try testing.expectEqual(monitor.Source.none, h.mon.memory_source);
    try testing.expectEqual(monitor.Source.none, h.mon.network_source);
    try testing.expectEqual(monitor.Network{}, h.mon.network);
    try testing.expect(!h.mon.power_saver);
    try testing.expectEqual(@as(usize, 0), h.changes.items.len);
}

test "NetworkManager's states map as GIO maps them" {
    const N = monitor.Network;
    try testing.expectEqual(N{ .available = true, .metered = false, .connectivity = .full }, monitor.networkOfNm(70, 4, 2));
    try testing.expectEqual(N{ .available = true, .metered = true, .connectivity = .limited }, monitor.networkOfNm(60, 3, 1));
    try testing.expectEqual(N{ .available = false, .metered = false, .connectivity = .local }, monitor.networkOfNm(20, 1, 4));
    // Connectivity not checked: the state decides.
    try testing.expectEqual(monitor.Connectivity.full, monitor.networkOfNm(70, 0, 0).connectivity);
    try testing.expectEqual(monitor.Connectivity.limited, monitor.networkOfNm(50, 0, 0).connectivity);
    try testing.expectEqual(monitor.Connectivity.local, monitor.networkOfNm(20, 0, 0).connectivity);
}

const TrashRecord = struct {
    call: portal.trash.Call = .{ .func = cb },
    result: ?portal.trash.Result = null,

    fn cb(c: *portal.trash.Call, r: portal.trash.Result) void {
        const t: *TrashRecord = @fieldParentPtr("call", c);
        t.result = r;
    }

    fn done(t: *TrashRecord) bool {
        return t.result != null;
    }
};

test "the trash portal gets the file by descriptor and says whether it trashed it" {
    var h: Harness = .{};
    try h.init(.{ .conn = undefined });
    defer h.deinit();
    var client = portal.Client.init(&h.app_conn);
    defer client.deinit();
    var t: TrashRecord = .{};
    try t.call.start(&client, "/etc/hostname");
    try h.until(&t, TrashRecord.done);
    try testing.expectEqual(portal.trash.Result.trashed, t.result.?);
    try testing.expectEqualStrings("/etc/hostname", h.stand.trashed.items[0]);

    h.stand.trash_code = 0;
    var r: TrashRecord = .{};
    try r.call.start(&client, "/etc/hostname");
    try h.until(&r, TrashRecord.done);
    try testing.expectEqual(portal.trash.Result.refused, r.result.?);
    try testing.expectError(error.FileNotFound, r.call.start(&client, "/nonexistent/x"));
}

test "without the trash portal the call is unavailable" {
    var h: Harness = .{};
    try h.init(.{ .conn = undefined, .portal = false });
    defer h.deinit();
    var client = portal.Client.init(&h.app_conn);
    defer client.deinit();
    var t: TrashRecord = .{};
    try t.call.start(&client, "/etc/hostname");
    try h.until(&t, TrashRecord.done);
    try testing.expectEqual(portal.trash.Result{ .failed = .unavailable }, t.result.?);
}
