//! Markdown for documents (D32): CommonMark 0.31 with the GitHub
//! extensions (tables, task list items, strikethrough, extended
//! autolinks), parsed the way the reference implementations do (block
//! structure line by line with open containers, then inlines with the
//! delimiter and bracket stacks) into HTML, which the HTML parser turns
//! into the document tree. Raw HTML in Markdown therefore parses exactly
//! as HTML does.
//!
//! Imports: html.

const std = @import("std");
const html = @import("html");

const Allocator = std.mem.Allocator;
const Error = error{OutOfMemory};

pub const Options = struct {
    /// GitHub Flavored Markdown's extensions.
    gfm: bool = true,
};

/// Parses Markdown into a document tree.
pub fn parse(gpa: Allocator, bytes: []const u8, options: Options) Error!html.Dom {
    const out = try toHtml(gpa, bytes, options);
    defer gpa.free(out);
    return html.parse(gpa, out, .{ .charset = "utf-8" });
}

/// Renders Markdown to HTML (the CommonMark reference renderer's output).
pub fn toHtml(gpa: Allocator, bytes: []const u8, options: Options) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var p: Parser = .{ .a = arena.allocator(), .gfm = options.gfm };
    try p.init();
    // Normalize: NUL to U+FFFD, invalid UTF-8 replaced.
    const input = try sanitize(p.a, bytes);
    var it = LineIterator{ .s = input };
    while (it.next()) |line| try p.line(line);
    try p.finish();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var r: Renderer = .{ .p = &p, .out = &out, .gpa = gpa };
    try r.render(0);
    return out.toOwnedSlice(gpa);
}

fn sanitize(a: Allocator, s: []const u8) Error![]const u8 {
    var bad = std.mem.indexOfScalar(u8, s, 0) != null;
    if (!bad) bad = !std.unicode.utf8ValidateSlice(s);
    if (!bad) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0) {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
            continue;
        }
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + l <= s.len) if (std.unicode.utf8Decode(s[i..][0..l])) |_| {
            try out.appendSlice(a, s[i..][0..l]);
            i += l;
            continue;
        } else |_| {};
        try out.appendSlice(a, "\u{FFFD}");
        i += 1;
    }
    return out.items;
}

const LineIterator = struct {
    s: []const u8,
    i: usize = 0,

    fn next(it: *LineIterator) ?[]const u8 {
        if (it.i >= it.s.len) return null;
        const start = it.i;
        while (it.i < it.s.len and it.s[it.i] != '\n' and it.s[it.i] != '\r') it.i += 1;
        const l = it.s[start..it.i];
        if (it.i < it.s.len) {
            if (it.s[it.i] == '\r' and it.i + 1 < it.s.len and it.s[it.i + 1] == '\n') it.i += 1;
            it.i += 1;
        }
        return l;
    }
};

const Kind = enum(u8) {
    document,
    block_quote,
    list,
    item,
    paragraph,
    heading,
    thematic_break,
    code_block,
    html_block,
    table,
    table_row,
    table_cell,
    // Inlines.
    text,
    softbreak,
    hardbreak,
    code,
    emph,
    strong,
    del,
    link,
    image,
    html_inline,
};

const none: u32 = std.math.maxInt(u32);

const Align = enum(u8) { none, left, center, right };

const Node = struct {
    kind: Kind,
    parent: u32 = none,
    first: u32 = none,
    last: u32 = none,
    next: u32 = none,
    prev: u32 = none,
    open: bool = true,
    /// Raw content: paragraph and heading text, code and HTML lines.
    content: std.ArrayList(u8) = .empty,
    literal: []const u8 = "",
    // Lists and items.
    ordered: bool = false,
    bullet: u8 = 0,
    delimiter: u8 = 0,
    start: u32 = 1,
    tight: bool = true,
    marker_offset: usize = 0,
    padding: usize = 0,
    /// The item started empty (marker then end of line).
    empty_start: bool = false,
    last_line_blank: bool = false,
    start_line: usize = 0,
    task: enum(u8) { none, unchecked, checked } = .none,
    // Headings.
    level: u8 = 0,
    setext: bool = false,
    // Code blocks.
    fenced: bool = false,
    fence_char: u8 = 0,
    fence_len: usize = 0,
    fence_offset: usize = 0,
    info: []const u8 = "",
    // HTML blocks.
    html_type: u8 = 0,
    // Links and images.
    destination: []const u8 = "",
    title: []const u8 = "",
    // Tables.
    aligns: []const Align = &.{},
    header: bool = false,
    cell_align: Align = .none,
};

const Ref = struct { dest: []const u8, title: []const u8 };

