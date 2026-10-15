//! Document renderer benchmarks (D32), with the system's fonts:
//! `zig build bench-doc -Doptimize=ReleaseFast [-- FILE...]`.
//!
//! - article: a 50 KB article with 20 KB of CSS, parsed, styled, and laid
//!   out (budget: a few milliseconds);
//! - long: a 1.5 MB document, to its first screen (budget: tens of
//!   milliseconds), then to its end;
//! - scroll: painting the band a scroll frame repaints (three viewports),
//!   and the layout slice that extends a lazily laid out document (budget:
//!   well under a millisecond per frame).
//!
//! FILE arguments are HTML (or .md) files measured like the article.
//! Inputs are generated, so that the numbers do not depend on anything
//! outside the repository; fonts are the machine's, loaded before timing.

const std = @import("std");
const doc = @import("doc");
const scene = @import("scene");
const text = @import("text");
const raster = @import("raster");
const pool = @import("pool");

/// The workers shaping uses, as the application's pool gives a document.
var executor: ?pool.Executor = null;

const Document = doc.Document;
const width = 800;
const viewport = 1000;

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

const words = [_][]const u8{ "the", "quick", "renderer", "lays", "out", "documents", "with", "care", "and", "speed", "while", "keeping", "memory", "bounded", "for", "very", "long", "texts", "that", "readers", "scroll", "through", "quietly", "at", "night", "typography", "matters", "because", "words", "are", "read", "one", "line", "after", "another", "hyphenation", "justification", "international", "characters", "café", "naïve", "Zürich" };

fn sentence(out: *std.ArrayList(u8), gpa: std.mem.Allocator, rng: std.Random, n: usize) !void {
    for (0..n) |i| {
        const w = words[rng.uintLessThan(usize, words.len)];
        if (i == 0) {
            try out.append(gpa, std.ascii.toUpper(w[0]));
            try out.appendSlice(gpa, w[1..]);
        } else {
            try out.append(gpa, ' ');
            switch (rng.uintLessThan(u8, 40)) {
                0 => try out.print(gpa, "<a href=\"/page/{d}\">{s}</a>", .{ i, w }),
                1 => try out.print(gpa, "<em>{s}</em>", .{w}),
                2 => try out.print(gpa, "<strong>{s}</strong>", .{w}),
                3 => try out.print(gpa, "<code>{s}</code>", .{w}),
                else => try out.appendSlice(gpa, w),
            }
        }
    }
    try out.appendSlice(gpa, ". ");
}

/// An article's body of about `bytes` bytes: headings, paragraphs, lists,
/// figures, quotes, tables, and code, as a news or blog article has.
fn body(out: *std.ArrayList(u8), gpa: std.mem.Allocator, rng: std.Random, bytes: usize) !void {
    var section: usize = 0;
    while (out.items.len < bytes) {
        section += 1;
        try out.print(gpa, "<section id=\"s{d}\"><h2 class=\"section-title\">Section {d}</h2>\n", .{ section, section });
        for (0..4) |_| {
            try out.appendSlice(gpa, "<p class=\"para\">");
            for (0..4 + rng.uintLessThan(usize, 4)) |_| try sentence(out, gpa, rng, 8 + rng.uintLessThan(usize, 12));
            try out.appendSlice(gpa, "</p>\n");
        }
        switch (section % 5) {
            0 => {
                try out.appendSlice(gpa, "<ul class=\"list\">");
                for (0..5) |_| {
                    try out.appendSlice(gpa, "<li>");
                    try sentence(out, gpa, rng, 6);
                    try out.appendSlice(gpa, "</li>");
                }
                try out.appendSlice(gpa, "</ul>\n");
            },
            1 => {
                try out.appendSlice(gpa, "<blockquote class=\"pull\"><p>");
                try sentence(out, gpa, rng, 14);
                try out.appendSlice(gpa, "</p></blockquote>\n");
            },
            2 => {
                try out.appendSlice(gpa, "<table class=\"data\"><thead><tr><th>Name</th><th>Value</th><th>Notes</th></tr></thead><tbody>");
                for (0..4) |r| try out.print(gpa, "<tr><td>Row {d}</td><td>{d}</td><td>{s} {s}</td></tr>", .{ r, rng.int(u16), words[r], words[r + 3] });
                try out.appendSlice(gpa, "</tbody></table>\n");
            },
            3 => try out.appendSlice(gpa, "<pre><code>fn main() void {\n    std.debug.print(\"hello\\n\", .{});\n}\n</code></pre>\n"),
            else => try out.appendSlice(gpa, "<div class=\"cards\"><div class=\"card\">One</div><div class=\"card\">Two</div><div class=\"card\">Three</div></div>\n"),
        }
        try out.appendSlice(gpa, "</section>\n");
    }
}

