//! Themed icons (D19): the application's icon theme, a cache of icons
//! looked up by name, size, and scale, and their loading on the worker
//! pool. One `Icons` serves all windows of an application, like `Fonts`.
//!
//! `get` answers from the cache or starts a load and returns null; when
//! a load finishes every listener hears of it (windows repaint the nodes
//! that show icons, canvases that drew with missing icons draw again).
//! The lookup (`icon.Themes`, which reads each theme's directories once)
//! and the file's parse or decode run on a worker; SVG icons become
//! vector images (`Image.vector`), PNG icons pixels decoded at the size
//! and scale asked for.

const std = @import("std");
const loop = @import("loop");
const icon = @import("icon");
const svg = @import("svg");
const image_mod = @import("image");
const image_file = @import("image.zig");
const Image = image_file.Image;

const Icons = @This();

gpa: std.mem.Allocator,
pool: ?*loop.Pool = null,
/// Shared with jobs on the workers; it locks itself.
themes: *icon.Themes,
/// The theme the lookups start from; hicolor follows every theme.
theme: std.ArrayList(u8) = .empty,
/// Bumped when the theme or the search path changes, so loads started
/// before are dropped.
serial: u32 = 0,
entries: std.HashMapUnmanaged(Key, Entry, KeyContext, 80) = .empty,
listeners: std.ArrayList(Listener) = .empty,
/// The last directory the application added to the search path, for
/// hosts that look icons up themselves (the tray's IconThemePath).
search_path: std.ArrayList(u8) = .empty,
/// Finished loads, so canvases know whether they drew with all icons.
loaded: u32 = 0,
/// Loads on the pool.
running: u32 = 0,

/// GTK's default theme, used until the desktop or the application names
/// one; hicolor is searched after it anyway.
pub const default_theme = "Adwaita";

pub const Key = struct {
    /// Owned by the entry. Several names, one per line, are fallbacks.
    names: []const u8,
    /// Pixels at scale 1 (logical size, rounded).
    size: u16,
    scale: u8,
    rtl: bool,
    /// Generic fallbacks (names shortened at dashes) are tried too.
    fallbacks: bool = true,
    style: icon.Style = .default,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.names);
        h.update(std.mem.asBytes(&k.size));
        h.update(&.{ k.scale, @intFromBool(k.rtl), @intFromBool(k.fallbacks), @intFromEnum(k.style) });
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.size == b.size and a.scale == b.scale and a.rtl == b.rtl and a.fallbacks == b.fallbacks and a.style == b.style and std.mem.eql(u8, a.names, b.names);
    }
};

const Entry = union(enum) {
    loading,
    ready: *Image,
    /// No theme has it, or its file failed to load.
    missing,
};

pub const Listener = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

/// The process's environment, for `init`.
pub const environment = icon.Themes.environment;

pub fn init(gpa: std.mem.Allocator, env: icon.Themes.Environment) error{OutOfMemory}!Icons {
    const themes = try gpa.create(icon.Themes);
    errdefer gpa.destroy(themes);
    themes.* = try .init(gpa, env);
    var icons: Icons = .{ .gpa = gpa, .themes = themes };
    try icons.theme.appendSlice(gpa, default_theme);
    return icons;
}

/// Loads still running finish into nothing; the pool must be gone first
/// (they hold `themes`).
pub fn deinit(icons: *Icons) void {
    icons.clear();
    icons.entries.deinit(icons.gpa);
    icons.theme.deinit(icons.gpa);
    icons.search_path.deinit(icons.gpa);
    icons.listeners.deinit(icons.gpa);
    icons.themes.deinit();
    icons.gpa.destroy(icons.themes);
}

fn clear(icons: *Icons) void {
    var it = icons.entries.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .ready) e.value_ptr.ready.release();
        icons.gpa.free(e.key_ptr.names);
    }
    icons.entries.clearRetainingCapacity();
}

pub fn addListener(icons: *Icons, l: Listener) error{OutOfMemory}!void {
    try icons.listeners.append(icons.gpa, l);
}

pub fn removeListener(icons: *Icons, ctx: *anyopaque) void {
    var i: usize = 0;
    while (i < icons.listeners.items.len) {
        if (icons.listeners.items[i].ctx == ctx) _ = icons.listeners.orderedRemove(i) else i += 1;
    }
}

fn notify(icons: *Icons) void {
    for (icons.listeners.items) |l| l.func(l.ctx);
}

pub fn themeName(icons: *const Icons) []const u8 {
    return icons.theme.items;
}

