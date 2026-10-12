//! External content through the public API on the headless backend
//! (D17): submitted frames shown by an external node and released once
//! replaced, and an embedder surface's configure reaching its callback.

const std = @import("std");
const linux = std.os.linux;
const abi = @import("abi");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const T = abi.tree;
const X = abi.external;
const Harness = harness.Harness;
const ok = harness.ok;

const Log = struct {
    released: [4]u64 = undefined,
    releases: usize = 0,
    configures: usize = 0,
    last: t.ExternalEvent = .{},
    destroyed: u32 = 0,

    fn onEvent(user_data: ?*anyopaque, _: t.External, event: ?*const t.ExternalEvent) callconv(.c) void {
        const log: *Log = @ptrCast(@alignCast(user_data));
        const e = event.?;
        switch (e.type) {
            .released => {
                log.released[log.releases] = e.key;
                log.releases += 1;
            },
            .configure => {
                log.configures += 1;
                log.last = e.*;
            },
            else => {},
        }
    }

    fn onDestroy(user_data: ?*anyopaque) callconv(.c) void {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.destroyed += 1;
    }
};

/// A memfd holding a 2x1 XRGB frame: `left` and `right` as B, G, R, X.
fn frameFd(left: [4]u8, right: [4]u8) !i32 {
    const rc = linux.memfd_create("siv-test-frame", linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
    const fd: i32 = @intCast(rc);
    const px = left ++ right;
    if (linux.write(fd, &px, px.len) != px.len) return error.WriteFailed;
    return fd;
}

fn pixel(img: []const u8, width: u32, x: u32, y: u32) [4]u8 {
    return img[(y * width + x) * 4 ..][0..4].*;
}

test "C API external: submitted frames show, and replaced ones are released" {
    var h: Harness = .{};
    try h.start(100, 60, null, null);
    defer h.stop();
    var log: Log = .{};
    var ext: t.External = .null;
    try ok(X.siv_external_create(h.window, &.{ .on_event = Log.onEvent, .destroy = Log.onDestroy, .user_data = &log }, &ext));

    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const view = X.siv_external_view(txn, A.siv_window_root(h.window), ext, .{ .width = 2, .height = 1 }, .fill);
    _ = T.siv_set_layout(txn, view, &.{ .width = .{ .unit = .px, .value = 80 }, .height = .{ .unit = .px, .value = 40 } });
    try ok(T.siv_txn_commit(txn));

    // B, G, R, X bytes.
    const red = [4]u8{ 0, 0, 0xff, 0 };
    const blue = [4]u8{ 0xff, 0, 0, 0 };
    const green = [4]u8{ 0, 0xff, 0, 0 };
    const fd1 = try frameFd(red, blue);
    defer _ = linux.close(fd1);
    try ok(X.siv_external_submit(ext, &.{ .fd = fd1, .width = 2, .height = 1, .key = 1 }));
    try h.settle();
    // Nothing covers it: promoted to a subsurface over the node's box.
    const sub = (try h.subsurface()).?;
    try testing.expect(sub.visible);
    try testing.expectEqual(@as(u64, 1), sub.frame.?.key);
    try testing.expectEqual(@as(i32, 80), sub.rect.width);
    try testing.expectEqual(@as(i32, 40), sub.rect.height);

    // Translucent itself, it is composited into the window instead: the
    // left half red and the right half blue over the white background.
    try ok(T.siv_txn_begin(h.window, &txn));
    _ = T.siv_set_visual(txn, A.siv_window_root(h.window), &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
    _ = T.siv_set_opacity(txn, view, 0.5);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    if (try h.subsurface()) |st| try testing.expect(!st.visible);
    var img = try h.capture();
    const l = pixel(img, 100, 10, 20);
    const r = pixel(img, 100, 70, 20);
    testing.allocator.free(img);
    try testing.expect(l[3] == 0xff and l[0] > 0xf0 and l[1] < 0xe0 and l[1] == l[2]);
    try testing.expect(r[3] == 0xff and r[2] > 0xf0 and r[1] < 0xe0 and r[0] == r[1]);

    // A new frame replaces it; the old one comes back by key.
    const fd2 = try frameFd(green, green);
    defer _ = linux.close(fd2);
    try ok(X.siv_external_submit(ext, &.{ .fd = fd2, .width = 2, .height = 1, .key = 2 }));
    // The frame shows on the compositor's own; its release says so.
    var waited: usize = 0;
    while (log.releases == 0) : (waited += 1) {
        if (waited > 2000) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 5));
    }
    img = try h.capture();
    const g = pixel(img, 100, 10, 20);
    testing.allocator.free(img);
    try testing.expect(g[1] > 0xf0 and g[0] < 0xe0 and g[0] == g[2]);
    try testing.expectEqual(1, log.releases);
    try testing.expectEqual(1, log.released[0]);

    // Frames go to frame slots only; bad frames are refused.
    var d: ?*anyopaque = undefined;
    var s: ?*anyopaque = undefined;
    try testing.expectEqual(t.Result.error_invalid_argument, X.siv_external_get_wayland(ext, &d, &s));
    try testing.expectEqual(t.Result.error_invalid_argument, X.siv_external_submit(ext, &.{ .fd = fd2, .width = 0, .height = 1, .key = 3 }));
    try testing.expectEqual(t.Result.error_invalid_argument, X.siv_external_surface_committed(ext, 2, 1));

    try ok(X.siv_external_destroy(ext));
    try testing.expectEqual(1, log.destroyed);
    try testing.expectEqual(t.Result.error_invalid_handle, X.siv_external_submit(ext, &.{ .fd = fd2, .width = 2, .height = 1, .key = 4 }));
    try h.settle();
}

