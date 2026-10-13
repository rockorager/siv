//! The Vulkan device (D10): instance, the chosen physical device, one
//! graphics queue, and everything windows share (pipelines, layouts, the
//! sampler, constant tables). One per process, used only from the thread
//! that created it (the compositor thread). Renderers and swapchains refer
//! to it; destroy them first.
//!
//! Device selection: devices without Vulkan 1.3, dynamic rendering,
//! synchronization2, or the FP16 and FP32 render formats are skipped, and so
//! are CPU implementations (lavapipe) unless `allow_cpu`: for presentation
//! the CPU renderer is faster and is the oracle. Among the rest, the
//! compositor's main device from dma-buf feedback wins (matched through
//! VK_EXT_physical_device_drm), so buffers never cross GPUs; then discrete,
//! integrated, virtual, and CPU devices, in that order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vk = @import("vk.zig");
const c = vk.c;
const shaders = @import("shaders");
const render_cpu = @import("render_cpu");

const Device = @This();
const log = std.log.scoped(.vulkan);

gpa: Allocator,
loader: vk.Loader,
options: Options = .{},
pipeline_cache: c.VkPipelineCache = null,
/// Bytes of cache data loaded at creation (0: none, a cold start).
cache_loaded: usize = 0,
base: vk.Base = .{},
vki: vk.Instance = .{},
vkd: vk.Device = .{},
instance: c.VkInstance = null,
messenger: c.VkDebugUtilsMessengerEXT = null,
physical: c.VkPhysicalDevice = null,
device: c.VkDevice = null,
queue: c.VkQueue = null,
queue_family: u32 = 0,
memory: c.VkPhysicalDeviceMemoryProperties = undefined,
limits: c.VkPhysicalDeviceLimits = undefined,
name: [c.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8 = @splat(0),
device_type: c.VkPhysicalDeviceType = c.VK_PHYSICAL_DEVICE_TYPE_OTHER,
/// The device can present (VK_KHR_swapchain is enabled).
swapchain: bool = false,
incremental_present: bool = false,
/// dma-bufs can be imported (VK_KHR_external_memory_fd and
/// VK_EXT_external_memory_dma_buf), linear ones at least.
dmabuf_import: bool = false,
/// ... with explicit modifiers, tiled too (VK_EXT_image_drm_format_modifier).
drm_modifiers: bool = false,
/// VK_EXT_queue_family_foreign.
queue_foreign: bool = false,
/// Set once any call reported VK_ERROR_DEVICE_LOST; everything using the
/// device must fall back (D10).
lost: bool = false,

/// Shared GPU objects.
set_layout: c.VkDescriptorSetLayout = null,
/// Set 1: the two draw-specific textures (`tex_a`, `tex_b`).
texture_layout: c.VkDescriptorSetLayout = null,
pipeline_layout: c.VkPipelineLayout = null,
sampler: c.VkSampler = null,
vert: c.VkShaderModule = null,
draw_frag: c.VkShaderModule = null,
blur_frag: c.VkShaderModule = null,
encode_frag: c.VkShaderModule = null,
draw_pipeline: c.VkPipeline = null,
/// The draw pipeline specialized for common draws (draw.frag's VARIANT 1).
draw_simple_pipeline: c.VkPipeline = null,
replace_pipeline: c.VkPipeline = null,
blur_pipeline: c.VkPipeline = null,
encode_pipelines: [2]c.VkPipeline = .{ null, null },
/// Contrast and transfer-function tables (`Luts` in the shaders).
luts: Buffer = .{},

pub const Options = struct {
    /// Presentation to this `wl_display` is required.
    wayland_display: ?*anyopaque = null,
    /// dev_t of the compositor's main device (dma-buf feedback), if known.
    main_device: ?u64 = null,
    /// Accept CPU implementations such as lavapipe (tests).
    allow_cpu: bool = false,
    /// Enable VK_LAYER_KHRONOS_validation when installed. Messages go to
    /// the log; errors also count in `validation_errors`.
    validation: bool = false,
    pipeline_cache: PipelineCache = .default,
};

/// Where compiled pipelines persist between runs.
pub const PipelineCache = union(enum) {
    /// $XDG_CACHE_HOME/siv/vulkan, or ~/.cache/siv/vulkan.
    default,
    /// This directory (created if missing).
    dir: []const u8,
    none,
};

/// The cache file: <dir>/<pipeline cache UUID>-<shader hash>.bin, so a
/// driver or shader change starts a new file. Null without a cache.
fn cachePath(d: *Device, buf: []u8) ?[:0]const u8 {
    var dir_buf: [std.posix.PATH_MAX]u8 = undefined;
    const dir: []const u8 = switch (d.options.pipeline_cache) {
        .none => return null,
        .dir => |p| p,
        .default => if (std.c.getenv("XDG_CACHE_HOME")) |x| (if (x[0] == '/') std.fmt.bufPrint(&dir_buf, "{s}/siv/vulkan", .{std.mem.span(x)}) catch return null else return null) else if (std.c.getenv("HOME")) |h|
            std.fmt.bufPrint(&dir_buf, "{s}/.cache/siv/vulkan", .{std.mem.span(h)}) catch return null
        else
            return null,
    };
    // mkdir -p.
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i < dir.len and dir[i] != '/') continue;
        var part: [std.posix.PATH_MAX]u8 = undefined;
        if (i >= part.len) return null;
        @memcpy(part[0..i], dir[0..i]);
        part[i] = 0;
        _ = std.c.mkdir(@ptrCast(&part), 0o700);
    }
    var h = std.hash.Wyhash.init(0);
    for ([_][]const u8{ shaders.quad_vert, shaders.draw_frag, shaders.blur_frag, shaders.encode_frag }) |code| h.update(code);
    var props: c.VkPhysicalDeviceProperties = undefined;
    d.vki.vkGetPhysicalDeviceProperties.?(d.physical, &props);
    return std.fmt.bufPrintSentinel(buf, "{s}/{x}-{x:0>16}.bin", .{ dir, props.pipelineCacheUUID, h.final() }, 0) catch null;
}

