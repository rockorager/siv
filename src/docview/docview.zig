//! The document widget (D32): a canvas node that shows a `doc.Document`.
//! Parsing, styling, and layout run on the worker pool, one job at a
//! time; the first job lays out the first screen and later jobs the rest
//! in slices, so the first screen shows before a long document is laid
//! out. While a job has the document, the widget draws its last drawing
//! again. The application's resource loader decides what can be fetched;
//! the widget never fetches anything itself.
//!
//! Imports: ui, doc, css, text, scene, raster, loop.

const std = @import("std");
const ui = @import("ui");
const doc = @import("doc");
const css = @import("css");
const text = @import("text");
const scene = @import("scene");
const raster = @import("raster");
const loop = @import("loop");

const Document = doc.Document;
const NodeId = ui.NodeId;
const Window = ui.Window;
const Rect = raster.Rect;
const Allocator = std.mem.Allocator;
const none = std.math.maxInt(u32);

pub const Error = error{OutOfMemory};

pub const ColorScheme = enum(u8) {
    /// The window's theme: its light or dark variant and its colors.
    theme,
    light,
    dark,
};

pub const Options = struct {
    kind: Document.Kind = .html,
    base_url: []const u8 = "",
    /// A stylesheet the application adds after the user agent's.
    user_css: []const u8 = "",
    color_scheme: ColorScheme = .theme,
    /// Remote (http, https) images are asked for; otherwise they are
    /// blocked, counted in a `blocked_images` event, and loaded only after
    /// `loadImages`.
    remote_images: bool = false,
    author_styles: bool = true,
    /// CSS `medium`; 0 follows the window's text size.
    font_size: f32 = 0,
};

pub const ResourceKind = enum(u8) { stylesheet, image, font };

pub const Event = union(enum) {
    /// A link was clicked (not a fragment of this document, which
    /// scrolls): its URL, resolved.
    link: []const u8,
    /// Layout finished: the height is exact.
    loaded,
    /// The document's height changed.
    size: f32,
    /// Find found `count` matches (capped); `current` is 1-based, 0 when
    /// there are none.
    find: struct { count: u32, current: u32 },
    /// The selection changed.
    selection,
    /// Remote images were blocked by the policy.
    blocked_images: u32,
};

pub const Host = struct {
    ctx: ?*anyopaque = null,
    event: ?*const fn (ctx: ?*anyopaque, v: *View, event: Event) void = null,
    /// Asks for a resource: answer with `View.supply` or `View.fail`,
    /// now or later. Without it nothing is loaded.
    load: ?*const fn (ctx: ?*anyopaque, v: *View, request: u32, url: []const u8, kind: ResourceKind) void = null,
};

/// The user agent's stylesheet, parsed once per process.
var ua_once: std.atomic.Value(u8) = .init(0);
var ua_sheet: css.Sheet = undefined;
var ua_lock: std.atomic.Mutex = .unlocked;

fn userAgentSheet() Error!*const css.Sheet {
    if (ua_once.load(.acquire) == 2) return &ua_sheet;
    while (!ua_lock.tryLock()) std.atomic.spinLoopHint();
    defer ua_lock.unlock();
    if (ua_once.load(.acquire) != 2) {
        ua_sheet = try Document.parseUserAgentSheet(std.heap.page_allocator);
        ua_once.store(2, .release);
    }
    return &ua_sheet;
}

const Supply = struct { request: u32, bytes: ?[]u8 };

