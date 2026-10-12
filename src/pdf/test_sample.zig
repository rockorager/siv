//! A page of every display list construct, for the PDF tests: solid,
//! translucent, and even-odd fills, dashed strokes, linear, radial, and
//! sweep gradients (one translucent), a clipped, transformed layer with
//! opacity and a blend mode, an image, a box shadow, and text with its
//! cluster data. Solid regions sit at known places so that rendered
//! pages can be probed.

const std = @import("std");
const scene = @import("scene");
const raster = @import("raster");
const text = @import("text");
const hb = @import("harfbuzz_subset");

pub const width: f32 = 300;
pub const height: f32 = 400;
pub const words = "Hello, siv!";
/// Distinct glyphs of `words`.
pub const distinct_glyphs = 10;

/// Where a solid color shows, in page points (y down), and the color
/// (sRGB, 8-bit) a renderer should show there.
pub const Probe = struct { x: f32, y: f32, rgb: [3]u8 };
pub const probes = [_]Probe{
    .{ .x = 70, .y = 50, .rgb = .{ 255, 0, 0 } }, // the red rectangle
    .{ .x = 10, .y = 390, .rgb = .{ 255, 255, 255 } }, // the background
    .{ .x = 60, .y = 115, .rgb = .{ 0, 128, 0 } }, // the even-odd ring
    .{ .x = 75, .y = 135, .rgb = .{ 255, 255, 255 } }, // the ring's hole
    .{ .x = 154, .y = 230, .rgb = .{ 255, 0, 0 } }, // the linear gradient's padded start
    .{ .x = 276, .y = 230, .rgb = .{ 0, 0, 255 } }, // and end
    .{ .x = 45, .y = 345, .rgb = .{ 0, 0, 0 } }, // the image's black pixel
    .{ .x = 75, .y = 345, .rgb = .{ 255, 255, 255 } }, // and its white one
};

