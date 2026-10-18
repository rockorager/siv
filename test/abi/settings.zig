//! Settings and state through the exports (D36): typed values with the
//! application's defaults, the file they reach and come back from, change
//! callbacks for this store's changes and the file's, and windows that
//! keep their size and states. Files go under a directory of the test's
//! own in /tmp, never the user's home.

const std = @import("std");
const linux = std.os.linux;
const abi = @import("abi");
const harness = @import("harness.zig");
const Loop = @import("loop").Loop;

const testing = std.testing;
const t = abi.types;
const c = t.c;
const ok = harness.ok;
const Harness = harness.Harness;

const Dir = struct {
    buf: [64]u8 = undefined,
    path: [:0]const u8 = "",

    var counter: std.atomic.Value(u32) = .init(0);

    fn init(d: *Dir) void {
        d.path = std.fmt.bufPrintSentinel(&d.buf, "/tmp/siv-abi-settings-{d}-{d}", .{ linux.getpid(), counter.fetchAdd(1, .monotonic) }, 0) catch unreachable;
    }

    fn file(d: *const Dir, buf: []u8, name: []const u8) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ d.path, name }, 0) catch unreachable;
    }

    fn remove(d: *const Dir, names: []const []const u8) void {
        var buf: [128]u8 = undefined;
        for (names) |n| _ = linux.unlink(d.file(&buf, n));
        _ = linux.rmdir(d.path);
    }
};

fn readFile(path: [:0]const u8, buf: []u8) ![]u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.NotFound;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    return buf[0..linux.read(fd, buf.ptr, buf.len)];
}

/// Replaces the file as an editor saving through a temporary file does.
fn editFile(path: [:0]const u8, bytes: []const u8) !void {
    var buf: [160]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&buf, "{s}~", .{path}, 0);
    const rc = linux.openat(linux.AT.FDCWD, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.Unwritable;
    const fd: i32 = @intCast(rc);
    _ = linux.write(fd, bytes.ptr, bytes.len);
    _ = linux.close(fd);
    if (linux.errno(linux.rename(tmp, path)) != .SUCCESS) return error.Unwritable;
}

fn newApp() !t.App {
    var app: t.App = .null;
    try ok(c.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true, .no_system_icons = true }, .app_id = "org.example.Notes", .app_id_len = 17 }, &app));
    return app;
}

const Changes = struct {
    keys: [16][32]u8 = undefined,
    lens: [16]usize = @splat(0),
    origins: [16]t.SettingsOrigin = undefined,
    n: usize = 0,
    released: bool = false,

    fn on(ud: ?*anyopaque, _: t.Settings, ch: *const t.SettingsChange) callconv(.c) void {
        const self: *Changes = @ptrCast(@alignCast(ud.?));
        @memcpy(self.keys[self.n][0..ch.key_len], ch.key.?[0..ch.key_len]);
        self.lens[self.n] = ch.key_len;
        self.origins[self.n] = ch.origin;
        self.n += 1;
    }

    fn release(ud: ?*anyopaque) callconv(.c) void {
        const self: *Changes = @ptrCast(@alignCast(ud.?));
        self.released = true;
    }

    fn has(self: *const Changes, key: []const u8, origin: t.SettingsOrigin) bool {
        for (0..self.n) |i| if (std.mem.eql(u8, self.keys[i][0..self.lens[i]], key) and self.origins[i] == origin) return true;
        return false;
    }
};

/// Dispatches the applications until `changes` heard `n` changes.
fn dispatchUntil(apps: []const t.App, changes: *const Changes, n: usize) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (changes.n < n) {
        if (Loop.now() > deadline) return error.Timeout;
        for (apps) |app| try ok(c.siv_app_dispatch(app, 2));
    }
}

