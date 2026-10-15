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
    // Mask pages fit the paths (a stroke under 130 px across): fixed
    // 2048 px pages, two layers for each frame in flight, were 16 MiB of
    // VRAM for one text field's border.
    var masked = false;
    for (r.frames) |f| {
        masked = masked or f.masks.width > 16;
        try testing.expect(f.masks.width <= 256 and f.masks.height <= 256);
    }
    try testing.expect(masked);
    try testing.expectEqual(errors, Device.validation_errors.load(.monotonic));
}

test "draws under later opaque ones get holes, borders are bands, and frames still match the CPU" {
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
    var b = scene.Builder.init(gpa);
    defer b.deinit();
    for (0..3) |frame| {
        b.reset();
        const f: f32 = @floatFromInt(frame);
        // A window's background, a view's rounded background and clip
        // over most of it, its border, and rows; then an opaque panel
        // over a gradient and a faded layer.
        try b.fillRect(.xywh(0, 0, 200, 150), .color(.srgb8(0xf0, 0xf0, 0xf0, 0xff)));
        const view: scene.Shape = .{ .rounded_rect = .{ .rect = .xywh(6.5, 5.25, 187, 139.5), .radii = .uniform(8, 8) } };
        try b.pushLayer(.{ .clip = .{ .shape = view } });
        try b.fill(view, .nonzero, .color(.white));
        for (0..6) |i| try b.fillRect(.xywh(10, 10 + @as(f32, @floatFromInt(i)) * 22 - f * 5, 120, 14), .color(.srgb8(0x30, 0x30, 0x40, 0xff)));
        try b.popLayer();
        try b.stroke(view, .{ .width = 1 }, .color(.srgb8(0x80, 0x80, 0x90, 0xff)));
        const stops = [_]scene.Stop{
            .{ .offset = 0, .color = scene.Color.srgb8(0x20, 0x60, 0xd0, 0xff) },
            .{ .offset = 1, .color = scene.Color.srgb8(0xf0, 0xa0, 0x30, 0xff) },
        };
        try b.fillRect(.xywh(140, 20, 50, 60), .{ .gradient = .{ .geometry = .{ .linear = .{ .p0 = .{ .x = 140, .y = 20 }, .p1 = .{ .x = 190, .y = 80 } } }, .stops = &stops } });
        try b.fillRect(.xywh(138, 18, 54, 64), .color(.srgb8(0x10, 0x80, 0x40, 0xff)));
        try b.pushLayer(.{ .opacity = 0.5 });
        try b.fillRect(.xywh(150, 90, 30, 30), .color(.srgb8(0xff, 0x20, 0x20, 0xff)));
        try b.fillRect(.xywh(160, 100, 30, 30), .color(.srgb8(0x20, 0x20, 0xff, 0xff)));
        try b.popLayer();
        const list = try b.finish(0);
        try expectMatch(r, cpu, list, if (frame == 0) null else &.{.xywh(0, 0, 200, 150)}, 200, 150);
        // The background and the gradient under the panel are holes (or
        // nothing at all).
        var holed: usize = 0;
        for (r.insts.items) |inst| {
            const q = inst.quad;
            if (q[2] <= q[0] or inst.hole[2] > inst.hole[0]) holed += 1;
        }
        try testing.expect(holed >= 2);
        // Both draw pipelines drew part of it: the specialized one the
        // rows and backgrounds, the full one the gradient and the border.
        var simple: usize = 0;
        for (r.insts.items) |inst| simple += @intFromBool(r.simpleDraw(inst));
        try testing.expect(simple >= 6 and simple < r.insts.items.len);
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
    // A device that cannot import warns that the frame is not drawn. The
    // warning is expected here, and `zig build` shows a passing test's
    // output under "failed command:".
    const level = testing.log_level;
    if (!device.dmabuf_import) testing.log_level = .err;
    defer testing.log_level = level;
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

test "tiled dma-bufs are imported with their explicit modifier" {
    try tiledRoundTrip(false);
}

test "tiled dma-bufs with compression planes are imported with every plane's layout" {
    // AMD's DCC: GL and Vulkan producers' XRGB8888 on RADV is two or three
    // memory planes in one dma-buf (D17). Skipped where the device offers
    // no such modifier (lavapipe).
    try tiledRoundTrip(true);
}

/// A producer's image with a tiled modifier (one memory plane, or more
/// for `multi`), exported and imported as a dma-buf frame, renders as its
/// pixels do.
fn tiledRoundTrip(multi: bool) !void {
    const vk = @import("vk.zig");
    const c = vk.c;
    const gpa = testing.allocator;
    const device = try testDevice();
    defer device.destroy();
    if (!device.drm_modifiers) return error.SkipZigTest;
    const errors = Device.validation_errors.load(.monotonic);
    const d = device;
    const fmt = c.VK_FORMAT_B8G8R8A8_UNORM;
    const w = 37;
    const h = 23;

    // A single-plane tiled modifier the device can export, as a producer
    // on this GPU would use.
    var mods: [64]c.VkDrmFormatModifierPropertiesEXT = undefined;
    var list: c.VkDrmFormatModifierPropertiesListEXT = .{ .sType = c.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT, .drmFormatModifierCount = mods.len, .pDrmFormatModifierProperties = &mods };
    var fp: c.VkFormatProperties2 = .{ .sType = c.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2, .pNext = &list };
    d.vki.vkGetPhysicalDeviceFormatProperties2.?(d.physical, fmt, &fp);
    const transfer = c.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
    const modifier = for (mods[0..@min(list.drmFormatModifierCount, mods.len)]) |m| {
        if (m.drmFormatModifier != scene.Dmabuf.modifier_linear and (m.drmFormatModifierPlaneCount > 1) == multi and m.drmFormatModifierTilingFeatures & transfer == transfer) break m.drmFormatModifier;
    } else return error.SkipZigTest;

    // The producer's image, exported as a dma-buf.
    const mod_list: c.VkImageDrmFormatModifierListCreateInfoEXT = .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT, .drmFormatModifierCount = 1, .pDrmFormatModifiers = &modifier };
    const external: c.VkExternalMemoryImageCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, .pNext = &mod_list, .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
    var image: c.VkImage = null;
    try vk.call(d.vkd.vkCreateImage, .{ d.device, &c.VkImageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &external,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = fmt,
        .extent = .{ .width = w, .height = h, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    }, null, &image });
    defer d.vkd.vkDestroyImage.?(d.device, image, null);
    var reqs: c.VkMemoryRequirements = undefined;
    d.vkd.vkGetImageMemoryRequirements.?(d.device, image, &reqs);
    const dedicated: c.VkMemoryDedicatedAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .image = image };
    const export_info: c.VkExportMemoryAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO, .pNext = &dedicated, .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
    var memory: c.VkDeviceMemory = null;
    try vk.call(d.vkd.vkAllocateMemory, .{ d.device, &c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &export_info, .allocationSize = reqs.size, .memoryTypeIndex = @ctz(reqs.memoryTypeBits) }, null, &memory });
    defer d.vkd.vkFreeMemory.?(d.device, memory, null);
    try vk.call(d.vkd.vkBindImageMemory, .{ d.device, image, memory, 0 });

    // Filled from a pattern by a copy, then released to the foreign queue.
    const pixels = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(pixels);
    for (0..h) |y| for (0..w) |x| {
        pixels[(y * w + x) * 4 ..][0..4].* = .{ @intCast(x * 6), @intCast(y * 11), @intCast(255 - x * 5), 0x22 };
    };
    var staging = try Device.Buffer.init(d, pixels.len, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    defer staging.deinit(d);
    @memcpy(staging.mapped.?[0..pixels.len], pixels);
    var pool_handle: c.VkCommandPool = null;
    try vk.call(d.vkd.vkCreateCommandPool, .{ d.device, &c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = d.queue_family }, null, &pool_handle });
    defer d.vkd.vkDestroyCommandPool.?(d.device, pool_handle, null);
    var cmd: c.VkCommandBuffer = null;
    try vk.call(d.vkd.vkAllocateCommandBuffers, .{ d.device, &c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool_handle, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 }, &cmd });
    try vk.call(d.vkd.vkBeginCommandBuffer, .{ cmd, &c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO } });
    var barrier: c.VkImageMemoryBarrier2 = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .dstStageMask = c.VK_PIPELINE_STAGE_2_COPY_BIT,
        .dstAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = Device.color_range,
    };
    d.vkd.vkCmdPipelineBarrier2.?(cmd, &c.VkDependencyInfo{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &barrier });
    d.vkd.vkCmdCopyBufferToImage.?(cmd, staging.handle, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &c.VkBufferImageCopy{ .imageSubresource = Device.color_layers, .imageExtent = .{ .width = w, .height = h, .depth = 1 } });
    barrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = c.VK_PIPELINE_STAGE_2_COPY_BIT,
        .srcAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = d.queue_family,
        .dstQueueFamilyIndex = if (d.queue_foreign) c.VK_QUEUE_FAMILY_FOREIGN_EXT else c.VK_QUEUE_FAMILY_EXTERNAL,
        .image = image,
        .subresourceRange = Device.color_range,
    };
    d.vkd.vkCmdPipelineBarrier2.?(cmd, &c.VkDependencyInfo{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &barrier });
    try vk.call(d.vkd.vkEndCommandBuffer, .{cmd});
    const cmd_info: c.VkCommandBufferSubmitInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .commandBuffer = cmd };
    try vk.call(d.vkd.vkQueueSubmit2, .{ d.queue, 1, &c.VkSubmitInfo2{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2, .commandBufferInfoCount = 1, .pCommandBufferInfos = &cmd_info }, null });
    try vk.call(d.vkd.vkDeviceWaitIdle, .{d.device});

    // What a producer sends: the fd, the modifier, and the plane layout.
    const get_fd: c.PFN_vkGetMemoryFdKHR = @ptrCast(d.vki.vkGetDeviceProcAddr.?(d.device, "vkGetMemoryFdKHR"));
    const get_modifier: c.PFN_vkGetImageDrmFormatModifierPropertiesEXT = @ptrCast(d.vki.vkGetDeviceProcAddr.?(d.device, "vkGetImageDrmFormatModifierPropertiesEXT"));
    var fd: c_int = -1;
    try vk.call(get_fd, .{ d.device, &c.VkMemoryGetFdInfoKHR{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR, .memory = memory, .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT }, &fd });
    defer _ = std.c.close(fd);
    var mod_props: c.VkImageDrmFormatModifierPropertiesEXT = .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT };
    try vk.call(get_modifier, .{ d.device, image, &mod_props });
    const get_layout: c.PFN_vkGetImageSubresourceLayout = @ptrCast(d.vki.vkGetDeviceProcAddr.?(d.device, "vkGetImageSubresourceLayout"));
    const plane_count: u32 = for (mods[0..@min(list.drmFormatModifierCount, mods.len)]) |m| {
        if (m.drmFormatModifier == mod_props.drmFormatModifier) break m.drmFormatModifierPlaneCount;
    } else 1;
    var buf: scene.Dmabuf = .{ .format = scene.Dmabuf.xrgb8888, .modifier = mod_props.drmFormatModifier, .plane_count = @intCast(plane_count) };
    const aspects = [_]u32{ c.VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT, c.VK_IMAGE_ASPECT_MEMORY_PLANE_1_BIT_EXT, c.VK_IMAGE_ASPECT_MEMORY_PLANE_2_BIT_EXT, c.VK_IMAGE_ASPECT_MEMORY_PLANE_3_BIT_EXT };
    for (0..plane_count) |i| {
        var layout: c.VkSubresourceLayout = undefined;
        get_layout.?(d.device, image, &c.VkImageSubresource{ .aspectMask = aspects[i] }, &layout);
        buf.planes[i] = .{ .fd = fd, .offset = @intCast(layout.offset), .stride = @intCast(layout.rowPitch) };
    }

    const r = try Renderer.create(gpa, d, .serial);
    defer r.destroy();
    try r.resize(50, 30);
    var b = scene.Builder.init(gpa);
    defer b.deinit();
    const want = try gpa.alloc(u8, 50 * 30 * 4);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, 50 * 30 * 4);
    defer gpa.free(got);
    for ([_]?[*]const u8{ pixels.ptr, null }, [_]u64{ 1, 2 }, [_][]u8{ want, got }) |px, key, out| {
        b.reset();
        try b.image(.{
            .image = .{ .pixels = px, .width = w, .height = h, .stride = w * 4, .format = .bgrx8_srgb, .key = key, .dmabuf = if (px == null) &buf else null },
            .src = .xywh(0, 0, w, h),
            .dst = .xywh(5, 4, w, h),
            .filter = .nearest,
        });
        try r.beginFrame();
        try r.render(try b.finish(0), .{ .background = .white }, .{ .readback = .{ .pixels = out.ptr, .stride = 50 * 4 } });
    }
    try testing.expect(!r.dmabuf_skipped);
    try testing.expectEqualSlices(u8, want, got);
    try testing.expectEqual(errors, Device.validation_errors.load(.monotonic));
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
    var times: [2]u64 = undefined;
    var loaded: [2]usize = undefined;
    for (&times, &loaded) |*t, *l| {
        const t0 = now();
        const d = try Device.create(gpa, .{ .allow_cpu = true, .pipeline_cache = .{ .dir = dir } });
        t.* = now() - t0;
        l.* = d.cache_loaded;
        d.destroy();
    }
    if (testing.environ.getPosix("SIV_MEASURE") != null) std.debug.print("device creation: {d:.1} ms cold, {d:.1} ms warm ({d} bytes)\n", .{
        @as(f64, @floatFromInt(times[0])) / 1e6, @as(f64, @floatFromInt(times[1])) / 1e6, loaded[1],
    });
    try testing.expectEqual(@as(usize, 0), loaded[0]);
    try testing.expect(loaded[1] > 0);
}

extern "c" fn system(cmd: [*:0]const u8) c_int;

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "the committed SPIR-V was compiled from the GLSL beside it" {
    // `zig build shaders` writes glsl.sha256 with the SPIR-V; a GLSL edit
    // without it would leave the SPIR-V stale (D10).
    const shaders = @import("shaders");
    var checked: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, shaders.glsl_sha256, '\n');
    while (lines.next()) |line| : (checked += 1) {
        const name = line[66..];
        for (shaders.glsl) |file| {
            if (!std.mem.eql(u8, file.name, name)) continue;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(file.text, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, &hex, line[0..64])) {
                std.log.err("{s} changed since its SPIR-V was compiled; run `zig build shaders`", .{name});
                return error.StaleSpirv;
            }
            break;
        } else return error.UnknownShaderSource;
    }
    try testing.expectEqual(shaders.glsl.len, checked);
}
