//! Image decoding (D19): PNG, APNG, JPEG, and GIF through wuffs, WebP
//! through libwebp, AVIF through libavif and dav1d, and JPEG XL through
//! libjxl, into pixels the renderers draw (D9).
//!
//! `decode` takes a whole file in memory and runs on the calling thread;
//! the UI runs it on the worker pool (`ui.Image.load`). Images are scaled
//! down to the size they are displayed at while they are decoded, frame by
//! frame, so only that size is kept. Color is converted to the working
//! space (D11): embedded ICC profiles through Little CMS, CICP encodings
//! (AVIF, JPEG XL) by their transfer function and primaries. 8-bit sRGB
//! images that are not scaled stay 8-bit sRGB (`rgba8_srgb`); everything
//! else becomes linear, premultiplied 16-bit (`rgba16_linear_premul`),
//! clipped to sRGB primaries.
//!
//! Every input is untrusted: decoders check sizes against `Options`, and
//! `zig build test-image --fuzz` fuzzes the whole path.
//!
//! Imports: scene; the C decoders behind src/image/*.h.

const std = @import("std");
const scene = @import("scene");
const c = @import("image_c");

const Allocator = std.mem.Allocator;

pub const Format = enum { png, jpeg, gif, webp, avif, jxl };

/// The format of a file, from its first bytes.
pub fn sniff(bytes: []const u8) ?Format {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return .gif;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp")) {
        const brand = bytes[8..12];
        if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) return .avif;
        // Compatible brands, for files whose major brand is generic.
        const size = std.mem.readInt(u32, bytes[0..4], .big);
        var i: usize = 16;
        while (i + 4 <= @min(size, bytes.len)) : (i += 4) {
            const b = bytes[i..][0..4];
            if (std.mem.eql(u8, b, "avif") or std.mem.eql(u8, b, "avis")) return .avif;
        }
    }
    if (std.mem.startsWith(u8, bytes, "\xff\x0a")) return .jxl;
    if (std.mem.startsWith(u8, bytes, "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a")) return .jxl;
    return null;
}

pub const Options = struct {
    /// The largest size to show the image at, in pixels; 0 is unbounded.
    /// Images larger than that are scaled down to fit, keeping their
    /// aspect ratio; smaller ones keep their size.
    max_width: u32 = 0,
    max_height: u32 = 0,
    /// Most pixels per frame before scaling (64 Mpx: 8192 × 8192).
    max_pixels: u64 = 64 << 20,
    /// Most bytes of all decoded frames together; an animation that needs
    /// more keeps only its first frame.
    max_bytes: usize = 256 << 20,
    /// Decode only the first frame of an animation.
    first_frame: bool = false,
    /// Always produce `rgba16_linear_premul`, also for 8-bit sRGB images
    /// at their own size.
    linear: bool = false,
};

pub const Error = error{
    OutOfMemory,
    /// Not a format siv decodes.
    Unsupported,
    /// The file is damaged or not what it claims.
    InvalidImage,
    /// More pixels than `Options.max_pixels`.
    TooLarge,
};

pub const Frame = struct {
    pixels: []align(16) u8,
    /// How long to show it, in milliseconds.
    delay_ms: u32 = 0,
};

pub const Image = struct {
    width: u32,
    height: u32,
    /// The size in the file.
    source_width: u32,
    source_height: u32,
    format: scene.ImageFormat,
    /// Rows are packed: `width` times the format's bytes per pixel.
    frames: []Frame,
    /// How many times an animation plays; 0 loops forever.
    loops: u32 = 0,

    pub fn stride(img: *const Image) u32 {
        return img.width * img.format.bytesPerPixel();
    }

    pub fn deinit(img: Image, gpa: Allocator) void {
        for (img.frames) |f| gpa.free(f.pixels);
        gpa.free(img.frames);
    }
};

