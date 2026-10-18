//! The freedesktop.org Trash specification, version 1.0 (D42): moving
//! files to a trash, listing what it holds, restoring an item to where it
//! was, deleting one, and emptying every trash. Blocking file system work:
//! callers run it on the worker pool (D6), never on the UI thread.
//!
//! - A trash directory holds `files/` (the trashed files, under names
//!   unique in that trash), `info/` (a `NAME.trashinfo` per file with its
//!   original path, percent-encoded, and its local deletion date), and
//!   `directorysizes` (a cache of trashed directories' disk usage).
//! - Files on the file system of the home trash ($XDG_DATA_HOME/Trash)
//!   go there with absolute paths. Files elsewhere go to the trash at the
//!   top of their mount: `$topdir/.Trash/$uid` when `$topdir/.Trash` is a
//!   sticky directory and not a symbolic link, else `$topdir/.Trash-$uid`,
//!   with paths relative to `$topdir`. A file that can be in neither is
//!   `error.Unsupported`: it is not copied to the home trash.
//! - The info file is created first with O_EXCL, which claims the name,
//!   and the file is renamed into `files/` without replacing anything, so
//!   two processes trashing at once never share a name.
//! - An item is named by its path in `files/` (its id). Restoring and
//!   deleting check that an id names an entry of a trash directory, so
//!   they cannot touch other files.
//!
//! Imports: nothing.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The file, or the trashed item, does not exist.
    FileNotFound,
    AccessDenied,
    /// No trash can take the file (its file system has no usable trash,
    /// it is in a trash already, or restoring would cross file systems).
    Unsupported,
    /// Restoring: something exists at the destination.
    Exists,
    /// Not the id of an item in a trash.
    InvalidId,
    NameTooLong,
    NoSpace,
    OutOfMemory,
    Unexpected,
};

const PathBuf = [linux.PATH_MAX]u8;

pub const Item = struct {
    /// Its path in the trash's `files/`.
    id: []const u8,
    /// Where it was, absolute; empty when its info file names none.
    path: []const u8,
    /// When it was trashed, in seconds since the epoch; 0 if unknown.
    deleted: i64,
    /// Bytes: a file's size, a directory's disk usage (`du -B1`).
    size: u64,
    directory: bool,
};

pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item,

    pub fn deinit(l: *List) void {
        l.arena.deinit();
    }
};

