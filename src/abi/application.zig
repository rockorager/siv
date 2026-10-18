//! Exports for the application, its loop, and windows (D2, D5, D6). The
//! work is done by the coordinator (`app`); this file maps handles,
//! descriptors, and C callbacks onto it.
//!
//! Callback rules every export follows:
//!
//! - Node and window callbacks run with `App.depth` raised. While it is
//!   nonzero, destroy-notifies are queued (`release`) and run when the
//!   outermost callback returns, so a callback's own user data is never
//!   released while it runs, even if it replaces its handler or destroys
//!   its window.
//! - A window destroyed during a callback keeps its `Window` record (marked
//!   dead, so later events skip it) until then too.

const std = @import("std");
const t = @import("siv");
const app_mod = @import("app");
const ui = @import("ui");
const platform = @import("platform");
const api = @import("api.zig");
const build_options = @import("build_options");
const runtime = @import("runtime.zig");
const alloc = @import("alloc.zig");
const tree = @import("tree.zig");
const canvas = @import("canvas.zig");
const external = @import("external.zig");
const loop_mod = @import("loop");
const portal = @import("portal.zig");
const watch = @import("watch.zig");
const shell = @import("shell.zig");
const dbus_abi = @import("dbus.zig");
const settings = @import("settings.zig");
const actions = @import("actions.zig");

const Root = runtime.Root;

pub const Error = runtime.Error || error{ Busy, Unavailable };

const toolkit_version = std.fmt.comptimePrint("{d}.{d}.{d}", .{ build_options.version.major, build_options.version.minor, build_options.version.patch });

pub const app_tag = api.spec.handleTag("siv_app");
pub const window_tag = api.spec.handleTag("siv_window");
pub const txn_tag = api.spec.handleTag("siv_txn");
pub const node_tag = api.spec.handleTag("siv_node");
pub const timer_tag = api.spec.handleTag("siv_timer");

/// Windows per application: a node handle's payload holds the window's
/// index in its top bits (see tree.zig).
pub const max_windows = 1 << 10;

pub fn wrap(r: Error!void) t.Result {
    r catch |err| return t.resultOf(err);
    return .ok;
}

pub const Release = struct { func: t.DestroyFn, user_data: ?*anyopaque };

pub const App = struct {
    root: Root,
    app: *app_mod.App,
    /// By window index (handle payload); null slots are reused.
    windows: std.ArrayList(?*Window),
    /// Nesting of node and window callbacks.
    depth: u32,
    /// siv_app_destroy was called from a callback: the application goes
    /// when the dispatch running it returns.
    destroy_requested: bool,
    /// Destroy-notifies waiting for `depth` to reach zero.
    pending: std.ArrayList(Release),
    /// Windows destroyed while `depth` was nonzero.
    dead: std.ArrayList(*Window),
    /// Nesting of canvas measure and draw callbacks, during which the tree
    /// must not change.
    painting: u32,
    draw: canvas.DrawState,
    /// By image index (handle payload); null slots are reused.
    images: std.ArrayList(?*ui.Image),
    waiting: std.ArrayList(canvas.Waiting),
    /// External slots, which other threads use too (external.zig).
    externals: external.Slots,
    /// Set before the root is retired, for calls that pin it through an
    /// object handle (`Root.pinOwner`).
    closing: std.atomic.Value(bool),
    /// By timer index (handle payload); null slots are reused.
    timers: std.ArrayList(?*Timer),
    /// By watch index (handle payload); null slots are reused.
    watches: std.ArrayList(?*watch.Watch),
    prepares: std.ArrayList(?*watch.Prepare),
    /// Pending image loads by index (handle payload); null slots are
    /// reused. The pool owns them until they complete or are dropped.
    image_requests: std.ArrayList(?*@import("image_load.zig").Request),
    /// Portal requests and choosers (D19).
    desktop: portal.State,
    /// Actions and their accelerators (D34).
    actions: actions.State,
    /// siv_job_start jobs not yet done or dropped, for siv_test_settle.
    jobs: u32,
    /// Outputs, layer windows, the lock, toplevels, workspaces, and idle
    /// watches (D31).
    shell: shell.State,
    /// Public D-Bus connections and what was made on them (D19).
    dbus: dbus_abi.State,
    /// Open EPUB publications (D32), by handle payload.
    epubs: std.ArrayList(?*@import("document.zig").Epub),
    /// Undo stacks (D35), by handle payload; null slots are reused.
    undos: std.ArrayList(?*@import("undo.zig").Stack),
    /// Settings stores (D36).
    settings: settings.State,
    /// On the headless backend, stores without a directory keep values in
    /// memory only (D36).
    headless: bool,
    /// Tells the windows that fonts finished loading, once for a burst of
    /// loads.
    fonts_task: loop_mod.Loop.Task,

    pub fn gpa(self: *App) std.mem.Allocator {
        return self.root.gpa;
    }

    /// Runs a destroy-notify now, or when no callback is running.
    pub fn release(self: *App, func: ?t.DestroyFn, user_data: ?*anyopaque) void {
        const f = func orelse return;
        if (self.depth == 0) return f(user_data);
        // Without memory to queue it, releasing early beats leaking.
        self.pending.append(self.gpa(), .{ .func = f, .user_data = user_data }) catch f(user_data);
    }

    pub fn enter(self: *App) void {
        self.depth += 1;
    }

    pub fn leave(self: *App) void {
        self.depth -= 1;
        if (self.depth != 0) return;
        while (self.pending.pop()) |r| r.func(r.user_data);
        while (self.dead.pop()) |w| w.free();
    }

    pub fn get(handle: u64) Error!*App {
        return Root.get(App, app_tag, handle);
    }

    /// The window an object handle (window or txn) names.
    pub fn window(handle: u64, tag: u8) Error!*Window {
        const self, const index = try Root.owner(App, app_tag, handle, tag);
        return self.windows.items[index] orelse error.InvalidHandle;
    }
};

