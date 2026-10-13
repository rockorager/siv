//! CPU renderer (D10, D11): tiled rendering of display lists in linear
//! light, 16 bits per channel, across a worker pool, with output encoded
//! for wl_shm buffers. Only damaged tiles are redrawn. It is the golden-
//! image oracle for the Vulkan renderer.
//!
//!     const r = try Renderer.create(gpa, app_pool.executor());
//!     try r.resize(width, height);
//!     try r.render(list, .{ .damage = rects, .target = .{
//!         .pixels = shm_bytes, .stride = stride, .format = .argb8888,
//!     } });
//!
//! Glyph runs are rasterized through HarfBuzz draw/paint (COLRv1
//! included) into the shared coverage rasterizer and cached (glyph.zig).
//!
//! Imports: scene, raster, text, harfbuzz.

const std = @import("std");

const renderer = @import("renderer.zig");
pub const Renderer = renderer.Renderer;
pub const Options = renderer.Options;
pub const Target = renderer.Target;
pub const tile_size = renderer.tile_size;
/// Box radii of the backdrop blur contract, shared with Vulkan.
pub const boxRadii = renderer.boxRadii;

const color = @import("color.zig");
pub const Format = color.Format;
pub const Pixel = color.Pixel;
pub const encodeRow = color.encodeRow;
pub const Luts = color.Luts;

/// Rendering runs on the application's worker pool through this fork-join
/// contract (see the `pool` module); `Executor.serial` renders inline.
pub const Executor = @import("pool").Executor;

pub const glyph = @import("glyph.zig");
pub const shadow = @import("shadow.zig");
pub const paint = @import("paint.zig");

test {
    std.testing.refAllDecls(@This());
    _ = renderer;
    _ = color;
    _ = @import("blend.zig");
    _ = @import("coverage.zig");
    _ = glyph;
    _ = shadow;
}
