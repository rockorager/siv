//! Input devices through the exports on the headless backend (D16):
//! touchpad gestures and zoomable scroll nodes, and mouse side buttons.

const std = @import("std");
const abi = @import("abi");
const platform = @import("platform");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const ok = harness.ok;
const Harness = harness.Harness;

fn px(v: f32) t.Dimension {
    return .{ .unit = .px, .value = v };
}

const Log = struct {
    gestures: [16]t.Event = undefined,
    n: usize = 0,
    zoom: f32 = 0,
    result: t.EventResult = .pass,

    fn onGesture(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const l: *Log = @ptrCast(@alignCast(ud.?));
        l.gestures[l.n] = ev.*;
        l.n += 1;
        return l.result;
    }

    fn onViewport(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const l: *Log = @ptrCast(@alignCast(ud.?));
        l.zoom = ev.zoom;
        return .handled;
    }
};

test "gestures reach handlers; pinches zoom scroll nodes on the compositor or through the UI" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var log: Log = .{};
    var view: Log = .{};
    const root = c.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const sc = c.siv_scroll(txn, root, .both);
    c.siv_set_layout(txn, sc, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(200), .height = px(100) });
    c.siv_set_scroll_zoom_range(txn, sc, 1, 4);
    c.siv_on(txn, sc, .viewport, Log.onViewport, null, &view);
    const content = c.siv_stack(txn, sc, null);
    c.siv_set_layout(txn, content, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(400), .height = px(400) });
    // A knob at (100, 0) in the content that takes gestures itself.
    const knob = c.siv_box(txn, content);
    c.siv_set_layout(txn, knob, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(50), .height = px(50), .inset_start = 100, .inset_top = 0, .flags = .{ .inset_start = true, .inset_top = true } });
    c.siv_on(txn, knob, .gesture, Log.onGesture, null, &log);
    c.siv_on(txn, root, .gesture, Log.onGesture, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(@as(f32, 1), view.zoom);
    const id = (try h.win()).win.id;

    // Over plain content the compositor zooms by itself, about the
    // pointer; no handler sees the pinch.
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = id, .seat = 0, .x = 20, .y = 20 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .begin, .fingers = 2 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .update, .fingers = 2, .scale = 2 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .end, .fingers = 2 } },
    });
    // The compositor reports the zoom with its next frame.
    const deadline = @import("loop").Loop.now() + 5 * std.time.ns_per_s;
    while (view.zoom != 2) {
        if (@import("loop").Loop.now() > deadline) return error.Timeout;
        try ok(c.siv_app_dispatch(h.app, 5));
    }
    try h.settle();
    try testing.expectEqual(@as(usize, 0), log.n);

    // Back at zoom 1, a pinch over the knob goes to its handler, bubbles
    // to the root's, and then zooms through the UI.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_scroll_zoom_to(txn, sc, 1);
    c.siv_scroll_to(txn, sc, 0, 0);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(@as(f32, 1), view.zoom);
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = id, .seat = 0, .x = 110, .y = 10 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .begin, .fingers = 2 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .update, .fingers = 2, .scale = 1.5, .rotation = -2, .dx = 1 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .end, .fingers = 2 } },
    });
    try h.settle();
    try testing.expectEqual(@as(usize, 6), log.n);
    const update = log.gestures[2];
    try testing.expectEqual(t.EventType.gesture, update.type);
    try testing.expectEqual(t.Gesture.pinch, update.gesture);
    try testing.expectEqual(t.PointerPhase.move, update.phase);
    try testing.expectEqual(knob, update.target);
    try testing.expectEqual(@as(u32, 2), update.count);
    try testing.expectEqual(@as(f32, 10), update.x);
    try testing.expectEqual(@as(f32, 1.5), update.scale);
    try testing.expectEqual(@as(f32, -2), update.rotation);
    try testing.expectEqual(@as(f32, 1), update.dx);
    try testing.expectEqual(t.PointerPhase.begin, log.gestures[0].phase);
    try testing.expectEqual(t.PointerPhase.end, log.gestures[4].phase);
    // The root saw the same event, in its own coordinates.
    try testing.expectEqual(@as(f32, 110), log.gestures[3].x);
    try testing.expectEqual(@as(f32, 1.5), view.zoom);

    // Swipes always reach the UI; a cancelled one ends with cancel.
    log.n = 0;
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = id, .seat = 0, .x = 20, .y = 20 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .swipe, .phase = .begin, .fingers = 3 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .swipe, .phase = .update, .fingers = 3, .dx = 30, .dy = -4 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .swipe, .phase = .end, .fingers = 3, .cancelled = true } },
    });
    try h.settle();
    try testing.expectEqual(@as(usize, 3), log.n);
    try testing.expectEqual(t.Gesture.swipe, log.gestures[1].gesture);
    try testing.expectEqual(@as(u32, 3), log.gestures[1].count);
    try testing.expectEqual(@as(f32, 30), log.gestures[1].dx);
    try testing.expectEqual(t.PointerPhase.cancel, log.gestures[2].phase);
    try testing.expectEqual(content, log.gestures[2].target);
}

