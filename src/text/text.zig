//! Text engine (D13, D14, D15): font discovery and fallback, shaping, bidi,
//! line breaking, and paragraph layout.
//!
//! Imports: raster, harfbuzz, sheenbidi, fontconfig, uucode. Unicode test
//! data is available through @embedFile, e.g. @embedFile("LineBreakTest.txt");
//! see build.zig for the list.

const std = @import("std");

pub const line_break = @import("line_break.zig");
pub const segmentation = @import("segmentation.zig");
pub const Boundaries = @import("boundaries.zig");
pub const bidi = @import("bidi.zig");
pub const script = @import("script.zig");
pub const font = @import("font.zig");
pub const fontconfig = @import("fontconfig.zig");
pub const shape = @import("shape.zig");
pub const paragraph = @import("paragraph.zig");

test {
    std.testing.refAllDecls(@This());
}
