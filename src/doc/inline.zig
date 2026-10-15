//! Inline layout (CSS 2.1 10.8, CSS Inline 3, CSS Text 3 and 4): an
//! inline formatting context's text is shaped once with siv's text engine
//! (`text.ShapedParagraph`: bidi, segmentation, fallback, shaping with
//! full context); each width breaks it into line boxes, greedily, balanced
//! (`text-wrap: balance`), or by Knuth and Plass (`text-wrap: pretty`),
//! with hyphenation, inline box edges, atomic inlines, line heights from
//! the strut and inline boxes, vertical-align, text-align and
//! justification, and UAX #9 reordering per line.
//!
//! Shaping and lines are caches that the document may drop and rebuild
//! (bounded memory); only an IFC's height and baselines must stay.

const std = @import("std");
const css = @import("css");
const text = @import("text");
const box_mod = @import("box.zig");

const Allocator = std.mem.Allocator;
const Style = css.Style;
const StyleId = Style.Id;
const BoxId = box_mod.BoxId;
const FontId = text.FontId;
const Error = error{OutOfMemory};

/// A style's fonts, resolved by the document before layout.
pub const FontInfo = struct {
    chain: []const FontId = &.{},
    size: f32 = 16,
    language: []const u8 = "und",
    /// The primary font's metrics at `size`.
    ascent: f32 = 12.8,
    descent: f32 = 3.2,
    x_height: f32 = 8,
    /// The primary font (for a hyphen's glyph), if ready.
    primary: ?FontId = null,
};

pub const Fonts = struct {
    cache: *const text.FontCache,
    hyphenation: ?*text.hyphen.Hyphenation = null,
    ctx: *const anyopaque,
    infoFn: *const fn (ctx: *const anyopaque, StyleId) *const FontInfo,

    pub fn info(f: Fonts, s: StyleId) *const FontInfo {
        return f.infoFn(f.ctx, s);
    }
};

/// What lines need from the rest of layout: atomic inline sizes.
pub const Atomics = struct {
    ctx: *anyopaque,
    /// The margin box of an atomic inline laid out for `avail` (its
    /// width, height, and baseline from its margin-box top).
    sizeFn: *const fn (ctx: *anyopaque, BoxId, avail: f32) Error!AtomicSize,
    /// Intrinsic margin-box widths (min-content or max-content).
    intrinsicFn: *const fn (ctx: *anyopaque, BoxId, max: bool) Error!f32,
};

pub const AtomicSize = struct { w: f32, h: f32, baseline: f32 };

pub const Glyph = struct { id: u32, x: f32, y: f32, cluster: u32 };

pub const Frag = struct {
    kind: Kind,
    /// From the IFC's content-box left edge.
    x: f32,
    w: f32,
    /// The fragment's baseline below the line's baseline.
    shift: f32 = 0,
    style: StyleId,
    font: FontId = undefined,
    size: f32 = 0,
    glyph_start: u32 = 0,
    glyph_end: u32 = 0,
    start: u32,
    end: u32,
    inline_box: u32 = box_mod.none,
    /// atomic: the box.
    box: BoxId = box_mod.none,
    rtl: bool = false,

    pub const Kind = enum(u8) { glyphs, atomic, open, close };
};

pub const Line = struct {
    start: u32,
    end: u32,
    /// Top of the line box from the IFC content-box top.
    top: f32,
    height: f32,
    /// The baseline from the IFC content-box top.
    baseline: f32,
    frag_start: u32,
    frag_end: u32,
    /// Ink extent of the line's content (left edge and width).
    left: f32,
    width: f32,
};

/// The width-independent part, kept while memory allows.
pub const Shaped = struct {
    para: text.ShapedParagraph,
    /// The fonts used are all ready (no reshaping pending).
    complete: bool,

    pub fn deinit(s: *Shaped) void {
        s.para.deinit();
    }

    pub fn bytes(s: *const Shaped) usize {
        return s.para.bytes();
    }
};

/// Lines at one width.
pub const Laid = struct {
    width: f32,
    lines: []Line,
    frags: []Frag,
    glyphs: []Glyph,
    height: f32,

    pub fn deinit(l: *Laid, gpa: Allocator) void {
        gpa.free(l.lines);
        gpa.free(l.frags);
        gpa.free(l.glyphs);
    }

    pub fn bytes(l: *const Laid) usize {
        return l.lines.len * @sizeOf(Line) + l.frags.len * @sizeOf(Frag) + l.glyphs.len * @sizeOf(Glyph);
    }

    pub fn firstBaseline(l: *const Laid) ?f32 {
        return if (l.lines.len > 0) l.lines[0].baseline else null;
    }

    pub fn lastBaseline(l: *const Laid) ?f32 {
        return if (l.lines.len > 0) l.lines[l.lines.len - 1].baseline else null;
    }

    pub fn lineFrags(l: *const Laid, line: Line) []const Frag {
        return l.frags[line.frag_start..line.frag_end];
    }

    pub fn fragGlyphs(l: *const Laid, f: Frag) []const Glyph {
        return l.glyphs[f.glyph_start..f.glyph_end];
    }
};

/// Shapes an IFC's text with its styles' fonts.
pub fn shape(gpa: Allocator, scratch: Allocator, ifc: *const box_mod.Ifc, fonts: Fonts, store: *const css.style.Store) Error!Shaped {
    var runs: std.ArrayList(text.StyleRun) = .empty;
    for (ifc.runs) |r| {
        const fi = fonts.info(r.style);
        const s: text.Style = .{ .fonts = fi.chain, .size = fi.size, .language = fi.language };
        if (runs.items.len > 0) {
            const last = &runs.items[runs.items.len - 1];
            if (last.style.fonts.ptr == s.fonts.ptr and last.style.fonts.len == s.fonts.len and last.style.size == s.size and std.mem.eql(u8, last.style.language, s.language)) {
                last.end = r.end;
                continue;
            }
        }
        try runs.append(scratch, .{ .end = r.end, .style = s });
    }
    if (runs.items.len == 0) try runs.append(scratch, .{ .end = @intCast(ifc.text.len), .style = .{ .fonts = fonts.info(ifc.style).chain, .size = fonts.info(ifc.style).size } });
    const st = store.get(ifc.style);
    const dir: text.BaseDirection = if (st.inh.direction == .rtl) .rtl else .ltr;
    const para = text.ShapedParagraph.init(gpa, scratch, fonts.cache, ifc.text, runs.items, dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Text from the box tree is valid UTF-8 within limits; styles
        // always cover it.
        else => return error.OutOfMemory,
    };
    return .{ .para = para, .complete = para.wanted.len == 0 };
}

