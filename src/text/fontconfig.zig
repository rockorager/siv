//! Font discovery with Fontconfig (D13): its configuration (families,
//! aliases, and languages after substitution) and font list, and siv's
//! own matching of them into an ordered fallback chain. Discovery returns
//! pending fonts; reading their files is the caller's job (font.zig).

const std = @import("std");
const fc = @import("fontconfig");
const font = @import("font.zig");
const family = @import("family.zig");

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
};

/// Since Fontconfig 2.17, FcDefaultSubstitute is FcConfigSetDefaultSubstitute
/// with the process's default configuration, which it loads if there is
/// none: every configuration file and cache read a second time, on the
/// UI thread before the first frame (4 ms). Looked up at run time, since
/// older releases lack it (a weak reference does not link against them);
/// their FcDefaultSubstitute uses no configuration.
const SetDefaultSubstitute = *const fn (?*fc.FcConfig, ?*fc.FcPattern) callconv(.c) void;

/// A snapshot of the Fontconfig configuration, and siv's index of its
/// font list. Loading it reads configuration and cache files and walks
/// every font, so create it off the UI thread; queries afterwards are in
/// memory.
pub const Database = struct {
    config: *fc.FcConfig,
    set_default_substitute: ?SetDefaultSubstitute,
    /// The index's memory.
    arena: std.heap.ArenaAllocator,
    /// The faces text can use, in Fontconfig's font list order.
    faces: []const Listed,
    /// Faces by each family name they list (`familyKey`), in list order.
    by_family: std.StringHashMapUnmanaged(std.ArrayList(u32)),

    /// A face of Fontconfig's font list. Its strings and sets belong to the
    /// configuration.
    pub const Listed = struct {
        path: [:0]const u8,
        /// In Fontconfig's encoding (font.Source).
        index: u32,
        /// The key of its first family name, the family it falls back as.
        family: []const u8,
        /// Its styles as Fontconfig reports them, until its data is read:
        /// Fontconfig has the wght and wdth ranges of variable fonts, but
        /// not slnt or ital.
        description: font.Description,
        charset: ?*const fc.FcCharSet,
        langs: ?*const fc.FcLangSet,
    };

    pub fn init(gpa: std.mem.Allocator) !Database {
        const config = fc.FcInitLoadConfigAndFonts() orelse return error.FontconfigInitFailed;
        return initConfig(gpa, config);
    }

    /// A database of `config`, which it takes (and destroys on error).
    pub fn initConfig(gpa: std.mem.Allocator, config: *fc.FcConfig) !Database {
        var self: Database = .{
            .config = config,
            .set_default_substitute = @ptrCast(std.c.dlsym(null, "FcConfigSetDefaultSubstitute")),
            .arena = .init(gpa),
            .faces = &.{},
            .by_family = .empty,
        };
        errdefer self.deinit();
        try self.index();
        return self;
    }

    pub fn deinit(self: *Database) void {
        self.arena.deinit();
        fc.FcConfigDestroy(self.config);
        self.* = undefined;
    }

    fn index(self: *Database) error{OutOfMemory}!void {
        const a = self.arena.allocator();
        const sets = [_]fc.FcSetName{ fc.FcSetSystem, fc.FcSetApplication };
        // Fontconfig lists a variable font as its variable face, its named
        // instances, and its default instance as a static face. siv sets
        // the axes itself (text.family), so only the variable face counts.
        var variable: std.StringHashMapUnmanaged(void) = .empty;
        var key: [4200]u8 = undefined;
        for (sets) |which| for (patterns(fc.FcConfigGetFonts(self.config, which))) |p| {
            if (!boolean(p, fc.FC_VARIABLE)) continue;
            const file = string(p, fc.FC_FILE, 0) orelse continue;
            try variable.put(a, try a.dupe(u8, faceKey(&key, file, integer(p, fc.FC_INDEX) orelse 0) orelse continue), {});
        };
        var faces: std.ArrayList(Listed) = .empty;
        for (sets) |which| for (patterns(fc.FcConfigGetFonts(self.config, which))) |p| {
            const file = string(p, fc.FC_FILE, 0) orelse continue;
            const idx = integer(p, fc.FC_INDEX) orelse 0;
            if (boolean(p, fc.FC_NAMED_INSTANCE)) continue;
            // HarfBuzz reads OpenType only: not Type 1, PCF, or BDF.
            if (string(p, fc.FC_FONTFORMAT, 0)) |format|
                if (!std.mem.eql(u8, format, "TrueType") and !std.mem.eql(u8, format, "CFF")) continue;
            if (!boolean(p, fc.FC_VARIABLE)) if (faceKey(&key, file, idx)) |k| if (variable.contains(k)) continue;
            const first = string(p, fc.FC_FAMILY, 0) orelse continue;
            const i: u32 = @intCast(faces.items.len);
            var charset: ?*fc.FcCharSet = null;
            _ = fc.FcPatternGetCharSet(p, fc.FC_CHARSET, 0, &charset);
            var langs: ?*fc.FcLangSet = null;
            _ = fc.FcPatternGetLangSet(p, fc.FC_LANG, 0, &langs);
            try faces.append(a, .{
                .path = file,
                .index = @bitCast(idx),
                .family = try familyKey(a, first),
                .description = describe(p),
                .charset = charset,
                .langs = langs,
            });
            var n: c_int = 0;
            while (string(p, fc.FC_FAMILY, n)) |name| : (n += 1) {
                const gop = try self.by_family.getOrPut(a, try familyKey(a, name));
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                const list = gop.value_ptr;
                if (list.items.len == 0 or list.items[list.items.len - 1] != i) try list.append(a, i);
            }
        };
        self.faces = faces.items;
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

    /// The pattern Fontconfig would match for `query`, after its
    /// configuration's substitutions: the families to look for, in order,
    /// with their bindings, and the languages. Caller destroys it.
    fn substituted(self: *const Database, allocator: std.mem.Allocator, query: Query) !*fc.FcPattern {
        const pattern = fc.FcPatternCreate() orelse return error.OutOfMemory;
        errdefer fc.FcPatternDestroy(pattern);
        const name = try allocator.dupeSentinel(u8, query.family, 0);
        defer allocator.free(name);
        if (fc.FcPatternAddString(pattern, fc.FC_FAMILY, name.ptr) == 0 or
            fc.FcPatternAddDouble(pattern, fc.FC_WEIGHT, fc.FcWeightFromOpenTypeDouble(query.weight)) == 0 or
            fc.FcPatternAddInteger(pattern, fc.FC_SLANT, query.slant.value()) == 0 or
            fc.FcPatternAddInteger(pattern, fc.FC_WIDTH, query.width.value()) == 0)
            return error.OutOfMemory;
        if (query.language) |language| {
            const z = try allocator.dupeSentinel(u8, language, 0);
            defer allocator.free(z);
            if (fc.FcPatternAddString(pattern, fc.FC_LANG, z.ptr) == 0) return error.OutOfMemory;
        }
        if (fc.FcConfigSubstitute(self.config, pattern, fc.FcMatchPattern) == 0) return error.OutOfMemory;
        if (self.set_default_substitute) |set| set(self.config, pattern) else fc.FcDefaultSubstitute(pattern);
        return pattern;
    }

    /// The fallback chain for `query`, registered in `cache` as pending
    /// fonts (or found there), best match first. Caller owns the slice.
    ///
    /// Families come in Fontconfig's order: those the configuration binds
    /// strongly (the one asked for, and its same-binding aliases), then
    /// for each language the first family that supports it, then the
    /// weakly bound aliases, then the rest. Ties go to the family whose
    /// closest face is closest to the style, then to font list order
    /// (Fontconfig's last tie-break, the font's version, is left out). Each
    /// family's faces are ranked by CSS font matching (text.family), and
    /// as with Fontconfig's trimmed sort, a face joins the chain only if
    /// it covers characters the faces before it do not. Each face is the
    /// instance of the style asked for: from its data once it is ready,
    /// from what Fontconfig says of it while it is pending.
    pub fn candidates(self: *const Database, allocator: std.mem.Allocator, cache: *font.FontCache, query: Query) ![]font.FontId {
        const pattern = try self.substituted(allocator, query);
        defer fc.FcPatternDestroy(pattern);

        var units: std.ArrayList(Unit) = .empty;
        defer units.deinit(allocator);
        var members: std.ArrayList(u32) = .empty;
        defer members.deinit(allocator);
        const claimed = try allocator.alloc(bool, self.faces.len);
        defer allocator.free(claimed);
        @memset(claimed, false);
        var grouping: Grouping = .{ .units = &units, .members = &members, .claimed = claimed, .allocator = allocator };

        // The families the pattern names: strongly bound ones first, so a
        // face listing several of them joins the strongest.
        for ([_]bool{ true, false }) |strong| {
            var n: c_int = 0;
            while (true) : (n += 1) {
                var v: fc.FcValue = undefined;
                var binding: fc.FcValueBinding = undefined;
                if (fc.FcPatternGetWithBinding(pattern, fc.FC_FAMILY, n, &v, &binding) != fc.FcResultMatch) break;
                if (v.type != fc.FcTypeString or (binding != fc.FcValueBindingWeak) != strong) continue;
                const key = try familyKey(allocator, std.mem.span(@as([*:0]const u8, @ptrCast(v.u.s))));
                defer allocator.free(key);
                const list = self.by_family.getPtr(key) orelse continue;
                const pos: u32 = @intCast(n);
                try grouping.add(list.items, if (strong) pos else none, if (strong) none else pos);
            }
        }
        // Every other family, by each face's first family name.
        for (self.faces, 0..) |face, i| if (!claimed[i])
            try grouping.add(self.by_family.getPtr(face.family).?.items, none, none);

        // Languages (FcFontSort): a family's score is its best distance
        // to the pattern's languages, earlier languages first. Once
        // sorted, each face of the first families supporting a language
        // claims one, in order, and those families keep their score; the
        // others rank as supporting none.
        var langs: [32]fc.FcValue = undefined;
        var lang_count: usize = 0;
        while (lang_count < langs.len and fc.FcPatternGet(pattern, fc.FC_LANG, @intCast(lang_count), &langs[lang_count]) == fc.FcResultMatch)
            lang_count += 1;
        const request: family.Request = .{ .weight = query.weight, .width = query.width.percent(), .slant = query.slant };
        for (units.items) |*u| for (members.items[u.start..u.end]) |m| {
            // Ties between families go to the closer style, as in
            // Fontconfig, measured as CSS does.
            const style = family.key(self.faces[m].description, request);
            if (std.mem.order(f32, &style, &u.style) == .lt) u.style = style;
            const have = self.faces[m].langs orelse continue;
            for (langs[0..lang_count], 0..) |want, j|
                u.lang = @min(u.lang, langDistance(want, have) * 1000 + @as(u32, @intCast(j)) * 100);
        };
        std.sort.pdq(Unit, units.items, {}, Unit.lessThan);
        var satisfied: u32 = 0;
        for (units.items) |*u| {
            var claims = false;
            if (u.lang < 2000) for (members.items[u.start..u.end]) |m| {
                const have = self.faces[m].langs orelse continue;
                for (langs[0..lang_count], 0..) |want, j| {
                    const bit = @as(u32, 1) << @intCast(j);
                    if (satisfied & bit == 0 and langDistance(want, have) < 2) {
                        satisfied |= bit;
                        claims = true;
                        break;
                    }
                }
            };
            if (!claims) u.lang = no_language;
        }
        std.sort.pdq(Unit, units.items, {}, Unit.lessThan);

        const covered = fc.FcCharSetCreate() orelse return error.OutOfMemory;
        defer fc.FcCharSetDestroy(covered);
        var descriptions: std.ArrayList(font.Description) = .empty;
        defer descriptions.deinit(allocator);
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(allocator);
        var ids: std.ArrayList(font.FontId) = .empty;
        errdefer ids.deinit(allocator);
        for (units.items) |u| {
            const unit = members.items[u.start..u.end];
            try descriptions.resize(allocator, unit.len);
            try order.resize(allocator, unit.len);
            for (unit, descriptions.items) |m, *d| d.* = self.faces[m].description;
            family.rank(descriptions.items, request, order.items);
            for (order.items) |k| {
                const face = self.faces[unit[k]];
                // Fontconfig skips faces without coverage, too.
                const charset = face.charset orelse continue;
                var adds: fc.FcBool = fc.FcFalse;
                if (fc.FcCharSetMerge(covered, charset, &adds) == fc.FcFalse) return error.OutOfMemory;
                if (ids.items.len != 0 and adds == fc.FcFalse) continue;
                const id = try register(cache, face, descriptions.items[k], request);
                if (std.mem.indexOfScalar(font.FontId, ids.items, id) == null) try ids.append(allocator, id);
            }
        }
        if (ids.items.len == 0) return error.NoFonts;
        return ids.toOwnedSlice(allocator);
    }

    /// No binding of that strength: Fontconfig's 1e99.
    const none = std.math.maxInt(u32);
    const no_language = 10000;

    /// A family's faces in a chain, `members[start..end]`, and its sort
    /// key: Fontconfig's priorities, from strong family binding to font
    /// list order.
    const Unit = struct {
        start: u32,
        end: u32,
        strong: u32,
        weak: u32,
        lang: u32 = 2000,
        /// Its closest face's distance from the style (`family.key`).
        style: [3]f32 = @splat(std.math.inf(f32)),
        order: u32,

        fn lessThan(_: void, a: Unit, b: Unit) bool {
            const ka = [_]u32{ a.strong, a.lang, a.weak };
            const kb = [_]u32{ b.strong, b.lang, b.weak };
            return switch (std.mem.order(u32, &ka, &kb)) {
                .lt => true,
                .gt => false,
                .eq => switch (std.mem.order(f32, &a.style, &b.style)) {
                    .lt => true,
                    .gt => false,
                    .eq => a.order < b.order,
                },
            };
        }
    };

    const Grouping = struct {
        units: *std.ArrayList(Unit),
        members: *std.ArrayList(u32),
        claimed: []bool,
        allocator: std.mem.Allocator,

        /// A unit of the faces of `list` no unit has yet, if any.
        fn add(g: *Grouping, list: []const u32, strong: u32, weak: u32) error{OutOfMemory}!void {
            const start: u32 = @intCast(g.members.items.len);
            for (list) |i| if (!g.claimed[i]) {
                g.claimed[i] = true;
                try g.members.append(g.allocator, i);
            };
            const end: u32 = @intCast(g.members.items.len);
            if (end > start) try g.units.append(g.allocator, .{ .start = start, .end = end, .strong = strong, .weak = weak, .order = g.members.items[start] });
        }
    };

    /// The face in `cache` as the instance `request` asks for: another
    /// instance of it if it is ready, else a pending font that will load
    /// as the instance Fontconfig's description of it suggests.
    fn register(cache: *font.FontCache, face: Listed, description: font.Description, request: family.Request) !font.FontId {
        if (cache.findReady(face.path, face.index)) |ready| {
            const d = cache.face(ready).?.description;
            return cache.instance(ready, family.instanceFor(d, request)) catch |err| switch (err) {
                error.OutOfMemory => err,
                // The font parsed once; an instance of it cannot fail otherwise.
                else => ready,
            };
        }
        return cache.addPending(.{ .path = face.path, .index = face.index, .instance = family.instanceFor(description, request) }, face.charset);
    }

    /// The installed families' names (each font's first, English, family
    /// name), each once, unsorted (D41: font choosers list them). Caller
    /// owns the slice and its strings.
    pub fn families(self: *const Database, allocator: std.mem.Allocator) error{OutOfMemory}![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |s| allocator.free(s);
            out.deinit(allocator);
        }
        const pattern = fc.FcPatternCreate() orelse return error.OutOfMemory;
        defer fc.FcPatternDestroy(pattern);
        const objects = fc.FcObjectSetCreate() orelse return error.OutOfMemory;
        defer fc.FcObjectSetDestroy(objects);
        if (fc.FcObjectSetAdd(objects, fc.FC_FAMILY) == 0) return error.OutOfMemory;
        const set = fc.FcFontList(self.config, pattern, objects) orelse return error.OutOfMemory;
        defer fc.FcFontSetDestroy(set);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        for (set.*.fonts[0..@intCast(@max(set.*.nfont, 0))]) |p| {
            var name: [*c]fc.FcChar8 = null;
            if (fc.FcPatternGetString(p, fc.FC_FAMILY, 0, &name) != fc.FcResultMatch) continue;
            const s = std.mem.span(@as([*:0]const u8, @ptrCast(name)));
            if (s.len == 0 or seen.contains(s)) continue;
            const owned = try allocator.dupe(u8, s);
            out.append(allocator, owned) catch |err| {
                allocator.free(owned);
                return err;
            };
            try seen.put(allocator, owned, {});
        }
        return out.toOwnedSlice(allocator);
    }
};

