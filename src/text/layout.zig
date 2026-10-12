//! Layout: a ShapedParagraph broken into lines at one width (D13).
//!
//! Greedy break selection runs over the paragraph's measured segments.
//! Where a chosen break is unsafe to break (HarfBuzz UNSAFE_TO_BREAK), the
//! line edges are reshaped inline from the nearest safe glyph boundary, and
//! the line is re-selected if the reshaped edge no longer fits. Each line
//! then gets UAX #9 L1 levels and L2 visual order, positioned glyph runs,
//! and caret stops (the cluster map) for hit testing and the editor (D15).
//!
//! A Layout owns one arena and borrows its ShapedParagraph, which must
//! outlive it.

const std = @import("std");
const hb = @import("harfbuzz");
const bidi = @import("bidi.zig");
const font_ = @import("font.zig");
const shape_ = @import("shape.zig");
const paragraph_ = @import("paragraph.zig");
const cursor = @import("cursor.zig");

const FontId = font_.FontId;
const FontCache = font_.FontCache;
const Glyph = shape_.Glyph;
const ShapedParagraph = paragraph_.ShapedParagraph;

pub const Alignment = enum { start, end, center };

pub const Options = struct {
    /// Available width in pixels; null lays out without wrapping.
    width: ?f32 = null,
    alignment: Alignment = .start,
};

/// A glyph positioned relative to its line's origin: x from the line's
/// left pen position, y from the baseline (down).
pub const PositionedGlyph = struct {
    id: u32,
    x: f32,
    y: f32,
    advance: f32,
    /// Byte offset of the glyph's cluster in the text.
    cluster: u32,
};

/// Glyphs of one font and size in visual order.
pub const GlyphRun = struct {
    font: FontId,
    size: f32,
    /// Index into `ShapedParagraph.styles`.
    style: u32,
    /// Logical byte range the glyphs cover.
    start: u32,
    end: u32,
    rtl: bool,
    /// Range in `Layout.glyphs`.
    glyph_start: u32,
    glyph_end: u32,
};

pub const Affinity = enum {
    /// Attached to the grapheme before the offset (its trailing edge).
    upstream,
    /// Attached to the grapheme after the offset (its leading edge).
    downstream,
};

/// A legal caret position: a grapheme edge. Each grapheme contributes two
/// stops (its leading and trailing edge), so one offset can have two stops
/// at a bidi boundary or a line wrap; affinity tells them apart.
pub const Caret = struct {
    offset: u32,
    /// From the line's left pen position.
    x: f32,
    affinity: Affinity,
};

pub const Line = struct {
    /// Byte range, including trailing whitespace and the separator.
    start: u32,
    end: u32,
    paragraph: u32,
    base_level: u8,
    /// Left pen position relative to the layout origin (from alignment).
    x: f32,
    /// Total advance, including hanging whitespace.
    advance: f32,
    /// Advance without the hanging whitespace at the line end.
    width: f32,
    top: f32,
    /// Baseline y relative to the layout origin.
    baseline: f32,
    ascent: f32,
    descent: f32,
    height: f32,
    run_start: u32,
    run_end: u32,
    /// Range in `Layout.carets`, in visual left-to-right order.
    caret_start: u32,
    caret_end: u32,

    pub fn rtl(self: Line) bool {
        return self.base_level & 1 != 0;
    }
};

pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };

pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    paragraph: *const ShapedParagraph,
    lines: []const Line,
    runs: []const GlyphRun,
    glyphs: []const PositionedGlyph,
    carets: []const Caret,
    /// Widest line without hanging whitespace.
    width: f32,
    height: f32,

    pub fn init(gpa: std.mem.Allocator, scratch: std.mem.Allocator, cache: *const FontCache, paragraph: *const ShapedParagraph, options: Options) !Layout {
        if (options.width) |w| if (!std.math.isFinite(w) or w < 0) return error.InvalidWidth;
        var self: Layout = .{
            .arena = .init(gpa),
            .paragraph = paragraph,
            .lines = &.{},
            .runs = &.{},
            .glyphs = &.{},
            .carets = &.{},
            .width = 0,
            .height = 0,
        };
        errdefer self.arena.deinit();
        var builder: Builder = .{
            .p = paragraph,
            .cache = cache,
            .a = self.arena.allocator(),
            .scratch = scratch,
            .shaper = try shape_.Shaper.init(),
            .width = options.width,
        };
        defer builder.shaper.deinit();
        try builder.breakLines();
        self.lines = builder.lines.items;
        self.runs = builder.runs.items;
        self.glyphs = builder.glyphs.items;
        self.carets = builder.carets.items;
        builder.position(options);
        for (self.lines) |line| self.width = @max(self.width, line.width);
        if (self.lines.len != 0) {
            const last = self.lines[self.lines.len - 1];
            self.height = last.top + last.height;
        }
        return self;
    }

    pub fn deinit(self: *Layout) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn lineRuns(self: *const Layout, line: Line) []const GlyphRun {
        return self.runs[line.run_start..line.run_end];
    }

    pub fn runGlyphs(self: *const Layout, run: GlyphRun) []const PositionedGlyph {
        return self.glyphs[run.glyph_start..run.glyph_end];
    }

    pub fn lineCarets(self: *const Layout, line: Line) []const Caret {
        return self.carets[line.caret_start..line.caret_end];
    }

    pub const Position = cursor.Position;
    pub const CaretRect = cursor.CaretRect;
    pub const caret = cursor.caret;
    pub const hitTest = cursor.hitTest;
    pub const nextGrapheme = cursor.nextGrapheme;
    pub const previousGrapheme = cursor.previousGrapheme;
    pub const nextWordEnd = cursor.nextWordEnd;
    pub const previousWordStart = cursor.previousWordStart;
    pub const moveVisual = cursor.moveVisual;
    pub const lineBoundary = cursor.lineBoundary;
    pub const moveVertical = cursor.moveVertical;
    pub const selectionRects = cursor.selectionRects;
    pub const lineAt = cursor.lineAt;
};

/// A contiguous part of one shaped run on a line, with its glyphs (the
/// paragraph's, or reshaped ones at an unsafe line edge).
const Piece = struct {
    run: u32,
    start: u32,
    end: u32,
    level: u8,
    glyphs: []const Glyph,
};

