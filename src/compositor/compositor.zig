//! The compositor thread (D8): one per process. It owns each window's layer
//! tree and all presentation, runs scrolling and transform and opacity
//! animations on its own, sampled at each frame's predicted presentation
//! time (D12), and renders damaged regions on the application's worker
//! pool.
//!
//! The UI thread talks to it only through layer updates (update.zig):
//!
//!     const seq = try compositor.commit(window, &.{
//!         .{ .create = 1 },
//!         .{ .set_content = .{ .layer = 1, .content = .{ .list = list, .builder = builder } } },
//!         .{ .set_root = 1 },
//!     });
//!
//! and gets `Event`s back on its own loop.
//!
//! Imports: scene, raster, render_cpu, pool, loop, platform.

const std = @import("std");

const update = @import("update.zig");
pub const LayerId = update.LayerId;
pub const WindowId = update.WindowId;
pub const Size = update.Size;
pub const Transform = update.Transform;
pub const Clip = update.Clip;
pub const Scroll = update.Scroll;
pub const Easing = update.Easing;
pub const Property = update.Property;
pub const Value = update.Value;
pub const Animation = update.Animation;
pub const Content = update.Content;
pub const Op = update.Op;
pub const Event = update.Event;
pub const configure_timeout_ns = update.configure_timeout_ns;

pub const Compositor = @import("Compositor.zig");
pub const Options = Compositor.Options;
pub const Backend = Compositor.Backend;
pub const Sink = Compositor.Sink;
pub const surface = @import("surface.zig");

test {
    std.testing.refAllDecls(@This());
    _ = update;
    _ = @import("anim.zig");
    _ = @import("tree.zig");
    _ = @import("tests.zig");
}
