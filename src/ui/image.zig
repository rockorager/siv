//! Images (D2, D9): immutable pixels that siv owns, reference counted.
//!
//! `Image.create` copies the caller's pixels, so the caller may free or
//! reuse them at once. The tree holds a reference for each image node
//! that shows it, and every display list that draws it holds one until
//! the compositor releases the list (`Event.released`), so the pixels
//! outlive every frame that can still read them. The creator's
//! reference is dropped with `release`; the last release frees them.
//!
//! Animations too large to keep decoded (`image.Options.max_bytes`) keep
//! their file instead (`Image.stream`); each image node showing one plays
//! it through a `Player`, which decodes a few frames ahead on the pool.

const std = @import("std");
const scene = @import("scene");
const image_mod = @import("image");
const loop_mod = @import("loop");
const svg = @import("svg");

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
    /// image or a streamed animation.
    frames: []const Frame = &.{},
    /// How many times an animation plays; 0 loops forever.
    loops: u32 = 0,
    /// Frames of the animation, also when streamed.
    frame_count: u32 = 1,
    /// A streamed animation: `pixels` is its first frame, and players
    /// decode the rest from the file.
    stream: ?*Stream = null,
    /// A vector image (an SVG file or icon): drawn from the document at
    /// any size, with no pixels. `width` and `height` are its logical
    /// size, at scale 1.
    vector: ?*svg.Document = null,

    pub const Frame = struct {
        pixels: []align(16) const u8,
        /// How long to show it, in milliseconds.
        delay_ms: u32,
        key: u64,
    };

    /// What a streamed animation plays from.
    pub const Stream = struct {
        /// The file.
        bytes: []u8,
        /// The options it decodes with, the same as its first frame's.
        options: image_mod.Options,
        /// How long the first frame shows, in milliseconds.
        first_delay_ms: u32,
        pool: *loop_mod.Pool,
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
        if (img.vector) |doc| doc.deinit();
        if (img.frames.len == 0 and img.pixels.len != 0) img.gpa.free(img.pixels);
        for (img.frames) |f| img.gpa.free(f.pixels);
        img.gpa.free(img.frames);
        if (img.stream) |st| {
            img.gpa.free(st.bytes);
            img.gpa.destroy(st);
        }
        img.gpa.destroy(img);
    }

    /// Whether image nodes play it.
    pub fn animated(img: *const Image) bool {
        return img.frames.len > 1 or img.stream != null;
    }

    /// A still image taking `pixels` (packed rows, allocated with `gpa`);
    /// they stay the caller's if this fails.
    pub fn fromPixels(gpa: std.mem.Allocator, pixels: []align(16) u8, width: u32, height: u32, format: scene.ImageFormat, scale: f32) error{OutOfMemory}!*Image {
        const img = try gpa.create(Image);
        img.* = .{
            .gpa = gpa,
            .refs = .init(1),
            .pixels = pixels,
            .width = width,
            .height = height,
            .stride = width * format.bytesPerPixel(),
            .format = format,
            .key = next_key.fetchAdd(1, .monotonic),
            .scale = scale,
        };
        return img;
    }

    /// A vector image of `width` × `height` logical pixels taking `doc`,
    /// which stays the caller's if this fails.
    pub fn fromVector(gpa: std.mem.Allocator, doc: *svg.Document, width: f32, height: f32) error{OutOfMemory}!*Image {
        const img = try gpa.create(Image);
        img.* = .{
            .gpa = gpa,
            .refs = .init(1),
            .pixels = &.{},
            .width = @intFromFloat(@max(1, @min(@ceil(width), 1 << 16))),
            .height = @intFromFloat(@max(1, @min(@ceil(height), 1 << 16))),
            .stride = 0,
            .format = .rgba8_srgb,
            .key = next_key.fetchAdd(1, .monotonic),
            .vector = doc,
        };
        return img;
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
            .frame_count = d.frame_count,
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
        /// Order among queued pool jobs: higher first.
        priority: i64 = 0,
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
    /// blocking the loop. The source is copied. The returned load is valid
    /// until `done` runs or it is cancelled.
    pub fn load(pool: *loop_mod.Pool, gpa: std.mem.Allocator, source: Source, options: LoadOptions, done: LoadDone) error{OutOfMemory}!*Loading {
        const l = try gpa.create(Load);
        errdefer gpa.destroy(l);
        const copy = try gpa.dupe(u8, switch (source) {
            inline else => |b| b,
        });
        l.* = .{ .gpa = gpa, .pool = pool, .source = copy, .is_path = source == .path, .options = options, .done = done };
        l.job.priority = options.priority;
        pool.submit(&l.job) catch {
            gpa.free(copy);
            return error.OutOfMemory;
        };
        return l;
    }

    pub const Loading = Load;
};

/// Files larger than this are not images siv decodes.
const max_file = 512 << 20;

