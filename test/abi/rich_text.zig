//! Rich text through the C ABI (D13, D22): a font family per span,
//! paragraph styles (alignment, indents, line and paragraph spacing, tab
//! stops), breaking inside overlong words, and the styled-text editor's
//! paragraph commands, on the headless backend against
//! test/golden/abi/rich-text.png.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const text = @import("text");
const ui = @import("ui");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const Harness = harness.Harness;
const ok = harness.ok;

fn label(txn: t.Txn, parent: t.Node, s: []const u8) t.Node {
    return c.siv_text(txn, parent, s.ptr, s.len);
}

test "rich text: families per span, paragraph styles, tab stops, and broken words" {
    var h: Harness = .{};
    try h.start(360, 330, null, null);
    defer h.stop();
    const vf = text.font.test_fonts.siv_variable;
    try ok(c.siv_app_add_font(h.app, "", 0, vf.ptr, vf.len));
    var family: u32 = 0;
    try ok(c.siv_app_font_family(h.app, "SivTest VF", 10, &family));
    var again: u32 = 0;
    try ok(c.siv_app_font_family(h.app, "SivTest VF", 10, &again));
    try testing.expectEqual(family, again);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_app_get_font_family_name(h.app, family, &buf, buf.len, &len));
    try testing.expectEqualStrings("SivTest VF", buf[0..len]);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_get_font_family_name(h.app, 100000, &buf, buf.len, &len));

    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .gap = 10 });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 10, .end = 10, .top = 10, .bottom = 10 } });

    // A family and width per span: "HIO" in the variable test font,
    // condensed.
    const mixed = label(txn, col, "Droid and HIO HIO");
    const spans = [_]t.TextSpan{
        .{ .start = 10, .end = 13, .flags = .{ .family = true }, .family = family },
        .{ .start = 14, .end = 17, .flags = .{ .family = true, .width = true }, .family = family, .width = .condensed },
    };
    _ = c.siv_set_text_spans(txn, mixed, &.{ .spans = &spans, .spans_count = spans.len });

    // Three paragraphs: centered; indented with a hanging first line and
    // one and a half line spacing; right-aligned after 8 px of space.
    const doc = label(txn, col, "A centered heading\nAn indented paragraph whose first line hangs out and whose lines are spaced apart.\nFlush right");
    _ = c.siv_set_layout(txn, doc, &.{ .width = .{ .unit = .px, .value = 340 } });
    const paras = [_]t.ParagraphSpan{
        .{ .start = 0, .end = 1, .flags = .{ .@"align" = true }, .@"align" = .center },
        .{ .start = 19, .end = 20, .flags = .{ .indent = true, .line_spacing = true }, .indent_start = 40, .indent_end = 20, .first_line_indent = -24, .line_spacing = 1.5 },
        .{ .start = 102, .end = 103, .flags = .{ .@"align" = true, .paragraph_spacing = true }, .@"align" = .end, .space_before = 8 },
    };
    _ = c.siv_set_paragraph_spans(txn, doc, &.{ .spans = &paras, .spans_count = paras.len });

    // Tab stops line columns up across lines.
    const stops = [_]t.TabStop{ .{ .position = 90 }, .{ .position = 170 } };
    const table = label(txn, col, "Name\tSize\tKind\nsiv.h\t12 KB\tHeader\nlibsiv.so\t2 MB\tLibrary");
    _ = c.siv_set_text_style(txn, table, &.{ .tab_stops = &stops, .tab_stops_count = stops.len });

    // A word too wide for its box breaks between characters.
    const narrow = label(txn, col, "Pneumonoultramicroscopic");
    _ = c.siv_set_layout(txn, narrow, &.{ .width = .{ .unit = .px, .value = 90 } });
    _ = c.siv_set_text_style(txn, narrow, &.{ .flags = .{ .break_words = true } });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.expectGolden("rich-text", 360, 330);

    // Runs and paragraphs read back.
    var run: t.TextSpan = undefined;
    try ok(c.siv_node_get_text_run(mixed, 15, &run));
    try testing.expect(run.flags.family and run.flags.width and run.family == family and run.width == .condensed);
    try testing.expectEqual([2]u32{ 14, 17 }, [2]u32{ run.start, run.end });
    var para: t.ParagraphSpan = undefined;
    try ok(c.siv_node_get_paragraph(doc, 30, &para));
    try testing.expectEqual([2]u32{ 19, 102 }, [2]u32{ para.start, para.end });
    try testing.expect(para.flags.indent and para.flags.line_spacing and !para.flags.@"align");
    try testing.expectEqual(@as(f32, -24), para.first_line_indent);
    try testing.expectEqual(@as(f32, 1.5), para.line_spacing);
    try ok(c.siv_node_get_paragraph(doc, 102, &para));
    try testing.expectEqual([2]u32{ 102, 113 }, [2]u32{ para.start, para.end });
    try testing.expect(para.flags.@"align" and para.@"align" == .end and para.space_before == 8);
    try ok(c.siv_node_get_paragraph(table, 3, &para));
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(para.flags)));

    // Invalid spans fail the transaction.
    try ok(c.siv_txn_begin(h.window, &txn));
    const negative = [_]t.ParagraphSpan{.{ .start = 0, .end = 1, .flags = .{ .indent = true }, .indent_start = -1 }};
    _ = c.siv_set_paragraph_spans(txn, doc, &.{ .spans = &negative, .spans_count = 1 });
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
    try ok(c.siv_txn_begin(h.window, &txn));
    const unsorted = [_]t.TabStop{ .{ .position = 50 }, .{ .position = 20 } };
    _ = c.siv_set_text_style(txn, table, &.{ .tab_stops = &unsorted, .tab_stops_count = 2 });
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
    try ok(c.siv_txn_begin(h.window, &txn));
    const bad_family = [_]t.TextSpan{.{ .start = 0, .end = 1, .flags = .{ .family = true }, .family = 100000 }};
    _ = c.siv_set_text_spans(txn, mixed, &.{ .spans = &bad_family, .spans_count = 1 });
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));

    // Measured text takes the paragraph defaults: double spacing doubles
    // the height of two lines.
    var single: t.TextMetrics = undefined;
    var double: t.TextMetrics = undefined;
    try ok(c.siv_app_measure_text(h.app, "a\nb", 3, 0, &.{ .font_size = 20 }, &single));
    try ok(c.siv_app_measure_text(h.app, "a\nb", 3, 0, &.{ .font_size = 20, .line_spacing = 2 }, &double));
    try testing.expectApproxEqAbs(2 * single.height, double.height, 0.01);
    var tabbed: t.TextMetrics = undefined;
    const stop = [_]t.TabStop{.{ .position = 200 }};
    try ok(c.siv_app_measure_text(h.app, "a\tb", 3, 0, &.{ .font_size = 20, .tab_stops = &stop, .tab_stops_count = 1 }, &tabbed));
    try testing.expect(tabbed.width > 200 and tabbed.width < 220);
}

