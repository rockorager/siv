//! Minimal PNG codec for golden images: 8-bit RGBA, non-interlaced.
//! Encoding uses the Paeth-free "up" filter per row and zlib from std.

const std = @import("std");
const flate = std.compress.flate;

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA bytes, 4 per pixel, rows packed.
    pixels: []u8,

    pub fn deinit(img: Image, gpa: std.mem.Allocator) void {
        gpa.free(img.pixels);
    }
};

const signature = "\x89PNG\r\n\x1a\n";

pub fn encode(gpa: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) ![]u8 {
    // Filtered scanlines: filter byte 2 (up) then the row difference.
    const stride = @as(usize, width) * 4;
    const raw = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(raw);
    for (0..height) |y| {
        const row = rgba[y * stride ..][0..stride];
        const out = raw[y * (stride + 1) ..][0 .. stride + 1];
        out[0] = 2;
        for (row, 0..) |v, i| out[1 + i] = v -% (if (y > 0) rgba[(y - 1) * stride + i] else 0);
    }

    var z: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 16);
    defer z.deinit();
    {
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var c = try flate.Compress.init(&z.writer, window, .zlib, .default);
        try c.writer.writeAll(raw);
        try c.finish();
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8-bit RGBA
    try chunk(w, "IHDR", &ihdr);
    try chunk(w, "IDAT", z.written());
    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.BadPng;
    var pos: usize = signature.len;
    var width: u32 = 0;
    var height: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (pos + 12 + len > bytes.len) return error.BadPng;
        const data = bytes[pos + 8 ..][0..len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8 or data[9] != 6 or data[12] != 0) return error.UnsupportedPng;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    var in: std.Io.Reader = .fixed(idat.items);
    var d = flate.Decompress.init(&in, .zlib, &.{});
    const raw = try d.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(raw);
    const stride = @as(usize, width) * 4;
    if (raw.len != (stride + 1) * height) return error.BadPng;
    const pixels = try gpa.alloc(u8, stride * height);
    errdefer gpa.free(pixels);
    for (0..height) |y| {
        const f = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const dst = pixels[y * stride ..][0..stride];
        const up: ?[]const u8 = if (y > 0) pixels[(y - 1) * stride ..][0..stride] else null;
        for (dst, src, 0..) |*o, v, i| {
            const a: u8 = if (i >= 4) dst[i - 4] else 0;
            const b: u8 = if (up) |u| u[i] else 0;
            const c: u8 = if (up != null and i >= 4) up.?[i - 4] else 0;
            o.* = switch (f) {
                0 => v,
                1 => v +% a,
                2 => v +% b,
                3 => v +% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => v +% paeth(a, b, c),
                else => return error.BadPng,
            };
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "png round trip" {
    const gpa = std.testing.allocator;
    var px: [5 * 3 * 4]u8 = undefined;
    for (&px, 0..) |*v, i| v.* = @truncate(i * 37);
    const bytes = try encode(gpa, 5, 3, &px);
    defer gpa.free(bytes);
    const img = try decode(gpa, bytes);
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &px, img.pixels);
}
