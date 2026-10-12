//! Accessibility (D18): the AT-SPI bridge that publishes the semantics
//! trees of an application's windows over D-Bus.
//!
//! Imports: dbus, ui, loop, raster, text.

const std = @import("std");

pub const atspi = @import("atspi.zig");
pub const Bridge = @import("Bridge.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("textutil.zig");
    _ = @import("iface.zig");
    if (comptime @import("integration").enabled) {
        _ = @import("integration_tests.zig");
    } else {
        _ = @import("tests.zig");
    }
}
