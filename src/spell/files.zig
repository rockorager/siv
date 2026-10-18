//! Where dictionaries and personal word lists are (D37), and reading and
//! writing them. Everything here blocks: callers run it on the worker
//! pool's blocking lane (D6).
//!
//! Dictionaries are searched where Hunspell and Enchant look: $DICPATH,
//! Enchant's own directory ($XDG_CONFIG_HOME/enchant/hunspell), then
//! hunspell, myspell, and myspell/dicts under $XDG_DATA_HOME and each of
//! $XDG_DATA_DIRS (/usr/local/share:/usr/share by default). A dictionary
//! is a pair <name>.aff and <name>.dic; the first directory that has a
//! name wins. The personal dictionary is Enchant's,
//! $XDG_CONFIG_HOME/enchant/<name>.dic, with exclusions in <name>.exc.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

/// Most bytes read of one file: the largest Hunspell dictionaries
/// (Hungarian, Portuguese) are tens of megabytes.
pub const max_file = 256 << 20;

/// The environment the search follows.
pub const Environment = struct {
    home: ?[]const u8 = null,
    dicpath: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_data_dirs: ?[]const u8 = null,

    /// The process's environment.
    pub fn current() Environment {
        return .{
            .home = getenv("HOME"),
            .dicpath = getenv("DICPATH"),
            .xdg_config_home = getenv("XDG_CONFIG_HOME"),
            .xdg_data_home = getenv("XDG_DATA_HOME"),
            .xdg_data_dirs = getenv("XDG_DATA_DIRS"),
        };
    }
};

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

/// The directories to search for dictionaries, in order, without
/// duplicates. Free each and the list with `gpa`.
pub fn searchDirs(gpa: Allocator, env: Environment) error{OutOfMemory}![][]u8 {
    var dirs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }
    const S = struct {
        fn add(list: *std.ArrayList([]u8), a: Allocator, path: []u8) error{OutOfMemory}!void {
            for (list.items) |d| if (std.mem.eql(u8, d, path)) {
                a.free(path);
                return;
            };
            list.append(a, path) catch |err| {
                a.free(path);
                return err;
            };
        }
    };
    if (nonEmpty(env.dicpath)) |dp| {
        var it = std.mem.tokenizeScalar(u8, dp, ':');
        while (it.next()) |d| try S.add(&dirs, gpa, try gpa.dupe(u8, d));
    }
    if (nonEmpty(env.xdg_config_home)) |c| {
        try S.add(&dirs, gpa, try std.fmt.allocPrint(gpa, "{s}/enchant/hunspell", .{c}));
    } else if (nonEmpty(env.home)) |h| {
        try S.add(&dirs, gpa, try std.fmt.allocPrint(gpa, "{s}/.config/enchant/hunspell", .{h}));
    }
    var roots: std.ArrayList([]u8) = .empty;
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    if (nonEmpty(env.xdg_data_home)) |d| {
        try roots.append(gpa, try gpa.dupe(u8, d));
    } else if (nonEmpty(env.home)) |h| {
        try roots.append(gpa, try std.fmt.allocPrint(gpa, "{s}/.local/share", .{h}));
    }
    var it = std.mem.tokenizeScalar(u8, nonEmpty(env.xdg_data_dirs) orelse "/usr/local/share:/usr/share", ':');
    while (it.next()) |d| try roots.append(gpa, try gpa.dupe(u8, d));
    try roots.append(gpa, try gpa.dupe(u8, "/usr/share"));
    for (roots.items) |r| for ([_][]const u8{ "hunspell", "myspell", "myspell/dicts" }) |sub| {
        try S.add(&dirs, gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ r, sub }));
    };
    return dirs.toOwnedSlice(gpa);
}

/// Enchant's directory for personal word lists, or null without a home.
pub fn personalDir(gpa: Allocator, env: Environment) error{OutOfMemory}!?[]u8 {
    if (nonEmpty(env.xdg_config_home)) |c| return try std.fmt.allocPrint(gpa, "{s}/enchant", .{c});
    if (nonEmpty(env.home)) |h| return try std.fmt.allocPrint(gpa, "{s}/.config/enchant", .{h});
    return null;
}