pub const Trash = struct {
    /// The home trash, absolute.
    home: []const u8,
    uid: u32,
    /// Mount points to consider; null reads /proc/self/mountinfo. Tests
    /// name directories of one file system as mounts of their own.
    mounts: ?[]const []const u8 = null,
    /// Only the home trash: files elsewhere are `error.Unsupported`
    /// (inside Flatpak, whose mount table is not the host's, D42).
    home_only: bool = false,

    /// Moves `path` (not following a final symbolic link) to the trash and
    /// returns its id, owned by the caller.
    pub fn trash(t: *const Trash, gpa: Allocator, path: []const u8) Error![]u8 {
        var cbuf: PathBuf = undefined;
        const canon = try canonical(&cbuf, path);
        var st: linux.Statx = undefined;
        try statPath(canon, &st);
        var mounts = try t.loadMounts(gpa);
        defer mounts.deinit(gpa);
        const file_mount = mounts.of(canon);
        var hbuf: PathBuf = undefined;
        const home_mount = mounts.of(try existingAncestor(&hbuf, t.home));

        var dbuf: PathBuf = undefined;
        const dir: []const u8, const topdir: ?[]const u8 = if (std.mem.eql(u8, file_mount, home_mount)) blk: {
            try makeDirs(t.home);
            break :blk .{ t.home, null };
        } else blk: {
            if (t.home_only) return error.Unsupported;
            break :blk .{ try topdirTrash(&dbuf, file_mount, t.uid, true) orelse return error.Unsupported, file_mount };
        };
        // Trashing the trash, or something inside it.
        var rbuf: PathBuf = undefined;
        const real_dir = canonicalDir(&rbuf, dir) catch dir;
        if (isWithin(canon, real_dir) or isWithin(real_dir, canon)) return error.Unsupported;
        try ensureSub(dir, "files");
        try ensureSub(dir, "info");

        var body_buf: [linux.PATH_MAX * 3 + 128]u8 = undefined;
        const body = try infoBody(&body_buf, if (topdir) |td| relativeTo(canon, td) else canon, now());

        const base = std.fs.path.basename(canon);
        var n: u32 = 1;
        while (n < 10_000) : (n += 1) {
            var nbuf: [256]u8 = undefined;
            const name = trashName(&nbuf, base, n);
            var ibuf: PathBuf = undefined;
            const info = try join(&ibuf, &.{ dir, "/info/", name, ".trashinfo" });
            const rc = linux.openat(linux.AT.FDCWD, info, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
            const fd: i32 = switch (linux.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .EXIST => continue,
                else => |e| return mapErrno(e),
            };
            const written = writeAll(fd, body);
            _ = linux.close(fd);
            if (!written) {
                _ = linux.unlinkat(linux.AT.FDCWD, info, 0);
                return error.NoSpace;
            }
            var fbuf: PathBuf = undefined;
            const target = try join(&fbuf, &.{ dir, "/files/", name });
            switch (linux.errno(linux.renameat2(linux.AT.FDCWD, canon, linux.AT.FDCWD, target, .{ .NOREPLACE = true }))) {
                .SUCCESS => return gpa.dupe(u8, target),
                // A file without an info file holds the name.
                .EXIST => {
                    _ = linux.unlinkat(linux.AT.FDCWD, info, 0);
                    continue;
                },
                else => |e| {
                    _ = linux.unlinkat(linux.AT.FDCWD, info, 0);
                    return switch (e) {
                        // Another file system after all (a btrfs
                        // subvolume, a bind mount the table did not show),
                        // or the trash inside what is trashed.
                        .XDEV, .INVAL => error.Unsupported,
                        else => mapErrno(e),
                    };
                },
            }
        }
        return error.Exists;
    }

    /// Moves item `id` back to where it was, or to `dest`, creating
    /// missing parent folders, and returns where it went (owned).
    /// `error.Exists` if something is there.
    pub fn restore(t: *const Trash, gpa: Allocator, id: []const u8, dest: ?[]const u8) Error![]u8 {
        const e = try t.entry(id);
        var ibuf: PathBuf = undefined;
        const info = try join(&ibuf, &.{ e.dir, "/info/", e.name, ".trashinfo" });
        var raw: [16384]u8 = undefined;
        const text = try readFile(info, &raw);
        var obuf: PathBuf = undefined;
        const original = parseInfo(text, topdirOf(e.dir, t.home), &obuf).path;
        const target_src = dest orelse original;
        if (target_src.len == 0 or target_src[0] != '/') return error.InvalidId;
        var tbuf: PathBuf = undefined;
        const target = try join(&tbuf, &.{target_src});
        if (std.fs.path.dirname(target)) |parent| try makeDirsMode(parent, 0o777);
        var fbuf: PathBuf = undefined;
        const src = try join(&fbuf, &.{id});
        switch (linux.errno(linux.renameat2(linux.AT.FDCWD, src, linux.AT.FDCWD, target, .{ .NOREPLACE = true }))) {
            .SUCCESS => {},
            .XDEV => return error.Unsupported,
            else => |er| return mapErrno(er),
        }
        _ = linux.unlinkat(linux.AT.FDCWD, info, 0);
        removeSize(gpa, e.dir, e.name);
        return gpa.dupe(u8, target);
    }

    /// Deletes item `id` for good.
    pub fn delete(t: *const Trash, gpa: Allocator, id: []const u8) Error!void {
        const e = try t.entry(id);
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(gpa);
        try path.appendSlice(gpa, id);
        try deleteTree(gpa, &path);
        var ibuf: PathBuf = undefined;
        const info = try join(&ibuf, &.{ e.dir, "/info/", e.name, ".trashinfo" });
        switch (linux.errno(linux.unlinkat(linux.AT.FDCWD, info, 0))) {
            .SUCCESS, .NOENT => {},
            else => |er| return mapErrno(er),
        }
        removeSize(gpa, e.dir, e.name);
    }

    /// Every item of every trash: the home trash and the trashes at the
    /// top of each mount. Info files whose file is gone are left out;
    /// directory sizes come from `directorysizes`, computed and written
    /// back for directories it lacks or whose info file changed.
    pub fn list(t: *const Trash, gpa: Allocator) Error!List {
        var out: List = .{ .arena = .init(gpa), .items = &.{} };
        errdefer out.deinit();
        const arena = out.arena.allocator();
        var items: std.ArrayList(Item) = .empty;
        var dirs = try t.trashDirs(gpa);
        defer dirs.deinit(gpa);
        for (dirs.items()) |dir| try listDir(gpa, arena, &items, dir, topdirOf(dir, t.home));
        out.items = items.items;
        return out;
    }

    /// Deletes everything in every trash. Goes on past failures and
    /// returns the first.
    pub fn empty(t: *const Trash, gpa: Allocator) Error!void {
        var dirs = try t.trashDirs(gpa);
        defer dirs.deinit(gpa);
        var first: ?Error = null;
        for (dirs.items()) |dir| {
            for ([_][]const u8{ "/files", "/info" }) |sub| {
                var path: std.ArrayList(u8) = .empty;
                defer path.deinit(gpa);
                try path.appendSlice(gpa, dir);
                try path.appendSlice(gpa, sub);
                deleteChildren(gpa, &path) catch |err| if (err != error.FileNotFound and first == null) {
                    first = err;
                };
            }
            var sbuf: PathBuf = undefined;
            _ = linux.unlinkat(linux.AT.FDCWD, try join(&sbuf, &.{ dir, "/directorysizes" }), 0);
        }
        if (first) |err| return err;
    }

    const Entry = struct { dir: []const u8, name: []const u8 };

    /// The trash directory and name of an id, checked.
    fn entry(t: *const Trash, id: []const u8) Error!Entry {
        const files = std.fs.path.dirname(id) orelse return error.InvalidId;
        const name = std.fs.path.basename(id);
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidId;
        if (!std.mem.eql(u8, std.fs.path.basename(files), "files")) return error.InvalidId;
        const dir = std.fs.path.dirname(files) orelse return error.InvalidId;
        if (std.mem.indexOf(u8, dir, "/../") != null or std.mem.endsWith(u8, dir, "/..")) return error.InvalidId;
        if (!std.mem.eql(u8, dir, t.home) and topdirOfTrash(dir, t.uid) == null) return error.InvalidId;
        var st: linux.Statx = undefined;
        var buf: PathBuf = undefined;
        statPath(try join(&buf, &.{id}), &st) catch |err| return if (err == error.FileNotFound) error.FileNotFound else err;
        return .{ .dir = dir, .name = name };
    }

    fn loadMounts(t: *const Trash, gpa: Allocator) Error!Mounts {
        if (t.mounts) |m| return Mounts.fromList(gpa, m);
        return Mounts.read(gpa);
    }

    /// The home trash and the topdir trashes that exist.
    fn trashDirs(t: *const Trash, gpa: Allocator) Error!Dirs {
        var dirs: Dirs = .{};
        errdefer dirs.deinit(gpa);
        try dirs.add(gpa, t.home);
        if (t.home_only) return dirs;
        var mounts = try t.loadMounts(gpa);
        defer mounts.deinit(gpa);
        var hbuf: PathBuf = undefined;
        const real_home = canonicalDir(&hbuf, t.home) catch "";
        for (mounts.points.items) |m| {
            for ([_]bool{ true, false }) |admin| {
                var buf: PathBuf = undefined;
                const dir = (if (admin) adminTrash(&buf, m, t.uid, false) else userTrash(&buf, m, t.uid, false)) catch continue orelse continue;
                if (std.mem.eql(u8, dir, real_home)) continue;
                try dirs.add(gpa, dir);
            }
        }
        return dirs;
    }
};

/// Where the home trash is: $XDG_DATA_HOME/Trash, else
/// ~/.local/share/Trash. Inside Flatpak $XDG_DATA_HOME is the
/// application's own, so the host's ($HOST_XDG_DATA_HOME) applies.
pub fn homeTrash(buf: *PathBuf, flatpak: bool) ?[]const u8 {
    const data = std.c.getenv(if (flatpak) "HOST_XDG_DATA_HOME" else "XDG_DATA_HOME");
    if (data) |d| {
        const s = std.mem.span(d);
        if (s.len > 0 and s[0] == '/') return join(buf, &.{ s, "/Trash" }) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    if (home.len == 0 or home[0] != '/') return null;
    return join(buf, &.{ home, "/.local/share/Trash" }) catch null;
}

// Info files --------------------------------------------------------------------

pub const Info = struct {
    /// Absolute when the topdir was known or the file said so; empty if
    /// missing.
    path: []const u8,
    deleted: i64,
};

/// Reads a .trashinfo file's Path (percent-decoded, resolved against
/// `topdir` when relative) and DeletionDate (local time).
pub fn parseInfo(text: []const u8, topdir: ?[]const u8, buf: *PathBuf) Info {
    var info: Info = .{ .path = "", .deleted = 0 };
    var in_group = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[Trash Info]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (std.mem.eql(u8, key, "Path")) {
            var dec: PathBuf = undefined;
            const p = percentDecode(&dec, value) orelse continue;
            info.path = if (p.len > 0 and p[0] != '/' and topdir != null)
                join(buf, &.{ topdir.?, if (std.mem.endsWith(u8, topdir.?, "/")) "" else "/", p }) catch continue
            else
                join(buf, &.{p}) catch continue;
        } else if (std.mem.eql(u8, key, "DeletionDate")) {
            info.deleted = parseDate(value) orelse 0;
        }
    }
    return info;
}

fn infoBody(buf: []u8, path: []const u8, when: i64) Error![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var tm: Tm = undefined;
    const t: c_long = @intCast(when);
    if (localtime_r(&t, &tm) == null) return error.Unexpected;
    w.writeAll("[Trash Info]\nPath=") catch return error.NameTooLong;
    percentEncode(&w, path) catch return error.NameTooLong;
    w.print("\nDeletionDate={d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{
        @as(u32, @intCast(tm.year + 1900)), @as(u32, @intCast(tm.mon + 1)), @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(tm.hour)),        @as(u32, @intCast(tm.min)),     @as(u32, @intCast(tm.sec)),
    }) catch return error.NameTooLong;
    return w.buffered();
}