const Parser = struct {
    a: Allocator,
    gfm: bool,
    nodes: std.ArrayList(Node) = .empty,
    refs: std.StringHashMapUnmanaged(Ref) = .empty,
    tip: u32 = 0,
    old_tip: u32 = 0,
    // The current line.
    ln: []const u8 = "",
    offset: usize = 0,
    column: usize = 0,
    next_nonspace: usize = 0,
    next_nonspace_column: usize = 0,
    indent: usize = 0,
    indented: bool = false,
    blank: bool = false,
    partially_consumed_tab: bool = false,
    all_closed: bool = true,
    line_no: usize = 0,
    last_matched: u32 = 0,
    last_line_length: usize = 0,

    fn init(p: *Parser) Error!void {
        try p.nodes.append(p.a, .{ .kind = .document });
    }

    fn n(p: *Parser, id: u32) *Node {
        return &p.nodes.items[id];
    }

    fn add(p: *Parser, kind: Kind, parent: u32) Error!u32 {
        // Close blocks that cannot hold the new one.
        var par = parent;
        while (!p.canContain(par, kind)) {
            const up = p.n(par).parent;
            p.finalize(par);
            par = up;
        }
        const id: u32 = @intCast(p.nodes.items.len);
        try p.nodes.append(p.a, .{ .kind = kind, .start_line = p.line_no });
        p.appendChild(par, id);
        p.tip = id;
        return id;
    }

    fn appendChild(p: *Parser, parent: u32, id: u32) void {
        const last = p.n(parent).last;
        p.n(id).parent = parent;
        p.n(id).prev = last;
        if (last == none) p.n(parent).first = id else p.n(last).next = id;
        p.n(parent).last = id;
    }

    fn unlink(p: *Parser, id: u32) void {
        const x = p.n(id).*;
        if (x.prev != none) p.n(x.prev).next = x.next else if (x.parent != none) p.n(x.parent).first = x.next;
        if (x.next != none) p.n(x.next).prev = x.prev else if (x.parent != none) p.n(x.parent).last = x.prev;
        p.n(id).parent = none;
        p.n(id).next = none;
        p.n(id).prev = none;
    }

    fn insertAfter(p: *Parser, after: u32, id: u32) void {
        const parent = p.n(after).parent;
        const nx = p.n(after).next;
        p.n(id).parent = parent;
        p.n(id).prev = after;
        p.n(id).next = nx;
        p.n(after).next = id;
        if (nx != none) p.n(nx).prev = id else p.n(parent).last = id;
    }

    fn insertBefore(p: *Parser, before: u32, id: u32) void {
        const parent = p.n(before).parent;
        const pv = p.n(before).prev;
        p.n(id).parent = parent;
        p.n(id).next = before;
        p.n(id).prev = pv;
        p.n(before).prev = id;
        if (pv != none) p.n(pv).next = id else p.n(parent).first = id;
    }

    fn canContain(p: *Parser, parent: u32, child: Kind) bool {
        return switch (p.n(parent).kind) {
            .document, .block_quote, .item => child != .item,
            .list => child == .item,
            .table => child == .table_row,
            .table_row => child == .table_cell,
            else => false,
        };
    }

    fn acceptsLines(k: Kind) bool {
        return k == .paragraph or k == .code_block or k == .html_block;
    }

    // Line scanning.

    fn findNextNonspace(p: *Parser) void {
        var i = p.offset;
        var cols = p.column;
        while (i < p.ln.len) {
            const c = p.ln[i];
            if (c == ' ') {
                i += 1;
                cols += 1;
            } else if (c == '\t') {
                i += 1;
                cols += 4 - (cols % 4);
            } else break;
        }
        p.blank = i >= p.ln.len;
        p.next_nonspace = i;
        p.next_nonspace_column = cols;
        p.indent = p.next_nonspace_column - p.column;
        p.indented = p.indent >= 4;
    }

    fn advanceNextNonspace(p: *Parser) void {
        p.offset = p.next_nonspace;
        p.column = p.next_nonspace_column;
        p.partially_consumed_tab = false;
    }

    fn advanceOffset(p: *Parser, count_: usize, columns: bool) void {
        var count = count_;
        while (count > 0 and p.offset < p.ln.len) {
            const c = p.ln[p.offset];
            if (c == '\t') {
                const chars_to_tab = 4 - (p.column % 4);
                if (columns) {
                    p.partially_consumed_tab = chars_to_tab > count;
                    const adv = @min(chars_to_tab, count);
                    p.column += adv;
                    if (!p.partially_consumed_tab) p.offset += 1;
                    count -= adv;
                } else {
                    p.partially_consumed_tab = false;
                    p.column += chars_to_tab;
                    p.offset += 1;
                    count -= 1;
                }
            } else {
                p.partially_consumed_tab = false;
                p.offset += 1;
                p.column += 1;
                count -= 1;
            }
        }
    }

    fn peek(p: *const Parser, i: usize) u8 {
        return if (i < p.ln.len) p.ln[i] else 0;
    }

    fn rest(p: *const Parser) []const u8 {
        return p.ln[@min(p.offset, p.ln.len)..];
    }

    fn addLine(p: *Parser) Error!void {
        const t = p.n(p.tip);
        if (p.partially_consumed_tab) {
            p.offset += 1;
            const chars_to_tab = 4 - (p.column % 4);
            for (0..chars_to_tab) |_| try t.content.append(p.a, ' ');
        }
        try t.content.appendSlice(p.a, p.rest());
        try t.content.append(p.a, '\n');
    }

    // Continuation of open blocks.

    const Cont = enum { matched, failed, done };

    fn continues(p: *Parser, id: u32) Cont {
        const x = p.n(id);
        switch (x.kind) {
            .document => return .matched,
            .block_quote => {
                if (!p.indented and p.peek(p.next_nonspace) == '>') {
                    p.advanceNextNonspace();
                    p.advanceOffset(1, false);
                    if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
                    return .matched;
                }
                return .failed;
            },
            .item => {
                if (p.blank) {
                    if (x.first == none) return .failed;
                    p.advanceNextNonspace();
                    return .matched;
                }
                if (p.indent >= x.marker_offset + x.padding) {
                    p.advanceOffset(x.marker_offset + x.padding, true);
                    return .matched;
                }
                return .failed;
            },
            .list => return .matched,
            .heading, .thematic_break => return .failed,
            .code_block => {
                if (x.fenced) {
                    const nn = p.next_nonspace;
                    if (p.indent <= 3 and p.peek(nn) == x.fence_char) {
                        var k = nn;
                        while (k < p.ln.len and p.ln[k] == x.fence_char) k += 1;
                        if (k - nn >= x.fence_len and isBlankFrom(p.ln, k)) {
                            p.last_line_length = p.ln.len;
                            p.finalize(id);
                            return .done;
                        }
                    }
                    var i = x.fence_offset;
                    while (i > 0 and isSpaceOrTab(p.peek(p.offset))) : (i -= 1) p.advanceOffset(1, true);
                    return .matched;
                }
                if (p.indent >= 4) {
                    p.advanceOffset(4, true);
                    return .matched;
                }
                if (p.blank) {
                    p.advanceNextNonspace();
                    return .matched;
                }
                return .failed;
            },
            .html_block => return if (p.blank and (x.html_type == 6 or x.html_type == 7)) .failed else .matched,
            .paragraph => return if (p.blank) .failed else .matched,
            .table => {
                if (p.blank) return .failed;
                return .matched;
            },
            else => return .failed,
        }
    }

    fn line(p: *Parser, raw: []const u8) Error!void {
        p.line_no += 1;
        p.ln = raw;
        p.offset = 0;
        p.column = 0;
        p.blank = false;
        p.partially_consumed_tab = false;
        p.old_tip = p.tip;
        p.all_closed = true;
        // Descend through open blocks that continue.
        var container: u32 = 0;
        while (true) {
            const last = p.n(container).last;
            if (last == none or !p.n(last).open) break;
            container = last;
            p.findNextNonspace();
            switch (p.continues(container)) {
                .matched => {},
                .failed => {
                    container = p.n(container).parent;
                    break;
                },
                .done => return,
            }
        }
        p.all_closed = container == p.old_tip;
        p.last_matched = container;
        var matched_leaf = p.n(container).kind != .paragraph and acceptsLines(p.n(container).kind);
        // Start new blocks.
        while (!matched_leaf) {
            p.findNextNonspace();
            if (!p.indented and !isSpecialStart(p.peek(p.next_nonspace))) {
                p.advanceNextNonspace();
                break;
            }
            switch (try p.start(container)) {
                .none => {
                    p.advanceNextNonspace();
                    break;
                },
                .container => container = p.tip,
                .leaf => {
                    container = p.tip;
                    matched_leaf = true;
                },
            }
        }
        // Lazy paragraph continuation.
        if (!p.all_closed and !p.blank and p.n(p.tip).kind == .paragraph) {
            try p.addLine();
            return;
        }
        // Close unmatched blocks.
        p.closeUnmatched();
        const t = p.n(container).kind;
        if (p.blank and p.n(container).last != none) p.n(p.n(container).last).last_line_blank = true;
        // Blank lines after a fenced code block, list item with nothing,
        // and so on do not make the container's last line blank.
        const last_blank = p.blank and !(t == .block_quote or (t == .code_block and p.n(container).fenced) or (t == .item and p.n(container).first == none and p.n(container).start_line == p.line_no));
        var cur = container;
        while (cur != none) : (cur = p.n(cur).parent) p.n(cur).last_line_blank = last_blank;
        if (acceptsLines(t)) {
            try p.addLine();
            if (t == .html_block and p.n(container).html_type >= 1 and p.n(container).html_type <= 5) {
                if (htmlBlockEnds(p.n(container).html_type, p.rest())) {
                    p.last_line_length = p.ln.len;
                    p.finalize(container);
                }
            }
        } else if (t == .table) {
            // Empty after a table start consumed the delimiter row.
            if (p.offset < p.ln.len) try p.tableRow(container, p.rest());
        } else if (p.offset < p.ln.len and !p.blank) {
            // A new paragraph.
            _ = try p.add(.paragraph, container);
            p.advanceNextNonspace();
            try p.addLine();
        }
        p.last_line_length = p.ln.len;
    }

    fn closeUnmatched(p: *Parser) void {
        if (!p.all_closed) {
            while (p.old_tip != p.last_matched) {
                const parent = p.n(p.old_tip).parent;
                p.finalize(p.old_tip);
                p.old_tip = parent;
            }
            p.all_closed = true;
        }
    }

    const Started = enum { none, container, leaf };

    fn start(p: *Parser, container: u32) Error!Started {
        const c = p.peek(p.next_nonspace);
        const ctype = p.n(container).kind;
        // Indented code.
        if (p.indented) {
            if (p.n(p.tip).kind != .paragraph and !p.blank) {
                p.advanceOffset(4, true);
                p.closeUnmatched();
                _ = try p.add(.code_block, container);
                return .leaf;
            }
            return .none;
        }
        // Block quote.
        if (c == '>') {
            p.advanceNextNonspace();
            p.advanceOffset(1, false);
            if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
            p.closeUnmatched();
            _ = try p.add(.block_quote, container);
            return .container;
        }
        // ATX heading.
        if (c == '#') {
            var k = p.next_nonspace;
            while (k < p.ln.len and p.ln[k] == '#') k += 1;
            const level = k - p.next_nonspace;
            if (level <= 6 and (k >= p.ln.len or isSpaceOrTab(p.ln[k]))) {
                p.advanceNextNonspace();
                p.advanceOffset(level, false);
                p.closeUnmatched();
                const h = try p.add(.heading, container);
                p.n(h).level = @intCast(level);
                // Content without the closing sequence.
                var s = std.mem.trim(u8, p.rest(), " \t");
                var e = s.len;
                while (e > 0 and s[e - 1] == '#') e -= 1;
                if (e == 0 or s[e - 1] == ' ' or s[e - 1] == '\t') s = std.mem.trimEnd(u8, s[0..e], " \t");
                try p.n(h).content.appendSlice(p.a, s);
                p.advanceOffset(p.ln.len - p.offset, false);
                return .leaf;
            }
        }
        // Fenced code.
        if (c == '`' or c == '~') {
            var k = p.next_nonspace;
            while (k < p.ln.len and p.ln[k] == c) k += 1;
            const len = k - p.next_nonspace;
            const info = p.ln[k..];
            if (len >= 3 and !(c == '`' and std.mem.indexOfScalar(u8, info, '`') != null)) {
                p.closeUnmatched();
                const cb = try p.add(.code_block, container);
                const x = p.n(cb);
                x.fenced = true;
                x.fence_char = c;
                x.fence_len = len;
                x.fence_offset = p.indent;
                x.info = try unescapeString(p.a, std.mem.trim(u8, info, " \t"));
                p.advanceNextNonspace();
                p.advanceOffset(len, false);
                p.advanceOffset(p.ln.len - p.offset, false);
                return .leaf;
            }
        }
        // HTML block.
        if (c == '<') {
            const s = p.ln[p.next_nonspace..];
            var t: u8 = 1;
            while (t <= 7) : (t += 1) {
                if (htmlBlockStarts(t, s) and (t < 7 or (ctype != .paragraph and !(!p.all_closed and !p.blank and p.n(p.tip).kind == .paragraph)))) {
                    p.closeUnmatched();
                    const hb = try p.add(.html_block, container);
                    p.n(hb).html_type = t;
                    return .leaf;
                }
            }
        }
        // Setext heading underline.
        if ((c == '=' or c == '-') and ctype == .paragraph) {
            const s = std.mem.trimEnd(u8, p.ln[p.next_nonspace..], " \t");
            var all = true;
            for (s) |ch| all = all and ch == c;
            if (all and s.len > 0) {
                // The paragraph minus leading reference definitions.
                try p.resolveRefs(container);
                if (p.n(container).content.items.len > 0) {
                    p.closeUnmatched();
                    const para = p.n(container);
                    const content = para.content.items;
                    para.kind = .heading;
                    para.level = if (c == '=') 1 else 2;
                    para.setext = true;
                    para.content.items.len = std.mem.trimEnd(u8, content, "\n").len;
                    p.advanceOffset(p.ln.len - p.offset, false);
                    return .leaf;
                }
            }
        }
        // GFM table: a paragraph's single line, then a delimiter row.
        if (p.gfm and ctype == .paragraph) {
            const para = p.n(container);
            const content = std.mem.trimEnd(u8, para.content.items, "\n");
            const header_line = if (std.mem.lastIndexOfScalar(u8, content, '\n')) |k| content[k + 1 ..] else content;
            if (try p.tableStart(container, header_line, p.ln[p.next_nonspace..])) {
                p.advanceOffset(p.ln.len - p.offset, false);
                return .leaf;
            }
        }
        // Thematic break.
        if (c == '*' or c == '-' or c == '_') {
            if (isThematicBreak(p.ln[p.next_nonspace..])) {
                p.closeUnmatched();
                _ = try p.add(.thematic_break, container);
                p.advanceOffset(p.ln.len - p.offset, false);
                return .leaf;
            }
        }
        // List item.
        if (try p.listItem(container)) return .container;
        return .none;
    }

    fn listItem(p: *Parser, container: u32) Error!bool {
        const s = p.ln[p.next_nonspace..];
        if (s.len == 0) return false;
        var ordered = false;
        var bullet: u8 = 0;
        var delim: u8 = 0;
        var startn: u32 = 1;
        var marker_len: usize = 0;
        const ctype = p.n(container).kind;
        if (s[0] == '-' or s[0] == '+' or s[0] == '*') {
            bullet = s[0];
            marker_len = 1;
        } else {
            var k: usize = 0;
            while (k < s.len and k < 9 and std.ascii.isDigit(s[k])) k += 1;
            if (k == 0 or k >= s.len or (s[k] != '.' and s[k] != ')')) return false;
            if (ctype == .paragraph and !(k == 1 and s[0] == '1')) return false;
            ordered = true;
            delim = s[k];
            startn = std.fmt.parseInt(u32, s[0..k], 10) catch return false;
            marker_len = k + 1;
        }
        // Followed by a space, a tab, or the end of the line.
        const after = if (marker_len < s.len) s[marker_len] else 0;
        if (marker_len < s.len and !isSpaceOrTab(after)) return false;
        // An empty item cannot interrupt a paragraph.
        if (ctype == .paragraph and isBlankFrom(s, marker_len)) return false;
        p.advanceNextNonspace();
        p.advanceOffset(marker_len, true);
        const spaces_start_col = p.column;
        const spaces_start_offset = p.offset;
        while (true) {
            p.advanceOffset(1, true);
            const nc = p.peek(p.offset);
            if (!(p.column - spaces_start_col < 5 and isSpaceOrTab(nc))) break;
        }
        const blank_item = p.offset >= p.ln.len;
        const spaces_after = p.column - spaces_start_col;
        var padding: usize = undefined;
        if (spaces_after >= 5 or spaces_after < 1 or blank_item) {
            padding = marker_len + 1;
            p.column = spaces_start_col;
            p.offset = spaces_start_offset;
            if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
        } else padding = marker_len + spaces_after;
        p.closeUnmatched();
        // A new list unless this item matches the open one.
        const tipk = p.n(p.tip).kind;
        var list: u32 = undefined;
        const continues_list = tipk == .list and p.n(p.tip).ordered == ordered and p.n(p.tip).bullet == bullet and p.n(p.tip).delimiter == delim;
        if (continues_list) {
            list = p.tip;
        } else {
            list = try p.add(.list, container);
            const l = p.n(list);
            l.ordered = ordered;
            l.bullet = bullet;
            l.delimiter = delim;
            l.start = startn;
        }
        const item = try p.add(.item, list);
        const it = p.n(item);
        it.marker_offset = p.indent;
        it.padding = padding;
        it.empty_start = blank_item;
        _ = &it;
        return true;
    }

    fn tableStart(p: *Parser, para: u32, header_line: []const u8, delim_line: []const u8) Error!bool {
        const aligns = (try delimiterRow(p.a, delim_line)) orelse return false;
        const cells = try splitRow(p.a, header_line);
        if (cells.len != aligns.len) return false;
        // Lines before the header stay a paragraph.
        const x = p.n(para);
        const content = std.mem.trimEnd(u8, x.content.items, "\n");
        const before = if (std.mem.lastIndexOfScalar(u8, content, '\n')) |k| content[0..k] else "";
        p.closeUnmatched();
        var table: u32 = undefined;
        if (before.len > 0) {
            x.content.items.len = before.len;
            try x.content.append(p.a, '\n');
            p.finalize(para);
            table = try p.add(.table, p.n(para).parent);
        } else {
            x.kind = .table;
            x.content.items.len = 0;
            table = para;
        }
        p.n(table).aligns = aligns;
        p.tip = table;
        const row = try p.add(.table_row, table);
        p.n(row).header = true;
        for (cells, 0..) |cell, i| {
            const c = try p.add(.table_cell, row);
            p.n(c).header = true;
            p.n(c).cell_align = aligns[i];
            try p.n(c).content.appendSlice(p.a, cell);
            p.n(c).open = false;
        }
        p.n(row).open = false;
        p.tip = table;
        return true;
    }

    fn tableRow(p: *Parser, table: u32, s: []const u8) Error!void {
        const aligns = p.n(table).aligns;
        const cells = try splitRow(p.a, s);
        const row = try p.add(.table_row, table);
        for (aligns, 0..) |al, i| {
            const c = try p.add(.table_cell, row);
            p.n(c).cell_align = al;
            if (i < cells.len) try p.n(c).content.appendSlice(p.a, cells[i]);
            p.n(c).open = false;
        }
        p.n(row).open = false;
        p.tip = table;
    }

    fn finalize(p: *Parser, id: u32) void {
        const x = p.n(id);
        if (!x.open) return;
        x.open = false;
        const parent = x.parent;
        defer if (p.tip == id) {
            p.tip = parent;
        };
        switch (x.kind) {
            .paragraph => {
                p.resolveRefs(id) catch {};
                if (p.n(id).content.items.len == 0) p.unlink(id);
            },
            .code_block => if (x.fenced) {
                // The first line is the info string.
                const c = x.content.items;
                const nl = std.mem.indexOfScalar(u8, c, '\n') orelse c.len;
                const rest_len = c.len - @min(c.len, nl + 1);
                std.mem.copyForwards(u8, c[0..rest_len], c[c.len - rest_len ..]);
                x.content.items.len = rest_len;
            } else {
                // Trailing blank lines are not part of indented code.
                var c = x.content.items;
                while (c.len > 0) {
                    const k = std.mem.lastIndexOfScalar(u8, c[0 .. c.len - 1], '\n');
                    const last_line = if (k) |kk| c[kk + 1 .. c.len - 1] else c[0 .. c.len - 1];
                    if (!isBlankFrom(last_line, 0)) break;
                    c = if (k) |kk| c[0 .. kk + 1] else c[0..0];
                }
                x.content.items.len = c.len;
            },
            .list => {
                // Loose if any item or child ends with a blank line
                // followed by more content.
                var tight = true;
                var item = x.first;
                while (item != none) : (item = p.n(item).next) {
                    if (endsWithBlank(p, item) and p.n(item).next != none) {
                        tight = false;
                        break;
                    }
                    var sub = p.n(item).first;
                    while (sub != none) : (sub = p.n(sub).next) {
                        if (endsWithBlank(p, sub) and (p.n(item).next != none or p.n(sub).next != none)) {
                            tight = false;
                            break;
                        }
                    }
                    if (!tight) break;
                }
                p.n(id).tight = tight;
            },
            else => {},
        }
    }

    fn finish(p: *Parser) Error!void {
        while (p.tip != none and p.tip != 0) p.finalize(p.tip);
        p.finalize(0);
        // Inlines, task items, then the tree is final.
        try p.inlines(0);
    }

    // Link reference definitions at the start of paragraphs.

    fn resolveRefs(p: *Parser, para: u32) Error!void {
        var s = p.n(para).content.items;
        var consumed: usize = 0;
        while (s.len > 0 and s[0] == '[') {
            const r = parseRefDef(p.a, s) catch break orelse break;
            const label = try normalizeLabel(p.a, r.label);
            if (label.len > 0 and !p.refs.contains(label)) try p.refs.put(p.a, label, .{
                // Copies: the content below shifts over the slices.
                .dest = try p.a.dupe(u8, r.dest),
                .title = try p.a.dupe(u8, r.title),
            });
            consumed += r.len;
            s = s[r.len..];
        }
        if (consumed > 0) {
            const x = p.n(para);
            const remain = x.content.items[consumed..];
            std.mem.copyForwards(u8, x.content.items, remain);
            x.content.items.len = remain.len;
        }
    }

    // Inlines.

    fn inlines(p: *Parser, id: u32) Error!void {
        var cur = p.n(id).first;
        while (cur != none) {
            const next = p.n(cur).next;
            switch (p.n(cur).kind) {
                .paragraph, .heading, .table_cell => {
                    const raw = std.mem.trim(u8, p.n(cur).content.items, " \t\n");
                    var ip: InlineParser = .{ .p = p, .s = raw, .block = cur };
                    if (p.gfm and p.n(cur).kind == .paragraph) ip.taskItem();
                    try ip.parse();
                },
                else => try p.inlines(cur),
            }
            cur = next;
        }
    }
};

