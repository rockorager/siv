//! The document renderer (D32): HTML and Markdown documents styled with
//! CSS, laid out with siv's text engine, and painted into display lists.
//!
//! Imports: html, markdown, css, text, scene, raster, image, svg.

const std = @import("std");

pub const Document = @import("Document.zig");
pub const cascade = @import("cascade.zig");
pub const box = @import("box.zig");
pub const layout = @import("layout.zig");
pub const inline_layout = @import("inline.zig");
pub const paint = @import("paint.zig");
pub const url = @import("url.zig");
pub const ua = @import("ua.zig");
pub const sysfonts = @import("sysfonts.zig");

pub const Palette = paint.Palette;
pub const Hooks = paint.Hooks;
pub const Highlight = paint.Highlight;

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
