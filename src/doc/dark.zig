//! Converting a light document's colors to dark ones (D32,
//! `convert_colors`): partial inversion, as Outlook and the Gmail app do
//! it, applied to computed colors as they are painted. Light backgrounds
//! become dark ones near the target's background, lighter colors darker,
//! so that a card stays a step above the page; dark text on them becomes
//! light, at the contrast it had scaled to the target's text, and never
//! less readable than it was (up to WCAG's 4.5); hues and some chroma are
//! kept (colorful backgrounds stay a little lighter, to have room for it), and neutral colors take the target's tint, so that white is the
//! target's background exactly and black its text. Borders follow
//! (light ones as backgrounds, dark ones as text). Backgrounds already
//! dark, and whatever is in front of them, stay. Images are not colors
//! and are left alone.

const std = @import("std");
const css = @import("css");

const Color = css.Color;
const cm = css.color;
const V3 = [3]f64;

/// The colors a document is converted toward (sRGB).
pub const Target = struct { bg: Color, fg: Color };

/// How much a converted background's lightness moves for a step of the
/// original's: above 1, so near-white surfaces stay apart in the dark.
const slope = 1.4;
/// Chroma kept by converted backgrounds, and how much lighter chroma
/// keeps them.
const bg_chroma = 0.8;
const chroma_lift = 1.2;
/// Below this chroma (OKLab) a color counts as neutral and takes the
/// target's tint.
const neutral = 0.04;
/// The contrast converted text keeps at least, unless it had less.
const min_contrast = 4.5;

pub const Map = struct {
    bg: V3,
    fg: V3,
    /// The contrast of the target's text on its background.
    fg_contrast: f64,
    /// Backgrounds lighter than this (OKLab L) are converted; it is where
    /// the conversion meets the identity.
    pivot: f64,

    pub fn init(t: Target) Map {
        const bg = lab(t.bg);
        const fg = lab(t.fg);
        return .{
            .bg = bg,
            .fg = fg,
            .fg_contrast = contrast(luminance(t.fg), luminance(t.bg)),
            .pivot = (bg[0] + slope) / (1 + slope),
        };
    }

    /// Whether a background is light, and so converted.
    pub fn light(m: *const Map, c: Color) bool {
        return c.a > 0 and lab(c)[0] > m.pivot;
    }

    /// A background (or a light border): light ones become dark.
    pub fn background(m: *const Map, c: Color) Color {
        if (c.kind != .rgba or c.a == 0) return c;
        const v = lab(c);
        if (v[0] <= m.pivot) return c;
        // Colorful ones stay lighter, where there is room for their
        // chroma (a yellow button stays golden rather than olive).
        const lift = chroma_lift * @min(@sqrt(v[1] * v[1] + v[2] * v[2]), 0.15);
        return fromLab(tint(v, m.bg, @min(v[0], m.bg[0] + (1 - v[0]) * slope + lift), bg_chroma), c.a);
    }

    /// Text in front of `behind`, the opaque background it had: dark
    /// text on a light background becomes light, at the contrast it had
    /// mapped from 1..21 onto 1..the target's text contrast, at least
    /// `floor` (or what it had, if less).
    pub fn text(m: *const Map, c: Color, behind: Color, floor: f64) Color {
        if (c.kind != .rgba or c.a == 0 or !m.light(behind)) return c;
        const shown = over(c, behind);
        const yb = luminance(behind);
        const yt = luminance(shown);
        if (yt >= yb) return c;
        const had = contrast(yb, yt);
        const nb = m.background(behind);
        const ynb = luminance(nb);
        var want = std.math.pow(f64, m.fg_contrast, @log(had) / @log(21.0));
        want = @max(want, @min(had, floor));
        const target = @min(1, want * (ynb + 0.05) - 0.05);
        // The lightness (above the new background's) whose color, with
        // this hue and chroma, has the luminance wanted.
        const v = lab(shown);
        var lo = lab(nb)[0];
        var hi: f64 = 1;
        for (0..20) |_| {
            const mid = (lo + hi) / 2;
            if (luminance(fromLab(tint(v, m.fg, mid, 1), 1)) < target) lo = mid else hi = mid;
        }
        return fromLab(tint(v, m.fg, hi, 1), 1);
    }

    /// A border, rule, or outline in front of `behind`: light ones as
    /// backgrounds, dark ones as text keeping their relative contrast.
    pub fn border(m: *const Map, c: Color, behind: Color) Color {
        if (c.kind != .rgba or c.a == 0) return c;
        if (lab(c)[0] > m.pivot) return m.background(c);
        return m.text(c, behind, 1);
    }
};

/// `v` at lightness `l`, its chroma scaled by `keep`, and as neutral as
/// it is, the tint of `toward` instead.
fn tint(v: V3, toward: V3, l: f64, keep: f64) V3 {
    const w = std.math.clamp(1 - @sqrt(v[1] * v[1] + v[2] * v[2]) / neutral, 0, 1);
    return .{ l, v[1] * keep * (1 - w) + toward[1] * w, v[2] * keep * (1 - w) + toward[2] * w };
}

