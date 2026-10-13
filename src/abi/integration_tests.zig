//! The public API against sway running headless (`zig build
//! test-integration`): a window created through the exports maps and
//! presents on a real compositor, real pointer and keyboard input reach C
//! callbacks, the compositor's configure arrives as a resize, and sway's
//! kill command arrives as a close request that ends siv_app_run.
//!
//! Imports: abi, platform, compositor, text, loop, portal, helpers.

const std = @import("std");
const testing = std.testing;
const abi = @import("abi");
const text = @import("text");
const platform = @import("platform");
const Compositor = @import("compositor").Compositor;
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

    fn onActivate(user_data: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.clicks += 1;
        return .handled;
    }

    fn onChange(user_data: ?*anyopaque, _: t.Node, event: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(user_data));
        const e = event;
        log.changes += 1;
        log.text_len = @min(e.text_len, log.text.len);
        @memcpy(log.text[0..log.text_len], e.text.?[0..log.text_len]);
        return .handled;
    }

    fn onWindow(user_data: ?*anyopaque, _: t.Window, event: *const t.WindowEvent) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        const e = event;
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
    const root = A.siv_window_get_root(window);
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
    // The virtual device gives the seat its pointer capability. Sway sends
    // the pointer's enter only once it handled siv's get_pointer, so after
    // that the clicks reach siv.
    try vp.sync();
    try dispatchUntil(app, w, struct {
        fn f(win: *A.Window) bool {
            return win.uiWin().input.pointer != null;
        }
    }.f);
    vp.moveTo(100, 50);
    vp.button(0x110, true);
    vp.button(0x110, false);
    try vp.sync();
    try dispatchUntil(app, &log, struct {
        fn f(l: *Log) bool {
            return l.clicks == 1;
        }
    }.f);

    // Focus the editor and type through a virtual keyboard. Keys from a
    // keyboard that appears with them can beat siv's get_keyboard, so an
    // idle wtype provides the seat's keyboard first, and the keys follow
    // its enter.
    vp.moveTo(100, 120);
    vp.button(0x110, true);
    vp.button(0x110, false);
    try vp.sync();
    const keyboard = try sway.spawnClient(&[_:null]?[*:0]const u8{ "wtype", "-s", "60000" });
    defer {
        _ = std.c.kill(keyboard, std.c.SIG.TERM);
        var status: c_int = 0;
        _ = std.c.waitpid(keyboard, &status, 0);
    }
    try dispatchUntil(app, w, struct {
        fn f(win: *A.Window) bool {
            return win.uiWin().input.keyboard;
        }
    }.f);
    try typeKeys(&sway, app, &[_:null]?[*:0]const u8{ "wtype", "hi" });
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
    // window, and siv_app_run returns with no window left.
    try sway.command("kill");
    try ok(A.siv_app_run(app));
    try testing.expectEqual(1, log.closes);
    A.siv_window_destroy(window);
}

// Portals (D19) ------------------------------------------------------------------

const portal = @import("portal");
const P = abi.portal;
const PortalDesktop = portal.testing.Desktop;
const PortalBackend = portal.testing.Backend;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const PortalLog = struct {
    results: u32 = 0,
    response: t.PortalResponse = .failed,
    count: u32 = 0,
    actions: u32 = 0,
    target: [16]u8 = undefined,
    target_len: usize = 0,

    fn onResult(user_data: ?*anyopaque, result: *const t.PortalResult) callconv(.c) void {
        const log: *PortalLog = @ptrCast(@alignCast(user_data));
        log.results += 1;
        log.response = result.response;
        log.count = result.count;
    }

    fn onAction(user_data: ?*anyopaque, event: *const t.ActionEvent) callconv(.c) void {
        const log: *PortalLog = @ptrCast(@alignCast(user_data));
        const e = event;
        log.actions += 1;
        log.target_len = @min(e.target_len, log.target.len);
        @memcpy(log.target[0..log.target_len], e.target.?[0..log.target_len]);
    }
};

fn chooserResults(call: *const PortalBackend.Call, w: portal.vardict.Writer) anyerror!void {
    if (!std.mem.eql(u8, call.member, "OpenFile")) return;
    try w.open("uris", "as");
    try w.e.write(@as([]const []const u8, &.{"file:///home/u/My%20Pictures/cat.png"}));
    try w.close();
    try w.open("choices", "a(ss)");
    try w.e.write(@as([]const struct { []const u8, []const u8 }, &.{.{ "resize", "true" }}));
    try w.close();
    try w.open("current_filter", "(sa(us))");
    try w.e.write(.{ @as([]const u8, "Images"), @as([]const struct { u32, []const u8 }, &.{.{ 1, "image/png" }}) });
    try w.close();
}

