//! The user's theme (D29): `$XDG_CONFIG_HOME/siv/theme.toml`, siv's own
//! format, and Omarchy's `colors.toml`, parsed and mapped to color tokens.
//! Bytes in, a `theme.User` out; the application reads and watches the
//! files (src/app/user_theme.zig). Whatever does not parse is skipped, so
//! its tokens keep the compiled colors.
//!
//! theme.toml sets tokens by their names (`siv_color_token` without the
//! prefix, lowercase), for both schemes at the top level and for one in
//! a `[light]` or `[dark]` table, which wins:
//!
//!     scheme = "dark"      # optional: the theme is for this scheme only
//!     base = "omarchy"     # optional: start from Omarchy's theme
//!     accent = "#7aa2f7"
//!     [dark]
//!     view_bg = "#1a1b26"
//!
//! Colors are "#rgb", "#rrggbb", or "#rrggbbaa", sRGB.

const std = @import("std");
const scene = @import("scene");
const theme = @import("theme.zig");

const Color = scene.Color;
const ColorToken = theme.ColorToken;
const User = theme.User;
const Scheme = theme.Scheme;
const token_count = theme.token_count;

/// Largest file read; a larger one is not a theme.
pub const max_bytes = 64 * 1024;

// TOML ------------------------------------------------------------------------

