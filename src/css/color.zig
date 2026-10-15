//! CSS Color Level 4 and 5: hex, named, and system colors, rgb(), hsl(),
//! hwb(), lab(), lch(), oklab(), oklch(), color() in the predefined
//! spaces, and color-mix(). Computed colors are sRGB components (encoded,
//! 0..1, straight alpha), gamut-clipped, which is what the renderers take
//! (D11 converts them to linear light); `currentcolor` and system colors
//! stay symbolic until computed.

const std = @import("std");
const tk = @import("tokenizer.zig");
const Token = tk.Token;

pub const System = enum(u8) {
    canvas,
    canvas_text,
    link_text,
    visited_text,
    active_text,
    button_face,
    button_text,
    button_border,
    field,
    field_text,
    highlight,
    highlight_text,
    mark,
    mark_text,
    gray_text,
    accent_color,
    accent_color_text,
};

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
    kind: Kind = .rgba,
    system: System = .canvas,

    pub const Kind = enum(u8) { rgba, current, system };

    pub const transparent: Color = .{};
    pub const black: Color = .{ .a = 1 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const current: Color = .{ .kind = .current };

    pub fn rgb8(r: u8, g: u8, b: u8) Color {
        return .{ .r = @as(f32, @floatFromInt(r)) / 255, .g = @as(f32, @floatFromInt(g)) / 255, .b = @as(f32, @floatFromInt(b)) / 255, .a = 1 };
    }

    pub fn eql(x: Color, y: Color) bool {
        return x.kind == y.kind and x.system == y.system and x.r == y.r and x.g == y.g and x.b == y.b and x.a == y.a;
    }

    pub fn isOpaqueBlackOrWhite(c: Color) bool {
        return c.a == 1 and c.r == c.g and c.g == c.b and (c.r == 0 or c.r == 1);
    }
};

pub fn hex(s: []const u8) ?Color {
    var v: [8]u8 = undefined;
    for (s, 0..) |ch, i| {
        if (i >= 8) return null;
        v[i] = std.fmt.charToDigit(ch, 16) catch return null;
    }
    return switch (s.len) {
        3, 4 => .{
            .r = @as(f32, @floatFromInt(v[0] * 17)) / 255,
            .g = @as(f32, @floatFromInt(v[1] * 17)) / 255,
            .b = @as(f32, @floatFromInt(v[2] * 17)) / 255,
            .a = if (s.len == 4) @as(f32, @floatFromInt(v[3] * 17)) / 255 else 1,
        },
        6, 8 => .{
            .r = @as(f32, @floatFromInt(v[0] * 16 + v[1])) / 255,
            .g = @as(f32, @floatFromInt(v[2] * 16 + v[3])) / 255,
            .b = @as(f32, @floatFromInt(v[4] * 16 + v[5])) / 255,
            .a = if (s.len == 8) @as(f32, @floatFromInt(v[6] * 16 + v[7])) / 255 else 1,
        },
        else => null,
    };
}

pub fn named(name: []const u8) ?Color {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, name);
    if (std.mem.eql(u8, lower, "transparent")) return Color.transparent;
    if (std.mem.eql(u8, lower, "currentcolor")) return Color.current;
    if (system_map.get(lower)) |s| return .{ .kind = .system, .system = s, .a = 1 };
    const v = named_map.get(lower) orelse return null;
    return Color.rgb8(@intCast(v >> 16), @intCast((v >> 8) & 0xff), @intCast(v & 0xff));
}

const system_map = std.StaticStringMap(System).initComptime(.{
    .{ "canvas", .canvas },                 .{ "canvastext", .canvas_text },     .{ "linktext", .link_text },
    .{ "visitedtext", .visited_text },      .{ "activetext", .active_text },     .{ "buttonface", .button_face },
    .{ "buttontext", .button_text },        .{ "buttonborder", .button_border }, .{ "field", .field },
    .{ "fieldtext", .field_text },          .{ "highlight", .highlight },        .{ "highlighttext", .highlight_text },
    .{ "mark", .mark },                     .{ "marktext", .mark_text },         .{ "graytext", .gray_text },
    .{ "accentcolor", .accent_color },      .{ "accentcolortext", .accent_color_text },
    .{ "window", .canvas },                 .{ "windowtext", .canvas_text },
});