/// The size an image of `w` × `h` is shown at within `max_w` × `max_h`
/// (0 unbounded): scaled down to fit, never up, at least 1 × 1.
pub fn fitSize(w: u32, h: u32, max_w: u32, max_h: u32) [2]u32 {
    var k: f64 = 1;
    if (max_w != 0 and w > max_w) k = @min(k, @as(f64, @floatFromInt(max_w)) / @as(f64, @floatFromInt(w)));
    if (max_h != 0 and h > max_h) k = @min(k, @as(f64, @floatFromInt(max_h)) / @as(f64, @floatFromInt(h)));
    if (k == 1) return .{ w, h };
    return .{
        @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * k)))),
        @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * k)))),
    };
}

// Sources ---------------------------------------------------------------------

/// How a decoder's pixels encode color.
pub const Color = union(enum) {
    srgb,
    /// An embedded ICC profile (bytes of the file).
    icc: []const u8,
    /// Linear light with sRGB primaries already.
    linear,
    /// Coding-independent code points (ITU-T H.273): primaries and transfer
    /// characteristics.
    cicp: struct { primaries: u16, transfer: u16 },
};

/// Pixels a decoder produces: straight-alpha RGBA, 8 or 16 bits per
/// channel (native endian).
pub const Depth = enum { rgba8, rgba16 };

/// One decoder over one file, frame by frame onto a full-size canvas.
const Source = struct {
    width: u32,
    height: u32,
    depth: Depth,
    color: Color,
    loops: u32 = 0,
    ctx: *anyopaque,
    /// Writes the next frame's canvas into `out`; false after the last.
    next: *const fn (ctx: *anyopaque, out: []u8, delay_ms: *u32) Error!bool,
    close: *const fn (ctx: *anyopaque) void,
};

fn mapWuffs(r: c_int) Error {
    return switch (r) {
        c.SIV_WUFFS_UNSUPPORTED => error.Unsupported,
        c.SIV_WUFFS_TOO_LARGE => error.TooLarge,
        c.SIV_WUFFS_NO_MEMORY => error.OutOfMemory,
        else => error.InvalidImage,
    };
}

const wuffs = struct {
    fn open(bytes: []const u8, max_pixels: u64) Error!Source {
        var s: ?*c.siv_wuffs = null;
        var w: u32 = 0;
        var h: u32 = 0;
        var icc: [*c]const u8 = null;
        var icc_len: usize = 0;
        const r = c.siv_wuffs_open(bytes.ptr, bytes.len, max_pixels, &s, &w, &h, &icc, &icc_len);
        if (r != c.SIV_WUFFS_OK) return mapWuffs(r);
        return .{
            .width = w,
            .height = h,
            .depth = .rgba8,
            .color = if (icc != null and icc_len != 0) .{ .icc = icc[0..icc_len] } else .srgb,
            .loops = c.siv_wuffs_loops(s),
            .ctx = s.?,
            .next = next,
            .close = close,
        };
    }

    fn next(ctx: *anyopaque, out: []u8, delay_ms: *u32) Error!bool {
        const r = c.siv_wuffs_next(@ptrCast(ctx), out.ptr, delay_ms);
        if (r == c.SIV_WUFFS_END) return false;
        if (r != c.SIV_WUFFS_OK) return mapWuffs(r);
        return true;
    }

    fn close(ctx: *anyopaque) void {
        c.siv_wuffs_close(@ptrCast(ctx));
    }
};

const webp = struct {
    fn open(bytes: []const u8, max_pixels: u64) Error!Source {
        var s: ?*c.siv_webp = null;
        var w: u32 = 0;
        var h: u32 = 0;
        var icc: [*c]const u8 = null;
        var icc_len: usize = 0;
        var loops: u32 = 0;
        const r = c.siv_webp_open(bytes.ptr, bytes.len, max_pixels, &s, &w, &h, &icc, &icc_len, &loops);
        if (r != c.SIV_WUFFS_OK) return mapWuffs(r);
        return .{
            .width = w,
            .height = h,
            .depth = .rgba8,
            .color = if (icc != null and icc_len != 0) .{ .icc = icc[0..icc_len] } else .srgb,
            .loops = loops,
            .ctx = s.?,
            .next = next,
            .close = close,
        };
    }

    fn next(ctx: *anyopaque, out: []u8, delay_ms: *u32) Error!bool {
        const r = c.siv_webp_next(@ptrCast(ctx), out.ptr, delay_ms);
        if (r == c.SIV_WUFFS_END) return false;
        if (r != c.SIV_WUFFS_OK) return mapWuffs(r);
        return true;
    }

    fn close(ctx: *anyopaque) void {
        c.siv_webp_close(@ptrCast(ctx));
    }
};

