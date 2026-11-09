//! Document nodes (D32) through the C API on the headless backend:
//! Markdown and HTML rendered against golden images, resources from the
//! application's loader, links, find, selection, locators, and what
//! assistive technology sees.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const harness = @import("harness.zig");
const ui_mod = @import("ui");
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

test "C API docview: an unchecked task box stands out from a dark theme's canvas" {
    var h: Harness = .{};
    try h.start(120, 40, null, null);
    defer h.stop();
    try ok(abi.theme.siv_app_set_theme(h.app, &.{ .scheme = .dark }));
    var ev: Events = .{};
    const root = A.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const src = "- [ ] x";
    _ = D.siv_docview(txn, root, &.{ .source = src.ptr, .source_count = src.len, .kind = .markdown, .color_scheme = .theme, .user_data = &ev, .on_event = Events.onEvent });
    try ok(T.siv_txn_commit(txn));
    try waitLoaded(&h, &ev, 1);
    const img = try h.capture();
    defer testing.allocator.free(img);
    // The box's outline, left of the text, against the canvas in the
    // corner: a dark theme's control border had all but vanished there.
    const lum = struct {
        fn f(px: []const u8) i32 {
            return @divTrunc(@as(i32, px[0]) * 3 + @as(i32, px[1]) * 6 + px[2], 10);
        }
    }.f;
    const canvas = lum(img[0..4]);
    var most: i32 = 0;
    for (0..40) |y| for (0..44) |x| {
        most = @max(most, @as(i32, @intCast(@abs(lum(img[(y * 120 + x) * 4 ..][0..4]) - canvas))));
    };
    try testing.expect(most > 60);
}

test "C API docview: Markdown rendered to HTML for export" {
    var h: Harness = .{};
    try h.start(40, 40, null, null);
    defer h.stop();
    const md = "# Notes\n\n- [x] *done*\n";
    var len: usize = 0;
    try ok(D.siv_markdown_to_html(h.app, md.ptr, md.len, null, 0, &len));
    var buf: [256]u8 = undefined;
    try ok(D.siv_markdown_to_html(h.app, md.ptr, md.len, &buf, buf.len, &len));
    try testing.expectEqualStrings("<h1>Notes</h1>\n<ul>\n<li class=\"task-list-item\"><input type=\"checkbox\" checked=\"\" disabled=\"\" /> <em>done</em></li>\n</ul>\n", buf[0..len]);
}

/// A page of "HIOn" in `family`, rendered with the default font set to
/// SivTest and Droid standing in for Fontconfig's sans-serif.
fn renderFamily(family: []const u8) ![]u8 {
    var h: Harness = .{};
    try h.start(120, 40, null, null);
    defer h.stop();
    const tf = @import("text").font.test_fonts;
    try ok(A.siv_app_add_font(h.app, "SivTest", 7, tf.siv_regular.ptr, tf.siv_regular.len));
    try ok(A.siv_app_add_font(h.app, "sans-serif", 10, tf.latin.ptr, tf.latin.len));
    try ok(A.siv_app_set_default_font(h.app, "SivTest", 7));
    var ev: Events = .{};
    var buf: [128]u8 = undefined;
    const html = try std.fmt.bufPrint(&buf, "<p style=\"font: 20px {s}; margin: 4px\">HIOn HIOn</p>", .{family});
    _ = try build(&h, &ev, .html, html, .{}, "file:///");
    try waitLoaded(&h, &ev, 1);
    return h.capture();
}

test "C API docview: system-ui is the application's default family" {
    const ui = try renderFamily("system-ui");
    defer testing.allocator.free(ui);
    const named = try renderFamily("SivTest");
    defer testing.allocator.free(named);
    const sans = try renderFamily("sans-serif");
    defer testing.allocator.free(sans);
    try testing.expectEqualSlices(u8, named, ui);
    try testing.expect(!std.mem.eql(u8, sans, ui));
}

