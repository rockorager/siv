//! Vulkan renderer tests against the CPU renderer (D24). They need a Vulkan
//! 1.3 device; any is accepted, including lavapipe (mesa-vulkan-drivers),
//! and they are skipped where there is none. With the validation layer
//! installed, any validation error fails them.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const render_cpu = @import("render_cpu");
const pool = @import("pool");
const Device = @import("Device.zig");
const Renderer = @import("Renderer.zig");

const testing = std.testing;
const IRect = raster.IRect;
const Affine = raster.Affine;

fn testDevice() !*Device {
    return @import("vulkan.zig").testDevice(testing.allocator);
}

/// Renders `list` with both renderers and compares them with the golden
/// image tolerance: every channel within 3, at most 0.5% of pixels off by
/// more than 1.
fn expectMatch(r: *Renderer, cpu: *render_cpu.Renderer, list: scene.DisplayList, damage: ?[]const IRect, w: u32, h: u32) !void {
    const gpa = testing.allocator;
    const want = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(got);
    try cpu.render(list, .{ .background = .white, .target = .{ .pixels = want.ptr, .stride = w * 4, .format = .abgr8888 } });
    try r.beginFrame();
    try r.render(list, .{ .background = .white, .damage = damage }, .{ .readback = .{ .pixels = got.ptr, .stride = w * 4 } });
    var worst: u8 = 0;
    var off: usize = 0;
    for (0..w * h) |i| {
        var d: u8 = 0;
        for (0..4) |ch| {
            const a = want[i * 4 + ch];
            const b = got[i * 4 + ch];
            d = @max(d, if (a > b) a - b else b - a);
        }
        worst = @max(worst, d);
        if (d > 1) off += 1;
    }
    if (worst > 3 or off * 200 > w * h) {
        std.debug.print("vulkan vs cpu: max channel difference {d}, {d} pixels off by more than 1\n", .{ worst, off });
        return error.TestExpectedEqual;
    }
}

fn buildScene(b: *scene.Builder, pb: *raster.PathBuilder, frame: u32) !scene.DisplayList {
    b.reset();
    const f: f32 = @floatFromInt(frame);
    const stops = [_]scene.Stop{
        .{ .offset = 0, .color = scene.Color.srgb8(0x20, 0x60, 0xd0, 0xff) },
        .{ .offset = 1, .color = scene.Color.srgb8(0xf0, 0xa0, 0x30, 0xff) },
    };
    try b.fillRect(.xywh(0, 0, 200, 150), .{ .gradient = .{ .geometry = .{ .linear = .{ .p0 = .zero, .p1 = .{ .x = 200, .y = 150 } } }, .stops = &stops } });
    try b.pushLayer(.{ .id = 1, .version = frame, .transform = .translate(20 + f * 7, 30) });
    try b.fillRoundedRect(.xywh(0, 0, 60, 40), .uniform(10, 10), .color(.srgb8(0xff, 0xff, 0xff, 0xc0)));
    try b.popLayer();
    try b.pushLayer(.{ .id = 2, .opacity = 0.6, .clip = .{ .shape = .{ .rounded_rect = .{ .rect = .xywh(90, 10, 100, 80), .radii = .uniform(16, 16) } } } });
    pb.reset();
    try pb.moveTo(80, 90);
    try pb.cubicTo(120, -20, 160, 140, 200, 20);
    try b.stroke(.{ .path = pb.path() }, .{ .width = 9, .join = .round, .cap = .round }, .color(.srgb8(0x10, 0x10, 0x10, 0xff)));
    try b.popLayer();
    try b.pushLayer(.{ .id = 4, .blend = .multiply });
    try b.fillRect(.xywh(150, 100, 40, 40), .color(.srgb8(0xff, 0x40, 0x40, 0xff)));
    try b.popLayer();
    try b.pushLayer(.{ .id = 5 });
    try b.backdropBlur(.{ .rounded_rect = .{ .rect = .xywh(10, 95, 90, 45), .radii = .uniform(8, 8) } }, 4);
    try b.fillRect(.xywh(10, 95, 90, 45), .color(.srgb8(0xff, 0xff, 0xff, 0x30)));
    try b.popLayer();
    return b.finish(0);
}

test "frames match the CPU renderer, including damage-only frames" {
    const gpa = testing.allocator;
    const device = try testDevice();
    defer device.destroy();
    const errors = Device.validation_errors.load(.monotonic);
    var tp = pool.Pool.init(gpa, 3);
    defer tp.deinit();
    const r = try Renderer.create(gpa, device, tp.executor());
    defer r.destroy();
    const cpu = try render_cpu.Renderer.create(gpa, .serial);
    defer cpu.destroy();
    try r.resize(200, 150);
    try cpu.resize(200, 150);

    var b0 = scene.Builder.init(gpa);
    defer b0.deinit();
    var b1 = scene.Builder.init(gpa);
    defer b1.deinit();
    var pb = raster.PathBuilder.init(gpa);
    defer pb.deinit();
    var tracker = scene.damage.Tracker.init(gpa);
    defer tracker.deinit();
    const vp = r.viewport();
    var prev = try buildScene(&b0, &pb, 0);
    _ = try tracker.diff(null, prev, .identity, vp);
    try expectMatch(r, cpu, prev, null, 200, 150);
    const builders = [2]*scene.Builder{ &b0, &b1 };
    for (1..4) |frame| {
        const list = try buildScene(builders[frame % 2], &pb, @intCast(frame));
        const damage = try tracker.diff(prev, list, .identity, vp);
        try expectMatch(r, cpu, list, damage, 200, 150);
        prev = list;
    }
    try testing.expectEqual(errors, Device.validation_errors.load(.monotonic));
}

test "device selection matches dma-buf feedback device numbers" {
    // dev_t 226:128 (/dev/dri/renderD128) in the Linux encoding.
    const dev: u64 = (226 << 8) | 128;
    var dp: @import("vk.zig").c.VkPhysicalDeviceDrmPropertiesEXT = .{ .hasRender = 1, .renderMajor = 226, .renderMinor = 128 };
    try testing.expect(Device.matchesDevice(dp, dev));
    dp.renderMinor = 129;
    try testing.expect(!Device.matchesDevice(dp, dev));
    // Large minors use the high bits.
    const big: u64 = (226 << 8) | (0x12345 & 0xff) | ((0x12345 & ~@as(u64, 0xff)) << 12);
    dp.renderMinor = 0x12345;
    try testing.expect(Device.matchesDevice(dp, big));
}
