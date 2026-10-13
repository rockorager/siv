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
    "unstable/text-input/text-input-unstable-v3.xml",
    "unstable/primary-selection/primary-selection-unstable-v1.xml",
    "stable/linux-dmabuf/linux-dmabuf-v1.xml",
    "staging/cursor-shape/cursor-shape-v1.xml",
    "stable/tablet/tablet-v2.xml",
    "unstable/pointer-gestures/pointer-gestures-unstable-v1.xml",
    "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml",
    "unstable/relative-pointer/relative-pointer-unstable-v1.xml",
    "unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml",
    "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml",
    "staging/xdg-dialog/xdg-dialog-v1.xml",
    "staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml",
    "staging/xdg-session-management/xdg-session-management-v1.xml",
    "unstable/xdg-foreign/xdg-foreign-unstable-v2.xml",
    "staging/xdg-activation/xdg-activation-v1.xml",
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
    .{ "zwp_text_input_manager_v3", 1 },
    .{ "zwp_primary_selection_device_manager_v1", 1 },
    // Only for the compositor's main device (default feedback, D10).
    .{ "zwp_linux_dmabuf_v1", 4 },
    .{ "wp_cursor_shape_manager_v1", 2 },
    // Parent window handles for portal dialogs (D19).
    .{ "zxdg_exporter_v2", 1 },
    // Focus handoff between applications (D17, D19).
    .{ "xdg_activation_v1", 1 },
    // Input on request (D16): tablets and pads, touchpad gestures, pointer
    // lock and confinement with relative motion, and shortcut inhibition.
    .{ "zwp_tablet_manager_v2", 2 },
    .{ "zwp_pointer_gestures_v1", 3 },
    .{ "zwp_pointer_constraints_v1", 1 },
    .{ "zwp_relative_pointer_manager_v1", 1 },
    .{ "zwp_keyboard_shortcuts_inhibit_manager_v1", 1 },
    // Windows (D17): idle inhibition, modal dialogs, icons, session restore.
    .{ "zwp_idle_inhibit_manager_v1", 1 },
    .{ "xdg_wm_dialog_v1", 1 },
    .{ "xdg_toplevel_icon_manager_v1", 1 },
    .{ "xdg_session_manager_v1", 1 },
};