const named_map = std.StaticStringMap(u32).initComptime(.{
    .{ "aliceblue", 0xf0f8ff },            .{ "antiquewhite", 0xfaebd7 },       .{ "aqua", 0x00ffff },               .{ "aquamarine", 0x7fffd4 },
    .{ "azure", 0xf0ffff },                .{ "beige", 0xf5f5dc },              .{ "bisque", 0xffe4c4 },             .{ "black", 0x000000 },
    .{ "blanchedalmond", 0xffebcd },       .{ "blue", 0x0000ff },               .{ "blueviolet", 0x8a2be2 },         .{ "brown", 0xa52a2a },
    .{ "burlywood", 0xdeb887 },            .{ "cadetblue", 0x5f9ea0 },          .{ "chartreuse", 0x7fff00 },         .{ "chocolate", 0xd2691e },
    .{ "coral", 0xff7f50 },                .{ "cornflowerblue", 0x6495ed },     .{ "cornsilk", 0xfff8dc },           .{ "crimson", 0xdc143c },
    .{ "cyan", 0x00ffff },                 .{ "darkblue", 0x00008b },           .{ "darkcyan", 0x008b8b },           .{ "darkgoldenrod", 0xb8860b },
    .{ "darkgray", 0xa9a9a9 },             .{ "darkgreen", 0x006400 },          .{ "darkgrey", 0xa9a9a9 },           .{ "darkkhaki", 0xbdb76b },
    .{ "darkmagenta", 0x8b008b },          .{ "darkolivegreen", 0x556b2f },     .{ "darkorange", 0xff8c00 },         .{ "darkorchid", 0x9932cc },
    .{ "darkred", 0x8b0000 },              .{ "darksalmon", 0xe9967a },         .{ "darkseagreen", 0x8fbc8f },       .{ "darkslateblue", 0x483d8b },
    .{ "darkslategray", 0x2f4f4f },        .{ "darkslategrey", 0x2f4f4f },      .{ "darkturquoise", 0x00ced1 },      .{ "darkviolet", 0x9400d3 },
    .{ "deeppink", 0xff1493 },             .{ "deepskyblue", 0x00bfff },        .{ "dimgray", 0x696969 },            .{ "dimgrey", 0x696969 },
    .{ "dodgerblue", 0x1e90ff },           .{ "firebrick", 0xb22222 },          .{ "floralwhite", 0xfffaf0 },        .{ "forestgreen", 0x228b22 },
    .{ "fuchsia", 0xff00ff },              .{ "gainsboro", 0xdcdcdc },          .{ "ghostwhite", 0xf8f8ff },         .{ "gold", 0xffd700 },
    .{ "goldenrod", 0xdaa520 },            .{ "gray", 0x808080 },               .{ "green", 0x008000 },              .{ "greenyellow", 0xadff2f },
    .{ "grey", 0x808080 },                 .{ "honeydew", 0xf0fff0 },           .{ "hotpink", 0xff69b4 },            .{ "indianred", 0xcd5c5c },
    .{ "indigo", 0x4b0082 },               .{ "ivory", 0xfffff0 },              .{ "khaki", 0xf0e68c },              .{ "lavender", 0xe6e6fa },
    .{ "lavenderblush", 0xfff0f5 },        .{ "lawngreen", 0x7cfc00 },          .{ "lemonchiffon", 0xfffacd },       .{ "lightblue", 0xadd8e6 },
    .{ "lightcoral", 0xf08080 },           .{ "lightcyan", 0xe0ffff },          .{ "lightgoldenrodyellow", 0xfafad2 }, .{ "lightgray", 0xd3d3d3 },
    .{ "lightgreen", 0x90ee90 },           .{ "lightgrey", 0xd3d3d3 },          .{ "lightpink", 0xffb6c1 },          .{ "lightsalmon", 0xffa07a },
    .{ "lightseagreen", 0x20b2aa },        .{ "lightskyblue", 0x87cefa },       .{ "lightslategray", 0x778899 },     .{ "lightslategrey", 0x778899 },
    .{ "lightsteelblue", 0xb0c4de },       .{ "lightyellow", 0xffffe0 },        .{ "lime", 0x00ff00 },               .{ "limegreen", 0x32cd32 },
    .{ "linen", 0xfaf0e6 },                .{ "magenta", 0xff00ff },            .{ "maroon", 0x800000 },             .{ "mediumaquamarine", 0x66cdaa },
    .{ "mediumblue", 0x0000cd },           .{ "mediumorchid", 0xba55d3 },       .{ "mediumpurple", 0x9370db },       .{ "mediumseagreen", 0x3cb371 },
    .{ "mediumslateblue", 0x7b68ee },      .{ "mediumspringgreen", 0x00fa9a },  .{ "mediumturquoise", 0x48d1cc },    .{ "mediumvioletred", 0xc71585 },
    .{ "midnightblue", 0x191970 },         .{ "mintcream", 0xf5fffa },          .{ "mistyrose", 0xffe4e1 },          .{ "moccasin", 0xffe4b5 },
    .{ "navajowhite", 0xffdead },          .{ "navy", 0x000080 },               .{ "oldlace", 0xfdf5e6 },            .{ "olive", 0x808000 },
    .{ "olivedrab", 0x6b8e23 },            .{ "orange", 0xffa500 },             .{ "orangered", 0xff4500 },          .{ "orchid", 0xda70d6 },
    .{ "palegoldenrod", 0xeee8aa },        .{ "palegreen", 0x98fb98 },          .{ "paleturquoise", 0xafeeee },      .{ "palevioletred", 0xdb7093 },
    .{ "papayawhip", 0xffefd5 },           .{ "peachpuff", 0xffdab9 },          .{ "peru", 0xcd853f },               .{ "pink", 0xffc0cb },
    .{ "plum", 0xdda0dd },                 .{ "powderblue", 0xb0e0e6 },         .{ "purple", 0x800080 },             .{ "rebeccapurple", 0x663399 },
    .{ "red", 0xff0000 },                  .{ "rosybrown", 0xbc8f8f },          .{ "royalblue", 0x4169e1 },          .{ "saddlebrown", 0x8b4513 },
    .{ "salmon", 0xfa8072 },               .{ "sandybrown", 0xf4a460 },         .{ "seagreen", 0x2e8b57 },           .{ "seashell", 0xfff5ee },
    .{ "sienna", 0xa0522d },               .{ "silver", 0xc0c0c0 },             .{ "skyblue", 0x87ceeb },            .{ "slateblue", 0x6a5acd },
    .{ "slategray", 0x708090 },            .{ "slategrey", 0x708090 },          .{ "snow", 0xfffafa },               .{ "springgreen", 0x00ff7f },
    .{ "steelblue", 0x4682b4 },            .{ "tan", 0xd2b48c },                .{ "teal", 0x008080 },               .{ "thistle", 0xd8bfd8 },
    .{ "tomato", 0xff6347 },               .{ "turquoise", 0x40e0d0 },          .{ "violet", 0xee82ee },             .{ "wheat", 0xf5deb3 },
    .{ "white", 0xffffff },                .{ "whitesmoke", 0xf5f5f5 },         .{ "yellow", 0xffff00 },             .{ "yellowgreen", 0x9acd32 },
});

