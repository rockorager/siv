//! D-Bus server addresses ("unix:path=/run/user/1000/bus;unix:abstract=x").
//! Only unix sockets are supported: TCP cannot pass fds or authenticate
//! with EXTERNAL. Addresses come from the environment or from other
//! processes (the accessibility bus), so the parser treats them as
//! untrusted.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{InvalidAddress};

/// A socket address to connect to.
pub const Socket = struct {
    addr: linux.sockaddr.un,
    len: linux.socklen_t,
};

/// Iterates the entries of an address list, yielding a socket for each
/// supported one and skipping the rest (other transports, server-only
/// keys).
pub const Iterator = struct {
    rest: []const u8,

    pub fn init(address: []const u8) Iterator {
        return .{ .rest = address };
    }

    pub fn next(it: *Iterator) Error!?Socket {
        while (it.rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, it.rest, ';') orelse it.rest.len;
            const entry = it.rest[0..end];
            it.rest = if (end < it.rest.len) it.rest[end + 1 ..] else "";
            if (entry.len == 0) continue;
            if (try parseEntry(entry)) |s| return s;
        }
        return null;
    }
};

fn parseEntry(entry: []const u8) Error!?Socket {
    const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return error.InvalidAddress;
    if (!std.mem.eql(u8, entry[0..colon], "unix")) return null;
    var s: Socket = .{ .addr = .{ .path = @splat(0) }, .len = 0 };
    var found = false;
    var keys = std.mem.splitScalar(u8, entry[colon + 1 ..], ',');
    while (keys.next()) |kv| {
        if (kv.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.InvalidAddress;
        const key = kv[0..eq];
        const value = kv[eq + 1 ..];
        const abstract = std.mem.eql(u8, key, "abstract");
        if (!abstract and !std.mem.eql(u8, key, "path")) continue; // guid and others
        if (found) return error.InvalidAddress;
        // An abstract name starts with a NUL in sun_path and has no
        // terminator; a path is NUL-terminated.
        const start: usize = @intFromBool(abstract);
        const n = try unescape(value, s.addr.path[start .. s.addr.path.len - @intFromBool(!abstract)]);
        if (n == 0) return error.InvalidAddress;
        s.len = @intCast(@sizeOf(linux.sa_family_t) + start + n + @intFromBool(!abstract));
        found = true;
    }
    return if (found) s else null;
}

/// Decodes %xx escapes into `out` and returns the length.
fn unescape(value: []const u8, out: []u8) Error!usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (n += 1) {
        if (n == out.len) return error.InvalidAddress;
        if (value[i] == '%') {
            if (value.len - i < 3) return error.InvalidAddress;
            out[n] = std.fmt.parseInt(u8, value[i + 1 ..][0..2], 16) catch return error.InvalidAddress;
            i += 3;
        } else {
            out[n] = value[i];
            i += 1;
        }
        if (out[n] == 0) return error.InvalidAddress;
    }
    return n;
}

/// The session bus address: $DBUS_SESSION_BUS_ADDRESS, else
/// unix:path=$XDG_RUNTIME_DIR/bus. Null if neither is set.
pub fn session(buf: []u8) ?[]const u8 {
    if (getenv("DBUS_SESSION_BUS_ADDRESS")) |a| return a;
    const dir = getenv("XDG_RUNTIME_DIR") orelse return null;
    return std.fmt.bufPrint(buf, "unix:path={s}/bus", .{dir}) catch null;
}

/// The system bus address: $DBUS_SYSTEM_BUS_ADDRESS, else the standard
/// socket.
pub fn system() []const u8 {
    return getenv("DBUS_SYSTEM_BUS_ADDRESS") orelse "unix:path=/var/run/dbus/system_bus_socket";
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

const testing = std.testing;

test "path, abstract, escapes, and skipped entries" {
    var it: Iterator = .init("tcp:host=x,port=1;unix:tmpdir=/tmp;unix:path=/run/user/1000/bus,guid=abc;unix:abstract=/tmp/dbus-%41b");
    const p = (try it.next()).?;
    try testing.expectEqualStrings("/run/user/1000/bus", std.mem.sliceTo(&p.addr.path, 0));
    try testing.expectEqual(@as(linux.socklen_t, 2 + 18 + 1), p.len);
    const a = (try it.next()).?;
    try testing.expectEqual(@as(u8, 0), a.addr.path[0]);
    try testing.expectEqualStrings("/tmp/dbus-Ab", a.addr.path[1..13]);
    try testing.expectEqual(@as(linux.socklen_t, 2 + 1 + 12), a.len);
    try testing.expect(try it.next() == null);
}

test "invalid addresses" {
    for ([_][]const u8{ "nocolon", "unix:path", "unix:path=", "unix:path=%4", "unix:path=%zz", "unix:path=a%00b", "unix:path=a,abstract=b" }) |s| {
        var it: Iterator = .init(s);
        try testing.expectError(error.InvalidAddress, it.next());
    }
    var long: [200]u8 = @splat('a');
    @memcpy(long[0..10], "unix:path=");
    var it: Iterator = .init(&long);
    try testing.expectError(error.InvalidAddress, it.next());
    // 107 bytes plus the NUL fill sun_path exactly.
    var exact: [117]u8 = @splat('a');
    @memcpy(exact[0..10], "unix:path=");
    it = .init(&exact);
    try testing.expect(try it.next() != null);
}

test "fuzz addresses" {
    try std.testing.fuzz({}, fuzzAddress, .{ .corpus = &.{"unix:path=/run/user/1000/bus;unix:abstract=%2fx,guid=1"} });
}

fn fuzzAddress(_: void, smith: *std.testing.Smith) !void {
    var buf: [512]u8 = undefined;
    var it: Iterator = .init(buf[0..smith.slice(&buf)]);
    while (it.next() catch return) |s| {
        try testing.expect(s.len <= @sizeOf(linux.sockaddr.un));
        try testing.expect(s.len > @sizeOf(linux.sa_family_t));
    }
}
