//! Destroying an application through the C API while a window holds an
//! open transaction, with allocator hooks backed by the testing allocator,
//! which fills freed memory and reports leaks.

const std = @import("std");
const abi = @import("abi");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const T = abi.tree;
const ok = harness.ok;

fn alloc(_: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const a = std.mem.Alignment.fromByteUnits(alignment);
    return @ptrCast(testing.allocator.rawAlloc(size, a, @returnAddress()));
}

fn free(_: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
    const p: [*]u8 = @ptrCast(ptr.?);
    testing.allocator.rawFree(p[0..size], .fromByteUnits(alignment), @returnAddress());
}

test "C API: destroying the application while a window's transaction is open" {
    const hooks: t.Allocator = .{ .alloc = alloc, .free = free };
    var app: t.App = .null;
    try ok(A.siv_app_create(&.{ .allocator = &hooks, .backend = .headless, .flags = .{ .no_system_fonts = true, .reduced_motion = true } }, &app));
    // One window has presented, the other never has; both hold a
    // transaction with a new node in it.
    var windows: [2]t.Window = undefined;
    try ok(A.siv_window_create(app, &.{ .width = 64, .height = 48 }, &windows[0]));
    for (0..20) |_| try ok(A.siv_app_dispatch(app, 2));
    try ok(A.siv_window_create(app, &.{ .width = 64, .height = 48 }, &windows[1]));
    for (windows) |w| {
        var txn: t.Txn = undefined;
        try ok(T.siv_txn_begin(w, &txn));
        _ = T.siv_box(txn, A.siv_window_get_root(w));
    }
    A.siv_app_destroy(app);
}

test "C API: destroying a window while its transaction is open" {
    const hooks: t.Allocator = .{ .alloc = alloc, .free = free };
    var app: t.App = .null;
    try ok(A.siv_app_create(&.{ .allocator = &hooks, .backend = .headless, .flags = .{ .no_system_fonts = true, .reduced_motion = true } }, &app));
    defer _ = A.siv_app_destroy(app);
    var w: t.Window = undefined;
    try ok(A.siv_window_create(app, &.{ .width = 64, .height = 48 }, &w));
    var txn: t.Txn = undefined;
    try ok(T.siv_txn_begin(w, &txn));
    _ = T.siv_box(txn, A.siv_window_get_root(w));
    A.siv_window_destroy(w);
    try testing.expectEqual(t.Result.error_invalid_handle, T.siv_txn_status(txn));
}

test "C API: destroying the application from a callback waits for the dispatch to return" {
    const hooks: t.Allocator = .{ .alloc = alloc, .free = free };
    var app: t.App = .null;
    try ok(A.siv_app_create(&.{ .allocator = &hooks, .backend = .headless, .flags = .{ .no_system_fonts = true, .reduced_motion = true } }, &app));
    var window: t.Window = .null;
    try ok(A.siv_window_create(app, &.{ .width = 64, .height = 48 }, &window));
    const S = struct {
        var seen: t.Result = .error_busy;
        fn fire(ud: ?*anyopaque) callconv(.c) void {
            const a: *t.App = @ptrCast(@alignCast(ud.?));
            A.siv_app_destroy(a.*);
            // Still valid until the dispatch running this returns.
            var w: t.Window = .null;
            seen = A.siv_window_create(a.*, null, &w);
        }
    };
    var timer: t.Timer = .null;
    try ok(A.siv_timer_start(app, 0, S.fire, null, &app, &timer));
    // siv_app_run returns at once, and the application is gone after it.
    try ok(A.siv_app_run(app));
    try ok(S.seen);
    try testing.expectEqual(t.Result.error_invalid_handle, A.siv_app_dispatch(app, 0));
    // A second destroy of the stale handle does nothing.
    A.siv_app_destroy(app);
}

