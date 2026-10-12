//! Presentation through the standard Vulkan Wayland swapchain (D7, D10):
//! a VkSurfaceKHR on the platform's wl_display and wl_surface, images the
//! renderer encodes into, and presents with damage (VK_KHR_incremental_
//! present maps it to wl_surface.damage_buffer).
//!
//! The present mode is MAILBOX when offered, so presenting never blocks:
//! the platform's frame clock already paces frames with its own frame
//! callbacks and presentation feedback, which it requests on the surface
//! before vkQueuePresentKHR commits it (D12). FIFO is the fallback; see
//! `blocksOnFrameCallback`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const raster = @import("raster");
const vk = @import("vk.zig");
const c = vk.c;
const Device = @import("Device.zig");
const Renderer = @import("Renderer.zig");

const Swapchain = @This();
const log = std.log.scoped(.vulkan);

gpa: Allocator,
device: *Device,
surface: c.VkSurfaceKHR = null,
handle: c.VkSwapchainKHR = null,
format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
output: Device.Output = .bgra8,
/// Premultiplied alpha reaches the compositor; otherwise the window is
/// opaque and alpha is dropped when encoding.
has_alpha: bool = false,
composite_alpha: c.VkCompositeAlphaFlagBitsKHR = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR,
width: u32 = 0,
height: u32 = 0,
images: []c.VkImage = &.{},
views: []c.VkImageView = &.{},
/// One per frame in flight, waited by the frame's submission.
acquired: [Renderer.frames_in_flight]c.VkSemaphore = @splat(null),
/// One per image, signaled by the submission and waited by the present.
rendered: []c.VkSemaphore = &.{},
/// The surface changed under the swapchain; recreate before the next frame.
stale: bool = false,
rects: std.ArrayList(c.VkRectLayerKHR) = .empty,

pub const PresentMode = enum {
    /// MAILBOX when available, else FIFO.
    auto,
    /// FIFO, the mode every implementation has (for testing D12).
    fifo,
};

pub const Options = struct {
    /// The connection's `wl_display` and the window's `wl_surface`.
    display: *anyopaque,
    surface: *anyopaque,
    present_mode: PresentMode = .auto,
};

pub fn create(gpa: Allocator, device: *Device, options: Options) vk.Error!*Swapchain {
    const d = device;
    if (!d.swapchain or d.vki.vkCreateWaylandSurfaceKHR == null) return error.Unavailable;
    const s = try gpa.create(Swapchain);
    s.* = .{ .gpa = gpa, .device = device };
    errdefer s.destroy();
    const info: c.VkWaylandSurfaceCreateInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        .display = @ptrCast(options.display),
        .surface = @ptrCast(options.surface),
    };
    try vk.call(d.vki.vkCreateWaylandSurfaceKHR, .{ d.instance, &info, null, &s.surface });
    var supported: c.VkBool32 = 0;
    try vk.call(d.vki.vkGetPhysicalDeviceSurfaceSupportKHR, .{ d.physical, d.queue_family, s.surface, &supported });
    if (supported == 0) return error.Unavailable;

    const formats = try vk.enumerate(gpa, c.VkSurfaceFormatKHR, d.vki.vkGetPhysicalDeviceSurfaceFormatsKHR, .{ d.physical, s.surface });
    defer gpa.free(formats);
    s.format = for (formats) |f| {
        if (f.colorSpace != c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) continue;
        if (f.format == c.VK_FORMAT_B8G8R8A8_UNORM or f.format == c.VK_FORMAT_R8G8B8A8_UNORM) break f.format;
    } else return error.Unavailable;
    s.output = if (s.format == c.VK_FORMAT_B8G8R8A8_UNORM) .bgra8 else .rgba8;

    const modes = try vk.enumerate(gpa, c.VkPresentModeKHR, d.vki.vkGetPhysicalDeviceSurfacePresentModesKHR, .{ d.physical, s.surface });
    defer gpa.free(modes);
    s.present_mode = c.VK_PRESENT_MODE_FIFO_KHR;
    if (options.present_mode == .auto) for (modes) |m| {
        if (m == c.VK_PRESENT_MODE_MAILBOX_KHR) s.present_mode = m;
    };

    const sem_info: c.VkSemaphoreCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    for (&s.acquired) |*sem| try vk.call(d.vkd.vkCreateSemaphore, .{ d.device, &sem_info, null, sem });
    return s;
}

