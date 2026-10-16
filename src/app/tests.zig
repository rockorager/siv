//! The coordinator on the headless backend: the real loop, worker pool,
//! and compositor thread, with events injected into the platform.

const std = @import("std");
const testing = std.testing;
const platform = @import("platform");
const compositor = @import("compositor");
const ui = @import("ui");
const app_mod = @import("app.zig");

const App = app_mod.App;
const Window = app_mod.Window;
const Loop = @import("loop").Loop;

fn create(thread: bool) !*App {
    return App.create(testing.allocator, .{
        .backend = .headless,
        .headless = .{ .refresh_ns = std.time.ns_per_ms },
        .system_fonts = false,
        .threads = 2,
        .compositor_thread = thread,
        .desktop_settings = false,
        .accessibility = false,
    });
}

/// Dispatches until `cond(ctx)`.
fn runUntil(app: *App, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (!cond(ctx)) {
        if (Loop.now() > deadline) return error.Timeout;
        try app.dispatch(5);
    }
}

fn settled(win: *Window) bool {
    return win.presented_seq > 0 and win.settled();
}

/// Runs `func(headless, id)` on the compositor thread.
fn onHeadless(app: *App, id: platform.WindowId, comptime func: fn (*platform.Headless, platform.WindowId) void) !void {
    const Ctx = struct {
        id: platform.WindowId,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            func(comp.platform.headless, c.id);
        }
    };
    var ctx: Ctx = .{ .id = id };
    try app.comp.call(&ctx, Ctx.run);
}

/// The top-left pixel of the presented frame, as B, G, R, A.
fn firstPixel(app: *App, id: platform.WindowId) ![4]u8 {
    const Ctx = struct {
        id: platform.WindowId,
        out: ?[4]u8 = null,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            const img = comp.platform.headless.presented(c.id) orelse return;
            c.out = img.pixels[0..4].*;
        }
    };
    var ctx: Ctx = .{ .id = id };
    try app.comp.call(&ctx, Ctx.run);
    return ctx.out orelse error.NothingPresented;
}

test "a window presents its tree, on and off the compositor thread" {
    for ([_]bool{ true, false }) |thread| {
        const app = try create(thread);
        defer app.destroy();
        const win = try app.createWindow(.{ .width = 64, .height = 48 }, .{});
        const t = try win.ui.begin();
        try t.setVisual(.root, .{ .background = .srgb8(0xff, 0x00, 0x00, 0xff) });
        t.commit();
        try runUntil(app, win, settled);
        try testing.expectEqual([4]u8{ 0, 0, 0xff, 0xff }, try firstPixel(app, win.id));
    }
}

const Recorder = struct {
    closes: usize = 0,
    configures: usize = 0,
    theme_changes: usize = 0,
    last: platform.WindowState = .{},
    keep_open: bool = false,

    fn listener(r: *Recorder) app_mod.Listener {
        return .{ .ctx = r, .func = onEvent };
    }

    fn onEvent(ctx: ?*anyopaque, _: *Window, ev: *const app_mod.WindowEvent) bool {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .close_requested => r.closes += 1,
            .configure => |c| {
                r.configures += 1;
                r.last = c.new;
            },
            .theme_changed => r.theme_changes += 1,
            .external_released, .external_configure, .external_presented, .presented, .pointer_constraint, .shortcuts_inhibit, .restored, .closed => {},
        }
        return r.keep_open;
    }
};

