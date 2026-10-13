//! Exports for canvases, images, and drawing (D28).
//!
//! A canvas node calls back into C to measure itself during layout and to
//! draw its content when it was invalidated or resized, both in the frame
//! phase (D5). A draw callback gets a `siv_draw` handle, valid for that
//! call only, and draws into a scratch `scene.Builder`; the finished list
//! is replayed into the canvas's own layer only if every drawing call
//! succeeded, so a failed drawing shows nothing rather than half of it.
//! Drawing errors are sticky like a transaction's.
//!
//! While a measure or draw callback runs (`App.painting`), calls that
//! would change the tree or re-enter the loop return SIV_ERROR_BUSY.
//!
//! Images are `ui.Image`s: siv_image holds one reference; image nodes and
//! the display lists that draw an image hold their own.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const scene = @import("scene");
const raster = @import("raster");
const text = @import("text");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");
const api = @import("api.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;
const NodeId = ui.NodeId;
const Point = raster.Point;
const Rect = raster.Rect;

pub const draw_tag = api.spec.handleTag("siv_draw");
pub const image_tag = api.spec.handleTag("siv_image");

/// The drawing in progress. One per application: draw callbacks never
/// nest.
pub const DrawState = struct {
    handle: u64 = 0,
    err: ?Error = null,
    builder: scene.Builder,
    path: raster.PathBuilder,
    /// The current path is exactly this rectangle or rounded rectangle, so
    /// fills and strokes keep the renderer's exact box coverage.
    simple: ?scene.Shape = null,
    /// The current path has a current point (for arcs and lines).
    open: bool = false,
    /// Layers the callback pushed and has not popped.
    depth: u32 = 0,
    /// Images drawn, each with a reference until the list is handed over.
    images: std.ArrayList(*ui.Image) = .empty,
    /// The canvas's window, or null for a page (print.zig).
    window: ?*Window = null,
    /// A page's direction and interned language (print.zig).
    page_rtl: bool = false,
    page_language: u32 = 0,
    node: NodeId = .none,
    /// Fonts were still loading when text was drawn.
    wanted_fonts: bool = false,

    pub fn init(gpa: std.mem.Allocator) DrawState {
        return .{ .builder = .init(gpa), .path = .init(gpa) };
    }

    pub fn deinit(d: *DrawState, gpa: std.mem.Allocator) void {
        d.dropImages(gpa);
        d.images.deinit(gpa);
        d.builder.deinit();
        d.path.deinit();
    }

    pub fn dropImages(d: *DrawState, gpa: std.mem.Allocator) void {
        _ = gpa;
        for (d.images.items) |img| img.release();
        d.images.clearRetainingCapacity();
    }

    pub fn clearPath(d: *DrawState) void {
        d.path.reset();
        d.simple = null;
        d.open = false;
    }
};

/// Canvases that drew text with fonts still loading; drawn again when a
/// font finishes.
pub const Waiting = struct { window: u32, node: NodeId };

// Canvas nodes ----------------------------------------------------------------

fn canvasOf(w: *Window, cb: ?tree.CanvasCb, d: t.CanvasDesc) ui.Canvas {
    const c = cb orelse return .{ .width = d.width, .height = d.height };
    return .{
        .draw = if (c.draw != null) drawCanvas else null,
        .measure = if (c.measure != null) measureCanvas else null,
        .user = w,
        .width = d.width,
        .height = d.height,
    };
}

/// Sets a canvas's callbacks in the tree and the ABI's table, as one
/// transaction operation.
fn setCanvas(w: *Window, id: NodeId, ptr: ?*const t.CanvasDesc) Error!void {
    const d = try runtime.readDesc(t.CanvasDesc, ptr);
    if (w.uiWin().node(id).kind != .canvas) return error.InvalidArgument;
    const cb: ?tree.CanvasCb = if (d.draw != null or d.measure != null) .{ .draw = d.draw, .measure = d.measure, .destroy = d.destroy, .user_data = d.user_data } else null;
    try w.txn.canvas_undo.ensureUnusedCapacity(w.owner.gpa(), 1);
    w.txn.ut.setCanvas(id, canvasOf(w, cb, d)) catch |err| return tree.mapTxn(err);
    const slot = w.nodes.canvas(id);
    w.txn.canvas_undo.appendAssumeCapacity(.{ .node = id, .old = slot.* });
    slot.* = cb;
    // With no callbacks to own it, user_data is released at once.
    if (cb == null) w.owner.release(d.destroy, d.user_data);
}

pub export fn siv_canvas(txn: t.Txn, parent: t.Node, desc: ?*const t.CanvasDesc) t.Node {
    const r = tree.build(txn, struct {
        fn f(w: *Window, p: t.Node, d: ?*const t.CanvasDesc) Error!NodeId {
            const id = try tree.create(w, p, .canvas);
            // Its own layer: redrawing it repaints nothing else.
            var v = w.uiWin().node(id).visual;
            v.layer = true;
            w.txn.ut.setVisual(id, v) catch |err| return tree.mapTxn(err);
            try setCanvas(w, id, d);
            return id;
        }
    }.f, .{ parent, desc });
    if (r == .null) releaseDesc(txn, desc);
    return r;
}

/// A failed call that took a destroy-notify runs it (D2).
fn releaseDesc(txn: t.Txn, desc: ?*const t.CanvasDesc) void {
    const d = desc orelse return;
    const f = d.destroy orelse return;
    if (application.App.window(@backingInt(txn), application.txn_tag)) |w| w.owner.release(f, d.user_data) else |_| f(d.user_data);
}

pub export fn siv_set_canvas(txn: t.Txn, node: t.Node, desc: ?*const t.CanvasDesc) t.Result {
    const r = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, d: ?*const t.CanvasDesc) Error!void {
            try setCanvas(w, try tree.nodeIn(w, n), d);
        }
    }.f, .{ node, desc });
    if (r != .ok) releaseDesc(txn, desc);
    return r;
}