/// Lays out an IFC at `width` (its content box).
pub const Context = struct {
    gpa: Allocator,
    scratch: Allocator,
    ifc: *const box_mod.Ifc,
    shaped: *const Shaped,
    fonts: Fonts,
    store: *const css.style.Store,
    atomics: Atomics,
    tree: *const box_mod.Tree,
    /// Floats beside the IFC (CSS 2.1 9.5): their margin boxes in its
    /// content coordinates; lines next to them are shortened.
    floats: []const FloatRect = &.{},
};

const Unit = struct {
    /// Text range; `end` is a break opportunity (or the text's end).
    start: u32,
    end: u32,
    /// Width including trailing white space, and that white space.
    advance: f32,
    trailing: f32,
    mandatory: bool,
    /// Where an overflowing unit may break inside (overflow-wrap,
    /// break-all, hyphens).
    breakable: bool,
};

/// A float's margin box beside an IFC.
pub const FloatRect = struct { x0: f32, y0: f32, x1: f32, y1: f32, left: bool, box: u32 = box_mod.none };

/// The inset and width a line from `top` to `top + h` has beside floats.
pub fn lineSpace(floats: []const FloatRect, width: f32, top: f32, h: f32) [2]f32 {
    var l: f32 = 0;
    var r: f32 = width;
    for (floats) |f| {
        if (f.y1 <= top or f.y0 >= top + h) continue;
        if (f.left) l = @max(l, f.x1) else r = @min(r, f.x0);
    }
    return .{ l, @max(0, r - l) };
}

const Builder = struct {
    cx: *const Context,
    width: f32,
    /// Per line beside floats: inset and width (beyond the list, none).
    spaces: []const [2]f32 = &.{},
    /// Lines broken so far by `greedy` (it restarts after hyphenating).
    greedy_line: usize = 0,

    lines: std.ArrayList(Line) = .empty,
    frags: std.ArrayList(Frag) = .empty,
    glyphs: std.ArrayList(Glyph) = .empty,
    atomic_sizes: std.AutoHashMapUnmanaged(BoxId, AtomicSize) = .empty,
    /// Per inline box: its baseline shift from its parent's (sum down
    /// the chain), and its A/D (CSS 2.1 10.8.1).
    ib_shift: []f32 = &.{},
    used_items: []bool = &.{},
    hyphen_after: ?u32 = null,

    fn space(b: *const Builder, line: usize) [2]f32 {
        return if (line < b.spaces.len) b.spaces[line] else .{ 0, b.width };
    }

    fn para(b: *const Builder) *const text.ShapedParagraph {
        return &b.cx.shaped.para;
    }

    fn style(b: *const Builder, s: StyleId) *const Style {
        return b.cx.store.get(s);
    }
};

/// The width an inline box edge adds: margin, border, and padding on one
/// side (`start`: left).
fn edge(st: *const Style, start: bool, basis: f32) f32 {
    const side: usize = if (start) 3 else 1;
    return st.box.margin[side].resolve(basis) + st.borderWidth(side) + st.box.padding[side].resolve(basis);
}

/// The style of the text at `at`: its run's, or the IFC's without runs
/// (only atomic inlines).
fn runStyle(ifc: *const box_mod.Ifc, at: u32) StyleId {
    if (ifc.runs.len == 0) return ifc.style;
    return ifc.runs[runStyleAt(ifc, at)].style;
}

fn runStyleAt(ifc: *const box_mod.Ifc, at: u32) usize {
    var lo: usize = 0;
    var hi: usize = ifc.runs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ifc.runs[mid].end <= at) lo = mid + 1 else hi = mid;
    }
    return @min(lo, ifc.runs.len -| 1);
}

/// The glyphs of shaped run `r` whose clusters fall in `from..to`, in the
/// run's (visual) order.
fn runGlyphs(p: *const text.ShapedParagraph, r: text.paragraph.Run, from: u32, to: u32) []const text.shape.Glyph {
    const g = p.runGlyphs(r);
    if (g.len == 0) return g;
    // Clusters increase (LTR) or decrease (RTL) along the run.
    var lo: usize = 0;
    var hi: usize = g.len;
    if (!r.rtl()) {
        while (lo < g.len and g[lo].cluster < from) lo += 1;
        hi = lo;
        while (hi < g.len and g[hi].cluster < to) hi += 1;
    } else {
        while (lo < g.len and g[lo].cluster >= to) lo += 1;
        hi = lo;
        while (hi < g.len and g[hi].cluster >= from) hi += 1;
    }
    return g[lo..hi];
}

fn shapedAdvance(p: *const text.ShapedParagraph, from: u32, to: u32) f32 {
    var w: f32 = 0;
    for (p.runs) |r| {
        if (r.end <= from) continue;
        if (r.start >= to) break;
        for (runGlyphs(p, r, @max(from, r.start), @min(to, r.end))) |g| w += g.advance;
    }
    return w;
}

