//! Portals and application actions through the exports (D19, D34) on the headless backend,
//! which has no session bus: requests complete as unavailable at the next
//! dispatch, never inside the call; argument checks, handle lifetimes,
//! and destroy-notifies follow D2. The portal round trips run against
//! the real xdg-desktop-portal in `zig build test-integration`.

const std = @import("std");
const abi = @import("abi");
const harness = @import("harness.zig");
const Loop = @import("loop").Loop;

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const P = abi.portal;
const ok = harness.ok;

const Log = struct {
    results: u32 = 0,
    destroys: u32 = 0,
    last: t.PortalResponse = .success,
    count: u32 = 0,
    events: u32 = 0,
    event: t.ScreencastEventType = .closed,
    event_response: t.PortalResponse = .success,
    actions: u32 = 0,

    fn onResult(user_data: ?*anyopaque, result: *const t.PortalResult) callconv(.c) void {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.results += 1;
        log.last = result.response;
        log.count = result.count;
    }

    fn onDestroy(user_data: ?*anyopaque) callconv(.c) void {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.destroys += 1;
    }

    fn onCast(user_data: ?*anyopaque, _: t.Screencast, event: *const t.ScreencastEvent) callconv(.c) void {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.events += 1;
        log.event = event.type;
        log.event_response = event.response;
    }

    fn onAction(user_data: ?*anyopaque, _: *const t.ActionEvent) callconv(.c) void {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.actions += 1;
    }
};

fn dispatch(h: *harness.Harness, n: usize) !void {
    for (0..n) |_| try ok(A.siv_app_dispatch(h.app, 1));
}

test "without a session bus, portal requests are unavailable at the next dispatch" {
    var h: harness.Harness = .{};
    try h.start(64, 48, null, null);
    defer h.stop();
    var log: Log = .{};
    try ok(P.siv_open_uri(h.app, h.window, "https://example.com", 19, .{}, Log.onResult, Log.onDestroy, &log));
    try ok(P.siv_screenshot(h.app, .null, .{ .interactive = true }, Log.onResult, Log.onDestroy, &log));
    try ok(P.siv_pick_color(h.app, h.window, Log.onResult, Log.onDestroy, &log));
    try ok(P.siv_document_export(h.app, &.{ .path = "/etc/hostname", .path_len = 13 }, Log.onResult, Log.onDestroy, &log));
    // Not inside the calls.
    try testing.expectEqual(@as(u32, 0), log.results);
    try dispatch(&h, 2);
    try testing.expectEqual(@as(u32, 4), log.results);
    try testing.expectEqual(@as(u32, 4), log.destroys);
    try testing.expectEqual(t.PortalResponse.unavailable, log.last);

    try testing.expectEqual(t.Result.error_unavailable, P.siv_notification_send(h.app, &.{ .id = "n", .id_len = 1, .title = "Hi", .title_len = 2 }));
    var cast: t.Screencast = .null;
    try ok(P.siv_screencast_start(h.app, h.window, &.{ .on_event = Log.onCast, .destroy = Log.onDestroy, .user_data = &log }, &cast));
    try dispatch(&h, 2);
    try testing.expectEqual(@as(u32, 1), log.events);
    try testing.expectEqual(t.ScreencastEventType.started, log.event);
    try testing.expectEqual(t.PortalResponse.unavailable, log.event_response);
    var fd: i32 = -1;
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_screencast_take_pipewire_fd(cast, &fd));
    _ = P.siv_screencast_destroy(cast);
    try testing.expectEqual(@as(u32, 5), log.destroys);
    P.siv_screencast_destroy(cast);
}

test "rejected calls run their destroy-notify at once" {
    var h: harness.Harness = .{};
    try h.start(64, 48, null, null);
    defer h.stop();
    var log: Log = .{};
    try testing.expectEqual(t.Result.error_unsupported, P.siv_open_uri(h.app, h.window, "x:y", 3, @bitCast(@as(u32, 1 << 9)), Log.onResult, Log.onDestroy, &log));
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_open_uri(h.app, h.window, "", 0, .{}, Log.onResult, Log.onDestroy, &log));
    try testing.expectEqual(t.Result.error_invalid_handle, P.siv_screenshot(h.app, @fromBackingInt(12345), .{}, Log.onResult, Log.onDestroy, &log));
    try testing.expectEqual(t.Result.error_invalid_handle, P.siv_pick_color(.null, .null, Log.onResult, Log.onDestroy, &log));
    try testing.expectEqual(@as(u32, 4), log.destroys);
    try testing.expectEqual(@as(u32, 0), log.results);
}

