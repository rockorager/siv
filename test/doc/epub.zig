//! E-books (D32) through the C API on the headless backend: Standard
//! Ebooks publications (test/doc/epub/README) opened with siv_epub_*,
//! chapters shown paged with the reading defaults, spreads, reading
//! positions that survive a new font size, and footnotes for popups.
//! Droid Serif (test/doc/fonts) is the serif face.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const harness = @import("../abi/harness.zig");
const Loop = @import("loop").Loop;

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const T = abi.tree;
const D = abi.document;
const Harness = harness.Harness;
const ok = harness.ok;

const Book = struct {
    h: Harness = .{ .golden = "test/golden/doc" },
    bytes: []u8 = &.{},
    fonts: [3][]u8 = .{ &.{}, &.{}, &.{} },
    epub: t.Epub = .null,
    node: t.Node = .null,
    pages: u32 = 0,
    page: u32 = 0,
    page_events: u32 = 0,
    loaded: u32 = 0,

    fn start(b: *Book, path: []const u8, w: u32, h: u32) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        try b.h.start(w, h, null, null);
        for ([_][]const u8{ "Regular", "Italic", "Bold" }, 0..) |style, i| {
            const p = try std.fmt.allocPrint(gpa, "test/doc/fonts/DroidSerif-{s}.ttf", .{style});
            defer gpa.free(p);
            b.fonts[i] = try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20));
            try ok(A.siv_app_add_font(b.h.app, "serif", 5, b.fonts[i].ptr, b.fonts[i].len));
        }
        b.bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20));
        try ok(D.siv_epub_open(b.h.app, b.bytes.ptr, b.bytes.len, &b.epub));
    }

    fn stop(b: *Book) void {
        D.siv_epub_destroy(b.epub);
        b.h.stop();
        testing.allocator.free(b.bytes);
        for (b.fonts) |f| testing.allocator.free(f);
    }

    fn onEvent(user: ?*anyopaque, _: t.Node, e: *const t.DocviewEvent) callconv(.c) void {
        const b: *Book = @ptrCast(@alignCast(user));
        switch (e.type) {
            .page => {
                b.page = e.current;
                b.pages = e.count;
                b.page_events += 1;
            },
            .loaded => b.loaded += 1,
            else => {},
        }
    }

    /// Shows spine item `index` paged with the reading defaults.
    fn show(b: *Book, index: u32, flags: t.DocviewFlags) !void {
        var path: [256]u8 = undefined;
        var len: usize = 0;
        try ok(D.siv_epub_get_spine_path(b.epub, index, &path, path.len, &len));
        const root = A.siv_window_get_root(b.h.window);
        var txn: t.Txn = .null;
        try ok(T.siv_txn_begin(b.h.window, &txn));
        if (b.node != .null) T.siv_remove(txn, b.node);
        var fl = flags;
        fl.paged = true;
        fl.reading = true;
        b.node = D.siv_docview(txn, root, &.{
            .epub = b.epub,
            .epub_path = &path,
            .epub_path_len = len,
            .color_scheme = .light,
            .flags = fl,
            .font_size = 18,
            .user_data = b,
            .on_event = onEvent,
        });
        try ok(T.siv_txn_commit(txn));
        try b.waitLoaded(b.loaded + 1);
    }

    fn waitLoaded(b: *Book, n: u32) !void {
        const deadline = Loop.now() + 20 * std.time.ns_per_s;
        while (b.loaded < n) {
            if (Loop.now() > deadline) return error.Timeout;
            try ok(A.siv_app_dispatch(b.h.app, 2));
        }
        try b.h.settle();
    }
};

fn text(epub: t.Epub, field: t.EpubField, buf: []u8) ![]const u8 {
    var len: usize = 0;
    try ok(D.siv_epub_get_metadata(epub, field, buf.ptr, buf.len, &len));
    return buf[0..@min(len, buf.len)];
}

test "epub: Standard Ebooks packages, spines, and tables of contents" {
    var b: Book = .{};
    try b.start("test/doc/epub/earnest.epub", 200, 100);
    defer b.stop();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("The Importance of Being Earnest", try text(b.epub, .title, &buf));
    try testing.expectEqualStrings("Oscar Wilde", try text(b.epub, .author, &buf));
    try testing.expectEqualStrings("en-GB", try text(b.epub, .language, &buf));
    var spine: u32 = 0;
    var toc: u32 = 0;
    try ok(D.siv_epub_get_counts(b.epub, &spine, &toc));
    try testing.expect(spine >= 8 and toc >= 8);
    var len: usize = 0;
    try ok(D.siv_epub_get_spine_path(b.epub, 0, &buf, buf.len, &len));
    try testing.expectEqualStrings("epub/text/titlepage.xhtml", buf[0..len]);
    // Each entry points into the spine.
    var depth: u32 = 0;
    var target: u32 = 0;
    for (0..toc) |i| {
        try ok(D.siv_epub_get_toc_label(b.epub, @intCast(i), &buf, buf.len, &len, &depth));
        try testing.expect(len > 0 and depth >= 1);
        try ok(D.siv_epub_get_toc_target(b.epub, @intCast(i), &buf, buf.len, &len, &target));
        try testing.expect(target < spine);
    }
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_epub_get_spine_path(b.epub, spine, &buf, buf.len, &len));
    var bad: t.Epub = .null;
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_epub_open(b.h.app, "not a zip", 9, &bad));
}