test "styled-text editors align paragraphs by keys, undoably" {
    var h: Harness = .{};
    try h.start(300, 120, null, null);
    defer h.stop();
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const content = "One\nTwo\nThree";
    const field = c.siv_text_field(txn, c.siv_window_root(h.window), &.{ .text = content, .text_len = content.len, .flags = .{ .multiline = true, .styled = true }, .rows = 3 });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try ok(c.siv_node_focus(field));
    // The caret in "Two": Ctrl+E centers that paragraph only.
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_set_selection(txn, field, 5, 5));
    try ok(c.siv_txn_commit(txn));
    try h.typeKey('e', "", .{ .ctrl = true });
    try h.settle();
    var para: t.ParagraphSpan = undefined;
    try ok(c.siv_node_get_paragraph(field, 5, &para));
    try testing.expect(para.flags.@"align" and para.@"align" == .center);
    try testing.expectEqual([2]u32{ 4, 8 }, [2]u32{ para.start, para.end });
    try ok(c.siv_node_get_paragraph(field, 0, &para));
    try testing.expect(!para.flags.@"align");
    // Ctrl+R over a selection from "One" into "Three" aligns all three
    // right; Ctrl+L puts them back; undo restores right.
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_set_selection(txn, field, 1, 10));
    try ok(c.siv_txn_commit(txn));
    try h.typeKey('r', "", .{ .ctrl = true });
    try h.settle();
    for ([_]u32{ 0, 5, 10 }) |o| {
        try ok(c.siv_node_get_paragraph(field, o, &para));
        try testing.expect(para.flags.@"align" and para.@"align" == .end);
    }
    try h.typeKey('l', "", .{ .ctrl = true });
    try h.settle();
    try ok(c.siv_node_get_paragraph(field, 5, &para));
    try testing.expect(!para.flags.@"align");
    try h.typeKey('z', "", .{ .ctrl = true });
    try h.settle();
    try ok(c.siv_node_get_paragraph(field, 5, &para));
    try testing.expect(para.@"align" == .end);
    // The editor command from C does the same.
    try ok(c.siv_editor_format_paragraph(field, .{ .flags = .{ .indent = true }, .indent_start = 12 }, .{ .indent = true }));
    try ok(c.siv_node_get_paragraph(field, 5, &para));
    try testing.expect(para.flags.indent and para.indent_start == 12 and para.@"align" == .end);
}