/// Follows another theme: every icon is looked up again.
pub fn setTheme(icons: *Icons, name: []const u8) error{OutOfMemory}!void {
    const n = if (name.len == 0) default_theme else name;
    if (std.mem.eql(u8, n, icons.theme.items)) return;
    icons.theme.clearRetainingCapacity();
    try icons.theme.appendSlice(icons.gpa, n);
    icons.invalidate();
}

/// Searches `dir` first, for themes and unthemed icons.
pub fn addSearchPath(icons: *Icons, dir: []const u8) error{OutOfMemory}!void {
    try icons.search_path.ensureTotalCapacity(icons.gpa, dir.len);
    try icons.themes.addSearchPath(dir);
    icons.search_path.clearRetainingCapacity();
    icons.search_path.appendSliceAssumeCapacity(dir);
    icons.invalidate();
}

fn invalidate(icons: *Icons) void {
    icons.serial +%= 1;
    icons.clear();
    icons.notify();
}

/// The icon if it is loaded (the cache holds the reference; take one to
/// keep it), else null: a load starts unless one is running or the icon
/// is known to be missing. `size` is logical pixels at `scale`.
pub fn get(icons: *Icons, names: []const u8, size: f32, scale: f32, rtl: bool) ?*Image {
    const key = keyOf(names, size, scale, rtl) orelse return null;
    if (icons.entries.get(key)) |e| return switch (e) {
        .ready => |img| img,
        .loading, .missing => null,
    };
    icons.start(key) catch {};
    return null;
}

/// Whether `get` with these arguments would wait for a load.
pub fn pending(icons: *const Icons, names: []const u8, size: f32, scale: f32, rtl: bool) bool {
    const key = keyOf(names, size, scale, rtl) orelse return false;
    const e = icons.entries.get(key) orelse return true;
    return e == .loading;
}

fn keyOf(names: []const u8, size: f32, scale: f32, rtl: bool) ?Key {
    if (names.len == 0 or !(size > 0) or !(scale > 0)) return null;
    return .{
        .names = names,
        .size = @intFromFloat(@min(@round(size), 4096)),
        .scale = @intFromFloat(@min(@max(@ceil(scale - 0.01), 1), 16)),
        .rtl = rtl,
    };
}

fn start(icons: *Icons, key: Key) error{OutOfMemory}!void {
    const pool = icons.pool orelse return;
    var k = key;
    k.names = try icons.gpa.dupe(u8, key.names);
    errdefer icons.gpa.free(k.names);
    try icons.entries.put(icons.gpa, k, .loading);
    errdefer _ = icons.entries.remove(k);
    const l = try icons.gpa.create(Load);
    errdefer icons.gpa.destroy(l);
    const theme = try icons.gpa.dupe(u8, icons.theme.items);
    errdefer icons.gpa.free(theme);
    l.* = .{ .icons = icons, .key = k, .theme = theme, .serial = icons.serial, .cache = true };
    pool.submit(&l.job) catch return error.OutOfMemory;
    icons.running += 1;
}

/// Whether loads are running (tests wait for them).
pub fn loading(icons: *const Icons) bool {
    return icons.running != 0;
}

/// How `request` looks an icon up.
pub const Lookup = struct {
    rtl: bool = false,
    fallbacks: bool = true,
    style: icon.Style = .default,
};

/// Receives a requested icon in the loop's dispatch phase: a reference
/// the callee owns, or null when no theme has it. `destroy` runs after
/// it, or alone when the loop goes away first (D5).
pub const Done = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, image: ?*Image) void,
    destroy: ?*const fn (ctx: ?*anyopaque) void = null,
};

/// Loads an icon for a caller of its own, through the cache: one already
/// loaded is delivered at the next dispatch, never inside this call.
pub fn request(icons: *Icons, names: []const u8, size: f32, scale: f32, options: Lookup, done: Done) error{OutOfMemory}!void {
    const pool = icons.pool orelse return error.OutOfMemory;
    var key = keyOf(names, size, scale, options.rtl) orelse return error.OutOfMemory;
    key.fallbacks = options.fallbacks;
    key.style = options.style;
    const l = try icons.gpa.create(Load);
    errdefer icons.gpa.destroy(l);
    const k_names = try icons.gpa.dupe(u8, names);
    errdefer icons.gpa.free(k_names);
    const theme = try icons.gpa.dupe(u8, icons.theme.items);
    errdefer icons.gpa.free(theme);
    var k = key;
    k.names = k_names;
    l.* = .{ .icons = icons, .key = k, .theme = theme, .serial = icons.serial, .client = done, .owns_names = true };
    if (icons.entries.get(key)) |e| switch (e) {
        .ready => |img| l.cached = img.retain(),
        .missing => l.known_missing = true,
        .loading => {},
    };
    pool.submit(&l.job) catch {
        if (l.cached) |img| img.release();
        return error.OutOfMemory;
    };
    icons.running += 1;
}

