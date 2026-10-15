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
    /// Patterns in a trie over their letters (lowercase UTF-8, '.'
    /// marking a word edge): node 0 is the root, a node's children are
    /// `edge_byte` and `edge_child` from `first`, sorted by byte, and a
    /// pattern's node holds its value at each gap (one per code point,
    /// plus one). Matching walks the trie from each position of a word
    /// rather than hashing every substring.
    nodes: []const Node = &.{},
    /// The root's children by byte (0: none), the most searched.
    root: [256]u32 = @splat(0),
    edge_byte: []const u8 = &.{},
    edge_child: []const u32 = &.{},
    /// Lowercase words to the code point indices they break before.
    exceptions: std.StringHashMapUnmanaged([]const u32) = .empty,
    /// Code points kept together at a word's start and end.
    left_min: u8,
    right_min: u8,

    const Node = struct { first: u32 = 0, count: u32 = 0, values: []const u8 = &.{} };

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
        // The trie while it is built: children by parent and byte.
        var kids: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer kids.deinit(gpa);
        var node_values: std.ArrayList([]const u8) = .empty;
        defer node_values.deinit(gpa);
        try node_values.append(gpa, &.{});
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
            var node: u32 = 0;
            for (letters.items) |byte| {
                const gop = try kids.getOrPut(gpa, @as(u64, node) << 8 | byte);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(node_values.items.len);
                    try node_values.append(gpa, &.{});
                }
                node = gop.value_ptr.*;
            }
            node_values.items[node] = try a.dupe(u8, values.items);
        }
        // Flattened: edges sorted by parent, then byte.
        const Edge = struct { key: u64, child: u32 };
        const edges = try gpa.alloc(Edge, kids.count());
        defer gpa.free(edges);
        var kit = kids.iterator();
        var ei: usize = 0;
        while (kit.next()) |kv| : (ei += 1) edges[ei] = .{ .key = kv.key_ptr.*, .child = kv.value_ptr.* };
        std.mem.sort(Edge, edges, {}, struct {
            fn lt(_: void, x: Edge, y: Edge) bool {
                return x.key < y.key;
            }
        }.lt);
        const nodes = try a.alloc(Node, node_values.items.len);
        for (nodes, node_values.items) |*n, v| n.* = .{ .values = v };
        const edge_byte = try a.alloc(u8, edges.len);
        const edge_child = try a.alloc(u32, edges.len);
        for (edges, 0..) |e, k| {
            const parent: u32 = @intCast(e.key >> 8);
            if (nodes[parent].count == 0) nodes[parent].first = @intCast(k);
            nodes[parent].count += 1;
            edge_byte[k] = @truncate(e.key);
            edge_child[k] = e.child;
        }
        for (edge_byte[0..nodes[0].count], edge_child[0..nodes[0].count]) |b, c| h.root[b] = c;
        h.nodes = nodes;
        h.edge_byte = edge_byte;
        h.edge_child = edge_child;
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
    /// may break, in increasing order. `scratch` holds intermediates of
    /// long words.
    pub fn points(h: *const Hyphenator, scratch: Allocator, word: []const u8, out: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!void {
        // The word lowercased between dots, where each code point starts
        // in it (plus the end), and where each starts in the word.
        const short = 48;
        var dotted_buf: [short * 4 + 2]u8 = undefined;
        var starts_buf: [short + 3]u32 = undefined;
        var origin_buf: [short]u32 = undefined;
        const long = word.len > short;
        const dotted = if (long) try scratch.alloc(u8, word.len * 4 + 2) else &dotted_buf;
        const starts = if (long) try scratch.alloc(u32, word.len + 3) else &starts_buf;
        const origin = if (long) try scratch.alloc(u32, word.len) else &origin_buf;
        dotted[0] = '.';
        starts[0] = 0;
        var len: u32 = 1;
        var n: u32 = 0;
        var at: u32 = 0;
        while (at < word.len) {
            origin[n] = at;
            n += 1;
            starts[n] = len;
            const c = word[at];
            if (c < 0x80) {
                dotted[len] = std.ascii.toLower(c);
                len += 1;
                at += 1;
                continue;
            }
            const l = std.unicode.utf8ByteSequenceLength(c) catch unreachable;
            const cp = std.unicode.utf8Decode(word[at..][0..l]) catch unreachable;
            at += l;
            len += std.unicode.utf8Encode(lower(cp), dotted[len..][0..4]) catch unreachable;
        }
        if (n < @as(u32, h.left_min) + h.right_min) return;
        starts[n + 1] = len;
        dotted[len] = '.';
        len += 1;
        starts[n + 2] = len;

        // The values at the gap before each dotted code point.
        var values_buf: [short + 3]u8 = undefined;
        const values = if (long) try scratch.alloc(u8, n + 3) else values_buf[0 .. n + 3];
        @memset(values, 0);
        if (h.exceptions.get(dotted[1 .. len - 1])) |ex| {
            for (ex) |k| values[k + 1] = 1;
        } else {
            // From each code point, the patterns the text there starts with.
            for (0..n + 2) |i| {
                var node = h.root[dotted[starts[i]]];
                var b = starts[i];
                while (node != 0) {
                    b += 1;
                    const pattern = h.nodes[node].values;
                    for (pattern, values[i..][0..pattern.len]) |v, *x| x.* = @max(x.*, v);
                    if (b == len) break;
                    node = h.child(node, dotted[b]) orelse break;
                }
            }
        }
        // A break before word code point k is the gap before dotted k + 1.
        var k: u32 = h.left_min;
        while (k + h.right_min <= n) : (k += 1) {
            if (values[k + 1] % 2 == 1) try out.append(gpa, origin[k]);
        }
    }

    fn child(h: *const Hyphenator, node: u32, byte: u8) ?u32 {
        const nd = h.nodes[node];
        for (h.edge_byte[nd.first..][0..nd.count], nd.first..) |b, k| {
            if (b == byte) return h.edge_child[k];
            if (b > byte) return null;
        }
        return null;
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
