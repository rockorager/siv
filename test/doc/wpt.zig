//! web-platform-tests CSS reftests (D32), imported by test/wpt/import.py:
//! each test and its reference are rendered at 800×600 through the
//! document renderer and siv's CPU renderer and compared; the pass rate
//! per suite must not fall below the one recorded here (and in DESIGN.md).
//! Fonts: Ahem from WPT for `font-family: Ahem`, siv's Droid test font for
//! everything else. SIV_WPT_VERBOSE=1 prints the failures.

const std = @import("std");
const doc = @import("doc");
const css = @import("css");
const text = @import("text");
const scene = @import("scene");
const raster = @import("raster");
const render_cpu = @import("render_cpu");
const pool = @import("pool");
const png = @import("png");

const testing = std.testing;
const Document = doc.Document;
const W = 800;
const H = 600;
const root = "test/wpt";
const origin = "http://wpt";

/// Passing tests per suite, recorded: fewer fails the test.
const floors = .{
    .{ "css2", 223 },
    .{ "css-flexbox", 209 },
    .{ "css-grid", 58 },
    .{ "css-values", 56 },
    .{ "css-variables", 46 },
};

const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cache: text.FontCache,
    ua: css.Sheet,
    droid: [1]text.FontId = undefined,
    ahem: [1]text.FontId = undefined,
    ahem_bytes: []u8,
    workers: pool.Pool,
    renderer: *render_cpu.Renderer,
    pixels: [2][]u8,

    fn init(gpa: std.mem.Allocator, io: std.Io) !*Runner {
        const r = try gpa.create(Runner);
        r.* = .{
            .gpa = gpa,
            .io = io,
            .cache = .init(gpa),
            .ua = try Document.parseUserAgentSheet(gpa),
            .ahem_bytes = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/fonts/Ahem.ttf", gpa, .limited(1 << 20)),
            .workers = pool.Pool.init(gpa, 2),
            .renderer = undefined,
            .pixels = .{ try gpa.alloc(u8, W * H * 4), try gpa.alloc(u8, W * H * 4) },
        };
        try r.cache.addLastResort();
        r.droid = .{try r.cache.add(text.font.test_fonts.latin, 0, .borrowed)};
        r.ahem = .{try r.cache.add(r.ahem_bytes, 0, .borrowed)};
        r.renderer = try render_cpu.Renderer.create(gpa, r.workers.executor());
        try r.renderer.resize(W, H);
        return r;
    }

    fn deinit(r: *Runner) void {
        r.renderer.destroy();
        r.workers.deinit();
        r.ua.deinit();
        r.cache.deinit();
        r.gpa.free(r.ahem_bytes);
        for (r.pixels) |p| r.gpa.free(p);
        r.gpa.destroy(r);
    }

    fn chainFn(ctx: *anyopaque, family: []const u8, _: []const u8, _: u16, _: bool, _: f32, _: f32) Document.Error![]const text.FontId {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        return if (std.ascii.eqlIgnoreCase(family, "ahem")) &r.ahem else &r.droid;
    }

    /// The file a URL of the WPT server names.
    fn file(r: *Runner, url: []const u8) ?[]u8 {
        if (!std.mem.startsWith(u8, url, origin)) return null;
        var path = url[origin.len..];
        if (std.mem.indexOfAny(u8, path, "?#")) |k| path = path[0..k];
        const full = std.fmt.allocPrint(r.gpa, root ++ "{s}", .{path}) catch return null;
        defer r.gpa.free(full);
        return std.Io.Dir.cwd().readFileAlloc(r.io, full, r.gpa, .limited(1 << 20)) catch null;
    }

    /// Renders a WPT file (its path from the WPT root) into `out`.
    fn render(r: *Runner, path: []const u8, out: []u8) !void {
        const base = try std.fmt.allocPrint(r.gpa, origin ++ "/{s}", .{path});
        defer r.gpa.free(base);
        const src = r.file(base) orelse return error.Missing;
        defer r.gpa.free(src);
        const d = try Document.create(r.gpa, src, .{ .base_url = base }, &r.ua);
        defer d.destroy();
        const env: css.media.Env = .{ .width = W, .height = H };
        try d.styleAndBuild(env);
        // Style sheets, as many rounds as imports go deep; fonts are
        // resolved by name instead.
        var round: usize = 0;
        while (round < 4) : (round += 1) {
            var supplied = false;
            for (d.resources.items, 0..) |res, i| {
                if (res.state != .wanted) continue;
                if (res.kind != .stylesheet) {
                    d.failResource(@intCast(i));
                    continue;
                }
                if (r.file(res.url)) |bytes| {
                    defer r.gpa.free(bytes);
                    try d.supplyStylesheet(@intCast(i), bytes);
                    supplied = true;
                } else d.failResource(@intCast(i));
            }
            if (!supplied) break;
            try d.styleAndBuild(env);
        }
        try d.resolveFonts(.{ .ctx = r, .cache = &r.cache, .chainFn = chainFn });
        _ = try d.layout(&r.cache, W, H, std.math.inf(f32));
        var b: scene.Builder = .init(r.gpa);
        defer b.deinit();
        try d.paint(&b, 0, H, .{}, .{ .ctx = d, .drawReplaced = noReplaced, .imageSize = noSize, .drawImage = noImage, .marker = marker }, &.{});
        const list = try b.finish(0);
        try r.renderer.render(list, .{ .background = .white, .target = .{ .pixels = out.ptr, .stride = W * 4, .format = .abgr8888 } });
    }

    fn noReplaced(_: *anyopaque, _: *scene.Builder, _: u32, _: raster.Rect, _: f32) scene.Error!bool {
        return false;
    }
    fn noSize(_: *anyopaque, _: []const u8) ?[2]f32 {
        return null;
    }
    fn noImage(_: *anyopaque, _: *scene.Builder, _: []const u8, _: raster.Rect, _: raster.Rect) scene.Error!void {}
    fn marker(ctx: *anyopaque, i: u32) ?*const doc.paint.MarkerGlyphs {
        const d: *Document = @ptrCast(@alignCast(ctx));
        return d.markerGlyphs(i);
    }

    /// Whether the two renders match: at most 20 pixels differ by more
    /// than 32 in a channel (antialiasing of the same edges drawn as
    /// glyphs in one and boxes in the other).
    fn same(r: *Runner) bool {
        var off: usize = 0;
        var i: usize = 0;
        while (i < W * H * 4) : (i += 4) {
            for (0..3) |c| {
                const a = r.pixels[0][i + c];
                const b = r.pixels[1][i + c];
                if ((if (a > b) a - b else b - a) > 32) {
                    off += 1;
                    break;
                }
            }
        }
        return off <= 20;
    }
};

