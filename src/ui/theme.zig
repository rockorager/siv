//! Theming (D29): named colors and text sizes that nodes reference instead
//! of literal values, resolved when a node is painted or shaped. A
//! window's palette follows the desktop (color scheme, contrast, accent,
//! font size; D19) and the application's overrides, so a theme change
//! repaints and reshapes without the application touching the tree.
//!
//! The compiled tokens come in four variants (light, dark, and a high
//! contrast version of each). The desktop's accent replaces `accent`, and
//! the colors derived from it (hover and active shades, the text on it,
//! focus rings, selections) follow unless the application overrides them.

const std = @import("std");
const scene = @import("scene");

const Color = scene.Color;

/// A themed color. `none` means the node's literal color applies.
pub const ColorToken = enum(u8) {
    none,
    window_bg,
    window_fg,
    view_bg,
    view_fg,
    card_bg,
    card_fg,
    muted_fg,
    disabled_fg,
    border,
    separator,
    control_bg,
    control_hover,
    control_active,
    control_fg,
    accent,
    accent_hover,
    accent_active,
    accent_fg,
    selection_bg,
    selection_fg,
    focus_ring,
    track,
    knob,
    destructive,
    destructive_fg,
    scrim,
    inverse_bg,
    inverse_fg,
};

pub const token_count = @typeInfo(ColorToken).@"enum".field_names.len;

/// A themed text size, relative to the desktop's font size. `fixed`
/// keeps the style's own size.
pub const TextRole = enum(u8) {
    fixed,
    body,
    caption,
    heading,
    title,

    pub fn ratio(r: TextRole) f32 {
        return switch (r) {
            .fixed, .body => 1,
            .caption => 0.85,
            .heading => 1.2,
            .title => 1.5,
        };
    }
};

pub const Variant = enum(u2) { light, dark, light_high_contrast, dark_high_contrast };

pub const SchemeChoice = enum(u8) { follow, light, dark };
pub const ContrastChoice = enum(u8) { follow, normal, high };

/// What the application chose: a fixed scheme or contrast instead of the
/// desktop's, and colors that replace the compiled tokens per variant.
pub const Theme = struct {
    scheme: SchemeChoice = .follow,
    contrast: ContrastChoice = .follow,
    overrides: [4][token_count]?Color = @splat(@splat(null)),
};

/// The desktop's part (from `Window.Desktop`).
pub const DesktopInput = struct {
    dark: bool = false,
    high_contrast: bool = false,
    /// sRGB components in [0, 1].
    accent: ?[3]f64 = null,
    /// The UI font's size in points.
    font_pt: f64 = 11,
};

/// Resolved colors (linear, as the renderer takes them) and the body text
/// size in logical pixels.
pub const Palette = struct {
    variant: Variant = .light,
    colors: [token_count]Color = compiled[0],
    body_px: f32 = 11.0 * 4.0 / 3.0,

    pub fn color(p: *const Palette, token: ColorToken) Color {
        return p.colors[@intFromEnum(token)];
    }

    /// `literal` unless `token` names a themed color.
    pub fn pick(p: *const Palette, literal: Color, token: ColorToken) Color {
        return if (token == .none) literal else p.color(token);
    }

    /// The size a text style shapes at.
    pub fn textSize(p: *const Palette, size: f32, role: TextRole) f32 {
        return if (role == .fixed) size else p.body_px * role.ratio();
    }

    pub fn eqlColors(a: *const Palette, b: *const Palette) bool {
        for (a.colors, b.colors) |x, y| if (!x.eql(y)) return false;
        return true;
    }
};

pub fn resolve(theme: *const Theme, d: DesktopInput) Palette {
    const dark = switch (theme.scheme) {
        .follow => d.dark,
        .light => false,
        .dark => true,
    };
    const high = switch (theme.contrast) {
        .follow => d.high_contrast,
        .normal => false,
        .high => true,
    };
    const variant: Variant = if (high) (if (dark) .dark_high_contrast else .light_high_contrast) else if (dark) .dark else .light;
    const v = @intFromEnum(variant);
    var p: Palette = .{ .variant = variant, .colors = compiled[v] };
    if (d.font_pt > 0 and std.math.isFinite(d.font_pt)) p.body_px = @floatCast(std.math.clamp(d.font_pt, 4, 96) * 4.0 / 3.0);
    const ov = &theme.overrides[v];
    const a = @intFromEnum(ColorToken.accent);
    var accent = p.colors[a];
    if (d.accent) |c| accent = .srgb(@floatCast(c[0]), @floatCast(c[1]), @floatCast(c[2]), 1);
    if (ov[a]) |c| accent = c;
    if (!accent.eql(p.colors[a])) derive(&p, accent, high);
    for (ov, 0..) |o, i| if (o) |c| {
        p.colors[i] = c;
    };
    return p;
}