test "configures reach the listener; an unhandled close request destroys the window and ends run" {
    const app = try create(true);
    defer app.destroy();
    var rec: Recorder = .{ .keep_open = true };
    const win = try app.createWindow(.{ .width = 64, .height = 48 }, rec.listener());
    try runUntil(app, win, settled);
    try testing.expect(rec.configures >= 1);
    try testing.expectEqual(@as(u32, 64), rec.last.width);

    try onHeadless(app, win.id, struct {
        fn f(hl: *platform.Headless, id: platform.WindowId) void {
            hl.configure(id, .{ .width = 100, .height = 30 }, null);
        }
    }.f);
    try runUntil(app, &rec, struct {
        fn f(r: *Recorder) bool {
            return r.last.width == 100;
        }
    }.f);
    try testing.expectEqual(@as(f32, 100), win.ui.width);

    // Handled: the window stays.
    try onHeadless(app, win.id, platform.Headless.requestClose);
    try runUntil(app, &rec, struct {
        fn f(r: *Recorder) bool {
            return r.closes == 1;
        }
    }.f);
    try testing.expectEqual(1, app.open_windows);

    // Unhandled: destroyed, and run returns with no windows left.
    rec.keep_open = false;
    try onHeadless(app, win.id, platform.Headless.requestClose);
    try app.run();
    try testing.expectEqual(2, rec.closes);
    try testing.expectEqual(0, app.open_windows);
}

test "a window destroyed from its own event handler lives until its lists come back" {
    const app = try create(true);
    defer app.destroy();
    const win = try app.createWindow(.{ .width = 64, .height = 48 }, .{});
    const Handler = struct {
        fn onActivate(user: ?*anyopaque, _: *ui.Window, _: ui.NodeId, _: *const ui.Event) ui.HandlerResult {
            const w: *Window = @ptrCast(@alignCast(user));
            w.destroy() catch unreachable;
            return .handled;
        }
    };
    const t = try win.ui.begin();
    const button = try t.create(.root, .box, .none);
    try t.setVisual(button, .{ .background = .black });
    try t.on(button, .activate, .{ .func = Handler.onActivate, .user = win });
    t.commit();
    try runUntil(app, win, settled);

    try onHeadless(app, win.id, struct {
        fn f(hl: *platform.Headless, id: platform.WindowId) void {
            hl.inject(.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 10, .y = 10 } });
            hl.inject(.{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 1 } });
            hl.inject(.{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 2 } });
        }
    }.f);
    try app.run();
    try testing.expectEqual(0, app.open_windows);
    try runUntil(app, app, struct {
        fn f(a: *App) bool {
            return a.zombies.items.len == 0;
        }
    }.f);
}

// Portals (D19) -----------------------------------------------------------------

const dbus = @import("dbus");
const portal = @import("portal");
const portals = app_mod.portals;

/// A test bus with a stand-in portal frontend, on a thread of its own.
const BusThread = struct {
    loop: Loop = undefined,
    bus: dbus.testing.TestBus = undefined,
    conn: dbus.Connection = undefined,
    frontend: portal.testing.Frontend = undefined,
    thread: std.Thread = undefined,
    stop_flag: std.atomic.Value(bool) = .init(false),
    running: bool = false,
    /// A second client socket, made before the thread starts.
    second_fd: i32 = -1,

    /// Starts the bus and returns a socket for the application.
    fn start(b: *BusThread) !i32 {
        b.loop = try Loop.init(std.heap.smp_allocator);
        b.bus = .init(testing.allocator, &b.loop);
        try b.conn.initFd(testing.allocator, &b.loop, try b.bus.connect(), .{});
        b.frontend = .{ .conn = &b.conn };
        try b.frontend.start();
        while (!b.frontend.owns()) try b.loop.dispatch(10);
        const fd = try b.bus.connect();
        b.second_fd = try b.bus.connect();
        b.thread = try std.Thread.spawn(.{}, run, .{b});
        b.running = true;
        return fd;
    }

    fn run(b: *BusThread) void {
        while (!b.stop_flag.load(.acquire)) b.loop.dispatch(-1) catch return;
    }

    /// Stops the thread; the frontend's records can be read afterwards.
    fn stop(b: *BusThread) void {
        if (!b.running) return;
        b.running = false;
        b.stop_flag.store(true, .release);
        b.loop.wake();
        b.thread.join();
    }

    fn deinit(b: *BusThread) void {
        b.stop();
        b.frontend.deinit();
        b.conn.deinit();
        b.bus.deinit();
        b.loop.deinit();
    }
};

