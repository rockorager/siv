//! A text as a sequence of blocks (D13): runs of whole bidi paragraphs of
//! about `Options.block_bytes`, each with its own `ShapedParagraph` and
//! `Layout`. Paragraphs are independent (bidi, line, grapheme, and word
//! boundaries all break after a separator, and shaping stops there), so
//! splitting a text between paragraphs changes nothing, and an edit
//! reshapes and lays out only the block it falls in. Blocks are shared,
//! by reference count, between a text and the one an edit built from it:
//! an edit costs its block plus a few words per block, not the document's
//! size. Offsets, lines, and positions in the API are the whole text's.
//!
//! Memory is bounded (D13): every block keeps its bytes, its styles, and
//! its exact metrics once measured (height, lines, width, the space around
//! it), but its shaping and lines (`ShapedParagraph`, `Layout`) only while
//! a `Residency` keeps it: blocks used least recently are evicted beyond
//! its budget and built again, identically, when something needs them. A
//! long text may also leave blocks unshaped (`Options.eager_bytes`) and lay
//! them out with estimated metrics (`TextLayout.init`'s `estimate`) until
//! they are measured, on demand or by the caller on another thread.

const std = @import("std");
const paragraph_ = @import("paragraph.zig");
const layout_ = @import("layout.zig");
const cursor = @import("cursor.zig");
const font = @import("font.zig");
const bidi = @import("bidi.zig");
const Rope = @import("rope.zig").Rope;

const Allocator = std.mem.Allocator;
const ShapedParagraph = paragraph_.ShapedParagraph;
const StyleRun = paragraph_.StyleRun;
const Style = paragraph_.Style;
const BuildError = paragraph_.BuildError;
const Layout = layout_.Layout;
const Line = layout_.Line;
const Rect = layout_.Rect;
const ParagraphRun = layout_.ParagraphRun;
const ParagraphStyle = layout_.ParagraphStyle;
const FontCache = font.FontCache;
const FontId = font.FontId;
const Position = cursor.Position;
const CaretRect = cursor.CaretRect;

/// A text's bytes, read by range: one buffer, or a rope (D15), whose
/// bytes a block copies a block's worth at a time.
pub const Source = struct {
    len: usize,
    bytes: ?[]const u8 = null,
    rope: Rope = .{},

    pub fn flat(bytes: []const u8) Source {
        return .{ .len = bytes.len, .bytes = bytes };
    }

    pub fn ofRope(r: Rope) Source {
        if (r.flat()) |f| return flat(f);
        return .{ .len = r.len(), .rope = r };
    }

    fn byteAt(s: Source, i: usize) u8 {
        return if (s.bytes) |b| b[i] else s.rope.byteAt(i);
    }

    /// Bytes `from..to`: the buffer's, or a copy in `buf`.
    fn window(s: Source, gpa: Allocator, buf: *std.ArrayList(u8), from: usize, to: usize) error{OutOfMemory}![]const u8 {
        if (s.bytes) |b| return b[from..to];
        buf.clearRetainingCapacity();
        try buf.resize(gpa, to - from);
        s.rope.read(from, buf.items);
        return buf.items;
    }
};

/// What an edit changed, from the bytes the old and new texts have in
/// common at their start and at their end: their caller knows it (a
/// rope finds it in the time the change takes, `Rope.commonPrefix`), so
/// building the new text compares nothing.
pub const Change = struct {
    prefix: usize,
    suffix: usize,
};

pub const Options = struct {
    /// A block ends at the first paragraph end at or after this many bytes
    /// (or the end of the text); a paragraph longer than this is a block of
    /// its own.
    block_bytes: u32 = 8192,
    /// Shape only the blocks that cover the first this many bytes; the
    /// rest are split into blocks but left unshaped, to be shaped when
    /// something needs them (`ShapedBlock.ensure`) or on another thread
    /// (`ShapedBlock.shapeAlone`, `install`). Null shapes every block.
    eager_bytes: ?u32 = null,
    /// Counts the blocks' shaping and lines against a budget and evicts
    /// them (null: they are kept).
    residency: ?*Residency = null,
};

/// The shaped blocks whose shaping and lines are in memory, least recently
/// used first, and their size. `trim` evicts blocks beyond `budget`, never
/// one used since the last trim (what an operation or a frame is using).
/// Only the thread that owns the texts touches it.
pub const Residency = struct {
    gpa: Allocator,
    budget: usize,
    /// Bytes of shaping and lines its blocks hold.
    bytes: usize = 0,
    head: ?*ShapedBlock = null,
    tail: ?*ShapedBlock = null,
    epoch: u32 = 1,
    /// Pending fonts that blocks shaped after their text was built wanted
    /// (`ShapedText.wanted` has the others); the owner requests them and
    /// clears the list.
    wanted: std.ArrayList(FontId) = .empty,
    /// Blocks shaped on demand or installed, and blocks evicted.
    shapes: u64 = 0,
    evictions: u64 = 0,

    pub fn init(gpa: Allocator, budget: usize) Residency {
        return .{ .gpa = gpa, .budget = budget };
    }

    /// What its blocks' shaping and lines are allocated with: `gpa`, but
    /// allocations of `big` bytes or more (glyphs, caret stops, arena
    /// chunks) go to pages of their own, which go back to the system when
    /// freed. Evicting blocks freed them into the C heap, whose free space
    /// a long text's blocks, built again elsewhere, scattered: 30 MiB of
    /// it stayed resident for the 1.4 MB editor. Safe on any thread, as
    /// `gpa` is.
    pub fn allocator(r: *Residency) Allocator {
        return .{ .ptr = &r.gpa, .vtable = &heavy_vtable };
    }

    const big = 64 << 10;

    const heavy_vtable: Allocator.VTable = .{
        .alloc = heavyAlloc,
        .resize = heavyResize,
        .remap = heavyRemap,
        .free = heavyFree,
    };

    fn route(ctx: *anyopaque, len: usize) Allocator {
        if (len >= big) return std.heap.page_allocator;
        const child: *const Allocator = @ptrCast(@alignCast(ctx));
        return child.*;
    }

    fn heavyAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        return route(ctx, len).rawAlloc(len, alignment, ra);
    }

    fn heavyResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        if ((memory.len >= big) != (new_len >= big)) return false;
        return route(ctx, memory.len).rawResize(memory, alignment, new_len, ra);
    }

    fn heavyRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        if ((memory.len >= big) != (new_len >= big)) return null;
        return route(ctx, memory.len).rawRemap(memory, alignment, new_len, ra);
    }

    fn heavyFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        route(ctx, memory.len).rawFree(memory, alignment, ra);
    }

    /// Every text using it must be gone first.
    pub fn deinit(r: *Residency) void {
        std.debug.assert(r.head == null);
        r.wanted.deinit(r.gpa);
        r.* = undefined;
    }

    /// Puts `b` first: the next to evict.
    fn linkFirst(r: *Residency, b: *ShapedBlock) void {
        b.prev = null;
        b.next = r.head;
        if (r.head) |h| h.prev = b else r.tail = b;
        r.head = b;
    }

    fn link(r: *Residency, b: *ShapedBlock) void {
        b.prev = r.tail;
        b.next = null;
        if (r.tail) |t| t.next = b else r.head = b;
        r.tail = b;
    }

    fn unlink(r: *Residency, b: *ShapedBlock) void {
        if (b.prev) |p| p.next = b.next else r.head = b.next;
        if (b.next) |n| n.prev = b.prev else r.tail = b.prev;
        b.prev = null;
        b.next = null;
    }

    /// Evicts the least recently used blocks until it fits its budget,
    /// sparing blocks used since the last trim and blocks shaped with
    /// fonts still loading (shaping them again could differ).
    pub fn trim(r: *Residency) void {
        var cur = r.head;
        while (r.bytes > r.budget) {
            const b = cur orelse break;
            if (b.last_use == r.epoch) break;
            cur = b.next;
            if (b.pinned) continue;
            b.evict();
            r.evictions += 1;
        }
        r.epoch +%= 1;
        if (r.epoch == 0) r.epoch = 1;
    }
};

