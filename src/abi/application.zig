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
    /// Portal requests, choosers, and actions (D19).
    desktop: portal.State,

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

    pub fn uiWin(w: *Window) *ui.Window {
        return w.win.ui;
    }

    fn free(w: *Window) void {
        const gpa = w.owner.gpa();
        w.nodes.deinit(gpa);
        w.txn.deinit(gpa);
        gpa.destroy(w);
    }

    /// Everything but the platform window: the open transaction, handles,
    /// and callbacks. The window must already be destroyed in `app`.
    fn teardown(w: *Window) void {
        const self = w.owner;
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
    const dest = try runtime.out(t.App, out);

    const self = try Root.create(App, app_tag, hooks);
    errdefer Root.destroy(App, self);
    self.windows = .empty;
    self.depth = 0;
    self.pending = .empty;
    self.dead = .empty;
    self.painting = 0;
    self.images = .empty;
    self.waiting = .empty;
    self.externals = .{};
    self.closing = .init(false);
    self.timers = .empty;
    self.desktop = .{};
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
        .reduced_motion = flags.reduced_motion,
        .desktop_settings = backend == .wayland and !flags.no_desktop_settings,
        // Mandatory on a display (D18); the headless backend stays
        // independent of the desktop.
        .accessibility = backend == .wayland,
        .name = name,
        .toolkit_version = toolkit_version,
        .app_id = app_id,
    }) catch |err| return mapAppError(err);
    errdefer self.app.destroy();
    try self.app.fonts.addListener(.{ .ctx = self, .func = canvas.onFontsLoaded });
    dest.* = @fromBackingInt(self.root.handle);
}

pub export fn siv_app_destroy(app: t.App) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    if (self.depth != 0 or self.app.loop.isDispatching()) return .error_busy;
    // From here no thread can post or submit, and every handle is
    // invalid.
    self.closing.store(true, .seq_cst);
    self.root.retire();
    // Before the windows, whose destruction would start waiting requests.
    portal.teardown(self);
    for (self.windows.items) |slot| if (slot) |w| {
        w.win.destroy() catch {};
        w.teardown();
    };
    const gpa = self.gpa();
    for (self.timers.items) |slot| if (slot) |tm| tm.cancel();
    self.timers.deinit(gpa);
    self.app.fonts.removeListener(self);
    for (self.images.items) |img| if (img) |i| i.release();
    // Runs the destroy-notify of posted work that never ran (D5).
    self.app.destroy();
    while (self.dead.pop()) |w| w.free();
    self.windows.deinit(gpa);
    self.pending.deinit(gpa);
    self.dead.deinit(gpa);
    self.draw.deinit(gpa);
    self.images.deinit(gpa);
    self.waiting.deinit(gpa);
    self.externals.deinit(gpa);
    Root.destroy(App, self);
    return .ok;
}

pub export fn siv_app_fd(app: t.App, fd: ?*i32) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const dest = runtime.out(i32, fd) catch |err| return t.resultOf(err);
    dest.* = self.app.fd();
    return .ok;
}

pub export fn siv_app_dispatch(app: t.App, timeout_ms: i32) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    if (self.depth != 0) return .error_busy;
    self.app.dispatch(timeout_ms) catch |err| return t.resultOf(mapAppError(err));
    return .ok;
}

pub export fn siv_run(app: t.App) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    if (self.depth != 0) return .error_busy;
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

pub export fn siv_app_set_default_font(app: t.App, family: ?[*]const u8, family_len: usize) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const name = runtime.string(family, family_len) catch |err| return t.resultOf(err);
    self.app.setDefaultFont(name) catch return .error_out_of_memory;
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
    const initial = try runtime.flags(t.WindowStates, desc.states);
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
    w.* = .{ .owner = self, .index = index, .handle = 0, .win = undefined, .on_event = desc.on_event, .destroy = desc.destroy, .user_data = desc.user_data };
    errdefer w.nodes.deinit(gpa);
    try w.nodes.reserve(gpa, 1);
    try self.root.handles.ensureUnusedCapacity(gpa);
    w.handle = try self.root.handles.insert(gpa, window_tag, index);
    errdefer _ = self.root.handles.remove(w.handle, window_tag) catch unreachable;
    try self.root.handles.ensureUnusedCapacity(gpa);

    w.win = self.app.createWindow(.{
        .title = title,
        .app_id = app_id,
        .width = if (desc.width == 0) 640 else desc.width,
        .height = if (desc.height == 0) 480 else desc.height,
        .client_decorations = flags.client_decorations,
        .rtl = flags.rtl,
        .language = language,
    }, .{ .ctx = w, .func = onWindowEvent }) catch |err| return mapAppError(err);
    errdefer w.win.destroy() catch {};
    if (desc.min_width != 0 or desc.min_height != 0 or desc.max_width != 0 or desc.max_height != 0) {
        try w.win.setSizeLimits(.{ .width = desc.min_width, .height = desc.min_height }, .{ .width = desc.max_width, .height = desc.max_height });
    }
    if (initial.maximized) try w.win.setMaximized(true);
    if (initial.fullscreen) try w.win.setFullscreen(true);
    // Nothing below fails.
    w.nodes.adopt(self, w, .root) catch unreachable;
    self.windows.items[index] = w;
    dest.* = @fromBackingInt(w.handle);
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
            if (!kept and !w.dead) {
                w.win.destroy() catch return true;
                w.teardown();
            }
            return true;
        },
        .configure => |c| {
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

fn states(s: platform.WindowStates) u32 {
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

pub export fn siv_window_destroy(window: t.Window) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| return t.resultOf(err);
    if (w.owner.painting != 0) return .error_busy;
    w.win.destroy() catch return .error_out_of_memory;
    w.teardown();
    return .ok;
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

pub export fn siv_window_root(window: t.Window) t.Node {
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
    const dest = runtime.out(t.Timer, out) catch |err| return t.resultOf(err);
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

pub export fn siv_timer_cancel(timer: t.Timer) t.Result {
    const self, const index = Root.owner(App, app_tag, @backingInt(timer), timer_tag) catch |err| return t.resultOf(err);
    const tm = self.timers.items[index] orelse return .error_invalid_handle;
    tm.cancel();
    return .ok;
}
