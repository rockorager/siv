//! examples/shell.c on the headless backend (D24, D31), run unchanged as
//! the guide's samples are: it is compiled into this binary a second time
//! with main and five functions renamed (see src/abi/build_steps.zig).
//! siv_app_create picks the headless backend with the test fonts and a
//! compositor that blurs; siv_app_run drives the shell as a user would;
//! time is fixed, so the clock shows 09:41; the user is "ada"; and dlopen and dlsym load a
//! fake libpam that accepts the password "hunter2", so the lock screen's
//! PAM conversation runs on its worker thread as it would for real.

const std = @import("std");
const abi = @import("abi");
const platform = @import("platform");
const compositor = @import("compositor");
const text = @import("text");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const A = abi.application;
const ok = harness.ok;

extern fn shell_example_main(argc: c_int, argv: [*]const ?[*:0]const u8) c_int;

/// What the scenario reports back to the test.
var outcome: anyerror!void = {};
var driver: *const fn (t.App) anyerror!void = undefined;

export fn shell_test_app_create(desc: ?*const t.AppDesc, app: ?*t.App) t.Result {
    var d = desc.?.*;
    d.backend = .headless;
    d.flags = .{ .no_system_fonts = true, .no_system_icons = true, .reduced_motion = true };
    const r = A.siv_app_create(&d, app);
    if (r != .ok) return r;
    const a = app.?.*;
    const tf = text.font.test_fonts;
    _ = A.siv_app_add_font(a, "Droid", 5, tf.latin.ptr, tf.latin.len);
    _ = A.siv_app_set_default_font(a, "Droid", 5);
    _ = abi.icon.siv_app_add_icon_path(a, "test/icons/themes", 17);
    _ = abi.icon.siv_app_set_icon_theme(a, "SivTest", 7);
    // A compositor that blurs, so the bar is translucent and frosted.
    _ = c.siv_test_set_blur(a, true);
    return .ok;
}

export fn shell_test_app_run(app: t.App) t.Result {
    driver(app) catch |err| {
        std.debug.print("the shell scenario failed: {t}\n", .{err});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        outcome = err;
    };
    return .ok;
}

/// 2026-01-01 09:41:00 UTC; the test runs without TZ.
export fn shell_test_time(out: ?*c_long) c_long {
    const now: c_long = 1767260460;
    if (out) |o| o.* = now;
    return now;
}

/// struct passwd, as glibc lays it out.
const Passwd = extern struct {
    name: [*:0]const u8,
    passwd: [*:0]const u8,
    uid: u32,
    gid: u32,
    gecos: [*:0]const u8,
    dir: [*:0]const u8,
    shell: [*:0]const u8,
};
var user: Passwd = .{ .name = "ada", .passwd = "x", .uid = 1000, .gid = 1000, .gecos = "Ada", .dir = "/home/ada", .shell = "/bin/sh" };

/// The user is ada, wherever the test runs.
export fn shell_test_getpwuid(_: u32) *Passwd {
    return &user;
}

// A fake libpam: pam_start keeps the conversation, pam_authenticate asks
// it for the password and accepts "hunter2".

const PamMessage = extern struct { style: c_int, msg: ?[*:0]const u8 };
const PamResponse = extern struct { resp: ?[*:0]u8, retcode: c_int };
const PamConv = extern struct {
    conv: *const fn (c_int, *const ?*const PamMessage, *?[*]PamResponse, ?*anyopaque) callconv(.c) c_int,
    data: ?*anyopaque,
};

var fake_lib: u8 = 0;
var conv: ?PamConv = null;
var attempts = std.atomic.Value(u32).init(0);

export fn shell_test_dlopen(name: ?[*:0]const u8, _: c_int) ?*anyopaque {
    if (!std.mem.eql(u8, std.mem.span(name.?), "libpam.so.0")) return null;
    return &fake_lib;
}

export fn shell_test_dlclose(_: ?*anyopaque) c_int {
    return 0;
}

export fn shell_test_dlsym(_: ?*anyopaque, name: [*:0]const u8) ?*anyopaque {
    const n = std.mem.span(name);
    if (std.mem.eql(u8, n, "pam_start")) return @constCast(@ptrCast(&pamStart));
    if (std.mem.eql(u8, n, "pam_authenticate")) return @constCast(@ptrCast(&pamAuthenticate));
    if (std.mem.eql(u8, n, "pam_end")) return @constCast(@ptrCast(&pamEnd));
    return null;
}

fn pamStart(_: [*:0]const u8, _: [*:0]const u8, cv: *const PamConv, handle: *?*anyopaque) callconv(.c) c_int {
    conv = cv.*;
    handle.* = &fake_lib;
    return 0;
}