/// A run of whole paragraphs shaped on its own, shared by the texts built
/// from one another. Its bytes and styles are its own copies, so it can be
/// shaped again from nothing else.
pub const ShapedBlock = struct {
    refs: u32 = 1,
    gpa: Allocator,
    cache: *const FontCache,
    residency: ?*Residency,
    text: []const u8,
    /// Its style runs, ends relative to it; fonts and languages copied.
    styles: []const StyleRun,
    direction: bidi.BaseDirection,
    /// Its bidi paragraphs.
    paragraphs: u32,
    /// Null while not shaped yet or evicted.
    paragraph: ?ShapedParagraph = null,
    /// The old text's block this one was reshaped from by
    /// `ShapedParagraph.initReusing`, so that laying it out can keep that
    /// block's lines (`Layout.initReusing`). Never dereferenced: only
    /// matched against the blocks of the old text's layout, which keeps
    /// them alive.
    from: ?*const ShapedBlock = null,
    /// Shaped with fonts still loading: kept in memory, since shaping it
    /// again after they load would differ (its text reshapes then anyway).
    pinned: bool = false,
    /// Its layouts (`LayoutBlock.sibling`), evicted with it.
    layouts: ?*LayoutBlock = null,
    prev: ?*ShapedBlock = null,
    next: ?*ShapedBlock = null,
    last_use: u32 = 0,
    /// What it counts in its residency.
    bytes: usize = 0,
    /// For the owner: a job on another thread is shaping it.
    queued: bool = false,
    /// Its shaping and lines are on the heap (`heavy`).
    on_heap: bool = false,

    /// A block of a copy of `text`, which starts at byte `s` of the text
    /// `styles` cover; not shaped.
    fn create(gpa: Allocator, cache: *const FontCache, residency: ?*Residency, text: []const u8, styles: []const StyleRun, direction: bidi.BaseDirection, s: usize) error{OutOfMemory}!*ShapedBlock {
        const e = s + text.len;
        const b = try gpa.create(ShapedBlock);
        errdefer gpa.destroy(b);
        const bytes = try gpa.dupe(u8, text);
        errdefer gpa.free(bytes);
        var k = styleIndex(styles, s);
        var count: usize = 1;
        while (styles[k + count - 1].end < e and k + count < styles.len) count += 1;
        const local = try gpa.alloc(StyleRun, count);
        var made: usize = 0;
        errdefer {
            for (local[0..made]) |r| freeStyle(gpa, r.style);
            gpa.free(local);
        }
        for (local) |*run| {
            const src = styles[k];
            const fonts = try gpa.dupe(FontId, src.style.fonts);
            const language = gpa.dupe(u8, src.style.language) catch |err| {
                gpa.free(fonts);
                return err;
            };
            run.* = .{ .end = @intCast(@min(src.end, e) - s), .style = .{ .fonts = fonts, .size = src.style.size, .language = language } };
            made += 1;
            k += 1;
        }
        local[count - 1].end = @intCast(e - s);
        b.* = .{ .gpa = gpa, .cache = cache, .residency = residency, .text = bytes, .styles = local, .direction = direction, .paragraphs = countParagraphs(bytes) };
        return b;
    }

    fn freeStyle(gpa: Allocator, style: Style) void {
        gpa.free(style.fonts);
        gpa.free(style.language);
    }

    fn retain(b: *ShapedBlock) *ShapedBlock {
        b.refs += 1;
        return b;
    }

    pub fn release(b: *ShapedBlock) void {
        b.refs -= 1;
        if (b.refs != 0) return;
        std.debug.assert(b.layouts == null);
        if (b.paragraph) |*p| {
            if (b.residency) |r| {
                r.unlink(b);
                r.bytes -= b.bytes;
            }
            p.deinit();
        }
        for (b.styles) |r| freeStyle(b.gpa, r.style);
        b.gpa.free(b.styles);
        b.gpa.free(b.text);
        b.gpa.destroy(b);
    }

    pub fn len(b: *const ShapedBlock) u32 {
        return @intCast(b.text.len);
    }

    /// What its shaping and its layouts' lines are allocated with: the
    /// residency's pages, or the heap for a block shaped with its text,
    /// as edits shape them (fresh pages cost a page fault each, 0.6 ms a
    /// keystroke in the 1.4 MB editor). Built again after an eviction, it
    /// takes pages.
    fn heavy(b: *const ShapedBlock) Allocator {
        if (b.on_heap) return b.gpa;
        return if (b.residency) |r| r.allocator() else b.gpa;
    }

    /// Its shaping, shaped (again) if not in memory; counts as a use.
    pub fn ensure(b: *ShapedBlock) error{OutOfMemory}!*const ShapedParagraph {
        if (b.paragraph == null) {
            var tmp: std.heap.ArenaAllocator = .init(b.gpa);
            defer tmp.deinit();
            const p = b.shapeWith(b.heavy(), tmp.allocator()) catch |err| return oom(err);
            b.adopt(p, true);
        }
        b.touch();
        return &b.paragraph.?;
    }

    /// Shapes its bytes: on any thread while its text holds a reference
    /// and `cache` stays as it is; `install` puts the result in place.
    pub fn shapeAlone(b: *const ShapedBlock) BuildError!ShapedParagraph {
        var tmp: std.heap.ArenaAllocator = .init(b.gpa);
        defer tmp.deinit();
        return b.shapeWith(b.heavy(), tmp.allocator());
    }

    fn shapeWith(b: *const ShapedBlock, gpa: Allocator, scratch: Allocator) BuildError!ShapedParagraph {
        return ShapedParagraph.init(gpa, scratch, b.cache, b.text, b.styles, b.direction);
    }

    /// Takes `p` (`shapeAlone`'s) as its shaping, unless it was shaped
    /// meanwhile. Not a use: the next trim may evict it.
    pub fn install(b: *ShapedBlock, p: ShapedParagraph) void {
        if (b.paragraph != null) {
            var q = p;
            q.deinit();
            return;
        }
        b.adopt(p, true);
    }

    /// `late`: shaped after its text was built, so fonts it wanted are
    /// the residency's to report, and it is the first to evict unless it
    /// is used.
    fn adopt(b: *ShapedBlock, p: ShapedParagraph, late: bool) void {
        b.paragraph = p;
        if (p.wanted.len != 0) b.pinned = true;
        if (b.residency) |r| {
            if (late) r.linkFirst(b) else r.link(b);
            if (late) {
                r.shapes += 1;
                for (p.wanted) |f| if (std.mem.indexOfScalar(FontId, r.wanted.items, f) == null) r.wanted.append(r.gpa, f) catch {};
            }
        }
        b.recount();
    }

    fn touch(b: *ShapedBlock) void {
        const r = b.residency orelse return;
        b.last_use = r.epoch;
        if (r.tail == b) return;
        r.unlink(b);
        r.link(b);
    }

    /// Updates what it counts in its residency.
    fn recount(b: *ShapedBlock) void {
        const r = b.residency orelse return;
        var n: usize = 0;
        if (b.paragraph) |*p| n += p.bytes();
        var it = b.layouts;
        while (it) |lb| : (it = lb.sibling) if (lb.layout) |*l| {
            n += l.bytes();
        };
        r.bytes = r.bytes - b.bytes + n;
        b.bytes = n;
    }

    /// Leaves its residency, for a block only a job on another thread
    /// still holds, which may outlive the residency.
    pub fn detach(b: *ShapedBlock) void {
        std.debug.assert(b.layouts == null);
        const r = b.residency orelse return;
        if (b.paragraph != null) {
            r.unlink(b);
            r.bytes -= b.bytes;
            b.bytes = 0;
        }
        b.residency = null;
    }

    /// Frees its shaping and its layouts' lines; their metrics stay.
    fn evict(b: *ShapedBlock) void {
        var it = b.layouts;
        while (it) |lb| : (it = lb.sibling) if (lb.layout) |*l| {
            l.deinit();
            lb.layout = null;
        };
        b.paragraph.?.deinit();
        b.paragraph = null;
        b.on_heap = false;
        const r = b.residency.?;
        r.unlink(b);
        r.bytes -= b.bytes;
        b.bytes = 0;
    }
};

fn oom(err: anyerror) error{OutOfMemory} {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Its bytes and styles were checked when its text was built,
        // and it was laid out with these options before.
        else => unreachable,
    };
}

