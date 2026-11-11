//! The rich text editor (D22): an editor node showing a Portable Text
//! document (portable_text.zig) as it reads, edited with the usual keys
//! and the mouse or with Vim's keys (vim.zig).
//!
//! The editor node holds the document: its text, its spans (marks), and
//! its paragraph styles (blocks), which siv keeps through the user's
//! edits. After every edit the widget reads them back into the model,
//! writes the canonical spans and paragraph styles for it (a heading's
//! size covers every character typed into it, Enter after a heading
//! starts a normal paragraph), and keeps the model before the edit for
//! undo. It reads the whole node per edit, which costs time linear in the
//! document; fine for articles, not for books.
//!
//! siv's spans and paragraph styles carry no data of the application's,
//! so two attributes double as tags: a paragraph's indent_end, a
//! hundred-thousandth of a pixel per step, is the index of its block
//! definition in the registry, and an annotation's (a link's) color
//! carries its index in the red channel, too small a difference to see.
//!
//! Links are annotations made with Ctrl+K's popover (a popover at the
//! selection), by typing or pasting a URL, or through the API; a link
//! given a new URL keeps its markDef's _key and other fields.
//!
//! The root is a stack of a canvas, which draws list markers, quote bars,
//! code block grounds, and object placeholders behind the text where the
//! paragraphs' indents leave room, and the editor. The state lives on the
//! heap and goes with the canvas (its destroy callback).

const std = @import("std");
const w = @import("widgets.zig");
const pt = @import("portable_text.zig");
const vim_mod = @import("vim.zig");
const menu = @import("menu.zig");
const field = @import("field.zig");
const button = @import("button.zig");
const siv = w.siv;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

const gpa = std.heap.c_allocator;

const pad_x: f32 = 28;
const pad_y: f32 = 16;
const list_indent: f32 = 26;
const quote_indent: f32 = 22;
const code_indent: f32 = 14;
/// A quote's bar per level, in the theme's hues (as Parcel's reader
/// draws quoted mail), over a tint of this opacity on light and dark
/// surfaces.
const quote_hues = [_]siv.ColorToken{ .blue, .green, .red };
const quote_tint_light: f32 = 0.2;
const quote_tint_dark: f32 = 0.04;
const tag_step: f32 = 1e-5;
const link_g: f32 = 0.36;
const link_b: f32 = 0.80;
const max_undo = 200;

const Heading = struct { scale: f32, before: f32, after: f32, line: f32 };
const headings = [_]Heading{
    .{ .scale = 1.875, .before = 20, .after = 4, .line = 1.2 },
    .{ .scale = 1.5, .before = 16, .after = 4, .line = 1.25 },
    .{ .scale = 1.1875, .before = 12, .after = 2, .line = 1.3 },
    .{ .scale = 1.0625, .before = 10, .after = 2, .line = 1.4 },
    .{ .scale = 1.0, .before = 8, .after = 2, .line = 1.4 },
    .{ .scale = 0.875, .before = 8, .after = 2, .line = 1.4 },
};

/// Node data on the root.
const Data = extern struct {
    hdr: w.Header,
    st: *State,
};

const Tail = struct { count: usize, def: u32 };
/// A link: its annotation and the stretch of text it covers.
pub const Link = struct { ann: u32, start: u32, stop: u32 };
/// The open link editor (Ctrl+K): its popover, its fields, and the text
/// it links (lo == hi inserts a link there).
const LinkEditor = struct { popup: siv.Window = .null, url: Node = .null, text: Node = .null, lo: u32 = 0, hi: u32 = 0 };
const Step = struct { model: pt.Model, caret: u32, anchor: u32 };
const GroupKind = enum { insert, delete, replace };
const Group = struct { kind: GroupKind, pos: u32, space: bool = false };

/// A change of the blocks a selection touches.
pub const BlockChange = union(enum) {
    style: pt.Style,
    /// Toggles: a list every block already is turns off.
    list: pt.List,
    indent: i8,
    /// Toggles between one code block and normal text.
    code,
};

