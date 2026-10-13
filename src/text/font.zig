//! Fonts and the font cache, the text engine's only cache (D13).
//!
//! The cache never performs I/O. A font enters either with its bytes
//! (`add`) or as a pending source that Fontconfig discovered (`addPending`).
//! Shaping skips pending fonts and reports which ones it wanted, so the
//! caller can read them on the worker pool, hand the bytes to `load`, and
//! reshape. Fonts are identified by plain indices (D20) that stay valid for
//! the cache's lifetime.

const std = @import("std");
const hb = @import("harfbuzz");
const fc = @import("fontconfig");

pub const FontId = enum(u32) { _ };

/// Who frees font bytes.
pub const Ownership = enum {
    /// The caller keeps the bytes alive for the cache's lifetime.
    borrowed,
    /// Allocated with the cache's allocator; the cache frees them.
    owned,
};

/// Line metrics in pixels at one size. `descent` is positive downward.
pub const Metrics = struct {
    ascent: f32,
    descent: f32,
    line_gap: f32,

    pub fn height(self: Metrics) f32 {
        return self.ascent + self.descent + self.line_gap;
    }

    pub fn max(a: Metrics, b: Metrics) Metrics {
        return .{ .ascent = @max(a.ascent, b.ascent), .descent = @max(a.descent, b.descent), .line_gap = @max(a.line_gap, b.line_gap) };
    }
};

/// Synthetic styles for a family that lacks a weight or slant (D13): baked
/// into the face's HarfBuzz font, so its outlines, advances, and extents
/// carry them wherever the font is drawn (CPU and Vulkan glyph caches,
/// PDF output).
pub const Synthetic = struct {
    /// Extra stroke added around outlines, in ems, horizontally and
    /// vertically; advances grow by the same amount. 0 is none.
    bold: f32 = 0,
    /// Horizontal shear (the tangent of the angle, leaning right). 0 is
    /// none.
    slant: f32 = 0,

    /// FreeType's emboldening strength (FT_GlyphSlot_Embolden), which
    /// Pango and Cairo use for synthetic bold.
    pub const bold_strength: f32 = 1.0 / 24.0;
    /// CSS's default oblique angle, 14 degrees.
    pub const oblique_slant: f32 = 0.24932800284318068;

    pub fn eql(a: Synthetic, b: Synthetic) bool {
        return a.bold == b.bold and a.slant == b.slant;
    }
};

/// Axis values set on a face's HarfBuzz font, on top of its variation
/// string, and synthetic styles: a face instance (`FontCache.instance`).
pub const Instance = struct {
    wght: ?f32 = null,
    wdth: ?f32 = null,
    slnt: ?f32 = null,
    ital: ?f32 = null,
    opsz: ?f32 = null,
    synthetic: Synthetic = .{},

    pub fn eql(a: Instance, b: Instance) bool {
        return a.wght == b.wght and a.wdth == b.wdth and a.slnt == b.slnt and a.ital == b.ital and a.opsz == b.opsz and
            a.synthetic.eql(b.synthetic);
    }

    pub fn isDefault(self: Instance) bool {
        return self.eql(.{});
    }

    fn variations(self: Instance, out: *[5]hb.hb_variation_t) []hb.hb_variation_t {
        var n: usize = 0;
        inline for (.{ "wght", "wdth", "slnt", "ital", "opsz" }) |name| if (@field(self, name)) |v| {
            out[n] = .{ .tag = tag(name), .value = v };
            n += 1;
        };
        return out[0..n];
    }

    fn hash(self: Instance, hasher: *std.hash.Wyhash) void {
        inline for (.{ "wght", "wdth", "slnt", "ital", "opsz" }) |name| {
            const v: f32 = @field(self, name) orelse std.math.nan(f32);
            hasher.update(std.mem.asBytes(&v));
        }
        hasher.update(std.mem.asBytes(&self.synthetic.bold));
        hasher.update(std.mem.asBytes(&self.synthetic.slant));
    }
};

