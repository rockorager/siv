//! dma-buf import (D10, D17): external frames that the compositor cannot
//! promote to a subsurface are composited from a texture, filled by
//! importing the producer's dma-buf and copying it on the GPU.
//!
//! The copy is submitted on its own and waited for before the texture is
//! used, so the dma-buf is never read after `copy` returns: the producer
//! gets it back on the usual schedule (D17), and no frame in flight holds
//! the import. The compositor shows a dma-buf frame only once its implicit
//! fences have signaled, so the copy needs no semaphore.
//!
//! Two ways in, by what the device offers:
//!   - VK_EXT_image_drm_format_modifier: the dma-buf becomes a VkImage with
//!     its explicit modifier and plane layout (tiled or linear), copied
//!     with vkCmdCopyImage.
//!   - Otherwise, linear dma-bufs only: the memory becomes a VkBuffer,
//!     copied with vkCmdCopyBufferToImage at the frame's stride.
//! Both acquire the memory from the foreign queue family
//! (VK_EXT_queue_family_foreign, else VK_QUEUE_FAMILY_EXTERNAL).

const std = @import("std");
const linux = std.os.linux;
const scene = @import("scene");
const vk = @import("vk.zig");
const c = vk.c;
const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

pub const Error = vk.Error || error{
    /// This device cannot import this dma-buf (format, modifier, or
    /// layout); the caller falls back to the pixels if it has them.
    Unsupported,
};

/// The Vulkan format that holds a DRM format's bytes, if siv composites
/// it. Opaque XRGB8888 only for now, like shared-memory frames.
pub fn format(drm: u32) ?c.VkFormat {
    return if (drm == scene.Dmabuf.xrgb8888) c.VK_FORMAT_B8G8R8A8_UNORM else null;
}