test "portals through the public API on sway: parented dialogs, OpenURI, notifications" {
    var sway: Sway = .{};
    try sway.start();
    defer sway.stop();
    var desktop: PortalDesktop = .{};
    try desktop.start();
    defer desktop.stop();
    _ = setenv("DBUS_SESSION_BUS_ADDRESS", desktop.daemon.address.ptr, 1);
    defer _ = unsetenv("DBUS_SESSION_BUS_ADDRESS");

    var app: t.App = .null;
    try ok(A.siv_app_create(&.{ .display = sway.display.ptr, .display_len = sway.display.len, .flags = .{ .no_system_fonts = true }, .app_id = "org.example.Portals", .app_id_len = 19 }, &app));
    defer _ = A.siv_app_destroy(app);
    var window: t.Window = .null;
    try ok(A.siv_window_create(app, &.{ .title = "portals", .title_len = 7 }, &window));
    const w = try A.App.window(@backingInt(window), A.window_tag);
    try dispatchUntil(app, w, struct {
        fn f(win: *A.Window) bool {
            return win.win.presented_seq > 0;
        }
    }.f);

    // The file chooser, parented to the window's xdg-foreign export.
    desktop.backend.setResponse(0, chooserResults);
    var chooser: t.FileChooser = .null;
    try ok(P.siv_file_chooser_create(app, &.{ .title = "Open", .title_len = 4 }, &chooser));
    defer _ = P.siv_file_chooser_destroy(chooser);
    try ok(P.siv_file_chooser_add_filter(chooser, "Images", 6));
    try ok(P.siv_file_chooser_add_pattern(chooser, .mime, "image/png", 9));
    try ok(P.siv_file_chooser_add_choice(chooser, "resize", 6, "Resize", 6, "false", 5));
    var log: PortalLog = .{};
    try ok(P.siv_file_chooser_show(chooser, window, PortalLog.onResult, null, &log));
    try dispatchUntil(app, &log, struct {
        fn f(l: *PortalLog) bool {
            return l.results == 1;
        }
    }.f);
    try testing.expectEqual(t.PortalResponse.success, log.response);
    try testing.expectEqual(@as(u32, 1), log.count);
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    try ok(P.siv_file_chooser_get_path(chooser, 0, &buf, buf.len, &len));
    try testing.expectEqualStrings("/home/u/My Pictures/cat.png", buf[0..len]);
    try ok(P.siv_file_chooser_get_choice(chooser, "resize", 6, &buf, buf.len, &len));
    try testing.expectEqualStrings("true", buf[0..len]);
    var filter: i32 = -1;
    try ok(P.siv_file_chooser_get_filter(chooser, &filter));
    try testing.expectEqual(@as(i32, 0), filter);
    const call = desktop.backend.find("FileChooser", "OpenFile").?;
    // parent_window is "wayland:" and the handle sway exported.
    const parent = call.string(1);
    try testing.expect(std.mem.startsWith(u8, parent, "wayland:") and parent.len > "wayland:".len);

    // OpenURI launches the handler.
    log = .{};
    try ok(P.siv_open_uri(app, window, "sivtest:from-c", 14, .{}, PortalLog.onResult, null, &log));
    try dispatchUntil(app, &log, struct {
        fn f(l: *PortalLog) bool {
            return l.results == 1;
        }
    }.f);
    try testing.expectEqual(t.PortalResponse.success, log.response);
    const Opened = struct {
        var d: *PortalDesktop = undefined;
        fn f(_: void) bool {
            var b: [512]u8 = undefined;
            return std.mem.indexOf(u8, d.opened(&b), "sivtest:from-c") != null;
        }
    };
    Opened.d = &desktop;
    try dispatchUntil(app, {}, Opened.f);

    // A notification whose button invokes an application action.
    try ok(P.siv_app_add_action(app, "archive", 7, PortalLog.onAction, null, &log));
    const buttons = [_]t.NotificationButton{.{ .label = "Archive", .label_len = 7, .action = "archive", .action_len = 7, .target = "42", .target_len = 2 }};
    try ok(P.siv_notification_send(app, &.{ .id = "mail", .id_len = 4, .title = "New mail", .title_len = 8, .buttons = &buttons, .buttons_count = 1 }));
    const Added = struct {
        var d: *PortalDesktop = undefined;
        fn f(_: void) bool {
            return d.backend.find("Notification", "AddNotification") != null;
        }
    };
    Added.d = &desktop;
    try dispatchUntil(app, {}, Added.f);
    var bb = desktop.backend.find("Notification", "AddNotification").?.options().get("buttons", "aa{sv}").?;
    const ba = try bb.beginArray();
    try testing.expect(ba.next(&bb));
    try testing.expectEqualStrings("app.archive", (try portal.vardict.Reader.take(&bb)).string("action").?);
    // The desktop reports the button (a host application's id is empty
    // to xdg-desktop-portal 1.16); the frontend forwards it to siv.
    try desktop.backend.invokeAction("", "mail", "app.archive", "42");
    try dispatchUntil(app, &log, struct {
        fn f(l: *PortalLog) bool {
            return l.actions == 1;
        }
    }.f);
    try testing.expectEqualStrings("42", log.target[0..log.target_len]);
}