fn pamAuthenticate(_: ?*anyopaque, _: c_int) callconv(.c) c_int {
    _ = attempts.fetchAdd(1, .seq_cst);
    const cv = conv.?;
    const msg: PamMessage = .{ .style = 1, .msg = "Password: " };
    const msgs: ?*const PamMessage = &msg;
    var resp: ?[*]PamResponse = null;
    if (cv.conv(1, &msgs, &resp, cv.data) != 0) return 19;
    const r = resp.?;
    const answer = std.mem.span(r[0].resp.?);
    const good = std.mem.eql(u8, answer, "hunter2");
    std.c.free(r[0].resp);
    std.c.free(r);
    return if (good) 0 else 7; // PAM_AUTH_ERR
}

fn pamEnd(_: ?*anyopaque, _: c_int) callconv(.c) c_int {
    return 0;
}

// The scenario ------------------------------------------------------------------

fn settle(app: t.App) !void {
    var settled = false;
    try ok(c.siv_test_settle(app, 5000, &settled));
    try testing.expect(settled);
}

/// The application's windows of a role.
fn windowsOf(app: t.App, role: std.meta.Tag(platform.Role), out: []t.Window) ![]t.Window {
    const self = try A.App.get(@backingInt(app));
    var n: usize = 0;
    for (self.windows.items) |slot| if (slot) |w| {
        if (w.dead or w.parent != null or w.win.role != role) continue;
        out[n] = @fromBackingInt(w.handle);
        n += 1;
    };
    return out[0..n];
}

fn find(window: t.Window, role: t.Role, name: []const u8) !t.TestNode {
    var found = false;
    var node: t.TestNode = undefined;
    try ok(c.siv_test_find(window, &.{ .role = role, .name = name.ptr, .name_len = name.len }, &found, &node));
    if (!found) {
        var buf: [8192]u8 = undefined;
        var len: usize = 0;
        _ = c.siv_test_dump(window, &buf, buf.len, &len);
        std.debug.print("no {t} \"{s}\" in:\n{s}\n", .{ role, name, buf[0..@min(len, buf.len)] });
        return error.NotFound;
    }
    return node;
}

fn click(app: t.App, window: t.Window, node: t.TestNode) !void {
    try ok(c.siv_test_click(window, node.bounds.x + node.bounds.width / 2, node.bounds.y + node.bounds.height / 2, .primary));
    try settle(app);
}

fn onHeadless(app: t.App, comptime func: anytype, args: anytype) !@typeInfo(@TypeOf(func)).@"fn".return_type.? {
    const self = try A.App.get(@backingInt(app));
    const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    const Ctx = struct {
        args: @TypeOf(args),
        out: R = undefined,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const x: *@This() = @ptrCast(@alignCast(ctx));
            x.out = @call(.auto, func, .{comp.platform.headless} ++ x.args);
        }
    };
    var ctx: Ctx = .{ .args = args };
    try self.app.comp.call(&ctx, Ctx.run);
    return ctx.out;
}

fn simWorkspaceActive(hl: *platform.Headless, id: u32) bool {
    for (hl.sim_workspaces.items) |w| if (w.id == id) return w.states.active;
    return false;
}

fn simToplevel(hl: *platform.Headless, id: u32) platform.ToplevelStates {
    for (hl.sim_toplevels.items) |x| if (x.id == id) return x.states;
    return .{};
}

fn locked(app: t.App) !bool {
    var on = false;
    try ok(c.siv_test_is_locked(app, &on));
    return on;
}

/// Types into the lock window's password field and presses Enter; the
/// check runs on a worker thread, which settling waits for.
fn typePassword(app: t.App, window: t.Window, password: []const u8) !void {
    try ok(c.siv_test_type(window, password.ptr, password.len));
    try ok(c.siv_test_key(window, .@"return", .{}, null, 0));
    try settle(app);
}

