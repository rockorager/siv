//! Fonts for text nodes (D13): the application's font cache, families of
//! faces added from bytes with their styles matched per query, resolution
//! of a style's family to a fallback chain, the opsz axis set from the
//! text size, and loading of pending fonts on the worker pool.
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
/// Hyphenation patterns by language, parsed on first use (D13).
hyphenation: text.hyphen.Hyphenation,
/// Interned family and language names; index 0 is "".
names: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Faces registered by family name (fonts added from bytes), in the
/// order they were added.
families: std.AutoHashMapUnmanaged(u32, []const FontId) = .empty,
/// Chains per query without a size: a registered family's faces ranked
/// for the style, or Fontconfig's sort, so that reshaping does not match
/// or sort fonts again. Fonts themselves live only in the cache.
resolved: std.AutoHashMapUnmanaged(Key, []const FontId) = .empty,
/// Chains per query with a size, for chains with variable faces that have
/// an opsz axis; dropped when a font loads, since a pending font in a
/// chain may turn out to have one.
sized: std.AutoHashMapUnmanaged(Key, []const FontId) = .empty,
default_family: u32 = 0,
/// "monospace", and the family it resolves to (`setMonospace`).
monospace: u32 = 0,
monospace_family: u32 = 0,
loads: std.ArrayList(*Load) = .empty,
listeners: std.ArrayList(Listener) = .empty,
/// Counts finished loads, so text nodes know when to reshape.
serial: u32 = 0,
/// The blocks of long texts whose shaping and lines are in memory, in
/// every window (D13).
residency: text.blocks.Residency,

/// What a residency keeps of long texts' blocks: about 30 blocks of
/// 8 KB of Latin text (shaping and lines take 60 times their bytes),
/// several screens of a document beyond those shown.
pub const residency_budget = 16 << 20;

pub const Query = struct {
    family: u32,
    language: u32,
    /// CSS weight (1..1000).
    weight: u16,
    slant: text.fontconfig.Slant,
    width: text.fontconfig.Width = .normal,
    /// Pixels per em: faces with an opsz axis are instanced at it (D13).
    /// 0 leaves opsz at its default.
    size: f32 = 0,
};

/// A query as a map key, with the size in 1/64 px.
const Key = struct {
    family: u32,
    language: u32,
    weight: u16,
    slant: text.fontconfig.Slant,
    width: text.fontconfig.Width,
    size: u32,

    fn of(q: Query) Key {
        const size: u32 = if (q.size > 0 and q.size < 1 << 20) @intFromFloat(@round(q.size * 64)) else 0;
        return .{ .family = q.family, .language = q.language, .weight = q.weight, .slant = q.slant, .width = q.width, .size = size };
    }

    fn pixels(k: Key) f32 {
        return @as(f32, @floatFromInt(k.size)) / 64;
    }
};

