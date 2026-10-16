//! Editor nodes (D15): caret, selection, and editing on the text `Layout`
//! (cluster map, grapheme and word boundaries, bidi levels); no other text
//! state. Edits commit through a transaction of their own and then send
//! the editor a `change` event, and are recorded for undo (except in
//! masked editors). Composed text from xkbcommon arrives as key text.

const std = @import("std");
const raster = @import("raster");
const text = @import("text");
const platform = @import("platform");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const text_node = @import("text_node.zig");
const input = @import("input.zig");
const layout = @import("layout.zig");
const secret = @import("secret.zig");
const bullet = @import("txn.zig").bullet;
const spans = @import("spans.zig");

const NodeId = node_mod.NodeId;
const Point = raster.Point;
const Rect = raster.Rect;
const Layout = text.TextLayout;
const Position = text.cursor.Position;
const keysym = input.keysym;

const backspace: u32 = 0xff08;
const delete: u32 = 0xffff;
const insert_key: u32 = 0xff63;

/// The editor's layout for its current text, rebuilt if the text changed
/// since the last frame.
fn fresh(win: *Window, id: NodeId) ?*const Layout {
    const s = win.state(id);
    if (!s.needs_shape) if (text_node.current(win, id)) |l| return l;
    const width = if (s.text) |c| c.layout_width else null;
    return text_node.layoutFor(win, id, width) catch null;
}

fn data(win: *const Window, id: NodeId) *node_mod.EditorData {
    return &win.node(id).data.editor;
}

fn contentOrigin(win: *const Window, id: NodeId) Point {
    const n = win.node(id);
    const s = win.state(id);
    return .{ .x = n.layout.padding.left(s.rtl) - s.editor_scroll, .y = n.layout.padding.top };
}

fn contentWidth(win: *const Window, id: NodeId) f32 {
    return win.state(id).size.w - win.node(id).layout.padding.horizontal();
}

/// The text shaped and shown: the content, with an input method's preedit
/// at the caret.
/// A new reference: the content's own, or a rope that shares all of it
/// but the leaf the preedit goes in.
pub fn displayText(win: *const Window, id: NodeId) error{OutOfMemory}!text.Rope {
    const e = data(win, id);
    const pre = win.ime.preeditFor(id) orelse return e.text.content.retain();
    return e.text.content.replace(win.gpa, e.caret, e.caret, pre);
}

/// The caret's offset in the shown text: inside the preedit while there
/// is one.
pub fn displayCaret(win: *const Window, id: NodeId) u32 {
    const e = data(win, id);
    const pre = win.ime.preeditFor(id) orelse return e.caret;
    const at: u32 = @intCast(std.math.clamp(win.ime.cursor_begin, 0, @as(i32, @intCast(pre.len))));
    return e.caret + at;
}

/// The preedit's range in the shown text, to underline.
pub fn preeditRange(win: *const Window, id: NodeId) ?[2]u32 {
    const pre = win.ime.preeditFor(id) orelse return null;
    const c = data(win, id).caret;
    return .{ c, c + @as(u32, @intCast(pre.len)) };
}

/// Applies an input method commit: deletes `before` and `after` bytes
/// around the selection, replaces the selection with `str`.
pub fn imeCommit(win: *Window, id: NodeId, before: u32, after: u32, str: []const u8) void {
    const e = data(win, id);
    const content = e.text.content;
    const len: u32 = @intCast(content.len());
    var rd = content.reader();
    const lo, const hi = selection(e);
    var start = lo -| before;
    while (start > 0 and start < len and rd.at(start) & 0xc0 == 0x80) start -= 1;
    var end = @min(len, hi + after);
    while (end < len and rd.at(end) & 0xc0 == 0x80) end += 1;
    replace(win, id, start, end, str, if (start == end) .typing else .other);
}

/// The caret rectangle in content coordinates (before editor scrolling).
pub fn caretRect(win: *const Window, id: NodeId, l: *const Layout) error{OutOfMemory}!Rect {
    const e = data(win, id);
    const block = e.editor.block_caret and win.ime.preeditFor(id) == null;
    // A block caret at the end of a selection covers the selection's
    // last grapheme: the cursor of a modal editor's visual mode.
    if (block and e.anchor < e.caret)
        return caretRectAt(win, id, l, .{ .offset = try l.previousGrapheme(e.caret), .affinity = .downstream }, true);
    return caretRectAt(win, id, l, .{ .offset = displayCaret(win, id), .affinity = e.affinity }, block);
}

/// The caret rectangle at `pos` in content coordinates. A block caret
/// covers the grapheme after it on its line; where there is none (a
/// line's end, an empty line), it is as wide as an "x" in the font and
/// size there: the last character's on the line, else the line break's.
pub fn caretRectAt(win: *const Window, id: NodeId, l: *const Layout, pos: Position, block: bool) error{OutOfMemory}!Rect {
    const c = try l.caret(pos);
    const line = try l.line(c.line);
    const shift = text_node.lineShift(win, id, line, contentWidth(win, id));
    if (!block) return .xywh(c.x + shift, c.top, layout.caret_width, c.height);
    const next = try l.nextGrapheme(pos.offset);
    if (next != pos.offset) {
        const n = try l.caret(.{ .offset = next, .affinity = .upstream });
        if (n.line == c.line and n.x != c.x)
            return .xywh(@min(c.x, n.x) + shift, c.top, @abs(n.x - c.x), c.height);
    }
    const at = if (pos.offset > line.start) try l.previousGrapheme(pos.offset) else pos.offset;
    const w = l.shaped.xAdvance(at) orelse c.height / 2;
    return .xywh(c.x + shift, c.top, w, c.height);
}