const avif = struct {
    fn open(bytes: []const u8, max_pixels: u64) Error!Source {
        var s: ?*c.siv_avif = null;
        var w: u32 = 0;
        var h: u32 = 0;
        var depth16: c_int = 0;
        var icc: [*c]const u8 = null;
        var icc_len: usize = 0;
        var primaries: u16 = 2;
        var transfer: u16 = 2;
        var loops: u32 = 0;
        const r = c.siv_avif_open(bytes.ptr, bytes.len, max_pixels, &s, &w, &h, &depth16, &icc, &icc_len, &primaries, &transfer, &loops);
        if (r != c.SIV_WUFFS_OK) return mapWuffs(r);
        return .{
            .width = w,
            .height = h,
            .depth = if (depth16 != 0) .rgba16 else .rgba8,
            .color = if (icc != null and icc_len != 0) .{ .icc = icc[0..icc_len] } else .{ .cicp = .{ .primaries = primaries, .transfer = transfer } },
            .loops = loops,
            .ctx = s.?,
            .next = next,
            .close = close,
        };
    }

    fn next(ctx: *anyopaque, out: []u8, delay_ms: *u32) Error!bool {
        const r = c.siv_avif_next(@ptrCast(ctx), out.ptr, delay_ms);
        if (r == c.SIV_WUFFS_END) return false;
        if (r != c.SIV_WUFFS_OK) return mapWuffs(r);
        return true;
    }

    fn close(ctx: *anyopaque) void {
        c.siv_avif_close(@ptrCast(ctx));
    }
};

const jxl = struct {
    fn open(bytes: []const u8, max_pixels: u64) Error!Source {
        var s: ?*c.siv_jxl = null;
        var w: u32 = 0;
        var h: u32 = 0;
        var depth16: c_int = 0;
        var linear: c_int = 0;
        var icc: [*c]const u8 = null;
        var icc_len: usize = 0;
        var primaries: u16 = 1;
        var transfer: u16 = 13;
        var loops: u32 = 0;
        const r = c.siv_jxl_open(bytes.ptr, bytes.len, max_pixels, &s, &w, &h, &depth16, &linear, &icc, &icc_len, &primaries, &transfer, &loops);
        if (r != c.SIV_WUFFS_OK) return mapWuffs(r);
        const color: Color = if (linear != 0) .linear else if (icc != null and icc_len != 0) .{ .icc = icc[0..icc_len] } else .{ .cicp = .{ .primaries = primaries, .transfer = transfer } };
        return .{
            .width = w,
            .height = h,
            .depth = if (depth16 != 0) .rgba16 else .rgba8,
            .color = color,
            .loops = loops,
            .ctx = s.?,
            .next = next,
            .close = close,
        };
    }

    fn next(ctx: *anyopaque, out: []u8, delay_ms: *u32) Error!bool {
        const r = c.siv_jxl_next(@ptrCast(ctx), out.ptr, delay_ms);
        if (r == c.SIV_WUFFS_END) return false;
        if (r != c.SIV_WUFFS_OK) return mapWuffs(r);
        return true;
    }

    fn close(ctx: *anyopaque) void {
        c.siv_jxl_close(@ptrCast(ctx));
    }
};

fn open(format: Format, bytes: []const u8, max_pixels: u64) Error!Source {
    return switch (format) {
        .png, .jpeg, .gif => wuffs.open(bytes, max_pixels),
        .webp => webp.open(bytes, max_pixels),
        .avif => avif.open(bytes, max_pixels),
        .jxl => jxl.open(bytes, max_pixels),
    };
}

// Decoding --------------------------------------------------------------------