fn endsWithBlank(p: *Parser, id: u32) bool {
    var cur = id;
    while (cur != none) {
        if (p.n(cur).last_line_blank) return true;
        const k = p.n(cur).kind;
        if (k == .list or k == .item) cur = p.n(cur).last else return false;
    }
    return false;
}

fn isSpaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isBlankFrom(s: []const u8, from: usize) bool {
    for (s[@min(from, s.len)..]) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn isSpecialStart(c: u8) bool {
    return switch (c) {
        '#', '`', '~', '*', '+', '_', '=', '<', '>', '-', '|', ':', '0'...'9' => true,
        else => false,
    };
}

fn isThematicBreak(s: []const u8) bool {
    const c = s[0];
    var count: usize = 0;
    for (s) |ch| {
        if (ch == c) {
            count += 1;
        } else if (ch != ' ' and ch != '\t') return false;
    }
    return count >= 3;
}

const block_tags = [_][]const u8{
    "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
};

fn htmlBlockStarts(t: u8, s: []const u8) bool {
    switch (t) {
        1 => {
            for ([_][]const u8{ "<pre", "<script", "<style", "<textarea" }) |tag| {
                if (std.ascii.startsWithIgnoreCase(s, tag)) {
                    const after = if (s.len > tag.len) s[tag.len] else '\n';
                    if (after == ' ' or after == '\t' or after == '>' or after == '\n') return true;
                }
            }
            return false;
        },
        2 => return std.mem.startsWith(u8, s, "<!--"),
        3 => return std.mem.startsWith(u8, s, "<?"),
        4 => return s.len > 2 and s[0] == '<' and s[1] == '!' and std.ascii.isAlphabetic(s[2]),
        5 => return std.mem.startsWith(u8, s, "<![CDATA["),
        6 => {
            var k: usize = 1;
            if (k < s.len and s[k] == '/') k += 1;
            const start = k;
            while (k < s.len and std.ascii.isAlphanumeric(s[k])) k += 1;
            const name = s[start..k];
            var found = false;
            for (block_tags) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) {
                found = true;
            };
            if (!found) return false;
            if (k >= s.len) return true;
            return s[k] == ' ' or s[k] == '\t' or s[k] == '>' or std.mem.startsWith(u8, s[k..], "/>");
        },
        7 => {
            // A complete open or closing tag alone on the line.
            const len = (htmlTag(s) orelse return false);
            const tag = s[0..len];
            if (std.mem.startsWith(u8, tag, "<!") or std.mem.startsWith(u8, tag, "<?")) return false;
            // Not a type 1 tag.
            for ([_][]const u8{ "<pre", "<script", "<style", "<textarea" }) |t1| if (std.ascii.startsWithIgnoreCase(tag, t1)) return false;
            return isBlankFrom(s, len);
        },
        else => return false,
    }
}