/// The part of TOML themes use: comments, `[table]` headers, and
/// `key = value` lines with basic and literal strings, integers, floats,
/// and booleans. Lines that do not parse are skipped, as are arrays,
/// inline tables, multi-line strings, and every entry under an array of
/// tables or a header that does not parse, so nothing lands in a table
/// it was not written in.
pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    table: []const u8 = "",
    /// Entries belong to `table`; false under an array of tables or a
    /// header that did not parse.
    in_table: bool = true,
    buf: [max_string]u8 = undefined,
    /// Unescapes basic strings here instead of `buf`, for longer ones:
    /// settings files hold paths (D36).
    long: ?[]u8 = null,

    pub const max_string = 256;

    pub const Value = union(enum) {
        /// Valid until the next call to `next`.
        string: []const u8,
        integer: i64,
        float: f64,
        boolean: bool,
    };

    pub const Entry = struct {
        /// The header's text without brackets and outer spaces; "" at the
        /// top level.
        table: []const u8,
        /// As written; a dotted key keeps its dots.
        key: []const u8,
        value: Value,
    };

    pub fn init(src: []const u8) Parser {
        const bom = "\xef\xbb\xbf";
        return .{ .src = src, .pos = if (std.mem.startsWith(u8, src, bom)) bom.len else 0 };
    }

    pub fn next(p: *Parser) ?Entry {
        while (p.pos < p.src.len) {
            const start = p.pos;
            const e = p.line();
            std.debug.assert(p.pos > start or p.pos >= p.src.len);
            if (e) |en| if (p.in_table) return en;
        }
        return null;
    }

    /// One line (or a multi-line value): an entry, or null for anything
    /// else; leaves `pos` at the start of the next line.
    fn line(p: *Parser) ?Entry {
        p.spaces();
        if (p.pos >= p.src.len) return null;
        switch (p.src[p.pos]) {
            '\n', '\r', '#' => {
                p.toEol();
                return null;
            },
            '[' => {
                p.header();
                p.toEol();
                return null;
            },
            else => {},
        }
        const e = p.entry() orelse {
            p.toEol();
            return null;
        };
        if (!p.endOfLine()) {
            p.toEol();
            return null;
        }
        p.toEol();
        return e;
    }

    fn header(p: *Parser) void {
        p.in_table = false;
        p.pos += 1;
        if (p.peek() == '[') return;
        const close = std.mem.indexOfAnyPos(u8, p.src, p.pos, "]\n") orelse return;
        if (p.src[close] != ']') return;
        const name = std.mem.trim(u8, p.src[p.pos..close], " \t");
        if (name.len == 0) return;
        for (name) |ch| if (!bare(ch) and ch != '.') return;
        p.pos = close + 1;
        if (!p.endOfLine()) return;
        p.table = name;
        p.in_table = true;
    }

    fn entry(p: *Parser) ?Entry {
        const start = p.pos;
        while (true) {
            if (!p.keyPart()) return null;
            const end = p.pos;
            p.spaces();
            if (p.peek() == '.') {
                p.pos += 1;
                p.spaces();
                continue;
            }
            const key = p.src[start..end];
            if (p.peek() != '=') return null;
            p.pos += 1;
            p.spaces();
            const v = p.value() orelse return null;
            return .{ .table = p.table, .key = key, .value = v };
        }
    }

    fn keyPart(p: *Parser) bool {
        const q = p.peek() orelse return false;
        if (q == '"' or q == '\'') {
            const close = std.mem.indexOfAnyPos(u8, p.src, p.pos + 1, &.{ q, '\n', '\\' }) orelse return false;
            if (p.src[close] != q) return false;
            p.pos = close + 1;
            return true;
        }
        const start = p.pos;
        while (p.peek()) |ch| {
            if (!bare(ch)) break;
            p.pos += 1;
        }
        return p.pos > start;
    }

    fn value(p: *Parser) ?Value {
        const ch = p.peek() orelse return null;
        switch (ch) {
            '"', '\'' => {
                if (std.mem.startsWith(u8, p.src[p.pos..], &.{ ch, ch, ch })) {
                    // Multi-line strings: skipped whole.
                    const close = std.mem.indexOfPos(u8, p.src, p.pos + 3, &.{ ch, ch, ch }) orelse p.src.len;
                    p.pos = @min(close + 3, p.src.len);
                    return null;
                }
                return if (ch == '"') p.basic() else p.literal();
            },
            '[', '{' => {
                p.skipNested();
                return null;
            },
            else => {},
        }
        const start = p.pos;
        while (p.peek()) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '+' or c == '-')) break;
            p.pos += 1;
        }
        const word = p.src[start..p.pos];
        if (std.mem.eql(u8, word, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, word, "false")) return .{ .boolean = false };
        if (word.len == 0 or word.len > 64) return null;
        // Digits with single underscores between them, as TOML allows.
        var digits: [64]u8 = undefined;
        var n: usize = 0;
        for (word, 0..) |c, i| {
            if (c == '_') {
                if (i == 0 or i + 1 == word.len or !std.ascii.isDigit(word[i - 1]) or !std.ascii.isDigit(word[i + 1])) return null;
                continue;
            }
            digits[n] = c;
            n += 1;
        }
        const num = digits[0..n];
        const body = if (num[0] == '+' or num[0] == '-') num[1..] else num;
        if (body.len == 0 or !std.ascii.isDigit(body[0])) return null;
        if (std.mem.indexOfAny(u8, body, ".eE") == null) {
            return .{ .integer = std.fmt.parseInt(i64, num, 10) catch return null };
        }
        for (body) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-')) return null;
        const f = std.fmt.parseFloat(f64, num) catch return null;
        return if (std.math.isFinite(f)) .{ .float = f } else null;
    }

    fn basic(p: *Parser) ?Value {
        p.pos += 1;
        const buf = p.long orelse &p.buf;
        var n: usize = 0;
        while (p.peek()) |ch| {
            p.pos += 1;
            var out: [4]u8 = undefined;
            var len: usize = 1;
            switch (ch) {
                '"' => return .{ .string = buf[0..n] },
                '\\' => {
                    const e = p.peek() orelse return null;
                    p.pos += 1;
                    out[0] = switch (e) {
                        'b' => 8,
                        't' => '\t',
                        'n' => '\n',
                        'f' => 12,
                        'r' => '\r',
                        '"' => '"',
                        '\\' => '\\',
                        'u', 'U' => blk: {
                            const digits: usize = if (e == 'u') 4 else 8;
                            if (p.pos + digits > p.src.len) return null;
                            const cp = std.fmt.parseInt(u21, p.src[p.pos..][0..digits], 16) catch return null;
                            p.pos += digits;
                            len = std.unicode.utf8Encode(cp, &out) catch return null;
                            break :blk out[0];
                        },
                        else => return null,
                    };
                },
                else => {
                    if ((ch < 0x20 and ch != '\t') or ch == 0x7f) return null;
                    out[0] = ch;
                },
            }
            if (n + len > buf.len) return null;
            @memcpy(buf[n..][0..len], out[0..len]);
            n += len;
        }
        return null;
    }

    fn literal(p: *Parser) ?Value {
        const close = std.mem.indexOfAnyPos(u8, p.src, p.pos + 1, "'\n") orelse return null;
        if (p.src[close] != '\'') return null;
        const s = p.src[p.pos + 1 .. close];
        for (s) |ch| if ((ch < 0x20 and ch != '\t') or ch == 0x7f) return null;
        p.pos = close + 1;
        return .{ .string = s };
    }

    /// Skips an array or inline table, across lines, minding strings and
    /// comments.
    fn skipNested(p: *Parser) void {
        var depth: usize = 0;
        while (p.peek()) |ch| {
            p.pos += 1;
            switch (ch) {
                '[', '{' => depth += 1,
                ']', '}' => {
                    depth -|= 1;
                    if (depth == 0) return;
                },
                '"', '\'' => while (p.peek()) |c| {
                    p.pos += 1;
                    if (c == '\\' and ch == '"') {
                        if (p.pos < p.src.len) p.pos += 1;
                    } else if (c == ch or c == '\n') break;
                },
                '#' => p.toEolKeep(),
                else => {},
            }
        }
    }

    /// Only spaces and a comment are left on the line.
    fn endOfLine(p: *Parser) bool {
        p.spaces();
        const ch = p.peek() orelse return true;
        if (ch == '#' or ch == '\n') return true;
        return ch == '\r' and (p.pos + 1 == p.src.len or p.src[p.pos + 1] == '\n');
    }

    fn spaces(p: *Parser) void {
        while (p.peek()) |ch| {
            if (ch != ' ' and ch != '\t') break;
            p.pos += 1;
        }
    }

    /// Past the next newline.
    fn toEol(p: *Parser) void {
        p.toEolKeep();
        if (p.pos < p.src.len) p.pos += 1;
    }

    /// To the next newline.
    fn toEolKeep(p: *Parser) void {
        p.pos = std.mem.indexOfScalarPos(u8, p.src, p.pos, '\n') orelse p.src.len;
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn bare(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
    }
};