const Builder = struct {
    p: *const ShapedParagraph,
    cache: *const FontCache,
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    shaper: shape_.Shaper,
    width: ?f32,
    lines: std.ArrayList(Line) = .empty,
    runs: std.ArrayList(GlyphRun) = .empty,
    glyphs: std.ArrayList(PositionedGlyph) = .empty,
    carets: std.ArrayList(Caret) = .empty,

    fn fits(self: *const Builder, width: f32) bool {
        const limit = self.width orelse return true;
        return width <= limit + 0.001;
    }

    fn breakLines(self: *Builder) !void {
        const segments = self.p.segments;
        var line_start: u32 = 0;
        var start_unsafe = false;
        var first: usize = 0;
        while (first < segments.len) {
            // Greedy: the last opportunity whose line fits without its
            // hanging whitespace. A first segment that does not fit
            // overflows; nothing breaks inside a UAX #14 segment.
            var advance: f32 = 0;
            var chosen = first;
            var j = first;
            while (j < segments.len) : (j += 1) {
                advance += segments[j].advance;
                if (j != first and !self.fits(advance - segments[j].trailing)) break;
                chosen = j;
                if (segments[j].mandatory) break;
            }
            var pieces: []Piece = undefined;
            while (true) {
                const end = segments[chosen].end;
                pieces = try self.linePieces(line_start, end, start_unsafe, segments[chosen].unsafe);
                // A reshaped edge can be wider than measured; then end the
                // line one opportunity earlier.
                if (!segments[chosen].unsafe or chosen == first) break;
                var total: f32 = 0;
                for (pieces) |piece| {
                    for (piece.glyphs) |glyph| total += glyph.advance;
                }
                if (self.fits(total - self.trailing(pieces, line_start, end))) break;
                chosen -= 1;
            }
            try self.emitLine(line_start, segments[chosen].end, pieces);
            line_start = segments[chosen].end;
            start_unsafe = segments[chosen].unsafe;
            first = chosen + 1;
        }
        // The position after a final hard break, and empty text, need a line.
        if (self.lines.items.len == 0 or self.endsWithBreak()) try self.emitLine(@intCast(self.p.text.len), @intCast(self.p.text.len), &.{});
    }

    fn endsWithBreak(self: *const Builder) bool {
        const text = self.p.text;
        if (text.len == 0) return false;
        var start = text.len - 1;
        while (text[start] & 0xc0 == 0x80) start -= 1;
        const len = std.unicode.utf8ByteSequenceLength(text[start]) catch unreachable;
        const cp = std.unicode.utf8Decode(text[start..][0..len]) catch unreachable;
        return switch (@import("uucode").get(.line_break, cp)) {
            .bk, .cr, .lf, .nl => true,
            else => self.p.paragraphs[self.p.paragraphs.len - 1].separator_len != 0,
        };
    }

    /// Advance of hanging whitespace at the end of a line.
    fn trailing(self: *const Builder, pieces: []const Piece, start: u32, end: u32) f32 {
        const hang = paragraph_.hangingStart(self.p.text, start, end);
        var total: f32 = 0;
        for (pieces) |piece| {
            for (piece.glyphs) |glyph| {
                if (glyph.cluster >= hang) total += glyph.advance;
            }
        }
        return total;
    }

    /// The parts of shaped runs on the line `start..end`, reshaping unsafe
    /// edges from the nearest safe glyph boundary inside the line.
    fn linePieces(self: *Builder, start: u32, end: u32, start_unsafe: bool, end_unsafe: bool) ![]Piece {
        var result: std.ArrayList(Piece) = .empty;
        // Runs are in logical order: start at the first one ending after
        // the line start.
        var low: usize = 0;
        var high = self.p.runs.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.p.runs[middle].end <= start) low = middle + 1 else high = middle;
        }
        for (self.p.runs[low..], low..) |run, index| {
            if (run.start >= end) break;
            if (run.end <= start) continue;
            const from = @max(start, run.start);
            const to = @min(end, run.end);
            const glyphs = self.p.runGlyphs(run);
            const reshape_start = start_unsafe and run.start < start;
            const reshape_end = end_unsafe and run.end > end;
            if (!reshape_start and !reshape_end or glyphs.len == 0) {
                try result.append(self.scratch, .{ .run = @intCast(index), .start = from, .end = to, .level = run.level, .glyphs = slice(glyphs, run.rtl(), from, to) });
                continue;
            }
            // Safe boundaries: clusters whose glyphs are not unsafe to break.
            var head_end = from; // reshape from..head_end
            var tail_start = to; // reshape tail_start..to
            if (reshape_start) head_end = safeAfter(glyphs, from, to);
            if (reshape_end) tail_start = safeBefore(glyphs, from, to);
            if (head_end >= tail_start) {
                try result.append(self.scratch, .{ .run = @intCast(index), .start = from, .end = to, .level = run.level, .glyphs = try self.reshape(run, from, to) });
                continue;
            }
            // Logical order: head, middle, tail.
            if (head_end > from) try result.append(self.scratch, .{ .run = @intCast(index), .start = from, .end = head_end, .level = run.level, .glyphs = try self.reshape(run, from, head_end) });
            try result.append(self.scratch, .{ .run = @intCast(index), .start = head_end, .end = tail_start, .level = run.level, .glyphs = slice(glyphs, run.rtl(), head_end, tail_start) });
            if (tail_start < to) try result.append(self.scratch, .{ .run = @intCast(index), .start = tail_start, .end = to, .level = run.level, .glyphs = try self.reshape(run, tail_start, to) });
        }
        return result.items;
    }

    fn reshape(self: *Builder, run: paragraph_.Run, start: u32, end: u32) ![]const Glyph {
        const p = self.p;
        const style = p.styles[run.style];
        const paragraph = p.paragraphs[run.paragraph];
        var out: std.ArrayList(Glyph) = .empty;
        try self.shaper.shape(self.scratch, .{
            .face = self.cache.face(run.font).?,
            .size = style.size,
            .text = p.text,
            .paragraph_start = paragraph.start,
            .paragraph_end = paragraph.contentEnd(),
            .start = start,
            .end = end,
            .rtl = run.rtl(),
            .script = run.script,
            .language = hb.hb_language_from_string(style.language.ptr, @intCast(style.language.len)),
        }, &out);
        return out.items;
    }

    fn emitLine(self: *Builder, start: u32, end: u32, pieces: []Piece) !void {
        const p = self.p;
        const paragraph_index = p.paragraphAt(start);
        const paragraph = p.paragraphs[paragraph_index];
        const base = paragraph.base_level;

        // L1 on the line, then split pieces where the line level changes
        // (trailing whitespace returning to the paragraph level).
        const levels = try self.scratch.alloc(u8, end - start);
        bidi.lineLevels(p.levels[start..end], p.classes[start..end], base, levels);
        var parts: std.ArrayList(Piece) = .empty;
        for (pieces) |piece| {
            var from = piece.start;
            while (from < piece.end) {
                const level = levels[from - start];
                var to = from + 1;
                while (to < piece.end and levels[to - start] == level) to += 1;
                try parts.append(self.scratch, .{ .run = piece.run, .start = from, .end = to, .level = level, .glyphs = slice(piece.glyphs, p.runs[piece.run].rtl(), from, to) });
                from = to;
            }
        }
        // L2: visual order of the parts.
        const part_levels = try self.scratch.alloc(u8, parts.items.len);
        for (part_levels, parts.items) |*level, part| level.* = part.level;
        const order = try self.scratch.alloc(u32, parts.items.len);
        bidi.reorder(part_levels, order);

        // Line metrics: the primary font of the style at the line start sets
        // a strut; every font on the line can extend it.
        var metrics = self.strut(p.styleAt(start));
        const run_start: u32 = @intCast(self.runs.items.len);
        const glyph_start_line = self.glyphs.items.len;
        const caret_start: u32 = @intCast(self.carets.items.len);
        var pen: f32 = 0;
        for (order) |index| {
            const part = parts.items[index];
            const run = p.runs[part.run];
            const style = p.styles[run.style];
            const face = self.cache.face(run.font);
            if (face) |f| metrics = metrics.max(f.metrics(style.size));
            const part_x = pen;
            const glyph_start: u32 = @intCast(self.glyphs.items.len);
            for (part.glyphs) |glyph| {
                try self.glyphs.append(self.a, .{ .id = glyph.id, .x = pen + glyph.x_offset, .y = glyph.y_offset, .advance = glyph.advance, .cluster = glyph.cluster });
                pen += glyph.advance;
            }
            try self.appendCarets(part, run, face, style.size, part_x);
            // Merge with the previous run when it continues it visually.
            if (self.runs.items.len > run_start) {
                const last = &self.runs.items[self.runs.items.len - 1];
                if (last.font == run.font and last.size == style.size and last.style == run.style and last.rtl == run.rtl() and last.glyph_end == glyph_start and
                    (if (run.rtl()) last.start == part.end else last.end == part.start))
                {
                    last.glyph_end = @intCast(self.glyphs.items.len);
                    if (run.rtl()) last.start = part.start else last.end = part.end;
                    continue;
                }
            }
            if (part.glyphs.len == 0) continue;
            try self.runs.append(self.a, .{
                .font = run.font,
                .size = style.size,
                .style = run.style,
                .start = part.start,
                .end = part.end,
                .rtl = run.rtl(),
                .glyph_start = glyph_start,
                .glyph_end = @intCast(self.glyphs.items.len),
            });
        }
        if (self.carets.items.len == caret_start) try self.carets.append(self.a, .{ .offset = start, .x = 0, .affinity = .downstream });

        const hang = paragraph_.hangingStart(p.text, start, end);
        var hanging: f32 = 0;
        for (self.glyphs.items[glyph_start_line..]) |glyph| {
            if (glyph.cluster >= hang) hanging += glyph.advance;
        }
        try self.lines.append(self.a, .{
            .start = start,
            .end = end,
            .paragraph = paragraph_index,
            .base_level = base,
            .x = 0,
            .advance = pen,
            .width = pen - hanging,
            .top = 0,
            .baseline = 0,
            .ascent = metrics.ascent,
            .descent = metrics.descent,
            .height = metrics.height(),
            .run_start = run_start,
            .run_end = @intCast(self.runs.items.len),
            .caret_start = caret_start,
            .caret_end = @intCast(self.carets.items.len),
        });
    }

    fn strut(self: *const Builder, style_index: u32) font_.Metrics {
        const style = self.p.styles[style_index];
        for (style.fonts) |id| if (self.cache.face(id)) |face| return face.metrics(style.size);
        return .{ .ascent = 0, .descent = 0, .line_gap = 0 };
    }

    /// Appends the caret stops of one part, in visual order. Glyphs are
    /// grouped by grapheme; a group's advance is divided among the
    /// graphemes it covers (a ligature), at the font's GDEF ligature carets
    /// when it has them, else evenly.
    fn appendCarets(self: *Builder, part: Piece, run: paragraph_.Run, face: ?*const font_.Face, size: f32, x: f32) !void {
        const graphemes = self.p.graphemes;
        const rtl = run.rtl();
        var pen = x;
        var i: usize = 0;
        while (i < part.glyphs.len) {
            const group = graphemes.atOrBefore(part.glyphs[i].cluster).?;
            var advance: f32 = 0;
            var j = i;
            while (j < part.glyphs.len and graphemes.atOrBefore(part.glyphs[j].cluster).? == group) : (j += 1) advance += part.glyphs[j].advance;
            // The group's logical end: the next group in logical order.
            var group_end = part.end;
            if (rtl) {
                if (i != 0) group_end = graphemes.atOrBefore(part.glyphs[i - 1].cluster).?;
            } else if (j < part.glyphs.len) group_end = graphemes.atOrBefore(part.glyphs[j].cluster).?;
            group_end = @min(group_end, part.end);
            const group_start = @max(group, part.start);

            var count: u32 = 0;
            var offset = group_start;
            while (offset < group_end) : (offset = graphemes.after(offset) orelse group_end) count += 1;
            var splits: [8]f32 = undefined;
            const ligature = count > 1 and j - i == 1 and count - 1 <= splits.len and
                face != null and ligatureCarets(face.?, part.glyphs[i].id, rtl, size, splits[0 .. count - 1]);

            // Physical order: graphemes left to right.
            var edge_left = pen;
            var k: u32 = 0;
            while (k < count) : (k += 1) {
                const edge_right = if (k + 1 == count) pen + advance else if (ligature) pen + splits[k] else pen + advance * @as(f32, @floatFromInt(k + 1)) / @as(f32, @floatFromInt(count));
                const logical = if (rtl) count - 1 - k else k;
                const g_start = nthBoundary(graphemes, group_start, logical);
                const g_end = @min(graphemes.after(g_start) orelse group_end, group_end);
                if (rtl) {
                    try self.carets.append(self.a, .{ .offset = g_end, .x = edge_left, .affinity = .upstream });
                    try self.carets.append(self.a, .{ .offset = g_start, .x = edge_right, .affinity = .downstream });
                } else {
                    try self.carets.append(self.a, .{ .offset = g_start, .x = edge_left, .affinity = .downstream });
                    try self.carets.append(self.a, .{ .offset = g_end, .x = edge_right, .affinity = .upstream });
                }
                edge_left = edge_right;
            }
            pen += advance;
            i = j;
        }
    }

    /// Applies alignment and stacks lines vertically.
    fn position(self: *Builder, options: Options) void {
        var widest: f32 = 0;
        for (self.lines.items) |line| widest = @max(widest, line.width);
        const available = options.width orelse widest;
        var top: f32 = 0;
        for (self.lines.items) |*line| {
            const hanging = line.advance - line.width;
            const free = available - line.width;
            // Hanging whitespace sits at the logical end: right for
            // left-to-right lines, left for right-to-left ones.
            const left_of_content: f32 = if (line.rtl()) hanging else 0;
            line.x = switch (options.alignment) {
                .start => if (line.rtl()) free else 0,
                .end => if (line.rtl()) 0 else free,
                .center => free / 2,
            } - left_of_content;
            line.top = top;
            line.baseline = top + line.ascent;
            top += line.height;
        }
    }
};

