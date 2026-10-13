//! The public primitives that code built on siv uses (D22): default
//! handlers, siv_emit, node data, tree navigation, siv_txn_fail, and
//! timers, through the exports on the headless backend. The application
//! allocates through hooks over the testing allocator, so node data that
//! outlives its node shows up as a leak.

const std = @import("std");
const abi = @import("abi");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const ok = harness.ok;
const Harness = harness.Harness;

fn hookAlloc(_: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const a = std.mem.Alignment.fromByteUnits(alignment);
    return testing.allocator.rawAlloc(size, a, @returnAddress());
}

fn hookFree(_: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
    const p: [*]u8 = @ptrCast(ptr.?);
    testing.allocator.rawFree(p[0..size], .fromByteUnits(alignment), @returnAddress());
}

/// A headless application allocating through the testing allocator.
fn start(h: *Harness) !void {
    try ok(c.siv_app_create(&.{
        .backend = .headless,
        .flags = .{ .no_system_fonts = true, .reduced_motion = true },
        .allocator = &.{ .alloc = hookAlloc, .free = hookFree },
    }, &h.app));
    try ok(c.siv_window_create(h.app, &.{ .width = 100, .height = 100 }, &h.window));
}

const Calls = struct {
    order: [8]u8 = undefined,
    n: usize = 0,
    app_returns: bool = false,
    value: f64 = 0,

    fn add(cs: *Calls, tag: u8) void {
        cs.order[cs.n] = tag;
        cs.n += 1;
    }

    fn app(ud: ?*anyopaque, _: t.Node, ev: ?*const t.Event) callconv(.c) t.EventResult {
        const cs: *Calls = @ptrCast(@alignCast(ud.?));
        cs.add('a');
        cs.value = ev.?.value;
        return if (cs.app_returns) .handled else .pass;
    }

    fn default(ud: ?*anyopaque, _: t.Node, ev: ?*const t.Event) callconv(.c) t.EventResult {
        const cs: *Calls = @ptrCast(@alignCast(ud.?));
        cs.add('d');
        cs.value = ev.?.value;
        return .handled;
    }
};

test "default handlers run after the application's, which can override them" {
    var h: Harness = .{};
    try start(&h);
    defer h.stop();
    var calls: Calls = .{};
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const n = c.siv_box(txn, c.siv_window_root(h.window));
    try ok(c.siv_on_default(txn, n, .select, Calls.default, null, &calls));
    try ok(c.siv_txn_commit(txn));

    // Only a default handler: it runs, and takes the event.
    var handled = false;
    try ok(c.siv_emit(n, &.{ .type = .select, .value = 2 }, &handled));
    try testing.expect(handled);
    try testing.expectEqualStrings("d", calls.order[0..calls.n]);

    // The application's handler declines: both run, in that order.
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_on(txn, n, .select, Calls.app, null, &calls));
    try ok(c.siv_txn_commit(txn));
    calls.n = 0;
    try ok(c.siv_emit(n, &.{ .type = .select, .value = 3 }, &handled));
    try testing.expectEqualStrings("ad", calls.order[0..calls.n]);
    try testing.expectEqual(@as(f64, 3), calls.value);

    // It takes the event: the default never runs.
    calls.n = 0;
    calls.app_returns = true;
    try ok(c.siv_emit(n, &.{ .type = .select }, &handled));
    try testing.expectEqualStrings("a", calls.order[0..calls.n]);

    // An aborted transaction restores the previous default handler.
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_on_default(txn, n, .select, null, null, null));
    try ok(c.siv_txn_abort(txn));
    calls.n = 0;
    calls.app_returns = false;
    try ok(c.siv_emit(n, &.{ .type = .select }, &handled));
    try testing.expectEqualStrings("ad", calls.order[0..calls.n]);
    try testing.expectEqual(t.Result.error_unsupported, c.siv_emit(n, &.{ .type = @fromBackingInt(99) }, &handled));
}

test "default handlers make a node activatable for input" {
    var h: Harness = .{};
    try start(&h);
    defer h.stop();
    var calls: Calls = .{};
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const n = c.siv_box(txn, c.siv_window_root(h.window));
    _ = c.siv_set_semantics(txn, n, &.{ .role = .button, .flags = .{ .focusable = true } });
    try ok(c.siv_on_default(txn, n, .activate, Calls.default, null, &calls));
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_focus(n));
    try h.typeKey(0xff0d, "", .{});
    try h.settle();
    try testing.expectEqualStrings("d", calls.order[0..calls.n]);
}

