//! Glyph rendering (D14): HarfBuzz draw and paint into the shared coverage
//! rasterizer, a glyph cache, and the unhinted-text mitigations.
//!
//! - Outline glyphs come from hb_font_draw_glyph into a raster.PathBuilder
//!   and are rasterized into 8-bit masks.
//! - Color glyphs (COLRv0/v1, and CBDT/sbix bitmaps decoded by wuffs) come
//!   from hb_font_paint_glyph, which is
//!   lowered into a scene display list (layers for transforms, clips, and
//!   composite groups; gradient fills) and rendered by a CPU renderer into a
//!   16-bit linear premultiplied bitmap. The same lowering serves Vulkan,
//!   which uploads these bitmaps.
//! - Entries are keyed by font key, glyph, pixel size (1/64 px), and 1/4-
//!   pixel horizontal phase; color glyphs also by foreground color.
//! - Mitigations for unhinted text: baselines snap to whole pixels, the
//!   x-height is scaled vertically to a whole pixel at small sizes, small
//!   sizes get slight stem darkening (outline emboldening), and coverage is
//!   corrected for contrast when composited (ContrastLuts).
//!
//! Runs whose transform is not a uniform positive scale plus translation,
//! or whose glyphs exceed `max_cached_size`, are drawn as paths instead.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
/// The HarfBuzz bindings, for callers that build fonts for glyph runs.
pub const hb = @import("harfbuzz");
const wuffs = @import("wuffs");
const color = @import("color.zig");
const renderer_mod = @import("renderer.zig");
const Pixel = color.Pixel;
const Point = raster.Point;
const Rect = raster.Rect;
const IRect = raster.IRect;
const Affine = raster.Affine;

/// Largest pixel size served from the cache.
pub const max_cached_size: f32 = 256;
/// The cache is cleared at the start of a frame once it holds more pixel
/// bytes than this.
pub const budget_bytes: usize = 32 << 20;

pub const Placement = struct {
    /// Device pixel of the glyph origin (phase already applied).
    x: i32,
    y: i32,
    entry: u32,
};

pub const Entry = struct {
    kind: Kind,
    /// Bitmap offset from the placement origin.
    left: i32,
    top: i32,
    width: u32,
    height: u32,
    /// Offset into the mask or color storage.
    offset: usize,

    pub const Kind = enum(u8) {
        mask,
        color,
        /// A color glyph; look it up again with the foreground color.
        redirect,
    };
};

const Key = struct {
    font: u64,
    glyph: u32,
    /// Pixel size in 1/64 px.
    size: u32,
    phase: u8,
    /// Foreground color (RGBA8) for color glyphs, else 0.
    fg: u32,
};

