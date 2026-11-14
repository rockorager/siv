//! Layout tests through the document API, with siv's test fonts so that
//! results do not depend on the machine. Rendered results are compared
//! with golden images in test/headless.zig.

const std = @import("std");
const css = @import("css");
const text = @import("text");
const scene = @import("scene");
const Document = @import("Document.zig");
const box_mod = @import("box.zig");

const testing = std.testing;

pub const Fixture = struct {
    cache: text.FontCache,
    regular: text.FontId,
    bold: text.FontId,
    ua: css.Sheet,
    chain: [1]text.FontId = undefined,
    chain_bold: [1]text.FontId = undefined,

    pub fn init(gpa: std.mem.Allocator) !*Fixture {
        const f = try gpa.create(Fixture);
        f.* = .{ .cache = .init(gpa), .regular = undefined, .bold = undefined, .ua = try Document.parseUserAgentSheet(gpa) };
        try f.cache.addLastResort();
        f.regular = try f.cache.add(text.font.test_fonts.siv_regular, 0, .borrowed);
        f.bold = try f.cache.add(text.font.test_fonts.siv_bold, 0, .borrowed);
        f.chain = .{f.regular};
        f.chain_bold = .{f.bold};
        return f;
    }

    pub fn deinit(f: *Fixture, gpa: std.mem.Allocator) void {
        f.ua.deinit();
        f.cache.deinit();
        gpa.destroy(f);
    }

    fn chainFn(ctx: *anyopaque, family: []const u8, language: []const u8, weight: u16, italic: bool, stretch: f32, size: f32) Document.Error![]const text.FontId {
        _ = family;
        _ = language;
        _ = italic;
        _ = stretch;
        _ = size;
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        return if (weight >= 600) &f.chain_bold else &f.chain;
    }

    pub fn resolver(f: *Fixture) Document.FontResolver {
        return .{ .ctx = f, .cache = &f.cache, .chainFn = chainFn };
    }

    /// Parses, styles, and lays out a document at `width`.
    pub fn load(f: *Fixture, gpa: std.mem.Allocator, src: []const u8, options: Document.Options, width: f32) !*Document {
        const d = try Document.create(gpa, src, options, &f.ua);
        errdefer d.destroy();
        try d.styleAndBuild(.{ .width = width, .height = 600 });
        try d.resolveFonts(f.resolver());
        _ = try d.layout(&f.cache, width, 600, std.math.inf(f32));
        return d;
    }
};

fn elementBox(d: *Document, tag: @import("html").Atom, k: usize) *box_mod.Box {
    var n: usize = 0;
    for (d.dom.nodes.items, 0..) |x, i| if (x.kind == .element and x.name == tag) {
        if (n == k) return d.tree.get(d.node_boxes.get(@intCast(i)).?);
        n += 1;
    };
    unreachable;
}

fn absY(d: *Document, b: *box_mod.Box) f32 {
    const id: u32 = @intCast((@intFromPtr(b) - @intFromPtr(d.tree.boxes.items.ptr)) / @sizeOf(box_mod.Box));
    return d.engine.?.absoluteY(id);
}

fn absX(d: *Document, b: *box_mod.Box) f32 {
    const id: u32 = @intCast((@intFromPtr(b) - @intFromPtr(d.tree.boxes.items.ptr)) / @sizeOf(box_mod.Box));
    return d.engine.?.absoluteX(id);
}

test "block flow: margins collapse, widths fill, auto margins center" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>body { margin: 10px } p { margin: 20px 0; } .c { width: 200px; margin: 0 auto; height: 50px }</style>
        \\<p>one</p><p>two</p><div class=c></div>
    , .{}, 800);
    defer d.destroy();
    const p1 = elementBox(d, .p, 0);
    const p2 = elementBox(d, .p, 1);
    // body's margin (10) collapses with p's (20): p at 20.
    try testing.expectEqual(@as(f32, 20), absY(d, p1));
    try testing.expectEqual(@as(f32, 780), p1.w);
    try testing.expect(p1.h > 10);
    // Between the paragraphs: one 20px margin, not two.
    try testing.expectApproxEqAbs(absY(d, p1) + p1.h + 20, absY(d, p2), 0.01);
    const c = elementBox(d, .div, 0);
    try testing.expectEqual(@as(f32, 200), c.w);
    try testing.expectApproxEqAbs(@as(f32, 300), absX(d, c), 0.01);
    try testing.expectEqual(@as(f32, 50), c.h);
}

test "inline layout wraps lines, and pretty and balanced wrapping even them out" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const words = "The quick brown fox jumps over the lazy dog and keeps running far away from here";
    const src = "<style>body{margin:0;font-size:20px} p{margin:0}</style><p>" ++ words ++ "</p><p style='text-wrap: balance'>" ++ words ++ "</p>";
    const d = try f.load(gpa, src, .{}, 300);
    defer d.destroy();
    const p = elementBox(d, .p, 0);
    const l = try d.engine.?.laid(p.data, 300);
    try testing.expect(l.lines.len >= 3);
    for (l.lines) |line| try testing.expect(line.width <= 300.5);
    const pb = elementBox(d, .p, 1);
    const lb = try d.engine.?.laid(pb.data, 300);
    try testing.expectEqual(l.lines.len, lb.lines.len);
    // Balanced: the last line is not much shorter than the others.
    var widest: f32 = 0;
    for (lb.lines) |line| widest = @max(widest, line.width);
    try testing.expect(lb.lines[lb.lines.len - 1].width > widest * 0.5);
}

