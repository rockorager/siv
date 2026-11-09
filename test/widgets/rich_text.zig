//! The rich text editor (D22) through the C ABI on the headless backend:
//! Portable Text in and out, typing with the usual keys and Vim's, and
//! the look of every block against test/golden/widgets/rich-text-*.png.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const platform = @import("platform");
const harness = @import("../abi/harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const Harness = harness.Harness;
const ok = harness.ok;
const Value = std.json.Value;
const A = abi.application;

const ks = struct {
    const @"return": u32 = 0xff0d;
    const escape: u32 = 0xff1b;
    const tab: u32 = 0xff09;
    const iso_left_tab: u32 = 0xfe20;
    const home: u32 = 0xff50;
    const end: u32 = 0xff57;
    const left: u32 = 0xff51;
    const right: u32 = 0xff53;
    const backspace: u32 = 0xff08;
};

/// Every block type EmDash's Portable Text has, with a field the editor
/// does not edit (textAlign) and keys it must keep.
const sample =
    \\[
    \\  {"_type": "block", "_key": "a1", "style": "h1", "markDefs": [], "children": [
    \\    {"_type": "span", "_key": "a1s", "text": "Release notes", "marks": []}]},
    \\  {"_type": "block", "_key": "a2", "style": "normal", "markDefs": [
    \\    {"_type": "link", "_key": "ln", "href": "https://emdashcms.com", "blank": true}], "children": [
    \\    {"_type": "span", "_key": "a2a", "text": "Written in ", "marks": []},
    \\    {"_type": "span", "_key": "a2b", "text": "EmDash", "marks": ["ln"]},
    \\    {"_type": "span", "_key": "a2c", "text": ", with ", "marks": []},
    \\    {"_type": "span", "_key": "a2d", "text": "bold", "marks": ["strong"]},
    \\    {"_type": "span", "_key": "a2e", "text": ", ", "marks": []},
    \\    {"_type": "span", "_key": "a2f", "text": "italic", "marks": ["em"]},
    \\    {"_type": "span", "_key": "a2g", "text": ", and ", "marks": []},
    \\    {"_type": "span", "_key": "a2h", "text": "code", "marks": ["code"]},
    \\    {"_type": "span", "_key": "a2i", "text": ".", "marks": []}]},
    \\  {"_type": "block", "_key": "a3", "style": "h2", "markDefs": [], "children": [
    \\    {"_type": "span", "_key": "a3s", "text": "Changes", "marks": []}]},
    \\  {"_type": "block", "_key": "a4", "style": "normal", "listItem": "bullet", "level": 1, "markDefs": [], "children": [
    \\    {"_type": "span", "_key": "a4a", "text": "Faster", "marks": ["underline"]},
    \\    {"_type": "span", "_key": "a4b", "text": " startup, ", "marks": []},
    \\    {"_type": "span", "_key": "a4c", "text": "fewer", "marks": ["strike-through"]},
    \\    {"_type": "span", "_key": "a4d", "text": " no stalls", "marks": []}]},
    \\  {"_type": "block", "_key": "a5", "style": "normal", "listItem": "bullet", "level": 2, "markDefs": [], "children": [
    \\    {"_type": "span", "_key": "a5s", "text": "Fonts load in log", "marks": []},
    \\    {"_type": "span", "_key": "a5t", "text": "2", "marks": ["subscript"]},
    \\    {"_type": "span", "_key": "a5u", "text": " n", "marks": []}]},
    \\  {"_type": "block", "_key": "a6", "style": "normal", "listItem": "number", "level": 1, "markDefs": [], "children": [
    \\    {"_type": "span", "_key": "a6s", "text": "Update", "marks": []}]},
    \\  {"_type": "block", "_key": "a7", "style": "normal", "listItem": "number", "level": 1, "markDefs": [], "children": [
    \\    {"_type": "span", "_key": "a7s", "text": "Restart", "marks": []},
    \\    {"_type": "span", "_key": "a7t", "text": "1", "marks": ["superscript"]}]},
    \\  {"_type": "block", "_key": "a8", "style": "blockquote", "markDefs": [], "children": [
    \\    {"_type": "span", "_key": "a8s", "text": "It just works.\nMostly.", "marks": []}]},
    \\  {"_type": "code", "_key": "a9", "language": "zig", "code": "const x = 1;\nconst y = x + 1;"},
    \\  {"_type": "image", "_key": "b1", "alt": "The new window", "asset": {"_ref": "image-abc-640x480-png"}},
    \\  {"_type": "block", "_key": "b2", "style": "normal", "textAlign": "center", "markDefs": [], "children": [
    \\    {"_type": "span", "_key": "b2s", "text": "That is all.", "marks": []}]}
    \\]
;

const Log = struct {
    changes: u32 = 0,
    selects: u32 = 0,
    command: [32]u8 = undefined,
    command_len: usize = 0,

    fn onChange(ud: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.changes += 1;
        return .handled;
    }
    fn onSelect(ud: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.selects += 1;
        return .handled;
    }
    fn onActivate(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.command_len = @min(ev.text_len, log.command.len);
        @memcpy(log.command[0..log.command_len], ev.text.?[0..log.command_len]);
        return .handled;
    }
};

fn build(h: *Harness, desc: t.RichTextDesc, log: *Log) !t.Node {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    c.siv_set_visual(txn, root, &.{ .background_token = .view_bg });
    var d = desc;
    const node = c.siv_rich_text(txn, root, &d);
    c.siv_on(txn, node, .change, Log.onChange, null, log);
    c.siv_on(txn, node, .select, Log.onSelect, null, log);
    c.siv_on(txn, node, .activate, Log.onActivate, null, log);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_focus(node));
    try h.settle();
    return node;
}

