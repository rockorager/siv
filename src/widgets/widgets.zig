//! Stock widgets (D22), written against the public C API only: this module
//! imports nothing but `siv`, the generated Zig wrapper of the C ABI, so a
//! stock widget can do nothing a widget written in C cannot. libsiv
//! exports the builders and view functions from here; their signatures
//! are checked against the schema like every export.
//!
//! Conventions every widget follows:
//!
//! - A builder appends the widget's root node and returns it (0 once the
//!   transaction has failed). Invalid descriptors fail the transaction
//!   (`siv_txn_fail`).
//! - State is node data on the root under `key`, beginning with `Header`;
//!   handlers get it as user data.
//! - Behavior is installed with `siv_on_default`, so the application's
//!   `siv_on` handlers run first and can override it.
//! - The generic `siv_widget_*` calls reach a widget through the interface
//!   its builder sets on the root with `siv_set_widget` (`setInterface`),
//!   as they reach an application's widget.
//! - User changes commit in a transaction of their own, then report
//!   `change` with `siv_node_emit`; values set by the application do not.
//! - Colors and text sizes are theme tokens (D29); metrics come from
//!   tokens.zig.
//!
//! Imports: siv (generated) only.

const std = @import("std");
pub const siv = @import("siv");
pub const tokens = @import("tokens.zig");
pub const button = @import("button.zig");
pub const toggle = @import("toggle.zig");
pub const radio = @import("radio.zig");
pub const field = @import("field.zig");
pub const range = @import("range.zig");
pub const menu = @import("menu.zig");
pub const dialog = @import("dialog.zig");
pub const tabs = @import("tabs.zig");
pub const split = @import("split.zig");
pub const toast = @import("toast.zig");
pub const views = @import("views.zig");

const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

/// The files that export schema functions, for src/abi/abi.zig.
pub const implementations = .{ @This(), button, toggle, radio, field, range, menu, dialog, tabs, split, toast, views };

var key_byte: u8 = 0;

/// The node data key of every stock widget's state.
pub fn key() *anyopaque {
    return @ptrCast(&key_byte);
}

pub const Kind = enum(u8) {
    button,
    toggle_button,
    check_box,
    @"switch",
    radio_group,
    radio,
    text_field,
    slider,
    spin_button,
    progress_bar,
    menu,
    menu_button,
    menu_item,
    /// A menu item's row in its popup.
    menu_row,
    /// A popover's popup root.
    popover,
    dialog,
    tabs,
    tab,
    split_pane,
    toast,
    /// Lists, trees, tables, and grids.
    view,
    view_row,
    /// A table column's header cell.
    view_column,
};

/// The first field of every widget's state.
pub const Header = extern struct {
    kind: Kind,
    disabled: bool = false,
    hover: bool = false,
    pressed: bool = false,
};

/// Gives `node` zeroed state of type T; null once the transaction failed.
pub fn create(comptime T: type, txn: Txn, node: Node) ?*T {
    var p: ?*anyopaque = null;
    if (c.siv_set_data(txn, node, key(), @sizeOf(T), &p) != .ok) return null;
    return @ptrCast(@alignCast(p.?));
}

/// Node data is 16-byte aligned, so the header casts to any state.
pub const HeaderPtr = *align(16) Header;

pub fn header(node: Node) ?HeaderPtr {
    var p: ?*anyopaque = null;
    if (c.siv_node_get_data(node, key(), &p) != .ok) return null;
    return @ptrCast(@alignCast(p orelse return null));
}

/// A widget's state, if `node` is a widget of one of `kinds`.
pub fn stateOf(comptime T: type, node: Node, kinds: []const Kind) ?*T {
    const h = header(node) orelse return null;
    for (kinds) |k| if (h.kind == k) return @ptrCast(h);
    return null;
}

pub fn fail(txn: Txn, err: siv.Result) Node {
    _ = c.siv_txn_fail(txn, err);
    return .null;
}

/// Reads a descriptor the way siv does: NULL is all defaults, a smaller
/// size (older headers) leaves later fields at their defaults, a larger
/// one must have zeros past the fields this version knows.
pub fn readDesc(comptime T: type, ptr: ?*const T) ?T {
    const p = ptr orelse return .{};
    if (p.size < @sizeOf(usize)) return null;
    var out: T = .{};
    const n = @min(p.size, @sizeOf(T));
    @memcpy(std.mem.asBytes(&out)[0..n], std.mem.asBytes(p)[0..n]);
    if (p.size > @sizeOf(T)) {
        const extra = @as([*]const u8, @ptrCast(p))[@sizeOf(T)..p.size];
        for (extra) |b| if (b != 0) return null;
    }
    out.size = @sizeOf(T);
    return out;
}

pub fn str(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return "";
    return (ptr orelse return null)[0..len];
}