/// A siv_timer: one loop timer and its C callback.
pub const Timer = struct {
    timer: loop_mod.Timer = .{ .func = fire },
    owner: *App,
    index: u32,
    handle: u64,
    callback: t.PostFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn fire(lt: *loop_mod.Timer) void {
        const tm: *Timer = @fieldParentPtr("timer", lt);
        const self = tm.owner;
        tm.forget();
        self.enter();
        tm.callback(tm.user_data);
        self.leave();
        self.release(tm.destroy, tm.user_data);
        self.gpa().destroy(tm);
    }

    fn forget(tm: *Timer) void {
        const self = tm.owner;
        _ = self.root.handles.remove(tm.handle, timer_tag) catch unreachable;
        self.timers.items[tm.index] = null;
    }

    /// Cancelled, or dropped with the application.
    fn cancel(tm: *Timer) void {
        const self = tm.owner;
        self.app.loop.cancelTimer(&tm.timer);
        tm.forget();
        self.release(tm.destroy, tm.user_data);
        self.gpa().destroy(tm);
    }
};

pub const Window = struct {
    owner: *App,
    index: u32,
    handle: u64,
    win: *app_mod.Window,
    dead: bool = false,
    on_event: ?t.WindowEventFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    nodes: tree.Nodes = .{},
    txn: tree.TxnState = .{},
    /// Popups: the window they belong to, and how siv_popup_show places
    /// them.
    parent: ?*Window = null,
    popup: Popup = .{},
    /// Native dialogs: the window they belong to (siv_window_desc.parent),
    /// destroyed with it.
    dialog_parent: ?*Window = null,
    /// Bumped by each siv_window_set_icon, so icon loads still on the way
    /// for an older one are dropped.
    icon_generation: u32 = 0,
    /// Where the window keeps its size and states (D36).
    settings: ?settings.Binding = null,

    pub const Popup = struct {
        anchor: ui.NodeId = .root,
        placement: app_mod.Window.Placement = .below,
        width: u32 = 0,
        height: u32 = 0,
        grab: bool = true,
        /// SIV_POPUP_AT_RECT: x, y, width, height in the anchor.
        rect: ?[4]f32 = null,
    };

    /// Destroys the window after its popups, which go first (D17).
    pub fn destroyTree(w: *Window) app_mod.Error!void {
        for (w.owner.windows.items) |slot| if (slot) |child| if (child.parent == w or child.dialog_parent == w) try child.destroyTree();
        if (w.dead) return;
        w.win.destroy() catch return error.OutOfMemory;
        w.teardown();
    }

    pub fn uiWin(w: *Window) *ui.Window {
        return w.win.ui;
    }

    fn free(w: *Window) void {
        const gpa = w.owner.gpa();
        if (w.settings) |*b| b.deinit(gpa);
        w.nodes.deinit(gpa);
        w.txn.deinit(gpa);
        gpa.destroy(w);
    }

    /// Everything but the platform window: the open transaction, handles,
    /// and callbacks. The window must already be destroyed in `app`.
    fn teardown(w: *Window) void {
        const self = w.owner;
        // Its actions first, so that nothing waits for the transaction
        // aborted next.
        actions.forgetWindow(w);
        tree.abortState(w);
        w.nodes.releaseAll(w);
        external.forgetWindow(w);
        _ = self.root.handles.remove(w.handle, window_tag) catch unreachable;
        self.windows.items[w.index] = null;
        self.release(w.destroy, w.user_data);
        w.dead = true;
        if (self.depth == 0) {
            w.free();
        } else {
            self.dead.append(self.gpa(), w) catch {
                // Freed with the application instead: nothing refers to
                // it once callbacks return, but it may still be on the
                // stack now.
            };
        }
    }
};

fn mapAppError(err: app_mod.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unavailable => error.Unavailable,
        error.Busy => error.Busy,
        error.Unsupported => error.Unsupported,
    };
}

// The application -------------------------------------------------------------

pub export fn siv_app_create(desc: ?*const t.AppDesc, app: ?*t.App) t.Result {
    return wrap(appCreate(desc, app));
}

