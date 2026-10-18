//! org.freedesktop.portal.Trash (D42): TrashFile(fd) moves a file the
//! application opened to the trash. It only trashes: it says whether that
//! worked, not where the file went, so a file trashed this way cannot be
//! restored, listed, or deleted through it. Sandboxed applications use it
//! when they cannot reach the trash themselves.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus");
const Client = @import("Client.zig");
const Request = @import("Request.zig");

pub const interface = "org.freedesktop.portal.Trash";

pub const Result = union(enum) {
    trashed,
    /// The portal could not trash the file (it answered 0).
    refused,
    failed: Request.Failure,
};

/// One TrashFile call. Owned by the caller; stays in place until `func`
/// ran or `cancel` returned.
pub const Call = struct {
    func: *const fn (c: *Call, result: Result) void,
    client: *Client = undefined,
    serial: u32 = 0,

    pub const Error = dbus.Connection.Error || error{FileNotFound};

    /// Trashes `path`, a link itself rather than its target.
    pub fn start(c: *Call, client: *Client, path: [:0]const u8) Error!void {
        const rc = linux.open(path, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.FileNotFound;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        c.client = client;
        c.serial = try client.conn.callMethod(Client.portal_name, Client.portal_path, interface, "TrashFile", .{dbus.Fd{ .fd = fd }}, onReply, c);
    }

    pub fn cancel(c: *Call) void {
        if (c.serial != 0) c.client.conn.cancelCall(c.serial);
        c.serial = 0;
    }

    fn onReply(ctx: ?*anyopaque, reply: dbus.Connection.Reply) void {
        const c: *Call = @ptrCast(@alignCast(ctx));
        c.serial = 0;
        switch (reply) {
            .ok => |m| {
                var d = m.body();
                const code = d.readUint32() catch return c.func(c, .{ .failed = .failed });
                c.func(c, if (code == 1) .trashed else .refused);
            },
            .err => |m| c.func(c, .{ .failed = Request.failureOf(m.error_name.?) }),
            .failed => c.func(c, .{ .failed = .disconnected }),
        }
    }
};
