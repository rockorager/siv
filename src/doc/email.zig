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
/// starts with a top border, with what follows them, and Outlook mobile's
/// `#mail-editor-reference-message-container`) and wraps each
/// outermost one that only blank text and other quotes follow in
/// `<div data-siv-quote=N>` after a toggle link to `siv:quote/N`.
/// Returns the wrappers, in order.
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
    // Only the quotes that end the message collapse: a quote with writing
    // after it, as bottom posting and replies between quotes leave, is
    // part of what is being read.
    var first = found.items.len;
    while (first > 0) : (first -= 1) {
        const q = found.items[first - 1];
        const end = if (first < found.items.len) try attribution(gpa, dom, found.items[first]) else .none;
        if (!blankBetween(dom, after(dom, q, tails.items[first - 1], body), end, body)) break;
    }
    var wrappers: std.ArrayList(NodeId) = .empty;
    errdefer wrappers.deinit(gpa);
    for (found.items[first..], tails.items[first..], 0..) |q, tail, k| {
        const parent = dom.node(q).parent;
        // The attribution line before it goes with it.
        const start = if (tail) q else try attribution(gpa, dom, q);
        var num: [16]u8 = undefined;
        const ks = std.fmt.bufPrint(&num, "{d}", .{k}) catch unreachable;
        const href = try std.fmt.allocPrint(gpa, "siv:quote/{d}", .{k});
        defer gpa.free(href);
        const toggle = try dom.createElement(.html, .a, &.{ .{ .name = .href, .value = href }, .{ .name = .class, .value = "siv-quote-toggle" }, .{ .name = .title, .value = "Show quoted text" } });
        dom.append(toggle, try dom.createText("\u{2022}\u{2022}\u{2022}"));
        const wrapper = try dom.createElement(.html, .div, &.{ .{ .name = try dom.atom("data-siv-quote"), .value = ks }, .{ .name = .class, .value = "siv-quote" } });
        dom.insertBefore(parent, toggle, start);
        dom.insertBefore(parent, wrapper, start);
        // Move the quote with its attribution (and for a reply header,
        // what follows it).
        var m = start;
        var past = false;
        while (m != .none) {
            const next = dom.node(m).next;
            past = past or m == q;
            dom.detach(m);
            dom.append(wrapper, m);
            if (past and !tail) break;
            m = next;
        }
        try wrappers.append(gpa, wrapper);
    }
    return wrappers.toOwnedSlice(gpa);
}

const Kind = enum { none, block, tail };

/// The first node after a quote: past its element, or for a reply header,
/// which takes the rest of its parent, past the parent.
fn after(dom: *const Dom, q: NodeId, tail: bool, body: NodeId) NodeId {
    return dom.followingSkip(if (tail) dom.node(q).parent else q, body);
}

/// Whether nothing is written from `from` up to `end` (none for the end
/// of the body): only blank text, line breaks, images, and style sheets.
fn blankBetween(dom: *const Dom, from: NodeId, end: NodeId, body: NodeId) bool {
    var cur = from;
    while (cur != .none and cur != end) {
        const n = dom.node(cur);
        if (n.kind == .text and std.mem.trim(u8, dom.text(cur), " \t\r\n\u{a0}").len > 0) return false;
        cur = if (dom.isHtml(cur, .style)) dom.followingSkip(cur, body) else dom.following(cur, body);
    }
    return true;
}

