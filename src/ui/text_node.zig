//! Text nodes (D13): each owns a width-independent `ShapedText` (its text
//! in blocks of whole paragraphs), rebuilt only when its text or
//! font-related style changes or a font it wanted finished loading, and a
//! `TextLayout` for the current width, rebuilt when the width changes. An
//! edit reshapes and lays out only the blocks it touched.
//!
//! A node with a line limit or an ellipsis that does not fit shows a cut
//! copy instead: the text up to a grapheme boundary of its last line, with
//! "…" appended, shaped and laid out like the original, the boundary found
//! by bisection. Its content, and so its accessible name, stays whole.
//!
//! A long text first shapes the blocks that cover its start and shapes the
//! rest on the worker pool (`Pending`), adding it as it arrives; editing
//! it, or showing what is not shaped yet, shapes the rest at once (D13).

const std = @import("std");
const builtin = @import("builtin");
const text = @import("text");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const Fonts = @import("fonts.zig");
const spans = @import("spans.zig");

const NodeId = node_mod.NodeId;
const Pool = @import("loop").Pool;
const ShapedBlock = text.blocks.ShapedBlock;

/// Texts at least this long shape their first `prefix_bytes` (to a block
/// end) at once and the rest on the pool, `chunk_blocks` blocks per job.
const background_bytes = 64 << 10;
const prefix_bytes = 32 << 10;
const chunk_blocks = 48;

pub const Cache = struct {
    paragraph: ?text.ShapedText = null,
    layout: ?text.TextLayout = null,
    /// The width the layout was built for (null: unwrapped).
    layout_width: ?f32 = null,
    /// `Fonts.serial` when the paragraph was shaped.
    serial: u32 = 0,
    /// An editor's placeholder, shaped in the same style, unwrapped.
    placeholder: ?struct { paragraph: text.ShapedText, layout: text.TextLayout } = null,
    /// The span style of each of the paragraph's styles (by index), for
    /// colors and decorations at paint time.
    run_styles: std.ArrayList(node_mod.SpanStyle) = .empty,
    /// The layout of the text `paragraph` was reshaped from, until the
    /// next layout takes the lines of the blocks they share (D13). Only
    /// its blocks are used: its `shaped` is gone.
    previous: ?text.TextLayout = null,
    /// The cut copy shown instead of `layout` (`shows_cut`), and the width
    /// it was fitted to.
    cut: ?struct { paragraph: text.ShapedText, layout: text.TextLayout } = null,
    cut_fit: ?f32 = null,
    shows_cut: bool = false,
    /// The rest of the text, while the pool shapes it.
    pending: ?*Pending = null,
    /// Shape the rest at the next layout: it is wanted on screen.
    want_all: bool = false,
    /// The pool finished shaping the text: trim the heap after the next
    /// layout.
    trim: bool = false,

    pub fn destroy(c: *Cache, gpa: std.mem.Allocator) void {
        c.dropPending();
        if (c.layout) |*l| l.deinit();
        if (c.paragraph) |*p| p.deinit();
        c.dropCut();
        c.dropPrevious();
        c.dropPlaceholder();
        c.run_styles.deinit(gpa);
        gpa.destroy(c);
    }

    /// The span style of a glyph run's style index.
    pub fn runStyle(c: *const Cache, style: u32) node_mod.SpanStyle {
        return if (style < c.run_styles.items.len) c.run_styles.items[style] else .{};
    }

    fn dropPlaceholder(c: *Cache) void {
        if (c.placeholder) |*ph| {
            ph.layout.deinit();
            ph.paragraph.deinit();
        }
        c.placeholder = null;
    }

    /// The paragraph wanted fonts and some font finished loading since.
    pub fn waiting(c: *const Cache, fonts: *const Fonts) bool {
        const p = c.paragraph orelse return false;
        return p.wanted.len != 0 and c.serial != fonts.serial;
    }

    /// Stops shaping the rest: queued jobs are cancelled, and running
    /// ones throw their blocks away.
    fn dropPending(c: *Cache) void {
        const p = c.pending orelse return;
        c.pending = null;
        c.want_all = false;
        p.orphaned.store(true, .seq_cst);
        for (p.chunks[p.next..]) |*ch| if (!ch.delivered and p.pool.cancel(&ch.job)) {
            ch.delivered = true;
            p.unref();
        };
        p.unref();
    }

    /// Puts a paragraph extended from the current one in its place; the
    /// next layout keeps the lines of the blocks they share.
    fn adopt(c: *Cache, win: *Window, id: NodeId, p: text.ShapedText, mark: bool) void {
        c.dropCut();
        if (c.layout != null) {
            c.dropPrevious();
            c.previous = c.layout;
            c.layout = null;
        }
        c.paragraph.?.deinit();
        c.paragraph = p;
        if (!mark) return;
        win.markLayout(id);
        win.requestFrame();
    }

    fn dropPrevious(c: *Cache) void {
        if (c.previous) |*l| l.deinit();
        c.previous = null;
    }

    fn dropLayout(c: *Cache) void {
        if (c.layout) |*l| l.deinit();
        c.layout = null;
        c.dropCut();
    }

    fn dropCut(c: *Cache) void {
        if (c.cut) |*ct| {
            ct.layout.deinit();
            ct.paragraph.deinit();
        }
        c.cut = null;
        c.shows_cut = false;
    }
};

