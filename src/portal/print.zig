//! org.freedesktop.portal.Print: printing a PDF the application made.
//!
//! `prepare` shows the print dialog; its response carries the settings
//! and page setup the user chose and a token. The application lays out
//! its pages for that page setup (`PageSetup.of`), writes them as a PDF,
//! and `print` sends the PDF's file descriptor with the token. The print
//! system applies the rest of the settings (copies, page ranges, n-up)
//! that the portal's backend kept with the token.

const std = @import("std");
const dbus = @import("dbus");
const Client = @import("Client.zig");
const Request = @import("Request.zig");
const vardict = @import("vardict.zig");

pub const interface = "org.freedesktop.portal.Print";

pub const Options = struct {
    modal: bool = true,
};

/// Shows the print dialog. A successful response has `token` (`token`)
/// and the page setup (`PageSetup.of`).
pub fn prepare(r: *Request, client: *Client, parent: []const u8, title: []const u8, o: Options) dbus.Connection.Error!void {
    const tok = r.token(client);
    var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "PreparePrint");
    writePrepare(&b.body, tok, parent, title, o) catch |err| {
        b.deinit();
        return err;
    };
    try r.start(&b);
}

fn writePrepare(e: *dbus.Encoder, tok: []const u8, parent: []const u8, title: []const u8, o: Options) dbus.codec.EncodeError!void {
    try e.writeAll(.{ parent, title });
    // No settings or page setup to start from: the dialog's defaults.
    try (try vardict.Writer.begin(e)).end();
    try (try vardict.Writer.begin(e)).end();
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    try w.put("modal", o.modal);
    try w.end();
}

/// Prints the PDF `fd` refers to (duplicated, so the caller keeps it)
/// with the token of a prepared dialog, or 0 to let the portal ask.
pub fn print(r: *Request, client: *Client, parent: []const u8, title: []const u8, fd: i32, prepared: u32, o: Options) dbus.Connection.Error!void {
    const tok = r.token(client);
    var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, "Print");
    writePrint(&b.body, tok, parent, title, fd, prepared, o) catch |err| {
        b.deinit();
        return err;
    };
    try r.start(&b);
}

fn writePrint(e: *dbus.Encoder, tok: []const u8, parent: []const u8, title: []const u8, fd: i32, prepared: u32, o: Options) dbus.codec.EncodeError!void {
    try e.writeAll(.{ parent, title, dbus.Fd{ .fd = fd } });
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    try w.put("modal", o.modal);
    if (prepared != 0) try w.put("token", prepared);
    try w.end();
}

/// The token of a prepared dialog's response.
pub fn token(results: *const vardict.Reader) u32 {
    return results.uint("token") orelse 0;
}

/// The paper and its margins in points, as the pages are laid out: for
/// a landscape orientation the paper's width and height are swapped and
/// the margins turn with it.
pub const PageSetup = struct {
    width: f32,
    height: f32,
    margin_top: f32 = 0,
    margin_right: f32 = 0,
    margin_bottom: f32 = 0,
    margin_left: f32 = 0,

    pub const points_per_mm: f64 = 72.0 / 25.4;

    /// The page setup of a prepared dialog's response, or `default` for
    /// what it leaves out.
    pub fn of(results: *const vardict.Reader, default: PageSetup) PageSetup {
        var d = results.get("page-setup", "a{sv}") orelse return default;
        const ps = vardict.Reader.take(&d) catch return default;
        const width = mm(&ps, "Width") orelse return default;
        const height = mm(&ps, "Height") orelse return default;
        if (!(width > 0 and height > 0)) return default;
        var s: PageSetup = .{
            .width = width,
            .height = height,
            .margin_top = mm(&ps, "MarginTop") orelse 0,
            .margin_right = mm(&ps, "MarginRight") orelse 0,
            .margin_bottom = mm(&ps, "MarginBottom") orelse 0,
            .margin_left = mm(&ps, "MarginLeft") orelse 0,
        };
        // GtkPageSetup's margins are the portrait paper's. Landscape turns
        // the page so that its top is the paper's left edge (as
        // GtkPrintContext rotates), reverse landscape its right edge.
        const orientation = ps.string("Orientation") orelse "portrait";
        const p = s;
        if (std.mem.eql(u8, orientation, "landscape")) {
            s = .{ .width = p.height, .height = p.width, .margin_top = p.margin_left, .margin_right = p.margin_top, .margin_bottom = p.margin_right, .margin_left = p.margin_bottom };
        } else if (std.mem.eql(u8, orientation, "reverse_landscape")) {
            s = .{ .width = p.height, .height = p.width, .margin_top = p.margin_right, .margin_right = p.margin_bottom, .margin_bottom = p.margin_left, .margin_left = p.margin_top };
        } else if (std.mem.eql(u8, orientation, "reverse_portrait")) {
            s = .{ .width = p.width, .height = p.height, .margin_top = p.margin_bottom, .margin_right = p.margin_left, .margin_bottom = p.margin_top, .margin_left = p.margin_right };
        }
        return s;
    }

    fn mm(r: *const vardict.Reader, key: []const u8) ?f32 {
        var d = r.get(key, "d") orelse return null;
        const v = d.read(f64) catch return null;
        if (!std.math.isFinite(v) or v < 0 or v > 100_000) return null;
        return @floatCast(v * points_per_mm);
    }
};
