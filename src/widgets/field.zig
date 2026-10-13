//! Text fields and areas: the editor primitive (D15) framed in themed
//! colors, with its placeholder. The builder returns the editor itself,
//! so the application uses editor functions and `change` events on it
//! directly. The border takes the accent while the field has focus.

const std = @import("std");
const w = @import("widgets.zig");
const button = @import("button.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Field = extern struct {
    hdr: w.Header,
    focused: bool = false,
    multiline: bool = false,
    rows: u32 = 3,
    root: Node,
};

pub export fn siv_text_field(txn: Txn, parent: Node, desc: ?*const siv.TextFieldDesc) Node {
    const d = w.readDesc(siv.TextFieldDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 15) != 0) return w.fail(txn, .error_unsupported);
    if (d.flags.styled and d.flags.masked) return w.fail(txn, .error_invalid_argument);
    const text = w.str(d.text, d.text_len) orelse return w.fail(txn, .error_invalid_argument);
    const placeholder = w.str(d.placeholder, d.placeholder_len) orelse return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_editor(txn, parent, .{ .multiline = d.flags.multiline, .masked = d.flags.masked });
    if (root == .null) return .null;
    _ = c.siv_set_text(txn, root, text.ptr, text.len);
    _ = c.siv_set_placeholder(txn, root, placeholder.ptr, placeholder.len);
    const st = w.create(Field, txn, root) orelse return .null;
    st.* = .{
        .hdr = .{ .kind = .text_field, .disabled = d.flags.disabled },
        .multiline = d.flags.multiline,
        .rows = if (d.rows == 0) 3 else @min(d.rows, 1000),
        .root = root,
    };
    const name = if (label.len != 0) label else placeholder;
    _ = c.siv_set_semantics(txn, root, &.{ .label = name.ptr, .label_len = name.len });
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .focus, onFocus, st);
    if (d.flags.styled) w.onDefault(txn, root, .key, onStyleKey, st);
    apply(txn, st);
    return root;
}

/// Styled-text editors (D22): Ctrl+B, Ctrl+I, and Ctrl+U toggle bold,
/// italic, and underline. An attribute turns off when all of the
/// selection has it (or, with nothing selected, the typing style), else
/// on, as word processors do. Ctrl+L, Ctrl+E, Ctrl+R, and Ctrl+J align
/// the selected paragraphs left, centered, right, and justified (D13);
/// left in a left-to-right editor and right in a right-to-left one go
/// back to the editor's own alignment.
fn onStyleKey(ud: ?*anyopaque, node: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Field = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (st.hdr.disabled or !e.flags.pressed or !e.modifiers.ctrl or e.modifiers.alt or e.modifiers.super) return false;
    switch (e.keysym) {
        'l', 'L', 'e', 'E', 'r', 'R', 'j', 'J' => {
            var rtl = false;
            _ = c.siv_node_is_rtl(node, &rtl);
            const left: siv.TextAlign = if (rtl) .end else .start;
            const right: siv.TextAlign = if (rtl) .start else .end;
            const a: siv.TextAlign = switch (e.keysym) {
                'l', 'L' => left,
                'e', 'E' => .center,
                'j', 'J' => .justify,
                else => right,
            };
            _ = c.siv_editor_format_paragraph(node, .{ .flags = .{ .@"align" = a != .start }, .@"align" = a }, .{ .@"align" = true });
            return true;
        },
        else => {},
    }
    const Attr = enum { bold, italic, underline };
    const attr: Attr = switch (e.keysym) {
        'b', 'B' => .bold,
        'i', 'I' => .italic,
        'u', 'U' => .underline,
        else => return false,
    };
    const has = struct {
        fn f(a: Attr, s: siv.TextSpan) bool {
            return switch (a) {
                .bold => s.flags.weight and @intFromEnum(s.weight) >= @intFromEnum(siv.FontWeight.semibold),
                .italic => s.flags.slant and s.slant != .roman,
                .underline => s.flags.underline,
            };
        }
    }.f;
    var caret: u32 = 0;
    var anchor: u32 = 0;
    if (c.siv_node_get_selection(node, &caret, &anchor) != .ok) return false;
    const lo = @min(caret, anchor);
    const hi = @max(caret, anchor);
    var on = true;
    if (lo == hi) {
        var typing: siv.TextSpan = undefined;
        if (c.siv_node_get_typing_style(node, &typing) != .ok) return false;
        on = !has(attr, typing);
    } else {
        // Off only when every run of the selection has it.
        var at = lo;
        var all = true;
        while (at < hi) {
            var run: siv.TextSpan = undefined;
            if (c.siv_node_get_text_run(node, at, &run) != .ok) return false;
            all = all and has(attr, run);
            at = @max(run.end, at + 1);
        }
        on = !all;
    }
    const values: siv.TextSpan = switch (attr) {
        .bold => .{ .flags = .{ .weight = on }, .weight = .bold },
        .italic => .{ .flags = .{ .slant = on }, .slant = .italic },
        .underline => .{ .flags = .{ .underline = on } },
    };
    const mask: siv.TextSpanFlags = switch (attr) {
        .bold => .{ .weight = true },
        .italic => .{ .slant = true },
        .underline => .{ .underline = true },
    };
    _ = c.siv_editor_format(node, values, mask);
    return true;
}

pub fn apply(txn: Txn, st: *Field) void {
    const h = st.hdr;
    const min_h: f32 = if (st.multiline) @as(f32, @floatFromInt(st.rows)) * tk.line_height + 2 * tk.pad_y else tk.control_height;
    _ = c.siv_set_default_layout(txn, st.root, &.{
        .min_width = tk.field_min_width,
        .min_height = min_h,
        .padding = .{ .start = tk.field_pad_x, .end = tk.field_pad_x, .top = tk.pad_y + 1, .bottom = tk.pad_y + 1 },
    });
    const border: siv.ColorToken = if (h.disabled) .border else if (st.focused) .accent else .border;
    _ = c.siv_set_visual(txn, st.root, &.{
        .radius = .{ .top_start = tk.radius, .top_end = tk.radius, .bottom_end = tk.radius, .bottom_start = tk.radius },
        .border_width = if (st.focused and !h.disabled) 2 * tk.border else tk.border,
        .border_token = border,
        .background_token = if (h.disabled) .control_bg else .view_bg,
    });
    _ = c.siv_set_text_style(txn, st.root, &.{ .color_token = if (h.disabled) .disabled_fg else .view_fg, .size_role = .body });
    var buf: [1024]u8 = undefined;
    const label = w.labelOf(st.root, &buf);
    _ = c.siv_set_semantics(txn, st.root, &.{ .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = h.disabled } });
}

pub fn setLabel(txn: Txn, st: *Field, label: []const u8) void {
    _ = c.siv_set_semantics(txn, st.root, &.{ .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = st.hdr.disabled } });
}

fn onPointer(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Field = @ptrCast(@alignCast(ud.?));
    _ = button.feedback(&st.hdr, ev.?);
    return false;
}

fn onFocus(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) bool {
    const st: *Field = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    st.focused = e.flags.gained;
    const txn = w.begin(e.window) orelse return false;
    apply(txn, st);
    _ = w.commit(txn);
    return false;
}
