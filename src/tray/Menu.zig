//! A tray item's menu as com.canonical.dbusmenu (version 3), the menu
//! protocol StatusNotifierItem hosts read. Entries form a tree by parent
//! id (0 is the root); siblings keep the order they were first set in.
//! A change bumps the layout revision and announces it with one
//! LayoutUpdated per dispatch; hosts then read the layout again.

const std = @import("std");
const dbus = @import("dbus");
const Loop = @import("loop").Loop;

const Menu = @This();
const Allocator = std.mem.Allocator;
const Encoder = dbus.Encoder;

pub const interface = "com.canonical.dbusmenu";
pub const path = "/MenuBar";

pub const Kind = enum { normal, separator, check, radio };

/// An entry as set: strings are copied.
pub const Entry = struct {
    /// Positive and unique in the menu.
    id: i32,
    /// The entry it is in; 0 for the top level.
    parent: i32 = 0,
    label: []const u8 = "",
    icon_name: []const u8 = "",
    kind: Kind = .normal,
    enabled: bool = true,
    visible: bool = true,
    /// Check and radio entries.
    checked: bool = false,
};

gpa: Allocator,
conn: ?*dbus.Connection = null,
entries: std.ArrayList(Entry) = .empty,
revision: u32 = 1,
/// Runs `clicked` with the entry's id.
clicked: ?*const fn (m: *Menu, id: i32) void = null,
announce: Loop.Task = .{ .func = onAnnounce },

pub fn init(gpa: Allocator) Menu {
    return .{ .gpa = gpa };
}

pub fn deinit(m: *Menu) void {
    if (m.conn) |c| c.loop.unschedule(&m.announce);
    for (m.entries.items) |e| m.freeEntry(e);
    m.entries.deinit(m.gpa);
}

fn freeEntry(m: *Menu, e: Entry) void {
    m.gpa.free(e.label);
    m.gpa.free(e.icon_name);
}

fn index(m: *const Menu, id: i32) ?usize {
    for (m.entries.items, 0..) |e, i| if (e.id == id) return i;
    return null;
}

pub const Error = Allocator.Error || error{InvalidArgument};

/// Adds an entry, or replaces the one with its id.
pub fn set(m: *Menu, entry: Entry) Error!void {
    if (entry.id <= 0 or entry.parent < 0 or entry.parent == entry.id) return error.InvalidArgument;
    if (entry.parent != 0) {
        // The parent must exist and not be inside the entry.
        var p = entry.parent;
        while (p != 0) {
            const i = m.index(p) orelse return error.InvalidArgument;
            if (p == entry.id) return error.InvalidArgument;
            p = m.entries.items[i].parent;
        }
    }
    const label = try m.gpa.dupe(u8, entry.label);
    errdefer m.gpa.free(label);
    const icon = try m.gpa.dupe(u8, entry.icon_name);
    errdefer m.gpa.free(icon);
    var e = entry;
    e.label = label;
    e.icon_name = icon;
    if (m.index(entry.id)) |i| {
        m.freeEntry(m.entries.items[i]);
        m.entries.items[i] = e;
    } else try m.entries.append(m.gpa, e);
    m.changed();
}

/// Removes an entry and everything in it.
pub fn remove(m: *Menu, id: i32) void {
    const i = m.index(id) orelse return;
    const e = m.entries.orderedRemove(i);
    m.freeEntry(e);
    while (true) {
        const child = for (m.entries.items) |c| {
            if (c.parent == id) break c.id;
        } else break;
        m.remove(child);
    }
    m.changed();
}

pub fn clear(m: *Menu) void {
    for (m.entries.items) |e| m.freeEntry(e);
    m.entries.clearRetainingCapacity();
    m.changed();
}

fn changed(m: *Menu) void {
    m.revision +%= 1;
    if (m.conn) |c| c.loop.schedule(&m.announce, .dispatch);
}

fn onAnnounce(task: *Loop.Task) void {
    const m: *Menu = @fieldParentPtr("announce", task);
    const c = m.conn orelse return;
    c.emitSignal(path, interface, "LayoutUpdated", .{ m.revision, @as(i32, 0) }) catch {};
}

fn hasChildren(m: *const Menu, id: i32) bool {
    for (m.entries.items) |e| if (e.parent == id) return true;
    return false;
}

