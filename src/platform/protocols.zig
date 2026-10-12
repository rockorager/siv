//! Wayland protocols that zig-wayland generates bindings for. build.zig
//! imports this file, so it must only use plain data. Owned by the platform
//! workstream: add protocols here without editing build.zig.
//!
//! Paths are relative to the pinned wayland-protocols release in
//! build.zig.zon. The core protocol (wayland.xml) is always included.

/// Protocol XML files to scan.
pub const xml = [_][]const u8{
    "stable/xdg-shell/xdg-shell.xml",
    "stable/viewporter/viewporter.xml",
    "stable/presentation-time/presentation-time.xml",
    "staging/fractional-scale/fractional-scale-v1.xml",
    "staging/fifo/fifo-v1.xml",
    "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",
};

/// Globals to bind, each with the highest version siv implements. Code is
/// generated for each global and every interface reachable from it at that
/// version; requests and events from newer versions are omitted.
pub const globals = [_]struct { []const u8, u32 }{
    .{ "wl_compositor", 6 },
    .{ "wl_subcompositor", 1 },
    .{ "wl_shm", 2 },
    .{ "wl_seat", 9 },
    .{ "wl_output", 4 },
    .{ "wl_data_device_manager", 3 },
    .{ "xdg_wm_base", 6 },
    .{ "wp_viewporter", 1 },
    .{ "wp_presentation", 2 },
    .{ "wp_fractional_scale_manager_v1", 1 },
    .{ "wp_fifo_manager_v1", 1 },
    .{ "zxdg_decoration_manager_v1", 1 },
};
