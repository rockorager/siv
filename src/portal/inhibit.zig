//! org.freedesktop.portal.Inhibit: keeping the session from logging out,
//! switching users, suspending, or going idle. The inhibition lasts until
//! the request is closed (`Request.cancel`). The portal answers once the
//! desktop applied it; it never answers when it allowed none of the
//! flags, so callers must not wait for the response.

const dbus = @import("dbus");
const Client = @import("Client.zig");
const Request = @import("Request.zig");
const vardict = @import("vardict.zig");

pub const interface = "org.freedesktop.portal.Inhibit";

pub const Flags = packed struct(u32) {
    logout: bool = false,
    user_switch: bool = false,
    suspend_: bool = false,
    idle: bool = false,
    _: u28 = 0,
};

pub fn start(r: *Request, client: *Client, parent: []const u8, flags: Flags, reason: []const u8) dbus.Connection.Error!void {
    const tok = r.token(client);
    var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "Inhibit");
    write(&b.body, tok, parent, flags, reason) catch |err| {
        b.deinit();
        return err;
    };
    try r.start(&b);
}

fn write(e: *dbus.Encoder, tok: []const u8, parent: []const u8, flags: Flags, reason: []const u8) dbus.codec.EncodeError!void {
    try e.writeAll(.{ parent, @as(u32, @bitCast(flags)) });
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    if (reason.len > 0) try w.put("reason", reason);
    try w.end();
}