pub fn tag(comptime name: *const [4]u8) u32 {
    return @as(u32, name[0]) << 24 | @as(u32, name[1]) << 16 | @as(u32, name[2]) << 8 | name[3];
}

/// A range of style values a face covers: one value for static faces, the
/// axis range for variable ones.
pub const Axis = struct {
    min: f32,
    default: f32,
    max: f32,

    pub fn point(v: f32) Axis {
        return .{ .min = v, .default = v, .max = v };
    }

    pub fn contains(self: Axis, v: f32) bool {
        return v >= self.min and v <= self.max;
    }

    pub fn clamp(self: Axis, v: f32) f32 {
        return std.math.clamp(v, self.min, self.max);
    }
};

/// What a face's data says about its style (D13), for matching styles
/// within a family.
pub const Description = struct {
    /// CSS weight (OS/2 usWeightClass, or the wght axis).
    weight: Axis,
    /// Width in percent of normal (OS/2 usWidthClass, or the wdth axis).
    width: Axis,
    /// An italic design (OS/2 fsSelection or head macStyle), or the ital
    /// axis.
    italic: Axis,
    /// Slant in degrees, counter-clockwise, so negative leans right (post
    /// italicAngle, or the slnt axis).
    slant: Axis,
    /// The opsz axis of a variable font, in its units (D13 sets it from the
    /// text size in pixels).
    opsz: ?Axis,
    /// Which of the above are variation axes.
    axes: struct { wght: bool = false, wdth: bool = false, ital: bool = false, slnt: bool = false } = .{},

    fn read(font: *hb.hb_font_t) Description {
        const face = hb.hb_font_get_face(font);
        var d: Description = undefined;
        d.axes = .{};
        d.opsz = null;
        inline for (.{ .{ "weight", "wght", hb.HB_STYLE_TAG_WEIGHT }, .{ "width", "wdth", hb.HB_STYLE_TAG_WIDTH }, .{ "italic", "ital", hb.HB_STYLE_TAG_ITALIC }, .{ "slant", "slnt", hb.HB_STYLE_TAG_SLANT_ANGLE } }) |entry| {
            var info: hb.hb_ot_var_axis_info_t = undefined;
            if (hb.hb_ot_var_find_axis_info(face, tag(entry[1]), &info) != 0) {
                @field(d, entry[0]) = .{ .min = info.min_value, .default = info.default_value, .max = info.max_value };
                @field(d.axes, entry[1]) = true;
            } else {
                @field(d, entry[0]) = .point(hb.hb_style_get_value(font, entry[2]));
            }
        }
        var info: hb.hb_ot_var_axis_info_t = undefined;
        if (hb.hb_ot_var_find_axis_info(face, tag("opsz"), &info) != 0)
            d.opsz = .{ .min = info.min_value, .default = info.default_value, .max = info.max_value };
        return d;
    }
};

