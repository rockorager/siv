//! UAX #9 bidi analysis. SheenBidi resolves paragraphs and embedding levels
//! (P1-I2) once per text; line-local rules L1 and L2 run in siv after break
//! selection, on the stored levels and bidi classes, so no SheenBidi object
//! outlives `analyze`.

const std = @import("std");
const sb = @import("sheenbidi");

pub const BaseDirection = enum {
    /// First strong character (P2-P3), left-to-right when there is none.
    auto_ltr,
    /// First strong character, right-to-left when there is none.
    auto_rtl,
    ltr,
    rtl,

    fn sheenbidi(self: BaseDirection) sb.SBLevel {
        return switch (self) {
            .auto_ltr => sb.SBLevelDefaultLTR,
            .auto_rtl => sb.SBLevelDefaultRTL,
            .ltr => 0,
            .rtl => 1,
        };
    }

    fn fallbackLevel(self: BaseDirection) u8 {
        return switch (self) {
            .auto_ltr, .ltr => 0,
            .auto_rtl, .rtl => 1,
        };
    }
};

/// What rule L1 needs to know about a character's original bidi class.
pub const LineClass = enum(u8) {
    other,
    /// WS, isolate initiators and PDI, and characters removed by X9 (BN and
    /// explicit embeddings; UAX #9 section 5.2 keeps them with whitespace).
    whitespace,
    /// S and B: reset to the paragraph level along with preceding whitespace.
    separator,
};

/// One UAX #9 paragraph: text up to and including a paragraph separator.
pub const Paragraph = struct {
    start: u32,
    /// Exclusive; includes the separator.
    end: u32,
    separator_len: u32,
    base_level: u8,

    pub fn contentEnd(self: Paragraph) u32 {
        return self.end - self.separator_len;
    }
};

pub const Analysis = struct {
    paragraphs: []Paragraph,
    /// Resolved embedding level of every byte, before L1.
    levels: []u8,
    /// L1 class of every byte.
    classes: []LineClass,
};

/// Resolves paragraphs and embedding levels. Empty text has one empty
/// paragraph. `text` must be valid UTF-8 shorter than 4 GiB.
pub fn analyze(allocator: std.mem.Allocator, text: []const u8, direction: BaseDirection) error{OutOfMemory}!Analysis {
    const levels = try allocator.alloc(u8, text.len);
    errdefer allocator.free(levels);
    const classes = try allocator.alloc(LineClass, text.len);
    errdefer allocator.free(classes);
    var paragraphs: std.ArrayList(Paragraph) = .empty;
    errdefer paragraphs.deinit(allocator);

    if (text.len == 0) {
        try paragraphs.append(allocator, .{ .start = 0, .end = 0, .separator_len = 0, .base_level = direction.fallbackLevel() });
        return .{ .paragraphs = try paragraphs.toOwnedSlice(allocator), .levels = levels, .classes = classes };
    }

    const sequence: sb.SBCodepointSequence = .{
        .stringEncoding = sb.SBStringEncodingUTF8,
        .stringBuffer = text.ptr,
        .stringLength = text.len,
    };
    const algorithm = sb.SBAlgorithmCreate(&sequence) orelse return error.OutOfMemory;
    defer sb.SBAlgorithmRelease(algorithm);

    const types = sb.SBAlgorithmGetBidiTypesPtr(algorithm);
    var class: LineClass = .other;
    for (classes, text, 0..) |*out, byte, i| {
        // SheenBidi gives continuation bytes type BN; they follow their lead.
        if (byte & 0xc0 != 0x80) class = switch (types[i]) {
            sb.SBBidiTypeWS, sb.SBBidiTypeLRI, sb.SBBidiTypeRLI, sb.SBBidiTypeFSI, sb.SBBidiTypePDI, sb.SBBidiTypeBN, sb.SBBidiTypeLRE, sb.SBBidiTypeRLE, sb.SBBidiTypeLRO, sb.SBBidiTypeRLO, sb.SBBidiTypePDF => .whitespace,
            sb.SBBidiTypeS, sb.SBBidiTypeB => .separator,
            else => .other,
        };
        out.* = class;
    }

    var offset: usize = 0;
    while (offset < text.len) {
        var length: sb.SBUInteger = 0;
        var separator: sb.SBUInteger = 0;
        sb.SBAlgorithmGetParagraphBoundary(algorithm, offset, text.len - offset, &length, &separator);
        std.debug.assert(length != 0 and length <= text.len - offset);
        const paragraph = sb.SBAlgorithmCreateParagraph(algorithm, offset, length, direction.sheenbidi()) orelse return error.OutOfMemory;
        defer sb.SBParagraphRelease(paragraph);
        std.debug.assert(sb.SBParagraphGetLength(paragraph) == length);
        @memcpy(levels[offset..][0..length], sb.SBParagraphGetLevelsPtr(paragraph)[0..length]);
        try paragraphs.append(allocator, .{
            .start = @intCast(offset),
            .end = @intCast(offset + length),
            .separator_len = @intCast(separator),
            .base_level = sb.SBParagraphGetBaseLevel(paragraph),
        });
        offset += length;
    }
    return .{ .paragraphs = try paragraphs.toOwnedSlice(allocator), .levels = levels, .classes = classes };
}

