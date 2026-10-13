//! Hyphenation (D13): Frank Liang's algorithm over TeX hyphenation
//! patterns. The built-in patterns are the hyph-utf8 files whose licences
//! are MIT, BSD, or permissive alike (hyphenation/README.md); each is
//! parsed the first time text in its language is hyphenated, and
//! applications can add patterns for other languages.

const std = @import("std");
const uucode = @import("uucode");

const Allocator = std.mem.Allocator;

pub const Hyphenator = struct {
    arena: std.heap.ArenaAllocator,
    /// Pattern letters (lowercase UTF-8, '.' marking a word edge) to the
    /// value at each gap: one per code point, plus one.
    patterns: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Lowercase words to the code point indices they break before.
    exceptions: std.StringHashMapUnmanaged([]const u32) = .empty,
    /// Code points kept together at a word's start and end.
    left_min: u8,
    right_min: u8,
    /// The longest pattern, in code points.
    max_len: u32 = 0,

    /// Parses TeX patterns (whitespace-separated, such as `.ab4c`) and
    /// exceptions (such as `as-so-ciate`). Nothing is kept from the
    /// inputs.
    pub fn init(gpa: Allocator, patterns: []const u8, exceptions: []const u8, left_min: u8, right_min: u8) error{ OutOfMemory, InvalidPatterns }!Hyphenator {
        var h: Hyphenator = .{ .arena = .init(gpa), .left_min = @max(1, left_min), .right_min = @max(1, right_min) };
        errdefer h.arena.deinit();
        const a = h.arena.allocator();
        if (!std.unicode.utf8ValidateSlice(patterns) or !std.unicode.utf8ValidateSlice(exceptions)) return error.InvalidPatterns;
        var it = std.mem.tokenizeAny(u8, patterns, " \t\r\n");
        var letters: std.ArrayList(u8) = .empty;
        var values: std.ArrayList(u8) = .empty;
        while (it.next()) |tok| {
            if (tok[0] == '%') {
                // A comment runs to the end of its line.
                while (it.index < patterns.len and patterns[it.index] != '\n') it.index += 1;
                continue;
            }
            letters.clearRetainingCapacity();
            values.clearRetainingCapacity();
            try values.append(a, 0);
            var view = std.unicode.Utf8View.initUnchecked(tok).iterator();
            while (view.nextCodepoint()) |cp| {
                if (cp >= '0' and cp <= '9') {
                    values.items[values.items.len - 1] = @intCast(cp - '0');
                } else {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(lower(cp), &buf) catch return error.InvalidPatterns;
                    try letters.appendSlice(a, buf[0..n]);
                    try values.append(a, 0);
                }
            }
            if (letters.items.len == 0) return error.InvalidPatterns;
            const gop = try h.patterns.getOrPut(a, try a.dupe(u8, letters.items));
            gop.value_ptr.* = try a.dupe(u8, values.items);
            h.max_len = @max(h.max_len, @as(u32, @intCast(values.items.len - 1)));
        }
        var ex = std.mem.tokenizeAny(u8, exceptions, " \t\r\n");
        while (ex.next()) |tok| {
            if (tok[0] == '%') {
                while (ex.index < exceptions.len and exceptions[ex.index] != '\n') ex.index += 1;
                continue;
            }
            letters.clearRetainingCapacity();
            var breaks: std.ArrayList(u32) = .empty;
            var count: u32 = 0;
            var view = std.unicode.Utf8View.initUnchecked(tok).iterator();
            while (view.nextCodepoint()) |cp| {
                if (cp == '-') {
                    try breaks.append(a, count);
                    continue;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(lower(cp), &buf) catch return error.InvalidPatterns;
                try letters.appendSlice(a, buf[0..n]);
                count += 1;
            }
            try h.exceptions.put(a, try a.dupe(u8, letters.items), breaks.items);
        }
        return h;
    }

    pub fn deinit(h: *Hyphenator) void {
        h.arena.deinit();
        h.* = undefined;
    }

    /// Appends the byte offsets in `word` (letters only) before which it
    /// may break, in increasing order. `scratch` holds intermediates.
    pub fn points(h: *const Hyphenator, scratch: Allocator, word: []const u8, out: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!void {
        // The word lowercased between dots, and where each code point
        // starts in it and in the word.
        var dotted: std.ArrayList(u8) = .empty;
        var starts: std.ArrayList(u32) = .empty; // in dotted, per code point, plus the end
        var origin: std.ArrayList(u32) = .empty; // in word, per word code point
        try dotted.append(scratch, '.');
        try starts.append(scratch, 0);
        var view = std.unicode.Utf8View.initUnchecked(word).iterator();
        var at: u32 = 0;
        while (view.nextCodepointSlice()) |slice| {
            const cp = std.unicode.utf8Decode(slice) catch unreachable;
            try origin.append(scratch, at);
            at += @intCast(slice.len);
            try starts.append(scratch, @intCast(dotted.items.len));
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(lower(cp), &buf) catch unreachable;
            try dotted.appendSlice(scratch, buf[0..n]);
        }
        const n: u32 = @intCast(origin.items.len);
        if (n < @as(u32, h.left_min) + h.right_min) return;
        try starts.append(scratch, @intCast(dotted.items.len));
        try dotted.append(scratch, '.');
        try starts.append(scratch, @intCast(dotted.items.len));

        // The values at the gap before each dotted code point.
        const values = try scratch.alloc(u8, n + 3);
        @memset(values, 0);
        const lowered = dotted.items[1 .. dotted.items.len - 1];
        if (h.exceptions.get(lowered)) |ex| {
            for (ex) |k| values[k + 1] = 1;
        } else {
            const len = n + 2;
            for (0..len) |i| {
                var j = i + 1;
                while (j <= len and j - i <= h.max_len) : (j += 1) {
                    const key = dotted.items[starts.items[i]..starts.items[j]];
                    const pattern = h.patterns.get(key) orelse continue;
                    for (pattern, 0..) |v, k| values[i + k] = @max(values[i + k], v);
                }
            }
        }
        // A break before word code point k is the gap before dotted k + 1.
        var k: u32 = h.left_min;
        while (k + h.right_min <= n) : (k += 1) {
            if (values[k + 1] % 2 == 1) try out.append(gpa, origin.items[k]);
        }
    }
};

fn lower(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
    return uucode.get(.simple_lowercase_mapping, cp);
}

/// Whether a code point belongs in a hyphenated word: letters, marks, and
/// apostrophes (French and Catalan patterns hyphenate across them).
pub fn isWordChar(cp: u21) bool {
    if (cp == '\'' or cp == 0x2019) return true;
    return switch (uucode.get(.general_category, cp)) {
        .letter_uppercase, .letter_lowercase, .letter_titlecase, .letter_modifier, .letter_other, .mark_nonspacing, .mark_spacing_combining, .mark_enclosing => true,
        else => false,
    };
}

const Builtin = struct {
    tag: []const u8,
    patterns: []const u8,
    exceptions: []const u8 = "",
    left: u8,
    right: u8,
};

/// The built-in patterns: hyph-utf8's files under MIT, BSD, or
/// equally permissive licences (hyphenation/README.md), with their
/// typesetting hyphenmins. The first of a language is its default.
const builtins = [_]Builtin{
    .{ .tag = "en-us", .patterns = @embedFile("hyphenation/hyph-en-us.pat.txt"), .exceptions = @embedFile("hyphenation/hyph-en-us.hyp.txt"), .left = 2, .right = 3 },
    .{ .tag = "en-gb", .patterns = @embedFile("hyphenation/hyph-en-gb.pat.txt"), .exceptions = @embedFile("hyphenation/hyph-en-gb.hyp.txt"), .left = 2, .right = 3 },
    .{ .tag = "de-1996", .patterns = @embedFile("hyphenation/hyph-de-1996.pat.txt"), .left = 2, .right = 2 },
    .{ .tag = "fr", .patterns = @embedFile("hyphenation/hyph-fr.pat.txt"), .left = 2, .right = 2 },
    .{ .tag = "es", .patterns = @embedFile("hyphenation/hyph-es.pat.txt"), .left = 2, .right = 2 },
    .{ .tag = "nl", .patterns = @embedFile("hyphenation/hyph-nl.pat.txt"), .exceptions = @embedFile("hyphenation/hyph-nl.hyp.txt"), .left = 2, .right = 2 },
    .{ .tag = "pt", .patterns = @embedFile("hyphenation/hyph-pt.pat.txt"), .exceptions = @embedFile("hyphenation/hyph-pt.hyp.txt"), .left = 2, .right = 3 },
    .{ .tag = "pl", .patterns = @embedFile("hyphenation/hyph-pl.pat.txt"), .exceptions = @embedFile("hyphenation/hyph-pl.hyp.txt"), .left = 2, .right = 2 },
    .{ .tag = "uk", .patterns = @embedFile("hyphenation/hyph-uk.pat.txt"), .left = 2, .right = 2 },
    .{ .tag = "sk", .patterns = @embedFile("hyphenation/hyph-sk.pat.txt"), .exceptions = @embedFile("hyphenation/hyph-sk.hyp.txt"), .left = 2, .right = 3 },
};

/// English regions that spell (and hyphenate) the British way.
const british = [_][]const u8{ "gb", "au", "nz", "ie", "za", "in" };

/// Hyphenators by language, parsed on first use.
pub const Hyphenation = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    builtins_added: bool = false,

    const Entry = struct {
        /// Lowercase BCP 47 tag.
        tag: []const u8,
        patterns: []const u8,
        exceptions: []const u8,
        left: u8,
        right: u8,
        /// Copies of patterns the application added (else built in).
        owned: bool,
        state: union(enum) { unloaded, ready: Hyphenator, failed },
    };

    pub fn init(gpa: Allocator) Hyphenation {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Hyphenation) void {
        for (self.entries.items) |*e| self.release(e);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    fn release(self: *Hyphenation, e: *Entry) void {
        if (e.state == .ready) e.state.ready.deinit();
        self.gpa.free(e.tag);
        if (e.owned) {
            self.gpa.free(e.patterns);
            self.gpa.free(e.exceptions);
        }
    }

    /// Adds patterns for a language (copied), replacing any it had,
    /// built in or added. They are checked now and parsed on first use.
    pub fn add(self: *Hyphenation, tag: []const u8, patterns: []const u8, exceptions: []const u8, left_min: u8, right_min: u8) error{ OutOfMemory, InvalidPatterns }!void {
        if (tag.len == 0 or !std.unicode.utf8ValidateSlice(patterns) or !std.unicode.utf8ValidateSlice(exceptions)) return error.InvalidPatterns;
        var probe: Hyphenator = try .init(self.gpa, patterns, exceptions, left_min, right_min);
        probe.deinit();
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        const low = try std.ascii.allocLowerString(self.gpa, tag);
        errdefer self.gpa.free(low);
        const p = try self.gpa.dupe(u8, patterns);
        errdefer self.gpa.free(p);
        const x = try self.gpa.dupe(u8, exceptions);
        errdefer self.gpa.free(x);
        for (self.entries.items, 0..) |*e, i| if (std.mem.eql(u8, e.tag, low)) {
            self.release(e);
            _ = self.entries.orderedRemove(i);
            break;
        };
        // Added patterns come first, so they also become the language's
        // default.
        self.entries.insertAssumeCapacity(0, .{ .tag = low, .patterns = p, .exceptions = x, .left = left_min, .right = right_min, .owned = true, .state = .unloaded });
    }

    /// Built-ins join once, after (and not replacing) anything added.
    fn ensureBuiltins(self: *Hyphenation) Allocator.Error!void {
        if (self.builtins_added) return;
        try self.entries.ensureUnusedCapacity(self.gpa, builtins.len);
        for (builtins) |b| {
            if (self.find(b.tag) != null) continue;
            const tag = try self.gpa.dupe(u8, b.tag);
            self.entries.appendAssumeCapacity(.{ .tag = tag, .patterns = b.patterns, .exceptions = b.exceptions, .left = b.left, .right = b.right, .owned = false, .state = .unloaded });
        }
        self.builtins_added = true;
    }

    /// The hyphenator for a BCP 47 language tag: the exact tag, else its
    /// language and region, else the language's first patterns (English:
    /// British for British-spelling regions). Null if there are none.
    pub fn get(self: *Hyphenation, language: []const u8) Allocator.Error!?*const Hyphenator {
        try self.ensureBuiltins();
        var buf: [32]u8 = undefined;
        if (language.len == 0 or language.len > buf.len) return null;
        const low = std.ascii.lowerString(&buf, language);
        var parts = std.mem.tokenizeAny(u8, low, "-_");
        const lang = parts.next() orelse return null;
        var region: []const u8 = "";
        while (parts.next()) |p| if (p.len == 2 or (p.len == 3 and std.ascii.isDigit(p[0]))) {
            region = p;
            break;
        };
        var lr_buf: [16]u8 = undefined;
        const lang_region = if (region.len != 0) std.fmt.bufPrint(&lr_buf, "{s}-{s}", .{ lang, region }) catch "" else "";
        var best: ?*Entry = null;
        for (self.entries.items) |*e| if (std.mem.eql(u8, e.tag, low)) {
            best = e;
            break;
        };
        if (best == null and lang_region.len != 0) {
            for (self.entries.items) |*e| if (std.mem.eql(u8, e.tag, lang_region)) {
                best = e;
                break;
            };
        }
        if (best == null and std.mem.eql(u8, lang, "en") and region.len != 0) {
            for (british) |r| if (std.mem.eql(u8, r, region)) {
                best = self.find("en-gb");
            };
        }
        if (best == null) {
            for (self.entries.items) |*e| {
                if (std.mem.eql(u8, e.tag, lang) or (std.mem.startsWith(u8, e.tag, lang) and e.tag.len > lang.len and e.tag[lang.len] == '-')) {
                    best = e;
                    break;
                }
            }
        }
        const e = best orelse return null;
        switch (e.state) {
            .ready => |*h| return h,
            .failed => return null,
            .unloaded => {
                e.state = .{ .ready = Hyphenator.init(self.gpa, e.patterns, e.exceptions, e.left, e.right) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidPatterns => {
                        e.state = .failed;
                        return null;
                    },
                } };
                return &e.state.ready;
            },
        }
    }

    fn find(self: *Hyphenation, tag: []const u8) ?*Entry {
        for (self.entries.items) |*e| if (std.mem.eql(u8, e.tag, tag)) return e;
        return null;
    }
};

const testing = std.testing;

fn hyphenated(h: *const Hyphenator, word: []const u8, buf: []u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(testing.allocator);
    try h.points(arena.allocator(), word, &out, testing.allocator);
    var n: usize = 0;
    var prev: usize = 0;
    for (out.items) |p| {
        @memcpy(buf[n..][0 .. p - prev], word[prev..p]);
        n += p - prev;
        buf[n] = '-';
        n += 1;
        prev = p;
    }
    @memcpy(buf[n..][0 .. word.len - prev], word[prev..]);
    return buf[0 .. n + word.len - prev];
}

test "Liang's algorithm on Knuth's example patterns" {
    // The patterns of The TeXbook's appendix H example for "hyphenation".
    var h: Hyphenator = try .init(testing.allocator, "hy3ph he2n hena4 hen5at 1na n2at 1tio 2io o2n", "", 2, 3);
    defer h.deinit();
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hy-phen-ation", try hyphenated(&h, "hyphenation", &buf));
    try testing.expectEqualStrings("Hy-phen-ation", try hyphenated(&h, "Hyphenation", &buf));
    // Too short for 2 + 3.
    try testing.expectEqualStrings("hyp", try hyphenated(&h, "hyp", &buf));
}

test "built-in patterns per language, loaded on first use" {
    var reg: Hyphenation = .init(testing.allocator);
    defer reg.deinit();
    var buf: [64]u8 = undefined;
    const us = (try reg.get("en-US")).?;
    try testing.expectEqualStrings("hy-phen-ation", try hyphenated(us, "hyphenation", &buf));
    // An exception overrides the patterns.
    try testing.expectEqualStrings("as-so-ciate", try hyphenated(us, "associate", &buf));
    try testing.expect((try reg.get("en")).? == us);
    // British regions get the British patterns.
    try testing.expect((try reg.get("en-AU")).? != us);
    const de = (try reg.get("de-DE")).?;
    try testing.expectEqualStrings("Sil-ben-tren-nung", try hyphenated(de, "Silbentrennung", &buf));
    try testing.expectEqualStrings("ré-pu-blique", try hyphenated((try reg.get("fr")).?, "république", &buf));
    try testing.expect(try reg.get("xx") == null);
    try testing.expect(try reg.get("") == null);
    // Only the languages asked for were parsed.
    var loaded: usize = 0;
    for (reg.entries.items) |e| loaded += @intFromBool(e.state == .ready);
    try testing.expectEqual(4, loaded);
}

test "applications add patterns, which take precedence" {
    var reg: Hyphenation = .init(testing.allocator);
    defer reg.deinit();
    try reg.add("x-test", "a1b", "", 1, 1);
    try reg.add("en-US", "o1o", "", 1, 1);
    try testing.expectError(error.InvalidPatterns, reg.add("x-bad", "1", "", 1, 1));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a-ba-b", try hyphenated((try reg.get("x-test")).?, "abab", &buf));
    try testing.expectEqualStrings("fo-o", try hyphenated((try reg.get("en-us")).?, "foo", &buf));
    // Still there for other English.
    try testing.expect((try reg.get("en-GB")) != null);
}
