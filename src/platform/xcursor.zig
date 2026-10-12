//! XCursor themes (D16, D19): cursor images for compositors without
//! cursor-shape-v1. A theme is a directory of cursor files under the icon
//! theme search path, inheriting from others through index.theme; a file
//! holds images at several nominal sizes, each size possibly animated.
//!
//! The parser takes untrusted bytes (anything on disk under a theme name)
//! and checks every offset and size; `zig build test-platform --fuzz`
//! fuzzes it.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

/// One frame: premultiplied ARGB8888 pixels (native-endian words, which
/// is wl_shm's ARGB8888 on little-endian hosts).
pub const Image = struct {
    width: u32,
    height: u32,
    xhot: u32,
    yhot: u32,
    /// Milliseconds to show it, for animated cursors.
    delay: u32,
    /// Into the file's bytes.
    pixels: []const u8,
};

/// The frames of one nominal size.
pub const Cursor = struct {
    nominal: u32,
    frames: []Image,

    pub fn deinit(c: Cursor, gpa: Allocator) void {
        gpa.free(c.frames);
    }
};

const magic = 0x72756358; // "Xcur"
const image_type = 0xfffd0002;
const max_dimension = 0x7fff;
const max_frames = 1024;

fn readU32(bytes: []const u8, at: usize) ?u32 {
    if (at > bytes.len or bytes.len - at < 4) return null;
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

pub const Error = error{ InvalidCursor, OutOfMemory };

/// The frames of the nominal size closest to `size` (ties go to the
/// larger), in file order. They point into `bytes`.
pub fn parse(gpa: Allocator, bytes: []const u8, size: u32) Error!Cursor {
    if (readU32(bytes, 0) != magic) return error.InvalidCursor;
    const header = readU32(bytes, 4) orelse return error.InvalidCursor;
    const ntoc = readU32(bytes, 12) orelse return error.InvalidCursor;
    if (header < 16 or ntoc == 0 or ntoc > (bytes.len -| header) / 12) return error.InvalidCursor;

    // The nominal size to use.
    var best: ?u32 = null;
    for (0..ntoc) |i| {
        const entry = header + i * 12;
        if (readU32(bytes, entry) != image_type) continue;
        const nominal = readU32(bytes, entry + 4) orelse return error.InvalidCursor;
        if (nominal == 0) continue;
        if (best) |b| {
            const db = if (b > size) b - size else size - b;
            const dn = if (nominal > size) nominal - size else size - nominal;
            if (dn < db or (dn == db and nominal > b)) best = nominal;
        } else best = nominal;
    }
    const nominal = best orelse return error.InvalidCursor;

    var frames: std.ArrayList(Image) = .empty;
    errdefer frames.deinit(gpa);
    for (0..ntoc) |i| {
        const entry = header + i * 12;
        if (readU32(bytes, entry) != image_type or readU32(bytes, entry + 4) != nominal) continue;
        if (frames.items.len == max_frames) break;
        const pos = readU32(bytes, entry + 8) orelse return error.InvalidCursor;
        try frames.append(gpa, try image(bytes, pos, nominal));
    }
    if (frames.items.len == 0) return error.InvalidCursor;
    return .{ .nominal = nominal, .frames = try frames.toOwnedSlice(gpa) };
}

fn image(bytes: []const u8, pos: u32, nominal: u32) Error!Image {
    const chunk_header = readU32(bytes, pos) orelse return error.InvalidCursor;
    if (readU32(bytes, pos + 4) != image_type or readU32(bytes, pos + 8) != nominal) return error.InvalidCursor;
    const width = readU32(bytes, pos + 16) orelse return error.InvalidCursor;
    const height = readU32(bytes, pos + 20) orelse return error.InvalidCursor;
    const xhot = readU32(bytes, pos + 24) orelse return error.InvalidCursor;
    const yhot = readU32(bytes, pos + 28) orelse return error.InvalidCursor;
    const delay = readU32(bytes, pos + 32) orelse return error.InvalidCursor;
    if (chunk_header < 36 or width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.InvalidCursor;
    if (xhot > width or yhot > height) return error.InvalidCursor;
    const start = @as(usize, pos) + chunk_header;
    const len = @as(usize, width) * height * 4;
    if (start > bytes.len or bytes.len - start < len) return error.InvalidCursor;
    return .{ .width = width, .height = height, .xhot = xhot, .yhot = yhot, .delay = delay, .pixels = bytes[start..][0..len] };
}

/// A cursor file's bytes, mapped read-only; `unmap` releases them.
pub const File = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    pub fn unmap(f: File) void {
        _ = linux.munmap(f.bytes.ptr, f.bytes.len);
    }
};

/// Cursor files over this size are not themes.
const max_file = 16 << 20;

fn mapFile(path: [*:0]const u8) ?File {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true, .TYPE = true }, &st)) != .SUCCESS) return null;
    if (st.mode & linux.S.IFMT != linux.S.IFREG or st.size == 0 or st.size > max_file) return null;
    const addr = linux.mmap(null, st.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(addr) != .SUCCESS) return null;
    return .{ .bytes = @as([*]align(std.heap.page_size_min) const u8, @ptrFromInt(addr))[0..st.size] };
}

