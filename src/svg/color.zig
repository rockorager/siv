//! CSS colors as SVG files write them: `#rgb`, `#rgba`, `#rrggbb`,
//! `#rrggbbaa`, `rgb()` and `rgba()` with numbers or percentages,
//! `hsl()` and `hsla()`, `transparent`, and the 148 named colors.
//! Results are sRGB-encoded with straight alpha, components in [0, 1].

const std = @import("std");

pub const Rgba = [4]f32;

pub fn parse(text: []const u8) ?Rgba {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] == '#') return hex(s[1..]);
    if (std.ascii.eqlIgnoreCase(s, "transparent")) return .{ 0, 0, 0, 0 };
    if (std.mem.indexOfScalar(u8, s, '(')) |open| {
        if (s[s.len - 1] != ')') return null;
        const func = s[0..open];
        var args: [4]f32 = .{ 0, 0, 0, 1 };
        var pct: [4]bool = @splat(false);
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, s[open + 1 .. s.len - 1], " ,/\t\r\n");
        while (it.next()) |tok| {
            if (n == 4) return null;
            var t = tok;
            if (t.len > 0 and t[t.len - 1] == '%') {
                pct[n] = true;
                t = t[0 .. t.len - 1];
            } else if (std.mem.endsWith(u8, t, "deg")) t = t[0 .. t.len - 3];
            args[n] = std.fmt.parseFloat(f32, t) catch return null;
            if (!std.math.isFinite(args[n])) return null;
            n += 1;
        }
        if (n < 3) return null;
        const alpha = if (n == 4) clamp(if (pct[3]) args[3] / 100 else args[3]) else 1;
        if (std.ascii.eqlIgnoreCase(func, "rgb") or std.ascii.eqlIgnoreCase(func, "rgba")) {
            var out: Rgba = undefined;
            for (0..3) |k| out[k] = clamp(if (pct[k]) args[k] / 100 else args[k] / 255);
            out[3] = alpha;
            return out;
        }
        if (std.ascii.eqlIgnoreCase(func, "hsl") or std.ascii.eqlIgnoreCase(func, "hsla")) {
            const h = @mod(args[0], 360) / 360;
            const sat = clamp(args[1] / 100);
            const l = clamp(args[2] / 100);
            const q = if (l < 0.5) l * (1 + sat) else l + sat - l * sat;
            const p = 2 * l - q;
            return .{ hue(p, q, h + 1.0 / 3.0), hue(p, q, h), hue(p, q, h - 1.0 / 3.0), alpha };
        }
        return null;
    }
    return named(s);
}

