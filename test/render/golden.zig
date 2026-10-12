//! CPU renderer golden images (D24). Each scene renders through the full
//! renderer (worker pool, tiles, encoding) and is compared with a PNG under
//! test/golden/render/. These images are the oracle the Vulkan renderer is
//! diffed against later.
//!
//! Run from the repository root. To accept new output:
//!
//!     SIV_UPDATE_GOLDEN=1 zig build test-headless
//!
//! On a mismatch the actual image and a diff are written to
//! .zig-cache/golden-failures/.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const render_cpu = @import("render_cpu");
const pool = @import("pool");
const text_engine = @import("text");
const png = @import("png.zig");
const hb = render_cpu.glyph.hb;

const Affine = raster.Affine;
const Rect = raster.Rect;
const Color = scene.Color;
const Builder = scene.Builder;

const golden_dir = "test/golden/render";
const failure_dir = ".zig-cache/golden-failures";

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    pb: raster.PathBuilder,
    roboto: Font,
    colr: Font,
    checker: [32 * 32 * 4]u8 = undefined,
    ramp: [64 * 8]render_cpu.Pixel = undefined,
    glyphs: std.ArrayList(scene.Glyph) = .empty,
    /// Fonts for the text-engine scene; display lists refer to its faces.
    fonts: ?text_engine.FontCache = null,
    /// A generated sbix bitmap font and its bytes.
    sbix: ?Font = null,
    sbix_bytes: []u8 = &.{},

    pub fn deinit(c: *Ctx) void {
        if (c.fonts) |*f| f.deinit();
        if (c.sbix) |f| f.deinit();
        c.gpa.free(c.sbix_bytes);
        c.pb.deinit();
        c.roboto.deinit();
        c.colr.deinit();
        c.glyphs.deinit(c.gpa);
    }
};

pub const Font = struct {
    font: *hb.hb_font_t,
    key: u64,
    upem: f32,

    pub fn init(data: []const u8, key: u64) Font {
        const blob = hb.hb_blob_create(data.ptr, @intCast(data.len), hb.HB_MEMORY_MODE_READONLY, null, null);
        defer hb.hb_blob_destroy(blob);
        const face = hb.hb_face_create(blob, 0);
        defer hb.hb_face_destroy(face);
        return .{ .font = hb.hb_font_create(face).?, .key = key, .upem = @floatFromInt(hb.hb_face_get_upem(face)) };
    }

    fn deinit(f: Font) void {
        hb.hb_font_destroy(f.font);
    }

    fn handle(f: Font) scene.Font {
        return .{ .handle = f.font, .key = f.key };
    }
};

/// Shapes `text` with HarfBuzz and adds a glyph run at baseline (x, y).
fn text(c: *Ctx, b: *Builder, f: Font, str: []const u8, x: f32, y: f32, size: f32, paint: scene.Paint) !void {
    const buf = hb.hb_buffer_create();
    defer hb.hb_buffer_destroy(buf);
    hb.hb_buffer_add_utf8(buf, str.ptr, @intCast(str.len), 0, @intCast(str.len));
    hb.hb_buffer_guess_segment_properties(buf);
    hb.hb_shape(f.font, buf, null, 0);
    var n: c_uint = 0;
    const infos = hb.hb_buffer_get_glyph_infos(buf, &n);
    const pos = hb.hb_buffer_get_glyph_positions(buf, &n);
    const s = size / f.upem;
    c.glyphs.clearRetainingCapacity();
    var pen: f32 = x;
    for (0..n) |i| {
        try c.glyphs.append(c.gpa, .{
            .id = infos[i].codepoint,
            .x = pen + @as(f32, @floatFromInt(pos[i].x_offset)) * s,
            .y = y - @as(f32, @floatFromInt(pos[i].y_offset)) * s,
        });
        pen += @as(f32, @floatFromInt(pos[i].x_advance)) * s;
    }
    try b.glyphs(.{
        .font = f.handle(),
        .size = size,
        .glyphs = c.glyphs.items,
        .paint = paint,
        .bounds = .{ .x0 = x - size, .y0 = y - size * 1.3, .x1 = pen + size, .y1 = y + size * 0.5 },
    });
}

fn checkerImage(c: *Ctx) scene.ImageRef {
    for (0..32) |y| for (0..32) |x| {
        const on = ((x / 4) + (y / 4)) % 2 == 0;
        const p = c.checker[(y * 32 + x) * 4 ..][0..4];
        p.* = if (on) .{ 0xe0, 0x30, 0x60, 0xff } else .{ 0x30, 0xa0, 0xe0, 0x90 };
    };
    return .{ .pixels = &c.checker, .width = 32, .height = 32, .stride = 32 * 4, .format = .rgba8_srgb, .key = 1 };
}

fn rampImage(c: *Ctx) scene.ImageRef {
    for (0..8) |y| for (0..64) |x| {
        const v: u16 = @intCast(x * 65535 / 63);
        c.ramp[y * 64 + x] = .{ v, @intCast(y * 65535 / 7), 65535 - v, 65535 };
    };
    return .{ .pixels = @ptrCast(&c.ramp), .width = 64, .height = 8, .stride = 64 * 8, .format = .rgba16_linear_premul, .key = 2 };
}

