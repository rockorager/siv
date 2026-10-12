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
const image_mod = @import("image");
const loop_mod = @import("loop");

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
    /// Pixels per logical pixel: an image node's intrinsic size is the
    /// pixel size divided by it (images decoded for a scale-2 window).
    scale: f32 = 1,
    /// An animation's frames, the first being `pixels`; empty for a still
    /// image.
    frames: []const Frame = &.{},
    /// How many times an animation plays; 0 loops forever.
    loops: u32 = 0,

    pub const Frame = struct {
        pixels: []align(16) const u8,
        /// How long to show it, in milliseconds.
        delay_ms: u32,
        key: u64,
    };

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
        if (img.frames.len == 0) img.gpa.free(img.pixels);
        for (img.frames) |f| img.gpa.free(f.pixels);
        img.gpa.free(img.frames);
        img.gpa.destroy(img);
    }

    /// Takes the frames of a decoded image (allocated with `gpa`), which
    /// is consumed even on failure.
    pub fn fromDecoded(gpa: std.mem.Allocator, d: image_mod.Image, scale: f32) error{OutOfMemory}!*Image {
        errdefer d.deinit(gpa);
        const img = try gpa.create(Image);
        errdefer gpa.destroy(img);
        var frames: []Frame = &.{};
        if (d.frames.len > 1) {
            frames = try gpa.alloc(Frame, d.frames.len);
            for (frames, d.frames) |*f, src| f.* = .{ .pixels = src.pixels, .delay_ms = src.delay_ms, .key = next_key.fetchAdd(1, .monotonic) };
        }
        img.* = .{
            .gpa = gpa,
            .refs = .init(1),
            .pixels = d.frames[0].pixels,
            .width = d.width,
            .height = d.height,
            .stride = d.stride(),
            .format = d.format,
            .key = if (frames.len != 0) frames[0].key else next_key.fetchAdd(1, .monotonic),
            .scale = if (scale > 0 and std.math.isFinite(scale)) scale else 1,
            .frames = frames,
            .loops = d.loops,
        };
        // The pixels now belong to the image.
        gpa.free(d.frames);
        return img;
    }

    /// The pixels for a display list, valid while a reference is held.
    pub fn sceneRef(img: *const Image) scene.ImageRef {
        return .{ .pixels = img.pixels.ptr, .width = img.width, .height = img.height, .stride = img.stride, .format = img.format, .key = img.key };
    }

    /// The intrinsic size in logical pixels.
    pub fn logicalSize(img: *const Image) [2]f32 {
        return .{ @as(f32, @floatFromInt(img.width)) / img.scale, @as(f32, @floatFromInt(img.height)) / img.scale };
    }

    /// Frame `i` of an animation (the image itself when still).
    pub fn frameRef(img: *const Image, i: usize) scene.ImageRef {
        var r = img.sceneRef();
        if (i < img.frames.len) {
            r.pixels = img.frames[i].pixels.ptr;
            r.key = img.frames[i].key;
        }
        return r;
    }

    pub const LoadError = image_mod.Error || error{
        /// The file could not be read.
        ReadFailed,
    };

    pub const Source = union(enum) {
        /// The file's bytes.
        bytes: []const u8,
        /// A file path, read on the worker.
        path: []const u8,
    };

    pub const LoadOptions = struct {
        decode: image_mod.Options = .{},
        /// Pixels per logical pixel; the decode bounds are in pixels.
        scale: f32 = 1,
    };

    /// Called with the image (the callee owns the reference) or why it
    /// failed, in the loop's dispatch phase; `destroy` runs afterwards,
    /// or alone when the loop goes away first (D5).
    pub const LoadDone = struct {
        ctx: ?*anyopaque = null,
        func: *const fn (ctx: ?*anyopaque, result: LoadError!*Image) void,
        destroy: ?*const fn (ctx: ?*anyopaque) void = null,
    };

    /// Reads (for a path) and decodes an image on the worker pool, without
    /// blocking the loop. The source is copied.
    pub fn load(pool: *loop_mod.Pool, gpa: std.mem.Allocator, source: Source, options: LoadOptions, done: LoadDone) error{OutOfMemory}!void {
        const l = try gpa.create(Load);
        errdefer gpa.destroy(l);
        const copy = try gpa.dupe(u8, switch (source) {
            inline else => |b| b,
        });
        l.* = .{ .gpa = gpa, .source = copy, .is_path = source == .path, .options = options, .done = done };
        pool.submit(&l.job) catch {
            gpa.free(copy);
            return error.OutOfMemory;
        };
    }
};

