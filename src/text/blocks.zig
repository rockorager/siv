//! A text as a sequence of blocks (D13): runs of whole bidi paragraphs of
//! about `Options.block_bytes`, each with its own `ShapedParagraph` and
//! `Layout`. Paragraphs are independent (bidi, line, grapheme, and word
//! boundaries all break after a separator, and shaping stops there), so
//! splitting a text between paragraphs changes nothing, and an edit
//! reshapes and lays out only the block it falls in. Blocks are shared,
//! by reference count, between a text and the one an edit built from it:
//! an edit costs its block plus a few words per block, not the document's
//! size. Offsets, lines, and positions in the API are the whole text's.

const std = @import("std");
const paragraph_ = @import("paragraph.zig");
const layout_ = @import("layout.zig");
const cursor = @import("cursor.zig");
const font = @import("font.zig");
const bidi = @import("bidi.zig");

const Allocator = std.mem.Allocator;
const ShapedParagraph = paragraph_.ShapedParagraph;
const StyleRun = paragraph_.StyleRun;
const Style = paragraph_.Style;
const BuildError = paragraph_.BuildError;
const Layout = layout_.Layout;
const Line = layout_.Line;
const Rect = layout_.Rect;
const ParagraphRun = layout_.ParagraphRun;
const FontCache = font.FontCache;
const FontId = font.FontId;
const Position = cursor.Position;
const CaretRect = cursor.CaretRect;

pub const Options = struct {
    /// A block ends at the first paragraph end at or after this many bytes
    /// (or the end of the text); a paragraph longer than this is a block of
    /// its own.
    block_bytes: u32 = 8192,
};

/// A run of whole paragraphs shaped on its own, shared by the texts built
/// from one another.
pub const ShapedBlock = struct {
    refs: u32 = 1,
    gpa: Allocator,
    paragraph: ShapedParagraph,
    /// The old text's block this one was reshaped from by
    /// `ShapedParagraph.initReusing`, so that laying it out can keep that
    /// block's lines (`Layout.initReusing`). Never dereferenced: only
    /// matched against the blocks of the old text's layout, which keeps
    /// them alive.
    from: ?*const ShapedBlock = null,

    fn retain(b: *ShapedBlock) *ShapedBlock {
        b.refs += 1;
        return b;
    }

    fn release(b: *ShapedBlock) void {
        b.refs -= 1;
        if (b.refs != 0) return;
        b.paragraph.deinit();
        b.gpa.destroy(b);
    }

    pub fn len(b: *const ShapedBlock) u32 {
        return @intCast(b.paragraph.text.len);
    }
};

