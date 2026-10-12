//! Compositor golden images (D24): layer trees composed and presented by
//! the compositor thread on the headless backend, through the real worker
//! pool, swapchain, and buffer-age path. Compared with PNGs under
//! test/golden/compositor/ with the CPU renderer's tolerance.
//!
//!     SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const scene = @import("scene");
const raster = @import("raster");
const platform = @import("platform");
const compositor = @import("compositor");
const png = @import("../render/png.zig");
const Ui = @import("harness.zig").Ui;

const Op = compositor.Op;
const Color = scene.Color;
const testing = std.testing;

const golden_dir = "test/golden/compositor";
const failure_dir = ".zig-cache/golden-failures";

const gray = Color.srgb8(0xe5, 0xe7, 0xeb, 0xff);
const blue = Color.srgb8(0x25, 0x63, 0xeb, 0xff);
const orange = Color.srgb8(0xf5, 0x9e, 0x0b, 0xff);
const green = Color.srgb8(0x10, 0xb9, 0x81, 0xff);
const pink = Color.srgb8(0xec, 0x48, 0x99, 0xff);

/// A 200x150 scene: a background, a rounded translucent card, a rotated
/// square, and a scroll container scrolled by 30 px.
fn sceneOps(ui: *Ui, ops: *std.ArrayList(Op)) !void {
    var b = ui.builder();
    try b.fillRect(.xywh(0, 0, 200, 150), .color(gray));
    try ops.appendSlice(ui.gpa, &.{
        .{ .create = 1 },
        .{ .set_root = 1 },
        .{ .set_background = .white },
        .{ .set_content = .{ .layer = 1, .content = try Ui.content(b) } },
    });

    b = ui.builder();
    try b.fillRect(.xywh(0, 0, 90, 60), .color(blue));
    try b.fillRect(.xywh(0, 40, 90, 8), .color(orange));
    try ops.appendSlice(ui.gpa, &.{
        .{ .create = 2 },
        .{ .insert = .{ .layer = 2, .parent = 1 } },
        .{ .set_content = .{ .layer = 2, .content = try Ui.content(b) } },
        .{ .set_transform = .{ .layer = 2, .transform = .offset(15, 15) } },
        .{ .set_clip = .{ .layer = 2, .clip = .{ .rect = .xywh(0, 0, 90, 60), .radii = .uniform(14, 14) } } },
        .{ .set_opacity = .{ .layer = 2, .opacity = 0.8 } },
    });

    b = ui.builder();
    try b.fillRect(.xywh(0, 0, 40, 40), .color(green));
    try ops.appendSlice(ui.gpa, &.{
        .{ .create = 3 },
        .{ .insert = .{ .layer = 3, .parent = 1 } },
        .{ .set_content = .{ .layer = 3, .content = try Ui.content(b) } },
        .{ .set_transform = .{ .layer = 3, .transform = .{
            .translate = .{ .x = 130, .y = 20 },
            .rotate = 0.4,
            .origin = .{ .x = 20, .y = 20 },
        } } },
    });

    b = ui.builder();
    for (0..10) |i| {
        const y: f32 = @floatFromInt(i * 20);
        try b.fillRect(.xywh(0, y, 170, 20), .color(if (i % 2 == 0) pink else blue));
    }
    try ops.appendSlice(ui.gpa, &.{
        .{ .create = 4 },
        .{ .create = 5 },
        .{ .insert = .{ .layer = 4, .parent = 1 } },
        .{ .insert = .{ .layer = 5, .parent = 4 } },
        .{ .set_transform = .{ .layer = 4, .transform = .offset(15, 85) } },
        .{ .set_scroll = .{ .layer = 4, .scroll = .{ .viewport = .xywh(0, 0, 170, 50), .content = .{ .width = 170, .height = 200 } } } },
        .{ .set_content = .{ .layer = 5, .content = try Ui.content(b) } },
        .{ .scroll_to = .{ .layer = 4, .offset = .{ .x = 0, .y = 30 } } },
    });
}

