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

test {
    std.testing.refAllDecls(@This());
}