/// Loads the icon a key names, the way `get` does, but on the calling
/// thread (tests, and output without a loop such as printing).
pub fn loadNow(icons: *Icons, names: []const u8, size: f32, scale: f32, rtl: bool) error{OutOfMemory}!?*Image {
    const key = keyOf(names, size, scale, rtl) orelse return null;
    if (icons.entries.get(key)) |e| switch (e) {
        .ready => |img| return img,
        .missing => return null,
        .loading => {},
    };
    const result = try resolve(icons.gpa, icons.themes, icons.theme.items, key);
    var k = key;
    k.names = try icons.gpa.dupe(u8, key.names);
    errdefer icons.gpa.free(k.names);
    const gop = try icons.entries.getOrPut(icons.gpa, k);
    if (gop.found_existing) {
        icons.gpa.free(k.names);
        if (gop.value_ptr.* == .ready) gop.value_ptr.ready.release();
    }
    gop.value_ptr.* = if (result) |img| .{ .ready = img } else .missing;
    return result;
}

const Load = struct {
    // The blocking lane (D6): a theme's first lookup reads its
    // directories, then the file is read; parsing an icon is small.
    job: loop.Pool.Job = .{ .run = run, .done = done, .cancel = cancel, .class = .blocking },
    icons: *Icons,
    key: Key,
    theme: []u8,
    serial: u32,
    /// Fills the cache entry made for it (`get`).
    cache: bool = false,
    /// Delivers to a caller (`request`).
    client: ?Done = null,
    /// The key's names are the load's own (`request`), not an entry's.
    owns_names: bool = false,
    /// Already loaded when requested.
    cached: ?*Image = null,
    known_missing: bool = false,
    /// One reference, the load's.
    result: error{OutOfMemory}!?*Image = null,

    fn run(job: *loop.Pool.Job) void {
        const l: *Load = @fieldParentPtr("job", job);
        if (l.cached != null or l.known_missing) {
            l.result = l.cached;
            return;
        }
        l.result = resolve(l.icons.gpa, l.icons.themes, l.theme, l.key);
    }

    fn done(job: *loop.Pool.Job) void {
        const l: *Load = @fieldParentPtr("job", job);
        const icons = l.icons;
        const result = l.result catch null;
        const client = l.client;
        // Otherwise the theme changed meanwhile: the entry and its key are
        // gone.
        const fills = l.cache and l.serial == icons.serial;
        if (fills) {
            if (icons.entries.getPtr(l.key)) |e| e.* = if (result) |img| .{ .ready = img.retain() } else .missing;
            icons.loaded +%= 1;
        }
        l.free();
        if (client) |c| c.func(c.ctx, if (result) |img| img.retain() else null);
        if (result) |img| img.release();
        if (fills) icons.notify();
        if (client) |c| if (c.destroy) |d| d(c.ctx);
    }

    fn cancel(job: *loop.Pool.Job) void {
        const l: *Load = @fieldParentPtr("job", job);
        if (l.result) |r| if (r) |img| img.release() else {} else |_| {}
        const client = l.client;
        l.free();
        if (client) |c| if (c.destroy) |d| d(c.ctx);
    }

    /// The load's memory; a cached load's key names belong to its entry.
    fn free(l: *Load) void {
        const gpa = l.icons.gpa;
        l.icons.running -= 1;
        if (l.owns_names) gpa.free(l.key.names);
        gpa.free(l.theme);
        gpa.destroy(l);
    }
};

/// Finds and loads an icon: null when no theme has it or its file does
/// not load (an unreadable or damaged file is as good as missing).
fn resolve(gpa: std.mem.Allocator, themes: *icon.Themes, theme: []const u8, key: Key) error{OutOfMemory}!?*Image {
    var names: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, key.names, '\n');
    while (it.next()) |name| {
        if (n == names.len) break;
        names[n] = name;
        n += 1;
    }
    const found = try themes.lookup(theme, names[0..n], key.size, key.scale, .{ .rtl = key.rtl, .generic_fallbacks = key.fallbacks, .style = key.style }) orelse return null;
    defer gpa.free(found.path);
    return loadFile(gpa, found, key) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn loadFile(gpa: std.mem.Allocator, found: icon.Found, key: Key) !*Image {
    const bytes = try image_file.readFile(gpa, found.path);
    defer gpa.free(bytes);
    const size: f32 = @floatFromInt(key.size);
    switch (found.format) {
        .svg => {
            const base = found.path[if (std.mem.lastIndexOfScalar(u8, found.path, '/')) |i| i + 1 else 0..];
            const stem = base[0 .. base.len - ".svg".len];
            const doc = try svg.parse(gpa, bytes, .{ .symbolic = std.mem.endsWith(u8, stem, "-symbolic") });
            errdefer doc.deinit();
            return Image.fromVector(gpa, doc, size, size);
        },
        .png => {
            const px: u32 = @as(u32, key.size) * key.scale;
            // Fixed-size icons decode at most at the size shown; smaller
            // ones are stretched by drawing, their logical size still the
            // size asked for.
            const d = try image_mod.decode(gpa, bytes, .{ .max_width = px, .max_height = px, .first_frame = true });
            const w: f32 = @floatFromInt(@max(d.width, d.height));
            return Image.fromDecoded(gpa, d, w / size);
        },
    }
}