/// The width-independent part: the text's blocks, shaped.
pub const ShapedText = struct {
    gpa: Allocator,
    blocks: []*ShapedBlock,
    /// Byte offset of each block, and the text's length last.
    starts: []u32,
    /// Index of each block's first style in the text's style runs: block
    /// style `i` is the text's style `style_firsts[b] + i`.
    style_firsts: []u32,
    /// Index of each block's first bidi paragraph, and the count last.
    paragraph_starts: []u32,
    direction: bidi.BaseDirection,
    options: Options,
    /// Some block had a font missing (see `ShapedParagraph.missing`).
    missing: bool,
    /// Pending fonts shaping would have tried, from every block.
    wanted: []FontId,

    /// Shapes `text` with `styles` (as `ShapedParagraph.init` takes them)
    /// in blocks.
    pub fn init(gpa: Allocator, scratch: Allocator, cache: *const FontCache, text: []const u8, styles: []const StyleRun, direction: bidi.BaseDirection, options: Options) BuildError!ShapedText {
        try validate(text, styles);
        var list: std.ArrayList(*ShapedBlock) = .empty;
        defer list.deinit(scratch);
        errdefer for (list.items) |b| b.release();
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        try appendBlocks(&list, gpa, scratch, &tmp, cache, text, styles, direction, options, 0, text.len);
        return finish(gpa, list.items, text, styles, direction, options);
    }

    /// Like `init`, but keeps `old`'s blocks (the text before an edit)
    /// that the edit left alone, with their styles: only blocks holding
    /// changed bytes or styles are shaped again. A block next to the
    /// change is redone too when the change touches its separator (an
    /// edit after a CR could make a CRLF), and a redone stretch smaller
    /// than a quarter block takes in its neighbor, so edits do not leave
    /// slivers.
    pub fn initReusing(gpa: Allocator, scratch: Allocator, cache: *const FontCache, text: []const u8, styles: []const StyleRun, direction: bidi.BaseDirection, options: Options, old_: ?*const ShapedText) BuildError!ShapedText {
        const old = old_ orelse return init(gpa, scratch, cache, text, styles, direction, options);
        if (old.direction != direction or old.missing or old.wanted.len != 0 or old.options.block_bytes != options.block_bytes or old.len() == 0 or text.len == 0)
            return init(gpa, scratch, cache, text, styles, direction, options);
        try validate(text, styles);
        const old_len = old.len();
        const n = old.blocks.len;

        // The changed bytes, from the common prefix and suffix.
        // Whole blocks compare with memcmp; only the one that differs is
        // looked into.
        const prefix = blk: {
            for (old.blocks, 0..) |b, i| {
                const s = old.starts[i];
                const bt = b.paragraph.text;
                const k = @min(bt.len, text.len - s);
                if (k == bt.len and sameBytes(bt, text[s..][0..k])) continue;
                if (std.mem.indexOfDiff(u8, bt[0..k], text[s..][0..k])) |d| break :blk s + d;
                break :blk s + k;
            }
            break :blk @as(usize, old_len);
        };
        const suffix = blk: {
            const limit = @min(old_len, text.len) - prefix;
            var done: usize = 0;
            var i = n;
            while (i > 0 and done < limit) {
                i -= 1;
                const bt = old.blocks[i].paragraph.text;
                const k = @min(bt.len, limit - done);
                if (k == bt.len and sameBytes(bt, text[text.len - done - k ..][0..k])) {
                    done += k;
                    continue;
                }
                var j: usize = 0;
                while (j < k and bt[bt.len - 1 - j] == text[text.len - 1 - done - j]) j += 1;
                done += j;
                break;
            }
            break :blk done;
        };
        const old_change_end = old_len - suffix;
        const delta: i64 = @as(i64, @intCast(text.len)) - old_len;

        var list: std.ArrayList(*ShapedBlock) = .empty;
        defer list.deinit(scratch);
        errdefer for (list.items) |b| b.release();
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        const ctx: Ctx = .{ .gpa = gpa, .scratch = scratch, .tmp = &tmp, .cache = cache, .text = text, .styles = styles, .direction = direction, .options = options };

        // Blocks before the change: kept unless it touches their end.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const end = old.starts[i + 1];
            const b = old.blocks[i];
            const sealed = end < prefix or (end == prefix and endsWithSeparator(b.paragraph.text) and b.paragraph.text[b.paragraph.text.len - 1] != '\r');
            if (!sealed) break;
            try ctx.keepOrRedo(&list, b, old.starts[i]);
        }
        // Blocks after the change: kept when the byte before them did not
        // change either.
        var j = i;
        while (j < n and old.starts[j] <= old_change_end) j += 1;
        var from: usize = old.starts[i];
        var to: usize = if (j < n) shift(old.starts[j], delta) else text.len;
        // No slivers: a small stretch takes in the next block, or else
        // the previous one.
        if (to - from < options.block_bytes / 4) {
            if (j < n) {
                j += 1;
                to = if (j < n) shift(old.starts[j], delta) else text.len;
            } else if (list.items.len > 0) {
                const prev = list.pop().?;
                from -= prev.len();
                prev.release();
            }
        }
        if (j == i + 1 and to > from and to - from < 2 * options.block_bytes) {
            // One block changed and stays one: reshape only the paragraphs
            // around the change (`ShapedParagraph.initReusing`).
            try list.ensureUnusedCapacity(scratch, 1);
            list.appendAssumeCapacity(try shapeBlock(gpa, &tmp, cache, text, styles, direction, from, to, old.blocks[i]));
        } else if (to > from or (list.items.len == 0 and j == n)) try appendBlocks(&list, gpa, scratch, &tmp, cache, text, styles, direction, options, from, to);
        while (j < n) : (j += 1) try ctx.keepOrRedo(&list, old.blocks[j], shift(old.starts[j], delta));
        return finish(gpa, list.items, text, styles, direction, options);
    }

    pub fn deinit(self: *ShapedText) void {
        for (self.blocks) |b| b.release();
        self.gpa.free(self.blocks);
        self.gpa.free(self.starts);
        self.gpa.free(self.style_firsts);
        self.gpa.free(self.paragraph_starts);
        self.gpa.free(self.wanted);
        self.* = undefined;
    }

    pub fn len(self: *const ShapedText) u32 {
        return self.starts[self.starts.len - 1];
    }

    /// The block holding `offset`: at a boundary between blocks, the one
    /// after it (whose first line starts there); the end of the text is
    /// the last block's.
    pub fn blockAt(self: *const ShapedText, offset: u32) u32 {
        var low: usize = 0;
        var high: usize = self.blocks.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.starts[middle + 1] <= offset) low = middle + 1 else high = middle;
        }
        return @intCast(@min(low, self.blocks.len - 1));
    }

    /// The bidi paragraph at `offset` without its separator (the last one
    /// at the end of the text).
    pub fn paragraphRange(self: *const ShapedText, offset: u32) [2]u32 {
        const b = self.blockAt(offset);
        const p = &self.blocks[b].paragraph;
        const s = self.starts[b];
        const para = p.paragraphs[p.paragraphAt(offset - s)];
        return .{ s + para.start, s + para.contentEnd() };
    }

    /// The word (or run of spaces or punctuation, UAX #29) at `offset`.
    pub fn wordAt(self: *const ShapedText, offset: u32) [2]u32 {
        const b = self.blockAt(offset);
        const p = &self.blocks[b].paragraph;
        const s = self.starts[b];
        const words = p.words.boundaries;
        const blen: u32 = @intCast(p.text.len);
        var start = words.atOrBefore(offset - s) orelse 0;
        if (start == blen and blen > 0) start = words.before(blen) orelse 0;
        return .{ s + start, s + (words.after(start) orelse blen) };
    }

    pub fn nextGrapheme(self: *const ShapedText, offset: u32) u32 {
        const b = self.blockAt(offset);
        const p = &self.blocks[b].paragraph;
        const s = self.starts[b];
        return s + (p.graphemes.after(offset - s) orelse @as(u32, @intCast(p.text.len)));
    }

    pub fn previousGrapheme(self: *const ShapedText, offset: u32) u32 {
        var b = self.blockAt(offset);
        var local = offset - self.starts[b];
        if (local == 0) {
            if (b == 0) return 0;
            b -= 1;
            local = self.blocks[b].len();
        }
        return self.starts[b] + (self.blocks[b].paragraph.graphemes.before(local) orelse 0);
    }

    /// The end of the word at or after `offset` (word-wise forward
    /// movement), across blocks as across paragraphs.
    pub fn nextWordEnd(self: *const ShapedText, offset: u32) u32 {
        var b = self.blockAt(offset);
        var local = offset - self.starts[b];
        while (true) {
            const p = &self.blocks[b].paragraph;
            const words = p.words;
            const blen: u32 = @intCast(p.text.len);
            var current = words.boundaries.atOrBefore(local).?;
            while (words.boundaries.after(current)) |next| : (current = next) {
                if (words.starts.isSet(current) and next > local) return self.starts[b] + next;
            }
            if (b + 1 == self.blocks.len) return self.starts[b] + blen;
            // On into the next block, every boundary of which is past
            // `offset`.
            b += 1;
            local = 0;
        }
    }

    /// The start of the word before `offset` (word-wise backward movement).
    pub fn previousWordStart(self: *const ShapedText, offset: u32) u32 {
        var b = self.blockAt(offset);
        var local = offset - self.starts[b];
        while (true) {
            if (local == 0) {
                if (b == 0) return 0;
                b -= 1;
                local = self.blocks[b].len();
            }
            const words = self.blocks[b].paragraph.words;
            var current = words.boundaries.before(local);
            while (current) |c| : (current = words.boundaries.before(c)) {
                if (words.starts.isSet(c)) return self.starts[b] + c;
            }
            if (b == 0) return 0;
            local = 0;
        }
    }

    const Ctx = struct {
        gpa: Allocator,
        scratch: Allocator,
        tmp: *std.heap.ArenaAllocator,
        cache: *const FontCache,
        text: []const u8,
        styles: []const StyleRun,
        direction: bidi.BaseDirection,
        options: Options,

        /// Appends `b`, now at `start`, if its styles are still the text's
        /// there; else its bytes shaped again.
        fn keepOrRedo(ctx: Ctx, list: *std.ArrayList(*ShapedBlock), b: *ShapedBlock, start: usize) BuildError!void {
            if (sameStyles(&b.paragraph, ctx.styles, start)) {
                try list.append(ctx.scratch, b.retain());
                return;
            }
            try list.ensureUnusedCapacity(ctx.scratch, 1);
            list.appendAssumeCapacity(try shapeBlock(ctx.gpa, ctx.tmp, ctx.cache, ctx.text, ctx.styles, ctx.direction, start, start + b.len(), null));
        }
    };

    fn finish(gpa: Allocator, list: []const *ShapedBlock, text: []const u8, styles: []const StyleRun, direction: bidi.BaseDirection, options: Options) BuildError!ShapedText {
        const blocks = try gpa.dupe(*ShapedBlock, list);
        errdefer gpa.free(blocks);
        const starts = try gpa.alloc(u32, list.len + 1);
        errdefer gpa.free(starts);
        const style_firsts = try gpa.alloc(u32, list.len);
        errdefer gpa.free(style_firsts);
        const paragraph_starts = try gpa.alloc(u32, list.len + 1);
        errdefer gpa.free(paragraph_starts);
        var wanted: std.ArrayList(FontId) = .empty;
        errdefer wanted.deinit(gpa);
        var at: u32 = 0;
        var paragraphs: u32 = 0;
        var style: u32 = 0;
        var missing = false;
        for (list, 0..) |b, i| {
            starts[i] = at;
            while (style + 1 < styles.len and styles[style].end <= at) style += 1;
            style_firsts[i] = style;
            paragraph_starts[i] = paragraphs;
            at += b.len();
            paragraphs += @intCast(b.paragraph.paragraphs.len);
            missing = missing or b.paragraph.missing;
            for (b.paragraph.wanted) |f| if (std.mem.indexOfScalar(FontId, wanted.items, f) == null) try wanted.append(gpa, f);
        }
        std.debug.assert(at == text.len);
        starts[list.len] = at;
        paragraph_starts[list.len] = paragraphs;
        // The list's references move into the result.
        return .{
            .gpa = gpa,
            .blocks = blocks,
            .starts = starts,
            .style_firsts = style_firsts,
            .paragraph_starts = paragraph_starts,
            .direction = direction,
            .options = options,
            .missing = missing,
            .wanted = try wanted.toOwnedSlice(gpa),
        };
    }
};

