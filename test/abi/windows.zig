//! Window features through the exports on the headless backend (D17):
//! native modal dialogs, window icons, idle inhibition, and session
//! restore.

const std = @import("std");
const abi = @import("abi");
const platform = @import("platform");
const compositor = @import("compositor");
const harness = @import("harness.zig");
const Loop = @import("loop").Loop;

const testing = std.testing;
const t = abi.types;
const c = t.c;
const ok = harness.ok;
const Harness = harness.Harness;

/// Runs `func(headless, args...)` on the compositor thread and returns
/// its result.
fn onHeadless(h: *Harness, comptime func: anytype, args: anytype) !@typeInfo(@TypeOf(func)).@"fn".return_type.? {
    const self = try h.internal();
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

fn idOf(window: t.Window) !platform.WindowId {
    return (try abi.application.App.window(@backingInt(window), abi.application.window_tag)).win.id;
}

const Clicks = struct {
    n: usize = 0,
    fn onActivate(ud: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        const k: *Clicks = @ptrCast(@alignCast(ud.?));
        k.n += 1;
        return .handled;
    }
};

test "native modal dialogs: a parent, input kept from it, destroyed with it" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var clicks: Clicks = .{};
    const root = c.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_on(txn, root, .activate, Clicks.onActivate, null, &clicks);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.click(10, 10);
    try h.settle();
    try testing.expectEqual(@as(usize, 1), clicks.n);

    // A modal child needs a parent.
    var dialog: t.Window = .null;
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_window_create(h.app, &.{ .title = "Bad", .title_len = 3, .flags = .{ .modal = true } }, &dialog));
    try ok(c.siv_window_create(h.app, &.{ .title = "Settings", .title_len = 8, .width = 120, .height = 80, .parent = h.window, .flags = .{ .modal = true } }, &dialog));
    try h.settle();
    const d = try onHeadless(&h, platform.Headless.dialogOf, .{try idOf(dialog)});
    try testing.expectEqual(try idOf(h.window), d.parent.?);
    try testing.expect(d.modal);
    // The parent takes no input while the dialog is shown, keys neither.
    try h.click(10, 10);
    try h.typeKey(' ', " ", .{});
    try h.settle();
    try testing.expectEqual(@as(usize, 1), clicks.n);

    // Without the dialog, input reaches the parent again.
    c.siv_window_destroy(dialog);
    try h.settle();
    try h.click(10, 10);
    try h.settle();
    try testing.expectEqual(@as(usize, 2), clicks.n);

    // A dialog goes with its parent.
    try ok(c.siv_window_create(h.app, &.{ .parent = h.window }, &dialog));
    try h.settle();
    c.siv_window_destroy(h.window);
    try testing.expect(c.siv_window_get_app(dialog) == .null);
}

test "window icons: a themed name drawn at the compositor's sizes, and images" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    const id = try idOf(h.window);
    try ok(c.siv_window_set_icon(h.window, "siv-test-app", 12, .null));
    // The name goes at once; the images drawn from the theme follow.
    var icon = (try onHeadless(&h, platform.Headless.iconOf, .{id})).?;
    try testing.expectEqualStrings("siv-test-app", icon.name);
    const deadline = Loop.now() + 5 * std.time.ns_per_s;
    while (icon.sizes.len == 0) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(c.siv_app_dispatch(h.app, 5));
        icon = (try onHeadless(&h, platform.Headless.iconOf, .{id})).?;
    }
    try testing.expectEqualStrings("siv-test-app", icon.name);
    try testing.expectEqualSlices(u32, &.{ 32, 64 }, icon.sizes);

    // A raster image goes once, at its own size, made square.
    var img: t.Image = .null;
    var px: [24]u8 = undefined;
    for (0..6) |i| px[i * 4 ..][0..4].* = .{ 0xff, 0, 0, 0xff };
    try ok(c.siv_image_create(h.app, &.{ .width = 3, .height = 2, .stride = 12, .format = .rgba8, .pixels = &px, .pixels_count = px.len }, &img));
    defer _ = c.siv_image_destroy(img);
    try ok(c.siv_window_set_icon(h.window, "", 0, img));
    icon = (try onHeadless(&h, platform.Headless.iconOf, .{id})).?;
    try testing.expectEqualStrings("", icon.name);
    try testing.expectEqualSlices(u32, &.{3}, icon.sizes);

    // Nothing resets it.
    try ok(c.siv_window_set_icon(h.window, "", 0, .null));
    try testing.expect(try onHeadless(&h, platform.Headless.iconOf, .{id}) == null);
}

test "idle inhibition for a window goes through the compositor; other inhibitions do not" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    const id = try idOf(h.window);
    var a: t.Inhibition = .null;
    var b: t.Inhibition = .null;
    try ok(c.siv_inhibit(h.app, h.window, .{ .idle = true }, "Video", 5, &a));
    try ok(c.siv_inhibit(h.app, h.window, .{ .idle = true }, "Slides", 6, &b));
    try testing.expect(try onHeadless(&h, platform.Headless.idleInhibited, .{id}));
    c.siv_inhibition_destroy(a);
    try testing.expect(try onHeadless(&h, platform.Headless.idleInhibited, .{id}));
    c.siv_inhibition_destroy(b);
    try testing.expect(!try onHeadless(&h, platform.Headless.idleInhibited, .{id}));
    // Suspending, or idling without a window, is the portal's (none here).
    try ok(c.siv_inhibit(h.app, h.window, .{ .idle = true, .@"suspend" = true }, "Burning", 7, &a));
    try ok(c.siv_inhibit(h.app, .null, .{ .idle = true }, "Music", 5, &b));
    try testing.expect(!try onHeadless(&h, platform.Headless.idleInhibited, .{id}));
    c.siv_inhibition_destroy(a);
    c.siv_inhibition_destroy(b);
    // An inhibition outliving its window ends with it.
    var dialog: t.Window = .null;
    try ok(c.siv_window_create(h.app, &.{}, &dialog));
    try ok(c.siv_inhibit(h.app, dialog, .{ .idle = true }, "Video", 5, &a));
    c.siv_window_destroy(dialog);
    c.siv_inhibition_destroy(a);
}

