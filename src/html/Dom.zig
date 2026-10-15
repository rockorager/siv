//! A parsed document: nodes in one array, linked as a tree, with names as
//! atoms and every string in one byte buffer. Plain indices (D20). The tree
//! builder, the Markdown parser, and tests create nodes; the style system
//! and layout only read them.

const std = @import("std");
const atoms = @import("atoms.zig");

const Dom = @This();
const Allocator = std.mem.Allocator;
pub const Atom = atoms.Atom;

pub const NodeId = enum(u32) {
    document = 0,
    none = std.math.maxInt(u32),
    _,

    pub fn index(id: NodeId) u32 {
        return @intFromEnum(id);
    }
};

pub const Kind = enum(u8) { document, doctype, element, text, comment };

pub const Namespace = enum(u8) { html, svg, mathml };

/// A range of `Dom.bytes`.
pub const Str = struct {
    start: u32 = 0,
    len: u32 = 0,
};

/// An attribute: a name, the prefix of a foreign attribute (`xlink:href`
/// is name `href` with prefix `xlink`), and a value.
pub const Attr = struct {
    name: Atom,
    prefix: Prefix = .none,
    value: Str,

    pub const Prefix = enum(u8) { none, xlink, xml, xmlns };
};

pub const Node = struct {
    parent: NodeId = .none,
    first: NodeId = .none,
    last: NodeId = .none,
    next: NodeId = .none,
    prev: NodeId = .none,
    kind: Kind,
    ns: Namespace = .html,
    /// Elements: in quirks-mode documents, layout follows some legacy rules.
    flags: Flags = .{},
    /// Element local name; doctype name.
    name: Atom = .none,
    /// Elements: `attrs[a..][0..b]`. Text, comments, and doctypes: `bytes`
    /// range (doctypes: the public and system identifiers follow in
    /// `doctypes`).
    a: u32 = 0,
    b: u32 = 0,

    pub const Flags = packed struct(u8) {
        /// A `<template>`'s children are its contents, not rendered.
        template_contents: bool = false,
        /// An `annotation-xml` that is an HTML integration point.
        integration_point: bool = false,
        /// Created by the parser for a misnested tag, not by markup.
        implied: bool = false,
        _: u5 = 0,
    };
};

pub const Quirks = enum(u8) { no_quirks, limited_quirks, quirks };

gpa: Allocator,
nodes: std.ArrayList(Node) = .empty,
attrs: std.ArrayList(Attr) = .empty,
bytes: std.ArrayList(u8) = .empty,
interner: Interner = .{},
quirks: Quirks = .no_quirks,

pub fn init(gpa: Allocator) error{OutOfMemory}!Dom {
    var d: Dom = .{ .gpa = gpa };
    try d.nodes.append(gpa, .{ .kind = .document });
    return d;
}

pub fn deinit(d: *Dom) void {
    d.nodes.deinit(d.gpa);
    d.attrs.deinit(d.gpa);
    d.bytes.deinit(d.gpa);
    d.interner.deinit(d.gpa);
    d.* = undefined;
}

/// Memory the document holds.
pub fn memory(d: *const Dom) usize {
    return d.nodes.capacity * @sizeOf(Node) + d.attrs.capacity * @sizeOf(Attr) + d.bytes.capacity + d.interner.memory();
}

pub fn node(d: *const Dom, id: NodeId) *const Node {
    return &d.nodes.items[id.index()];
}

pub fn nodeMut(d: *Dom, id: NodeId) *Node {
    return &d.nodes.items[id.index()];
}

pub fn len(d: *const Dom) u32 {
    return @intCast(d.nodes.items.len);
}

pub fn str(d: *const Dom, s: Str) []const u8 {
    return d.bytes.items[s.start..][0..s.len];
}

/// The text of a text or comment node.
pub fn text(d: *const Dom, id: NodeId) []const u8 {
    const n = d.node(id);
    return d.bytes.items[n.a..][0..n.b];
}

pub fn attributes(d: *const Dom, id: NodeId) []const Attr {
    const n = d.node(id);
    if (n.kind != .element) return &.{};
    return d.attrs.items[n.a..][0..n.b];
}

