//! Stock widgets (D22), written against the public C API only: this module
//! imports nothing but `siv`, the generated Zig wrapper of the C ABI, so a
//! stock widget can do nothing a widget written in C cannot. libsiv
//! exports the builders and `siv_widget_*` functions from here; their
//! signatures are checked against the schema like every export.
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
//! - User changes commit in a transaction of their own, then report
//!   `change` with `siv_emit`; values set by the application do not.
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
    _ = c.siv_emit(node, &.{ .type = .change, .value = value, .index = index }, &handled);
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
pub fn labelOf(node: Node, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_node_get_label(node, buf.ptr, buf.len, &len) != .ok) return "";
    if (len <= buf.len) return buf[0..len];
    var end = buf.len;
    while (end > 0 and buf[end] & 0xc0 == 0x80) end -= 1;
    return buf[0..end];
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
pub fn textStyle(token: siv.ColorToken, role: siv.TextRole) siv.TextStyleDesc {
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

// Generic widget functions ----------------------------------------------------

pub export fn siv_widget_set_label(txn: Txn, node: Node, label: ?[*]const u8, label_len: usize) siv.Result {
    const s = str(label, label_len) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    const h = header(node) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    switch (h.kind) {
        .button, .toggle_button => button.setLabel(txn, @ptrCast(h), s),
        .check_box, .@"switch" => toggle.setLabel(txn, @ptrCast(h), s),
        .radio => radio.setLabel(txn, @ptrCast(h), s),
        .radio_group => radio.setGroupLabel(txn, @ptrCast(h), s),
        .text_field => field.setLabel(txn, @ptrCast(h), s),
        .slider, .spin_button, .progress_bar => range.setLabel(txn, @ptrCast(h), s),
        .menu_button => button.setLabel(txn, @ptrCast(h), s),
        .menu_item => menu.setItemLabel(txn, @ptrCast(h), s),
        .view => views.setLabel(txn, @ptrCast(h), s),
        .view_column => views.setColumnLabel(txn, @ptrCast(h), s),
        .menu, .popover, .menu_row, .dialog, .tabs, .tab, .split_pane, .toast, .view_row => setName(txn, h, node, s),
    }
    return c.siv_txn_status(txn);
}

/// Widgets whose label is only their accessible name.
fn setName(txn: Txn, h: HeaderPtr, node: Node, s: []const u8) void {
    switch (h.kind) {
        .dialog => dialog.setTitle(txn, @ptrCast(h), s),
        .toast => toast.setText(txn, @ptrCast(h), s),
        .split_pane => split.setLabel(txn, @ptrCast(h), s),
        .tabs => tabs.setLabel(txn, @ptrCast(h), s),
        else => _ = c.siv_set_semantics(txn, node, &.{ .label = s.ptr, .label_len = s.len }),
    }
}

pub export fn siv_widget_set_disabled(txn: Txn, node: Node, disabled: bool) siv.Result {
    const h = header(node) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    h.disabled = disabled;
    if (disabled) {
        h.hover = false;
        h.pressed = false;
    }
    refresh(txn, h);
    return c.siv_txn_status(txn);
}

/// Shows a widget's state again after its header changed.
fn refresh(txn: Txn, h: HeaderPtr) void {
    switch (h.kind) {
        .button, .toggle_button => button.apply(txn, @ptrCast(h)),
        .check_box, .@"switch" => toggle.apply(txn, @ptrCast(h)),
        .radio_group => radio.applyGroup(txn, @ptrCast(h)),
        .radio => radio.apply(txn, @ptrCast(h)),
        .text_field => field.apply(txn, @ptrCast(h)),
        .slider, .spin_button, .progress_bar => range.apply(txn, @ptrCast(h)),
        .menu_button => button.apply(txn, @ptrCast(h)),
        .menu_item => {},
        .tabs => tabs.apply(txn, @ptrCast(h)),
        .split_pane => split.apply(txn, @ptrCast(h)),
        .view => views.apply(txn, @ptrCast(h)),
        .menu, .popover, .menu_row, .dialog, .tab, .toast, .view_row, .view_column => {},
    }
}

pub export fn siv_widget_set_value(txn: Txn, node: Node, value: f64) siv.Result {
    const h = header(node) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    if (!std.math.isFinite(value)) return c.siv_txn_fail(txn, .error_invalid_argument);
    switch (h.kind) {
        .button, .text_field, .radio, .menu, .menu_button, .menu_row, .popover, .dialog, .tab, .toast, .view_row => return c.siv_txn_fail(txn, .error_invalid_argument),
        .view => views.setCursor(txn, @ptrCast(h), value),
        .view_column => views.setColumnValue(txn, @ptrCast(h), value),
        .menu_item => menu.setItemValue(txn, @ptrCast(h), value),
        .tabs => tabs.select(txn, @ptrCast(h), value),
        .split_pane => split.setPosition(txn, @ptrCast(h), value),
        .toggle_button => button.setValue(txn, @ptrCast(h), value),
        .check_box, .@"switch" => toggle.setValue(txn, @ptrCast(h), value),
        .radio_group => radio.select(txn, @ptrCast(h), value),
        .slider, .spin_button, .progress_bar => range.setValue(txn, @ptrCast(h), value),
    }
    return c.siv_txn_status(txn);
}

pub export fn siv_widget_get_value(node: Node, value: ?*f64) siv.Result {
    const out = value orelse return .error_invalid_argument;
    const h = header(node) orelse {
        // Not a widget: say whether the handle was valid at all.
        var w: siv.Window = .null;
        const r = c.siv_node_get_window(node, &w);
        return if (r != .ok) r else .error_invalid_argument;
    };
    out.* = switch (h.kind) {
        .button, .text_field, .radio, .menu, .menu_button, .menu_row, .popover, .dialog, .tab, .toast, .view_row => return .error_invalid_argument,
        .view => views.value(@ptrCast(h)),
        .view_column => views.columnValue(@ptrCast(h)),
        .menu_item => menu.itemValue(@ptrCast(h)),
        .tabs => @floatFromInt(@as(*tabs.Tabs, @ptrCast(h)).selected),
        .split_pane => @as(*split.Split, @ptrCast(h)).position,
        .toggle_button => button.value(@ptrCast(h)),
        .check_box, .@"switch" => toggle.value(@ptrCast(h)),
        .radio_group => @as(*radio.Group, @ptrCast(h)).selectedValue(),
        .slider, .spin_button, .progress_bar => @as(*range.Range, @ptrCast(h)).value,
    };
    return .ok;
}

pub export fn siv_widget_set_range(txn: Txn, node: Node, min: f64, max: f64, step: f64) siv.Result {
    const r = stateOf(range.Range, node, &.{ .slider, .spin_button, .progress_bar }) orelse return c.siv_txn_fail(txn, .error_invalid_argument);
    if (!std.math.isFinite(min) or !std.math.isFinite(max) or !std.math.isFinite(step) or step < 0 or min > max)
        return c.siv_txn_fail(txn, .error_invalid_argument);
    range.setRange(txn, r, min, max, step);
    return c.siv_txn_status(txn);
}

pub export fn siv_widget_get_part(node: Node, part: siv.WidgetPart, index: u32, result: ?*Node) siv.Result {
    const out = result orelse return .error_invalid_argument;
    const h = header(node) orelse return .error_invalid_argument;
    const r: Node = switch (part) {
        .content => switch (h.kind) {
            .dialog => @as(*dialog.Dialog, @ptrCast(h)).content,
            .popover => @as(*menu.Popover, @ptrCast(h)).content,
            else => .null,
        },
        .actions => if (h.kind == .dialog) @as(*dialog.Dialog, @ptrCast(h)).actions else .null,
        .tab, .panel => if (h.kind == .tabs) tabs.part(@ptrCast(h), part == .tab, index) else .null,
        .start => if (h.kind == .split_pane) @as(*split.Split, @ptrCast(h)).start else .null,
        .end => if (h.kind == .split_pane) @as(*split.Split, @ptrCast(h)).end else .null,
        .menu => if (h.kind == .menu_button) @as(*button.Button, @ptrCast(h)).menu else .null,
        else => return .error_unsupported,
    };
    if (r == .null) return .error_invalid_argument;
    out.* = r;
    return .ok;
}