fn cache(win: *Window, id: NodeId) error{OutOfMemory}!*Cache {
    const s = win.state(id);
    if (s.text) |c| return c;
    const c = try win.gpa.create(Cache);
    c.* = .{};
    s.text = c;
    return c;
}

/// Shapes the node's text if it changed. Requests fonts it wanted.
fn shape(win: *Window, id: NodeId) error{OutOfMemory}!*Cache {
    const c = try cache(win, id);
    const s = win.state(id);
    const fonts = win.fonts;
    // A text changed while the pool shapes it is finished first, so that
    // the change reshapes only its blocks; with other fonts it is
    // reshaped whole anyway.
    if (c.pending != null) {
        if (s.needs_shape and c.serial != fonts.serial) c.dropPending() else if (s.needs_shape or c.want_all) try finishNow(win, id, c, false);
    }
    if (!s.needs_shape and c.paragraph != null) return c;
    const d = win.node(id).textData();
    const n = win.node(id);
    const a = win.scratch.allocator();
    var content = d.content;
    var list = d.spans;
    if (n.kind == .editor) {
        content = try @import("editor.zig").displayText(win, id, a);
        // The preedit sits at the caret in the style typing would give it.
        if (content.len != d.content.len) {
            const e = n.data.editor;
            list = try spans.replaced(a, d.spans, e.caret, e.caret, @intCast(content.len - d.content.len), e.typing orelse spans.inherited(d.spans, e.caret));
        }
    }
    try c.run_styles.ensureTotalCapacity(win.gpa, 2 * list.len + 1);
    // An edit keeps the paragraphs it did not touch, unless fonts changed.
    const old: ?*const text.ShapedText = if (c.paragraph != null and c.serial == fonts.serial and c.paragraph.?.pending == 0) &c.paragraph.? else null;
    const runs = try styleRuns(win, id, content, list, &c.run_styles);
    var pending: ?*Pending = null;
    var p = blk: {
        if (old == null and content.len >= background_bytes) if (fonts.pool) |pool| {
            // The first blocks `ShapedText.init` would make.
            var prefix_end: usize = 0;
            while (prefix_end < prefix_bytes) prefix_end = text.blocks.blockEnd(content, prefix_end, content.len, .{});
            if (prefix_end < content.len) {
                var head = try shapeRuns(win, content, runs, null, prefix_end);
                pending = Pending.start(win, id, pool, content, runs, prefix_end) catch null;
                if (pending != null) break :blk head;
                head.deinit();
            }
        };
        break :blk try shapeRuns(win, content, runs, old, null);
    };
    errdefer p.deinit();
    c.dropCut();
    // The last layout built, kept until the next takes its lines.
    if (old == null) {
        c.dropPrevious();
        c.dropLayout();
    } else if (c.layout != null) {
        c.dropPrevious();
        c.previous = c.layout;
        c.layout = null;
    }
    if (c.paragraph) |*o| o.deinit();
    c.dropPlaceholder();
    c.paragraph = p;
    c.pending = pending;
    c.want_all = false;
    c.serial = fonts.serial;
    s.needs_shape = false;
    win.stats.shapes += 1;
    if (p.wanted.len != 0) fonts.request(p.wanted);
    return c;
}

