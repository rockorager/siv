//! External content through the public API on the headless backend
//! (D17): submitted frames shown by an external node and released once
//! replaced, and an embedder surface's configure reaching its callback.

const std = @import("std");
const linux = std.os.linux;
const abi = @import("abi");
const harness = @import("harness.zig");
const platform = @import("platform");
const compositor = @import("compositor");
const Loop = @import("loop").Loop;

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
    presented: [4]u64 = undefined,
    presents: usize = 0,
    present_ns: u64 = 0,
    destroyed: u32 = 0,

    fn onEvent(user_data: ?*anyopaque, _: t.External, event: *const t.ExternalEvent) callconv(.c) void {
        const log: *Log = @ptrCast(@alignCast(user_data));
        const e = event;
        switch (e.type) {
            .released => {
                log.released[log.releases] = e.key;
                log.releases += 1;
            },
            .configure => {
                log.configures += 1;
                log.last = e.*;
            },
            .presented => {
                log.presented[log.presents] = e.key;
                log.presents += 1;
                log.present_ns = e.present_ns;
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
    const view = X.siv_external_view(txn, A.siv_window_get_root(h.window), &.{ .external = ext, .content_size = .{ .width = 2, .height = 1 }, .fit = .fill });
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

    // Translucent itself and uncovered, it stays on the subsurface, which
    // the compositor shows at that alpha (alpha-modifier-v1).
    try ok(T.siv_txn_begin(h.window, &txn));
    _ = T.siv_set_visual(txn, A.siv_window_get_root(h.window), &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
    _ = T.siv_set_opacity(txn, view, 0.5);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    const faded = (try h.subsurface()).?;
    try testing.expect(faded.visible);
    try testing.expectEqual(@as(f32, 0.5), faded.alpha);
    // Where the compositor cannot apply alpha, it is composited into the
    // window instead: the left half red and the right half blue over the
    // white background.
    try h.setSubsurfaceFeatures(.{ .alpha = false, .solid = true });
    try ok(T.siv_txn_begin(h.window, &txn));
    _ = T.siv_set_opacity(txn, view, 0.51);
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
    // dma-buf frames: shared memory has no modifier, and a dma-buf at most
    // four planes.
    try testing.expectEqual(t.Result.error_invalid_argument, X.siv_external_submit(ext, &.{ .fd = fd2, .width = 2, .height = 1, .key = 3, .modifier = 1 }));
    const planes: [4]t.ExternalPlane = @splat(.{ .fd = fd2, .offset = 0, .stride = 8 });
    try testing.expectEqual(t.Result.error_invalid_argument, X.siv_external_submit(ext, &.{ .fd = fd2, .width = 2, .height = 1, .key = 3, .memory = .dmabuf, .planes = &planes, .planes_count = 4 }));
    // A linear XRGB8888 dma-buf (a memfd stands in) shows like shared
    // memory on the CPU renderer.
    try ok(X.siv_external_submit(ext, &.{ .fd = fd1, .width = 2, .height = 1, .key = 5, .memory = .dmabuf }));
    waited = 0;
    while (log.releases < 2) : (waited += 1) {
        if (waited > 2000) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 5));
    }
    try testing.expectEqual(2, log.released[1]);
    img = try h.capture();
    const l2 = pixel(img, 100, 10, 20);
    testing.allocator.free(img);
    try testing.expectEqual(l, l2);

    X.siv_external_destroy(ext);
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
    const view = X.siv_external_view(txn, A.siv_window_get_root(h.window), &.{ .external = ext, .fit = .fill });
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
    A.siv_window_destroy(h.window);
    try testing.expectEqual(1, log.destroyed);
    try testing.expectEqual(t.Result.error_invalid_handle, X.siv_external_get_wayland(ext, &display, &surface));
}

test "C API external: a frame slot is configured to its content box and told when each frame shows" {
    var h: Harness = .{};
    try h.start(100, 80, null, null);
    defer h.stop();
    var log: Log = .{};
    var ext: t.External = .null;
    try ok(X.siv_external_create(h.window, &.{ .on_event = Log.onEvent, .user_data = &log }, &ext));
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    // A 2:1 frame contained in an 80x60 box shows 80x40, but the producer
    // is told the box: frames of the box's size fill it.
    const view = X.siv_external_view(txn, A.siv_window_get_root(h.window), &.{ .external = ext, .content_size = .{ .width = 2, .height = 1 }, .fit = .contain });
    _ = T.siv_set_layout(txn, view, &.{ .width = .{ .unit = .px, .value = 80 }, .height = .{ .unit = .px, .value = 60 } });
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    // Before any frame.
    try testing.expectEqual(1, log.configures);
    try testing.expectEqual(t.ExternalEventType.configure, log.last.type);
    try testing.expectEqual(80, log.last.width);
    try testing.expectEqual(60, log.last.height);
    try testing.expectEqual(80, log.last.buffer_width);
    try testing.expectEqual(60, log.last.buffer_height);
    // At 150%, the buffer size is the logical size times the scale.
    const Scale = struct {
        id: platform.WindowId,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            comp.platform.headless.setScale(c.id, .{ .v120 = 180 });
        }
    };
    var sc: Scale = .{ .id = (try h.win()).win.id };
    try (try h.internal()).app.comp.call(&sc, Scale.run);
    try h.settle();
    try testing.expectEqual(2, log.configures);
    try testing.expectEqual(80, log.last.width);
    try testing.expectEqual(120, log.last.buffer_width);
    try testing.expectEqual(90, log.last.buffer_height);
    try testing.expectEqual(@as(f32, 1.5), log.last.scale);

    // Each frame is reported once, when it first shows.
    const blue = [4]u8{ 0xff, 0, 0, 0 };
    const fd = try frameFd(blue, blue);
    defer _ = linux.close(fd);
    try ok(X.siv_external_submit(ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 1 }));
    var waited: usize = 0;
    while (log.presents == 0) : (waited += 1) {
        if (waited > 2000) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 5));
    }
    try h.settle();
    try testing.expectEqual(1, log.presents);
    try testing.expectEqual(1, log.presented[0]);
    try testing.expect(log.present_ns > 0);
    // Not while no node shows the slot: the frame waits until it does.
    try ok(T.siv_txn_begin(h.window, &txn));
    _ = T.siv_set_hidden(txn, view, true);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try ok(X.siv_external_submit(ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 2 }));
    try h.settle();
    try testing.expectEqual(1, log.presents);
    try ok(T.siv_txn_begin(h.window, &txn));
    _ = T.siv_set_hidden(txn, view, false);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(2, log.presents);
    try testing.expectEqual(2, log.presented[1]);
    try testing.expectEqual(2, log.configures);
}