/// Sets the node's default handler for one event type, with the widget's
/// state as user data.
pub fn onDefault(txn: Txn, node: Node, kind: siv.EventType, func: siv.EventFn, state: *anyopaque) void {
    _ = c.siv_on_default(txn, node, kind, func, null, state);
}

/// Reports a value change to the application's handler on `node`.
pub fn emitChange(node: Node, value: f64, index: u32) void {
    var handled = false;
    _ = c.siv_node_emit(node, &.{ .type = .change, .value = value, .index = index }, &handled);
}

/// A transaction of the widget's own, for changes the user made.
pub fn begin(window: siv.Window) ?Txn {
    var txn: Txn = .null;
    if (c.siv_txn_begin(window, &txn) != .ok) return null;
    return txn;
}

pub fn commit(txn: Txn) bool {
    return c.siv_txn_commit(txn) == .ok;
}

pub fn isRtl(node: Node) bool {
    var rtl = false;
    _ = c.siv_node_is_rtl(node, &rtl);
    return rtl;
}

/// The node's accessible label, truncated to the buffer at a character
/// boundary.
/// The text of a text node, cut at a UTF-8 boundary to fit `buf`.
pub fn textOf(node: Node, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_node_get_text(node, buf.ptr, buf.len, &len) != .ok) return "";
    return fitUtf8(buf, len);
}

/// The first `len` bytes of a string copied into `buf`, or what fits of
/// it, cut before a code point that does not fit whole.
fn fitUtf8(buf: []const u8, len: usize) []const u8 {
    if (len <= buf.len) return buf[0..len];
    var start = buf.len;
    while (start > 0 and buf[start - 1] & 0xc0 == 0x80) start -= 1;
    if (start == 0) return buf[0..0];
    const n = std.unicode.utf8ByteSequenceLength(buf[start - 1]) catch 1;
    return if (start - 1 + n <= buf.len) buf else buf[0 .. start - 1];
}

/// A text node that takes no space and is not shown or announced: a
/// widget keeps a string in the tree with it (an icon's name).
pub fn hiddenText(txn: Txn, parent: Node, text: []const u8) Node {
    const n = c.siv_text(txn, parent, text.ptr, text.len);
    _ = c.siv_set_visual(txn, n, &.{ .flags = .{ .hidden = true } });
    return n;
}

/// Shows the themed icon named by the text of `name` (D19) in `image`,
/// at `size`, in a themed color.
pub fn setIcon(txn: Txn, image: Node, name: Node, size: f32, token: siv.ColorToken) void {
    var buf: [1024]u8 = undefined;
    const icon = textOf(name, &buf);
    _ = c.siv_set_image_view(txn, image, &.{ .icon = icon.ptr, .icon_len = icon.len, .icon_size = size, .color_token = token });
}

pub fn labelOf(node: Node, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_node_get_label(node, buf.ptr, buf.len, &len) != .ok) return "";
    return fitUtf8(buf, len);
}

pub fn windowOf(node: Node) siv.Window {
    var win: siv.Window = .null;
    _ = c.siv_node_get_window(node, &win);
    return win;
}

pub fn appOf(window: siv.Window) siv.App {
    var app: siv.App = .null;
    _ = c.siv_window_get_app(window, &app);
    return app;
}

/// Whether a window handle is still valid (a popup may have been
/// dismissed).
pub fn windowAlive(window: siv.Window) bool {
    return window != .null and appOf(window) != .null;
}

/// A node handle as callback user data, for callbacks that may outlive
/// the node (timers, popups): looking the handle up again is safe, since
/// a stale handle is an error, never another node.
pub fn handleData(node: Node) ?*anyopaque {
    return @ptrFromInt(@backingInt(node));
}

pub fn dataHandle(ud: ?*anyopaque) Node {
    return @fromBackingInt(@intFromPtr(ud));
}

pub fn corners(r: f32) siv.Corners {
    return .{ .top_start = r, .top_end = r, .bottom_end = r, .bottom_start = r };
}

pub fn px(v: f32) siv.Dimension {
    return .{ .unit = .px, .value = v };
}

pub fn color(window: siv.Window, token: siv.ColorToken) siv.Color {
    var col: siv.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    _ = c.siv_window_get_color(window, token, &col);
    return col;
}

/// A check mark, or a dash for mixed, stroked in `col` (check boxes and
/// checkable menu items).
pub fn drawCheck(draw: siv.Draw, width: f32, height: f32, col: siv.Color, mixed: bool) void {
    if (mixed) {
        _ = c.siv_draw_move_to(draw, width * 0.27, height * 0.5);
        _ = c.siv_draw_line_to(draw, width * 0.73, height * 0.5);
    } else {
        _ = c.siv_draw_move_to(draw, width * 0.24, height * 0.53);
        _ = c.siv_draw_line_to(draw, width * 0.43, height * 0.71);
        _ = c.siv_draw_line_to(draw, width * 0.77, height * 0.31);
    }
    _ = c.siv_draw_stroke(draw, &.{ .width = tokens.check_stroke, .join = .round, .cap = .round }, &.{ .color = col });
}

