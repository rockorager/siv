//! Icon theme lookup (D19), following the freedesktop icon theme
//! specification: themes found in the icon base directories, their
//! index.theme parents and the hicolor fallback, directories matched by
//! size and scale (exactly, else the closest), PNG and SVG files, and
//! unthemed icons in /usr/share/pixmaps. `Themes` keeps every theme it
//! has read, with the names each of its directories holds, so a lookup
//! after the first touches no files. Lookups block on the file system
//! the first time a theme is used, so the UI runs them on its worker pool;
//! a mutex makes them safe from any thread.
//!
//! Imports: none.

const std = @import("std");
const linux = std.os.linux;
const c = std.c;
pub const index = @import("index.zig");

pub const Format = enum(u8) { png, svg };

/// A file that a lookup found.
pub const Found = struct {
    /// Owned by the caller (`gpa` of the `Themes`).
    path: []u8,
    format: Format,
    /// The size and scale of the directory it came from, so the caller
    /// knows how much a fixed-size image must be scaled; 0 for unthemed
    /// icons.
    size: u32,
    scale: u32,
    scalable: bool,
};

pub const Options = struct {
    /// Right-to-left: names ending in -rtl (Adwaita's mirrored arrows)
    /// come first.
    rtl: bool = false,
    /// Also try the names' generic fallbacks: `folder-documents-symbolic`
    /// falls back to `folder-symbolic`, as GTK's icon lookup does.
    generic_fallbacks: bool = true,
    style: Style = .default,
};

/// GTK's FORCE_SYMBOLIC and FORCE_REGULAR: which variant of each name to
/// try first.
pub const Style = enum(u8) { default, symbolic, regular };