/// A loaded face. Its HarfBuzz font is at the default scale (font units, y
/// up) and is never mutated after creation, so renderers may draw from it.
pub const Face = struct {
    font: *hb.hb_font_t,
    upem: u32,
    /// Identifies the face's content (bytes, index, variations); equal keys
    /// mean identical glyphs, so glyph caches can key on it across caches.
    key: u64,
    color: bool,
    /// Metrics in font units; `descender` is negative (y up).
    ascender: i32,
    descender: i32,
    line_gap: i32,
    /// The face's styles, read from its data.
    description: Description,
    /// The variation string and instance values it was created with.
    instance: Instance,
    glyph_count: u32,
    /// Ink extents by glyph id, filled on first use (see `glyphBounds`).
    extents: std.atomic.Value(?[*]std.atomic.Value(u64)) = .init(null),

    /// Pixels per font unit at `size` pixels per em.
    pub fn scale(self: *const Face, size: f32) f32 {
        return size / @as(f32, @floatFromInt(self.upem));
    }

    pub fn metrics(self: *const Face, size: f32) Metrics {
        const s = self.scale(size);
        return .{
            .ascent = @as(f32, @floatFromInt(self.ascender)) * s,
            .descent = @as(f32, @floatFromInt(-self.descender)) * s,
            .line_gap = @as(f32, @floatFromInt(self.line_gap)) * s,
        };
    }

    /// Nominal cmap lookup, without shaping.
    pub fn hasCodepoint(self: *const Face, cp: u21) bool {
        var glyph: hb.hb_codepoint_t = 0;
        return hb.hb_font_get_nominal_glyph(self.font, cp, &glyph) != 0;
    }

    /// Ink bounds of a glyph in pixels at `size`, y down, relative to the
    /// glyph origin. Null for glyphs without outlines.
    ///
    /// HarfBuzz computes extents from the outline, applying gvar deltas
    /// for variable fonts, which made it most of the cost of painting
    /// text. Each face remembers them per glyph in font units, packed as
    /// four i16 into an atomic word, so that any thread may fill and read
    /// the table without a lock (racing writers store the same value).
    pub fn glyphBounds(self: *const Face, glyph: u32, size: f32) ?struct { x: f32, y: f32, width: f32, height: f32 } {
        var extents: hb.hb_glyph_extents_t = undefined;
        const table = self.extentsTable();
        const slot = if (table != null and glyph < self.glyph_count) &table.?[glyph] else null;
        const cached = if (slot) |sl| sl.load(.monotonic) else extents_unknown;
        if (cached == extents_none) return null;
        if (cached != extents_unknown) {
            extents = .{
                .x_bearing = @as(i16, @bitCast(@as(u16, @truncate(cached)))),
                .y_bearing = @as(i16, @bitCast(@as(u16, @truncate(cached >> 16)))),
                .width = @as(i16, @bitCast(@as(u16, @truncate(cached >> 32)))),
                .height = @as(i16, @bitCast(@as(u16, @truncate(cached >> 48)))),
            };
        } else if (hb.hb_font_get_glyph_extents(self.font, glyph, &extents) == 0) {
            if (slot) |sl| sl.store(extents_none, .monotonic);
            return null;
        } else if (slot) |sl| {
            if (packExtents(extents)) |packed_| sl.store(packed_, .monotonic);
        }
        const s = self.scale(size);
        return .{
            .x = @as(f32, @floatFromInt(extents.x_bearing)) * s,
            .y = @as(f32, @floatFromInt(-extents.y_bearing)) * s,
            .width = @as(f32, @floatFromInt(extents.width)) * s,
            .height = @as(f32, @floatFromInt(-extents.height)) * s,
        };
    }

    /// The family name in the face's name table: the typographic family
    /// (name ID 16), else the font family (ID 1). Empty if it has none.
    pub fn familyName(self: *const Face, buf: []u8) []const u8 {
        const face = hb.hb_font_get_face(self.font);
        for ([_]hb.hb_ot_name_id_t{ hb.HB_OT_NAME_ID_TYPOGRAPHIC_FAMILY, hb.HB_OT_NAME_ID_FONT_FAMILY }) |id| {
            // English, or the first name there is.
            var len: c_uint = @intCast(buf.len);
            if (hb.hb_ot_name_get_utf8(face, id, null, &len, buf.ptr) != 0) return buf[0..len];
        }
        return "";
    }

    /// The glyph extents table, allocated on first use.
    fn extentsTable(self: *const Face) ?[*]std.atomic.Value(u64) {
        if (self.extents.load(.acquire)) |t| return t;
        const fresh = std.heap.page_allocator.alloc(std.atomic.Value(u64), self.glyph_count) catch return null;
        @memset(fresh, .init(extents_unknown));
        const mutable: *Face = @constCast(self);
        if (mutable.extents.cmpxchgStrong(null, fresh.ptr, .acq_rel, .acquire)) |won| {
            std.heap.page_allocator.free(fresh);
            return won;
        }
        return fresh.ptr;
    }

    fn init(bytes: []const u8, index: u32, variations: []const u8, instance: Instance) !Face {
        if (bytes.len > std.math.maxInt(c_uint)) return error.InvalidFont;
        const blob = hb.hb_blob_create(bytes.ptr, @intCast(bytes.len), hb.HB_MEMORY_MODE_READONLY, null, null) orelse return error.OutOfMemory;
        defer hb.hb_blob_destroy(blob);
        // Fontconfig marks the default instance of a variable font with
        // 0x8000 in the upper 16 bits; HarfBuzz expects 0 there.
        const hb_index = if (index >> 16 == 0x8000) index & 0xffff else index;
        const face = hb.hb_face_create(blob, hb_index) orelse return error.OutOfMemory;
        defer hb.hb_face_destroy(face);
        const upem = hb.hb_face_get_upem(face);
        if (hb.hb_face_get_glyph_count(face) == 0 or upem == 0) return error.InvalidFont;
        const font = hb.hb_font_create(face) orelse return error.OutOfMemory;
        if (font == hb.hb_font_get_empty()) return error.OutOfMemory;
        errdefer hb.hb_font_destroy(font);

        var tokens = std.mem.tokenizeAny(u8, variations, ", ");
        while (tokens.next()) |token| {
            var variation: hb.hb_variation_t = undefined;
            if (hb.hb_variation_from_string(token.ptr, @intCast(token.len), &variation) == 0) return error.InvalidVariations;
            hb.hb_font_set_variation(font, variation.tag, variation.value);
        }
        var extra: [5]hb.hb_variation_t = undefined;
        for (instance.variations(&extra)) |v| hb.hb_font_set_variation(font, v.tag, v.value);
        const description: Description = .read(font);
        const synthetic = instance.synthetic;
        if (synthetic.bold != 0) hb.hb_font_set_synthetic_bold(font, synthetic.bold, synthetic.bold, 0);
        if (synthetic.slant != 0) hb.hb_font_set_synthetic_slant(font, synthetic.slant);
        hb.hb_font_make_immutable(font);

        var extents: hb.hb_font_extents_t = undefined;
        _ = hb.hb_font_get_h_extents(font, &extents);
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(bytes);
        hasher.update(std.mem.asBytes(&index));
        hasher.update(variations);
        instance.hash(&hasher);
        return .{
            .font = font,
            .upem = upem,
            .key = hasher.final(),
            .color = hb.hb_ot_color_has_png(face) != 0 or hb.hb_ot_color_has_layers(face) != 0 or
                hb.hb_ot_color_has_paint(face) != 0 or hb.hb_ot_color_has_svg(face) != 0,
            .ascender = extents.ascender,
            .descender = extents.descender,
            .line_gap = extents.line_gap,
            .description = description,
            .instance = instance,
            .glyph_count = hb.hb_face_get_glyph_count(face),
        };
    }

    fn deinit(self: *Face) void {
        if (self.extents.load(.acquire)) |t| std.heap.page_allocator.free(t[0..self.glyph_count]);
        hb.hb_font_destroy(self.font);
    }
};