/// Break units: segments merged where wrapping is off, with atomic and
/// inline-edge widths and spacing added.
fn units(b: *Builder, intrinsic_mode: ?bool) Error![]Unit {
    const cx = b.cx;
    const p = b.para();
    const ifc = cx.ifc;
    var out: std.ArrayList(Unit) = .empty;
    var item_i: usize = 0;
    var start: u32 = 0;
    var pending: ?Unit = null;
    for (p.segments) |seg| {
        var u: Unit = .{ .start = start, .end = seg.end, .advance = seg.advance, .trailing = seg.trailing, .mandatory = seg.mandatory, .breakable = false };
        // Items in this segment.
        while (item_i < ifc.items.len and ifc.items[item_i].offset < seg.end) : (item_i += 1) {
            const it = ifc.items[item_i];
            if (it.offset < start) continue;
            switch (it.kind) {
                .atomic => {
                    const bx = cx.tree.get(it.index);
                    if (bx.out_of_flow or bx.inline_float) continue;
                    const w = if (intrinsic_mode) |max| try cx.atomics.intrinsicFn(cx.atomics.ctx, it.index, max) else (try atomic(b, it.index)).w;
                    u.advance += w - shapedAdvance(p, it.offset, it.offset + 3);
                },
                .open => u.advance += edge(b.style(ifc.inline_boxes[it.index].style), true, b.width),
                .close => u.advance += edge(b.style(ifc.inline_boxes[it.index].style), false, b.width),
            }
        }
        // Closing edges right at the segment end belong to it.
        while (item_i < ifc.items.len and ifc.items[item_i].offset == seg.end and ifc.items[item_i].kind == .close) : (item_i += 1) {
            u.advance += edge(b.style(ifc.inline_boxes[ifc.items[item_i].index].style), false, b.width);
        }
        const rs = cx.store.get(runStyle(ifc, seg.end -| 1));
        // Letter and word spacing.
        if (rs.inh.letter_spacing != 0 or rs.inh.word_spacing != 0) {
            var n_chars: f32 = 0;
            var n_spaces: f32 = 0;
            for (ifc.text[start..seg.end]) |ch| {
                if (ch & 0xC0 != 0x80) n_chars += 1;
                if (ch == ' ') n_spaces += 1;
            }
            u.advance += n_chars * rs.inh.letter_spacing + n_spaces * rs.inh.word_spacing;
        }
        u.breakable = rs.inh.overflow_wrap != .normal or rs.inh.word_break == .break_all or rs.inh.word_break == .break_word or rs.inh.hyphens == .auto;
        start = seg.end;
        // No wrapping inside nowrap text: join with the next unit.
        const nowrap = rs.inh.text_wrap_mode == .nowrap and !seg.mandatory;
        if (pending) |*pu| {
            pu.end = u.end;
            pu.advance += u.advance;
            pu.trailing = u.trailing;
            pu.mandatory = u.mandatory;
            pu.breakable = pu.breakable or u.breakable;
            if (!nowrap) {
                try out.append(cx.scratch, pu.*);
                pending = null;
            }
        } else if (nowrap) {
            pending = u;
        } else try out.append(cx.scratch, u);
    }
    if (pending) |pu| try out.append(cx.scratch, pu);
    return out.items;
}

fn atomic(b: *Builder, id: BoxId) Error!AtomicSize {
    if (b.atomic_sizes.get(id)) |s| return s;
    const s = try b.cx.atomics.sizeFn(b.cx.atomics.ctx, id, b.width);
    try b.atomic_sizes.put(b.cx.scratch, id, s);
    return s;
}

/// Intrinsic widths of an IFC: the widest unbreakable unit and the widest
/// line between forced breaks.
pub fn intrinsic(cx: *const Context) Error![2]f32 {
    var b: Builder = .{ .cx = cx, .width = 0 };
    const us_min = try units(&b, false);
    var min: f32 = 0;
    for (us_min) |u| min = @max(min, u.advance - u.trailing);
    const us_max = try units(&b, true);
    var max: f32 = 0;
    var line: f32 = 0;
    for (us_max) |u| {
        line += u.advance;
        if (u.mandatory) {
            max = @max(max, line - u.trailing);
            line = 0;
        }
    }
    max = @max(max, line - if (us_max.len > 0) us_max[us_max.len - 1].trailing else 0);
    const indent = cx.store.get(cx.ifc.style).inh.text_indent.resolve(0);
    return .{ min + @max(0, indent), max + indent };
}

const Break = struct { at: u32, hyphen: bool = false };

/// Greedy breaks at `width` (the first line narrower by `indent`).
fn greedy(b: *Builder, us: []const Unit, width: f32, indent: f32, out: *std.ArrayList(Break)) Error!void {
    var x: f32 = 0;
    var first_line = true;
    var i: usize = 0;
    var line_start: usize = 0;
    while (i < us.len) {
        const u = us[i];
        const limit = (if (b.spaces.len > 0) b.space(b.greedy_line)[1] else width) - if (first_line) indent else 0;
        if (i > line_start and x + u.advance - u.trailing > limit + 0.01) {
            // Break before this unit, unless hyphenation fits part of it.
            if (u.breakable) if (try hyphenate(b, u, limit - x)) |at| {
                try out.append(b.cx.scratch, .{ .at = at, .hyphen = true });
                b.greedy_line += 1;
                x = 0;
                first_line = false;
                // The rest of the unit starts the next line.
                var rest = u;
                rest.start = at;
                rest.advance = u.advance - shapedAdvance(b.para(), u.start, at);
                const merged = try b.cx.scratch.dupe(Unit, us);
                merged[i] = rest;
                return greedyFrom(b, merged, i, width, out);
            };
            try out.append(b.cx.scratch, .{ .at = u.start });
            b.greedy_line += 1;
            x = 0;
            first_line = false;
            line_start = i;
            continue;
        }
        if (i == line_start and u.advance - u.trailing > limit + 0.01 and u.breakable) {
            // A unit too wide alone: hyphenate, or break between graphemes.
            if (try hyphenate(b, u, limit)) |at| {
                try out.append(b.cx.scratch, .{ .at = at, .hyphen = true });
                b.greedy_line += 1;
                var rest = u;
                rest.start = at;
                rest.advance = u.advance - shapedAdvance(b.para(), u.start, at);
                const merged = try b.cx.scratch.dupe(Unit, us);
                merged[i] = rest;
                return greedyFromState(b, merged, i, width, out, false);
            }
            const style = b.style(runStyle(b.cx.ifc, u.start));
            if (style.inh.overflow_wrap != .normal or style.inh.word_break == .break_all or style.inh.word_break == .break_word) {
                const at = graphemeFit(b, u.start, u.end - trailingBytes(b.cx.ifc.text[u.start..u.end]), limit);
                if (at > u.start and at < u.end) {
                    try out.append(b.cx.scratch, .{ .at = at });
                    b.greedy_line += 1;
                    var rest = u;
                    rest.start = at;
                    rest.advance = u.advance - shapedAdvance(b.para(), u.start, at);
                    const merged = try b.cx.scratch.dupe(Unit, us);
                    merged[i] = rest;
                    return greedyFromState(b, merged, i, width, out, false);
                }
            }
        }
        x += u.advance;
        i += 1;
        if (u.mandatory) {
            try out.append(b.cx.scratch, .{ .at = u.end });
            b.greedy_line += 1;
            x = 0;
            first_line = false;
            line_start = i;
        }
    }
}