/// The spine index of a path.
fn spineOf(epub: t.Epub, want: []const u8) !u32 {
    var spine: u32 = 0;
    var toc: u32 = 0;
    try ok(D.siv_epub_get_counts(epub, &spine, &toc));
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (0..spine) |i| {
        try ok(D.siv_epub_get_spine_path(epub, @intCast(i), &buf, buf.len, &len));
        if (std.mem.eql(u8, buf[0..len], want)) return @intCast(i);
    }
    return error.NotInSpine;
}

test "epub: a chapter paged with the reading defaults, positions kept across font sizes" {
    var b: Book = .{};
    try b.start("test/doc/epub/jekyll.epub", 640, 860);
    defer b.stop();
    try b.show(try spineOf(b.epub, "epub/text/chapter-1.xhtml"), .{});
    try testing.expect(b.pages >= 3);
    try testing.expectEqual(@as(u32, 0), b.page);
    try b.h.expectGolden("epub-jekyll-page1", 640, 860);
    try ok(D.siv_docview_set_page(b.node, 1));
    try b.h.settle();
    try testing.expectEqual(@as(u32, 1), b.page);
    try b.h.expectGolden("epub-jekyll-page2", 640, 860);

    // A reading position on page 3 survives a larger font: the page
    // shown afterwards holds it.
    try ok(D.siv_docview_set_page(b.node, 2));
    var loc: [64]u8 = undefined;
    var len: usize = 0;
    try ok(D.siv_docview_get_position(b.node, &loc, loc.len, &len));
    const pages_before = b.pages;
    try ok(D.siv_docview_set_user_css(b.node, "body { font-size: 130% }", 24));
    try b.waitLoaded(b.loaded + 1);
    try testing.expect(b.pages > pages_before);
    var after: [64]u8 = undefined;
    var after_len: usize = 0;
    try ok(D.siv_docview_get_position(b.node, &after, after.len, &after_len));
    // The new page starts at or before the kept element, on the same
    // page as it.
    var page_now: u32 = 0;
    var count: u32 = 0;
    try ok(D.siv_docview_get_page(b.node, &page_now, &count));
    try ok(D.siv_docview_go_to(b.node, &loc, len));
    var page_go: u32 = 0;
    try ok(D.siv_docview_get_page(b.node, &page_go, &count));
    try testing.expectEqual(page_now, page_go);
    try testing.expect(page_now > 2);
}

test "epub: a spread of two pages, drama, and verse" {
    var b: Book = .{};
    try b.start("test/doc/epub/earnest.epub", 1200, 760);
    defer b.stop();
    try b.show(try spineOf(b.epub, "epub/text/act-1.xhtml"), .{ .spread = true });
    try b.h.expectGolden("epub-earnest-spread", 1200, 760);
    try testing.expect(b.pages > 2);
    // Spreads turn two pages at a time.
    try ok(D.siv_docview_set_page(b.node, 3));
    try b.h.settle();
    try testing.expectEqual(@as(u32, 2), b.page);

    var c: Book = .{};
    try c.start("test/doc/epub/alice.epub", 640, 860);
    defer c.stop();
    try c.show(try spineOf(c.epub, "epub/text/chapter-2.xhtml"), .{});
    try c.h.expectGolden("epub-alice-page1", 640, 860);
}

test "epub: footnotes for popups" {
    var b: Book = .{};
    try b.start("test/doc/epub/jekyll.epub", 640, 860);
    defer b.stop();
    try b.show(try spineOf(b.epub, "epub/text/colophon.xhtml"), .{});
    var html: [4096]u8 = undefined;
    var len: usize = 0;
    // Any element by id: the colophon's section.
    try ok(D.siv_docview_get_element_html(b.node, "colophon", 8, &html, html.len, &len));
    try testing.expect(std.mem.startsWith(u8, html[0..@min(len, html.len)], "<section"));
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_docview_get_element_html(b.node, "nope", 4, &html, html.len, &len));
}