// Printing (D9, D19) --------------------------------------------------------------

fn printResults(call: *const PortalBackend.Call, w: portal.vardict.Writer) anyerror!void {
    if (!std.mem.eql(u8, call.member, "PreparePrint")) return;
    try w.open("settings", "a{sv}");
    const st = try portal.vardict.Writer.begin(w.e);
    try st.put("printer", @as([]const u8, "Test Printer"));
    try st.end();
    try w.close();
    try w.open("page-setup", "a{sv}");
    const ps = try portal.vardict.Writer.begin(w.e);
    try ps.put("Name", @as([]const u8, "iso_a4"));
    try ps.put("Width", @as(f64, 210));
    try ps.put("Height", @as(f64, 297));
    inline for (.{ "MarginTop", "MarginRight", "MarginBottom", "MarginLeft" }) |k| try ps.put(k, @as(f64, 6.35));
    try ps.put("Orientation", @as([]const u8, "landscape"));
    try ps.end();
    try w.close();
    try w.put("token", @as(u32, 5));
}

const Printing = struct {
    done: u32 = 0,
    response: t.PortalResponse = .failed,
    pages: u32 = 0,
    width: f32 = 0,

    fn begin(user_data: ?*anyopaque, setup: *const t.PageSetup) callconv(.c) u32 {
        const p: *Printing = @ptrCast(@alignCast(user_data));
        p.width = setup.width;
        return 2;
    }

    fn drawPage(_: ?*anyopaque, draw: t.Draw, page: u32, setup: *const t.PageSetup) callconv(.c) void {
        const s = setup;
        const words: []const u8 = if (page == 0) "Printed by siv" else "Second sheet";
        _ = abi.canvas.siv_draw_text(draw, s.margin_left, s.margin_top, 0, words.ptr, words.len, &.{ .font_size = 24 });
    }

    fn onDone(user_data: ?*anyopaque, result: *const t.PortalResult) callconv(.c) void {
        const p: *Printing = @ptrCast(@alignCast(user_data));
        p.done += 1;
        p.response = result.response;
        p.pages = result.count;
    }
};

/// Runs a tool (poppler, qpdf) on a file and returns its exit status and
/// output in `buf`.
fn runTool(name: []const u8, args: []const [*:0]const u8, buf: []u8) !struct { status: c_int, output: []const u8 } {
    const linux = std.os.linux;
    const exe = td.findExecutable(name) orelse return error.SkipZigTest;
    var argv: [8:null]?[*:0]const u8 = @splat(null);
    argv[0] = exe;
    for (args, 1..) |a, i| argv[i] = a;
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", "LC_ALL=C.UTF-8" };
    const out: i32 = @intCast(linux.memfd_create("siv-tool", linux.MFD.CLOEXEC));
    defer _ = linux.close(out);
    const pid = try td.spawn(exe, &argv, &envp, out);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const n = linux.pread(out, buf.ptr, buf.len, 0);
    return .{ .status = status, .output = buf[0..if (linux.errno(n) == .SUCCESS) n else 0] };
}