/// Each block checks its own bytes are UTF-8 when shaped, and blocks
/// kept from an old text are its bytes, checked then: a keystroke does not
/// check all of a long text.
fn validate(text: []const u8, styles: []const StyleRun) BuildError!void {
    if (text.len >= std.math.maxInt(u32)) return error.TextTooLong;
    try paragraph_.validateStyles(text, styles);
}

/// Whether two byte strings are equal, by unaligned 64-bit words:
/// std.mem.eql compiles to byte-wise broadcasts with AVX-512 (Zen 4),
/// libsiv's memcmp is compiler-rt's byte loop, and a vector bitcast of a
/// byte array loads byte by byte; each took a third to a half of a
/// keystroke in a 1.4 MB document.
fn sameBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i + 32 <= a.len) : (i += 32) {
        const x: *align(1) const [4]u64 = @ptrCast(a.ptr + i);
        const y: *align(1) const [4]u64 = @ptrCast(b.ptr + i);
        if ((x[0] ^ y[0]) | (x[1] ^ y[1]) | (x[2] ^ y[2]) | (x[3] ^ y[3]) != 0) return false;
    }
    while (i < a.len) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

fn shift(x: u32, d: i64) u32 {
    return @intCast(@as(i64, x) + d);
}

/// The end of the bidi paragraph at `from` (after its separator, a CRLF
/// counting as one), or `limit`: UAX #9's paragraph separators (class B).
pub fn paragraphEnd(text: []const u8, from: usize, limit: usize) usize {
    var i = from;
    while (i < limit) : (i += 1) {
        switch (text[i]) {
            '\n', 0x1c, 0x1d, 0x1e => return i + 1,
            '\r' => return if (i + 1 < limit and text[i + 1] == '\n') i + 2 else i + 1,
            0xc2 => if (i + 1 < limit and text[i + 1] == 0x85) return i + 2,
            0xe2 => if (i + 2 < limit and text[i + 1] == 0x80 and text[i + 2] == 0xa9) return i + 3,
            else => {},
        }
    }
    return limit;
}

