//! The tray item on a test bus, hermetically: registration with a
//! stand-in watcher (and without one), the properties and menu a host
//! reads, and the events a host sends. `zig build test-integration`
//! reads the same item with GLib's gdbus over dbus-daemon.

const std = @import("std");
const testing = std.testing;
const dbus = @import("dbus");
const Loop = @import("loop").Loop;
const Item = @import("Item.zig");
const Menu = @import("Menu.zig");
const Watcher = @import("test_watcher.zig").Watcher;

const gpa = testing.allocator;

const Harness = struct {
    loop: Loop,
    bus: dbus.testing.TestBus,
    item_conn: dbus.Connection,
    watcher_conn: dbus.Connection,
    client: dbus.Connection,
    watcher: Watcher,
    item: Item,
    events: std.ArrayList(Item.Event) = .empty,
    token: [16]u8 = undefined,
    token_len: usize = 0,

    fn init(h: *Harness) !void {
        h.loop = try Loop.init(gpa);
        h.bus = .init(gpa, &h.loop);
        try h.item_conn.initFd(gpa, &h.loop, try h.bus.connect(), .{});
        try h.watcher_conn.initFd(gpa, &h.loop, try h.bus.connect(), .{});
        try h.client.initFd(gpa, &h.loop, try h.bus.connect(), .{});
        h.watcher = .{ .gpa = gpa, .conn = &h.watcher_conn };
        h.item = .init(gpa, onEvent);
        h.events = .empty;
        h.token_len = 0;
    }

    fn deinit(h: *Harness) void {
        h.item.deinit();
        h.events.deinit(gpa);
        h.watcher.deinit();
        h.client.deinit();
        h.watcher_conn.deinit();
        h.item_conn.deinit();
        h.bus.deinit();
        h.loop.deinit();
    }

    fn onEvent(it: *Item, ev: Item.Event) void {
        const h: *Harness = @fieldParentPtr("item", it);
        var e = ev;
        if (e == .activate) {
            const n = @min(e.activate.token.len, h.token.len);
            @memcpy(h.token[0..n], e.activate.token[0..n]);
            h.token_len = n;
            e.activate.token = "";
        }
        h.events.append(gpa, e) catch {};
    }

    fn until(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        const deadline = Loop.now() + 2 * std.time.ns_per_s;
        while (!cond(ctx)) {
            if (Loop.now() > deadline) return error.TestTimeout;
            try h.loop.dispatch(20);
        }
    }

    fn eventCount(h: *Harness, comptime tag: std.meta.Tag(Item.Event)) usize {
        var n: usize = 0;
        for (h.events.items) |e| if (e == tag) {
            n += 1;
        };
        return n;
    }

    fn last(h: *Harness) Item.Event {
        return h.events.items[h.events.items.len - 1];
    }

    /// Calls a method on the item from the client and waits for the reply,
    /// whose body `read` decodes.
    fn call(h: *Harness, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, args: anytype, read: ?*const fn (ctx: *Reply, d: *dbus.Decoder) anyerror!void) !Reply {
        var r: Reply = .{ .read = read };
        _ = try h.client.callMethod(dest, path, iface, member, args, Reply.cb, &r);
        try h.until(&r, Reply.isDone);
        if (r.err) return error.ErrorReply;
        if (r.read_failed) return error.BadReply;
        return r;
    }
};

const Reply = struct {
    done: bool = false,
    err: bool = false,
    read_failed: bool = false,
    read: ?*const fn (ctx: *Reply, d: *dbus.Decoder) anyerror!void,
    text: [256]u8 = undefined,
    text_len: usize = 0,
    int: i64 = 0,

    fn cb(ctx: ?*anyopaque, reply: dbus.Connection.Reply) void {
        const r: *Reply = @ptrCast(@alignCast(ctx));
        r.done = true;
        switch (reply) {
            .ok => |m| if (r.read) |f| {
                var d = m.body();
                f(r, &d) catch {
                    r.read_failed = true;
                };
            },
            else => r.err = true,
        }
    }

    fn isDone(r: *Reply) bool {
        return r.done;
    }

    fn setText(r: *Reply, s: []const u8) void {
        const n = @min(s.len, r.text.len);
        @memcpy(r.text[0..n], s[0..n]);
        r.text_len = n;
    }

    fn slice(r: *const Reply) []const u8 {
        return r.text[0..r.text_len];
    }
};

fn readStringVariant(r: *Reply, d: *dbus.Decoder) anyerror!void {
    _ = try d.beginVariant();
    r.setText(try d.readString());
}

fn readPixmapVariant(r: *Reply, d: *dbus.Decoder) anyerror!void {
    _ = try d.beginVariant();
    const a = try d.beginArray();
    var n: i64 = 0;
    while (a.next(d)) {
        try d.beginStruct();
        const w = try d.readInt32();
        const hgt = try d.readInt32();
        const bytes = try d.readFixedArray();
        try d.endStruct();
        n += 1;
        r.int = w * 1000 + hgt;
        r.setText(bytes);
    }
}

fn ownsName(w: *Watcher) bool {
    return w.owns();
}