test "flex: grow, gaps, and centering" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>body{margin:0} .row { display: flex; gap: 10px; height: 100px; align-items: center }
        \\.a { width: 100px; height: 20px } .b { flex: 1; height: 40px } .c { flex: 2; height: 60px }</style>
        \\<div class=row><div class=a></div><div class=b></div><div class=c></div></div>
    , .{}, 430);
    defer d.destroy();
    const a = elementBox(d, .div, 1);
    const b = elementBox(d, .div, 2);
    const c = elementBox(d, .div, 3);
    try testing.expectEqual(@as(f32, 100), a.w);
    // 430 - 100 - 20 = 310 free: b 1/3, c 2/3.
    try testing.expectApproxEqAbs(@as(f32, 103.33), b.w, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 206.67), c.w, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 110), b.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), a.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), c.y, 0.01);
}

test "grid: fr tracks, spans, and named areas" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>body{margin:0} .g { display: grid; grid-template-columns: 100px 1fr 2fr; grid-template-areas: "h h h" "s m m"; gap: 10px }
        \\.h { grid-area: h; height: 30px } .s { grid-area: s; height: 50px } .m { grid-area: m; height: 20px } .x { grid-column: 2 / span 2; height: 10px }</style>
        \\<div class=g><div class=h></div><div class=s></div><div class=m></div><div class=x></div></div>
    , .{}, 520);
    defer d.destroy();
    const h = elementBox(d, .div, 1);
    const s = elementBox(d, .div, 2);
    const m = elementBox(d, .div, 3);
    const x = elementBox(d, .div, 4);
    try testing.expectEqual(@as(f32, 520), h.w);
    try testing.expectEqual(@as(f32, 100), s.w);
    // 520 - 100 - 20 = 400: 1fr 133.33, 2fr 266.67; m spans both + gap.
    try testing.expectApproxEqAbs(@as(f32, 410), m.w, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 110), m.x, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 40), s.y, 0.1);
    // Row 2 is 50 tall (s); x goes to row 3.
    try testing.expectApproxEqAbs(@as(f32, 100), x.y, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 410), x.w, 0.1);
}

test "positioning: relative, absolute in a positioned block" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>body{margin:0} .p { position: relative; width: 300px; height: 200px; top: 5px }
        \\.a { position: absolute; right: 10px; bottom: 20px; width: 50px; height: 40px }</style>
        \\<div class=p><div class=a></div></div>
    , .{}, 800);
    defer d.destroy();
    const p = elementBox(d, .div, 0);
    const a = elementBox(d, .div, 1);
    try testing.expectEqual(@as(f32, 5), absY(d, p));
    try testing.expectApproxEqAbs(@as(f32, 240), absX(d, a), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 5 + 140), absY(d, a), 0.01);
}

test "lazy layout stops after the first screen and resumes" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "<style>body{margin:0} p{margin:0 0 10px}</style><article>");
    for (0..400) |i| try src.print(gpa, "<p>Paragraph {d} with some words to wrap across a line or two.</p>", .{i});
    const d = try Document.create(gpa, src.items, .{}, &f.ua);
    defer d.destroy();
    try d.styleAndBuild(.{ .width = 400, .height = 300 });
    try d.resolveFonts(f.resolver());
    try testing.expect(!try d.layout(&f.cache, 400, 300, 600));
    const partial = d.height();
    try testing.expect(partial > 600);
    // The paragraphs near the top are laid out, those far below not yet.
    try testing.expect(elementBox(d, .p, 0).laid_h > 0);
    try testing.expect(elementBox(d, .p, 399).laid_h < 0);
    var steps: usize = 0;
    while (!try d.layout(&f.cache, 400, 300, d.height() * 0 + absY(d, elementBox(d, .p, 0)) + 2000 * @as(f32, @floatFromInt(steps + 2)))) : (steps += 1) {
        try testing.expect(steps < 100);
    }
    const full = d.height();
    // The same as laying out at once.
    const d2 = try f.load(gpa, src.items, .{}, 400);
    defer d2.destroy();
    try testing.expectApproxEqAbs(d2.height(), full, 0.5);
    try testing.expectApproxEqAbs(absY(d2, elementBox(d2, .p, 399)), absY(d, elementBox(d, .p, 399)), 0.5);
}

test "tables size columns from their cells" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>body{margin:0} table { border-spacing: 0 } td { padding: 0 }</style>
        \\<table><tr><td>a</td><td>longer text here</td></tr><tr><td colspan=2>wide cell spanning</td></tr></table>
    , .{}, 800);
    defer d.destroy();
    const td1 = elementBox(d, .td, 0);
    const td2 = elementBox(d, .td, 1);
    const td3 = elementBox(d, .td, 2);
    try testing.expect(td2.w > td1.w);
    try testing.expectApproxEqAbs(td1.w + td2.w, td3.w, 0.5);
    try testing.expect(absY(d, td3) >= absY(d, td1) + td1.h - 0.5);
}

test "painting produces glyphs and backgrounds in the band only" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "<style>p{background:#eee;margin:0;height:100px}</style>");
    for (0..50) |i| try src.print(gpa, "<p>Line {d}</p>", .{i});
    const d = try f.load(gpa, src.items, .{}, 400);
    defer d.destroy();
    var b: scene.Builder = .init(gpa);
    defer b.deinit();
    const H = struct {
        fn draw(_: *anyopaque, _: *scene.Builder, _: u32, _: @import("raster").Rect, _: f32) scene.Error!bool {
            return false;
        }
        fn size(_: *anyopaque, _: []const u8) ?[2]f32 {
            return null;
        }
        fn image(_: *anyopaque, _: *scene.Builder, _: []const u8, _: @import("raster").Rect, _: @import("raster").Rect) scene.Error!void {}
        fn marker(ctx: *anyopaque, i: u32) ?*const @import("paint.zig").MarkerGlyphs {
            const dd: *Document = @ptrCast(@alignCast(ctx));
            return dd.markerGlyphs(i);
        }
    };
    try d.paint(&b, 1000, 1400, .{}, .{ .ctx = d, .drawReplaced = H.draw, .imageSize = H.size, .drawImage = H.image, .marker = H.marker }, &.{});
    const list = try b.finish(0);
    var glyph_runs: usize = 0;
    var fills: usize = 0;
    for (list.commands) |c| switch (c) {
        .glyphs => glyph_runs += 1,
        .fill => fills += 1,
        else => {},
    };
    // Paragraphs 10..14 overlap 1000..1400 (plus one either side).
    try testing.expect(glyph_runs >= 4 and glyph_runs <= 8);
    try testing.expect(fills >= 4);
}