pub fn destroy(s: *Swapchain) void {
    const d = s.device;
    if (d.device != null) _ = d.vkd.vkDeviceWaitIdle.?(d.device);
    s.releaseImages();
    if (s.handle != null) d.vkd.vkDestroySwapchainKHR.?(d.device, s.handle, null);
    for (s.acquired) |sem| if (sem != null) d.vkd.vkDestroySemaphore.?(d.device, sem, null);
    if (s.surface != null) d.vki.vkDestroySurfaceKHR.?(d.instance, s.surface, null);
    s.rects.deinit(s.gpa);
    s.gpa.destroy(s);
}

/// Whether presenting can block until the previous frame's frame callback:
/// Mesa's FIFO without wp_fifo_v1 (before Mesa 25) waits for it inside
/// vkQueuePresentKHR with no timeout, so a hidden window would stall the
/// compositor thread. Frames must then wait for the platform's own frame
/// callback, which the compositor sends for the same commit.
pub fn blocksOnFrameCallback(s: *const Swapchain) bool {
    return s.present_mode == c.VK_PRESENT_MODE_FIFO_KHR;
}

fn releaseImages(s: *Swapchain) void {
    const d = s.device;
    for (s.views) |v| d.vkd.vkDestroyImageView.?(d.device, v, null);
    for (s.rendered) |sem| d.vkd.vkDestroySemaphore.?(d.device, sem, null);
    s.gpa.free(s.views);
    s.gpa.free(s.images);
    s.gpa.free(s.rendered);
    s.views = &.{};
    s.images = &.{};
    s.rendered = &.{};
}

/// Makes the swapchain match the window's buffer size. Waits for the GPU
/// when it has to recreate.
pub fn configure(s: *Swapchain, width: u32, height: u32) vk.Error!void {
    if (s.handle != null and !s.stale and s.width == width and s.height == height) return;
    const d = s.device;
    var caps: c.VkSurfaceCapabilitiesKHR = undefined;
    try vk.call(d.vki.vkGetPhysicalDeviceSurfaceCapabilitiesKHR, .{ d.physical, s.surface, &caps });
    // Wayland leaves the size to the client (currentExtent is 0xFFFFFFFF).
    var extent: c.VkExtent2D = .{ .width = width, .height = height };
    if (caps.currentExtent.width != std.math.maxInt(u32)) extent = caps.currentExtent;
    extent.width = std.math.clamp(extent.width, caps.minImageExtent.width, caps.maxImageExtent.width);
    extent.height = std.math.clamp(extent.height, caps.minImageExtent.height, caps.maxImageExtent.height);
    if (extent.width == 0 or extent.height == 0) return error.OutOfDate;
    var count = @max(caps.minImageCount + 1, 3);
    if (caps.maxImageCount != 0) count = @min(count, caps.maxImageCount);
    if (caps.supportedCompositeAlpha & c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR != 0) {
        s.composite_alpha = c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
        s.has_alpha = true;
    } else {
        s.composite_alpha = if (caps.supportedCompositeAlpha & c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR != 0) c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR else c.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
        s.has_alpha = false;
    }

    if (s.handle != null) _ = d.vkd.vkDeviceWaitIdle.?(d.device);
    const info: c.VkSwapchainCreateInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = s.surface,
        .minImageCount = count,
        .imageFormat = s.format,
        .imageColorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = c.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .compositeAlpha = s.composite_alpha,
        .presentMode = s.present_mode,
        .clipped = c.VK_TRUE,
        .oldSwapchain = s.handle,
    };
    var handle: c.VkSwapchainKHR = null;
    vk.check(d.vkd.vkCreateSwapchainKHR.?(d.device, &info, null, &handle)) catch |e| return d.note(e);
    s.releaseImages();
    if (s.handle != null) d.vkd.vkDestroySwapchainKHR.?(d.device, s.handle, null);
    s.handle = handle;
    s.width = extent.width;
    s.height = extent.height;
    s.stale = false;

    s.images = try vk.enumerate(s.gpa, c.VkImage, d.vkd.vkGetSwapchainImagesKHR, .{ d.device, s.handle });
    s.views = try s.gpa.alloc(c.VkImageView, s.images.len);
    @memset(s.views, null);
    s.rendered = try s.gpa.alloc(c.VkSemaphore, s.images.len);
    @memset(s.rendered, null);
    const sem_info: c.VkSemaphoreCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    for (s.images, s.views, s.rendered) |img, *v, *sem| {
        v.* = try d.imageView(img, s.format, c.VK_IMAGE_VIEW_TYPE_2D);
        try vk.call(d.vkd.vkCreateSemaphore, .{ d.device, &sem_info, null, sem });
    }
}

