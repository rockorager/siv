// Every draw: coverage (analytic rectangles and rounded rectangles, masks
// of CPU-rasterized coverage, glyph masks) times the clip chain, times a
// paint. The draw pipeline blends premultiplied source-over; the replace
// pipeline writes PAINT_BLEND and PAINT_BLUR results as they are, and a
// discarded fragment keeps the destination.
//
// Formulas follow src/render/cpu: coverage.zig, paint.zig, blend.zig.

layout(location = 0) flat in uint v_inst;
layout(location = 0) out vec4 o_color;

// Coverage ------------------------------------------------------------------

float overlap(float lo, float hi, float p) {
    return clamp(min(p + 1.0, hi) - max(p, lo), 0.0, 1.0);
}

float ellipseDistance(vec2 q, vec2 r) {
    if (r.x <= 0.0 || r.y <= 0.0) return -1e9;
    if (r.x == r.y) return length(q) - r.x;
    float k0 = length(q / r);
    float k1 = length(q / (r * r));
    if (k1 == 0.0) return -min(r.x, r.y);
    return k0 * (k0 - 1.0) / k1;
}

float rrectCoverage(vec4 r, vec4 g1, vec4 g2, vec2 px) {
    float c = overlap(r.x, r.z, px.x) * overlap(r.y, r.w, px.y);
    vec2 p = px + 0.5;
    if (c > 0.0) {
        vec2 center = vec2(0.0);
        vec2 radius = vec2(0.0);
        bool corner = true;
        if (p.x < r.x + g1.x && p.y < r.y + g1.y) {
            center = vec2(r.x + g1.x, r.y + g1.y);
            radius = g1.xy;
        } else if (p.x > r.z - g1.z && p.y < r.y + g1.w) {
            center = vec2(r.z - g1.z, r.y + g1.w);
            radius = g1.zw;
        } else if (p.x > r.z - g2.x && p.y > r.w - g2.y) {
            center = vec2(r.z - g2.x, r.w - g2.y);
            radius = g2.xy;
        } else if (p.x < r.x + g2.z && p.y > r.w - g2.w) {
            center = vec2(r.x + g2.z, r.w - g2.w);
            radius = g2.zw;
        } else {
            corner = false;
        }
        if (corner) c = min(c, clamp(0.5 - ellipseDistance(p - center, radius), 0.0, 1.0));
    }
    return floor(c * 255.0 + 0.5);
}

float maskCoverage(ivec4 tex, vec2 px) {
    ivec2 p = ivec2(px) - tex.yz;
    ivec2 size = ivec2(tex.w & 0xffff, tex.w >> 16);
    if (any(lessThan(p, ivec2(0))) || any(greaterThanEqual(p, size))) return 0.0;
    return floor(texelFetch(masks, ivec3(p, tex.x), 0).r * 255.0 + 0.5);
}

float glyphCoverage(ivec4 tex, vec2 px) {
    return floor(texelFetch(glyph_masks, ivec2(px) - tex.yz, 0).r * 255.0 + 0.5);
}

float shapeCoverage(uint kind, vec4 g0, vec4 g1, vec4 g2, ivec4 tex, vec2 px) {
    if (kind == COV_RECT) return floor(overlap(g0.x, g0.z, px.x) * overlap(g0.y, g0.w, px.y) * 255.0 + 0.5);
    if (kind == COV_RRECT) return rrectCoverage(g0, g1, g2, px);
    if (kind == COV_MASK) return maskCoverage(tex, px);
    return 255.0;
}

// Clip masks multiply from the outermost clip inward with the CPU's
// rounding: m = (own * parent + 127) / 255.
const int max_clip_depth = 32;

float clipCoverage(uint index, vec2 px) {
    float own[max_clip_depth];
    int n = 0;
    while (index != 0u && n < max_clip_depth) {
        ClipRec c = clips[index - 1u];
        own[n] = shapeCoverage(c.kind, c.g0, c.g1, c.g2, c.tex, px);
        n++;
        index = c.parent;
    }
    float m = 255.0;
    for (int i = n - 1; i >= 0; i--) {
        m = (i == n - 1) ? own[i] : floor((own[i] * m + 127.0) / 255.0);
    }
    return m;
}