const Session = struct {
    events: [4]t.SessionEventType = undefined,
    n: usize = 0,
    id: [64]u8 = undefined,
    id_len: usize = 0,
    restored: usize = 0,

    fn onSession(ud: ?*anyopaque, ev: *const t.SessionEvent) callconv(.c) void {
        const s: *Session = @ptrCast(@alignCast(ud.?));
        const e = ev;
        s.events[s.n] = e.type;
        s.n += 1;
        if (e.type == .created) {
            @memcpy(s.id[0..e.session_id_len], e.session_id.?[0..e.session_id_len]);
            s.id_len = e.session_id_len;
        }
    }

    fn onWindow(ud: ?*anyopaque, _: t.Window, ev: *const t.WindowEvent) callconv(.c) bool {
        const s: *Session = @ptrCast(@alignCast(ud.?));
        if (ev.type == .restored) s.restored += 1;
        return false;
    }
};

fn waitSession(h: *Harness, s: *Session, n: usize) !void {
    const deadline = Loop.now() + 5 * std.time.ns_per_s;
    while (s.n < n) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(c.siv_app_dispatch(h.app, 5));
    }
}

test "session restore: a new session's id brings its windows back in the next run" {
    var first: Session = .{};
    {
        var h: Harness = .{};
        try h.start(200, 100, null, null);
        defer h.stop();
        try ok(c.siv_app_start_session(h.app, "", 0, .launch, Session.onSession, null, &first));
        try waitSession(&h, &first, 1);
        try testing.expectEqual(t.SessionEventType.created, first.events[0]);
        try testing.expect(first.id_len > 0);
        var main: t.Window = .null;
        try ok(c.siv_window_create(h.app, &.{ .session_name = "main", .session_name_len = 4, .on_event = Session.onWindow, .user_data = &first }, &main));
        try h.settle();
        try testing.expectEqual(@as(usize, 0), first.restored);
    }
    var second: Session = .{};
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    try ok(c.siv_app_start_session(h.app, &first.id, first.id_len, .launch, Session.onSession, null, &second));
    try waitSession(&h, &second, 1);
    try testing.expectEqual(t.SessionEventType.restored, second.events[0]);
    // The window the session knows is restored; a new one is not.
    var main: t.Window = .null;
    var other: t.Window = .null;
    try ok(c.siv_window_create(h.app, &.{ .session_name = "main", .session_name_len = 4, .on_event = Session.onWindow, .user_data = &second }, &main));
    try ok(c.siv_window_create(h.app, &.{ .session_name = "other", .session_name_len = 5, .on_event = Session.onWindow, .user_data = &second }, &other));
    try h.settle();
    try testing.expectEqual(@as(usize, 1), second.restored);
    // Removed, the session is forgotten: its id starts a new one.
    c.siv_app_remove_session(h.app);
    var third: Session = .{};
    try ok(c.siv_app_start_session(h.app, &first.id, first.id_len, .launch, Session.onSession, null, &third));
    try waitSession(&h, &third, 1);
    try testing.expectEqual(t.SessionEventType.created, third.events[0]);
}

const Sizes = struct {
    resized: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    fn onEvent(ud: ?*anyopaque, _: t.Window, e: *const t.WindowEvent) callconv(.c) bool {
        const self: *Sizes = @ptrCast(@alignCast(ud.?));
        if (e.type == .resized) {
            self.resized += 1;
            self.width = e.width;
            self.height = e.height;
        }
        return false;
    }
};

test "siv_test_resize: the compositor resizes a window, which lays out again" {
    var sizes: Sizes = .{};
    var h: Harness = .{};
    try h.start(200, 100, Sizes.onEvent, &sizes);
    defer h.stop();
    // A box that fills the window, then lays out at the new size.
    const root = c.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const box = c.siv_box(txn, root);
    c.siv_set_layout(txn, box, &.{ .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    const before = sizes.resized;

    try ok(c.siv_test_resize(h.window, 320, 90));
    try h.settle();
    try testing.expectEqual(before + 1, sizes.resized);
    try testing.expectEqual(@as(u32, 320), sizes.width);
    try testing.expectEqual(@as(u32, 90), sizes.height);
    var size: t.Size = .{};
    try ok(c.siv_window_get_size(h.window, &size));
    try testing.expectEqual(@as(f32, 320), size.width);
    var rect: t.Rect = .{};
    try ok(c.siv_node_get_rect(box, &rect));
    try testing.expectEqual(@as(f32, 320), rect.width);
    try testing.expectEqual(@as(f32, 90), rect.height);

    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_test_resize(h.window, 0, 90));
}
