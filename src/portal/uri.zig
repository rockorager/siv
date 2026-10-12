//! file:// URIs: the paths portals return as URIs, and back.

const std = @import("std");

/// The local path of a file:// URI ("file:///p" or "file://localhost/p"),
/// percent-decoded into `out`. Null for other URIs, other hosts, encoded
/// NULs, or a path longer than `out`.
pub fn filePath(uri: []const u8, out: []u8) ?[]u8 {
    const prefix = "file://";
    if (uri.len < prefix.len or !std.ascii.eqlIgnoreCase(uri[0..prefix.len], prefix)) return null;
    var rest = uri[prefix.len..];
    if (std.mem.startsWith(u8, rest, "localhost/")) rest = rest["localhost".len..];
    if (rest.len == 0 or rest[0] != '/') return null;
    // Neither query nor fragment belongs to the path.
    if (std.mem.indexOfAny(u8, rest, "?#")) |i| rest = rest[0..i];
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (n += 1) {
        if (n == out.len) return null;
        if (rest[i] == '%') {
            if (i + 3 > rest.len) return null;
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch return null;
            const v = hi << 4 | lo;
            if (v == 0) return null;
            out[n] = v;
            i += 3;
        } else {
            out[n] = rest[i];
            i += 1;
        }
    }
    return out[0..n];
}

/// Appends the file:// URI of an absolute path, percent-encoding every
/// byte outside RFC 3986's unreserved set and "/".
pub fn fromPath(gpa: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) std.mem.Allocator.Error!void {
    try out.appendSlice(gpa, "file://");
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/", c) != null) {
            try out.append(gpa, c);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(gpa, &.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
}

test "file URIs decode and encode" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/a b/é", filePath("file:///tmp/a%20b/%C3%A9", &buf).?);
    try std.testing.expectEqualStrings("/x", filePath("FILE://localhost/x", &buf).?);
    try std.testing.expectEqualStrings("/x", filePath("file:///x?q=1#f", &buf).?);
    try std.testing.expectEqual(null, filePath("file://host/x", &buf));
    try std.testing.expectEqual(null, filePath("https://example.com/", &buf));
    try std.testing.expectEqual(null, filePath("file:///a%00b", &buf));
    try std.testing.expectEqual(null, filePath("file:///a%2", &buf));
    try std.testing.expectEqual(null, filePath("file:///a%zz", &buf));
    var small: [2]u8 = undefined;
    try std.testing.expectEqual(null, filePath("file:///abc", &small));

    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try fromPath(gpa, &out, "/tmp/a b/é%");
    try std.testing.expectEqualStrings("file:///tmp/a%20b/%C3%A9%25", out.items);
    try std.testing.expectEqualStrings("/tmp/a b/é%", filePath(out.items, &buf).?);
}
