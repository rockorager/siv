//! Vulkan renderer tests against the CPU renderer (D24). They need a Vulkan
//! 1.3 device; any is accepted, including lavapipe (mesa-vulkan-drivers),
//! and they are skipped where there is none. With the validation layer
//! installed, any validation error fails them.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const render_cpu = @import("render_cpu");
const pool = @import("pool");
const Device = @import("Device.zig");
const Renderer = @import("Renderer.zig");

const testing = std.testing;
const IRect = raster.IRect;
const Affine = raster.Affine;

fn testDevice() !*Device {
    return @import("vulkan.zig").testDevice(testing.allocator);
}

/// Renders `list` with both renderers and compares them with the golden
/// image tolerance: every channel within 3, at most 0.5% of pixels off by
/// more than 1.
fn expectMatch(r: *Renderer, cpu: *render_cpu.Renderer, list: scene.DisplayList, damage: ?[]const IRect, w: u32, h: u32) !void {
    const gpa = testing.allocator;
    const want = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(got);
    try cpu.render(list, .{ .background = .white, .target = .{ .pixels = want.ptr, .stride = w * 4, .format = .abgr8888 } });
    try r.beginFrame();
    try r.render(list, .{ .background = .white, .damage = damage }, .{ .readback = .{ .pixels = got.ptr, .stride = w * 4 } });
    var worst: u8 = 0;
    var off: usize = 0;
    for (0..w * h) |i| {
        var d: u8 = 0;
        for (0..4) |ch| {
            const a = want[i * 4 + ch];
            const b = got[i * 4 + ch];
            d = @max(d, if (a > b) a - b else b - a);
        }
        worst = @max(worst, d);
        if (d > 1) off += 1;
    }
    if (worst > 3 or off * 200 > w * h) {
        std.debug.print("vulkan vs cpu: max channel difference {d}, {d} pixels off by more than 1\n", .{ worst, off });
        return error.TestExpectedEqual;
    }
}

/// An opaque XRGB8888 image whose ignored fourth byte varies (external
/// video frames, D17).
var bgrx: [8 * 8 * 4]u8 = blk: {
    var px: [8 * 8 * 4]u8 = undefined;
    for (0..64) |i| px[i * 4 ..][0..4].* = .{ @intCast(i * 4), 0x80, @intCast(255 - i * 4), @intCast(i * 37 % 256) };
    break :blk px;
};

fn buildScene(b: *scene.Builder, pb: *raster.PathBuilder, frame: u32) !scene.DisplayList {
    b.reset();
    const f: f32 = @floatFromInt(frame);
    const stops = [_]scene.Stop{
        .{ .offset = 0, .color = scene.Color.srgb8(0x20, 0x60, 0xd0, 0xff) },
        .{ .offset = 1, .color = scene.Color.srgb8(0xf0, 0xa0, 0x30, 0xff) },
    };
    try b.fillRect(.xywh(0, 0, 200, 150), .{ .gradient = .{ .geometry = .{ .linear = .{ .p0 = .zero, .p1 = .{ .x = 200, .y = 150 } } }, .stops = &stops } });
    try b.pushLayer(.{ .id = 1, .version = frame, .transform = .translate(20 + f * 7, 30) });
    try b.shadow(.{ .shape = .{ .rect = .xywh(0, 0, 60, 40), .radii = .uniform(10, 10) }, .offset = .{ .x = 0, .y = 4 }, .sigma = 5, .color = scene.Color.black.withAlpha(0.4) });
    try b.fillRoundedRect(.xywh(0, 0, 60, 40), .uniform(10, 10), .color(.srgb8(0xff, 0xff, 0xff, 0xc0)));
    try b.popLayer();
    try b.pushLayer(.{ .id = 2, .opacity = 0.6, .clip = .{ .shape = .{ .rounded_rect = .{ .rect = .xywh(90, 10, 100, 80), .radii = .uniform(16, 16) } } } });
    pb.reset();
    try pb.moveTo(80, 90);
    try pb.cubicTo(120, -20, 160, 140, 200, 20);
    try b.stroke(.{ .path = pb.path() }, .{ .width = 9, .join = .round, .cap = .round }, .color(.srgb8(0x10, 0x10, 0x10, 0xff)));
    try b.popLayer();
    try b.pushLayer(.{ .id = 4, .blend = .multiply });
    try b.fillRect(.xywh(150, 100, 40, 40), .color(.srgb8(0xff, 0x40, 0x40, 0xff)));
    try b.popLayer();
    try b.image(.{
        .image = .{ .pixels = &bgrx, .width = 8, .height = 8, .stride = 32, .format = .bgrx8_srgb, .key = 7 },
        .src = .xywh(0, 0, 8, 8),
        .dst = .xywh(110, 110, 30, 30),
    });
    try b.pushLayer(.{ .id = 5 });
    try b.backdropBlur(.{ .rounded_rect = .{ .rect = .xywh(10, 95, 90, 45), .radii = .uniform(8, 8) } }, 4);
    try b.fillRect(.xywh(10, 95, 90, 45), .color(.srgb8(0xff, 0xff, 0xff, 0x30)));
    try b.popLayer();
    return b.finish(0);
}