const Keys = struct {
    inner: t.EventResult = .pass,
    root_keys: u32 = 0,
    root_prevented: bool = false,

    fn onInner(ud: ?*anyopaque, _: t.Node, _: ?*const t.Event) callconv(.c) t.EventResult {
        const k: *Keys = @ptrCast(@alignCast(ud.?));
        return k.inner;
    }

    fn onRoot(ud: ?*anyopaque, _: t.Node, ev: ?*const t.Event) callconv(.c) t.EventResult {
        const k: *Keys = @ptrCast(@alignCast(ud.?));
        if (!ev.?.flags.pressed) return .pass;
        k.root_keys += 1;
        k.root_prevented = ev.?.flags.prevented;
        return .pass;
    }
};

test "handlers stop bubbling and prevent the default action separately" {
    var h: Harness = .{};
    try h.start(100, 100, null, null);
    defer h.stop();
    var keys: Keys = .{};
    var txn: t.Txn = .null;
    const root = c.siv_window_root(h.window);
    try ok(c.siv_txn_begin(h.window, &txn));
    const box = c.siv_box(txn, root);
    const editor = c.siv_editor(txn, box, .{});
    try ok(c.siv_on(txn, root, .key, Keys.onRoot, null, &keys));
    try ok(c.siv_on(txn, box, .key, Keys.onInner, null, &keys));
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    var focus: t.Node = .null;
    try ok(c.siv_window_get_focus(h.window, &focus));
    try testing.expectEqual(t.Node.null, focus);
    try ok(c.siv_node_focus(editor));
    try ok(c.siv_window_get_focus(h.window, &focus));
    try testing.expectEqual(editor, focus);

    var buf: [16]u8 = undefined;
    var len: usize = 0;
    // Stop: the root never sees the key, the editor still types it.
    keys.inner = .stop;
    try h.typeKey('a', "a", .{});
    try h.settle();
    try testing.expectEqual(0, keys.root_keys);
    try ok(c.siv_node_get_text(editor, &buf, buf.len, &len));
    try testing.expectEqualStrings("a", buf[0..len]);

    // Prevent: the root sees it marked prevented, the editor does not type.
    keys.inner = .prevent;
    try h.typeKey('b', "b", .{});
    try h.settle();
    try testing.expectEqual(1, keys.root_keys);
    try testing.expect(keys.root_prevented);
    try ok(c.siv_node_get_text(editor, &buf, buf.len, &len));
    try testing.expectEqualStrings("a", buf[0..len]);

    // Pass: both.
    keys.inner = .pass;
    try h.typeKey('c', "c", .{});
    try h.settle();
    try testing.expectEqual(2, keys.root_keys);
    try testing.expect(!keys.root_prevented);
    try ok(c.siv_node_get_text(editor, &buf, buf.len, &len));
    try testing.expectEqualStrings("ac", buf[0..len]);

    // Handled: neither.
    keys.inner = .handled;
    try h.typeKey('d', "d", .{});
    try h.settle();
    try testing.expectEqual(2, keys.root_keys);
    try ok(c.siv_node_get_text(editor, &buf, buf.len, &len));
    try testing.expectEqualStrings("ac", buf[0..len]);
}

