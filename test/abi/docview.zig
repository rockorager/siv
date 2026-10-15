//! Document nodes (D32) through the C API on the headless backend:
//! Markdown and HTML rendered against golden images, resources from the
//! application's loader, links, find, selection, locators, and what
//! assistive technology sees.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const harness = @import("harness.zig");
const Loop = @import("loop").Loop;

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const T = abi.tree;
const D = abi.document;
const Harness = harness.Harness;
const ok = harness.ok;

const Events = struct {
    loaded: u32 = 0,
    links: u32 = 0,
    link: [128]u8 = undefined,
    link_len: usize = 0,
    find_count: u32 = 0,
    find_current: u32 = 0,
    blocked: u32 = 0,
    selections: u32 = 0,
    requests: u32 = 0,
    last_request: u32 = 0,
    last_url: [128]u8 = undefined,
    last_url_len: usize = 0,

    fn onEvent(user: ?*anyopaque, _: t.Node, e: *const t.DocviewEvent) callconv(.c) void {
        const ev: *Events = @ptrCast(@alignCast(user));
        switch (e.type) {
            .loaded => ev.loaded += 1,
            .link => {
                ev.links += 1;
                ev.link_len = @min(e.url_len, ev.link.len);
                @memcpy(ev.link[0..ev.link_len], e.url.?[0..ev.link_len]);
            },
            .find => {
                ev.find_count = e.count;
                ev.find_current = e.current;
            },
            .blocked_images => ev.blocked = e.count,
            .selection => ev.selections += 1,
            else => {},
        }
    }

    fn onLoad(user: ?*anyopaque, _: t.Node, request: u32, url: ?[*]const u8, url_len: usize, _: t.ResourceKind) callconv(.c) void {
        const ev: *Events = @ptrCast(@alignCast(user));
        ev.requests += 1;
        ev.last_request = request;
        ev.last_url_len = @min(url_len, ev.last_url.len);
        @memcpy(ev.last_url[0..ev.last_url_len], url.?[0..ev.last_url_len]);
    }
};

/// Dispatches until the document has been laid out `n` times, then
/// settles.
fn waitLoaded(h: *Harness, ev: *const Events, n: u32) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (ev.loaded < n) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 2));
    }
    try h.settle();
}

fn build(h: *Harness, ev: *Events, kind: t.DocviewKind, source: []const u8, flags: t.DocviewFlags, base: []const u8) !t.Node {
    const root = A.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const sc = T.siv_scroll(txn, root, .vertical);
    _ = T.siv_set_layout(txn, sc, &.{ .size = @sizeOf(t.LayoutDesc), .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
    const node = D.siv_docview(txn, sc, &.{
        .source = source.ptr,
        .source_count = source.len,
        .base_url = base.ptr,
        .base_url_len = base.len,
        .kind = kind,
        .color_scheme = .light,
        .flags = flags,
        .user_data = ev,
        .on_event = Events.onEvent,
        .load = Events.onLoad,
    });
    try ok(T.siv_txn_commit(txn));
    return node;
}

const readme =
    \\# siv
    \\
    \\A *GUI toolkit* for **Wayland**; see the [guide](guide.html) and the [API](#api) in `Zig`.
    \\
    \\- [x] Fast
    \\- [ ] Done
    \\
    \\> Quoted text.
    \\
    \\| Name | Size |
    \\| ---- | ---: |
    \\| siv  |   42 |
    \\
    \\```
    \\code block
    \\```
    \\
    \\## <a name="api"></a>API
    \\
    \\The siv API, ~~old~~ new.
    \\
;

test "C API docview: Markdown rendered, links, find, selection, locators, accessibility" {
    var h: Harness = .{};
    try h.start(400, 300, null, null);
    defer h.stop();
    var ev: Events = .{};
    const node = try build(&h, &ev, .markdown, readme, .{}, "https://example.com/docs/");
    try waitLoaded(&h, &ev, 1);
    try h.expectGolden("docview-markdown", 400, 300);

    // Assistive technology sees the headings, the list, the table, and
    // the links inside the document.
    const w = try h.win();
    const sem = try w.uiWin().semanticsTree();
    try testing.expect(sem.find(.heading, "siv") != null);
    try testing.expect(sem.find(.table, "") != null);
    const guide = sem.find(.link, "guide") orelse return error.NoLink;
    try testing.expectEqual(@as(u8, 2), (sem.find(.heading, "API") orelse return error.NoHeading).level);

    // Clicking a link reports its resolved URL.
    try h.click((guide.bounds.x0 + guide.bounds.x1) / 2, (guide.bounds.y0 + guide.bounds.y1) / 2);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), ev.links);
    try testing.expectEqualStrings("https://example.com/docs/guide.html", ev.link[0..ev.link_len]);

    // Find counts case-insensitively and moves through the matches.
    try ok(D.siv_docview_find(node, "SIV", 3, false));
    try testing.expectEqual(@as(u32, 3), ev.find_count);
    try testing.expectEqual(@as(u32, 1), ev.find_current);
    try ok(D.siv_docview_find(node, "SIV", 3, false));
    try testing.expectEqual(@as(u32, 2), ev.find_current);
    try ok(D.siv_docview_find(node, "SIV", 3, true));
    try testing.expectEqual(@as(u32, 1), ev.find_current);
    try ok(D.siv_docview_find(node, "", 0, false));
    try testing.expectEqual(@as(u32, 0), ev.find_count);

    // Select all, and read it back.
    try ok(D.siv_docview_select_all(node));
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    try ok(D.siv_docview_get_selection(node, &buf, buf.len, &len));
    try testing.expect(std.mem.startsWith(u8, buf[0..len], "siv\nA GUI toolkit for Wayland; see the guide"));
    try testing.expect(std.mem.indexOf(u8, buf[0..len], "code block") != null);

    // A locator finds its place again.
    var loc: [64]u8 = undefined;
    try ok(D.siv_docview_get_locator(node, 120, &loc, loc.len, &len));
    var y: f32 = 0;
    try ok(D.siv_docview_get_locator_y(node, &loc, len, &y));
    try testing.expect(@abs(y - 120) < 60);

    // Not a document.
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_docview_select_all(A.siv_window_get_root(h.window)));
}

