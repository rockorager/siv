//! file:// URIs and the text/uri-list format (RFC 2483), which other
//! applications use for dragged and copied files, and GNOME's
//! x-special/gnome-copied-files ("copy" or "cut", then the URIs), which
//! tells a paste whether to move.

const std = @import("std");

/// Appends `path` as a file:// URI, percent-encoding every byte that is
/// not unreserved or a slash.
pub fn appendFileUri(out: *std.ArrayList(u8), gpa: std.mem.Allocator, path: []const u8) !void {
    try out.appendSlice(gpa, "file://");
    for (path) |b| {
        const plain = std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "-._~/", b) != null;
        if (plain) {
            try out.append(gpa, b);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(gpa, &.{ '%', hex[b >> 4], hex[b & 15] });
        }
    }
}

/// The local path of a file URI (decoded into `buf`), or null for other
/// schemes, remote hosts, and malformed escapes.
pub fn filePath(buf: []u8, uri: []const u8) ?[]u8 {
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(uri, prefix)) return null;
    var rest = uri[prefix.len..];
    // file://localhost/path and file:///path are local; others are not.
    if (std.ascii.startsWithIgnoreCase(rest, "localhost/")) rest = rest["localhost".len..];
    if (rest.len == 0 or rest[0] != '/') return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (n >= buf.len) return null;
        if (rest[i] == '%') {
            if (i + 2 >= rest.len) return null;
            const v = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch return null;
            if (v == 0) return null;
            buf[n] = v;
            i += 2;
        } else buf[n] = rest[i];
        n += 1;
    }
    return buf[0..n];
}

/// Iterates the URIs of a text/uri-list: lines ending in CRLF (or LF),
/// skipping comments and blank lines.
pub const Lines = struct {
    rest: []const u8,

    pub fn next(it: *Lines) ?[]const u8 {
        while (it.rest.len != 0) {
            const end = std.mem.indexOfScalar(u8, it.rest, '\n') orelse it.rest.len;
            var line = it.rest[0..end];
            it.rest = if (end < it.rest.len) it.rest[end + 1 ..] else it.rest[it.rest.len..];
            if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            line = std.mem.trim(u8, line, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            return line;
        }
        return null;
    }
};

/// Splits x-special/gnome-copied-files into its action and URI lines.
pub fn gnomeCopied(data: []const u8) struct { cut: bool, uris: []const u8 } {
    const end = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
    const first = std.mem.trim(u8, data[0..end], " \r\t");
    if (std.mem.eql(u8, first, "cut") or std.mem.eql(u8, first, "copy"))
        return .{ .cut = std.mem.eql(u8, first, "cut"), .uris = if (end < data.len) data[end + 1 ..] else "" };
    return .{ .cut = false, .uris = data };
}

const testing = std.testing;

test "file URIs round trip" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendFileUri(&out, gpa, "/home/me/a b%c/ü.txt");
    try testing.expectEqualStrings("file:///home/me/a%20b%25c/%C3%BC.txt", out.items);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/me/a b%c/ü.txt", filePath(&buf, out.items).?);
    try testing.expectEqualStrings("/x", filePath(&buf, "file://localhost/x").?);
    try testing.expect(filePath(&buf, "file://host/x") == null);
    try testing.expect(filePath(&buf, "https://x/y") == null);
    try testing.expect(filePath(&buf, "file:///a%2") == null);
    try testing.expect(filePath(&buf, "file:///a%00b") == null);
}

test "uri lists" {
    var it: Lines = .{ .rest = "# comment\r\nfile:///a\r\n\r\nfile:///b\n" };
    try testing.expectEqualStrings("file:///a", it.next().?);
    try testing.expectEqualStrings("file:///b", it.next().?);
    try testing.expect(it.next() == null);
    const g = gnomeCopied("cut\nfile:///a\nfile:///b");
    try testing.expect(g.cut);
    try testing.expectEqualStrings("file:///a\nfile:///b", g.uris);
}
