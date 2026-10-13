//! ShapedParagraph: everything about a text that does not depend on the
//! available width (D13). Building one runs bidi analysis, script
//! itemization, UAX #14 and #29 segmentation, font fallback, and shaping
//! with full paragraph context. A width change only reruns layout.zig.
//!
//! The result owns one arena with all of its arrays; intermediates use the
//! caller's scratch allocator (an arena reset once per layout pass).

const std = @import("std");
const hb = @import("harfbuzz");
const uucode = @import("uucode");
const bidi = @import("bidi.zig");
const script_ = @import("script.zig");
const segmentation = @import("segmentation.zig");
const line_break = @import("line_break.zig");
const font_ = @import("font.zig");
const shape_ = @import("shape.zig");
const Boundaries = @import("boundaries.zig");

const FontId = font_.FontId;
const FontCache = font_.FontCache;
const Glyph = shape_.Glyph;
const Script = script_.Script;

pub const Style = struct {
    /// Fallback chain, primary first: usually Database.candidates().
    fonts: []const FontId,
    /// Pixels per em.
    size: f32,
    /// BCP 47 language tag passed to shaping (D21).
    language: []const u8 = "und",
};

/// A style applying up to byte offset `end` (exclusive), from the previous
/// run's end. Ends must increase and the last one must equal the text length.
pub const StyleRun = struct {
    end: u32,
    style: Style,
};

/// One shaped run: a single font, direction, script, and style. Runs are in
/// logical order and cover each paragraph's text except its separator.
pub const Run = struct {
    start: u32,
    end: u32,
    /// Index into `ShapedParagraph.paragraphs`.
    paragraph: u32,
    level: u8,
    script: Script,
    /// Index into `ShapedParagraph.styles`.
    style: u32,
    font: FontId,
    /// Range in `ShapedParagraph.glyphs`, in HarfBuzz output order.
    glyph_start: u32,
    glyph_end: u32,

    pub fn rtl(self: Run) bool {
        return self.level & 1 != 0;
    }
};

/// The text between two consecutive line-break opportunities, measured.
pub const Segment = struct {
    /// The opportunity that ends the segment (exclusive byte offset).
    end: u32,
    mandatory: bool,
    advance: f32,
    /// Advance of the whitespace at the end of the segment, which hangs past
    /// the line end when the line breaks here.
    trailing: f32,
    /// Ending a line here needs reshaping on both sides (HarfBuzz
    /// UNSAFE_TO_BREAK, or the break falls inside a glyph cluster).
    unsafe: bool,
};

pub const BuildError = error{ OutOfMemory, InvalidUtf8, TextTooLong, InvalidStyles };