test "file choosers are built, shown once at a time, and cancelled" {
    var h: harness.Harness = .{};
    try h.start(64, 48, null, null);
    defer h.stop();
    var c: t.FileChooser = .null;
    try ok(P.siv_file_chooser_create(h.app, &.{ .title = "Open", .title_len = 4, .flags = .{ .multiple = true } }, &c));
    // Patterns and options need a filter and a choice first.
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_file_chooser_add_pattern(c, .glob, "*.png", 5));
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_file_chooser_add_choice_option(c, "a", 1, "A", 1));
    try ok(P.siv_file_chooser_add_filter(c, "Images", 6));
    try ok(P.siv_file_chooser_add_pattern(c, .mime, "image/png", 9));
    try testing.expectEqual(t.Result.error_unsupported, P.siv_file_chooser_add_pattern(c, @enumFromInt(7), "x", 1));
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_file_chooser_set_current_filter(c, 1));
    try ok(P.siv_file_chooser_set_current_filter(c, 0));
    try ok(P.siv_file_chooser_add_choice(c, "enc", 3, "Encoding", 8, "utf8", 4));
    try ok(P.siv_file_chooser_add_choice_option(c, "utf8", 4, "UTF-8", 5));

    var log: Log = .{};
    try ok(P.siv_file_chooser_show(c, h.window, Log.onResult, Log.onDestroy, &log));
    var other: Log = .{};
    try testing.expectEqual(t.Result.error_busy, P.siv_file_chooser_show(c, h.window, Log.onResult, Log.onDestroy, &other));
    try testing.expectEqual(@as(u32, 1), other.destroys);
    // Cancelled: the destroy-notify runs, the callback never does.
    _ = P.siv_file_chooser_cancel(c);
    try dispatch(&h, 2);
    try testing.expectEqual(@as(u32, 0), log.results);
    try testing.expectEqual(@as(u32, 1), log.destroys);

    try ok(P.siv_file_chooser_show(c, .null, Log.onResult, Log.onDestroy, &log));
    try dispatch(&h, 2);
    try testing.expectEqual(t.PortalResponse.unavailable, log.last);
    var count: u32 = 99;
    try ok(P.siv_file_chooser_get_uri_count(c, &count));
    try testing.expectEqual(@as(u32, 0), count);
    var len: usize = 0;
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_file_chooser_get_uri(c, 0, null, 0, &len));
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_file_chooser_get_choice(c, "enc", 3, null, 0, &len));
    var filter: i32 = 7;
    try ok(P.siv_file_chooser_get_filter(c, &filter));
    try testing.expectEqual(@as(i32, -1), filter);
    _ = P.siv_file_chooser_destroy(c);
    try testing.expectEqual(t.Result.error_invalid_handle, P.siv_file_chooser_add_filter(c, "x", 1));
}

test "the desktop invokes enabled application actions by name; actions and inhibitions are handles" {
    const Act = abi.actions;
    var log: Log = .{};
    {
        var h: harness.Harness = .{};
        try h.start(64, 48, null, null);
        defer h.stop();
        var quit: t.Action = .null;
        try ok(Act.siv_action_create(h.app, &.{ .name = "quit", .name_len = 4 }, Log.onAction, Log.onDestroy, &log, &quit));
        // A name its scope has: refused, and the destroy-notify runs.
        var dup: t.Action = .null;
        try testing.expectEqual(t.Result.error_invalid_argument, Act.siv_action_create(h.app, &.{ .name = "quit", .name_len = 4 }, Log.onAction, Log.onDestroy, &log, &dup));
        try testing.expectEqual(@as(u32, 1), log.destroys);
        // The coordinator's registry (notifications, ActivateAction) runs
        // it, unless it is disabled.
        const self = try h.internal();
        self.app.invokeAction("quit", "", "");
        try testing.expectEqual(@as(u32, 1), log.actions);
        try ok(Act.siv_action_set_enabled(quit, false));
        self.app.invokeAction("quit", "", "");
        try testing.expectEqual(@as(u32, 1), log.actions);
        // A window's actions are not the desktop's.
        var close: t.Action = .null;
        try ok(Act.siv_action_create(h.app, &.{ .name = "close", .name_len = 5, .window = h.window }, Log.onAction, null, &log, &close));
        self.app.invokeAction("close", "", "");
        try testing.expectEqual(@as(u32, 1), log.actions);
        _ = Act.siv_action_destroy(quit);
        try testing.expectEqual(@as(u32, 2), log.destroys);
        Act.siv_action_destroy(quit);
        try testing.expectEqual(t.Result.error_invalid_handle, Act.siv_action_set_enabled(quit, true));
        try testing.expectEqual(t.Result.error_invalid_argument, Act.siv_action_create(h.app, &.{}, Log.onAction, Log.onDestroy, &log, &dup));
        try testing.expectEqual(@as(u32, 3), log.destroys);
        // Left alive: released with the application.
        var open: t.Action = .null;
        try ok(Act.siv_action_create(h.app, &.{ .name = "open", .name_len = 4 }, Log.onAction, Log.onDestroy, &log, &open));

        var inh: t.Inhibition = .null;
        try testing.expectEqual(t.Result.error_invalid_argument, P.siv_inhibit(h.app, h.window, .{}, "x", 1, &inh));
        try ok(P.siv_inhibit(h.app, h.window, .{ .idle = true, .@"suspend" = true }, "Playing", 7, &inh));
        _ = P.siv_inhibition_destroy(inh);
        P.siv_inhibition_destroy(inh);

        // Pending at teardown: only the destroy-notify runs.
        try ok(P.siv_screenshot(h.app, .null, .{}, Log.onResult, Log.onDestroy, &log));
    }
    try testing.expectEqual(@as(u32, 5), log.destroys);
    try testing.expectEqual(@as(u32, 0), log.results);
}