pub const State = struct {
    root: Node,
    editor: Node = .null,
    canvas: Node = .null,
    window: siv.Window,
    app: siv.App,
    data: *Data = undefined,
    allow: pt.Allow,
    font_size: f32,
    mono: u32 = 0,
    vim_on: bool = false,
    reg: pt.Registry,
    model: pt.Model = .{},
    tail: ?Tail = null,
    undo_stack: std.ArrayList(Step) = .empty,
    redo_stack: std.ArrayList(Step) = .empty,
    group: ?Group = null,
    modified: bool = false,
    /// A change event is due once the input being handled is done.
    changed: bool = false,
    message: std.ArrayList(u8) = .empty,
    vim: vim_mod.Vim = .{},
    posted: bool = false,
    reported: siv.RichTextState = .{},
    reported_status: std.ArrayList(u8) = .empty,
    link: LinkEditor = .{},

    fn deinit(st: *State) void {
        st.model.deinit(gpa);
        st.clearHistory();
        st.undo_stack.deinit(gpa);
        st.redo_stack.deinit(gpa);
        st.message.deinit(gpa);
        st.reported_status.deinit(gpa);
        st.vim.deinit();
        st.reg.deinit();
    }

    fn clearHistory(st: *State) void {
        for (st.undo_stack.items) |s| s.model.deinit(gpa);
        for (st.redo_stack.items) |s| s.model.deinit(gpa);
        st.undo_stack.clearRetainingCapacity();
        st.redo_stack.clearRetainingCapacity();
        st.group = null;
    }

    // Text, selection, and geometry, for the Vim keys --------------------

    pub fn text(st: *const State) []const u8 {
        return st.model.text;
    }

    pub fn def(st: *const State, b: pt.Block) pt.Def {
        return st.reg.def(b.def);
    }

    pub fn selection(st: *const State) [2]u32 {
        var caret: u32 = 0;
        var anchor: u32 = 0;
        _ = c.siv_node_get_selection(st.editor, &caret, &anchor);
        return .{ caret, anchor };
    }

    pub fn select(st: *State, caret: u32, anchor: u32, show_at: ?u32) void {
        const txn = w.begin(st.window) orelse return;
        c.siv_set_selection(txn, st.editor, caret, anchor);
        if (show_at) |at| c.siv_show_caret_at(txn, st.editor, at);
        _ = w.commit(txn);
        st.notifyLater();
    }

    /// The block holding offset, and its index.
    pub fn blockAt(st: *const State, offset: u32) struct { pt.Block, usize } {
        const blocks = st.model.blocks;
        for (blocks, 0..) |b, i| if (offset <= b.stop) return .{ b, i };
        return .{ blocks[blocks.len - 1], blocks.len - 1 };
    }

    pub fn caretRect(st: *const State, offset: u32) siv.Rect {
        var r: siv.Rect = .{};
        _ = c.siv_node_get_caret_rect(st.editor, offset, &r);
        return r;
    }

    /// Where the caret would go one displayed line up (dir -1) or down
    /// (1) from offset, at x; null at the first or last line.
    pub fn vertical(st: *const State, offset: u32, dir: i2, x: f32) ?u32 {
        const r = st.caretRect(offset);
        var y = if (dir > 0) r.y + r.height else r.y;
        for (0..80) |_| {
            y += @as(f32, @floatFromInt(dir)) * 3;
            var o: u32 = 0;
            if (c.siv_node_get_offset_at(st.editor, x, y, &o) != .ok) return null;
            o = vim_mod.onDisplayedLine(st, o, y);
            const q = st.caretRect(o);
            if ((dir > 0 and q.y > r.y + 1) or (dir < 0 and q.y < r.y - 1)) return o;
        }
        return null;
    }

    // Model <-> node --------------------------------------------------------

    fn span(st: *const State, start: u32, stop: u32, marks: pt.Marks, ann: u32, heading: u8) ?siv.TextSpan {
        var s: siv.TextSpan = .{ .start = start, .end = stop };
        if (heading > 0) {
            s.flags.size = true;
            s.font_size = st.font_size * headings[heading - 1].scale;
        }
        if (marks.strong or heading > 0) {
            s.flags.weight = true;
            s.weight = if (marks.strong) .bold else .semibold;
        }
        if (marks.em) {
            s.flags.slant = true;
            s.slant = .italic;
        }
        s.flags.underline = marks.underline;
        s.flags.strikethrough = marks.strike_through;
        if (marks.code and st.mono != 0) {
            s.flags.family = true;
            s.family = st.mono;
        }
        if (marks.superscript or marks.subscript) {
            s.flags.baseline = true;
            s.baseline = if (marks.superscript) .superscript else .subscript;
        }
        if (ann != 0) {
            s.flags.color = true;
            s.color = .{ .r = @as(f32, @floatFromInt(ann)) / 65536, .g = link_g, .b = link_b, .a = 1 };
        }
        if (@as(u32, @bitCast(s.flags)) == 0) return null;
        return s;
    }

    /// The spans and paragraph styles that show a model; sets the tail.
    fn encode(st: *State, m: pt.Model, spans: *std.ArrayList(siv.TextSpan), paras: *std.ArrayList(siv.ParagraphSpan)) !void {
        st.tail = null;
        var ri: usize = 0;
        for (m.blocks, 0..) |b, bi| {
            const d = st.def(b);
            switch (d.kind) {
                .code => if (b.stop > b.start and st.mono != 0) try spans.append(gpa, .{ .start = b.start, .end = b.stop, .flags = .{ .family = true }, .family = st.mono }),
                .object => try spans.append(gpa, .{ .start = b.start, .end = b.stop, .flags = .{ .color = true }, .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } }),
                .text => {
                    const heading = d.style.heading();
                    var at = b.start;
                    while (ri < m.runs.len and m.runs[ri].stop <= b.start) ri += 1;
                    var j = ri;
                    while (j < m.runs.len and m.runs[j].start < b.stop) : (j += 1) {
                        const r = m.runs[j];
                        const s = @max(r.start, b.start);
                        const e = @min(r.stop, b.stop);
                        if (heading > 0 and s > at) if (st.span(at, s, .{}, 0, heading)) |x| try spans.append(gpa, x);
                        if (e > s) if (st.span(s, e, r.marks, r.ann, heading)) |x| try spans.append(gpa, x);
                        at = @max(at, e);
                    }
                    if (heading > 0 and b.stop > at) if (st.span(at, b.stop, .{}, 0, heading)) |x| try spans.append(gpa, x);
                },
            }
            const last = bi == m.blocks.len - 1;
            if (b.def == 0) continue;
            if (last and b.start == b.stop) {
                // siv cannot style an empty last paragraph (it has no
                // character, not even a line break), so the widget keeps
                // its block until text is typed into it.
                st.tail = .{ .count = m.blocks.len, .def = b.def };
                continue;
            }
            var p: siv.ParagraphSpan = .{
                .start = b.start,
                .end = if (last) @intCast(m.text.len) else b.stop + 1,
                .flags = .{ .indent = true },
                .indent_end = @as(f32, @floatFromInt(b.def)) * tag_step,
            };
            switch (d.kind) {
                .text => if (d.list != .none) {
                    p.indent_start = list_indent * @as(f32, @floatFromInt(d.level));
                    p.flags.paragraph_spacing = true;
                    p.space_before = 2;
                    p.space_after = 2;
                } else if (d.style == .blockquote) {
                    p.indent_start = quote_indent * @as(f32, @floatFromInt(@max(d.level, 1)));
                } else if (d.style.heading() > 0) {
                    const h = headings[d.style.heading() - 1];
                    p.flags.paragraph_spacing = true;
                    p.space_before = h.before;
                    p.space_after = h.after;
                    p.flags.line_spacing = true;
                    p.line_spacing = h.line;
                },
                .code => {
                    const first = bi == 0 or m.blocks[bi - 1].def != b.def;
                    const final = last or m.blocks[bi + 1].def != b.def;
                    p.indent_start = code_indent;
                    p.flags.paragraph_spacing = true;
                    p.space_before = if (first) 12 else 0;
                    p.space_after = if (final) 18 else 0;
                    p.flags.line_spacing = true;
                    p.line_spacing = 1.35;
                },
                .object => {
                    p.flags.paragraph_spacing = true;
                    p.space_before = 8;
                    p.space_after = 14;
                },
            }
            try paras.append(gpa, p);
        }
    }

    fn marksOf(st: *const State, s: siv.TextSpan) struct { pt.Marks, u32 } {
        const f = s.flags;
        var m: pt.Marks = .{};
        m.strong = f.weight and @intFromEnum(s.weight) >= @intFromEnum(siv.FontWeight.bold);
        m.em = f.slant and s.slant != .roman;
        m.underline = f.underline;
        m.strike_through = f.strikethrough;
        m.code = f.family and st.mono != 0 and s.family == st.mono;
        m.superscript = f.baseline and s.baseline == .superscript;
        m.subscript = f.baseline and s.baseline == .subscript;
        var ann: u32 = 0;
        if (f.color and s.color_token == .none and @abs(s.color.g - link_g) < 1e-3 and @abs(s.color.b - link_b) < 1e-3) {
            const i: u32 = @intFromFloat(@round(s.color.r * 65536));
            if (st.reg.annotationValue(i) != null) ann = i;
        }
        return .{ m, ann };
    }

    /// What the node shows, as a model; takes the text.
    fn decode(st: *const State, text_: []u8, spans: []const siv.TextSpan, paras: []const siv.ParagraphSpan) !pt.Model {
        var blocks: std.ArrayList(pt.Block) = .empty;
        errdefer blocks.deinit(gpa);
        for (paras) |p| {
            var tag: u32 = 0;
            if (p.flags.indent) {
                const t: u32 = @intFromFloat(@max(0, @round(p.indent_end / tag_step)));
                if (t < st.reg.defs.items.len) tag = t;
            }
            const stop = if (p.end > p.start and text_[p.end - 1] == '\n') p.end - 1 else p.end;
            try blocks.append(gpa, .{ .start = p.start, .stop = stop, .def = tag });
        }
        if (blocks.items.len == 0) try blocks.append(gpa, .{ .start = 0, .stop = 0 });
        const last = &blocks.items[blocks.items.len - 1];
        if (st.tail) |tail| if (tail.count == blocks.items.len and last.def == 0) {
            last.def = tail.def;
        };
        // A paragraph tagged as an object without its character: the
        // object was deleted, what is left is text.
        for (blocks.items) |*b| if (st.def(b.*).kind == .object and std.mem.indexOf(u8, text_[b.start..b.stop], pt.object_char) == null) {
            b.def = 0;
        };

        var runs: std.ArrayList(pt.Run) = .empty;
        errdefer runs.deinit(gpa);
        var bi: usize = 0;
        for (spans) |s| {
            const marks, const ann = st.marksOf(s);
            if (!marks.any() and ann == 0) continue;
            // Marks only in text blocks: a code block's monospace is no
            // code mark.
            var at = s.start;
            while (at < s.end) {
                while (bi < blocks.items.len and blocks.items[bi].stop < at) bi += 1;
                if (bi == blocks.items.len) break;
                const b = blocks.items[bi];
                const lo = @max(at, b.start);
                const hi = @min(s.end, b.stop);
                if (hi > lo and st.def(b).kind == .text) {
                    if (runs.items.len > 0) {
                        const prev = &runs.items[runs.items.len - 1];
                        if (prev.stop == lo and prev.ann == ann and prev.marks.eql(marks)) {
                            prev.stop = hi;
                            at = @max(hi, b.stop + 1);
                            continue;
                        }
                    }
                    try runs.append(gpa, .{ .start = lo, .stop = hi, .marks = marks, .ann = ann });
                }
                at = @max(hi, b.stop + 1);
            }
        }
        const b = try blocks.toOwnedSlice(gpa);
        errdefer gpa.free(b);
        return .{ .text = text_, .blocks = b, .runs = try runs.toOwnedSlice(gpa) };
    }

    const Read = struct {
        text: []u8,
        spans: std.ArrayList(siv.TextSpan) = .empty,
        paras: std.ArrayList(siv.ParagraphSpan) = .empty,

        fn deinit(r: *Read) void {
            r.spans.deinit(gpa);
            r.paras.deinit(gpa);
        }
    };

    /// Reads the node's text, spans, and paragraph styles.
    fn read(st: *const State) !Read {
        var len: usize = 0;
        _ = c.siv_node_get_text(st.editor, null, 0, &len);
        const buf = try gpa.alloc(u8, len);
        errdefer gpa.free(buf);
        _ = c.siv_node_get_text(st.editor, buf.ptr, buf.len, &len);
        var r: Read = .{ .text = buf };
        errdefer r.deinit();
        var o: u32 = 0;
        while (o < buf.len) {
            var s: siv.TextSpan = .{};
            if (c.siv_node_get_text_run(st.editor, o, &s) != .ok or s.end <= o) break;
            if (@as(u32, @bitCast(s.flags)) != 0) try r.spans.append(gpa, s);
            o = s.end;
        }
        o = 0;
        while (true) {
            var p: siv.ParagraphSpan = .{};
            if (c.siv_node_get_paragraph(st.editor, o, &p) != .ok) break;
            try r.paras.append(gpa, p);
            if (p.end >= buf.len or p.end <= o) break;
            o = p.end;
        }
        if (buf.len > 0 and buf[buf.len - 1] == '\n') {
            var p: siv.ParagraphSpan = .{};
            if (c.siv_node_get_paragraph(st.editor, @intCast(buf.len), &p) == .ok) try r.paras.append(gpa, p);
        }
        return r;
    }

    /// Writes a model to the node in a transaction: its text when asked,
    /// spans, and paragraph styles.
    fn write(st: *State, txn: Txn, m: pt.Model, with_text: bool) void {
        var spans: std.ArrayList(siv.TextSpan) = .empty;
        defer spans.deinit(gpa);
        var paras: std.ArrayList(siv.ParagraphSpan) = .empty;
        defer paras.deinit(gpa);
        st.encode(m, &spans, &paras) catch return;
        if (with_text) c.siv_set_text(txn, st.editor, m.text.ptr, m.text.len);
        c.siv_set_text_spans(txn, st.editor, &.{ .spans = spans.items.ptr, .spans_count = spans.items.len });
        c.siv_set_paragraph_spans(txn, st.editor, &.{ .spans = paras.items.ptr, .spans_count = paras.items.len });
        c.siv_invalidate(txn, st.canvas);
    }

    fn setModel(st: *State, m: pt.Model) void {
        st.model.deinit(gpa);
        st.model = m;
    }

    /// Reads the node back into the model and normalizes what it shows.
    pub fn sync(st: *State) void {
        st.syncDepth(0);
    }

    fn syncDepth(st: *State, depth: u8) void {
        var r = st.read() catch return;
        defer r.deinit();
        const m = st.decode(r.text, r.spans.items, r.paras.items) catch {
            gpa.free(r.text);
            return;
        };
        // Text typed beside an object goes to a paragraph of its own.
        if (depth < 2) for (m.blocks) |b| {
            if (st.def(b).kind != .object) continue;
            const s = m.text[b.start..b.stop];
            if (std.mem.eql(u8, s, pt.object_char)) continue;
            const k: u32 = @intCast(std.mem.indexOf(u8, s, pt.object_char).?);
            const txn = w.begin(st.window) orelse break;
            const after = b.start + k + @as(u32, pt.object_char.len);
            if (after < b.stop) c.siv_replace_text(txn, st.editor, after, after, "\n", 1);
            if (k > 0) c.siv_replace_text(txn, st.editor, b.start + k, b.start + k, "\n", 1);
            _ = w.commit(txn);
            m.deinit(gpa);
            return st.syncDepth(depth + 1);
        };
        var spans: std.ArrayList(siv.TextSpan) = .empty;
        defer spans.deinit(gpa);
        var paras: std.ArrayList(siv.ParagraphSpan) = .empty;
        defer paras.deinit(gpa);
        st.encode(m, &spans, &paras) catch {};
        const same_spans = spansMatch(r.spans.items, spans.items);
        const same_paras = parasMatch(r.paras.items, paras.items);
        if (w.begin(st.window)) |txn| {
            if (!same_spans) c.siv_set_text_spans(txn, st.editor, &.{ .spans = spans.items.ptr, .spans_count = spans.items.len });
            if (!same_paras) c.siv_set_paragraph_spans(txn, st.editor, &.{ .spans = paras.items.ptr, .spans_count = paras.items.len });
            c.siv_invalidate(txn, st.canvas);
            _ = w.commit(txn);
        }
        st.setModel(m);
        st.tailTypingStyle();
        st.notifyLater();
    }

    /// Shows a model (taking it), replacing what the node shows, and
    /// selects.
    pub fn apply(st: *State, m: pt.Model, sel: ?[2]u32) void {
        const txn = w.begin(st.window) orelse {
            m.deinit(gpa);
            return;
        };
        st.write(txn, m, !std.mem.eql(u8, m.text, st.model.text));
        if (sel) |s| c.siv_set_selection(txn, st.editor, s[0], s[1]);
        _ = w.commit(txn);
        st.setModel(m);
        st.tailTypingStyle();
        st.notifyLater();
    }

    /// Gives what is typed into the empty last paragraph its block's look.
    fn tailTypingStyle(st: *State) void {
        const tail = st.tail orelse return;
        const s = st.selection();
        if (s[0] != s[1] or s[0] != st.model.text.len) return;
        const d = st.reg.def(tail.def);
        if (d.kind == .code and st.mono != 0) {
            _ = c.siv_editor_format(st.editor, .{ .flags = .{ .family = true }, .family = st.mono }, .{ .family = true });
        } else if (d.style.heading() > 0) {
            _ = c.siv_editor_format(st.editor, .{ .flags = .{ .size = true, .weight = true }, .font_size = st.font_size * headings[d.style.heading() - 1].scale, .weight = .semibold }, .{ .size = true, .weight = true });
        }
    }

    // Edits -------------------------------------------------------------------

    /// Replaces lo..hi with text as an edit of the document, with the
    /// marks and blocks of a fragment when given (a paste).
    pub fn replace(st: *State, lo: u32, hi: u32, s: []const u8, frag: ?*const pt.Model) void {
        const txn = w.begin(st.window) orelse return;
        c.siv_replace_text(txn, st.editor, lo, hi, s.ptr, s.len);
        _ = w.commit(txn);
        st.edited();
        st.sync();
        if (frag) |f| {
            const m = overlay(st.model, lo, f.*) catch return;
            st.apply(m, null);
        }
    }

    pub fn edited(st: *State) void {
        st.modified = true;
        st.changed = true;
    }

    /// Reports the change of the input just handled.
    fn flushChange(st: *State) void {
        if (!st.changed) return;
        st.changed = false;
        w.emitChange(st.root, 0, 0);
    }

    /// The marks and blocks of lo..hi, to paste elsewhere.
    pub fn fragment(st: *const State, lo: u32, hi: u32) !pt.Model {
        const m = st.model;
        var runs: std.ArrayList(pt.Run) = .empty;
        errdefer runs.deinit(gpa);
        for (m.runs) |r| {
            const s = @max(r.start, lo);
            const e = @min(r.stop, hi);
            if (e > s) try runs.append(gpa, .{ .start = s - lo, .stop = e - lo, .marks = r.marks, .ann = r.ann });
        }
        var blocks: std.ArrayList(pt.Block) = .empty;
        errdefer blocks.deinit(gpa);
        for (m.blocks) |b| if (b.start >= lo and b.start < hi or (b.start == lo and lo == hi)) {
            try blocks.append(gpa, .{ .start = b.start - lo, .stop = @min(b.stop, hi) - lo, .def = b.def });
        };
        const t = try gpa.dupe(u8, m.text[lo..hi]);
        errdefer gpa.free(t);
        const bl = try blocks.toOwnedSlice(gpa);
        errdefer gpa.free(bl);
        return .{ .text = t, .blocks = bl, .runs = try runs.toOwnedSlice(gpa) };
    }

    // Undo: the model before each step ----------------------------------------

    pub fn checkpoint(st: *State, caret: u32, anchor: u32) void {
        const m = st.model.clone(gpa) catch return;
        if (st.undo_stack.items.len >= max_undo) st.undo_stack.orderedRemove(0).model.deinit(gpa);
        st.undo_stack.append(gpa, .{ .model = m, .caret = caret, .anchor = anchor }) catch m.deinit(gpa);
        for (st.redo_stack.items) |s| s.model.deinit(gpa);
        st.redo_stack.clearRetainingCapacity();
        st.group = null;
    }

    /// Drops the last checkpoint when nothing changed since (an insert
    /// that typed nothing).
    pub fn dropEmptyCheckpoint(st: *State) void {
        const top = st.undo_stack.getLastOrNull() orelse return;
        if (top.model.eql(st.model)) {
            _ = st.undo_stack.pop();
            top.model.deinit(gpa);
        }
    }

    pub fn dropCheckpoint(st: *State) void {
        if (st.undo_stack.pop()) |s| s.model.deinit(gpa);
    }

    fn history(st: *State, from: *std.ArrayList(Step), to: *std.ArrayList(Step), empty: []const u8) bool {
        const step = from.pop() orelse {
            st.setMessage(empty);
            return false;
        };
        const sel = st.selection();
        const cur = st.model.clone(gpa) catch {
            from.append(gpa, step) catch {};
            return false;
        };
        to.append(gpa, .{ .model = cur, .caret = sel[0], .anchor = sel[1] }) catch cur.deinit(gpa);
        st.apply(step.model, .{ step.caret, step.anchor });
        st.edited();
        st.group = null;
        return true;
    }

    pub fn undo(st: *State) bool {
        return st.history(&st.undo_stack, &st.redo_stack, "Already at oldest change");
    }

    pub fn redo(st: *State) bool {
        return st.history(&st.redo_stack, &st.undo_stack, "Already at newest change");
    }

    // Formatting --------------------------------------------------------------

    /// Toggles a decorator over lo..hi, or for what is typed next when
    /// that is empty.
    pub fn toggleMark(st: *State, mark: pt.Marks, lo: u32, hi: u32) void {
        if (st.allow.marks.bits() & mark.bits() == 0) return;
        if (lo == hi) {
            var typing: siv.TextSpan = .{};
            _ = c.siv_node_get_typing_style(st.editor, &typing);
            const has, _ = st.marksOf(typing);
            const on = has.bits() & mark.bits() == 0;
            var v: siv.TextSpan = .{};
            var mask: siv.TextSpanFlags = .{};
            if (mark.strong) {
                mask.weight = true;
                v.flags.weight = on;
                v.weight = .bold;
            } else if (mark.em) {
                mask.slant = true;
                v.flags.slant = on;
                v.slant = .italic;
            } else if (mark.underline) {
                mask.underline = true;
                v.flags.underline = on;
            } else if (mark.strike_through) {
                mask.strikethrough = true;
                v.flags.strikethrough = on;
            } else if (mark.code and st.mono != 0) {
                mask.family = true;
                v.flags.family = on;
                v.family = st.mono;
            } else if (mark.superscript or mark.subscript) {
                // One replaces the other.
                mask.baseline = true;
                v.flags.baseline = on;
                v.baseline = if (mark.superscript) .superscript else .subscript;
            }
            _ = c.siv_editor_format(st.editor, v, mask);
            st.notifyLater();
            return;
        }
        const on = !st.allMarked(lo, hi, mark);
        const runs = mapRuns(st, lo, hi, .{ .mark = .{ .mark = mark, .on = on } }) catch return;
        const sel = st.selection();
        st.checkpoint(sel[0], sel[1]);
        const t = gpa.dupe(u8, st.model.text) catch return;
        const b = gpa.dupe(pt.Block, st.model.blocks) catch return;
        st.edited();
        st.apply(.{ .text = t, .blocks = b, .runs = runs }, sel);
    }

    /// Whether every character of text blocks in lo..hi but line breaks
    /// has the mark.
    fn allMarked(st: *const State, lo: u32, hi: u32, mark: pt.Marks) bool {
        const m = st.model;
        for (m.blocks) |b| {
            if (st.def(b).kind != .text or b.stop <= lo or b.start >= hi) continue;
            var at = @max(b.start, lo);
            const end = @min(b.stop, hi);
            for (m.runs) |r| {
                if (r.stop <= at or r.start >= end) continue;
                if (r.start > at) return false;
                if (r.marks.bits() & mark.bits() == 0) return false;
                at = r.stop;
                if (at >= end) break;
            }
            if (at < end) return false;
        }
        return true;
    }

    /// Sets the blocks lo..hi touches; false when the schema does not
    /// allow it or nothing changes.
    pub fn setBlock(st: *State, change: BlockChange, lo: u32, hi: u32) bool {
        switch (change) {
            .style => |s| if (!st.allow.style(s)) return false,
            .list => |l| if (!st.allow.list(l)) return false,
            .indent => {},
            .code => if (!st.allow.code) return false,
        }
        const m = st.model;
        const blocks = gpa.dupe(pt.Block, m.blocks) catch return false;
        var touched_all_list = true;
        var touched_all_code = true;
        var code_def: ?u32 = null;
        var any = false;
        for (m.blocks) |b| {
            if (b.stop < lo or b.start > hi) continue;
            const d = st.def(b);
            if (d.kind == .object) continue;
            any = true;
            if (change == .list and d.list != change.list) touched_all_list = false;
            if (d.kind != .code) touched_all_code = false else if (code_def == null) code_def = b.def;
        }
        if (!any) {
            gpa.free(blocks);
            return false;
        }
        const to_code = change == .code and !touched_all_code;
        if (to_code and code_def == null) code_def = st.reg.intern(.{ .kind = .code }) catch null;
        var differs = false;
        for (blocks) |*b| {
            if (b.stop < lo or b.start > hi) continue;
            const d = st.def(b.*);
            if (d.kind == .object) continue;
            const raw = if (d.kind == .text) d.raw else null;
            const nd: pt.Def = switch (change) {
                // A quote made from other text is quoted once; one
                // already quoted keeps its level.
                .style => |s| .{ .style = s, .level = if (s != .blockquote) 0 else if (d.style == .blockquote) d.level else 1, .raw = raw },
                .list => |l| if (touched_all_list or l == .none) .{ .raw = raw } else .{ .list = l, .level = @max(d.level, 1), .raw = raw },
                .indent => |n| if (d.list == .none and d.style != .blockquote) d else blk: {
                    var x = d;
                    x.level = @intCast(std.math.clamp(@as(i32, d.level) + n, 1, pt.max_level));
                    break :blk x;
                },
                .code => if (to_code) st.reg.def(code_def.?) else .{},
            };
            const id = st.reg.intern(nd) catch continue;
            if (id != b.def) differs = true;
            b.def = id;
        }
        if (!differs) {
            gpa.free(blocks);
            return false;
        }
        const t = gpa.dupe(u8, m.text) catch return false;
        const runs = clipRuns(st, m.runs, blocks) catch return false;
        const sel = st.selection();
        st.checkpoint(sel[0], sel[1]);
        st.edited();
        st.apply(.{ .text = t, .blocks = blocks, .runs = runs }, sel);
        return true;
    }

    // Links ---------------------------------------------------------------

    /// The link over the character at lo when hi > lo (a selection), else
    /// over the character before lo or, failing that, after it; with its
    /// extent, the stretch of its annotation around it.
    pub fn linkAt(st: *const State, lo: u32, hi: u32) ?Link {
        const runs = st.model.runs;
        // Runs are in order, so the one ending at a caret comes before the
        // one starting there.
        const i = for (runs, 0..) |r, i| {
            if (r.ann == 0) continue;
            if (r.start <= lo and lo < r.stop) break i;
            if (hi == lo and r.start < lo and lo <= r.stop) break i;
        } else return null;
        const ann = runs[i].ann;
        var s = i;
        while (s > 0 and runs[s - 1].ann == ann and runs[s - 1].stop == runs[s].start) s -= 1;
        var e = i;
        while (e + 1 < runs.len and runs[e + 1].ann == ann and runs[e + 1].start == runs[e].stop) e += 1;
        return .{ .ann = ann, .start = runs[s].start, .stop = runs[e].stop };
    }

    /// The link at a selection, as Ctrl+K edits it: in Vim's modes with a
    /// block cursor, the one under the cursor.
    pub fn caretLink(st: *const State, lo: u32, hi: u32) ?Link {
        if (lo == hi and st.vim_on and st.vim.modal() and lo < st.model.text.len) {
            const n = std.unicode.utf8ByteSequenceLength(st.model.text[lo]) catch 1;
            return st.linkAt(lo, lo + n);
        }
        return st.linkAt(lo, hi);
    }

    /// Links lo..hi to url, or unlinks it when url is empty, as one undo
    /// step; with lo == hi, the link at lo, whole. A link given a new URL
    /// over its whole extent keeps its _key and other fields. Whether the
    /// document changed.
    pub fn setLink(st: *State, lo0: u32, hi0: u32, url: []const u8) bool {
        if (!st.allow.link) return false;
        var lo = lo0;
        var hi = hi0;
        var ann: u32 = 0;
        if (st.linkAt(lo, hi)) |l| {
            if (lo == hi) {
                lo = l.start;
                hi = l.stop;
            }
            if (url.len > 0 and l.start <= lo and hi <= l.stop) {
                ann = if (std.mem.eql(u8, st.reg.href(l.ann), url)) l.ann else st.reg.link(url, st.reg.annotationValue(l.ann)) catch return false;
            }
        } else if (lo == hi) return false;
        if (url.len > 0 and ann == 0) ann = st.reg.link(url, null) catch return false;
        const runs = mapRuns(st, lo, hi, .{ .ann = ann }) catch return false;
        if (runsEql(runs, st.model.runs)) {
            gpa.free(runs);
            return false;
        }
        const sel = st.selection();
        st.checkpoint(sel[0], sel[1]);
        st.edited();
        st.applyRuns(runs, sel);
        return true;
    }

    /// Shows the model with other runs (taking them).
    fn applyRuns(st: *State, runs: []pt.Run, sel: ?[2]u32) void {
        const t = gpa.dupe(u8, st.model.text) catch return gpa.free(runs);
        const b = gpa.dupe(pt.Block, st.model.blocks) catch {
            gpa.free(t);
            return gpa.free(runs);
        };
        st.apply(.{ .text = t, .blocks = b, .runs = runs }, sel);
    }

    /// Replaces lo..hi with text linked to url, as one undo step, with the
    /// caret after it.
    pub fn insertLink(st: *State, lo: u32, hi: u32, s: []const u8, url: []const u8) void {
        const b, _ = st.blockAt(lo);
        if (!st.allow.link or st.def(b).kind != .text or s.len == 0) return;
        const sel = st.selection();
        st.checkpoint(sel[0], sel[1]);
        st.replace(lo, hi, s, null);
        const e: u32 = lo + @as(u32, @intCast(s.len));
        const ann = st.reg.link(url, null) catch return;
        const runs = mapRuns(st, lo, e, .{ .ann = ann }) catch return;
        st.applyRuns(runs, .{ e, e });
    }

    /// Links the URL typed before a space or Enter at `end`, as an undo
    /// step of its own (in Vim, of the insert's), as mail and chat editors
    /// do: the word before it, without the brackets, quotes, and
    /// punctuation around it.
    fn autolink(st: *State, end: u32) void {
        if (!st.allow.link) return;
        const b, _ = st.blockAt(end);
        if (st.def(b).kind != .text or end > b.stop or end <= b.start) return;
        const t = st.model.text;
        var lo = end;
        while (lo > b.start) {
            if (t[lo - 1] == ' ' or t[lo - 1] == '\t') break;
            if (std.mem.endsWith(u8, t[b.start..lo], pt.line_separator) or std.mem.endsWith(u8, t[b.start..lo], pt.object_char)) break;
            lo -= 1;
        }
        var hi = end;
        while (lo < hi and std.mem.indexOfScalar(u8, "(<[\"'", t[lo]) != null) lo += 1;
        while (hi > lo) {
            const ch = t[hi - 1];
            const open_paren = ch == ')' and std.mem.count(u8, t[lo..hi], "(") < std.mem.count(u8, t[lo..hi], ")");
            if (std.mem.indexOfScalar(u8, ".,;:!?\"'>]", ch) == null and !open_paren) break;
            hi -= 1;
        }
        const url = urlHref(t[lo..hi]) orelse return;
        defer gpa.free(url);
        for (st.model.runs) |r| if (r.ann != 0 and r.start < hi and r.stop > lo) return;
        const ann = st.reg.link(url, null) catch return;
        const runs = mapRuns(st, lo, hi, .{ .ann = ann }) catch return;
        if (!(st.vim_on and st.vim.undo_held)) {
            const sel = st.selection();
            st.checkpoint(sel[0], sel[1]);
        }
        st.applyRuns(runs, null);
    }

    /// A URL pasted over text (lo..hi before the paste) links that text
    /// instead of replacing it, as one undo step back to the selection;
    /// whether it did.
    fn pasteLink(st: *State, lo: u32, hi: u32, pasted: []const u8) bool {
        if (!st.allow.link) return false;
        const b, _ = st.blockAt(lo);
        if (st.def(b).kind != .text or hi > b.stop) return false;
        const url = urlHref(std.mem.trim(u8, pasted, " \t\r\n")) orelse return false;
        defer gpa.free(url);
        const old = st.model.text[lo..hi];
        st.checkpoint(hi, lo);
        const txn = w.begin(st.window) orelse return false;
        c.siv_replace_text(txn, st.editor, lo, lo + @as(u32, @intCast(pasted.len)), old.ptr, old.len);
        _ = w.commit(txn);
        st.edited();
        const ann = st.reg.link(url, null) catch return true;
        const runs = mapRuns(st, lo, hi, .{ .ann = ann }) catch return true;
        st.applyRuns(runs, .{ hi, hi });
        return true;
    }

    /// Opens the link editor (Ctrl+K) in a popover at the selection: a URL
    /// for selected text; the URL of the link at the caret, to change or
    /// remove; else a URL and the text to insert.
    pub fn openLink(st: *State) void {
        if (!st.allow.link or st.data.hdr.disabled or w.windowAlive(st.link.popup)) return;
        const sel = st.selection();
        var lo = @min(sel[0], sel[1]);
        var hi = @max(sel[0], sel[1]);
        const b, _ = st.blockAt(lo);
        if (st.def(b).kind != .text) return;
        var url: []const u8 = "";
        var editing = false;
        if (st.caretLink(lo, hi)) |l| {
            if (lo == hi or (l.start <= lo and hi <= l.stop)) {
                lo = l.start;
                hi = l.stop;
            }
            url = st.reg.href(l.ann);
            editing = true;
        }
        const r0 = st.caretRect(lo);
        const r1 = st.caretRect(hi);
        const rect: siv.Rect = if (@abs(r1.y - r0.y) < 1)
            .{ .x = @min(r0.x, r1.x), .y = r0.y, .width = @max(1, @abs(r1.x - r0.x)), .height = r0.height }
        else
            .{ .x = r0.x, .y = r0.y, .width = 1, .height = r0.height };
        var popup: siv.Window = .null;
        var content: Node = .null;
        if (menu.popoverAt(st.editor, .{ .label = "Link", .label_len = 4 }, rect, &popup, &content) != .ok) return;
        const txn = w.begin(popup) orelse {
            c.siv_window_destroy(popup);
            return;
        };
        const ud = w.handleData(st.root);
        const col = c.siv_flex(txn, content, &.{ .axis = .column, .gap = 8 });
        c.siv_set_layout(txn, col, &.{ .width = w.px(300) });
        const url_field = field.siv_text_field(txn, col, &.{ .text = url.ptr, .text_len = url.len, .placeholder = "Paste or type a link", .placeholder_len = 20, .label = "Link address", .label_len = 12 });
        const text_field: Node = if (lo == hi) field.siv_text_field(txn, col, &.{ .placeholder = "Text to show", .placeholder_len = 12, .label = "Link text", .label_len = 9 }) else .null;
        const row = c.siv_flex(txn, col, &.{ .axis = .row, .justify = .end, .gap = 8 });
        if (editing) {
            const remove = button.siv_push_button(txn, row, &.{ .label = "Remove", .label_len = 6 });
            c.siv_on(txn, remove, .activate, onLinkRemove, null, ud);
        }
        const apply_ = button.siv_push_button(txn, row, &.{ .label = "Apply", .label_len = 5, .style = .primary });
        c.siv_on(txn, apply_, .activate, onLinkApply, null, ud);
        c.siv_on(txn, col, .key, onLinkKey, null, ud);
        c.siv_set_selection(txn, url_field, @intCast(url.len), 0);
        if (!w.commit(txn) or c.siv_popup_show(popup) != .ok) {
            c.siv_window_destroy(popup);
            return;
        }
        st.link = .{ .popup = popup, .url = url_field, .text = text_field, .lo = lo, .hi = hi };
        _ = c.siv_node_focus(url_field);
    }

    /// Closes the link editor, applying what it holds or removing the
    /// link.
    fn finishLink(st: *State, remove: bool) void {
        const ed = st.link;
        if (!w.windowAlive(ed.popup)) return;
        var buf: [2][]u8 = .{ &.{}, &.{} };
        defer for (buf) |x| gpa.free(x);
        if (!remove) for ([_]Node{ ed.url, ed.text }, &buf) |n, *out| {
            if (n == .null) continue;
            var len: usize = 0;
            _ = c.siv_node_get_text(n, null, 0, &len);
            out.* = gpa.alloc(u8, len) catch continue;
            _ = c.siv_node_get_text(n, out.*.ptr, len, &len);
        };
        c.siv_window_destroy(ed.popup);
        st.link = .{};
        const href = hrefOf(buf[0]);
        defer if (href) |h| gpa.free(h);
        if (ed.lo == ed.hi) {
            const shown = std.mem.trim(u8, buf[1], " \t");
            if (href) |h| st.insertLink(ed.lo, ed.lo, if (shown.len > 0) shown else std.mem.trim(u8, buf[0], " \t\r\n"), h);
        } else {
            _ = st.setLink(ed.lo, ed.hi, href orelse "");
            // The caret at the end of the text, as word processors leave
            // it, so typing goes on after the link (Vim's cursor stays).
            if (!(st.vim_on and st.vim.modal())) st.select(ed.hi, ed.hi, null);
        }
        _ = c.siv_node_focus(st.editor);
        if (st.vim_on) st.vim.afterLink(st);
        st.flushChange();
        st.notify();
    }

    /// Runs a command as the toolbar gives it.
    pub fn run(st: *State, cmd: siv.RichTextCommand) siv.Result {
        const sel = st.selection();
        const lo = @min(sel[0], sel[1]);
        const hi = @max(sel[0], sel[1]);
        switch (cmd) {
            .strong, .em, .underline, .strike_through, .code, .superscript, .subscript => {
                const mark: pt.Marks = switch (cmd) {
                    .superscript => .{ .superscript = true },
                    .subscript => .{ .subscript = true },
                    else => pt.Marks.of(@as(u8, 1) << @intCast(@intFromEnum(cmd))),
                };
                if (st.allow.marks.bits() & mark.bits() == 0) return .error_unsupported;
                st.toggleMark(mark, lo, hi);
            },
            .normal, .h1, .h2, .h3, .h4, .h5, .h6 => {
                const s: pt.Style = @enumFromInt(@intFromEnum(cmd) - @intFromEnum(siv.RichTextCommand.normal));
                if (!st.allow.style(s)) return .error_unsupported;
                _ = st.setBlock(.{ .style = s }, lo, hi);
            },
            .blockquote => {
                if (!st.allow.style(.blockquote)) return .error_unsupported;
                const b, _ = st.blockAt(sel[0]);
                _ = st.setBlock(.{ .style = if (st.def(b).style == .blockquote and st.def(b).kind == .text) .normal else .blockquote }, lo, hi);
            },
            .bullet_list, .number_list => {
                const l: pt.List = if (cmd == .bullet_list) .bullet else .number;
                if (!st.allow.list(l)) return .error_unsupported;
                _ = st.setBlock(.{ .list = l }, lo, hi);
            },
            .code_block => {
                if (!st.allow.code) return .error_unsupported;
                _ = st.setBlock(.code, lo, hi);
            },
            .indent, .outdent => {
                if (!st.allow.bullet and !st.allow.number and !st.allow.style(.blockquote)) return .error_unsupported;
                _ = st.setBlock(.{ .indent = if (cmd == .indent) 1 else -1 }, lo, hi);
            },
            .undo => _ = st.undo(),
            .redo => _ = st.redo(),
            .link => {
                if (!st.allow.link) return .error_unsupported;
                st.openLink();
            },
            else => return .error_unsupported,
        }
        st.flushChange();
        st.notify();
        return .ok;
    }

    // Keys -----------------------------------------------------------------

    /// Formatting keys of both modes; whether it took the key.
    pub fn formatKey(st: *State, ev: *const siv.Event) bool {
        const m = ev.modifiers;
        if (!m.ctrl or m.super) return false;
        const k: u32 = @bitCast(@intFromEnum(ev.shortcut_key));
        const ch: u8 = if (k < 128) std.ascii.toLower(@intCast(k)) else 0;
        const sel = st.selection();
        const lo = @min(sel[0], sel[1]);
        const hi = @max(sel[0], sel[1]);
        if (m.alt) {
            if (ch >= '0' and ch <= '6') {
                _ = st.run(@enumFromInt(@intFromEnum(siv.RichTextCommand.normal) + (ch - '0')));
                return true;
            }
            if (ch == 'c') {
                _ = st.run(.code_block);
                return true;
            }
            return false;
        }
        if (m.shift) {
            const cmd: ?siv.RichTextCommand = switch (ch) {
                '7', '&' => .number_list,
                '8', '*' => .bullet_list,
                '9', '(' => .blockquote,
                'x' => .strike_through,
                'z' => .redo,
                else => null,
            };
            if (cmd) |x| _ = st.run(x);
            return cmd != null;
        }
        switch (ch) {
            '.' => _ = st.run(.superscript),
            ',' => _ = st.run(.subscript),
            'b' => st.toggleMark(.{ .strong = true }, lo, hi),
            'i' => st.toggleMark(.{ .em = true }, lo, hi),
            'u' => st.toggleMark(.{ .underline = true }, lo, hi),
            'e' => st.toggleMark(.{ .code = true }, lo, hi),
            'z' => _ = st.undo(),
            'y' => _ = st.redo(),
            'k' => st.openLink(),
            else => return false,
        }
        st.notifyLater();
        return true;
    }

    /// Keys while the editor types (the usual mode, Vim's insert mode).
    pub fn typingKey(st: *State, ev: *const siv.Event) bool {
        if (st.formatKey(ev)) return true;
        const k = ev.keysym;
        const m = ev.modifiers;
        if ((k == w.keysym.tab or k == w.keysym.iso_left_tab) and !m.ctrl and !m.alt) {
            const sel = st.selection();
            const b, _ = st.blockAt(sel[0]);
            const d = st.def(b);
            const back = k == w.keysym.iso_left_tab or m.shift;
            if (d.list != .none or (d.kind == .text and d.style == .blockquote)) {
                _ = st.setBlock(.{ .indent = if (back) -1 else 1 }, @min(sel[0], sel[1]), @max(sel[0], sel[1]));
                return true;
            }
            if (d.kind == .code and !back) {
                st.insertAtSelection("\t");
                return true;
            }
        }
        if ((k == w.keysym.@"return" or k == w.keysym.kp_enter) and m.shift and !m.ctrl) {
            st.insertAtSelection(pt.line_separator);
            return true;
        }
        // Backspace at the start of a quote unquotes it one level, to
        // normal text from the first, before it joins the line above.
        if (k == w.keysym.backspace and !m.ctrl and !m.alt) {
            const sel = st.selection();
            const b, _ = st.blockAt(sel[0]);
            const d = st.def(b);
            if (sel[0] == sel[1] and sel[0] == b.start and d.kind == .text and d.style == .blockquote) {
                const change: BlockChange = if (d.level > 1) .{ .indent = -1 } else .{ .style = .normal };
                _ = st.setBlock(change, b.start, b.start);
                return true;
            }
        }
        return false;
    }

    fn insertAtSelection(st: *State, s: []const u8) void {
        const sel = st.selection();
        const lo = @min(sel[0], sel[1]);
        st.editGroup(.insert, lo, null);
        const txn = w.begin(st.window) orelse return;
        c.siv_replace_text(txn, st.editor, lo, @max(sel[0], sel[1]), s.ptr, s.len);
        const after: u32 = lo + @as(u32, @intCast(s.len));
        c.siv_set_selection(txn, st.editor, after, after);
        _ = w.commit(txn);
        if (st.group) |*g| g.pos = after;
        st.edited();
        st.sync();
        if (std.mem.eql(u8, s, pt.line_separator)) st.autolink(lo);
    }

    /// Starts a new undo step unless the edit continues the last one:
    /// typing forward within a word, or a run of deletions.
    fn editGroup(st: *State, kind: GroupKind, pos: u32, inserted: ?[]const u8) void {
        if (st.vim_on and st.vim.undo_held) {
            // Vim's insert mode is one step from the command that began it.
            st.group = .{ .kind = kind, .pos = pos };
            return;
        }
        var continues = if (st.group) |g| g.kind == kind and g.pos == pos else false;
        if (continues and kind == .insert) if (inserted) |s| {
            if (s.len == 1 and std.ascii.isWhitespace(s[0]) and !st.group.?.space) continues = false;
        };
        if (!continues) st.checkpoint(pos, pos);
        st.group = .{ .kind = kind, .pos = pos };
    }

    fn onKey(st: *State, ev: *const siv.Event) siv.EventResult {
        if (!ev.flags.pressed) return .pass;
        // Disabled, it takes every key but Tab, which moves the focus on.
        if (st.data.hdr.disabled) return if (ev.keysym == w.keysym.tab or ev.keysym == w.keysym.iso_left_tab) .pass else .handled;
        st.notifyLater();
        const took = if (st.vim_on) st.vim.key(st, ev) else st.typingKey(ev);
        st.flushChange();
        return w.resultOf(took);
    }

    /// The user edited the text: typing, an input method, a paste, a cut.
    fn onChange(st: *State, ev: *const siv.Event) siv.EventResult {
        if (ev.edit_start == 0 and ev.edit_end == 0 and ev.edit_length == 0) {
            // Styles only (a typing style).
            st.notifyLater();
            return .handled;
        }
        const full = w.str(ev.text, ev.text_len) orelse "";
        const es = ev.edit_start;
        const inserted = if (es + ev.edit_length <= full.len) full[es .. es + ev.edit_length] else "";
        if (ev.edit_end > es and ev.edit_length > 1 and st.pasteLink(es, ev.edit_end, inserted)) {
            if (st.vim_on) st.vim.afterChange(st);
            st.flushChange();
            return .handled;
        }
        // The block the edit began in, before it.
        var old: ?pt.Block = null;
        var old_last_of_def = false;
        for (st.model.blocks, 0..) |b, i| if (es >= b.start and es <= b.stop) {
            old = b;
            old_last_of_def = i + 1 == st.model.blocks.len or st.model.blocks[i + 1].def != b.def;
            break;
        };
        // Text typed at a link's end is not part of it, as in word
        // processors, though siv gives it the style before it.
        const after_link = ev.edit_length > 0 and for (st.model.runs, 0..) |r, i| {
            if (r.ann == 0 or r.stop != es) continue;
            const next = if (i + 1 < st.model.runs.len) st.model.runs[i + 1] else null;
            break next == null or next.?.start != es or next.?.ann != r.ann;
        } else false;
        if (ev.edit_length > 0 and ev.edit_end == es) {
            st.editGroup(.insert, es, inserted);
            st.group.?.pos = es + ev.edit_length;
            st.group.?.space = inserted.len > 0 and std.ascii.isWhitespace(inserted[inserted.len - 1]);
        } else if (ev.edit_length == 0) {
            st.editGroup(.delete, ev.edit_end, null);
            st.group.?.pos = es;
        } else st.editGroup(.replace, std.math.maxInt(u32), null);
        st.edited();
        st.sync();
        if (after_link) {
            if (mapRuns(st, es, es + ev.edit_length, .{ .ann = 0 })) |runs| {
                if (runsEql(runs, st.model.runs)) gpa.free(runs) else st.applyRuns(runs, null);
            } else |_| {}
        }

        if (std.mem.eql(u8, inserted, "\n")) {
            if (old) |o| st.enterRules(o, old_last_of_def, es);
            st.autolink(es);
        }
        if (std.mem.eql(u8, inserted, " ")) {
            st.autolink(es);
            st.markdownPrefix(es);
        }
        if (st.vim_on) st.vim.afterChange(st);
        st.flushChange();
        return .handled;
    }

    /// Enter after a heading starts a normal paragraph; Enter in an empty
    /// list item or on an empty last line of a code block ends it; Enter
    /// at the end of a list, quote, or code block continues it, on the
    /// last line too.
    fn enterRules(st: *State, old: pt.Block, last_of_def: bool, at: u32) void {
        const d = st.def(old);
        if (old.start == old.stop and (d.list != .none or (d.kind == .code and last_of_def))) {
            const txn = w.begin(st.window) orelse return;
            c.siv_replace_text(txn, st.editor, at, at + 1, "", 0);
            _ = w.commit(txn);
            st.sync();
            st.setDefAt(old.start, 0, .{ at, at });
            return;
        }
        if (d.kind == .text and d.style.heading() > 0 and at == old.stop) {
            st.setDefAt(at + 1, 0, null);
            return;
        }
        if (d.list != .none or d.style == .blockquote or d.kind == .code) {
            // siv continues a paragraph's style on the next line, but not
            // on an empty last one.
            const blocks = st.model.blocks;
            const last = blocks[blocks.len - 1];
            if (last.start == at + 1 and last.start == last.stop and last.def == 0) st.setDefAt(last.start, old.def, null);
        }
    }

    /// Gives the block starting at `start` a definition, without an undo
    /// step of its own.
    fn setDefAt(st: *State, start: u32, id: u32, sel: ?[2]u32) void {
        const m = st.model;
        const blocks = gpa.dupe(pt.Block, m.blocks) catch return;
        for (blocks) |*b| if (b.start == start) {
            b.def = id;
        };
        const t = gpa.dupe(u8, m.text) catch return;
        const runs = clipRuns(st, m.runs, blocks) catch return;
        st.apply(.{ .text = t, .blocks = blocks, .runs = runs }, sel);
    }

    /// Markdown at the start of a paragraph: "# " to "###### " make
    /// headings, "- " and "* " bullets, "1. " numbered items, "> " a
    /// quote, "``` " a code block.
    fn markdownPrefix(st: *State, at: u32) void {
        const b, _ = st.blockAt(at);
        const d = st.def(b);
        if (d.kind != .text or d.style != .normal or d.list != .none or at < b.start) return;
        const prefix = st.model.text[b.start..at];
        const change: BlockChange = if (prefix.len >= 1 and prefix.len <= 6 and std.mem.allEqual(u8, prefix, '#'))
            .{ .style = @enumFromInt(prefix.len) }
        else if (std.mem.eql(u8, prefix, "-") or std.mem.eql(u8, prefix, "*"))
            .{ .list = .bullet }
        else if (std.mem.eql(u8, prefix, "1."))
            .{ .list = .number }
        else if (std.mem.eql(u8, prefix, ">"))
            .{ .style = .blockquote }
        else if (std.mem.eql(u8, prefix, "```"))
            .code
        else
            return;
        switch (change) {
            .style => |s| if (!st.allow.style(s)) return,
            .list => |l| if (!st.allow.list(l)) return,
            .code => if (!st.allow.code) return,
            .indent => {},
        }
        const txn = w.begin(st.window) orelse return;
        c.siv_replace_text(txn, st.editor, b.start, at + 1, "", 0);
        _ = w.commit(txn);
        st.sync();
        if (st.setBlock(change, b.start, b.start)) st.dropCheckpoint();
        st.group = null;
    }

    fn onPointer(st: *State, ev: *const siv.Event) siv.EventResult {
        if (ev.phase == .up) {
            st.vim.pointer_y = ev.y;
            st.notifyLater();
            if (st.vim_on) _ = c.siv_post(st.app, postPointer, null, w.handleData(st.root));
        }
        return .pass;
    }

    pub fn updateFlags(st: *State, txn_: ?Txn) void {
        const flags: siv.EditorFlags = .{ .multiline = true, .no_undo = true, .block_caret = st.vim_on and st.vim.modal(), .no_input_method = st.vim_on and st.vim.modal() };
        if (txn_) |txn| return c.siv_set_editor_flags(txn, st.editor, flags);
        const txn = w.begin(st.window) orelse return;
        c.siv_set_editor_flags(txn, st.editor, flags);
        _ = w.commit(txn);
    }

    // State for the application -------------------------------------------

    pub fn setMessage(st: *State, msg: []const u8) void {
        st.message.clearRetainingCapacity();
        st.message.appendSlice(gpa, msg) catch {};
        st.notifyLater();
    }

    /// A Vim command line for the application (":w" gives "w").
    pub fn command(st: *State, s: []const u8) void {
        var handled = false;
        _ = c.siv_node_emit(st.root, &.{ .type = .activate, .text = s.ptr, .text_len = s.len }, &handled);
    }

    fn state(st: *const State) siv.RichTextState {
        const sel = st.selection();
        const b, _ = st.blockAt(sel[0]);
        const d = st.def(b);
        var typing: siv.TextSpan = .{};
        _ = c.siv_node_get_typing_style(st.editor, &typing);
        const marks, var ann = st.marksOf(typing);
        if (ann == 0) {
            const at = if (sel[0] != sel[1]) @min(sel[0], sel[1]) + 1 else sel[0];
            for (st.model.runs) |r| if (r.start < at and at <= r.stop and r.ann != 0) {
                ann = r.ann;
            };
        }
        var out: siv.RichTextState = .{
            .style = switch (d.kind) {
                .code => .code,
                .object => .object,
                .text => @enumFromInt(@intFromEnum(d.style)),
            },
            .list = @enumFromInt(@intFromEnum(d.list)),
            .level = d.level,
            .mode = if (st.vim_on) st.vim.modeOf() else .edit,
            .modified = st.modified,
            .can_undo = st.undo_stack.items.len > 0,
            .can_redo = st.redo_stack.items.len > 0,
        };
        out.marks = .{
            .strong = marks.strong,
            .em = marks.em,
            .underline = marks.underline,
            .strike_through = marks.strike_through,
            .code = marks.code,
            .link = ann != 0,
            .superscript = marks.superscript,
            .subscript = marks.subscript,
        };
        return out;
    }

    fn status(st: *const State, out: *std.ArrayList(u8)) void {
        out.clearRetainingCapacity();
        if (st.vim_on and st.vim.status(out)) return;
        out.appendSlice(gpa, st.message.items) catch {};
    }

    /// Reports a changed state or status line.
    pub fn notify(st: *State) void {
        const now = st.state();
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(gpa);
        st.status(&s);
        if (std.mem.eql(u8, std.mem.asBytes(&now), std.mem.asBytes(&st.reported)) and std.mem.eql(u8, s.items, st.reported_status.items)) return;
        st.reported = now;
        st.reported_status.clearRetainingCapacity();
        st.reported_status.appendSlice(gpa, s.items) catch {};
        var handled = false;
        _ = c.siv_node_emit(st.root, &.{ .type = .select }, &handled);
    }

    /// Notifies once the input being handled has had its default action.
    pub fn notifyLater(st: *State) void {
        if (st.posted) return;
        if (c.siv_post(st.app, postNotify, null, w.handleData(st.root)) == .ok) st.posted = true;
    }

    // Drawing ---------------------------------------------------------------

    fn draw(st: *const State, d: siv.Draw, width: f32) void {
        const muted = w.color(st.window, .muted_fg);
        const ground = w.color(st.window, .control_bg);
        const border = w.color(st.window, .border);
        // Fills blend in linear light, where one opacity reads far
        // stronger on a dark surface than on a light one: these read
        // about as a 12% tint blended in sRGB (a browser's) does.
        const fg = w.color(st.window, .view_fg);
        const tint: f32 = if (fg.r + fg.g + fg.b > 1.5) quote_tint_dark else quote_tint_light;
        var counters: [pt.max_level + 1]u32 = @splat(0);
        const blocks = st.model.blocks;
        var bi: usize = 0;
        while (bi < blocks.len) : (bi += 1) {
            const b = blocks[bi];
            const def_ = st.def(b);
            switch (def_.kind) {
                .text => {
                    if (def_.list == .none) @memset(&counters, 0);
                    if (def_.list != .none) {
                        for (def_.level + 1..counters.len) |l| counters[l] = 0;
                        const r = st.caretRect(b.start);
                        if (def_.list == .number) {
                            counters[def_.level] += 1;
                            var buf: [16]u8 = undefined;
                            const label = std.fmt.bufPrint(&buf, "{d}.", .{counters[def_.level]}) catch "";
                            c.siv_draw_text(d, r.x - 34, r.y, 28, label.ptr, label.len, &.{ .font_size = st.font_size, .line_height = r.height, .@"align" = .end, .color = muted, .flags = .{ .no_wrap = true } });
                        } else {
                            // Bullets are drawn, not glyphs, which fonts
                            // may lack: a disc, a circle, a square.
                            counters[def_.level] = 0;
                            const cx = r.x - 13;
                            const cy = r.y + r.height / 2;
                            const rad = st.font_size * 0.16;
                            switch ((def_.level - 1) % 3) {
                                0 => {
                                    c.siv_draw_ellipse(d, .{ .x = cx - rad, .y = cy - rad, .width = 2 * rad, .height = 2 * rad });
                                    c.siv_draw_fill(d, &.{ .color = muted }, .{});
                                },
                                1 => {
                                    c.siv_draw_ellipse(d, .{ .x = cx - rad + 0.5, .y = cy - rad + 0.5, .width = 2 * rad - 1, .height = 2 * rad - 1 });
                                    c.siv_draw_stroke(d, &.{ .width = 1 }, &.{ .color = muted });
                                },
                                else => {
                                    c.siv_draw_rect(d, .{ .x = cx - rad, .y = cy - rad, .width = 2 * rad, .height = 2 * rad });
                                    c.siv_draw_fill(d, &.{ .color = muted }, .{});
                                },
                            }
                        }
                    } else if (def_.style == .blockquote) {
                        // A bar per level, each in its hue over a faint
                        // tint of it, the innermost level's reaching the
                        // text's end, so the quotes of a quoted reply
                        // nest as mail readers show them. Levels the
                        // block above has too go on up across the gap.
                        const r = st.caretRect(b.start);
                        const e = st.caretRect(b.stop);
                        const level = @max(def_.level, 1);
                        const above = if (bi > 0) st.def(blocks[bi - 1]) else pt.Def{};
                        const prev: u8 = if (above.kind == .text and above.style == .blockquote) @max(above.level, 1) else 0;
                        const prev_bottom = if (prev > 0) blk: {
                            const p = st.caretRect(blocks[bi - 1].stop);
                            break :blk p.y + p.height;
                        } else 0;
                        for (0..level) |k| {
                            const x = r.x - 14 - quote_indent * @as(f32, @floatFromInt(level - 1 - k));
                            const top = if (prev > k) prev_bottom else r.y;
                            const end_x = if (k + 1 == level) width - pad_x else x + quote_indent;
                            const hue = w.color(st.window, quote_hues[k % quote_hues.len]);
                            c.siv_draw_rect(d, .{ .x = x, .y = top, .width = end_x - x, .height = e.y + e.height - top });
                            c.siv_draw_fill(d, &.{ .color = .{ .r = hue.r, .g = hue.g, .b = hue.b, .a = tint } }, .{});
                            c.siv_draw_rounded_rect(d, .{ .x = x, .y = top, .width = 3, .height = e.y + e.height - top }, .{ .top_left = 1.5, .top_right = 1.5, .bottom_right = 1.5, .bottom_left = 1.5 });
                            c.siv_draw_fill(d, &.{ .color = hue }, .{});
                        }
                    }
                },
                .code => {
                    @memset(&counters, 0);
                    var j = bi;
                    while (j + 1 < blocks.len and blocks[j + 1].def == b.def) j += 1;
                    const top = st.caretRect(b.start);
                    const bottom = st.caretRect(blocks[j].stop);
                    const rect: siv.Rect = .{ .x = pad_x, .y = top.y - 8, .width = width - 2 * pad_x, .height = bottom.y + bottom.height - top.y + 16 };
                    c.siv_draw_rounded_rect(d, rect, .{ .top_left = 6, .top_right = 6, .bottom_right = 6, .bottom_left = 6 });
                    c.siv_draw_fill(d, &.{ .color = ground }, .{});
                    const lang = pt.language(def_.raw);
                    if (lang.len > 0) c.siv_draw_text(d, rect.x + 8, rect.y + 4, rect.width - 16, lang.ptr, lang.len, &.{ .font_size = 11, .@"align" = .end, .color = muted, .flags = .{ .no_wrap = true } });
                    bi = j;
                },
                .object => {
                    @memset(&counters, 0);
                    const r = st.caretRect(b.start);
                    const rect: siv.Rect = .{ .x = pad_x, .y = r.y - 4, .width = width - 2 * pad_x, .height = r.height + 8 };
                    c.siv_draw_rounded_rect(d, rect, .{ .top_left = 6, .top_right = 6, .bottom_right = 6, .bottom_left = 6 });
                    c.siv_draw_fill(d, &.{ .color = ground }, .{});
                    c.siv_draw_rounded_rect(d, rect, .{ .top_left = 6, .top_right = 6, .bottom_right = 6, .bottom_left = 6 });
                    c.siv_draw_stroke(d, &.{ .width = 1 }, &.{ .color = border });
                    var buf: [128]u8 = undefined;
                    const label = if (def_.raw) |raw| pt.describe(&buf, raw) else "object";
                    c.siv_draw_text(d, r.x + 8, r.y, rect.width - 24, label.ptr, label.len, &.{ .font_size = st.font_size * 0.875, .line_height = r.height, .color = muted, .flags = .{ .no_wrap = true } });
                },
            }
        }
    }
};