fn openPipelineCache(d: *Device, path: ?[:0]const u8) vk.Error!void {
    var data: []u8 = &.{};
    defer d.gpa.free(data);
    if (path) |p| data = readFile(d.gpa, p) catch &.{};
    d.cache_loaded = data.len;
    const info: c.VkPipelineCacheCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
        .initialDataSize = data.len,
        .pInitialData = if (data.len > 0) data.ptr else null,
    };
    // Drivers validate the header and ignore data that is not theirs.
    if (d.vkd.vkCreatePipelineCache.?(d.device, &info, null, &d.pipeline_cache) != c.VK_SUCCESS) {
        const empty: c.VkPipelineCacheCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO };
        try vk.call(d.vkd.vkCreatePipelineCache, .{ d.device, &empty, null, &d.pipeline_cache });
    }
}

/// Saves the cache when it grew (atomically: a temporary file renamed
/// over the old one), then drops it: every pipeline exists by now.
fn closePipelineCache(d: *Device, path: ?[:0]const u8) void {
    defer {
        d.vkd.vkDestroyPipelineCache.?(d.device, d.pipeline_cache, null);
        d.pipeline_cache = null;
    }
    const p = path orelse return;
    var size: usize = 0;
    if (d.vkd.vkGetPipelineCacheData.?(d.device, d.pipeline_cache, &size, null) != c.VK_SUCCESS or size == 0 or size == d.cache_loaded) return;
    const data = d.gpa.alloc(u8, size) catch return;
    defer d.gpa.free(data);
    if (d.vkd.vkGetPipelineCacheData.?(d.device, d.pipeline_cache, &size, data.ptr) != c.VK_SUCCESS) return;
    var tmp_buf: [std.posix.PATH_MAX + 8]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tmp_buf, "{s}.{d}", .{ p, std.c.getpid() }, 0) catch return;
    const fd = std.c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    var written: usize = 0;
    while (written < size) {
        const n = std.c.write(fd, data.ptr + written, size - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    _ = std.c.close(fd);
    if (written == size) _ = std.c.rename(tmp, p) else _ = std.c.unlink(tmp);
}

fn readFile(gpa: Allocator, path: [:0]const u8) ![]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return error.NotFound;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [64 * 1024]u8 = undefined;
    while (out.items.len < 64 << 20) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        try out.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(gpa);
}

/// Validation errors reported since start; tests check it stays zero.
pub var validation_errors: std.atomic.Value(u32) = .init(0);

pub const fp16 = c.VK_FORMAT_R16G16B16A16_SFLOAT;
pub const fp32 = c.VK_FORMAT_R32G32B32A32_SFLOAT;
/// Encoded 8-bit outputs (`encode_pipelines` index).
pub const Output = enum(u1) { bgra8, rgba8 };

pub fn outputFormat(o: Output) c.VkFormat {
    return switch (o) {
        .bgra8 => c.VK_FORMAT_B8G8R8A8_UNORM,
        .rgba8 => c.VK_FORMAT_R8G8B8A8_UNORM,
    };
}

