//! PNG, APNG, JPEG, GIF, WebP, and JPEG XL for src/image (D19), decoded in
//! Zig by baskingspot's image package. This file is the root of an object
//! compiled once per build and linked through `image_c`, as the C decoders
//! are, so the decoders are not compiled again by every compilation that
//! imports `image` (D25); src/image/image.zig reaches it through the
//! `siv_native_*` functions below, which stay hidden in libsiv.
//!
//! Each frame is drawn onto the canvas `siv_native_next` is given, which
//! holds the previous frame: the package blends a frame onto it, and this
//! applies the frame's disposal before the next one. Memory comes from the
//! C allocator, as the C decoders' does; pixels go into siv's buffers.

const std = @import("std");
const bs = @import("baskingspot_image");

const gpa = std.heap.c_allocator;

/// As in src/siv.zig: no per-thread signal stack in a library's
/// thread-local storage.
pub const std_options: std.Options = .{ .signal_stack_size = null };

const abi = @import("native_abi.zig");
const Format = abi.Format;
const Info = abi.Info;
const ok = abi.ok;
const end = abi.end;
const unsupported = abi.unsupported;
const invalid = abi.invalid;
const too_large = abi.too_large;
const no_memory = abi.no_memory;

const Impl = union(Format) {
    png: bs.png.Decoder,
    jpeg: bs.jpeg.Decoder,
    gif: bs.gif.Decoder,
    webp: bs.webp.Decoder,
    jxl: bs.jxl.Decoder,
};

const State = struct {
    reader: std.Io.Reader,
    impl: Impl,
    pixel_format: bs.PixelFormat = .rgba8,
    width: u32 = 0,
    height: u32 = 0,
    work: []u8 = &.{},
    /// The embedded ICC profile as the file stores it (zlib in PNG).
    icc: std.ArrayList(u8) = .empty,
    icc_zlib: bool = false,
    icc_failed: bool = false,
    /// Frames drawn so far.
    drawn: u32 = 0,
    /// The last frame, whose disposal comes before the next one.
    last: ?bs.Frame = null,
    /// The canvas before the last frame, for `previous` disposal.
    saved: []u8 = &.{},

    fn create(format: Format, bytes: []const u8, max_pixels: u64) error{OutOfMemory}!*State {
        const st = try gpa.create(State);
        st.* = .{ .reader = .fixed(bytes), .impl = undefined };
        const limits: bs.Limits = .{ .max_pixels = max_pixels, .max_frames = std.math.maxInt(u32) };
        st.impl = switch (format) {
            inline else => |f| @unionInit(Impl, @tagName(f), .init(&st.reader, .{ .limits = limits, .blob_sink = st.sink() })),
        };
        return st;
    }

    fn destroy(st: *State) void {
        st.icc.deinit(gpa);
        gpa.free(st.work);
        gpa.free(st.saved);
        gpa.destroy(st);
    }

    fn sink(st: *State) bs.BlobSink {
        return .{ .context = st, .write = collect };
    }

    fn collect(ctx: *anyopaque, blob: bs.Blob, at: u64, bytes: []const u8) void {
        const st: *State = @ptrCast(@alignCast(ctx));
        if (blob.kind != .icc or blob.encoding == .brotli or st.icc_failed) return;
        // A profile larger than 4 MiB is ignored.
        if (at != st.icc.items.len or at + bytes.len > 4 << 20) {
            st.icc_failed = true;
            return;
        }
        st.icc_zlib = blob.encoding == .zlib;
        st.icc.appendSlice(gpa, bytes) catch {
            st.icc_failed = true;
        };
    }
};

fn code(e: anyerror) c_int {
    return switch (e) {
        error.OutOfMemory => no_memory,
        error.ImageTooLarge, error.WorkTooLarge => too_large,
        error.Unsupported => unsupported,
        else => invalid,
    };
}