/// The glyphs of `from..to` in a run's glyph sequence (monotone clusters,
/// decreasing for right-to-left).
fn slice(glyphs: []const Glyph, rtl: bool, from: u32, to: u32) []const Glyph {
    var first: usize = 0;
    var last: usize = glyphs.len;
    if (rtl) {
        while (first < last and glyphs[first].cluster >= to) first += 1;
        while (last > first and glyphs[last - 1].cluster < from) last -= 1;
    } else {
        while (first < last and glyphs[first].cluster < from) first += 1;
        while (last > first and glyphs[last - 1].cluster >= to) last -= 1;
    }
    return glyphs[first..last];
}

/// The first cluster boundary after `from` (within `from..to`) that is safe
/// to break at, or `to`.
fn safeAfter(glyphs: []const Glyph, from: u32, to: u32) u32 {
    var best = to;
    for (glyphs) |glyph| {
        if (glyph.cluster > from and glyph.cluster < best and !anyUnsafeAt(glyphs, glyph.cluster)) best = glyph.cluster;
    }
    return best;
}

/// The last safe cluster boundary before `to` (within `from..to`), or `from`.
fn safeBefore(glyphs: []const Glyph, from: u32, to: u32) u32 {
    var best = from;
    for (glyphs) |glyph| {
        if (glyph.cluster < to and glyph.cluster > best and !anyUnsafeAt(glyphs, glyph.cluster)) best = glyph.cluster;
    }
    return best;
}