pub const Error = error{OutOfMemory};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    masks: std.ArrayList(u8) = .empty,
    colors: std.ArrayList(Pixel) = .empty,
    rasterizer: raster.Rasterizer,
    path: raster.PathBuilder,
    contour_points: std.ArrayList(Point) = .empty,
    contour_ends: std.ArrayList(u32) = .empty,
    draw_funcs: ?*hb.hb_draw_funcs_t = null,
    paint_funcs: ?*hb.hb_paint_funcs_t = null,
    // Color glyphs: built lazily on first use.
    builder: ?scene.Builder = null,
    sub: ?*renderer_mod.Renderer = null,
    stops: std.ArrayList(scene.Stop) = .empty,
    /// Bitmap glyph images for the glyph being rasterized.
    images: std.ArrayList([]Pixel) = .empty,

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa, .rasterizer = .init(gpa), .path = .init(gpa) };
    }

    pub fn deinit(c: *Cache) void {
        c.map.deinit(c.gpa);
        c.entries.deinit(c.gpa);
        c.masks.deinit(c.gpa);
        c.colors.deinit(c.gpa);
        c.rasterizer.deinit();
        c.path.deinit();
        c.contour_points.deinit(c.gpa);
        c.contour_ends.deinit(c.gpa);
        c.stops.deinit(c.gpa);
        c.freeImages();
        c.images.deinit(c.gpa);
        if (c.draw_funcs) |f| hb.hb_draw_funcs_destroy(f);
        if (c.paint_funcs) |f| hb.hb_paint_funcs_destroy(f);
        if (c.builder) |*b| b.deinit();
        if (c.sub) |s| s.destroy();
        c.* = undefined;
    }

    /// Called at the start of each frame; placements from earlier frames
    /// become invalid.
    pub fn beginFrame(c: *Cache) void {
        if (c.masks.items.len + c.colors.items.len * @sizeOf(Pixel) > budget_bytes) c.clear();
    }

    pub fn clear(c: *Cache) void {
        c.map.clearRetainingCapacity();
        c.entries.clearRetainingCapacity();
        c.masks.clearRetainingCapacity();
        c.colors.clearRetainingCapacity();
    }

    pub fn evictFont(c: *Cache, key: u64) void {
        // Entries are packed; dropping one font means rebuilding. Fonts go
        // away rarely, so clearing everything is simpler and as correct.
        var it = c.map.keyIterator();
        while (it.next()) |k| if (k.font == key) return c.clear();
    }

    pub fn entry(c: *const Cache, index: u32) Entry {
        return c.entries.items[index];
    }

    pub fn maskRow(c: *const Cache, e: Entry, y: usize) []const u8 {
        return c.masks.items[e.offset + y * e.width ..][0..e.width];
    }

    pub fn colorRow(c: *const Cache, e: Entry, y: usize) []const Pixel {
        return c.colors.items[e.offset + y * e.width ..][0..e.width];
    }

    /// Places the run's glyphs through `m`, rasterizing misses. Returns
    /// false when the run must be drawn as paths instead.
    pub fn place(c: *Cache, run: scene.GlyphRun, m: Affine, fg: scene.Color, out: *std.ArrayList(Placement)) Error!bool {
        if (!m.isAxisAligned() or !(m.a > 0) or !(m.d > 0)) return false;
        if (@abs(m.a - m.d) > 1e-4 * m.a) return false;
        const px_size = run.size * m.a;
        if (!(px_size <= max_cached_size)) return false;
        const font: *hb.hb_font_t = @ptrCast(run.font.handle);
        const size_key: u32 = @intFromFloat(@round(px_size * 64));
        const fg_key = rgba8(fg);
        const y_scale = xHeightScale(font, px_size);
        try out.ensureUnusedCapacity(c.gpa, run.glyphs.len);
        for (run.glyphs) |g| {
            const o = m.apply(.{ .x = g.x, .y = g.y });
            const q: i32 = @intFromFloat(@floor(o.x * 4 + 0.5));
            const phase: u8 = @intCast(@mod(q, 4));
            var key: Key = .{ .font = run.font.key, .glyph = g.id, .size = size_key, .phase = phase, .fg = 0 };
            var index = c.map.get(key) orelse try c.add(key, font, px_size, y_scale, fg);
            if (c.entries.items[index].kind == .redirect) {
                key.fg = fg_key;
                index = c.map.get(key) orelse try c.addColor(key, font, px_size, fg);
            }
            if (c.entries.items[index].width == 0) continue;
            out.appendAssumeCapacity(.{ .x = @divFloor(q, 4), .y = @intFromFloat(@round(o.y)), .entry = index });
        }
        return true;
    }

    /// Appends the run's outlines in run coordinates (for path drawing).
    pub fn outlines(c: *Cache, run: scene.GlyphRun, out: *raster.PathBuilder) Error!void {
        const font: *hb.hb_font_t = @ptrCast(run.font.handle);
        var xs: c_int = 0;
        var ys: c_int = 0;
        hb.hb_font_get_scale(font, &xs, &ys);
        if (xs == 0 or ys == 0) return;
        for (run.glyphs) |g| {
            c.path.reset();
            try c.drawOutline(font, g.id);
            const m: Affine = .{ .a = run.size / @as(f32, @floatFromInt(xs)), .d = -run.size / @as(f32, @floatFromInt(ys)), .e = g.x, .f = g.y };
            try out.append(c.path.path(), m);
        }
    }

    fn add(c: *Cache, key: Key, font: *hb.hb_font_t, px_size: f32, y_scale: f32, fg: scene.Color) Error!u32 {
        const face = hb.hb_font_get_face(font);
        if (isColorGlyph(font, face, key.glyph)) {
            const index = try c.push(.{ .kind = .redirect, .left = 0, .top = 0, .width = 0, .height = 0, .offset = 0 });
            try c.map.put(c.gpa, key, index);
            var ck = key;
            ck.fg = rgba8(fg);
            if (c.map.get(ck) == null) _ = try c.addColor(ck, font, px_size, fg);
            return index;
        }
        const index = try c.rasterizeMask(key, font, px_size, y_scale);
        try c.map.put(c.gpa, key, index);
        return index;
    }

    fn push(c: *Cache, e: Entry) Error!u32 {
        try c.entries.append(c.gpa, e);
        return @intCast(c.entries.items.len - 1);
    }

    fn ensureDrawFuncs(c: *Cache) Error!*hb.hb_draw_funcs_t {
        if (c.draw_funcs) |f| return f;
        const f = hb.hb_draw_funcs_create() orelse return error.OutOfMemory;
        hb.hb_draw_funcs_set_move_to_func(f, Draw.moveTo, null, null);
        hb.hb_draw_funcs_set_line_to_func(f, Draw.lineTo, null, null);
        hb.hb_draw_funcs_set_quadratic_to_func(f, Draw.quadTo, null, null);
        hb.hb_draw_funcs_set_cubic_to_func(f, Draw.cubicTo, null, null);
        hb.hb_draw_funcs_set_close_path_func(f, Draw.closePath, null, null);
        hb.hb_draw_funcs_make_immutable(f);
        c.draw_funcs = f;
        return f;
    }

    /// Draws a glyph outline (font units, y up) into c.path.
    fn drawOutline(c: *Cache, font: *hb.hb_font_t, glyph: u32) Error!void {
        try drawInto(c, font, glyph, &c.path);
    }

    fn drawInto(c: *Cache, font: *hb.hb_font_t, glyph: u32, b: *raster.PathBuilder) Error!void {
        const funcs = try c.ensureDrawFuncs();
        var ctx: Draw = .{ .b = b };
        _ = hb.hb_font_draw_glyph_or_fail(font, glyph, funcs, &ctx);
        if (ctx.failed) return error.OutOfMemory;
    }

    fn rasterizeMask(c: *Cache, key: Key, font: *hb.hb_font_t, px_size: f32, y_scale: f32) Error!u32 {
        var xs: c_int = 0;
        var ys: c_int = 0;
        hb.hb_font_get_scale(font, &xs, &ys);
        const empty: Entry = .{ .kind = .mask, .left = 0, .top = 0, .width = 0, .height = 0, .offset = 0 };
        if (xs == 0 or ys == 0) return c.push(empty);
        c.path.reset();
        try c.drawOutline(font, key.glyph);
        if (c.path.path().isEmpty()) return c.push(empty);
        const m: Affine = .{
            .a = px_size / @as(f32, @floatFromInt(xs)),
            .d = -px_size * y_scale / @as(f32, @floatFromInt(ys)),
            .e = @as(f32, @floatFromInt(key.phase)) / 4,
        };
        const darken = stemDarkening(px_size);
        const window = c.path.path().transformedBounds(m).outset(darken + 1).roundOut();
        if (window.isEmpty()) return c.push(empty);
        try c.rasterizer.begin(window);
        if (darken > 0) {
            try c.collectContours(m);
            embolden(c.contour_points.items, c.contour_ends.items, darken / 2);
            var start: u32 = 0;
            for (c.contour_ends.items) |end| {
                const pts = c.contour_points.items[start..end];
                for (pts, 0..) |p, i| c.rasterizer.addLine(p, pts[(i + 1) % pts.len]);
                start = end;
            }
        } else {
            c.rasterizer.addPath(c.path.path(), m, raster.default_tolerance);
        }
        const w: usize = @intCast(window.width());
        const h: usize = @intCast(window.height());
        const offset = c.masks.items.len;
        try c.masks.resize(c.gpa, offset + w * h);
        c.rasterizer.finish(.nonzero, c.masks.items[offset..], w);
        return c.push(.{ .kind = .mask, .left = window.x0, .top = window.y0, .width = @intCast(w), .height = @intCast(h), .offset = offset });
    }

    fn collectContours(c: *Cache, m: Affine) Error!void {
        c.contour_points.clearRetainingCapacity();
        c.contour_ends.clearRetainingCapacity();
        var sink: ContourSink = .{ .c = c };
        try raster.flatten(c.path.path(), m, raster.default_tolerance, &sink);
    }

    const ContourSink = struct {
        c: *Cache,
        start: usize = 0,

        pub fn begin(s: *ContourSink, p: Point) Error!void {
            s.start = s.c.contour_points.items.len;
            try s.c.contour_points.append(s.c.gpa, p);
        }
        pub fn lineTo(s: *ContourSink, p: Point) Error!void {
            const pts = s.c.contour_points.items;
            if (pts[pts.len - 1].eql(p)) return;
            try s.c.contour_points.append(s.c.gpa, p);
        }
        pub fn end(s: *ContourSink, _: bool) Error!void {
            const pts = s.c.contour_points.items;
            if (pts.len - s.start > 1 and pts[pts.len - 1].eql(pts[s.start])) s.c.contour_points.items.len -= 1;
            if (s.c.contour_points.items.len - s.start < 3) {
                s.c.contour_points.items.len = s.start;
                return;
            }
            try s.c.contour_ends.append(s.c.gpa, @intCast(s.c.contour_points.items.len));
        }
    };

    fn addColor(c: *Cache, key: Key, font: *hb.hb_font_t, px_size: f32, fg: scene.Color) Error!u32 {
        const index = try c.rasterizeColor(key, font, px_size, fg);
        try c.map.put(c.gpa, key, index);
        return index;
    }

    fn rasterizeColor(c: *Cache, key: Key, font: *hb.hb_font_t, px_size: f32, fg: scene.Color) Error!u32 {
        const empty: Entry = .{ .kind = .color, .left = 0, .top = 0, .width = 0, .height = 0, .offset = 0 };
        var xs: c_int = 0;
        var ys: c_int = 0;
        hb.hb_font_get_scale(font, &xs, &ys);
        var ext: hb.hb_glyph_extents_t = undefined;
        if (xs == 0 or ys == 0 or hb.hb_font_get_glyph_extents(font, key.glyph, &ext) == 0) return c.push(empty);
        const m: Affine = .{
            .a = px_size / @as(f32, @floatFromInt(xs)),
            .d = -px_size / @as(f32, @floatFromInt(ys)),
            .e = @as(f32, @floatFromInt(key.phase)) / 4,
        };
        const font_box: Rect = .{
            .x0 = @floatFromInt(ext.x_bearing),
            .y0 = @floatFromInt(ext.y_bearing + ext.height),
            .x1 = @floatFromInt(ext.x_bearing + ext.width),
            .y1 = @floatFromInt(ext.y_bearing),
        };
        const window = m.applyRect(font_box).outset(1).roundOut();
        if (window.isEmpty()) return c.push(empty);

        if (c.builder == null) c.builder = scene.Builder.init(c.gpa);
        if (c.sub == null) c.sub = try renderer_mod.Renderer.create(c.gpa, .serial);
        const b = &c.builder.?;
        b.reset();
        const funcs = try c.ensurePaintFuncs();
        defer c.freeImages();
        var ctx: Paint = .{ .c = c, .b = b, .scale = m.a };
        hb.hb_font_paint_glyph(font, key.glyph, funcs, &ctx, 0, hbColor(fg));
        // Unbalanced output from a malformed font: close what is open.
        while (ctx.depth > 0) : (ctx.depth -= 1) b.popLayer() catch break;
        if (ctx.err) |e| return e;
        const list = b.finish(0) catch return c.push(empty);

        const w: u32 = @intCast(window.width());
        const h: u32 = @intCast(window.height());
        const sub = c.sub.?;
        try sub.resize(w, h);
        try sub.render(list, .{ .root = m.then(.translate(@floatFromInt(-window.x0), @floatFromInt(-window.y0))) });
        const offset = c.colors.items.len;
        try c.colors.appendSlice(c.gpa, sub.pixels());
        return c.push(.{ .kind = .color, .left = window.x0, .top = window.y0, .width = w, .height = h, .offset = offset });
    }

    fn freeImages(c: *Cache) void {
        for (c.images.items) |img| c.gpa.free(img);
        c.images.clearRetainingCapacity();
    }

    fn ensurePaintFuncs(c: *Cache) Error!*hb.hb_paint_funcs_t {
        if (c.paint_funcs) |f| return f;
        const f = hb.hb_paint_funcs_create() orelse return error.OutOfMemory;
        hb.hb_paint_funcs_set_push_transform_func(f, Paint.pushTransform, null, null);
        hb.hb_paint_funcs_set_pop_transform_func(f, Paint.pop, null, null);
        hb.hb_paint_funcs_set_push_clip_glyph_func(f, Paint.pushClipGlyph, null, null);
        hb.hb_paint_funcs_set_push_clip_rectangle_func(f, Paint.pushClipRectangle, null, null);
        hb.hb_paint_funcs_set_push_clip_path_start_func(f, Paint.pushClipPathStart, null, null);
        hb.hb_paint_funcs_set_push_clip_path_end_func(f, Paint.pushClipPathEnd, null, null);
        hb.hb_paint_funcs_set_pop_clip_func(f, Paint.pop, null, null);
        hb.hb_paint_funcs_set_color_func(f, Paint.color, null, null);
        hb.hb_paint_funcs_set_linear_gradient_func(f, Paint.linearGradient, null, null);
        hb.hb_paint_funcs_set_radial_gradient_func(f, Paint.radialGradient, null, null);
        hb.hb_paint_funcs_set_sweep_gradient_func(f, Paint.sweepGradient, null, null);
        hb.hb_paint_funcs_set_push_group_for_func(f, Paint.pushGroupFor, null, null);
        hb.hb_paint_funcs_set_image_func(f, Paint.image, null, null);
        hb.hb_paint_funcs_set_pop_group_func(f, Paint.popGroup, null, null);
        hb.hb_paint_funcs_make_immutable(f);
        c.paint_funcs = f;
        return f;
    }
};

