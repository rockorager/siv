//! The tray item over a real dbus-daemon, read by GLib's gdbus, an
//! independent client: introspection, the properties a host reads, the
//! dbusmenu layout, and the calls a host makes (`zig build
//! test-integration`).

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const dbus = @import("dbus");
const Loop = @import("loop").Loop;
const Item = @import("Item.zig");
const Watcher = @import("test_watcher.zig").Watcher;
const td = dbus.testing.daemon;

const gpa = testing.allocator;

const Events = struct {
    item: Item,
    registered: u32 = 0,
    menu: i32 = 0,
    activated: u32 = 0,
    x: i32 = 0,

    fn on(it: *Item, ev: Item.Event) void {
        const e: *Events = @fieldParentPtr("item", it);
        switch (ev) {
            .registered => e.registered += 1,
            .menu => |id| e.menu = id,
            .activate => |a| {
                e.activated += 1;
                e.x = a.x;
            },
            else => {},
        }
    }
};

/// Runs gdbus against the bus while the loop keeps answering, and returns
/// its output (in `buf`).
fn gdbus(loop: *Loop, address: []const u8, args: []const [*:0]const u8, buf: []u8) ![]const u8 {
    const exe = td.findExecutable("gdbus") orelse return error.SkipZigTest;
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    argv[0] = exe;
    for (args, 1..) |a, i| argv[i] = a;
    var env_buf: [256]u8 = undefined;
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", try std.fmt.bufPrintSentinel(&env_buf, "DBUS_SESSION_BUS_ADDRESS={s}", .{address}, 0) };
    const out: i32 = @intCast(linux.memfd_create("siv-gdbus", linux.MFD.CLOEXEC));
    defer _ = linux.close(out);
    const pid = try td.spawn(exe, &argv, &envp, out);
    var status: c_int = 0;
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (std.c.waitpid(pid, &status, std.c.W.NOHANG) == 0) {
        if (Loop.now() > deadline) {
            td.kill(pid);
            return error.Timeout;
        }
        try loop.dispatch(10);
    }
    const n = linux.pread(out, buf.ptr, buf.len, 0);
    const text = buf[0..if (linux.errno(n) == .SUCCESS) n else 0];
    if (status != 0) {
        std.debug.print("gdbus failed: {s}\n", .{text});
        return error.GdbusFailed;
    }
    return text;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;
    std.debug.print("missing {s} in:\n{s}\n", .{ needle, haystack });
    return error.TestExpectedEqual;
}

test "a tray item over dbus-daemon, read by gdbus" {
    var daemon: td.Daemon = .{};
    try daemon.start();
    defer daemon.stop();
    var loop = try Loop.init(gpa);
    defer loop.deinit();
    var watcher_conn: dbus.Connection = undefined;
    try watcher_conn.init(gpa, &loop, daemon.address, .{});
    defer watcher_conn.deinit();
    var conn: dbus.Connection = undefined;
    try conn.init(gpa, &loop, daemon.address, .{});
    defer conn.deinit();

    var watcher: Watcher = .{ .gpa = gpa, .conn = &watcher_conn };
    defer watcher.deinit();
    try watcher.start();
    var ev: Events = .{ .item = .init(gpa, Events.on) };
    defer ev.item.deinit();
    try ev.item.start(&conn, .{ .id = "org.example.Tray", .title = "Example", .icon_name = "mail-unread" });
    try ev.item.setToolTip("Tray", "Body");
    try ev.item.menu.set(.{ .id = 1, .label = "Open" });
    try ev.item.menu.set(.{ .id = 2, .label = "Quit", .icon_name = "application-exit" });
    const deadline = Loop.now() + 5 * std.time.ns_per_s;
    while (ev.registered == 0) {
        if (Loop.now() > deadline) return error.Timeout;
        try loop.dispatch(10);
    }
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&name_buf, "{s}", .{ev.item.owner.name}, 0);
    try testing.expect(std.mem.endsWith(u8, watcher.items.items[0], name));

    var buf: [8192]u8 = undefined;
    var out = try gdbus(&loop, daemon.address, &.{ "introspect", "--session", "--dest", name, "--object-path", "/StatusNotifierItem" }, &buf);
    try expectContains(out, "interface org.kde.StatusNotifierItem");
    try expectContains(out, "readonly a(iiay) IconPixmap");

    out = try gdbus(&loop, daemon.address, &.{ "call", "--session", "--dest", name, "--object-path", "/StatusNotifierItem", "--method", "org.freedesktop.DBus.Properties.GetAll", "org.kde.StatusNotifierItem" }, &buf);
    try expectContains(out, "'IconName': <'mail-unread'>");
    try expectContains(out, "'Id': <'org.example.Tray'>");
    try expectContains(out, "'Status': <'Active'>");
    try expectContains(out, "'Menu': <objectpath '/MenuBar'>");
    try expectContains(out, "'Tray', 'Body')>");

    out = try gdbus(&loop, daemon.address, &.{ "call", "--session", "--dest", name, "--object-path", "/MenuBar", "--method", "com.canonical.dbusmenu.GetLayout", "--", "0", "-1", "[]" }, &buf);
    try expectContains(out, "'label': <'Open'>");
    try expectContains(out, "'icon-name': <'application-exit'>");

    _ = try gdbus(&loop, daemon.address, &.{ "call", "--session", "--dest", name, "--object-path", "/MenuBar", "--method", "com.canonical.dbusmenu.Event", "2", "clicked", "<0>", "0" }, &buf);
    try testing.expectEqual(@as(i32, 2), ev.menu);
    _ = try gdbus(&loop, daemon.address, &.{ "call", "--session", "--dest", name, "--object-path", "/StatusNotifierItem", "--method", "org.kde.StatusNotifierItem.Activate", "10", "20" }, &buf);
    try testing.expectEqual(@as(u32, 1), ev.activated);
    try testing.expectEqual(@as(i32, 10), ev.x);
}