pub fn create(gpa: Allocator, options: Options) vk.Error!*Device {
    const loader = try vk.Loader.open();
    const d = gpa.create(Device) catch {
        loader.close();
        return error.OutOfMemory;
    };
    d.* = .{ .gpa = gpa, .loader = loader, .options = options };
    errdefer d.destroy();
    try vk.load(vk.Base, &d.base, loader.getInstanceProcAddr, @as(c.VkInstance, null));
    try d.createInstance(options);
    try d.selectDevice(gpa, options);
    try d.createShared();
    return d;
}

pub fn destroy(d: *Device) void {
    if (d.device != null) {
        _ = d.vkd.vkDeviceWaitIdle.?(d.device);
        const dev = d.device;
        const k = &d.vkd;
        for ([_]c.VkPipeline{ d.draw_pipeline, d.draw_simple_pipeline, d.replace_pipeline, d.blur_pipeline, d.encode_pipelines[0], d.encode_pipelines[1] }) |p| {
            if (p != null) k.vkDestroyPipeline.?(dev, p, null);
        }
        for ([_]c.VkShaderModule{ d.vert, d.draw_frag, d.blur_frag, d.encode_frag }) |m| {
            if (m != null) k.vkDestroyShaderModule.?(dev, m, null);
        }
        if (d.pipeline_layout != null) k.vkDestroyPipelineLayout.?(dev, d.pipeline_layout, null);
        if (d.set_layout != null) k.vkDestroyDescriptorSetLayout.?(dev, d.set_layout, null);
        if (d.texture_layout != null) k.vkDestroyDescriptorSetLayout.?(dev, d.texture_layout, null);
        if (d.sampler != null) k.vkDestroySampler.?(dev, d.sampler, null);
        d.luts.deinit(d);
        k.vkDestroyDevice.?(dev, null);
    }
    if (d.instance != null) {
        if (d.messenger != null) d.vki.vkDestroyDebugUtilsMessengerEXT.?(d.instance, d.messenger, null);
        d.vki.vkDestroyInstance.?(d.instance, null);
    }
    d.loader.close();
    d.gpa.destroy(d);
}

/// Records a failure; device loss marks the device lost for good.
pub fn note(d: *Device, err: vk.Error) vk.Error {
    if (err == error.DeviceLost and !d.lost) {
        log.warn("device lost: {s}", .{d.deviceName()});
        d.lost = true;
    }
    return err;
}

pub fn deviceName(d: *const Device) []const u8 {
    return std.mem.sliceTo(&d.name, 0);
}

// Instance and device --------------------------------------------------------

fn hasName(list: []const [*:0]const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, std.mem.span(n), name)) return true;
    return false;
}

fn createInstance(d: *Device, options: Options) vk.Error!void {
    const gpa = d.gpa;
    var version: u32 = c.VK_API_VERSION_1_0;
    if (d.base.vkEnumerateInstanceVersion) |f| _ = f(&version);
    if (version < c.VK_API_VERSION_1_3) return error.Unavailable;

    const exts = try vk.enumerate(gpa, c.VkExtensionProperties, d.base.vkEnumerateInstanceExtensionProperties, .{@as([*c]const u8, null)});
    defer gpa.free(exts);
    var have_surface = false;
    var have_wayland = false;
    var have_debug = false;
    for (exts) |e| {
        const name = std.mem.sliceTo(&e.extensionName, 0);
        if (std.mem.eql(u8, name, "VK_KHR_surface")) have_surface = true;
        if (std.mem.eql(u8, name, "VK_KHR_wayland_surface")) have_wayland = true;
        if (std.mem.eql(u8, name, "VK_EXT_debug_utils")) have_debug = true;
    }
    var enabled: [3][*:0]const u8 = undefined;
    var n: u32 = 0;
    if (have_surface and have_wayland) {
        enabled[n] = "VK_KHR_surface";
        enabled[n + 1] = "VK_KHR_wayland_surface";
        n += 2;
    } else if (options.wayland_display != null) return error.Unavailable;

    var layers: [1][*:0]const u8 = undefined;
    var nlayers: u32 = 0;
    if (options.validation) {
        const props = try vk.enumerate(gpa, c.VkLayerProperties, d.base.vkEnumerateInstanceLayerProperties, .{});
        defer gpa.free(props);
        for (props) |p| if (std.mem.eql(u8, std.mem.sliceTo(&p.layerName, 0), "VK_LAYER_KHRONOS_validation")) {
            layers[0] = "VK_LAYER_KHRONOS_validation";
            nlayers = 1;
        };
        if (nlayers == 1 and have_debug) {
            enabled[n] = "VK_EXT_debug_utils";
            n += 1;
        }
    }

    const app: c.VkApplicationInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pEngineName = "siv",
        .apiVersion = c.VK_API_VERSION_1_3,
    };
    const info: c.VkInstanceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
        .enabledLayerCount = nlayers,
        .ppEnabledLayerNames = @ptrCast(&layers),
        .enabledExtensionCount = n,
        .ppEnabledExtensionNames = @ptrCast(&enabled),
    };
    try vk.call(d.base.vkCreateInstance, .{ &info, null, &d.instance });
    try vk.load(vk.Instance, &d.vki, d.loader.getInstanceProcAddr, d.instance);
    if (nlayers == 1 and have_debug) {
        const mi: c.VkDebugUtilsMessengerCreateInfoEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = onDebugMessage,
        };
        try vk.call(d.vki.vkCreateDebugUtilsMessengerEXT, .{ d.instance, &mi, null, &d.messenger });
    }
}