/// Shapes `content` in the node's style with `list`'s spans over it, one
/// style per run of equal span style; `run_styles` gets each run's span
/// style.
fn shapeString(win: *Window, id: NodeId, content: []const u8, list: []const node_mod.Span, run_styles: ?*std.ArrayList(node_mod.SpanStyle), old: ?*const text.ShapedText) error{OutOfMemory}!text.ShapedText {
    return shapeRuns(win, content, try styleRuns(win, id, content, list, run_styles), old, null);
}

const Runs = struct { styles: []const text.StyleRun, direction: text.bidi.BaseDirection };

/// The style runs `shapeString` shapes with, in scratch memory.
fn styleRuns(win: *Window, id: NodeId, content: []const u8, list: []const node_mod.Span, run_styles: ?*std.ArrayList(node_mod.SpanStyle)) error{OutOfMemory}!Runs {
    const d = win.node(id).textData();
    const fonts = win.fonts;
    const style = d.props.style;
    const language = if (d.language != 0) d.language else win.language;
    const lang_name = if (fonts.name(language).len == 0) "und" else fonts.name(language);
    const scale: f32 = @floatCast(win.desktop.text_scale);
    const size = win.palette.textSize(style.size, style.size_role) * scale;
    const len: u32 = @intCast(content.len);
    var runs: std.ArrayList(text.StyleRun) = .empty;
    const a = win.scratch.allocator();
    if (run_styles) |rs| rs.clearRetainingCapacity();
    var at: u32 = 0;
    while (true) {
        const run = spans.runAt(list, at, len);
        const sp = run.style;
        const run_size = if (sp.size) |z| z * scale else size;
        const chain = try fonts.chain(.{ .family = sp.family orelse d.family, .language = language, .weight = node_mod.cssWeight(style, sp.weight), .slant = sp.slant orelse style.slant, .width = sp.width orelse style.width, .size = run_size });
        try runs.append(a, .{ .end = run.end, .style = .{ .fonts = chain, .size = run_size, .language = lang_name } });
        if (run_styles) |rs| try rs.append(win.gpa, sp);
        if (run.end >= len) break;
        at = run.end;
    }
    const direction: text.bidi.BaseDirection = switch (d.props.direction) {
        .auto => if (win.state(id).rtl) .auto_rtl else .auto_ltr,
        .ltr => .ltr,
        .rtl => .rtl,
    };
    return .{ .styles = runs.items, .direction = direction };
}

/// Shapes `content` with `runs`, reusing `old`'s blocks, or only up to
/// `prefix_end` (a block end).
fn shapeRuns(win: *Window, content: []const u8, runs: Runs, old: ?*const text.ShapedText, prefix_end: ?usize) error{OutOfMemory}!text.ShapedText {
    const a = win.scratch.allocator();
    const cache_ = &win.fonts.cache;
    const result = if (prefix_end) |e|
        text.ShapedText.initPrefix(win.gpa, a, cache_, content, runs.styles, runs.direction, .{}, e)
    else
        text.ShapedText.initReusing(win.gpa, a, cache_, content, runs.styles, runs.direction, .{}, old);
    return result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Validated when the text was set; chains may be empty, since
        // the font cache has a last resort (D13).
        error.InvalidUtf8, error.TextTooLong, error.InvalidStyles => unreachable,
    };
}

