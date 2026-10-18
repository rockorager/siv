//! Color choosers (D41): a saturation and value area over a hue strip, an
//! optional opacity strip, a swatch of the color, a hexadecimal field,
//! and a button that picks a color from the screen through the
//! Screenshot portal (siv_pick_color, D19).
//!
//! Colors are sRGB with straight alpha (siv_color, D11). The area and the
//! strips are images of sRGB pixels computed here, so each shows exactly
//! the colors it chooses: siv composites them in linear light and writes
//! the same sRGB values back, where a gradient paint would interpolate in
//! linear light and drift from HSV's sRGB arithmetic. The chooser keeps
//! hue, saturation, and value as the user set them, so dragging through
//! black or gray does not lose the hue.
//!
//! The area and strips lay out left to right in right-to-left layouts
//! too: they are color geometry, not reading order, as in GTK and Qt.
//! Each is a slider for assistive technology (the area's value is the
//! saturation, its value text both numbers) and takes keys: arrows step
//! by 1 (with Shift 10), Page Up and Page Down by 10, Home and End go to
//! the ends; in the area Up and Down change the value.

const std = @import("std");
const w = @import("widgets.zig");
const picker = @import("picker.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

const area_w: f32 = 280;
const area_h: f32 = 160;
const strip_h: f32 = 16;
/// Pixels of the area's image.
const img_w = 128;
const img_h = 80;
const strip_img_w = 256;
const alpha_img_h = 8;

const Part = enum(u8) { area, hue, alpha };

pub const ColorChooser = extern struct {
    hdr: w.Header,
    root: Node,
    name: Node,
    area: Node,
    area_img: Node,
    area_mark: Node,
    hue: Node,
    hue_mark: Node,
    alpha: Node = .null,
    alpha_img: Node = .null,
    alpha_mark: Node = .null,
    swatch: Node,
    hex: Node,
    pick: Node,
    h: f32 = 0,
    s: f32 = 0,
    v: f32 = 0,
    a: f32 = 1,
    has_alpha: bool,
    /// The part a press is dragging, or none.
    dragging: u8 = 0xff,
    /// The portal said no color picker exists here.
    pick_unavailable: bool = false,
    /// The area's image shows this hue.
    shown_hue: f32 = -1,
};

/// The part a strip, the area, or a marker belongs to, as handler data.
const PartState = extern struct {
    hdr: w.Header,
    chooser: Node,
    part: Part,
};

pub export fn siv_color_chooser(txn: Txn, parent: Node, desc: ?*const siv.ColorChooserDesc) Node {
    const d = w.readDesc(siv.ColorChooserDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 0xf) != 0 or d.reserved0 != 0) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const col = clampColor(if (isZero(d.color)) .{ .r = 0, .g = 0, .b = 0, .a = 1 } else d.color);
    if (d.flags.compact) return picker.compact(txn, parent, .color_chooser, label, d.flags, 0, col, .none, "");

    const root = c.siv_flex(txn, parent, &.{ .axis = .column, .gap = 8 });
    if (root == .null) return .null;
    const st = w.create(ColorChooser, txn, root) orelse return .null;
    st.* = .{
        .hdr = .{ .kind = .color_chooser, .disabled = d.flags.disabled },
        .root = root,
        .name = .null,
        .area = .null,
        .area_img = .null,
        .area_mark = .null,
        .hue = .null,
        .hue_mark = .null,
        .swatch = .null,
        .hex = .null,
        .pick = .null,
        .has_alpha = d.flags.alpha,
    };
    setHsv(st, col, true);
    c.siv_set_layout(txn, root, &.{ .width = w.px(area_w) });

    st.area, st.area_img, st.area_mark = strip(txn, st, root, .area, area_h);
    st.hue, const hue_img, st.hue_mark = strip(txn, st, root, .hue, strip_h);
    showImage(txn, hue_img, &huePixels(), strip_img_w, 1);
    if (st.has_alpha) st.alpha, st.alpha_img, st.alpha_mark = strip(txn, st, root, .alpha, strip_h);

    const row = c.siv_flex(txn, root, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    st.swatch = c.siv_box(txn, row);
    c.siv_set_layout(txn, st.swatch, &.{ .width = w.px(tk.control_height), .height = w.px(tk.control_height), .flags = .{ .no_shrink = true } });
    st.hex = c.siv_text_field(txn, row, &.{ .label = "Hexadecimal", .label_len = 11, .placeholder = "#RRGGBB", .placeholder_len = 7 });
    c.siv_set_layout(txn, st.hex, &.{ .grow = 1, .width = w.px(0), .min_width = 96, .direction = .ltr });
    _ = c.siv_on_default(txn, st.hex, .change, onHexChange, null, st);
    st.pick = c.siv_push_button(txn, row, &.{ .label = "Pick from Screen", .label_len = 16 });
    _ = c.siv_on_default(txn, st.pick, .activate, onPick, null, st);

    st.name = w.hiddenText(txn, root, label);
    w.setInterface(txn, root, ColorChooser, st, .{ .set_label = setLabel, .apply = apply, .focus = focusArea });
    showHex(txn, st);
    apply(txn, st);
    return root;
}

/// A stack of an image and a canvas marker over it, a slider for
/// assistive technology.
fn strip(txn: Txn, st: *ColorChooser, parent: Node, part: Part, height: f32) struct { Node, Node, Node } {
    const stack = c.siv_stack(txn, parent, &.{ .align_x = .stretch, .align_y = .stretch });
    c.siv_set_layout(txn, stack, &.{ .width = w.px(area_w), .height = w.px(height), .flags = .{ .no_shrink = true }, .direction = .ltr });
    const ps = w.create(PartState, txn, stack) orelse return .{ .null, .null, .null };
    ps.* = .{ .hdr = .{ .kind = .color_part }, .chooser = st.root, .part = part };
    const img = c.siv_image_view(txn, stack, &.{ .fit = .fill });
    c.siv_set_visual(txn, img, &.{ .radius = w.corners(if (part == .area) tk.radius else height / 2), .flags = .{ .clip = true } });
    c.siv_set_semantics(txn, img, &.{ .role = .none });
    const mark = c.siv_canvas(txn, stack, &.{ .user_data = ps, .draw = drawMark });
    w.onDefault(txn, stack, .pointer, onPointer, ps);
    w.onDefault(txn, stack, .key, onKey, ps);
    w.onDefault(txn, stack, .set_value, onSetValue, ps);
    return .{ stack, img, mark };
}

fn stateOf(node: Node) ?*ColorChooser {
    return w.stateOf(ColorChooser, node, &.{.color_chooser});
}

fn focusArea(st: *ColorChooser) Node {
    return st.area;
}

fn setLabel(txn: Txn, st: *ColorChooser, label: []const u8) void {
    c.siv_set_text(txn, st.name, label.ptr, label.len);
    apply(txn, st);
}

/// siv_color_chooser_get_color: an inline chooser's color, or the
/// compact form's.
pub export fn siv_color_chooser_get_color(node: Node, out: ?*siv.Color) siv.Result {
    const o = out orelse return .error_invalid_argument;
    if (stateOf(node)) |st| {
        o.* = colorOf(st);
        return .ok;
    }
    if (picker.compactOf(node)) |cs| if (cs.picker == .color_chooser) {
        o.* = picker.getColor(cs);
        return .ok;
    };
    return .error_invalid_argument;
}

pub export fn siv_color_chooser_set_color(txn: Txn, node: Node, col: siv.Color) void {
    if (!std.math.isFinite(col.r) or !std.math.isFinite(col.g) or !std.math.isFinite(col.b) or !std.math.isFinite(col.a))
        return c.siv_txn_fail(txn, .error_invalid_argument);
    if (stateOf(node)) |st| {
        setHsv(st, clampColor(col), false);
        showHex(txn, st);
        apply(txn, st);
        return;
    }
    if (picker.compactOf(node)) |cs| if (cs.picker == .color_chooser) return picker.setColor(txn, cs, clampColor(col));
    c.siv_txn_fail(txn, .error_invalid_argument);
}

// Color arithmetic ---------------------------------------------------------------

fn isZero(col: siv.Color) bool {
    return col.r == 0 and col.g == 0 and col.b == 0 and col.a == 0;
}

fn clampColor(col: siv.Color) siv.Color {
    return .{ .r = std.math.clamp(col.r, 0, 1), .g = std.math.clamp(col.g, 0, 1), .b = std.math.clamp(col.b, 0, 1), .a = std.math.clamp(col.a, 0, 1) };
}

/// HSV (hue in degrees) to sRGB.
pub fn rgbOf(h: f32, s: f32, v: f32) [3]f32 {
    const hh = @mod(h, 360) / 60;
    const i: u32 = @intFromFloat(@floor(hh));
    const f = hh - @floor(hh);
    const p = v * (1 - s);
    const q = v * (1 - s * f);
    const t = v * (1 - s * (1 - f));
    return switch (i) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
}

/// Takes an sRGB color into the chooser's HSV, keeping the hue (and the
/// saturation) where the color does not determine it: grays and black.
fn setHsv(st: *ColorChooser, col: siv.Color, fresh: bool) void {
    const mx = @max(col.r, @max(col.g, col.b));
    const mn = @min(col.r, @min(col.g, col.b));
    const delta = mx - mn;
    st.v = mx;
    st.a = col.a;
    if (mx > 0) st.s = delta / mx else if (fresh) st.s = 0;
    if (delta > 0) {
        var h: f32 = if (mx == col.r)
            60 * @mod((col.g - col.b) / delta, 6)
        else if (mx == col.g)
            60 * ((col.b - col.r) / delta + 2)
        else
            60 * ((col.r - col.g) / delta + 4);
        if (h < 0) h += 360;
        st.h = if (h >= 360) 0 else h;
    } else if (mx > 0) st.s = 0;
}

fn colorOf(st: *const ColorChooser) siv.Color {
    const rgb = rgbOf(st.h, st.s, st.v);
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = if (st.has_alpha) st.a else 1 };
}