// Box shadows (render/cpu/shadow.zig, formula for formula) -------------------

float erfAS(float x) {
    float a = abs(x);
    if (a >= 4.0) return x < 0.0 ? -1.0 : 1.0;
    float d = 1.0 + a * (0.278393 + a * (0.230389 + a * (0.000972 + a * 0.078108)));
    float d2 = d * d;
    float y = 1.0 - 1.0 / (d2 * d2);
    return x < 0.0 ? -y : y;
}

float cornerInset(float dy, float ry) {
    float d = dy / ry;
    return 1.0 - sqrt(max(0.0, 1.0 - d * d));
}

// The row [xl, xr] of rounded rect r (radii tl, tr in g1; br, bl in g2).
vec2 rowSpan(vec4 r, vec4 g1, vec4 g2, float y) {
    float xl = r.x;
    float xr = r.z;
    if (g1.y > 0.0 && y < r.y + g1.y) xl = max(xl, r.x + g1.x * cornerInset(r.y + g1.y - y, g1.y));
    if (g2.w > 0.0 && y > r.w - g2.w) xl = max(xl, r.x + g2.z * cornerInset(y - (r.w - g2.w), g2.w));
    if (g1.w > 0.0 && y < r.y + g1.w) xr = min(xr, r.z - g1.z * cornerInset(r.y + g1.w - y, g1.w));
    if (g2.y > 0.0 && y > r.w - g2.y) xr = min(xr, r.z - g2.x * cornerInset(y - (r.w - g2.y), g2.y));
    return vec2(xl, xr);
}

float shadowBand(vec4 r, vec4 g1, vec4 g2, float sigma, float k, vec2 q, float edge, float height, float a, float b) {
    if (!(a < b) || height == 0.0) return 0.0;
    const float half_pi = 3.14159265358979323846 / 2.0;
    float ua = acos(clamp(1.0 - (a - edge) / height, -1.0, 1.0)) / half_pi;
    float ub = acos(clamp(1.0 - (b - edge) / height, -1.0, 1.0)) / half_pi;
    int n = int(clamp(ceil(2.0 * (b - a) / sigma), 4.0, 16.0));
    float du = (ub - ua) / float(n);
    float norm = 1.0 / (sigma * sqrt(2.0 * 3.14159265358979323846));
    float sum = 0.0;
    for (int i = 0; i < n; i++) {
        float u = ua + (float(i) + 0.5) * du;
        float y = edge + height * (1.0 - cos(u * half_pi));
        vec2 sp = rowSpan(r, g1, g2, y);
        if (!(sp.y > sp.x)) continue;
        float dy = abs(height * sin(u * half_pi) * half_pi * du);
        float t = q.y - y;
        sum += exp(-t * t * (k * k)) * norm * dy * 0.5 * (erfAS((q.x - sp.x) * k) - erfAS((q.x - sp.y) * k));
    }
    return sum;
}

float shadowBlurred(vec4 r, vec4 g1, vec4 g2, float sigma, vec2 q) {
    const float reach = 4.0;
    float k = 1.0 / (sigma * 1.41421356237309504880);
    float lo = max(r.y, q.y - reach * sigma);
    float hi = min(r.w, q.y + reach * sigma);
    if (!(lo < hi)) return 0.0;
    float c1 = min(r.y + max(g1.y, g1.w), r.w);
    float c2 = max(r.w - max(g2.w, g2.y), c1);
    float sum = 0.0;
    float mlo = max(lo, c1);
    float mhi = min(hi, c2);
    if (mlo < mhi) sum += 0.25 * (erfAS((q.x - r.x) * k) - erfAS((q.x - r.z) * k)) * (erfAS((q.y - mlo) * k) - erfAS((q.y - mhi) * k));
    sum += shadowBand(r, g1, g2, sigma, k, q, r.y, c1 - r.y, lo, min(hi, c1));
    sum += shadowBand(r, g1, g2, sigma, k, q, r.w, c2 - r.w, max(lo, c2), hi);
    return sum;
}