const ParentRecord = struct {
    parent: portals.Parent = .{ .func = cb },
    id: [64]u8 = undefined,
    len: usize = 0,
    done: bool = false,

    fn cb(p: *portals.Parent, id: []const u8) void {
        const r: *ParentRecord = @fieldParentPtr("parent", p);
        @memcpy(r.id[0..id.len], id);
        r.len = id.len;
        r.done = true;
    }

    fn isDone(r: *ParentRecord) bool {
        return r.done;
    }

    fn slice(r: *const ParentRecord) []const u8 {
        return r.id[0..r.len];
    }
};

const TokenRecord = struct {
    token: portals.Token = .{ .func = cb },
    text: [64]u8 = undefined,
    len: usize = 0,
    done: bool = false,

    fn cb(t: *portals.Token, token: []const u8) void {
        const r: *TokenRecord = @fieldParentPtr("token", t);
        @memcpy(r.text[0..token.len], token);
        r.len = token.len;
        r.done = true;
    }

    fn isDone(r: *TokenRecord) bool {
        return r.done;
    }
};

test "portal dialogs get parent window identifiers from exports" {
    const app = try create(true);
    defer app.destroy();
    const win = try app.createWindow(.{}, .{});
    var a: ParentRecord = .{};
    portals.parentOf(app, win, &a.parent);
    try runUntil(app, &a, ParentRecord.isDone);
    try testing.expectEqualStrings("wayland:headless-0", a.slice());
    // Known now: answered at once.
    var b: ParentRecord = .{};
    portals.parentOf(app, win, &b.parent);
    try testing.expect(b.done);
    try testing.expectEqualStrings("wayland:headless-0", b.slice());
    // No window, no parent.
    var c: ParentRecord = .{};
    portals.parentOf(app, null, &c.parent);
    try testing.expectEqualStrings("", c.slice());
    // A window destroyed while its export is on the way: no parent.
    const other = try app.createWindow(.{}, .{});
    var d: ParentRecord = .{};
    portals.parentOf(app, other, &d.parent);
    try testing.expect(!d.done);
    try other.destroy();
    try testing.expect(d.done);
    try testing.expectEqualStrings("", d.slice());
}

test "activation tokens need the window's last input" {
    const app = try create(true);
    defer app.destroy();
    const win = try app.createWindow(.{ .width = 64, .height = 48 }, .{});
    try runUntil(app, win, settled);
    var none: TokenRecord = .{};
    portals.tokenFor(app, win, &none.token);
    try runUntil(app, &none, TokenRecord.isDone);
    try testing.expectEqual(@as(usize, 0), none.len);

    try onHeadless(app, win.id, struct {
        fn f(hl: *platform.Headless, id: platform.WindowId) void {
            hl.inject(.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 10, .y = 10 } });
            hl.inject(.{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 5 } });
        }
    }.f);
    try runUntil(app, win, struct {
        fn f(w: *Window) bool {
            return w.ui.input.serial == 5;
        }
    }.f);
    var tok: TokenRecord = .{};
    portals.tokenFor(app, win, &tok.token);
    try runUntil(app, &tok, TokenRecord.isDone);
    try testing.expect(std.mem.startsWith(u8, tok.text[0..tok.len], "headless-token-"));
}

const ChooserRecord = struct {
    req: portal.Request = .{ .func = cb },
    parent: portals.Parent = .{ .func = withParent },
    app: *App,
    done: bool = false,
    code: ?portal.Response = null,

    fn withParent(p: *portals.Parent, id: []const u8) void {
        const r: *ChooserRecord = @fieldParentPtr("parent", p);
        portal.file_chooser.start(&r.req, r.app.portals.get().?, id, .{ .title = "Pick" }) catch unreachable;
    }

    fn cb(req: *portal.Request, outcome: portal.Request.Outcome) void {
        const r: *ChooserRecord = @fieldParentPtr("req", req);
        r.done = true;
        r.code = switch (outcome) {
            .response => |res| res.code,
            .failed => null,
        };
    }

    fn isDone(r: *ChooserRecord) bool {
        return r.done;
    }
};