/// One-shot transfer objects, created on first use.
pub const Importer = struct {
    pool: c.VkCommandPool = null,
    cmd: c.VkCommandBuffer = null,
    fence: c.VkFence = null,

    pub fn deinit(im: *Importer, d: *Device) void {
        if (im.fence != null) d.vkd.vkDestroyFence.?(d.device, im.fence, null);
        if (im.pool != null) d.vkd.vkDestroyCommandPool.?(d.device, im.pool, null);
        im.* = .{};
    }

    fn ensure(im: *Importer, d: *Device) vk.Error!void {
        if (im.pool != null) return;
        errdefer im.deinit(d);
        try vk.call(d.vkd.vkCreateCommandPool, .{ d.device, &c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
            .queueFamilyIndex = d.queue_family,
        }, null, &im.pool });
        try vk.call(d.vkd.vkAllocateCommandBuffers, .{ d.device, &c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = im.pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        }, &im.cmd });
        try vk.call(d.vkd.vkCreateFence, .{ d.device, &c.VkFenceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO }, null, &im.fence });
    }

    /// Copies `buf` (`width` × `height`) into `dst`, which must have its
    /// format and TRANSFER_DST usage, and leaves `dst` ready to sample.
    pub fn copy(im: *Importer, d: *Device, buf: *const scene.Dmabuf, width: u32, height: u32, dst: *Device.Image) Error!void {
        if (!d.dmabuf_import) return error.Unsupported;
        const fmt = format(buf.format) orelse return error.Unsupported;
        if (buf.plane_count != 1 or fmt != dst.format) return error.Unsupported;
        try im.ensure(d);
        var src: Source = .{};
        defer src.deinit(d);
        if (d.drm_modifiers and buf.modifier != scene.Dmabuf.modifier_invalid) {
            src.importImage(d, buf, fmt, width, height) catch |e| {
                // Drivers reject linear images whose stride or offset
                // breaks their alignment (RADV wants 256 bytes); a buffer
                // copy takes any whole-pixel layout.
                if (e != error.Unsupported or buf.modifier != scene.Dmabuf.modifier_linear) return e;
                src.deinit(d);
                try src.importBuffer(d, buf, width, height);
            };
        } else if (buf.modifier == scene.Dmabuf.modifier_linear) {
            try src.importBuffer(d, buf, width, height);
        } else return error.Unsupported;
        try im.record(d, &src, buf, width, height, dst);
        const cmd_info: c.VkCommandBufferSubmitInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .commandBuffer = im.cmd };
        const submit: c.VkSubmitInfo2 = .{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2, .commandBufferInfoCount = 1, .pCommandBufferInfos = &cmd_info };
        vk.check(d.vkd.vkQueueSubmit2.?(d.queue, 1, &submit, im.fence)) catch |e| return d.note(e);
        vk.check(d.vkd.vkWaitForFences.?(d.device, 1, &im.fence, c.VK_TRUE, std.math.maxInt(u64))) catch |e| return d.note(e);
        vk.check(d.vkd.vkResetFences.?(d.device, 1, &im.fence)) catch |e| return d.note(e);
        dst.layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    }

    fn record(im: *Importer, d: *Device, src: *const Source, buf: *const scene.Dmabuf, width: u32, height: u32, dst: *Device.Image) vk.Error!void {
        const k = &d.vkd;
        const cmd = im.cmd;
        try vk.call(k.vkResetCommandPool, .{ d.device, im.pool, 0 });
        try vk.call(k.vkBeginCommandBuffer, .{ cmd, &c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT } });
        const foreign: u32 = if (d.queue_foreign) c.VK_QUEUE_FAMILY_FOREIGN_EXT else c.VK_QUEUE_FAMILY_EXTERNAL;
        // Acquire the producer's memory, and make `dst` writable.
        var images: [2]c.VkImageMemoryBarrier2 = undefined;
        var n_images: u32 = 0;
        images[n_images] = imageBarrier(dst.handle, dst.layout, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_QUEUE_FAMILY_IGNORED, c.VK_QUEUE_FAMILY_IGNORED);
        n_images += 1;
        var buffer_barrier: c.VkBufferMemoryBarrier2 = undefined;
        var n_buffers: u32 = 0;
        if (src.image != null) {
            // Foreign images are by convention in the GENERAL layout.
            images[n_images] = imageBarrier(src.image, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, foreign, d.queue_family);
            n_images += 1;
        } else {
            buffer_barrier = .{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2,
                .srcStageMask = c.VK_PIPELINE_STAGE_2_NONE,
                .srcAccessMask = c.VK_ACCESS_2_NONE,
                .dstStageMask = c.VK_PIPELINE_STAGE_2_COPY_BIT,
                .dstAccessMask = c.VK_ACCESS_2_TRANSFER_READ_BIT,
                .srcQueueFamilyIndex = foreign,
                .dstQueueFamilyIndex = d.queue_family,
                .buffer = src.buffer,
                .offset = 0,
                .size = c.VK_WHOLE_SIZE,
            };
            n_buffers = 1;
        }
        k.vkCmdPipelineBarrier2.?(cmd, &c.VkDependencyInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .bufferMemoryBarrierCount = n_buffers,
            .pBufferMemoryBarriers = &buffer_barrier,
            .imageMemoryBarrierCount = n_images,
            .pImageMemoryBarriers = &images,
        });
        const extent: c.VkExtent3D = .{ .width = width, .height = height, .depth = 1 };
        if (src.image != null) {
            const region: c.VkImageCopy = .{ .srcSubresource = Device.color_layers, .dstSubresource = Device.color_layers, .extent = extent };
            k.vkCmdCopyImage.?(cmd, src.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dst.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        } else {
            const region: c.VkBufferImageCopy = .{
                .bufferOffset = buf.planes[0].offset,
                .bufferRowLength = buf.planes[0].stride / 4,
                .imageSubresource = Device.color_layers,
                .imageExtent = extent,
            };
            k.vkCmdCopyBufferToImage.?(cmd, src.buffer, dst.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        }
        // The producer gets its memory back once the fence passes (nothing
        // is released back to its queue family: it never reads siv's
        // writes, and the import is destroyed right after).
        const ready = imageBarrier(dst.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, c.VK_QUEUE_FAMILY_IGNORED, c.VK_QUEUE_FAMILY_IGNORED);
        k.vkCmdPipelineBarrier2.?(cmd, &c.VkDependencyInfo{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &ready });
        try vk.call(k.vkEndCommandBuffer, .{cmd});
    }
};

