//! The PDF writer, hermetically: a page of every display list construct
//! is written, then the file's structure is checked (every xref offset
//! names its object, every stream's length is exact, the trailer is
//! complete) and its content streams, fonts, and ToUnicode map are read
//! back. `zig build test-integration` checks the same file with qpdf and
//! poppler, independent parsers.

const std = @import("std");
const testing = std.testing;
const scene = @import("scene");
const raster = @import("raster");
const text = @import("text");
const hb = @import("harfbuzz_subset");
const Writer = @import("Writer.zig");
const sample = @import("test_sample.zig");
const parse = @import("test_parse.zig");
const Parsed = parse.Parsed;
const dictInt = parse.dictInt;
const ref = parse.ref;

const gpa = testing.allocator;

test "a page of every construct has a sound structure and content" {
    var fonts: text.FontCache = .init(gpa);
    defer fonts.deinit();
    const id = try fonts.add(text.font.test_fonts.latin, 0, .borrowed);
    const face = fonts.face(id).?;

    var b: scene.Builder = .init(gpa);
    defer b.deinit();
    try sample.build(&b, face);
    const list = try b.finish(0);

    var w = try Writer.init(gpa, .{ .title = "Every construct", .author = "siv" });
    defer w.deinit();
    try w.addPage(sample.width, sample.height, list);
    try w.addPage(200, 100, list);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try w.finish(&aw.writer);

    var p = try Parsed.parse(aw.written());
    defer p.deinit();

    // The page tree.
    const catalog = for (p.objects.items, 1..) |o, n| {
        if (std.mem.indexOf(u8, o, "/Type /Catalog") != null) break @as(u32, @intCast(n));
    } else return error.NoCatalog;
    const pages = p.object(try ref(p.object(catalog), "/Pages "));
    try testing.expect(std.mem.indexOf(u8, pages, "/Count 2") != null);
    const page_num: u32 = @intCast(try dictInt(pages, "/Kids ["));
    const page = p.object(page_num);
    try testing.expect(std.mem.indexOf(u8, page, "/MediaBox [0 0 300 400]") != null);

    // The content: the y flip, then every construct.
    const ops = try p.stream(try ref(page, "/Contents "));
    defer gpa.free(ops);
    try testing.expect(std.mem.startsWith(u8, ops, "1 0 0 -1 0 400 cm\n"));
    for ([_][]const u8{ " re\n", "f\n", "f*\n", " c\n", "S\n", "] 2 d\n", " sh\n", " Do\n", " Tj\n", "W n\n", " gs\n" }) |want| {
        if (std.mem.indexOf(u8, ops, want) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ want, ops });
            return error.MissingOperator;
        }
    }

    // A transparency group with the layer's blend mode.
    var found_group = false;
    var found_multiply = false;
    var found_smask = false;
    var found_mesh = false;
    var font_file: ?u32 = null;
    var to_unicode: ?u32 = null;
    for (p.objects.items, 1..) |o, n| {
        if (std.mem.indexOf(u8, o, "/Group << /S /Transparency /CS /DeviceRGB /I true >>") != null) found_group = true;
        if (std.mem.indexOf(u8, o, "/BM /Multiply") != null) found_multiply = true;
        if (std.mem.indexOf(u8, o, "/SMask << /Type /Mask /S /Luminosity") != null) found_smask = true;
        if (std.mem.indexOf(u8, o, "/ShadingType 6") != null) found_mesh = true;
        if (std.mem.indexOf(u8, o, "/FontFile2 ") != null) font_file = try ref(o, "/FontFile2 ");
        if (std.mem.indexOf(u8, o, "/ToUnicode ") != null) to_unicode = try ref(o, "/ToUnicode ");
        if (std.mem.indexOf(u8, o, "/Subtype /Type0") != null) {
            // A subset's name: six capitals and a plus sign.
            const base = o[std.mem.indexOf(u8, o, "/BaseFont /").? + 11 ..];
            for (base[0..6]) |ch| try testing.expect(ch >= 'A' and ch <= 'Z');
            try testing.expectEqual(@as(u8, '+'), base[6]);
            try testing.expect(std.mem.indexOf(u8, o, "/Encoding /Identity-H") != null);
        }
        _ = n;
    }
    try testing.expect(found_group and found_multiply and found_smask and found_mesh);

    // The embedded subset is a font HarfBuzz reads back, much smaller than
    // the original, with the glyphs the text used.
    const program = try p.stream(font_file.?);
    defer gpa.free(program);
    try testing.expect(program.len < text.font.test_fonts.latin.len / 4);
    const blob = hb.hb_blob_create(program.ptr, @intCast(program.len), hb.HB_MEMORY_MODE_READONLY, null, null);
    defer hb.hb_blob_destroy(blob);
    const sub = hb.hb_face_create(blob, 0);
    defer hb.hb_face_destroy(sub);
    // .notdef and the distinct glyphs of "Hello, siv!".
    try testing.expectEqual(@as(c_uint, 1 + sample.distinct_glyphs), hb.hb_face_get_glyph_count(sub));

    // ToUnicode maps each glyph to its text.
    const cmap = try p.stream(to_unicode.?);
    defer gpa.free(cmap);
    var gid: u32 = 0;
    _ = hb.hb_font_get_nominal_glyph(@ptrCast(face.font), 'H', &gid);
    var want: [32]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, cmap, std.fmt.bufPrint(&want, "<{X:0>4}> <0048>", .{gid}) catch unreachable) != null);
    try testing.expect(std.mem.indexOf(u8, cmap, "begincodespacerange") != null);
}