/// HarfBuzz draw callbacks into a PathBuilder.
const Draw = struct {
    b: *raster.PathBuilder,
    failed: bool = false,

    fn ctx(p: ?*anyopaque) *Draw {
        return @ptrCast(@alignCast(p.?));
    }

    fn check(d: *Draw, r: error{OutOfMemory}!void) void {
        r catch {
            d.failed = true;
        };
    }

    fn moveTo(_: ?*hb.hb_draw_funcs_t, data: ?*anyopaque, _: [*c]hb.hb_draw_state_t, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
        const d = ctx(data);
        d.check(d.b.moveTo(x, y));
    }
    fn lineTo(_: ?*hb.hb_draw_funcs_t, data: ?*anyopaque, _: [*c]hb.hb_draw_state_t, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
        const d = ctx(data);
        d.check(d.b.lineTo(x, y));
    }
    fn quadTo(_: ?*hb.hb_draw_funcs_t, data: ?*anyopaque, _: [*c]hb.hb_draw_state_t, cx: f32, cy: f32, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
        const d = ctx(data);
        d.check(d.b.quadTo(cx, cy, x, y));
    }
    fn cubicTo(_: ?*hb.hb_draw_funcs_t, data: ?*anyopaque, _: [*c]hb.hb_draw_state_t, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
        const d = ctx(data);
        d.check(d.b.cubicTo(c1x, c1y, c2x, c2y, x, y));
    }
    fn closePath(_: ?*hb.hb_draw_funcs_t, data: ?*anyopaque, _: [*c]hb.hb_draw_state_t, _: ?*anyopaque) callconv(.c) void {
        const d = ctx(data);
        d.check(d.b.close());
    }
};