/// The attribution line ("On Tuesday, Priya wrote:") right before a quote,
/// past line breaks and blank text, when it is apart from it: Thunderbird's
/// `div.moz-cite-prefix`, else a short element or text ending in a colon
/// (Fastmail's, older Apple Mail's, and most clients' in any language).
/// The quote itself when there is none.
fn attribution(gpa: Allocator, dom: *const Dom, q: NodeId) error{OutOfMemory}!NodeId {
    var cur = dom.node(q).prev;
    while (cur != .none) : (cur = dom.node(cur).prev) {
        const n = dom.node(cur);
        if (n.kind == .text and std.mem.trim(u8, dom.text(cur), " \t\r\n\u{a0}").len == 0) continue;
        if (n.kind == .comment) continue;
        if (n.kind == .element and n.ns == .html and n.name == .br) continue;
        break;
    }
    if (cur == .none) return q;
    const n = dom.node(cur);
    if (n.kind == .element) if (dom.attr(cur, .class)) |cls| {
        var it = std.mem.tokenizeAny(u8, cls, " \t\n");
        while (it.next()) |c| if (std.mem.eql(u8, c, "moz-cite-prefix")) return cur;
    };
    if (n.kind != .text and !(n.kind == .element and n.ns == .html and (n.name == .div or n.name == .p or n.name == .span))) return q;
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(gpa);
    if (n.kind == .text) try t.appendSlice(gpa, dom.text(cur)) else try dom.textContent(gpa, cur, &t);
    const line = std.mem.trim(u8, t.items, " \t\r\n\u{a0}");
    return if (line.len > 0 and line.len <= 300 and line[line.len - 1] == ':') cur else q;
}

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
        // Outlook mobile: the quoted message, its From/Sent/To/Subject
        // header first, in one container.
        if (std.mem.eql(u8, v, "mail-editor-reference-message-container")) return .block;
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
        \\<a href="javascript:alert(1)">x</a><a href=" JaVa&#x09;script:1">y</a><a href="https://example.com/">z</a><script>bad()</script>
        \\<div class="gmail_quote"><div>On Mon, Ann wrote:</div><blockquote class="gmail_quote" type="cite">Lunch?</blockquote></div>
        \\<blockquote type=cite>Apple <blockquote type=cite>nested</blockquote></blockquote>
        \\<div><div id="divRplyFwdMsg">From: Bob</div><div>Old text</div><p>more</p></div>
        \\<div id="mail-editor-reference-message-container"><div class="ms-outlook-mobile-reference-message" style="border-top: 1pt solid rgb(181, 196, 223)"><b>From: </b>Cy<br><b>Subject: </b>Plans</div><div dir="ltr">Older text</div></div>
    , .{});
    defer dom.deinit();
    // As the document does: clean first, then wrap.
    sanitize(&dom);
    const wrappers = try wrapQuotes(gpa, &dom);
    defer gpa.free(wrappers);
    try std.testing.expectEqual(4, wrappers.len);
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
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "class=\"siv-quote-toggle\""));
    // Outlook mobile's container went whole, its header with it.
    var q: std.Io.Writer.Allocating = .init(gpa);
    defer q.deinit();
    try html.serialize.outer(&dom, &q.writer, wrappers[3]);
    try std.testing.expect(std.mem.indexOf(u8, q.written(), "id=\"mail-editor-reference-message-container\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.written(), "<b>From: </b>Cy") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.written(), "Older text") != null);
}


test "quotes from each client go behind the toggle with their attribution line" {
    const gpa = std.testing.allocator;
    // Invented messages in each client's markup: the reply, then the
    // attribution and the quote.
    const cases = [_][]const u8{
        // Apple Mail: the attribution inside the quote.
        \\<div>See you there.</div><div><br><blockquote type="cite"><div>On Oct 6, 2026, at 16:12, Priya Raman &lt;priya@example.com&gt; wrote:</div><br class="Apple-interchange-newline"><div><div>Old text</div></div></blockquote></div>
        ,
        // Apple Mail, older versions: before it.
        \\<div>See you there.</div><div><br><div>On Oct 6, 2026, at 16:12, Priya Raman &lt;priya@example.com&gt; wrote:</div><br class="Apple-interchange-newline"><blockquote type="cite"><div>Old text</div></blockquote></div>
        ,
        // Thunderbird: div.moz-cite-prefix before blockquote[type=cite].
        \\<p>See you there.</p><div class="moz-cite-prefix">On 10/6/26 16:12, Priya Raman wrote:<br></div><blockquote type="cite" cite="mid:abc@example.com"><p>Old text</p></blockquote>
        ,
        // Gmail: gmail_attr inside div.gmail_quote.
        \\<div dir="ltr">See you there.</div><br><div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On Tue, Oct 6, 2026 at 4:12 PM Priya Raman &lt;<a href="mailto:priya@example.com">priya@example.com</a>&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex"><div dir="ltr">Old text</div></blockquote></div>
        ,
        // Yahoo: the attribution inside div.yahoo_quoted.
        \\<div class="ydp1"><div>See you there.</div></div><div id="yahoo_quoted_123" class="yahoo_quoted"><div style="font-family:Helvetica"><div>On Tuesday, October 6, 2026 at 04:12:08 PM EDT, Priya Raman &lt;priya@example.com&gt; wrote:</div><div><br></div><div><div dir="ltr">Old text</div></div></div></div>
        ,
        // Proton: text inside div.protonmail_quote, before its blockquote.
        \\<div>See you there.</div><div class="protonmail_quote">On Tuesday, October 6th, 2026 at 4:12 PM, Priya Raman &lt;priya@example.com&gt; wrote:<br><blockquote class="protonmail_quote" type="cite"><div>Old text</div></blockquote><br></div>
        ,
        // Fastmail: a plain div before blockquote#qt.
        \\<div>See you there.</div><div><br></div><div>On Tue, Oct 6, 2026, at 16:12, Priya Raman wrote:</div><blockquote type="cite" id="qt" style="overflow-wrap:break-word;"><div>Old text</div></blockquote><div><br></div>
        ,
        // German, with the attribution as bare text before the quote.
        \\<div>Bis dann.</div>Am 06.10.2026 um 16:12 schrieb Priya Raman:<br><blockquote type="cite">Old text</blockquote>
        ,
    };
    for (cases) |src| {
        var dom = try html.parse(gpa, src, .{});
        defer dom.deinit();
        const wrappers = try wrapQuotes(gpa, &dom);
        defer gpa.free(wrappers);
        try std.testing.expectEqual(1, wrappers.len);
        var q: std.Io.Writer.Allocating = .init(gpa);
        defer q.deinit();
        try html.serialize.outer(&dom, &q.writer, wrappers[0]);
        // What stays out: the reply and the toggle, not the attribution.
        const quote = q.written();
        var all: std.Io.Writer.Allocating = .init(gpa);
        defer all.deinit();
        try html.serialize.outer(&dom, &all.writer, dom.body());
        const rest = try std.mem.replaceOwned(u8, gpa, all.written(), quote, "");
        defer gpa.free(rest);
        std.testing.expect(std.mem.indexOf(u8, quote, "Old text") != null and std.mem.indexOf(u8, quote, "Priya Raman") != null and std.mem.indexOf(u8, rest, "Priya") == null and std.mem.indexOf(u8, rest, "16:12") == null) catch |err| {
            std.debug.print("quote: {s}\nrest: {s}\n", .{ quote, rest });
            return err;
        };
        try std.testing.expect(std.mem.indexOf(u8, rest, "See you there.") != null or std.mem.indexOf(u8, rest, "Bis dann.") != null);
    }
    // A line ending in a colon that is not right before the quote stays.
    var dom = try html.parse(gpa, "<div>Notes:</div><p>One</p><blockquote type=cite>Old text</blockquote>", .{});
    defer dom.deinit();
    const one = try wrapQuotes(gpa, &dom);
    defer gpa.free(one);
    try std.testing.expectEqual(1, one.len);
    // Before its toggle: the paragraph, not the line.
    try std.testing.expectEqual(dom.childElement(dom.body(), .p), dom.node(dom.node(one[0]).prev).prev);
}

test "only the quotes that end a message collapse" {
    const gpa = std.testing.allocator;
    const Case = struct { src: []const u8, quotes: usize, open: []const u8 = "" };
    const cases = [_]Case{
        // Bottom posting: the reply after the quote.
        .{ .src = "<blockquote type=cite>Old</blockquote><p>Reply</p>", .quotes = 0 },
        // Replies between quotes, and a signature after the last.
        .{ .src = "<div>Arnt,</div><blockquote type=cite>One</blockquote><div>First</div><blockquote type=cite>Two</blockquote><div>Second</div><div>Mark</div>", .quotes = 0 },
        // Replies between quotes, ending in one: that one goes.
        .{ .src = "<blockquote type=cite>One</blockquote><p>First</p><blockquote type=cite>Two</blockquote><div><br></div>", .quotes = 1, .open = "One" },
        // Top posting over two quotes, each with its attribution before it.
        .{ .src = "<div>Reply</div><div>On Mon, Ann wrote:</div><blockquote type=cite>A</blockquote><div><br></div><div>On Sun, Bob wrote:</div><blockquote type=cite>B</blockquote>", .quotes = 2 },
        // Outlook's reply header takes the rest of its parent; what
        // follows the parent is a reply.
        .{ .src = "<div><div id=divRplyFwdMsg>From: Bob</div><div>Old</div></div><p>Reply</p>", .quotes = 0 },
        // A style sheet after it is not writing.
        .{ .src = "<p>Reply</p><div><div id=divRplyFwdMsg>From: Bob</div><div>Old</div></div><style>p { margin: 0 }</style>", .quotes = 1, .open = "Reply" },
    };
    for (cases) |c| {
        var dom = try html.parse(gpa, c.src, .{});
        defer dom.deinit();
        const wrappers = try wrapQuotes(gpa, &dom);
        defer gpa.free(wrappers);
        std.testing.expectEqual(c.quotes, wrappers.len) catch |err| {
            std.debug.print("{s}\n", .{c.src});
            return err;
        };
        if (c.open.len == 0) continue;
        // What stayed out of the wrappers.
        var all: std.Io.Writer.Allocating = .init(gpa);
        defer all.deinit();
        try html.serialize.outer(&dom, &all.writer, dom.body());
        var rest: []const u8 = all.written();
        const start = std.mem.indexOf(u8, rest, "<div data-siv-quote").?;
        rest = rest[0..start];
        try std.testing.expect(std.mem.indexOf(u8, rest, c.open) != null);
    }
}
