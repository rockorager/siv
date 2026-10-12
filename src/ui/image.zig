//! Images (D2, D9): immutable pixels that siv owns, reference counted.
//!
//! `Image.create` copies the caller's pixels, so the caller may free or
//! reuse them at once. The tree holds a reference for each image node
//! that shows it, and every display list that draws it holds one until
//! the compositor releases the list (`Event.released`), so the pixels
//! outlive every frame that can still read them. The creator's
//! reference is dropped with `release`; the last release frees them.

const std = @import("std");
const scene = @import("scene");

pub const Image = struct {
    gpa: std.mem.Allocator,
    refs: std.atomic.Value(u32),
    pixels: []align(16) const u8,
    width: u32,
    height: u32,
    /// Bytes per row: rows are packed.
    stride: u32,
    format: scene.ImageFormat,
    /// Unique to this image for the life of the process.
    key: u64,

    pub const Desc = struct {
        pixels: []const u8,
        width: u32,
        height: u32,
        /// Bytes per row of `pixels`; 0 means packed rows.
        stride: u32 = 0,
        format: scene.ImageFormat = .rgba8_srgb,
    };

    pub const Error = error{ OutOfMemory, InvalidArgument };

    /// Copies `desc.pixels` into a new image with one reference.
    pub fn create(gpa: std.mem.Allocator, desc: Desc) Error!*Image {
        if (desc.width == 0 or desc.height == 0) return error.InvalidArgument;
        const row = std.math.mul(u32, desc.width, desc.format.bytesPerPixel()) catch return error.InvalidArgument;
        const stride = if (desc.stride == 0) row else desc.stride;
        if (stride < row) return error.InvalidArgument;
        const needed = std.math.add(u64, @as(u64, stride) * (desc.height - 1), row) catch return error.InvalidArgument;
        if (desc.pixels.len < needed) return error.InvalidArgument;
        const size = std.math.cast(usize, @as(u64, row) * desc.height) orelse return error.OutOfMemory;

        const img = try gpa.create(Image);
        errdefer gpa.destroy(img);
        const pixels = try gpa.alignedAlloc(u8, .@"16", size);
        for (0..desc.height) |y| @memcpy(pixels[y * row ..][0..row], desc.pixels[y * stride ..][0..row]);
        img.* = .{
            .gpa = gpa,
            .refs = .init(1),
            .pixels = pixels,
            .width = desc.width,
            .height = desc.height,
            .stride = row,
            .format = desc.format,
            .key = next_key.fetchAdd(1, .monotonic),
        };
        return img;
    }

    /// Adds a reference. Any thread.
    pub fn retain(img: *Image) *Image {
        _ = img.refs.fetchAdd(1, .monotonic);
        return img;
    }

    /// Drops a reference; the last one frees the pixels. Any thread.
    pub fn release(img: *Image) void {
        if (img.refs.fetchSub(1, .release) != 1) return;
        _ = img.refs.load(.acquire);
        img.gpa.free(img.pixels);
        img.gpa.destroy(img);
    }

    /// The pixels for a display list, valid while a reference is held.
    pub fn sceneRef(img: *const Image) scene.ImageRef {
        return .{ .pixels = img.pixels.ptr, .width = img.width, .height = img.height, .stride = img.stride, .format = img.format, .key = img.key };
    }
};

/// Keys have the top bit set, apart from keys that producers choose for
/// external frames (D17), so backend caches keyed by them cannot mix the
/// two up.
var next_key: std.atomic.Value(u64) = .init(1 << 63);

test "create copies and packs the pixels; the last release frees them" {
    const gpa = std.testing.allocator;
    // Two rows of two RGBA pixels with four bytes of padding per row.
    var src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 0xEE, 0xEE, 0xEE, 0xEE, 9, 10, 11, 12, 13, 14, 15, 16, 0xEE, 0xEE, 0xEE, 0xEE };
    const img = try Image.create(gpa, .{ .pixels = &src, .width = 2, .height = 2, .stride = 12 });
    @memset(&src, 0);
    try std.testing.expectEqual(@as(u32, 8), img.stride);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, img.pixels);
    const other = try Image.create(gpa, .{ .pixels = img.pixels, .width = 2, .height = 2 });
    try std.testing.expect(other.key != img.key and img.key >= 1 << 63);
    other.release();
    _ = img.retain();
    img.release();
    try std.testing.expectEqual(@as(u8, 16), img.pixels[15]);
    img.release();
}

test "create rejects rows that do not fit" {
    const gpa = std.testing.allocator;
    const px: [15]u8 = @splat(0);
    try std.testing.expectError(error.InvalidArgument, Image.create(gpa, .{ .pixels = &px, .width = 2, .height = 2 }));
    try std.testing.expectError(error.InvalidArgument, Image.create(gpa, .{ .pixels = &px, .width = 2, .height = 1, .stride = 4 }));
    try std.testing.expectError(error.InvalidArgument, Image.create(gpa, .{ .pixels = &px, .width = 0, .height = 1 }));
    // The last row needs only its own bytes, not a full stride.
    const img = try Image.create(gpa, .{ .pixels = px[0..14], .width = 1, .height = 2, .stride = 10 });
    img.release();
}
