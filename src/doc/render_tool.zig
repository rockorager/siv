//! Renders a document to a PNG with the CPU renderer and the system's
//! fonts: `zig build doc-render -- IN OUT [WIDTH] [--markdown] [--dark]`.
//! A development tool for looking at what the renderer does.

const std = @import("std");
const doc = @import("doc");
const scene = @import("scene");
const raster = @import("raster");
const render_cpu = @import("render_cpu");
const pool = @import("pool");
const png = @import("png");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 3) return error.Usage;
    const in = argv[1];
    const out_path = argv[2];
    var ai: usize = 3;
    var width: f32 = 800;
    var kind: doc.Document.Kind = .html;
    var dark = false;
    while (ai < argv.len) : (ai += 1) {
        const a = argv[ai];
        if (std.mem.eql(u8, a, "--markdown")) kind = .markdown else if (std.mem.eql(u8, a, "--dark")) dark = true else width = try std.fmt.parseFloat(f32, a);
    }
    if (std.mem.endsWith(u8, in, ".md")) kind = .markdown;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, in, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    const fonts = try doc.sysfonts.SystemFonts.init(gpa, io);
    defer fonts.deinit();
    var ua = try doc.Document.parseUserAgentSheet(gpa);
    defer ua.deinit();
    const d = try doc.Document.create(gpa, bytes, .{ .kind = kind, .base_url = in }, &ua);
    defer d.destroy();
    try d.styleAndBuild(.{ .width = width, .height = 800, .dark = dark });
    try d.resolveFonts(fonts.resolver());
    _ = try d.layout(&fonts.cache, width, 800, std.math.inf(f32));
    var wanted: std.ArrayList(@import("text").FontId) = .empty;
    defer wanted.deinit(gpa);
    try d.wantedFonts(&wanted);
    if (wanted.items.len > 0) {
        for (wanted.items) |id| fonts.load(id);
        d.fontsLoaded();
        _ = try d.layout(&fonts.cache, width, 800, std.math.inf(f32));
    }
    const h: u32 = @intFromFloat(@min(8000, @max(100, @ceil(d.height()))));
    const w: u32 = @intFromFloat(width);
    var b: scene.Builder = .init(gpa);
    defer b.deinit();
    const Hooks = struct {
        fn draw(_: *anyopaque, _: *scene.Builder, _: u32, _: raster.Rect, _: f32) scene.Error!bool {
            return false;
        }
        fn size(_: *anyopaque, _: []const u8) ?[2]f32 {
            return null;
        }
        fn image(_: *anyopaque, _: *scene.Builder, _: []const u8, _: raster.Rect, _: raster.Rect) scene.Error!void {}
        fn marker(ctx: *anyopaque, i: u32) ?*const doc.paint.MarkerGlyphs {
            const dd: *doc.Document = @ptrCast(@alignCast(ctx));
            return dd.markerGlyphs(i);
        }
    };
    var palette: doc.Palette = .{};
    if (dark) {
        palette.canvas = .rgb8(0x1e, 0x1e, 0x1e);
        palette.canvas_text = .rgb8(0xe8, 0xe8, 0xe8);
        palette.link = .rgb8(0x78, 0xae, 0xed);
    }
    try d.paint(&b, 0, @floatFromInt(h), palette, .{ .ctx = d, .drawReplaced = Hooks.draw, .imageSize = Hooks.size, .drawImage = Hooks.image, .marker = Hooks.marker }, &.{});
    const list = try b.finish(0);
    var workers = pool.Pool.init(gpa, 3);
    defer workers.deinit();
    const r = try render_cpu.Renderer.create(gpa, workers.executor());
    defer r.destroy();
    try r.resize(w, h);
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(px);
    try r.render(list, .{ .background = .white, .target = .{ .pixels = px.ptr, .stride = w * 4, .format = .abgr8888 } });
    const encoded = try png.encode(gpa, w, h, px);
    defer gpa.free(encoded);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = encoded });
}