pub const ShapedParagraph = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    styles: []const Style,
    style_ends: []const u32,
    direction: bidi.BaseDirection,
    paragraphs: []const bidi.Paragraph,
    /// Embedding level of every byte, before L1.
    levels: []const u8,
    classes: []const bidi.LineClass,
    runs: []const Run,
    glyphs: []const Glyph,
    segments: []const Segment,
    graphemes: Boundaries,
    words: segmentation.Words,
    /// Some grapheme has no glyph in any ready font and shows .notdef.
    missing: bool,
    /// Pending fonts that shaping would have tried. Load them into the cache
    /// and rebuild to improve the result.
    wanted: []const FontId,
    /// Set by `initReusing` when it kept paragraphs of the previous text:
    /// how they map, for `Layout.initReusing`.
    reused: ?Reuse = null,

    /// Paragraphs `0..first` and the text before `start` are the old
    /// text's; paragraphs from `new_rest` on are the old ones from
    /// `old_rest` on, moved by `new_end - old_end` bytes.
    pub const Reuse = struct {
        old_len: u32,
        old_paragraphs: u32,
        first: u32,
        old_rest: u32,
        new_rest: u32,
        start: u32,
        old_end: u32,
        new_end: u32,
    };

    /// `text` and `styles` are copied. `scratch` should be an arena; nothing
    /// in the result points into it.
    pub fn init(
        gpa: std.mem.Allocator,
        scratch: std.mem.Allocator,
        cache: *const FontCache,
        text: []const u8,
        styles: []const StyleRun,
        direction: bidi.BaseDirection,
    ) BuildError!ShapedParagraph {
        if (text.len >= std.math.maxInt(u32)) return error.TextTooLong;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        try validateStyles(cache, text, styles);

        var self: ShapedParagraph = undefined;
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.direction = direction;
        self.text = try a.dupe(u8, text);
        const copied = try a.alloc(Style, styles.len);
        const ends = try a.alloc(u32, styles.len);
        for (styles, copied, ends) |run, *style, *end| {
            style.* = .{ .fonts = try a.dupe(FontId, run.style.fonts), .size = run.style.size, .language = try a.dupe(u8, run.style.language) };
            end.* = run.end;
        }
        self.styles = copied;
        self.style_ends = ends;

        const analysis = try bidi.analyze(a, self.text, direction);
        self.paragraphs = analysis.paragraphs;
        self.levels = analysis.levels;
        self.classes = analysis.classes;
        self.graphemes = try segmentation.graphemes(a, self.text);
        self.words = try segmentation.words(a, self.text);

        var builder: Builder = .{
            .paragraph = &self,
            .cache = cache,
            .a = a,
            .scratch = scratch,
            .shaper = shape_.Shaper.init() catch return error.OutOfMemory,
        };
        defer builder.shaper.deinit();
        defer builder.glyphs.deinit(gpa);
        for (self.paragraphs, 0..) |paragraph, index| try builder.itemize(@intCast(index), paragraph);
        // Grown in scratch memory, kept at their final size; the glyphs,
        // most of a long text's memory, grow and stay outside the arena,
        // which grows by half again what it holds (`deinit` frees them).
        self.runs = try a.dupe(Run, builder.runs.items);
        self.glyphs = try builder.glyphs.toOwnedSlice(gpa);
        errdefer gpa.free(self.glyphs);
        self.missing = builder.missing;
        self.wanted = try a.dupe(FontId, builder.wanted.items);
        self.segments = try measure(a, scratch, &self);
        self.reused = null;
        return self;
    }

    /// Like `init`, but takes what does not change from `old`, the
    /// result for the text before this edit: the paragraphs the edit left
    /// alone keep their bidi levels, segmentation, shaping, and line-break
    /// opportunities, moved to their new offsets, and only the paragraphs
    /// around the change are analyzed and shaped again. Paragraphs are
    /// independent (UAX #9 P1, #14 LB4 and LB5, #29 GB4, GB5, WB3a, and
    /// WB3b break after separators, and shaping stops at them), so the
    /// result equals `init`'s. A keystroke in a 1.4 MB document reshaped
    /// all of it. Falls back to `init` when `old` cannot be reused: other
    /// style values, another direction, or fonts it was missing.
    pub fn initReusing(
        gpa: std.mem.Allocator,
        scratch: std.mem.Allocator,
        cache: *const FontCache,
        text: []const u8,
        styles: []const StyleRun,
        direction: bidi.BaseDirection,
        old_: ?*const ShapedParagraph,
    ) BuildError!ShapedParagraph {
        const old = old_ orelse return init(gpa, scratch, cache, text, styles, direction);
        if (old.direction != direction or old.missing or old.wanted.len != 0 or old.text.len == 0 or text.len == 0 or text.len >= std.math.maxInt(u32))
            return init(gpa, scratch, cache, text, styles, direction);
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        try validateStyles(cache, text, styles);

        // The changed bytes, from the common prefix and suffix.
        const shorter = @min(old.text.len, text.len);
        var prefix: usize = 0;
        while (prefix < shorter and old.text[prefix] == text[prefix]) prefix += 1;
        var suffix: usize = 0;
        while (suffix < shorter - prefix and old.text[old.text.len - 1 - suffix] == text[text.len - 1 - suffix]) suffix += 1;
        // Redo the paragraphs holding the change and one on each side, so
        // that separators made or split by it (CR before LF) are seen.
        const first = old.paragraphAt(@intCast(prefix)) -| 1;
        const last = @min(old.paragraphAt(@intCast(old.text.len - suffix)) + 1, @as(u32, @intCast(old.paragraphs.len - 1)));
        const start = old.paragraphs[first].start;
        const old_end = old.paragraphs[last].end;
        const delta: i64 = @as(i64, @intCast(text.len)) - @as(i64, @intCast(old.text.len));
        const new_end: u32 = @intCast(@as(i64, old_end) + delta);
        // Nothing to keep, or nothing between the kept paragraphs.
        if ((first == 0 and last == old.paragraphs.len - 1) or new_end == start) return init(gpa, scratch, cache, text, styles, direction);

        // Kept runs refer to styles by index: those values and the ends
        // outside the redone bytes must not have changed.
        if (styles.len != old.styles.len) return init(gpa, scratch, cache, text, styles, direction);
        for (styles, old.styles, old.style_ends) |new, o, old_style_end| {
            if (new.style.size != o.size or !std.mem.eql(FontId, new.style.fonts, o.fonts) or !std.mem.eql(u8, new.style.language, o.language))
                return init(gpa, scratch, cache, text, styles, direction);
            const moved: i64 = if (old_style_end >= old_end) old_style_end + delta else old_style_end;
            if ((old_style_end <= start or old_style_end >= old_end) and new.end != moved)
                return init(gpa, scratch, cache, text, styles, direction);
        }

        // The middle, analyzed and shaped on its own in the scratch arena.
        const style_first = blk: {
            for (styles, 0..) |run, i| if (run.end > start) break :blk i;
            break :blk styles.len - 1;
        };
        var mid_styles: std.ArrayList(StyleRun) = .empty;
        for (styles[style_first..]) |run| {
            try mid_styles.append(scratch, .{ .end = @min(run.end, new_end) - start, .style = run.style });
            if (run.end >= new_end) break;
        }
        var mid = try init(scratch, scratch, cache, text[start..new_end], mid_styles.items, direction);
        defer mid.deinit();

        var self: ShapedParagraph = undefined;
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.direction = direction;
        self.text = try a.dupe(u8, text);
        const copied = try a.alloc(Style, styles.len);
        const ends = try a.alloc(u32, styles.len);
        for (styles, copied, ends) |run, *style, *end| {
            style.* = .{ .fonts = try a.dupe(FontId, run.style.fonts), .size = run.style.size, .language = try a.dupe(u8, run.style.language) };
            end.* = run.end;
        }
        self.styles = copied;
        self.style_ends = ends;
        const shift = struct {
            fn by(x: u32, d: i64) u32 {
                return @intCast(@as(i64, x) + d);
            }
        }.by;

        // Paragraphs and the per-byte arrays.
        const mid_count: u32 = @intCast(mid.paragraphs.len);
        const new_rest = first + mid_count;
        const dp: i64 = @as(i64, new_rest) - @as(i64, last + 1);
        const paragraphs = try a.alloc(bidi.Paragraph, old.paragraphs.len - (last + 1 - first) + mid_count);
        @memcpy(paragraphs[0..first], old.paragraphs[0..first]);
        for (paragraphs[first..new_rest], mid.paragraphs) |*out, in| out.* = .{ .start = in.start + start, .end = in.end + start, .separator_len = in.separator_len, .base_level = in.base_level };
        for (paragraphs[new_rest..], old.paragraphs[last + 1 ..]) |*out, in| out.* = .{ .start = shift(in.start, delta), .end = shift(in.end, delta), .separator_len = in.separator_len, .base_level = in.base_level };
        self.paragraphs = paragraphs;
        const levels = try a.alloc(u8, text.len);
        const classes = try a.alloc(bidi.LineClass, text.len);
        inline for (.{ .{ levels, old.levels, mid.levels }, .{ classes, old.classes, mid.classes } }) |arrays| {
            @memcpy(arrays[0][0..start], arrays[1][0..start]);
            @memcpy(arrays[0][start..new_end], arrays[2]);
            @memcpy(arrays[0][new_end..], arrays[1][old_end..]);
        }
        self.levels = levels;
        self.classes = classes;
        const len: u32 = @intCast(text.len);
        self.graphemes = try .init(a, len);
        self.words = .{ .boundaries = try .init(a, len), .starts = try .init(a, len) };
        inline for (.{ .{ &self.graphemes, old.graphemes, mid.graphemes }, .{ &self.words.boundaries, old.words.boundaries, mid.words.boundaries }, .{ &self.words.starts, old.words.starts, mid.words.starts } }) |sets| {
            sets[0].copyRange(0, sets[1], 0, start);
            sets[0].copyRange(start, sets[2], 0, sets[2].len);
            sets[0].copyRange(new_end, sets[1], old_end, sets[1].len);
        }

        // Runs and glyphs: the kept paragraphs' are contiguous at both ends.
        var run_first: usize = 0;
        while (run_first < old.runs.len and old.runs[run_first].paragraph < first) run_first += 1;
        var run_rest = run_first;
        while (run_rest < old.runs.len and old.runs[run_rest].paragraph <= last) run_rest += 1;
        const glyph_first: u32 = if (run_first < old.runs.len) old.runs[run_first].glyph_start else @intCast(old.glyphs.len);
        const glyph_rest: u32 = if (run_rest < old.runs.len) old.runs[run_rest].glyph_start else @intCast(old.glyphs.len);
        const glyphs = try gpa.alloc(Glyph, glyph_first + mid.glyphs.len + (old.glyphs.len - glyph_rest));
        errdefer gpa.free(glyphs);
        @memcpy(glyphs[0..glyph_first], old.glyphs[0..glyph_first]);
        for (glyphs[glyph_first..][0..mid.glyphs.len], mid.glyphs) |*out, in| {
            out.* = in;
            out.cluster += start;
        }
        const dg: i64 = @as(i64, @intCast(glyph_first + mid.glyphs.len)) - glyph_rest;
        for (glyphs[glyph_first + mid.glyphs.len ..], old.glyphs[glyph_rest..]) |*out, in| {
            out.* = in;
            out.cluster = shift(in.cluster, delta);
        }
        self.glyphs = glyphs;
        const runs = try a.alloc(Run, run_first + mid.runs.len + (old.runs.len - run_rest));
        @memcpy(runs[0..run_first], old.runs[0..run_first]);
        for (runs[run_first..][0..mid.runs.len], mid.runs) |*out, in| {
            out.* = in;
            out.start += start;
            out.end += start;
            out.paragraph += first;
            out.style += @intCast(style_first);
            out.glyph_start += glyph_first;
            out.glyph_end += glyph_first;
        }
        for (runs[run_first + mid.runs.len ..], old.runs[run_rest..]) |*out, in| {
            out.* = in;
            out.start = shift(in.start, delta);
            out.end = shift(in.end, delta);
            out.paragraph = shift(in.paragraph, dp);
            out.glyph_start = shift(in.glyph_start, dg);
            out.glyph_end = shift(in.glyph_end, dg);
        }
        self.runs = runs;

        // Line-break opportunities, sorted by their ends.
        var seg_first: usize = 0;
        while (seg_first < old.segments.len and old.segments[seg_first].end <= start) seg_first += 1;
        var seg_rest = seg_first;
        while (seg_rest < old.segments.len and old.segments[seg_rest].end <= old_end) seg_rest += 1;
        const segments = try a.alloc(Segment, seg_first + mid.segments.len + (old.segments.len - seg_rest));
        @memcpy(segments[0..seg_first], old.segments[0..seg_first]);
        for (segments[seg_first..][0..mid.segments.len], mid.segments) |*out, in| {
            out.* = in;
            out.end += start;
        }
        for (segments[seg_first + mid.segments.len ..], old.segments[seg_rest..]) |*out, in| {
            out.* = in;
            out.end = shift(in.end, delta);
        }
        self.segments = segments;

        self.missing = mid.missing;
        self.wanted = try a.dupe(FontId, mid.wanted);
        self.reused = .{
            .old_len = @intCast(old.text.len),
            .old_paragraphs = @intCast(old.paragraphs.len),
            .first = first,
            .old_rest = last + 1,
            .new_rest = new_rest,
            .start = start,
            .old_end = old_end,
            .new_end = new_end,
        };
        return self;
    }

    pub fn deinit(self: *ShapedParagraph) void {
        self.arena.child_allocator.free(self.glyphs);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Index of the style that applies at `offset`.
    pub fn styleAt(self: *const ShapedParagraph, offset: u32) u32 {
        return firstEndAfter(u32, self.style_ends, offset, {}, struct {
            fn end(_: void, e: u32) u32 {
                return e;
            }
        }.end);
    }

    pub fn runGlyphs(self: *const ShapedParagraph, run: Run) []const Glyph {
        return self.glyphs[run.glyph_start..run.glyph_end];
    }

    /// The index of the paragraph containing `offset` (the last one for the
    /// end of the text).
    pub fn paragraphAt(self: *const ShapedParagraph, offset: u32) u32 {
        return firstEndAfter(bidi.Paragraph, self.paragraphs, offset, {}, struct {
            fn end(_: void, p: bidi.Paragraph) u32 {
                return p.end;
            }
        }.end);
    }
};

