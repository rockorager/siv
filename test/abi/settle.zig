//! siv_test_settle (D27): it returns once nothing is in flight, whatever
//! the frame timing, rather than after a stretch of quiet dispatches.

const std = @import("std");
const abi = @import("abi");
const compositor = @import("compositor");
const Loop = @import("loop").Loop;
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const T = abi.tree;
const X = abi.testing;
const Harness = harness.Harness;
const ok = harness.ok;

fn px(v: f32) t.Dimension {
    return .{ .unit = .px, .value = v };
}

const red: t.Color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
const blue: t.Color = .{ .r = 0, .g = 0, .b = 1, .a = 1 };

fn settle(h: *Harness) !void {
    var settled = false;
    try ok(X.siv_test_settle(h.app, 5000, &settled));
    try testing.expect(settled);
}

fn capture(h: *Harness, buf: []u8) !void {
    var len: usize = 0;
    try ok(X.siv_test_capture(h.window, buf.ptr, buf.len, &len, null, null));
    try testing.expectEqual(buf.len, len);
}

fn pixel(img: []const u8, x: usize, y: usize) [4]u8 {
    return img[(y * 120 + x) * 4 ..][0..4].*;
}

test "siv_test_settle waits for the frame a compositor-side scroll owes, however late it lands" {
    var h: Harness = .{};
    try h.start(120, 80, null, null);
    defer h.stop();
    const root = A.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const column = T.siv_flex(txn, root, &.{ .axis = .column });
    const sc = T.siv_scroll(txn, column, .vertical);
    _ = T.siv_set_layout(txn, sc, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(120), .height = px(60) });
    const rows = T.siv_flex(txn, sc, &.{ .axis = .column });
    // Rows of 40 px, red and blue in turn.
    for (0..10) |i| {
        const row = T.siv_box(txn, rows);
        _ = T.siv_set_layout(txn, row, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(120), .height = px(40) });
        _ = T.siv_set_visual(txn, row, &.{ .background = if (i % 2 == 0) red else blue });
    }
    const flag = T.siv_box(txn, column);
    _ = T.siv_set_layout(txn, flag, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(120), .height = px(20) });
    _ = T.siv_set_visual(txn, flag, &.{ .background = red });
    try ok(T.siv_txn_commit(txn));
    try settle(&h);

    // A refresh of 300 ms from now on: a frame asked for just after one
    // was presented lands at the next vblank, long after several quiet
    // dispatches.
    const self = try h.internal();
    const Slow = struct {
        fn run(_: ?*anyopaque, comp: *compositor.Compositor) void {
            const hl = comp.platform.headless;
            hl.refresh_ns = 300 * std.time.ns_per_ms;
            hl.epoch_ns = Loop.now();
        }
    };
    try self.app.comp.call(null, Slow.run);
    try ok(X.siv_test_pointer_move(h.window, 60, 30));
    try settle(&h);

    var before: [120 * 80 * 4]u8 = undefined;
    try capture(&h, &before);
    try testing.expectEqual(@as(u8, 255), pixel(&before, 60, 20)[0]);

    // Present a frame (the flag turns blue), then scroll while its vblank
    // is still ahead: the compositor scrolls at once but presents at the
    // vblank.
    try ok(T.siv_txn_begin(h.window, &txn));
    _ = T.siv_set_visual(txn, flag, &.{ .background = blue });
    try ok(T.siv_txn_commit(txn));
    const w = try h.win();
    while (!(w.win.settled() and w.win.presented_seq >= w.win.committed_seq)) try ok(A.siv_app_dispatch(h.app, 1));
    const t0 = Loop.now();
    try ok(X.siv_test_scroll(h.window, 0, 30));
    try settle(&h);
    const waited = Loop.now() - t0;

    var after: [120 * 80 * 4]u8 = undefined;
    try capture(&h, &after);
    // Row 1 (blue) is at y = 20 now, and the flag is blue.
    try testing.expectEqual(@as(u8, 255), pixel(&after, 60, 20)[2]);
    try testing.expectEqual(@as(u8, 255), pixel(&after, 60, 70)[2]);
    // Nothing more lands later.
    const end = Loop.now() + 400 * std.time.ns_per_ms;
    while (Loop.now() < end) try ok(A.siv_app_dispatch(h.app, 50));
    var later: [120 * 80 * 4]u8 = undefined;
    try capture(&h, &later);
    try testing.expectEqualSlices(u8, &after, &later);
    // The scroll's frame waited for the vblank, so settling took longer
    // than the old rule's three quiet dispatches of 2 ms.
    try testing.expect(waited > 20 * std.time.ns_per_ms);
}
