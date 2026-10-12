//! Display lists (D9): immutable lists of paths, gradients, images, glyph
//! runs, clips, layers with opacity and blend modes, affine transforms, and
//! backdrop blur, with per-layer damage. One contract for the CPU renderer,
//! Vulkan, and PDF.
//!
//! Build a list with `Builder` (reused per frame slot, so steady-state
//! frames allocate nothing), hand the immutable `DisplayList` to a
//! renderer, and compute what changed with `damage.Tracker`.
//!
//! Imports: raster (geometry, paths, fill rules, stroke styles).

const std = @import("std");
const raster = @import("raster");

const list = @import("list.zig");
pub const Color = list.Color;
pub const srgbToLinear = list.srgbToLinear;
pub const linearToSrgb = list.linearToSrgb;
pub const Extend = list.Extend;
pub const Stop = list.Stop;
pub const Gradient = list.Gradient;
pub const Paint = list.Paint;
pub const RoundedRect = list.RoundedRect;
pub const Shape = list.Shape;
pub const BlendMode = list.BlendMode;
pub const Clip = list.Clip;
pub const Layer = list.Layer;
pub const Push = list.Push;
pub const Fill = list.Fill;
pub const Stroke = list.Stroke;
pub const Font = list.Font;
pub const Glyph = list.Glyph;
pub const GlyphRun = list.GlyphRun;
pub const ImageFormat = list.ImageFormat;
pub const ImageRef = list.ImageRef;
pub const Filter = list.Filter;
pub const Image = list.Image;
pub const BackdropBlur = list.BackdropBlur;
pub const Command = list.Command;
pub const DisplayList = list.DisplayList;
pub const Builder = list.Builder;
pub const Error = list.Error;
pub const max_blur_sigma = list.max_blur_sigma;
pub const CountingAllocator = list.CountingAllocator;

pub const FillRule = raster.FillRule;
pub const StrokeStyle = raster.StrokeStyle;

pub const damage = @import("damage.zig");

test {
    std.testing.refAllDecls(@This());
    _ = list;
    _ = damage;
}