pub const Themes = struct {
    gpa: std.mem.Allocator,
    mutex: c.pthread_mutex_t = .{},
    /// Directories that hold themes, in order: the application's own
    /// first, then $XDG_DATA_HOME/icons, ~/.icons, $XDG_DATA_DIRS/icons.
    bases: std.ArrayList([]u8) = .empty,
    /// Directories searched for unthemed icons after every theme.
    pixmaps: std.ArrayList([]u8) = .empty,
    themes: std.StringHashMapUnmanaged(*Theme) = .empty,
    /// Unthemed files by name, per pixmap directory, read on first use.
    loose: ?Names = null,

    pub const Environment = struct {
        home: ?[]const u8 = null,
        xdg_data_home: ?[]const u8 = null,
        xdg_data_dirs: ?[]const u8 = null,
        /// Search /usr/share/pixmaps for unthemed icons.
        pixmaps: bool = true,
    };

    /// The process's environment.
    pub fn environment() Environment {
        return .{
            .home = getenv("HOME"),
            .xdg_data_home = getenv("XDG_DATA_HOME"),
            .xdg_data_dirs = getenv("XDG_DATA_DIRS"),
        };
    }

    pub fn init(gpa: std.mem.Allocator, env: Environment) error{OutOfMemory}!Themes {
        var t: Themes = .{ .gpa = gpa };
        errdefer t.deinit();
        if (env.xdg_data_home) |d| {
            if (d.len > 0 and d[0] == '/') try t.addBase(d, "/icons");
        } else if (env.home) |h| try t.addBase(h, "/.local/share/icons");
        if (env.home) |h| try t.addBase(h, "/.icons");
        var it = std.mem.tokenizeScalar(u8, env.xdg_data_dirs orelse "/usr/local/share:/usr/share", ':');
        while (it.next()) |d| if (d[0] == '/') try t.addBase(d, "/icons");
        if (env.pixmaps) try t.pixmaps.append(gpa, try gpa.dupe(u8, "/usr/share/pixmaps"));
        return t;
    }

    fn addBase(t: *Themes, dir: []const u8, suffix: []const u8) error{OutOfMemory}!void {
        const path = try std.mem.concat(t.gpa, u8, &.{ std.mem.trimEnd(u8, dir, "/"), suffix });
        for (t.bases.items) |b| if (std.mem.eql(u8, b, path)) {
            t.gpa.free(path);
            return;
        };
        try t.bases.append(t.gpa, path);
    }

    pub fn deinit(t: *Themes) void {
        var it = t.themes.iterator();
        while (it.next()) |e| e.value_ptr.*.destroy(t.gpa);
        t.themes.deinit(t.gpa);
        for (t.bases.items) |b| t.gpa.free(b);
        t.bases.deinit(t.gpa);
        for (t.pixmaps.items) |p| t.gpa.free(p);
        t.pixmaps.deinit(t.gpa);
        if (t.loose) |*l| l.deinit(t.gpa);
        _ = c.pthread_mutex_destroy(&t.mutex);
    }

    /// Adds a directory searched before the others, both for themes and
    /// for unthemed icons (an application's own icons). Themes already
    /// read are read again.
    pub fn addSearchPath(t: *Themes, dir: []const u8) error{OutOfMemory}!void {
        _ = c.pthread_mutex_lock(&t.mutex);
        defer _ = c.pthread_mutex_unlock(&t.mutex);
        const copy = try t.gpa.dupe(u8, std.mem.trimEnd(u8, dir, "/"));
        errdefer t.gpa.free(copy);
        try t.bases.insert(t.gpa, 0, copy);
        t.forget();
    }

    fn forget(t: *Themes) void {
        var it = t.themes.iterator();
        while (it.next()) |e| e.value_ptr.*.destroy(t.gpa);
        t.themes.clearRetainingCapacity();
        if (t.loose) |*l| l.deinit(t.gpa);
        t.loose = null;
    }

    /// FindIcon for the first of `names` that any theme in the chain has:
    /// `theme`, its parents, then hicolor, each trying every name (and
    /// the names' fallbacks) before the next theme; then unthemed icons.
    /// `size` is in logical pixels at `scale`.
    pub fn lookup(t: *Themes, theme: []const u8, names: []const []const u8, size: u32, scale: u32, options: Options) error{OutOfMemory}!?Found {
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        const candidates = try expand(arena.allocator(), names, options);
        if (candidates.len == 0) return null;
        const sz = std.math.clamp(size, 1, 4096);
        const sc = std.math.clamp(scale, 1, 16);

        _ = c.pthread_mutex_lock(&t.mutex);
        defer _ = c.pthread_mutex_unlock(&t.mutex);
        var visited: std.ArrayList(*Theme) = .empty;
        if (try t.findIn(arena.allocator(), theme, candidates, sz, sc, &visited, 0)) |f| return f;
        if (try t.findIn(arena.allocator(), "hicolor", candidates, sz, sc, &visited, 0)) |f| return f;
        return t.findLoose(candidates);
    }

    fn findIn(t: *Themes, arena: std.mem.Allocator, name: []const u8, candidates: []const []const u8, size: u32, scale: u32, visited: *std.ArrayList(*Theme), depth: u32) error{OutOfMemory}!?Found {
        if (depth > 16) return null;
        const theme = try t.load(name) orelse return null;
        if (std.mem.indexOfScalar(*Theme, visited.items, theme) != null) return null;
        try visited.append(arena, theme);
        for (candidates) |cand| if (try theme.find(t.gpa, cand, size, scale)) |f| return f;
        for (theme.inherits) |parent| {
            if (try t.findIn(arena, parent, candidates, size, scale, visited, depth + 1)) |f| return f;
        }
        return null;
    }

    /// LookupFallbackIcon: files named after the icon directly in a base
    /// directory or a pixmap directory.
    fn findLoose(t: *Themes, candidates: []const []const u8) error{OutOfMemory}!?Found {
        if (t.loose == null) {
            var names: Names = .{};
            errdefer names.deinit(t.gpa);
            for (t.bases.items, 0..) |dir, i| try names.scan(t.gpa, dir, @intCast(i));
            for (t.pixmaps.items, 0..) |dir, i| try names.scan(t.gpa, dir, @intCast(t.bases.items.len + i));
            t.loose = names;
        }
        const loose = &t.loose.?;
        for (candidates) |cand| {
            const hits = loose.map.get(cand) orelse continue;
            const best = hits.items[0];
            const dir = if (best.dir < t.bases.items.len) t.bases.items[best.dir] else t.pixmaps.items[best.dir - t.bases.items.len];
            const path = try std.fmt.allocPrint(t.gpa, "{s}/{s}.{s}", .{ dir, cand, @tagName(best.format) });
            return .{ .path = path, .format = best.format, .size = 0, .scale = 1, .scalable = best.format == .svg };
        }
        return null;
    }

    /// The theme `name`, read on first use, or null if no base directory
    /// has an index.theme for it.
    fn load(t: *Themes, name: []const u8) error{OutOfMemory}!?*Theme {
        if (t.themes.get(name)) |th| return th;
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, "..")) return null;
        const theme = try Theme.read(t.gpa, t.bases.items, name) orelse return null;
        errdefer theme.destroy(t.gpa);
        try t.themes.put(t.gpa, theme.name, theme);
        return theme;
    }

    /// Whether a theme of that name is installed.
    pub fn has(t: *Themes, name: []const u8) error{OutOfMemory}!bool {
        _ = c.pthread_mutex_lock(&t.mutex);
        defer _ = c.pthread_mutex_unlock(&t.mutex);
        return try t.load(name) != null;
    }
};

