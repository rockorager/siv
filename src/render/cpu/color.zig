//! Working-space pixels and output encoders.
//!
//! The renderer works in linear light, premultiplied, 16 bits per channel
//! (D11): a pixel is [4]u16 in R, G, B, A order. Output buffers use the
//! wl_shm formats below. Encoders apply the sRGB transfer function and
//! premultiply in encoded space, as Wayland compositors expect for the
//! default (sRGB) image description. 8- and 10-bit outputs are dithered with
//! an ordered pattern anchored to device coordinates, so gradients do not
//! band and the result does not depend on how the frame was tiled.

const std = @import("std");

pub const Pixel = [4]u16;

/// wl_shm formats the renderer can write. Values are the wl_shm format
/// codes (DRM fourcc, except the two legacy codes 0 and 1).
pub const Format = enum(u32) {
    /// 32-bit little-endian [B, G, R, A] bytes, premultiplied.
    argb8888 = 0,
    /// As argb8888 with the alpha byte ignored (written as 0xff).
    xrgb8888 = 1,
    /// [R, G, B, A] bytes.
    abgr8888 = 0x34324241,
    xbgr8888 = 0x34324258,
    /// 32-bit little-endian, 2:10:10:10 A:R:G:B.
    argb2101010 = 0x30335241,
    xrgb2101010 = 0x30335258,
    /// 64-bit little-endian [R, G, B, A] u16 values.
    abgr16161616 = 0x38344241,
    xbgr16161616 = 0x38344258,

    pub fn bytesPerPixel(f: Format) u32 {
        return switch (f) {
            .abgr16161616, .xbgr16161616 => 8,
            else => 4,
        };
    }

    pub fn hasAlpha(f: Format) bool {
        return switch (f) {
            .argb8888, .abgr8888, .argb2101010, .abgr16161616 => true,
            else => false,
        };
    }
};

/// Lookup tables for transfer functions. About 260 KiB; build once per
/// renderer.
pub const Luts = struct {
    /// sRGB-encoded byte to linear u16.
    srgb8_to_linear: [256]u16,
    /// Linear u16 to sRGB-encoded u16.
    linear_to_srgb16: [65536]u16,
    /// Linear u16 to sRGB-encoded 8-bit values in 8.8 fixed point, for
    /// dithering opaque pixels with one lookup per channel.
    linear_to_srgb8_8: [65536]u16,

    pub fn init(l: *Luts) void {
        for (&l.srgb8_to_linear, 0..) |*v, i| {
            v.* = toU16(srgbToLinear(@as(f32, @floatFromInt(i)) / 255));
        }
        for (&l.linear_to_srgb16, &l.linear_to_srgb8_8, 0..) |*v, *v8, i| {
            const e = linearToSrgb(@as(f32, @floatFromInt(i)) / 65535);
            v.* = toU16(e);
            v8.* = @intFromFloat(std.math.clamp(e, 0, 1) * 255 * 256 + 0.5);
        }
    }
};

pub fn srgbToLinear(v: f32) f32 {
    if (v <= 0.04045) return v / 12.92;
    return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgb(v: f32) f32 {
    if (v <= 0.0031308) return v * 12.92;
    return 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

pub inline fn toU16(v: f32) u16 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 65535 + 0.5);
}

/// x / 65535 rounded, exact for x <= 65535 * 65535.
pub inline fn div65535(x: u32) u32 {
    const t = x + 32768;
    return (t + (t >> 16)) >> 16;
}

pub inline fn div65535v(x: @Vector(4, u32)) @Vector(4, u32) {
    const t = x + @as(@Vector(4, u32), @splat(32768));
    return (t + (t >> @splat(16))) >> @splat(16);
}

/// Narrows a vector of 16-bit values to a pixel.
pub inline fn narrow(v: @Vector(4, u32)) Pixel {
    const r: @Vector(4, u16) = @intCast(v);
    return r;
}

/// Premultiplied linear u16 pixel from a straight-alpha linear color.
pub fn premultiply(r: f32, g: f32, b: f32, a: f32) Pixel {
    const al = std.math.clamp(a, 0, 1);
    return .{ toU16(r * al), toU16(g * al), toU16(b * al), toU16(al) };
}