/// Keeps a single-line editor's caret in view; call after layout.
pub fn scrollToCaret(win: *Window, id: NodeId) void {
    const s = win.state(id);
    const e = data(win, id);
    const l = text_node.current(win, id) orelse return;
    if (e.editor.multiline or l.lineCount() == 0) {
        s.editor_scroll = 0;
        return;
    }
    const w = contentWidth(win, id);
    const line = l.line(0) catch return;
    const x0 = line.x + text_node.lineShift(win, id, line, w);
    const lo = @min(0, x0);
    const hi = @max(0, x0 + line.width + layout.caret_width - w);
    const c = caretRect(win, id, l) catch return;
    var scroll = s.editor_scroll;
    if (c.x1 - scroll > w) scroll = c.x1 - w;
    if (c.x0 - scroll < 0) scroll = c.x0;
    s.editor_scroll = std.math.clamp(scroll, lo, hi);
}

/// The text position under a point in the editor's coordinates.
pub fn positionAt(win: *Window, id: NodeId, local: Point) ?Position {
    const l = fresh(win, id) orelse return null;
    const o = contentOrigin(win, id);
    const x = local.x - o.x;
    const y = local.y - o.y;
    const line = l.line(l.lineAt(y) catch return null) catch return null;
    return l.hitTest(x - text_node.lineShift(win, id, line, contentWidth(win, id)), y) catch null;
}

/// What a multi-click selects, and what dragging after it extends by.
pub const Unit = enum { grapheme, word, paragraph };

/// The selection a press started: its unit and the range it selected,
/// which dragging keeps selected.
pub const Gesture = struct { unit: Unit = .grapheme, start: u32 = 0, end: u32 = 0 };

/// The word (or run of spaces or punctuation, UAX #29) at an offset.
fn wordAt(l: *const Layout, offset: u32) error{OutOfMemory}![2]u32 {
    return l.shaped.wordAt(offset);
}

/// The paragraph at an offset, without its separator.
fn paragraphAt(l: *const Layout, offset: u32) error{OutOfMemory}![2]u32 {
    return l.shaped.paragraphRange(offset);
}

fn unitAt(l: *const Layout, unit: Unit, offset: u32) error{OutOfMemory}![2]u32 {
    return switch (unit) {
        .grapheme => .{ offset, offset },
        .word => wordAt(l, offset),
        .paragraph => paragraphAt(l, offset),
    };
}

/// A primary press at a window point: places the caret (extends the
/// selection with shift); a double click selects a word, a triple click
/// a paragraph.
pub fn pointerDown(win: *Window, id: NodeId, p: Point, extend: bool, clicks: u8) void {
    if (win.ime.preeditFor(id) != null) @import("ime.zig").reset(win);
    const pos = positionAt(win, id, input.toLocal(win, id, p)) orelse return;
    const e = data(win, id);
    const unit: Unit = switch (clicks) {
        0, 1 => .grapheme,
        2 => .word,
        else => .paragraph,
    };
    // Masked text has no words to show.
    const effective: Unit = if (e.editor.masked and unit == .word) .paragraph else unit;
    if (effective == .grapheme or extend) {
        win.input.gesture = .{ .unit = .grapheme, .start = pos.offset, .end = pos.offset };
        select(win, id, pos, if (extend) e.anchor else pos.offset);
        win.reveal = .none;
        return;
    }
    const l = fresh(win, id) orelse return;
    const r = unitAt(l, effective, pos.offset) catch return;
    win.input.gesture = .{ .unit = effective, .start = r[0], .end = r[1] };
    win.state(id).preferred_x = null;
    setSelection(win, id, r[1], r[0], .upstream);
    win.reveal = .none;
}

/// Dragging with the button held extends the selection, by the unit the
/// press selected.
pub fn pointerDrag(win: *Window, id: NodeId, p: Point) void {
    const pos = positionAt(win, id, input.toLocal(win, id, p)) orelse return;
    const g = win.input.gesture;
    defer win.reveal = .none;
    if (g.unit == .grapheme) return select(win, id, pos, data(win, id).anchor);
    const l = fresh(win, id) orelse return;
    const r = unitAt(l, g.unit, pos.offset) catch return;
    if (r[0] < g.start) {
        setSelection(win, id, r[0], g.end, .downstream);
    } else {
        setSelection(win, id, @max(r[1], g.end), g.start, .upstream);
    }
}

fn select(win: *Window, id: NodeId, pos: Position, anchor: u32) void {
    win.state(id).preferred_x = null;
    setSelection(win, id, pos.offset, anchor, pos.affinity);
}

