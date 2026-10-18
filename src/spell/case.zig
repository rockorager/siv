//! Letter case for spell checking (D37): a word's capitalization type
//! and its lowercase, uppercase, and capitalized forms, by simple
//! (one-to-one) Unicode case mappings.
//!
//! Lowercase and the letter categories come from uucode's tables, which
//! the text engine compiles (`src/text/uucode_config.zig`); uppercase is
//! the inverse of the lowercase mapping over the Basic Multilingual Plane,
//! built once per process, since the tables carry no uppercase mapping.
//! Where two capitals lower to one letter (K and the Kelvin sign), the
//! lower code point wins, and ß stays ß as in Unicode's simple mapping.

const std = @import("std");
const uucode = @import("uucode");

/// How a word is capitalized, as Hunspell classifies it.
pub const Captype = enum {
    /// No capitals: "word".
    none,
    /// Only the first letter: "Word".
    initial,
    /// Every cased letter: "WORD", "NASA'S".
    all,
    /// Capitals elsewhere, first letter lowercase: "iPhone".
    mixed,
    /// Capitals elsewhere and first: "OpenOffice".
    mixed_initial,
};

pub fn isUpper(cp: u21) bool {
    return switch (uucode.get(.general_category, cp)) {
        .letter_uppercase, .letter_titlecase => true,
        else => false,
    };
}

pub fn isLower(cp: u21) bool {
    return uucode.get(.general_category, cp) == .letter_lowercase;
}

pub fn isLetter(cp: u21) bool {
    return switch (uucode.get(.general_category, cp)) {
        .letter_uppercase, .letter_lowercase, .letter_titlecase, .letter_modifier, .letter_other => true,
        else => false,
    };
}

pub fn lower(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
    return uucode.get(.simple_lowercase_mapping, cp);
}

/// (lowercase, uppercase) pairs by lowercase code point, built once.
var upper_pairs: [1600][2]u16 = undefined;
var upper_len: usize = 0;
var upper_state: std.atomic.Value(u8) = .init(0);
var upper_lock: std.atomic.Mutex = .unlocked;

fn ensureUpper() void {
    if (upper_state.load(.acquire) == 2) return;
    while (!upper_lock.tryLock()) std.atomic.spinLoopHint();
    defer upper_lock.unlock();
    if (upper_state.load(.acquire) == 2) return;
    buildUpper();
    upper_state.store(2, .release);
}

fn buildUpper() void {
    var cp: u21 = 0x80;
    while (cp < 0x10000) : (cp += 1) {
        if (cp >= 0xd800 and cp < 0xe000) continue;
        // ẞ lowers to ß, but ß has no simple uppercase.
        if (!isUpper(cp) or cp == 0x1e9e) continue;
        const l = uucode.get(.simple_lowercase_mapping, cp);
        if (l == cp or l >= 0x10000) continue;
        // Keep the first (lowest) capital for each lowercase letter.
        var seen = false;
        for (upper_pairs[0..upper_len]) |p| if (p[0] == l) {
            seen = true;
            break;
        };
        if (seen or upper_len == upper_pairs.len) continue;
        upper_pairs[upper_len] = .{ @intCast(l), @intCast(cp) };
        upper_len += 1;
    }
    std.mem.sort([2]u16, upper_pairs[0..upper_len], {}, struct {
        fn lt(_: void, a: [2]u16, b: [2]u16) bool {
            return a[0] < b[0];
        }
    }.lt);
}

pub fn upper(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toUpper(@intCast(cp));
    if (cp >= 0x10000) return cp;
    ensureUpper();
    const pairs = upper_pairs[0..upper_len];
    var lo: usize = 0;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (pairs[mid][0] < cp) lo = mid + 1 else hi = mid;
    }
    if (lo < pairs.len and pairs[lo][0] == cp) return pairs[lo][1];
    return cp;
}