// Color spaces.

pub const Space = enum { srgb, srgb_linear, display_p3, a98_rgb, prophoto_rgb, rec2020, xyz_d50, xyz_d65, lab, lch, oklab, oklch, hsl, hwb };

fn srgbToLinear(c: f64) f64 {
    const a = @abs(c);
    const v = if (a <= 0.04045) a / 12.92 else std.math.pow(f64, (a + 0.055) / 1.055, 2.4);
    return std.math.copysign(v, c);
}

fn linearToSrgb(c: f64) f64 {
    const a = @abs(c);
    const v = if (a <= 0.0031308) a * 12.92 else 1.055 * std.math.pow(f64, a, 1.0 / 2.4) - 0.055;
    return std.math.copysign(v, c);
}

const V3 = [3]f64;

fn mul(m: [9]f64, v: V3) V3 {
    return .{ m[0] * v[0] + m[1] * v[1] + m[2] * v[2], m[3] * v[0] + m[4] * v[1] + m[5] * v[2], m[6] * v[0] + m[7] * v[1] + m[8] * v[2] };
}

const xyz65_to_lsrgb = [9]f64{ 3.2409699419045226, -1.537383177570094, -0.4986107602930034, -0.9692436362808796, 1.8759675015077202, 0.04155505740717559, 0.05563007969699366, -0.20397695888897652, 1.0569715142428786 };
const lsrgb_to_xyz65 = [9]f64{ 0.41239079926595934, 0.357584339383878, 0.1804807884018343, 0.21263900587151027, 0.715168678767756, 0.07219231536073371, 0.01933081871559182, 0.11919477979462598, 0.9505321522496607 };
const d50_to_d65 = [9]f64{ 0.955473421488075, -0.02309845494876471, 0.06325924320057072, -0.0283697093338637, 1.0099953980813041, 0.021041441191917323, 0.012314014864481998, -0.020507649298898964, 1.330365926242124 };
const d65_to_d50 = [9]f64{ 1.0479297925449969, 0.022946870601609652, -0.05019226628920524, 0.02962780877005599, 0.9904344267538799, -0.017073799063418826, -0.009243040646204504, 0.015055191490298152, 0.7518742814281371 };
const p3_to_xyz = [9]f64{ 0.4865709486482162, 0.26566769316909306, 0.1982172852343625, 0.2289745640697488, 0.6917385218365064, 0.079286914093745, 0.0, 0.04511338185890264, 1.043944368900976 };
const rec2020_to_xyz = [9]f64{ 0.6369580483012914, 0.14461690358620832, 0.1688809751641721, 0.2627002120112671, 0.6779980715188708, 0.05930171646986196, 0.0, 0.028072693049087428, 1.060985057710791 };
const a98_to_xyz = [9]f64{ 0.5766690429101305, 0.1855582379065463, 0.1882286462349947, 0.29734497525053605, 0.6273635662554661, 0.0752914584939978, 0.02703136138641234, 0.07068885253582723, 0.9913375368376388 };
const prophoto_to_xyz50 = [9]f64{ 0.7977666449006423, 0.13518129740053308, 0.0313477341283922, 0.2880748288194013, 0.711835234241873, 0.00008993693872564, 0.0, 0.0, 0.8251046025104602 };

