//! Time pickers (D41): a field for the hour, the minutes, optional
//! seconds, and a day period where the locale counts 12 hours, in the
//! order, digits, and separator of the locale's short time pattern (D21):
//! "10:30 PM", "22:30", "오후 10:30" (period first). The numbers sit in a
//! left-to-right group, since "10:30" reads that way in right-to-left
//! layouts too, and the period on whichever side the pattern puts it.
//!
//! Each field is a spin button (one Tab stop each, as WAI-ARIA's spin
//! buttons are): Up and Down step it, wrapping (the hour by an hour, the
//! minutes by the step's minutes), Home and End go to its ends, digits
//! type it (two within a second make one number; a digit that cannot
//! start a longer number moves on to the next field), A and P or the
//! period's first letter set the period, and Left and Right move between
//! fields. Enter reports `activate`, which closes the compact form's
//! popover. Fields expose their number as the value and what they show as
//! the value text, so the period reads "PM", not 1.

const std = @import("std");
const w = @import("widgets.zig");
const picker = @import("picker.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

const Which = enum(u8) { hour, minute, second, period };
const field_names = [_][]const u8{ "Hour", "Minutes", "Seconds", "AM/PM" };

pub const TimePicker = extern struct {
    hdr: w.Header,
    root: Node,
    name: Node,
    /// The row of fields, built again when the language changes.
    body: Node,
    /// Indexed by Which; .null when not shown.
    fields: [4]Node,
    texts: [4]Node,
    /// In order of the row, for Left and Right.
    order: [4]Which = undefined,
    count: u8 = 0,
    value: u32 = 0,
    min: f64 = 0,
    max: f64 = 86399,
    step: f64 = 60,
    cycle: siv.HourCycle = .h23,
    /// What was typed into the field `typed_field` since `typed_at`.
    typed: u32 = 0,
    typed_digits: u8 = 0,
    typed_field: u8 = 0,
    typed_at: u32 = 0,
    focused: i8 = -1,
    seconds: bool = false,
};

const Field = extern struct {
    hdr: w.Header,
    picker: Node,
    which: Which,
};

pub export fn siv_time_picker(txn: Txn, parent: Node, desc: ?*const siv.TimePickerDesc) Node {
    const d = w.readDesc(siv.TimePickerDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 0xf) != 0 or d.reserved0 != 0) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    if (d.flags.compact) return picker.compact(txn, parent, .time_picker, label, d.flags, 0, .{ .r = 0, .g = 0, .b = 0, .a = 1 }, .none, "");

    const root = c.siv_flex(txn, parent, &.{ .axis = .row, .align_items = .center, .gap = 4 });
    if (root == .null) return .null;
    const st = w.create(TimePicker, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .time_picker, .disabled = d.flags.disabled }, .root = root, .name = .null, .body = .null, .fields = @splat(.null), .texts = @splat(.null), .step = if (d.flags.seconds) 1 else 60, .seconds = d.flags.seconds };
    c.siv_set_default_layout(txn, root, &.{ .min_height = tk.control_height, .padding = .{ .start = 6, .end = 6, .top = 2, .bottom = 2 } });
    st.name = w.hiddenText(txn, root, label);
    build(txn, st);
    w.onDefault(txn, root, .key, onKey, st);
    w.onDefault(txn, root, .settings, onSettings, st);
    w.setInterface(txn, root, TimePicker, st, .{ .set_label = setLabel, .set_value = setValue, .get_value = getValue, .set_range = setRange, .apply = apply, .focus = focusFirst });
    apply(txn, st);
    return root;
}

/// The fields in the locale's order, replacing any it had.
fn build(txn: Txn, st: *TimePicker) void {
    if (st.body != .null) c.siv_remove(txn, st.body);
    st.fields = @splat(.null);
    st.texts = @splat(.null);
    st.count = 0;
    st.focused = -1;
    st.body = c.siv_flex(txn, st.root, &.{ .axis = .row, .align_items = .center, .gap = 4 });
    const info = picker.localeInfo(picker.appOf(st.root));
    st.cycle = info.hour_cycle;
    const twelve = info.hour_cycle == .h12 or info.hour_cycle == .h11;
    if (twelve and info.flags.period_first) addField(txn, st, st.body, .period);
    const numbers = c.siv_flex(txn, st.body, &.{ .axis = .row, .align_items = .center });
    c.siv_set_layout(txn, numbers, &.{ .direction = .ltr });
    var sep_buf: [4]u8 = undefined;
    const sep_len = std.unicode.utf8Encode(@intCast(@min(info.time_separator, 0x10ffff)), &sep_buf) catch blk: {
        sep_buf[0] = ':';
        break :blk 1;
    };
    const sep = sep_buf[0..sep_len];
    addField(txn, st, numbers, .hour);
    addSeparator(txn, numbers, sep);
    addField(txn, st, numbers, .minute);
    if (st.seconds) {
        addSeparator(txn, numbers, sep);
        addField(txn, st, numbers, .second);
    }
    if (twelve and !info.flags.period_first) addField(txn, st, st.body, .period);
}