/// Decodes an image (see the module comment).
pub fn decode(gpa: Allocator, bytes: []const u8, options: Options) Error!Image {
    const format = sniff(bytes) orelse return error.Unsupported;
    var src = try open(format, bytes, options.max_pixels);
    defer src.close(src.ctx);
    if (src.width == 0 or src.height == 0) return error.InvalidImage;
    if (@as(u64, src.width) * src.height > options.max_pixels) return error.TooLarge;

    var conv = try Converter.init(gpa, src, fitSize(src.width, src.height, options.max_width, options.max_height), options.linear);
    defer conv.deinit(gpa);

    const src_bpp: usize = if (src.depth == .rgba8) 4 else 8;
    const canvas = try gpa.alignedAlloc(u8, .@"16", @as(usize, src.width) * src.height * src_bpp);
    defer gpa.free(canvas);

    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |f| gpa.free(f.pixels);
        frames.deinit(gpa);
    }
    const frame_bytes = @as(usize, conv.dw) * conv.dh * conv.format.bytesPerPixel();
    var total: usize = 0;
    while (true) {
        var delay: u32 = 0;
        if (!try src.next(src.ctx, canvas, &delay)) break;
        if (total + frame_bytes > options.max_bytes and frames.items.len != 0) {
            // Too much to keep: the first frame only.
            for (frames.items[1..]) |f| gpa.free(f.pixels);
            frames.shrinkRetainingCapacity(1);
            break;
        }
        const pixels = try gpa.alignedAlloc(u8, .@"16", frame_bytes);
        errdefer gpa.free(pixels);
        conv.convert(canvas, pixels);
        try frames.append(gpa, .{ .pixels = pixels, .delay_ms = delay });
        total += frame_bytes;
        if (options.first_frame) break;
    }
    if (frames.items.len == 0) return error.InvalidImage;
    // A single frame needs no delay.
    if (frames.items.len == 1) frames.items[0].delay_ms = 0;
    return .{
        .width = conv.dw,
        .height = conv.dh,
        .source_width = src.width,
        .source_height = src.height,
        .format = conv.format,
        .frames = try frames.toOwnedSlice(gpa),
        .loops = src.loops,
    };
}

