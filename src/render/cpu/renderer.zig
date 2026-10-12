//! The CPU renderer (D10, D11).
//!
//! A frame runs in three steps:
//!
//! 1. Prepare (calling thread): walk the display list once, resolve device
//!    transforms and clip bounds, flatten paths and strokes into device-
//!    space lines, premultiply paints, place glyphs (rasterizing cache
//!    misses), and cull everything outside the viewport. The result is a
//!    flat list of ops.
//! 2. Damage: mark the 64×64 tiles to redraw, widened by backdrop blurs
//!    whose backdrop changed. Blur backdrops are rendered and blurred first
//!    (see `renderBlurs`).
//! 3. Tiles (worker pool): each damaged tile runs the ops into the
//!    persistent linear 16-bit framebuffer, using per-worker tile buffers
//!    for isolated layers and coverage masks for clips, then encodes the
//!    tile into the output buffer.
//!
//! Each pixel is computed the same way whichever tile or pass computes it,
//! so redrawing only damage is exact. All per-frame storage is retained:
//! steady-state frames allocate nothing.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const color = @import("color.zig");
const blend = @import("blend.zig");
const paint_mod = @import("paint.zig");
const coverage = @import("coverage.zig");
const pool = @import("pool");
const glyph = @import("glyph.zig");

const Point = raster.Point;
const Rect = raster.Rect;
const IRect = raster.IRect;
const Affine = raster.Affine;
const Radii = raster.Radii;
const FillRule = raster.FillRule;
const Pixel = color.Pixel;
const Paint = paint_mod.Paint;
const Executor = pool.Executor;

pub const tile_size = 64;
const T = tile_size;

/// Where encoded output goes, e.g. a mapped wl_shm buffer.
pub const Target = struct {
    pixels: [*]u8,
    /// Bytes per row.
    stride: usize,
    format: color.Format,
};

pub const Options = struct {
    /// Maps the display list's root coordinates to device pixels (e.g. the
    /// buffer scale).
    root: Affine = .identity,
    /// Device rectangles to redraw (see scene.damage.Tracker); null
    /// redraws everything.
    damage: ?[]const IRect = null,
    /// What the frame is drawn over.
    background: scene.Color = .transparent,
    /// Output buffer, or null to only update the working framebuffer.
    target: ?Target = null,
    /// Extra rectangles to encode into the target without redrawing, such
    /// as the age damage of a reused buffer.
    encode: []const IRect = &.{},
};

pub const Error = error{OutOfMemory};

const Line = struct { p0: Point, p1: Point };

const Coverage = union(enum) {
    rect: Rect,
    rounded_rect: struct { rect: Rect, radii: Radii },
    lines: struct { start: u32, end: u32, rule: FillRule },
};

const Draw = struct {
    bbox: IRect,
    coverage: Coverage,
    paint: Paint,
};

const Glyphs = struct {
    bbox: IRect,
    start: u32,
    end: u32,
    paint: Paint,
    /// Text contrast table (see glyph.ContrastLuts).
    contrast: u8,
};

const Clip = struct {
    scissor: IRect,
    /// Null when the clip is a pixel-aligned rectangle.
    coverage: ?Coverage,
};

const PushOp = struct {
    bbox: IRect,
    /// Index of the matching pop op.
    end: u32,
    isolated: bool,
    opacity16: u32,
    blend: scene.BlendMode,
    clip: ?Clip,
};

const BlurOp = struct {
    bbox: IRect,
    coverage: Coverage,
    index: u32,
};

const Op = union(enum) {
    draw: Draw,
    glyphs: Glyphs,
    push: PushOp,
    /// Index of the matching push op.
    pop: u32,
    blur: BlurOp,
};

const Blur = struct {
    op: u32,
    bbox: IRect,
    sigma: f32,
    /// How far the blur reads from an output pixel.
    radius: i32,
    /// Box radii for large sigmas (three box passes approximate the
    /// Gaussian); null for an exact Gaussian kernel of radius ceil(3σ).
    boxes: ?[3]usize,
    /// Output pixels needed this frame, and the backdrop region they read.
    need: IRect = .empty,
    src: IRect = .empty,
    /// Offset of the `need`-sized result in Frame.blur_results.
    result: usize = 0,
};

const Surface = struct {
    px: [*]Pixel,
    stride: usize,
    x0: i32,
    y0: i32,

    inline fn row(s: Surface, x: i32, y: i32) [*]Pixel {
        return s.px + @as(usize, @intCast(y - s.y0)) * s.stride + @as(usize, @intCast(x - s.x0));
    }
};

const Level = struct {
    surf: Surface,
    scissor: IRect,
    /// Tile-local coverage of all clips so far, or null for none.
    mask: ?[*]u8,
    push: u32,
    isolated: bool,
};

const Worker = struct {
    raster: raster.Rasterizer,
    cov: [T * T]u8 = undefined,
    shade: [T]Pixel = undefined,
    base: []Pixel = &.{},
    /// One tile buffer and mask per nesting depth.
    bufs: std.ArrayList([]Pixel) = .empty,
    masks: std.ArrayList([]u8) = .empty,
    levels: std.ArrayList(Level) = .empty,
    /// Scratch line for blurs.
    line: std.ArrayList(@Vector(4, f32)) = .empty,
    line2: std.ArrayList(@Vector(4, f32)) = .empty,

    fn deinit(w: *Worker, gpa: std.mem.Allocator) void {
        w.raster.deinit();
        gpa.free(w.base);
        for (w.bufs.items) |b| gpa.free(b);
        for (w.masks.items) |m| gpa.free(m);
        w.bufs.deinit(gpa);
        w.masks.deinit(gpa);
        w.levels.deinit(gpa);
        w.line.deinit(gpa);
        w.line2.deinit(gpa);
    }

    fn reserve(w: *Worker, gpa: std.mem.Allocator, depth: usize, blur_line: usize) Error!void {
        if (w.base.len == 0) w.base = try gpa.alloc(Pixel, T * T);
        while (w.bufs.items.len < depth) {
            try w.bufs.ensureUnusedCapacity(gpa, 1);
            try w.masks.ensureUnusedCapacity(gpa, 1);
            const b = try gpa.alloc(Pixel, T * T);
            errdefer gpa.free(b);
            const m = try gpa.alloc(u8, T * T);
            w.bufs.appendAssumeCapacity(b);
            w.masks.appendAssumeCapacity(m);
        }
        try w.levels.ensureTotalCapacity(gpa, depth + 1);
        try w.line.ensureTotalCapacity(gpa, blur_line);
        try w.line2.ensureTotalCapacity(gpa, blur_line);
        // Rasterizer windows are at most one tile.
        try w.raster.begin(.xywh(0, 0, T, T));
        w.raster.discard();
    }
};