/// Colors that follow a replaced accent.
fn derive(p: *Palette, accent: Color, high: bool) void {
    const dark = p.variant == .dark or p.variant == .dark_high_contrast;
    const shade: Color = if (dark) .white else .black;
    set(p, .accent, accent);
    set(p, .accent_hover, mix(accent, shade, 0.12));
    set(p, .accent_active, mix(accent, shade, 0.24));
    const on = onColor(accent);
    set(p, .accent_fg, on);
    set(p, .focus_ring, accent);
    if (high) {
        set(p, .selection_bg, accent);
        set(p, .selection_fg, on);
    } else {
        set(p, .selection_bg, mix(p.color(.view_bg), accent, 0.3));
    }
}

fn set(p: *Palette, t: ColorToken, c: Color) void {
    p.colors[@intFromEnum(t)] = c;
}

/// Linear interpolation in linear light.
pub fn mix(a: Color, b: Color, k: f32) Color {
    return .{ .r = a.r + (b.r - a.r) * k, .g = a.g + (b.g - a.g) * k, .b = a.b + (b.b - a.b) * k, .a = a.a + (b.a - a.a) * k };
}

/// Black or white, whichever contrasts more with `bg` (WCAG ratio).
pub fn onColor(bg: Color) Color {
    const l = bg.luminance();
    const with_white = 1.05 / (l + 0.05);
    const with_black = (l + 0.05) / 0.05;
    return if (with_white >= with_black) .white else .black;
}

/// The compiled tokens: light, dark, light high contrast, dark high contrast.
pub const compiled: [4][token_count]Color = .{
    palette(.{
        .window_bg = 0xfafafa, .window_fg = 0x18181b, .view_bg = 0xffffff, .view_fg = 0x18181b,
        .card_bg = 0xffffff, .card_fg = 0x18181b, .muted_fg = 0x71717a, .disabled_fg = 0xa1a1aa,
        .border = 0xc4c4cc, .separator = 0xe4e4e7, .control_bg = 0xf4f4f5, .control_hover = 0xe4e4e7,
        .control_active = 0xd4d4d8, .control_fg = 0x18181b, .accent = 0x2563eb, .accent_hover = 0x1d4ed8,
        .accent_active = 0x1e40af, .accent_fg = 0xffffff, .selection_bg = 0xbfdbfe, .selection_fg = 0x18181b,
        .focus_ring = 0x2563eb, .track = 0xd4d4d8, .knob = 0xffffff, .destructive = 0xdc2626,
        .destructive_fg = 0xffffff, .scrim = 0x00000066, .inverse_bg = 0x27272a, .inverse_fg = 0xfafafa,
    }),
    palette(.{
        .window_bg = 0x18181b, .window_fg = 0xf4f4f5, .view_bg = 0x09090b, .view_fg = 0xf4f4f5,
        .card_bg = 0x27272a, .card_fg = 0xf4f4f5, .muted_fg = 0xa1a1aa, .disabled_fg = 0x52525b,
        .border = 0x52525b, .separator = 0x3f3f46, .control_bg = 0x27272a, .control_hover = 0x3f3f46,
        .control_active = 0x52525b, .control_fg = 0xf4f4f5, .accent = 0x2563eb, .accent_hover = 0x3b82f6,
        .accent_active = 0x1d4ed8, .accent_fg = 0xffffff, .selection_bg = 0x1e3a8a, .selection_fg = 0xf4f4f5,
        .focus_ring = 0x3b82f6, .track = 0x3f3f46, .knob = 0xf4f4f5, .destructive = 0xdc2626,
        .destructive_fg = 0xffffff, .scrim = 0x00000099, .inverse_bg = 0xf4f4f5, .inverse_fg = 0x18181b,
    }),
    palette(.{
        .window_bg = 0xffffff, .window_fg = 0x000000, .view_bg = 0xffffff, .view_fg = 0x000000,
        .card_bg = 0xffffff, .card_fg = 0x000000, .muted_fg = 0x333333, .disabled_fg = 0x595959,
        .border = 0x000000, .separator = 0x000000, .control_bg = 0xffffff, .control_hover = 0xe0e0e0,
        .control_active = 0xc2c2c2, .control_fg = 0x000000, .accent = 0x0040c0, .accent_hover = 0x002f8f,
        .accent_active = 0x00226b, .accent_fg = 0xffffff, .selection_bg = 0x0040c0, .selection_fg = 0xffffff,
        .focus_ring = 0x000000, .track = 0x595959, .knob = 0xffffff, .destructive = 0xa00000,
        .destructive_fg = 0xffffff, .scrim = 0x000000b3, .inverse_bg = 0x000000, .inverse_fg = 0xffffff,
    }),
    palette(.{
        .window_bg = 0x000000, .window_fg = 0xffffff, .view_bg = 0x000000, .view_fg = 0xffffff,
        .card_bg = 0x000000, .card_fg = 0xffffff, .muted_fg = 0xe0e0e0, .disabled_fg = 0xa6a6a6,
        .border = 0xffffff, .separator = 0xffffff, .control_bg = 0x000000, .control_hover = 0x262626,
        .control_active = 0x404040, .control_fg = 0xffffff, .accent = 0x7cb4ff, .accent_hover = 0xa3caff,
        .accent_active = 0xc7ddff, .accent_fg = 0x000000, .selection_bg = 0x7cb4ff, .selection_fg = 0x000000,
        .focus_ring = 0xffff00, .track = 0xa6a6a6, .knob = 0x000000, .destructive = 0xff7070,
        .destructive_fg = 0x000000, .scrim = 0x000000b3, .inverse_bg = 0xffffff, .inverse_fg = 0x000000,
    }),
};