const ActionRecord = struct {
    count: u32 = 0,
    target: [16]u8 = undefined,
    target_len: usize = 0,

    fn cb(ctx: ?*anyopaque, name: []const u8, target: []const u8, _: []const u8) void {
        const r: *ActionRecord = @ptrCast(@alignCast(ctx));
        std.debug.assert(std.mem.eql(u8, name, "archive"));
        r.count += 1;
        @memcpy(r.target[0..target.len], target);
        r.target_len = target.len;
    }

    fn got(r: *ActionRecord) bool {
        return r.count > 0;
    }
};

test "portal calls go out on the application's bus with the window's parent" {
    var bt: BusThread = .{};
    const fd = try bt.start();
    defer bt.deinit();
    const app = try App.create(testing.allocator, .{
        .backend = .headless,
        .system_fonts = false,
        .threads = 2,
        .desktop_settings = false,
        .accessibility = false,
        .bus_fd = fd,
        .app_id = "org.example.Test",
    });
    defer app.destroy();
    try testing.expect(app.portals.get() != null);
    const win = try app.createWindow(.{}, .{});

    var r: ChooserRecord = .{ .app = app };
    portals.parentOf(app, win, &r.parent);
    try runUntil(app, &r, ChooserRecord.isDone);
    try testing.expectEqual(portal.Response.success, r.code.?);

    // Notification buttons invoke application actions ("app." prefix).
    var rec: ActionRecord = .{};
    try app.addAction("archive", .{ .ctx = &rec, .func = ActionRecord.cb });
    var params = [_]dbus.Variant([]const u8){dbus.variant(@as([]const u8, "42"))};
    // The frontend's connection belongs to the bus thread; post the
    // signal there by stopping it first.
    bt.stop();
    try bt.frontend.emit(portal.notification.interface, "ActionInvoked", .{ @as([]const u8, "n1"), @as([]const u8, "app.archive"), @as([]const dbus.Variant([]const u8), &params) });
    bt.conn.flush();
    try bt.loop.dispatch(0);
    bt.stop_flag.store(false, .release);
    bt.thread = try std.Thread.spawn(.{}, BusThread.run, .{&bt});
    bt.running = true;
    try runUntil(app, &rec, ActionRecord.got);
    try testing.expectEqualStrings("42", rec.target[0..rec.target_len]);
    bt.stop();

    const call = bt.frontend.find("OpenFile").?;
    try testing.expectEqualStrings("wayland:headless-0", call.firstString());
}

// Lifecycle (D19) -------------------------------------------------------------

const lifecycle = app_mod.lifecycle;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const Activations = struct {
    count: u32 = 0,
    kind: lifecycle.Kind = .activate,
    remote: bool = false,
    token: [32]u8 = undefined,
    token_len: usize = 0,
    uri: [32]u8 = undefined,
    uri_len: usize = 0,

    fn cb(ctx: ?*anyopaque, a: *const lifecycle.Activation) void {
        const r: *Activations = @ptrCast(@alignCast(ctx));
        r.count += 1;
        r.kind = a.kind;
        r.remote = a.remote;
        @memcpy(r.token[0..a.token.len], a.token);
        r.token_len = a.token.len;
        if (a.uris.len > 0) {
            @memcpy(r.uri[0..a.uris[0].len], a.uris[0]);
            r.uri_len = a.uris[0].len;
        }
    }
};

fn lifecycleApp(fd: i32) !*App {
    return App.create(testing.allocator, .{
        .backend = .headless,
        .system_fonts = false,
        .threads = 1,
        .desktop_settings = false,
        .accessibility = false,
        .bus_fd = fd,
        .app_id = "org.example.Life",
    });
}

