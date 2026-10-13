//! Decoding images through the C API on the headless backend (D19):
//! loading from a path and from bytes, sizes, failures, and an animated
//! GIF playing in an image node.

const std = @import("std");
const abi = @import("abi");
const text = @import("text");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const T = abi.tree;
const I = abi.image_load;
const C = abi.canvas;
const Harness = harness.Harness;
const ok = harness.ok;

const Loaded = struct {
    result: ?t.Result = null,
    image: t.Image = .null,
    destroyed: bool = false,

    fn done(user: ?*anyopaque, result: t.Result, image: t.Image) callconv(.c) void {
        const l: *Loaded = @ptrCast(@alignCast(user));
        l.result = result;
        l.image = image;
    }

    fn destroy(user: ?*anyopaque) callconv(.c) void {
        const l: *Loaded = @ptrCast(@alignCast(user));
        l.destroyed = true;
    }
};

fn load(app: t.App, desc: t.ImageLoadDesc) !Loaded {
    var l: Loaded = .{};
    var req: t.ImageRequest = .null;
    try ok(I.siv_image_load(app, &desc, Loaded.done, Loaded.destroy, &l, &req));
    var guard: usize = 0;
    while (!l.destroyed) : (guard += 1) {
        if (guard > 5000) return error.Timeout;
        try ok(A.siv_app_dispatch(app, 2));
    }
    return l;
}

fn pixel(h: *Harness, x: usize, y: usize, width: usize) ![4]u8 {
    const img = try h.capture();
    defer testing.allocator.free(img);
    return img[(y * width + x) * 4 ..][0..4].*;
}

/// Dispatches for `ms` milliseconds.
fn wait(app: t.App, ms: u64) !void {
    const Loop = @import("loop").Loop;
    const end = Loop.now() + ms * std.time.ns_per_ms;
    while (Loop.now() < end) try ok(A.siv_app_dispatch(app, 2));
}

test "C API images: load from a path and from bytes, play an animation" {
    // Without reduced motion, so that the animation plays.
    var h: Harness = .{};
    try ok(A.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true } }, &h.app));
    defer h.stop();
    try ok(A.siv_window_create(h.app, &.{ .width = 64, .height = 64 }, &h.window));

    const path = "src/image/testdata/anim.gif";
    const gif = try load(h.app, .{ .path = path, .path_len = path.len, .scale = 1 });
    try ok(gif.result.?);
    defer _ = C.siv_image_destroy(gif.image);
    var size: t.Size = undefined;
    try ok(I.siv_image_get_size(gif.image, &size));
    try testing.expectEqual(t.Size{ .width = 16, .height = 16 }, size);
    var frames: u32 = 0;
    try ok(I.siv_image_get_frame_count(gif.image, &frames));
    try testing.expectEqual(@as(u32, 3), frames);

    // Bytes, shown within 32 × 32 logical pixels at scale 2: 64 × 48
    // pixels decode to 64 × 48 (no larger than 32 × 2), logically 32 × 24.
    const png = @embedFile("testdata/rgba.png");
    const still = try load(h.app, .{ .data = png, .data_count = png.len, .max_width = 32, .max_height = 32, .scale = 2 });
    try ok(still.result.?);
    try ok(I.siv_image_get_size(still.image, &size));
    try testing.expectEqual(t.Size{ .width = 32, .height = 24 }, size);
    _ = C.siv_image_destroy(still.image);

    // Failures come through the callback.
    const bad = try load(h.app, .{ .data = "nope", .data_count = 4 });
    try testing.expectEqual(t.Result.error_unsupported, bad.result.?);
    try testing.expectEqual(t.Image.null, bad.image);
    const missing = try load(h.app, .{ .path = "/nonexistent.png", .path_len = 16 });
    try testing.expectEqual(t.Result.error_unavailable, missing.result.?);
    var req: t.ImageRequest = .null;
    try testing.expectEqual(t.Result.error_invalid_argument, I.siv_image_load(h.app, &.{}, Loaded.done, null, null, &req));
    // A reserved field must be zero.
    try testing.expectEqual(t.Result.error_unsupported, I.siv_image_load(h.app, &.{ .path = path, .path_len = path.len, .reserved0 = 1 }, Loaded.done, null, null, &req));

    // The animation plays in an image node: red, then green after 100 ms,
    // then blue after 300 ms.
    var txn: t.Txn = undefined;
    try ok(T.siv_txn_begin(h.window, &txn));
    const stack = T.siv_stack(txn, A.siv_window_root(h.window), null);
    _ = C.siv_image_view(txn, stack, &.{ .image = gif.image });
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, try pixel(&h, 5, 5, 64));
    try wait(h.app, 180);
    try h.settle();
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, try pixel(&h, 5, 5, 64));
    try wait(h.app, 200);
    try h.settle();
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, try pixel(&h, 5, 5, 64));
}