fn onDebugMessage(severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT, _: c.VkDebugUtilsMessageTypeFlagsEXT, data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT, _: ?*anyopaque) callconv(.c) c.VkBool32 {
    const msg: []const u8 = if (data != null and data.*.pMessage != null) std.mem.span(data.*.pMessage) else "";
    if (severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT != 0) {
        _ = validation_errors.fetchAdd(1, .monotonic);
        log.err("validation: {s}", .{msg});
    } else log.warn("validation: {s}", .{msg});
    return c.VK_FALSE;
}

const Candidate = struct {
    physical: c.VkPhysicalDevice,
    family: u32,
    score: u32,
    swapchain: bool,
    incremental: bool,
    dmabuf: bool,
    modifiers: bool,
    foreign: bool,
};

fn selectDevice(d: *Device, gpa: Allocator, options: Options) vk.Error!void {
    const devices = try vk.enumerate(gpa, c.VkPhysicalDevice, d.vki.vkEnumeratePhysicalDevices, .{d.instance});
    defer gpa.free(devices);
    var best: ?Candidate = null;
    for (devices) |pd| {
        const cand = d.evaluate(gpa, pd, options) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => null,
        } orelse continue;
        if (best == null or cand.score > best.?.score) best = cand;
    }
    const chosen = best orelse return error.Unavailable;
    d.physical = chosen.physical;
    d.queue_family = chosen.family;
    d.swapchain = chosen.swapchain;
    d.incremental_present = chosen.incremental;
    d.dmabuf_import = chosen.dmabuf;
    d.drm_modifiers = chosen.dmabuf and chosen.modifiers;
    d.queue_foreign = chosen.dmabuf and chosen.foreign;

    var props: c.VkPhysicalDeviceProperties = undefined;
    d.vki.vkGetPhysicalDeviceProperties.?(d.physical, &props);
    d.limits = props.limits;
    d.name = props.deviceName;
    d.device_type = props.deviceType;
    d.vki.vkGetPhysicalDeviceMemoryProperties.?(d.physical, &d.memory);
    log.info("using {s}", .{d.deviceName()});

    const priority: f32 = 1;
    const queue_info: c.VkDeviceQueueCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = d.queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    var f13: c.VkPhysicalDeviceVulkan13Features = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .dynamicRendering = c.VK_TRUE,
        .synchronization2 = c.VK_TRUE,
        // Both required by Vulkan 1.3: `discard` compiles to demote in
        // SPIR-V 1.6, and passes ignore the quad shader's instance output.
        .shaderDemoteToHelperInvocation = c.VK_TRUE,
        .maintenance4 = c.VK_TRUE,
    };

    var exts: [7][*:0]const u8 = undefined;
    var n: u32 = 0;
    for ([_]struct { bool, [*:0]const u8 }{
        .{ d.swapchain, "VK_KHR_swapchain" },
        .{ d.swapchain and d.incremental_present, "VK_KHR_incremental_present" },
        .{ d.dmabuf_import, "VK_KHR_external_memory_fd" },
        .{ d.dmabuf_import, "VK_EXT_external_memory_dma_buf" },
        .{ d.drm_modifiers, "VK_EXT_image_drm_format_modifier" },
        .{ d.queue_foreign, "VK_EXT_queue_family_foreign" },
    }) |e| if (e[0]) {
        exts[n] = e[1];
        n += 1;
    };
    const info: c.VkDeviceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &f13,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = n,
        .ppEnabledExtensionNames = @ptrCast(&exts),
    };
    try vk.call(d.vki.vkCreateDevice, .{ d.physical, &info, null, &d.device });
    try vk.load(vk.Device, &d.vkd, d.vki.vkGetDeviceProcAddr, d.device);
    d.vkd.vkGetDeviceQueue.?(d.device, d.queue_family, 0, &d.queue);
}

