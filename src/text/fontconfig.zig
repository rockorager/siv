//! Font discovery with Fontconfig (D13): configured families, substitution
//! rules, and the ordered fallback chain. Discovery returns pending fonts;
//! reading their files is the caller's job (font.zig).

const std = @import("std");
const fc = @import("fontconfig");
const font = @import("font.zig");

pub const Weight = enum {
    thin,
    light,
    regular,
    medium,
    semibold,
    bold,
    black,

    fn value(self: Weight) c_int {
        return switch (self) {
            .thin => fc.FC_WEIGHT_THIN,
            .light => fc.FC_WEIGHT_LIGHT,
            .regular => fc.FC_WEIGHT_REGULAR,
            .medium => fc.FC_WEIGHT_MEDIUM,
            .semibold => fc.FC_WEIGHT_SEMIBOLD,
            .bold => fc.FC_WEIGHT_BOLD,
            .black => fc.FC_WEIGHT_BLACK,
        };
    }
};

pub const Slant = enum {
    roman,
    italic,
    oblique,

    fn value(self: Slant) c_int {
        return switch (self) {
            .roman => fc.FC_SLANT_ROMAN,
            .italic => fc.FC_SLANT_ITALIC,
            .oblique => fc.FC_SLANT_OBLIQUE,
        };
    }
};

pub const Query = struct {
    /// A family name or a generic family such as "sans-serif".
    family: []const u8,
    /// BCP 47 language tag; selects language-appropriate fallbacks (D21).
    language: ?[]const u8 = null,
    weight: Weight = .regular,
    slant: Slant = .roman,
    /// Pixel size, for fonts with size-specific designs.
    size: ?f64 = null,
};

/// A snapshot of the Fontconfig configuration and font list. Loading it
/// reads configuration and cache files, so create it off the UI thread;
/// queries afterwards are in memory.
pub const Database = struct {
    config: *fc.FcConfig,

    pub fn init() !Database {
        return .{ .config = fc.FcInitLoadConfigAndFonts() orelse return error.FontconfigInitFailed };
    }

    pub fn deinit(self: *Database) void {
        fc.FcConfigDestroy(self.config);
        self.* = undefined;
    }

    /// Fontconfig's ordered fallback chain for `query`, trimmed to fonts
    /// that add coverage, registered in `cache` as pending fonts (or found
    /// there). The first entry is the best match. Caller owns the slice.
    pub fn candidates(self: *const Database, allocator: std.mem.Allocator, cache: *font.FontCache, query: Query) ![]font.FontId {
        const pattern = fc.FcPatternCreate() orelse return error.OutOfMemory;
        defer fc.FcPatternDestroy(pattern);
        const family = try allocator.dupeSentinel(u8, query.family, 0);
        defer allocator.free(family);
        if (fc.FcPatternAddString(pattern, fc.FC_FAMILY, family.ptr) == 0 or
            fc.FcPatternAddInteger(pattern, fc.FC_WEIGHT, query.weight.value()) == 0 or
            fc.FcPatternAddInteger(pattern, fc.FC_SLANT, query.slant.value()) == 0)
            return error.OutOfMemory;
        if (query.language) |language| {
            const z = try allocator.dupeSentinel(u8, language, 0);
            defer allocator.free(z);
            if (fc.FcPatternAddString(pattern, fc.FC_LANG, z.ptr) == 0) return error.OutOfMemory;
        }
        if (query.size) |size| if (fc.FcPatternAddDouble(pattern, fc.FC_PIXEL_SIZE, size) == 0) return error.OutOfMemory;
        if (fc.FcConfigSubstitute(self.config, pattern, fc.FcMatchPattern) == 0) return error.OutOfMemory;
        fc.FcDefaultSubstitute(pattern);

        var result: fc.FcResult = undefined;
        const sorted = fc.FcFontSort(self.config, pattern, fc.FcTrue, null, &result) orelse return error.NoFonts;
        defer fc.FcFontSetDestroy(sorted);
        if (sorted.*.nfont <= 0) return error.NoFonts;

        var ids: std.ArrayList(font.FontId) = .empty;
        errdefer ids.deinit(allocator);
        for (sorted.*.fonts[0..@intCast(sorted.*.nfont)]) |candidate| {
            const prepared = fc.FcFontRenderPrepare(self.config, pattern, candidate) orelse return error.OutOfMemory;
            defer fc.FcPatternDestroy(prepared);
            var file: [*c]fc.FcChar8 = null;
            var index: c_int = 0;
            if (fc.FcPatternGetString(prepared, fc.FC_FILE, 0, &file) != fc.FcResultMatch) continue;
            _ = fc.FcPatternGetInteger(prepared, fc.FC_INDEX, 0, &index);
            var variations: [*c]fc.FcChar8 = null;
            _ = fc.FcPatternGetString(prepared, fc.FC_FONT_VARIATIONS, 0, &variations);
            var charset: ?*fc.FcCharSet = null;
            _ = fc.FcPatternGetCharSet(prepared, fc.FC_CHARSET, 0, &charset);
            const id = try cache.addPending(.{
                .path = std.mem.span(@as([*:0]const u8, @ptrCast(file))),
                .index = @bitCast(index),
                .variations = if (variations != null) std.mem.span(@as([*:0]const u8, @ptrCast(variations))) else "",
            }, charset);
            if (std.mem.indexOfScalar(font.FontId, ids.items, id) == null) try ids.append(allocator, id);
        }
        return ids.toOwnedSlice(allocator);
    }
};

test "generic sans-serif resolves to an ordered fallback chain" {
    var database = Database.init() catch return error.SkipZigTest;
    defer database.deinit();
    var cache: font.FontCache = .init(std.testing.allocator);
    defer cache.deinit();
    const ids = database.candidates(std.testing.allocator, &cache, .{ .family = "sans-serif", .language = "en" }) catch |err| switch (err) {
        error.NoFonts => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(ids);
    try std.testing.expect(ids.len != 0);
    try std.testing.expectEqual(font.State.pending, cache.state(ids[0]));
    try std.testing.expect(cache.source(ids[0]).path.len != 0);
    try std.testing.expect(cache.mayCover(ids[0], 'A'));
    // Asking again reuses the registered fonts.
    const again = try database.candidates(std.testing.allocator, &cache, .{ .family = "sans-serif", .language = "en" });
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualSlices(font.FontId, ids, again);
}