fn setSelection(win: *Window, id: NodeId, caret: u32, anchor: u32, affinity: text.layout.Affinity) void {
    const t = win.begin() catch return;
    t.setSelection(id, caret, anchor, affinity) catch {
        t.abort();
        return;
    };
    t.commit();
}

/// How an edit joins the undo history.
pub const Record = enum {
    /// Typing: consecutive insertions merge into one undo step.
    typing,
    /// Deleting with Backspace or Delete: consecutive deletions merge.
    deleting,
    /// Anything else is a step of its own.
    other,
    /// A formatting command (`format`): styles change, the text does not.
    format,
    /// Undo and redo themselves.
    none,
};

/// Replaces `start..end` (offsets into the shown text) with `insert`, puts
/// the caret after it, records it, and tells the editor.
fn replace(win: *Window, id: NodeId, start: u32, end: u32, insert: []const u8, record: Record) void {
    const e = data(win, id);
    if (e.editor.masked) return replaceMasked(win, id, start, end, insert);
    const old = e.text.content;
    const before: Snapshot = .{ .caret = e.caret, .anchor = e.anchor, .revision = e.revision };
    const a = win.scratch.allocator();
    // A copy: the old text goes when the edit commits.
    const removed = a.alloc(u8, end - start) catch return;
    old.read(start, removed);
    const caret: u32 = @intCast(start + insert.len);
    // Inserted text takes the typing style, else that of the first
    // replaced character, else that of the character before (D22).
    const style = e.typing orelse if (start < end) spans.styleAt(e.text.spans, start) else spans.inherited(e.text.spans, start);
    const spans_before = e.text.spans;
    const spans_after = spans.replaced(a, spans_before, start, end, @intCast(insert.len), style) catch return;
    const kept_before = a.dupe(node_mod.Span, spans_before) catch return;
    // Inserted text joins the paragraph it goes into, and paragraphs keep
    // the style of their first character (D13).
    const paragraphs_before = a.dupe(node_mod.ParagraphSpan, e.text.paragraphs) catch return;
    // Without paragraph spans there is nothing to snap (and no need to
    // scan a long text for paragraphs).
    const paragraphs_after = if (paragraphs_before.len == 0) paragraphs_before else blk: {
        const content = old.replace(win.gpa, start, end, insert) catch return;
        defer content.release(win.gpa);
        const paragraph_style = spans.styleAt(paragraphs_before, spans.paragraphAt(old, start).start);
        break :blk spans.snapped(a, content, spans.replaced(a, paragraphs_before, start, end, @intCast(insert.len), paragraph_style) catch return) catch return;
    };
    if (!commitEdit(win, id, .{ .splice = .{ .start = start, .end = end, .insert = insert } }, caret, spans_after, paragraphs_after)) return;
    if (record != .none) remember(win, id, before, .{
        .start = start,
        .removed = removed,
        .inserted = insert,
        .kind = record,
        .spans_before = kept_before,
        .spans_after = spans_after,
        .paragraphs_before = paragraphs_before,
        .paragraphs_after = paragraphs_after,
    });
    changed(win, id, .{ .start = start, .end = end, .length = @intCast(insert.len) });
}

/// Masked: offsets index the bullets, one per code point of the secret.
/// The new text is assembled in locked memory, never in ordinary memory.
fn replaceMasked(win: *Window, id: NodeId, start: u32, end: u32, insert: []const u8) void {
    const old = data(win, id).secret;
    const cp_start = start / bullet.len;
    const cp_end = end / bullet.len;
    const b_start = byteOfCodepoint(old, cp_start);
    const b_end = byteOfCodepoint(old, cp_end);
    const plain = secret.alloc(b_start + insert.len + old.len - b_end) catch return;
    defer secret.free(plain);
    @memcpy(plain[0..b_start], old[0..b_start]);
    @memcpy(plain[b_start..][0..insert.len], insert);
    @memcpy(plain[b_start + insert.len ..], old[b_end..]);
    const inserted_cps = std.unicode.utf8CountCodepoints(insert) catch return;
    const caret: u32 = @intCast((cp_start + inserted_cps) * bullet.len);
    if (!commitEdit(win, id, .{ .all = plain }, caret, &.{}, &.{})) return;
    changed(win, id, .{});
}

fn byteOfCodepoint(s: []const u8, cp: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < cp) : (n += 1) i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return i;
}

/// New text for an edit: all of it, or a range replaced.
const NewText = union(enum) {
    all: []const u8,
    splice: struct { start: u32, end: u32, insert: []const u8 },
};

fn commitEdit(win: *Window, id: NodeId, new: NewText, caret: u32, styled: []const node_mod.Span, paragraphs: []const node_mod.ParagraphSpan) bool {
    const t = win.begin() catch return false;
    (switch (new) {
        .all => |content| t.setText(id, content),
        .splice => |sp| t.replaceText(id, sp.start, sp.end, sp.insert),
    }) catch {
        t.abort();
        return false;
    };
    t.setSpans(id, styled) catch {
        t.abort();
        return false;
    };
    t.setParagraphSpans(id, paragraphs) catch {
        t.abort();
        return false;
    };
    t.setSelection(id, caret, caret, .downstream) catch {
        t.abort();
        return false;
    };
    t.commit();
    win.state(id).preferred_x = null;
    return true;
}