fn registeredOnce(h: *Harness) bool {
    return h.eventCount(.registered) >= 1;
}

test "an item registers with the watcher and serves its properties and menu" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.watcher.start();
    try h.until(&h.watcher, ownsName);
    try h.item.start(&h.item_conn, .{ .id = "org.example.Tray", .title = "Example", .icon_name = "mail-unread", .icon_theme_path = "/opt/example/icons" });
    try h.until(&h, registeredOnce);
    // By its well-known name.
    try testing.expectEqual(@as(usize, 1), h.watcher.items.items.len);
    try testing.expect(std.mem.indexOf(u8, h.watcher.items.items[0], " org.kde.StatusNotifierItem-") != null);
    const name = h.item.owner.name;

    const props = "org.freedesktop.DBus.Properties";
    var r = try h.call(name, Item.path, props, "Get", .{ Item.interface, "IconName" }, readStringVariant);
    try testing.expectEqualStrings("mail-unread", r.slice());
    // Where the host finds the application's own icons (D19).
    r = try h.call(name, Item.path, props, "Get", .{ Item.interface, "IconThemePath" }, readStringVariant);
    try testing.expectEqualStrings("/opt/example/icons", r.slice());
    try h.item.setIconThemePath("/opt/other");
    r = try h.call(name, Item.path, props, "Get", .{ Item.interface, "IconThemePath" }, readStringVariant);
    try testing.expectEqualStrings("/opt/other", r.slice());
    r = try h.call(name, Item.path, props, "Get", .{ Item.interface, "Status" }, readStringVariant);
    try testing.expectEqualStrings("Active", r.slice());
    h.item.setStatus(.needs_attention);
    r = try h.call(name, Item.path, props, "Get", .{ Item.interface, "Status" }, readStringVariant);
    try testing.expectEqualStrings("NeedsAttention", r.slice());

    // A 2x1 pixmap goes out as given.
    const argb = [_]u8{ 255, 1, 2, 3, 128, 4, 5, 6 };
    try h.item.setIcon("", .{ .width = 2, .height = 1, .argb = &argb });
    r = try h.call(name, Item.path, props, "Get", .{ Item.interface, "IconPixmap" }, readPixmapVariant);
    try testing.expectEqual(@as(i64, 2001), r.int);
    try testing.expectEqualSlices(u8, &argb, r.slice());
    try testing.expectError(error.InvalidArgument, h.item.setIcon("x", .{ .width = 3, .height = 1, .argb = &argb }));

    // Events from the host.
    _ = try h.call(name, Item.path, Item.interface, "ProvideXdgActivationToken", .{"tok-1"}, null);
    _ = try h.call(name, Item.path, Item.interface, "Activate", .{ @as(i32, 5), @as(i32, 6) }, null);
    try testing.expectEqual(@as(i32, 5), h.last().activate.x);
    try testing.expectEqualStrings("tok-1", h.token[0..h.token_len]);
    // The token is used once.
    _ = try h.call(name, Item.path, Item.interface, "Activate", .{ @as(i32, 0), @as(i32, 0) }, null);
    try testing.expectEqual(@as(usize, 0), h.token_len);
    _ = try h.call(name, Item.path, Item.interface, "Scroll", .{ @as(i32, -2), "Horizontal" }, null);
    try testing.expectEqual(@as(i32, -2), h.last().scroll.delta);
    try testing.expect(h.last().scroll.horizontal);
    _ = try h.call(name, Item.path, Item.interface, "SecondaryActivate", .{ @as(i32, 1), @as(i32, 2) }, null);
    try testing.expectEqual(@as(i32, 2), h.last().secondary_activate.y);
}

fn readLayoutRevision(r: *Reply, d: *dbus.Decoder) anyerror!void {
    r.int = try d.readUint32();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeNode(d, &out);
    r.setText(out.items);
}

/// "id{key=value,...}[child child]" for a (ia{sv}av) node.
fn writeNode(d: *dbus.Decoder, out: *std.ArrayList(u8)) anyerror!void {
    try d.beginStruct();
    try out.print(gpa, "{d}{{", .{try d.readInt32()});
    const pa = try d.beginArray();
    var first = true;
    while (pa.next(d)) {
        try d.beginDictEntry();
        const key = try d.readString();
        const sig = try d.beginVariant();
        if (!first) try out.append(gpa, ',');
        first = false;
        if (std.mem.eql(u8, sig, "s")) try out.print(gpa, "{s}={s}", .{ key, try d.readString() }) else if (std.mem.eql(u8, sig, "i")) try out.print(gpa, "{s}={d}", .{ key, try d.readInt32() }) else if (std.mem.eql(u8, sig, "b")) try out.print(gpa, "{s}={}", .{ key, try d.readBool() }) else return error.UnexpectedType;
        try d.endVariant();
        try d.endDictEntry();
    }
    try d.endArray(pa);
    try out.append(gpa, '}');
    const ca = try d.beginArray();
    var any = false;
    while (ca.next(d)) {
        try out.append(gpa, if (any) ' ' else '[');
        any = true;
        _ = try d.beginVariant();
        try writeNode(d, out);
        try d.endVariant();
    }
    try d.endArray(ca);
    if (any) try out.append(gpa, ']');
    try d.endStruct();
}