fn stateOf(node: Node) ?*State {
    const h = w.header(node) orelse return null;
    if (h.kind != .rich_text) return null;
    const data: *Data = @ptrCast(h);
    return data.st;
}

fn spanEq(a: siv.TextSpan, b: siv.TextSpan) bool {
    const fa: u32 = @bitCast(a.flags);
    if (fa != @as(u32, @bitCast(b.flags))) return false;
    const f = a.flags;
    if (f.weight and a.weight != b.weight) return false;
    if (f.slant and a.slant != b.slant) return false;
    if (f.size and @abs(a.font_size - b.font_size) > 0.01) return false;
    if (f.family and a.family != b.family) return false;
    if (f.color and (a.color_token != b.color_token or @abs(a.color.r - b.color.r) > 1e-6 or @abs(a.color.g - b.color.g) > 1e-4 or @abs(a.color.b - b.color.b) > 1e-4 or @abs(a.color.a - b.color.a) > 1e-4)) return false;
    return true;
}

/// Whether spans read from the node show what the wanted ones do: the
/// same runs once neighbors with the same attributes merge.
fn spansMatch(read: []const siv.TextSpan, want: []const siv.TextSpan) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < read.len and read[i].end <= read[i].start) i += 1;
        while (j < want.len and want[j].end <= want[j].start) j += 1;
        if (i == read.len or j == want.len) return i == read.len and j == want.len;
        var a = read[i];
        var b = want[j];
        i += 1;
        j += 1;
        while (i < read.len and read[i].start == a.end and spanEq(read[i], a)) : (i += 1) a.end = read[i].end;
        while (j < want.len and want[j].start == b.end and spanEq(want[j], b)) : (j += 1) b.end = want[j].end;
        if (a.start != b.start or a.end != b.end or !spanEq(a, b)) return false;
    }
}

