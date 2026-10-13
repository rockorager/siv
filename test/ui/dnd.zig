//! Drag and drop end to end on the headless backend (D19): drops from
//! other clients into drop targets and editors, drags from the window to
//! its own nodes and to other clients, actions and `ask`, in-app drags,
//! and the size limit.

const std = @import("std");
const ui = @import("ui");
const platform = @import("platform");
const App = @import("harness.zig").App;

const testing = std.testing;
const NodeId = ui.NodeId;

/// Records drop and drag events, answers drops as told, and starts a drag
/// from a node when the pointer moves with the button held.
const Rec = struct {
    drops: std.ArrayList(Drop) = .empty,
    drags: std.ArrayList(ui.Drag) = .empty,
    /// What `enter`, `move`, and `drop` return.
    take: bool = true,
    /// Start this drag from the node with the pointer handler.
    start: ?ui.Window.DragOptions = null,
    start_err: ?ui.Window.DragError = null,
    pressed: bool = false,

    const Drop = struct { phase: ui.DropPhase, x: f32, y: f32, action: ui.DragAction, mime: []const u8, data: []u8 };

    fn deinit(r: *Rec) void {
        for (r.drops.items) |d| testing.allocator.free(d.data);
        r.drops.deinit(testing.allocator);
        r.drags.deinit(testing.allocator);
    }

    fn handler(r: *Rec) ui.Handler {
        return .{ .func = onEvent, .user = r };
    }

    fn onEvent(user: ?*anyopaque, win: *ui.Window, id: NodeId, ev: *const ui.Event) ui.HandlerResult {
        const r: *Rec = @ptrCast(@alignCast(user));
        switch (ev.*) {
            .drop => |d| {
                // Static strings outlive the test; data is copied.
                const mime: []const u8 = for ([_][]const u8{ "text/uri-list", "text/plain", "application/x-row", "text/plain;charset=utf-8" }) |m| {
                    if (std.mem.eql(u8, m, d.mime)) break m;
                } else "";
                r.drops.append(testing.allocator, .{ .phase = d.phase, .x = d.x, .y = d.y, .action = d.action, .mime = mime, .data = testing.allocator.dupe(u8, d.data) catch unreachable }) catch unreachable;
                return if (r.take) .handled else .pass;
            },
            .drag => |d| r.drags.append(testing.allocator, d) catch unreachable,
            .pointer => |p| if (p.phase == .down or p.phase == .up or p.phase == .cancel) {
                r.pressed = p.phase == .down;
            } else if (p.phase == .move and r.pressed) if (r.start) |o| {
                r.start = null;
                win.startDrag(id, o) catch |e| {
                    r.start_err = e;
                };
                return .handled;
            },
            else => {},
        }
        return .pass;
    }

    fn phases(r: *const Rec, buf: []ui.DropPhase) []ui.DropPhase {
        for (r.drops.items, 0..) |d, i| buf[i] = d.phase;
        return buf[0..r.drops.items.len];
    }
};

/// Two boxes side by side over the window: a source on the left and a
/// drop target on the right, and an editor below.
const Scene = struct { source: NodeId, target: NodeId, editor: NodeId };

fn scene(app: *App, rec: *Rec, target: ui.DropTarget) !Scene {
    const t = try app.win.begin();
    const col = try t.create(.root, .flex, .none);
    try t.setFlex(col, .{ .axis = .column });
    const row = try t.create(col, .flex, .none);
    const source = try t.create(row, .box, .none);
    try t.setLayout(source, .{ .width = .{ .px = 100 }, .height = .{ .px = 60 } });
    try t.on(source, .pointer, rec.handler());
    try t.on(source, .drag, rec.handler());
    const target_node = try t.create(row, .box, .none);
    try t.setLayout(target_node, .{ .width = .{ .px = 100 }, .height = .{ .px = 60 } });
    // A child of the target: drags over it go to the target.
    _ = try t.create(target_node, .box, .none);
    try t.setDropTarget(target_node, target);
    try t.on(target_node, .drop, rec.handler());
    const ed = try t.create(col, .editor, .none);
    try t.setLayout(ed, .{ .width = .{ .px = 200 }, .height = .{ .px = 24 } });
    try t.setText(ed, "ab");
    t.commit();
    try settle(app);
    return .{ .source = source, .target = target_node, .editor = ed };
}

