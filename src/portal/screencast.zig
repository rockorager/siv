//! org.freedesktop.portal.ScreenCast: recording monitors and windows.
//! A cast is a session through four steps (CreateSession, SelectSources,
//! Start, OpenPipeWireRemote); the result is a PipeWire remote fd and
//! the node ids of the streams on it. siv does not speak PipeWire: the
//! application connects to the fd with its own PipeWire client.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus");
const Client = @import("Client.zig");
const Request = @import("Request.zig");
const Session = @import("Session.zig");
const vardict = @import("vardict.zig");

pub const interface = "org.freedesktop.portal.ScreenCast";

pub const SourceTypes = packed struct(u32) {
    monitor: bool = false,
    window: bool = false,
    virtual: bool = false,
    _: u29 = 0,
};

pub const CursorMode = enum(u32) { default = 0, hidden = 1, embedded = 2, metadata = 4 };

pub const PersistMode = enum(u32) { none = 0, transient = 1, persistent = 2 };

pub const max_streams = 16;
pub const max_token = 64;

pub const Stream = struct {
    /// The PipeWire node id.
    node_id: u32,
    /// What it shows: SourceTypes bits (1 monitor, 2 window, 4 virtual), 0
    /// if the portal did not say.
    source_type: u32 = 0,
    /// Position in the compositor's space and size, in logical pixels; 0
    /// when unknown.
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

pub const Options = struct {
    types: SourceTypes = .{ .monitor = true },
    multiple: bool = false,
    cursor_mode: CursorMode = .default,
    persist_mode: PersistMode = .none,
    /// A token from an earlier cast, to restore its sources without asking.
    restore_token: []const u8 = "",
};

pub const Event = union(enum) {
    /// The cast runs: `ScreenCast.streams`, `pipewire_fd`, and
    /// `restoreToken` are set.
    started,
    /// The user cancelled, or the portal ended the setup.
    ended: Request.Response,
    failed: Request.Failure,
    /// The portal closed the running cast.
    closed,
};

pub const ScreenCast = struct {
    func: *const fn (sc: *ScreenCast, event: Event) void,
    client: *Client = undefined,
    session: Session = .{},
    req: Request = .{ .func = onResponse },
    stage: Stage = .idle,
    options: Options = .{},
    token_buf: [max_token]u8 = undefined,
    token_len: u8 = 0,
    parent_buf: [128]u8 = undefined,
    parent_len: u8 = 0,
    stream_buf: [max_streams]Stream = undefined,
    stream_count: u8 = 0,
    /// The PipeWire remote, owned by the cast until taken.
    pipewire_fd: i32 = -1,
    open_serial: u32 = 0,

    const Stage = enum { idle, creating, selecting, starting, opening, running, done };

    pub fn streams(sc: *const ScreenCast) []const Stream {
        return sc.stream_buf[0..sc.stream_count];
    }

    /// The token to restore this cast's sources later; empty if the
    /// portal gave none (persist mode none).
    pub fn restoreToken(sc: *const ScreenCast) []const u8 {
        return sc.token_buf[0..sc.token_len];
    }

    /// Starts the cast for the window `parent`. Strings are copied.
    pub fn start(sc: *ScreenCast, client: *Client, parent: []const u8, o: Options) (dbus.Connection.Error || error{NameTooLong})!void {
        std.debug.assert(sc.stage == .idle);
        if (parent.len > sc.parent_buf.len or o.restore_token.len > sc.token_buf.len) return error.NameTooLong;
        sc.client = client;
        sc.options = o;
        @memcpy(sc.token_buf[0..o.restore_token.len], o.restore_token);
        sc.token_len = @intCast(o.restore_token.len);
        @memcpy(sc.parent_buf[0..parent.len], parent);
        sc.parent_len = @intCast(parent.len);
        sc.session.on_closed = onClosed;
        const tok = sc.req.token(client);
        var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "CreateSession");
        writeCreate(&b.body, tok, sc.session.token(client)) catch |err| {
            b.deinit();
            return err;
        };
        try sc.req.start(&b);
        sc.stage = .creating;
    }

    /// Ends the cast and closes the PipeWire fd if it was not taken.
    pub fn close(sc: *ScreenCast) void {
        sc.req.abandon();
        if (sc.open_serial != 0) sc.client.conn.cancelCall(sc.open_serial);
        sc.open_serial = 0;
        if (sc.stage != .idle) sc.session.close();
        if (sc.pipewire_fd >= 0) _ = linux.close(sc.pipewire_fd);
        sc.pipewire_fd = -1;
        sc.stage = .done;
    }

    /// Takes the PipeWire fd; the caller closes it.
    pub fn takePipewireFd(sc: *ScreenCast) ?i32 {
        if (sc.pipewire_fd < 0) return null;
        defer sc.pipewire_fd = -1;
        return sc.pipewire_fd;
    }

    fn finish(sc: *ScreenCast, event: Event) void {
        if (event != .started) {
            sc.session.close();
            sc.stage = .done;
        }
        sc.func(sc, event);
    }

    fn step(sc: *ScreenCast, member: []const u8) void {
        const tok = sc.req.token(sc.client);
        var b = sc.client.conn.methodCall(Client.portal_name, Client.portal_path, interface, member);
        const r = if (std.mem.eql(u8, member, "SelectSources")) writeSelect(&b.body, tok, sc.session.path(), sc) else writeStart(&b.body, tok, sc.session.path(), sc.parent_buf[0..sc.parent_len]);
        r catch {
            b.deinit();
            return sc.finish(.{ .failed = .failed });
        };
        sc.req.start(&b) catch return sc.finish(.{ .failed = .disconnected });
    }

    fn onResponse(r: *Request, outcome: Request.Outcome) void {
        const sc: *ScreenCast = @fieldParentPtr("req", r);
        const res = switch (outcome) {
            .failed => |f| return sc.finish(.{ .failed = f }),
            .response => |res| res,
        };
        if (res.code != .success) return sc.finish(.{ .ended = res.code });
        switch (sc.stage) {
            .creating => {
                const handle = res.results.string("session_handle") orelse res.results.objectPath("session_handle") orelse return sc.finish(.{ .failed = .failed });
                sc.session.opened(handle) catch return sc.finish(.{ .failed = .failed });
                sc.stage = .selecting;
                sc.step("SelectSources");
            },
            .selecting => {
                sc.stage = .starting;
                sc.step("Start");
            },
            .starting => {
                sc.readStreams(&res.results);
                if (res.results.string("restore_token")) |t| if (t.len <= sc.token_buf.len) {
                    @memcpy(sc.token_buf[0..t.len], t);
                    sc.token_len = @intCast(t.len);
                };
                sc.stage = .opening;
                var b = sc.client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "OpenPipeWireRemote");
                writeOpen(&b.body, sc.session.path()) catch {
                    b.deinit();
                    return sc.finish(.{ .failed = .failed });
                };
                sc.open_serial = sc.client.conn.call(&b, onOpened, sc, .{}) catch return sc.finish(.{ .failed = .disconnected });
            },
            else => {},
        }
    }

    fn readStreams(sc: *ScreenCast, results: *const vardict.Reader) void {
        sc.stream_count = 0;
        var d = results.get("streams", "a(ua{sv})") orelse return;
        const a = d.beginArray() catch return;
        while (a.next(&d) and sc.stream_count < max_streams) {
            d.beginStruct() catch return;
            const node = d.readUint32() catch return;
            const props = vardict.Reader.take(&d) catch return;
            d.endStruct() catch return;
            var s: Stream = .{ .node_id = node, .source_type = props.uint("source_type") orelse 0 };
            if (props.get("position", "(ii)")) |pd| {
                var p = pd;
                if (p.read(struct { i32, i32 })) |xy| {
                    s.x = xy[0];
                    s.y = xy[1];
                } else |_| {}
            }
            if (props.get("size", "(ii)")) |sd| {
                var p = sd;
                if (p.read(struct { i32, i32 })) |wh| {
                    s.width = wh[0];
                    s.height = wh[1];
                } else |_| {}
            }
            sc.stream_buf[sc.stream_count] = s;
            sc.stream_count += 1;
        }
    }

    fn onOpened(ctx: ?*anyopaque, reply: dbus.Connection.Reply) void {
        const sc: *ScreenCast = @ptrCast(@alignCast(ctx));
        sc.open_serial = 0;
        switch (reply) {
            .ok => |m| {
                var d = m.body();
                const fd = d.readFd() catch return sc.finish(.{ .failed = .failed });
                for (m.fds, 0..) |f, i| if (f == fd) {
                    sc.pipewire_fd = m.takeFd(i).?;
                };
                if (sc.pipewire_fd < 0) return sc.finish(.{ .failed = .failed });
                sc.stage = .running;
                sc.finish(.started);
            },
            .err => |m| sc.finish(.{ .failed = Request.failureOf(m.error_name.?) }),
            .failed => sc.finish(.{ .failed = .disconnected }),
        }
    }

    fn onClosed(s: *Session) void {
        const sc: *ScreenCast = @fieldParentPtr("session", s);
        sc.req.abandon();
        const was_running = sc.stage == .running;
        sc.stage = .done;
        sc.func(sc, if (was_running) .closed else .{ .ended = .other });
    }
};

