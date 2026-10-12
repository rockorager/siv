//! Lifecycle (D19): single instance and D-Bus activation through
//! org.freedesktop.Application.
//!
//! `launch` asks for the application id as a bus name. The instance that
//! gets it is primary: it serves Activate, Open, and ActivateAction, and
//! unless it was started by D-Bus activation it activates itself (or
//! opens the URIs it was launched with). An instance that finds the name
//! taken is secondary: it forwards its activation to the primary and
//! `run` returns. Without an application id or a session bus, or with
//! multiple instances allowed, every launch is primary.
//!
//! The launcher's xdg-activation token ($XDG_ACTIVATION_TOKEN) goes with
//! the first activation, or is forwarded to the primary, and is removed
//! from the environment so that children do not reuse it.

const std = @import("std");
const portal = @import("portal");
const loop_mod = @import("loop");
const platform = @import("platform");
const app_mod = @import("app.zig");

const App = app_mod.App;
const Loop = loop_mod.Loop;
const Timer = loop_mod.Timer;
const Application = portal.application;

pub const Kind = enum { activate, open };

pub const Activation = struct {
    kind: Kind,
    uris: []const []const u8 = &.{},
    /// An xdg-activation token for the window the activation shows.
    token: []const u8 = "",
    /// From another instance or the desktop, not this launch.
    remote: bool = false,
};

pub const Handler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, activation: *const Activation) void,
};

pub const Role = enum { none, pending, primary, secondary };

pub const LaunchOptions = struct {
    /// URIs to open: the primary opens them, a secondary forwards them.
    uris: []const []const u8 = &.{},
    /// Started by D-Bus activation: wait for the desktop's call instead
    /// of activating.
    service: bool = false,
    /// Every launch is a primary instance and nothing is exported.
    multiple_instances: bool = false,
    /// A service with no window this long after its last activation
    /// makes `run` return; 0 waits forever.
    idle_timeout_ms: u32 = 0,
};

pub const Error = error{ OutOfMemory, Busy };

pub const Lifecycle = struct {
    role: Role = .none,
    handler: Handler = undefined,
    server: Application.Server = .{ .handler = undefined },
    serving: bool = false,
    forward: Application.Forward = .{ .func = onForwarded },
    arena: std.heap.ArenaAllocator = undefined,
    uris: []const []const u8 = &.{},
    token: platform.Handle = .{},
    service: bool = false,
    idle_timeout_ms: u32 = 0,
    task: Loop.Task = .{ .func = onLaunched },
    idle: Timer = .{ .func = onIdle },

    pub fn deinit(l: *Lifecycle, app: *App) void {
        if (l.role == .none) return;
        app.loop.unschedule(&l.task);
        app.loop.cancelTimer(&l.idle);
        l.forward.cancel();
        if (l.serving) l.server.stop();
        l.serving = false;
        l.arena.deinit();
        l.role = .none;
    }
};

extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Starts the lifecycle; see the module comment. Once only.
pub fn launch(app: *App, options: LaunchOptions, handler: Handler) Error!void {
    const l = &app.lifecycle;
    if (l.role != .none) return error.Busy;
    l.arena = .init(app.gpa);
    errdefer l.arena.deinit();
    const a = l.arena.allocator();
    const uris = try a.alloc([]const u8, options.uris.len);
    for (options.uris, uris) |u, *d| d.* = try a.dupe(u8, u);
    l.* = .{
        .role = .pending,
        .handler = handler,
        .arena = l.arena,
        .uris = uris,
        .service = options.service,
        .idle_timeout_ms = options.idle_timeout_ms,
    };
    if (std.c.getenv("XDG_ACTIVATION_TOKEN")) |t| {
        l.token.set(std.mem.span(t));
        _ = unsetenv("XDG_ACTIVATION_TOKEN");
    }
    const id = app.app_id.slice();
    if (!options.multiple_instances and id.len > 0 and app.desktop.connected) {
        l.server = .{ .handler = .{ .ctx = app, .activate = remoteActivate, .open = remoteOpen, .action = remoteAction }, .on_name = onName };
        if (l.server.start(&app.desktop.bus, id)) {
            l.serving = true;
            return;
        } else |_| {}
    }
    becomePrimary(app);
}

fn becomePrimary(app: *App) void {
    const l = &app.lifecycle;
    l.role = .primary;
    // The first activation is delivered from the loop, not from `launch`.
    if (!l.service) app.loop.schedule(&l.task, .dispatch) else armIdle(app);
}

fn onLaunched(task: *Loop.Task) void {
    const l: *Lifecycle = @fieldParentPtr("task", task);
    const app: *App = @fieldParentPtr("lifecycle", l);
    deliver(app, .{ .kind = if (l.uris.len > 0) .open else .activate, .uris = l.uris, .token = l.token.slice() });
}

fn deliver(app: *App, activation: Activation) void {
    const l = &app.lifecycle;
    l.handler.func(l.handler.ctx, &activation);
    armIdle(app);
}

/// Services quit when nothing shows a window for a while.
fn armIdle(app: *App) void {
    const l = &app.lifecycle;
    if (!l.service or l.idle_timeout_ms == 0) return;
    app.loop.startTimer(&l.idle, Loop.now() + @as(u64, l.idle_timeout_ms) * std.time.ns_per_ms, 0) catch {};
}

fn onIdle(timer: *Timer) void {
    const l: *Lifecycle = @fieldParentPtr("idle", timer);
    const app: *App = @fieldParentPtr("lifecycle", l);
    if (app.open_windows == 0) app.quit();
}

fn onName(s: *Application.Server) void {
    const l: *Lifecycle = @fieldParentPtr("server", s);
    const app: *App = @fieldParentPtr("lifecycle", l);
    switch (s.owner.state) {
        .primary => becomePrimary(app),
        .exists => {
            l.serving = false;
            l.role = .secondary;
            const conn = &app.desktop.bus;
            const id = app.app_id.slice();
            const r = if (l.uris.len > 0) l.forward.open(conn, id, l.uris, l.token.slice()) else l.forward.activate(conn, id, l.token.slice());
            r catch onForwarded(&l.forward, false);
        },
        // The bus refused the name: run alone.
        else => {
            l.serving = false;
            becomePrimary(app);
        },
    }
}

fn onForwarded(f: *Application.Forward, ok: bool) void {
    const l: *Lifecycle = @fieldParentPtr("forward", f);
    const app: *App = @fieldParentPtr("lifecycle", l);
    if (!ok) app.fail(error.Unavailable);
    app.quit();
}

fn remoteActivate(ctx: ?*anyopaque, token: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.loop.cancelTimer(&app.lifecycle.idle);
    deliver(app, .{ .kind = .activate, .token = token, .remote = true });
}

fn remoteOpen(ctx: ?*anyopaque, uris: *portal.vardict.StringIterator, token: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.loop.cancelTimer(&app.lifecycle.idle);
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(app.gpa);
    while (uris.next()) |u| list.append(app.gpa, u) catch return app.fail(error.OutOfMemory);
    deliver(app, .{ .kind = .open, .uris = list.items, .token = token, .remote = true });
}

fn remoteAction(ctx: ?*anyopaque, name: []const u8, target: []const u8, token: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.loop.cancelTimer(&app.lifecycle.idle);
    app.invokeAction(name, target, token);
    armIdle(app);
}
