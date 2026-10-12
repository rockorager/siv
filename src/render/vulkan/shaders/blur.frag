// One separable blur pass along pc.dir over pc.region: a box of radius
// pc.radius (mode 0) or the normalized Gaussian kernel in
// kernels[pc.kernel .. pc.kernel + 2 * radius] (mode 1). Reads clamp to
// pc.clampr, the backdrop region, as the CPU's blurLine does (D10).

layout(location = 0) out vec4 o_color;

void main() {
    ivec2 p = ivec2(floor(gl_FragCoord.xy) + pc.origin);
    ivec2 lo = pc.clampr.xy;
    ivec2 hi = pc.clampr.zw - 1;
    ivec2 so = ivec2(pc.src_origin);
    int r = int(pc.radius);
    vec4 acc = vec4(0.0);
    for (int k = -r; k <= r; k++) {
        ivec2 q = clamp(p + pc.dir * k, lo, hi);
        vec4 v = texelFetch(tex_a, q - so, 0);
        acc += pc.mode == 0u ? v : v * kernels[pc.kernel + uint(k + r)];
    }
    o_color = pc.mode == 0u ? acc * (1.0 / float(2 * r + 1)) : acc;
}
