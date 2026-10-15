//! Lowering tests: what documents become, checked through the ops and
//! the paints a display list receives. Rendered results are compared
//! with golden images in test/headless.zig.

const std = @import("std");
const scene = @import("scene");
const raster = @import("raster");
const svg = @import("svg.zig");

const testing = std.testing;

fn parse(src: []const u8, options: svg.Options) !*svg.Document {
    return svg.parse(testing.allocator, src, options);
}

/// Draws into a builder and returns the list.
fn drawn(b: *scene.Builder, doc: *const svg.Document, dst: raster.Rect, colors: ?*const svg.Colors) !scene.DisplayList {
    b.reset();
    try doc.draw(b, dst, colors);
    return b.finish(0);
}

fn fills(list: scene.DisplayList, out: []scene.Fill) usize {
    var n: usize = 0;
    for (list.commands) |c| switch (c) {
        .fill => |f| {
            if (n < out.len) out[n] = f;
            n += 1;
        },
        else => {},
    };
    return n;
}

fn expectColor(want: [4]f32, got: scene.Color) !void {
    try testing.expectApproxEqAbs(want[0], scene.linearToSrgb(got.r), 1e-3);
    try testing.expectApproxEqAbs(want[1], scene.linearToSrgb(got.g), 1e-3);
    try testing.expectApproxEqAbs(want[2], scene.linearToSrgb(got.b), 1e-3);
    try testing.expectApproxEqAbs(want[3], got.a, 1e-3);
}

test "view box maps into the destination, and transforms apply to paths" {
    const doc = try parse(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="16px" height="16px" viewBox="0 0 16 16">
        \\  <g transform="translate(2 3)"><rect x="1" y="1" width="4" height="2" transform="scale(2)"/></g>
        \\</svg>
    , .{});
    defer doc.deinit();
    try testing.expectEqual(@as(f32, 16), doc.width);
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    const list = try drawn(&b, doc, .xywh(100, 0, 32, 32), null);
    // The view box layer scales by 2 and moves to x = 100.
    const push = list.commands[0].push;
    try testing.expectEqual(@as(f32, 2), push.layer.transform.a);
    try testing.expectEqual(@as(f32, 100), push.layer.transform.e);
    var f: [1]scene.Fill = undefined;
    try testing.expectEqual(@as(usize, 1), fills(list, &f));
    // Local (1, 1)-(5, 3), scaled by 2 and moved by (2, 3).
    try testing.expectEqual(raster.Rect{ .x0 = 4, .y0 = 5, .x1 = 12, .y1 = 9 }, f[0].shape.path.bounds());
    try expectColor(.{ 0, 0, 0, 1 }, f[0].paint.solid);
}

test "GTK symbolic icons take the foreground, and classes their own colors" {
    const src =
        \\<svg viewBox="0 0 16 16"><path d="M0 0h8v8z" fill="#2e3436"/>
        \\<path class="error" d="M8 8h8v8z" fill="#ff0000"/><path d="M0 8h1v1z" fill="none"/>
        \\<circle cx="4" cy="12" r="2" fill="#2e3436" opacity="0.5"/></svg>
    ;
    const doc = try parse(src, .{ .symbolic = true });
    defer doc.deinit();
    try testing.expect(doc.recolors);
    var colors: svg.Colors = .{};
    colors.set(.foreground, .srgb(0.2, 0.4, 0.6, 1));
    colors.set(.@"error", .srgb(0.9, 0.1, 0.1, 1));
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    var f: [4]scene.Fill = undefined;
    // fill="none" stays unpainted.
    try testing.expectEqual(@as(usize, 3), fills(try drawn(&b, doc, .xywh(0, 0, 16, 16), &colors), &f));
    try expectColor(.{ 0.2, 0.4, 0.6, 1 }, f[0].paint.solid);
    try expectColor(.{ 0.9, 0.1, 0.1, 1 }, f[1].paint.solid);
    // A lone shape's opacity folds into its paint.
    try expectColor(.{ 0.2, 0.4, 0.6, 0.5 }, f[2].paint.solid);
    // Without colors the file's own colors show.
    _ = fills(try drawn(&b, doc, .xywh(0, 0, 16, 16), null), &f);
    try expectColor(.{ 0, 0, 0, 1 }, f[0].paint.solid);

    const plain = try parse(src, .{});
    defer plain.deinit();
    try testing.expect(!plain.recolors);
    _ = fills(try drawn(&b, plain, .xywh(0, 0, 16, 16), &colors), &f);
    try expectColor(.{ @as(f32, 0x2e) / 255, @as(f32, 0x34) / 255, @as(f32, 0x36) / 255, 1 }, f[0].paint.solid);
}