/// `Face.extents` entries: not computed yet, and no outline. Neither is a
/// packing of extents that fit in i16 (both have x_bearing -32768).
const extents_unknown: u64 = 0x8000;
const extents_none: u64 = 0x1_8000;

fn packExtents(e: hb.hb_glyph_extents_t) ?u64 {
    const fields = [_]i32{ e.x_bearing, e.y_bearing, e.width, e.height };
    var out: u64 = 0;
    for (fields, 0..) |f, i| {
        if (f <= std.math.minInt(i16) or f > std.math.maxInt(i16)) return null;
        out |= @as(u64, @as(u16, @bitCast(@as(i16, @intCast(f))))) << @intCast(16 * i);
    }
    return out;
}

/// Where a pending font's bytes live, for the caller to read.
pub const Source = struct {
    path: []const u8,
    /// Face index in Fontconfig's encoding (upper 16 bits: named instance).
    index: u32 = 0,
    /// Fontconfig variation settings, e.g. "wght=700".
    variations: []const u8 = "",
    /// Fontconfig's synthetic emboldening and shear (FC_EMBOLDEN and
    /// FC_MATRIX, set by its synthetic-style rules).
    synthetic: Synthetic = .{},
};

pub const State = enum { pending, ready, failed };

const Entry = struct {
    state: State,
    face: Face = undefined,
    bytes: []const u8 = &.{},
    ownership: Ownership = .borrowed,
    /// Owned copies; empty for fonts added from bytes.
    path: []const u8 = "",
    variations: []const u8 = "",
    index: u32 = 0,
    /// Fontconfig's coverage, owned; lets shaping skip pending fonts that
    /// cannot help.
    charset: ?*fc.FcCharSet = null,
    /// Instances: the font whose bytes they share (never an instance).
    base: ?FontId = null,
    instance: Instance = .{},
};