float shadowDistance(vec4 r, vec4 g1, vec4 g2, vec2 q) {
    if (g1.x > 0.0 && g1.y > 0.0 && q.x < r.x + g1.x && q.y < r.y + g1.y) return ellipseDistance(q - vec2(r.x + g1.x, r.y + g1.y), g1.xy);
    if (g1.z > 0.0 && g1.w > 0.0 && q.x > r.z - g1.z && q.y < r.y + g1.w) return ellipseDistance(q - vec2(r.z - g1.z, r.y + g1.w), g1.zw);
    if (g2.x > 0.0 && g2.y > 0.0 && q.x > r.z - g2.x && q.y > r.w - g2.y) return ellipseDistance(q - vec2(r.z - g2.x, r.w - g2.y), g2.xy);
    if (g2.z > 0.0 && g2.w > 0.0 && q.x < r.x + g2.z && q.y > r.w - g2.w) return ellipseDistance(q - vec2(r.x + g2.z, r.w - g2.w), g2.zw);
    float dx = max(r.x - q.x, q.x - r.z);
    float dy = max(r.y - q.y, q.y - r.w);
    if (dx > 0.0 && dy > 0.0) return sqrt(dx * dx + dy * dy);
    return max(dx, dy);
}

// rec0: inverse (inv0, inv1.xy), scale (inv1.z), sigma (inv1.w), the
// casting rect (geo0), the blurred rect (geo1), inset and empty (meta.xy);
// rec1: casting radii (inv0, inv1), blurred radii (geo0, geo1).
float shadowAlpha(PaintRec a, PaintRec b, vec2 p) {
    vec2 q = vec2(a.inv0.x * p.x + a.inv0.z * p.y + a.inv1.x, a.inv0.y * p.x + a.inv0.w * p.y + a.inv1.y);
    float c = clamp(0.5 - a.inv1.z * shadowDistance(a.geo0, b.inv0, b.inv1, q), 0.0, 1.0);
    float bl = a.meta.y != 0u ? 0.0 : shadowBlurred(a.geo1, b.geo0, b.geo1, a.inv1.w, q);
    return a.meta.x != 0u ? c * (1.0 - bl) : bl * (1.0 - c);
}

// Paints ----------------------------------------------------------------------

vec4 toPixel(vec4 c) {
    float a = clamp(c.a, 0.0, 1.0);
    return vec4(min(clamp(c.rgb, 0.0, 1.0), vec3(a)), a);
}

vec4 colorInRange(uint first, uint n, float t) {
    uint i = 1u;
    while (i < n - 1u && stops[first + i].offset.x < t) i++;
    Stop a = stops[first + i - 1u];
    Stop b = stops[first + i];
    float w = b.offset.x - a.offset.x;
    if (w <= 0.0) return b.color;
    float f = clamp((t - a.offset.x) / w, 0.0, 1.0);
    return a.color + (b.color - a.color) * f;
}

