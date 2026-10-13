//! Styled ranges of text and editor nodes (D22): edits move them, style
//! changes split and merge them. Lists stay normalized: sorted, disjoint,
//! not empty, none with the default style, equal neighbors merged.

const std = @import("std");
const node_mod = @import("node.zig");

const Span = node_mod.Span;
const SpanStyle = node_mod.SpanStyle;
const ParagraphSpan = node_mod.ParagraphSpan;
const Allocator = std.mem.Allocator;

// The functions take character spans (`Span`) or paragraph spans
// (`ParagraphSpan`): ranges with a style that has isDefault, eql, and
// patched.

fn Elem(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) p.child else Elem(p.child),
        .array => |a| a.child,
        else => @compileError("not a list of spans"),
    };
}

fn StyleOf(comptime T: type) type {
    return @FieldType(Elem(T), "style");
}

/// The style at byte `offset`: of the span containing it, else default.
pub fn styleAt(spans: anytype, offset: u32) StyleOf(@TypeOf(spans)) {
    return (runAt(spans, offset, std.math.maxInt(u32))).style;
}

/// The run containing `offset` in text of length `len`: a span, or the
/// unstyled stretch between spans.
pub fn runAt(spans: anytype, offset: u32, len: u32) Elem(@TypeOf(spans)) {
    var start: u32 = 0;
    for (spans) |s| {
        if (offset < s.start) return .{ .start = start, .end = s.start, .style = .{} };
        if (offset < s.end) return s;
        start = s.end;
    }
    return .{ .start = @min(start, len), .end = len, .style = .{} };
}

/// The style text inserted at `at` takes without a typing style: that of
/// the character before, or at the start that of the one after.
pub fn inherited(spans: anytype, at: u32) StyleOf(@TypeOf(spans)) {
    return styleAt(spans, if (at > 0) at - 1 else 0);
}

/// Whether `spans` is a valid list for text `content`.
pub fn valid(content: []const u8, spans: anytype) bool {
    var prev: u32 = 0;
    for (spans) |s| {
        if (s.start < prev or s.end <= s.start or s.end > content.len) return false;
        for ([_]u32{ s.start, s.end }) |o| if (o < content.len and content[o] & 0xc0 == 0x80) return false;
        prev = s.end;
    }
    return true;
}

/// Drops default and empty spans and merges equal neighbors, in place.
pub fn normalize(list: anytype) void {
    var out: usize = 0;
    for (list.items) |s| {
        if (s.end <= s.start or s.style.isDefault()) continue;
        if (out > 0 and list.items[out - 1].end == s.start and list.items[out - 1].style.eql(s.style)) {
            list.items[out - 1].end = s.end;
            continue;
        }
        list.items[out] = s;
        out += 1;
    }
    list.shrinkRetainingCapacity(out);
}

/// The spans after `start..end` is replaced by `inserted` bytes that take
/// `style`.
pub fn replaced(a: Allocator, spans: anytype, start: u32, end: u32, inserted: u32, style: StyleOf(@TypeOf(spans))) Allocator.Error![]Elem(@TypeOf(spans)) {
    const S = Elem(@TypeOf(spans));
    var list: std.ArrayList(S) = .empty;
    try list.ensureTotalCapacity(a, spans.len + 2);
    const removed = end - start;
    for (spans) |s| {
        // Before the edit, the part in front of it.
        if (s.start < start) list.appendAssumeCapacity(.{ .start = s.start, .end = @min(s.end, start), .style = s.style });
    }
    list.appendAssumeCapacity(.{ .start = start, .end = start + inserted, .style = style });
    for (spans) |s| {
        if (s.end > end) list.appendAssumeCapacity(.{ .start = @max(s.start, end) - removed + inserted, .end = s.end - removed + inserted, .style = s.style });
    }
    normalize(&list);
    return list.items;
}

/// The spans after the attributes in `mask` are set to those of `values`
/// over `lo..hi` of text of length `len`.
pub fn restyled(a: Allocator, spans: anytype, len: u32, lo: u32, hi: u32, values: StyleOf(@TypeOf(spans)), mask: StyleOf(@TypeOf(spans)).Mask) Allocator.Error![]Elem(@TypeOf(spans)) {
    const S = Elem(@TypeOf(spans));
    var list: std.ArrayList(S) = .empty;
    try list.ensureTotalCapacity(a, 2 * spans.len + 3);
    var at: u32 = 0;
    while (at < len) {
        const run = runAt(spans, at, len);
        // Split the run at the edges of the range.
        const end = if (at < lo) @min(run.end, lo) else if (at < hi) @min(run.end, hi) else run.end;
        const inside = at >= lo and at < hi;
        list.appendAssumeCapacity(.{ .start = at, .end = end, .style = if (inside) run.style.patched(values, mask) else run.style });
        at = end;
    }
    normalize(&list);
    return list.items;
}

