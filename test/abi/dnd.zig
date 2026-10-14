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

    fn onEvent(user: ?*anyopaque, node: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const r: *Rec = @ptrCast(@alignCast(user));
        const e = ev;
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
    const row = T.siv_flex(txn, abi.application.siv_window_get_root(h.window), null);
    const source = T.siv_box(txn, row);
    const target = T.siv_box(txn, row);
    const size: t.LayoutDesc = .{ .size = @sizeOf(t.LayoutDesc), .width = .{ .unit = .px, .value = 100 }, .height = .{ .unit = .px, .value = 100 } };
    T.siv_set_layout(txn, source, &size);
    T.siv_set_layout(txn, target, &size);
    const mimes = "text/uri-list\ntext/plain";
    D.siv_set_drop_target(txn, target, &.{ .size = @sizeOf(t.DropTargetDesc), .mimes = mimes, .mimes_len = mimes.len, .actions = .{ .copy = true, .move = true }, .preferred = .move });
    T.siv_on(txn, target, .drop, Rec.onEvent, null, &rec);
    T.siv_on(txn, source, .pointer, Rec.onEvent, null, &rec);
    T.siv_on(txn, source, .drag, Rec.onEvent, null, &rec);
    try ok(T.siv_txn_commit(txn));
    // Invalid MIME types fail the transaction like any operation.
    try ok(T.siv_txn_begin(h.window, &txn));
    D.siv_set_drop_target(txn, source, &.{ .size = @sizeOf(t.DropTargetDesc), .mimes = "a b", .mimes_len = 3 }); try testing.expectEqual(t.Result.error_invalid_argument, T.siv_txn_status(txn));
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

/// Fills the whole image with one color (user data: *const t.Color).
fn fillDraw(user: ?*anyopaque, node: t.Node, draw: t.Draw, width: f32, height: f32) callconv(.c) void {
    const color: *const t.Color = @ptrCast(@alignCast(user));
    std.debug.assert(node == .null);
    abi.canvas.siv_draw_rect(draw, .{ .x = 0, .y = 0, .width = width, .height = height });
    abi.canvas.siv_draw_fill(draw, &.{ .size = @sizeOf(t.PaintDesc), .color = color.* }, .{});
    // Text draws too (in the window's direction), if not in the test's
    // missing fonts.
    abi.canvas.siv_draw_text(draw, 0, 0, width, "x", 1, null);
}

fn drawnImage(h: *Harness, color: *const t.Color, w: f32, hgt: f32) !t.Image {
    var img: t.Image = .null;
    try ok(abi.canvas.siv_image_draw(h.window, &.{ .size = @sizeOf(t.ImageDrawDesc), .user_data = @constCast(color), .draw = fillDraw, .width = w, .height = hgt }, &img));
    return img;
}

/// The drag icon the compositor shows: its size and its middle pixel.
fn dragIcon(h: *Harness) !struct { u32, u32, [4]u8 } {
    var buf: [64 * 64 * 4]u8 = undefined;
    var len: usize = 0;
    var w: u32 = 0;
    var hh: u32 = 0;
    try ok(abi.testing.siv_test_capture_drag_icon(h.app, &buf, buf.len, &len, &w, &hh));
    const mid = ((hh / 2) * w + w / 2) * 4;
    return .{ w, hh, buf[mid..][0..4].* };
}

const Choose = struct {
    window: t.Window,
    phases: [32]t.PointerPhase = undefined,
    n: usize = 0,
    action: t.DragAction = .none,
    ctrl: bool = false,
    end_action: ?t.DragAction = null,
    pressed: bool = false,
    start: ?*const t.DragDesc = null,
    start_result: t.Result = .ok,

    /// Moves unless Ctrl is held, which copies, as a file manager does.
    fn onEvent(user: ?*anyopaque, node: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const s: *Choose = @ptrCast(@alignCast(user));
        switch (ev.type) {
            .drop => {
                s.phases[s.n] = ev.phase;
                s.n += 1;
                s.action = ev.action;
                s.ctrl = ev.modifiers.ctrl;
                if (ev.phase == .enter or ev.phase == .move) _ = D.siv_drop_set_action(s.window, if (ev.modifiers.ctrl) .copy else .move);
                return .handled;
            },
            .drag => {
                if (ev.phase == .end) s.end_action = ev.action;
                return .handled;
            },
            .pointer => {
                if (ev.phase == .down or ev.phase == .up or ev.phase == .cancel) s.pressed = ev.phase == .down;
                if (ev.phase == .move and s.pressed) if (s.start) |d| {
                    s.start = null;
                    s.start_result = D.siv_drag_start(node, d);
                };
                return .pass;
            },
            else => return .pass,
        }
    }
};

test "C API drag and drop: drawn and replaced icons, the target's action, modifiers, and cancelling" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var s: Choose = .{ .window = h.window };
    const wid = (try h.win()).win.id;
    var txn: t.Txn = undefined;
    try ok(T.siv_txn_begin(h.window, &txn));
    const row = T.siv_flex(txn, abi.application.siv_window_get_root(h.window), null);
    const source = T.siv_box(txn, row);
    const target = T.siv_box(txn, row);
    const size: t.LayoutDesc = .{ .size = @sizeOf(t.LayoutDesc), .width = .{ .unit = .px, .value = 100 }, .height = .{ .unit = .px, .value = 100 } };
    T.siv_set_layout(txn, source, &size);
    T.siv_set_layout(txn, target, &size);
    // The target prefers copy; its handler asks for move instead.
    D.siv_set_drop_target(txn, target, &.{ .size = @sizeOf(t.DropTargetDesc), .mimes = "text/uri-list", .mimes_len = 13, .actions = .{ .copy = true, .move = true }, .preferred = .copy });
    T.siv_on(txn, target, .drop, Choose.onEvent, null, &s);
    T.siv_on(txn, source, .pointer, Choose.onEvent, null, &s);
    T.siv_on(txn, source, .drag, Choose.onEvent, null, &s);
    try ok(T.siv_txn_commit(txn));
    try h.settle();

    // An icon drawn as a canvas draws: its logical size, its pixels.
    const red: t.Color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
    const icon = try drawnImage(&h, &red, 20, 10);
    var isz: t.Size = .{};
    try ok(abi.image_load.siv_image_get_size(icon, &isz));
    try testing.expectEqual(@as(u32, 20), isz.width);
    try testing.expectEqual(@as(u32, 10), isz.height);
    var bad: t.Image = .null;
    try testing.expectEqual(t.Result.error_invalid_argument, abi.canvas.siv_image_draw(h.window, &.{ .size = @sizeOf(t.ImageDrawDesc), .user_data = @constCast(&red), .draw = fillDraw, .width = 0, .height = 10 }, &bad));

    // Dragged with it from the source, over the target.
    const desc: t.DragDesc = .{ .size = @sizeOf(t.DragDesc), .mimes = "text/uri-list", .mimes_len = 13, .data = "file:///a\r\n", .data_count = 11, .icon = icon, .actions = .{ .copy = true, .move = true }, .hotspot_x = 4, .hotspot_y = 5 };
    s.start = &desc;
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 20, .y = 20 } },
        .{ .pointer_button = .{ .window = wid, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 7 } },
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 30, .y = 20 } },
    });
    try h.settle();
    try ok(s.start_result);
    {
        const w, const hh, const px = try dragIcon(&h);
        try testing.expectEqual(@as(u32, 20), w);
        try testing.expectEqual(@as(u32, 10), hh);
        try testing.expect(px[0] > 200 and px[1] < 30 and px[2] < 30 and px[3] == 255);
    }
    try h.inject(&.{.{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 150, .y = 50 } }});
    try h.settle();
    try testing.expectEqual(t.PointerPhase.enter, s.phases[0]);
    // The handler's move, not the target's preferred copy.
    try testing.expectEqual(t.DragAction.move, s.action);
    try testing.expect(!s.ctrl);

    // Ctrl goes down without the pointer moving: the target hears a move
    // with the modifier, and copy is asked for.
    const before = s.n;
    try ok(abi.testing.siv_test_modifiers(h.window, .{ .ctrl = true }));
    try h.settle();
    try testing.expect(s.n > before);
    try testing.expect(s.ctrl);
    try testing.expectEqual(t.DragAction.copy, s.action);

    // The icon is replaced while the drag lasts.
    const blue: t.Color = .{ .r = 0, .g = 0, .b = 1, .a = 1 };
    const icon2 = try drawnImage(&h, &blue, 30, 12);
    try ok(D.siv_drag_set_icon(source, icon2, 0, 0));
    {
        const w, const hh, const px = try dragIcon(&h);
        try testing.expectEqual(@as(u32, 30), w);
        try testing.expectEqual(@as(u32, 12), hh);
        try testing.expect(px[2] > 200 and px[0] < 30);
    }

    // Cancelled: the source hears the end with no action, the target leaves.
    try ok(D.siv_drag_cancel(source));
    try h.settle();
    try testing.expectEqual(@as(?t.DragAction, .none), s.end_action);
    try testing.expectEqual(t.PointerPhase.leave, s.phases[s.n - 1]);
    try testing.expectEqual(t.Result.error_unavailable, D.siv_drag_cancel(source));
    try testing.expectEqual(t.Result.error_unavailable, D.siv_drag_set_icon(source, icon2, 0, 0));
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(t.Result.error_unavailable, abi.testing.siv_test_capture_drag_icon(h.app, &buf, buf.len, &len, null, null));
    abi.canvas.siv_image_destroy(icon);
    abi.canvas.siv_image_destroy(icon2);
}

