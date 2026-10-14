//! Theming (D29): named colors and text sizes that nodes reference instead
//! of literal values, resolved when a node is painted or shaped. A
//! window's palette follows the desktop (color scheme, contrast, accent,
//! font size; D19), the user's theme (user_theme.zig), and the
//! application's overrides, so a theme change repaints and reshapes
//! without the application touching the tree.
//!
//! The compiled tokens come in four variants (light, dark, and a high
//! contrast version of each). Layers apply over them in order: the
//! desktop's accent, the user's theme (not in high contrast), and the
//! application's overrides. A layer that sets `accent` also sets the
//! colors derived from it (hover and active shades, the text on it, focus
//! rings, selections), except those it sets itself.

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
    /// Symbolic icons' success and warning colors (D19); their error
    /// color is `destructive`.
    success,
    warning,
    /// Panes recessed from the view beside it, as libadwaita's sidebars:
    /// navigation lists, the outer columns of a Miller-column browser.
    /// `sidebar_bg` is the farther one, `secondary_sidebar_bg` sits
    /// between it and `view_bg`. Text on both is `view_fg`.
    sidebar_bg,
    secondary_sidebar_bg,
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

pub const Scheme = enum(u1) { light, dark };

/// The user's theme (D29): colors for the light and the dark variant, from
/// `$XDG_CONFIG_HOME/siv/theme.toml` or Omarchy (user_theme.zig). Tokens
/// it leaves null keep the compiled ones. High contrast ignores it.
pub const User = struct {
    pub const Source = enum(u8) { none, file, omarchy };

    source: Source = .none,
    /// The scheme the theme is for (Omarchy's mode, theme.toml's
    /// `scheme`): it picks the variant instead of the desktop's color
    /// scheme. Null follows the desktop.
    scheme: ?Scheme = null,
    /// Indexed by `Scheme`.
    colors: [2][token_count]?Color = @splat(@splat(null)),

    pub fn eql(a: *const User, b: *const User) bool {
        if (a.source != b.source or a.scheme != b.scheme) return false;
        for (a.colors, b.colors) |x, y| for (x, y) |p, q| {
            if ((p == null) != (q == null)) return false;
            if (p != null and !p.?.eql(q.?)) return false;
        };
        return true;
    }
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

pub fn resolve(theme: *const Theme, d: DesktopInput, user: *const User) Palette {
    const dark = switch (theme.scheme) {
        .follow => if (user.scheme) |s| s == .dark else d.dark,
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
    // High contrast is siv's: a user theme (Omarchy's have no
    // high-contrast variant) would undo what the user asked for.
    const none: [token_count]?Color = @splat(null);
    const layers = [_]*const [token_count]?Color{ if (high) &none else &user.colors[@intFromBool(dark)], &theme.overrides[v] };
    for (layers) |layer| for (layer, 0..) |o, i| if (o) |c| {
        p.colors[i] = c;
    };
    // The accent's layer: 0 compiled, 1 the desktop, 2 + the index in
    // `layers`.
    const a = @intFromEnum(ColorToken.accent);
    var level: usize = 0;
    if (d.accent) |c| {
        p.colors[a] = .srgb(@floatCast(c[0]), @floatCast(c[1]), @floatCast(c[2]), 1);
        level = 1;
    }
    for (layers, 2..) |layer, l| if (layer[a]) |c| {
        p.colors[a] = c;
        level = l;
    };
    // Layers at or above the accent's keep the derived colors they set;
    // those below it give way to the accent.
    if (level > 0) derive(&p, layers[level -| 2 ..], high);
    return p;
}

/// Colors derived from a replaced accent, over the final view background,
/// except those one of `keep` sets.
fn derive(p: *Palette, keep: []const *const [token_count]?Color, high: bool) void {
    const accent = p.color(.accent);
    const dark = p.variant == .dark or p.variant == .dark_high_contrast;
    const shade: Color = if (dark) .white else .black;
    const on = onColor(accent);
    const derived = [_]struct { ColorToken, Color }{
        .{ .accent_hover, mix(accent, shade, 0.12) },
        .{ .accent_active, mix(accent, shade, 0.24) },
        .{ .accent_fg, on },
        .{ .focus_ring, accent },
        .{ .selection_bg, if (high) accent else mix(p.color(.view_bg), accent, 0.3) },
        .{ .selection_fg, if (high) on else p.color(.selection_fg) },
    };
    next: for (derived) |e| {
        for (keep) |layer| if (layer[@intFromEnum(e[0])] != null) continue :next;
        set(p, e[0], e[1]);
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
        .destructive_fg = 0xffffff, .scrim = .{ 0x000000, 0x66 }, .inverse_bg = 0x27272a, .inverse_fg = 0xfafafa,
        .success = 0x16a34a, .warning = 0xd97706,
        .sidebar_bg = 0xededf0, .secondary_sidebar_bg = 0xf6f6f8,
    }),
    palette(.{
        .window_bg = 0x18181b, .window_fg = 0xf4f4f5, .view_bg = 0x09090b, .view_fg = 0xf4f4f5,
        .card_bg = 0x27272a, .card_fg = 0xf4f4f5, .muted_fg = 0xa1a1aa, .disabled_fg = 0x52525b,
        .border = 0x52525b, .separator = 0x3f3f46, .control_bg = 0x27272a, .control_hover = 0x3f3f46,
        .control_active = 0x52525b, .control_fg = 0xf4f4f5, .accent = 0x2563eb, .accent_hover = 0x3b82f6,
        .accent_active = 0x1d4ed8, .accent_fg = 0xffffff, .selection_bg = 0x1e3a8a, .selection_fg = 0xf4f4f5,
        .focus_ring = 0x3b82f6, .track = 0x3f3f46, .knob = 0xf4f4f5, .destructive = 0xdc2626,
        .destructive_fg = 0xffffff, .scrim = .{ 0x000000, 0x99 }, .inverse_bg = 0xf4f4f5, .inverse_fg = 0x18181b,
        .success = 0x22c55e, .warning = 0xf59e0b,
        .sidebar_bg = 0x1c1c20, .secondary_sidebar_bg = 0x131316,
    }),
    palette(.{
        .window_bg = 0xffffff, .window_fg = 0x000000, .view_bg = 0xffffff, .view_fg = 0x000000,
        .card_bg = 0xffffff, .card_fg = 0x000000, .muted_fg = 0x333333, .disabled_fg = 0x595959,
        .border = 0x000000, .separator = 0x000000, .control_bg = 0xffffff, .control_hover = 0xe0e0e0,
        .control_active = 0xc2c2c2, .control_fg = 0x000000, .accent = 0x0040c0, .accent_hover = 0x002f8f,
        .accent_active = 0x00226b, .accent_fg = 0xffffff, .selection_bg = 0x0040c0, .selection_fg = 0xffffff,
        .focus_ring = 0x000000, .track = 0x595959, .knob = 0xffffff, .destructive = 0xa00000,
        .destructive_fg = 0xffffff, .scrim = .{ 0x000000, 0xb3 }, .inverse_bg = 0x000000, .inverse_fg = 0xffffff,
        .success = 0x006b1f, .warning = 0x8a4b00,
        .sidebar_bg = 0xe6e6e6, .secondary_sidebar_bg = 0xf2f2f2,
    }),
    palette(.{
        .window_bg = 0x000000, .window_fg = 0xffffff, .view_bg = 0x000000, .view_fg = 0xffffff,
        .card_bg = 0x000000, .card_fg = 0xffffff, .muted_fg = 0xe0e0e0, .disabled_fg = 0xa6a6a6,
        .border = 0xffffff, .separator = 0xffffff, .control_bg = 0x000000, .control_hover = 0x262626,
        .control_active = 0x404040, .control_fg = 0xffffff, .accent = 0x7cb4ff, .accent_hover = 0xa3caff,
        .accent_active = 0xc7ddff, .accent_fg = 0x000000, .selection_bg = 0x7cb4ff, .selection_fg = 0x000000,
        .focus_ring = 0xffff00, .track = 0xa6a6a6, .knob = 0x000000, .destructive = 0xff7070,
        .destructive_fg = 0x000000, .scrim = .{ 0x000000, 0xb3 }, .inverse_bg = 0xffffff, .inverse_fg = 0x000000,
        .success = 0x66ff99, .warning = 0xffcc33,
        .sidebar_bg = 0x1f1f1f, .secondary_sidebar_bg = 0x101010,
    }),
};

/// Colors per token: 0xRRGGBB opaque, or .{ 0xRRGGBB, alpha }.
fn palette(comptime hex: anytype) [token_count]Color {
    @setEvalBranchQuota(1_000_000);
    var out: [token_count]Color = undefined;
    out[0] = .transparent;
    for (@typeInfo(ColorToken).@"enum".field_names[1..], 1..) |name, i| {
        const f = @field(hex, name);
        const v: u32, const a: u8 = if (@typeInfo(@TypeOf(f)) == .@"struct") .{ f[0], f[1] } else .{ f, 0xff };
        out[i] = .srgb8(@truncate(v >> 16), @truncate(v >> 8), @truncate(v), a);
    }
    return out;
}

test "translucent tokens keep their color and alpha" {
    const scrim = compiled[0][@intFromEnum(ColorToken.scrim)];
    try std.testing.expect(scrim.r == 0 and scrim.g == 0 and scrim.b == 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0x66) / 255, scrim.a, 1e-6);
}