/// The rest of a long text after the blocks shaped at once, shaped on
/// the pool in chunks of whole blocks (the blocks `ShapedText.init` would
/// make, so the result is the same). Each chunk's blocks join the text
/// when it and those before it are done. Shared by the node and each
/// chunk until its completion: a node that goes away, or reshapes, marks
/// it orphaned and the jobs still running throw their work away.
const Pending = struct {
    gpa: std.mem.Allocator,
    pool: *Pool,
    cache: *const text.FontCache,
    win: *Window,
    id: NodeId,
    refs: u32,
    orphaned: std.atomic.Value(bool) = .init(false),
    /// Copies of the text from `offset` on, its style runs from there
    /// (ends relative to `offset`, font chains copied), and all its style
    /// runs (for `ShapedText.extend`).
    arena: std.heap.ArenaAllocator,
    offset: u32,
    rest: []const u8,
    rest_styles: []const text.StyleRun,
    styles: []const text.StyleRun,
    direction: text.bidi.BaseDirection,
    chunks: []Chunk,
    /// The first chunk not in the text yet.
    next: usize = 0,

    const Chunk = struct {
        job: Pool.Job = .{ .run = run, .done = done, .cancel = cancelled, .priority = -1 },
        owner: *Pending,
        /// Whole-text offsets.
        start: u32,
        end: u32,
        blocks: std.ArrayList(*ShapedBlock) = .empty,
        failed: bool = false,
        delivered: bool = false,
    };

    fn start(win: *Window, id: NodeId, pool: *Pool, content: []const u8, runs: Runs, offset: usize) error{ OutOfMemory, Submit }!*Pending {
        const gpa = win.gpa;
        const p = try gpa.create(Pending);
        p.* = .{ .gpa = gpa, .pool = pool, .cache = &win.fonts.cache, .win = win, .id = id, .refs = 1, .arena = .init(gpa), .offset = @intCast(offset), .rest = &.{}, .rest_styles = &.{}, .styles = &.{}, .direction = runs.direction, .chunks = &.{} };
        errdefer p.unref();
        const a = p.arena.allocator();
        p.rest = try a.dupe(u8, content[offset..]);
        const styles = try a.alloc(text.StyleRun, runs.styles.len);
        var rest: std.ArrayList(text.StyleRun) = .empty;
        for (runs.styles, styles) |r, *copy| {
            copy.* = .{ .end = r.end, .style = .{ .fonts = try a.dupe(text.FontId, r.style.fonts), .size = r.style.size, .language = try a.dupe(u8, r.style.language) } };
            if (r.end > offset) try rest.append(a, .{ .end = @intCast(r.end - offset), .style = copy.style });
        }
        p.styles = styles;
        p.rest_styles = rest.items;
        // Chunks of `chunk_blocks` blocks.
        var ends: std.ArrayList(u32) = .empty;
        var at = offset;
        while (at < content.len) {
            for (0..chunk_blocks) |_| {
                if (at >= content.len) break;
                at = text.blocks.blockEnd(content, at, content.len, .{});
            }
            try ends.append(a, @intCast(at));
        }
        p.chunks = try a.alloc(Chunk, ends.items.len);
        var from: u32 = @intCast(offset);
        for (p.chunks, ends.items) |*ch, end| {
            ch.* = .{ .owner = p, .start = from, .end = end };
            from = end;
        }
        for (p.chunks, 0..) |*ch, i| {
            pool.submit(&ch.job) catch {
                p.orphaned.store(true, .seq_cst);
                for (p.chunks[0..i]) |*q| if (pool.cancel(&q.job)) p.unref();
                return error.Submit;
            };
            p.refs += 1;
        }
        return p;
    }

    fn unref(p: *Pending) void {
        p.refs -= 1;
        if (p.refs != 0) return;
        for (p.chunks) |*ch| {
            for (ch.blocks.items) |b| b.release();
            ch.blocks.deinit(p.gpa);
        }
        p.arena.deinit();
        p.gpa.destroy(p);
    }

    /// On a worker: shapes the chunk's blocks while the font cache stays
    /// as it is, unless the node no longer wants them.
    fn run(job: *Pool.Job) void {
        const ch: *Chunk = @fieldParentPtr("job", job);
        const p = ch.owner;
        var s = ch.start - p.offset;
        const e = ch.end - p.offset;
        while (s < e) {
            if (p.orphaned.load(.seq_cst)) break;
            const to = text.blocks.blockEnd(p.rest, s, e, .{});
            p.cache.lockShared();
            const b = if (p.orphaned.load(.seq_cst)) null else text.blocks.shapeRange(p.gpa, p.cache, p.rest, p.rest_styles, p.direction, s, to) catch null;
            p.cache.unlockShared();
            const block = b orelse break;
            ch.blocks.append(p.gpa, block) catch {
                block.release();
                break;
            };
            s = @intCast(to);
        }
        ch.failed = s < e;
    }

    /// On the loop thread: adds the chunks done in order to the text.
    fn done(job: *Pool.Job) void {
        const ch: *Chunk = @fieldParentPtr("job", job);
        const p = ch.owner;
        ch.delivered = true;
        defer p.unref();
        if (p.orphaned.load(.seq_cst)) return;
        const c = p.win.state(p.id).text.?;
        p.splice(c, true) catch {
            // Shaped at the next layout instead.
            c.want_all = true;
            p.win.markLayout(p.id);
            p.win.requestFrame();
        };
    }

    fn cancelled(job: *Pool.Job) void {
        const ch: *Chunk = @fieldParentPtr("job", job);
        ch.delivered = true;
        ch.owner.unref();
    }

    fn splice(p: *Pending, c: *Cache, mark: bool) error{OutOfMemory}!void {
        var more: std.ArrayList(*ShapedBlock) = .empty;
        defer more.deinit(p.gpa);
        var next = p.next;
        while (next < p.chunks.len and p.chunks[next].delivered) : (next += 1) {
            if (p.chunks[next].failed) return error.OutOfMemory;
            try more.appendSlice(p.gpa, p.chunks[next].blocks.items);
        }
        if (next == p.next) return;
        const extended = c.paragraph.?.extend(p.gpa, p.gpa, more.items, p.styles) catch return error.OutOfMemory;
        // The blocks' references moved into the text.
        for (p.chunks[p.next..next]) |*ch| ch.blocks.clearRetainingCapacity();
        p.next = next;
        c.adopt(p.win, p.id, extended, mark);
        if (next == p.chunks.len) {
            c.dropPending();
            c.trim = true;
        }
    }
};