pub export fn siv_invalidate(txn: t.Txn, node: t.Node) t.Result {
    return tree.run(txn, struct {
        fn f(w: *Window, n: t.Node) Error!void {
            w.txn.ut.invalidate(try tree.nodeIn(w, n)) catch |err| return tree.mapTxn(err);
        }
    }.f, .{node});
}

pub export fn siv_invalidate_size(txn: t.Txn, node: t.Node) t.Result {
    return tree.run(txn, struct {
        fn f(w: *Window, n: t.Node) Error!void {
            w.txn.ut.remeasure(try tree.nodeIn(w, n)) catch |err| return tree.mapTxn(err);
        }
    }.f, .{node});
}

fn measureCanvas(user: ?*anyopaque, _: *ui.Window, id: NodeId, min_w: f32, max_w: f32, min_h: f32, max_h: f32) ui.CanvasSize {
    const w: *Window = @ptrCast(@alignCast(user));
    if (w.dead) return .{};
    const cb = w.nodes.canvas(id).* orelse return .{};
    const f = cb.measure orelse return .{};
    const self = w.owner;
    var c: t.Constraints = .{ .min_width = min_w, .max_width = max_w, .min_height = min_h, .max_height = max_h };
    self.enter();
    self.painting += 1;
    const s = f(cb.user_data, @fromBackingInt(w.nodes.handle(id)), &c);
    self.painting -= 1;
    self.leave();
    return .{ .width = s.width, .height = s.height };
}

fn drawCanvas(user: ?*anyopaque, uw: *ui.Window, id: NodeId, b: *scene.Builder, width: f32, height: f32) scene.Error!void {
    const w: *Window = @ptrCast(@alignCast(user));
    if (w.dead) return;
    const cb = w.nodes.canvas(id).* orelse return;
    const f = cb.draw orelse return;
    const self = w.owner;
    const gpa = self.gpa();
    const d = &self.draw;
    d.builder.reset();
    d.clearPath();
    d.err = null;
    d.depth = 0;
    d.window = w;
    d.node = id;
    d.wanted_fonts = false;
    defer d.dropImages(gpa);
    self.root.handles.ensureUnusedCapacity(gpa) catch return error.OutOfMemory;
    d.handle = self.root.handles.insert(gpa, draw_tag, 0) catch unreachable;
    self.enter();
    self.painting += 1;
    f(cb.user_data, @fromBackingInt(w.nodes.handle(id)), @fromBackingInt(d.handle), width, height);
    self.painting -= 1;
    self.leave();
    _ = self.root.handles.remove(d.handle, draw_tag) catch unreachable;
    d.handle = 0;

    if (d.wanted_fonts) self.waiting.append(gpa, .{ .window = w.index, .node = id }) catch {};
    // Layers the callback left open close here.
    while (d.err == null and d.depth > 0) : (d.depth -= 1) d.builder.popLayer() catch |err| {
        d.err = mapScene(err);
    };
    if (d.err != null) return error.InvalidArgument;
    const list = d.builder.finish(0) catch return error.InvalidArgument;
    // The list keeps the images alive once the compositor has it.
    for (d.images.items) |img| try uw.holdImage(b, img);
    try replay(b, list);
}

/// The palette pages draw with: the light variant of the application's
/// theme, for paper.
pub fn lightPalette(self: *App) ui.theme.Palette {
    var theme = self.app.theme;
    theme.scheme = .light;
    return ui.theme.resolve(&theme, self.app.desktop.values.themeInput());
}