/// An image to render frame `frame` into, or null when the compositor
/// still holds every image.
pub fn acquire(s: *Swapchain, frame: u64) vk.Error!?u32 {
    const d = s.device;
    var index: u32 = 0;
    const r = d.vkd.vkAcquireNextImageKHR.?(d.device, s.handle, 0, s.acquired[frame % Renderer.frames_in_flight], null, &index);
    switch (r) {
        c.VK_SUCCESS => {},
        c.VK_SUBOPTIMAL_KHR => s.stale = true,
        c.VK_NOT_READY, c.VK_TIMEOUT => return null,
        else => {
            if (r == c.VK_ERROR_OUT_OF_DATE_KHR) s.stale = true;
            vk.check(r) catch |e| return d.note(e);
        },
    }
    return index;
}

/// What `Renderer.render` needs to draw into image `index`.
pub fn target(s: *const Swapchain, index: u32, frame: u64) Renderer.Target {
    return .{ .swapchain = .{
        .image = s.images[index],
        .view = s.views[index],
        .output = s.output,
        .has_alpha = s.has_alpha,
        .wait = s.acquired[frame % Renderer.frames_in_flight],
        .signal = s.rendered[index],
    } };
}

/// Presents image `index` (which commits the wl_surface) with this frame's
/// damage in buffer pixels; null damages everything.
pub fn present(s: *Swapchain, index: u32, damage: ?[]const raster.IRect) vk.Error!void {
    const d = s.device;
    var regions: c.VkPresentRegionsKHR = undefined;
    var region: c.VkPresentRegionKHR = undefined;
    var next: ?*const anyopaque = null;
    if (d.incremental_present) if (damage) |rects| {
        s.rects.clearRetainingCapacity();
        for (rects) |rc| {
            const cr = rc.intersect(.xywh(0, 0, @intCast(s.width), @intCast(s.height)));
            if (cr.isEmpty()) continue;
            try s.rects.append(s.gpa, .{
                .offset = .{ .x = cr.x0, .y = cr.y0 },
                .extent = .{ .width = @intCast(cr.width()), .height = @intCast(cr.height()) },
                .layer = 0,
            });
        }
        // No rectangles would mean "no hint"; an unchanged frame damages a
        // single pixel instead of everything.
        if (s.rects.items.len == 0) try s.rects.append(s.gpa, .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 1, .height = 1 }, .layer = 0 });
        region = .{ .rectangleCount = @intCast(s.rects.items.len), .pRectangles = s.rects.items.ptr };
        regions = .{ .sType = c.VK_STRUCTURE_TYPE_PRESENT_REGIONS_KHR, .swapchainCount = 1, .pRegions = &region };
        next = &regions;
    };
    const info: c.VkPresentInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext = next,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &s.rendered[index],
        .swapchainCount = 1,
        .pSwapchains = &s.handle,
        .pImageIndices = &index,
    };
    const r = d.vkd.vkQueuePresentKHR.?(d.queue, &info);
    switch (r) {
        c.VK_SUCCESS => {},
        c.VK_SUBOPTIMAL_KHR => s.stale = true,
        else => {
            if (r == c.VK_ERROR_OUT_OF_DATE_KHR) s.stale = true;
            vk.check(r) catch |e| return d.note(e);
        },
    }
}