/// What a frame slot was last told about being seen, and the window's
/// states as of its last states_changed.
const Seen = struct {
    visible: ?bool = null,
    changes: usize = 0,
    states: t.WindowStates = .{},
    states_changes: usize = 0,

    fn onEvent(user_data: ?*anyopaque, _: t.External, e: *const t.ExternalEvent) callconv(.c) void {
        const s: *Seen = @ptrCast(@alignCast(user_data));
        switch (e.type) {
            .shown, .hidden => {
                s.visible = e.type == .shown;
                s.changes += 1;
            },
            .states_changed => {
                s.states = e.states;
                s.states_changes += 1;
            },
            else => {},
        }
    }
};

fn waitVisible(h: *Harness, s: *const Seen, want: bool) !void {
    const deadline = Loop.now() + 5 * std.time.ns_per_s;
    while (s.visible != want) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 5));
    }
}

test "C API external: a frame slot is hidden while no node shows it, its window is suspended, or the window does not draw" {
    var h: Harness = .{};
    try h.start(100, 80, null, null);
    defer h.stop();
    var seen: Seen = .{};
    var ext: t.External = .null;
    try ok(X.siv_external_create(h.window, &.{ .on_event = Seen.onEvent, .user_data = &seen }, &ext));
    try h.settle();
    // Hidden until a node shows it; nothing is said before.
    try testing.expect(seen.visible == null);
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const view = X.siv_external_view(txn, A.siv_window_get_root(h.window), &.{ .external = ext });
    _ = T.siv_set_layout(txn, view, &.{ .width = .{ .unit = .px, .value = 80 }, .height = .{ .unit = .px, .value = 60 } });
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try testing.expect(seen.visible == true);
    try testing.expectEqual(1, seen.changes);

    // A hidden node.
    try ok(T.siv_txn_begin(h.window, &txn));
    _ = T.siv_set_hidden(txn, view, true);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try testing.expect(seen.visible == false);
    try ok(T.siv_txn_begin(h.window, &txn));
    _ = T.siv_set_hidden(txn, view, false);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try testing.expect(seen.visible == true);
    try testing.expectEqual(3, seen.changes);

    // A suspended window; its states reach the slot too.
    const states_before = seen.states_changes;
    try ok(abi.testing.siv_test_set_states(h.window, .{ .suspended = true }));
    try waitVisible(&h, &seen, false);
    try testing.expect(seen.states.suspended);
    try ok(abi.testing.siv_test_set_states(h.window, .{ .activated = true }));
    try waitVisible(&h, &seen, true);
    try testing.expect(seen.states.activated and !seen.states.suspended);
    try testing.expectEqual(5, seen.changes);
    try testing.expectEqual(states_before + 2, seen.states_changes);

    // A window the compositor stops drawing (a lock screen, an output
    // turned off) owes a frame for a second: hidden, until it draws again.
    const Occlude = struct {
        id: platform.WindowId,
        on: bool,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            comp.platform.headless.setOccluded(c.id, c.on);
        }
    };
    var occ: Occlude = .{ .id = (try h.win()).win.id, .on = true };
    try (try h.internal()).app.comp.call(&occ, Occlude.run);
    const blue = [4]u8{ 0xff, 0, 0, 0 };
    const fd = try frameFd(blue, blue);
    defer _ = linux.close(fd);
    // The first frame may still show; the next waits for a callback that
    // does not come.
    const before = Loop.now();
    try ok(X.siv_external_submit(ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 1 }));
    const until = Loop.now() + 100 * std.time.ns_per_ms;
    while (Loop.now() < until) try ok(A.siv_app_dispatch(h.app, 10));
    try testing.expect(seen.visible == true);
    try ok(X.siv_external_submit(ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 2 }));
    try waitVisible(&h, &seen, false);
    // A second after the last frame.
    try testing.expect(Loop.now() - before >= std.time.ns_per_s);
    occ.on = false;
    try (try h.internal()).app.comp.call(&occ, Occlude.run);
    try waitVisible(&h, &seen, true);
    try testing.expectEqual(7, seen.changes);
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
        fn onEvent(user_data: ?*anyopaque, _: t.External, event: *const t.ExternalEvent) callconv(.c) void {
            const p: *@This() = @ptrCast(@alignCast(user_data));
            if (event.type == .released) p.ui_releases += 1;
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
    const view = X.siv_external_view(txn, A.siv_window_get_root(h.window), &.{ .external = p.ext, .content_size = .{ .width = 2, .height = 1 }, .fit = .fill });
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
    X.siv_external_destroy(p.ext);
    try testing.expectEqual(t.Result.error_invalid_handle, X.siv_external_submit(p.ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 12 }));
    var waited: usize = 0;
    while (p.destroyed.load(.seq_cst) == 0) : (waited += 1) {
        if (waited > 2000) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 5));
    }
    try testing.expectEqual(11, p.released.load(.seq_cst));
    try testing.expectEqual(11, p.last_key.load(.seq_cst));
}