fn appCreate(desc_ptr: ?*const t.AppDesc, out: ?*t.App) Error!void {
    const desc = try runtime.readDesc(t.AppDesc, desc_ptr);
    const hooks = if (desc.allocator) |a| try alloc.fromDesc(try runtime.readDesc(t.Allocator, a)) else null;
    const display = try runtime.string(desc.display, desc.display_len);
    if (std.mem.indexOfScalar(u8, display, 0) != null) return error.InvalidArgument;
    const backend = try runtime.enumValue(t.Backend, desc.backend);
    const flags = try runtime.flags(t.AppFlags, desc.flags);
    const name = try runtime.string(desc.name, desc.name_len);
    const app_id = try runtime.string(desc.app_id, desc.app_id_len);
    const language = try runtime.string(desc.language, desc.language_len);
    if (flags.ltr and flags.rtl) return error.InvalidArgument;
    const dest = try runtime.out(t.App, out);

    const self = try Root.create(App, app_tag, hooks);
    errdefer Root.destroy(App, self);
    self.windows = .empty;
    self.depth = 0;
    self.destroy_requested = false;
    self.pending = .empty;
    self.dead = .empty;
    self.painting = 0;
    self.images = .empty;
    self.waiting = .empty;
    self.externals = .{};
    self.closing = .init(false);
    self.timers = .empty;
    self.watches = .empty;
    self.prepares = .empty;
    self.image_requests = .empty;
    self.desktop = .{};
    self.actions = .{};
    self.dbus = .{};
    self.jobs = 0;
    self.shell = .{};
    self.epubs = .empty;
    self.undos = .empty;
    self.settings = .{};
    self.headless = backend == .headless;
    self.fonts_task = .{ .func = onFontsTask };
    const gpa = self.gpa();
    self.draw = .init(gpa);
    errdefer self.draw.deinit(gpa);
    const display_z: ?[:0]u8 = if (display.len == 0) null else try gpa.dupeSentinel(u8, display, 0);
    defer if (display_z) |d| gpa.free(d);
    self.app = app_mod.App.create(gpa, .{
        .backend = switch (backend) {
            .wayland => .wayland,
            .headless => .headless,
            _ => unreachable,
        },
        .display = if (display_z) |d| d.ptr else null,
        .system_fonts = !flags.no_system_fonts,
        .system_icons = !flags.no_system_icons,
        .reduced_motion = flags.reduced_motion,
        .desktop_settings = backend == .wayland and !flags.no_desktop_settings,
        // SIV_THEME's file applies on any backend; the user's files only
        // where the desktop's settings do.
        .user_theme = .{ .lookup = backend == .wayland and !flags.no_desktop_settings },
        .follow_fontconfig = backend == .wayland and !flags.no_desktop_settings,
        // Mandatory on a display (D18); the headless backend stays
        // independent of the desktop.
        .accessibility = backend == .wayland,
        .name = name,
        .toolkit_version = toolkit_version,
        .app_id = app_id,
        .language = language,
        .rtl = if (flags.rtl) true else if (flags.ltr) false else null,
    }) catch |err| return mapAppError(err);
    errdefer self.app.destroy();
    try self.app.fonts.addListener(.{ .ctx = self, .func = onFontsLoaded });
    // Canvases and pages that drew while icons loaded draw again too.
    try self.app.icons.addListener(.{ .ctx = self, .func = canvas.onFontsLoaded });
    shell.start(self);
    dest.* = @fromBackingInt(self.root.handle);
}

/// Fonts finished loading: canvases draw again, and the windows hear of
/// it at the next dispatch, since text measured before may measure
/// differently now.
fn onFontsLoaded(ctx: *anyopaque) void {
    canvas.onFontsLoaded(ctx);
    const self: *App = @ptrCast(@alignCast(ctx));
    self.app.loop.schedule(&self.fonts_task, .dispatch);
}

fn onFontsTask(task: *loop_mod.Loop.Task) void {
    const self: *App = @fieldParentPtr("fonts_task", task);
    for (self.windows.items) |slot| {
        const w = slot orelse continue;
        if (w.dead) continue;
        const cb = w.on_event orelse continue;
        var e = windowEvent(.fonts_changed, w.win.state);
        self.enter();
        defer self.leave();
        _ = cb(w.user_data, @fromBackingInt(w.handle), &e);
    }
}

pub export fn siv_app_destroy(app: t.App) void {
    const self = App.get(@backingInt(app)) catch return;
    if (self.depth != 0 or self.app.loop.isDispatching()) {
        // From a callback: once the dispatch running it returns, which
        // siv_app_run does at once.
        self.destroy_requested = true;
        self.app.quit();
        return;
    }
    destroyNow(self);
}

fn destroyNow(self: *App) void {
    // From here no thread can post or submit, and every handle is
    // invalid.
    self.closing.store(true, .seq_cst);
    self.root.retire();
    // Before the windows, whose destruction would start waiting requests.
    portal.teardown(self);
    actions.teardown(self);
    dbus_abi.teardown(self);
    for (self.windows.items) |slot| if (slot) |w| {
        w.destroyTree() catch {};
    };
    shell.teardown(self);
    @import("document.zig").teardown(self);
    @import("undo.zig").teardown(self);
    // The coordinator writes what the stores have left (app.destroy).
    settings.teardown(self);
    const gpa = self.gpa();
    for (self.timers.items) |slot| if (slot) |tm| tm.cancel();
    self.timers.deinit(gpa);
    for (self.watches.items) |slot| if (slot) |w| w.remove();
    self.watches.deinit(gpa);
    for (self.prepares.items) |slot| if (slot) |p| p.remove();
    self.prepares.deinit(gpa);
    self.app.fonts.removeListener(self);
    self.app.loop.unschedule(&self.fonts_task);
    for (self.images.items) |img| if (img) |i| i.release();
    // Runs the destroy-notify of posted work that never ran (D5).
    self.app.destroy();
    // Dropped loads forgot their handles in app.destroy.
    self.image_requests.deinit(gpa);
    while (self.dead.pop()) |w| w.free();
    self.windows.deinit(gpa);
    self.pending.deinit(gpa);
    self.dead.deinit(gpa);
    self.draw.deinit(gpa);
    self.images.deinit(gpa);
    self.waiting.deinit(gpa);
    self.externals.deinit(gpa);
    Root.destroy(App, self);
    return;
}

pub export fn siv_app_get_fd(app: t.App, fd: ?*i32) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const dest = runtime.out(i32, fd) catch |err| return t.resultOf(err);
    dest.* = self.app.fd();
    return .ok;
}

pub export fn siv_app_dispatch(app: t.App, timeout_ms: i32) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    if (self.depth != 0) return .error_busy;
    defer if (self.destroy_requested) destroyNow(self);
    self.app.dispatch(timeout_ms) catch |err| return t.resultOf(mapAppError(err));
    return .ok;
}

pub export fn siv_app_run(app: t.App) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    if (self.depth != 0) return .error_busy;
    defer if (self.destroy_requested) destroyNow(self);
    self.app.run() catch |err| return t.resultOf(mapAppError(err));
    return .ok;
}

pub export fn siv_app_quit(app: t.App) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    self.app.quit();
    return .ok;
}