/// Escapes every byte but unreserved characters and slashes (RFC 3986),
/// as the specification asks.
pub fn percentEncode(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |b| {
        if (std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "-._~/", b) != null) {
            try w.writeByte(b);
        } else {
            try w.writeAll(&.{ '%', hex[b >> 4], hex[b & 15] });
        }
    }
}

/// Decodes %XX escapes; null for a malformed one.
pub fn percentDecode(buf: *PathBuf, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (n == buf.len) return null;
        if (s[i] == '%') {
            if (i + 3 > s.len) return null;
            buf[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            buf[n] = s[i];
            i += 1;
        }
    }
    if (std.mem.indexOfScalar(u8, buf[0..n], 0) != null) return null;
    return buf[0..n];
}

/// YYYY-MM-DDThh:mm:ss in local time, to seconds since the epoch.
pub fn parseDate(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const num = struct {
        fn f(x: []const u8) ?c_int {
            return std.fmt.parseInt(c_int, x, 10) catch null;
        }
    }.f;
    var tm: Tm = std.mem.zeroes(Tm);
    tm.year = (num(s[0..4]) orelse return null) - 1900;
    tm.mon = (num(s[5..7]) orelse return null) - 1;
    tm.mday = num(s[8..10]) orelse return null;
    tm.hour = num(s[11..13]) orelse return null;
    tm.min = num(s[14..16]) orelse return null;
    tm.sec = num(s[17..19]) orelse return null;
    tm.isdst = -1;
    const t = mktime(&tm);
    return if (t == -1) null else t;
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;
extern "c" fn mktime(tm: *Tm) c_long;
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

/// `base` with ".n" for n > 1 (GIO's names), shortened at a UTF-8
/// boundary so that NAME.trashinfo fits a file name.
fn trashName(buf: *[256]u8, base: []const u8, n: u32) []const u8 {
    var suffix_buf: [12]u8 = undefined;
    const suffix = if (n == 1) "" else std.fmt.bufPrint(&suffix_buf, ".{d}", .{n}) catch unreachable;
    var keep = @min(base.len, 255 - ".trashinfo".len - suffix.len);
    while (keep > 0 and keep < base.len and base[keep] & 0xc0 == 0x80) keep -= 1;
    @memcpy(buf[0..keep], base[0..keep]);
    @memcpy(buf[keep..][0..suffix.len], suffix);
    return buf[0 .. keep + suffix.len];
}

// Trash directories ----------------------------------------------------------------

/// The trash for files on the mount at `topdir`: $topdir/.Trash/$uid if
/// $topdir/.Trash is usable, else $topdir/.Trash-$uid; made if `create`.
fn topdirTrash(buf: *PathBuf, topdir: []const u8, uid: u32, create: bool) Error!?[]const u8 {
    if (adminTrash(buf, topdir, uid, create) catch null) |d| return d;
    return userTrash(buf, topdir, uid, create);
}

fn adminTrash(buf: *PathBuf, topdir: []const u8, uid: u32, create: bool) Error!?[]const u8 {
    var abuf: PathBuf = undefined;
    const admin = try join(&abuf, &.{ topdir, if (std.mem.endsWith(u8, topdir, "/")) "" else "/", ".Trash" });
    var st: linux.Statx = undefined;
    statPath(admin, &st) catch return null;
    // A directory with the sticky bit, not a symbolic link.
    if (st.mode & linux.S.IFMT != linux.S.IFDIR or st.mode & linux.S.ISVTX == 0) return null;
    var ubuf: [16]u8 = undefined;
    const dir = try join(buf, &.{ admin, "/", std.fmt.bufPrint(&ubuf, "{d}", .{uid}) catch unreachable });
    return try ownDir(dir, uid, create);
}

fn userTrash(buf: *PathBuf, topdir: []const u8, uid: u32, create: bool) Error!?[]const u8 {
    var ubuf: [24]u8 = undefined;
    const dir = try join(buf, &.{ topdir, if (std.mem.endsWith(u8, topdir, "/")) "" else "/", std.fmt.bufPrint(&ubuf, ".Trash-{d}", .{uid}) catch unreachable });
    return try ownDir(dir, uid, create);
}

/// `dir` if it is a directory (not a link) owned by `uid`, made with mode
/// 0700 if missing and `create`; null if it cannot be used.
fn ownDir(dir: [:0]const u8, uid: u32, create: bool) Error!?[:0]const u8 {
    var st: linux.Statx = undefined;
    statPath(dir, &st) catch |err| {
        if (err != error.FileNotFound or !create) return null;
        switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, dir, 0o700))) {
            .SUCCESS => return dir,
            else => return null,
        }
    };
    if (st.mode & linux.S.IFMT != linux.S.IFDIR or st.uid != uid) return null;
    return dir;
}