fn paraEq(a: siv.ParagraphSpan, b: siv.ParagraphSpan) bool {
    const fa: u32 = @as(u32, @bitCast(a.flags)) & siv.ParagraphFlags.known_bits;
    if (fa != @as(u32, @bitCast(b.flags)) & siv.ParagraphFlags.known_bits) return false;
    const f = a.flags;
    if (f.@"align" and a.@"align" != b.@"align") return false;
    if (f.indent and (@abs(a.indent_start - b.indent_start) > 0.01 or @round(a.indent_end / tag_step) != @round(b.indent_end / tag_step))) return false;
    if (f.line_spacing and @abs(a.line_spacing - b.line_spacing) > 0.001) return false;
    if (f.paragraph_spacing and (@abs(a.space_before - b.space_before) > 0.01 or @abs(a.space_after - b.space_after) > 0.01)) return false;
    return true;
}

/// Read paragraphs are one per paragraph; wanted ones only the styled.
fn parasMatch(read: []const siv.ParagraphSpan, want: []const siv.ParagraphSpan) bool {
    var j: usize = 0;
    for (read) |p| {
        if (j < want.len and want[j].start == p.start) {
            if (!paraEq(p, want[j])) return false;
            j += 1;
        } else if (@as(u32, @bitCast(p.flags)) & siv.ParagraphFlags.known_bits != 0) return false;
    }
    return j == want.len;
}