/// Hex colors per token: 0xRRGGBB opaque, or 0xRRGGBBAA when the value
/// exceeds 24 bits.
fn palette(comptime hex: anytype) [token_count]Color {
    @setEvalBranchQuota(1_000_000);
    var out: [token_count]Color = undefined;
    out[0] = .transparent;
    for (@typeInfo(ColorToken).@"enum".field_names[1..], 1..) |name, i| {
        const v: u32 = @field(hex, name);
        out[i] = if (v > 0xffffff)
            .srgb8(@truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v))
        else
            .srgb8(@truncate(v >> 16), @truncate(v >> 8), @truncate(v), 0xff);
    }
    return out;
}

test "variants follow the desktop unless the application fixes them" {
    var th: Theme = .{};
    try std.testing.expectEqual(Variant.light, resolve(&th, .{}).variant);
    try std.testing.expectEqual(Variant.dark, resolve(&th, .{ .dark = true }).variant);
    try std.testing.expectEqual(Variant.dark_high_contrast, resolve(&th, .{ .dark = true, .high_contrast = true }).variant);
    th.scheme = .light;
    th.contrast = .high;
    try std.testing.expectEqual(Variant.light_high_contrast, resolve(&th, .{ .dark = true }).variant);
}

test "a desktop accent replaces the accent and what derives from it; overrides win" {
    var th: Theme = .{};
    // A light yellow accent needs black text on it.
    const p = resolve(&th, .{ .accent = .{ 1, 0.9, 0.2 } });
    const want = Color.srgb(1, 0.9, 0.2, 1);
    try std.testing.expect(p.color(.accent).eql(want));
    try std.testing.expect(p.color(.focus_ring).eql(want));
    try std.testing.expect(p.color(.accent_fg).eql(.black));
    try std.testing.expect(p.color(.accent_hover).luminance() < want.luminance());
    // Untouched tokens keep their compiled values.
    try std.testing.expect(p.color(.window_bg).eql(compiled[0][@intFromEnum(ColorToken.window_bg)]));
    th.overrides[0][@intFromEnum(ColorToken.focus_ring)] = .white;
    try std.testing.expect(resolve(&th, .{ .accent = .{ 1, 0.9, 0.2 } }).color(.focus_ring).eql(.white));
    // Without an accent nothing is derived: the compiled shades stay.
    try std.testing.expect(resolve(&th, .{}).color(.accent_hover).eql(compiled[0][@intFromEnum(ColorToken.accent_hover)]));
}

test "body text follows the desktop font size in points" {
    const th: Theme = .{};
    const p = resolve(&th, .{ .font_pt = 12 });
    try std.testing.expectApproxEqAbs(@as(f32, 16), p.textSize(9, .body), 1e-4);
    try std.testing.expectEqual(@as(f32, 9), p.textSize(9, .fixed));
    try std.testing.expectApproxEqAbs(@as(f32, 24), p.textSize(9, .title), 1e-4);
}
