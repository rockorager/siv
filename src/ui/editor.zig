//! Editor nodes (D15): caret, selection, and editing on the text `Layout`
//! (cluster map, grapheme and word boundaries, bidi levels); no other text
//! state. Edits commit through a transaction of their own and then send
//! the editor a `change` event. Composed text from xkbcommon arrives as key
//! text; text-input-v3 (IME) and masked fields are not built yet.

const std = @import("std");
const raster = @import("raster");
const text = @import("text");
const platform = @import("platform");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const text_node = @import("text_node.zig");
const input = @import("input.zig");
const layout = @import("layout.zig");

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

/// Replaces `start..end` with `insert`, puts the caret after it, and
/// tells the editor.
fn replace(win: *Window, id: NodeId, start: u32, end: u32, insert: []const u8) void {
    const old = data(win, id).text.content;
    const a = win.scratch.allocator();
    const content = std.mem.concat(a, u8, &.{ old[0..start], insert, old[end..] }) catch return;
    const caret: u32 = @intCast(start + insert.len);
    const t = win.begin() catch return;
    t.setText(id, content) catch {
        t.abort();
        return;
    };
    t.setSelection(id, caret, caret, .downstream) catch {
        t.abort();
        return;
    };
    t.commit();
    win.state(id).preferred_x = null;
    if (win.isLive(id)) if (win.node(id).handler(.change)) |h| {
        _ = h.func(h.user, win, id, &.change);
    };
}

fn selection(e: *const node_mod.EditorData) struct { u32, u32 } {
    return .{ @min(e.caret, e.anchor), @max(e.caret, e.anchor) };
}

/// Inserts typed text, replacing the selection. Single-line editors drop
/// line breaks.
pub fn insertText(win: *Window, id: NodeId, str: []const u8) void {
    const e = data(win, id);
    var buf: std.ArrayList(u8) = .empty;
    for (str) |c| if (e.editor.multiline or (c != '\n' and c != '\r')) buf.append(win.scratch.allocator(), c) catch return;
    if (buf.items.len == 0 and str.len != 0) return;
    const lo, const hi = selection(e);
    replace(win, id, lo, hi, buf.items);
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
            const next: Position = if (mods.ctrl)
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
                replace(win, id, lo, hi, "");
            } else if (k.keysym == backspace) {
                if (e.caret == 0) return true;
                const start = if (mods.ctrl) l.previousWordStart(e.caret) else l.previousGrapheme(e.caret);
                replace(win, id, start, e.caret, "");
            } else {
                if (e.caret == len) return true;
                const end = if (mods.ctrl) l.nextWordEnd(e.caret) else l.nextGrapheme(e.caret);
                replace(win, id, e.caret, end, "");
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
