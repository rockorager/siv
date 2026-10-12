//! Display lists (D9): immutable lists of paths, gradients, images, text
//! runs, clips, layers with opacity, affine transforms, and backdrop blur,
//! with per-layer damage. One contract for the CPU renderer, Vulkan, and PDF.
//!
//! Imports: none.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