const Launches = struct {
    activations: u32 = 0,
    destroys: u32 = 0,
    kind: t.ActivationType = .open,
    source: t.ActivationSource = .remote,
    uris: usize = 0,
    tokens: u32 = 0,
    token_len: usize = 99,

    fn onActivate(user_data: ?*anyopaque, _: t.App, a: *const t.Activation) callconv(.c) void {
        const l: *Launches = @ptrCast(@alignCast(user_data));
        l.activations += 1;
        l.kind = a.type;
        l.source = a.source;
        l.uris = a.uris_count;
    }

    fn onDestroy(user_data: ?*anyopaque) callconv(.c) void {
        const l: *Launches = @ptrCast(@alignCast(user_data));
        l.destroys += 1;
    }

    fn onToken(user_data: ?*anyopaque, result: *const t.PortalResult) callconv(.c) void {
        const l: *Launches = @ptrCast(@alignCast(user_data));
        l.tokens += 1;
        l.token_len = result.token_len;
    }
};

test "launching without an application id is a primary instance that activates once" {
    var l: Launches = .{};
    {
        var h: harness.Harness = .{};
        try h.start(64, 48, null, null);
        defer h.stop();
        var instance: t.Instance = .pending;
        try ok(P.siv_app_get_instance(h.app, &instance));
        try testing.expectEqual(t.Instance.none, instance);
        const uris = [_]t.Uri{.{ .uri = "file:///a", .uri_len = 9 }};
        try ok(P.siv_app_launch(h.app, &.{ .uris = &uris, .uris_count = 1, .on_activate = Launches.onActivate, .destroy = Launches.onDestroy, .user_data = &l }));
        try ok(P.siv_app_get_instance(h.app, &instance));
        try testing.expectEqual(t.Instance.primary, instance);
        // At the next dispatch, not inside the call.
        try testing.expectEqual(@as(u32, 0), l.activations);
        try dispatch(&h, 2);
        try testing.expectEqual(@as(u32, 1), l.activations);
        try testing.expectEqual(t.ActivationType.open, l.kind);
        try testing.expectEqual(t.ActivationSource.launch, l.source);
        try testing.expectEqual(@as(usize, 1), l.uris);
        var other: Launches = .{};
        try testing.expectEqual(t.Result.error_busy, P.siv_app_launch(h.app, &.{ .on_activate = Launches.onActivate, .destroy = Launches.onDestroy, .user_data = &other }));
        try testing.expectEqual(@as(u32, 1), other.destroys);

        // No input yet: the compositor gives no token. Its answer comes
        // from the compositor thread, so wait for it.
        try ok(P.siv_window_request_activation_token(h.window, Launches.onToken, null, &l));
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        while (l.tokens == 0) {
            if (Loop.now() > deadline) return error.Timeout;
            try ok(A.siv_app_dispatch(h.app, 10));
        }
        try dispatch(&h, 2);
        try testing.expectEqual(@as(u32, 1), l.tokens);
        try testing.expectEqual(@as(usize, 0), l.token_len);
        try ok(P.siv_window_activate(h.window, "some-token", 10));
    }
    try testing.expectEqual(@as(u32, 1), l.destroys);
}

test "tray items need a session bus; handles die with their item" {
    var h: harness.Harness = .{};
    try h.start(64, 48, null, null);
    defer h.stop();
    var item: t.TrayItem = .null;
    try testing.expectEqual(t.Result.error_unavailable, abi.tray.siv_tray_item_create(h.app, &.{ .id = "org.example.Tray", .id_len = 16 }, &item));
    try testing.expectEqual(t.Result.error_unsupported, abi.tray.siv_tray_item_create(h.app, &.{ .category = @enumFromInt(9) }, &item));
    abi.tray.siv_tray_item_destroy(@fromBackingInt(12345));
    try testing.expectEqual(t.Result.error_invalid_handle, abi.tray.siv_tray_item_set_title(.null, "x", 1));
}
