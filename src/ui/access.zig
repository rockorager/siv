//! What the AT-SPI bridge (D18) needs beyond the semantics tree: text
//! geometry and editing that assistive technology drives.
//!
//! Offsets are bytes into a text or editor node's text: the semantics
//! name of a text node without a label, and an editor's `value_text`. An
//! input method's preedit is not part of it. Geometry is in window
//! coordinates and follows an editor's horizontal scrolling; it describes
//! the last frame's layout, like the semantics tree. Masked editors
//! expose no text, so they have no geometry and take no edits.
//!
//! Edits go through the same path as the user's: each is its own
//! transaction with a change event and an undo step (except selection
//! changes), and while the application holds a transaction open (or input
//! waits behind one) they queue and apply in order at the next frame
//! (D15).

const std = @import("std");
const raster = @import("raster");
const text = @import("text");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const text_node = @import("text_node.zig");
const editor = @import("editor.zig");
const spans = @import("spans.zig");

const NodeId = node_mod.NodeId;
const Point = raster.Point;
const Rect = raster.Rect;
const Layout = text.TextLayout;

pub const EditError = error{
    OutOfMemory,
    /// Not a live, unmasked, enabled editor.
    InvalidNode,
    /// Offsets past the end, not on code point boundaries, or a start
    /// after the end; text that is not UTF-8.
    InvalidArgument,
};

/// A text or editor node's laid-out text, and how its offsets map.
const Geometry = struct {
    win: *const Window,
    id: NodeId,
    layout: *const Layout,
    /// Window position of the layout origin (padding and scrolling applied).
    origin: Point,
    content_width: f32,
    /// The preedit shown at `preedit_at`, in the layout's text.
    preedit_at: u32 = 0,
    preedit_len: u32 = 0,
    len: u32,

    fn of(win: *const Window, id: NodeId) ?Geometry {
        if (!win.isLive(id)) return null;
        const n = win.node(id);
        if (!n.isText()) return null;
        if (n.kind == .editor and n.data.editor.editor.masked) return null;
        const l = text_node.current(win, id) orelse return null;
        const s = win.state(id);
        const pad = n.layout.padding;
        const r = win.windowRect(id);
        var g: Geometry = .{
            .win = win,
            .id = id,
            .layout = l,
            .origin = .{ .x = r.x0 + pad.left(s.rtl), .y = r.y0 + pad.top },
            .content_width = s.size.w - pad.horizontal(),
            .len = @intCast(n.textData().content.len()),
        };
        if (n.kind == .editor) {
            g.origin.x -= s.editor_scroll;
            if (editor.preeditRange(win, id)) |p| {
                g.preedit_at = p[0];
                g.preedit_len = p[1] - p[0];
            }
        }
        return g;
    }

    /// An offset in the text to one in the layout's text. The preedit
    /// sits before the character at its offset.
    fn shown(g: Geometry, offset: u32) u32 {
        return if (g.preedit_len != 0 and offset >= g.preedit_at) offset + g.preedit_len else offset;
    }

    /// An offset in the layout's text to one in the text; inside the
    /// preedit is where it sits.
    fn fromShown(g: Geometry, offset: u32) u32 {
        if (g.preedit_len == 0 or offset <= g.preedit_at) return offset;
        if (offset < g.preedit_at + g.preedit_len) return g.preedit_at;
        return offset - g.preedit_len;
    }

    fn shift(g: Geometry, line: u32) error{OutOfMemory}!f32 {
        return text_node.lineShift(g.win, g.id, try g.layout.line(line), g.content_width);
    }
};

/// The window rectangle of the character at `offset`, or a zero-width
/// rectangle at the end of the text for its length. Null if the node has
/// no text geometry or `offset` is past the end.
pub fn characterRect(win: *const Window, id: NodeId, offset: u32) ?Rect {
    const g = Geometry.of(win, id) orelse return null;
    if (offset > g.len) return null;
    // Without memory to lay out the block holding it, there is no answer.
    return characterRectIn(g, offset) catch null;
}

fn characterRectIn(g: Geometry, offset: u32) error{OutOfMemory}!Rect {
    const l = g.layout;
    const at = g.shown(offset);
    const lead = try l.caret(.{ .offset = at, .affinity = .downstream });
    var x0 = lead.x;
    var x1 = lead.x;
    if (offset < g.len) {
        // The character runs from its leading edge to the caret after it
        // on the same line, whichever way the run goes.
        const trail = try l.caret(.{ .offset = try l.nextGrapheme(at), .affinity = .upstream });
        if (trail.line == lead.line) {
            x0 = @min(lead.x, trail.x);
            x1 = @max(lead.x, trail.x);
        }
    }
    const dx = g.origin.x + try g.shift(lead.line);
    return .{ .x0 = dx + x0, .y0 = g.origin.y + lead.top, .x1 = dx + x1, .y1 = g.origin.y + lead.top + lead.height };
}

/// The style run of a text or editor node containing byte `offset`: a
/// span (D22) or the unstyled stretch around it, in the node's current
/// text. Null for other nodes and masked editors.
pub fn textRun(win: *const Window, id: NodeId, offset: u32) ?node_mod.Span {
    if (!win.isLive(id)) return null;
    const n = win.node(id);
    if (!n.isText()) return null;
    if (n.kind == .editor and n.data.editor.editor.masked) return null;
    const d = n.textData();
    const len: u32 = @intCast(d.content.len());
    return spans.runAt(d.spans, @min(offset, len), len);
}

