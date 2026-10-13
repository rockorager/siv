//! A parsed SVG lowered to a list of drawing operations in the root's
//! user space, immutable and safe to draw from any thread. `draw`
//! appends them to a display list (D9), mapped into a rectangle, with
//! the colors that stand for roles (symbolic icons) resolved at that
//! moment, so a theme change needs no new parse.

const std = @import("std");
const scene = @import("scene");
const raster = @import("raster");
const Rect = raster.Rect;
const Affine = raster.Affine;

const Document = @This();

arena: std.heap.ArenaAllocator,
/// The intrinsic size in CSS pixels: the root's width and height, or its
/// view box's.
width: f32,
height: f32,
/// What the root's user space shows.
view_box: Rect,
aspect: Aspect,
ops: []const Op,
paints: []const Paint,
/// Whether any paint stands for a role, so the document follows the
/// colors it is drawn with.
recolors: bool,

/// What a color stands for in a recolored icon: the GTK symbolic
/// convention's foreground, success, warning, and error colors, and
/// KDE's color scheme classes (`.ColorScheme-Text` and the others).
pub const Role = enum(u8) {
    none,
    foreground,
    background,
    accent,
    accent_foreground,
    success,
    warning,
    @"error",
};
pub const role_count = @typeInfo(Role).@"enum".field_names.len;

/// The colors roles take, sRGB-encoded with straight alpha (CSS colors),
/// since SVG computes masks and filters on encoded values.
pub const Colors = struct {
    roles: [role_count][4]f32 = @splat(.{ 0, 0, 0, 1 }),

    /// From linear-light colors, as the theme resolves them.
    pub fn set(c: *Colors, role: Role, linear: scene.Color) void {
        c.roles[@intFromEnum(role)] = .{ scene.linearToSrgb(linear.r), scene.linearToSrgb(linear.g), scene.linearToSrgb(linear.b), linear.a };
    }
};

/// preserveAspectRatio.
pub const Aspect = struct {
    /// none stretches.
    align_x: Align = .mid,
    align_y: Align = .mid,
    slice: bool = false,
    none: bool = false,

    pub const Align = enum(u8) { min, mid, max };
};

/// A color as the file writes it (sRGB-encoded, straight alpha), which
/// the role replaces when the document is drawn with colors.
pub const Tint = struct {
    rgba: [4]f32 = .{ 0, 0, 0, 1 },
    role: Role = .none,
};

pub const TintStop = struct {
    offset: f32,
    tint: Tint,
    opacity: f32 = 1,
};

/// One step of a color filter, applied to each paint's colors.
pub const ColorStep = union(enum) {
    /// feColorMatrix's 4 × 5 matrix on straight RGBA; on linear-light
    /// components when `linear` (color-interpolation-filters), else on
    /// sRGB-encoded ones.
    matrix: struct { m: [20]f32, linear: bool },
    /// A luminance mask: alpha becomes luminance times alpha, color white.
    luminance,
};

pub const Paint = struct {
    kind: Kind,
    /// Gradients: offsets non-decreasing in [0, 1], at least two.
    stops: []const TintStop = &.{},
    extend: scene.Extend = .pad,
    /// Gradient space into the coordinates of the operation drawing it.
    transform: Affine = .identity,
    /// Multiplies alpha (fill-opacity, folded element opacity).
    opacity: f32 = 1,
    /// Applied in order to every color.
    filter: []const ColorStep = &.{},

    pub const Kind = union(enum) {
        solid: Tint,
        linear: struct { p0: raster.Point, p1: raster.Point },
        radial: struct { c0: raster.Point, r0: f32, c1: raster.Point, r1: f32 },
    };
};

pub const Op = union(enum) {
    push: Push,
    pop,
    fill: struct { path: raster.Path, rule: scene.FillRule, paint: u32 },
    stroke: struct { path: raster.Path, style: raster.StrokeStyle, paint: u32 },
    /// Blurs what the innermost isolated layer holds so far (a Gaussian
    /// blur filter on that layer's content).
    blur: struct { region: raster.Path, sigma: f32 },

    pub const Push = struct {
        transform: Affine = .identity,
        opacity: f32 = 1,
        blend: scene.BlendMode = .src_over,
        isolate: bool = false,
        clip: ?struct { path: raster.Path, rule: scene.FillRule } = null,
    };
};