/// The mount top directory of a topdir trash, or null.
fn topdirOfTrash(dir: []const u8, uid: u32) ?[]const u8 {
    var ubuf: [24]u8 = undefined;
    const base = std.fs.path.basename(dir);
    const parent = std.fs.path.dirname(dir) orelse return null;
    if (std.mem.eql(u8, base, std.fmt.bufPrint(&ubuf, ".Trash-{d}", .{uid}) catch unreachable)) return parent;
    if (std.mem.eql(u8, base, std.fmt.bufPrint(&ubuf, "{d}", .{uid}) catch unreachable) and std.mem.eql(u8, std.fs.path.basename(parent), ".Trash"))
        return std.fs.path.dirname(parent);
    return null;
}

/// What relative paths in a trash's info files are relative to.
fn topdirOf(dir: []const u8, home: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, dir, home)) return null;
    const base = std.fs.path.basename(dir);
    const parent = std.fs.path.dirname(dir) orelse return null;
    if (std.mem.startsWith(u8, base, ".Trash-")) return parent;
    if (std.mem.eql(u8, std.fs.path.basename(parent), ".Trash")) return std.fs.path.dirname(parent);
    return null;
}

const Dirs = struct {
    bytes: std.ArrayList(u8) = .empty,
    ends: std.ArrayList(usize) = .empty,
    buf: std.ArrayList([]const u8) = .empty,

    fn add(d: *Dirs, gpa: Allocator, dir: []const u8) Error!void {
        try d.bytes.appendSlice(gpa, dir);
        try d.ends.append(gpa, d.bytes.items.len);
        d.buf.clearRetainingCapacity();
        var start: usize = 0;
        for (d.ends.items) |e| {
            try d.buf.append(gpa, d.bytes.items[start..e]);
            start = e;
        }
    }

    fn items(d: *const Dirs) []const []const u8 {
        return d.buf.items;
    }

    fn deinit(d: *Dirs, gpa: Allocator) void {
        d.bytes.deinit(gpa);
        d.ends.deinit(gpa);
        d.buf.deinit(gpa);
    }
};