/// The working-space conversion and scaling of one image's frames.
const Converter = struct {
    sw: u32,
    sh: u32,
    dw: u32,
    dh: u32,
    depth: Depth,
    format: scene.ImageFormat,
    icc: ?*c.siv_icc = null,
    /// Decoded value to linear 16-bit, for sRGB-encoded pixels: 256
    /// entries for 8 bits, 65536 for 16 (also CICP transfer functions).
    lut: []u16 = &.{},
    /// CICP primaries to sRGB, in linear light.
    matrix: ?[9]f32 = null,
    /// One source row in linear 16-bit straight RGBA.
    row: []u16,
    /// Scaling: a source row resampled horizontally, and the output row
    /// being summed, in premultiplied linear light.
    hrow: []f32 = &.{},
    acc: []f32 = &.{},

    fn init(gpa: Allocator, src: Source, size: [2]u32, linear: bool) Error!Converter {
        var conv: Converter = .{
            .sw = src.width,
            .sh = src.height,
            .dw = size[0],
            .dh = size[1],
            .depth = src.depth,
            .format = .rgba16_linear_premul,
            .row = &.{},
        };
        errdefer conv.deinit(gpa);
        var color = src.color;
        if (color == .icc) {
            conv.icc = c.siv_icc_new(color.icc.ptr, color.icc.len, if (src.depth == .rgba8) 8 else 16);
            if (conv.icc) |t| {
                if (c.siv_icc_is_srgb(t) != 0) {
                    c.siv_icc_free(t);
                    conv.icc = null;
                    color = .srgb;
                }
            } else color = .srgb;
        }
        if (color == .cicp) {
            // Unspecified transfer is sRGB's, and sRGB primaries with it
            // are plain sRGB.
            if (color.cicp.transfer == 2) color.cicp.transfer = 13;
            const p = color.cicp;
            if ((p.primaries == 1 or p.primaries == 2) and p.transfer == 13) color = .srgb;
        }
        const scaled = conv.dw != conv.sw or conv.dh != conv.sh;
        if (color == .srgb and src.depth == .rgba8 and !scaled and !linear) {
            conv.format = .rgba8_srgb;
            return conv;
        }
        conv.row = try gpa.alloc(u16, @as(usize, conv.sw) * 4);
        switch (color) {
            .srgb => conv.lut = try transferLut(gpa, if (src.depth == .rgba8) 8 else 16, 13),
            .cicp => |p| {
                conv.lut = try transferLut(gpa, if (src.depth == .rgba8) 8 else 16, p.transfer);
                conv.matrix = primariesToSrgb(p.primaries);
            },
            .icc, .linear => {},
        }
        if (scaled) {
            conv.hrow = try gpa.alloc(f32, @as(usize, conv.dw) * 4);
            conv.acc = try gpa.alloc(f32, @as(usize, conv.dw) * 4);
        }
        return conv;
    }

    fn deinit(conv: *Converter, gpa: Allocator) void {
        if (conv.icc) |t| c.siv_icc_free(t);
        gpa.free(conv.lut);
        gpa.free(conv.row);
        gpa.free(conv.hrow);
        gpa.free(conv.acc);
    }

    /// One source row to linear 16-bit straight RGBA in `conv.row`.
    fn linearRow(conv: *Converter, src: []const u8) void {
        const n = conv.sw;
        if (conv.icc) |t| return c.siv_icc_apply(t, src.ptr, conv.row.ptr, n);
        const out = conv.row;
        if (conv.depth == .rgba8) {
            for (0..n) |i| {
                for (0..3) |k| out[i * 4 + k] = if (conv.lut.len != 0) conv.lut[src[i * 4 + k]] else @as(u16, src[i * 4 + k]) * 257;
                out[i * 4 + 3] = @as(u16, src[i * 4 + 3]) * 257;
            }
        } else {
            const s16: []align(1) const u16 = std.mem.bytesAsSlice(u16, src[0 .. n * 8]);
            for (0..n) |i| {
                for (0..3) |k| out[i * 4 + k] = if (conv.lut.len != 0) conv.lut[s16[i * 4 + k]] else s16[i * 4 + k];
                out[i * 4 + 3] = s16[i * 4 + 3];
            }
        }
        if (conv.matrix) |m| for (0..n) |i| {
            const px = out[i * 4 ..][0..3];
            const r: f32 = @floatFromInt(px[0]);
            const g: f32 = @floatFromInt(px[1]);
            const b: f32 = @floatFromInt(px[2]);
            for (0..3) |k| {
                const v = m[k * 3] * r + m[k * 3 + 1] * g + m[k * 3 + 2] * b;
                px[k] = @intFromFloat(std.math.clamp(@round(v), 0, 65535));
            }
        };
    }

    /// One frame's canvas to the output pixels.
    fn convert(conv: *Converter, canvas: []const u8, dst: []align(16) u8) void {
        const src_stride: usize = @as(usize, conv.sw) * (if (conv.depth == .rgba8) @as(usize, 4) else 8);
        if (conv.format == .rgba8_srgb) return @memcpy(dst, canvas[0..dst.len]);
        const out: []u16 = std.mem.bytesAsSlice(u16, dst);
        if (conv.hrow.len == 0) {
            for (0..conv.sh) |y| {
                conv.linearRow(canvas[y * src_stride ..][0..src_stride]);
                const o = out[y * conv.sw * 4 ..][0 .. conv.sw * 4];
                for (0..conv.sw) |i| premultiply(conv.row[i * 4 ..][0..4], o[i * 4 ..][0..4]);
            }
            return;
        }
        // Area averaging in premultiplied linear light: every source pixel
        // adds to the output pixels it overlaps, by the overlap.
        const fy = @as(f64, @floatFromInt(conv.sh)) / @as(f64, @floatFromInt(conv.dh));
        const norm: f32 = @floatCast(1.0 / (fy * @as(f64, @floatFromInt(conv.sw)) / @as(f64, @floatFromInt(conv.dw))));
        @memset(conv.acc, 0);
        var oy: u32 = 0;
        for (0..conv.sh) |y| {
            conv.linearRow(canvas[y * src_stride ..][0..src_stride]);
            conv.horizontal();
            const y0: f64 = @floatFromInt(y);
            const y1 = y0 + 1;
            while (oy < conv.dh) {
                const span0 = @as(f64, @floatFromInt(oy)) * fy;
                const span1 = if (oy + 1 == conv.dh) @as(f64, @floatFromInt(conv.sh)) else @as(f64, @floatFromInt(oy + 1)) * fy;
                const w: f32 = @floatCast(@min(y1, span1) - @max(y0, span0));
                if (w > 0) for (conv.acc, conv.hrow) |*a, h| {
                    a.* += h * w;
                };
                if (span1 > y1 + 1e-9) break;
                const o = out[oy * conv.dw * 4 ..][0 .. conv.dw * 4];
                for (o, conv.acc) |*d, a| d.* = @intFromFloat(std.math.clamp(@round(a * norm), 0, 65535));
                @memset(conv.acc, 0);
                oy += 1;
            }
        }
    }

    /// `conv.row` resampled to the output width into `conv.hrow`, as sums
    /// (not yet divided by the scale), premultiplied.
    fn horizontal(conv: *Converter) void {
        const fx = @as(f64, @floatFromInt(conv.sw)) / @as(f64, @floatFromInt(conv.dw));
        @memset(conv.hrow, 0);
        var ox: u32 = 0;
        for (0..conv.sw) |x| {
            const px = conv.row[x * 4 ..][0..4];
            const a: f32 = @as(f32, @floatFromInt(px[3])) / 65535;
            const p = [4]f32{ @as(f32, @floatFromInt(px[0])) * a, @as(f32, @floatFromInt(px[1])) * a, @as(f32, @floatFromInt(px[2])) * a, @floatFromInt(px[3]) };
            const x0: f64 = @floatFromInt(x);
            const x1 = x0 + 1;
            while (ox < conv.dw) {
                const span0 = @as(f64, @floatFromInt(ox)) * fx;
                const span1 = if (ox + 1 == conv.dw) @as(f64, @floatFromInt(conv.sw)) else @as(f64, @floatFromInt(ox + 1)) * fx;
                const w: f32 = @floatCast(@min(x1, span1) - @max(x0, span0));
                if (w > 0) for (0..4) |k| {
                    conv.hrow[ox * 4 + k] += p[k] * w;
                };
                if (span1 > x1 + 1e-9) break;
                ox += 1;
            }
        }
    }
};