pub export fn siv_post(app: t.App, callback: ?t.PostFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const cb = callback orelse return .error_invalid_argument;
    // The pin keeps the application from being torn down while the
    // closure is queued; siv_app_destroy waits for it.
    const self = Root.pin(App, app_tag, @backingInt(app)) catch |err| return t.resultOf(err);
    defer Root.unpin(@backingInt(app));
    self.app.post(cb, destroy, user_data) catch return .error_out_of_memory;
    return .ok;
}

pub export fn siv_app_add_font(app: t.App, family: ?[*]const u8, family_len: usize, data: ?[*]const u8, data_count: usize) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const name = runtime.string(family, family_len) catch |err| return t.resultOf(err);
    const bytes = runtime.array(u8, data, data_count) catch |err| return t.resultOf(err);
    self.app.addFont(name, bytes) catch |err| return switch (err) {
        error.OutOfMemory => .error_out_of_memory,
        error.InvalidFont => .error_invalid_argument,
    };
    return .ok;
}

pub export fn siv_app_get_font_family(app: t.App, family: ?[*]const u8, family_len: usize, id: ?*u32) t.Result {
    return wrap(struct {
        fn f(a: t.App, p: ?[*]const u8, n: usize, out: ?*u32) Error!void {
            const self = try App.get(@backingInt(a));
            const name = try runtime.string(p, n);
            const dest = try runtime.out(u32, out);
            dest.* = try self.app.fonts.intern(name);
        }
    }.f(app, family, family_len, id));
}

pub export fn siv_app_get_font_family_name(app: t.App, id: u32, name: ?[*]u8, name_cap: usize, len: ?*usize) t.Result {
    return wrap(struct {
        fn f(a: t.App, i: u32, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const self = try App.get(@backingInt(a));
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const fonts = &self.app.fonts;
            if (i >= fonts.names.count()) return error.InvalidArgument;
            const s = fonts.name(i);
            const k = @min(s.len, buf.len);
            @memcpy(buf[0..k], s[0..k]);
            dest.* = s.len;
        }
    }.f(app, id, name, name_cap, len));
}

pub export fn siv_app_add_hyphenation(app: t.App, desc: ?*const t.HyphenationDesc) t.Result {
    return wrap(struct {
        fn f(a: t.App, d_ptr: ?*const t.HyphenationDesc) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.HyphenationDesc, d_ptr);
            const language = try runtime.string(d.language, d.language_len);
            if (d.left_min > 32 or d.right_min > 32) return error.InvalidArgument;
            self.app.fonts.hyphenation.add(
                language,
                try runtime.string(d.patterns, d.patterns_len),
                try runtime.string(d.exceptions, d.exceptions_len),
                if (d.left_min == 0) 2 else @intCast(d.left_min),
                if (d.right_min == 0) 3 else @intCast(d.right_min),
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidPatterns => error.InvalidArgument,
            };
        }
    }.f(app, desc));
}

pub export fn siv_app_set_default_font(app: t.App, family: ?[*]const u8, family_len: usize) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const name = runtime.string(family, family_len) catch |err| return t.resultOf(err);
    self.app.setDefaultFont(name) catch return .error_out_of_memory;
    return .ok;
}

pub export fn siv_app_get_default_font(app: t.App, name: ?[*]u8, name_cap: usize, len: ?*usize) t.Result {
    return wrap(struct {
        fn f(a: t.App, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const self = try App.get(@backingInt(a));
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const fonts = &self.app.fonts;
            const s = fonts.name(fonts.default_family);
            const k = @min(s.len, buf.len);
            @memcpy(buf[0..k], s[0..k]);
            dest.* = s.len;
        }
    }.f(app, name, name_cap, len));
}

pub export fn siv_app_has_fonts(app: t.App, has_fonts: ?*bool) t.Result {
    return wrap(struct {
        fn f(a: t.App, out: ?*bool) Error!void {
            const self = try App.get(@backingInt(a));
            const dest = try runtime.out(bool, out);
            dest.* = try self.app.fonts.hasFonts();
        }
    }.f(app, has_fonts));
}

pub export fn siv_app_set_language(app: t.App, language: ?[*]const u8, language_len: usize, direction: t.Direction) t.Result {
    return wrap(struct {
        fn f(a: t.App, p: ?[*]const u8, n: usize, d: t.Direction) Error!void {
            const self = try App.get(@backingInt(a));
            const lang = try runtime.string(p, n);
            const dir = try runtime.enumValue(t.Direction, d);
            if (std.mem.indexOfScalar(u8, lang, 0) != null) return error.InvalidArgument;
            try self.app.setLocale(lang, switch (dir) {
                .ltr => false,
                .rtl => true,
                else => null,
            });
        }
    }.f(app, language, language_len, direction));
}

pub export fn siv_app_is_rtl(app: t.App, rtl: ?*bool) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const dest = runtime.out(bool, rtl) catch |err| return t.resultOf(err);
    dest.* = self.app.rtl;
    return .ok;
}

pub export fn siv_app_get_key_repeat(app: t.App, delay_ms: ?*u32, interval_ms: ?*u32) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const delay = runtime.out(u32, delay_ms) catch |err| return t.resultOf(err);
    const interval = runtime.out(u32, interval_ms) catch |err| return t.resultOf(err);
    const r = self.app.key_repeat;
    delay.* = r.delay_ms;
    // At least 1 ms: a rate above 1000 cannot repeat faster than that.
    interval.* = if (r.rate == 0) 0 else @max(1000 / r.rate, 1);
    return .ok;
}

pub export fn siv_app_get_reduced_motion(app: t.App, reduced_motion: ?*bool) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const dest = runtime.out(bool, reduced_motion) catch |err| return t.resultOf(err);
    dest.* = self.app.reduced_motion or self.app.desktop.values.reduced_motion;
    return .ok;
}