test "find, selected text, and the accessibility tree" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<h2>Fruit</h2><p>Apples and <a href="/pears">pears</a>.</p>
        \\<ul><li>one</li><li>two <img alt="a pear" width=10 height=10></li></ul>
        \\<p>More apples.</p>
    , .{ .base_url = "https://example.com/a/" }, 400);
    defer d.destroy();
    var all: std.ArrayList(Document.Pos) = .empty;
    defer all.deinit(gpa);
    try d.findAll("APPLES", &all, gpa, 100);
    try testing.expectEqual(2, all.items.len);
    // Forwards from just past the first match finds the second; wrapping
    // backwards from the start finds the last.
    const second = d.find("apples", .{ .ifc = all.items[0].ifc, .offset = all.items[0].offset + 1 }, false).?;
    try testing.expectEqual(all.items[1], second);
    try testing.expectEqual(all.items[1], d.find("apples", .{ .ifc = 0, .offset = 0 }, true).?);
    // Between the heading's middle and the second item: blocks on lines,
    // and the image's replacement character left out.
    const sel = try d.textBetween(gpa, .{ .ifc = 3, .offset = 3 }, .{ .ifc = 0, .offset = 2 });
    defer gpa.free(sel);
    try testing.expectEqualStrings("uit\nApples and pears.\none\ntwo", std.mem.trimEnd(u8, sel, " "));
    try testing.expect((try d.offsetRect(second)).?[1] > (try d.offsetRect(all.items[0])).?[1]);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var nodes: std.ArrayList(Document.AccessNode) = .empty;
    defer nodes.deinit(gpa);
    try d.accessibility(arena.allocator(), &nodes);
    const roles = [_]@FieldType(Document.AccessNode, "role"){ .heading, .paragraph, .link, .list, .list_item, .list_item, .image, .paragraph };
    try testing.expectEqual(roles.len, nodes.items.len);
    for (roles, nodes.items) |r, n| try testing.expectEqual(r, n.role);
    try testing.expectEqual(2, nodes.items[0].level);
    try testing.expectEqualStrings("Apples and pears.", nodes.items[1].name);
    try testing.expectEqualStrings("pears", nodes.items[2].name);
    try testing.expectEqual(1, nodes.items[2].parent);
    try testing.expectEqualStrings("https://example.com/pears", d.linkAt(nodes.items[2].node).?.href);
    try testing.expectEqual(2, nodes.items[5].position);
    try testing.expectEqual(2, nodes.items[5].set_size);
    try testing.expectEqualStrings("a pear", nodes.items[6].name);
    try testing.expectEqual(5, nodes.items[6].parent);
}

test "page breaks keep widows and orphans and honor break-before" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    // Ten lines of 20 px in one paragraph, then a chapter that starts a page.
    const d = try f.load(gpa,
        \\<style>body { margin: 0; font: 16px/20px serif } p { margin: 0 } h2 { break-before: page; margin: 0; font: 16px/20px serif }</style>
        \\<p>x x x x x x x x x x<br>x<br>x<br>x<br>x<br>x<br>x<br>x<br>x<br>x</p><h2>Two</h2><p>y</p>
    , .{}, 400);
    defer d.destroy();
    var breaks: std.ArrayList(f32) = .empty;
    defer breaks.deinit(gpa);
    // 190 px fits nine lines: breaking there would leave one widow, so the
    // break moves up a line; then the forced break before the heading.
    try d.pageBreaks(190, std.math.inf(f32), &breaks, gpa);
    try testing.expectEqual(2, breaks.items.len);
    try testing.expectApproxEqAbs(@as(f32, 160), breaks.items[0], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 200), breaks.items[1], 0.5);
    // Laid out only to 300 px: the pages that end above it, as before.
    try d.pageBreaks(190, 300, &breaks, gpa);
    try testing.expectEqual(1, breaks.items.len);
    try testing.expectApproxEqAbs(@as(f32, 160), breaks.items[0], 0.5);
    // A page taller than everything: no breaks but the forced one.
    try d.pageBreaks(1000, std.math.inf(f32), &breaks, gpa);
    try testing.expectEqual(1, breaks.items.len);
}

test "an image's size that arrives after its line was laid out reaches layout" {
    // The README's logo: a paragraph with an image is laid out before the
    // image decodes (0 × 0), then its size arrives and layout runs again
    // at the same width. The paragraph's lines must take the new size.
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa, "<p><img src=\"logo.png\"> after</p><p><img src=\"b.png\"></p><p>last</p>", .{ .base_url = "file:///r/" }, 400);
    defer d.destroy();
    const before = elementBox(d, .img, 0).h;
    try testing.expect(before < 1);
    for (d.resources.items, 0..) |r, i| if (r.kind == .image) d.supplyImage(@intCast(i), 120, 80, i);
    _ = try d.layout(&f.cache, 400, 600, std.math.inf(f32));
    const logo = elementBox(d, .img, 0);
    try testing.expectEqual(@as(f32, 120), logo.w);
    try testing.expectEqual(@as(f32, 80), logo.h);
    // The lines grew around the images: nothing overlaps.
    const p0 = elementBox(d, .p, 0);
    const p1 = elementBox(d, .p, 1);
    try testing.expect(p0.h >= 80);
    try testing.expect(absY(d, elementBox(d, .img, 1)) >= absY(d, p0) + p0.h);
    try testing.expect(absY(d, elementBox(d, .p, 2)) >= absY(d, p1) + 80);
}