/// Linear sRGB to OKLab and back.
fn lsrgbToOklab(c: V3) V3 {
    const l = std.math.cbrt(0.4122214708 * c[0] + 0.5363325363 * c[1] + 0.0514459929 * c[2]);
    const m = std.math.cbrt(0.2119034982 * c[0] + 0.6806995451 * c[1] + 0.1073969566 * c[2]);
    const s = std.math.cbrt(0.0883024619 * c[0] + 0.2817188376 * c[1] + 0.6299787005 * c[2]);
    return .{ 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s };
}

fn oklabToLsrgb(c: V3) V3 {
    const l_ = c[0] + 0.3963377774 * c[1] + 0.2158037573 * c[2];
    const m_ = c[0] - 0.1055613458 * c[1] - 0.0638541728 * c[2];
    const s_ = c[0] - 0.0894841775 * c[1] - 1.2914855480 * c[2];
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;
    return .{ 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s, -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s };
}

fn labToXyz50(c: V3) V3 {
    const k = 24389.0 / 27.0;
    const e = 216.0 / 24389.0;
    const f1 = (c[0] + 16) / 116;
    const f0 = c[1] / 500 + f1;
    const f2 = f1 - c[2] / 200;
    const x = if (f0 * f0 * f0 > e) f0 * f0 * f0 else (116 * f0 - 16) / k;
    const y = if (c[0] > k * e) std.math.pow(f64, (c[0] + 16) / 116, 3) else c[0] / k;
    const z = if (f2 * f2 * f2 > e) f2 * f2 * f2 else (116 * f2 - 16) / k;
    return .{ x * 0.3457 / 0.3585, y, z * (1.0 - 0.3457 - 0.3585) / 0.3585 };
}

fn xyz50ToLab(c: V3) V3 {
    const k = 24389.0 / 27.0;
    const e = 216.0 / 24389.0;
    const w = V3{ 0.3457 / 0.3585, 1.0, (1.0 - 0.3457 - 0.3585) / 0.3585 };
    var f: V3 = undefined;
    for (0..3) |i| {
        const v = c[i] / w[i];
        f[i] = if (v > e) std.math.cbrt(v) else (k * v + 16) / 116;
    }
    return .{ 116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2]) };
}

fn hslToSrgb(h_: f64, s: f64, l: f64) V3 {
    const h = @mod(h_, 360);
    const f = struct {
        fn f(n: f64, hh: f64, ss: f64, ll: f64) f64 {
            const k = @mod(n + hh / 30, 12);
            const a = ss * @min(ll, 1 - ll);
            return ll - a * @max(-1, @min(@min(k - 3, 9 - k), 1));
        }
    }.f;
    return .{ f(0, h, s, l), f(8, h, s, l), f(4, h, s, l) };
}

fn hwbToSrgb(h: f64, w_: f64, b_: f64) V3 {
    var w = w_;
    var b = b_;
    if (w + b >= 1) {
        const g = w / (w + b);
        return .{ g, g, g };
    }
    var rgb = hslToSrgb(h, 1, 0.5);
    for (&rgb) |*c| c.* = c.* * (1 - w - b) + w;
    _ = &w;
    _ = &b;
    return rgb;
}

