//! Canvases drawn by C code (test/c/canvas_scene.c) through the public
//! API on the headless backend (D28): golden images of every drawing
//! construct, redraws that damage only their canvas, and measure callbacks
//! that resize a canvas when its content changes.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const T = abi.tree;
const Harness = harness.Harness;
const ok = harness.ok;

const shapes = 0;
const layers = 1;
const picture = 2;
const label = 3;
const broken = 4;

extern fn canvas_scene_build(app: t.App, window: t.Window) t.Result;
extern fn canvas_scene_recolor() t.Result;
extern fn canvas_scene_relabel(text: [*:0]const u8) t.Result;
extern fn canvas_scene_draws(which: c_int) c_int;
extern fn canvas_scene_measures() c_int;
extern fn canvas_scene_node(which: c_int) t.Node;
extern fn canvas_scene_busy_result() t.Result;
extern fn canvas_scene_broken_status() t.Result;
extern fn canvas_scene_picture_status() t.Result;
extern fn canvas_scene_stale_draw() t.Draw;

fn rect(node: t.Node) !t.Rect {
    var r: t.Rect = undefined;
    try ok(T.siv_node_get_rect(node, &r));
    return r;
}

test "C API canvas: drawing from C, per-canvas redraws, measured sizes" {
    var h: Harness = .{};
    try h.start(300, 150, null, null);
    defer h.stop();
    try ok(canvas_scene_build(h.app, h.window));
    try h.settle();
    try h.expectGolden("canvas", 300, 150);

    // Each canvas drew; the draw callback could not open a transaction,
    // the broken one failed and shows nothing, and the drawing handle died
    // with its callback.
    for ([_]c_int{ shapes, layers, picture, label, broken }) |i| try testing.expect(canvas_scene_draws(i) >= 1);
    try testing.expectEqual(t.Result.error_busy, canvas_scene_busy_result());
    try testing.expectEqual(t.Result.error_invalid_argument, canvas_scene_broken_status());
    try ok(canvas_scene_picture_status());
    try testing.expectEqual(t.Result.error_invalid_handle, abi.canvas.siv_draw_move_to(canvas_scene_stale_draw(), 0, 0));
    try testing.expect(canvas_scene_measures() >= 1);

    // Invalidating one canvas redraws it alone and damages only its box.
    var before: [5]c_int = undefined;
    for (&before, 0..) |*b, i| b.* = canvas_scene_draws(@intCast(i));
    try ok(canvas_scene_recolor());
    try h.settle();
    try testing.expectEqual(before[shapes] + 1, canvas_scene_draws(shapes));
    for ([_]c_int{ layers, picture, label, broken }) |i| try testing.expectEqual(before[@intCast(i)], canvas_scene_draws(i));
    const box = try rect(canvas_scene_node(shapes));
    const damage = (try h.lastDamage()).?;
    try testing.expect(damage.x >= @as(i32, @intFromFloat(@floor(box.x))) and damage.y >= @as(i32, @intFromFloat(@floor(box.y))));
    try testing.expect(damage.x + damage.width <= @as(i32, @intFromFloat(@ceil(box.x + box.width))));
    try testing.expect(damage.y + damage.height <= @as(i32, @intFromFloat(@ceil(box.y + box.height))));
    try h.expectGolden("canvas-recolor", 300, 150);

    // New text: the canvas measures again and grows; what follows moves.
    const old = try rect(canvas_scene_node(label));
    const measures = canvas_scene_measures();
    try ok(canvas_scene_relabel("A much longer label"));
    try h.settle();
    try testing.expect(canvas_scene_measures() > measures);
    const new = try rect(canvas_scene_node(label));
    try testing.expect(new.width > old.width + 40);
    try testing.expectEqual(old.height, new.height);
    try h.expectGolden("canvas-relabel", 300, 150);
}