const ink = Color.srgb8(0x1a, 0x1a, 0x1a, 0xff);
const blue = Color.srgb8(0x25, 0x63, 0xeb, 0xff);
const orange = Color.srgb8(0xf5, 0x9e, 0x0b, 0xff);
const green = Color.srgb8(0x10, 0xb9, 0x81, 0xff);
const pink = Color.srgb8(0xec, 0x48, 0x99, 0xff);

fn stops2(a: Color, b: Color) [2]scene.Stop {
    return .{ .{ .offset = 0, .color = a }, .{ .offset = 1, .color = b } };
}

fn shapes(c: *Ctx, b: *Builder) !void {
    // Pixel-aligned, fractional, and thin rectangles.
    try b.fillRect(.xywh(10, 10, 40, 30), .color(blue));
    try b.fillRect(.xywh(60.25, 10.5, 40.5, 29.75), .color(blue));
    for (0..8) |i| {
        const f: f32 = @floatFromInt(i);
        try b.fillRect(.xywh(110 + f * 5 + f * 0.125, 10, 0.25 + f * 0.25, 30), .color(ink));
    }
    // Rounded rectangles: circular, elliptical, per-corner, and rotated.
    try b.fillRoundedRect(.xywh(160, 10, 50, 30), .uniform(10, 10), .color(orange));
    try b.fillRoundedRect(.xywh(220, 10, 50, 30), .uniform(20, 8), .color(orange));
    try b.fillRoundedRect(.xywh(280, 10, 50, 30), .{ .tl = .{ .x = 0, .y = 0 }, .tr = .{ .x = 15, .y = 15 }, .br = .{ .x = 4, .y = 4 }, .bl = .{ .x = 25, .y = 10 } }, .color(orange));
    try b.pushLayer(.{ .transform = Affine.rotate(0.35).then(.translate(370, 22)) });
    try b.fillRoundedRect(.xywh(-25, -12, 50, 24), .uniform(8, 8), .color(green));
    try b.popLayer();

    // Star: nonzero vs even-odd.
    for (0..2) |k| {
        c.pb.reset();
        const cx: f32 = 50 + @as(f32, @floatFromInt(k)) * 90;
        for (0..5) |i| {
            const a = @as(f32, @floatFromInt(i)) * 4 * std.math.pi / 5.0 - std.math.pi / 2.0;
            const x = cx + 35 * @cos(a);
            const y = 95 + 35 * @sin(a);
            if (i == 0) try c.pb.moveTo(x, y) else try c.pb.lineTo(x, y);
        }
        try c.pb.close();
        try b.fillPath(c.pb.path(), if (k == 0) .nonzero else .even_odd, .color(pink));
    }
    // Curves.
    c.pb.reset();
    try c.pb.moveTo(200, 60);
    try c.pb.quadTo(260, 60, 240, 100);
    try c.pb.cubicTo(230, 140, 180, 90, 200, 60);
    try c.pb.close();
    try c.pb.ellipse(.xywh(260, 60, 70, 50));
    try c.pb.ellipse(.xywh(280, 72, 30, 26));
    try b.fillPath(c.pb.path(), .even_odd, .color(blue));

    // Strokes: joins, caps, dashes, hairlines, under a non-uniform scale.
    const joins = [_]raster.Join{ .miter, .round, .bevel };
    const caps = [_]raster.Cap{ .butt, .round, .square };
    for (0..3) |i| {
        const x: f32 = 20 + @as(f32, @floatFromInt(i)) * 70;
        c.pb.reset();
        try c.pb.moveTo(x, 190);
        try c.pb.lineTo(x + 25, 145);
        try c.pb.lineTo(x + 50, 190);
        try b.stroke(.{ .path = c.pb.path() }, .{ .width = 10, .join = joins[i], .cap = caps[i] }, .color(ink));
    }
    c.pb.reset();
    try c.pb.moveTo(230, 150);
    try c.pb.cubicTo(270, 120, 300, 200, 390, 160);
    try b.stroke(.{ .path = c.pb.path() }, .{ .width = 4, .cap = .round, .dashes = &.{ 12, 6, 2, 6 } }, .color(green));
    for (0..6) |i| {
        const f: f32 = @floatFromInt(i);
        c.pb.reset();
        try c.pb.moveTo(230, 175 + f * 4);
        try c.pb.lineTo(390, 172 + f * 5);
        try b.stroke(.{ .path = c.pb.path() }, .{ .width = 0.25 + f * 0.25 }, .color(ink));
    }
    try b.pushLayer(.{ .transform = Affine.scale(2, 0.75).then(.translate(300, 100)) });
    try b.stroke(.{ .rounded_rect = .{ .rect = .xywh(0, 0, 40, 40), .radii = .uniform(8, 8) } }, .{ .width = 3 }, .color(pink));
    try b.popLayer();
}