/// Copies a finished list into another builder.
fn replay(b: *scene.Builder, list: scene.DisplayList) scene.Error!void {
    for (list.commands) |cmd| switch (cmd) {
        .push => |p| try b.pushLayer(p.layer),
        .pop => try b.popLayer(),
        .fill => |f| try b.fill(f.shape, f.rule, f.paint),
        .stroke => |s| try b.stroke(s.shape, s.style, s.paint),
        .glyphs => |g| try b.glyphs(g),
        .image => |i| try b.image(i),
        .backdrop_blur => |bb| try b.backdropBlur(bb.shape, bb.sigma),
        .shadow => |s| try b.shadow(s),
    };
}

pub fn mapScene(err: scene.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPath, error.InvalidArgument, error.Unbalanced => error.InvalidArgument,
    };
}

/// Fonts finished loading: canvases that drew with missing fonts draw
/// again (dispatch phase).
pub fn onFontsLoaded(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    @import("print.zig").onFontsLoaded(self);
    for (self.waiting.items) |wt| {
        const w = (if (wt.window < self.windows.items.len) self.windows.items[wt.window] else null) orelse continue;
        const uw = w.uiWin();
        if (!uw.isLive(wt.node) or uw.node(wt.node).kind != .canvas) continue;
        uw.markPaint(wt.node);
        uw.requestFrame();
    }
    self.waiting.clearRetainingCapacity();
}

// Drawing ---------------------------------------------------------------------

/// Runs a drawing operation under the sticky-error rule.
fn draw(handle: t.Draw, comptime f: anytype, args: anytype) t.Result {
    const self, _ = runtime.Root.owner(App, application.app_tag, @backingInt(handle), draw_tag) catch |err| return t.resultOf(err);
    const d = &self.draw;
    if (d.err) |e| return t.resultOf(e);
    @call(.auto, f, .{ self, d } ++ args) catch |err| {
        d.err = err;
        return t.resultOf(err);
    };
    return .ok;
}

fn finite(vs: anytype) Error!void {
    inline for (vs) |v| if (!std.math.isFinite(v)) return error.InvalidArgument;
}

fn rectOf(r: t.Rect) Error!Rect {
    try finite(.{ r.x, r.y, r.width, r.height });
    if (r.width < 0 or r.height < 0) return error.InvalidArgument;
    return .xywh(r.x, r.y, r.width, r.height);
}

pub export fn siv_draw_status(handle: t.Draw) t.Result {
    return draw(handle, struct {
        fn f(_: *App, _: *DrawState) Error!void {}
    }.f, .{});
}

pub export fn siv_draw_move_to(handle: t.Draw, x: f32, y: f32) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, px: f32, py: f32) Error!void {
            try finite(.{ px, py });
            try d.path.moveTo(px, py);
            d.simple = null;
            d.open = true;
        }
    }.f, .{ x, y });
}

fn ensureOpen(d: *DrawState) Error!void {
    if (!d.open) {
        try d.path.moveTo(d.path.current.x, d.path.current.y);
        d.open = true;
    }
    d.simple = null;
}

pub export fn siv_draw_line_to(handle: t.Draw, x: f32, y: f32) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, px: f32, py: f32) Error!void {
            try finite(.{ px, py });
            try ensureOpen(d);
            try d.path.lineTo(px, py);
        }
    }.f, .{ x, y });
}

pub export fn siv_draw_quad_to(handle: t.Draw, cx: f32, cy: f32, x: f32, y: f32) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, a: f32, b: f32, px: f32, py: f32) Error!void {
            try finite(.{ a, b, px, py });
            try ensureOpen(d);
            try d.path.quadTo(a, b, px, py);
        }
    }.f, .{ cx, cy, x, y });
}

pub export fn siv_draw_cubic_to(handle: t.Draw, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, a: f32, b: f32, c: f32, e: f32, px: f32, py: f32) Error!void {
            try finite(.{ a, b, c, e, px, py });
            try ensureOpen(d);
            try d.path.cubicTo(a, b, c, e, px, py);
        }
    }.f, .{ c1x, c1y, c2x, c2y, x, y });
}

pub export fn siv_draw_arc(handle: t.Draw, cx: f32, cy: f32, radius: f32, start_angle: f32, end_angle: f32) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, x: f32, y: f32, r: f32, a0: f32, a1: f32) Error!void {
            try finite(.{ x, y, r, a0, a1 });
            if (r < 0) return error.InvalidArgument;
            try arc(d, x, y, r, a0, a1);
        }
    }.f, .{ cx, cy, radius, start_angle, end_angle });
}