/// The paragraph of a text or editor node containing byte `offset`: its
/// range (up to the end of its separator) and its paragraph span's style.
/// Null for other nodes and masked editors.
pub fn paragraphRun(win: *const Window, id: NodeId, offset: u32) ?node_mod.ParagraphSpan {
    if (!win.isLive(id)) return null;
    const n = win.node(id);
    if (!n.isText()) return null;
    if (n.kind == .editor and n.data.editor.editor.masked) return null;
    const d = n.textData();
    const p = spans.paragraphAt(d.content, @min(offset, @as(u32, @intCast(d.content.len()))));
    return .{ .start = p.start, .end = p.end, .style = spans.styleAt(d.paragraphs, p.start) };
}

/// The stretch of a text or editor node around byte `offset` whose
/// paragraph style is the same: a paragraph span (whole paragraphs), or
/// the paragraphs with the node's defaults around it.
pub fn paragraphStyleRun(win: *const Window, id: NodeId, offset: u32) ?node_mod.ParagraphSpan {
    const p = paragraphRun(win, id, offset) orelse return null;
    const d = win.node(id).textData();
    const len: u32 = @intCast(d.content.len());
    return spans.runAt(d.paragraphs, p.start, len);
}

/// Formatting commands on editors and the typing style (D22, D13).
pub const format = editor.format;
pub const formatParagraph = editor.formatParagraph;
pub const typingStyle = editor.typingStyle;

/// The offset nearest a window point (a caret position), or null if the
/// node has no text geometry.
pub fn offsetAt(win: *const Window, id: NodeId, p: Point) ?u32 {
    const g = Geometry.of(win, id) orelse return null;
    const l = g.layout;
    const y = p.y - g.origin.y;
    const line = l.lineAt(y) catch return null;
    const pos = l.hitTest(p.x - g.origin.x - (g.shift(line) catch return null), y) catch return null;
    return g.fromShown(pos.offset);
}

/// The byte range of the visual line containing `offset`, including its
/// trailing whitespace and line break. Null if the node has no text
/// geometry or `offset` is past the end.
pub fn lineRange(win: *const Window, id: NodeId, offset: u32) ?[2]u32 {
    const g = Geometry.of(win, id) orelse return null;
    if (offset > g.len) return null;
    const caret = g.layout.caret(.{ .offset = g.shown(offset), .affinity = .downstream }) catch return null;
    const line = g.layout.line(caret.line) catch return null;
    return .{ g.fromShown(line.start), @min(g.fromShown(line.end), g.len) };
}

fn editable(win: *const Window, id: NodeId) EditError!text.Rope {
    if (!win.isLive(id)) return error.InvalidNode;
    const n = win.node(id);
    if (n.kind != .editor or n.data.editor.editor.masked or n.semantics.disabled) return error.InvalidNode;
    return n.data.editor.text.content;
}

fn submit(win: *Window, p: editor.Pending) EditError!void {
    if (editor.mustQueue(win)) return editor.queue(win, p);
    editor.apply(win, p);
}

/// Replaces `start..end` with `str`, leaving the caret after it, as a
/// paste would (single-line editors turn line breaks into spaces).
pub fn replaceText(win: *Window, id: NodeId, start: u32, end: u32, str: []const u8) EditError!void {
    const content = try editable(win, id);
    if (!editor.validRange(content, start, end) or !std.unicode.utf8ValidateSlice(str)) return error.InvalidArgument;
    const copy = try win.gpa.dupe(u8, str);
    return submit(win, .{ .node = id, .edit = .{ .replace = .{ .start = start, .end = end, .text = copy } } });
}

/// Moves the caret, and the selection's other end to `anchor`.
pub fn setSelection(win: *Window, id: NodeId, caret: u32, anchor: u32) EditError!void {
    const content = try editable(win, id);
    if (!editor.validRange(content, @min(caret, anchor), @max(caret, anchor))) return error.InvalidArgument;
    return submit(win, .{ .node = id, .edit = .{ .select = .{ .caret = caret, .anchor = anchor } } });
}

/// Copies `start..end` to the clipboard and, with `cut`, deletes it. The
/// clipboard request carries the serial of the window's last input event,
/// so a compositor may refuse it if the window has had no input.
pub fn copyText(win: *Window, id: NodeId, start: u32, end: u32, cut: bool) EditError!void {
    const content = try editable(win, id);
    if (!editor.validRange(content, start, end)) return error.InvalidArgument;
    return submit(win, .{ .node = id, .edit = .{ .copy = .{ .start = start, .end = end, .cut = cut } } });
}

/// Moves the caret to `offset` and pastes the clipboard there.
pub fn pasteText(win: *Window, id: NodeId, offset: u32) EditError!void {
    const content = try editable(win, id);
    if (!editor.validRange(content, offset, offset)) return error.InvalidArgument;
    return submit(win, .{ .node = id, .edit = .{ .paste_at = offset } });
}