test "typesetting: justified, hyphenated, total-fit paragraphs and aligned tab stops" {
    var h: Harness = .{};
    try h.start(360, 300, null, null);
    defer h.stop();
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .gap = 12 });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 10, .end = 10, .top = 10, .bottom = 10 } });
    const prose = "Hyphenation and justification typeset paragraphs evenly: the total-fit breaker considers every opportunity, including hyphenation points, before choosing lines.";
    const doc = label(txn, col, prose);
    _ = c.siv_set_layout(txn, doc, &.{ .width = .{ .unit = .px, .value = 220 } });
    _ = c.siv_set_text_style(txn, doc, &.{ .language = "en-US", .language_len = 5, .@"align" = .justify, .flags = .{ .hyphenate = true, .optimal_breaks = true } });
    const stops = [_]t.TabStop{ .{ .position = 120, .@"align" = .center }, .{ .position = 220, .@"align" = .decimal }, .{ .position = 330, .@"align" = .end } };
    const table = label(txn, col, "Item\tQty\tPrice\tNote\nPaper\t12\t3.50\tA4\nInk\t2\t24.99\tblack");
    _ = c.siv_set_text_style(txn, table, &.{ .tab_stops = &stops, .tab_stops_count = stops.len });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.expectGolden("typesetting", 360, 300);

    // Justified lines but the last fill the width; some line ends with a
    // hyphen, so it ends inside a word.
    const uw, const id = try uiOf(doc);
    const l = ui.text_node.current(uw, id).?;
    try testing.expect(l.lines.len >= 4);
    var hyphenated = false;
    for (l.lines[0 .. l.lines.len - 1]) |line| {
        try testing.expectApproxEqAbs(@as(f32, 220), line.width, 0.01);
        const prev = prose[line.end - 1];
        if (std.ascii.isAlphabetic(prev) and std.ascii.isAlphabetic(prose[line.end])) hyphenated = true;
    }
    try testing.expect(hyphenated);
    try testing.expect(l.lines[l.lines.len - 1].width < 219);

    // An application's patterns for a language without built-in ones.
    try ok(c.siv_app_add_hyphenation(h.app, &.{ .language = "x-test", .language_len = 6, .patterns = "a1b", .patterns_len = 3, .left_min = 1, .right_min = 1 }));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_add_hyphenation(h.app, &.{ .language = "x-bad", .language_len = 5, .patterns = "1", .patterns_len = 1 }));
    var m: t.TextMetrics = undefined;
    var whole: t.TextMetrics = undefined;
    try ok(c.siv_app_measure_text(h.app, "abababab", 8, 0, &.{ .language = "x-test", .language_len = 6, .font_size = 20 }, &whole));
    try ok(c.siv_app_measure_text(h.app, "abababab", 8, whole.width / 2, &.{ .language = "x-test", .language_len = 6, .font_size = 20, .flags = .{ .hyphenate = true } }, &m));
    try testing.expect(m.height > 1.5 * whole.height);
    try testing.expect(m.width <= whole.width / 2 + 0.01);
    // Without hyphenation the word stays on one line.
    try ok(c.siv_app_measure_text(h.app, "abababab", 8, whole.width / 2, &.{ .language = "x-test", .language_len = 6, .font_size = 20 }, &m));
    try testing.expectApproxEqAbs(whole.height, m.height, 0.01);
    // Tab stops must increase.
    try ok(c.siv_txn_begin(h.window, &txn));
    const bad = [_]t.TabStop{ .{ .position = 50 }, .{ .position = 50 } };
    _ = c.siv_set_text_style(txn, table, &.{ .tab_stops = &bad, .tab_stops_count = 2 });
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
}

fn uiOf(n: t.Node) !struct { *ui.Window, ui.NodeId } {
    const w, const id = try abi.tree.lookup(n);
    return .{ w.uiWin(), id };
}
