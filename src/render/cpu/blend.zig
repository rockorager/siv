//! Pixel compositing in linear light, premultiplied, 16 bits per channel.
//! Source-over runs in integer arithmetic; the other blend modes follow
//! the W3C Compositing and Blending formulas in f32.

const std = @import("std");
const scene = @import("scene");
const color = @import("color.zig");
const Pixel = color.Pixel;
const BlendMode = scene.BlendMode;

const V4 = @Vector(4, u32);
const F4 = @Vector(4, f32);

/// Source-over of `s` scaled by coverage `cov16` (0..65535).
pub inline fn srcOver(d: *Pixel, s: Pixel, cov16: u32) void {
    var sv: V4 = s;
    if (cov16 != 65535) sv = color.div65535v(sv * @as(V4, @splat(cov16)));
    const inv = 65535 - sv[3];
    const dv: V4 = d.*;
    d.* = color.narrow(sv + color.div65535v(dv * @as(V4, @splat(inv))));
}

/// d = lerp(d, s, cov16 / 65535).
pub inline fn lerp(d: *Pixel, s: Pixel, cov16: u32) void {
    const sv: V4 = s;
    const dv: V4 = d.*;
    d.* = color.narrow(color.div65535v(sv * @as(V4, @splat(cov16)) + dv * @as(V4, @splat(65535 - cov16))));
}

/// Composites a layer pixel onto its parent with `mode`. `opacity16`
/// scales the source. For unbounded modes `clip16` limits the effect.
pub fn composite(mode: BlendMode, d: *Pixel, s: Pixel, opacity16: u32, clip16: u32) void {
    if (mode == .src_over) return srcOver(d, s, opacity16);
    var sv: V4 = s;
    if (opacity16 != 65535) sv = color.div65535v(sv * @as(V4, @splat(opacity16)));
    const sf = toF(sv);
    const df = toF(d.*);
    const r = blendF(mode, sf, df);
    const out = fromF(r);
    if (clip16 != 65535 and mode.isUnbounded()) {
        lerp(d, out, clip16);
    } else {
        d.* = out;
    }
}

inline fn toF(p: anytype) F4 {
    const v: V4 = p;
    return @as(F4, @floatFromInt(v)) * @as(F4, @splat(1.0 / 65535.0));
}

inline fn fromF(f: F4) Pixel {
    var out: Pixel = undefined;
    const a = std.math.clamp(f[3], 0, 1);
    out[3] = color.toU16(a);
    inline for (0..3) |i| out[i] = color.toU16(@min(std.math.clamp(f[i], 0, 1), a));
    return out;
}

/// Premultiplied src (s) onto premultiplied backdrop (d).
pub fn blendF(mode: BlendMode, s: F4, d: F4) F4 {
    const sa = s[3];
    const da = d[3];
    const one: F4 = @splat(1);
    return switch (mode) {
        .clear => @splat(0),
        .src => s,
        .dst => d,
        .src_over => s + d * @as(F4, @splat(1 - sa)),
        .dst_over => s * @as(F4, @splat(1 - da)) + d,
        .src_in => s * @as(F4, @splat(da)),
        .dst_in => d * @as(F4, @splat(sa)),
        .src_out => s * @as(F4, @splat(1 - da)),
        .dst_out => d * @as(F4, @splat(1 - sa)),
        .src_atop => s * @as(F4, @splat(da)) + d * @as(F4, @splat(1 - sa)),
        .dst_atop => s * @as(F4, @splat(1 - da)) + d * @as(F4, @splat(sa)),
        .xor => s * @as(F4, @splat(1 - da)) + d * @as(F4, @splat(1 - sa)),
        .plus => @min(s + d, one),
        else => blk: {
            // co = cs·(1 − ab) + cb·(1 − as) + as·ab·B(Cb, Cs)
            const cs = unpremul(s);
            const cb = unpremul(d);
            const b = mix(mode, cb, cs);
            var out = s * @as(F4, @splat(1 - da)) + d * @as(F4, @splat(1 - sa)) + b * @as(F4, @splat(sa * da));
            out[3] = sa + da - sa * da;
            break :blk out;
        },
    };
}

fn unpremul(p: F4) F4 {
    if (p[3] <= 0) return @splat(0);
    var out = p / @as(F4, @splat(p[3]));
    out[3] = p[3];
    return out;
}