/// The index of the first item whose end is past `offset`, or the last
/// item: a binary search over items with increasing ends. Layout asks for
/// every line's paragraph, so a linear scan was quadratic in a long text.
fn firstEndAfter(comptime T: type, items: []const T, offset: u32, ctx: anytype, comptime endOf: fn (@TypeOf(ctx), T) u32) u32 {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (endOf(ctx, items[middle]) <= offset) low = middle + 1 else high = middle;
    }
    return @intCast(@min(low, items.len - 1));
}

/// A run's fonts may be empty only when `cache` has a last-resort face.
pub fn validateStyles(cache: *const FontCache, text: []const u8, styles: []const StyleRun) !void {
    if (styles.len == 0 or styles[styles.len - 1].end != text.len) return error.InvalidStyles;
    var previous: u32 = 0;
    for (styles, 0..) |run, i| {
        if ((run.end <= previous and !(i == 0 and run.end == 0)) or run.end > text.len) return error.InvalidStyles;
        if (run.end < text.len and text[run.end] & 0xc0 == 0x80) return error.InvalidStyles;
        if ((run.style.fonts.len == 0 and cache.last_resort == null) or !std.math.isFinite(run.style.size) or run.style.size <= 0) return error.InvalidStyles;
        previous = run.end;
    }
}

