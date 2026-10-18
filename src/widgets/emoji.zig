//! Emoji choosers (D41): a search field and a skin tone menu over a tab
//! per group of the catalogue (UTS #51's groups, in CLDR order) and a
//! grid of the group's emoji, or of those whose names match the search
//! (siv_emoji_find).
//!
//! The value is the catalogue index of the emoji chosen last (-1 before
//! one is); the change event carries the skin tone as its index, so an
//! application gets the characters with siv_emoji_get(value, index).
//! Choosing is a click, Enter, or Space on a cell. The tabs are a
//! WAI-ARIA tab list: one Tab stop at the selected tab, Left and Right
//! (mirrored in right-to-left layouts), Home and End move and select. The
//! grid is a grid view (D22): arrows move in two dimensions. Each cell is
//! named by the emoji's CLDR name with its tone, since a screen reader
//! would otherwise read the characters as it can.

const std = @import("std");
const w = @import("widgets.zig");
const picker = @import("picker.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

const groups = 9;
const cell: f32 = 40;
const columns = 8;
const group_names = [groups][]const u8{ "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink", "Travel & Places", "Activities", "Objects", "Symbols", "Flags" };
/// Each tab's face: an emoji of its group.
const group_faces = [groups][]const u8{ "😀", "👋", "🐻", "🍔", "🚗", "⚽", "💡", "❤\u{fe0f}", "🏁" };
const tone_names = [_][]const u8{ "No skin tone", "Light skin tone", "Medium-light skin tone", "Medium skin tone", "Medium-dark skin tone", "Dark skin tone" };

pub const EmojiChooser = extern struct {
    hdr: w.Header,
    root: Node,
    name: Node,
    search: Node,
    tone_box: Node,
    tab_list: Node,
    tabs: [groups]Node,
    tab_texts: [groups]Node,
    grid: Node,
    group: u8 = 0,
    tone: siv.SkinTone = .none,
    value: i32 = -1,
    /// Search results shown instead of the group, in results_key's memory
    /// on the root.
    searching: bool = false,
    /// A key other than Space is down in the grid: the selection it
    /// moves is not a choice.
    navigating: bool = false,
    results: u32 = 0,
};

var results_key: u8 = 0;

/// Where each group starts in the catalogue, which CLDR's order keeps
/// grouped; the last entry is the count.
var group_start: [groups + 1]u32 = @splat(0);
var starts_known = false;

fn starts() *const [groups + 1]u32 {
    if (!starts_known) {
        const count = c.siv_emoji_get_count();
        var g: usize = 0;
        for (0..count) |i| {
            var info: siv.EmojiInfo = .{ .group = .smileys_emotion, .flags = .{} };
            if (c.siv_emoji_get_info(@intCast(i), &info) != .ok) continue;
            const gi: usize = @intCast(@intFromEnum(info.group));
            while (g < gi and g < groups) {
                g += 1;
                group_start[g] = @intCast(i);
            }
        }
        while (g < groups) {
            g += 1;
            group_start[g] = count;
        }
        starts_known = true;
    }
    return &group_start;
}

pub export fn siv_emoji_chooser(txn: Txn, parent: Node, desc: ?*const siv.EmojiChooserDesc) Node {
    const d = w.readDesc(siv.EmojiChooserDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 0xf) != 0) return w.fail(txn, .error_unsupported);
    const tone_i = @intFromEnum(d.tone);
    if (tone_i < 0 or tone_i > 5) return w.fail(txn, .error_invalid_argument);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    if (d.flags.compact) return picker.compact(txn, parent, .emoji_chooser, label, d.flags, -1, .{ .r = 0, .g = 0, .b = 0, .a = 1 }, d.tone, "");

    const root = c.siv_flex(txn, parent, &.{ .axis = .column, .gap = 6 });
    if (root == .null) return .null;
    const st = w.create(EmojiChooser, txn, root) orelse return .null;
    st.* = .{
        .hdr = .{ .kind = .emoji_chooser, .disabled = d.flags.disabled },
        .root = root,
        .name = .null,
        .search = .null,
        .tone_box = .null,
        .tab_list = .null,
        .tabs = @splat(.null),
        .tab_texts = @splat(.null),
        .grid = .null,
        .tone = d.tone,
    };
    const width = cell * columns + 2 * tk.border + 12;
    c.siv_set_layout(txn, root, &.{ .width = w.px(width) });

    const top = c.siv_flex(txn, root, &.{ .axis = .row, .align_items = .center, .gap = tk.gap });
    st.search = c.siv_text_field(txn, top, &.{ .placeholder = "Search emoji", .placeholder_len = 12, .label = "Search emoji", .label_len = 12 });
    c.siv_set_layout(txn, st.search, &.{ .grow = 1, .width = w.px(0) });
    _ = c.siv_on_default(txn, st.search, .change, onSearch, null, st);
    _ = c.siv_on_default(txn, st.search, .key, onSearchKey, null, st);
    st.tone_box = c.siv_combo_box(txn, top, &.{ .label = "Skin tone", .label_len = 9 });
    for (tone_names) |n| _ = c.siv_combo_box_item(txn, st.tone_box, &.{ .label = n.ptr, .label_len = n.len });
    c.siv_widget_set_value(txn, st.tone_box, @floatFromInt(tone_i));
    _ = c.siv_on(txn, st.tone_box, .change, onTone, null, st);

    st.tab_list = c.siv_flex(txn, root, &.{ .axis = .row, .justify = .space_between });
    for (0..groups) |g| {
        const tab = c.siv_flex(txn, st.tab_list, &.{ .axis = .row, .justify = .center, .align_items = .center });
        c.siv_set_layout(txn, tab, &.{ .width = w.px(34), .height = w.px(34), .flags = .{ .no_shrink = true } });
        st.tabs[g] = tab;
        st.tab_texts[g] = c.siv_text(txn, tab, group_faces[g].ptr, group_faces[g].len);
        c.siv_set_semantics(txn, st.tab_texts[g], &.{ .role = .none });
        _ = c.siv_on_default(txn, tab, .activate, onTab, null, st);
        _ = c.siv_on_default(txn, tab, .pointer, onTabPointer, null, st);
    }
    _ = c.siv_on_default(txn, st.tab_list, .key, onTabKey, null, st);

    st.grid = c.siv_grid_view(txn, root, &.{ .label = group_names[0].ptr, .label_len = group_names[0].len, .user_data = st, .bind = bind, .item_width = cell, .item_height = cell, .selection = .single });
    c.siv_set_layout(txn, st.grid, &.{ .height = w.px(cell * 6 + 2 * tk.border), .grow = 0 });
    _ = c.siv_on(txn, st.grid, .select, onSelect, null, st);
    _ = c.siv_on_capture(txn, st.grid, .key, onGridKey, null, st);
    _ = c.siv_on(txn, st.grid, .activate, onActivate, null, st);

    st.name = w.hiddenText(txn, root, label);
    w.setInterface(txn, root, EmojiChooser, st, .{ .set_label = setLabel, .set_value = setValue, .get_value = getValue, .apply = apply, .focus = focusSearch });
    showItems(txn, st);
    apply(txn, st);
    return root;
}

