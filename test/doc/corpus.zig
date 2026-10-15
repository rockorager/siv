//! The document renderer's golden corpus (D32, test/doc/corpus/README):
//! a real README in Markdown, RSS items with messy HTML, and a Standard
//! Ebooks chapter with its publisher CSS, rendered with siv's test fonts
//! and compared with test/golden/doc/.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const png = @import("png");
const Runner = @import("render.zig").Runner;

const testing = std.testing;
const golden_dir = "test/golden/doc";

fn expectGolden(r: *Runner, name: []const u8, got: []const u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = try std.fmt.allocPrint(gpa, golden_dir ++ "/{s}.png", .{name});
    defer gpa.free(path);
    if (testing.environ.getPosix("SIV_UPDATE_GOLDEN") != null) {
        const bytes = try png.encode(gpa, r.width, r.height, got);
        defer gpa.free(bytes);
        try std.Io.Dir.cwd().createDirPath(io, golden_dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        return;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    const want = try png.decode(gpa, bytes);
    defer want.deinit(gpa);
    try testing.expectEqual(r.width, want.width);
    try testing.expectEqual(r.height, want.height);
    var worst: u8 = 0;
    var off: usize = 0;
    for (want.pixels, got) |a, b| {
        const d = if (a > b) a - b else b - a;
        worst = @max(worst, d);
        if (d > 1) off += 1;
    }
    if (worst <= 3 and off * 200 <= got.len / 4) return;
    std.debug.print("golden {s}: max channel difference {d}, {d} channels off by more than 1\n", .{ name, worst, off });
    return error.GoldenMismatch;
}

fn check(comptime name: []const u8, path: []const u8, kind: @import("doc").Document.Kind, width: u32, height: u32, top: f32) !void {
    const r = try Runner.init(testing.allocator, testing.io, "test/doc/corpus", "https://corpus.example", width, height);
    defer r.deinit();
    try r.render(path, kind, top, r.pixels[0]);
    try expectGolden(r, name, r.pixels[0]);
}

test "corpus: a README in Markdown" {
    try check("readme", "readme.md", .markdown, 640, 900, 0);
}

test "corpus: RSS items with messy HTML" {
    try check("rss-wordpress", "rss-wordpress.html", .html, 480, 520, 0);
    try check("rss-newsletter", "rss-newsletter.html", .html, 640, 480, 0);
    try check("rss-messy", "rss-messy.html", .html, 480, 420, 0);
}

test "corpus: a Standard Ebooks chapter with its CSS" {
    try check("se-chapter", "se/text/chapter-1.xhtml", .html, 560, 800, 0);
}
