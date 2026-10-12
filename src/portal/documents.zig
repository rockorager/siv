//! org.freedesktop.portal.Documents: the document portal, which makes
//! files available to sandboxed applications through its FUSE mount
//! ($XDG_RUNTIME_DIR/doc/<id>/<name>). The file chooser registers the
//! files it returns to a sandboxed application itself; an application
//! registers files explicitly to hand them to another sandboxed
//! application (drag and drop, sharing) with the permissions it chooses.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus");
const Client = @import("Client.zig");
const Request = @import("Request.zig");
const vardict = @import("vardict.zig");

pub const interface = "org.freedesktop.portal.Documents";

pub const Permissions = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    grant_permissions: bool = false,
    delete: bool = false,
    _: u28 = 0,
};

pub const Flags = packed struct(u32) {
    /// Return the existing document if the file is registered already.
    reuse_existing: bool = false,
    /// Keep the document after this session.
    persistent: bool = false,
    /// Only register the file if the application `app_id` cannot see it.
    as_needed_by_app: bool = false,
    /// Register a directory.
    export_directory: bool = false,
    _: u28 = 0,
};

pub const Result = union(enum) {
    /// The document's id and its path in the document portal's mount
    /// (empty if the file needed no registration, with as_needed_by_app).
    added: struct { id: []const u8, path: []const u8 },
    failed: Request.Failure,
};

/// Registers one file. Owned by the caller; stays in place until `func`
/// ran or `cancel` returned.
pub const Add = struct {
    func: *const fn (a: *Add, result: Result) void,
    client: *Client = undefined,
    mount_serial: u32 = 0,
    add_serial: u32 = 0,
    mount_buf: [512]u8 = undefined,
    mount_len: u16 = 0,
    name_buf: [256]u8 = undefined,
    name_len: u16 = 0,
    failed: bool = false,

    pub const Error = dbus.Connection.Error || error{ FileNotFound, NameTooLong };

    /// Registers `path` and grants `app_id` (empty for none) `permissions`.
    pub fn start(a: *Add, client: *Client, path: [:0]const u8, app_id: []const u8, permissions: Permissions, flags: Flags) Error!void {
        const base = std.fs.path.basename(path);
        if (base.len > a.name_buf.len) return error.NameTooLong;
        @memcpy(a.name_buf[0..base.len], base);
        a.name_len = @intCast(base.len);
        a.client = client;
        a.failed = false;
        a.mount_len = 0;
        const rc = linux.open(path, .{ .PATH = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.FileNotFound;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        const conn = client.conn;
        var m = conn.methodCall(Client.documents_name, Client.documents_path, interface, "GetMountPoint");
        a.mount_serial = try conn.call(&m, onMount, a, .{});
        errdefer {
            conn.cancelCall(a.mount_serial);
            a.mount_serial = 0;
        }
        var b = conn.methodCall(Client.documents_name, Client.documents_path, interface, "AddFull");
        writeAdd(&b.body, fd, flags, app_id, permissions) catch |err| {
            b.deinit();
            return err;
        };
        a.add_serial = try conn.call(&b, onAdd, a, .{});
    }

    pub fn cancel(a: *Add) void {
        if (a.mount_serial != 0) a.client.conn.cancelCall(a.mount_serial);
        if (a.add_serial != 0) a.client.conn.cancelCall(a.add_serial);
        a.mount_serial = 0;
        a.add_serial = 0;
    }

    fn fail(a: *Add, f: Request.Failure) void {
        a.cancel();
        if (a.failed) return;
        a.failed = true;
        a.func(a, .{ .failed = f });
    }

    fn onMount(ctx: ?*anyopaque, reply: dbus.Connection.Reply) void {
        const a: *Add = @ptrCast(@alignCast(ctx));
        a.mount_serial = 0;
        switch (reply) {
            .ok => |m| {
                var d = m.body();
                const p = vardict.readBytesZ(&d) catch return a.fail(.failed);
                if (p.len > a.mount_buf.len) return a.fail(.failed);
                @memcpy(a.mount_buf[0..p.len], p);
                a.mount_len = @intCast(p.len);
            },
            .err => |m| a.fail(Request.failureOf(m.error_name.?)),
            .failed => a.fail(.disconnected),
        }
    }

    fn onAdd(ctx: ?*anyopaque, reply: dbus.Connection.Reply) void {
        const a: *Add = @ptrCast(@alignCast(ctx));
        a.add_serial = 0;
        switch (reply) {
            .ok => |m| {
                // GetMountPoint was sent first, so its reply came first.
                if (a.failed) return;
                var d = m.body();
                const arr = d.beginArray() catch return a.fail(.failed);
                const id = if (arr.next(&d)) d.readString() catch return a.fail(.failed) else "";
                var buf: [1024]u8 = undefined;
                const path = if (id.len == 0) "" else std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ a.mount_buf[0..a.mount_len], id, a.name_buf[0..a.name_len] }) catch return a.fail(.failed);
                a.func(a, .{ .added = .{ .id = id, .path = path } });
            },
            .err => |m| a.fail(Request.failureOf(m.error_name.?)),
            .failed => a.fail(.disconnected),
        }
    }
};

fn writeAdd(e: *dbus.Encoder, fd: i32, flags: Flags, app_id: []const u8, p: Permissions) dbus.codec.EncodeError!void {
    try e.beginArray("h");
    try e.writeFd(fd);
    try e.endArray();
    try e.writeAll(.{ @as(u32, @bitCast(flags)), app_id });
    try e.beginArray("s");
    if (p.read) try e.writeString("read");
    if (p.write) try e.writeString("write");
    if (p.grant_permissions) try e.writeString("grant-permissions");
    if (p.delete) try e.writeString("delete");
    try e.endArray();
}
