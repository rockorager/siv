//! The AT-SPI bridge (D18): publishes the semantics trees of an
//! application's windows on the accessibility bus and turns their changes
//! into AT-SPI events.
//!
//! Discovery: on the session bus, `org.a11y.Bus` says whether assistive
//! technology is enabled (org.a11y.Status IsEnabled or
//! ScreenReaderEnabled) and where the accessibility bus is (GetAddress).
//! The bridge connects only while it is enabled, so an application nobody
//! inspects pays nothing. $AT_SPI_BUS_ADDRESS overrides discovery.
//!
//! Publishing: one D-Bus subtree registration serves every object. The
//! application is /org/a11y/atspi/accessible/root; a semantics node is
//! /org/a11y/atspi/accessible/<window>_<node>_<generation>, resolved from
//! the path on each call. The generation changes when a node leaves the
//! tree, so a recycled node index never answers for an old object.
//!
//! Each window keeps a snapshot of the tree it last published. `update`,
//! called after a frame, builds a new snapshot, diffs it against the old
//! one (children, names, states, values, text, caret, live regions),
//! emits the events, and swaps. Calls from assistive technology are
//! answered from the snapshot, so answers and events always agree.
//!
//! Loop thread only; callbacks run at safe points (D5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const dbus = @import("dbus");
const ui = @import("ui");
const raster = @import("raster");
const Loop = @import("loop").Loop;
const atspi = @import("atspi.zig");
const textutil = @import("textutil.zig");
const iface = @import("iface.zig");

const Connection = dbus.Connection;
const Rect = raster.Rect;

const Bridge = @This();

gpa: Allocator,
loop: *Loop,
options: Options,
session: ?*Connection = null,
bus_watch: Connection.NameWatch = .{ .name = "org.a11y.Bus", .func = onBusOwner },
status_sub: Connection.Subscription = .{
    .rule = .{ .sender = "org.a11y.Bus", .path = "/org/a11y/bus", .interface = "org.freedesktop.DBus.Properties", .member = "PropertiesChanged" },
    .func = onStatusChanged,
},
status_call: u32 = 0,
address_call: u32 = 0,
is_enabled: bool = false,
screen_reader: bool = false,
/// The accessibility bus.
conn: ?*Connection = null,
ready: bool = false,
embed_call: u32 = 0,
/// The registry's desktop, our root's parent.
desktop_name: Connection.Name = .{},
desktop_path: [64]u8 = undefined,
desktop_path_len: u8 = 0,
/// Assigned by the registry through Application.Id.
app_id: i32 = 0,
object: dbus.Object = undefined,
cache: dbus.Object = undefined,
windows: std.ArrayList(?*Win) = .empty,
cleanup: Loop.Task = .{ .func = onCleanup },
/// Scratch for one call or one update.
arena: std.heap.ArenaAllocator,
/// Application.GetLocale's answer: the application's language (D21) as a
/// POSIX locale name.
locale_buf: [64]u8 = undefined,
locale_len: u8 = 0,

pub const Options = struct {
    app_name: []const u8 = "",
    toolkit_version: []const u8 = "",
    /// The application's BCP 47 language (D21); empty is "C".
    language: []const u8 = "",
    /// Called at a safe point when publishing starts or stops, so that
    /// the application can skip `update` while nobody listens.
    on_active: ?*const fn (ctx: ?*anyopaque, active: bool) void = null,
    ctx: ?*anyopaque = null,
};

pub const Error = Allocator.Error || Connection.Error;

pub const WindowId = u32;

pub fn init(b: *Bridge, gpa: Allocator, loop: *Loop, options: Options) void {
    b.* = .{ .gpa = gpa, .loop = loop, .options = options, .arena = .init(gpa) };
    b.setLanguage(options.language);
    b.object = .{ .path = atspi.accessible_prefix, .ctx = b, .subtree = .{ .lookup = lookup } };
    b.cache = .{ .path = "/org/a11y/atspi/cache", .ctx = b, .interfaces = &.{&iface.cache} };
}

/// Sets the application's language (BCP 47), which Application.GetLocale
/// reports as a POSIX locale name: "ar-EG" is "ar_EG", a script subtag
/// is dropped, and empty is "C".
pub fn setLanguage(b: *Bridge, language: []const u8) void {
    var it = std.mem.tokenizeAny(u8, language, "-_");
    var w: std.Io.Writer = .fixed(&b.locale_buf);
    const lang = it.next() orelse "C";
    w.writeAll(lang) catch {};
    while (it.next()) |sub| {
        // A region: two letters or three digits.
        if (sub.len == 2 or (sub.len == 3 and std.ascii.isDigit(sub[0]))) {
            w.writeByte('_') catch {};
            for (sub) |c| w.writeByte(std.ascii.toUpper(c)) catch {};
            break;
        }
    }
    b.locale_len = @intCast(w.end);
}

pub fn locale(b: *const Bridge) []const u8 {
    return b.locale_buf[0..b.locale_len];
}

/// Disconnects and frees everything. Windows still added are dropped.
pub fn deinit(b: *Bridge) void {
    b.loop.unschedule(&b.cleanup);
    if (b.session) |s| {
        if (b.status_call != 0) s.cancelCall(b.status_call);
        if (b.address_call != 0) s.cancelCall(b.address_call);
        s.unwatchName(&b.bus_watch);
        s.unsubscribe(&b.status_sub);
    }
    b.disconnect();
    for (b.windows.items) |w| if (w) |x| x.destroy();
    b.windows.deinit(b.gpa);
    b.arena.deinit();
    b.* = undefined;
}