/// The names to try, in order: with RTL, each name's -rtl variant first;
/// then, with generic fallbacks, each name shortened at its dashes
/// (keeping a -symbolic suffix).
fn expand(arena: std.mem.Allocator, names: []const []const u8, options: Options) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var styled: std.ArrayList([]const u8) = .empty;
    for (names) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (name.len == 0 or name.len > 255 or std.mem.indexOfScalar(u8, name, '/') != null) continue;
        const symbolic = std.mem.endsWith(u8, name, "-symbolic");
        switch (options.style) {
            .default => {},
            .symbolic => if (!symbolic) try styled.append(arena, try std.mem.concat(arena, u8, &.{ name, "-symbolic" })),
            .regular => if (symbolic) try styled.append(arena, name[0 .. name.len - "-symbolic".len]),
        }
        try styled.append(arena, name);
    }
    for (styled.items) |name| {
        const symbolic = std.mem.endsWith(u8, name, "-symbolic");
        const stem = if (symbolic) name[0 .. name.len - "-symbolic".len] else name;
        const suffix = if (symbolic) "-symbolic" else "";
        var cut: usize = stem.len;
        while (true) {
            const base = stem[0..cut];
            if (base.len > 0) {
                if (options.rtl) {
                    try add(arena, &out, try std.mem.concat(arena, u8, &.{ base, "-rtl", suffix }));
                    if (symbolic) try add(arena, &out, try std.mem.concat(arena, u8, &.{ base, suffix, "-rtl" }));
                }
                try add(arena, &out, try std.mem.concat(arena, u8, &.{ base, suffix }));
            }
            if (!options.generic_fallbacks) break;
            cut = std.mem.lastIndexOfScalar(u8, base, '-') orelse break;
        }
    }
    return out.items;
}

fn add(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), name: []const u8) error{OutOfMemory}!void {
    for (out.items) |n| if (std.mem.eql(u8, n, name)) return;
    try out.append(arena, name);
}

/// File names without their extension, each with where it was found.
const Names = struct {
    map: std.StringHashMapUnmanaged(std.ArrayList(Hit)) = .empty,
    /// The names' bytes.
    strings: std.ArrayList([]u8) = .empty,

    const Hit = struct { dir: u32, format: Format };

    fn deinit(n: *Names, gpa: std.mem.Allocator) void {
        var it = n.map.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        n.map.deinit(gpa);
        for (n.strings.items) |s| gpa.free(s);
        n.strings.deinit(gpa);
    }

    /// Records the PNG and SVG files of `path` under directory `dir`.
    /// XPM is not decoded; GTK's `.symbolic.png` encoding is skipped
    /// (its name ends in `.symbolic`), so the SVG of a symbolic icon wins.
    fn scan(n: *Names, gpa: std.mem.Allocator, path: []const u8, dir: u32) error{OutOfMemory}!void {
        var zbuf: [4096]u8 = undefined;
        if (path.len >= zbuf.len) return;
        @memcpy(zbuf[0..path.len], path);
        zbuf[path.len] = 0;
        const rc = linux.open(zbuf[0..path.len :0], .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
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
                if (ent.type == linux.DT.DIR) continue;
                const format: Format = if (std.mem.endsWith(u8, name, ".png"))
                    .png
                else if (std.mem.endsWith(u8, name, ".svg"))
                    .svg
                else
                    continue;
                const stem = name[0 .. name.len - 4];
                if (stem.len == 0) continue;
                const gop = try n.map.getOrPut(gpa, stem);
                if (!gop.found_existing) {
                    const owned = gpa.dupe(u8, stem) catch |e| {
                        n.map.removeByPtr(gop.key_ptr);
                        return e;
                    };
                    n.strings.append(gpa, owned) catch |e| {
                        gpa.free(owned);
                        n.map.removeByPtr(gop.key_ptr);
                        return e;
                    };
                    gop.key_ptr.* = owned;
                    gop.value_ptr.* = .empty;
                }
                // The specification's extension order: PNG before SVG.
                const hits = gop.value_ptr;
                try hits.append(gpa, .{ .dir = dir, .format = format });
                if (format == .png) {
                    var i = hits.items.len - 1;
                    while (i > 0 and hits.items[i - 1].dir == dir and hits.items[i - 1].format == .svg) : (i -= 1)
                        std.mem.swap(Hit, &hits.items[i], &hits.items[i - 1]);
                }
            }
        }
    }
};

