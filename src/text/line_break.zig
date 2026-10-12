//! UAX #14 (Unicode 18.0, revision 57) default line-break opportunities.
//!
//! The rules are ported from ourokit's Unicode 17 scanner, whose transcription
//! was informed by cto-af/linebreak at 088ff02 (MIT, Joe Hildebrand). The
//! revision 57 change to LB12a (no break between BA and GL) is applied. The
//! official conformance file is authoritative and runs as a test.
//!
//! Choosing actual line ends is a separate, measured stage (layout.zig).

const std = @import("std");
const uucode = @import("uucode");

const Class = uucode.TypeOf(.line_break);
const GeneralCategory = uucode.TypeOf(.general_category);
const EastAsianWidth = uucode.TypeOf(.east_asian_width);

/// A position after which a line may (or must) end.
pub const Opportunity = struct {
    /// UTF-8 byte offset after the preceding code point.
    offset: u32,
    mandatory: bool,
};

const Sentinel = enum { scalar, start, end };

const Character = struct {
    codepoint: u21 = 0,
    class: Class = .xx,
    category: GeneralCategory = .other_not_assigned,
    east_asian_width: EastAsianWidth = .neutral,
    extended_pictographic: bool = false,
    byte_end: u32 = 0,
    index: u32 = 0,
    sentinel: Sentinel = .scalar,
    ignored: bool = false,
    /// LB9 absorbed a trailing ZWJ into this character (LB8a still applies).
    ends_with_zwj: bool = false,

    fn initialPunctuation(self: Character) bool {
        return self.sentinel == .scalar and self.category == .punctuation_initial_quote;
    }

    fn finalPunctuation(self: Character) bool {
        return self.sentinel == .scalar and self.category == .punctuation_final_quote;
    }

    fn eastAsian(self: Character) bool {
        return self.sentinel == .scalar and switch (self.east_asian_width) {
            .fullwidth, .wide, .halfwidth => true,
            else => false,
        };
    }
};

const Decision = enum { no_break, allowed, mandatory };

const State = struct {
    characters: []const Character,
    previous: Character,
    current: Character,
    next: Character,
    last_break: u32 = 0,
    after_zero_width_space: bool = false,
    suppress_spaces: bool = false,
    /// Consecutive regional indicators ending at `current` (LB30a).
    regional_indicators: usize = 0,

    fn push(self: *State, character: Character) void {
        if (self.next.ignored) {
            self.current.byte_end = self.next.byte_end;
            self.current.ends_with_zwj = self.next.class == .zwj;
        } else {
            self.previous = self.current;
            self.current = self.next;
            self.regional_indicators = if (self.current.class == .ri) self.regional_indicators + 1 else 0;
        }
        self.next = character;
    }

    fn afterNext(self: *const State, distance: usize) ?Character {
        if (self.next.sentinel == .end) return null;
        const index = self.next.index + distance;
        return if (index < self.characters.len) self.characters[index] else null;
    }

    fn classAfterSpaces(self: *const State) ?Class {
        if (self.next.sentinel == .end) return null;
        var index: usize = self.next.index;
        while (index < self.characters.len) : (index += 1) {
            const class = if (index == self.next.index) self.next.class else self.characters[index].class;
            if (class != .sp) return class;
        }
        return null;
    }

    fn numericBefore(self: *const State, start_index: usize) bool {
        var index = start_index;
        while (self.classBefore(&index)) |class| switch (class) {
            .sy, .is => continue,
            .nu => return true,
            else => return false,
        };
        return false;
    }

    fn classBefore(self: *const State, index: *usize) ?Class {
        if (index.* == 0) return null;
        if (self.next.sentinel != .end and index.* == self.next.index) {
            index.* = self.current.index;
            return if (self.current.sentinel == .scalar) self.current.class else null;
        }
        if (self.next.sentinel == .end and index.* == self.characters.len) {
            index.* = self.current.index;
            return if (self.current.sentinel == .scalar) self.current.class else null;
        }
        if (self.current.sentinel == .scalar and index.* == self.current.index) {
            index.* = self.previous.index;
            return if (self.previous.sentinel == .scalar) self.previous.class else null;
        }
        index.* -= 1;
        return self.characters[index.*].class;
    }
};

