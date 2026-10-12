//! Text nodes (D13): each owns a width-independent `ShapedParagraph`,
//! rebuilt only when its text or font-related style changes or a font it
//! wanted finished loading, and a `Layout` for the current width, rebuilt
//! when the width changes.

const std = @import("std");
const text = @import("text");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const Fonts = @import("fonts.zig");

const NodeId = node_mod.NodeId;

pub const Cache = struct {
    paragraph: ?text.ShapedParagraph = null,
    layout: ?text.Layout = null,
    /// The width the layout was built for (null: unwrapped).
    layout_width: ?f32 = null,
    /// `Fonts.serial` when the paragraph was shaped.
    serial: u32 = 0,

    pub fn destroy(c: *Cache, gpa: std.mem.Allocator) void {
        if (c.layout) |*l| l.deinit();
        if (c.paragraph) |*p| p.deinit();
        gpa.destroy(c);
    }

    /// The paragraph wanted fonts and some font finished loading since.
    pub fn waiting(c: *const Cache, fonts: *const Fonts) bool {
        const p = c.paragraph orelse return false;
        return p.wanted.len != 0 and c.serial != fonts.serial;
    }

    fn dropLayout(c: *Cache) void {
        if (c.layout) |*l| l.deinit();
        c.layout = null;
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
    const style = d.props.style;
    const language = if (d.language != 0) d.language else win.language;
    const chain = try fonts.chain(.{ .family = d.family, .language = language, .weight = style.weight, .slant = style.slant });
    const n = win.node(id);
    const content = if (n.kind == .editor) try @import("editor.zig").displayText(win, id, win.scratch.allocator()) else d.content;
    var p = text.ShapedParagraph.init(win.gpa, win.scratch.allocator(), &fonts.cache, content, &.{.{
        .end = @intCast(content.len),
        .style = .{ .fonts = chain, .size = style.size, .language = if (fonts.name(language).len == 0) "und" else fonts.name(language) },
    }}, if (s.rtl) .auto_rtl else .auto_ltr) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Validated when the text was set.
        error.InvalidUtf8, error.TextTooLong, error.InvalidStyles => unreachable,
    };
    errdefer p.deinit();
    c.dropLayout();
    if (c.paragraph) |*old| old.deinit();
    c.paragraph = p;
    c.serial = fonts.serial;
    s.needs_shape = false;
    win.stats.shapes += 1;
    if (p.wanted.len != 0) fonts.request(p.wanted);
    return c;
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
        if (l.width <= want and want <= built) return l;
    }
    // Lines are aligned in the node at paint time (`lineShift`).
    const l = text.Layout.init(win.gpa, win.scratch.allocator(), &win.fonts.cache, &c.paragraph.?, .{
        .width = width,
        .alignment = .start,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // finite, non-negative widths only
    };
    c.dropLayout();
    c.layout = l;
    c.layout_width = width;
    win.stats.text_layouts += 1;
    return &c.layout.?;
}

/// Unwrapped width of the text.
pub fn maxContent(win: *Window, id: NodeId) error{OutOfMemory}!f32 {
    const l = try layoutFor(win, id, null) orelse return 0;
    return l.width;
}

/// The node's current layout (after layout ran).
pub fn current(win: *const Window, id: NodeId) ?*const text.Layout {
    const c = win.state(id).text orelse return null;
    const n = win.node(id);
    if (n.kind == .text and n.data.text.content.len == 0) return null;
    return if (c.layout) |*l| l else null;
}

/// Horizontal shift that aligns a line in the node's content box. The
/// layout placed each line at the start of its own base direction; text
/// aligns by the node's direction instead (D21), so an English label in a
/// right-to-left window is flush right, while each paragraph's bidi
/// ordering still follows its own text.
pub fn lineShift(win: *const Window, id: NodeId, line: text.layout.Line, content_width: f32) f32 {
    const c = win.state(id).text.?;
    const l = c.layout.?;
    const aligned_in = c.layout_width orelse l.width;
    // Left edge of the line's content (without hanging whitespace) now.
    const now = if (line.rtl()) aligned_in - line.width else 0;
    const rtl = win.state(id).rtl;
    const target: f32 = switch (win.node(id).textData().props.alignment) {
        .start => if (rtl) content_width - line.width else 0,
        .end => if (rtl) 0 else content_width - line.width,
        .center => (content_width - line.width) / 2,
    };
    return target - now;
}