fn changed(win: *Window, id: NodeId, change: node_mod.Change) void {
    if (win.isLive(id)) if (win.node(id).handler(.change)) |h| {
        _ = h.func(h.user, win, id, &.{ .change = change });
    };
}

// Undo ---------------------------------------------------------------------

/// Most undo steps kept per editor.
pub const max_undo = 100;

const Snapshot = struct { caret: u32, anchor: u32, revision: u32 };

pub const Edit = struct {
    start: u32,
    removed: []const u8,
    inserted: []const u8,
    kind: Record,
    /// Selection before the edit, restored by undo.
    caret: u32 = 0,
    anchor: u32 = 0,
    /// Styled ranges and paragraph styles before and after the edit (D22).
    spans_before: []const node_mod.Span = &.{},
    spans_after: []const node_mod.Span = &.{},
    paragraphs_before: []const node_mod.ParagraphSpan = &.{},
    paragraphs_after: []const node_mod.ParagraphSpan = &.{},

    fn deinit(ed: Edit, gpa: std.mem.Allocator) void {
        gpa.free(ed.removed);
        gpa.free(ed.inserted);
        gpa.free(ed.spans_before);
        gpa.free(ed.spans_after);
        gpa.free(ed.paragraphs_before);
        gpa.free(ed.paragraphs_after);
    }
};

/// An editor's undo and redo steps. Valid while the editor's revision is
/// the one recorded: when the application replaces the text, the history
/// no longer applies and is dropped.
pub const History = struct {
    revision: u32 = 0,
    undo: std.ArrayList(Edit) = .empty,
    redo: std.ArrayList(Edit) = .empty,

    pub fn deinit(h: *History, gpa: std.mem.Allocator) void {
        h.clear(gpa);
        h.undo.deinit(gpa);
        h.redo.deinit(gpa);
    }

    fn clear(h: *History, gpa: std.mem.Allocator) void {
        for (h.undo.items) |ed| ed.deinit(gpa);
        for (h.redo.items) |ed| ed.deinit(gpa);
        h.undo.clearRetainingCapacity();
        h.redo.clearRetainingCapacity();
    }
};

/// The editor's history, emptied if the text changed since it was kept.
fn history(win: *Window, id: NodeId, revision: u32) ?*History {
    const gop = win.histories.getOrPut(win.gpa, id) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = .{ .revision = revision };
    if (gop.value_ptr.revision != revision) gop.value_ptr.clear(win.gpa);
    gop.value_ptr.revision = revision;
    return gop.value_ptr;
}

fn isSpace(s: []const u8) bool {
    return s.len == 1 and (s[0] == ' ' or s[0] == '\n' or s[0] == '\t');
}

fn remember(win: *Window, id: NodeId, before: Snapshot, edit: Edit) void {
    // The application keeps the history.
    if (data(win, id).editor.no_undo) return;
    const gpa = win.gpa;
    const h = history(win, id, before.revision) orelse return;
    h.revision = data(win, id).revision;
    for (h.redo.items) |ed| ed.deinit(gpa);
    h.redo.clearRetainingCapacity();
    if (h.undo.items.len != 0) {
        const last = &h.undo.items[h.undo.items.len - 1];
        // Typing merges until a space follows a word; deleting merges
        // runs of Backspace or Delete.
        const typing = edit.kind == .typing and last.kind == .typing and edit.removed.len == 0 and
            last.start + last.inserted.len == edit.start and !(isSpace(edit.inserted) and !isSpace(last.inserted[last.inserted.len - 1 ..]));
        const backspacing = edit.kind == .deleting and last.kind == .deleting and edit.inserted.len == 0 and
            edit.start + edit.removed.len == last.start;
        const deleting = edit.kind == .deleting and last.kind == .deleting and edit.inserted.len == 0 and edit.start == last.start;
        if (typing or backspacing or deleting) {
            const merged = if (typing)
                std.mem.concat(gpa, u8, &.{ last.inserted, edit.inserted })
            else if (backspacing)
                std.mem.concat(gpa, u8, &.{ edit.removed, last.removed })
            else
                std.mem.concat(gpa, u8, &.{ last.removed, edit.removed });
            const m = merged catch return h.clear(gpa);
            const after = gpa.dupe(node_mod.Span, edit.spans_after) catch {
                gpa.free(m);
                return h.clear(gpa);
            };
            const paragraphs_after = gpa.dupe(node_mod.ParagraphSpan, edit.paragraphs_after) catch {
                gpa.free(m);
                gpa.free(after);
                return h.clear(gpa);
            };
            gpa.free(last.spans_after);
            last.spans_after = after;
            gpa.free(last.paragraphs_after);
            last.paragraphs_after = paragraphs_after;
            if (typing) {
                gpa.free(last.inserted);
                last.inserted = m;
            } else {
                gpa.free(last.removed);
                last.removed = m;
                if (backspacing) last.start = edit.start;
            }
            return;
        }
    }
    var owned: Edit = .{ .start = edit.start, .removed = &.{}, .inserted = &.{}, .kind = edit.kind, .caret = before.caret, .anchor = before.anchor };
    owned.removed = gpa.dupe(u8, edit.removed) catch return h.clear(gpa);
    owned.inserted = gpa.dupe(u8, edit.inserted) catch {
        owned.deinit(gpa);
        return h.clear(gpa);
    };
    owned.spans_before = gpa.dupe(node_mod.Span, edit.spans_before) catch {
        owned.deinit(gpa);
        return h.clear(gpa);
    };
    owned.spans_after = gpa.dupe(node_mod.Span, edit.spans_after) catch {
        owned.deinit(gpa);
        return h.clear(gpa);
    };
    owned.paragraphs_before = gpa.dupe(node_mod.ParagraphSpan, edit.paragraphs_before) catch {
        owned.deinit(gpa);
        return h.clear(gpa);
    };
    owned.paragraphs_after = gpa.dupe(node_mod.ParagraphSpan, edit.paragraphs_after) catch {
        owned.deinit(gpa);
        return h.clear(gpa);
    };
    if (h.undo.items.len == max_undo) h.undo.orderedRemove(0).deinit(gpa);
    h.undo.append(gpa, owned) catch owned.deinit(gpa);
}