const Theme = struct {
    name: []u8,
    arena: std.heap.ArenaAllocator,
    inherits: []const []const u8,
    dirs: []const index.Dir,
    /// Every directory of the theme in every base directory that has it:
    /// `dirs[k]` under base `roots[r]` is directory r * dirs.len + k.
    roots: []const []const u8,
    names: Names,

    fn read(gpa: std.mem.Allocator, bases: []const []const u8, name: []const u8) error{OutOfMemory}!?*Theme {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var roots: std.ArrayList([]const u8) = .empty;
        var idx: ?index.Index = null;
        for (bases) |b| {
            const root = try std.fmt.allocPrint(a, "{s}/{s}", .{ b, name });
            if (!isDir(root)) continue;
            try roots.append(a, root);
            // The first index.theme found describes the theme.
            if (idx == null) {
                const path = try std.fmt.allocPrint(a, "{s}/index.theme", .{root});
                const text = readSmall(a, path) catch continue;
                idx = try index.parse(a, text);
            }
        }
        const parsed = idx orelse {
            arena.deinit();
            return null;
        };
        const t = try gpa.create(Theme);
        errdefer gpa.destroy(t);
        const owned_name = try a.dupe(u8, name);
        t.* = .{ .name = owned_name, .arena = arena, .inherits = parsed.inherits, .dirs = parsed.dirs, .roots = roots.items, .names = .{} };
        errdefer t.names.deinit(gpa);
        for (t.roots, 0..) |root, r| for (t.dirs, 0..) |d, k| {
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, d.path });
            try t.names.scan(gpa, path, @intCast(r * t.dirs.len + k));
        };
        t.arena = arena;
        return t;
    }

    fn destroy(t: *Theme, gpa: std.mem.Allocator) void {
        t.names.deinit(gpa);
        var arena = t.arena;
        gpa.destroy(t);
        arena.deinit();
    }

    /// LookupIcon: a directory that matches the size exactly, in the
    /// theme's directory order, else the closest one.
    fn find(t: *Theme, gpa: std.mem.Allocator, name: []const u8, size: u32, scale: u32) error{OutOfMemory}!?Found {
        const hits = t.names.map.get(name) orelse return null;
        var best: ?Names.Hit = null;
        var best_distance: u64 = std.math.maxInt(u64);
        var exact: ?Names.Hit = null;
        var exact_order: usize = std.math.maxInt(usize);
        for (hits.items) |h| {
            const d = t.dirs[h.dir % t.dirs.len];
            // Directory order first, then base order (r).
            const order = (h.dir % t.dirs.len) * t.roots.len + h.dir / t.dirs.len;
            if (d.matches(size, scale)) {
                if (order < exact_order) {
                    exact = h;
                    exact_order = order;
                }
                continue;
            }
            const dist = d.distance(size, scale);
            if (dist < best_distance) {
                best = h;
                best_distance = dist;
            }
        }
        const h = exact orelse best orelse return null;
        const d = t.dirs[h.dir % t.dirs.len];
        const root = t.roots[h.dir / t.dirs.len];
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}.{s}", .{ root, d.path, name, @tagName(h.format) });
        return .{ .path = path, .format = h.format, .size = d.size, .scale = d.scale, .scalable = d.type == .scalable or h.format == .svg };
    }
};

fn isDir(path: []const u8) bool {
    var zbuf: [4096]u8 = undefined;
    if (path.len >= zbuf.len) return false;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, zbuf[0..path.len :0], 0, .{ .TYPE = true }, &st)) != .SUCCESS) return false;
    return st.mode & linux.S.IFMT == linux.S.IFDIR;
}

/// Reads a small text file (index.theme) whole.
fn readSmall(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var zbuf: [4096]u8 = undefined;
    if (path.len >= zbuf.len) return error.ReadFailed;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const rc = linux.open(zbuf[0..path.len :0], .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (out.items.len < 4 << 20) {
        const r = linux.read(fd, &buf, buf.len);
        switch (linux.errno(r)) {
            .SUCCESS => if (r == 0) break else try out.appendSlice(a, buf[0..r]),
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
    return out.items;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

test {
    std.testing.refAllDecls(@This());
    _ = index;
    _ = @import("tests.zig");
}
