//! org.freedesktop.portal.Screenshot: taking a screenshot (the result's
//! `uri`) and picking a color from the screen (`color`, (ddd) in sRGB).

const std = @import("std");
const dbus = @import("dbus");
const Client = @import("Client.zig");
const Request = @import("Request.zig");
const vardict = @import("vardict.zig");

pub const interface = "org.freedesktop.portal.Screenshot";

pub const Options = struct {
    /// Let the user choose the area and options first.
    interactive: bool = false,
    modal: bool = true,
};

pub fn screenshot(r: *Request, client: *Client, parent: []const u8, o: Options) dbus.Connection.Error!void {
    const tok = r.token(client);
    var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "Screenshot");
    write(&b.body, tok, parent, o) catch |err| {
        b.deinit();
        return err;
    };
    try r.start(&b);
}

fn write(e: *dbus.Encoder, tok: []const u8, parent: []const u8, o: Options) dbus.codec.EncodeError!void {
    try e.writeString(parent);
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    try w.put("modal", o.modal);
    try w.put("interactive", o.interactive);
    try w.end();
}

pub fn pickColor(r: *Request, client: *Client, parent: []const u8) dbus.Connection.Error!void {
    const tok = r.token(client);
    var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "PickColor");
    writePick(&b.body, tok, parent) catch |err| {
        b.deinit();
        return err;
    };
    try r.start(&b);
}

fn writePick(e: *dbus.Encoder, tok: []const u8, parent: []const u8) dbus.codec.EncodeError!void {
    try e.writeString(parent);
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    try w.end();
}

/// The picked color's sRGB components, clamped to [0, 1].
pub fn color(results: *const vardict.Reader) ?[3]f64 {
    var d = results.get("color", "(ddd)") orelse return null;
    const c = d.read(struct { f64, f64, f64 }) catch return null;
    var out: [3]f64 = .{ c[0], c[1], c[2] };
    for (&out) |*v| {
        if (!std.math.isFinite(v.*)) return null;
        v.* = std.math.clamp(v.*, 0, 1);
    }
    return out;
}