test "linked and inline style sheets cascade in document order" {
    // A <style> after a <link> overrides it at equal specificity (and a
    // <link> after a <style> overrides that).
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const src = "<link rel=stylesheet href=a.css><style>p { width: 30px } div { width: 40px }</style><link rel=stylesheet href=b.css><p>x</p><div>y</div>";
    const d = try Document.create(gpa, src, .{ .base_url = "file:///s/" }, &f.ua);
    defer d.destroy();
    try d.styleAndBuild(.{ .width = 400, .height = 600 });
    for (d.resources.items, 0..) |r, i| if (r.kind == .stylesheet) {
        try d.supplyStylesheet(@intCast(i), if (std.mem.endsWith(u8, r.url, "a.css")) "p { width: 10px }" else "div { width: 50px }");
    };
    try d.styleAndBuild(.{ .width = 400, .height = 600 });
    try d.resolveFonts(f.resolver());
    _ = try d.layout(&f.cache, 400, 600, std.math.inf(f32));
    try testing.expectEqual(@as(f32, 30), elementBox(d, .p, 0).w);
    try testing.expectEqual(@as(f32, 50), elementBox(d, .div, 0).w);
}

test "a sheet's imports are resources named against the sheet's URL" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try Document.create(gpa, "<link rel=stylesheet href=css/a.css><p>x</p>", .{ .base_url = "file:///s/" }, &f.ua);
    defer d.destroy();
    try d.styleAndBuild(.{ .width = 400, .height = 600 });
    try testing.expectEqual(@as(usize, 1), d.resources.items.len);
    // More imports than the resource list has room for: it grows, and
    // moves, while they are added.
    try d.supplyStylesheet(0, "@import 'b.css'; @import 'c.css'; @import 'sub/d.css'; @import '/e.css'; p { width: 10px }");
    const urls = [_][]const u8{ "file:///s/css/a.css", "file:///s/css/b.css", "file:///s/css/c.css", "file:///s/css/sub/d.css", "file:///e.css" };
    try testing.expectEqual(urls.len, d.resources.items.len);
    for (urls, d.resources.items) |u, r| try testing.expectEqualStrings(u, r.url);
    try testing.expect(d.resources.items[0].sheet != null);
    // An imported sheet comes before the sheet that imports it.
    var i: u32 = 1;
    while (i < d.resources.items.len) : (i += 1) try d.supplyStylesheet(i, "p { width: 20px }");
    try d.styleAndBuild(.{ .width = 400, .height = 600 });
    try d.resolveFonts(f.resolver());
    _ = try d.layout(&f.cache, 400, 600, std.math.inf(f32));
    try testing.expectEqual(@as(f32, 10), elementBox(d, .p, 0).w);
}

test "text at font-size 0 lays out to finite geometry" {
    // Mail's spacer cells: `font-size: 0; line-height: 0` around a
    // no-break space.
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa, "<table width=600><tr><td>row</td></tr><tr><td height=40 style=\"font-size: 0px; line-height: 0px\">&nbsp;</td></tr><tr><td>after</td></tr></table><p>end</p>", .{}, 800);
    defer d.destroy();
    for (d.tree.boxes.items) |b| {
        for ([_]f32{ b.x, b.y, b.w, b.h }) |v| try testing.expect(std.math.isFinite(v));
    }
    try testing.expect(elementBox(d, .td, 1).h >= 40);
}

test "tables keep their margins; captions sit outside the border" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>body { margin: 0 } table { margin: 5px 3px 2px 40px; border: 4px solid; border-spacing: 0 }
        \\td { padding: 0 } caption { height: 20px }</style>
        \\<table><caption></caption><tr><td><div style="width:50px;height:10px"></div></td></tr></table>
    , .{}, 800);
    defer d.destroy();
    const t = elementBox(d, .table, 0);
    try testing.expectEqual(@as(f32, 40), absX(d, t));
    try testing.expectEqual(@as(f32, 5), absY(d, t));
    // The caption above the border; the cell inside it.
    try testing.expectEqual(@as(f32, 5), absY(d, elementBox(d, .caption, 0)));
    try testing.expectEqual(@as(f32, 5 + 20 + 4), absY(d, elementBox(d, .td, 0)));
    try testing.expectEqual(@as(f32, 40 + 4), absX(d, elementBox(d, .td, 0)));
}

test "table columns: excess width to auto columns, percentages of the table" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>body { margin: 0 } td { padding: 0 }</style>
        \\<table width=600 cellspacing=0><tr><td width=20>a</td><td>b</td><td width=20>c</td></tr></table>
        \\<table width=600 cellspacing=0><tr><td width="25%">a</td><td>b</td></tr></table>
    , .{}, 800);
    defer d.destroy();
    // Mail's gutters keep their width; the auto column takes the rest.
    try testing.expectEqual(@as(f32, 20), elementBox(d, .td, 0).w);
    try testing.expectEqual(@as(f32, 560), elementBox(d, .td, 1).w);
    try testing.expectEqual(@as(f32, 150), elementBox(d, .td, 3).w);
    try testing.expectEqual(@as(f32, 450), elementBox(d, .td, 4).w);
}

