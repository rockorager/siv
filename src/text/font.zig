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
    pub fn glyphBounds(self: *const Face, glyph: u32, size: f32) ?struct { x: f32, y: f32, width: f32, height: f32 } {
        var extents: hb.hb_glyph_extents_t = undefined;
        if (hb.hb_font_get_glyph_extents(self.font, glyph, &extents) == 0) return null;
        const s = self.scale(size);
        return .{
            .x = @as(f32, @floatFromInt(extents.x_bearing)) * s,
            .y = @as(f32, @floatFromInt(-extents.y_bearing)) * s,
            .width = @as(f32, @floatFromInt(extents.width)) * s,
            .height = @as(f32, @floatFromInt(-extents.height)) * s,
        };
    }

    fn init(bytes: []const u8, index: u32, variations: []const u8) !Face {
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
        hb.hb_font_make_immutable(font);

        var extents: hb.hb_font_extents_t = undefined;
        _ = hb.hb_font_get_h_extents(font, &extents);
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(bytes);
        hasher.update(std.mem.asBytes(&index));
        hasher.update(variations);
        return .{
            .font = font,
            .upem = upem,
            .key = hasher.final(),
            .color = hb.hb_ot_color_has_png(face) != 0 or hb.hb_ot_color_has_layers(face) != 0 or
                hb.hb_ot_color_has_paint(face) != 0 or hb.hb_ot_color_has_svg(face) != 0,
            .ascender = extents.ascender,
            .descender = extents.descender,
            .line_gap = extents.line_gap,
        };
    }

    fn deinit(self: *Face) void {
        hb.hb_font_destroy(self.font);
    }
};

/// Where a pending font's bytes live, for the caller to read.
pub const Source = struct {
    path: []const u8,
    /// Face index in Fontconfig's encoding (upper 16 bits: named instance).
    index: u32 = 0,
    /// Fontconfig variation settings, e.g. "wght=700".
    variations: []const u8 = "",
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
};

pub const FontCache = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator) FontCache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FontCache) void {
        for (self.entries.items) |*entry| self.release(entry);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    fn release(self: *FontCache, entry: *Entry) void {
        if (entry.state == .ready) entry.face.deinit();
        if (entry.ownership == .owned) self.gpa.free(entry.bytes);
        if (entry.charset) |charset| fc.FcCharSetDestroy(charset);
        self.gpa.free(entry.path);
        self.gpa.free(entry.variations);
    }

    /// Adds a font from bytes. On error, owned bytes are freed.
    pub fn add(self: *FontCache, bytes: []const u8, index: u32, ownership: Ownership) !FontId {
        errdefer if (ownership == .owned) self.gpa.free(bytes);
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        const loaded: Face = try .init(bytes, index, "");
        self.entries.appendAssumeCapacity(.{ .state = .ready, .face = loaded, .bytes = bytes, .ownership = ownership, .index = index });
        return @enumFromInt(self.entries.items.len - 1);
    }

    /// Registers a font whose bytes the caller will read later. Registering
    /// the same source again returns the existing id. `charset`, when given,
    /// is copied.
    pub fn addPending(self: *FontCache, src: Source, charset: ?*const fc.FcCharSet) !FontId {
        if (self.find(src)) |id| return id;
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        const path = try self.gpa.dupe(u8, src.path);
        errdefer self.gpa.free(path);
        const variations = try self.gpa.dupe(u8, src.variations);
        errdefer self.gpa.free(variations);
        const copy = if (charset) |c| fc.FcCharSetCopy(@constCast(c)) orelse return error.OutOfMemory else null;
        self.entries.appendAssumeCapacity(.{ .state = .pending, .path = path, .variations = variations, .index = src.index, .charset = copy });
        return @enumFromInt(self.entries.items.len - 1);
    }

    pub fn find(self: *const FontCache, src: Source) ?FontId {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.index == src.index and std.mem.eql(u8, entry.path, src.path) and
                std.mem.eql(u8, entry.variations, src.variations)) return @enumFromInt(i);
        }
        return null;
    }

    /// Supplies the bytes of a pending font. Bytes that do not parse mark the
    /// font failed (and are freed if owned); shaping then skips it for good.
    pub fn load(self: *FontCache, id: FontId, bytes: []const u8, ownership: Ownership) !void {
        const entry = &self.entries.items[@intFromEnum(id)];
        std.debug.assert(entry.state == .pending);
        entry.face = Face.init(bytes, entry.index, entry.variations) catch |err| {
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
        self.entries.items[@intFromEnum(id)].state = .failed;
    }

    pub fn state(self: *const FontCache, id: FontId) State {
        return self.entries.items[@intFromEnum(id)].state;
    }

    pub fn source(self: *const FontCache, id: FontId) Source {
        const entry = &self.entries.items[@intFromEnum(id)];
        return .{ .path = entry.path, .index = entry.index, .variations = entry.variations };
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