pub const Listener = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!Fonts {
    var f: Fonts = .{ .gpa = gpa, .cache = .init(gpa), .hyphenation = .init(gpa), .residency = .init(gpa, residency_budget) };
    errdefer f.deinit();
    _ = try f.intern("");
    f.default_family = try f.intern("sans-serif");
    f.monospace = try f.intern("monospace");
    f.monospace_family = f.monospace;
    // Text without a font shows boxes rather than nothing (D13).
    try f.cache.addLastResort();
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
    f.dropChains(null);
    f.resolved.deinit(f.gpa);
    f.sized.deinit(f.gpa);
    for (f.names.keys()) |k| f.gpa.free(k);
    f.names.deinit(f.gpa);
    if (f.database) |*db| db.deinit();
    f.hyphenation.deinit();
    f.residency.deinit();
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

/// Registers the faces of a family, replacing any it had; it takes
/// precedence over Fontconfig. Queries rank them by style (D13), so faces
/// of one style form a fallback chain in this order. `fonts` is copied.
pub fn register(f: *Fonts, family: []const u8, fonts: []const FontId) error{OutOfMemory}!void {
    const id = try f.intern(family);
    const owned = try f.gpa.dupe(FontId, fonts);
    errdefer f.gpa.free(owned);
    const gop = try f.families.getOrPut(f.gpa, id);
    if (gop.found_existing) f.gpa.free(gop.value_ptr.*);
    gop.value_ptr.* = owned;
    f.dropChains(id);
}

/// Adds font data (copied): each face of a collection joins `family`,
/// or, when `family` is empty, the family its name table gives.
pub fn addFont(f: *Fonts, family: []const u8, bytes: []const u8) error{ OutOfMemory, InvalidFont }!void {
    const count = text.FontCache.faceCount(bytes);
    if (count == 0) return error.InvalidFont;
    for (0..count) |index| {
        // The cache owns each copy, and frees it on failure.
        const id = f.cache.add(try f.gpa.dupe(u8, bytes), @intCast(index), .owned) catch |err|
            return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFont;
        var buf: [256]u8 = undefined;
        const name_ = if (family.len != 0) family else f.cache.face(id).?.familyName(&buf);
        if (name_.len == 0) return error.InvalidFont;
        const key = try f.intern(name_);
        const old: []const FontId = f.families.get(key) orelse &.{};
        const faces = try f.gpa.alloc(FontId, old.len + 1);
        defer f.gpa.free(faces);
        @memcpy(faces[0..old.len], old);
        faces[old.len] = id;
        try f.register(name_, faces);
    }
}

/// Frees cached chains of `family` (every one when null) and every sized
/// chain.
fn dropChains(f: *Fonts, family: ?u32) void {
    var it = f.resolved.iterator();
    while (it.next()) |e| {
        if (family != null and e.key_ptr.family != family.?) continue;
        f.gpa.free(e.value_ptr.*);
        f.resolved.removeByPtr(e.key_ptr);
    }
    var sized = f.sized.valueIterator();
    while (sized.next()) |c| f.gpa.free(c.*);
    f.sized.clearRetainingCapacity();
}

/// The family used by styles that name none.
pub fn setDefault(f: *Fonts, family: []const u8) error{OutOfMemory}!void {
    f.default_family = try f.intern(family);
}

/// The family that styles naming "monospace" get: "monospace" itself,
/// Fontconfig's alias, unless the desktop names one (D19).
pub fn setMonospace(f: *Fonts, family: []const u8) error{OutOfMemory}!void {
    f.monospace_family = try f.intern(family);
}

/// Replaces the Fontconfig snapshot, whose configuration changed (D19):
/// every family resolves again. Text shaped already keeps its fonts
/// until it is shaped again.
pub fn setDatabase(f: *Fonts, database: text.fontconfig.Database) void {
    if (f.database) |*db| db.deinit();
    f.database = database;
    f.dropChains(null);
}

/// Evicts the shaping and lines of long texts' blocks not used since
/// the last frame, under memory pressure (D42); they shape again when
/// shown.
pub fn trim(f: *Fonts) void {
    const budget = f.residency.budget;
    f.residency.budget = 0;
    f.residency.trim();
    f.residency.budget = budget;
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

/// The fallback chain for a query: a registered family's faces ranked by
/// style, else Fontconfig's coverage-trimmed sort, else the default
/// family's faces. Faces with an opsz axis are instanced at the query's
/// size. May be empty. Valid until fonts are added or a font loads.
pub fn chain(f: *Fonts, query: Query) error{OutOfMemory}![]const FontId {
    var q = query;
    if (q.family == 0) q.family = f.default_family;
    if (q.family == f.monospace) q.family = f.monospace_family;
    var key: Key = .of(q);
    if (key.size != 0) if (f.sized.get(key)) |c| return c;
    const size = key.pixels();
    key.size = 0;
    const base = try f.unsized(key);
    if (size == 0) return base;
    const sized = try f.withSize(base, size) orelse return base;
    errdefer f.gpa.free(sized);
    key.size = Key.of(q).size;
    try f.sized.put(f.gpa, key, sized);
    return sized;
}

fn unsized(f: *Fonts, key: Key) error{OutOfMemory}![]const FontId {
    if (f.resolved.get(key)) |c| return c;
    const found = if (f.families.get(key.family)) |faces|
        try f.match(faces, key)
    else if (f.database) |*db| blk: {
        const lang = f.name(key.language);
        break :blk db.candidates(f.gpa, &f.cache, .{
            .family = f.name(key.family),
            .language = if (lang.len == 0) null else lang,
            .weight = @floatFromInt(key.weight),
            .slant = key.slant,
            .width = key.width,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try f.gpa.alloc(FontId, 0),
        };
    } else if (f.families.get(f.default_family)) |faces|
        try f.match(faces, key)
    else
        try f.gpa.alloc(FontId, 0);
    errdefer f.gpa.free(found);
    try f.resolved.put(f.gpa, key, found);
    return found;
}

/// A family's faces best match first, each instanced for the style:
/// variable axes set, synthetic bold or oblique where it lacks the style.
fn match(f: *Fonts, faces: []const FontId, key: Key) error{OutOfMemory}![]FontId {
    const descriptions = try f.gpa.alloc(text.font.Description, faces.len);
    defer f.gpa.free(descriptions);
    for (faces, descriptions) |id, *d| d.* = if (f.cache.face(id)) |face| face.description else .{
        .weight = .point(400),
        .width = .point(100),
        .italic = .point(0),
        .slant = .point(0),
        .opsz = null,
    };
    const order = try f.gpa.alloc(u32, faces.len);
    defer f.gpa.free(order);
    const wanted: text.family.Request = .{ .weight = @floatFromInt(key.weight), .width = key.width.percent(), .slant = key.slant };
    text.family.rank(descriptions, wanted, order);
    const out = try f.gpa.alloc(FontId, faces.len);
    errdefer f.gpa.free(out);
    for (out, order) |*o, i| o.* = if (f.cache.state(faces[i]) == .ready)
        try f.instance(faces[i], text.family.instanceFor(descriptions[i], wanted))
    else
        faces[i];
    return out;
}

fn instance(f: *Fonts, id: FontId, inst: text.font.Instance) error{OutOfMemory}!FontId {
    return f.cache.instance(id, inst) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // The font parsed once; an instance of it cannot fail otherwise.
        else => id,
    };
}

/// `base` with every ready face that has an opsz axis instanced at
/// `size` pixels per em, as CSS's font-optical-sizing does (D13); null if
/// none has one.
fn withSize(f: *Fonts, base: []const FontId, size: f32) error{OutOfMemory}!?[]FontId {
    const any = for (base) |id| {
        const face = f.cache.face(id) orelse continue;
        if (face.description.opsz != null) break true;
    } else false;
    if (!any) return null;
    const out = try f.gpa.dupe(FontId, base);
    errdefer f.gpa.free(out);
    for (out) |*id| {
        const face = f.cache.face(id.*) orelse continue;
        const axis = face.description.opsz orelse continue;
        var inst = f.cache.instanceOf(id.*);
        const v = axis.clamp(size);
        inst.opsz = if (v == axis.default) null else v;
        id.* = try f.instance(id.*, inst);
    }
    return out;
}

/// Whether text in the default family has a font to draw with, ready or
/// still loading: one added, or Fontconfig's. Without one, text draws
/// with the last-resort face (boxes).
pub fn hasFonts(f: *Fonts) error{OutOfMemory}!bool {
    for (try f.chain(.{ .family = 0, .language = 0, .weight = 400, .slant = .roman })) |id| {
        if (f.cache.state(id) != .failed) return true;
    }
    return false;
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
        // A loaded font may have an opsz axis.
        var sized = f.sized.valueIterator();
        while (sized.next()) |c| f.gpa.free(c.*);
        f.sized.clearRetainingCapacity();
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
    try std.testing.expectEqualSlices(FontId, &.{ latin, hebrew }, try f.chain(.{ .family = 0, .language = 0, .weight = 400, .slant = .roman }));
    // Bold from regular faces is synthetic, for every face of the chain.
    const bold = try f.chain(.{ .family = other, .language = 0, .weight = 700, .slant = .roman });
    try std.testing.expectEqual(2, bold.len);
    for (bold, [_]FontId{ latin, hebrew }) |id, base| {
        try std.testing.expect(id != base);
        try std.testing.expectEqual(text.font.Synthetic.bold_strength, f.cache.instanceOf(id).synthetic.bold);
    }
}

test "without fonts, the default family has none; text draws with the last resort" {
    var f = try Fonts.init(std.testing.allocator);
    defer f.deinit();
    try std.testing.expect(f.cache.last_resort != null);
    try std.testing.expect(!try f.hasFonts());
    try f.addFont("", text.font.test_fonts.siv_regular);
    // Added under its own family, not the default one.
    try std.testing.expect(!try f.hasFonts());
    try f.setDefault("SivTest");
    try std.testing.expect(try f.hasFonts());
}

test "added faces form families matched by style" {
    var f = try Fonts.init(std.testing.allocator);
    defer f.deinit();
    const tf = text.font.test_fonts;
    // Names from the fonts' data; the static faces in any order.
    for ([_][]const u8{ tf.siv_italic, tf.siv_regular, tf.siv_bold, tf.siv_variable }) |bytes| try f.addFont("", bytes);
    try std.testing.expectError(error.InvalidFont, f.addFont("X", "not a font"));
    const family = try f.intern("SivTest");
    const vf = try f.intern("SivTest VF");
    const Case = struct { weight: u16, slant: text.fontconfig.Slant, face: []const u8, synthetic: text.font.Synthetic };
    const s = text.font.Synthetic;
    for ([_]Case{
        .{ .weight = 400, .slant = .roman, .face = tf.siv_regular, .synthetic = .{} },
        .{ .weight = 700, .slant = .roman, .face = tf.siv_bold, .synthetic = .{} },
        .{ .weight = 400, .slant = .italic, .face = tf.siv_italic, .synthetic = .{} },
        // No bold italic: the italic, emboldened; no black: bold as it is.
        .{ .weight = 700, .slant = .italic, .face = tf.siv_italic, .synthetic = .{ .bold = s.bold_strength } },
        .{ .weight = 900, .slant = .roman, .face = tf.siv_bold, .synthetic = .{} },
        .{ .weight = 600, .slant = .roman, .face = tf.siv_bold, .synthetic = .{} },
    }) |case| {
        const c = try f.chain(.{ .family = family, .language = 0, .weight = case.weight, .slant = case.slant });
        try std.testing.expectEqual(3, c.len);
        try std.testing.expectEqual(case.face.ptr == tf.siv_italic.ptr, f.cache.face(c[0]).?.description.italic.max == 1);
        try std.testing.expectEqual(@as(f32, if (case.face.ptr == tf.siv_bold.ptr) 700 else 400), f.cache.face(c[0]).?.description.weight.min);
        try std.testing.expect(f.cache.instanceOf(c[0]).synthetic.eql(case.synthetic));
    }

    // The variable face: axes from the style, opsz from the size, cached
    // per size, and the default instance is the face itself.
    const base = (try f.chain(.{ .family = vf, .language = 0, .weight = 400, .slant = .roman }))[0];
    try std.testing.expect(f.cache.instanceOf(base).isDefault());
    const big = (try f.chain(.{ .family = vf, .language = 0, .weight = 700, .slant = .oblique, .width = .condensed, .size = 40 }))[0];
    try std.testing.expectEqual(text.font.Instance{ .wght = 700, .wdth = 75, .slnt = -12, .opsz = 40 }, f.cache.instanceOf(big));
    try std.testing.expectEqual(big, (try f.chain(.{ .family = vf, .language = 0, .weight = 700, .slant = .oblique, .width = .condensed, .size = 40 }))[0]);
    try std.testing.expectEqual(base, (try f.chain(.{ .family = vf, .language = 0, .weight = 400, .slant = .roman, .size = 14 }))[0]);
    try std.testing.expectEqual(text.font.Instance{ .opsz = 8 }, f.cache.instanceOf((try f.chain(.{ .family = vf, .language = 0, .weight = 400, .slant = .roman, .size = 6 }))[0]));
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