fn endsWithSeparator(text: []const u8) bool {
    if (text.len == 0) return false;
    const last = text[text.len - 1];
    if (last == '\n' or last == '\r' or (last >= 0x1c and last <= 0x1e)) return true;
    return std.mem.endsWith(u8, text, "\u{85}") or std.mem.endsWith(u8, text, "\u{2029}");
}

/// Appends blocks covering `text[from..to]`, which starts and ends at
/// paragraph boundaries (or the text's ends); one empty block for empty
/// text.
fn appendBlocks(list: *std.ArrayList(*ShapedBlock), gpa: Allocator, scratch: Allocator, tmp: *std.heap.ArenaAllocator, cache: *const FontCache, text: []const u8, styles: []const StyleRun, direction: bidi.BaseDirection, options: Options, from: usize, to: usize) BuildError!void {
    var s = from;
    while (true) {
        var e = s;
        while (e < to) {
            e = paragraphEnd(text, e, to);
            if (e - s >= options.block_bytes) break;
        }
        try list.ensureUnusedCapacity(scratch, 1);
        list.appendAssumeCapacity(try shapeBlock(gpa, tmp, cache, text, styles, direction, s, e, null));
        s = e;
        if (s >= to) break;
    }
}

/// The index of the first style run ending after `offset` (the last for
/// the end of the text).
fn styleIndex(styles: []const StyleRun, offset: usize) usize {
    var low: usize = 0;
    var high = styles.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (styles[middle].end <= offset) low = middle + 1 else high = middle;
    }
    return @min(low, styles.len - 1);
}

/// Shapes `text[s..e]` as a block, from `old` (the block it replaces)
/// when given.
fn shapeBlock(gpa: Allocator, tmp: *std.heap.ArenaAllocator, cache: *const FontCache, text: []const u8, styles: []const StyleRun, direction: bidi.BaseDirection, s: usize, e: usize, old: ?*const ShapedBlock) BuildError!*ShapedBlock {
    // Intermediates go in `tmp`, emptied after each block, so a long text
    // never holds all of them at once.
    defer _ = tmp.reset(.retain_capacity);
    const scratch = tmp.allocator();
    var local: std.ArrayList(StyleRun) = .empty;
    var k = styleIndex(styles, s);
    while (true) : (k += 1) {
        const run = styles[k];
        try local.append(scratch, .{ .end = @intCast(@min(run.end, e) - s), .style = run.style });
        if (run.end >= e or k + 1 == styles.len) break;
    }
    const b = try gpa.create(ShapedBlock);
    errdefer gpa.destroy(b);
    const reused = if (old) |o| &o.paragraph else null;
    b.* = .{ .gpa = gpa, .paragraph = try ShapedParagraph.initReusing(gpa, scratch, cache, text[s..e], local.items, direction, reused) };
    if (b.paragraph.reused != null) b.from = old;
    return b;
}

/// Whether the text's styles over `p`'s bytes, at `start`, are `p`'s.
fn sameStyles(p: *const ShapedParagraph, styles: []const StyleRun, start: usize) bool {
    const blen = p.text.len;
    var k = styleIndex(styles, start);
    for (p.styles, p.style_ends, 0..) |o, end, i| {
        if (k >= styles.len) return false;
        const run = styles[k];
        const local_end = @min(run.end, start + blen) - start;
        if (local_end != end) return false;
        if (run.style.size != o.size or !std.mem.eql(FontId, run.style.fonts, o.fonts) or !std.mem.eql(u8, run.style.language, o.language)) return false;
        if (i + 1 == p.styles.len) return run.end >= start + blen;
        k += 1;
    }
    return false;
}

/// One block's lines, shared like the block.
pub const LayoutBlock = struct {
    refs: u32 = 1,
    gpa: Allocator,
    shaped: *ShapedBlock,
    layout: Layout,
    /// Its paragraph runs, ends relative to its start, for reuse checks.
    runs: []ParagraphRun,

    fn retain(b: *LayoutBlock) *LayoutBlock {
        b.refs += 1;
        return b;
    }

    fn release(b: *LayoutBlock) void {
        b.refs -= 1;
        if (b.refs != 0) return;
        b.layout.deinit();
        b.gpa.free(b.runs);
        b.shaped.release();
        b.gpa.destroy(b);
    }
};