/// Follows the accessibility status on the session bus, and connects to
/// the accessibility bus while assistive technology is enabled.
pub fn start(b: *Bridge, session: *Connection) Error!void {
    if (getenv("AT_SPI_BUS_ADDRESS")) |addr| return b.connectAddress(addr);
    b.session = session;
    try session.subscribe(&b.status_sub);
    try session.watchName(&b.bus_watch);
}

/// Publishes on an already connected accessibility bus socket (tests).
pub fn connectFd(b: *Bridge, fd: i32) Error!void {
    const c = try b.newConnection();
    c.initFd(b.gpa, b.loop, fd, b.connOptions()) catch |err| {
        b.gpa.destroy(c);
        b.conn = null;
        return err;
    };
    try b.attach();
}

pub fn connectAddress(b: *Bridge, addr: []const u8) Error!void {
    const c = try b.newConnection();
    c.init(b.gpa, b.loop, addr, b.connOptions()) catch |err| {
        b.gpa.destroy(c);
        b.conn = null;
        return err;
    };
    try b.attach();
}

fn newConnection(b: *Bridge) Allocator.Error!*Connection {
    std.debug.assert(b.conn == null);
    const c = try b.gpa.create(Connection);
    b.conn = c;
    return c;
}

fn connOptions(b: *Bridge) Connection.Options {
    return .{ .on_event = onA11yEvent, .ctx = b };
}

fn attach(b: *Bridge) Error!void {
    const c = b.conn.?;
    errdefer b.disconnect();
    try c.exportObject(&b.object);
    try c.exportObject(&b.cache);
}

/// Whether the bridge is publishing: `update` has work to do.
pub fn active(b: *const Bridge) bool {
    return b.ready;
}

fn disconnect(b: *Bridge) void {
    const c = b.conn orelse return;
    if (b.embed_call != 0) c.cancelCall(b.embed_call);
    b.embed_call = 0;
    c.deinit();
    b.gpa.destroy(c);
    b.conn = null;
    const was = b.ready;
    b.ready = false;
    for (b.windows.items) |w| if (w) |x| x.forget();
    if (was) b.notifyActive(false);
}

fn notifyActive(b: *Bridge, on: bool) void {
    if (b.options.on_active) |f| f(b.options.ctx, on);
}

fn onA11yEvent(ctx: ?*anyopaque, _: *Connection, event: Connection.Event) void {
    const b: *Bridge = @ptrCast(@alignCast(ctx));
    switch (event) {
        .ready => {
            b.ready = true;
            b.embed();
            // Publish what the windows show now; events follow changes.
            for (b.windows.items) |w| if (w) |x| x.refresh(false) catch {};
            b.notifyActive(true);
        },
        // The connection cannot be freed from its own callback.
        .disconnected => b.loop.schedule(&b.cleanup, .dispatch),
    }
}

fn onCleanup(t: *Loop.Task) void {
    const b: *Bridge = @fieldParentPtr("cleanup", t);
    if (b.conn) |c| if (!c.connected()) b.disconnect();
}

fn embed(b: *Bridge) void {
    const c = b.conn.?;
    var m = c.methodCall(atspi.registry_name, atspi.root_path, atspi.iface.socket, "Embed");
    m.body.write(.{ c.uniqueName(), dbus.ObjectPath{ .path = atspi.root_path } }) catch {
        m.deinit();
        return;
    };
    b.embed_call = c.call(&m, onEmbed, b, .{}) catch 0;
}

fn onEmbed(ctx: ?*anyopaque, reply: Connection.Reply) void {
    const b: *Bridge = @ptrCast(@alignCast(ctx));
    b.embed_call = 0;
    const m = switch (reply) {
        .ok => |m| m,
        else => return, // no registry: still answer direct queries
    };
    var d = m.body();
    const ref = d.read(struct { []const u8, dbus.ObjectPath }) catch return;
    b.desktop_name.set(ref[0]);
    const n = @min(ref[1].path.len, b.desktop_path.len);
    @memcpy(b.desktop_path[0..n], ref[1].path[0..n]);
    b.desktop_path_len = @intCast(n);
}

pub fn desktop(b: *const Bridge) Ref {
    if (b.desktop_path_len == 0) return Ref.null_ref;
    return .init(b.desktop_name.slice(), b.desktop_path[0..b.desktop_path_len]);
}

// Discovery -------------------------------------------------------------------

fn onBusOwner(w: *Connection.NameWatch) void {
    const b: *Bridge = @fieldParentPtr("bus_watch", w);
    if (w.owner() == null) {
        b.is_enabled = false;
        b.screen_reader = false;
        b.applyEnabled();
        return;
    }
    const s = b.session.?;
    if (b.status_call != 0) s.cancelCall(b.status_call);
    b.status_call = s.callMethod("org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties", "GetAll", .{"org.a11y.Status"}, onStatus, b) catch 0;
}

fn onStatus(ctx: ?*anyopaque, reply: Connection.Reply) void {
    const b: *Bridge = @ptrCast(@alignCast(ctx));
    b.status_call = 0;
    const m = switch (reply) {
        .ok => |m| m,
        else => return,
    };
    if (!std.mem.eql(u8, m.signature, "a{sv}")) return;
    var d = m.body();
    b.readStatus(&d) catch return;
    b.applyEnabled();
}

fn readStatus(b: *Bridge, d: *dbus.Decoder) dbus.codec.DecodeError!void {
    const a = try d.beginArray();
    while (a.next(d)) {
        try d.beginDictEntry();
        const key = try d.readString();
        const vs = try d.beginVariant();
        if (std.mem.eql(u8, vs, "b")) {
            const v = try d.readBool();
            if (std.mem.eql(u8, key, "IsEnabled")) b.is_enabled = v;
            if (std.mem.eql(u8, key, "ScreenReaderEnabled")) b.screen_reader = v;
        }
        try d.endVariant();
        try d.endDictEntry();
    }
    try d.endArray(a);
}

