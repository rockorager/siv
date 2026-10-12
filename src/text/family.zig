//! Matching styles within a family of faces the application added (D13):
//! CSS Fonts 4 §5.2's font matching, with each face's styles read from
//! its data (`font.Description`), variable faces covering their axis
//! ranges, and synthetic bold and oblique where the chosen face lacks the
//! style.

const std = @import("std");
const font = @import("font.zig");
const fontconfig = @import("fontconfig.zig");

const Description = font.Description;
const Instance = font.Instance;
const Axis = font.Axis;

pub const Request = struct {
    /// CSS weight.
    weight: f32 = 400,
    /// Percent of normal width.
    width: f32 = 100,
    slant: fontconfig.Slant = .roman,
    /// Pixels per em, for the opsz axis; 0 leaves it at its default.
    size: f32 = 0,
};

/// The oblique angle CSS uses for `oblique` and for italic requests that
/// only an oblique face (or slnt axis) can serve: 14 degrees, leaning
/// right, so -14 in slnt's counter-clockwise degrees.
const oblique_angle: f32 = -14;

/// Weights from 600 up ask for synthetic bold from lighter faces, as in
/// browsers.
const bold_threshold: f32 = 600;

/// Writes the indices of `faces` best match first into `out` (as long as
/// `faces`): CSS narrows by width, then slant, then weight, so the sort
/// key is that triple. Ties keep the order faces were added in, so faces
/// of one style added for different scripts form a fallback chain.
pub fn rank(faces: []const Description, request: Request, out: []u32) void {
    std.debug.assert(out.len == faces.len);
    for (out, 0..) |*o, i| o.* = @intCast(i);
    const Ctx = struct {
        faces: []const Description,
        request: Request,
        fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            const ka = key(ctx.faces[a], ctx.request);
            const kb = key(ctx.faces[b], ctx.request);
            for (ka, kb) |x, y| if (x != y) return x < y;
            return false;
        }
    };
    std.sort.insertion(u32, out, Ctx{ .faces = faces, .request = request }, Ctx.lessThan);
}

fn key(d: Description, r: Request) [3]f32 {
    return .{ widthScore(d.width, r.width), slantScore(d, r.slant), weightScore(d.weight, r.weight) };
}

/// The value of `axis` closest to `v`.
fn nearest(axis: Axis, v: f32) f32 {
    return axis.clamp(v);
}

/// CSS: narrower widths first for normal and narrower requests, wider
/// first for wider ones. Lower is better.
fn widthScore(axis: Axis, want: f32) f32 {
    const c = nearest(axis, want);
    if (c == want) return 0;
    if (want <= 100) return if (c < want) want - c else 1000 + c - want;
    return if (c > want) c - want else 1000 + want - c;
}

/// CSS: 400 to 500 look up to 500, then down, then above 500; lighter
/// requests look down first, bolder ones up first.
fn weightScore(axis: Axis, want: f32) f32 {
    const c = nearest(axis, want);
    if (c == want) return 0;
    if (want >= 400 and want <= 500) {
        if (c > want and c <= 500) return c - want;
        if (c < want) return 1000 + want - c;
        return 2000 + c - want;
    }
    if (want < 400) return if (c < want) want - c else 1000 + c - want;
    return if (c > want) c - want else 1000 + want - c;
}

const Style = enum { upright, oblique, italic };

fn covers(d: Description, style: Style) bool {
    return switch (style) {
        .italic => d.italic.max >= 1,
        .oblique => d.italic.min < 1 and d.slant.min < 0,
        .upright => d.italic.min < 1 and d.slant.contains(0),
    };
}

/// CSS: italic falls back to oblique, then upright; oblique to italic,
/// then upright; upright to oblique, then italic.
fn slantScore(d: Description, slant: fontconfig.Slant) f32 {
    const order: [3]Style = switch (slant) {
        .roman => .{ .upright, .oblique, .italic },
        .italic => .{ .italic, .oblique, .upright },
        .oblique => .{ .oblique, .italic, .upright },
    };
    for (order, 0..) |style, i| if (covers(d, style)) return @floatFromInt(i);
    return 3;
}