fn greedyFrom(b: *Builder, us: []const Unit, from: usize, width: f32, out: *std.ArrayList(Break)) Error!void {
    return greedyFromState(b, us, from, width, out, false);
}

fn greedyFromState(b: *Builder, us: []const Unit, from: usize, width: f32, out: *std.ArrayList(Break), first: bool) Error!void {
    _ = first;
    return greedy(b, us[from..], width, 0, out);
}

fn trailingBytes(s: []const u8) u32 {
    var n: u32 = 0;
    var i = s.len;
    while (i > 0 and (s[i - 1] == ' ' or s[i - 1] == '\n')) : (i -= 1) n += 1;
    return n;
}

/// The last grapheme boundary in `from..to` before which the text fits.
fn graphemeFit(b: *Builder, from: u32, to: u32, limit: f32) u32 {
    const p = b.para();
    var at = from;
    var w: f32 = 0;
    while (at < to) {
        const next = @min(to, p.graphemes.after(at) orelse to);
        const gw = shapedAdvance(p, at, next);
        if (at > from and w + gw > limit) return at;
        w += gw;
        at = next;
    }
    return to;
}

/// The last hyphenation point in a unit where its start and a hyphen fit
/// in `room`.
fn hyphenate(b: *Builder, u: Unit, room: f32) Error!?u32 {
    var points: std.ArrayList(u32) = .empty;
    try hyphenPoints(b, u, &points);
    const hw = hyphenWidth(b, u.start) orelse return null;
    var k = points.items.len;
    while (k > 0) {
        k -= 1;
        const at = points.items[k];
        if (shapedAdvance(b.para(), u.start, at) + hw <= room) return at;
    }
    return null;
}

/// The hyphenation points of a unit's word (`hyphens: auto`), as text
/// offsets in increasing order, on grapheme boundaries.
fn hyphenPoints(b: *Builder, u: Unit, out: *std.ArrayList(u32)) Error!void {
    const cx = b.cx;
    const h = cx.fonts.hyphenation orelse return;
    const ifc = cx.ifc;
    const rs = b.style(runStyle(ifc, u.start));
    if (rs.inh.hyphens != .auto) return;
    const fi = cx.fonts.info(runStyle(ifc, u.start));
    const hyph = (try h.get(fi.language)) orelse return;
    const s = ifc.text[u.start..u.end];
    // The word: letters from the start (skip leading punctuation).
    var ws: usize = 0;
    while (ws < s.len and !std.ascii.isAlphabetic(s[ws]) and s[ws] < 0x80) ws += 1;
    var we = ws;
    while (we < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[we]) catch 1;
        const cp = std.unicode.utf8Decode(s[we..@min(s.len, we + l)]) catch 0;
        if (!text.hyphen.isWordChar(cp)) break;
        we += l;
    }
    if (we - ws < 4) return;
    var points: std.ArrayList(u32) = .empty;
    hyph.points(cx.scratch, s[ws..we], &points, cx.scratch) catch return;
    for (points.items) |pt| {
        const at: u32 = u.start + @as(u32, @intCast(ws)) + pt;
        if (b.para().graphemes.atOrBefore(at) != at) continue;
        try out.append(cx.scratch, at);
    }
}

fn hyphenWidth(b: *const Builder, at: u32) ?f32 {
    const ifc = b.cx.ifc;
    const fi = b.cx.fonts.info(runStyle(ifc, at));
    const id = fi.primary orelse return null;
    const face = b.cx.fonts.cache.face(id) orelse return null;
    const g = face.nominalGlyph(0x2010) orelse face.nominalGlyph('-') orelse return null;
    return face.advance(g, fi.size);
}

/// Knuth and Plass over units (and hyphenation points).
fn pretty(b: *Builder, us: []const Unit, width: f32, indent: f32, out: *std.ArrayList(Break)) Error!void {
    const scratch = b.cx.scratch;
    var cands: std.ArrayList(text.knuth_plass.Candidate) = .empty;
    try cands.append(scratch, .{ .at = 0, .w_end = 0, .w_next = 0, .s_end = 0, .s_next = 0 });
    var w: f64 = 0;
    var s: f64 = 0;
    var points: std.ArrayList(u32) = .empty;
    for (us, 0..) |u, j| {
        const hanging: f64 = u.trailing;
        // Hyphenation points inside the unit, at a penalty that keeps them
        // for lines that would be loose without them.
        if (u.breakable) {
            points.clearRetainingCapacity();
            try hyphenPoints(b, u, &points);
            if (points.items.len > 0) if (hyphenWidth(b, u.start)) |hw| for (points.items) |pt| {
                const part: f64 = shapedAdvance(b.para(), u.start, pt);
                try cands.append(scratch, .{ .at = pt, .w_end = w + part, .w_next = w + part, .s_end = s, .s_next = s, .hyphen = hw, .penalty = 100 });
            };
        }
        try cands.append(scratch, .{
            .at = u.end,
            .w_end = w + u.advance - hanging,
            .w_next = w + u.advance,
            .s_end = s,
            .s_next = s + hanging / 2,
            .forced = u.mandatory or j + 1 == us.len,
        });
        w += u.advance;
        s += hanging / 2;
    }
    const Ctx = struct { width: f64, indent: f64 };
    const chain = try text.knuth_plass.breaks(scratch, cands.items, Ctx{ .width = width, .indent = indent }, struct {
        fn f(c: Ctx, at: u32) f64 {
            return if (at == 0) c.width - c.indent else c.width;
        }
    }.f);
    for (chain) |k| try out.append(scratch, .{ .at = cands.items[k].at, .hyphen = cands.items[k].hyphen != null });
}