// Mounts ---------------------------------------------------------------------------

const Mounts = struct {
    points: std.ArrayList([]u8) = .empty,

    fn fromList(gpa: Allocator, list: []const []const u8) Error!Mounts {
        var m: Mounts = .{};
        errdefer m.deinit(gpa);
        for (list) |p| try m.points.append(gpa, try gpa.dupe(u8, p));
        return m;
    }

    /// Pseudo file systems hold no user files and are not looked at.
    const skipped = [_][]const u8{ "proc", "sysfs", "cgroup", "cgroup2", "devpts", "devtmpfs", "mqueue", "debugfs", "tracefs", "securityfs", "pstore", "bpf", "autofs", "fusectl", "configfs", "binfmt_misc", "hugetlbfs", "rpc_pipefs", "nsfs", "efivarfs", "selinuxfs" };

    fn read(gpa: Allocator) Error!Mounts {
        var m: Mounts = .{};
        errdefer m.deinit(gpa);
        try m.points.append(gpa, try gpa.dupe(u8, "/"));
        const rc = linux.openat(linux.AT.FDCWD, "/proc/self/mountinfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return m;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        while (true) {
            try text.ensureUnusedCapacity(gpa, 16384);
            const n = linux.read(fd, text.unusedCapacitySlice().ptr, text.unusedCapacitySlice().len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            text.items.len += n;
        }
        var lines = std.mem.splitScalar(u8, text.items, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ' ');
            var i: usize = 0;
            var point: []const u8 = "";
            while (fields.next()) |f| : (i += 1) {
                if (i == 4) point = f;
                if (std.mem.eql(u8, f, "-")) break;
            }
            const fstype = fields.next() orelse continue;
            if (point.len == 0 or std.mem.eql(u8, point, "/")) continue;
            if (for (skipped) |s| (if (std.mem.eql(u8, s, fstype)) break true) else false) continue;
            var buf: PathBuf = undefined;
            const p = unescapeOctal(&buf, point);
            var dup = false;
            for (m.points.items) |q| if (std.mem.eql(u8, q, p)) {
                dup = true;
            };
            if (!dup) try m.points.append(gpa, try gpa.dupe(u8, p));
        }
        return m;
    }

    fn deinit(m: *Mounts, gpa: Allocator) void {
        for (m.points.items) |p| gpa.free(p);
        m.points.deinit(gpa);
    }

    /// The mount point holding `path` (absolute, canonical).
    fn of(m: *const Mounts, path: []const u8) []const u8 {
        var best: []const u8 = "/";
        for (m.points.items) |p| {
            if (p.len > best.len and isWithin(path, p)) best = p;
        }
        return best;
    }
};

