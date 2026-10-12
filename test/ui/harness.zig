//! A headless application for UI tests (D24): the real loop, worker pool,
//! and headless platform; a ui.Window; and ui.TestCompositor standing in
//! for the compositor thread, flattened into the CPU renderer with
//! per-layer damage and presented with buffer-age damage.
//!
//! Like the compositor (D8), the harness scrolls scroll containers that
//! take input itself and reports `scrolled`; other scroll input and all
//! other platform events go to the window.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const text = @import("text");
const loop_mod = @import("loop");
const platform = @import("platform");
const render_cpu = @import("render_cpu");
const ui = @import("ui");

const Loop = loop_mod.Loop;
const IRect = raster.IRect;

pub const App = struct {
    gpa: std.mem.Allocator,
    loop: Loop,
    pool: loop_mod.Pool,
    fonts: ui.Fonts,
    tc: ui.TestCompositor,
    hl: *platform.Headless,
    win: *ui.Window,
    wid: platform.WindowId = 0,
    renderer: *render_cpu.Renderer,
    tracker: scene.damage.Tracker,
    prev: ?scene.DisplayList = null,
    /// Damage of the previous present, re-encoded into the next buffer
    /// (the headless backend alternates two buffers).
    prev_damage: std.ArrayList(IRect) = .empty,
    /// Device damage of the last present.
    damage: std.ArrayList(IRect) = .empty,
    presents: usize = 0,
    pointer: raster.Point = .zero,
    mods: platform.Mods = .{},
    configure_serial: u64 = 0,
    err: ?anyerror = null,

    pub const Options = struct {
        width: u32 = 320,
        height: u32 = 240,
        scale: u32 = 1,
        rtl: bool = false,
    };

    /// `app` must not move afterwards.
    pub fn init(app: *App, gpa: std.mem.Allocator, options: Options) !void {
        app.gpa = gpa;
        app.loop = try Loop.init(std.heap.smp_allocator);
        errdefer app.loop.deinit();
        app.pool = .init(&app.loop, gpa, 3);
        errdefer app.pool.deinit();
        app.fonts = try .init(gpa);
        errdefer app.fonts.deinit();
        app.fonts.pool = &app.pool;
        const tf = text.font.test_fonts;
        const chain = [_]text.FontId{
            try app.fonts.cache.add(tf.latin, 0, .borrowed),
            try app.fonts.cache.add(tf.arabic, 0, .borrowed),
            try app.fonts.cache.add(tf.hebrew, 0, .borrowed),
        };
        try app.fonts.register("Droid", &chain);
        try app.fonts.setDefault("Droid");
        app.tc = .init(gpa);
        errdefer app.tc.deinit();
        app.renderer = try render_cpu.Renderer.create(gpa, app.pool.executor());
        errdefer app.renderer.destroy();
        app.tracker = .init(gpa);
        errdefer app.tracker.deinit();
        app.prev = null;
        app.prev_damage = .empty;
        app.damage = .empty;
        app.presents = 0;
        app.pointer = .zero;
        app.mods = .{};
        app.configure_serial = 0;
        app.err = null;
        app.wid = 0;
        app.win = try ui.Window.init(gpa, .{
            .fonts = &app.fonts,
            .sink = app.tc.sink(),
            .host = .{ .ctx = app, .request_frame = requestFrame },
            .width = @floatFromInt(options.width),
            .height = @floatFromInt(options.height),
            .scale = @floatFromInt(options.scale),
            .rtl = options.rtl,
        });
        errdefer app.win.deinit();
        var output: platform.OutputInfo = .{ .width = 1920, .height = 1080, .refresh_mhz = 60000, .scale = @intCast(options.scale) };
        output.name.set("HEADLESS-1");
        app.hl = try platform.Headless.create(&app.loop, gpa, .{ .ctx = app, .func = onEvent }, .{
            .refresh_ns = std.time.ns_per_ms,
            .output = output,
        });
        app.wid = try app.hl.createWindow(.{ .width = options.width, .height = options.height });
    }

    pub fn deinit(app: *App) void {
        app.hl.destroy();
        app.pool.deinit();
        app.win.deinit();
        app.tc.deinit();
        app.fonts.deinit();
        app.tracker.deinit();
        app.renderer.destroy();
        app.prev_damage.deinit(app.gpa);
        app.damage.deinit(app.gpa);
        app.loop.deinit();
    }

    fn requestFrame(ctx: ?*anyopaque) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        app.hl.requestFrame(app.wid);
    }

    fn onEvent(ctx: ?*anyopaque, ev: *const platform.Event) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .frame => app.present() catch |e| {
                app.err = e;
            },
            .configure => |c| {
                // The compositor numbers configures for acknowledgement.
                app.configure_serial += 1;
                app.win.handleEvent(&.{ .configure = .{ .window = c.window, .state = c.state, .serial = app.configure_serial } }) catch |e| {
                    app.err = e;
                };
            },
            .modifiers => |m| {
                app.mods = m.mods;
                app.win.handlePlatform(ev);
            },
            .pointer_enter, .pointer_motion => |m| {
                app.pointer = .{ .x = @floatCast(m.x), .y = @floatCast(m.y) };
                app.win.handlePlatform(ev);
            },
            .scroll => |s| {
                const step: f32 = ui.input.line_step / 120;
                const delta: raster.Point = .{
                    .x = if (s.dx != 0) @floatCast(s.dx) else @as(f32, @floatFromInt(s.v120_x)) * step,
                    .y = if (s.dy != 0) @floatCast(s.dy) else @as(f32, @floatFromInt(s.v120_y)) * step,
                };
                if (app.tc.route(app.pointer, delta, app.mods) == .scroll) {
                    const layer = app.tc.route(app.pointer, delta, app.mods).scroll;
                    const offset = app.tc.scrollBy(layer, delta);
                    app.win.handleEvent(&.{ .scrolled = .{ .window = app.wid, .layer = layer, .offset = offset, .seq = app.tc.seq } }) catch |e| {
                        app.err = e;
                    };
                    app.hl.requestFrame(app.wid);
                } else app.win.handlePlatform(ev);
            },
            else => if (ev.window() == app.wid) app.win.handlePlatform(ev),
        }
    }

    fn present(app: *App) !void {
        try app.win.frame();
        const list = try app.tc.flatten();
        for (app.tc.released.items) |b| try app.win.handleEvent(&.{ .released = b });
        app.tc.released.clearRetainingCapacity();
        for (app.tc.reports.items) |r| try app.win.handleEvent(&.{ .scrolled = .{ .window = app.wid, .layer = r.layer, .offset = r.offset, .seq = r.seq } });
        app.tc.reports.clearRetainingCapacity();
        const buf = try app.hl.acquireBuffer(app.wid);
        try app.renderer.resize(buf.width, buf.height);
        const s = app.win.scale;
        const root = raster.Affine.scale(s, s);
        const rects = try app.tracker.diff(app.prev, list, root, app.renderer.viewport());
        app.damage.clearRetainingCapacity();
        try app.damage.appendSlice(app.gpa, rects);
        try app.renderer.render(list, .{
            .root = root,
            .damage = app.damage.items,
            .background = .white,
            .target = .{ .pixels = buf.pixels.ptr, .stride = buf.stride, .format = .argb8888 },
            .encode = app.prev_damage.items,
        });
        var prects: std.ArrayList(platform.Rect) = .empty;
        defer prects.deinit(app.gpa);
        for (app.damage.items) |r| try prects.append(app.gpa, .{ .x = r.x0, .y = r.y0, .width = r.width(), .height = r.height() });
        app.hl.present(app.wid, buf, if (prects.items.len == 0) &.{} else prects.items);
        app.prev = list;
        app.prev_damage.clearRetainingCapacity();
        try app.prev_damage.appendSlice(app.gpa, app.damage.items);
        app.presents += 1;
    }

    /// Runs the loop until nothing is pending: frames presented, fonts
    /// loaded.
    pub fn settle(app: *App) !void {
        var idle: usize = 0;
        var guard: usize = 0;
        while (idle < 3) : (guard += 1) {
            if (guard > 2000) return error.Timeout;
            const before = app.presents;
            try app.loop.dispatch(2);
            if (app.err) |e| return e;
            const busy = app.presents != before or app.win.needsFrame() or app.fonts.loading() or app.win.txn.open;
            idle = if (busy) 0 else idle + 1;
        }
    }

    /// Injects a platform event as the compositor would forward it.
    pub fn inject(app: *App, ev: platform.Event) void {
        app.hl.inject(ev);
    }

    pub fn click(app: *App, x: f64, y: f64) void {
        app.inject(.{ .pointer_motion = .{ .window = app.wid, .seat = 0, .x = x, .y = y } });
        app.inject(.{ .pointer_button = .{ .window = app.wid, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 1 } });
        app.inject(.{ .pointer_button = .{ .window = app.wid, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 2 } });
    }

    pub fn key(app: *App, keysym: u32, mods: platform.Mods) void {
        const k: platform.Key = .{ .window = app.wid, .seat = 0, .keycode = 0, .keysym = keysym, .state = .pressed, .mods = mods, .time = 0, .serial = 3 };
        app.inject(.{ .key = k });
        var up = k;
        up.state = .released;
        app.inject(.{ .key = up });
    }

    /// The presented frame as RGBA bytes (caller frees).
    pub fn snapshot(app: *App) ![]u8 {
        const img = app.hl.presented(app.wid) orelse return error.NothingPresented;
        const out = try app.gpa.alloc(u8, @as(usize, img.width) * img.height * 4);
        for (0..img.height) |y| for (0..img.width) |x| {
            const p = img.pixels[y * img.stride + x * 4 ..][0..4];
            out[(y * img.width + x) * 4 ..][0..4].* = .{ p[2], p[1], p[0], p[3] };
        };
        return out;
    }

    /// Renders the current layer tree from scratch, for comparing with the
    /// incrementally damaged frame. RGBA bytes; caller frees.
    pub fn fullRender(app: *App) ![]u8 {
        const img = app.hl.presented(app.wid) orelse return error.NothingPresented;
        const r = try render_cpu.Renderer.create(app.gpa, app.pool.executor());
        defer r.destroy();
        try r.resize(img.width, img.height);
        const out = try app.gpa.alloc(u8, @as(usize, img.width) * img.height * 4);
        const s = app.win.scale;
        try r.render(app.prev.?, .{ .root = .scale(s, s), .background = .white, .target = .{ .pixels = out.ptr, .stride = img.width * 4, .format = .abgr8888 } });
        return out;
    }
};
