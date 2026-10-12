//! Images in PDF (D9): image XObjects in sRGB-encoded DeviceRGB with an
//! 8-bit soft mask for alpha, and box shadows as images of their alpha
//! (the PDF option D9 names), evaluated with the renderers' shadow
//! contract (render/cpu/shadow.zig) so the page matches the screen.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scene = @import("scene");
const raster = @import("raster");
const render_cpu = @import("render_cpu");
const content = @import("content.zig");

const Affine = raster.Affine;
const num = content.num;

/// Shadow images per unit (point) of the shadow's bounds.
const shadow_resolution: f32 = 2;
const max_shadow_pixels: f32 = 2048;

/// Draws a display list image.
pub fn draw(c: *content.Content, im: scene.Image) content.Error!void {
    const ref = im.image;
    // Only GPU memory (a dma-buf): nothing to read back.
    const pixels = ref.pixels orelse return;
    if (im.opacity <= 0 or im.src.isEmpty() or im.dst.isEmpty()) return;
    const obj = try xobject(c, ref, pixels, im.filter);
    // The whole image placed so that `src` lands on `dst`, clipped to it.
    const sx = im.dst.width() / im.src.width();
    const sy = im.dst.height() / im.src.height();
    const w = @as(f32, @floatFromInt(ref.width)) * sx;
    const h = @as(f32, @floatFromInt(ref.height)) * sy;
    const x = im.dst.x0 - im.src.x0 * sx;
    const y = im.dst.y0 - im.src.y0 * sy;
    try c.print("q\n{f} {f} {f} {f} re W n\n", .{ num(im.dst.x0), num(im.dst.y0), num(im.dst.width()), num(im.dst.height()) });
    if (im.opacity < 1) {
        var gs: [32]u8 = undefined;
        try c.useState(std.fmt.bufPrint(&gs, "/ca {f}", .{num(im.opacity)}) catch unreachable);
    }
    // Image space has its first row at the top of the unit square; the
    // page is y-down, so the square is flipped back.
    try c.matrix(.{ .a = w, .b = 0, .c = 0, .d = -h, .e = x, .f = y + h });
    try c.useXObject(obj);
    try c.print("Q\n", .{});
}

/// An image XObject (with a soft mask if any pixel is translucent).
fn xobject(c: *content.Content, ref: scene.ImageRef, pixels: [*]const u8, filter: scene.Filter) content.Error!u32 {
    const gpa = c.w.gpa;
    const n = @as(usize, ref.width) * ref.height;
    const rgb = try gpa.alloc(u8, n * 3);
    defer gpa.free(rgb);
    const alpha = try gpa.alloc(u8, n);
    defer gpa.free(alpha);
    var translucent = false;
    for (0..ref.height) |y| {
        const row = pixels + y * ref.stride;
        for (0..ref.width) |x| {
            const i = y * ref.width + x;
            var px: [4]u8 = undefined;
            switch (ref.format) {
                .rgba8_srgb => px = row[x * 4 ..][0..4].*,
                .bgra8_srgb => px = .{ row[x * 4 + 2], row[x * 4 + 1], row[x * 4], row[x * 4 + 3] },
                .bgrx8_srgb => px = .{ row[x * 4 + 2], row[x * 4 + 1], row[x * 4], 255 },
                .rgba16_linear_premul => {
                    const p = row + x * 8;
                    var v: [4]f32 = undefined;
                    for (&v, 0..) |*o, k| o.* = @as(f32, @floatFromInt(std.mem.readInt(u16, p[k * 2 ..][0..2], .little))) / 65535;
                    const a = v[3];
                    for (0..3) |k| px[k] = if (a > 0) @intFromFloat(@round(scene.linearToSrgb(std.math.clamp(v[k] / a, 0, 1)) * 255)) else 0;
                    px[3] = @intFromFloat(@round(a * 255));
                },
            }
            rgb[i * 3 ..][0..3].* = px[0..3].*;
            alpha[i] = px[3];
            if (px[3] != 255) translucent = true;
        }
    }
    var dict: std.ArrayList(u8) = .empty;
    defer dict.deinit(gpa);
    try dict.print(gpa, "/Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Interpolate {s}", .{ ref.width, ref.height, if (filter == .linear) "true" else "false" });
    if (translucent) {
        const mask = try maskObject(c, ref.width, ref.height, alpha, filter == .linear);
        try dict.print(gpa, " /SMask {d} 0 R", .{mask});
    }
    return c.w.addStream(dict.items, rgb);
}

