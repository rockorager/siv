//! A stand-in for xdg-desktop-portal's Settings interface, for the tests
//! against the test bus and against dbus-daemon. Not part of libsiv.

const std = @import("std");
const Connection = @import("Connection.zig");
const object = @import("object.zig");
const codec = @import("codec.zig");
const Settings = @import("Settings.zig");

pub const FakePortal = struct {
    conn: *Connection,
    owner: Connection.NameOwner = .{ .name = Settings.portal_name },
    obj: object.Object = undefined,
    color_scheme: u32 = 1,
    reads: u32 = 0,
    /// The namespaces the last ReadAll asked for, joined with ",".
    asked: [256]u8 = undefined,
    asked_len: usize = 0,

    const iface: object.Interface = .{
        .name = Settings.portal_interface,
        .methods = &.{.{ .name = "ReadAll", .in = "as", .out = "a{sa{sv}}", .func = readAll }},
        .signals = &.{.{ .name = "SettingChanged", .signature = "ssv" }},
    };

    pub fn start(p: *FakePortal) !void {
        const conn = p.conn;
        p.owner = .{ .name = Settings.portal_name };
        p.obj = .{ .path = Settings.portal_path, .ctx = p, .interfaces = &.{&iface} };
        try conn.exportObject(&p.obj);
        try conn.requestName(&p.owner);
    }

    pub fn stop(p: *FakePortal) void {
        p.conn.releaseName(&p.owner);
        p.conn.unexportObject(&p.obj);
    }

    pub fn owns(p: *FakePortal) bool {
        return p.owner.state == .primary;
    }

    fn readAll(r: *object.Request) anyerror!void {
        const p: *FakePortal = @ptrCast(@alignCast(r.node.ctx));
        p.reads += 1;
        var d = r.args();
        const arr = try d.beginArray();
        p.asked_len = 0;
        while (arr.next(&d)) {
            const ns = try d.readString();
            if (p.asked_len > 0) p.append(",");
            p.append(ns);
        }
        const E = codec.DictEntry([]const u8, Value);
        const appearance = [_]E{
            .{ .key = "color-scheme", .value = .{ .u = p.color_scheme } },
            .{ .key = "accent-color", .value = .{ .rgb = .{ 0.2, 0.4, 0.8 } } },
            .{ .key = "reduced-motion", .value = .{ .u = 1 } },
            .{ .key = "unknown-key", .value = .{ .s = "ignored" } },
        };
        const gnome = [_]E{
            .{ .key = "font-name", .value = .{ .s = "Cantarell 11" } },
            .{ .key = "monospace-font-name", .value = .{ .s = "Source Code Pro 10" } },
            .{ .key = "cursor-theme", .value = .{ .s = "Adwaita" } },
            .{ .key = "cursor-size", .value = .{ .i = 32 } },
            .{ .key = "text-scaling-factor", .value = .{ .d = 1.5 } },
            // Contradicts reduced-motion above; the standard key wins.
            .{ .key = "enable-animations", .value = .{ .b = true } },
            .{ .key = "cursor-blink-time", .value = .{ .i = 1000 } },
        };
        const mouse = [_]E{.{ .key = "double-click", .value = .{ .i = 300 } }};
        // KDE's portal sends kdeglobals entries as strings.
        const kde = [_]E{.{ .key = "CursorBlinkRate", .value = .{ .s = "0" } }};
        // A theme GNOME's key does not name; GNOME's would win.
        const kde_icons = [_]E{.{ .key = "Theme", .value = .{ .s = "breeze" } }};
        var b = r.newReply();
        errdefer b.deinit();
        try b.body.beginArray("{sa{sv}}");
        for ([_]struct { []const u8, []const E }{ .{ "org.freedesktop.appearance", &appearance }, .{ "org.gnome.desktop.interface", &gnome }, .{ "org.gnome.desktop.peripherals.mouse", &mouse }, .{ "org.kde.kdeglobals.KDE", &kde }, .{ "org.kde.kdeglobals.Icons", &kde_icons } }) |ns| {
            try b.body.beginDictEntry();
            try b.body.writeString(ns[0]);
            try b.body.beginArray("{sv}");
            for (ns[1]) |e| {
                try b.body.beginDictEntry();
                try b.body.writeString(e.key);
                try e.value.write(&b.body);
                try b.body.endDictEntry();
            }
            try b.body.endArray();
            try b.body.endDictEntry();
        }
        try b.body.endArray();
        try r.sendReply(&b);
    }

    fn append(p: *FakePortal, s: []const u8) void {
        const n = @min(s.len, p.asked.len - p.asked_len);
        @memcpy(p.asked[p.asked_len..][0..n], s[0..n]);
        p.asked_len += n;
    }

    pub fn askedFor(p: *const FakePortal) []const u8 {
        return p.asked[0..p.asked_len];
    }

    pub const Value = union(enum) {
        u: u32,
        i: i32,
        d: f64,
        b: bool,
        s: []const u8,
        rgb: [3]f64,

        pub fn write(v: Value, e: *codec.Encoder) !void {
            switch (v) {
                .u => |x| try e.write(codec.variant(x)),
                .i => |x| try e.write(codec.variant(x)),
                .d => |x| try e.write(codec.variant(x)),
                .b => |x| try e.write(codec.variant(x)),
                .s => |x| try e.write(codec.variant(x)),
                .rgb => |x| try e.write(codec.variant(.{ x[0], x[1], x[2] })),
            }
        }
    };

    /// Emits SettingChanged.
    pub fn change(p: *FakePortal, namespace: []const u8, key: []const u8, value: Value) !void {
        var b = p.conn.signal(Settings.portal_path, Settings.portal_interface, "SettingChanged");
        errdefer b.deinit();
        try b.body.writeAll(.{ namespace, key });
        try value.write(&b.body);
        _ = try p.conn.send(&b);
    }
};

/// Records what a Settings client reported.
pub const Observer = struct {
    calls: usize = 0,
    last: Settings.Changed = .{},

    pub fn cb(ctx: ?*anyopaque, _: *Settings, changed: Settings.Changed) void {
        const o: *Observer = @ptrCast(@alignCast(ctx));
        o.calls += 1;
        o.last = changed;
    }
};
