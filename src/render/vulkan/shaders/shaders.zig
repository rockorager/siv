//! The shaders' SPIR-V, compiled from the GLSL beside it by `zig build
//! shaders` and committed, so that builds need no shader compiler (D10).
//! `glsl.sha256` holds the hashes of the GLSL it was compiled from, which
//! the render_vulkan tests compare with `glsl` (Device.zig).

pub const quad_vert = @embedFile("quad.vert.spv");
pub const draw_frag = @embedFile("draw.frag.spv");
pub const blur_frag = @embedFile("blur.frag.spv");
pub const encode_frag = @embedFile("encode.frag.spv");

/// `sha256sum` output for the files below.
pub const glsl_sha256 = @embedFile("glsl.sha256");

pub const glsl = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "common.glsl", .text = @embedFile("common.glsl") },
    .{ .name = "quad.vert", .text = @embedFile("quad.vert") },
    .{ .name = "draw.frag", .text = @embedFile("draw.frag") },
    .{ .name = "blur.frag", .text = @embedFile("blur.frag") },
    .{ .name = "encode.frag", .text = @embedFile("encode.frag") },
};