fn zpath(buf: []u8, path: []const u8) ?[:0]const u8 {
    if (path.len >= buf.len or std.mem.indexOfScalar(u8, path, 0) != null) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub const ReadError = error{ OutOfMemory, ReadFailed, TooLarge };

/// Reads a whole regular file.
pub fn readFile(gpa: Allocator, path: []const u8) ReadError![]u8 {
    var zbuf: [4096]u8 = undefined;
    const z = zpath(&zbuf, path) orelse return error.ReadFailed;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true, .TYPE = true }, &st)) != .SUCCESS) return error.ReadFailed;
    if (st.mode & linux.S.IFMT != linux.S.IFREG) return error.ReadFailed;
    if (st.size > max_file) return error.TooLarge;
    const out = try gpa.alloc(u8, @intCast(st.size));
    errdefer gpa.free(out);
    var n: usize = 0;
    while (n < out.len) {
        const r = linux.read(fd, out[n..].ptr, out.len - n);
        switch (linux.errno(r)) {
            .SUCCESS => if (r == 0) break else {
                n += r;
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
    if (n != out.len) return error.ReadFailed;
    return out;
}

/// Calls `f(ctx, name)` for each dictionary name in `dir`: each <name>.aff
/// beside a <name>.dic.
pub fn eachDictionary(dir: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8) error{OutOfMemory}!void) error{OutOfMemory}!void {
    var zbuf: [4096]u8 = undefined;
    const z = zpath(&zbuf, dir) orelse return;
    const rc = linux.open(z, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const got = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(got) != .SUCCESS or got == 0) break;
        var off: usize = 0;
        while (off < got) {
            const ent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            off += ent.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (!std.mem.endsWith(u8, name, ".aff") or name.len <= 4) continue;
            const stem = name[0 .. name.len - 4];
            var pbuf: [4096]u8 = undefined;
            const dic = std.mem.printSentinel(&pbuf, "{s}/{s}.dic", .{ dir, stem }, 0) catch continue;
            var st: linux.Statx = undefined;
            if (linux.errno(linux.statx(linux.AT.FDCWD, dic, 0, .{ .TYPE = true }, &st)) != .SUCCESS) continue;
            try f(ctx, stem);
        }
    }
}

/// Every dictionary name in `dirs`, sorted, without duplicates. Free each
/// and the list with `gpa`.
pub fn listDictionaries(gpa: Allocator, dirs: []const []const u8) error{OutOfMemory}![][]u8 {
    const Ctx = struct {
        gpa: Allocator,
        names: std.ArrayList([]u8) = .empty,
        fn add(c: *@This(), name: []const u8) error{OutOfMemory}!void {
            for (c.names.items) |n| if (std.mem.eql(u8, n, name)) return;
            const owned = try c.gpa.dupe(u8, name);
            c.names.append(c.gpa, owned) catch |err| {
                c.gpa.free(owned);
                return err;
            };
        }
    };
    var ctx: Ctx = .{ .gpa = gpa };
    errdefer {
        for (ctx.names.items) |n| gpa.free(n);
        ctx.names.deinit(gpa);
    }
    for (dirs) |d| try eachDictionary(d, &ctx, Ctx.add);
    std.mem.sort([]u8, ctx.names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return ctx.names.toOwnedSlice(gpa);
}

/// The first directory of `dirs` with dictionary `name`.
pub fn findDictionary(dirs: []const []const u8, name: []const u8) ?[]const u8 {
    for (dirs) |d| {
        var pbuf: [4096]u8 = undefined;
        const aff = std.mem.printSentinel(&pbuf, "{s}/{s}.aff", .{ d, name }, 0) catch continue;
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, aff, 0, .{ .TYPE = true }, &st)) != .SUCCESS) continue;
        const dic = std.mem.printSentinel(&pbuf, "{s}/{s}.dic", .{ d, name }, 0) catch continue;
        if (linux.errno(linux.statx(linux.AT.FDCWD, dic, 0, .{ .TYPE = true }, &st)) != .SUCCESS) continue;
        return d;
    }
    return null;
}

/// Appends a line to a file, creating it and its directory as needed.
pub fn appendLine(path: []const u8, line: []const u8) error{WriteFailed}!void {
    var zbuf: [4096]u8 = undefined;
    if (std.fs.path.dirname(path)) |dir| makePath(dir);
    const z = zpath(&zbuf, path) orelse return error.WriteFailed;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    // One write, so concurrent appenders do not interleave a line.
    var buf: [1024]u8 = undefined;
    if (line.len + 1 > buf.len) return error.WriteFailed;
    @memcpy(buf[0..line.len], line);
    buf[line.len] = '\n';
    const r = linux.write(fd, &buf, line.len + 1);
    if (linux.errno(r) != .SUCCESS or r != line.len + 1) return error.WriteFailed;
}

fn makePath(dir: []const u8) void {
    var zbuf: [4096]u8 = undefined;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i != dir.len and dir[i] != '/') continue;
        const z = zpath(&zbuf, dir[0..i]) orelse return;
        _ = linux.mkdir(z, 0o755);
    }
}