pub const FontCache = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Taken exclusively by the functions that change the cache, which
    /// run on one thread, and shared by other threads while they shape
    /// with it (`lockShared`); that thread reads without it.
    lock: std.c.pthread_rwlock_t = .{},

    pub fn init(gpa: std.mem.Allocator) FontCache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FontCache) void {
        // Shaping on other threads finishes first.
        self.lockExclusive();
        self.unlockExclusive();
        _ = std.c.pthread_rwlock_destroy(&self.lock);
        for (self.entries.items) |*entry| self.release(entry);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Keeps the cache from changing while another thread shapes with it.
    pub fn lockShared(self: *const FontCache) void {
        _ = std.c.pthread_rwlock_rdlock(@constCast(&self.lock));
    }

    pub fn unlockShared(self: *const FontCache) void {
        _ = std.c.pthread_rwlock_unlock(@constCast(&self.lock));
    }

    fn lockExclusive(self: *FontCache) void {
        _ = std.c.pthread_rwlock_wrlock(&self.lock);
    }

    fn unlockExclusive(self: *FontCache) void {
        _ = std.c.pthread_rwlock_unlock(&self.lock);
    }

    fn release(self: *FontCache, entry: *Entry) void {
        if (entry.state == .ready) entry.face.deinit();
        // Instances borrow their base's bytes.
        if (entry.ownership == .owned and entry.base == null) self.gpa.free(entry.bytes);
        if (entry.charset) |charset| fc.FcCharSetDestroy(charset);
        self.gpa.free(entry.path);
        self.gpa.free(entry.variations);
    }

    /// Adds a font from bytes. On error, owned bytes are freed.
    pub fn add(self: *FontCache, bytes: []const u8, index: u32, ownership: Ownership) !FontId {
        errdefer if (ownership == .owned) self.gpa.free(bytes);
        self.lockExclusive();
        defer self.unlockExclusive();
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        const loaded: Face = try .init(bytes, index, "", .{});
        self.entries.appendAssumeCapacity(.{ .state = .ready, .face = loaded, .bytes = bytes, .ownership = ownership, .index = index });
        return @enumFromInt(self.entries.items.len - 1);
    }

    /// The number of faces in font data (a collection has several), 0 if
    /// it is not a font.
    pub fn faceCount(bytes: []const u8) u32 {
        if (bytes.len > std.math.maxInt(c_uint)) return 0;
        const blob = hb.hb_blob_create(bytes.ptr, @intCast(bytes.len), hb.HB_MEMORY_MODE_READONLY, null, null) orelse return 0;
        defer hb.hb_blob_destroy(blob);
        return hb.hb_face_count(blob);
    }

    /// A ready font with other axis values or synthetic styles: `instance`
    /// replaces the font's own (a Fontconfig variation string still
    /// applies beneath it). Sharing the font's bytes, an instance is
    /// created once and found again; the default instance is the font.
    pub fn instance(self: *FontCache, id: FontId, inst: Instance) !FontId {
        const base = self.entries.items[@intFromEnum(id)].base orelse id;
        // A copy: growing the list moves entries.
        const root = self.entries.items[@intFromEnum(base)];
        std.debug.assert(root.state == .ready);
        if (inst.eql(root.instance)) return base;
        for (self.entries.items, 0..) |entry, i| {
            if (entry.base == base and entry.instance.eql(inst)) return @enumFromInt(i);
        }
        self.lockExclusive();
        defer self.unlockExclusive();
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        const variations = try self.gpa.dupe(u8, root.variations);
        errdefer self.gpa.free(variations);
        const loaded: Face = try .init(root.bytes, root.index, variations, inst);
        self.entries.appendAssumeCapacity(.{ .state = .ready, .face = loaded, .bytes = root.bytes, .variations = variations, .index = root.index, .base = base, .instance = inst });
        return @enumFromInt(self.entries.items.len - 1);
    }

    /// The instance values a font was created with.
    pub fn instanceOf(self: *const FontCache, id: FontId) Instance {
        return self.entries.items[@intFromEnum(id)].instance;
    }

    /// Registers a font whose bytes the caller will read later. Registering
    /// the same source again returns the existing id. `charset`, when given,
    /// is copied.
    pub fn addPending(self: *FontCache, src: Source, charset: ?*const fc.FcCharSet) !FontId {
        if (self.find(src)) |id| return id;
        self.lockExclusive();
        defer self.unlockExclusive();
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        const path = try self.gpa.dupe(u8, src.path);
        errdefer self.gpa.free(path);
        const variations = try self.gpa.dupe(u8, src.variations);
        errdefer self.gpa.free(variations);
        const copy = if (charset) |c| fc.FcCharSetCopy(@constCast(c)) orelse return error.OutOfMemory else null;
        self.entries.appendAssumeCapacity(.{ .state = .pending, .path = path, .variations = variations, .index = src.index, .charset = copy, .instance = .{ .synthetic = src.synthetic } });
        return @enumFromInt(self.entries.items.len - 1);
    }

    pub fn find(self: *const FontCache, src: Source) ?FontId {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.base == null and entry.index == src.index and std.mem.eql(u8, entry.path, src.path) and
                std.mem.eql(u8, entry.variations, src.variations) and entry.instance.synthetic.eql(src.synthetic)) return @enumFromInt(i);
        }
        return null;
    }

    /// Supplies the bytes of a pending font. Bytes that do not parse mark the
    /// font failed (and are freed if owned); shaping then skips it for good.
    pub fn load(self: *FontCache, id: FontId, bytes: []const u8, ownership: Ownership) !void {
        self.lockExclusive();
        defer self.unlockExclusive();
        const entry = &self.entries.items[@intFromEnum(id)];
        std.debug.assert(entry.state == .pending);
        entry.face = Face.init(bytes, entry.index, entry.variations, entry.instance) catch |err| {
            if (ownership == .owned) self.gpa.free(bytes);
            if (err == error.OutOfMemory) return err;
            entry.state = .failed;
            return err;
        };
        entry.state = .ready;
        entry.bytes = bytes;
        entry.ownership = ownership;
    }

    /// Marks a pending font as unreadable, so shaping stops asking for it.
    pub fn fail(self: *FontCache, id: FontId) void {
        self.lockExclusive();
        defer self.unlockExclusive();
        self.entries.items[@intFromEnum(id)].state = .failed;
    }

    pub fn state(self: *const FontCache, id: FontId) State {
        return self.entries.items[@intFromEnum(id)].state;
    }

    pub fn source(self: *const FontCache, id: FontId) Source {
        const entry = &self.entries.items[@intFromEnum(id)];
        return .{ .path = entry.path, .index = entry.index, .variations = entry.variations, .synthetic = entry.instance.synthetic };
    }

    /// The face of a ready font.
    pub fn face(self: *const FontCache, id: FontId) ?*const Face {
        const entry = &self.entries.items[@intFromEnum(id)];
        return if (entry.state == .ready) &entry.face else null;
    }

    /// Whether the font may cover `cp`: the cmap of a ready font, Fontconfig's
    /// charset of a pending one (true when unknown), false for failed fonts.
    pub fn mayCover(self: *const FontCache, id: FontId, cp: u21) bool {
        const entry = &self.entries.items[@intFromEnum(id)];
        return switch (entry.state) {
            .ready => entry.face.hasCodepoint(cp),
            .pending => if (entry.charset) |charset| fc.FcCharSetHasChar(charset, cp) != 0 else true,
            .failed => false,
        };
    }

    pub fn count(self: *const FontCache) usize {
        return self.entries.items.len;
    }
};