/// Lays out the IFC at a content width.
pub fn layout(cx: *const Context, width: f32) Error!Laid {
    var b: Builder = .{ .cx = cx, .width = width };
    const ifc = cx.ifc;
    const root_style = cx.store.get(ifc.style);
    const us = try units(&b, null);
    const indent = root_style.inh.text_indent.resolve(width);
    var breaks: std.ArrayList(Break) = .empty;
    const wrap_style = root_style.inh.text_wrap_style;
    if (cx.floats.len > 0) {
        // Beside floats: greedy lines, each as wide as the space at its
        // place. Lines are placed first at the strut's height, then again
        // at the tops and heights that placement found.
        const fi = cx.fonts.info(ifc.style);
        const strut = root_style.lineHeightPx(fi.ascent + fi.descent);
        var spaces: std.ArrayList([2]f32) = .empty;
        for (0..us.len + 1) |li| try spaces.append(cx.scratch, lineSpace(cx.floats, width, @as(f32, @floatFromInt(li)) * strut, strut));
        b.spaces = spaces.items;
        b.greedy_line = 0;
        try greedy(&b, us, width, indent, &breaks);
        const trial = try layoutLines(&b, breaks.items);
        var refined: std.ArrayList([2]f32) = .empty;
        for (trial.lines.items, 0..) |line, li| {
            _ = li;
            try refined.append(cx.scratch, lineSpace(cx.floats, width, line.top, line.height));
        }
        // Lines beyond the first placement keep the strut estimate.
        const known = refined.items.len;
        const last_top: f32 = if (known > 0) trial.lines.items[known - 1].top + trial.lines.items[known - 1].height else 0;
        for (0..us.len + 1) |k| try refined.append(cx.scratch, lineSpace(cx.floats, width, last_top + @as(f32, @floatFromInt(k)) * strut, strut));
        b.spaces = refined.items;
        b.greedy_line = 0;
        breaks.clearRetainingCapacity();
        try greedy(&b, us, width, indent, &breaks);
    } else if (wrap_style == .pretty and us.len > 1) {
        try pretty(&b, us, width, indent, &breaks);
    } else {
        try greedy(&b, us, width, indent, &breaks);
        if (wrap_style == .balance and breaks.items.len >= 1 and breaks.items.len <= 10) {
            // The narrowest width that keeps the line count.
            const count = breaks.items.len;
            var lo: f32 = width / 2;
            var hi: f32 = width;
            var best = try cx.scratch.dupe(Break, breaks.items);
            for (0..12) |_| {
                const mid = (lo + hi) / 2;
                var trial: std.ArrayList(Break) = .empty;
                try greedy(&b, us, mid, indent, &trial);
                if (trial.items.len <= count) {
                    hi = mid;
                    best = trial.items;
                } else lo = mid;
            }
            breaks.clearRetainingCapacity();
            try breaks.appendSlice(cx.scratch, best);
        }
    }
    const top = (try layoutLines(&b, breaks.items)).top;
    var laid: Laid = .{
        .width = width,
        .lines = try b.lines.toOwnedSlice(cx.gpa),
        .frags = undefined,
        .glyphs = undefined,
        .height = top,
    };
    errdefer cx.gpa.free(laid.lines);
    laid.frags = try b.frags.toOwnedSlice(cx.gpa);
    errdefer cx.gpa.free(laid.frags);
    laid.glyphs = try b.glyphs.toOwnedSlice(cx.gpa);
    return laid;
}

/// Places the lines `breaks` end into `b.lines`, `b.frags`, and
/// `b.glyphs` (emptied first); returns them and the height.
fn layoutLines(b: *Builder, breaks_: []const Break) Error!struct { lines: *std.ArrayList(Line), frags: *std.ArrayList(Frag), glyphs: *std.ArrayList(Glyph), top: f32 } {
    const cx = b.cx;
    const ifc = cx.ifc;
    b.lines.clearRetainingCapacity();
    b.frags.clearRetainingCapacity();
    b.glyphs.clearRetainingCapacity();
    // The text's end ends the last line.
    const n: u32 = @intCast(ifc.text.len);
    var breaks = breaks_;
    if (breaks.len == 0 or breaks[breaks.len - 1].at != n) {
        const more = try cx.scratch.alloc(Break, breaks.len + 1);
        @memcpy(more[0..breaks.len], breaks);
        more[breaks.len] = .{ .at = n };
        breaks = more;
    }
    // A final forced break leaves an empty line only for preserved text.
    try precomputeShifts(b);
    b.used_items = try cx.scratch.alloc(bool, ifc.items.len);
    @memset(b.used_items, false);
    var start: u32 = 0;
    var top: f32 = 0;
    for (breaks, 0..) |br, li| {
        if (br.at <= start and li > 0 and br.at != n) continue;
        try emitLine(b, start, br.at, br.hyphen, li == 0, &top, br.at == n);
        start = br.at;
    }
    return .{ .lines = &b.lines, .frags = &b.frags, .glyphs = &b.glyphs, .top = top };
}

fn precomputeShifts(b: *Builder) Error!void {
    const ifc = b.cx.ifc;
    b.ib_shift = try b.cx.scratch.alloc(f32, ifc.inline_boxes.len);
    for (ifc.inline_boxes, 0..) |ib, i| {
        const parent_shift: f32 = if (ib.parent != box_mod.none) b.ib_shift[ib.parent] else 0;
        const parent_style: StyleId = if (ib.parent != box_mod.none) ifc.inline_boxes[ib.parent].style else ifc.style;
        b.ib_shift[i] = parent_shift + verticalShift(b, ib.style, parent_style);
    }
}

/// An inline box's baseline below its parent's (vertical-align, the
/// baseline-relative values).
fn verticalShift(b: *const Builder, s: StyleId, parent: StyleId) f32 {
    const st = b.style(s);
    const pf = b.cx.fonts.info(parent);
    const f = b.cx.fonts.info(s);
    return switch (st.box.vertical_align) {
        .baseline, .top, .bottom => 0,
        .sub => pf.size * 0.2,
        .super => -pf.size * 0.34,
        .middle => -(pf.x_height / 2) + (f.ascent - f.descent) / 2,
        .text_top => -(pf.ascent - f.ascent),
        .text_bottom => pf.descent - f.descent,
        .length => -st.box.vertical_align_len.resolve(lineHeightOf(b, s)),
    };
}

fn lineHeightOf(b: *const Builder, s: StyleId) f32 {
    const st = b.style(s);
    const f = b.cx.fonts.info(s);
    return st.lineHeightPx(f.ascent + f.descent);
}

/// A box's (or the strut's) extent above and below its baseline,
/// half-leading included.
fn ad(b: *const Builder, s: StyleId) [2]f32 {
    const f = b.cx.fonts.info(s);
    const lh = lineHeightOf(b, s);
    const half = (lh - (f.ascent + f.descent)) / 2;
    return .{ f.ascent + half, f.descent + half };
}

const Piece = struct {
    from: u32,
    to: u32,
    run: u32,
    ifc_run: u32,
    level: u8,
};