/// A `ShapedText` laid out for one width: its blocks' layouts stacked,
/// with the space between paragraphs between blocks.
pub const TextLayout = struct {
    gpa: Allocator,
    shaped: *const ShapedText,
    blocks: []*LayoutBlock,
    /// Each block's top.
    tops: []f32,
    /// Index of each block's first line, and the line count last.
    line_starts: []u32,
    /// Widest line without hanging whitespace, with its indents.
    width: f32,
    height: f32,

    /// Lays out `shaped` (`Layout.init`'s options, with paragraph runs in
    /// the whole text's offsets), keeping `old`'s lines for blocks it
    /// shares with `old`'s text when the options are the same.
    pub fn init(gpa: Allocator, scratch: Allocator, cache: *const FontCache, shaped: *const ShapedText, options: layout_.Options, old: ?*const TextLayout) !TextLayout {
        if (options.width) |w| if (!std.math.isFinite(w) or w < 0) return error.InvalidWidth;
        const n = shaped.blocks.len;
        // Old blocks by their shaped block.
        var reusable: std.AutoHashMapUnmanaged(*ShapedBlock, *LayoutBlock) = .empty;
        if (old) |o| {
            try reusable.ensureTotalCapacity(scratch, @intCast(o.blocks.len));
            for (o.blocks) |lb| reusable.putAssumeCapacity(lb.shaped, lb);
        }
        const blocks = try gpa.alloc(*LayoutBlock, n);
        var made: usize = 0;
        errdefer {
            for (blocks[0..made]) |b| b.release();
            gpa.free(blocks);
        }
        var run_index: usize = 0;
        const runs = options.paragraphs;
        // Each block's intermediates, emptied after it.
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        for (shaped.blocks, 0..) |sb, i| {
            const s = shaped.starts[i];
            const e = shaped.starts[i + 1];
            const last = i + 1 == n;
            // Its paragraph runs: those covering s..e (and e itself for the
            // line after a final break).
            var local: std.ArrayList(ParagraphRun) = .empty;
            while (run_index + 1 < runs.len and runs[run_index].end <= s) run_index += 1;
            var k = run_index;
            while (k < runs.len) : (k += 1) {
                try local.append(scratch, .{ .end = @intCast(@min(runs[k].end, e) - @min(s, runs[k].end)), .style = runs[k].style });
                if (runs[k].end > e or (runs[k].end == e and !last)) break;
            }
            var block_options = options;
            block_options.paragraphs = local.items;
            block_options.final_line = last;
            if (reusable.get(sb)) |lb| if (compatible(lb, block_options)) {
                blocks[i] = lb.retain();
                made += 1;
                continue;
            };
            const lb = try gpa.create(LayoutBlock);
            errdefer gpa.destroy(lb);
            const owned_runs = try gpa.dupe(ParagraphRun, local.items);
            errdefer gpa.free(owned_runs);
            lb.* = .{ .gpa = gpa, .shaped = sb.retain(), .layout = undefined, .runs = owned_runs };
            errdefer sb.release();
            // A block reshaped from an old one keeps the old one's lines
            // for the paragraphs it kept.
            const from: ?*const Layout = if (sb.from) |f| (if (reusable.get(@constCast(f))) |o| &o.layout else null) else null;
            lb.layout = try Layout.initReusing(gpa, tmp.allocator(), cache, &sb.paragraph, block_options, from);
            _ = tmp.reset(.retain_capacity);
            blocks[i] = lb;
            made += 1;
        }
        const tops = try gpa.alloc(f32, n);
        errdefer gpa.free(tops);
        const line_starts = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(line_starts);
        var top: f32 = 0;
        var lines: u32 = 0;
        var width: f32 = 0;
        for (blocks, 0..) |b, i| {
            if (i > 0) {
                const prev = blocks[i - 1].layout.built.styles;
                const prev_paragraphs = blocks[i - 1].shaped.paragraph.paragraphs.len;
                top += prev[prev_paragraphs - 1].space_after + b.layout.built.styles[0].space_before;
            }
            tops[i] = top;
            line_starts[i] = lines;
            top += b.layout.height;
            lines += @intCast(b.layout.lines.len);
            width = @max(width, b.layout.width);
        }
        line_starts[n] = lines;
        return .{ .gpa = gpa, .shaped = shaped, .blocks = blocks, .tops = tops, .line_starts = line_starts, .width = width, .height = top };
    }

    fn compatible(lb: *const LayoutBlock, options: layout_.Options) bool {
        const b = lb.layout.built;
        if (b.width != options.width or b.alignment != options.alignment or b.break_words != options.break_words or b.hyphenate != options.hyphenate or
            b.optimal != options.optimal or b.final_line != options.final_line or b.tab_stops.len != options.tab_stops.len) return false;
        for (b.tab_stops, options.tab_stops) |x, y| if (!std.meta.eql(x, y)) return false;
        if (lb.runs.len != options.paragraphs.len) return false;
        for (lb.runs, options.paragraphs) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    pub fn deinit(self: *TextLayout) void {
        for (self.blocks) |b| b.release();
        self.gpa.free(self.blocks);
        self.gpa.free(self.tops);
        self.gpa.free(self.line_starts);
        self.* = undefined;
    }

    pub fn lineCount(self: *const TextLayout) u32 {
        return self.line_starts[self.line_starts.len - 1];
    }

    /// The block holding line `index`.
    pub fn blockOfLine(self: *const TextLayout, index: u32) u32 {
        var low: usize = 0;
        var high: usize = self.blocks.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.line_starts[middle + 1] <= index) low = middle + 1 else high = middle;
        }
        return @intCast(@min(low, self.blocks.len - 1));
    }

    /// Line `index` in the whole text's offsets and coordinates (its run
    /// and caret ranges stay its block's).
    pub fn line(self: *const TextLayout, index: u32) Line {
        const b = self.blockOfLine(index);
        return self.globalLine(b, self.blocks[b].layout.lines[index - self.line_starts[b]]);
    }

    /// A line of block `b` in the whole text's offsets and coordinates.
    pub fn globalLine(self: *const TextLayout, b: u32, block_line: Line) Line {
        var l = block_line;
        const s = self.shaped.starts[b];
        l.start += s;
        l.end += s;
        l.paragraph += self.shaped.paragraph_starts[b];
        l.top += self.tops[b];
        l.baseline += self.tops[b];
        return l;
    }

    /// The last block whose top is at or above `y` (the first above them all).
    pub fn blockAtY(self: *const TextLayout, y: f32) u32 {
        var low: usize = 0;
        var high: usize = self.blocks.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.tops[middle] <= y) low = middle + 1 else high = middle;
        }
        return @intCast(low -| 1);
    }

    /// The line at vertical position `y` (clamped to the first and last line).
    pub fn lineAt(self: *const TextLayout, y: f32) u32 {
        const b = self.blockAtY(y);
        return self.line_starts[b] + self.blocks[b].layout.lineAt(y - self.tops[b]);
    }

    fn toBlock(self: *const TextLayout, position: Position) struct { u32, Position } {
        const b = self.shaped.blockAt(position.offset);
        return .{ b, .{ .offset = position.offset - self.shaped.starts[b], .affinity = position.affinity } };
    }

    fn global(self: *const TextLayout, b: u32, position: Position) Position {
        return .{ .offset = position.offset + self.shaped.starts[b], .affinity = position.affinity };
    }

    pub fn caret(self: *const TextLayout, position: Position) CaretRect {
        const b, const p = self.toBlock(position);
        const c = self.blocks[b].layout.caret(p);
        return .{ .line = self.line_starts[b] + c.line, .x = c.x, .top = c.top + self.tops[b], .height = c.height };
    }

    /// The caret position closest to a point relative to the layout origin.
    pub fn hitTest(self: *const TextLayout, x: f32, y: f32) Position {
        const b = self.blockAtY(y);
        return self.global(b, self.blocks[b].layout.hitTest(x, y - self.tops[b]));
    }

    pub fn nextGrapheme(self: *const TextLayout, offset: u32) u32 {
        return self.shaped.nextGrapheme(offset);
    }

    pub fn previousGrapheme(self: *const TextLayout, offset: u32) u32 {
        return self.shaped.previousGrapheme(offset);
    }

    pub fn nextWordEnd(self: *const TextLayout, offset: u32) u32 {
        return self.shaped.nextWordEnd(offset);
    }

    pub fn previousWordStart(self: *const TextLayout, offset: u32) u32 {
        return self.shaped.previousWordStart(offset);
    }

    /// Visual movement by one grapheme edge (`cursor.moveVisual`): past a
    /// block's first or last line it continues in the next block.
    pub fn moveVisual(self: *const TextLayout, position: Position, direction: cursor.Direction) Position {
        const b, const p = self.toBlock(position);
        const l = &self.blocks[b].layout;
        const moved = l.moveVisual(p, direction);
        const from = l.caret(p);
        const forward = (direction == .right) != l.lines[from.line].rtl();
        const edge = if (forward) from.line + 1 == l.lines.len and b + 1 < self.blocks.len else from.line == 0 and b > 0;
        if (edge) {
            const to = l.caret(moved);
            if (to.line == from.line and @abs(to.x - from.x) <= 0.001) {
                if (forward) return self.global(b + 1, self.blocks[b + 1].layout.lineEdge(0, .start));
                const prev = &self.blocks[b - 1].layout;
                return self.global(b - 1, prev.lineEdge(@intCast(prev.lines.len - 1), .end));
            }
        }
        return self.global(b, moved);
    }

    /// The start or end of the position's line in reading order.
    pub fn lineBoundary(self: *const TextLayout, position: Position, boundary: cursor.Boundary) Position {
        const b, const p = self.toBlock(position);
        return self.global(b, self.blocks[b].layout.lineBoundary(p, boundary));
    }

    /// Moves to the adjacent line at the preferred x (`cursor.moveVertical`).
    pub fn moveVertical(self: *const TextLayout, position: Position, preferred_x: ?f32, direction: cursor.Vertical) cursor.VerticalMove {
        const b, const p = self.toBlock(position);
        const l = &self.blocks[b].layout;
        const from = l.caret(p);
        const target: ?u32 = switch (direction) {
            .up => if (from.line == 0 and b > 0) b - 1 else null,
            .down => if (from.line + 1 == l.lines.len and b + 1 < self.blocks.len) b + 1 else null,
        };
        if (target) |t| {
            const x = preferred_x orelse from.x;
            const tl = &self.blocks[t].layout;
            const target_line = if (direction == .up) tl.lines[tl.lines.len - 1] else tl.lines[0];
            const stops = tl.lineCarets(target_line);
            const index = cursor.nearest(stops, x - target_line.x);
            return .{ .position = self.global(t, .{ .offset = stops[index].offset, .affinity = stops[index].affinity }), .x = x };
        }
        const m = l.moveVertical(p, preferred_x, direction);
        return .{ .position = self.global(b, m.position), .x = m.x };
    }

    /// Appends rectangles covering the graphemes in `start..end`
    /// (`cursor.selectionRects`).
    pub fn selectionRects(self: *const TextLayout, gpa: Allocator, start: u32, end: u32, out: *std.ArrayList(Rect)) !void {
        if (start >= end) return;
        var b = self.shaped.blockAt(start);
        while (b < self.blocks.len and self.shaped.starts[b] < end) : (b += 1) {
            const s = self.shaped.starts[b];
            const e = self.shaped.starts[b + 1];
            const first = out.items.len;
            try self.blocks[b].layout.selectionRects(gpa, @max(start, s) - s, @min(end, e) - s, out);
            for (out.items[first..]) |*r| r.y += self.tops[b];
        }
    }
};