fn hue(p: f32, q: f32, t0: f32) f32 {
    var t = t0;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

fn clamp(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

fn hex(h: []const u8) ?Rgba {
    var v: [8]u8 = undefined;
    for (h, 0..) |ch, i| {
        if (i >= 8) return null;
        v[i] = std.fmt.charToDigit(ch, 16) catch return null;
    }
    return switch (h.len) {
        3, 4 => .{
            @as(f32, @floatFromInt(v[0] * 17)) / 255,
            @as(f32, @floatFromInt(v[1] * 17)) / 255,
            @as(f32, @floatFromInt(v[2] * 17)) / 255,
            if (h.len == 4) @as(f32, @floatFromInt(v[3] * 17)) / 255 else 1,
        },
        6, 8 => .{
            @as(f32, @floatFromInt(@as(u32, v[0]) * 16 + v[1])) / 255,
            @as(f32, @floatFromInt(@as(u32, v[2]) * 16 + v[3])) / 255,
            @as(f32, @floatFromInt(@as(u32, v[4]) * 16 + v[5])) / 255,
            if (h.len == 8) @as(f32, @floatFromInt(@as(u32, v[6]) * 16 + v[7])) / 255 else 1,
        },
        else => null,
    };
}

fn named(s: []const u8) ?Rgba {
    var buf: [24]u8 = undefined;
    if (s.len > buf.len) return null;
    const key = std.ascii.lowerString(&buf, s);
    const rgb = names.get(key) orelse return null;
    return .{
        @as(f32, @floatFromInt(rgb >> 16)) / 255,
        @as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255,
        @as(f32, @floatFromInt(rgb & 0xff)) / 255,
        1,
    };
}

const names: std.StaticStringMap(u24) = .initComptime(.{
    .{ "aliceblue", 0xf0f8ff },            .{ "antiquewhite", 0xfaebd7 },      .{ "aqua", 0x00ffff },
    .{ "aquamarine", 0x7fffd4 },           .{ "azure", 0xf0ffff },             .{ "beige", 0xf5f5dc },
    .{ "bisque", 0xffe4c4 },               .{ "black", 0x000000 },             .{ "blanchedalmond", 0xffebcd },
    .{ "blue", 0x0000ff },                 .{ "blueviolet", 0x8a2be2 },        .{ "brown", 0xa52a2a },
    .{ "burlywood", 0xdeb887 },            .{ "cadetblue", 0x5f9ea0 },         .{ "chartreuse", 0x7fff00 },
    .{ "chocolate", 0xd2691e },            .{ "coral", 0xff7f50 },             .{ "cornflowerblue", 0x6495ed },
    .{ "cornsilk", 0xfff8dc },             .{ "crimson", 0xdc143c },           .{ "cyan", 0x00ffff },
    .{ "darkblue", 0x00008b },             .{ "darkcyan", 0x008b8b },          .{ "darkgoldenrod", 0xb8860b },
    .{ "darkgray", 0xa9a9a9 },             .{ "darkgreen", 0x006400 },         .{ "darkgrey", 0xa9a9a9 },
    .{ "darkkhaki", 0xbdb76b },            .{ "darkmagenta", 0x8b008b },       .{ "darkolivegreen", 0x556b2f },
    .{ "darkorange", 0xff8c00 },           .{ "darkorchid", 0x9932cc },        .{ "darkred", 0x8b0000 },
    .{ "darksalmon", 0xe9967a },           .{ "darkseagreen", 0x8fbc8f },      .{ "darkslateblue", 0x483d8b },
    .{ "darkslategray", 0x2f4f4f },        .{ "darkslategrey", 0x2f4f4f },     .{ "darkturquoise", 0x00ced1 },
    .{ "darkviolet", 0x9400d3 },           .{ "deeppink", 0xff1493 },          .{ "deepskyblue", 0x00bfff },
    .{ "dimgray", 0x696969 },              .{ "dimgrey", 0x696969 },           .{ "dodgerblue", 0x1e90ff },
    .{ "firebrick", 0xb22222 },            .{ "floralwhite", 0xfffaf0 },       .{ "forestgreen", 0x228b22 },
    .{ "fuchsia", 0xff00ff },              .{ "gainsboro", 0xdcdcdc },         .{ "ghostwhite", 0xf8f8ff },
    .{ "gold", 0xffd700 },                 .{ "goldenrod", 0xdaa520 },         .{ "gray", 0x808080 },
    .{ "grey", 0x808080 },                 .{ "green", 0x008000 },             .{ "greenyellow", 0xadff2f },
    .{ "honeydew", 0xf0fff0 },             .{ "hotpink", 0xff69b4 },           .{ "indianred", 0xcd5c5c },
    .{ "indigo", 0x4b0082 },               .{ "ivory", 0xfffff0 },             .{ "khaki", 0xf0e68c },
    .{ "lavender", 0xe6e6fa },             .{ "lavenderblush", 0xfff0f5 },     .{ "lawngreen", 0x7cfc00 },
    .{ "lemonchiffon", 0xfffacd },         .{ "lightblue", 0xadd8e6 },         .{ "lightcoral", 0xf08080 },
    .{ "lightcyan", 0xe0ffff },            .{ "lightgoldenrodyellow", 0xfafad2 }, .{ "lightgray", 0xd3d3d3 },
    .{ "lightgreen", 0x90ee90 },           .{ "lightgrey", 0xd3d3d3 },         .{ "lightpink", 0xffb6c1 },
    .{ "lightsalmon", 0xffa07a },          .{ "lightseagreen", 0x20b2aa },     .{ "lightskyblue", 0x87cefa },
    .{ "lightslategray", 0x778899 },       .{ "lightslategrey", 0x778899 },    .{ "lightsteelblue", 0xb0c4de },
    .{ "lightyellow", 0xffffe0 },          .{ "lime", 0x00ff00 },              .{ "limegreen", 0x32cd32 },
    .{ "linen", 0xfaf0e6 },                .{ "magenta", 0xff00ff },           .{ "maroon", 0x800000 },
    .{ "mediumaquamarine", 0x66cdaa },     .{ "mediumblue", 0x0000cd },        .{ "mediumorchid", 0xba55d3 },
    .{ "mediumpurple", 0x9370db },         .{ "mediumseagreen", 0x3cb371 },    .{ "mediumslateblue", 0x7b68ee },
    .{ "mediumspringgreen", 0x00fa9a },    .{ "mediumturquoise", 0x48d1cc },   .{ "mediumvioletred", 0xc71585 },
    .{ "midnightblue", 0x191970 },         .{ "mintcream", 0xf5fffa },         .{ "mistyrose", 0xffe4e1 },
    .{ "moccasin", 0xffe4b5 },             .{ "navajowhite", 0xffdead },       .{ "navy", 0x000080 },
    .{ "oldlace", 0xfdf5e6 },              .{ "olive", 0x808000 },             .{ "olivedrab", 0x6b8e23 },
    .{ "orange", 0xffa500 },               .{ "orangered", 0xff4500 },         .{ "orchid", 0xda70d6 },
    .{ "palegoldenrod", 0xeee8aa },        .{ "palegreen", 0x98fb98 },         .{ "paleturquoise", 0xafeeee },
    .{ "palevioletred", 0xdb7093 },        .{ "papayawhip", 0xffefd5 },        .{ "peachpuff", 0xffdab9 },
    .{ "peru", 0xcd853f },                 .{ "pink", 0xffc0cb },              .{ "plum", 0xdda0dd },
    .{ "powderblue", 0xb0e0e6 },           .{ "purple", 0x800080 },            .{ "rebeccapurple", 0x663399 },
    .{ "red", 0xff0000 },                  .{ "rosybrown", 0xbc8f8f },         .{ "royalblue", 0x4169e1 },
    .{ "saddlebrown", 0x8b4513 },          .{ "salmon", 0xfa8072 },            .{ "sandybrown", 0xf4a460 },
    .{ "seagreen", 0x2e8b57 },             .{ "seashell", 0xfff5ee },          .{ "sienna", 0xa0522d },
    .{ "silver", 0xc0c0c0 },               .{ "skyblue", 0x87ceeb },           .{ "slateblue", 0x6a5acd },
    .{ "slategray", 0x708090 },            .{ "slategrey", 0x708090 },         .{ "snow", 0xfffafa },
    .{ "springgreen", 0x00ff7f },          .{ "steelblue", 0x4682b4 },         .{ "tan", 0xd2b48c },
    .{ "teal", 0x008080 },                 .{ "thistle", 0xd8bfd8 },           .{ "tomato", 0xff6347 },
    .{ "turquoise", 0x40e0d0 },            .{ "violet", 0xee82ee },            .{ "wheat", 0xf5deb3 },
    .{ "white", 0xffffff },                .{ "whitesmoke", 0xf5f5f5 },        .{ "yellow", 0xffff00 },
    .{ "yellowgreen", 0x9acd32 },
});

const testing = std.testing;

test "color syntaxes" {
    try testing.expectEqual(Rgba{ 1, 0, 0, 1 }, parse("red").?);
    try testing.expectEqual(Rgba{ 1, 0, 0, 1 }, parse(" #F00 ").?);
    try testing.expectEqual(Rgba{ @as(f32, 0x2e) / 255, @as(f32, 0x34) / 255, @as(f32, 0x36) / 255, 1 }, parse("#2e3436").?);
    try testing.expectEqual(Rgba{ 0, 0, 0, @as(f32, 0x80) / 255 }, parse("#00000080").?);
    try testing.expectEqual(Rgba{ 1, 0.5, 0, 0.25 }, parse("rgba(255, 50%, 0, .25)").?);
    try testing.expectEqual(Rgba{ 0, 0, 0, 0 }, parse("Transparent").?);
    const h = parse("hsl(120, 100%, 25%)").?;
    try testing.expectApproxEqAbs(@as(f32, 0.5), h[1], 1e-5);
    for ([_][]const u8{ "", "#12", "#ggg", "rgb(1,2)", "notacolor", "rgb(1,2,3,4,5)", "url(#a)" }) |bad|
        try testing.expect(parse(bad) == null);
}