const Pen = struct {
    events: [16]t.Event = undefined,
    samples: [16][8]t.TabletSample = undefined,
    n: usize = 0,
    pads: [4]t.Event = undefined,
    pad_n: usize = 0,

    fn onTablet(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const p: *Pen = @ptrCast(@alignCast(ud.?));
        const e = ev;
        p.events[p.n] = e.*;
        @memcpy(p.samples[p.n][0..e.samples_count], e.samples.?[0..e.samples_count]);
        p.n += 1;
        return .handled;
    }

    fn onPad(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const p: *Pen = @ptrCast(@alignCast(ud.?));
        p.pads[p.pad_n] = ev.*;
        p.pad_n += 1;
        return .handled;
    }
};

test "tablet tools and pads reach handlers with every sample, in node coordinates" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var pen: Pen = .{};
    const root = c.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const row = c.siv_flex(txn, root, null);
    const spacer = c.siv_box(txn, row);
    c.siv_set_layout(txn, spacer, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(40), .height = px(10) });
    const canvas = c.siv_box(txn, row);
    c.siv_set_layout(txn, canvas, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(100), .height = px(100) });
    c.siv_on(txn, canvas, .tablet, Pen.onTablet, null, &pen);
    c.siv_on(txn, root, .pad, Pen.onPad, null, &pen);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    const id = (try h.win()).win.id;

    const base: platform.TabletTool = .{ .window = id, .seat = 0, .tool = 2, .kind = .airbrush, .axes = .{ .pressure = true, .slider = true }, .serial_number = 77, .phase = .motion };
    var events: [8]platform.Event = undefined;
    for (&events, 0..) |*e, i| {
        var s = base;
        s.phase = if (i == 0) .proximity_in else if (i == 1) .down else .motion;
        s.x = 50 + @as(f64, @floatFromInt(i));
        s.y = 30;
        s.pressure = @as(f64, @floatFromInt(i)) / 10;
        s.slider = -0.5;
        s.wheel = if (i >= 2) 1.5 else 0;
        s.tip = i >= 1;
        s.time = @intCast(1000 + i);
        e.* = .{ .tablet_tool = s };
    }
    try h.inject(&events);
    try h.settle();
    // Enter, down, then one move with the six motions.
    try testing.expectEqual(@as(usize, 3), pen.n);
    try testing.expectEqual(t.PointerPhase.enter, pen.events[0].phase);
    try testing.expectEqual(t.PointerPhase.down, pen.events[1].phase);
    try testing.expectEqual(t.PointerButton.primary, pen.events[1].button);
    const move = pen.events[2];
    try testing.expectEqual(t.EventType.tablet, move.type);
    try testing.expectEqual(t.PointerPhase.move, move.phase);
    try testing.expectEqual(t.TabletTool.airbrush, move.tool);
    try testing.expectEqual(@as(u32, 2), move.tool_id);
    try testing.expectEqual(@as(u64, 77), move.tool_serial);
    try testing.expect(move.axes.pressure and move.axes.slider and !move.axes.tilt);
    try testing.expect(move.flags.tip);
    try testing.expectEqual(@as(usize, 6), move.samples_count);
    // Node coordinates: the canvas starts at x 40.
    try testing.expectEqual(@as(f32, 12), pen.samples[2][0].x);
    try testing.expectEqual(@as(f32, 17), pen.samples[2][5].x);
    try testing.expectEqual(@as(f32, 17), move.x);
    try testing.expectEqual(@as(f32, 30), move.y);
    try testing.expectApproxEqAbs(@as(f32, 0.7), move.pressure, 1e-6);
    try testing.expectEqual(@as(f32, -0.5), move.slider);
    try testing.expectEqual(@as(u32, 1002), pen.samples[2][0].time);
    // Each sample has its wheel turn, the event their sum.
    try testing.expectEqual(@as(f32, 1.5), pen.samples[2][3].wheel);
    try testing.expectEqual(@as(f32, 9), move.wheel);
    try testing.expectEqual(@as(u32, 0), pen.samples[2][5].reserved3);

    // A stylus button is a secondary press; pads go from focus (none: the
    // root).
    var button = base;
    button.phase = .button;
    button.button = 0x14b;
    button.pressed = true;
    button.x = 60;
    try h.inject(&.{
        .{ .tablet_tool = button },
        .{ .tablet_pad = .{ .window = id, .seat = 0, .pad = 0, .control = .dial, .index = 0, .group = 1, .mode = 3, .value = -1.5 } },
        .{ .tablet_pad = .{ .window = id, .seat = 0, .pad = 0, .control = .button, .index = 4, .pressed = true } },
    });
    try h.settle();
    try testing.expectEqual(@as(usize, 4), pen.n);
    try testing.expectEqual(t.PointerPhase.down, pen.events[3].phase);
    try testing.expectEqual(t.PointerButton.secondary, pen.events[3].button);
    try testing.expectEqual(@as(usize, 2), pen.pad_n);
    try testing.expectEqual(t.EventType.pad, pen.pads[0].type);
    try testing.expectEqual(t.PadControl.dial, pen.pads[0].pad_control);
    try testing.expectEqual(@as(f64, -1.5), pen.pads[0].value);
    try testing.expectEqual(@as(u32, 1), pen.pads[0].group);
    try testing.expectEqual(@as(u32, 3), pen.pads[0].mode);
    try testing.expectEqual(@as(u32, 4), pen.pads[1].index);
    try testing.expect(pen.pads[1].flags.pressed);
}

