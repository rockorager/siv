//! The application's session bus connection, and desktop settings on it
//! (D19): one portal Settings client, started at application creation in
//! parallel with the Wayland connection. The AT-SPI bridge (D18) shares
//! the connection. Their values go into every
//! window's `ui.Desktop` at startup and on every change, and the desktop
//! font becomes the default family.
//!
//! Fonts come from Fontconfig's generic families, `sans-serif` and
//! `monospace`, which the user's fonts.conf decides, except on desktops
//! that own a font setting, GNOME and KDE: there the portal's font names
//! and size apply (`ownsFonts`). Elsewhere the portal reports a GTK
//! default nobody chose.
//!
//! First frames wait for the settings, at most `first_frame_wait_ns` from
//! application creation, so a dark-theme user never sees a light first
//! frame: frame events that arrive while waiting are held and asked for
//! again when the settings are ready, the wait times out, or the bus goes
//! away. Without a session bus there is nothing to wait for.

const std = @import("std");
const dbus = @import("dbus");
const portal = @import("portal");
const ui = @import("ui");
const loop_mod = @import("loop");
const app_mod = @import("app.zig");
const compositor = @import("compositor");

const Loop = loop_mod.Loop;
const Timer = loop_mod.Timer;
const App = app_mod.App;

pub const first_frame_wait_ns: u64 = 100 * std.time.ns_per_ms;

pub const Desktop = struct {
    bus: dbus.Connection = undefined,
    settings: dbus.Settings = undefined,
    /// The session bus is connected.
    connected: bool = false,
    /// The Settings client runs.
    reading: bool = false,
    /// First frames are held until the settings are ready.
    waiting: bool = false,
    timer: Timer = .{ .func = onTimeout },
    /// What every window follows.
    values: ui.Desktop = .{},
    /// The portal's font names and size apply (`ownsFonts`).
    owns_fonts: bool = false,
    /// For measurements: application creation and the first read.
    started_ns: u64 = 0,
    ready_ns: ?u64 = null,

    /// Connects to the session bus (or `address`, or the connected socket
    /// `fd`) and, with `settings`, starts reading them. Failures leave the
    /// defaults in effect. A host application registers its `app_id` with
    /// the portal first, as xdg-desktop-portal requires (portals.zig).
    pub fn start(d: *Desktop, app: *App, address: ?[]const u8, fd: ?i32, settings: bool, app_id: []const u8) void {
        d.started_ns = Loop.now();
        const options: dbus.Connection.Options = .{ .on_event = onBusEvent, .ctx = app };
        if (fd) |f| {
            d.bus.initFd(app.gpa, &app.loop, f, options) catch {
                _ = std.os.linux.close(f);
                return;
            };
        } else {
            var buf: [256]u8 = undefined;
            const addr = address orelse dbus.address.session(&buf) orelse return;
            d.bus.init(app.gpa, &app.loop, addr, options) catch return;
        }
        d.connected = true;
        portal.Client.register(&d.bus, app_id) catch {};
        if (!settings) return;
        d.settings.init(&d.bus, .{ .on_change = onChange, .ctx = app }) catch return;
        d.reading = true;
        app.loop.startTimer(&d.timer, d.started_ns + first_frame_wait_ns, 0) catch {
            // Without a timeout, do not wait at all.
            return;
        };
        d.waiting = true;
    }

    pub fn deinit(d: *Desktop, app: *App) void {
        app.loop.cancelTimer(&d.timer);
        if (d.reading) d.settings.deinit();
        if (d.connected) d.bus.deinit();
        d.reading = false;
        d.connected = false;
    }
};

/// Whether the desktop owns a font setting that its users change rather
/// than Fontconfig's configuration: GNOME and KDE, by
/// $XDG_CURRENT_DESKTOP's colon-separated names (D19).
pub fn ownsFonts(current_desktop: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, current_desktop, ':');
    while (it.next()) |name| {
        if (std.ascii.eqlIgnoreCase(name, "GNOME") or std.ascii.eqlIgnoreCase(name, "KDE")) return true;
    }
    return false;
}

/// The portal's values siv follows: without a desktop that owns fonts,
/// Fontconfig's generic families at 11 pt.
pub fn effective(v: dbus.Settings.Values, owns_fonts: bool) dbus.Settings.Values {
    if (owns_fonts) return v;
    const def: dbus.Settings.Values = .{};
    var out = v;
    out.font = def.font;
    out.document_font = def.document_font;
    out.monospace_font = def.monospace_font;
    return out;
}

fn desktopOf(v: dbus.Settings.Values) ui.Desktop {
    var out: ui.Desktop = .{};
    // ui.Desktop has the names of the portal's values, and their types
    // or enums with the same tags.
    inline for (@typeInfo(ui.Desktop).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "font_size")) continue;
        const F = @FieldType(ui.Desktop, name);
        @field(out, name) = if (@typeInfo(F) == .@"enum") std.meta.stringToEnum(F, @tagName(@field(v, name))).? else @field(v, name);
    }
    out.font_size = v.font.size;
    return out;
}

fn onChange(ctx: ?*anyopaque, s: *dbus.Settings, changed: dbus.Settings.Changed) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const d = &app.desktop;
    const first = d.ready_ns == null;
    if (first) d.ready_ns = Loop.now();
    const v = effective(s.values, d.owns_fonts);
    d.values = desktopOf(v);
    for (app.windows.items) |w| if (w) |win| {
        const old = win.ui.palette;
        win.ui.setDesktop(d.values);
        win.paletteApplied(&old);
    };
    if (first or changed.cursor_theme or changed.cursor_size) setCursorTheme(app, s.values.cursor_theme.slice(), s.values.cursor_size);
    if ((first or changed.icon_theme) and !app.icon_theme_overridden) app.icons.setTheme(s.values.icon_theme.slice()) catch app.fail(error.OutOfMemory);
    var refresh = changed.text_scale;
    const fonts = first or (d.owns_fonts and (changed.font or changed.monospace_font));
    if (fonts and !app.font_overridden) app.fonts.setDefault(v.font.family.slice()) catch app.fail(error.OutOfMemory);
    if (fonts) {
        app.fonts.setMonospace(v.monospace_font.family.slice()) catch app.fail(error.OutOfMemory);
        refresh = true;
    }
    if (refresh) app.refreshText();
    release(app);
}

/// Themed cursors (D16) follow the desktop's theme and size, on the
/// compositor thread.
fn setCursorTheme(app: *App, name: []const u8, size: u32) void {
    const Req = struct {
        gpa: std.mem.Allocator,
        name: [64]u8,
        len: usize,
        size: u32,
        fn run(c: ?*anyopaque, comp: *compositor.Compositor) void {
            const r: *@This() = @ptrCast(@alignCast(c));
            comp.platform.setCursorTheme(r.name[0..r.len], r.size);
            drop(c);
        }
        fn drop(c: ?*anyopaque) void {
            const r: *@This() = @ptrCast(@alignCast(c));
            r.gpa.destroy(r);
        }
    };
    const r = app.gpa.create(Req) catch return app.fail(error.OutOfMemory);
    r.* = .{ .gpa = app.gpa, .name = undefined, .len = @min(name.len, 64), .size = size };
    @memcpy(r.name[0..r.len], name[0..r.len]);
    app.comp.post(r, Req.run, Req.drop) catch {
        Req.drop(r);
        app.fail(error.OutOfMemory);
    };
}

fn onBusEvent(ctx: ?*anyopaque, _: *dbus.Connection, event: dbus.Connection.Event) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.portals.connectionEvent(event == .ready);
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
    app.releaseFrames();
}