/// Cubic Bézier segments of at most a quarter turn each.
fn arc(d: *DrawState, cx: f32, cy: f32, r: f32, a0: f32, a1: f32) Error!void {
    const sweep = std.math.clamp(a1 - a0, -2 * std.math.pi, 2 * std.math.pi);
    const sx = cx + r * @cos(a0);
    const sy = cy + r * @sin(a0);
    if (d.open) try d.path.lineTo(sx, sy) else try d.path.moveTo(sx, sy);
    d.open = true;
    d.simple = null;
    const n: u32 = @max(1, @as(u32, @intFromFloat(@ceil(@abs(sweep) / (std.math.pi / 2.0) - 1e-4))));
    const step = sweep / @as(f32, @floatFromInt(n));
    const k = 4.0 / 3.0 * @tan(step / 4);
    var a = a0;
    for (0..n) |_| {
        const b = a + step;
        const c0 = @cos(a);
        const s0 = @sin(a);
        const c1 = @cos(b);
        const s1 = @sin(b);
        try d.path.cubicTo(cx + r * (c0 - k * s0), cy + r * (s0 + k * c0), cx + r * (c1 + k * s1), cy + r * (s1 - k * c1), cx + r * c1, cy + r * s1);
        a = b;
    }
}

pub export fn siv_draw_close(handle: t.Draw) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState) Error!void {
            if (!d.open) return;
            try d.path.close();
            d.open = false;
            d.simple = null;
        }
    }.f, .{});
}

/// Adds a closed shape; the path stays "simple" if it was empty.
fn addShape(d: *DrawState, shape: scene.Shape) Error!void {
    const was_empty = d.path.path().isEmpty();
    try shape.toPath(&d.path);
    d.open = false;
    d.simple = if (was_empty) shape else null;
}

pub export fn siv_draw_rect(handle: t.Draw, rect: t.Rect) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, r: t.Rect) Error!void {
            try addShape(d, .{ .rect = try rectOf(r) });
        }
    }.f, .{rect});
}

pub export fn siv_draw_rounded_rect(handle: t.Draw, rect: t.Rect, radii: t.Radii) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, r: t.Rect, rd: t.Radii) Error!void {
            try finite(.{ rd.top_left, rd.top_right, rd.bottom_right, rd.bottom_left });
            const c = struct {
                fn p(v: f32) Point {
                    return .{ .x = @max(0, v), .y = @max(0, v) };
                }
            }.p;
            const rect_ = try rectOf(r);
            const radii_: raster.Radii = .{ .tl = c(rd.top_left), .tr = c(rd.top_right), .br = c(rd.bottom_right), .bl = c(rd.bottom_left) };
            try addShape(d, .{ .rounded_rect = .{ .rect = rect_, .radii = radii_.fit(rect_) } });
        }
    }.f, .{ rect, radii });
}

pub export fn siv_draw_ellipse(handle: t.Draw, rect: t.Rect) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, r: t.Rect) Error!void {
            try d.path.ellipse(try rectOf(r));
            d.open = false;
            d.simple = null;
        }
    }.f, .{rect});
}

/// The current path as a shape for the builder, which copies it.
fn currentShape(d: *DrawState) scene.Shape {
    return d.simple orelse .{ .path = d.path.path() };
}

/// A paint descriptor. Gradient stops are copied into `stops`.
fn paintOf(gpa: std.mem.Allocator, ptr: ?*const t.PaintDesc, stops: *std.ArrayList(scene.Stop)) Error!scene.Paint {
    const p = try runtime.readDesc(t.PaintDesc, ptr);
    const kind = try runtime.enumValue(t.PaintType, p.type);
    if (kind == .solid) return .color(try tree.color(p.color, .black));
    try finite(.{ p.x0, p.y0, p.x1, p.y1, p.r0, p.r1, p.start_angle, p.end_angle });
    const src = try runtime.array(t.GradientStop, p.stops, p.stops_count);
    if (src.len == 0) return error.InvalidArgument;
    try stops.ensureTotalCapacity(gpa, src.len);
    for (src) |s| {
        try finite(.{s.offset});
        stops.appendAssumeCapacity(.{ .offset = s.offset, .color = try tree.color(s.color, .transparent) });
    }
    if (p.r0 < 0 or p.r1 < 0) return error.InvalidArgument;
    return .{ .gradient = .{
        .geometry = switch (kind) {
            .linear => .{ .linear = .{ .p0 = .{ .x = p.x0, .y = p.y0 }, .p1 = .{ .x = p.x1, .y = p.y1 } } },
            .radial => .{ .radial = .{ .c0 = .{ .x = p.x0, .y = p.y0 }, .r0 = p.r0, .c1 = .{ .x = p.x1, .y = p.y1 }, .r1 = p.r1 } },
            .sweep => .{ .sweep = .{ .center = .{ .x = p.x0, .y = p.y0 }, .start_angle = p.start_angle, .end_angle = p.end_angle } },
            else => unreachable,
        },
        .stops = stops.items,
        .extend = switch (try runtime.enumValue(t.Extend, p.extend)) {
            .pad => .pad,
            .repeat => .repeat,
            .reflect => .reflect,
            _ => unreachable,
        },
    } };
}