const Lock = struct {
    window_events: [8]t.WindowEventType = undefined,
    wn: usize = 0,
    moves: [8]t.Event = undefined,
    n: usize = 0,

    fn onWindow(ud: ?*anyopaque, _: t.Window, ev: *const t.WindowEvent) callconv(.c) bool {
        const l: *Lock = @ptrCast(@alignCast(ud.?));
        switch (ev.type) {
            .pointer_constrained, .pointer_unconstrained, .shortcuts_inhibited, .shortcuts_restored => {
                l.window_events[l.wn] = ev.type;
                l.wn += 1;
            },
            else => {},
        }
        return false;
    }

    fn onPointer(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const l: *Lock = @ptrCast(@alignCast(ud.?));
        if (!ev.flags.relative) return .pass;
        l.moves[l.n] = ev.*;
        l.n += 1;
        return .handled;
    }
};

fn constraintOf(h: *Harness) !struct { options: platform.ConstraintOptions, active: bool } {
    const self = try h.internal();
    const Ctx = struct {
        id: platform.WindowId,
        out: @typeInfo(@TypeOf(platform.Headless.constraintOf)).@"fn".return_type.? = undefined,
        fn run(ctx: ?*anyopaque, comp: *@import("compositor").Compositor) void {
            const q: *@This() = @ptrCast(@alignCast(ctx));
            q.out = comp.platform.headless.constraintOf(q.id);
        }
    };
    var ctx: Ctx = .{ .id = (try h.win()).win.id };
    try self.app.comp.call(&ctx, Ctx.run);
    return .{ .options = ctx.out.options, .active = ctx.out.active };
}