fn runsEql(a: []const pt.Run, b: []const pt.Run) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.start != y.start or x.stop != y.stop or !x.marks.eql(y.marks) or x.ann != y.ann) return false;
    return true;
}

fn startsWithAny(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// The href of text that is a URL as typed or pasted, owned by the
/// caller: http://, https://, and mailto: ones as they are, www. ones
/// with https://; null for other text.
fn urlHref(s: []const u8) ?[]u8 {
    for (s) |ch| if (ch <= ' ' or ch == 0x7f) return null;
    if (std.mem.indexOf(u8, s, pt.line_separator) != null or std.mem.indexOf(u8, s, pt.object_char) != null) return null;
    for ([_][]const u8{ "https://", "http://" }) |scheme| {
        if (startsWithAny(s, scheme) and s.len > scheme.len and std.ascii.isAlphanumeric(s[scheme.len])) return gpa.dupe(u8, s) catch null;
    }
    if (startsWithAny(s, "mailto:") and std.mem.indexOfScalarPos(u8, s, 8, '@') != null) return gpa.dupe(u8, s) catch null;
    if (startsWithAny(s, "www.") and s.len > 4 and std.ascii.isAlphanumeric(s[4]) and std.mem.indexOfScalarPos(u8, s, 5, '.') != null) {
        return std.mem.concat(gpa, u8, &.{ "https://", s }) catch null;
    }
    return null;
}

/// What the user typed into the link editor or :link as an href, owned
/// by the caller: trimmed; with a scheme (RFC 3986) or as a relative
/// reference ("/", "#", "?") as it is, an address with mailto:, anything
/// else with https://. Null when empty.
pub fn hrefOf(s: []const u8) ?[]u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    const scheme = if (std.mem.indexOfScalar(u8, t, ':')) |colon| colon > 0 and std.ascii.isAlphabetic(t[0]) and for (t[1..colon]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') break false;
    } else true else false;
    if (scheme or t[0] == '/' or t[0] == '#' or t[0] == '?') return gpa.dupe(u8, t) catch null;
    const mail = std.mem.indexOfScalar(u8, t, '@') != null and std.mem.indexOfScalar(u8, t, '/') == null;
    return std.mem.concat(gpa, u8, &.{ if (mail) "mailto:" else "https://", t }) catch null;
}