test "printing through the public API: the Print portal's dialog, then the PDF" {
    var sway: Sway = .{};
    try sway.start();
    defer sway.stop();
    var desktop: PortalDesktop = .{};
    try desktop.start();
    defer desktop.stop();
    _ = setenv("DBUS_SESSION_BUS_ADDRESS", desktop.daemon.address.ptr, 1);
    defer _ = unsetenv("DBUS_SESSION_BUS_ADDRESS");

    var app: t.App = .null;
    try ok(A.siv_app_create(&.{ .display = sway.display.ptr, .display_len = sway.display.len, .flags = .{ .no_system_fonts = true }, .app_id = "org.example.Printing", .app_id_len = 20 }, &app));
    defer _ = A.siv_app_destroy(app);
    const latin = text.font.test_fonts.latin;
    try ok(A.siv_app_add_font(app, "Droid", 5, latin.ptr, latin.len));
    try ok(A.siv_app_set_default_font(app, "Droid", 5));
    var window: t.Window = .null;
    try ok(A.siv_window_create(app, &.{ .title = "printing", .title_len = 8 }, &window));
    const w = try A.App.window(@backingInt(window), A.window_tag);
    try dispatchUntil(app, w, struct {
        fn f(win: *A.Window) bool {
            return win.win.presented_seq > 0;
        }
    }.f);

    desktop.backend.setResponse(0, printResults);
    var printing: Printing = .{};
    try ok(abi.print.siv_print(app, window, &.{ .title = "Report", .title_len = 6, .user_data = &printing, .begin = Printing.begin, .draw_page = Printing.drawPage, .done = Printing.onDone }));
    try dispatchUntil(app, &printing, struct {
        fn f(p: *Printing) bool {
            return p.done == 1;
        }
    }.f);
    try testing.expectEqual(t.PortalResponse.success, printing.response);
    try testing.expectEqual(@as(u32, 2), printing.pages);
    // Landscape A4 in points.
    try testing.expectApproxEqAbs(@as(f32, 841.89), printing.width, 0.01);

    const prepare = desktop.backend.find("Print", "PreparePrint").?;
    try testing.expect(std.mem.startsWith(u8, prepare.string(1), "wayland:"));
    try testing.expectEqualStrings("Report", prepare.string(2));
    const call = desktop.backend.find("Print", "Print").?;
    try testing.expectEqual(@as(u32, 5), call.options().uint("token").?);
    try testing.expect(std.mem.startsWith(u8, call.fd_data, "%PDF-1.7"));

    // The PDF the print system got, by independent readers.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/siv-print-{d}.pdf", .{std.os.linux.getpid()}, 0);
    try td.writeFile(path, call.fd_data);
    defer _ = std.os.linux.unlink(path);
    var buf: [4096]u8 = undefined;
    const check = try runTool("qpdf", &.{ "--check", path }, &buf);
    if (check.status != 0) std.debug.print("{s}\n", .{check.output});
    try testing.expectEqual(@as(c_int, 0), check.status);
    const words = try runTool("pdftotext", &.{ path, "-" }, &buf);
    try testing.expect(std.mem.indexOf(u8, words.output, "Printed by siv") != null);
    try testing.expect(std.mem.indexOf(u8, words.output, "Second sheet") != null);
    const info = try runTool("pdfinfo", &.{path}, &buf);
    try testing.expect(std.mem.indexOf(u8, info.output, "Report") != null);
    try testing.expect(std.mem.indexOf(u8, info.output, "841.89 x 595.2") != null);
}

// The tray (D19) ------------------------------------------------------------------

const TrayLog = struct {
    unregistered: u32 = 0,
    activated: u32 = 0,
    menu: u32 = 0,
    destroyed: u32 = 0,

    fn onEvent(user_data: ?*anyopaque, _: t.TrayItem, event: *const t.TrayEvent) callconv(.c) void {
        const log: *TrayLog = @ptrCast(@alignCast(user_data));
        const e = event;
        switch (e.type) {
            .unregistered => log.unregistered += 1,
            .activate => log.activated += 1,
            .menu => log.menu = e.menu_item,
            else => {},
        }
    }

    fn onDestroy(user_data: ?*anyopaque) callconv(.c) void {
        const log: *TrayLog = @ptrCast(@alignCast(user_data));
        log.destroyed += 1;
    }
};

/// Runs gdbus against `address` while the application keeps dispatching,
/// and returns its output.
fn gdbusOutput(app: t.App, address: []const u8, args: []const [*:0]const u8, buf: []u8) ![]const u8 {
    const linux = std.os.linux;
    const exe = td.findExecutable("gdbus") orelse return error.GdbusNotInstalled;
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    argv[0] = exe;
    for (args, 1..) |a, i| argv[i] = a;
    var env_buf: [256]u8 = undefined;
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", try std.fmt.bufPrintSentinel(&env_buf, "DBUS_SESSION_BUS_ADDRESS={s}", .{address}, 0) };
    const out: i32 = @intCast(linux.memfd_create("siv-gdbus", linux.MFD.CLOEXEC));
    defer _ = linux.close(out);
    const pid = try td.spawn(exe, &argv, &envp, out);
    var status: c_int = 0;
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (std.c.waitpid(pid, &status, std.c.W.NOHANG) == 0) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(A.siv_app_dispatch(app, 10));
    }
    const n = linux.pread(out, buf.ptr, buf.len, 0);
    const output = buf[0..if (linux.errno(n) == .SUCCESS) n else 0];
    if (status != 0) {
        std.debug.print("gdbus failed: {s}\n", .{output});
        return error.GdbusFailed;
    }
    return output;
}

