//! A stand-in for xdg-desktop-portal's frontend, for hermetic tests on a
//! test bus: it records every portal call and answers requests with a
//! response the test chooses, at once or when the test says. Not part of
//! libsiv.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus");
const Client = @import("Client.zig");
const vardict = @import("vardict.zig");

const Connection = dbus.Connection;
const gpa = std.testing.allocator;

pub const Frontend = struct {
    conn: *Connection,
    owner: Connection.NameOwner = .{ .name = Client.portal_name },
    doc_owner: Connection.NameOwner = .{ .name = Client.documents_name },
    obj: dbus.Object = undefined,
    doc_obj: dbus.Object = undefined,
    calls: std.ArrayList(Call) = .empty,
    /// Paths that got Request.Close or Session.Close.
    closed: std.ArrayList([]u8) = .empty,
    /// Answer requests at once; otherwise they wait for `respond`.
    immediate: bool = true,
    code: u32 = 0,
    /// Writes the results of the response to `call`.
    results: ?*const fn (f: *Frontend, call: *const Call, w: vardict.Writer) anyerror!void = null,
    ctx: ?*anyopaque = null,
    /// Reply to calls with this D-Bus error instead.
    error_name: ?[]const u8 = null,

    pub const Call = struct {
        interface: []u8,
        member: []u8,
        sender: []u8,
        signature: []u8,
        body: []u8,
        /// The request path the call created, if any.
        request: []u8,
        /// For calls with fds: the path of the first one.
        fd_path: []u8,

        pub fn decoder(c: *const Call) dbus.Decoder {
            return .init(c.body, c.signature, .little, &.{});
        }

        /// The call's options (its last argument when that is a{sv}).
        pub fn options(c: *const Call) vardict.Reader {
            var d = c.decoder();
            while (d.peek() != null) {
                if (std.mem.eql(u8, d.remainingSignature(), "a{sv}")) return vardict.Reader.take(&d) catch .empty;
                d.skip() catch return .empty;
            }
            return .empty;
        }

        /// The first string argument (the parent window for most calls).
        pub fn firstString(c: *const Call) []const u8 {
            var d = c.decoder();
            while (d.peek()) |code| {
                if (code == 's') return d.readString() catch "";
                d.skip() catch return "";
            }
            return "";
        }

        fn deinit(c: *Call) void {
            inline for (.{ "interface", "member", "sender", "signature", "body", "request", "fd_path" }) |f| gpa.free(@field(c, f));
        }
    };

    const request_iface: dbus.Interface = .{ .name = "org.freedesktop.portal.Request", .methods = &.{.{ .name = "Close", .func = close }} };
    const session_iface: dbus.Interface = .{ .name = "org.freedesktop.portal.Session", .methods = &.{.{ .name = "Close", .func = close }} };

    fn m(name: []const u8, in: []const u8, out: []const u8) dbus.Method {
        return .{ .name = name, .in = in, .out = out, .func = handle };
    }

    const portal_ifaces = [_]*const dbus.Interface{
        &.{ .name = "org.freedesktop.portal.FileChooser", .methods = &.{ m("OpenFile", "ssa{sv}", "o"), m("SaveFile", "ssa{sv}", "o") } },
        &.{ .name = "org.freedesktop.portal.OpenURI", .methods = &.{ m("OpenURI", "ssa{sv}", "o"), m("OpenFile", "sha{sv}", "o"), m("OpenDirectory", "sha{sv}", "o") } },
        &.{ .name = "org.freedesktop.portal.Notification", .methods = &.{ m("AddNotification", "sa{sv}", ""), m("RemoveNotification", "s", "") } },
        &.{ .name = "org.freedesktop.portal.Inhibit", .methods = &.{m("Inhibit", "sua{sv}", "o")} },
        &.{ .name = "org.freedesktop.portal.Screenshot", .methods = &.{ m("Screenshot", "sa{sv}", "o"), m("PickColor", "sa{sv}", "o") } },
        &.{ .name = "org.freedesktop.portal.ScreenCast", .methods = &.{ m("CreateSession", "a{sv}", "o"), m("SelectSources", "oa{sv}", "o"), m("Start", "osa{sv}", "o"), m("OpenPipeWireRemote", "oa{sv}", "h") } },
        &.{ .name = "org.freedesktop.portal.GlobalShortcuts", .methods = &.{ m("CreateSession", "a{sv}", "o"), m("BindShortcuts", "oa(sa{sv})sa{sv}", "o"), m("ListShortcuts", "oa{sv}", "o") } },
        &.{ .name = "org.freedesktop.portal.Print", .methods = &.{ m("PreparePrint", "ssa{sv}a{sv}a{sv}", "o"), m("Print", "ssha{sv}", "o") } },
    };

    const documents_iface: dbus.Interface = .{ .name = "org.freedesktop.portal.Documents", .methods = &.{
        m("GetMountPoint", "", "ay"),
        m("AddFull", "ahusas", "asa{sv}"),
    } };

    pub fn start(f: *Frontend) !void {
        f.obj = .{ .path = Client.portal_path, .ctx = f, .subtree = .{ .lookup = lookup } };
        f.doc_obj = .{ .path = Client.documents_path, .ctx = f, .interfaces = &.{&documents_iface} };
        try f.conn.exportObject(&f.obj);
        try f.conn.exportObject(&f.doc_obj);
        try f.conn.requestName(&f.owner);
        try f.conn.requestName(&f.doc_owner);
    }

    pub fn owns(f: *const Frontend) bool {
        return f.owner.state == .primary and f.doc_owner.state == .primary;
    }

    pub fn deinit(f: *Frontend) void {
        for (f.calls.items) |*c| c.deinit();
        f.calls.deinit(gpa);
        for (f.closed.items) |p| gpa.free(p);
        f.closed.deinit(gpa);
    }

    fn lookup(o: *dbus.Object, path: []const u8) ?dbus.Node {
        if (std.mem.eql(u8, path, Client.portal_path)) return .{ .ctx = o.ctx, .interfaces = &portal_ifaces };
        if (std.mem.startsWith(u8, path, Client.portal_path ++ "/request/")) return .{ .ctx = o.ctx, .interfaces = &.{&request_iface} };
        if (std.mem.startsWith(u8, path, Client.portal_path ++ "/session/")) return .{ .ctx = o.ctx, .interfaces = &.{&session_iface} };
        return null;
    }

    pub fn last(f: *Frontend) ?*Call {
        if (f.calls.items.len == 0) return null;
        return &f.calls.items[f.calls.items.len - 1];
    }

    /// The last call of `member`.
    pub fn find(f: *Frontend, member: []const u8) ?*Call {
        var i = f.calls.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, f.calls.items[i].member, member)) return &f.calls.items[i];
        }
        return null;
    }

    pub fn wasClosed(f: *const Frontend, path: []const u8) bool {
        for (f.closed.items) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }

    fn close(r: *dbus.Request) anyerror!void {
        const f: *Frontend = @ptrCast(@alignCast(r.node.ctx));
        try f.closed.append(gpa, try gpa.dupe(u8, r.path));
    }

    fn objectPath(buf: []u8, kind: []const u8, sender: []const u8, token: []const u8) ![]const u8 {
        const out = try std.fmt.bufPrint(buf, "{s}/{s}/{s}/{s}", .{ Client.portal_path, kind, sender[1..], token });
        for (out[Client.portal_path.len + kind.len + 2 ..][0 .. sender.len - 1]) |*ch| {
            if (ch.* == '.') ch.* = '_';
        }
        return out;
    }

    fn handle(r: *dbus.Request) anyerror!void {
        const f: *Frontend = @ptrCast(@alignCast(r.node.ctx));
        const msg = r.msg;
        if (f.error_name) |e| return r.replyError(e, "refused by the test");
        var call: Call = .{
            .interface = try gpa.dupe(u8, msg.interface.?),
            .member = try gpa.dupe(u8, msg.member.?),
            .sender = try gpa.dupe(u8, msg.sender orelse ":0.0"),
            .signature = try gpa.dupe(u8, msg.signature),
            .body = try gpa.dupe(u8, msg.bodyBytes()),
            .request = &.{},
            .fd_path = &.{},
        };
        errdefer call.deinit();
        if (msg.fds.len > 0) {
            var pbuf: [64]u8 = undefined;
            var lbuf: [std.fs.max_path_bytes]u8 = undefined;
            const proc = try std.fmt.bufPrintSentinel(&pbuf, "/proc/self/fd/{d}", .{msg.fds[0]}, 0);
            const n = linux.readlink(proc, &lbuf, lbuf.len);
            if (linux.errno(n) == .SUCCESS) call.fd_path = try gpa.dupe(u8, lbuf[0..n]);
        }
        const opts = call.options();
        const member = call.member;
        const iface = call.interface;
        if (std.mem.eql(u8, iface, "org.freedesktop.portal.Documents")) {
            try f.calls.append(gpa, call);
            if (std.mem.eql(u8, member, "GetMountPoint")) {
                var b = r.newReply();
                errdefer b.deinit();
                try vardict.writeBytesZ(&b.body, "/run/user/1000/doc");
                return r.sendReply(&b);
            }
            var b = r.newReply();
            errdefer b.deinit();
            try b.body.write(@as([]const []const u8, &.{"a1b2c3"}));
            try b.body.beginArray("{sv}");
            try b.body.endArray();
            return r.sendReply(&b);
        }
        if (std.mem.eql(u8, member, "AddNotification") or std.mem.eql(u8, member, "RemoveNotification")) {
            try f.calls.append(gpa, call);
            return r.reply(.{});
        }
        if (std.mem.eql(u8, member, "OpenPipeWireRemote")) {
            try f.calls.append(gpa, call);
            var fds: [2]i32 = undefined;
            if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.SystemResources;
            defer _ = linux.close(fds[0]);
            defer _ = linux.close(fds[1]);
            return r.reply(.{dbus.Fd{ .fd = fds[0] }});
        }
        const token = opts.string("handle_token") orelse "t";
        var pbuf: [Client.max_path]u8 = undefined;
        const path = try objectPath(&pbuf, "request", call.sender, token);
        call.request = try gpa.dupe(u8, path);
        try f.calls.append(gpa, call);
        try r.reply(.{dbus.ObjectPath{ .path = path }});
        if (f.immediate) try f.respond(f.calls.items.len - 1, f.code);
    }

    /// Sends the Response of call `index` with `code` and the results
    /// from `results`. Session-creating calls report their session.
    pub fn respond(f: *Frontend, index: usize, code: u32) !void {
        const call = &f.calls.items[index];
        var b = f.conn.signal(call.request, "org.freedesktop.portal.Request", "Response");
        b.header.destination = call.sender;
        errdefer b.deinit();
        try b.body.writeUint32(code);
        const w = try vardict.Writer.begin(&b.body);
        if (std.mem.eql(u8, call.member, "CreateSession")) {
            const opts = call.options();
            var sbuf: [Client.max_path]u8 = undefined;
            try w.put("session_handle", try objectPath(&sbuf, "session", call.sender, opts.string("session_handle_token") orelse "s"));
        }
        if (f.results) |res| try res(f, call, w);
        try w.end();
        _ = try f.conn.send(&b);
    }

    /// Emits a signal on the portal object to the sender of the last call.
    pub fn emit(f: *Frontend, interface: []const u8, member: []const u8, args: anytype) !void {
        var b = f.conn.signal(Client.portal_path, interface, member);
        errdefer b.deinit();
        try b.body.writeAll(args);
        _ = try f.conn.send(&b);
    }

    /// Emits Session.Closed for `path`.
    pub fn closeSession(f: *Frontend, path: []const u8) !void {
        var b = f.conn.signal(path, "org.freedesktop.portal.Session", "Closed");
        errdefer b.deinit();
        try b.body.beginArray("{sv}");
        try b.body.endArray();
        _ = try f.conn.send(&b);
    }
};
