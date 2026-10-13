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
//! events, frames, or listener calls. The `Window` and its `ui.Window` live
//! on until the compositor has released every display list it holds, no
//! event for it is being delivered, and the loop runs again (the next
//! dispatch or event delivery, or `App.destroy`), so the caller of
//! `destroy` may still tear down what it keeps about the window.
//!
//! Everything here is for the UI thread, except `post`.
//!
//! Imports: ui, compositor, platform, loop, text, dbus, a11y, portal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text");
const loop_mod = @import("loop");
const platform = @import("platform");
const compositor = @import("compositor");
const ui = @import("ui");
const desktop_mod = @import("desktop.zig");
const a11y = @import("a11y");
pub const portals = @import("portals.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const locale = @import("locale.zig");

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
    /// Search the system's icon themes (D19). Without it only directories
    /// added with `Icons.addSearchPath` are searched.
    system_icons: bool = true,
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
    /// Publish the windows' semantics to assistive technology over
    /// AT-SPI (D18), while it listens.
    accessibility: bool = true,
    /// The session bus for desktop settings and accessibility; null finds
    /// it from the environment.
    bus_address: ?[]const u8 = null,
    /// A connected socket to the session bus instead (tests); taken over.
    bus_fd: ?i32 = null,
    /// The application id (reverse DNS, the .desktop file's name): the
    /// default window app id, and the id portals and D-Bus activation use.
    app_id: []const u8 = "",
    /// The application's name for assistive technology.
    name: []const u8 = "",
    /// siv's version, as assistive technology reports it.
    toolkit_version: []const u8 = "",
    /// BCP 47 language of the application's text (D21); empty is the
    /// process locale's (none on the headless backend).
    language: []const u8 = "",
    /// Right to left; null is the direction `language` is written in.
    rtl: ?bool = null,
};

