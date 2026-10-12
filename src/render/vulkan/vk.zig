//! Vulkan entry points, loaded at run time from libvulkan.so.1 so that
//! libsiv starts on machines without a Vulkan loader (and falls back to
//! the CPU renderer there, D10).

const std = @import("std");
pub const c = @import("vulkan");

pub const Error = error{
    /// No loader, no suitable device, or initialization failed.
    Unavailable,
    OutOfMemory,
    DeviceLost,
    SurfaceLost,
    /// The swapchain no longer matches the surface.
    OutOfDate,
    Unexpected,
};

/// Maps a failing VkResult to an error.
pub fn check(r: c.VkResult) Error!void {
    return switch (r) {
        c.VK_SUCCESS => {},
        c.VK_ERROR_OUT_OF_HOST_MEMORY, c.VK_ERROR_OUT_OF_DEVICE_MEMORY, c.VK_ERROR_OUT_OF_POOL_MEMORY, c.VK_ERROR_FRAGMENTED_POOL, c.VK_ERROR_TOO_MANY_OBJECTS => error.OutOfMemory,
        c.VK_ERROR_DEVICE_LOST => error.DeviceLost,
        c.VK_ERROR_SURFACE_LOST_KHR, c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => error.SurfaceLost,
        c.VK_ERROR_OUT_OF_DATE_KHR => error.OutOfDate,
        c.VK_ERROR_INITIALIZATION_FAILED, c.VK_ERROR_INCOMPATIBLE_DRIVER, c.VK_ERROR_EXTENSION_NOT_PRESENT, c.VK_ERROR_FEATURE_NOT_PRESENT, c.VK_ERROR_LAYER_NOT_PRESENT => error.Unavailable,
        else => error.Unexpected,
    };
}

/// Functions resolved without an instance.
pub const Base = struct {
    vkCreateInstance: c.PFN_vkCreateInstance = null,
    vkEnumerateInstanceExtensionProperties: c.PFN_vkEnumerateInstanceExtensionProperties = null,
    vkEnumerateInstanceLayerProperties: c.PFN_vkEnumerateInstanceLayerProperties = null,
    vkEnumerateInstanceVersion: c.PFN_vkEnumerateInstanceVersion = null,
};

pub const Instance = struct {
    vkDestroyInstance: c.PFN_vkDestroyInstance = null,
    vkEnumeratePhysicalDevices: c.PFN_vkEnumeratePhysicalDevices = null,
    vkGetPhysicalDeviceProperties: c.PFN_vkGetPhysicalDeviceProperties = null,
    vkGetPhysicalDeviceProperties2: c.PFN_vkGetPhysicalDeviceProperties2 = null,
    vkGetPhysicalDeviceFeatures2: c.PFN_vkGetPhysicalDeviceFeatures2 = null,
    vkGetPhysicalDeviceQueueFamilyProperties: c.PFN_vkGetPhysicalDeviceQueueFamilyProperties = null,
    vkGetPhysicalDeviceMemoryProperties: c.PFN_vkGetPhysicalDeviceMemoryProperties = null,
    vkGetPhysicalDeviceFormatProperties: c.PFN_vkGetPhysicalDeviceFormatProperties = null,
    vkGetPhysicalDeviceFormatProperties2: c.PFN_vkGetPhysicalDeviceFormatProperties2 = null,
    vkGetPhysicalDeviceImageFormatProperties2: c.PFN_vkGetPhysicalDeviceImageFormatProperties2 = null,
    vkEnumerateDeviceExtensionProperties: c.PFN_vkEnumerateDeviceExtensionProperties = null,
    vkCreateDevice: c.PFN_vkCreateDevice = null,
    vkGetDeviceProcAddr: c.PFN_vkGetDeviceProcAddr = null,
    vkDestroySurfaceKHR: c.PFN_vkDestroySurfaceKHR = null,
    vkGetPhysicalDeviceSurfaceSupportKHR: c.PFN_vkGetPhysicalDeviceSurfaceSupportKHR = null,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: c.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR = null,
    vkGetPhysicalDeviceSurfaceFormatsKHR: c.PFN_vkGetPhysicalDeviceSurfaceFormatsKHR = null,
    vkGetPhysicalDeviceSurfacePresentModesKHR: c.PFN_vkGetPhysicalDeviceSurfacePresentModesKHR = null,
    vkCreateWaylandSurfaceKHR: c.PFN_vkCreateWaylandSurfaceKHR = null,
    vkGetPhysicalDeviceWaylandPresentationSupportKHR: c.PFN_vkGetPhysicalDeviceWaylandPresentationSupportKHR = null,
    vkCreateDebugUtilsMessengerEXT: c.PFN_vkCreateDebugUtilsMessengerEXT = null,
    vkDestroyDebugUtilsMessengerEXT: c.PFN_vkDestroyDebugUtilsMessengerEXT = null,
};