pub fn deinit(doc: *Document) void {
    var arena = doc.arena;
    arena.deinit();
}

/// Maps the view box into `dst` following preserveAspectRatio.
pub fn viewTransform(doc: *const Document, dst: Rect) Affine {
    const vb = doc.view_box;
    const vw = vb.width();
    const vh = vb.height();
    if (!(vw > 0) or !(vh > 0)) return .identity;
    var sx = dst.width() / vw;
    var sy = dst.height() / vh;
    const a = doc.aspect;
    if (!a.none) {
        const s = if (a.slice) @max(sx, sy) else @min(sx, sy);
        sx = s;
        sy = s;
    }
    const free_x = dst.width() - vw * sx;
    const free_y = dst.height() - vh * sy;
    const ox = if (a.none) 0 else alignOffset(a.align_x, free_x);
    const oy = if (a.none) 0 else alignOffset(a.align_y, free_y);
    return Affine.translate(-vb.x0, -vb.y0).then(.scale(sx, sy)).then(.translate(dst.x0 + ox, dst.y0 + oy));
}

fn alignOffset(al: Aspect.Align, free: f32) f32 {
    return switch (al) {
        .min => 0,
        .mid => free / 2,
        .max => free,
    };
}

/// Appends the drawing, mapped into `dst` and clipped to it, to `b`.
/// Without `colors` every role keeps the color the file gives it.
pub fn draw(doc: *const Document, b: *scene.Builder, dst: Rect, colors: ?*const Colors) scene.Error!void {
    if (dst.isEmpty()) return;
    try b.pushLayer(.{ .transform = doc.viewTransform(dst), .clip = .{ .shape = .{ .rect = doc.view_box } } });
    var depth: usize = 1;
    errdefer for (0..depth) |_| b.popLayer() catch {};
    for (doc.ops) |op| switch (op) {
        .push => |p| {
            try b.pushLayer(.{
                .transform = p.transform,
                .opacity = p.opacity,
                .blend = p.blend,
                .isolate = p.isolate,
                .clip = if (p.clip) |c| .{ .shape = .{ .path = c.path }, .rule = c.rule } else null,
            });
            depth += 1;
        },
        .pop => {
            try b.popLayer();
            depth -= 1;
        },
        .fill => |f| {
            var buf: StopBuffer = undefined;
            const paint = doc.resolve(f.paint, colors, &buf);
            if (!paint.isInvisible()) try b.fill(.{ .path = f.path }, f.rule, paint);
        },
        .stroke => |s| {
            var buf: StopBuffer = undefined;
            const paint = doc.resolve(s.paint, colors, &buf);
            if (!paint.isInvisible()) try b.stroke(.{ .path = s.path }, s.style, paint);
        },
        .blur => |bl| try b.backdropBlur(.{ .path = bl.region }, bl.sigma),
    };
    try b.popLayer();
    depth -= 1;
}

const max_stops = 256;
const StopBuffer = [max_stops]scene.Stop;

/// Linear-light color of a tint after the paint's filter and opacity.
fn color(p: *const Paint, t: Tint, opacity: f32, colors: ?*const Colors) scene.Color {
    var c: [4]f32 = if (t.role != .none and colors != null) colors.?.roles[@intFromEnum(t.role)] else t.rgba;
    for (p.filter) |step| c = apply(step, c);
    return .{ .r = scene.srgbToLinear(c[0]), .g = scene.srgbToLinear(c[1]), .b = scene.srgbToLinear(c[2]), .a = std.math.clamp(c[3] * opacity * p.opacity, 0, 1) };
}

