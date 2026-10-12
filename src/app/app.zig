//! The application coordinator (D20): it creates the subsystems of one
//! application, connects them, and sequences their phases. Nothing else
//! lives here; the tree, layout, input, and presentation stay in their
//! modules.
//!
//!     ┌────────────────────── UI thread ──────────────────────┐
//!     │ Loop: poll → io → timers → dispatch → frame → prepare │
//!     │             posted closures, compositor events ─┐     │
//!     │  ui.Window ◀── handleEvent ── App.onEvent ◀─────┘     │
//!     │      │ layer ops (Sink)                               │
//!     └──────┼────────────────────────────────────────────────┘
//!            ▼
//!     Compositor thread: platform, layer trees, presentation
//!
//! An `App` owns the UI loop, the worker pool (D6), the fonts, the
//! clipboard and the desktop settings (D19, desktop.zig), and the
//! compositor (D8). Each `Window` pairs a platform window on the
//! compositor with a `ui.Window`. Compositor events arrive in the loop's
//! dispatch phase (D5) and go to the window they name; window-level
//! events (close requests, configures) also go to the window's listener.
//!
//! Destroying a window takes effect at once for the application: no more
//! events, frames, or listener calls. Its `ui.Window` lives on until the
//! compositor has released every display list it holds and no event for
//! it is being delivered.
//!
//! Everything here is for the UI thread, except `post`.
//!
//! Imports: ui, compositor, platform, loop, text, dbus.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text");
const loop_mod = @import("loop");
const platform = @import("platform");
const compositor = @import("compositor");
const ui = @import("ui");
const desktop_mod = @import("desktop.zig");

const Loop = loop_mod.Loop;
const Compositor = compositor.Compositor;
const WindowId = platform.WindowId;

pub const Error = error{
    OutOfMemory,
    /// No display server could be reached, it lacks a required protocol,
    /// the connection was lost, or a system call failed.
    Unavailable,
    /// The loop is already dispatching (a callback called back in).
    Busy,
};

pub const Backend = enum {
    /// Wayland.
    wayland,
    /// The headless backend: the same loop and presentation, no display
    /// server (D20, D24).
    headless,
};

pub const Options = struct {
    backend: Backend = .wayland,
    /// Wayland socket name or path; null uses $WAYLAND_DISPLAY.
    display: ?[*:0]const u8 = null,
    headless: platform.Headless.Options = .{},
    /// Resolve font families with Fontconfig. Without it only families
    /// registered from bytes (`addFont`) resolve.
    system_fonts: bool = true,
    /// Worker threads; 0 uses one per CPU.
    threads: u32 = 0,
    /// Run the compositor on its own thread (D8). Without one it runs on
    /// the UI loop, for deterministic tests.
    compositor_thread: bool = true,
    /// No caret blinking or other motion in any window, whatever the
    /// desktop settings say.
    reduced_motion: bool = false,
    /// Follow the portal's desktop settings (D19).
    desktop_settings: bool = true,
    /// The bus for them; null is the session bus.
    bus_address: ?[]const u8 = null,
};