/// Components in `space` to linear sRGB.
pub fn toLinearSrgb(space: Space, c: V3) V3 {
    return switch (space) {
        .srgb => .{ srgbToLinear(c[0]), srgbToLinear(c[1]), srgbToLinear(c[2]) },
        .srgb_linear => c,
        .hsl => toLinearSrgb(.srgb, hslToSrgb(c[0], c[1], c[2])),
        .hwb => toLinearSrgb(.srgb, hwbToSrgb(c[0], c[1], c[2])),
        .display_p3 => mul(xyz65_to_lsrgb, mul(p3_to_xyz, .{ srgbToLinear(c[0]), srgbToLinear(c[1]), srgbToLinear(c[2]) })),
        .rec2020 => blk: {
            const f = struct {
                fn f(v: f64) f64 {
                    const a = 1.09929682680944;
                    const b = 0.018053968510807;
                    const x = @abs(v);
                    const r = if (x < b * 4.5) x / 4.5 else std.math.pow(f64, (x + a - 1) / a, 1.0 / 0.45);
                    return std.math.copysign(r, v);
                }
            }.f;
            break :blk mul(xyz65_to_lsrgb, mul(rec2020_to_xyz, .{ f(c[0]), f(c[1]), f(c[2]) }));
        },
        .a98_rgb => blk: {
            const f = struct {
                fn f(v: f64) f64 {
                    return std.math.copysign(std.math.pow(f64, @abs(v), 563.0 / 256.0), v);
                }
            }.f;
            break :blk mul(xyz65_to_lsrgb, mul(a98_to_xyz, .{ f(c[0]), f(c[1]), f(c[2]) }));
        },
        .prophoto_rgb => blk: {
            const f = struct {
                fn f(v: f64) f64 {
                    const x = @abs(v);
                    const r = if (x <= 16.0 / 512.0) x / 16 else std.math.pow(f64, x, 1.8);
                    return std.math.copysign(r, v);
                }
            }.f;
            break :blk mul(xyz65_to_lsrgb, mul(d50_to_d65, mul(prophoto_to_xyz50, .{ f(c[0]), f(c[1]), f(c[2]) })));
        },
        .xyz_d65 => mul(xyz65_to_lsrgb, c),
        .xyz_d50 => mul(xyz65_to_lsrgb, mul(d50_to_d65, c)),
        .lab => mul(xyz65_to_lsrgb, mul(d50_to_d65, labToXyz50(c))),
        .lch => toLinearSrgb(.lab, polarToRect(c)),
        .oklab => oklabToLsrgb(c),
        .oklch => oklabToLsrgb(polarToRect(c)),
    };
}

/// Linear sRGB to components in `space` (for color-mix).
pub fn fromLinearSrgb(space: Space, c: V3) V3 {
    return switch (space) {
        .srgb => .{ linearToSrgb(c[0]), linearToSrgb(c[1]), linearToSrgb(c[2]) },
        .srgb_linear => c,
        .hsl => srgbToHsl(fromLinearSrgb(.srgb, c)),
        .hwb => blk: {
            const s = fromLinearSrgb(.srgb, c);
            const hsl = srgbToHsl(s);
            break :blk .{ hsl[0], @min(s[0], @min(s[1], s[2])), 1 - @max(s[0], @max(s[1], s[2])) };
        },
        .xyz_d65 => mul(lsrgb_to_xyz65, c),
        .xyz_d50 => mul(d65_to_d50, mul(lsrgb_to_xyz65, c)),
        .lab => xyz50ToLab(mul(d65_to_d50, mul(lsrgb_to_xyz65, c))),
        .lch => rectToPolar(fromLinearSrgb(.lab, c)),
        .oklab => lsrgbToOklab(c),
        .oklch => rectToPolar(lsrgbToOklab(c)),
        // Interpolating in these is rare; sRGB-linear stands in.
        .display_p3, .a98_rgb, .prophoto_rgb, .rec2020 => c,
    };
}

fn srgbToHsl(c: V3) V3 {
    const mx = @max(c[0], @max(c[1], c[2]));
    const mn = @min(c[0], @min(c[1], c[2]));
    const l = (mx + mn) / 2;
    const d = mx - mn;
    if (d == 0) return .{ 0, 0, l };
    const s = if (l == 0 or l == 1) 0 else (mx - l) / @min(l, 1 - l);
    var h: f64 = if (mx == c[0]) (c[1] - c[2]) / d + (if (c[1] < c[2]) @as(f64, 6) else 0) else if (mx == c[1]) (c[2] - c[0]) / d + 2 else (c[0] - c[1]) / d + 4;
    h *= 60;
    return .{ h, s, l };
}

fn polarToRect(c: V3) V3 {
    const h = c[2] * std.math.pi / 180;
    return .{ c[0], c[1] * @cos(h), c[1] * @sin(h) };
}

