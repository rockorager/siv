//! Layout: a ShapedParagraph broken into lines at one width (D13).
//!
//! Greedy break selection runs over the paragraph's measured segments,
//! each line within the width its paragraph's indents leave. Tabs advance
//! to the next tab stop from the start margin, so a segment holding one
//! is measured where it falls; with `break_words`, a word too wide for a
//! line of its own breaks between graphemes.
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
const hyphen_ = @import("hyphen.zig");

/// `justify` widens the spaces of every line but a paragraph's last to
/// fill the width, which then goes at the start.
pub const Alignment = enum { start, end, center, justify };

/// How text after a tab lines up with a tab stop.
pub const TabAlign = enum { start, center, end, decimal };

pub const TabStop = struct {
    /// Pixels from the start margin (before indentation).
    position: f32,
    alignment: TabAlign = .start,
    /// Decimal stops: the character placed at the stop.
    decimal: u21 = '.',
};

/// How the lines of one paragraph (a bidi paragraph: text up to a
/// paragraph separator) are placed.
pub const ParagraphStyle = struct {
    /// Null takes the layout's alignment (a text node's, at paint time).
    alignment: ?Alignment = null,
    /// Space at the start and end edges, in pixels.
    indent_start: f32 = 0,
    indent_end: f32 = 0,
    /// Added to `indent_start` on the paragraph's first line; negative
    /// hangs the first line out.
    first_line_indent: f32 = 0,
    /// Line height as a multiple of the font's (CSS line-height), with
    /// the extra space split above and below the line.
    line_spacing: f32 = 1,
    /// An exact line height in pixels, replacing `line_spacing`; 0 is
    /// none.
    line_height: f32 = 0,
    /// Space above the paragraph's first line and below its last, between
    /// paragraphs only: not above the text's first paragraph or below its
    /// last.
    space_before: f32 = 0,
    space_after: f32 = 0,
    /// Distance between tab stops after the explicit ones; 0 is the
    /// shaped tab's advance (four spaces).
    tab_width: f32 = 0,
};

/// A paragraph style up to byte offset `end` (exclusive). A paragraph
/// takes the style of the run containing its first byte.
pub const ParagraphRun = struct {
    end: u32,
    style: ParagraphStyle,
};