fn gradients(_: *Ctx, b: *Builder) !void {
    const s = stops2(blue, orange);
    const multi = [_]scene.Stop{
        .{ .offset = 0, .color = pink },
        .{ .offset = 0.3, .color = Color.srgb8(0xff, 0xff, 0xff, 0x40) },
        .{ .offset = 0.3, .color = green },
        .{ .offset = 1, .color = blue },
    };
    const extends = [_]scene.Extend{ .pad, .repeat, .reflect };
    for (extends, 0..) |e, i| {
        const y: f32 = 10 + @as(f32, @floatFromInt(i)) * 35;
        try b.fillRect(.xywh(10, y, 180, 30), .{ .gradient = .{
            .geometry = .{ .linear = .{ .p0 = .{ .x = 60, .y = 0 }, .p1 = .{ .x = 100, .y = 0 } } },
            .stops = &s,
            .extend = e,
        } });
        try b.fillRect(.xywh(200, y, 190, 30), .{ .gradient = .{
            .geometry = .{ .linear = .{ .p0 = .{ .x = 230, .y = y }, .p1 = .{ .x = 290, .y = y + 30 } } },
            .stops = &multi,
            .extend = e,
        } });
    }
    // Radial: concentric, focal inside, cone (start circle outside).
    try b.fillRect(.xywh(10, 120, 120, 120), .{ .gradient = .{
        .geometry = .{ .radial = .{ .c0 = .{ .x = 70, .y = 180 }, .r0 = 5, .c1 = .{ .x = 70, .y = 180 }, .r1 = 55 } },
        .stops = &multi,
    } });
    try b.fillRect(.xywh(140, 120, 120, 120), .{ .gradient = .{
        .geometry = .{ .radial = .{ .c0 = .{ .x = 175, .y = 160 }, .r0 = 0, .c1 = .{ .x = 200, .y = 180 }, .r1 = 55 } },
        .stops = &s,
        .extend = .repeat,
    } });
    try b.fillRect(.xywh(270, 120, 120, 120), .{ .gradient = .{
        .geometry = .{ .radial = .{ .c0 = .{ .x = 290, .y = 150 }, .r0 = 8, .c1 = .{ .x = 350, .y = 200 }, .r1 = 30 } },
        .stops = &s,
    } });
    // Sweep, with a gradient transform.
    try b.fillRoundedRect(.xywh(10, 250, 120, 80), .uniform(12, 12), .{ .gradient = .{
        .geometry = .{ .sweep = .{ .center = .{ .x = 70, .y = 290 }, .start_angle = 0, .end_angle = 2 * std.math.pi } },
        .stops = &multi,
    } });
    try b.fillRect(.xywh(140, 250, 250, 80), .{ .gradient = .{
        .geometry = .{ .sweep = .{ .center = .zero, .start_angle = 0.5, .end_angle = 2 } },
        .stops = &s,
        .extend = .reflect,
        .transform = Affine.scale(1, 0.4).then(.translate(265, 290)),
    } });
}

fn layers(c: *Ctx, b: *Builder) !void {
    // Opacity groups versus per-item opacity: the group shows no overlap.
    try b.pushLayer(.{ .opacity = 0.5 });
    try b.fillRect(.xywh(10, 10, 50, 50), .color(blue));
    try b.fillRect(.xywh(35, 35, 50, 50), .color(blue));
    try b.popLayer();
    try b.fillRect(.xywh(100, 10, 50, 50), .color(blue.withAlpha(0.5)));
    try b.fillRect(.xywh(125, 35, 50, 50), .color(blue.withAlpha(0.5)));

    // Nested clips: rounded rect, then a path, then a rotated rectangle.
    try b.pushLayer(.{ .clip = .{ .shape = .{ .rounded_rect = .{ .rect = .xywh(200, 10, 190, 80), .radii = .uniform(20, 20) } } } });
    try b.fillRect(.xywh(190, 0, 210, 100), .color(orange));
    c.pb.reset();
    try c.pb.ellipse(.xywh(230, 20, 120, 90));
    try b.pushLayer(.{ .clip = .{ .shape = .{ .path = c.pb.path() } } });
    try b.fillRect(.xywh(190, 0, 210, 100), .color(green));
    try b.pushLayer(.{ .transform = Affine.rotate(-0.4).then(.translate(300, 60)), .clip = .{ .shape = .{ .rect = .xywh(-60, -12, 120, 24) } } });
    try b.fillRect(.xywh(-100, -100, 200, 200), .color(ink));
    try b.popLayer();
    try b.popLayer();
    try b.popLayer();

    // Every blend mode: a pink circle over a blue-to-orange gradient tile.
    const s = stops2(blue, orange);
    const modes = std.enums.values(scene.BlendMode);
    for (modes, 0..) |m, i| {
        const x: f32 = 10 + @as(f32, @floatFromInt(i % 7)) * 55;
        const y: f32 = 110 + @as(f32, @floatFromInt(i / 7)) * 55;
        try b.pushLayer(.{ .isolate = true, .clip = .{ .shape = .{ .rect = .xywh(x, y, 50, 50) } } });
        try b.fillRect(.xywh(x, y, 50, 50), .{ .gradient = .{ .geometry = .{ .linear = .{ .p0 = .{ .x = x, .y = y }, .p1 = .{ .x = x + 50, .y = y } } }, .stops = &s } });
        try b.pushLayer(.{ .blend = m });
        c.pb.reset();
        try c.pb.ellipse(.xywh(x + 10, y + 5, 35, 35));
        try b.fillPath(c.pb.path(), .nonzero, .color(pink.withAlpha(0.8)));
        try b.popLayer();
        try b.popLayer();
    }
}

