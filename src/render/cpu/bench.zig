//! CPU renderer benchmarks: `zig build bench-render-cpu -Doptimize=ReleaseFast`.
//!
//! Each workload renders a 1920x1080 frame (encoded to ARGB8888, as for
//! wl_shm) with one worker and with one worker per CPU, after warm-up so
//! glyph caches are populated. Damage workloads redraw one small rectangle.
//! Fonts are the text engine's bundled Droid Sans, so results do not depend
//! on the machine's fonts.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const text = @import("text");
const render_cpu = @import("render_cpu");
const pool_mod = @import("pool");
const hb = render_cpu.glyph.hb;

const width = 1920;
const height = 1080;

const Ctx = struct {
    gpa: std.mem.Allocator,
    font: *hb.hb_font_t,
    upem: f32,
    pb: raster.PathBuilder,
    glyphs: std.ArrayList(scene.Glyph) = .empty,
    frame: u32 = 0,
};

fn label(c: *Ctx, b: *scene.Builder, str: []const u8, x: f32, y: f32, size: f32, color: scene.Color) !void {
    const buf = hb.hb_buffer_create();
    defer hb.hb_buffer_destroy(buf);
    hb.hb_buffer_add_utf8(buf, str.ptr, @intCast(str.len), 0, @intCast(str.len));
    hb.hb_buffer_guess_segment_properties(buf);
    hb.hb_shape(c.font, buf, null, 0);
    var n: c_uint = 0;
    const infos = hb.hb_buffer_get_glyph_infos(buf, &n);
    const pos = hb.hb_buffer_get_glyph_positions(buf, &n);
    const s = size / c.upem;
    c.glyphs.clearRetainingCapacity();
    var pen = x;
    for (0..n) |i| {
        try c.glyphs.append(c.gpa, .{ .id = infos[i].codepoint, .x = pen, .y = y });
        pen += @as(f32, @floatFromInt(pos[i].x_advance)) * s;
    }
    try b.glyphs(.{
        .font = .{ .handle = c.font, .key = 1 },
        .size = size,
        .glyphs = c.glyphs.items,
        .paint = .color(color),
        .bounds = .{ .x0 = x - 2, .y0 = y - size, .x1 = pen + 2, .y1 = y + size * 0.4 },
    });
}

const bg = scene.Color.srgb8(0xf4, 0xf4, 0xf5, 0xff);
const card = scene.Color.srgb8(0xff, 0xff, 0xff, 0xff);
const ink = scene.Color.srgb8(0x18, 0x18, 0x1b, 0xff);
const accent = scene.Color.srgb8(0x25, 0x63, 0xeb, 0xff);

/// A dashboard: sidebar, a grid of cards with titles, body text, and a
/// button each. Card 0's version changes every frame (a hover).
fn ui(c: *Ctx, b: *scene.Builder) !void {
    try b.fillRect(.xywh(0, 0, width, height), .color(bg));
    try b.fillRect(.xywh(0, 0, 240, height), .color(scene.Color.srgb8(0x27, 0x27, 0x2a, 0xff)));
    for (0..24) |i| try label(c, b, "Navigation item", 24, 40 + @as(f32, @floatFromInt(i)) * 36, 14, .white);
    for (0..40) |i| {
        const x = 264 + @as(f32, @floatFromInt(i % 5)) * 330;
        const y = 24 + @as(f32, @floatFromInt(i / 5)) * 130;
        const hovered = i == 0 and c.frame % 2 == 1;
        try b.pushLayer(.{ .id = @intCast(i + 1), .version = if (i == 0) c.frame else 0 });
        try b.fillRoundedRect(.xywh(x, y, 310, 116), .uniform(10, 10), .color(if (hovered) scene.Color.srgb8(0xe0, 0xe7, 0xff, 0xff) else card));
        try b.stroke(.{ .rounded_rect = .{ .rect = .xywh(x + 0.5, y + 0.5, 309, 115), .radii = .uniform(10, 10) } }, .{ .width = 1 }, .color(scene.Color.srgb8(0xe4, 0xe4, 0xe7, 0xff)));
        try label(c, b, "Quarterly revenue", x + 16, y + 30, 16, ink);
        try label(c, b, "Up 12% from last quarter across all regions.", x + 16, y + 56, 13, ink);
        try b.fillRoundedRect(.xywh(x + 16, y + 74, 96, 28), .uniform(6, 6), .color(accent));
        try label(c, b, "Details", x + 38, y + 93, 13, .white);
        try b.popLayer();
    }
}