pub fn build(b: *scene.Builder, face: *const text.Face) !void {
    const gpa = b.gpa;
    try b.fillRect(.{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height }, .color(.white));
    try b.fillRect(.{ .x0 = 20, .y0 = 20, .x1 = 120, .y1 = 80 }, .color(.srgb(1, 0, 0, 1)));
    try b.fillRoundedRect(.{ .x0 = 150, .y0 = 20, .x1 = 280, .y1 = 80 }, .{ .tl = .{ .x = 10, .y = 10 }, .tr = .{ .x = 10, .y = 10 }, .br = .{ .x = 10, .y = 10 }, .bl = .{ .x = 10, .y = 10 } }, .color(.srgb(0, 0, 1, 0.5)));

    // A ring: two squares, even-odd.
    var ring: raster.PathBuilder = .init(gpa);
    defer ring.deinit();
    try ring.rect(.{ .x0 = 20, .y0 = 100, .x1 = 130, .y1 = 170 });
    try ring.rect(.{ .x0 = 50, .y0 = 120, .x1 = 100, .y1 = 150 });
    try b.fillPath(ring.path(), .even_odd, .color(.srgb(0, 128.0 / 255.0, 0, 1)));

    // A dashed curve.
    var curve: raster.PathBuilder = .init(gpa);
    defer curve.deinit();
    try curve.moveTo(150, 100);
    try curve.cubicTo(180, 180, 240, 60, 280, 160);
    try b.stroke(.{ .path = curve.path() }, .{ .width = 3, .cap = .round, .dashes = &.{ 6, 4 }, .dash_offset = 2 }, .color(.black));

    const rb = [_]scene.Stop{ .{ .offset = 0, .color = .srgb(1, 0, 0, 1) }, .{ .offset = 1, .color = .srgb(0, 0, 1, 1) } };
    try b.fillRect(.{ .x0 = 150, .y0 = 200, .x1 = 280, .y1 = 260 }, .{ .gradient = .{ .geometry = .{ .linear = .{ .p0 = .{ .x = 160, .y = 0 }, .p1 = .{ .x = 270, .y = 0 } } }, .stops = &rb } });
    const fade = [_]scene.Stop{ .{ .offset = 0, .color = .srgb(1, 0.8, 0, 1) }, .{ .offset = 0.5, .color = .srgb(0, 0.5, 1, 0.3) } };
    try b.fillRect(.{ .x0 = 20, .y0 = 190, .x1 = 130, .y1 = 280 }, .{ .gradient = .{ .geometry = .{ .radial = .{ .c0 = .{ .x = 75, .y = 235 }, .r0 = 0, .c1 = .{ .x = 75, .y = 235 }, .r1 = 50 } }, .stops = &fade, .extend = .reflect } });
    const wheel = [_]scene.Stop{ .{ .offset = 0, .color = .srgb(1, 0, 0, 1) }, .{ .offset = 0.33, .color = .srgb(0, 1, 0, 1) }, .{ .offset = 0.66, .color = .srgb(0, 0, 1, 1) }, .{ .offset = 1, .color = .srgb(1, 0, 0, 1) } };
    var circle: raster.PathBuilder = .init(gpa);
    defer circle.deinit();
    try circle.ellipse(.{ .x0 = 160, .y0 = 280, .x1 = 220, .y1 = 340 });
    try b.fillPath(circle.path(), .nonzero, .{ .gradient = .{ .geometry = .{ .sweep = .{ .center = .{ .x = 190, .y = 310 }, .start_angle = 0, .end_angle = 2 * std.math.pi } }, .stops = &wheel } });

    // A clipped, rotated layer at half opacity, multiplied.
    try b.pushLayer(.{
        .transform = raster.Affine.rotate(0.2).then(.translate(250, 300)),
        .opacity = 0.5,
        .blend = .multiply,
        .clip = .{ .shape = .{ .rect = .{ .x0 = -20, .y0 = -20, .x1 = 20, .y1 = 20 } } },
    });
    try b.fillRect(.{ .x0 = -30, .y0 = -30, .x1 = 30, .y1 = 30 }, .color(.srgb(1, 1, 0, 1)));
    try b.popLayer();

    // A 2x2 image, nearest: black and white columns.
    const px = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255 };
    try b.image(.{
        .image = .{ .pixels = &px, .width = 2, .height = 2, .stride = 8, .format = .rgba8_srgb, .key = 1 },
        .src = .{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 2 },
        .dst = .{ .x0 = 30, .y0 = 330, .x1 = 90, .y1 = 360 },
        .filter = .nearest,
    });

    try b.shadow(.{ .shape = .{ .rect = .{ .x0 = 230, .y0 = 340, .x1 = 280, .y1 = 380 }, .radii = .{} }, .offset = .{ .x = 3, .y = 3 }, .sigma = 4, .color = .srgb(0, 0, 0, 0.5) });

    // Text, with its clusters.
    const font: *hb.hb_font_t = @ptrCast(face.font);
    const size: f32 = 24;
    const scale = size / @as(f32, @floatFromInt(face.upem));
    var glyphs: [words.len]scene.Glyph = undefined;
    var clusters: [words.len]u32 = undefined;
    var x: f32 = 20;
    for (words, 0..) |ch, i| {
        var gid: u32 = 0;
        _ = hb.hb_font_get_nominal_glyph(font, ch, &gid);
        glyphs[i] = .{ .id = gid, .x = x, .y = 310 };
        clusters[i] = @intCast(i);
        x += @as(f32, @floatFromInt(hb.hb_font_get_glyph_h_advance(font, gid))) * scale;
    }
    try b.glyphs(.{
        .font = .{ .handle = face.font, .key = face.key },
        .size = size,
        .glyphs = &glyphs,
        .paint = .color(.black),
        .bounds = .{ .x0 = 20, .y0 = 285, .x1 = x, .y1 = 320 },
        .text = .{ .bytes = words, .clusters = &clusters },
    });
}