fn images(c: *Ctx, b: *Builder) !void {
    const img = checkerImage(c);
    const full: Rect = .xywh(0, 0, 32, 32);
    try b.image(.{ .image = img, .src = full, .dst = .xywh(10, 10, 96, 96), .filter = .nearest });
    try b.image(.{ .image = img, .src = full, .dst = .xywh(116, 10, 96, 96), .filter = .linear });
    try b.image(.{ .image = img, .src = .xywh(4, 4, 8, 8), .dst = .xywh(222, 10, 96, 96), .filter = .linear });
    try b.pushLayer(.{ .transform = Affine.rotate(0.5).then(.translate(70, 160)) });
    try b.image(.{ .image = img, .src = full, .dst = .xywh(-40, -30, 80, 60), .opacity = 0.7 });
    try b.popLayer();
    try b.image(.{ .image = img, .src = full, .dst = .xywh(140, 130, 20, 20) });
    try b.image(.{ .image = rampImage(c), .src = .xywh(0, 0, 64, 8), .dst = .xywh(180, 120, 210, 80) });
}

fn blur(c: *Ctx, b: *Builder) !void {
    // A busy backdrop.
    for (0..10) |i| {
        const f: f32 = @floatFromInt(i);
        try b.fillRect(.xywh(f * 40, 0, 20, 200), .color(if (i % 2 == 0) blue else orange));
    }
    try text(c, b, c.roboto, "Backdrop", 20, 60, 40, .color(ink));
    // Frosted panel.
    try b.pushLayer(.{ .id = 1 });
    try b.backdropBlur(.{ .rounded_rect = .{ .rect = .xywh(30, 30, 200, 120), .radii = .uniform(16, 16) } }, 6);
    try b.fillRoundedRect(.xywh(30, 30, 200, 120), .uniform(16, 16), .color(Color.white.withAlpha(0.25)));
    try b.popLayer();
    // Blur inside an isolated group only sees the group's content.
    try b.pushLayer(.{ .opacity = 0.9 });
    try b.fillRect(.xywh(260, 20, 120, 160), .color(green));
    try b.fillRect(.xywh(290, 50, 20, 100), .color(ink));
    try b.backdropBlur(.{ .rect = .xywh(280, 40, 80, 120) }, 3);
    try b.popLayer();
}

fn textScene(c: *Ctx, b: *Builder) !void {
    try b.fillRect(.xywh(200, 0, 200, 260), .color(Color.srgb8(0x18, 0x18, 0x1b, 0xff)));
    const sizes = [_]f32{ 9, 10, 11, 12, 13, 14, 16, 20, 28 };
    var y: f32 = 16;
    for (sizes) |s| {
        try text(c, b, c.roboto, "Hamburgefonstiv", 8, y, s, .color(ink));
        try text(c, b, c.roboto, "Hamburgefonstiv", 208, y, s, .color(Color.srgb8(0xe4, 0xe4, 0xe7, 0xff)));
        y += s * 1.35 + 2;
    }
    // Subpixel phases: the same glyph at quarter-pixel offsets.
    for (0..8) |i| {
        const f: f32 = @floatFromInt(i);
        try text(c, b, c.roboto, "l", 10 + f * 6.25, 205, 14, .color(ink));
    }
    // Gradient-filled text, rotated text (outline path), large text.
    const s2 = stops2(blue, pink);
    try text(c, b, c.roboto, "Gradient", 70, 210, 22, .{ .gradient = .{ .geometry = .{ .linear = .{ .p0 = .{ .x = 70, .y = 0 }, .p1 = .{ .x = 160, .y = 0 } } }, .stops = &s2 } });
    try b.pushLayer(.{ .transform = Affine.rotate(-0.25).then(.translate(220, 245)) });
    try text(c, b, c.roboto, "Rotated", 0, 0, 18, .color(orange));
    try b.popLayer();
    try text(c, b, c.roboto, "Ag", 300, 250, 60, .color(green));
}