vec4 gradient(PaintRec p, uint kind, vec2 pos) {
    float qx = pos.x * p.inv0.x + (p.inv0.z * pos.y + p.inv1.x);
    float qy = pos.x * p.inv0.y + (p.inv0.w * pos.y + p.inv1.y);
    float t = 0.0;
    bool valid = true;
    if (kind == PAINT_LINEAR) {
        float dx = p.geo0.z - p.geo0.x;
        float dy = p.geo0.w - p.geo0.y;
        float dd = dx * dx + dy * dy;
        if (dd == 0.0) {
            valid = false;
        } else {
            t = ((qx - p.geo0.x) * dx + (qy - p.geo0.y) * dy) / dd;
        }
    } else if (kind == PAINT_RADIAL) {
        vec2 c0 = p.geo0.xy;
        float r0 = p.geo0.z;
        vec2 c1 = vec2(p.geo0.w, p.geo1.x);
        float r1 = p.geo1.y;
        float cdx = c1.x - c0.x;
        float cdy = c1.y - c0.y;
        float dr = r1 - r0;
        float a = cdx * cdx + cdy * cdy - dr * dr;
        float pdx = qx - c0.x;
        float pdy = qy - c0.y;
        float b = pdx * cdx + pdy * cdy + r0 * dr;
        float c = pdx * pdx + pdy * pdy - r0 * r0;
        if (abs(a) < 1e-6 * max(1.0, cdx * cdx + cdy * cdy + dr * dr)) {
            float tt = c / (2.0 * b);
            t = tt;
            valid = b != 0.0 && r0 + tt * dr >= 0.0;
        } else {
            float disc = b * b - a * c;
            float sq = sqrt(max(disc, 0.0));
            float t1 = (b + sq) / a;
            float t2 = (b - sq) / a;
            float hi = max(t1, t2);
            float lo = min(t1, t2);
            bool hi_ok = r0 + hi * dr >= 0.0;
            bool lo_ok = r0 + lo * dr >= 0.0;
            t = hi_ok ? hi : lo;
            valid = disc >= 0.0 && (hi_ok || lo_ok);
        }
    } else {
        float span = p.geo0.w - p.geo0.z;
        if (span == 0.0) {
            valid = false;
        } else {
            float angle = atan(qy - p.geo0.y, qx - p.geo0.x);
            if (angle < 0.0) angle += 2.0 * 3.14159265358979323846;
            t = (angle - p.geo0.z) / span;
        }
    }
    if (!valid) return vec4(0.0);
    uint first = p.meta.x;
    uint n = p.meta.y;
    uint extend = p.meta.z;
    float lo = stops[first].offset.x;
    float hi = stops[first + n - 1u].offset.x;
    if (n == 1u) return toPixel(stops[first].color);
    if (hi <= lo) return toPixel(t < lo ? stops[first].color : stops[first + n - 1u].color);
    float span = hi - lo;
    if (extend == 0u) {
        t = min(max(t, lo), hi);
    } else if (extend == 1u) {
        t = lo + (t - lo) - span * floor((t - lo) / span);
    } else {
        float two = 2.0 * span;
        float u = (t - lo) - two * floor((t - lo) / two);
        t = lo + (u > span ? two - u : u);
    }
    return toPixel(colorInRange(first, n, t));
}

int clampI(float v, int lo, int hi) {
    if (!(v >= float(lo))) return lo;
    if (v >= float(hi - 1)) return hi - 1;
    return int(v);
}

// Premultiplied linear u16 texel (paint.texel). Formats: 0 sRGB 8-bit with
// alpha, 1 linear premultiplied 16-bit, 2 sRGB 8-bit opaque.
uvec4 texel(uint format, int x, int y) {
    vec4 v = texelFetch(tex_a, ivec2(x, y), 0);
    if (format == 1u) return uvec4(v * 65535.0 + 0.5);
    uvec4 b = uvec4(v * 255.0 + 0.5);
    uint a16 = format == 2u ? 65535u : b.a * 257u; // 2: opaque, fourth byte ignored
    return uvec4(div65535(luts[LUT_SRGB8 + b.r] * a16), div65535(luts[LUT_SRGB8 + b.g] * a16), div65535(luts[LUT_SRGB8 + b.b] * a16), a16);
}

vec4 image(PaintRec p, vec2 pos) {
    float qx = p.inv0.x * pos.x + p.inv0.z * pos.y + p.inv1.x;
    float qy = p.inv0.y * pos.x + p.inv0.w * pos.y + p.inv1.y;
    ivec4 r = p.range;
    uint format = p.meta.x;
    uvec4 px;
    if (p.meta.y == 0u) {
        px = texel(format, clampI(floor(qx), r.x, r.z), clampI(floor(qy), r.y, r.w));
    } else {
        float u = qx - 0.5;
        float v = qy - 0.5;
        float fu = floor(u);
        float fv = floor(v);
        int ix = clampI(fu, r.x, r.z);
        int iy = clampI(fv, r.y, r.w);
        int ix1 = clampI(fu + 1.0, r.x, r.z);
        int iy1 = clampI(fv + 1.0, r.y, r.w);
        uint wx = uint(clamp(u - fu, 0.0, 1.0) * 256.0);
        uint wy = uint(clamp(v - fv, 0.0, 1.0) * 256.0);
        uvec4 top = texel(format, ix, iy) * (256u - wx) + texel(format, ix1, iy) * wx;
        uvec4 bot = texel(format, ix, iy1) * (256u - wx) + texel(format, ix1, iy1) * wx;
        px = (top * (256u - wy) + bot * wy + 32768u) >> 16;
    }
    uint opacity = p.meta.z;
    if (opacity != 65535u) px = div65535v(px * opacity);
    return vec4(px) / 65535.0;
}