fn rectToPolar(c: V3) V3 {
    var h = std.math.atan2(c[2], c[1]) * 180 / std.math.pi;
    if (h < 0) h += 360;
    return .{ c[0], @sqrt(c[1] * c[1] + c[2] * c[2]), h };
}

pub fn fromSpace(space: Space, c: V3, alpha: f64) Color {
    const lin = toLinearSrgb(space, c);
    const s = fromLinearSrgb(.srgb, lin);
    return .{
        .r = @floatCast(std.math.clamp(s[0], 0, 1)),
        .g = @floatCast(std.math.clamp(s[1], 0, 1)),
        .b = @floatCast(std.math.clamp(s[2], 0, 1)),
        .a = @floatCast(std.math.clamp(alpha, 0, 1)),
    };
}

pub const HueMethod = enum { shorter, longer, increasing, decreasing };

/// color-mix(in space, a p, b) with p the share of `a`.
pub fn mix(space: Space, hue: HueMethod, a: Color, b: Color, p: f64) Color {
    const la = toLinearSrgb(.srgb, .{ a.r, a.g, a.b });
    const lb = toLinearSrgb(.srgb, .{ b.r, b.g, b.b });
    var ca = fromLinearSrgb(space, la);
    var cb = fromLinearSrgb(space, lb);
    const aa: f64 = a.a;
    const ab: f64 = b.a;
    const polar_index: ?usize = switch (space) {
        .hsl, .hwb => 0,
        .lch, .oklch => 2,
        else => null,
    };
    // Premultiplied, except hue.
    for (0..3) |i| if (polar_index != i) {
        ca[i] *= aa;
        cb[i] *= ab;
    };
    if (polar_index) |hi| {
        var h1 = ca[hi];
        var h2 = cb[hi];
        switch (hue) {
            .shorter => if (h2 - h1 > 180) {
                h1 += 360;
            } else if (h2 - h1 < -180) {
                h2 += 360;
            },
            .longer => if (h2 - h1 > 0 and h2 - h1 < 180) {
                h1 += 360;
            } else if (h2 - h1 > -180 and h2 - h1 <= 0) {
                h2 += 360;
            },
            .increasing => if (h2 < h1) {
                h2 += 360;
            },
            .decreasing => if (h1 < h2) {
                h1 += 360;
            },
        }
        ca[hi] = h1;
        cb[hi] = h2;
    }
    var out: V3 = undefined;
    for (0..3) |i| out[i] = ca[i] * p + cb[i] * (1 - p);
    const alpha = aa * p + ab * (1 - p);
    if (alpha > 0) for (0..3) |i| if (polar_index != i) {
        out[i] /= alpha;
    };
    return fromSpace(space, out, alpha);
}

// Parsing.

pub const Parser = struct {
    tokens: []const Token,
    pos: usize = 0,

    fn skipWs(p: *Parser) void {
        while (p.pos < p.tokens.len and p.tokens[p.pos].kind == .whitespace) p.pos += 1;
    }

    fn peek(p: *Parser) Token {
        p.skipWs();
        return if (p.pos < p.tokens.len) p.tokens[p.pos] else .{ .kind = .eof };
    }

    fn take(p: *Parser) Token {
        const t = p.peek();
        if (p.pos < p.tokens.len) p.pos += 1;
        return t;
    }
};

/// Parses a color at `tokens[pos.*]`, advancing past it.
pub fn parse(tokens: []const Token, pos: *usize) ?Color {
    var p: Parser = .{ .tokens = tokens, .pos = pos.* };
    const t = p.take();
    const c: Color = switch (t.kind) {
        .hash => hex(t.text) orelse return null,
        .ident => named(t.text) orelse return null,
        .function => func(&p, t.text) orelse return null,
        else => return null,
    };
    pos.* = p.pos;
    return c;
}

/// A component: number, percentage (scaled by `pct`), angle (for hue),
/// or `none` (0).
fn component(p: *Parser, pct: f64, hue: bool) ?f64 {
    const t = p.take();
    return switch (t.kind) {
        .number => t.number,
        .percentage => t.number / 100 * pct,
        .dimension => if (hue) angle(t) else null,
        .ident => if (t.isIdent("none")) 0 else null,
        else => null,
    };
}

pub fn angle(t: Token) ?f64 {
    if (t.kind == .number and t.number == 0) return 0;
    if (t.kind != .dimension) return null;
    const u = t.text;
    if (std.ascii.eqlIgnoreCase(u, "deg")) return t.number;
    if (std.ascii.eqlIgnoreCase(u, "rad")) return t.number * 180 / std.math.pi;
    if (std.ascii.eqlIgnoreCase(u, "grad")) return t.number * 0.9;
    if (std.ascii.eqlIgnoreCase(u, "turn")) return t.number * 360;
    return null;
}