fn emitLine(b: *Builder, start: u32, end_: u32, hyphen: bool, first: bool, top: *f32, last: bool) Error!void {
    const cx = b.cx;
    const p = b.para();
    const ifc = cx.ifc;
    var end = end_;
    // A forced break at the end: its character is not drawn.
    const frag_start: u32 = @intCast(b.frags.items.len);
    // Pieces in logical order: shaped runs split by IFC runs.
    var pieces: std.ArrayList(Piece) = .empty;
    for (p.runs, 0..) |r, ri| {
        if (r.end <= start) continue;
        if (r.start >= end) break;
        var from = @max(start, r.start);
        const to = @min(end, r.end);
        while (from < to) {
            const ir = runStyleAt(ifc, from);
            const seg_end = @min(to, ifc.runs[ir].end);
            try pieces.append(cx.scratch, .{ .from = from, .to = seg_end, .run = @intCast(ri), .ifc_run = @intCast(ir), .level = r.level });
            from = seg_end;
        }
    }
    // L1 and L2 on the line.
    if (end > start and pieces.items.len > 0) {
        const pi = p.paragraphAt(start);
        const base = p.paragraphs[pi].base_level;
        const levels = try cx.scratch.alloc(u8, end - start);
        text.bidi.lineLevels(p.levels[start..end], p.classes[start..end], base, levels);
        var split: std.ArrayList(Piece) = .empty;
        for (pieces.items) |pc| {
            var from = pc.from;
            while (from < pc.to) {
                const lv = levels[from - start];
                var to = from + 1;
                while (to < pc.to and levels[to - start] == lv) to += 1;
                var q = pc;
                q.from = from;
                q.to = to;
                q.level = lv;
                try split.append(cx.scratch, q);
                from = to;
            }
        }
        pieces = split;
    }
    const order = try cx.scratch.alloc(u32, pieces.items.len);
    if (pieces.items.len > 0) {
        const lv = try cx.scratch.alloc(u8, pieces.items.len);
        for (lv, pieces.items) |*l, pc| l.* = pc.level;
        text.bidi.reorder(lv, order);
    }
    // Place fragments.
    var pen: f32 = 0;
    var item_cursor: usize = 0;
    while (item_cursor < ifc.items.len and ifc.items[item_cursor].offset < start) item_cursor += 1;
    // Opening edges of inline boxes that started on earlier lines do not
    // repeat (box-decoration-break: slice).
    for (order) |oi| {
        const pc = pieces.items[oi];
        const r = p.runs[pc.run];
        const run_style = ifc.runs[pc.ifc_run].style;
        const ib = ifc.runs[pc.ifc_run].inline_box;
        const st = b.style(run_style);
        // Opening edges at this piece's start.
        for (ifc.items, 0..) |it, k| {
            if (b.used_items[k] or it.kind != .open or it.offset != pc.from) continue;
            if (it.offset < start or it.offset >= end) continue;
            b.used_items[k] = true;
            const w = edge(b.style(ifc.inline_boxes[it.index].style), true, b.width);
            try b.frags.append(cx.gpa, .{ .kind = .open, .x = pen, .w = w, .style = ifc.inline_boxes[it.index].style, .start = it.offset, .end = it.offset, .inline_box = it.index, .shift = b.ib_shift[it.index] });
            pen += w;
        }
        const gs = runGlyphs(p, r, pc.from, pc.to);
        const fi = cx.fonts.info(run_style);
        var frag: Frag = .{
            .kind = .glyphs,
            .x = pen,
            .w = 0,
            .style = run_style,
            .font = r.font,
            .size = p.styles[r.style].size,
            .glyph_start = @intCast(b.glyphs.items.len),
            .start = pc.from,
            .end = pc.to,
            .inline_box = ib,
            .rtl = r.rtl(),
            .shift = if (ib != box_mod.none) b.ib_shift[ib] else 0,
        };
        _ = fi;
        var gx: f32 = 0;
        for (gs, 0..) |g, gi| {
            // An atomic inline's placeholder.
            if (ifc.text.len >= g.cluster + 3 and std.mem.eql(u8, ifc.text[g.cluster..][0..3], "\u{FFFC}")) {
                // Close the text fragment, add the atomic one.
                if (b.glyphs.items.len > frag.glyph_start) {
                    frag.glyph_end = @intCast(b.glyphs.items.len);
                    frag.w = gx;
                    try b.frags.append(cx.gpa, frag);
                }
                pen += gx;
                gx = 0;
                const atom_box = for (ifc.items) |it| {
                    if (it.kind == .atomic and it.offset == g.cluster and !cx.tree.get(it.index).out_of_flow) break it.index;
                } else box_mod.none;
                if (atom_box != box_mod.none) {
                    const sz = try atomic(b, atom_box);
                    const ast = b.style(cx.tree.get(atom_box).style);
                    try b.frags.append(cx.gpa, .{ .kind = .atomic, .x = pen, .w = sz.w, .style = cx.tree.get(atom_box).style, .start = g.cluster, .end = g.cluster + 3, .box = atom_box, .inline_box = ib, .shift = (if (ib != box_mod.none) b.ib_shift[ib] else 0) + verticalShift(b, cx.tree.get(atom_box).style, run_style) * @as(f32, if (ast.box.vertical_align == .middle) 0 else 1) });
                    pen += sz.w;
                }
                frag.x = pen;
                frag.glyph_start = @intCast(b.glyphs.items.len);
                continue;
            }
            try b.glyphs.append(cx.gpa, .{ .id = g.id, .x = gx + g.x_offset, .y = g.y_offset, .cluster = g.cluster });
            gx += g.advance;
            if (st.inh.letter_spacing != 0) {
                const next_cluster = if (gi + 1 < gs.len) gs[gi + 1].cluster else std.math.maxInt(u32);
                if (next_cluster != g.cluster) gx += st.inh.letter_spacing;
            }
            if (st.inh.word_spacing != 0 and ifc.text[g.cluster] == ' ') gx += st.inh.word_spacing;
        }
        frag.glyph_end = @intCast(b.glyphs.items.len);
        frag.w = gx;
        if (frag.glyph_end > frag.glyph_start) try b.frags.append(cx.gpa, frag);
        pen += gx;
        // Closing edges at this piece's end.
        for (ifc.items, 0..) |it, k| {
            if (b.used_items[k] or it.kind != .close or it.offset != pc.to) continue;
            if (it.offset <= start and start != end) continue;
            b.used_items[k] = true;
            const w = edge(b.style(ifc.inline_boxes[it.index].style), false, b.width);
            try b.frags.append(cx.gpa, .{ .kind = .close, .x = pen, .w = w, .style = ifc.inline_boxes[it.index].style, .start = it.offset, .end = it.offset, .inline_box = it.index, .shift = b.ib_shift[it.index] });
            pen += w;
        }
    }
    // Edges of empty inline boxes on this line (opened and closed with
    // nothing between).
    for (ifc.items, 0..) |it, k| {
        if (b.used_items[k] or it.offset < start or it.offset > end) continue;
        if (it.offset == end and !last and it.kind == .open) continue;
        if (it.kind == .atomic) continue;
        if (it.offset == start and start != 0 and it.kind == .close and pieces.items.len > 0) continue;
        b.used_items[k] = true;
        const w = edge(b.style(ifc.inline_boxes[it.index].style), it.kind == .open, b.width);
        try b.frags.append(cx.gpa, .{ .kind = if (it.kind == .open) .open else .close, .x = pen, .w = w, .style = ifc.inline_boxes[it.index].style, .start = it.offset, .end = it.offset, .inline_box = it.index, .shift = b.ib_shift[it.index] });
        pen += w;
    }
    // A hyphen ends a line broken inside a word.
    if (hyphen) {
        const at = end;
        const fi = cx.fonts.info(runStyle(ifc, at -| 1));
        if (fi.primary) |fid| if (cx.fonts.cache.face(fid)) |face| {
            if (face.nominalGlyph(0x2010) orelse face.nominalGlyph('-')) |g| {
                const gs: u32 = @intCast(b.glyphs.items.len);
                try b.glyphs.append(cx.gpa, .{ .id = g, .x = 0, .y = 0, .cluster = at -| 1 });
                const w = face.advance(g, fi.size);
                const ir = runStyleAt(ifc, at -| 1);
                try b.frags.append(cx.gpa, .{ .kind = .glyphs, .x = pen, .w = w, .style = ifc.runs[ir].style, .font = fid, .size = fi.size, .glyph_start = gs, .glyph_end = gs + 1, .start = at, .end = at, .inline_box = ifc.runs[ir].inline_box, .shift = if (ifc.runs[ir].inline_box != box_mod.none) b.ib_shift[ifc.runs[ir].inline_box] else 0 });
                pen += w;
            }
        };
    }
    const frag_end: u32 = @intCast(b.frags.items.len);
    // Hanging white space at the line end (and the break itself).
    const tail = trailingWidth(b, start, end, frag_start, frag_end);
    end = end_;
    // Vertical metrics: the strut and every box on the line.
    var above: f32 = 0;
    var below: f32 = 0;
    {
        const s = ad(b, ifc.style);
        above = s[0];
        below = s[1];
    }
    var top_aligned: f32 = 0;
    for (b.frags.items[frag_start..frag_end]) |*f| switch (f.kind) {
        .atomic => {
            const sz = try atomic(b, f.box);
            const ast = b.style(cx.tree.get(f.box).style);
            switch (ast.box.vertical_align) {
                .top, .bottom => top_aligned = @max(top_aligned, sz.h),
                .middle => {
                    const pf = cx.fonts.info(f.style);
                    _ = pf;
                    const parent_info = cx.fonts.info(if (f.inline_box != box_mod.none) ifc.inline_boxes[f.inline_box].style else ifc.style);
                    // Midpoint at the parent's baseline + half x-height.
                    const mid = f.shift - parent_info.x_height / 2;
                    above = @max(above, -(mid - sz.h / 2));
                    below = @max(below, mid + sz.h / 2);
                    f.shift = mid + sz.h / 2 - (sz.h - sz.baseline) - 0;
                    f.shift = mid - sz.h / 2 + sz.baseline;
                },
                else => {
                    above = @max(above, sz.baseline - f.shift);
                    below = @max(below, sz.h - sz.baseline + f.shift);
                },
            }
        },
        else => {
            const s = if (f.inline_box != box_mod.none) ifc.inline_boxes[f.inline_box].style else f.style;
            const st = b.style(s);
            // Text straight in the block sits on the baseline: the
            // block's own vertical-align (a table cell's) is not the text's.
            if (f.inline_box != box_mod.none and (st.box.vertical_align == .top or st.box.vertical_align == .bottom)) {
                const x = ad(b, s);
                top_aligned = @max(top_aligned, x[0] + x[1]);
                continue;
            }
            const x = ad(b, s);
            above = @max(above, x[0] - f.shift);
            below = @max(below, x[1] + f.shift);
            if (f.kind == .glyphs and f.style != s) {
                const y = ad(b, f.style);
                above = @max(above, y[0] - f.shift);
                below = @max(below, y[1] + f.shift);
            }
        },
    };
    var height = above + below;
    if (top_aligned > height) {
        below += top_aligned - height;
        height = top_aligned;
    }
    // top/bottom aligned boxes: placed against the line box.
    for (b.frags.items[frag_start..frag_end]) |*f| {
        if (f.kind != .atomic and f.inline_box == box_mod.none) continue;
        const s = if (f.kind == .atomic) cx.tree.get(f.box).style else ifc.inline_boxes[f.inline_box].style;
        const st = b.style(s);
        switch (st.box.vertical_align) {
            .top => if (f.kind == .atomic) {
                const sz = try atomic(b, f.box);
                f.shift = -above + sz.baseline;
            } else {
                f.shift = -above + ad(b, s)[0];
            },
            .bottom => if (f.kind == .atomic) {
                const sz = try atomic(b, f.box);
                f.shift = below - (sz.h - sz.baseline);
            } else {
                f.shift = below - ad(b, s)[1];
            },
            else => {},
        }
    }
    // Horizontal alignment.
    const content_w = pen - tail;
    const line_indent: f32 = if (first) b.style(ifc.style).inh.text_indent.resolve(b.width) else 0;
    const rtl = b.style(ifc.style).inh.direction == .rtl;
    const forced_end = end > start and (ifc.text[end - 1] == '\n' or std.mem.endsWith(u8, ifc.text[start..end], "\u{2028}"));
    const is_last = last or forced_end;
    var al = switch (b.style(ifc.style).inh.text_align) {
        .legacy_left => .left,
        .legacy_right => .right,
        .legacy_center => .center,
        else => |x| x,
    };
    if (is_last and al == .justify) {
        al = switch (b.style(ifc.style).inh.text_align_last) {
            .auto, .start => .start,
            .end => .end,
            .left => .left,
            .right => .right,
            .center => .center,
            .justify => .justify,
        };
    }
    // Beside floats, the line's own space.
    const sp = b.space(b.lines.items.len);
    const lw = sp[1];
    const avail = lw - line_indent;
    const free = avail - content_w;
    var offset: f32 = if (rtl) lw - line_indent - content_w else line_indent;
    switch (al) {
        .start, .match_parent, .legacy_left, .legacy_right, .legacy_center => {},
        .end => offset = if (rtl) 0 else line_indent + free,
        .left => offset = if (rtl) 0 else line_indent,
        .right => offset = if (rtl) lw - content_w else line_indent + free,
        .center => offset = (if (rtl) 0 else line_indent) + free / 2,
        .justify => if (free > 0) {
            // Widen spaces before the hanging tail.
            var spaces: f32 = 0;
            for (b.frags.items[frag_start..frag_end]) |f| if (f.kind == .glyphs) {
                for (b.glyphs.items[f.glyph_start..f.glyph_end]) |g| if (g.cluster < end - trailingBytes(ifc.text[start..end]) and ifc.text[g.cluster] == ' ') {
                    spaces += 1;
                };
            };
            if (spaces > 0) {
                const per = free / spaces;
                var shift: f32 = 0;
                for (b.frags.items[frag_start..frag_end]) |*f| {
                    f.x += shift;
                    if (f.kind != .glyphs) continue;
                    var inner: f32 = 0;
                    for (b.glyphs.items[f.glyph_start..f.glyph_end]) |*g| {
                        g.x += inner;
                        if (g.cluster < end - trailingBytes(ifc.text[start..end]) and ifc.text[g.cluster] == ' ') inner += per;
                    }
                    f.w += inner;
                    shift += inner;
                }
            }
        },
    }
    offset += sp[0];
    if (offset != 0) for (b.frags.items[frag_start..frag_end]) |*f| {
        f.x += offset;
    };
    try b.lines.append(cx.gpa, .{
        .start = start,
        .end = end,
        .top = top.*,
        .height = height,
        .baseline = top.* + above,
        .frag_start = frag_start,
        .frag_end = frag_end,
        .left = offset,
        .width = content_w,
    });
    top.* += height;
}

