//! A directory's entries: reading them (on a worker thread), sorting,
//! and filtering for search. Plain Zig with no siv calls, so the tests
//! exercise it directly.
//!
//! Names live in one byte arena per listing; entries refer to them by
//! offset, so a listing of 100 000 entries is two allocations.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const Kind = enum(u8) { file, dir, other };

/// What an entry looks like, from its type and name: picks the icon and
/// the Type column.
pub const Category = enum(u8) {
    folder,
    text,
    image,
    audio,
    video,
    archive,
    document,
    code,
    executable,
    other,

    pub fn label(c: Category) []const u8 {
        return switch (c) {
            .folder => "Folder",
            .text => "Text",
            .image => "Image",
            .audio => "Audio",
            .video => "Video",
            .archive => "Archive",
            .document => "Document",
            .code => "Source code",
            .executable => "Program",
            .other => "File",
        };
    }
};

pub const Entry = struct {
    name_off: u32,
    name_len: u32,
    size: u64,
    /// Modification time in nanoseconds since the epoch.
    mtime: i64,
    mode: u32,
    kind: Kind,
    category: Category,
    /// A symbolic link (kind is its target's).
    link: bool,
    hidden: bool,
};

pub const Listing = struct {
    gpa: Allocator,
    /// The directory, absolute and without a trailing slash (except "/").
    path: []u8,
    names: []u8,
    entries: []Entry,

    pub fn deinit(l: *Listing) void {
        l.gpa.free(l.path);
        l.gpa.free(l.names);
        l.gpa.free(l.entries);
        l.* = undefined;
    }

    pub fn name(l: *const Listing, e: Entry) []const u8 {
        return l.names[e.name_off..][0..e.name_len];
    }
};

pub const ReadError = error{ FileNotFound, AccessDenied, NotDir, OutOfMemory, Unexpected };

/// Reads `path` (absolute): every entry but "." and "..", with its type,
/// size, and modification time. Symbolic links report their target's
/// kind. Blocking: runs on a worker thread.
pub fn read(gpa: Allocator, path: []const u8) ReadError!Listing {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const zpath = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return error.FileNotFound;
    const rc = linux.openat(linux.AT.FDCWD, zpath, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    const fd: i32 = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer _ = linux.close(fd);

    var names: std.ArrayList(u8) = .empty;
    errdefer names.deinit(gpa);
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);

    var buf: [32 * 1024]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Unexpected,
        }
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
            off += d.reclen;
            const raw: [*:0]const u8 = @ptrCast(&buf[off - d.reclen + @offsetOf(linux.dirent64, "name")]);
            const nm = std.mem.span(raw);
            if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
            const e = try stat(fd, raw, nm, @intCast(names.items.len));
            try names.appendSlice(gpa, nm);
            try entries.append(gpa, e);
        }
    }
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    const owned_names = try names.toOwnedSlice(gpa);
    errdefer gpa.free(owned_names);
    return .{ .gpa = gpa, .path = owned_path, .names = owned_names, .entries = try entries.toOwnedSlice(gpa) };
}

fn stat(dirfd: i32, zname: [*:0]const u8, nm: []const u8, name_off: u32) !Entry {
    var st: linux.Statx = undefined;
    const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true };
    var e: Entry = .{
        .name_off = name_off,
        .name_len = @intCast(nm.len),
        .size = 0,
        .mtime = 0,
        .mode = 0,
        .kind = .other,
        .category = .other,
        .link = false,
        .hidden = nm.len > 0 and nm[0] == '.',
    };
    if (linux.errno(linux.statx(dirfd, zname, linux.AT.SYMLINK_NOFOLLOW, mask, &st)) != .SUCCESS) {
        e.category = categorize(nm, .other, 0);
        return e;
    }
    if (st.mode & linux.S.IFMT == linux.S.IFLNK) {
        e.link = true;
        // The target, if there is one; a dangling link stays "other".
        var target: linux.Statx = undefined;
        if (linux.errno(linux.statx(dirfd, zname, 0, mask, &target)) == .SUCCESS) st = target;
    }
    e.size = st.size;
    e.mtime = st.mtime.sec * std.time.ns_per_s + st.mtime.nsec;
    e.mode = st.mode;
    e.kind = switch (st.mode & linux.S.IFMT) {
        linux.S.IFDIR => .dir,
        linux.S.IFREG => .file,
        else => .other,
    };
    if (e.kind == .dir) e.size = 0;
    e.category = categorize(nm, e.kind, e.mode);
    return e;
}

