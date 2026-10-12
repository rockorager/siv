//! UAX #29 (Unicode 18.0) extended grapheme cluster and word boundaries.
//!
//! Grapheme clusters come from uucode; word boundaries are siv's scanner,
//! ported from ourokit. Both run against the official conformance files.

const std = @import("std");
const uucode = @import("uucode");
const Boundaries = @import("boundaries.zig");

/// Marks every extended grapheme cluster boundary, including 0 and
/// `text.len`. `text` must be valid UTF-8.
pub fn graphemes(allocator: std.mem.Allocator, text: []const u8) !Boundaries {
    var result: Boundaries = try .init(allocator, @intCast(text.len));
    result.set(0);
    // Every ASCII pair is a boundary except CR LF (GB3).
    var i: usize = 0;
    while (i < text.len and text[i] < 0x80) : (i += 1) {
        if (i != 0 and !(text[i] == '\n' and text[i - 1] == '\r')) result.set(@intCast(i));
    }
    if (i < text.len) {
        // Restart from the last ASCII boundary so the iterator sees context.
        var restart = i -| 1;
        if (restart != 0 and text[restart] == '\n' and text[restart - 1] == '\r') restart -= 1;
        var iterator = uucode.grapheme.utf8Iterator(text[restart..]);
        while (iterator.nextGrapheme()) |grapheme| result.set(@intCast(restart + grapheme.start));
    }
    result.set(@intCast(text.len));
    return result;
}

const Property = uucode.TypeOf(.word_break);

const Unit = struct {
    start: usize,
    end: usize,
    property: Property,
    extended_pictographic: bool,
};

/// Word boundaries and which segments are words (as opposed to spaces and
/// punctuation). `starts` holds the boundaries that begin a word segment.
pub const Words = struct {
    boundaries: Boundaries,
    starts: Boundaries,

    pub fn deinit(self: *Words, allocator: std.mem.Allocator) void {
        self.boundaries.deinit(allocator);
        self.starts.deinit(allocator);
    }
};

/// Marks every default UAX #29 word boundary, including 0 and `text.len`,
/// and the start of every word-like segment. `text` must be valid UTF-8.
pub fn words(allocator: std.mem.Allocator, text: []const u8) !Words {
    var boundaries: Boundaries = try .init(allocator, @intCast(text.len));
    errdefer boundaries.deinit(allocator);
    var starts: Boundaries = try .init(allocator, @intCast(text.len));
    boundaries.set(0);
    if (text.len != 0) {
        const first = unitAt(text, 0);
        var segment_start: usize = 0;
        var offset = first.end;
        var immediate_left = first;
        var regional_indicators: usize = @intFromBool(first.property == .regional_indicator);
        while (offset < text.len) {
            const unit = unitAt(text, offset);
            if (breaksAt(text, immediate_left, unit, regional_indicators)) {
                boundaries.set(@intCast(offset));
                if (isWordSegment(text[segment_start..offset])) starts.set(@intCast(segment_start));
                segment_start = offset;
            }
            offset = unit.end;
            immediate_left = unit;
            if (!isIgnored(unit.property)) regional_indicators =
                if (unit.property == .regional_indicator) regional_indicators + 1 else 0;
        }
        if (isWordSegment(text[segment_start..])) starts.set(@intCast(segment_start));
    }
    boundaries.set(@intCast(text.len));
    return .{ .boundaries = boundaries, .starts = starts };
}

/// Distinguishes word-like segments from separators and punctuation after
/// UAX #29 has placed boundaries. This is editor policy, not conformance.
fn isWordSegment(text: []const u8) bool {
    var offset: usize = 0;
    while (offset < text.len) {
        const unit = unitAt(text, offset);
        offset = unit.end;
        if (isIgnored(unit.property)) continue;
        if (isAhLetter(unit.property) or unit.property == .numeric or
            unit.property == .katakana or unit.property == .extendnumlet or
            unit.property == .regional_indicator or unit.extended_pictographic) return true;
        // Scripts without Word_Break letters (Han, Thai, ...) are words too.
        const cp = std.unicode.utf8Decode(text[unit.start..unit.end]) catch unreachable;
        return switch (uucode.get(.general_category, cp)) {
            .letter_uppercase, .letter_lowercase, .letter_titlecase, .letter_modifier, .letter_other, .number_decimal_digit, .number_letter, .number_other => true,
            else => false,
        };
    }
    return false;
}

