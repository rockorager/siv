//! Platform backends (D7, D12, D16, D17, D20): Wayland through libwayland-
//! client with wl_shm presentation, xkbcommon input, and the headless backend
//! that runs the same loop for tests.
//!
//! Imports: loop, wayland (zig-wayland bindings; protocols are listed in
//! protocols.zig), xkbcommon.

const std = @import("std");
const wayland = @import("wayland");
const xkb = @import("xkbcommon");

test {
    std.testing.refAllDecls(@This());
}

test "C dependencies link" {
    const context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_DEFAULT_INCLUDES) orelse return error.OutOfMemory;
    defer xkb.xkb_context_unref(context);

    // Referencing the function checks that the generated bindings compile
    // and that libwayland-client links, without needing a compositor.
    _ = &wayland.client.wl.Display.connect;
}
