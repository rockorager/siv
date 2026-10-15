//! URL resolution (RFC 3986, section 5.2) for the document's links and
//! resources: enough for http(s), file, and the opaque schemes documents
//! use (cid:, data:, mailto:, epub zip paths). Nothing is fetched here.

const std = @import("std");

fn schemeEnd(s: []const u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == ':') return if (i > 0) i else null;
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
        if (i == 0 and !std.ascii.isAlphabetic(c)) return null;
    }
    return null;
}

/// `ref` resolved against `base`. An empty base keeps relative references
/// relative (normalized).
pub fn resolve(a: std.mem.Allocator, base: []const u8, ref_: []const u8) error{OutOfMemory}![]const u8 {
    const ref = std.mem.trim(u8, ref_, " \t\n\r");
    if (schemeEnd(ref) != null) return a.dupe(u8, ref);
    if (ref.len == 0) return a.dupe(u8, if (std.mem.indexOfScalar(u8, base, '#')) |k| base[0..k] else base);
    if (ref[0] == '#') {
        const b = if (std.mem.indexOfScalar(u8, base, '#')) |k| base[0..k] else base;
        return std.mem.concat(a, u8, &.{ b, ref });
    }
    if (base.len == 0) return a.dupe(u8, ref);
    const se = schemeEnd(base);
    const scheme = if (se) |e| base[0 .. e + 1] else "";
    var rest = base[scheme.len..];
    // Opaque bases (cid:, mailto:) resolve nothing.
    if (se != null and !std.mem.startsWith(u8, rest, "/")) return a.dupe(u8, ref);
    if (std.mem.startsWith(u8, ref, "//")) return std.mem.concat(a, u8, &.{ scheme, ref });
    var authority: []const u8 = "";
    if (std.mem.startsWith(u8, rest, "//")) {
        const end = std.mem.indexOfAnyPos(u8, rest, 2, "/?#") orelse rest.len;
        authority = rest[0..end];
        rest = rest[end..];
    }
    // The base's path without query and fragment.
    const path_end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
    const base_path = rest[0..path_end];
    var merged: std.ArrayList(u8) = .empty;
    defer merged.deinit(a);
    var tail: []const u8 = "";
    var ref_path = ref;
    if (std.mem.indexOfAny(u8, ref, "?#")) |k| {
        ref_path = ref[0..k];
        tail = ref[k..];
    }
    if (ref_path.len == 0) {
        try merged.appendSlice(a, base_path);
        if (tail.len > 0 and tail[0] == '#') {
            // Keep the base's query.
            const q = rest[path_end..];
            const qe = std.mem.indexOfScalar(u8, q, '#') orelse q.len;
            try merged.appendSlice(a, q[0..qe]);
        }
    } else if (ref_path[0] == '/') {
        try merged.appendSlice(a, ref_path);
    } else {
        const dir = if (std.mem.lastIndexOfScalar(u8, base_path, '/')) |k| base_path[0 .. k + 1] else if (authority.len > 0) "/" else "";
        try merged.appendSlice(a, dir);
        try merged.appendSlice(a, ref_path);
    }
    // Remove dot segments.
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    var it = std.mem.splitScalar(u8, merged.items, '/');
    var first = true;
    var absolute = false;
    var trailing = false;
    while (it.next()) |seg| {
        if (first) {
            first = false;
            if (seg.len == 0) {
                absolute = true;
                continue;
            }
        }
        trailing = false;
        if (std.mem.eql(u8, seg, ".")) {
            trailing = true;
            continue;
        }
        if (std.mem.eql(u8, seg, "..")) {
            if (out.items.len > 0) _ = out.pop();
            trailing = true;
            continue;
        }
        try out.append(a, seg);
    }
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(a, scheme);
    try result.appendSlice(a, authority);
    if (absolute) try result.append(a, '/');
    for (out.items, 0..) |seg, i| {
        if (i > 0) try result.append(a, '/');
        try result.appendSlice(a, seg);
    }
    if (trailing and out.items.len > 0) try result.append(a, '/');
    try result.appendSlice(a, tail);
    return result.items;
}

test "resolving" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "http://a/b/c/d;p?q";
    const cases = [_][2][]const u8{
        .{ "g", "http://a/b/c/g" },        .{ "./g", "http://a/b/c/g" },   .{ "g/", "http://a/b/c/g/" },
        .{ "/g", "http://a/g" },           .{ "//g", "http://g" },          .{ "?y", "http://a/b/c/d;p?y" },
        .{ "g?y", "http://a/b/c/g?y" },    .{ "#s", "http://a/b/c/d;p?q#s" }, .{ "../g", "http://a/b/g" },
        .{ "../../g", "http://a/g" },      .{ "cid:part1@x", "cid:part1@x" }, .{ "", "http://a/b/c/d;p?q" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try resolve(a, base, c[0]));
    try std.testing.expectEqualStrings("OEBPS/images/a.png", try resolve(a, "OEBPS/text/ch1.xhtml", "../images/a.png"));
    try std.testing.expectEqualStrings("img.png", try resolve(a, "", "img.png"));
}