/// The value of an unprefixed attribute, or null.
pub fn attr(d: *const Dom, id: NodeId, name: Atom) ?[]const u8 {
    for (d.attributes(id)) |at| if (at.name == name and at.prefix == .none) return d.str(at.value);
    return null;
}

pub fn hasAttr(d: *const Dom, id: NodeId, name: Atom) bool {
    return d.attr(id, name) != null;
}

/// The name of an atom: static, or interned in this document.
pub fn nameOf(d: *const Dom, a: Atom) []const u8 {
    const v = @intFromEnum(a);
    if (v < atoms.first_dynamic) return atoms.static_names[v];
    return d.interner.names.items[v - atoms.first_dynamic];
}

/// The atom for a name, interning it when it is not static.
pub fn atom(d: *Dom, s: []const u8) error{OutOfMemory}!Atom {
    if (atoms.static_map.get(s)) |a| return a;
    return d.interner.intern(d.gpa, s);
}

/// The atom for a name if it exists, without interning.
pub fn lookup(d: *const Dom, s: []const u8) ?Atom {
    if (atoms.static_map.get(s)) |a| return a;
    return d.interner.lookup(s);
}

pub fn isElement(d: *const Dom, id: NodeId, ns: Namespace, n: Atom) bool {
    const x = d.node(id);
    return x.kind == .element and x.ns == ns and x.name == n;
}

pub fn isHtml(d: *const Dom, id: NodeId, n: Atom) bool {
    return d.isElement(id, .html, n);
}

// Building.

pub fn addString(d: *Dom, s: []const u8) error{OutOfMemory}!Str {
    if (d.bytes.items.len + s.len > std.math.maxInt(u32)) return error.OutOfMemory;
    const start: u32 = @intCast(d.bytes.items.len);
    try d.bytes.appendSlice(d.gpa, s);
    return .{ .start = start, .len = @intCast(s.len) };
}

fn add(d: *Dom, n: Node) error{OutOfMemory}!NodeId {
    if (d.nodes.items.len >= std.math.maxInt(u32) - 1) return error.OutOfMemory;
    const id: NodeId = @enumFromInt(d.nodes.items.len);
    try d.nodes.append(d.gpa, n);
    return id;
}

pub const NewAttr = struct { name: Atom, prefix: Attr.Prefix = .none, value: []const u8 };

/// A new element with no parent.
pub fn createElement(d: *Dom, ns: Namespace, n: Atom, attributes_: []const NewAttr) error{OutOfMemory}!NodeId {
    const start: u32 = @intCast(d.attrs.items.len);
    try d.attrs.ensureUnusedCapacity(d.gpa, attributes_.len);
    for (attributes_) |at| d.attrs.appendAssumeCapacity(.{ .name = at.name, .prefix = at.prefix, .value = try d.addString(at.value) });
    return d.add(.{ .kind = .element, .ns = ns, .name = n, .a = start, .b = @intCast(attributes_.len) });
}

/// Adds an attribute an element does not have yet (the parser's merging
/// of duplicate `<html>` and `<body>` tags' attributes).
pub fn addAttrIfMissing(d: *Dom, id: NodeId, at: NewAttr) error{OutOfMemory}!void {
    for (d.attributes(id)) |old| if (old.name == at.name and old.prefix == at.prefix) return;
    const n = d.node(id).*;
    const value = try d.addString(at.value);
    if (n.a + n.b != d.attrs.items.len) {
        // Move the element's attributes to the end, where they can grow.
        const start: u32 = @intCast(d.attrs.items.len);
        try d.attrs.ensureUnusedCapacity(d.gpa, n.b + 1);
        for (0..n.b) |i| d.attrs.appendAssumeCapacity(d.attrs.items[n.a + i]);
        d.nodeMut(id).a = start;
    }
    try d.attrs.append(d.gpa, .{ .name = at.name, .prefix = at.prefix, .value = value });
    d.nodeMut(id).b += 1;
}

pub fn createText(d: *Dom, s: []const u8) error{OutOfMemory}!NodeId {
    const v = try d.addString(s);
    return d.add(.{ .kind = .text, .a = v.start, .b = v.len });
}

pub fn createComment(d: *Dom, s: []const u8) error{OutOfMemory}!NodeId {
    const v = try d.addString(s);
    return d.add(.{ .kind = .comment, .a = v.start, .b = v.len });
}