test "a tray item through the public API over dbus-daemon, driven by gdbus" {
    var daemon: td.Daemon = .{};
    try daemon.start();
    defer daemon.stop();
    _ = setenv("DBUS_SESSION_BUS_ADDRESS", daemon.address.ptr, 1);
    defer _ = unsetenv("DBUS_SESSION_BUS_ADDRESS");

    // The headless backend connects the session bus for an application id.
    var app: t.App = .null;
    try ok(A.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true }, .app_id = "org.example.Tray", .app_id_len = 16 }, &app));
    defer _ = A.siv_app_destroy(app);
    var log: TrayLog = .{};
    var item: t.TrayItem = .null;
    try ok(abi.tray.siv_tray_item_create(app, &.{ .title = "Example", .title_len = 7, .icon_name = "mail-unread", .icon_name_len = 11, .on_event = TrayLog.onEvent, .destroy = TrayLog.onDestroy, .user_data = &log }, &item));
    var second: t.TrayItem = .null;
    try testing.expectEqual(t.Result.error_busy, abi.tray.siv_tray_item_create(app, null, &second));
    try ok(abi.tray.siv_tray_item_set_menu_item(item, &.{ .id = 7, .label = "Quit", .label_len = 4 }));
    try testing.expectEqual(t.Result.error_invalid_argument, abi.tray.siv_tray_item_set_menu_item(item, &.{ .id = 8, .parent = 99 }));
    // A 1x1 red image becomes an ARGB pixmap.
    const px = [_]u8{ 255, 0, 0, 255 };
    var image: t.Image = .null;
    try ok(abi.canvas.siv_image_create(app, &.{ .pixels = &px, .pixels_count = 4, .width = 1, .height = 1 }, &image));
    try ok(abi.tray.siv_tray_item_set_icon(item, "mail-unread", 11, image));
    try ok(abi.tray.siv_tray_item_set_status(item, .needs_attention));
    // No tray runs on this bus.
    try dispatchUntil(app, &log, struct {
        fn f(l: *TrayLog) bool {
            return l.unregistered == 1;
        }
    }.f);

    const self = try A.App.get(@backingInt(app));
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&name_buf, "{s}", .{self.desktop.tray.item.?.item.owner.name}, 0);
    var buf: [8192]u8 = undefined;
    const props = try gdbusOutput(app, daemon.address, &.{ "call", "--session", "--dest", name, "--object-path", "/StatusNotifierItem", "--method", "org.freedesktop.DBus.Properties.GetAll", "org.kde.StatusNotifierItem" }, &buf);
    try testing.expect(std.mem.indexOf(u8, props, "'Id': <'org.example.Tray'>") != null);
    try testing.expect(std.mem.indexOf(u8, props, "'Status': <'NeedsAttention'>") != null);
    try testing.expect(std.mem.indexOf(u8, props, "[(1, 1, [byte 0xff, 0xff, 0x00, 0x00])]") != null);
    _ = try gdbusOutput(app, daemon.address, &.{ "call", "--session", "--dest", name, "--object-path", "/MenuBar", "--method", "com.canonical.dbusmenu.Event", "7", "clicked", "<0>", "0" }, &buf);
    try testing.expectEqual(@as(u32, 7), log.menu);
    _ = try gdbusOutput(app, daemon.address, &.{ "call", "--session", "--dest", name, "--object-path", "/StatusNotifierItem", "--method", "org.kde.StatusNotifierItem.Activate", "0", "0" }, &buf);
    try testing.expectEqual(@as(u32, 1), log.activated);

    abi.tray.siv_tray_item_destroy(item);
    try testing.expectEqual(@as(u32, 1), log.destroyed);
    abi.tray.siv_tray_item_destroy(item);
}

// Lifecycle (D19) -----------------------------------------------------------------

const helpers = @import("helpers");
const td = portal.testing.daemon;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

/// The lifecycle helper (test/c/lifecycle.c) and the libsiv it links, as
/// absolute paths.
const Helper = struct {
    exe_buf: [4096]u8 = undefined,
    lib_buf: [4096]u8 = undefined,
    exe: [:0]const u8 = "",
    lib_dir: []const u8 = "",

    fn init(h: *Helper) !void {
        var z: [4096]u8 = undefined;
        h.exe = std.mem.span(realpath(try std.fmt.bufPrintSentinel(&z, "{s}", .{helpers.lifecycle}, 0), &h.exe_buf) orelse return error.HelperNotFound);
        const lib = std.mem.span(realpath(try std.fmt.bufPrintSentinel(&z, "{s}", .{helpers.libsiv}, 0), &h.lib_buf) orelse return error.HelperNotFound);
        h.lib_dir = std.fs.path.dirname(lib).?;
    }
};

fn readLog(path: [:0]const u8, buf: []u8) []const u8 {
    const linux = std.os.linux;
    const rc = linux.open(path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return "";
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    return buf[0..n];
}

fn waitLog(path: [:0]const u8, what: []const u8) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    var buf: [4096]u8 = undefined;
    while (std.mem.indexOf(u8, readLog(path, &buf), what) == null) {
        if (Loop.now() > deadline) {
            std.debug.print("log so far:\n{s}\n", .{readLog(path, &buf)});
            return error.Timeout;
        }
        td.sleepMs(10);
    }
}