/// Mail as parcel shows it (untrusted, quotes collapsed, its user style
/// sheet), in a 600 px wide window under Omarchy's Tokyo Night or the
/// stock light theme, colors converted or not; checked against a golden
/// image when `golden` names one. Returns what the window showed.
fn renderMail(comptime name: []const u8, height: u32, tokyo: bool, convert: bool, golden: ?[]const u8) ![]u8 {
    const Mail = struct {
        const logo = @embedFile("../doc/email/schemes/cid/logo@lumen");
        fn onLoad(_: ?*anyopaque, node: t.Node, request: u32, url: ?[*]const u8, len: usize, _: t.ResourceKind) callconv(.c) void {
            const data: []const u8 = if (std.mem.eql(u8, url.?[0..len], "cid:logo@lumen")) logo else "";
            ok(D.siv_docview_supply(node, request, data.ptr, data.len)) catch unreachable;
        }
    };
    const source = @embedFile("../doc/email/schemes/" ++ name ++ ".html");
    const css = "body { margin: 0; font-family: system-ui, sans-serif; line-height: 1.45 }";
    var h: Harness = .{};
    try h.start(600, height, null, null);
    defer h.stop();
    if (tokyo) {
        (try h.internal()).app.setUserTheme(&ui_mod.user_theme.omarchy(@embedFile("../themes/omarchy/tokyo-night/colors.toml"), false));
        try h.settle();
    }
    var ev: Events = .{};
    const root = A.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const sc = T.siv_scroll(txn, root, .vertical);
    _ = T.siv_set_layout(txn, sc, &.{ .size = @sizeOf(t.LayoutDesc), .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
    _ = D.siv_docview(txn, sc, &.{
        .source = source.ptr,
        .source_count = source.len,
        .base_url = "cid:",
        .base_url_len = 4,
        .user_css = css,
        .user_css_len = css.len,
        .kind = .html,
        .color_scheme = .theme,
        .flags = .{ .untrusted = true, .collapse_quotes = true, .convert_colors = convert },
        .user_data = &ev,
        .on_event = Events.onEvent,
        .load = Mail.onLoad,
    });
    try ok(T.siv_txn_commit(txn));
    try waitLoaded(&h, &ev, 1);
    if (golden) |g| try h.expectGolden(g, 600, height);
    return h.capture();
}

test "C API docview: mail under a dark theme shows light unless it allows dark, and converts on request" {
    const Case = struct { []const u8, u32, enum { light, theme, own_dark } };
    inline for (.{
        // Outlook mobile: every paragraph black, a white signature, the
        // quote collapsed.
        Case{ "outlook-mobile", 234, .light },
        // A notification: white body and tables, a gray card, a logo.
        Case{ "notification", 334, .light },
        // A newsletter: a colored band, light and saturated buttons.
        Case{ "newsletter", 430, .light },
        // No colors at all: nothing to clash with, so the theme's.
        Case{ "bare", 116, .theme },
        Case{ "plain", 300, .theme },
        // Dark styles of its own (prefers-color-scheme: dark).
        Case{ "dark-styles", 260, .own_dark },
    }) |c| {
        const name, const height, const kind = c;
        const gpa = testing.allocator;
        // The stock light theme: converting changes nothing.
        const light = try renderMail(name, height, false, false, null);
        defer gpa.free(light);
        const light_converted = try renderMail(name, height, false, true, null);
        defer gpa.free(light_converted);
        try testing.expectEqualSlices(u8, light, light_converted);
        const dark = try renderMail(name, height, true, false, "docview-scheme-" ++ name);
        defer gpa.free(dark);
        switch (kind) {
            // A document with colors of its own shows as in a light
            // theme: none of Tokyo Night's colors mixed with its own.
            .light => {
                try testing.expectEqualSlices(u8, light, dark);
                const converted = try renderMail(name, height, true, true, "docview-scheme-" ++ name ++ "-converted");
                gpa.free(converted);
            },
            // Following the theme or dark already: left alone.
            .theme, .own_dark => {
                try testing.expect(!std.mem.eql(u8, light, dark));
                const converted = try renderMail(name, height, true, true, null);
                defer gpa.free(converted);
                try testing.expectEqualSlices(u8, dark, converted);
            },
        }
    }
}

/// The cursor the headless backend shows over the harness's window.
fn cursor(h: *Harness) !@import("platform").CursorShape {
    const Ctx = struct {
        wid: @import("platform").WindowId,
        out: @import("platform").CursorShape = .default,
        fn run(c: ?*anyopaque, comp: *@import("compositor").Compositor) void {
            const s: *@This() = @ptrCast(@alignCast(c));
            s.out = comp.platform.headless.cursorOf(s.wid);
        }
    };
    var c: Ctx = .{ .wid = (try h.win()).win.id };
    try (try h.internal()).app.comp.call(&c, Ctx.run);
    return c.out;
}

test "C API docview: :hover restyles what the pointer is over, and links show the pointer cursor" {
    var h: Harness = .{};
    try h.start(300, 160, null, null);
    defer h.stop();
    var ev: Events = .{};
    const mail =
        \\<style>a:hover { color: rgb(220 0 0) } .row:hover td { background: rgb(0 0 220) }</style>
        \\<p style="margin: 8px"><a href="https://example.com/">Link</a> and text</p>
        \\<table style="margin: 8px"><tr class="row"><td>Cell</td><td>More</td></tr></table>
    ;
    _ = try build(&h, &ev, .html, mail, .{}, "file:///mail/");
    try waitLoaded(&h, &ev, 1);
    const w = try h.win();
    const sem = try w.uiWin().semanticsTree();
    const link = (sem.find(.link, "Link") orelse return error.NoLink).bounds;
    const cell = (sem.find(.cell, "Cell") orelse return error.NoCell).bounds;
    const wid = w.win.id;
    const Count = struct {
        /// Pixels in `r` mostly of one channel (0 red, 2 blue).
        fn of(img: []const u8, r: anytype, ch: usize) usize {
            var n: usize = 0;
            var y: usize = @intFromFloat(r.y0);
            while (y < @as(usize, @intFromFloat(r.y1))) : (y += 1) {
                var x: usize = @intFromFloat(r.x0);
                while (x < @as(usize, @intFromFloat(r.x1))) : (x += 1) {
                    const px = img[(y * 300 + x) * 4 ..][0..4];
                    var others: u32 = 0;
                    for (0..3) |k| if (k != ch) {
                        others = @max(others, px[k]);
                    };
                    if (px[ch] > 150 and others < 60) n += 1;
                }
            }
            return n;
        }
    };
    const move = struct {
        fn f(hh: *Harness, id: anytype, x: f32, y: f32) !void {
            try hh.inject(&.{.{ .pointer_motion = .{ .window = id, .seat = 0, .x = x, .y = y } }});
            try hh.settle();
        }
    }.f;
    // Off the link: neither is restyled.
    try move(&h, wid, 280, 150);
    var img = try h.capture();
    try testing.expectEqual(0, Count.of(img, link, 0));
    try testing.expectEqual(0, Count.of(img, cell, 2));
    testing.allocator.free(img);
    // Over the link: it turns red and shows the pointer cursor.
    try move(&h, wid, (link.x0 + link.x1) / 2, (link.y0 + link.y1) / 2);
    img = try h.capture();
    try testing.expect(Count.of(img, link, 0) > 10);
    try testing.expectEqual(0, Count.of(img, cell, 2));
    try testing.expectEqual(@import("platform").CursorShape.pointer, try cursor(&h));
    testing.allocator.free(img);
    // Over the cell: the row's descendant rule, and the link is back.
    try move(&h, wid, (cell.x0 + cell.x1) / 2, (cell.y0 + cell.y1) / 2);
    img = try h.capture();
    try testing.expectEqual(0, Count.of(img, link, 0));
    try testing.expect(Count.of(img, cell, 2) > 50);
    try testing.expectEqual(@import("platform").CursorShape.default, try cursor(&h));
    testing.allocator.free(img);
    // Out of the window: nothing hovered.
    try h.inject(&.{.{ .pointer_leave = .{ .window = wid, .seat = 0, .serial = 9 } }});
    try h.settle();
    img = try h.capture();
    defer testing.allocator.free(img);
    try testing.expectEqual(0, Count.of(img, cell, 2));
}

test "C API docview: content scrolled under a resting pointer takes the hover and the cursor" {
    var h: Harness = .{};
    try h.start(300, 160, null, null);
    defer h.stop();
    var ev: Events = .{};
    // Links 320 pixels apart in a document four windows tall.
    const page =
        \\<style>a:hover { color: rgb(220 0 0) }</style>
        \\<body style="margin: 0">
        \\<p style="margin: 0; line-height: 20px"><a href="https://example.com/top">Top</a></p>
        \\<div style="height: 300px"></div>
        \\<p style="margin: 0; line-height: 20px"><a href="https://example.com/bottom">Bottom</a></p>
        \\<div style="height: 300px"></div>
    ;
    const root = A.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const sc = T.siv_scroll(txn, root, .vertical);
    _ = T.siv_set_layout(txn, sc, &.{ .size = @sizeOf(t.LayoutDesc), .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
    _ = D.siv_docview(txn, sc, &.{
        .source = page.ptr,
        .source_count = page.len,
        .kind = .html,
        .color_scheme = .light,
        .user_data = &ev,
        .on_event = Events.onEvent,
        .load = Events.onLoad,
    });
    try ok(T.siv_txn_commit(txn));
    try waitLoaded(&h, &ev, 1);
    const wid = (try h.win()).win.id;
    const top = ((try (try h.win()).uiWin().semanticsTree()).find(.link, "Top") orelse return error.NoLink).bounds;
    const at: [2]f32 = .{ top.x0 + 4, (top.y0 + top.y1) / 2 };
    const reds = struct {
        /// Pixels of the hovered links' red.
        fn f(hh: *Harness) !usize {
            const img = try hh.capture();
            defer testing.allocator.free(img);
            var n: usize = 0;
            var i: usize = 0;
            while (i < img.len) : (i += 4) {
                if (img[i] > 150 and img[i + 1] < 60 and img[i + 2] < 60) n += 1;
            }
            return n;
        }
    }.f;

    // Over the top link: hovered, the hand.
    try h.inject(&.{.{ .pointer_motion = .{ .window = wid, .seat = 0, .x = at[0], .y = at[1] } }});
    try h.settle();
    try testing.expectEqual(@import("platform").CursorShape.pointer, try cursor(&h));
    try testing.expect(try reds(&h) > 10);
    // The wheel scrolls it out from under the pointer, which rests on
    // the space below it: no hover, the arrow.
    try h.inject(&.{.{ .scroll = .{ .window = wid, .seat = 0, .dy = 80, .source = .wheel } }});
    try h.settle();
    var ox: f32 = 0;
    var oy: f32 = 0;
    try ok(T.siv_scroll_get_offset(sc, &ox, &oy));
    try testing.expect(oy > 20 and oy < 300);
    try testing.expectEqual(@import("platform").CursorShape.default, try cursor(&h));
    try testing.expectEqual(0, try reds(&h));
    // The application scrolls the bottom link under it: hovered, the
    // hand.
    try ok(T.siv_txn_begin(h.window, &txn));
    T.siv_scroll_by(txn, sc, .pixel, 0, 320 - oy);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try ok(T.siv_scroll_get_offset(sc, &ox, &oy));
    try testing.expectEqual(@as(f32, 320), oy);
    try testing.expectEqual(@import("platform").CursorShape.pointer, try cursor(&h));
    try testing.expect(try reds(&h) > 10);
    // And sets an offset that leaves the space under it.
    try ok(T.siv_txn_begin(h.window, &txn));
    T.siv_scroll_to(txn, sc, 0, 160);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(@import("platform").CursorShape.default, try cursor(&h));
    try testing.expectEqual(0, try reds(&h));
}

test "C API docview: no_author_styles ignores style sheets and style attributes" {
    const source =
        \\<style>div { height: 20px; background: rgb(0 0 200) }</style>
        \\<body style="margin: 0"><p style="margin: 0; height: 30px; background: rgb(200 0 0)">x</p><div></div>
    ;
    const red: [3]u8 = .{ 200, 0, 0 };
    const blue: [3]u8 = .{ 0, 0, 200 };
    for ([_]bool{ false, true }) |off| {
        var h: Harness = .{};
        try h.start(100, 60, null, null);
        defer h.stop();
        var ev: Events = .{};
        _ = try build(&h, &ev, .html, source, .{ .no_author_styles = off }, "file:///");
        try waitLoaded(&h, &ev, 1);
        const img = try h.capture();
        defer testing.allocator.free(img);
        if (!off) {
            // The paragraph's background from its attribute, the div's
            // from the sheet.
            try testing.expectEqual(red, img[(15 * 100 + 90) * 4 ..][0..3].*);
            try testing.expectEqual(blue, img[(40 * 100 + 90) * 4 ..][0..3].*);
        } else {
            // Neither anywhere.
            var i: usize = 0;
            while (i < img.len) : (i += 4) {
                try testing.expect(!std.mem.eql(u8, img[i..][0..3], &red));
                try testing.expect(!std.mem.eql(u8, img[i..][0..3], &blue));
            }
        }
    }
}

test "C API docview: flags change in place, keeping the place, open quotes, selection, and images" {
    var h: Harness = .{};
    try h.start(300, 150, null, null);
    defer h.stop();
    const Loader = struct {
        var requests: u32 = 0;
        var remote: u32 = 0;
        fn onLoad(_: ?*anyopaque, node: t.Node, request: u32, url: ?[*]const u8, len: usize, _: t.ResourceKind) callconv(.c) void {
            requests += 1;
            const u = url.?[0..len];
            if (std.mem.startsWith(u8, u, "https:")) remote += 1;
            const svg = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='#2a7'/></svg>";
            const data: []const u8 = if (std.mem.eql(u8, u, "cid:logo")) svg else "";
            ok(D.siv_docview_supply(node, request, data.ptr, data.len)) catch unreachable;
        }
    };
    // Mail with colors of its own, so that a dark preference converts it.
    const mail =
        \\<body style="margin: 8px; background: white; color: black"><p>See you then.</p>
        \\<div class="gmail_quote"><div>On Mon, Ann wrote:</div><blockquote class="gmail_quote">Lunch at noon?<br>Ann</blockquote></div>
        \\<p><img src="cid:logo" alt="logo" width=40 height=20><img src="https://tracker.example/p.gif" width=1 height=1>
        \\<p style="height: 400px">Tall</p><p>End</p>
    ;
    const created: t.DocviewFlags = .{ .untrusted = true, .collapse_quotes = true };
    var ev: Events = .{};
    const root = A.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const sc = T.siv_scroll(txn, root, .vertical);
    _ = T.siv_set_layout(txn, sc, &.{ .size = @sizeOf(t.LayoutDesc), .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
    const node = D.siv_docview(txn, sc, &.{
        .source = mail.ptr,
        .source_count = mail.len,
        .base_url = "cid:",
        .base_url_len = 4,
        .kind = .html,
        .color_scheme = .dark,
        .flags = created,
        .user_data = &ev,
        .on_event = Events.onEvent,
        .load = Loader.onLoad,
    });
    try ok(T.siv_txn_commit(txn));
    try waitLoaded(&h, &ev, 1);
    try testing.expectEqual(@as(u32, 1), ev.blocked);

    // The reader opens the quote, selects, and scrolls down.
    const w = try h.win();
    const toggle = (try w.uiWin().semanticsTree()).find(.link, "\u{2022}\u{2022}\u{2022}") orelse return error.NoToggle;
    try h.click((toggle.bounds.x0 + toggle.bounds.x1) / 2, (toggle.bounds.y0 + toggle.bounds.y1) / 2);
    try waitLoaded(&h, &ev, ev.loaded + 1);
    try ok(D.siv_docview_select_all(node));
    var before: [256]u8 = undefined;
    var before_len: usize = 0;
    try ok(D.siv_docview_get_selection(node, &before, before.len, &before_len));
    try testing.expect(std.mem.indexOf(u8, before[0..before_len], "Lunch at noon?") != null);
    try ok(T.siv_txn_begin(h.window, &txn));
    T.siv_scroll_to(txn, sc, 0, 100);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    const original = try h.capture();
    defer testing.allocator.free(original);
    const loaded = ev.loaded;
    const requests = Loader.requests;
    try testing.expect(requests > 0);

    // The right margin, in the page's color.
    const margin = struct {
        fn f(img: []const u8) [3]u8 {
            const px = img[(140 * 300 + 296) * 4 ..][0..3];
            return px.*;
        }
    }.f;
    try testing.expectEqual([3]u8{ 255, 255, 255 }, margin(original));

    // Converting repaints: the page turns the stock dark background, and
    // nothing is parsed, styled, laid out, or loaded again.
    var on = created;
    on.convert_colors = true;
    try ok(D.siv_docview_set_flags(node, on));
    try h.settle();
    const converted = try h.capture();
    defer testing.allocator.free(converted);
    try testing.expectEqual([3]u8{ 0x1e, 0x1e, 0x1e }, margin(converted));
    try testing.expectEqual(loaded, ev.loaded);
    try testing.expectEqual(requests, Loader.requests);
    var after: [256]u8 = undefined;
    var after_len: usize = 0;
    try ok(D.siv_docview_get_selection(node, &after, after.len, &after_len));
    try testing.expectEqualStrings(before[0..before_len], after[0..after_len]);
    var ox: f32 = 0;
    var oy: f32 = 0;
    try ok(T.siv_scroll_get_offset(sc, &ox, &oy));
    try testing.expectEqual(@as(f32, 100), oy);

    // And back: what showed before, exactly.
    try ok(D.siv_docview_set_flags(node, created));
    try h.settle();
    const back = try h.capture();
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, original, back);

    // Flags that parsing or page layout used are fixed: the call fails
    // and changes nothing, convert_colors with them included.
    for ([_]t.DocviewFlags{
        .{ .collapse_quotes = true, .convert_colors = true },
        .{ .untrusted = true, .convert_colors = true },
        .{ .untrusted = true, .collapse_quotes = true, .no_author_styles = true },
        .{ .untrusted = true, .collapse_quotes = true, .paged = true },
        .{ .untrusted = true, .collapse_quotes = true, .reading = true },
    }) |fl| try testing.expectEqual(t.Result.error_invalid_argument, D.siv_docview_set_flags(node, fl));
    try testing.expectEqual(t.Result.error_unsupported, D.siv_docview_set_flags(node, @bitCast(@as(u32, 1 << 20))));
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_docview_set_flags(root, created));
    try h.settle();
    const unchanged = try h.capture();
    defer testing.allocator.free(unchanged);
    try testing.expectEqualSlices(u8, original, unchanged);

    // Remote images can be allowed later, as siv_docview_load_images
    // allows them, but not taken back.
    var remote = created;
    remote.remote_images = true;
    try ok(D.siv_docview_set_flags(node, remote));
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (Loader.remote < 1) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 2));
    }
    try h.settle();
    try testing.expectEqual(t.Result.error_invalid_argument, D.siv_docview_set_flags(node, created));
}

test "C API docview: 1px borders are whole device pixels of one shade at fractional scales and zooms" {
    // An email's table (parcel, Austrian Airlines): a 1px border around
    // it, cells with borders just inside it, and rules of other grays.
    const source =
        \\<body style="margin:5px;background:#fff">
        \\<table width="170" cellpadding="0" cellspacing="0" style="border:1px solid #cccccc">
        \\<tr><td><table width="100%" cellpadding="0" cellspacing="0">
        \\<tr><td style="border-right:1px solid #cccccc;height:33px"></td></tr>
        \\<tr><td style="border-right:1px solid #cccccc;height:17.5px;border-top:1px solid #dddddd"></td></tr>
        \\<tr><td style="border-right:1px solid #cccccc;height:41px"></td></tr>
        \\<tr><td style="border-right:1px solid #cccccc;height:23px"></td></tr>
        \\</table></td></tr>
        \\<tr><td style="border-top:1px solid #cccccc;padding:13px 27px">
        \\<table width="100%" cellpadding="0" cellspacing="0"><tr>
        \\<td width="60" style="border-top:1px solid #999999;height:10px"></td>
        \\<td style="border-top:1px solid #dddddd;height:10px"></td>
        \\</tr></table></td></tr>
        \\</table>
    ;
    const Case = struct { v120: u32, zoom: f32, offset: f32 };
    for ([_]Case{
        .{ .v120 = 180, .zoom = 1, .offset = 0 },
        .{ .v120 = 150, .zoom = 1, .offset = 0 },
        // parcel zooms its reader in the compositor; the offset leaves the
        // content at a fraction of a pixel too.
        .{ .v120 = 180, .zoom = 1.1, .offset = 0.7 },
    }) |c| {
        var h: Harness = .{};
        try h.start(200, 150, null, null);
        defer h.stop();
        const Scale = struct {
            id: @import("platform").WindowId,
            v120: u32,
            fn run(ctx: ?*anyopaque, comp: *@import("compositor").Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(ctx));
                comp.platform.headless.setScale(s.id, .{ .v120 = s.v120 });
            }
        };
        var scale: Scale = .{ .id = (try h.win()).win.id, .v120 = c.v120 };
        try (try h.internal()).app.comp.call(&scale, Scale.run);
        try h.settle();
        var ev: Events = .{};
        const root = A.siv_window_get_root(h.window);
        var txn: t.Txn = .null;
        try ok(T.siv_txn_begin(h.window, &txn));
        const sc = T.siv_scroll(txn, root, .vertical);
        _ = T.siv_set_layout(txn, sc, &.{ .size = @sizeOf(t.LayoutDesc), .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
        T.siv_set_scroll_zoom_range(txn, sc, 0.5, 4);
        _ = D.siv_docview(txn, sc, &.{ .source = source.ptr, .source_count = source.len, .kind = .html, .color_scheme = .light, .flags = .{ .untrusted = true }, .user_data = &ev, .on_event = Events.onEvent });
        try ok(T.siv_txn_commit(txn));
        try waitLoaded(&h, &ev, 1);
        if (c.zoom != 1) {
            try ok(T.siv_txn_begin(h.window, &txn));
            T.siv_scroll_zoom_to(txn, sc, c.zoom);
            T.siv_scroll_to(txn, sc, 0, c.offset);
            try ok(T.siv_txn_commit(txn));
            try h.settle();
        }
        const img = try h.capture();
        defer testing.allocator.free(img);
        const w: usize = (200 * c.v120 + 60) / 120;
        const ht: usize = (150 * c.v120 + 60) / 120;
        try testing.expectEqual(w * ht * 4, img.len);
        const Px = struct {
            /// White, or within 1 of one of the borders' grays (dithering);
            /// anything between is a border smeared over partial pixels.
            fn kind(p: []const u8) ?u8 {
                for ([_]u8{ 0xff, 0xcc, 0xdd, 0x99 }) |g| {
                    const ok_ = for (p[0..3]) |ch| {
                        if (@abs(@as(i16, ch) - g) > 1) break false;
                    } else true;
                    if (ok_) return g;
                }
                return null;
            }
        };
        // Rows through the first cell cross the table's left border, the
        // cell's right border, and the table's right border; columns
        // through the middle cross every horizontal rule. Each line is
        // whole pixels of its gray, in the same place along its length.
        var first: [512]u8 = undefined;
        for (0..2) |axis| {
            const n = if (axis == 0) w else ht - 2;
            const along: [2]usize = if (axis == 0) .{ 16, 44 } else .{ w * 6 / 10, w * 7 / 10 };
            for (along[0]..along[1]) |a| {
                for (0..n) |i| {
                    const x, const y = if (axis == 0) .{ i, a } else .{ a, i };
                    const g = Px.kind(img[(y * w + x) * 4 ..][0..4]) orelse {
                        std.debug.print("scale {d}/120 zoom {d}: partial pixel {x} at {d},{d}\n", .{ c.v120, c.zoom, img[(y * w + x) * 4 ..][0..3], x, y });
                        return error.TestUnexpectedResult;
                    };
                    if (a == along[0]) first[i] = g else try testing.expectEqual(first[i], g);
                }
            }
            // Every border shows.
            var lines: usize = 0;
            for (0..n) |i| {
                if (first[i] != 0xff and (i == 0 or first[i - 1] == 0xff)) lines += 1;
            }
            try testing.expect(lines >= 2);
        }
    }
}
