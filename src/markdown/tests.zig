//! The CommonMark spec's examples (spec.txt of commonmark-spec 0.31.2,
//! fetched by the build and not kept in the repository: it is
//! CC-BY-SA, D25), and GFM's extensions.

const std = @import("std");
const md = @import("markdown.zig");
const testing = std.testing;

const spec = @embedFile("commonmark-spec.txt");

/// Collapses the differences the spec's own runner ignores: white
/// space between tags, and the order of nothing else.
fn normalize(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\n' and out.items.len > 0 and out.items[out.items.len - 1] == '>' and i + 1 < s.len and s[i + 1] == '<') continue;
        try out.append(a, s[i]);
    }
    return std.mem.trim(u8, out.items, "\n");
}

test "CommonMark spec examples" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const fence = "```````````````````````````````` example\n";
    var pos: usize = 0;
    var total: usize = 0;
    var passed: usize = 0;
    const verbose = false;
    while (std.mem.indexOfPos(u8, spec, pos, fence)) |k| {
        const start = k + fence.len;
        const dot = std.mem.indexOfPos(u8, spec, start, "\n.\n") orelse break;
        const end = std.mem.indexOfPos(u8, spec, dot + 3, "````````````````````````````````") orelse break;
        pos = end + 32;
        const input = try std.mem.replaceOwned(u8, a, spec[start .. dot + 1], "→", "\t");
        const want = try std.mem.replaceOwned(u8, a, spec[dot + 3 .. end], "→", "\t");
        total += 1;
        const got = try md.toHtml(gpa, input, .{ .gfm = false });
        defer gpa.free(got);
        if (std.mem.eql(u8, try normalize(a, got), try normalize(a, want))) {
            passed += 1;
        } else if (verbose) std.debug.print("FAIL #{d}\n--- input\n{s}--- want\n{s}--- got\n{s}\n", .{ total, input, want, got });
    }
    if (verbose) std.debug.print("CommonMark: {d}/{d}\n", .{ passed, total });
    try testing.expectEqual(@as(usize, 652), total);
    // Recorded in DESIGN.md (D32); a regression fails the gate.
    try testing.expect(passed >= min_passed);
}

const min_passed = 652;