/// Apache-2.0 fonts for tests and benchmarks (testdata/LICENSE-DroidSans.txt).
/// Not referenced by the library itself.
pub const test_fonts = struct {
    pub const latin = @embedFile("testdata/DroidSans.ttf");
    pub const arabic = @embedFile("testdata/DroidSansArabic.ttf");
    pub const hebrew = @embedFile("testdata/DroidSansHebrew-Regular.ttf");
    /// Generated by testdata/make_test_fonts.py (part of siv, MIT): space,
    /// H, I, O, and n in family "SivTest" (static Regular, Bold, Italic)
    /// and "SivTest VF" (wght 100..900, wdth 75..125, opsz 8..72, slnt
    /// -12..0). The I's advance is 2 side bearings plus a stem: the stem
    /// is 90 units at wght 400 (30 at 100, 156 at 700, 200 at 900); the
    /// side bearing 60 at opsz 14 (80 at 8 and below, 30 at 72).
    pub const siv_regular = @embedFile("testdata/SivTest-Regular.ttf");
    pub const siv_bold = @embedFile("testdata/SivTest-Bold.ttf");
    pub const siv_italic = @embedFile("testdata/SivTest-Italic.ttf");
    pub const siv_variable = @embedFile("testdata/SivTest-VF.ttf");
};

