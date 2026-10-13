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