test "C API external: a background fills the content box, on a solid subsurface while promoted" {
    var h: Harness = .{};
    try h.start(100, 100, null, null);
    defer h.stop();
    var ext: t.External = .null;
    try ok(X.siv_external_create(h.window, null, &ext));
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    _ = T.siv_set_visual(txn, A.siv_window_get_root(h.window), &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
    // A 2:1 frame letterboxed in an 80x80 box: black bars above and below.
    const view = X.siv_external_view(txn, A.siv_window_get_root(h.window), &.{ .external = ext, .content_size = .{ .width = 2, .height = 1 }, .background = .{ .r = 0, .g = 0, .b = 0, .a = 1 } });
    _ = T.siv_set_layout(txn, view, &.{ .width = .{ .unit = .px, .value = 80 }, .height = .{ .unit = .px, .value = 80 } });
    try ok(T.siv_txn_commit(txn));
    const red = [4]u8{ 0, 0, 0xff, 0 };
    const fd = try frameFd(red, red);
    defer _ = linux.close(fd);
    try ok(X.siv_external_submit(ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 1 }));
    try h.settle();
    // Promoted, with the bars on a solid-color subsurface over the whole
    // box: the window paints neither.
    const sub = (try h.subsurface()).?;
    try testing.expectEqual(platform.Rect{ .x = 0, .y = 20, .width = 80, .height = 40 }, sub.rect);
    try testing.expectEqual(platform.Rect{ .x = 0, .y = 0, .width = 80, .height = 80 }, sub.background.?.rect);
    try testing.expectEqual([4]u32{ 0, 0, 0, std.math.maxInt(u32) }, sub.background.?.rgba);
    var img = try h.capture();
    try testing.expectEqual([4]u8{ 0xff, 0xff, 0xff, 0xff }, pixel(img, 100, 40, 5));
    testing.allocator.free(img);
    // Without single-pixel buffers, the window paints the bars.
    try h.setSubsurfaceFeatures(.{ .alpha = true, .solid = false });
    try ok(T.siv_txn_begin(h.window, &txn));
    X.siv_set_external_view(txn, view, &.{ .external = ext, .content_size = .{ .width = 2, .height = 1 }, .background = .{ .r = 0, .g = 0, .b = 0.2, .a = 1 } });
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try testing.expect((try h.subsurface()).?.background == null);
    img = try h.capture();
    const bar = pixel(img, 100, 40, 5);
    testing.allocator.free(img);
    try testing.expect(bar[0] == 0 and bar[1] == 0 and bar[2] > 0x20 and bar[2] < 0x40);
}

