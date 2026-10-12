//! Display list types and the builder.
//!
//! A display list is a flat sequence of commands. `push` opens a layer
//! (transform, clip, opacity, blend mode) and `pop` closes it; everything
//! else draws into the innermost open layer. The flat, stack-structured
//! form lowers directly to each backend: the CPU renderer walks it per
//! tile, Vulkan batches it, and PDF maps push/pop to q/Q with transparency
//! groups and clipping paths.
//!
//! Coordinates are y-down. Each layer's transform maps its coordinates into
//! its parent's. Colors are linear light with sRGB primaries and straight
//! (not premultiplied) alpha; compositing and gradient interpolation happen
//! in linear light (D11).

const std = @import("std");
const raster = @import("raster");
const Point = raster.Point;
const Rect = raster.Rect;
const Affine = raster.Affine;
const Path = raster.Path;
const Radii = raster.Radii;
pub const FillRule = raster.FillRule;
pub const StrokeStyle = raster.StrokeStyle;

/// Linear-light color with sRGB primaries and straight alpha. Components
/// outside [0, 1] are reserved for wide gamut and HDR (D11).
pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };

    /// From sRGB-encoded components in [0, 1] (CSS colors).
    pub fn srgb(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = srgbToLinear(r), .g = srgbToLinear(g), .b = srgbToLinear(b), .a = a };
    }

    /// From 8-bit sRGB-encoded components, e.g. srgb8(0x33, 0x66, 0x99, 0xff).
    pub fn srgb8(r: u8, g: u8, b: u8, a: u8) Color {
        return srgb(@as(f32, @floatFromInt(r)) / 255, @as(f32, @floatFromInt(g)) / 255, @as(f32, @floatFromInt(b)) / 255, @as(f32, @floatFromInt(a)) / 255);
    }

    pub fn withAlpha(c: Color, a: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }

    /// Relative luminance (Rec. 709 / sRGB primaries).
    pub fn luminance(c: Color) f32 {
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

/// The sRGB electro-optical transfer function (decode).
pub fn srgbToLinear(v: f32) f32 {
    if (v <= 0.04045) return v / 12.92;
    return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// The inverse of `srgbToLinear` (encode).
pub fn linearToSrgb(v: f32) f32 {
    if (v <= 0.0031308) return v * 12.92;
    return 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

/// How a gradient continues outside its [0, 1] parameter range.
pub const Extend = enum(u8) { pad, repeat, reflect };

pub const Stop = extern struct {
    offset: f32,
    color: Color,
};

pub const Gradient = struct {
    geometry: Geometry,
    /// Non-decreasing offsets. Offsets outside [0, 1] are allowed (COLRv1).
    stops: []const Stop,
    extend: Extend = .pad,
    /// Maps gradient space into the drawing's coordinates.
    transform: Affine = .identity,

    pub const Geometry = union(enum) {
        /// t is the projection onto p0 → p1.
        linear: struct { p0: Point, p1: Point },
        /// Two-point conical gradient (PDF type 3, canvas, COLRv1): t is the
        /// largest value for which the point lies on the circle
        /// lerp(c0, c1, t) with radius lerp(r0, r1, t) >= 0. Points with no
        /// such t are transparent.
        radial: struct { c0: Point, r0: f32, c1: Point, r1: f32 },
        /// t grows with the angle around `center`, clockwise on screen,
        /// from `start_angle` (t = 0) to `end_angle` (t = 1), in radians
        /// from the +x axis.
        sweep: struct { center: Point, start_angle: f32, end_angle: f32 },
    };
};

pub const Paint = union(enum) {
    solid: Color,
    gradient: Gradient,

    pub fn color(c: Color) Paint {
        return .{ .solid = c };
    }

    /// True when the paint is fully transparent everywhere.
    pub fn isInvisible(p: Paint) bool {
        return switch (p) {
            .solid => |c| c.a <= 0,
            .gradient => |g| for (g.stops) |s| {
                if (s.color.a > 0) break false;
            } else true,
        };
    }
};

pub const RoundedRect = struct {
    rect: Rect,
    radii: Radii,
};

pub const Shape = union(enum) {
    rect: Rect,
    rounded_rect: RoundedRect,
    path: Path,

    pub fn bounds(s: Shape) Rect {
        return switch (s) {
            .rect => |r| r,
            .rounded_rect => |r| r.rect,
            .path => |p| p.bounds(),
        };
    }

    /// Writes the shape as a path.
    pub fn toPath(s: Shape, b: *raster.PathBuilder) error{OutOfMemory}!void {
        switch (s) {
            .rect => |r| try b.rect(r),
            .rounded_rect => |r| try b.roundedRect(r.rect, r.radii),
            .path => |p| try b.append(p, .identity),
        }
    }
};

/// Compositing operators, in the order of COLRv1 CompositeMode and
/// hb_paint_composite_mode_t. Porter-Duff operators first, then the
/// separable and non-separable blend modes (which composite source-over).
pub const BlendMode = enum(u8) {
    clear,
    src,
    dst,
    src_over,
    dst_over,
    src_in,
    dst_in,
    src_out,
    dst_out,
    src_atop,
    dst_atop,
    xor,
    plus,
    screen,
    overlay,
    darken,
    lighten,
    color_dodge,
    color_burn,
    hard_light,
    soft_light,
    difference,
    exclusion,
    multiply,
    hue,
    saturation,
    color,
    luminosity,

    /// Operators that change the destination where the source is
    /// transparent. A layer using one affects everything inside its clip
    /// (or its parent's), not only its content's bounds.
    pub fn isUnbounded(m: BlendMode) bool {
        return switch (m) {
            .clear, .src, .src_in, .dst_in, .src_out, .dst_atop => true,
            else => false,
        };
    }
};

pub const Clip = struct {
    shape: Shape,
    rule: FillRule = .nonzero,
};

/// A layer: everything between its push and pop is drawn through it.
pub const Layer = struct {
    /// Nonzero ids identify a layer across display lists for damage
    /// tracking. Zero marks an anonymous layer, which is part of its
    /// parent's content.
    id: u32 = 0,
    /// Content version. Change it whenever anything about the layer other
    /// than its transform and opacity changes: clip, blend mode, damage,
    /// items, or anonymous child layers. Child layers with ids carry their
    /// own versions.
    version: u32 = 0,
    /// Maps this layer's coordinates into its parent's.
    transform: Affine = .identity,
    opacity: f32 = 1,
    blend: BlendMode = .src_over,
    /// Clip in this layer's coordinates.
    clip: ?Clip = null,
    /// What changed since the previous version with the same id, in layer
    /// coordinates. Null means the whole layer.
    damage: ?Rect = null,

    /// True when the layer needs its own buffer to composite correctly.
    pub fn isIsolated(l: Layer) bool {
        return l.opacity < 1 or l.blend != .src_over;
    }
};

pub const Push = struct {
    layer: Layer,
    /// Index of the matching pop.
    end: u32,
    /// Bounds of the layer's content in its own coordinates, limited by its
    /// clip. Infinite for unbounded blend modes.
    bounds: Rect,
};

pub const Fill = struct {
    shape: Shape,
    rule: FillRule = .nonzero,
    paint: Paint,
};

pub const Stroke = struct {
    shape: Shape,
    style: StrokeStyle,
    paint: Paint,
};

/// A font as the text engine provides it.
pub const Font = struct {
    /// The hb_font_t* that owns outlines and color paint. The text engine
    /// owns it; it must outlive every display list that refers to it and
    /// every renderer glyph cache entry (see the renderer's evictFont).
    handle: *anyopaque,
    /// Unique per font object (face plus variations) and never reused in
    /// the process; it keys glyph caches.
    key: u64,
};

pub const Glyph = extern struct {
    id: u32,
    /// Glyph origin on the baseline, in the run's coordinates.
    x: f32,
    y: f32,
};

pub const GlyphRun = struct {
    font: Font,
    /// Pixels per em in the run's coordinates.
    size: f32,
    glyphs: []const Glyph,
    /// Paint for outline glyphs. Color glyphs use their own colors, with
    /// this paint's color as the foreground color.
    paint: Paint,
    /// Must contain all ink of the run; used for culling and damage.
    bounds: Rect,
};

pub const ImageFormat = enum(u8) {
    /// 8-bit sRGB-encoded R, G, B, A bytes, straight alpha.
    rgba8_srgb,
    /// 8-bit sRGB-encoded B, G, R, A bytes, straight alpha.
    bgra8_srgb,
    /// 16-bit linear-light R, G, B, A, premultiplied, native endian. The
    /// renderers' working format.
    rgba16_linear_premul,

    pub fn bytesPerPixel(f: ImageFormat) u32 {
        return switch (f) {
            .rgba8_srgb, .bgra8_srgb => 4,
            .rgba16_linear_premul => 8,
        };
    }
};

/// Pixels owned by the caller. They must stay valid and unchanged while
/// any display list refers to them.
pub const ImageRef = struct {
    pixels: [*]const u8,
    width: u32,
    height: u32,
    /// Bytes per row.
    stride: u32,
    format: ImageFormat,
    /// Unique per pixel content: change it when the pixels change. Keys
    /// backend caches (e.g. Vulkan textures).
    key: u64,
};

pub const Filter = enum(u8) { nearest, linear };

pub const Image = struct {
    image: ImageRef,
    /// Source rectangle in image pixels.
    src: Rect,
    /// Destination rectangle in the drawing's coordinates.
    dst: Rect,
    filter: Filter = .linear,
    opacity: f32 = 1,
};

/// Replaces what is under `shape` with its Gaussian blur. The backdrop is
/// everything drawn before it in the nearest isolated layer (or the
/// surface), like CSS backdrop-filter.
pub const BackdropBlur = struct {
    shape: Shape,
    /// Standard deviation in the layer's coordinates.
    sigma: f32,
};

pub const Command = union(enum(u8)) {
    push: Push,
    pop,
    fill: Fill,
    stroke: Stroke,
    glyphs: GlyphRun,
    image: Image,
    backdrop_blur: BackdropBlur,
};

/// Largest blur sigma, in device pixels after transforms. Larger values
/// are clamped.
pub const max_blur_sigma: f32 = 64;

/// An immutable display list. It refers to memory owned by the builder
/// that produced it and stays valid until that builder is reset.
pub const DisplayList = struct {
    commands: []const Command = &.{},
    /// Version of the content outside any layer with an id.
    version: u32 = 0,
    /// Bounds of everything, in root coordinates.
    bounds: Rect = Rect.empty,
};

pub const Error = error{ OutOfMemory, InvalidPath, InvalidArgument, Unbalanced };

/// Builds display lists. Reuse one builder per frame slot: `reset` keeps
/// all capacity, so steady-state frames allocate nothing. Inputs (paths,
/// stops, glyphs, dash arrays) are copied; image pixels and fonts are not.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    commands: std.ArrayList(Command) = .empty,
    /// Open pushes: command index and accumulated content bounds.
    stack: std.ArrayList(Open) = .empty,
    root_bounds: Rect = Rect.empty,

    const Open = struct { index: u32, bounds: Rect };

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(b: *Builder) void {
        b.commands.deinit(b.gpa);
        b.stack.deinit(b.gpa);
        b.arena.deinit();
        b.* = undefined;
    }

    /// Invalidates every display list this builder produced.
    pub fn reset(b: *Builder) void {
        b.commands.clearRetainingCapacity();
        b.stack.clearRetainingCapacity();
        b.root_bounds = Rect.empty;
        _ = b.arena.reset(.retain_capacity);
    }

    pub fn pushLayer(b: *Builder, layer: Layer) Error!void {
        var l = layer;
        if (!finiteAffine(l.transform) or !std.math.isFinite(l.opacity)) return error.InvalidArgument;
        l.opacity = std.math.clamp(l.opacity, 0, 1);
        if (l.clip) |*c| c.shape = try b.copyShape(c.shape);
        try b.stack.ensureUnusedCapacity(b.gpa, 1);
        try b.commands.append(b.gpa, .{ .push = .{ .layer = l, .end = 0, .bounds = Rect.empty } });
        b.stack.appendAssumeCapacity(.{ .index = @intCast(b.commands.items.len - 1), .bounds = Rect.empty });
    }

    pub fn popLayer(b: *Builder) Error!void {
        const open = b.stack.pop() orelse return error.Unbalanced;
        try b.commands.append(b.gpa, .pop);
        const push = &b.commands.items[open.index].push;
        push.end = @intCast(b.commands.items.len - 1);
        var bounds = open.bounds;
        if (push.layer.blend.isUnbounded()) bounds = infinite;
        if (push.layer.clip) |c| bounds = bounds.intersect(c.shape.bounds());
        if (bounds.isEmpty()) bounds = Rect.empty;
        push.bounds = bounds;
        b.include(push.layer.transform.applyRect(bounds));
    }

    pub fn fill(b: *Builder, shape: Shape, rule: FillRule, paint: Paint) Error!void {
        const s = try b.copyShape(shape);
        const p = try b.copyPaint(paint);
        try b.commands.append(b.gpa, .{ .fill = .{ .shape = s, .rule = rule, .paint = p } });
        b.include(s.bounds());
    }

    pub fn fillRect(b: *Builder, r: Rect, paint: Paint) Error!void {
        return b.fill(.{ .rect = r }, .nonzero, paint);
    }

    pub fn fillRoundedRect(b: *Builder, r: Rect, radii: Radii, paint: Paint) Error!void {
        return b.fill(.{ .rounded_rect = .{ .rect = r, .radii = radii } }, .nonzero, paint);
    }

    pub fn fillPath(b: *Builder, path: Path, rule: FillRule, paint: Paint) Error!void {
        return b.fill(.{ .path = path }, rule, paint);
    }

    pub fn stroke(b: *Builder, shape: Shape, style: StrokeStyle, paint: Paint) Error!void {
        if (!std.math.isFinite(style.width) or !std.math.isFinite(style.miter_limit) or !std.math.isFinite(style.dash_offset))
            return error.InvalidArgument;
        const s = try b.copyShape(shape);
        const p = try b.copyPaint(paint);
        var st = style;
        st.dashes = try b.arena.allocator().dupe(f32, style.dashes);
        try b.commands.append(b.gpa, .{ .stroke = .{ .shape = s, .style = st, .paint = p } });
        b.include(s.bounds().outset(st.outset()));
    }

    pub fn glyphs(b: *Builder, run: GlyphRun) Error!void {
        if (!(run.size > 0) or !std.math.isFinite(run.size)) return error.InvalidArgument;
        for (run.glyphs) |g| if (!std.math.isFinite(g.x) or !std.math.isFinite(g.y)) return error.InvalidArgument;
        var r = run;
        r.glyphs = try b.arena.allocator().dupe(Glyph, run.glyphs);
        r.paint = try b.copyPaint(run.paint);
        try b.commands.append(b.gpa, .{ .glyphs = r });
        b.include(r.bounds);
    }

    pub fn image(b: *Builder, img: Image) Error!void {
        const ref = img.image;
        if (ref.width == 0 or ref.height == 0 or ref.stride < ref.width * ref.format.bytesPerPixel()) return error.InvalidArgument;
        if (!finiteRect(img.src) or !finiteRect(img.dst) or !std.math.isFinite(img.opacity)) return error.InvalidArgument;
        var i = img;
        i.opacity = std.math.clamp(i.opacity, 0, 1);
        try b.commands.append(b.gpa, .{ .image = i });
        b.include(i.dst);
    }

    pub fn backdropBlur(b: *Builder, shape: Shape, sigma: f32) Error!void {
        if (!(sigma >= 0) or !std.math.isFinite(sigma)) return error.InvalidArgument;
        const s = try b.copyShape(shape);
        try b.commands.append(b.gpa, .{ .backdrop_blur = .{ .shape = s, .sigma = sigma } });
        b.include(s.bounds());
    }

    /// The finished list. Fails if a layer is still open.
    pub fn finish(b: *Builder, version: u32) Error!DisplayList {
        if (b.stack.items.len != 0) return error.Unbalanced;
        return .{ .commands = b.commands.items, .version = version, .bounds = b.root_bounds };
    }

    fn include(b: *Builder, r: Rect) void {
        if (b.stack.items.len == 0) {
            b.root_bounds = b.root_bounds.unite(r);
        } else {
            const top = &b.stack.items[b.stack.items.len - 1];
            top.bounds = top.bounds.unite(r);
        }
    }

    fn copyShape(b: *Builder, shape: Shape) Error!Shape {
        switch (shape) {
            .rect => |r| {
                if (!finiteRect(r)) return error.InvalidArgument;
                return shape;
            },
            .rounded_rect => |r| {
                if (!finiteRect(r.rect)) return error.InvalidArgument;
                return .{ .rounded_rect = .{ .rect = r.rect, .radii = r.radii.fit(r.rect) } };
            },
            .path => |p| {
                try p.validate();
                const a = b.arena.allocator();
                return .{ .path = .{ .verbs = try a.dupe(raster.Verb, p.verbs), .points = try a.dupe(Point, p.points) } };
            },
        }
    }

    fn copyPaint(b: *Builder, paint: Paint) Error!Paint {
        switch (paint) {
            .solid => return paint,
            .gradient => |g| {
                if (g.stops.len == 0 or !finiteAffine(g.transform)) return error.InvalidArgument;
                var prev = -std.math.inf(f32);
                for (g.stops) |s| {
                    if (!std.math.isFinite(s.offset) or s.offset < prev) return error.InvalidArgument;
                    prev = s.offset;
                }
                var out = g;
                out.stops = try b.arena.allocator().dupe(Stop, g.stops);
                return .{ .gradient = out };
            },
        }
    }
};

const infinite: Rect = .{ .x0 = -std.math.inf(f32), .y0 = -std.math.inf(f32), .x1 = std.math.inf(f32), .y1 = std.math.inf(f32) };

fn finiteRect(r: Rect) bool {
    return std.math.isFinite(r.x0) and std.math.isFinite(r.y0) and std.math.isFinite(r.x1) and std.math.isFinite(r.y1);
}

fn finiteAffine(m: Affine) bool {
    inline for (.{ "a", "b", "c", "d", "e", "f" }) |f| if (!std.math.isFinite(@field(m, f))) return false;
    return true;
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

test "builder nests layers and computes bounds" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.fillRect(.xywh(0, 0, 10, 10), .color(.black));
    try b.pushLayer(.{ .id = 1, .transform = .translate(100, 0) });
    try b.fillRect(.xywh(0, 0, 5, 5), .color(.white));
    try b.pushLayer(.{ .clip = .{ .shape = .{ .rect = .xywh(0, 0, 2, 2) } } });
    try b.fillRect(.xywh(-50, -50, 100, 100), .color(.white));
    try b.popLayer();
    try b.popLayer();
    const list = try b.finish(1);
    try testing.expectEqual(@as(usize, 7), list.commands.len);
    const outer = list.commands[1].push;
    try testing.expectEqual(@as(u32, 6), outer.end);
    try testing.expectEqual(Rect.xywh(0, 0, 5, 5), outer.bounds);
    try testing.expectEqual(Rect.xywh(0, 0, 2, 2), list.commands[3].push.bounds);
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 105, .y1 = 10 }, list.bounds);
}