// Colors ----------------------------------------------------------------------

/// sRGB, 8 bits per component.
const Rgba = [4]u8;

/// "#rgb", "#rrggbb", or "#rrggbbaa".
fn parseHex(s: []const u8) ?Rgba {
    if (s.len < 1 or s[0] != '#') return null;
    const h = s[1..];
    for (h) |ch| if (!std.ascii.isHex(ch)) return null;
    const byte = struct {
        fn f(x: []const u8) u8 {
            return std.fmt.parseInt(u8, x, 16) catch unreachable;
        }
    }.f;
    return switch (h.len) {
        3 => .{ byte(&.{ h[0], h[0] }), byte(&.{ h[1], h[1] }), byte(&.{ h[2], h[2] }), 0xff },
        6 => .{ byte(h[0..2]), byte(h[2..4]), byte(h[4..6]), 0xff },
        8 => .{ byte(h[0..2]), byte(h[2..4]), byte(h[4..6]), byte(h[6..8]) },
        else => null,
    };
}

pub fn parseColor(s: []const u8) ?Color {
    const c = parseHex(s) orelse return null;
    return color(c);
}

fn color(c: Rgba) Color {
    return .srgb8(c[0], c[1], c[2], c[3]);
}

/// Mixed in sRGB, rounded, as Omarchy's templates mix (its `mix`).
fn mix(a: Rgba, b: Rgba, k: f32) Rgba {
    var out: Rgba = undefined;
    for (&out, a, b) |*o, x, y| o.* = @intFromFloat(@as(f32, @floatFromInt(x)) * (1 - k) + @as(f32, @floatFromInt(y)) * k + 0.5);
    return out;
}