/// Runs gdbus (GLib, an independent client) against the private bus and
/// waits for it.
fn gdbus(address: []const u8, args: []const [*:0]const u8) !void {
    const exe = td.findExecutable("gdbus") orelse return error.GdbusNotInstalled;
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    argv[0] = exe;
    for (args, 1..) |a, i| argv[i] = a;
    var env_buf: [256]u8 = undefined;
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", try std.fmt.bufPrintSentinel(&env_buf, "DBUS_SESSION_BUS_ADDRESS={s}", .{address}, 0) };
    const pid = try td.spawn(exe, &argv, &envp, null);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    if (status != 0) return error.GdbusFailed;
}

test "lifecycle: single instance, forwarding, and D-Bus activation through dbus-daemon" {
    var helper: Helper = .{};
    try helper.init();
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/siv-life-{d}", .{std.os.linux.getpid()}, 0);
    _ = std.os.linux.mkdir(dir, 0o700);
    var log_buf: [96]u8 = undefined;
    const log = try std.fmt.bufPrintSentinel(&log_buf, "{s}/log", .{dir}, 0);
    var svc_buf: [96]u8 = undefined;
    const svc = try std.fmt.bufPrintSentinel(&svc_buf, "{s}/org.siv.Test.Lifecycle.service", .{dir}, 0);
    var svc_text: [8192 + 512]u8 = undefined;
    try td.writeFile(svc, try std.fmt.bufPrint(&svc_text,
        \\[D-BUS Service]
        \\Name=org.siv.Test.Lifecycle
        \\Exec=/usr/bin/env LD_LIBRARY_PATH={s} {s} --service --log={s}
        \\
    , .{ helper.lib_dir, helper.exe, log }));
    defer {
        _ = std.os.linux.unlink(log);
        _ = std.os.linux.unlink(svc);
        _ = std.os.linux.rmdir(dir);
    }

    var daemon: td.Daemon = .{ .service_dir = dir };
    try daemon.start();
    defer daemon.stop();

    // D-Bus activation: calling Activate starts the service, which answers
    // instead of activating by itself.
    try gdbus(daemon.address, &.{ "call", "--session", "--dest", "org.siv.Test.Lifecycle", "--object-path", "/org/siv/Test/Lifecycle", "--method", "org.freedesktop.Application.Activate", "{'activation-token': <'tok-dbus'>}" });
    try waitLog(log, "activate remote token=tok-dbus\n");
    try gdbus(daemon.address, &.{ "call", "--session", "--dest", "org.siv.Test.Lifecycle", "--object-path", "/org/siv/Test/Lifecycle", "--method", "org.freedesktop.Application.Open", "['file:///tmp/a.txt']", "{}" });
    try waitLog(log, "open remote token= file:///tmp/a.txt\n");
    try gdbus(daemon.address, &.{ "call", "--session", "--dest", "org.siv.Test.Lifecycle", "--object-path", "/org/siv/Test/Lifecycle", "--method", "org.freedesktop.Application.ActivateAction", "quit", "[<'now'>]", "{}" });
    try waitLog(log, "action quit now\nexit primary SIV_OK\n");
    var buf: [4096]u8 = undefined;
    // The service never activated by itself.
    try testing.expect(std.mem.indexOf(u8, readLog(log, &buf), "launch") == null);

    // Launched twice: the second forwards its URI and token, then exits.
    // The library's directory is in the build's cache, as long as the
    // checkout's path makes it.
    var env: [2][std.os.linux.PATH_MAX + 64]u8 = undefined;
    const base = [_]?[*:0]const u8{
        "PATH=/usr/bin:/bin",
        try std.fmt.bufPrintSentinel(&env[0], "DBUS_SESSION_BUS_ADDRESS={s}", .{daemon.address}, 0),
        try std.fmt.bufPrintSentinel(&env[1], "LD_LIBRARY_PATH={s}", .{helper.lib_dir}, 0),
    };
    var log_arg_buf: [128]u8 = undefined;
    const log_arg = try std.fmt.bufPrintSentinel(&log_arg_buf, "--log={s}", .{log}, 0);
    const first_env = base ++ [_:null]?[*:0]const u8{"XDG_ACTIVATION_TOKEN=first"};
    const first = try td.spawn(helper.exe, &[_:null]?[*:0]const u8{ helper.exe, log_arg }, &first_env, null);
    try waitLog(log, "activate launch token=first\n");
    const second_env = base ++ [_:null]?[*:0]const u8{"XDG_ACTIVATION_TOKEN=second"};
    const second = try td.spawn(helper.exe, &[_:null]?[*:0]const u8{ helper.exe, log_arg, "file:///tmp/b.txt" }, &second_env, null);
    var status: c_int = 0;
    _ = std.c.waitpid(second, &status, 0);
    try testing.expectEqual(@as(c_int, 0), status);
    try waitLog(log, "open remote token=second file:///tmp/b.txt\n");
    try waitLog(log, "exit secondary SIV_OK\n");
    // GLib sees the interface.
    try gdbus(daemon.address, &.{ "call", "--session", "--dest", "org.siv.Test.Lifecycle", "--object-path", "/org/siv/Test/Lifecycle", "--method", "org.freedesktop.Application.ActivateAction", "quit", "[]", "{}" });
    _ = std.c.waitpid(first, &status, 0);
    try testing.expectEqual(@as(c_int, 0), status);
    try waitLog(log, "exit primary SIV_OK\n");
}