/// The language changed: its clock may have other fields.
fn onSettings(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *TimePicker = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.locale_changed) return .pass;
    const txn = w.begin(w.windowOf(st.root)) orelse return .pass;
    build(txn, st);
    apply(txn, st);
    _ = w.commit(txn);
    return .pass;
}

fn addField(txn: Txn, st: *TimePicker, parent: Node, which: Which) void {
    const node = c.siv_flex(txn, parent, &.{ .axis = .row, .justify = .center, .align_items = .center });
    c.siv_set_layout(txn, node, &.{ .min_width = 26, .padding = .{ .start = 3, .end = 3, .top = 2, .bottom = 2 } });
    const i = @intFromEnum(which);
    st.fields[i] = node;
    st.texts[i] = c.siv_text(txn, node, "", 0);
    st.order[st.count] = which;
    st.count += 1;
    const f = w.create(Field, txn, node) orelse return;
    f.* = .{ .hdr = .{ .kind = .time_field }, .picker = st.root, .which = which };
    w.onDefault(txn, node, .focus, onFieldFocus, f);
    w.onDefault(txn, node, .set_value, onFieldSetValue, f);
}

fn addSeparator(txn: Txn, parent: Node, sep: []const u8) void {
    const t = c.siv_text(txn, parent, sep.ptr, sep.len);
    c.siv_set_text_style(txn, t, &w.textStyle(.muted_fg, .body));
    c.siv_set_semantics(txn, t, &.{ .role = .none });
}

fn stateOf(node: Node) ?*TimePicker {
    return w.stateOf(TimePicker, node, &.{.time_picker});
}

fn getValue(st: *const TimePicker) f64 {
    return @floatFromInt(st.value);
}

/// Wrapped into a day, clamped to the range, and snapped to its step.
fn normalized(st: *const TimePicker, v: f64) u32 {
    const x = w.snap(@mod(@round(v), 86400), st.min, st.max, st.step);
    return @intFromFloat(std.math.clamp(@round(x), 0, 86399));
}

fn setValue(txn: Txn, st: *TimePicker, v: f64) void {
    st.value = normalized(st, v);
    apply(txn, st);
}

fn setRange(txn: Txn, st: *TimePicker, min: f64, max: f64, step: f64) void {
    st.min = std.math.clamp(min, 0, 86399);
    st.max = std.math.clamp(max, st.min, 86399);
    st.step = if (step > 0) step else st.step;
    setValue(txn, st, @floatFromInt(st.value));
}

fn setLabel(txn: Txn, st: *TimePicker, label: []const u8) void {
    c.siv_set_text(txn, st.name, label.ptr, label.len);
    apply(txn, st);
}

fn focusFirst(st: *TimePicker) Node {
    return st.fields[@intFromEnum(st.order[0])];
}

/// The number a field holds, and its range, as the locale counts.
fn fieldValue(st: *const TimePicker, which: Which) struct { now: f64, min: f64, max: f64 } {
    const h = st.value / 3600;
    return switch (which) {
        .hour => switch (st.cycle) {
            .h12 => .{ .now = @floatFromInt(if (h % 12 == 0) 12 else h % 12), .min = 1, .max = 12 },
            .h11 => .{ .now = @floatFromInt(h % 12), .min = 0, .max = 11 },
            .h24 => .{ .now = @floatFromInt(if (h == 0) 24 else h), .min = 1, .max = 24 },
            else => .{ .now = @floatFromInt(h), .min = 0, .max = 23 },
        },
        .minute => .{ .now = @floatFromInt(st.value / 60 % 60), .min = 0, .max = 59 },
        .second => .{ .now = @floatFromInt(st.value % 60), .min = 0, .max = 59 },
        .period => .{ .now = @floatFromInt(@intFromBool(h >= 12)), .min = 0, .max = 1 },
    };
}