fn closeOrSep(p: *Parser, legacy: *?bool) ?void {
    const t = p.peek();
    if (t.kind == .comma) {
        if (legacy.* == false) return null;
        legacy.* = true;
        p.pos += 1;
        return;
    }
    if (legacy.* == true) return null;
    legacy.* = false;
}

/// The optional `/ alpha` (or legacy `, alpha`) and the closing paren.
fn alphaAndClose(p: *Parser, legacy: ?bool) ?f64 {
    var a: f64 = 1;
    const t = p.peek();
    if ((legacy != true and t.isDelim('/')) or (legacy == true and t.kind == .comma)) {
        p.pos += 1;
        a = component(p, 1, false) orelse return null;
    }
    if (p.take().kind != .rparen) return null;
    return std.math.clamp(a, 0, 1);
}

fn func(p: *Parser, name_: []const u8) ?Color {
    var buf: [16]u8 = undefined;
    if (name_.len > buf.len) return null;
    const name = std.ascii.lowerString(&buf, name_);
    if (std.mem.eql(u8, name, "rgb") or std.mem.eql(u8, name, "rgba")) {
        var legacy: ?bool = null;
        var v: [3]f64 = undefined;
        for (0..3) |i| {
            if (i > 0) closeOrSep(p, &legacy) orelse return null;
            v[i] = component(p, 255, false) orelse return null;
        }
        const a = alphaAndClose(p, legacy) orelse return null;
        return .{ .r = @floatCast(std.math.clamp(v[0] / 255, 0, 1)), .g = @floatCast(std.math.clamp(v[1] / 255, 0, 1)), .b = @floatCast(std.math.clamp(v[2] / 255, 0, 1)), .a = @floatCast(a) };
    }
    if (std.mem.eql(u8, name, "hsl") or std.mem.eql(u8, name, "hsla") or std.mem.eql(u8, name, "hwb")) {
        const hwb = name[1] == 'w';
        var legacy: ?bool = if (hwb) false else null;
        const h = component(p, 1, true) orelse return null;
        closeOrSep(p, &legacy) orelse return null;
        const s = component(p, 1, false) orelse return null;
        closeOrSep(p, &legacy) orelse return null;
        const l = component(p, 1, false) orelse return null;
        const a = alphaAndClose(p, legacy) orelse return null;
        // Plain numbers are percentages in the modern syntax.
        const sn = if (s > 1) s / 100 else s;
        const ln = if (l > 1) l / 100 else l;
        return fromSpace(if (hwb) .hwb else .hsl, .{ h, std.math.clamp(sn, 0, 1), std.math.clamp(ln, 0, 1) }, a);
    }
    const lab_like: ?struct { Space, [3]f64 } = if (std.mem.eql(u8, name, "lab"))
        .{ .lab, .{ 100, 125, 125 } }
    else if (std.mem.eql(u8, name, "lch"))
        .{ .lch, .{ 100, 150, 1 } }
    else if (std.mem.eql(u8, name, "oklab"))
        .{ .oklab, .{ 1, 0.4, 0.4 } }
    else if (std.mem.eql(u8, name, "oklch"))
        .{ .oklch, .{ 1, 0.4, 1 } }
    else
        null;
    if (lab_like) |ll| {
        var v: [3]f64 = undefined;
        for (0..3) |i| v[i] = component(p, ll[1][i], i == 2 and (ll[0] == .lch or ll[0] == .oklch)) orelse return null;
        const a = alphaAndClose(p, false) orelse return null;
        v[0] = @max(0, v[0]);
        if (ll[0] == .lch or ll[0] == .oklch) v[1] = @max(0, v[1]);
        return fromSpace(ll[0], v, a);
    }
    if (std.mem.eql(u8, name, "color")) {
        const st = p.take();
        if (st.kind != .ident) return null;
        const space = predefined(st.text) orelse return null;
        var v: [3]f64 = undefined;
        for (0..3) |i| v[i] = component(p, 1, false) orelse return null;
        const a = alphaAndClose(p, false) orelse return null;
        return fromSpace(space, v, a);
    }
    if (std.mem.eql(u8, name, "color-mix")) {
        const in_ = p.take();
        if (!in_.isIdent("in")) return null;
        const st = p.take();
        if (st.kind != .ident) return null;
        const space = mixSpace(st.text) orelse return null;
        var hue: HueMethod = .shorter;
        if (p.peek().kind == .ident) {
            const h = p.take();
            hue = if (h.isIdent("shorter")) .shorter else if (h.isIdent("longer")) .longer else if (h.isIdent("increasing")) .increasing else if (h.isIdent("decreasing")) .decreasing else return null;
            if (!p.take().isIdent("hue")) return null;
        }
        var colors: [2]Color = undefined;
        var pcts: [2]?f64 = .{ null, null };
        for (0..2) |i| {
            if (p.take().kind != .comma) return null;
            if (p.peek().kind == .percentage) pcts[i] = p.take().number / 100;
            p.skipWs();
            colors[i] = parse(p.tokens, &p.pos) orelse return null;
            if (p.peek().kind == .percentage) pcts[i] = p.take().number / 100;
        }
        if (p.take().kind != .rparen) return null;
        var p1 = pcts[0];
        var p2 = pcts[1];
        if (p1 == null and p2 == null) {
            p1 = 0.5;
            p2 = 0.5;
        } else if (p1 == null) p1 = 1 - p2.? else if (p2 == null) p2 = 1 - p1.?;
        const sum = p1.? + p2.?;
        if (sum <= 0) return null;
        // Symbolic colors mix as black or white stand-ins.
        for (&colors) |*c| if (c.kind != .rgba) {
            c.* = .{ .a = 1 };
        };
        var out = mix(space, hue, colors[0], colors[1], p1.? / sum);
        if (sum < 1) out.a *= @floatCast(sum);
        return out;
    }
    return null;
}

