//! Exports for system signals (D42, api_system.zig): the state the
//! coordinator follows (`app.system`), and monitors that hear its
//! changes at safe points (D5), after siv's own handling.

const std = @import("std");
const t = @import("siv");
const app_mod = @import("app");
const api = @import("api.zig");
const runtime = @import("runtime.zig");
const application = @import("application.zig");

const App = application.App;
const Error = application.Error;
const Root = runtime.Root;
const Change = app_mod.system.Change;

pub const monitor_tag = api.spec.handleTag("siv_system_monitor");

pub const State = struct {
    /// By handle payload; null slots are reused.
    monitors: std.ArrayList(?*Monitor) = .empty,
};

const Monitor = struct {
    owner: *App,
    index: u32,
    handle: u64 = 0,
    on_event: ?t.SystemFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn remove(m: *Monitor) void {
        const self = m.owner;
        _ = self.root.handles.remove(m.handle, monitor_tag) catch unreachable;
        self.system.monitors.items[m.index] = null;
        self.release(m.destroy, m.user_data);
        self.gpa().destroy(m);
    }
};

pub fn teardown(self: *App) void {
    self.app.system.listener = null;
    for (self.system.monitors.items) |slot| if (slot) |m| m.remove();
    self.system.monitors.deinit(self.gpa());
}

fn stateOf(self: *App) t.SystemState {
    const n = self.app.system.network();
    return .{
        .flags = .{ .power_saver = self.app.system.powerSaver(), .network_available = n.available, .network_metered = n.metered },
        .connectivity = switch (n.connectivity) {
            .full => .full,
            .limited => .limited,
            .captive_portal => .captive_portal,
            .local => .local,
        },
    };
}

/// The coordinator's listener: every monitor hears the change.
fn onChange(ctx: ?*anyopaque, change: Change) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    var e: t.SystemEvent = .{ .state = stateOf(self) };
    switch (change) {
        .power_saver => e.type = .power_saver,
        .network => e.type = .network,
        .memory => |level| {
            e.type = .memory;
            e.memory_pressure = switch (level) {
                .low => .low,
                .medium => .medium,
                .critical => .critical,
            };
        },
    }
    self.enter();
    defer self.leave();
    // A callback may destroy monitors, its own included, or create new
    // ones, which hear the next change.
    const n = self.system.monitors.items.len;
    for (0..n) |i| {
        const m = self.system.monitors.items[i] orelse continue;
        const cb = m.on_event orelse continue;
        cb(m.user_data, @fromBackingInt(m.handle), &e);
    }
}

pub export fn siv_app_get_system_state(app: t.App, state: ?*t.SystemState) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const dest = runtime.out(t.SystemState, state) catch |err| return t.resultOf(err);
    dest.* = stateOf(self);
    return .ok;
}

pub export fn siv_system_monitor_create(app: t.App, desc: ?*const t.SystemMonitorDesc, monitor: ?*t.SystemMonitor) t.Result {
    const d = runtime.readDesc(t.SystemMonitorDesc, desc) catch |err| return t.resultOf(err);
    const self = App.get(@backingInt(app)) catch |err| {
        if (d.destroy) |f| f(d.user_data);
        return t.resultOf(err);
    };
    const r = application.wrap(create(self, &d, monitor));
    // The call failed: the caller handed user_data over anyway (D2).
    if (r != .ok) self.release(d.destroy, d.user_data);
    return r;
}

fn create(self: *App, d: *const t.SystemMonitorDesc, out: ?*t.SystemMonitor) Error!void {
    const dest = try runtime.out(t.SystemMonitor, out);
    const gpa = self.gpa();
    const list = &self.system.monitors;
    const index: u32 = for (list.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        try list.append(gpa, null);
        break :blk @intCast(list.items.len - 1);
    };
    const m = try gpa.create(Monitor);
    errdefer gpa.destroy(m);
    m.* = .{ .owner = self, .index = index, .on_event = d.on_event, .destroy = d.destroy, .user_data = d.user_data };
    try self.root.handles.ensureUnusedCapacity(gpa);
    m.handle = self.root.handles.insert(gpa, monitor_tag, index) catch unreachable;
    list.items[index] = m;
    self.app.system.listener = .{ .ctx = self, .func = onChange };
    dest.* = @fromBackingInt(m.handle);
}

pub export fn siv_test_system_signal(app: t.App, desc: ?*const t.SystemEvent) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const e = runtime.readDesc(t.SystemEvent, desc) catch |err| return t.resultOf(err);
    if (!self.headless) return .error_unsupported;
    _ = runtime.enumValue(t.SystemEventType, e.type) catch |err| return t.resultOf(err);
    _ = runtime.enumValue(t.MemoryPressure, e.memory_pressure) catch |err| return t.resultOf(err);
    _ = runtime.enumValue(t.NetworkConnectivity, e.state.connectivity) catch |err| return t.resultOf(err);
    _ = runtime.flags(t.SystemFlags, e.state.flags) catch |err| return t.resultOf(err);
    if (self.depth != 0) return .error_busy;
    const fl = e.state.flags;
    self.app.system.simulate(self.app, switch (e.type) {
        .power_saver => .{ .power_saver = fl.power_saver },
        .memory => .{ .memory = switch (e.memory_pressure) {
            .low => .low,
            .medium => .medium,
            .critical => .critical,
            _ => unreachable,
        } },
        .network => .{ .network = .{ .available = fl.network_available, .metered = fl.network_metered, .connectivity = switch (e.state.connectivity) {
            .full => .full,
            .limited => .limited,
            .captive_portal => .captive_portal,
            .local => .local,
            _ => unreachable,
        } } },
        _ => unreachable,
    });
    return .ok;
}

pub export fn siv_system_monitor_destroy(monitor: t.SystemMonitor) void {
    const self, const index = Root.owner(App, application.app_tag, @backingInt(monitor), monitor_tag) catch return;
    const m = self.system.monitors.items[index] orelse return;
    m.remove();
}