fn contrast(a: Rgba, b: Rgba) f32 {
    const la = color(a).luminance();
    const lb = color(b).luminance();
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

// theme.toml ------------------------------------------------------------------

pub const File = struct {
    theme: User,
    /// `base = "omarchy"`: lay the file over Omarchy's theme.
    omarchy: bool = false,
};

pub fn parseFile(src: []const u8) File {
    var out: File = .{ .theme = .{ .source = .file } };
    var both: [token_count]?Color = @splat(null);
    var p: Parser = .init(src);
    while (p.next()) |e| {
        const s = switch (e.value) {
            .string => |s| s,
            else => continue,
        };
        const slot: ?Scheme = if (e.table.len == 0) null else std.meta.stringToEnum(Scheme, e.table) orelse continue;
        if (slot == null) {
            if (std.mem.eql(u8, e.key, "scheme")) {
                out.theme.scheme = std.meta.stringToEnum(Scheme, s);
                continue;
            }
            if (std.mem.eql(u8, e.key, "base")) {
                out.omarchy = std.mem.eql(u8, s, "omarchy");
                continue;
            }
        }
        const t = std.meta.stringToEnum(ColorToken, e.key) orelse continue;
        if (t == .none) continue;
        const c = parseColor(s) orelse continue;
        if (slot) |sl| out.theme.colors[@intFromEnum(sl)][@intFromEnum(t)] = c else both[@intFromEnum(t)] = c;
    }
    for (&out.theme.colors) |*colors| for (colors, both) |*o, b| {
        if (o.* == null) o.* = b;
    };
    return out;
}

/// `top` over `base`: its scheme if it has one, and its colors.
pub fn overlay(base: User, top: User) User {
    var out = base;
    out.source = top.source;
    if (top.scheme) |s| out.scheme = s;
    for (&out.colors, top.colors) |*colors, t| for (colors, t) |*o, c| {
        if (c) |v| o.* = v;
    };
    return out;
}

// Omarchy ---------------------------------------------------------------------

/// The keys of Omarchy's colors.toml that siv reads (its docs/theming.md).
const Key = enum {
    accent,
    selection,
    muted,
    background,
    dark_background,
    darker_background,
    lighter_background,
    foreground,
    dark_foreground,
    light_foreground,
    bright_foreground,
    red,
    yellow,
    orange,
    green,
    cyan,
    blue,
    magenta,
    purple,
    bright_red,
    bright_yellow,
    bright_green,
    bright_cyan,
    bright_blue,
    bright_magenta,
    bright_purple,
    color0,
    color1,
    color2,
    color3,
    color4,
    color5,
    color6,
    color7,
    color8,
    color9,
    color10,
    color11,
    color12,
    color13,
    color14,
    color15,
    bg,
    dark_bg,
    darker_bg,
    lighter_bg,
    fg,
    dark_fg,
    light_fg,
    bright_fg,
};

const Palette = struct {
    v: std.EnumArray(Key, ?Rgba) = .initFill(null),

    fn get(p: *const Palette, k: Key) ?Rgba {
        return p.v.get(k);
    }

    /// `k` from the first of `from` that is set, unless it is set.
    fn alias(p: *Palette, k: Key, from: []const Key) void {
        if (p.get(k) != null) return;
        for (from) |f| if (p.get(f)) |c| {
            p.v.set(k, c);
            return;
        };
    }
};

/// Omarchy's colors.toml, as Omarchy itself resolves it (its
/// omarchy-theme-color: legacy short names, ANSI colors, derived
/// shades), mapped to tokens for its mode. `light_marker`: a light.mode
/// file lies beside it, the legacy way to mark a light theme.
pub fn omarchy(src: []const u8, light_marker: bool) User {
    var pal: Palette = .{};
    var mode: ?Scheme = null;
    var theme_type: ?Scheme = null;
    var p: Parser = .init(src);
    while (p.next()) |e| {
        if (e.table.len != 0) continue;
        const s = switch (e.value) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, e.key, "mode")) {
            mode = std.meta.stringToEnum(Scheme, s);
        } else if (std.mem.eql(u8, e.key, "theme_type")) {
            theme_type = std.meta.stringToEnum(Scheme, s);
        } else if (std.meta.stringToEnum(Key, e.key)) |k| {
            if (parseHex(s)) |c| pal.v.set(k, c);
        }
    }

    // The cascade of omarchy-theme-color's resolve_theme_colors, in its
    // order: canonical names over legacy ones, ANSI colors as fallbacks.
    const legacy = [_][2]Key{ .{ .background, .bg }, .{ .dark_background, .dark_bg }, .{ .darker_background, .darker_bg }, .{ .lighter_background, .lighter_bg }, .{ .foreground, .fg }, .{ .dark_foreground, .dark_fg }, .{ .light_foreground, .light_fg }, .{ .bright_foreground, .bright_fg } };
    for (legacy) |l| pal.alias(l[0], &.{l[1]});
    pal.alias(.background, &.{.color0});
    pal.alias(.foreground, &.{.color7});
    if (pal.get(.background)) |c| pal.v.set(.color0, c);
    if (pal.get(.foreground)) |c| pal.v.set(.color7, c);
    const ansi = [_][2]Key{ .{ .red, .color1 }, .{ .green, .color2 }, .{ .yellow, .color3 }, .{ .blue, .color4 }, .{ .magenta, .color5 }, .{ .cyan, .color6 }, .{ .bright_red, .color9 }, .{ .bright_green, .color10 }, .{ .bright_yellow, .color11 }, .{ .bright_blue, .color12 }, .{ .bright_magenta, .color13 }, .{ .bright_cyan, .color14 } };
    for (ansi) |l| pal.alias(l[0], &.{l[1]});
    pal.alias(.magenta, &.{.purple});
    pal.alias(.light_foreground, &.{ .color7, .foreground });
    pal.alias(.bright_foreground, &.{ .color15, .foreground });
    pal.alias(.lighter_background, &.{ .color0, .background });
    pal.alias(.dark_foreground, &.{ .color8, .foreground });
    pal.alias(.muted, &.{ .color8, .dark_foreground });
    pal.alias(.selection, &.{ .color8, .color0, .background });
    pal.alias(.orange, &.{.yellow});
    const black: Rgba = .{ 0, 0, 0, 0xff };
    if (pal.get(.background)) |b| {
        if (pal.get(.dark_background) == null) pal.v.set(.dark_background, mix(b, black, 0.25));
        if (pal.get(.darker_background) == null) pal.v.set(.darker_background, mix(b, black, 0.5));
    }
    pal.alias(.accent, &.{.blue});

    // Its mode: `mode`, the legacy `theme_type`, a light.mode file, the
    // background's brightness, dark.
    const scheme: Scheme = mode orelse theme_type orelse if (light_marker) .light else if (pal.get(.background)) |b|
        (if (@as(u32, b[0]) + b[1] + b[2] > 382) .light else .dark)
    else
        .dark;
    var out: User = .{ .source = .omarchy, .scheme = scheme };
    mapOmarchy(&pal, scheme, &out.colors[@intFromEnum(scheme)]);
    return out;
}