pub fn related(node: Node, rel: siv.Relation) Node {
    var out: Node = .null;
    _ = c.siv_node_get_related(node, rel, &out);
    return out;
}

/// A label's text style.
pub fn textStyle(token: siv.ColorToken, role: siv.SizeRole) siv.TextStyleDesc {
    return .{ .color_token = token, .size_role = role, .flags = .{ .no_wrap = true } };
}

/// Clamps to the range and snaps to min plus multiples of step.
pub fn snap(v: f64, min: f64, max: f64, step: f64) f64 {
    var x = std.math.clamp(v, min, max);
    if (step > 0) {
        x = min + @round((x - min) / step) * step;
        if (x > max) x -= step;
        x = std.math.clamp(x, min, max);
    }
    return x;
}

/// A handler result from whether the widget handled the event.
pub fn resultOf(yes: bool) siv.EventResult {
    return if (yes) .handled else .pass;
}

// Keysyms the widgets handle.
pub const keysym = siv.Key;

/// Keyboard direction of an arrow key: -1 back, +1 forward, 0 neither.
/// Left and right swap in right-to-left layouts.
pub fn arrowDirection(sym: siv.Key, rtl: bool) i2 {
    return switch (sym) {
        keysym.up => -1,
        keysym.down => 1,
        keysym.left => if (rtl) 1 else -1,
        keysym.right => if (rtl) -1 else 1,
        else => 0,
    };
}

// The widget interface ---------------------------------------------------------

/// Gives a stock widget's root its interface (siv_set_widget, D22), with
/// its state as user data, so the generic siv_widget_* calls reach it the
/// way they reach an application's widget. `ops` names functions of the
/// state, each optional:
///
///   set_label, set_icon: fn (Txn, *T, []const u8) void
///   set_value:           fn (Txn, *T, f64) void
///   set_range:           fn (Txn, *T, f64, f64, f64) void
///   get_value:           fn (*const T) f64
///   get_part:            fn (*const T, siv.WidgetPart, u32) Node
///   focus:               fn (*T) Node
///   apply:               fn (Txn, *T) void; with it, siv_widget_set_disabled
///                        sets the header's disabled flag and shows it
pub fn setInterface(txn: Txn, node: Node, comptime T: type, st: *T, comptime ops: anytype) void {
    const O = @TypeOf(ops);
    const I = struct {
        fn state(ud: ?*anyopaque) *T {
            return @ptrCast(@alignCast(ud.?));
        }
        fn setLabel(ud: ?*anyopaque, txn_: Txn, _: Node, p: ?[*]const u8, len: usize) callconv(.c) void {
            ops.set_label(txn_, state(ud), str(p, len) orelse "");
        }
        fn setIcon(ud: ?*anyopaque, txn_: Txn, _: Node, p: ?[*]const u8, len: usize) callconv(.c) void {
            ops.set_icon(txn_, state(ud), str(p, len) orelse "");
        }
        fn setDisabled(ud: ?*anyopaque, txn_: Txn, _: Node, disabled: bool) callconv(.c) void {
            const st_ = state(ud);
            const h: *Header = &st_.hdr;
            h.disabled = disabled;
            if (disabled) {
                h.hover = false;
                h.pressed = false;
            }
            ops.apply(txn_, st_);
        }
        fn setValue(ud: ?*anyopaque, txn_: Txn, _: Node, v: f64) callconv(.c) void {
            ops.set_value(txn_, state(ud), v);
        }
        fn setRange(ud: ?*anyopaque, txn_: Txn, _: Node, min: f64, max: f64, step: f64) callconv(.c) void {
            ops.set_range(txn_, state(ud), min, max, step);
        }
        fn getValue(ud: ?*anyopaque, _: Node) callconv(.c) f64 {
            return ops.get_value(state(ud));
        }
        fn getPart(ud: ?*anyopaque, _: Node, part: siv.WidgetPart, index: u32) callconv(.c) Node {
            return ops.get_part(state(ud), part, index);
        }
        fn focus(ud: ?*anyopaque, _: Node) callconv(.c) Node {
            return ops.focus(state(ud));
        }
    };
    var d: siv.WidgetDesc = .{ .user_data = st };
    if (@hasField(O, "set_label")) d.set_label = I.setLabel;
    if (@hasField(O, "set_icon")) d.set_icon = I.setIcon;
    if (@hasField(O, "apply")) d.set_disabled = I.setDisabled;
    if (@hasField(O, "set_value")) d.set_value = I.setValue;
    if (@hasField(O, "set_range")) d.set_range = I.setRange;
    if (@hasField(O, "get_value")) d.get_value = I.getValue;
    if (@hasField(O, "get_part")) d.get_part = I.getPart;
    if (@hasField(O, "focus")) d.focus = I.focus;
    _ = c.siv_set_widget(txn, node, &d);
}