/// Undoes (or redoes) the last step. Returns whether there was one.
pub fn undo(win: *Window, id: NodeId, redo: bool) bool {
    const e = data(win, id);
    if (e.editor.masked or e.editor.no_undo) return false;
    const h = win.histories.getPtr(id) orelse return false;
    if (h.revision != e.revision) {
        h.clear(win.gpa);
        return false;
    }
    const from = if (redo) &h.redo else &h.undo;
    const to = if (redo) &h.undo else &h.redo;
    const ed = from.pop() orelse return false;
    to.ensureUnusedCapacity(win.gpa, 1) catch {
        from.appendAssumeCapacity(ed);
        return false;
    };
    const gone = if (redo) ed.removed else ed.inserted;
    const back = if (redo) ed.inserted else ed.removed;
    const splice: NewText = .{ .splice = .{ .start = ed.start, .end = @intCast(ed.start + gone.len), .insert = back } };
    if (!commitEdit(win, id, splice, @intCast(ed.start + back.len), if (redo) ed.spans_after else ed.spans_before, if (redo) ed.paragraphs_after else ed.paragraphs_before)) {
        from.appendAssumeCapacity(ed);
        return false;
    }
    // Undo restores the selection the edit replaced.
    if (!redo) setSelection(win, id, ed.caret, ed.anchor, .downstream);
    to.appendAssumeCapacity(ed);
    h.revision = data(win, id).revision;
    changed(win, id, .{ .start = ed.start, .end = @intCast(ed.start + gone.len), .length = @intCast(back.len) });
    return true;
}

/// A formatting command (D22): sets the attributes in `mask` to those of
/// `values` over the selection, as one undo step followed by a change
/// event, or with nothing selected makes them the typing style until the
/// caret moves. Masked editors take no styles.
pub fn format(win: *Window, id: NodeId, values: node_mod.SpanStyle, mask: node_mod.SpanStyle.Mask) bool {
    const e = data(win, id);
    if (e.editor.masked) return false;
    const lo, const hi = selection(e);
    const t = win.begin() catch return false;
    if (lo == hi) {
        t.setTypingStyle(id, typingStyle(win, id).patched(values, mask)) catch {
            t.abort();
            return false;
        };
        t.commit();
        return true;
    }
    const a = win.scratch.allocator();
    const before = a.dupe(node_mod.Span, e.text.spans) catch {
        t.abort();
        return false;
    };
    const after = spans.restyled(a, before, @intCast(e.text.content.len()), lo, hi, values, mask) catch {
        t.abort();
        return false;
    };
    const snap: Snapshot = .{ .caret = e.caret, .anchor = e.anchor, .revision = e.revision };
    t.setSpans(id, after) catch {
        t.abort();
        return false;
    };
    t.commit();
    const paragraphs = e.text.paragraphs;
    remember(win, id, snap, .{ .start = lo, .removed = "", .inserted = "", .kind = .format, .spans_before = before, .spans_after = after, .paragraphs_before = paragraphs, .paragraphs_after = paragraphs });
    changed(win, id, .{});
    return true;
}