pub export fn siv_draw_fill(handle: t.Draw, paint: ?*const t.PaintDesc, flags: t.FillFlags) t.Result {
    return draw(handle, struct {
        fn f(self: *App, d: *DrawState, pd: ?*const t.PaintDesc, fl_raw: t.FillFlags) Error!void {
            const fl = try runtime.flags(t.FillFlags, fl_raw);
            var stops: std.ArrayList(scene.Stop) = .empty;
            defer stops.deinit(self.gpa());
            const p = try paintOf(self.gpa(), pd, &stops);
            if (!d.path.path().isEmpty()) d.builder.fill(currentShape(d), if (fl.even_odd) .even_odd else .nonzero, p) catch |err| return mapScene(err);
            if (!fl.keep_path) d.clearPath();
        }
    }.f, .{ paint, flags });
}

pub export fn siv_draw_stroke(handle: t.Draw, stroke: ?*const t.StrokeDesc, paint: ?*const t.PaintDesc) t.Result {
    return draw(handle, struct {
        fn f(self: *App, d: *DrawState, sd_ptr: ?*const t.StrokeDesc, pd: ?*const t.PaintDesc) Error!void {
            const sd = try runtime.readDesc(t.StrokeDesc, sd_ptr);
            const fl = try runtime.flags(t.StrokeFlags, sd.flags);
            const dashes = try runtime.array(f32, sd.dashes, sd.dashes_count);
            try finite(.{ sd.width, sd.miter_limit, sd.dash_offset });
            for (dashes) |v| try finite(.{v});
            if (sd.width < 0 or sd.miter_limit < 0) return error.InvalidArgument;
            const style: raster.StrokeStyle = .{
                .width = if (sd.width == 0) 1 else sd.width,
                .miter_limit = if (sd.miter_limit == 0) 4 else sd.miter_limit,
                .dashes = dashes,
                .dash_offset = sd.dash_offset,
                .join = switch (try runtime.enumValue(t.LineJoin, sd.join)) {
                    .miter => .miter,
                    .round => .round,
                    .bevel => .bevel,
                    _ => unreachable,
                },
                .cap = switch (try runtime.enumValue(t.LineCap, sd.cap)) {
                    .butt => .butt,
                    .round => .round,
                    .square => .square,
                    _ => unreachable,
                },
            };
            var stops: std.ArrayList(scene.Stop) = .empty;
            defer stops.deinit(self.gpa());
            const p = try paintOf(self.gpa(), pd, &stops);
            if (!d.path.path().isEmpty()) d.builder.stroke(currentShape(d), style, p) catch |err| return mapScene(err);
            if (!fl.keep_path) d.clearPath();
        }
    }.f, .{ stroke, paint });
}

pub export fn siv_draw_image(handle: t.Draw, image: t.Image, dst: t.Rect, src: t.Rect, opacity: f32, flags: t.ImageFlags) t.Result {
    return draw(handle, struct {
        fn f(self: *App, d: *DrawState, im: t.Image, dr: t.Rect, sr: t.Rect, o: f32, fl_raw: t.ImageFlags) Error!void {
            const img = try imageOf(self, im);
            const fl = try runtime.flags(t.ImageFlags, fl_raw);
            try finite(.{o});
            const whole = sr.x == 0 and sr.y == 0 and sr.width == 0 and sr.height == 0;
            const s = if (whole) Rect.xywh(0, 0, @floatFromInt(img.width), @floatFromInt(img.height)) else try rectOf(sr);
            try d.images.ensureUnusedCapacity(self.gpa(), 1);
            d.builder.image(.{ .image = img.sceneRef(), .src = s, .dst = try rectOf(dr), .opacity = o, .filter = if (fl.nearest) .nearest else .linear }) catch |err| return mapScene(err);
            d.images.appendAssumeCapacity(img.retain());
        }
    }.f, .{ image, dst, src, opacity, flags });
}