test "clusters give their text to their first glyph" {
    var fonts: text.FontCache = .init(gpa);
    defer fonts.deinit();
    const id = try fonts.add(text.font.test_fonts.latin, 0, .borrowed);
    const face = fonts.face(id).?;
    var b: scene.Builder = .init(gpa);
    defer b.deinit();
    // "fi" shaped as two glyphs in one cluster (as a decomposed ligature
    // would be), then "x" as its own cluster, right to left.
    var f_gid: u32 = 0;
    var i_gid: u32 = 0;
    var x_gid: u32 = 0;
    const font: *hb.hb_font_t = @ptrCast(face.font);
    _ = hb.hb_font_get_nominal_glyph(font, 'f', &f_gid);
    _ = hb.hb_font_get_nominal_glyph(font, 'i', &i_gid);
    _ = hb.hb_font_get_nominal_glyph(font, 'x', &x_gid);
    try b.glyphs(.{
        .font = .{ .handle = face.font, .key = face.key },
        .size = 12,
        .glyphs = &.{ .{ .id = x_gid, .x = 10, .y = 20 }, .{ .id = f_gid, .x = 20, .y = 20 }, .{ .id = i_gid, .x = 25, .y = 20 } },
        .paint = .color(.black),
        .bounds = .{ .x0 = 0, .y0 = 0, .x1 = 40, .y1 = 30 },
        .text = .{ .bytes = "fix", .clusters = &.{ 2, 0, 0 } },
    });
    var w = try Writer.init(gpa, .{});
    defer w.deinit();
    try w.addPage(50, 50, try b.finish(0));
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try w.finish(&aw.writer);
    var p = try Parsed.parse(aw.written());
    defer p.deinit();
    const cmap = for (p.objects.items, 1..) |o, n| {
        if (std.mem.indexOf(u8, o, "/ToUnicode ") != null) break try p.stream(try ref(o, "/ToUnicode "));
        _ = n;
    } else return error.NoToUnicode;
    defer gpa.free(cmap);
    var buf: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, cmap, std.fmt.bufPrint(&buf, "<{X:0>4}> <00660069>", .{f_gid}) catch unreachable) != null);
    try testing.expect(std.mem.indexOf(u8, cmap, std.fmt.bufPrint(&buf, "<{X:0>4}> <0078>", .{x_gid}) catch unreachable) != null);
    try testing.expect(std.mem.indexOf(u8, cmap, std.fmt.bufPrint(&buf, "<{X:0>4}>", .{i_gid}) catch unreachable) == null);
}