/// Runs kept only where they lie in text blocks.
fn clipRuns(st: *const State, runs: []const pt.Run, blocks: []const pt.Block) ![]pt.Run {
    var out: std.ArrayList(pt.Run) = .empty;
    errdefer out.deinit(gpa);
    var bi: usize = 0;
    for (runs) |r| {
        while (bi > 0 and blocks[bi].start > r.start) bi -= 1;
        var k = bi;
        while (k < blocks.len and blocks[k].start < r.stop) : (k += 1) {
            const b = blocks[k];
            if (b.stop <= r.start and !(b.start == b.stop and b.start == r.start)) continue;
            if (st.def(b).kind != .text) continue;
            const s = @max(r.start, b.start);
            const e = @min(r.stop, b.stop);
            if (e > s) try out.append(gpa, .{ .start = s, .stop = e, .marks = r.marks, .ann = r.ann });
        }
        bi = if (k > 0) k - 1 else 0;
    }
    return out.toOwnedSlice(gpa);
}

/// What mapRuns does to every character of a range: sets or clears a
/// decorator, or gives it an annotation (0 for none).
const RunChange = union(enum) {
    mark: struct { mark: pt.Marks, on: bool },
    ann: u32,
};

/// Runs with a change made to every character of lo..hi.
fn mapRuns(st: *const State, lo: u32, hi: u32, change: RunChange) ![]pt.Run {
    const m = st.model;
    var out: std.ArrayList(pt.Run) = .empty;
    errdefer out.deinit(gpa);
    const add = struct {
        fn f(list: *std.ArrayList(pt.Run), s: u32, e: u32, marks: pt.Marks, ann: u32) !void {
            if (e <= s or (!marks.any() and ann == 0)) return;
            if (list.items.len > 0) {
                const last = &list.items[list.items.len - 1];
                if (last.stop == s and last.ann == ann and last.marks.eql(marks)) {
                    last.stop = e;
                    return;
                }
            }
            try list.append(gpa, .{ .start = s, .stop = e, .marks = marks, .ann = ann });
        }
    }.f;
    const set = struct {
        fn f(marks: pt.Marks, bit: pt.Marks, yes: bool) pt.Marks {
            var res = pt.Marks.of(if (yes) marks.bits() | bit.bits() else marks.bits() & ~bit.bits());
            // Superscript and subscript replace each other.
            if (yes and bit.superscript) res.subscript = false;
            if (yes and bit.subscript) res.superscript = false;
            return res;
        }
    }.f;
    // Split the document at lo and hi and at every run boundary, then
    // map each piece.
    var at: u32 = 0;
    var ri: usize = 0;
    const len: u32 = @intCast(m.text.len);
    while (at < len) {
        var next = len;
        var marks: pt.Marks = .{};
        var ann: u32 = 0;
        while (ri < m.runs.len and m.runs[ri].stop <= at) ri += 1;
        if (ri < m.runs.len and m.runs[ri].start <= at) {
            marks = m.runs[ri].marks;
            ann = m.runs[ri].ann;
            next = m.runs[ri].stop;
        } else if (ri < m.runs.len) next = m.runs[ri].start;
        if (at < lo) next = @min(next, lo) else if (at < hi) next = @min(next, hi);
        if (at >= lo and at < hi) switch (change) {
            .mark => |m_| marks = set(marks, m_.mark, m_.on),
            .ann => |a| ann = a,
        };
        try add(&out, at, next, marks, ann);
        at = next;
    }
    const runs = try out.toOwnedSlice(gpa);
    defer gpa.free(runs);
    return clipRuns(st, runs, m.blocks);
}

