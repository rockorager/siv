//! Caret, hit-test, movement, and selection queries on a Layout, for the
//! editor (D15). Everything derives from the layout's caret stops (the
//! cluster map), the paragraph's grapheme and word boundaries, and the
//! line base directions; there is no other text state.

const std = @import("std");
const layout_ = @import("layout.zig");

const Layout = layout_.Layout;
const Line = layout_.Line;
const Caret = layout_.Caret;
const Affinity = layout_.Affinity;
const Rect = layout_.Rect;

/// A caret position: a byte offset at a grapheme boundary, and which side it
/// attaches to where one offset has two visual positions.
pub const Position = struct {
    offset: u32,
    affinity: Affinity = .downstream,
};

/// Where to draw a caret, relative to the layout origin.
pub const CaretRect = struct {
    line: u32,
    x: f32,
    top: f32,
    height: f32,
};

const Stop = struct { line: u32, index: u32 };

/// Finds the caret stop for a position. Offsets inside a grapheme snap to
/// its start. An exact affinity match wins; otherwise any stop with the
/// offset (the first line for downstream, the last for upstream).
fn find(self: *const Layout, position: Position) Stop {
    const graphemes = self.paragraph.graphemes;
    const offset = graphemes.atOrBefore(@min(position.offset, graphemes.len)).?;
    var fallback: ?Stop = null;
    if (position.affinity == .downstream) {
        for (self.lines, 0..) |line, l| {
            if (offset < line.start or offset > line.end) continue;
            for (self.lineCarets(line), 0..) |stop, i| {
                if (stop.offset != offset) continue;
                const found: Stop = .{ .line = @intCast(l), .index = @intCast(i) };
                if (stop.affinity == .downstream) return found;
                if (fallback == null) fallback = found;
            }
        }
    } else {
        var l = self.lines.len;
        while (l != 0) {
            l -= 1;
            const line = self.lines[l];
            if (offset < line.start or offset > line.end) continue;
            const stops = self.lineCarets(line);
            var i = stops.len;
            while (i != 0) {
                i -= 1;
                if (stops[i].offset != offset) continue;
                const found: Stop = .{ .line = @intCast(l), .index = @intCast(i) };
                if (stops[i].affinity == .upstream) return found;
                if (fallback == null) fallback = found;
            }
        }
    }
    if (fallback) |stop| return stop;
    // Offsets without a stop (inside a separator): the end of their line.
    for (self.lines, 0..) |line, l| {
        if (offset >= line.start and (offset < line.end or l + 1 == self.lines.len)) {
            const stops = self.lineCarets(line);
            return .{ .line = @intCast(l), .index = if (line.rtl()) 0 else @intCast(stops.len - 1) };
        }
    }
    unreachable;
}

fn stopAt(self: *const Layout, stop: Stop) Caret {
    return self.lineCarets(self.lines[stop.line])[stop.index];
}

fn positionOf(caret_: Caret) Position {
    return .{ .offset = caret_.offset, .affinity = caret_.affinity };
}

pub fn caret(self: *const Layout, position: Position) CaretRect {
    const stop = find(self, position);
    const line = self.lines[stop.line];
    return .{ .line = stop.line, .x = line.x + stopAt(self, stop).x, .top = line.top, .height = line.height };
}

/// The line at vertical position `y` (clamped to the first and last
/// line); in the space between paragraphs, the nearer line.
pub fn lineAt(self: *const Layout, y: f32) u32 {
    var low: usize = 0;
    var high = self.lines.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (self.lines[middle].top <= y) low = middle + 1 else high = middle;
    }
    const i = low -| 1;
    if (i + 1 < self.lines.len) {
        const bottom = self.lines[i].top + self.lines[i].height;
        if (y > bottom and self.lines[i + 1].top - y < y - bottom) return @intCast(i + 1);
    }
    return @intCast(i);
}

/// The stop closest to `x` among a line's stops.
pub fn nearest(stops: []const Caret, x: f32) u32 {
    var low: usize = 0;
    var high = stops.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (stops[middle].x < x) low = middle + 1 else high = middle;
    }
    if (low == stops.len) return @intCast(stops.len - 1);
    if (low == 0) return 0;
    // Between two stops: the closer one. On a tie or an exact hit on a
    // shared edge, the stop that begins the right-hand grapheme.
    if (x - stops[low - 1].x < stops[low].x - x) return @intCast(low - 1);
    var i = low;
    while (i + 1 < stops.len and stops[i + 1].x - stops[low].x <= 0.001) i += 1;
    return @intCast(i);
}