test "synthetic styles print as their outlines under invisible text" {
    var fonts: text.FontCache = .init(gpa);
    defer fonts.deinit();
    const regular = try fonts.add(text.font.test_fonts.siv_regular, 0, .borrowed);
    const bold = fonts.face(try fonts.instance(regular, .{ .synthetic = .{ .bold = text.font.Synthetic.bold_strength } })).?;
    var gid: u32 = 0;
    _ = hb.hb_font_get_nominal_glyph(@ptrCast(bold.font), 'I', &gid);
    var b: scene.Builder = .init(gpa);
    defer b.deinit();
    try b.glyphs(.{
        .font = .{ .handle = bold.font, .key = bold.key },
        .size = 100,
        .glyphs = &.{.{ .id = gid, .x = 10, .y = 80 }},
        .paint = .color(.black),
        .bounds = .{ .x0 = 0, .y0 = 0, .x1 = 50, .y1 = 100 },
        .text = .{ .bytes = "I", .clusters = &.{0} },
    });
    var w = try Writer.init(gpa, .{});
    defer w.deinit();
    try w.addPage(50, 100, try b.finish(0));
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try w.finish(&aw.writer);
    var p = try Parsed.parse(aw.written());
    defer p.deinit();
    const page = for (p.objects.items) |o| {
        if (std.mem.indexOf(u8, o, "/Type /Page ") != null) break o;
    } else return error.NoPage;
    const ops = try p.stream(try ref(page, "/Contents "));
    defer gpa.free(ops);
    // The stem's outline: 90 units wide at 1/10 px per unit, plus 1/24 em
    // of emboldening (42 units).
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    var lines = std.mem.splitScalar(u8, ops, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, " m") and !std.mem.endsWith(u8, line, " l")) continue;
        var nums: [2]f32 = undefined;
        var it = std.mem.tokenizeScalar(u8, line[0 .. line.len - 2], ' ');
        for (&nums) |*n| n.* = try std.fmt.parseFloat(f32, it.next().?);
        lo = @min(lo, nums[0]);
        hi = @max(hi, nums[0]);
    }
    try testing.expectApproxEqAbs(13.2, hi - lo, 0.05);
    // The text is still there, invisible, in the embedded font.
    try testing.expect(std.mem.indexOf(u8, ops, "3 Tr\n") != null);
    try testing.expect(std.mem.indexOf(u8, ops, " Tj\n") != null);
    try testing.expect(std.mem.indexOf(u8, ops, "f\n") != null);
}

test "a group ending in a dst_in layer is drawn through a soft mask of it" {
    // An SVG mask as the svg module lowers it (D19): content, then the
    // mask's alpha composited with dst_in, in an isolated layer.
    var b: scene.Builder = .init(gpa);
    defer b.deinit();
    try b.pushLayer(.{ .isolate = true });
    try b.fillRect(.xywh(10, 10, 80, 80), .color(.srgb8(0xff, 0, 0, 0xff)));
    try b.pushLayer(.{ .blend = .dst_in });
    try b.fillRect(.xywh(30, 30, 40, 40), .color(.{ .r = 1, .g = 1, .b = 1, .a = 0.5 }));
    try b.popLayer();
    try b.popLayer();
    const list = try b.finish(0);
    var w = try Writer.init(gpa, .{});
    defer w.deinit();
    try w.addPage(100, 100, list);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try w.finish(&aw.writer);
    var p = try Parsed.parse(aw.written());
    defer p.deinit();
    // The soft mask's group holds the mask's rectangle, the masked group
    // the content's, without the mask drawn over it.
    const gs = for (p.objects.items) |o| {
        if (std.mem.indexOf(u8, o, "/SMask << /Type /Mask /S /Alpha /G ") != null) break o;
    } else return error.NoSoftMask;
    const mask = try p.stream(try ref(gs, "/G "));
    defer gpa.free(mask);
    // The mask layer is a group of its own, drawn by the soft mask's.
    try testing.expect(std.mem.indexOf(u8, mask, " Do") != null or std.mem.indexOf(u8, mask, "30 30 40 40 re") != null);
    var groups: usize = 0;
    for (p.objects.items, 1..) |o, n| {
        if (std.mem.indexOf(u8, o, "/Subtype /Form") == null) continue;
        const ops = try p.stream(@intCast(n));
        defer gpa.free(ops);
        if (std.mem.indexOf(u8, ops, "10 10 80 80 re") != null) {
            groups += 1;
            try testing.expect(std.mem.indexOf(u8, ops, "30 30 40 40 re") == null);
        }
    }
    try testing.expectEqual(@as(usize, 1), groups);
}

test "sibling layers inside a layer keep their clips" {
    // An icon's groups sit side by side inside its view box layer.
    var b: scene.Builder = .init(gpa);
    defer b.deinit();
    try b.pushLayer(.{ .opacity = 0.5 });
    for (0..3) |i| {
        const x: f32 = @floatFromInt(i * 30);
        try b.pushLayer(.{ .clip = .{ .shape = .{ .rect = .xywh(x, 0, 20, 20) } } });
        try b.fillRect(.xywh(x, 0, 40, 40), .color(.black));
        try b.popLayer();
    }
    try b.popLayer();
    const list = try b.finish(0);
    var w = try Writer.init(gpa, .{});
    defer w.deinit();
    try w.addPage(100, 100, list);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try w.finish(&aw.writer);
    var p = try Parsed.parse(aw.written());
    defer p.deinit();
    var clips: usize = 0;
    for (p.objects.items, 1..) |o, n| {
        if (std.mem.indexOf(u8, o, "/Length") == null) continue;
        const ops = p.stream(@intCast(n)) catch continue;
        defer gpa.free(ops);
        clips += std.mem.count(u8, ops, "W n");
    }
    try testing.expectEqual(@as(usize, 3), clips);
}