/// A doctype: its name, then public and system identifiers as the next
/// two strings (empty and missing are told apart by `flags.implied`
/// bits... kept simple: missing identifiers are empty).
pub fn createDoctype(d: *Dom, n: []const u8, public_id: ?[]const u8, system_id: ?[]const u8) error{OutOfMemory}!NodeId {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(d.gpa);
    // name \0 public \0 system, with \x01 marking a missing identifier.
    try buf.appendSlice(d.gpa, n);
    try buf.append(d.gpa, 0);
    if (public_id) |p| try buf.appendSlice(d.gpa, p) else try buf.append(d.gpa, 1);
    try buf.append(d.gpa, 0);
    if (system_id) |s| try buf.appendSlice(d.gpa, s) else try buf.append(d.gpa, 1);
    const v = try d.addString(buf.items);
    return d.add(.{ .kind = .doctype, .a = v.start, .b = v.len });
}

pub const Doctype = struct { name: []const u8, public_id: ?[]const u8, system_id: ?[]const u8 };

pub fn doctype(d: *const Dom, id: NodeId) Doctype {
    var it = std.mem.splitScalar(u8, d.text(id), 0);
    const n = it.next() orelse "";
    const p = it.next() orelse "\x01";
    const s = it.next() orelse "\x01";
    return .{
        .name = n,
        .public_id = if (std.mem.eql(u8, p, "\x01")) null else p,
        .system_id = if (std.mem.eql(u8, s, "\x01")) null else s,
    };
}

/// Appends text to a text node, moving its bytes to the end of the buffer
/// when something was written after them.
pub fn appendText(d: *Dom, id: NodeId, s: []const u8) error{OutOfMemory}!void {
    const n = d.node(id).*;
    if (d.bytes.items.len + s.len + n.b > std.math.maxInt(u32)) return error.OutOfMemory;
    if (n.a + n.b != d.bytes.items.len) {
        const start: u32 = @intCast(d.bytes.items.len);
        try d.bytes.ensureUnusedCapacity(d.gpa, n.b + s.len);
        d.bytes.appendSliceAssumeCapacity(d.bytes.items[n.a..][0..n.b]);
        d.nodeMut(id).a = start;
    }
    try d.bytes.appendSlice(d.gpa, s);
    d.nodeMut(id).b += @intCast(s.len);
}

/// Removes a node from its parent.
pub fn detach(d: *Dom, id: NodeId) void {
    const n = d.node(id).*;
    if (n.parent == .none) return;
    if (n.prev != .none) d.nodeMut(n.prev).next = n.next else d.nodeMut(n.parent).first = n.next;
    if (n.next != .none) d.nodeMut(n.next).prev = n.prev else d.nodeMut(n.parent).last = n.prev;
    const m = d.nodeMut(id);
    m.parent = .none;
    m.prev = .none;
    m.next = .none;
}

/// Inserts `id` (detached first) into `parent` before `before`, or last.
pub fn insertBefore(d: *Dom, parent: NodeId, id: NodeId, before: NodeId) void {
    d.detach(id);
    const m = d.nodeMut(id);
    m.parent = parent;
    if (before == .none) {
        const last = d.node(parent).last;
        m.prev = last;
        m.next = .none;
        if (last != .none) d.nodeMut(last).next = id else d.nodeMut(parent).first = id;
        d.nodeMut(parent).last = id;
    } else {
        const prev = d.node(before).prev;
        m.prev = prev;
        m.next = before;
        d.nodeMut(before).prev = id;
        if (prev != .none) d.nodeMut(prev).next = id else d.nodeMut(parent).first = id;
    }
}

pub fn append(d: *Dom, parent: NodeId, id: NodeId) void {
    d.insertBefore(parent, id, .none);
}

/// Moves all children of `from` to the end of `to`.
pub fn moveChildren(d: *Dom, from: NodeId, to: NodeId) void {
    while (d.node(from).first != .none) d.append(to, d.node(from).first);
}

// Reading.

pub fn children(d: *const Dom, id: NodeId) ChildIterator {
    return .{ .d = d, .cur = d.node(id).first };
}

pub const ChildIterator = struct {
    d: *const Dom,
    cur: NodeId,

    pub fn next(it: *ChildIterator) ?NodeId {
        if (it.cur == .none) return null;
        const r = it.cur;
        it.cur = it.d.node(r).next;
        return r;
    }
};