/// 8x8 Bayer matrix, values 0..63.
const bayer8 = [8][8]u8{
    .{ 0, 32, 8, 40, 2, 34, 10, 42 },
    .{ 48, 16, 56, 24, 50, 18, 58, 26 },
    .{ 12, 44, 4, 36, 14, 46, 6, 38 },
    .{ 60, 28, 52, 20, 62, 30, 54, 22 },
    .{ 3, 35, 11, 43, 1, 33, 9, 41 },
    .{ 51, 19, 59, 27, 49, 17, 57, 25 },
    .{ 15, 47, 7, 39, 13, 45, 5, 37 },
    .{ 63, 31, 55, 23, 61, 29, 53, 21 },
};

/// Encodes one row of working pixels, starting at device pixel (x, y), into
/// `out` (which holds exactly src.len pixels of `format`).
pub fn encodeRow(luts: *const Luts, format: Format, src: []const Pixel, x: i32, y: i32, out: []u8) void {
    switch (format) {
        inline else => |f| encodeRowT(f, luts, src, x, y, out),
    }
}

fn encodeRowT(comptime f: Format, luts: *const Luts, src: []const Pixel, x: i32, y: i32, out: []u8) void {
    const bpp = comptime f.bytesPerPixel();
    const has_alpha = comptime f.hasAlpha();
    const dither_row = &bayer8[@as(usize, @intCast(@mod(y, 8)))];
    for (src, 0..) |p, i| {
        const px = out[i * bpp ..][0..bpp];
        if (comptime bpp == 4 and f != .argb2101010 and f != .xrgb2101010) {
            if (p[3] == 65535 or !has_alpha) {
                // Opaque: one lookup, the dither offset, and a shift.
                const d: u32 = dither_row[@as(usize, @intCast(@mod(x + @as(i32, @intCast(i)), 8)))];
                const bias = (2 * d + 1) * 2;
                const r: u8 = @intCast(@min((@as(u32, luts.linear_to_srgb8_8[p[0]]) + bias) >> 8, 255));
                const g: u8 = @intCast(@min((@as(u32, luts.linear_to_srgb8_8[p[1]]) + bias) >> 8, 255));
                const b: u8 = @intCast(@min((@as(u32, luts.linear_to_srgb8_8[p[2]]) + bias) >> 8, 255));
                px.* = if (f == .argb8888 or f == .xrgb8888) .{ b, g, r, 0xff } else .{ r, g, b, 0xff };
                continue;
            }
        }
        const e = encodePixel(luts, p, has_alpha);
        switch (f) {
            .argb8888, .xrgb8888, .abgr8888, .xbgr8888 => {
                const d: u32 = dither_row[@as(usize, @intCast(@mod(x + @as(i32, @intCast(i)), 8)))];
                const q = quantize(e, 255, d);
                if (f == .argb8888 or f == .xrgb8888) {
                    px.* = .{ @intCast(q[2]), @intCast(q[1]), @intCast(q[0]), if (has_alpha) @intCast(q[3]) else 0xff };
                } else {
                    px.* = .{ @intCast(q[0]), @intCast(q[1]), @intCast(q[2]), if (has_alpha) @intCast(q[3]) else 0xff };
                }
            },
            .argb2101010, .xrgb2101010 => {
                const d: u32 = dither_row[@as(usize, @intCast(@mod(x + @as(i32, @intCast(i)), 8)))];
                const q = quantize(e, 1023, d);
                const a2: u32 = if (has_alpha) (e[3] * 3 + 32767) / 65535 else 3;
                const v: u32 = (a2 << 30) | (q[0] << 20) | (q[1] << 10) | q[2];
                std.mem.writeInt(u32, px, v, .little);
            },
            .abgr16161616, .xbgr16161616 => {
                std.mem.writeInt(u16, px[0..2], @intCast(e[0]), .little);
                std.mem.writeInt(u16, px[2..4], @intCast(e[1]), .little);
                std.mem.writeInt(u16, px[4..6], @intCast(e[2]), .little);
                std.mem.writeInt(u16, px[6..8], if (has_alpha) @intCast(e[3]) else 0xffff, .little);
            },
        }
    }
}