fn onStatusChanged(sub: *Connection.Subscription, m: *const dbus.Message) void {
    const b: *Bridge = @fieldParentPtr("status_sub", sub);
    if (!std.mem.eql(u8, m.signature, "sa{sv}as")) return;
    var d = m.body();
    const name = d.readString() catch return;
    if (!std.mem.eql(u8, name, "org.a11y.Status")) return;
    b.readStatus(&d) catch return;
    b.applyEnabled();
}

fn applyEnabled(b: *Bridge) void {
    const want = b.is_enabled or b.screen_reader;
    if (!want) {
        b.disconnect();
        return;
    }
    if (b.conn != null or b.address_call != 0) return;
    const s = b.session orelse return;
    b.address_call = s.callMethod("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", .{}, onAddress, b) catch 0;
}

fn onAddress(ctx: ?*anyopaque, reply: Connection.Reply) void {
    const b: *Bridge = @ptrCast(@alignCast(ctx));
    b.address_call = 0;
    const m = switch (reply) {
        .ok => |m| m,
        else => return,
    };
    var d = m.body();
    const addr = d.readString() catch return;
    if (!(b.is_enabled or b.screen_reader) or b.conn != null) return;
    b.connectAddress(addr) catch |err| std.log.scoped(.a11y).warn("cannot connect to the accessibility bus: {t}", .{err});
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

// Windows ---------------------------------------------------------------------

/// Starts publishing a window. `title` names it when its root node has no
/// label.
pub fn addWindow(b: *Bridge, ui_win: *ui.Window, title: []const u8) Error!WindowId {
    const w = try b.gpa.create(Win);
    errdefer b.gpa.destroy(w);
    w.* = .{ .bridge = b, .id = 0, .ui = ui_win };
    errdefer w.title.deinit(b.gpa);
    try w.title.appendSlice(b.gpa, title);
    // Reuse a free slot; ids are slot indices plus one.
    var slot: ?usize = null;
    for (b.windows.items, 0..) |x, i| if (x == null) {
        slot = i;
        break;
    };
    if (slot == null) {
        try b.windows.append(b.gpa, null);
        slot = b.windows.items.len - 1;
    }
    w.id = @intCast(slot.? + 1);
    b.windows.items[slot.?] = w;
    if (b.ready) {
        w.refresh(false) catch {};
        const base = b.rootIndexOf(w);
        for (0..w.cur.top_count) |k| {
            const i = w.cur.topAt(k);
            b.emitObject(atspi.root_path, "ChildrenChanged", "add", @intCast(base + k), 0, .{ .ref = w.ref(i) });
        }
        if (w.cur.top_count > 0) b.emitWindow(w, w.cur.topAt(0), "Create");
    }
    return w.id;
}

pub fn removeWindow(b: *Bridge, id: WindowId) void {
    const w = b.window(id) orelse return;
    if (b.ready and w.built) {
        if (w.cur.top_count > 0) b.emitWindow(w, w.cur.topAt(0), "Destroy");
        const base = b.rootIndexOf(w);
        var k = w.cur.top_count;
        while (k > 0) {
            k -= 1;
            b.emitObject(atspi.root_path, "ChildrenChanged", "remove", @intCast(base + k), 0, .{ .ref = w.ref(w.cur.topAt(k)) });
        }
    }
    b.windows.items[id - 1] = null;
    w.destroy();
}

pub fn setTitle(b: *Bridge, id: WindowId, title: []const u8) Error!void {
    const w = b.window(id) orelse return;
    w.title.clearRetainingCapacity();
    try w.title.appendSlice(b.gpa, title);
    if (b.ready and w.built and w.cur.top_count > 0) {
        const top = w.cur.topAt(0);
        if (w.cur.nodes.items[top].name.len == 0) b.emitPath(w, top, atspi.iface.event_object, "PropertyChange", "accessible-name", 0, 0, .{ .str = title });
    }
}

/// The window gained or lost keyboard focus (xdg_toplevel activated).
pub fn setActive(b: *Bridge, id: WindowId, on: bool) void {
    const w = b.window(id) orelse return;
    if (w.active == on) return;
    w.active = on;
    if (!b.ready or !w.built or w.cur.top_count == 0) return;
    const top = w.cur.topAt(0);
    w.cur.nodes.items[top].states = w.cur.nodes.items[top].states.with(.active);
    if (!on) w.cur.nodes.items[top].states.bits &= ~(@as(u64, 1) << @backingInt(atspi.State.active));
    b.emitWindow(w, top, if (on) "Activate" else "Deactivate");
    b.emitPath(w, top, atspi.iface.event_object, "StateChanged", "active", @intFromBool(on), 0, .{ .int = 0 });
}

/// Publishes the window's changes since the last update. Call after
/// every frame of the window; does nothing while not publishing.
pub fn update(b: *Bridge, id: WindowId) Error!void {
    if (!b.ready) return;
    const w = b.window(id) orelse return;
    try w.refresh(true);
}

pub fn window(b: *const Bridge, id: WindowId) ?*Win {
    if (id == 0 or id > b.windows.items.len) return null;
    return b.windows.items[id - 1];
}

/// The index in the application's children of the window's first
/// top-level node.
pub fn rootIndexOf(b: *const Bridge, w: *const Win) usize {
    var n: usize = 0;
    for (b.windows.items) |x| {
        const o = x orelse continue;
        if (o == w) break;
        n += o.cur.top_count;
    }
    return n;
}

/// The application's children, in order.
pub fn rootChildren(b: *const Bridge) RootIterator {
    return .{ .bridge = b };
}

pub const RootIterator = struct {
    bridge: *const Bridge,
    w: usize = 0,
    k: u32 = 0,

    pub fn next(it: *RootIterator) ?struct { *Win, u32 } {
        while (it.w < it.bridge.windows.items.len) {
            const w = it.bridge.windows.items[it.w] orelse {
                it.w += 1;
                continue;
            };
            if (it.k < w.cur.top_count) {
                defer it.k += 1;
                return .{ w, w.cur.topAt(it.k) };
            }
            it.w += 1;
            it.k = 0;
        }
        return null;
    }
};

// Objects ---------------------------------------------------------------------

/// An object reference, (so) on the wire. The name is borrowed (a
/// connection's unique name); the path is stored inline.
pub const Ref = struct {
    name: []const u8,
    buf: [96]u8 = undefined,
    len: u8 = 0,

    pub const null_ref: Ref = .init("", atspi.null_path);

    pub fn init(name: []const u8, p: []const u8) Ref {
        var r: Ref = .{ .name = name };
        const n = @min(p.len, r.buf.len);
        @memcpy(r.buf[0..n], p[0..n]);
        r.len = @intCast(n);
        return r;
    }

    pub fn path(r: *const Ref) []const u8 {
        return r.buf[0..r.len];
    }

    pub fn write(r: *const Ref, e: *dbus.Encoder) dbus.codec.EncodeError!void {
        try e.beginStruct();
        try e.writeString(r.name);
        try e.writeObjectPath(r.path());
        try e.endStruct();
    }
};

/// What a path names.
pub const Target = union(enum) {
    root,
    node: struct { win: *Win, index: u32 },
};

pub fn resolve(b: *const Bridge, path: []const u8) ?Target {
    if (!std.mem.startsWith(u8, path, atspi.accessible_prefix ++ "/")) return null;
    const rest = path[atspi.accessible_prefix.len + 1 ..];
    if (std.mem.eql(u8, rest, "root")) return .root;
    var it = std.mem.splitScalar(u8, rest, '_');
    const wid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const node = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const gen = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const virtual: u64 = if (it.next()) |v| std.fmt.parseInt(u32, v, 10) catch return null else 0;
    if (it.next() != null) return null;
    const w = b.window(wid) orelse return null;
    const index = w.cur.index.get(virtual << 32 | node) orelse return null;
    if (w.cur.nodes.items[index].gen != gen) return null;
    return .{ .node = .{ .win = w, .index = index } };
}

fn lookup(o: *dbus.Object, path: []const u8) ?dbus.Node {
    const b: *Bridge = @ptrCast(@alignCast(o.ctx));
    const t = b.resolve(path) orelse return null;
    return .{ .ctx = b, .interfaces = switch (t) {
        .root => &iface.root_interfaces,
        .node => |n| iface.interfacesOf(&n.win.cur.nodes.items[n.index]),
    } };
}

pub fn rootRef(b: *const Bridge) Ref {
    return .init(b.conn.?.uniqueName(), atspi.root_path);
}

// Events ----------------------------------------------------------------------

pub const Any = union(enum) {
    int: i32,
    double: f64,
    str: []const u8,
    ref: Ref,
};

/// Emits an event signal "siiva{sv}" from `path`.
pub fn emit(b: *Bridge, path: []const u8, interface: []const u8, member: []const u8, detail: []const u8, d1: i32, d2: i32, any: Any) void {
    const c = b.conn orelse return;
    if (!b.ready) return;
    var m = c.signal(path, interface, member);
    writeEvent(&m.body, detail, d1, d2, any) catch {
        m.deinit();
        return;
    };
    // A full or closed connection loses the event; the next change or
    // query still sees the current tree.
    _ = c.send(&m) catch {};
}

fn writeEvent(e: *dbus.Encoder, detail: []const u8, d1: i32, d2: i32, any: Any) dbus.codec.EncodeError!void {
    try e.writeAll(.{ detail, d1, d2 });
    switch (any) {
        .int => |v| try e.write(dbus.variant(v)),
        .double => |v| try e.write(dbus.variant(v)),
        .str => |v| try e.write(dbus.variant(v)),
        .ref => |*r| {
            try e.beginVariant("(so)");
            try r.write(e);
            try e.endVariant();
        },
    }
    try e.beginArray("{sv}");
    try e.endArray();
}

fn emitObject(b: *Bridge, path: []const u8, member: []const u8, detail: []const u8, d1: i32, d2: i32, any: Any) void {
    b.emit(path, atspi.iface.event_object, member, detail, d1, d2, any);
}

fn emitPath(b: *Bridge, w: *Win, index: u32, interface: []const u8, member: []const u8, detail: []const u8, d1: i32, d2: i32, any: Any) void {
    var buf: [96]u8 = undefined;
    b.emit(w.path(&buf, index), interface, member, detail, d1, d2, any);
}

fn emitWindow(b: *Bridge, w: *Win, index: u32, member: []const u8) void {
    b.emitPath(w, index, atspi.iface.event_window, member, "", 0, 0, .{ .int = 0 });
}

// Snapshots -------------------------------------------------------------------

pub const Str = struct {
    off: u32 = 0,
    len: u32 = 0,
};

/// One published node.
pub const SNode = struct {
    node: u32,
    /// One of a canvas's own objects (D32), 1-based; 0 for the node.
    virtual: u32 = 0,
    gen: u32,
    role: ui.Role,
    /// Index of the parent, or `none` for top-level nodes.
    parent: u32,
    /// Descendants follow up to `end`.
    end: u32,
    child_index: u32 = 0,
    child_count: u32 = 0,
    name: Str,
    description: Str,
    /// The text the Text interface shows: an editor's value or a text
    /// node's content (which a label may replace as its name). Offsets
    /// into it are what ui.access takes.
    text: Str,
    /// Heading level or tree item depth, 0 for none.
    level: u8,
    /// Position in a set, its size, and a table row's index; 0 for none.
    position: u32 = 0,
    set_size: u32 = 0,
    row: u32 = 0,
    sort: ui.Sort = .none,
    column: u32 = 0,
    current: ui.Current = .none,
    caret: ?u32,
    anchor: ?u32,
    bounds: Rect,
    states: atspi.States,
    value: ?ui.Range,
    live: ui.Live,
    actionable: bool,
    /// The key that does the same as its action (D34); keysym 0 for none.
    shortcut: ui.Accel = .{},
    focusable: bool,
    editable: bool,
    masked: bool,
    /// The root of a window without a title bar (a layer or lock window,
    /// D31): AT-SPI's window rather than frame.
    frameless: bool = false,
    has_text: bool,
    /// Identifies the text attributes (styled ranges and paragraph
    /// styles), so a change without a text change is reported.
    attrs: u64 = 0,
    /// Another process's object, its last child: "BUS:/path" (D18).
    embed: Str = .{},

    /// The snapshot index's key: the node, and which of its canvas's
    /// objects.
    pub fn key(n: SNode) u64 {
        return @as(u64, n.virtual) << 32 | n.node;
    }
};

/// The reference to a node's embedded object, if it has one.
pub fn embedRef(s: *const Snapshot, n: *const SNode) ?Ref {
    if (n.embed.len == 0) return null;
    const plug = s.str(n.embed);
    const sep = std.mem.indexOf(u8, plug, ":/") orelse return null;
    return .init(plug[0..sep], plug[sep + 1 ..]);
}

pub const none: u32 = std.math.maxInt(u32);

/// A snapshot node's AT-SPI role.
pub fn roleOf(n: *const SNode) atspi.Role {
    if (n.frameless and n.role == .window) return .window;
    return atspi.role(n.role, n.masked);
}

/// A hash of a text node's styled ranges, paragraph styles, and
/// misspelled words (D37).
fn attrsHash(d: *const ui.TextData, misspelled: []const [2]u32) u64 {
    var h = std.hash.Wyhash.init(0);
    hashValue(&h, d.spans);
    hashValue(&h, d.paragraphs);
    h.update(std.mem.sliceAsBytes(misspelled));
    return h.final();
}

fn hashValue(h: *std.hash.Wyhash, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .slice) {
            hashValue(h, @as(u64, v.len));
            for (v) |e| hashValue(h, e);
        } else hashValue(h, v.*),
        .optional => if (v) |x| {
            hashValue(h, true);
            hashValue(h, x);
        } else hashValue(h, false),
        .@"struct" => |st| inline for (st.field_names) |name| hashValue(h, @field(v, name)),
        .float => hashValue(h, @as(u32, @bitCast(@as(f32, v)))),
        .@"enum" => hashValue(h, @as(u32, @intFromEnum(v))),
        .bool => h.update(&.{@intFromBool(v)}),
        .int => h.update(std.mem.asBytes(&v)),
        else => @compileError("cannot hash " ++ @typeName(T)),
    }
}