fn document(node: t.Node) ![]u8 {
    var len: usize = 0;
    try ok(c.siv_rich_text_get_document(node, null, 0, &len));
    const buf = try testing.allocator.alloc(u8, len);
    try ok(c.siv_rich_text_get_document(node, buf.ptr, buf.len, &len));
    return buf;
}

fn get(v: Value, name: []const u8) Value {
    return v.object.get(name) orelse .null;
}

/// The document in short: blocks separated by " | ", each its style or
/// list and level, then its text, marked spans as marks(text).
fn outline(node: t.Node) ![]u8 {
    const a = testing.allocator;
    const json = try document(node);
    defer a.free(json);
    const parsed = try std.json.parseFromSlice(Value, a, json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (parsed.value.array.items, 0..) |b, i| {
        if (i > 0) try out.appendSlice(a, " | ");
        const ty = get(b, "_type").string;
        if (!std.mem.eql(u8, ty, "block")) {
            try out.appendSlice(a, ty);
            if (get(b, "code") == .string) try out.print(a, ":{s}", .{get(b, "code").string});
            continue;
        }
        if (get(b, "listItem") == .string) {
            try out.print(a, "{s}{d}:", .{ get(b, "listItem").string, get(b, "level").integer });
        } else try out.print(a, "{s}:", .{get(b, "style").string});
        for (get(b, "children").array.items) |span| {
            const marks = get(span, "marks").array.items;
            if (marks.len == 0) {
                try out.appendSlice(a, get(span, "text").string);
                continue;
            }
            for (marks, 0..) |m, j| try out.print(a, "{s}{s}", .{ if (j > 0) "+" else "", m.string });
            try out.print(a, "({s})", .{get(span, "text").string});
        }
    }
    return out.toOwnedSlice(a);
}

fn expectOutline(node: t.Node, want: []const u8) !void {
    const got = try outline(node);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn jsonEql(a: Value, b: Value) bool {
    return switch (a) {
        .object => |o| b == .object and o.count() == b.object.count() and for (o.keys(), o.values()) |k, v| {
            const other = b.object.get(k) orelse break false;
            if (!jsonEql(v, other)) break false;
        } else true,
        .array => |x| b == .array and x.items.len == b.array.items.len and for (x.items, b.array.items) |p, q| {
            if (!jsonEql(p, q)) break false;
        } else true,
        .string => |s| b == .string and std.mem.eql(u8, s, b.string),
        .integer => |n| b == .integer and n == b.integer,
        .bool => |x| b == .bool and x == b.bool,
        .null => b == .null,
        else => false,
    };
}

/// Types text: letters as their keysyms, "\n" as Return.
fn typeText(h: *Harness, s: []const u8) !void {
    const view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |ch| {
        if (std.mem.eql(u8, ch, "\n")) {
            try h.typeKey(ks.@"return", "", .{});
        } else try h.typeKey(try std.unicode.utf8Decode(ch), ch, .{});
        try h.settle();
    }
}

fn press(h: *Harness, sym: u32, mods: platform.Mods) !void {
    try h.typeKey(sym, "", mods);
    try h.settle();
}

fn state(node: t.Node) !t.RichTextState {
    var s: t.RichTextState = undefined;
    try ok(c.siv_rich_text_get_state(node, &s));
    return s;
}

fn status(node: t.Node, buf: []u8) ![]const u8 {
    var len: usize = 0;
    try ok(c.siv_rich_text_get_status(node, buf.ptr, buf.len, &len));
    return buf[0..@min(len, buf.len)];
}

test "rich text: Portable Text comes back as it went in, and every block shows" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(520, 720, null, null);
    defer h.stop();
    var log: Log = .{};
    const node = try build(&h, .{ .document = sample, .document_len = sample.len }, &log);
    try h.expectGolden("rich-text-light", 520, 720);

    // Unedited, the document is the same JSON, keys and fields the editor
    // does not edit included.
    const out = try document(node);
    defer testing.allocator.free(out);
    const want = try std.json.parseFromSlice(Value, testing.allocator, sample, .{});
    defer want.deinit();
    const got = try std.json.parseFromSlice(Value, testing.allocator, out, .{});
    defer got.deinit();
    try testing.expect(jsonEql(want.value, got.value));

    const s = try state(node);
    try testing.expectEqual(t.RichTextStyle.h1, s.style);
    try testing.expect(!s.modified and !s.can_undo);
    try testing.expectEqual(@as(u32, 0), log.changes);

    try ok(c.siv_app_set_theme(h.app, &.{ .scheme = .dark }));
    try h.settle();
    try h.expectGolden("rich-text-dark", 520, 720);
}

test "rich text: typing, Markdown, Enter, lists, code blocks, marks, and undo" {
    var h: Harness = .{};
    try h.start(480, 480, null, null);
    defer h.stop();
    var log: Log = .{};
    const node = try build(&h, .{}, &log);

    try typeText(&h, "# Title\nSome text.\n- one\n");
    try press(&h, ks.tab, .{});
    try typeText(&h, "nested\n");
    try press(&h, ks.iso_left_tab, .{ .shift = true });
    // Enter in an empty item ends the list; "``` " starts a code block,
    // and Enter on its empty last line ends it.
    try typeText(&h, "two\n\nafter\n``` let x = 1;\nlet y = 2;\n\nback\n> quoted");
    try press(&h, ks.@"return", .{ .shift = true });
    try typeText(&h, "soft");
    try expectOutline(node, "h1:Title | normal:Some text. | bullet1:one | bullet2:nested | bullet1:two | normal:after | code:let x = 1;\nlet y = 2; | normal:back | blockquote:quoted\nsoft");
    var s = try state(node);
    try testing.expectEqual(t.RichTextStyle.blockquote, s.style);
    try testing.expect(s.modified and s.can_undo);
    try testing.expect(log.changes > 0 and log.selects > 0);

    // A fresh document: marks for what is typed next, then over a
    // selection by command.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_rich_text_set_document(txn, node, "", 0);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expect(!(try state(node)).modified);
    try typeText(&h, "plain ");
    try press(&h, 'b', .{ .ctrl = true });
    try typeText(&h, "bold");
    try press(&h, 'b', .{ .ctrl = true });
    try typeText(&h, " and ");
    try press(&h, 'e', .{ .ctrl = true });
    try typeText(&h, "code");
    try press(&h, 'e', .{ .ctrl = true });
    try expectOutline(node, "normal:plain strong(bold) and code(code)");
    try press(&h, ks.home, .{});
    try press(&h, ks.end, .{ .shift = true });
    try ok(c.siv_rich_text_run(node, .em));
    try ok(c.siv_rich_text_run(node, .h2));
    try h.settle();
    try expectOutline(node, "h2:em(plain )strong+em(bold)em( and )em+code(code)");
    s = try state(node);
    try testing.expectEqual(t.RichTextStyle.h2, s.style);
    try testing.expect(s.marks.em);
    // Undo by step: the heading, then the italic.
    try press(&h, 'z', .{ .ctrl = true });
    try press(&h, 'z', .{ .ctrl = true });
    try expectOutline(node, "normal:plain strong(bold) and code(code)");
    try press(&h, 'z', .{ .ctrl = true, .shift = true });
    try expectOutline(node, "normal:em(plain )strong+em(bold)em( and )em+code(code)");

    // Superscript and subscript replace each other, for what is typed
    // next and over a selection.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_rich_text_set_document(txn, node, "", 0);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try typeText(&h, "x");
    try press(&h, '.', .{ .ctrl = true });
    try typeText(&h, "2");
    try press(&h, ',', .{ .ctrl = true });
    try typeText(&h, "i");
    try expectOutline(node, "normal:xsuperscript(2)subscript(i)");
    try press(&h, ks.home, .{});
    try press(&h, ks.end, .{ .shift = true });
    try ok(c.siv_rich_text_run(node, .superscript));
    try expectOutline(node, "normal:superscript(x2i)");
    try testing.expect((try state(node)).marks.superscript);
}

test "rich text: Vim's keys" {
    var h: Harness = .{};
    try h.start(480, 300, null, null);
    defer h.stop();
    var log: Log = .{};
    const node = try build(&h, .{ .flags = .{ .vim = true } }, &log);
    try testing.expectEqual(t.RichTextMode.normal, (try state(node)).mode);
    var buf: [64]u8 = undefined;

    try typeText(&h, "ihello world foo");
    try testing.expectEqual(t.RichTextMode.insert, (try state(node)).mode);
    try press(&h, ks.escape, .{});
    try typeText(&h, "0dw");
    try expectOutline(node, "normal:world foo");
    try typeText(&h, "uyyp");
    try expectOutline(node, "normal:hello world foo | normal:hello world foo");
    // A change repeats with dot on the line above.
    try typeText(&h, "ciwbar");
    try press(&h, ks.escape, .{});
    try typeText(&h, "k.");
    try expectOutline(node, "normal:bar world foo | normal:bar world foo");
    try typeText(&h, "ggdd2u");
    try expectOutline(node, "normal:hello world foo | normal:bar world foo");

    // The register keeps marks: bold over a visual selection, yanked and
    // put as a line.
    try typeText(&h, "ggve");
    try testing.expectEqual(t.RichTextMode.visual, (try state(node)).mode);
    try press(&h, 'b', .{ .ctrl = true });
    try press(&h, ks.escape, .{});
    try typeText(&h, "yyGp");
    try expectOutline(node, "normal:strong(hello) world foo | normal:bar world foo | normal:strong(hello) world foo");
    try typeText(&h, "Vkd");
    try expectOutline(node, "normal:strong(hello) world foo");

    // Pending keys and the command line show in the status.
    try typeText(&h, "2d");
    try testing.expectEqualStrings("2d", try status(node, &buf));
    try press(&h, ks.escape, .{});
    try typeText(&h, ":w");
    try testing.expectEqual(t.RichTextMode.command, (try state(node)).mode);
    try testing.expectEqualStrings(":w", try status(node, &buf));
    try press(&h, ks.@"return", .{});
    try testing.expectEqualStrings("w", log.command[0..log.command_len]);
    try typeText(&h, "/foo");
    try press(&h, ks.@"return", .{});
    try typeText(&h, "x");
    try expectOutline(node, "normal:strong(hello) world oo");
    try typeText(&h, "/zzz");
    try press(&h, ks.@"return", .{});
    try testing.expectEqualStrings("Pattern not found: zzz", try status(node, &buf));

    // Off, keys type again.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_rich_text_set_flags(txn, node, .{});
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(t.RichTextMode.edit, (try state(node)).mode);
    try typeText(&h, "x");
    try expectOutline(node, "normal:strong(hello) world xoo");
}

test "rich text: a custom schema, invalid descriptors and documents" {
    var h: Harness = .{};
    try h.start(320, 200, null, null);
    defer h.stop();
    var log: Log = .{};
    // Only bold and h2: other styles show as normal, other marks and
    // objects are dropped, code shows as text, with a message.
    const node = try build(&h, .{
        .schema = .custom,
        .styles = .{ .h2 = true },
        .marks = .{ .strong = true },
        .document = sample,
        .document_len = sample.len,
    }, &log);
    const got = try outline(node);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "normal:Release notes | normal:Written in EmDash, with strong(bold), italic, and code. | h2:Changes | normal:Faster startup, fewer no stalls"));
    try testing.expect(std.mem.endsWith(u8, got, "normal:const x = 1; | normal:const y = x + 1; | normal:That is all."));
    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try status(node, &buf), "image blocks are dropped") != null);
    try testing.expectEqual(t.Result.error_unsupported, c.siv_rich_text_run(node, .h1));
    try testing.expectEqual(t.Result.error_unsupported, c.siv_rich_text_run(node, .code_block));
    try ok(c.siv_rich_text_run(node, .h2));

    const root = c.siv_window_get_root(h.window);
    const Case = struct { desc: t.RichTextDesc, want: t.Result };
    const cases = [_]Case{
        .{ .desc = .{ .document = "{", .document_len = 1 }, .want = .error_invalid_argument },
        .{ .desc = .{ .document = "{}", .document_len = 2 }, .want = .error_invalid_argument },
        .{ .desc = .{ .styles = .{ .h1 = true } }, .want = .error_invalid_argument },
        .{ .desc = .{ .flags = @bitCast(@as(u32, 2)) }, .want = .error_unsupported },
        .{ .desc = .{ .font_size = -1 }, .want = .error_invalid_argument },
    };
    for (cases) |cs| {
        var txn: t.Txn = .null;
        try ok(c.siv_txn_begin(h.window, &txn));
        var d = cs.desc;
        try testing.expectEqual(t.Node.null, c.siv_rich_text(txn, root, &d));
        try testing.expectEqual(cs.want, c.siv_txn_commit(txn));
    }
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_rich_text_set_document(txn, node, "[1", 2);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
    // Inside an open transaction a command is busy.
    try ok(c.siv_txn_begin(h.window, &txn));
    try testing.expectEqual(t.Result.error_busy, c.siv_rich_text_run(node, .strong));
    try ok(c.siv_txn_commit(txn));
}