pub const App = struct {
    /// Every allocation of the application; thread-safe (D2).
    gpa: Allocator,
    loop: Loop,
    pool: loop_mod.Pool,
    fonts: ui.Fonts,
    clipboard: ui.Clipboard,
    comp: *Compositor,
    /// Live windows by platform window id.
    windows: std.ArrayList(?*Window) = .empty,
    /// Destroyed windows waiting for their display lists to come back.
    zombies: std.ArrayList(*Window) = .empty,
    /// Nesting of compositor event delivery.
    delivering: u32 = 0,
    open_windows: usize = 0,
    reduced_motion: bool = false,
    desktop: desktop_mod.Desktop = .{},
    /// The application chose the default font family, so the desktop's
    /// does not replace it.
    font_overridden: bool = false,
    quit_requested: bool = false,
    /// Reported by the next `dispatch`. Unavailable stays.
    failure: ?Error = null,

    pub fn create(gpa: Allocator, options: Options) Error!*App {
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        app.* = .{
            .gpa = gpa,
            .loop = Loop.init(gpa) catch return error.Unavailable,
            .pool = undefined,
            .fonts = undefined,
            .clipboard = undefined,
            .comp = undefined,
            .reduced_motion = options.reduced_motion,
        };
        errdefer app.loop.deinit();
        app.pool = .init(&app.loop, gpa, if (options.threads != 0) options.threads else loop_mod.Pool.defaultThreadCount());
        errdefer app.pool.deinit();
        app.fonts = try .init(gpa);
        errdefer app.fonts.deinit();
        app.fonts.pool = &app.pool;
        if (options.system_fonts) app.fonts.database = text.fontconfig.Database.init() catch null;
        app.clipboard = .init(gpa, &app.loop, .{ .ctx = app, .set_selection = setSelection, .receive = receiveSelection });
        errdefer app.clipboard.deinit();
        // The bus handshake and the settings read proceed while the
        // compositor connects to Wayland below.
        if (options.desktop_settings) app.desktop.start(app, options.bus_address);
        errdefer app.desktop.deinit(app);
        app.comp = Compositor.create(.{
            .allocator = gpa,
            .executor = app.pool.executor(),
            .ui_loop = &app.loop,
            .sink = .{ .ctx = app, .func = onEvent },
            .backend = switch (options.backend) {
                .wayland => .{ .wayland = .{ .display = options.display } },
                .headless => .{ .headless = options.headless },
            },
            .thread = options.compositor_thread,
        }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
        return app;
    }

    /// Tears everything down. Posted closures that have not run get their
    /// destroy function instead (D5). Not from inside `dispatch`.
    pub fn destroy(app: *App) void {
        std.debug.assert(!app.loop.isDispatching());
        const gpa = app.gpa;
        // Nothing reads the windows' display lists or fonts after this.
        app.comp.destroy();
        app.desktop.deinit(app);
        for (app.windows.items) |w| if (w) |win| win.free();
        for (app.zombies.items) |win| win.free();
        app.windows.deinit(gpa);
        app.zombies.deinit(gpa);
        app.clipboard.deinit();
        app.fonts.deinit();
        app.pool.deinit();
        app.loop.deinit();
        gpa.destroy(app);
    }

    /// Runs one loop iteration (D6). `timeout_ms` bounds the wait: -1
    /// blocks until there is work, 0 never blocks.
    pub fn dispatch(app: *App, timeout_ms: i32) Error!void {
        if (app.loop.isDispatching()) return error.Busy;
        app.loop.dispatch(timeout_ms) catch return error.Unavailable;
        app.freeZombies();
        if (app.failure) |err| {
            if (err != error.Unavailable) app.failure = null;
            return err;
        }
    }

    /// Dispatches until `quit` is called or the last window is destroyed.
    pub fn run(app: *App) Error!void {
        if (app.loop.isDispatching()) return error.Busy;
        app.quit_requested = false;
        while (!app.quit_requested) try app.dispatch(-1);
    }

    /// Makes `run` return after the current iteration.
    pub fn quit(app: *App) void {
        app.quit_requested = true;
        app.loop.wake();
    }

    /// The epoll fd; readable whenever `dispatch(0)` has work (D6).
    pub fn fd(app: *const App) i32 {
        return app.loop.fd();
    }

    /// C calling convention, so that the C ABI passes its callbacks on.
    pub const PostFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;

    /// Runs `func(ctx)` on the UI thread in the dispatch phase, then
    /// `destroy(ctx)`. If the application is destroyed first, only
    /// `destroy(ctx)` runs (D5). Safe from any thread while the
    /// application exists.
    pub fn post(app: *App, func: PostFn, destroy_fn: ?PostFn, ctx: ?*anyopaque) Allocator.Error!void {
        const p = try app.gpa.create(Posted);
        p.* = .{ .func = func, .destroy = destroy_fn, .ctx = ctx, .gpa = app.gpa };
        app.loop.postRemote(&p.remote);
    }

    const Posted = struct {
        remote: Loop.Remote = .{ .func = invoke, .cancel = drop },
        func: PostFn,
        destroy: ?PostFn,
        ctx: ?*anyopaque,
        gpa: Allocator,

        fn invoke(r: *Loop.Remote) void {
            const p: *Posted = @fieldParentPtr("remote", r);
            const func, const destroy_fn, const ctx = .{ p.func, p.destroy, p.ctx };
            p.gpa.destroy(p);
            func(ctx);
            if (destroy_fn) |d| d(ctx);
        }

        fn drop(r: *Loop.Remote) void {
            const p: *Posted = @fieldParentPtr("remote", r);
            const destroy_fn, const ctx = .{ p.destroy, p.ctx };
            p.gpa.destroy(p);
            if (destroy_fn) |d| d(ctx);
        }
    };

    /// Registers a font from bytes (copied) and appends it to `family`'s
    /// fallback chain, which takes precedence over Fontconfig.
    pub fn addFont(app: *App, family: []const u8, bytes: []const u8) error{ OutOfMemory, InvalidFont }!void {
        const fonts = &app.fonts;
        const name = try fonts.intern(family);
        const old: []const text.FontId = fonts.families.get(name) orelse &.{};
        const chain = try app.gpa.alloc(text.FontId, old.len + 1);
        defer app.gpa.free(chain);
        // The cache owns the copy, and frees it on failure.
        const id = fonts.cache.add(try app.gpa.dupe(u8, bytes), 0, .owned) catch |err|
            return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFont;
        @memcpy(chain[0..old.len], old);
        chain[old.len] = id;
        try fonts.register(family, chain);
    }

    /// Overrides the desktop's font (D19) from now on.
    pub fn setDefaultFont(app: *App, family: []const u8) Allocator.Error!void {
        try app.fonts.setDefault(family);
        app.font_overridden = true;
        app.refreshText();
    }

    /// The default font family or the text scale changed: text in the
    /// default family reshapes, and canvases measure and draw again.
    pub fn refreshText(app: *App) void {
        for (app.windows.items) |w| if (w) |win| {
            const uw = win.ui;
            for (uw.nodes.items, 0..) |*n, i| {
                if (n.status != .live) continue;
                const id: ui.NodeId = @enumFromInt(i);
                if (n.isText() and n.textData().family == 0) uw.markShape(id);
                if (n.kind == .canvas) {
                    uw.markLayout(id);
                    uw.markPaint(id);
                }
            }
            uw.requestFrame();
        };
    }

    pub fn createWindow(app: *App, options: WindowOptions, listener: Listener) Error!*Window {
        const gpa = app.gpa;
        try app.zombies.ensureUnusedCapacity(gpa, 1);
        const win = try gpa.create(Window);
        errdefer gpa.destroy(win);
        const id = app.comp.createWindow(.{
            .title = options.title,
            .app_id = options.app_id,
            .width = options.width,
            .height = options.height,
            .decoration = if (options.client_decorations) .client else .server,
        }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
        errdefer app.comp.destroyWindow(id) catch {};
        if (id >= app.windows.items.len) try app.windows.appendNTimes(gpa, null, id + 1 - app.windows.items.len);
        win.* = .{ .app = app, .id = id, .ui = undefined, .listener = listener };
        win.ui = try ui.Window.init(gpa, .{
            .fonts = &app.fonts,
            .sink = .{ .ctx = win, .commit = Window.commit },
            .host = .{ .ctx = win, .request_frame = Window.requestFrame, .text_input = Window.textInput },
            .clipboard = &app.clipboard,
            .reduced_motion = app.reduced_motion,
            .desktop = app.desktop.values,
            .width = @floatFromInt(options.width),
            .height = @floatFromInt(options.height),
            .rtl = options.rtl,
            .language = options.language,
        });
        app.windows.items[id] = win;
        app.open_windows += 1;
        return win;
    }

    fn window(app: *App, id: ?WindowId) ?*Window {
        const i = id orelse return null;
        if (i >= app.windows.items.len) return null;
        return app.windows.items[i];
    }

    pub fn fail(app: *App, err: Error) void {
        if (app.failure == null or err == error.Unavailable) app.failure = err;
    }

    // Selection requests run on the compositor thread (D8); `call` blocks
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

    fn receiveSelection(ctx: ?*anyopaque, seat: platform.SeatId, kind: platform.SelectionKind, prefs: []const []const u8, pipe_fd: i32) bool {
        const app: *App = @ptrCast(@alignCast(ctx));
        const Ctx = struct {
            seat: platform.SeatId,
            kind: platform.SelectionKind,
            prefs: []const []const u8,
            fd: i32,
            out: bool = false,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                const mime = ui.Clipboard.pick(comp.platform.selectionMimes(s.seat, s.kind), s.prefs) orelse {
                    _ = std.os.linux.close(s.fd);
                    return;
                };
                s.out = comp.platform.receiveSelection(s.seat, s.kind, mime, s.fd);
            }
        };
        var c: Ctx = .{ .seat = seat, .kind = kind, .prefs = prefs, .fd = pipe_fd };
        app.comp.call(&c, Ctx.run) catch {
            _ = std.os.linux.close(pipe_fd);
            return false;
        };
        return c.out;
    }

    /// Compositor events, in the UI loop's dispatch phase.
    fn onEvent(ctx: ?*anyopaque, ev: *const compositor.Event) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        // Selection events belong to the application, not a window.
        if (ev.* == .platform and app.clipboard.handleEvent(&ev.platform)) return;
        app.delivering += 1;
        defer {
            app.delivering -= 1;
            app.freeZombies();
        }
        switch (ev.*) {
            .released => |b| {
                for (app.windows.items) |w| if (w) |win| if (win.ui.ownsBuilder(b)) return win.handle(ev);
                for (app.zombies.items) |win| if (win.ui.ownsBuilder(b)) return win.handle(ev);
            },
            .platform => |*p| switch (p.*) {
                .failed => |err| app.fail(if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable),
                .close_requested => |id| if (app.window(id)) |win| {
                    if (!win.notify(&.close_requested)) win.destroy() catch |err| app.fail(err);
                },
                else => if (app.window(p.window())) |win| win.handle(ev),
            },
            .configure => |c| if (app.window(c.window)) |win| {
                const old = win.state;
                win.state = c.state;
                win.handle(ev);
                if (!win.closed) _ = win.notify(&.{ .configure = .{ .old = old, .new = c.state } });
            },
            // First frames wait for the desktop settings (desktop.zig).
            .frame => |f| if (app.window(f.window)) |win| {
                if (app.desktop.waiting) win.frame_held = true else win.handle(ev);
            },
            .external_released => |x| if (app.window(x.window)) |win| {
                _ = win.notify(&.{ .external_released = .{ .id = x.id, .key = x.key } });
            },
            .external_configure => |x| if (app.window(x.window)) |win| {
                _ = win.notify(&.{ .external_configure = .{ .id = x.id, .width = x.width, .height = x.height, .buffer_width = x.buffer_width, .buffer_height = x.buffer_height } });
            },
            .presented => |p| if (app.window(p.window)) |win| {
                win.presented_seq = p.seq;
                win.handle(ev);
            },
            else => if (app.window(ev.window())) |win| win.handle(ev),
        }
    }

    fn freeZombies(app: *App) void {
        if (app.delivering != 0) return;
        var i: usize = 0;
        while (i < app.zombies.items.len) {
            const win = app.zombies.items[i];
            if (win.ui.buildersHome()) {
                _ = app.zombies.swapRemove(i);
                win.free();
            } else i += 1;
        }
    }
};