fn open(f: Format, data: [*]const u8, len: usize, max_pixels: u64, count: bool, info: *Info) callconv(.c) c_int {
    info.* = .{};
    const bytes = data[0..len];
    const st = State.create(f, bytes, max_pixels) catch return no_memory;
    readHeaders(st, f, bytes, max_pixels, count, info) catch |e| {
        st.destroy();
        return code(e);
    };
    info.ctx = st;
    return ok;
}

fn readHeaders(st: *State, format: Format, bytes: []const u8, max_pixels: u64, count: bool, info: *Info) !void {
    const config = switch (st.impl) {
        inline else => |*d| try d.decodeConfig(),
    };
    st.width = config.width;
    st.height = config.height;
    // 16 bits for sources deeper than 8 (floats included).
    info.deep = config.native.sample() != .u8;
    st.pixel_format = if (info.deep) .rgba16 else .rgba8;
    st.work = try gpa.alloc(u8, config.work_len);
    const m = config.metadata;
    // A JPEG XL file's profile comes with its first frame: skim the frames
    // with a second decoder to have it now.
    if (format == .jxl and m.icc != null and m.transfer == null) {
        var r: std.Io.Reader = .fixed(bytes);
        var d: bs.jxl.Decoder = .init(&r, .{ .limits = .{ .max_pixels = max_pixels }, .blob_sink = st.sink() });
        var skim: bs.jxl.Decoder.Skim = .{};
        try d.skim(st.work, &skim);
    }
    try colorOf(st, m, info);
    info.width = st.width;
    info.height = st.height;
    info.loops = config.loop_count orelse 0;
    info.frames = if (config.frame_count) |n| n else if (!count) 0 else switch (format) {
        .gif => countGif(bytes),
        .webp => countWebp(bytes),
        // Nothing short of decoding a JPEG XL file's frames says which of
        // them are shown.
        .jxl => countDecoded(format, bytes, max_pixels) catch 0,
        .png, .jpeg => 0,
    };
}