test "variants follow the desktop unless the application fixes them" {
    var th: Theme = .{};
    try std.testing.expectEqual(Variant.light, resolve(&th, .{}, &.{}).variant);
    try std.testing.expectEqual(Variant.dark, resolve(&th, .{ .dark = true }, &.{}).variant);
    try std.testing.expectEqual(Variant.dark_high_contrast, resolve(&th, .{ .dark = true, .high_contrast = true }, &.{}).variant);
    th.scheme = .light;
    th.contrast = .high;
    try std.testing.expectEqual(Variant.light_high_contrast, resolve(&th, .{ .dark = true }, &.{}).variant);
}

test "a desktop accent replaces the accent and what derives from it; overrides win" {
    var th: Theme = .{};
    // A light yellow accent needs black text on it.
    const p = resolve(&th, .{ .accent = .{ 1, 0.9, 0.2 } }, &.{});
    const want = Color.srgb(1, 0.9, 0.2, 1);
    try std.testing.expect(p.color(.accent).eql(want));
    try std.testing.expect(p.color(.focus_ring).eql(want));
    try std.testing.expect(p.color(.accent_fg).eql(.black));
    try std.testing.expect(p.color(.accent_hover).luminance() < want.luminance());
    // Untouched tokens keep their compiled values.
    try std.testing.expect(p.color(.window_bg).eql(compiled[0][@intFromEnum(ColorToken.window_bg)]));
    th.overrides[0][@intFromEnum(ColorToken.focus_ring)] = .white;
    try std.testing.expect(resolve(&th, .{ .accent = .{ 1, 0.9, 0.2 } }, &.{}).color(.focus_ring).eql(.white));
    // Without an accent nothing is derived: the compiled shades stay.
    try std.testing.expect(resolve(&th, .{}, &.{}).color(.accent_hover).eql(compiled[0][@intFromEnum(ColorToken.accent_hover)]));
}

