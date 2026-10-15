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
//! A long text keeps the shaping and lines of only the blocks it used
//! recently, within the application's `Residency` budget, and their exact
//! metrics for good (D13). It first shapes the blocks that cover its start
//! and lays out the rest with estimated metrics; the worker pool shapes
//! them (`Shaping`) and each is measured as it arrives. `settle`, after
//! each layout, measures the blocks a scroll container shows and keeps
//! what it shows in place while metrics above it change.

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

/// Texts at least this long are long texts: they keep blocks in the
/// residency's budget, shape their first `prefix_bytes` (to a block end)
/// at once, and estimate the rest until the pool has shaped it,
/// `chunk_blocks` blocks per job.
pub const background_bytes = 64 << 10;
const prefix_bytes = 32 << 10;
const chunk_blocks = 8;
const inflight_jobs = 4;

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
    /// Jobs shaping estimated blocks on the pool.
    shaping: std.ArrayList(*Shaping) = .empty,
    /// Blocks shaped after the text wanted fonts that were loading.
    late_wanted: bool = false,
    /// Where the text's scroll container shows it (`settle`).
    anchor: ?Anchor = null,
    /// The text `paragraph` was shaped from (with any preedit), to find
    /// what the next text changed (D15).
    shown: text.Rope = .{},

    pub fn destroy(c: *Cache, gpa: std.mem.Allocator) void {
        if (c.layout) |*l| l.deinit();
        c.dropPrevious();
        if (c.paragraph) |*p| p.deinit();
        // After the text's references are gone, so that the blocks only
        // jobs hold leave the residency (`Shaping.orphan`).
        c.dropShaping(gpa);
        c.shaping.deinit(gpa);
        c.dropCut();
        c.dropPlaceholder();
        c.shown.release(gpa);
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
        return (p.wanted.len != 0 or c.late_wanted) and c.serial != fonts.serial;
    }

    /// Stops shaping on the pool: queued jobs are cancelled, and running
    /// ones throw their work away.
    fn dropShaping(c: *Cache, gpa: std.mem.Allocator) void {
        for (c.shaping.items) |sh| sh.orphan();
        c.shaping.clearRetainingCapacity();
        _ = gpa;
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
    if (!s.needs_shape and c.paragraph != null) return c;
    const d = win.node(id).textData();
    const n = win.node(id);
    const a = win.scratch.allocator();
    // The text shown: the content, with an editor's preedit in it.
    const content = if (n.kind == .editor) try @import("editor.zig").displayText(win, id) else d.content.retain();
    var keep_content = false;
    defer if (!keep_content) content.release(win.gpa);
    var list = d.spans;
    if (content.len() != d.content.len()) {
        // The preedit sits at the caret in the style typing would give it.
        const e = n.data.editor;
        list = try spans.replaced(a, d.spans, e.caret, e.caret, @intCast(content.len() - d.content.len()), e.typing orelse spans.inherited(d.spans, e.caret));
    }
    try c.run_styles.ensureTotalCapacity(win.gpa, 2 * list.len + 1);
    // An edit keeps the blocks it did not touch, unless fonts changed.
    // Blocks still shaping on the pool stay theirs (`Shaping`). What
    // changed since the text last shaped comes from the ropes, which
    // share all but the leaves edits touched (D15).
    const old: ?*const text.ShapedText = if (c.paragraph != null and c.serial == fonts.serial) &c.paragraph.? else null;
    const change: ?text.blocks.Change = if (old != null) .{
        .prefix = text.Rope.commonPrefix(c.shown, content),
        .suffix = text.Rope.commonSuffix(c.shown, content),
    } else null;
    const runs = try styleRuns(win, id, content.len(), list, &c.run_styles);
    var p = try shapeRuns(win, .ofRope(content), runs, old, blockOptions(win, content.len()), change);
    errdefer p.deinit();
    c.shown.release(win.gpa);
    c.shown = content;
    keep_content = true;
    c.dropCut();
    // The last layout built, kept until the next takes its lines.
    if (old == null) {
        c.dropShaping(win.gpa);
        c.dropPrevious();
        c.dropLayout();
        c.anchor = null;
        c.late_wanted = false;
    } else if (c.layout != null) {
        c.dropPrevious();
        c.previous = c.layout;
        c.layout = null;
    }
    if (c.paragraph) |*o| o.deinit();
    c.dropPlaceholder();
    c.paragraph = p;
    c.serial = fonts.serial;
    s.needs_shape = false;
    win.stats.shapes += 1;
    if (p.wanted.len != 0) fonts.request(p.wanted);
    return c;
}