/// The category of a file from its kind and extension.
pub fn categorize(nm: []const u8, kind: Kind, mode: u32) Category {
    if (kind == .dir) return .folder;
    const dot = std.mem.lastIndexOfScalar(u8, nm, '.') orelse {
        return if (kind == .file and mode & 0o111 != 0) .executable else if (kind == .file) .text else .other;
    };
    if (dot == 0) return .text; // dotfiles: configuration
    var ext_buf: [8]u8 = undefined;
    const ext_raw = nm[dot + 1 ..];
    if (ext_raw.len > ext_buf.len) return .other;
    const ext = std.ascii.lowerString(&ext_buf, ext_raw);
    const table = [_]struct { Category, []const []const u8 }{
        .{ .image, &.{ "png", "jpg", "jpeg", "gif", "webp", "avif", "jxl", "svg", "bmp", "tif", "tiff", "ico", "heic" } },
        .{ .audio, &.{ "mp3", "flac", "ogg", "opus", "wav", "m4a", "aac" } },
        .{ .video, &.{ "mp4", "mkv", "webm", "mov", "avi", "m4v" } },
        .{ .archive, &.{ "zip", "tar", "gz", "xz", "zst", "bz2", "7z", "rar", "tgz", "deb", "rpm" } },
        .{ .document, &.{ "pdf", "odt", "ods", "odp", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "epub" } },
        .{ .code, &.{ "zig", "c", "h", "cc", "cpp", "hpp", "rs", "go", "py", "js", "ts", "lua", "java", "sh", "json", "toml", "yaml", "yml", "xml", "html", "css" } },
        .{ .text, &.{ "txt", "md", "rst", "log", "csv", "ini", "conf", "cfg" } },
    };
    for (table) |row| for (row[1]) |x| if (std.mem.eql(u8, ext, x)) return row[0];
    if (kind == .file and mode & 0o111 != 0) return .executable;
    return .other;
}

/// Whether siv decodes the file for a thumbnail.
pub fn thumbnailable(nm: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, nm, '.') orelse return false;
    var ext_buf: [8]u8 = undefined;
    const ext_raw = nm[dot + 1 ..];
    if (ext_raw.len > ext_buf.len) return false;
    const ext = std.ascii.lowerString(&ext_buf, ext_raw);
    for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "avif", "jxl" }) |x| if (std.mem.eql(u8, ext, x)) return true;
    return false;
}

// Sorting ---------------------------------------------------------------------

pub const SortKey = enum(u8) { name, size, modified, type };

pub const Sort = struct {
    key: SortKey = .name,
    descending: bool = false,
    /// Folders before files whatever the order, as file managers do.
    folders_first: bool = true,
};

/// Fills `order` with every entry's index, sorted.
pub fn sort(l: *const Listing, order: []u32, s: Sort) void {
    std.debug.assert(order.len == l.entries.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, Ctx{ .l = l, .s = s }, Ctx.less);
}

const Ctx = struct {
    l: *const Listing,
    s: Sort,

    fn less(ctx: Ctx, a: u32, b: u32) bool {
        const ea = ctx.l.entries[a];
        const eb = ctx.l.entries[b];
        if (ctx.s.folders_first) {
            const da = ea.kind == .dir;
            const db = eb.kind == .dir;
            if (da != db) return da;
        }
        var ord: std.math.Order = switch (ctx.s.key) {
            .name => .eq,
            .size => std.math.order(ea.size, eb.size),
            .modified => std.math.order(ea.mtime, eb.mtime),
            .type => std.mem.order(u8, ea.category.label(), eb.category.label()),
        };
        if (ord == .eq) ord = naturalOrder(ctx.l.name(ea), ctx.l.name(eb));
        if (ord == .eq) ord = std.math.order(a, b);
        return if (ctx.s.descending) ord == .gt else ord == .lt;
    }
};