test "pointer constraints follow their node's box and send it relative motion; shortcut inhibition" {
    var h: Harness = .{};
    var lock: Lock = .{};
    try h.start(200, 100, Lock.onWindow, &lock);
    defer h.stop();
    const root = c.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const row = c.siv_flex(txn, root, null);
    const spacer = c.siv_box(txn, row);
    c.siv_set_layout(txn, spacer, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(30), .height = px(10) });
    const view = c.siv_box(txn, row);
    c.siv_set_layout(txn, view, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(120), .height = px(80) });
    c.siv_on(txn, view, .pointer, Lock.onPointer, null, &lock);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    const id = (try h.win()).win.id;

    try ok(c.siv_window_set_pointer_constraint(h.window, view, .lock, .{ .relative = true }));
    try h.settle();
    var st = try constraintOf(&h);
    try testing.expectEqual(platform.PointerConstraint.lock, st.options.kind);
    try testing.expect(st.options.relative and !st.options.persistent);
    try testing.expectEqual(platform.Rect{ .x = 30, .y = 0, .width = 120, .height = 80 }, st.options.region.?);
    try testing.expectEqual(@as(usize, 1), lock.wn);
    try testing.expectEqual(t.WindowEventType.pointer_constrained, lock.window_events[0]);

    // The box follows layout.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_layout(txn, spacer, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(50), .height = px(10) });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    st = try constraintOf(&h);
    try testing.expectEqual(@as(i32, 50), st.options.region.?.x);

    // Relative motion goes to the node.
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = id, .seat = 0, .x = 90, .y = 40 } },
        .{ .relative_motion = .{ .window = id, .seat = 0, .dx = 3.5, .dy = -2, .dx_unaccel = 2, .dy_unaccel = -1, .time_us = 5_000_000 } },
    });
    try h.settle();
    try testing.expectEqual(@as(usize, 1), lock.n);
    const m = lock.moves[0];
    try testing.expectEqual(t.PointerPhase.move, m.phase);
    try testing.expectEqual(@as(f32, 3.5), m.dx);
    try testing.expectEqual(@as(f32, -2), m.dy);
    try testing.expectEqual(@as(f32, 2), m.raw_dx);
    try testing.expectEqual(@as(f32, -1), m.raw_dy);
    try testing.expectEqual(@as(f32, 40), m.x); // 90 - 50
    try testing.expectEqual(@as(u32, 5000), m.time);

    // The compositor ends a one-shot lock; relative motion still comes.
    const self = try h.internal();
    const End = struct {
        id: platform.WindowId,
        fn run(ctx: ?*anyopaque, comp: *@import("compositor").Compositor) void {
            const e: *@This() = @ptrCast(@alignCast(ctx));
            comp.platform.headless.endConstraint(e.id);
        }
    };
    var end: End = .{ .id = id };
    try self.app.comp.call(&end, End.run);
    try h.settle();
    try testing.expectEqual(t.WindowEventType.pointer_unconstrained, lock.window_events[1]);

    try ok(c.siv_window_inhibit_shortcuts(h.window, true));
    try h.settle();
    try ok(c.siv_window_inhibit_shortcuts(h.window, false));
    try h.settle();
    try testing.expectEqual(@as(usize, 4), lock.wn);
    try testing.expectEqual(t.WindowEventType.shortcuts_inhibited, lock.window_events[2]);
    try testing.expectEqual(t.WindowEventType.shortcuts_restored, lock.window_events[3]);

    // Removing the node ends the constraint.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_remove(txn, view);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    st = try constraintOf(&h);
    try testing.expectEqual(platform.PointerConstraint.none, st.options.kind);
    try testing.expect(!st.options.relative);
}

const Buttons = struct {
    events: [8]t.Event = undefined,
    n: usize = 0,

    fn onPointer(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const l: *Buttons = @ptrCast(@alignCast(ud.?));
        if (ev.phase != .down and ev.phase != .up) return .pass;
        l.events[l.n] = ev.*;
        l.n += 1;
        return .handled;
    }
};