fn htmlBlockEnds(t: u8, s: []const u8) bool {
    return switch (t) {
        1 => std.ascii.findIgnoreCase(s, "</pre>") != null or std.ascii.findIgnoreCase(s, "</script>") != null or std.ascii.findIgnoreCase(s, "</style>") != null or std.ascii.findIgnoreCase(s, "</textarea>") != null,
        2 => std.mem.indexOf(u8, s, "-->") != null,
        3 => std.mem.indexOf(u8, s, "?>") != null,
        4 => std.mem.indexOfScalar(u8, s, '>') != null,
        5 => std.mem.indexOf(u8, s, "]]>") != null,
        else => false,
    };
}

/// The length of an HTML tag (open, closing, comment, processing
/// instruction, declaration, CDATA) at the start of `s` (CommonMark 6.6).
fn htmlTag(s: []const u8) ?usize {
    if (s.len < 3 or s[0] != '<') return null;
    if (std.mem.startsWith(u8, s, "<!--")) {
        if (std.mem.startsWith(u8, s, "<!-->")) return 5;
        if (std.mem.startsWith(u8, s, "<!--->")) return 6;
        const e = std.mem.indexOfPos(u8, s, 4, "-->") orelse return null;
        return e + 3;
    }
    if (std.mem.startsWith(u8, s, "<?")) {
        const e = std.mem.indexOfPos(u8, s, 2, "?>") orelse return null;
        return e + 2;
    }
    if (std.mem.startsWith(u8, s, "<![CDATA[")) {
        const e = std.mem.indexOfPos(u8, s, 9, "]]>") orelse return null;
        return e + 3;
    }
    if (s[1] == '!' and s.len > 2 and std.ascii.isAlphabetic(s[2])) {
        const e = std.mem.indexOfScalarPos(u8, s, 2, '>') orelse return null;
        return e + 1;
    }
    var i: usize = 1;
    const closing = s[i] == '/';
    if (closing) i += 1;
    if (i >= s.len or !std.ascii.isAlphabetic(s[i])) return null;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    if (closing) {
        while (i < s.len and isWs(s[i])) i += 1;
        if (i < s.len and s[i] == '>') return i + 1;
        return null;
    }
    // Attributes.
    while (true) {
        const ws_start = i;
        while (i < s.len and isWs(s[i])) i += 1;
        if (i >= s.len) return null;
        if (s[i] == '>') return i + 1;
        if (s[i] == '/' and i + 1 < s.len and s[i + 1] == '>') return i + 2;
        if (i == ws_start) return null;
        // Attribute name.
        if (!(std.ascii.isAlphabetic(s[i]) or s[i] == '_' or s[i] == ':')) return null;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '.' or s[i] == ':' or s[i] == '-')) i += 1;
        // Value.
        var j = i;
        while (j < s.len and isWs(s[j])) j += 1;
        if (j < s.len and s[j] == '=') {
            j += 1;
            while (j < s.len and isWs(s[j])) j += 1;
            if (j >= s.len) return null;
            if (s[j] == '"' or s[j] == '\'') {
                const q = s[j];
                const e = std.mem.indexOfScalarPos(u8, s, j + 1, q) orelse return null;
                i = e + 1;
            } else {
                const st = j;
                while (j < s.len and !isWs(s[j]) and std.mem.indexOfScalar(u8, "\"'=<>`", s[j]) == null) j += 1;
                if (j == st) return null;
                i = j;
            }
        }
    }
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn delimiterRow(a: Allocator, line: []const u8) Error!?[]const Align {
    const cells = try splitRow(a, line);
    if (cells.len == 0) return null;
    var out: std.ArrayList(Align) = .empty;
    for (cells) |c_| {
        const c = std.mem.trim(u8, c_, " \t");
        if (c.len == 0) return null;
        const left = c[0] == ':';
        const right = c[c.len - 1] == ':';
        const inner = c[@intFromBool(left) .. c.len - @intFromBool(right and c.len > 1)];
        if (inner.len == 0) return null;
        for (inner) |ch| if (ch != '-') return null;
        try out.append(a, if (left and right) .center else if (left) .left else if (right) .right else .none);
    }
    // A delimiter row needs a pipe unless it has several cells.
    if (std.mem.indexOfScalar(u8, line, '|') == null and out.items.len < 2) {
        if (out.items.len == 1) return null;
    }
    return out.items;
}

/// A table row's cells: split at unescaped pipes outside code spans,
/// leading and trailing pipes dropped, cells trimmed.
fn splitRow(a: Allocator, line_: []const u8) Error![]const []const u8 {
    var line = std.mem.trim(u8, line_, " \t");
    if (line.len > 0 and line[0] == '|') line = line[1..];
    if (line.len > 0 and line[line.len - 1] == '|' and !(line.len > 1 and line[line.len - 2] == '\\')) line = line[0 .. line.len - 1];
    var out: std.ArrayList([]const u8) = .empty;
    var cell: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\' and i + 1 < line.len and line[i + 1] == '|') {
            // An escaped pipe stays a pipe (inside code spans too).
            try cell.append(a, '|');
            i += 1;
            continue;
        }
        if (c == '|') {
            try out.append(a, std.mem.trim(u8, cell.items, " \t"));
            cell = .empty;
            continue;
        }
        try cell.append(a, c);
    }
    try out.append(a, std.mem.trim(u8, cell.items, " \t"));
    return out.items;
}

// Link reference definitions.

const RefDef = struct { label: []const u8, dest: []const u8, title: []const u8, len: usize };

fn parseRefDef(a: Allocator, s: []const u8) Error!?RefDef {
    const label_len = linkLabel(s) orelse return null;
    if (label_len >= s.len or s[label_len] != ':') return null;
    const label = s[1 .. label_len - 1];
    var i = label_len + 1;
    i = skipSpacesNewline(s, i) orelse return null;
    const dest = linkDestination(s, i) orelse return null;
    if (dest.raw.len == 0 and !dest.angle) return null;
    i = dest.end;
    const before_title = i;
    var title: []const u8 = "";
    var title_ok = false;
    if (skipSpacesNewline(s, i)) |j| if (j > i) if (linkTitle(s, j)) |t| {
        // The title ends its line.
        var k = t.end;
        while (k < s.len and isSpaceOrTab(s[k])) k += 1;
        if (k >= s.len or s[k] == '\n') {
            title = t.raw;
            i = if (k < s.len) k + 1 else k;
            title_ok = true;
        }
    };
    if (!title_ok) {
        i = before_title;
        var k = i;
        while (k < s.len and isSpaceOrTab(s[k])) k += 1;
        if (k < s.len and s[k] != '\n') return null;
        i = if (k < s.len) k + 1 else k;
    }
    return .{ .label = label, .dest = try unescapeString(a, dest.raw), .title = try unescapeString(a, title), .len = i };
}

