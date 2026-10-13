//! Validation of the names the D-Bus specification restricts: object paths,
//! interface, error, and member names, and bus names. Every name received
//! from the wire or given to the public API passes through here.

const std = @import("std");

pub const max_name_len = 255;

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isAlnum(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}

/// "/" or "/" followed by elements of [A-Za-z0-9_] separated by "/", with
/// no empty elements and no trailing "/".
pub fn isObjectPath(s: []const u8) bool {
    if (s.len == 0 or s[0] != '/') return false;
    if (s.len == 1) return true;
    var prev_slash = true;
    for (s[1..]) |c| {
        if (c == '/') {
            if (prev_slash) return false;
            prev_slash = true;
        } else if (isAlnum(c)) {
            prev_slash = false;
        } else return false;
    }
    return !prev_slash;
}

/// One element of [A-Za-z_][A-Za-z0-9_]*, at most 255 bytes.
pub fn isMemberName(s: []const u8) bool {
    if (s.len == 0 or s.len > max_name_len or !isAlpha(s[0])) return false;
    for (s[1..]) |c| if (!isAlnum(c)) return false;
    return true;
}

/// Two or more member-name elements separated by ".", at most 255 bytes.
/// Error names follow the same rule.
pub fn isInterfaceName(s: []const u8) bool {
    if (s.len == 0 or s.len > max_name_len) return false;
    var elements: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |e| {
        if (!isMemberName(e)) return false;
        elements += 1;
    }
    return elements >= 2;
}

pub const isErrorName = isInterfaceName;

/// A unique name (":" then two or more elements of [A-Za-z0-9_-]) or a
/// well-known name (two or more elements of [A-Za-z_-][A-Za-z0-9_-]*), at
/// most 255 bytes.
pub fn isBusName(s: []const u8) bool {
    if (s.len == 0 or s.len > max_name_len) return false;
    const unique = s[0] == ':';
    const body = if (unique) s[1..] else s;
    var elements: usize = 0;
    var it = std.mem.splitScalar(u8, body, '.');
    while (it.next()) |e| {
        if (e.len == 0) return false;
        if (!unique and e[0] >= '0' and e[0] <= '9') return false;
        for (e) |c| if (!isAlnum(c) and c != '-') return false;
        elements += 1;
    }
    return elements >= 2;
}

pub fn isUniqueName(s: []const u8) bool {
    return s.len > 0 and s[0] == ':' and isBusName(s);
}

/// Whether `path` equals `namespace` or lies below it ("/" contains every
/// path).
pub fn pathInNamespace(path: []const u8, namespace: []const u8) bool {
    if (!std.mem.startsWith(u8, path, namespace)) return false;
    if (path.len == namespace.len) return true;
    if (namespace.len == 1) return true; // "/"
    return path[namespace.len] == '/';
}

/// Whether `name` equals `namespace` or starts with `namespace` and ".".
pub fn nameInNamespace(name: []const u8, namespace: []const u8) bool {
    if (!std.mem.startsWith(u8, name, namespace)) return false;
    return name.len == namespace.len or name[namespace.len] == '.';
}

test "object paths" {
    const t = std.testing;
    for ([_][]const u8{ "/", "/a", "/a/b_c/D9", "/org/a11y/atspi/accessible/123" }) |p| try t.expect(isObjectPath(p));
    for ([_][]const u8{ "", "a", "//", "/a/", "/a//b", "/a-b", "/é" }) |p| try t.expect(!isObjectPath(p));
}

test "interface, member, and bus names" {
    const t = std.testing;
    try t.expect(isInterfaceName("org.freedesktop.DBus"));
    try t.expect(isInterfaceName("a._b"));
    try t.expect(!isInterfaceName("org"));
    try t.expect(!isInterfaceName("org..x"));
    try t.expect(!isInterfaceName("org.9x"));
    try t.expect(!isInterfaceName("org.x-y"));
    try t.expect(!isInterfaceName(".org.x"));
    try t.expect(isMemberName("Hello"));
    try t.expect(isMemberName("_a1"));
    try t.expect(!isMemberName("1a"));
    try t.expect(!isMemberName("a.b"));
    try t.expect(!isMemberName(""));
    try t.expect(isBusName(":1.42"));
    try t.expect(isBusName("org.freedesktop.portal.Desktop"));
    try t.expect(isBusName("org.my-app.x"));
    try t.expect(!isBusName("org.1x"));
    try t.expect(!isBusName(":1"));
    try t.expect(!isBusName("org"));
    try t.expect(!isBusName("org.x."));
    try t.expect(isUniqueName(":1.0"));
    try t.expect(!isUniqueName("a.b"));
    var long: [256]u8 = @splat('a');
    long[1] = '.';
    try t.expect(!isBusName(&long));
    try t.expect(isBusName(long[0..255]));
}