// Tests ----------------------------------------------------------------------------

const Fixture = paragraph_.testing.Fixture;

/// Random paragraphs of Latin, Hebrew, digits, spaces, tabs, and every
/// kind of paragraph separator.
fn randomText(rand: std.Random, buf: *std.ArrayList(u8), a: Allocator, paragraphs: usize) !void {
    const words = [_][]const u8{ "abc", "de", "fghij", "אבג", "דה", "12", "x", "wwwwwwww" };
    const separators = [_][]const u8{ "\n", "\r\n", "\r", "\u{2029}", "\u{85}", "\n\n" };
    var last: usize = 0;
    for (0..paragraphs) |_| {
        const count = rand.uintLessThan(usize, 12);
        for (0..count) |i| {
            if (i > 0) try buf.appendSlice(a, if (rand.uintLessThan(u8, 8) == 0) "\t" else " ");
            try buf.appendSlice(a, words[rand.uintLessThan(usize, words.len)]);
        }
        const sep = separators[rand.uintLessThan(usize, separators.len)];
        try buf.appendSlice(a, sep);
        last = sep.len;
    }
    // Text that ends without a separator too.
    if (rand.boolean()) buf.shrinkRetainingCapacity(buf.items.len - last);
}

fn expectSameLayout(flat: *const Layout, text: *const TextLayout, gpa: Allocator) !void {
    const t = std.testing;
    try t.expectEqual(@as(u32, @intCast(flat.lines.len)), text.lineCount());
    try t.expectApproxEqAbs(flat.height, text.height, 0.01);
    for (flat.lines, 0..) |fl, i| {
        const l = text.line(@intCast(i));
        try t.expectEqual(fl.start, l.start);
        try t.expectEqual(fl.end, l.end);
        try t.expectEqual(fl.paragraph, l.paragraph);
        try t.expectApproxEqAbs(fl.top, l.top, 0.01);
        try t.expectApproxEqAbs(fl.baseline, l.baseline, 0.01);
        try t.expectApproxEqAbs(fl.width, l.width, 0.01);
        try t.expectApproxEqAbs(fl.height, l.height, 0.01);
    }
    const len: u32 = @intCast(flat.paragraph.text.len);
    for (0..len + 1) |o_| {
        const o: u32 = @intCast(o_);
        for ([_]layout_.Affinity{ .downstream, .upstream }) |aff| {
            const pos: Position = .{ .offset = o, .affinity = aff };
            const fc = flat.caret(pos);
            const tc = text.caret(pos);
            try t.expectEqual(fc.line, tc.line);
            try t.expectApproxEqAbs(fc.x, tc.x, 0.01);
            try t.expectApproxEqAbs(fc.top, tc.top, 0.01);
            for ([_]cursor.Direction{ .left, .right }) |d| try t.expectEqual(flat.moveVisual(pos, d), text.moveVisual(pos, d));
            for ([_]cursor.Boundary{ .start, .end }) |bd| try t.expectEqual(flat.lineBoundary(pos, bd), text.lineBoundary(pos, bd));
            for ([_]cursor.Vertical{ .up, .down }) |v| {
                try t.expectEqual(flat.moveVertical(pos, null, v), text.moveVertical(pos, null, v));
                try t.expectEqual(flat.moveVertical(pos, 13, v), text.moveVertical(pos, 13, v));
            }
        }
        try t.expectEqual(flat.nextGrapheme(o), text.nextGrapheme(o));
        try t.expectEqual(flat.previousGrapheme(o), text.previousGrapheme(o));
        try t.expectEqual(flat.nextWordEnd(o), text.nextWordEnd(o));
        try t.expectEqual(flat.previousWordStart(o), text.previousWordStart(o));
        const p = flat.paragraph.paragraphs[flat.paragraph.paragraphAt(o)];
        try t.expectEqual([2]u32{ p.start, p.contentEnd() }, text.shaped.paragraphRange(o));
        const words = flat.paragraph.words.boundaries;
        var ws = words.atOrBefore(o) orelse 0;
        if (ws == len and len > 0) ws = words.before(len) orelse 0;
        try t.expectEqual([2]u32{ ws, words.after(ws) orelse len }, text.shaped.wordAt(o));
    }
    var y: f32 = -5;
    while (y < flat.height + 10) : (y += 3.7) {
        try t.expectEqual(flat.lineAt(y), text.lineAt(y));
        var x: f32 = -5;
        while (x < 300) : (x += 11.3) try t.expectEqual(flat.hitTest(x, y), text.hitTest(x, y));
    }
    var a: std.ArrayList(Rect) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(Rect) = .empty;
    defer b.deinit(gpa);
    var s: u32 = 0;
    while (s < len) : (s += 7) {
        a.clearRetainingCapacity();
        b.clearRetainingCapacity();
        const e = @min(len, s + 23);
        try flat.selectionRects(gpa, s, e, &a);
        try text.selectionRects(gpa, s, e, &b);
        // Rectangles of one line that meet across a block boundary stay
        // apart: compare the area they cover per line.
        try t.expectApproxEqAbs(coverage(a.items), coverage(b.items), 0.05);
    }
}