/// Null if the device is unsuitable; otherwise its score.
fn evaluate(d: *Device, gpa: Allocator, pd: c.VkPhysicalDevice, options: Options) vk.Error!?Candidate {
    const k = &d.vki;
    var props: c.VkPhysicalDeviceProperties = undefined;
    k.vkGetPhysicalDeviceProperties.?(pd, &props);
    const name = std.mem.sliceTo(&props.deviceName, 0);
    if (props.apiVersion < c.VK_API_VERSION_1_3) return null;
    const is_cpu = props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_CPU;
    if (is_cpu and !options.allow_cpu) {
        log.debug("{s}: skipped, CPU implementation", .{name});
        return null;
    }

    var f13: c.VkPhysicalDeviceVulkan13Features = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    var f2: c.VkPhysicalDeviceFeatures2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f13 };
    k.vkGetPhysicalDeviceFeatures2.?(pd, &f2);
    if (f13.dynamicRendering == 0 or f13.synchronization2 == 0) {
        log.debug("{s}: skipped, missing features", .{name});
        return null;
    }
    const attach = c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
    for ([_]struct { c.VkFormat, c.VkFormatFeatureFlags }{
        .{ fp16, attach | c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT | c.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT },
        .{ fp32, attach },
        .{ c.VK_FORMAT_R8_UNORM, c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT },
        .{ c.VK_FORMAT_R16G16B16A16_UNORM, c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT },
        .{ c.VK_FORMAT_R8G8B8A8_UNORM, attach | c.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT },
        .{ c.VK_FORMAT_B8G8R8A8_UNORM, c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT },
    }) |req| {
        var fp: c.VkFormatProperties = undefined;
        k.vkGetPhysicalDeviceFormatProperties.?(pd, req[0], &fp);
        if (fp.optimalTilingFeatures & req[1] != req[1]) {
            log.debug("{s}: skipped, format {d} unsupported", .{ name, req[0] });
            return null;
        }
    }

    const families = try vk.enumerateVoid(gpa, c.VkQueueFamilyProperties, k.vkGetPhysicalDeviceQueueFamilyProperties, .{pd});
    defer gpa.free(families);
    const family: u32 = for (families, 0..) |f, i| {
        if (f.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
        if (options.wayland_display) |display| {
            if (k.vkGetPhysicalDeviceWaylandPresentationSupportKHR == null) continue;
            if (k.vkGetPhysicalDeviceWaylandPresentationSupportKHR.?(pd, @intCast(i), @ptrCast(display)) == 0) continue;
        }
        break @intCast(i);
    } else {
        log.debug("{s}: skipped, no suitable queue", .{name});
        return null;
    };

    const exts = try vk.enumerate(gpa, c.VkExtensionProperties, k.vkEnumerateDeviceExtensionProperties, .{ pd, @as([*c]const u8, null) });
    defer gpa.free(exts);
    var swapchain = false;
    var incremental = false;
    var drm = false;
    var memory_fd = false;
    var dmabuf = false;
    var modifiers = false;
    var foreign = false;
    for (exts) |e| {
        const en = std.mem.sliceTo(&e.extensionName, 0);
        if (std.mem.eql(u8, en, "VK_KHR_swapchain")) swapchain = true;
        if (std.mem.eql(u8, en, "VK_KHR_incremental_present")) incremental = true;
        if (std.mem.eql(u8, en, "VK_EXT_physical_device_drm")) drm = true;
        if (std.mem.eql(u8, en, "VK_KHR_external_memory_fd")) memory_fd = true;
        if (std.mem.eql(u8, en, "VK_EXT_external_memory_dma_buf")) dmabuf = true;
        if (std.mem.eql(u8, en, "VK_EXT_image_drm_format_modifier")) modifiers = true;
        if (std.mem.eql(u8, en, "VK_EXT_queue_family_foreign")) foreign = true;
    }
    if (options.wayland_display != null and !swapchain) return null;

    var score: u32 = switch (props.deviceType) {
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 4,
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 3,
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 2,
        c.VK_PHYSICAL_DEVICE_TYPE_CPU => 1,
        else => 0,
    };
    if (drm and options.main_device != null) {
        var dp: c.VkPhysicalDeviceDrmPropertiesEXT = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT };
        var p2: c.VkPhysicalDeviceProperties2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &dp };
        k.vkGetPhysicalDeviceProperties2.?(pd, &p2);
        if (matchesDevice(dp, options.main_device.?)) score += 16;
    }
    log.debug("{s}: score {d}", .{ name, score });
    return .{ .physical = pd, .family = family, .score = score, .swapchain = swapchain, .incremental = incremental, .dmabuf = memory_fd and dmabuf, .modifiers = modifiers, .foreign = foreign };
}