pub export fn siv_draw_text(handle: t.Draw, x: f32, y: f32, width: f32, str: ?[*]const u8, str_len: usize, style: ?*const t.TextStyleDesc) t.Result {
    return draw(handle, struct {
        fn f(self: *App, d: *DrawState, px: f32, py: f32, wd: f32, ptr: ?[*]const u8, len: usize, sd: ?*const t.TextStyleDesc) Error!void {
            try finite(.{ px, py, wd });
            if (wd < 0) return error.InvalidArgument;
            const s = try runtime.string(ptr, len);
            var stops: tree.TabStops = undefined;
            const props = try tree.textPropsOf(sd, &stops);
            // Pages (print.zig) have the document's direction and language
            // and the light theme, without the desktop's text scaling.
            const uw: ?*ui.Window = if (d.window) |w| w.uiWin() else null;
            const scale: f32 = if (uw != null) @floatCast(self.app.desktop.values.text_scale) else 1;
            var shaped = try Shaped.init(self, s, props, wd, if (uw) |u| u.state(d.node).rtl else d.page_rtl, if (uw) |u| u.language else d.page_language, scale);
            defer shaped.deinit();
            if (shaped.wanted) d.wanted_fonts = true;
            const l = shaped.layout orelse return;
            const palette = if (uw) |u| u.palette else lightPalette(self);
            var glyphs: std.ArrayList(scene.Glyph) = .empty;
            defer glyphs.deinit(self.gpa());
            var clusters: std.ArrayList(u32) = .empty;
            defer clusters.deinit(self.gpa());
            const cache = &self.app.fonts.cache;
            for (l.lines) |line| for (l.lineRuns(line)) |r| {
                const face = cache.face(r.font) orelse continue;
                glyphs.clearRetainingCapacity();
                clusters.clearRetainingCapacity();
                var bounds = Rect.empty;
                for (l.runGlyphs(r)) |g| {
                    const gx = px + line.x + g.x;
                    const gy = py + line.baseline + g.y;
                    try glyphs.append(self.gpa(), .{ .id = g.id, .x = gx, .y = gy });
                    try clusters.append(self.gpa(), std.math.clamp(g.cluster, r.start, r.end) - r.start);
                    if (face.glyphBounds(g.id, r.size)) |gb| bounds = bounds.unite(.xywh(gx + gb.x, gy + gb.y, gb.width, gb.height));
                }
                if (bounds.isEmpty()) continue;
                d.builder.glyphs(.{
                    .font = .{ .handle = face.font, .key = face.key },
                    .size = r.size,
                    .glyphs = glyphs.items,
                    .paint = .color(palette.pick(props.style.color, props.style.color_token)),
                    .bounds = bounds.outset(1),
                    // The characters, for PDF output.
                    .text = .{ .bytes = s[r.start..r.end], .clusters = clusters.items },
                }) catch |err| return mapScene(err);
            };
        }
    }.f, .{ x, y, width, str, str_len, style });
}

pub export fn siv_draw_backdrop_blur(handle: t.Draw, sigma: f32, flags: t.FillFlags) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, sg: f32, fl_raw: t.FillFlags) Error!void {
            const fl = try runtime.flags(t.FillFlags, fl_raw);
            try finite(.{sg});
            if (sg < 0 or sg > scene.max_blur_sigma) return error.InvalidArgument;
            if (!d.path.path().isEmpty()) d.builder.backdropBlur(currentShape(d), sg) catch |err| return mapScene(err);
            if (!fl.keep_path) d.clearPath();
        }
    }.f, .{ sigma, flags });
}

fn push(d: *DrawState, layer: scene.Layer) Error!void {
    d.builder.pushLayer(layer) catch |err| return mapScene(err);
    d.depth += 1;
}

pub export fn siv_draw_push_transform(handle: t.Draw, transform: t.Affine) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, m: t.Affine) Error!void {
            try push(d, .{ .transform = .{ .a = m.a, .b = m.b, .c = m.c, .d = m.d, .e = m.e, .f = m.f } });
        }
    }.f, .{transform});
}

pub export fn siv_draw_push_clip(handle: t.Draw, flags: t.FillFlags) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, fl_raw: t.FillFlags) Error!void {
            const fl = try runtime.flags(t.FillFlags, fl_raw);
            try push(d, .{ .clip = .{ .shape = currentShape(d), .rule = if (fl.even_odd) .even_odd else .nonzero } });
            if (!fl.keep_path) d.clearPath();
        }
    }.f, .{flags});
}

pub export fn siv_draw_push_opacity(handle: t.Draw, opacity: f32) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, o: f32) Error!void {
            try push(d, .{ .opacity = o });
        }
    }.f, .{opacity});
}

pub export fn siv_draw_push_blend(handle: t.Draw, mode: t.BlendMode) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState, m: t.BlendMode) Error!void {
            const v = try runtime.enumValue(t.BlendMode, m);
            const blend = blendOf(v);
            try push(d, .{ .blend = blend, .isolate = true });
        }
    }.f, .{mode});
}

