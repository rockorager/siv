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

const NodeId = node_mod.NodeId;
const Point = raster.Point;
const Rect = raster.Rect;
const Layout = text.Layout;
const Position = Layout.Position;
const keysym = input.keysym;

const backspace: u32 = 0xff08;
const delete: u32 = 0xffff;

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

/// The caret rectangle in content coordinates (before editor scrolling).
pub fn caretRect(win: *const Window, id: NodeId, l: *const Layout) Rect {
    const e = data(win, id);
    const c = l.caret(.{ .offset = e.caret, .affinity = e.affinity });
    const x = c.x + text_node.lineShift(win, id, l.lines[c.line], contentWidth(win, id));
    return .xywh(x, c.top, layout.caret_width, c.height);
}

/// Keeps a single-line editor's caret in view; call after layout.
pub fn scrollToCaret(win: *Window, id: NodeId) void {
    const s = win.state(id);
    const e = data(win, id);
    const l = text_node.current(win, id) orelse return;
    if (e.editor.multiline or l.lines.len == 0) {
        s.editor_scroll = 0;
        return;
    }
    const w = contentWidth(win, id);
    const line = l.lines[0];
    const x0 = line.x + text_node.lineShift(win, id, line, w);
    const lo = @min(0, x0);
    const hi = @max(0, x0 + line.width + layout.caret_width - w);
    const c = caretRect(win, id, l);
    var scroll = s.editor_scroll;
    if (c.x1 - scroll > w) scroll = c.x1 - w;
    if (c.x0 - scroll < 0) scroll = c.x0;
    s.editor_scroll = std.math.clamp(scroll, lo, hi);
}

/// The text position under a point in the editor's coordinates.
fn positionAt(win: *Window, id: NodeId, local: Point) ?Position {
    const l = fresh(win, id) orelse return null;
    const o = contentOrigin(win, id);
    const x = local.x - o.x;
    const y = local.y - o.y;
    const line = l.lines[l.lineAt(y)];
    return l.hitTest(x - text_node.lineShift(win, id, line, contentWidth(win, id)), y);
}

/// A primary press at a window point: places the caret (extends the
/// selection with shift).
pub fn pointerDown(win: *Window, id: NodeId, p: Point, extend: bool) void {
    const pos = positionAt(win, id, input.toLocal(win, id, p)) orelse return;
    const e = data(win, id);
    select(win, id, pos, if (extend) e.anchor else pos.offset);
}

/// Dragging with the button held extends the selection.
pub fn pointerDrag(win: *Window, id: NodeId, p: Point) void {
    const pos = positionAt(win, id, input.toLocal(win, id, p)) orelse return;
    select(win, id, pos, data(win, id).anchor);
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
    const removed = a.dupe(u8, old[start..end]) catch return;
    const content = std.mem.concat(a, u8, &.{ old[0..start], insert, old[end..] }) catch return;
    const caret: u32 = @intCast(start + insert.len);
    if (!commitEdit(win, id, content, caret)) return;
    if (record != .none) remember(win, id, before, .{ .start = start, .removed = removed, .inserted = insert, .kind = record });
    changed(win, id);
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
    if (!commitEdit(win, id, plain, caret)) return;
    changed(win, id);
}

fn byteOfCodepoint(s: []const u8, cp: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < cp) : (n += 1) i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return i;
}