/// About `bytes` of CSS, as a site's stylesheet has: resets, typography,
/// components with descendant and attribute selectors, custom
/// properties, media queries, and flex and grid layouts.
fn stylesheet(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: usize) !void {
    try out.appendSlice(gpa,
        \\:root { --fg: #222; --bg: #fff; --accent: oklch(55% 0.15 250); --gap: 1rem; --measure: 42rem }
        \\@media (prefers-color-scheme: dark) { :root { --fg: #ddd; --bg: #111 } }
        \\*, *::before, *::after { box-sizing: border-box }
        \\html { font-family: Georgia, serif; line-height: 1.55; color: var(--fg); background: var(--bg) }
        \\body { margin: 0 auto; max-width: var(--measure); padding: 0 var(--gap) }
        \\h1, h2, h3 { font-family: system-ui, sans-serif; line-height: 1.2; text-wrap: balance }
        \\p.para { hyphens: auto; text-wrap: pretty; margin: 0 0 1em }
        \\a { color: var(--accent); text-decoration-thickness: 1px }
        \\a:hover { color: color-mix(in oklch, var(--accent) 70%, black) }
        \\code, pre { font-family: ui-monospace, monospace; font-size: 0.9em }
        \\pre { padding: 1em; background: color-mix(in srgb, var(--fg) 6%, var(--bg)); border-radius: 6px; overflow: auto }
        \\blockquote.pull { border-left: 4px solid var(--accent); margin: 1.5em 0; padding: 0 1em; font-style: italic }
        \\table.data { border-collapse: collapse; width: 100% }
        \\table.data th, table.data td { border-bottom: 1px solid #ccc; padding: 0.4em 0.6em; text-align: left }
        \\.cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(10rem, 1fr)); gap: var(--gap) }
        \\.card { padding: 1rem; border-radius: 8px; box-shadow: 0 1px 3px rgb(0 0 0 / 0.2) }
        \\ul.list { display: flex; flex-direction: column; gap: 0.25em; padding-left: 1.2em }
        \\@media (max-width: 600px) { body { padding: 0 0.5rem } .cards { grid-template-columns: 1fr } }
        \\
    );
    // Component rules that do not match, as most of a site's sheet does
    // on any one page.
    var i: usize = 0;
    while (out.items.len < bytes) : (i += 1) {
        try out.print(gpa,
            \\.c{d}-wrapper > .c{d}-item:not(.hidden) .label[data-kind="x{d}"] {{ color: calc(1px + {d}px); margin: calc(var(--gap) * 0.5) 0; padding: 2px {d}px }}
            \\#nav-{d} ul li a:hover, .menu-{d} .entry:first-child {{ background: rgb({d} {d} 200 / 0.5); border-radius: {d}px }}
            \\
        , .{ i, i, i, i % 7, i % 11, i, i, i % 255, (i * 7) % 255, i % 9 });
    }
}

fn article(gpa: std.mem.Allocator, body_bytes: usize, css_bytes: usize) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(42);
    const rng = prng.random();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, "<!doctype html><html lang=en><head><meta charset=utf-8><title>An article</title><style>\n");
    try stylesheet(&out, gpa, css_bytes);
    try out.appendSlice(gpa, "</style></head><body><article><h1>A long article about document rendering</h1>\n");
    try body(&out, gpa, rng, out.items.len + body_bytes);
    try out.appendSlice(gpa, "</article></body></html>\n");
    return out.toOwnedSlice(gpa);
}