test "collapsed table borders are shared between cells" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>body { margin: 0 } table { border: 1px solid; border-collapse: collapse; padding: 9px }
        \\td { border: 1px solid; padding: 0 } td + td { border-left-width: 3px }</style>
        \\<table><tr><td><div style="width:50px;height:10px"></div><td><div style="width:50px;height:10px"></div></table>
    , .{}, 800);
    defer d.destroy();
    // One line between the cells (the wider, 3px), one at each edge,
    // and no table padding.
    try testing.expectEqual(@as(f32, 1 + 50 + 3 + 50 + 1), elementBox(d, .table, 0).w);
    try testing.expectEqual(@as(f32, 1 + 10 + 1), elementBox(d, .table, 0).h);
    // The 3px line straddles the cells' edge: one pixel in the first.
    try testing.expectEqual(@as(f32, 1 + 50 + 1), absX(d, elementBox(d, .td, 1)));
}

test "floats: <br clear> and lines too wide beside floats move below them" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>body { margin: 0 } .f { float: left; width: 150px; height: 60px } span { display: inline-block; width: 200px; height: 20px }</style>
        \\<div style="width: 300px"><div class=f></div><span></span></div>
        \\<div style="clear: both"></div>
        \\<div class=f></div>before<br clear=all><p style="margin: 0">after</p>
    , .{}, 800);
    defer d.destroy();
    // 200px does not fit in the 150px beside the float: below it.
    try testing.expectEqual(@as(f32, 60), absY(d, elementBox(d, .span, 0)));
    try testing.expectEqual(@as(f32, 0), absX(d, elementBox(d, .span, 0)));
    // The line after the <br> starts below the float: the paragraph
    // after it too.
    try testing.expect(absY(d, elementBox(d, .p, 0)) >= absY(d, elementBox(d, .div, 3)) + 60);
}

test "generated content: counter scopes, reversed lists, ::first-letter" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>h2 { counter-increment: h2; counter-reset: h3 } h3 { counter-increment: h3 }
        \\h3::before { content: counter(h2) "." counter(h3) " " } p::first-letter { float: left; font-size: 3em }</style>
        \\<h2>A</h2><h3>x</h3><h3>y</h3><h2>B</h2><h3>z</h3>
        \\<ol reversed><li>a<li value=6>b<li>c</ol>
        \\<p>“Lorem ipsum</p>
    , .{}, 800);
    defer d.destroy();
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    for (d.tree.ifcs.items) |ifc| {
        try all.appendSlice(gpa, ifc.text);
        try all.append(gpa, '|');
    }
    // A reset on h2 reaches the h3s after it (its following siblings).
    for ([_][]const u8{ "1.1 x", "1.2 y", "2.1 z" }) |want| try testing.expect(std.mem.indexOf(u8, all.items, want) != null);
    // Items before value=6 count down to it.
    var markers: std.ArrayList(u8) = .empty;
    defer markers.deinit(gpa);
    for (d.tree.markers.items) |m| try markers.appendSlice(gpa, m.text);
    try testing.expectEqualStrings("7. 6. 5. ", markers.items);
    // The drop cap: a float with the quote and the letter.
    var float_text: []const u8 = "";
    for (d.tree.boxes.items) |b| if (b.inline_float and b.kind == .inline_root) {
        float_text = d.tree.ifcs.items[b.data].text;
    };
    try testing.expectEqualStrings("“L", float_text);
}

test "an image with a percentage height against an auto one keeps its ratio" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa, "<div style=\"width: 100px\"><img src=\"a.png\" style=\"max-width: 100%; height: 100%\"></div>", .{ .base_url = "file:///r/" }, 400);
    defer d.destroy();
    for (d.resources.items, 0..) |r, i| if (r.kind == .image) d.supplyImage(@intCast(i), 200, 200, i);
    _ = try d.layout(&f.cache, 400, 600, std.math.inf(f32));
    // height: 100% of an auto height is auto: max-width scales both.
    try testing.expectEqual(@as(f32, 100), elementBox(d, .img, 0).w);
    try testing.expectEqual(@as(f32, 100), elementBox(d, .img, 0).h);
}

test "color schemes: what a document declares, and whether it has colors of its own" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const Case = struct { []const u8, Document.Kind, Document.Colors };
    for ([_]Case{
        // No colors: the user agent's (an hr's gray, Markdown's grays)
        // and hidden ones do not count.
        .{ "<div dir=ltr>hi</div><hr><p style='display:none;color:#fff'>preheader</p>", .html, .{} },
        .{ "# Title\n\n> quote\n\n`code`", .markdown, .{} },
        .{ "plain text", .text, .{} },
        // Colors in style attributes, presentational hints, and sheets,
        // and inherited into what is shown.
        .{ "<div style='color: rgb(0, 0, 0)'>hi</div>", .html, .{ .own = true } },
        .{ "<table bgcolor=white><tr><td>hi</table>", .html, .{ .own = true } },
        .{ "<style>.x { background: linear-gradient(#fff, #eee) }</style><div class=x>hi</div>", .html, .{ .own = true } },
        .{ "<p>a <font color=red>b</font>", .html, .{ .own = true } },
        // Not colors: system colors, currentcolor, transparent.
        .{ "<div style='color: CanvasText; background: transparent; border-color: currentcolor'>hi</div>", .html, .{} },
        // Declarations: the root's color-scheme, else the meta tag.
        .{ "<meta name=color-scheme content='light dark'><body style='color:#222'>hi", .html, .{ .scheme = .light_dark, .own = true } },
        .{ "<meta name=color-scheme content='light dark'><style>:root { color-scheme: only light }</style>hi", .html, .{ .scheme = .light } },
        .{ "<style>body { color: #222 } @media (prefers-color-scheme: dark) { body { color: #eee } }</style>hi", .html, .{ .dark_media = true, .own = true } },
    }) |c| {
        const d = try f.load(gpa, c[0], .{ .kind = c[1] }, 400);
        defer d.destroy();
        try testing.expectEqual(c[2], d.colors);
    }
    // Light unless it allows dark; a theme's colors only where they suit.
    const own: Document.Colors = .{ .own = true };
    try testing.expect(!own.usedDark(true) and !own.adapts());
    try testing.expect((Document.Colors{}).usedDark(true));
    try testing.expect((Document.Colors{ .own = true, .dark_media = true }).usedDark(true));
    try testing.expect(!(Document.Colors{ .scheme = .light_dark, .own = true }).usedDark(false));
    try testing.expect((Document.Colors{ .scheme = .dark, .own = true }).usedDark(false));
}