const Ordered = struct {
    tag: u8,
    log: *std.ArrayList(u8),
    destroyed: bool = false,

    fn done(user: ?*anyopaque, result: t.Result, image: t.Image) callconv(.c) void {
        const o: *Ordered = @ptrCast(@alignCast(user));
        o.log.append(testing.allocator, o.tag) catch unreachable;
        if (result == .ok) _ = C.siv_image_destroy(image);
    }

    fn destroy(user: ?*anyopaque) callconv(.c) void {
        const o: *Ordered = @ptrCast(@alignCast(user));
        o.destroyed = true;
    }
};

const Gate = struct {
    open: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),

    fn work(user: ?*anyopaque) callconv(.c) void {
        const g: *Gate = @ptrCast(@alignCast(user));
        g.started.store(true, .release);
        while (!g.open.load(.acquire)) std.Thread.yield() catch {};
    }
};

test "C API images: loads wait in priority order, and cancelled ones never call back" {
    var h: Harness = .{};
    try ok(A.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true } }, &h.app));
    defer h.stop();
    // One compute worker, held by a job, so that the loads queue.
    (try A.App.get(@backingInt(h.app))).app.pool.workers.max_threads = 1;
    var gate: Gate = .{};
    try ok(A.siv_job_start(h.app, .{ .compute = true }, Gate.work, null, null, &gate));
    while (!gate.started.load(.acquire)) std.Thread.yield() catch {};
    // A blocking job still runs meanwhile: it has a lane of its own.
    var blocking: Gate = .{};
    blocking.open.store(true, .release);
    try ok(A.siv_job_start(h.app, .{}, Gate.work, null, null, &blocking));
    while (!blocking.started.load(.acquire)) std.Thread.yield() catch {};

    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    const png = @embedFile("testdata/rgba.png");
    var loads = [_]Ordered{ .{ .tag = 'a', .log = &log }, .{ .tag = 'b', .log = &log }, .{ .tag = 'c', .log = &log }, .{ .tag = 'd', .log = &log } };
    const priorities = [_]i32{ 1, 3, 2, 5 };
    var reqs: [4]t.ImageRequest = undefined;
    for (&loads, priorities, &reqs) |*l, p, *r| {
        try ok(I.siv_image_load(h.app, &.{ .data = png, .data_count = png.len, .priority = p }, Ordered.done, Ordered.destroy, l, r));
    }
    try ok(I.siv_image_request_cancel(reqs[3]));
    try testing.expect(loads[3].destroyed);
    try testing.expectEqual(t.Result.error_invalid_handle, I.siv_image_request_cancel(reqs[3]));
    try ok(I.siv_image_request_set_priority(reqs[0], 4));
    gate.open.store(true, .release);
    var guard: usize = 0;
    while (!(loads[0].destroyed and loads[1].destroyed and loads[2].destroyed)) : (guard += 1) {
        if (guard > 5000) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 2));
    }
    try testing.expectEqualStrings("abc", log.items);
    // Handles end with their callback.
    try testing.expectEqual(t.Result.error_invalid_handle, I.siv_image_request_set_priority(reqs[0], 1));
}