fn colr(c: *Ctx, b: *Builder) !void {
    const face = hb.hb_font_get_face(c.colr.font);
    const count = hb.hb_face_get_glyph_count(face);
    const size: f32 = 36;
    var g: u32 = 1;
    var i: u32 = 0;
    while (g < count and i < 80) : (g += 1) {
        if (hb.hb_ot_color_glyph_has_paint(face, g) == 0) continue;
        const x: f32 = 6 + @as(f32, @floatFromInt(i % 10)) * 40;
        const y: f32 = 36 + @as(f32, @floatFromInt(i / 10)) * 40;
        try b.glyphs(.{
            .font = c.colr.handle(),
            .size = size,
            .glyphs = &.{.{ .id = g, .x = x, .y = y }},
            .paint = .color(ink),
            .bounds = .{ .x0 = x - size, .y0 = y - size * 2, .x1 = x + size * 2, .y1 = y + size },
        });
        i += 1;
    }
    // A few glyphs large: linear, sweep, radial, composite, layers.
    for ([_]u32{ 6, 10, 92, 116, 175 }, 0..) |id, k| {
        const x: f32 = 8 + @as(f32, @floatFromInt(k)) * 78;
        const y: f32 = 400;
        try b.glyphs(.{
            .font = c.colr.handle(),
            .size = 72,
            .glyphs = &.{.{ .id = id, .x = x, .y = y }},
            .paint = .color(blue),
            .bounds = .{ .x0 = x - 72, .y0 = y - 144, .x1 = x + 144, .y1 = y + 72 },
        });
    }
}

