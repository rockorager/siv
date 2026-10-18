//! Exports for settings and state (D36, api_settings.zig): handles over
//! the coordinator's stores (`app.settings`), and windows that keep their
//! size and states in one (siv_window_desc.settings).

const std = @import("std");
const t = @import("siv");
const app_mod = @import("app");
const platform = @import("platform");
const api = @import("api.zig");
const runtime = @import("runtime.zig");
const application = @import("application.zig");

const App = application.App;
const Root = runtime.Root;
const Error = application.Error;
const Store = app_mod.settings.Store;
const Value = app_mod.settings.Value;
const validKey = app_mod.settings.validKey;

pub const settings_tag = api.spec.handleTag("siv_settings");

/// The application's stores, by handle payload; null slots are reused.
pub const State = struct {
    stores: std.ArrayList(?*Settings) = .empty,
};

pub const Settings = struct {
    owner: *App,
    index: u32,
    handle: u64,
    store: *Store,
    on_change: ?t.SettingsChangeFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    /// Destroyed, or dropped with the application. The store writes what
    /// is left and goes on its own.
    fn remove(s: *Settings) void {
        const self = s.owner;
        s.store.close();
        _ = self.root.handles.remove(s.handle, settings_tag) catch unreachable;
        self.settings.stores.items[s.index] = null;
        self.release(s.destroy, s.user_data);
        self.gpa().destroy(s);
    }
};

fn onChange(ctx: ?*anyopaque, key: []const u8, origin: app_mod.settings.Origin) void {
    const s: *Settings = @ptrCast(@alignCast(ctx));
    const cb = s.on_change orelse return;
    const self = s.owner;
    const e: t.SettingsChange = .{ .key = key.ptr, .key_len = key.len, .origin = switch (origin) {
        .application => .application,
        .outside => .outside,
    } };
    // The callback may destroy the store: nothing touches it after.
    self.enter();
    cb(s.user_data, @fromBackingInt(s.handle), &e);
    self.leave();
}

pub fn teardown(self: *App) void {
    for (self.settings.stores.items) |slot| if (slot) |s| s.remove();
    self.settings.stores.deinit(self.gpa());
}

pub export fn siv_settings_open(app: t.App, desc: ?*const t.SettingsDesc, settings: ?*t.Settings) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const d = runtime.readDesc(t.SettingsDesc, desc) catch |err| return t.resultOf(err);
    open(self, d, settings) catch |err| {
        // The call failed: the caller handed user_data over anyway (D2).
        self.release(d.destroy, d.user_data);
        return t.resultOf(err);
    };
    return .ok;
}

