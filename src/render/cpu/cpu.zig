//! CPU renderer (D10, D11): tiled rendering of display lists in linear light
//! across the worker pool. The golden-image oracle.
//!
//! Imports: scene, raster, text.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
