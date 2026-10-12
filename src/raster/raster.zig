//! Coverage rasterizer (D14) shared by paths and glyph outlines.
//!
//! This is the API the text engine and the renderers build on. It is kept
//! small and stable:
//!
//! - Geometry: `Point`, `Rect`, `IRect`, `Affine` (y-down; PDF/cairo
//!   matrix order).
//! - Paths: `PathBuilder` builds a `Path` with moveTo, lineTo, quadTo,
//!   cubicTo, and close, which map one to one onto HarfBuzz's draw
//!   callbacks (hb_draw_funcs_t). Font units are y-up, so a glyph outline is
//!   fed in with y negated (or through an Affine with d = -scale).
//! - Coverage: `Rasterizer` turns paths (through an Affine) into exact-area
//!   8-bit coverage with the nonzero or even-odd rule, inside an integer
//!   window. Coverage at a pixel does not depend on the window, so tiles and
//!   cached glyphs agree.
//! - Strokes: `Stroker` converts a stroked path into a nonzero fill path
//!   (miter, round, bevel joins; butt, round, square caps; dashes).
//!
//! Everything reuses its buffers: steady-state use allocates nothing.
//!
//! Imports: none.

const std = @import("std");

pub const geom = @import("geom.zig");
pub const Point = geom.Point;
pub const Rect = geom.Rect;
pub const IRect = geom.IRect;
pub const Affine = geom.Affine;

const path = @import("path.zig");
pub const Verb = path.Verb;
pub const Path = path.Path;
pub const PathBuilder = path.PathBuilder;
pub const Radii = path.Radii;
pub const kappa = path.kappa;

const flatten_mod = @import("flatten.zig");
pub const flatten = flatten_mod.flatten;
pub const default_tolerance = flatten_mod.default_tolerance;

const rasterizer = @import("rasterizer.zig");
pub const Rasterizer = rasterizer.Rasterizer;
pub const FillRule = rasterizer.FillRule;
pub const Mask = rasterizer.Mask;

const stroke = @import("stroke.zig");
pub const Stroker = stroke.Stroker;
pub const StrokeStyle = stroke.StrokeStyle;
pub const Join = stroke.Join;
pub const Cap = stroke.Cap;

test {
    std.testing.refAllDecls(@This());
    _ = geom;
    _ = path;
    _ = flatten_mod;
    _ = rasterizer;
    _ = stroke;
}