test "side buttons are back and forward, and every button carries its evdev code" {
    var h: Harness = .{};
    try h.start(100, 100, null, null);
    defer h.stop();
    var log: Buttons = .{};
    const root = c.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_on(txn, root, .pointer, Buttons.onPointer, null, &log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    const id = (try h.win()).win.id;
    try h.inject(&.{.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 20, .y = 20 } }});
    // BTN_SIDE, BTN_EXTRA, BTN_BACK, and BTN_TASK (named by code only).
    for ([_]u32{ 0x113, 0x114, 0x116, 0x117 }) |code| try h.inject(&.{
        .{ .pointer_button = .{ .window = id, .seat = 0, .button = code, .pressed = true, .time = 0, .serial = 0 } },
        .{ .pointer_button = .{ .window = id, .seat = 0, .button = code, .pressed = false, .time = 0, .serial = 0 } },
    });
    try h.settle();
    try testing.expectEqual(@as(usize, 8), log.n);
    try testing.expectEqual(t.PointerButton.back, log.events[0].button);
    try testing.expectEqual(@as(u32, 0x113), log.events[0].button_code);
    try testing.expectEqual(t.PointerPhase.up, log.events[1].phase);
    try testing.expectEqual(t.PointerButton.forward, log.events[2].button);
    try testing.expectEqual(t.PointerButton.back, log.events[4].button);
    try testing.expectEqual(@as(u32, 0x116), log.events[4].button_code);
    try testing.expectEqual(t.PointerButton.other, log.events[6].button);
    try testing.expectEqual(@as(u32, 0x117), log.events[6].button_code);
    // siv_test_click names the side buttons too.
    log.n = 0;
    try ok(c.siv_test_click(h.window, 20, 20, .forward));
    try h.settle();
    try testing.expectEqual(t.PointerButton.forward, log.events[0].button);
    try testing.expectEqual(@as(u32, 0x114), log.events[0].button_code);
}

const Raw = struct {
    events: [16]t.Event = undefined,
    n: usize = 0,

    fn on(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const l: *Raw = @ptrCast(@alignCast(ud.?));
        if (l.n < l.events.len) l.events[l.n] = ev.*;
        l.n += 1;
        return .handled;
    }
};

