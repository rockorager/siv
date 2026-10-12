//! Headless text engine benchmarks: `zig build bench-text -Doptimize=ReleaseFast`.
//!
//! Each stage runs on the same workloads with a scratch arena reset per
//! iteration, the way a layout pass uses the engine. Fonts are the bundled
//! Droid Sans test fonts, so results do not depend on the machine's fonts.

const std = @import("std");
const text = @import("text");

const Workload = struct { name: []const u8, text: []const u8 };

const pangram = "The quick brown fox jumps over the lazy dog. ";

fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime var result: []const u8 = "";
    inline for (0..n) |_| result = result ++ s;
    return result;
}
const workloads = [_]Workload{
    .{ .name = "label", .text = "Save changes" },
    .{ .name = "latin", .text = repeat(pangram, 4) },
    .{ .name = "mixed", .text = repeat("Status: جاهز — build 42 (successful). نص عربي مع English في المنتصف. ", 2) },
    .{ .name = "hebrew", .text = "פסקה ראשונה עם מילים בעברית, ועוד קצת טקסט לשבירת שורות.\nשנייה with Latin." },
    .{ .name = "long", .text = repeat(pangram, 64) },
};

var sink: usize = 0;

const Bench = struct {
    io: std.Io,
    arena: std.heap.ArenaAllocator,

    fn run(self: *Bench, label: []const u8, workload: Workload, iterations: usize, context: anytype, comptime body: fn (@TypeOf(context), std.mem.Allocator, []const u8) anyerror!usize) !void {
        // Warm up, then time.
        for (0..@max(1, iterations / 10)) |_| {
            sink +%= try body(context, self.arena.allocator(), workload.text);
            _ = self.arena.reset(.retain_capacity);
        }
        const start = std.Io.Timestamp.now(self.io, .awake);
        for (0..iterations) |_| {
            sink +%= try body(context, self.arena.allocator(), workload.text);
            _ = self.arena.reset(.retain_capacity);
        }
        const elapsed = start.durationTo(std.Io.Timestamp.now(self.io, .awake)).toNanoseconds();
        const per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        std.debug.print("  {s:<22} {s:<7} {d:>11.0} ns/op {d:>8.2} ns/byte\n", .{ label, workload.name, per_op, per_op / @as(f64, @floatFromInt(@max(1, workload.text.len))) });
    }
};

const Fonts = struct {
    cache: *const text.FontCache,
    fonts: []const text.FontId,
    paragraph: *const text.ShapedParagraph = undefined,
    width: f32 = 0,
};

fn lineBreaks(_: void, a: std.mem.Allocator, input: []const u8) !usize {
    return (try text.line_break.analyze(a, input)).len;
}

fn segmentation(_: void, a: std.mem.Allocator, input: []const u8) !usize {
    const graphemes = try text.segmentation.graphemes(a, input);
    const words = try text.segmentation.words(a, input);
    return graphemes.masks.len + words.boundaries.masks.len;
}

fn bidi(_: void, a: std.mem.Allocator, input: []const u8) !usize {
    return (try text.bidi.analyze(a, input, .auto_ltr)).paragraphs.len;
}

fn scripts(_: void, a: std.mem.Allocator, input: []const u8) !usize {
    const graphemes = try text.segmentation.graphemes(a, input);
    return (try text.script.analyze(a, input, graphemes, 0, @intCast(input.len))).len;
}

fn shaped(fonts: Fonts, a: std.mem.Allocator, input: []const u8) !usize {
    var p = try text.ShapedParagraph.init(a, a, fonts.cache, input, &.{.{ .end = @intCast(input.len), .style = .{ .fonts = fonts.fonts, .size = 16 } }}, .auto_ltr);
    defer p.deinit();
    return p.glyphs.len;
}

fn layout(fonts: Fonts, a: std.mem.Allocator, _: []const u8) !usize {
    var l = try text.Layout.init(a, a, fonts.cache, fonts.paragraph, .{ .width = fonts.width });
    defer l.deinit();
    return l.lines.len;
}

fn queries(l: *const text.Layout, _: std.mem.Allocator, _: []const u8) !usize {
    var total: usize = 0;
    var position: text.Layout.Position = .{ .offset = 0 };
    for (0..64) |i| {
        position = l.moveVisual(position, .right);
        const hit = l.hitTest(@floatFromInt(i * 7), @floatFromInt(i * 3));
        total += position.offset + hit.offset + l.nextWordEnd(hit.offset);
    }
    return total;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    if (@import("builtin").mode == .debug) std.debug.print("warning: build with -Doptimize=ReleaseFast for meaningful numbers\n", .{});
    var bench: Bench = .{ .io = init.io, .arena = .init(gpa) };
    defer bench.arena.deinit();

    var cache: text.FontCache = .init(gpa);
    defer cache.deinit();
    const fonts = [_]text.FontId{
        try cache.add(text.font.test_fonts.latin, 0, .borrowed),
        try cache.add(text.font.test_fonts.arabic, 0, .borrowed),
        try cache.add(text.font.test_fonts.hebrew, 0, .borrowed),
    };

    std.debug.print("analysis\n", .{});
    for (workloads) |w| try bench.run("UAX #14 opportunities", w, 2000, {}, lineBreaks);
    for (workloads) |w| try bench.run("UAX #29 boundaries", w, 2000, {}, segmentation);
    for (workloads) |w| try bench.run("UAX #9 levels", w, 2000, {}, bidi);
    for (workloads) |w| try bench.run("script runs", w, 2000, {}, scripts);

    std.debug.print("ShapedParagraph (everything width-independent)\n", .{});
    for (workloads) |w| try bench.run("build", w, 500, Fonts{ .cache = &cache, .fonts = &fonts }, shaped);

    std.debug.print("Layout (a width change)\n", .{});
    for (workloads) |w| {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var p = try text.ShapedParagraph.init(gpa, scratch.allocator(), &cache, w.text, &.{.{ .end = @intCast(w.text.len), .style = .{ .fonts = &fonts, .size = 16 } }}, .auto_ltr);
        defer p.deinit();
        for ([_]f32{ 600, 200 }) |width| {
            var label: [32]u8 = undefined;
            try bench.run(try std.fmt.bufPrint(&label, "width {d}", .{width}), w, 2000, Fonts{ .cache = &cache, .fonts = &fonts, .paragraph = &p, .width = width }, layout);
        }
        var l = try text.Layout.init(gpa, scratch.allocator(), &cache, &p, .{ .width = 200 });
        defer l.deinit();
        try bench.run("64 caret queries", w, 2000, &l, queries);
    }
    std.mem.doNotOptimizeAway(sink);
}