/// A paragraph formatting command (D13): sets the attributes in `mask` to
/// those of `values` on every paragraph the selection touches (the
/// caret's, with nothing selected), as one undo step followed by a change
/// event. Masked editors take none.
pub fn formatParagraph(win: *Window, id: NodeId, values: node_mod.ParagraphPatch, mask: node_mod.ParagraphPatch.Mask) bool {
    const e = data(win, id);
    if (e.editor.masked) return false;
    const lo, const hi = selection(e);
    const content = e.text.content;
    const a = win.scratch.allocator();
    const from = spans.paragraphAt(content, lo).start;
    // A selection ending at a paragraph's start does not touch it.
    const to = if (hi > lo and hi > from and spans.paragraphAt(content, hi).start == hi) hi else spans.paragraphAt(content, hi).end;
    const before = a.dupe(node_mod.ParagraphSpan, e.text.paragraphs) catch return false;
    const restyled = spans.restyled(a, before, @intCast(content.len()), from, @max(to, from + 1), values, mask) catch return false;
    const after = spans.snapped(a, content, restyled) catch return false;
    const snap: Snapshot = .{ .caret = e.caret, .anchor = e.anchor, .revision = e.revision };
    const t = win.begin() catch return false;
    t.setParagraphSpans(id, after) catch {
        t.abort();
        return false;
    };
    t.commit();
    const styled = e.text.spans;
    remember(win, id, snap, .{ .start = lo, .removed = "", .inserted = "", .kind = .format, .spans_before = styled, .spans_after = styled, .paragraphs_before = before, .paragraphs_after = after });
    changed(win, id, .{});
    return true;
}

/// The paragraph style at `offset`: of the paragraph containing it.
pub fn paragraphStyle(win: *const Window, id: NodeId, offset: u32) node_mod.ParagraphPatch {
    const d = win.node(id).textData();
    return spans.styleAt(d.paragraphs, spans.paragraphAt(d.content, offset).start);
}

/// The style typed text would take now.
pub fn typingStyle(win: *const Window, id: NodeId) node_mod.SpanStyle {
    const e = data(win, id);
    if (e.typing) |ty| return ty;
    const lo, const hi = selection(e);
    return if (lo < hi) spans.styleAt(e.text.spans, lo) else spans.inherited(e.text.spans, lo);
}

fn selection(e: *const node_mod.EditorData) struct { u32, u32 } {
    return .{ @min(e.caret, e.anchor), @max(e.caret, e.anchor) };
}

/// Inserts typed text, replacing the selection. Single-line editors drop
/// line breaks.
pub fn insertText(win: *Window, id: NodeId, str: []const u8) void {
    const e = data(win, id);
    // The edit runs change handlers, which may build nodes and move `e`:
    // nothing reads it after `replace`.
    const masked = e.editor.masked;
    var buf: std.ArrayList(u8) = .empty;
    defer if (masked) std.crypto.secureZero(u8, buf.items);
    for (str) |c| if (e.editor.multiline or (c != '\n' and c != '\r')) buf.append(win.scratch.allocator(), c) catch return;
    if (buf.items.len == 0 and str.len != 0) return;
    const lo, const hi = selection(e);
    replace(win, id, lo, hi, buf.items, if (lo == hi) .typing else .other);
}

/// Editing and caret keys. Returns whether the key was consumed.
pub fn key(win: *Window, id: NodeId, k: *const platform.Key) bool {
    if (k.state == .released or k.composing) return false;
    const n = win.node(id);
    if (n.semantics.disabled) return false;
    // The input method owns the keyboard while it composes; keys that
    // still arrive must not edit around its preedit.
    if (win.ime.preeditFor(id) != null) return k.keysym != keysym.tab and k.keysym != keysym.iso_left_tab;
    const l = fresh(win, id) orelse return false;
    // Without memory to lay out the blocks it needs, the key does nothing.
    return keyIn(win, id, k, l) catch true;
}