pub const Snapshot = struct {
    nodes: std.ArrayList(SNode) = .empty,
    strings: std.ArrayList(u8) = .empty,
    /// Node index (and canvas object, `SNode.key`) to position in `nodes`.
    index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    top_count: u32 = 0,
    /// Positions of the top-level nodes.
    tops: std.ArrayList(u32) = .empty,

    fn deinit(s: *Snapshot, gpa: Allocator) void {
        s.nodes.deinit(gpa);
        s.strings.deinit(gpa);
        s.index.deinit(gpa);
        s.tops.deinit(gpa);
    }

    fn clear(s: *Snapshot) void {
        s.nodes.clearRetainingCapacity();
        s.strings.clearRetainingCapacity();
        s.index.clearRetainingCapacity();
        s.tops.clearRetainingCapacity();
        s.top_count = 0;
    }

    pub fn str(s: *const Snapshot, v: Str) []const u8 {
        return s.strings.items[v.off..][0..v.len];
    }

    pub fn topAt(s: *const Snapshot, k: usize) u32 {
        return s.tops.items[k];
    }

    pub fn children(s: *const Snapshot, parent: u32) ChildIterator {
        return .{ .snap = s, .i = parent + 1, .end = s.nodes.items[parent].end };
    }

    pub const ChildIterator = struct {
        snap: *const Snapshot,
        i: u32,
        end: u32,

        pub fn next(it: *ChildIterator) ?u32 {
            if (it.i >= it.end) return null;
            const r = it.i;
            it.i = it.snap.nodes.items[r].end;
            return r;
        }
    };
};