/// Files larger than this are not images siv decodes.
const max_file = 512 << 20;

const Load = struct {
    job: loop_mod.Pool.Job = .{ .run = run, .done = finish, .cancel = cancel },
    gpa: std.mem.Allocator,
    source: []u8,
    is_path: bool,
    options: Image.LoadOptions,
    done: Image.LoadDone,
    result: Image.LoadError!*Image = error.InvalidImage,

    fn run(job: *loop_mod.Pool.Job) void {
        const l: *Load = @fieldParentPtr("job", job);
        l.result = l.decode();
    }

    fn decode(l: *Load) Image.LoadError!*Image {
        var bytes: []const u8 = l.source;
        var file: ?[]u8 = null;
        defer if (file) |f| l.gpa.free(f);
        if (l.is_path) {
            file = try readFile(l.gpa, l.source);
            bytes = file.?;
        }
        const d = try image_mod.decode(l.gpa, bytes, l.options.decode);
        return Image.fromDecoded(l.gpa, d, l.options.scale);
    }

    fn finish(job: *loop_mod.Pool.Job) void {
        const l: *Load = @fieldParentPtr("job", job);
        const done = l.done;
        const result = l.result;
        l.free();
        done.func(done.ctx, result);
        if (done.destroy) |d| d(done.ctx);
    }

    fn cancel(job: *loop_mod.Pool.Job) void {
        const l: *Load = @fieldParentPtr("job", job);
        if (l.result) |img| img.release() else |_| {}
        const done = l.done;
        l.free();
        if (done.destroy) |d| d(done.ctx);
    }

    fn free(l: *Load) void {
        l.gpa.free(l.source);
        l.gpa.destroy(l);
    }
};

fn readFile(gpa: std.mem.Allocator, path: []const u8) Image.LoadError![]u8 {
    const linux = std.os.linux;
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.ReadFailed;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = linux.openat(linux.AT.FDCWD, buf[0..path.len :0], .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true, .TYPE = true }, &st)) != .SUCCESS) return error.ReadFailed;
    if (st.mode & linux.S.IFMT != linux.S.IFREG) return error.ReadFailed;
    if (st.size > max_file) return error.TooLarge;
    const out = try gpa.alloc(u8, @intCast(st.size));
    errdefer gpa.free(out);
    var n: usize = 0;
    while (n < out.len) {
        const r = linux.read(fd, out[n..].ptr, out.len - n);
        switch (linux.errno(r)) {
            .SUCCESS => if (r == 0) break else {
                n += r;
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
    if (n != out.len) return error.ReadFailed;
    return out;
}

test "decoded animations keep their frames; loads run on the pool" {
    const gpa = std.testing.allocator;
    var loop = try loop_mod.Loop.init(gpa);
    defer loop.deinit();
    var pool: loop_mod.Pool = .init(&loop, gpa, 2);
    defer pool.deinit();
    const Rec = struct {
        img: ?*Image = null,
        err: ?Image.LoadError = null,
        destroyed: bool = false,
        fn done(ctx: ?*anyopaque, r: Image.LoadError!*Image) void {
            const rec: *@This() = @ptrCast(@alignCast(ctx));
            if (r) |img| rec.img = img else |e| rec.err = e;
        }
        fn destroy(ctx: ?*anyopaque) void {
            const rec: *@This() = @ptrCast(@alignCast(ctx));
            rec.destroyed = true;
        }
    };
    var rec: Rec = .{};
    // 16 × 16, three frames, shown at scale 2.
    try Image.load(&pool, gpa, .{ .bytes = @embedFile("testdata/anim.gif") }, .{ .scale = 2 }, .{ .ctx = &rec, .func = Rec.done, .destroy = Rec.destroy });
    while (!rec.destroyed) try loop.dispatch(-1);
    const img = rec.img.?;
    defer img.release();
    try std.testing.expectEqual(@as(usize, 3), img.frames.len);
    try std.testing.expectEqual([2]f32{ 8, 8 }, img.logicalSize());
    try std.testing.expect(img.frameRef(1).key != img.frameRef(0).key);
    try std.testing.expectEqual(img.pixels.ptr, img.frameRef(0).pixels);

    var bad: Rec = .{};
    try Image.load(&pool, gpa, .{ .path = "/nonexistent/siv.png" }, .{}, .{ .ctx = &bad, .func = Rec.done, .destroy = Rec.destroy });
    while (!bad.destroyed) try loop.dispatch(-1);
    try std.testing.expectEqual(@as(?Image.LoadError, error.ReadFailed), bad.err);
}


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
