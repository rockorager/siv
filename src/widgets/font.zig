//! Font choosers (D41): a search field over a list of the installed
//! families (siv_app_get_font_family_at, D13), each row naming its family
//! in that family's own face, and a preview of the chosen one.
//!
//! The value is the chosen family's id (siv_app_get_font_family), the
//! same id text styles and spans take, so an application stores or
//! applies it directly; 0, which no family has, is the default family.
//! Typing in the field filters the list by what the names contain,
//! ignoring ASCII case; Down moves to the list, whose keys are a list
//! view's (D22). Selecting a row chooses it, reported with `change`;
//! Enter on a row reports `activate`, which closes the compact form's
//! popover. The list follows Fontconfig: a settings event with
//! SIV_EVENT_FONTS_CHANGED reads the families again.

const std = @import("std");
const w = @import("widgets.zig");
const picker = @import("picker.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

const default_preview = "The quick brown fox jumps over the lazy dog. 0123456789";

pub const FontChooser = extern struct {
    hdr: w.Header,
    root: Node,
    name: Node,
    search: Node,
    list: Node,
    preview: Node,
    value: u32 = 0,
    /// Families shown, as ids, in ids_key's memory on the root.
    shown: u32 = 0,
};

var ids_key: u8 = 0;

pub export fn siv_font_chooser(txn: Txn, parent: Node, desc: ?*const siv.FontChooserDesc) Node {
    const d = w.readDesc(siv.FontChooserDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 0xf) != 0 or d.reserved0 != 0) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const preview = w.str(d.preview, d.preview_len) orelse return w.fail(txn, .error_invalid_argument);
    if (d.flags.compact) return picker.compact(txn, parent, .font_chooser, label, d.flags, 0, .{ .r = 0, .g = 0, .b = 0, .a = 1 }, .none, preview);

    const root = c.siv_flex(txn, parent, &.{ .axis = .column, .gap = 8 });
    if (root == .null) return .null;
    const st = w.create(FontChooser, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .font_chooser, .disabled = d.flags.disabled }, .root = root, .name = .null, .search = .null, .list = .null, .preview = .null };
    c.siv_set_layout(txn, root, &.{ .width = w.px(300) });
    st.search = c.siv_text_field(txn, root, &.{ .placeholder = "Search fonts", .placeholder_len = 12, .label = "Search fonts", .label_len = 12 });
    _ = c.siv_on_default(txn, st.search, .change, onSearch, null, st);
    _ = c.siv_on_default(txn, st.search, .key, onSearchKey, null, st);
    st.list = c.siv_list_view(txn, root, &.{ .label = "Font families", .label_len = 13, .user_data = st, .bind = bind, .item_height = 30, .selection = .single });
    c.siv_set_layout(txn, st.list, &.{ .height = w.px(200), .grow = 0 });
    _ = c.siv_on(txn, st.list, .select, onSelect, null, st);
    _ = c.siv_on(txn, st.list, .activate, onActivate, null, st);
    const text = if (preview.len == 0) default_preview else preview;
    st.preview = c.siv_text(txn, root, text.ptr, text.len);
    c.siv_set_layout(txn, st.preview, &.{ .min_height = 56, .padding = .{ .start = 8, .end = 8, .top = 8, .bottom = 8 } });
    st.name = w.hiddenText(txn, root, label);
    w.onDefault(txn, root, .settings, onSettings, st);
    w.setInterface(txn, root, FontChooser, st, .{ .set_label = setLabel, .set_value = setValue, .get_value = getValue, .apply = apply, .focus = focusSearch });
    filter(txn, st);
    apply(txn, st);
    return root;
}

fn stateOf(node: Node) ?*FontChooser {
    return w.stateOf(FontChooser, node, &.{.font_chooser});
}

fn focusSearch(st: *FontChooser) Node {
    return st.search;
}

fn getValue(st: *const FontChooser) f64 {
    return @floatFromInt(st.value);
}

fn setValue(txn: Txn, st: *FontChooser, v: f64) void {
    const app = picker.appOf(st.root);
    var len: usize = 0;
    if (v < 0 or v > std.math.maxInt(u32) or (v != 0 and c.siv_app_get_font_family_name(app, @intFromFloat(v), null, 0, &len) != .ok)) {
        c.siv_txn_fail(txn, .error_invalid_argument);
        return;
    }
    st.value = @intFromFloat(v);
    select(txn, st);
    apply(txn, st);
}

fn setLabel(txn: Txn, st: *FontChooser, label: []const u8) void {
    c.siv_set_text(txn, st.name, label.ptr, label.len);
    apply(txn, st);
}

fn ids(st: *const FontChooser) []u32 {
    var p: ?*anyopaque = null;
    if (c.siv_node_get_data(st.root, &ids_key, &p) != .ok) return &.{};
    const base: [*]u32 = @ptrCast(@alignCast(p orelse return &.{}));
    return base[0..st.shown];
}

fn familyName(app: siv.App, id: u32, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_app_get_font_family_name(app, id, buf.ptr, buf.len, &len) != .ok) return "";
    return buf[0..@min(len, buf.len)];
}

