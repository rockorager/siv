//! org.freedesktop.portal.GlobalShortcuts: shortcuts that work while the
//! application is not focused. A session (CreateSession) binds the
//! application's shortcuts (BindShortcuts), where the desktop lets the
//! user assign triggers; Activated and Deactivated follow the session.

const std = @import("std");
const dbus = @import("dbus");
const Client = @import("Client.zig");
const Request = @import("Request.zig");
const Session = @import("Session.zig");
const vardict = @import("vardict.zig");

pub const interface = "org.freedesktop.portal.GlobalShortcuts";

pub const Shortcut = struct {
    id: []const u8,
    description: []const u8,
    /// A trigger to suggest, in the XDG shortcuts format ("CTRL+a").
    preferred_trigger: []const u8 = "",
};

/// Iterates a(sa{sv}) shortcut lists from the portal.
pub const BoundIterator = struct {
    d: dbus.Decoder,
    a: dbus.Decoder.Array,

    pub const Bound = struct { id: []const u8, description: []const u8, trigger: []const u8 };

    pub fn init(d: dbus.Decoder) ?BoundIterator {
        var it: BoundIterator = .{ .d = d, .a = undefined };
        it.a = it.d.beginArray() catch return null;
        return it;
    }

    pub fn next(it: *BoundIterator) ?Bound {
        if (!it.a.next(&it.d)) return null;
        it.d.beginStruct() catch return null;
        const id = it.d.readString() catch return null;
        const props = vardict.Reader.take(&it.d) catch return null;
        it.d.endStruct() catch return null;
        return .{ .id = id, .description = props.string("description") orelse "", .trigger = props.string("trigger_description") orelse "" };
    }
};

pub const Event = union(enum) {
    /// BindShortcuts answered: the shortcuts as bound, with the triggers
    /// the user assigned.
    bound: BoundIterator,
    ended: Request.Response,
    failed: Request.Failure,
    activated: struct { id: []const u8, timestamp_ms: u64 },
    deactivated: struct { id: []const u8, timestamp_ms: u64 },
    /// The user changed the triggers.
    changed: BoundIterator,
    /// The portal closed the session.
    closed,
};

const Sub = struct { sub: dbus.Connection.Subscription, g: *GlobalShortcuts };