pub const Device = struct {
    vkDestroyDevice: c.PFN_vkDestroyDevice = null,
    vkGetDeviceQueue: c.PFN_vkGetDeviceQueue = null,
    vkDeviceWaitIdle: c.PFN_vkDeviceWaitIdle = null,
    vkQueueSubmit2: c.PFN_vkQueueSubmit2 = null,
    vkCreateCommandPool: c.PFN_vkCreateCommandPool = null,
    vkDestroyCommandPool: c.PFN_vkDestroyCommandPool = null,
    vkResetCommandPool: c.PFN_vkResetCommandPool = null,
    vkAllocateCommandBuffers: c.PFN_vkAllocateCommandBuffers = null,
    vkBeginCommandBuffer: c.PFN_vkBeginCommandBuffer = null,
    vkEndCommandBuffer: c.PFN_vkEndCommandBuffer = null,
    vkCreateFence: c.PFN_vkCreateFence = null,
    vkDestroyFence: c.PFN_vkDestroyFence = null,
    vkWaitForFences: c.PFN_vkWaitForFences = null,
    vkResetFences: c.PFN_vkResetFences = null,
    vkCreateSemaphore: c.PFN_vkCreateSemaphore = null,
    vkDestroySemaphore: c.PFN_vkDestroySemaphore = null,
    vkCreateBuffer: c.PFN_vkCreateBuffer = null,
    vkDestroyBuffer: c.PFN_vkDestroyBuffer = null,
    vkCreateImage: c.PFN_vkCreateImage = null,
    vkDestroyImage: c.PFN_vkDestroyImage = null,
    vkCreateImageView: c.PFN_vkCreateImageView = null,
    vkDestroyImageView: c.PFN_vkDestroyImageView = null,
    vkGetBufferMemoryRequirements: c.PFN_vkGetBufferMemoryRequirements = null,
    vkGetImageMemoryRequirements: c.PFN_vkGetImageMemoryRequirements = null,
    vkAllocateMemory: c.PFN_vkAllocateMemory = null,
    vkFreeMemory: c.PFN_vkFreeMemory = null,
    vkBindBufferMemory: c.PFN_vkBindBufferMemory = null,
    vkBindImageMemory: c.PFN_vkBindImageMemory = null,
    vkMapMemory: c.PFN_vkMapMemory = null,
    vkCreateSampler: c.PFN_vkCreateSampler = null,
    vkDestroySampler: c.PFN_vkDestroySampler = null,
    vkCreateShaderModule: c.PFN_vkCreateShaderModule = null,
    vkDestroyShaderModule: c.PFN_vkDestroyShaderModule = null,
    vkCreateDescriptorSetLayout: c.PFN_vkCreateDescriptorSetLayout = null,
    vkDestroyDescriptorSetLayout: c.PFN_vkDestroyDescriptorSetLayout = null,
    vkCreatePipelineLayout: c.PFN_vkCreatePipelineLayout = null,
    vkDestroyPipelineLayout: c.PFN_vkDestroyPipelineLayout = null,
    vkCreateGraphicsPipelines: c.PFN_vkCreateGraphicsPipelines = null,
    vkCreatePipelineCache: c.PFN_vkCreatePipelineCache = null,
    vkDestroyPipelineCache: c.PFN_vkDestroyPipelineCache = null,
    vkGetPipelineCacheData: c.PFN_vkGetPipelineCacheData = null,
    vkDestroyPipeline: c.PFN_vkDestroyPipeline = null,
    vkCreateDescriptorPool: c.PFN_vkCreateDescriptorPool = null,
    vkDestroyDescriptorPool: c.PFN_vkDestroyDescriptorPool = null,
    vkResetDescriptorPool: c.PFN_vkResetDescriptorPool = null,
    vkAllocateDescriptorSets: c.PFN_vkAllocateDescriptorSets = null,
    vkUpdateDescriptorSets: c.PFN_vkUpdateDescriptorSets = null,
    vkCmdPipelineBarrier2: c.PFN_vkCmdPipelineBarrier2 = null,
    vkCmdBeginRendering: c.PFN_vkCmdBeginRendering = null,
    vkCmdEndRendering: c.PFN_vkCmdEndRendering = null,
    vkCmdBindPipeline: c.PFN_vkCmdBindPipeline = null,
    vkCmdBindDescriptorSets: c.PFN_vkCmdBindDescriptorSets = null,
    vkCmdPushConstants: c.PFN_vkCmdPushConstants = null,
    vkCmdSetViewport: c.PFN_vkCmdSetViewport = null,
    vkCmdSetScissor: c.PFN_vkCmdSetScissor = null,
    vkCmdDraw: c.PFN_vkCmdDraw = null,
    vkCmdCopyBufferToImage: c.PFN_vkCmdCopyBufferToImage = null,
    vkCmdCopyImage: c.PFN_vkCmdCopyImage = null,
    vkCmdCopyImageToBuffer: c.PFN_vkCmdCopyImageToBuffer = null,
    vkCreateSwapchainKHR: c.PFN_vkCreateSwapchainKHR = null,
    vkDestroySwapchainKHR: c.PFN_vkDestroySwapchainKHR = null,
    vkGetSwapchainImagesKHR: c.PFN_vkGetSwapchainImagesKHR = null,
    vkAcquireNextImageKHR: c.PFN_vkAcquireNextImageKHR = null,
    vkQueuePresentKHR: c.PFN_vkQueuePresentKHR = null,
    vkGetMemoryFdPropertiesKHR: c.PFN_vkGetMemoryFdPropertiesKHR = null,
};