/// Returns every default UAX #14 opportunity in increasing offset order, in
/// linear time. The last opportunity is always the mandatory break at the end
/// of the text (also for empty text). `text` must be valid UTF-8 shorter than
/// 4 GiB. Scratch memory is freed before returning; pass an arena.
pub fn analyze(allocator: std.mem.Allocator, text: []const u8) ![]Opportunity {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    const characters = try allocator.alloc(Character, text.len);
    defer allocator.free(characters);
    var count: u32 = 0;
    var iterator = uucode.utf8.Iterator.init(text);
    while (iterator.next()) |codepoint| : (count += 1) {
        const category = uucode.get(.general_category, codepoint);
        characters[count] = .{
            .codepoint = codepoint,
            .class = resolveClass(uucode.get(.line_break, codepoint), category),
            .category = category,
            .east_asian_width = uucode.get(.east_asian_width, codepoint),
            .extended_pictographic = uucode.get(.is_extended_pictographic, codepoint),
            .byte_end = @intCast(iterator.i),
            .index = count,
        };
    }

    var breaks: std.ArrayList(Opportunity) = .empty;
    errdefer breaks.deinit(allocator);
    const start: Character = .{ .sentinel = .start };
    var state: State = .{
        .characters = characters[0..count],
        .previous = start,
        .current = start,
        .next = start,
    };
    for (characters[0..count]) |character| {
        state.push(character);
        try record(allocator, &breaks, &state, decide(&state));
    }
    state.push(.{ .byte_end = @intCast(text.len), .index = count, .sentinel = .end });
    try record(allocator, &breaks, &state, decide(&state));
    return breaks.toOwnedSlice(allocator);
}

fn record(allocator: std.mem.Allocator, output: *std.ArrayList(Opportunity), state: *State, decision: Decision) !void {
    if (decision == .no_break) return;
    try output.append(allocator, .{ .offset = state.current.byte_end, .mandatory = decision == .mandatory });
    state.last_break = state.current.byte_end;
}

/// LB1: resolve classes that have no rule of their own.
fn resolveClass(class: Class, category: GeneralCategory) Class {
    return switch (class) {
        .ai, .sg, .xx => .al,
        .sa => switch (category) {
            .mark_nonspacing, .mark_spacing_combining => .cm,
            else => .al,
        },
        .cj => .ns,
        else => class,
    };
}