/// mountinfo escapes spaces, tabs, newlines, and backslashes as \ooo.
fn unescapeOctal(buf: *PathBuf, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) : (n += 1) {
        if (s[i] == '\\' and i + 4 <= s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 4], 8)) |b| {
                buf[n] = b;
                i += 4;
                continue;
            } else |_| {}
        }
        buf[n] = s[i];
        i += 1;
    }
    return buf[0..n];
}

/// `path` is `dir` or below it.
fn isWithin(path: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, dir, "/")) return path.len > 0 and path[0] == '/';
    const d = std.mem.trimEnd(u8, dir, "/");
    if (!std.mem.startsWith(u8, path, d)) return false;
    return path.len == d.len or path[d.len] == '/';
}

fn relativeTo(path: []const u8, topdir: []const u8) []const u8 {
    if (std.mem.eql(u8, topdir, "/")) return path[1..];
    const d = std.mem.trimEnd(u8, topdir, "/");
    return path[d.len + 1 ..];
}

// Listing ---------------------------------------------------------------------------

const SizeEntry = struct { size: u64, mtime: i64 };

fn listDir(gpa: Allocator, arena: Allocator, items: *std.ArrayList(Item), dir: []const u8, topdir: ?[]const u8) Error!void {
    var ibuf: PathBuf = undefined;
    const info_dir = try join(&ibuf, &.{ dir, "/info" });
    var names = readNames(gpa, info_dir) catch |err| return if (err == error.FileNotFound or err == error.AccessDenied) {} else err;
    defer names.deinit(gpa);
    var sizes = readSizes(gpa, dir);
    defer {
        var it = sizes.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        sizes.deinit(gpa);
    }
    var dirty = false;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var it = names.iterator();
    while (it.next()) |file| {
        if (!std.mem.endsWith(u8, file, ".trashinfo") or file.len == ".trashinfo".len) continue;
        const name = file[0 .. file.len - ".trashinfo".len];
        var fbuf: PathBuf = undefined;
        const id = join(&fbuf, &.{ dir, "/files/", name }) catch continue;
        var st: linux.Statx = undefined;
        statPath(id, &st) catch continue;
        var pbuf: PathBuf = undefined;
        const info_path = join(&pbuf, &.{ dir, "/info/", file }) catch continue;
        var raw: [16384]u8 = undefined;
        const text = readFile(info_path, &raw) catch continue;
        var obuf: PathBuf = undefined;
        const info = parseInfo(text, topdir, &obuf);
        const is_dir = st.mode & linux.S.IFMT == linux.S.IFDIR;
        var size: u64 = st.size;
        if (is_dir) {
            var ist: linux.Statx = undefined;
            const mtime: i64 = if (statPath(info_path, &ist)) ist.mtime.sec else |_| 0;
            if (sizes.get(name)) |e| if (e.mtime == mtime) {
                size = e.size;
            } else {
                size = try usage(gpa, id);
                sizes.getPtr(name).?.* = .{ .size = size, .mtime = mtime };
                dirty = true;
            } else {
                size = try usage(gpa, id);
                try sizes.put(gpa, try gpa.dupe(u8, name), .{ .size = size, .mtime = mtime });
                dirty = true;
            }
            try seen.put(gpa, name, {});
        }
        try items.append(arena, .{
            .id = try arena.dupe(u8, id),
            .path = try arena.dupe(u8, info.path),
            .deleted = info.deleted,
            .size = size,
            .directory = is_dir,
        });
    }
    // Entries of directories no longer trashed go.
    var keys = sizes.keyIterator();
    while (keys.next()) |k| if (!seen.contains(k.*)) {
        dirty = true;
    };
    if (dirty) writeSizes(gpa, dir, &sizes, &seen);
}

/// `directorysizes`: "size mtime name" per line, the name percent-encoded.
fn readSizes(gpa: Allocator, dir: []const u8) std.StringHashMapUnmanaged(SizeEntry) {
    var map: std.StringHashMapUnmanaged(SizeEntry) = .empty;
    var pbuf: PathBuf = undefined;
    const path = join(&pbuf, &.{ dir, "/directorysizes" }) catch return map;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    readAll(gpa, path, &text) catch return map;
    var lines = std.mem.splitScalar(u8, text.items, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ' ');
        const size = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
        const mtime = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue;
        var nbuf: PathBuf = undefined;
        const name = percentDecode(&nbuf, f.rest()) orelse continue;
        if (name.len == 0 or map.contains(name)) continue;
        const key = gpa.dupe(u8, name) catch break;
        map.put(gpa, key, .{ .size = size, .mtime = mtime }) catch {
            gpa.free(key);
            break;
        };
    }
    return map;
}