test "C API external: an embedder surface is configured to its node's size" {
    var h: Harness = .{};
    try h.start(100, 60, null, null);
    defer h.stop();
    var log: Log = .{};
    var ext: t.External = .null;
    try ok(X.siv_external_create_surface(h.window, &.{ .on_event = Log.onEvent, .destroy = Log.onDestroy, .user_data = &log }, &ext));
    var display: ?*anyopaque = undefined;
    var surface: ?*anyopaque = undefined;
    try ok(X.siv_external_get_wayland(ext, &display, &surface));
    // No Wayland on the headless backend.
    try testing.expect(display == null and surface == null);

    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const view = X.siv_external_view(txn, A.siv_window_root(h.window), ext, .{ .width = 0, .height = 0 }, .fill);
    _ = T.siv_set_layout(txn, view, &.{ .width = .{ .unit = .px, .value = 60 }, .height = .{ .unit = .px, .value = 30 } });
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try testing.expect(log.configures >= 1);
    try testing.expectEqual(60, log.last.width);
    try testing.expectEqual(30, log.last.height);
    try testing.expectEqual(60, log.last.buffer_width);
    try testing.expectEqual(30, log.last.buffer_height);
    try testing.expectEqual(@as(f32, 1), log.last.scale);
    try ok(X.siv_external_surface_committed(ext, 60, 30));

    // The window takes its slots with it.
    try ok(A.siv_window_destroy(h.window));
    try testing.expectEqual(1, log.destroyed);
    try testing.expectEqual(t.Result.error_invalid_handle, X.siv_external_get_wayland(ext, &display, &surface));
}