test "node data lives with its node and goes with an aborted transaction" {
    var h: Harness = .{};
    try start(&h);
    defer h.stop();
    var key_a: u8 = 0;
    var key_b: u8 = 0;
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const n = c.siv_box(txn, c.siv_window_root(h.window));
    var p: ?*anyopaque = null;
    try ok(c.siv_set_data(txn, n, &key_a, 40, &p));
    const bytes: [*]u8 = @ptrCast(p.?);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(p) % 16);
    for (bytes[0..40]) |b| try testing.expectEqual(@as(u8, 0), b);
    bytes[0] = 7;
    // The same key and size hands back the same memory.
    var q: ?*anyopaque = null;
    try ok(c.siv_set_data(txn, n, &key_a, 40, &q));
    try testing.expectEqual(p, q);
    try ok(c.siv_set_data(txn, n, &key_b, 8, &q));
    try testing.expect(p != q);
    try ok(c.siv_txn_commit(txn));
    try ok(c.siv_node_get_data(n, &key_a, &q));
    try testing.expectEqual(@as(u8, 7), @as([*]u8, @ptrCast(q.?))[0]);
    var none: u8 = 0;
    try ok(c.siv_node_get_data(n, &none, &q));
    try testing.expect(q == null);

    // Data made in an aborted transaction is freed; earlier data stays.
    try ok(c.siv_txn_begin(h.window, &txn));
    var key_c: u8 = 0;
    try ok(c.siv_set_data(txn, n, &key_c, 100, &q));
    try ok(c.siv_txn_abort(txn));
    try ok(c.siv_node_get_data(n, &key_c, &q));
    try testing.expect(q == null);
    try ok(c.siv_node_get_data(n, &key_a, &q));
    try testing.expectEqual(p, q);

    // Another size replaces the memory, keeping the bytes that fit; an
    // abort puts the old memory back.
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_set_data(txn, n, &key_a, 64, &q));
    try testing.expectEqual(@as(u8, 7), @as([*]u8, @ptrCast(q.?))[0]);
    try testing.expectEqual(@as(u8, 0), @as([*]u8, @ptrCast(q.?))[63]);
    try ok(c.siv_txn_abort(txn));
    try ok(c.siv_node_get_data(n, &key_a, &q));
    try testing.expectEqual(p, q);
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_set_data(txn, n, &key_a, 8, &q));
    try ok(c.siv_txn_commit(txn));
    try ok(c.siv_node_get_data(n, &key_a, &q));
    try testing.expectEqual(@as(u8, 7), @as([*]u8, @ptrCast(q.?))[0]);
    // Removing the node frees its data (the testing allocator checks).
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_remove(txn, n));
    try ok(c.siv_txn_commit(txn));
}

test "tree navigation, labels, direction, and failing a transaction" {
    var h: Harness = .{};
    try start(&h);
    defer h.stop();
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_root(h.window);
    const a = c.siv_box(txn, root);
    const b = c.siv_flex(txn, root, null);
    _ = c.siv_set_layout(txn, b, &.{ .direction = .rtl });
    const inner = c.siv_box(txn, b);
    _ = c.siv_set_semantics(txn, inner, &.{ .label = "Inner", .label_len = 5 });
    // Navigation sees the open transaction's tree.
    var r: t.Node = .null;
    try ok(c.siv_node_get_related(a, .next, &r));
    try testing.expectEqual(b, r);
    try ok(c.siv_node_get_related(b, .previous, &r));
    try testing.expectEqual(a, r);
    try ok(c.siv_node_get_related(inner, .parent, &r));
    try testing.expectEqual(b, r);
    try ok(c.siv_node_get_related(root, .last_child, &r));
    try testing.expectEqual(b, r);
    try ok(c.siv_node_get_related(inner, .first_child, &r));
    try testing.expectEqual(t.Node.null, r);
    var rtl = false;
    try ok(c.siv_node_is_rtl(inner, &rtl));
    try testing.expect(rtl);
    try ok(c.siv_node_is_rtl(a, &rtl));
    try testing.expect(!rtl);
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_node_get_label(inner, &buf, 3, &len));
    try testing.expectEqual(@as(usize, 5), len);
    try testing.expectEqualStrings("Inn", buf[0..3]);
    var win: t.Window = .null;
    try ok(c.siv_node_get_window(inner, &win));
    try testing.expectEqual(h.window, win);
    // A failed transaction does nothing more and commits nothing.
    try testing.expectEqual(t.Result.error_unsupported, c.siv_txn_fail(txn, .error_unsupported));
    try testing.expectEqual(t.Node.null, c.siv_box(txn, root));
    try testing.expectEqual(t.Result.error_unsupported, c.siv_txn_fail(txn, .error_busy));
    try testing.expectEqual(t.Result.error_unsupported, c.siv_txn_commit(txn));
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_node_get_related(a, .next, &r));
}

