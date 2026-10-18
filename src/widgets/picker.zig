//! What the pickers (D41) share: the locale's dates and times through the
//! public API (D21), a chevron button, civil date arithmetic, and the
//! compact form, a button showing the value that opens the picker in a
//! popover (D22).
//!
//! The compact form keeps the value itself and builds the inline picker
//! in a popover each time it opens, with siv_popover_create, so it is a
//! popover as an application would make one: the inline picker's
//! `change` updates the button and is reported on it; a chosen date or
//! emoji, or the picker's `activate` (Enter), closes the popover, and
//! focus returns to the button.

const std = @import("std");
const w = @import("widgets.zig");
const button = @import("button.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub fn appOf(node: Node) siv.App {
    return w.appOf(w.windowOf(node));
}

pub fn formatDate(app: siv.App, date: i32, style: siv.DateStyle, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_app_format_date(app, date, style, buf.ptr, buf.len, &len) != .ok) return "";
    return buf[0..@min(len, buf.len)];
}

pub fn formatTime(app: siv.App, seconds: u32, style: siv.TimeStyle, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_app_format_time(app, seconds, style, buf.ptr, buf.len, &len) != .ok) return "";
    return buf[0..@min(len, buf.len)];
}

pub fn localeInfo(app: siv.App) siv.LocaleInfo {
    var info: siv.LocaleInfo = .{ .first_weekday = 0, .hour_cycle = .h23, .flags = .{}, .time_separator = ':' };
    _ = c.siv_app_get_locale_info(app, &info);
    return info;
}

// Civil dates -------------------------------------------------------------------

pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,
};

/// Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
pub fn civil(n: i64) Date {
    const z = n + 719468;
    const era = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = @intCast(@as(i64, @intCast(yoe)) + era * 400 + @intFromBool(m <= 2)), .month = m, .day = d };
}

/// A civil date to days since 1970-01-01; months past December carry
/// into the next year, and day 0 is the last of the month before.
pub fn days(year: i64, month: i64, day: i64) i64 {
    var y = year + @divFloor(month - 1, 12);
    const m = @mod(month - 1, 12) + 1;
    y -= @intFromBool(m <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + @divFloor(153 * mp + 2, 5);
    return era * 146097 + doe - 719468 + day - 1;
}

/// 0 is Sunday.
pub fn weekday(d: i64) u3 {
    return @intCast(@mod(d + 4, 7));
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return @intCast(days(year, @as(i64, month) + 1, 1) - days(year, month, 1));
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn time(t: ?*i64) i64;
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;

/// Today's date in the local time zone.
pub fn today() i32 {
    const now = time(null);
    var tm: Tm = undefined;
    if (localtime_r(&now, &tm) == null) return @intCast(@divFloor(now, 86400));
    return @intCast(days(@as(i64, tm.year) + 1900, @as(i64, tm.mon) + 1, tm.mday));
}

// Chevron buttons ---------------------------------------------------------------

/// A flat square button drawing a chevron toward the start or end edge
/// (mirrored in right-to-left layouts), named for assistive technology.
pub const Chevron = extern struct {
    hdr: w.Header,
    root: Node,
    canvas: Node,
    /// Points toward the end edge.
    forward: bool,
};

pub fn chevron(txn: Txn, parent: Node, forward: bool, name: []const u8, func: siv.EventFn, ud: ?*anyopaque) Node {
    const root = c.siv_flex(txn, parent, &.{ .axis = .row, .justify = .center, .align_items = .center });
    if (root == .null) return .null;
    const st = w.create(Chevron, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .chevron }, .root = root, .canvas = .null, .forward = forward };
    st.canvas = c.siv_canvas(txn, root, &.{ .user_data = st, .draw = drawChevron, .width = 16, .height = 16 });
    c.siv_set_default_layout(txn, root, &.{ .width = w.px(tk.control_height), .height = w.px(tk.control_height), .flags = .{ .no_shrink = true } });
    c.siv_set_semantics(txn, root, &.{ .role = .button, .label = name.ptr, .label_len = name.len, .flags = .{ .focusable = true } });
    w.onDefault(txn, root, .pointer, onChevronPointer, st);
    _ = c.siv_on_default(txn, root, .activate, func, null, ud);
    applyChevron(txn, st);
    return root;
}

fn applyChevron(txn: Txn, st: *Chevron) void {
    const h = st.hdr;
    c.siv_set_visual(txn, st.root, &.{ .radius = w.corners(tk.radius), .background_token = if (h.pressed) .control_active else if (h.hover) .control_hover else .none });
    c.siv_invalidate(txn, st.canvas);
}

fn drawChevron(ud: ?*anyopaque, node: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const st: *Chevron = @ptrCast(@alignCast(ud.?));
    const right = st.forward != w.isRtl(node);
    const cx = width / 2;
    const cy = height / 2;
    const d: f32 = if (right) 1 else -1;
    c.siv_draw_move_to(draw, cx - 2 * d, cy - 4);
    c.siv_draw_line_to(draw, cx + 2 * d, cy);
    c.siv_draw_line_to(draw, cx - 2 * d, cy + 4);
    c.siv_draw_stroke(draw, &.{ .width = 1.5, .join = .round, .cap = .round }, &.{ .color = w.color(w.windowOf(node), .control_fg) });
}

fn onChevronPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Chevron = @ptrCast(@alignCast(ud.?));
    if (button.feedback(&st.hdr, ev)) {
        const txn = w.begin(ev.window) orelse return .pass;
        applyChevron(txn, st);
        _ = w.commit(txn);
    }
    return .pass;
}