pub const Options = struct {
    /// Available width in pixels; null lays out without wrapping.
    width: ?f32 = null,
    alignment: Alignment = .start,
    /// Paragraph styles in text order; empty uses the defaults.
    paragraphs: []const ParagraphRun = &.{},
    /// Explicit tab stops, increasing; after them tabs advance to
    /// multiples of the paragraph's `tab_width`. Text after a center,
    /// end, or decimal stop is measured to the next tab or the end of
    /// its paragraph.
    tab_stops: []const TabStop = &.{},
    /// A word too wide for a line of its own breaks between graphemes
    /// (CSS overflow-wrap: anywhere) instead of overflowing.
    break_words: bool = false,
    /// Words may break at hyphenation points of their style's language,
    /// from `hyphenation`, ending the line with a hyphen.
    hyphenate: bool = false,
    hyphenation: ?*hyphen_.Hyphenation = null,
    /// Knuth and Plass's total-fit breaking (with a width): lines chosen
    /// for the whole paragraph, evening out their fill, instead of
    /// greedily.
    optimal: bool = false,
    /// Whether text ending with a hard break gets the empty line after it.
    /// A block of a longer text (`blocks.zig`) other than the last has
    /// none: the next block's first line follows.
    final_line: bool = true,
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
    /// Ink bounds of the glyphs, x from the line's left pen position and y
    /// from the baseline (down); empty (zero size) without ink. Painting
    /// takes them as they are instead of asking every glyph.
    ink: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
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
    /// The paragraph's indents on this line (the first-line indent
    /// included), in its own direction's start and end edges.
    indent_start: f32 = 0,
    indent_end: f32 = 0,
    /// The paragraph's alignment, if it sets one.
    alignment: ?Alignment = null,

    pub fn rtl(self: Line) bool {
        return self.base_level & 1 != 0;
    }

    /// The left edge of the line's content (without hanging whitespace)
    /// as laid out.
    pub fn contentX(self: Line) f32 {
        return self.x + if (self.rtl()) self.advance - self.width else 0;
    }

    /// Where the line's content goes in a box `width` wide whose start
    /// edge is the left (or the right, `rtl`): within the indents, which
    /// follow the box's direction like the alignment does (D21), by the
    /// line's alignment or else `alignment`.
    pub fn contentXIn(self: Line, width: f32, rtl_box: bool, alignment: Alignment) f32 {
        const left = if (rtl_box) self.indent_end else self.indent_start;
        const right = if (rtl_box) self.indent_start else self.indent_end;
        const free = width - left - right - self.width;
        return left + switch (self.alignment orelse alignment) {
            .start, .justify => if (rtl_box) free else 0,
            .end => if (rtl_box) 0 else free,
            .center => free / 2,
        };
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
    /// Widest line without hanging whitespace, with its indents.
    width: f32,
    height: f32,
    /// What it was built with, for `initReusing`.
    built: Built = .{},

    const Built = struct {
        width: ?f32 = null,
        alignment: Alignment = .start,
        break_words: bool = false,
        hyphenate: bool = false,
        optimal: bool = true,
        final_line: bool = true,
        tab_stops: []const TabStop = &.{},
        /// One per bidi paragraph, plus the line after a final break.
        styles: []const ParagraphStyle = &.{},
    };

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
        for (options.tab_stops) |stop| if (!std.math.isFinite(stop.position)) return error.InvalidWidth;
        var builder: Builder = .{
            .p = paragraph,
            .cache = cache,
            .a = self.arena.allocator(),
            .scratch = scratch,
            .shaper = try shape_.Shaper.init(),
            .width = options.width,
            .styles = try paragraphStyles(scratch, paragraph, options.paragraphs),
            .tab_stops = options.tab_stops,
            .break_words = options.break_words,
            .hyphenation = if (options.hyphenate) options.hyphenation else null,
            .tabs = std.mem.indexOfScalar(u8, paragraph.text, '\t') != null,
            .final_line = options.final_line,
        };
        defer builder.shaper.deinit();
        if (options.optimal and options.width != null) try builder.breakOptimal() else try builder.breakLines();
        builder.position(options);
        try self.keep(&builder);
        errdefer self.freeArrays();
        try self.finish(options, builder.styles);
        return self;
    }

    /// Copies the builder's lists out at their exact sizes, outside the
    /// arena: an arena grows by half again what it holds, which left more
    /// than half of a long text's memory unused. `deinit` frees them.
    fn keep(self: *Layout, builder: *const Builder) !void {
        const gpa = self.arena.child_allocator;
        errdefer self.freeArrays();
        self.lines = try gpa.dupe(Line, builder.lines.items);
        self.runs = try gpa.dupe(GlyphRun, builder.runs.items);
        self.glyphs = try gpa.dupe(PositionedGlyph, builder.glyphs.items);
        self.carets = try gpa.dupe(Caret, builder.carets.items);
    }

    fn freeArrays(self: *Layout) void {
        const gpa = self.arena.child_allocator;
        gpa.free(self.lines);
        gpa.free(self.runs);
        gpa.free(self.glyphs);
        gpa.free(self.carets);
        self.lines = &.{};
        self.runs = &.{};
        self.glyphs = &.{};
        self.carets = &.{};
    }

    /// Width, height, and what the layout was built with.
    fn finish(self: *Layout, options: Options, styles: []const ParagraphStyle) !void {
        for (self.lines) |line| self.width = @max(self.width, line.width + line.indent_start + line.indent_end);
        if (self.lines.len != 0) {
            const last = self.lines[self.lines.len - 1];
            self.height = last.top + last.height;
        }
        const a = self.arena.allocator();
        self.built = .{
            .width = options.width,
            .alignment = options.alignment,
            .break_words = options.break_words,
            .hyphenate = options.hyphenate,
            .optimal = options.optimal,
            .final_line = options.final_line,
            .tab_stops = try a.dupe(TabStop, options.tab_stops),
            .styles = try a.dupe(ParagraphStyle, styles),
        };
    }

    /// Like `init` for `paragraph`, which `ShapedParagraph.initReusing`
    /// built from the paragraph `old` was laid out from: the lines of the
    /// paragraphs it kept are `old`'s, moved to their new offsets and
    /// heights, and only the paragraphs it redid are broken into lines
    /// again. Lines of different paragraphs are independent, since every
    /// paragraph ends with a mandatory break, so the result equals
    /// `init`'s. Falls back to `init` without a width (alignment then
    /// depends on the widest line), with total-fit breaking, or when the
    /// options or the kept paragraphs' styles differ from `old`'s.
    pub fn initReusing(gpa: std.mem.Allocator, scratch: std.mem.Allocator, cache: *const FontCache, paragraph: *const ShapedParagraph, options: Options, old_: ?*const Layout) !Layout {
        const old = old_ orelse return init(gpa, scratch, cache, paragraph, options);
        const r = paragraph.reused orelse return init(gpa, scratch, cache, paragraph, options);
        const width = options.width orelse return init(gpa, scratch, cache, paragraph, options);
        if (!std.math.isFinite(width) or width < 0) return error.InvalidWidth;
        const b = old.built;
        if (old.paragraph.text.len != r.old_len or old.paragraph.paragraphs.len != r.old_paragraphs or options.optimal or b.optimal or
            b.final_line != options.final_line or b.width != width or b.alignment != options.alignment or b.break_words != options.break_words or b.hyphenate != options.hyphenate or
            b.tab_stops.len != options.tab_stops.len)
            return init(gpa, scratch, cache, paragraph, options);
        for (b.tab_stops, options.tab_stops) |x, y| if (!std.meta.eql(x, y)) return init(gpa, scratch, cache, paragraph, options);
        for (options.tab_stops) |stop| if (!std.math.isFinite(stop.position)) return error.InvalidWidth;
        const styles = try paragraphStyles(scratch, paragraph, options.paragraphs);
        if (styles.len - r.new_rest != b.styles.len - r.old_rest) return init(gpa, scratch, cache, paragraph, options);
        for (styles[0..r.first], b.styles[0..r.first]) |x, y| if (!std.meta.eql(x, y)) return init(gpa, scratch, cache, paragraph, options);
        for (styles[r.new_rest..], b.styles[r.old_rest..]) |x, y| if (!std.meta.eql(x, y)) return init(gpa, scratch, cache, paragraph, options);

        var self: Layout = .{ .arena = .init(gpa), .paragraph = paragraph, .lines = &.{}, .runs = &.{}, .glyphs = &.{}, .carets = &.{}, .width = 0, .height = 0 };
        errdefer self.arena.deinit();
        var builder: Builder = .{
            .p = paragraph,
            .cache = cache,
            .a = self.arena.allocator(),
            .scratch = scratch,
            .shaper = try shape_.Shaper.init(),
            .width = width,
            .styles = styles,
            .tab_stops = options.tab_stops,
            .break_words = options.break_words,
            .hyphenation = if (options.hyphenate) options.hyphenation else null,
            .tabs = std.mem.indexOfScalar(u8, paragraph.text, '\t') != null,
            .final_line = options.final_line,
        };
        defer builder.shaper.deinit();

        // The kept lines at each end, and where their arrays start.
        var head: usize = 0;
        while (head < old.lines.len and old.lines[head].paragraph < r.first) head += 1;
        var tail = head;
        while (tail < old.lines.len and old.lines[tail].paragraph < r.old_rest) tail += 1;
        const runEnd = struct {
            fn at(l: *const Layout, line: usize) struct { u32, u32, u32 } {
                if (line == l.lines.len) return .{ @intCast(l.runs.len), @intCast(l.glyphs.len), @intCast(l.carets.len) };
                const run = l.lines[line].run_start;
                return .{ run, if (run == 0) 0 else l.runs[run - 1].glyph_end, l.lines[line].caret_start };
            }
        }.at;
        const head_end = runEnd(old, head);
        const tail_start = runEnd(old, tail);
        const lists = builder.scratch;
        try builder.lines.appendSlice(lists, old.lines[0..head]);
        try builder.runs.appendSlice(lists, old.runs[0..head_end[0]]);
        try builder.glyphs.appendSlice(lists, old.glyphs[0..head_end[1]]);
        try builder.carets.appendSlice(lists, old.carets[0..head_end[2]]);

        // The redone paragraphs.
        const segments = paragraph.segments;
        var seg_first: usize = 0;
        while (seg_first < segments.len and segments[seg_first].end <= r.start) seg_first += 1;
        var seg_end = seg_first;
        while (seg_end < segments.len and segments[seg_end].end <= r.new_end) seg_end += 1;
        try builder.breakRange(seg_first, seg_end, r.start);
        const mid_end = builder.lines.items.len;

        // The kept lines after them.
        const delta: i64 = @as(i64, r.new_end) - r.old_end;
        const shift = struct {
            fn by(x: u32, d: i64) u32 {
                return @intCast(@as(i64, x) + d);
            }
        }.by;
        const dp: i64 = @as(i64, r.new_rest) - r.old_rest;
        const dr: i64 = @as(i64, @intCast(builder.runs.items.len)) - tail_start[0];
        const dg: i64 = @as(i64, @intCast(builder.glyphs.items.len)) - tail_start[1];
        const dc: i64 = @as(i64, @intCast(builder.carets.items.len)) - tail_start[2];
        for (old.lines[tail..]) |line| {
            var l = line;
            l.start = shift(l.start, delta);
            l.end = shift(l.end, delta);
            l.paragraph = shift(l.paragraph, dp);
            l.run_start = shift(l.run_start, dr);
            l.run_end = shift(l.run_end, dr);
            l.caret_start = shift(l.caret_start, dc);
            l.caret_end = shift(l.caret_end, dc);
            try builder.lines.append(lists, l);
        }
        for (old.runs[tail_start[0]..]) |run| {
            var x = run;
            x.start = shift(x.start, delta);
            x.end = shift(x.end, delta);
            x.glyph_start = shift(x.glyph_start, dg);
            x.glyph_end = shift(x.glyph_end, dg);
            try builder.runs.append(lists, x);
        }
        try builder.glyphs.ensureUnusedCapacity(lists, old.glyphs.len - tail_start[1]);
        for (old.glyphs[tail_start[1]..]) |g| {
            var x = g;
            x.cluster = shift(x.cluster, delta);
            builder.glyphs.appendAssumeCapacity(x);
        }
        try builder.carets.ensureUnusedCapacity(lists, old.carets.len - tail_start[2]);
        for (old.carets[tail_start[2]..]) |c| {
            var x = c;
            x.offset = shift(x.offset, delta);
            builder.carets.appendAssumeCapacity(x);
        }
        if (r.new_end == paragraph.text.len and builder.final_line and builder.endsWithBreak()) {
            const len: u32 = @intCast(paragraph.text.len);
            try builder.emitLine(len, len, &.{}, builder.frame(len), null);
        }

        // Place the redone lines after the kept ones, and move the rest by
        // the change in height.
        var place: Builder.Place = .{};
        if (head > 0) {
            const prev = builder.lines.items[head - 1];
            place = .{ .top = prev.top + prev.height, .previous = builder.paragraphIndex(prev.start) };
        }
        place = builder.positionRange(options, head, mid_end, place);
        if (mid_end < builder.lines.items.len and tail < old.lines.len) {
            const first_kept = builder.lines.items[mid_end];
            const index = builder.paragraphIndex(first_kept.start);
            var top = place.top;
            if (place.previous) |p| if (p != index) {
                top += styles[p].space_after + styles[index].space_before;
            };
            const dy = top - old.lines[tail].top;
            for (builder.lines.items[mid_end..]) |*line| {
                line.top += dy;
                line.baseline += dy;
            }
        } else if (mid_end < builder.lines.items.len) {
            // Only the line after a final break followed.
            _ = builder.positionRange(options, mid_end, builder.lines.items.len, place);
        }
        try self.keep(&builder);
        errdefer self.freeArrays();
        try self.finish(options, styles);
        return self;
    }

    pub fn deinit(self: *Layout) void {
        self.freeArrays();
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
    pub const lineEdge = cursor.lineEdge;
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
    /// One per bidi paragraph, plus one for a line after a final break.
    styles: []const ParagraphStyle,
    tab_stops: []const TabStop,
    break_words: bool,
    hyphenation: ?*hyphen_.Hyphenation,
    /// The text has a tab, so segments need measuring where they fall.
    tabs: bool,
    /// `Options.final_line`.
    final_line: bool = true,
    /// The lists below grow in scratch memory and are copied into the
    /// layout's arena at their final size: grown in the arena, every
    /// outgrown buffer stayed (about half the memory of a long text).
    lines: std.ArrayList(Line) = .empty,
    runs: std.ArrayList(GlyphRun) = .empty,
    glyphs: std.ArrayList(PositionedGlyph) = .empty,
    carets: std.ArrayList(Caret) = .empty,

    fn fits(limit: ?f32, width: f32) bool {
        const l = limit orelse return true;
        return width <= l + 0.001;
    }

    /// Where the line starting at `start` begins and how wide it may be.
    const LineFrame = struct {
        style: ParagraphStyle,
        /// The start indent, with the first-line indent on a first line.
        indent: f32,
        limit: ?f32,
    };

    fn frame(self: *const Builder, start: u32) LineFrame {
        const index = self.paragraphIndex(start);
        const style = self.styles[index];
        const first = index == self.p.paragraphs.len or start == self.p.paragraphs[index].start;
        const indent = style.indent_start + if (first) style.first_line_indent else 0;
        return .{
            .style = style,
            .indent = indent,
            .limit = if (self.width) |w| @max(0, w - indent - style.indent_end) else null,
        };
    }

    /// The paragraph a line starting at `start` belongs to; the line after
    /// a final break starts a paragraph of its own (index
    /// `paragraphs.len`).
    fn paragraphIndex(self: *const Builder, start: u32) u32 {
        if (start == self.p.text.len and self.p.text.len != 0 and self.endsWithBreak()) return @intCast(self.p.paragraphs.len);
        return self.p.paragraphAt(start);
    }

    const Measured = struct { advance: f32, trailing: f32 };

    /// The advance of segment `j` from `from` (its start, or inside it
    /// after a break within a word), with its tabs advancing to their
    /// stops from `x`, the pen's distance from the start margin.
    fn segment(self: *Builder, j: usize, from: u32, x: f32, style: ParagraphStyle) Measured {
        const seg = self.p.segments[j];
        const seg_start = if (j == 0) 0 else self.p.segments[j - 1].end;
        if (from == seg_start and !self.tabs) return .{ .advance = seg.advance, .trailing = seg.trailing };
        const hang = paragraph_.hangingStart(self.p.text, from, seg.end);
        var m: Measured = .{ .advance = 0, .trailing = 0 };
        var it: LogicalGlyphs = .init(self.p, from, seg.end);
        while (it.next()) |glyph| {
            const advance = if (self.isTab(glyph)) self.tabAdvance(x + m.advance, glyph, style) else glyph.advance;
            m.advance += advance;
            if (glyph.cluster >= hang) m.trailing += advance;
        }
        return m;
    }

    fn isTab(self: *const Builder, glyph: Glyph) bool {
        return self.p.text[glyph.cluster] == '\t';
    }

    /// The advance of `tab` from `x`, the pen's distance from the start
    /// margin, to the next tab stop: an explicit one, where the text
    /// after the tab starts, centers, ends, or puts its decimal
    /// character; else a multiple of the tab width (or of the shaped
    /// tab's advance, four spaces).
    fn tabAdvance(self: *const Builder, x: f32, tab: Glyph, style: ParagraphStyle) f32 {
        const shaped = tab.advance;
        for (self.tab_stops) |stop| if (stop.position > x + 0.01) {
            const to = stop.position - x;
            return switch (stop.alignment) {
                .start => to,
                .center => @max(0, to - self.following(tab.cluster, null) / 2),
                .end => @max(0, to - self.following(tab.cluster, null)),
                .decimal => @max(0, to - self.following(tab.cluster, stop.decimal)),
            };
        };
        const interval = if (style.tab_width > 0) style.tab_width else shaped;
        if (!(interval > 0.01)) return shaped;
        return (@floor((x + 0.01) / interval) + 1) * interval - x;
    }

    /// The advance of the text after the tab at `at`, to the next tab or
    /// the end of its paragraph, or with `decimal` to that character.
    fn following(self: *const Builder, at: u32, decimal: ?u21) f32 {
        const p = self.p;
        const end = p.paragraphs[p.paragraphAt(at)].contentEnd();
        var it: LogicalGlyphs = .init(p, at + 1, end);
        var width: f32 = 0;
        var seen: ?u32 = null;
        while (it.next()) |g| {
            const ch = p.text[g.cluster];
            if (ch == '\t') break;
            if (decimal) |d| if (seen != g.cluster) {
                seen = g.cluster;
                const len = std.unicode.utf8ByteSequenceLength(ch) catch 1;
                const cp = std.unicode.utf8Decode(p.text[g.cluster..@min(p.text.len, g.cluster + len)]) catch 0;
                if (cp == d) break;
            };
            width += g.advance;
        }
        return width;
    }

    /// Gives the tabs among a line's pieces (logical order) their
    /// advances from the start margin, on copies of the glyphs.
    fn placeTabs(self: *Builder, pieces: []Piece, indent: f32, style: ParagraphStyle) !void {
        if (!self.tabs) return;
        var pen: f32 = indent;
        for (pieces) |*piece| {
            const rtl = self.p.runs[piece.run].rtl();
            var has_tab = false;
            for (piece.glyphs) |glyph| has_tab = has_tab or self.isTab(glyph);
            if (!has_tab) {
                for (piece.glyphs) |glyph| pen += glyph.advance;
                continue;
            }
            const copy = try self.scratch.dupe(Glyph, piece.glyphs);
            for (0..copy.len) |i| {
                const g = &copy[if (rtl) copy.len - 1 - i else i];
                if (self.isTab(g.*)) g.advance = self.tabAdvance(pen, g.*, style);
                pen += g.advance;
            }
            piece.glyphs = copy;
        }
    }

    /// The last grapheme boundary in `start..end` before which the text
    /// fits in `limit`, at least one grapheme past `start`.
    fn graphemeBreak(self: *Builder, start: u32, end: u32, limit: f32, x: f32, style: ParagraphStyle) u32 {
        const graphemes = self.p.graphemes;
        var advance: f32 = 0;
        var at = start;
        var it: LogicalGlyphs = .init(self.p, start, end);
        var pending: ?Glyph = it.next();
        while (true) {
            const next = @min(end, graphemes.after(at) orelse end);
            var width = advance;
            while (pending) |glyph| : (pending = it.next()) {
                if (glyph.cluster >= next) break;
                width += if (self.isTab(glyph)) self.tabAdvance(x + width, glyph, style) else glyph.advance;
            }
            if (at != start and !fits(limit, width)) return at;
            advance = width;
            at = next;
            if (at >= end) return end;
        }
    }

    fn breakLines(self: *Builder) !void {
        try self.breakRange(0, self.p.segments.len, 0);
        // The position after a final hard break, and empty text, need a line.
        if (self.lines.items.len == 0 or (self.final_line and self.endsWithBreak())) {
            const len: u32 = @intCast(self.p.text.len);
            try self.emitLine(len, len, &.{}, self.frame(len), null);
        }
    }

    /// Breaks the text of segments `first_segment..end_segment` into
    /// lines, from `line_start_`, where the first segment starts; the last
    /// one ends with a mandatory break or the text.
    fn breakRange(self: *Builder, first_segment: usize, end_segment: usize, line_start_: u32) !void {
        const segments = self.p.segments[0..end_segment];
        var line_start = line_start_;
        var start_unsafe = false;
        var first: usize = first_segment;
        while (first < segments.len) {
            const f = self.frame(line_start);
            // Greedy: the last opportunity whose line fits without its
            // hanging whitespace. A first segment that does not fit
            // overflows, unless words may break.
            var advance: f32 = 0;
            var chosen = first;
            var j = first;
            var overflow: ?usize = null;
            while (j < segments.len) : (j += 1) {
                const m = self.segment(j, if (j == first) line_start else segments[j - 1].end, f.indent + advance, f.style);
                if (j != first and !fits(f.limit, advance + m.advance - m.trailing)) {
                    overflow = j;
                    break;
                }
                advance += m.advance;
                chosen = j;
                if (segments[j].mandatory) break;
            }
            // A hyphenation point is a later opportunity than the last
            // that fits: in the segment that did not fit, or in a first
            // segment that does not fit alone.
            if (self.hyphenation != null and f.limit != null) {
                const alone = chosen == first and !fits(f.limit, advance - self.segment(first, line_start, f.indent, f.style).trailing);
                const in_seg: ?usize = if (overflow) |o| o else if (alone) first else null;
                if (in_seg) |k| {
                    const from = if (k == first) line_start else segments[k - 1].end;
                    const used = if (k == first) 0 else advance;
                    if (try self.hyphenBreak(from, segments[k].end, f.limit.? - used)) |hyph| {
                        const pieces = try self.linePieces(line_start, hyph.at, start_unsafe, true);
                        try self.placeTabs(pieces, f.indent, f.style);
                        try self.emitLine(line_start, hyph.at, pieces, f, hyph.hyphen);
                        line_start = hyph.at;
                        start_unsafe = true;
                        first = k;
                        continue;
                    }
                }
            }
            if (chosen == first and self.break_words and f.limit != null) {
                const m = self.segment(first, line_start, f.indent, f.style);
                const content_end = paragraph_.hangingStart(self.p.text, line_start, segments[first].end);
                if (!fits(f.limit, m.advance - m.trailing) and content_end > line_start) {
                    const end = self.graphemeBreak(line_start, content_end, f.limit.?, f.indent, f.style);
                    if (end < content_end) {
                        // Shaping across the break may differ: reshape
                        // both edges, as at an unsafe opportunity.
                        const pieces = try self.linePieces(line_start, end, start_unsafe, true);
                        try self.placeTabs(pieces, f.indent, f.style);
                        try self.emitLine(line_start, end, pieces, f, null);
                        line_start = end;
                        start_unsafe = true;
                        continue;
                    }
                }
            }
            var pieces: []Piece = undefined;
            while (true) {
                const end = segments[chosen].end;
                pieces = try self.linePieces(line_start, end, start_unsafe, segments[chosen].unsafe);
                try self.placeTabs(pieces, f.indent, f.style);
                // A reshaped edge can be wider than measured; then end the
                // line one opportunity earlier.
                if (!segments[chosen].unsafe or chosen == first) break;
                var total: f32 = 0;
                for (pieces) |piece| {
                    for (piece.glyphs) |glyph| total += glyph.advance;
                }
                if (fits(f.limit, total - self.trailing(pieces, line_start, end))) break;
                chosen -= 1;
            }
            try self.emitLine(line_start, segments[chosen].end, pieces, f, null);
            line_start = segments[chosen].end;
            start_unsafe = segments[chosen].unsafe;
            first = chosen + 1;
        }
    }

    /// The hyphen ending a line broken inside a word before `at`.
    const Hyphen = struct { id: u32, advance: f32, font: FontId, size: f32, style: u32, cluster: u32 };

    /// The hyphen glyph (U+2010, else a hyphen-minus) of the face of the
    /// text before `at`; null in right-to-left runs or without a face.
    fn hyphenAt(self: *const Builder, at: u32) ?Hyphen {
        const p = self.p;
        if (at == 0) return null;
        const run = for (p.runs) |r| {
            if (at - 1 >= r.start and at - 1 < r.end) break r;
        } else return null;
        if (run.rtl()) return null;
        const face = self.cache.face(run.font) orelse return null;
        var id: hb.hb_codepoint_t = 0;
        if (hb.hb_font_get_nominal_glyph(face.font, 0x2010, &id) == 0 and hb.hb_font_get_nominal_glyph(face.font, '-', &id) == 0) return null;
        const size = p.styles[run.style].size;
        return .{
            .id = id,
            .advance = @as(f32, @floatFromInt(hb.hb_font_get_glyph_h_advance(face.font, id))) * face.scale(size),
            .font = run.font,
            .size = size,
            .style = run.style,
            // The hyphen is not text: in the cluster of the grapheme
            // before it, where it follows that grapheme's own glyph.
            .cluster = p.graphemes.atOrBefore(at - 1).?,
        };
    }

    /// Hyphenation points in `from..to`, increasing: inside words (runs of
    /// letters, marks, and apostrophes), in each word's language, at
    /// grapheme boundaries.
    fn hyphenPoints(self: *Builder, from: u32, to: u32, out: *std.ArrayList(u32)) !void {
        const h = self.hyphenation orelse return;
        const p = self.p;
        var i = from;
        while (i < to) {
            const len = std.unicode.utf8ByteSequenceLength(p.text[i]) catch 1;
            const cp = std.unicode.utf8Decode(p.text[i..@min(p.text.len, i + len)]) catch 0;
            if (!hyphen_.isWordChar(cp)) {
                i += len;
                continue;
            }
            const word_start = i;
            while (i < to) {
                const l = std.unicode.utf8ByteSequenceLength(p.text[i]) catch 1;
                const c = std.unicode.utf8Decode(p.text[i..@min(p.text.len, i + l)]) catch 0;
                if (!hyphen_.isWordChar(c)) break;
                i += l;
            }
            const language = p.styles[p.styleAt(word_start)].language;
            const hyph = try h.get(language) orelse continue;
            var found: std.ArrayList(u32) = .empty;
            try hyph.points(self.scratch, p.text[word_start..i], &found, self.scratch);
            for (found.items) |off| {
                const at = word_start + off;
                if (p.graphemes.atOrBefore(at) == at) try out.append(self.scratch, at);
            }
        }
    }

    const HyphenBreak = struct { at: u32, hyphen: Hyphen };

    /// The last hyphenation point in `from..to` (a segment's text) where
    /// the text from `from` and a hyphen fit in `room`.
    fn hyphenBreak(self: *Builder, from: u32, to: u32, room: f32) !?HyphenBreak {
        const content_end = paragraph_.hangingStart(self.p.text, from, to);
        var points: std.ArrayList(u32) = .empty;
        try self.hyphenPoints(from, content_end, &points);
        var k = points.items.len;
        while (k > 0) {
            k -= 1;
            const at = points.items[k];
            const hy = self.hyphenAt(at) orelse continue;
            if (fits(room, self.advanceOf(from, at) + hy.advance)) return .{ .at = at, .hyphen = hy };
        }
        return null;
    }

    /// The shaped advance of `from..to`.
    fn advanceOf(self: *const Builder, from: u32, to: u32) f32 {
        var it: LogicalGlyphs = .init(self.p, from, to);
        var w: f32 = 0;
        while (it.next()) |g| w += g.advance;
        return w;
    }

    /// A place a line may end, for total-fit breaking: the end of a
    /// segment, or a hyphenation point inside one.
    const Candidate = struct {
        at: u32,
        /// Totals from the text's start: natural width, stretch, and
        /// shrink, up to the end of a line ending here (without its
        /// hanging whitespace) and up to where the next line starts.
        w_end: f64,
        w_next: f64,
        s_end: f64,
        s_next: f64,
        z_end: f64,
        z_next: f64,
        hyphen: ?Hyphen = null,
        forced: bool = false,
        unsafe: bool = false,
        penalty: f64 = 0,
    };

    /// Knuth and Plass's total-fit line breaking: the breaks minimizing
    /// the paragraph's demerits, by dynamic programming over every
    /// opportunity (forced breaks split the text). Interword spaces (each
    /// segment's hanging whitespace when the line goes on) stretch by
    /// half their width and never shrink, since justification only widens
    /// them and ragged lines must fit; a paragraph's last line
    /// may fall short freely. The adjustment ratio r is the room left over
    /// the stretch plus 3% of the width (so lines without spaces are not
    /// all equally bad, as with TeX's capped badness, where a first line
    /// of one hyphenated syllable tied with a loose line of words);
    /// badness is 100 |r|³, demerits (10 + badness)² plus the square of a
    /// hyphen's penalty (50) and 3000 for consecutive hyphenated lines. A line no break
    /// can make fit overflows, with demerits growing with the overflow.
    fn breakOptimal(self: *Builder) !void {
        const p = self.p;
        const segments = p.segments;
        var cands: std.ArrayList(Candidate) = .empty;
        try cands.append(self.scratch, .{ .at = 0, .w_end = 0, .w_next = 0, .s_end = 0, .s_next = 0, .z_end = 0, .z_next = 0 });
        var w: f64 = 0;
        var s: f64 = 0;
        const z: f64 = 0;
        var points: std.ArrayList(u32) = .empty;
        for (segments, 0..) |seg, j| {
            const from: u32 = if (j == 0) 0 else segments[j - 1].end;
            if (self.hyphenation != null) {
                points.clearRetainingCapacity();
                try self.hyphenPoints(from, paragraph_.hangingStart(p.text, from, seg.end), &points);
                for (points.items) |at| {
                    const hy = self.hyphenAt(at) orelse continue;
                    const prefix: f64 = self.advanceOf(from, at);
                    try cands.append(self.scratch, .{ .at = at, .w_end = w + prefix, .w_next = w + prefix, .s_end = s, .s_next = s, .z_end = z, .z_next = z, .hyphen = hy, .unsafe = true, .penalty = 50 });
                }
            }
            const hanging: f64 = seg.trailing;
            try cands.append(self.scratch, .{
                .at = seg.end,
                .w_end = w + seg.advance - hanging,
                .w_next = w + seg.advance,
                .s_end = s,
                .s_next = s + hanging / 2,
                .z_end = z,
                .z_next = z,
                .forced = seg.mandatory or j + 1 == segments.len,
                .unsafe = seg.unsafe,
            });
            w += seg.advance;
            s += hanging / 2;
        }
        const c = cands.items;
        const best = try self.scratch.alloc(f64, c.len);
        const prev = try self.scratch.alloc(u32, c.len);
        best[0] = 0;
        var floor: usize = 0;
        for (1..c.len) |k| {
            best[k] = std.math.inf(f64);
            prev[k] = @intCast(k - 1);
            var a = k;
            while (a > floor) {
                a -= 1;
                const limit: f64 = self.frame(c[a].at).limit.?;
                const natural = c[k].w_end - c[a].w_next + if (c[k].hyphen) |hy| @as(f64, hy.advance) else 0;
                const stretch = c[k].s_end - c[a].s_next;
                const shrink = c[k].z_end - c[a].z_next;
                var d: f64 = undefined;
                if (natural > limit + shrink + 0.001) {
                    // Overfull: only as the one way out.
                    if (a + 1 != k and best[k] < std.math.inf(f64)) break;
                    d = 1e12 + (natural - limit) * 1e6;
                } else {
                    // Lines without spaces still give a little (3% of
                    // the width), so a loose line is worse the looser it
                    // is rather than all equally bad.
                    const give = stretch + 0.03 * limit;
                    const r: f64 = if (natural <= limit)
                        (if (c[k].forced) 0 else (limit - natural) / give)
                    else
                        (limit - natural) / @max(shrink, 1e-9);
                    const badness = @min(1e10, 100 * @abs(r) * @abs(r) * @abs(r));
                    d = (10 + badness) * (10 + badness) + c[k].penalty * c[k].penalty;
                    if (c[k].hyphen != null and c[a].hyphen != null) d += 3000;
                }
                if (best[a] + d < best[k]) {
                    best[k] = best[a] + d;
                    prev[k] = @intCast(a);
                }
            }
            if (c[k].forced) floor = k;
        }
        // Back from the end, then forward.
        var chain: std.ArrayList(u32) = .empty;
        var k: u32 = @intCast(c.len - 1);
        while (k != 0) : (k = prev[k]) try chain.append(self.scratch, k);
        var a: u32 = 0;
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            const b = chain.items[i];
            const start = c[a].at;
            const end = c[b].at;
            const f = self.frame(start);
            const pieces = try self.linePieces(start, end, c[a].unsafe, c[b].unsafe);
            try self.placeTabs(pieces, f.indent, f.style);
            try self.emitLine(start, end, pieces, f, c[b].hyphen);
            a = b;
        }
        if (self.lines.items.len == 0 or (self.final_line and self.endsWithBreak())) {
            const len: u32 = @intCast(p.text.len);
            try self.emitLine(len, len, &.{}, self.frame(len), null);
        }
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

    fn emitLine(self: *Builder, start: u32, end: u32, pieces: []Piece, fr: LineFrame, hyphen: ?Hyphen) !void {
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
                try self.glyphs.append(self.scratch, .{ .id = glyph.id, .x = pen + glyph.x_offset, .y = glyph.y_offset, .advance = glyph.advance, .cluster = glyph.cluster });
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
            try self.runs.append(self.scratch, .{
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
        if (self.carets.items.len == caret_start) try self.carets.append(self.scratch, .{ .offset = start, .x = 0, .affinity = .downstream });
        if (hyphen) |hy| {
            // At the visual end of the (left-to-right) line, after its
            // last caret stop: it is shown, not text.
            const at: u32 = @intCast(self.glyphs.items.len);
            try self.glyphs.append(self.scratch, .{ .id = hy.id, .x = pen, .y = 0, .advance = hy.advance, .cluster = hy.cluster });
            pen += hy.advance;
            const merge = self.runs.items.len > run_start and blk: {
                const last = self.runs.items[self.runs.items.len - 1];
                break :blk last.font == hy.font and last.size == hy.size and !last.rtl and last.glyph_end == at;
            };
            if (merge) {
                self.runs.items[self.runs.items.len - 1].glyph_end = at + 1;
            } else {
                try self.runs.append(self.scratch, .{ .font = hy.font, .size = hy.size, .style = hy.style, .start = hy.cluster, .end = end, .rtl = false, .glyph_start = at, .glyph_end = at + 1 });
            }
        }

        self.inkRuns(run_start, @intCast(self.runs.items.len));
        const hang = paragraph_.hangingStart(p.text, start, end);
        var hanging: f32 = 0;
        for (self.glyphs.items[glyph_start_line..]) |glyph| {
            if (glyph.cluster >= hang) hanging += glyph.advance;
        }
        try self.lines.append(self.scratch, .{
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
            .indent_start = fr.indent,
            .indent_end = fr.style.indent_end,
            .alignment = fr.style.alignment,
        });
    }

    /// Sets the ink bounds of runs `from..to` from their glyphs.
    fn inkRuns(self: *Builder, from: u32, to: u32) void {
        for (self.runs.items[from..to]) |*run| {
            const face = self.cache.face(run.font) orelse continue;
            var x0: f32 = std.math.inf(f32);
            var y0: f32 = std.math.inf(f32);
            var x1: f32 = -std.math.inf(f32);
            var y1: f32 = -std.math.inf(f32);
            for (self.glyphs.items[run.glyph_start..run.glyph_end]) |g| {
                const b = face.glyphBounds(g.id, run.size) orelse continue;
                if (!(b.width > 0 and b.height > 0)) continue;
                x0 = @min(x0, g.x + b.x);
                y0 = @min(y0, g.y + b.y);
                x1 = @max(x1, g.x + b.x + b.width);
                y1 = @max(y1, g.y + b.y + b.height);
            }
            run.ink = if (x1 > x0) .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        }
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
                    try self.carets.append(self.scratch, .{ .offset = g_end, .x = edge_left, .affinity = .upstream });
                    try self.carets.append(self.scratch, .{ .offset = g_start, .x = edge_right, .affinity = .downstream });
                } else {
                    try self.carets.append(self.scratch, .{ .offset = g_start, .x = edge_left, .affinity = .downstream });
                    try self.carets.append(self.scratch, .{ .offset = g_end, .x = edge_right, .affinity = .upstream });
                }
                edge_left = edge_right;
            }
            pen += advance;
            i = j;
        }
    }

    /// Widens the word separators of a line that does not end its
    /// paragraph so that its content fills `target`, moving the glyphs
    /// and caret stops after each.
    fn justify(self: *Builder, line: *Line, target: f32) void {
        const p = self.p;
        const extra = target - line.width;
        if (!(extra > 0.01) or line.run_start == line.run_end) return;
        if (line.end >= p.text.len or line.end >= p.paragraphs[line.paragraph].end) return;
        const hang = paragraph_.hangingStart(p.text, line.start, line.end);
        const glyphs = self.glyphs.items[self.runs.items[line.run_start].glyph_start..self.runs.items[line.run_end - 1].glyph_end];
        var count: usize = 0;
        for (glyphs) |g| {
            if (g.cluster < hang and isSeparator(p.text[g.cluster..])) count += 1;
        }
        if (count == 0) return;
        const per = extra / @as(f32, @floatFromInt(count));
        // Caret stops move by the separators wholly left of them.
        const carets = self.carets.items[line.caret_start..line.caret_end];
        for (carets) |*cs| {
            var n: f32 = 0;
            for (glyphs) |g| {
                if (g.cluster < hang and isSeparator(p.text[g.cluster..]) and g.x + g.advance <= cs.x + 0.01) n += 1;
            }
            cs.x += n * per;
        }
        var shift: f32 = 0;
        for (glyphs) |*g| {
            g.x += shift;
            if (g.cluster < hang and isSeparator(p.text[g.cluster..])) {
                g.advance += per;
                shift += per;
            }
        }
        line.advance += extra;
        line.width += extra;
    }

    /// Applies alignment and indents, and stacks lines vertically with
    /// their paragraphs' line and paragraph spacing.
    /// Where the next line goes: its top, before the space between
    /// paragraphs, and the paragraph of the line before.
    const Place = struct { top: f32 = 0, previous: ?u32 = null };

    fn position(self: *Builder, options: Options) void {
        _ = self.positionRange(options, 0, self.lines.items.len, .{});
    }

    /// Places lines `from..to`, the first at `place`, and returns where
    /// the next would go.
    fn positionRange(self: *Builder, options: Options, from: usize, to: usize, place: Place) Place {
        var widest: f32 = 0;
        if (options.width == null) for (self.lines.items) |line| {
            widest = @max(widest, line.width + line.indent_start + line.indent_end);
        };
        const available = options.width orelse widest;
        var top = place.top;
        var previous = place.previous;
        for (self.lines.items[from..to]) |*line| {
            const index = self.paragraphIndex(line.start);
            const style = self.styles[index];
            if (previous) |p| if (p != index) {
                top += self.styles[p].space_after + style.space_before;
            };
            previous = index;
            if ((line.alignment orelse options.alignment) == .justify) if (options.width) |w| {
                self.justify(line, w - line.indent_start - line.indent_end);
                // Justification moved the glyphs.
                self.inkRuns(line.run_start, line.run_end);
            };
            // Hanging whitespace sits at the logical end: right for
            // left-to-right lines, left for right-to-left ones.
            line.x = line.contentXIn(available, line.rtl(), options.alignment) - if (line.rtl()) line.advance - line.width else 0;
            const natural = line.height;
            const height = if (style.line_height > 0) style.line_height else natural * style.line_spacing;
            line.top = top;
            line.baseline = top + (height - natural) / 2 + line.ascent;
            line.height = height;
            top += height;
        }
        return .{ .top = top, .previous = previous };
    }
};

