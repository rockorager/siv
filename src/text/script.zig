//! Script itemization (UAX #24) above extended grapheme clusters, ported
//! from ourokit. Common and Inherited clusters join compatible surrounding
//! text using Script_Extensions; paired brackets take the script of the text
//! they enclose and always agree with their mate.
//!
//! Scripts are ISO 15924 tags packed big-endian into a u32, which is also
//! HarfBuzz's hb_script_t.

const std = @import("std");
const uucode = @import("uucode");
const Boundaries = @import("boundaries.zig");

pub const Script = u32;

pub fn tag(comptime code: *const [4]u8) Script {
    return std.mem.readInt(u32, code, .big);
}

pub const common = tag("Zyyy");
pub const inherited = tag("Zinh");
pub const unknown = tag("Zzzz");
pub const latin = tag("Latn");

pub const Run = struct {
    start: u32,
    end: u32,
    script: Script,
};

/// Explicit script candidates of a code point or cluster: Script_Extensions
/// without Common, Inherited, and Unknown.
const Candidates = struct {
    /// The candidate when there is exactly one and `multi` is empty.
    single: Script = 0,
    /// Concatenated ISO 15924 codes when there are several.
    multi: []const u8 = "",

    fn of(cp: u21) Candidates {
        const extensions = uucode.get(.script_extensions, cp);
        if (extensions.len == 4) return .{ .single = std.mem.readInt(u32, extensions[0..4], .big) };
        if (extensions.len != 0) return .{ .multi = extensions };
        const script = uucode.get(.iso_script, cp);
        return if (isGeneric(script)) .{} else .{ .single = script };
    }

    fn count(self: Candidates) usize {
        return if (self.multi.len != 0) self.multi.len / 4 else @intFromBool(self.single != 0);
    }

    fn at(self: Candidates, index: usize) Script {
        return if (self.multi.len != 0) std.mem.readInt(u32, self.multi[index * 4 ..][0..4], .big) else self.single;
    }

    fn contains(self: Candidates, script: Script) bool {
        for (0..self.count()) |i| if (self.at(i) == script) return true;
        return false;
    }

    fn intersect(self: Candidates, other: Candidates, allocator: std.mem.Allocator) !Candidates {
        var result: std.ArrayList(u8) = .empty;
        for (0..self.count()) |i| {
            const script = self.at(i);
            if (!other.contains(script)) continue;
            var code: [4]u8 = undefined;
            std.mem.writeInt(u32, &code, script, .big);
            try result.appendSlice(allocator, &code);
        }
        return switch (result.items.len) {
            0 => .{},
            4 => .{ .single = std.mem.readInt(u32, result.items[0..4], .big) },
            else => .{ .multi = result.items },
        };
    }
};

fn isGeneric(script: Script) bool {
    return script == common or script == inherited or script == unknown;
}

const Cluster = struct {
    start: u32,
    end: u32,
    candidates: Candidates,
    preferred: ?Script,
    resolved: ?Script = null,
    first: u21,
    paired: bool = false,

    fn compatible(self: Cluster, script: Script) bool {
        return self.candidates.count() == 0 or self.candidates.contains(script);
    }
};