// Text helpers -------------------------------------------------------------------

/// "label, value" for a name that carries both; either may be empty.
pub fn joinName(buf: []u8, label: []const u8, value: []const u8) []const u8 {
    if (label.len == 0) return value;
    if (value.len == 0) return label;
    return std.fmt.bufPrint(buf, "{s}, {s}", .{ label, value }) catch label;
}

/// ASCII-case-insensitive substring search.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

// The compact form ---------------------------------------------------------------

pub const Compact = extern struct {
    hdr: w.Header,
    /// The picker it opens.
    picker: w.Kind,
    root: Node,
    /// What the button shows: the value as text, and a color's swatch.
    text: Node,
    swatch: Node = .null,
    /// Hidden text nodes: the accessible name, and a font chooser's
    /// preview text.
    name: Node = .null,
    preview: Node = .null,
    flags: siv.PickerFlags,
    value: f64 = 0,
    min: f64 = 0,
    max: f64 = 0,
    step: f64 = 0,
    has_range: bool = false,
    color: siv.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    tone: siv.SkinTone = .none,
    popup: siv.Window = .null,
    /// The inline picker in the open popover.
    inner: Node = .null,
};

pub fn compactOf(node: Node) ?*Compact {
    return w.stateOf(Compact, node, &.{.picker_button});
}