/// Whether a character is a word separator that justification widens.
fn isSeparator(ch: []const u8) bool {
    return ch[0] == ' ' or std.mem.startsWith(u8, ch, "\u{00A0}") or std.mem.startsWith(u8, ch, "\u{3000}");
}

/// The glyphs of `from..to` in logical order: runs in order, each run's
/// glyphs reversed when it is right to left.
const LogicalGlyphs = struct {
    p: *const ShapedParagraph,
    from: u32,
    to: u32,
    run: usize,
    index: usize = 0,

    fn init(p: *const ShapedParagraph, from: u32, to: u32) LogicalGlyphs {
        var low: usize = 0;
        var high = p.runs.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (p.runs[middle].end <= from) low = middle + 1 else high = middle;
        }
        return .{ .p = p, .from = from, .to = to, .run = low };
    }

    fn next(it: *LogicalGlyphs) ?Glyph {
        while (it.run < it.p.runs.len) {
            const run = it.p.runs[it.run];
            if (run.start >= it.to) return null;
            const glyphs = it.p.runGlyphs(run);
            while (it.index < glyphs.len) {
                const g = glyphs[if (run.rtl()) glyphs.len - 1 - it.index else it.index];
                it.index += 1;
                if (g.cluster >= it.from and g.cluster < it.to) return g;
            }
            it.run += 1;
            it.index = 0;
        }
        return null;
    }
};

