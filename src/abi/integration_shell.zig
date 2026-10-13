//! examples/shell.c against sway (D24, D31), run unchanged: it is compiled
//! into this binary with main and the calls this file drives or fakes
//! renamed (src/abi/build_steps.zig). siv_app_create connects to the test's
//! sway; siv_app_run clicks the bar with a virtual pointer and types the
//! password with wtype; time and the user are fixed; and dlopen and dlsym
//! load a fake libpam that accepts "hunter2", so the PAM conversation runs
//! on the worker thread as it would for real.

const std = @import("std");
const testing = std.testing;
const abi = @import("abi");
const platform = @import("platform");
const compositor = @import("compositor");
const text = @import("text");
const Loop = @import("loop").Loop;

const t = abi.types;
const c = t.c;
const A = abi.application;
const Sway = platform.test_sway.Sway;
const VirtualPointer = platform.test_sway.VirtualPointer;

fn ok(r: t.Result) !void {
    if (r == .ok) return;
    std.debug.print("unexpected {s}\n", .{abi.siv_result_name(r)});
    return error.Unexpected;
}

extern fn shell_example_main(argc: c_int, argv: [*]const ?[*:0]const u8) c_int;

var sway: Sway = .{};
var outcome: anyerror!void = {};

export fn shell_sway_app_create(desc: ?*const t.AppDesc, app: ?*t.App) t.Result {
    var d = desc.?.*;
    d.display = sway.display.ptr;
    d.display_len = sway.display.len;
    d.flags = .{ .no_system_fonts = true, .reduced_motion = true };
    const r = A.siv_app_create(&d, app);
    if (r != .ok) return r;
    const tf = text.font.test_fonts;
    _ = A.siv_app_add_font(app.?.*, "Droid", 5, tf.latin.ptr, tf.latin.len);
    _ = A.siv_app_set_default_font(app.?.*, "Droid", 5);
    return .ok;
}

export fn shell_sway_app_run(app: t.App) t.Result {
    drive(app) catch |err| {
        std.debug.print("the shell scenario on sway failed: {t}\n", .{err});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        outcome = err;
    };
    return .ok;
}

export fn shell_sway_time(out: ?*c_long) c_long {
    const now: c_long = 1767260460;
    if (out) |o| o.* = now;
    return now;
}

export fn shell_sway_localtime_r(time: *const c_long, tm: *anyopaque) ?*anyopaque {
    return gmtime_r(time, tm);
}
extern "c" fn gmtime_r(time: *const c_long, tm: *anyopaque) ?*anyopaque;

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

export fn shell_sway_getpwuid(_: u32) *Passwd {
    return &user;
}

const PamMessage = extern struct { style: c_int, msg: ?[*:0]const u8 };
const PamResponse = extern struct { resp: ?[*:0]u8, retcode: c_int };
const PamConv = extern struct {
    conv: *const fn (c_int, *const ?*const PamMessage, *?[*]PamResponse, ?*anyopaque) callconv(.c) c_int,
    data: ?*anyopaque,
};
var fake_lib: u8 = 0;
var conv: ?PamConv = null;
var attempts = std.atomic.Value(u32).init(0);

export fn shell_sway_dlopen(name: ?[*:0]const u8, _: c_int) ?*anyopaque {
    return if (std.mem.eql(u8, std.mem.span(name.?), "libpam.so.0")) &fake_lib else null;
}

export fn shell_sway_dlclose(_: ?*anyopaque) c_int {
    return 0;
}

export fn shell_sway_dlsym(_: ?*anyopaque, name: [*:0]const u8) ?*anyopaque {
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
    const good = std.mem.eql(u8, std.mem.span(r[0].resp.?), "hunter2");
    std.c.free(r[0].resp);
    std.c.free(r);
    return if (good) 0 else 7;
}

fn pamEnd(_: ?*anyopaque, _: c_int) callconv(.c) c_int {
    return 0;
}

/// Dispatches until `cond` holds, for at most 10 s.
fn until(app: t.App, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) anyerror!bool) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (!try cond(ctx)) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(A.siv_app_dispatch(app, 10));
    }
}

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

fn presented(window: t.Window) bool {
    const w = A.App.window(@backingInt(window), A.window_tag) catch return false;
    return !w.dead and w.win.presented_seq > 0 and w.win.settled();
}

fn findIn(window: t.Window, role: t.Role, name: []const u8) !?t.TestNode {
    var found = false;
    var node: t.TestNode = undefined;
    try ok(c.siv_test_find(window, &.{ .role = role, .name = name.ptr, .name_len = name.len }, &found, &node));
    return if (found) node else null;
}

/// Clicks a bar button's center on the screen (the bar is at the
/// output's top left), once the pointer is over the bar: a new virtual
/// pointer's motion reaches siv only after it bound the seat's pointer.
fn clickAt(app: t.App, vp: *VirtualPointer, bar: t.Window, name: []const u8) !void {
    const w = try A.App.window(@backingInt(bar), A.window_tag);
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    // Laid out: the semantics tree has its place after the next frame.
    var node = (try findIn(bar, .button, name)).?;
    while (node.bounds.width == 0) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(A.siv_app_dispatch(app, 10));
        node = (try findIn(bar, .button, name)).?;
    }
    const x: u32 = @intFromFloat(node.bounds.x + node.bounds.width / 2);
    const y: u32 = @intFromFloat(node.bounds.y + node.bounds.height / 2);
    while (w.uiWin().input.pointer == null) {
        if (Loop.now() > deadline) return error.Timeout;
        vp.moveTo(x + 1, y);
        vp.moveTo(x, y);
        try vp.sync();
        try ok(A.siv_app_dispatch(app, 50));
    }
    vp.moveTo(x, y);
    vp.button(0x110, true);
    vp.button(0x110, false);
    try vp.sync();
}