/// Whether a dev_t (Linux encoding) names the device's primary or render
/// node.
pub fn matchesDevice(dp: c.VkPhysicalDeviceDrmPropertiesEXT, dev: u64) bool {
    const major: i64 = @intCast(((dev >> 8) & 0xfff) | ((dev >> 32) & ~@as(u64, 0xfff)));
    const minor: i64 = @intCast((dev & 0xff) | ((dev >> 12) & ~@as(u64, 0xff)));
    if (dp.hasPrimary != 0 and dp.primaryMajor == major and dp.primaryMinor == minor) return true;
    if (dp.hasRender != 0 and dp.renderMajor == major and dp.renderMinor == minor) return true;
    return false;
}

// Shared objects --------------------------------------------------------------

/// Set 0 bindings, matching common.glsl.
pub const Binding = enum(u32) { insts, paints, stops, clips, luts, kernels, glyph_masks, glyph_colors, masks };

fn createShared(d: *Device) vk.Error!void {
    var cache_buf: [std.posix.PATH_MAX]u8 = undefined;
    const k = &d.vkd;
    const dev = d.device;
    const sampler_info: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = c.VK_FILTER_NEAREST,
        .minFilter = c.VK_FILTER_NEAREST,
        .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .unnormalizedCoordinates = c.VK_FALSE,
    };
    try vk.call(k.vkCreateSampler, .{ dev, &sampler_info, null, &d.sampler });

    var bindings: [9]c.VkDescriptorSetLayoutBinding = undefined;
    for (&bindings, 0..) |*b, i| b.* = .{
        .binding = @intCast(i),
        .descriptorType = if (i < 6) c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER else c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    try vk.call(k.vkCreateDescriptorSetLayout, .{ dev, &c.VkDescriptorSetLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    }, null, &d.set_layout });
    var textures = bindings[6..8].*;
    for (&textures, 0..) |*b, i| b.binding = @intCast(i);
    try vk.call(k.vkCreateDescriptorSetLayout, .{ dev, &c.VkDescriptorSetLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = textures.len,
        .pBindings = &textures,
    }, null, &d.texture_layout });
    const range: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(Push),
    };
    const set_layouts = [_]c.VkDescriptorSetLayout{ d.set_layout, d.texture_layout };
    const layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = set_layouts.len,
        .pSetLayouts = &set_layouts,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &range,
    };
    try vk.call(k.vkCreatePipelineLayout, .{ dev, &layout_info, null, &d.pipeline_layout });

    d.vert = try d.shaderModule(shaders.quad_vert);
    d.draw_frag = try d.shaderModule(shaders.draw_frag);
    d.blur_frag = try d.shaderModule(shaders.blur_frag);
    d.encode_frag = try d.shaderModule(shaders.encode_frag);
    const cache_path = d.cachePath(&cache_buf);
    try d.openPipelineCache(cache_path);
    defer d.closePipelineCache(cache_path);
    d.draw_pipeline = try d.pipeline(d.draw_frag, fp16, true, 0);
    d.draw_simple_pipeline = try d.pipeline(d.draw_frag, fp16, true, 1);
    d.replace_pipeline = try d.pipeline(d.draw_frag, fp16, false, 0);
    d.blur_pipeline = try d.pipeline(d.blur_frag, fp32, false, 0);
    d.encode_pipelines[@backingInt(Output.bgra8)] = try d.pipeline(d.encode_frag, outputFormat(.bgra8), false, 0);
    d.encode_pipelines[@backingInt(Output.rgba8)] = try d.pipeline(d.encode_frag, outputFormat(.rgba8), false, 0);

    // Constant tables, one u32 per entry: 16 text contrast tables of 256,
    // then the CPU renderer's transfer tables (sRGB byte to linear u16,
    // linear u16 to sRGB u16, linear u16 to sRGB 8.8 fixed point, sRGB u16
    // to linear u16).
    const contrast = try d.gpa.create(render_cpu.glyph.ContrastLuts);
    defer d.gpa.destroy(contrast);
    contrast.init();
    const transfer = try d.gpa.create(render_cpu.Luts);
    defer d.gpa.destroy(transfer);
    transfer.init();
    const levels = render_cpu.glyph.ContrastLuts.levels;
    const count = levels * 256 + 256 + 3 * 65536;
    d.luts = try Buffer.init(d, count * 4, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    const out: [*]u32 = @ptrCast(@alignCast(d.luts.mapped.?));
    for (contrast.tables, 0..) |t, i| for (t, 0..) |v, j| {
        out[i * 256 + j] = v;
    };
    for (transfer.srgb8_to_linear, 0..) |v, i| out[levels * 256 + i] = v;
    for (transfer.linear_to_srgb16, 0..) |v, i| out[levels * 256 + 256 + i] = v;
    for (transfer.linear_to_srgb8_8, 0..) |v, i| out[levels * 256 + 256 + 65536 + i] = v;
    for (transfer.srgb16_to_linear, 0..) |v, i| out[levels * 256 + 256 + 2 * 65536 + i] = v;
}