/// The style of each bidi paragraph, and of the line after a final break,
/// from the runs (each paragraph takes the run containing its start).
fn paragraphStyles(scratch: std.mem.Allocator, p: *const ShapedParagraph, runs: []const ParagraphRun) ![]ParagraphStyle {
    const out = try scratch.alloc(ParagraphStyle, p.paragraphs.len + 1);
    for (out, 0..) |*style, i| {
        const start: u32 = if (i < p.paragraphs.len) p.paragraphs[i].start else @intCast(p.text.len);
        style.* = for (runs) |run| {
            if (start < run.end) break run.style;
        } else if (runs.len != 0) runs[runs.len - 1].style else .{};
        if (!(style.line_spacing > 0) or !std.math.isFinite(style.line_spacing)) style.line_spacing = 1;
        inline for (.{ "indent_start", "indent_end", "first_line_indent", "line_height", "space_before", "space_after", "tab_width" }) |name| {
            if (!std.math.isFinite(@field(style, name))) @field(style, name) = 0;
        }
    }
    return out;
}

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

/// Left edge of the glyph for byte `offset`, from the layout origin.
fn glyphX(l: *const Layout, offset: u32) ?f32 {
    for (l.lines) |line| for (l.lineRuns(line)) |run| for (l.runGlyphs(run)) |g| {
        if (g.cluster == offset) return line.x + g.x;
    };
    return null;
}