/// A family name as Fontconfig compares them: ASCII case and spaces
/// ignored.
fn familyKey(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
    const out = try allocator.alloc(u8, name.len - std.mem.count(u8, name, " "));
    var n: usize = 0;
    for (name) |c| if (c != ' ') {
        out[n] = std.ascii.toLower(c);
        n += 1;
    };
    return out;
}

/// A face of a font file, whatever Fontconfig's upper index bits say.
fn faceKey(buf: []u8, file: []const u8, index: c_int) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{d}:{s}", .{ @as(u32, @bitCast(index)) & 0xffff, file }) catch null;
}

/// Fontconfig's distance between a language of a pattern and a face's
/// languages: 0 the same, 1 another territory, 2 another language.
fn langDistance(want: fc.FcValue, have: *const fc.FcLangSet) u32 {
    const result = switch (want.type) {
        fc.FcTypeString => fc.FcLangSetHasLang(have, want.u.s),
        fc.FcTypeLangSet => fc.FcLangSetCompare(want.u.l, have),
        else => return 2,
    };
    return if (result == fc.FcLangEqual) 0 else if (result == fc.FcLangDifferentLang) 2 else 1;
}

/// A face's styles as Fontconfig reports them.
fn describe(p: ?*const fc.FcPattern) font.Description {
    var d: font.Description = .{ .weight = .point(400), .width = .point(100), .italic = .point(0), .slant = .point(0), .opsz = null };
    if (range(p, fc.FC_WEIGHT)) |r| {
        d.weight = .{ .min = cssWeight(r[0]), .default = 0, .max = cssWeight(r[1]) };
        d.weight.default = d.weight.clamp(400);
        d.axes.wght = true;
    } else if (number(p, fc.FC_WEIGHT)) |w| d.weight = .point(cssWeight(w));
    if (range(p, fc.FC_WIDTH)) |r| {
        d.width = .{ .min = @floatCast(r[0]), .default = 0, .max = @floatCast(r[1]) };
        d.width.default = d.width.clamp(100);
        d.axes.wdth = true;
    } else if (number(p, fc.FC_WIDTH)) |w| d.width = .point(@floatCast(w));
    switch (integer(p, fc.FC_SLANT) orelse fc.FC_SLANT_ROMAN) {
        fc.FC_SLANT_ITALIC => d.italic = .point(1),
        fc.FC_SLANT_OBLIQUE => d.slant = .point(family.oblique_angle),
        else => {},
    }
    return d;
}