fn premultiply(px: *const [4]u16, out: *[4]u16) void {
    const a: u32 = px[3];
    for (0..3) |k| out[k] = @intCast((@as(u32, px[k]) * a + 32767) / 65535);
    out[3] = px[3];
}

/// Linear 16-bit values for every code value of `bits` bits under an
/// H.273 transfer characteristic. HDR transfers (PQ, HLG) map their
/// reference white (203 cd/m²) to 1 and clip above it until HDR output
/// exists (D11).
fn transferLut(gpa: Allocator, bits: u5, transfer: u16) Allocator.Error![]u16 {
    const n = @as(usize, 1) << bits;
    const lut = try gpa.alloc(u16, n);
    const max: f64 = @floatFromInt(n - 1);
    for (lut, 0..) |*e, i| {
        const v = @as(f64, @floatFromInt(i)) / max;
        e.* = @intFromFloat(@round(std.math.clamp(eotf(transfer, v), 0, 1) * 65535));
    }
    return lut;
}

fn eotf(transfer: u16, v: f64) f64 {
    return switch (transfer) {
        // Linear.
        8 => v,
        // BT.709, BT.601, BT.2020: the inverse of their camera curve.
        1, 6, 14, 15 => if (v < 0.081) v / 4.5 else std.math.pow(f64, (v + 0.099) / 1.099, 1.0 / 0.45),
        // Gamma 2.2 and 2.8.
        4 => std.math.pow(f64, v, 2.2),
        5 => std.math.pow(f64, v, 2.8),
        // PQ (SMPTE ST 2084), in units of 203 cd/m².
        16 => blk: {
            const m1 = 2610.0 / 16384.0;
            const m2 = 2523.0 / 4096.0 * 128.0;
            const c1 = 3424.0 / 4096.0;
            const c2 = 2413.0 / 4096.0 * 32.0;
            const c3 = 2392.0 / 4096.0 * 32.0;
            const p = std.math.pow(f64, v, 1.0 / m2);
            const l = std.math.pow(f64, @max(p - c1, 0) / (c2 - c3 * p), 1.0 / m1);
            break :blk l * 10000.0 / 203.0;
        },
        // HLG (ARIB STD-B67), its nominal peak at 1000 cd/m².
        18 => blk: {
            const a = 0.17883277;
            const b = 1 - 4 * a;
            const cc = 0.5 - a * @log(4 * a);
            const e = if (v <= 0.5) v * v / 3 else (@exp((v - cc) / a) + b) / 12;
            break :blk e * 1000.0 / 203.0;
        },
        // sRGB, and anything unknown.
        else => if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4),
    };
}