/// The next node in tree order after `id`, within `root`'s subtree.
pub fn following(d: *const Dom, id: NodeId, root: NodeId) NodeId {
    const n = d.node(id);
    if (n.first != .none) return n.first;
    return d.followingSkip(id, root);
}

/// The next node in tree order that is not a descendant of `id`.
pub fn followingSkip(d: *const Dom, id: NodeId, root: NodeId) NodeId {
    var cur = id;
    while (cur != root and cur != .none) {
        const c = d.node(cur);
        if (c.next != .none) return c.next;
        cur = c.parent;
    }
    return .none;
}

/// The first child element of `id` with this name, or none.
pub fn childElement(d: *const Dom, id: NodeId, n: Atom) NodeId {
    var it = d.children(id);
    while (it.next()) |c| if (d.isHtml(c, n)) return c;
    return .none;
}

/// The document element (`<html>`), or none.
pub fn documentElement(d: *const Dom) NodeId {
    var it = d.children(.document);
    while (it.next()) |c| if (d.node(c).kind == .element) return c;
    return .none;
}

/// `<body>`, or none.
pub fn body(d: *const Dom) NodeId {
    const r = d.documentElement();
    if (r == .none) return .none;
    var it = d.children(r);
    while (it.next()) |c| if (d.isHtml(c, .body) or d.isHtml(c, .frameset)) return c;
    return .none;
}

/// Concatenated text of the subtree (textContent).
pub fn textContent(d: *const Dom, gpa: Allocator, id: NodeId, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
    var cur = d.node(id).first;
    while (cur != .none) {
        const n = d.node(cur);
        if (n.kind == .text) try out.appendSlice(gpa, d.text(cur));
        cur = d.following(cur, id);
    }
}

/// Names interned by one document.
pub const Interner = struct {
    map: std.StringHashMapUnmanaged(Atom) = .empty,
    names: std.ArrayList([]const u8) = .empty,

    pub fn deinit(i: *Interner, gpa: Allocator) void {
        i.map.deinit(gpa);
        for (i.names.items) |n| gpa.free(n);
        i.names.deinit(gpa);
    }

    pub fn memory(i: *const Interner) usize {
        return i.map.capacity() * (@sizeOf([]const u8) + @sizeOf(Atom)) + i.names.capacity * @sizeOf([]const u8);
    }

    pub fn intern(i: *Interner, gpa: Allocator, s: []const u8) error{OutOfMemory}!Atom {
        if (i.map.get(s)) |a| return a;
        const copy = try gpa.dupe(u8, s);
        errdefer gpa.free(copy);
        const a: Atom = @enumFromInt(atoms.first_dynamic + i.names.items.len);
        try i.names.append(gpa, copy);
        errdefer _ = i.names.pop();
        try i.map.put(gpa, copy, a);
        return a;
    }

    pub fn lookup(i: *const Interner, s: []const u8) ?Atom {
        return i.map.get(s);
    }
};

test "building and walking" {
    const gpa = std.testing.allocator;
    var d = try Dom.init(gpa);
    defer d.deinit();
    const html = try d.createElement(.html, .html, &.{});
    d.append(.document, html);
    const p = try d.createElement(.html, .p, &.{.{ .name = .class, .value = "x" }});
    d.append(html, p);
    const t = try d.createText("hello");
    d.append(p, t);
    _ = try d.createText("other");
    try d.appendText(t, " world");
    try std.testing.expectEqualStrings("hello world", d.text(t));
    try std.testing.expectEqualStrings("x", d.attr(p, .class).?);
    try d.addAttrIfMissing(p, .{ .name = .id, .value = "y" });
    try d.addAttrIfMissing(p, .{ .name = .class, .value = "z" });
    try std.testing.expectEqualStrings("x", d.attr(p, .class).?);
    try std.testing.expectEqualStrings("y", d.attr(p, .id).?);
    const custom = try d.atom("my-element");
    try std.testing.expectEqual(custom, try d.atom("my-element"));
    try std.testing.expectEqualStrings("my-element", d.nameOf(custom));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try d.textContent(gpa, html, &out);
    try std.testing.expectEqualStrings("hello world", out.items);
}