const Item = struct {
    start: u32,
    end: u32,
    paragraph: u32,
    level: u8,
    script: Script,
    style: u32,
};

const Builder = struct {
    paragraph: *const ShapedParagraph,
    cache: *const FontCache,
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    shaper: shape_.Shaper,
    runs: std.ArrayList(Run) = .empty,
    glyphs: std.ArrayList(Glyph) = .empty,
    wanted: std.ArrayList(FontId) = .empty,
    probe: std.ArrayList(Glyph) = .empty,
    missing: bool = false,

    /// Splits a paragraph at level, script, and style changes and shapes
    /// each item.
    fn itemize(self: *Builder, index: u32, paragraph: bidi.Paragraph) !void {
        const p = self.paragraph;
        const end = paragraph.contentEnd();
        const scripts = try script_.analyze(self.scratch, p.text, p.graphemes, paragraph.start, end);
        var start = paragraph.start;
        var script_index: usize = 0;
        while (start < end) {
            while (scripts[script_index].end <= start) script_index += 1;
            const style = p.styleAt(start);
            var item_end = @min(scripts[script_index].end, p.style_ends[style]);
            const level = p.levels[start];
            var i = start + 1;
            while (i < item_end and p.levels[i] == level) i += 1;
            item_end = i;
            try self.shapeItem(.{ .start = start, .end = item_end, .paragraph = index, .level = level, .script = scripts[script_index].script, .style = style });
            start = item_end;
        }
    }

    fn want(self: *Builder, id: FontId) !void {
        if (std.mem.indexOfScalar(FontId, self.wanted.items, id) == null) try self.wanted.append(self.scratch, id);
    }

    fn request(self: *Builder, item: Item, face: *const font_.Face, start: u32, end: u32) shape_.Request {
        const p = self.paragraph;
        const style = p.styles[item.style];
        const paragraph = p.paragraphs[item.paragraph];
        return .{
            .face = face,
            .size = style.size,
            .text = p.text,
            .paragraph_start = paragraph.start,
            .paragraph_end = paragraph.contentEnd(),
            .start = start,
            .end = end,
            .rtl = item.level & 1 != 0,
            .script = item.script,
            .language = hb.hb_language_from_string(style.language.ptr, @intCast(style.language.len)),
        };
    }

    fn appendRun(self: *Builder, item: Item, id: FontId, start: u32, end: u32, glyphs: []const Glyph) !void {
        const glyph_start: u32 = @intCast(self.glyphs.items.len);
        try self.glyphs.appendSlice(self.paragraph.arena.child_allocator, glyphs);
        if (self.cache.face(id)) |face| hideControls(self.paragraph.text, face, item.paragraph, self.glyphs.items[glyph_start..], self.paragraph.styles[item.style].size);
        try self.runs.append(self.scratch, .{
            .start = start,
            .end = end,
            .paragraph = item.paragraph,
            .level = item.level,
            .script = item.script,
            .style = item.style,
            .font = id,
            .glyph_start = glyph_start,
            .glyph_end = @intCast(self.glyphs.items.len),
        });
    }

    /// Shapes an item with its style's fallback chain. The first ready font
    /// shapes the whole item; graphemes it renders as .notdef (or in the
    /// wrong emoji presentation) go to the first later font whose actual
    /// shaping output has no .notdef. Adjacent graphemes with the same font
    /// are shaped together, always with full paragraph context.
    ///
    /// Without a ready font, the cache's last-resort face shapes it
    /// (boxes), unless a font of the chain is still loading: then nothing
    /// shows until it loads, rather than boxes for a moment.
    fn shapeItem(self: *Builder, item: Item) !void {
        const p = self.paragraph;
        const fonts = p.styles[item.style].fonts;
        var loading = false;
        const primary = for (fonts) |id| switch (self.cache.state(id)) {
            .ready => break id,
            .pending => {
                try self.want(id);
                loading = true;
            },
            .failed => {},
        } else if (self.cache.last_resort != null and !loading) self.cache.last_resort.? else {
            // Nothing can shape this text until a font loads.
            self.missing = true;
            return self.appendRun(item, fonts[0], item.start, item.end, &.{});
        };
        const primary_face = self.cache.face(primary).?;

        self.probe.clearRetainingCapacity();
        try self.shaper.shape(self.scratch, self.request(item, primary_face, item.start, item.end), &self.probe);
        const text = p.text[item.start..item.end];
        const emoji = containsEmoji(text);
        if (!emoji and !hasNotdef(p.text, self.probe.items)) return self.appendRun(item, primary, item.start, item.end, self.probe.items);

        // Graphemes the primary font cannot render.
        const bad = try self.scratch.alloc(bool, item.end - item.start);
        @memset(bad, false);
        markNotdef(p.text, self.probe.items, item, bad);

        const Selection = struct { font: FontId, start: u32, end: u32 };
        var selections: std.ArrayList(Selection) = .empty;
        var start = item.start;
        while (start < item.end) {
            var end = @min(item.end, p.graphemes.after(start).?);
            const presentation = emojiPresentation(p.text[start..end]);
            const mismatched = if (presentation) |wanted| primary_face.color != (wanted == .emoji) else false;
            const chosen = if (!bad[start - item.start] and !mismatched) primary else chosen: {
                if (presentation == null) {
                    // A stretch of unrenderable graphemes (a word in another
                    // script) goes to the first font that renders all of it.
                    var stretch_end = end;
                    while (stretch_end < item.end and bad[stretch_end - item.start]) {
                        const next = @min(item.end, p.graphemes.after(stretch_end).?);
                        if (emojiPresentation(p.text[stretch_end..next]) != null) break;
                        stretch_end = next;
                    }
                    if (stretch_end > end) if (try self.chooseStretch(item, start, stretch_end, primary)) |id| {
                        end = stretch_end;
                        break :chosen id;
                    };
                }
                break :chosen try self.choose(item, start, end, primary, presentation);
            };
            if (selections.items.len != 0 and selections.items[selections.items.len - 1].font == chosen) {
                selections.items[selections.items.len - 1].end = end;
            } else {
                try selections.append(self.scratch, .{ .font = chosen, .start = start, .end = end });
            }
            start = end;
        }
        if (selections.items.len == 1 and selections.items[0].font == primary)
            return self.appendRun(item, primary, item.start, item.end, self.probe.items);
        for (selections.items) |selection| {
            self.probe.clearRetainingCapacity();
            try self.shaper.shape(self.scratch, self.request(item, self.cache.face(selection.font).?, selection.start, selection.end), &self.probe);
            if (hasNotdef(p.text, self.probe.items)) self.missing = true;
            try self.appendRun(item, selection.font, selection.start, selection.end, self.probe.items);
        }
    }

    /// The first ready font that renders all of `start..end`, if any.
    fn chooseStretch(self: *Builder, item: Item, start: u32, end: u32, primary: FontId) !?FontId {
        const p = self.paragraph;
        const base = firstCodepoint(p.text[start..end]);
        var glyphs: std.ArrayList(Glyph) = .empty;
        var wanted_one = false;
        for (p.styles[item.style].fonts) |id| {
            if (id == primary or !self.cache.mayCover(id, base)) continue;
            const face = self.cache.face(id) orelse {
                if (!wanted_one) try self.want(id);
                wanted_one = true;
                continue;
            };
            glyphs.clearRetainingCapacity();
            try self.shaper.shape(self.scratch, self.request(item, face, start, end), &glyphs);
            if (glyphs.items.len != 0 and !hasNotdef(p.text, glyphs.items)) return id;
            return null; // the best candidate fails somewhere: go grapheme by grapheme
        }
        return null;
    }

    /// Picks a font for one grapheme the primary font could not render.
    fn choose(self: *Builder, item: Item, start: u32, end: u32, primary: FontId, presentation: ?Presentation) !FontId {
        const p = self.paragraph;
        const base = firstCodepoint(p.text[start..end]);
        var usable: ?FontId = null;
        var wanted_one = false;
        var glyphs: std.ArrayList(Glyph) = .empty;
        for (p.styles[item.style].fonts) |id| {
            if (id == primary or !self.cache.mayCover(id, base)) continue;
            const face = self.cache.face(id) orelse {
                // Ask for the first pending font that may cover it; a later
                // ready font still renders it until that one loads.
                if (!wanted_one and usable == null) try self.want(id);
                wanted_one = true;
                continue;
            };
            glyphs.clearRetainingCapacity();
            try self.shaper.shape(self.scratch, self.request(item, face, start, end), &glyphs);
            if (glyphs.items.len == 0 or hasNotdef(p.text, glyphs.items)) continue;
            // Prefer a face that matches the requested emoji presentation,
            // but a mismatched face beats .notdef.
            if (presentation) |wanted| if (face.color != (wanted == .emoji)) {
                if (usable == null) usable = id;
                continue;
            };
            return id;
        }
        if (usable) |id| return id;
        // Unrenderable unless the primary font only had the wrong presentation.
        if (presentation == null or self.cache.face(primary).?.color == (presentation.? == .emoji)) self.missing = true;
        return primary;
    }
};