fn imageBarrier(image: c.VkImage, old: c.VkImageLayout, new: c.VkImageLayout, src_family: u32, dst_family: u32) c.VkImageMemoryBarrier2 {
    return .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .srcAccessMask = c.VK_ACCESS_2_MEMORY_WRITE_BIT,
        .dstStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .dstAccessMask = c.VK_ACCESS_2_MEMORY_READ_BIT | c.VK_ACCESS_2_MEMORY_WRITE_BIT,
        .oldLayout = old,
        .newLayout = new,
        .srcQueueFamilyIndex = src_family,
        .dstQueueFamilyIndex = dst_family,
        .image = image,
        .subresourceRange = Device.color_range,
    };
}

/// The imported dma-buf: an image or a buffer, and its memory.
const Source = struct {
    image: c.VkImage = null,
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,

    fn deinit(s: *Source, d: *Device) void {
        if (s.image != null) d.vkd.vkDestroyImage.?(d.device, s.image, null);
        if (s.buffer != null) d.vkd.vkDestroyBuffer.?(d.device, s.buffer, null);
        if (s.memory != null) d.vkd.vkFreeMemory.?(d.device, s.memory, null);
        s.* = .{};
    }

    fn importImage(s: *Source, d: *Device, buf: *const scene.Dmabuf, fmt: c.VkFormat, width: u32, height: u32) Error!void {
        const plane = buf.planes[0];
        if (!modifierSupported(d, fmt, buf.modifier)) return error.Unsupported;
        const layout: c.VkSubresourceLayout = .{ .offset = plane.offset, .rowPitch = plane.stride };
        const explicit: c.VkImageDrmFormatModifierExplicitCreateInfoEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
            .drmFormatModifier = buf.modifier,
            .drmFormatModifierPlaneCount = 1,
            .pPlaneLayouts = &layout,
        };
        const external: c.VkExternalMemoryImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .pNext = &explicit,
            .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        vk.call(d.vkd.vkCreateImage, .{ d.device, &c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &external,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = fmt,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            .usage = c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        }, null, &s.image }) catch |e| return unsupported(e);
        var reqs: c.VkMemoryRequirements = undefined;
        d.vkd.vkGetImageMemoryRequirements.?(d.device, s.image, &reqs);
        s.memory = try importMemory(d, plane.fd, reqs, s.image, null);
        vk.call(d.vkd.vkBindImageMemory, .{ d.device, s.image, s.memory, 0 }) catch |e| return unsupported(e);
    }

    fn importBuffer(s: *Source, d: *Device, buf: *const scene.Dmabuf, width: u32, height: u32) Error!void {
        const plane = buf.planes[0];
        // Copies address texels: whole 4-byte pixels.
        if (plane.stride % 4 != 0 or plane.offset % 4 != 0 or plane.stride < width * 4) return error.Unsupported;
        const size = @as(u64, plane.offset) + @as(u64, plane.stride) * (height - 1) + @as(u64, width) * 4;
        const external: c.VkExternalMemoryBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
            .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        vk.call(d.vkd.vkCreateBuffer, .{ d.device, &c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = &external,
            .size = size,
            .usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        }, null, &s.buffer }) catch |e| return unsupported(e);
        var reqs: c.VkMemoryRequirements = undefined;
        d.vkd.vkGetBufferMemoryRequirements.?(d.device, s.buffer, &reqs);
        s.memory = try importMemory(d, plane.fd, reqs, null, s.buffer);
        vk.call(d.vkd.vkBindBufferMemory, .{ d.device, s.buffer, s.memory, 0 }) catch |e| return unsupported(e);
    }
};