/// A published window.
pub const Win = struct {
    bridge: *Bridge,
    id: WindowId,
    ui: *ui.Window,
    title: std.ArrayList(u8) = .empty,
    active: bool = false,
    cur: Snapshot = .{},
    next: Snapshot = .{},
    /// Generation of each node index.
    gens: std.ArrayList(u32) = .empty,
    built: bool = false,
    /// The semantics tree generation `cur` was built from.
    generation: u64 = 0,

    fn destroy(w: *Win) void {
        const gpa = w.bridge.gpa;
        w.title.deinit(gpa);
        w.cur.deinit(gpa);
        w.next.deinit(gpa);
        w.gens.deinit(gpa);
        gpa.destroy(w);
    }

    /// Drops the published state when publishing stops. Old paths stay
    /// invalid: generations survive.
    fn forget(w: *Win) void {
        for (w.cur.nodes.items) |n| w.bumpGen(n.node);
        w.cur.clear();
        w.built = false;
    }

    fn bumpGen(w: *Win, node: u32) void {
        if (node < w.gens.items.len) w.gens.items[node] +%= 1;
    }

    pub fn path(w: *const Win, buf: []u8, index: u32) []const u8 {
        return w.pathIn(&w.cur, buf, index);
    }

    /// A reference to node `index` of the published snapshot.
    pub fn ref(w: *const Win, index: u32) Ref {
        return w.refIn(&w.cur, index);
    }

    pub fn name(w: *const Win, index: u32) []const u8 {
        const n = &w.cur.nodes.items[index];
        if (n.name.len == 0 and n.parent == none and n.role == .window) return w.title.items;
        return w.cur.str(n.name);
    }

    /// Rebuilds the snapshot if the tree may have changed, emitting the
    /// differences when `events` is set and something was published.
    fn refresh(w: *Win, events: bool) Error!void {
        const tree = try w.ui.semanticsTree();
        if (w.built and tree.generation == w.generation) return;
        w.generation = tree.generation;
        try w.build(&w.next, tree);
        defer _ = w.bridge.arena.reset(.retain_capacity);
        if (w.built and events) try w.diff();
        w.embedNew();
        // Nodes that left the tree get a new generation.
        for (w.cur.nodes.items) |n| {
            if (n.virtual == 0 and !w.next.index.contains(n.key())) w.bumpGen(n.node);
        }
        std.mem.swap(Snapshot, &w.cur, &w.next);
        w.next.clear();
        w.built = true;
    }

    fn genOf(w: *Win, node: u32) Allocator.Error!u32 {
        if (node >= w.gens.items.len) try w.gens.appendNTimes(w.bridge.gpa, 0, node + 1 - w.gens.items.len);
        return w.gens.items[node];
    }

    fn build(w: *Win, s: *Snapshot, tree: *const ui.semantics.Tree) Error!void {
        const gpa = w.bridge.gpa;
        s.clear();
        try s.nodes.ensureTotalCapacity(gpa, tree.nodes.items.len);
        try s.index.ensureTotalCapacity(gpa, @intCast(tree.nodes.items.len));
        for (tree.nodes.items, 0..) |n, i| {
            const node = n.node.index();
            const editor = n.caret != null or n.masked or n.role == .text_input;
            const un = w.ui.node(n.node);
            const has_text = editor or un.kind == .text or switch (n.role) {
                .label, .paragraph, .heading, .status, .alert, .tooltip => true,
                else => false,
            };
            var sn: SNode = .{
                .node = node,
                .virtual = n.virtual,
                .gen = try w.genOf(node),
                .role = n.role,
                .parent = n.parent,
                .end = n.end,
                .name = try addStr(gpa, s, tree.name(n)),
                .description = try addStr(gpa, s, n.description),
                .text = .{},
                .caret = n.caret,
                .anchor = n.anchor,
                .bounds = n.bounds,
                .states = .{},
                .value = n.value,
                .live = n.live,
                .actionable = n.actionable,
                .shortcut = n.shortcut,
                .focusable = n.focusable,
                .editable = editor and !n.masked and !n.disabled,
                .masked = n.masked,
                .frameless = n.node == .root and w.ui.frameless,
                .has_text = has_text,
                .level = n.level,
                .position = n.position,
                .set_size = n.set_size,
                .sort = n.sort,
                .column = n.column,
                .current = n.current,
                .row = n.row,
                .embed = try addStr(gpa, s, n.embed),
            };
            sn.text = if (editor)
                try addRope(gpa, s, n.value_text)
            else if (un.kind == .text)
                try addRope(gpa, s, un.data.text.content)
            else if (has_text) sn.name else .{};
            if (un.isText()) sn.attrs = attrsHash(un.textData(), ui.Spelling.misspellings(w.ui, n.node));
            sn.states = states(&n, w);
            if (n.parent == none) {
                sn.child_index = s.top_count;
                s.top_count += 1;
                try s.tops.append(gpa, @intCast(i));
            } else {
                const p = &s.nodes.items[n.parent];
                sn.child_index = p.child_count;
                p.child_count += 1;
            }
            s.nodes.appendAssumeCapacity(sn);
            s.index.putAssumeCapacity(sn.key(), @intCast(i));
        }
    }

    fn addRope(gpa: Allocator, s: *Snapshot, v: @import("text").Rope) Allocator.Error!Str {
        const off: u32 = @intCast(s.strings.items.len);
        try v.appendTo(gpa, &s.strings, 0, v.len());
        return .{ .off = off, .len = @intCast(v.len()) };
    }

    fn addStr(gpa: Allocator, s: *Snapshot, v: []const u8) Allocator.Error!Str {
        const off: u32 = @intCast(s.strings.items.len);
        try s.strings.appendSlice(gpa, v);
        return .{ .off = off, .len = @intCast(v.len) };
    }

    fn states(n: *const ui.semantics.Node, w: *const Win) atspi.States {
        var s: atspi.States = .{};
        s = s.with(.visible);
        const view = Rect.xywh(0, 0, w.ui.width, w.ui.height);
        if (n.bounds.x0 < view.x1 and n.bounds.x1 > view.x0 and n.bounds.y0 < view.y1 and n.bounds.y1 > view.y0) s = s.with(.showing);
        if (!n.disabled) s = s.with(.enabled).with(.sensitive);
        if (n.focusable) s = s.with(.focusable);
        if (n.focused) s = s.with(.focused);
        switch (n.checked) {
            .unset => {},
            .off => s = s.with(.checkable),
            .on => s = s.with(.checkable).with(.checked),
            .mixed => s = s.with(.checkable).with(.indeterminate),
        }
        switch (n.pressed) {
            .unset, .off => {},
            .on => s = s.with(.pressed),
            .mixed => s = s.with(.indeterminate),
        }
        switch (n.selected) {
            .unset => {},
            .off => s = s.with(.selectable),
            .on => s = s.with(.selectable).with(.selected),
            .mixed => s = s.with(.selectable),
        }
        switch (n.expanded) {
            .unset => {},
            .off => s = s.with(.expandable).with(.collapsed),
            .on, .mixed => s = s.with(.expandable).with(.expanded),
        }
        if (n.caret != null or n.masked) {
            s = s.with(.selectable_text).with(.single_line);
            if (!n.disabled) s = s.with(.editable);
        }
        if (n.role == .slider) s = s.with(.horizontal);
        if (n.modal) s = s.with(.modal);
        if (n.role == .window) {
            s = s.with(.resizable);
            if (w.active) s = s.with(.active);
        }
        return s;
    }

    /// Tells each object newly embedded in `next` its parent
    /// (org.a11y.atspi.Socket.Embedded, as at-spi2-atk's sockets do), so
    /// that its Parent names the node. Objects embedded before keep it.
    fn embedNew(w: *Win) void {
        const b = w.bridge;
        const c = b.conn orelse return;
        if (!b.ready) return;
        const new = &w.next;
        for (new.nodes.items, 0..) |*n, i| {
            const r = embedRef(new, n) orelse continue;
            if (w.built) if (w.cur.index.get(n.key())) |j| {
                const o = &w.cur.nodes.items[j];
                if (o.gen == n.gen and std.mem.eql(u8, w.cur.str(o.embed), new.str(n.embed))) continue;
            };
            var buf: [96]u8 = undefined;
            var m = c.methodCall(r.name, r.path(), atspi.iface.socket, "Embedded");
            m.body.writeString(w.pathIn(new, &buf, @intCast(i))) catch {
                m.deinit();
                continue;
            };
            _ = c.send(&m) catch {};
        }
    }

    /// Emits the events that take `cur` to `next`.
    fn diff(w: *Win) Error!void {
        const b = w.bridge;
        const old = &w.cur;
        const new = &w.next;
        // Children: per parent present in both, removals then additions.
        try w.diffChildren(none, none);
        for (new.nodes.items, 0..) |n, i| {
            const j = old.index.get(n.key()) orelse continue;
            if (old.nodes.items[j].gen != n.gen) continue;
            try w.diffChildren(@intCast(j), @intCast(i));
        }
        // Properties of nodes present in both. Events name the node by its
        // new path, which equals the old one.
        var focus_gained: ?u32 = null;
        for (new.nodes.items, 0..) |*n, i| {
            const j = old.index.get(n.key()) orelse {
                if (n.states.has(.focused)) focus_gained = @intCast(i);
                if (n.live != .off or w.inLiveRegion(new, @intCast(i))) w.announceNew(@intCast(i));
                continue;
            };
            const o = &old.nodes.items[j];
            if (o.gen != n.gen) continue;
            var buf: [96]u8 = undefined;
            const p = w.pathIn(new, &buf, @intCast(i));
            const new_name = new.str(n.name);
            if (!std.mem.eql(u8, old.str(o.name), new_name)) {
                b.emitObject(p, "PropertyChange", "accessible-name", 0, 0, .{ .str = new_name });
            }
            if (!std.mem.eql(u8, old.str(o.description), new.str(n.description))) {
                b.emitObject(p, "PropertyChange", "accessible-description", 0, 0, .{ .str = new.str(n.description) });
            }
            if (o.role != n.role or o.masked != n.masked) {
                b.emitObject(p, "PropertyChange", "accessible-role", 0, 0, .{ .int = @intCast(@backingInt(roleOf(n))) });
            }
            if (!std.meta.eql(o.value, n.value)) {
                b.emitObject(p, "PropertyChange", "accessible-value", 0, 0, .{ .double = if (n.value) |v| v.now else 0 });
            }
            if (n.has_text and o.has_text) try w.diffText(o, n, p);
            const changed = o.states.bits ^ n.states.bits;
            if (changed != 0) {
                inline for (@typeInfo(atspi.State).@"enum".field_names) |field| {
                    const st = @field(atspi.State, field);
                    if (changed & (@as(u64, 1) << @backingInt(st)) != 0) {
                        const on = n.states.has(st);
                        if (st == .focused and on) {
                            focus_gained = @intCast(i); // after every loss
                        } else {
                            b.emitObject(p, "StateChanged", st.nick(), @intFromBool(on), 0, .{ .int = 0 });
                        }
                    }
                }
            }
            if (n.live != .off and !std.mem.eql(u8, old.str(o.name), new_name) and new_name.len > 0) {
                b.emitObject(p, "Announcement", "", atspi.live(n.live), 0, .{ .str = new_name });
            }
        }
        if (focus_gained) |i| {
            var buf: [96]u8 = undefined;
            b.emitObject(w.pathIn(new, &buf, i), "StateChanged", "focused", 1, 0, .{ .int = 0 });
        }
    }

    fn pathIn(w: *const Win, s: *const Snapshot, buf: []u8, index: u32) []const u8 {
        const n = s.nodes.items[index];
        if (n.virtual != 0) return std.fmt.bufPrint(buf, atspi.accessible_prefix ++ "/{d}_{d}_{d}_{d}", .{ w.id, n.node, n.gen, n.virtual }) catch unreachable;
        return std.fmt.bufPrint(buf, atspi.accessible_prefix ++ "/{d}_{d}_{d}", .{ w.id, n.node, n.gen }) catch unreachable;
    }

    fn refIn(w: *const Win, s: *const Snapshot, index: u32) Ref {
        var r: Ref = .{ .name = w.bridge.conn.?.uniqueName() };
        r.len = @intCast(w.pathIn(s, &r.buf, index).len);
        return r;
    }

    /// Children of `oi` in the old snapshot and `ni` in the new one (both
    /// `none`: the window's top-level nodes, children of the root).
    fn diffChildren(w: *Win, oi: u32, ni: u32) Error!void {
        const b = w.bridge;
        const old = &w.cur;
        const new = &w.next;
        var obuf: [96]u8 = undefined;
        const parent_path = if (ni == none) atspi.root_path else w.pathIn(new, &obuf, ni);
        const base: usize = if (ni == none) b.rootIndexOf(w) else 0;
        // Removed: an old child no longer under this parent.
        var it = childIter(old, oi);
        var removed: usize = 0;
        while (it.next()) |c| {
            const n = old.nodes.items[c];
            if (w.sameParent(new, n.key(), n.gen, ni)) continue;
            b.emitObject(parent_path, "ChildrenChanged", "remove", @intCast(base + n.child_index - removed), 0, .{ .ref = w.refIn(old, c) });
            removed += 1;
        }
        var it2 = childIter(new, ni);
        while (it2.next()) |c| {
            const n = new.nodes.items[c];
            if (w.sameParentOld(old, n.key(), n.gen, oi)) continue;
            b.emitObject(parent_path, "ChildrenChanged", "add", @intCast(base + n.child_index), 0, .{ .ref = w.refIn(new, c) });
        }
    }

    fn childIter(s: *const Snapshot, parent: u32) TopOrChildIterator {
        return if (parent == none) .{ .tops = s.tops.items } else .{ .children = s.children(parent) };
    }

    const TopOrChildIterator = union(enum) {
        tops: []const u32,
        children: Snapshot.ChildIterator,

        fn next(it: *TopOrChildIterator) ?u32 {
            switch (it.*) {
                .tops => |*t| {
                    if (t.len == 0) return null;
                    defer t.* = t.*[1..];
                    return t.*[0];
                },
                .children => |*c| return c.next(),
            }
        }
    };

    /// Whether node `node` with `gen` sits in `s` under the node at `ni`
    /// of the new snapshot (`none`: top level).
    fn sameParent(w: *const Win, s: *const Snapshot, node: u64, gen: u32, ni: u32) bool {
        _ = w;
        const k = s.index.get(node) orelse return false;
        const n = s.nodes.items[k];
        if (n.gen != gen) return false;
        return n.parent == ni;
    }

    /// The same, for a new child against the old snapshot's parent `oi`.
    fn sameParentOld(w: *const Win, s: *const Snapshot, node: u64, gen: u32, oi: u32) bool {
        _ = w;
        const k = s.index.get(node) orelse return false;
        const n = s.nodes.items[k];
        if (n.gen != gen) return false;
        return n.parent == oi;
    }

    fn diffText(w: *Win, o: *const SNode, n: *const SNode, p: []const u8) Error!void {
        const b = w.bridge;
        const old_text = w.cur.str(o.text);
        const new_text = w.next.str(n.text);
        // Attributes that move with edited text are part of the edit.
        if (o.attrs != n.attrs and std.mem.eql(u8, old_text, new_text)) b.emitObject(p, "TextAttributesChanged", "", 0, 0, .{ .int = 0 });
        if (textutil.diff(old_text, new_text)) |c| {
            const at = textutil.charOf(old_text, c.start);
            if (c.old_end > c.start) {
                const del = old_text[c.start..c.old_end];
                b.emitObject(p, "TextChanged", "delete", @intCast(at), @intCast(textutil.charCount(del)), .{ .str = del });
            }
            if (c.new_end > c.start) {
                const ins = new_text[c.start..c.new_end];
                b.emitObject(p, "TextChanged", "insert", @intCast(at), @intCast(textutil.charCount(ins)), .{ .str = ins });
            }
        }
        if (!std.meta.eql(o.caret, n.caret)) {
            if (n.caret) |c| b.emitObject(p, "TextCaretMoved", "", @intCast(textutil.charOf(new_text, c)), 0, .{ .int = 0 });
        }
        const old_sel = o.caret != null and o.anchor != null and o.caret.? != o.anchor.?;
        const new_sel = n.caret != null and n.anchor != null and n.caret.? != n.anchor.?;
        if ((old_sel or new_sel) and !(std.meta.eql(o.caret, n.caret) and std.meta.eql(o.anchor, n.anchor))) {
            b.emitObject(p, "TextSelectionChanged", "", 0, 0, .{ .int = 0 });
        }
    }

    fn inLiveRegion(w: *const Win, s: *const Snapshot, index: u32) bool {
        _ = w;
        var p = s.nodes.items[index].parent;
        while (p != none) : (p = s.nodes.items[p].parent) {
            if (s.nodes.items[p].live != .off) return true;
        }
        return false;
    }

    /// Announces a node that appeared in (or as) a live region.
    fn announceNew(w: *Win, index: u32) void {
        const s = &w.next;
        const n = s.nodes.items[index];
        const text = s.str(n.name);
        if (text.len == 0) return;
        var live = n.live;
        var p = n.parent;
        while (live == .off and p != none) : (p = s.nodes.items[p].parent) live = s.nodes.items[p].live;
        // Only the topmost new node of an added subtree speaks.
        if (n.parent != none and !w.cur.index.contains(s.nodes.items[n.parent].key()) and s.nodes.items[n.parent].live == .off) return;
        var buf: [96]u8 = undefined;
        w.bridge.emitObject(w.pathIn(s, &buf, index), "Announcement", "", atspi.live(live), 0, .{ .str = text });
    }
};
