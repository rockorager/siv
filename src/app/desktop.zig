//! Desktop settings for the application (D19): one session bus connection
//! and one portal Settings client, started at application creation in
//! parallel with the Wayland connection. Their values go into every
//! window's `ui.Desktop` at startup and on every change, and the desktop
//! font becomes the default family.
//!
//! First frames wait for the settings, at most `first_frame_wait_ns` from
//! application creation, so a dark-theme user never sees a light first
//! frame: frame events that arrive while waiting are held and asked for
//! again when the settings are ready, the wait times out, or the bus goes
//! away. Without a session bus there is nothing to wait for.

const std = @import("std");
const dbus = @import("dbus");
const ui = @import("ui");
const loop_mod = @import("loop");
const app_mod = @import("app.zig");

const Loop = loop_mod.Loop;
const Timer = loop_mod.Timer;
const App = app_mod.App;

pub const first_frame_wait_ns: u64 = 100 * std.time.ns_per_ms;

pub const Desktop = struct {
    bus: dbus.Connection = undefined,
    settings: dbus.Settings = undefined,
    connected: bool = false,
    /// First frames are held until the settings are ready.
    waiting: bool = false,
    timer: Timer = .{ .func = onTimeout },
    /// What every window follows.
    values: ui.Desktop = .{},
    /// For measurements: application creation and the first read.
    started_ns: u64 = 0,
    ready_ns: ?u64 = null,

    /// Connects to the session bus (or `address`) and starts reading.
    /// Failures leave the defaults in effect.
    pub fn start(d: *Desktop, app: *App, address: ?[]const u8) void {
        d.started_ns = Loop.now();
        var buf: [256]u8 = undefined;
        const addr = address orelse dbus.address.session(&buf) orelse return;
        d.bus.init(app.gpa, &app.loop, addr, .{ .on_event = onBusEvent, .ctx = app }) catch return;
        d.settings.init(&d.bus, .{ .on_change = onChange, .ctx = app }) catch {
            d.bus.deinit();
            return;
        };
        d.connected = true;
        app.loop.startTimer(&d.timer, d.started_ns + first_frame_wait_ns, 0) catch {
            // Without a timeout, do not wait at all.
            return;
        };
        d.waiting = true;
    }

    pub fn deinit(d: *Desktop, app: *App) void {
        app.loop.cancelTimer(&d.timer);
        if (!d.connected) return;
        d.settings.deinit();
        d.bus.deinit();
        d.connected = false;
    }
};

fn desktopOf(v: dbus.Settings.Values) ui.Desktop {
    var out: ui.Desktop = .{};
    // ui.Desktop has the names and types of the portal's values.
    inline for (@typeInfo(ui.Desktop).@"struct".field_names) |name| @field(out, name) = @field(v, name);
    return out;
}

fn onChange(ctx: ?*anyopaque, s: *dbus.Settings, changed: dbus.Settings.Changed) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const d = &app.desktop;
    const first = d.ready_ns == null;
    if (first) d.ready_ns = Loop.now();
    d.values = desktopOf(s.values);
    for (app.windows.items) |w| if (w) |win| win.ui.setDesktop(d.values);
    var refresh = changed.text_scale;
    if ((first or changed.font) and !app.font_overridden) {
        app.fonts.setDefault(s.values.font.family.slice()) catch app.fail(error.OutOfMemory);
        refresh = true;
    }
    if (refresh) app.refreshText();
    release(app);
}

fn onBusEvent(ctx: ?*anyopaque, _: *dbus.Connection, event: dbus.Connection.Event) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    // Without a bus the settings never come; stop waiting for them.
    if (event == .disconnected) release(app);
}

fn onTimeout(timer: *Timer) void {
    const d: *Desktop = @fieldParentPtr("timer", timer);
    const app: *App = @fieldParentPtr("desktop", d);
    release(app);
}

/// Stops holding first frames and asks again for the ones held.
fn release(app: *App) void {
    const d = &app.desktop;
    if (!d.waiting) return;
    d.waiting = false;
    app.loop.cancelTimer(&d.timer);
    for (app.windows.items) |w| if (w) |win| win.releaseFrame();
}