/// Writes the entries named in `keep` through a temporary file renamed
/// over the old one, as the specification requires. A cache: failures
/// leave it as it was.
fn writeSizes(gpa: Allocator, dir: []const u8, sizes: *const std.StringHashMapUnmanaged(SizeEntry), keep: ?*const std.StringHashMapUnmanaged(void)) void {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    var it = sizes.iterator();
    while (it.next()) |e| {
        if (keep) |k| if (!k.contains(e.key_ptr.*)) continue;
        text.writer.print("{d} {d} ", .{ e.value_ptr.size, e.value_ptr.mtime }) catch return;
        percentEncode(&text.writer, e.key_ptr.*) catch return;
        text.writer.writeByte('\n') catch return;
    }
    var pbuf: PathBuf = undefined;
    var tbuf: PathBuf = undefined;
    var nbuf: [32]u8 = undefined;
    const path = join(&pbuf, &.{ dir, "/directorysizes" }) catch return;
    const tmp = join(&tbuf, &.{ dir, "/directorysizes.", std.fmt.bufPrint(&nbuf, "{d}-{d}", .{ linux.getpid(), linux.gettid() }) catch return }) catch return;
    const rc = linux.openat(linux.AT.FDCWD, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    const ok = writeAll(fd, text.written());
    _ = linux.close(fd);
    if (!ok or linux.errno(linux.renameat(linux.AT.FDCWD, tmp, linux.AT.FDCWD, path)) != .SUCCESS) _ = linux.unlinkat(linux.AT.FDCWD, tmp, 0);
}

/// Drops `name`'s directorysizes entry, if it has one.
fn removeSize(gpa: Allocator, dir: []const u8, name: []const u8) void {
    var sizes = readSizes(gpa, dir);
    defer {
        var it = sizes.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        sizes.deinit(gpa);
    }
    const kv = sizes.fetchRemove(name) orelse return;
    gpa.free(kv.key);
    writeSizes(gpa, dir, &sizes, null);
}

/// Disk usage of a tree as `du -B1` counts it: allocated blocks of the
/// directory and everything below, links not followed.
fn usage(gpa: Allocator, root: []const u8) Error!u64 {
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    try path.appendSlice(gpa, root);
    return usageOf(gpa, &path);
}

fn usageOf(gpa: Allocator, path: *std.ArrayList(u8)) Error!u64 {
    var zbuf: PathBuf = undefined;
    var st: linux.Statx = undefined;
    statPath(try join(&zbuf, &.{path.items}), &st) catch return 0;
    var total: u64 = st.blocks * 512;
    if (st.mode & linux.S.IFMT != linux.S.IFDIR) return total;
    var names = readNames(gpa, try join(&zbuf, &.{path.items})) catch return total;
    defer names.deinit(gpa);
    const len = path.items.len;
    var it = names.iterator();
    while (it.next()) |n| {
        try path.append(gpa, '/');
        try path.appendSlice(gpa, n);
        total += try usageOf(gpa, path);
        path.shrinkRetainingCapacity(len);
    }
    return total;
}

// File system helpers -------------------------------------------------------------

/// Names in a directory, without "." and "..", read at once so that the
/// directory is closed before its children are visited: deep trees cost
/// memory per level, not a descriptor.
const Names = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(n: *Names, gpa: Allocator) void {
        n.bytes.deinit(gpa);
    }

    fn iterator(n: *const Names) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, if (n.bytes.items.len == 0) "" else n.bytes.items[0 .. n.bytes.items.len - 1], 0);
    }
};

fn readNames(gpa: Allocator, dir: [:0]const u8) Error!Names {
    const rc = linux.openat(linux.AT.FDCWD, dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0);
    const fd: i32 = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |e| return mapErrno(e),
    };
    defer _ = linux.close(fd);
    var names: Names = .{};
    errdefer names.deinit(gpa);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.Unexpected;
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
            const name_ptr: [*:0]const u8 = @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")]);
            off += d.reclen;
            const nm = std.mem.span(name_ptr);
            if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
            try names.bytes.appendSlice(gpa, nm);
            try names.bytes.append(gpa, 0);
        }
    }
    return names;
}

fn deleteTree(gpa: Allocator, path: *std.ArrayList(u8)) Error!void {
    var zbuf: PathBuf = undefined;
    const z = try join(&zbuf, &.{path.items});
    switch (linux.errno(linux.unlinkat(linux.AT.FDCWD, z, 0))) {
        .SUCCESS, .NOENT => return,
        .ISDIR, .PERM => {},
        else => |e| return mapErrno(e),
    }
    try deleteChildren(gpa, path);
    switch (linux.errno(linux.unlinkat(linux.AT.FDCWD, try join(&zbuf, &.{path.items}), linux.AT.REMOVEDIR))) {
        .SUCCESS, .NOENT => {},
        else => |e| return mapErrno(e),
    }
}