fn commitEdit(win: *Window, id: NodeId, content: []const u8, caret: u32) bool {
    const t = win.begin() catch return false;
    t.setText(id, content) catch {
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

fn changed(win: *Window, id: NodeId) void {
    if (win.isLive(id)) if (win.node(id).handler(.change)) |h| {
        _ = h.func(h.user, win, id, &.change);
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

    fn deinit(ed: Edit, gpa: std.mem.Allocator) void {
        gpa.free(ed.removed);
        gpa.free(ed.inserted);
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
    const removed = gpa.dupe(u8, edit.removed) catch return h.clear(gpa);
    const inserted = gpa.dupe(u8, edit.inserted) catch {
        gpa.free(removed);
        return h.clear(gpa);
    };
    if (h.undo.items.len == max_undo) h.undo.orderedRemove(0).deinit(gpa);
    h.undo.append(gpa, .{ .start = edit.start, .removed = removed, .inserted = inserted, .kind = edit.kind, .caret = before.caret, .anchor = before.anchor }) catch {
        gpa.free(removed);
        gpa.free(inserted);
    };
}

/// Undoes (or redoes) the last step. Returns whether there was one.
pub fn undo(win: *Window, id: NodeId, redo: bool) bool {
    const e = data(win, id);
    if (e.editor.masked) return false;
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
    const old = e.text.content;
    const a = win.scratch.allocator();
    const gone = if (redo) ed.removed else ed.inserted;
    const back = if (redo) ed.inserted else ed.removed;
    const content = std.mem.concat(a, u8, &.{ old[0..ed.start], back, old[ed.start + gone.len ..] }) catch {
        from.appendAssumeCapacity(ed);
        return false;
    };
    if (!commitEdit(win, id, content, @intCast(ed.start + back.len))) {
        from.appendAssumeCapacity(ed);
        return false;
    }
    // Undo restores the selection the edit replaced.
    if (!redo) setSelection(win, id, ed.caret, ed.anchor, .downstream);
    to.appendAssumeCapacity(ed);
    h.revision = data(win, id).revision;
    changed(win, id);
    return true;
}

fn selection(e: *const node_mod.EditorData) struct { u32, u32 } {
    return .{ @min(e.caret, e.anchor), @max(e.caret, e.anchor) };
}

/// Inserts typed text, replacing the selection. Single-line editors drop
/// line breaks.
pub fn insertText(win: *Window, id: NodeId, str: []const u8) void {
    const e = data(win, id);
    var buf: std.ArrayList(u8) = .empty;
    defer if (e.editor.masked) std.crypto.secureZero(u8, buf.items);
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
    const e = data(win, id);
    const l = fresh(win, id) orelse return false;
    const mods = k.mods;
    const lo, const hi = selection(e);
    const len: u32 = @intCast(e.text.content.len);
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
                .{ .offset = if (forward) l.nextWordEnd(e.caret) else l.previousWordStart(e.caret) }
            else
                l.moveVisual(pos, if (k.keysym == keysym.right) .right else .left);
            select(win, id, next, if (extend) e.anchor else next.offset);
        },
        keysym.home, keysym.end => {
            const boundary: text.cursor.Boundary = if (k.keysym == keysym.home) .start else .end;
            const next: Position = if (mods.ctrl) .{ .offset = if (boundary == .start) 0 else len } else l.lineBoundary(pos, boundary);
            select(win, id, next, if (extend) e.anchor else next.offset);
        },
        keysym.up, keysym.down => {
            if (!e.editor.multiline) return false;
            const s = win.state(id);
            const w = contentWidth(win, id);
            const cur = l.caret(pos);
            const x_node = s.preferred_x orelse cur.x + text_node.lineShift(win, id, l.lines[cur.line], w);
            const up = k.keysym == keysym.up;
            const target_line = if (up) cur.line -| 1 else @min(cur.line + 1, @as(u32, @intCast(l.lines.len - 1)));
            const moved = l.moveVertical(pos, x_node - text_node.lineShift(win, id, l.lines[target_line], w), if (up) .up else .down);
            setSelection(win, id, moved.position.offset, if (extend) e.anchor else moved.position.offset, moved.position.affinity);
            win.state(id).preferred_x = x_node;
        },
        backspace, delete => {
            if (lo != hi) {
                replace(win, id, lo, hi, "", .other);
            } else if (k.keysym == backspace) {
                if (e.caret == 0) return true;
                // Word deletion in a masked field would reveal word breaks.
                const start = if (mods.ctrl and !e.editor.masked) l.previousWordStart(e.caret) else l.previousGrapheme(e.caret);
                replace(win, id, start, e.caret, "", if (mods.ctrl) .other else .deleting);
            } else {
                if (e.caret == len) return true;
                const end = if (mods.ctrl and !e.editor.masked) l.nextWordEnd(e.caret) else l.nextGrapheme(e.caret);
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
        },
        'z', 'Z' => {
            if (!mods.ctrl) return typed(win, id, k);
            _ = undo(win, id, mods.shift);
        },
        'y', 'Y' => {
            if (!mods.ctrl) return typed(win, id, k);
            _ = undo(win, id, true);
        },
        else => return typed(win, id, k),
    }
    return true;
}

fn typed(win: *Window, id: NodeId, k: *const platform.Key) bool {
    const str = k.text();
    if (str.len == 0 or k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    insertText(win, id, str);
    return true;
}