/// The advance of white space and breaks hanging at a line's end.
fn trailingWidth(b: *Builder, start: u32, end: u32, frag_start: u32, frag_end: u32) f32 {
    const ifc = b.cx.ifc;
    const t = ifc.text;
    var hang = end;
    while (hang > start) {
        const c = t[hang - 1];
        if (c == ' ' or c == '\n') {
            hang -= 1;
            continue;
        }
        if (hang >= start + 3 and std.mem.eql(u8, t[hang - 3 .. hang], "\u{2028}")) {
            hang -= 3;
            continue;
        }
        break;
    }
    if (hang == end) return 0;
    // Preserved spaces (pre-wrap) still hang; preserved text with
    // break-spaces does not.
    var w: f32 = 0;
    for (b.frags.items[frag_start..frag_end]) |f| if (f.kind == .glyphs) {
        var x: f32 = 0;
        const gs = b.glyphs.items[f.glyph_start..f.glyph_end];
        for (gs, 0..) |g, i| {
            const next_x = if (i + 1 < gs.len) gs[i + 1].x else f.w;
            if (g.cluster >= hang and g.cluster < end) w += @max(0, next_x - g.x);
            x = next_x;
        }
    };
    return w;
}

/// The text offset at x in a line (for hit testing), from glyph clusters.
pub fn offsetAt(laid: *const Laid, ifc: *const box_mod.Ifc, line: Line, x: f32) u32 {
    const frags = laid.lineFrags(line);
    var best: u32 = line.start;
    var best_d: f32 = std.math.inf(f32);
    for (frags) |f| {
        if (f.kind == .atomic) {
            const d0 = @abs(x - f.x);
            const d1 = @abs(x - (f.x + f.w));
            if (d0 < best_d) {
                best_d = d0;
                best = f.start;
            }
            if (d1 < best_d) {
                best_d = d1;
                best = f.end;
            }
            continue;
        }
        if (f.kind != .glyphs) continue;
        const gs = laid.fragGlyphs(f);
        for (gs, 0..) |g, i| {
            const gx0 = f.x + g.x;
            const gx1 = f.x + (if (i + 1 < gs.len) gs[i + 1].x else f.w);
            const before = if (f.rtl) gx1 else gx0;
            const after = if (f.rtl) gx0 else gx1;
            const d0 = @abs(x - before);
            if (d0 < best_d) {
                best_d = d0;
                best = g.cluster;
            }
            const d1 = @abs(x - after);
            if (d1 < best_d) {
                best_d = d1;
                best = nextCluster(ifc.text, g.cluster);
            }
        }
    }
    return @min(@max(best, line.start), line.end);
}