/// Compares names as people read them: case-insensitively (ASCII), with
/// runs of digits compared as numbers, so "file2" sorts before "file10".
/// A leading dot is ignored, so ".config" sorts among the c's.
pub fn naturalOrder(a_in: []const u8, b_in: []const u8) std.math.Order {
    const a = if (a_in.len > 1 and a_in[0] == '.') a_in[1..] else a_in;
    const b = if (b_in.len > 1 and b_in[0] == '.') b_in[1..] else b_in;
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            // Compare without leading zeros: longer is larger, then digits.
            const na = std.mem.trimStart(u8, a[i..ie], "0");
            const nb = std.mem.trimStart(u8, b[j..je], "0");
            if (na.len != nb.len) return std.math.order(na.len, nb.len);
            const o = std.mem.order(u8, na, nb);
            if (o != .eq) return o;
            i = ie;
            j = je;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return std.math.order(ca, cb);
        i += 1;
        j += 1;
    }
    const o = std.math.order(a.len - i, b.len - j);
    if (o != .eq) return o;
    // Equal ignoring case: a stable tiebreak on the bytes.
    return std.mem.order(u8, a_in, b_in);
}

// Filtering -------------------------------------------------------------------

/// Copies the indices of `order` whose entries match into `out` and
/// returns how many: hidden entries only with `show_hidden`, and with a
/// query, names containing it case-insensitively.
pub fn filter(l: *const Listing, order: []const u32, out: []u32, query: []const u8, show_hidden: bool) usize {
    var n: usize = 0;
    for (order) |i| {
        const e = l.entries[i];
        if (e.hidden and !show_hidden) continue;
        if (query.len != 0 and std.ascii.findIgnoreCase(l.name(e), query) == null) continue;
        out[n] = i;
        n += 1;
    }
    return n;
}

// Formatting ------------------------------------------------------------------

/// "2026-10-13 14:05" in UTC offset `tz_offset_s` (local time comes from
/// the caller, which reads /etc/localtime once).
pub fn formatTime(buf: []u8, mtime_ns: i64, tz_offset_s: i64) []const u8 {
    const secs = @divFloor(mtime_ns, std.time.ns_per_s) + tz_offset_s;
    if (secs < 0) return std.fmt.bufPrint(buf, "—", .{}) catch buf[0..0];
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch buf[0..0];
}

// Paths -----------------------------------------------------------------------

/// `dir` joined with `name`.
pub fn join(buf: []u8, dir: []const u8, nm: []const u8) ?[]u8 {
    const sep: []const u8 = if (dir.len > 0 and dir[dir.len - 1] == '/') "" else "/";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir, sep, nm }) catch null;
}

/// The parent of an absolute path; "/" is its own parent.
pub fn parent(path: []const u8) []const u8 {
    if (path.len <= 1) return "/";
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return if (i == 0) "/" else path[0..i];
}

/// The last component; "/" for the root.
pub fn basename(path: []const u8) []const u8 {
    if (path.len <= 1) return "/";
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

/// Whether `name` can be a file name: not empty, ".", or "..", without
/// slashes or NULs, at most 255 bytes.
pub fn validName(nm: []const u8) bool {
    if (nm.len == 0 or nm.len > 255) return false;
    if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) return false;
    return std.mem.indexOfAny(u8, nm, "/\x00") == null;
}

const testing = std.testing;

test "natural order" {
    try testing.expectEqual(.lt, naturalOrder("file2", "file10"));
    try testing.expectEqual(.gt, naturalOrder("file10", "file9"));
    try testing.expectEqual(.lt, naturalOrder("apple", "Banana"));
    try testing.expectEqual(.lt, naturalOrder("a", "ab"));
    try testing.expectEqual(.lt, naturalOrder(".bashrc", "config"));
    try testing.expectEqual(.lt, naturalOrder("x007", "x8"));
    try testing.expect(naturalOrder("Readme", "readme") != .eq);
}

test "categories" {
    try testing.expectEqual(Category.folder, categorize("x.png", .dir, 0));
    try testing.expectEqual(Category.image, categorize("Photo.JPG", .file, 0o644));
    try testing.expectEqual(Category.executable, categorize("run", .file, 0o755));
    try testing.expectEqual(Category.text, categorize("README", .file, 0o644));
    try testing.expectEqual(Category.code, categorize("main.zig", .file, 0o644));
}

test "times" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("2026-10-13 14:05", formatTime(&buf, 1_791_900_300 * std.time.ns_per_s, 0));
}

test "paths" {
    try testing.expectEqualStrings("/", parent("/home"));
    try testing.expectEqualStrings("/home", parent("/home/user"));
    try testing.expectEqualStrings("user", basename("/home/user"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/a", join(&buf, "/", "a").?);
    try testing.expectEqualStrings("/x/a", join(&buf, "/x", "a").?);
    try testing.expect(!validName("a/b"));
    try testing.expect(!validName(".."));
    try testing.expect(validName("..a"));
}