test "tabs advance to explicit stops from the start margin, then to multiples of the tab width" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("a\tb\tc\td", .auto_ltr);
    defer p.deinit();
    const stops = [_]TabStop{ .{ .position = 50 }, .{ .position = 120 } };
    var l = try layoutOf(&fixture, &p, .{ .tab_stops = &stops, .paragraphs = &.{.{ .end = 7, .style = .{ .tab_width = 40 } }} });
    defer l.deinit();
    try std.testing.expectApproxEqAbs(50, glyphX(&l, 2).?, 0.01);
    try std.testing.expectApproxEqAbs(120, glyphX(&l, 4).?, 0.01);
    // Past the stops, the next multiple of 40 after c.
    const c_end = glyphX(&l, 4).? + p.glyphs[4].advance;
    try std.testing.expectApproxEqAbs(@ceil(c_end / 40) * 40, glyphX(&l, 6).?, 0.01);

    // Stops count from the margin, not the indent: an indented line still
    // puts b at 50.
    var indented = try layoutOf(&fixture, &p, .{ .tab_stops = &stops, .paragraphs = &.{.{ .end = 7, .style = .{ .indent_start = 20 } }} });
    defer indented.deinit();
    try std.testing.expectApproxEqAbs(20, glyphX(&indented, 0).?, 0.01);
    try std.testing.expectApproxEqAbs(50, glyphX(&indented, 2).?, 0.01);

    // Without stops or a width, multiples of the shaped tab (four spaces).
    var plain = try layoutOf(&fixture, &p, .{});
    defer plain.deinit();
    const tab = p.glyphs[1].advance;
    try std.testing.expectApproxEqAbs(tab, glyphX(&plain, 2).?, 0.01);
    try std.testing.expectApproxEqAbs(2 * tab, glyphX(&plain, 4).?, 0.01);
}

