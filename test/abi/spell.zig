//! Spell checking through the C ABI (D37): the application's checks,
//! suggestions, and word lists, and spell-checked editors with their
//! wavy underlines (test/golden/abi/spell.png) and context menu. The
//! headless backend has no system dictionaries; the tests add spell's
//! test dictionary.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const ui = @import("ui");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const A = abi.application;
const Harness = harness.Harness;
const ok = harness.ok;

fn addDictionary(h: *Harness) !void {
    const d = ui.Spelling.test_dictionary;
    try ok(c.siv_app_add_dictionary(h.app, "en_ZZ", 5, d.aff.ptr, d.aff.len, d.dic.ptr, d.dic.len));
}

fn check(h: *Harness, language: []const u8, word: []const u8) !bool {
    var correct = false;
    try ok(c.siv_app_check_spelling(h.app, language.ptr, language.len, word.ptr, word.len, &correct));
    return correct;
}

fn openPopup(h: *Harness) !?t.Window {
    const self = try h.internal();
    var found: ?t.Window = null;
    for (self.windows.items) |slot| if (slot) |w| {
        if (!w.dead and w.parent != null and w.win.shown) found = @fromBackingInt(w.handle);
    };
    return found;
}

const Find = struct { found: bool, start: u32, end: u32 };

fn find(node: t.Node, offset: u32, how: t.SpellFind) !Find {
    var f: Find = undefined;
    try ok(c.siv_node_find_misspelling(node, offset, how, &f.found, &f.start, &f.end));
    return f;
}

fn textOf(node: t.Node, buf: []u8) ![]const u8 {
    var len: usize = 0;
    try ok(c.siv_node_get_text(node, buf.ptr, buf.len, &len));
    return buf[0..len];
}

test "spelling: the application's checks, suggestions, and word lists" {
    var h: Harness = .{};
    try h.start(100, 100, null, null);
    defer h.stop();
    var correct = false;
    // The headless backend has none until the application adds one.
    try testing.expectEqual(t.Result.error_unavailable, c.siv_app_check_spelling(h.app, "", 0, "word", 4, &correct));
    try addDictionary(&h);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_add_dictionary(h.app, "xx", 2, "SET NOPE\n", 9, "1\nword\n", 7));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_add_dictionary(h.app, "", 0, "", 0, "", 0));
    // The application's language (none here: English), a tag, or the
    // dictionary's name pick it.
    try testing.expect(!try check(&h, "", "quikc"));
    try testing.expect(try check(&h, "en-US", "quick"));
    try testing.expect(try check(&h, "en_ZZ", "Jumped"));
    try testing.expectEqual(t.Result.error_unavailable, c.siv_app_check_spelling(h.app, "de", 2, "Wort", 4, &correct));

    var buf: [256]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_app_suggest_spelling(h.app, "", 0, "quikc", 5, null, 0, &len));
    try testing.expect(len > 0);
    try ok(c.siv_app_suggest_spelling(h.app, "", 0, "quikc", 5, &buf, buf.len, &len));
    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    try testing.expectEqualStrings("quick", lines.first());
    // A replacement table's: "fone" is "phone".
    try ok(c.siv_app_suggest_spelling(h.app, "", 0, "fone", 4, &buf, buf.len, &len));
    lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    try testing.expectEqualStrings("phone", lines.first());

    try ok(c.siv_app_add_spelling_word(h.app, "", 0, "siv", 3));
    try testing.expect(try check(&h, "", "siv") and try check(&h, "", "Siv"));
    try ok(c.siv_app_ignore_spelling_word(h.app, "en", 2, "zig", 3));
    try testing.expect(try check(&h, "", "zig"));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_add_spelling_word(h.app, "", 0, "", 0));

    try ok(c.siv_app_get_dictionaries(h.app, &buf, buf.len, &len));
    try testing.expectEqualStrings("en_ZZ", buf[0..len]);
}