fn maskObject(c: *content.Content, width: u32, height: u32, alpha: []const u8, interpolate: bool) content.Error!u32 {
    var dict: [192]u8 = undefined;
    return c.w.addStream(std.fmt.bufPrint(&dict, "/Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceGray /BitsPerComponent 8 /Interpolate {s}", .{ width, height, if (interpolate) "true" else "false" }) catch unreachable, alpha);
}

/// Draws a box shadow: a one-pixel image of its color with a soft mask
/// of its alpha over its bounds. A soft mask may have another size than
/// its image; both cover the unit square.
pub fn shadow(c: *content.Content, s: scene.Shadow) content.Error!void {
    const bounds = s.bounds();
    if (bounds.isEmpty() or s.color.a <= 0) return;
    const gpa = c.w.gpa;
    var res = shadow_resolution;
    res = @min(res, max_shadow_pixels / @max(bounds.width(), 1), max_shadow_pixels / @max(bounds.height(), 1));
    const wf = @ceil(bounds.width() * res);
    const hf = @ceil(bounds.height() * res);
    const w: u32 = @intFromFloat(@max(wf, 1));
    const h: u32 = @intFromFloat(@max(hf, 1));
    // Layer coordinates to mask pixels.
    const m: Affine = .{ .a = res, .b = 0, .c = 0, .d = res, .e = -bounds.x0 * res, .f = -bounds.y0 * res };
    var prepared = render_cpu.shadow.prepare(s, m) orelse return;
    // The blur alone, B in render/cpu/shadow.zig: the casting shape's
    // coverage becomes a clip below, sharp at any zoom. A casting
    // rectangle far away (outset) or around everything (inset) makes the
    // coverage term 0 or 1.
    prepared.cast = if (s.inset) .{ .x0 = -1e9, .y0 = -1e9, .x1 = 1e9, .y1 = 1e9 } else .{ .x0 = -1e9, .y0 = -1e9, .x1 = -1e9 + 1, .y1 = -1e9 + 1 };
    prepared.cast_radii = .{};
    const alpha = try gpa.alloc(u8, @as(usize, w) * h);
    defer gpa.free(alpha);
    const a = std.math.clamp(s.color.a, 0, 1);
    for (0..h) |y| for (0..w) |x| {
        const v = render_cpu.shadow.alpha(&prepared, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
        alpha[y * w + x] = @intFromFloat(@round(std.math.clamp(v * a, 0, 1) * 255));
    };
    const mask = try maskObject(c, w, h, alpha, true);
    const rgb = [3]u8{
        @intFromFloat(@round(scene.linearToSrgb(std.math.clamp(s.color.r, 0, 1)) * 255)),
        @intFromFloat(@round(scene.linearToSrgb(std.math.clamp(s.color.g, 0, 1)) * 255)),
        @intFromFloat(@round(scene.linearToSrgb(std.math.clamp(s.color.b, 0, 1)) * 255)),
    };
    var dict: [192]u8 = undefined;
    const img = try c.w.addStream(std.fmt.bufPrint(&dict, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask {d} 0 R", .{mask}) catch unreachable, &rgb);
    const bw = @as(f32, @floatFromInt(w)) / res;
    const bh = @as(f32, @floatFromInt(h)) / res;
    try c.print("q\n", .{});
    // The shape's edge exactly, as the renderers draw it, rather than at
    // the mask's resolution: an outset shadow only outside its shape, an
    // inset one only inside.
    if (s.inset) {
        try c.path(.{ .rounded_rect = s.shape });
        try c.print("W n\n", .{});
    } else {
        try c.path(.{ .rect = bounds });
        try c.path(.{ .rounded_rect = s.shape });
        try c.print("W* n\n", .{});
    }
    try c.matrix(.{ .a = bw, .b = 0, .c = 0, .d = -bh, .e = bounds.x0, .f = bounds.y0 + bh });
    try c.useXObject(img);
    try c.print("Q\n", .{});
}