/// Omarchy's palette as tokens. Its neutral ramp runs from `background`
/// to `bright_foreground` (darkest to lightest in dark themes, lightest
/// to darkest in light ones), with `dark_background` and
/// `darker_background` recessed from the background and
/// `lighter_background` a step toward the text.
fn mapOmarchy(pal: *const Palette, scheme: Scheme, out: *[token_count]?Color) void {
    const set = struct {
        fn f(o: *[token_count]?Color, t: ColorToken, c: Rgba) void {
            o[@intFromEnum(t)] = color(c);
        }
    }.f;
    if (pal.get(.accent)) |a| set(out, .accent, a);
    if (pal.get(.red)) |r| {
        set(out, .destructive, r);
        set(out, .destructive_fg, onColor(r));
    }
    if (pal.get(.green)) |g| set(out, .success, g);
    if (pal.get(.yellow)) |y| set(out, .warning, y);
    // Surfaces and text need both ends of the ramp.
    const bg = pal.get(.background) orelse return;
    const fg = pal.get(.foreground) orelse return;
    const dark = scheme == .dark;
    // The cascade above fills these whenever the background is set.
    const dbg = pal.get(.dark_background).?;
    const ddbg = pal.get(.darker_background).?;
    const lbg = pal.get(.lighter_background).?;
    const muted = pal.get(.muted).?;
    const bright = pal.get(.bright_foreground).?;
    const accent = pal.get(.accent) orelse fg;

    set(out, .view_bg, bg);
    set(out, .view_fg, fg);
    set(out, .window_bg, dbg);
    set(out, .window_fg, fg);
    set(out, .sidebar_bg, ddbg);
    set(out, .secondary_sidebar_bg, dbg);
    // Raised surfaces: a step toward the text in dark themes, the
    // lightest surface in light ones.
    set(out, .card_bg, if (dark) lbg else bg);
    set(out, .card_fg, fg);
    set(out, .control_bg, lbg);
    set(out, .control_hover, mix(lbg, fg, 0.1));
    set(out, .control_active, mix(lbg, fg, 0.2));
    set(out, .control_fg, fg);
    set(out, .border, muted);
    set(out, .separator, mix(bg, muted, 0.6));
    set(out, .track, mix(lbg, muted, 0.5));
    // Knobs ride on the track and on the accent: light, unless the
    // accent is too light for it (kanagawa's is its text color).
    const knob = if (dark) mix(bright, .{ 0xff, 0xff, 0xff, 0xff }, 0.5) else bg;
    set(out, .knob, if (contrast(knob, accent) >= 1.6) knob else if (dark) bg else fg);
    // Halfway to the background: Omarchy's dark_foreground where a theme
    // keeps its ramp even, and still legible where it does not (white's
    // is its control color).
    set(out, .disabled_fg, mix(fg, bg, 0.5));
    set(out, .muted_fg, readable(fg, bg, &.{ bg, dbg, ddbg }));
    const sel = selection(pal.get(.selection).?, accent, &.{ bg, dbg, ddbg });
    set(out, .selection_bg, sel);
    const on_sel = if (contrast(bright, sel) >= contrast(fg, sel)) bright else fg;
    set(out, .selection_fg, if (contrast(on_sel, sel) >= 4.5) on_sel else onColor(sel));
    set(out, .inverse_bg, fg);
    set(out, .inverse_fg, bg);
}