pub const View = struct {
    gpa: Allocator,
    win: *Window,
    node: NodeId,
    host: Host,
    options: Options,
    source: []u8,
    d: ?*Document = null,
    job: Job = .{},
    /// A job has the document.
    busy: bool = false,
    /// The node is gone: the view goes when its job is done.
    dead: bool = false,
    /// Work waiting for the document to be free.
    want_style: bool = false,
    want_fonts_loaded: bool = false,
    supplies: std.ArrayList(Supply) = .empty,
    /// Width layout runs at, and how far it has gone.
    width: f32 = 0,
    stop_y: f32 = 0,
    complete: bool = false,
    reported_height: f32 = -1,
    media_dark: bool = false,
    /// Decoded images by resource index, and loads in flight.
    images: std.ArrayList(?*ui.Image) = .empty,
    loads: std.ArrayList(*ImageLoad) = .empty,
    /// The last drawing, for frames while a job has the document, with
    /// the images it draws.
    last: scene.Builder,
    last_list: ?scene.DisplayList = null,
    last_images: std.ArrayList(*ui.Image) = .empty,
    drawn_band: [2]f32 = .{ 0, 0 },
    /// Find: the text, its matches, and the current one (index).
    find_text: std.ArrayList(u8) = .empty,
    matches: std.ArrayList(Document.Pos) = .empty,
    current: u32 = 0,
    /// Selection: anchor and focus, and whether a drag is selecting.
    anchor: ?Document.Pos = null,
    focus: ?Document.Pos = null,
    selecting: bool = false,
    press: ?[2]f32 = null,
    highlights: std.ArrayList(doc.paint.Highlight) = .empty,
    wanted: std.ArrayList(text.FontId) = .empty,
    listening: bool = false,

    /// Makes a canvas node, created in the open transaction `t`, show a
    /// document. The source is copied. The view lives as long as the
    /// node: call `destroy` when the node goes.
    pub fn create(gpa: Allocator, t: *ui.Txn, id: NodeId, source: []const u8, options: Options, host: Host) (Error || ui.TxnError)!*View {
        const v = try gpa.create(View);
        errdefer gpa.destroy(v);
        const win = t.win;
        v.* = .{ .gpa = gpa, .win = win, .node = id, .host = host, .options = options, .source = try gpa.dupe(u8, source), .last = .init(gpa) };
        errdefer gpa.free(v.source);
        const o = &v.options;
        o.base_url = try gpa.dupe(u8, options.base_url);
        o.user_css = try gpa.dupe(u8, options.user_css);
        try t.setCanvas(id, .{ .draw = draw, .measure = measure, .user = v, .banded = true, .semantics = semantics });
        try t.on(id, .pointer, .{ .func = onPointer, .user = v });
        try t.setSemantics(id, .{ .role = .document });
        try v.startParse();
        return v;
    }

    /// The node is gone. A job in flight finishes first.
    pub fn destroy(v: *View) void {
        v.dead = true;
        if (v.listening) v.win.fonts.removeListener(v);
        v.listening = false;
        for (v.loads.items) |l| l.cancel();
        v.loads.clearRetainingCapacity();
        if (v.busy) {
            if (v.win.fonts.pool) |pool| if (pool.cancel(&v.job.job)) {
                v.busy = false;
            };
        }
        if (!v.busy) v.free();
    }

    fn free(v: *View) void {
        const gpa = v.gpa;
        if (v.d) |d| d.destroy();
        if (v.job.result) |d| d.destroy();
        for (v.images.items) |img| if (img) |i| i.release();
        v.images.deinit(gpa);
        v.loads.deinit(gpa);
        for (v.supplies.items) |s| if (s.bytes) |b| gpa.free(b);
        v.supplies.deinit(gpa);
        v.dropLast();
        v.last_images.deinit(gpa);
        v.last.deinit();
        v.find_text.deinit(gpa);
        v.matches.deinit(gpa);
        v.highlights.deinit(gpa);
        v.wanted.deinit(gpa);
        gpa.free(v.options.base_url);
        gpa.free(v.options.user_css);
        gpa.free(v.source);
        gpa.destroy(v);
    }

    pub fn document(v: *View) ?*Document {
        return if (v.busy) null else v.d;
    }

    fn emit(v: *View, e: Event) void {
        if (v.dead) return;
        if (v.host.event) |f| f(v.host.ctx, v, e);
    }

    fn repaint(v: *View) void {
        if (v.dead or !v.win.isLive(v.node)) return;
        v.win.markPaint(v.node);
        v.win.requestFrame();
    }

    fn relayoutNode(v: *View) void {
        if (v.dead or !v.win.isLive(v.node)) return;
        v.win.markLayout(v.node);
        v.repaint();
    }

    // Jobs ----------------------------------------------------------------------

    fn media(v: *View) css.media.Env {
        const dark = switch (v.options.color_scheme) {
            .theme => v.win.palette.variant == .dark or v.win.palette.variant == .dark_high_contrast,
            .light => false,
            .dark => true,
        };
        const high = v.win.palette.variant == .light_high_contrast or v.win.palette.variant == .dark_high_contrast;
        return .{ .width = if (v.width > 0) v.width else v.win.width, .height = v.win.height, .dark = dark, .high_contrast = high, .reduced_motion = v.win.reducedMotion(), .resolution = v.win.scale, .font_size = v.fontSize() };
    }

    fn fontSize(v: *View) f32 {
        return if (v.options.font_size > 0) v.options.font_size else @max(12, v.win.palette.body_px * 16.0 / (11.0 * 4.0 / 3.0));
    }

    fn submit(v: *View, kind: Job.Kind, priority: i64) void {
        std.debug.assert(!v.busy);
        const pool = v.win.fonts.pool orelse {
            // Without a pool (tests without one): run here.
            v.job = .{ .view = v, .kind = kind, .media = v.media(), .width = v.width, .viewport_h = v.viewportHeight(), .stop_y = v.stop_y };
            v.busy = true;
            Job.run(&v.job.job);
            Job.done(&v.job.job);
            return;
        };
        v.job = .{ .view = v, .kind = kind, .media = v.media(), .width = v.width, .viewport_h = v.viewportHeight(), .stop_y = v.stop_y };
        v.job.job.priority = priority;
        v.busy = true;
        pool.submit(&v.job.job) catch {
            v.busy = false;
        };
    }

    fn startParse(v: *View) Error!void {
        _ = try userAgentSheet();
        v.media_dark = v.media().dark;
        v.submit(.parse, 1);
    }

    fn viewportHeight(v: *View) f32 {
        if (v.win.isLive(v.node)) if (ui.visibleBand(v.win, v.node)) |b| return @max(1, b[1] - b[0]);
        return @max(1, v.win.height);
    }

    /// What to do next once the document is free.
    fn schedule(v: *View) void {
        if (v.busy or v.dead) return;
        const d = v.d orelse return;
        v.applySupplies() catch {};
        if (v.want_fonts_loaded) {
            v.want_fonts_loaded = false;
            d.fontsLoaded();
            v.complete = false;
        }
        if (v.want_style) {
            v.want_style = false;
            v.media_dark = v.media().dark;
            v.complete = false;
            v.submit(.style, 1);
            return;
        }
        if (v.width <= 0) return;
        if (d.width != v.width) {
            v.complete = false;
            v.stop_y = v.firstStop();
            v.submit(.layout, 1);
            return;
        }
        if (!v.complete) {
            v.stop_y = if (v.stop_y <= 0) v.firstStop() else v.stop_y + slice_px;
            v.submit(.layout, -1);
        }
    }

    /// Starts styling or layout that a frame found wanting (a new width,
    /// a new color scheme), from layout or drawing, where the
    /// application's callbacks must not run: the rest waits for
    /// `schedule`.
    fn kick(v: *View) void {
        if (v.busy or v.dead) return;
        const d = v.d orelse return;
        if (v.want_style) {
            v.want_style = false;
            v.media_dark = v.media().dark;
            v.complete = false;
            v.submit(.style, 1);
        } else if (v.width > 0 and d.width != v.width) {
            v.complete = false;
            v.stop_y = v.firstStop();
            v.submit(.layout, 1);
        }
    }

    fn firstStop(v: *View) f32 {
        var stop = 2 * v.viewportHeight();
        if (v.win.isLive(v.node)) if (ui.visibleBand(v.win, v.node)) |b| {
            stop = @max(stop, b[1] + (b[1] - b[0]));
        };
        return stop;
    }

    /// Document pixels a background layout job adds: a few milliseconds.
    const slice_px = 20000;

    fn jobDone(v: *View) void {
        v.busy = false;
        if (v.dead) return v.free();
        const j = &v.job;
        switch (j.kind) {
            .parse => {
                v.d = j.result;
                j.result = null;
                const d = v.d orelse return;
                if (d.blocked_images > 0) v.emit(.{ .blocked_images = d.blocked_images });
                v.requestResources();
                v.afterStyle();
            },
            .style => {
                v.requestResources();
                v.afterStyle();
            },
            .layout => {
                v.complete = j.complete;
                const d = v.d.?;
                const h = d.height();
                if (h != v.reported_height) {
                    v.reported_height = h;
                    v.relayoutNode();
                    v.emit(.{ .size = h });
                }
                v.repaint();
                v.wanted.clearRetainingCapacity();
                d.wantedFonts(&v.wanted) catch {};
                if (v.wanted.items.len > 0) {
                    if (!v.listening) {
                        v.win.fonts.addListener(.{ .ctx = v, .func = onFontLoaded }) catch {};
                        v.listening = true;
                    }
                    v.win.fonts.request(v.wanted.items);
                }
                if (v.complete) {
                    v.refreshFind();
                    v.emit(.loaded);
                }
            },
        }
        v.schedule();
    }

    fn afterStyle(v: *View) void {
        const d = v.d orelse return;
        d.resolveFonts(.{ .ctx = v, .cache = &v.win.fonts.cache, .chainFn = chainFn }) catch {};
        v.complete = false;
        v.stop_y = 0;
        // The cascade made new boxes: positions found before are stale.
        v.matches.clearRetainingCapacity();
        v.anchor = null;
        v.focus = null;
        if (v.width <= 0) v.relayoutNode();
    }

    fn chainFn(ctx: *anyopaque, family: []const u8, language: []const u8, weight: u16, italic: bool, stretch: f32, size: f32) Document.Error![]const text.FontId {
        const v: *View = @ptrCast(@alignCast(ctx));
        const f = v.win.fonts;
        return f.chain(.{
            .family = try f.intern(family),
            .language = try f.intern(language),
            .weight = weight,
            .slant = if (italic) .italic else .roman,
            .width = if (stretch < 87.5) .condensed else if (stretch > 112.5) .expanded else .normal,
            .size = size,
        });
    }

    fn onFontLoaded(ctx: *anyopaque) void {
        const v: *View = @ptrCast(@alignCast(ctx));
        if (v.dead) return;
        // Only fonts the document wanted matter.
        for (v.wanted.items) |id| if (v.win.fonts.cache.state(id) != .pending) {
            v.want_fonts_loaded = true;
            break;
        };
        if (v.want_fonts_loaded) v.schedule();
    }

    // Resources -----------------------------------------------------------------

    fn requestResources(v: *View) void {
        const d = v.d orelse return;
        const load = v.host.load orelse return;
        var i: u32 = 0;
        while (i < d.resources.items.len) : (i += 1) {
            const r = &d.resources.items[i];
            if (r.state != .wanted) continue;
            r.state = .loading;
            load(v.host.ctx, v, i, r.url, switch (r.kind) {
                .stylesheet => .stylesheet,
                .image => .image,
                .font => .font,
            });
            // The callback may have supplied it already.
            if (v.dead) return;
        }
    }

    /// A resource's bytes (copied); null fails it.
    pub fn supply(v: *View, request: u32, bytes: ?[]const u8) Error!void {
        const copy = if (bytes) |b| try v.gpa.dupe(u8, b) else null;
        errdefer if (copy) |c| v.gpa.free(c);
        try v.supplies.append(v.gpa, .{ .request = request, .bytes = copy });
        if (!v.busy) {
            try v.applySupplies();
            v.schedule();
        }
    }

    fn applySupplies(v: *View) Error!void {
        const d = v.d orelse return;
        var restyle = false;
        var relayout = false;
        defer v.supplies.clearRetainingCapacity();
        for (v.supplies.items) |s| {
            defer if (s.bytes) |b| v.gpa.free(b);
            if (s.request & image_ready != 0) {
                // An image decoded while a job had the document.
                const i = s.request & ~image_ready;
                const img = v.imageOf(i) orelse continue;
                const w, const h = img.logicalSize();
                d.supplyImage(i, w, h, i);
                relayout = true;
                continue;
            }
            if (s.request >= d.resources.items.len) continue;
            const r = &d.resources.items[s.request];
            const bytes = s.bytes orelse {
                d.failResource(s.request);
                continue;
            };
            switch (r.kind) {
                .stylesheet => {
                    try d.supplyStylesheet(s.request, bytes);
                    restyle = true;
                },
                .font => {
                    try d.supplyFont(s.request, &v.win.fonts.cache, bytes);
                    restyle = true;
                },
                .image => {
                    if (looksLikeSvg(bytes)) {
                        try d.supplySvg(s.request, bytes);
                        relayout = true;
                        continue;
                    }
                    const pool = v.win.fonts.pool orelse {
                        d.failResource(s.request);
                        continue;
                    };
                    const l = try v.gpa.create(ImageLoad);
                    l.* = .{ .view = v, .request = s.request };
                    try v.loads.append(v.gpa, l);
                    l.loading = ui.Image.load(pool, v.gpa, .{ .bytes = bytes }, .{ .scale = v.win.scale }, .{ .ctx = l, .func = ImageLoad.done, .destroy = ImageLoad.drop }) catch {
                        _ = v.loads.pop();
                        v.gpa.destroy(l);
                        d.failResource(s.request);
                        continue;
                    };
                },
            }
        }
        if (restyle) {
            // Stylesheets may import more.
            v.requestResources();
            v.want_style = true;
        } else if (relayout) {
            v.complete = false;
            v.stop_y = 0;
        }
    }

    fn looksLikeSvg(b: []const u8) bool {
        const head = std.mem.trimStart(u8, b[0..@min(b.len, 512)], " \t\r\n\xef\xbb\xbf");
        return std.mem.startsWith(u8, head, "<") and std.mem.indexOf(u8, b[0..@min(b.len, 4096)], "<svg") != null;
    }

    const ImageLoad = struct {
        view: *View,
        request: u32,
        loading: ?*ui.Image.Loading = null,

        fn cancel(l: *ImageLoad) void {
            if (l.loading) |x| x.cancel();
        }

        fn done(ctx: ?*anyopaque, result: ui.Image.LoadError!*ui.Image) void {
            const l: *ImageLoad = @ptrCast(@alignCast(ctx));
            const v = l.view;
            const img = result catch {
                if (v.d) |d| if (!v.busy) d.failResource(l.request);
                return;
            };
            if (v.dead) {
                img.release();
                return;
            }
            while (v.images.items.len <= l.request) v.images.append(v.gpa, null) catch {
                img.release();
                return;
            };
            if (v.images.items[l.request]) |old| old.release();
            v.images.items[l.request] = img;
            const w, const h = img.logicalSize();
            if (v.busy) {
                // Sizes apply once the document is free.
                v.supplies.append(v.gpa, .{ .request = l.request | image_ready, .bytes = null }) catch {};
                return;
            }
            v.imageReady(l.request, w, h);
        }

        fn drop(ctx: ?*anyopaque) void {
            const l: *ImageLoad = @ptrCast(@alignCast(ctx));
            const v = l.view;
            for (v.loads.items, 0..) |x, i| if (x == l) {
                _ = v.loads.swapRemove(i);
                break;
            };
            v.gpa.destroy(l);
        }
    };

    const image_ready: u32 = 1 << 31;

    fn imageReady(v: *View, request: u32, w: f32, h: f32) void {
        const d = v.d orelse return;
        d.supplyImage(request, w, h, request);
        v.complete = false;
        v.stop_y = 0;
        v.schedule();
    }

    /// Lets remote images load after a `blocked_images` event: the
    /// document is styled again with them allowed.
    pub fn loadImages(v: *View) void {
        if (v.options.remote_images) return;
        v.options.remote_images = true;
        if (v.d) |d| d.options.remote_images = true;
        v.want_style = true;
        v.schedule();
    }

    // Layout and drawing --------------------------------------------------------

    fn measure(user: ?*anyopaque, win: *Window, node: NodeId, min_w: f32, max_w: f32, min_h: f32, max_h: f32) ui.CanvasSize {
        _ = win;
        _ = node;
        _ = min_h;
        _ = max_h;
        const v: *View = @ptrCast(@alignCast(user));
        if (!std.math.isFinite(max_w)) return .{ .width = @max(min_w, 600), .height = if (v.reported_height > 0) v.reported_height else 0 };
        if (max_w != v.width) {
            v.width = max_w;
            v.kick();
        }
        return .{ .width = max_w, .height = @max(0, v.reported_height) };
    }

    fn palette(v: *View) doc.Palette {
        var p: doc.Palette = .{};
        const dark = v.media_dark;
        if (v.options.color_scheme == .theme) {
            const tp = &v.win.palette;
            p.canvas = color(tp.color(.view_bg));
            p.canvas_text = color(tp.color(.view_fg));
            p.accent = color(tp.color(.accent));
            p.accent_text = color(tp.color(.accent_fg));
            p.highlight = color(tp.color(.selection_bg));
            p.highlight_text = color(tp.color(.selection_fg));
            p.field = color(tp.color(.control_bg));
            p.field_text = color(tp.color(.control_fg));
            p.button_face = color(tp.color(.control_bg));
            p.button_text = color(tp.color(.control_fg));
            p.button_border = color(tp.color(.border));
            p.gray = color(tp.color(.muted_fg));
            var sel = color(tp.color(.selection_bg));
            sel.a = 0.45;
            p.selection = sel;
        } else if (dark) {
            p.canvas = .rgb8(0x1e, 0x1e, 0x1e);
            p.canvas_text = .rgb8(0xe8, 0xe8, 0xe8);
        }
        if (dark) {
            p.link = .rgb8(0x78, 0xae, 0xed);
            p.visited = .rgb8(0xc0, 0x97, 0xf0);
        }
        return p;
    }

    fn color(c: scene.Color) css.Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }

    fn dropLast(v: *View) void {
        for (v.last_images.items) |img| img.release();
        v.last_images.clearRetainingCapacity();
        v.last_list = null;
    }

    fn draw(user: ?*anyopaque, win: *Window, node: NodeId, b: *scene.Builder, width: f32, height: f32) scene.Error!void {
        const v: *View = @ptrCast(@alignCast(user));
        const band = win.state(node).painted_band orelse [2]f32{ 0, height };
        _ = width;
        // The theme's scheme changed: style again for prefers-color-scheme.
        if (v.options.color_scheme == .theme and v.media().dark != v.media_dark and v.d != null) {
            v.want_style = true;
            v.kick();
        }
        const d = v.d orelse return;
        if (v.busy) return v.replayLast(b);
        if (!v.complete and band[1] > v.stop_y) {
            // Scrolled past what is laid out: lay out to there first.
            v.stop_y = band[1] + (band[1] - band[0]);
            v.submit(.layout, 1);
            if (v.busy) return v.replayLast(b);
        }
        v.dropLast();
        v.last.reset();
        try v.buildHighlights();
        const hooks: doc.Hooks = .{ .ctx = v, .drawReplaced = drawReplaced, .imageSize = imageSize, .drawImage = drawImage, .marker = marker };
        d.paint(&v.last, band[0], band[1], v.palette(), hooks, v.highlights.items) catch return error.OutOfMemory;
        v.last_list = try v.last.finish(0);
        v.drawn_band = band;
        try v.replayLast(b);
    }

    fn replayLast(v: *View, b: *scene.Builder) scene.Error!void {
        const list = v.last_list orelse return;
        for (v.last_images.items) |img| try v.win.holdImage(b, img);
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

    fn holdImage(v: *View, img: *ui.Image) scene.Error!void {
        for (v.last_images.items) |x| if (x == img) return;
        try v.last_images.append(v.gpa, img.retain());
    }

    fn drawReplaced(ctx: *anyopaque, b: *scene.Builder, resource: u32, dst: Rect, opacity: f32) scene.Error!bool {
        _ = opacity;
        const v: *View = @ptrCast(@alignCast(ctx));
        const d = v.d orelse return false;
        if (resource >= d.resources.items.len) return false;
        const r = d.resources.items[resource];
        if (r.state != .ready) return false;
        if (r.svg_doc) |sd| {
            try sd.draw(b, dst, null);
            return true;
        }
        const img = v.imageOf(resource) orelse return false;
        try v.holdImage(img);
        try b.image(.{ .image = img.sceneRef(), .src = .xywh(0, 0, @floatFromInt(img.width), @floatFromInt(img.height)), .dst = dst, .filter = .linear });
        return true;
    }

    fn imageOf(v: *View, resource: u32) ?*ui.Image {
        return if (resource < v.images.items.len) v.images.items[resource] else null;
    }

    fn resourceByUrl(v: *View, url: []const u8) ?u32 {
        const d = v.d orelse return null;
        for (d.resources.items, 0..) |r, i| if (r.kind == .image and std.mem.eql(u8, r.url, url)) return @intCast(i);
        return null;
    }

    fn imageSize(ctx: *anyopaque, url: []const u8) ?[2]f32 {
        const v: *View = @ptrCast(@alignCast(ctx));
        const i = v.resourceByUrl(url) orelse return null;
        const r = v.d.?.resources.items[i];
        if (r.state != .ready) return null;
        return .{ r.width, r.height };
    }

    fn drawImage(ctx: *anyopaque, b: *scene.Builder, url: []const u8, dst: Rect, clip: Rect) scene.Error!void {
        const v: *View = @ptrCast(@alignCast(ctx));
        const i = v.resourceByUrl(url) orelse return;
        try b.pushLayer(.{ .clip = .{ .shape = .{ .rect = clip } } });
        defer b.popLayer() catch {};
        _ = try drawReplaced(ctx, b, i, dst, 1);
    }

    fn marker(ctx: *anyopaque, index: u32) ?*const doc.paint.MarkerGlyphs {
        const v: *View = @ptrCast(@alignCast(ctx));
        return v.d.?.markerGlyphs(index);
    }

    fn buildHighlights(v: *View) Error!void {
        v.highlights.clearRetainingCapacity();
        const d = v.d orelse return;
        const p = v.palette();
        for (v.matches.items, 0..) |m, i| try v.highlights.append(v.gpa, .{
            .ifc = m.ifc,
            .start = m.offset,
            .end = m.offset + @as(u32, @intCast(v.find_text.items.len)),
            .color = if (i == v.current) p.find_current else p.find,
        });
        if (v.anchor) |a| if (v.focus) |f| try d.rangeHighlights(a, f, p.selection, &v.highlights, v.gpa);
    }

    // Input ---------------------------------------------------------------------

    fn onPointer(user: ?*anyopaque, win: *Window, node: NodeId, event: *const ui.Event) ui.HandlerResult {
        _ = win;
        _ = node;
        const v: *View = @ptrCast(@alignCast(user));
        const p = event.pointer;
        const d = v.document() orelse return .pass;
        switch (p.phase) {
            .down => {
                if (p.button != .primary) return .pass;
                const hit = d.hitTest(p.x, p.y) catch return .pass;
                v.press = .{ p.x, p.y };
                if (hit.ifc != none) {
                    const pos: Document.Pos = .{ .ifc = hit.ifc, .offset = hit.offset };
                    if (p.mods.shift and v.anchor != null) {
                        v.focus = pos;
                    } else {
                        v.anchor = pos;
                        v.focus = pos;
                    }
                    if (p.clicks >= 2) v.selectWord(pos, p.clicks >= 3);
                    v.selecting = true;
                    v.repaint();
                } else if (v.anchor != null) {
                    v.anchor = null;
                    v.focus = null;
                    v.repaint();
                    v.emit(.selection);
                }
                return .handled;
            },
            .move => {
                if (!v.selecting) return .pass;
                const hit = d.hitTest(p.x, p.y) catch return .pass;
                if (hit.ifc != none) {
                    v.focus = .{ .ifc = hit.ifc, .offset = hit.offset };
                    v.repaint();
                }
                return .handled;
            },
            .up => {
                if (!v.selecting and v.press == null) return .pass;
                v.selecting = false;
                const press = v.press orelse return .handled;
                v.press = null;
                const moved = @abs(press[0] - p.x) + @abs(press[1] - p.y) > 4;
                if (!moved and p.clicks == 1) {
                    // A click: no selection, and a link opens.
                    v.anchor = null;
                    v.focus = null;
                    v.repaint();
                    const hit = d.hitTest(p.x, p.y) catch return .handled;
                    if (d.linkAt(hit.node)) |link| v.activate(link.href);
                    return .handled;
                }
                v.emit(.selection);
                return .handled;
            },
            else => return .pass,
        }
    }

    fn selectWord(v: *View, pos: Document.Pos, paragraph: bool) void {
        const d = v.d orelse return;
        const t = d.tree.ifcs.items[pos.ifc].text;
        var s: u32 = pos.offset;
        var e: u32 = pos.offset;
        if (paragraph) {
            s = 0;
            e = @intCast(t.len);
        } else {
            while (s > 0 and isWord(t[s - 1])) s -= 1;
            while (e < t.len and isWord(t[e])) e += 1;
        }
        v.anchor = .{ .ifc = pos.ifc, .offset = s };
        v.focus = .{ .ifc = pos.ifc, .offset = e };
    }

    fn isWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c >= 0x80 or c == '_' or c == '\'';
    }

    /// Follows a link: a fragment of this document scrolls to its target;
    /// anything else goes to the application.
    pub fn activate(v: *View, href: []const u8) void {
        const d = v.d orelse return;
        if (std.mem.indexOfScalar(u8, href, '#')) |hash| {
            const base = d.base_url;
            const base_end = std.mem.indexOfScalar(u8, base, '#') orelse base.len;
            if (std.mem.eql(u8, href[0..hash], base[0..base_end])) {
                if (v.scrollToFragment(href[hash + 1 ..])) return;
            }
        }
        v.emit(.{ .link = href });
    }

    /// Scrolls the element with this id (or name) into view; false when
    /// there is none.
    pub fn scrollToFragment(v: *View, fragment: []const u8) bool {
        const d = v.document() orelse return false;
        const el = d.elementById(fragment);
        if (el == .none) return false;
        const y = d.elementY(el) orelse return false;
        v.reveal(y, 0, true);
        return true;
    }

    /// Scrolls the nearest scroll node so that document y..y+h shows,
    /// at the top when `top`.
    pub fn reveal(v: *View, y: f32, h: f32, top: bool) void {
        const win = v.win;
        if (!win.isLive(v.node)) return;
        const band = ui.visibleBand(win, v.node) orelse return;
        var sc = win.node(v.node).parent;
        while (sc != .none and win.node(sc).kind != .scroll) sc = win.node(sc).parent;
        if (sc == .none) return;
        const view_h = band[1] - band[0];
        var dy: f32 = 0;
        if (top or y < band[0] or y + h > band[1]) {
            dy = if (top) y - band[0] else y - band[0] - view_h / 3;
        }
        if (dy == 0) return;
        ui.input.scrollBy(win, sc, .{ .x = 0, .y = dy * win.scale });
    }

    // Find and selection --------------------------------------------------------

    /// Finds text (ignoring ASCII case): a new text finds its first match
    /// at or after what shows; the same text again moves to the next
    /// match (the previous when `backwards`). Empty clears.
    pub fn find(v: *View, needle: []const u8, backwards: bool) Error!void {
        const same = std.mem.eql(u8, needle, v.find_text.items);
        if (!same) {
            v.find_text.clearRetainingCapacity();
            try v.find_text.appendSlice(v.gpa, needle);
            v.matches.clearRetainingCapacity();
            v.current = 0;
        }
        const d = v.document() orelse return;
        if (!same or v.matches.items.len == 0) {
            try d.findAll(needle, &v.matches, v.gpa, max_matches);
            // The first at or after the view's top.
            const top = if (ui.visibleBand(v.win, v.node)) |b| b[0] else 0;
            for (v.matches.items, 0..) |m, i| {
                const r = (d.offsetRect(m) catch null) orelse continue;
                if (r[1] >= top) {
                    v.current = @intCast(i);
                    break;
                }
            }
        } else if (v.matches.items.len > 0) {
            const n: u32 = @intCast(v.matches.items.len);
            v.current = if (backwards) (v.current + n - 1) % n else (v.current + 1) % n;
        }
        v.showCurrent();
    }

    const max_matches = 10000;

    fn refreshFind(v: *View) void {
        if (v.find_text.items.len == 0) return;
        const d = v.d orelse return;
        v.matches.clearRetainingCapacity();
        d.findAll(v.find_text.items, &v.matches, v.gpa, max_matches) catch {};
        if (v.current >= v.matches.items.len) v.current = 0;
        v.repaint();
        v.emit(.{ .find = .{ .count = @intCast(v.matches.items.len), .current = if (v.matches.items.len > 0) v.current + 1 else 0 } });
    }

    fn showCurrent(v: *View) void {
        v.repaint();
        const count: u32 = @intCast(v.matches.items.len);
        if (count > 0) if (v.d) |d| if ((d.offsetRect(v.matches.items[v.current]) catch null)) |r| v.reveal(r[1], r[3], false);
        v.emit(.{ .find = .{ .count = count, .current = if (count > 0) v.current + 1 else 0 } });
    }

    /// The selected text (allocated with `gpa`), empty without one.
    pub fn selectedText(v: *View, gpa: Allocator) Error![]u8 {
        const d = v.document() orelse return gpa.alloc(u8, 0);
        const a = v.anchor orelse return gpa.alloc(u8, 0);
        const f = v.focus orelse return gpa.alloc(u8, 0);
        return d.textBetween(gpa, a, f);
    }

    pub fn selectAll(v: *View) void {
        const d = v.document() orelse return;
        const n = d.tree.ifcs.items.len;
        if (n == 0) return;
        v.anchor = .{ .ifc = 0, .offset = 0 };
        v.focus = .{ .ifc = @intCast(n - 1), .offset = @intCast(d.tree.ifcs.items[n - 1].text.len) };
        v.repaint();
        v.emit(.selection);
    }

    // Reading position ----------------------------------------------------------

    /// A locator for what is at document y: the path of element indices
    /// from the body to the innermost block there, stable across widths,
    /// themes, and fonts (D32). Written into `out`.
    pub fn locatorAt(v: *View, y: f32, out: *std.ArrayList(u8)) Error!void {
        const d = v.document() orelse return;
        var path: std.ArrayList(u32) = .empty;
        defer path.deinit(v.gpa);
        try d.locatorPath(y, &path, v.gpa);
        out.clearRetainingCapacity();
        for (path.items) |i| try out.print(v.gpa, "/{d}", .{i});
        if (out.items.len == 0) try out.append(v.gpa, '/');
    }
    /// The document y of a locator's element, or null.
    pub fn locatorY(v: *View, locator: []const u8) ?f32 {
        const d = v.document() orelse return null;
        var cur = d.dom.body();
        var it = std.mem.tokenizeScalar(u8, locator, '/');
        while (it.next()) |part| {
            const want = std.fmt.parseInt(u32, part, 10) catch return null;
            var i: u32 = 0;
            var c = d.dom.node(cur).first;
            while (c != .none) : (c = d.dom.node(c).next) {
                if (d.dom.node(c).kind != .element) continue;
                if (i == want) break;
                i += 1;
            }
            if (c == .none) break;
            cur = c;
        }
        // The nearest element with a box.
        while (cur != .none) : (cur = d.dom.node(cur).parent) if (d.elementY(cur)) |y| return y;
        return null;
    }

    // Accessibility -------------------------------------------------------------

    fn semantics(user: ?*anyopaque, win: *Window, node: NodeId, out: *ui.semantics.Virtual) Error!void {
        _ = win;
        _ = node;
        const v: *View = @ptrCast(@alignCast(user));
        const d = v.document() orelse return;
        var list: std.ArrayList(Document.AccessNode) = .empty;
        defer list.deinit(v.gpa);
        try d.accessibility(out.arena, &list);
        for (list.items) |n| try out.nodes.append(out.gpa, .{
            .role = switch (n.role) {
                .heading => .heading,
                .link => .link,
                .list => .list,
                .list_item => .list_item,
                .table => .table,
                .row => .row,
                .cell => .cell,
                .column_header => .column_header,
                .image => .image,
                .paragraph => .paragraph,
                .group => .group,
            },
            .name = n.name,
            .parent = n.parent,
            .end = n.end,
            .bounds = .xywh(n.bounds[0], n.bounds[1], n.bounds[2], n.bounds[3]),
            .level = n.level,
            .position = n.position,
            .set_size = n.set_size,
        });
    }
};

