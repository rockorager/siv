//! Text fields and areas: the editor primitive (D15) framed in themed
//! colors, with its placeholder. The builder returns the editor itself,
//! so the application uses editor functions and `change` events on it
//! directly. The border takes the accent while the field has focus.
//!
//! Text areas and styled-text editors are spell checked (D37): a
//! secondary click on a misspelled word, or the Menu key or Shift+F10
//! with the caret in one, opens a menu of suggestions, Add to Dictionary,
//! and Ignore.

const std = @import("std");
const w = @import("widgets.zig");
const button = @import("button.zig");
const menu = @import("menu.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Field = extern struct {
    hdr: w.Header,
    focused: bool = false,
    multiline: bool = false,
    rows: u32 = 3,
    styled: bool = false,
    root: Node,
};

pub export fn siv_text_field(txn: Txn, parent: Node, desc: ?*const siv.TextFieldDesc) Node {
    const d = w.readDesc(siv.TextFieldDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 15) != 0) return w.fail(txn, .error_unsupported);
    if (d.flags.styled and d.flags.masked) return w.fail(txn, .error_invalid_argument);
    const text = w.str(d.text, d.text_len) orelse return w.fail(txn, .error_invalid_argument);
    const placeholder = w.str(d.placeholder, d.placeholder_len) orelse return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_editor(txn, parent, .{ .multiline = d.flags.multiline, .masked = d.flags.masked });
    if (root == .null) return .null;
    _ = c.siv_set_text(txn, root, text.ptr, text.len);
    _ = c.siv_set_placeholder(txn, root, placeholder.ptr, placeholder.len);
    const st = w.create(Field, txn, root) orelse return .null;
    st.* = .{
        .hdr = .{ .kind = .text_field, .disabled = d.flags.disabled },
        .multiline = d.flags.multiline,
        .rows = if (d.rows == 0) 3 else @min(d.rows, 1000),
        .styled = d.flags.styled,
        .root = root,
    };
    if ((d.flags.multiline or d.flags.styled) and !d.flags.masked) _ = c.siv_set_spell_check(txn, root, true, null, 0);
    const name = if (label.len != 0) label else placeholder;
    _ = c.siv_set_semantics(txn, root, &.{ .label = name.ptr, .label_len = name.len });
    w.onDefault(txn, root, .pointer, onPointer, st);
    w.onDefault(txn, root, .focus, onFocus, st);
    w.onDefault(txn, root, .key, onKey, st);
    w.setInterface(txn, root, Field, st, .{ .set_label = setLabel, .apply = apply });
    apply(txn, st);
    return root;
}

fn onKey(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Field = @ptrCast(@alignCast(ud.?));
    const e = ev;
    if (!st.hdr.disabled and e.flags.pressed and (e.keysym == w.keysym.menu or (e.keysym == w.keysym.f10 and e.modifiers.shift and !e.modifiers.ctrl and !e.modifiers.alt))) {
        var caret: u32 = 0;
        var anchor: u32 = 0;
        if (c.siv_node_get_selection(node, &caret, &anchor) == .ok) {
            var rect: siv.Rect = .{};
            _ = c.siv_node_get_caret_rect(node, caret, &rect);
            if (openSpellMenu(node, caret, rect.x, rect.y + rect.height)) return .handled;
        }
    }
    return if (st.styled) onStyleKey(ud, node, ev) else .pass;
}