/// Hands the free pages of the C library's heaps back to the system:
/// shaping on the pool leaves each worker's heap holding the freed
/// intermediates of the blocks it shaped (a sixth again of a 1.4 MB
/// text's memory). glibc's malloc_trim, decided at compile time: other
/// C libraries (musl has none) and builds without libc go without.
fn trimHeap() void {
    if (comptime !(builtin.link_libc and builtin.target.isGnuLibC())) return;
    const malloc_trim = @extern(*const fn (usize) callconv(.c) c_int, .{ .name = "malloc_trim" });
    _ = malloc_trim(0);
}

/// Shapes what is left of a long text now, on this thread: it is being
/// edited or shown.
/// `mark`: the node needs layout again (not when layout shapes it).
fn finishNow(win: *Window, id: NodeId, c: *Cache, mark: bool) error{OutOfMemory}!void {
    const p = c.pending.?;
    // What the pool has finished joins first.
    p.splice(c, mark) catch {};
    const q = c.pending orelse return;
    var more: std.ArrayList(*ShapedBlock) = .empty;
    defer more.deinit(win.gpa);
    errdefer for (more.items) |b| b.release();
    var s: usize = c.paragraph.?.len() - q.offset;
    while (s < q.rest.len) {
        const e = text.blocks.blockEnd(q.rest, s, q.rest.len, .{});
        try more.ensureUnusedCapacity(win.gpa, 1);
        more.appendAssumeCapacity(text.blocks.shapeRange(win.gpa, q.cache, q.rest, q.rest_styles, q.direction, s, e) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        });
        s = e;
    }
    const extended = c.paragraph.?.extend(win.gpa, win.scratch.allocator(), more.items, q.styles) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    more.clearRetainingCapacity();
    c.dropPending();
    c.adopt(win, id, extended, mark);
}