const Ticks = struct {
    fired: u32 = 0,
    destroyed: u32 = 0,

    fn fire(ud: ?*anyopaque) callconv(.c) void {
        const k: *Ticks = @ptrCast(@alignCast(ud.?));
        k.fired += 1;
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const k: *Ticks = @ptrCast(@alignCast(ud.?));
        k.destroyed += 1;
    }
};

test "timers fire once after their delay; cancelled ones never" {
    var h: Harness = .{};
    try start(&h);
    defer h.stop();
    var a: Ticks = .{};
    var b: Ticks = .{};
    var ta: t.Timer = .null;
    var tb: t.Timer = .null;
    const t0 = @import("loop").Loop.now();
    try ok(c.siv_timer_start(h.app, 20, Ticks.fire, Ticks.destroy, &a, &ta));
    try ok(c.siv_timer_start(h.app, 10, Ticks.fire, Ticks.destroy, &b, &tb));
    try ok(c.siv_timer_cancel(tb));
    try testing.expectEqual(@as(u32, 1), b.destroyed);
    while (a.fired == 0) try ok(c.siv_app_dispatch(h.app, 100));
    const elapsed = @import("loop").Loop.now() - t0;
    try testing.expect(elapsed >= 20 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 1), a.destroyed);
    try testing.expectEqual(@as(u32, 0), b.fired);
    // A fired timer's handle is gone.
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_timer_cancel(ta));
    // Destroying the application cancels pending timers.
    var d: Ticks = .{};
    var td: t.Timer = .null;
    try ok(c.siv_timer_start(h.app, 10_000, Ticks.fire, Ticks.destroy, &d, &td));
    h.stop();
    h.app = .null;
    try testing.expectEqual(@as(u32, 1), d.destroyed);
    try testing.expectEqual(@as(u32, 0), d.fired);
}

const Work = struct {
    worker: std.atomic.Value(std.Thread.Id) = .init(0),
    worked: std.atomic.Value(u32) = .init(0),
    started: std.atomic.Value(bool) = .init(false),
    delay_ms: u64 = 0,
    done: u32 = 0,
    done_after_work: bool = false,
    destroyed: u32 = 0,
    destroyed_after_done: bool = false,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const k: *Work = @ptrCast(@alignCast(ud.?));
        k.started.store(true, .release);
        if (k.delay_ms != 0) @import("platform").test_sway.sleepMs(k.delay_ms);
        k.worker.store(std.Thread.getCurrentId(), .release);
        _ = k.worked.fetchAdd(1, .acq_rel);
    }

    fn finish(ud: ?*anyopaque) callconv(.c) void {
        const k: *Work = @ptrCast(@alignCast(ud.?));
        k.done += 1;
        k.done_after_work = k.worked.load(.acquire) == 1;
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const k: *Work = @ptrCast(@alignCast(ud.?));
        k.destroyed += 1;
        k.destroyed_after_done = k.done == 1;
    }
};

test "jobs run on a worker thread, then done and destroy on the application's" {
    var h: Harness = .{};
    try start(&h);
    defer h.stop();
    var jobs: [8]Work = @splat(.{});
    // Half blocking, half compute: both lanes deliver the same way.
    for (&jobs, 0..) |*j, i| try ok(c.siv_job_start(h.app, .{ .compute = i % 2 == 1 }, Work.work, Work.finish, Work.destroy, j));
    // Nothing completes inside the call.
    for (jobs) |j| try testing.expectEqual(@as(u32, 0), j.done);
    const deadline = @import("loop").Loop.now() + 10 * std.time.ns_per_s;
    while (true) {
        var all = true;
        for (jobs) |j| all = all and j.destroyed == 1;
        if (all) break;
        if (@import("loop").Loop.now() > deadline) return error.Timeout;
        try ok(c.siv_app_dispatch(h.app, 10));
    }
    for (jobs) |j| {
        try testing.expect(j.worker.load(.acquire) != std.Thread.getCurrentId());
        try testing.expect(j.done_after_work and j.destroyed_after_done);
    }
    // Without work the call fails and hands user_data back at once.
    var bad: Work = .{};
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_job_start(h.app, .{}, null, Work.finish, Work.destroy, &bad));
    try testing.expectEqual(@as(u32, 1), bad.destroyed);
    try testing.expectEqual(t.Result.error_unsupported, c.siv_job_start(h.app, @bitCast(@as(u32, 0x80)), Work.work, Work.finish, Work.destroy, &bad));
    try testing.expectEqual(@as(u32, 2), bad.destroyed);
    // Destroying the application waits for a running job and runs only
    // its destroy-notify.
    var slow: Work = .{ .delay_ms = 50 };
    try ok(c.siv_job_start(h.app, .{}, Work.work, Work.finish, Work.destroy, &slow));
    while (!slow.started.load(.acquire)) std.atomic.spinLoopHint();
    h.stop();
    h.app = .null;
    try testing.expectEqual(@as(u32, 1), slow.worked.load(.acquire));
    try testing.expectEqual(@as(u32, 0), slow.done);
    try testing.expectEqual(@as(u32, 1), slow.destroyed);
}