test "C API docview: HTML with a stylesheet and images from the loader, remote images blocked" {
    var h: Harness = .{};
    try h.start(300, 200, null, null);
    defer h.stop();
    var ev: Events = .{};
    const html =
        \\<!doctype html><title>Receipt</title><link rel=stylesheet href="style.css">
        \\<h1>Thanks</h1><p class=note>Total: <b>$42</b></p>
        \\<img src="https://tracker.example/pixel.gif" width=1 height=1>
        \\<p><img src="cid:logo" alt="logo" width=40 height=20>
    ;
    // A message's parts are local; the tracking pixel is remote.
    const node = try build(&h, &ev, .html, html, .{}, "file:///mail/");
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (ev.requests < 2) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 2));
    }
    try testing.expectEqual(@as(u32, 1), ev.blocked);
    // Requests: the sheet, then the cid: image; answer both.
    try testing.expectEqualStrings("cid:logo", ev.last_url[0..ev.last_url_len]);
    const css = "h1 { color: rgb(200 0 0); border-bottom: 2px solid oklch(60% 0.15 250) } .note { background: color-mix(in srgb, yellow 50%, white) }";
    try ok(D.siv_docview_supply(node, 0, css, css.len));
    const svg = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='#2a7'/></svg>";
    try ok(D.siv_docview_supply(node, ev.last_request, svg, svg.len));
    try waitLoaded(&h, &ev, ev.loaded + 1);
    try h.settle();
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    try ok(D.siv_docview_get_title(node, &buf, buf.len, &len));
    try testing.expectEqualStrings("Receipt", buf[0..len]);
    try h.expectGolden("docview-html", 300, 200);
}

test "C API docview: a loader that supplies from its callback, two stylesheets" {
    var h: Harness = .{};
    try h.start(300, 200, null, null);
    defer h.stop();
    const Sync = struct {
        var requests: u32 = 0;
        const pad: [8000]u8 = @splat('x');
        const big = "h1 { color: rgb(200 0 0); font-family: sans-serif } /*" ++ pad ++ "*/";
        fn onLoad(_: ?*anyopaque, node: t.Node, request: u32, _: ?[*]const u8, _: usize, _: t.ResourceKind) callconv(.c) void {
            requests += 1;
            // Sizes far apart, so the allocator does not hand the first
            // sheet's freed copy to the second.
            const css: []const u8 = if (request == 0) big else "p { color: rgb(0 0 200); font-family: serif }";
            ok(D.siv_docview_supply(node, request, css.ptr, css.len)) catch unreachable;
        }
    };
    var ev: Events = .{};
    const html =
        \\<!doctype html><link rel=stylesheet href="a.css"><link rel=stylesheet href="b.css">
        \\<h1>Title</h1><p>Text
    ;
    const root = A.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const sc = T.siv_scroll(txn, root, .vertical);
    _ = D.siv_docview(txn, sc, &.{ .source = html.ptr, .source_count = html.len, .base_url = "file:///doc/", .base_url_len = 12, .kind = .html, .user_data = &ev, .on_event = Events.onEvent, .load = Sync.onLoad });
    try ok(T.siv_txn_commit(txn));
    // Both answered inside the callbacks, while the parsed document is
    // still being set up: each is applied once, after that.
    try waitLoaded(&h, &ev, 1);
    try testing.expectEqual(@as(u32, 2), Sync.requests);
}

test "C API docview: email with a collapsed quote that a click opens" {
    var h: Harness = .{};
    try h.start(300, 200, null, null);
    defer h.stop();
    var ev: Events = .{};
    const mail =
        \\<div dir=ltr>See you then.</div><div class="gmail_quote"><div>On Mon, Ann wrote:</div>
        \\<blockquote class="gmail_quote">Lunch at noon?<br>Ann</blockquote></div>
        \\<script>alert(1)</script><a href="javascript:alert(2)">no link</a>
    ;
    const node = try build(&h, &ev, .html, mail, .{ .untrusted = true, .collapse_quotes = true }, "file:///mail/");
    try waitLoaded(&h, &ev, 1);
    const w = try h.win();
    var sem = try w.uiWin().semanticsTree();
    // The quote is hidden behind its toggle; the javascript: link is no
    // link at all.
    try testing.expect(sem.find(.paragraph, "Lunch at noon? Ann") == null);
    const toggle = sem.find(.link, "\u{2022}\u{2022}\u{2022}") orelse return error.NoToggle;
    try testing.expect(sem.find(.link, "no link") == null);
    const loaded = ev.loaded;
    try h.click((toggle.bounds.x0 + toggle.bounds.x1) / 2, (toggle.bounds.y0 + toggle.bounds.y1) / 2);
    try waitLoaded(&h, &ev, loaded + 1);
    // Open: its text is part of the document now.
    try ok(D.siv_docview_select_all(node));
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    try ok(D.siv_docview_get_selection(node, &buf, buf.len, &len));
    try testing.expect(std.mem.indexOf(u8, buf[0..len], "Lunch at noon?") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..len], "alert") == null);
}