/// Where themes live, in order (libXcursor's default path, after
/// $XCURSOR_PATH if set).
pub const SearchPath = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,

    pub fn fromEnv() SearchPath {
        var p: SearchPath = .{};
        if (std.c.getenv("XCURSOR_PATH")) |v| {
            p.add(std.mem.span(v));
            return p;
        }
        const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
        if (std.c.getenv("XDG_DATA_HOME")) |d| p.addFmt("{s}/icons", .{std.mem.span(d)}) else if (home.len != 0) p.addFmt("{s}/.local/share/icons", .{home});
        if (home.len != 0) p.addFmt("{s}/.icons", .{home});
        const data_dirs = if (std.c.getenv("XDG_DATA_DIRS")) |d| std.mem.span(d) else "/usr/local/share:/usr/share";
        var it = std.mem.tokenizeScalar(u8, data_dirs, ':');
        while (it.next()) |d| p.addFmt("{s}/icons", .{d});
        p.add("/usr/share/pixmaps");
        return p;
    }

    pub fn add(p: *SearchPath, list: []const u8) void {
        if (p.len != 0 and p.len < p.buf.len) {
            p.buf[p.len] = ':';
            p.len += 1;
        }
        const n = @min(list.len, p.buf.len - p.len);
        @memcpy(p.buf[p.len..][0..n], list[0..n]);
        p.len += n;
    }

    fn addFmt(p: *SearchPath, comptime fmt: []const u8, args: anytype) void {
        var tmp: [512]u8 = undefined;
        p.add(std.fmt.bufPrint(&tmp, fmt, args) catch return);
    }

    pub fn dirs(p: *const SearchPath) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, p.buf[0..p.len], ':');
    }
};

/// Finds cursor `name` in `theme` or the themes it inherits, then in the
/// "default" theme, and maps its file.
pub fn find(path: *const SearchPath, theme: []const u8, name: []const u8) ?File {
    var seen: [8][64]u8 = undefined;
    var seen_len: [8]usize = undefined;
    var n_seen: usize = 0;
    if (findIn(path, theme, name, &seen, &seen_len, &n_seen, 0)) |f| return f;
    if (!std.mem.eql(u8, theme, "default")) return findIn(path, "default", name, &seen, &seen_len, &n_seen, 0);
    return null;
}

fn findIn(path: *const SearchPath, theme: []const u8, name: []const u8, seen: *[8][64]u8, seen_len: *[8]usize, n_seen: *usize, depth: u32) ?File {
    if (depth > 6 or theme.len == 0 or theme.len > 63 or std.mem.indexOfScalar(u8, theme, '/') != null) return null;
    for (seen[0..n_seen.*], seen_len[0..n_seen.*]) |s, l| if (std.mem.eql(u8, s[0..l], theme)) return null;
    if (n_seen.* < seen.len) {
        @memcpy(seen[n_seen.*][0..theme.len], theme);
        seen_len[n_seen.*] = theme.len;
        n_seen.* += 1;
    }
    var buf: [1024]u8 = undefined;
    var dirs = path.dirs();
    while (dirs.next()) |dir| {
        const file = std.fmt.bufPrintSentinel(&buf, "{s}/{s}/cursors/{s}", .{ dir, theme, name }, 0) catch continue;
        if (mapFile(file)) |f| return f;
    }
    // Inherited themes, from the first index.theme that names them.
    dirs = path.dirs();
    while (dirs.next()) |dir| {
        const index = std.fmt.bufPrintSentinel(&buf, "{s}/{s}/index.theme", .{ dir, theme }, 0) catch continue;
        const f = mapFile(index) orelse continue;
        defer f.unmap();
        var parents: [256]u8 = undefined;
        const list = inherits(f.bytes, &parents) orelse continue;
        var it = std.mem.tokenizeAny(u8, list, ",; \t");
        while (it.next()) |parent| {
            if (findIn(path, parent, name, seen, seen_len, n_seen, depth + 1)) |found| return found;
        }
        return null;
    }
    return null;
}