test "custom widgets get raw input: keycodes, scroll as the compositor sent it, and touch sequences" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var keys: Raw = .{};
    var scrolls: Raw = .{};
    var touches: Raw = .{};
    var pointers: Raw = .{};
    var others: Raw = .{};
    const root = c.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const row = c.siv_flex(txn, root, &.{ .size = @sizeOf(t.FlexDesc), .axis = .row });
    // A widget at (0, 0) that handles touch itself, and one at (100, 0)
    // that leaves touch to the pointer.
    const pad = c.siv_box(txn, row);
    c.siv_set_layout(txn, pad, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(100), .height = px(100) });
    c.siv_set_semantics(txn, pad, &.{ .size = @sizeOf(t.SemanticsDesc), .flags = .{ .focusable = true } });
    c.siv_on(txn, pad, .key, Raw.on, null, &keys);
    c.siv_on(txn, pad, .scroll, Raw.on, null, &scrolls);
    c.siv_on(txn, pad, .touch, Raw.on, null, &touches);
    c.siv_on(txn, pad, .pointer, Raw.on, null, &pointers);
    const other = c.siv_box(txn, row);
    c.siv_set_layout(txn, other, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(100), .height = px(100) });
    c.siv_on(txn, other, .pointer, Raw.on, null, &others);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_focus(pad));
    const id = (try h.win()).win.id;

    // Keys carry the physical key: KEY_A is evdev 30, XKB keycode 38.
    try h.inject(&.{.{ .key = .{ .window = id, .seat = 0, .keycode = 38, .keysym = 'a', .state = .pressed, .mods = .{}, .time = 5, .serial = 1 } }});
    try h.settle();
    try testing.expectEqual(@as(usize, 1), keys.n);
    try testing.expectEqual(@as(u32, 38), keys.events[0].keycode);

    // Half a high-resolution detent: siv's distance for the window, and the
    // input as sent; then a touchpad's fingers lifting.
    try h.inject(&.{.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 20, .y = 20 } }});
    try h.inject(&.{.{ .scroll = .{ .window = id, .seat = 0, .dy = 7.5, .v120_y = 60, .source = .wheel } }});
    try h.inject(&.{.{ .scroll = .{ .window = id, .seat = 0, .dy = 3, .source = .finger } }});
    try h.inject(&.{.{ .scroll = .{ .window = id, .seat = 0, .source = .finger, .stop_y = true } }});
    try h.settle();
    try testing.expectEqual(@as(usize, 3), scrolls.n);
    const wheel = scrolls.events[0];
    try testing.expectEqual(t.ScrollSource.wheel, wheel.scroll_source);
    try testing.expectEqual(@as(f32, 0.5), wheel.steps_y);
    try testing.expectEqual(@as(f32, 7.5), wheel.raw_dy);
    // The window's 100 px: a detent scrolls 60 px (D16), half of it 30.
    try testing.expectEqual(@as(f32, 30), wheel.dy);
    try testing.expect(!wheel.flags.stop);
    const finger = scrolls.events[1];
    try testing.expectEqual(t.ScrollSource.finger, finger.scroll_source);
    try testing.expectEqual(@as(f32, 3), finger.raw_dy);
    try testing.expectEqual(@as(f32, 12), finger.dy);
    try testing.expectEqual(@as(f32, 0), finger.steps_y);
    try testing.expect(scrolls.events[2].flags.stop);
    try testing.expectEqual(@as(f32, 0), scrolls.events[2].dy);

    // Two fingers on the widget: each sequence goes to it, in its
    // coordinates, and no pointer press is emulated.
    const pointers_before = pointers.n;
    try h.inject(&.{
        .{ .touch_down = .{ .window = id, .seat = 0, .id = 7, .x = 10, .y = 20, .time = 1 } },
        .{ .touch_down = .{ .window = id, .seat = 0, .id = 8, .x = 30, .y = 40, .time = 2 } },
        .{ .touch_motion = .{ .window = id, .seat = 0, .id = 7, .x = 15, .y = 25, .time = 3 } },
        .{ .touch_up = .{ .window = id, .seat = 0, .id = 7, .time = 4 } },
        .{ .touch_cancel = .{ .window = id, .seat = 0 } },
    });
    try h.settle();
    try testing.expectEqual(@as(usize, 5), touches.n);
    try testing.expectEqual(t.PointerPhase.down, touches.events[0].phase);
    try testing.expectEqual(@as(i32, 7), touches.events[0].touch_id);
    try testing.expectEqual(@as(f32, 10), touches.events[0].x);
    try testing.expectEqual(@as(i32, 8), touches.events[1].touch_id);
    try testing.expectEqual(@as(f32, 40), touches.events[1].y);
    try testing.expectEqual(t.PointerPhase.move, touches.events[2].phase);
    try testing.expectEqual(@as(f32, 25), touches.events[2].y);
    try testing.expectEqual(t.PointerPhase.up, touches.events[3].phase);
    // Only the sequence still down is cancelled.
    try testing.expectEqual(t.PointerPhase.cancel, touches.events[4].phase);
    try testing.expectEqual(@as(i32, 8), touches.events[4].touch_id);
    for (pointers.events[pointers_before..@min(pointers.n, pointers.events.len)]) |e| try testing.expect(e.phase != .down);
    // A touch elsewhere still drives the pointer, in that node's
    // coordinates.
    try h.inject(&.{
        .{ .touch_down = .{ .window = id, .seat = 0, .id = 9, .x = 150, .y = 50, .time = 5 } },
        .{ .touch_up = .{ .window = id, .seat = 0, .id = 9, .time = 6 } },
    });
    try h.settle();
    try testing.expectEqual(@as(usize, 5), touches.n);
    var down = false;
    for (others.events[0..@min(others.n, others.events.len)]) |e| down = down or (e.phase == .down and e.x == 50);
    try testing.expect(down);
}

const Ime = struct {
    n: usize = 0,
    text: [32]u8 = undefined,
    text_len: usize = 0,
    preedit: [32]u8 = undefined,
    preedit_len: usize = 0,
    last: t.Event = .{},

    fn on(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const l: *Ime = @ptrCast(@alignCast(ud.?));
        l.n += 1;
        l.last = ev.*;
        l.text_len = ev.text_len;
        @memcpy(l.text[0..ev.text_len], ev.text.?[0..ev.text_len]);
        l.preedit_len = ev.preedit_len;
        if (ev.preedit_len != 0) @memcpy(l.preedit[0..ev.preedit_len], ev.preedit.?[0..ev.preedit_len]);
        return .handled;
    }
};