/// Splits `text[start..end]` (one bidi paragraph, without its separator) into
/// maximal runs of one script. Offsets are absolute. `graphemes` holds the
/// grapheme boundaries of all of `text`; runs never split a cluster.
pub fn analyze(allocator: std.mem.Allocator, text: []const u8, graphemes: Boundaries, start: u32, end: u32) ![]Run {
    var runs: std.ArrayList(Run) = .empty;
    errdefer runs.deinit(allocator);
    if (start == end) return runs.toOwnedSlice(allocator);

    // Text of only Latin characters and Common or Inherited ones without
    // other scripts' extensions (ASCII, accented letters, curly quotes,
    // dashes: most European text) resolves to one script for every
    // cluster: Latin if any character is.
    var letters = false;
    var i = start;
    const simple = while (i < end) {
        const byte = text[i];
        if (byte < 0x80) {
            letters = letters or std.ascii.isAlphabetic(byte);
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch break false;
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch break false;
        i += len;
        const candidates: Candidates = .of(cp);
        if (candidates.multi.len != 0 or (candidates.single != 0 and candidates.single != latin)) break false;
        const script = uucode.get(.iso_script, cp);
        if (!isGeneric(script) and script != latin) break false;
        letters = letters or candidates.single == latin;
    } else true;
    if (simple) {
        try runs.append(allocator, .{ .start = start, .end = end, .script = if (letters) latin else common });
        return runs.toOwnedSlice(allocator);
    }
    return analyzeClusters(allocator, text, graphemes, start, end, &runs);
}

/// `analyze` for text of several scripts, cluster by cluster.
fn analyzeClusters(allocator: std.mem.Allocator, text: []const u8, graphemes: Boundaries, start: u32, end: u32, runs: *std.ArrayList(Run)) ![]Run {
    var clusters: std.ArrayList(Cluster) = .empty;
    defer clusters.deinit(allocator);
    var cluster_start = start;
    while (cluster_start < end) {
        const cluster_end = @min(end, graphemes.after(cluster_start).?);
        try clusters.append(allocator, try analyzeCluster(allocator, text, cluster_start, cluster_end));
        cluster_start = cluster_end;
    }
    resolveContext(clusters.items);
    try resolvePairedBrackets(allocator, clusters.items);
    reresolveGeneric(clusters.items);

    for (clusters.items) |cluster| {
        const script = cluster.resolved orelse common;
        if (runs.items.len != 0 and runs.items[runs.items.len - 1].script == script) {
            runs.items[runs.items.len - 1].end = cluster.end;
        } else {
            try runs.append(allocator, .{ .start = cluster.start, .end = cluster.end, .script = script });
        }
    }
    return runs.toOwnedSlice(allocator);
}

fn analyzeCluster(allocator: std.mem.Allocator, text: []const u8, start: u32, end: u32) !Cluster {
    var iterator = uucode.utf8.Iterator.init(text[start..end]);
    const first = iterator.next().?;
    var candidates: Candidates = .of(first);
    var preferred = explicitScript(first);
    while (iterator.next()) |cp| {
        if (preferred == null) preferred = explicitScript(cp);
        const next: Candidates = .of(cp);
        if (next.count() == 0) continue;
        if (candidates.count() == 0) {
            candidates = next;
        } else {
            // A malformed cross-script combining sequence stays one cluster
            // and follows its base rather than splitting.
            const intersection = try candidates.intersect(next, allocator);
            if (intersection.count() != 0) candidates = intersection;
        }
    }
    return .{ .start = start, .end = end, .candidates = candidates, .preferred = preferred, .first = first };
}

fn explicitScript(cp: u21) ?Script {
    const script = uucode.get(.iso_script, cp);
    return if (isGeneric(script)) null else script;
}

fn resolveContext(clusters: []Cluster) void {
    var previous: ?Script = null;
    for (clusters) |*cluster| {
        if (previous != null and cluster.compatible(previous.?)) {
            cluster.resolved = previous;
        } else if (cluster.preferred) |preferred| {
            cluster.resolved = preferred;
        } else if (cluster.candidates.count() == 1) {
            cluster.resolved = cluster.candidates.at(0);
        }
        if (cluster.resolved != null) previous = cluster.resolved;
    }
    var next: ?Script = null;
    var i = clusters.len;
    while (i != 0) {
        i -= 1;
        const cluster = &clusters[i];
        if (cluster.resolved == null and next != null and cluster.compatible(next.?)) cluster.resolved = next;
        if (cluster.resolved != null) next = cluster.resolved;
    }
}

fn resolvePairedBrackets(allocator: std.mem.Allocator, clusters: []Cluster) !void {
    const Open = struct { close: u21, index: usize };
    var stack: std.ArrayList(Open) = .empty;
    defer stack.deinit(allocator);
    for (clusters, 0..) |*cluster, index| switch (uucode.get(.bidi_paired_bracket, cluster.first)) {
        .open => |close| try stack.append(allocator, .{ .close = close, .index = index }),
        .close => {
            var match = stack.items.len;
            while (match != 0) {
                match -= 1;
                if (stack.items[match].close == cluster.first) break;
            } else continue;
            const opening = stack.items[match].index;
            clusters[opening].paired = true;
            cluster.paired = true;
            const enclosing = clusters[opening].resolved orelse inside: {
                for (clusters[opening + 1 .. index]) |inside| if (inside.resolved) |resolved| break :inside resolved;
                break :inside null;
            };
            clusters[opening].resolved = enclosing;
            cluster.resolved = enclosing;
            stack.shrinkRetainingCapacity(match);
        },
        .none => {},
    };
}

fn reresolveGeneric(clusters: []Cluster) void {
    for (clusters) |*cluster| {
        if (!cluster.paired and cluster.candidates.count() == 0) cluster.resolved = null;
    }
    var previous: ?Script = null;
    for (clusters) |*cluster| {
        if (cluster.resolved == null and previous != null) cluster.resolved = previous;
        if (cluster.resolved != null) previous = cluster.resolved;
    }
    var next: ?Script = null;
    var i = clusters.len;
    while (i != 0) {
        i -= 1;
        if (clusters[i].resolved == null and next != null) clusters[i].resolved = next;
        if (clusters[i].resolved != null) next = clusters[i].resolved;
    }
}

const testing = struct {
    fn runs(arena: std.mem.Allocator, text: []const u8) ![]Run {
        const graphemes = try @import("segmentation.zig").graphemes(arena, text);
        return analyze(arena, text, graphemes, 0, @intCast(text.len));
    }
};

test "Common text and Script_Extensions follow their context" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // U+30FC (Hira Kana) and U+060C (Arab Nkoo Rohg Syrc Thaa Yezi).
    const result = try testing.runs(arena.allocator(), "Latin あーアー العربية،");
    try std.testing.expectEqual(4, result.len);
    try std.testing.expectEqual(tag("Latn"), result[0].script);
    try std.testing.expectEqual(tag("Hira"), result[1].script);
    try std.testing.expectEqual(tag("Kana"), result[2].script);
    try std.testing.expectEqual(tag("Arab"), result[3].script);
    try std.testing.expectEqual(result[3].end, "Latin あーアー العربية،".len);
}