fn skipSpacesNewline(s: []const u8, from: usize) ?usize {
    var i = from;
    var newlines: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n')) : (i += 1) {
        if (s[i] == '\n') newlines += 1;
    }
    if (newlines > 1) return null;
    return i;
}

/// A link label `[...]` at the start: its length with the brackets.
fn linkLabel(s: []const u8) ?usize {
    if (s.len == 0 or s[0] != '[') return null;
    var i: usize = 1;
    var nonblank = false;
    while (i < s.len and i < 1001) : (i += 1) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
            i += 1;
            nonblank = true;
            continue;
        }
        if (c == '[') return null;
        if (c == ']') return if (nonblank) i + 1 else null;
        if (!isWs(c)) nonblank = true;
    }
    return null;
}

const Dest = struct { raw: []const u8, end: usize, angle: bool };

fn linkDestination(s: []const u8, from: usize) ?Dest {
    var i = from;
    if (i < s.len and s[i] == '<') {
        i += 1;
        const start = i;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
                i += 1;
                continue;
            }
            if (c == '>') return .{ .raw = s[start..i], .end = i + 1, .angle = true };
            if (c == '<' or c == '\n') return null;
        }
        return null;
    }
    const start = i;
    var depth: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
            i += 1;
            continue;
        }
        if (c == '(') {
            depth += 1;
            if (depth > 32) return null;
        } else if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
        } else if (c <= ' ' or c == 0x7F) break;
    }
    if (depth != 0) return null;
    return .{ .raw = s[start..i], .end = i, .angle = false };
}

const Title = struct { raw: []const u8, end: usize };

fn linkTitle(s: []const u8, from: usize) ?Title {
    if (from >= s.len) return null;
    const open = s[from];
    const close: u8 = switch (open) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var i = from + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
            i += 1;
            continue;
        }
        if (c == close) return .{ .raw = s[from + 1 .. i], .end = i + 1 };
        if (open == '(' and c == '(') return null;
        if (c == '\n' and i + 1 < s.len and s[i + 1] == '\n') return null;
    }
    return null;
}

fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

/// Label normalization: case fold and collapse white space.
fn normalizeLabel(a: Allocator, label: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    var it = std.mem.tokenizeAny(u8, label, " \t\n\r");
    while (it.next()) |w| {
        if (space) try out.append(a, ' ');
        space = true;
        var i: usize = 0;
        while (i < w.len) {
            const l = std.unicode.utf8ByteSequenceLength(w[i]) catch 1;
            const cp = std.unicode.utf8Decode(w[i..@min(w.len, i + l)]) catch 0xFFFD;
            i += l;
            // ASCII, Latin-1, Greek, and Cyrillic case folding; ß folds
            // to ss.
            if (cp == 0xDF or cp == 0x1E9E) {
                try out.appendSlice(a, "ss");
                continue;
            }
            const f: u21 = if (cp >= 'A' and cp <= 'Z') cp + 32 else if ((cp >= 0xC0 and cp <= 0xDE and cp != 0xD7)) cp + 32 else if (cp >= 0x391 and cp <= 0x3A9) cp + 32 else if (cp >= 0x410 and cp <= 0x42F) cp + 32 else if (cp >= 0x400 and cp <= 0x40F) cp + 80 else cp;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(f, &buf) catch 0;
            try out.appendSlice(a, buf[0..len]);
        }
    }
    return out.items;
}

/// Backslash escapes and entities resolved.
fn unescapeString(a: Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\\&") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
            try out.append(a, s[i + 1]);
            i += 2;
            continue;
        }
        if (c == '&') if (entity(s[i..])) |e| {
            try appendCp(a, &out, e.cp[0]);
            if (e.cp[1] != 0) try appendCp(a, &out, e.cp[1]);
            i += e.len;
            continue;
        };
        try out.append(a, c);
        i += 1;
    }
    return out.items;
}

fn appendCp(a: Allocator, out: *std.ArrayList(u8), cp: u21) Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.appendSlice(a, "\u{FFFD}");
        return;
    };
    try out.appendSlice(a, buf[0..n]);
}

/// An entity or numeric character reference at the start of `s`.
fn entity(s: []const u8) ?struct { cp: [2]u21, len: usize } {
    if (s.len < 3 or s[0] != '&') return null;
    if (s[1] == '#') {
        var i: usize = 2;
        var hex = false;
        if (i < s.len and (s[i] == 'x' or s[i] == 'X')) {
            hex = true;
            i += 1;
        }
        const start = i;
        while (i < s.len and (if (hex) std.ascii.isHex(s[i]) else std.ascii.isDigit(s[i]))) i += 1;
        const digits = i - start;
        if (digits == 0 or digits > (if (hex) @as(usize, 6) else 7) or i >= s.len or s[i] != ';') return null;
        const v = std.fmt.parseInt(u32, s[start..i], if (hex) 16 else 10) catch return null;
        const cp: u21 = if (v == 0 or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) 0xFFFD else @intCast(v);
        return .{ .cp = .{ cp, 0 }, .len = i + 1 };
    }
    var i: usize = 1;
    while (i < s.len and i < 40 and std.ascii.isAlphanumeric(s[i])) i += 1;
    if (i >= s.len or s[i] != ';' or i == 1) return null;
    const cp = html.tokenizer.lookupEntity(s[1 .. i + 1]) orelse return null;
    return .{ .cp = cp, .len = i + 1 };
}

// Inline parsing.

const Delim = struct {
    node: u32,
    char: u8,
    count: usize,
    orig: usize,
    can_open: bool,
    can_close: bool,
    active: bool = true,
};

const Bracket = struct {
    node: u32,
    image: bool,
    active: bool = true,
    /// Delimiters below this index were before the bracket.
    delim_base: usize,
    pos: usize,
    bracket_after: bool = false,
};

