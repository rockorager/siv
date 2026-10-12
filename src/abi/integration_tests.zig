//! The public API against sway running headless (`zig build
//! test-integration`): a window created through the exports maps and
//! presents on a real compositor, real pointer and keyboard input reach C
//! callbacks, the compositor's configure arrives as a resize, and sway's
//! kill command arrives as a close request that ends siv_run.
//!
//! Imports: abi, platform, text, loop.

const std = @import("std");
const testing = std.testing;
const abi = @import("abi");
const text = @import("text");
const platform = @import("platform");
const Loop = @import("loop").Loop;

const t = abi.types;
const A = abi.application;
const T = abi.tree;
const Sway = platform.test_sway.Sway;
const VirtualPointer = platform.test_sway.VirtualPointer;

fn ok(r: t.Result) !void {
    if (r == .ok) return;
    std.debug.print("unexpected {s}\n", .{abi.siv_result_name(r)});
    return error.Unexpected;
}

const Log = struct {
    clicks: u32 = 0,
    changes: u32 = 0,
    text: [32]u8 = undefined,
    text_len: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    resizes: u32 = 0,
    closes: u32 = 0,

    fn onActivate(user_data: ?*anyopaque, _: t.Node, _: ?*const t.Event) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.clicks += 1;
        return true;
    }

    fn onChange(user_data: ?*anyopaque, _: t.Node, event: ?*const t.Event) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        const e = event.?;
        log.changes += 1;
        log.text_len = @min(e.text_len, log.text.len);
        @memcpy(log.text[0..log.text_len], e.text.?[0..log.text_len]);
        return true;
    }

    fn onWindow(user_data: ?*anyopaque, _: t.Window, event: ?*const t.WindowEvent) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        const e = event.?;
        switch (e.type) {
            .resized => {
                log.resizes += 1;
                log.width = e.width;
                log.height = e.height;
            },
            .close_requested => log.closes += 1,
            else => {},
        }
        return false;
    }
};

fn dispatchUntil(app: t.App, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (!cond(ctx)) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(A.siv_app_dispatch(app, 10));
    }
}

fn dispatchFor(app: t.App, ms: u64) void {
    const deadline = Loop.now() + ms * std.time.ns_per_ms;
    while (Loop.now() < deadline) _ = A.siv_app_dispatch(app, 10);
}

test "the public API on sway: present, pointer and keyboard input, resize, close" {
    var sway: Sway = .{};
    try sway.start();
    defer sway.stop();

    var app: t.App = .null;
    try ok(A.siv_app_create(&.{ .display = sway.display.ptr, .display_len = sway.display.len, .flags = .{ .no_system_fonts = true } }, &app));
    defer _ = A.siv_app_destroy(app);
    try ok(A.siv_app_add_font(app, "Droid", 5, text.font.test_fonts.latin.ptr, text.font.test_fonts.latin.len));
    try ok(A.siv_app_set_default_font(app, "Droid", 5));

    var log: Log = .{};
    var window: t.Window = .null;
    const title = "siv C API";
    try ok(A.siv_window_create(app, &.{ .title = title, .title_len = title.len, .on_event = Log.onWindow, .user_data = &log }, &window));

    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(window, &txn));
    const root = A.siv_window_root(window);
    _ = T.siv_set_visual(txn, root, &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
    const column = T.siv_flex(txn, root, &.{ .axis = .column });
    const button = T.siv_box(txn, column);
    _ = T.siv_set_layout(txn, button, &.{ .width = .{ .unit = .px, .value = 200 }, .height = .{ .unit = .px, .value = 100 } });
    _ = T.siv_set_visual(txn, button, &.{ .background = .{ .r = 0.15, .g = 0.39, .b = 0.92, .a = 1 } });
    _ = T.siv_set_semantics(txn, button, &.{ .role = .button, .flags = .{ .focusable = true } });
    _ = T.siv_on(txn, button, .activate, Log.onActivate, null, &log);
    const editor = T.siv_editor(txn, column, .{});
    _ = T.siv_set_layout(txn, editor, &.{ .width = .{ .unit = .px, .value = 200 }, .height = .{ .unit = .px, .value = 40 } });
    _ = T.siv_on(txn, editor, .change, Log.onChange, null, &log);
    try ok(T.siv_txn_commit(txn));

    // Sway tiles the only window over its 1280x720 output.
    const w = try A.App.window(@backingInt(window), A.window_tag);
    try dispatchUntil(app, w, struct {
        fn f(win: *A.Window) bool {
            return win.win.presented_seq > 0 and win.win.settled() and win.win.ui.width == 1280;
        }
    }.f);
    try testing.expect(log.resizes >= 1);
    try testing.expectEqual(1280, log.width);
    try testing.expectEqual(720, log.height);
    var size: t.Size = undefined;
    try ok(A.siv_window_get_size(window, &size));
    try testing.expectEqual(t.Size{ .width = 1280, .height = 720 }, size);

    // A real click on the button.
    var vp = try VirtualPointer.connect(&sway);
    defer vp.deinit();
    // The virtual device gives the seat its pointer capability; give the
    // application time to bind its wl_pointer before clicking.
    try vp.sync();
    dispatchFor(app, 300);
    vp.moveTo(100, 50);
    vp.button(0x110, true);
    vp.button(0x110, false);
    try vp.sync();
    try dispatchUntil(app, &log, struct {
        fn f(l: *Log) bool {
            return l.clicks == 1;
        }
    }.f);

    // Focus the editor and type through a virtual keyboard.
    vp.moveTo(100, 120);
    vp.button(0x110, true);
    vp.button(0x110, false);
    try vp.sync();
    dispatchFor(app, 300);
    const wtype = try sway.spawnClient(&[_:null]?[*:0]const u8{ "wtype", "-s", "300", "hi" });
    var status: c_int = 0;
    while (std.c.waitpid(wtype, &status, std.c.W.NOHANG) == 0) try ok(A.siv_app_dispatch(app, 10));
    try testing.expectEqual(0, status);
    try dispatchUntil(app, &log, struct {
        fn f(l: *Log) bool {
            return l.changes >= 2;
        }
    }.f);
    try testing.expectEqualStrings("hi", log.text[0..log.text_len]);
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    try ok(T.siv_node_get_text(editor, &buf, buf.len, &len));
    try testing.expectEqualStrings("hi", buf[0..len]);

    // sway's kill sends a close request; unhandled, it destroys the
    // window, and siv_run returns with no window left.
    try sway.command("kill");
    try ok(A.siv_run(app));
    try testing.expectEqual(1, log.closes);
    try testing.expectEqual(t.Result.error_invalid_handle, A.siv_window_destroy(window));
}