fn nextCluster(t: []const u8, at: u32) u32 {
    if (at >= t.len) return @intCast(t.len);
    const l = std.unicode.utf8ByteSequenceLength(t[at]) catch 1;
    return @intCast(@min(t.len, at + l));
}

/// The x range of text offsets `from..to` within a line, as rectangles
/// (one per fragment piece).
pub fn rangeRects(laid: *const Laid, line: Line, from: u32, to: u32, out: *std.ArrayList([2]f32), gpa: Allocator) Error!void {
    for (laid.lineFrags(line)) |f| {
        if (f.end <= from or f.start >= to) continue;
        if (f.kind == .atomic) {
            try out.append(gpa, .{ f.x, f.x + f.w });
            continue;
        }
        if (f.kind != .glyphs) continue;
        const gs = laid.fragGlyphs(f);
        var x0: f32 = std.math.inf(f32);
        var x1: f32 = -std.math.inf(f32);
        for (gs, 0..) |g, i| {
            if (g.cluster < from or g.cluster >= to) continue;
            const a = f.x + g.x;
            const bb = f.x + (if (i + 1 < gs.len) gs[i + 1].x else f.w);
            x0 = @min(x0, @min(a, bb));
            x1 = @max(x1, @max(a, bb));
        }
        if (x1 > x0) try out.append(gpa, .{ x0, x1 });
    }
}