fn drive(app: t.App) !void {
    // The desktop: two workspaces and two other applications' windows.
    var ws: [2]u32 = undefined;
    try ok(c.siv_test_add_workspace(app, "1", 1, .null, &ws[0]));
    try ok(c.siv_test_add_workspace(app, "2", 1, .null, &ws[1]));
    var foot: u32 = 0;
    var notes: u32 = 0;
    try ok(c.siv_test_add_toplevel(app, "foot", 4, "foot", 4, .null, &foot));
    try ok(c.siv_test_add_toplevel(app, "notes.txt", 9, "org.siv.Editor", 14, .null, &notes));
    try settle(app);

    // A bar on the output, with them, the clock, and the lock button.
    var buf: [8]t.Window = undefined;
    const bars = try windowsOf(app, .layer, &buf);
    try testing.expectEqual(@as(usize, 1), bars.len);
    const bar = bars[0];
    var size: t.Size = undefined;
    try ok(c.siv_window_get_size(bar, &size));
    try testing.expectEqual(t.Size{ .width = 1920, .height = 34 }, size);
    _ = try find(bar, .toolbar, "Panel");
    _ = try find(bar, .status, "Clock");
    const two = try find(bar, .button, "2");
    const foot_button = try find(bar, .button, "foot");
    _ = try find(bar, .button, "notes.txt");
    _ = try find(bar, .button, "Lock");
    // Frosted: the compositor blurs behind the whole bar.
    var rects: usize = 0;
    try ok(c.siv_test_get_blur_region_count(bar, &rects));
    try testing.expectEqual(@as(usize, 1), rects);
    var h: harness.Harness = .{ .app = app, .golden = "test/golden/shell" };
    try h.expectGoldenOf(bar, "bar", 1920, 34);

    // Clicking a workspace switches to it; clicking a window focuses it,
    // and clicking it again minimizes it.
    try click(app, bar, two);
    try testing.expect(try onHeadless(app, simWorkspaceActive, .{ws[1]}));
    try testing.expect(!try onHeadless(app, simWorkspaceActive, .{ws[0]}));
    try click(app, bar, foot_button);
    try testing.expect((try onHeadless(app, simToplevel, .{foot})).activated);
    try click(app, bar, try find(bar, .button, "foot"));
    try testing.expect((try onHeadless(app, simToplevel, .{foot})).minimized);
    // A window that closes leaves the task list.
    try ok(c.siv_test_remove_toplevel(app, notes));
    try settle(app);
    var found = false;
    var node: t.TestNode = undefined;
    try ok(c.siv_test_find(bar, &.{ .role = .button, .name = "notes.txt", .name_len = 9 }, &found, &node));
    try testing.expect(!found);

    // The lock button locks: a lock window per output with a password
    // field that has the keyboard.
    try click(app, bar, try find(bar, .button, "Lock"));
    try testing.expect(try locked(app));
    var lbuf: [8]t.Window = undefined;
    const screens = try windowsOf(app, .lock, &lbuf);
    try testing.expectEqual(@as(usize, 1), screens.len);
    const screen = screens[0];
    _ = try find(screen, .dialog, "Locked");
    var field: t.TestNode = undefined;
    try ok(c.siv_test_find(screen, &.{ .role = .text_input, .flags = .{ .focused = true } }, &found, &field));
    try testing.expect(found);
    try h.expectGoldenOf(screen, "lock", 1920, 1080);

    // A wrong password: PAM says no, the field clears, and the screen
    // says so.
    try typePassword(app, screen, "nope");
    try testing.expectEqual(@as(u32, 1), attempts.load(.seq_cst));
    _ = try find(screen, .status, "Wrong password");
    try testing.expect(try locked(app));
    // The right one unlocks: the lock windows go.
    try typePassword(app, screen, "hunter2");
    try testing.expectEqual(@as(u32, 2), attempts.load(.seq_cst));
    try testing.expect(!try locked(app));
    try testing.expectEqual(@as(usize, 0), (try windowsOf(app, .lock, &lbuf)).len);

    // Five idle minutes lock too.
    try ok(c.siv_test_set_idle(app, true));
    try settle(app);
    try testing.expect(try locked(app));
    try ok(c.siv_test_set_idle(app, false));
    const again = (try windowsOf(app, .lock, &lbuf))[0];
    try typePassword(app, again, "hunter2");
    try testing.expect(!try locked(app));

    // A second monitor gets a bar of its own, which goes with it.
    try ok(c.siv_test_add_output(app, "HEADLESS-2", 10, 1280, 720, 1));
    try settle(app);
    try testing.expectEqual(@as(usize, 2), (try windowsOf(app, .layer, &buf)).len);
    try ok(c.siv_test_remove_output(app, "HEADLESS-2", 10));
    try settle(app);
    try testing.expectEqual(@as(usize, 1), (try windowsOf(app, .layer, &buf)).len);
}

test "the shell example: a bar with workspaces, tasks, and a clock; a lock screen that checks the password with PAM" {
    driver = drive;
    outcome = {};
    const argv = [_:null]?[*:0]const u8{"shell"};
    try testing.expectEqual(@as(c_int, 0), shell_example_main(1, &argv));
    try outcome;
}
