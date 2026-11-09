//! Glyph rendering (D14): HarfBuzz draw and paint into the shared coverage
//! rasterizer, a glyph cache, and the unhinted-text mitigations.
//!
//! - Outline glyphs come from hb_font_draw_glyph into a raster.PathBuilder
//!   and are rasterized into 8-bit masks.
//! - Color glyphs (COLRv0/v1, and CBDT/sbix bitmaps decoded by the image
//!   module) come
//!   from hb_font_paint_glyph, which is
//!   lowered into a scene display list (layers for transforms, clips, and
//!   composite groups; gradient fills) and rendered by a CPU renderer into a
//!   16-bit linear premultiplied bitmap. The same lowering serves Vulkan,
//!   which uploads these bitmaps.
//! - Entries are keyed by font key, glyph, pixel size (1/64 px), 1/4-
//!   pixel horizontal phase, and dilation class; color glyphs also by
//!   foreground color.
//! - Mitigations for unhinted text: baselines snap to whole pixels, the
//!   x-height is scaled vertically to a whole pixel at small sizes,
//!   outlines are dilated as macOS's font smoothing does (`dilation`), and
//!   coverage is corrected for contrast when composited (ContrastLuts).
//! - Glyphs whose contours overlap (common in variable fonts) rasterize
//!   with per-sample winding, so overlaps do not add up coverage.
//!
//! Runs whose transform is not a uniform positive scale plus translation,
//! or whose glyphs exceed `max_cached_size`, are drawn as paths instead.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
/// The HarfBuzz bindings, for callers that build fonts for glyph runs.
pub const hb = @import("harfbuzz");
const image_mod = @import("image");
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
    /// Dilation class (see `dilationClass`) for outline glyphs.
    class: u8,
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
    contour_info: std.ArrayList(ContourInfo) = .empty,
    draw_funcs: ?*hb.hb_draw_funcs_t = null,
    paint_funcs: ?*hb.hb_paint_funcs_t = null,
    // Color glyphs: built lazily on first use.
    builder: ?scene.Builder = null,
    sub: ?*renderer_mod.Renderer = null,
    stops: std.ArrayList(scene.Stop) = .empty,
    /// Bitmap glyph images for the glyph being rasterized.
    images: std.ArrayList([]Pixel) = .empty,
    /// Font smoothing: outlines are dilated (`dilation`). Off, as
    /// browsers' test runners turn it off, glyphs keep their outlines'
    /// exact edges, which reftests compare against boxes (D14).
    smoothing: bool = true,

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
        c.contour_info.deinit(c.gpa);
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

    /// Drops every entry and frees their memory, under memory pressure
    /// (D42); glyphs rasterize again as frames draw them.
    pub fn trim(c: *Cache) void {
        c.map.clearAndFree(c.gpa);
        c.entries.clearAndFree(c.gpa);
        c.masks.clearAndFree(c.gpa);
        c.colors.clearAndFree(c.gpa);
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
        const class = dilationClass(fg);
        const y_scale = xHeightScale(font, px_size, c.dilationAt(px_size, 0));
        try out.ensureUnusedCapacity(c.gpa, run.glyphs.len);
        for (run.glyphs) |g| {
            const o = m.apply(.{ .x = g.x, .y = g.y });
            const q: i32 = @intFromFloat(@floor(o.x * 4 + 0.5));
            const phase: u8 = @intCast(@mod(q, 4));
            var key: Key = .{ .font = run.font.key, .glyph = g.id, .size = size_key, .phase = phase, .class = class, .fg = 0 };
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

    fn dilationAt(c: *const Cache, px_size: f32, class: u8) f32 {
        return if (c.smoothing) dilation(px_size, class) else 0;
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
        const d = c.dilationAt(px_size, key.class);
        const window = c.path.path().transformedBounds(m).outset(d + 1).roundOut();
        if (window.isEmpty()) return c.push(empty);
        try c.collectContours(m);
        // Strokes grow by d: half on each side, then up by half, so bottom
        // edges (the baseline) stay and tops rise by d.
        embolden(c.contour_points.items, c.contour_ends.items, d / 2);
        for (c.contour_points.items) |*p| p.y -= d / 2;
        const w: usize = @intCast(window.width());
        const h: usize = @intCast(window.height());
        const offset = c.masks.items.len;
        try c.masks.resize(c.gpa, offset + w * h);
        const out = c.masks.items[offset..];
        // Overlapping parts (several contours, or one crossing itself)
        // take the per-sample path; exact accumulation reveals the second
        // kind by summing past full coverage.
        var overlapping = try c.contoursOverlap();
        if (!overlapping) {
            try c.rasterizer.begin(window);
            var start: u32 = 0;
            for (c.contour_ends.items) |end| {
                const pts = c.contour_points.items[start..end];
                for (pts, 0..) |p, i| c.rasterizer.addLine(p, pts[(i + 1) % pts.len]);
                start = end;
            }
            overlapping = c.rasterizer.finishDetectingOverlap(out, w);
        }
        if (overlapping) try c.rasterizer.fillOverlapping(window, c.contour_points.items, c.contour_ends.items, out, w);
        return c.push(.{ .kind = .mask, .left = window.x0, .top = window.y0, .width = @intCast(w), .height = @intCast(h), .offset = offset });
    }

    fn collectContours(c: *Cache, m: Affine) Error!void {
        c.contour_points.clearRetainingCapacity();
        c.contour_ends.clearRetainingCapacity();
        var sink: ContourSink = .{ .c = c };
        try raster.flatten(c.path.path(), m, raster.default_tolerance, &sink);
    }

    /// Whether two contours of the same orientation have intersecting
    /// bounds: overlapping parts of a glyph (variable fonts keep them),
    /// which exact-area accumulation would count twice. Islands inside
    /// counters also match; drawing them the slower way is still correct.
    fn contoursOverlap(c: *Cache) Error!bool {
        const ends = c.contour_ends.items;
        if (ends.len < 2) return false;
        c.contour_info.clearRetainingCapacity();
        try c.contour_info.ensureTotalCapacity(c.gpa, ends.len);
        var start: u32 = 0;
        for (ends) |end| {
            const pts = c.contour_points.items[start..end];
            var info: ContourInfo = .{ .bounds = .{ .x0 = pts[0].x, .y0 = pts[0].y, .x1 = pts[0].x, .y1 = pts[0].y }, .area = 0 };
            for (pts, 0..) |p, i| {
                const q = pts[(i + 1) % pts.len];
                info.area += p.x * q.y - q.x * p.y;
                info.bounds = info.bounds.unite(.{ .x0 = p.x, .y0 = p.y, .x1 = p.x, .y1 = p.y });
            }
            c.contour_info.appendAssumeCapacity(info);
            start = end;
        }
        const infos = c.contour_info.items;
        for (infos, 0..) |a, i| for (infos[i + 1 ..]) |b| {
            if ((a.area > 0) != (b.area > 0)) continue;
            if (a.bounds.x0 < b.bounds.x1 and b.bounds.x0 < a.bounds.x1 and a.bounds.y0 < b.bounds.y1 and b.bounds.y0 < a.bounds.y1) return true;
        };
        return false;
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

const ContourInfo = struct { bounds: Rect, area: f32 };

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
        const fw: f32 = @floatFromInt(@abs(ext.width));
        const fh: f32 = @floatFromInt(@abs(ext.height));
        const c = p.c;
        // Decoded straight to the device size (never larger than the
        // bitmap), box-filtered in linear light.
        const img = image_mod.decode(c.gpa, bytes[0..len], .{
            .max_width = @intFromFloat(std.math.clamp(@round(fw * p.scale), 1, 1 << 16)),
            .max_height = @intFromFloat(std.math.clamp(@round(fh * p.scale), 1, 1 << 16)),
            .max_pixels = max_bitmap_pixels,
            .first_frame = true,
            .linear = true,
        }) catch |e| switch (e) {
            error.OutOfMemory => |oom| {
                p.check(oom);
                return 1;
            },
            else => return 0,
        };
        defer img.deinit(c.gpa);
        const tw = img.width;
        const th = img.height;
        c.images.ensureUnusedCapacity(c.gpa, 1) catch |e| {
            p.check(e);
            return 1;
        };
        const px = c.gpa.alloc(Pixel, @as(usize, tw) * th) catch |e| {
            p.check(e);
            return 1;
        };
        c.images.appendAssumeCapacity(px);
        @memcpy(std.mem.sliceAsBytes(px), img.frames[0].pixels);

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
/// so the tops of lowercase letters are crisp. The top is the dilated one
/// (`dilation` raises tops by `d`), with dark text's dilation so that every
/// color gets the same proportions. Rounds up from a fraction of 0.375, like
/// FreeType's autohinter (which GTK's default hintslight uses): Noto Sans
/// at 12 px gets a 7 px x-height instead of 6, as in GTK. Bounded to
/// -8%..+12%.
pub fn xHeightScale(font: *hb.hb_font_t, px_size: f32, d: f32) f32 {
    if (px_size > 32) return 1;
    var pos: hb.hb_position_t = 0;
    if (hb.hb_ot_metrics_get_position(font, hb.HB_OT_METRICS_TAG_X_HEIGHT, &pos) == 0 or pos <= 0) return 1;
    var xs: c_int = 0;
    var ys: c_int = 0;
    hb.hb_font_get_scale(font, &xs, &ys);
    if (ys == 0) return 1;
    const xh = @as(f32, @floatFromInt(pos)) * px_size / @as(f32, @floatFromInt(ys));
    if (xh < 2) return 1;
    return std.math.clamp((@floor(xh + d + 0.625) - d) / xh, 0.92, 1.12);
}

/// Stroke width added to outlines, in pixels, as macOS's font smoothing
/// adds it (measured on macOS 27, D14): proportional to the pixel size,
/// more for lighter text (`dilationClass`), and at most 0.6 px.
pub fn dilation(px_size: f32, class: u8) f32 {
    const per_px: f32 = 0.0113;
    const factors = [dilation_classes]f32{ 1, 1.43, 1.85, 2.3, 2.7 };
    return @min(0.6, per_px * factors[class] * px_size);
}

pub const dilation_classes = 5;

/// The dilation class of a foreground, from its encoded luminance: Core
/// Text picks its masks by foreground gray in five steps.
pub fn dilationClass(fg: scene.Color) u8 {
    const e = scene.linearToSrgb(std.math.clamp(fg.luminance(), 0, 1));
    const bounds = [dilation_classes - 1]f32{ 0.4, 0.64, 0.8, 0.96 };
    var class: u8 = 0;
    for (bounds) |b| class += @intFromBool(e >= b);
    return class;
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
/// coverage, per color channel, so that linear blending reproduces
/// blending in sRGB-encoded space, as Core Text blends and as Linux users
/// are used to. A table per encoded foreground and background channel
/// value (16 levels each). Text with no known background
/// (`scene.GlyphRun.background`) assumes a contrasting one: white behind
/// dark text, and a dark theme's background (#181818, near siv's #18181b)
/// behind light text.
pub const ContrastLuts = struct {
    pub const levels = 16;
    pub const count = levels * levels;
    const dark_bg: f32 = 24.0 / 255.0;
    tables: [count][256]u16,

    pub fn init(l: *ContrastLuts) void {
        for (0..levels) |fi| for (0..levels) |bi| {
            const fe = @as(f32, @floatFromInt(fi)) / (levels - 1);
            const be = @as(f32, @floatFromInt(bi)) / (levels - 1);
            const f = scene.srgbToLinear(fe);
            const bg = scene.srgbToLinear(be);
            for (&l.tables[fi * levels + bi], 0..) |*v, a| {
                const af = @as(f32, @floatFromInt(a)) / 255;
                const lin = scene.srgbToLinear(af * fe + (1 - af) * be);
                const corrected = if (@abs(f - bg) > 1e-4) (lin - bg) / (f - bg) else af;
                v.* = color.toU16(corrected);
            }
        };
    }

    /// The tables, built by the first caller and shared by every renderer.
    pub fn shared() *const ContrastLuts {
        if (shared_contrast_state.load(.acquire) != 2) {
            if (shared_contrast_state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
                shared_contrast.init();
                shared_contrast_state.store(2, .release);
            } else while (shared_contrast_state.load(.acquire) != 2) std.atomic.spinLoopHint();
        }
        return &shared_contrast;
    }

    /// The tables for the red, green, and blue channels of text in `fg`
    /// over `bg`, or over the assumed background.
    pub fn indices(fg: scene.Color, bg: ?scene.Color) [3]u8 {
        const assumed: f32 = if (scene.linearToSrgb(std.math.clamp(fg.luminance(), 0, 1)) < 0.5) 1 else dark_bg;
        const fs = [3]f32{ fg.r, fg.g, fg.b };
        var out: [3]u8 = undefined;
        for (&out, fs, 0..) |*o, f, i| {
            const be = if (bg) |b| scene.linearToSrgb(std.math.clamp(([3]f32{ b.r, b.g, b.b })[i], 0, 1)) else assumed;
            o.* = level(scene.linearToSrgb(std.math.clamp(f, 0, 1))) * levels + level(be);
        }
        return out;
    }

    fn level(e: f32) u8 {
        return @intFromFloat(@round(e * (levels - 1)));
    }
};

var shared_contrast: ContrastLuts = undefined;
/// 0: not built, 1: being built, 2: built.
var shared_contrast_state: std.atomic.Value(u8) = .init(0);

test "contrast tables reproduce sRGB-space blending per channel" {
    const l = ContrastLuts.shared();
    for (l.tables) |t| {
        try std.testing.expectEqual(@as(u16, 0), t[0]);
        try std.testing.expectEqual(@as(u16, 65535), t[255]);
    }
    // Dark text on white gains coverage, white text on dark loses it.
    const black_on_white = ContrastLuts.indices(.black, null);
    const white_on_dark = ContrastLuts.indices(.white, null);
    try std.testing.expect(l.tables[black_on_white[0]][128] > 128 * 257);
    try std.testing.expect(l.tables[white_on_dark[0]][128] < 128 * 257);
    // A saturated color over a mid-tone background, blended in linear
    // light with each channel's coverage, lands where blending the encoded
    // values puts it: #3366cc over #a0a0a0 at 25% coverage. The channels
    // need different coverage.
    const fg = scene.Color.srgb8(0x33, 0x66, 0xcc, 0xff);
    const bg = scene.Color.srgb8(0xa0, 0xa0, 0xa0, 0xff);
    const idx = ContrastLuts.indices(fg, bg);
    const fe = [3]f32{ 0x33, 0x66, 0xcc };
    const fl = [3]f32{ fg.r, fg.g, fg.b };
    for (idx, fe, fl) |i, e, f| {
        const c = @as(f32, @floatFromInt(l.tables[i][64])) / 65535;
        const got = scene.linearToSrgb(c * f + (1 - c) * bg.r);
        const want = (64 * e + (255 - 64) * @as(f32, 0xa0)) / 255 / 255;
        // Within the 16-level quantization of the channel values.
        try std.testing.expectApproxEqAbs(want, got, 0.012);
    }
    try std.testing.expect(idx[0] != idx[2]);
}


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
