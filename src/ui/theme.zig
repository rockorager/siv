//! Theming (D29): named colors and text sizes that nodes reference instead
//! of literal values, resolved when a node is painted or shaped. A
//! window's palette follows the desktop (color scheme, contrast, accent,
//! font size; D19), the user's theme (user_theme.zig), and the
//! application's overrides, so a theme change repaints and reshapes
//! without the application touching the tree.
//!
//! The compiled tokens come in four variants (light, dark, and a high
//! contrast version of each). Layers apply over them in order: the
//! application's defaults (its own palette in place of the compiled
//! one, without a user theme), the desktop's accent, the user's theme (not in high contrast),
//! and the application's overrides. A layer that sets `accent` also sets the
//! colors derived from it (hover and active shades, the text on it, focus
//! rings, selections), except those it sets itself.
//!
//! A node can carry a theme for its subtree (`Scope`, D43): a scheme, high
//! contrast, and overrides per variant, composed with every scope above
//! it into a `Context` that resolves over the same layers, so a dark
//! sidebar still follows the desktop's accent and the user's theme.

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
    /// Box shadows under raised surfaces (`Visual.shadows`): translucent
    /// black, deeper in dark variants, where a faint one would vanish.
    shadow,
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
/// desktop's, its defaults for the compiled tokens per variant (beneath
/// the desktop, and only without a user theme), and overrides above
/// them all.
pub const Theme = struct {
    scheme: SchemeChoice = .follow,
    contrast: ContrastChoice = .follow,
    defaults: [4][token_count]?Color = @splat(@splat(null)),
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

/// The scheme a subtree takes (`Scope.scheme`).
pub const SubtreeScheme = enum(u8) {
    /// The enclosing subtree's, else the window's.
    inherit,
    /// The desktop's (or the user's theme's, as for a window that follows
    /// it), whatever the application or an enclosing subtree fixed.
    follow,
    light,
    dark,
    /// The opposite of the enclosing subtree's or the window's.
    inverse,
};

/// A node's theme for its subtree (`Node.theme`, D43): choices, never
/// resolved colors, so the desktop, the user's theme, and the
/// application's theme reach the subtree as they reach the window.
/// Colors only: text sizes stay the window's.
pub const Scope = struct {
    scheme: SubtreeScheme = .inherit,
    /// Raises contrast; nothing lowers what the desktop or the application
    /// asked for (D18).
    high_contrast: bool = false,
    /// Over the application's overrides, per variant like them.
    overrides: [4][token_count]?Color = @splat(@splat(null)),

    pub fn isEmpty(s: *const Scope) bool {
        if (s.scheme != .inherit or s.high_contrast) return false;
        for (s.overrides) |v| for (v) |c| if (c != null) return false;
        return true;
    }

    pub fn eql(a: *const Scope, b: *const Scope) bool {
        return a.scheme == b.scheme and a.high_contrast == b.high_contrast and eqlOverrides(&a.overrides, &b.overrides);
    }
};

/// The subtree choices in effect at a node: the scopes from the window's
/// root down to it, composed (`within`). The window's own is empty, except
/// in a popup, which takes its anchor's.
pub const Context = struct {
    /// Where the scheme comes from, before `invert`.
    scheme: enum(u8) { window, desktop, light, dark } = .window,
    invert: bool = false,
    high_contrast: bool = false,
    /// Every scope's overrides, inner ones winning. A scope that sets the
    /// accent drops the derived colors outer ones set and it does not, so
    /// that they derive from its accent, as one layer above another would.
    overrides: [4][token_count]?Color = @splat(@splat(null)),

    /// The context inside a node with scope `s`.
    pub fn within(outer: *const Context, s: *const Scope) Context {
        var c = outer.*;
        switch (s.scheme) {
            .inherit => {},
            .follow => c = .{ .scheme = .desktop, .high_contrast = c.high_contrast, .overrides = c.overrides },
            .light => c = .{ .scheme = .light, .high_contrast = c.high_contrast, .overrides = c.overrides },
            .dark => c = .{ .scheme = .dark, .high_contrast = c.high_contrast, .overrides = c.overrides },
            .inverse => c.invert = !c.invert,
        }
        c.high_contrast = c.high_contrast or s.high_contrast;
        for (&c.overrides, &s.overrides) |*o, *mine| {
            if (mine[@intFromEnum(ColorToken.accent)] != null) for (derived_tokens) |t| {
                o[@intFromEnum(t)] = null;
            };
            for (o, mine) |*x, y| if (y) |v| {
                x.* = v;
            };
        }
        return c;
    }

    pub fn eql(a: *const Context, b: *const Context) bool {
        return a.scheme == b.scheme and a.invert == b.invert and a.high_contrast == b.high_contrast and eqlOverrides(&a.overrides, &b.overrides);
    }
};

fn eqlOverrides(a: *const [4][token_count]?Color, b: *const [4][token_count]?Color) bool {
    for (a, b) |x, y| for (x, y) |p, q| {
        if ((p == null) != (q == null)) return false;
        if (p != null and !p.?.eql(q.?)) return false;
    };
    return true;
}

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
    return resolveIn(theme, d, user, &.{});
}