/// Builds the compact form of a picker: `value`, `color`, and `tone` are
/// its starting value, as the inline picker would have it.
pub fn compact(txn: Txn, parent: Node, kind: w.Kind, label: []const u8, flags: siv.PickerFlags, value: f64, col: siv.Color, tone: siv.SkinTone, preview: []const u8) Node {
    const root = c.siv_flex(txn, parent, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    if (root == .null) return .null;
    const st = w.create(Compact, txn, root) orelse return .null;
    var inner_flags = flags;
    inner_flags.compact = false;
    st.* = .{ .hdr = .{ .kind = .picker_button, .disabled = flags.disabled }, .picker = kind, .root = root, .text = .null, .flags = inner_flags, .value = value, .color = col, .tone = tone };
    if (kind == .color_chooser) {
        st.swatch = c.siv_box(txn, root);
        c.siv_set_layout(txn, st.swatch, &.{ .width = w.px(18), .height = w.px(18), .flags = .{ .no_shrink = true } });
    }
    st.text = c.siv_text(txn, root, "", 0);
    c.siv_set_default_layout(txn, root, &.{
        .min_height = tk.control_height,
        .padding = .{ .start = tk.pad_x, .end = tk.pad_x, .top = tk.pad_y, .bottom = tk.pad_y },
    });
    st.name = w.hiddenText(txn, root, label);
    if (kind == .font_chooser) st.preview = w.hiddenText(txn, root, preview);
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .activate, onActivate, st);
    w.onDefault(txn, root, .key, onKey, st);
    w.onDefault(txn, root, .settings, onSettings, st);
    w.setInterface(txn, root, Compact, st, .{ .set_label = setLabel, .set_value = setValue, .get_value = getValue, .set_range = setRange, .apply = apply, .get_part = part });
    apply(txn, st);
    return root;
}

/// The open popover's picker, as the inline picker's parts: none other.
fn part(st: *const Compact, p: siv.WidgetPart, _: u32) Node {
    return if (p == .content and w.windowAlive(st.popup)) st.inner else .null;
}

fn getValue(st: *const Compact) f64 {
    return st.value;
}

fn setValue(txn: Txn, st: *Compact, v: f64) void {
    switch (st.picker) {
        .color_chooser => {
            c.siv_txn_fail(txn, .error_invalid_argument);
            return;
        },
        .emoji_chooser => if (@round(v) < -1 or @round(v) >= @as(f64, @floatFromInt(c.siv_emoji_get_count()))) {
            c.siv_txn_fail(txn, .error_invalid_argument);
            return;
        },
        else => {},
    }
    st.value = if (st.picker == .time_picker) @mod(@round(v), 86400) else @round(v);
    if (st.has_range) st.value = std.math.clamp(st.value, st.min, st.max);
    apply(txn, st);
    if (w.windowAlive(st.popup) and st.inner != .null) syncInner(st);
}

fn setRange(txn: Txn, st: *Compact, min: f64, max: f64, step: f64) void {
    if (st.picker != .date_picker and st.picker != .time_picker) {
        c.siv_txn_fail(txn, .error_invalid_argument);
        return;
    }
    st.min = min;
    st.max = max;
    st.step = step;
    st.has_range = true;
    st.value = std.math.clamp(st.value, min, max);
    apply(txn, st);
}

fn setLabel(txn: Txn, st: *Compact, label: []const u8) void {
    c.siv_set_text(txn, st.name, label.ptr, label.len);
    apply(txn, st);
}

pub fn getColor(st: *const Compact) siv.Color {
    return st.color;
}

pub fn setColor(txn: Txn, st: *Compact, col: siv.Color) void {
    st.color = col;
    apply(txn, st);
    if (w.windowAlive(st.popup) and st.inner != .null) syncInner(st);
}