test "the quote toggle: a message's rules cannot restyle it, the application's user sheet can" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const mail = "<style>a { color: rgb(0 128 0) !important; background: yellow; border: 0 }</style><p>Hi</p><blockquote type=cite>Old</blockquote>";
    const toggleStyle = struct {
        fn of(d: *const Document) *const css.Style {
            const toggle = d.dom.node(d.quotes[0]).prev;
            return d.store.get(d.styles.?.styles[toggle.index()]);
        }
    }.of;
    {
        const d = try f.load(gpa, mail, .{ .collapse_quotes = true }, 400);
        defer d.destroy();
        const st = toggleStyle(d);
        try testing.expectEqual(css.Color.Kind.system, st.inh.color.kind);
        try testing.expectEqual(css.color.System.button_face, st.box.background_color.system);
        try testing.expectEqual(@as(f32, 1), st.box.border_width[0]);
        // Under the pointer, the face siv's buttons have when hovered.
        const toggle = d.dom.node(d.quotes[0]).prev;
        try testing.expect(try d.setHover(toggle));
        const hovered = d.store.get(d.hover_paint.get(toggle.index()).?.painted);
        try testing.expectEqual(css.color.System.button_hover, hovered.box.background_color.system);
    }
    {
        const d = try f.load(gpa, mail, .{ .collapse_quotes = true, .user_css = "a.siv-quote-toggle { color: rgb(200 0 0) !important; background: none !important }" }, 400);
        defer d.destroy();
        const st = toggleStyle(d);
        try testing.expect(st.inh.color.eql(.rgb8(200, 0, 0)));
        try testing.expectEqual(@as(f32, 0), st.box.background_color.a);
    }
}

test "elements nested past the parser's limit build boxes and lay out" {
    // The box builder, layout, and painting recurse once per level of
    // the tree: 16,000 unclosed <div>s overflowed the stack.
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "<style>body { margin: 0 } div { padding-left: 1px }</style>");
    for (0..16_000) |_| try src.appendSlice(gpa, "<div>");
    try src.appendSlice(gpa, "x");
    const d = try f.load(gpa, src.items, .{}, 4000);
    defer d.destroy();
    // html, body, and 510 <div>s above the deepest ones, which are
    // siblings there.
    const depth = @import("html").max_depth - 2;
    try testing.expectEqual(@as(f32, depth - 1), absX(d, elementBox(d, .div, depth - 1)));
    try testing.expectEqual(@as(f32, depth), absX(d, elementBox(d, .div, depth)));
    try testing.expectEqual(@as(f32, depth), absX(d, elementBox(d, .div, 15_999)));
}

test "a selector that cannot match fails without trying every placement of its compounds" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    // No <div> is above the <section>, so the rule matches nothing. With
    // k descendant combinators over 2k <div>s there are (2k choose k)
    // ways to find that out: 10 seconds for k = 13, and for 40 never.
    {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "<style>h6 { width: 20px } div section");
        for (0..40) |_| try src.appendSlice(gpa, " div");
        try src.appendSlice(gpa, " h6 { width: 10px } section");
        for (0..40) |_| try src.appendSlice(gpa, " div");
        try src.appendSlice(gpa, " h6 { height: 30px }</style><section>");
        for (0..80) |_| try src.appendSlice(gpa, "<div>");
        try src.appendSlice(gpa, "<h6>x</h6>");
        const d = try f.load(gpa, src.items, .{}, 400);
        defer d.destroy();
        try testing.expectEqual(@as(f32, 20), elementBox(d, .h6, 0).w);
        try testing.expectEqual(@as(f32, 30), elementBox(d, .h6, 0).h);
    }
    // What stops a search early must not stop one that a farther
    // ancestor or sibling completes.
    const cases = [_]struct { selector: []const u8, body: []const u8, matches: bool }{
        // The nearest .b has the wrong parent; the next one has .a.
        .{ .selector = ".a > .b h6", .body = "<div class=a><div class=b><div><div class=b><h6>", .matches = true },
        .{ .selector = ".a > .b h6", .body = "<div class=a><div><div class=b><div><div class=b><h6>", .matches = false },
        // The nearest .b has no sibling before it; the next one has .a.
        .{ .selector = ".a ~ .b h6", .body = "<div class=a></div><div class=b><div class=b><h6>", .matches = true },
        .{ .selector = ".a ~ .b h6", .body = "<div class=b><div class=a></div><div><div class=b><h6>", .matches = false },
        // The nearest .b follows something else; the first follows .a.
        .{ .selector = ".a + .b ~ h6", .body = "<div class=a></div><div class=b></div><div></div><div class=b></div><h6>", .matches = true },
        .{ .selector = ".a + .b ~ h6", .body = "<div class=b></div><div class=a></div><div></div><div class=b></div><h6>", .matches = false },
        // The nearest .c has a .b before it under the wrong parent.
        .{ .selector = ".a > .b ~ .c h6", .body = "<div class=a><div class=b></div><div class=c><div><div class=b></div><div class=c><h6>", .matches = true },
        .{ .selector = ".a > .b ~ .c h6", .body = "<div><div class=b></div><div class=c><div class=a><div></div><div class=c><h6>", .matches = false },
        // The nearest .c has no .b before it.
        .{ .selector = ".a .b ~ .c h6", .body = "<div class=a><div class=b></div><div class=c><div class=x></div><div class=c><h6>", .matches = true },
        .{ .selector = ".a .b + .c > h6", .body = "<div class=a><div></div><div class=b></div><div class=c><h6>", .matches = true },
        .{ .selector = ".a .b + .c > h6", .body = "<div class=b></div><div class=c><div class=a></div><h6>", .matches = false },
    };
    for (cases) |case| {
        const src = try std.fmt.allocPrint(gpa, "<style>h6 {{ width: 20px }} {s} {{ width: 10px }}</style>{s}x", .{ case.selector, case.body });
        defer gpa.free(src);
        const d = try f.load(gpa, src, .{}, 400);
        defer d.destroy();
        testing.expectEqual(@as(f32, if (case.matches) 10 else 20), elementBox(d, .h6, 0).w) catch |err| {
            std.debug.print("{s} on {s}\n", .{ case.selector, case.body });
            return err;
        };
    }
}