fn open(self: *App, d: t.SettingsDesc, out: ?*t.Settings) Error!void {
    const kind = try runtime.enumValue(t.SettingsKind, d.kind);
    const name = try runtime.string(d.name, d.name_len);
    const directory = try runtime.string(d.directory, d.directory_len);
    const dest = try runtime.out(t.Settings, out);
    const gpa = self.gpa();
    const list = &self.settings.stores;
    const index: u32 = for (list.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        try list.append(gpa, null);
        break :blk @intCast(list.items.len - 1);
    };
    const s = try gpa.create(Settings);
    errdefer gpa.destroy(s);
    try self.root.handles.ensureUnusedCapacity(gpa);
    s.* = .{ .owner = self, .index = index, .handle = 0, .store = undefined, .on_change = d.on_change, .destroy = d.destroy, .user_data = d.user_data };
    s.store = Store.open(self.app, .{
        .kind = switch (kind) {
            .config => .config,
            .state => .state,
            _ => unreachable,
        },
        .name = name,
        .directory = directory,
        .memory = self.headless and directory.len == 0,
        .listener = .{ .ctx = s, .func = onChange },
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArgument => error.InvalidArgument,
        error.Busy => error.Busy,
        error.Unavailable => error.Unavailable,
    };
    s.handle = self.root.handles.insert(gpa, settings_tag, index) catch unreachable;
    list.items[index] = s;
    dest.* = @fromBackingInt(s.handle);
}

pub fn lookup(settings: t.Settings) runtime.Error!*Settings {
    const self, const index = try Root.owner(App, application.app_tag, @backingInt(settings), settings_tag);
    if (index >= self.settings.stores.items.len) return error.InvalidHandle;
    return self.settings.stores.items[index] orelse error.InvalidHandle;
}

pub export fn siv_settings_destroy(settings: t.Settings) void {
    const s = lookup(settings) catch return;
    s.remove();
}

fn keyOf(ptr: ?[*]const u8, len: usize) runtime.Error![]const u8 {
    const key = try runtime.string(ptr, len);
    if (!validKey(key)) return error.InvalidArgument;
    return key;
}

/// The store and the key's value, for a getter.
fn read(settings: t.Settings, key_ptr: ?[*]const u8, key_len: usize) runtime.Error!?Value {
    const s = try lookup(settings);
    return s.store.get(try keyOf(key_ptr, key_len));
}

pub export fn siv_settings_get_type(settings: t.Settings, key: ?[*]const u8, key_len: usize, @"type": ?*t.SettingsType) t.Result {
    const v = read(settings, key, key_len) catch |err| return t.resultOf(err);
    const dest = runtime.out(t.SettingsType, @"type") catch |err| return t.resultOf(err);
    dest.* = if (v) |x| switch (x) {
        .boolean => .bool,
        .integer => .int,
        .float => .float,
        .string => .string,
    } else .none;
    return .ok;
}

pub export fn siv_settings_get_bool(settings: t.Settings, key: ?[*]const u8, key_len: usize, fallback: bool, value: ?*bool) t.Result {
    const v = read(settings, key, key_len) catch |err| return t.resultOf(err);
    const dest = runtime.out(bool, value) catch |err| return t.resultOf(err);
    dest.* = if (v) |x| if (x == .boolean) x.boolean else fallback else fallback;
    return .ok;
}

pub export fn siv_settings_get_int(settings: t.Settings, key: ?[*]const u8, key_len: usize, fallback: i64, value: ?*i64) t.Result {
    const v = read(settings, key, key_len) catch |err| return t.resultOf(err);
    const dest = runtime.out(i64, value) catch |err| return t.resultOf(err);
    dest.* = if (v) |x| if (x == .integer) x.integer else fallback else fallback;
    return .ok;
}

pub export fn siv_settings_get_float(settings: t.Settings, key: ?[*]const u8, key_len: usize, fallback: f64, value: ?*f64) t.Result {
    const v = read(settings, key, key_len) catch |err| return t.resultOf(err);
    const dest = runtime.out(f64, value) catch |err| return t.resultOf(err);
    dest.* = if (v) |x| switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => fallback,
    } else fallback;
    return .ok;
}

pub export fn siv_settings_get_string(settings: t.Settings, key: ?[*]const u8, key_len: usize, fallback: ?[*]const u8, fallback_len: usize, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    const v = read(settings, key, key_len) catch |err| return t.resultOf(err);
    const fb = runtime.string(fallback, fallback_len) catch |err| return t.resultOf(err);
    const buf = runtime.buffer(buffer, buffer_cap) catch |err| return t.resultOf(err);
    const dest = runtime.out(usize, len) catch |err| return t.resultOf(err);
    const s = if (v) |x| if (x == .string) x.string else fb else fb;
    const k = @min(s.len, buf.len);
    @memcpy(buf[0..k], s[0..k]);
    dest.* = s.len;
    return .ok;
}

fn write(settings: t.Settings, key_ptr: ?[*]const u8, key_len: usize, value: ?Value) t.Result {
    const s = lookup(settings) catch |err| return t.resultOf(err);
    const key = keyOf(key_ptr, key_len) catch |err| return t.resultOf(err);
    if (value) |v| {
        if (!app_mod.settings.validValue(v)) return .error_invalid_argument;
        s.store.set(key, v) catch return .error_out_of_memory;
    } else s.store.reset(key) catch return .error_out_of_memory;
    return .ok;
}

pub export fn siv_settings_set_bool(settings: t.Settings, key: ?[*]const u8, key_len: usize, value: bool) t.Result {
    return write(settings, key, key_len, .{ .boolean = value });
}