/// Everything a COLR paint covers: the area outside any clip is bounded by
/// the glyph's clip box, so this only needs to exceed it.
const paint_everywhere: Rect = .{ .x0 = -1e6, .y0 = -1e6, .x1 = 1e6, .y1 = 1e6 };

/// HarfBuzz paint callbacks lowered into display list commands, in font
/// units (y up); the renderer's root transform maps them to pixels.
const Paint = struct {
    c: *Cache,
    b: *scene.Builder,
    /// Device pixels per font unit, to size bitmap glyphs.
    scale: f32,
    depth: u32 = 0,
    err: ?Error = null,
    clip_path: ?raster.PathBuilder = null,
    draw: Draw = undefined,

    fn ctx(p: ?*anyopaque) *Paint {
        return @ptrCast(@alignCast(p.?));
    }

    fn check(p: *Paint, r: scene.Error!void) void {
        r catch |e| {
            if (p.err == null) p.err = switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                // Malformed font data: drop the command.
                else => return,
            };
        };
    }

    fn pushLayer(p: *Paint, layer: scene.Layer) void {
        if (p.b.pushLayer(layer)) {
            p.depth += 1;
        } else |e| {
            p.check(e);
            // Keep push/pop balanced: an empty layer stands in.
            if (p.b.pushLayer(.{})) {
                p.depth += 1;
            } else |e2| p.check(e2);
        }
    }

    fn pop(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const p = ctx(data);
        if (p.depth == 0) return;
        p.depth -= 1;
        p.check(p.b.popLayer());
    }

    fn pushTransform(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, xx: f32, yx: f32, xy: f32, yy: f32, dx: f32, dy: f32, _: ?*anyopaque) callconv(.c) void {
        ctx(data).pushLayer(.{ .transform = .{ .a = xx, .b = yx, .c = xy, .d = yy, .e = dx, .f = dy } });
    }

    fn pushClipGlyph(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, glyph: hb.hb_codepoint_t, font: ?*hb.hb_font_t, _: ?*anyopaque) callconv(.c) void {
        const p = ctx(data);
        const c = p.c;
        c.path.reset();
        c.drawOutline(font.?, glyph) catch |e| p.check(e);
        p.pushLayer(.{ .clip = .{ .shape = .{ .path = c.path.path() } } });
    }

    fn pushClipRectangle(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, _: ?*anyopaque) callconv(.c) void {
        ctx(data).pushLayer(.{ .clip = .{ .shape = .{ .rect = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } } } });
    }

    fn pushClipPathStart(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, draw_data: [*c]?*anyopaque, _: ?*anyopaque) callconv(.c) ?*hb.hb_draw_funcs_t {
        const p = ctx(data);
        const funcs = p.c.ensureDrawFuncs() catch |e| {
            p.check(e);
            if (draw_data != null) draw_data.* = null;
            return null;
        };
        p.c.path.reset();
        p.draw = .{ .b = &p.c.path };
        if (draw_data != null) draw_data.* = &p.draw;
        return funcs;
    }

    fn pushClipPathEnd(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const p = ctx(data);
        if (p.draw.failed) p.err = error.OutOfMemory;
        p.pushLayer(.{ .clip = .{ .shape = .{ .path = p.c.path.path() } } });
    }

    fn color(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, _: hb.hb_bool_t, c: hb.hb_color_t, _: ?*anyopaque) callconv(.c) void {
        const p = ctx(data);
        p.check(p.b.fillRect(paint_everywhere, .{ .solid = fromHb(c) }));
    }

    fn gradient(p: *Paint, line: [*c]hb.hb_color_line_t, geometry: scene.Gradient.Geometry) void {
        const c = p.c;
        const n = hb.hb_color_line_get_color_stops(line, 0, null, null);
        if (n == 0) return;
        var hb_stops: [64]hb.hb_color_stop_t = undefined;
        var count: c_uint = @min(n, hb_stops.len);
        _ = hb.hb_color_line_get_color_stops(line, 0, &count, &hb_stops);
        c.stops.clearRetainingCapacity();
        c.stops.ensureTotalCapacity(c.gpa, count) catch |e| return p.check(e);
        for (hb_stops[0..count]) |s| c.stops.appendAssumeCapacity(.{ .offset = s.offset, .color = fromHb(s.color) });
        std.sort.insertion(scene.Stop, c.stops.items, {}, struct {
            fn lt(_: void, a: scene.Stop, b: scene.Stop) bool {
                return a.offset < b.offset;
            }
        }.lt);
        const extend: scene.Extend = switch (hb.hb_color_line_get_extend(line)) {
            hb.HB_PAINT_EXTEND_REPEAT => .repeat,
            hb.HB_PAINT_EXTEND_REFLECT => .reflect,
            else => .pad,
        };
        p.check(p.b.fillRect(paint_everywhere, .{ .gradient = .{ .geometry = geometry, .stops = c.stops.items, .extend = extend } }));
    }

    fn linearGradient(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, line: [*c]hb.hb_color_line_t, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, _: ?*anyopaque) callconv(.c) void {
        // COLRv1 rotates the gradient line by a third point: project p1
        // onto the normal of p0 → p2.
        const q2x = x2 - x0;
        const q2y = y2 - y0;
        const s = q2x * q2x + q2y * q2y;
        var e: Point = .{ .x = x1, .y = y1 };
        if (s >= 1e-6) {
            const k = (q2x * (x1 - x0) + q2y * (y1 - y0)) / s;
            e = .{ .x = x1 - k * q2x, .y = y1 - k * q2y };
        }
        ctx(data).gradient(line, .{ .linear = .{ .p0 = .{ .x = x0, .y = y0 }, .p1 = e } });
    }

    fn radialGradient(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, line: [*c]hb.hb_color_line_t, x0: f32, y0: f32, r0: f32, x1: f32, y1: f32, r1: f32, _: ?*anyopaque) callconv(.c) void {
        ctx(data).gradient(line, .{ .radial = .{ .c0 = .{ .x = x0, .y = y0 }, .r0 = r0, .c1 = .{ .x = x1, .y = y1 }, .r1 = r1 } });
    }

    fn sweepGradient(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, line: [*c]hb.hb_color_line_t, x0: f32, y0: f32, a0: f32, a1: f32, _: ?*anyopaque) callconv(.c) void {
        // Angles are counter-clockwise in font space (y up); gradient
        // space is font space, so they apply as given.
        ctx(data).gradient(line, .{ .sweep = .{ .center = .{ .x = x0, .y = y0 }, .start_angle = a0, .end_angle = a1 } });
    }

    /// CBDT and sbix bitmaps arrive as PNG data positioned by `extents` in
    /// font units. They are decoded, box-filtered to their device size, and
    /// drawn as an image.
    fn image(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, blob: ?*hb.hb_blob_t, _: c_uint, _: c_uint, format: hb.hb_tag_t, _: f32, extents: [*c]hb.hb_glyph_extents_t, _: ?*anyopaque) callconv(.c) hb.hb_bool_t {
        const p = ctx(data);
        if (format != hb.HB_PAINT_IMAGE_FORMAT_PNG or extents == null) return 0;
        const ext = extents.*;
        if (ext.width == 0 or ext.height == 0) return 1;
        var len: c_uint = 0;
        const bytes = hb.hb_blob_get_data(blob, &len);
        if (bytes == null or len == 0) return 0;
        var img: wuffs.siv_image = undefined;
        if (wuffs.siv_image_decode(bytes, len, max_bitmap_pixels, &img) != wuffs.SIV_IMAGE_OK) return 0;
        defer wuffs.siv_image_free(&img);

        const fw: f32 = @floatFromInt(@abs(ext.width));
        const fh: f32 = @floatFromInt(@abs(ext.height));
        const tw: u32 = @intFromFloat(std.math.clamp(@round(fw * p.scale), 1, @as(f32, @floatFromInt(img.width))));
        const th: u32 = @intFromFloat(std.math.clamp(@round(fh * p.scale), 1, @as(f32, @floatFromInt(img.height))));
        const c = p.c;
        c.images.ensureUnusedCapacity(c.gpa, 1) catch |e| {
            p.check(e);
            return 1;
        };
        const px = c.gpa.alloc(Pixel, @as(usize, tw) * th) catch |e| {
            p.check(e);
            return 1;
        };
        c.images.appendAssumeCapacity(px);
        boxResample(img.pixels[0 .. @as(usize, img.width) * img.height * 4], img.width, img.height, px, tw, th);

        // Image rows run down from the top edge at y_bearing (font space
        // is y up).
        p.pushLayer(.{ .transform = .{ .a = 1, .d = -1, .e = @floatFromInt(ext.x_bearing), .f = @floatFromInt(ext.y_bearing) } });
        p.check(p.b.image(.{
            .image = .{ .pixels = @ptrCast(px.ptr), .width = tw, .height = th, .stride = tw * 8, .format = .rgba16_linear_premul, .key = 0 },
            .src = .xywh(0, 0, @floatFromInt(tw), @floatFromInt(th)),
            .dst = .xywh(0, 0, fw, fh),
        }));
        pop(null, data, null);
        return 1;
    }

    fn pushGroupFor(_: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, mode: hb.hb_paint_composite_mode_t, _: ?*anyopaque) callconv(.c) void {
        const m: u8 = @intCast(@min(@as(c_uint, @intCast(mode)), @intFromEnum(scene.BlendMode.luminosity)));
        ctx(data).pushLayer(.{ .isolate = true, .blend = @enumFromInt(m) });
    }

    fn popGroup(funcs: ?*hb.hb_paint_funcs_t, data: ?*anyopaque, _: hb.hb_paint_composite_mode_t, user: ?*anyopaque) callconv(.c) void {
        pop(funcs, data, user);
    }
};