fn deleteChildren(gpa: Allocator, path: *std.ArrayList(u8)) Error!void {
    var zbuf: PathBuf = undefined;
    var names = try readNames(gpa, try join(&zbuf, &.{path.items}));
    defer names.deinit(gpa);
    const len = path.items.len;
    var first: ?Error = null;
    var it = names.iterator();
    while (it.next()) |n| {
        try path.append(gpa, '/');
        try path.appendSlice(gpa, n);
        deleteTree(gpa, path) catch |err| if (first == null) {
            first = err;
        };
        path.shrinkRetainingCapacity(len);
    }
    if (first) |err| return err;
}

/// The absolute path of `path` with its parent's links resolved and its
/// last component kept as it is.
fn canonical(buf: *PathBuf, path: []const u8) Error![:0]const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0 or path[0] != '/') return error.FileNotFound;
    const base = std.fs.path.basename(trimmed);
    if (std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.Unsupported;
    const parent = std.fs.path.dirname(trimmed) orelse "/";
    var pbuf: PathBuf = undefined;
    const real = try canonicalDir(&pbuf, parent);
    return join(buf, &.{ real, if (std.mem.eql(u8, real, "/")) "" else "/", base });
}

fn canonicalDir(buf: *PathBuf, dir: []const u8) Error![]const u8 {
    var zbuf: PathBuf = undefined;
    const z = try join(&zbuf, &.{dir});
    const r = realpath(z, buf) orelse return switch (std.c._errno().*) {
        @intFromEnum(linux.E.ACCES) => error.AccessDenied,
        @intFromEnum(linux.E.NAMETOOLONG) => error.NameTooLong,
        else => error.FileNotFound,
    };
    return std.mem.span(r);
}

/// The nearest existing ancestor of `path` (or itself), canonical.
fn existingAncestor(buf: *PathBuf, path: []const u8) Error![]const u8 {
    var p = path;
    while (true) {
        if (canonicalDir(buf, p)) |r| return r else |_| {}
        p = std.fs.path.dirname(p) orelse return "/";
    }
}

fn makeDirs(path: []const u8) Error!void {
    return makeDirsMode(path, 0o700);
}

fn makeDirsMode(path: []const u8, mode: u32) Error!void {
    var zbuf: PathBuf = undefined;
    const z = try join(&zbuf, &.{path});
    switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, z, mode))) {
        .SUCCESS, .EXIST => return,
        .NOENT => {},
        else => |e| return mapErrno(e),
    }
    const parent = std.fs.path.dirname(path) orelse return error.FileNotFound;
    try makeDirsMode(parent, mode);
    switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, z, mode))) {
        .SUCCESS, .EXIST => {},
        else => |e| return mapErrno(e),
    }
}

fn ensureSub(dir: []const u8, sub: []const u8) Error!void {
    var buf: PathBuf = undefined;
    switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, try join(&buf, &.{ dir, "/", sub }), 0o700))) {
        .SUCCESS, .EXIST => {},
        else => |e| return mapErrno(e),
    }
}

fn statPath(path: [:0]const u8, st: *linux.Statx) Error!void {
    const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .SIZE = true, .BLOCKS = true, .MTIME = true };
    switch (linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, mask, st))) {
        .SUCCESS => {},
        else => |e| return mapErrno(e),
    }
}

fn readFile(path: [:0]const u8, buf: []u8) Error![]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0);
    const fd: i32 = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |e| return mapErrno(e),
    };
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        switch (linux.errno(r)) {
            .SUCCESS => if (r == 0) break else {
                n += r;
            },
            .INTR => {},
            else => |e| return mapErrno(e),
        }
    }
    return buf[0..n];
}

fn readAll(gpa: Allocator, path: [:0]const u8, out: *std.ArrayList(u8)) Error!void {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0);
    const fd: i32 = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |e| return mapErrno(e),
    };
    defer _ = linux.close(fd);
    while (true) {
        try out.ensureUnusedCapacity(gpa, 4096);
        const spare = out.unusedCapacitySlice();
        const r = linux.read(fd, spare.ptr, spare.len);
        switch (linux.errno(r)) {
            .SUCCESS => if (r == 0) return else {
                out.items.len += r;
            },
            .INTR => {},
            else => |e| return mapErrno(e),
        }
    }
}

fn now() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn writeAll(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const w = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        switch (linux.errno(w)) {
            .SUCCESS => off += w,
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

/// Concatenates `parts` as a NUL-terminated path.
fn join(buf: *PathBuf, parts: []const []const u8) Error![:0]u8 {
    var n: usize = 0;
    for (parts) |p| {
        if (n + p.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    if (std.mem.indexOfScalar(u8, buf[0..n], 0) != null) return error.FileNotFound;
    buf[n] = 0;
    return buf[0..n :0];
}

fn mapErrno(e: linux.E) Error {
    return switch (e) {
        .NOENT, .NOTDIR, .LOOP => error.FileNotFound,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOSPC, .DQUOT => error.NoSpace,
        .EXIST, .NOTEMPTY => error.Exists,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.OutOfMemory,
        .XDEV => error.Unsupported,
        else => error.Unexpected,
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
