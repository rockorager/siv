//! System signals (D42): power saving, memory pressure, and the network,
//! from the portals or the system services behind them
//! (`portal.monitor`), and what siv does with them itself.
//!
//! - Power saving stops caret blinking in every window (desktop.zig's
//!   `apply`), the one motion siv runs while the user does nothing.
//! - A memory warning drops what siv can rebuild: at every level the
//!   icon cache, long texts' blocks and documents' layout caches not on
//!   screen, and the C library's free heap pages; from medium up also
//!   the renderers' glyph caches and, on Vulkan, textures not drawn.
//! - Every change reaches the listener (the ABI's monitors) after siv's
//!   own handling.

const std = @import("std");
const builtin = @import("builtin");
const dbus = @import("dbus");
const portal = @import("portal");
const app_mod = @import("app.zig");
const desktop = @import("desktop.zig");

const App = app_mod.App;
const monitor = portal.monitor;

pub const Change = monitor.Change;
pub const Network = monitor.Network;
pub const MemoryLevel = monitor.MemoryLevel;

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, change: Change) void,
};

pub const System = struct {
    monitor: monitor.Monitor = undefined,
    /// The monitor was started (and needs `deinit`).
    running: bool = false,
    /// Its values are set: started, or simulated (`simulate`).
    active: bool = false,
    listener: ?Listener = null,
    /// Memory warnings received, for tests.
    trims: u32 = 0,

    /// Starts following the signals on the session bus `session`, with
    /// `system_bus` for the fallbacks.
    pub fn start(s: *System, app: *App, session: ?*dbus.Connection, system_bus: monitor.SystemBus) void {
        s.monitor = .{ .gpa = app.gpa, .loop = &app.loop, .func = onChange };
        s.running = true;
        s.active = true;
        s.monitor.start(session, system_bus);
    }

    /// A change as if the monitor had reported it (the headless backend's
    /// siv_test_system_signal): the same handling, at once.
    pub fn simulate(s: *System, app: *App, change: Change) void {
        if (!s.active) {
            s.monitor = .{ .gpa = app.gpa, .loop = &app.loop, .func = onChange };
            s.active = true;
        }
        switch (change) {
            .power_saver => |on| {
                if (s.monitor.power_saver == on) return;
                s.monitor.power_saver = on;
            },
            .network => |n| {
                if (s.monitor.network.eql(n)) return;
                s.monitor.network = n;
            },
            .memory => {},
        }
        onChange(&s.monitor, change);
    }

    pub fn deinit(s: *System) void {
        if (s.running) s.monitor.deinit();
        s.running = false;
        s.active = false;
    }

    pub fn powerSaver(s: *const System) bool {
        return s.active and s.monitor.power_saver;
    }

    pub fn network(s: *const System) Network {
        return if (s.active) s.monitor.network else .{};
    }
};

fn onChange(m: *monitor.Monitor, change: Change) void {
    const s: *System = @fieldParentPtr("monitor", m);
    const app: *App = @fieldParentPtr("system", s);
    switch (change) {
        .power_saver => desktop.apply(app),
        .memory => |level| trim(app, level),
        .network => {},
    }
    if (s.listener) |l| l.func(l.ctx, change);
}

/// Drops siv's caches for a memory warning of `level`.
pub fn trim(app: *App, level: MemoryLevel) void {
    app.system.trims += 1;
    app.icons.trim();
    app.fonts.trim();
    for (app.windows.items) |w| if (w) |win| win.ui.trimMemory();
    if (level != .low) app.comp.trimCaches() catch {};
    trimHeap();
}

/// glibc's malloc_trim hands free pages of its heaps back to the system;
/// other C libraries go without (text_node.zig does the same).
fn trimHeap() void {
    if (comptime !(builtin.link_libc and builtin.target.isGnuLibC())) return;
    const malloc_trim = @extern(*const fn (usize) callconv(.c) c_int, .{ .name = "malloc_trim" });
    _ = malloc_trim(0);
}