const Hooks = struct {
    fn draw(_: *anyopaque, _: *scene.Builder, _: u32, _: raster.Rect, _: f32) scene.Error!bool {
        return false;
    }
    fn size(_: *anyopaque, _: []const u8) ?[2]f32 {
        return null;
    }
    fn image(_: *anyopaque, _: *scene.Builder, _: []const u8, _: raster.Rect, _: raster.Rect) scene.Error!void {}
    fn marker(ctx: *anyopaque, i: u32) ?*const doc.paint.MarkerGlyphs {
        const d: *Document = @ptrCast(@alignCast(ctx));
        return d.markerGlyphs(i);
    }
    fn of(d: *Document) doc.Hooks {
        return .{ .ctx = d, .drawReplaced = draw, .imageSize = size, .drawImage = image, .marker = marker };
    }
};

const Phases = struct { parse: u64 = 0, style: u64 = 0, fonts: u64 = 0, layout: u64 = 0 };

/// Parses, styles, resolves fonts, and lays out to `stop_y`.
fn load(gpa: std.mem.Allocator, fonts: *doc.sysfonts.SystemFonts, ua: *const @import("css").Sheet, src: []const u8, kind: Document.Kind, stop_y: f32, p: *Phases) !*Document {
    var t = now();
    const d = try Document.create(gpa, src, .{ .kind = kind }, ua);
    d.executor = executor;
    p.parse += now() - t;
    t = now();
    try d.styleAndBuild(.{ .width = width, .height = viewport });
    p.style += now() - t;
    t = now();
    try d.resolveFonts(fonts.resolver());
    p.fonts += now() - t;
    t = now();
    _ = try d.layout(&fonts.cache, width, viewport, stop_y);
    p.layout += now() - t;
    return d;
}

fn report(name: []const u8, runs: usize, p: Phases) void {
    const n: u64 = runs;
    const total = p.parse + p.style + p.fonts + p.layout;
    std.debug.print("{s:<28} {d:>8.2} ms  (parse {d:.2}, style {d:.2}, fonts {d:.2}, layout {d:.2})\n", .{ name, ms(total / n), ms(p.parse / n), ms(p.style / n), ms(p.fonts / n), ms(p.layout / n) });
}

/// Loads every font the document wants, so that timing excludes reading
/// font files (the application's font loading does that once).
fn warm(gpa: std.mem.Allocator, fonts: *doc.sysfonts.SystemFonts, ua: *const @import("css").Sheet, src: []const u8, kind: Document.Kind) !void {
    var p: Phases = .{};
    const d = try load(gpa, fonts, ua, src, kind, std.math.inf(f32), &p);
    defer d.destroy();
    var wanted: std.ArrayList(text.FontId) = .empty;
    defer wanted.deinit(gpa);
    try d.wantedFonts(&wanted);
    for (wanted.items) |id| fonts.load(id);
}