/// Whether sway reports the named workspace active, read from siv's own
/// workspace objects on the compositor thread.
fn workspaceActive(app: t.App, name: []const u8) !bool {
    const self = try A.App.get(@backingInt(app));
    const C = struct {
        name: []const u8,
        out: bool = false,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const x: *@This() = @ptrCast(@alignCast(ctx));
            for (comp.platform.wayland.foreign.workspaces.items) |w| {
                if (std.mem.eql(u8, w.name.bytes.items, x.name)) x.out = w.states.active;
            }
        }
    };
    var cx: C = .{ .name = name };
    try self.app.comp.call(&cx, C.run);
    return cx.out;
}

fn typeKeys(app: t.App, argv: [*:null]const ?[*:0]const u8) !void {
    const pid = try sway.spawnClient(argv);
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, std.c.W.NOHANG) == 0) try ok(A.siv_app_dispatch(app, 10));
    try testing.expectEqual(0, status);
}

fn drive(app: t.App) !void {
    // The bar maps along the top of sway's output.
    var buf: [8]t.Window = undefined;
    try until(app, app, struct {
        fn f(a: t.App) !bool {
            var b: [8]t.Window = undefined;
            const bars = try windowsOf(a, .layer, &b);
            return bars.len == 1 and presented(bars[0]) and (try findIn(bars[0], .button, "1")) != null;
        }
    }.f);
    const bar = (try windowsOf(app, .layer, &buf))[0];
    var size: t.Size = undefined;
    try ok(c.siv_window_get_size(bar, &size));
    try testing.expectEqual(t.Size{ .width = 1280, .height = 34 }, size);

    // A real window: sway lists it, so the task list shows it.
    var window: t.Window = .null;
    try ok(c.siv_window_create(app, &.{ .title = "Editor", .title_len = 6 }, &window));
    try until(app, bar, struct {
        fn f(b: t.Window) !bool {
            return (try findIn(b, .button, "Editor")) != null;
        }
    }.f);

    // A second workspace appears in the bar; clicking "1" switches back.
    try sway.command("workspace 2");
    try until(app, bar, struct {
        fn f(b: t.Window) !bool {
            return (try findIn(b, .button, "2")) != null;
        }
    }.f);
    try testing.expect(try workspaceActive(app, "2"));
    var vp = try VirtualPointer.connect(&sway);
    defer vp.deinit();
    try vp.sync();
    try clickAt(app, &vp, bar, "1");
    try until(app, app, struct {
        fn f(a: t.App) !bool {
            return workspaceActive(a, "1");
        }
    }.f);

    // The lock button: sway locks, and the lock window shows on the output.
    try clickAt(app, &vp, bar, "Lock");
    try until(app, app, struct {
        fn f(a: t.App) !bool {
            var b: [8]t.Window = undefined;
            const screens = try windowsOf(a, .lock, &b);
            if (screens.len != 1 or !presented(screens[0])) return false;
            const self = try A.App.get(@backingInt(a));
            const l = self.shell.lock orelse return false;
            return l.locked;
        }
    }.f);
    const screen = (try windowsOf(app, .lock, &buf))[0];
    try ok(c.siv_window_get_size(screen, &size));
    try testing.expectEqual(t.Size{ .width = 1280, .height = 720 }, size);

    // The password through a virtual keyboard: sway gives the lock surface
    // the keys. An idle wtype provides the seat's keyboard first.
    const keyboard = try sway.spawnClient(&[_:null]?[*:0]const u8{ "wtype", "-s", "60000" });
    defer {
        _ = std.c.kill(keyboard, std.c.SIG.TERM);
        var status: c_int = 0;
        _ = std.c.waitpid(keyboard, &status, 0);
    }
    try until(app, screen, struct {
        fn f(s: t.Window) !bool {
            const w = try A.App.window(@backingInt(s), A.window_tag);
            return w.uiWin().input.keyboard;
        }
    }.f);
    try typeKeys(app, &[_:null]?[*:0]const u8{ "wtype", "nope", "-k", "Return" });
    try until(app, screen, struct {
        fn f(s: t.Window) !bool {
            return (try findIn(s, .status, "Wrong password")) != null;
        }
    }.f);
    try testing.expectEqual(@as(u32, 1), attempts.load(.seq_cst));
    try typeKeys(app, &[_:null]?[*:0]const u8{ "wtype", "hunter2", "-k", "Return" });
    try until(app, app, struct {
        fn f(a: t.App) !bool {
            const self = try A.App.get(@backingInt(a));
            var b: [8]t.Window = undefined;
            return self.shell.lock == null and (try windowsOf(a, .lock, &b)).len == 0;
        }
    }.f);
    try testing.expectEqual(@as(u32, 2), attempts.load(.seq_cst));
    c.siv_window_destroy(window);
}

test "the shell example on sway: the bar lists sway's workspaces and windows and switches workspaces; the lock screen locks and unlocks with PAM" {
    try sway.start();
    defer sway.stop();
    outcome = {};
    const argv = [_:null]?[*:0]const u8{"shell"};
    try testing.expectEqual(@as(c_int, 0), shell_example_main(1, &argv));
    try outcome;
}
