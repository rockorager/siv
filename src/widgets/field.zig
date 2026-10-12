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
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 7) != 0) return w.fail(txn, .error_unsupported);
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
    apply(txn, st);
    return root;
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