/// The palette of a subtree whose scopes compose to `ctx`: the window's
/// layers in the variant `ctx` picks, then its overrides on top.
pub fn resolveIn(theme: *const Theme, d: DesktopInput, user: *const User, ctx: *const Context) Palette {
    const desktop_dark = if (user.scheme) |s| s == .dark else d.dark;
    const window_dark = switch (theme.scheme) {
        .follow => desktop_dark,
        .light => false,
        .dark => true,
    };
    const dark = ctx.invert != switch (ctx.scheme) {
        .window => window_dark,
        .desktop => desktop_dark,
        .light => false,
        .dark => true,
    };
    const high = ctx.high_contrast or switch (theme.contrast) {
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
    // In order: the application's defaults (all or nothing: a user
    // theme fills its gaps from the compiled palette, so every
    // application looks the same under it), the desktop (its accent,
    // applied apart), the user's theme, the application's overrides,
    // the subtree's.
    const layers = [_]*const [token_count]?Color{ if (user.source == .none) &theme.defaults[v] else &none, &none, if (high) &none else &user.colors[@intFromBool(dark)], &theme.overrides[v], &ctx.overrides[v] };
    const a = @intFromEnum(ColorToken.accent);
    const desktop_accent: ?Color = if (d.accent) |c| .srgb(@floatCast(c[0]), @floatCast(c[1]), @floatCast(c[2]), 1) else null;
    // The accent's layer: 0 compiled, else 1 + its index in `layers`.
    var level: usize = 0;
    for (layers, 1..) |layer, l| {
        for (layer, 0..) |o, i| if (o) |c| {
            p.colors[i] = c;
        };
        if (layer[a] != null) level = l;
        if (l == 2) if (desktop_accent) |c| {
            p.colors[a] = c;
            level = l;
        };
    }
    // Layers at or above the accent's keep the derived colors they set;
    // those below it give way to the accent.
    if (level > 0) derive(&p, layers[level - 1 ..], high);
    return p;
}

/// The colors `derive` sets.
const derived_tokens = [_]ColorToken{ .accent_hover, .accent_active, .accent_fg, .focus_ring, .selection_bg, .selection_fg };

/// Colors derived from a replaced accent, over the final view background,
/// except those one of `keep` sets.
fn derive(p: *Palette, keep: []const *const [token_count]?Color, high: bool) void {
    const accent = p.color(.accent);
    const dark = p.variant == .dark or p.variant == .dark_high_contrast;
    const shade: Color = if (dark) .white else .black;
    const on = onColor(accent);
    const values = [derived_tokens.len]Color{
        mix(accent, shade, 0.12),
        mix(accent, shade, 0.24),
        on,
        accent,
        if (high) accent else mix(p.color(.view_bg), accent, 0.3),
        if (high) on else p.color(.selection_fg),
    };
    next: for (derived_tokens, values) |t, c| {
        for (keep) |layer| if (layer[@intFromEnum(t)] != null) continue :next;
        set(p, t, c);
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
        .sidebar_bg = 0xededf0, .secondary_sidebar_bg = 0xf6f6f8, .shadow = .{ 0x000000, 0x2e },
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
        .sidebar_bg = 0x1c1c20, .secondary_sidebar_bg = 0x131316, .shadow = .{ 0x000000, 0xa6 },
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
        .sidebar_bg = 0xe6e6e6, .secondary_sidebar_bg = 0xf2f2f2, .shadow = .{ 0x000000, 0x40 },
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
        .sidebar_bg = 0x1f1f1f, .secondary_sidebar_bg = 0x101010, .shadow = .{ 0x000000, 0xb3 },
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

test "the application's defaults replace the compiled palette beneath the desktop, without a user theme" {
    const tok = struct {
        fn f(t: ColorToken) usize {
            return @intFromEnum(t);
        }
    }.f;
    const paper = Color.srgb8(0xf7, 0xf7, 0xf5, 0xff);
    const ink = Color.srgb8(0x1f, 0x1f, 0x1f, 0xff);
    const teal = Color.srgb8(0x00, 0x80, 0x80, 0xff);
    var th: Theme = .{};
    th.defaults[0][tok(.view_bg)] = paper;
    th.defaults[0][tok(.view_fg)] = ink;
    th.defaults[0][tok(.accent)] = teal;
    // Alone, they stand in for the compiled colors, and the colors
    // derived from their accent mix over their view background.
    var p = resolve(&th, .{}, &.{});
    try std.testing.expect(p.color(.view_bg).eql(paper));
    try std.testing.expect(p.color(.accent).eql(teal));
    try std.testing.expect(p.color(.selection_bg).eql(mix(paper, teal, 0.3)));
    try std.testing.expect(p.color(.border).eql(compiled[0][tok(.border)]));
    // The desktop's accent wins over theirs.
    p = resolve(&th, .{ .accent = .{ 1, 0, 0 } }, &.{});
    try std.testing.expect(p.color(.accent).eql(Color.srgb(1, 0, 0, 1)));
    try std.testing.expect(p.color(.selection_bg).eql(mix(paper, Color.srgb(1, 0, 0, 1), 0.3)));
    // Any user theme replaces them whole: its gaps fill from the
    // compiled palette, as in every other application.
    const view = Color.srgb8(0xfa, 0xf4, 0xed, 0xff);
    var u: User = .{ .source = .omarchy, .scheme = .light };
    u.colors[0][tok(.view_bg)] = view;
    p = resolve(&th, .{}, &u);
    try std.testing.expect(p.color(.view_bg).eql(view));
    try std.testing.expect(p.color(.view_fg).eql(compiled[0][tok(.view_fg)]));
    try std.testing.expect(p.color(.accent).eql(compiled[0][tok(.accent)]));
    // Other variants keep the compiled colors.
    try std.testing.expect(resolve(&th, .{ .dark = true }, &.{}).color(.view_bg).eql(compiled[1][tok(.view_bg)]));
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

test "a subtree's scheme: forced, inverse of the enclosing one, or the desktop's" {
    const tok = struct {
        fn f(t: ColorToken) usize {
            return @intFromEnum(t);
        }
    }.f;
    var th: Theme = .{};
    const light: DesktopInput = .{};
    const dark: DesktopInput = .{ .dark = true };
    const window: Context = .{};
    const always_dark = window.within(&.{ .scheme = .dark });
    const inverse = window.within(&.{ .scheme = .inverse });
    try std.testing.expectEqual(Variant.dark, resolveIn(&th, light, &.{}, &always_dark).variant);
    try std.testing.expectEqual(Variant.dark, resolveIn(&th, dark, &.{}, &always_dark).variant);
    try std.testing.expectEqual(Variant.dark, resolveIn(&th, light, &.{}, &inverse).variant);
    try std.testing.expectEqual(Variant.light, resolveIn(&th, dark, &.{}, &inverse).variant);
    // Inverse inside inverse is the window's again; inside a forced
    // scheme it is the opposite of that one.
    try std.testing.expectEqual(Variant.dark, resolveIn(&th, dark, &.{}, &inverse.within(&.{ .scheme = .inverse })).variant);
    try std.testing.expectEqual(Variant.light, resolveIn(&th, dark, &.{}, &always_dark.within(&.{ .scheme = .inverse })).variant);
    // Inherit keeps the enclosing choice, inversion included.
    try std.testing.expectEqual(Variant.light, resolveIn(&th, dark, &.{}, &inverse.within(&.{})).variant);
    // Follow is the desktop's even where the application fixed the
    // window's scheme and an enclosing subtree fixed its own.
    th.scheme = .light;
    const follow = always_dark.within(&.{ .scheme = .follow });
    try std.testing.expectEqual(Variant.light, resolveIn(&th, dark, &.{}, &window).variant);
    try std.testing.expectEqual(Variant.dark, resolveIn(&th, dark, &.{}, &follow).variant);
    try std.testing.expectEqual(Variant.light, resolveIn(&th, light, &.{}, &follow).variant);
    th.scheme = .follow;
    // High contrast from the desktop reaches a dark subtree in its
    // scheme; a subtree raises contrast but never lowers it.
    try std.testing.expectEqual(Variant.dark_high_contrast, resolveIn(&th, .{ .high_contrast = true }, &.{}, &always_dark).variant);
    try std.testing.expectEqual(Variant.light_high_contrast, resolveIn(&th, light, &.{}, &window.within(&.{ .high_contrast = true })).variant);
    try std.testing.expectEqual(Variant.dark_high_contrast, resolveIn(&th, .{ .high_contrast = true }, &.{}, &always_dark.within(&.{})).variant);
    // The desktop's accent and the user's theme reach the subtree in its
    // variant; the compiled colors fill the rest.
    const view = Color.srgb8(0x1a, 0x1b, 0x26, 0xff);
    var u: User = .{ .source = .file };
    u.colors[@intFromEnum(Scheme.dark)][tok(.view_bg)] = view;
    const p = resolveIn(&th, .{ .accent = .{ 1, 0, 0 } }, &u, &always_dark);
    try std.testing.expect(p.color(.view_bg).eql(view));
    try std.testing.expect(p.color(.accent).eql(Color.srgb(1, 0, 0, 1)));
    try std.testing.expect(p.color(.border).eql(compiled[1][tok(.border)]));
}

test "a subtree's colors override the application's, and its accent moves what derives from it" {
    const tok = struct {
        fn f(t: ColorToken) usize {
            return @intFromEnum(t);
        }
    }.f;
    const green = Color.srgb(0, 1, 0, 1);
    const purple = Color.srgb8(0x7c, 0x3a, 0xed, 0xff);
    const sel = Color.srgb8(0x33, 0x33, 0x33, 0xff);
    var th: Theme = .{};
    th.overrides[0][tok(.focus_ring)] = .white;
    th.overrides[0][tok(.view_bg)] = .black;
    var accent: Scope = .{};
    for (&accent.overrides) |*o| o[tok(.accent)] = purple;
    const outer = (Context{}).within(&accent);
    var p = resolveIn(&th, .{ .accent = .{ 1, 0, 0 } }, &.{}, &outer);
    // Over the desktop's accent and the application's focus ring.
    try std.testing.expect(p.color(.accent).eql(purple));
    try std.testing.expect(p.color(.focus_ring).eql(purple));
    try std.testing.expect(p.color(.selection_bg).eql(mix(.black, purple, 0.3)));
    try std.testing.expect(p.color(.view_bg).eql(.black));
    // A nested scope keeps the accent; its own selection stays.
    var inner: Scope = .{};
    inner.overrides[0][tok(.selection_bg)] = sel;
    const nested = outer.within(&inner);
    p = resolveIn(&th, .{}, &.{}, &nested);
    try std.testing.expect(p.color(.accent).eql(purple));
    try std.testing.expect(p.color(.selection_bg).eql(sel));
    // A scope's accent inside it moves the outer scope's selection.
    var again: Scope = .{};
    again.overrides[0][tok(.accent)] = green;
    p = resolveIn(&th, .{}, &.{}, &nested.within(&again));
    try std.testing.expect(p.color(.selection_bg).eql(mix(.black, green, 0.3)));
    try std.testing.expect(p.color(.focus_ring).eql(green));
    // Overrides apply to their variant only.
    p = resolveIn(&th, .{ .dark = true }, &.{}, &nested);
    try std.testing.expect(p.color(.selection_bg).eql(mix(compiled[1][tok(.view_bg)], purple, 0.3)));
    // An empty context is the window's palette.
    try std.testing.expect(resolveIn(&th, .{}, &.{}, &.{}).eqlColors(&resolve(&th, .{}, &.{})));
}
