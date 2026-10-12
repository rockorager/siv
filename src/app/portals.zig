//! Desktop portals for the application (D19): the portal client on the
//! application's session bus, parent window identifiers for portal
//! dialogs, activation tokens, and application actions.
//!
//! Parent windows: a portal dialog is parented to a window through
//! "wayland:<handle>", where the handle comes from exporting the window's
//! toplevel with xdg-foreign-v2. Exports are made on the compositor
//! thread the first time a window needs one and last as long as the
//! window; `Window.parent` runs its callback with the identifier once it
//! is known, or with "" when the compositor cannot export (and the dialog
//! is then not modal to anything).
//!
//! Actions are named operations the desktop can invoke: notification
//! buttons (ActionInvoked) and org.freedesktop.Application's
//! ActivateAction (lifecycle). A notification action "app.<name>" (GLib's
//! convention, which desktops that activate applications by D-Bus
//! expect) invokes the action <name>.

const std = @import("std");
const portal = @import("portal");
const platform = @import("platform");
const compositor = @import("compositor");
const app_mod = @import("app.zig");

const App = app_mod.App;
const Window = app_mod.Window;
const List = std.DoublyLinkedList;

/// Waits for a window's parent identifier ("wayland:<handle>" or "").
pub const Parent = struct {
    func: *const fn (p: *Parent, id: []const u8) void,
    node: List.Node = .{},
    window: ?*Window = null,

    /// Stops waiting; the callback will not run.
    pub fn cancel(p: *Parent) void {
        const win = p.window orelse return;
        win.parent_waiters.remove(&p.node);
        p.window = null;
    }
};

/// Waits for an activation token ("" when there is none).
pub const Token = struct {
    func: *const fn (t: *Token, token: []const u8) void,
    node: List.Node = .{},
    window: ?*Window = null,
    request: u32 = 0,

    pub fn cancel(t: *Token) void {
        const win = t.window orelse return;
        win.token_waiters.remove(&t.node);
        t.window = null;
    }
};

pub const Action = struct {
    ctx: ?*anyopaque = null,
    /// `target` is the action's string parameter, or empty.
    /// `activation_token` lets a window the action shows take focus.
    func: *const fn (ctx: ?*anyopaque, name: []const u8, target: []const u8, activation_token: []const u8) void,
};

pub const Portals = struct {
    client: portal.Client = undefined,
    /// The client runs on the application's session bus.
    running: bool = false,
    actions: portal.notification.Actions = .{ .func = onNotificationAction },
    subscribed: bool = false,
    /// Registered application actions by name (names are owned).
    registry: std.StringHashMapUnmanaged(Action) = .empty,
    next_token: u32 = 0,

    /// Starts the client on the application's bus; desktop.zig has sent
    /// the registration already.
    pub fn start(p: *Portals, app: *App) void {
        if (!app.desktop.connected) return;
        p.client = .init(&app.desktop.bus);
        p.running = true;
        p.client.queryVersions();
        p.actions.subscribe(&p.client) catch return;
        p.subscribed = true;
    }

    pub fn deinit(p: *Portals, app: *App) void {
        if (p.running) {
            if (p.subscribed) p.actions.unsubscribe();
            p.client.deinit();
        }
        p.running = false;
        var it = p.registry.keyIterator();
        while (it.next()) |k| app.gpa.free(k.*);
        p.registry.deinit(app.gpa);
    }

    /// The portal client, or null without a session bus.
    pub fn get(p: *Portals) ?*portal.Client {
        return if (p.running) &p.client else null;
    }

    pub fn connectionEvent(p: *Portals, ready: bool) void {
        if (!p.running) return;
        if (ready) p.client.connectionReady() else p.client.connectionLost();
    }
};

fn onNotificationAction(a: *portal.notification.Actions, _: []const u8, action: []const u8, target: []const u8) void {
    const p: *Portals = @fieldParentPtr("actions", a);
    const app: *App = @fieldParentPtr("portals", p);
    const name = if (std.mem.startsWith(u8, action, "app.")) action[4..] else action;
    app.invokeAction(name, target, "");
}

// Window side -----------------------------------------------------------------

/// Runs `p.func` with the window's parent identifier: at once if it is
/// known, else when the export arrives. `win` null means no parent.
pub fn parentOf(app: *App, win: ?*Window, p: *Parent) void {
    const w = win orelse return p.func(p, "");
    if (w.closed) return p.func(p, "");
    switch (w.export_state) {
        .done => {
            var buf: [300]u8 = undefined;
            return p.func(p, parentId(&buf, w.export_handle.slice()));
        },
        .pending => {},
        .none => {
            w.export_state = .pending;
            w.platformRequest(struct {
                fn f(pl: platform.Platform, id: platform.WindowId, _: void) void {
                    pl.exportToplevel(id);
                }
            }.f, {}) catch {
                w.export_state = .none;
                return p.func(p, "");
            };
        },
    }
    p.window = w;
    w.parent_waiters.append(&p.node);
    _ = app;
}

fn parentId(buf: []u8, handle: []const u8) []const u8 {
    if (handle.len == 0) return "";
    return std.fmt.bufPrint(buf, "wayland:{s}", .{handle}) catch "";
}

/// The window's export arrived: run every waiter.
pub fn exported(w: *Window, handle: []const u8) void {
    w.export_handle.set(handle);
    w.export_state = .done;
    var buf: [300]u8 = undefined;
    const id = parentId(&buf, w.export_handle.slice());
    while (w.parent_waiters.popFirst()) |n| {
        const p: *Parent = @fieldParentPtr("node", n);
        p.window = null;
        p.func(p, id);
    }
}

/// Asks for an activation token tied to the window's last input, for an
/// application the user asked to open (OpenURI) or to show.
pub fn tokenFor(app: *App, win: *Window, t: *Token) void {
    if (win.closed) return t.func(t, "");
    app.portals.next_token +%= 1;
    const request = app.portals.next_token;
    const Arg = struct { request: u32, seat: platform.SeatId, serial: u32, app_id: platform.BoundedString(256) };
    var arg: Arg = .{ .request = request, .seat = win.ui.input.seat, .serial = win.ui.input.serial, .app_id = .{} };
    arg.app_id.set(app.app_id.slice());
    win.platformRequest(struct {
        fn f(pl: platform.Platform, id: platform.WindowId, a: Arg) void {
            pl.requestActivationToken(id, a.request, a.seat, a.serial, a.app_id.slice());
        }
    }.f, arg) catch return t.func(t, "");
    t.window = win;
    t.request = request;
    win.token_waiters.append(&t.node);
}

pub fn tokenArrived(w: *Window, request: u32, token: []const u8) void {
    var it = w.token_waiters.first;
    while (it) |n| {
        it = n.next;
        const t: *Token = @fieldParentPtr("node", n);
        if (t.request != request) continue;
        w.token_waiters.remove(n);
        t.window = null;
        t.func(t, token);
    }
}

/// The window is going away: waiters proceed without it.
pub fn windowClosed(w: *Window) void {
    while (w.parent_waiters.popFirst()) |n| {
        const p: *Parent = @fieldParentPtr("node", n);
        p.window = null;
        p.func(p, "");
    }
    while (w.token_waiters.popFirst()) |n| {
        const t: *Token = @fieldParentPtr("node", n);
        t.window = null;
        t.func(t, "");
    }
}
