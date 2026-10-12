//! org.freedesktop.portal.OpenURI: opening URIs and files in the user's
//! preferred application, and showing files in the file manager.
//!
//! A file:// URI goes to OpenFile (or OpenDirectory) with a file
//! descriptor instead of OpenURI: inside Flatpak the portal refuses file
//! URIs, and outside it the descriptor works the same. So one call opens
//! files in and out of the sandbox.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus");
const Client = @import("Client.zig");
const Request = @import("Request.zig");
const vardict = @import("vardict.zig");
const uri_mod = @import("uri.zig");

pub const interface = "org.freedesktop.portal.OpenURI";

pub const Options = struct {
    /// Let the user choose the application even if there is a default.
    ask: bool = false,
    /// Let the application write to the file (sandboxed handlers).
    writable: bool = false,
    /// Show the file in its folder (OpenDirectory) instead of opening it.
    show_in_folder: bool = false,
    /// An xdg-activation token, so the application opened may take focus.
    activation_token: []const u8 = "",
};

pub const Error = dbus.Connection.Error || error{FileNotFound};

/// Opens `uri` for the window `parent` ("wayland:<handle>", or empty).
pub fn openUri(r: *Request, client: *Client, parent: []const u8, uri: []const u8, o: Options) Error!void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (uri_mod.filePath(uri, buf[0 .. buf.len - 1])) |p| {
        buf[p.len] = 0;
        return openPath(r, client, parent, buf[0..p.len :0], o);
    }
    if (o.show_in_folder) return error.InvalidValue;
    const tok = r.token(client);
    var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "OpenURI");
    writeOptions(&b.body, tok, .{ parent, uri }, o) catch |err| {
        b.deinit();
        return err;
    };
    try r.start(&b);
}

/// Opens a local file by path.
pub fn openPath(r: *Request, client: *Client, parent: []const u8, path: [:0]const u8, o: Options) Error!void {
    const flags: linux.O = if (o.writable and !o.show_in_folder) .{ .ACCMODE = .RDWR, .CLOEXEC = true } else .{ .PATH = true, .CLOEXEC = true };
    const rc = linux.open(path, flags, 0);
    if (linux.errno(rc) != .SUCCESS) return error.FileNotFound;
    const fd: i32 = @intCast(rc);
    // The message holds a duplicate.
    defer _ = linux.close(fd);
    return openFd(r, client, parent, fd, o);
}

/// Opens the file `fd` refers to (duplicated, so the caller keeps it).
pub fn openFd(r: *Request, client: *Client, parent: []const u8, fd: i32, o: Options) Error!void {
    const tok = r.token(client);
    var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, if (o.show_in_folder) "OpenDirectory" else "OpenFile");
    writeOptions(&b.body, tok, .{ parent, dbus.Fd{ .fd = fd } }, o) catch |err| {
        b.deinit();
        return err;
    };
    try r.start(&b);
}

fn writeOptions(e: *dbus.Encoder, tok: []const u8, args: anytype, o: Options) dbus.codec.EncodeError!void {
    try e.writeAll(args);
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    if (!o.show_in_folder) {
        if (o.ask) try w.put("ask", true);
        if (o.writable) try w.put("writable", true);
    }
    if (o.activation_token.len > 0) try w.put("activation_token", o.activation_token);
    try w.end();
}
