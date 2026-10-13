//! Text engine (D13, D14, D15): font discovery and fallback, shaping, bidi,
//! line breaking, and paragraph layout.
//!
//! Pipeline: a text node builds a width-independent `ShapedParagraph` from
//! its text and styles, then a `Layout` for each width. Fonts live in the
//! `FontCache`, the only cache; Fontconfig (`fontconfig.Database`) finds
//! them, and the caller reads their bytes, so nothing here blocks on I/O.
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
pub const family = @import("family.zig");
pub const hyphen = @import("hyphen.zig");
pub const shape = @import("shape.zig");
pub const paragraph = @import("paragraph.zig");
pub const layout = @import("layout.zig");
pub const cursor = @import("cursor.zig");
pub const blocks = @import("blocks.zig");
pub const rope = @import("rope.zig");

pub const FontId = font.FontId;
pub const FontCache = font.FontCache;
pub const Face = font.Face;
pub const BaseDirection = bidi.BaseDirection;
pub const Style = paragraph.Style;
pub const StyleRun = paragraph.StyleRun;
pub const ShapedParagraph = paragraph.ShapedParagraph;
pub const Layout = layout.Layout;
pub const ShapedText = blocks.ShapedText;
pub const TextLayout = blocks.TextLayout;
pub const Rope = rope.Rope;

test {
    std.testing.refAllDecls(@This());
}