// Menus on popups (D17, D22) ---------------------------------------------------

const MenuLog = struct {
    selects: u32 = 0,
    index: u32 = 0,

    fn onSelect(user_data: ?*anyopaque, _: t.Node, event: *const t.Event) callconv(.c) t.EventResult {
        const log: *MenuLog = @ptrCast(@alignCast(user_data));
        log.selects += 1;
        log.index = event.index;
        return .pass;
    }
};

/// The application's shown popups, in creation order.
fn shownPopups(app: t.App, out: []*A.Window) !usize {
    const self = try A.App.get(@backingInt(app));
    var n: usize = 0;
    for (self.windows.items) |slot| if (slot) |w| {
        if (!w.dead and w.parent != null and w.win.shown and n < out.len) {
            out[n] = w;
            n += 1;
        }
    };
    return n;
}

/// Whether sway has shown `w`: presentation feedback for one of its
/// commits arrived. siv's own `presented` event comes as soon as siv
/// commits; sway may still handle input from another connection (the
/// virtual pointer, wtype) before that commit, and hit-test without the
/// window.
fn swayShown(w: *A.Window) !bool {
    const Probe = struct {
        id: platform.WindowId,
        shown: bool = false,
        fn run(ctx: ?*anyopaque, comp: *Compositor) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.shown = comp.platform.wayland.get(p.id).clock.last_present_ns != null;
        }
    };
    var p: Probe = .{ .id = w.win.id };
    try w.win.app.comp.call(&p, Probe.run);
    return p.shown;
}

fn waitPopups(app: t.App, count: usize) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    var ps: [4]*A.Window = undefined;
    while (true) {
        const n = try shownPopups(app, &ps);
        // Placed by the compositor and on screen, so that input sent from
        // now on finds them.
        var placed = n == count;
        for (ps[0..n]) |p| placed = placed and p.win.state.popup != null and p.win.presented_seq > 0 and try swayShown(p);
        if (placed) return;
        if (Loop.now() > deadline) return error.Timeout;
        try ok(A.siv_app_dispatch(app, 10));
    }
}

fn typeKeys(sway: *const Sway, app: t.App, argv: [*:null]const ?[*:0]const u8) !void {
    const pid = try sway.spawnClient(argv);
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, std.c.W.NOHANG) == 0) try ok(A.siv_app_dispatch(app, 10));
    try testing.expectEqual(0, status);
}