/// siv_blend_mode by name; normal is source-over.
fn blendOf(v: t.BlendMode) scene.BlendMode {
    if (v == .normal) return .src_over;
    inline for (@typeInfo(scene.BlendMode).@"enum".field_names) |name| {
        if (@hasField(t.BlendMode, name) and v == @field(t.BlendMode, name)) return @field(scene.BlendMode, name);
    }
    unreachable;
}

comptime {
    for (@typeInfo(t.BlendMode).@"enum".field_names) |name| {
        if (!std.mem.eql(u8, name, "normal") and !@hasField(scene.BlendMode, name)) @compileError("siv_blend_mode has no scene mode: " ++ name);
    }
    for (@typeInfo(scene.BlendMode).@"enum".field_names) |name| {
        if (!std.mem.eql(u8, name, "src_over") and !@hasField(t.BlendMode, name)) @compileError("siv_blend_mode lacks " ++ name);
    }
}

pub export fn siv_draw_pop(handle: t.Draw) t.Result {
    return draw(handle, struct {
        fn f(_: *App, d: *DrawState) Error!void {
            if (d.depth == 0) return error.InvalidArgument;
            d.builder.popLayer() catch |err| return mapScene(err);
            d.depth -= 1;
        }
    }.f, .{});
}

// Text layout -----------------------------------------------------------------

/// Text shaped and laid out with the application's fonts, as a text node
/// would, for one call.
const Shaped = struct {
    paragraph: ?text.ShapedParagraph = null,
    layout: ?text.Layout = null,
    scratch: std.heap.ArenaAllocator,
    /// Fonts were still loading; their loads were requested.
    wanted: bool = false,

    fn init(self: *App, s: []const u8, props: ui.Text, width: f32, rtl: bool, window_language: u32, text_scale: f32) Error!Shaped {
        if (!std.unicode.utf8ValidateSlice(s) or s.len >= std.math.maxInt(u32)) return error.InvalidArgument;
        const gpa = self.gpa();
        var sh: Shaped = .{ .scratch = .init(gpa) };
        errdefer sh.deinit();
        if (s.len == 0) return sh;
        const fonts = &self.app.fonts;
        const st = props.style;
        const family = try fonts.intern(st.family);
        var language = try fonts.intern(st.language);
        if (language == 0) language = window_language;
        // Desktop text scaling applies to canvas text as to text nodes.
        const size = self.app.palette().textSize(st.size, st.size_role) * text_scale;
        const chain = try fonts.chain(.{ .family = family, .language = language, .weight = ui.cssWeight(st, null), .slant = st.slant, .width = st.width, .size = size });
        const lang = fonts.name(language);
        sh.paragraph = text.ShapedParagraph.init(gpa, sh.scratch.allocator(), &fonts.cache, s, &.{.{
            .end = @intCast(s.len),
            .style = .{ .fonts = chain, .size = size, .language = if (lang.len == 0) "und" else lang },
        }}, if (rtl) .auto_rtl else .auto_ltr) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidArgument,
        };
        const p = &sh.paragraph.?;
        if (p.wanted.len != 0) {
            fonts.request(p.wanted);
            sh.wanted = true;
        }
        sh.layout = text.Layout.init(gpa, sh.scratch.allocator(), &fonts.cache, p, .{
            .width = if (width > 0 and props.wrap) width else null,
            .paragraphs = &.{.{ .end = std.math.maxInt(u32), .style = props.paragraph }},
            .tab_stops = props.tab_stops,
            .break_words = props.break_words,
            .alignment = props.alignment,
            .hyphenate = props.hyphenate,
            .hyphenation = &fonts.hyphenation,
            .optimal = props.optimal,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidArgument,
        };
        // Lines align by the drawing's direction (the canvas node's, or the
        // page's), not by each paragraph's own, as text nodes do (D21): an
        // English line in a right-to-left canvas is flush right, while bidi
        // ordering within it still follows its text. Within the given width,
        // also without wrapping; else within the widest line.
        const l = &sh.layout.?;
        const box = if (width > 0) width else l.width;
        for (@constCast(l.lines)) |*line| {
            // Indents follow the drawing's direction like the alignment.
            const target = line.contentXIn(box, rtl, props.alignment);
            // Hanging whitespace sits left of a right-to-left line's content.
            line.x = target - if (line.rtl()) line.advance - line.width else 0;
        }
        return sh;
    }

    fn deinit(sh: *Shaped) void {
        if (sh.layout) |*l| l.deinit();
        if (sh.paragraph) |*p| p.deinit();
        sh.scratch.deinit();
    }
};