/// Shapes the rest of a long text at the next layout if what is shown
/// goes past its shaped part: `end` is the bottom of what is painted
/// (null: all of it).
pub fn cover(win: *Window, id: NodeId, l: *const text.TextLayout, end: ?f32) void {
    const c = win.state(id).text orelse return;
    if (c.pending == null or c.want_all) return;
    const last = l.blocks.len - 1;
    if (end) |y| if (y <= l.tops[last] + l.blocks[last].layout.height) return;
    c.want_all = true;
    win.markLayout(id);
    win.requestFrame();
}

/// Shapes the rest of a long text now, for editing.
pub fn finish(win: *Window, id: NodeId) error{OutOfMemory}!void {
    const c = win.state(id).text orelse return;
    if (c.pending == null or win.state(id).needs_shape) return;
    try finishNow(win, id, c, true);
}

/// An editor's placeholder, laid out on one line, after layout shaped the
/// editor's own text.
pub fn placeholder(win: *Window, id: NodeId) error{OutOfMemory}!?*const text.TextLayout {
    const c = win.state(id).text orelse return null;
    if (c.placeholder) |*ph| return &ph.layout;
    const n = win.node(id);
    // The layout points at the paragraph, so it goes in place first.
    c.placeholder = .{ .paragraph = try shapeString(win, id, n.data.editor.placeholder, &.{}, null, null), .layout = undefined };
    const ph = &c.placeholder.?;
    if (ph.paragraph.wanted.len != 0) win.fonts.request(ph.paragraph.wanted);
    ph.layout = text.TextLayout.init(win.gpa, win.scratch.allocator(), &win.fonts.cache, &ph.paragraph, .{ .alignment = .start }, null) catch |err| {
        ph.paragraph.deinit();
        c.placeholder = null;
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
    };
    return &ph.layout;
}

/// A layout that is valid for `width` (null: unwrapped). A layout built
/// for another width is reused when its lines would break the same way:
/// its widest line fits and it was built at least as wide.
pub fn layoutFor(win: *Window, id: NodeId, width: ?f32) error{OutOfMemory}!?*const text.TextLayout {
    // Empty labels take no space; an empty editor still has a caret line.
    const n = win.node(id);
    if (n.kind == .text and n.data.text.content.len == 0) return null;
    const c = try shape(win, id);
    if (c.layout) |*l| {
        const built: f32 = c.layout_width orelse std.math.inf(f32);
        const want: f32 = width orelse std.math.inf(f32);
        // Justified and total-fit lines depend on the exact width.
        const exact = n.textData().props.exactWidth(n.textData().paragraphs);
        if (if (exact) built == want else l.width <= want and want <= built) return l;
    }
    // Lines are aligned in the node at paint time (`lineShift`); only
    // justification needs the layout.
    const d = n.textData();
    // Blocks laid out before an edit, or for another width or style,
    // keep their lines when nothing they depend on changed.
    const previous: ?*const text.TextLayout = if (c.previous) |*pl| pl else if (c.layout) |*cl| cl else null;
    const l = text.TextLayout.init(win.gpa, win.scratch.allocator(), &win.fonts.cache, &c.paragraph.?, .{
        .width = width,
        .alignment = if (d.props.alignment == .justify) .justify else .start,
        .paragraphs = try paragraphRuns(win, id),
        .tab_stops = d.props.tab_stops,
        .break_words = d.props.break_words,
        .hyphenate = d.props.hyphenate,
        .hyphenation = &win.fonts.hyphenation,
        .optimal = d.props.optimal,
    }, previous) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // finite, non-negative widths only
    };
    c.dropPrevious();
    c.dropLayout();
    c.layout = l;
    c.layout_width = width;
    win.stats.text_layouts += 1;
    if (c.trim) {
        c.trim = false;
        trimHeap();
    }
    return &c.layout.?;
}

