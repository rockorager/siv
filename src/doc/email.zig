//! HTML email (D32): quoted replies found and wrapped so that they can be
//! collapsed, and untrusted HTML cleaned of what a document renderer must
//! not act on. Both work on the DOM before styling.

const std = @import("std");
const html = @import("html");

const Dom = html.Dom;
const NodeId = html.NodeId;
const Allocator = std.mem.Allocator;

/// Elements removed from untrusted HTML with their content: scripts and
/// embedded browsing contexts never run here, and their fallback text is
/// not meant to be read.
const dropped = [_]html.Atom{ .script, .iframe, .frame, .frameset, .object, .embed, .applet };

/// Cleans untrusted HTML: drops scripts and embedded content, links to
/// `javascript:` and other active schemes, and `<base>`, which would point
/// every link elsewhere. Styles stay: the cascade keeps positioning from
/// covering the page (`Env.untrusted`).
pub fn sanitize(dom: *Dom) void {
    const http_equiv = dom.lookup("http-equiv");
    var cur = dom.documentElement();
    const root = cur;
    while (cur != .none) {
        const n = dom.node(cur);
        if (n.kind == .element and n.ns == .html) {
            if (std.mem.indexOfScalar(html.Atom, &dropped, n.name) != null or n.name == .base or (n.name == .meta and http_equiv != null and dom.hasAttr(cur, http_equiv.?))) {
                const next = dom.followingSkip(cur, root);
                dom.detach(cur);
                cur = next;
                continue;
            }
            if (n.name == .a or n.name == .area) if (dom.attr(cur, .href)) |h| {
                if (!safeUrl(h)) neuter(dom, cur, .href);
            };
        }
        cur = dom.following(cur, root);
    }
}

/// Whether a link may be followed: a scheme the application can decide on
/// (http, https, mailto, tel, cid, a fragment, or relative), not one that
/// runs code.
fn safeUrl(h: []const u8) bool {
    const t = std.mem.trim(u8, h, " \t\r\n");
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return true;
    // A colon after a path, query, or fragment character is not a scheme's.
    if (std.mem.indexOfAny(u8, t[0..colon], "/?#") != null) return true;
    var scheme: [16]u8 = undefined;
    var n: usize = 0;
    for (t[0..colon]) |ch| {
        if (ch == '\t' or ch == '\n' or ch == '\r') continue;
        if (n == scheme.len) return false;
        scheme[n] = std.ascii.toLower(ch);
        n += 1;
    }
    const s = scheme[0..n];
    for ([_][]const u8{ "http", "https", "mailto", "tel", "cid", "mid", "news", "ftp" }) |ok| if (std.mem.eql(u8, s, ok)) return true;
    return false;
}

/// Renames an attribute out of the way (the DOM has no removal).
fn neuter(dom: *Dom, id: NodeId, name: html.Atom) void {
    const removed = dom.atom("data-siv-removed") catch return;
    const n = dom.node(id);
    const attrs = dom.attrs.items[n.a..][0..n.b];
    for (attrs) |*a| if (a.name == name and a.prefix == .none) {
        a.name = removed;
    };
}

/// Finds quoted replies (Apple Mail's and Thunderbird's
/// `blockquote type=cite`, Gmail's `.gmail_quote`, Yahoo's
/// `.yahoo_quoted`, Outlook's `#divRplyFwdMsg` and the reply header that
/// starts with a top border, with what follows them) and wraps each
/// outermost one in `<div data-siv-quote=N>` after a toggle link to
/// `siv:quote/N`. Returns the wrappers, in order.
pub fn wrapQuotes(gpa: Allocator, dom: *Dom) error{OutOfMemory}![]NodeId {
    var found: std.ArrayList(NodeId) = .empty;
    defer found.deinit(gpa);
    // Outlook's reply header takes the rest of its parent with it.
    var tails: std.ArrayList(bool) = .empty;
    defer tails.deinit(gpa);
    const body = dom.body();
    if (body == .none) return &.{};
    var cur = dom.node(body).first;
    while (cur != .none) {
        const kind = quoteKind(dom, cur);
        if (kind != .none) {
            try found.append(gpa, cur);
            try tails.append(gpa, kind == .tail);
            cur = dom.followingSkip(cur, body);
            continue;
        }
        cur = dom.following(cur, body);
    }
    var wrappers: std.ArrayList(NodeId) = .empty;
    errdefer wrappers.deinit(gpa);
    for (found.items, tails.items, 0..) |q, tail, k| {
        const parent = dom.node(q).parent;
        var num: [16]u8 = undefined;
        const ks = std.fmt.bufPrint(&num, "{d}", .{k}) catch unreachable;
        const href = try std.fmt.allocPrint(gpa, "siv:quote/{d}", .{k});
        defer gpa.free(href);
        const toggle = try dom.createElement(.html, .a, &.{ .{ .name = .href, .value = href }, .{ .name = .class, .value = "siv-quote-toggle" }, .{ .name = .title, .value = "Show quoted text" } });
        dom.append(toggle, try dom.createText("\u{2022}\u{2022}\u{2022}"));
        const wrapper = try dom.createElement(.html, .div, &.{ .{ .name = try dom.atom("data-siv-quote"), .value = ks }, .{ .name = .class, .value = "siv-quote" } });
        dom.insertBefore(parent, toggle, q);
        dom.insertBefore(parent, wrapper, q);
        // Move the quote (and for a reply header, what follows it).
        var m = q;
        while (m != .none) {
            const next = dom.node(m).next;
            dom.detach(m);
            dom.append(wrapper, m);
            if (!tail) break;
            m = next;
        }
        try wrappers.append(gpa, wrapper);
    }
    return wrappers.toOwnedSlice(gpa);
}