fn anyUnsafeAt(glyphs: []const Glyph, cluster: u32) bool {
    for (glyphs) |glyph| if (glyph.cluster == cluster and glyph.unsafe_to_break) return true;
    return false;
}

fn nthBoundary(graphemes: @import("boundaries.zig"), start: u32, n: u32) u32 {
    var offset = start;
    for (0..n) |_| offset = graphemes.after(offset).?;
    return offset;
}

/// Font-provided caret positions inside a ligature glyph, in pixels from its
/// left edge. False unless the font defines exactly `out.len` of them.
fn ligatureCarets(face: *const font_.Face, glyph: u32, rtl: bool, size: f32, out: []f32) bool {
    var positions: [8]hb.hb_position_t = undefined;
    var count: c_uint = @intCast(out.len);
    const total = hb.hb_ot_layout_get_ligature_carets(face.font, if (rtl) hb.HB_DIRECTION_RTL else hb.HB_DIRECTION_LTR, glyph, 0, &count, &positions);
    if (total != out.len or count != out.len) return false;
    const scale = face.scale(size);
    for (out, positions[0..out.len]) |*o, position| o.* = @as(f32, @floatFromInt(position)) * scale;
    std.mem.sort(f32, out, {}, std.sort.asc(f32));
    return true;
}