fn measureFull(gpa: std.mem.Allocator, fonts: *doc.sysfonts.SystemFonts, ua: *const @import("css").Sheet, name: []const u8, src: []const u8, kind: Document.Kind) !void {
    try warm(gpa, fonts, ua, src, kind);
    const runs = 20;
    var p: Phases = .{};
    for (0..runs) |_| {
        const d = try load(gpa, fonts, ua, src, kind, std.math.inf(f32), &p);
        d.destroy();
    }
    var label: [64]u8 = undefined;
    report(std.fmt.bufPrint(&label, "{s} ({d} KB)", .{ name, src.len / 1024 }) catch name, runs, p);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const fonts = try doc.sysfonts.SystemFonts.init(gpa, io);
    defer fonts.deinit();
    var ua = try Document.parseUserAgentSheet(gpa);
    defer ua.deinit();
    var workers = pool.Pool.init(gpa, pool.defaultThreadCount() - 1);
    defer workers.deinit();
    const serial = for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--serial")) break true;
    } else false;
    if (!serial) executor = workers.executor();

    if (argv.len > 2 and std.mem.eql(u8, argv[1], "--write")) {
        // The generated inputs, for profiling: DIR/article.html, DIR/long.html.
        const art = try article(gpa, 50 << 10, 20 << 10);
        defer gpa.free(art);
        const long = try article(gpa, 1500 << 10, 20 << 10);
        defer gpa.free(long);
        var dir = try std.Io.Dir.cwd().openDir(io, argv[2], .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "article.html", .data = art });
        try dir.writeFile(io, .{ .sub_path = "long.html", .data = long });
        return;
    }
    if (argv.len > 1 and !(argv.len == 2 and serial)) {
        for (argv[1..]) |path| {
            if (std.mem.eql(u8, path, "--serial")) continue;
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
            defer gpa.free(bytes);
            try measureFull(gpa, fonts, &ua, std.fs.path.basename(path), bytes, if (std.mem.endsWith(u8, path, ".md")) .markdown else .html);
        }
        return;
    }

    // The article: 50 KB of content with 20 KB of CSS.
    const art = try article(gpa, 50 << 10, 20 << 10);
    defer gpa.free(art);
    try measureFull(gpa, fonts, &ua, "article + 20 KB CSS", art, .html);

    // The UA sheet, parsed once per process.
    {
        const t = now();
        for (0..100) |_| {
            var s = try Document.parseUserAgentSheet(gpa);
            s.deinit();
        }
        std.debug.print("{s:<28} {d:>8.3} ms\n", .{ "user agent sheet", ms((now() - t) / 100) });
    }

    // A long document: first screen, then the rest.
    const long = try article(gpa, 1500 << 10, 20 << 10);
    defer gpa.free(long);
    try warm(gpa, fonts, &ua, long, .html);
    {
        const runs = 5;
        var p: Phases = .{};
        var rest: u64 = 0;
        var mem: usize = 0;
        var height: f32 = 0;
        for (0..runs) |_| {
            const d = try load(gpa, fonts, &ua, long, .html, 2 * viewport, &p);
            defer d.destroy();
            const t = now();
            var stop: f32 = 2 * viewport;
            while (!try d.layout(&fonts.cache, width, viewport, stop)) stop += 20000;
            rest += now() - t;
            mem = d.memory();
            height = d.height();
        }
        var label: [64]u8 = undefined;
        report(std.fmt.bufPrint(&label, "long ({d} KB) first screen", .{long.len / 1024}) catch "long", runs, p);
        std.debug.print("{s:<28} {d:>8.2} ms  ({d:.0} px tall, {d} MB in memory after)\n", .{ "long: the rest, in slices", ms(rest / runs), height, mem >> 20 });
    }

    // Scrolling the long document: a band repaint every viewport (what a
    // scroll leaving the painted band costs), after layout is complete,
    // and resize relayout to the first screen.
    {
        var p: Phases = .{};
        const d = try load(gpa, fonts, &ua, long, .html, std.math.inf(f32), &p);
        defer d.destroy();
        var b: scene.Builder = .init(gpa);
        defer b.deinit();
        const h = d.height();
        var y: f32 = 0;
        var frames: u64 = 0;
        var worst: u64 = 0;
        const t = now();
        while (y + 3 * viewport < h) : (y += viewport) {
            const t0 = now();
            b.reset();
            try d.paint(&b, y, y + 3 * viewport, .{}, Hooks.of(d), &.{});
            _ = try b.finish(0);
            const dt = now() - t0;
            worst = @max(worst, dt);
            frames += 1;
        }
        const per = (now() - t) / frames;
        std.debug.print("{s:<28} {d:>8.3} ms  (worst {d:.3} ms; one per viewport scrolled, {d} bands)\n", .{ "scroll: band repaint", ms(per), ms(worst), frames });
        // At 60 Hz scrolling a viewport per 10 frames, the CPU per frame.
        std.debug.print("{s:<28} {d:>8.3} ms\n", .{ "scroll: per frame (10/vp)", ms(per / 10) });
        const t1 = now();
        _ = try d.layout(&fonts.cache, width - 100, viewport, 2 * viewport);
        std.debug.print("{s:<28} {d:>8.2} ms\n", .{ "resize: first screen again", ms(now() - t1) });
    }
}