fn coverage(rects: []const Rect) f32 {
    var sum: f32 = 0;
    for (rects) |r| sum += r.width * r.height + r.y * 0.001 * r.width;
    return sum;
}

test "paragraphEnd finds UAX #9's paragraph separators" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var prng: std.Random.DefaultPrng = .init(7);
    const a = fixture.arena.allocator();
    for (0..40) |_| {
        var buf: std.ArrayList(u8) = .empty;
        try randomText(prng.random(), &buf, a, 6);
        const analysis = try bidi.analyze(a, buf.items, .auto_ltr);
        var at: usize = 0;
        for (analysis.paragraphs) |p| {
            try std.testing.expectEqual(@as(usize, p.start), at);
            at = paragraphEnd(buf.items, at, buf.items.len);
            try std.testing.expectEqual(@as(usize, p.end), at);
        }
    }
}

test "a text in blocks lays out, moves, and hit-tests as one paragraph does" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const fonts = [_]FontId{ fixture.latin, fixture.arabic, fixture.hebrew };
    const style: Style = .{ .fonts = &fonts, .size = 16 };
    var prng: std.Random.DefaultPrng = .init(11);
    const rand = prng.random();
    for (0..12) |round| {
        const a = fixture.arena.allocator();
        var buf: std.ArrayList(u8) = .empty;
        try randomText(rand, &buf, a, 1 + rand.uintLessThan(usize, 9));
        const styles = [_]StyleRun{.{ .end = @intCast(buf.items.len), .style = style }};
        const spacing: layout_.ParagraphStyle = .{ .space_before = 3, .space_after = 5, .line_spacing = 1.25 };
        const options: layout_.Options = .{ .width = 90 + @as(f32, @floatFromInt(round)) * 7, .paragraphs = &.{.{ .end = std.math.maxInt(u32), .style = spacing }} };
        var flat_p = try ShapedParagraph.init(gpa, a, &fixture.cache, buf.items, &styles, .auto_ltr);
        defer flat_p.deinit();
        var flat = try Layout.init(gpa, a, &fixture.cache, &flat_p, options);
        defer flat.deinit();
        var shaped = try ShapedText.init(gpa, a, &fixture.cache, buf.items, &styles, .auto_ltr, .{ .block_bytes = 1 + rand.uintLessThan(u32, 40) });
        defer shaped.deinit();
        var text = try TextLayout.init(gpa, a, &fixture.cache, &shaped, options, null);
        defer text.deinit();
        try expectSameLayout(&flat, &text, gpa);
    }
}