/// Applies rule L1 to one line of a paragraph: `levels` and `classes` are the
/// line's slices of `Analysis.levels` and `Analysis.classes`, and `out`
/// receives the line's levels. Separators, whitespace before them, and
/// trailing whitespace take the paragraph level.
pub fn lineLevels(levels: []const u8, classes: []const LineClass, base_level: u8, out: []u8) void {
    std.debug.assert(levels.len == classes.len and out.len == levels.len);
    @memcpy(out, levels);
    var reset = true; // at the end of the line
    var i = levels.len;
    while (i != 0) {
        i -= 1;
        switch (classes[i]) {
            .separator => {
                out[i] = base_level;
                reset = true;
            },
            .whitespace => if (reset) {
                out[i] = base_level;
            },
            .other => reset = false,
        }
    }
}

/// Rule L2: fills `order` with the visual left-to-right order of items
/// (characters or runs) that have the given levels. `order[i]` is the
/// logical index shown at visual position `i`.
pub fn reorder(levels: []const u8, order: []u32) void {
    std.debug.assert(order.len == levels.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    if (levels.len == 0) return;
    var highest: u8 = 0;
    var lowest_odd: u8 = std.math.maxInt(u8);
    for (levels) |level| {
        highest = @max(highest, level);
        if (level & 1 != 0) lowest_odd = @min(lowest_odd, level);
    }
    var level = highest;
    while (level >= lowest_odd and level != 0) : (level -= 1) {
        var i: usize = 0;
        while (i < order.len) {
            if (levels[order[i]] < level) {
                i += 1;
                continue;
            }
            var end = i + 1;
            while (end < order.len and levels[order[end]] >= level) end += 1;
            std.mem.reverse(u32, order[i..end]);
            i = end;
        }
    }
}

test "levels of mixed-direction text, per byte" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try analyze(arena.allocator(), "abc אבג", .auto_ltr);
    try std.testing.expectEqual(1, result.paragraphs.len);
    try std.testing.expectEqual(0, result.paragraphs[0].base_level);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1 }, result.levels);
}

test "paragraph separators and base directions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = try analyze(arena.allocator(), "one\r\nשתיים\n", .auto_ltr);
    try std.testing.expectEqual(2, a.paragraphs.len);
    try std.testing.expectEqual(Paragraph{ .start = 0, .end = 5, .separator_len = 2, .base_level = 0 }, a.paragraphs[0]);
    try std.testing.expectEqual(Paragraph{ .start = 5, .end = 16, .separator_len = 1, .base_level = 1 }, a.paragraphs[1]);

    const neutral = try analyze(arena.allocator(), "123", .auto_rtl);
    try std.testing.expectEqual(1, neutral.paragraphs[0].base_level);
    const empty = try analyze(arena.allocator(), "", .rtl);
    try std.testing.expectEqual(1, empty.paragraphs[0].base_level);
}

test "L1 resets trailing whitespace of a wrapped line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = "abc אבג דהו";
    const result = try analyze(arena.allocator(), text, .ltr);
    // The space between the Hebrew words is level 1 inside the paragraph...
    try std.testing.expectEqual(1, result.levels[10]);
    // ...and level 0 at the end of a line that breaks after it.
    var out: [11]u8 = undefined;
    lineLevels(result.levels[0..11], result.classes[0..11], 0, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0 }, &out);
}

/// Runs one conformance case: `text` is a single paragraph; `expected_levels`
/// holds null for characters removed by X9.
fn checkCase(
    allocator: std.mem.Allocator,
    text: []const u8,
    direction: BaseDirection,
    expected_paragraph_level: ?u8,
    expected_levels: []const ?u8,
    expected_order: []const u32,
) !bool {
    const result = try analyze(allocator, text, direction);
    if (result.paragraphs.len != 1) return false;
    const base = result.paragraphs[0].base_level;
    if (expected_paragraph_level) |level| if (level != base) return false;
    const line = try allocator.alloc(u8, text.len);
    lineLevels(result.levels, result.classes, base, line);

    // Per code point levels, skipping X9-removed characters.
    var kept_levels: std.ArrayList(u8) = .empty;
    var kept_index: std.ArrayList(u32) = .empty;
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    var index: u32 = 0;
    while (iterator.nextCodepointSlice()) |slice| : (index += 1) {
        const offset = slice.ptr - text.ptr;
        const expected = expected_levels[index] orelse continue;
        if (line[offset] != expected) return false;
        try kept_levels.append(allocator, line[offset]);
        try kept_index.append(allocator, index);
    }
    const order = try allocator.alloc(u32, kept_levels.items.len);
    reorder(kept_levels.items, order);
    if (order.len != expected_order.len) return false;
    for (order, expected_order) |visual, expected| if (kept_index.items[visual] != expected) return false;
    return true;
}

