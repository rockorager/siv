//! Text for the AT-SPI Text interface: offsets in characters (code points,
//! as AT-SPI counts them) over siv's UTF-8 strings, and the ranges of
//! characters, words, sentences, lines, and paragraphs around an offset.

const std = @import("std");
const text = @import("text");
const atspi = @import("atspi.zig");

pub fn charCount(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| n += @intFromBool(c & 0xc0 != 0x80);
    return n;
}

/// The byte offset of character `char`, clamped to the end.
pub fn byteOf(s: []const u8, char: i64) usize {
    if (char <= 0) return 0;
    var n: i64 = 0;
    for (s, 0..) |c, i| {
        if (c & 0xc0 == 0x80) continue;
        if (n == char) return i;
        n += 1;
    }
    return s.len;
}

/// The character offset of byte `byte` (rounded down to a character).
pub fn charOf(s: []const u8, byte: usize) u32 {
    return charCount(s[0..@min(byte, s.len)]);
}

pub const Range = struct { start: u32, end: u32 };

/// The range of `granularity` containing character `offset`, in
/// characters. `line_ends` gives line breaks of the laid-out text, when
/// known; otherwise lines are paragraphs.
pub fn rangeAt(gpa: std.mem.Allocator, s: []const u8, g: atspi.Granularity, offset: i64) error{OutOfMemory}!Range {
    const len = charCount(s);
    const o: u32 = @intCast(std.math.clamp(offset, 0, len));
    switch (g) {
        .char => return .{ .start = o, .end = @min(o + 1, len) },
        .word => {
            var w = try text.segmentation.words(gpa, s);
            defer w.deinit(gpa);
            const b = byteOf(s, o);
            const start = if (b == s.len and b > 0) w.starts.atOrBefore(@intCast(b - 1)) orelse 0 else w.starts.atOrBefore(@intCast(b)) orelse 0;
            const end = w.starts.after(@intCast(b)) orelse @as(u32, @intCast(s.len));
            return .{ .start = charOf(s, start), .end = charOf(s, end) };
        },
        .sentence => return around(s, o, isSentenceStart),
        .line, .paragraph => return around(s, o, isParagraphStart),
        _ => return .{ .start = o, .end = o },
    }
}

/// The range around `o` between starts found by `isStart` (called with
/// byte offsets > 0).
fn around(s: []const u8, o: u32, isStart: *const fn ([]const u8, usize) bool) Range {
    const b = byteOf(s, o);
    var start = @min(b, s.len);
    // The range containing the last character when `o` is at the end.
    if (start == s.len and start > 0) start -= 1;
    while (start > 0 and !isStart(s, start)) start -= 1;
    var end = b + 1;
    while (end < s.len and !isStart(s, end)) end += 1;
    return .{ .start = charOf(s, start), .end = charOf(s, @min(end, s.len)) };
}

fn isParagraphStart(s: []const u8, i: usize) bool {
    return s[i - 1] == '\n';
}

/// A heuristic: a sentence starts after a paragraph break, or at the
/// first non-space after ".", "!", or "?" (and closing quotes) and space.
fn isSentenceStart(s: []const u8, i: usize) bool {
    if (s[i - 1] == '\n') return true;
    if (s[i] == ' ' or s[i] == '\t' or s[i] & 0xc0 == 0x80) return false;
    var j = i;
    var spaced = false;
    while (j > 0 and (s[j - 1] == ' ' or s[j - 1] == '\t')) : (j -= 1) spaced = true;
    if (!spaced) return false;
    while (j > 0 and (s[j - 1] == '"' or s[j - 1] == '\'' or s[j - 1] == ')')) j -= 1;
    return j > 0 and (s[j - 1] == '.' or s[j - 1] == '!' or s[j - 1] == '?');
}

/// The granularity a deprecated boundary type stands for.
pub fn granularityOf(b: atspi.Boundary) atspi.Granularity {
    return switch (b) {
        .char => .char,
        .word_start, .word_end => .word,
        .sentence_start, .sentence_end => .sentence,
        .line_start, .line_end => .line,
        _ => .char,
    };
}

/// The difference between two strings as one replaced range: the common
/// prefix and suffix are kept, in bytes.
pub const Change = struct { start: usize, old_end: usize, new_end: usize };

pub fn diff(old: []const u8, new: []const u8) ?Change {
    if (std.mem.eql(u8, old, new)) return null;
    var p: usize = 0;
    while (p < old.len and p < new.len and old[p] == new[p]) p += 1;
    while (p > 0 and p < old.len and old[p] & 0xc0 == 0x80) p -= 1;
    var sfx: usize = 0;
    while (sfx < old.len - p and sfx < new.len - p and old[old.len - 1 - sfx] == new[new.len - 1 - sfx]) sfx += 1;
    while (sfx > 0 and old[old.len - sfx] & 0xc0 == 0x80) sfx -= 1;
    return .{ .start = p, .old_end = old.len - sfx, .new_end = new.len - sfx };
}

const testing = std.testing;

test "character offsets over UTF-8" {
    const s = "aé😀b";
    try testing.expectEqual(@as(u32, 4), charCount(s));
    try testing.expectEqual(@as(usize, 3), byteOf(s, 2));
    try testing.expectEqual(@as(usize, s.len), byteOf(s, 9));
    try testing.expectEqual(@as(u32, 3), charOf(s, 7));
}

test "ranges of words, sentences, and paragraphs" {
    const gpa = testing.allocator;
    const s = "Hello wörld. Next one!\nSecond line";
    const cases = [_]struct { atspi.Granularity, i64, []const u8 }{
        .{ .char, 7, "ö" },
        .{ .word, 2, "Hello " },
        .{ .word, 7, "wörld. " },
        .{ .sentence, 3, "Hello wörld. " },
        .{ .sentence, 15, "Next one!\n" },
        .{ .paragraph, 3, "Hello wörld. Next one!\n" },
        .{ .line, 30, "Second line" },
        .{ .line, 99, "Second line" },
    };
    for (cases) |c| {
        const r = try rangeAt(gpa, s, c[0], c[1]);
        try testing.expectEqualStrings(c[2], s[byteOf(s, r.start)..byteOf(s, r.end)]);
    }
}

test "diff keeps the common prefix and suffix" {
    const c = diff("hello world", "hello brave world").?;
    try testing.expectEqual(Change{ .start = 6, .old_end = 6, .new_end = 12 }, c);
    try testing.expect(diff("same", "same") == null);
    const d = diff("aé", "aè").?; // differs inside a two-byte character
    try testing.expectEqual(@as(usize, 1), d.start);
    try testing.expectEqual(@as(usize, 3), d.old_end);
}