/// Largest bitmap glyph image decoded.
const max_bitmap_pixels = 4096 * 4096;

fn isColorGlyph(font: *hb.hb_font_t, face: ?*hb.hb_face_t, glyph: u32) bool {
    if (hb.hb_ot_color_glyph_has_paint(face, glyph) != 0) return true;
    if (hb.hb_ot_color_glyph_get_layers(face, glyph, 0, null, null) > 0) return true;
    if (hb.hb_ot_color_has_png(face) == 0) return false;
    const blob = hb.hb_ot_color_glyph_reference_png(font, glyph);
    defer hb.hb_blob_destroy(blob);
    return hb.hb_blob_get_length(blob) > 0;
}

/// Area-weighted resample of straight-alpha sRGB RGBA8 into linear
/// premultiplied pixels, for downscaling bitmap glyphs (sizes equal to the
/// source copy through).
pub fn boxResample(src: []const u8, sw: u32, sh: u32, dst: []Pixel, dw: u32, dh: u32) void {
    const sx = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(dw));
    const sy = @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(dh));
    for (0..dh) |ty| {
        const y0 = @as(f32, @floatFromInt(ty)) * sy;
        const y1 = y0 + sy;
        for (0..dw) |tx| {
            const x0 = @as(f32, @floatFromInt(tx)) * sx;
            const x1 = x0 + sx;
            var acc: @Vector(4, f32) = @splat(0);
            var yi: usize = @intFromFloat(@floor(y0));
            while (@as(f32, @floatFromInt(yi)) < y1 and yi < sh) : (yi += 1) {
                const wy = @min(@as(f32, @floatFromInt(yi + 1)), y1) - @max(@as(f32, @floatFromInt(yi)), y0);
                var xi: usize = @intFromFloat(@floor(x0));
                while (@as(f32, @floatFromInt(xi)) < x1 and xi < sw) : (xi += 1) {
                    const wx = @min(@as(f32, @floatFromInt(xi + 1)), x1) - @max(@as(f32, @floatFromInt(xi)), x0);
                    const p = src[(yi * sw + xi) * 4 ..][0..4];
                    const a = @as(f32, @floatFromInt(p[3])) / 255;
                    const lin: @Vector(4, f32) = .{
                        color.srgbToLinear(@as(f32, @floatFromInt(p[0])) / 255) * a,
                        color.srgbToLinear(@as(f32, @floatFromInt(p[1])) / 255) * a,
                        color.srgbToLinear(@as(f32, @floatFromInt(p[2])) / 255) * a,
                        a,
                    };
                    acc += lin * @as(@Vector(4, f32), @splat(wx * wy));
                }
            }
            acc /= @as(@Vector(4, f32), @splat(sx * sy));
            dst[ty * dw + tx] = .{ color.toU16(@min(acc[0], acc[3])), color.toU16(@min(acc[1], acc[3])), color.toU16(@min(acc[2], acc[3])), color.toU16(acc[3]) };
        }
    }
}