/// Parses "#RGB", "#RRGGBB", or "#RRGGBBAA", with or without the "#".
pub fn parseHex(text: []const u8) ?siv.Color {
    var s = std.mem.trim(u8, text, " \t");
    if (s.len > 0 and s[0] == '#') s = s[1..];
    var b: [4]u8 = .{ 0, 0, 0, 255 };
    switch (s.len) {
        3 => for (0..3) |i| {
            const d = std.fmt.charToDigit(s[i], 16) catch return null;
            b[i] = d * 17;
        },
        6, 8 => for (0..s.len / 2) |i| {
            b[i] = std.fmt.parseInt(u8, s[i * 2 ..][0..2], 16) catch return null;
        },
        else => return null,
    }
    return .{ .r = @as(f32, @floatFromInt(b[0])) / 255, .g = @as(f32, @floatFromInt(b[1])) / 255, .b = @as(f32, @floatFromInt(b[2])) / 255, .a = @as(f32, @floatFromInt(b[3])) / 255 };
}

// Images -------------------------------------------------------------------------

fn showImage(txn: Txn, node: Node, pixels: []const u8, width: u32, height: u32) void {
    var img: siv.Image = .null;
    if (c.siv_image_create(picker.appOf(node), &.{ .pixels = pixels.ptr, .pixels_count = pixels.len, .width = width, .height = height }, &img) != .ok) return;
    c.siv_set_image_view(txn, node, &.{ .image = img, .fit = .fill });
    c.siv_image_destroy(img);
}