/// The width-independent part: the text's blocks, shaped or not.
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
    /// Some block shaped while building it had a font missing (see
    /// `ShapedParagraph.missing`).
    missing: bool,
    /// Pending fonts shaping would have tried, from the blocks shaped
    /// while building it; blocks shaped later report theirs to the
    /// residency.
    wanted: []FontId,
    /// The text's one style, when it has one (a copy): an edit keeps
    /// every block outside the change without comparing styles block by
    /// block, which cost 2 ms a keystroke for 12,800 blocks.
    only_style: ?Style = null,

    /// Shapes `text` with `styles` (as `ShapedParagraph.init` takes them)
    /// in blocks: all of them, or those within `options.eager_bytes`.
    pub fn init(gpa: Allocator, scratch: Allocator, cache: *const FontCache, text: []const u8, styles: []const StyleRun, direction: bidi.BaseDirection, options: Options) BuildError!ShapedText {
        return initFrom(gpa, scratch, cache, .flat(text), styles, direction, options);
    }

    /// `init` from a source, read a block at a time.
    pub fn initFrom(gpa: Allocator, scratch: Allocator, cache: *const FontCache, text: Source, styles: []const StyleRun, direction: bidi.BaseDirection, options: Options) BuildError!ShapedText {
        try validate(cache, text, styles);
        var list: std.ArrayList(*ShapedBlock) = .empty;
        defer list.deinit(scratch);
        errdefer for (list.items) |b| b.release();
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const ctx: Ctx = .{ .gpa = gpa, .scratch = scratch, .tmp = &tmp, .cache = cache, .text = text, .buf = &buf, .styles = styles, .direction = direction, .options = options };
        var eager: usize = options.eager_bytes orelse std.math.maxInt(usize);
        try ctx.appendBlocks(&list, 0, text.len, &eager);
        return finish(gpa, list.items, styles, direction, options);
    }

    /// Like `init`, but keeps `old`'s blocks (the text before an edit)
    /// that the edit left alone, with their styles: only blocks holding
    /// changed bytes or styles are shaped again. A block next to the
    /// change is redone too when the change touches its separator (an
    /// edit after a CR could make a CRLF), and a redone stretch smaller
    /// than a quarter block takes in its neighbor, so edits do not leave
    /// slivers. Blocks whose styles changed are shaped again only if they
    /// were in memory; others are left unshaped.
    pub fn initReusing(gpa: Allocator, scratch: Allocator, cache: *const FontCache, text: []const u8, styles: []const StyleRun, direction: bidi.BaseDirection, options: Options, old: ?*const ShapedText) BuildError!ShapedText {
        return initEdit(gpa, scratch, cache, .flat(text), styles, direction, options, old, null);
    }

    /// `initReusing` from a source, with what changed when the caller
    /// knows it (else found by comparing the texts, which needs a flat
    /// source): only the blocks the change touches are compared and
    /// built again, so an edit costs its blocks, not the text.
    pub fn initEdit(gpa: Allocator, scratch: Allocator, cache: *const FontCache, text: Source, styles: []const StyleRun, direction: bidi.BaseDirection, options: Options, old_: ?*const ShapedText, change: ?Change) BuildError!ShapedText {
        const old = old_ orelse return initFrom(gpa, scratch, cache, text, styles, direction, options);
        if (old.direction != direction or old.missing or old.wanted.len != 0 or old.options.block_bytes != options.block_bytes or old.len() == 0 or text.len == 0)
            return initFrom(gpa, scratch, cache, text, styles, direction, options);
        try validate(cache, text, styles);
        const old_len = old.len();
        const n = old.blocks.len;

        // The changed bytes, from the common prefix and suffix: given, or
        // by whole blocks compared with memcmp, looking into only the one
        // that differs.
        const flat_text = text.bytes orelse &.{};
        const prefix = if (change) |c| @min(c.prefix, old_len, text.len) else blk: {
            const t = text.bytes.?;
            for (old.blocks, 0..) |b, i| {
                const s = old.starts[i];
                const bt = b.text;
                const k = @min(bt.len, t.len - s);
                if (k == bt.len and sameBytes(bt, t[s..][0..k])) continue;
                if (std.mem.indexOfDiff(u8, bt[0..k], t[s..][0..k])) |d| break :blk s + d;
                break :blk s + k;
            }
            break :blk @as(usize, old_len);
        };
        const suffix = if (change) |c| @min(c.suffix, @min(old_len, text.len) - prefix) else blk: {
            const t = flat_text;
            const limit = @min(old_len, text.len) - prefix;
            var done: usize = 0;
            var i = n;
            while (i > 0 and done < limit) {
                i -= 1;
                const bt = old.blocks[i].text;
                const k = @min(bt.len, limit - done);
                if (k == bt.len and sameBytes(bt, t[t.len - done - k ..][0..k])) {
                    done += k;
                    continue;
                }
                var j: usize = 0;
                while (j < k and bt[bt.len - 1 - j] == t[t.len - 1 - done - j]) j += 1;
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
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const uniform = styles.len == 1 and if (old.only_style) |o| sameStyle(o, styles[0].style) else false;
        const ctx: Ctx = .{ .gpa = gpa, .scratch = scratch, .tmp = &tmp, .cache = cache, .text = text, .buf = &buf, .styles = styles, .direction = direction, .options = options, .uniform = uniform };

        // Blocks before the change: kept unless it touches their end.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const end = old.starts[i + 1];
            const b = old.blocks[i];
            const sealed = end < prefix or (end == prefix and endsWithSeparator(b.text) and b.text[b.text.len - 1] != '\r');
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
            list.appendAssumeCapacity(try ctx.shapeBlock(from, to, old.blocks[i]));
        } else if (to > from or (list.items.len == 0 and j == n)) {
            var eager: usize = options.eager_bytes orelse std.math.maxInt(usize);
            try ctx.appendBlocks(&list, from, to, &eager);
        }
        while (j < n) : (j += 1) try ctx.keepOrRedo(&list, old.blocks[j], shift(old.starts[j], delta));
        return finish(gpa, list.items, styles, direction, options);
    }

    pub fn deinit(self: *ShapedText) void {
        for (self.blocks) |b| b.release();
        self.gpa.free(self.blocks);
        self.gpa.free(self.starts);
        self.gpa.free(self.style_firsts);
        self.gpa.free(self.paragraph_starts);
        self.gpa.free(self.wanted);
        if (self.only_style) |st| {
            self.gpa.free(st.fonts);
            self.gpa.free(st.language);
        }
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

    fn shapedAt(self: *const ShapedText, b: u32) error{OutOfMemory}!*const ShapedParagraph {
        return self.blocks[b].ensure();
    }

    /// The bidi paragraph at `offset` without its separator (the last one
    /// at the end of the text).
    pub fn paragraphRange(self: *const ShapedText, offset: u32) error{OutOfMemory}![2]u32 {
        const b = self.blockAt(offset);
        const p = try self.shapedAt(b);
        const s = self.starts[b];
        const para = p.paragraphs[p.paragraphAt(offset - s)];
        return .{ s + para.start, s + para.contentEnd() };
    }

    /// The word (or run of spaces or punctuation, UAX #29) at `offset`.
    pub fn wordAt(self: *const ShapedText, offset: u32) error{OutOfMemory}![2]u32 {
        const b = self.blockAt(offset);
        const p = try self.shapedAt(b);
        const s = self.starts[b];
        const words = p.words.boundaries;
        const blen: u32 = @intCast(p.text.len);
        var start = words.atOrBefore(offset - s) orelse 0;
        if (start == blen and blen > 0) start = words.before(blen) orelse 0;
        return .{ s + start, s + (words.after(start) orelse blen) };
    }

    /// The advance of an "x" in the font and size of the style at
    /// `offset` (the last style at the text's end): the width of a
    /// character where there is none. Null if no font of the style that
    /// is loaded has an "x".
    pub fn xAdvance(self: *const ShapedText, offset: u32) ?f32 {
        const b = self.blockAt(offset);
        const blk = self.blocks[b];
        if (blk.styles.len == 0) return null;
        const local = offset - @min(offset, self.starts[b]);
        var st = blk.styles[blk.styles.len - 1].style;
        for (blk.styles) |r| if (r.end > local) {
            st = r.style;
            break;
        };
        for (st.fonts) |id| {
            const face = blk.cache.face(id) orelse continue;
            const g = face.nominalGlyph('x') orelse continue;
            return face.advance(g, st.size);
        }
        return null;
    }

    pub fn nextGrapheme(self: *const ShapedText, offset: u32) error{OutOfMemory}!u32 {
        const b = self.blockAt(offset);
        const p = try self.shapedAt(b);
        const s = self.starts[b];
        return s + (p.graphemes.after(offset - s) orelse @as(u32, @intCast(p.text.len)));
    }

    pub fn previousGrapheme(self: *const ShapedText, offset: u32) error{OutOfMemory}!u32 {
        var b = self.blockAt(offset);
        var local = offset - self.starts[b];
        if (local == 0) {
            if (b == 0) return 0;
            b -= 1;
            local = self.blocks[b].len();
        }
        return self.starts[b] + ((try self.shapedAt(b)).graphemes.before(local) orelse 0);
    }

    /// The end of the word at or after `offset` (word-wise forward
    /// movement), across blocks as across paragraphs.
    pub fn nextWordEnd(self: *const ShapedText, offset: u32) error{OutOfMemory}!u32 {
        var b = self.blockAt(offset);
        var local = offset - self.starts[b];
        while (true) {
            const p = try self.shapedAt(b);
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
    pub fn previousWordStart(self: *const ShapedText, offset: u32) error{OutOfMemory}!u32 {
        var b = self.blockAt(offset);
        var local = offset - self.starts[b];
        while (true) {
            if (local == 0) {
                if (b == 0) return 0;
                b -= 1;
                local = self.blocks[b].len();
            }
            const words = (try self.shapedAt(b)).words;
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
        text: Source,
        /// Where blocks of a rope are copied out to.
        buf: *std.ArrayList(u8),
        styles: []const StyleRun,
        direction: bidi.BaseDirection,
        options: Options,
        /// The old text and this one have the same one style.
        uniform: bool = false,

        /// Appends `b`, now at `start`, if its styles are still the text's
        /// there; else its bytes again (unchanged), shaped if `b` was.
        fn keepOrRedo(ctx: Ctx, list: *std.ArrayList(*ShapedBlock), b: *ShapedBlock, start: usize) BuildError!void {
            try list.ensureUnusedCapacity(ctx.scratch, 1);
            if ((ctx.uniform and b.styles.len == 1) or sameStyles(b, ctx.styles, start)) {
                list.appendAssumeCapacity(b.retain());
                return;
            }
            list.appendAssumeCapacity(if (b.paragraph != null) try ctx.shapeBytes(b.text, start, null) else try ctx.unshapedBytes(b.text, start));
        }

        /// The end of the block that starts at `s`, as `blockEnd` finds it
        /// in a flat text; a rope is read a window at a time, grown until
        /// the end is clear of the window's edge (a separator there may
        /// run past it).
        fn blockEndAt(ctx: Ctx, s: usize, to: usize) error{OutOfMemory}!usize {
            if (ctx.text.bytes) |b| return blockEnd(b, s, to, ctx.options);
            var want = @min(to, s + ctx.options.block_bytes + 1024);
            while (true) {
                const w = try ctx.text.window(ctx.gpa, ctx.buf, s, want);
                const e = blockEnd(w, 0, w.len, ctx.options);
                if (want == to or e + 3 <= w.len) return s + e;
                want = @min(to, s + 2 * (want - s));
            }
        }

        /// Appends blocks covering `text[from..to]`, which starts and ends
        /// at paragraph boundaries (or the text's ends), shaping them while
        /// `eager` bytes are left; one empty block for empty text.
        fn appendBlocks(ctx: Ctx, list: *std.ArrayList(*ShapedBlock), from: usize, to: usize, eager: *usize) BuildError!void {
            var s = from;
            while (true) {
                const e = try ctx.blockEndAt(s, to);
                try list.ensureUnusedCapacity(ctx.scratch, 1);
                if (eager.* > 0) {
                    eager.* -|= e - s;
                    list.appendAssumeCapacity(try ctx.shapeBlock(s, e, null));
                } else list.appendAssumeCapacity(try ctx.unshaped(s, e));
                s = e;
                if (s >= to) break;
            }
        }

        /// `text[s..e]` as a block, not shaped yet.
        fn unshaped(ctx: Ctx, s: usize, e: usize) BuildError!*ShapedBlock {
            return ctx.unshapedBytes(try ctx.text.window(ctx.gpa, ctx.buf, s, e), s);
        }

        /// A block of `bytes`, at `s`, not shaped yet. Shaping checks a
        /// block's bytes are UTF-8; this one may be shaped on demand.
        fn unshapedBytes(ctx: Ctx, bytes: []const u8, s: usize) BuildError!*ShapedBlock {
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            return ShapedBlock.create(ctx.gpa, ctx.cache, ctx.options.residency, bytes, ctx.styles, ctx.direction, s);
        }

        /// Shapes `text[s..e]` as a block, from `old` (the block it
        /// replaces) when given and in memory.
        fn shapeBlock(ctx: Ctx, s: usize, e: usize, old: ?*const ShapedBlock) BuildError!*ShapedBlock {
            return ctx.shapeBytes(try ctx.text.window(ctx.gpa, ctx.buf, s, e), s, old);
        }

        fn shapeBytes(ctx: Ctx, bytes: []const u8, s: usize, old: ?*const ShapedBlock) BuildError!*ShapedBlock {
            // Intermediates go in `tmp`, emptied after each block, so a
            // long text never holds all of them at once.
            defer _ = ctx.tmp.reset(.retain_capacity);
            const b = try ShapedBlock.create(ctx.gpa, ctx.cache, ctx.options.residency, bytes, ctx.styles, ctx.direction, s);
            errdefer b.release();
            b.on_heap = true;
            const reused = if (old) |o| (if (o.paragraph) |*p| p else null) else null;
            const p = try ShapedParagraph.initReusing(b.heavy(), ctx.tmp.allocator(), ctx.cache, b.text, b.styles, ctx.direction, reused);
            if (p.reused != null) b.from = old;
            b.adopt(p, false);
            return b;
        }
    };

    /// Builds the text from `list`, taking its references, which cover it
    /// from the start.
    fn finish(gpa: Allocator, list: []const *ShapedBlock, styles: []const StyleRun, direction: bidi.BaseDirection, options: Options) BuildError!ShapedText {
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
            paragraphs += b.paragraphs;
            if (b.paragraph) |*p| {
                missing = missing or p.missing;
                for (p.wanted) |f| if (std.mem.indexOfScalar(FontId, wanted.items, f) == null) try wanted.append(gpa, f);
            }
        }
        starts[list.len] = at;
        paragraph_starts[list.len] = paragraphs;
        var only_style: ?Style = null;
        if (styles.len == 1) {
            const fonts = try gpa.dupe(FontId, styles[0].style.fonts);
            errdefer gpa.free(fonts);
            only_style = .{ .fonts = fonts, .size = styles[0].style.size, .language = try gpa.dupe(u8, styles[0].style.language) };
        }
        errdefer if (only_style) |st| {
            gpa.free(st.fonts);
            gpa.free(st.language);
        };
        // The list's references move into the result.
        return .{
            .only_style = only_style,
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

/// Shaping checks each block's bytes are UTF-8, and blocks kept from an
/// old text are its bytes, checked then: a keystroke does not check all
/// of a long text.
fn validate(cache: *const FontCache, text: Source, styles: []const StyleRun) BuildError!void {
    if (text.len >= std.math.maxInt(u32)) return error.TextTooLong;
    if (text.bytes) |b| return paragraph_.validateStyles(cache, b, styles);
    // As `validateStyles`, with the rope's bytes at the style ends.
    if (styles.len == 0 or styles[styles.len - 1].end != text.len) return error.InvalidStyles;
    var previous: u32 = 0;
    for (styles, 0..) |run, i| {
        if ((run.end <= previous and !(i == 0 and run.end == 0)) or run.end > text.len) return error.InvalidStyles;
        if (run.end < text.len and text.byteAt(run.end) & 0xc0 == 0x80) return error.InvalidStyles;
        if ((run.style.fonts.len == 0 and cache.last_resort == null) or !std.math.isFinite(run.style.size) or run.style.size <= 0) return error.InvalidStyles;
        previous = run.end;
    }
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

/// Whether any of 16 bytes can start a paragraph separator.
fn mayHoldSeparator(chunk: @Vector(16, u8)) bool {
    const V = @Vector(16, u8);
    const hit = (chunk == @as(V, @splat('\n'))) | (chunk == @as(V, @splat('\r'))) |
        ((chunk >= @as(V, @splat(0x1c))) & (chunk <= @as(V, @splat(0x1e)))) |
        (chunk == @as(V, @splat(0xc2))) | (chunk == @as(V, @splat(0xe2)));
    return @reduce(.Or, hit);
}

/// The end of the bidi paragraph at `from` (after its separator, a CRLF
/// counting as one), or `limit`: UAX #9's paragraph separators (class B).
pub fn paragraphEnd(text: []const u8, from: usize, limit: usize) usize {
    var i = from;
    while (i < limit) {
        // Sixteen bytes at a time past stretches without any.
        if (i + 16 <= limit and !mayHoldSeparator(text[i..][0..16].*)) {
            i += 16;
            continue;
        }
        switch (text[i]) {
            '\n', 0x1c, 0x1d, 0x1e => return i + 1,
            '\r' => return if (i + 1 < limit and text[i + 1] == '\n') i + 2 else i + 1,
            0xc2 => if (i + 1 < limit and text[i + 1] == 0x85) return i + 2,
            0xe2 => if (i + 2 < limit and text[i + 1] == 0x80 and text[i + 2] == 0xa9) return i + 3,
            else => {},
        }
        i += 1;
    }
    return limit;
}

/// The bidi paragraphs of `text` (one for empty text), as
/// `ShapedParagraph` finds them.
fn countParagraphs(text: []const u8) u32 {
    if (text.len == 0) return 1;
    var n: u32 = 0;
    var at: usize = 0;
    while (at < text.len) : (n += 1) at = paragraphEnd(text, at, text.len);
    return n;
}

/// The start of the last bidi paragraph of `text`.
fn lastParagraphStart(text: []const u8) usize {
    var end = text.len;
    if (std.mem.endsWith(u8, text, "\r\n") or std.mem.endsWith(u8, text, "\u{85}")) {
        end -= 2;
    } else if (std.mem.endsWith(u8, text, "\u{2029}")) {
        end -= 3;
    } else if (endsWithSeparator(text)) end -= 1;
    var i = end;
    while (i > 0) : (i -= 1) {
        switch (text[i - 1]) {
            '\n', '\r', 0x1c, 0x1d, 0x1e => return i,
            0x85 => if (i >= 2 and text[i - 2] == 0xc2) return i,
            0xa9 => if (i >= 3 and text[i - 2] == 0x80 and text[i - 3] == 0xe2) return i,
            else => {},
        }
    }
    return 0;
}

fn endsWithSeparator(text: []const u8) bool {
    if (text.len == 0) return false;
    const last = text[text.len - 1];
    if (last == '\n' or last == '\r' or (last >= 0x1c and last <= 0x1e)) return true;
    return std.mem.endsWith(u8, text, "\u{85}") or std.mem.endsWith(u8, text, "\u{2029}");
}

/// The end of the block that starts at `s` (a paragraph start) in a text
/// split from `s` on, no later than `to`: the first paragraph end at least
/// `block_bytes` past `s`. A separator ending there starts at most three
/// bytes before, so the search starts there.
pub fn blockEnd(text: []const u8, s: usize, to: usize, options: Options) usize {
    var e = @max(s, (s + options.block_bytes) -| 3);
    if (e >= to) return to;
    while (e < to) {
        e = paragraphEnd(text, e, to);
        if (e - s >= options.block_bytes) break;
    }
    return e;
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

fn sameStyle(a: Style, b: Style) bool {
    return a.size == b.size and std.mem.eql(FontId, a.fonts, b.fonts) and std.mem.eql(u8, a.language, b.language);
}

/// Whether the text's styles over `b`'s bytes, at `start`, are `b`'s.
fn sameStyles(b: *const ShapedBlock, styles: []const StyleRun, start: usize) bool {
    const blen = b.text.len;
    var k = styleIndex(styles, start);
    for (b.styles, 0..) |o, i| {
        if (k >= styles.len) return false;
        const run = styles[k];
        const local_end = @min(run.end, start + blen) - start;
        if (local_end != o.end) return false;
        if (run.style.size != o.style.size or !std.mem.eql(FontId, run.style.fonts, o.style.fonts) or !std.mem.eql(u8, run.style.language, o.style.language)) return false;
        if (i + 1 == b.styles.len) return run.end >= start + blen;
        k += 1;
    }
    return false;
}

/// What stacking a block's lines with the others needs, exact once it has
/// been laid out, estimated before.
pub const Metrics = struct {
    height: f32 = 0,
    lines: u32 = 1,
    /// Widest line without hanging whitespace, with its indents.
    width: f32 = 0,
    /// Its first paragraph's space before and its last's space after.
    space_before: f32 = 0,
    space_after: f32 = 0,

    fn of(l: *const Layout, paragraphs: u32) Metrics {
        return .{
            .height = l.height,
            .lines = @intCast(l.lines.len),
            .width = l.width,
            .space_before = l.built.styles[0].space_before,
            .space_after = l.built.styles[paragraphs - 1].space_after,
        };
    }
};

/// One block's lines, shared like the block. Its metrics outlive its
/// lines, which go when its shaped block is evicted.
pub const LayoutBlock = struct {
    refs: u32 = 1,
    gpa: Allocator,
    shaped: *ShapedBlock,
    /// Null while not laid out yet or evicted.
    layout: ?Layout = null,
    /// What it is laid out with: its own copies of its paragraph runs
    /// (ends relative to it) and tab stops.
    options: layout_.Options,
    /// Whether `metrics` are its layout's (once laid out, for good).
    measured: bool = false,
    metrics: Metrics = .{},
    /// The next layout of its shaped block.
    sibling: ?*LayoutBlock = null,

    fn create(gpa: Allocator, shaped: *ShapedBlock, options: layout_.Options) error{OutOfMemory}!*LayoutBlock {
        const lb = try gpa.create(LayoutBlock);
        errdefer gpa.destroy(lb);
        var copy = options;
        copy.paragraphs = try gpa.dupe(ParagraphRun, options.paragraphs);
        errdefer gpa.free(copy.paragraphs);
        copy.tab_stops = try gpa.dupe(layout_.TabStop, options.tab_stops);
        lb.* = .{ .gpa = gpa, .shaped = shaped.retain(), .options = copy, .sibling = shaped.layouts };
        shaped.layouts = lb;
        return lb;
    }

    fn retain(b: *LayoutBlock) *LayoutBlock {
        b.refs += 1;
        return b;
    }

    fn release(b: *LayoutBlock) void {
        b.refs -= 1;
        if (b.refs != 0) return;
        const sb = b.shaped;
        var link = &sb.layouts;
        while (link.*.? != b) link = &link.*.?.sibling;
        link.* = b.sibling;
        if (b.layout) |*l| {
            l.deinit();
            sb.recount();
        }
        b.gpa.free(b.options.paragraphs);
        b.gpa.free(b.options.tab_stops);
        sb.release();
        b.gpa.destroy(b);
    }

    /// Its lines, laid out (again) if not in memory, from `from` (the
    /// old block's lines it was reshaped from) when given. `use`: counts
    /// as a use of its block.
    fn ensure(lb: *LayoutBlock, from: ?*const Layout, use: bool) error{OutOfMemory}!*Layout {
        if (lb.layout == null) {
            const sb = lb.shaped;
            const p = if (use) try sb.ensure() else if (sb.paragraph) |*p| p else try sb.ensure();
            var tmp: std.heap.ArenaAllocator = .init(lb.gpa);
            defer tmp.deinit();
            lb.layout = Layout.initReusing(sb.heavy(), tmp.allocator(), sb.cache, p, lb.options, from) catch |err| return oom(err);
            const m: Metrics = .of(&lb.layout.?, sb.paragraphs);
            // Laid out again, a block is what it was (D13).
            std.debug.assert(!lb.measured or std.meta.eql(m, lb.metrics));
            lb.metrics = m;
            lb.measured = true;
            sb.recount();
        } else if (use) lb.shaped.touch();
        return &lb.layout.?;
    }

    /// Estimated metrics: `per_byte` pixels a byte, lines of `line_height`,
    /// the space around it from its paragraph runs.
    fn estimate(lb: *LayoutBlock, per_byte: f64, line_height: f64) void {
        const text = lb.shaped.text;
        const h = per_byte * @as(f64, @floatFromInt(text.len));
        lb.metrics = .{
            .height = @floatCast(h),
            .lines = @max(1, @as(u32, @intFromFloat(@round(h / line_height)))),
            .space_before = runStyleAt(lb.options.paragraphs, 0).space_before,
            .space_after = runStyleAt(lb.options.paragraphs, @intCast(lastParagraphStart(text))).space_after,
        };
    }
};

/// The paragraph style of the paragraph starting at `start` (as
/// `Layout` resolves it).
fn runStyleAt(runs: []const ParagraphRun, start: u32) ParagraphStyle {
    var style: ParagraphStyle = for (runs) |run| {
        if (start < run.end) break run.style;
    } else if (runs.len != 0) runs[runs.len - 1].style else .{};
    if (!std.math.isFinite(style.space_before)) style.space_before = 0;
    if (!std.math.isFinite(style.space_after)) style.space_after = 0;
    return style;
}

/// An old layout's blocks, found by their shaped block: those an edit
/// kept at the start and the end pair up by index, the rest by a map.
const Reusable = struct {
    old: []const *LayoutBlock = &.{},
    /// Blocks `0..head` of both, and the last `tail` of each, are the
    /// same shaped blocks.
    head: usize = 0,
    tail: usize = 0,
    new_len: usize = 0,
    middle: std.AutoHashMapUnmanaged(*ShapedBlock, *LayoutBlock) = .empty,

    fn init(r: *Reusable, scratch: Allocator, old: []const *LayoutBlock, new: []const *ShapedBlock) error{OutOfMemory}!void {
        r.old = old;
        r.new_len = new.len;
        const m = @min(old.len, new.len);
        while (r.head < m and old[r.head].shaped == new[r.head]) r.head += 1;
        while (r.tail < m - r.head and old[old.len - 1 - r.tail].shaped == new[new.len - 1 - r.tail]) r.tail += 1;
        const rest = old[r.head .. old.len - r.tail];
        try r.middle.ensureTotalCapacity(scratch, @intCast(rest.len));
        for (rest) |lb| r.middle.putAssumeCapacity(lb.shaped, lb);
    }

    /// The old block of shaped block `sb`, the new text's block `i` or
    /// one it was reshaped from.
    fn get(r: *const Reusable, i: usize, sb: *ShapedBlock) ?*LayoutBlock {
        if (r.old.len == 0) return null;
        if (i < r.head and r.old[i].shaped == sb) return r.old[i];
        if (i >= r.new_len - r.tail) {
            const lb = r.old[r.old.len - (r.new_len - i)];
            if (lb.shaped == sb) return lb;
        }
        return r.middle.get(sb);
    }
};

/// Texts of up to this many blocks keep every block's positioned glyphs.
const eager_glyph_blocks = 4;

/// A `ShapedText` laid out for one width: its blocks' layouts stacked,
/// with the space between paragraphs between blocks. Blocks laid out with
/// estimated metrics are measured when a query reaches them (or by
/// `measure`), which moves the blocks after them: `generation` counts
/// such changes.
pub const TextLayout = struct {
    gpa: Allocator,
    shaped: *const ShapedText,
    blocks: []*LayoutBlock,
    /// Each block's top, in doubles: a long text's sums lose whole pixels
    /// in floats.
    tops: []f64,
    /// Index of each block's first line, and the line count last.
    line_starts: []u32,
    totals: *Totals,

    pub const Totals = struct {
        /// Widest measured line without hanging whitespace, with its indents.
        width: f32 = 0,
        height: f64 = 0,
        /// Blocks whose metrics are estimates.
        estimated: u32 = 0,
        /// Changes of metrics since it was built.
        generation: u32 = 0,
    };

    /// Lays out `shaped` (`Layout.init`'s options, with paragraph runs in
    /// the whole text's offsets), keeping `old`'s lines for blocks it
    /// shares with `old`'s text when the options are the same. With
    /// `estimate`, blocks whose shaping is not in memory get metrics
    /// estimated from the others' instead of being shaped now.
    pub fn init(gpa: Allocator, scratch: Allocator, shaped: *const ShapedText, options: layout_.Options, old: ?*const TextLayout, estimate: bool) !TextLayout {
        if (options.width) |w| if (!std.math.isFinite(w) or w < 0) return error.InvalidWidth;
        for (options.tab_stops) |stop| if (!std.math.isFinite(stop.position)) return error.InvalidWidth;
        const n = shaped.blocks.len;
        // Old blocks by their shaped block. An edit keeps the blocks before
        // and after it in order, so those pair up by walking both ends;
        // only the blocks between go in a map.
        var reusable: Reusable = .{};
        if (old) |o| try reusable.init(scratch, o.blocks, shaped.blocks);
        const blocks = try gpa.alloc(*LayoutBlock, n);
        var made: usize = 0;
        errdefer {
            for (blocks[0..made]) |b| b.release();
            gpa.free(blocks);
        }
        // Blocks that keep the estimate they had.
        const kept = try scratch.alloc(bool, n);
        @memset(kept, false);
        var run_index: usize = 0;
        const runs = options.paragraphs;
        for (shaped.blocks, 0..) |sb, i| {
            const s = shaped.starts[i];
            const e = shaped.starts[i + 1];
            const last = i + 1 == n;
            // Its paragraph runs: those covering s..e (and e itself for the
            // line after a final break).
            var local_buf: [4]ParagraphRun = undefined;
            var local: std.ArrayList(ParagraphRun) = .initBuffer(&local_buf);
            while (run_index + 1 < runs.len and runs[run_index].end <= s) run_index += 1;
            var k = run_index;
            while (k < runs.len) : (k += 1) {
                const run: ParagraphRun = .{ .end = @intCast(@min(runs[k].end, e) - @min(s, runs[k].end)), .style = runs[k].style };
                if (local.items.len == local.capacity) {
                    // More than a few runs: on to the scratch allocator.
                    var grown: std.ArrayList(ParagraphRun) = .empty;
                    try grown.ensureTotalCapacity(scratch, local.items.len * 4);
                    grown.appendSliceAssumeCapacity(local.items);
                    local = grown;
                }
                local.appendAssumeCapacity(run);
                if (runs[k].end > e or (runs[k].end == e and !last)) break;
            }
            var block_options = options;
            block_options.paragraphs = local.items;
            block_options.final_line = last;
            // Only painting reads positioned glyphs: a long text keeps
            // them for the blocks it paints (`withGlyphs`), and for a
            // block reshaped from one it painted.
            const from: ?*const Layout = if (sb.from) |f| (if (reusable.get(i, @constCast(f))) |o| (if (o.layout) |*l| l else null) else null) else null;
            block_options.glyphs = n <= eager_glyph_blocks or (if (from) |f| f.built.glyphs else false);
            if (reusable.get(i, sb)) |lb| if (compatible(lb, block_options)) {
                blocks[i] = lb.retain();
                kept[i] = !lb.measured;
                made += 1;
                continue;
            };
            const lb = try LayoutBlock.create(gpa, sb, block_options);
            blocks[i] = lb;
            made += 1;
            // A block reshaped from an old one keeps the old one's lines
            // for the paragraphs it kept.
            if (!estimate or sb.paragraph != null) _ = try lb.ensure(from, false);
        }
        // Estimates: the height per byte and line height of the measured
        // blocks (else of `old`).
        var measured_height: f64 = 0;
        var measured_bytes: f64 = 0;
        var measured_lines: f64 = 0;
        for (blocks) |lb| if (lb.measured) {
            measured_height += lb.metrics.height;
            measured_bytes += @floatFromInt(lb.shaped.text.len);
            measured_lines += @floatFromInt(lb.metrics.lines);
        };
        var per_byte: f64 = 0.25;
        var line_height: f64 = 20;
        if (measured_bytes > 0) {
            per_byte = measured_height / measured_bytes;
            if (measured_lines > 0 and measured_height > 0) line_height = measured_height / measured_lines;
        } else if (old) |o| if (o.shaped.len() > 0) {
            per_byte = o.totals.height / @as(f64, @floatFromInt(o.shaped.len()));
        };
        for (blocks, kept) |lb, keep| if (!lb.measured and !keep) lb.estimate(per_byte, line_height);

        const tops = try gpa.alloc(f64, n);
        errdefer gpa.free(tops);
        const line_starts = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(line_starts);
        const totals = try gpa.create(Totals);
        totals.* = .{};
        var self: TextLayout = .{ .gpa = gpa, .shaped = shaped, .blocks = blocks, .tops = tops, .line_starts = line_starts, .totals = totals };
        self.restack(0);
        totals.generation = 0;
        return self;
    }

    /// Stacks the blocks from `first` on again after their metrics changed.
    fn restack(self: *const TextLayout, first: usize) void {
        const blocks = self.blocks;
        var top: f64 = if (first == 0) 0 else self.tops[first - 1] + blocks[first - 1].metrics.height;
        var lines: u32 = if (first == 0) 0 else self.line_starts[first - 1] + blocks[first - 1].metrics.lines;
        for (blocks[first..], first..) |b, i| {
            if (i > 0) top += blocks[i - 1].metrics.space_after + b.metrics.space_before;
            self.tops[i] = top;
            self.line_starts[i] = lines;
            top += b.metrics.height;
            lines += b.metrics.lines;
        }
        self.line_starts[blocks.len] = lines;
        var widest: f32 = 0;
        var guesses: u32 = 0;
        for (blocks) |b| {
            if (b.measured) widest = @max(widest, b.metrics.width) else guesses += 1;
        }
        self.totals.* = .{ .width = widest, .height = top, .estimated = guesses, .generation = self.totals.generation +% 1 };
    }

    pub fn deinit(self: *TextLayout) void {
        for (self.blocks) |b| b.release();
        self.gpa.free(self.blocks);
        self.gpa.free(self.tops);
        self.gpa.free(self.line_starts);
        self.gpa.destroy(self.totals);
        self.* = undefined;
    }

    pub fn height(self: *const TextLayout) f32 {
        return @floatCast(self.totals.height);
    }

    pub fn width(self: *const TextLayout) f32 {
        return self.totals.width;
    }

    /// Whether some block's metrics are estimates.
    pub fn estimated(self: *const TextLayout) bool {
        return self.totals.estimated != 0;
    }

    pub fn generation(self: *const TextLayout) u32 {
        return self.totals.generation;
    }

    pub fn lineCount(self: *const TextLayout) u32 {
        return self.line_starts[self.line_starts.len - 1];
    }

    /// Block `b`'s lines, laid out if they are not in memory (measuring
    /// it if it was estimated, which moves the blocks after it).
    pub fn measure(self: *const TextLayout, b: u32) error{OutOfMemory}!*const Layout {
        const lb = self.blocks[b];
        const was = lb.measured;
        const l = try lb.ensure(null, true);
        if (!was) self.restack(b);
        return l;
    }

    /// Measures the estimated blocks whose shaping is in memory (installed
    /// from another thread). Whether any was.
    pub fn measureShaped(self: *const TextLayout) error{OutOfMemory}!bool {
        var first: ?usize = null;
        for (self.blocks, 0..) |lb, i| if (!lb.measured and lb.shaped.paragraph != null) {
            _ = try lb.ensure(null, false);
            if (first == null) first = i;
        };
        if (first) |f| self.restack(f);
        return first != null;
    }

    /// Block `b`'s layout with its positioned glyphs, laid out again
    /// (the same lines) if it was built without them.
    pub fn withGlyphs(self: *const TextLayout, scratch: Allocator, b: u32) error{OutOfMemory}!*const Layout {
        const lb = self.blocks[b];
        const l = try self.measure(b);
        if (l.built.glyphs) return l;
        var options = lb.options;
        options.glyphs = true;
        const again = Layout.init(lb.shaped.heavy(), scratch, lb.shaped.cache, &lb.shaped.paragraph.?, options) catch |err| return oom(err);
        lb.layout.?.deinit();
        lb.layout = again;
        lb.shaped.recount();
        return &lb.layout.?;
    }

    /// Frees the positioned glyphs of a long text's blocks outside
    /// `first..end`.
    pub fn dropGlyphs(self: *const TextLayout, first: u32, end: u32) void {
        if (self.blocks.len <= eager_glyph_blocks) return;
        for (self.blocks, 0..) |lb, i| if (i < first or i >= end) if (lb.layout) |*l| if (l.built.glyphs) {
            l.dropGlyphs();
            lb.shaped.recount();
        };
    }

    fn compatible(lb: *const LayoutBlock, options: layout_.Options) bool {
        const b = lb.options;
        if (b.width != options.width or b.alignment != options.alignment or b.break_words != options.break_words or b.hyphenate != options.hyphenate or
            b.hyphenation != options.hyphenation or b.optimal != options.optimal or b.final_line != options.final_line or b.tab_stops.len != options.tab_stops.len) return false;
        for (b.tab_stops, options.tab_stops) |x, y| if (!std.meta.eql(x, y)) return false;
        if (b.paragraphs.len != options.paragraphs.len) return false;
        for (b.paragraphs, options.paragraphs) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    /// The block holding line `index` (by the current metrics).
    pub fn blockOfLine(self: *const TextLayout, index: u32) u32 {
        var low: usize = 0;
        var high: usize = self.blocks.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.line_starts[middle + 1] <= index) low = middle + 1 else high = middle;
        }
        return @intCast(@min(low, self.blocks.len - 1));
    }

    /// The measured block holding line `index`, measuring blocks until
    /// the one it falls in is (its index may move as they are).
    fn measuredBlockOfLine(self: *const TextLayout, index: u32) error{OutOfMemory}!u32 {
        while (true) {
            const b = self.blockOfLine(index);
            if (self.blocks[b].measured) return b;
            _ = try self.measure(b);
        }
    }

    /// Line `index` in the whole text's offsets and coordinates (its run
    /// and caret ranges stay its block's).
    pub fn line(self: *const TextLayout, index: u32) error{OutOfMemory}!Line {
        const b = try self.measuredBlockOfLine(index);
        const l = try self.measure(b);
        const local = @min(index - self.line_starts[b], @as(u32, @intCast(l.lines.len - 1)));
        return self.globalLine(b, l.lines[local]);
    }

    /// A line of block `b` in the whole text's offsets and coordinates.
    pub fn globalLine(self: *const TextLayout, b: u32, block_line: Line) Line {
        var l = block_line;
        const s = self.shaped.starts[b];
        l.start += s;
        l.end += s;
        l.paragraph += self.shaped.paragraph_starts[b];
        l.top = @floatCast(self.tops[b] + l.top);
        l.baseline = @floatCast(self.tops[b] + l.baseline);
        return l;
    }

    /// The last block whose top is at or above `y` (the first above them
    /// all), by the current metrics.
    pub fn blockAtY(self: *const TextLayout, y: f64) u32 {
        var low: usize = 0;
        var high: usize = self.blocks.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.tops[middle] <= y) low = middle + 1 else high = middle;
        }
        return @intCast(low -| 1);
    }

    /// The measured block at `y`, measuring blocks until the one it falls
    /// in is.
    fn measuredBlockAtY(self: *const TextLayout, y: f64) error{OutOfMemory}!u32 {
        while (true) {
            const b = self.blockAtY(y);
            if (self.blocks[b].measured) return b;
            _ = try self.measure(b);
        }
    }

    /// The line at vertical position `y` (clamped to the first and last line).
    pub fn lineAt(self: *const TextLayout, y: f32) error{OutOfMemory}!u32 {
        const b = try self.measuredBlockAtY(y);
        const l = try self.measure(b);
        return self.line_starts[b] + l.lineAt(@floatCast(y - self.tops[b]));
    }

    fn toBlock(self: *const TextLayout, position: Position) struct { u32, Position } {
        const b = self.shaped.blockAt(position.offset);
        return .{ b, .{ .offset = position.offset - self.shaped.starts[b], .affinity = position.affinity } };
    }

    fn global(self: *const TextLayout, b: u32, position: Position) Position {
        return .{ .offset = position.offset + self.shaped.starts[b], .affinity = position.affinity };
    }

    pub fn caret(self: *const TextLayout, position: Position) error{OutOfMemory}!CaretRect {
        const b, const p = self.toBlock(position);
        const c = (try self.measure(b)).caret(p);
        return .{ .line = self.line_starts[b] + c.line, .x = c.x, .top = @floatCast(self.tops[b] + c.top), .height = c.height };
    }

    /// The caret position closest to a point relative to the layout origin.
    pub fn hitTest(self: *const TextLayout, x: f32, y: f32) error{OutOfMemory}!Position {
        const b = try self.measuredBlockAtY(y);
        const l = try self.measure(b);
        return self.global(b, l.hitTest(x, @floatCast(y - self.tops[b])));
    }

    pub fn nextGrapheme(self: *const TextLayout, offset: u32) error{OutOfMemory}!u32 {
        return self.shaped.nextGrapheme(offset);
    }

    pub fn previousGrapheme(self: *const TextLayout, offset: u32) error{OutOfMemory}!u32 {
        return self.shaped.previousGrapheme(offset);
    }

    pub fn nextWordEnd(self: *const TextLayout, offset: u32) error{OutOfMemory}!u32 {
        return self.shaped.nextWordEnd(offset);
    }

    pub fn previousWordStart(self: *const TextLayout, offset: u32) error{OutOfMemory}!u32 {
        return self.shaped.previousWordStart(offset);
    }

    /// Visual movement by one grapheme edge (`cursor.moveVisual`): past a
    /// block's first or last line it continues in the next block.
    pub fn moveVisual(self: *const TextLayout, position: Position, direction: cursor.Direction) error{OutOfMemory}!Position {
        const b, const p = self.toBlock(position);
        const l = try self.measure(b);
        const moved = l.moveVisual(p, direction);
        const from = l.caret(p);
        const forward = (direction == .right) != l.lines[from.line].rtl();
        const edge = if (forward) from.line + 1 == l.lines.len and b + 1 < self.blocks.len else from.line == 0 and b > 0;
        if (edge) {
            const to = l.caret(moved);
            if (to.line == from.line and @abs(to.x - from.x) <= 0.001) {
                if (forward) return self.global(b + 1, (try self.measure(b + 1)).lineEdge(0, .start));
                const prev = try self.measure(b - 1);
                return self.global(b - 1, prev.lineEdge(@intCast(prev.lines.len - 1), .end));
            }
        }
        return self.global(b, moved);
    }

    /// The start or end of the position's line in reading order.
    pub fn lineBoundary(self: *const TextLayout, position: Position, boundary: cursor.Boundary) error{OutOfMemory}!Position {
        const b, const p = self.toBlock(position);
        return self.global(b, (try self.measure(b)).lineBoundary(p, boundary));
    }

    /// Moves to the adjacent line at the preferred x (`cursor.moveVertical`).
    pub fn moveVertical(self: *const TextLayout, position: Position, preferred_x: ?f32, direction: cursor.Vertical) error{OutOfMemory}!cursor.VerticalMove {
        const b, const p = self.toBlock(position);
        const l = try self.measure(b);
        const from = l.caret(p);
        const target: ?u32 = switch (direction) {
            .up => if (from.line == 0 and b > 0) b - 1 else null,
            .down => if (from.line + 1 == l.lines.len and b + 1 < self.blocks.len) b + 1 else null,
        };
        if (target) |t| {
            const x = preferred_x orelse from.x;
            const tl = try self.measure(t);
            const target_line = if (direction == .up) tl.lines[tl.lines.len - 1] else tl.lines[0];
            const stops = tl.lineCarets(target_line);
            const index = cursor.nearest(stops, x - target_line.x);
            return .{ .position = self.global(t, .{ .offset = stops[index].offset, .affinity = stops[index].affinity }), .x = x };
        }
        const m = l.moveVertical(p, preferred_x, direction);
        return .{ .position = self.global(b, m.position), .x = m.x };
    }

    /// Appends rectangles covering the graphemes in `start..end`
    /// (`cursor.selectionRects`); with `band`, only those of blocks that
    /// reach into it (a selection of a long text, painted).
    pub fn selectionRects(self: *const TextLayout, gpa: Allocator, start: u32, end: u32, out: *std.ArrayList(Rect), band: ?[2]f32) error{OutOfMemory}!void {
        if (start >= end) return;
        var b = self.shaped.blockAt(start);
        if (band) |bd| b = @max(b, self.blockAtY(bd[0]));
        while (b < self.blocks.len and self.shaped.starts[b] < end) : (b += 1) {
            if (band) |bd| if (self.tops[b] > bd[1]) break;
            const s = self.shaped.starts[b];
            const e = self.shaped.starts[b + 1];
            const first = out.items.len;
            try (try self.measure(b)).selectionRects(gpa, @max(start, s) - s, @min(end, e) - s, out);
            for (out.items[first..]) |*r| r.y = @floatCast(self.tops[b] + r.y);
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

/// Compares every query of `text` with `flat`'s, in an order that reaches
/// blocks before their lines are needed; with `residency`, trimmed after
/// each offset, so that blocks are evicted and built again between
/// queries. The totals are compared last, when every block is measured.
fn expectSameLayout(flat: *const Layout, text: *const TextLayout, gpa: Allocator, residency: ?*Residency) !void {
    const t = std.testing;
    const len: u32 = @intCast(flat.paragraph.text.len);
    for (0..len + 1) |o_| {
        const o: u32 = @intCast(o_);
        for ([_]layout_.Affinity{ .downstream, .upstream }) |aff| {
            const pos: Position = .{ .offset = o, .affinity = aff };
            const fc = flat.caret(pos);
            const tc = try text.caret(pos);
            try t.expectEqual(fc.line, tc.line);
            try t.expectApproxEqAbs(fc.x, tc.x, 0.01);
            try t.expectApproxEqAbs(fc.top, tc.top, 0.01);
            for ([_]cursor.Direction{ .left, .right }) |d| try t.expectEqual(flat.moveVisual(pos, d), try text.moveVisual(pos, d));
            for ([_]cursor.Boundary{ .start, .end }) |bd| try t.expectEqual(flat.lineBoundary(pos, bd), try text.lineBoundary(pos, bd));
            for ([_]cursor.Vertical{ .up, .down }) |v| {
                try t.expectEqual(flat.moveVertical(pos, null, v), try text.moveVertical(pos, null, v));
                try t.expectEqual(flat.moveVertical(pos, 13, v), try text.moveVertical(pos, 13, v));
            }
        }
        try t.expectEqual(flat.nextGrapheme(o), try text.nextGrapheme(o));
        try t.expectEqual(flat.previousGrapheme(o), try text.previousGrapheme(o));
        try t.expectEqual(flat.nextWordEnd(o), try text.nextWordEnd(o));
        try t.expectEqual(flat.previousWordStart(o), try text.previousWordStart(o));
        const p = flat.paragraph.paragraphs[flat.paragraph.paragraphAt(o)];
        try t.expectEqual([2]u32{ p.start, p.contentEnd() }, try text.shaped.paragraphRange(o));
        const words = flat.paragraph.words.boundaries;
        var ws = words.atOrBefore(o) orelse 0;
        if (ws == len and len > 0) ws = words.before(len) orelse 0;
        try t.expectEqual([2]u32{ ws, words.after(ws) orelse len }, try text.shaped.wordAt(o));
        if (residency) |r| r.trim();
    }
    // Every block has been measured: the totals are exact.
    try t.expect(!text.estimated());
    try t.expectEqual(@as(u32, @intCast(flat.lines.len)), text.lineCount());
    try t.expectApproxEqAbs(flat.height, text.height(), 0.01);
    try t.expectApproxEqAbs(flat.width, text.width(), 0.01);
    for (flat.lines, 0..) |fl, i| {
        const l = try text.line(@intCast(i));
        try t.expectEqual(fl.start, l.start);
        try t.expectEqual(fl.end, l.end);
        try t.expectEqual(fl.paragraph, l.paragraph);
        try t.expectApproxEqAbs(fl.top, l.top, 0.01);
        try t.expectApproxEqAbs(fl.baseline, l.baseline, 0.01);
        try t.expectApproxEqAbs(fl.width, l.width, 0.01);
        try t.expectApproxEqAbs(fl.height, l.height, 0.01);
        if (residency) |r| if (i % 3 == 0) r.trim();
    }
    var y: f32 = -5;
    while (y < flat.height + 10) : (y += 3.7) {
        try t.expectEqual(flat.lineAt(y), try text.lineAt(y));
        var x: f32 = -5;
        while (x < 300) : (x += 11.3) try t.expectEqual(flat.hitTest(x, y), try text.hitTest(x, y));
        if (residency) |r| r.trim();
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
        try text.selectionRects(gpa, s, e, &b, null);
        // Rectangles of one line that meet across a block boundary stay
        // apart: compare the area they cover per line.
        try t.expectApproxEqAbs(coverage(a.items), coverage(b.items), 0.05);
        if (residency) |r| r.trim();
    }
}

fn coverage(rects: []const Rect) f32 {
    var sum: f32 = 0;
    for (rects) |r| sum += r.width * r.height + r.y * 0.001 * r.width;
    return sum;
}

/// How a test builds a text: everything kept and laid out, or with a
/// residency far too small for it, only some blocks shaped at first, and
/// the others estimated until measured.
const Mode = enum {
    keep,
    bounded,

    fn options(m: Mode, block_bytes: u32, residency: *Residency) Options {
        return switch (m) {
            .keep => .{ .block_bytes = block_bytes },
            .bounded => .{ .block_bytes = block_bytes, .eager_bytes = block_bytes, .residency = residency },
        };
    }

    fn estimate(m: Mode) bool {
        return m == .bounded;
    }
};

test "paragraphEnd finds UAX #9's paragraph separators" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var prng: std.Random.DefaultPrng = .init(7);
    const a = fixture.arena.allocator();
    for (0..40) |_| {
        var buf: std.ArrayList(u8) = .empty;
        // Long words too, so that the 16-byte skip runs.
        try randomText(prng.random(), &buf, a, 6);
        if (prng.random().boolean()) try buf.insertSlice(a, buf.items.len / 2, "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz");
        const analysis = try bidi.analyze(a, buf.items, .auto_ltr);
        var at: usize = 0;
        for (analysis.paragraphs) |p| {
            try std.testing.expectEqual(@as(usize, p.start), at);
            at = paragraphEnd(buf.items, at, buf.items.len);
            try std.testing.expectEqual(@as(usize, p.end), at);
        }
        try std.testing.expectEqual(@as(u32, @intCast(analysis.paragraphs.len)), countParagraphs(buf.items));
        try std.testing.expectEqual(@as(usize, analysis.paragraphs[analysis.paragraphs.len - 1].start), lastParagraphStart(buf.items));
        // Block ends found by skipping ahead are those found by walking
        // paragraph by paragraph.
        for ([_]u32{ 1, 3, 7, 16, 40 }) |bb| {
            var s: usize = 0;
            while (s < buf.items.len) {
                var e = s;
                while (e < buf.items.len) {
                    e = paragraphEnd(buf.items, e, buf.items.len);
                    if (e - s >= bb) break;
                }
                try std.testing.expectEqual(e, blockEnd(buf.items, s, buf.items.len, .{ .block_bytes = bb }));
                s = e;
            }
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
    var residency: Residency = .init(gpa, 0);
    defer residency.deinit();
    for (0..24) |round| {
        const mode: Mode = if (round % 2 == 0) .keep else .bounded;
        const a = fixture.arena.allocator();
        var buf: std.ArrayList(u8) = .empty;
        try randomText(rand, &buf, a, 1 + rand.uintLessThan(usize, 9));
        const styles = [_]StyleRun{.{ .end = @intCast(buf.items.len), .style = style }};
        const spacing: layout_.ParagraphStyle = .{ .space_before = 3, .space_after = 5, .line_spacing = 1.25 };
        const options: layout_.Options = .{ .width = 90 + @as(f32, @floatFromInt(round)) * 3, .paragraphs = &.{.{ .end = std.math.maxInt(u32), .style = spacing }} };
        var flat_p = try ShapedParagraph.init(gpa, a, &fixture.cache, buf.items, &styles, .auto_ltr);
        defer flat_p.deinit();
        var flat = try Layout.init(gpa, a, &fixture.cache, &flat_p, options);
        defer flat.deinit();
        var shaped = try ShapedText.init(gpa, a, &fixture.cache, buf.items, &styles, .auto_ltr, mode.options(1 + rand.uintLessThan(u32, 40), &residency));
        defer shaped.deinit();
        var text = try TextLayout.init(gpa, a, &shaped, options, null, mode.estimate());
        defer text.deinit();
        try expectSameLayout(&flat, &text, gpa, if (mode == .bounded) &residency else null);
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
    const options: layout_.Options = .{ .width = 120 };
    var residency: Residency = .init(gpa, 0);
    defer residency.deinit();
    for (0..30) |round| {
        const mode: Mode = if (round % 2 == 0) .keep else .bounded;
        const block_options = mode.options(24, &residency);
        const a = fixture.arena.allocator();
        var buf: std.ArrayList(u8) = .empty;
        try randomText(rand, &buf, a, 2 + rand.uintLessThan(usize, 8));
        var shaped = try ShapedText.init(gpa, a, &fixture.cache, buf.items, &.{.{ .end = @intCast(buf.items.len), .style = style }}, .auto_ltr, block_options);
        defer shaped.deinit();
        var text = try TextLayout.init(gpa, a, &shaped, options, null, mode.estimate());
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
            const relaid = TextLayout.init(gpa, a, &reshaped, options, &text, mode.estimate()) catch |err| {
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
                try concatenated.appendSlice(a, b.text);
                if (i + 1 < shaped.blocks.len) try std.testing.expect(endsWithSeparator(b.text));
            }
            try std.testing.expectEqualStrings(buf.items, concatenated.items);
            try expectSameLayout(&flat, &text, gpa, if (mode == .bounded) &residency else null);
        }
    }
}

test "edits to a rope, with what changed given, build what shaping the new text does" {
    // Texts longer than a rope leaf, so that blocks are read from the
    // rope; several edits between builds; the change from the ropes, not
    // from comparing bytes. Against one paragraph of the new text, and
    // against the blocks the comparing path builds.
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const fonts = [_]FontId{ fixture.latin, fixture.arabic, fixture.hebrew };
    const style: Style = .{ .fonts = &fonts, .size = 16 };
    var prng: std.Random.DefaultPrng = .init(53);
    const rand = prng.random();
    const inserts = [_][]const u8{ "q", "\n", "\r", "\r\n", "א", " ", "zz\u{2029}y", "", "wwwwwwww wwwwwwww\n" };
    var residency: Residency = .init(gpa, 20_000);
    defer residency.deinit();
    const options: layout_.Options = .{ .width = 150 };
    for (0..4) |round| {
        const a = fixture.arena.allocator();
        var buf: std.ArrayList(u8) = .empty;
        try randomText(rand, &buf, a, 170 + rand.uintLessThan(usize, 30));
        try std.testing.expect(buf.items.len > @import("rope.zig").leaf_max);
        var rope = try Rope.initBytes(gpa, buf.items);
        defer rope.release(gpa);
        const bounded = round % 2 == 1;
        const block_options: Options = if (bounded) .{ .block_bytes = 64 + rand.uintLessThan(u32, 400), .eager_bytes = 256, .residency = &residency } else .{ .block_bytes = 64 + rand.uintLessThan(u32, 400) };
        var shaped = try ShapedText.initFrom(gpa, a, &fixture.cache, .ofRope(rope), &.{.{ .end = @intCast(buf.items.len), .style = style }}, .auto_ltr, block_options);
        defer shaped.deinit();
        var text = try TextLayout.init(gpa, a, &shaped, options, null, bounded);
        defer text.deinit();
        for (0..3) |edit| {
            var next = rope.retain();
            defer next.release(gpa);
            for (0..1 + rand.uintLessThan(usize, 3)) |_| {
                const len = next.len();
                var start = rand.uintAtMost(usize, len);
                while (start > 0 and start < len and next.byteAt(start) & 0xc0 == 0x80) start -= 1;
                var end = @min(len, start + rand.uintLessThan(usize, 12));
                while (end < len and next.byteAt(end) & 0xc0 == 0x80) end += 1;
                const edited = try next.replace(gpa, start, end, inserts[rand.uintLessThan(usize, inserts.len)]);
                next.release(gpa);
                next = edited;
            }
            const change: Change = .{ .prefix = Rope.commonPrefix(rope, next), .suffix = Rope.commonSuffix(rope, next) };
            const bytes = try next.toOwned(a);
            const styles = [_]StyleRun{.{ .end = @intCast(bytes.len), .style = style }};
            var reshaped = try ShapedText.initEdit(gpa, a, &fixture.cache, .ofRope(next), &styles, .auto_ltr, block_options, &shaped, change);
            // The same blocks as comparing the bytes finds.
            var compared = try ShapedText.initReusing(gpa, a, &fixture.cache, bytes, &styles, .auto_ltr, block_options, &shaped);
            defer compared.deinit();
            try std.testing.expectEqualSlices(u32, compared.starts, reshaped.starts);
            for (compared.blocks, reshaped.blocks) |x, y| try std.testing.expectEqualStrings(x.text, y.text);
            const relaid = TextLayout.init(gpa, a, &reshaped, options, &text, bounded) catch |err| {
                reshaped.deinit();
                return err;
            };
            text.deinit();
            shaped.deinit();
            shaped = reshaped;
            text = relaid;
            text.shaped = &shaped;
            rope.release(gpa);
            rope = next.retain();
            // Each edit's blocks match the comparing path's above; the
            // layout, reused through every edit, is checked after the last.
            if (edit < 2) continue;
            var flat_p = try ShapedParagraph.init(gpa, a, &fixture.cache, bytes, &styles, .auto_ltr);
            defer flat_p.deinit();
            var flat = try Layout.init(gpa, a, &fixture.cache, &flat_p, options);
            defer flat.deinit();
            try expectSameLayout(&flat, &text, gpa, if (bounded) &residency else null);
        }
    }
}

test "evicted blocks are built again as they were, across edits" {
    // A bounded text against the same text with everything kept, block by
    // block: lines, carets, glyphs, and metrics, with blocks evicted and
    // built again in random order between edits, measurements, and trims.
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const fonts = [_]FontId{ fixture.latin, fixture.arabic, fixture.hebrew };
    const style: Style = .{ .fonts = &fonts, .size = 16 };
    var prng: std.Random.DefaultPrng = .init(41);
    const rand = prng.random();
    const inserts = [_][]const u8{ "q", "\n", "\r\n", "א", " ", "zz\u{2029}y", "", "wwwwwwww wwwwwwww\n" };
    var residency: Residency = .init(gpa, 0);
    defer residency.deinit();
    for (0..12) |round| {
        const a = fixture.arena.allocator();
        residency.budget = rand.uintLessThan(usize, 40_000);
        const spacing: layout_.ParagraphStyle = .{ .space_before = 2, .space_after = 3 };
        const options: layout_.Options = .{ .width = 80 + @as(f32, @floatFromInt(round)) * 4, .paragraphs = &.{.{ .end = std.math.maxInt(u32), .style = spacing }} };
        const block_bytes = 8 + rand.uintLessThan(u32, 40);
        var buf: std.ArrayList(u8) = .empty;
        try randomText(rand, &buf, a, 8 + rand.uintLessThan(usize, 16));
        var kept_s = try ShapedText.init(gpa, a, &fixture.cache, buf.items, &.{.{ .end = @intCast(buf.items.len), .style = style }}, .auto_ltr, .{ .block_bytes = block_bytes });
        defer kept_s.deinit();
        var kept = try TextLayout.init(gpa, a, &kept_s, options, null, false);
        defer kept.deinit();
        const bounded_options: Options = .{ .block_bytes = block_bytes, .eager_bytes = rand.uintLessThan(u32, 64), .residency = &residency };
        var bounded_s = try ShapedText.init(gpa, a, &fixture.cache, buf.items, &.{.{ .end = @intCast(buf.items.len), .style = style }}, .auto_ltr, bounded_options);
        defer bounded_s.deinit();
        var bounded = try TextLayout.init(gpa, a, &bounded_s, options, null, true);
        defer bounded.deinit();
        for (0..3) |_| {
            try std.testing.expectEqualSlices(u32, kept_s.starts, bounded_s.starts);
            try std.testing.expectEqualSlices(u32, kept_s.paragraph_starts, bounded_s.paragraph_starts);
            const n: u32 = @intCast(kept.blocks.len);
            // Blocks in random order, each compared whole.
            for (0..2 * n) |_| {
                const b = rand.uintLessThan(u32, n);
                const want = try kept.measure(b);
                const got = try bounded.measure(b);
                try std.testing.expectEqualSlices(Line, want.lines, got.lines);
                try std.testing.expectEqualSlices(layout_.Caret, want.carets, got.carets);
                try std.testing.expectEqual(kept.blocks[b].metrics, bounded.blocks[b].metrics);
                if (rand.uintLessThan(u8, 4) == 0) {
                    const wg = try kept.withGlyphs(a, b);
                    const gg = try bounded.withGlyphs(a, b);
                    try std.testing.expectEqualSlices(layout_.PositionedGlyph, wg.glyphs, gg.glyphs);
                }
                // The tops of measured blocks agree with the kept text's
                // when every block before them is measured.
                if (for (bounded.blocks[0..b]) |lb| {
                    if (!lb.measured) break false;
                } else true) try std.testing.expectEqual(kept.tops[b], bounded.tops[b]);
                if (rand.boolean()) residency.trim();
            }
            // Queries at random offsets and points.
            const len = bounded_s.len();
            for (0..20) |_| {
                const pos: Position = .{ .offset = rand.uintAtMost(u32, len), .affinity = if (rand.boolean()) .upstream else .downstream };
                if (pos.offset < len and buf.items[pos.offset] & 0xc0 == 0x80) continue;
                try std.testing.expectEqual(try kept.moveVertical(pos, null, .down), try bounded.moveVertical(pos, null, .down));
                try std.testing.expectEqual(try kept.moveVisual(pos, .left), try bounded.moveVisual(pos, .left));
                try std.testing.expectEqual(try kept.nextWordEnd(pos.offset), try bounded.nextWordEnd(pos.offset));
                // Lines and tops count estimates before them until those
                // are measured; within the block they agree.
                const kc = try kept.caret(pos);
                const bc = try bounded.caret(pos);
                const blk = bounded_s.blockAt(pos.offset);
                try std.testing.expectEqual(kc.x, bc.x);
                try std.testing.expectEqual(kc.height, bc.height);
                try std.testing.expectEqual(kc.line - kept.line_starts[blk], bc.line - bounded.line_starts[blk]);
                if (for (bounded.blocks[0..blk]) |lb| {
                    if (!lb.measured) break false;
                } else true) try std.testing.expectEqual(kc, bc);
                residency.trim();
            }
            // Every block measured: the same totals, and the residency
            // back within its budget once nothing is in use.
            for (0..n) |b| _ = try bounded.measure(@intCast(b));
            try std.testing.expectEqual(kept.height(), bounded.height());
            try std.testing.expectEqual(kept.lineCount(), bounded.lineCount());
            try std.testing.expectEqualSlices(f64, kept.tops, bounded.tops);
            residency.trim();
            residency.trim();
            var pinned: usize = 0;
            var it = residency.head;
            while (it) |sb| : (it = sb.next) if (sb.pinned) {
                pinned += sb.bytes;
            };
            try std.testing.expect(residency.bytes <= residency.budget + pinned);

            // An edit, applied to both.
            var start = rand.uintAtMost(usize, buf.items.len);
            while (start > 0 and start < buf.items.len and buf.items[start] & 0xc0 == 0x80) start -= 1;
            var end = @min(buf.items.len, start + rand.uintLessThan(usize, 12));
            while (end < buf.items.len and buf.items[end] & 0xc0 == 0x80) end += 1;
            var next: std.ArrayList(u8) = .empty;
            try next.appendSlice(a, buf.items[0..start]);
            try next.appendSlice(a, inserts[rand.uintLessThan(usize, inserts.len)]);
            try next.appendSlice(a, buf.items[end..]);
            buf = next;
            const styles = [_]StyleRun{.{ .end = @intCast(buf.items.len), .style = style }};
            inline for (.{ .{ &kept_s, &kept, Options{ .block_bytes = block_bytes }, false }, .{ &bounded_s, &bounded, bounded_options, true } }) |pair| {
                var reshaped = try ShapedText.initReusing(gpa, a, &fixture.cache, buf.items, &styles, .auto_ltr, pair[2], pair[0]);
                const relaid = TextLayout.init(gpa, a, &reshaped, options, pair[1], pair[3]) catch |err| {
                    reshaped.deinit();
                    return err;
                };
                pair[1].deinit();
                pair[0].deinit();
                pair[0].* = reshaped;
                pair[1].* = relaid;
                pair[1].shaped = pair[0];
            }
            if (rand.boolean()) residency.trim();
        }
    }
    try std.testing.expect(residency.evictions > 0 and residency.shapes > 0);
}

test "a text shaped from its first blocks, the rest installed from elsewhere, equals shaping it whole" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const fonts = [_]FontId{ fixture.latin, fixture.arabic, fixture.hebrew };
    var prng: std.Random.DefaultPrng = .init(31);
    const rand = prng.random();
    const options: layout_.Options = .{ .width = 110 };
    var residency: Residency = .init(gpa, 1 << 30);
    defer residency.deinit();
    for (0..30) |_| {
        const a = fixture.arena.allocator();
        var buf: std.ArrayList(u8) = .empty;
        try randomText(rand, &buf, a, 4 + rand.uintLessThan(usize, 8));
        // Two sizes, so blocks start in different styles.
        var cut: u32 = @intCast(rand.uintAtMost(usize, buf.items.len));
        while (cut > 0 and cut < buf.items.len and buf.items[cut] & 0xc0 == 0x80) cut -= 1;
        const styles = [_]StyleRun{
            .{ .end = cut, .style = .{ .fonts = &fonts, .size = 16 } },
            .{ .end = @intCast(buf.items.len), .style = .{ .fonts = &fonts, .size = 11 } },
        };
        const all = if (cut == 0) styles[1..] else styles[0..];
        var whole = try ShapedText.init(gpa, a, &fixture.cache, buf.items, all, .auto_ltr, .{ .block_bytes = 24 });
        defer whole.deinit();
        if (whole.blocks.len < 3) continue;
        var flat_p = try ShapedParagraph.init(gpa, a, &fixture.cache, buf.items, all, .auto_ltr);
        defer flat_p.deinit();
        var flat = try Layout.init(gpa, a, &fixture.cache, &flat_p, options);
        defer flat.deinit();

        // The first block at once, the rest estimated.
        var shaped = try ShapedText.init(gpa, a, &fixture.cache, buf.items, all, .auto_ltr, .{ .block_bytes = 24, .eager_bytes = 1, .residency = &residency });
        defer shaped.deinit();
        try std.testing.expectEqualSlices(u32, whole.starts, shaped.starts);
        try std.testing.expectEqualSlices(u32, whole.style_firsts, shaped.style_firsts);
        try std.testing.expectEqualSlices(u32, whole.paragraph_starts, shaped.paragraph_starts);
        try std.testing.expect(shaped.blocks[0].paragraph != null and shaped.blocks[1].paragraph == null);
        var text = try TextLayout.init(gpa, a, &shaped, options, null, true);
        defer text.deinit();
        try std.testing.expect(text.estimated() and text.blocks[0].measured and !text.blocks[1].measured);
        // The rest shaped "elsewhere" and installed in two steps; one
        // block twice, the second copy thrown away.
        const middle = shaped.blocks.len / 2;
        for ([_][2]usize{ .{ 1, middle + 1 }, .{ middle, shaped.blocks.len } }) |range| {
            for (shaped.blocks[range[0]..range[1]]) |b| b.install(try b.shapeAlone());
            try std.testing.expect(try text.measureShaped());
        }
        try std.testing.expect(!text.estimated());
        for (whole.blocks, shaped.blocks) |x, y| try std.testing.expectEqual(x.paragraph.?.glyphs.len, y.paragraph.?.glyphs.len);
        try expectSameLayout(&flat, &text, gpa, null);
        // A long text's blocks are laid out without positioned glyphs
        // until painted; laid out again with them, the lines are the same.
        const lazy = shaped.blocks.len > eager_glyph_blocks;
        try std.testing.expectEqual(lazy, !text.blocks[text.blocks.len - 1].layout.?.built.glyphs);
        for (text.blocks, 0..) |lb, b| {
            try std.testing.expect(lazy or lb.layout.?.built.glyphs);
            const lines = try a.dupe(Line, lb.layout.?.lines);
            const l = try text.withGlyphs(a, @intCast(b));
            try std.testing.expectEqualSlices(Line, lines, l.lines);
            var options_ = lb.options;
            options_.glyphs = true;
            var eager = try Layout.init(gpa, a, &fixture.cache, &lb.shaped.paragraph.?, options_);
            defer eager.deinit();
            try std.testing.expectEqualSlices(layout_.PositionedGlyph, eager.glyphs, l.glyphs);
        }
        text.dropGlyphs(1, 2);
        for (text.blocks, 0..) |lb, b| try std.testing.expectEqual(!lazy or b == 1, lb.layout.?.built.glyphs);
    }
}

test "estimates move only the blocks after a measured one" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const a = fixture.arena.allocator();
    const fonts = [_]FontId{fixture.latin};
    var buf: std.ArrayList(u8) = .empty;
    // Short paragraphs first, then long ones, so the estimate is wrong.
    for (0..40) |i| try buf.print(a, "{d}\n", .{i});
    for (0..40) |_| {
        for (0..12) |_| try buf.appendSlice(a, "wwwwwwww ");
        try buf.append(a, '\n');
    }
    var residency: Residency = .init(gpa, 0);
    defer residency.deinit();
    var shaped = try ShapedText.init(gpa, a, &fixture.cache, buf.items, &.{.{ .end = @intCast(buf.items.len), .style = .{ .fonts = &fonts, .size = 16 } }}, .auto_ltr, .{ .block_bytes = 64, .eager_bytes = 64, .residency = &residency });
    defer shaped.deinit();
    var text = try TextLayout.init(gpa, a, &shaped, .{ .width = 200 }, null, true);
    defer text.deinit();
    const n = text.blocks.len;
    const last = n - 1;
    const tops = try a.dupe(f64, text.tops);
    const g = text.generation();
    // Measuring the last block moves nothing before it.
    _ = try text.measure(@intCast(last));
    try std.testing.expectEqualSlices(f64, tops, text.tops);
    try std.testing.expect(text.generation() != g);
    // Measuring a middle block moves only the blocks after it.
    const mid = n / 2;
    _ = try text.measure(@intCast(mid));
    try std.testing.expectEqualSlices(f64, tops[0 .. mid + 1], text.tops[0 .. mid + 1]);
    try std.testing.expect(text.tops[last] != tops[last]);
    // A hit test far down measures the block it lands in, wherever the
    // estimate put it.
    const y = text.height() - 1;
    const pos = try text.hitTest(10, y);
    try std.testing.expect(pos.offset > shaped.starts[last - 1]);
}



