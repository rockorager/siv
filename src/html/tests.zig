//! The html5lib tree-construction tests (MIT, testdata/html5lib, from
//! html5lib-tests a9f4496, the last revision before the relaxed `<select>`
//! parser), parsing and the fuzz target.

const std = @import("std");
const html = @import("html.zig");
const testing = std.testing;

const files = [_][]const u8{
    "adoption01",    "adoption02",       "blocks",           "comments01",  "doctype01",  "domjs-unsafe", "entities01",
    "entities02",    "foreign-fragment", "html5test-com",    "inbody01",    "isindex",    "main-element", "math",
    "menuitem-element", "namespace-sensitivity", "noscript01", "pending-spec-changes", "plain-text-unsafe", "quirks01",
    "ruby",          "scriptdata01",     "search-element",   "svg",         "tables01",   "template",     "tests1",
    "tests10",       "tests11",          "tests12",          "tests14",     "tests15",    "tests16",      "tests17",
    "tests18",       "tests19",          "tests2",           "tests20",     "tests21",    "tests22",      "tests23",
    "tests24",       "tests25",          "tests26",          "tests3",      "tests4",     "tests5",       "tests6",
    "tests7",        "tests8",           "tests9",           "tests_innerHTML_1", "tricky01", "webkit01",  "webkit02",
};

const Case = struct {
    data: []const u8,
    fragment: ?[]const u8,
    script: ?bool,
    document: []const u8,
};

fn after(block: []const u8, marker: []const u8) ?[]const u8 {
    const k = std.mem.indexOf(u8, block, marker) orelse return null;
    return block[k + marker.len ..];
}

fn line(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn runCase(gpa: std.mem.Allocator, c: Case, out: *std.Io.Writer.Allocating) !bool {
    var options: html.Options = .{};
    if (c.fragment) |f| {
        const t = std.mem.trim(u8, f, " \n");
        if (std.mem.startsWith(u8, t, "svg ")) {
            options.context = .{ .name = t[4..], .ns = .svg };
        } else if (std.mem.startsWith(u8, t, "math ")) {
            options.context = .{ .name = t[5..], .ns = .mathml };
        } else options.context = .{ .name = t };
    }
    var dom = try html.parse(gpa, c.data, options);
    defer dom.deinit();
    out.clearRetainingCapacity();
    const root = if (c.fragment != null) dom.documentElement() else html.NodeId.document;
    try html.serialize.testFormat(&dom, &out.writer, root);
    const got = std.mem.trimEnd(u8, out.written(), "\n");
    const want = std.mem.trimEnd(u8, c.document, "\n");
    return std.mem.eql(u8, got, want);
}

test "html5lib tree construction" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var passed: usize = 0;
    var total: usize = 0;
    var skipped: usize = 0;
    const verbose = false;
    inline for (files) |name| {
        const src = @embedFile("testdata/html5lib/" ++ name ++ ".dat");
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, src, pos, "#data\n")) |k| {
            if (k != 0 and src[k - 1] != '\n') {
                pos = k + 1;
                continue;
            }
            const next = std.mem.indexOfPos(u8, src, k + 6, "\n#data\n");
            const block = src[k + 6 .. if (next) |x| x + 1 else src.len];
            pos = if (next) |x| x + 1 else src.len;
            const data = block[0 .. std.mem.indexOf(u8, block, "\n#errors") orelse continue];
            const doc = after(block, "\n#document\n") orelse continue;
            if (std.mem.indexOf(u8, block, "\n#script-on\n") != null) {
                skipped += 1;
                continue;
            }
            const frag = if (after(block, "\n#document-fragment\n")) |f| line(f) else null;
            const c: Case = .{ .data = data, .fragment = frag, .script = null, .document = doc };
            total += 1;
            if (try runCase(gpa, c, &out)) {
                passed += 1;
            } else if (verbose) {
                std.debug.print("FAIL {s}: {s}\n--- got\n{s}\n--- want\n{s}\n", .{ name, data, out.written(), doc });
            }
        }
    }
    // Recorded in DESIGN.md (D32); a regression fails the gate.
    if (verbose) std.debug.print("html5lib: {d}/{d} passed, {d} skipped (scripting)\n", .{ passed, total, skipped });
    try testing.expect(total > 1400);
    try testing.expect(passed * 1000 >= total * min_pass_permille);
}

/// The pass rate the gate holds (per mille).
const min_pass_permille = 1000;

test "named and numeric references, legacy and in attributes" {
    var dom = try html.parse(testing.allocator, "<p title='&notit; &amp=1'>&copy &lt;&#x41;&#128;&#0;&notin;</p>", .{});
    defer dom.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try html.serialize.html(&dom, &out.writer, dom.body());
    try testing.expectEqualStrings("<p title=\"&amp;notit; &amp;amp=1\">© &lt;A€\u{FFFD}∉</p>", out.written());
}

test "email-grade broken markup recovers like browsers" {
    var dom = try html.parse(testing.allocator,
        \\<table><tr><td>a<b>bold<td>b</b></table><p>one<p>two<div><font color=red><i>x</div>y
    , .{});
    defer dom.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try html.serialize.html(&dom, &out.writer, dom.body());
    try testing.expectEqualStrings("<table><tbody><tr><td>a<b>bold</b></td><td>b</td></tr></tbody></table><p>one</p><p>two</p><div><font color=\"red\"><i>x</i></font></div><font color=\"red\"><i>y</i></font>", out.written());
}

test "fuzz the parser" {
    try testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        "<!DOCTYPE html><html><head><title>t</title></head><body><p class=a>x<b>y<i>z</b>w</i></p></body></html>",
        "<table><tr><td>1<td>2</table><svg><foreignObject><p>q</svg><math><mi>x</math>",
        "<select><option>a<optgroup><option>b</select><template><td>c</template>",
        "<!--c--><![CDATA[x]]><script>a<!--<script></script>--></script><textarea>\n&amp;</textarea>",
    } });
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    var dom = try html.parse(testing.allocator, src, .{});
    defer dom.deinit();
    // The tree is well formed: every child's parent is its parent.
    for (dom.nodes.items, 0..) |n, i| {
        var c = n.first;
        while (c != .none) : (c = dom.node(c).next) try testing.expectEqual(@as(u32, @intCast(i)), dom.node(c).parent.index());
    }
}