test "the first instance activates; a second forwards its URIs and token to it" {
    var bt: BusThread = .{};
    const fd = try bt.start();
    defer bt.deinit();
    _ = setenv("XDG_ACTIVATION_TOKEN", "launch-token", 1);

    const first = try lifecycleApp(fd);
    defer first.destroy();
    var acts: Activations = .{};
    try first.launch(.{}, .{ .ctx = &acts, .func = Activations.cb });
    // Not inside launch.
    try testing.expectEqual(@as(u32, 0), acts.count);
    try runUntil(first, &acts, struct {
        fn f(a: *Activations) bool {
            return a.count == 1;
        }
    }.f);
    try testing.expectEqual(lifecycle.Role.primary, first.lifecycle.role);
    try testing.expectEqual(lifecycle.Kind.activate, acts.kind);
    try testing.expect(!acts.remote);
    try testing.expectEqualStrings("launch-token", acts.token[0..acts.token_len]);
    // Taken from the environment so that children do not reuse it.
    try testing.expect(std.c.getenv("XDG_ACTIVATION_TOKEN") == null);
    try testing.expectError(error.Busy, first.launch(.{}, .{ .func = Activations.cb }));

    _ = setenv("XDG_ACTIVATION_TOKEN", "second-token", 1);
    const second = try lifecycleApp(bt.second_fd);
    defer second.destroy();
    var none: Activations = .{};
    try second.launch(.{ .uris = &.{"file:///tmp/x.txt"} }, .{ .ctx = &none, .func = Activations.cb });
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (!second.quit_requested) {
        if (Loop.now() > deadline) return error.Timeout;
        try first.dispatch(2);
        try second.dispatch(2);
    }
    try runUntil(first, &acts, struct {
        fn f(a: *Activations) bool {
            return a.count == 2;
        }
    }.f);
    try testing.expectEqual(lifecycle.Role.secondary, second.lifecycle.role);
    try testing.expectEqual(@as(u32, 0), none.count);
    try testing.expectEqual(lifecycle.Kind.open, acts.kind);
    try testing.expect(acts.remote);
    try testing.expectEqualStrings("file:///tmp/x.txt", acts.uri[0..acts.uri_len]);
    try testing.expectEqualStrings("second-token", acts.token[0..acts.token_len]);
}

test "without an application id every launch is primary, and services wait" {
    const app = try create(true);
    defer app.destroy();
    var acts: Activations = .{};
    try app.launch(.{ .service = true }, .{ .ctx = &acts, .func = Activations.cb });
    try testing.expectEqual(lifecycle.Role.primary, app.lifecycle.role);
    for (0..5) |_| try app.dispatch(1);
    // Started by D-Bus activation: nothing until the desktop calls.
    try testing.expectEqual(@as(u32, 0), acts.count);
}

test "windows follow the application's language and direction unless they set their own" {
    const app = try App.create(testing.allocator, .{
        .backend = .headless,
        .headless = .{ .refresh_ns = std.time.ns_per_ms },
        .system_fonts = false,
        .threads = 2,
        .compositor_thread = false,
        .desktop_settings = false,
        .accessibility = false,
        .language = "ar-EG",
    });
    defer app.destroy();
    // Arabic is written right to left.
    try testing.expect(app.rtl);
    const follows = try app.createWindow(.{}, .{});
    const own = try app.createWindow(.{ .rtl = false, .language = "en" }, .{});
    try testing.expect(follows.ui.rtl);
    try testing.expectEqualStrings("ar-EG", app.fonts.name(follows.ui.language));
    try testing.expect(!own.ui.rtl);

    try app.setLocale("de", null);
    try testing.expect(!app.rtl);
    try testing.expect(!follows.ui.rtl);
    try testing.expectEqualStrings("de", app.fonts.name(follows.ui.language));
    try testing.expectEqualStrings("en", app.fonts.name(own.ui.language));
    // A direction set against the language's.
    try app.setLocale("de", true);
    try testing.expect(follows.ui.rtl);
    try testing.expect(!own.ui.rtl);
}

// The user's theme (D29) ------------------------------------------------------

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn system(cmd: [*:0]const u8) c_int;

fn sh(comptime fmt: []const u8, args: anytype) !void {
    var buf: [2048]u8 = undefined;
    const cmd = try std.fmt.bufPrintSentinel(&buf, fmt, args, 0);
    if (system(cmd.ptr) != 0) return error.ShellFailed;
}