/// Push constants, matching common.glsl.
pub const Push = extern struct {
    /// Device coordinates of the render target's pixel (0, 0), and its size.
    origin: [2]f32 = .{ 0, 0 },
    size: [2]f32 = .{ 0, 0 },
    /// Quad in device pixels for passes without instances (blur, encode);
    /// x0 < 0 means quads come from instances.
    region: [4]i32 = .{ -1, 0, 0, 0 },
    /// Blur: rows or columns reads clamp to.
    clamp: [4]i32 = .{ 0, 0, 0, 0 },
    /// Instance draws: each instance is drawn four times, as the quads
    /// around its hole (quad.vert).
    pieces: u32 = 0,
    /// Device coordinates of `tex_a`'s texel (0, 0) are `src_origin`.
    mode: u32 = 0,
    radius: u32 = 0,
    kernel: u32 = 0,
    src_origin: [2]f32 = .{ 0, 0 },
    dir: [2]i32 = .{ 0, 0 },
};

fn shaderModule(d: *Device, code: []const u8) vk.Error!c.VkShaderModule {
    const aligned = try d.gpa.alignedAlloc(u8, .of(u32), code.len);
    defer d.gpa.free(aligned);
    @memcpy(aligned, code);
    const info: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = @ptrCast(aligned.ptr),
    };
    var m: c.VkShaderModule = null;
    try vk.call(d.vkd.vkCreateShaderModule, .{ d.device, &info, null, &m });
    return m;
}

/// `variant` sets the fragment shader's specialization constant 0.
fn pipeline(d: *Device, frag: c.VkShaderModule, format: c.VkFormat, blend: bool, variant: u32) vk.Error!c.VkPipeline {
    const entry: c.VkSpecializationMapEntry = .{ .constantID = 0, .offset = 0, .size = 4 };
    const spec: c.VkSpecializationInfo = .{ .mapEntryCount = 1, .pMapEntries = &entry, .dataSize = 4, .pData = &variant };
    const stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = d.vert, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag, .pName = "main", .pSpecializationInfo = &spec },
    };
    const vertex_input: c.VkPipelineVertexInputStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    const assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    };
    const viewport: c.VkPipelineViewportStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };
    const raster: c.VkPipelineRasterizationStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .cullMode = c.VK_CULL_MODE_NONE,
        .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1,
    };
    const multisample: c.VkPipelineMultisampleStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
    };
    // Premultiplied source-over.
    const attachment: c.VkPipelineColorBlendAttachmentState = .{
        .blendEnable = if (blend) c.VK_TRUE else c.VK_FALSE,
        .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = c.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = c.VK_BLEND_OP_ADD,
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    };
    const blend_state: c.VkPipelineColorBlendStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &attachment,
    };
    const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    const dynamic: c.VkPipelineDynamicStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };
    const rendering: c.VkPipelineRenderingCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &format,
    };
    const info: c.VkGraphicsPipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &rendering,
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &assembly,
        .pViewportState = &viewport,
        .pRasterizationState = &raster,
        .pMultisampleState = &multisample,
        .pColorBlendState = &blend_state,
        .pDynamicState = &dynamic,
        .layout = d.pipeline_layout,
    };
    var p: c.VkPipeline = null;
    try vk.call(d.vkd.vkCreateGraphicsPipelines, .{ d.device, d.pipeline_cache, 1, &info, null, &p });
    return p;
}

// Memory ----------------------------------------------------------------------

pub fn allocate(d: *Device, reqs: c.VkMemoryRequirements, want: c.VkMemoryPropertyFlags) vk.Error!c.VkDeviceMemory {
    const index = for (0..d.memory.memoryTypeCount) |i| {
        if (reqs.memoryTypeBits & (@as(u32, 1) << @intCast(i)) == 0) continue;
        if (d.memory.memoryTypes[i].propertyFlags & want == want) break i;
    } else return error.OutOfMemory;
    const info: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = reqs.size,
        .memoryTypeIndex = @intCast(index),
    };
    var mem: c.VkDeviceMemory = null;
    try vk.call(d.vkd.vkAllocateMemory, .{ d.device, &info, null, &mem });
    return mem;
}