test "a tab's advance decides where lines break" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("aa\tbb", .auto_ltr);
    defer p.deinit();
    const bb = p.glyphs[3].advance + p.glyphs[4].advance;
    // bb after a stop at 100 needs 100 + bb; one pixel less wraps it.
    var fits = try layoutOf(&fixture, &p, .{ .width = 100 + bb, .tab_stops = &.{.{ .position = 100 }} });
    defer fits.deinit();
    try std.testing.expectEqual(1, fits.lines.len);
    var wraps = try layoutOf(&fixture, &p, .{ .width = 100 + bb - 1, .tab_stops = &.{.{ .position = 100 }} });
    defer wraps.deinit();
    try std.testing.expectEqual(2, wraps.lines.len);
    try std.testing.expectEqual(3, wraps.lines[1].start);
    // The tab hangs at the end of the first line.
    try std.testing.expect(wraps.lines[0].advance > wraps.lines[0].width + 50);
}

test "words too wide for a line break between graphemes when asked" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const text = "go abcdefghijklmnop to";
    var p = try fixture.shape(text, .auto_ltr);
    defer p.deinit();
    const width = 4 * p.glyphs[3].advance + 1;
    var overflow = try layoutOf(&fixture, &p, .{ .width = width });
    defer overflow.deinit();
    try std.testing.expect(overflow.width > width);
    var broken = try layoutOf(&fixture, &p, .{ .width = width, .break_words = true });
    defer broken.deinit();
    var covered: u32 = 0;
    for (broken.lines) |line| {
        try std.testing.expectEqual(covered, line.start);
        try std.testing.expect(line.width <= width + 0.001);
        covered = line.end;
    }
    try std.testing.expectEqual(text.len, covered);
    // "go " stays whole; the long word starts a line and breaks inside.
    try std.testing.expectEqual(3, broken.lines[0].end);
    try std.testing.expect(broken.lines.len >= 5);
    // Every glyph appears once.
    var total: usize = 0;
    for (broken.runs) |run| total += run.glyph_end - run.glyph_start;
    try std.testing.expectEqual(p.glyphs.len, total);
    // A line narrower than one grapheme still takes one.
    var tiny = try layoutOf(&fixture, &p, .{ .width = 1, .break_words = true });
    defer tiny.deinit();
    try std.testing.expect(tiny.lines.len > text.len / 2);
}