fn apply(txn: Txn, st: *TimePicker) void {
    const app = picker.appOf(st.root);
    const h = st.hdr;
    var name_buf: [256]u8 = undefined;
    const label = w.textOf(st.name, &name_buf);
    c.siv_set_semantics(txn, st.root, &.{ .role = .group, .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = h.disabled } });
    c.siv_set_visual(txn, st.root, &.{
        .radius = w.corners(tk.radius),
        .border_width = tk.border,
        .border_token = .border,
        .background_token = if (h.disabled) .control_bg else .view_bg,
    });
    const styles = [_]siv.TimeStyle{ .hour, .minute, .second, .period };
    for (st.fields, st.texts, 0..) |node, text, i| {
        if (node == .null) continue;
        const which: Which = @enumFromInt(i);
        var buf: [64]u8 = undefined;
        const shown = picker.formatTime(app, st.value, styles[i], &buf);
        c.siv_set_text(txn, text, shown.ptr, shown.len);
        const lit = st.focused == @as(i8, @intCast(i)) and !h.disabled;
        c.siv_set_text_style(txn, text, &.{ .color_token = if (h.disabled) .disabled_fg else if (lit) .selection_fg else .view_fg, .size_role = .body, .flags = .{ .no_wrap = true } });
        c.siv_set_visual(txn, node, &.{ .radius = w.corners(4), .background_token = if (lit) .selection_bg else .none });
        const v = fieldValue(st, which);
        c.siv_set_semantics(txn, node, &.{
            .role = .spin_button,
            .label = field_names[i].ptr,
            .label_len = field_names[i].len,
            .value_min = v.min,
            .value_max = v.max,
            .value_now = v.now,
            .value_step = 1,
            .value_text = shown.ptr,
            .value_text_len = shown.len,
            .flags = .{ .focusable = !h.disabled, .disabled = h.disabled, .has_value = true },
        });
    }
}

fn refresh(st: *TimePicker) void {
    const txn = w.begin(w.windowOf(st.root)) orelse return;
    apply(txn, st);
    _ = w.commit(txn);
}

/// The user changed the time: commits it and reports `change`.
fn userSet(st: *TimePicker, seconds: i64) void {
    const nv = normalized(st, @floatFromInt(@mod(seconds, 86400)));
    const changed = nv != st.value;
    st.value = nv;
    refresh(st);
    if (changed) w.emitChange(st.root, @floatFromInt(nv), 0);
}

/// The time with one field stepped by `n`, wrapping within the field.
fn stepped(st: *const TimePicker, which: Which, n: i64) i64 {
    const v: i64 = st.value;
    const h = @divFloor(v, 3600);
    const m = @mod(@divFloor(v, 60), 60);
    const s = @mod(v, 60);
    const minute_step: i64 = if (st.step >= 60) @max(1, @as(i64, @intFromFloat(st.step / 60))) else 1;
    const second_step: i64 = if (st.step < 60 and st.step >= 1) @intFromFloat(st.step) else 1;
    return switch (which) {
        .hour => @mod(h + n, 24) * 3600 + m * 60 + s,
        .minute => h * 3600 + @mod(m + n * minute_step, 60) * 60 + s,
        .second => h * 3600 + m * 60 + @mod(s + n * second_step, 60),
        .period => @mod(v + 43200 * n, 86400),
    };
}

/// The time with a field set to the number the locale shows there.
fn withField(st: *const TimePicker, which: Which, x: i64) i64 {
    const v: i64 = st.value;
    const h = @divFloor(v, 3600);
    const pm = h >= 12;
    return switch (which) {
        .hour => blk: {
            const hour: i64 = switch (st.cycle) {
                .h12 => @mod(x, 12) + @as(i64, if (pm) 12 else 0),
                .h11 => x + @as(i64, if (pm) 12 else 0),
                .h24 => @mod(x, 24),
                else => x,
            };
            break :blk hour * 3600 + @mod(v, 3600);
        },
        .minute => h * 3600 + x * 60 + @mod(v, 60),
        .second => @divFloor(v, 60) * 60 + x,
        .period => if ((x != 0) == pm) v else @mod(v + 43200, 86400),
    };
}

fn fieldAt(st: *const TimePicker, node: Node) ?Which {
    for (st.fields, 0..) |f, i| if (f != .null and f == node) return @enumFromInt(i);
    return null;
}

/// The field next to one on screen, toward the right or the left: the
/// numbers read left to right while a right-to-left layout puts the
/// period on the other side, so neither the row's order nor its
/// mirror is the screen's.
fn nearest(st: *const TimePicker, which: Which, right: bool) ?Node {
    var from: siv.Rect = undefined;
    if (c.siv_node_get_rect(st.fields[@intFromEnum(which)], &from) != .ok) return null;
    var best: ?Node = null;
    var best_d: f32 = std.math.inf(f32);
    for (st.fields) |f| {
        if (f == .null or f == st.fields[@intFromEnum(which)]) continue;
        var r: siv.Rect = undefined;
        if (c.siv_node_get_rect(f, &r) != .ok) continue;
        const d = if (right) r.x - from.x else from.x - r.x;
        if (d > 0 and d < best_d) {
            best_d = d;
            best = f;
        }
    }
    return best;
}