fn writeCreate(e: *dbus.Encoder, tok: []const u8, session_tok: []const u8) dbus.codec.EncodeError!void {
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    try w.put("session_handle_token", session_tok);
    try w.end();
}

fn writeSelect(e: *dbus.Encoder, tok: []const u8, session: []const u8, sc: *const ScreenCast) dbus.codec.EncodeError!void {
    try e.write(dbus.ObjectPath{ .path = session });
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    try w.put("types", @as(u32, @bitCast(sc.options.types)));
    try w.put("multiple", sc.options.multiple);
    if (sc.options.cursor_mode != .default) try w.put("cursor_mode", @intFromEnum(sc.options.cursor_mode));
    if (sc.options.persist_mode != .none) try w.put("persist_mode", @intFromEnum(sc.options.persist_mode));
    if (sc.token_len > 0) try w.put("restore_token", @as([]const u8, sc.token_buf[0..sc.token_len]));
    try w.end();
}

fn writeStart(e: *dbus.Encoder, tok: []const u8, session: []const u8, parent: []const u8) dbus.codec.EncodeError!void {
    try e.writeAll(.{ dbus.ObjectPath{ .path = session }, parent });
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    try w.end();
}

fn writeOpen(e: *dbus.Encoder, session: []const u8) dbus.codec.EncodeError!void {
    try e.write(dbus.ObjectPath{ .path = session });
    const w = try vardict.Writer.begin(e);
    try w.end();
}