pub const WindowOptions = struct {
    title: []const u8 = "",
    app_id: []const u8 = "",
    /// Logical size used when the compositor lets the client choose.
    width: u32 = 640,
    height: u32 = 480,
    client_decorations: bool = false,
    rtl: bool = false,
    /// BCP 47 language of the window's text.
    language: []const u8 = "",
};

pub const WindowEvent = union(enum) {
    /// The user asked to close the window. Unless the listener returns
    /// true, the window is destroyed.
    close_requested,
    /// New size, scale, or states; the tree has already been told.
    configure: struct { old: platform.WindowState, new: platform.WindowState },
    /// No frame reads an external frame any more (D17).
    external_released: struct { id: compositor.ExternalId, key: u64 },
    /// An embedder's surface has a new size.
    external_configure: struct { id: compositor.ExternalId, width: u32, height: u32, buffer_width: u32, buffer_height: u32 },
};

pub const Listener = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (ctx: ?*anyopaque, win: *Window, event: *const WindowEvent) bool = null,
};

pub const Window = struct {
    app: *App,
    id: WindowId,
    ui: *ui.Window,
    listener: Listener,
    /// As of the last configure.
    state: platform.WindowState = .{},
    closed: bool = false,
    /// A frame event arrived while the desktop settings were awaited.
    frame_held: bool = false,
    /// Last layer commit, and the last one presented.
    committed_seq: u64 = 0,
    presented_seq: u64 = 0,

    /// Destroys the window (see the module comment). On failure nothing
    /// changed.
    pub fn destroy(win: *Window) Allocator.Error!void {
        if (win.closed) return;
        const app = win.app;
        try app.zombies.ensureUnusedCapacity(app.gpa, 1);
        try app.comp.destroyWindow(win.id);
        win.closed = true;
        if (win.ui.txn.open) win.ui.txn.abort();
        app.windows.items[win.id] = null;
        app.zombies.appendAssumeCapacity(win);
        app.open_windows -= 1;
        if (app.open_windows == 0) app.quit();
        app.freeZombies();
    }

    fn free(win: *Window) void {
        if (win.ui.txn.open) win.ui.txn.abort();
        win.ui.deinit();
        win.app.gpa.destroy(win);
    }

    fn handle(win: *Window, ev: *const compositor.Event) void {
        win.ui.handleEvent(ev) catch |err| win.app.fail(err);
    }

    fn notify(win: *Window, ev: *const WindowEvent) bool {
        const f = win.listener.func orelse return false;
        return f(win.listener.ctx, win, ev);
    }

    fn commit(ctx: ?*anyopaque, ops: []const compositor.Op) error{OutOfMemory}!u64 {
        const win: *Window = @ptrCast(@alignCast(ctx));
        const seq = win.app.comp.commit(win.id, ops) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The tree only emits valid ops.
            else => unreachable,
        };
        win.committed_seq = seq;
        return seq;
    }

    // External content (D17): slots the tree shows with external nodes.

    /// A slot for frames a producer submits (`setExternalFrame`).
    pub fn createExternal(win: *Window) Error!compositor.ExternalId {
        return win.app.comp.createExternal(win.id) catch |err| if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
    }

    /// A slot backed by a `wl_surface` an embedder renders into.
    pub fn createExternalSurface(win: *Window) Error!Compositor.ExternalSurface {
        return win.app.comp.createExternalSurface(win.id) catch |err| if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
    }

    /// Shows a new frame in a slot; the fd is duplicated.
    pub fn setExternalFrame(win: *Window, id: compositor.ExternalId, frame: compositor.ExternalFrame) Error!void {
        win.app.comp.setExternalFrame(win.id, id, frame) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
    }

    pub fn externalSurfaceCommitted(win: *Window, id: compositor.ExternalId, width: u32, height: u32) Allocator.Error!void {
        try win.app.comp.externalSurfaceCommitted(win.id, id, width, height);
    }

    pub fn destroyExternal(win: *Window, id: compositor.ExternalId) Allocator.Error!void {
        try win.app.comp.destroyExternal(win.id, id);
    }

    /// Asks again for a frame held for the desktop settings.
    pub fn releaseFrame(win: *Window) void {
        if (!win.frame_held) return;
        win.frame_held = false;
        requestFrame(win);
    }

    fn requestFrame(ctx: ?*anyopaque) void {
        const win: *Window = @ptrCast(@alignCast(ctx));
        if (win.closed) return;
        win.app.comp.requestFrame(win.id) catch win.app.fail(error.OutOfMemory);
    }

    /// Text input state for the input method (text-input-v3), set on the
    /// compositor thread in order with commits (D8). The request owns a
    /// copy of the surrounding text.
    fn textInput(ctx: ?*anyopaque, seat: platform.SeatId, state: *const platform.TextInputState) void {
        const win: *Window = @ptrCast(@alignCast(ctx));
        if (win.closed) return;
        const gpa = win.app.gpa;
        const Req = struct {
            gpa: Allocator,
            seat: platform.SeatId,
            state: platform.TextInputState,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const r: *@This() = @ptrCast(@alignCast(c));
                comp.platform.setTextInput(r.seat, &r.state);
                drop(c);
            }
            fn drop(c: ?*anyopaque) void {
                const r: *@This() = @ptrCast(@alignCast(c));
                r.gpa.free(r.state.surrounding);
                r.gpa.destroy(r);
            }
        };
        const r = gpa.create(Req) catch return win.app.fail(error.OutOfMemory);
        const copy = gpa.dupe(u8, state.surrounding) catch {
            gpa.destroy(r);
            return win.app.fail(error.OutOfMemory);
        };
        r.* = .{ .gpa = gpa, .seat = seat, .state = state.* };
        r.state.surrounding = copy;
        win.app.comp.post(r, Req.run, Req.drop) catch {
            Req.drop(r);
            win.app.fail(error.OutOfMemory);
        };
    }

    /// Whether everything committed has been presented and the tree has
    /// no frame pending.
    pub fn settled(win: *const Window) bool {
        return win.presented_seq >= win.committed_seq and !win.ui.needsFrame() and !win.ui.txn.open;
    }

    pub fn setTitle(win: *Window, title: []const u8) Allocator.Error!void {
        try win.platformCall(struct {
            fn f(p: platform.Platform, id: WindowId, s: []const u8) void {
                p.setTitle(id, s);
            }
        }.f, title);
    }

    pub fn setMaximized(win: *Window, on: bool) Allocator.Error!void {
        try win.platformCall(platform.Platform.setMaximized, on);
    }

    pub fn setFullscreen(win: *Window, on: bool) Allocator.Error!void {
        try win.platformCall(platform.Platform.setFullscreen, on);
    }

    pub fn minimize(win: *Window) Allocator.Error!void {
        try win.platformCall(struct {
            fn f(p: platform.Platform, id: WindowId, _: void) void {
                p.setMinimized(id);
            }
        }.f, {});
    }

    pub const Limits = struct { min: platform.Size, max: platform.Size };

    pub fn setSizeLimits(win: *Window, min: platform.Size, max: platform.Size) Allocator.Error!void {
        try win.platformCall(struct {
            fn f(p: platform.Platform, id: WindowId, l: Limits) void {
                p.setSizeLimits(id, l.min, l.max);
            }
        }.f, Limits{ .min = min, .max = max });
    }

    /// Runs `func(platform, id, arg)` on the compositor thread, in order
    /// with layer commits (D8). A string argument is copied.
    fn platformCall(win: *Window, comptime func: anytype, arg: anytype) Allocator.Error!void {
        const Arg = @TypeOf(arg);
        const gpa = win.app.gpa;
        const Closure = struct {
            gpa: Allocator,
            id: WindowId,
            arg: Arg,

            fn run(ctx: ?*anyopaque, comp: *Compositor) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                func(comp.platform, c.id, c.arg);
                drop(ctx);
            }

            fn drop(ctx: ?*anyopaque) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                if (Arg == []const u8) c.gpa.free(c.arg);
                c.gpa.destroy(c);
            }
        };
        const c = try gpa.create(Closure);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .id = win.id, .arg = if (Arg == []const u8) try gpa.dupe(u8, arg) else arg };
        errdefer if (Arg == []const u8) gpa.free(c.arg);
        try win.app.comp.post(c, Closure.run, Closure.drop);
    }
};

test {
    if (comptime @import("integration").enabled) {
        // `zig build test-integration`: desktop settings via dbus-daemon.
        _ = @import("integration_tests.zig");
        return;
    }
    std.testing.refAllDecls(@This());
    _ = @import("desktop.zig");
    _ = @import("tests.zig");
}