fn stateOf(node: Node) ?*EmojiChooser {
    return w.stateOf(EmojiChooser, node, &.{.emoji_chooser});
}

fn focusSearch(st: *EmojiChooser) Node {
    return st.search;
}

fn getValue(st: *const EmojiChooser) f64 {
    return @floatFromInt(st.value);
}

/// Shows the emoji's group, with it selected.
fn setValue(txn: Txn, st: *EmojiChooser, v: f64) void {
    const count = c.siv_emoji_get_count();
    const i = @round(v);
    if (i < -1 or i >= @as(f64, @floatFromInt(count))) {
        c.siv_txn_fail(txn, .error_invalid_argument);
        return;
    }
    st.value = @intFromFloat(i);
    if (st.value >= 0) {
        var info: siv.EmojiInfo = .{ .group = .smileys_emotion, .flags = .{} };
        _ = c.siv_emoji_get_info(@intCast(st.value), &info);
        st.group = @intCast(@intFromEnum(info.group));
        if (st.searching) {
            st.searching = false;
            c.siv_set_text(txn, st.search, "", 0);
        }
    }
    showItems(txn, st);
    apply(txn, st);
}

fn setLabel(txn: Txn, st: *EmojiChooser, label: []const u8) void {
    c.siv_set_text(txn, st.name, label.ptr, label.len);
    apply(txn, st);
}

fn results(st: *const EmojiChooser) []u32 {
    var p: ?*anyopaque = null;
    if (c.siv_node_get_data(st.root, &results_key, &p) != .ok) return &.{};
    const base: [*]u32 = @ptrCast(@alignCast(p orelse return &.{}));
    return base[0..st.results];
}