test "icons load on the pool, are cached, and follow the theme" {
    const gpa = std.testing.allocator;
    var lp = try loop.Loop.init(gpa);
    defer lp.deinit();
    var pool: loop.Pool = .init(&lp, gpa, 2);
    var icons = try Icons.init(gpa, .{ .xdg_data_dirs = "/nonexistent" });
    defer icons.deinit();
    defer pool.deinit();
    icons.pool = &pool;
    try icons.addSearchPath("test/icons/themes");
    try icons.setTheme("SivTest");
    const Count = struct {
        n: u32 = 0,
        fn bump(ctx: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.n += 1;
        }
    };
    var count: Count = .{};
    try icons.addListener(.{ .ctx = &count, .func = Count.bump });

    try std.testing.expect(icons.get("edit-copy-symbolic", 16, 1, false) == null);
    try std.testing.expect(icons.pending("edit-copy-symbolic", 16, 1, false));
    // A second request while loading starts nothing new.
    try std.testing.expect(icons.get("edit-copy-symbolic", 16, 1, false) == null);
    try std.testing.expect(icons.get("document-new", 16, 2, false) == null);
    try std.testing.expect(icons.get("no-such-icon", 16, 1, false) == null);
    while (count.n < 3) try lp.dispatch(-1);

    const copy = icons.get("edit-copy-symbolic", 16, 1, false).?;
    try std.testing.expect(copy.vector.?.recolors);
    try std.testing.expectEqual([2]f32{ 16, 16 }, copy.logicalSize());
    // The scale-2 PNG: 32 pixels, 16 logical.
    const page = icons.get("document-new", 16, 2, false).?;
    try std.testing.expectEqual(@as(u32, 32), page.width);
    try std.testing.expectEqual([2]f32{ 16, 16 }, page.logicalSize());
    try std.testing.expect(!icons.pending("no-such-icon", 16, 1, false));
    try std.testing.expect(icons.get("no-such-icon", 16, 1, false) == null);

    // A new theme drops the cache and tells the listeners.
    const before = count.n;
    try icons.setTheme("SivColor");
    try std.testing.expectEqual(before + 1, count.n);
    try std.testing.expect(icons.get("edit-copy", 16, 1, false) == null);
    while (icons.pending("edit-copy", 16, 1, false)) try lp.dispatch(-1);
    try std.testing.expect(icons.get("edit-copy", 16, 1, false).?.vector != null);
    // Requests deliver through the cache, never inside the call.
    const Got = struct {
        img: ?*Image = null,
        calls: u32 = 0,
        destroyed: bool = false,
        fn func(ctx: ?*anyopaque, img: ?*Image) void {
            const g: *@This() = @ptrCast(@alignCast(ctx));
            g.img = img;
            g.calls += 1;
        }
        fn destroy(ctx: ?*anyopaque) void {
            const g: *@This() = @ptrCast(@alignCast(ctx));
            g.destroyed = true;
        }
    };
    var got: Got = .{};
    try icons.request("edit-copy", 16, 1, .{}, .{ .ctx = &got, .func = Got.func, .destroy = Got.destroy });
    try std.testing.expectEqual(@as(u32, 0), got.calls);
    while (!got.destroyed) try lp.dispatch(-1);
    try std.testing.expectEqual(icons.get("edit-copy", 16, 1, false).?, got.img.?);
    got.img.?.release();
    var none: Got = .{};
    try icons.request("no-such-icon", 16, 1, .{}, .{ .ctx = &none, .func = Got.func, .destroy = Got.destroy });
    while (!none.destroyed) try lp.dispatch(-1);
    try std.testing.expect(none.calls == 1 and none.img == null);
    // Synchronous loads share the cache.
    const app = (try icons.loadNow("siv-test-app", 48, 1, false)).?;
    try std.testing.expect(app.vector == null);
    try std.testing.expectEqual(app, icons.get("siv-test-app", 48, 1, false).?);
}