const Kind = enum { none, block, tail };

fn quoteKind(dom: *const Dom, id: NodeId) Kind {
    const n = dom.node(id);
    if (n.kind != .element or n.ns != .html) return .none;
    if (n.name == .blockquote) if (dom.attr(id, .type)) |t| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " "), "cite")) return .block;
    };
    if (dom.attr(id, .class)) |cls| {
        var it = std.mem.tokenizeAny(u8, cls, " \t\n");
        while (it.next()) |c| {
            if (std.mem.eql(u8, c, "gmail_quote") or std.mem.eql(u8, c, "gmail_quote_container") or std.mem.eql(u8, c, "yahoo_quoted") or std.mem.eql(u8, c, "protonmail_quote")) return .block;
        }
    }
    if (dom.attr(id, .id)) |v| {
        if (std.mem.eql(u8, v, "divRplyFwdMsg") or std.mem.eql(u8, v, "appendonsend")) return .tail;
    }
    // Outlook for Windows: the reply header is a div with a top border
    // (`border:none;border-top:solid #E1E1E1 1.0pt`).
    if (n.name == .div) if (dom.attr(id, .style)) |st| {
        if (std.ascii.findIgnoreCase(st, "border-top:solid #E1E1E1") != null or std.ascii.findIgnoreCase(st, "border-top:solid #B5C4DF") != null) return .tail;
    };
    return .none;
}

test "quotes from Gmail, Apple Mail, and Outlook are wrapped once" {
    const gpa = std.testing.allocator;
    var dom = try html.parse(gpa,
        \\<p>Sounds good.</p>
        \\<div class="gmail_quote"><div>On Mon, Ann wrote:</div><blockquote class="gmail_quote" type="cite">Lunch?</blockquote></div>
        \\<blockquote type=cite>Apple <blockquote type=cite>nested</blockquote></blockquote>
        \\<div><div id="divRplyFwdMsg">From: Bob</div><div>Old text</div><p>more</p></div>
        \\<a href="javascript:alert(1)">x</a><a href=" JaVa&#x09;script:1">y</a><a href="https://example.com/">z</a><script>bad()</script>
    , .{});
    defer dom.deinit();
    // As the document does: clean first, then wrap.
    sanitize(&dom);
    const wrappers = try wrapQuotes(gpa, &dom);
    defer gpa.free(wrappers);
    try std.testing.expectEqual(3, wrappers.len);
    // Outlook's header took the rest of its parent.
    try std.testing.expectEqual(@as(usize, 3), blk: {
        var n: usize = 0;
        var it = dom.children(wrappers[2]);
        while (it.next()) |c| if (dom.node(c).kind == .element) {
            n += 1;
        };
        break :blk n;
    });
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try html.serialize.outer(&dom, &w.writer, dom.body());
    const out = w.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "<script") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "href=\"javascript") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "href=\"https://example.com/\"") != null);
    std.testing.expect(std.mem.indexOf(u8, out, "href=\"siv:quote/0\"") != null) catch |err| {
        std.debug.print("{s}\n", .{out});
        return err;
    };
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "class=\"siv-quote-toggle\""));
}