fn firstCodepoint(bytes: []const u8) u21 {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch unreachable;
    return std.unicode.utf8Decode(bytes[0..len]) catch unreachable;
}

/// Controls (tab, LS, ...) have no glyphs in most fonts; they are not
/// missing text. They draw nothing; a tab advances like four spaces.
fn isControl(text: []const u8, offset: u32) bool {
    const cp = firstCodepoint(text[offset..]);
    return switch (uucode.get(.general_category, cp)) {
        .other_control, .separator_line, .separator_paragraph => true,
        else => false,
    };
}

fn hasNotdef(text: []const u8, glyphs: []const Glyph) bool {
    for (glyphs) |glyph| if (glyph.id == 0 and !isControl(text, glyph.cluster)) return true;
    return false;
}

/// Marks the bytes of every cluster with a .notdef glyph.
fn markNotdef(text: []const u8, glyphs: []const Glyph, item: Item, bad: []bool) void {
    for (glyphs) |glyph| {
        if (glyph.id != 0 or isControl(text, glyph.cluster)) continue;
        // The cluster extends to the next larger cluster value in the run.
        var end = item.end;
        for (glyphs) |other| if (other.cluster > glyph.cluster and other.cluster < end) {
            end = other.cluster;
        };
        @memset(bad[glyph.cluster - item.start .. end - item.start], true);
    }
}

fn hideControls(text: []const u8, face: *const font_.Face, paragraph: u32, glyphs: []Glyph, size: f32) void {
    _ = paragraph;
    var space: u32 = 0;
    var space_advance: f32 = 0;
    for (glyphs) |*glyph| {
        if (glyph.id != 0 or !isControl(text, glyph.cluster)) continue;
        if (space_advance == 0) {
            var id: hb.hb_codepoint_t = 0;
            if (hb.hb_font_get_nominal_glyph(face.font, ' ', &id) != 0) space = id;
            space_advance = @as(f32, @floatFromInt(hb.hb_font_get_glyph_h_advance(face.font, space))) * face.scale(size);
        }
        glyph.id = space;
        glyph.x_offset = 0;
        glyph.y_offset = 0;
        glyph.advance = if (text[glyph.cluster] == '\t') 4 * space_advance else 0;
    }
}

const Presentation = enum { text, emoji };

fn containsEmoji(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x80) break;
    } else return false; // ASCII digits, # and * are emoji only with FE0F, which is not ASCII
    var iterator = uucode.utf8.Iterator.init(bytes);
    while (iterator.next()) |cp| if (uucode.get(.is_emoji, cp) and cp >= 0x80) return true;
    // Keycaps start with ASCII but contain U+20E3 or FE0F.
    return std.mem.indexOf(u8, bytes, "\u{FE0F}") != null or std.mem.indexOf(u8, bytes, "\u{20E3}") != null;
}