fn breaksAt(text: []const u8, immediate_left: Unit, right: Unit, regional_indicators: usize) bool {
    // WB3-WB3d apply before format and extend characters are ignored.
    if (immediate_left.property == .cr and right.property == .lf) return false;
    if (isNewline(immediate_left.property) or isNewline(right.property)) return true;
    if (immediate_left.property == .zwj and right.extended_pictographic) return false;
    if (immediate_left.property == .wsegspace and right.property == .wsegspace) return false;

    // WB4: ignored characters attach to the preceding significant one. At the
    // start of text or after a hard break they form their own segment.
    if (isIgnored(right.property)) return false;
    const left = if (!isIgnored(immediate_left.property)) immediate_left else previousSignificant(text, immediate_left.start) orelse return true;
    if (isIgnored(immediate_left.property) and isNewline(left.property)) return true;

    // Decode lookbehind and lookahead only for the rules that need them.
    const previous = if (isMidLetter(left.property) or isMidNumber(left.property) or left.property == .double_quote)
        previousSignificant(text, left.start)
    else
        null;
    const next = if (isMidLetter(right.property) or isMidNumber(right.property) or right.property == .double_quote)
        nextSignificant(text, right.end)
    else
        null;
    const left_ah = isAhLetter(left.property);
    const right_ah = isAhLetter(right.property);

    // WB5-WB7c
    if (left_ah and right_ah) return false;
    if (left_ah and isMidLetter(right.property) and next != null and isAhLetter(next.?.property)) return false;
    if (previous != null and isAhLetter(previous.?.property) and isMidLetter(left.property) and right_ah) return false;
    if (left.property == .hebrew_letter and right.property == .single_quote) return false;
    if (left.property == .hebrew_letter and right.property == .double_quote and
        next != null and next.?.property == .hebrew_letter) return false;
    if (previous != null and previous.?.property == .hebrew_letter and
        left.property == .double_quote and right.property == .hebrew_letter) return false;

    // WB8-WB12
    if (left.property == .numeric and right.property == .numeric) return false;
    if (left_ah and right.property == .numeric) return false;
    if (left.property == .numeric and right_ah) return false;
    if (previous != null and previous.?.property == .numeric and
        isMidNumber(left.property) and right.property == .numeric) return false;
    if (left.property == .numeric and isMidNumber(right.property) and
        next != null and next.?.property == .numeric) return false;

    // WB13-WB13b
    if (left.property == .katakana and right.property == .katakana) return false;
    if (isExtendNumLetLeft(left.property) and right.property == .extendnumlet) return false;
    if (left.property == .extendnumlet and isExtendNumLetRight(right.property)) return false;

    // WB15-WB16: ignored characters do not affect regional indicator parity.
    if (left.property == .regional_indicator and right.property == .regional_indicator and
        regional_indicators & 1 == 1) return false;

    return true; // WB999
}

fn isIgnored(property: Property) bool {
    return property == .extend or property == .format or property == .zwj;
}

fn isNewline(property: Property) bool {
    return property == .cr or property == .lf or property == .newline;
}

fn isAhLetter(property: Property) bool {
    return property == .aletter or property == .hebrew_letter;
}

fn isMidLetter(property: Property) bool {
    return property == .midletter or property == .midnumlet or property == .single_quote;
}

fn isMidNumber(property: Property) bool {
    return property == .midnum or property == .midnumlet or property == .single_quote;
}

fn isExtendNumLetLeft(property: Property) bool {
    return isAhLetter(property) or property == .numeric or property == .katakana or property == .extendnumlet;
}

fn isExtendNumLetRight(property: Property) bool {
    return isAhLetter(property) or property == .numeric or property == .katakana;
}

fn previousSignificant(text: []const u8, before: usize) ?Unit {
    var cursor = before;
    while (previousUnit(text, cursor)) |unit| {
        if (!isIgnored(unit.property)) return unit;
        cursor = unit.start;
    }
    return null;
}

fn nextSignificant(text: []const u8, after: usize) ?Unit {
    var cursor = after;
    while (cursor < text.len) {
        const unit = unitAt(text, cursor);
        if (!isIgnored(unit.property)) return unit;
        cursor = unit.end;
    }
    return null;
}