test "paragraph styles: indents, alignment, line and paragraph spacing" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const text = "aaa aaa aaa\nbbb\nccc";
    var p = try fixture.shape(text, .auto_ltr);
    defer p.deinit();
    var plain = try layoutOf(&fixture, &p, .{});
    defer plain.deinit();
    const natural = plain.lines[0].height;
    const word = p.segments[0].advance - p.segments[0].trailing;

    const runs = [_]ParagraphRun{
        // The first paragraph: indented, its first line further, double
        // spaced, with space after it.
        .{ .end = 12, .style = .{ .indent_start = 10, .indent_end = 5, .first_line_indent = 20, .line_spacing = 2, .space_after = 7, .space_before = 100 } },
        // The second: centered, an exact line height, space before it.
        .{ .end = 16, .style = .{ .alignment = .center, .line_height = 30, .space_before = 3 } },
        .{ .end = @intCast(text.len), .style = .{} },
    };
    // Room for two words after the first line's 30 px of indent and 5 at
    // the end; later lines have 15 px of indents.
    const width = 30 + 5 + 2 * word + p.segments[0].trailing + 1;
    var l = try layoutOf(&fixture, &p, .{ .width = width, .paragraphs = &runs });
    defer l.deinit();
    try std.testing.expectEqual(4, l.lines.len);
    try std.testing.expectEqual(8, l.lines[0].end);
    try std.testing.expectEqual(30, l.lines[0].indent_start);
    try std.testing.expectEqual(10, l.lines[1].indent_start);
    try std.testing.expectApproxEqAbs(30, l.lines[0].x, 0.01);
    try std.testing.expectApproxEqAbs(10, l.lines[1].x, 0.01);
    // Space before the text's first paragraph does not apply.
    try std.testing.expectEqual(0, l.lines[0].top);
    try std.testing.expectApproxEqAbs(2 * natural, l.lines[0].height, 0.01);
    try std.testing.expectApproxEqAbs(natural / 2 + plain.lines[0].ascent, l.lines[0].baseline, 0.01);
    try std.testing.expectApproxEqAbs(4 * natural + 7 + 3, l.lines[2].top, 0.01);
    try std.testing.expectEqual(30, l.lines[2].height);
    try std.testing.expectEqual(Alignment.center, l.lines[2].alignment.?);
    try std.testing.expectApproxEqAbs((width - l.lines[2].width) / 2, l.lines[2].x, 0.01);
    try std.testing.expectApproxEqAbs(l.lines[2].top + 30, l.lines[3].top, 0.01);
    try std.testing.expectApproxEqAbs(l.lines[3].top + natural, l.height, 0.01);
    // The widest line counts its indents.
    try std.testing.expectApproxEqAbs(@max(l.lines[0].width + 35, l.lines[1].width + 15), l.width, 0.01);
    // Placed in a box by its alignment and indents.
    // In a right-to-left box the start indent is on the right.
    try std.testing.expectApproxEqAbs(200 - 30 - l.lines[0].width, l.lines[0].contentXIn(200, true, .start), 0.01);
    try std.testing.expectApproxEqAbs(200 - 5 - l.lines[0].width, l.lines[0].contentXIn(200, false, .end), 0.01);
}

test "right-to-left paragraphs indent from the right" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("שלום עולם", .auto_ltr);
    defer p.deinit();
    var l = try layoutOf(&fixture, &p, .{ .width = 300, .paragraphs = &.{.{ .end = 17, .style = .{ .indent_start = 25 } }} });
    defer l.deinit();
    try std.testing.expectApproxEqAbs(275, l.lines[0].contentX() + l.lines[0].width, 0.01);
}

fn shapeIn(fixture: *Fixture, text: []const u8, language: []const u8) !ShapedParagraph {
    const fonts = [_]FontId{ fixture.latin, fixture.arabic, fixture.hebrew };
    return ShapedParagraph.init(std.testing.allocator, fixture.arena.allocator(), &fixture.cache, text, &.{.{
        .end = @intCast(text.len),
        .style = .{ .fonts = &fonts, .size = 16, .language = language },
    }}, .auto_ltr);
}

/// The right edge of a line's last glyph before its hanging whitespace.
fn contentRight(l: *const Layout, line: Line) f32 {
    const hang = paragraph_.hangingStart(l.paragraph.text, line.start, line.end);
    var right: f32 = 0;
    for (l.lineRuns(line)) |run| for (l.runGlyphs(run)) |g| {
        if (g.cluster < hang) right = @max(right, g.x + g.advance);
    };
    return line.x + right;
}

test "justified lines fill the width except a paragraph's last" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("aa aaa a aaaa aa\nshort", .auto_ltr);
    defer p.deinit();
    const width = p.segments[0].advance + p.segments[1].advance + p.segments[2].advance + 3;
    var l = try layoutOf(&fixture, &p, .{ .width = width, .alignment = .justify });
    defer l.deinit();
    try std.testing.expect(l.lines.len >= 3);
    // The first line's content reaches the right edge; its spaces grew.
    try std.testing.expectApproxEqAbs(width, contentRight(&l, l.lines[0]), 0.01);
    try std.testing.expectApproxEqAbs(width, l.lines[0].width, 0.01);
    const plain_a = p.glyphs[3].x_offset + p.segments[0].advance;
    try std.testing.expect(glyphX(&l, 3).? > plain_a + 0.5);
    // Caret stops moved with the glyphs: the stop before "aaa" is at its glyph.
    const stop = for (l.lineCarets(l.lines[0])) |cs| {
        if (cs.offset == 3 and cs.affinity == .downstream) break cs.x;
    } else unreachable;
    try std.testing.expectApproxEqAbs(glyphX(&l, 3).?, l.lines[0].x + stop, 0.01);
    // The last line of each paragraph keeps its natural spacing.
    var last_first_para: Line = undefined;
    for (l.lines) |line| if (line.end == 17) {
        last_first_para = line;
    };
    try std.testing.expect(last_first_para.width < width - 1);
    try std.testing.expect(l.lines[l.lines.len - 1].width < width - 1);
}

test "center, end, and decimal tab stops" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("x\tabc\t12.50\tz", .auto_ltr);
    defer p.deinit();
    const stops = [_]TabStop{ .{ .position = 100, .alignment = .center }, .{ .position = 200, .alignment = .decimal }, .{ .position = 300, .alignment = .end } };
    var l = try layoutOf(&fixture, &p, .{ .tab_stops = &stops });
    defer l.deinit();
    const abc = p.glyphs[2].advance + p.glyphs[3].advance + p.glyphs[4].advance;
    try std.testing.expectApproxEqAbs(100 - abc / 2, glyphX(&l, 2).?, 0.01);
    // The decimal point sits at the stop.
    try std.testing.expectApproxEqAbs(200, glyphX(&l, 8).?, 0.01);
    // "z" ends at the stop.
    try std.testing.expectApproxEqAbs(300 - p.glyphs[p.glyphs.len - 1].advance, glyphX(&l, 12).?, 0.01);
    // A decimal stop with no decimal point ends the text there.
    var q = try fixture.shape("x\t1250", .auto_ltr);
    defer q.deinit();
    const dec = [_]TabStop{.{ .position = 200, .alignment = .decimal, .decimal = ',' }};
    var m = try layoutOf(&fixture, &q, .{ .tab_stops = &dec });
    defer m.deinit();
    try std.testing.expectApproxEqAbs(200, contentRight(&m, m.lines[0]), 0.01);
}

