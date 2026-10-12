//! The system tray (D19): an optional StatusNotifierItem with a
//! com.canonical.dbusmenu menu, on the application's session bus. Nothing
//! is exported until an application creates an item.
//!
//! Imports: dbus, loop.

const std = @import("std");

pub const Item = @import("Item.zig");
pub const Menu = @import("Menu.zig");

/// Test doubles for other modules' tests. Not for production use.
pub const testing = struct {
    /// A stand-in StatusNotifierWatcher.
    pub const Watcher = @import("test_watcher.zig").Watcher;
};

test {
    std.testing.refAllDecls(@This());
    if (comptime @import("integration").enabled) {
        _ = @import("integration_tests.zig");
    } else {
        _ = @import("tests.zig");
    }
}