const tile_render: u8 = 1;
const tile_encode: u8 = 2;

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    executor: Executor,
    luts: color.Luts,
    contrast: glyph.ContrastLuts,
    glyphs: glyph.Cache,
    workers: []Worker,

    width: u32 = 0,
    height: u32 = 0,
    framebuffer: []Pixel = &.{},

    // Per-frame storage, retained across frames.
    ops: std.ArrayList(Op) = .empty,
    lines: std.ArrayList(Line) = .empty,
    stops: std.ArrayList(paint_mod.Stop) = .empty,
    placements: std.ArrayList(glyph.Placement) = .empty,
    blurs: std.ArrayList(Blur) = .empty,
    blur_src: std.ArrayList(Pixel) = .empty,
    blur_tmp: std.ArrayList(@Vector(4, f32)) = .empty,
    blur_results: std.ArrayList(Pixel) = .empty,
    kernel: std.ArrayList(f32) = .empty,
    tiles: std.ArrayList(u8) = .empty,
    tile_list: std.ArrayList(u32) = .empty,
    changed: std.ArrayList(IRect) = .empty,
    stack: std.ArrayList(PrepState) = .empty,
    path: raster.PathBuilder,
    outline: raster.PathBuilder,
    stroker: raster.Stroker,
    max_depth: usize = 0,

    const PrepState = struct { m: Affine, clip: Rect, op: u32 };

    pub fn create(gpa: std.mem.Allocator, executor: Executor) Error!*Renderer {
        const r = try gpa.create(Renderer);
        errdefer gpa.destroy(r);
        const workers = try gpa.alloc(Worker, @max(1, executor.workers));
        errdefer gpa.free(workers);
        for (workers) |*w| w.* = .{ .raster = .init(gpa) };
        r.* = .{
            .gpa = gpa,
            .executor = executor,
            .luts = undefined,
            .contrast = undefined,
            .glyphs = .init(gpa),
            .workers = workers,
            .path = .init(gpa),
            .outline = .init(gpa),
            .stroker = .init(gpa),
        };
        r.luts.init();
        r.contrast.init();
        return r;
    }

    pub fn destroy(r: *Renderer) void {
        const gpa = r.gpa;
        for (r.workers) |*w| w.deinit(gpa);
        gpa.free(r.workers);
        gpa.free(r.framebuffer);
        r.glyphs.deinit();
        r.ops.deinit(gpa);
        r.lines.deinit(gpa);
        r.stops.deinit(gpa);
        r.placements.deinit(gpa);
        r.blurs.deinit(gpa);
        r.blur_src.deinit(gpa);
        r.blur_tmp.deinit(gpa);
        r.blur_results.deinit(gpa);
        r.kernel.deinit(gpa);
        r.tiles.deinit(gpa);
        r.tile_list.deinit(gpa);
        r.changed.deinit(gpa);
        r.stack.deinit(gpa);
        r.path.deinit();
        r.outline.deinit();
        r.stroker.deinit();
        gpa.destroy(r);
    }

    /// Sets the viewport size. The framebuffer contents become undefined;
    /// the next frame must redraw everything.
    pub fn resize(r: *Renderer, width: u32, height: u32) Error!void {
        if (width == r.width and height == r.height) return;
        const fb = try r.gpa.alloc(Pixel, @as(usize, width) * height);
        @memset(fb, .{ 0, 0, 0, 0 });
        r.gpa.free(r.framebuffer);
        r.framebuffer = fb;
        r.width = width;
        r.height = height;
    }

    /// The working framebuffer: linear light, premultiplied, 16 bits per
    /// channel, `width` pixels per row.
    pub fn pixels(r: *const Renderer) []const Pixel {
        return r.framebuffer;
    }

    /// Drops cached glyphs of a font that is going away.
    pub fn evictFont(r: *Renderer, key: u64) void {
        r.glyphs.evictFont(key);
    }

    pub fn viewport(r: *const Renderer) IRect {
        return .xywh(0, 0, @intCast(r.width), @intCast(r.height));
    }

    /// Renders `list` into the framebuffer and the target.
    pub fn render(r: *Renderer, list: scene.DisplayList, opts: Options) Error!void {
        if (r.width == 0 or r.height == 0) return;
        try r.prepare(list, opts.root);
        try r.markTiles(opts);
        for (r.workers) |*w| try w.reserve(r.gpa, r.max_depth, r.blurLineLength());
        try r.renderBlurs(opts.background);
        r.runTiles(opts);
    }

    // Prepare ---------------------------------------------------------------

    fn prepare(r: *Renderer, list: scene.DisplayList, root: Affine) Error!void {
        r.ops.clearRetainingCapacity();
        r.lines.clearRetainingCapacity();
        r.stops.clearRetainingCapacity();
        r.placements.clearRetainingCapacity();
        r.blurs.clearRetainingCapacity();
        r.stack.clearRetainingCapacity();
        r.max_depth = 0;
        r.glyphs.beginFrame();

        // Stops are referenced by slice, so reserve them all up front.
        var nstops: usize = 0;
        for (list.commands) |cmd| switch (cmd) {
            inline .fill, .stroke, .glyphs => |d| if (d.paint == .gradient) {
                nstops += d.paint.gradient.stops.len;
            },
            else => {},
        };
        try r.stops.ensureTotalCapacity(r.gpa, nstops);

        const vp = r.viewport();
        const vpf = vp.toRect();
        try r.stack.append(r.gpa, .{ .m = root, .clip = vpf, .op = 0 });

        var i: usize = 0;
        const cmds = list.commands;
        while (i < cmds.len) : (i += 1) {
            const top = r.stack.items[r.stack.items.len - 1];
            const m = top.m;
            switch (cmds[i]) {
                .push => |p| {
                    const l = p.layer;
                    const lm = l.transform.then(m);
                    const invisible = l.opacity <= 0 and !l.blend.isUnbounded();
                    const unbounded = std.math.isInf(p.bounds.x0) or std.math.isInf(p.bounds.x1);
                    const bf = if (unbounded) top.clip else lm.applyRect(p.bounds).intersect(top.clip);
                    const bbox = bf.roundOut().intersect(vp);
                    if (invisible or bbox.isEmpty() or lm.invert() == null) {
                        i = p.end;
                        continue;
                    }
                    var clip_bounds = top.clip;
                    var clip: ?Clip = null;
                    if (l.clip) |c| {
                        const cb = lm.applyRect(c.shape.bounds());
                        clip_bounds = clip_bounds.intersect(cb);
                        const cov = try r.coverageFor(c.shape, c.rule, lm);
                        clip = .{ .scissor = cb.roundOut().intersect(vp), .coverage = cov };
                        if (cov == .rect and isPixelAligned(cov.rect)) clip.?.coverage = null;
                    }
                    try r.ops.append(r.gpa, .{ .push = .{
                        .bbox = bbox,
                        .end = 0,
                        .isolated = l.isIsolated(),
                        .opacity16 = color.toU16(l.opacity),
                        .blend = l.blend,
                        .clip = clip,
                    } });
                    try r.stack.append(r.gpa, .{ .m = lm, .clip = clip_bounds, .op = @intCast(r.ops.items.len - 1) });
                    r.max_depth = @max(r.max_depth, r.stack.items.len);
                },
                .pop => {
                    const st = r.stack.pop().?;
                    try r.ops.append(r.gpa, .{ .pop = st.op });
                    r.ops.items[st.op].push.end = @intCast(r.ops.items.len - 1);
                },
                .fill => |f| {
                    if (f.paint.isInvisible()) continue;
                    const bbox = m.applyRect(f.shape.bounds()).intersect(top.clip).roundOut().intersect(vp);
                    if (bbox.isEmpty()) continue;
                    const cov = try r.coverageFor(f.shape, f.rule, m);
                    try r.ops.append(r.gpa, .{ .draw = .{ .bbox = bbox, .coverage = cov, .paint = r.preparePaint(f.paint, m) } });
                },
                .stroke => |s| {
                    if (s.paint.isInvisible()) continue;
                    const bbox = m.applyRect(s.shape.bounds().outset(s.style.outset())).intersect(top.clip).roundOut().intersect(vp);
                    if (bbox.isEmpty()) continue;
                    r.path.reset();
                    try s.shape.toPath(&r.path);
                    r.outline.reset();
                    const scale = @max(m.maxScale(), 1e-6);
                    try r.stroker.stroke(r.path.path(), s.style, raster.default_tolerance / scale, &r.outline);
                    const start: u32 = @intCast(r.lines.items.len);
                    try r.flattenInto(r.outline.path(), m);
                    try r.ops.append(r.gpa, .{ .draw = .{
                        .bbox = bbox,
                        .coverage = .{ .lines = .{ .start = start, .end = @intCast(r.lines.items.len), .rule = .nonzero } },
                        .paint = r.preparePaint(s.paint, m),
                    } });
                },
                .glyphs => |g| try r.prepareGlyphs(g, m, top.clip, vp),
                .image => |img| {
                    if (img.opacity <= 0) continue;
                    const bbox = m.applyRect(img.dst).intersect(top.clip).roundOut().intersect(vp);
                    if (bbox.isEmpty() or img.src.isEmpty() or img.dst.isEmpty()) continue;
                    const inv = m.invert() orelse continue;
                    // Local (dst) to image pixels.
                    const sx = img.src.width() / img.dst.width();
                    const sy = img.src.height() / img.dst.height();
                    const to_img: Affine = .{ .a = sx, .d = sy, .e = img.src.x0 - img.dst.x0 * sx, .f = img.src.y0 - img.dst.y0 * sy };
                    const ref = img.image;
                    const sr = img.src.roundOut().intersect(.xywh(0, 0, @intCast(ref.width), @intCast(ref.height)));
                    if (sr.isEmpty()) continue;
                    const cov = try r.coverageFor(.{ .rect = img.dst }, .nonzero, m);
                    try r.ops.append(r.gpa, .{ .draw = .{ .bbox = bbox, .coverage = cov, .paint = .{ .image = .{
                        .inv = inv.then(to_img),
                        .ref = ref,
                        .x0 = sr.x0,
                        .y0 = sr.y0,
                        .x1 = sr.x1,
                        .y1 = sr.y1,
                        .filter = img.filter,
                        .opacity16 = color.toU16(img.opacity),
                    } } } });
                },
                .backdrop_blur => |b| {
                    const bbox = m.applyRect(b.shape.bounds()).intersect(top.clip).roundOut().intersect(vp);
                    if (bbox.isEmpty()) continue;
                    const sigma = @min(b.sigma * @sqrt(@abs(m.determinant())), scene.max_blur_sigma);
                    if (!(sigma > 0)) continue;
                    const cov = try r.coverageFor(b.shape, .nonzero, m);
                    const boxes = boxRadii(sigma);
                    try r.blurs.append(r.gpa, .{
                        .op = @intCast(r.ops.items.len),
                        .bbox = bbox,
                        .sigma = sigma,
                        .radius = if (boxes) |bx| @intCast(bx[0] + bx[1] + bx[2]) else @intFromFloat(@ceil(3 * sigma)),
                        .boxes = boxes,
                    });
                    try r.ops.append(r.gpa, .{ .blur = .{ .bbox = bbox, .coverage = cov, .index = @intCast(r.blurs.items.len - 1) } });
                },
            }
        }
    }

    fn isPixelAligned(rc: Rect) bool {
        return rc.x0 == @floor(rc.x0) and rc.y0 == @floor(rc.y0) and rc.x1 == @floor(rc.x1) and rc.y1 == @floor(rc.y1);
    }

    /// Device-space coverage for a shape drawn through `m`.
    fn coverageFor(r: *Renderer, shape: scene.Shape, rule: FillRule, m: Affine) Error!Coverage {
        if (m.isAxisAligned()) switch (shape) {
            .rect => |rc| return .{ .rect = m.applyRect(rc) },
            .rounded_rect => |rr| {
                const ax = @abs(m.a);
                const ay = @abs(m.d);
                var radii: Radii = .{
                    .tl = .{ .x = rr.radii.tl.x * ax, .y = rr.radii.tl.y * ay },
                    .tr = .{ .x = rr.radii.tr.x * ax, .y = rr.radii.tr.y * ay },
                    .br = .{ .x = rr.radii.br.x * ax, .y = rr.radii.br.y * ay },
                    .bl = .{ .x = rr.radii.bl.x * ax, .y = rr.radii.bl.y * ay },
                };
                if (m.a < 0) radii = .{ .tl = radii.tr, .tr = radii.tl, .br = radii.bl, .bl = radii.br };
                if (m.d < 0) radii = .{ .tl = radii.bl, .tr = radii.br, .br = radii.tr, .bl = radii.tl };
                const dr = m.applyRect(rr.rect);
                return .{ .rounded_rect = .{ .rect = dr, .radii = radii.fit(dr) } };
            },
            .path => {},
        };
        const start: u32 = @intCast(r.lines.items.len);
        switch (shape) {
            .path => |p| try r.flattenInto(p, m),
            else => {
                r.path.reset();
                try shape.toPath(&r.path);
                try r.flattenInto(r.path.path(), m);
            },
        }
        return .{ .lines = .{ .start = start, .end = @intCast(r.lines.items.len), .rule = rule } };
    }

    fn flattenInto(r: *Renderer, p: raster.Path, m: Affine) Error!void {
        var sink: LineSink = .{ .r = r };
        try raster.flatten(p, m, raster.default_tolerance, &sink);
    }

    const LineSink = struct {
        r: *Renderer,
        start: Point = .zero,
        last: Point = .zero,

        pub fn begin(s: *LineSink, p: Point) Error!void {
            s.start = p;
            s.last = p;
        }
        pub fn lineTo(s: *LineSink, p: Point) Error!void {
            if (s.last.y != p.y) try s.r.lines.append(s.r.gpa, .{ .p0 = s.last, .p1 = p });
            s.last = p;
        }
        pub fn end(s: *LineSink, _: bool) Error!void {
            try s.lineTo(s.start);
        }
    };

    fn preparePaint(r: *Renderer, p: scene.Paint, m: Affine) Paint {
        switch (p) {
            .solid => |c| return .{ .solid = paint_mod.solid(c, 1) },
            .gradient => |g| {
                const to_device = g.transform.then(m);
                const inv = to_device.invert() orelse return .{ .solid = .{ 0, 0, 0, 0 } };
                const start = r.stops.items.len;
                r.stops.items.len += g.stops.len; // capacity reserved in prepare
                const out = r.stops.items[start..];
                paint_mod.prepareStops(g.stops, 1, out);
                return .{ .gradient = .{ .inv = inv, .geometry = g.geometry, .stops = out, .extend = g.extend } };
            },
        }
    }

    fn prepareGlyphs(r: *Renderer, g: scene.GlyphRun, m: Affine, clip: Rect, vp: IRect) Error!void {
        if (g.paint.isInvisible() or g.glyphs.len == 0) return;
        const bbox = m.applyRect(g.bounds).intersect(clip).roundOut().intersect(vp);
        if (bbox.isEmpty()) return;
        const start: u32 = @intCast(r.placements.items.len);
        const fg = switch (g.paint) {
            .solid => |c| c,
            .gradient => |gr| gr.stops[gr.stops.len / 2].color,
        };
        if (try r.glyphs.place(g, m, fg, &r.placements)) {
            try r.ops.append(r.gpa, .{ .glyphs = .{
                .bbox = bbox,
                .start = start,
                .end = @intCast(r.placements.items.len),
                .paint = r.preparePaint(g.paint, m),
                .contrast = glyph.ContrastLuts.index(fg),
            } });
        } else {
            // Transformed or very large text: draw outlines as paths.
            const line_start: u32 = @intCast(r.lines.items.len);
            r.path.reset();
            try r.glyphs.outlines(g, &r.path);
            try r.flattenInto(r.path.path(), m);
            try r.ops.append(r.gpa, .{ .draw = .{
                .bbox = bbox,
                .coverage = .{ .lines = .{ .start = line_start, .end = @intCast(r.lines.items.len), .rule = .nonzero } },
                .paint = r.preparePaint(g.paint, m),
            } });
        }
    }

    // Damage ----------------------------------------------------------------

    fn tilesX(r: *const Renderer) u32 {
        return (r.width + T - 1) / T;
    }

    fn tilesY(r: *const Renderer) u32 {
        return (r.height + T - 1) / T;
    }

    fn tileRect(r: *const Renderer, index: u32) IRect {
        const tx: i32 = @intCast(index % r.tilesX());
        const ty: i32 = @intCast(index / r.tilesX());
        return IRect.xywh(tx * T, ty * T, T, T).intersect(r.viewport());
    }

    fn markRect(r: *Renderer, rect: IRect, flag: u8) void {
        const c = rect.intersect(r.viewport());
        if (c.isEmpty()) return;
        const tx0: u32 = @intCast(@divFloor(c.x0, T));
        const ty0: u32 = @intCast(@divFloor(c.y0, T));
        const tx1: u32 = @intCast(@divFloor(c.x1 - 1, T));
        const ty1: u32 = @intCast(@divFloor(c.y1 - 1, T));
        var ty = ty0;
        while (ty <= ty1) : (ty += 1) {
            var tx = tx0;
            while (tx <= tx1) : (tx += 1) r.tiles.items[ty * r.tilesX() + tx] |= flag;
        }
    }

    /// Bounding box of the render-marked tiles inside `rect`.
    fn markedBounds(r: *const Renderer, rect: IRect) IRect {
        const c = rect.intersect(r.viewport());
        var out = IRect.empty;
        if (c.isEmpty()) return out;
        var ty: i32 = @divFloor(c.y0, T);
        while (ty <= @divFloor(c.y1 - 1, T)) : (ty += 1) {
            var tx: i32 = @divFloor(c.x0, T);
            while (tx <= @divFloor(c.x1 - 1, T)) : (tx += 1) {
                const idx = @as(u32, @intCast(ty)) * r.tilesX() + @as(u32, @intCast(tx));
                if (r.tiles.items[idx] & tile_render != 0) out = out.unite(r.tileRect(idx).intersect(c));
            }
        }
        return out;
    }

    fn markTiles(r: *Renderer, opts: Options) Error!void {
        const n = r.tilesX() * r.tilesY();
        try r.tiles.resize(r.gpa, n);
        @memset(r.tiles.items, 0);
        if (opts.damage) |rects| {
            for (rects) |d| r.markRect(d, tile_render);
        } else {
            @memset(r.tiles.items, tile_render);
        }
        // A blur whose backdrop changed changes everywhere it is drawn.
        // Blurs are in paint order, so one forward pass catches chains.
        // Test against the changed pixels, not whole tiles: redrawn tiles
        // reproduce unchanged pixels exactly.
        if (r.blurs.items.len > 0) {
            r.changed.clearRetainingCapacity();
            if (opts.damage) |rects| try r.changed.appendSlice(r.gpa, rects) else try r.changed.append(r.gpa, r.viewport());
            for (r.blurs.items) |b| {
                const reach = b.bbox.outset(b.radius);
                for (r.changed.items) |d| if (d.intersects(reach)) {
                    r.markRect(b.bbox, tile_render);
                    try r.changed.append(r.gpa, b.bbox);
                    break;
                };
            }
        }
        for (opts.encode) |e| r.markRect(e, tile_encode);
        // Each blur must produce what damaged tiles and later blurs' backdrops
        // read from it.
        var k = r.blurs.items.len;
        while (k > 0) {
            k -= 1;
            const b = &r.blurs.items[k];
            var need = r.markedBounds(b.bbox);
            for (r.blurs.items[k + 1 ..]) |later| {
                if (!later.need.isEmpty()) need = need.unite(later.src.intersect(b.bbox));
            }
            b.need = need;
            b.src = if (need.isEmpty()) IRect.empty else need.outset(b.radius).intersect(r.viewport());
        }
        r.tile_list.clearRetainingCapacity();
        for (r.tiles.items, 0..) |f, i| if (f != 0) try r.tile_list.append(r.gpa, @intCast(i));

        // Reserve blur storage now, outside the parallel passes.
        var src_max: usize = 0;
        var tmp_max: usize = 0;
        var results: usize = 0;
        var kernel: usize = 0;
        for (r.blurs.items) |*b| {
            if (b.need.isEmpty()) continue;
            src_max = @max(src_max, area(b.src));
            tmp_max = @max(tmp_max, @as(usize, @intCast(b.src.height())) * @as(usize, @intCast(b.need.width())));
            b.result = results;
            results += area(b.need);
            if (b.boxes == null) kernel = @max(kernel, @as(usize, @intCast(2 * b.radius + 1)));
        }
        try r.blur_src.resize(r.gpa, src_max);
        try r.blur_tmp.resize(r.gpa, tmp_max);
        try r.blur_results.resize(r.gpa, results);
        try r.kernel.resize(r.gpa, @max(kernel, 1));
    }

    fn area(rc: IRect) usize {
        if (rc.isEmpty()) return 0;
        return @as(usize, @intCast(rc.width())) * @as(usize, @intCast(rc.height()));
    }

    fn blurLineLength(r: *const Renderer) usize {
        var n: usize = 0;
        for (r.blurs.items) |b| n = @max(n, @as(usize, @intCast(@max(b.src.width(), b.src.height()))));
        return n;
    }

    // Blur ------------------------------------------------------------------

    /// For each needed blur, in paint order: render its backdrop region
    /// with the ops before it (tile by tile, on the same grid, so pixels
    /// match the main pass), then blur it separably into its result.
    fn renderBlurs(r: *Renderer, background: scene.Color) Error!void {
        const bg = paint_mod.solid(background, 1);
        for (r.blurs.items) |*b| {
            if (b.need.isEmpty()) continue;
            var region: RegionJob = .{ .r = r, .blur = b, .bg = bg, .counter = .{ .count = 0 } };
            r.tile_list.clearRetainingCapacity();
            const tx0: u32 = @intCast(@divFloor(b.src.x0, T));
            const ty0: u32 = @intCast(@divFloor(b.src.y0, T));
            const tx1: u32 = @intCast(@divFloor(b.src.x1 - 1, T));
            const ty1: u32 = @intCast(@divFloor(b.src.y1 - 1, T));
            var ty = ty0;
            while (ty <= ty1) : (ty += 1) {
                var tx = tx0;
                while (tx <= tx1) : (tx += 1) try r.tile_list.append(r.gpa, ty * r.tilesX() + tx);
            }
            region.counter.count = @intCast(r.tile_list.items.len);
            r.executor.run(r.executor.ctx, .{ .ctx = &region, .func = RegionJob.run });

            // Gaussian kernel (unused for box blurs).
            const kr: usize = if (b.boxes == null) @intCast(b.radius) else 0;
            const kernel = r.kernel.items[0 .. 2 * kr + 1];
            var sum: f32 = 0;
            for (kernel, 0..) |*w, i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(kr));
                w.* = @exp(-x * x / (2 * b.sigma * b.sigma));
                sum += w.*;
            }
            for (kernel) |*w| w.* /= sum;

            var h: BlurJob = .{ .r = r, .blur = b, .kernel = kernel, .vertical = false, .counter = .{ .count = @intCast(b.src.height()) } };
            r.executor.run(r.executor.ctx, .{ .ctx = &h, .func = BlurJob.run });
            var v: BlurJob = .{ .r = r, .blur = b, .kernel = kernel, .vertical = true, .counter = .{ .count = @intCast(b.need.width()) } };
            r.executor.run(r.executor.ctx, .{ .ctx = &v, .func = BlurJob.run });
        }
        // Restore the damaged tile list for the main pass.
        r.tile_list.clearRetainingCapacity();
        for (r.tiles.items, 0..) |f, i| if (f != 0) try r.tile_list.append(r.gpa, @intCast(i));
    }

    const RegionJob = struct {
        r: *Renderer,
        blur: *Blur,
        bg: Pixel,
        counter: pool.Counter,

        fn run(ctx: *anyopaque, worker: u32) void {
            const job: *RegionJob = @ptrCast(@alignCast(ctx));
            const r = job.r;
            const w = &r.workers[worker];
            while (job.counter.take()) |i| {
                const tile = r.tileRect(r.tile_list.items[i]);
                const base: Surface = .{ .px = w.base.ptr, .stride = T, .x0 = tile.x0, .y0 = tile.y0 };
                fillRect(base, tile, job.bg);
                const top = r.runOps(w, tile, base, job.blur.op, true);
                // Copy the backdrop (the innermost isolated layer's buffer).
                const src = job.blur.src;
                const c = tile.intersect(src);
                var y = c.y0;
                while (y < c.y1) : (y += 1) {
                    const from = top.row(c.x0, y)[0..@intCast(c.width())];
                    const to = r.blur_src.items[@as(usize, @intCast(y - src.y0)) * @as(usize, @intCast(src.width())) + @as(usize, @intCast(c.x0 - src.x0)) ..];
                    @memcpy(to[0..from.len], from);
                }
            }
        }
    };

    const BlurJob = struct {
        r: *Renderer,
        blur: *Blur,
        kernel: []const f32,
        vertical: bool,
        counter: pool.Counter,

        fn run(ctx: *anyopaque, worker: u32) void {
            const job: *BlurJob = @ptrCast(@alignCast(ctx));
            const r = job.r;
            const w = &r.workers[worker];
            const b = job.blur;
            const sw: usize = @intCast(b.src.width());
            const sh: usize = @intCast(b.src.height());
            const nw: usize = @intCast(b.need.width());
            const nx0: usize = @intCast(b.need.x0 - b.src.x0);
            const ny0: usize = @intCast(b.need.y0 - b.src.y0);
            while (job.counter.take()) |i| {
                if (!job.vertical) {
                    // Row i of src → tmp row i, columns of `need`.
                    const line = w.line.items.ptr[0..sw];
                    const row = r.blur_src.items[i * sw ..][0..sw];
                    for (line, row) |*l, p| l.* = toF(p);
                    const out = w.line2.items.ptr[0..sw];
                    blurLine(b, line, job.kernel, out, nx0, nw);
                    @memcpy(r.blur_tmp.items[i * nw ..][0..nw], out[nx0..][0..nw]);
                } else {
                    // Column i of tmp → result column i, rows of `need`.
                    const line = w.line.items.ptr[0..sh];
                    for (line, 0..) |*l, y| l.* = r.blur_tmp.items[y * nw + i];
                    const out = w.line2.items.ptr[0..sh];
                    const nh: usize = @intCast(b.need.height());
                    blurLine(b, line, job.kernel, out, ny0, nh);
                    for (0..nh) |y| r.blur_results.items[b.result + y * nw + i] = fromF(out[ny0 + y]);
                }
            }
        }
    };

    // Tiles -----------------------------------------------------------------

    const TileJob = struct {
        r: *Renderer,
        opts: *const Options,
        bg: Pixel,
        counter: pool.Counter,

        fn run(ctx: *anyopaque, worker: u32) void {
            const job: *TileJob = @ptrCast(@alignCast(ctx));
            const r = job.r;
            const w = &r.workers[worker];
            const fb: Surface = .{ .px = r.framebuffer.ptr, .stride = r.width, .x0 = 0, .y0 = 0 };
            while (job.counter.take()) |i| {
                const index = r.tile_list.items[i];
                const tile = r.tileRect(index);
                if (r.tiles.items[index] & tile_render != 0) {
                    fillRect(fb, tile, job.bg);
                    _ = r.runOps(w, tile, fb, @intCast(r.ops.items.len), false);
                }
                if (job.opts.target) |t| r.encodeTile(t, tile);
            }
        }
    };

    fn runTiles(r: *Renderer, opts: Options) void {
        var job: TileJob = .{ .r = r, .opts = &opts, .bg = paint_mod.solid(opts.background, 1), .counter = .{ .count = @intCast(r.tile_list.items.len) } };
        r.executor.run(r.executor.ctx, .{ .ctx = &job, .func = TileJob.run });
    }

    fn encodeTile(r: *Renderer, t: Target, tile: IRect) void {
        const bpp = t.format.bytesPerPixel();
        var y = tile.y0;
        while (y < tile.y1) : (y += 1) {
            const src = r.framebuffer[@as(usize, @intCast(y)) * r.width + @as(usize, @intCast(tile.x0)) ..][0..@intCast(tile.width())];
            const out = t.pixels[@as(usize, @intCast(y)) * t.stride + @as(usize, @intCast(tile.x0)) * bpp ..][0 .. src.len * bpp];
            color.encodeRow(&r.luts, t.format, src, tile.x0, y, out);
        }
    }

    /// Runs ops [0, stop) for one tile into `base`. Returns the surface
    /// that is current at `stop` (the innermost isolated layer). In a
    /// backdrop pass (`backdrop`), layers that contain `stop` are never
    /// culled and isolated layers clear the whole tile.
    fn runOps(r: *Renderer, w: *Worker, tile: IRect, base: Surface, stop: u32, backdrop: bool) Surface {
        w.levels.clearRetainingCapacity();
        w.levels.appendAssumeCapacity(.{ .surf = base, .scissor = tile, .mask = null, .push = 0, .isolated = false });
        const ops = r.ops.items;
        var i: u32 = 0;
        while (i < stop) : (i += 1) {
            const lv = &w.levels.items[w.levels.items.len - 1];
            switch (ops[i]) {
                .push => |*p| {
                    const contains_stop = backdrop and p.end >= stop;
                    var scissor = lv.scissor.intersect(p.bbox);
                    if (p.clip) |c| scissor = scissor.intersect(c.scissor);
                    if (scissor.isEmpty() and !contains_stop) {
                        i = p.end;
                        continue;
                    }
                    const depth = w.levels.items.len - 1;
                    var nl: Level = .{ .surf = lv.surf, .scissor = scissor, .mask = lv.mask, .push = i, .isolated = p.isolated };
                    if (p.clip) |c| if (c.coverage) |cov| {
                        const m = w.masks.items[depth].ptr;
                        r.computeCoverage(w, cov, tile, scissor, m);
                        if (lv.mask) |pm| multiplyMask(m, pm, tile, scissor);
                        nl.mask = m;
                    };
                    if (p.isolated) {
                        nl.surf = .{ .px = w.bufs.items[depth].ptr, .stride = T, .x0 = tile.x0, .y0 = tile.y0 };
                        fillRect(nl.surf, if (contains_stop) tile else scissor, .{ 0, 0, 0, 0 });
                    }
                    w.levels.appendAssumeCapacity(nl);
                },
                .pop => |pi| {
                    const p = &ops[pi].push;
                    const done = w.levels.pop().?;
                    if (done.isolated) {
                        const parent = w.levels.items[w.levels.items.len - 1];
                        compositeLayer(parent.surf, done.surf, done.scissor, done.mask, tile, p.blend, p.opacity16);
                    }
                },
                .draw => |*d| r.runDraw(w, lv, tile, d),
                .glyphs => |*g| r.runGlyphs(w, lv, tile, g),
                .blur => |*b| r.runBlur(w, lv, tile, b),
            }
        }
        return w.levels.items[w.levels.items.len - 1].surf;
    }

    fn computeCoverage(r: *Renderer, w: *Worker, cov: Coverage, tile: IRect, region: IRect, out: [*]u8) void {
        const off = @as(usize, @intCast(region.y0 - tile.y0)) * T + @as(usize, @intCast(region.x0 - tile.x0));
        const dst = out[off .. T * T];
        switch (cov) {
            .rect => |rc| coverage.rect(rc, region, dst, T),
            .rounded_rect => |rr| coverage.roundedRect(rr.rect, rr.radii, region, dst, T),
            .lines => |l| {
                w.raster.begin(region) catch unreachable; // capacity reserved
                for (r.lines.items[l.start..l.end]) |ln| w.raster.addLine(ln.p0, ln.p1);
                w.raster.finish(l.rule, dst, T);
            },
        }
    }

    fn runDraw(r: *Renderer, w: *Worker, lv: *const Level, tile: IRect, d: *const Draw) void {
        const region = lv.scissor.intersect(d.bbox);
        if (region.isEmpty()) return;
        if (d.coverage == .rect and lv.mask == null) {
            // Fully covered interior: no coverage pass.
            const rc = d.coverage.rect;
            const inner = (IRect{
                .x0 = @intFromFloat(@max(@ceil(rc.x0), -1e9)),
                .y0 = @intFromFloat(@max(@ceil(rc.y0), -1e9)),
                .x1 = @intFromFloat(@min(@floor(rc.x1), 1e9)),
                .y1 = @intFromFloat(@min(@floor(rc.y1), 1e9)),
            }).intersect(region);
            if (inner.eql(region)) return r.fillFull(w, lv, region, &d.paint);
        }
        r.computeCoverage(w, d.coverage, tile, region, &w.cov);
        if (lv.mask) |m| multiplyMask(&w.cov, m, tile, region);
        const width: usize = @intCast(region.width());
        var y = region.y0;
        while (y < region.y1) : (y += 1) {
            const cov = w.cov[@as(usize, @intCast(y - tile.y0)) * T + @as(usize, @intCast(region.x0 - tile.x0)) ..][0..width];
            const dst = lv.surf.row(region.x0, y)[0..width];
            switch (d.paint) {
                .solid => |s| {
                    for (dst, cov) |*px, c| {
                        if (c == 0) continue;
                        if (c == 255 and s[3] == 65535) {
                            px.* = s;
                        } else blend.srcOver(px, s, @as(u32, c) * 257);
                    }
                },
                else => {
                    const shade = w.shade[0..width];
                    paint_mod.shadeRow(&d.paint, &r.luts, region.x0, y, shade);
                    for (dst, cov, shade) |*px, c, s| {
                        if (c == 255 and s[3] == 65535) {
                            px.* = s;
                        } else if (c != 0) blend.srcOver(px, s, @as(u32, c) * 257);
                    }
                },
            }
        }
    }

    fn fillFull(r: *Renderer, w: *Worker, lv: *const Level, region: IRect, paint: *const Paint) void {
        const width: usize = @intCast(region.width());
        var y = region.y0;
        while (y < region.y1) : (y += 1) {
            const dst = lv.surf.row(region.x0, y)[0..width];
            switch (paint.*) {
                .solid => |s| {
                    if (s[3] == 65535) {
                        @memset(dst, s);
                    } else for (dst) |*px| blend.srcOver(px, s, 65535);
                },
                else => {
                    const shade = w.shade[0..width];
                    paint_mod.shadeRow(paint, &r.luts, region.x0, y, shade);
                    for (dst, shade) |*px, s| {
                        if (s[3] == 65535) px.* = s else blend.srcOver(px, s, 65535);
                    }
                },
            }
        }
    }

    fn runGlyphs(r: *Renderer, w: *Worker, lv: *const Level, tile: IRect, g: *const Glyphs) void {
        const region = lv.scissor.intersect(g.bbox);
        if (region.isEmpty()) return;
        const lut = &r.contrast.tables[g.contrast];
        for (r.placements.items[g.start..g.end]) |pl| {
            const e = r.glyphs.entry(pl.entry);
            const gr = IRect.xywh(pl.x + e.left, pl.y + e.top, @intCast(e.width), @intCast(e.height));
            const c = gr.intersect(region);
            if (c.isEmpty()) continue;
            const width: usize = @intCast(c.width());
            var y = c.y0;
            while (y < c.y1) : (y += 1) {
                const dst = lv.surf.row(c.x0, y)[0..width];
                const gy: usize = @intCast(y - gr.y0);
                const gx: usize = @intCast(c.x0 - gr.x0);
                const clip_row: ?[]const u8 = if (lv.mask) |m| m[@as(usize, @intCast(y - tile.y0)) * T + @as(usize, @intCast(c.x0 - tile.x0)) ..][0..width] else null;
                switch (e.kind) {
                    .mask => {
                        const src = r.glyphs.maskRow(e, gy)[gx..][0..width];
                        if (g.paint != .solid) paint_mod.shadeRow(&g.paint, &r.luts, c.x0, y, w.shade[0..width]);
                        for (dst, src, 0..) |*px, a, xi| {
                            if (a == 0) continue;
                            var cov16: u32 = lut[a];
                            if (clip_row) |cr| cov16 = color.div65535(cov16 * (@as(u32, cr[xi]) * 257));
                            const s = if (g.paint == .solid) g.paint.solid else w.shade[xi];
                            blend.srcOver(px, s, cov16);
                        }
                    },
                    .color => {
                        const src = r.glyphs.colorRow(e, gy)[gx..][0..width];
                        for (dst, src, 0..) |*px, s, xi| {
                            if (s[3] == 0) continue;
                            const cov16: u32 = if (clip_row) |cr| @as(u32, cr[xi]) * 257 else 65535;
                            blend.srcOver(px, s, cov16);
                        }
                    },
                    .redirect => unreachable,
                }
            }
        }
    }

    fn runBlur(r: *Renderer, w: *Worker, lv: *const Level, tile: IRect, b: *const BlurOp) void {
        const blur = r.blurs.items[b.index];
        const region = lv.scissor.intersect(b.bbox).intersect(blur.need);
        if (region.isEmpty()) return;
        r.computeCoverage(w, b.coverage, tile, region, &w.cov);
        if (lv.mask) |m| multiplyMask(&w.cov, m, tile, region);
        const width: usize = @intCast(region.width());
        const nw: usize = @intCast(blur.need.width());
        var y = region.y0;
        while (y < region.y1) : (y += 1) {
            const cov = w.cov[@as(usize, @intCast(y - tile.y0)) * T + @as(usize, @intCast(region.x0 - tile.x0)) ..][0..width];
            const dst = lv.surf.row(region.x0, y)[0..width];
            const src = r.blur_results.items[blur.result + @as(usize, @intCast(y - blur.need.y0)) * nw + @as(usize, @intCast(region.x0 - blur.need.x0)) ..][0..width];
            for (dst, cov, src) |*px, c, s| {
                if (c != 0) blend.lerp(px, s, @as(u32, c) * 257);
            }
        }
    }
};