/// Settles, after enough loop iterations for a drag event's round trip
/// (platform, compositor, window, and back through the compositor),
/// which `App.settle` alone may count as idle.
fn settle(app: *App) !void {
    for (0..12) |_| try app.loop.dispatch(0);
    try app.settle();
}

const Offer = struct { window: platform.WindowId, mimes: []const []const u8, data: []const u8, actions: platform.DragActions, x: f64, y: f64 };

fn offer(hl: *platform.Headless, o: *const Offer) void {
    hl.offerDrag(0, o.window, o.mimes, o.data, o.actions, o.x, o.y) catch unreachable;
}

fn move(hl: *platform.Headless, p: *const [2]f64) void {
    hl.moveDrag(0, p[0], p[1]);
}

fn dropIt(hl: *platform.Headless, _: void) void {
    hl.dropDrag(0);
}

fn leave(hl: *platform.Headless, _: void) void {
    hl.leaveDrag(0);
}

const Snapshot = struct { accepted: ?[]const u8 = null, action: platform.DragAction = .none, result: ?platform.DragAction = null, preferred: platform.DragAction = .none, offer: u32 = 0, source: u32 = 0 };

fn snap(hl: *platform.Headless, out: *Snapshot) void {
    const d = hl.drag(0);
    out.* = .{ .accepted = d.acceptedMime(), .action = d.action, .result = d.result, .preferred = d.preferred, .offer = d.offer, .source = d.source };
}

fn state(app: *App) Snapshot {
    var s: Snapshot = .{};
    app.onHeadless(&s, snap);
    return s;
}

test "drops from another client reach the nearest drop target that takes them" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 240, .height = 120 });
    defer app.deinit();
    var rec: Rec = .{};
    defer rec.deinit();
    const sc = try scene(&app, &rec, .{ .mimes = "text/uri-list\ntext/plain", .actions = .{ .copy = true, .move = true }, .preferred = .move });

    // Enters over the source (no drop target): refused. Then over the
    // target's child: the target takes its preferred type and action.
    app.onHeadless(&Offer{ .window = app.wid, .mimes = &.{ "text/plain", "text/uri-list" }, .data = "file:///tmp/a\r\n", .actions = .{ .copy = true, .move = true }, .x = 10, .y = 10 }, offer);
    try settle(&app);
    try testing.expect(state(&app).accepted == null);
    app.onHeadless(&[2]f64{ 150, 20 }, move);
    try settle(&app);
    const s = state(&app);
    try testing.expectEqualStrings("text/uri-list", s.accepted.?);
    try testing.expectEqual(platform.DragAction.move, s.action);
    try testing.expectEqual(platform.DragAction.move, s.preferred);
    app.onHeadless(&[2]f64{ 160, 30 }, move);
    app.onHeadless({}, dropIt);
    try settle(&app);
    var buf: [16]ui.DropPhase = undefined;
    // Moves follow the pointer and the compositor's choice of action.
    try expectPhases(&.{ .enter, .move, .drop }, rec.phases(&buf));
    const d = rec.drops.getLast();
    try testing.expectEqualStrings("text/uri-list", d.mime);
    try testing.expectEqualStrings("file:///tmp/a\r\n", d.data);
    try testing.expectEqual(ui.DragAction.move, d.action);
    // Local coordinates: the target starts at x = 100.
    try testing.expectEqual(@as(f32, 60), d.x);
    try testing.expectEqual(@as(f32, 30), d.y);
    try testing.expectEqual(@as(?platform.DragAction, .move), state(&app).result);

    // A target whose handler refuses: not accepted, the drop is cancelled
    // and the target hears leave.
    rec.take = false;
    const before = rec.drops.items.len;
    app.onHeadless(&Offer{ .window = app.wid, .mimes = &.{"text/plain"}, .data = "x", .actions = .{ .copy = true }, .x = 150, .y = 20 }, offer);
    try settle(&app);
    app.onHeadless({}, dropIt);
    try settle(&app);
    try testing.expect(state(&app).accepted == null);
    try testing.expectEqual(@as(?platform.DragAction, .none), state(&app).result);
    try expectPhases(&.{ .enter, .leave }, rec.phases(&buf)[before..]);
    rec.take = true;

    // A type the target does not take, and actions it does not allow,
    // never reach it.
    app.onHeadless(&Offer{ .window = app.wid, .mimes = &.{"image/png"}, .data = "", .actions = .{ .copy = true }, .x = 150, .y = 20 }, offer);
    try settle(&app);
    app.onHeadless({}, leave);
    app.onHeadless(&Offer{ .window = app.wid, .mimes = &.{"text/plain"}, .data = "", .actions = .{ .ask = true }, .x = 150, .y = 20 }, offer);
    try settle(&app);
    try testing.expect(state(&app).accepted == null);
    app.onHeadless({}, leave);
    const seen = rec.drops.items.len;
    try settle(&app);
    try testing.expectEqual(seen, rec.drops.items.len);

    // Text dropped on the editor goes in at the drop point and is selected.
    const r = app.win.windowRect(sc.editor);
    app.onHeadless(&Offer{ .window = app.wid, .mimes = &.{ "image/png", "UTF8_STRING" }, .data = "X\x00Y", .actions = .{ .copy = true, .move = true }, .x = r.x1 - 2, .y = r.y0 + 10 }, offer);
    try settle(&app);
    try testing.expectEqualStrings("UTF8_STRING", state(&app).accepted.?);
    try testing.expectEqual(platform.DragAction.copy, state(&app).action);
    app.onHeadless({}, dropIt);
    try settle(&app);
    const e = app.win.node(sc.editor).data.editor;
    try testing.expectEqualStrings("abXY", e.text.content);
    try testing.expectEqual(@as(u32, 4), e.caret);
    try testing.expectEqual(@as(u32, 2), e.anchor);
    try testing.expectEqual(sc.editor, app.win.input.focus);
    _ = sc.target;
}