const InlineParser = struct {
    p: *Parser,
    s: []const u8,
    i: usize = 0,
    block: u32,
    delims: std.ArrayList(Delim) = .empty,
    brackets: std.ArrayList(Bracket) = .empty,

    fn text(ip: *InlineParser, t: []const u8) Error!void {
        if (t.len == 0) return;
        const p = ip.p;
        const last = p.n(ip.block).last;
        if (last != none and p.n(last).kind == .text and !ip.isDelimNode(last)) {
            const lit = p.n(last).literal;
            // Join adjacent text.
            p.n(last).literal = try std.mem.concat(p.a, u8, &.{ lit, t });
            return;
        }
        const id = try ip.node(.text);
        p.n(id).literal = t;
    }

    fn isDelimNode(ip: *const InlineParser, id: u32) bool {
        for (ip.delims.items) |d| if (d.node == id) return true;
        for (ip.brackets.items) |b| if (b.node == id) return true;
        return false;
    }

    fn node(ip: *InlineParser, kind: Kind) Error!u32 {
        const p = ip.p;
        const id: u32 = @intCast(p.nodes.items.len);
        try p.nodes.append(p.a, .{ .kind = kind, .open = false });
        p.appendChild(ip.block, id);
        return id;
    }

    /// `[ ]` or `[x]` at the start of a list item's first paragraph.
    fn taskItem(ip: *InlineParser) void {
        const p = ip.p;
        const par = p.n(ip.block);
        const item = par.parent;
        if (item == none or p.n(item).kind != .item or p.n(item).first != ip.block) return;
        const s = ip.s;
        if (s.len >= 3 and s[0] == '[' and s[2] == ']' and (s[1] == ' ' or s[1] == 'x' or s[1] == 'X') and (s.len == 3 or isWs(s[3]))) {
            p.n(item).task = if (s[1] == ' ') .unchecked else .checked;
            ip.s = std.mem.trimStart(u8, s[3..], " \t");
        }
    }

    fn parse(ip: *InlineParser) Error!void {
        const s = ip.s;
        var text_start: usize = 0;
        while (ip.i < s.len) {
            const c = s[ip.i];
            switch (c) {
                '@' => {
                    if (ip.p.gfm) {
                        var ls = ip.i;
                        while (ls > text_start and (std.ascii.isAlphanumeric(s[ls - 1]) or std.mem.indexOfScalar(u8, ".-_+", s[ls - 1]) != null)) ls -= 1;
                        if (ls < ip.i) {
                            const at = ip.i;
                            ip.i = ls;
                            const before_len = ip.p.nodes.items.len;
                            try ip.text(s[text_start..ls]);
                            const mark = ip.i;
                            try ip.emailAutolink();
                            if (ip.i != mark) {
                                text_start = ip.i;
                                continue;
                            }
                            // Not an address: undo the split text.
                            _ = before_len;
                            ip.i = at;
                            text_start = ls;
                        }
                    }
                    ip.i += 1;
                },
                '\n', '\\', '`', '*', '_', '[', ']', '!', '<', '&', '~', 'w', 'h', 'f', 'm', 'x' => {
                    if (c == 'w' or c == 'h' or c == 'f' or c == 'm' or c == 'x') {
                        if (!ip.p.gfm) {
                            ip.i += 1;
                            continue;
                        }
                        // Extended autolinks start at word boundaries.
                        if (c != '@' and ip.i > 0 and !isAutolinkBoundary(s[ip.i - 1])) {
                            ip.i += 1;
                            continue;
                        }
                    }
                    if (c == '~' and !ip.p.gfm) {
                        ip.i += 1;
                        continue;
                    }
                    try ip.text(s[text_start..ip.i]);
                    const before = ip.i;
                    try ip.special(c);
                    if (ip.i == before) {
                        // Nothing special after all: plain text.
                        ip.i += 1;
                        text_start = before;
                        continue;
                    }
                    text_start = ip.i;
                },
                else => ip.i += 1,
            }
        }
        try ip.text(s[text_start..]);
        try ip.processEmphasis(0);
    }

    /// Handles the construct at `ip.i`; leaves `ip.i` unchanged if there
    /// is none there.
    fn special(ip: *InlineParser, c: u8) Error!void {
        const s = ip.s;
        switch (c) {
            '\n' => {
                // Hard break: two spaces or a backslash before.
                const last = ip.p.n(ip.block).last;
                var hard = false;
                if (last != none and ip.p.n(last).kind == .text) {
                    const lit = ip.p.n(last).literal;
                    var trimmed = lit.len;
                    while (trimmed > 0 and lit[trimmed - 1] == ' ') trimmed -= 1;
                    hard = lit.len - trimmed >= 2;
                    ip.p.n(last).literal = lit[0..trimmed];
                }
                _ = try ip.node(if (hard) .hardbreak else .softbreak);
                ip.i += 1;
                while (ip.i < s.len and (s[ip.i] == ' ' or s[ip.i] == '\t')) ip.i += 1;
            },
            '\\' => {
                if (ip.i + 1 < s.len and s[ip.i + 1] == '\n') {
                    _ = try ip.node(.hardbreak);
                    ip.i += 2;
                    while (ip.i < s.len and (s[ip.i] == ' ' or s[ip.i] == '\t')) ip.i += 1;
                } else if (ip.i + 1 < s.len and isAsciiPunct(s[ip.i + 1])) {
                    const id = try ip.node(.text);
                    ip.p.n(id).literal = s[ip.i + 1 .. ip.i + 2];
                    ip.i += 2;
                } else {
                    try ip.text("\\");
                    ip.i += 1;
                }
            },
            '`' => {
                var k = ip.i;
                while (k < s.len and s[k] == '`') k += 1;
                const n = k - ip.i;
                // The closing run of the same length.
                var j = k;
                while (j < s.len) {
                    if (s[j] != '`') {
                        j += 1;
                        continue;
                    }
                    var e = j;
                    while (e < s.len and s[e] == '`') e += 1;
                    if (e - j == n) {
                        var content = try ip.p.a.dupe(u8, s[k..j]);
                        for (content) |*ch| if (ch.* == '\n') {
                            ch.* = ' ';
                        };
                        if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ' and std.mem.indexOfNone(u8, content, " ") != null) content = content[1 .. content.len - 1];
                        const id = try ip.node(.code);
                        ip.p.n(id).literal = content;
                        ip.i = e;
                        return;
                    }
                    j = e;
                }
                // No match: the backticks are text.
                try ip.text(s[ip.i..k]);
                ip.i = k;
            },
            '*', '_', '~' => try ip.delimiterRun(c),
            '[' => {
                const id = try ip.node(.text);
                ip.p.n(id).literal = "[";
                try ip.brackets.append(ip.p.a, .{ .node = id, .image = false, .delim_base = ip.delims.items.len, .pos = ip.i + 1 });
                ip.i += 1;
            },
            '!' => {
                if (ip.i + 1 < s.len and s[ip.i + 1] == '[') {
                    const id = try ip.node(.text);
                    ip.p.n(id).literal = "![";
                    try ip.brackets.append(ip.p.a, .{ .node = id, .image = true, .delim_base = ip.delims.items.len, .pos = ip.i + 2 });
                    ip.i += 2;
                } else {
                    try ip.text("!");
                    ip.i += 1;
                }
            },
            ']' => try ip.closeBracket(),
            '<' => {
                if (autolink(s[ip.i..])) |al| {
                    const id = try ip.node(.link);
                    const dest = s[ip.i + 1 .. ip.i + al.len - 1];
                    ip.p.n(id).destination = if (al.email) try std.mem.concat(ip.p.a, u8, &.{ "mailto:", dest }) else dest;
                    const t: u32 = @intCast(ip.p.nodes.items.len);
                    try ip.p.nodes.append(ip.p.a, .{ .kind = .text, .open = false, .literal = dest });
                    ip.p.appendChild(id, t);
                    ip.i += al.len;
                } else if (htmlTag(s[ip.i..])) |len| {
                    const id = try ip.node(.html_inline);
                    ip.p.n(id).literal = s[ip.i .. ip.i + len];
                    ip.i += len;
                } else {
                    try ip.text("<");
                    ip.i += 1;
                }
            },
            '&' => {
                if (entity(s[ip.i..])) |e| {
                    var buf: std.ArrayList(u8) = .empty;
                    try appendCp(ip.p.a, &buf, e.cp[0]);
                    if (e.cp[1] != 0) try appendCp(ip.p.a, &buf, e.cp[1]);
                    const id = try ip.node(.text);
                    ip.p.n(id).literal = buf.items;
                    ip.i += e.len;
                } else {
                    try ip.text("&");
                    ip.i += 1;
                }
            },
            'w', 'h', 'f', 'm', 'x' => try ip.extendedAutolink(),
            else => {},
        }
    }

    fn delimiterRun(ip: *InlineParser, c: u8) Error!void {
        const s = ip.s;
        var k = ip.i;
        while (k < s.len and s[k] == c) k += 1;
        const count = k - ip.i;
        if (c == '~' and count > 2) {
            try ip.text(s[ip.i..k]);
            ip.i = k;
            return;
        }
        const before: u21 = if (ip.i == 0) '\n' else prevCp(s, ip.i);
        const after: u21 = if (k >= s.len) '\n' else nextCp(s, k);
        const after_ws = isUnicodeWs(after);
        const after_punct = isUnicodePunct(after);
        const before_ws = isUnicodeWs(before);
        const before_punct = isUnicodePunct(before);
        const left = !after_ws and (!after_punct or before_ws or before_punct);
        const right = !before_ws and (!before_punct or after_ws or after_punct);
        var can_open = left;
        var can_close = right;
        if (c == '_') {
            can_open = left and (!right or before_punct);
            can_close = right and (!left or after_punct);
        }
        const id = try ip.node(.text);
        ip.p.n(id).literal = s[ip.i..k];
        try ip.delims.append(ip.p.a, .{ .node = id, .char = c, .count = count, .orig = count, .can_open = can_open, .can_close = can_close });
        ip.i = k;
    }

    fn closeBracket(ip: *InlineParser) Error!void {
        const s = ip.s;
        ip.i += 1;
        if (ip.brackets.items.len == 0) {
            try ip.text("]");
            return;
        }
        const opener = ip.brackets.items[ip.brackets.items.len - 1];
        if (!opener.active) {
            _ = ip.brackets.pop();
            try ip.text("]");
            return;
        }
        var dest: []const u8 = "";
        var title: []const u8 = "";
        var matched = false;
        const after = ip.i;
        // Inline link: (dest "title").
        if (ip.i < s.len and s[ip.i] == '(') {
            var j = ip.i + 1;
            j = skipSpacesNewline(s, j) orelse j;
            if (linkDestination(s, j)) |d| {
                var k = d.end;
                var t_ok = true;
                if (k < s.len and isWs(s[k])) {
                    k = skipSpacesNewline(s, k) orelse k;
                    if (linkTitle(s, k)) |t| {
                        title = t.raw;
                        k = skipSpacesNewline(s, t.end) orelse t.end;
                    } else if (k < s.len and s[k] != ')') t_ok = false;
                }
                if (t_ok and k < s.len and s[k] == ')') {
                    dest = d.raw;
                    ip.i = k + 1;
                    matched = true;
                }
            }
        }
        if (!matched) {
            // Reference link: [text][label], [text][], or [text].
            var label: []const u8 = "";
            var label_end = after;
            if (linkLabel(s[after..])) |len| {
                label = s[after + 1 .. after + len - 1];
                label_end = after + len;
            } else if (after + 1 < s.len and s[after] == '[' and s[after + 1] == ']') {
                label_end = after + 2;
            }
            if (label.len == 0) label = s[opener.pos .. after - 1];
            const norm = try normalizeLabel(ip.p.a, label);
            if (ip.p.refs.get(norm)) |r| {
                dest = r.dest;
                title = r.title;
                matched = true;
                ip.i = label_end;
            }
        }
        if (!matched) {
            _ = ip.brackets.pop();
            ip.i = after;
            try ip.text("]");
            return;
        }
        // Make the link: everything after the opener becomes its content.
        const p = ip.p;
        const link: u32 = @intCast(p.nodes.items.len);
        try p.nodes.append(p.a, .{ .kind = if (opener.image) .image else .link, .open = false, .destination = try unescapeString(p.a, dest), .title = try unescapeString(p.a, title) });
        var cur = p.n(opener.node).next;
        while (cur != none) {
            const nx = p.n(cur).next;
            p.unlink(cur);
            p.appendChild(link, cur);
            cur = nx;
        }
        p.insertAfter(opener.node, link);
        // Emphasis inside the link.
        try ip.processEmphasisIn(opener.delim_base);
        p.unlink(opener.node);
        _ = ip.brackets.pop();
        // No links in links: deactivate earlier link openers.
        if (!opener.image) for (ip.brackets.items) |*b| {
            if (!b.image) b.active = false;
        };
    }

    fn processEmphasisIn(ip: *InlineParser, base: usize) Error!void {
        try ip.processEmphasis(base);
    }

    /// CommonMark's "process emphasis" over delimiters from `base` on.
    fn processEmphasis(ip: *InlineParser, base: usize) Error!void {
        const p = ip.p;
        var openers_bottom: [3][3][2]usize = undefined;
        for (&openers_bottom) |*x| for (x) |*y| {
            y.* = .{ base, base };
        };
        var closer = base;
        while (closer < ip.delims.items.len) {
            const cd = ip.delims.items[closer];
            if (!cd.can_close or cd.count == 0) {
                closer += 1;
                continue;
            }
            const ci: usize = switch (cd.char) {
                '*' => 0,
                '_' => 1,
                else => 2,
            };
            const bottom = openers_bottom[ci][cd.orig % 3][@intFromBool(cd.can_open)];
            var opener_found: ?usize = null;
            var k = closer;
            while (k > bottom) {
                k -= 1;
                const od = ip.delims.items[k];
                if (od.char != cd.char or !od.can_open or od.count == 0) continue;
                if (cd.char == '~') {
                    if (od.count != cd.count) continue;
                } else if ((od.can_close or cd.can_open) and (od.orig + cd.orig) % 3 == 0 and !(od.orig % 3 == 0 and cd.orig % 3 == 0)) continue;
                opener_found = k;
                break;
            }
            if (opener_found) |oi| {
                const od = &ip.delims.items[oi];
                const cdp = &ip.delims.items[closer];
                const use: usize = if (cd.char == '~') od.count else if (od.count >= 2 and cdp.count >= 2) 2 else 1;
                od.count -= use;
                cdp.count -= use;
                p.n(od.node).literal = p.n(od.node).literal[0..od.count];
                p.n(cdp.node).literal = p.n(cdp.node).literal[0..cdp.count];
                const kind: Kind = if (cd.char == '~') .del else if (use == 2) .strong else .emph;
                const em: u32 = @intCast(p.nodes.items.len);
                try p.nodes.append(p.a, .{ .kind = kind, .open = false });
                var cur = p.n(od.node).next;
                while (cur != none and cur != cdp.node) {
                    const nx = p.n(cur).next;
                    p.unlink(cur);
                    p.appendChild(em, cur);
                    cur = nx;
                }
                p.insertAfter(od.node, em);
                // Delimiters between them are gone.
                var j = oi + 1;
                while (j < closer) : (j += 1) ip.delims.items[j].count = 0;
                if (od.count == 0) p.unlink(od.node);
                if (cdp.count == 0) {
                    p.unlink(cdp.node);
                    closer += 1;
                }
            } else {
                openers_bottom[ci][cd.orig % 3][@intFromBool(cd.can_open)] = closer;
                if (!cd.can_open) ip.delims.items[closer].count = ip.delims.items[closer].count; // stays text
                closer += 1;
            }
        }
        ip.delims.shrinkRetainingCapacity(base);
    }

    fn extendedAutolink(ip: *InlineParser) Error!void {
        const s = ip.s;
        const rest = s[ip.i..];
        var scheme: []const u8 = "";
        var start_len: usize = 0;
        if (std.ascii.startsWithIgnoreCase(rest, "www.")) {
            scheme = "http://";
        } else if (std.ascii.startsWithIgnoreCase(rest, "http://")) {
            start_len = 7;
        } else if (std.ascii.startsWithIgnoreCase(rest, "https://")) {
            start_len = 8;
        } else if (std.ascii.startsWithIgnoreCase(rest, "ftp://")) {
            start_len = 6;
        } else {
            if (std.ascii.startsWithIgnoreCase(rest, "mailto:") or std.ascii.startsWithIgnoreCase(rest, "xmpp:")) return ip.emailAutolink();
            return;
        }
        // Domain: segments of alphanumerics, _ and -, separated by dots.
        var k = start_len;
        var segs: usize = 0;
        var last_seg_underscore = false;
        var prev_seg_underscore = false;
        while (k < rest.len) {
            const seg_start = k;
            var underscore = false;
            while (k < rest.len and (std.ascii.isAlphanumeric(rest[k]) or rest[k] == '_' or rest[k] == '-' or rest[k] >= 0x80)) : (k += 1) {
                if (rest[k] == '_') underscore = true;
            }
            if (k == seg_start) break;
            segs += 1;
            prev_seg_underscore = last_seg_underscore;
            last_seg_underscore = underscore;
            if (k < rest.len and rest[k] == '.' and k + 1 < rest.len and (std.ascii.isAlphanumeric(rest[k + 1]) or rest[k + 1] == '_' or rest[k + 1] == '-')) {
                k += 1;
                continue;
            }
            break;
        }
        if (segs < 2 and scheme.len > 0) return;
        if (segs < 1) return;
        if (last_seg_underscore or prev_seg_underscore) return;
        // Path: up to white space or '<'.
        while (k < rest.len and !isWs(rest[k]) and rest[k] != '<') k += 1;
        var end = k;
        // Trailing punctuation is not part of it.
        while (end > 0) {
            const ch = rest[end - 1];
            if (std.mem.indexOfScalar(u8, "?!.,:*_~'\"", ch) != null) {
                end -= 1;
                continue;
            }
            if (ch == ')') {
                var open: usize = 0;
                var close: usize = 0;
                for (rest[0..end]) |x| {
                    if (x == '(') open += 1;
                    if (x == ')') close += 1;
                }
                if (close > open) {
                    end -= 1;
                    continue;
                }
            }
            if (ch == ';') {
                // An entity-like suffix &name; is dropped.
                var j = end - 1;
                while (j > 0 and std.ascii.isAlphanumeric(rest[j - 1])) j -= 1;
                if (j > 0 and rest[j - 1] == '&') {
                    end = j - 1;
                    continue;
                }
            }
            break;
        }
        if (end <= start_len) return;
        const url = rest[0..end];
        const link = try ip.node(.link);
        ip.p.n(link).destination = try std.mem.concat(ip.p.a, u8, &.{ scheme, url });
        const t: u32 = @intCast(ip.p.nodes.items.len);
        try ip.p.nodes.append(ip.p.a, .{ .kind = .text, .open = false, .literal = url });
        ip.p.appendChild(link, t);
        ip.i += end;
    }

    fn emailAutolink(ip: *InlineParser) Error!void {
        // Scan back over the local part already emitted as text is not
        // possible; GFM email autolinks are recognized at their start.
        const s = ip.s;
        const rest = s[ip.i..];
        var k: usize = 0;
        const is_mailto = std.ascii.startsWithIgnoreCase(rest, "mailto:");
        const is_xmpp = std.ascii.startsWithIgnoreCase(rest, "xmpp:");
        if (is_mailto) k = 7 else if (is_xmpp) k = 5;
        const local_start = k;
        while (k < rest.len and (std.ascii.isAlphanumeric(rest[k]) or std.mem.indexOfScalar(u8, ".-_+", rest[k]) != null)) k += 1;
        if (k == local_start or k >= rest.len or rest[k] != '@') return;
        k += 1;
        const dom_start = k;
        var dots: usize = 0;
        while (k < rest.len and (std.ascii.isAlphanumeric(rest[k]) or rest[k] == '-' or rest[k] == '_' or (rest[k] == '.' and k + 1 < rest.len and std.ascii.isAlphanumeric(rest[k + 1])))) : (k += 1) {
            if (rest[k] == '.') dots += 1;
        }
        if (dots == 0 or k == dom_start) return;
        const last = rest[k - 1];
        if (last == '-' or last == '_') return;
        if (is_xmpp and k < rest.len and rest[k] == '/') {
            k += 1;
            while (k < rest.len and (std.ascii.isAlphanumeric(rest[k]) or rest[k] == '.' or rest[k] == '@')) k += 1;
        }
        // The text before (the local part start) must be at a boundary.
        if (ip.i > 0 and (std.ascii.isAlphanumeric(s[ip.i - 1]) or s[ip.i - 1] == '.' or s[ip.i - 1] == '_' or s[ip.i - 1] == '-' or s[ip.i - 1] == '+')) return;
        const addr = rest[0..k];
        const link = try ip.node(.link);
        ip.p.n(link).destination = if (is_mailto or is_xmpp) addr else try std.mem.concat(ip.p.a, u8, &.{ "mailto:", addr });
        const t: u32 = @intCast(ip.p.nodes.items.len);
        try ip.p.nodes.append(ip.p.a, .{ .kind = .text, .open = false, .literal = addr });
        ip.p.appendChild(link, t);
        ip.i += k;
    }
};