/// Allocator hooks that give every block pages of its own and, while
/// armed, take the pages away on free instead of reusing them, so that a
/// read of a freed block faults.
const Guard = struct {
    var armed: std.atomic.Value(bool) = .init(false);
    const hooks: t.Allocator = .{ .alloc = Guard.alloc, .free = Guard.free };

    fn pages(size: usize) usize {
        return std.mem.alignForward(usize, @max(size, 1), std.heap.pageSize());
    }

    fn alloc(_: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        if (alignment > std.heap.pageSize()) return null;
        const m = std.posix.mmap(null, pages(size), .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return null;
        return m.ptr;
    }

    fn free(_: ?*anyopaque, ptr: ?*anyopaque, size: usize, _: usize) callconv(.c) void {
        const p: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(ptr.?));
        const block = p[0..pages(size)];
        if (armed.load(.seq_cst)) {
            _ = std.os.linux.mprotect(block.ptr, block.len, .{});
        } else std.posix.munmap(block);
    }
};

/// Where a window destroys itself: siv has the window in hand around
/// each of these callbacks, and reads it again once they return.
const SelfDestroy = enum { close_requested, presented, emitted, bubbling };

fn destroyFromCallback(comptime how: SelfDestroy) !void {
    const c = abi.testing;
    const S = struct {
        var destroyed: bool = false;
        fn onWindow(_: ?*anyopaque, w: t.Window, ev: ?*const t.WindowEvent) callconv(.c) bool {
            const want: t.WindowEventType = switch (how) {
                .close_requested => .close_requested,
                .presented => .presented,
                else => return false,
            };
            if (ev.?.type != want or destroyed) return false;
            destroyed = true;
            A.siv_window_destroy(w);
            return false;
        }
        fn onNode(_: ?*anyopaque, _: t.Node, ev: ?*const t.Event) callconv(.c) t.EventResult {
            destroyed = true;
            A.siv_window_destroy(ev.?.window);
            // The event goes on: to the node's action, or up the tree.
            return .pass;
        }
        fn onRoot(_: ?*anyopaque, _: t.Node, _: ?*const t.Event) callconv(.c) t.EventResult {
            return .pass;
        }
    };
    S.destroyed = false;
    Guard.armed.store(false, .seq_cst);
    var app: t.App = .null;
    try ok(A.siv_app_create(&.{ .allocator = &Guard.hooks, .backend = .headless, .flags = .{ .no_system_fonts = true, .reduced_motion = true } }, &app));
    defer {
        Guard.armed.store(false, .seq_cst);
        A.siv_app_destroy(app);
    }
    // The first frame is presented while the tree below settles.
    if (how == .presented) Guard.armed.store(true, .seq_cst);
    var window: t.Window = .null;
    try ok(A.siv_window_create(app, &.{ .width = 64, .height = 48, .on_event = S.onWindow }, &window));
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(window, &txn));
    const root = A.siv_window_get_root(window);
    const child = T.siv_box(txn, root);
    _ = T.siv_set_layout(txn, child, &.{ .height = .{ .unit = .px, .value = 30 } });
    switch (how) {
        .emitted => _ = T.siv_on(txn, child, .activate, S.onNode, null, null),
        .bubbling => {
            _ = T.siv_on(txn, child, .pointer, S.onNode, null, null);
            _ = T.siv_on(txn, root, .pointer, S.onRoot, null, null);
        },
        else => {},
    }
    try ok(T.siv_txn_commit(txn));
    var settled = false;
    try ok(c.siv_test_settle(app, 10_000, &settled));
    Guard.armed.store(true, .seq_cst);
    switch (how) {
        .close_requested => try ok(c.siv_test_close(window)),
        .presented => {},
        .emitted => {
            var handled = false;
            try ok(T.siv_node_emit(child, &.{ .type = .activate }, &handled));
        },
        .bubbling => try ok(c.siv_test_click(window, 10, 10, .primary)),
    }
    try ok(c.siv_test_settle(app, 10_000, &settled));
    try testing.expect(S.destroyed);
    try testing.expectEqual(t.Result.error_invalid_handle, T.siv_txn_begin(window, &txn));
}

test "C API: a window destroyed from its close request is not read after it is freed" {
    try destroyFromCallback(.close_requested);
}

test "C API: a window destroyed when it is presented is not read after it is freed" {
    try destroyFromCallback(.presented);
}

test "C API: a window destroyed by an emitted event is not read after it is freed" {
    try destroyFromCallback(.emitted);
}

test "C API: a window destroyed by a bubbling event is not read after it is freed" {
    try destroyFromCallback(.bubbling);
}