/// The presentation a grapheme requests, from UTS #51: explicit variation
/// selectors win; keycaps, modifier, and ZWJ sequences are emoji.
fn emojiPresentation(bytes: []const u8) ?Presentation {
    var iterator = uucode.utf8.Iterator.init(bytes);
    const base = iterator.next() orelse return null;
    if (!uucode.get(.is_emoji, base)) return null;
    var presentation: Presentation = if (uucode.get(.is_emoji_presentation, base)) .emoji else .text;
    var previous = base;
    var single = true;
    while (iterator.next()) |cp| {
        single = false;
        if (uucode.get(.is_emoji_vs_base, previous)) {
            if (cp == 0xFE0E) return .text;
            if (cp == 0xFE0F) return .emoji;
        }
        if (cp == 0x20E3 or cp == 0x200D or uucode.get(.is_emoji_presentation, cp)) presentation = .emoji;
        previous = cp;
    }
    // Plain ASCII digits and symbols are text, not emoji requests.
    if (single and base < 0x80) return null;
    return presentation;
}

/// Hanging whitespace: Zs characters that allow breaks, tab, and hard line
/// breaks. Whitespace at a line end does not count toward the line width.
fn isHanging(cp: u21) bool {
    if (cp == '\t') return true;
    return switch (uucode.get(.line_break, cp)) {
        .bk, .cr, .lf, .nl => true,
        .gl => false,
        else => uucode.get(.general_category, cp) == .separator_space,
    };
}

/// Where the hanging whitespace before `end` begins, not before `start`.
pub fn hangingStart(text: []const u8, start: u32, end: u32) u32 {
    var offset = end;
    while (offset > start) {
        var cp_start = offset - 1;
        while (text[cp_start] & 0xc0 == 0x80) cp_start -= 1;
        if (!isHanging(firstCodepoint(text[cp_start..]))) break;
        offset = cp_start;
    }
    return offset;
}

/// UAX #14 opportunities plus a mandatory break at every bidi paragraph end
/// (Bidi_Class B characters such as U+001C are not all hard line breaks),
/// so that no line spans two paragraphs.
fn opportunities(scratch: std.mem.Allocator, p: *const ShapedParagraph) ![]line_break.Opportunity {
    const found = try line_break.analyze(scratch, p.text);
    var merged: std.ArrayList(line_break.Opportunity) = try .initCapacity(scratch, found.len + p.paragraphs.len);
    var next_paragraph: usize = 0;
    for (found) |opportunity| {
        while (next_paragraph < p.paragraphs.len and p.paragraphs[next_paragraph].end <= opportunity.offset) : (next_paragraph += 1) {
            const end = p.paragraphs[next_paragraph].end;
            if (end < opportunity.offset) merged.appendAssumeCapacity(.{ .offset = end, .mandatory = true });
        }
        const at_paragraph_end = next_paragraph > 0 and p.paragraphs[next_paragraph - 1].end == opportunity.offset;
        merged.appendAssumeCapacity(.{ .offset = opportunity.offset, .mandatory = opportunity.mandatory or at_paragraph_end });
    }
    return merged.items;
}

/// Measures the segments between line-break opportunities.
fn measure(a: std.mem.Allocator, scratch: std.mem.Allocator, p: *const ShapedParagraph) ![]Segment {
    const breaks = try opportunities(scratch, p);
    const segments = try a.alloc(Segment, breaks.len);
    const hanging_start = try scratch.alloc(u32, breaks.len);
    var previous: u32 = 0;
    for (segments, breaks, hanging_start) |*segment, opportunity, *hang| {
        segment.* = .{ .end = opportunity.offset, .mandatory = opportunity.mandatory, .advance = 0, .trailing = 0, .unsafe = false };
        hang.* = hangingStart(p.text, previous, opportunity.offset);
        previous = opportunity.offset;
    }

    var next: usize = 0; // first segment that may end inside or after the current run
    for (p.runs) |run| {
        const glyphs = p.runGlyphs(run);
        while (segments[next].end <= run.start) next += 1;
        var s = next; // segment receiving the current cluster
        var previous_cluster: ?u32 = null;
        var i: usize = 0;
        while (i < glyphs.len) {
            // One logical cluster: consecutive glyphs with equal cluster values.
            const index = if (run.rtl()) glyphs.len - 1 - i else i;
            const cluster = glyphs[index].cluster;
            var advance: f32 = 0;
            var unsafe = false;
            while (i < glyphs.len) : (i += 1) {
                const glyph = glyphs[if (run.rtl()) glyphs.len - 1 - i else i];
                if (glyph.cluster != cluster) break;
                advance += glyph.advance;
                unsafe = unsafe or glyph.unsafe_to_break;
            }
            // Opportunities before this cluster but after the previous one
            // fall inside the previous cluster.
            while (segments[s].end < cluster) : (s += 1) {
                if (previous_cluster != null and segments[s].end > previous_cluster.?) segments[s].unsafe = true;
            }
            if (segments[s].end == cluster) {
                if (cluster > run.start) segments[s].unsafe = unsafe;
                s += 1;
            }
            segments[s].advance += advance;
            if (cluster >= hanging_start[s]) segments[s].trailing += advance;
            previous_cluster = cluster;
        }
        if (previous_cluster) |last| {
            while (segments[s].end < run.end) : (s += 1) {
                if (segments[s].end > last) segments[s].unsafe = true;
            }
        }
    }
    return segments;
}

pub const testing = struct {
    pub const Fixture = struct {
        cache: FontCache,
        latin: FontId,
        arabic: FontId,
        hebrew: FontId,
        arena: std.heap.ArenaAllocator,

        pub fn init() !Fixture {
            var cache: FontCache = .init(std.testing.allocator);
            errdefer cache.deinit();
            return .{
                .latin = try cache.add(font_.test_fonts.latin, 0, .borrowed),
                .arabic = try cache.add(font_.test_fonts.arabic, 0, .borrowed),
                .hebrew = try cache.add(font_.test_fonts.hebrew, 0, .borrowed),
                .cache = cache,
                .arena = .init(std.testing.allocator),
            };
        }

        pub fn deinit(self: *Fixture) void {
            self.cache.deinit();
            self.arena.deinit();
        }

        pub fn shape(self: *Fixture, text: []const u8, direction: bidi.BaseDirection) !ShapedParagraph {
            const fonts = [_]FontId{ self.latin, self.arabic, self.hebrew };
            return ShapedParagraph.init(std.testing.allocator, self.arena.allocator(), &self.cache, text, &.{.{
                .end = @intCast(text.len),
                .style = .{ .fonts = &fonts, .size = 16 },
            }}, direction);
        }
    };
};

