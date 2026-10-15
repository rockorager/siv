//! Renders documents for the document renderer's tests (D32): siv's
//! Droid test fonts (and Ahem by name, for WPT), style sheets read from a
//! directory standing for a server, painted with the CPU renderer.

const std = @import("std");
const doc = @import("doc");
const css = @import("css");
const text = @import("text");
const scene = @import("scene");
const raster = @import("raster");
const render_cpu = @import("render_cpu");
const pool = @import("pool");

const Document = doc.Document;

pub const Runner = struct {
    /// The directory standing for `origin`.
    root: []const u8,
    origin: []const u8,
    width: u32,
    height: u32,
    /// Email: untrusted HTML with quoted replies collapsed (or opened).
    untrusted: bool = false,
    collapse_quotes: bool = false,
    open_quotes: bool = false,
    /// Remote content (the server's style sheets) loads.
    remote: bool = true,
    gpa: std.mem.Allocator,
    io: std.Io,
    cache: text.FontCache,
    ua: css.Sheet,
    droid: [3]text.FontId = undefined,
    ahem: [1]text.FontId = undefined,
    ahem_bytes: []u8,
    workers: pool.Pool,
    renderer: *render_cpu.Renderer,
    pixels: [2][]u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: []const u8, origin: []const u8, width: u32, height: u32) !*Runner {
        const r = try gpa.create(Runner);
        r.* = .{
            .root = root,
            .origin = origin,
            .width = width,
            .height = height,
            .gpa = gpa,
            .io = io,
            .cache = .init(gpa),
            .ua = try Document.parseUserAgentSheet(gpa),
            .ahem_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/wpt/fonts/Ahem.ttf", gpa, .limited(1 << 20)),
            .workers = pool.Pool.init(gpa, 2),
            .renderer = undefined,
            .pixels = .{ try gpa.alloc(u8, @as(usize, width) * height * 4), try gpa.alloc(u8, @as(usize, width) * height * 4) },
        };
        try r.cache.addLastResort();
        r.droid = .{
            try r.cache.add(text.font.test_fonts.latin, 0, .borrowed),
            try r.cache.add(text.font.test_fonts.arabic, 0, .borrowed),
            try r.cache.add(text.font.test_fonts.hebrew, 0, .borrowed),
        };
        r.ahem = .{try r.cache.add(r.ahem_bytes, 0, .borrowed)};
        r.renderer = try render_cpu.Renderer.create(gpa, r.workers.executor());
        try r.renderer.resize(width, height);
        return r;
    }

    pub fn deinit(r: *Runner) void {
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
    pub fn file(r: *Runner, url: []const u8) ?[]u8 {
        if (!std.mem.startsWith(u8, url, r.origin)) return null;
        var path = url[r.origin.len..];
        if (std.mem.indexOfAny(u8, path, "?#")) |k| path = path[0..k];
        const full = std.fmt.allocPrint(r.gpa, "{s}{s}", .{ r.root, path }) catch return null;
        defer r.gpa.free(full);
        return std.Io.Dir.cwd().readFileAlloc(r.io, full, r.gpa, .limited(1 << 20)) catch null;
    }

    /// Renders a file (its path from the root) into `out`, from the top
    /// (`top`: document y) of the document.
    pub fn render(r: *Runner, path: []const u8, kind: Document.Kind, top: f32, out: []u8) !void {
        const base = try std.fmt.allocPrint(r.gpa, "{s}/{s}", .{ r.origin, path });
        defer r.gpa.free(base);
        const src = r.file(base) orelse return error.Missing;
        defer r.gpa.free(src);
        const d = try Document.create(r.gpa, src, .{ .base_url = base, .kind = kind, .remote_images = r.remote, .untrusted = r.untrusted, .collapse_quotes = r.collapse_quotes }, &r.ua);
        if (r.open_quotes) for (0..d.quotes.len) |k| {
            _ = d.toggleQuote(k);
        };
        defer d.destroy();
        const W: f32 = @floatFromInt(r.width);
        const H: f32 = @floatFromInt(r.height);
        const env: css.media.Env = .{ .width = W, .height = H };
        try d.styleAndBuild(env);
        // Style sheets, as many rounds as imports go deep; fonts are
        // resolved by name instead.
        var round: usize = 0;
        while (round < 4) : (round += 1) {
            var supplied = false;
            for (d.resources.items, 0..) |res, i| {
                if (res.state != .wanted) continue;
                if (res.kind == .image and std.mem.startsWith(u8, res.url, "cid:")) {
                    // An email's part, as SVG under cid/.
                    const part = try std.fmt.allocPrint(r.gpa, "{s}/cid/{s}", .{ r.root, res.url[4..] });
                    defer r.gpa.free(part);
                    const bytes = std.Io.Dir.cwd().readFileAlloc(r.io, part, r.gpa, .limited(1 << 20)) catch {
                        d.failResource(@intCast(i));
                        continue;
                    };
                    defer r.gpa.free(bytes);
                    try d.supplySvg(@intCast(i), bytes);
                    continue;
                }
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
        try b.pushLayer(.{ .transform = raster.Affine.translate(0, -top) });
        try d.paint(&b, top, top + H, .{}, .{ .ctx = d, .drawReplaced = noReplaced, .imageSize = noSize, .drawImage = noImage, .marker = marker }, &.{});
        try b.popLayer();
        const list = try b.finish(0);
        try r.renderer.render(list, .{ .background = .white, .target = .{ .pixels = out.ptr, .stride = r.width * 4, .format = .abgr8888 } });
    }

    fn noReplaced(ctx: *anyopaque, b: *scene.Builder, resource: u32, dst: raster.Rect, _: f32) scene.Error!bool {
        const d: *Document = @ptrCast(@alignCast(ctx));
        const res = d.resources.items[resource];
        const sd = res.svg_doc orelse return false;
        try sd.draw(b, dst, null);
        return true;
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
    pub fn same(r: *Runner) bool {
        return r.within(32, 20);
    }

    /// `same`, widened by a WPT test's fuzzy metadata
    /// (`<meta name=fuzzy content="maxDifference=0-40;totalPixels=0-300">`)
    /// when it allows larger differences than `same` does.
    pub fn sameAs(r: *Runner, test_path: []const u8) bool {
        const base = std.fmt.allocPrint(r.gpa, "{s}/{s}", .{ r.origin, test_path }) catch return r.same();
        defer r.gpa.free(base);
        const src = r.file(base) orelse return r.same();
        defer r.gpa.free(src);
        const f = fuzzy(src) orelse return r.same();
        if (f[0] <= 32) return r.same();
        return r.within(f[0], @max(20, f[1]));
    }

    /// The upper bounds of a fuzzy annotation: the largest channel
    /// difference and the number of pixels that may differ.
    pub fn fuzzy(src: []const u8) ?[2]u32 {
        const at = std.mem.indexOf(u8, src, "name=\"fuzzy\"") orelse std.mem.indexOf(u8, src, "name=fuzzy") orelse return null;
        const tag_end = std.mem.indexOfScalarPos(u8, src, at, '>') orelse return null;
        const tag_start = std.mem.lastIndexOfScalar(u8, src[0..at], '<') orelse return null;
        const tag = src[tag_start..tag_end];
        const c = std.mem.indexOf(u8, tag, "content=") orelse return null;
        var v = tag[c + 8 ..];
        if (v.len > 0 and (v[0] == '"' or v[0] == '\'')) {
            const q = v[0];
            v = v[1..];
            v = v[0 .. std.mem.indexOfScalar(u8, v, q) orelse v.len];
        }
        // An optional reference URL before a colon.
        if (std.mem.lastIndexOfScalar(u8, v, ':')) |k| v = v[k + 1 ..];
        var result: [2]u32 = .{ 0, 0 };
        var parts = std.mem.tokenizeScalar(u8, v, ';');
        var n: usize = 0;
        while (parts.next()) |part| : (n += 1) {
            var p = std.mem.trim(u8, part, " ");
            var slot: usize = @min(n, 1);
            if (std.mem.indexOfScalar(u8, p, '=')) |eq| {
                slot = if (std.mem.startsWith(u8, p, "maxDifference")) 0 else 1;
                p = p[eq + 1 ..];
            }
            const hi = if (std.mem.indexOfScalar(u8, p, '-')) |d| p[d + 1 ..] else p;
            result[slot] = std.fmt.parseInt(u32, std.mem.trim(u8, hi, " "), 10) catch return null;
        }
        return result;
    }

    fn within(r: *Runner, threshold: u32, allowed: usize) bool {
        var off: usize = 0;
        var i: usize = 0;
        while (i < @as(usize, r.width) * r.height * 4) : (i += 4) {
            for (0..3) |c| {
                const a = r.pixels[0][i + c];
                const b = r.pixels[1][i + c];
                if ((if (a > b) a - b else b - a) > threshold) {
                    off += 1;
                    break;
                }
            }
        }
        return off <= allowed;
    }
};