fn cssWeight(fc_weight: f64) f32 {
    return @floatCast(fc.FcWeightToOpenTypeDouble(fc_weight));
}

fn patterns(set: ?*fc.FcFontSet) []const ?*fc.FcPattern {
    const s = set orelse return &.{};
    if (s.nfont <= 0) return &.{};
    return s.fonts[0..@intCast(s.nfont)];
}

fn string(p: ?*const fc.FcPattern, object: [*:0]const u8, n: c_int) ?[:0]const u8 {
    var s: [*c]fc.FcChar8 = null;
    if (fc.FcPatternGetString(p, object, n, &s) != fc.FcResultMatch or s == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(s)));
}

fn integer(p: ?*const fc.FcPattern, object: [*:0]const u8) ?c_int {
    var i: c_int = 0;
    return if (fc.FcPatternGetInteger(p, object, 0, &i) == fc.FcResultMatch) i else null;
}

fn number(p: ?*const fc.FcPattern, object: [*:0]const u8) ?f64 {
    var d: f64 = 0;
    if (fc.FcPatternGetDouble(p, object, 0, &d) == fc.FcResultMatch) return d;
    return if (integer(p, object)) |i| @floatFromInt(i) else null;
}

fn boolean(p: ?*const fc.FcPattern, object: [*:0]const u8) bool {
    var b: fc.FcBool = fc.FcFalse;
    return fc.FcPatternGetBool(p, object, 0, &b) == fc.FcResultMatch and b != fc.FcFalse;
}

