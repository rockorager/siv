//! Vulkan renderer (D10, D11): display lists drawn with Vulkan 1.3 (dynamic
//! rendering, synchronization2) in a linear FP16 working space, encoded
//! for output, and presented through the standard Wayland swapchain.
//!
//!     const device = try Device.create(gpa, .{ .wayland_display = display });
//!     const r = try Renderer.create(gpa, device, app_pool.executor());
//!     try r.resize(width, height);
//!     try r.beginFrame();
//!     try r.render(list, .{ .damage = rects }, .{ .readback = ... });
//!
//! `Swapchain` presents a renderer's frames on a wl_surface. Errors include
//! `DeviceLost`; callers fall back to the CPU renderer (D10).
//!
//! Imports: scene, raster, render_cpu (glyph rasterization, the blur
//! contract), pool, vulkan (headers; libvulkan is loaded at run time),
//! shaders (SPIR-V compiled at build time, see build_steps.zig).

const std = @import("std");

pub const vk = @import("vk.zig");
pub const Error = vk.Error;
pub const Device = @import("Device.zig");
pub const Renderer = @import("Renderer.zig");
pub const Swapchain = @import("Swapchain.zig");

/// A device for tests: any Vulkan 1.3 device, lavapipe included, with
/// validation when the layer is installed; error.SkipZigTest without one.
pub fn testDevice(gpa: std.mem.Allocator) !*Device {
    // Mesa's implicit device-select layer connects to Wayland and X to find
    // the default GPU and complains on stderr when there is neither.
    _ = setenv("NODEVICE_SELECT", "1", 0);
    return Device.create(gpa, .{ .allow_cpu = true, .validation = true }) catch |e| switch (e) {
        error.Unavailable => return error.SkipZigTest,
        else => return e,
    };
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