pub export fn siv_app_measure_text(app: t.App, str: ?[*]const u8, str_len: usize, max_width: f32, style: ?*const t.TextStyleDesc, metrics: ?*t.TextMetrics) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, ptr: ?[*]const u8, len: usize, mw: f32, sd: ?*const t.TextStyleDesc, out: ?*t.TextMetrics) Error!void {
            const self = try App.get(@backingInt(a));
            const s = try runtime.string(ptr, len);
            if (!std.math.isFinite(mw) or mw < 0) return error.InvalidArgument;
            var stops: tree.TabStops = undefined;
            const props = try tree.textPropsOf(sd, &stops);
            const dest = try runtime.out(t.TextMetrics, out);
            var shaped = try Shaped.init(self, s, props, mw, false, 0, @floatCast(self.app.desktop.values.text_scale));
            defer shaped.deinit();
            const l = shaped.layout orelse {
                dest.* = .{ .width = 0, .height = 0, .baseline = 0 };
                return;
            };
            dest.* = .{ .width = l.width, .height = l.height, .baseline = if (l.lines.len != 0) l.lines[0].baseline else 0 };
        }
    }.f(app, str, str_len, max_width, style, metrics));
}

// Images ----------------------------------------------------------------------

pub fn imageOf(self: *App, image: t.Image) Error!*ui.Image {
    const index = try self.root.handles.get(@backingInt(image), image_tag);
    return self.images.items[index] orelse error.InvalidHandle;
}

pub export fn siv_image_create(app: t.App, desc: ?*const t.ImageDesc, image: ?*t.Image) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, ptr: ?*const t.ImageDesc, out: ?*t.Image) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.ImageDesc, ptr);
            const pixels = try runtime.array(u8, d.pixels, d.pixels_count);
            const format: scene.ImageFormat = switch (try runtime.enumValue(t.ImageFormat, d.format)) {
                .rgba8 => .rgba8_srgb,
                .bgra8 => .bgra8_srgb,
                .bgrx8 => .bgrx8_srgb,
                _ => unreachable,
            };
            const dest = try runtime.out(t.Image, out);
            const img = ui.Image.create(self.gpa(), .{ .pixels = pixels, .width = d.width, .height = d.height, .stride = d.stride, .format = format }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidArgument => error.InvalidArgument,
            };
            dest.* = adoptImage(self, img) catch |err| {
                img.release();
                return err;
            };
        }
    }.f(app, desc, image));
}

/// Gives an image a handle; the handle takes over its reference. On
/// failure the caller still holds it.
pub fn adoptImage(self: *App, img: *ui.Image) Error!t.Image {
    const gpa = self.gpa();
    const index: u32 = for (self.images.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        try self.images.append(gpa, null);
        break :blk @intCast(self.images.items.len - 1);
    };
    try self.root.handles.ensureUnusedCapacity(gpa);
    self.images.items[index] = img;
    return @fromBackingInt(self.root.handles.insert(gpa, image_tag, index) catch unreachable);
}

pub export fn siv_image_destroy(image: t.Image) t.Result {
    const self, const index = runtime.Root.owner(App, application.app_tag, @backingInt(image), image_tag) catch |err| return t.resultOf(err);
    _ = self.root.handles.remove(@backingInt(image), image_tag) catch unreachable;
    self.images.items[index].?.release();
    self.images.items[index] = null;
    return .ok;
}

fn imageViewOf(self: *App, ptr: ?*const t.ImageViewDesc) Error!ui.ImageView {
    const d = try runtime.readDesc(t.ImageViewDesc, ptr);
    const fl = try runtime.flags(t.ImageFlags, d.flags);
    return .{
        .image = if (d.image == .null) null else try imageOf(self, d.image),
        .fit = switch (try runtime.enumValue(t.Fit, d.fit)) {
            .contain => .contain,
            .cover => .cover,
            .fill => .fill,
            .none => .none,
            _ => unreachable,
        },
        .filter = if (fl.nearest) .nearest else .linear,
        .mirror = fl.mirror_rtl,
    };
}

pub export fn siv_image_view(txn: t.Txn, parent: t.Node, desc: ?*const t.ImageViewDesc) t.Node {
    return tree.build(txn, struct {
        fn f(w: *Window, p: t.Node, d: ?*const t.ImageViewDesc) Error!NodeId {
            const view = try imageViewOf(w.owner, d);
            const id = try tree.create(w, p, .image);
            w.txn.ut.setImage(id, view) catch |err| return tree.mapTxn(err);
            return id;
        }
    }.f, .{ parent, desc });
}

pub export fn siv_set_image_view(txn: t.Txn, node: t.Node, desc: ?*const t.ImageViewDesc) t.Result {
    return tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, d: ?*const t.ImageViewDesc) Error!void {
            const id = try tree.nodeIn(w, n);
            w.txn.ut.setImage(id, try imageViewOf(w.owner, d)) catch |err| return tree.mapTxn(err);
        }
    }.f, .{ node, desc });
}