fn positionOf(st: *const TimePicker, which: Which) usize {
    for (st.order[0..st.count], 0..) |o, i| if (o == which) return i;
    return 0;
}

/// A typed digit's value: ASCII, Arabic-Indic, or extended Arabic-Indic.
fn digitOf(text: []const u8) ?u8 {
    const cp = std.unicode.utf8Decode(text[0 .. std.unicode.utf8ByteSequenceLength(text[0]) catch return null]) catch return null;
    return switch (cp) {
        '0'...'9' => @intCast(cp - '0'),
        0x660...0x669 => @intCast(cp - 0x660),
        0x6f0...0x6f9 => @intCast(cp - 0x6f0),
        else => null,
    };
}

fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *TimePicker = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled or !ev.flags.pressed) return .pass;
    const m = ev.modifiers;
    if (m.ctrl or m.alt or m.super) return .pass;
    const k = w.keysym;
    if (ev.keysym == k.@"return" or ev.keysym == k.kp_enter) {
        var handled = false;
        _ = c.siv_node_emit(st.root, &.{ .type = .activate }, &handled);
        return .handled;
    }
    const which = fieldAt(st, ev.target) orelse return .pass;
    const v = fieldValue(st, which);
    switch (ev.keysym) {
        k.up => userSet(st, stepped(st, which, 1)),
        k.down => userSet(st, stepped(st, which, -1)),
        k.home => userSet(st, withField(st, which, @intFromFloat(v.min))),
        k.end => userSet(st, withField(st, which, @intFromFloat(v.max))),
        k.left, k.right => if (nearest(st, which, ev.keysym == k.right)) |to| {
            _ = c.siv_node_focus(to);
        },
        else => return typed(st, which, ev),
    }
    return .handled;
}

/// Digits, and the period's letters.
fn typed(st: *TimePicker, which: Which, ev: *const siv.Event) siv.EventResult {
    const text = w.str(ev.text, ev.text_len) orelse return .pass;
    if (text.len == 0) return .pass;
    if (which == .period) {
        var buf: [32]u8 = undefined;
        const app = picker.appOf(st.root);
        const am = picker.formatTime(app, 0, .period, &buf);
        const a0 = if (am.len > 0) std.ascii.toLower(am[0]) else 'a';
        var buf2: [32]u8 = undefined;
        const pm = picker.formatTime(app, 43200, .period, &buf2);
        const p0 = if (pm.len > 0) std.ascii.toLower(pm[0]) else 'p';
        const ch = std.ascii.toLower(text[0]);
        if (ch == 'a' or (ch == a0 and a0 != p0)) userSet(st, withField(st, .period, 0)) else if (ch == 'p' or (ch == p0 and a0 != p0)) userSet(st, withField(st, .period, 1)) else return .pass;
        return .handled;
    }
    const d = digitOf(text) orelse return .pass;
    const v = fieldValue(st, which);
    const fresh = st.typed_digits == 0 or st.typed_field != @intFromEnum(which) or ev.time -% st.typed_at > 1000;
    var x: u32 = if (fresh) d else st.typed * 10 + d;
    if (x > @as(u32, @intFromFloat(v.max))) x = d;
    st.typed = x;
    st.typed_digits = if (fresh) 1 else st.typed_digits + 1;
    st.typed_field = @intFromEnum(which);
    st.typed_at = ev.time;
    if (x >= @as(u32, @intFromFloat(v.min))) userSet(st, withField(st, which, x));
    // Done once no further digit could fit: on to the next field.
    if (st.typed_digits >= 2 or x * 10 > @as(u32, @intFromFloat(v.max))) {
        st.typed_digits = 0;
        const pos = positionOf(st, which);
        if (pos + 1 < st.count) _ = c.siv_node_focus(st.fields[@intFromEnum(st.order[pos + 1])]);
    }
    return .handled;
}

fn onFieldFocus(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const f: *Field = @ptrCast(@alignCast(ud.?));
    const st = stateOf(f.picker) orelse return .pass;
    const i: i8 = @intCast(@intFromEnum(f.which));
    if (ev.flags.gained) {
        st.focused = i;
        st.typed_digits = 0;
    } else if (st.focused == i) st.focused = -1;
    refresh(st);
    return .pass;
}

/// Assistive technology sets a field's number.
fn onFieldSetValue(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const f: *Field = @ptrCast(@alignCast(ud.?));
    const st = stateOf(f.picker) orelse return .pass;
    if (st.hdr.disabled) return .pass;
    const v = fieldValue(st, f.which);
    userSet(st, withField(st, f.which, @intFromFloat(std.math.clamp(@round(ev.value), v.min, v.max))));
    return .handled;
}