test "the user's theme: between the desktop and the application, not in high contrast" {
    const D = @intFromEnum(Scheme.dark);
    const tok = struct {
        fn f(t: ColorToken) usize {
            return @intFromEnum(t);
        }
    }.f;
    const view = Color.srgb8(0x1a, 0x1b, 0x26, 0xff);
    const user_accent = Color.srgb8(0x7a, 0xa2, 0xf7, 0xff);
    const user_sel = Color.srgb8(0x29, 0x2e, 0x42, 0xff);
    var u: User = .{ .source = .omarchy, .scheme = .dark };
    u.colors[D][tok(.view_bg)] = view;
    u.colors[D][tok(.accent)] = user_accent;
    u.colors[D][tok(.selection_bg)] = user_sel;
    var th: Theme = .{};
    const desktop: DesktopInput = .{ .dark = false, .accent = .{ 1, 0, 0 } };

    // Its scheme decides over the desktop's; its accent over the
    // desktop's, with siv's shades; colors it sets stay.
    var p = resolve(&th, desktop, &u);
    try std.testing.expectEqual(Variant.dark, p.variant);
    try std.testing.expect(p.color(.view_bg).eql(view));
    try std.testing.expect(p.color(.accent).eql(user_accent));
    try std.testing.expect(p.color(.focus_ring).eql(user_accent));
    try std.testing.expect(p.color(.accent_hover).eql(mix(user_accent, .white, 0.12)));
    try std.testing.expect(p.color(.selection_bg).eql(user_sel));
    // Tokens it leaves out keep the compiled dark ones.
    try std.testing.expect(p.color(.border).eql(compiled[1][tok(.border)]));

    // Without its own accent the desktop's applies, and a derived color
    // the theme leaves out mixes over the theme's view background.
    u.colors[D][tok(.accent)] = null;
    u.colors[D][tok(.selection_bg)] = null;
    p = resolve(&th, desktop, &u);
    const red = Color.srgb(1, 0, 0, 1);
    try std.testing.expect(p.color(.accent).eql(red));
    try std.testing.expect(p.color(.selection_bg).eql(mix(view, red, 0.3)));
    u.colors[D][tok(.accent)] = user_accent;
    u.colors[D][tok(.selection_bg)] = user_sel;

    // The application's overrides win, and its accent moves what
    // derives from it, the theme's selection too.
    const green = Color.srgb(0, 1, 0, 1);
    th.overrides[1][tok(.accent)] = green;
    th.overrides[1][tok(.view_bg)] = .black;
    p = resolve(&th, desktop, &u);
    try std.testing.expect(p.color(.accent).eql(green));
    try std.testing.expect(p.color(.view_bg).eql(.black));
    try std.testing.expect(p.color(.selection_bg).eql(mix(.black, green, 0.3)));
    th.overrides = @splat(@splat(null));

    // A scheme the application fixes keeps the theme's colors to their
    // variant: light is compiled.
    th.scheme = .light;
    p = resolve(&th, desktop, &u);
    try std.testing.expectEqual(Variant.light, p.variant);
    try std.testing.expect(p.color(.view_bg).eql(compiled[0][tok(.view_bg)]));
    th.scheme = .follow;

    // High contrast is siv's own, in the theme's scheme.
    p = resolve(&th, .{ .high_contrast = true }, &u);
    try std.testing.expectEqual(Variant.dark_high_contrast, p.variant);
    for (p.colors, compiled[3]) |a, b| try std.testing.expect(a.eql(b));
}