test "an ask drop waits for the application's choice; over the limit it fails" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 240, .height = 120 });
    defer app.deinit();
    var rec: Rec = .{};
    defer rec.deinit();
    _ = try scene(&app, &rec, .{ .mimes = "text/plain", .actions = .{ .copy = true, .move = true, .ask = true }, .preferred = .ask });

    app.onHeadless(&Offer{ .window = app.wid, .mimes = &.{"text/plain"}, .data = "hello", .actions = .{ .copy = true, .move = true, .ask = true }, .x = 150, .y = 20 }, offer);
    try settle(&app);
    try testing.expectEqual(platform.DragAction.ask, state(&app).action);
    app.onHeadless({}, dropIt);
    try settle(&app);
    try testing.expectEqual(ui.DragAction.ask, rec.drops.getLast().action);
    try testing.expectEqualStrings("hello", rec.drops.getLast().data);
    // Not finished until the application decides.
    try testing.expect(state(&app).result == null);
    app.win.finishDrop(.copy);
    try settle(&app);
    try testing.expectEqual(@as(?platform.DragAction, .copy), state(&app).result);

    // More than the limit: the read fails, the target hears leave, and the
    // drop is refused.
    app.clipboard.limit = 1000;
    const big = try testing.allocator.alloc(u8, 70_000);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    app.onHeadless(&Offer{ .window = app.wid, .mimes = &.{"text/plain"}, .data = big, .actions = .{ .copy = true }, .x = 150, .y = 20 }, offer);
    try settle(&app);
    app.onHeadless({}, dropIt);
    try settle(&app);
    try testing.expectEqual(ui.DropPhase.leave, rec.drops.getLast().phase);
    try testing.expectEqual(@as(?platform.DragAction, .none), state(&app).result);
}