test "frames match the CPU renderer, including damage-only frames" {
    const gpa = testing.allocator;
    const device = try testDevice();
    defer device.destroy();
    const errors = Device.validation_errors.load(.monotonic);
    var tp = pool.Pool.init(gpa, 3);
    defer tp.deinit();
    const r = try Renderer.create(gpa, device, tp.executor());
    defer r.destroy();
    const cpu = try render_cpu.Renderer.create(gpa, .serial);
    defer cpu.destroy();
    try r.resize(200, 150);
    try cpu.resize(200, 150);

    var b0 = scene.Builder.init(gpa);
    defer b0.deinit();
    var b1 = scene.Builder.init(gpa);
    defer b1.deinit();
    var pb = raster.PathBuilder.init(gpa);
    defer pb.deinit();
    var tracker = scene.damage.Tracker.init(gpa);
    defer tracker.deinit();
    const vp = r.viewport();
    var prev = try buildScene(&b0, &pb, 0);
    _ = try tracker.diff(null, prev, .identity, vp);
    try expectMatch(r, cpu, prev, null, 200, 150);
    const builders = [2]*scene.Builder{ &b0, &b1 };
    for (1..4) |frame| {
        const list = try buildScene(builders[frame % 2], &pb, @intCast(frame));
        const damage = try tracker.diff(prev, list, .identity, vp);
        try expectMatch(r, cpu, list, damage, 200, 150);
        prev = list;
    }
    try testing.expectEqual(errors, Device.validation_errors.load(.monotonic));
}

test "dma-buf frames are imported, or skipped without pixels" {
    const gpa = testing.allocator;
    const device = try testDevice();
    defer device.destroy();
    const errors = Device.validation_errors.load(.monotonic);
    const r = try Renderer.create(gpa, device, .serial);
    defer r.destroy();
    try r.resize(40, 30);
    const w = 13;
    const h = 9;
    // A 256-byte aligned layout, which drivers with explicit modifiers
    // import as an image, and a decoder's odd stride and offset, which
    // RADV's image path rejects and a buffer copy takes.
    for ([_][2]u32{ .{ 256, 256 }, .{ 64, 128 } }, 0..) |layout, n| {
        const stride, const offset = layout;
        const mem = try gpa.alloc(u8, offset + stride * h);
        defer gpa.free(mem);
        @memset(mem, 0xee);
        for (0..h) |y| for (0..w) |x| {
            mem[offset + y * stride + x * 4 ..][0..4].* = .{ @intCast(x * 19), @intCast(y * 27), @intCast(255 - x * 7), 0x11 };
        };
        // A real dma-buf over a memfd where /dev/udmabuf opens; otherwise
        // the memfd stands in, which only CPU implementations (lavapipe,
        // which maps what it imports) accept.
        const udmabuf = udmabufFrom(mem);
        if (udmabuf == null and device.dmabuf_import and device.device_type != @import("vk.zig").c.VK_PHYSICAL_DEVICE_TYPE_CPU) return error.SkipZigTest;
        const fd = udmabuf orelse fd: {
            const memfd = try std.posix.memfd_create("siv-dmabuf", 0);
            if (std.c.pwrite(memfd, mem.ptr, mem.len, 0) != mem.len) return error.Unexpected;
            break :fd memfd;
        };
        defer _ = std.c.close(fd);
        var buf: scene.Dmabuf = .{ .format = scene.Dmabuf.xrgb8888, .modifier = scene.Dmabuf.modifier_linear, .plane_count = 1 };
        buf.planes[0] = .{ .fd = fd, .offset = offset, .stride = stride };

        var b = scene.Builder.init(gpa);
        defer b.deinit();
        const want = try gpa.alloc(u8, 40 * 30 * 4);
        defer gpa.free(want);
        const got = try gpa.alloc(u8, 40 * 30 * 4);
        defer gpa.free(got);
        // The same frame from its pixels, then from the dma-buf alone.
        for ([_]?[*]const u8{ mem.ptr + offset, null }, [_]u64{ 1, 2 }, [_][]u8{ want, got }) |pixels, key, out| {
            b.reset();
            try b.image(.{
                .image = .{ .pixels = pixels, .width = w, .height = h, .stride = stride, .format = .bgrx8_srgb, .key = key + 2 * n, .dmabuf = if (pixels == null) &buf else null },
                .src = .xywh(0, 0, w, h),
                .dst = .xywh(3, 2, w, h),
                .filter = .nearest,
            });
            try r.beginFrame();
            try r.render(try b.finish(0), .{ .background = .white }, .{ .readback = .{ .pixels = out.ptr, .stride = 40 * 4 } });
        }
        if (device.dmabuf_import) {
            try testing.expectEqualSlices(u8, want, got);
        } else {
            // Not drawn: the background only.
            for (0..40 * 30) |i| try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, got[i * 4 ..][0..4]);
            try testing.expect(r.dmabuf_skipped);
        }
    }
    try testing.expectEqual(errors, Device.validation_errors.load(.monotonic));
}