pub export fn siv_settings_set_int(settings: t.Settings, key: ?[*]const u8, key_len: usize, value: i64) t.Result {
    return write(settings, key, key_len, .{ .integer = value });
}

pub export fn siv_settings_set_float(settings: t.Settings, key: ?[*]const u8, key_len: usize, value: f64) t.Result {
    return write(settings, key, key_len, .{ .float = value });
}

pub export fn siv_settings_set_string(settings: t.Settings, key: ?[*]const u8, key_len: usize, value: ?[*]const u8, value_len: usize) t.Result {
    const v = runtime.string(value, value_len) catch |err| return t.resultOf(err);
    return write(settings, key, key_len, .{ .string = v });
}

pub export fn siv_settings_reset(settings: t.Settings, key: ?[*]const u8, key_len: usize) t.Result {
    return write(settings, key, key_len, null);
}

// Windows ---------------------------------------------------------------------

/// A window's size and states kept in a store (siv_window_desc.settings).
pub const Binding = struct {
    settings: t.Settings,
    /// Owned; keys are "<prefix>.width" and so on.
    prefix: []u8,

    const longest = ".fullscreen".len;

    /// From a window's descriptor; null without a store.
    pub fn fromDesc(self: *App, desc: *const t.WindowDesc) Error!?Binding {
        if (desc.settings == .null) return null;
        const s = try lookup(desc.settings);
        if (s.owner != self) return error.InvalidArgument;
        const key = try runtime.string(desc.settings_key, desc.settings_key_len);
        const prefix = if (key.len == 0) "window" else key;
        if (!validKey(prefix) or prefix.len + longest > app_mod.settings.max_key) return error.InvalidArgument;
        return .{ .settings = desc.settings, .prefix = try self.gpa().dupe(u8, prefix) };
    }

    pub fn deinit(b: *Binding, gpa: std.mem.Allocator) void {
        gpa.free(b.prefix);
    }

    fn keyName(b: *const Binding, buf: []u8, name: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}.{s}", .{ b.prefix, name }) catch unreachable;
    }

    /// What the store holds over the descriptor's size and states, within
    /// the size limits.
    pub fn restore(b: *const Binding, size: *[2]u32, maximized: *bool, fullscreen: *bool, min: [2]u32, max: [2]u32) void {
        const s = lookup(b.settings) catch return;
        var buf: [app_mod.settings.max_key]u8 = undefined;
        for (size, [_][]const u8{ "width", "height" }, min, max) |*dim, name, lo, hi| {
            const v = s.store.get(b.keyName(&buf, name)) orelse continue;
            if (v != .integer or v.integer < 1 or v.integer > 1 << 15) continue;
            var x: u32 = @intCast(v.integer);
            if (lo != 0) x = @max(x, lo);
            if (hi != 0) x = @min(x, hi);
            dim.* = x;
        }
        for ([_]*bool{ maximized, fullscreen }, [_][]const u8{ "maximized", "fullscreen" }) |state, name| {
            const v = s.store.get(b.keyName(&buf, name)) orelse continue;
            if (v == .boolean) state.* = v.boolean;
        }
    }

    /// Saves a configure: the states, and the size unless the compositor
    /// chose it (maximized, fullscreen, tiled).
    pub fn save(b: *const Binding, state: platform.WindowState) void {
        const s = lookup(b.settings) catch return;
        var buf: [app_mod.settings.max_key]u8 = undefined;
        const st = state.states;
        s.store.set(b.keyName(&buf, "maximized"), .{ .boolean = st.maximized }) catch {};
        s.store.set(b.keyName(&buf, "fullscreen"), .{ .boolean = st.fullscreen }) catch {};
        if (st.maximized or st.fullscreen or st.tiled_left or st.tiled_right or st.tiled_top or st.tiled_bottom) return;
        if (state.width == 0 or state.height == 0) return;
        s.store.set(b.keyName(&buf, "width"), .{ .integer = state.width }) catch {};
        s.store.set(b.keyName(&buf, "height"), .{ .integer = state.height }) catch {};
    }
};