/// The document's links in short: blocks separated by " | ", linked
/// spans as [text](href). Checks that every link is a link markDef of
/// its block named by the span's mark.
fn links(node: t.Node) ![]u8 {
    const a = testing.allocator;
    const json = try document(node);
    defer a.free(json);
    const parsed = try std.json.parseFromSlice(Value, a, json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (parsed.value.array.items, 0..) |b, i| {
        if (i > 0) try out.appendSlice(a, " | ");
        if (!std.mem.eql(u8, get(b, "_type").string, "block")) continue;
        const defs = get(b, "markDefs").array.items;
        for (get(b, "children").array.items) |span| {
            const text = get(span, "text").string;
            const def: ?Value = blk: for (get(span, "marks").array.items) |m| {
                for (defs) |d| if (std.mem.eql(u8, get(d, "_key").string, m.string)) break :blk d;
            } else null;
            if (def) |d| {
                try testing.expectEqualStrings("link", get(d, "_type").string);
                try out.print(a, "[{s}]({s})", .{ text, get(d, "href").string });
            } else try out.appendSlice(a, text);
        }
    }
    return out.toOwnedSlice(a);
}

fn expectLinks(node: t.Node, want: []const u8) !void {
    const got = try links(node);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

/// The _key of the first link markDef in the document.
fn firstLinkKey(node: t.Node, buf: []u8) ![]const u8 {
    const a = testing.allocator;
    const json = try document(node);
    defer a.free(json);
    const parsed = try std.json.parseFromSlice(Value, a, json, .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |b| {
        if (get(b, "markDefs") != .array) continue;
        for (get(b, "markDefs").array.items) |d| {
            const k = get(d, "_key").string;
            @memcpy(buf[0..k.len], k);
            return buf[0..k.len];
        }
    }
    return error.NoLink;
}

/// The link at the caret: its href and range.
fn linkAtCaret(node: t.Node, buf: []u8) !struct { []const u8, u32, u32 } {
    var len: usize = 0;
    var start: u32 = 0;
    var end: u32 = 0;
    try ok(c.siv_rich_text_get_link(node, buf.ptr, buf.len, &len, &start, &end));
    return .{ buf[0..len], start, end };
}

/// The application's open popup, if any.
fn openPopup(h: *Harness) !?t.Window {
    const self = try h.internal();
    var found: ?t.Window = null;
    for (self.windows.items) |slot| if (slot) |pw| {
        if (!pw.dead and pw.parent != null and pw.win.shown) found = @fromBackingInt(pw.handle);
    };
    return found;
}

fn typeTextIn(h: *Harness, window: t.Window, s: []const u8) !void {
    for (s) |ch| {
        try h.typeKeyIn(window, ch, &.{ch}, .{});
        try h.settle();
    }
}

fn pressIn(h: *Harness, window: t.Window, sym: u32, mods: platform.Mods) !void {
    try h.typeKeyIn(window, sym, "", mods);
    try h.settle();
}

/// Selects n characters from `at` with Home, Right, and Shift+Right.
fn selectChars(h: *Harness, at: u32, n: u32) !void {
    try press(h, ks.home, .{});
    for (0..at) |_| try press(h, ks.right, .{});
    for (0..n) |_| try press(h, ks.right, .{ .shift = true });
}

/// The editor inside a rich text editor: the root stack's last child.
fn editorOf(node: t.Node) t.Node {
    return c.siv_node_get_related(node, .last_child);
}

test "rich text: Ctrl+K links a selection, edits and removes a link, and inserts one" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(480, 320, null, null);
    defer h.stop();
    var log: Log = .{};
    const node = try build(&h, .{}, &log);
    try typeText(&h, "Read the docs today");

    // A selection: the popover asks for a URL; one without a scheme gets
    // https://.
    try selectChars(&h, 9, 4);
    try press(&h, 'k', .{ .ctrl = true });
    var popup = (try openPopup(&h)) orelse return error.NoPopup;
    // Under the selected word, at its start.
    var word: t.Rect = .{};
    try ok(c.siv_node_get_caret_rect(editorOf(node), 9, &word));
    const placed = (try A.App.window(@backingInt(popup), A.window_tag)).win.state.popup.?;
    try testing.expectApproxEqAbs(word.x, @as(f32, @floatFromInt(placed.x)), 2);
    try testing.expectApproxEqAbs(word.y + word.height, @as(f32, @floatFromInt(placed.y)), 2);
    try typeTextIn(&h, popup, "example.com");
    try pressIn(&h, popup, ks.@"return", .{});
    try testing.expectEqual(@as(?t.Window, null), try openPopup(&h));
    try expectLinks(node, "Read the [docs](https://example.com) today");
    try testing.expect((try state(node)).marks.link);
    var key_buf: [32]u8 = undefined;
    const key = try testing.allocator.dupe(u8, try firstLinkKey(node, &key_buf));
    defer testing.allocator.free(key);

    // On the link, with nothing selected, it shows the URL to change; the
    // whole link changes and keeps its key.
    try selectChars(&h, 11, 0);
    var buf: [128]u8 = undefined;
    const at = try linkAtCaret(node, &buf);
    try testing.expectEqualStrings("https://example.com", at[0]);
    try testing.expectEqual(@as(u32, 9), at[1]);
    try testing.expectEqual(@as(u32, 13), at[2]);
    try press(&h, 'k', .{ .ctrl = true });
    popup = (try openPopup(&h)) orelse return error.NoPopup;
    var size: t.Size = .{};
    try ok(c.siv_window_get_size(popup, &size));
    try h.expectGoldenOf(popup, "rich-text-link-popover", @intFromFloat(size.width), @intFromFloat(size.height));
    // The URL is selected: typing replaces it.
    try typeTextIn(&h, popup, "https://parcel.app");
    try pressIn(&h, popup, ks.@"return", .{});
    try expectLinks(node, "Read the [docs](https://parcel.app) today");
    try testing.expectEqualStrings(key, try firstLinkKey(node, &key_buf));

    // Escape cancels.
    try press(&h, 'k', .{ .ctrl = true });
    popup = (try openPopup(&h)) orelse return error.NoPopup;
    try typeTextIn(&h, popup, "nope");
    try pressIn(&h, popup, ks.escape, .{});
    try testing.expectEqual(@as(?t.Window, null), try openPopup(&h));
    try expectLinks(node, "Read the [docs](https://parcel.app) today");

    // Clearing the URL removes the link, and so does Remove; undo brings
    // it back.
    try press(&h, 'k', .{ .ctrl = true });
    popup = (try openPopup(&h)) orelse return error.NoPopup;
    try pressIn(&h, popup, ks.backspace, .{});
    try pressIn(&h, popup, ks.@"return", .{});
    try expectLinks(node, "Read the docs today");
    try press(&h, 'z', .{ .ctrl = true });
    try expectLinks(node, "Read the [docs](https://parcel.app) today");
    try press(&h, 'k', .{ .ctrl = true });
    popup = (try openPopup(&h)) orelse return error.NoPopup;
    try pressIn(&h, popup, ks.tab, .{});
    try pressIn(&h, popup, ks.@"return", .{});
    try expectLinks(node, "Read the docs today");
    try testing.expect(!(try state(node)).marks.link);

    // With nothing selected off a link: a URL and the text to show; what
    // is typed after it is not linked.
    try press(&h, ks.end, .{});
    try typeText(&h, " at ");
    try press(&h, 'k', .{ .ctrl = true });
    popup = (try openPopup(&h)) orelse return error.NoPopup;
    try typeTextIn(&h, popup, "https://siv.dev");
    try pressIn(&h, popup, ks.tab, .{});
    try typeTextIn(&h, popup, "siv");
    try pressIn(&h, popup, ks.@"return", .{});
    try typeText(&h, "!");
    try expectLinks(node, "Read the docs today at [siv](https://siv.dev)!");
    // An empty text shows the URL itself.
    try press(&h, 'k', .{ .ctrl = true });
    popup = (try openPopup(&h)) orelse return error.NoPopup;
    try typeTextIn(&h, popup, "a.example");
    try pressIn(&h, popup, ks.@"return", .{});
    try expectLinks(node, "Read the docs today at [siv](https://siv.dev)![a.example](https://a.example)");

    // A click on a link places the caret in it and opens nothing.
    const changes = log.changes;
    log.command_len = 0;
    var r: t.Rect = .{};
    try ok(c.siv_node_get_caret_rect(editorOf(node), 25, &r));
    try h.click(r.x + 1, r.y + r.height / 2);
    try h.settle();
    var caret: u32 = 0;
    var anchor: u32 = 0;
    try ok(c.siv_rich_text_get_selection(node, &caret, &anchor));
    try testing.expectEqual(caret, anchor);
    try testing.expect(caret >= 23 and caret <= 26);
    try testing.expectEqualStrings("https://siv.dev", (try linkAtCaret(node, &buf))[0]);
    try testing.expectEqual(changes, log.changes);
    try testing.expectEqual(@as(usize, 0), log.command_len);
    try testing.expectEqual(@as(?t.Window, null), try openPopup(&h));
}

test "rich text: typed and pasted URLs become links" {
    var h: Harness = .{};
    try h.start(480, 320, null, null);
    defer h.stop();
    var log: Log = .{};
    const node = try build(&h, .{}, &log);

    // A URL and a space: linked without the punctuation after it; the
    // link is an undo step of its own.
    try typeText(&h, "See https://siv.dev/docs. ");
    try expectLinks(node, "See [https://siv.dev/docs](https://siv.dev/docs). ");
    try press(&h, 'z', .{ .ctrl = true });
    try expectLinks(node, "See https://siv.dev/docs. ");
    try press(&h, 'z', .{ .ctrl = true, .shift = true });
    // Brackets around it, www. without a scheme, Enter after it; words
    // that are not URLs stay text.
    try typeText(&h, "(https://a.example/x_(y)) and www.example.org\nmailto:me@example.com not.a.url ");
    try expectLinks(node, "See [https://siv.dev/docs](https://siv.dev/docs). ([https://a.example/x_(y)](https://a.example/x_(y))) and [www.example.org](https://www.example.org) | [mailto:me@example.com](mailto:me@example.com) not.a.url ");

    // A URL pasted over a selection links it instead of replacing it,
    // and undo takes the link back.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_rich_text_set_document(txn, node, "", 0);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try typeText(&h, "Docs are here.");
    try selectChars(&h, 9, 4);
    try ok(c.siv_clipboard_write(h.window, .clipboard, "https://siv.dev/docs", 20));
    try h.settle();
    try press(&h, 'v', .{ .ctrl = true });
    try h.settle();
    try expectLinks(node, "Docs are [here](https://siv.dev/docs).");
    try press(&h, 'z', .{ .ctrl = true });
    try expectLinks(node, "Docs are here.");
    // Other text pasted over it replaces it, as ever.
    try selectChars(&h, 9, 4);
    try ok(c.siv_clipboard_write(h.window, .clipboard, "not a URL", 9));
    try h.settle();
    try press(&h, 'v', .{ .ctrl = true });
    try h.settle();
    try expectLinks(node, "Docs are not a URL.");
}

test "rich text: links through the API, round-tripping markDefs" {
    var h: Harness = .{};
    try h.start(520, 400, null, null);
    defer h.stop();
    var log: Log = .{};
    const node = try build(&h, .{ .document = sample, .document_len = sample.len }, &log);
    var buf: [128]u8 = undefined;

    // A link read from the document ("EmDash" is 25..31): an offset in
    // it unlinks it whole, and undo links it again.
    try ok(c.siv_rich_text_set_link_range(node, 28, 28, "", 0));
    var got = try links(node);
    try testing.expect(std.mem.startsWith(u8, got, "Release notes | Written in EmDash, with"));
    testing.allocator.free(got);
    try press(&h, 'z', .{ .ctrl = true });
    // Its href changes and its key and other fields stay.
    try ok(c.siv_rich_text_set_link_range(node, 28, 28, "https://emdashcms.com/docs", 26));
    {
        const json = try document(node);
        defer testing.allocator.free(json);
        const parsed = try std.json.parseFromSlice(Value, testing.allocator, json, .{});
        defer parsed.deinit();
        const def = get(parsed.value.array.items[1], "markDefs").array.items[0];
        try testing.expectEqualStrings("ln", get(def, "_key").string);
        try testing.expectEqualStrings("https://emdashcms.com/docs", get(def, "href").string);
        try testing.expect(get(def, "blank").bool);
        const span = get(parsed.value.array.items[1], "children").array.items[1];
        try testing.expectEqualStrings("EmDash", get(span, "text").string);
        try testing.expectEqualStrings("ln", get(span, "marks").array.items[0].string);
    }
    // A range across marks and two blocks; an empty href removes links.
    try ok(c.siv_rich_text_set_link_range(node, 42, 14, "https://example.com", 19));
    got = try links(node);
    try testing.expect(std.mem.startsWith(u8, got, "Release notes | [Written in EmDash, with ](https://example.com)[bold](https://example.com), italic"));
    testing.allocator.free(got);
    try ok(c.siv_rich_text_set_link_range(node, 0, 60, "", 0));
    got = try links(node);
    try testing.expect(std.mem.startsWith(u8, got, "Release notes | Written in EmDash, with bold, italic, and code. | Changes"));
    testing.allocator.free(got);
    try press(&h, 'z', .{ .ctrl = true });
    try press(&h, 'z', .{ .ctrl = true });
    got = try links(node);
    try testing.expect(std.mem.startsWith(u8, got, "Release notes | Written in [EmDash](https://emdashcms.com/docs), with"));
    testing.allocator.free(got);

    // The selection: link it, or at a caret off a link insert the URL as
    // linked text; reading the link and the selection back.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_rich_text_set_document(txn, node, "", 0);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try typeText(&h, "Mail me ");
    try ok(c.siv_rich_text_set_link(node, "mailto:me@example.com", 21));
    try expectLinks(node, "Mail me [mailto:me@example.com](mailto:me@example.com)");
    var caret: u32 = 0;
    var anchor: u32 = 0;
    try ok(c.siv_rich_text_get_selection(node, &caret, &anchor));
    try testing.expectEqual(@as(u32, 29), caret);
    try testing.expectEqual(caret, anchor);
    const at = try linkAtCaret(node, &buf);
    try testing.expectEqualStrings("mailto:me@example.com", at[0]);
    try testing.expectEqual(@as(u32, 8), at[1]);
    try testing.expectEqual(@as(u32, 29), at[2]);
    try selectChars(&h, 0, 4);
    try ok(c.siv_rich_text_set_link(node, "https://example.com", 19));
    try expectLinks(node, "[Mail](https://example.com) me [mailto:me@example.com](mailto:me@example.com)");
    try ok(c.siv_rich_text_set_link(node, "", 0));
    try expectLinks(node, "Mail me [mailto:me@example.com](mailto:me@example.com)");
    try press(&h, ks.home, .{});
    try testing.expectEqual(@as(usize, 0), (try linkAtCaret(node, &buf))[0].len);
    try testing.expect(log.changes > 0);

    // Errors: offsets past the end, inside a transaction, a schema
    // without links.
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_rich_text_set_link_range(node, 0, 999, "x", 1));
    try ok(c.siv_txn_begin(h.window, &txn));
    try testing.expectEqual(t.Result.error_busy, c.siv_rich_text_set_link(node, "x", 1));
    try ok(c.siv_txn_commit(txn));
    try ok(c.siv_txn_begin(h.window, &txn));
    const plain = c.siv_rich_text(txn, c.siv_window_get_root(h.window), &.{ .schema = .custom, .marks = .{ .strong = true } });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(t.Result.error_unsupported, c.siv_rich_text_set_link(plain, "x", 1));
    try testing.expectEqual(t.Result.error_unsupported, c.siv_rich_text_run(plain, .link));
}

test "rich text: links with Vim's keys" {
    var h: Harness = .{};
    try h.start(480, 300, null, null);
    defer h.stop();
    var log: Log = .{};
    const node = try build(&h, .{ .flags = .{ .vim = true } }, &log);
    try typeText(&h, "ivisit the site now");
    try press(&h, ks.escape, .{});

    // :link URL links the word under the cursor; on a link it changes
    // the link; :unlink removes it.
    try typeText(&h, "0w");
    try typeText(&h, ":link example.com");
    try press(&h, ks.@"return", .{});
    try expectLinks(node, "visit [the](https://example.com) site now");
    try typeText(&h, ":link https://siv.dev");
    try press(&h, ks.@"return", .{});
    try expectLinks(node, "visit [the](https://siv.dev) site now");
    try typeText(&h, ":unlink");
    try press(&h, ks.@"return", .{});
    try expectLinks(node, "visit the site now");
    try testing.expectEqual(@as(usize, 0), log.command_len);

    // On the visual selection.
    try typeText(&h, "wve:link https://a.example");
    try press(&h, ks.@"return", .{});
    try expectLinks(node, "visit the [site](https://a.example) now");
    try testing.expectEqual(t.RichTextMode.normal, (try state(node)).mode);

    // Ctrl+K in normal mode edits the link under the cursor.
    try press(&h, 'k', .{ .ctrl = true });
    const popup = (try openPopup(&h)) orelse return error.NoPopup;
    try typeTextIn(&h, popup, "b.example");
    try pressIn(&h, popup, ks.@"return", .{});
    try expectLinks(node, "visit the [site](https://b.example) now");
    try testing.expectEqual(t.RichTextMode.normal, (try state(node)).mode);
    // In insert mode, a URL typed before a space links; u undoes the
    // insert with it.
    try typeText(&h, "A see www.siv.dev ");
    try press(&h, ks.escape, .{});
    try expectLinks(node, "visit the [site](https://b.example) now see [www.siv.dev](https://www.siv.dev) ");
    try typeText(&h, "u");
    try expectLinks(node, "visit the [site](https://b.example) now");
}