/// The layout the node shows at wrapping width `width` (null: unwrapped)
/// in a box `fit` wide: `layoutFor`'s, or a cut copy when the node limits
/// its lines or ellipsizes and the text does not fit.
pub fn layoutIn(win: *Window, id: NodeId, width: ?f32, fit: ?f32) error{OutOfMemory}!?*const text.TextLayout {
    const full = try layoutFor(win, id, width) orelse return null;
    const n = win.node(id);
    if (n.kind != .text) return full;
    const props = n.data.text.props;
    if (props.max_lines == 0 and !props.ellipsize) return full;
    const c = win.state(id).text.?;
    var last: ?usize = null;
    if (props.max_lines != 0 and full.lineCount() > props.max_lines) last = props.max_lines - 1;
    if (props.ellipsize) if (fit) |f| for (0..full.lineCount()) |i| {
        if (last != null and i >= last.?) break;
        if (full.line(@intCast(i)).width > f + 0.01) {
            last = i;
            break;
        }
    };
    const line_index = last orelse {
        c.shows_cut = false;
        return full;
    };
    if (c.cut != null and c.cut_fit == fit and c.cut.?.layout.lineCount() == line_index + 1) {
        c.shows_cut = true;
        return &c.cut.?.layout;
    }
    c.dropCut();
    try cutText(win, id, c, full, line_index, width, fit);
    c.cut_fit = fit;
    c.shows_cut = true;
    return &c.cut.?.layout;
}

const Cut = struct {
    paragraph: text.ShapedText,
    layout: text.TextLayout,

    fn deinit(ct: *Cut) void {
        ct.layout.deinit();
        ct.paragraph.deinit();
    }
};

/// Builds the cut copy: the text up to the last grapheme boundary of line
/// `last` at which it, with "…" when the node ellipsizes, still ends on
/// that line and fits in `fit`.
fn cutText(win: *Window, id: NodeId, c: *Cache, full: *const text.TextLayout, last: usize, width: ?f32, fit: ?f32) error{OutOfMemory}!void {
    const d = win.node(id).data.text;
    const content = d.content;
    const line = full.line(@intCast(last));
    const a = win.scratch.allocator();
    // Grapheme edges of the line, without its trailing white space.
    var end = line.end;
    while (end > line.start and std.ascii.isWhitespace(content[end - 1])) end -= 1;
    var edges: std.ArrayList(u32) = .empty;
    try edges.append(a, line.start);
    const bi = full.blockOfLine(@intCast(last));
    const base = full.shaped.starts[bi];
    const block = &full.blocks[bi].layout;
    for (block.lineCarets(block.lines[last - full.line_starts[bi]])) |k| {
        const offset = base + k.offset;
        if (offset > line.start and offset <= end) try edges.append(a, offset);
    }
    std.mem.sort(u32, edges.items, {}, std.sort.asc(u32));
    const ellipsis = if (d.props.ellipsize) "…" else "";
    // The largest edge that fits, by bisection; the line's start stands
    // in when none does. Without an ellipsis the text stops at the line's
    // end.
    var lo: usize = if (ellipsis.len == 0) edges.items.len - 1 else 0;
    var hi: usize = edges.items.len - 1;
    var best: ?Cut = null;
    var best_at: usize = 0;
    errdefer if (best) |*b| b.deinit();
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        var ct = try cutAt(win, id, content, edges.items[mid], line.start, ellipsis, width);
        if (ct.layout.lineCount() <= last + 1 and (fit == null or ct.layout.width <= fit.? + 0.01)) {
            if (best) |*b| b.deinit();
            best = ct;
            best_at = mid;
            lo = mid;
        } else {
            ct.deinit();
            hi = mid - 1;
        }
    }
    if (best == null or best_at != lo) {
        if (best) |*b| b.deinit();
        best = try cutAt(win, id, content, edges.items[lo], line.start, ellipsis, width);
    }
    // The layout points at its paragraph: put both in place, then fix it.
    c.cut = .{ .paragraph = best.?.paragraph, .layout = best.?.layout };
    c.cut.?.layout.shaped = &c.cut.?.paragraph;
}