/// The text engine end to end: a wrapped bidi paragraph with font
/// fallback, lowered from text.Layout into display-list glyph runs.
fn paragraph(c: *Ctx, b: *Builder) !void {
    const gpa = c.gpa;
    if (c.fonts == null) c.fonts = .init(gpa);
    const cache = &c.fonts.?;
    const tf = text_engine.font.test_fonts;
    const fonts = [_]text_engine.FontId{
        try cache.add(tf.latin, 0, .borrowed),
        try cache.add(tf.arabic, 0, .borrowed),
        try cache.add(tf.hebrew, 0, .borrowed),
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const str = "Rendering text through siv: \u{05e9}\u{05dc}\u{05d5}\u{05dd} and \u{0645}\u{0631}\u{062d}\u{0628}\u{0627} wrap across lines, shaped by HarfBuzz and drawn by the CPU renderer.";
    var para = try text_engine.ShapedParagraph.init(gpa, arena.allocator(), cache, str, &.{.{
        .end = @intCast(str.len),
        .style = .{ .fonts = &fonts, .size = 15 },
    }}, .auto_ltr);
    defer para.deinit();
    var layout = try text_engine.Layout.init(gpa, arena.allocator(), cache, &para, .{ .width = 260 });
    defer layout.deinit();

    const origin_x: f32 = 12;
    const origin_y: f32 = 10;
    try b.fillRect(.xywh(origin_x, origin_y, 260, layout.height), .color(Color.srgb8(0xee, 0xf2, 0xff, 0xff)));
    for (layout.lines) |line| {
        for (layout.lineRuns(line)) |run| {
            const face = cache.face(run.font).?;
            c.glyphs.clearRetainingCapacity();
            var bounds = Rect.empty;
            for (layout.runGlyphs(run)) |g| {
                const x = origin_x + line.x + g.x;
                const y = origin_y + line.baseline + g.y;
                try c.glyphs.append(gpa, .{ .id = g.id, .x = x, .y = y });
                if (face.glyphBounds(g.id, run.size)) |gb| bounds = bounds.unite(.xywh(x + gb.x, y + gb.y, gb.width, gb.height));
            }
            if (bounds.isEmpty()) continue;
            try b.glyphs(.{
                .font = .{ .handle = face.font, .key = face.key },
                .size = run.size,
                .glyphs = c.glyphs.items,
                .paint = .color(ink),
                .bounds = bounds.outset(1),
            });
        }
    }
}

/// Synthetic bold and oblique (D13) and variable instances, from faces of
/// the text engine's cache: on the glyph cache's path, small (with stem
/// darkening), and rotated (drawn as outlines).
fn families(c: *Ctx, b: *Builder) !void {
    const gpa = c.gpa;
    if (c.fonts == null) c.fonts = .init(gpa);
    const cache = &c.fonts.?;
    const Synthetic = text_engine.font.Synthetic;
    const roboto = try cache.add(@embedFile("../golden/fonts/Roboto-Regular.ttf"), 0, .borrowed);
    const styles = [_]Synthetic{ .{}, .{ .bold = Synthetic.bold_strength }, .{ .slant = Synthetic.oblique_slant }, .{ .bold = Synthetic.bold_strength, .slant = Synthetic.oblique_slant } };
    for (styles, 0..) |style, i| {
        const f = try faceFont(cache, try cache.instance(roboto, .{ .synthetic = style }));
        const y = 30 + @as(f32, @floatFromInt(i)) * 28;
        try text(c, b, f, "Hamburgefonstiv", 12, y, 20, .color(ink));
        try text(c, b, f, "Hamburgefonstiv 11px", 200, y, 11, .color(blue));
    }
    // Rotated: outlines as paths, synthetic styles included.
    try b.pushLayer(.{ .transform = Affine.rotate(-0.15).then(.translate(200, 150)) });
    try text(c, b, try faceFont(cache, try cache.instance(roboto, .{ .synthetic = styles[3] })), "Rotated", 0, 0, 22, .color(orange));
    try b.popLayer();
    // The variable test font's I, H, O, and n at wght 100, 400, 700, and
    // 900, then condensed, and its opsz instances at the same size.
    const vf = try cache.add(text_engine.font.test_fonts.siv_variable, 0, .borrowed);
    const instances = [_]text_engine.font.Instance{ .{ .wght = 100 }, .{}, .{ .wght = 700 }, .{ .wght = 900 }, .{ .wdth = 75 }, .{ .opsz = 8 }, .{ .opsz = 72 } };
    var x: f32 = 12;
    for (instances) |inst| {
        const f = try faceFont(cache, try cache.instance(vf, inst));
        try text(c, b, f, "HIOn", x, 190, 24, .color(ink));
        x += 54;
    }
}

fn faceFont(cache: *text_engine.FontCache, id: text_engine.FontId) !Font {
    const face = cache.face(id).?;
    return .{ .font = @ptrCast(face.font), .key = face.key, .upem = @floatFromInt(face.upem) };
}

/// Builds a minimal sbix font: glyph 1 is a 64x64 PNG (a face with a
/// translucent halo) in a 64 ppem strike with 64 units per em. No suitable
/// bitmap font is available under a license siv accepts (D25).
fn sbixFont(gpa: std.mem.Allocator) ![]u8 {
    const n = 64;
    var rgba: [n * n * 4]u8 = undefined;
    for (0..n) |y| for (0..n) |x| {
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - 32;
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - 32;
        const d = @sqrt(dx * dx + dy * dy);
        const eye = (@abs(dx) > 7 and @abs(dx) < 13 and dy > -14 and dy < -4);
        const mouth = (d > 14 and d < 19 and dy > 6);
        const p = rgba[(y * n + x) * 4 ..][0..4];
        if (d < 24) {
            p.* = if (eye or mouth) .{ 0x5a, 0x32, 0x10, 0xff } else .{ 0xff, 0xc8, 0x2c, 0xff };
        } else if (d < 31) {
            p.* = .{ 0xff, 0x60, 0x20, @intFromFloat(255 * (31 - d) / 7) };
        } else p.* = .{ 0, 0, 0, 0 };
    };
    const image = try png.encode(gpa, n, n, &rgba);
    defer gpa.free(image);

    var head: [54]u8 = @splat(0);
    std.mem.writeInt(u32, head[0..4], 0x00010000, .big);
    std.mem.writeInt(u32, head[12..16], 0x5F0F3CF5, .big);
    std.mem.writeInt(u16, head[18..20], 64, .big); // unitsPerEm
    var maxp: [6]u8 = undefined;
    std.mem.writeInt(u32, maxp[0..4], 0x00005000, .big);
    std.mem.writeInt(u16, maxp[4..6], 2, .big);

    var sbix: std.ArrayList(u8) = .empty;
    defer sbix.deinit(gpa);
    const w = struct {
        fn int(l: *std.ArrayList(u8), a: std.mem.Allocator, comptime T: type, v: T) !void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .big);
            try l.appendSlice(a, &b);
        }
    };
    try w.int(&sbix, gpa, u16, 1); // version
    try w.int(&sbix, gpa, u16, 1); // flags
    try w.int(&sbix, gpa, u32, 1); // strikes
    try w.int(&sbix, gpa, u32, 12); // strike offset
    // Strike: ppem, ppi, glyph data offsets (3 for 2 glyphs).
    const glyph1 = 4 + 3 * 4;
    try w.int(&sbix, gpa, u16, 64);
    try w.int(&sbix, gpa, u16, 72);
    try w.int(&sbix, gpa, u32, glyph1);
    try w.int(&sbix, gpa, u32, glyph1);
    try w.int(&sbix, gpa, u32, @intCast(glyph1 + 8 + image.len));
    try w.int(&sbix, gpa, i16, 0); // origin x
    try w.int(&sbix, gpa, i16, -8); // origin y: 8 units below the baseline
    try sbix.appendSlice(gpa, "png ");
    try sbix.appendSlice(gpa, image);

    const tables = [_]struct { []const u8, []const u8 }{ .{ "head", &head }, .{ "maxp", &maxp }, .{ "sbix", sbix.items } };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try w.int(&out, gpa, u32, 0x00010000);
    try w.int(&out, gpa, u16, tables.len);
    try w.int(&out, gpa, u16, 32);
    try w.int(&out, gpa, u16, 1);
    try w.int(&out, gpa, u16, 16);
    var offset: u32 = @intCast(12 + 16 * tables.len);
    for (tables) |t| {
        try out.appendSlice(gpa, t[0]);
        try w.int(&out, gpa, u32, 0);
        try w.int(&out, gpa, u32, offset);
        try w.int(&out, gpa, u32, @intCast(t[1].len));
        offset += @intCast((t[1].len + 3) & ~@as(usize, 3));
    }
    for (tables) |t| {
        try out.appendSlice(gpa, t[1]);
        while (out.items.len % 4 != 0) try out.append(gpa, 0);
    }
    return out.toOwnedSlice(gpa);
}

