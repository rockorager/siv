//! Date pickers (D41): a month's calendar in the application's locale
//! (D21), WAI-ARIA's date grid. A heading with the month and year between
//! previous- and next-month buttons, then a table: a row of weekday
//! column headers from the locale's first day, and six rows of seven day
//! cells, so the size never changes from month to month. Days of the
//! months around the shown one fill the first and last rows, dimmed.
//!
//! The cursor is the day that has the focus (one Tab stop, roving): the
//! arrows move it by a day (Left and Right mirrored in right-to-left
//! layouts, which mirror the columns by layout alone) or a week, Home and
//! End to the start and end of its week, Page Up and Page Down by a month
//! and with Shift by a year, and the calendar shows the cursor's month.
//! A click, Enter, or Space on a day chooses it: the value, reported with
//! `change`. Days outside the range (siv_widget_set_range) are disabled
//! and the cursor stays inside it.
//!
//! Cells are named by their full date ("Sunday, October 18, 2026"), the
//! column headers by the weekday's name, so a screen reader announces
//! what a sighted user reads off the grid; the heading is a polite live
//! region, as in WAI-ARIA's example.

const std = @import("std");
const w = @import("widgets.zig");
const picker = @import("picker.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

const cell_w: f32 = 36;
const cell_h: f32 = 32;

pub const DatePicker = extern struct {
    hdr: w.Header,
    root: Node,
    title: Node,
    prev: Node,
    next: Node,
    table: Node,
    /// A hidden text node holding the accessible name.
    name: Node,
    heads: [7]Node,
    cells: [42]Node,
    texts: [42]Node,
    value: i32,
    cursor: i32,
    /// The date of the first cell.
    first: i32 = 0,
    today: i32,
    min: f64 = -std.math.inf(f64),
    max: f64 = std.math.inf(f64),
    first_weekday: u8 = 0,
    hover: i8 = -1,
};

/// A day cell's state: its place in the grid.
const Cell = extern struct {
    hdr: w.Header,
    picker: Node,
    index: u8,
};

pub export fn siv_date_picker(txn: Txn, parent: Node, desc: ?*const siv.DatePickerDesc) Node {
    const d = w.readDesc(siv.DatePickerDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 0xf) != 0 or d.reserved0 != 0) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const today = picker.today();
    if (d.flags.compact) return picker.compact(txn, parent, .date_picker, label, d.flags, @floatFromInt(today), .{ .r = 0, .g = 0, .b = 0, .a = 1 }, .none, "");

    const root = c.siv_flex(txn, parent, &.{ .axis = .column, .gap = 4 });
    if (root == .null) return .null;
    const st = w.create(DatePicker, txn, root) orelse return .null;
    st.* = .{
        .hdr = .{ .kind = .date_picker, .disabled = d.flags.disabled },
        .root = root,
        .title = .null,
        .prev = .null,
        .next = .null,
        .table = .null,
        .name = .null,
        .heads = @splat(.null),
        .cells = @splat(.null),
        .texts = @splat(.null),
        .value = today,
        .cursor = today,
        .today = today,
    };
    const header = c.siv_flex(txn, root, &.{ .axis = .row, .align_items = .center });
    st.prev = picker.chevron(txn, header, false, "Previous month", onPrev, st);
    st.title = c.siv_text(txn, header, "", 0);
    c.siv_set_layout(txn, st.title, &.{ .grow = 1 });
    st.next = picker.chevron(txn, header, true, "Next month", onNext, st);
    st.table = c.siv_flex(txn, root, &.{ .axis = .column, .gap = 2 });
    const head_row = c.siv_flex(txn, st.table, &.{ .axis = .row });
    c.siv_set_semantics(txn, head_row, &.{ .role = .row });
    for (&st.heads) |*h| {
        h.* = c.siv_text(txn, head_row, "", 0);
        c.siv_set_layout(txn, h.*, &.{ .width = w.px(cell_w), .padding = .{ .top = 4, .bottom = 4 } });
    }
    for (0..6) |r| {
        const row = c.siv_flex(txn, st.table, &.{ .axis = .row });
        c.siv_set_semantics(txn, row, &.{ .role = .row });
        for (0..7) |col| {
            const i = r * 7 + col;
            const cell = c.siv_flex(txn, row, &.{ .axis = .row, .justify = .center, .align_items = .center });
            c.siv_set_layout(txn, cell, &.{ .width = w.px(cell_w), .height = w.px(cell_h), .flags = .{ .no_shrink = true } });
            st.cells[i] = cell;
            st.texts[i] = c.siv_text(txn, cell, "", 0);
            const cs = w.create(Cell, txn, cell) orelse return .null;
            cs.* = .{ .hdr = .{ .kind = .date_cell }, .picker = root, .index = @intCast(i) };
            w.onDefault(txn, cell, .pointer, onCellPointer, cs);
            w.onDefault(txn, cell, .activate, onCellActivate, cs);
        }
    }
    st.name = w.hiddenText(txn, root, label);
    w.onDefault(txn, root, .key, onKey, st);
    w.onDefault(txn, root, .settings, onSettings, st);
    w.setInterface(txn, root, DatePicker, st, .{ .set_label = setLabel, .set_value = setValue, .get_value = getValue, .set_range = setRange, .apply = apply, .focus = focusCursor });
    apply(txn, st);
    return root;
}