test "var() substitution reads a bounded amount of text" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    // Each variable is the one before it four times over, so the last is
    // --v0 4^levels times: the columns of a grid whose second item shows
    // whether the declaration applied.
    const Case = struct {
        fn second(fx: *Fixture, a: std.mem.Allocator, v0: []const u8, levels: u32, columns: []const u8) !f32 {
            var src: std.ArrayList(u8) = .empty;
            defer src.deinit(a);
            try src.print(a, "<body style='margin:0'><div style='display:grid;--v0:{s};", .{v0});
            for (1..levels + 1) |i| try src.print(a, "--v{d}:var(--v{d}) var(--v{d}) var(--v{d}) var(--v{d});", .{ i, i - 1, i - 1, i - 1, i - 1 });
            try src.print(a, "grid-template-columns:var(--v{d}) {s}'><p style='margin:0'>a</p><p style='margin:0'>b</p></div>", .{ levels, columns });
            const d = try fx.load(a, src.items, .{}, 400);
            defer d.destroy();
            // A megabyte is far above what these documents need and far
            // below what the largest substitutions wrote.
            try testing.expect(d.memory() < 1 << 20);
            return absX(d, elementBox(d, .p, 1));
        }
    };
    // 16 columns of 10px: the second item is in the second one.
    try testing.expectEqual(@as(f32, 10), try Case.second(f, gpa, "10px", 2, ""));
    // 4^8 columns are 327 KB of text: the declaration is invalid, the
    // grid has one column, and the second item is under the first.
    try testing.expectEqual(@as(f32, 0), try Case.second(f, gpa, "10px", 8, ""));
    // 4^16 columns would be 21 GB.
    try testing.expectEqual(@as(f32, 0), try Case.second(f, gpa, "10px", 16, ""));
    // Uses that write nothing count too: 4^16 empty fallbacks.
    try testing.expectEqual(@as(f32, 10), try Case.second(f, gpa, "var(--none,)", 2, "10px 10px"));
    try testing.expectEqual(@as(f32, 0), try Case.second(f, gpa, "var(--none,)", 16, "10px 10px"));
}

test "table cells that span a thousand rows and columns cost their columns, not their slots" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    // Sixteen such cells in a row took 76 seconds.
    {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "<table><tr>");
        for (0..16) |_| try src.appendSlice(gpa, "<td rowspan=1000 colspan=1000>x");
        try src.appendSlice(gpa, "</table>");
        const d = try f.load(gpa, src.items, .{}, 400);
        defer d.destroy();
        try testing.expect(absX(d, elementBox(d, .td, 15)) > absX(d, elementBox(d, .td, 14)));
        try testing.expectEqual(absY(d, elementBox(d, .td, 0)), absY(d, elementBox(d, .td, 15)));
    }
    // And with rows for them to span, a cell in each of 300, each cell
    // beside the ones from the rows above: 45 million slots.
    {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "<table style='border-collapse:collapse'>");
        for (0..300) |_| try src.appendSlice(gpa, "<tr><td rowspan=1000 colspan=1000>x");
        try src.appendSlice(gpa, "</table>");
        const d = try f.load(gpa, src.items, .{}, 400);
        defer d.destroy();
        for (1..300) |k| {
            try testing.expect(absX(d, elementBox(d, .td, k)) > absX(d, elementBox(d, .td, k - 1)));
        }
    }
}

test "collapsed borders against cells that span in from another row or column" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const d = try f.load(gpa,
        \\<style>body { margin: 0 } table { border-collapse: collapse } td { border: 1px solid; padding: 0 } div { width: 50px; height: 10px }</style>
        \\<table><tr><td rowspan=2 style="border-right-width: 5px"><div></div><td><div></div>
        \\<tr><td><div></div><tr><td colspan=2 style="border-top-width: 7px"><div></div></table>
    , .{}, 800);
    defer d.destroy();
    try testing.expectEqual(@as(f32, 1 + 50 + 5 + 50 + 1), elementBox(d, .table, 0).w);
    // The second row's cell has the first row's first cell on its left,
    // and its 5px border.
    try testing.expectEqual(@as(f32, 1 + 50 + 5), absX(d, elementBox(d, .div, 1)));
    try testing.expectEqual(@as(f32, 1 + 50 + 5), absX(d, elementBox(d, .div, 2)));
    try testing.expectEqual(@as(f32, 1 + 10 + 1), absY(d, elementBox(d, .div, 2)));
    // And the third row's cell below it, with its 7px border.
    try testing.expectEqual(@as(f32, 1 + 10 + 1 + 10 + 7), absY(d, elementBox(d, .div, 3)));
    try testing.expectEqual(@as(f32, 1 + 10 + 1 + 10 + 7 + 10 + 1), elementBox(d, .table, 0).h);
}