/// The instance of a face that serves `request`: its axes set as close to
/// the request as they go (left at their defaults where the request is
/// the default), and synthetic bold or oblique where the face cannot
/// reach the style.
pub fn instanceFor(d: Description, r: Request) Instance {
    var inst: Instance = .{};
    var weight = d.weight.default;
    if (d.axes.wght) {
        weight = d.weight.clamp(r.weight);
        if (weight != d.weight.default) inst.wght = weight;
    }
    if (d.axes.wdth) {
        const w = d.width.clamp(r.width);
        if (w != d.width.default) inst.wdth = w;
    }
    if (r.size > 0) if (d.opsz) |opsz| {
        const v = opsz.clamp(r.size);
        if (v != opsz.default) inst.opsz = v;
    };
    if (r.weight >= bold_threshold and weight < bold_threshold) inst.synthetic.bold = font.Synthetic.bold_strength;

    const slanted = switch (r.slant) {
        .roman => blk: {
            // Back to upright where an axis allows it.
            if (d.axes.ital and d.italic.default != 0 and d.italic.contains(0)) inst.ital = 0;
            if (d.axes.slnt and d.slant.default != 0 and d.slant.contains(0)) inst.slnt = 0;
            break :blk true;
        },
        .italic => blk: {
            if (d.axes.ital and d.italic.max >= 1) {
                if (d.italic.default != 1) inst.ital = 1;
                break :blk true;
            }
            if (d.italic.min >= 1 or d.slant.max < 0) break :blk true;
            if (d.axes.slnt and d.slant.min < 0) {
                inst.slnt = d.slant.clamp(oblique_angle);
                break :blk true;
            }
            break :blk false;
        },
        .oblique => blk: {
            if (d.slant.max < 0 or d.italic.min >= 1) break :blk true;
            if (d.axes.slnt and d.slant.min < 0) {
                inst.slnt = d.slant.clamp(oblique_angle);
                break :blk true;
            }
            if (d.axes.ital and d.italic.max >= 1) {
                inst.ital = 1;
                break :blk true;
            }
            break :blk false;
        },
    };
    if (!slanted) inst.synthetic.slant = font.Synthetic.oblique_slant;
    return inst;
}

const testing = std.testing;
const test_fonts = font.test_fonts;

fn static(weight: f32, italic: bool) Description {
    return .{
        .weight = .point(weight),
        .width = .point(100),
        .italic = .point(if (italic) 1 else 0),
        .slant = .point(if (italic) -12 else 0),
        .opsz = null,
    };
}

fn ranked(faces: []const Description, r: Request) [8]u32 {
    var out: [8]u32 = @splat(99);
    rank(faces, r, out[0..faces.len]);
    return out;
}

test "CSS weight and slant order within a family" {
    // Regular, Bold, Italic, Light.
    const faces = [_]Description{ static(400, false), static(700, false), static(400, true), static(300, false) };
    try testing.expectEqual(1, ranked(&faces, .{ .weight = 700 })[0]);
    try testing.expectEqual(1, ranked(&faces, .{ .weight = 600 })[0]); // bolder first
    try testing.expectEqual(0, ranked(&faces, .{ .weight = 500 })[0]); // 400..500 looks down after up to 500
    try testing.expectEqual(3, ranked(&faces, .{ .weight = 200 })[0]); // lighter first
    // Slant narrows before weight: bold italic is the italic face.
    try testing.expectEqual(2, ranked(&faces, .{ .weight = 700, .slant = .italic })[0]);
    try testing.expectEqual(2, ranked(&faces, .{ .slant = .oblique })[0]);
    // The whole order for regular: 400, 300 (down), then 700 (above 500),
    // then the italic.
    try testing.expectEqualSlices(u32, &.{ 0, 3, 1, 2 }, ranked(&faces, .{})[0..4]);
}

test "faces of one style keep the order they were added in" {
    const faces = [_]Description{ static(400, false), static(400, false), static(700, false) };
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, ranked(&faces, .{})[0..3]);
    try testing.expectEqualSlices(u32, &.{ 2, 0, 1 }, ranked(&faces, .{ .weight = 700 })[0..3]);
}

test "synthesis where the face lacks the style" {
    const regular = static(400, false);
    try testing.expect(instanceFor(regular, .{}).isDefault());
    const bold = instanceFor(regular, .{ .weight = 700 });
    try testing.expectEqual(font.Synthetic.bold_strength, bold.synthetic.bold);
    try testing.expectEqual(0, bold.synthetic.slant);
    try testing.expectEqual(font.Synthetic.oblique_slant, instanceFor(regular, .{ .slant = .italic }).synthetic.slant);
    // Semibold from a medium face is synthesized; medium from regular is not.
    try testing.expect(instanceFor(static(500, false), .{ .weight = 600 }).synthetic.bold != 0);
    try testing.expect(instanceFor(regular, .{ .weight = 500 }).isDefault());
    // An italic face serves oblique and italic requests as it is.
    try testing.expect(instanceFor(static(400, true), .{ .slant = .oblique }).isDefault());
    try testing.expect(instanceFor(static(700, false), .{ .weight = 700 }).isDefault());
}