test "body text follows the desktop font size in points" {
    const th: Theme = .{};
    const p = resolve(&th, .{ .font_pt = 12 }, &.{});
    try std.testing.expectApproxEqAbs(@as(f32, 16), p.textSize(9, .body), 1e-4);
    try std.testing.expectEqual(@as(f32, 9), p.textSize(9, .fixed));
    try std.testing.expectApproxEqAbs(@as(f32, 24), p.textSize(9, .title), 1e-4);
}

test "sidebar surfaces are distinct steps from the view, with readable text, in every variant" {
    for (compiled, 0..) |colors, v| {
        const view = colors[@intFromEnum(ColorToken.view_bg)];
        const fg = colors[@intFromEnum(ColorToken.view_fg)];
        const side = colors[@intFromEnum(ColorToken.sidebar_bg)];
        const second = colors[@intFromEnum(ColorToken.secondary_sidebar_bg)];
        try std.testing.expect(!side.eql(view) and !second.eql(view) and !side.eql(second));
        // The secondary sidebar lies between the sidebar and the view.
        const lv = view.luminance();
        const ls = side.luminance();
        const l2 = second.luminance();
        try std.testing.expect((l2 - lv) * (ls - l2) > 0);
        // View text keeps its contrast: 7:1 in high contrast, 4.5:1 else.
        const want: f32 = if (v >= 2) 7 else 4.5;
        for ([_]Color{ side, second }) |bg| {
            const a = @max(fg.luminance(), bg.luminance());
            const b = @min(fg.luminance(), bg.luminance());
            try std.testing.expect((a + 0.05) / (b + 0.05) >= want);
        }
    }
}