fn expectHtml(input: []const u8, want: []const u8) !void {
    const got = try md.toHtml(testing.allocator, input, .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "GFM tables, task lists, strikethrough, autolinks" {
    try expectHtml(
        \\| a | b |
        \\|:--|--:|
        \\| 1 | `x \| y` |
        \\
    , "<table>\n<thead>\n<tr>\n<th align=\"left\">a</th>\n<th align=\"right\">b</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td align=\"left\">1</td>\n<td align=\"right\"><code>x | y</code></td>\n</tr>\n</tbody>\n</table>\n");
    try expectHtml("- [ ] todo\n- [x] done\n", "<ul>\n<li class=\"task-list-item\"><input type=\"checkbox\" disabled=\"\" /> todo</li>\n<li class=\"task-list-item\"><input type=\"checkbox\" checked=\"\" disabled=\"\" /> done</li>\n</ul>\n");
    try expectHtml("~~gone~~ ~one~\n", "<p><del>gone</del> <del>one</del></p>\n");
    try expectHtml("see www.example.com/a?b, or https://x.org.\n", "<p>see <a href=\"http://www.example.com/a?b\">www.example.com/a?b</a>, or <a href=\"https://x.org\">https://x.org</a>.</p>\n");
    try expectHtml("mail foo.bar@example.com now\n", "<p>mail <a href=\"mailto:foo.bar@example.com\">foo.bar@example.com</a> now</p>\n");
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

/// `unit` repeated `n` times.
fn repeated(gpa: std.mem.Allocator, unit: []const u8, n: usize) ![]u8 {
    const out = try gpa.alloc(u8, unit.len * n);
    for (0..n) |i| @memcpy(out[i * unit.len ..][0..unit.len], unit);
    return out;
}

test "inlines that find no match cost their length, not its square" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 40_000;
    // Each of these was read again, to its end or back to its start, for
    // every piece of it. What they render as stays as it was.
    const Case = struct { src: []const u8, want: ?[]const u8 = null, has: []const u8 = "", times: usize = 0 };
    var ticks: std.ArrayList(u8) = .empty;
    for (1..2000) |i| {
        try ticks.append(a, 'x');
        try ticks.appendNTimes(a, '`', i);
    }
    const brackets = try std.mem.concat(a, u8, &.{ try repeated(a, "[", n), "a", try repeated(a, "]", n) });
    const closers = try repeated(a, "a]", 5 * n);
    const parens = try repeated(a, ")", n);
    const cases = [_]Case{
        // Code spans opened with runs of every length, none closed.
        .{ .src = ticks.items, .want = try std.mem.concat(a, u8, &.{ "<p>", ticks.items, "</p>\n" }) },
        // Brackets in brackets that are no link: each was looked up as
        // a reference, with everything inside it as the label.
        .{ .src = brackets, .want = try std.mem.concat(a, u8, &.{ "<p>", brackets, "</p>\n" }) },
        // Text in many pieces, joined by copying all of it again.
        .{ .src = closers, .want = try std.mem.concat(a, u8, &.{ "<p>", closers, "</p>\n" }) },
        // Comments that never end.
        .{ .src = try std.mem.concat(a, u8, &.{ "a", try repeated(a, "<!--", n) }), .has = "&lt;!--", .times = n },
        // Emphasis closers whose openers are of the other character.
        .{ .src = try repeated(a, "*a_ ", n), .has = "<em>", .times = 0 },
        // Emphasis that closes, across the delimiters used before it.
        .{ .src = try std.mem.concat(a, u8, &.{ try repeated(a, "*a* ", n), try repeated(a, "_b_ ", n) }), .has = "<em>", .times = 2 * n },
        // Links inside image brackets that stay open.
        .{ .src = try repeated(a, "![[]()", n), .has = "<a href=\"\"></a>", .times = n },
        // Links after link brackets that stay open.
        .{ .src = try std.mem.concat(a, u8, &.{ try repeated(a, "[", n), try repeated(a, "[a](b) ", n) }), .has = "<a href=\"b\">a</a>", .times = n },
        // An autolink that ends in parentheses it does not own.
        .{ .src = try std.mem.concat(a, u8, &.{ "www.a.b", parens }), .want = try std.mem.concat(a, u8, &.{ "<p><a href=\"http://www.a.b\">www.a.b</a>", parens, "</p>\n" }) },
    };
    for (cases) |case| {
        const out = try md.toHtml(gpa, case.src, .{});
        defer gpa.free(out);
        if (case.want) |want| {
            try testing.expect(std.mem.eql(u8, want, out));
        } else try testing.expectEqual(case.times, count(out, case.has));
    }
}

test "nesting far deeper than the stack holds calls" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    // Block quotes in block quotes.
    const quotes = 200_000;
    for (0..quotes) |_| try src.appendSlice(gpa, "> ");
    try src.appendSlice(gpa, "x\n");
    {
        const out = try md.toHtml(gpa, src.items, .{});
        defer gpa.free(out);
        try testing.expectEqual(quotes, count(out, "<blockquote>\n"));
        try testing.expectEqual(quotes, count(out, "</blockquote>\n"));
        try testing.expectEqual(@as(usize, 1), count(out, "<p>x</p>"));
    }
    // Lists in lists, each a marker on one line.
    const lists = 50_000;
    src.clearRetainingCapacity();
    for (0..lists) |_| try src.appendSlice(gpa, "- ");
    try src.appendSlice(gpa, "x\n");
    {
        const out = try md.toHtml(gpa, src.items, .{});
        defer gpa.free(out);
        try testing.expectEqual(lists, count(out, "<ul>\n<li>"));
        try testing.expectEqual(lists, count(out, "</li>\n</ul>\n"));
        try testing.expectEqual(@as(usize, 1), count(out, "<li>x</li>"));
    }
    // Emphasis in strong emphasis in emphasis, as text and as an
    // image's alternative text, which is the text without the markup.
    const pairs = 50_000;
    src.clearRetainingCapacity();
    for (0..pairs) |_| try src.appendSlice(gpa, "*a **b ");
    try src.appendSlice(gpa, "x");
    for (0..pairs) |_| try src.appendSlice(gpa, " c** d*");
    const text = try gpa.dupe(u8, src.items);
    defer gpa.free(text);
    {
        const out = try md.toHtml(gpa, text, .{});
        defer gpa.free(out);
        try testing.expectEqual(pairs, count(out, "<em>a <strong>b "));
        try testing.expectEqual(pairs, count(out, " c</strong> d</em>"));
    }
    src.clearRetainingCapacity();
    try src.appendSlice(gpa, "![");
    try src.appendSlice(gpa, text);
    try src.appendSlice(gpa, "](i.png)\n");
    {
        const out = try md.toHtml(gpa, src.items, .{});
        defer gpa.free(out);
        try testing.expect(std.mem.startsWith(u8, out, "<p><img src=\"i.png\" alt=\"a b a b "));
        try testing.expect(std.mem.endsWith(u8, out, " c d c d\" /></p>\n"));
        try testing.expectEqual(@as(usize, 0), count(out, "<em>"));
    }
}

test "a blank line costs the same however many lists are open" {
    const gpa = testing.allocator;
    // Every open list item takes a blank line, so each one walked down
    // all of them and back up: 50,000 nested lists and 50,000 blank lines
    // were 5,000,000,000 steps for 150 KB.
    const lists = 50_000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..lists) |_| try src.appendSlice(gpa, "- ");
    try src.appendSlice(gpa, "a\n");
    for (0..lists) |_| try src.appendSlice(gpa, "\n");
    try src.appendSlice(gpa, "b\n");
    {
        const out = try md.toHtml(gpa, src.items, .{});
        defer gpa.free(out);
        try testing.expectEqual(lists, count(out, "<ul>"));
        // The text after the blank lines ends every list.
        try testing.expect(std.mem.endsWith(u8, out, "</ul>\n<p>b</p>\n"));
    }
    // A code block in the innermost item keeps each of the lines.
    src.clearRetainingCapacity();
    for (0..lists) |_| try src.appendSlice(gpa, "- ");
    try src.appendSlice(gpa, "```\n");
    for (0..lists) |_| try src.appendSlice(gpa, " \n");
    try src.appendSlice(gpa, "b\n");
    const out = try md.toHtml(gpa, src.items, .{});
    defer gpa.free(out);
    const code = std.mem.indexOf(u8, out, "<pre><code>").? + "<pre><code>".len;
    const end = std.mem.indexOfPos(u8, out, code, "</code></pre>").?;
    try testing.expectEqual(lists, end - code);
    try testing.expectEqual(lists, count(out[code..end], "\n"));
    try testing.expect(std.mem.endsWith(u8, out, "</ul>\n<p>b</p>\n"));
}

test "fuzz the parser" {
    try testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        "# Title\n\n> quote *em* **strong** `code`\n\n- a\n  - b\n1. c\n\n```zig\nconst x = 1;\n```\n",
        "| a | b |\n|---|---|\n| [link](http://x \"t\") | ![img](i.png) |\n\n[ref]: /url\n[ref]\n",
        "<div>\n*html*\n</div>\n\n***\nSetext\n---\n\n    code\n\n- [x] task ~~del~~ www.x.org foo@bar.com\n",
    } });
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    const out = try md.toHtml(testing.allocator, src, .{});
    testing.allocator.free(out);
}