test "the menu's layout, properties, and clicks follow dbusmenu" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.item.start(&h.item_conn, .{ .id = "org.example.Tray" });
    const m = &h.item.menu;
    try m.set(.{ .id = 1, .label = "_Open" });
    try m.set(.{ .id = 2, .kind = .separator });
    try m.set(.{ .id = 3, .label = "Mode" });
    try m.set(.{ .id = 4, .parent = 3, .label = "Fast", .kind = .radio, .checked = true });
    try m.set(.{ .id = 5, .parent = 3, .label = "Slow", .kind = .radio, .enabled = false });
    try m.set(.{ .id = 6, .label = "Quit", .icon_name = "application-exit" });
    try testing.expectError(error.InvalidArgument, m.set(.{ .id = 7, .parent = 99 }));
    try testing.expectError(error.InvalidArgument, m.set(.{ .id = 3, .parent = 4 }));
    try testing.expectError(error.InvalidArgument, m.set(.{ .id = 0 }));

    try h.until(&h.item_conn, hasUniqueName);
    const dest = h.item_conn.uniqueName();
    var r = try h.call(dest, Menu.path, Menu.interface, "GetLayout", .{ @as(i32, 0), @as(i32, -1), @as([]const []const u8, &.{}) }, readLayoutRevision);
    try testing.expectEqualStrings("0{children-display=submenu}[1{label=_Open} 2{type=separator} 3{children-display=submenu,label=Mode}[4{label=Fast,toggle-type=radio,toggle-state=1} 5{label=Slow,toggle-type=radio,toggle-state=0,enabled=false}] 6{label=Quit,icon-name=application-exit}]", r.slice());
    const rev = r.int;
    // One level, and only the labels.
    r = try h.call(dest, Menu.path, Menu.interface, "GetLayout", .{ @as(i32, 3), @as(i32, 0), @as([]const []const u8, &.{"label"}) }, readLayoutRevision);
    try testing.expectEqualStrings("3{label=Mode}", r.slice());

    // A change bumps the revision; removing an entry removes its children.
    m.remove(3);
    r = try h.call(dest, Menu.path, Menu.interface, "GetLayout", .{ @as(i32, 0), @as(i32, -1), @as([]const []const u8, &.{"label"}) }, readLayoutRevision);
    try testing.expectEqualStrings("0{}[1{label=_Open} 2{} 6{label=Quit}]", r.slice());
    try testing.expect(r.int > rev);
    try testing.expectError(error.ErrorReply, h.call(dest, Menu.path, Menu.interface, "GetLayout", .{ @as(i32, 4), @as(i32, -1), @as([]const []const u8, &.{}) }, null));

    _ = try h.call(dest, Menu.path, Menu.interface, "Event", .{ @as(i32, 6), "clicked", dbus.variant(@as(i32, 0)), @as(u32, 0) }, null);
    try testing.expectEqual(@as(i32, 6), h.last().menu);
    // Hovering is not a click.
    _ = try h.call(dest, Menu.path, Menu.interface, "Event", .{ @as(i32, 1), "hovered", dbus.variant(@as(i32, 0)), @as(u32, 0) }, null);
    try testing.expectEqual(@as(i32, 6), h.last().menu);
    r = try h.call(dest, Menu.path, Menu.interface, "GetProperty", .{ @as(i32, 6), "icon-name" }, readStringVariant);
    try testing.expectEqualStrings("application-exit", r.slice());
}

fn hasUniqueName(c: *dbus.Connection) bool {
    return c.uniqueName().len > 0;
}

fn unregisteredOnce(h: *Harness) bool {
    return h.eventCount(.unregistered) >= 1;
}

fn registeredTwice(h: *Harness) bool {
    return h.eventCount(.registered) >= 2;
}

fn unregisteredTwice(h: *Harness) bool {
    return h.eventCount(.unregistered) >= 2;
}

test "without a watcher the item is unregistered until one appears" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.item.start(&h.item_conn, .{ .id = "org.example.Tray" });
    try h.until(&h, unregisteredOnce);
    try testing.expectEqual(@as(usize, 0), h.eventCount(.registered));
    // A desktop shell starts: the item registers.
    try h.watcher.start();
    try h.until(&h, registeredOnce);
    // It exits: the item is unregistered; another starts: registered again.
    h.watcher.stop();
    try h.until(&h, unregisteredTwice);
    try h.watcher.start();
    try h.until(&h, registeredTwice);
    try testing.expectEqual(@as(usize, 2), h.watcher.items.items.len);
}

test "a watcher that refuses the item leaves it unregistered" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.watcher.refuse = true;
    try h.watcher.start();
    try h.until(&h.watcher, ownsName);
    try h.item.start(&h.item_conn, .{ .id = "org.example.Tray" });
    try h.until(&h, unregisteredOnce);
    try testing.expect(!h.item.registered);
}