/// Styled-text editors (D22): Ctrl+B, Ctrl+I, and Ctrl+U toggle bold,
/// italic, and underline. An attribute turns off when all of the
/// selection has it (or, with nothing selected, the typing style), else
/// on, as word processors do. Ctrl+L, Ctrl+E, Ctrl+R, and Ctrl+J align
/// the selected paragraphs left, centered, right, and justified (D13);
/// left in a left-to-right editor and right in a right-to-left one go
/// back to the editor's own alignment.
fn onStyleKey(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Field = @ptrCast(@alignCast(ud.?));
    const e = ev;
    if (st.hdr.disabled or !e.flags.pressed or !e.modifiers.ctrl or e.modifiers.alt or e.modifiers.super) return .pass;
    // Through the key's Latin equivalent on any layout (D44).
    const key: u32 = @bitCast(@intFromEnum(e.shortcut_key));
    switch (key) {
        'l', 'L', 'e', 'E', 'r', 'R', 'j', 'J' => {
            var rtl = false;
            _ = c.siv_node_is_rtl(node, &rtl);
            const left: siv.TextAlign = if (rtl) .end else .start;
            const right: siv.TextAlign = if (rtl) .start else .end;
            const a: siv.TextAlign = switch (key) {
                'l', 'L' => left,
                'e', 'E' => .center,
                'j', 'J' => .justify,
                else => right,
            };
            _ = c.siv_editor_format_paragraph(node, .{ .flags = .{ .@"align" = a != .start }, .@"align" = a }, .{ .@"align" = true });
            return .handled;
        },
        else => {},
    }
    const Attr = enum { bold, italic, underline };
    const attr: Attr = switch (key) {
        'b', 'B' => .bold,
        'i', 'I' => .italic,
        'u', 'U' => .underline,
        else => return .pass,
    };
    const has = struct {
        fn f(a: Attr, s: siv.TextSpan) bool {
            return switch (a) {
                .bold => s.flags.weight and @intFromEnum(s.weight) >= @intFromEnum(siv.FontWeight.semibold),
                .italic => s.flags.slant and s.slant != .roman,
                .underline => s.flags.underline,
            };
        }
    }.f;
    var caret: u32 = 0;
    var anchor: u32 = 0;
    if (c.siv_node_get_selection(node, &caret, &anchor) != .ok) return .pass;
    const lo = @min(caret, anchor);
    const hi = @max(caret, anchor);
    var on = true;
    if (lo == hi) {
        var typing: siv.TextSpan = undefined;
        if (c.siv_node_get_typing_style(node, &typing) != .ok) return .pass;
        on = !has(attr, typing);
    } else {
        // Off only when every run of the selection has it.
        var at = lo;
        var all = true;
        while (at < hi) {
            var run: siv.TextSpan = undefined;
            if (c.siv_node_get_text_run(node, at, &run) != .ok) return .pass;
            all = all and has(attr, run);
            at = @max(run.end, at + 1);
        }
        on = !all;
    }
    const values: siv.TextSpan = switch (attr) {
        .bold => .{ .flags = .{ .weight = on }, .weight = .bold },
        .italic => .{ .flags = .{ .slant = on }, .slant = .italic },
        .underline => .{ .flags = .{ .underline = on } },
    };
    const mask: siv.TextSpanFlags = switch (attr) {
        .bold => .{ .weight = true },
        .italic => .{ .slant = true },
        .underline => .{ .underline = true },
    };
    _ = c.siv_editor_format(node, values, mask);
    return .handled;
}

pub fn apply(txn: Txn, st: *Field) void {
    const h = st.hdr;
    const min_h: f32 = if (st.multiline) @as(f32, @floatFromInt(st.rows)) * tk.line_height + 2 * tk.pad_y else tk.control_height;
    _ = c.siv_set_default_layout(txn, st.root, &.{
        .min_width = tk.field_min_width,
        .min_height = min_h,
        .padding = .{ .start = tk.field_pad_x, .end = tk.field_pad_x, .top = tk.pad_y + 1, .bottom = tk.pad_y + 1 },
    });
    const border: siv.ColorToken = if (h.disabled) .border else if (st.focused) .accent else .border;
    _ = c.siv_set_visual(txn, st.root, &.{
        .radius = .{ .top_start = tk.radius, .top_end = tk.radius, .bottom_end = tk.radius, .bottom_start = tk.radius },
        .border_width = if (st.focused and !h.disabled) 2 * tk.border else tk.border,
        .border_token = border,
        .background_token = if (h.disabled) .control_bg else .view_bg,
    });
    _ = c.siv_set_text_style(txn, st.root, &.{ .color_token = if (h.disabled) .disabled_fg else .view_fg, .size_role = .body });
    var buf: [1024]u8 = undefined;
    const label = w.labelOf(st.root, &buf);
    _ = c.siv_set_semantics(txn, st.root, &.{ .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = h.disabled } });
}

pub fn setLabel(txn: Txn, st: *Field, label: []const u8) void {
    _ = c.siv_set_semantics(txn, st.root, &.{ .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = st.hdr.disabled } });
}

fn onPointer(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Field = @ptrCast(@alignCast(ud.?));
    _ = button.feedback(&st.hdr, ev);
    if (!st.hdr.disabled and ev.phase == .down and ev.button == .secondary) {
        var offset: u32 = 0;
        if (c.siv_node_get_offset_at(node, ev.x, ev.y, &offset) == .ok and openSpellMenu(node, offset, ev.x, ev.y)) return .handled;
    }
    return .pass;
}

// Spelling ---------------------------------------------------------------------

/// The open spelling menu's state, in its menu node's data.
const SpellMenu = extern struct {
    editor: Node,
    start: u32,
    end: u32,
    suggestions: u32,
    word_len: u32,
    lang_len: u32,
    word: [256]u8,
    lang: [64]u8,
};

var spell_key: u8 = 0;