fn fillRect(s: Surface, rc: IRect, p: Pixel) void {
    var y = rc.y0;
    while (y < rc.y1) : (y += 1) @memset(s.row(rc.x0, y)[0..@intCast(rc.width())], p);
}

/// m[region] *= other[region] (both tile-local masks).
fn multiplyMask(m: [*]u8, other: [*]const u8, tile: IRect, region: IRect) void {
    var y = region.y0;
    while (y < region.y1) : (y += 1) {
        const off = @as(usize, @intCast(y - tile.y0)) * T + @as(usize, @intCast(region.x0 - tile.x0));
        for (m[off..][0..@intCast(region.width())], other[off..][0..@intCast(region.width())]) |*a, b| {
            a.* = @intCast((@as(u32, a.*) * b + 127) / 255);
        }
    }
}

fn compositeLayer(dst: Surface, src: Surface, region: IRect, mask: ?[*]const u8, tile: IRect, mode: scene.BlendMode, opacity16: u32) void {
    if (region.isEmpty()) return;
    const width: usize = @intCast(region.width());
    var y = region.y0;
    while (y < region.y1) : (y += 1) {
        const d = dst.row(region.x0, y)[0..width];
        const s = src.row(region.x0, y)[0..width];
        const mrow: ?[]const u8 = if (mask) |m| m[@as(usize, @intCast(y - tile.y0)) * T + @as(usize, @intCast(region.x0 - tile.x0)) ..][0..width] else null;
        if (mode == .src_over) {
            for (d, s) |*dp, sp| if (sp[3] != 0) blend.srcOver(dp, sp, opacity16);
        } else {
            for (d, s, 0..) |*dp, sp, xi| {
                const clip16: u32 = if (mrow) |mr| @as(u32, mr[xi]) * 257 else 65535;
                blend.composite(mode, dp, sp, opacity16, clip16);
            }
        }
    }
}