pub const Job = struct {
    job: loop.Pool.Job = .{ .run = run, .done = done, .cancel = cancelled },
    view: *View = undefined,
    kind: Kind = .parse,
    media: css.media.Env = .{},
    width: f32 = 0,
    viewport_h: f32 = 0,
    stop_y: f32 = 0,
    complete: bool = false,
    result: ?*Document = null,

    pub const Kind = enum { parse, style, layout };

    fn run(job: *loop.Pool.Job) void {
        const j: *Job = @fieldParentPtr("job", job);
        const v = j.view;
        if (v.dead) return;
        j.work() catch {};
    }

    fn work(j: *Job) Error!void {
        const v = j.view;
        switch (j.kind) {
            .parse => {
                const o = v.options;
                const d = try Document.create(v.gpa, v.source, .{
                    .kind = o.kind,
                    .base_url = o.base_url,
                    .user_css = o.user_css,
                    .font_size = j.media.font_size,
                    .remote_images = o.remote_images,
                    .author_styles = o.author_styles,
                }, try userAgentSheet());
                errdefer d.destroy();
                try d.styleAndBuild(j.media);
                j.result = d;
            },
            .style => try v.d.?.styleAndBuild(j.media),
            .layout => {
                const cache = &v.win.fonts.cache;
                cache.lockShared();
                defer cache.unlockShared();
                j.complete = try v.d.?.layout(cache, j.width, j.viewport_h, j.stop_y);
            },
        }
    }

    fn done(job: *loop.Pool.Job) void {
        const j: *Job = @fieldParentPtr("job", job);
        j.view.jobDone();
    }

    fn cancelled(job: *loop.Pool.Job) void {
        const j: *Job = @fieldParentPtr("job", job);
        const v = j.view;
        v.busy = false;
        if (v.dead) v.free();
    }
};

test {
    std.testing.refAllDecls(@This());
}
