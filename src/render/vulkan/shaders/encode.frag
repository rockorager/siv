// Encodes the linear working image for output (D11): sRGB transfer,
// premultiplied in encoded space, 8 bits with the CPU's 8x8 ordered
// dither anchored to device pixels (render/cpu/color.zig, encodeRowT).
// pc.mode bit 0: the output keeps alpha (otherwise alpha is opaque).

layout(location = 0) out vec4 o_color;

const uint bayer8[64] = uint[64](
    0u, 32u, 8u, 40u, 2u, 34u, 10u, 42u,
    48u, 16u, 56u, 24u, 50u, 18u, 58u, 26u,
    12u, 44u, 4u, 36u, 14u, 46u, 6u, 38u,
    60u, 28u, 52u, 20u, 62u, 30u, 54u, 22u,
    3u, 35u, 11u, 43u, 1u, 33u, 9u, 41u,
    51u, 19u, 59u, 27u, 49u, 17u, 57u, 25u,
    15u, 47u, 7u, 39u, 13u, 45u, 5u, 37u,
    63u, 31u, 55u, 23u, 61u, 29u, 53u, 21u
);

void main() {
    ivec2 p = ivec2(floor(gl_FragCoord.xy) + pc.origin);
    uvec4 q = toU16(texelFetch(tex_a, p - ivec2(pc.src_origin), 0));
    bool has_alpha = (pc.mode & 1u) != 0u;
    uint d = bayer8[(p.y & 7) * 8 + (p.x & 7)];
    uvec4 o;
    if (q.a == 65535u || !has_alpha) {
        uint bias = (2u * d + 1u) * 2u;
        o = uvec4(
            min((luts[LUT_TO_SRGB8_8 + q.r] + bias) >> 8, 255u),
            min((luts[LUT_TO_SRGB8_8 + q.g] + bias) >> 8, 255u),
            min((luts[LUT_TO_SRGB8_8 + q.b] + bias) >> 8, 255u),
            255u);
    } else if (q.a == 0u) {
        o = uvec4(0u);
    } else {
        uint a = q.a;
        uint bias = (2u * d + 1u) * 65535u / 128u;
        uint a8 = (a * 255u + 32767u) / 65535u;
        uvec3 e;
        for (int c = 0; c < 3; c++) {
            uint straight = min((q[c] * 65535u + a / 2u) / a, 65535u);
            e[c] = div65535(luts[LUT_TO_SRGB16 + straight] * a);
        }
        o = uvec4(min((e * 255u + bias) / 65535u, uvec3(a8)), a8);
    }
    o_color = vec4(o) / 255.0;
}