test "settings: typed values over defaults, written to a file and read back in the next run" {
    var dir: Dir = .{};
    dir.init();
    defer dir.remove(&.{"notes.toml"});
    var path_buf: [128]u8 = undefined;
    const path = dir.file(&path_buf, "notes.toml");
    var changes: Changes = .{};
    {
        const app = try newApp();
        defer c.siv_app_destroy(app);
        var st: t.Settings = .null;
        try ok(c.siv_settings_open(app, &.{ .name = "notes", .name_len = 5, .directory = dir.path.ptr, .directory_len = dir.path.len, .on_change = Changes.on, .destroy = Changes.release, .user_data = &changes }, &st));
        // The same file twice in one application is refused.
        var again: t.Settings = .null;
        try testing.expectEqual(t.Result.error_busy, c.siv_settings_open(app, &.{ .name = "notes", .name_len = 5, .directory = dir.path.ptr, .directory_len = dir.path.len }, &again));

        // Unset keys give the application's default.
        var i: i64 = 0;
        try ok(c.siv_settings_get_int(st, "font.size", 9, 11, &i));
        try testing.expectEqual(@as(i64, 11), i);
        var ty: t.SettingsType = .bool;
        try ok(c.siv_settings_get_type(st, "font.size", 9, &ty));
        try testing.expectEqual(t.SettingsType.none, ty);

        try ok(c.siv_settings_set_int(st, "font.size", 9, 14));
        try ok(c.siv_settings_set_bool(st, "spell-check", 11, false));
        try ok(c.siv_settings_set_float(st, "zoom", 4, 1.25));
        try ok(c.siv_settings_set_string(st, "last-folder", 11, "/home/u/Notes \"2026\"", 20));
        try ok(c.siv_settings_set_int(st, "gone", 4, 1));
        try ok(c.siv_settings_reset(st, "gone", 4));

        // Reads see the values at once, typed: another type is the default.
        try ok(c.siv_settings_get_int(st, "font.size", 9, 11, &i));
        try testing.expectEqual(@as(i64, 14), i);
        var b = true;
        try ok(c.siv_settings_get_bool(st, "spell-check", 11, true, &b));
        try testing.expect(!b);
        try ok(c.siv_settings_get_bool(st, "font.size", 9, true, &b));
        try testing.expect(b);
        var f: f64 = 0;
        try ok(c.siv_settings_get_float(st, "zoom", 4, 1, &f));
        try testing.expectEqual(@as(f64, 1.25), f);
        // An integer reads as a float.
        try ok(c.siv_settings_get_float(st, "font.size", 9, 1, &f));
        try testing.expectEqual(@as(f64, 14), f);
        var text: [64]u8 = undefined;
        var len: usize = 0;
        try ok(c.siv_settings_get_string(st, "last-folder", 11, "~", 1, &text, text.len, &len));
        try testing.expectEqualStrings("/home/u/Notes \"2026\"", text[0..len]);
        try ok(c.siv_settings_get_string(st, "zoom", 4, "~", 1, &text, text.len, &len));
        try testing.expectEqualStrings("~", text[0..len]);
        // A short buffer gets what fits and the full length.
        try ok(c.siv_settings_get_string(st, "last-folder", 11, "", 0, &text, 4, &len));
        try testing.expectEqual(@as(usize, 20), len);
        try ok(c.siv_settings_get_type(st, "gone", 4, &ty));
        try testing.expectEqual(t.SettingsType.none, ty);

        // What the store cannot keep.
        try testing.expectEqual(t.Result.error_invalid_argument, c.siv_settings_set_int(st, "a b", 3, 1));
        try testing.expectEqual(t.Result.error_invalid_argument, c.siv_settings_set_int(st, "a.", 2, 1));
        try testing.expectEqual(t.Result.error_invalid_argument, c.siv_settings_set_float(st, "x", 1, std.math.inf(f64)));
        try testing.expectEqual(t.Result.error_invalid_argument, c.siv_settings_set_string(st, "x", 1, "\xff", 1));
        try testing.expectEqual(t.Result.error_invalid_argument, c.siv_settings_get_int(st, "", 0, 0, &i));

        // The callback hears each changed key once, at the next dispatch;
        // "gone" was set and reset in one burst, so it changed too.
        try testing.expectEqual(@as(usize, 0), changes.n);
        try ok(c.siv_app_dispatch(app, 0));
        try testing.expectEqual(@as(usize, 5), changes.n);
        try testing.expect(changes.has("font.size", .application));
        try testing.expect(changes.has("gone", .application));
        // Setting the value a key has is no change.
        try ok(c.siv_settings_set_int(st, "font.size", 9, 14));
        try ok(c.siv_app_dispatch(app, 0));
        try testing.expectEqual(@as(usize, 5), changes.n);
        // Destroying the application writes what is unsaved, and drops
        // the store with its user data.
    }
    try testing.expect(changes.released);
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        \\# Kept by the application through siv. Edits apply while it runs;
        \\# comments are not kept.
        \\last-folder = "/home/u/Notes \"2026\""
        \\spell-check = false
        \\zoom = 1.25
        \\
        \\[font]
        \\size = 14
        \\
    , try readFile(path, &buf));

    // The next run reads it.
    const app = try newApp();
    defer c.siv_app_destroy(app);
    var st: t.Settings = .null;
    try ok(c.siv_settings_open(app, &.{ .name = "notes", .name_len = 5, .directory = dir.path.ptr, .directory_len = dir.path.len }, &st));
    var i: i64 = 0;
    try ok(c.siv_settings_get_int(st, "font.size", 9, 11, &i));
    try testing.expectEqual(@as(i64, 14), i);
    c.siv_settings_destroy(st);
    // A stale handle fails.
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_settings_get_int(st, "font.size", 9, 11, &i));
}

