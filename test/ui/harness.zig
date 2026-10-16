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
    clipboard: ui.Clipboard,
    drag: ui.dnd.CompositorHost = undefined,
    last_seq: u64 = 0,
    presented_seq: u64 = 0,
    popups: std.ArrayList(*Popup) = .empty,
    err: ?anyerror = null,
    /// The last size an embedder was told to render at.
    external_configure: ?@FieldType(compositor.Event, "external_configure") = null,

    pub const Options = struct {
        width: u32 = 320,
        height: u32 = 240,
        /// A fractional scale comes as fractional-scale-v1 sends it, over
        /// an output of the integer scale below it.
        scale: f32 = 1,
        rtl: bool = false,
        output_width: i32 = 1920,
        output_height: i32 = 1080,
    };

    /// A popup window and its own ui.Window (D17).
    pub const Popup = struct {
        app: *App,
        wid: platform.WindowId,
        win: *ui.Window,
        closed: bool = false,

        fn commit(ctx: ?*anyopaque, ops: []const compositor.Op) error{OutOfMemory}!u64 {
            const p: *Popup = @ptrCast(@alignCast(ctx));
            const seq = p.app.comp.commit(p.wid, ops) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => std.debug.panic("invalid ops: {t}", .{e}),
            };
            p.app.last_seq = @max(p.app.last_seq, seq);
            return seq;
        }

        fn requestFrame(ctx: ?*anyopaque) void {
            const p: *Popup = @ptrCast(@alignCast(ctx));
            p.app.comp.requestFrame(p.wid) catch |e| {
                p.app.err = e;
            };
        }

        pub fn close(p: *Popup) void {
            const app = p.app;
            for (app.popups.items, 0..) |q, i| if (q == p) {
                _ = app.popups.orderedRemove(i);
                break;
            };
            app.comp.destroyWindow(p.wid) catch {};
            p.win.deinit();
            app.gpa.destroy(p);
        }
    };

    /// Opens a popup anchored to `node` of the main window, with a grab
    /// for the last press if `grab`.
    pub fn openPopup(app: *App, node: ui.NodeId, width: u32, height: u32, placement: ui.Window.PopupPlacement, grab: bool) !*Popup {
        const p = try app.gpa.create(Popup);
        errdefer app.gpa.destroy(p);
        p.* = .{ .app = app, .wid = undefined, .win = undefined };
        p.win = try ui.Window.init(app.gpa, .{
            .fonts = &app.fonts,
            .sink = .{ .ctx = p, .commit = Popup.commit },
            .host = .{ .ctx = p, .request_frame = Popup.requestFrame },
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
            .scale = app.win.scale,
            .rtl = app.win.rtl,
            .reduced_motion = true,
            .clipboard = &app.clipboard,
        });
        errdefer p.win.deinit();
        try app.popups.append(app.gpa, p);
        errdefer _ = app.popups.pop();
        p.wid = try app.comp.createPopup(.{
            .parent = app.wid,
            .positioner = app.win.popupPositioner(node, width, height, placement, null),
            .grab = if (grab) .{ .seat = app.win.input.seat, .serial = app.win.input.serial } else null,
        });
        return p;
    }

    /// `app` must not move afterwards.
    pub fn init(app: *App, gpa: std.mem.Allocator, options: Options) !void {
        app.gpa = gpa;
        app.last_seq = 0;
        app.presented_seq = 0;
        app.popups = .empty;
        app.external_configure = null;
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
        app.clipboard = .init(gpa, &app.loop, .{ .ctx = app, .set_selection = setSelection, .receive = receiveSelection });
        errdefer app.clipboard.deinit();
        // The compositor exists before any drag can start.
        app.drag = .{ .comp = undefined, .window = 0, .gpa = gpa };
        app.win = try ui.Window.init(gpa, .{
            .fonts = &app.fonts,
            .sink = .{ .ctx = app, .commit = commit },
            .host = .{ .ctx = app, .request_frame = requestFrame, .text_input = textInput, .set_cursor = setCursor },
            .width = @floatFromInt(options.width),
            .height = @floatFromInt(options.height),
            .scale = options.scale,
            .rtl = options.rtl,
            .reduced_motion = true,
            .clipboard = &app.clipboard,
            .drag = app.drag.host(),
            .loop = &app.loop,
        });
        errdefer app.win.deinit();
        var output: platform.OutputInfo = .{ .width = options.output_width, .height = options.output_height, .refresh_mhz = 60000, .scale = @intFromFloat(@max(1, @floor(options.scale))) };
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
        const Preferred = struct { platform.WindowId, platform.Scale };
        if (options.scale != @floor(options.scale)) app.onHeadless(Preferred{ app.wid, .{ .v120 = @intFromFloat(@round(options.scale * 120)) } }, struct {
            fn f(hl: *platform.Headless, c: Preferred) void {
                hl.setScale(c[0], c[1]);
            }
        }.f);
        app.drag.comp = app.comp;
        app.drag.window = app.wid;
    }

    pub fn deinit(app: *App) void {
        while (app.popups.items.len != 0) app.popups.items[app.popups.items.len - 1].close();
        app.popups.deinit(app.gpa);
        // The compositor first: afterwards nothing refers to the window's
        // builders.
        app.comp.destroy();
        app.pool.deinit();
        app.mirror.deinit();
        app.win.deinit();
        app.clipboard.deinit();
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

    fn setCursor(ctx: ?*anyopaque, shape: ui.CursorShape) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        const Req = struct {
            gpa: std.mem.Allocator,
            wid: platform.WindowId,
            shape: ui.CursorShape,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const r: *@This() = @ptrCast(@alignCast(c));
                comp.platform.setCursor(r.wid, r.shape);
                destroy(c);
            }
            fn destroy(c: ?*anyopaque) void {
                const r: *@This() = @ptrCast(@alignCast(c));
                r.gpa.destroy(r);
            }
        };
        const r = app.gpa.create(Req) catch |e| {
            app.err = e;
            return;
        };
        r.* = .{ .gpa = app.gpa, .wid = app.wid, .shape = shape };
        app.comp.post(r, Req.run, Req.destroy) catch |e| {
            Req.destroy(r);
            app.err = e;
        };
    }

    /// Text input requests run on the compositor thread, in order with
    /// commits (D8). The request owns a copy of the surrounding text.
    fn textInput(ctx: ?*anyopaque, seat: platform.SeatId, state: *const platform.TextInputState) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        const Req = struct {
            gpa: std.mem.Allocator,
            seat: platform.SeatId,
            state: platform.TextInputState,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const r: *@This() = @ptrCast(@alignCast(c));
                comp.platform.setTextInput(r.seat, &r.state);
                destroy(c);
            }
            fn destroy(c: ?*anyopaque) void {
                const r: *@This() = @ptrCast(@alignCast(c));
                r.gpa.free(r.state.surrounding);
                r.gpa.destroy(r);
            }
        };
        const r = app.gpa.create(Req) catch |e| {
            app.err = e;
            return;
        };
        const copy = app.gpa.dupe(u8, state.surrounding) catch |e| {
            app.gpa.destroy(r);
            app.err = e;
            return;
        };
        r.* = .{ .gpa = app.gpa, .seat = seat, .state = state.* };
        r.state.surrounding = copy;
        app.comp.post(r, Req.run, Req.destroy) catch |e| {
            Req.destroy(r);
            app.err = e;
        };
    }

    /// What seat 0's text input last committed on the platform.
    pub fn textInputState(app: *App) !struct { enabled: bool, surrounding: []u8, cursor: u32, commits: u32, rect: platform.Rect } {
        const Ctx = struct {
            gpa: std.mem.Allocator,
            out: anyerror!@typeInfo(@typeInfo(@TypeOf(textInputState)).@"fn".return_type.?).error_union.payload = error.OutOfMemory,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                const rec = comp.platform.headless.textInput(0);
                const copy = s.gpa.dupe(u8, rec.state.surrounding) catch return;
                s.out = .{ .enabled = rec.state.enabled, .surrounding = copy, .cursor = rec.state.cursor, .commits = rec.commits, .rect = rec.state.cursor_rect };
            }
        };
        var c: Ctx = .{ .gpa = app.gpa };
        try app.comp.call(&c, Ctx.run);
        return c.out;
    }

    // Selection requests run on the compositor thread (D8). `call` blocks
    // for at most about a frame.
    fn setSelection(ctx: ?*anyopaque, seat: platform.SeatId, kind: platform.SelectionKind, mimes: []const []const u8, serial: u32) ?u32 {
        const app: *App = @ptrCast(@alignCast(ctx));
        const Ctx = struct {
            seat: platform.SeatId,
            kind: platform.SelectionKind,
            mimes: []const []const u8,
            serial: u32,
            out: ?u32 = null,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                s.out = comp.platform.setSelection(s.seat, s.kind, s.mimes, s.serial) catch null;
            }
        };
        var c: Ctx = .{ .seat = seat, .kind = kind, .mimes = mimes, .serial = serial };
        app.comp.call(&c, Ctx.run) catch return null;
        return c.out;
    }

    fn receiveSelection(ctx: ?*anyopaque, seat: platform.SeatId, kind: platform.SelectionKind, prefs: []const []const u8, fd: i32) ?usize {
        const app: *App = @ptrCast(@alignCast(ctx));
        const Ctx = struct {
            seat: platform.SeatId,
            kind: platform.SelectionKind,
            prefs: []const []const u8,
            fd: i32,
            out: ?usize = null,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                const mime = ui.Clipboard.pick(comp.platform.selectionMimes(s.seat, s.kind), s.prefs) orelse {
                    _ = std.os.linux.close(s.fd);
                    return;
                };
                if (!comp.platform.receiveSelection(s.seat, s.kind, mime, s.fd)) return;
                for (s.prefs, 0..) |p, i| if (p.ptr == mime.ptr) {
                    s.out = i;
                };
            }
        };
        var c: Ctx = .{ .seat = seat, .kind = kind, .prefs = prefs, .fd = fd };
        app.comp.call(&c, Ctx.run) catch {
            _ = std.os.linux.close(fd);
            return null;
        };
        return c.out;
    }

    /// Runs `f(headless, ctx)` on the compositor thread.
    pub fn onHeadless(app: *App, ctx: anytype, comptime f: fn (*platform.Headless, @TypeOf(ctx)) void) void {
        const C = struct {
            ctx: @TypeOf(ctx),
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                f(comp.platform.headless, s.ctx);
            }
        };
        var c: C = .{ .ctx = ctx };
        app.comp.call(&c, C.run) catch |e| {
            app.err = e;
        };
    }

    /// Reads a pipe to its end while the loop runs (the writer may be this
    /// application). Caller frees.
    pub fn readAll(app: *App, fd: i32) ![]u8 {
        const linux = std.os.linux;
        defer _ = linux.close(fd);
        const o_nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
        _ = linux.fcntl(fd, linux.F.SETFL, linux.fcntl(fd, linux.F.GETFL, 0) | o_nonblock);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(app.gpa);
        var guard: usize = 0;
        while (true) : (guard += 1) {
            if (guard > 100_000) return error.Timeout;
            try out.ensureUnusedCapacity(app.gpa, 64 * 1024);
            const space = out.unusedCapacitySlice();
            const n = linux.read(fd, space.ptr, space.len);
            switch (linux.errno(n)) {
                .SUCCESS => if (n == 0) return out.toOwnedSlice(app.gpa) else {
                    out.items.len += n;
                },
                .AGAIN => try app.loop.dispatch(1),
                else => return error.ReadFailed,
            }
        }
    }

    fn onEvent(ctx: ?*anyopaque, ev: *const compositor.Event) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        if (ev.* == .platform and app.clipboard.handleEvent(&ev.platform)) return;
        switch (ev.*) {
            .presented => |p| app.presented_seq = @max(app.presented_seq, p.seq),
            .scrolled => |s| if (app.mirror.get(s.layer)) |l| {
                l.offset = s.offset;
            },
            .platform => |p| if (p == .failed) {
                app.err = p.failed;
            },
            .external_configure => |cf| app.external_configure = cf,
            else => {},
        }
        if (ev.* == .released) {
            for (app.popups.items) |p| if (p.win.ownsBuilder(ev.released)) return p.win.handleEvent(ev) catch {};
            if (!app.win.ownsBuilder(ev.released)) return;
        }
        if (ev.window()) |w| if (w != app.wid) {
            for (app.popups.items) |p| if (p.wid == w) {
                if (ev.* == .platform and ev.platform == .close_requested) p.closed = true;
                if (ev.* == .presented) app.presented_seq = @max(app.presented_seq, ev.presented.seq);
                p.win.handleEvent(ev) catch |e| {
                    app.err = e;
                };
            };
            return;
        };
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
            var popups_busy = false;
            for (app.popups.items) |p| popups_busy = popups_busy or p.win.needsFrame();
            const busy = app.presented_seq != before or app.presented_seq < app.last_seq or
                app.win.needsFrame() or app.fonts.loading() or app.win.txn.open or popups_busy or
                app.clipboard.transfers.items.len != 0 or app.clipboard.ready.items.len != 0 or
                platform.Headless.writersRunning() != 0;
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
        return app.presentedOf(app.wid);
    }

    /// The popup's (or any window's) presented frame and placement.
    pub fn windowState(app: *App, wid: platform.WindowId) !platform.WindowState {
        const Ctx = struct {
            wid: platform.WindowId,
            out: platform.WindowState = .{},
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                s.out = comp.platform.window(s.wid).*;
            }
        };
        var c: Ctx = .{ .wid = wid };
        try app.comp.call(&c, Ctx.run);
        return c.out;
    }

    pub fn presentedOf(app: *App, wid: platform.WindowId) !Presented {
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
        var c: Ctx = .{ .gpa = app.gpa, .wid = wid };
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