inline fn toF(p: Pixel) @Vector(4, f32) {
    const v: @Vector(4, u32) = p;
    return @floatFromInt(v);
}

inline fn fromF(v: @Vector(4, f32)) Pixel {
    const c = @min(@max(v + @as(@Vector(4, f32), @splat(0.5)), @as(@Vector(4, f32), @splat(0))), @as(@Vector(4, f32), @splat(65535)));
    const n: @Vector(4, u16) = @intFromFloat(c);
    var out: Pixel = n;
    // Premultiplied validity.
    inline for (0..3) |i| out[i] = @min(out[i], out[3]);
    return out;
}

/// Box radii for three box passes approximating a Gaussian of `sigma`
/// (Kovesi), or null below sigma 2 where an exact kernel is cheap. This is
/// part of the rendering contract the Vulkan blur must match.
pub fn boxRadii(sigma: f32) ?[3]usize {
    if (sigma <= 2) return null;
    const n = 3.0;
    const ideal = @sqrt(12 * sigma * sigma / n + 1);
    var wl: i32 = @intFromFloat(@floor(ideal));
    if (@mod(wl, 2) == 0) wl -= 1;
    const wu = wl + 2;
    const wlf: f32 = @floatFromInt(wl);
    const m: i32 = @intFromFloat(@round((12 * sigma * sigma - n * wlf * wlf - 4 * n * wlf - 3 * n) / (-4 * wlf - 4)));
    var out: [3]usize = undefined;
    for (&out, 0..) |*r, i| r.* = @intCast(@divFloor((if (@as(i32, @intCast(i)) < m) wl else wu) - 1, 2));
    return out;
}