fn put(px: []u8, rgb: [3]f32, a: f32) void {
    px[0] = picker.byteOf(rgb[0]);
    px[1] = picker.byteOf(rgb[1]);
    px[2] = picker.byteOf(rgb[2]);
    px[3] = picker.byteOf(a);
}

fn huePixels() [strip_img_w * 4]u8 {
    var out: [strip_img_w * 4]u8 = undefined;
    for (0..strip_img_w) |x| {
        const h = @as(f32, @floatFromInt(x)) / (strip_img_w - 1) * 360;
        put(out[x * 4 ..][0..4], rgbOf(h, 1, 1), 1);
    }
    return out;
}

/// Saturation left to right, value top to bottom, at the hue; pixel
/// centers sample the ends exactly.
fn showArea(txn: Txn, st: *ColorChooser) void {
    if (st.shown_hue == st.h) return;
    st.shown_hue = st.h;
    var px: [img_w * img_h * 4]u8 = undefined;
    for (0..img_h) |y| for (0..img_w) |x| {
        const s = @as(f32, @floatFromInt(x)) / (img_w - 1);
        const v = 1 - @as(f32, @floatFromInt(y)) / (img_h - 1);
        put(px[(y * img_w + x) * 4 ..][0..4], rgbOf(st.h, s, v), 1);
    };
    showImage(txn, st.area_img, &px, img_w, img_h);
}