/// The node's text up to `at` (less trailing white space, down to
/// `floor`) with `suffix`, shaped and laid out like the node.
fn cutAt(win: *Window, id: NodeId, content: []const u8, at: u32, floor: u32, suffix: []const u8, width: ?f32) error{OutOfMemory}!Cut {
    const d = win.node(id).data.text;
    const a = win.scratch.allocator();
    var trimmed = at;
    while (trimmed > floor and std.ascii.isWhitespace(content[trimmed - 1])) trimmed -= 1;
    const s = try std.mem.concat(a, u8, &.{ content[0..trimmed], suffix });
    var ct: Cut = .{ .paragraph = try shapeString(win, id, s, d.spans, null, null), .layout = undefined };
    errdefer ct.paragraph.deinit();
    if (ct.paragraph.wanted.len != 0) win.fonts.request(ct.paragraph.wanted);
    ct.layout = text.TextLayout.init(win.gpa, a, &win.fonts.cache, &ct.paragraph, .{
        .width = width,
        .alignment = if (d.props.alignment == .justify) .justify else .start,
        .paragraphs = try paragraphRuns(win, id),
        .tab_stops = d.props.tab_stops,
        .break_words = d.props.break_words,
        .hyphenate = d.props.hyphenate,
        .hyphenation = &win.fonts.hyphenation,
        .optimal = d.props.optimal,
    }, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    return ct;
}

/// The node's paragraph styles as layout runs: its defaults, patched by
/// its paragraph spans. An editor's preedit shifts the spans after the
/// caret.
fn paragraphRuns(win: *Window, id: NodeId) error{OutOfMemory}![]const text.layout.ParagraphRun {
    const n = win.node(id);
    const d = n.textData();
    const base = d.props.paragraph;
    if (d.paragraphs.len == 0) return win.scratch.allocator().dupe(text.layout.ParagraphRun, &.{.{ .end = std.math.maxInt(u32), .style = base }});
    const a = win.scratch.allocator();
    var list = d.paragraphs;
    // Shaped already: the text as shown, with any preedit.
    const shaped = &win.state(id).text.?.paragraph.?;
    const shown: u32 = shaped.len() + shaped.pending;
    if (n.kind == .editor and shown != d.content.len) {
        const e = n.data.editor;
        list = try spans.replaced(a, list, e.caret, e.caret, @intCast(shown - d.content.len), spans.inherited(list, e.caret));
    }
    var runs: std.ArrayList(text.layout.ParagraphRun) = .empty;
    var at: u32 = 0;
    while (true) {
        const run = spans.runAt(list, at, shown);
        try runs.append(a, .{ .end = run.end, .style = run.style.apply(base) });
        if (run.end >= shown) break;
        at = run.end;
    }
    return runs.items;
}

/// Unwrapped width of the text.
pub fn maxContent(win: *Window, id: NodeId) error{OutOfMemory}!f32 {
    const l = try layoutFor(win, id, null) orelse return 0;
    return l.width;
}

/// The node's current layout (after layout ran): the cut copy when it
/// shows one.
pub fn current(win: *const Window, id: NodeId) ?*const text.TextLayout {
    const c = win.state(id).text orelse return null;
    const n = win.node(id);
    if (n.kind == .text and n.data.text.content.len == 0) return null;
    if (c.shows_cut) if (c.cut) |*ct| return &ct.layout;
    return if (c.layout) |*l| l else null;
}

/// Horizontal shift that aligns a line in the node's content box. The
/// layout placed each line at the start of its own base direction; text
/// aligns by the node's direction instead (D21), so an English label in a
/// right-to-left window is flush right, while each paragraph's bidi
/// ordering still follows its own text.
pub fn lineShift(win: *const Window, id: NodeId, line: text.layout.Line, content_width: f32) f32 {
    // Paragraph indents and alignment follow the node's direction too.
    const target = line.contentXIn(content_width, win.state(id).rtl, win.node(id).textData().props.alignment);
    return target - line.contentX();
}