const Fixture = paragraph_.testing.Fixture;

fn layoutOf(fixture: *Fixture, p: *const ShapedParagraph, options: Options) !Layout {
    return Layout.init(std.testing.allocator, fixture.arena.allocator(), &fixture.cache, p, options);
}

/// Logical clusters of a line's glyphs in visual order.
fn visualClusters(l: *const Layout, line: Line, out: []u32) []u32 {
    var n: usize = 0;
    for (l.lineRuns(line)) |run| for (l.runGlyphs(run)) |glyph| {
        out[n] = glyph.cluster;
        n += 1;
    };
    return out[0..n];
}

test "greedy breaking lets trailing whitespace hang" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("aaa aaa aaa", .auto_ltr);
    defer p.deinit();
    var natural = try layoutOf(&fixture, &p, .{});
    defer natural.deinit();
    try std.testing.expectEqual(1, natural.lines.len);
    // Exactly the width of "aaa aaa" without the following space.
    const space = p.segments[0].trailing;
    const width = p.segments[0].advance + p.segments[1].advance - space;
    var wrapped = try layoutOf(&fixture, &p, .{ .width = width });
    defer wrapped.deinit();
    try std.testing.expectEqual(2, wrapped.lines.len);
    try std.testing.expectEqual(8, wrapped.lines[0].end);
    try std.testing.expectApproxEqAbs(width, wrapped.lines[0].width, 0.01);
    try std.testing.expectApproxEqAbs(width + space, wrapped.lines[0].advance, 0.01);
    // One pixel less and every word gets its own line.
    var narrower = try layoutOf(&fixture, &p, .{ .width = width - 1 });
    defer narrower.deinit();
    try std.testing.expectEqual(3, narrower.lines.len);
    try std.testing.expect(narrower.lines[1].top > 0 and narrower.lines[2].top > narrower.lines[1].top);
    // A word wider than the line overflows instead of breaking.
    var tiny = try layoutOf(&fixture, &p, .{ .width = 1 });
    defer tiny.deinit();
    try std.testing.expectEqual(3, tiny.lines.len);
}