test "builder copies inputs and rejects bad ones" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var pb = raster.PathBuilder.init(testing.allocator);
    defer pb.deinit();
    try pb.rect(.xywh(0, 0, 1, 1));
    try b.fillPath(pb.path(), .even_odd, .color(.black));
    pb.reset(); // the list must not see this
    try pb.moveTo(5, 5);
    const list = try b.finish(0);
    try testing.expectEqual(@as(usize, 5), list.commands[0].fill.shape.path.verbs.len);

    try testing.expectError(error.InvalidArgument, b.fillRect(.xywh(std.math.nan(f32), 0, 1, 1), .color(.black)));
    const bad_stops = [_]Stop{ .{ .offset = 0.5, .color = .black }, .{ .offset = 0.2, .color = .white } };
    try testing.expectError(error.InvalidArgument, b.fillRect(.xywh(0, 0, 1, 1), .{ .gradient = .{
        .geometry = .{ .linear = .{ .p0 = .zero, .p1 = .{ .x = 1, .y = 0 } } },
        .stops = &bad_stops,
    } }));
    try testing.expectError(error.Unbalanced, b.popLayer());
    try b.pushLayer(.{});
    try testing.expectError(error.Unbalanced, b.finish(0));
}

test "steady-state frames allocate nothing" {
    var counting: CountingAllocator = .{ .child = testing.allocator };
    var b = Builder.init(counting.allocator());
    defer b.deinit();
    const stops = [_]Stop{ .{ .offset = 0, .color = .black }, .{ .offset = 1, .color = .white } };
    for (0..3) |frame| {
        b.reset();
        if (frame == 2) counting.count = 0;
        for (0..100) |i| {
            const f: f32 = @floatFromInt(i);
            try b.pushLayer(.{ .id = @intCast(i + 1), .clip = .{ .shape = .{ .rect = .xywh(0, 0, 5, 5) } } });
            try b.fillRoundedRect(.xywh(f, f, 10, 10), .uniform(2, 2), .{ .gradient = .{
                .geometry = .{ .linear = .{ .p0 = .zero, .p1 = .{ .x = 1, .y = 0 } } },
                .stops = &stops,
            } });
            try b.popLayer();
        }
        _ = try b.finish(0);
    }
    try testing.expectEqual(@as(usize, 0), counting.count);
}

/// Counts allocations (not frees) for steady-state checks.
pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    count: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.count += 1;
        return self.child.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.count += 1;
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }
};

test "color conversions round trip" {
    for (0..256) |i| {
        const v: f32 = @as(f32, @floatFromInt(i)) / 255;
        try testing.expectApproxEqAbs(v, linearToSrgb(srgbToLinear(v)), 1e-5);
    }
    try testing.expectApproxEqAbs(@as(f32, 0.21586), Color.srgb8(0x80, 0, 0, 0xff).r, 1e-4);
}