fn isAutolinkBoundary(c: u8) bool {
    return isWs(c) or c == '*' or c == '_' or c == '~' or c == '(';
}

fn autolink(s: []const u8) ?struct { len: usize, email: bool } {
    // <scheme:...>
    var i: usize = 1;
    const start = i;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '+' or s[i] == '.' or s[i] == '-')) i += 1;
    if (i - start >= 2 and i - start <= 32 and i < s.len and s[i] == ':' and std.ascii.isAlphabetic(s[start])) {
        i += 1;
        while (i < s.len and s[i] != '>' and s[i] > ' ' and s[i] != '<') i += 1;
        if (i < s.len and s[i] == '>') return .{ .len = i + 1, .email = false };
    }
    // <email>
    i = 1;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", s[i]) != null)) i += 1;
    if (i == 1 or i >= s.len or s[i] != '@') return null;
    i += 1;
    while (true) {
        const ls = i;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-') and i - ls < 63) i += 1;
        if (i == ls or s[i - 1] == '-' or s[ls] == '-') return null;
        if (i < s.len and s[i] == '.') {
            i += 1;
            continue;
        }
        break;
    }
    if (i < s.len and s[i] == '>') return .{ .len = i + 1, .email = true };
    return null;
}

fn prevCp(s: []const u8, i: usize) u21 {
    var k = i - 1;
    while (k > 0 and s[k] & 0xC0 == 0x80) k -= 1;
    return std.unicode.utf8Decode(s[k..i]) catch 0xFFFD;
}