fn fromHb(c: hb.hb_color_t) scene.Color {
    return scene.Color.srgb8(@truncate(c >> 8), @truncate(c >> 16), @truncate(c >> 24), @truncate(c));
}

fn hbColor(c: scene.Color) hb.hb_color_t {
    const v = rgba8(c);
    // RGBA8 → hb's BGRA packing.
    const r = v >> 24;
    const g = (v >> 16) & 0xff;
    const b = (v >> 8) & 0xff;
    const a = v & 0xff;
    return (b << 24) | (g << 16) | (r << 8) | a;
}

fn rgba8(c: scene.Color) u32 {
    const r: u32 = @intFromFloat(std.math.clamp(scene.linearToSrgb(c.r), 0, 1) * 255 + 0.5);
    const g: u32 = @intFromFloat(std.math.clamp(scene.linearToSrgb(c.g), 0, 1) * 255 + 0.5);
    const b: u32 = @intFromFloat(std.math.clamp(scene.linearToSrgb(c.b), 0, 1) * 255 + 0.5);
    const a: u32 = @intFromFloat(std.math.clamp(c.a, 0, 1) * 255 + 0.5);
    return (r << 24) | (g << 16) | (b << 8) | a;
}

/// Vertical scale that puts the x-height on a whole pixel at text sizes,
/// so the tops of lowercase letters are crisp. Rounds up from a fraction of
/// 0.375, like FreeType's autohinter (which GTK's default hintslight uses):
/// Noto Sans at 12 px gets a 7 px x-height (+8.8%) instead of 6 (-6.7%),
/// as in GTK. Bounded to -8%..+12%.
pub fn xHeightScale(font: *hb.hb_font_t, px_size: f32) f32 {
    if (px_size > 32) return 1;
    var pos: hb.hb_position_t = 0;
    if (hb.hb_ot_metrics_get_position(font, hb.HB_OT_METRICS_TAG_X_HEIGHT, &pos) == 0 or pos <= 0) return 1;
    var xs: c_int = 0;
    var ys: c_int = 0;
    hb.hb_font_get_scale(font, &xs, &ys);
    if (ys == 0) return 1;
    const xh = @as(f32, @floatFromInt(pos)) * px_size / @as(f32, @floatFromInt(ys));
    if (xh < 2) return 1;
    return std.math.clamp(@floor(xh + 0.625) / xh, 0.92, 1.12);
}