fn wanted(names: []const []const u8, name: []const u8) bool {
    if (names.len == 0) return true;
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Writes the a{sv} of entry `id` (0 is the root), with the properties
/// in `names` (all if empty) that differ from dbusmenu's defaults.
fn writeProperties(m: *const Menu, e: *Encoder, id: i32, names: []const []const u8) dbus.codec.EncodeError!void {
    try e.beginArray("{sv}");
    const W = struct {
        fn put(enc: *Encoder, key: []const u8, value: anytype) dbus.codec.EncodeError!void {
            try enc.beginDictEntry();
            try enc.writeString(key);
            try enc.beginVariant(comptime dbus.codec.signatureOf(@TypeOf(value)));
            try enc.write(value);
            try enc.endVariant();
            try enc.endDictEntry();
        }
    };
    if (m.hasChildren(id) and wanted(names, "children-display")) try W.put(e, "children-display", @as([]const u8, "submenu"));
    if (m.index(id)) |i| {
        const it = m.entries.items[i];
        if (it.kind == .separator) {
            if (wanted(names, "type")) try W.put(e, "type", @as([]const u8, "separator"));
        } else {
            if (wanted(names, "label")) try W.put(e, "label", it.label);
            if (it.icon_name.len > 0 and wanted(names, "icon-name")) try W.put(e, "icon-name", it.icon_name);
            if (it.kind == .check or it.kind == .radio) {
                if (wanted(names, "toggle-type")) try W.put(e, "toggle-type", @as([]const u8, if (it.kind == .check) "checkmark" else "radio"));
                if (wanted(names, "toggle-state")) try W.put(e, "toggle-state", @as(i32, @intFromBool(it.checked)));
            }
        }
        if (!it.enabled and wanted(names, "enabled")) try W.put(e, "enabled", false);
        if (!it.visible and wanted(names, "visible")) try W.put(e, "visible", false);
    }
    try e.endArray();
}

/// Writes the (ia{sv}av) layout of entry `id`, `depth` levels down (-1
/// for all).
fn writeLayout(m: *const Menu, e: *Encoder, id: i32, depth: i32, names: []const []const u8) dbus.codec.EncodeError!void {
    try e.beginStruct();
    try e.writeInt32(id);
    try m.writeProperties(e, id, names);
    try e.beginArray("v");
    if (depth != 0) for (m.entries.items) |c| {
        if (c.parent != id) continue;
        try e.beginVariant("(ia{sv}av)");
        try m.writeLayout(e, c.id, if (depth < 0) depth else depth - 1, names);
        try e.endVariant();
    };
    try e.endArray();
    try e.endStruct();
}

fn readNames(d: *dbus.Decoder, buf: [][]const u8) ![]const []const u8 {
    var n: usize = 0;
    const a = try d.beginArray();
    while (a.next(d)) {
        const s = try d.readString();
        if (n < buf.len) {
            buf[n] = s;
            n += 1;
        }
    }
    try d.endArray(a);
    return buf[0..n];
}

fn menuOf(r: *dbus.Request) *Menu {
    return @ptrCast(@alignCast(r.node.ctx));
}

fn getLayout(r: *dbus.Request) anyerror!void {
    const m = menuOf(r);
    var d = r.args();
    const parent = try d.readInt32();
    const depth = try d.readInt32();
    var buf: [32][]const u8 = undefined;
    const names = try readNames(&d, &buf);
    if (parent != 0 and m.index(parent) == null) return r.replyError("com.canonical.dbusmenu.Error.UnknownId", "no such menu entry");
    var b = r.newReply();
    errdefer b.deinit();
    try b.body.writeUint32(m.revision);
    try m.writeLayout(&b.body, parent, depth, names);
    try r.sendReply(&b);
}

fn getGroupProperties(r: *dbus.Request) anyerror!void {
    const m = menuOf(r);
    var d = r.args();
    const ids_d = d;
    try d.skip();
    var buf: [32][]const u8 = undefined;
    const names = try readNames(&d, &buf);
    var b = r.newReply();
    errdefer b.deinit();
    try b.body.beginArray("(ia{sv})");
    var ids = ids_d;
    const a = try ids.beginArray();
    var any = false;
    while (a.next(&ids)) {
        any = true;
        const id = try ids.readInt32();
        if (id != 0 and m.index(id) == null) continue;
        try b.body.beginStruct();
        try b.body.writeInt32(id);
        try m.writeProperties(&b.body, id, names);
        try b.body.endStruct();
    }
    // No ids: every entry.
    if (!any) for (m.entries.items) |e| {
        try b.body.beginStruct();
        try b.body.writeInt32(e.id);
        try m.writeProperties(&b.body, e.id, names);
        try b.body.endStruct();
    };
    try b.body.endArray();
    try r.sendReply(&b);
}

fn getProperty(r: *dbus.Request) anyerror!void {
    const m = menuOf(r);
    var d = r.args();
    const id = try d.readInt32();
    const name = try d.readString();
    if (id != 0 and m.index(id) == null) return r.replyError("com.canonical.dbusmenu.Error.UnknownId", "no such menu entry");
    // Find the property in the entry's a{sv} and copy its variant.
    var tmp: Encoder = .init(m.gpa);
    defer tmp.deinit();
    try m.writeProperties(&tmp, id, &.{name});
    var td: dbus.Decoder = .init(tmp.bytes(), "a{sv}", .little, &.{});
    const a = try td.beginArray();
    if (!a.next(&td)) return r.replyError("com.canonical.dbusmenu.Error.UnknownProperty", "the entry does not have this property");
    try td.beginDictEntry();
    _ = try td.readString();
    const sig = try td.beginVariant();
    var b = r.newReply();
    errdefer b.deinit();
    try b.body.beginVariant(sig);
    if (std.mem.eql(u8, sig, "s")) try b.body.writeString(try td.readString()) else if (std.mem.eql(u8, sig, "i")) try b.body.writeInt32(try td.readInt32()) else try b.body.writeBool(try td.readBool());
    try b.body.endVariant();
    try r.sendReply(&b);
}

fn event(r: *dbus.Request) anyerror!void {
    const m = menuOf(r);
    var d = r.args();
    const id = try d.readInt32();
    const name = try d.readString();
    if (m.index(id) == null) return r.replyError("com.canonical.dbusmenu.Error.UnknownId", "no such menu entry");
    try r.reply(.{});
    m.dispatchEvent(id, name);
}

fn eventGroup(r: *dbus.Request) anyerror!void {
    const m = menuOf(r);
    var d = r.args();
    var missing: [64]i32 = undefined;
    var n_missing: usize = 0;
    var clicked: [64]i32 = undefined;
    var n_clicked: usize = 0;
    const a = try d.beginArray();
    while (a.next(&d)) {
        try d.beginStruct();
        const id = try d.readInt32();
        const name = try d.readString();
        try d.skip();
        _ = try d.readUint32();
        try d.endStruct();
        if (m.index(id) == null) {
            if (n_missing < missing.len) {
                missing[n_missing] = id;
                n_missing += 1;
            }
        } else if (std.mem.eql(u8, name, "clicked") and n_clicked < clicked.len) {
            clicked[n_clicked] = id;
            n_clicked += 1;
        }
    }
    try r.reply(.{@as([]const i32, missing[0..n_missing])});
    for (clicked[0..n_clicked]) |id| m.dispatchEvent(id, "clicked");
}

fn dispatchEvent(m: *Menu, id: i32, name: []const u8) void {
    if (!std.mem.eql(u8, name, "clicked")) return;
    if (m.clicked) |f| f(m, id);
}

fn aboutToShow(r: *dbus.Request) anyerror!void {
    // The menu is always up to date.
    try r.reply(.{false});
}

fn aboutToShowGroup(r: *dbus.Request) anyerror!void {
    try r.reply(.{ @as([]const i32, &.{}), @as([]const i32, &.{}) });
}

fn constProp(comptime name: []const u8, comptime sig: []const u8, comptime value: anytype) dbus.Property {
    return .{ .name = name, .signature = sig, .emits_changed = .@"const", .get = struct {
        fn get(_: dbus.object.PropertyContext, e: *Encoder) anyerror!void {
            try e.write(value);
        }
    }.get };
}

pub const iface: dbus.Interface = .{
    .name = interface,
    .methods = &.{
        .{ .name = "GetLayout", .in = "iias", .out = "u(ia{sv}av)", .in_names = &.{ "parentId", "recursionDepth", "propertyNames" }, .out_names = &.{ "revision", "layout" }, .func = getLayout },
        .{ .name = "GetGroupProperties", .in = "aias", .out = "a(ia{sv})", .in_names = &.{ "ids", "propertyNames" }, .out_names = &.{"properties"}, .func = getGroupProperties },
        .{ .name = "GetProperty", .in = "is", .out = "v", .in_names = &.{ "id", "name" }, .out_names = &.{"value"}, .func = getProperty },
        .{ .name = "Event", .in = "isvu", .in_names = &.{ "id", "eventId", "data", "timestamp" }, .func = event },
        .{ .name = "EventGroup", .in = "a(isvu)", .out = "ai", .in_names = &.{"events"}, .out_names = &.{"idErrors"}, .func = eventGroup },
        .{ .name = "AboutToShow", .in = "i", .out = "b", .in_names = &.{"id"}, .out_names = &.{"needUpdate"}, .func = aboutToShow },
        .{ .name = "AboutToShowGroup", .in = "ai", .out = "aiai", .in_names = &.{"ids"}, .out_names = &.{ "updatesNeeded", "idErrors" }, .func = aboutToShowGroup },
    },
    .properties = &.{
        constProp("Version", "u", @as(u32, 3)),
        constProp("TextDirection", "s", @as([]const u8, "ltr")),
        constProp("Status", "s", @as([]const u8, "normal")),
        constProp("IconThemePath", "as", @as([]const []const u8, &.{})),
    },
    .signals = &.{
        .{ .name = "ItemsPropertiesUpdated", .signature = "a(ia{sv})a(ias)", .arg_names = &.{ "updatedProps", "removedProps" } },
        .{ .name = "LayoutUpdated", .signature = "ui", .arg_names = &.{ "revision", "parent" } },
        .{ .name = "ItemActivationRequested", .signature = "iu", .arg_names = &.{ "id", "timestamp" } },
    },
};