/// Whether every character of `lo..hi` has `pred` true of its style.
pub fn all(spans: []const Span, len: u32, lo: u32, hi: u32, comptime pred: fn (SpanStyle) bool) bool {
    var at = lo;
    while (at < hi) {
        const run = runAt(spans, at, len);
        if (!pred(run.style)) return false;
        at = @max(run.end, at + 1);
    }
    return true;
}

/// Paragraph separators: Bidi_Class B, which end bidi paragraphs (D13).
fn separatorLen(content: []const u8, i: usize) usize {
    const c = content[i];
    if (c == '\r') return if (i + 1 < content.len and content[i + 1] == '\n') 2 else 1;
    if (c == '\n' or (c >= 0x1c and c <= 0x1e)) return 1;
    if (std.mem.startsWith(u8, content[i..], "\u{85}") or std.mem.startsWith(u8, content[i..], "\u{2029}")) return std.unicode.utf8ByteSequenceLength(c) catch 1;
    return 0;
}

/// The paragraph around byte `offset`: from the start of its first
/// character to the end of its separator (or the text).
pub fn paragraphAt(content: []const u8, offset: u32) struct { start: u32, end: u32 } {
    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        const sep = separatorLen(content, i);
        if (sep == 0) {
            i += 1;
            continue;
        }
        if (offset < i + sep) return .{ .start = @intCast(start), .end = @intCast(i + sep) };
        i += sep;
        start = i;
    }
    return .{ .start = @intCast(start), .end = @intCast(content.len) };
}

/// Paragraph spans snapped to whole paragraphs: each paragraph takes the
/// style at its first byte.
pub fn snapped(a: Allocator, content: []const u8, spans: []const ParagraphSpan) Allocator.Error![]ParagraphSpan {
    var list: std.ArrayList(ParagraphSpan) = .empty;
    if (spans.len == 0) return list.items;
    var at: u32 = 0;
    while (true) {
        const p = paragraphAt(content, at);
        try list.append(a, .{ .start = p.start, .end = p.end, .style = styleAt(spans, p.start) });
        if (p.end >= content.len) break;
        at = p.end;
    }
    normalize(&list);
    return list.items;
}

const testing = std.testing;

fn bold() SpanStyle {
    return .{ .weight = .bold };
}

test "replacing text moves, shrinks, and drops spans; inserted text takes the given style" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "abcdefgh" with cde bold and g underlined.
    const spans = [_]Span{ .{ .start = 2, .end = 5, .style = bold() }, .{ .start = 6, .end = 7, .style = .{ .underline = true } } };
    // Delete d..f (3..6): bold shrinks to c, the underline moves to 3.
    try testing.expectEqualDeep(&[_]Span{ .{ .start = 2, .end = 3, .style = bold() }, .{ .start = 3, .end = 4, .style = .{ .underline = true } } }, try replaced(a, &spans, 3, 6, 0, .{}));
    // Typing two bold bytes inside the bold span extends it.
    try testing.expectEqualDeep(&[_]Span{ .{ .start = 2, .end = 7, .style = bold() }, .{ .start = 8, .end = 9, .style = .{ .underline = true } } }, try replaced(a, &spans, 4, 4, 2, bold()));
    // Plain text over the whole bold span removes it.
    try testing.expectEqualDeep(&[_]Span{.{ .start = 4, .end = 5, .style = .{ .underline = true } }}, try replaced(a, &spans, 2, 5, 1, .{}));
    try testing.expectEqual(bold(), inherited(&spans, 5));
    try testing.expectEqual(SpanStyle{}, inherited(&spans, 2));
}

test "restyling a range splits spans at its edges and merges equal neighbors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spans = [_]Span{.{ .start = 2, .end = 5, .style = .{ .slant = .italic } }};
    // Bold over 4..8: italic 2..4, bold italic 4..5, bold 5..8.
    const out = try restyled(a, &spans, 10, 4, 8, bold(), .{ .weight = true });
    try testing.expectEqualDeep(&[_]Span{
        .{ .start = 2, .end = 4, .style = .{ .slant = .italic } },
        .{ .start = 4, .end = 5, .style = .{ .slant = .italic, .weight = .bold } },
        .{ .start = 5, .end = 8, .style = bold() },
    }, out);
    try testing.expect(all(out, 10, 4, 8, struct {
        fn f(s: SpanStyle) bool {
            return s.weight == .bold;
        }
    }.f));
    // Clearing the weight again leaves the italic in one piece.
    try testing.expectEqualDeep(&[_]Span{.{ .start = 2, .end = 5, .style = .{ .slant = .italic } }}, try restyled(a, out, 10, 0, 10, .{}, .{ .weight = true }));
    try testing.expect(valid("abcdefghij", out));
    try testing.expect(!valid("ab", out));
}