/// Stem darkening for small unhinted sizes: total stroke width added, in
/// pixels. It applies to every foreground, and dark text at 11-13 px is
/// already heavier than GTK's (D14), so light text gets its weight from
/// ContrastLuts instead.
pub fn stemDarkening(px_size: f32) f32 {
    const max: f32 = 0.25;
    const full: f32 = 10;
    const none: f32 = 18;
    if (px_size <= full) return max;
    if (px_size >= none) return 0;
    return max * (none - px_size) / (none - full);
}

/// Offsets every contour vertex outward (away from the filled side) by
/// `d` pixels, with a miter limit. Orientation is taken from the total
/// signed area, so outer contours grow and counters shrink.
pub fn embolden(points: []Point, ends: []const u32, d: f32) void {
    var area: f32 = 0;
    var start: u32 = 0;
    for (ends) |end| {
        const pts = points[start..end];
        for (pts, 0..) |p, i| {
            const q = pts[(i + 1) % pts.len];
            area += p.x * q.y - q.x * p.y;
        }
        start = end;
    }
    // Positive area: clockwise on screen, filled on the right of each edge.
    const sign: f32 = if (area >= 0) 1 else -1;
    start = 0;
    for (ends) |end| {
        const pts = points[start..end];
        const n = pts.len;
        const first = pts[0];
        var prev = pts[n - 1];
        for (0..n) |i| {
            const cur = pts[i];
            const next = if (i + 1 < n) pts[i + 1] else first;
            const n0 = outward(cur.sub(prev).normalize(), sign);
            const n1 = outward(next.sub(cur).normalize(), sign);
            const b = n0.add(n1);
            const bl2 = @max(b.dot(b), 0.5);
            prev = cur;
            pts[i] = cur.add(b.scale(2 * d / bl2));
        }
        start = end;
    }
}