/// Shows the value on the button.
pub fn apply(txn: Txn, st: *Compact) void {
    const app = appOf(st.root);
    var buf: [256]u8 = undefined;
    var shown: []const u8 = "";
    var family: []const u8 = "";
    switch (st.picker) {
        .date_picker => shown = formatDate(app, @intFromFloat(st.value), .medium, &buf),
        .time_picker => shown = formatTime(app, @intFromFloat(st.value), if (st.flags.seconds) .medium else .short, &buf),
        .color_chooser => shown = hexOf(&buf, st.color, st.flags.alpha),
        .font_chooser => {
            var len: usize = 0;
            if (st.value > 0 and c.siv_app_get_font_family_name(app, @intFromFloat(st.value), &buf, buf.len, &len) == .ok) {
                shown = buf[0..@min(len, buf.len)];
            } else if (c.siv_app_get_default_font(app, &buf, buf.len, &len) == .ok) shown = buf[0..@min(len, buf.len)];
            family = shown;
        },
        .emoji_chooser => {
            var len: usize = 0;
            if (st.value >= 0 and c.siv_emoji_get(@intFromFloat(st.value), st.tone, &buf, buf.len, &len) == .ok) shown = buf[0..@min(len, buf.len)];
        },
        else => {},
    }
    var name_buf: [256]u8 = undefined;
    const label = w.textOf(st.name, &name_buf);
    if (shown.len == 0) shown = label;
    c.siv_set_text(txn, st.text, shown.ptr, shown.len);
    const h = st.hdr;
    c.siv_set_text_style(txn, st.text, &.{
        .family = family.ptr,
        .family_len = family.len,
        .color_token = if (h.disabled) .disabled_fg else .control_fg,
        .size_role = .body,
        .flags = .{ .no_wrap = true },
        // A hexadecimal color reads left to right in right-to-left
        // layouts too; dates and times carry their own marks (CLDR).
        .direction = if (st.picker == .color_chooser) .ltr else .auto,
    });
    if (st.swatch != .null) c.siv_set_visual(txn, st.swatch, &.{
        .background = st.color,
        .radius = w.corners(4),
        .border_width = tk.border,
        .border_token = .border,
    });
    c.siv_set_visual(txn, st.root, &.{
        .radius = w.corners(tk.radius),
        .border_width = tk.border,
        .border_token = .border,
        .background_token = if (h.disabled) .control_bg else if (h.pressed) .control_active else if (h.hover) .control_hover else .control_bg,
    });
    var full: [512]u8 = undefined;
    const name = joinName(&full, label, if (std.mem.eql(u8, shown, label)) "" else shown);
    c.siv_set_semantics(txn, st.root, &.{
        .label = name.ptr,
        .label_len = name.len,
        .role = .button,
        .expanded = if (w.windowAlive(st.popup)) .on else .off,
        .flags = .{ .focusable = !h.disabled, .disabled = h.disabled },
    });
}

fn refresh(st: *Compact) void {
    const txn = w.begin(w.windowOf(st.root)) orelse return;
    apply(txn, st);
    _ = w.commit(txn);
}

/// "#RRGGBB", or "#RRGGBBAA" with alpha.
pub fn hexOf(buf: []u8, col: siv.Color, alpha: bool) []const u8 {
    const b = [4]u8{ byteOf(col.r), byteOf(col.g), byteOf(col.b), byteOf(col.a) };
    if (alpha) return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ b[0], b[1], b[2], b[3] }) catch "";
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ b[0], b[1], b[2] }) catch "";
}

pub fn byteOf(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn onPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Compact = @ptrCast(@alignCast(ud.?));
    if (button.feedback(&st.hdr, ev)) refresh(st);
    return .pass;
}

fn onActivate(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Compact = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .pass;
    open(st);
    return .handled;
}

/// Down and Alt+Down open it too, as a combo box's list.
fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Compact = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled or !ev.flags.pressed or ev.keysym != w.keysym.down) return .pass;
    open(st);
    return .handled;
}

/// A date or time shows in the new language; a font follows the default.
fn onSettings(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Compact = @ptrCast(@alignCast(ud.?));
    if (ev.flags.locale_changed or ev.flags.fonts_changed) refresh(st);
    return .pass;
}

fn open(st: *Compact) void {
    if (w.windowAlive(st.popup)) return;
    var name_buf: [256]u8 = undefined;
    const label = w.textOf(st.name, &name_buf);
    var popup: siv.Window = .null;
    var content: Node = .null;
    if (c.siv_popover_create(st.root, &.{ .label = label.ptr, .label_len = label.len }, &popup, &content) != .ok) return;
    const txn = w.begin(popup) orelse {
        c.siv_window_destroy(popup);
        return;
    };
    const inner = buildInner(txn, content, st, label);
    if (inner != .null) {
        const ud = w.handleData(st.root);
        _ = c.siv_on(txn, inner, .change, onInnerChange, null, ud);
        _ = c.siv_on(txn, inner, .activate, onInnerActivate, null, ud);
        _ = c.siv_on(txn, content, .close, onClose, null, ud);
    }
    if (!w.commit(txn) or inner == .null or c.siv_popup_show(popup) != .ok) {
        c.siv_window_destroy(popup);
        return;
    }
    st.popup = popup;
    st.inner = inner;
    _ = c.siv_node_focus(inner);
    refresh(st);
}