/// The color from transparent to opaque over a checkerboard, composited
/// here in sRGB as a checkerboard behind a transparent color looks.
fn showAlpha(txn: Txn, st: *ColorChooser) void {
    if (st.alpha_img == .null) return;
    const rgb = rgbOf(st.h, st.s, st.v);
    var px: [strip_img_w * alpha_img_h * 4]u8 = undefined;
    for (0..alpha_img_h) |y| for (0..strip_img_w) |x| {
        const a = @as(f32, @floatFromInt(x)) / (strip_img_w - 1);
        const light = ((x / 4) + (y / 4)) % 2 == 0;
        const bg: f32 = if (light) 1 else 0.8;
        var mixed: [3]f32 = undefined;
        for (0..3) |i| mixed[i] = rgb[i] * a + bg * (1 - a);
        put(px[(y * strip_img_w + x) * 4 ..][0..4], mixed, 1);
    };
    showImage(txn, st.alpha_img, &px, strip_img_w, alpha_img_h);
}

// Showing the state ----------------------------------------------------------------

fn showHex(txn: Txn, st: *ColorChooser) void {
    var buf: [16]u8 = undefined;
    const hex = picker.hexOf(&buf, colorOf(st), st.has_alpha);
    c.siv_set_text(txn, st.hex, hex.ptr, hex.len);
}

fn apply(txn: Txn, st: *ColorChooser) void {
    const h = st.hdr;
    var name_buf: [256]u8 = undefined;
    const label = w.textOf(st.name, &name_buf);
    c.siv_set_semantics(txn, st.root, &.{ .role = .group, .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = h.disabled } });
    showArea(txn, st);
    showAlpha(txn, st);
    var buf: [64]u8 = undefined;
    const s_pct = @round(st.s * 100);
    const v_pct = @round(st.v * 100);
    const area_text = std.fmt.bufPrint(&buf, "saturation {d}%, brightness {d}%", .{ s_pct, v_pct }) catch "";
    sliderSemantics(txn, st.area, "Saturation and brightness", s_pct, 100, area_text, h.disabled);
    var hue_buf: [32]u8 = undefined;
    const hue_text = std.fmt.bufPrint(&hue_buf, "{d}°", .{@round(st.h)}) catch "";
    sliderSemantics(txn, st.hue, "Hue", @round(st.h), 360, hue_text, h.disabled);
    if (st.alpha != .null) {
        var a_buf: [32]u8 = undefined;
        const a_text = std.fmt.bufPrint(&a_buf, "{d}%", .{@round(st.a * 100)}) catch "";
        sliderSemantics(txn, st.alpha, "Opacity", @round(st.a * 100), 100, a_text, h.disabled);
    }
    for ([_]Node{ st.area_mark, st.hue_mark, st.alpha_mark }) |m| if (m != .null) c.siv_invalidate(txn, m);
    const col = colorOf(st);
    c.siv_set_visual(txn, st.swatch, &.{ .background = col, .radius = w.corners(tk.radius), .border_width = tk.border, .border_token = .border });
    var hex_buf: [16]u8 = undefined;
    const hex = picker.hexOf(&hex_buf, col, st.has_alpha);
    var sw_buf: [64]u8 = undefined;
    const sw = std.fmt.bufPrint(&sw_buf, "Color {s}", .{hex}) catch "";
    c.siv_set_semantics(txn, st.swatch, &.{ .role = .image, .label = sw.ptr, .label_len = sw.len });
    c.siv_widget_set_disabled(txn, st.hex, h.disabled);
    c.siv_widget_set_disabled(txn, st.pick, h.disabled or st.pick_unavailable);
}