// Blend modes (blend.blendF), premultiplied ------------------------------------

vec3 unpremul(vec4 p) {
    return p.a <= 0.0 ? vec3(0.0) : p.rgb / p.a;
}

float hardLight(float b, float s) {
    if (s <= 0.5) return b * 2.0 * s;
    float s2 = 2.0 * s - 1.0;
    return b + s2 - b * s2;
}

float separable(uint mode, float b, float s) {
    switch (mode) {
    case 23u: return b * s;                       // multiply
    case 13u: return b + s - b * s;               // screen
    case 14u: return hardLight(s, b);             // overlay
    case 15u: return min(b, s);                   // darken
    case 16u: return max(b, s);                   // lighten
    case 17u: return b == 0.0 ? 0.0 : (s >= 1.0 ? 1.0 : min(1.0, b / (1.0 - s))); // color dodge
    case 18u: return b >= 1.0 ? 1.0 : (s <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - b) / s)); // color burn
    case 19u: return hardLight(b, s);             // hard light
    case 20u: {                                   // soft light
        if (s <= 0.5) return b - (1.0 - 2.0 * s) * b * (1.0 - b);
        float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
        return b + (2.0 * s - 1.0) * (d - b);
    }
    case 21u: return abs(b - s);                  // difference
    case 22u: return b + s - 2.0 * b * s;         // exclusion
    }
    return s;
}

float lum(vec3 c) {
    return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b;
}

vec3 clipColor(vec3 c) {
    float l = lum(c);
    float n = min(c.r, min(c.g, c.b));
    float x = max(c.r, max(c.g, c.b));
    vec3 o = c;
    if (n < 0.0) o = l + (o - l) * l / (l - n);
    if (x > 1.0) o = l + (o - l) * (1.0 - l) / (x - l);
    return o;
}

vec3 setLum(vec3 c, float l) {
    float d = l - lum(c);
    return clipColor(c + d);
}

float sat(vec3 c) {
    return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

vec3 setSat(vec3 c, float s) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    return mx > mn ? (c - mn) * s / (mx - mn) : vec3(0.0);
}

vec4 blendModes(uint mode, vec4 s, vec4 d) {
    float sa = s.a;
    float da = d.a;
    switch (mode) {
    case 0u: return vec4(0.0);
    case 1u: return s;
    case 2u: return d;
    case 3u: return s + d * (1.0 - sa);
    case 4u: return s * (1.0 - da) + d;
    case 5u: return s * da;
    case 6u: return d * sa;
    case 7u: return s * (1.0 - da);
    case 8u: return d * (1.0 - sa);
    case 9u: return s * da + d * (1.0 - sa);
    case 10u: return s * (1.0 - da) + d * sa;
    case 11u: return s * (1.0 - da) + d * (1.0 - sa);
    case 12u: return min(s + d, vec4(1.0));
    }
    vec3 cs = unpremul(s);
    vec3 cb = unpremul(d);
    vec3 b;
    if (mode == 24u) b = setLum(setSat(cs, sat(cb)), lum(cb));
    else if (mode == 25u) b = setLum(setSat(cb, sat(cs)), lum(cb));
    else if (mode == 26u) b = setLum(cs, lum(cb));
    else if (mode == 27u) b = setLum(cb, lum(cs));
    else b = vec3(separable(mode, cb.r, cs.r), separable(mode, cb.g, cs.g), separable(mode, cb.b, cs.b));
    vec4 o = s * (1.0 - da) + d * (1.0 - sa);
    o.rgb += b * (sa * da);
    o.a = sa + da - sa * da;
    return o;
}