fn lab(c: Color) V3 {
    return cm.fromLinearSrgb(.oklab, cm.toLinearSrgb(.srgb, .{ c.r, c.g, c.b }));
}

fn inGamut(v: V3) bool {
    const l = cm.toLinearSrgb(.oklab, v);
    for (l) |x| if (x < -1e-4 or x > 1 + 1e-4) return false;
    return true;
}

/// An OKLab color in sRGB, its chroma reduced until it fits.
fn fromLab(v: V3, alpha: f32) Color {
    var fit = v;
    if (!inGamut(v)) {
        var lo: f64 = 0;
        var hi: f64 = 1;
        for (0..16) |_| {
            const mid = (lo + hi) / 2;
            if (inGamut(.{ v[0], v[1] * mid, v[2] * mid })) lo = mid else hi = mid;
        }
        fit = .{ v[0], v[1] * lo, v[2] * lo };
    }
    return cm.fromSpace(.oklab, fit, alpha);
}

/// `c` composited over an opaque `bg`.
fn over(c: Color, bg: Color) Color {
    const a = c.a;
    return .{ .r = c.r * a + bg.r * (1 - a), .g = c.g * a + bg.g * (1 - a), .b = c.b * a + bg.b * (1 - a), .a = 1 };
}

fn luminance(c: Color) f64 {
    const l = cm.toLinearSrgb(.srgb, .{ c.r, c.g, c.b });
    return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2];
}

/// WCAG's contrast ratio of two luminances.
fn contrast(a: f64, b: f64) f64 {
    return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
}

const testing = std.testing;

fn hex(v: u24) Color {
    return .rgb8(@truncate(v >> 16), @truncate(v >> 8), @truncate(v));
}

fn expectNear(want: Color, got: Color) !void {
    try testing.expectApproxEqAbs(want.r, got.r, 1.0 / 255.0);
    try testing.expectApproxEqAbs(want.g, got.g, 1.0 / 255.0);
    try testing.expectApproxEqAbs(want.b, got.b, 1.0 / 255.0);
}

const tokyo: Target = .{ .bg = hex(0x1a1b26), .fg = hex(0xa9b1d6) };

test "white and black become the target's background and text" {
    const m = Map.init(tokyo);
    try expectNear(tokyo.bg, m.background(Color.white));
    try expectNear(tokyo.fg, m.text(Color.black, Color.white, min_contrast));
}

test "lighter backgrounds become darker ones, a card a step above the page" {
    const m = Map.init(tokyo);
    const page = lab(m.background(Color.white))[0];
    const card = lab(m.background(hex(0xf5f6f3)))[0];
    const circle = lab(m.background(hex(0xe8eae6)))[0];
    try testing.expect(page < card and card < circle);
    try testing.expect(card - page > 0.03);
    // Dark and mid backgrounds (a saturated button, a dark band) stay.
    try testing.expect(m.background(hex(0x1a73e8)).eql(hex(0x1a73e8)));
    try testing.expect(m.background(hex(0x222222)).eql(hex(0x222222)));
}

test "dark text becomes light and readable, keeping its hue and order" {
    const m = Map.init(tokyo);
    const bg = m.background(Color.white);
    const body = m.text(hex(0x171b17), Color.white, min_contrast);
    const muted = m.text(hex(0x60655e), Color.white, min_contrast);
    try testing.expect(luminance(body) > luminance(muted));
    try testing.expect(contrast(luminance(muted), luminance(bg)) >= min_contrast - 0.01);
    // A purple link stays purple: its OKLab hue within a few degrees.
    const link = hex(0x65408b);
    const got = m.text(link, Color.white, min_contrast);
    const h0 = std.math.atan2(lab(link)[2], lab(link)[1]);
    const h1 = std.math.atan2(lab(got)[2], lab(got)[1]);
    try testing.expectApproxEqAbs(h0, h1, 0.12);
    try testing.expect(contrast(luminance(got), luminance(bg)) >= min_contrast - 0.01);
    // Light text, and text on a background that stays, stay.
    try testing.expect(m.text(Color.white, hex(0xe91e63), min_contrast).eql(Color.white));
    try testing.expect(m.text(Color.black, hex(0x1a73e8), min_contrast).eql(Color.black));
    // Text that was faint stays as faint as it was, not fainter.
    const faint = hex(0xaaaaaa);
    const had = contrast(luminance(faint), 1);
    try testing.expect(contrast(luminance(m.text(faint, Color.white, min_contrast)), luminance(bg)) >= had - 0.01);
}

test "borders: light ones as backgrounds, dark ones as text" {
    const m = Map.init(tokyo);
    const bg = m.background(Color.white);
    const rule = m.border(hex(0xe8ebe4), Color.white);
    try testing.expect(luminance(rule) > luminance(bg) and luminance(rule) < 0.1);
    try testing.expect(luminance(m.border(Color.black, Color.white)) > 0.3);
}
