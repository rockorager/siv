//! A tray icon: an org.kde.StatusNotifierItem at /StatusNotifierItem with
//! its menu (Menu.zig) at /MenuBar, registered with the desktop's
//! org.kde.StatusNotifierWatcher.
//!
//! The item asks for the well-known name org.kde.StatusNotifierItem-
//! <pid>-<n> and registers it; where that name cannot be had (a Flatpak
//! sandbox may not allow it) it registers its object path, which
//! watchers pair with the connection's unique name. It registers again
//! whenever a watcher appears and reports `unregistered` while none
//! runs, so an application can fall back to something else (a window).
//!
//! Properties follow the specification's change signals (NewIcon,
//! NewTitle, ...) rather than PropertiesChanged. Events come from the
//! host: Activate, SecondaryActivate, ContextMenu, Scroll, menu clicks,
//! and KDE's ProvideXdgActivationToken, whose token goes with the next
//! activation.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus");
const Menu = @import("Menu.zig");

const Item = @This();
const Allocator = std.mem.Allocator;
const Connection = dbus.Connection;
const Encoder = dbus.Encoder;

pub const interface = "org.kde.StatusNotifierItem";
pub const path = "/StatusNotifierItem";
pub const watcher_name = "org.kde.StatusNotifierWatcher";
pub const watcher_path = "/StatusNotifierWatcher";

pub const Status = enum { passive, active, needs_attention };
pub const Category = enum { application_status, communications, system_services, hardware };

/// An icon image: ARGB32 pixels in network byte order (A, R, G, B bytes),
/// straight alpha, rows packed, as the specification's IconPixmap.
pub const Pixmap = struct {
    width: i32,
    height: i32,
    argb: []const u8,
};

pub const Event = union(enum) {
    /// A watcher accepted the item: a host may show it.
    registered,
    /// No watcher runs, or it refused the item.
    unregistered,
    /// Primary activation (a click), at screen coordinates if known, with
    /// the xdg-activation token the host provided or "".
    activate: struct { x: i32, y: i32, token: []const u8 },
    secondary_activate: struct { x: i32, y: i32 },
    /// The host asks for a context menu the item draws itself (only when
    /// it has no menu entries).
    context_menu: struct { x: i32, y: i32 },
    scroll: struct { delta: i32, horizontal: bool },
    /// A menu entry was clicked.
    menu: i32,
};

pub const Options = struct {
    /// Unique to the application, stable across runs; the application id.
    id: []const u8,
    title: []const u8 = "",
    icon_name: []const u8 = "",
    category: Category = .application_status,
    status: Status = .active,
    /// Activation shows the menu instead of sending Activate.
    item_is_menu: bool = false,
};

gpa: Allocator,
conn: *Connection = undefined,
func: *const fn (item: *Item, event: Event) void,
id: []u8 = &.{},
title: []u8 = &.{},
icon_name: []u8 = &.{},
icon: []u8 = &.{},
icon_size: [2]i32 = .{ 0, 0 },
attention_icon_name: []u8 = &.{},
attention_icon: []u8 = &.{},
attention_size: [2]i32 = .{ 0, 0 },
tooltip_title: []u8 = &.{},
tooltip_body: []u8 = &.{},
category: Category = .application_status,
status: Status = .active,
item_is_menu: bool = false,
menu: Menu,
obj: dbus.Object = undefined,
menu_obj: dbus.Object = undefined,
name_buf: [64]u8 = undefined,
owner: Connection.NameOwner = .{ .name = "" },
watch: Connection.NameWatch = .{ .name = watcher_name },
/// The RegisterStatusNotifierItem call in flight.
register_serial: u32 = 0,
registered: bool = false,
started: bool = false,
token_buf: [256]u8 = undefined,
token_len: usize = 0,

var next_instance: std.atomic.Value(u32) = .init(1);

pub fn init(gpa: Allocator, func: *const fn (item: *Item, event: Event) void) Item {
    return .{ .gpa = gpa, .func = func, .menu = .init(gpa) };
}