/// B(Cb, Cs) for the separable and non-separable blend modes.
fn mix(mode: BlendMode, cb: F4, cs: F4) F4 {
    switch (mode) {
        .hue, .saturation, .color, .luminosity => {
            const b: [3]f32 = .{ cb[0], cb[1], cb[2] };
            const s: [3]f32 = .{ cs[0], cs[1], cs[2] };
            const r = switch (mode) {
                .hue => setLum(setSat(s, sat(b)), lum(b)),
                .saturation => setLum(setSat(b, sat(s)), lum(b)),
                .color => setLum(s, lum(b)),
                else => setLum(b, lum(s)),
            };
            return .{ r[0], r[1], r[2], 0 };
        },
        else => {
            var out: F4 = @splat(0);
            inline for (0..3) |i| out[i] = separable(mode, cb[i], cs[i]);
            return out;
        },
    }
}

fn separable(mode: BlendMode, b: f32, s: f32) f32 {
    return switch (mode) {
        .multiply => b * s,
        .screen => b + s - b * s,
        .overlay => hardLight(s, b),
        .darken => @min(b, s),
        .lighten => @max(b, s),
        .color_dodge => if (b == 0) 0 else if (s >= 1) 1 else @min(1, b / (1 - s)),
        .color_burn => if (b >= 1) 1 else if (s <= 0) 0 else 1 - @min(1, (1 - b) / s),
        .hard_light => hardLight(b, s),
        .soft_light => blk: {
            if (s <= 0.5) break :blk b - (1 - 2 * s) * b * (1 - b);
            const d = if (b <= 0.25) ((16 * b - 12) * b + 4) * b else @sqrt(b);
            break :blk b + (2 * s - 1) * (d - b);
        },
        .difference => @abs(b - s),
        .exclusion => b + s - 2 * b * s,
        else => s,
    };
}

fn hardLight(b: f32, s: f32) f32 {
    if (s <= 0.5) return b * 2 * s;
    const s2 = 2 * s - 1;
    return b + s2 - b * s2;
}

fn lum(c: [3]f32) f32 {
    return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2];
}

fn clipColor(c: [3]f32) [3]f32 {
    const l = lum(c);
    const n = @min(c[0], @min(c[1], c[2]));
    const x = @max(c[0], @max(c[1], c[2]));
    var out = c;
    if (n < 0) {
        for (&out) |*v| v.* = l + (v.* - l) * l / (l - n);
    }
    if (x > 1) {
        for (&out) |*v| v.* = l + (v.* - l) * (1 - l) / (x - l);
    }
    return out;
}

fn setLum(c: [3]f32, l: f32) [3]f32 {
    const d = l - lum(c);
    return clipColor(.{ c[0] + d, c[1] + d, c[2] + d });
}

fn sat(c: [3]f32) f32 {
    return @max(c[0], @max(c[1], c[2])) - @min(c[0], @min(c[1], c[2]));
}

fn setSat(c: [3]f32, s: f32) [3]f32 {
    const mx = @max(c[0], @max(c[1], c[2]));
    const mn = @min(c[0], @min(c[1], c[2]));
    var out: [3]f32 = undefined;
    for (c, 0..) |v, i| {
        out[i] = if (mx > mn) (v - mn) * s / (mx - mn) else 0;
    }
    return out;
}

test "source over" {
    var d: Pixel = .{ 0, 0, 65535, 65535 };
    srcOver(&d, .{ 32768, 0, 0, 32768 }, 65535);
    try std.testing.expectEqual(Pixel{ 32768, 0, 32767, 65535 }, d);
    d = .{ 0, 0, 0, 0 };
    srcOver(&d, .{ 65535, 65535, 65535, 65535 }, 32768);
    try std.testing.expectEqual(Pixel{ 32768, 32768, 32768, 32768 }, d);
}

test "blend modes agree with source-over and known values" {
    var d: Pixel = .{ 10000, 20000, 30000, 50000 };
    var e = d;
    const s: Pixel = .{ 30000, 5000, 1000, 40000 };
    composite(.src_over, &d, s, 65535, 65535);
    // The f32 path must agree with the integer path.
    e = fromF(blendF(.src_over, toF(s), toF(e)));
    for (0..4) |i| try std.testing.expect(@abs(@as(i32, d[i]) - e[i]) <= 1);

    // Multiply of opaque white with anything is the identity.
    var m: Pixel = .{ 12345, 23456, 34567, 65535 };
    composite(.multiply, &m, .{ 65535, 65535, 65535, 65535 }, 65535, 65535);
    try std.testing.expectEqual(Pixel{ 12345, 23456, 34567, 65535 }, m);

    // dst_in with a transparent source clears, but only inside the clip.
    var u: Pixel = .{ 1000, 1000, 1000, 65535 };
    composite(.dst_in, &u, .{ 0, 0, 0, 0 }, 65535, 32768);
    try std.testing.expectEqual(Pixel{ 500, 500, 500, 32767 }, u);
}