/// How a text of `len` bytes is split: a long text keeps its blocks in
/// the residency's budget and, with a pool to shape the rest, shapes only
/// its first blocks now.
fn blockOptions(win: *Window, len: usize) text.blocks.Options {
    if (len < background_bytes) return .{};
    return .{ .eager_bytes = if (win.fonts.pool != null) prefix_bytes else null, .residency = &win.fonts.residency };
}

/// Whether the node's text is a long text.
fn isLong(c: *const Cache) bool {
    return c.paragraph.?.options.residency != null;
}

/// Shapes `content` in the node's style with `list`'s spans over it, one
/// style per run of equal span style; `run_styles` gets each run's span
/// style.
fn shapeString(win: *Window, id: NodeId, content: []const u8, list: []const node_mod.Span, run_styles: ?*std.ArrayList(node_mod.SpanStyle), old: ?*const text.ShapedText) error{OutOfMemory}!text.ShapedText {
    return shapeRuns(win, .flat(content), try styleRuns(win, id, content.len, list, run_styles), old, .{}, null);
}

const Runs = struct { styles: []const text.StyleRun, direction: text.bidi.BaseDirection };

/// The style runs `shapeString` shapes with, in scratch memory.
fn styleRuns(win: *Window, id: NodeId, content_len: usize, list: []const node_mod.Span, run_styles: ?*std.ArrayList(node_mod.SpanStyle)) error{OutOfMemory}!Runs {
    const d = win.node(id).textData();
    const fonts = win.fonts;
    const style = d.props.style;
    const language = if (d.language != 0) d.language else win.language;
    const lang_name = if (fonts.name(language).len == 0) "und" else fonts.name(language);
    const scale: f32 = @floatCast(win.desktop.text_scale);
    const size = win.palette.textSize(style.size, style.size_role) * scale;
    const len: u32 = @intCast(content_len);
    var runs: std.ArrayList(text.StyleRun) = .empty;
    const a = win.scratch.allocator();
    if (run_styles) |rs| rs.clearRetainingCapacity();
    // The runs in order: each span, and the unstyled stretches between.
    // A long styled text has a run per span (Markdown's markup and
    // emphasis: one per few words), and a text reshapes its runs after
    // every edit, so the spans are walked once, not searched per run, and
    // the few distinct fonts they ask for are remembered here rather than
    // looked up per run.
    try runs.ensureTotalCapacity(a, 2 * list.len + 1);
    const Memo = struct { query: Fonts.Query, chain: []const text.FontId };
    var memo: [8]?Memo = @splat(null);
    var memo_next: usize = 0;
    var at: u32 = 0;
    var i: usize = 0;
    while (true) {
        var run: node_mod.Span = .{ .start = at, .end = len, .style = .{} };
        if (i < list.len and list[i].start <= at) {
            run = list[i];
            i += 1;
        } else if (i < list.len) run.end = list[i].start;
        const sp = run.style;
        const run_size = if (sp.size) |z| z * scale else size;
        const query: Fonts.Query = .{ .family = sp.family orelse d.family, .language = language, .weight = node_mod.cssWeight(style, sp.weight), .slant = sp.slant orelse style.slant, .width = sp.width orelse style.width, .size = run_size };
        const chain = for (memo) |m| {
            if (m) |x| if (std.meta.eql(x.query, query)) break x.chain;
        } else blk: {
            const ch = try fonts.chain(query);
            memo[memo_next] = .{ .query = query, .chain = ch };
            memo_next = (memo_next + 1) % memo.len;
            break :blk ch;
        };
        runs.appendAssumeCapacity(.{ .end = run.end, .style = .{ .fonts = chain, .size = run_size, .language = lang_name } });
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

/// Shapes `content` with `runs`, reusing `old`'s blocks.
fn shapeRuns(win: *Window, content: text.blocks.Source, runs: Runs, old: ?*const text.ShapedText, options: text.blocks.Options, change: ?text.blocks.Change) error{OutOfMemory}!text.ShapedText {
    const a = win.scratch.allocator();
    return text.ShapedText.initEdit(win.gpa, a, &win.fonts.cache, content, runs.styles, runs.direction, options, old, change) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Validated when the text was set; chains may be empty, since
        // the font cache has a last resort (D13).
        error.InvalidUtf8, error.TextTooLong, error.InvalidStyles => unreachable,
    };
}

/// Estimated blocks of a long text, shaped on the pool in jobs of
/// `chunk_blocks` and measured on the loop thread as each job is done
/// (D13). Each job holds references to its blocks, which stay what they
/// are while other blocks of the text are edited, so an edit does not
/// stop it; a node that reshapes whole or goes away orphans it: queued
/// jobs are cancelled and running ones throw their work away.
const Shaping = struct {
    gpa: std.mem.Allocator,
    pool: *Pool,
    cache: *const text.FontCache,
    win: *Window,
    id: NodeId,
    refs: u32,
    orphaned: std.atomic.Value(bool) = .init(false),
    blocks: []*ShapedBlock,
    results: []?text.ShapedParagraph,
    jobs: []Job,
    submitted: usize = 0,

    const Job = struct {
        job: Pool.Job = .{ .run = run, .done = done, .cancel = cancelled, .priority = -1 },
        owner: *Shaping,
        first: usize,
        end: usize,
        delivered: bool = false,
    };

    /// Shapes `list` (estimated blocks not in memory or queued) on the pool.
    fn start(win: *Window, id: NodeId, pool: *Pool, list: []const *ShapedBlock) error{ OutOfMemory, Submit }!*Shaping {
        const gpa = win.gpa;
        const sh = try gpa.create(Shaping);
        sh.* = .{ .gpa = gpa, .pool = pool, .cache = &win.fonts.cache, .win = win, .id = id, .refs = 1, .blocks = &.{}, .results = &.{}, .jobs = &.{} };
        errdefer sh.unref();
        sh.blocks = try gpa.dupe(*ShapedBlock, list);
        for (sh.blocks) |b| {
            b.refs += 1;
            b.queued = true;
        }
        sh.results = try gpa.alloc(?text.ShapedParagraph, list.len);
        @memset(sh.results, null);
        sh.jobs = try gpa.alloc(Job, (list.len + chunk_blocks - 1) / chunk_blocks);
        for (sh.jobs, 0..) |*j, i| j.* = .{ .owner = sh, .first = i * chunk_blocks, .end = @min(list.len, (i + 1) * chunk_blocks) };
        for (0..@min(sh.jobs.len, inflight_jobs)) |_| sh.submitNext() catch {
            sh.orphan();
            return error.Submit;
        };
        return sh;
    }

    /// Submits the next job. A few at a time: the shaping a job holds
    /// waits for the loop thread to measure and trim it, which may be busy.
    fn submitNext(sh: *Shaping) error{Submit}!void {
        if (sh.submitted == sh.jobs.len) return;
        sh.pool.submit(&sh.jobs[sh.submitted].job) catch return error.Submit;
        sh.submitted += 1;
        sh.refs += 1;
    }

    fn orphan(sh: *Shaping) void {
        sh.orphaned.store(true, .seq_cst);
        // Blocks no text holds any more may outlive the application's
        // residency in jobs still running.
        for (sh.blocks) |b| if (b.refs == 1) b.detach();
        for (sh.jobs[0..sh.submitted]) |*j| if (!j.delivered and sh.pool.cancel(&j.job)) {
            j.delivered = true;
            sh.unref();
        };
        sh.submitted = sh.jobs.len;
        sh.unref();
    }

    fn unref(sh: *Shaping) void {
        sh.refs -= 1;
        if (sh.refs != 0) return;
        for (sh.results) |*r| if (r.*) |*p| p.deinit();
        for (sh.blocks) |b| {
            b.queued = false;
            b.release();
        }
        sh.gpa.free(sh.jobs);
        sh.gpa.free(sh.results);
        sh.gpa.free(sh.blocks);
        sh.gpa.destroy(sh);
    }

    /// On a worker: shapes the job's blocks while the font cache stays as
    /// it is, unless the node no longer wants them.
    fn run(job: *Pool.Job) void {
        const j: *Job = @fieldParentPtr("job", job);
        const sh = j.owner;
        for (j.first..j.end) |i| {
            if (sh.orphaned.load(.seq_cst)) break;
            sh.cache.lockShared();
            defer sh.cache.unlockShared();
            if (sh.orphaned.load(.seq_cst)) break;
            sh.results[i] = sh.blocks[i].shapeAlone() catch null;
        }
    }

    /// On the loop thread: puts the job's blocks in place and measures
    /// them in the node's layout.
    fn done(job: *Pool.Job) void {
        const j: *Job = @fieldParentPtr("job", job);
        const sh = j.owner;
        j.delivered = true;
        defer sh.unref();
        if (sh.orphaned.load(.seq_cst)) return;
        sh.submitNext() catch {
            // Measured where they are shown, or by the next layout's jobs.
            for (sh.jobs[sh.submitted..]) |*q| {
                q.delivered = true;
                for (sh.blocks[q.first..q.end]) |b| b.queued = false;
            }
            sh.submitted = sh.jobs.len;
        };
        for (sh.blocks[j.first..j.end], sh.results[j.first..j.end]) |b, *r| {
            b.queued = false;
            if (r.*) |p| b.install(p);
            r.* = null;
        }
        const win = sh.win;
        const c = win.state(sh.id).text.?;
        if (c.layout) |*l| {
            const changed = l.measureShaped() catch true;
            if (changed) {
                win.markLayout(sh.id);
                win.markPaint(sh.id);
                win.requestFrame();
            }
        }
        // Blocks shaped here count as used by no one: back within the
        // budget before more arrive.
        win.fonts.residency.trim();
        noteWanted(win, sh.id);
        for (sh.jobs) |*q| if (!q.delivered) return;
        if (std.mem.indexOfScalar(*Shaping, c.shaping.items, sh)) |i| {
            _ = c.shaping.swapRemove(i);
            sh.unref();
        }
        // The free pages the pool's work left go back at once.
        if (c.shaping.items.len == 0) trimHeap();
    }

    fn cancelled(job: *Pool.Job) void {
        const j: *Job = @fieldParentPtr("job", job);
        j.delivered = true;
        j.owner.unref();
    }
};

/// Blocks shaped after their text was built wanted fonts that are
/// loading: request them, and reshape the text when they load.
fn noteWanted(win: *Window, id: NodeId) void {
    const r = &win.fonts.residency;
    if (r.wanted.items.len == 0) return;
    win.fonts.request(r.wanted.items);
    r.wanted.clearRetainingCapacity();
    if (win.state(id).text) |c| c.late_wanted = true;
}

/// Hands the free pages of the C library's heaps back to the system:
/// shaping on the pool leaves each worker's heap holding the freed
/// intermediates of the blocks it shaped, and evicted blocks leave holes
/// in the loop thread's. glibc's malloc_trim, decided at compile time:
/// other C libraries (musl has none) and builds without libc go without.
fn trimHeap() void {
    if (comptime !(builtin.link_libc and builtin.target.isGnuLibC())) return;
    const malloc_trim = @extern(*const fn (usize) callconv(.c) c_int, .{ .name = "malloc_trim" });
    _ = malloc_trim(0);
}

/// Starts shaping a long text's estimated blocks on the pool, those not
/// in memory and not shaping already.
fn shapeEstimated(win: *Window, id: NodeId, c: *Cache, l: *const text.TextLayout) error{OutOfMemory}!void {
    const pool = win.fonts.pool orelse return;
    if (!l.estimated()) return;
    var list: std.ArrayList(*ShapedBlock) = .empty;
    defer list.deinit(win.gpa);
    for (l.blocks) |lb| if (!lb.measured and lb.shaped.paragraph == null and !lb.shaped.queued) try list.append(win.gpa, lb.shaped);
    if (list.items.len == 0) return;
    try c.shaping.ensureUnusedCapacity(win.gpa, 1);
    const sh = Shaping.start(win, id, pool, list.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Measured where they are shown instead.
        error.Submit => return,
    };
    c.shaping.appendAssumeCapacity(sh);
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
    ph.layout = text.TextLayout.init(win.gpa, win.scratch.allocator(), &ph.paragraph, .{ .alignment = .start }, null, false) catch |err| {
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
    if (n.kind == .text and n.data.text.content.len() == 0) return null;
    const c = try shape(win, id);
    if (c.layout) |*l| {
        const built: f32 = c.layout_width orelse std.math.inf(f32);
        const want: f32 = width orelse std.math.inf(f32);
        // Justified and total-fit lines depend on the exact width, and so
        // does a long text, whose estimated blocks may hold wider lines.
        const exact = n.textData().props.exactWidth(n.textData().paragraphs) or isLong(c);
        if (if (exact) built == want else l.width() <= want and want <= built) return l;
    }
    // Lines are aligned in the node at paint time (`lineShift`); only
    // justification needs the layout.
    const d = n.textData();
    // Blocks laid out before an edit, or for another width or style,
    // keep their lines when nothing they depend on changed.
    const previous: ?*const text.TextLayout = if (c.previous) |*pl| pl else if (c.layout) |*cl| cl else null;
    const long = isLong(c);
    const l = text.TextLayout.init(win.gpa, win.scratch.allocator(), &c.paragraph.?, .{
        .width = width,
        .alignment = if (d.props.alignment == .justify) .justify else .start,
        .paragraphs = try paragraphRuns(win, id),
        .tab_stops = d.props.tab_stops,
        .break_words = d.props.break_words,
        .hyphenate = d.props.hyphenate,
        .hyphenation = &win.fonts.hyphenation,
        .optimal = d.props.optimal,
        // A long text estimates the blocks not in memory (D13).
    }, previous, long) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // finite, non-negative widths only
    };
    c.dropPrevious();
    c.dropLayout();
    c.layout = l;
    c.layout_width = width;
    win.stats.text_layouts += 1;
    if (long) {
        if (std.mem.indexOfScalar(NodeId, win.long_texts.items, id) == null) try win.long_texts.append(win.gpa, id);
        try shapeEstimated(win, id, c, &c.layout.?);
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
        if ((try full.line(@intCast(i))).width > f + 0.01) {
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
    const line = try full.line(@intCast(last));
    const a = win.scratch.allocator();
    // The cut copies are made from the text up to the line's end.
    const content = try d.content.slice(a, 0, line.end);
    // Grapheme edges of the line, without its trailing white space.
    var end = line.end;
    while (end > line.start and std.ascii.isWhitespace(content[end - 1])) end -= 1;
    var edges: std.ArrayList(u32) = .empty;
    try edges.append(a, line.start);
    const bi = full.blockOfLine(@intCast(last));
    const base = full.shaped.starts[bi];
    const block = try full.measure(bi);
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
        if (ct.layout.lineCount() <= last + 1 and (fit == null or ct.layout.width() <= fit.? + 0.01)) {
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
    ct.layout = text.TextLayout.init(win.gpa, a, &ct.paragraph, .{
        .width = width,
        .alignment = if (d.props.alignment == .justify) .justify else .start,
        .paragraphs = try paragraphRuns(win, id),
        .tab_stops = d.props.tab_stops,
        .break_words = d.props.break_words,
        .hyphenate = d.props.hyphenate,
        .hyphenation = &win.fonts.hyphenation,
        .optimal = d.props.optimal,
    }, null, false) catch |err| switch (err) {
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
    // Shaped already: the text as total, with any preedit.
    const shaped = &win.state(id).text.?.paragraph.?;
    const total: u32 = shaped.len();
    if (n.kind == .editor and total != d.content.len()) {
        const e = n.data.editor;
        list = try spans.replaced(a, list, e.caret, e.caret, @intCast(total - d.content.len()), spans.inherited(list, e.caret));
    }
    var runs: std.ArrayList(text.layout.ParagraphRun) = .empty;
    var at: u32 = 0;
    while (true) {
        const run = spans.runAt(list, at, total);
        try runs.append(a, .{ .end = run.end, .style = run.style.apply(base) });
        if (run.end >= total) break;
        at = run.end;
    }
    return runs.items;
}

/// Unwrapped width of the text.
pub fn maxContent(win: *Window, id: NodeId) error{OutOfMemory}!f32 {
    const l = try layoutFor(win, id, null) orelse return 0;
    return l.width();
}

/// The node's current layout (after layout ran): the cut copy when it
/// shows one.
pub fn current(win: *const Window, id: NodeId) ?*const text.TextLayout {
    const c = win.state(id).text orelse return null;
    const n = win.node(id);
    if (n.kind == .text and n.data.text.content.len() == 0) return null;
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

// Scroll anchoring ------------------------------------------------------------

/// Where a long text's scroll container showed it: the block holding the
/// top of what it showed, by address (compared, never dereferenced), and
/// how far below the start of that block's line at `byte` (or, without
/// one, below the block's top) the shown top was. Metrics that change
/// elsewhere (estimates measured, blocks laid out again, edits in other
/// blocks) move the shown top with its block, so what is shown stays put
/// (D13).
pub const Anchor = struct {
    block: *const ShapedBlock,
    byte: ?u32,
    dy: f64,
    /// The shown top, in text coordinates, when it was recorded.
    y: f64,
};

/// The anchor for the shown top at text coordinate `y`, from what is in
/// memory: nothing is laid out for it.
fn anchorAt(l: *const text.TextLayout, y: f64) Anchor {
    const b = l.blockAtY(y);
    const lb = l.blocks[b];
    const top = l.tops[b];
    if (lb.measured) if (lb.layout) |*lay| {
        const line = lay.lines[lay.lineAt(@floatCast(y - top))];
        return .{ .block = lb.shaped, .byte = line.start, .dy = y - (top + line.top), .y = y };
    };
    return .{ .block = lb.shaped, .byte = null, .dy = y - top, .y = y };
}

/// Where the anchor's point is now, in text coordinates: its block (or
/// the block an edit reshaped it into), its line found again by byte.
/// Null when its block is gone.
fn anchorY(l: *const text.TextLayout, a: Anchor) error{OutOfMemory}!?f64 {
    for (l.blocks, 0..) |lb, i| {
        const sb = lb.shaped;
        var byte = a.byte;
        if (sb != a.block) {
            if (sb.from != a.block) continue;
            // Reshaped by an edit: bytes after the change moved with it.
            if (byte) |o| if (sb.paragraph) |*p| if (p.reused) |r| {
                byte = if (o < r.start) o else if (o >= r.old_end) o - r.old_end + r.new_end else r.start;
            };
        }
        const b: u32 = @intCast(i);
        const o = byte orelse return l.tops[b] + a.dy;
        const lay = try l.measure(b);
        const c = lay.caret(.{ .offset = @min(o, sb.len()) });
        return l.tops[b] + lay.lines[c.line].top + a.dy;
    }
    return null;
}

fn nearestScroll(win: *const Window, id: NodeId) ?NodeId {
    var cur = win.node(id).parent;
    while (cur != .none) : (cur = win.node(cur).parent) if (win.node(cur).kind == .scroll) return cur;
    return null;
}

/// What scroll container `sc` shows of the text of `id`: the top in
/// text coordinates, from the offset the UI knows (with corrections not
/// reported back yet), and the height.
fn shown(win: *const Window, id: NodeId, sc: NodeId) [2]f64 {
    const paint = @import("paint.zig");
    const z: f64 = paint.zoomOf(win, sc);
    const pad = win.node(sc).layout.padding;
    // The node's top in the container's content, whatever the offset.
    const node_y = (@as(f64, win.windowRect(id).y0) - (win.windowRect(sc).y0 + pad.top) + paint.scrollTranslation(win, sc).y) / z;
    return .{ win.node(sc).data.scroll.offset.y / z - node_y - win.node(id).layout.padding.top, win.viewportOf(sc).height / z };
}

/// Scrolls `sc` by `dy` text pixels, relative to wherever the compositor
/// has it (D8), and moves the offset the UI knows with it.
fn scrollText(win: *Window, sc: NodeId, dy: f64) void {
    const d: f32 = @floatCast(dy * @import("paint.zig").zoomOf(win, sc));
    win.node(sc).data.scroll.offset.y += d;
    // Up goes before the container's new extent, which may clamp it;
    // down after, which may make room for it.
    win.paint.scroll_by.append(win.gpa, .{ .node = sc, .delta = .{ .x = 0, .y = d }, .early = d < 0 }) catch return;
    win.dirty.props = true;
}

/// After layout: for each long text in a scroll container, keeps what it
/// shows in place while metrics above it changed, scrolls an editor's
/// caret into view when it moved (`Window.reveal`), and measures the
/// estimated blocks within a viewport of what it shows, so that painting
/// finds them exact. Whether layout must run again (heights changed).
pub fn settle(win: *Window) error{OutOfMemory}!bool {
    const reveal = win.reveal;
    win.reveal = .none;
    var revealed = false;
    var relayout = false;
    var i: usize = 0;
    while (i < win.long_texts.items.len) {
        const id = win.long_texts.items[i];
        const c = if (win.isLive(id)) win.state(id).text else null;
        if (c == null or c.?.layout == null or c.?.paragraph == null or !isLong(c.?)) {
            _ = win.long_texts.swapRemove(i);
            continue;
        }
        i += 1;
        const sc = nearestScroll(win, id) orelse continue;
        if (!win.isShown(id)) continue;
        const l = &c.?.layout.?;
        const g = l.generation();
        try settleText(win, id, c.?, l, sc, id == reveal);
        if (id == reveal) revealed = true;
        if (l.generation() != g) {
            win.markLayout(id);
            win.markPaint(id);
            relayout = true;
        }
    }
    if (!revealed and reveal != .none) try revealCaret(win, reveal);
    return relayout;
}

fn settleText(win: *Window, id: NodeId, c: *Cache, l: *const text.TextLayout, sc: NodeId, reveal: bool) error{OutOfMemory}!void {
    // Each round measures at least one block, or ends.
    for (0..16) |_| {
        if (c.anchor) |a| if (try anchorY(l, a)) |y| {
            const dy = y - a.y;
            if (@abs(dy) > 0.001) scrollText(win, sc, dy);
        };
        if (reveal) try revealIn(win, id, l, sc);
        const view = shown(win, id, sc);
        c.anchor = anchorAt(l, view[0]);
        // Painting draws the lines within a viewport of what is shown.
        var measured = false;
        var b = l.blockAtY(view[0] - view[1]);
        while (b < l.blocks.len and l.tops[b] <= view[0] + 2 * view[1]) : (b += 1) {
            if (l.blocks[b].measured) continue;
            _ = try l.measure(b);
            measured = true;
        }
        if (!measured) return;
    }
}

/// Scrolls the caret of editor `id` into view in its nearest scroll
/// container (a text that is not long).
fn revealCaret(win: *Window, id: NodeId) error{OutOfMemory}!void {
    if (!win.isLive(id) or win.node(id).kind != .editor or !win.isShown(id)) return;
    const sc = nearestScroll(win, id) orelse return;
    const l = current(win, id) orelse return;
    try revealIn(win, id, l, sc);
}

fn revealIn(win: *Window, id: NodeId, l: *const text.TextLayout, sc: NodeId) error{OutOfMemory}!void {
    const e = win.node(id).data.editor;
    const editor = @import("editor.zig");
    const caret = try l.caret(.{ .offset = editor.displayCaret(win, id), .affinity = e.affinity });
    const view = shown(win, id, sc);
    const top: f64 = caret.top;
    const bottom = top + caret.height;
    if (top < view[0]) {
        scrollText(win, sc, top - view[0]);
    } else if (bottom > view[0] + view[1]) scrollText(win, sc, bottom - (view[0] + view[1]));
}

/// The compositor scrolled `sc`: long texts in it take their anchors
/// from what it shows now.
pub fn scrolled(win: *Window, sc: NodeId) void {
    for (win.long_texts.items) |id| {
        if (!win.isLive(id) or nearestScroll(win, id) != sc) continue;
        const c = win.state(id).text orelse continue;
        const l = if (c.layout) |*l| l else continue;
        c.anchor = anchorAt(l, shown(win, id, sc)[0]);
    }
}