const Watcher = struct {
    fd: i32,
    calls: u32 = 0,
    read: u32 = 0,
    last: t.WatchFlags = .{},
    destroyed: u32 = 0,
    stop_on_hangup: bool = true,
    in_callback: bool = false,

    fn ready(ud: ?*anyopaque, watch: t.Watch, events: t.WatchFlags) callconv(.c) void {
        const wt: *Watcher = @ptrCast(@alignCast(ud.?));
        wt.calls += 1;
        wt.last = events;
        var buf: [64]u8 = undefined;
        if (events.readable) {
            const n = std.os.linux.read(wt.fd, &buf, buf.len);
            if (std.os.linux.errno(n) == .SUCCESS) wt.read += @intCast(n);
        }
        if (events.hangup and wt.stop_on_hangup) {
            wt.in_callback = true;
            _ = c.siv_watch_destroy(watch);
            wt.in_callback = false;
        }
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const wt: *Watcher = @ptrCast(@alignCast(ud.?));
        // Never while the callback runs (D2).
        std.debug.assert(!wt.in_callback);
        wt.destroyed += 1;
    }
};

test "watched descriptors call back at safe points until destroyed" {
    var h: Harness = .{};
    try start(&h);
    defer h.stop();
    const linux = std.os.linux;
    var fds: [2]i32 = undefined;
    try testing.expectEqual(@as(usize, 0), linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }));
    defer _ = linux.close(fds[0]);
    var wt: Watcher = .{ .fd = fds[0] };
    var watch: t.Watch = .null;
    try ok(c.siv_app_watch_fd(h.app, fds[0], .{ .readable = true }, Watcher.ready, Watcher.destroy, &wt, &watch));
    // Idle: no calls.
    try ok(c.siv_app_dispatch(h.app, 0));
    try testing.expectEqual(@as(u32, 0), wt.calls);
    // Data: one call per iteration that sees it, which reads it all.
    _ = linux.write(fds[1], "hello", 5);
    try ok(c.siv_app_dispatch(h.app, 100));
    try testing.expectEqual(@as(u32, 1), wt.calls);
    try testing.expect(wt.last.readable and !wt.last.hangup);
    try testing.expectEqual(@as(u32, 5), wt.read);
    // Neither readable nor writable: data waits, unreported.
    try ok(c.siv_watch_set_events(watch, .{}));
    _ = linux.write(fds[1], "x", 1);
    try ok(c.siv_app_dispatch(h.app, 0));
    try testing.expectEqual(@as(u32, 1), wt.calls);
    try ok(c.siv_watch_set_events(watch, .{ .readable = true }));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_watch_set_events(watch, .{ .hangup = true }));
    // Closing the write end hangs up; the callback destroys its own watch,
    // and the destroy-notify runs after it returns.
    _ = linux.close(fds[1]);
    var tries: u32 = 0;
    while (wt.destroyed == 0 and tries < 10) : (tries += 1) try ok(c.siv_app_dispatch(h.app, 100));
    try testing.expectEqual(@as(u32, 1), wt.destroyed);
    try testing.expectEqual(@as(u32, 6), wt.read);
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_watch_destroy(watch));
    // A watch the application never destroys goes with it.
    var other: Watcher = .{ .fd = fds[0], .stop_on_hangup = false };
    try ok(c.siv_app_watch_fd(h.app, fds[0], .{ .readable = true }, Watcher.ready, Watcher.destroy, &other, &watch));
    // A descriptor can be watched once; a bad one fails and hands
    // user_data back.
    var dup: Watcher = .{ .fd = fds[0] };
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_watch_fd(h.app, fds[0], .{ .readable = true }, Watcher.ready, Watcher.destroy, &dup, &watch));
    try testing.expectEqual(@as(u32, 1), dup.destroyed);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_watch_fd(h.app, -1, .{ .readable = true }, Watcher.ready, Watcher.destroy, &dup, &watch));
    try testing.expectEqual(@as(u32, 2), dup.destroyed);
    h.stop();
    h.app = .null;
    try testing.expectEqual(@as(u32, 1), other.destroyed);
}