pub export fn siv_app_get_double_click_time(app: t.App, time_ms: ?*u32) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const dest = runtime.out(u32, time_ms) catch |err| return t.resultOf(err);
    dest.* = self.app.desktop.values.double_click_ms;
    return .ok;
}

pub export fn siv_app_get_caret_blink(app: t.App, cycle_ms: ?*u32) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const dest = runtime.out(u32, cycle_ms) catch |err| return t.resultOf(err);
    const d = self.app.desktop.values;
    dest.* = if (self.app.reduced_motion or d.reduced_motion or !d.cursor_blink) 0 else d.cursor_blink_ms;
    return .ok;
}

// Windows ---------------------------------------------------------------------

pub export fn siv_window_create(app: t.App, desc: ?*const t.WindowDesc, window: ?*t.Window) t.Result {
    return wrap(windowCreate(app, desc, window));
}

fn windowCreate(app: t.App, desc_ptr: ?*const t.WindowDesc, out: ?*t.Window) Error!void {
    const self = try App.get(@backingInt(app));
    if (self.painting != 0) return error.Busy;
    const desc = try runtime.readDesc(t.WindowDesc, desc_ptr);
    const title = try runtime.string(desc.title, desc.title_len);
    const app_id = try runtime.string(desc.app_id, desc.app_id_len);
    const language = try runtime.string(desc.language, desc.language_len);
    const flags = try runtime.flags(t.WindowFlags, desc.flags);
    if (flags.ltr and flags.rtl) return error.InvalidArgument;
    const initial = try runtime.flags(t.WindowStates, desc.states);
    const session_name = try runtime.string(desc.session_name, desc.session_name_len);
    if (session_name.len > 255 or std.mem.indexOfScalar(u8, session_name, 0) != null) return error.InvalidArgument;
    // A dialog's parent: a toplevel of this application.
    const parent: ?*Window = if (desc.parent == .null) null else blk: {
        const pw = try App.window(@backingInt(desc.parent), window_tag);
        if (pw.owner != self or pw.dead or pw.parent != null) return error.InvalidArgument;
        break :blk pw;
    };
    // Another application's window, by its xdg-foreign handle; other
    // kinds of handles (x11:) leave the window without a parent.
    const parent_handle = try runtime.string(desc.parent_handle, desc.parent_handle_len);
    if (parent_handle.len > 255 or std.mem.indexOfScalar(u8, parent_handle, 0) != null) return error.InvalidArgument;
    const foreign_parent: []const u8 = if (parent != null) "" else if (std.mem.startsWith(u8, parent_handle, "wayland:")) parent_handle["wayland:".len..] else if (std.mem.indexOfScalar(u8, parent_handle, ':') != null) "" else parent_handle;
    if (flags.modal and parent == null and parent_handle.len == 0) return error.InvalidArgument;
    const dest = try runtime.out(t.Window, out);
    // A store's size and states win over the descriptor's (D36).
    var binding = try settings.Binding.fromDesc(self, &desc);
    errdefer if (binding) |*b| b.deinit(self.gpa());
    var size: [2]u32 = .{ if (desc.width == 0) 640 else desc.width, if (desc.height == 0) 480 else desc.height };
    var maximized = initial.maximized;
    var fullscreen = initial.fullscreen;
    if (binding) |*b| b.restore(&size, &maximized, &fullscreen, .{ desc.min_width, desc.min_height }, .{ desc.max_width, desc.max_height });

    const w = try newWindow(self, .{
        .title = title,
        .app_id = app_id,
        .width = size[0],
        .height = size[1],
        .client_decorations = flags.client_decorations,
        .rtl = if (flags.rtl) true else if (flags.ltr) false else null,
        .language = language,
        .parent = if (parent) |pw| pw.win else null,
        .foreign_parent = foreign_parent,
        .modal = flags.modal,
        .session_name = session_name,
    }, .{ .on_event = desc.on_event, .destroy = desc.destroy, .user_data = desc.user_data, .dialog_parent = parent });
    errdefer {
        // The window's destroy-notify is the caller's to run on failure.
        w.destroy = null;
        w.destroyTree() catch {};
    }
    if (desc.min_width != 0 or desc.min_height != 0 or desc.max_width != 0 or desc.max_height != 0) {
        try w.win.setSizeLimits(.{ .width = desc.min_width, .height = desc.min_height }, .{ .width = desc.max_width, .height = desc.max_height });
    }
    if (maximized) try w.win.setMaximized(true);
    if (fullscreen) try w.win.setFullscreen(true);
    w.settings = binding;
    binding = null;
    dest.* = @fromBackingInt(w.handle);
}

/// A window's callbacks, for `newWindow`.
pub const Callbacks = struct {
    on_event: ?t.WindowEventFn = null,
    destroy: ?t.DestroyFn = null,
    user_data: ?*anyopaque = null,
    dialog_parent: ?*Window = null,
};