/// The value of `Inherits=` in an index.theme's [Icon Theme] group.
pub fn inherits(text: []const u8, out: []u8) ?[]const u8 {
    var in_group = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len != 0 and line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[Icon Theme]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "Inherits")) continue;
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const n = @min(v.len, out.len);
        @memcpy(out[0..n], v[0..n]);
        return out[0..n];
    }
    return null;
}

/// Builds a cursor file in memory, for tests.
pub fn encodeForTest(gpa: Allocator, images: []const struct { nominal: u32, width: u32, height: u32, xhot: u32 = 0, yhot: u32 = 0, delay: u32 = 0, color: u32 = 0xff000000 }) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const w = struct {
        fn u32le(list: *std.ArrayList(u8), a: Allocator, v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try list.appendSlice(a, &b);
        }
    };
    try w.u32le(&out, gpa, magic);
    try w.u32le(&out, gpa, 16);
    try w.u32le(&out, gpa, 0x10000);
    try w.u32le(&out, gpa, @intCast(images.len));
    var pos: u32 = @intCast(16 + 12 * images.len);
    for (images) |img| {
        try w.u32le(&out, gpa, image_type);
        try w.u32le(&out, gpa, img.nominal);
        try w.u32le(&out, gpa, pos);
        pos += 36 + img.width * img.height * 4;
    }
    for (images) |img| {
        for ([_]u32{ 36, image_type, img.nominal, 1, img.width, img.height, img.xhot, img.yhot, img.delay }) |v| try w.u32le(&out, gpa, v);
        for (0..img.width * img.height) |_| try w.u32le(&out, gpa, img.color);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "the nominal size closest to the request, with its animation frames" {
    const bytes = try encodeForTest(testing.allocator, &.{
        .{ .nominal = 24, .width = 24, .height = 24, .xhot = 3, .yhot = 4 },
        .{ .nominal = 48, .width = 48, .height = 48, .xhot = 6, .yhot = 8, .delay = 30, .color = 0xff112233 },
        .{ .nominal = 48, .width = 48, .height = 48, .delay = 40 },
        .{ .nominal = 32, .width = 32, .height = 32 },
    });
    defer testing.allocator.free(bytes);
    const c = try parse(testing.allocator, bytes, 45);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 48), c.nominal);
    try testing.expectEqual(@as(usize, 2), c.frames.len);
    try testing.expectEqual(@as(u32, 6), c.frames[0].xhot);
    try testing.expectEqual(@as(u32, 40), c.frames[1].delay);
    try testing.expectEqual(@as(u32, 0xff112233), std.mem.readInt(u32, c.frames[0].pixels[0..4], .little));
    // 28 is as close to 24 as to 32: the larger wins.
    const d = try parse(testing.allocator, bytes, 28);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 32), d.nominal);
    // Truncated files and bad hotspots are rejected.
    try testing.expectError(error.InvalidCursor, parse(testing.allocator, bytes[0 .. bytes.len - 1], 32));
    var bad = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(bad);
    std.mem.writeInt(u32, bad[16 + 48 + 24 ..][0..4], 99, .little); // first image's xhot
    try testing.expectError(error.InvalidCursor, parse(testing.allocator, bad, 24));
}

test "index.theme inheritance" {
    const text = "[Icon Theme]\nName=X\nInherits = Adwaita, hicolor\n[Other]\nInherits=no\n";
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Adwaita, hicolor", inherits(text, &buf).?);
    try testing.expect(inherits("[Other]\nInherits=no\n", &buf) == null);
}

test "fuzz: cursor files" {
    const seed = try encodeForTest(testing.allocator, &.{ .{ .nominal = 24, .width = 2, .height = 2, .xhot = 1 }, .{ .nominal = 24, .width = 2, .height = 2, .delay = 5 } });
    defer testing.allocator.free(seed);
    try testing.fuzz(seed, fuzzParse, .{ .corpus = &.{seed} });
}

fn fuzzParse(_: []const u8, smith: *testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    const c = parse(testing.allocator, bytes, 24) catch return;
    defer c.deinit(testing.allocator);
    for (c.frames) |f| {
        try testing.expect(f.pixels.len == @as(usize, f.width) * f.height * 4);
        try testing.expect(f.xhot <= f.width and f.yhot <= f.height);
        try testing.expect(@intFromPtr(f.pixels.ptr) >= @intFromPtr(bytes.ptr));
        try testing.expect(@intFromPtr(f.pixels.ptr) + f.pixels.len <= @intFromPtr(bytes.ptr) + bytes.len);
    }
}