pub const GlobalShortcuts = struct {
    func: *const fn (g: *GlobalShortcuts, event: Event) void,
    /// The shortcuts to bind, borrowed until the bind answers.
    shortcuts: []const Shortcut = &.{},
    client: *Client = undefined,
    session: Session = .{},
    req: Request = .{ .func = onResponse },
    stage: enum { idle, creating, binding, bound, done } = .idle,
    parent_buf: [128]u8 = undefined,
    parent_len: u8 = 0,
    subs: [3]Sub = undefined,
    arg: [1]dbus.match.Arg = undefined,
    subscribed: bool = false,

    /// Creates the session and binds `shortcuts` for the window `parent`.
    pub fn bind(g: *GlobalShortcuts, client: *Client, parent: []const u8, shortcuts: []const Shortcut) (dbus.Connection.Error || error{NameTooLong})!void {
        if (parent.len > g.parent_buf.len) return error.NameTooLong;
        g.client = client;
        g.shortcuts = shortcuts;
        @memcpy(g.parent_buf[0..parent.len], parent);
        g.parent_len = @intCast(parent.len);
        if (g.stage == .bound) return g.sendBind();
        std.debug.assert(g.stage == .idle);
        g.session.on_closed = onClosed;
        const tok = g.req.token(client);
        var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "CreateSession");
        writeCreate(&b.body, tok, g.session.token(client)) catch |err| {
            b.deinit();
            return err;
        };
        try g.req.start(&b);
        g.stage = .creating;
    }

    pub fn close(g: *GlobalShortcuts) void {
        g.req.abandon();
        g.unsubscribe();
        g.session.close();
        g.stage = .done;
    }

    fn sendBind(g: *GlobalShortcuts) (dbus.Connection.Error || error{NameTooLong})!void {
        const tok = g.req.token(g.client);
        var b = g.client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "BindShortcuts");
        writeBind(&b.body, tok, g.session.path(), g.shortcuts, g.parent_buf[0..g.parent_len]) catch |err| {
            b.deinit();
            return err;
        };
        try g.req.start(&b);
        g.stage = .binding;
    }

    fn subscribe(g: *GlobalShortcuts) dbus.Connection.Error!void {
        g.arg[0] = .{ .index = 0, .kind = .path, .value = g.session.path() };
        const members = [_][]const u8{ "Activated", "Deactivated", "ShortcutsChanged" };
        for (&g.subs, members, 0..) |*s, m, i| {
            s.* = .{ .g = g, .sub = .{
                .rule = .{ .type = .signal, .sender = Client.portal_name, .path = Client.portal_path, .interface = interface, .member = m, .args = &g.arg },
                .func = onSignal,
            } };
            g.client.conn.subscribe(&s.sub) catch |err| {
                for (g.subs[0..i]) |*p| g.client.conn.unsubscribe(&p.sub);
                return err;
            };
        }
        g.subscribed = true;
    }

    fn unsubscribe(g: *GlobalShortcuts) void {
        if (!g.subscribed) return;
        for (&g.subs) |*s| g.client.conn.unsubscribe(&s.sub);
        g.subscribed = false;
    }

    fn finish(g: *GlobalShortcuts, event: Event) void {
        g.unsubscribe();
        g.session.close();
        g.stage = .done;
        g.func(g, event);
    }

    fn onResponse(r: *Request, outcome: Request.Outcome) void {
        const g: *GlobalShortcuts = @fieldParentPtr("req", r);
        const res = switch (outcome) {
            .failed => |f| return g.finish(.{ .failed = f }),
            .response => |res| res,
        };
        if (res.code != .success) return g.finish(.{ .ended = res.code });
        switch (g.stage) {
            .creating => {
                const handle = res.results.string("session_handle") orelse res.results.objectPath("session_handle") orelse return g.finish(.{ .failed = .failed });
                g.session.opened(handle) catch return g.finish(.{ .failed = .failed });
                g.subscribe() catch return g.finish(.{ .failed = .disconnected });
                g.sendBind() catch return g.finish(.{ .failed = .disconnected });
            },
            .binding => {
                g.stage = .bound;
                const d = res.results.get("shortcuts", "a(sa{sv})") orelse dbus.Decoder.init(&empty_array, "a(sa{sv})", .little, &.{});
                g.func(g, .{ .bound = BoundIterator.init(d) orelse return });
            },
            else => {},
        }
    }

    const empty_array = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };

    fn onSignal(sub: *dbus.Connection.Subscription, m: *const dbus.Message) void {
        const g = @as(*Sub, @fieldParentPtr("sub", sub)).g;
        var d = m.body();
        _ = d.readObjectPath() catch return;
        const member = m.member.?;
        if (std.mem.eql(u8, member, "ShortcutsChanged")) {
            if (!std.mem.eql(u8, m.signature, "oa(sa{sv})")) return;
            g.func(g, .{ .changed = BoundIterator.init(d) orelse return });
            return;
        }
        if (!std.mem.eql(u8, m.signature, "osta{sv}")) return;
        const id = d.readString() catch return;
        const ts = d.readUint64() catch return;
        if (std.mem.eql(u8, member, "Activated")) {
            g.func(g, .{ .activated = .{ .id = id, .timestamp_ms = ts } });
        } else {
            g.func(g, .{ .deactivated = .{ .id = id, .timestamp_ms = ts } });
        }
    }

    fn onClosed(s: *Session) void {
        const g: *GlobalShortcuts = @fieldParentPtr("session", s);
        g.req.abandon();
        g.unsubscribe();
        g.stage = .done;
        g.func(g, .closed);
    }
};

fn writeCreate(e: *dbus.Encoder, tok: []const u8, session_tok: []const u8) dbus.codec.EncodeError!void {
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    try w.put("session_handle_token", session_tok);
    try w.end();
}

fn writeBind(e: *dbus.Encoder, tok: []const u8, session: []const u8, shortcuts: []const Shortcut, parent: []const u8) dbus.codec.EncodeError!void {
    try e.write(dbus.ObjectPath{ .path = session });
    try e.beginArray("(sa{sv})");
    for (shortcuts) |s| {
        try e.beginStruct();
        try e.writeString(s.id);
        const w = try vardict.Writer.begin(e);
        try w.put("description", s.description);
        if (s.preferred_trigger.len > 0) try w.put("preferred_trigger", s.preferred_trigger);
        try w.end();
        try e.endStruct();
    }
    try e.endArray();
    try e.writeString(parent);
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    try w.end();
}