/// Omarchy's selection is a stop on its ramp for selected text on the
/// background; selected rows also sit on the sidebars, which in light
/// themes can be as dark. Tinted toward the accent until it stands out
/// (1.2:1) from every one of `under`.
fn selection(sel: Rgba, accent: Rgba, under: []const Rgba) Rgba {
    var k: f32 = 0;
    while (k <= 0.6 + 1e-3) : (k += 0.05) {
        const c = mix(sel, accent, k);
        for (under) |u| {
            if (contrast(c, u) < 1.2) break;
        } else return c;
    }
    return mix(sel, accent, 0.6);
}

/// The dimmest mix of `fg` toward `bg`, up to 40%, that keeps 4.5:1
/// against every one of `under`: secondary text that stays readable.
fn readable(fg: Rgba, bg: Rgba, under: []const Rgba) Rgba {
    var best = fg;
    var k: f32 = 0.05;
    while (k <= 0.4 + 1e-3) : (k += 0.05) {
        const c = mix(fg, bg, k);
        for (under) |u| if (contrast(c, u) < 4.5) return best;
        best = c;
    }
    return best;
}

fn onColor(bg: Rgba) Rgba {
    return if (theme.onColor(color(bg)).eql(.white)) .{ 0xff, 0xff, 0xff, 0xff } else .{ 0, 0, 0, 0xff };
}

// Tests -----------------------------------------------------------------------

const testing = std.testing;

fn expectEntry(p: *Parser, table: []const u8, key: []const u8, value: Parser.Value) !void {
    const e = p.next() orelse return error.TestExpectedEntry;
    try testing.expectEqualStrings(table, e.table);
    try testing.expectEqualStrings(key, e.key);
    switch (value) {
        .string => |s| try testing.expectEqualStrings(s, e.value.string),
        else => try testing.expectEqual(value, e.value),
    }
}

test "toml: tables, strings, numbers, and comments" {
    var p: Parser = .init(
        \\# comment
        \\top = "a#b" # trailing
        \\esc = "q\"\\\t\u00e9"
        \\lit = 'C:\path'
        \\n = -1_000
        \\f = 2.5e1
        \\yes = true
        \\"quoted key" = 1
        \\dotted . key = 2
        \\
        \\[ dark ]
        \\view_bg="#000"
        \\[a.b]
        \\x = 3
    );
    try expectEntry(&p, "", "top", .{ .string = "a#b" });
    try expectEntry(&p, "", "esc", .{ .string = "q\"\\\t\u{e9}" });
    try expectEntry(&p, "", "lit", .{ .string = "C:\\path" });
    try expectEntry(&p, "", "n", .{ .integer = -1000 });
    try expectEntry(&p, "", "f", .{ .float = 25 });
    try expectEntry(&p, "", "yes", .{ .boolean = true });
    try expectEntry(&p, "", "\"quoted key\"", .{ .integer = 1 });
    try expectEntry(&p, "", "dotted . key", .{ .integer = 2 });
    try expectEntry(&p, "dark", "view_bg", .{ .string = "#000" });
    try expectEntry(&p, "a.b", "x", .{ .integer = 3 });
    try testing.expect(p.next() == null);
}

test "toml: malformed lines are skipped, and nothing lands in the wrong table" {
    var p: Parser = .init("a = \"unterminated\nb = \"ok\" junk\n[broken\nc = \"under a broken header\"\n" ++
        "[light]\nd = \"#fff\"\n[[array]]\ne = \"under an array of tables\"\n[dark]\n" ++
        "f = [\n  \"x = 1\",\n]\ng = \"\"\"\nh = 'multi-line'\n\"\"\"\ni = { j = 1 }\nk = 1__0\nl = nan\nm = \"\\x\"\n= \"no key\"\nz = \"last\"\r\n");
    try expectEntry(&p, "light", "d", .{ .string = "#fff" });
    try expectEntry(&p, "dark", "z", .{ .string = "last" });
    try testing.expect(p.next() == null);
}