/// Opens the spelling menu of the misspelled word at `offset` of a
/// spell-checked editor, at (x, y) in it; false when there is no
/// misspelled word there.
fn openSpellMenu(node: Node, offset: u32, x: f32, y: f32) bool {
    var found = false;
    var start: u32 = 0;
    var end: u32 = 0;
    if (c.siv_node_find_misspelling(node, offset, .at, &found, &start, &end) != .ok or !found) return false;
    var sm: SpellMenu = .{ .editor = node, .start = start, .end = end, .suggestions = 0, .word_len = end - start, .lang_len = 0, .word = undefined, .lang = undefined };
    if (sm.word_len > sm.word.len) return false;
    var len: usize = 0;
    if (c.siv_node_get_text_range(node, start, &sm.word, sm.word_len, &len) != .ok) return false;
    if (c.siv_node_get_spell_language(node, &sm.lang, sm.lang.len, &len) != .ok or len == 0 or len > sm.lang.len) return false;
    sm.lang_len = @intCast(len);
    const window = w.windowOf(node);
    var buf: [2048]u8 = undefined;
    var n: usize = 0;
    if (c.siv_app_suggest_spelling(w.appOf(window), &sm.lang, sm.lang_len, &sm.word, sm.word_len, &buf, buf.len, &n) != .ok) n = 0;
    const txn = w.begin(window) orelse return false;
    const m = c.siv_menu(txn, c.siv_window_get_root(window), &.{ .label = "Spelling", .label_len = 8 });
    var it = std.mem.splitScalar(u8, buf[0..@min(n, buf.len)], '\n');
    while (it.next()) |s| {
        // A suggestion the buffer cut is left out.
        if (s.len == 0 or (it.index == null and n > buf.len)) continue;
        _ = c.siv_menu_item(txn, m, &.{ .label = s.ptr, .label_len = s.len });
        sm.suggestions += 1;
    }
    if (sm.suggestions == 0) _ = c.siv_menu_item(txn, m, &.{ .label = "(No Suggestions)", .label_len = 16, .flags = .{ .disabled = true } });
    _ = c.siv_menu_item(txn, m, &.{ .flags = .{ .separator = true } });
    _ = c.siv_menu_item(txn, m, &.{ .label = "Add to Dictionary", .label_len = 17 });
    _ = c.siv_menu_item(txn, m, &.{ .label = "Ignore", .label_len = 6 });
    var data: ?*anyopaque = null;
    if (c.siv_set_data(txn, m, &spell_key, @sizeOf(SpellMenu), &data) == .ok) {
        const p: *SpellMenu = @ptrCast(@alignCast(data.?));
        p.* = sm;
        _ = c.siv_on(txn, m, .select, onSpellSelect, null, p);
        _ = c.siv_on(txn, m, .close, onSpellClose, null, p);
    }
    if (!w.commit(txn)) return false;
    if (c.siv_menu_open_at(m, node, x, y) != .ok) {
        removeMenu(m);
        return false;
    }
    return true;
}

fn removeMenu(m: Node) void {
    const txn = w.begin(w.windowOf(m)) orelse return;
    _ = c.siv_remove(txn, m);
    _ = w.commit(txn);
}

fn onSpellSelect(ud: ?*anyopaque, m: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const sm: *SpellMenu = @ptrCast(@alignCast(ud.?));
    const index = ev.index;
    const word = sm.word[0..sm.word_len];
    const lang = sm.lang[0..sm.lang_len];
    const app = w.appOf(w.windowOf(sm.editor));
    const first_action = @max(sm.suggestions, 1) + 1;
    if (index < sm.suggestions) {
        // Still the word the menu was opened on.
        var now: [256]u8 = undefined;
        var len: usize = 0;
        const item = c.siv_menu_get_item(m, index);
        const label = if (w.stateOf(menu.Item, item, &.{.menu_item})) |it| it.label else .null;
        var buf: [256]u8 = undefined;
        const s = w.textOf(label, &buf);
        if (c.siv_node_get_text_range(sm.editor, sm.start, &now, sm.word_len, &len) == .ok and std.mem.eql(u8, now[0..@min(len -| sm.start, sm.word_len)], word) and s.len != 0)
            _ = c.siv_editor_replace(sm.editor, sm.start, sm.end, s.ptr, s.len);
    } else if (index == first_action) {
        _ = c.siv_app_add_spelling_word(app, lang.ptr, lang.len, word.ptr, word.len);
    } else if (index == first_action + 1) {
        _ = c.siv_app_ignore_spelling_word(app, lang.ptr, lang.len, word.ptr, word.len);
    }
    removeMenu(m);
    return .handled;
}

fn onSpellClose(_: ?*anyopaque, m: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    removeMenu(m);
    return .handled;
}

fn onFocus(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *Field = @ptrCast(@alignCast(ud.?));
    const e = ev;
    st.focused = e.flags.gained;
    const txn = w.begin(e.window) orelse return .pass;
    apply(txn, st);
    _ = w.commit(txn);
    return .pass;
}
