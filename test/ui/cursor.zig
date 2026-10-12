//! Pointer cursors end to end on the headless backend (D16): the cursor
//! of the node under the pointer reaches the platform, inherited from
//! ancestors, kept by a press, overridden for the whole window, and
//! updated when the tree changes under a still pointer.

const std = @import("std");
const ui = @import("ui");
const platform = @import("platform");
const App = @import("harness.zig").App;

const testing = std.testing;

fn cursorOf(app: *App) platform.CursorShape {
    const C = struct {
        wid: platform.WindowId,
        out: platform.CursorShape = .default,
        changes: u32 = 0,
        fn run(hl: *platform.Headless, c: *@This()) void {
            c.out = hl.cursorOf(c.wid);
        }
    };
    var c: C = .{ .wid = app.wid };
    app.onHeadless(&c, C.run);
    return c.out;
}

fn changes(app: *App) u32 {
    const C = struct {
        out: u32 = 0,
        fn run(hl: *platform.Headless, c: *@This()) void {
            c.out = hl.cursor_changes;
        }
    };
    var c: C = .{};
    app.onHeadless(&c, C.run);
    return c.out;
}

fn moveTo(app: *App, x: f64, y: f64) !void {
    app.inject(.{ .pointer_motion = .{ .window = app.wid, .seat = 0, .x = x, .y = y } });
    try app.settle();
}

test "the cursor follows the node under the pointer" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 300, .height = 100 });
    defer app.deinit();
    const t = try app.win.begin();
    const row = try t.create(.root, .flex, .none);
    const pane = try t.create(row, .box, .none);
    try t.setLayout(pane, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    try t.setCursor(pane, .pointer);
    // A child inherits its parent's cursor.
    const child = try t.create(pane, .box, .none);
    try t.setLayout(child, .{ .height = .{ .px = 50 } });
    const handle = try t.create(row, .box, .none);
    try t.setLayout(handle, .{ .width = .{ .px = 10 }, .height = .{ .px = 100 } });
    try t.setCursor(handle, .col_resize);
    const ed = try t.create(row, .editor, .none);
    try t.setLayout(ed, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } });
    t.commit();
    try app.settle();

    try moveTo(&app, 20, 20);
    try testing.expectEqual(platform.CursorShape.pointer, cursorOf(&app));
    try moveTo(&app, 105, 20);
    try testing.expectEqual(platform.CursorShape.col_resize, cursorOf(&app));
    try moveTo(&app, 150, 10);
    try testing.expectEqual(platform.CursorShape.text, cursorOf(&app));
    try moveTo(&app, 150, 80);
    try testing.expectEqual(platform.CursorShape.default, cursorOf(&app));

    // A press on the handle keeps its cursor while the pointer leaves it,
    // as when dragging a split; the release lets go.
    try moveTo(&app, 105, 20);
    app.inject(.{ .pointer_button = .{ .window = app.wid, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 1 } });
    try moveTo(&app, 200, 80);
    try testing.expectEqual(platform.CursorShape.col_resize, cursorOf(&app));
    app.inject(.{ .pointer_button = .{ .window = app.wid, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 2 } });
    try app.settle();
    try testing.expectEqual(platform.CursorShape.default, cursorOf(&app));

    // Moving within the same cursor sends nothing.
    const before = changes(&app);
    try moveTo(&app, 210, 85);
    try testing.expectEqual(before, changes(&app));

    // A busy override wins everywhere until cleared.
    app.win.setCursorOverride(.progress);
    try app.settle();
    try testing.expectEqual(platform.CursorShape.progress, cursorOf(&app));
    try moveTo(&app, 20, 20);
    try testing.expectEqual(platform.CursorShape.progress, cursorOf(&app));
    app.win.setCursorOverride(null);
    try app.settle();
    try testing.expectEqual(platform.CursorShape.pointer, cursorOf(&app));

    // The tree changes under the still pointer: the next frame updates it,
    // here to the parent's after the child sets none, then hidden.
    const t2 = try app.win.begin();
    try t2.setCursor(pane, null);
    t2.commit();
    try app.settle();
    try testing.expectEqual(platform.CursorShape.default, cursorOf(&app));
    const t3 = try app.win.begin();
    try t3.setCursor(child, .hidden);
    t3.commit();
    try app.settle();
    try testing.expectEqual(platform.CursorShape.hidden, cursorOf(&app));
}