const Load = struct {
    job: loop_mod.Pool.Job = .{ .run = run, .done = finish, .cancel = cancelled },
    gpa: std.mem.Allocator,
    pool: *loop_mod.Pool,
    source: []u8,
    is_path: bool,
    options: Image.LoadOptions,
    done: Image.LoadDone,
    result: Image.LoadError!*Image = error.InvalidImage,
    /// Cancelled while decoding: the result is dropped.
    dropped: bool = false,

    /// Stops the load: a queued one never decodes; one being decoded is
    /// dropped when done. Only `done.destroy` runs, now or then.
    pub fn cancel(l: *Load) void {
        if (l.pool.cancel(&l.job)) return cancelled(&l.job);
        l.dropped = true;
    }

    pub fn setPriority(l: *Load, priority: i64) void {
        l.pool.setPriority(&l.job, priority);
    }

    fn run(job: *loop_mod.Pool.Job) void {
        const l: *Load = @fieldParentPtr("job", job);
        l.result = l.decode();
    }

    fn decode(l: *Load) Image.LoadError!*Image {
        var file: ?[]u8 = null;
        defer if (file) |f| l.gpa.free(f);
        if (l.is_path) file = try readFile(l.gpa, l.source);
        const bytes = file orelse l.source;
        if (isSvg(bytes)) {
            // SVG files are vector images at their own size (D19).
            const doc = svg.parse(l.gpa, bytes, .{}) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidSvg => error.InvalidImage,
            };
            errdefer doc.deinit();
            return Image.fromVector(l.gpa, doc, doc.width, doc.height);
        }
        const d = try image_mod.decode(l.gpa, bytes, l.options.decode);
        const streamed = d.streamed;
        const first_delay = d.frames[0].delay_ms;
        const img = try Image.fromDecoded(l.gpa, d, l.options.scale);
        if (streamed) {
            const st = l.gpa.create(Image.Stream) catch |e| {
                img.release();
                return e;
            };
            // The file moves to the stream.
            st.* = .{ .bytes = bytes, .options = l.options.decode, .first_delay_ms = first_delay, .pool = l.pool };
            if (file != null) file = null else l.source = &.{};
            img.stream = st;
        }
        return img;
    }

    fn finish(job: *loop_mod.Pool.Job) void {
        const l: *Load = @fieldParentPtr("job", job);
        if (l.dropped) return cancelled(job);
        const done = l.done;
        const result = l.result;
        l.free();
        done.func(done.ctx, result);
        if (done.destroy) |d| d(done.ctx);
    }

    fn cancelled(job: *loop_mod.Pool.Job) void {
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

/// Whether a file is SVG rather than a raster format: XML whose root
/// element is svg (after an XML declaration, comments, or a DOCTYPE).
pub fn isSvg(bytes: []const u8) bool {
    var s = bytes;
    if (std.mem.startsWith(u8, s, "\xef\xbb\xbf")) s = s[3..];
    s = std.mem.trimStart(u8, s, " \t\r\n");
    if (s.len == 0 or s[0] != '<') return false;
    const head = s[0..@min(s.len, 4096)];
    return std.mem.indexOf(u8, head, "<svg") != null;
}

/// Reads a whole file (on a worker: it blocks).
pub fn readFile(gpa: std.mem.Allocator, path: []const u8) Image.LoadError![]u8 {
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
    _ = try Image.load(&pool, gpa, .{ .bytes = @embedFile("testdata/anim.gif") }, .{ .scale = 2 }, .{ .ctx = &rec, .func = Rec.done, .destroy = Rec.destroy });
    while (!rec.destroyed) try loop.dispatch(-1);
    const img = rec.img.?;
    defer img.release();
    try std.testing.expectEqual(@as(usize, 3), img.frames.len);
    try std.testing.expectEqual([2]f32{ 8, 8 }, img.logicalSize());
    try std.testing.expect(img.frameRef(1).key != img.frameRef(0).key);
    try std.testing.expectEqual(img.pixels.ptr, img.frameRef(0).pixels);

    var bad: Rec = .{};
    _ = try Image.load(&pool, gpa, .{ .path = "/nonexistent/siv.png" }, .{}, .{ .ctx = &bad, .func = Rec.done, .destroy = Rec.destroy });
    while (!bad.destroyed) try loop.dispatch(-1);
    try std.testing.expectEqual(@as(?Image.LoadError, error.ReadFailed), bad.err);
}


/// Plays a streamed animation (`Image.stream`) for one image node: an
/// `image.Decoder` on the worker pool keeps up to `ahead` frames decoded
/// ahead of the one shown. Every frame is an `Image` of its own, so the
/// display lists that draw one keep it alive, and memory stays bounded by
/// them, the frames ahead, and the decoder's canvas, however long the
/// animation. Loop thread only, apart from the decoding job.
pub const Player = struct {
    gpa: std.mem.Allocator,
    image: *Image,
    notify: Notify,
    // The decoding job's, while `busy`.
    decoder: ?image_mod.Decoder = null,
    /// Past the first frame, which `image` itself shows.
    started: bool = false,
    loops_done: u32 = 0,
    result: Result = .none,
    // The loop thread's.
    job: loop_mod.Pool.Job = .{ .run = run, .done = done, .cancel = cancel },
    busy: bool = false,
    /// Destroyed while busy: freed when the job finishes.
    dead: bool = false,
    /// No more frames: the last loop ended, or decoding failed.
    ended: bool = false,
    /// `take` found no frame: `notify` runs when one arrives.
    waiting: bool = false,
    queue: [ahead]Frame = undefined,
    head: usize = 0,
    len: usize = 0,
    /// The frame shown, once past the first.
    current: ?*Image = null,

    pub const ahead = 2;

    pub const Frame = struct { image: *Image, delay_ms: u32 };

    /// Told on the loop thread that a frame `take` waited for arrived, or
    /// that playback ended.
    pub const Notify = struct {
        ctx: *anyopaque,
        id: u32,
        func: *const fn (ctx: *anyopaque, id: u32) void,
    };

    const Result = union(enum) { none, frame: Frame, end };

    /// Starts decoding ahead. `image` must be streamed.
    pub fn create(gpa: std.mem.Allocator, image: *Image, notify: Notify) error{OutOfMemory}!*Player {
        std.debug.assert(image.stream != null);
        const p = try gpa.create(Player);
        p.* = .{ .gpa = gpa, .image = image.retain(), .notify = notify };
        p.fill();
        return p;
    }

    pub fn destroy(p: *Player) void {
        if (p.busy) {
            p.dead = true;
            return;
        }
        p.free();
    }

    fn free(p: *Player) void {
        while (p.len != 0) p.pop().image.release();
        if (p.current) |c| c.release();
        if (p.decoder) |*d| d.deinit();
        p.image.release();
        p.gpa.destroy(p);
    }

    fn pop(p: *Player) Frame {
        const f = p.queue[p.head];
        p.head = (p.head + 1) % ahead;
        p.len -= 1;
        return f;
    }

    /// Shows the next frame and returns how long to, or null if it is not
    /// decoded yet (`notify` follows) or there is none (`ended`).
    pub fn advance(p: *Player) ?u32 {
        if (p.len == 0) {
            p.waiting = !p.ended;
            return null;
        }
        const f = p.pop();
        if (p.current) |c| c.release();
        p.current = f.image;
        p.fill();
        return f.delay_ms;
    }

    fn fill(p: *Player) void {
        if (p.busy or p.ended or p.len + 1 > ahead) return;
        p.busy = true;
        p.image.stream.?.pool.submit(&p.job) catch {
            p.busy = false;
            p.ended = true;
        };
    }

    fn run(job: *loop_mod.Pool.Job) void {
        const p: *Player = @fieldParentPtr("job", job);
        p.result = p.decodeOne() catch .end;
    }

    fn decodeOne(p: *Player) !Result {
        const st = p.image.stream.?;
        if (p.decoder == null) p.decoder = try image_mod.Decoder.init(p.gpa, st.bytes, st.options);
        const d = &p.decoder.?;
        const out = try p.gpa.alignedAlloc(u8, .@"16", d.frameBytes());
        errdefer p.gpa.free(out);
        var rewound = false;
        while (true) {
            if (try d.next(out)) |delay| {
                if (!p.started) {
                    p.started = true;
                    continue;
                }
                const img = try Image.fromPixels(p.gpa, out, d.width, d.height, d.format, p.image.scale);
                return .{ .frame = .{ .image = img, .delay_ms = delay } };
            }
            p.loops_done += 1;
            // The last loop ends on its last frame; a file with no frames
            // after rewinding has nothing to loop.
            if ((p.image.loops != 0 and p.loops_done >= p.image.loops) or rewound) {
                p.gpa.free(out);
                return .end;
            }
            try d.rewind();
            rewound = true;
        }
    }

    fn done(job: *loop_mod.Pool.Job) void {
        const p: *Player = @fieldParentPtr("job", job);
        p.busy = false;
        const result = p.result;
        p.result = .none;
        if (p.dead) {
            if (result == .frame) result.frame.image.release();
            return p.free();
        }
        switch (result) {
            .frame => |f| {
                p.queue[(p.head + p.len) % ahead] = f;
                p.len += 1;
            },
            .end, .none => {
                p.ended = true;
                // The canvas is not needed any more.
                if (p.decoder) |*d| d.deinit();
                p.decoder = null;
            },
        }
        if (p.waiting) {
            p.waiting = false;
            p.notify.func(p.notify.ctx, p.notify.id);
        }
        p.fill();
    }

    fn cancel(job: *loop_mod.Pool.Job) void {
        const p: *Player = @fieldParentPtr("job", job);
        p.busy = false;
        if (p.result == .frame) p.result.frame.image.release();
        p.result = .none;
        p.ended = true;
        if (p.dead) p.free();
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