/// The caret position closest to a point relative to the layout origin.
pub fn hitTest(self: *const Layout, x: f32, y: f32) Position {
    const line = self.lines[lineAt(self, y)];
    const stops = self.lineCarets(line);
    return positionOf(stops[nearest(stops, x - line.x)]);
}

pub fn nextGrapheme(self: *const Layout, offset: u32) u32 {
    return self.paragraph.graphemes.after(offset) orelse @intCast(self.paragraph.text.len);
}

pub fn previousGrapheme(self: *const Layout, offset: u32) u32 {
    return self.paragraph.graphemes.before(offset) orelse 0;
}

/// The end of the word at or after `offset` (word-wise forward movement).
pub fn nextWordEnd(self: *const Layout, offset: u32) u32 {
    const words = self.paragraph.words;
    var current = words.boundaries.atOrBefore(offset).?;
    while (words.boundaries.after(current)) |next| : (current = next) {
        if (words.starts.isSet(current) and next > offset) return next;
    }
    return @intCast(self.paragraph.text.len);
}

/// The start of the word before `offset` (word-wise backward movement).
pub fn previousWordStart(self: *const Layout, offset: u32) u32 {
    const words = self.paragraph.words;
    var current = words.boundaries.before(offset) orelse return 0;
    while (true) {
        if (words.starts.isSet(current)) return current;
        current = words.boundaries.before(current) orelse return 0;
    }
}

pub const Direction = enum { left, right };

/// Visual movement by one grapheme edge. Within a line the caret moves to
/// the next stop at a different x; past the line's end in its reading
/// direction it continues at the start of the next line, and before its
/// start at the end of the previous line.
pub fn moveVisual(self: *const Layout, position: Position, direction: Direction) Position {
    const stop = find(self, position);
    const line = self.lines[stop.line];
    const stops = self.lineCarets(line);
    const x = stops[stop.index].x;
    switch (direction) {
        .right => {
            var i = stop.index + 1;
            while (i < stops.len) : (i += 1) if (stops[i].x > x + 0.001) return positionOf(stops[i]);
        },
        .left => {
            var i = stop.index;
            while (i != 0) {
                i -= 1;
                if (stops[i].x < x - 0.001) return positionOf(stops[i]);
            }
        },
    }
    const forward = (direction == .right) != line.rtl();
    if (forward) {
        if (stop.line + 1 == self.lines.len) return positionOf(stops[stop.index]);
        return lineEdge(self, stop.line + 1, .start);
    }
    if (stop.line == 0) return positionOf(stops[stop.index]);
    return lineEdge(self, stop.line - 1, .end);
}

pub const Boundary = enum { start, end };

/// The start or end, in reading order, of line `line_index`.
pub fn lineEdge(self: *const Layout, line_index: u32, boundary: Boundary) Position {
    const line = self.lines[line_index];
    const stops = self.lineCarets(line);
    const left = (boundary == .start) != line.rtl();
    return positionOf(if (left) stops[0] else stops[stops.len - 1]);
}

/// The start or end of the position's line in reading order (Home, End).
pub fn lineBoundary(self: *const Layout, position: Position, boundary: Boundary) Position {
    return lineEdge(self, find(self, position).line, boundary);
}

pub const Vertical = enum { up, down };

pub const VerticalMove = struct {
    position: Position,
    /// Keep passing this back so the column survives shorter lines.
    x: f32,
};

/// Moves to the adjacent line at the preferred x (the caret's x when null).
pub fn moveVertical(self: *const Layout, position: Position, preferred_x: ?f32, direction: Vertical) VerticalMove {
    const stop = find(self, position);
    const line = self.lines[stop.line];
    const x = preferred_x orelse line.x + stopAt(self, stop).x;
    const target = switch (direction) {
        .up => if (stop.line == 0) return .{ .position = lineEdge(self, 0, .start), .x = x } else stop.line - 1,
        .down => if (stop.line + 1 == self.lines.len) return .{ .position = lineEdge(self, stop.line, .end), .x = x } else stop.line + 1,
    };
    const target_line = self.lines[target];
    const stops = self.lineCarets(target_line);
    return .{ .position = positionOf(stops[nearest(stops, x - target_line.x)]), .x = x };
}