test "C API external: a frame with a fence shows once it signals" {
    var h: Harness = .{};
    try h.start(100, 60, null, null);
    defer h.stop();
    var log: Log = .{};
    var ext: t.External = .null;
    try ok(X.siv_external_create(h.window, &.{ .on_event = Log.onEvent, .user_data = &log }, &ext));
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const view = X.siv_external_view(txn, A.siv_window_get_root(h.window), &.{ .external = ext, .content_size = .{ .width = 2, .height = 1 }, .fit = .fill });
    _ = T.siv_set_layout(txn, view, &.{ .width = .{ .unit = .px, .value = 80 }, .height = .{ .unit = .px, .value = 40 } });
    try ok(T.siv_txn_commit(txn));
    // A linear XRGB8888 dma-buf (a memfd maps like one), composited since
    // the headless compositor takes no dma-bufs, behind a fence (a pipe
    // stands in for the sync_file: readable once signaled).
    const blue = [4]u8{ 0xff, 0, 0, 0 };
    const fd = try frameFd(blue, blue);
    defer _ = linux.close(fd);
    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.SkipZigTest;
    defer _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);
    const frame: t.ExternalFrameDesc = .{ .fd = fd, .width = 2, .height = 1, .key = 1, .memory = .dmabuf, .flags = .{ .fence = true }, .fence = pipe[0] };
    try ok(X.siv_external_submit(ext, &frame));
    try h.settle();
    // Captures are RGBA: not blue yet.
    var img = try h.capture();
    try testing.expect(!std.mem.eql(u8, &pixel(img, 100, 20, 20), &.{ 0, 0, 0xff, 0xff }));
    testing.allocator.free(img);
    _ = linux.write(pipe[1], "x", 1);
    var waited: usize = 0;
    while (true) : (waited += 1) {
        try ok(A.siv_app_dispatch(h.app, 5));
        try h.settle();
        img = try h.capture();
        const px = pixel(img, 100, 20, 20);
        testing.allocator.free(img);
        if (std.mem.eql(u8, &px, &.{ 0, 0, 0xff, 0xff })) break;
        if (waited > 200) return error.Timeout;
    }
    // A fence goes only with dma-bufs, and unknown flags are refused.
    try testing.expectEqual(t.Result.error_invalid_argument, X.siv_external_submit(ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 2, .flags = .{ .fence = true }, .fence = pipe[0] }));
    try testing.expectEqual(t.Result.error_invalid_argument, X.siv_external_submit(ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 2, .memory = .dmabuf, .flags = .{ .fence = true }, .fence = -1 }));
    try testing.expectEqual(t.Result.error_unsupported, X.siv_external_submit(ext, &.{ .fd = fd, .width = 2, .height = 1, .key = 2, .flags = @bitCast(@as(u32, 2)) }));
}