/// Encoded (sRGB, premultiplied in encoded space) 16-bit components.
inline fn encodePixel(luts: *const Luts, p: Pixel, has_alpha: bool) [4]u32 {
    const a: u32 = p[3];
    if (a == 65535 or !has_alpha) {
        // Opaque, or alpha is dropped: the color is used as is. For
        // non-opaque pixels in an alpha-less format this composites over
        // black, which is what premultiplied color means.
        return .{ luts.linear_to_srgb16[p[0]], luts.linear_to_srgb16[p[1]], luts.linear_to_srgb16[p[2]], 65535 };
    }
    if (a == 0) return .{ 0, 0, 0, 0 };
    var out: [4]u32 = undefined;
    inline for (0..3) |c| {
        // Unpremultiply, encode, premultiply.
        const straight = @min((@as(u32, p[c]) * 65535 + a / 2) / a, 65535);
        out[c] = div65535(@as(u32, luts.linear_to_srgb16[straight]) * a);
    }
    out[3] = a;
    return out;
}

/// Quantizes 16-bit encoded components to `max` levels with an ordered
/// dither threshold d in 0..63. Alpha is rounded, not dithered, and color
/// never exceeds alpha (premultiplied validity).
inline fn quantize(e: [4]u32, comptime max: u32, d: u32) [4]u32 {
    const bias: u32 = (2 * d + 1) * 65535 / 128; // (d + 0.5) / 64 of one step
    const a = (e[3] * max + 32767) / 65535;
    var q: [4]u32 = undefined;
    inline for (0..3) |c| q[c] = @min((e[c] * max + bias) / 65535, a);
    q[3] = a;
    return q;
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

test "div65535 rounds exactly" {
    var x: u32 = 0;
    while (x < 65535 * 65535) : (x += 7919 * 13) {
        const expect: u32 = @intCast((@as(u64, x) + 32767) / 65535);
        const got = div65535(x);
        // Ties may round either way.
        try testing.expect(got == expect or (@as(u64, x) * 2) % 65535 == 0);
    }
    try testing.expectEqual(@as(u32, 65535), div65535(65535 * 65535));
}

test "encode opaque and transparent pixels" {
    const luts = try testing.allocator.create(Luts);
    defer testing.allocator.destroy(luts);
    luts.init();
    // Linear 0.5 is sRGB 0.7354 = 187.5/255; dithering picks 187 or 188.
    const mid = toU16(0.5);
    var out: [8]u8 = undefined;
    encodeRow(luts, .argb8888, &.{ .{ mid, 0, 65535, 65535 }, .{ 0, 0, 0, 0 } }, 0, 0, &out);
    try testing.expect(out[2] == 187 or out[2] == 188);
    try testing.expectEqual(@as(u8, 0), out[1]);
    try testing.expectEqual(@as(u8, 255), out[0]);
    try testing.expectEqual(@as(u8, 255), out[3]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out[4..8]);

    // Dithering averages to the exact value over the 8x8 pattern.
    var total: u32 = 0;
    for (0..8) |yy| {
        var row: [8 * 4]u8 = undefined;
        const src: [8]Pixel = @splat(.{ mid, mid, mid, 65535 });
        encodeRow(luts, .xrgb8888, &src, 0, @intCast(yy), &row);
        for (0..8) |i| total += row[i * 4];
    }
    const avg = @as(f32, @floatFromInt(total)) / 64;
    try testing.expectApproxEqAbs(linearToSrgb(0.5) * 255, avg, 0.05);
}

test "translucent pixels premultiply in encoded space" {
    const luts = try testing.allocator.create(Luts);
    defer testing.allocator.destroy(luts);
    luts.init();
    // 50% white: linear premultiplied (0.5, 0.5, 0.5, 0.5) encodes to
    // sRGB(1) * 0.5 = 0.5 (not sRGB(0.5) = 0.735).
    const half = toU16(0.5);
    var out: [8]u8 = undefined;
    encodeRow(luts, .abgr16161616, &.{.{ half, half, half, half }}, 0, 0, &out);
    try testing.expectEqual(half, std.mem.readInt(u16, out[0..2], .little));
    try testing.expectEqual(half, std.mem.readInt(u16, out[6..8], .little));
}
