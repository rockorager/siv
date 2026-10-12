//! Fonts for text nodes (D13): the application's font cache, resolution of
//! a style's family to a fallback chain, and loading of pending fonts on
//! the worker pool.
//!
//! The font cache never reads files. Shaping skips pending fonts and lists
//! the ones it wanted; `request` reads them on the pool, and when one is
//! loaded every listening window reshapes the text nodes that wanted fonts.
//! One `Fonts` serves all windows of an application.

const std = @import("std");
const text = @import("text");
const loop = @import("loop");

const FontId = text.FontId;
const Pool = loop.Pool;

const Fonts = @This();

gpa: std.mem.Allocator,
cache: text.FontCache,
/// Fontconfig, if the application provides it; without it only
/// registered families resolve.
database: ?text.fontconfig.Database = null,
pool: ?*Pool = null,
/// Interned family and language names; index 0 is "".
names: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Chains registered by name (fonts added from bytes).
families: std.AutoHashMapUnmanaged(u32, []const FontId) = .empty,
/// Fontconfig results per query, so that reshaping does not sort fonts
/// again. Fonts themselves live only in the cache.
resolved: std.AutoHashMapUnmanaged(Query, []const FontId) = .empty,
default_family: u32 = 0,
loads: std.ArrayList(*Load) = .empty,
listeners: std.ArrayList(Listener) = .empty,
/// Counts finished loads, so text nodes know when to reshape.
serial: u32 = 0,

pub const Query = struct {
    family: u32,
    language: u32,
    weight: text.fontconfig.Weight,
    slant: text.fontconfig.Slant,
};

pub const Listener = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!Fonts {
    var f: Fonts = .{ .gpa = gpa, .cache = .init(gpa) };
    errdefer f.deinit();
    _ = try f.intern("");
    f.default_family = try f.intern("sans-serif");
    return f;
}

/// Loads still in flight finish without touching this object.
pub fn deinit(f: *Fonts) void {
    for (f.loads.items) |load| {
        if (f.pool) |pool| if (pool.cancel(&load.read.job)) {
            load.destroy();
            continue;
        };
        load.fonts = null;
    }
    f.loads.deinit(f.gpa);
    f.listeners.deinit(f.gpa);
    var families = f.families.valueIterator();
    while (families.next()) |c| f.gpa.free(c.*);
    f.families.deinit(f.gpa);
    var resolved = f.resolved.valueIterator();
    while (resolved.next()) |c| f.gpa.free(c.*);
    f.resolved.deinit(f.gpa);
    for (f.names.keys()) |k| f.gpa.free(k);
    f.names.deinit(f.gpa);
    if (f.database) |*db| db.deinit();
    f.cache.deinit();
    f.* = undefined;
}

pub fn intern(f: *Fonts, str: []const u8) error{OutOfMemory}!u32 {
    if (f.names.getIndex(str)) |i| return @intCast(i);
    const owned = try f.gpa.dupe(u8, str);
    errdefer f.gpa.free(owned);
    try f.names.put(f.gpa, owned, {});
    return @intCast(f.names.count() - 1);
}

pub fn name(f: *const Fonts, id: u32) []const u8 {
    return f.names.keys()[id];
}

/// Registers a fallback chain under a family name; it takes precedence
/// over Fontconfig. `chain` is copied.
pub fn register(f: *Fonts, family: []const u8, fonts: []const FontId) error{OutOfMemory}!void {
    const id = try f.intern(family);
    const owned = try f.gpa.dupe(FontId, fonts);
    errdefer f.gpa.free(owned);
    const gop = try f.families.getOrPut(f.gpa, id);
    if (gop.found_existing) f.gpa.free(gop.value_ptr.*);
    gop.value_ptr.* = owned;
}

/// The family used by styles that name none.
pub fn setDefault(f: *Fonts, family: []const u8) error{OutOfMemory}!void {
    f.default_family = try f.intern(family);
}

pub fn addListener(f: *Fonts, listener: Listener) error{OutOfMemory}!void {
    try f.listeners.append(f.gpa, listener);
}

pub fn removeListener(f: *Fonts, ctx: *anyopaque) void {
    for (f.listeners.items, 0..) |l, i| if (l.ctx == ctx) {
        _ = f.listeners.swapRemove(i);
        return;
    };
}