/// Blurs `line` (clamped at its ends) and leaves output pixels [from,
/// from + n) in `out`. Box blurs use `line` as scratch.
fn blurLine(b: *const Blur, line: []@Vector(4, f32), kernel: []const f32, out: []@Vector(4, f32), from: usize, n: usize) void {
    const boxes = b.boxes orelse return convolve(line, kernel, out, from, n);
    boxPass(line, out, boxes[0]);
    boxPass(out, line, boxes[1]);
    boxPass(line, out, boxes[2]);
}

/// Running-sum box filter of radius r with clamp-to-edge.
fn boxPass(in: []const @Vector(4, f32), out: []@Vector(4, f32), r: usize) void {
    const len = in.len;
    const last: isize = @intCast(len - 1);
    const scale: @Vector(4, f32) = @splat(1 / @as(f32, @floatFromInt(2 * r + 1)));
    var acc: @Vector(4, f32) = @splat(0);
    const ri: isize = @intCast(r);
    var k: isize = -ri;
    while (k <= ri) : (k += 1) acc += in[@intCast(std.math.clamp(k, 0, last))];
    for (0..len) |i| {
        out[i] = acc * scale;
        const ii: isize = @intCast(i);
        acc += in[@intCast(std.math.clamp(ii + ri + 1, 0, last))];
        acc -= in[@intCast(std.math.clamp(ii - ri, 0, last))];
    }
}