/// What the headless seat's input method was last told.
fn imeState(h: *Harness) !struct { enabled: bool, surrounding: [64]u8, len: usize, cursor: u32, purpose: platform.ContentPurpose, rect: platform.Rect } {
    const C = struct {
        out: @typeInfo(@typeInfo(@TypeOf(imeState)).@"fn".return_type.?).error_union.payload = undefined,
        fn run(ctx: ?*anyopaque, comp: *@import("compositor").Compositor) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const st = comp.platform.headless.textInput(0).state;
            self.out.enabled = st.enabled;
            self.out.len = @min(st.surrounding.len, 64);
            @memcpy(self.out.surrounding[0..self.out.len], st.surrounding[0..self.out.len]);
            self.out.cursor = st.cursor;
            self.out.purpose = st.purpose;
            self.out.rect = st.cursor_rect;
        }
    };
    var ctx: C = .{};
    try (try h.internal()).app.comp.call(&ctx, C.run);
    return ctx.out;
}

test "custom text widgets talk to the input method: their text and caret out, its edits in" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var log: Ime = .{};
    const root = c.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const col = c.siv_flex(txn, root, &.{ .size = @sizeOf(t.FlexDesc), .axis = .column });
    const spacer = c.siv_box(txn, col);
    c.siv_set_layout(txn, spacer, &.{ .size = @sizeOf(t.LayoutDesc), .height = px(30) });
    // A terminal-like widget 30 px down, its caret 10 px in.
    const term = c.siv_box(txn, col);
    c.siv_set_layout(txn, term, &.{ .size = @sizeOf(t.LayoutDesc), .width = px(200), .height = px(50) });
    c.siv_set_semantics(txn, term, &.{ .size = @sizeOf(t.SemanticsDesc), .flags = .{ .focusable = true } });
    c.siv_on(txn, term, .text_input, Ime.on, null, &log);
    const text = "hello";
    c.siv_set_text_input(txn, term, &.{ .size = @sizeOf(t.TextInputDesc), .surrounding = text, .surrounding_len = text.len, .cursor = 5, .anchor = 5, .cursor_rect = .{ .x = 10, .y = 4, .width = 2, .height = 16 }, .purpose = .terminal, .hints = .{ .multiline = true } });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    const id = (try h.win()).win.id;
    try h.inject(&.{.{ .text_input_enter = .{ .window = id, .seat = 0, .serial = 0 } }});
    try ok(c.siv_node_focus(term));
    try h.settle();
    var st = try imeState(&h);
    try testing.expect(st.enabled);
    try testing.expectEqualStrings("hello", st.surrounding[0..st.len]);
    try testing.expectEqual(@as(u32, 5), st.cursor);
    try testing.expectEqual(platform.ContentPurpose.terminal, st.purpose);
    // The caret in window coordinates.
    try testing.expectEqual(platform.Rect{ .x = 10, .y = 34, .width = 2, .height = 16 }, st.rect);

    // An edit: delete one byte, commit "p", compose "ab" with its cursor
    // after the "a". The widget applies it.
    var e: platform.TextInput = .{ .window = id, .seat = 0, .delete_before = 1, .cursor_begin = 1, .cursor_end = 1 };
    @memcpy(e.commit_buf[0..1], "p");
    e.commit_len = 1;
    @memcpy(e.preedit_buf[0..2], "ab");
    e.preedit_len = 2;
    try h.inject(&.{.{ .text_input = e }});
    try h.settle();
    try testing.expectEqual(@as(usize, 1), log.n);
    try testing.expectEqual(t.EventType.text_input, log.last.type);
    try testing.expectEqualStrings("p", log.text[0..log.text_len]);
    try testing.expectEqualStrings("ab", log.preedit[0..log.preedit_len]);
    try testing.expectEqual(@as(u32, 1), log.last.delete_before);
    try testing.expectEqual(@as(i32, 1), log.last.preedit_cursor_begin);

    // The widget tells siv its new text; then turns text input off.
    try ok(c.siv_txn_begin(h.window, &txn));
    const text2 = "hellp";
    c.siv_set_text_input(txn, term, &.{ .size = @sizeOf(t.TextInputDesc), .surrounding = text2, .surrounding_len = text2.len, .cursor = 5, .anchor = 5 });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    st = try imeState(&h);
    try testing.expectEqualStrings("hellp", st.surrounding[0..st.len]);
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_text_input(txn, term, null);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expect(!(try imeState(&h)).enabled);
    // A cursor past the text is refused.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_text_input(txn, term, &.{ .size = @sizeOf(t.TextInputDesc), .surrounding = text2, .surrounding_len = text2.len, .cursor = 9 });
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
}