fn keyIn(win: *Window, id: NodeId, k: *const platform.Key, l: *const Layout) error{OutOfMemory}!bool {
    const e = data(win, id);
    const mods = k.mods;
    const lo, const hi = selection(e);
    const len: u32 = @intCast(e.text.content.len());
    const rtl = win.state(id).rtl;
    const pos: Position = .{ .offset = e.caret, .affinity = e.affinity };
    const extend = mods.shift;
    switch (k.keysym) {
        keysym.left, keysym.right => {
            const forward = (k.keysym == keysym.right) != rtl;
            if (!extend and lo != hi and !mods.ctrl) {
                select(win, id, .{ .offset = if (forward) hi else lo }, if (forward) hi else lo);
                return true;
            }
            const next: Position = if (mods.ctrl and !e.editor.masked)
                .{ .offset = if (forward) try l.nextWordEnd(e.caret) else try l.previousWordStart(e.caret) }
            else
                try l.moveVisual(pos, if (k.keysym == keysym.right) .right else .left);
            select(win, id, next, if (extend) e.anchor else next.offset);
        },
        keysym.home, keysym.end => {
            const boundary: text.cursor.Boundary = if (k.keysym == keysym.home) .start else .end;
            const next: Position = if (mods.ctrl) .{ .offset = if (boundary == .start) 0 else len } else try l.lineBoundary(pos, boundary);
            select(win, id, next, if (extend) e.anchor else next.offset);
        },
        keysym.up, keysym.down => {
            if (!e.editor.multiline) return false;
            const s = win.state(id);
            const w = contentWidth(win, id);
            const cur = try l.caret(pos);
            const x_node = s.preferred_x orelse cur.x + text_node.lineShift(win, id, try l.line(cur.line), w);
            const up = k.keysym == keysym.up;
            const target_line = if (up) cur.line -| 1 else @min(cur.line + 1, l.lineCount() - 1);
            const moved = try l.moveVertical(pos, x_node - text_node.lineShift(win, id, try l.line(target_line), w), if (up) .up else .down);
            setSelection(win, id, moved.position.offset, if (extend) e.anchor else moved.position.offset, moved.position.affinity);
            win.state(id).preferred_x = x_node;
        },
        backspace, delete => {
            if (lo != hi) {
                // Shift+Delete cuts.
                if (k.keysym == delete and mods.shift) copySelection(win, id, false);
                replace(win, id, lo, hi, "", .other);
            } else if (k.keysym == backspace) {
                if (e.caret == 0) return true;
                // Word deletion in a masked field would reveal word breaks.
                const start = if (mods.ctrl and !e.editor.masked) try l.previousWordStart(e.caret) else try l.previousGrapheme(e.caret);
                replace(win, id, start, e.caret, "", if (mods.ctrl) .other else .deleting);
            } else {
                if (e.caret == len) return true;
                const end = if (mods.ctrl and !e.editor.masked) try l.nextWordEnd(e.caret) else try l.nextGrapheme(e.caret);
                replace(win, id, e.caret, end, "", if (mods.ctrl) .other else .deleting);
            }
        },
        keysym.@"return", keysym.kp_enter => {
            if (!e.editor.multiline) return false;
            insertText(win, id, "\n");
        },
        'a', 'A' => {
            if (!mods.ctrl) return typed(win, id, k);
            select(win, id, .{ .offset = len }, 0);
            // Selecting all leaves the view where it is.
            win.reveal = .none;
        },
        'c', 'C', 'x', 'X' => {
            if (!mods.ctrl) return typed(win, id, k);
            copySelection(win, id, k.keysym == 'x' or k.keysym == 'X');
        },
        'v', 'V' => {
            if (!mods.ctrl) return typed(win, id, k);
            paste(win, id, .clipboard);
        },
        insert_key => {
            if (mods.shift) paste(win, id, .clipboard) else if (mods.ctrl) copySelection(win, id, false) else return false;
        },
        'z', 'Z' => {
            if (!mods.ctrl) return typed(win, id, k);
            // The application's history: the keys are its own.
            if (e.editor.no_undo) return false;
            _ = undo(win, id, mods.shift);
        },
        'y', 'Y' => {
            if (!mods.ctrl) return typed(win, id, k);
            if (e.editor.no_undo) return false;
            _ = undo(win, id, true);
        },
        else => return typed(win, id, k),
    }
    return true;
}

// Clipboard -----------------------------------------------------------------

/// Copies (or cuts) the selection to the clipboard. Masked editors do not
/// copy.
pub fn copySelection(win: *Window, id: NodeId, cut: bool) void {
    const lo, const hi = selection(data(win, id));
    copyRange(win, id, lo, hi, cut);
}

/// Copies `lo..hi` to the clipboard, and with `cut` deletes it. Masked
/// editors never copy.
pub fn copyRange(win: *Window, id: NodeId, lo: u32, hi: u32, cut: bool) void {
    const e = data(win, id);
    if (lo == hi or e.editor.masked) return;
    const cb = win.clipboard orelse return;
    cb.copy(.clipboard, win.input.seat, win.input.serial, e.text.content.slice(win.scratch.allocator(), lo, hi) catch return) catch return;
    if (cut) replace(win, id, lo, hi, "", .other);
}

/// An edit that arrived while the application held a transaction open
/// (or behind input queued for that reason), applied in order at the
/// next frame like queued input. Offsets are checked again then, since
/// the text may have changed; an edit that no longer fits is dropped.
pub const Pending = struct {
    node: NodeId,
    edit: union(enum) {
        /// Pasted text, inserted over the selection.
        paste: []u8,
        replace: struct { start: u32, end: u32, text: []u8 },
        select: struct { caret: u32, anchor: u32 },
        copy: struct { start: u32, end: u32, cut: bool },
        /// Paste the clipboard at an offset.
        paste_at: u32,
    },

    pub fn deinit(p: Pending, gpa: std.mem.Allocator) void {
        const owned: []u8 = switch (p.edit) {
            .paste => |t| t,
            .replace => |r| r.text,
            else => return,
        };
        std.crypto.secureZero(u8, owned);
        gpa.free(owned);
    }
};

/// Whether an edit must wait its turn behind an open transaction or
/// queued input.
pub fn mustQueue(win: *const Window) bool {
    return win.txn.open or win.pending_input.items.len != 0 or win.pending_edits.items.len != 0;
}

/// Queues `p`, which the queue then owns.
pub fn queue(win: *Window, p: Pending) error{OutOfMemory}!void {
    win.pending_edits.append(win.gpa, p) catch |err| {
        p.deinit(win.gpa);
        return err;
    };
    win.requestFrame();
}

/// Whether `start..end` is a range of whole code points in `s`.
pub fn validRange(s: text.Rope, start: u32, end: u32) bool {
    const len = s.len();
    if (start > end or end > len) return false;
    var rd = s.reader();
    for ([_]u32{ start, end }) |o| if (o < len and rd.at(o) & 0xc0 == 0x80) return false;
    return true;
}