/// A model with a fragment's marks and blocks over the text at `at`,
/// which is the fragment's text.
pub fn overlay(m: pt.Model, at: u32, f: pt.Model) !pt.Model {
    const e: u32 = at + @as(u32, @intCast(f.text.len));
    var runs: std.ArrayList(pt.Run) = .empty;
    errdefer runs.deinit(gpa);
    for (m.runs) |r| {
        if (r.start >= at) break;
        try runs.append(gpa, .{ .start = r.start, .stop = @min(r.stop, at), .marks = r.marks, .ann = r.ann });
    }
    for (f.runs) |r| try runs.append(gpa, .{ .start = r.start + at, .stop = r.stop + at, .marks = r.marks, .ann = r.ann });
    for (m.runs) |r| if (r.stop > e) try runs.append(gpa, .{ .start = @max(r.start, e), .stop = r.stop, .marks = r.marks, .ann = r.ann });
    const blocks = try gpa.dupe(pt.Block, m.blocks);
    errdefer gpa.free(blocks);
    for (blocks) |*b| {
        if (b.start < at or b.start >= e and !(b.start == at and e == at)) continue;
        for (f.blocks) |fb| if (fb.start + at == b.start) {
            b.def = fb.def;
            break;
        };
    }
    const t = try gpa.dupe(u8, m.text);
    errdefer gpa.free(t);
    return .{ .text = t, .blocks = blocks, .runs = try runs.toOwnedSlice(gpa) };
}

// Callbacks -------------------------------------------------------------------

fn stOf(ud: ?*anyopaque) *State {
    return @ptrCast(@alignCast(ud.?));
}

fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    return stOf(ud).onKey(ev);
}

fn onChange(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    return stOf(ud).onChange(ev);
}

fn onPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    return stOf(ud).onPointer(ev);
}

fn onFocus(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    stOf(ud).notifyLater();
    return .pass;
}

fn postNotify(ud: ?*anyopaque) callconv(.c) void {
    const st = stateOf(w.dataHandle(ud)) orelse return;
    st.posted = false;
    st.notify();
}

/// Enter in a link editor's field applies it (on its buttons, Enter
/// presses them).
fn onLinkKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    if (!ev.flags.pressed or (ev.keysym != w.keysym.@"return" and ev.keysym != w.keysym.kp_enter)) return .pass;
    const st = stateOf(w.dataHandle(ud)) orelse return .pass;
    if (ev.target != st.link.url and (ev.target != st.link.text or st.link.text == .null)) return .pass;
    st.finishLink(false);
    return .handled;
}

fn onLinkApply(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st = stateOf(w.dataHandle(ud)) orelse return .pass;
    st.finishLink(false);
    return .handled;
}

fn onLinkRemove(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st = stateOf(w.dataHandle(ud)) orelse return .pass;
    st.finishLink(true);
    return .handled;
}

fn postPointer(ud: ?*anyopaque) callconv(.c) void {
    const st = stateOf(w.dataHandle(ud)) orelse return;
    st.vim.afterPointer(st);
}

fn drawCanvas(ud: ?*anyopaque, _: Node, d: siv.Draw, width: f32, _: f32) callconv(.c) void {
    stOf(ud).draw(d, width);
}

fn destroy(ud: ?*anyopaque) callconv(.c) void {
    const st = stOf(ud);
    st.deinit();
    gpa.destroy(st);
}

fn setLabel(txn: Txn, data: *Data, label: []const u8) void {
    const name = if (label.len > 0) label else "Document";
    c.siv_set_semantics(txn, data.st.editor, &.{ .label = name.ptr, .label_len = name.len, .flags = .{ .disabled = data.hdr.disabled } });
}

fn applyDisabled(txn: Txn, data: *Data) void {
    const st = data.st;
    c.siv_set_text_style(txn, st.editor, &.{ .font_size = st.font_size, .line_spacing = 1.5, .space_after = 10, .color_token = if (data.hdr.disabled) .disabled_fg else .view_fg });
    var buf: [1024]u8 = undefined;
    setLabel(txn, data, w.labelOf(st.editor, &buf));
}

fn focusOf(data: *Data) Node {
    return data.st.editor;
}

fn allowOf(d: siv.RichTextDesc) pt.Allow {
    if (d.schema == .emdash) return .{};
    const s: u32 = @bitCast(d.styles);
    return .{
        .styles = @intCast(s & 0x7f),
        .marks = .{
            .strong = d.marks.strong,
            .em = d.marks.em,
            .underline = d.marks.underline,
            .strike_through = d.marks.strike_through,
            .code = d.marks.code,
            .superscript = d.marks.superscript,
            .subscript = d.marks.subscript,
        },
        .link = d.marks.link,
        .bullet = d.blocks.bullet_list,
        .number = d.blocks.number_list,
        .code = d.blocks.code,
        .objects = false,
    };
}