/// Creates a window of any role in the coordinator with its handle, its
/// root node's handle, and its callbacks. On failure nothing is left.
pub fn newWindow(self: *App, options: app_mod.WindowOptions, cb: Callbacks) Error!*Window {
    const gpa = self.gpa();
    const index: u32 = for (self.windows.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        if (self.windows.items.len >= max_windows) return error.LimitExceeded;
        try self.windows.append(gpa, null);
        break :blk @intCast(self.windows.items.len - 1);
    };
    const w = try gpa.create(Window);
    errdefer gpa.destroy(w);
    w.* = .{ .owner = self, .index = index, .handle = 0, .win = undefined, .on_event = cb.on_event, .destroy = cb.destroy, .user_data = cb.user_data, .dialog_parent = cb.dialog_parent };
    errdefer w.nodes.deinit(gpa);
    try w.nodes.reserve(gpa, 1);
    try self.root.handles.ensureUnusedCapacity(gpa);
    w.handle = try self.root.handles.insert(gpa, window_tag, index);
    errdefer _ = self.root.handles.remove(w.handle, window_tag) catch unreachable;
    try self.root.handles.ensureUnusedCapacity(gpa);
    w.win = self.app.createWindow(options, .{ .ctx = w, .func = onWindowEvent }) catch |err| return mapAppError(err);
    // Nothing below fails.
    w.nodes.adopt(self, w, .root) catch unreachable;
    actions.attach(w);
    self.windows.items[index] = w;
    return w;
}

fn onWindowEvent(ctx: ?*anyopaque, _: *app_mod.Window, ev: *const app_mod.WindowEvent) bool {
    const w: *Window = @ptrCast(@alignCast(ctx));
    if (w.dead) return true;
    const self = w.owner;
    const handle: t.Window = @fromBackingInt(w.handle);
    switch (ev.*) {
        .close_requested => {
            const kept = if (w.on_event) |cb| blk: {
                var e = windowEvent(.close_requested, w.win.state);
                self.enter();
                defer self.leave();
                break :blk cb(w.user_data, handle, &e);
            } else false;
            // Unhandled: destroyed here, like siv_window_destroy, so that
            // handles and callbacks go with it. Without memory to do so the
            // window stays open.
            if (!kept and !w.dead) w.destroyTree() catch return true;
            return true;
        },
        .configure => |c| {
            // Frame slots follow the window's states too (a web page's
            // focus), after the window's own callback.
            defer if (states(c.old.states) != states(c.new.states) and !w.dead) external.deliverAll(w, .{ .type = .states_changed });
            if (w.settings) |*b| b.save(c.new);
            const cb = w.on_event orelse return false;
            self.enter();
            defer self.leave();
            if (c.old.width != c.new.width or c.old.height != c.new.height) {
                var e = windowEvent(.resized, c.new);
                _ = cb(w.user_data, handle, &e);
            }
            if (c.old.scale.v120 != c.new.scale.v120 and !w.dead) {
                var e = windowEvent(.scale_changed, c.new);
                _ = cb(w.user_data, handle, &e);
            }
            if (states(c.old.states) != states(c.new.states) and !w.dead) {
                var e = windowEvent(.states_changed, c.new);
                _ = cb(w.user_data, handle, &e);
            }
            return false;
        },
        .external_released => |x| {
            external.deliver(w, x.id, .{ .type = .released, .key = x.key });
            return false;
        },
        .external_presented => |x| {
            external.deliver(w, x.id, .{ .type = .presented, .key = x.key, .present_ns = x.present_ns });
            return false;
        },
        .external_visibility => |x| {
            external.deliver(w, x.id, .{ .type = if (x.visible) .shown else .hidden });
            return false;
        },
        .external_frame => |x| {
            external.deliver(w, x.id, .{ .type = .frame, .present_ns = x.present_ns });
            return false;
        },
        .presented => |p| {
            const cb = w.on_event orelse return false;
            var e = windowEvent(.presented, w.win.state);
            e.frame = p.seq;
            e.present_ns = p.present_ns;
            e.commit_ns = p.commit_ns;
            self.enter();
            defer self.leave();
            _ = cb(w.user_data, handle, &e);
            return false;
        },
        .closed => {
            if (w.on_event) |cb| {
                var e = windowEvent(.closed, w.win.state);
                self.enter();
                defer self.leave();
                _ = cb(w.user_data, handle, &e);
            }
            // The coordinator destroys it next; the handles and callbacks
            // go with it here, popups first.
            if (!w.dead) w.destroyTree() catch {};
            return true;
        },
        .pointer_constraint, .shortcuts_inhibit, .restored, .theme_changed => {
            const cb = w.on_event orelse return false;
            const kind: t.WindowEventType = switch (ev.*) {
                .pointer_constraint => |c| if (c.active) .pointer_constrained else .pointer_unconstrained,
                .shortcuts_inhibit => |on| if (on) .shortcuts_inhibited else .shortcuts_restored,
                .restored => .restored,
                .theme_changed => .theme_changed,
                else => unreachable,
            };
            var e = windowEvent(kind, w.win.state);
            self.enter();
            defer self.leave();
            _ = cb(w.user_data, handle, &e);
            return false;
        },
        .external_configure => |x| {
            external.deliver(w, x.id, .{
                .type = .configure,
                .width = x.width,
                .height = x.height,
                .buffer_width = x.buffer_width,
                .buffer_height = x.buffer_height,
                .scale = @floatCast(w.win.state.scale.toFloat()),
            });
            return false;
        },
    }
}

fn windowEvent(kind: t.WindowEventType, s: platform.WindowState) t.WindowEvent {
    return .{ .type = kind, .width = s.width, .height = s.height, .states = @bitCast(states(s.states)), .scale = s.scale.toFloat() };
}

pub fn states(s: platform.WindowStates) u32 {
    const out: t.WindowStates = .{
        .maximized = s.maximized,
        .fullscreen = s.fullscreen,
        .resizing = s.resizing,
        .activated = s.activated,
        .tiled_left = s.tiled_left,
        .tiled_right = s.tiled_right,
        .tiled_top = s.tiled_top,
        .tiled_bottom = s.tiled_bottom,
        .suspended = s.suspended,
    };
    return @bitCast(out);
}

pub export fn siv_window_destroy(window: t.Window) void {
    const w = App.window(@backingInt(window), window_tag) catch return;
    if (w.owner.painting != 0) return;
    w.destroyTree() catch return;
    return;
}