bool isUnbounded(uint mode) {
    return mode == 0u || mode == 1u || mode == 5u || mode == 6u || mode == 7u || mode == 10u;
}

// u16 lerp(d, s, c16) (blend.lerp).
uvec4 lerp16(uvec4 d, uvec4 s, uint c16) {
    return div65535v(s * c16 + d * (65535u - c16));
}

// Valid premultiplied u16 pixel from f32 (blend.fromF).
uvec4 fromF(vec4 f) {
    float a = clamp(f.a, 0.0, 1.0);
    return uvec4(toU16(vec4(min(clamp(f.rgb, 0.0, 1.0), vec3(a)), a)));
}

uvec4 texelA(ivec4 t, vec2 px) {
    return toU16(texelFetch(tex_a, ivec2(px) - t.yz, 0));
}

uvec4 texelB(ivec4 t, vec2 px) {
    return toU16(texelFetch(tex_b, ivec2(px) - t.yz, 0));
}

void main() {
    Inst it = insts[v_inst];
    vec2 px = floor(gl_FragCoord.xy) + pc.origin;
    vec2 pos = px + 0.5;

    // Coverage, 16 bits (0..65535).
    uint cov16;
    if (it.cov == COV_SHADOW) {
        cov16 = uint(clamp(shadowAlpha(paints[it.aux], paints[it.aux + 1u], pos), 0.0, 1.0) * 65535.0 + 0.5);
        if (it.clip != 0u) cov16 = div65535(cov16 * (uint(clipCoverage(it.clip, px)) * 257u));
        if (cov16 == 0u) discard;
    } else if (it.cov == COV_GLYPH) {
        uint a = uint(glyphCoverage(it.tex, px));
        if (a == 0u) discard;
        cov16 = luts[uint(it.tex.w) * 256u + a];
        if (it.clip != 0u) cov16 = div65535(cov16 * (uint(clipCoverage(it.clip, px)) * 257u));
    } else {
        float c = shapeCoverage(it.cov, it.g0, it.g1, it.g2, it.tex, px);
        if (it.clip != 0u) c = floor((c * clipCoverage(it.clip, px) + 127.0) / 255.0);
        cov16 = uint(c) * 257u;
    }

    if (it.paint == PAINT_BLEND) {
        uint mode = it.aux;
        uvec4 s = texelA(it.ptex, px);
        uint opacity = uint(it.color.a * 65535.0 + 0.5);
        if (opacity != 65535u) s = div65535v(s * opacity);
        uvec4 d = texelB(it.btex, px);
        uvec4 o = fromF(blendModes(mode, vec4(s) / 65535.0, vec4(d) / 65535.0));
        if (isUnbounded(mode) && cov16 != 65535u) o = lerp16(d, o, cov16);
        o_color = vec4(o) / 65535.0;
        return;
    }
    if (cov16 == 0u) discard;
    if (it.paint == PAINT_BLUR) {
        uvec4 s = fromF(texelFetch(tex_a, ivec2(px) - it.ptex.yz, 0));
        uvec4 d = texelB(it.btex, px);
        o_color = vec4(lerp16(d, s, cov16)) / 65535.0;
        return;
    }

    vec4 s;
    switch (it.paint) {
    case PAINT_SOLID: s = it.color; break;
    case PAINT_LINEAR:
    case PAINT_RADIAL:
    case PAINT_SWEEP: s = gradient(paints[it.aux], it.paint, pos); break;
    case PAINT_IMAGE: s = image(paints[it.aux], pos); break;
    case PAINT_GLYPH: s = texelFetch(glyph_colors, ivec2(px) - it.ptex.yz, 0); break;
    default: s = texelFetch(tex_a, ivec2(px) - it.ptex.yz, 0) * it.color.a; break;
    }
    o_color = s * (float(cov16) / 65535.0);
}