/// Decodes the code point at `i`, and how many bytes it takes; invalid
/// bytes decode as U+FFFD one byte at a time.
pub fn decode(s: []const u8, i: usize) struct { u21, u3 } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ 0xfffd, 1 };
    if (i + n > s.len) return .{ 0xfffd, 1 };
    const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return .{ 0xfffd, 1 };
    return .{ cp, n };
}

pub fn count(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i += decode(s, i)[1];
    return n;
}

pub fn captype(s: []const u8) Captype {
    var caps: usize = 0;
    var cased: usize = 0;
    var first_cap = false;
    var i: usize = 0;
    var first = true;
    while (i < s.len) {
        const cp, const n = decode(s, i);
        i += n;
        const up = isUpper(cp);
        if (up) caps += 1;
        if (up or isLower(cp)) cased += 1;
        if (first) first_cap = up;
        first = false;
    }
    if (caps == 0) return .none;
    if (caps == 1 and first_cap) return .initial;
    if (caps == cased) return .all;
    return if (first_cap) .mixed_initial else .mixed;
}

pub const Mode = enum { lower, upper, capitalize };

/// Appends `s` in the case `mode` gives: every letter lowered or raised,
/// or the first raised and the rest left as they are.
pub fn convert(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8, mode: Mode) error{OutOfMemory}!void {
    var i: usize = 0;
    var first = true;
    while (i < s.len) {
        const cp, const n = decode(s, i);
        const mapped = switch (mode) {
            .lower => lower(cp),
            .upper => upper(cp),
            .capitalize => if (first) upper(cp) else cp,
        };
        if (mode == .capitalize and !first) {
            try out.appendSlice(gpa, s[i..]);
            return;
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(mapped, &buf) catch unreachable;
        try out.appendSlice(gpa, buf[0..len]);
        i += n;
        first = false;
    }
}

/// `convert` into a fixed buffer; null when it does not fit.
pub fn convertBuf(buf: []u8, s: []const u8, mode: Mode) ?[]u8 {
    var len: usize = 0;
    var i: usize = 0;
    var first = true;
    while (i < s.len) {
        const cp, const n = decode(s, i);
        const mapped = switch (mode) {
            .lower => lower(cp),
            .upper => upper(cp),
            .capitalize => if (first) upper(cp) else cp,
        };
        if (mode == .capitalize and !first) {
            if (len + s.len - i > buf.len) return null;
            @memcpy(buf[len..][0 .. s.len - i], s[i..]);
            return buf[0 .. len + s.len - i];
        }
        var enc: [4]u8 = undefined;
        const el = std.unicode.utf8Encode(mapped, &enc) catch unreachable;
        if (len + el > buf.len) return null;
        @memcpy(buf[len..][0..el], enc[0..el]);
        len += el;
        i += n;
        first = false;
    }
    return buf[0..len];
}

test "capitalization types and case mappings" {
    const t = std.testing;
    try t.expectEqual(Captype.none, captype("word"));
    try t.expectEqual(Captype.none, captype("1st"));
    try t.expectEqual(Captype.initial, captype("Word"));
    try t.expectEqual(Captype.all, captype("WORD"));
    try t.expectEqual(Captype.all, captype("NASA'S"));
    try t.expectEqual(Captype.mixed, captype("iPhone"));
    try t.expectEqual(Captype.mixed_initial, captype("OpenOffice"));
    try t.expectEqual(Captype.initial, captype("Éclair"));
    try t.expectEqual(Captype.all, captype("ÉCOLE"));
    try t.expectEqual(@as(u21, 'é'), lower('É'));
    try t.expectEqual(@as(u21, 'É'), upper('é'));
    try t.expectEqual(@as(u21, 'Σ'), upper('σ'));
    try t.expectEqual(@as(u21, 'K'), upper('k'));
    try t.expectEqual(@as(u21, 'ß'), upper('ß'));
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("straße", convertBuf(&buf, "STRAßE", .lower).?);
    try t.expectEqualStrings("Über", convertBuf(&buf, "über", .capitalize).?);
    try t.expectEqualStrings("ÜBER", convertBuf(&buf, "über", .upper).?);
    try t.expect(convertBuf(buf[0..2], "über", .upper) == null);
}