fn runSuite(comptime suite: []const u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/MANIFEST", gpa, .limited(1 << 20));
    defer gpa.free(manifest);
    const r = try Runner.init(gpa, io);
    defer r.deinit();
    const verbose = testing.environ.getPosix("SIV_WPT_VERBOSE") != null;
    const dump = testing.environ.getPosix("SIV_WPT_DUMP");
    var total: usize = 0;
    var passed: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, parts.next() orelse continue, suite)) continue;
        const test_path = parts.next() orelse continue;
        const ref_path = parts.next() orelse continue;
        total += 1;
        const ok = blk: {
            r.render(test_path, r.pixels[0]) catch break :blk false;
            r.render(ref_path, r.pixels[1]) catch break :blk false;
            break :blk r.same();
        };
        if (ok) {
            passed += 1;
        } else {
            if (verbose) std.debug.print("WPT FAIL {s}\n", .{test_path});
            if (dump) |dir| {
                for (r.pixels, [_][]const u8{ "test", "ref" }) |px, which| {
                    const enc = try png.encode(gpa, W, H, px);
                    defer gpa.free(enc);
                    const name = try std.fmt.allocPrint(gpa, "{s}/{s}.{s}.png", .{ dir, std.fs.path.basename(test_path), which });
                    defer gpa.free(name);
                    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = enc }) catch {};
                }
            }
        }
    }
    if (verbose or testing.environ.getPosix("SIV_WPT_RATES") != null) std.debug.print("WPT {s}: {d}/{d}\n", .{ suite, passed, total });
    inline for (floors) |f| if (comptime std.mem.eql(u8, f[0], suite)) try testing.expect(passed >= f[1]);
    try testing.expect(total > 0);
}

test "WPT css2 reftests" {
    try runSuite("css2");
}

test "WPT css-flexbox reftests" {
    try runSuite("css-flexbox");
}

test "WPT css-grid reftests" {
    try runSuite("css-grid");
}

test "WPT css-values reftests" {
    try runSuite("css-values");
}

test "WPT css-variables reftests" {
    try runSuite("css-variables");
}