pub export fn siv_window_set_title(window: t.Window, title: ?[*]const u8, title_len: usize) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    const s = runtime.string(title, title_len) catch |err| return t.resultOf(err);
    w.win.setTitle(s) catch return .error_out_of_memory;
    return .ok;
}

pub export fn siv_window_get_size(window: t.Window, size: ?*t.Size) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    const dest = runtime.out(t.Size, size) catch |err| return t.resultOf(err);
    dest.* = .{ .width = w.uiWin().width, .height = w.uiWin().height };
    return .ok;
}

pub export fn siv_window_get_scale(window: t.Window, scale: ?*f64) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    const dest = runtime.out(f64, scale) catch |err| return t.resultOf(err);
    dest.* = w.win.state.scale.toFloat();
    return .ok;
}

pub export fn siv_window_get_states(window: t.Window, out: ?*t.WindowStates) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    const dest = runtime.out(t.WindowStates, out) catch |err| return t.resultOf(err);
    dest.* = @bitCast(states(w.win.state.states));
    return .ok;
}

pub export fn siv_window_set_maximized(window: t.Window, maximized: bool) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    w.win.setMaximized(maximized) catch return .error_out_of_memory;
    return .ok;
}

pub export fn siv_window_set_fullscreen(window: t.Window, fullscreen: bool) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    w.win.setFullscreen(fullscreen) catch return .error_out_of_memory;
    return .ok;
}

pub export fn siv_app_get_wayland(app: t.App, display: ?*?*anyopaque) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const dest = runtime.out(?*anyopaque, display) catch |err| return t.resultOf(err);
    const objects = self.app.comp.wayland(null) catch return .error_unavailable;
    dest.* = objects.display;
    return .ok;
}

pub export fn siv_window_get_wayland(window: t.Window, surface: ?*?*anyopaque, toplevel: ?*?*anyopaque) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    const ds = runtime.out(?*anyopaque, surface) catch |err| return t.resultOf(err);
    var scratch: ?*anyopaque = null;
    const dt = runtime.optOut(?*anyopaque, toplevel, &scratch);
    const objects = w.owner.app.comp.wayland(w.win.id) catch return .error_unavailable;
    ds.* = objects.surface;
    dt.* = objects.toplevel;
    return .ok;
}

pub export fn siv_window_request_commit(window: t.Window) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    w.owner.app.comp.requestCommit(w.win.id) catch return .error_out_of_memory;
    return .ok;
}

pub export fn siv_window_minimize(window: t.Window) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    w.win.minimize() catch return .error_out_of_memory;
    return .ok;
}

pub export fn siv_window_set_size_limits(window: t.Window, min: t.Size, max: t.Size) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    const lmin = limit(min) catch |err| return t.resultOf(err);
    const lmax = limit(max) catch |err| return t.resultOf(err);
    w.win.setSizeLimits(lmin, lmax) catch return .error_out_of_memory;
    return .ok;
}

fn limit(s: t.Size) Error!platform.Size {
    for ([_]f32{ s.width, s.height }) |v| if (!(v >= 0) or v > 1 << 30) return error.InvalidArgument;
    return .{ .width = @intFromFloat(@ceil(s.width)), .height = @intFromFloat(@ceil(s.height)) };
}

pub export fn siv_window_get_root(window: t.Window) t.Node {
    const w = App.window(@backingInt(window), window_tag) catch return .null;
    return @fromBackingInt(w.nodes.handle(.root));
}

// Timers ----------------------------------------------------------------------

pub export fn siv_timer_start(app: t.App, delay_ms: u32, callback: ?t.PostFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, timer: ?*t.Timer) t.Result {
    const self = App.get(@backingInt(app)) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    const r = timerStart(self, delay_ms, callback, destroy, user_data, timer);
    // The call failed: the caller handed user_data over anyway (D2).
    if (r != .ok) self.release(destroy, user_data);
    return r;
}

fn timerStart(self: *App, delay_ms: u32, callback: ?t.PostFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, out: ?*t.Timer) t.Result {
    const cb = callback orelse return .error_invalid_argument;
    var unused: t.Timer = .null;
    const dest = runtime.optOut(t.Timer, out, &unused);
    const gpa = self.gpa();
    const index: u32 = for (self.timers.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        self.timers.append(gpa, null) catch return .error_out_of_memory;
        break :blk @intCast(self.timers.items.len - 1);
    };
    const tm = gpa.create(Timer) catch return .error_out_of_memory;
    tm.* = .{ .owner = self, .index = index, .handle = 0, .callback = cb, .destroy = destroy, .user_data = user_data };
    self.root.handles.ensureUnusedCapacity(gpa) catch {
        gpa.destroy(tm);
        return .error_out_of_memory;
    };
    const ns = @as(u64, delay_ms) * std.time.ns_per_ms;
    self.app.loop.startTimer(&tm.timer, loop_mod.Loop.now() + ns, 0) catch {
        gpa.destroy(tm);
        return .error_out_of_memory;
    };
    tm.handle = self.root.handles.insert(gpa, timer_tag, index) catch unreachable;
    self.timers.items[index] = tm;
    dest.* = @fromBackingInt(tm.handle);
    return .ok;
}

pub export fn siv_timer_cancel(timer: t.Timer) void {
    const self, const index = Root.owner(App, app_tag, @backingInt(timer), timer_tag) catch return;
    const tm = self.timers.items[index] orelse return;
    tm.cancel();
    return;
}