test "grid: items locked to a row take the next free column, past the columns there are" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    // Positions as Chromium lays these out. 10px tracks count them.
    const style = "<style>body { margin: 0 } div { display: grid; grid-template-columns: 10px 10px; grid-auto-columns: 10px; grid-auto-rows: 10px; width: 200px } p, i { margin: 0 }</style>";
    const row = "<p style='grid-row: 1'>x</p>";
    {
        // Five in the first row of two columns: three columns are made,
        // one after the other, and the rest of the items fill rows of
        // five.
        const d = try f.load(gpa, style ++ "<div>" ++ row ++ row ++ row ++ row ++ row ++ "<i>x</i><i>x</i><i>x</i><i>x</i><i>x</i><i>x</i></div>", .{}, 400);
        defer d.destroy();
        for (0..5) |k| {
            try testing.expectEqual(@as(f32, @floatFromInt(k * 10)), absX(d, elementBox(d, .p, k)));
            try testing.expectEqual(@as(f32, 0), absY(d, elementBox(d, .p, k)));
            try testing.expectEqual(@as(f32, @floatFromInt(k * 10)), absX(d, elementBox(d, .i, k)));
            try testing.expectEqual(@as(f32, 10), absY(d, elementBox(d, .i, k)));
        }
        try testing.expectEqual(@as(f32, 0), absX(d, elementBox(d, .i, 5)));
        try testing.expectEqual(@as(f32, 20), absY(d, elementBox(d, .i, 5)));
    }
    {
        // Dense packing looks from the row's start each time, and finds
        // the columns the items before made taken.
        const d = try f.load(gpa, style ++ "<div style='grid-auto-flow: row dense'>" ++ row ++ row ++ row ++ row ++ "</div>", .{}, 400);
        defer d.destroy();
        for (0..4) |k| try testing.expectEqual(@as(f32, @floatFromInt(k * 10)), absX(d, elementBox(d, .p, k)));
    }
    {
        // Two columns wide, with the first and third of three taken: not
        // over the third, but after it; the next item goes on from there.
        const d = try f.load(gpa, style ++ "<div style='grid-template-columns: 10px 10px 10px'><p style='grid-row: 1; grid-column: 1'>x</p><p style='grid-row: 1; grid-column: 3'>x</p><p style='grid-row: 1; grid-column: span 2'>x</p>" ++ row ++ "</div>", .{}, 400);
        defer d.destroy();
        try testing.expectEqual(@as(f32, 30), absX(d, elementBox(d, .p, 2)));
        try testing.expectEqual(@as(f32, 50), absX(d, elementBox(d, .p, 3)));
    }
}

test "grid: lines and spans beyond the limit take the last track" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    // 1px implicit tracks, so that positions count them.
    const style = "<style>body { margin: 0 } div { display: grid; grid-auto-columns: 1px; grid-auto-rows: 1px; width: 0 } p { margin: 0 }</style>";
    {
        // A line number made that many tracks: 2,000,000 here, and
        // 1,000,000,000 as readily.
        const d = try f.load(gpa, style ++ "<div><p style='grid-column: 2000000'>x</p><p style='grid-column: 900 / 2000000'>x</p><p style='grid-column: 3 / span 2000000'>x</p></div>", .{}, 400);
        defer d.destroy();
        // Beyond the last line: the last track. Across it: up to it.
        try testing.expectEqual(@as(f32, 999), absX(d, elementBox(d, .p, 0)));
        try testing.expectEqual(@as(f32, 899), absX(d, elementBox(d, .p, 1)));
        try testing.expectEqual(@as(f32, 2), absX(d, elementBox(d, .p, 2)));
    }
    {
        // Before the explicit grid: a thousand tracks, which the item
        // at line 1 comes after.
        const d = try f.load(gpa, style ++ "<div><p style='grid-column: -2000000'>x</p><p style='grid-column: 1; grid-row: 1'>x</p></div>", .{}, 400);
        defer d.destroy();
        try testing.expectEqual(@as(f32, 0), absX(d, elementBox(d, .p, 0)));
        try testing.expectEqual(@as(f32, 1000), absX(d, elementBox(d, .p, 1)));
    }
    {
        // Auto placement: each item would start a thousand rows below
        // the one before, and each row would be a row of the bitmap.
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, style ++ "<div>");
        for (0..200) |_| try src.appendSlice(gpa, "<p style='grid-row: span 600000'>x</p>");
        const d = try f.load(gpa, src.items, .{}, 400);
        defer d.destroy();
        try testing.expectEqual(@as(f32, 0), absY(d, elementBox(d, .p, 0)));
        try testing.expectEqual(@as(f32, 999), absY(d, elementBox(d, .p, 1)));
        try testing.expectEqual(@as(f32, 999), absY(d, elementBox(d, .p, 199)));
        // A template is as long at most: its last track is the 1000th.
        const t = try f.load(gpa, style ++ "<div style='grid-template-columns: repeat(10000, 1px) repeat(10000, 1px)'><p style='grid-column: -2'>x</p></div>", .{}, 400);
        defer t.destroy();
        try testing.expectEqual(@as(f32, 999), absX(t, elementBox(t, .p, 0)));
    }
}
