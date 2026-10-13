//! Pointer cursors through the C API on the headless backend (D16).

const std = @import("std");
const abi = @import("abi");
const platform = @import("platform");
const compositor = @import("compositor");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const T = abi.tree;
const C = abi.cursor;
const Harness = harness.Harness;
const ok = harness.ok;

fn cursorOf(h: *Harness) !platform.CursorShape {
    const Ctx = struct {
        wid: platform.WindowId,
        out: platform.CursorShape = .default,
        fn run(c: ?*anyopaque, comp: *compositor.Compositor) void {
            const s: *@This() = @ptrCast(@alignCast(c));
            s.out = comp.platform.headless.cursorOf(s.wid);
        }
    };
    var c: Ctx = .{ .wid = (try h.win()).win.id };
    try (try h.internal()).app.comp.call(&c, Ctx.run);
    return c.out;
}

test "C API cursors: per node, window override, resize edges" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    const wid = (try h.win()).win.id;
    var txn: t.Txn = undefined;
    try ok(T.siv_txn_begin(h.window, &txn));
    const edge = T.siv_box(txn, abi.application.siv_window_get_root(h.window));
    T.siv_set_layout(txn, edge, &.{ .size = @sizeOf(t.LayoutDesc), .width = .{ .unit = .px, .value = 8 }, .height = .{ .unit = .px, .value = 8 } });
    C.siv_set_cursor(txn, edge, .nwse_resize);
    try ok(T.siv_txn_commit(txn));
    try ok(T.siv_txn_begin(h.window, &txn));
    C.siv_set_cursor(txn, edge, @fromBackingInt(99)); try testing.expectEqual(t.Result.error_unsupported, T.siv_txn_status(txn));
    try testing.expectEqual(t.Result.error_unsupported, T.siv_txn_commit(txn));
    try h.settle();

    try h.inject(&.{.{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 4, .y = 4 } }});
    try h.settle();
    try testing.expectEqual(platform.CursorShape.nwse_resize, try cursorOf(&h));
    try h.inject(&.{.{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 100, .y = 50 } }});
    try h.settle();
    try testing.expectEqual(platform.CursorShape.default, try cursorOf(&h));
    try ok(C.siv_window_set_cursor(h.window, .wait));
    try h.settle();
    try testing.expectEqual(platform.CursorShape.wait, try cursorOf(&h));
    try ok(C.siv_window_set_cursor(h.window, .hidden));
    try h.settle();
    try testing.expectEqual(platform.CursorShape.hidden, try cursorOf(&h));
    try ok(C.siv_window_set_cursor(h.window, .auto));
    try h.settle();
    try testing.expectEqual(platform.CursorShape.default, try cursorOf(&h));

    try testing.expectEqual(t.Result.error_invalid_argument, C.siv_window_begin_resize(h.window, .none));
    try ok(C.siv_window_begin_resize(h.window, .top_left));
    try ok(C.siv_window_begin_move(h.window));
}
