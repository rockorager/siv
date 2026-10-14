//! Vulkan renderer against the CPU golden images (D10, D24): every scene in
//! golden.zig renders through the Vulkan renderer and must match the CPU
//! renderer's PNG under test/golden/render/ with the same tolerance.
//!
//! Any Vulkan 1.3 device is accepted, including lavapipe (mesa-vulkan-
//! drivers, installed by .agents/setup); without one the test is skipped.
//! With the validation layer installed, validation errors fail it. On a
//! mismatch the actual image and a diff are written to
//! .zig-cache/golden-failures/vulkan-<name>-*.png.

const std = @import("std");
const scene = @import("scene");
const raster = @import("raster");
const pool = @import("pool");
const render_vulkan = @import("render_vulkan");
const golden = @import("golden.zig");
const png = @import("png");

const Device = render_vulkan.Device;
const Renderer = render_vulkan.Renderer;

test "vulkan matches the CPU golden images" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const device = try render_vulkan.testDevice(gpa);
    defer device.destroy();
    const errors = Device.validation_errors.load(.monotonic);

    var ctx: golden.Ctx = .{
        .gpa = gpa,
        .pb = .init(gpa),
        .roboto = .init(@embedFile("../golden/fonts/Roboto-Regular.ttf"), 1),
        .colr = .init(@embedFile("../golden/fonts/test_glyphs-glyf_colr_1.ttf"), 2),
    };
    defer ctx.deinit();
    var workers = pool.Pool.init(gpa, 3);
    defer workers.deinit();
    const r = try Renderer.create(gpa, device, workers.executor());
    defer r.destroy();
    var b = scene.Builder.init(gpa);
    defer b.deinit();

    var failures: usize = 0;
    for (golden.cases) |case| {
        b.reset();
        try case.build(&ctx, &b);
        const list = try b.finish(0);
        try r.resize(case.width, case.height);
        const out = try gpa.alloc(u8, @as(usize, case.width) * case.height * 4);
        defer gpa.free(out);
        try r.beginFrame();
        try r.render(list, .{ .background = .white }, .{ .readback = .{ .pixels = out.ptr, .stride = case.width * 4 } });

        const path = try std.fmt.allocPrint(gpa, "test/golden/render/{s}.png", .{case.name});
        defer gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
        defer gpa.free(bytes);
        const want = try png.decode(gpa, bytes);
        defer want.deinit(gpa);
        var named = case;
        named.name = try std.fmt.allocPrint(gpa, "vulkan-{s}", .{case.name});
        defer gpa.free(named.name);
        if (!try golden.compare(gpa, io, named, want, out)) failures += 1;
        // Each glyph atlas is made with its first glyph: the 8 MiB color
        // atlas waits for the first color glyph (colr comes after text).
        if (std.mem.eql(u8, case.name, "text")) {
            try std.testing.expect(r.glyph_masks.image.handle != null);
            try std.testing.expect(r.glyph_colors.image.handle == null);
        }
        if (std.mem.eql(u8, case.name, "colr")) try std.testing.expect(r.glyph_colors.image.handle != null);
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expectEqual(errors, Device.validation_errors.load(.monotonic));
}
