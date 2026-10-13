//! Text nodes (D13): each owns a width-independent `ShapedParagraph`,
//! rebuilt only when its text or font-related style changes or a font it
//! wanted finished loading, and a `Layout` for the current width, rebuilt
//! when the width changes.
//!
//! A node with a line limit or an ellipsis that does not fit shows a cut
//! copy instead: the text up to a grapheme boundary of its last line, with
//! "…" appended, shaped and laid out like the original, the boundary found
//! by bisection. Its content, and so its accessible name, stays whole.

const std = @import("std");
const text = @import("text");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const Fonts = @import("fonts.zig");
const spans = @import("spans.zig");

const NodeId = node_mod.NodeId;

pub const Cache = struct {
    paragraph: ?text.ShapedParagraph = null,
    layout: ?text.Layout = null,
    /// The width the layout was built for (null: unwrapped).
    layout_width: ?f32 = null,
    /// `Fonts.serial` when the paragraph was shaped.
    serial: u32 = 0,
    /// An editor's placeholder, shaped in the same style, unwrapped.
    placeholder: ?struct { paragraph: text.ShapedParagraph, layout: text.Layout } = null,
    /// The span style of each of the paragraph's styles (by index), for
    /// colors and decorations at paint time.
    run_styles: std.ArrayList(node_mod.SpanStyle) = .empty,
    /// The paragraph and layout `paragraph` was reshaped from when it
    /// kept some of its paragraphs (text.ShapedParagraph.initReusing),
    /// until the next layout reuses their lines (D13).
    previous: ?struct { paragraph: text.ShapedParagraph, layout: ?text.Layout } = null,
    /// The cut copy shown instead of `layout` (`shows_cut`), and the width
    /// it was fitted to.
    cut: ?struct { paragraph: text.ShapedParagraph, layout: text.Layout } = null,
    cut_fit: ?f32 = null,
    shows_cut: bool = false,

    pub fn destroy(c: *Cache, gpa: std.mem.Allocator) void {
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

    fn dropPrevious(c: *Cache) void {
        if (c.previous) |*pr| {
            if (pr.layout) |*l| l.deinit();
            pr.paragraph.deinit();
        }
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
    if (!s.needs_shape and c.paragraph != null) return c;
    const d = win.node(id).textData();
    const fonts = win.fonts;
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
    const old: ?*const text.ShapedParagraph = if (c.paragraph != null and c.serial == fonts.serial) &c.paragraph.? else null;
    var p = try shapeString(win, id, content, list, &c.run_styles, old);
    errdefer p.deinit();
    c.dropPrevious();
    c.dropCut();
    if (p.reused != null) {
        c.previous = .{ .paragraph = c.paragraph.?, .layout = c.layout };
        c.layout = null;
        // The layout points at its paragraph, which moved.
        if (c.previous.?.layout) |*l| l.paragraph = &c.previous.?.paragraph;
    } else {
        c.dropLayout();
        if (c.paragraph) |*o| o.deinit();
    }
    c.dropPlaceholder();
    c.paragraph = p;
    c.serial = fonts.serial;
    s.needs_shape = false;
    win.stats.shapes += 1;
    if (p.wanted.len != 0) fonts.request(p.wanted);
    return c;
}

/// Shapes `content` in the node's style with `list`'s spans over it, one
/// style per run of equal span style; `run_styles` gets each run's span
/// style.
fn shapeString(win: *Window, id: NodeId, content: []const u8, list: []const node_mod.Span, run_styles: ?*std.ArrayList(node_mod.SpanStyle), old: ?*const text.ShapedParagraph) error{OutOfMemory}!text.ShapedParagraph {
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
    return text.ShapedParagraph.initReusing(win.gpa, a, &fonts.cache, content, runs.items, direction, old) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Validated when the text was set.
        error.InvalidUtf8, error.TextTooLong, error.InvalidStyles => unreachable,
    };
}

/// An editor's placeholder, laid out on one line, after layout shaped the
/// editor's own text.
pub fn placeholder(win: *Window, id: NodeId) error{OutOfMemory}!?*const text.Layout {
    const c = win.state(id).text orelse return null;
    if (c.placeholder) |*ph| return &ph.layout;
    const n = win.node(id);
    // The layout points at the paragraph, so it goes in place first.
    c.placeholder = .{ .paragraph = try shapeString(win, id, n.data.editor.placeholder, &.{}, null, null), .layout = undefined };
    const ph = &c.placeholder.?;
    if (ph.paragraph.wanted.len != 0) win.fonts.request(ph.paragraph.wanted);
    ph.layout = text.Layout.init(win.gpa, win.scratch.allocator(), &win.fonts.cache, &ph.paragraph, .{ .alignment = .start }) catch |err| {
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
pub fn layoutFor(win: *Window, id: NodeId, width: ?f32) error{OutOfMemory}!?*const text.Layout {
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
    const previous: ?*const text.Layout = if (c.previous) |*pr| (if (pr.layout) |*pl| pl else null) else null;
    const l = text.Layout.initReusing(win.gpa, win.scratch.allocator(), &win.fonts.cache, &c.paragraph.?, .{
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
    return &c.layout.?;
}

/// The layout the node shows at wrapping width `width` (null: unwrapped)
/// in a box `fit` wide: `layoutFor`'s, or a cut copy when the node limits
/// its lines or ellipsizes and the text does not fit.
pub fn layoutIn(win: *Window, id: NodeId, width: ?f32, fit: ?f32) error{OutOfMemory}!?*const text.Layout {
    const full = try layoutFor(win, id, width) orelse return null;
    const n = win.node(id);
    if (n.kind != .text) return full;
    const props = n.data.text.props;
    if (props.max_lines == 0 and !props.ellipsize) return full;
    const c = win.state(id).text.?;
    var last: ?usize = null;
    if (props.max_lines != 0 and full.lines.len > props.max_lines) last = props.max_lines - 1;
    if (props.ellipsize) if (fit) |f| for (full.lines, 0..) |line, i| {
        if (last != null and i >= last.?) break;
        if (line.width > f + 0.01) {
            last = i;
            break;
        }
    };
    const line_index = last orelse {
        c.shows_cut = false;
        return full;
    };
    if (c.cut != null and c.cut_fit == fit and c.cut.?.layout.lines.len == line_index + 1) {
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
    paragraph: text.ShapedParagraph,
    layout: text.Layout,

    fn deinit(ct: *Cut) void {
        ct.layout.deinit();
        ct.paragraph.deinit();
    }
};

/// Builds the cut copy: the text up to the last grapheme boundary of line
/// `last` at which it, with "…" when the node ellipsizes, still ends on
/// that line and fits in `fit`.
fn cutText(win: *Window, id: NodeId, c: *Cache, full: *const text.Layout, last: usize, width: ?f32, fit: ?f32) error{OutOfMemory}!void {
    const d = win.node(id).data.text;
    const content = full.paragraph.text;
    const line = full.lines[last];
    const a = win.scratch.allocator();
    // Grapheme edges of the line, without its trailing white space.
    var end = line.end;
    while (end > line.start and std.ascii.isWhitespace(content[end - 1])) end -= 1;
    var edges: std.ArrayList(u32) = .empty;
    try edges.append(a, line.start);
    for (full.lineCarets(line)) |k| if (k.offset > line.start and k.offset <= end) try edges.append(a, k.offset);
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
        if (ct.layout.lines.len <= last + 1 and (fit == null or ct.layout.width <= fit.? + 0.01)) {
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
    c.cut.?.layout.paragraph = &c.cut.?.paragraph;
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
    ct.layout = text.Layout.init(win.gpa, a, &win.fonts.cache, &ct.paragraph, .{
        .width = width,
        .alignment = if (d.props.alignment == .justify) .justify else .start,
        .paragraphs = try paragraphRuns(win, id),
        .tab_stops = d.props.tab_stops,
        .break_words = d.props.break_words,
        .hyphenate = d.props.hyphenate,
        .hyphenation = &win.fonts.hyphenation,
        .optimal = d.props.optimal,
    }) catch |err| switch (err) {
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
    const shown: u32 = @intCast(win.state(id).text.?.paragraph.?.text.len);
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
pub fn current(win: *const Window, id: NodeId) ?*const text.Layout {
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