const ThemeCheck = struct {
    app: *App,
    win: *Window,
    want: [4]u8,

    fn shows(c: *ThemeCheck) bool {
        if (!settled(c.win)) return false;
        const px = firstPixel(c.app, c.win.id) catch return false;
        return std.mem.eql(u8, &px, &c.want);
    }
};

fn idle(ut: *app_mod.user_theme.UserTheme) bool {
    return !ut.watch.timer.armed() and !ut.running;
}

test "the user's theme: read at startup, and followed live as Omarchy renames a theme into place; windows hear when their colors change" {
    var template = "/tmp/siv-theme-XXXXXX".*;
    const home = std.mem.span(mkdtemp(&template) orelse return error.SkipZigTest);
    defer sh("rm -rf '{s}'", .{home}) catch {};
    const cur = "{s}/.local/state/omarchy/current";
    // ~/.config exists; its siv folder does not yet.
    try sh("mkdir -p '{s}/.config' '" ++ cur ++ "/theme' && printf 'mode = \"dark\"\\nbackground = \"#1a1b26\"\\nforeground = \"#a9b1d6\"\\n' > '" ++ cur ++ "/theme/colors.toml'", .{ home, home, home });
    var config_buf: [64]u8 = undefined;
    const config = try std.fmt.bufPrint(&config_buf, "{s}/.config", .{home});
    const app = try App.create(testing.allocator, .{
        .backend = .headless,
        .headless = .{ .refresh_ns = std.time.ns_per_ms },
        .system_fonts = false,
        .threads = 2,
        .desktop_settings = false,
        .accessibility = false,
        .user_theme = .{ .home = home, .config_home = config },
    });
    defer app.destroy();
    var rec: Recorder = .{};
    const win = try app.createWindow(.{ .width = 16, .height = 16 }, rec.listener());
    const t = try win.ui.begin();
    try t.setVisual(.root, .{ .background_token = .view_bg });
    t.commit();
    // The theme's background (B, G, R, A), read before the first frame
    // unless the read took longer than first frames wait.
    var check: ThemeCheck = .{ .app = app, .win = win, .want = .{ 0x26, 0x1b, 0x1a, 0xff } };
    try runUntil(app, win, settled);
    try testing.expectEqual(check.want, try firstPixel(app, win.id));
    try testing.expectEqual(ui.theme.Scheme.dark, app.user_theme.value.scheme.?);
    // From siv's compiled colors to the theme's.
    try testing.expectEqual(@as(usize, 1), rec.theme_changes);

    // omarchy-theme-set: stage the next theme, delete the current one,
    // rename the staged one into place. Between the two the old theme
    // stays: nothing flashes siv's compiled colors.
    try sh("mkdir '" ++ cur ++ "/next-theme' && printf 'mode = \"light\"\\nbackground = \"#eff1f5\"\\nforeground = \"#4c4f69\"\\n' > '" ++ cur ++ "/next-theme/colors.toml' && rm -rf '" ++ cur ++ "/theme'", .{ home, home, home });
    try runUntil(app, &app.user_theme.watch, struct {
        fn f(w: *@import("watch.zig").Watch) bool {
            return w.timer.armed();
        }
    }.f);
    try runUntil(app, &app.user_theme, idle);
    try testing.expectEqual(ui.theme.Scheme.dark, app.user_theme.value.scheme.?);
    try testing.expectEqual(@as(usize, 1), rec.theme_changes);
    try sh("mv '" ++ cur ++ "/next-theme' '" ++ cur ++ "/theme'", .{ home, home });
    check.want = .{ 0xf5, 0xf1, 0xef, 0xff };
    try runUntil(app, &check, ThemeCheck.shows);
    try testing.expectEqual(ui.theme.Scheme.light, app.user_theme.value.scheme.?);
    try testing.expectEqual(@as(usize, 2), rec.theme_changes);
    // Below, a read may catch a file half written (empty, so siv's
    // colors for a moment); each change is at least one event.
    var changes = rec.theme_changes;

    // theme.toml, made later in a folder that did not exist, decides
    // over Omarchy; with base = "omarchy" it lies over Omarchy's theme.
    try sh("mkdir -p '{s}/siv' && printf 'view_bg = \"#ff0000\"\\n' > '{s}/siv/theme.toml'", .{ config, config });
    check.want = .{ 0, 0, 0xff, 0xff };
    try runUntil(app, &check, ThemeCheck.shows);
    try testing.expectEqual(ui.theme.User.Source.file, app.user_theme.value.source);
    try testing.expect(app.user_theme.value.scheme == null);
    try testing.expect(rec.theme_changes > changes);
    changes = rec.theme_changes;
    try sh("printf 'base = \"omarchy\"\\n[dark]\\nview_bg = \"#00ff00\"\\n' > '{s}/siv/theme.toml'", .{config});
    // Omarchy's light theme, which the file leaves alone.
    check.want = .{ 0xf5, 0xf1, 0xef, 0xff };
    try runUntil(app, &check, ThemeCheck.shows);
    try testing.expect(rec.theme_changes > changes);
    changes = rec.theme_changes;
    // A broken file is no theme: siv's compiled light background.
    try sh("printf 'view_bg = \"#12' > '{s}/siv/theme.toml'", .{config});
    check.want = .{ 0xff, 0xff, 0xff, 0xff };
    try runUntil(app, &check, ThemeCheck.shows);
    try testing.expect(rec.theme_changes > changes);
    changes = rec.theme_changes;
    // A theme for the dark variant only is a new theme, but the light
    // window's colors stay, as they would half written: no event.
    try sh("printf '[dark]\\nview_bg = \"#00ff00\"\\n' > '{s}/siv/theme.toml'", .{config});
    try runUntil(app, &app.user_theme.value, struct {
        fn f(u: *const ui.theme.User) bool {
            return u.colors[@intFromEnum(ui.theme.Scheme.dark)][@intFromEnum(ui.theme.ColorToken.view_bg)] != null;
        }
    }.f);
    for (0..2) |_| try app.dispatch(0);
    try testing.expectEqual(changes, rec.theme_changes);
}