/// The fallback chain for a query: a registered family, else Fontconfig's
/// coverage-trimmed sort, else the default family's chain. May be empty.
pub fn chain(f: *Fonts, query: Query) error{OutOfMemory}![]const FontId {
    var q = query;
    if (q.family == 0) q.family = f.default_family;
    if (f.families.get(q.family)) |c| return c;
    if (f.database) |*db| {
        if (f.resolved.get(q)) |c| return c;
        const lang = f.name(q.language);
        const found = db.candidates(f.gpa, &f.cache, .{
            .family = f.name(q.family),
            .language = if (lang.len == 0) null else lang,
            .weight = q.weight,
            .slant = q.slant,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try f.gpa.alloc(FontId, 0),
        };
        errdefer f.gpa.free(found);
        try f.resolved.put(f.gpa, q, found);
        return found;
    }
    if (q.family != f.default_family) {
        if (f.families.get(f.default_family)) |c| return c;
    }
    return &.{};
}

/// Starts reading pending fonts on the pool. Fonts already loading, ready,
/// or failed are skipped. Without a pool nothing happens.
pub fn request(f: *Fonts, ids: []const FontId) void {
    const pool = f.pool orelse return;
    outer: for (ids) |id| {
        if (f.cache.state(id) != .pending) continue;
        for (f.loads.items) |load| if (load.id == id) continue :outer;
        const src = f.cache.source(id);
        const load = f.gpa.create(Load) catch return;
        const path = f.gpa.dupeSentinel(u8, src.path, 0) catch {
            f.gpa.destroy(load);
            return;
        };
        load.* = .{
            .gpa = f.gpa,
            .fonts = f,
            .id = id,
            .path = path,
            .read = .{ .path = path, .allocator = f.gpa, .on_done = Load.onDone, .max_bytes = 256 << 20 },
        };
        load.read.job.cancel = Load.onCancel;
        f.loads.append(f.gpa, load) catch {
            load.destroy();
            return;
        };
        pool.submit(&load.read.job) catch {
            _ = f.loads.pop();
            load.destroy();
            return;
        };
    }
}

/// Whether any font load is in flight.
pub fn loading(f: *const Fonts) bool {
    return f.loads.items.len != 0;
}

const Load = struct {
    gpa: std.mem.Allocator,
    fonts: ?*Fonts,
    id: FontId,
    path: [:0]u8,
    read: Pool.ReadFile,

    fn destroy(load: *Load) void {
        load.gpa.free(load.path);
        load.gpa.destroy(load);
    }

    fn onDone(read: *Pool.ReadFile) void {
        const load: *Load = @fieldParentPtr("read", read);
        defer load.destroy();
        const f = load.fonts orelse {
            if (read.result) |bytes| load.gpa.free(bytes) else |_| {}
            return;
        };
        for (f.loads.items, 0..) |l, i| if (l == load) {
            _ = f.loads.swapRemove(i);
            break;
        };
        if (read.result) |bytes| {
            // Bytes that do not parse mark the font failed.
            f.cache.load(load.id, bytes, .owned) catch {};
        } else |_| f.cache.fail(load.id);
        f.serial +%= 1;
        for (f.listeners.items) |l| l.func(l.ctx);
    }

    fn onCancel(job: *Pool.Job) void {
        const read: *Pool.ReadFile = @fieldParentPtr("job", job);
        const load: *Load = @fieldParentPtr("read", read);
        if (load.fonts) |f| for (f.loads.items, 0..) |l, i| if (l == load) {
            _ = f.loads.swapRemove(i);
            break;
        };
        load.destroy();
    }
};

test "registered families and the default resolve without Fontconfig" {
    var f = try Fonts.init(std.testing.allocator);
    defer f.deinit();
    const latin = try f.cache.add(text.font.test_fonts.latin, 0, .borrowed);
    const hebrew = try f.cache.add(text.font.test_fonts.hebrew, 0, .borrowed);
    try f.register("Test", &.{ latin, hebrew });
    try f.setDefault("Test");
    const other = try f.intern("Unknown");
    try std.testing.expectEqualSlices(FontId, &.{ latin, hebrew }, try f.chain(.{ .family = 0, .language = 0, .weight = .regular, .slant = .roman }));
    try std.testing.expectEqualSlices(FontId, &.{ latin, hebrew }, try f.chain(.{ .family = other, .language = 0, .weight = .bold, .slant = .roman }));
}

test "pending fonts load on the pool and notify listeners" {
    var lp = try loop.Loop.init(std.heap.smp_allocator);
    defer lp.deinit();
    var pool = Pool.init(&lp, std.testing.allocator, 2);
    defer pool.deinit();
    var f = try Fonts.init(std.testing.allocator);
    defer f.deinit();
    f.pool = &pool;

    var path_buf: [64]u8 = undefined;
    const path = try writeTestFont(&path_buf);
    defer _ = std.os.linux.unlink(path);
    const good = try f.cache.addPending(.{ .path = path }, null);
    const missing = try f.cache.addPending(.{ .path = "/nonexistent/font.ttf" }, null);
    const Count = struct {
        n: usize = 0,
        fn bump(ctx: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.n += 1;
        }
    };
    var count: Count = .{};
    try f.addListener(.{ .ctx = &count, .func = Count.bump });
    f.request(&.{ good, missing, good });
    try std.testing.expectEqual(2, f.loads.items.len);
    while (f.loading()) try lp.dispatch(-1);
    try std.testing.expectEqual(2, count.n);
    try std.testing.expectEqual(text.font.State.ready, f.cache.state(good));
    try std.testing.expectEqual(text.font.State.failed, f.cache.state(missing));
}

/// Writes the Latin test font to a file in /tmp and returns its path.
pub fn writeTestFont(buf: []u8) ![:0]const u8 {
    const linux = std.os.linux;
    const path = try std.fmt.bufPrintSentinel(buf, "/tmp/siv-ui-font-{d}.ttf", .{linux.getpid()}, 0);
    const fd: i32 = @intCast(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600));
    defer _ = linux.close(fd);
    const bytes = text.font.test_fonts.latin;
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
        done += n;
    }
    return path;
}
