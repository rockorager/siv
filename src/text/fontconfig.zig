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

    /// The CSS weight.
    pub fn css(self: Weight) f32 {
        return switch (self) {
            .thin => 100,
            .light => 300,
            .regular => 400,
            .medium => 500,
            .semibold => 600,
            .bold => 700,
            .black => 900,
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

/// Font width (CSS font-stretch keywords).
pub const Width = enum {
    ultra_condensed,
    extra_condensed,
    condensed,
    semi_condensed,
    normal,
    semi_expanded,
    expanded,
    extra_expanded,
    ultra_expanded,

    /// Percent of normal, as CSS and OS/2 usWidthClass define them.
    pub fn percent(self: Width) f32 {
        return switch (self) {
            .ultra_condensed => 50,
            .extra_condensed => 62.5,
            .condensed => 75,
            .semi_condensed => 87.5,
            .normal => 100,
            .semi_expanded => 112.5,
            .expanded => 125,
            .extra_expanded => 150,
            .ultra_expanded => 200,
        };
    }

    fn value(self: Width) c_int {
        return switch (self) {
            .ultra_condensed => fc.FC_WIDTH_ULTRACONDENSED,
            .extra_condensed => fc.FC_WIDTH_EXTRACONDENSED,
            .condensed => fc.FC_WIDTH_CONDENSED,
            .semi_condensed => fc.FC_WIDTH_SEMICONDENSED,
            .normal => fc.FC_WIDTH_NORMAL,
            .semi_expanded => fc.FC_WIDTH_SEMIEXPANDED,
            .expanded => fc.FC_WIDTH_EXPANDED,
            .extra_expanded => fc.FC_WIDTH_EXTRAEXPANDED,
            .ultra_expanded => fc.FC_WIDTH_ULTRAEXPANDED,
        };
    }
};

pub const Query = struct {
    /// A family name or a generic family such as "sans-serif".
    family: []const u8,
    /// BCP 47 language tag; selects language-appropriate fallbacks (D21).
    language: ?[]const u8 = null,
    /// CSS weight (1..1000).
    weight: f32 = 400,
    slant: Slant = .roman,
    width: Width = .normal,
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

    /// The directories of the configuration files Fontconfig read, each
    /// once, so that a change to them can be followed (D19). Caller owns
    /// the slice and its strings.
    pub fn configDirs(self: *const Database, allocator: std.mem.Allocator) error{OutOfMemory}![][:0]u8 {
        var out: std.ArrayList([:0]u8) = .empty;
        errdefer {
            for (out.items) |d| allocator.free(d);
            out.deinit(allocator);
        }
        const list = fc.FcConfigGetConfigFiles(self.config) orelse return out.toOwnedSlice(allocator);
        defer fc.FcStrListDone(list);
        while (fc.FcStrListNext(list)) |p| {
            const dir = std.fs.path.dirname(std.mem.span(@as([*:0]const u8, @ptrCast(p)))) orelse continue;
            for (out.items) |d| {
                if (std.mem.eql(u8, d, dir)) break;
            } else try out.append(allocator, try allocator.dupeSentinel(u8, dir, 0));
        }
        return out.toOwnedSlice(allocator);
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
            fc.FcPatternAddDouble(pattern, fc.FC_WEIGHT, fc.FcWeightFromOpenTypeDouble(query.weight)) == 0 or
            fc.FcPatternAddInteger(pattern, fc.FC_SLANT, query.slant.value()) == 0 or
            fc.FcPatternAddInteger(pattern, fc.FC_WIDTH, query.width.value()) == 0)
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
            // Fontconfig's synthetic-style rules (90-synthetic.conf) ask
            // for emboldening and a shear when the face lacks the style.
            var synthetic: font.Synthetic = .{};
            var embolden: fc.FcBool = fc.FcFalse;
            if (fc.FcPatternGetBool(prepared, fc.FC_EMBOLDEN, 0, &embolden) == fc.FcResultMatch and embolden != fc.FcFalse)
                synthetic.bold = font.Synthetic.bold_strength;
            var matrix: [*c]fc.FcMatrix = null;
            if (fc.FcPatternGetMatrix(prepared, fc.FC_MATRIX, 0, &matrix) == fc.FcResultMatch and matrix != null and matrix.*.xy != 0)
                synthetic.slant = @floatCast(matrix.*.xy);
            const id = try cache.addPending(.{
                .path = std.mem.span(@as([*:0]const u8, @ptrCast(file))),
                .index = @bitCast(index),
                .variations = if (variations != null) std.mem.span(@as([*:0]const u8, @ptrCast(variations))) else "",
                .synthetic = synthetic,
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

test "Fontconfig's synthetic-style rules reach the pending font" {
    var database = Database.init() catch return error.SkipZigTest;
    defer database.deinit();
    var cache: font.FontCache = .init(std.testing.allocator);
    defer cache.deinit();
    const ids = database.candidates(std.testing.allocator, &cache, .{ .family = "sans-serif", .weight = 700, .slant = .italic }) catch |err| switch (err) {
        error.NoFonts => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(ids);
    // What Fontconfig itself says about its best match.
    const pattern = fc.FcNameParse("sans-serif:bold:italic").?;
    defer fc.FcPatternDestroy(pattern);
    _ = fc.FcConfigSubstitute(database.config, pattern, fc.FcMatchPattern);
    fc.FcDefaultSubstitute(pattern);
    var result: fc.FcResult = undefined;
    const best = fc.FcFontMatch(database.config, pattern, &result) orelse return error.SkipZigTest;
    defer fc.FcPatternDestroy(best);
    var embolden: fc.FcBool = fc.FcFalse;
    _ = fc.FcPatternGetBool(best, fc.FC_EMBOLDEN, 0, &embolden);
    var matrix: [*c]fc.FcMatrix = null;
    const shear: f32 = if (fc.FcPatternGetMatrix(best, fc.FC_MATRIX, 0, &matrix) == fc.FcResultMatch) @floatCast(matrix.*.xy) else 0;
    const synthetic = cache.source(ids[0]).synthetic;
    try std.testing.expectEqual(shear, synthetic.slant);
    try std.testing.expectEqual(embolden != fc.FcFalse, synthetic.bold != 0);
}