/// The catalogue index of a grid item.
fn itemIndex(st: *const EmojiChooser, item: u64) ?u32 {
    if (st.searching) {
        const r = results(st);
        return if (item < r.len) r[@intCast(item)] else null;
    }
    const s = starts();
    const i = s[st.group] + item;
    return if (i < s[st.group + 1]) @intCast(i) else null;
}

/// Shows the group or the search results, with the value selected.
fn showItems(txn: Txn, st: *EmojiChooser) void {
    const s = starts();
    const n: u32 = if (st.searching) st.results else s[st.group + 1] - s[st.group];
    c.siv_view_set_count(txn, st.grid, n);
    c.siv_view_refresh(txn, st.grid);
    c.siv_view_set_selection(txn, st.grid, null, 0);
    if (st.value >= 0) {
        const v: u32 = @intCast(st.value);
        var row: ?u32 = null;
        if (st.searching) {
            for (results(st), 0..) |r, i| if (r == v) {
                row = @intCast(i);
                break;
            };
        } else if (v >= s[st.group] and v < s[st.group + 1]) row = v - s[st.group];
        if (row) |r| {
            c.siv_view_set_selected(txn, st.grid, r, true);
            c.siv_view_set_cursor(txn, st.grid, @intCast(r));
            return;
        }
    }
    c.siv_view_set_cursor(txn, st.grid, if (n > 0) 0 else -1);
}

fn apply(txn: Txn, st: *EmojiChooser) void {
    const h = st.hdr;
    var name_buf: [256]u8 = undefined;
    const label = w.textOf(st.name, &name_buf);
    c.siv_set_semantics(txn, st.root, &.{ .role = .group, .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = h.disabled } });
    c.siv_set_semantics(txn, st.tab_list, &.{ .role = .tab_list, .label = "Categories", .label_len = 10 });
    for (st.tabs, st.tab_texts, 0..) |tab, text, g| {
        const sel = g == st.group and !st.searching;
        c.siv_set_text_style(txn, text, &.{ .size_role = .heading, .color_token = .window_fg, .flags = .{ .no_wrap = true } });
        c.siv_set_visual(txn, tab, &.{
            .radius = w.corners(tk.radius),
            .background_token = if (sel) .control_active else .none,
            .border_width = if (sel) 2 * tk.border else 0,
            .border_token = .accent,
        });
        c.siv_set_semantics(txn, tab, &.{
            .role = .tab,
            .label = group_names[g].ptr,
            .label_len = group_names[g].len,
            .selected = if (sel) .on else .off,
            .flags = .{ .focusable = g == st.group and !h.disabled, .disabled = h.disabled },
        });
    }
    const grid_name = if (st.searching) "Search results" else group_names[st.group];
    c.siv_widget_set_label(txn, st.grid, grid_name.ptr, grid_name.len);
    c.siv_widget_set_disabled(txn, st.search, h.disabled);
    c.siv_widget_set_disabled(txn, st.tone_box, h.disabled);
}

fn bind(ud: ?*anyopaque, txn: Txn, row: Node, item: u64, _: u32, _: u32, recycled: bool) callconv(.c) void {
    const st: *EmojiChooser = @ptrCast(@alignCast(ud.?));
    const index = itemIndex(st, item) orelse return;
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    if (c.siv_emoji_get(index, st.tone, &buf, buf.len, &len) != .ok) return;
    const chars = buf[0..@min(len, buf.len)];
    const text = if (recycled) w.related(row, .first_child) else c.siv_text(txn, row, "", 0);
    if (!recycled) c.siv_set_layout(txn, text, &.{ .grow = 1, .padding = .{ .top = 6 } });
    c.siv_set_text(txn, text, chars.ptr, chars.len);
    c.siv_set_text_style(txn, text, &.{ .size_role = .title, .color_token = .view_fg, .@"align" = .center, .flags = .{ .no_wrap = true } });
    var name_buf: [256]u8 = undefined;
    if (c.siv_emoji_get_name(index, st.tone, &name_buf, name_buf.len, &len) != .ok) len = 0;
    c.siv_set_semantics(txn, row, &.{ .label = &name_buf, .label_len = @min(len, name_buf.len) });
}

fn refresh(st: *EmojiChooser, items: bool) void {
    const txn = w.begin(w.windowOf(st.root)) orelse return;
    if (items) showItems(txn, st);
    apply(txn, st);
    _ = w.commit(txn);
}

fn chooseRow(st: *EmojiChooser, row: u32) void {
    if (st.hdr.disabled) return;
    const index = itemIndex(st, row) orelse return;
    st.value = @intCast(index);
    w.emitChange(st.root, @floatFromInt(index), @intCast(@intFromEnum(st.tone)));
}