/// Exports the item and its menu and registers with the watcher. The
/// item stays in place until `deinit`.
pub fn start(it: *Item, conn: *Connection, o: Options) (Connection.Error || Allocator.Error || error{InvalidArgument})!void {
    if (o.id.len == 0) return error.InvalidArgument;
    it.conn = conn;
    try replace(it.gpa, &it.id, o.id);
    try replace(it.gpa, &it.title, o.title);
    try replace(it.gpa, &it.icon_name, o.icon_name);
    it.category = o.category;
    it.status = o.status;
    it.item_is_menu = o.item_is_menu;
    it.menu.conn = conn;
    it.menu.clicked = onClicked;
    it.obj = .{ .path = path, .ctx = it, .interfaces = &.{&iface} };
    it.menu_obj = .{ .path = Menu.path, .ctx = &it.menu, .interfaces = &.{&Menu.iface} };
    try conn.exportObject(&it.obj);
    errdefer conn.unexportObject(&it.obj);
    try conn.exportObject(&it.menu_obj);
    errdefer conn.unexportObject(&it.menu_obj);
    const name = std.fmt.bufPrint(&it.name_buf, "org.kde.StatusNotifierItem-{d}-{d}", .{ linux.getpid(), next_instance.fetchAdd(1, .monotonic) }) catch unreachable;
    it.owner = .{ .name = name, .flags = .{ .do_not_queue = true }, .func = onOwner };
    try conn.requestName(&it.owner);
    errdefer conn.releaseName(&it.owner);
    it.watch = .{ .name = watcher_name, .func = onWatcher };
    try conn.watchName(&it.watch);
    it.started = true;
}

pub fn deinit(it: *Item) void {
    if (it.started) {
        const c = it.conn;
        c.unwatchName(&it.watch);
        if (it.register_serial != 0) c.cancelCall(it.register_serial);
        c.releaseName(&it.owner);
        c.unexportObject(&it.obj);
        c.unexportObject(&it.menu_obj);
    }
    it.menu.deinit();
    inline for (.{ "id", "title", "icon_name", "icon", "attention_icon_name", "attention_icon", "tooltip_title", "tooltip_body" }) |f| it.gpa.free(@field(it, f));
    it.started = false;
}

fn replace(gpa: Allocator, field: *[]u8, value: []const u8) Allocator.Error!void {
    const copy = try gpa.dupe(u8, value);
    gpa.free(field.*);
    field.* = copy;
}

fn emit(it: *Item, member: []const u8, args: anytype) void {
    if (it.started) it.conn.emitSignal(path, interface, member, args) catch {};
}

pub fn setTitle(it: *Item, title: []const u8) Allocator.Error!void {
    try replace(it.gpa, &it.title, title);
    it.emit("NewTitle", .{});
}

pub fn setStatus(it: *Item, status: Status) void {
    if (it.status == status) return;
    it.status = status;
    it.emit("NewStatus", .{statusName(status)});
}

/// Sets the icon: a themed name, an image, or both (hosts prefer the
/// name when their theme has it).
pub fn setIcon(it: *Item, name: []const u8, pixmap: ?Pixmap) (Allocator.Error || error{InvalidArgument})!void {
    try setImage(it.gpa, &it.icon_name, &it.icon, &it.icon_size, name, pixmap);
    it.emit("NewIcon", .{});
}

/// The icon shown while the status is needs_attention.
pub fn setAttentionIcon(it: *Item, name: []const u8, pixmap: ?Pixmap) (Allocator.Error || error{InvalidArgument})!void {
    try setImage(it.gpa, &it.attention_icon_name, &it.attention_icon, &it.attention_size, name, pixmap);
    it.emit("NewAttentionIcon", .{});
}

fn setImage(gpa: Allocator, name_field: *[]u8, data: *[]u8, size: *[2]i32, name: []const u8, pixmap: ?Pixmap) (Allocator.Error || error{InvalidArgument})!void {
    if (pixmap) |p| {
        if (p.width <= 0 or p.height <= 0 or p.argb.len != @as(usize, @intCast(p.width)) * @as(usize, @intCast(p.height)) * 4) return error.InvalidArgument;
    }
    try replace(gpa, name_field, name);
    try replace(gpa, data, if (pixmap) |p| p.argb else "");
    size.* = if (pixmap) |p| .{ p.width, p.height } else .{ 0, 0 };
}

pub fn setToolTip(it: *Item, title: []const u8, body: []const u8) Allocator.Error!void {
    try replace(it.gpa, &it.tooltip_title, title);
    try replace(it.gpa, &it.tooltip_body, body);
    it.emit("NewToolTip", .{});
}

fn statusName(s: Status) []const u8 {
    return switch (s) {
        .passive => "Passive",
        .active => "Active",
        .needs_attention => "NeedsAttention",
    };
}