pub const App = struct {
    /// Every allocation of the application; thread-safe (D2).
    gpa: Allocator,
    loop: Loop,
    pool: loop_mod.Pool,
    fonts: ui.Fonts,
    /// Themed icons (D19), shared by every window.
    icons: ui.Icons,
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
    /// The theme choices every window follows (D29).
    theme: ui.Theme = .{},
    /// The application chose the default font family, so the desktop's
    /// does not replace it.
    font_overridden: bool = false,
    /// The application chose the icon theme, so the desktop's does not
    /// replace it.
    icon_theme_overridden: bool = false,
    /// The seat's key-repeat timing (platform.KeyRepeat); these defaults
    /// until the compositor reports it.
    key_repeat: platform.KeyRepeat = .{ .seat = 0, .delay_ms = 600, .rate = 25 },
    /// Receives session events (`startSession`).
    session_listener: SessionListener = .{},
    /// A press that dismissed popups (`dismissGrabs`): its release is
    /// dropped too.
    swallowed: ?struct { window: WindowId, button: u32 } = null,
    bridge: a11y.Bridge = undefined,
    /// The AT-SPI bridge runs on the session bus.
    accessible: bool = false,
    portals: portals.Portals = .{},
    lifecycle: lifecycle.Lifecycle = .{},
    app_id: platform.BoundedString(255) = .{},
    /// The application's language (interned in `fonts`) and direction,
    /// which windows follow unless they set their own (D21).
    language: u32 = 0,
    rtl: bool = false,
    /// An empty language is the process locale's; on the headless backend
    /// it stays empty, so tests do not depend on the environment.
    process_locale: bool = true,
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
            .icons = undefined,
            .clipboard = undefined,
            .comp = undefined,
            .reduced_motion = options.reduced_motion,
        };
        app.app_id.set(options.app_id);
        errdefer app.loop.deinit();
        app.pool = .init(&app.loop, gpa, if (options.threads != 0) options.threads else loop_mod.Pool.defaultThreadCount());
        errdefer app.pool.deinit();
        app.fonts = try .init(gpa);
        errdefer app.fonts.deinit();
        app.fonts.pool = &app.pool;
        app.icons = try .init(gpa, if (options.system_icons) ui.Icons.environment() else .{ .xdg_data_dirs = "", .pixmaps = false });
        errdefer app.icons.deinit();
        app.icons.pool = &app.pool;
        app.process_locale = options.backend != .headless;
        try app.applyLocale(options.language, options.rtl);
        if (options.system_fonts) app.fonts.database = text.fontconfig.Database.init() catch null;
        app.clipboard = .init(gpa, &app.loop, .{ .ctx = app, .set_selection = setSelection, .receive = receiveSelection });
        errdefer app.clipboard.deinit();
        // The bus handshake and the settings read proceed while the
        // compositor connects to Wayland below.
        // An application id means portals and D-Bus activation, on any
        // backend.
        if (options.desktop_settings or options.accessibility or options.bus_fd != null or options.app_id.len > 0) app.desktop.start(app, options.bus_address, options.bus_fd, options.desktop_settings, options.app_id);
        errdefer app.desktop.deinit(app);
        app.portals.start(app);
        errdefer app.portals.deinit(app);
        if (options.accessibility and app.desktop.connected) {
            app.bridge.init(gpa, &app.loop, .{ .app_name = options.name, .toolkit_version = options.toolkit_version, .language = app.fonts.name(app.language), .on_active = onAccessibilityActive, .ctx = app });
            if (app.bridge.start(&app.desktop.bus)) {
                app.accessible = true;
            } else |_| app.bridge.deinit();
        }
        errdefer if (app.accessible) app.bridge.deinit();
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
        if (app.accessible) {
            for (app.windows.items) |w| if (w) |win| app.bridge.removeWindow(win.a11y_id);
            app.bridge.deinit();
        }
        app.lifecycle.deinit(app);
        app.portals.deinit(app);
        app.desktop.deinit(app);
        for (app.windows.items) |w| if (w) |win| win.free();
        for (app.zombies.items) |win| win.free();
        app.windows.deinit(gpa);
        app.zombies.deinit(gpa);
        app.clipboard.deinit();
        app.fonts.deinit();
        app.pool.deinit();
        // Loads the pool dropped release into the icons.
        app.icons.deinit();
        app.loop.deinit();
        gpa.destroy(app);
    }

    /// Chooses the icon theme (D19); empty follows the desktop's again.
    pub fn setIconTheme(app: *App, name: []const u8) Error!void {
        app.icon_theme_overridden = name.len != 0;
        const desktop = if (app.desktop.reading) app.desktop.settings.values.icon_theme.slice() else "";
        try app.icons.setTheme(if (name.len != 0) name else desktop);
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

    /// Adds font data (copied): each face joins `family`, or the family
    /// its name table gives when `family` is empty, and queries match
    /// styles within the family (D13). Registered families take
    /// precedence over Fontconfig.
    pub fn addFont(app: *App, family: []const u8, bytes: []const u8) error{ OutOfMemory, InvalidFont }!void {
        return app.fonts.addFont(family, bytes);
    }

    /// Assistive technology started or stopped listening: windows publish
    /// their semantics while it listens.
    fn onAccessibilityActive(ctx: ?*anyopaque, active: bool) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        if (!active) return;
        for (app.windows.items) |w| if (w) |win| win.publish();
    }

    /// New theme choices for every window (D29).
    pub fn setTheme(app: *App, theme: *const ui.Theme) void {
        app.theme = theme.*;
        for (app.windows.items) |w| if (w) |win| win.ui.setTheme(&app.theme);
    }

    /// The palette windows resolve now, for work outside a window (text
    /// measured for canvases).
    pub fn palette(app: *const App) ui.theme.Palette {
        return ui.theme.resolve(&app.theme, app.desktop.values.themeInput());
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

    /// Single instance and D-Bus activation (lifecycle.zig).
    pub fn launch(app: *App, options: lifecycle.LaunchOptions, handler: lifecycle.Handler) lifecycle.Error!void {
        return lifecycle.launch(app, options, handler);
    }

    /// Registers (or replaces) the action `name`, which the desktop can
    /// invoke through notifications and D-Bus activation (portals.zig).
    pub fn addAction(app: *App, name: []const u8, action: portals.Action) Allocator.Error!void {
        const gop = try app.portals.registry.getOrPut(app.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = app.gpa.dupe(u8, name) catch |err| {
                app.portals.registry.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = action;
    }

    pub fn removeAction(app: *App, name: []const u8) void {
        const kv = app.portals.registry.fetchRemove(name) orelse return;
        app.gpa.free(kv.key);
    }

    /// Runs the action `name` if it is registered.
    pub fn invokeAction(app: *App, name: []const u8, target: []const u8, activation_token: []const u8) void {
        const a = app.portals.registry.get(name) orelse return;
        a.func(a.ctx, name, target, activation_token);
    }

    /// Resolves and keeps the application's language and direction.
    fn applyLocale(app: *App, language: []const u8, rtl: ?bool) Allocator.Error!void {
        var buf: [64]u8 = undefined;
        const lang = if (language.len > 0 or !app.process_locale) language else locale.processLanguage(&buf);
        app.language = try app.fonts.intern(lang);
        app.rtl = rtl orelse locale.isRtl(lang);
    }

    /// Changes the application's language (empty: the process locale's)
    /// and direction (null: the language's). Windows that follow the
    /// application lay out and shape their text again (D21).
    pub fn setLocale(app: *App, language: []const u8, rtl: ?bool) Allocator.Error!void {
        try app.applyLocale(language, rtl);
        if (app.accessible) app.bridge.setLanguage(app.fonts.name(app.language));
        for (app.windows.items) |w| if (w) |win| {
            if (win.follows_language) win.ui.setLanguage(app.fonts.name(app.language)) catch |err| return err;
            if (win.follows_direction) win.ui.setRtl(app.rtl);
        };
    }

    pub fn createWindow(app: *App, options: WindowOptions, listener: Listener) Error!*Window {
        const gpa = app.gpa;
        try app.zombies.ensureUnusedCapacity(gpa, 1);
        const win = try gpa.create(Window);
        errdefer gpa.destroy(win);
        const id = app.comp.createWindow(.{
            .title = options.title,
            .app_id = if (options.app_id.len > 0) options.app_id else app.app_id.slice(),
            .width = options.width,
            .height = options.height,
            .decoration = if (options.client_decorations) .client else .server,
            .parent = if (options.parent) |p| p.id else null,
            .modal = options.modal,
            .session_name = options.session_name,
        }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
        errdefer app.comp.destroyWindow(id) catch {};
        if (id >= app.windows.items.len) try app.windows.appendNTimes(gpa, null, id + 1 - app.windows.items.len);
        win.* = .{ .app = app, .id = id, .ui = undefined, .listener = listener, .drag = .{ .comp = app.comp, .window = id, .gpa = gpa }, .follows_language = options.language.len == 0, .follows_direction = options.rtl == null, .owner = options.parent, .modal = options.parent != null and options.modal };
        win.ui = try ui.Window.init(gpa, .{
            .fonts = &app.fonts,
            .icons = &app.icons,
            .sink = .{ .ctx = win, .commit = Window.commit },
            .host = .{ .ctx = win, .request_frame = Window.requestFrame, .text_input = Window.textInput, .set_cursor = Window.setCursor, .pointer_constraint = Window.pointerConstraint, .tooltip = Window.tooltip },
            .clipboard = &app.clipboard,
            .drag = win.drag.host(),
            .loop = &app.loop,
            .reduced_motion = app.reduced_motion,
            .desktop = app.desktop.values,
            .theme = app.theme,
            .width = @floatFromInt(options.width),
            .height = @floatFromInt(options.height),
            .rtl = options.rtl orelse app.rtl,
            .language = if (options.language.len > 0) options.language else app.fonts.name(app.language),
        });
        // The first frame waits for the icons it shows as long as it may
        // wait for the settings (D19).
        win.ui.icon_wait_until = Loop.now() + desktop_mod.first_frame_wait_ns;
        if (app.accessible) win.a11y_id = app.bridge.addWindow(win.ui, options.title) catch |err| blk: {
            app.fail(if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable);
            break :blk 0;
        };
        app.windows.items[id] = win;
        app.open_windows += 1;
        return win;
    }

    /// A popup of `parent` (D17): its own tree, shown with
    /// `Window.showPopup` once its content is built, so that it can size
    /// to it. Until then the compositor knows nothing of it.
    pub fn createPopup(app: *App, parent: *Window, listener: Listener) Error!*Window {
        const gpa = app.gpa;
        try app.zombies.ensureUnusedCapacity(gpa, 1);
        const win = try gpa.create(Window);
        errdefer gpa.destroy(win);
        win.* = .{ .app = app, .id = 0, .ui = undefined, .listener = listener, .drag = .{ .comp = app.comp, .window = 0, .gpa = gpa }, .parent = parent, .shown = false };
        win.ui = try ui.Window.init(gpa, .{
            .fonts = &app.fonts,
            .icons = &app.icons,
            .sink = .{ .ctx = win, .commit = Window.commit },
            .host = .{ .ctx = win, .request_frame = Window.requestFrame, .text_input = Window.textInput, .tooltip = Window.tooltip },
            .clipboard = &app.clipboard,
            .reduced_motion = app.reduced_motion,
            .desktop = app.desktop.values,
            .theme = app.theme,
            .width = 1,
            .height = 1,
            .scale = parent.ui.scale,
            .rtl = parent.ui.rtl,
            .language = app.fonts.name(parent.ui.language),
        });
        return win;
    }

    fn window(app: *App, id: ?WindowId) ?*Window {
        const i = id orelse return null;
        if (i >= app.windows.items.len) return null;
        return app.windows.items[i];
    }

    /// A press on a toplevel while popups over it hold a grab dismisses
    /// them, topmost first, and is not delivered (nor is its release).
    /// Compositors dismiss grabs only for clicks on other clients'
    /// surfaces; one on the application's own toplevel reaches it.
    fn dismissGrabs(app: *App, win: *Window, serial: u32) bool {
        if (win.parent != null) return false;
        var grabs: [16]*Window = undefined;
        var n: usize = 0;
        for (app.windows.items) |slot| if (slot) |w| {
            // Only presses after the one the grab was taken for.
            const after = @as(i32, @bitCast(serial -% w.grab_serial)) > 0;
            if (w.grab and after and w.shown and !w.closed and w.toplevel() == win and n < grabs.len) {
                grabs[n] = w;
                n += 1;
            }
        };
        if (n == 0) return false;
        std.mem.sort(*Window, grabs[0..n], {}, struct {
            fn deeper(_: void, a: *Window, b: *Window) bool {
                return a.depth() > b.depth();
            }
        }.deeper);
        for (grabs[0..n]) |w| {
            if (w.closed) continue;
            if (!w.notify(&.close_requested)) w.destroy() catch |err| app.fail(err);
        }
        return true;
    }

    /// Where keyboard input for `win` goes: the topmost grabbing popup
    /// over its toplevel, or `win` itself. xdg_popup says the topmost
    /// grabbing popup has keyboard focus, but some compositors (sway)
    /// keep sending keys to the toplevel during the grab, so they are
    /// redirected here, as GTK does.
    fn keyboardTarget(app: *App, win: *Window) *Window {
        const top = win.toplevel();
        var best = win;
        var best_depth: usize = 0;
        for (app.windows.items) |slot| if (slot) |w| {
            if (!w.grab or !w.shown or w.closed or w.toplevel() != top) continue;
            const depth = w.depth();
            if (depth > best_depth) {
                best = w;
                best_depth = depth;
            }
        };
        return best;
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

    fn receiveSelection(ctx: ?*anyopaque, seat: platform.SeatId, kind: platform.SelectionKind, prefs: []const []const u8, pipe_fd: i32) ?usize {
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
                    return;
                };
            }
        };
        var c: Ctx = .{ .seat = seat, .kind = kind, .prefs = prefs, .fd = pipe_fd };
        app.comp.call(&c, Ctx.run) catch {
            _ = std.os.linux.close(pipe_fd);
            return null;
        };
        return c.out;
    }

    /// Compositor events, in the UI loop's dispatch phase.
    fn onEvent(ctx: ?*anyopaque, ev: *const compositor.Event) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        // Selection and drag source events belong to the application,
        // not a window.
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
            .platform => |*p| if (blockedByModal(app, p)) {} else switch (p.*) {
                .failed => |err| app.fail(if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable),
                .exported => |e| if (app.window(e.window)) |win| portals.exported(win, e.handle.slice()),
                .activation_token => |t| if (app.window(t.window)) |win| portals.tokenArrived(win, t.request, t.token.slice()),
                .key_repeat => |r| app.key_repeat = r,
                .pointer_button => |b| if (app.window(b.window)) |win| {
                    if (b.pressed and app.dismissGrabs(win, b.serial)) {
                        app.swallowed = .{ .window = b.window, .button = b.button };
                        return;
                    }
                    if (!b.pressed) if (app.swallowed) |sw| if (sw.window == b.window and sw.button == b.button) {
                        app.swallowed = null;
                        return;
                    };
                    win.handle(ev);
                },
                .key, .modifiers => if (app.window(p.window())) |win| {
                    const target = app.keyboardTarget(win);
                    if (target == win) return win.handle(ev);
                    // The popup never got the keyboard's enter.
                    if (!target.ui.input.keyboard) target.handle(&.{ .platform = .{ .keyboard_enter = .{ .window = target.id, .seat = 0, .serial = 0 } } });
                    var moved = p.*;
                    switch (moved) {
                        .key => |*k| k.window = target.id,
                        .modifiers => |*m| m.window = target.id,
                        else => unreachable,
                    }
                    target.handle(&.{ .platform = moved });
                },
                .close_requested => |id| if (app.window(id)) |win| {
                    if (!win.notify(&.close_requested)) win.destroy() catch |err| app.fail(err);
                },
                .pointer_constraint => |c| if (app.window(c.window)) |win| {
                    if (c.ended) win.ui.pointerConstraintEnded();
                    _ = win.notify(&.{ .pointer_constraint = c });
                },
                .shortcuts_inhibit => |i| if (app.window(i.window)) |win| {
                    _ = win.notify(&.{ .shortcuts_inhibit = i.active });
                },
                .session => |e| if (app.session_listener.func) |f| f(app.session_listener.ctx, &e),
                .window_restored => |id| if (app.window(id)) |win| {
                    _ = win.notify(&.restored);
                },
                else => if (app.window(p.window())) |win| win.handle(ev),
            },
            .configure => |c| if (app.window(c.window)) |win| {
                const old = win.state;
                win.state = c.state;
                win.handle(ev);
                if (app.accessible and old.states.activated != c.state.states.activated) app.bridge.setActive(win.a11y_id, c.state.states.activated);
                if (!win.closed) _ = win.notify(&.{ .configure = .{ .old = old, .new = c.state } });
            },
            // First frames wait for the desktop settings (desktop.zig).
            .frame => |f| if (app.window(f.window)) |win| {
                if (app.desktop.waiting) win.frame_held = true else {
                    win.handle(ev);
                    win.publish();
                }
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
                _ = win.notify(&.{ .presented = .{ .seq = p.seq, .present_ns = p.present_ns, .commit_ns = p.commit_ns } });
            },
            else => if (app.window(ev.window())) |win| win.handle(ev),
        }
    }

    /// Input for a window with a shown modal dialog goes nowhere, on any
    /// compositor (D17); motion, focus, and modifiers still arrive.
    fn blockedByModal(app: *App, ev: *const platform.Event) bool {
        switch (ev.*) {
            .pointer_button, .key, .scroll, .touch_down, .touch_motion, .touch_up, .gesture, .tablet_tool, .tablet_pad, .text_input, .relative_motion => {},
            else => return false,
        }
        const win = app.window(ev.window()) orelse return false;
        const top = win.toplevel();
        for (app.windows.items) |w| if (w) |d| if (d.modal and !d.closed and d.owner == top) return true;
        return false;
    }

    /// Joins a session so that the compositor restores windows with a
    /// session name (D17); `listener` gets its events. See
    /// `platform.Platform.startSession`.
    pub fn startSession(app: *App, reason: platform.SessionReason, id: []const u8, listener: SessionListener) Allocator.Error!void {
        app.session_listener = listener;
        const Req = struct {
            reason: platform.SessionReason,
            id: []const u8,
            fn run(ctx: ?*anyopaque, comp: *Compositor) void {
                const r: *@This() = @ptrCast(@alignCast(ctx));
                comp.platform.startSession(r.reason, r.id);
            }
        };
        var r: Req = .{ .reason = reason, .id = id };
        try app.comp.call(&r, Req.run);
    }

    /// Leaves the session and has the compositor forget it.
    pub fn removeSession(app: *App) Allocator.Error!void {
        try app.comp.call(null, struct {
            fn run(_: ?*anyopaque, comp: *Compositor) void {
                comp.platform.removeSession();
            }
        }.run);
    }

    /// The icon sizes the compositor prefers, copied into `out`.
    pub fn iconSizes(app: *App, out: []u32) Allocator.Error![]u32 {
        const Req = struct {
            out: []u32,
            n: usize = 0,
            fn run(ctx: ?*anyopaque, comp: *Compositor) void {
                const r: *@This() = @ptrCast(@alignCast(ctx));
                const sizes = comp.platform.iconSizes();
                r.n = @min(sizes.len, r.out.len);
                @memcpy(r.out[0..r.n], sizes[0..r.n]);
            }
        };
        var r: Req = .{ .out = out };
        try app.comp.call(&r, Req.run);
        return out[0..r.n];
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
    /// Right to left; null follows the application's direction.
    rtl: ?bool = null,
    /// BCP 47 language of the window's text; empty follows the
    /// application's language.
    language: []const u8 = "",
    /// The window this one belongs to, as a dialog (D17): the compositor
    /// keeps it above that window.
    parent: ?*Window = null,
    /// With a parent: a modal dialog. The compositor may keep input from
    /// the parent (xdg-dialog-v1); siv does on every compositor.
    modal: bool = false,
    /// The window's name in the session (`App.startSession`), unique among
    /// the application's windows; empty keeps it out of the session.
    session_name: []const u8 = "",
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
    /// Everything committed up to `seq` reached the screen: predicted
    /// presentation and commit times on CLOCK_MONOTONIC.
    presented: struct { seq: u64, present_ns: u64, commit_ns: u64 },
    /// The compositor activated or deactivated the pointer constraint
    /// (D16); `ended` when it will not come back.
    pointer_constraint: platform.ConstraintState,
    /// The compositor passes its shortcuts to the window, or stopped.
    shortcuts_inhibit: bool,
    /// The compositor restored the window from the session, before its
    /// first configure.
    restored,
};

