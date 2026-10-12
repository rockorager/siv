//! Exported objects: interface descriptions (methods, properties, signals)
//! and introspection XML.
//!
//! Interfaces are static tables, usually comptime constants, so exporting
//! an object costs one registration and no per-method allocation. An
//! `Object` serves either one path or, with a `Subtree`, every path below
//! it through a lookup function: a large tree (an accessibility tree of
//! 100k nodes) is one registration whose nodes are resolved on demand from
//! the path, with no per-node state in the connection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const codec = @import("codec.zig");
const names = @import("names.zig");

pub const Interface = struct {
    name: []const u8,
    methods: []const Method = &.{},
    properties: []const Property = &.{},
    signals: []const Signal = &.{},

    pub fn findMethod(i: *const Interface, name: []const u8) ?*const Method {
        for (i.methods) |*m| if (std.mem.eql(u8, m.name, name)) return m;
        return null;
    }

    pub fn findProperty(i: *const Interface, name: []const u8) ?*const Property {
        for (i.properties) |*p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

pub const Method = struct {
    name: []const u8,
    /// Signatures of the arguments and the reply. A call whose body does
    /// not match `in` gets InvalidArgs without reaching `func`; a reply
    /// whose body does not match `out` is replaced with an error.
    in: []const u8 = "",
    out: []const u8 = "",
    /// Argument names for introspection, optional.
    in_names: []const []const u8 = &.{},
    out_names: []const []const u8 = &.{},
    /// Handles the call. It replies through the request (or defers the
    /// reply); returning without replying sends an empty reply when `out`
    /// is empty and an error otherwise. A returned error becomes an error
    /// reply (see `Request`).
    func: *const fn (req: *Request) anyerror!void,
    deprecated: bool = false,
};

pub const Property = struct {
    name: []const u8,
    signature: []const u8,
    access: Access = .read,
    /// Writes the value (not wrapped in a variant).
    get: ?*const fn (ctx: PropertyContext, out: *codec.Encoder) anyerror!void = null,
    /// Reads the value from inside the variant. The setter emits
    /// PropertiesChanged itself if the value changed.
    set: ?*const fn (ctx: PropertyContext, in: *codec.Decoder) anyerror!void = null,
    emits_changed: EmitsChanged = .true,

    pub const Access = enum { read, write, readwrite };
    pub const EmitsChanged = enum { true, invalidates, @"const", false };

    pub fn readable(p: *const Property) bool {
        return p.access != .write and p.get != null;
    }

    pub fn writable(p: *const Property) bool {
        return p.access != .read and p.set != null;
    }
};

pub const Signal = struct {
    name: []const u8,
    signature: []const u8 = "",
    arg_names: []const []const u8 = &.{},
    deprecated: bool = false,
};

/// A resolved object: what an `Object` or a `Subtree` lookup yields.
pub const Node = struct {
    ctx: ?*anyopaque = null,
    interfaces: []const *const Interface = &.{},

    pub fn findInterface(n: Node, name: []const u8) ?*const Interface {
        for (n.interfaces) |i| if (std.mem.eql(u8, i.name, name)) return i;
        return null;
    }
};

/// An exported object, owned by the caller and registered with
/// `Connection.exportObject`. `path` is borrowed while registered.
pub const Object = struct {
    path: []const u8,
    ctx: ?*anyopaque = null,
    interfaces: []const *const Interface = &.{},
    /// Serve the paths below `path` too.
    subtree: ?Subtree = null,
};

pub const Subtree = struct {
    /// Resolves `path`, which is `object.path` or below it, to a node, or
    /// null if no object lives there. Called for every incoming call, so it
    /// should be a cheap parse of the path.
    lookup: *const fn (object: *Object, path: []const u8) ?Node,
    /// Lists the names of the immediate children of `path` (a path at or
    /// below `object.path`) for introspection.
    children: ?*const fn (object: *Object, path: []const u8, out: *ChildList) Allocator.Error!void = null,
};

/// Child node names collected for introspection. Names are copied.
pub const ChildList = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    ends: std.ArrayList(u32) = .empty,

    pub fn add(l: *ChildList, name: []const u8) Allocator.Error!void {
        var it = l.iterator();
        while (it.next()) |n| if (std.mem.eql(u8, n, name)) return;
        try l.bytes.appendSlice(l.gpa, name);
        try l.ends.append(l.gpa, @intCast(l.bytes.items.len));
    }

    pub fn deinit(l: *ChildList) void {
        l.bytes.deinit(l.gpa);
        l.ends.deinit(l.gpa);
    }

    pub fn iterator(l: *const ChildList) Iterator {
        return .{ .list = l };
    }

    pub const Iterator = struct {
        list: *const ChildList,
        i: usize = 0,

        pub fn next(it: *Iterator) ?[]const u8 {
            if (it.i == it.list.ends.items.len) return null;
            const start = if (it.i == 0) 0 else it.list.ends.items[it.i - 1];
            defer it.i += 1;
            return it.list.bytes.items[start..it.list.ends.items[it.i]];
        }
    };
};

pub const PropertyContext = struct {
    path: []const u8,
    node: Node,
    interface: *const Interface,
};

/// An incoming method call being handled. Defined by the connection.
pub const Request = @import("Connection.zig").Request;

// Introspection ------------------------------------------------------------

pub const introspect_doctype =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\
;

const standard_interfaces =
    \\ <interface name="org.freedesktop.DBus.Peer">
    \\  <method name="Ping"/>
    \\  <method name="GetMachineId">
    \\   <arg type="s" name="machine_uuid" direction="out"/>
    \\  </method>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Introspectable">
    \\  <method name="Introspect">
    \\   <arg type="s" name="xml_data" direction="out"/>
    \\  </method>
    \\ </interface>
    \\
;

const properties_interface =
    \\ <interface name="org.freedesktop.DBus.Properties">
    \\  <method name="Get">
    \\   <arg type="s" name="interface_name" direction="in"/>
    \\   <arg type="s" name="property_name" direction="in"/>
    \\   <arg type="v" name="value" direction="out"/>
    \\  </method>
    \\  <method name="GetAll">
    \\   <arg type="s" name="interface_name" direction="in"/>
    \\   <arg type="a{sv}" name="props" direction="out"/>
    \\  </method>
    \\  <method name="Set">
    \\   <arg type="s" name="interface_name" direction="in"/>
    \\   <arg type="s" name="property_name" direction="in"/>
    \\   <arg type="v" name="value" direction="in"/>
    \\  </method>
    \\  <signal name="PropertiesChanged">
    \\   <arg type="s" name="interface_name"/>
    \\   <arg type="a{sv}" name="changed_properties"/>
    \\   <arg type="as" name="invalidated_properties"/>
    \\  </signal>
    \\ </interface>
    \\
;

/// Writes the introspection document for a node (null for a path that only
/// has children) and its children.
pub fn introspect(gpa: Allocator, out: *std.ArrayList(u8), node: ?Node, children: *const ChildList) Allocator.Error!void {
    var w: std.Io.Writer.Allocating = .fromArrayList(gpa, out);
    defer out.* = w.toArrayList();
    writeXml(&w.writer, node, children) catch return error.OutOfMemory;
}

fn writeXml(w: *std.Io.Writer, node: ?Node, children: *const ChildList) std.Io.Writer.Error!void {
    try w.writeAll(introspect_doctype);
    try w.writeAll("<node>\n");
    try w.writeAll(standard_interfaces);
    if (node) |n| {
        var has_props = false;
        for (n.interfaces) |i| has_props = has_props or i.properties.len > 0;
        if (has_props) try w.writeAll(properties_interface);
        for (n.interfaces) |i| {
            try w.print(" <interface name=\"{s}\">\n", .{i.name});
            for (i.methods) |m| {
                try w.print("  <method name=\"{s}\">\n", .{m.name});
                try writeArgs(w, m.in, m.in_names, "in");
                try writeArgs(w, m.out, m.out_names, "out");
                if (m.deprecated) try w.writeAll("   <annotation name=\"org.freedesktop.DBus.Deprecated\" value=\"true\"/>\n");
                try w.writeAll("  </method>\n");
            }
            for (i.signals) |s| {
                try w.print("  <signal name=\"{s}\">\n", .{s.name});
                try writeArgs(w, s.signature, s.arg_names, null);
                if (s.deprecated) try w.writeAll("   <annotation name=\"org.freedesktop.DBus.Deprecated\" value=\"true\"/>\n");
                try w.writeAll("  </signal>\n");
            }
            for (i.properties) |p| {
                const access = switch (p.access) {
                    .read => "read",
                    .write => "write",
                    .readwrite => "readwrite",
                };
                try w.print("  <property name=\"{s}\" type=\"{s}\" access=\"{s}\"", .{ p.name, p.signature, access });
                if (p.emits_changed == .true) {
                    try w.writeAll("/>\n");
                } else {
                    try w.print(">\n   <annotation name=\"org.freedesktop.DBus.Property.EmitsChangedSignal\" value=\"{t}\"/>\n  </property>\n", .{p.emits_changed});
                }
            }
            try w.writeAll(" </interface>\n");
        }
    }
    var it = children.iterator();
    while (it.next()) |c| try w.print(" <node name=\"{s}\"/>\n", .{c});
    try w.writeAll("</node>\n");
}

fn writeArgs(w: *std.Io.Writer, signature: []const u8, arg_names: []const []const u8, direction: ?[]const u8) std.Io.Writer.Error!void {
    var it: @import("signature.zig").Iterator = .{ .sig = signature };
    var i: usize = 0;
    while (it.next()) |t| : (i += 1) {
        try w.print("   <arg type=\"{s}\"", .{t});
        if (i < arg_names.len) try w.print(" name=\"{s}\"", .{arg_names[i]});
        if (direction) |d| try w.print(" direction=\"{s}\"", .{d});
        try w.writeAll("/>\n");
    }
}

test "introspection lists interfaces, properties, and children" {
    const gpa = std.testing.allocator;
    const Dummy = struct {
        fn call(_: *Request) anyerror!void {}
    };
    const iface: Interface = .{
        .name = "org.example.Thing",
        .methods = &.{.{ .name = "Do", .in = "sa{sv}", .out = "u", .in_names = &.{ "what", "options" }, .func = Dummy.call }},
        .properties = &.{
            .{ .name = "Count", .signature = "u" },
            .{ .name = "Name", .signature = "s", .access = .readwrite, .emits_changed = .invalidates },
        },
        .signals = &.{.{ .name = "Changed", .signature = "u" }},
    };
    var children: ChildList = .{ .gpa = gpa };
    defer children.deinit();
    try children.add("a");
    try children.add("b");
    try children.add("a");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try introspect(gpa, &out, .{ .interfaces = &.{&iface} }, &children);
    const xml = out.items;
    const expect = [_][]const u8{
        "<interface name=\"org.freedesktop.DBus.Properties\">",
        "<interface name=\"org.example.Thing\">",
        "<arg type=\"s\" name=\"what\" direction=\"in\"/>",
        "<arg type=\"a{sv}\" name=\"options\" direction=\"in\"/>",
        "<arg type=\"u\" direction=\"out\"/>",
        "<signal name=\"Changed\">\n   <arg type=\"u\"/>",
        "<property name=\"Count\" type=\"u\" access=\"read\"/>",
        "value=\"invalidates\"",
        " <node name=\"a\"/>\n <node name=\"b\"/>\n</node>\n",
    };
    for (expect) |e| {
        if (std.mem.indexOf(u8, xml, e) == null) {
            std.debug.print("missing {s} in\n{s}\n", .{ e, xml });
            return error.TestExpectedEqual;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, xml, "name=\"a\""));
}
