//! Image decoding benchmarks: `zig build bench-image -Doptimize=ReleaseFast
//! -- FILE...`, or the test images without arguments.
//!
//! Each file is decoded whole at its own size (every frame of an
//! animation), on one thread as the worker pool does, after a warm-up
//! decode; the best and median of the runs are printed.

const std = @import("std");
const image = @import("image");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    if (@import("builtin").mode == .debug) std.debug.print("warning: build with -Doptimize=ReleaseFast for meaningful numbers\n", .{});
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const defaults = [_][:0]const u8{ "src/image/testdata/still.avif", "src/image/testdata/deep.avif", "src/image/testdata/anim.avif" };
    const files: []const [:0]const u8 = if (args.len > 1) args[1..] else &defaults;
    for (files) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 << 20));
        defer gpa.free(bytes);
        const first = try image.decode(gpa, bytes, .{ .max_bytes = std.math.maxInt(usize) });
        const frames = first.frames.len;
        const w = first.source_width;
        const h = first.source_height;
        first.deinit(gpa);

        var times: [15]u64 = undefined;
        for (&times) |*t| {
            const start = std.Io.Timestamp.now(io, .awake);
            const img = try image.decode(gpa, bytes, .{ .max_bytes = std.math.maxInt(usize) });
            t.* = @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
            img.deinit(gpa);
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        const ms = struct {
            fn f(ns: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
            }
        }.f;
        std.debug.print("{s:<40} {d}x{d} {d:>3} frames  best {d:>8.2} ms  median {d:>8.2} ms\n", .{ std.fs.path.basename(path), w, h, frames, ms(times[0]), ms(times[times.len / 2]) });
    }
}