/// A click or Space chooses; arrows only move the selection.
fn onSelect(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *EmojiChooser = @ptrCast(@alignCast(ud.?));
    if (ev.count == 0 or st.navigating) return .handled;
    chooseRow(st, ev.index);
    return .handled;
}

/// Sees the grid's keys on their way to its rows, which select as they
/// move the cursor.
fn onGridKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *EmojiChooser = @ptrCast(@alignCast(ud.?));
    st.navigating = ev.flags.pressed and ev.keysym != w.keysym.space;
    return .pass;
}

fn onActivate(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *EmojiChooser = @ptrCast(@alignCast(ud.?));
    chooseRow(st, ev.index);
    return .handled;
}

fn onTone(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *EmojiChooser = @ptrCast(@alignCast(ud.?));
    const i: i32 = @intFromFloat(std.math.clamp(ev.value, 0, 5));
    st.tone = @enumFromInt(i);
    const txn = w.begin(w.windowOf(st.root)) orelse return .handled;
    c.siv_view_refresh(txn, st.grid);
    _ = w.commit(txn);
    return .handled;
}

fn onSearch(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *EmojiChooser = @ptrCast(@alignCast(ud.?));
    var query_buf: [256]u8 = undefined;
    const query = std.mem.trim(u8, w.textOf(st.search, &query_buf), " ");
    const txn = w.begin(w.windowOf(st.root)) orelse return .pass;
    st.searching = query.len > 0;
    st.results = 0;
    if (st.searching) {
        const count = c.siv_emoji_get_count();
        var p: ?*anyopaque = null;
        if (c.siv_set_data(txn, st.root, &results_key, @max(count, 1) * @sizeOf(u32), &p) == .ok) {
            const out: [*]u32 = @ptrCast(@alignCast(p.?));
            var start: u32 = 0;
            while (start < count) {
                var found = false;
                var index: u32 = count;
                if (c.siv_emoji_find(query.ptr, query.len, start, &found, &index) != .ok or !found) break;
                out[st.results] = index;
                st.results += 1;
                start = index + 1;
            }
        }
    }
    showItems(txn, st);
    apply(txn, st);
    _ = w.commit(txn);
    return .pass;
}

/// Down moves from the search field to the grid.
fn onSearchKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *EmojiChooser = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.pressed or ev.keysym != w.keysym.down) return .pass;
    _ = c.siv_node_focus(st.grid);
    return .handled;
}

fn tabOf(st: *const EmojiChooser, node: Node) ?u8 {
    for (st.tabs, 0..) |t, g| if (t == node) return @intCast(g);
    return null;
}

fn selectGroup(st: *EmojiChooser, g: u8, focus: bool) void {
    st.group = g;
    if (st.searching) {
        st.searching = false;
        const txn = w.begin(w.windowOf(st.root)) orelse return;
        c.siv_set_text(txn, st.search, "", 0);
        _ = w.commit(txn);
    }
    refresh(st, true);
    if (focus) _ = c.siv_node_focus(st.tabs[g]);
}

fn onTab(ud: ?*anyopaque, node: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *EmojiChooser = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled) return .handled;
    const g = tabOf(st, node) orelse return .pass;
    selectGroup(st, g, true);
    return .handled;
}

fn onTabPointer(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *EmojiChooser = @ptrCast(@alignCast(ud.?));
    const g = tabOf(st, node) orelse return .pass;
    if (ev.phase != .enter and ev.phase != .leave) return .pass;
    const sel = g == st.group and !st.searching;
    if (sel or st.hdr.disabled) return .pass;
    const txn = w.begin(ev.window) orelse return .pass;
    c.siv_set_visual(txn, node, &.{ .radius = w.corners(tk.radius), .background_token = if (ev.phase == .enter) .control_hover else .none });
    _ = w.commit(txn);
    return .pass;
}

fn onTabKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *EmojiChooser = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled or !ev.flags.pressed) return .pass;
    const g = tabOf(st, ev.target) orelse return .pass;
    const k = w.keysym;
    const to: i32 = switch (ev.keysym) {
        k.left, k.right => @as(i32, g) + w.arrowDirection(ev.keysym, w.isRtl(st.root)),
        k.home => 0,
        k.end => groups - 1,
        else => return .pass,
    };
    selectGroup(st, @intCast(@mod(to, groups)), true);
    return .handled;
}