fn paths(c: *Ctx, b: *scene.Builder) !void {
    try b.fillRect(.xywh(0, 0, width, height), .color(.white));
    var rng = std.Random.DefaultPrng.init(42);
    const r = rng.random();
    for (0..400) |_| {
        c.pb.reset();
        const x = r.float(f32) * width;
        const y = r.float(f32) * height;
        try c.pb.moveTo(x, y);
        for (0..4) |_| try c.pb.cubicTo(x + r.float(f32) * 200 - 100, y + r.float(f32) * 200 - 100, x + r.float(f32) * 200 - 100, y + r.float(f32) * 200 - 100, x + r.float(f32) * 200 - 100, y + r.float(f32) * 200 - 100);
        try c.pb.close();
        const col = scene.Color.srgb(r.float(f32), r.float(f32), r.float(f32), 0.7);
        if (r.boolean()) {
            try b.fillPath(c.pb.path(), .nonzero, .color(col));
        } else {
            try b.stroke(.{ .path = c.pb.path() }, .{ .width = 3, .join = .round }, .color(col));
        }
    }
}

/// A few large paths with many segments, each spanning most of the frame:
/// the case where every tile would otherwise walk every line.
fn largePaths(c: *Ctx, b: *scene.Builder) !void {
    try b.fillRect(.xywh(0, 0, width, height), .color(.white));
    for (0..6) |k| {
        c.pb.reset();
        const kf: f32 = @floatFromInt(k);
        const n = 2000;
        for (0..n) |i| {
            const a = @as(f32, @floatFromInt(i)) / n * 2 * std.math.pi;
            const r = 300 + 200 * @sin(a * (7 + kf * 3)) + 40 * @sin(a * 61);
            const x = 960 + r * 1.6 * @cos(a) + kf * 20;
            const y = 540 + r * @sin(a);
            if (i == 0) try c.pb.moveTo(x, y) else try c.pb.lineTo(x, y);
        }
        try c.pb.close();
        try b.fillPath(c.pb.path(), .even_odd, .color(scene.Color.srgb(0.2 + kf * 0.1, 0.4, 0.8 - kf * 0.1, 0.5)));
    }
}

fn gradients(_: *Ctx, b: *scene.Builder) !void {
    const stops = [_]scene.Stop{
        .{ .offset = 0, .color = accent },
        .{ .offset = 0.5, .color = .white },
        .{ .offset = 1, .color = scene.Color.srgb8(0xf5, 0x9e, 0x0b, 0xff) },
    };
    try b.fillRect(.xywh(0, 0, width, height), .{ .gradient = .{ .geometry = .{ .linear = .{ .p0 = .zero, .p1 = .{ .x = width, .y = height } } }, .stops = &stops } });
    try b.fillRect(.xywh(0, 0, width, height), .{ .gradient = .{ .geometry = .{ .radial = .{ .c0 = .{ .x = 960, .y = 540 }, .r0 = 0, .c1 = .{ .x = 960, .y = 540 }, .r1 = 600 } }, .stops = &stops, .extend = .reflect } });
}

fn blur(c: *Ctx, b: *scene.Builder) !void {
    try ui(c, b);
    try b.pushLayer(.{ .id = 100 });
    try b.backdropBlur(.{ .rounded_rect = .{ .rect = .xywh(560, 240, 800, 500), .radii = .uniform(16, 16) } }, 20);
    try b.fillRoundedRect(.xywh(560, 240, 800, 500), .uniform(16, 16), .color(scene.Color.white.withAlpha(0.3)));
    try b.popLayer();
}