fn predefined(s: []const u8) ?Space {
    const map = [_]struct { []const u8, Space }{
        .{ "srgb", .srgb },               .{ "srgb-linear", .srgb_linear }, .{ "display-p3", .display_p3 },
        .{ "a98-rgb", .a98_rgb },         .{ "prophoto-rgb", .prophoto_rgb }, .{ "rec2020", .rec2020 },
        .{ "xyz", .xyz_d65 },             .{ "xyz-d65", .xyz_d65 },         .{ "xyz-d50", .xyz_d50 },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(s, m[0])) return m[1];
    return null;
}

fn mixSpace(s: []const u8) ?Space {
    if (predefined(s)) |sp| return sp;
    const map = [_]struct { []const u8, Space }{ .{ "lab", .lab }, .{ "lch", .lch }, .{ "oklab", .oklab }, .{ "oklch", .oklch }, .{ "hsl", .hsl }, .{ "hwb", .hwb } };
    for (map) |m| if (std.ascii.eqlIgnoreCase(s, m[0])) return m[1];
    return null;
}

fn parseStr(s: []const u8) ?Color {
    var l = tk.tokenize(std.testing.allocator, s) catch return null;
    defer l.deinit();
    var pos: usize = 0;
    return parse(l.tokens, &pos);
}

fn expectRgb(want: [4]f32, c: ?Color) !void {
    const got = c orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(want[0], got.r * 255, 0.6);
    try std.testing.expectApproxEqAbs(want[1], got.g * 255, 0.6);
    try std.testing.expectApproxEqAbs(want[2], got.b * 255, 0.6);
    try std.testing.expectApproxEqAbs(want[3], got.a, 0.01);
}

test "colors" {
    try expectRgb(.{ 255, 0, 0, 1 }, parseStr("red"));
    try expectRgb(.{ 0x11, 0x22, 0x33, 1 }, parseStr("#123"));
    try expectRgb(.{ 10, 20, 30, 0.5 }, parseStr("rgb(10 20 30 / 50%)"));
    try expectRgb(.{ 10, 20, 30, 0.5 }, parseStr("rgba(10, 20, 30, .5)"));
    try expectRgb(.{ 0, 128, 0, 1 }, parseStr("hsl(120deg 100% 25.1%)"));
    // oklch(62.8% 0.2577 29.23) is sRGB red.
    try expectRgb(.{ 255, 0, 0, 1 }, parseStr("oklch(62.8% 0.2577 29.23)"));
    try expectRgb(.{ 255, 0, 0, 1 }, parseStr("lab(54.29 80.8 69.89)"));
    // Half red, half blue in sRGB.
    try expectRgb(.{ 128, 0, 128, 1 }, parseStr("color-mix(in srgb, red, blue)"));
    try expectRgb(.{ 191, 0, 64, 1 }, parseStr("color-mix(in srgb, red 75%, blue)"));
    try std.testing.expectEqual(Color.Kind.current, parseStr("currentColor").?.kind);
    try std.testing.expect(parseStr("rgb(1, 2 3)") == null);
}