test "fallback selects fonts per grapheme and keeps runs logical" {
    var fixture: testing.Fixture = try .init();
    defer fixture.deinit();
    const text = "Save حفظ שמור";
    var p = try fixture.shape(text, .auto_ltr);
    defer p.deinit();
    try std.testing.expect(!p.missing);
    try std.testing.expectEqual(0, p.wanted.len);
    // Latin "Save " (space joins Latin), Arabic "حفظ", " " and Hebrew.
    var previous_end: u32 = 0;
    var fonts: [8]FontId = undefined;
    for (p.runs, 0..) |run, i| {
        try std.testing.expectEqual(previous_end, run.start);
        previous_end = run.end;
        fonts[i] = run.font;
        for (p.runGlyphs(run)) |glyph| {
            try std.testing.expect(glyph.id != 0);
            try std.testing.expect(glyph.cluster >= run.start and glyph.cluster < run.end);
        }
    }
    try std.testing.expectEqual(text.len, previous_end);
    try std.testing.expectEqual(fixture.latin, fonts[0]);
    try std.testing.expect(std.mem.indexOfScalar(FontId, fonts[0..p.runs.len], fixture.arabic) != null);
    try std.testing.expectEqual(fixture.hebrew, p.runs[p.runs.len - 1].font);
    try std.testing.expect(p.runs[p.runs.len - 1].rtl());
}

test "Arabic fallback keeps joining across the font boundary context" {
    var fixture: testing.Fixture = try .init();
    defer fixture.deinit();
    // The primary (Latin) font has no Arabic; the fallback shapes "سلام" as
    // one run, so its letters join (medial forms differ from isolated ones).
    var joined = try fixture.shape("سلام", .auto_ltr);
    defer joined.deinit();
    var isolated = try fixture.shape("س ل ا م", .auto_ltr);
    defer isolated.deinit();
    try std.testing.expectEqual(1, joined.runs.len);
    try std.testing.expectEqual(fixture.arabic, joined.runs[0].font);
    const lam_joined = joined.glyphs[2].id; // RTL order: م ا ل س
    var lam_isolated: u32 = 0;
    for (isolated.glyphs) |glyph| if (glyph.cluster == 4) {
        lam_isolated = glyph.id;
    };
    try std.testing.expect(lam_joined != lam_isolated);
}

test "pending fonts are wanted, not read; missing glyphs are reported" {
    var fixture: testing.Fixture = try .init();
    defer fixture.deinit();
    const pending = try fixture.cache.addPending(.{ .path = "/fonts/Unloaded.ttf" }, null);
    const fonts = [_]FontId{ pending, fixture.latin };
    var p = try ShapedParagraph.init(std.testing.allocator, fixture.arena.allocator(), &fixture.cache, "Hi 日本", &.{.{
        .end = "Hi 日本".len,
        .style = .{ .fonts = &fonts, .size = 12 },
    }}, .auto_ltr);
    defer p.deinit();
    try std.testing.expectEqualSlices(FontId, &.{pending}, p.wanted);
    try std.testing.expect(p.missing); // no ready font has Han
    try std.testing.expectEqual(fixture.latin, p.runs[0].font);

    // A pending fallback ahead of a ready one: render with the ready font
    // now, and ask for the pending one, which ranks higher.
    const chain = [_]FontId{ fixture.latin, pending, fixture.hebrew };
    var hebrew = try ShapedParagraph.init(std.testing.allocator, fixture.arena.allocator(), &fixture.cache, "Hi שלום", &.{.{
        .end = "Hi שלום".len,
        .style = .{ .fonts = &chain, .size = 12 },
    }}, .auto_ltr);
    defer hebrew.deinit();
    try std.testing.expectEqualSlices(FontId, &.{pending}, hebrew.wanted);
    try std.testing.expect(!hebrew.missing);
    try std.testing.expectEqual(fixture.hebrew, hebrew.runs[hebrew.runs.len - 1].font);
}

test "without a font, the last-resort face shows boxes, unless a font is loading" {
    var fixture: testing.Fixture = try .init();
    defer fixture.deinit();
    const style = struct {
        var run: [1]StyleRun = undefined;
        fn of(fonts: []const FontId) []const StyleRun {
            run[0] = .{ .end = "ab c".len, .style = .{ .fonts = fonts, .size = 10 } };
            return &run;
        }
    }.of;
    const a = fixture.arena.allocator();
    // An empty chain is invalid without a last resort.
    try std.testing.expectError(error.InvalidStyles, ShapedParagraph.init(std.testing.allocator, a, &fixture.cache, "ab c", style(&.{}), .auto_ltr));
    try fixture.cache.addLastResort();
    const failed = try fixture.cache.addPending(.{ .path = "/fonts/Gone.ttf" }, null);
    fixture.cache.fail(failed);
    for ([_][]const FontId{ &.{}, &.{failed} }) |chain| {
        var p = try ShapedParagraph.init(std.testing.allocator, a, &fixture.cache, "ab c", style(chain), .auto_ltr);
        defer p.deinit();
        try std.testing.expect(p.missing);
        try std.testing.expectEqual(fixture.cache.last_resort.?, p.runs[0].font);
        // A box of 0.6 em per letter, a quarter em for the space.
        try std.testing.expectEqual(4, p.glyphs.len);
        for (p.glyphs, [_]u32{ 0, 0, 1, 0 }, [_]f32{ 6, 6, 2.5, 6 }) |g, id, advance| {
            try std.testing.expectEqual(id, g.id);
            try std.testing.expectApproxEqAbs(advance, g.advance, 0.001);
        }
    }
    // A font still loading: nothing until it loads, not boxes.
    const pending = try fixture.cache.addPending(.{ .path = "/fonts/Unloaded.ttf" }, null);
    var p = try ShapedParagraph.init(std.testing.allocator, a, &fixture.cache, "ab c", style(&.{ failed, pending }), .auto_ltr);
    defer p.deinit();
    try std.testing.expectEqualSlices(FontId, &.{pending}, p.wanted);
    try std.testing.expectEqual(0, p.glyphs.len);
}