/// Whether the device can copy from an image of `fmt` with `modifier`.
fn modifierSupported(d: *Device, fmt: c.VkFormat, modifier: u64) bool {
    const k = &d.vki;
    var mods: [64]c.VkDrmFormatModifierPropertiesEXT = undefined;
    var list: c.VkDrmFormatModifierPropertiesListEXT = .{ .sType = c.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT, .drmFormatModifierCount = mods.len, .pDrmFormatModifierProperties = &mods };
    var fp: c.VkFormatProperties2 = .{ .sType = c.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2, .pNext = &list };
    k.vkGetPhysicalDeviceFormatProperties2.?(d.physical, fmt, &fp);
    const found = for (mods[0..@min(list.drmFormatModifierCount, mods.len)]) |m| {
        if (m.drmFormatModifier == modifier) break m;
    } else return false;
    if (found.drmFormatModifierPlaneCount != 1 or found.drmFormatModifierTilingFeatures & c.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT == 0) return false;
    // And importable as a dma-buf.
    var mod_info: c.VkPhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
        .drmFormatModifier = modifier,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };
    var ext_info: c.VkPhysicalDeviceExternalImageFormatInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
        .pNext = &mod_info,
        .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    const info: c.VkPhysicalDeviceImageFormatInfo2 = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .pNext = &ext_info,
        .format = fmt,
        .type = c.VK_IMAGE_TYPE_2D,
        .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
    };
    var ext_props: c.VkExternalImageFormatProperties = .{ .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES };
    var props: c.VkImageFormatProperties2 = .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2, .pNext = &ext_props };
    if (k.vkGetPhysicalDeviceImageFormatProperties2.?(d.physical, &info, &props) != c.VK_SUCCESS) return false;
    return ext_props.externalMemoryProperties.externalMemoryFeatures & c.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT != 0;
}

/// Imports a duplicate of `fd` as memory for `image` or `buffer`
/// (dedicated, as dma-buf imports want).
fn importMemory(d: *Device, fd: i32, reqs: c.VkMemoryRequirements, image: c.VkImage, buffer: c.VkBuffer) Error!c.VkDeviceMemory {
    var fd_props: c.VkMemoryFdPropertiesKHR = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR };
    if (d.vkd.vkGetMemoryFdPropertiesKHR.?(d.device, c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, fd, &fd_props) != c.VK_SUCCESS) return error.Unsupported;
    const bits = reqs.memoryTypeBits & fd_props.memoryTypeBits;
    if (bits == 0) return error.Unsupported;
    // A dma-buf smaller than the copy would read past its end.
    const end = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(end) == .SUCCESS and end < reqs.size) return error.Unsupported;
    const dup = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
    if (linux.errno(dup) != .SUCCESS) return error.OutOfMemory;
    const dedicated: c.VkMemoryDedicatedAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .image = image, .buffer = buffer };
    const import: c.VkImportMemoryFdInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
        .pNext = &dedicated,
        .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        .fd = @intCast(dup),
    };
    var mem: c.VkDeviceMemory = null;
    // On success the driver owns the duplicate.
    vk.call(d.vkd.vkAllocateMemory, .{ d.device, &c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &import,
        .allocationSize = reqs.size,
        .memoryTypeIndex = @ctz(bits),
    }, null, &mem }) catch |e| {
        _ = linux.close(@intCast(dup));
        return unsupported(e);
    };
    return mem;
}

/// Failures that mean "not this buffer" fall back; the rest propagate.
fn unsupported(e: vk.Error) Error {
    return switch (e) {
        error.DeviceLost, error.OutOfMemory => e,
        else => blk: {
            log.debug("dma-buf import failed: {t}", .{e});
            break :blk error.Unsupported;
        },
    };
}