fn nextCp(s: []const u8, i: usize) u21 {
    const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return std.unicode.utf8Decode(s[i..@min(s.len, i + l)]) catch 0xFFFD;
}

fn isUnicodeWs(c: u21) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0xA0 or c == 0x1680 or (c >= 0x2000 and c <= 0x200A) or c == 0x202F or c == 0x205F or c == 0x3000;
}

fn isUnicodePunct(c: u21) bool {
    if (c < 0x80) return isAsciiPunct(@intCast(c));
    // Unicode P and S categories, approximately: general punctuation,
    // Latin-1 punctuation and symbols, currency, CJK punctuation.
    return (c >= 0xA1 and c <= 0xBF) or c == 0xD7 or c == 0xF7 or (c >= 0x2010 and c <= 0x2027) or (c >= 0x2030 and c <= 0x205E) or (c >= 0x20A0 and c <= 0x20CF) or (c >= 0x2190 and c <= 0x23FF) or (c >= 0x2500 and c <= 0x27BF) or (c >= 0x3000 and c <= 0x303F) or (c >= 0xFF01 and c <= 0xFF0F) or (c >= 0xFE30 and c <= 0xFE4F);
}

// Rendering.

const Renderer = struct {
    p: *Parser,
    out: *std.ArrayList(u8),
    gpa: Allocator,
    tight: bool = false,

    fn w(r: *Renderer, s: []const u8) Error!void {
        try r.out.appendSlice(r.gpa, s);
    }

    fn esc(r: *Renderer, s: []const u8) Error!void {
        for (s) |c| switch (c) {
            '&' => try r.w("&amp;"),
            '<' => try r.w("&lt;"),
            '>' => try r.w("&gt;"),
            '"' => try r.w("&quot;"),
            else => try r.out.append(r.gpa, c),
        };
    }

    /// Percent-encodes a URL the way the reference renderer does.
    fn url(r: *Renderer, s: []const u8) Error!void {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '%' and i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2])) {
                try r.out.append(r.gpa, c);
                continue;
            }
            const safe = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~:/?#@!$&'()*+,;=", c) != null;
            if (c == '&') {
                try r.w("&amp;");
            } else if (c == '\'') {
                try r.w("'");
            } else if (safe) {
                try r.out.append(r.gpa, c);
            } else {
                var buf: [3]u8 = undefined;
                try r.w(std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch "");
            }
        }
    }

    fn children(r: *Renderer, id: u32) Error!void {
        var cur = r.p.n(id).first;
        while (cur != none) : (cur = r.p.n(cur).next) try r.render(cur);
    }

    fn plain(r: *Renderer, id: u32) Error!void {
        // Alt text: the text of the content, no markup.
        var cur = r.p.n(id).first;
        while (cur != none) : (cur = r.p.n(cur).next) {
            const x = r.p.n(cur);
            switch (x.kind) {
                .text, .code => try r.esc(x.literal),
                .softbreak, .hardbreak => try r.w(" "),
                .html_inline => {},
                else => try r.plain(cur),
            }
        }
    }

    fn cr(r: *Renderer) Error!void {
        if (r.out.items.len > 0 and r.out.items[r.out.items.len - 1] != '\n') try r.w("\n");
    }

    fn inTightList(r: *Renderer, id: u32) bool {
        const parent = r.p.n(id).parent;
        if (parent == none or r.p.n(parent).kind != .item) return false;
        const list = r.p.n(parent).parent;
        return list != none and r.p.n(list).tight;
    }

    fn render(r: *Renderer, id: u32) Error!void {
        const x = r.p.n(id);
        switch (x.kind) {
            .document => try r.children(id),
            .block_quote => {
                try r.cr();
                try r.w("<blockquote>\n");
                try r.children(id);
                try r.cr();
                try r.w("</blockquote>\n");
            },
            .list => {
                try r.cr();
                if (x.ordered) {
                    if (x.start != 1) {
                        var buf: [32]u8 = undefined;
                        try r.w(std.fmt.bufPrint(&buf, "<ol start=\"{d}\">\n", .{x.start}) catch "<ol>\n");
                    } else try r.w("<ol>\n");
                } else try r.w("<ul>\n");
                try r.children(id);
                try r.cr();
                try r.w(if (x.ordered) "</ol>\n" else "</ul>\n");
            },
            .item => {
                if (x.task != .none) {
                    try r.w(if (x.task == .checked) "<li class=\"task-list-item\"><input type=\"checkbox\" checked=\"\" disabled=\"\" /> " else "<li class=\"task-list-item\"><input type=\"checkbox\" disabled=\"\" /> ");
                } else try r.w("<li>");
                try r.children(id);
                try r.w("</li>\n");
            },
            .paragraph => {
                if (r.inTightList(id)) {
                    try r.children(id);
                } else {
                    try r.cr();
                    try r.w("<p>");
                    try r.children(id);
                    try r.w("</p>\n");
                }
            },
            .heading => {
                try r.cr();
                var buf: [8]u8 = undefined;
                try r.w(std.fmt.bufPrint(&buf, "<h{d}>", .{x.level}) catch "<h1>");
                try r.children(id);
                try r.w(std.fmt.bufPrint(&buf, "</h{d}>\n", .{x.level}) catch "</h1>\n");
            },
            .thematic_break => {
                try r.cr();
                try r.w("<hr />\n");
            },
            .code_block => {
                try r.cr();
                try r.w("<pre><code");
                if (x.info.len > 0) {
                    const lang_end = std.mem.indexOfAny(u8, x.info, " \t") orelse x.info.len;
                    try r.w(" class=\"language-");
                    try r.esc(x.info[0..lang_end]);
                    try r.w("\"");
                }
                try r.w(">");
                try r.esc(x.content.items);
                try r.w("</code></pre>\n");
            },
            .html_block => {
                try r.cr();
                try r.w(std.mem.trimEnd(u8, x.content.items, "\n"));
                try r.w("\n");
            },
            .table => {
                try r.cr();
                try r.w("<table>\n");
                var cur = x.first;
                var in_body = false;
                while (cur != none) : (cur = r.p.n(cur).next) {
                    const row = r.p.n(cur);
                    if (row.header) {
                        try r.w("<thead>\n");
                        try r.render(cur);
                        try r.w("</thead>\n");
                    } else {
                        if (!in_body) try r.w("<tbody>\n");
                        in_body = true;
                        try r.render(cur);
                    }
                }
                if (in_body) try r.w("</tbody>\n");
                try r.w("</table>\n");
            },
            .table_row => {
                try r.w("<tr>\n");
                try r.children(id);
                try r.w("</tr>\n");
            },
            .table_cell => {
                const tag = if (x.header) "th" else "td";
                try r.w("<");
                try r.w(tag);
                switch (x.cell_align) {
                    .left => try r.w(" align=\"left\""),
                    .center => try r.w(" align=\"center\""),
                    .right => try r.w(" align=\"right\""),
                    .none => {},
                }
                try r.w(">");
                try r.children(id);
                try r.w("</");
                try r.w(tag);
                try r.w(">\n");
            },
            .text => try r.esc(x.literal),
            .softbreak => try r.w("\n"),
            .hardbreak => try r.w("<br />\n"),
            .code => {
                try r.w("<code>");
                try r.esc(x.literal);
                try r.w("</code>");
            },
            .emph => {
                try r.w("<em>");
                try r.children(id);
                try r.w("</em>");
            },
            .strong => {
                try r.w("<strong>");
                try r.children(id);
                try r.w("</strong>");
            },
            .del => {
                try r.w("<del>");
                try r.children(id);
                try r.w("</del>");
            },
            .link => {
                try r.w("<a href=\"");
                try r.url(x.destination);
                try r.w("\"");
                if (x.title.len > 0) {
                    try r.w(" title=\"");
                    try r.esc(x.title);
                    try r.w("\"");
                }
                try r.w(">");
                try r.children(id);
                try r.w("</a>");
            },
            .image => {
                try r.w("<img src=\"");
                try r.url(x.destination);
                try r.w("\" alt=\"");
                try r.plain(id);
                try r.w("\"");
                if (x.title.len > 0) {
                    try r.w(" title=\"");
                    try r.esc(x.title);
                    try r.w("\"");
                }
                try r.w(" />");
            },
            .html_inline => try r.w(x.literal),
        }
    }
};

test {
    _ = @import("tests.zig");
}