fn range(p: ?*const fc.FcPattern, object: [*:0]const u8) ?[2]f64 {
    var r: ?*fc.FcRange = null;
    if (fc.FcPatternGetRange(p, object, 0, &r) != fc.FcResultMatch) return null;
    var begin: f64 = 0;
    var end: f64 = 0;
    if (fc.FcRangeGetDouble(r, &begin, &end) == fc.FcFalse) return null;
    return .{ begin, end };
}

test "installed families are listed once each" {
    var database = Database.init(std.testing.allocator) catch return error.SkipZigTest;
    defer database.deinit();
    const names = try database.families(std.testing.allocator);
    defer {
        for (names) |n| std.testing.allocator.free(n);
        std.testing.allocator.free(names);
    }
    for (names, 0..) |n, i| {
        try std.testing.expect(n.len > 0);
        for (names[0..i]) |m| try std.testing.expect(!std.mem.eql(u8, n, m));
    }
}

test "generic sans-serif resolves to an ordered fallback chain" {
    var database = Database.init(std.testing.allocator) catch return error.SkipZigTest;
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

const testing = std.testing;

/// A database of siv's test fonts (testdata/) and `rules`, without the
/// system's fonts or configuration.
fn testDatabase(rules: []const u8) !Database {
    const config = fc.FcConfigCreate() orelse return error.OutOfMemory;
    const xml = try std.fmt.allocPrintSentinel(testing.allocator, "<fontconfig>{s}</fontconfig>", .{rules}, 0);
    defer testing.allocator.free(xml);
    errdefer fc.FcConfigDestroy(config);
    if (fc.FcConfigParseAndLoadFromMemory(config, xml.ptr, fc.FcTrue) == fc.FcFalse) return error.InvalidConfig;
    // Files, not the directory, which Fontconfig would want to cache.
    // Tests run from the build root.
    for ([_][*:0]const u8{
        "src/text/testdata/DroidSans.ttf",               "src/text/testdata/DroidSansArabic.ttf",
        "src/text/testdata/DroidSansHebrew-Regular.ttf", "src/text/testdata/SivTest-Regular.ttf",
        "src/text/testdata/SivTest-Bold.ttf",            "src/text/testdata/SivTest-Italic.ttf",
        "src/text/testdata/SivTest-VF.ttf",
    }) |file| if (fc.FcConfigAppFontAddFile(config, file) == fc.FcFalse) return error.TestFontsMissing;
    return Database.initConfig(testing.allocator, config);
}

fn basename(cache: *const font.FontCache, id: font.FontId) []const u8 {
    return std.fs.path.basename(cache.source(id).path);
}

test "chains order families and languages as Fontconfig's trimmed sort does" {
    var db = try testDatabase(
        \\<alias><family>sans-serif</family><prefer><family>SivTest</family><family>Droid Sans</family></prefer></alias>
        \\<alias binding="same"><family>Helvetica</family><accept><family>Droid Sans</family></accept></alias>
    );
    defer db.deinit();
    const queries = [_]Query{
        .{ .family = "sans-serif" },
        .{ .family = "sans-serif", .language = "ar" },
        .{ .family = "sans-serif", .language = "he" },
        // Named families bind strongly: first even without the language.
        .{ .family = "SivTest", .language = "he" },
        .{ .family = "siv test", .language = "ar" },
        .{ .family = "Droid Sans Hebrew", .language = "en" },
        .{ .family = "Helvetica", .language = "he" },
        .{ .family = "Unknown", .language = "en" },
    };
    for (queries) |query| {
        var cache: font.FontCache = .init(testing.allocator);
        defer cache.deinit();
        const ids = try db.candidates(testing.allocator, &cache, query);
        defer testing.allocator.free(ids);
        const pattern = try db.substituted(testing.allocator, query);
        defer fc.FcPatternDestroy(pattern);
        var result: fc.FcResult = undefined;
        const sorted = fc.FcFontSort(db.config, pattern, fc.FcTrue, null, &result) orelse return error.NoFonts;
        defer fc.FcFontSetDestroy(sorted);
        const want = patterns(sorted);
        errdefer std.debug.print("{s} ({?s}): Fontconfig has {d} fonts, siv {d}\n", .{ query.family, query.language, want.len, ids.len });
        try testing.expectEqual(want.len, ids.len);
        for (want, ids) |p, id| try testing.expectEqualStrings(std.fs.path.basename(string(p, fc.FC_FILE, 0).?), basename(&cache, id));
    }
    // Language picks the fallback order: Arabic first for Arabic text,
    // and right after the family asked for.
    var cache: font.FontCache = .init(testing.allocator);
    defer cache.deinit();
    const arabic = try db.candidates(testing.allocator, &cache, .{ .family = "sans-serif", .language = "ar" });
    defer testing.allocator.free(arabic);
    try testing.expectEqualStrings("DroidSansArabic.ttf", basename(&cache, arabic[0]));
    const hebrew = try db.candidates(testing.allocator, &cache, .{ .family = "SivTest", .language = "he" });
    defer testing.allocator.free(hebrew);
    try testing.expectEqualStrings("SivTest-Regular.ttf", basename(&cache, hebrew[0]));
    try testing.expectEqualStrings("DroidSansHebrew-Regular.ttf", basename(&cache, hebrew[1]));
}

test "installed families match styles as CSS does, and load as the instance matched" {
    var db = try testDatabase("");
    defer db.deinit();
    var cache: font.FontCache = .init(testing.allocator);
    defer cache.deinit();
    const s = font.Synthetic;
    const Case = struct { weight: f32, slant: Slant, file: []const u8, synthetic: s = .{} };
    for ([_]Case{
        .{ .weight = 400, .slant = .roman, .file = "SivTest-Regular.ttf" },
        // 400 to 500 look up to 500, then down; 600 looks bolder first.
        .{ .weight = 500, .slant = .roman, .file = "SivTest-Regular.ttf" },
        .{ .weight = 600, .slant = .roman, .file = "SivTest-Bold.ttf" },
        .{ .weight = 300, .slant = .roman, .file = "SivTest-Regular.ttf" },
        // Slant narrows before weight; no bold italic, so the italic is
        // emboldened (Fontconfig's configuration is not asked).
        .{ .weight = 700, .slant = .italic, .file = "SivTest-Italic.ttf", .synthetic = .{ .bold = s.bold_strength } },
        .{ .weight = 400, .slant = .oblique, .file = "SivTest-Italic.ttf" },
    }) |case| {
        const ids = try db.candidates(testing.allocator, &cache, .{ .family = "SivTest", .weight = case.weight, .slant = case.slant });
        defer testing.allocator.free(ids);
        try testing.expectEqualStrings(case.file, basename(&cache, ids[0]));
        try testing.expectEqual(font.State.pending, cache.state(ids[0]));
        try testing.expect(cache.source(ids[0]).instance.synthetic.eql(case.synthetic));
    }
}

test "variable faces: axes from Fontconfig while pending, from the font once read" {
    var db = try testDatabase("");
    defer db.deinit();
    // Fontconfig also lists the default instance as a static face.
    var count: usize = 0;
    for (db.faces) |f| count += @intFromBool(std.mem.endsWith(u8, f.path, "SivTest-VF.ttf"));
    try testing.expectEqual(1, count);

    var cache: font.FontCache = .init(testing.allocator);
    defer cache.deinit();
    const query: Query = .{ .family = "SivTest VF", .weight = 700, .slant = .italic, .width = .condensed };
    const pending = try db.candidates(testing.allocator, &cache, query);
    defer testing.allocator.free(pending);
    // Fontconfig has the wght and wdth ranges but not slnt: until the
    // font is read, the italic is a synthetic oblique.
    try testing.expectEqual(font.Instance{ .wght = 700, .wdth = 75, .synthetic = .{ .slant = font.Synthetic.oblique_slant } }, cache.source(pending[0]).instance);
    try cache.load(pending[0], font.test_fonts.siv_variable, .borrowed);
    const ready = try db.candidates(testing.allocator, &cache, query);
    defer testing.allocator.free(ready);
    try testing.expectEqual(font.Instance{ .wght = 700, .wdth = 75, .slnt = -12 }, cache.instanceOf(ready[0]));
    // Another style of a read font needs no second read.
    const regular = try db.candidates(testing.allocator, &cache, .{ .family = "SivTest VF" });
    defer testing.allocator.free(regular);
    try testing.expectEqual(font.State.ready, cache.state(regular[0]));
    try testing.expect(cache.instanceOf(regular[0]).isDefault());
}