/// Appends rectangles covering the graphemes in `start..end`, one per
/// visually contiguous fragment (a bidi selection can be discontiguous).
/// An empty line's selected separator shows as a box `empty.width(offset)`
/// wide, the width a block caret has there (an "x" in the line break's
/// font), or a quarter of the line's height where that is null or
/// `empty` is void.
pub fn selectionRects(self: *const Layout, gpa: std.mem.Allocator, start: u32, end: u32, out: *std.ArrayList(Rect), empty: anytype) !void {
    if (start >= end) return;
    for (self.lines) |line| {
        if (line.end <= start or line.start >= end) continue;
        const stops = self.lineCarets(line);
        const first_rect = out.items.len;
        if (stops.len == 1) {
            // An empty line shows its selected separator as a narrow box.
            if (line.end > line.start and start <= line.start and end >= line.end) {
                const w = (if (@TypeOf(empty) == void) null else empty.width(line.start)) orelse line.height / 4;
                try out.append(gpa, .{ .x = line.x + stops[0].x - if (line.rtl()) w else 0, .y = line.top, .width = w, .height = line.height });
            }
            continue;
        }
        var i: usize = 0;
        while (i + 1 < stops.len) : (i += 2) {
            const a = stops[i];
            const b = stops[i + 1];
            const lo = @min(a.offset, b.offset);
            const hi = @max(a.offset, b.offset);
            if (lo < start or hi > end) continue;
            const x = line.x + a.x;
            const width = b.x - a.x;
            if (out.items.len > first_rect) {
                const last = &out.items[out.items.len - 1];
                if (@abs(last.x + last.width - x) <= 0.001) {
                    last.width += width;
                    continue;
                }
            }
            try out.append(gpa, .{ .x = x, .y = line.top, .width = width, .height = line.height });
        }
    }
}

const paragraph_ = @import("paragraph.zig");
const Fixture = paragraph_.testing.Fixture;

fn layoutOf(fixture: *Fixture, p: *const paragraph_.ShapedParagraph, width: ?f32) !Layout {
    return Layout.init(std.testing.allocator, fixture.arena.allocator(), &fixture.cache, p, .{ .width = width });
}

test "carets and hit testing agree on left-to-right text" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("abc de", .auto_ltr);
    defer p.deinit();
    var l = try layoutOf(&fixture, &p, null);
    defer l.deinit();
    var previous: f32 = -1;
    for (0..7) |offset| {
        const rect = l.caret(.{ .offset = @intCast(offset) });
        try std.testing.expect(rect.x > previous);
        previous = rect.x;
        const hit = l.hitTest(rect.x + 0.01, 5);
        try std.testing.expectEqual(offset, hit.offset);
    }
    // Past either end clamps to the ends.
    try std.testing.expectEqual(0, l.hitTest(-50, 5).offset);
    try std.testing.expectEqual(6, l.hitTest(5000, 5).offset);
    try std.testing.expectEqual(6, l.hitTest(5000, 500).offset);
}

test "points in the space between paragraphs hit the nearer line" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("ab\ncd", .auto_ltr);
    defer p.deinit();
    const spaced: layout_.ParagraphStyle = .{ .space_before = 40 };
    var l = try Layout.init(std.testing.allocator, fixture.arena.allocator(), &fixture.cache, &p, .{ .paragraphs = &.{ .{ .end = 3, .style = .{} }, .{ .end = std.math.maxInt(u32), .style = spaced } } });
    defer l.deinit();
    const bottom = l.lines[0].top + l.lines[0].height;
    try std.testing.expect(l.lines[1].top > bottom + 30);
    try std.testing.expectEqual(0, l.lineAt(bottom + 5));
    try std.testing.expectEqual(1, l.lineAt(l.lines[1].top - 5));
    try std.testing.expectEqual(3, l.hitTest(0, l.lines[1].top - 5).offset);
}