test "UAX #9 conformance (BidiCharacterTest-18.0.0)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var lines = std.mem.splitScalar(u8, @embedFile("BidiCharacterTest.txt"), '\n');
    var line_number: usize = 0;
    var count: usize = 0;
    var failures: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        if (line.len == 0 or line[0] == '#') continue;
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var fields = std.mem.splitScalar(u8, line, ';');
        var text: std.ArrayList(u8) = .empty;
        var codepoints = std.mem.tokenizeScalar(u8, fields.next().?, ' ');
        while (codepoints.next()) |token| {
            var buffer: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(try std.fmt.parseInt(u21, token, 16), &buffer);
            try text.appendSlice(a, buffer[0..len]);
        }
        const direction: BaseDirection = switch (fields.next().?[0]) {
            '0' => .ltr,
            '1' => .rtl,
            else => .auto_ltr,
        };
        const paragraph_level = try std.fmt.parseInt(u8, fields.next().?, 10);
        var levels: std.ArrayList(?u8) = .empty;
        var level_tokens = std.mem.tokenizeScalar(u8, fields.next().?, ' ');
        while (level_tokens.next()) |token|
            try levels.append(a, if (token[0] == 'x') null else try std.fmt.parseInt(u8, token, 10));
        var order: std.ArrayList(u32) = .empty;
        var order_tokens = std.mem.tokenizeScalar(u8, fields.next().?, ' ');
        while (order_tokens.next()) |token| try order.append(a, try std.fmt.parseInt(u32, token, 10));

        count += 1;
        if (!try checkCase(a, text.items, direction, paragraph_level, levels.items, order.items)) {
            if (failures < 10) std.debug.print("BidiCharacterTest.txt:{d} fails\n", .{line_number});
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
    try std.testing.expect(count > 90_000);
}

test "UAX #9 conformance (BidiTest-18.0.0)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // One representative code point per Bidi_Class.
    const samples = std.StaticStringMap(u21).initComptime(.{
        .{ "L", 'a' },       .{ "R", 0x05D0 },    .{ "AL", 0x0627 },  .{ "EN", '1' },
        .{ "ES", '+' },      .{ "ET", '$' },      .{ "AN", 0x0660 },  .{ "CS", ',' },
        .{ "NSM", 0x0300 },  .{ "BN", 0x00AD },   .{ "B", 0x2029 },   .{ "S", '\t' },
        .{ "WS", ' ' },      .{ "ON", '!' },      .{ "LRE", 0x202A }, .{ "RLE", 0x202B },
        .{ "PDF", 0x202C },  .{ "LRO", 0x202D },  .{ "RLO", 0x202E }, .{ "LRI", 0x2066 },
        .{ "RLI", 0x2067 },  .{ "FSI", 0x2068 },  .{ "PDI", 0x2069 },
    });
    var lines = std.mem.splitScalar(u8, @embedFile("BidiTest.txt"), '\n');
    var levels: std.ArrayList(?u8) = .empty;
    defer levels.deinit(std.testing.allocator);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(std.testing.allocator);
    var line_number: usize = 0;
    var count: usize = 0;
    var failures: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "@Levels:")) {
            levels.clearRetainingCapacity();
            var tokens = std.mem.tokenizeAny(u8, line["@Levels:".len..], " \t");
            while (tokens.next()) |token|
                try levels.append(std.testing.allocator, if (token[0] == 'x') null else try std.fmt.parseInt(u8, token, 10));
            continue;
        }
        if (std.mem.startsWith(u8, line, "@Reorder:")) {
            order.clearRetainingCapacity();
            var tokens = std.mem.tokenizeAny(u8, line["@Reorder:".len..], " \t");
            while (tokens.next()) |token| try order.append(std.testing.allocator, try std.fmt.parseInt(u32, token, 10));
            continue;
        }
        if (line[0] == '@') continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const classes = fields.next().?;
        const bitset = try std.fmt.parseInt(u8, std.mem.trim(u8, fields.next().?, " \t"), 16);
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var text: std.ArrayList(u8) = .empty;
        var tokens = std.mem.tokenizeAny(u8, classes, " \t");
        while (tokens.next()) |token| {
            var buffer: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(samples.get(token).?, &buffer);
            try text.appendSlice(a, buffer[0..len]);
        }
        for ([_]BaseDirection{ .auto_ltr, .ltr, .rtl }, 0..) |direction, bit| {
            if (bitset & (@as(u8, 1) << @intCast(bit)) == 0) continue;
            count += 1;
            if (!try checkCase(a, text.items, direction, null, levels.items, order.items)) {
                if (failures < 10) std.debug.print("BidiTest.txt:{d} ({s}) fails\n", .{ line_number, @tagName(direction) });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(0, failures);
    try std.testing.expect(count > 400_000);
}