test "segments measure the advance between opportunities" {
    var fixture: testing.Fixture = try .init();
    defer fixture.deinit();
    var p = try fixture.shape("one two  three\nfour", .auto_ltr);
    defer p.deinit();
    try std.testing.expectEqual(4, p.segments.len);
    try std.testing.expectEqual(4, p.segments[0].end);
    try std.testing.expectEqual(9, p.segments[1].end);
    try std.testing.expect(p.segments[2].mandatory and p.segments[2].end == 15);
    // "two  " hangs two spaces; "one " one.
    try std.testing.expectApproxEqAbs(p.segments[1].trailing, 2 * p.segments[0].trailing, 0.01);
    var total: f32 = 0;
    for (p.segments) |segment| total += segment.advance;
    var glyph_total: f32 = 0;
    for (p.glyphs) |glyph| glyph_total += glyph.advance;
    try std.testing.expectApproxEqAbs(glyph_total, total, 0.01);
    try std.testing.expectEqual(2, p.paragraphs.len);
}

test "styles split items and validate" {
    var fixture: testing.Fixture = try .init();
    defer fixture.deinit();
    const fonts = [_]FontId{fixture.latin};
    const a = fixture.arena.allocator();
    var p = try ShapedParagraph.init(std.testing.allocator, a, &fixture.cache, "big small", &.{
        .{ .end = 4, .style = .{ .fonts = &fonts, .size = 32 } },
        .{ .end = 9, .style = .{ .fonts = &fonts, .size = 10 } },
    }, .auto_ltr);
    defer p.deinit();
    try std.testing.expectEqual(2, p.runs.len);
    try std.testing.expect(p.glyphs[0].advance > 2 * p.glyphs[5].advance);
    try std.testing.expectError(error.InvalidStyles, ShapedParagraph.init(std.testing.allocator, a, &fixture.cache, "abc", &.{.{ .end = 2, .style = .{ .fonts = &fonts, .size = 10 } }}, .auto_ltr));
    try std.testing.expectError(error.InvalidUtf8, ShapedParagraph.init(std.testing.allocator, a, &fixture.cache, "a\xff", &.{.{ .end = 2, .style = .{ .fonts = &fonts, .size = 10 } }}, .auto_ltr));
}

/// Every field `initReusing` builds equals `init`'s for the same text.
pub fn expectSameShaping(want: *const ShapedParagraph, got: *const ShapedParagraph) !void {
    const t = std.testing;
    try t.expectEqualStrings(want.text, got.text);
    try t.expectEqual(want.missing, got.missing);
    try t.expectEqualSlices(bidi.Paragraph, want.paragraphs, got.paragraphs);
    try t.expectEqualSlices(u8, want.levels, got.levels);
    try t.expectEqualSlices(bidi.LineClass, want.classes, got.classes);
    try t.expectEqualSlices(Run, want.runs, got.runs);
    try t.expectEqualSlices(Glyph, want.glyphs, got.glyphs);
    try t.expectEqualSlices(Segment, want.segments, got.segments);
    for ([_][2]Boundaries{ .{ want.graphemes, got.graphemes }, .{ want.words.boundaries, got.words.boundaries }, .{ want.words.starts, got.words.starts } }) |pair|
        for (0..want.text.len + 1) |o| try t.expectEqual(pair[0].isSet(@intCast(o)), pair[1].isSet(@intCast(o)));
}

test "reusing an edited text's shaping gives the same result as shaping it" {
    var fixture: testing.Fixture = try .init();
    defer fixture.deinit();
    // Paragraphs in three scripts and both directions, with CR LF, CR,
    // and paragraph separators, tabs, and an empty paragraph.
    const pieces = [_][]const u8{ "Save the file", "\n", "حفظ الملف", "\r\n", "שמור", "\r", " tab\tstop ", "\u{2029}", "x", "\n", "", "ab cd ef", "\n\n", "مرحبا world" };
    const inserts = [_][]const u8{ "q", " ", "\n", "\r", "\r\n", "ש", "حف", "\u{2029}", "word " };
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    for ([_]bidi.BaseDirection{ .auto_ltr, .rtl }) |direction| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(std.testing.allocator);
        for (0..3) |_| for (pieces) |p| try text.appendSlice(std.testing.allocator, p);
        var old = try fixture.shape(text.items, direction);
        defer old.deinit();
        var reused_some = false;
        for (0..150) |_| {
            // Insert or delete at a random character boundary.
            var at = rand.uintLessThan(usize, text.items.len + 1);
            while (at < text.items.len and text.items[at] & 0xc0 == 0x80) at += 1;
            if (rand.boolean() and at < text.items.len) {
                var end = at + 1 + rand.uintLessThan(usize, 4);
                end = @min(end, text.items.len);
                while (end < text.items.len and text.items[end] & 0xc0 == 0x80) end += 1;
                try text.replaceRange(std.testing.allocator, at, end - at, "");
            } else {
                try text.insertSlice(std.testing.allocator, at, inserts[rand.uintLessThan(usize, inserts.len)]);
            }
            const fonts = [_]FontId{ fixture.latin, fixture.arabic, fixture.hebrew };
            const styles = [_]StyleRun{.{ .end = @intCast(text.items.len), .style = .{ .fonts = &fonts, .size = 16 } }};
            var want = try fixture.shape(text.items, direction);
            defer want.deinit();
            var got = try ShapedParagraph.initReusing(std.testing.allocator, fixture.arena.allocator(), &fixture.cache, text.items, &styles, direction, &old);
            if (got.reused != null) reused_some = true;
            expectSameShaping(&want, &got) catch |err| {
                got.deinit();
                return err;
            };
            old.deinit();
            old = got;
        }
        try std.testing.expect(reused_some);
    }
}