// The C API -------------------------------------------------------------------

pub export fn siv_rich_text(txn: Txn, parent: Node, desc: ?*const siv.RichTextDesc) Node {
    const d = w.readDesc(siv.RichTextDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 1) != 0 or d.reserved0 != 0 or d.reserved1 != 0) return w.fail(txn, .error_unsupported);
    const styles: u32 = @bitCast(d.styles);
    const marks: u32 = @bitCast(d.marks);
    const blocks: u32 = @bitCast(d.blocks);
    switch (d.schema) {
        .emdash => if (styles | marks | blocks != 0) return w.fail(txn, .error_invalid_argument),
        .custom => if (styles & ~@as(u32, 0x7f) != 0 or marks & ~@as(u32, 0xff) != 0 or blocks & ~@as(u32, 7) != 0) return w.fail(txn, .error_unsupported),
        _ => return w.fail(txn, .error_unsupported),
    }
    if (!(d.font_size >= 0) or d.font_size > 1000) return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const placeholder = w.str(d.placeholder, d.placeholder_len) orelse return w.fail(txn, .error_invalid_argument);
    const document = w.str(d.document, d.document_len) orelse return w.fail(txn, .error_invalid_argument);
    const window = w.windowOf(parent);
    const st = gpa.create(State) catch return w.fail(txn, .error_out_of_memory);
    st.* = .{
        .root = .null,
        .window = window,
        .app = w.appOf(window),
        .allow = allowOf(d),
        .font_size = if (d.font_size == 0) 16 else d.font_size,
        .vim_on = d.flags.vim,
        .reg = pt.Registry.init(gpa) catch {
            gpa.destroy(st);
            return w.fail(txn, .error_out_of_memory);
        },
    };
    var warnings: std.ArrayList(u8) = .empty;
    defer warnings.deinit(gpa);
    const model = pt.import(&st.reg, gpa, document, st.allow, &warnings) catch |e| {
        st.deinit();
        gpa.destroy(st);
        return w.fail(txn, if (e == error.OutOfMemory) .error_out_of_memory else .error_invalid_argument);
    };
    st.model = model;
    st.message.appendSlice(gpa, warnings.items) catch {};
    _ = c.siv_app_get_font_family(st.app, "monospace", 9, &st.mono);

    const root = c.siv_stack(txn, parent, null);
    if (root == .null) {
        st.deinit();
        gpa.destroy(st);
        return .null;
    }
    st.root = root;
    const data = w.create(Data, txn, root) orelse {
        st.deinit();
        gpa.destroy(st);
        return .null;
    };
    data.* = .{ .hdr = .{ .kind = .rich_text }, .st = st };
    st.data = data;
    c.siv_set_default_layout(txn, root, &.{ .width = .{ .unit = .fraction, .value = 1 } });
    // From here the canvas owns the state.
    st.canvas = c.siv_canvas(txn, root, &.{ .user_data = st, .draw = drawCanvas, .destroy = destroy });
    if (st.canvas == .null) {
        st.deinit();
        gpa.destroy(st);
        return .null;
    }
    c.siv_set_layout(txn, st.canvas, &.{ .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
    c.siv_set_visual(txn, st.canvas, &.{ .flags = .{ .no_hit_test = true } });
    st.editor = c.siv_editor(txn, root, .{ .multiline = true, .no_undo = true });
    c.siv_set_layout(txn, st.editor, &.{ .width = .{ .unit = .fraction, .value = 1 }, .padding = .{ .start = pad_x, .end = pad_x, .top = pad_y, .bottom = pad_y } });
    c.siv_set_visual(txn, st.editor, &.{ .flags = .{ .no_focus_ring = true } });
    c.siv_set_placeholder(txn, st.editor, placeholder.ptr, placeholder.len);
    st.updateFlags(txn);
    w.onDefault(txn, st.editor, .key, onKey, st);
    w.onDefault(txn, st.editor, .change, onChange, st);
    w.onDefault(txn, st.editor, .pointer, onPointer, st);
    w.onDefault(txn, st.editor, .focus, onFocus, st);
    w.setInterface(txn, root, Data, data, .{ .set_label = setLabel, .apply = applyDisabled, .focus = focusOf });
    applyDisabled(txn, data);
    setLabel(txn, data, label);
    st.write(txn, st.model, true);
    c.siv_set_selection(txn, st.editor, 0, 0);
    return if (c.siv_txn_status(txn) == .ok) root else .null;
}

pub export fn siv_rich_text_set_document(txn: Txn, node: Node, document: ?[*]const u8, document_len: usize) void {
    const st = stateOf(node) orelse {
        _ = c.siv_txn_fail(txn, .error_invalid_argument);
        return;
    };
    const s = w.str(document, document_len) orelse {
        _ = c.siv_txn_fail(txn, .error_invalid_argument);
        return;
    };
    var reg = pt.Registry.init(gpa) catch {
        _ = c.siv_txn_fail(txn, .error_out_of_memory);
        return;
    };
    var warnings: std.ArrayList(u8) = .empty;
    defer warnings.deinit(gpa);
    const m = pt.import(&reg, gpa, s, st.allow, &warnings) catch |e| {
        reg.deinit();
        _ = c.siv_txn_fail(txn, if (e == error.OutOfMemory) .error_out_of_memory else .error_invalid_argument);
        return;
    };
    st.clearHistory();
    st.reg.deinit();
    st.reg = reg;
    st.tail = null;
    st.setModel(m);
    st.modified = false;
    st.vim.reset();
    // The register's blocks and links index the registry just replaced.
    st.vim.clearRegister();
    st.message.clearRetainingCapacity();
    st.message.appendSlice(gpa, warnings.items) catch {};
    st.write(txn, st.model, true);
    c.siv_set_selection(txn, st.editor, 0, 0);
    st.updateFlags(txn);
    st.notifyLater();
}

pub export fn siv_rich_text_set_flags(txn: Txn, node: Node, flags: siv.RichTextFlags) void {
    const st = stateOf(node) orelse {
        _ = c.siv_txn_fail(txn, .error_invalid_argument);
        return;
    };
    if (@as(u32, @bitCast(flags)) & ~@as(u32, 1) != 0) {
        _ = c.siv_txn_fail(txn, .error_unsupported);
        return;
    }
    if (flags.vim == st.vim_on) return;
    st.vim_on = flags.vim;
    st.vim.reset();
    st.updateFlags(txn);
    if (st.vim_on) {
        const sel = st.selection();
        c.siv_set_selection(txn, st.editor, sel[0], sel[0]);
    }
    st.notifyLater();
}

fn copyOut(s: []const u8, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) siv.Result {
    if (buffer_cap > 0 and buffer == null) return .error_invalid_argument;
    if (len) |l| l.* = s.len;
    if (buffer) |b| @memcpy(b[0..@min(s.len, buffer_cap)], s[0..@min(s.len, buffer_cap)]);
    return .ok;
}

pub export fn siv_rich_text_get_document(node: Node, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) siv.Result {
    const st = stateOf(node) orelse return .error_invalid_argument;
    const out = pt.exportJson(&st.reg, gpa, st.model) catch return .error_out_of_memory;
    defer gpa.free(out);
    return copyOut(out, buffer, buffer_cap, len);
}

pub export fn siv_rich_text_run(node: Node, command: siv.RichTextCommand) siv.Result {
    const st = stateOf(node) orelse return .error_invalid_argument;
    if (@intFromEnum(command) < 0 or @intFromEnum(command) > @intFromEnum(siv.RichTextCommand.link)) return .error_unsupported;
    // Not inside an open transaction of the window.
    const probe = w.begin(st.window) orelse return .error_busy;
    _ = w.commit(probe);
    return st.run(command);
}

pub export fn siv_rich_text_get_state(node: Node, out: ?*siv.RichTextState) siv.Result {
    const st = stateOf(node) orelse return .error_invalid_argument;
    (out orelse return .error_invalid_argument).* = st.state();
    return .ok;
}

pub export fn siv_rich_text_get_status(node: Node, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) siv.Result {
    const st = stateOf(node) orelse return .error_invalid_argument;
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(gpa);
    st.status(&s);
    return copyOut(s.items, buffer, buffer_cap, len);
}

pub export fn siv_rich_text_get_selection(node: Node, caret: ?*u32, anchor: ?*u32) siv.Result {
    const st = stateOf(node) orelse return .error_invalid_argument;
    if (caret == null or anchor == null) return .error_invalid_argument;
    const sel = st.selection();
    caret.?.* = sel[0];
    anchor.?.* = sel[1];
    return .ok;
}

pub export fn siv_rich_text_get_link(node: Node, href: ?[*]u8, href_cap: usize, len: ?*usize, start: ?*u32, end: ?*u32) siv.Result {
    const st = stateOf(node) orelse return .error_invalid_argument;
    if ((href_cap > 0 and href == null) or len == null) return .error_invalid_argument;
    const sel = st.selection();
    const l = st.caretLink(@min(sel[0], sel[1]), @max(sel[0], sel[1]));
    if (start) |p| p.* = if (l) |x| x.start else sel[0];
    if (end) |p| p.* = if (l) |x| x.stop else sel[0];
    return copyOut(if (l) |x| st.reg.href(x.ann) else "", href, href_cap, len);
}

/// The state for a link call: not inside an open transaction of the
/// window, and with links in the schema.
fn linkState(node: Node, href: ?[*]const u8, href_len: usize) union(enum) { ok: struct { *State, []const u8 }, err: siv.Result } {
    const st = stateOf(node) orelse return .{ .err = .error_invalid_argument };
    const url = w.str(href, href_len) orelse return .{ .err = .error_invalid_argument };
    if (!st.allow.link) return .{ .err = .error_unsupported };
    const probe = w.begin(st.window) orelse return .{ .err = .error_busy };
    _ = w.commit(probe);
    return .{ .ok = .{ st, url } };
}

fn linked(st: *State) siv.Result {
    if (st.vim_on) st.vim.afterChange(st);
    st.flushChange();
    st.notify();
    return .ok;
}

pub export fn siv_rich_text_set_link(node: Node, href: ?[*]const u8, href_len: usize) siv.Result {
    const st, const url = switch (linkState(node, href, href_len)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    const sel = st.selection();
    const lo = @min(sel[0], sel[1]);
    const hi = @max(sel[0], sel[1]);
    if (lo != hi) {
        _ = st.setLink(lo, hi, url);
    } else if (st.caretLink(lo, hi)) |l| {
        _ = st.setLink(l.start, l.stop, url);
    } else if (url.len > 0) st.insertLink(lo, lo, url, url);
    return linked(st);
}

pub export fn siv_rich_text_set_link_range(node: Node, start: u32, end: u32, href: ?[*]const u8, href_len: usize) siv.Result {
    const st, const url = switch (linkState(node, href, href_len)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    const t = st.model.text;
    if (start > t.len or end > t.len) return .error_invalid_argument;
    var ends = [2]u32{ @min(start, end), @max(start, end) };
    // An offset inside a character counts as its start.
    for (&ends) |*o| while (o.* > 0 and o.* < t.len and t[o.*] & 0xc0 == 0x80) {
        o.* -= 1;
    };
    _ = st.setLink(ends[0], ends[1], url);
    return linked(st);
}

pub export fn siv_rich_text_mark_saved(node: Node) siv.Result {
    const st = stateOf(node) orelse return .error_invalid_argument;
    st.modified = false;
    st.notifyLater();
    return .ok;
}