// Fonts (D19) -----------------------------------------------------------------

const desktop = @import("desktop.zig");

test "fonts: the portal's font names apply only on desktops that own a font setting" {
    try testing.expect(desktop.ownsFonts("GNOME"));
    try testing.expect(desktop.ownsFonts("ubuntu:GNOME"));
    try testing.expect(desktop.ownsFonts("KDE"));
    try testing.expect(desktop.ownsFonts("kde"));
    try testing.expect(!desktop.ownsFonts("Hyprland"));
    try testing.expect(!desktop.ownsFonts("sway:wlroots"));
    try testing.expect(!desktop.ownsFonts("niri"));
    try testing.expect(!desktop.ownsFonts("GNOME-Flashback-ish"));
    try testing.expect(!desktop.ownsFonts(""));

    // What GTK's portal backend reports on Hyprland: GNOME's defaults.
    var v: @import("dbus").Settings.Values = .{};
    v.font = .{ .family = .init("Adwaita Sans"), .size = 13 };
    v.monospace_font = .{ .family = .init("Adwaita Mono"), .size = 11 };
    v.text_scale = 1.25;
    const elsewhere = desktop.effective(v, false);
    try testing.expectEqualStrings("sans-serif", elsewhere.font.family.slice());
    try testing.expectEqualStrings("monospace", elsewhere.monospace_font.family.slice());
    try testing.expectEqual(@as(f64, 11), elsewhere.font.size);
    // The text scale still applies everywhere (Omarchy's text size).
    try testing.expectEqual(@as(f64, 1.25), elsewhere.text_scale);
    const gnome = desktop.effective(v, true);
    try testing.expectEqualStrings("Adwaita Mono", gnome.monospace_font.family.slice());
    try testing.expectEqual(@as(f64, 13), gnome.font.size);
}