/// A siv_job_start job: one pool job and its C callbacks (D5, D6).
const Job = struct {
    job: loop_mod.Pool.Job = .{ .run = run, .done = done, .cancel = dropped },
    owner: *App,
    work: t.WorkFn,
    callback: ?t.PostFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn run(pj: *loop_mod.Pool.Job) void {
        const j: *Job = @fieldParentPtr("job", pj);
        j.work(j.user_data);
    }

    fn done(pj: *loop_mod.Pool.Job) void {
        const j: *Job = @fieldParentPtr("job", pj);
        const self = j.owner;
        if (j.callback) |f| {
            self.enter();
            f(j.user_data);
            self.leave();
        }
        dropped(pj);
    }

    /// Queued at teardown, or done: only the destroy-notify runs.
    fn dropped(pj: *loop_mod.Pool.Job) void {
        const j: *Job = @fieldParentPtr("job", pj);
        const self = j.owner;
        const destroy, const user_data = .{ j.destroy, j.user_data };
        self.jobs -= 1;
        self.gpa().destroy(j);
        self.release(destroy, user_data);
    }
};

pub export fn siv_job_start(app: t.App, flags: t.JobFlags, work: ?t.WorkFn, done: ?t.PostFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const self = App.get(@backingInt(app)) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    const r = jobStart(self, flags, work, done, destroy, user_data);
    // The call failed: the caller handed user_data over anyway (D2).
    if (r != .ok) self.release(destroy, user_data);
    return r;
}

fn jobStart(self: *App, flags: t.JobFlags, work: ?t.WorkFn, done: ?t.PostFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const fl = runtime.flags(t.JobFlags, flags) catch |err| return t.resultOf(err);
    const w = work orelse return .error_invalid_argument;
    const gpa = self.gpa();
    const j = gpa.create(Job) catch return .error_out_of_memory;
    j.* = .{ .owner = self, .work = w, .callback = done, .destroy = destroy, .user_data = user_data };
    j.job.class = if (fl.compute) .compute else .blocking;
    self.jobs += 1;
    self.app.pool.submit(&j.job) catch |err| {
        self.jobs -= 1;
        gpa.destroy(j);
        return switch (err) {
            error.OutOfMemory => .error_out_of_memory,
            error.SystemResources => .error_unavailable,
        };
    };
    return .ok;
}

// Popups ----------------------------------------------------------------------

pub export fn siv_popup_create(parent: t.Window, desc: ?*const t.PopupDesc, popup: ?*t.Window) t.Result {
    return wrap(popupCreate(parent, desc, popup));
}

fn popupCreate(parent: t.Window, desc_ptr: ?*const t.PopupDesc, out: ?*t.Window) Error!void {
    const pw = try App.window(@backingInt(parent), window_tag);
    const self = pw.owner;
    if (self.painting != 0) return error.Busy;
    const desc = try runtime.readDesc(t.PopupDesc, desc_ptr);
    const flags = try runtime.flags(t.PopupFlags, desc.flags);
    const placement: app_mod.Window.Placement = switch (try runtime.enumValue(t.PopupPlacement, desc.placement)) {
        .below => .below,
        .beside => .beside,
        .tooltip => .tooltip,
        _ => unreachable,
    };
    const anchor: ui.NodeId = if (desc.anchor == .null) .root else try tree.nodeIn(pw, desc.anchor);
    const ar = desc.anchor_rect;
    for ([_]f32{ ar.x, ar.y, ar.width, ar.height }) |v| if (!std.math.isFinite(v)) return error.InvalidArgument;
    if (ar.width < 0 or ar.height < 0) return error.InvalidArgument;
    const rect: ?[4]f32 = if (flags.at_rect) .{ ar.x, ar.y, ar.width, ar.height } else null;
    const dest = try runtime.out(t.Window, out);

    const gpa = self.gpa();
    const index: u32 = for (self.windows.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        if (self.windows.items.len >= max_windows) return error.LimitExceeded;
        try self.windows.append(gpa, null);
        break :blk @intCast(self.windows.items.len - 1);
    };
    const w = try gpa.create(Window);
    errdefer gpa.destroy(w);
    w.* = .{
        .owner = self,
        .index = index,
        .handle = 0,
        .win = undefined,
        .on_event = desc.on_event,
        .destroy = desc.destroy,
        .user_data = desc.user_data,
        .parent = pw,
        .popup = .{ .anchor = anchor, .placement = placement, .width = desc.width, .height = desc.height, .grab = !flags.no_grab, .rect = rect },
    };
    errdefer w.nodes.deinit(gpa);
    try w.nodes.reserve(gpa, 1);
    try self.root.handles.ensureUnusedCapacity(gpa);
    w.handle = try self.root.handles.insert(gpa, window_tag, index);
    errdefer _ = self.root.handles.remove(w.handle, window_tag) catch unreachable;
    try self.root.handles.ensureUnusedCapacity(gpa);
    w.win = self.app.createPopup(pw.win, anchor, .{ .ctx = w, .func = onWindowEvent }) catch |err| return mapAppError(err);
    w.nodes.adopt(self, w, .root) catch unreachable;
    actions.attach(w);
    self.windows.items[index] = w;
    dest.* = @fromBackingInt(w.handle);
}

pub export fn siv_popup_show(popup: t.Window) t.Result {
    const w = App.window(@backingInt(popup), window_tag) catch |err| return t.resultOf(err);
    if (w.owner.painting != 0 or w.txn.handle != 0) return .error_busy;
    const pw = w.parent orelse return .error_invalid_argument;
    const p = w.popup;
    const anchor: ui.NodeId = if (pw.uiWin().isLive(p.anchor)) p.anchor else .root;
    w.win.showPopup(anchor, p.placement, p.width, p.height, p.grab, p.rect) catch |err| return t.resultOf(mapAppError(err));
    return .ok;
}

pub export fn siv_window_get_app(window: t.Window) t.App {
    const w = App.window(@backingInt(window), window_tag) catch return .null;
    return @fromBackingInt(w.owner.root.handle);
}