test "default layouts fill the fields the application's layout leaves zero" {
    var h: Harness = .{};
    try start(&h);
    defer h.stop();
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const col = c.siv_flex(txn, c.siv_window_root(h.window), &.{ .axis = .column, .align_items = .start });
    const n = c.siv_box(txn, col);
    try ok(c.siv_set_default_layout(txn, n, &.{
        .width = .{ .unit = .px, .value = 40 },
        .height = .{ .unit = .px, .value = 30 },
        .padding = .{ .start = 5, .end = 5 },
    }));
    // The application's width wins; its zero height and padding do not.
    try ok(c.siv_set_layout(txn, n, &.{ .width = .{ .unit = .px, .value = 70 }, .padding = .{ .top = 2 } }));
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(n, &r));
    try testing.expectEqual(t.Rect{ .x = 0, .y = 0, .width = 70, .height = 30 }, r);
    const w, const id = try abi.tree.lookup(n);
    const pad = w.uiWin().node(id).layout.padding;
    try testing.expectEqual(@as(f32, 5), pad.start);
    try testing.expectEqual(@as(f32, 2), pad.top);

    // New defaults keep the application's layout; an abort restores both.
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_set_default_layout(txn, n, &.{ .height = .{ .unit = .px, .value = 50 } }));
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_get_rect(n, &r));
    try testing.expectEqual(t.Rect{ .x = 0, .y = 0, .width = 70, .height = 50 }, r);
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_set_layout(txn, n, &.{ .height = .{ .unit = .px, .value = 10 } }));
    try ok(c.siv_set_default_layout(txn, n, null));
    try ok(c.siv_txn_abort(txn));
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_set_layout(txn, n, &.{ .width = .{ .unit = .px, .value = 20 } }));
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_get_rect(n, &r));
    try testing.expectEqual(t.Rect{ .x = 0, .y = 0, .width = 20, .height = 50 }, r);
}

const Frames = struct {
    count: u32 = 0,
    frame: u64 = 0,
    present_ns: u64 = 0,
    commit_ns: u64 = 0,

    fn onEvent(ud: ?*anyopaque, _: t.Window, ev: ?*const t.WindowEvent) callconv(.c) bool {
        const f: *Frames = @ptrCast(@alignCast(ud.?));
        const e = ev.?;
        if (e.type != .presented) return false;
        f.count += 1;
        f.frame = e.frame;
        f.present_ns = e.present_ns;
        f.commit_ns = e.commit_ns;
        return false;
    }
};

test "windows report each presented frame with its times, and nothing while idle" {
    var h: Harness = .{};
    var frames: Frames = .{};
    const Loop = @import("loop").Loop;
    const before = Loop.now();
    try h.start(100, 100, Frames.onEvent, &frames);
    defer h.stop();
    try h.settle();
    try testing.expect(frames.count >= 1);
    try testing.expect(frames.commit_ns >= before and frames.commit_ns <= Loop.now());
    try testing.expect(frames.present_ns >= frames.commit_ns);
    const first = frames.frame;
    // A change: one more frame, a later commit.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_set_visual(txn, c.siv_window_root(h.window), &.{ .background = .{ .r = 1, .a = 1 } });
    try ok(c.siv_txn_commit(txn));
    const n = frames.count;
    try h.settle();
    try testing.expectEqual(n + 1, frames.count);
    try testing.expect(frames.frame > first);
    // Idle: none.
    for (0..5) |_| try ok(c.siv_app_dispatch(h.app, 10));
    try testing.expectEqual(n + 1, frames.count);
}