fn stateOf(node: Node) ?*DatePicker {
    return w.stateOf(DatePicker, node, &.{.date_picker});
}

fn getValue(st: *const DatePicker) f64 {
    return @floatFromInt(st.value);
}

fn clampDay(st: *const DatePicker, v: f64) i32 {
    const x = std.math.clamp(@round(v), @max(st.min, -2e8), @min(st.max, 2e8));
    return @intFromFloat(x);
}

fn setValue(txn: Txn, st: *DatePicker, v: f64) void {
    st.value = clampDay(st, v);
    st.cursor = st.value;
    apply(txn, st);
}

fn setRange(txn: Txn, st: *DatePicker, min: f64, max: f64, _: f64) void {
    st.min = @ceil(min);
    st.max = @floor(max);
    if (st.min > st.max) st.max = st.min;
    st.value = clampDay(st, @floatFromInt(st.value));
    st.cursor = clampDay(st, @floatFromInt(st.cursor));
    apply(txn, st);
}

fn setLabel(txn: Txn, st: *DatePicker, label: []const u8) void {
    c.siv_set_text(txn, st.name, label.ptr, label.len);
    apply(txn, st);
}

fn focusCursor(st: *DatePicker) Node {
    const i = st.cursor - st.first;
    return if (i >= 0 and i < 42) st.cells[@intCast(i)] else st.root;
}

fn inRange(st: *const DatePicker, day: i32) bool {
    const x: f64 = @floatFromInt(day);
    return x >= st.min and x <= st.max;
}

/// Shows the cursor's month: heading, weekday headers, and every cell.
fn apply(txn: Txn, st: *DatePicker) void {
    const app = picker.appOf(st.root);
    st.first_weekday = @intCast(picker.localeInfo(app).first_weekday % 7);
    const cur = picker.civil(st.cursor);
    const month_start: i32 = @intCast(picker.days(cur.year, cur.month, 1));
    const lead = @mod(@as(i32, picker.weekday(month_start)) - st.first_weekday, 7);
    st.first = month_start - lead;
    const h = st.hdr;
    var buf: [256]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    const label = w.textOf(st.name, &name_buf);
    c.siv_set_semantics(txn, st.root, &.{ .role = .group, .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = h.disabled } });

    const title = picker.formatDate(app, month_start, .month_year, &buf);
    c.siv_set_text(txn, st.title, title.ptr, title.len);
    c.siv_set_text_style(txn, st.title, &.{ .color_token = if (h.disabled) .disabled_fg else .window_fg, .size_role = .body, .weight = .semibold, .@"align" = .center, .flags = .{ .no_wrap = true } });
    c.siv_set_semantics(txn, st.title, &.{ .role = .heading, .level = 2, .flags = .{ .live_polite = true } });
    c.siv_set_semantics(txn, st.table, &.{ .role = .table, .label = title.ptr, .label_len = title.len });
    for ([_]Node{ st.prev, st.next }, [_][]const u8{ "Previous month", "Next month" }) |b, n|
        c.siv_set_semantics(txn, b, &.{ .role = .button, .label = n.ptr, .label_len = n.len, .flags = .{ .focusable = !h.disabled, .disabled = h.disabled } });

    // 1970-01-04 was a Sunday. Short names where they all fit their
    // column, else the narrow ones (Arabic's short names are its
    // abbreviated ones).
    var head_style: siv.DateStyle = .weekday_short;
    for (0..7) |wd| {
        const short = picker.formatDate(app, 3 + @as(i32, @intCast(wd)), .weekday_short, &buf);
        var m: siv.TextMetrics = undefined;
        if (c.siv_app_measure_text(app, short.ptr, short.len, 0, &.{ .size_role = .caption }, &m) == .ok and m.width > cell_w - 4) head_style = .weekday_narrow;
    }
    for (st.heads, 0..) |head, col| {
        const day: i32 = 3 + @as(i32, @intCast((col + st.first_weekday) % 7));
        const short = picker.formatDate(app, day, head_style, &buf);
        c.siv_set_text(txn, head, short.ptr, short.len);
        c.siv_set_text_style(txn, head, &.{ .color_token = if (h.disabled) .disabled_fg else .muted_fg, .size_role = .caption, .@"align" = .center, .flags = .{ .no_wrap = true } });
        const full = picker.formatDate(app, day, .weekday, &name_buf);
        c.siv_set_semantics(txn, head, &.{ .role = .column_header, .label = full.ptr, .label_len = full.len, .column = @intCast(col + 1) });
    }
    for (st.cells, st.texts, 0..) |cell, text, i| {
        const day = st.first + @as(i32, @intCast(i));
        const ok = inRange(st, day) and !h.disabled;
        const selected = day == st.value;
        const outside = picker.civil(day).month != cur.month;
        const n = picker.formatDate(app, day, .day, &buf);
        c.siv_set_text(txn, text, n.ptr, n.len);
        const fg: siv.ColorToken = if (!ok) .disabled_fg else if (selected) .accent_fg else if (outside) .muted_fg else .window_fg;
        c.siv_set_text_style(txn, text, &.{ .color_token = fg, .size_role = .body, .weight = if (day == st.today) .semibold else .regular, .flags = .{ .no_wrap = true } });
        const hover = st.hover == @as(i8, @intCast(i)) and ok;
        c.siv_set_visual(txn, cell, &.{
            .radius = w.corners(tk.radius),
            .background_token = if (selected) (if (ok) .accent else .control_active) else if (hover) .control_hover else .none,
            .border_width = if (day == st.today and !selected) tk.border else 0,
            .border_token = .accent,
        });
        const full = picker.formatDate(app, day, .full, &name_buf);
        c.siv_set_semantics(txn, cell, &.{
            .role = .cell,
            .label = full.ptr,
            .label_len = full.len,
            .selected = if (selected) .on else .off,
            .column = @intCast(i % 7 + 1),
            .flags = .{ .focusable = day == st.cursor and ok, .disabled = !inRange(st, day) },
        });
    }
}