test "clusters stay whole and paired brackets take the enclosed script" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const mark = try testing.runs(arena.allocator(), "a\u{05B0}");
    try std.testing.expectEqual(1, mark.len);
    try std.testing.expectEqual(latin, mark[0].script);

    const text = "gamma (γ) text";
    const brackets = try testing.runs(arena.allocator(), text);
    try std.testing.expectEqual(3, brackets.len);
    try std.testing.expectEqualStrings("γ", text[brackets[1].start..brackets[1].end]);

    const leading = try testing.runs(arena.allocator(), "(Ελληνικά)");
    try std.testing.expectEqual(1, leading.len);
    try std.testing.expectEqual(tag("Grek"), leading[0].script);
}

test "Latin shortcut agrees with full resolution" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // ASCII, accented letters and combining marks, typographic
    // punctuation, Common symbols, and text without letters.
    for ([_][]const u8{ "([12]) --", "(abc[123])\r\nZ", "x", "Café naïve Zürich — “quoted” ‘text’…", "e\u{0301}\u{0323} ½ × € © ¶", "«» – 12 €", "Œuvre ǅ ȷ ɐ" }) |text| {
        const a = arena.allocator();
        const graphemes = try @import("segmentation.zig").graphemes(a, text);
        var slow: std.ArrayList(Run) = .empty;
        const full = try analyzeClusters(a, text, graphemes, 0, @intCast(text.len), &slow);
        const fast = try testing.runs(a, text);
        try std.testing.expectEqual(1, fast.len);
        try std.testing.expectEqualSlices(Run, full, fast);
    }
}