test "an edit reshapes only its block and equals shaping the new text" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const fonts = [_]FontId{ fixture.latin, fixture.arabic, fixture.hebrew };
    const style: Style = .{ .fonts = &fonts, .size = 16 };
    var prng: std.Random.DefaultPrng = .init(23);
    const rand = prng.random();
    const inserts = [_][]const u8{ "q", "\n", "\r", "\n\r\n", "א", " ", "zz\u{2029}y", "" };
    const block_options: Options = .{ .block_bytes = 24 };
    const options: layout_.Options = .{ .width = 120 };
    for (0..60) |_| {
        const a = fixture.arena.allocator();
        var buf: std.ArrayList(u8) = .empty;
        try randomText(rand, &buf, a, 2 + rand.uintLessThan(usize, 8));
        var shaped = try ShapedText.init(gpa, a, &fixture.cache, buf.items, &.{.{ .end = @intCast(buf.items.len), .style = style }}, .auto_ltr, block_options);
        defer shaped.deinit();
        var text = try TextLayout.init(gpa, a, &fixture.cache, &shaped, options, null);
        defer text.deinit();
        // Several edits in a row, each from the last.
        for (0..4) |_| {
            var start = rand.uintAtMost(usize, buf.items.len);
            while (start > 0 and start < buf.items.len and buf.items[start] & 0xc0 == 0x80) start -= 1;
            var end = @min(buf.items.len, start + rand.uintLessThan(usize, 6));
            while (end < buf.items.len and buf.items[end] & 0xc0 == 0x80) end += 1;
            var next: std.ArrayList(u8) = .empty;
            try next.appendSlice(a, buf.items[0..start]);
            try next.appendSlice(a, inserts[rand.uintLessThan(usize, inserts.len)]);
            try next.appendSlice(a, buf.items[end..]);
            const styles = [_]StyleRun{.{ .end = @intCast(next.items.len), .style = style }};
            var reshaped = try ShapedText.initReusing(gpa, a, &fixture.cache, next.items, &styles, .auto_ltr, block_options, &shaped);
            const relaid = TextLayout.init(gpa, a, &fixture.cache, &reshaped, options, &text) catch |err| {
                reshaped.deinit();
                return err;
            };
            text.deinit();
            shaped.deinit();
            shaped = reshaped;
            text = relaid;
            text.shaped = &shaped;
            buf = next;
            var flat_p = try ShapedParagraph.init(gpa, a, &fixture.cache, buf.items, &styles, .auto_ltr);
            defer flat_p.deinit();
            var flat = try Layout.init(gpa, a, &fixture.cache, &flat_p, options);
            defer flat.deinit();
            var concatenated: std.ArrayList(u8) = .empty;
            for (shaped.blocks, 0..) |b, i| {
                try std.testing.expectEqual(shaped.starts[i], @as(u32, @intCast(concatenated.items.len)));
                try concatenated.appendSlice(a, b.paragraph.text);
                if (i + 1 < shaped.blocks.len) try std.testing.expect(endsWithSeparator(b.paragraph.text));
            }
            try std.testing.expectEqualStrings(buf.items, concatenated.items);
            try expectSameLayout(&flat, &text, gpa);
        }
    }
}