test "theme.toml: tokens for both schemes, a scheme's table wins, bad values fall back" {
    const f = parseFile(
        \\scheme = "dark"
        \\accent = "#ff0000"
        \\view_bg = "#111111"
        \\border = "not a color"
        \\none = "#123456"
        \\unknown_token = "#123456"
        \\[dark]
        \\view_bg = "#222"
        \\[light]
        \\view_fg = "#00000080"
    );
    const u = f.theme;
    try testing.expect(!f.omarchy);
    try testing.expectEqual(User.Source.file, u.source);
    try testing.expectEqual(Scheme.dark, u.scheme.?);
    const L = @intFromEnum(Scheme.light);
    const D = @intFromEnum(Scheme.dark);
    try testing.expect(u.colors[D][@intFromEnum(ColorToken.view_bg)].?.eql(.srgb8(0x22, 0x22, 0x22, 0xff)));
    try testing.expect(u.colors[L][@intFromEnum(ColorToken.view_bg)].?.eql(.srgb8(0x11, 0x11, 0x11, 0xff)));
    try testing.expect(u.colors[L][@intFromEnum(ColorToken.view_fg)].?.eql(.srgb8(0, 0, 0, 0x80)));
    try testing.expect(u.colors[D][@intFromEnum(ColorToken.view_fg)] == null);
    try testing.expect(u.colors[D][@intFromEnum(ColorToken.accent)].?.eql(.srgb8(0xff, 0, 0, 0xff)));
    try testing.expect(u.colors[D][@intFromEnum(ColorToken.border)] == null);
    try testing.expect(u.colors[D][@intFromEnum(ColorToken.none)] == null);
    try testing.expect(parseFile("base = \"omarchy\"").omarchy);
}

const tokyo_night =
    \\mode = "dark"
    \\accent = "#7aa2f7"
    \\selection = "#292e42"
    \\muted = "#414868"
    \\background = "#1a1b26"
    \\dark_background = "#13141c"
    \\darker_background = "#0e0e14"
    \\lighter_background = "#24283b"
    \\foreground = "#a9b1d6"
    \\dark_foreground = "#565f89"
    \\light_foreground = "#b4bee6"
    \\bright_foreground = "#c0caf5"
    \\red = "#f7768e"
    \\yellow = "#e0af68"
    \\green = "#9ece6a"
    \\blue = "#7aa2f7"
;

fn tok(u: *const User, s: Scheme, t: ColorToken) ?Color {
    return u.colors[@intFromEnum(s)][@intFromEnum(t)];
}

fn hex(v: u24) Color {
    return .srgb8(@truncate(v >> 16), @truncate(v >> 8), @truncate(v), 0xff);
}

test "omarchy: colors.toml maps to tokens for its mode" {
    const u = omarchy(tokyo_night, false);
    try testing.expectEqual(User.Source.omarchy, u.source);
    try testing.expectEqual(Scheme.dark, u.scheme.?);
    // Only the dark variant is themed.
    for (u.colors[@intFromEnum(Scheme.light)]) |c| try testing.expect(c == null);
    try testing.expect(tok(&u, .dark, .view_bg).?.eql(hex(0x1a1b26)));
    try testing.expect(tok(&u, .dark, .view_fg).?.eql(hex(0xa9b1d6)));
    try testing.expect(tok(&u, .dark, .window_bg).?.eql(hex(0x13141c)));
    try testing.expect(tok(&u, .dark, .sidebar_bg).?.eql(hex(0x0e0e14)));
    try testing.expect(tok(&u, .dark, .secondary_sidebar_bg).?.eql(hex(0x13141c)));
    try testing.expect(tok(&u, .dark, .control_bg).?.eql(hex(0x24283b)));
    try testing.expect(tok(&u, .dark, .card_bg).?.eql(hex(0x24283b)));
    try testing.expect(tok(&u, .dark, .border).?.eql(hex(0x414868)));
    try testing.expect(tok(&u, .dark, .accent).?.eql(hex(0x7aa2f7)));
    try testing.expect(tok(&u, .dark, .selection_bg).?.eql(hex(0x292e42)));
    try testing.expect(tok(&u, .dark, .selection_fg).?.eql(hex(0xc0caf5)));
    try testing.expect(tok(&u, .dark, .destructive).?.eql(hex(0xf7768e)));
    try testing.expect(tok(&u, .dark, .success).?.eql(hex(0x9ece6a)));
    // The accent's shades are siv's, derived when the palette resolves.
    try testing.expect(tok(&u, .dark, .accent_hover) == null);
    // Muted text is dimmer than the text but readable on every surface.
    const muted = tok(&u, .dark, .muted_fg).?;
    try testing.expect(muted.luminance() < hex(0xa9b1d6).luminance());
    for ([_]u24{ 0x1a1b26, 0x13141c, 0x0e0e14 }) |b| {
        const l = hex(b).luminance();
        try testing.expect((muted.luminance() + 0.05) / (l + 0.05) >= 4.5);
    }
}

