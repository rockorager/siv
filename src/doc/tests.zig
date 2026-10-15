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
