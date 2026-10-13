//! Drag and drop through the C API on the headless backend (D19): a drop
//! target set with siv_set_drop_target receiving another client's drop,
//! and siv_drag_start from a pointer handler, its data split per MIME type
//! and read by another client.

const std = @import("std");
const abi = @import("abi");
const platform = @import("platform");
const compositor = @import("compositor");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const T = abi.tree;
const D = abi.dnd;
const Harness = harness.Harness;
const ok = harness.ok;

const Rec = struct {
    phases: [16]t.PointerPhase = undefined,
    types: [16]t.EventType = undefined,
    n: usize = 0,
    data: [64]u8 = undefined,
    data_len: usize = 0,
    mime: [64]u8 = undefined,
    mime_len: usize = 0,
    action: t.DragAction = .none,
    accepted: bool = false,
    pressed: bool = false,
    start: ?*const t.DragDesc = null,
    start_result: t.Result = .ok,

    fn onEvent(user: ?*anyopaque, node: t.Node, ev: ?*const t.Event) callconv(.c) t.EventResult {
        const r: *Rec = @ptrCast(@alignCast(user));
        const e = ev.?;
        switch (e.type) {
            .drop, .drag => {
                r.phases[r.n] = e.phase;
                r.types[r.n] = e.type;
                r.n += 1;
                r.action = e.action;
                r.accepted = e.flags.accepted;
                if (e.phase == .drop and e.type == .drop) {
                    @memcpy(r.data[0..e.data_count], e.data.?[0..e.data_count]);
                    r.data_len = e.data_count;
                    @memcpy(r.mime[0..e.mime_len], e.mime.?[0..e.mime_len]);
                    r.mime_len = e.mime_len;
                }
                return .handled;
            },
            .pointer => {
                if (e.phase == .down or e.phase == .up or e.phase == .cancel) r.pressed = e.phase == .down;
                if (e.phase == .move and r.pressed) if (r.start) |d| {
                    r.start = null;
                    r.start_result = D.siv_drag_start(node, d);
                };
                return .pass;
            },
            else => return .pass,
        }
    }
};

fn onHeadless(h: *Harness, ctx: anytype, comptime f: fn (*platform.Headless, @TypeOf(ctx)) void) !void {
    const C = struct {
        ctx: @TypeOf(ctx),
        fn run(c: ?*anyopaque, comp: *compositor.Compositor) void {
            const s: *@This() = @ptrCast(@alignCast(c));
            f(comp.platform.headless, s.ctx);
        }
    };
    var c: C = .{ .ctx = ctx };
    try (try h.internal()).app.comp.call(&c, C.run);
}