/// A dma-buf holding `bytes` (udmabuf over a sealed memfd), or null where
/// /dev/udmabuf is missing or not accessible.
fn udmabufFrom(bytes: []const u8) ?std.posix.fd_t {
    const linux = std.os.linux;
    const size = std.mem.alignForward(usize, bytes.len, std.heap.page_size_min);
    const memfd_rc = linux.memfd_create("siv-udmabuf", linux.MFD.ALLOW_SEALING | linux.MFD.CLOEXEC);
    if (linux.errno(memfd_rc) != .SUCCESS) return null;
    const memfd: i32 = @intCast(memfd_rc);
    defer _ = linux.close(memfd);
    if (linux.ftruncate(memfd, @intCast(size)) != 0) return null;
    if (std.c.pwrite(memfd, bytes.ptr, bytes.len, 0) != bytes.len) return null;
    if (linux.fcntl(memfd, linux.F.ADD_SEALS, linux.F.SEAL_SHRINK) != 0) return null;
    const dev_rc = linux.open("/dev/udmabuf", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(dev_rc) != .SUCCESS) return null;
    const dev: i32 = @intCast(dev_rc);
    defer _ = linux.close(dev);
    const Create = extern struct { memfd: u32, flags: u32, offset: u64, size: u64 };
    var create: Create = .{ .memfd = @intCast(memfd), .flags = 1, .offset = 0, .size = size }; // UDMABUF_FLAGS_CLOEXEC
    const rc = linux.ioctl(dev, 0x40187542, @intFromPtr(&create)); // UDMABUF_CREATE: _IOW('u', 0x42, Create)
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

test "device selection matches dma-buf feedback device numbers" {
    // dev_t 226:128 (/dev/dri/renderD128) in the Linux encoding.
    const dev: u64 = (226 << 8) | 128;
    var dp: @import("vk.zig").c.VkPhysicalDeviceDrmPropertiesEXT = .{ .hasRender = 1, .renderMajor = 226, .renderMinor = 128 };
    try testing.expect(Device.matchesDevice(dp, dev));
    dp.renderMinor = 129;
    try testing.expect(!Device.matchesDevice(dp, dev));
    // Large minors use the high bits.
    const big: u64 = (226 << 8) | (0x12345 & 0xff) | ((0x12345 & ~@as(u64, 0xff)) << 12);
    dp.renderMinor = 0x12345;
    try testing.expect(Device.matchesDevice(dp, big));
}

test "the pipeline cache persists across devices, and how much it saves" {
    const gpa = testing.allocator;
    // A probe for a device at all.
    (try testDevice()).destroy();
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/siv-pipeline-cache-{d}", .{std.c.getpid()});
    defer {
        var cmd_buf: [96]u8 = undefined;
        const cmd = std.fmt.bufPrintSentinel(&cmd_buf, "rm -rf {s}", .{dir}, 0) catch unreachable;
        _ = system(cmd);
    }
    var times: [3]u64 = undefined;
    var loaded: [3]usize = undefined;
    for ([_]Device.PipelineCache{ .none, .{ .dir = dir }, .{ .dir = dir } }, 0..) |cache, i| {
        const t0 = now();
        const d = try Device.create(gpa, .{ .allow_cpu = true, .pipeline_cache = cache });
        times[i] = now() - t0;
        loaded[i] = d.cache_loaded;
        d.destroy();
    }
    if (testing.environ.getPosix("SIV_MEASURE") != null) std.debug.print("device creation: {d:.1} ms without a cache, {d:.1} ms cold, {d:.1} ms warm ({d} bytes)\n", .{
        @as(f64, @floatFromInt(times[0])) / 1e6, @as(f64, @floatFromInt(times[1])) / 1e6, @as(f64, @floatFromInt(times[2])) / 1e6, loaded[2],
    });
    try testing.expectEqual(@as(usize, 0), loaded[1]);
    try testing.expect(loaded[2] > 0);
}

extern "c" fn system(cmd: [*:0]const u8) c_int;

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