test "hyphenation breaks words at their language's points, with a hyphen" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var reg: hyphen_.Hyphenation = .init(std.testing.allocator);
    defer reg.deinit();
    const text = "hyphenation hyphenation";
    var p = try shapeIn(&fixture, text, "en-US");
    defer p.deinit();
    const word = p.segments[0].advance;
    var width: f32 = word;
    for (p.glyphs[12..15]) |g| width += g.advance; // "hyp" fits, but the point is after "hy"
    var l = try layoutOf(&fixture, &p, .{ .width = width, .hyphenate = true, .hyphenation = &reg });
    defer l.deinit();
    try std.testing.expectEqual(2, l.lines.len);
    try std.testing.expectEqual(14, l.lines[0].end); // "hy-" ends the first line
    const runs = l.lineRuns(l.lines[0]);
    const glyphs = l.runGlyphs(runs[runs.len - 1]);
    const last = glyphs[glyphs.len - 1];
    const face = fixture.cache.face(fixture.latin).?;
    var dash: u32 = 0;
    var minus: u32 = 0;
    _ = hb.hb_font_get_nominal_glyph(face.font, 0x2010, &dash);
    _ = hb.hb_font_get_nominal_glyph(face.font, '-', &minus);
    try std.testing.expect(last.id == dash or last.id == minus);
    try std.testing.expectEqual(13, last.cluster);
    try std.testing.expect(l.lines[0].width <= width + 0.001);
    // Every text glyph appears once, plus the hyphen.
    var total: usize = 0;
    for (l.runs) |run| total += run.glyph_end - run.glyph_start;
    try std.testing.expectEqual(p.glyphs.len + 1, total);
    // Off, or in a language without patterns, the word stays whole.
    var off = try layoutOf(&fixture, &p, .{ .width = width });
    defer off.deinit();
    try std.testing.expectEqual(12, off.lines[0].end);
    var q = try shapeIn(&fixture, text, "x-none");
    defer q.deinit();
    var none = try layoutOf(&fixture, &q, .{ .width = width, .hyphenate = true, .hyphenation = &reg });
    defer none.deinit();
    try std.testing.expectEqual(12, none.lines[0].end);
}

/// Knuth and Plass's demerits of a layout's lines (as breakOptimal counts
/// them, without hyphens): the paragraph's last line is free.
fn demerits(l: *const Layout, width: f32) f64 {
    var total: f64 = 0;
    for (l.lines[0 .. l.lines.len - 1]) |line| {
        const hang = paragraph_.hangingStart(l.paragraph.text, line.start, line.end);
        var stretch: f64 = 0;
        for (l.lineRuns(line)) |run| for (l.runGlyphs(run)) |g| {
            if (g.cluster < hang and l.paragraph.text[g.cluster] == ' ') stretch += g.advance / 2;
        };
        const r: f64 = (width - line.width) / (stretch + 0.03 * width);
        const badness = @min(1e10, 100 * r * r * r);
        total += (10 + badness) * (10 + badness);
    }
    return total;
}

test "total-fit breaking finds breaks with fewer demerits than greedy" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const text = "aaa bb cc ddddd ee ff gggg hh iiiii jj kk llll mm nnnnnn oo pp qqq rr";
    var p = try fixture.shape(text, .auto_ltr);
    defer p.deinit();
    const width = 12 * p.glyphs[0].advance;
    var greedy = try layoutOf(&fixture, &p, .{ .width = width });
    defer greedy.deinit();
    var optimal = try layoutOf(&fixture, &p, .{ .width = width, .optimal = true });
    defer optimal.deinit();
    var covered: u32 = 0;
    for (optimal.lines) |line| {
        try std.testing.expectEqual(covered, line.start);
        try std.testing.expect(line.width <= width + 0.001);
        covered = line.end;
    }
    try std.testing.expectEqual(text.len, covered);
    // Other breaks than greedy's, with fewer demerits: the minimum.
    const differ = for (optimal.lines, greedy.lines) |o, g| {
        if (o.end != g.end) break true;
    } else false;
    try std.testing.expect(differ);
    try std.testing.expect(demerits(&optimal, width) < demerits(&greedy, width));
    // Justified, its lines fill the width.
    var justified = try layoutOf(&fixture, &p, .{ .width = width, .optimal = true, .alignment = .justify });
    defer justified.deinit();
    for (justified.lines[0 .. justified.lines.len - 1]) |line| try std.testing.expectApproxEqAbs(width, line.width, 0.01);
    // A word wider than the line still gets a line of its own.
    var tiny = try layoutOf(&fixture, &p, .{ .width = 1, .optimal = true });
    defer tiny.deinit();
    try std.testing.expectEqual(p.segments.len, tiny.lines.len);
}

test "total-fit breaking uses hyphenation points" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var reg: hyphen_.Hyphenation = .init(std.testing.allocator);
    defer reg.deinit();
    var p = try shapeIn(&fixture, "hyphenation hyphenation hyphenation", "en-US");
    defer p.deinit();
    const width = p.segments[0].advance * 1.5;
    var l = try layoutOf(&fixture, &p, .{ .width = width, .optimal = true, .hyphenate = true, .hyphenation = &reg });
    defer l.deinit();
    var hyphenated = false;
    for (l.lines) |line| {
        try std.testing.expect(line.width <= width + 0.001);
        if (line.end < p.text.len and p.text[line.end - 1] != ' ') hyphenated = true;
    }
    try std.testing.expect(hyphenated);
}

test "reusing an edited text's layout gives the same lines as laying it out" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const pieces = [_][]const u8{ "Save the file and the rest of it", "\n", "حفظ الملف الآن", "\r\n", "שמור את הקובץ", "\r", " tab\tstop words go here ", "\u{2029}", "x", "\n", "ab cd ef gh ij kl mn op", "\n\n", "مرحبا world again" };
    const inserts = [_][]const u8{ "q", " ", "\n", "\r", "\r\n", "ש", "حف", "\u{2029}", "word word " };
    const fonts = [_]FontId{ fixture.latin, fixture.arabic, fixture.hebrew };
    var prng = std.Random.DefaultPrng.init(0x1a7);
    const rand = prng.random();
    // Paragraph spacing, so that moved lines move by the height change.
    const spaced: ParagraphStyle = .{ .space_before = 3, .space_after = 5, .line_spacing = 1.25 };
    const runs = [_]ParagraphRun{.{ .end = std.math.maxInt(u32), .style = spaced }};
    for ([_]Options{
        .{ .width = 90 },
        .{ .width = 60, .alignment = .justify, .paragraphs = &runs },
        .{ .width = 75, .break_words = true, .alignment = .center },
    }) |options| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(std.testing.allocator);
        for (0..3) |_| for (pieces) |p| try text.appendSlice(std.testing.allocator, p);
        var old_p = try fixture.shape(text.items, .auto_ltr);
        defer old_p.deinit();
        var old = try layoutOf(&fixture, &old_p, options);
        defer old.deinit();
        var reused_some = false;
        for (0..120) |_| {
            var at = rand.uintLessThan(usize, text.items.len + 1);
            while (at < text.items.len and text.items[at] & 0xc0 == 0x80) at += 1;
            if (rand.boolean() and at < text.items.len) {
                var end = @min(at + 1 + rand.uintLessThan(usize, 4), text.items.len);
                while (end < text.items.len and text.items[end] & 0xc0 == 0x80) end += 1;
                try text.replaceRange(std.testing.allocator, at, end - at, "");
            } else {
                try text.insertSlice(std.testing.allocator, at, inserts[rand.uintLessThan(usize, inserts.len)]);
            }
            const styles = [_]paragraph_.StyleRun{.{ .end = @intCast(text.items.len), .style = .{ .fonts = &fonts, .size = 16 } }};
            const p = try ShapedParagraph.initReusing(std.testing.allocator, fixture.arena.allocator(), &fixture.cache, text.items, &styles, .auto_ltr, &old_p);
            var want = try layoutOf(&fixture, &p, options);
            defer want.deinit();
            const got = try Layout.initReusing(std.testing.allocator, fixture.arena.allocator(), &fixture.cache, &p, options, &old);
            if (p.reused != null) reused_some = true;
            const same = blk: {
                std.testing.expectEqualSlices(Line, want.lines, got.lines) catch |e| break :blk e;
                std.testing.expectEqualSlices(GlyphRun, want.runs, got.runs) catch |e| break :blk e;
                std.testing.expectEqualSlices(PositionedGlyph, want.glyphs, got.glyphs) catch |e| break :blk e;
                std.testing.expectEqualSlices(Caret, want.carets, got.carets) catch |e| break :blk e;
                std.testing.expectEqual(want.width, got.width) catch |e| break :blk e;
                std.testing.expectEqual(want.height, got.height) catch |e| break :blk e;
                break :blk {};
            };
            // The old layout points at the old paragraph: replace both.
            old.deinit();
            old_p.deinit();
            old = got;
            old_p = p;
            old.paragraph = &old_p;
            try same;
        }
        try std.testing.expect(reused_some);
    }
}
