//! Decoding tests over small files made with ImageMagick and ffmpeg (see
//! testdata/), and the fuzz target over every decoder.

const std = @import("std");
const image = @import("image.zig");

const testing = std.testing;
const gpa = testing.allocator;

fn px8(img: *const image.Image, frame: usize, x: u32, y: u32) [4]u8 {
    return img.frames[frame].pixels[(y * img.width + x) * 4 ..][0..4].*;
}

fn px16(img: *const image.Image, frame: usize, x: u32, y: u32) [4]u16 {
    const p = img.frames[frame].pixels[(y * img.width + x) * 8 ..][0..8];
    var out: [4]u16 = undefined;
    for (&out, 0..) |*o, i| o.* = std.mem.readInt(u16, p[i * 2 ..][0..2], .little);
    return out;
}

fn near(want: anytype, got: @TypeOf(want), tolerance: u32) !void {
    for (want, got) |w, g| {
        const d = if (w > g) w - g else g - w;
        if (d > tolerance) {
            std.debug.print("want {any}, got {any}\n", .{ want, got });
            return error.TestUnexpectedResult;
        }
    }
}

test "PNG with alpha stays 8-bit sRGB at its own size" {
    const img = try image.decode(gpa, @embedFile("testdata/rgba.png"), .{});
    defer img.deinit(gpa);
    try testing.expectEqual(@as(u32, 64), img.width);
    try testing.expectEqual(@as(u32, 48), img.height);
    try testing.expectEqual(.rgba8_srgb, img.format);
    try testing.expectEqual(@as(usize, 1), img.frames.len);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px8(&img, 0, 3, 3));
    try near([4]u8{ 0, 0, 255, 128 }, px8(&img, 0, 40, 3), 1);
}

test "JPEG" {
    const img = try image.decode(gpa, @embedFile("testdata/photo.jpg"), .{});
    defer img.deinit(gpa);
    try testing.expectEqual(.rgba8_srgb, img.format);
    try near([4]u8{ 255, 0, 0, 255 }, px8(&img, 0, 8, 24), 6);
    try near([4]u8{ 0, 0, 255, 255 }, px8(&img, 0, 56, 24), 6);
}

test "animated GIF and APNG: frames, delays, loops" {
    const gif = try image.decode(gpa, @embedFile("testdata/anim.gif"), .{});
    defer gif.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), gif.frames.len);
    try testing.expectEqual(@as(u32, 0), gif.loops);
    try testing.expectEqual([3]u32{ 100, 200, 300 }, .{ gif.frames[0].delay_ms, gif.frames[1].delay_ms, gif.frames[2].delay_ms });
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px8(&gif, 0, 5, 5));
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px8(&gif, 1, 5, 5));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px8(&gif, 2, 5, 5));

    const apng = try image.decode(gpa, @embedFile("testdata/anim.png"), .{});
    defer apng.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), apng.frames.len);
    try testing.expectEqual(@as(u32, 2), apng.loops);
    // ImageMagick writes one delay for every APNG frame.
    try testing.expectEqual(@as(u32, 100), apng.frames[1].delay_ms);
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px8(&apng, 1, 0, 0));

    // Only the first frame when asked, or when they do not all fit.
    const first = try image.decode(gpa, @embedFile("testdata/anim.gif"), .{ .first_frame = true });
    defer first.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), first.frames.len);
    const small = try image.decode(gpa, @embedFile("testdata/anim.gif"), .{ .max_bytes = 16 * 16 * 4 * 2 });
    defer small.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), small.frames.len);
}

test "an embedded ICC profile converts to linear light" {
    // Gray 128 in a linear profile is linear 0.502; read as sRGB it would
    // be 0.216.
    const img = try image.decode(gpa, @embedFile("testdata/linear-icc.png"), .{});
    defer img.deinit(gpa);
    try testing.expectEqual(.rgba16_linear_premul, img.format);
    try near([4]u16{ 32896, 32896, 32896, 65535 }, px16(&img, 0, 10, 10), 200);
}

test "scaling to the displayed size averages in linear light" {
    // 400 × 200, white left and black right, shown within 4 × 4.
    const img = try image.decode(gpa, @embedFile("testdata/big.png"), .{ .max_width = 4, .max_height = 4 });
    defer img.deinit(gpa);
    try testing.expectEqual(@as(u32, 4), img.width);
    try testing.expectEqual(@as(u32, 2), img.height);
    try testing.expectEqual(@as(u32, 400), img.source_width);
    try testing.expectEqual(.rgba16_linear_premul, img.format);
    try near([4]u16{ 65535, 65535, 65535, 65535 }, px16(&img, 0, 0, 1), 1);
    try near([4]u16{ 0, 0, 0, 65535 }, px16(&img, 0, 3, 0), 1);
    // 3 × 1: the middle pixel is half white in linear light, not sRGB.
    const odd = try image.decode(gpa, @embedFile("testdata/big.png"), .{ .max_width = 3 });
    defer odd.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), odd.width);
    try near([4]u16{ 32768, 32768, 32768, 65535 }, px16(&odd, 0, 1, 0), 2);
    // Half the transparent blue of rgba.png stays straight-alpha blue.
    const half = try image.decode(gpa, @embedFile("testdata/rgba.png"), .{ .max_width = 32 });
    defer half.deinit(gpa);
    try near([4]u16{ 0, 0, 32896, 32896 }, px16(&half, 0, 20, 2), 200);
}