/// CBDT/sbix bitmap glyphs: PNG decoded by the image module, box-filtered
/// to size.
fn bitmaps(c: *Ctx, b: *Builder) !void {
    if (c.sbix == null) {
        c.sbix_bytes = try sbixFont(c.gpa);
        c.sbix = .init(c.sbix_bytes, 3);
    }
    const f = c.sbix.?;
    try b.fillRect(.xywh(0, 0, 240, 130), .color(Color.srgb8(0x18, 0x18, 0x1b, 0xff)));
    const sizes = [_]f32{ 12, 16, 24, 32, 48, 64 };
    var x: f32 = 8;
    for (sizes) |size| {
        // The second row is offset by a quarter pixel (another phase).
        for ([_]f32{ 58, 120 }, [_]f32{ 0, 0.25 }) |y, dx| {
            try b.glyphs(.{
                .font = f.handle(),
                .size = size,
                .glyphs = &.{.{ .id = 1, .x = x + dx, .y = y }},
                .paint = .color(ink),
                .bounds = .{ .x0 = x - 2, .y0 = y - size * 1.2, .x1 = x + size * 1.2, .y1 = y + size * 0.3 },
            });
        }
        x += size + 4;
    }
}

/// Analytic box shadows (D9): outset, inset, spread both ways, sharp and
/// large blurs, per-corner and elliptical radii, a translucent card that
/// shows the shadow is not under it, a clip, and a rotated, scaled layer.
fn shadows(_: *Ctx, b: *Builder) !void {
    const shade = Color.black.withAlpha(0.35);
    const Card = struct { r: Rect, radii: raster.Radii, s: scene.Shadow };
    const cards = [_]Card{
        .{ .r = .xywh(20, 20, 100, 60), .radii = .uniform(16, 16), .s = .{ .shape = undefined, .offset = .{ .x = 0, .y = 6 }, .sigma = 8, .color = shade } },
        .{ .r = .xywh(150, 20, 100, 60), .radii = .{}, .s = .{ .shape = undefined, .offset = .{ .x = 3, .y = 3 }, .sigma = 2, .color = shade } },
        .{ .r = .xywh(280, 20, 100, 60), .radii = .{ .tl = .{ .x = 30, .y = 12 }, .tr = .{ .x = 4, .y = 4 }, .br = .{ .x = 20, .y = 20 }, .bl = .{ .x = 0, .y = 0 } }, .s = .{ .shape = undefined, .spread = 6, .sigma = 4, .color = blue.withAlpha(0.5) } },
        .{ .r = .xywh(20, 120, 100, 60), .radii = .uniform(10, 10), .s = .{ .shape = undefined, .offset = .{ .x = 6, .y = 6 }, .sigma = 0, .color = shade } },
        .{ .r = .xywh(150, 120, 100, 60), .radii = .uniform(12, 12), .s = .{ .shape = undefined, .offset = .{ .x = 0, .y = 14 }, .spread = -10, .sigma = 10, .color = Color.black.withAlpha(0.6) } },
        .{ .r = .xywh(290, 120, 80, 50), .radii = .uniform(25, 25), .s = .{ .shape = undefined, .sigma = 24, .color = orange.withAlpha(0.8) } },
    };
    for (cards, 0..) |cd, i| {
        var sh = cd.s;
        sh.shape = .{ .rect = cd.r, .radii = cd.radii };
        try b.shadow(sh);
        const fill = if (i == 3) Color.white.withAlpha(0.5) else Color.white;
        try b.fillRoundedRect(cd.r, cd.radii, .color(fill));
    }
    // Inset shadows: a pressed well, and one whose spread fills the shape.
    try b.fillRoundedRect(.xywh(20, 210, 100, 60), .uniform(14, 14), .color(Color.srgb8(0xe4, 0xe4, 0xe7, 0xff)));
    try b.shadow(.{ .shape = .{ .rect = .xywh(20, 210, 100, 60), .radii = .uniform(14, 14) }, .offset = .{ .x = 0, .y = 4 }, .sigma = 5, .spread = 2, .color = Color.black.withAlpha(0.5), .inset = true });
    try b.shadow(.{ .shape = .{ .rect = .xywh(140, 215, 40, 50), .radii = .uniform(8, 8) }, .spread = 30, .sigma = 3, .color = green, .inset = true });
    // A clip cuts the shadow off.
    try b.pushLayer(.{ .clip = .{ .shape = .{ .rect = .xywh(190, 200, 70, 90) } } });
    try b.shadow(.{ .shape = .{ .rect = .xywh(200, 215, 80, 50), .radii = .uniform(6, 6) }, .offset = .{ .x = -4, .y = 4 }, .sigma = 6, .color = pink });
    try b.popLayer();
    // Rotated and scaled: the shadow turns and scales with its card.
    try b.pushLayer(.{ .transform = Affine.rotate(0.3).then(.scale(1.3, 1.3)).then(.translate(330, 240)) });
    try b.shadow(.{ .shape = .{ .rect = .xywh(-30, -18, 60, 36), .radii = .uniform(8, 8) }, .offset = .{ .x = 0, .y = 5 }, .sigma = 5, .color = shade });
    try b.fillRoundedRect(.xywh(-30, -18, 60, 36), .uniform(8, 8), .color(Color.white));
    try b.popLayer();
}