fn refresh(st: *DatePicker) bool {
    const txn = w.begin(w.windowOf(st.root)) orelse return false;
    apply(txn, st);
    return w.commit(txn);
}

/// Moves the cursor (kept in range) and the focus with it.
fn moveTo(st: *DatePicker, day: i64, focus: bool) void {
    st.cursor = clampDay(st, @floatFromInt(std.math.clamp(day, -200_000_000, 200_000_000)));
    if (!refresh(st)) return;
    if (focus) _ = c.siv_node_focus(focusCursor(st));
}

/// The cursor's day in the month `months` away, clamped to its length.
fn addMonths(day: i32, months: i32) i64 {
    const d = picker.civil(day);
    const total = @as(i64, d.year) * 12 + d.month - 1 + months;
    const y: i32 = @intCast(@divFloor(total, 12));
    const m: u8 = @intCast(@mod(total, 12) + 1);
    return picker.days(y, m, @min(d.day, picker.daysInMonth(y, m)));
}

fn choose(st: *DatePicker, day: i32) void {
    if (!inRange(st, day)) return;
    st.value = day;
    st.cursor = day;
    const root = st.root;
    if (!refresh(st)) return;
    _ = c.siv_node_focus(focusCursor(st));
    w.emitChange(root, @floatFromInt(day), 0);
}

fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *DatePicker = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled or !ev.flags.pressed) return .pass;
    const m = ev.modifiers;
    if (m.ctrl or m.alt or m.super) return .pass;
    // Only keys aimed at a day: the month buttons keep theirs.
    const cell = w.stateOf(Cell, ev.target, &.{.date_cell}) orelse return .pass;
    _ = cell;
    const k = w.keysym;
    const cur: i64 = st.cursor;
    const back: i64 = @mod(@as(i64, picker.weekday(cur)) - st.first_weekday, 7);
    const to: i64 = switch (ev.keysym) {
        k.left, k.right => cur + w.arrowDirection(ev.keysym, w.isRtl(st.root)),
        k.up => cur - 7,
        k.down => cur + 7,
        k.home => cur - back,
        k.end => cur + 6 - back,
        k.page_up => addMonths(st.cursor, if (m.shift) -12 else -1),
        k.page_down => addMonths(st.cursor, if (m.shift) 12 else 1),
        else => return .pass,
    };
    moveTo(st, to, true);
    return .handled;
}

/// The language changed: names, digits, and the first weekday with it.
fn onSettings(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *DatePicker = @ptrCast(@alignCast(ud.?));
    if (ev.flags.locale_changed) _ = refresh(st);
    return .pass;
}

fn onPrev(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *DatePicker = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .pass;
    moveTo(st, addMonths(st.cursor, -1), false);
    return .handled;
}

fn onNext(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *DatePicker = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .pass;
    moveTo(st, addMonths(st.cursor, 1), false);
    return .handled;
}

fn onCellActivate(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const cs: *Cell = @ptrCast(@alignCast(ud.?));
    const st = stateOf(cs.picker) orelse return .pass;
    if (st.hdr.disabled) return .handled;
    choose(st, st.first + cs.index);
    return .handled;
}

fn onCellPointer(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const cs: *Cell = @ptrCast(@alignCast(ud.?));
    const st = stateOf(cs.picker) orelse return .pass;
    const hover: i8 = switch (ev.phase) {
        .enter => @intCast(cs.index),
        .leave => if (st.hover == @as(i8, @intCast(cs.index))) -1 else st.hover,
        else => return .pass,
    };
    if (hover == st.hover) return .pass;
    st.hover = hover;
    _ = refresh(st);
    return .pass;
}
