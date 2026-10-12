//! XDG desktop portals (D19): the file chooser, OpenURI, notifications,
//! inhibition, global shortcuts, screenshots and screen casts, printing,
//! and the document portal, as clients of xdg-desktop-portal on siv's
//! own D-Bus connection. They work the same inside Flatpak and outside.
//! Also org.freedesktop.Application, for single instance and D-Bus
//! activation (application.zig).
//!
//! Most portal calls follow the request/response pattern (`Request`):
//! the reply names a request object, and the result arrives later as its
//! Response signal. Window-modal dialogs take a parent window identifier,
//! "wayland:<handle>" from an xdg-foreign-v2 export (made by the
//! application coordinator), or an empty string.
//!
//! Callbacks run at safe points (D5) on the connection's loop. Every
//! operation is a caller-owned struct that stays in place while it runs.
//!
//! Imports: dbus, loop.

const std = @import("std");

pub const Client = @import("Client.zig");
pub const Request = @import("Request.zig");
pub const Session = @import("Session.zig");
pub const vardict = @import("vardict.zig");
pub const uri = @import("uri.zig");
pub const file_chooser = @import("file_chooser.zig");
pub const open_uri = @import("open_uri.zig");
pub const notification = @import("notification.zig");
pub const inhibit = @import("inhibit.zig");
pub const screenshot = @import("screenshot.zig");
pub const screencast = @import("screencast.zig");
pub const global_shortcuts = @import("global_shortcuts.zig");
pub const documents = @import("documents.zig");
pub const application = @import("application.zig");

pub const Response = Request.Response;
pub const Failure = Request.Failure;

/// Test doubles for other modules' tests. Not for production use.
pub const testing = struct {
    /// A stand-in for xdg-desktop-portal's frontend on a test bus.
    pub const Frontend = @import("test_frontend.zig").Frontend;
    /// The real xdg-desktop-portal with siv's backend behind it, for
    /// integration tests.
    pub const Desktop = @import("test_desktop.zig").Desktop;
    pub const Backend = @import("test_desktop.zig").Backend;
    /// dbus-daemon and process helpers.
    pub const daemon = @import("dbus").testing.daemon;
};

test {
    std.testing.refAllDecls(@This());
    if (comptime @import("integration").enabled) {
        _ = @import("integration_tests.zig");
    } else {
        _ = @import("tests.zig");
    }
}