test "C API external: a producer thread submits and gets frames back while the UI thread is blocked" {
    var h: Harness = .{};
    try h.start(100, 60, null, null);
    defer h.stop();

    const Producer = struct {
        ext: t.External = .null,
        fd: i32,
        released: std.atomic.Value(u64) = .init(0),
        last_key: std.atomic.Value(u64) = .init(0),
        wrong_thread: std.atomic.Value(bool) = .init(false),
        destroyed: std.atomic.Value(u32) = .init(0),
        /// Releases that came as events on the UI thread instead.
        ui_releases: u32 = 0,
        ui_thread: std.Thread.Id,

        failed: ?anyerror = null,
        fn onEvent(user_data: ?*anyopaque, _: t.External, event: ?*const t.ExternalEvent) callconv(.c) void {
            const p: *@This() = @ptrCast(@alignCast(user_data));
            if (event.?.type == .released) p.ui_releases += 1;
        }

        fn onRelease(user_data: ?*anyopaque, _: t.External, key: u64) callconv(.c) void {
            const p: *@This() = @ptrCast(@alignCast(user_data));
            if (std.Thread.getCurrentId() == p.ui_thread) p.wrong_thread.store(true, .seq_cst);
            _ = p.released.fetchAdd(1, .seq_cst);
            p.last_key.store(key, .seq_cst);
        }

        fn onDestroy(user_data: ?*anyopaque) callconv(.c) void {
            const p: *@This() = @ptrCast(@alignCast(user_data));
            _ = p.destroyed.fetchAdd(1, .seq_cst);
        }

        /// Submits frames 2..11, each after the one before it came back.
        fn run(p: *@This()) void {
            p.produce() catch |err| {
                p.failed = err;
            };
        }

        fn produce(p: *@This()) !void {
            var key: u64 = 2;
            while (key <= 11) : (key += 1) {
                try ok(X.siv_external_submit(p.ext, &.{ .fd = p.fd, .width = 2, .height = 1, .key = key }));
                // Frame key - 1 is released once frame key is on screen.
                const deadline = @import("loop").Loop.now() + 5 * std.time.ns_per_s;
                while (p.released.load(.seq_cst) < key - 1) {
                    if (@import("loop").Loop.now() > deadline) return error.Timeout;
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    const red = [4]u8{ 0, 0, 0xff, 0 };
    const fd = try frameFd(red, red);
    defer _ = linux.close(fd);
    var p: Producer = .{ .fd = fd, .ui_thread = std.Thread.getCurrentId() };
    try ok(X.siv_external_create(h.window, &.{ .on_event = Producer.onEvent, .release = Producer.onRelease, .destroy = Producer.onDestroy, .user_data = &p }, &p.ext));
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const view = X.siv_external_view(txn, A.siv_window_root(h.window), p.ext, .{ .width = 2, .height = 1 }, .fill);
    _ = T.siv_set_layout(txn, view, &.{ .width = .{ .unit = .px, .value = 80 }, .height = .{ .unit = .px, .value = 40 } });
    try ok(T.siv_txn_commit(txn));
    try ok(X.siv_external_submit(p.ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 1 }));
    try h.settle();

    // The UI thread blocks in join, dispatching nothing, while the
    // producer runs ten frames through the compositor.
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&p});
    thread.join();
    if (p.failed) |err| return err;
    try testing.expectEqual(10, p.released.load(.seq_cst));
    try testing.expectEqual(10, p.last_key.load(.seq_cst));
    try testing.expect(!p.wrong_thread.load(.seq_cst));
    try testing.expectEqual(@as(u64, 11), (try h.subsurface()).?.frame.?.key);

    // Releases did not go through the UI thread's events.
    try h.settle();
    try testing.expectEqual(0, p.ui_releases);

    // Destroying the slot: the last frame comes back, then the
    // destroy-notify runs on the application's thread.
    try ok(X.siv_external_destroy(p.ext));
    try testing.expectEqual(t.Result.error_invalid_handle, X.siv_external_submit(p.ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 12 }));
    var waited: usize = 0;
    while (p.destroyed.load(.seq_cst) == 0) : (waited += 1) {
        if (waited > 2000) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 5));
    }
    try testing.expectEqual(11, p.released.load(.seq_cst));
    try testing.expectEqual(11, p.last_key.load(.seq_cst));
}