pub const SessionListener = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (ctx: ?*anyopaque, event: *const platform.SessionEvent) void = null,
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
    /// Drag-and-drop requests on the compositor thread.
    drag: ui.dnd.CompositorHost,
    /// As of the last configure.
    state: platform.WindowState = .{},
    closed: bool = false,
    /// A frame event arrived while the desktop settings were awaited.
    frame_held: bool = false,
    /// The window in the AT-SPI bridge, or 0.
    a11y_id: a11y.Bridge.WindowId = 0,
    /// The xdg-foreign export for portal dialogs (portals.zig).
    export_state: enum { none, pending, done } = .none,
    export_handle: platform.Handle = .{},
    parent_waiters: std.DoublyLinkedList = .{},
    token_waiters: std.DoublyLinkedList = .{},
    /// Last layer commit, and the last one presented.
    committed_seq: u64 = 0,
    presented_seq: u64 = 0,
    /// The window follows the application's language and direction
    /// (`App.setLocale`). Popups take their parent's when created.
    follows_language: bool = true,
    follows_direction: bool = true,
    /// Popups: the window they belong to.
    parent: ?*Window = null,
    /// False for a popup until `showPopup`.
    shown: bool = true,
    /// A popup shown with a grab: it takes its toplevel's keyboard input.
    grab: bool = false,
    /// The input serial the grab was taken for.
    grab_serial: u32 = 0,
    /// Dialogs: the window they belong to, and whether they are modal,
    /// which keeps input from it.
    owner: ?*Window = null,
    modal: bool = false,
    /// Tooltips (D17): the node asked for, the timer that shows it, the
    /// popup showing it, and when the last one hid (another shown soon
    /// after shows at once, as the user browses a toolbar).
    tooltip_node: ui.NodeId = .none,
    tooltip_timer: loop_mod.Timer = .{ .func = tooltipFire },
    tooltip_popup: ?*Window = null,
    tooltip_hid_ns: u64 = 0,
    /// A popup that shows a tooltip.
    is_tooltip: bool = false,

    /// How long the pointer rests or keyboard focus stays before a
    /// tooltip shows. The desktop settings portal has no such setting;
    /// this is GTK's.
    pub const tooltip_delay_ns: u64 = 500 * std.time.ns_per_ms;
    /// After a tooltip hides, others show without the delay this long.
    pub const tooltip_browse_ns: u64 = 1000 * std.time.ns_per_ms;

    fn toplevel(win: *Window) *Window {
        var w = win;
        while (w.parent) |p| w = p;
        return w;
    }

    fn depth(win: *Window) usize {
        var n: usize = 0;
        var w = win;
        while (w.parent) |p| : (n += 1) w = p;
        return n;
    }

    /// Destroys the window (see the module comment). On failure nothing
    /// changed. `win` stays valid until the loop runs again. Destroy a
    /// window's popups before it.
    pub fn destroy(win: *Window) Allocator.Error!void {
        if (win.closed) return;
        const app = win.app;
        try app.zombies.ensureUnusedCapacity(app.gpa, 1);
        app.loop.cancelTimer(&win.tooltip_timer);
        if (win.tooltip_popup) |p| {
            win.tooltip_popup = null;
            try p.destroy();
        }
        if (!win.shown) {
            win.closed = true;
            if (win.ui.txn.open) win.ui.txn.abort();
            app.zombies.appendAssumeCapacity(win);
            return;
        }
        try app.comp.destroyWindow(win.id);
        win.closed = true;
        // Dialogs that outlive it belong to nothing.
        for (app.windows.items) |w| if (w) |d| if (d.owner == win) {
            d.owner = null;
        };
        if (app.accessible) app.bridge.removeWindow(win.a11y_id);
        win.a11y_id = 0;
        if (win.ui.txn.open) win.ui.txn.abort();
        app.windows.items[win.id] = null;
        portals.windowClosed(win);
        app.zombies.appendAssumeCapacity(win);
        // Popups do not keep the application running.
        if (win.parent != null) return;
        app.open_windows -= 1;
        if (app.open_windows == 0) app.quit();
        // Not freed here even if its lists are home: the caller may still
        // use it (the C API tears down its handles after this returns).
    }

    pub const Placement = ui.Window.PopupPlacement;

    /// Shows a popup made by `App.createPopup`, anchored to a node of its
    /// parent. A zero width or height sizes it to its content, at most
    /// the parent's width. With `grab`, it takes the keyboard for the
    /// parent's last press or key, and a click outside dismisses it.
    /// `rect`, if set, is where in `anchor` to place the popup (x, y,
    /// width, height in the anchor's coordinates).
    pub fn showPopup(win: *Window, anchor: ui.NodeId, placement: Placement, width: u32, height: u32, grab: bool, rect: ?[4]f32) Error!void {
        const app = win.app;
        const parent = win.parent orelse return error.Unavailable;
        if (win.shown or win.closed or parent.closed or !parent.shown) return error.Busy;
        var w = width;
        var h = height;
        if (w == 0 or h == 0) {
            const sz = try win.ui.preferredSize(parent.ui.width);
            if (w == 0) w = @intFromFloat(@max(1, @ceil(sz.w)));
            if (h == 0) h = @intFromFloat(@max(1, @ceil(sz.h)));
        }
        const live = parent.ui.isLive(anchor);
        var pos = parent.ui.popupPositioner(if (live) anchor else .root, w, h, placement, if (live) rect else null);
        pos.reactive = true;
        const id = app.comp.createPopup(.{
            .parent = parent.id,
            .positioner = pos,
            .grab = if (grab) .{ .seat = parent.ui.input.seat, .serial = parent.ui.input.serial } else null,
            .input = placement != .tooltip,
        }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
        errdefer app.comp.destroyWindow(id) catch {};
        if (id >= app.windows.items.len) try app.windows.appendNTimes(app.gpa, null, id + 1 - app.windows.items.len);
        win.id = id;
        win.drag.window = id;
        win.shown = true;
        win.grab = grab;
        win.grab_serial = parent.ui.input.serial;
        app.windows.items[id] = win;
        if (app.accessible) win.a11y_id = app.bridge.addWindow(win.ui, "") catch 0;
        win.ui.configure(@floatFromInt(w), @floatFromInt(h), parent.ui.scale);
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
        if (win.closed or !win.shown) return;
        win.app.comp.requestFrame(win.id) catch win.app.fail(error.OutOfMemory);
    }

    /// Text input state for the input method (text-input-v3), set on the
    /// compositor thread in order with commits (D8). The request owns a
    /// copy of the surrounding text.
    fn textInput(ctx: ?*anyopaque, seat: platform.SeatId, state: *const platform.TextInputState) void {
        const win: *Window = @ptrCast(@alignCast(ctx));
        if (win.closed or !win.shown) return;
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

    /// Publishes the semantics tree after a frame, if assistive technology
    /// listens and it changed (D18).
    fn publish(win: *Window) void {
        const app = win.app;
        if (!app.accessible or win.a11y_id == 0 or win.closed) return;
        app.bridge.update(win.a11y_id) catch |err| app.fail(if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable);
    }

    pub fn setTitle(win: *Window, title: []const u8) Allocator.Error!void {
        if (win.app.accessible) win.app.bridge.setTitle(win.a11y_id, title) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Published with the next update.
            else => {},
        };
        try win.platformCall(struct {
            fn f(p: platform.Platform, id: WindowId, s: []const u8) void {
                p.setTitle(id, s);
            }
        }.f, title);
    }

    fn pointerConstraint(ctx: ?*anyopaque, options: platform.ConstraintOptions) void {
        const win: *Window = @ptrCast(@alignCast(ctx));
        if (win.closed) return;
        win.platformCall(platform.Platform.setPointerConstraint, options) catch win.app.fail(error.OutOfMemory);
    }

    /// Asks the compositor for every key, its shortcuts included, while
    /// the window has focus (D16); `shortcuts_inhibit` events follow.
    pub fn inhibitShortcuts(win: *Window, on: bool) Allocator.Error!void {
        try win.platformCall(platform.Platform.inhibitShortcuts, on);
    }

    /// Sets the toplevel's icon (D17): a theme name and square images,
    /// copied; null resets it. False when the compositor offers no
    /// toplevel icons.
    pub fn setIcon(win: *Window, icon: ?*const platform.ToplevelIcon) Allocator.Error!bool {
        if (win.closed or !win.shown) return false;
        const Req = struct {
            id: WindowId,
            icon: ?*const platform.ToplevelIcon,
            out: bool = false,
            fn run(ctx: ?*anyopaque, comp: *Compositor) void {
                const r: *@This() = @ptrCast(@alignCast(ctx));
                r.out = comp.platform.setIcon(r.id, r.icon);
            }
        };
        var r: Req = .{ .id = win.id, .icon = icon };
        try win.app.comp.call(&r, Req.run);
        return r.out;
    }

    /// Keeps the session from going idle while the window is visible
    /// (D17, idle-inhibit-unstable-v1), counted. False, changing nothing,
    /// when the compositor offers no idle inhibition.
    pub fn inhibitIdle(win: *Window, on: bool) Allocator.Error!bool {
        if (win.closed or !win.shown) return false;
        const Req = struct {
            id: WindowId,
            on: bool,
            out: bool = false,
            fn run(ctx: ?*anyopaque, comp: *Compositor) void {
                const r: *@This() = @ptrCast(@alignCast(ctx));
                r.out = comp.platform.inhibitIdle(r.id, r.on);
            }
        };
        var r: Req = .{ .id = win.id, .on = on };
        try win.app.comp.call(&r, Req.run);
        return r.out;
    }

    /// The tree asks for a node's tooltip, or for none (D17): hide what
    /// shows, then show the new one after the delay.
    fn tooltip(ctx: ?*anyopaque, node: ui.NodeId) void {
        const win: *Window = @ptrCast(@alignCast(ctx));
        if (win.closed or win.is_tooltip) return;
        const app = win.app;
        app.loop.cancelTimer(&win.tooltip_timer);
        const now = Loop.now();
        if (win.tooltip_popup) |p| {
            win.tooltip_popup = null;
            win.tooltip_hid_ns = now;
            p.destroy() catch |err| app.fail(err);
        }
        win.tooltip_node = node;
        if (node == .none) return;
        const browsing = win.tooltip_hid_ns != 0 and now - win.tooltip_hid_ns < tooltip_browse_ns;
        app.loop.startTimer(&win.tooltip_timer, if (browsing) now else now + tooltip_delay_ns, 0) catch app.fail(error.OutOfMemory);
    }

    fn tooltipFire(timer: *loop_mod.Timer) void {
        const win: *Window = @fieldParentPtr("tooltip_timer", timer);
        showTooltip(win) catch |err| switch (err) {
            // A compositor without popups, or a window not shown: no tooltip.
            error.Unavailable, error.Busy => {},
            else => win.app.fail(err),
        };
    }

    /// A tooltip popup (D17's tooltip placement, no grab) with the node's
    /// text in the theme's inverse colors, like a toast.
    fn showTooltip(win: *Window) Error!void {
        const node = win.tooltip_node;
        if (win.closed or !win.shown or node == .none or !win.ui.isLive(node)) return;
        const tip = win.ui.node(node).tooltip;
        if (tip.len == 0) return;
        const app = win.app;
        const popup = try app.createPopup(win, .{});
        popup.is_tooltip = true;
        errdefer popup.destroy() catch {};
        const t = popup.ui.begin() catch return error.OutOfMemory;
        build: {
            const card = t.create(.root, .box, .none) catch break :build;
            t.setLayout(card, .{ .max_width = 360, .padding = .{ .start = 8, .end = 8, .top = 4, .bottom = 4 } }) catch break :build;
            t.setVisual(card, .{ .background_token = .inverse_bg, .radius = .all(4) }) catch break :build;
            const label = t.create(card, .text, .none) catch break :build;
            t.setText(label, tip) catch break :build;
            t.setTextProps(label, .{ .style = .{ .color_token = .inverse_fg, .size_role = .caption } }) catch break :build;
            t.setSemantics(card, .{ .role = .tooltip }) catch break :build;
            t.commit();
            try popup.showPopup(node, .tooltip, 0, 0, false, null);
            win.tooltip_popup = popup;
            return;
        }
        t.abort();
        return error.OutOfMemory;
    }

    fn setCursor(ctx: ?*anyopaque, shape: ui.CursorShape) void {
        const win: *Window = @ptrCast(@alignCast(ctx));
        if (win.closed) return;
        win.platformCall(platform.Platform.setCursor, shape) catch win.app.fail(error.OutOfMemory);
    }

    /// Starts an interactive move of the window, for client-side
    /// decorations (D17), during the press that is still held.
    pub fn beginMove(win: *Window) Allocator.Error!void {
        const Arg = struct { seat: platform.SeatId, serial: u32 };
        try win.platformCall(struct {
            fn f(p: platform.Platform, id: WindowId, a: Arg) void {
                p.beginMove(id, a.seat, a.serial);
            }
        }.f, Arg{ .seat = win.ui.input.seat, .serial = win.ui.input.press_serial });
    }

    /// Starts an interactive resize from an edge, like `beginMove`.
    pub fn beginResize(win: *Window, edge: platform.Edge) Allocator.Error!void {
        const Arg = struct { seat: platform.SeatId, serial: u32, edge: platform.Edge };
        try win.platformCall(struct {
            fn f(p: platform.Platform, id: WindowId, a: Arg) void {
                p.beginResize(id, a.seat, a.serial, a.edge);
            }
        }.f, Arg{ .seat = win.ui.input.seat, .serial = win.ui.input.press_serial, .edge = edge });
    }

    /// Focuses the window with an xdg-activation token another
    /// application passed on (an activation's token); applied once the
    /// window is mapped.
    pub fn activate(win: *Window, token: []const u8) Allocator.Error!void {
        if (token.len == 0) return;
        try win.platformCall(struct {
            fn f(p: platform.Platform, id: WindowId, t: []const u8) void {
                p.activate(id, t);
            }
        }.f, token);
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
    pub fn platformRequest(win: *Window, comptime func: anytype, arg: anytype) Allocator.Error!void {
        return win.platformCall(func, arg);
    }

    fn platformCall(win: *Window, comptime func: anytype, arg: anytype) Allocator.Error!void {
        if (!win.shown) return;
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