test "lines get L1 levels and L2 order after breaking" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const text = "abc אבג דהו";
    var p = try fixture.shape(text, .ltr);
    defer p.deinit();
    var one = try layoutOf(&fixture, &p, .{});
    defer one.deinit();
    var clusters: [16]u32 = undefined;
    // Unwrapped: "abc " then the Hebrew words right to left, the space
    // between them staying inside the right-to-left run.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 15, 13, 11, 10, 8, 6, 4 }, visualClusters(&one, one.lines[0], &clusters));

    // Break after "אבג ": the trailing space returns to level 0 (L1) and
    // sits at the visual end of the left-to-right line.
    const width = p.segments[0].advance + p.segments[1].advance - p.segments[1].trailing;
    var two = try layoutOf(&fixture, &p, .{ .width = width });
    defer two.deinit();
    try std.testing.expectEqual(2, two.lines.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 8, 6, 4, 10 }, visualClusters(&two, two.lines[0], &clusters));
    try std.testing.expectEqualSlices(u32, &.{ 15, 13, 11 }, visualClusters(&two, two.lines[1], &clusters));
}

test "right-to-left paragraphs align to the right edge" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("שלום עולם", .auto_ltr);
    defer p.deinit();
    var l = try layoutOf(&fixture, &p, .{ .width = 300 });
    defer l.deinit();
    const line = l.lines[0];
    try std.testing.expect(line.rtl());
    try std.testing.expectApproxEqAbs(300, line.x + line.advance, 0.01);
    var centered = try layoutOf(&fixture, &p, .{ .width = 300, .alignment = .center });
    defer centered.deinit();
    try std.testing.expectApproxEqAbs(150 - line.width / 2, centered.lines[0].x, 0.01);
}

test "a width change reuses the shaped paragraph" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("The quick brown fox jumps over the lazy dog.", .auto_ltr);
    defer p.deinit();
    var previous_lines: usize = 0;
    for ([_]f32{ 400, 200, 100, 50 }) |width| {
        var l = try layoutOf(&fixture, &p, .{ .width = width });
        defer l.deinit();
        try std.testing.expect(l.lines.len >= previous_lines);
        previous_lines = l.lines.len;
        for (l.lines) |line| try std.testing.expect(line.width <= width or line.run_end - line.run_start == 1);
        // Every glyph appears exactly once across lines.
        var total: usize = 0;
        for (l.runs) |run| total += run.glyph_end - run.glyph_start;
        try std.testing.expectEqual(p.glyphs.len, total);
    }
}

test "unsafe line edges are reshaped from the nearest safe boundary" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("aaa aaa aaa", .auto_ltr);
    defer p.deinit();
    // The test fonts never flag a break opportunity, so mark the break after
    // "aaa " unsafe by hand: layout must splice reshaped glyphs for "a" at
    // the start of line 2 and for the space at the end of line 1.
    @constCast(p.segments)[0].unsafe = true;
    for (@constCast(p.glyphs)) |*glyph| glyph.unsafe_to_break = glyph.cluster == 4;
    const width = p.segments[0].advance + p.segments[1].advance - p.segments[1].trailing - 1;
    var l = try layoutOf(&fixture, &p, .{ .width = width });
    defer l.deinit();
    try std.testing.expectEqual(3, l.lines.len);
    var clusters: [16]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, visualClusters(&l, l.lines[0], &clusters));
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 6, 7 }, visualClusters(&l, l.lines[1], &clusters));
    // Reshaping in this font changes nothing, so positions match the
    // paragraph's glyphs.
    var x: f32 = 0;
    for (l.runGlyphs(l.lineRuns(l.lines[1])[0]), p.glyphs[4..8]) |positioned, glyph| {
        try std.testing.expectEqual(glyph.id, positioned.id);
        try std.testing.expectApproxEqAbs(x, positioned.x, 0.001);
        x += glyph.advance;
    }
}