test "settings: an edit of the file and another instance's writes reach a running application" {
    var dir: Dir = .{};
    dir.init();
    defer dir.remove(&.{"state.toml"});
    var path_buf: [128]u8 = undefined;
    const path = dir.file(&path_buf, "state.toml");
    const a = try newApp();
    defer c.siv_app_destroy(a);
    const b = try newApp();
    defer c.siv_app_destroy(b);
    var heard_a: Changes = .{};
    var heard_b: Changes = .{};
    var sa: t.Settings = .null;
    var sb: t.Settings = .null;
    // Two instances: two applications on one file.
    try ok(c.siv_settings_open(a, &.{ .kind = .state, .directory = dir.path.ptr, .directory_len = dir.path.len, .on_change = Changes.on, .user_data = &heard_a }, &sa));
    try ok(c.siv_settings_open(b, &.{ .kind = .state, .directory = dir.path.ptr, .directory_len = dir.path.len, .on_change = Changes.on, .user_data = &heard_b }, &sb));

    // Each sets its own key; neither write loses the other's.
    try ok(c.siv_settings_set_string(sa, "view.mode", 9, "grid", 4));
    try ok(c.siv_settings_set_int(sb, "sidebar.width", 13, 240));
    try dispatchUntil(&.{ a, b }, &heard_b, 2);
    try testing.expect(heard_b.has("view.mode", .outside));
    try dispatchUntil(&.{ a, b }, &heard_a, 2);
    try testing.expect(heard_a.has("sidebar.width", .outside));
    var i: i64 = 0;
    try ok(c.siv_settings_get_int(sa, "sidebar.width", 13, 0, &i));
    try testing.expectEqual(@as(i64, 240), i);
    var text: [16]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_settings_get_string(sb, "view.mode", 9, "list", 4, &text, text.len, &len));
    try testing.expectEqualStrings("grid", text[0..len]);

    // Someone edits the file: a value changes, one goes, one is new.
    heard_a.n = 0;
    try editFile(path,
        \\# by hand
        \\sidebar.width = 300
        \\[window]
        \\maximized = true
        \\
    );
    try dispatchUntil(&.{a}, &heard_a, 3);
    for (0..heard_a.n) |k| try testing.expectEqual(t.SettingsOrigin.outside, heard_a.origins[k]);
    try testing.expect(heard_a.has("view.mode", .outside));
    try ok(c.siv_settings_get_int(sa, "sidebar.width", 13, 0, &i));
    try testing.expectEqual(@as(i64, 300), i);
    try ok(c.siv_settings_get_string(sa, "view.mode", 9, "list", 4, &text, text.len, &len));
    try testing.expectEqualStrings("list", text[0..len]);
    var max = false;
    try ok(c.siv_settings_get_bool(sa, "window.maximized", 16, false, &max));
    try testing.expect(max);
}