/// Functions only some devices or instances have; the rest are required.
const optional = [_][]const u8{
    "vkCreateDebugUtilsMessengerEXT",
    "vkDestroyDebugUtilsMessengerEXT",
    "vkDestroySurfaceKHR",
    "vkGetPhysicalDeviceSurfaceSupportKHR",
    "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
    "vkGetPhysicalDeviceSurfaceFormatsKHR",
    "vkGetPhysicalDeviceSurfacePresentModesKHR",
    "vkCreateWaylandSurfaceKHR",
    "vkGetPhysicalDeviceWaylandPresentationSupportKHR",
    "vkCreateSwapchainKHR",
    "vkDestroySwapchainKHR",
    "vkGetSwapchainImagesKHR",
    "vkAcquireNextImageKHR",
    "vkQueuePresentKHR",
    "vkGetMemoryFdPropertiesKHR",
};

fn isOptional(comptime name: []const u8) bool {
    @setEvalBranchQuota(100_000);
    inline for (optional) |o| if (comptime std.mem.eql(u8, o, name)) return true;
    return false;
}

/// Fills every field of `table` through `proc(handle, name)`
/// (vkGetInstanceProcAddr or vkGetDeviceProcAddr).
pub fn load(comptime T: type, table: *T, proc: anytype, handle: anytype) Error!void {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const p = proc.?(handle, name);
        if (p == null and !comptime isOptional(name)) {
            std.log.scoped(.vulkan).debug("missing entry point {s}", .{name});
            return error.Unavailable;
        }
        @field(table, name) = @ptrCast(p);
    }
}

/// The loader library: dlopen'ed once per `Loader` and closed with it.
pub const Loader = struct {
    lib: *anyopaque,
    getInstanceProcAddr: c.PFN_vkGetInstanceProcAddr,

    pub fn open() Error!Loader {
        const lib = std.c.dlopen("libvulkan.so.1", .{ .NOW = true }) orelse return error.Unavailable;
        errdefer _ = std.c.dlclose(lib);
        const sym = std.c.dlsym(lib, "vkGetInstanceProcAddr") orelse return error.Unavailable;
        return .{ .lib = lib, .getInstanceProcAddr = @ptrCast(sym) };
    }

    pub fn close(l: Loader) void {
        _ = std.c.dlclose(l.lib);
    }
};

/// Calls `f` and returns its result as an error union.
pub inline fn call(f: anytype, args: anytype) Error!void {
    return check(@call(.auto, f.?, args));
}

/// Fetches a variable-length array through the usual count/pointer pair.
pub fn enumerate(gpa: std.mem.Allocator, comptime T: type, f: anytype, args: anytype) Error![]T {
    var n: u32 = 0;
    try check(@call(.auto, f.?, args ++ .{ &n, @as([*c]T, null) }));
    const items = try gpa.alloc(T, n);
    errdefer gpa.free(items);
    const r = @call(.auto, f.?, args ++ .{ &n, items.ptr });
    if (r != c.VK_SUCCESS and r != c.VK_INCOMPLETE) {
        try check(r);
    }
    return items[0..n];
}

/// `enumerate` for queries that return nothing.
pub fn enumerateVoid(gpa: std.mem.Allocator, comptime T: type, f: anytype, args: anytype) Error![]T {
    var n: u32 = 0;
    @call(.auto, f.?, args ++ .{ &n, @as([*c]T, null) });
    const items = try gpa.alloc(T, n);
    @call(.auto, f.?, args ++ .{ &n, items.ptr });
    return items[0..n];
}