fn categoryName(c: Category) []const u8 {
    return switch (c) {
        .application_status => "ApplicationStatus",
        .communications => "Communications",
        .system_services => "SystemServices",
        .hardware => "Hardware",
    };
}

// Registration -------------------------------------------------------------------

fn onOwner(o: *Connection.NameOwner) void {
    const it: *Item = @fieldParentPtr("owner", o);
    if (o.state == .requesting) return;
    it.register();
}

fn onWatcher(w: *Connection.NameWatch) void {
    const it: *Item = @fieldParentPtr("watch", w);
    if (w.owner() == null) {
        if (it.register_serial != 0) it.conn.cancelCall(it.register_serial);
        it.register_serial = 0;
        const was = it.registered;
        it.registered = false;
        // Reported once the first lookup says no watcher runs, and when
        // one goes away.
        if (was or w.state == .unowned) it.func(it, .unregistered);
        return;
    }
    it.register();
}

/// Registers with the watcher once both the watcher and the name request
/// have answered.
fn register(it: *Item) void {
    if (it.watch.owner() == null or it.owner.state == .requesting or it.owner.state == .idle) return;
    if (it.register_serial != 0) it.conn.cancelCall(it.register_serial);
    const service: []const u8 = if (it.owner.state == .primary) it.owner.name else path;
    it.register_serial = it.conn.callMethod(watcher_name, watcher_path, watcher_name, "RegisterStatusNotifierItem", .{service}, onRegistered, it) catch {
        it.register_serial = 0;
        return;
    };
}

fn onRegistered(ctx: ?*anyopaque, reply: Connection.Reply) void {
    const it: *Item = @ptrCast(@alignCast(ctx));
    it.register_serial = 0;
    const ok = reply == .ok;
    if (ok == it.registered and ok) return;
    it.registered = ok;
    it.func(it, if (ok) .registered else .unregistered);
}

// The interface ------------------------------------------------------------------

fn itemOf(r: *dbus.Request) *Item {
    return @ptrCast(@alignCast(r.node.ctx));
}

fn ctxItem(ctx: dbus.object.PropertyContext) *Item {
    return @ptrCast(@alignCast(ctx.node.ctx));
}

fn onActivate(r: *dbus.Request) anyerror!void {
    const it = itemOf(r);
    var d = r.args();
    const xy = try d.readAll(struct { i32, i32 });
    try r.reply(.{});
    const token = it.token_buf[0..it.token_len];
    it.token_len = 0;
    it.func(it, .{ .activate = .{ .x = xy[0], .y = xy[1], .token = token } });
}

fn onSecondaryActivate(r: *dbus.Request) anyerror!void {
    const it = itemOf(r);
    var d = r.args();
    const xy = try d.readAll(struct { i32, i32 });
    try r.reply(.{});
    it.func(it, .{ .secondary_activate = .{ .x = xy[0], .y = xy[1] } });
}

fn onContextMenu(r: *dbus.Request) anyerror!void {
    const it = itemOf(r);
    var d = r.args();
    const xy = try d.readAll(struct { i32, i32 });
    try r.reply(.{});
    it.func(it, .{ .context_menu = .{ .x = xy[0], .y = xy[1] } });
}

fn onScroll(r: *dbus.Request) anyerror!void {
    const it = itemOf(r);
    var d = r.args();
    const a = try d.readAll(struct { i32, []const u8 });
    const horizontal = std.ascii.eqlIgnoreCase(a[1], "horizontal");
    try r.reply(.{});
    it.func(it, .{ .scroll = .{ .delta = a[0], .horizontal = horizontal } });
}

fn onProvideToken(r: *dbus.Request) anyerror!void {
    const it = itemOf(r);
    var d = r.args();
    const token = try d.readString();
    const n = @min(token.len, it.token_buf.len);
    @memcpy(it.token_buf[0..n], token[0..n]);
    it.token_len = n;
    try r.reply(.{});
}

fn onClicked(m: *Menu, id: i32) void {
    const it: *Item = @fieldParentPtr("menu", m);
    it.func(it, .{ .menu = id });
}

fn writePixmaps(e: *Encoder, data: []const u8, size: [2]i32) dbus.codec.EncodeError!void {
    try e.beginArray("(iiay)");
    if (data.len > 0) try e.write(.{ size[0], size[1], dbus.Bytes{ .bytes = data } });
    try e.endArray();
}