/// out[i] for i in [from, from + n) = sum_k kernel[k] * in[clamp(i + k - r)].
fn convolve(in: []const @Vector(4, f32), kernel: []const f32, out: []@Vector(4, f32), from: usize, n: usize) void {
    const kr = kernel.len / 2;
    const last: isize = @intCast(in.len - 1);
    for (from..from + n) |i| {
        var acc: @Vector(4, f32) = @splat(0);
        const base: isize = @as(isize, @intCast(i)) - @as(isize, @intCast(kr));
        if (base >= 0 and base + @as(isize, @intCast(kernel.len)) - 1 <= last) {
            const s = in[@intCast(base)..][0..kernel.len];
            for (kernel, s) |k, v| acc += v * @as(@Vector(4, f32), @splat(k));
        } else {
            for (kernel, 0..) |k, j| {
                const idx = std.math.clamp(base + @as(isize, @intCast(j)), 0, last);
                acc += in[@intCast(idx)] * @as(@Vector(4, f32), @splat(k));
            }
        }
        out[i] = acc;
    }
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

/// A scene with every command kind, parameterized so frames can differ in
/// one layer.
fn buildScene(b: *scene.Builder, pb: *raster.PathBuilder, frame: u32, image: scene.ImageRef) !scene.DisplayList {
    b.reset();
    const f: f32 = @floatFromInt(frame);
    const stops = [_]scene.Stop{
        .{ .offset = 0, .color = scene.Color.srgb8(0x20, 0x60, 0xd0, 0xff) },
        .{ .offset = 1, .color = scene.Color.srgb8(0xf0, 0xa0, 0x30, 0xff) },
    };
    try b.fillRect(.xywh(0, 0, 200, 150), .{ .gradient = .{ .geometry = .{ .linear = .{ .p0 = .zero, .p1 = .{ .x = 200, .y = 150 } } }, .stops = &stops } });
    try b.pushLayer(.{ .id = 1, .version = frame, .transform = .translate(20 + f * 7, 30) });
    try b.fillRoundedRect(.xywh(0, 0, 60, 40), .uniform(10, 10), .color(.srgb8(0xff, 0xff, 0xff, 0xc0)));
    try b.popLayer();
    try b.pushLayer(.{ .id = 2, .opacity = 0.6, .clip = .{ .shape = .{ .rounded_rect = .{ .rect = .xywh(90, 10, 100, 80), .radii = .uniform(16, 16) } } } });
    pb.reset();
    try pb.moveTo(80, 90);
    try pb.cubicTo(120, -20, 160, 140, 200, 20);
    try b.stroke(.{ .path = pb.path() }, .{ .width = 9, .join = .round, .cap = .round }, .color(.srgb8(0x10, 0x10, 0x10, 0xff)));
    try b.fill(.{ .rect = .xywh(100, 50, 30, 30) }, .nonzero, .{ .gradient = .{ .geometry = .{ .radial = .{ .c0 = .{ .x = 115, .y = 65 }, .r0 = 0, .c1 = .{ .x = 115, .y = 65 }, .r1 = 20 } }, .stops = &stops, .extend = .reflect } });
    try b.popLayer();
    try b.pushLayer(.{ .id = 3, .transform = Affine.rotate(0.3).then(.translate(60, 80)) });
    try b.image(.{ .image = image, .src = .xywh(0, 0, @floatFromInt(image.width), @floatFromInt(image.height)), .dst = .xywh(0, 0, 40, 40) });
    try b.popLayer();
    try b.pushLayer(.{ .id = 4, .blend = .multiply });
    try b.fillRect(.xywh(150, 100, 40, 40), .color(.srgb8(0xff, 0x40, 0x40, 0xff)));
    try b.popLayer();
    try b.pushLayer(.{ .id = 5 });
    try b.backdropBlur(.{ .rounded_rect = .{ .rect = .xywh(10, 95, 90, 45), .radii = .uniform(8, 8) } }, 4);
    try b.fillRect(.xywh(10, 95, 90, 45), .color(.srgb8(0xff, 0xff, 0xff, 0x30)));
    try b.popLayer();
    return b.finish(0);
}

fn checker(buf: []u8, w: u32, h: u32) scene.ImageRef {
    for (0..h) |y| for (0..w) |x| {
        const on = ((x / 4) + (y / 4)) % 2 == 0;
        const p = buf[(y * w + x) * 4 ..][0..4];
        p.* = if (on) .{ 0xff, 0x20, 0x80, 0xff } else .{ 0x20, 0xc0, 0x40, 0x80 };
    };
    return .{ .pixels = buf.ptr, .width = w, .height = h, .stride = w * 4, .format = .rgba8_srgb, .key = 1 };
}

test "solid rectangle is exact across tiles" {
    const r = try Renderer.create(testing.allocator, .serial);
    defer r.destroy();
    try r.resize(150, 100);
    var b = scene.Builder.init(testing.allocator);
    defer b.deinit();
    try b.fillRect(.xywh(60, 10, 10, 80), .color(.white));
    try b.fillRect(.xywh(10.5, 10, 1, 1), .color(.white));
    try r.render(try b.finish(0), .{});
    const px = r.pixels();
    try testing.expectEqual(Pixel{ 65535, 65535, 65535, 65535 }, px[50 * 150 + 63]);
    try testing.expectEqual(Pixel{ 65535, 65535, 65535, 65535 }, px[50 * 150 + 64]);
    try testing.expectEqual(Pixel{ 0, 0, 0, 0 }, px[50 * 150 + 70]);
    // Half coverage: coverage is 8-bit (128/255).
    try testing.expectEqual(Pixel{ 128 * 257, 128 * 257, 128 * 257, 128 * 257 }, px[10 * 150 + 10]);
}

test "damage-only frames match full redraws, serial and threaded" {
    var img_buf: [16 * 16 * 4]u8 = undefined;
    const img = checker(&img_buf, 16, 16);
    var b0 = scene.Builder.init(testing.allocator);
    defer b0.deinit();
    var b1 = scene.Builder.init(testing.allocator);
    defer b1.deinit();
    var pb = raster.PathBuilder.init(testing.allocator);
    defer pb.deinit();
    var tracker = scene.damage.Tracker.init(testing.allocator);
    defer tracker.deinit();
    var tp = pool.Pool.init(testing.allocator, 3);
    defer tp.deinit();

    const inc = try Renderer.create(testing.allocator, tp.executor());
    defer inc.destroy();
    const full = try Renderer.create(testing.allocator, .serial);
    defer full.destroy();
    try inc.resize(200, 150);
    try full.resize(200, 150);
    const vp = inc.viewport();

    var prev = try buildScene(&b0, &pb, 0, img);
    _ = try tracker.diff(null, prev, .identity, vp);
    try inc.render(prev, .{ .background = .black });
    const builders = [2]*scene.Builder{ &b0, &b1 };
    for (1..6) |frame| {
        const list = try buildScene(builders[frame % 2], &pb, @intCast(frame), img);
        const damage = try tracker.diff(prev, list, .identity, vp);
        try testing.expect(damage.len > 0);
        try inc.render(list, .{ .background = .black, .damage = damage });
        try full.render(list, .{ .background = .black });
        try testing.expectEqualSlices(Pixel, full.pixels(), inc.pixels());
        prev = list;
    }
}

test "steady-state frames allocate nothing" {
    var img_buf: [16 * 16 * 4]u8 = undefined;
    const img = checker(&img_buf, 16, 16);
    var counting: scene.CountingAllocator = .{ .child = testing.allocator };
    const gpa = counting.allocator();
    var b = scene.Builder.init(gpa);
    defer b.deinit();
    var pb = raster.PathBuilder.init(gpa);
    defer pb.deinit();
    var tp = pool.Pool.init(gpa, 2);
    defer tp.deinit();
    const r = try Renderer.create(gpa, tp.executor());
    defer r.destroy();
    try r.resize(200, 150);
    var out: [200 * 150 * 4]u8 = undefined;
    for (0..3) |frame| {
        if (frame == 2) counting.count = 0;
        const list = try buildScene(&b, &pb, 1, img);
        try r.render(list, .{ .target = .{ .pixels = &out, .stride = 200 * 4, .format = .argb8888 } });
    }
    try testing.expectEqual(@as(usize, 0), counting.count);
}

test "box radii approximate the Gaussian variance" {
    for ([_]f32{ 2.5, 4, 10, 20, 64 }) |sigma| {
        const bx = boxRadii(sigma).?;
        // A box of radius r has variance r(r + 1)/3; variances add.
        var v: f32 = 0;
        for (bx) |r| v += @as(f32, @floatFromInt(r * (r + 1))) / 3;
        try testing.expectApproxEqRel(sigma * sigma, v, 0.1);
    }
    try testing.expect(boxRadii(1.5) == null);
}