/// Lists the families whose names contain the search text.
fn filter(txn: Txn, st: *FontChooser) void {
    const app = picker.appOf(st.root);
    var count: u32 = 0;
    _ = c.siv_app_get_font_family_count(app, &count);
    var p: ?*anyopaque = null;
    if (c.siv_set_data(txn, st.root, &ids_key, @max(count, 1) * @sizeOf(u32), &p) != .ok) return;
    const out: [*]u32 = @ptrCast(@alignCast(p.?));
    var query_buf: [256]u8 = undefined;
    const query = std.mem.trim(u8, w.textOf(st.search, &query_buf), " ");
    var n: u32 = 0;
    var buf: [256]u8 = undefined;
    for (0..count) |i| {
        var id: u32 = 0;
        if (c.siv_app_get_font_family_at(app, @intCast(i), &id) != .ok) continue;
        if (!picker.containsIgnoreCase(familyName(app, id, &buf), query)) continue;
        out[n] = id;
        n += 1;
    }
    st.shown = n;
    c.siv_view_set_count(txn, st.list, n);
    select(txn, st);
}

/// Selects the chosen family's row, if shown.
fn select(txn: Txn, st: *FontChooser) void {
    for (ids(st), 0..) |id, i| if (id == st.value) {
        c.siv_view_set_selected(txn, st.list, @intCast(i), true);
        c.siv_view_set_cursor(txn, st.list, @intCast(i));
        return;
    };
    c.siv_view_set_selection(txn, st.list, null, 0);
}

fn apply(txn: Txn, st: *FontChooser) void {
    const h = st.hdr;
    const app = picker.appOf(st.root);
    var name_buf: [256]u8 = undefined;
    const label = w.textOf(st.name, &name_buf);
    c.siv_set_semantics(txn, st.root, &.{ .role = .group, .label = label.ptr, .label_len = label.len, .flags = .{ .disabled = h.disabled } });
    var buf: [256]u8 = undefined;
    const family = if (st.value != 0) familyName(app, st.value, &buf) else "";
    c.siv_set_text_style(txn, st.preview, &.{ .family = family.ptr, .family_len = family.len, .color_token = if (h.disabled) .disabled_fg else .window_fg, .size_role = .title });
    var pv_buf: [300]u8 = undefined;
    const pv = std.fmt.bufPrint(&pv_buf, "Preview: {s}", .{if (family.len == 0) "default font" else family}) catch "Preview";
    c.siv_set_semantics(txn, st.preview, &.{ .label = pv.ptr, .label_len = pv.len });
    c.siv_set_visual(txn, st.preview, &.{ .radius = w.corners(tk.radius), .border_width = tk.border, .border_token = .border });
    c.siv_widget_set_disabled(txn, st.search, h.disabled);
}

fn bind(ud: ?*anyopaque, txn: Txn, row: Node, item: u64, _: u32, _: u32, recycled: bool) callconv(.c) void {
    const st: *FontChooser = @ptrCast(@alignCast(ud.?));
    const list = ids(st);
    if (item >= list.len) return;
    const id = list[@intCast(item)];
    var buf: [256]u8 = undefined;
    const name = familyName(picker.appOf(st.root), id, &buf);
    const text = if (recycled) w.related(row, .first_child) else c.siv_text(txn, row, "", 0);
    if (!recycled) c.siv_set_layout(txn, text, &.{ .padding = .{ .start = 8, .end = 8, .top = 4 } });
    c.siv_set_text(txn, text, name.ptr, name.len);
    c.siv_set_text_style(txn, text, &.{ .family = name.ptr, .family_len = name.len, .color_token = .view_fg, .size_role = .body, .flags = .{ .no_wrap = true } });
    c.siv_set_semantics(txn, row, &.{ .label = name.ptr, .label_len = name.len });
}

fn onSearch(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *FontChooser = @ptrCast(@alignCast(ud.?));
    const txn = w.begin(w.windowOf(st.root)) orelse return .pass;
    filter(txn, st);
    _ = w.commit(txn);
    return .pass;
}

fn onSearchKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *FontChooser = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.pressed or ev.keysym != w.keysym.down or st.shown == 0) return .pass;
    var cursor: i32 = -1;
    _ = c.siv_view_get_cursor(st.list, &cursor);
    if (cursor < 0) {
        const txn = w.begin(w.windowOf(st.root)) orelse return .pass;
        c.siv_view_set_cursor(txn, st.list, 0);
        _ = w.commit(txn);
    }
    _ = c.siv_node_focus(st.list);
    return .handled;
}

fn onSelect(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *FontChooser = @ptrCast(@alignCast(ud.?));
    if (st.hdr.disabled or ev.count == 0) return .pass;
    const list = ids(st);
    const i: usize = @intCast(ev.index);
    if (i >= list.len or list[i] == st.value) return .handled;
    st.value = list[i];
    const root = st.root;
    const txn = w.begin(w.windowOf(root)) orelse return .handled;
    apply(txn, st);
    if (!w.commit(txn)) return .handled;
    w.emitChange(root, @floatFromInt(list[i]), 0);
    return .handled;
}

fn onActivate(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *FontChooser = @ptrCast(@alignCast(ud.?));
    var handled = false;
    _ = c.siv_node_emit(st.root, &.{ .type = .activate }, &handled);
    return .handled;
}

fn onSettings(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const st: *FontChooser = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.fonts_changed) return .pass;
    const txn = w.begin(w.windowOf(st.root)) orelse return .pass;
    filter(txn, st);
    _ = w.commit(txn);
    return .pass;
}