test "visual movement crosses bidi boundaries once per visual position" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("abc אבג", .auto_ltr);
    defer p.deinit();
    var l = try layoutOf(&fixture, &p, null);
    defer l.deinit();
    var position: Position = .{ .offset = 0 };
    var offsets: [16]u32 = undefined;
    var count: usize = 0;
    var x = l.caret(position).x;
    while (true) {
        offsets[count] = position.offset;
        count += 1;
        const next = l.moveVisual(position, .right);
        const next_x = l.caret(next).x;
        if (next_x <= x) break;
        x = next_x;
        position = next;
    }
    // a b c space, then the Hebrew letters from the left: ג (8), ב (6), א.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 8, 6, 4 }, offsets[0..count]);
    // And back again.
    var back = position;
    for (0..count - 1) |_| back = l.moveVisual(back, .left);
    try std.testing.expectEqual(0, back.offset);
    // Logical movement ignores direction.
    try std.testing.expectEqual(6, l.nextGrapheme(4));
    try std.testing.expectEqual(4, l.previousGrapheme(6));
}

test "the two carets of a bidi boundary are told apart by affinity" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("abcאבג", .ltr);
    defer p.deinit();
    var l = try layoutOf(&fixture, &p, null);
    defer l.deinit();
    // Offset 3 ends "abc" (upstream, left of the Hebrew) and starts the
    // Hebrew word (downstream, at its right end).
    const upstream = l.caret(.{ .offset = 3, .affinity = .upstream });
    const downstream = l.caret(.{ .offset = 3, .affinity = .downstream });
    try std.testing.expect(downstream.x > upstream.x + 10);
    try std.testing.expectApproxEqAbs(l.lines[0].advance, downstream.x, 0.01);
}

test "line boundaries, vertical movement, and empty lines" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const text = "first line\n\nשורה שלישית\n";
    var p = try fixture.shape(text, .auto_ltr);
    defer p.deinit();
    var l = try layoutOf(&fixture, &p, 400);
    defer l.deinit();
    try std.testing.expectEqual(4, l.lines.len);
    // Home and End follow each line's direction.
    try std.testing.expectEqual(10, l.lineBoundary(.{ .offset = 3 }, .end).offset);
    try std.testing.expectEqual(0, l.lineBoundary(.{ .offset = 3 }, .start).offset);
    const rtl_end = l.lineBoundary(.{ .offset = 14 }, .end);
    try std.testing.expectEqual(text.len - 1, rtl_end.offset);
    try std.testing.expect(l.caret(rtl_end).x < l.caret(.{ .offset = 12 }).x);
    // Down from "first" goes through the empty line to the third line,
    // keeping the column.
    var move = l.moveVertical(.{ .offset = 2 }, null, .down);
    try std.testing.expectEqual(11, move.position.offset);
    move = l.moveVertical(move.position, move.x, .down);
    try std.testing.expectEqual(2, l.caret(move.position).line);
    // The end of the text, after the final newline, is its own line.
    try std.testing.expectEqual(3, l.caret(.{ .offset = @intCast(text.len) }).line);
    var empty = try fixture.shape("", .auto_rtl);
    defer empty.deinit();
    var empty_layout = try layoutOf(&fixture, &empty, 100);
    defer empty_layout.deinit();
    try std.testing.expectEqual(1, empty_layout.lines.len);
    try std.testing.expect(empty_layout.lines[0].height > 0);
    try std.testing.expectApproxEqAbs(100, empty_layout.caret(.{ .offset = 0 }).x, 0.01);
}

test "word movement and selection rectangles" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("can't stop now", .auto_ltr);
    defer p.deinit();
    var l = try layoutOf(&fixture, &p, null);
    defer l.deinit();
    try std.testing.expectEqual(5, l.nextWordEnd(0));
    try std.testing.expectEqual(10, l.nextWordEnd(5));
    try std.testing.expectEqual(10, l.nextWordEnd(7));
    try std.testing.expectEqual(6, l.previousWordStart(10));
    try std.testing.expectEqual(0, l.previousWordStart(6));
    try std.testing.expectEqual(14, l.nextWordEnd(14));

    var rects: std.ArrayList(Rect) = .empty;
    defer rects.deinit(std.testing.allocator);
    try l.selectionRects(std.testing.allocator, 0, 14, &rects, {});
    try std.testing.expectEqual(1, rects.items.len);
    try std.testing.expectApproxEqAbs(l.lines[0].advance, rects.items[0].width, 0.01);

    // A logical range across a bidi boundary is two visual fragments.
    var mixed = try fixture.shape("ab אבג", .ltr);
    defer mixed.deinit();
    var ml = try layoutOf(&fixture, &mixed, null);
    defer ml.deinit();
    rects.clearRetainingCapacity();
    try ml.selectionRects(std.testing.allocator, 1, 5, &rects, {});
    try std.testing.expectEqual(2, rects.items.len);
}