test "KDE color scheme classes stand for roles through currentColor" {
    const doc = try parse(
        \\<svg viewBox="0 0 16 16"><defs><style type="text/css" id="current-color-scheme">
        \\ .ColorScheme-Text { color:#232629; } .ColorScheme-Highlight { color:#3daee9; }
        \\</style></defs>
        \\<path class="ColorScheme-Text" style="fill:currentColor; fill-opacity:1" d="M0 0h4v4z"/>
        \\<g class="ColorScheme-Highlight" fill="currentColor"><rect width="2" height="2"/></g>
        \\<path style="fill-opacity:0.33" d="M0 0h1v1z"/>
        \\</svg>
    , .{});
    defer doc.deinit();
    try testing.expect(doc.recolors);
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    var f: [3]scene.Fill = undefined;
    _ = fills(try drawn(&b, doc, .xywh(0, 0, 16, 16), null), &f);
    try expectColor(.{ @as(f32, 0x23) / 255, @as(f32, 0x26) / 255, @as(f32, 0x29) / 255, 1 }, f[0].paint.solid);
    try expectColor(.{ @as(f32, 0x3d) / 255, @as(f32, 0xae) / 255, @as(f32, 0xe9) / 255, 1 }, f[1].paint.solid);
    var colors: svg.Colors = .{};
    colors.set(.foreground, .srgb(1, 1, 1, 1));
    colors.set(.accent, .srgb(1, 0, 0, 1));
    _ = fills(try drawn(&b, doc, .xywh(0, 0, 16, 16), &colors), &f);
    try expectColor(.{ 1, 1, 1, 1 }, f[0].paint.solid);
    try expectColor(.{ 1, 0, 0, 1 }, f[1].paint.solid);
    // A shape with no fill of its own is black, at its fill opacity.
    try expectColor(.{ 0, 0, 0, 0.33 }, f[2].paint.solid);
}

test "the cascade: attributes, rules by specificity, style, important" {
    const doc = try parse(
        \\<svg viewBox="0 0 4 4"><style>
        \\ path { fill: #010101 } .a { fill: #020202 } #p3 { fill: #030303 } .imp { fill: #040404 !important }
        \\</style>
        \\<path d="M0 0h1v1z" fill="#ffffff"/>
        \\<path class="a" d="M0 0h1v1z" fill="#ffffff"/>
        \\<path id="p3" class="a" d="M0 0h1v1z"/>
        \\<path class="a" style="fill:#050505" d="M0 0h1v1z"/>
        \\<path class="imp" style="fill:#050505" d="M0 0h1v1z"/>
        \\<g fill="#060606"><path style="fill:inherit" d="M0 0h1v1z"/></g>
        \\</svg>
    , .{});
    defer doc.deinit();
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    var f: [6]scene.Fill = undefined;
    try testing.expectEqual(@as(usize, 6), fills(try drawn(&b, doc, .xywh(0, 0, 4, 4), null), &f));
    // A path rule beats the attribute; then class, id, style, important;
    // a <g>'s fill reaches its child through inherit (path's rule loses).
    for (f, [_]f32{ 1, 2, 3, 5, 4, 6 }) |fill, v| try expectColor(.{ v / 255, v / 255, v / 255, 1 }, fill.paint.solid);
}

test "gradients map their bounding box and interpolate in their color-interpolation" {
    const src =
        \\<svg viewBox="0 0 10 10" color-interpolation="{s}"><defs>
        \\ <linearGradient id="g"><stop offset="0" stop-color="#000"/><stop offset="100%" stop-color="#fff"/></linearGradient>
        \\ <linearGradient id="h" xlink:href="#g" x1="0" y1="0" x2="0" y2="1"/>
        \\ <linearGradient id="l" xlink:href="#g" color-interpolation="{s}"/>
        \\</defs><rect x="2" y="4" width="6" height="2" fill="url(#h)"/><rect width="1" height="1" fill="url(#l)"/></svg>
    ;
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    // Root layer space, then for each gradient: stop count and the
    // encoded middle (sRGB's middle gray or linear light's).
    const Case = struct { root: []const u8, other: []const u8, srgb: bool, stops: [2]usize, mid: [2]f32 };
    for ([_]Case{
        // The root composites in sRGB: an sRGB gradient needs no sub-stops,
        // a linearRGB one gets 16 per interval computed in linear light.
        .{ .root = "auto", .other = "linearRGB", .srgb = true, .stops = .{ 2, 17 }, .mid = .{ 0.5, scene.linearToSrgb(0.5) } },
        // A linearRGB root, which gradients inherit: the other way round.
        .{ .root = "linearRGB", .other = "sRGB", .srgb = false, .stops = .{ 2, 17 }, .mid = .{ scene.linearToSrgb(0.5), 0.5 } },
    }) |case| {
        const text = try std.fmt.allocPrint(testing.allocator, src, .{ case.root, case.other });
        defer testing.allocator.free(text);
        const doc = try parse(text, .{});
        defer doc.deinit();
        var f: [2]scene.Fill = undefined;
        const list = try drawn(&b, doc, .xywh(0, 0, 10, 10), null);
        try testing.expectEqual(case.srgb, list.commands[0].push.layer.srgb);
        _ = fills(list, &f);
        // The unit square maps onto the rectangle.
        const g = f[0].paint.gradient;
        try testing.expectEqual(raster.Point{ .x = 2, .y = 6 }, g.transform.apply(g.geometry.linear.p1));
        for (f, case.stops, case.mid) |fill, n, mid| {
            const stops = fill.paint.gradient.stops;
            try testing.expectEqual(n, stops.len);
            // Where the layer interpolates itself, its middle is between
            // the two stops in its own space.
            const c = if (n == 17) stops[8].color.r else if (case.srgb) scene.srgbToLinear(0.5 * (scene.linearToSrgb(stops[0].color.r) + scene.linearToSrgb(stops[1].color.r))) else 0.5 * (stops[0].color.r + stops[1].color.r);
            try testing.expectApproxEqAbs(mid, scene.linearToSrgb(c), 1e-3);
        }
    }
}

test "color spaces of layers: the root, groups, blur filters" {
    const doc = try parse(
        \\<svg viewBox="0 0 16 16"><defs>
        \\ <filter id="b"><feGaussianBlur stdDeviation="1"/></filter>
        \\ <filter id="s" color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="1"/></filter>
        \\</defs>
        \\<g opacity="0.5"><rect width="4" height="4"/><rect width="2" height="2" fill="red"/></g>
        \\<g color-interpolation="linearRGB"><rect width="4" height="4"/><rect width="2" height="2" fill="red"/></g>
        \\<rect width="4" height="4" filter="url(#b)"/>
        \\<rect width="4" height="4" filter="url(#s)"/>
        \\</svg>
    , .{});
    defer doc.deinit();
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    const list = try drawn(&b, doc, .xywh(0, 0, 16, 16), null);
    var spaces: std.ArrayList(bool) = .empty;
    defer spaces.deinit(testing.allocator);
    for (list.commands) |c| switch (c) {
        .push => |p| if (p.layer.isIsolated()) try spaces.append(testing.allocator, p.layer.srgb),
        else => {},
    };
    // Root (sRGB); the opacity group stays in sRGB; the linearRGB group
    // gets a linear layer; a default blur works in linear light with the
    // element drawn in sRGB inside it; an sRGB blur needs no inner layer.
    try testing.expectEqualSlices(bool, &.{ true, true, false, false, true, true }, spaces.items);
}

test "one-stop gradients, ellipse starts, and the viewport beyond the view box" {
    const doc = try parse(
        \\<svg viewBox="0 0 10 20"><defs>
        \\ <linearGradient id="g"><stop offset="0" stop-color="#00f" stop-opacity="0.5"/></linearGradient>
        \\</defs>
        \\<rect width="10" height="10" fill="url(#g)" fill-opacity="0.5"/>
        \\<circle cx="5" cy="15" r="2" fill="none" stroke="#000"/>
        \\<rect x="-5" width="2" height="2"/>
        \\</svg>
    , .{});
    defer doc.deinit();
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    // A 20 x 20 viewport: the 10 x 20 view box centers, leaving 5 units
    // on each side that still show.
    const list = try drawn(&b, doc, .xywh(0, 0, 20, 20), null);
    try testing.expectEqual(raster.Rect{ .x0 = -5, .y0 = 0, .x1 = 15, .y1 = 20 }, list.commands[0].push.layer.clip.?.shape.rect);
    var f: [2]scene.Fill = undefined;
    try testing.expectEqual(@as(usize, 2), fills(list, &f));
    // The stop's opacity and fill-opacity multiply.
    try expectColor(.{ 0, 0, 1, 0.25 }, f[0].paint.solid);
    // A circle's path starts at (cx + r, cy), where dashes begin.
    for (list.commands) |c| switch (c) {
        .stroke => |s| {
            const p = s.shape.path;
            try testing.expectEqual(raster.Point{ .x = 7, .y = 15 }, p.points[0]);
        },
        else => {},
    };
}

test "clip paths and masks become layers" {
    const doc = try parse(
        \\<svg viewBox="0 0 16 16"><defs>
        \\ <clipPath id="c"><rect width="8" height="16"/></clipPath>
        \\ <filter id="w"><feColorMatrix values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 1 0"/></filter>
        \\ <mask id="m"><g filter="url(#w)"><rect width="16" height="8" fill-opacity="0.3"/></g></mask>
        \\</defs>
        \\<g clip-path="url(#c)"><rect width="16" height="16"/></g>
        \\<path clip-path="url(#c)" d="M0 0C4 0 8 0 12 0L12 12Z"/>
        \\<g mask="url(#m)"><rect width="16" height="16" fill="#ff0000"/></g>
        \\</svg>
    , .{});
    defer doc.deinit();
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    const list = try drawn(&b, doc, .xywh(0, 0, 16, 16), null);
    var clips: usize = 0;
    var first_fill: ?scene.Fill = null;
    var dst_in: ?scene.Push = null;
    var mask_fill: ?scene.Fill = null;
    for (list.commands, 0..) |c, i| switch (c) {
        .push => |p| {
            if (p.layer.clip != null) clips += 1;
            if (p.layer.blend == .dst_in) {
                dst_in = p;
                mask_fill = list.commands[i + 1].fill;
            }
        },
        .fill => |f| if (first_fill == null) {
            first_fill = f;
        },
        else => {},
    };
    // The view box, the clip path of the triangle that crosses it, and
    // the mask's region. Building the clip path of a shape leaves the
    // shape intact. The square holds its clip path, so it draws as the
    // clip path's rectangle, with no clip (contain.zig).
    try testing.expectEqual(@as(usize, 3), clips);
    try testing.expectEqual(raster.Rect{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 16 }, first_fill.?.shape.path.bounds());
    try testing.expect(dst_in != null);
    // The filter turns the mask white; luminance becomes alpha: 0.3.
    try expectColor(.{ 1, 1, 1, 0.3 }, mask_fill.?.paint.solid);
}

test "use places its target, strokes scale with uniform transforms" {
    const doc = try parse(
        \\<svg viewBox="0 0 32 32"><defs><path id="p" d="M0 0L4 0" stroke="#000" stroke-width="2"/></defs>
        \\<use href="#p" x="10" y="1" transform="scale(2)"/>
        \\<use xlink:href="#p" transform="scale(2 1)"/>
        \\</svg>
    , .{});
    defer doc.deinit();
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    const list = try drawn(&b, doc, .xywh(0, 0, 32, 32), null);
    var strokes: [2]scene.Stroke = undefined;
    var n: usize = 0;
    var transformed = false;
    for (list.commands) |c| switch (c) {
        .stroke => |s| {
            strokes[n] = s;
            n += 1;
        },
        .push => |p| if (p.layer.transform.a == 2 and p.layer.transform.d == 1) {
            transformed = true;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(raster.Point{ .x = 20, .y = 2 }, strokes[0].shape.path.points[0]);
    try testing.expectEqual(@as(f32, 4), strokes[0].style.width);
    // A non-uniform scale strokes inside a transformed layer.
    try testing.expect(transformed);
    try testing.expectEqual(@as(f32, 2), strokes[1].style.width);
}

test "malformed and hostile documents fail or draw nothing, never crash" {
    for ([_][]const u8{ "", "<html/>", "<svg><g></svg>", "not xml" }) |src|
        try testing.expectError(error.InvalidSvg, parse(src, .{}));
    // Self-referencing uses and gradients end.
    const doc = try parse(
        \\<svg viewBox="0 0 4 4"><g id="a"><use href="#a"/></g><use href="#b"/><use id="b" href="#a"/>
        \\<linearGradient id="g" href="#g"><stop/></linearGradient><rect width="1" height="1" fill="url(#g)"/>
        \\<path d="M 1 1 L 2 2 L x"/></svg>
    , .{});
    defer doc.deinit();
}

test "fuzz the parser" {
    try std.testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        "<svg viewBox='0 0 16 16'><path d='M0 0h8v8z' fill='#2e3436'/></svg>",
        "<svg><style>.a{fill:red}</style><g class='a' opacity='.5'><rect width='2' height='2' rx='1'/></g></svg>",
        "<svg><defs><radialGradient id='r' fx='.1'><stop stop-color='red'/><stop offset='1'/></radialGradient></defs><circle r='3' fill='url(#r)' stroke='blue' stroke-dasharray='1 2'/></svg>",
        "<svg><mask id='m'><path d='M0 0A5 5 0 1 0 4 4'/></mask><use href='#u' mask='url(#m)'/><symbol id='u' viewBox='0 0 1 1'><polygon points='0 0 1 0 1 1'/></symbol></svg>",
    } });
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    const doc = svg.parse(testing.allocator, src, .{ .symbolic = src.len % 2 == 0 }) catch return;
    defer doc.deinit();
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    var colors: svg.Colors = .{};
    colors.set(.foreground, .white);
    doc.draw(&b, .xywh(0, 0, 16, 16), &colors) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // Paths are validated when copied; anything else is a bug.
        else => return err,
    };
    _ = try b.finish(0);
}

