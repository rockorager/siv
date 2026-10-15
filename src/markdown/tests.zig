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