/// A hash of the presented frame.
fn frameHash(app: *App, id: platform.WindowId) !u64 {
    const Ctx = struct {
        id: platform.WindowId,
        out: ?u64 = null,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            const img = comp.platform.headless.presented(c.id) orelse return;
            c.out = std.hash.Wyhash.hash(0, img.pixels);
        }
    };
    var ctx: Ctx = .{ .id = id };
    try app.comp.call(&ctx, Ctx.run);
    return ctx.out orelse error.NothingPresented;
}

/// The file of the font `family` resolves to first.
fn firstFontFile(app: *App, family: []const u8) ![]const u8 {
    const chain = try app.fonts.chain(.{ .family = try app.fonts.intern(family), .language = 0, .weight = 400, .slant = .roman });
    if (chain.len == 0) return error.NoFont;
    return std.fs.path.basename(app.fonts.cache.source(chain[0]).path);
}

const FontCheck = struct {
    app: *App,
    win: *Window,
    family: []const u8,
    want: []const u8,

    fn resolved(c: *FontCheck) bool {
        const file = firstFontFile(c.app, c.family) catch return false;
        return std.mem.eql(u8, file, c.want) and settled(c.win);
    }
};

test "fonts: monospace follows Fontconfig's alias, live as fonts.conf changes" {
    var template = "/tmp/siv-fc-XXXXXX".*;
    const dir = std.mem.span(mkdtemp(&template) orelse return error.SkipZigTest);
    defer sh("rm -rf '{s}'", .{dir}) catch {};
    // A configuration of siv's test fonts only, as `omarchy font set`
    // writes it: the chosen family first for monospace.
    const conf =
        \\printf '<?xml version="1.0"?>
        \\<fontconfig><dir>%s/src/text/testdata</dir><cachedir>{s}/cache</cachedir>
        \\<match target="pattern"><test name="family" qual="any"><string>monospace</string></test>
        \\<edit name="family" mode="prepend_first" binding="strong"><string>{s}</string></edit></match>
        \\</fontconfig>\n' "$(pwd)" > '{s}/fonts.conf'
    ;
    try sh(conf, .{ dir, "SivTest", dir });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/fonts.conf", .{dir}, 0);
    const old = std.c.getenv("FONTCONFIG_FILE");
    _ = setenv("FONTCONFIG_FILE", path.ptr, 1);
    defer if (old) |o| {
        _ = setenv("FONTCONFIG_FILE", o, 1);
    } else {
        _ = unsetenv("FONTCONFIG_FILE");
    };

    const app = try App.create(testing.allocator, .{
        .backend = .headless,
        .headless = .{ .refresh_ns = std.time.ns_per_ms },
        .threads = 2,
        .desktop_settings = false,
        .accessibility = false,
        .follow_fontconfig = true,
        .desktop_fonts = false,
    });
    defer app.destroy();
    if (app.fonts.database == null) return error.SkipZigTest;
    const win = try app.createWindow(.{ .width = 160, .height = 40 }, .{});
    const t = try win.ui.begin();
    try t.setVisual(.root, .{ .background = .white });
    const label = try t.create(.root, .text, .none);
    try t.setText(label, "Mono 0123");
    try t.setTextProps(label, .{ .style = .{ .family = "monospace", .size = 20, .color = .black }, .wrap = false });
    t.commit();
    var check: FontCheck = .{ .app = app, .win = win, .family = "monospace", .want = "SivTest-Regular.ttf" };
    try runUntil(app, &check, FontCheck.resolved);
    const before = try frameHash(app, win.id);

    // `omarchy font set "Droid Sans"` rewrites fonts.conf in place.
    try sh(conf, .{ dir, "Droid Sans", dir });
    check.want = "DroidSans.ttf";
    try runUntil(app, &check, FontCheck.resolved);
    // The open window shows its text in the new font.
    const Changed = struct {
        app: *App,
        win: *Window,
        before: u64,
        fn f(c: *@This()) bool {
            return settled(c.win) and (frameHash(c.app, c.win.id) catch c.before) != c.before;
        }
    };
    var changed: Changed = .{ .app = app, .win = win, .before = before };
    try runUntil(app, &changed, Changed.f);
}

extern "c" fn unsetenv(name: [*:0]const u8) c_int;