fn apply(step: ColorStep, in: [4]f32) [4]f32 {
    switch (step) {
        .luminance => {
            const l = 0.2125 * in[0] + 0.7154 * in[1] + 0.0721 * in[2];
            return .{ 1, 1, 1, std.math.clamp(l * in[3], 0, 1) };
        },
        .matrix => |mx| {
            var c = in;
            if (mx.linear) for (0..3) |k| {
                c[k] = scene.srgbToLinear(c[k]);
            };
            var out: [4]f32 = undefined;
            for (0..4) |row| {
                const m = mx.m[row * 5 ..][0..5];
                out[row] = std.math.clamp(m[0] * c[0] + m[1] * c[1] + m[2] * c[2] + m[3] * c[3] + m[4], 0, 1);
            }
            if (mx.linear) for (0..3) |k| {
                out[k] = scene.linearToSrgb(out[k]);
            };
            return out;
        },
    }
}

/// SVG interpolates gradients in sRGB, display lists in linear light
/// (D9): stops between colors that differ get sub-stops computed in
/// premultiplied sRGB, 16 per interval while they fit, so the linear
/// interpolation between them stays within half a level of 8 bits.
fn resolve(doc: *const Document, index: u32, colors: ?*const Colors, buf: *StopBuffer) scene.Paint {
    const p = &doc.paints[index];
    switch (p.kind) {
        .solid => |t| return .{ .solid = color(p, t, 1, colors) },
        else => {},
    }
    const stops = p.stops;
    var n: usize = 0;
    var subdivisions: usize = 16;
    while (subdivisions > 1 and 1 + (stops.len - 1) * subdivisions > max_stops) subdivisions /= 2;
    for (stops, 0..) |s, i| {
        if (n >= max_stops) break;
        const c = color(p, s.tint, s.opacity, colors);
        if (i > 0 and subdivisions > 1) {
            const prev = stops[i - 1];
            const a = encoded(p, prev.tint, prev.opacity, colors);
            const z = encoded(p, s.tint, s.opacity, colors);
            if (!(a[0] == z[0] and a[1] == z[1] and a[2] == z[2])) {
                for (1..subdivisions) |k| {
                    if (n >= max_stops - 1) break;
                    const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(subdivisions));
                    buf[n] = .{ .offset = prev.offset + (s.offset - prev.offset) * t, .color = mixSrgb(a, z, t) };
                    n += 1;
                }
            }
        }
        buf[n] = .{ .offset = s.offset, .color = c };
        n += 1;
    }
    const g: scene.Gradient = .{
        .geometry = switch (p.kind) {
            .linear => |l| .{ .linear = .{ .p0 = l.p0, .p1 = l.p1 } },
            .radial => |r| .{ .radial = .{ .c0 = r.c0, .r0 = r.r0, .c1 = r.c1, .r1 = r.r1 } },
            .solid => unreachable,
        },
        .stops = buf[0..n],
        .extend = p.extend,
        .transform = p.transform,
    };
    return .{ .gradient = g };
}

/// Filtered sRGB-encoded color with alpha, before linearization.
fn encoded(p: *const Paint, t: Tint, opacity: f32, colors: ?*const Colors) [4]f32 {
    var c: [4]f32 = if (t.role != .none and colors != null) colors.?.roles[@intFromEnum(t.role)] else t.rgba;
    for (p.filter) |step| c = apply(step, c);
    c[3] = std.math.clamp(c[3] * opacity * p.opacity, 0, 1);
    return c;
}

/// Premultiplied interpolation in sRGB, back to straight linear light.
fn mixSrgb(a: [4]f32, z: [4]f32, t: f32) scene.Color {
    const alpha = a[3] + (z[3] - a[3]) * t;
    if (alpha <= 0) return .transparent;
    var out: [3]f32 = undefined;
    for (0..3) |k| out[k] = scene.srgbToLinear(std.math.clamp((a[k] * a[3] + (z[k] * z[3] - a[k] * a[3]) * t) / alpha, 0, 1));
    return .{ .r = out[0], .g = out[1], .b = out[2], .a = alpha };
}