fn sliderSemantics(txn: Txn, node: Node, label: []const u8, now: f64, max: f64, text: []const u8, disabled: bool) void {
    c.siv_set_semantics(txn, node, &.{
        .role = .slider,
        .label = label.ptr,
        .label_len = label.len,
        .value_min = 0,
        .value_max = max,
        .value_now = now,
        .value_step = 1,
        .value_text = text.ptr,
        .value_text_len = text.len,
        .flags = .{ .focusable = !disabled, .disabled = disabled, .has_value = true },
    });
}

/// The marker; the core draws the focus ring around the focused part.
fn drawMark(ud: ?*anyopaque, _: Node, draw: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const ps: *PartState = @ptrCast(@alignCast(ud.?));
    const st = stateOf(ps.chooser) orelse return;
    const ring: f32 = 2;
    const white: siv.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const dark: siv.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0.6 };
    switch (ps.part) {
        .area => {
            const x = st.s * width;
            const y = (1 - st.v) * height;
            const r: f32 = 6;
            c.siv_draw_ellipse(draw, .{ .x = x - r - 1, .y = y - r - 1, .width = 2 * r + 2, .height = 2 * r + 2 });
            c.siv_draw_stroke(draw, &.{ .width = 1 }, &.{ .color = dark });
            c.siv_draw_ellipse(draw, .{ .x = x - r, .y = y - r, .width = 2 * r, .height = 2 * r });
            c.siv_draw_stroke(draw, &.{ .width = ring }, &.{ .color = white });
        },
        .hue, .alpha => {
            const f = if (ps.part == .hue) st.h / 360 else st.a;
            const x = std.math.clamp(f * width, 3, width - 3);
            const rect: siv.Rect = .{ .x = x - 3, .y = 0.5, .width = 6, .height = height - 1 };
            c.siv_draw_rounded_rect(draw, rect, .{ .top_left = 3, .top_right = 3, .bottom_right = 3, .bottom_left = 3 });
            c.siv_draw_stroke(draw, &.{ .width = ring + 1 }, &.{ .color = dark });
            c.siv_draw_rounded_rect(draw, rect, .{ .top_left = 3, .top_right = 3, .bottom_right = 3, .bottom_left = 3 });
            c.siv_draw_stroke(draw, &.{ .width = ring }, &.{ .color = white });
        },
    }
}

// Input --------------------------------------------------------------------------

/// The user changed the color: shows it and reports `change`.
fn userChanged(st: *ColorChooser, hex: bool) void {
    const root = st.root;
    const txn = w.begin(w.windowOf(root)) orelse return;
    if (hex) showHex(txn, st);
    apply(txn, st);
    if (!w.commit(txn)) return;
    w.emitChange(root, 0, 0);
}

fn setPart(st: *ColorChooser, part: Part, x: f32, y: f32) void {
    switch (part) {
        .area => {
            st.s = std.math.clamp(x, 0, 1);
            st.v = std.math.clamp(y, 0, 1);
        },
        .hue => st.h = std.math.clamp(x, 0, 1) * 360,
        .alpha => st.a = std.math.clamp(x, 0, 1),
    }
}

fn atPointer(st: *ColorChooser, ps: *PartState, node: Node, ev: *const siv.Event) void {
    var rect: siv.Rect = undefined;
    if (c.siv_node_get_rect(node, &rect) != .ok or rect.width <= 0 or rect.height <= 0) return;
    setPart(st, ps.part, ev.x / rect.width, 1 - ev.y / rect.height);
    userChanged(st, true);
}

fn onPointer(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const ps: *PartState = @ptrCast(@alignCast(ud.?));
    const st = stateOf(ps.chooser) orelse return .pass;
    if (st.hdr.disabled) return .pass;
    switch (ev.phase) {
        .down => if (ev.button == .primary) {
            st.dragging = @intFromEnum(ps.part);
            atPointer(st, ps, node, ev);
        },
        .move => if (st.dragging == @intFromEnum(ps.part)) atPointer(st, ps, node, ev),
        .up, .cancel => st.dragging = 0xff,
        else => {},
    }
    // The core focuses the part on the press (D16).
    return .pass;
}

fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const ps: *PartState = @ptrCast(@alignCast(ud.?));
    const st = stateOf(ps.chooser) orelse return .pass;
    if (st.hdr.disabled or !ev.flags.pressed) return .pass;
    const m = ev.modifiers;
    if (m.ctrl or m.alt or m.super) return .pass;
    const k = w.keysym;
    // In units of the part's range: degrees of hue, percent otherwise.
    const range: f32 = if (ps.part == .hue) 360 else 100;
    const step: f32 = (if (m.shift) @as(f32, 10) else 1) / range;
    const page: f32 = 10 / range;
    var x: f32 = switch (ps.part) {
        .area => st.s,
        .hue => st.h / 360,
        .alpha => st.a,
    };
    var y: f32 = st.v;
    const vertical_value = ps.part == .area;
    switch (ev.keysym) {
        k.left => x -= step,
        k.right => x += step,
        k.up => if (vertical_value) {
            y += step;
        } else {
            x += step;
        },
        k.down => if (vertical_value) {
            y -= step;
        } else {
            x -= step;
        },
        k.page_up => if (vertical_value) {
            y += page;
        } else {
            x += page;
        },
        k.page_down => if (vertical_value) {
            y -= page;
        } else {
            x -= page;
        },
        k.home => x = 0,
        k.end => x = 1,
        else => return .pass,
    }
    // Snap to whole units, so a step from 37.4 lands on 38.
    x = @round(std.math.clamp(x, 0, 1) * range) / range;
    y = @round(std.math.clamp(y, 0, 1) * 100) / 100;
    if (ps.part == .hue and x >= 1) x = 359.0 / 360.0;
    setPart(st, ps.part, x, y);
    userChanged(st, true);
    return .handled;
}

fn onSetValue(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const ps: *PartState = @ptrCast(@alignCast(ud.?));
    const st = stateOf(ps.chooser) orelse return .pass;
    if (st.hdr.disabled or !std.math.isFinite(ev.value)) return .pass;
    const v: f32 = @floatCast(ev.value);
    switch (ps.part) {
        .area => st.s = std.math.clamp(v / 100, 0, 1),
        .hue => st.h = @min(std.math.clamp(v, 0, 360), 359.999),
        .alpha => st.a = std.math.clamp(v / 100, 0, 1),
    }
    userChanged(st, true);
    return .handled;
}

/// Typing a whole color into the field takes it; anything else waits.
fn onHexChange(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *ColorChooser = @ptrCast(@alignCast(ud.?));
    const text = w.str(ev.text, ev.text_len) orelse return .pass;
    var col = parseHex(text) orelse return .pass;
    if (!st.has_alpha) col.a = 1;
    setHsv(st, col, false);
    userChanged(st, false);
    return .pass;
}

fn onPick(ud: ?*anyopaque, node: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *ColorChooser = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled or st.pick_unavailable) return .handled;
    const window = w.windowOf(node);
    _ = c.siv_pick_color(w.appOf(window), window, onPicked, null, w.handleData(st.root));
    return .handled;
}

/// The portal answered: a picked color is the user's change; no portal
/// disables the button for good.
fn onPicked(ud: ?*anyopaque, result: *const siv.PortalResult) callconv(.c) void {
    const st = stateOf(w.dataHandle(ud)) orelse return;
    switch (result.response) {
        .success => {
            var col = clampColor(result.color);
            col.a = st.a;
            setHsv(st, col, false);
            userChanged(st, true);
        },
        .unavailable => {
            st.pick_unavailable = true;
            const txn = w.begin(w.windowOf(st.root)) orelse return;
            apply(txn, st);
            _ = w.commit(txn);
        },
        else => {},
    }
}

test "hsv round trip and hex parsing" {
    const t = std.testing;
    try t.expectEqual([3]f32{ 1, 0, 0 }, rgbOf(0, 1, 1));
    try t.expectEqual([3]f32{ 0, 0, 1 }, rgbOf(240, 1, 1));
    const col = parseHex("#3366CC").?;
    try t.expectApproxEqAbs(@as(f32, 0.2), col.r, 1e-6);
    try t.expectEqual(@as(f32, 1), col.a);
    try t.expectEqual(@as(f32, 0x80) / 255, parseHex("11223380").?.a);
    try t.expectEqual(@as(f32, 1), parseHex("#fff").?.g);
    try t.expect(parseHex("#12345") == null);
    try t.expect(parseHex("#GGGGGG") == null);
}