fn previousUnit(text: []const u8, before: usize) ?Unit {
    if (before == 0) return null;
    var start = before - 1;
    while (start != 0 and text[start] & 0xc0 == 0x80) start -= 1;
    return unitAt(text, start);
}

fn unitAt(text: []const u8, start: usize) Unit {
    const length = std.unicode.utf8ByteSequenceLength(text[start]) catch unreachable;
    const end = start + length;
    const codepoint = std.unicode.utf8Decode(text[start..end]) catch unreachable;
    return .{
        .start = start,
        .end = end,
        .property = uucode.get(.word_break, codepoint),
        .extended_pictographic = uucode.get(.is_extended_pictographic, codepoint),
    };
}

fn expectBoundaries(expected: []const usize, actual: Boundaries, line_number: usize, file: []const u8) !void {
    var index: usize = 0;
    var offset: u32 = 0;
    while (true) : (index += 1) {
        const matches = index < expected.len and expected[index] == offset;
        if (!matches) {
            std.debug.print("{s}:{d}: expected {any}, boundary {d} differs\n", .{ file, line_number, expected, offset });
            return error.TestUnexpectedResult;
        }
        offset = actual.after(offset) orelse break;
    }
    if (index + 1 != expected.len) {
        std.debug.print("{s}:{d}: expected {any}, got {d} boundaries\n", .{ file, line_number, expected, index + 1 });
        return error.TestUnexpectedResult;
    }
}

test "UAX #29 grapheme conformance (GraphemeBreakTest-18.0.0)" {
    const gpa = std.testing.allocator;
    var cases = @import("ucd_test.zig").Cases.init(@embedFile("GraphemeBreakTest.txt"));
    defer cases.deinit(gpa);
    var count: usize = 0;
    while (try cases.next(gpa)) |case| : (count += 1) {
        var actual = try graphemes(gpa, case.utf8);
        defer actual.deinit(gpa);
        // uucode's documented tailoring (UAX29-C1-2 profile): an emoji
        // modifier that does not follow an emoji modifier base starts its own
        // cluster, as UTS #51 ED-13 requires for modifier sequences.
        var expected: std.ArrayList(usize) = .empty;
        defer expected.deinit(gpa);
        try expected.appendSlice(gpa, case.breaks);
        var iterator = uucode.utf8.Iterator.init(case.utf8);
        var previous: ?u21 = null;
        while (iterator.next()) |cp| : (previous = cp) {
            const start = iterator.i - @as(usize, std.unicode.utf8CodepointSequenceLength(cp) catch unreachable);
            if (previous != null and uucode.get(.is_emoji_modifier, cp) and !uucode.get(.is_emoji_modifier_base, previous.?) and
                std.mem.indexOfScalar(usize, expected.items, start) == null)
            {
                try expected.append(gpa, start);
                std.mem.sort(usize, expected.items, {}, std.sort.asc(usize));
            }
        }
        try expectBoundaries(expected.items, actual, case.line_number, "GraphemeBreakTest.txt");
    }
    try std.testing.expect(count > 700);
}

test "UAX #29 word conformance (WordBreakTest-18.0.0)" {
    const gpa = std.testing.allocator;
    var cases = @import("ucd_test.zig").Cases.init(@embedFile("WordBreakTest.txt"));
    defer cases.deinit(gpa);
    var count: usize = 0;
    while (try cases.next(gpa)) |case| : (count += 1) {
        var actual = try words(gpa, case.utf8);
        defer actual.deinit(gpa);
        try expectBoundaries(case.breaks, actual.boundaries, case.line_number, "WordBreakTest.txt");
    }
    try std.testing.expect(count > 1_800);
}

test "word segments exclude spaces and punctuation" {
    const text = "can't stop, 世界 42";
    var result = try words(std.testing.allocator, text);
    defer result.deinit(std.testing.allocator);
    var starts: [8]u32 = undefined;
    var count: usize = 0;
    var offset: u32 = 0;
    while (true) {
        if (result.starts.isSet(offset)) {
            starts[count] = offset;
            count += 1;
        }
        offset = result.boundaries.after(offset) orelse break;
    }
    // "can't", "stop", "世", "界" (Han has no Word_Break letters), "42".
    try std.testing.expectEqualSlices(u32, &.{ 0, 6, 12, 15, 19 }, starts[0..count]);
}
