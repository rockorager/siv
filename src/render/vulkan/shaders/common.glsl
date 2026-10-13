#version 460

// Declarations shared by every shader; build_steps.zig prepends this file.
// Layouts match Renderer.zig (Inst, PaintRec, Stop, ClipRec) and
// Device.zig (Push, bindings).
//
// Everything is evaluated in device pixels, at pixel centers, with the CPU
// renderer's formulas (src/render/cpu), so that the two agree (D10).

// Coverage kinds. Coverage is an 8-bit value (0..255), as on the CPU.
const uint COV_FULL = 0u;
const uint COV_RECT = 1u;
const uint COV_RRECT = 2u;
const uint COV_MASK = 3u;
const uint COV_GLYPH = 4u;
// An analytic box shadow (render/cpu/shadow.zig), 16-bit; two paint
// records from aux.
const uint COV_SHADOW = 5u;

// Paint kinds.
const uint PAINT_SOLID = 0u;
const uint PAINT_LINEAR = 1u;
const uint PAINT_RADIAL = 2u;
const uint PAINT_SWEEP = 3u;
const uint PAINT_IMAGE = 4u;
// tex_a's texel at the pixel (layers), scaled by color.a.
const uint PAINT_TEXEL = 5u;
// Replace pipeline: a layer composited with a blend mode over a copy of
// its backdrop.
const uint PAINT_BLEND = 6u;
// Replace pipeline: a blurred backdrop mixed into its copy by coverage.
const uint PAINT_BLUR = 7u;
// The color glyph atlas texel at the pixel.
const uint PAINT_GLYPH = 8u;

struct Inst {
    ivec4 quad;  // device pixels [x0, x1) x [y0, y1)
    uint cov;
    uint paint;
    uint clip;   // clip record + 1; 0 for none
    uint aux;    // paint record or blend mode
    vec4 color;  // premultiplied solid color; .a scales texel paints
    vec4 g0;     // coverage rectangle (device)
    vec4 g1;     // corner radii: tl, tr
    vec4 g2;     // corner radii: br, bl
    ivec4 tex;   // coverage texture: mask layer, device x and y of texel (0, 0), and the
                 // mask size (width | height << 16) or the glyph contrast table
    ivec4 ptex;  // paint texture (tex_a or the color glyph atlas): device x and y of texel (0, 0) in .yz
    ivec4 btex;  // backdrop texture (tex_b), the same way
    ivec4 hole;  // part of quad not drawn (x0 >= x1: none)
};

struct PaintRec {
    vec4 inv0;   // device to paint space: a, b, c, d
    vec4 inv1;   // e, f
    vec4 geo0;   // linear: p0, p1; radial: c0, r0, c1.x; sweep: center, start, end
    vec4 geo1;   // radial: c1.y, r1
    uvec4 meta;  // gradients: first stop, stop count, extend; images: format (see texel), filter, opacity (u16)
    ivec4 range; // images: texel range sampling clamps to
};

struct Stop {
    vec4 color;  // premultiplied
    vec4 offset; // .x
};

struct ClipRec {
    uint kind;
    uint parent; // clip record + 1; 0 for none
    uint pad0;
    uint pad1;
    vec4 g0;
    vec4 g1;
    vec4 g2;
    ivec4 tex;
};

layout(std430, set = 0, binding = 0) readonly buffer Insts { Inst insts[]; };
layout(std430, set = 0, binding = 1) readonly buffer Paints { PaintRec paints[]; };
layout(std430, set = 0, binding = 2) readonly buffer Stops { Stop stops[]; };
layout(std430, set = 0, binding = 3) readonly buffer Clips { ClipRec clips[]; };
// 16 contrast tables of 256 entries, then sRGB byte to linear u16 (256),
// linear u16 to sRGB u16 (65536), linear u16 to sRGB 8.8 fixed (65536).
layout(std430, set = 0, binding = 4) readonly buffer Luts { uint luts[]; };
layout(std430, set = 0, binding = 5) readonly buffer Kernels { float kernels[]; };
layout(set = 0, binding = 6) uniform sampler2D glyph_masks;
layout(set = 0, binding = 7) uniform sampler2D glyph_colors;
layout(set = 0, binding = 8) uniform sampler2DArray masks;
// Draw-specific textures: an image, a layer, a blur input, the working
// image (tex_a), and a backdrop copy (tex_b).
layout(set = 1, binding = 0) uniform sampler2D tex_a;
layout(set = 1, binding = 1) uniform sampler2D tex_b;

const uint LUT_SRGB8 = 16u * 256u;
const uint LUT_TO_SRGB16 = LUT_SRGB8 + 256u;
const uint LUT_TO_SRGB8_8 = LUT_TO_SRGB16 + 65536u;

layout(push_constant) uniform Push {
    vec2 origin;      // device coordinates of target pixel (0, 0)
    vec2 size;        // target size
    ivec4 region;     // quad for passes without instances; empty otherwise
    ivec4 clampr;     // blur: reads clamp to this rectangle
    uint pieces;     // instance draws: four quads around each instance's hole
    uint mode;
    uint radius;
    uint kernel;
    vec2 src_origin;  // device coordinates of tex_a's texel (0, 0)
    ivec2 dir;
} pc;


// x / 65535 rounded (color.div65535).
uint div65535(uint x) {
    uint t = x + 32768u;
    return (t + (t >> 16)) >> 16;
}

uvec4 div65535v(uvec4 x) {
    uvec4 t = x + 32768u;
    return (t + (t >> 16)) >> 16;
}

uvec4 toU16(vec4 v) {
    return uvec4(clamp(v, 0.0, 1.0) * 65535.0 + 0.5);
}