test "omarchy: legacy names, ANSI fallbacks, and the mode without a mode key" {
    // Short names and colorN only, light by its background.
    const u = omarchy(
        \\bg = "#eff1f5"
        \\fg = "#4c4f69"
        \\color1 = "#d20f39"
        \\color4 = "#1e66f5"
    , false);
    try testing.expectEqual(Scheme.light, u.scheme.?);
    try testing.expect(tok(&u, .light, .view_bg).?.eql(hex(0xeff1f5)));
    try testing.expect(tok(&u, .light, .destructive).?.eql(hex(0xd20f39)));
    // The accent falls back to blue, which falls back to color4.
    try testing.expect(tok(&u, .light, .accent).?.eql(hex(0x1e66f5)));
    // Missing shades are Omarchy's: the background mixed 25% toward black.
    try testing.expect(tok(&u, .light, .window_bg).?.eql(.srgb8(0xb3, 0xb5, 0xb8, 0xff)));
    // Canonical names win over legacy ones.
    try testing.expect(tok(&omarchy("background = \"#000000\"\nbg = \"#ffffff\"\nforeground = \"#ffffff\"", false), .dark, .view_bg).?.eql(hex(0)));
    // A light.mode marker and theme_type decide over the background.
    try testing.expectEqual(Scheme.light, omarchy("background = \"#000000\"", true).scheme.?);
    try testing.expectEqual(Scheme.light, omarchy("theme_type = \"light\"\nbackground = \"#000000\"", false).scheme.?);
    try testing.expectEqual(Scheme.dark, omarchy("mode = \"dark\"\nbackground = \"#ffffff\"", true).scheme.?);
    // Without a foreground no surface or text is themed, but the accent is.
    const half = omarchy("background = \"#000000\"\naccent = \"#ff0000\"", false);
    try testing.expect(tok(&half, .dark, .view_bg) == null);
    try testing.expect(tok(&half, .dark, .accent).?.eql(hex(0xff0000)));
}

test "theme.toml over Omarchy" {
    const base = omarchy(tokyo_night, false);
    const f = parseFile("base = \"omarchy\"\naccent = \"#ff0000\"\n[light]\nview_bg = \"#ffffff\"\n");
    try testing.expect(f.omarchy);
    const u = overlay(base, f.theme);
    try testing.expectEqual(User.Source.file, u.source);
    try testing.expectEqual(Scheme.dark, u.scheme.?);
    try testing.expect(tok(&u, .dark, .accent).?.eql(hex(0xff0000)));
    try testing.expect(tok(&u, .dark, .view_bg).?.eql(hex(0x1a1b26)));
    try testing.expect(tok(&u, .light, .view_bg).?.eql(hex(0xffffff)));
}

test "fuzz theme files" {
    try std.testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        tokyo_night,
        "scheme = \"dark\"\n[dark]\nview_bg = \"#000\"\n[[x]]\ny = [1, { z = '}' }]\n",
        "a = \"\\u00e9\\U0001F600\"\nb = '''\nc\n'''\n\"k\".k2 = 1_0\n",
    } });
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [2048]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    var p: Parser = .init(src);
    var n: usize = 0;
    while (p.next()) |e| : (n += 1) {
        // Entries never span lines or name a table or key with a newline.
        try testing.expect(std.mem.indexOfScalar(u8, e.key, '\n') == null);
        try testing.expect(std.mem.indexOfScalar(u8, e.table, '\n') == null);
        try testing.expect(n <= src.len);
    }
    const f = parseFile(src);
    const o = omarchy(src, false);
    _ = overlay(o, f.theme);
    // Every color is a real one.
    for ([_]User{ f.theme, o }) |u| for (u.colors) |cs| for (cs) |c| if (c) |v| {
        try testing.expect(v.a >= 0 and v.a <= 1 and std.math.isFinite(v.r));
    };
}
