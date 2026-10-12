//! A headless application for UI tests (D24): the real loop, worker pool,
//! and compositor (D8) on the headless backend, and a ui.Window committing
//! to it. The compositor runs without a thread of its own here, so every
//! test is deterministic; its own tests cover the thread.
//!
//! Input is injected into the platform on the compositor, which routes it
//! like real input: it scrolls scroll containers itself and forwards the
//! rest to the window. Caret blinking is off (reduced motion), so frames
//! do not depend on time.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const text = @import("text");
const loop_mod = @import("loop");
const platform = @import("platform");
const render_cpu = @import("render_cpu");
const compositor = @import("compositor");
const ui = @import("ui");

const Loop = loop_mod.Loop;
const Compositor = compositor.Compositor;

pub const App = struct {
    gpa: std.mem.Allocator,
    loop: Loop,
    pool: loop_mod.Pool,
    fonts: ui.Fonts,
    comp: *Compositor,
    win: *ui.Window,
    wid: platform.WindowId = 0,
    /// The layer tree as the window committed it (with the compositor's
    /// scroll offsets), for full redraws to compare damaged frames with.
    mirror: compositor.Tree,
    last_seq: u64 = 0,
    presented_seq: u64 = 0,
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
        app.last_seq = 0;
        app.presented_seq = 0;
        app.err = null;
        app.wid = 0;
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
        app.mirror = .init(gpa);
        errdefer app.mirror.deinit();
        app.win = try ui.Window.init(gpa, .{
            .fonts = &app.fonts,
            .sink = .{ .ctx = app, .commit = commit },
            .host = .{ .ctx = app, .request_frame = requestFrame },
            .width = @floatFromInt(options.width),
            .height = @floatFromInt(options.height),
            .scale = @floatFromInt(options.scale),
            .rtl = options.rtl,
            .reduced_motion = true,
        });
        errdefer app.win.deinit();
        var output: platform.OutputInfo = .{ .width = 1920, .height = 1080, .refresh_mhz = 60000, .scale = @intCast(options.scale) };
        output.name.set("HEADLESS-1");
        app.comp = try Compositor.create(.{
            .allocator = gpa,
            .executor = app.pool.executor(),
            .ui_loop = &app.loop,
            .sink = .{ .ctx = app, .func = onEvent },
            .backend = .{ .headless = .{ .refresh_ns = std.time.ns_per_ms, .output = output } },
            .thread = false,
        });
        app.wid = try app.comp.createWindow(.{ .width = options.width, .height = options.height });
    }

    pub fn deinit(app: *App) void {
        // The compositor first: afterwards nothing refers to the window's
        // builders.
        app.comp.destroy();
        app.pool.deinit();
        app.mirror.deinit();
        app.win.deinit();
        app.fonts.deinit();
        app.loop.deinit();
    }

    fn commit(ctx: ?*anyopaque, ops: []const compositor.Op) error{OutOfMemory}!u64 {
        const app: *App = @ptrCast(@alignCast(ctx));
        for (ops) |op| _ = try app.mirror.apply(op);
        app.last_seq = app.comp.commit(app.wid, ops) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("invalid ops: {t}", .{e}),
        };
        return app.last_seq;
    }

    fn requestFrame(ctx: ?*anyopaque) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        app.comp.requestFrame(app.wid) catch |e| {
            app.err = e;
        };
    }

    fn onEvent(ctx: ?*anyopaque, ev: *const compositor.Event) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .presented => |p| app.presented_seq = @max(app.presented_seq, p.seq),
            .scrolled => |s| if (app.mirror.get(s.layer)) |l| {
                l.offset = s.offset;
            },
            .platform => |p| if (p == .failed) {
                app.err = p.failed;
            },
            else => {},
        }
        if (ev.* == .released and !app.win.ownsBuilder(ev.released)) return;
        if (ev.window()) |w| if (w != app.wid) return;
        app.win.handleEvent(ev) catch |e| {
            app.err = e;
        };
    }

    /// Runs the loop until nothing is pending: everything committed is
    /// presented, no frame is wanted, fonts are loaded.
    pub fn settle(app: *App) !void {
        var idle: usize = 0;
        var guard: usize = 0;
        while (idle < 3) : (guard += 1) {
            if (guard > 2000) return error.Timeout;
            const before = app.presented_seq;
            try app.loop.dispatch(2);
            if (app.err) |e| return e;
            const busy = app.presented_seq != before or app.presented_seq < app.last_seq or
                app.win.needsFrame() or app.fonts.loading() or app.win.txn.open;
            idle = if (busy) 0 else idle + 1;
        }
    }

    /// Injects a platform event on the compositor, as the seat would.
    pub fn inject(app: *App, ev: platform.Event) void {
        const Ctx = struct {
            ev: platform.Event,
            fn run(ctx: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(ctx));
                comp.platform.headless.inject(s.ev);
            }
        };
        var c: Ctx = .{ .ev = ev };
        app.comp.call(&c, Ctx.run) catch |e| {
            app.err = e;
        };
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

    const Presented = struct { rgba: []u8, width: u32, height: u32, damage: ?platform.Rect };

    /// The presented frame as RGBA bytes (caller frees `rgba`), and the
    /// bounding box of its damage.
    pub fn presented(app: *App) !Presented {
        const Ctx = struct {
            gpa: std.mem.Allocator,
            wid: platform.WindowId,
            out: anyerror!Presented = error.NothingPresented,
            fn run(ctx: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(ctx));
                const img = comp.platform.headless.presented(s.wid) orelse return;
                const rgba = s.gpa.alloc(u8, @as(usize, img.width) * img.height * 4) catch |e| {
                    s.out = e;
                    return;
                };
                for (0..img.height) |y| for (0..img.width) |x| {
                    const p = img.pixels[y * img.stride + x * 4 ..][0..4];
                    rgba[(y * img.width + x) * 4 ..][0..4].* = .{ p[2], p[1], p[0], p[3] };
                };
                s.out = .{ .rgba = rgba, .width = img.width, .height = img.height, .damage = img.damage };
            }
        };
        var c: Ctx = .{ .gpa = app.gpa, .wid = app.wid };
        try app.comp.call(&c, Ctx.run);
        return c.out;
    }

    /// Renders the committed layer tree from scratch at the presented size.
    /// RGBA bytes; caller frees.
    pub fn fullRender(app: *App, width: u32, height: u32) ![]u8 {
        const list = try app.mirror.compose();
        // The mirror releases nothing: the compositor owns the builders.
        _ = app.mirror.endFrame();
        const r = try render_cpu.Renderer.create(app.gpa, app.pool.executor());
        defer r.destroy();
        try r.resize(width, height);
        const out = try app.gpa.alloc(u8, @as(usize, width) * height * 4);
        const s = app.win.scale;
        try r.render(list, .{ .root = .scale(s, s), .background = app.mirror.background, .target = .{ .pixels = out.ptr, .stride = width * 4, .format = .abgr8888 } });
        return out;
    }
};