fn textScreen(c: *Ctx, b: *scene.Builder) !void {
    try b.fillRect(.xywh(0, 0, width, height), .color(.white));
    for (0..60) |i| {
        try label(c, b, "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. How vexingly quick daft zebras jump!", 12, 16 + @as(f32, @floatFromInt(i)) * 17.5, 13, ink);
    }
}

const Workload = struct {
    name: []const u8,
    build: *const fn (*Ctx, *scene.Builder) anyerror!void,
    damage: ?raster.IRect = null,
    /// Redraw nothing: measures the serial prepare pass alone.
    prepare_only: bool = false,
};

const workloads = [_]Workload{
    .{ .name = "ui full", .build = ui },
    .{ .name = "ui hover damage", .build = ui, .damage = .xywh(264, 24, 310, 116) },
    .{ .name = "text screen", .build = textScreen },
    .{ .name = "paths", .build = paths },
    .{ .name = "paths prepare only", .build = paths, .prepare_only = true },
    .{ .name = "large paths", .build = largePaths },
    .{ .name = "gradients", .build = gradients },
    .{ .name = "blur panel", .build = blur },
    .{ .name = "blur hover damage", .build = blur, .damage = .xywh(264, 24, 310, 116) },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    if (@import("builtin").mode == .debug) std.debug.print("warning: build with -Doptimize=ReleaseFast for meaningful numbers\n", .{});

    const data = text.font.test_fonts.latin;
    const blob = hb.hb_blob_create(data.ptr, @intCast(data.len), hb.HB_MEMORY_MODE_READONLY, null, null);
    defer hb.hb_blob_destroy(blob);
    const face = hb.hb_face_create(blob, 0);
    defer hb.hb_face_destroy(face);
    const font = hb.hb_font_create(face).?;
    defer hb.hb_font_destroy(font);
    var c: Ctx = .{ .gpa = gpa, .font = font, .upem = @floatFromInt(hb.hb_face_get_upem(face)), .pb = .init(gpa) };
    defer c.pb.deinit();
    defer c.glyphs.deinit(gpa);

    const out = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(out);
    var b = scene.Builder.init(gpa);
    defer b.deinit();

    const cpus: u32 = @intCast(std.Thread.getCpuCount() catch 1);
    std.debug.print("{d}x{d}, ARGB8888 output; ms per frame (median of 30)\n", .{ width, height });
    std.debug.print("  {s:<20} {s:>10} {s:>10}\n", .{ "workload", "1 worker", try std.fmt.allocPrint(gpa, "{d} workers", .{cpus}) });
    for (workloads) |w| {
        var times: [2]f64 = undefined;
        for ([_]u32{ 1, cpus }, 0..) |n, k| {
            // n workers in total: the caller plus n - 1 pool threads.
            var workers = pool_mod.Pool.init(gpa, @max(n, 2) - 1);
            defer workers.deinit();
            const r = try render_cpu.Renderer.create(gpa, if (n == 1) .serial else workers.executor());
            defer r.destroy();
            try r.resize(width, height);
            var samples: [30]f64 = undefined;
            for (0..40) |i| {
                c.frame = @intCast(i);
                b.reset();
                try w.build(&c, &b);
                const list = try b.finish(0);
                const damage: ?[]const raster.IRect = if (w.prepare_only) &.{} else if (w.damage != null and i > 0) &.{w.damage.?} else null;
                const start = std.Io.Timestamp.now(io, .awake);
                try r.render(list, .{ .damage = damage, .target = .{ .pixels = out.ptr, .stride = width * 4, .format = .argb8888 } });
                const ns = start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds();
                if (i >= 10) samples[i - 10] = @as(f64, @floatFromInt(ns)) / 1e6;
            }
            std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
            times[k] = samples[samples.len / 2];
        }
        std.debug.print("  {s:<20} {d:>10.2} {d:>10.2}\n", .{ w.name, times[0], times[1] });
    }
}