fn decide(state: *State) Decision {
    const previous = state.previous;
    const current = &state.current;
    const next = &state.next;

    // LB2-LB6
    if (current.sentinel == .start and next.sentinel != .end) return .no_break;
    if (next.sentinel == .end and (current.byte_end == 0 or current.byte_end != state.last_break))
        return .mandatory;
    if (current.class == .bk) return .mandatory;
    if (current.class == .cr) return if (next.class == .lf) .no_break else .mandatory;
    if (current.class == .lf or current.class == .nl) return .mandatory;
    if (next.class == .bk or next.class == .cr or next.class == .lf or next.class == .nl)
        return .no_break;

    if (state.suppress_spaces) {
        if (next.class != .sp) state.suppress_spaces = false;
        return .no_break;
    }

    // LB7-LB10
    if (next.class == .zw) return .no_break;
    if (next.class == .sp and current.class != .zw and current.class != .op and
        current.class != .qu and current.class != .cl and current.class != .cp and
        current.class != .b2) return .no_break;
    if (state.after_zero_width_space) {
        state.after_zero_width_space = false;
        return .allowed;
    } else if (current.class == .zw) {
        if (next.class == .sp) state.after_zero_width_space = true;
        return if (next.class == .sp) .no_break else .allowed;
    }
    if (current.class == .zwj) return .no_break;
    if (!isHardOrSpace(current.class) and (next.class == .cm or next.class == .zwj)) {
        next.ignored = true;
        return .no_break;
    }
    if (current.ends_with_zwj) return .no_break;
    if (current.class == .cm) current.class = .al;
    if (next.class == .cm) next.class = .al;

    // LB11-LB14. LB12a: [^SP HY HH] × GL (revision 57 removed BA).
    if (current.class == .wj or next.class == .wj) return .no_break;
    if (current.class == .gl) return .no_break;
    if (next.class == .gl and current.class != .sp and current.class != .hy and
        current.class != .hh) return .no_break;
    if (next.class == .cl or next.class == .cp or next.class == .ex or next.class == .sy)
        return .no_break;
    if (current.class == .op) {
        if (next.class == .sp) state.suppress_spaces = true;
        return .no_break;
    }

    // LB15a-LB17
    if (isLb15aPrefix(previous) and current.class == .qu and current.initialPunctuation()) {
        if (next.class == .sp) state.suppress_spaces = true;
        return .no_break;
    }
    if (next.class == .qu and next.finalPunctuation()) {
        const after = state.afterNext(1);
        if (after == null or isLb15bSuffix(after.?.class)) return .no_break;
    }
    if (current.class == .sp and next.class == .is and
        if (state.afterNext(1)) |after| after.class == .nu else false) return .allowed;
    if (next.class == .is) return .no_break;
    if (current.class == .cl or current.class == .cp) {
        if (state.classAfterSpaces() == .ns) {
            if (next.class == .sp) state.suppress_spaces = true;
            return .no_break;
        }
        if (next.class == .sp) return .no_break;
    }
    if (current.class == .b2) {
        if (state.classAfterSpaces() == .b2) {
            if (next.class == .sp) state.suppress_spaces = true;
            return .no_break;
        }
        if (next.class == .sp) return .no_break;
    }

    // LB18-LB20
    if (current.class == .sp) return .allowed;
    if (next.class == .qu and !next.initialPunctuation()) return .no_break;
    if (current.class == .qu and !current.finalPunctuation()) return .no_break;
    if (!current.eastAsian() and next.class == .qu) return .no_break;
    if (next.class == .qu) {
        const after = state.afterNext(1);
        if (after == null or !after.?.eastAsian()) return .no_break;
    }
    if (current.class == .qu and !next.eastAsian()) return .no_break;
    if ((previous.sentinel == .start or !previous.eastAsian()) and current.class == .qu)
        return .no_break;
    if (current.class == .cb or next.class == .cb) return .allowed;

    // LB20a-LB24
    if (isWordStart(previous) and (current.class == .hy or current.class == .hh) and
        (next.class == .al or next.class == .hl)) return .no_break;
    if (previous.class == .hl and (current.class == .hy or current.class == .hh) and
        next.class != .hl) return .no_break;
    if (current.class == .bb or next.class == .ba or next.class == .hh or
        next.class == .hy or next.class == .ns) return .no_break;
    if (current.class == .sy and next.class == .hl) return .no_break;
    if (next.class == .in) return .no_break;
    if ((isAlphabetic(current.class) and next.class == .nu) or
        (current.class == .nu and isAlphabetic(next.class))) return .no_break;
    if ((current.class == .pr and isIdeographicEmoji(next.class)) or
        (isIdeographicEmoji(current.class) and next.class == .po)) return .no_break;
    if ((isPrefixPostfix(current.class) and isAlphabetic(next.class)) or
        (isAlphabetic(current.class) and isPrefixPostfix(next.class))) return .no_break;

    // LB25
    if (isPrefixPostfix(next.class)) {
        const start_index: usize = if (current.class == .cl or current.class == .cp) current.index else next.index;
        if (state.numericBefore(start_index)) return .no_break;
    } else if (next.class == .nu and state.numericBefore(next.index)) {
        return .no_break;
    }
    if (isPrefixPostfix(current.class)) {
        if (next.class == .nu) return .no_break;
        if (next.class == .op) {
            if (state.afterNext(1)) |after| {
                if (after.class == .nu) return .no_break;
                if (after.class == .is and
                    if (state.afterNext(2)) |second| second.class == .nu else false)
                    return .no_break;
            }
        }
    }
    if ((current.class == .hy or current.class == .is) and next.class == .nu)
        return .no_break;

    // LB26-LB28a
    if ((current.class == .jl and isOneOf(next.class, &.{ .jl, .jv, .h2, .h3 })) or
        (isOneOf(current.class, &.{ .jv, .h2 }) and isOneOf(next.class, &.{ .jv, .jt })) or
        (isOneOf(current.class, &.{ .jt, .h3 }) and next.class == .jt)) return .no_break;
    if ((isHangul(current.class) and next.class == .po) or
        (current.class == .pr and isHangul(next.class))) return .no_break;
    if (isAlphabetic(current.class) and isAlphabetic(next.class)) return .no_break;
    if (current.class == .ap and isAkCircleAs(next.*)) return .no_break;
    if (isAkCircleAs(current.*) and (next.class == .vf or next.class == .vi)) return .no_break;
    if (isAkCircleAs(previous) and current.class == .vi and
        (next.class == .ak or next.codepoint == 0x25cc)) return .no_break;
    if (isAkCircleAs(current.*) and isAkCircleAs(next.*) and
        if (state.afterNext(1)) |after| after.class == .vf else false) return .no_break;

    // LB29-LB31
    if (current.class == .is and isAlphabetic(next.class)) return .no_break;
    if (isOneOf(current.class, &.{ .al, .hl, .nu }) and next.class == .op and
        !next.eastAsian()) return .no_break;
    if (current.class == .cp and !current.eastAsian() and
        isOneOf(next.class, &.{ .al, .hl, .nu })) return .no_break;
    if (current.class == .ri and next.class == .ri and state.regional_indicators & 1 != 0)
        return .no_break;
    if ((current.class == .eb or
        (current.category == .other_not_assigned and current.extended_pictographic)) and
        next.class == .em) return .no_break;
    return .allowed;
}