test "limits: too many pixels, damaged files" {
    try testing.expectError(error.TooLarge, image.decode(gpa, @embedFile("testdata/big.png"), .{ .max_pixels = 1000 }));
    const png = @embedFile("testdata/rgba.png");
    try testing.expectError(error.InvalidImage, image.decode(gpa, png[0..40], .{}));
}

test "fuzz: every decoder" {
    try testing.fuzz({}, fuzzDecode, .{ .corpus = &.{
        @embedFile("testdata/rgba.png"),
        @embedFile("testdata/photo.jpg"),
        @embedFile("testdata/anim.gif"),
        @embedFile("testdata/anim.png"),
        @embedFile("testdata/linear-icc.png"),
        @embedFile("testdata/still.webp"),
        @embedFile("testdata/anim.webp"),
        @embedFile("testdata/still.avif"),
        @embedFile("testdata/deep.avif"),
        @embedFile("testdata/lossy.jxl"),
        @embedFile("testdata/lossless.jxl"),
    } });
}

fn fuzzDecode(_: void, smith: *testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    const img = image.decode(gpa, bytes, .{ .max_pixels = 1 << 20, .max_width = 64, .max_height = 64 }) catch return;
    defer img.deinit(gpa);
    try testing.expect(img.width >= 1 and img.width <= 64 and img.height >= 1 and img.height <= 64);
    for (img.frames) |f| try testing.expectEqual(@as(usize, img.width) * img.height * img.format.bytesPerPixel(), f.pixels.len);
}

test "WebP, still and animated" {
    const still = try image.decode(gpa, @embedFile("testdata/still.webp"), .{});
    defer still.deinit(gpa);
    try testing.expectEqual(@as(u32, 64), still.width);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px8(&still, 0, 3, 3));
    try near([4]u8{ 0, 0, 255, 128 }, px8(&still, 0, 40, 3), 1);

    const anim = try image.decode(gpa, @embedFile("testdata/anim.webp"), .{});
    defer anim.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), anim.frames.len);
    try testing.expectEqual(@as(u32, 3), anim.loops);
    try testing.expectEqual([3]u32{ 100, 200, 300 }, .{ anim.frames[0].delay_ms, anim.frames[1].delay_ms, anim.frames[2].delay_ms });
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px8(&anim, 1, 8, 8));
}

test "AVIF: 8-bit, 10-bit, and an image sequence" {
    const still = try image.decode(gpa, @embedFile("testdata/still.avif"), .{});
    defer still.deinit(gpa);
    try testing.expectEqual(@as(u32, 64), still.width);
    try testing.expectEqual(.rgba8_srgb, still.format);
    try near([4]u8{ 255, 0, 0, 255 }, px8(&still, 0, 4, 24), 8);
    try near([4]u8{ 0, 0, 255, 128 }, px8(&still, 0, 56, 24), 8);

    // 10 bits per channel: linear 16-bit, red stays red.
    const deep = try image.decode(gpa, @embedFile("testdata/deep.avif"), .{});
    defer deep.deinit(gpa);
    try testing.expectEqual(.rgba16_linear_premul, deep.format);
    try near([4]u16{ 65535, 0, 0, 65535 }, px16(&deep, 0, 8, 8), 1200);

    const anim = try image.decode(gpa, @embedFile("testdata/anim.avif"), .{});
    defer anim.deinit(gpa);
    try testing.expectEqual(@as(usize, 6), anim.frames.len);
    try testing.expectEqual(@as(u32, 100), anim.frames[0].delay_ms);
    try near([4]u8{ 255, 0, 0, 255 }, px8(&anim, 0, 8, 8), 10);
    try near([4]u8{ 0, 255, 0, 255 }, px8(&anim, 2, 8, 8), 10);
    try near([4]u8{ 0, 0, 255, 255 }, px8(&anim, 5, 8, 8), 10);
}

test "JPEG XL: lossy (XYB, rendered to linear light) and lossless" {
    const lossy = try image.decode(gpa, @embedFile("testdata/lossy.jxl"), .{});
    defer lossy.deinit(gpa);
    try testing.expectEqual(@as(u32, 64), lossy.width);
    try testing.expectEqual(.rgba16_linear_premul, lossy.format);
    try near([4]u16{ 65535, 0, 0, 65535 }, px16(&lossy, 0, 4, 24), 2500);
    // Half-transparent blue, premultiplied.
    try near([4]u16{ 0, 0, 32896, 32896 }, px16(&lossy, 0, 56, 24), 2500);

    const lossless = try image.decode(gpa, @embedFile("testdata/lossless.jxl"), .{});
    defer lossless.deinit(gpa);
    try testing.expectEqual(.rgba8_srgb, lossless.format);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px8(&lossless, 0, 4, 24));
    try testing.expectEqual([4]u8{ 0, 0, 255, 128 }, px8(&lossless, 0, 56, 24));
}