test "C API drag and drop: drop targets and drags from nodes" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var rec: Rec = .{};
    const wid = (try h.win()).win.id;

    var txn: t.Txn = undefined;
    try ok(T.siv_txn_begin(h.window, &txn));
    const row = T.siv_flex(txn, abi.application.siv_window_root(h.window), null);
    const source = T.siv_box(txn, row);
    const target = T.siv_box(txn, row);
    const size: t.LayoutDesc = .{ .size = @sizeOf(t.LayoutDesc), .width = .{ .unit = .px, .value = 100 }, .height = .{ .unit = .px, .value = 100 } };
    try ok(T.siv_set_layout(txn, source, &size));
    try ok(T.siv_set_layout(txn, target, &size));
    const mimes = "text/uri-list\ntext/plain";
    try ok(D.siv_set_drop_target(txn, target, &.{ .size = @sizeOf(t.DropTargetDesc), .mimes = mimes, .mimes_len = mimes.len, .actions = .{ .copy = true, .move = true }, .preferred = .move }));
    try ok(T.siv_on(txn, target, .drop, Rec.onEvent, null, &rec));
    try ok(T.siv_on(txn, source, .pointer, Rec.onEvent, null, &rec));
    try ok(T.siv_on(txn, source, .drag, Rec.onEvent, null, &rec));
    try ok(T.siv_txn_commit(txn));
    // Invalid MIME types fail the transaction like any operation.
    try ok(T.siv_txn_begin(h.window, &txn));
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_set_drop_target(txn, source, &.{ .size = @sizeOf(t.DropTargetDesc), .mimes = "a b", .mimes_len = 3 }));
    try testing.expectEqual(t.Result.error_invalid_argument, T.siv_txn_commit(txn));
    try h.settle();

    // Another client drops text on the target.
    const In = struct {
        wid: platform.WindowId,
        fn offer(hl: *platform.Headless, s: *const @This()) void {
            hl.offerDrag(0, s.wid, &.{"text/plain"}, "dropped", .{ .copy = true, .move = true }, 150, 50) catch unreachable;
        }
        fn drop(hl: *platform.Headless, _: *const @This()) void {
            hl.dropDrag(0);
        }
    };
    try onHeadless(&h, &In{ .wid = wid }, In.offer);
    try h.settle();
    try onHeadless(&h, &In{ .wid = wid }, In.drop);
    try h.settle();
    // Enter, moves (when the compositor chose the action), and the drop.
    try testing.expect(rec.n >= 2);
    try testing.expectEqual(t.PointerPhase.enter, rec.phases[0]);
    for (rec.phases[1 .. rec.n - 1]) |p| try testing.expectEqual(t.PointerPhase.move, p);
    try testing.expectEqual(t.PointerPhase.drop, rec.phases[rec.n - 1]);
    try testing.expectEqualStrings("dropped", rec.data[0..rec.data_len]);
    try testing.expectEqualStrings("text/plain", rec.mime[0..rec.mime_len]);
    try testing.expectEqual(t.DragAction.move, rec.action);

    // A drag from the source, its data split between two types, dragged
    // out to another client that reads the second.
    try testing.expectEqual(t.Result.error_unavailable, D.siv_drag_start(source, &.{ .size = @sizeOf(t.DragDesc), .mimes = "text/plain", .mimes_len = 10 }));
    const out_mimes = "text/uri-list\ntext/plain";
    const data = "file:///a\r\nA";
    const lengths = [_]usize{ 11, 1 };
    const desc: t.DragDesc = .{ .size = @sizeOf(t.DragDesc), .mimes = out_mimes, .mimes_len = out_mimes.len, .data = data, .data_count = data.len, .lengths = &lengths, .lengths_count = 2, .actions = .{ .copy = true } };
    rec.start = &desc;
    rec.n = 0;
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 20, .y = 20 } },
        .{ .pointer_button = .{ .window = wid, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 5 } },
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 30, .y = 20 } },
    });
    try h.settle();
    try ok(rec.start_result);
    const Out = struct {
        fd: i32 = -1,
        fn run(hl: *platform.Headless, o: *@This()) void {
            hl.leaveDrag(0);
            o.fd = (hl.dropOutside(0, "text/plain", .copy) catch null) orelse -1;
        }
        fn finish(hl: *platform.Headless, _: *@This()) void {
            hl.finishOutside(0, .copy);
        }
    };
    var out: Out = .{};
    try onHeadless(&h, &out, Out.run);
    try testing.expect(out.fd >= 0);
    const linux = std.os.linux;
    const o_nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    _ = linux.fcntl(out.fd, linux.F.SETFL, linux.fcntl(out.fd, linux.F.GETFL, 0) | o_nonblock);
    var got: [16]u8 = undefined;
    var len: usize = 0;
    for (0..5000) |_| {
        try ok(abi.application.siv_app_dispatch(h.app, 2));
        const n = linux.read(out.fd, got[len..].ptr, got.len - len);
        if (linux.errno(n) == .AGAIN) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        len += n;
    }
    _ = std.os.linux.close(out.fd);
    try testing.expectEqualStrings("A", got[0..len]);
    try onHeadless(&h, &out, Out.finish);
    try h.settle();
    try testing.expectEqual(t.EventType.drag, rec.types[rec.n - 1]);
    try testing.expectEqual(t.PointerPhase.end, rec.phases[rec.n - 1]);
    try testing.expectEqual(t.DragAction.copy, rec.action);
}