/// Applies a queued edit to the editor, if it still exists and fits.
pub fn apply(win: *Window, p: Pending) void {
    defer p.deinit(win.gpa);
    if (!win.isLive(p.node) or win.node(p.node).kind != .editor) return;
    const content = data(win, p.node).text.content;
    switch (p.edit) {
        .paste => |t| pasteText(win, p.node, t),
        .replace => |r| if (validRange(content, r.start, r.end)) replaceRange(win, p.node, r.start, r.end, r.text),
        .select => |s| if (validRange(content, @min(s.caret, s.anchor), @max(s.caret, s.anchor)))
            setSelection(win, p.node, s.caret, s.anchor, .downstream),
        .copy => |c| if (validRange(content, c.start, c.end)) copyRange(win, p.node, c.start, c.end, c.cut),
        .paste_at => |o| if (validRange(content, o, o)) {
            setSelection(win, p.node, o, o, .downstream);
            paste(win, p.node, .clipboard);
        },
    }
}

const Paste = struct {
    win: *Window,
    node: NodeId,

    fn done(ctx: *anyopaque, pasted: ?[]const u8) void {
        const p: *Paste = @ptrCast(@alignCast(ctx));
        const win = p.win;
        const node = p.node;
        win.gpa.destroy(p);
        const s = pasted orelse return;
        if (!win.isLive(node) or win.node(node).kind != .editor) return;
        // Behind an open transaction (or input queued behind one), the
        // paste waits its turn like input.
        if (mustQueue(win)) {
            const copy = win.gpa.dupe(u8, s) catch return;
            queue(win, .{ .node = node, .edit = .{ .paste = copy } }) catch {};
            return;
        }
        pasteText(win, node, s);
    }
};

/// Pastes the clipboard or primary selection at the caret.
pub fn paste(win: *Window, id: NodeId, kind: platform.SelectionKind) void {
    const cb = win.clipboard orelse return;
    const p = win.gpa.create(Paste) catch return;
    p.* = .{ .win = win, .node = id };
    cb.paste(kind, win.input.seat, win, .{ .ctx = p, .func = Paste.done });
}

/// Inserts dropped text at a window point, as one undo step, and selects
/// it.
pub fn dropText(win: *Window, id: NodeId, p: Point, text_: []const u8) void {
    const pos = positionAt(win, id, input.toLocal(win, id, p)) orelse return;
    const before = data(win, id).text.content.len();
    setSelection(win, id, pos.offset, pos.offset, .downstream);
    replaceRange(win, id, pos.offset, pos.offset, text_);
    const e = data(win, id);
    const added: u32 = @intCast(e.text.content.len() -| before);
    if (added != 0) setSelection(win, id, pos.offset + added, pos.offset, .downstream);
}

/// Inserts pasted text over the selection, as one undo step.
pub fn pasteText(win: *Window, id: NodeId, text_: []const u8) void {
    const lo, const hi = selection(data(win, id));
    replaceRange(win, id, lo, hi, text_);
}

/// Replaces `lo..hi` with `text_` as one undo step, as a paste does:
/// single-line editors turn line breaks into spaces. Disabled editors do
/// not change.
pub fn replaceRange(win: *Window, id: NodeId, lo: u32, hi: u32, text_: []const u8) void {
    const e = data(win, id);
    if (win.node(id).semantics.disabled) return;
    const a = win.scratch.allocator();
    const buf = a.alloc(u8, text_.len) catch return;
    defer std.crypto.secureZero(u8, buf);
    var n: usize = 0;
    for (text_, 0..) |c, i| {
        if (e.editor.multiline) {
            if (c == '\r' and i + 1 < text_.len and text_[i + 1] == '\n') continue;
            buf[n] = if (c == '\r') '\n' else c;
        } else {
            if (c == '\r' and i + 1 < text_.len and text_[i + 1] == '\n') continue;
            buf[n] = if (c == '\n' or c == '\r') ' ' else c;
        }
        n += 1;
    }
    replace(win, id, lo, hi, buf[0..n], .other);
}

/// Offers the focused editor's selection as the primary selection when it
/// changed (once per frame, not on every drag step).
pub fn updatePrimary(win: *Window) void {
    const cb = win.clipboard orelse return;
    const id = win.input.focus;
    if (id == .none or !win.isLive(id) or win.node(id).kind != .editor) return;
    const e = data(win, id);
    const lo, const hi = selection(e);
    if (lo == hi or e.editor.masked) return;
    const p = win.primary;
    if (p.node == id and p.lo == lo and p.hi == hi and p.revision == e.revision) return;
    win.primary = .{ .node = id, .lo = lo, .hi = hi, .revision = e.revision };
    cb.copy(.primary, win.input.seat, win.input.serial, e.text.content.slice(win.scratch.allocator(), lo, hi) catch return) catch {};
}

fn typed(win: *Window, id: NodeId, k: *const platform.Key) bool {
    const str = k.text();
    if (str.len == 0 or k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    insertText(win, id, str);
    return true;
}