fn isHardOrSpace(class: Class) bool {
    return isOneOf(class, &.{ .bk, .cr, .lf, .nl, .sp, .zw });
}

fn isLb15aPrefix(character: Character) bool {
    return character.sentinel == .start or isOneOf(character.class, &.{
        .bk, .cr, .lf, .nl, .op, .qu, .gl, .sp, .zw,
    });
}

fn isLb15bSuffix(class: Class) bool {
    return isOneOf(class, &.{
        .sp, .gl, .wj, .cl, .qu, .cp, .ex, .is, .sy, .bk, .cr, .lf, .nl, .zw,
    });
}

fn isWordStart(character: Character) bool {
    return character.sentinel == .start or isOneOf(character.class, &.{
        .bk, .cr, .lf, .nl, .sp, .zw, .cb, .gl,
    });
}

fn isAlphabetic(class: Class) bool {
    return class == .al or class == .hl;
}

fn isIdeographicEmoji(class: Class) bool {
    return class == .id or class == .eb or class == .em;
}

fn isPrefixPostfix(class: Class) bool {
    return class == .pr or class == .po;
}

fn isHangul(class: Class) bool {
    return isOneOf(class, &.{ .jl, .jv, .jt, .h2, .h3 });
}

fn isAkCircleAs(character: Character) bool {
    return character.class == .ak or character.codepoint == 0x25cc or character.class == .as;
}

fn isOneOf(class: Class, comptime values: []const Class) bool {
    inline for (values) |value| if (class == value) return true;
    return false;
}

test "opportunities are UTF-8 offsets after the preceding code point" {
    const breaks = try analyze(std.testing.allocator, "hello world\nnext");
    defer std.testing.allocator.free(breaks);
    try std.testing.expectEqualSlices(Opportunity, &.{
        .{ .offset = 6, .mandatory = false },
        .{ .offset = 12, .mandatory = true },
        .{ .offset = 16, .mandatory = true },
    }, breaks);

    const empty = try analyze(std.testing.allocator, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualSlices(Opportunity, &.{.{ .offset = 0, .mandatory = true }}, empty);
}

test "revision 57: no break between EN DASH and NO-BREAK SPACE" {
    // U+2013 is BA in Unicode 18; LB12a no longer allows BA ÷ GL.
    const breaks = try analyze(std.testing.allocator, "a\u{2013}\u{00A0}b");
    defer std.testing.allocator.free(breaks);
    try std.testing.expectEqual(1, breaks.len);
}

test "UAX #14 conformance (LineBreakTest-18.0.0)" {
    const gpa = std.testing.allocator;
    var cases = @import("ucd_test.zig").Cases.init(@embedFile("LineBreakTest.txt"));
    defer cases.deinit(gpa);
    var count: usize = 0;
    while (try cases.next(gpa)) |case| : (count += 1) {
        const actual = try analyze(gpa, case.utf8);
        defer gpa.free(actual);
        const matches = actual.len == case.breaks.len and for (actual, case.breaks) |a, e| {
            if (a.offset != e) break false;
        } else true;
        if (!matches) {
            std.debug.print("LineBreakTest.txt:{d}: expected {any}, got {any}\n", .{ case.line_number, case.breaks, actual });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(count > 19_000);
}