/// A host-visible, coherent, persistently mapped buffer.
pub const Buffer = struct {
    handle: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    size: usize = 0,
    mapped: ?[*]u8 = null,

    pub fn init(d: *Device, size: usize, usage: c.VkBufferUsageFlags) vk.Error!Buffer {
        var b: Buffer = .{ .size = size };
        errdefer b.deinit(d);
        const info: c.VkBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = @max(size, 16),
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        };
        try vk.call(d.vkd.vkCreateBuffer, .{ d.device, &info, null, &b.handle });
        var reqs: c.VkMemoryRequirements = undefined;
        d.vkd.vkGetBufferMemoryRequirements.?(d.device, b.handle, &reqs);
        b.memory = try d.allocate(reqs, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        try vk.call(d.vkd.vkBindBufferMemory, .{ d.device, b.handle, b.memory, 0 });
        var p: ?*anyopaque = null;
        try vk.call(d.vkd.vkMapMemory, .{ d.device, b.memory, 0, c.VK_WHOLE_SIZE, 0, &p });
        b.mapped = @ptrCast(p);
        return b;
    }

    pub fn deinit(b: *Buffer, d: *Device) void {
        if (b.handle != null) d.vkd.vkDestroyBuffer.?(d.device, b.handle, null);
        if (b.memory != null) d.vkd.vkFreeMemory.?(d.device, b.memory, null);
        b.* = .{};
    }

    /// Makes room for `size` bytes, dropping the contents. The caller must
    /// know the GPU no longer reads the buffer.
    pub fn reserve(b: *Buffer, d: *Device, size: usize, usage: c.VkBufferUsageFlags) vk.Error!void {
        if (size <= b.size and b.handle != null) return;
        var grown = try Buffer.init(d, @max(size, b.size * 2, 64 << 10), usage);
        b.deinit(d);
        b.* = grown;
        grown = .{};
    }
};

/// A device-local 2D image with one view, tracking its layout.
pub const Image = struct {
    handle: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    width: u32 = 0,
    height: u32 = 0,
    layers: u32 = 1,
    format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,

    pub fn init(d: *Device, width: u32, height: u32, format: c.VkFormat, usage: c.VkImageUsageFlags) vk.Error!Image {
        return make(d, width, height, 1, format, usage, c.VK_IMAGE_VIEW_TYPE_2D);
    }

    /// An image with `layers` layers and a 2D array view.
    pub fn initArray(d: *Device, width: u32, height: u32, layers: u32, format: c.VkFormat, usage: c.VkImageUsageFlags) vk.Error!Image {
        return make(d, width, height, layers, format, usage, c.VK_IMAGE_VIEW_TYPE_2D_ARRAY);
    }

    fn make(d: *Device, width: u32, height: u32, layers: u32, format: c.VkFormat, usage: c.VkImageUsageFlags, view_type: c.VkImageViewType) vk.Error!Image {
        var img: Image = .{ .width = width, .height = height, .layers = layers, .format = format };
        errdefer img.deinit(d);
        const info: c.VkImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = layers,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        try vk.call(d.vkd.vkCreateImage, .{ d.device, &info, null, &img.handle });
        var reqs: c.VkMemoryRequirements = undefined;
        d.vkd.vkGetImageMemoryRequirements.?(d.device, img.handle, &reqs);
        img.memory = try d.allocate(reqs, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try vk.call(d.vkd.vkBindImageMemory, .{ d.device, img.handle, img.memory, 0 });
        img.view = try d.imageView(img.handle, format, view_type);
        return img;
    }

    pub fn deinit(img: *Image, d: *Device) void {
        if (img.view != null) d.vkd.vkDestroyImageView.?(d.device, img.view, null);
        if (img.handle != null) d.vkd.vkDestroyImage.?(d.device, img.handle, null);
        if (img.memory != null) d.vkd.vkFreeMemory.?(d.device, img.memory, null);
        img.* = .{};
    }
};

pub fn imageView(d: *Device, image: c.VkImage, format: c.VkFormat, view_type: c.VkImageViewType) vk.Error!c.VkImageView {
    const info: c.VkImageViewCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = view_type,
        .format = format,
        .subresourceRange = color_range,
    };
    var view: c.VkImageView = null;
    try vk.call(d.vkd.vkCreateImageView, .{ d.device, &info, null, &view });
    return view;
}

pub const color_range: c.VkImageSubresourceRange = .{
    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
    .baseMipLevel = 0,
    .levelCount = 1,
    .baseArrayLayer = 0,
    .layerCount = c.VK_REMAINING_ARRAY_LAYERS,
};

pub const color_layers: c.VkImageSubresourceLayers = .{
    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
    .mipLevel = 0,
    .baseArrayLayer = 0,
    .layerCount = 1,
};