test "C API Wayland escape hatch: NULL objects on the headless backend, and commits on request" {
    var h: Harness = .{};
    try h.start(100, 60, null, null);
    defer h.stop();
    var display: ?*anyopaque = @ptrFromInt(8);
    var surface: ?*anyopaque = @ptrFromInt(8);
    var toplevel: ?*anyopaque = @ptrFromInt(8);
    try ok(A.siv_app_get_wayland(h.app, &display));
    try ok(A.siv_window_get_wayland(h.window, &surface, &toplevel));
    try testing.expect(display == null and surface == null and toplevel == null);
    // The toplevel is optional; the surface is not.
    try ok(A.siv_window_get_wayland(h.window, &surface, null));
    try testing.expectEqual(t.Result.error_invalid_argument, A.siv_window_get_wayland(h.window, null, null));
    // A commit with nothing new to show: bare, for state set on the
    // surface to apply.
    try h.settle();
    const Bare = struct {
        id: platform.WindowId,
        count: u64 = 0,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.count = comp.platform.headless.bareCommits(c.id);
        }
        fn read(hh: *Harness) !u64 {
            var c: @This() = .{ .id = (try hh.win()).win.id };
            try (try hh.internal()).app.comp.call(&c, run);
            return c.count;
        }
    };
    const before = try Bare.read(&h);
    try ok(A.siv_window_request_commit(h.window));
    try h.settle();
    try testing.expectEqual(before + 1, try Bare.read(&h));
    // Requested within a refresh of a frame the window presented, the
    // commit waits for the frame callback, and settling waits for it too.
    // It once returned first, so this test failed after any other test in
    // the process (whose warm caches made it fast enough to hit this).
    const Pending = struct {
        id: platform.WindowId,
        waiting: bool = false,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.waiting = comp.platform.headless.frameCallbackPending(c.id);
        }
    };
    var deferred: usize = 0;
    for (0..10) |i| {
        var txn: t.Txn = .null;
        try ok(T.siv_txn_begin(h.window, &txn));
        const v: f32 = if (i % 2 == 0) 1 else 0;
        _ = T.siv_set_visual(txn, A.siv_window_get_root(h.window), &.{ .background = .{ .r = v, .g = v, .b = v, .a = 1 } });
        try ok(T.siv_txn_commit(txn));
        try h.settle();
        const n = try Bare.read(&h);
        try ok(A.siv_window_request_commit(h.window));
        var p: Pending = .{ .id = (try h.win()).win.id };
        try (try h.internal()).app.comp.call(&p, Pending.run);
        if (p.waiting) deferred += 1;
        try h.settle();
        try testing.expectEqual(n + 1, try Bare.read(&h));
    }
    try testing.expect(deferred > 0);
    try testing.expectEqual(t.Result.error_invalid_handle, A.siv_window_request_commit(@fromBackingInt(@backingInt(h.window) ^ 1)));
}