test "C API drag and drop: a target that replaces the one under a resting drag takes it" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var s: Choose = .{ .window = h.window };
    var b: Choose = .{ .window = h.window };
    const wid = (try h.win()).win.id;
    var txn: t.Txn = undefined;
    try ok(T.siv_txn_begin(h.window, &txn));
    const row = T.siv_flex(txn, abi.application.siv_window_get_root(h.window), null);
    const source = T.siv_box(txn, row);
    const target = T.siv_box(txn, row);
    const size: t.LayoutDesc = .{ .size = @sizeOf(t.LayoutDesc), .width = .{ .unit = .px, .value = 100 }, .height = .{ .unit = .px, .value = 100 } };
    T.siv_set_layout(txn, source, &size);
    T.siv_set_layout(txn, target, &size);
    const drop: t.DropTargetDesc = .{ .size = @sizeOf(t.DropTargetDesc), .mimes = "text/uri-list", .mimes_len = 13, .actions = .{ .copy = true, .move = true }, .preferred = .copy };
    D.siv_set_drop_target(txn, target, &drop);
    T.siv_on(txn, target, .drop, Choose.onEvent, null, &s);
    T.siv_on(txn, source, .pointer, Choose.onEvent, null, &s);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    const desc: t.DragDesc = .{ .size = @sizeOf(t.DragDesc), .mimes = "text/uri-list", .mimes_len = 13, .data = "file:///a\r\n", .data_count = 11, .actions = .{ .copy = true, .move = true } };
    s.start = &desc;
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 20, .y = 20 } },
        .{ .pointer_button = .{ .window = wid, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 9 } },
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 30, .y = 20 } },
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = 150, .y = 50 } },
    });
    try h.settle();
    try testing.expectEqual(t.PointerPhase.enter, s.phases[0]);
    // The target goes and another takes its place, the pointer still: a
    // spring-loaded folder that opened, say.
    try ok(T.siv_txn_begin(h.window, &txn));
    T.siv_remove(txn, target);
    const other = T.siv_box(txn, row);
    T.siv_set_layout(txn, other, &size);
    D.siv_set_drop_target(txn, other, &drop);
    T.siv_on(txn, other, .drop, Choose.onEvent, null, &b);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try testing.expect(b.n >= 1);
    try testing.expectEqual(t.PointerPhase.enter, b.phases[0]);
    // And the release drops there.
    try h.inject(&.{.{ .pointer_button = .{ .window = wid, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 10 } }});
    try h.settle();
    try testing.expectEqual(t.PointerPhase.drop, b.phases[b.n - 1]);
}