test "drags from the window drop on its own nodes and on other clients" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 240, .height = 120 });
    defer app.deinit();
    var rec: Rec = .{};
    defer rec.deinit();
    const sc = try scene(&app, &rec, .{ .mimes = "application/x-row\ntext/plain", .actions = .{ .copy = true, .move = true } });
    _ = sc;

    // Without a press held there is nothing to drag with.
    try testing.expectError(error.Unavailable, app.win.startDrag(sc_source(&app), .{ .items = &.{.{ .mime = "text/plain", .data = "x" }} }));

    // Press on the source and move: its handler starts an in-app drag of
    // a row, which enters the window under the pointer.
    rec.start = .{ .items = &.{ .{ .mime = "application/x-row", .data = "row 7" }, .{ .mime = "text/plain", .data = "Row 7" } }, .actions = .{ .move = true }, .in_app = true };
    app.inject(.{ .pointer_motion = .{ .window = app.wid, .seat = 0, .x = 20, .y = 20 } });
    app.inject(.{ .pointer_button = .{ .window = app.wid, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 41 } });
    app.inject(.{ .pointer_motion = .{ .window = app.wid, .seat = 0, .x = 30, .y = 20 } });
    try settle(&app);
    try testing.expect(rec.start_err == null);
    try testing.expect(state(&app).source != 0);
    // The platform sees only the private type.
    const Mimes = struct {
        n: usize = 0,
        first: [64]u8 = undefined,
        len: usize = 0,
        fn run(hl: *platform.Headless, m: *@This()) void {
            const list = hl.drag(0).source_mimes.items;
            m.n = list.len;
            m.len = list[0].len;
            @memcpy(m.first[0..m.len], list[0]);
        }
    };
    var mimes: Mimes = .{};
    app.onHeadless(&mimes, Mimes.run);
    try testing.expectEqual(@as(usize, 1), mimes.n);
    try testing.expectEqualStrings(ui.dnd.in_app_mime, mimes.first[0..mimes.len]);

    // Over the target: it takes the row type with move, and the source
    // hears that.
    app.inject(.{ .pointer_motion = .{ .window = app.wid, .seat = 0, .x = 150, .y = 20 } });
    try settle(&app);
    try testing.expectEqual(platform.DragAction.move, state(&app).action);
    try testing.expect(rec.drags.items.len != 0 and rec.drags.getLast().phase == .move);
    app.inject(.{ .pointer_button = .{ .window = app.wid, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 42 } });
    try settle(&app);
    const d = rec.drops.getLast();
    try testing.expectEqual(ui.DropPhase.drop, d.phase);
    try testing.expectEqualStrings("application/x-row", d.mime);
    try testing.expectEqualStrings("row 7", d.data);
    const end = rec.drags.getLast();
    try testing.expectEqual(ui.DragPhase.end, end.phase);
    try testing.expectEqual(ui.DragAction.move, end.action);
    try testing.expect(app.clipboard.drag == null);

    // A drag dragged out to another client, which reads it and copies.
    rec.start = .{ .items = &.{.{ .mime = "text/plain", .data = "Row 8" }}, .actions = .{ .copy = true, .move = true } };
    app.inject(.{ .pointer_motion = .{ .window = app.wid, .seat = 0, .x = 20, .y = 20 } });
    app.inject(.{ .pointer_button = .{ .window = app.wid, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 43 } });
    app.inject(.{ .pointer_motion = .{ .window = app.wid, .seat = 0, .x = 20, .y = 30 } });
    try settle(&app);
    app.onHeadless({}, leave);
    const Out = struct {
        fd: ?i32 = null,
        fn run(hl: *platform.Headless, o: *@This()) void {
            o.fd = hl.dropOutside(0, "text/plain", .copy) catch null;
        }
        fn finish(hl: *platform.Headless, _: void) void {
            hl.finishOutside(0, .copy);
        }
    };
    var out: Out = .{};
    app.onHeadless(&out, Out.run);
    const got = try app.readAll(out.fd.?);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Row 8", got);
    app.onHeadless({}, Out.finish);
    try settle(&app);
    try testing.expectEqual(ui.DragPhase.end, rec.drags.getLast().phase);
    try testing.expectEqual(ui.DragAction.copy, rec.drags.getLast().action);
    try testing.expect(app.clipboard.drag == null);
}

/// `got` is `want` with any number of moves where `want` has one.
fn expectPhases(want: []const ui.DropPhase, got: []const ui.DropPhase) !void {
    var i: usize = 0;
    for (got) |p| {
        if (i > 0 and p == .move and want[i - 1] == .move) continue;
        if (i >= want.len or p != want[i]) {
            std.debug.print("phases: want {any}, got {any}\n", .{ want, got });
            return error.TestUnexpectedResult;
        }
        i += 1;
    }
    if (i != want.len) {
        std.debug.print("phases: want {any}, got {any}\n", .{ want, got });
        return error.TestUnexpectedResult;
    }
}

fn sc_source(app: *App) NodeId {
    // The first box of the row.
    return app.win.node(app.win.node(app.win.node(.root).first).first).first;
}
