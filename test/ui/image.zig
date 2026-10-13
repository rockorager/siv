//! Streamed animations end to end on the headless backend (D19): an
//! animation over its memory budget plays in an image node frame by
//! frame from its file, loops by decoding it again, and frees everything
//! when the window goes away.

const std = @import("std");
const ui = @import("ui");
const App = @import("harness.zig").App;

const testing = std.testing;

const Loaded = struct {
    img: ?*ui.Image = null,
    done: bool = false,
    fn func(ctx: ?*anyopaque, r: ui.Image.LoadError!*ui.Image) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.img = r catch null;
        self.done = true;
    }
};

fn pixel(app: *App, x: usize, y: usize) ![4]u8 {
    const p = try app.presented();
    defer app.gpa.free(p.rgba);
    return p.rgba[(y * p.width + x) * 4 ..][0..4].*;
}

test "a streamed animation plays frame by frame and loops" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 32, .height = 32 });
    defer app.deinit();
    app.win.force_reduced_motion = false;

    // Red, green, blue, 16 × 16, shown for 100, 200, and 300 ms, looping;
    // a budget of one frame streams it.
    var loaded: Loaded = .{};
    try ui.Image.load(&app.pool, app.gpa, .{ .path = "src/image/testdata/anim.gif" }, .{
        .decode = .{ .max_bytes = 16 * 16 * 4 },
    }, .{ .ctx = &loaded, .func = Loaded.func });
    while (!loaded.done) try app.loop.dispatch(-1);
    const img = loaded.img.?;
    defer img.release();
    try testing.expect(img.stream != null);
    try testing.expectEqual(@as(u32, 3), img.frame_count);
    try testing.expectEqual(@as(usize, 0), img.frames.len);

    const t = try app.win.begin();
    const node = try t.create(.root, .image, .none);
    try t.setImage(node, .{ .image = img });
    t.commit();
    try app.settle();

    // Watch the colors go by: two loops' worth, the second decoded again
    // after the decoder rewinds.
    const red = [4]u8{ 255, 0, 0, 255 };
    const green = [4]u8{ 0, 255, 0, 255 };
    const blue = [4]u8{ 0, 0, 255, 255 };
    var seen: [5][4]u8 = undefined;
    seen[0] = try pixel(&app, 4, 4);
    var n: usize = 1;
    const Loop = @import("loop").Loop;
    const deadline = Loop.now() + 5 * std.time.ns_per_s;
    while (n < seen.len and Loop.now() < deadline) {
        try app.loop.dispatch(5);
        try app.settle();
        const px = try pixel(&app, 4, 4);
        if (!std.mem.eql(u8, &px, &seen[n - 1])) {
            seen[n] = px;
            n += 1;
        }
    }
    try testing.expectEqual(seen.len, n);
    try testing.expectEqualSlices([4]u8, &.{ red, green, blue, red, green }, &seen);
    // The window goes away while its player decodes ahead: the testing
    // allocator checks that the player, its frames, and the file are freed.
}