test "variable faces set their axes from the request and the size" {
    var cache: font.FontCache = .init(testing.allocator);
    defer cache.deinit();
    const vf = try cache.add(test_fonts.siv_variable, 0, .borrowed);
    const d = cache.face(vf).?.description;
    try testing.expect(d.axes.wght and d.axes.wdth and d.axes.slnt and !d.axes.ital);
    try testing.expectEqual(Axis{ .min = 100, .default = 400, .max = 900 }, d.weight);
    try testing.expectEqual(Axis{ .min = 8, .default = 14, .max = 72 }, d.opsz.?);

    // Bold from the wght axis, no synthesis; oblique from slnt, clamped to
    // its -12; condensed from wdth.
    const inst = instanceFor(d, .{ .weight = 700, .slant = .italic, .width = 75, .size = 40 });
    try testing.expectEqual(Instance{ .wght = 700, .wdth = 75, .slnt = -12, .opsz = 40 }, inst);
    // Black clamps to 900; the default request is the default instance;
    // opsz clamps to its range and stays unset at its default.
    try testing.expectEqual(Instance{ .wght = 900, .opsz = 72 }, instanceFor(d, .{ .weight = 1000, .size = 100 }));
    try testing.expect(instanceFor(d, .{ .size = 14 }).isDefault());

    // The instance's glyphs follow: the I's advance is two side bearings
    // and a stem (testdata/make_test_fonts.py), 2 * 30 + 156 at opsz 72
    // and wght 700.
    const id = try cache.instance(vf, .{ .wght = 700, .opsz = 72 });
    const face = cache.face(id).?;
    var glyph: u32 = 0;
    try testing.expect(@import("harfbuzz").hb_font_get_nominal_glyph(face.font, 'I', &glyph) != 0);
    try testing.expectEqual(216, @import("harfbuzz").hb_font_get_glyph_h_advance(face.font, glyph));
    try testing.expectEqual(id, try cache.instance(vf, .{ .wght = 700, .opsz = 72 }));
    try testing.expectEqual(vf, try cache.instance(id, .{}));
    try testing.expect(face.key != cache.face(vf).?.key);
}

test "static faces describe themselves from their tables" {
    var cache: font.FontCache = .init(testing.allocator);
    defer cache.deinit();
    const ids = [_]font.FontId{
        try cache.add(test_fonts.siv_regular, 0, .borrowed),
        try cache.add(test_fonts.siv_bold, 0, .borrowed),
        try cache.add(test_fonts.siv_italic, 0, .borrowed),
    };
    var faces: [3]Description = undefined;
    for (ids, &faces) |id, *d| d.* = cache.face(id).?.description;
    try testing.expectEqual(Axis.point(700), faces[1].weight);
    try testing.expectEqual(Axis.point(1), faces[2].italic);
    try testing.expectEqual(Axis.point(-12), faces[2].slant);
    try testing.expectEqual(Axis.point(100), faces[0].width);
    try testing.expectEqual(1, ranked(&faces, .{ .weight = 700 })[0]);
    try testing.expectEqual(2, ranked(&faces, .{ .weight = 700, .slant = .italic })[0]);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("SivTest", cache.face(ids[1]).?.familyName(&buf));
}

test "synthetic styles change outlines and advances, not the base face" {
    const hb = @import("harfbuzz");
    var cache: font.FontCache = .init(testing.allocator);
    defer cache.deinit();
    const regular = try cache.add(test_fonts.siv_regular, 0, .borrowed);
    const bold = try cache.instance(regular, .{ .synthetic = .{ .bold = font.Synthetic.bold_strength } });
    const oblique = try cache.instance(regular, .{ .synthetic = .{ .slant = font.Synthetic.oblique_slant } });
    var glyph: u32 = 0;
    _ = hb.hb_font_get_nominal_glyph(cache.face(regular).?.font, 'I', &glyph);
    const advance = hb.hb_font_get_glyph_h_advance(cache.face(regular).?.font, glyph);
    // 1/24 em of 1000 units, rounded: 42.
    try testing.expectEqual(advance + 42, hb.hb_font_get_glyph_h_advance(cache.face(bold).?.font, glyph));
    try testing.expectEqual(advance, hb.hb_font_get_glyph_h_advance(cache.face(oblique).?.font, glyph));
    // The stem (90 units, 700 tall) is 42 wider and leans right by 700 tan 14°.
    const plain = cache.face(regular).?.glyphBounds(glyph, 1000).?;
    const wide = cache.face(bold).?.glyphBounds(glyph, 1000).?;
    const leaning = cache.face(oblique).?.glyphBounds(glyph, 1000).?;
    try testing.expectApproxEqAbs(plain.width + 42, wide.width, 1);
    try testing.expectApproxEqAbs(plain.width + 700 * font.Synthetic.oblique_slant, leaning.width, 1.5);
    try testing.expect(cache.face(bold).?.key != cache.face(regular).?.key);
}