test "embedded images draw in their viewport, wrapped base64 and all" {
    const doc = try parse(
        \\<svg viewBox="0 0 16 16"><image x="2" y="4" width="8" height="8" preserveAspectRatio="xMidYMid meet"
        \\ xlink:href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVQI12P4z8Dwn4Hh
        \\ /38AD/kD/XjubY4AAAAASUVORK5CYII="/>
        \\<image width="4" height="4" href="file:///etc/passwd"/></svg>
    , .{});
    defer doc.deinit();
    try testing.expect(doc.has_images);
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    const list = try drawn(&b, doc, .xywh(0, 0, 16, 16), null);
    var images: usize = 0;
    var m: raster.Affine = .identity;
    for (list.commands) |c| switch (c) {
        .push => |p| m = p.layer.transform.then(m),
        .image => |im| {
            images += 1;
            try testing.expectEqual(@as(u32, 2), im.image.width);
            // 2 × 1 pixels meet in 8 × 8 at (2, 4): 4 units a pixel,
            // centered vertically.
            const r = m.applyRect(im.dst);
            try testing.expectEqual(raster.Rect{ .x0 = 2, .y0 = 6, .x1 = 10, .y1 = 10 }, r);
            // Red, then blue.
            const px = im.image.pixels.?;
            try testing.expect(px[0] > 200 and px[2] < 50 and px[4] < 50 and px[6] > 200);
        },
        else => {},
    };
    // Files are not loaded.
    try testing.expectEqual(@as(usize, 1), images);
}

