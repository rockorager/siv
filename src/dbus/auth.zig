//! SASL EXTERNAL authentication, client side. The client pipelines its
//! whole side of the handshake (a NUL byte, AUTH EXTERNAL with the hex
//! encoded uid, NEGOTIATE_UNIX_FD, BEGIN) together with its first messages,
//! so connecting costs no round trips beyond the socket's. The server's
//! lines are untrusted input.

const std = @import("std");

/// Longest server line accepted. Real servers send under 100 bytes.
pub const max_line = 512;

pub const Error = error{
    /// The server refused EXTERNAL authentication.
    AuthRejected,
    /// The server sent something the protocol does not allow here.
    AuthProtocol,
};

/// Writes the client's side of the handshake into `buf` and returns it.
pub fn clientHello(buf: *[64]u8, uid: u32, negotiate_fds: bool) []const u8 {
    var dec: [10]u8 = undefined;
    const digits = std.fmt.bufPrint(&dec, "{d}", .{uid}) catch unreachable;
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("\x00AUTH EXTERNAL ") catch unreachable;
    for (digits) |d| w.print("{x:0>2}", .{d}) catch unreachable;
    w.writeAll("\r\n") catch unreachable;
    if (negotiate_fds) w.writeAll("NEGOTIATE_UNIX_FD\r\n") catch unreachable;
    w.writeAll("BEGIN\r\n") catch unreachable;
    return w.buffered();
}

/// Consumes the server's replies.
pub const Client = struct {
    negotiate_fds: bool,
    state: enum { wait_ok, wait_fds, done } = .wait_ok,
    /// The server's GUID, 32 hex digits.
    guid: [32]u8 = undefined,
    unix_fds: bool = false,

    /// Consumes complete lines from `data` and returns how many bytes were
    /// used. Once `done()`, the bytes that follow are binary messages.
    pub fn feed(c: *Client, data: []const u8) Error!usize {
        var used: usize = 0;
        while (c.state != .done) {
            const rest = data[used..];
            const nl = std.mem.indexOf(u8, rest[0..@min(rest.len, max_line)], "\r\n") orelse {
                if (rest.len >= max_line) return error.AuthProtocol;
                break;
            };
            try c.line(rest[0..nl]);
            used += nl + 2;
        }
        return used;
    }

    pub fn done(c: *const Client) bool {
        return c.state == .done;
    }

    fn line(c: *Client, l: []const u8) Error!void {
        const space = std.mem.indexOfScalar(u8, l, ' ') orelse l.len;
        const cmd = l[0..space];
        const arg = if (space < l.len) l[space + 1 ..] else "";
        switch (c.state) {
            .wait_ok => {
                if (std.mem.eql(u8, cmd, "OK")) {
                    if (arg.len != 32) return error.AuthProtocol;
                    for (arg) |ch| if (!std.ascii.isHex(ch)) return error.AuthProtocol;
                    c.guid = arg[0..32].*;
                    c.state = if (c.negotiate_fds) .wait_fds else .done;
                } else if (std.mem.eql(u8, cmd, "REJECTED")) {
                    return error.AuthRejected;
                } else {
                    // ERROR or DATA: EXTERNAL with an initial response
                    // needs neither.
                    return error.AuthProtocol;
                }
            },
            .wait_fds => {
                if (std.mem.eql(u8, l, "AGREE_UNIX_FD")) {
                    c.unix_fds = true;
                } else if (!std.mem.eql(u8, cmd, "ERROR")) {
                    return error.AuthProtocol;
                }
                c.state = .done;
            },
            .done => unreachable,
        }
    }
};

const testing = std.testing;

test "client hello" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("\x00AUTH EXTERNAL 31303030\r\nNEGOTIATE_UNIX_FD\r\nBEGIN\r\n", clientHello(&buf, 1000, true));
    try testing.expectEqualStrings("\x00AUTH EXTERNAL 30\r\nBEGIN\r\n", clientHello(&buf, 0, false));
    _ = clientHello(&buf, std.math.maxInt(u32), true); // fits
}

test "server replies split across reads" {
    var c: Client = .{ .negotiate_fds = true };
    const reply = "OK 0123456789abcdef0123456789ABCDEF\r\nAGREE_UNIX_FD\r\nl\x02";
    var used = try c.feed(reply[0..10]);
    try testing.expectEqual(@as(usize, 0), used);
    used = try c.feed(reply);
    try testing.expect(c.done());
    try testing.expect(c.unix_fds);
    try testing.expectEqualStrings("l\x02", reply[used..]);
    try testing.expectEqualStrings("0123456789abcdef0123456789ABCDEF", &c.guid);
}

test "fds refused and authentication rejected" {
    var c: Client = .{ .negotiate_fds = true };
    _ = try c.feed("OK 0123456789abcdef0123456789abcdef\r\nERROR not supported\r\n");
    try testing.expect(c.done() and !c.unix_fds);

    var r: Client = .{ .negotiate_fds = true };
    try testing.expectError(error.AuthRejected, r.feed("REJECTED EXTERNAL DBUS_COOKIE_SHA1\r\n"));
    var bad: Client = .{ .negotiate_fds = false };
    try testing.expectError(error.AuthProtocol, bad.feed("OK short\r\n"));
    var long: Client = .{ .negotiate_fds = false };
    try testing.expectError(error.AuthProtocol, long.feed(&@as([max_line]u8, @splat('A'))));
}

test "fuzz server replies" {
    try std.testing.fuzz({}, fuzzFeed, .{ .corpus = &.{
        "OK 0123456789abcdef0123456789abcdef\r\nAGREE_UNIX_FD\r\n",
        "REJECTED EXTERNAL\r\n",
    } });
}

fn fuzzFeed(_: void, smith: *std.testing.Smith) !void {
    var buf: [1024]u8 = undefined;
    const data = buf[0..smith.slice(&buf)];
    // Feeding in two pieces must agree with feeding at once.
    var whole: Client = .{ .negotiate_fds = true };
    const whole_used = whole.feed(data) catch return;
    try testing.expect(whole_used <= data.len);
    const split = data.len / 2;
    var parts: Client = .{ .negotiate_fds = true };
    var used = try parts.feed(data[0..split]);
    used += try parts.feed(data[used..]);
    if (whole.done()) {
        try testing.expect(parts.done());
        try testing.expectEqual(whole_used, used);
        try testing.expectEqual(whole.unix_fds, parts.unix_fds);
    }
}