test "settings: on the headless backend without a directory, values stay in memory" {
    const app = try newApp();
    defer c.siv_app_destroy(app);
    var st: t.Settings = .null;
    try ok(c.siv_settings_open(app, null, &st));
    try ok(c.siv_settings_set_int(st, "x", 1, 3));
    var i: i64 = 0;
    try ok(c.siv_settings_get_int(st, "x", 1, 0, &i));
    try testing.expectEqual(@as(i64, 3), i);
    // A store needs an application id to find its directory by.
    var anon: t.App = .null;
    try ok(c.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true } }, &anon));
    defer c.siv_app_destroy(anon);
    var none: t.Settings = .null;
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_settings_open(anon, &.{ .kind = .state, .directory = "relative", .directory_len = 8 }, &none));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_settings_open(app, &.{ .name = "../x", .name_len = 4 }, &none));
}

const Sizes = struct {
    width: u32 = 0,
    height: u32 = 0,
    states: t.WindowStates = .{},
    fn onEvent(ud: ?*anyopaque, _: t.Window, e: *const t.WindowEvent) callconv(.c) bool {
        const self: *Sizes = @ptrCast(@alignCast(ud.?));
        self.width = e.width;
        self.height = e.height;
        self.states = e.states;
        return false;
    }
};

test "settings: a window keeps its size and maximized state in a store" {
    var dir: Dir = .{};
    dir.init();
    defer dir.remove(&.{"state.toml"});
    var path_buf: [128]u8 = undefined;
    const path = dir.file(&path_buf, "state.toml");
    {
        var h: Harness = .{};
        try h.start(100, 100, null, null);
        defer h.stop();
        var st: t.Settings = .null;
        try ok(c.siv_settings_open(h.app, &.{ .kind = .state, .directory = dir.path.ptr, .directory_len = dir.path.len }, &st));
        var win: t.Window = .null;
        try ok(c.siv_window_create(h.app, &.{ .width = 300, .height = 200, .settings = st, .settings_key = "window.main", .settings_key_len = 11 }, &win));
        try h.settle();
        // The user resizes it, then maximizes it: the size kept is the
        // one before.
        try ok(c.siv_test_resize(win, 420, 310));
        try h.settle();
        try ok(c.siv_test_set_states(win, .{ .maximized = true, .activated = true }));
        try h.settle();
        var i: i64 = 0;
        try ok(c.siv_settings_get_int(st, "window.main.width", 17, 0, &i));
        try testing.expectEqual(@as(i64, 420), i);
        var max = false;
        try ok(c.siv_settings_get_bool(st, "window.main.maximized", 21, false, &max));
        try testing.expect(max);
        // A bad key is refused.
        try testing.expectEqual(t.Result.error_invalid_argument, c.siv_window_create(h.app, &.{ .settings = st, .settings_key = "a..b", .settings_key_len = 4 }, &win));
    }
    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, try readFile(path, &buf),
        \\[window.main]
        \\fullscreen = false
        \\height = 310
        \\maximized = true
        \\width = 420
        \\
    ));

    // The next run opens it at that size, maximized.
    var sizes: Sizes = .{};
    var h: Harness = .{};
    try h.start(100, 100, null, null);
    defer h.stop();
    var st: t.Settings = .null;
    try ok(c.siv_settings_open(h.app, &.{ .kind = .state, .directory = dir.path.ptr, .directory_len = dir.path.len }, &st));
    var win: t.Window = .null;
    try ok(c.siv_window_create(h.app, &.{ .width = 300, .height = 200, .settings = st, .settings_key = "window.main", .settings_key_len = 11, .on_event = Sizes.onEvent, .user_data = &sizes }, &win));
    try h.settle();
    var states: t.WindowStates = .{};
    try ok(c.siv_window_get_states(win, &states));
    try testing.expect(states.maximized);
    try testing.expect(sizes.states.maximized);
    c.siv_window_destroy(win);
    // Not maximized, it opens at the size it had.
    try ok(c.siv_settings_set_bool(st, "window.main.maximized", 21, false));
    try ok(c.siv_window_create(h.app, &.{ .width = 300, .height = 200, .settings = st, .settings_key = "window.main", .settings_key_len = 11 }, &win));
    try h.settle();
    var size: t.Size = .{ .width = 0, .height = 0 };
    try ok(c.siv_window_get_size(win, &size));
    try testing.expectEqual(@as(f32, 420), size.width);
    try testing.expectEqual(@as(f32, 310), size.height);
    try ok(c.siv_window_get_states(win, &states));
    try testing.expect(!states.maximized);
}