pub const Case = struct {
    name: []const u8,
    width: u32,
    height: u32,
    build: *const fn (*Ctx, *Builder) anyerror!void,
};

pub const cases = [_]Case{
    .{ .name = "shapes", .width = 400, .height = 200, .build = shapes },
    .{ .name = "gradients", .width = 400, .height = 340, .build = gradients },
    .{ .name = "layers", .width = 400, .height = 340, .build = layers },
    .{ .name = "images", .width = 400, .height = 210, .build = images },
    .{ .name = "blur", .width = 400, .height = 200, .build = blur },
    .{ .name = "text", .width = 400, .height = 260, .build = textScene },
    .{ .name = "colr", .width = 400, .height = 410, .build = colr },
    .{ .name = "paragraph", .width = 284, .height = 84, .build = paragraph },
    .{ .name = "bitmaps", .width = 240, .height = 130, .build = bitmaps },
    .{ .name = "shadows", .width = 400, .height = 300, .build = shadows },
    .{ .name = "families", .width = 400, .height = 210, .build = families },
};

test "golden images" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const update = std.testing.environ.getPosix("SIV_UPDATE_GOLDEN") != null;
    var ctx: Ctx = .{
        .gpa = gpa,
        .pb = .init(gpa),
        .roboto = .init(@embedFile("../golden/fonts/Roboto-Regular.ttf"), 1),
        .colr = .init(@embedFile("../golden/fonts/test_glyphs-glyf_colr_1.ttf"), 2),
    };
    defer ctx.deinit();
    var workers = pool.Pool.init(gpa, 3);
    defer workers.deinit();
    const r = try render_cpu.Renderer.create(gpa, workers.executor());
    defer r.destroy();
    var b = Builder.init(gpa);
    defer b.deinit();

    var failures: usize = 0;
    for (cases) |case| {
        b.reset();
        try case.build(&ctx, &b);
        const list = try b.finish(0);
        try r.resize(case.width, case.height);
        const out = try gpa.alloc(u8, @as(usize, case.width) * case.height * 4);
        defer gpa.free(out);
        try r.render(list, .{ .background = .white, .target = .{ .pixels = out.ptr, .stride = case.width * 4, .format = .abgr8888 } });

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ golden_dir, case.name });
        defer gpa.free(path);
        if (update) {
            const bytes = try png.encode(gpa, case.width, case.height, out);
            defer gpa.free(bytes);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
            continue;
        }
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch |e| {
            std.debug.print("golden {s}: cannot read {s}: {t} (run with SIV_UPDATE_GOLDEN=1)\n", .{ case.name, path, e });
            failures += 1;
            continue;
        };
        defer gpa.free(bytes);
        const want = try png.decode(gpa, bytes);
        defer want.deinit(gpa);
        if (!try compare(gpa, io, case, want, out)) failures += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

/// Allows the rounding noise different CPUs can produce: every channel
/// within 3, and at most 0.5% of pixels off by more than 1.
pub fn compare(gpa: std.mem.Allocator, io: std.Io, case: Case, want: png.Image, got: []const u8) !bool {
    if (want.width != case.width or want.height != case.height) {
        std.debug.print("golden {s}: size {d}x{d}, expected {d}x{d}\n", .{ case.name, case.width, case.height, want.width, want.height });
        return false;
    }
    var worst: u8 = 0;
    var off: usize = 0;
    const diff = try gpa.alloc(u8, got.len);
    defer gpa.free(diff);
    for (0..got.len / 4) |i| {
        var d: u8 = 0;
        for (0..4) |ch| d = @max(d, absDiff(want.pixels[i * 4 + ch], got[i * 4 + ch]));
        worst = @max(worst, d);
        if (d > 1) off += 1;
        const v: u8 = @intCast(@min(255, @as(u32, d) * 32));
        diff[i * 4 ..][0..4].* = .{ v, 0, 0, if (d > 0) 255 else 40 };
    }
    const pixels = got.len / 4;
    if (worst <= 3 and off * 200 <= pixels) return true;
    std.debug.print("golden {s}: max channel difference {d}, {d} pixels off by more than 1\n", .{ case.name, worst, off });
    try std.Io.Dir.cwd().createDirPath(io, failure_dir);
    for ([_]struct { []const u8, []const u8 }{ .{ "actual", got }, .{ "diff", diff } }) |item| {
        const bytes = try png.encode(gpa, case.width, case.height, item[1]);
        defer gpa.free(bytes);
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.png", .{ failure_dir, case.name, item[0] });
        defer gpa.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }
    return false;
}

fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

test {
    _ = png;
}