test "menus on sway: a click opens a grabbing popup, keys reach it, submenus open beside their item, and a click outside dismisses" {
    var sway: Sway = .{};
    try sway.start();
    defer sway.stop();

    var app: t.App = .null;
    try ok(A.siv_app_create(&.{ .display = sway.display.ptr, .display_len = sway.display.len, .flags = .{ .no_system_fonts = true, .reduced_motion = true } }, &app));
    defer _ = A.siv_app_destroy(app);
    try ok(A.siv_app_add_font(app, "Droid", 5, text.font.test_fonts.latin.ptr, text.font.test_fonts.latin.len));
    try ok(A.siv_app_set_default_font(app, "Droid", 5));
    var window: t.Window = .null;
    try ok(A.siv_window_create(app, &.{ .title = "menus", .title_len = 5 }, &window));

    const c = t.c;
    var log: MenuLog = .{};
    var sub_log: MenuLog = .{};
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(window, &txn));
    const col = c.siv_flex(txn, A.siv_window_get_root(window), &.{ .axis = .column, .align_items = .start });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 20, .top = 20 } });
    const button = c.siv_menu_button(txn, col, &.{ .label = "File", .label_len = 4 });
    const recent = c.siv_menu(txn, col, &.{ .label = "Recent", .label_len = 6 });
    _ = c.siv_menu_item(txn, recent, &.{ .label = "a.txt", .label_len = 5 });
    _ = c.siv_menu_item(txn, recent, &.{ .label = "b.txt", .label_len = 5 });
    _ = c.siv_menu_item(txn, button, &.{ .label = "New", .label_len = 3 });
    _ = c.siv_menu_item(txn, button, &.{ .label = "Recent", .label_len = 6, .submenu = recent });
    _ = c.siv_menu_item(txn, button, &.{ .label = "Quit", .label_len = 4 });
    _ = c.siv_on(txn, button, .select, MenuLog.onSelect, null, &log);
    _ = c.siv_on(txn, recent, .select, MenuLog.onSelect, null, &sub_log);
    try ok(T.siv_txn_commit(txn));
    const w = try A.App.window(@backingInt(window), A.window_tag);
    try dispatchUntil(app, w, struct {
        fn f(win: *A.Window) bool {
            return win.win.presented_seq > 0 and win.win.settled() and win.win.ui.width == 1280;
        }
    }.f);

    var vp = try VirtualPointer.connect(&sway);
    defer vp.deinit();
    try vp.sync();
    // A keyboard that exists before the menu opens, as on a real seat:
    // one that appears while a popup holds the grab gets focus on the
    // toplevel. An idle wtype provides it.
    const keyboard = try sway.spawnClient(&[_:null]?[*:0]const u8{ "wtype", "-s", "60000" });
    defer {
        _ = std.c.kill(keyboard, std.c.SIG.TERM);
        var status: c_int = 0;
        _ = std.c.waitpid(keyboard, &status, 0);
    }
    try dispatchUntil(app, w, struct {
        fn f(win: *A.Window) bool {
            return win.uiWin().input.keyboard;
        }
    }.f);
    var r: t.Rect = undefined;
    try ok(T.siv_node_get_rect(button, &r));
    const click = struct {
        fn at(p: *VirtualPointer, x: f64, y: f64) !void {
            p.moveTo(@intFromFloat(x), @intFromFloat(y));
            p.button(0x110, true);
            p.button(0x110, false);
            try p.sync();
        }
    }.at;

    // A real click opens the menu with a grab, below the button.
    try click(&vp, r.x + r.width / 2, r.y + r.height / 2);
    try waitPopups(app, 1);
    var ps: [4]*A.Window = undefined;
    _ = try shownPopups(app, &ps);
    const top = ps[0];
    const at = top.win.state.popup.?;
    try testing.expect(@as(f64, @floatFromInt(at.x)) >= r.x - 8 and @as(f64, @floatFromInt(at.x)) <= r.x + r.width);
    try testing.expect(@as(f64, @floatFromInt(at.y)) >= r.y + r.height - 1);

    // The grab gives the popup the keyboard: Down then Right open the
    // submenu, focused, beside its item on the end side.
    try typeKeys(&sway, app, &[_:null]?[*:0]const u8{ "wtype", "-k", "Down", "-k", "Right" });
    try waitPopups(app, 2);
    _ = try shownPopups(app, &ps);
    const sub = ps[1];
    const sat = sub.win.state.popup.?;
    try testing.expect(sat.x >= @as(i32, @intFromFloat(top.uiWin().width)) - 8);
    const sub_tree = try sub.uiWin().semanticsTree();
    try testing.expectEqualStrings("a.txt", sub_tree.name(sub_tree.focused().?.*));

    // Enter chooses in the submenu and closes the chain.
    try typeKeys(&sway, app, &[_:null]?[*:0]const u8{ "wtype", "-k", "Return" });
    try waitPopups(app, 0);
    try testing.expectEqual(@as(u32, 1), sub_log.selects);
    try testing.expectEqual(@as(u32, 0), sub_log.index);
    try testing.expectEqual(@as(u32, 0), log.selects);

    // Hovering the item opens the submenu without a grab under a grabbing
    // popup; a click outside dismisses the whole chain.
    try click(&vp, r.x + r.width / 2, r.y + r.height / 2);
    try waitPopups(app, 1);
    _ = try shownPopups(app, &ps);
    const top2 = ps[0];
    const tree2 = try top2.uiWin().semanticsTree();
    const item = tree2.find(.menu_item, "Recent").?.bounds;
    const origin = top2.win.state.popup.?;
    vp.moveTo(@intFromFloat(@as(f64, @floatFromInt(origin.x)) + (item.x0 + item.x1) / 2), @intFromFloat(@as(f64, @floatFromInt(origin.y)) + (item.y0 + item.y1) / 2));
    try vp.sync();
    try waitPopups(app, 2);
    try click(&vp, 900, 600);
    try waitPopups(app, 0);
    try testing.expectEqual(@as(u32, 0), log.selects);
    try testing.expectEqual(@as(u32, 1), sub_log.selects);
}