/// How the decoded pixels encode color: the file's code points, its
/// transfer function and primaries, its ICC profile, or sRGB.
fn colorOf(st: *State, m: bs.Metadata, info: *Info) !void {
    if (m.cicp) |p| {
        info.color = 2;
        info.primaries = p.primaries;
        info.transfer = p.transfer;
        return;
    }
    if (m.transfer) |t| {
        const primaries: u16 = if (m.primaries) |xy| primariesCode(xy) else 1;
        if (t == .linear and primaries == 1) {
            info.color = 3;
            return;
        }
        info.color = 2;
        info.primaries = primaries;
        info.transfer = switch (t) {
            .srgb => 13,
            .linear => 8,
            .bt709 => 1,
            .dci => 17,
            .pq => 16,
            .hlg => 18,
        };
        return;
    }
    if (st.icc.items.len == 0 or st.icc_failed) return;
    if (st.icc_zlib) {
        var in: std.Io.Reader = .fixed(st.icc.items);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var z: std.compress.flate.Decompress = .init(&in, .zlib, &window);
        const raw = z.reader.allocRemaining(gpa, .limited(4 << 20)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        st.icc.deinit(gpa);
        st.icc = .fromOwnedSlice(raw);
        st.icc_zlib = false;
    }
    info.color = 1;
    info.icc = st.icc.items.ptr;
    info.icc_len = st.icc.items.len;
}

/// The H.273 code of CIE xy primaries (red, green, blue, white): 9 for
/// BT.2020 and 12 for Display P3, each with a D65 white, and 1 for sRGB and
/// everything else.
fn primariesCode(xy: [8]f32) u16 {
    const known = [_]struct { u16, [8]f32 }{
        .{ 9, .{ 0.708, 0.292, 0.17, 0.797, 0.131, 0.046, 0.3127, 0.329 } },
        .{ 12, .{ 0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329 } },
    };
    for (known) |k| {
        for (k[1], xy) |a, b| {
            if (@abs(a - b) > 0.001) break;
        } else return k[0];
    }
    return 1;
}

fn countDecoded(format: Format, bytes: []const u8, max_pixels: u64) !u32 {
    var info: Info = .{};
    const r = open(format, bytes.ptr, bytes.len, max_pixels, false, &info);
    if (r != ok) return error.InvalidImage;
    defer close(info.ctx.?);
    const canvas = try gpa.alloc(u8, @as(usize, info.width) * info.height * @as(usize, if (info.deep) 8 else 4));
    defer gpa.free(canvas);
    var n: u32 = 0;
    var delay: u32 = 0;
    while (n < std.math.maxInt(u32) and next(info.ctx.?, canvas.ptr, canvas.len, &delay) == ok) n += 1;
    return n;
}

/// Image descriptors in a GIF's block stream, up to its trailer or the end
/// of the data.
fn countGif(bytes: []const u8) u32 {
    if (bytes.len < 13) return 0;
    var i: usize = 13;
    if (bytes[10] & 0x80 != 0) i += @as(usize, 3) << @intCast((bytes[10] & 7) + 1);
    var n: u32 = 0;
    while (i < bytes.len) {
        switch (bytes[i]) {
            // An extension: its label, then sub-blocks.
            0x21 => i += 2,
            0x2c => {
                if (i + 10 > bytes.len) break;
                const flags = bytes[i + 9];
                i += 10;
                if (flags & 0x80 != 0) i += @as(usize, 3) << @intCast((flags & 7) + 1);
                // The LZW minimum code size, then sub-blocks.
                i += 1;
                n += 1;
            },
            else => break,
        }
        while (i < bytes.len and bytes[i] != 0) i += @as(usize, bytes[i]) + 1;
        i += 1;
    }
    return n;
}

/// ANMF chunks in an animated WebP; 1 for a still one.
fn countWebp(bytes: []const u8) u32 {
    var i: usize = 12;
    var n: u32 = 0;
    while (i + 8 <= bytes.len) {
        const size = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        if (std.mem.eql(u8, bytes[i..][0..4], "ANMF")) n += 1;
        i += 8 + @as(usize, size) + (size & 1);
    }
    return @max(n, 1);
}

fn next(ctx: *anyopaque, rgba: [*]u8, len: usize, delay_ms: *u32) callconv(.c) c_int {
    const st: *State = @ptrCast(@alignCast(ctx));
    const out = rgba[0..len];
    const canvas = bs.PixelBuffer.init(out, st.pixel_format, st.width, st.height) catch return invalid;
    if (st.last) |f| switch (f.disposal) {
        .none => {},
        .background => {
            const region = canvas.sub(f.x, f.y, f.width, f.height);
            for (0..region.height) |y| @memset(region.row(@intCast(y)), 0);
        },
        .previous => @memcpy(out, st.saved),
    };
    const frame = draw(st, canvas, out) catch |e| {
        if (e == error.OutOfMemory) return no_memory;
        return if (st.drawn != 0) end else code(e);
    } orelse return end;
    st.drawn += 1;
    st.last = frame;
    delay_ms.* = @intCast(@min(frame.duration * 1000 / bs.flicks_per_second, std.math.maxInt(u32)));
    return ok;
}

fn draw(st: *State, canvas: bs.PixelBuffer, out: []u8) !?bs.Frame {
    // A frame to be undone needs the canvas as it was before it.
    const upcoming = switch (st.impl) {
        inline .png, .gif, .webp => |*d| try d.decodeFrameConfig(),
        .jpeg, .jxl => null,
    };
    if (upcoming) |f| if (f.disposal == .previous) {
        if (st.saved.len == 0) st.saved = try gpa.alloc(u8, out.len);
        @memcpy(st.saved, out);
    };
    return switch (st.impl) {
        inline else => |*d| try d.decodeFrame(canvas, st.work),
    };
}

fn close(ctx: *anyopaque) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    st.destroy();
}

comptime {
    @export(@as(*const abi.Open, &open), .{ .name = "siv_native_open", .visibility = .hidden });
    @export(@as(*const abi.Next, &next), .{ .name = "siv_native_next", .visibility = .hidden });
    @export(@as(*const abi.Close, &close), .{ .name = "siv_native_close", .visibility = .hidden });
}