fn buildInner(txn: Txn, content: Node, st: *Compact, label: []const u8) Node {
    const fl = st.flags;
    const node = switch (st.picker) {
        .date_picker => @import("date.zig").siv_date_picker(txn, content, &.{ .label = label.ptr, .label_len = label.len, .flags = fl }),
        .time_picker => @import("time.zig").siv_time_picker(txn, content, &.{ .label = label.ptr, .label_len = label.len, .flags = fl }),
        .color_chooser => @import("color.zig").siv_color_chooser(txn, content, &.{ .label = label.ptr, .label_len = label.len, .flags = fl, .color = st.color }),
        .font_chooser => blk: {
            var buf: [1024]u8 = undefined;
            const preview = w.textOf(st.preview, &buf);
            break :blk @import("font.zig").siv_font_chooser(txn, content, &.{ .label = label.ptr, .label_len = label.len, .flags = fl, .preview = preview.ptr, .preview_len = preview.len });
        },
        .emoji_chooser => @import("emoji.zig").siv_emoji_chooser(txn, content, &.{ .label = label.ptr, .label_len = label.len, .flags = fl, .tone = st.tone }),
        else => Node.null,
    };
    if (node == .null) return .null;
    if (st.has_range) c.siv_widget_set_range(txn, node, st.min, st.max, st.step);
    switch (st.picker) {
        .color_chooser => {},
        .emoji_chooser => if (st.value >= 0) c.siv_widget_set_value(txn, node, st.value),
        .font_chooser => if (st.value > 0) c.siv_widget_set_value(txn, node, st.value),
        else => c.siv_widget_set_value(txn, node, st.value),
    }
    return node;
}

/// The application set the value while the popover is open.
fn syncInner(st: *Compact) void {
    const txn = w.begin(st.popup) orelse return;
    switch (st.picker) {
        .color_chooser => c.siv_color_chooser_set_color(txn, st.inner, st.color),
        .emoji_chooser, .font_chooser => if (st.value >= 0) c.siv_widget_set_value(txn, st.inner, st.value),
        else => c.siv_widget_set_value(txn, st.inner, st.value),
    }
    _ = w.commit(txn);
}

fn close(st: *Compact) void {
    if (w.windowAlive(st.popup)) c.siv_window_destroy(st.popup);
    st.popup = .null;
    st.inner = .null;
    refresh(st);
    _ = c.siv_node_focus(st.root);
}

fn onInnerChange(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st = compactOf(w.dataHandle(ud)) orelse return .pass;
    switch (st.picker) {
        .color_chooser => _ = c.siv_color_chooser_get_color(node, &st.color),
        .emoji_chooser => {
            st.value = ev.value;
            st.tone = @enumFromInt(@as(i32, @intCast(ev.index)));
        },
        else => st.value = ev.value,
    }
    const root = st.root;
    const ends = st.picker == .date_picker or st.picker == .emoji_chooser;
    if (ends) close(st) else refresh(st);
    var handled = false;
    _ = c.siv_node_emit(root, &.{ .type = .change, .value = ev.value, .index = ev.index }, &handled);
    return .handled;
}

fn onInnerActivate(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st = compactOf(w.dataHandle(ud)) orelse return .pass;
    close(st);
    return .handled;
}

/// Escape, or a click outside: the popover goes, and focus comes back.
fn onClose(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st = compactOf(w.dataHandle(ud)) orelse return .pass;
    close(st);
    return .handled;
}