test "text becomes a text op with its inherited font and anchor, for the caller to shape" {
    const doc = try parse(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="88" height="20"><g fill="#fff" text-anchor="middle" font-family="Verdana,sans-serif" font-size="110">
        \\<text x="195 200" y="140" transform="scale(.1)" textLength="270"> build
        \\ <tspan>ok</tspan></text></g></svg>
    , .{});
    defer doc.deinit();
    var texts: std.ArrayList(*const svg.Document.Text) = .empty;
    defer texts.deinit(testing.allocator);
    try doc.texts(&texts, testing.allocator);
    try testing.expectEqual(1, texts.items.len);
    const t = texts.items[0];
    try testing.expectEqualStrings("build ok", t.content);
    try testing.expectEqualStrings("Verdana,sans-serif", t.family);
    try testing.expectEqual(svg.Document.Text.Anchor.middle, t.anchor);
    try testing.expectEqual(@as(f32, 110), t.size);
    try testing.expectEqual(@as(f32, 195), t.x);
    try testing.expectEqual(@as(f32, 270), t.length);
    try testing.expectApproxEqAbs(@as(f32, 0.1), t.transform.a, 1e-6);
    // Without a hook, drawing leaves the text out.
    var b: scene.Builder = .init(testing.allocator);
    defer b.deinit();
    const list = try drawn(&b, doc, .xywh(0, 0, 88, 20), null);
    for (list.commands) |c| try testing.expect(c != .glyphs);
}