test "faces from bytes, metrics, and coverage" {
    var cache: FontCache = .init(std.testing.allocator);
    defer cache.deinit();
    const latin = try cache.add(test_fonts.latin, 0, .borrowed);
    const arabic = try cache.add(test_fonts.arabic, 0, .borrowed);
    const face = cache.face(latin).?;
    try std.testing.expect(face.hasCodepoint('A') and !face.hasCodepoint(0x0627));
    try std.testing.expect(cache.face(arabic).?.hasCodepoint(0x0627));
    try std.testing.expect(face.key != cache.face(arabic).?.key);
    const m = face.metrics(16);
    try std.testing.expect(m.ascent > 10 and m.ascent < 20 and m.descent > 2 and m.descent < 8);
    const bounds = face.glyphBounds(36, 16).?; // some outline glyph
    try std.testing.expect(bounds.width > 0 and bounds.height > 0);
    // Remembered extents (negative bearings included) match HarfBuzz's.
    for (0..face.glyph_count) |g| {
        var e: hb.hb_glyph_extents_t = undefined;
        const has = hb.hb_font_get_glyph_extents(face.font, @intCast(g), &e) != 0;
        for (0..2) |_| {
            const b = face.glyphBounds(@intCast(g), 1000);
            try std.testing.expectEqual(has, b != null);
            if (b) |v| try std.testing.expectEqual(@as(f32, @floatFromInt(e.x_bearing)) * face.scale(1000), v.x);
            if (b) |v| try std.testing.expectEqual(@as(f32, @floatFromInt(-e.height)) * face.scale(1000), v.height);
        }
    }

    try std.testing.expectError(error.InvalidFont, cache.add("not a font", 0, .borrowed));
}

test "pending fonts load later and dedupe by source" {
    var cache: FontCache = .init(std.testing.allocator);
    defer cache.deinit();
    const id = try cache.addPending(.{ .path = "/fonts/DroidSans.ttf" }, null);
    try std.testing.expectEqual(id, try cache.addPending(.{ .path = "/fonts/DroidSans.ttf" }, null));
    try std.testing.expectEqual(State.pending, cache.state(id));
    try std.testing.expect(cache.face(id) == null and cache.mayCover(id, 'A'));
    try cache.load(id, try std.testing.allocator.dupe(u8, test_fonts.latin), .owned);
    try std.testing.expectEqual(State.ready, cache.state(id));
    try std.testing.expect(!cache.mayCover(id, 0x0627));

    const bad = try cache.addPending(.{ .path = "/fonts/broken.ttf" }, null);
    try std.testing.expectError(error.InvalidFont, cache.load(bad, try std.testing.allocator.dupe(u8, "junk"), .owned));
    try std.testing.expectEqual(State.failed, cache.state(bad));
}