/// A dictionary name for a BCP 47 tag or a POSIX locale name: "en-US",
/// "en_US.UTF-8", and "en_us" are "en_US"; the language lowercase, a
/// two-letter region uppercase, encoding and modifier dropped.
pub fn normalize(buf: []u8, tag: []const u8) []const u8 {
    var t = tag;
    if (std.mem.indexOfAny(u8, t, ".@")) |i| t = t[0..i];
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, t, "-_");
    var part: usize = 0;
    while (it.next()) |sub| : (part += 1) {
        if (n + sub.len + 1 > buf.len) break;
        if (part > 0) {
            buf[n] = '_';
            n += 1;
        }
        for (sub, 0..) |ch, k| buf[n + k] = if (part == 0) std.ascii.toLower(ch) else if (sub.len == 2) std.ascii.toUpper(ch) else if (k == 0) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
        n += sub.len;
    }
    return buf[0..n];
}

/// The dictionary of `names` for `tag` (normalized): the same name, the
/// language alone ("fr" for "fr_CA"), the language's own region ("de_DE"
/// for "de"), en_US for English, else the first name in the language.
pub fn pick(names: []const []const u8, tag: []const u8) ?usize {
    var buf: [64]u8 = undefined;
    const want = normalize(&buf, tag);
    if (want.len == 0) return null;
    const lang = want[0 .. std.mem.indexOfScalar(u8, want, '_') orelse want.len];
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, want)) return i;
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, lang)) return i;
    var own_buf: [16]u8 = undefined;
    if (lang.len <= 3) {
        const own = std.fmt.bufPrint(&own_buf, "{s}_{s}", .{ lang, lang }) catch unreachable;
        for (own, 0..) |*ch, k| {
            if (k > lang.len) ch.* = std.ascii.toUpper(ch.*);
        }
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, own)) return i;
    }
    if (std.mem.eql(u8, lang, "en")) for (names, 0..) |n, i| if (std.mem.eql(u8, n, "en_US")) return i;
    var best: ?usize = null;
    for (names, 0..) |n, i| {
        if (!std.mem.startsWith(u8, n, lang) or n.len <= lang.len or n[lang.len] != '_') continue;
        if (best == null or std.mem.lessThan(u8, n, names[best.?])) best = i;
    }
    return best;
}

test "dictionary names for languages" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("en_US", normalize(&buf, "en-US"));
    try std.testing.expectEqualStrings("en_US", normalize(&buf, "en_us.UTF-8"));
    try std.testing.expectEqualStrings("de", normalize(&buf, "DE"));
    try std.testing.expectEqualStrings("sr_Latn_RS", normalize(&buf, "sr-latn-rs"));
    const names = [_][]const u8{ "de_AT", "de_CH", "de_DE", "en_AU", "en_GB", "en_US", "fr", "fr_CA", "pt_BR" };
    try std.testing.expectEqual(@as(?usize, 5), pick(&names, "en-US"));
    try std.testing.expectEqual(@as(?usize, 4), pick(&names, "en-GB"));
    try std.testing.expectEqual(@as(?usize, 5), pick(&names, "en"));
    try std.testing.expectEqual(@as(?usize, 5), pick(&names, "en-IE"));
    try std.testing.expectEqual(@as(?usize, 2), pick(&names, "de"));
    try std.testing.expectEqual(@as(?usize, 1), pick(&names, "de-CH"));
    try std.testing.expectEqual(@as(?usize, 7), pick(&names, "fr-CA"));
    try std.testing.expectEqual(@as(?usize, 6), pick(&names, "fr-BE"));
    try std.testing.expectEqual(@as(?usize, 8), pick(&names, "pt"));
    try std.testing.expectEqual(@as(?usize, null), pick(&names, "es"));
    try std.testing.expectEqual(@as(?usize, null), pick(&names, ""));
}

test "search directories follow the environment" {
    const gpa = std.testing.allocator;
    const dirs = try searchDirs(gpa, .{ .home = "/home/u", .dicpath = "/opt/dicts:/opt/dicts", .xdg_data_dirs = "/usr/share" });
    defer {
        for (dirs) |d| gpa.free(d);
        gpa.free(dirs);
    }
    try std.testing.expectEqualStrings("/opt/dicts", dirs[0]);
    try std.testing.expectEqualStrings("/home/u/.config/enchant/hunspell", dirs[1]);
    try std.testing.expectEqualStrings("/home/u/.local/share/hunspell", dirs[2]);
    try std.testing.expectEqualStrings("/usr/share/hunspell", dirs[5]);
    try std.testing.expectEqual(@as(usize, 8), dirs.len);
}