fn stringProp(comptime name: []const u8, comptime field: []const u8) dbus.Property {
    return .{ .name = name, .signature = "s", .emits_changed = .false, .get = struct {
        fn get(ctx: dbus.object.PropertyContext, e: *Encoder) anyerror!void {
            try e.writeString(@field(ctxItem(ctx), field));
        }
    }.get };
}

fn prop(comptime name: []const u8, comptime sig: []const u8, comptime get: fn (it: *Item, e: *Encoder) anyerror!void) dbus.Property {
    return .{ .name = name, .signature = sig, .emits_changed = .false, .get = struct {
        fn f(ctx: dbus.object.PropertyContext, e: *Encoder) anyerror!void {
            try get(ctxItem(ctx), e);
        }
    }.f };
}

pub const iface: dbus.Interface = .{
    .name = interface,
    .methods = &.{
        .{ .name = "ContextMenu", .in = "ii", .in_names = &.{ "x", "y" }, .func = onContextMenu },
        .{ .name = "Activate", .in = "ii", .in_names = &.{ "x", "y" }, .func = onActivate },
        .{ .name = "SecondaryActivate", .in = "ii", .in_names = &.{ "x", "y" }, .func = onSecondaryActivate },
        .{ .name = "Scroll", .in = "is", .in_names = &.{ "delta", "orientation" }, .func = onScroll },
        .{ .name = "ProvideXdgActivationToken", .in = "s", .in_names = &.{"token"}, .func = onProvideToken },
    },
    .properties = &.{
        prop("Category", "s", struct {
            fn f(it: *Item, e: *Encoder) anyerror!void {
                try e.writeString(categoryName(it.category));
            }
        }.f),
        stringProp("Id", "id"),
        stringProp("Title", "title"),
        prop("Status", "s", struct {
            fn f(it: *Item, e: *Encoder) anyerror!void {
                try e.writeString(statusName(it.status));
            }
        }.f),
        prop("WindowId", "i", struct {
            fn f(_: *Item, e: *Encoder) anyerror!void {
                try e.writeInt32(0);
            }
        }.f),
        prop("IconThemePath", "s", struct {
            fn f(_: *Item, e: *Encoder) anyerror!void {
                try e.writeString("");
            }
        }.f),
        stringProp("IconName", "icon_name"),
        prop("IconPixmap", "a(iiay)", struct {
            fn f(it: *Item, e: *Encoder) anyerror!void {
                try writePixmaps(e, it.icon, it.icon_size);
            }
        }.f),
        prop("OverlayIconName", "s", struct {
            fn f(_: *Item, e: *Encoder) anyerror!void {
                try e.writeString("");
            }
        }.f),
        prop("OverlayIconPixmap", "a(iiay)", struct {
            fn f(_: *Item, e: *Encoder) anyerror!void {
                try writePixmaps(e, "", .{ 0, 0 });
            }
        }.f),
        stringProp("AttentionIconName", "attention_icon_name"),
        prop("AttentionIconPixmap", "a(iiay)", struct {
            fn f(it: *Item, e: *Encoder) anyerror!void {
                try writePixmaps(e, it.attention_icon, it.attention_size);
            }
        }.f),
        prop("AttentionMovieName", "s", struct {
            fn f(_: *Item, e: *Encoder) anyerror!void {
                try e.writeString("");
            }
        }.f),
        prop("ToolTip", "(sa(iiay)ss)", struct {
            fn f(it: *Item, e: *Encoder) anyerror!void {
                try e.beginStruct();
                try e.writeString("");
                try writePixmaps(e, "", .{ 0, 0 });
                try e.writeString(it.tooltip_title);
                try e.writeString(it.tooltip_body);
                try e.endStruct();
            }
        }.f),
        prop("ItemIsMenu", "b", struct {
            fn f(it: *Item, e: *Encoder) anyerror!void {
                try e.writeBool(it.item_is_menu);
            }
        }.f),
        prop("Menu", "o", struct {
            fn f(_: *Item, e: *Encoder) anyerror!void {
                try e.writeObjectPath(Menu.path);
            }
        }.f),
    },
    .signals = &.{
        .{ .name = "NewTitle" },
        .{ .name = "NewIcon" },
        .{ .name = "NewAttentionIcon" },
        .{ .name = "NewOverlayIcon" },
        .{ .name = "NewToolTip" },
        .{ .name = "NewStatus", .signature = "s", .arg_names = &.{"status"} },
    },
};