fn expectGolden(ui: *Ui, window: platform.WindowId, name: []const u8, width: u32, height: u32) !void {
    const gpa = ui.gpa;
    const io = testing.io;
    const got = try ui.capture(window);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, width) * height * 4, got.len);
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ golden_dir, name });
    defer gpa.free(path);
    if (testing.environ.getPosix("SIV_UPDATE_GOLDEN") != null) {
        const bytes = try png.encode(gpa, width, height, got);
        defer gpa.free(bytes);
        try std.Io.Dir.cwd().createDirPath(io, golden_dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        return;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    const want = try png.decode(gpa, bytes);
    defer want.deinit(gpa);
    try testing.expectEqual(width, want.width);
    try testing.expectEqual(height, want.height);
    // Every channel within 3, at most 0.5% of pixels off by more than 1.
    var worst: u8 = 0;
    var off: usize = 0;
    for (want.pixels, got) |a, b| {
        const d = if (a > b) a - b else b - a;
        worst = @max(worst, d);
        if (d > 1) off += 1;
    }
    if (worst <= 3 and off * 200 <= got.len / 4) return;
    std.debug.print("golden {s}: max channel difference {d}, {d} channels off by more than 1\n", .{ name, worst, off });
    try std.Io.Dir.cwd().createDirPath(io, failure_dir);
    const actual = try png.encode(gpa, width, height, got);
    defer gpa.free(actual);
    const out = try std.fmt.allocPrint(gpa, "{s}/{s}-actual.png", .{ failure_dir, name });
    defer gpa.free(out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = actual });
    return error.GoldenMismatch;
}

test "compositor golden images: layers, two windows at two scales, after an animation" {
    var ui: Ui = .{};
    try ui.start(true, .{ .headless = .{ .refresh_ns = 4 * std.time.ns_per_ms } });
    defer ui.stop();

    // Two windows with the same tree; the second at scale 2.
    const a = try ui.comp.createWindow(.{ .width = 200, .height = 150 });
    const b = try ui.comp.createWindow(.{ .width = 200, .height = 150 });
    const Scale = struct {
        fn f(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            comp.platform.headless.setScale(@intCast(@intFromPtr(ctx) - 1), .int(2));
        }
    };
    try ui.comp.call(@ptrFromInt(b + 1), Scale.f);
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(ui.gpa);
    for ([_]platform.WindowId{ a, b }) |w| {
        ops.clearRetainingCapacity();
        try sceneOps(&ui, &ops);
        _ = try ui.commit(w, ops.items);
    }
    try ui.waitSettled(a);
    try ui.waitSettled(b);
    try expectGolden(&ui, a, "layers", 200, 150);
    try expectGolden(&ui, b, "layers-2x", 400, 300);

    // Animations on the compositor thread end where they are told to.
    _ = try ui.commit(a, &.{
        .{ .animate = .{ .layer = 3, .animation = .{ .to = .{ .transform = .{
            .translate = .{ .x = 110, .y = 10 },
            .rotate = 0,
            .scale = .{ .x = 1.5, .y = 1.5 },
            .origin = .{ .x = 20, .y = 20 },
        } }, .duration_ns = 30 * std.time.ns_per_ms } } },
        .{ .animate = .{ .layer = 2, .animation = .{ .to = .{ .opacity = 0.4 }, .duration_ns = 20 * std.time.ns_per_ms } } },
        .{ .animate = .{ .layer = 4, .animation = .{ .to = .{ .scroll = .{ .x = 0, .y = 150 } }, .duration_ns = 25 * std.time.ns_per_ms } } },
    });
    try ui.run(&ui, struct {
        fn f(x: *Ui) bool {
            return x.count(.animation_finished) == 3;
        }
    }.f);
    // The scroll animation's target was clamped to the extent (150).
    try testing.expectEqual(@as(f32, 150), ui.last(.scrolled).?.scrolled.offset.y);
    try expectGolden(&ui, a, "animated", 200, 150);

    // Teardown of one window releases its content and leaves the other.
    try ui.comp.destroyWindow(b);
    try ui.run(&ui, struct {
        fn f(x: *Ui) bool {
            return x.free.items.len == x.builders.len - 4;
        }
    }.f);
    try expectGolden(&ui, a, "animated", 200, 150);
}