test "spelling: editors mark misspelled words; a context menu corrects them" {
    var h: Harness = .{};
    try h.start(320, 170, null, null);
    defer h.stop();
    try addDictionary(&h);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .gap = 10 });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 10, .end = 10, .top = 10, .bottom = 10 } });
    const area_text = "The quikc brown fox jumpz over teh lazy dog.";
    const area = c.siv_text_field(txn, col, &.{ .text = area_text, .text_len = area_text.len, .flags = .{ .multiline = true }, .rows = 2 });
    // Single-line fields are not checked unless asked.
    const line = c.siv_text_field(txn, col, &.{ .text = "Single quikc line", .text_len = 17 });
    // The editor primitive opts in, with a language of its own.
    const ed = c.siv_editor(txn, col, .{});
    _ = c.siv_set_text(txn, ed, "An editr checks text", 20);
    _ = c.siv_set_spell_check(txn, ed, true, "en-GB", 5);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.expectGolden("spell", 320, 170);

    try testing.expectEqual(Find{ .found = true, .start = 4, .end = 9 }, try find(area, 6, .at));
    try testing.expectEqual(Find{ .found = true, .start = 20, .end = 25 }, try find(area, 9, .next));
    try testing.expectEqual(Find{ .found = true, .start = 20, .end = 25 }, try find(area, 31, .previous));
    try testing.expectEqual(Find{ .found = false, .start = 0, .end = 0 }, try find(area, 2, .at));
    try testing.expect(!(try find(line, 9, .at)).found);
    try testing.expectEqual(Find{ .found = true, .start = 3, .end = 8 }, try find(ed, 3, .at));
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_node_get_spell_language(area, &buf, buf.len, &len));
    try testing.expectEqualStrings("en_ZZ", buf[0..len]);
    try ok(c.siv_node_get_spell_language(line, &buf, buf.len, &len));
    try testing.expectEqual(@as(usize, 0), len);

    // A secondary click on "quikc" opens its menu, on the first
    // suggestion; Enter replaces the word, as one undo step.
    var box: t.Rect = undefined;
    var caret: t.Rect = undefined;
    try ok(c.siv_node_get_rect(area, &box));
    try ok(c.siv_node_get_caret_rect(area, 6, &caret));
    const wid = (try h.win()).win.id;
    const x = box.x + caret.x;
    const y = box.y + caret.y + caret.height / 2;
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = wid, .seat = 0, .x = x, .y = y } },
        .{ .pointer_button = .{ .window = wid, .seat = 0, .button = 0x111, .pressed = true, .time = 0, .serial = 1 } },
        .{ .pointer_button = .{ .window = wid, .seat = 0, .button = 0x111, .pressed = false, .time = 0, .serial = 2 } },
    });
    try h.settle();
    var popup = (try openPopup(&h)).?;
    const pw = try A.App.window(@backingInt(popup), A.window_tag);
    const tree = try pw.uiWin().semanticsTree();
    try testing.expectEqualStrings("quick", tree.name(tree.focused().?.*));
    try testing.expect(tree.find(.menu_item, "Add to Dictionary") != null);
    try testing.expect(tree.find(.menu_item, "Ignore") != null);
    try h.typeKeyIn(popup, 0xff0d, "", .{});
    try h.settle();
    try testing.expectEqual(null, try openPopup(&h));
    try testing.expectEqualStrings("The quick brown fox jumpz over teh lazy dog.", try textOf(area, &buf));
    try testing.expectEqual(Find{ .found = true, .start = 20, .end = 25 }, try find(area, 0, .next));

    // The Menu key with the caret in "jumpz": Ignore, the last item.
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_set_selection(txn, area, 22, 22);
    try ok(c.siv_txn_commit(txn));
    try ok(c.siv_node_focus(area));
    try h.settle();
    try h.typeKey(0xff67, "", .{});
    try h.settle();
    popup = (try openPopup(&h)).?;
    try h.typeKeyIn(popup, 0xff57, "", .{});
    try h.typeKeyIn(popup, 0xff0d, "", .{});
    try h.settle();
    try testing.expectEqual(Find{ .found = true, .start = 31, .end = 34 }, try find(area, 0, .next));
    try testing.expect(try check(&h, "", "jumpz"));

    // Shift+F10 in "teh": Add to Dictionary, above Ignore. Ctrl+Z then
    // undoes the earlier correction.
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_set_selection(txn, area, 32, 32);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.typeKey(0xffc7, "", .{ .shift = true });
    try h.settle();
    popup = (try openPopup(&h)).?;
    try h.typeKeyIn(popup, 0xff57, "", .{});
    try h.typeKeyIn(popup, 0xff52, "", .{});
    try h.typeKeyIn(popup, 0xff0d, "", .{});
    try h.settle();
    try testing.expect(!(try find(area, 0, .next)).found);
    try testing.expect(try check(&h, "en", "teh"));
    try h.typeKey('z', "", .{ .ctrl = true });
    try h.settle();
    try testing.expectEqualStrings(area_text, try textOf(area, &buf));
    try testing.expectEqual(Find{ .found = true, .start = 4, .end = 9 }, try find(area, 0, .next));
}