fn outward(dir: Point, sign: f32) Point {
    return .{ .x = dir.y * sign, .y = -dir.x * sign };
}

/// Coverage correction for text composited in linear light (D11): maps
/// coverage so that text looks as it does with gamma-space blending, which
/// Linux users compare against. Indexed by the foreground's encoded
/// luminance, assuming a contrasting background: white behind dark text,
/// and a dark theme's background (#181818, near siv's #18181b) behind light
/// text. Assuming black there thinned light text on real dark backgrounds
/// by about a tenth at half coverage.
pub const ContrastLuts = struct {
    pub const levels = 16;
    const dark_bg: f32 = 24.0 / 255.0;
    tables: [levels][256]u16,

    pub fn init(l: *ContrastLuts) void {
        for (&l.tables, 0..) |*t, i| {
            const fe = @as(f32, @floatFromInt(i)) / (levels - 1);
            const be: f32 = if (fe < 0.5) 1 else dark_bg;
            const f = scene.srgbToLinear(fe);
            const bg = scene.srgbToLinear(be);
            for (t, 0..) |*v, a| {
                const af = @as(f32, @floatFromInt(a)) / 255;
                const lin = scene.srgbToLinear(af * fe + (1 - af) * be);
                const corrected = if (@abs(f - bg) > 1e-4) (lin - bg) / (f - bg) else af;
                v.* = color.toU16(corrected);
            }
        }
    }

    pub fn index(fg: scene.Color) u8 {
        const e = scene.linearToSrgb(std.math.clamp(fg.luminance(), 0, 1));
        return @intFromFloat(@round(e * (levels - 1)));
    }
};

test "contrast tables" {
    var l: ContrastLuts = undefined;
    l.init();
    // Dark text gains coverage, light text loses it, ends are fixed.
    try std.testing.expect(l.tables[0][128] > 128 * 257);
    try std.testing.expect(l.tables[levels_last][128] < 128 * 257);
    for (l.tables) |t| {
        try std.testing.expectEqual(@as(u16, 0), t[0]);
        try std.testing.expectEqual(@as(u16, 65535), t[255]);
    }
    // White text at half coverage on #181818, blended in linear light,
    // lands where gamma-space blending puts it.
    const c = @as(f32, @floatFromInt(l.tables[levels_last][128])) / 65535;
    const bg = scene.srgbToLinear(24.0 / 255.0);
    const want = (128 + (255 - 128) * @as(f32, 0x18) / 255) / 255;
    try std.testing.expectApproxEqAbs(want, scene.linearToSrgb(c + (1 - c) * bg), 0.003);
}

const levels_last = ContrastLuts.levels - 1;

test "embolden grows a square by d on each side" {
    // Clockwise square (y down).
    var pts = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } };
    embolden(&pts, &.{4}, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), pts[0].x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), pts[0].y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), pts[2].x, 1e-5);
    // Same result for the counter-clockwise square.
    var ccw = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 4 }, .{ .x = 4, .y = 4 }, .{ .x = 4, .y = 0 } };
    embolden(&ccw, &.{4}, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), ccw[0].x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), ccw[2].y, 1e-5);
}

test "box resample averages in linear light" {
    // Black and white columns average to linear 0.5, not sRGB 0.5.
    const src = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 };
    var dst: [1]Pixel = undefined;
    boxResample(&src, 2, 1, &dst, 1, 1);
    try std.testing.expectEqual(Pixel{ 32768, 32768, 32768, 65535 }, dst[0]);
}