/// Linear RGB in H.273 primaries to linear sRGB (both D65); null for sRGB
/// primaries and unknown ones.
fn primariesToSrgb(primaries: u16) ?[9]f32 {
    return switch (primaries) {
        // BT.2020.
        9 => .{ 1.6605, -0.5876, -0.0728, -0.1246, 1.1329, -0.0083, -0.0182, -0.1006, 1.1187 },
        // Display P3.
        12 => .{ 1.2249, -0.2247, 0.0, -0.0420, 1.0419, 0.0, -0.0197, -0.0786, 1.0979 },
        else => null,
    };
}

// Tests -----------------------------------------------------------------------

const testing = std.testing;

test "formats are told apart by their first bytes" {
    try testing.expectEqual(Format.png, sniff("\x89PNG\r\n\x1a\nrest").?);
    try testing.expectEqual(Format.jpeg, sniff("\xff\xd8\xff\xe0").?);
    try testing.expectEqual(Format.gif, sniff("GIF89a...").?);
    try testing.expectEqual(Format.webp, sniff("RIFF\x00\x00\x00\x00WEBPVP8 ").?);
    try testing.expectEqual(Format.avif, sniff("\x00\x00\x00\x1cftypavif\x00\x00\x00\x00").?);
    try testing.expectEqual(Format.avif, sniff("\x00\x00\x00\x1cftypmif1\x00\x00\x00\x00avifmiaf").?);
    try testing.expectEqual(Format.jxl, sniff("\xff\x0a\x00").?);
    try testing.expect(sniff("hello") == null);
    try testing.expectError(error.Unsupported, decode(testing.allocator, "hello", .{}));
}

test "sizes fit within the bounds, never larger" {
    try testing.expectEqual([2]u32{ 100, 50 }, fitSize(100, 50, 0, 0));
    try testing.expectEqual([2]u32{ 100, 50 }, fitSize(100, 50, 200, 200));
    try testing.expectEqual([2]u32{ 40, 20 }, fitSize(100, 50, 40, 0));
    try testing.expectEqual([2]u32{ 20, 10 }, fitSize(100, 50, 40, 10));
    try testing.expectEqual([2]u32{ 10, 1 }, fitSize(1000, 1, 10, 10));
}

test "transfer functions and primaries" {
    try testing.expectApproxEqAbs(@as(f64, 0.2140), eotf(13, 0.5), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 10000.0 / 203.0), eotf(16, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1000.0 / 203.0 * 0.0833), eotf(18, 0.5) / 1 * 1, 1e-3);
    // Rows of a primaries matrix sum to 1: white stays white.
    for ([_]u16{ 9, 12 }) |p| {
        const m = primariesToSrgb(p).?;
        for (0..3) |r| try testing.expectApproxEqAbs(@as(f32, 1), m[r * 3] + m[r * 3 + 1] + m[r * 3 + 2], 2e-3);
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
