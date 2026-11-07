//! Spinners, avatars, and cards: widgets that show rather than take
//! input (D22).
//!
//! - A spinner is a bead of the accent circling a ring in the track
//!   color, the turning done by a compositor animation (D8), which
//!   reduced motion stops with the bead at the top (D29). Adwaita has no
//!   process-working-symbolic any more, so it is drawn, not an icon. It
//!   is a progress bar without a value, busy for assistive technology.
//! - An avatar is a circle tinted with a hue derived from a name, with
//!   the name's initials over it and an image part over those for a
//!   picture.
//! - A card is a column on a raised surface, framed in the border color
//!   or the accent, clipped to its corners, with a shadow.

const std = @import("std");
const w = @import("widgets.zig");
const siv = w.siv;
const tk = w.tokens;
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

// Spinners -----------------------------------------------------------------------

pub const Spinner = extern struct {
    hdr: w.Header,
    root: Node,
};

pub export fn siv_spinner(txn: Txn, parent: Node, desc: ?*const siv.SpinnerDesc) Node {
    const d = w.readDesc(siv.SpinnerDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (d.reserved0 != 0) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    if (!std.math.isFinite(d.diameter) or d.diameter < 0) return w.fail(txn, .error_invalid_argument);
    const size = if (d.diameter == 0) tk.spinner_size else d.diameter;
    const root = c.siv_stack(txn, parent, null);
    if (root == .null) return .null;
    const st = w.create(Spinner, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .spinner }, .root = root };
    _ = c.siv_set_default_layout(txn, root, &.{ .width = w.px(size), .height = w.px(size), .flags = .{ .no_shrink = true } });
    const whole: siv.Dimension = .{ .unit = .fraction, .value = 1 };
    const stroke = @max(1, @round(size / 8));
    const ring = c.siv_box(txn, root);
    _ = c.siv_set_layout(txn, ring, &.{ .width = whole, .height = whole });
    _ = c.siv_set_visual(txn, ring, &.{ .border_token = .track, .border_width = stroke, .radius = w.corners(size / 2) });
    // The bead rides on the ring at the top of a column that turns.
    const orbit = c.siv_flex(txn, root, &.{ .axis = .column, .align_items = .center });
    _ = c.siv_set_layout(txn, orbit, &.{ .width = whole, .height = whole });
    const bead_size = @max(2 * stroke, @round(size / 3));
    const bead = c.siv_box(txn, orbit);
    _ = c.siv_set_layout(txn, bead, &.{ .width = w.px(bead_size), .height = w.px(bead_size) });
    _ = c.siv_set_visual(txn, bead, &.{ .background_token = .accent, .radius = w.corners(bead_size / 2) });
    _ = c.siv_set_animation(txn, orbit, &.{
        .property = .rotate,
        .easing = .linear,
        .from = 0,
        .to = 2 * std.math.pi,
        .duration_ms = tk.spinner_ms,
    });
    setSpinnerLabel(txn, st, label);
    w.setInterface(txn, root, Spinner, st, .{ .set_label = setSpinnerLabel });
    return root;
}

fn setSpinnerLabel(txn: Txn, st: *Spinner, label: []const u8) void {
    const name = if (label.len == 0) "Loading" else label;
    _ = c.siv_set_semantics(txn, st.root, &.{ .role = .progress_bar, .label = name.ptr, .label_len = name.len, .flags = .{ .busy = true } });
}

// Avatars ------------------------------------------------------------------------

pub const Avatar = extern struct {
    hdr: w.Header,
    root: Node,
    initials: Node,
    image: Node,
    size: f32,
    /// The color the application chose; none derives one from the name.
    color: siv.ColorToken,
};

pub export fn siv_avatar(txn: Txn, parent: Node, desc: ?*const siv.AvatarDesc) Node {
    const d = w.readDesc(siv.AvatarDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    const name = w.str(d.name, d.name_len) orelse return w.fail(txn, .error_invalid_argument);
    if (!std.math.isFinite(d.diameter) or d.diameter < 0) return w.fail(txn, .error_invalid_argument);
    if (!validToken(d.color)) return w.fail(txn, .error_unsupported);
    const size = if (d.diameter == 0) tk.avatar_size else d.diameter;
    const root = c.siv_stack(txn, parent, &.{ .align_x = .center, .align_y = .center });
    if (root == .null) return .null;
    const st = w.create(Avatar, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .avatar }, .root = root, .initials = c.siv_text(txn, root, "", 0), .image = .null, .size = size, .color = d.color };
    _ = c.siv_set_default_layout(txn, root, &.{ .width = w.px(size), .height = w.px(size), .flags = .{ .no_shrink = true } });
    // The picture covers the initials once the application shows one.
    st.image = c.siv_image_view(txn, root, &.{ .fit = .cover });
    const whole: siv.Dimension = .{ .unit = .fraction, .value = 1 };
    _ = c.siv_set_layout(txn, st.image, &.{ .width = whole, .height = whole });
    _ = c.siv_set_semantics(txn, st.image, &.{ .role = .none });
    setAvatarName(txn, st, name);
    w.setInterface(txn, root, Avatar, st, .{ .set_label = setAvatarName, .get_part = avatarPart });
    return root;
}

fn avatarPart(st: *const Avatar, part: siv.WidgetPart, _: u32) Node {
    return if (part == .image) st.image else .null;
}

fn setAvatarName(txn: Txn, st: *Avatar, name: []const u8) void {
    var buf: [8]u8 = undefined;
    const ini = initials(name, &buf);
    _ = c.siv_set_text(txn, st.initials, ini.ptr, ini.len);
    // Initials take about 40% of the circle, at least the caption size
    // in practice; fixed so that they follow the circle, not the font.
    _ = c.siv_set_text_style(txn, st.initials, &.{
        .font_size = @round(st.size * 0.4),
        .weight = .semibold,
        .color_token = .view_fg,
        .flags = .{ .no_wrap = true },
    });
    _ = c.siv_set_semantics(txn, st.initials, &.{ .role = .none });
    const fill: siv.ColorToken = if (st.color != .none) tintOf(st.color) else if (name.len == 0) .track else tints[hueIndex(name)];
    _ = c.siv_set_visual(txn, st.root, &.{ .background_token = fill, .radius = w.corners(st.size / 2), .flags = .{ .clip = true } });
    _ = c.siv_set_semantics(txn, st.root, &.{ .role = .image, .label = name.ptr, .label_len = name.len });
}

/// The tints a name's hue comes from, in the order of the hues.
const tints = [_]siv.ColorToken{ .red_bg, .yellow_bg, .green_bg, .cyan_bg, .blue_bg, .magenta_bg };

/// One of the six hues for a name, the same for the same name in every
/// application and run: FNV-1a over its bytes, ASCII letters folded.
pub fn hueIndex(name: []const u8) usize {
    var h: u32 = 0x811c9dc5;
    for (name) |b| {
        h ^= std.ascii.toLower(b);
        h *%= 0x01000193;
    }
    return h % tints.len;
}

/// The fill a chip or avatar of color `token` takes: a hue's tint, or the
/// token itself.
pub fn tintOf(token: siv.ColorToken) siv.ColorToken {
    return switch (token) {
        .red => .red_bg,
        .yellow => .yellow_bg,
        .green => .green_bg,
        .cyan => .cyan_bg,
        .blue => .blue_bg,
        .magenta => .magenta_bg,
        else => token,
    };
}

pub fn validToken(token: siv.ColorToken) bool {
    return std.enums.tagName(siv.ColorToken, token) != null;
}

/// The initials of a name: the first letter or digit of its first word
/// and of its last, uppercased where ASCII, whole code points where not;
/// one for a single word. Words are separated by spaces; parts in
/// parentheses or angle brackets (an address) are skipped.
pub fn initials(name: []const u8, buf: *[8]u8) []const u8 {
    var first: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    var words = std.mem.tokenizeAny(u8, name, " \t\n");
    while (words.next()) |word| {
        if (word[0] == '(' or word[0] == '<') continue;
        const ch = firstChar(word) orelse continue;
        if (first == null) first = ch else last = ch;
    }
    var n: usize = 0;
    for ([_]?[]const u8{ first, last }) |part| if (part) |p| {
        @memcpy(buf[n..][0..p.len], p);
        if (p.len == 1) buf[n] = std.ascii.toUpper(p[0]);
        n += p.len;
    };
    return buf[0..n];
}

/// The first letter or digit of a word, or its first non-ASCII code point.
fn firstChar(word: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < word.len) {
        const len = std.unicode.utf8ByteSequenceLength(word[i]) catch return null;
        if (i + len > word.len) return null;
        if (len > 1) return word[i..][0..len];
        if (std.ascii.isAlphanumeric(word[i])) return word[i..][0..1];
        i += 1;
    }
    return null;
}

test "initials of first and last words, uppercased, addresses skipped" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("MO", initials("Maya Okafor", &buf));
    try std.testing.expectEqualStrings("MI", initials("mark van ito", &buf));
    try std.testing.expectEqualStrings("A", initials("ada", &buf));
    try std.testing.expectEqualStrings("JD", initials("  \"Jo\" D'Arcy <jo@example.com>", &buf));
    try std.testing.expectEqualStrings("ÉZ", initials("Élodie Zola", &buf));
    try std.testing.expectEqualStrings("", initials("", &buf));
    try std.testing.expectEqualStrings("", initials("<> ()", &buf));
}

test "a name's hue is stable and case-insensitive" {
    try std.testing.expectEqual(hueIndex("Maya Okafor"), hueIndex("maya okafor"));
    // The six hues all occur over a few names.
    var seen: [tints.len]bool = @splat(false);
    for ([_][]const u8{ "Ada", "Bea", "Cy", "Dee", "Eve", "Fay", "Gus", "Hal", "Ivy", "Jo", "Kit", "Lu", "Mo", "Ned", "Oz", "Pia" }) |n| seen[hueIndex(n)] = true;
    for (seen) |s| try std.testing.expect(s);
}

// Cards --------------------------------------------------------------------------

pub const Card = extern struct {
    hdr: w.Header,
    root: Node,
};

pub export fn siv_card(txn: Txn, parent: Node, desc: ?*const siv.CardDesc) Node {
    const d = w.readDesc(siv.CardDesc, desc) orelse return w.fail(txn, .error_invalid_argument);
    if (@as(u32, @bitCast(d.flags)) & ~@as(u32, 3) != 0) return w.fail(txn, .error_unsupported);
    if (!validToken(d.background)) return w.fail(txn, .error_unsupported);
    const label = w.str(d.label, d.label_len) orelse return w.fail(txn, .error_invalid_argument);
    const root = c.siv_flex(txn, parent, &.{ .axis = .column, .align_items = .stretch });
    if (root == .null) return .null;
    const st = w.create(Card, txn, root) orelse return .null;
    st.* = .{ .hdr = .{ .kind = .card }, .root = root };
    _ = c.siv_set_visual(txn, root, &.{
        .background_token = if (d.background == .none) .card_bg else d.background,
        .border_token = if (d.flags.accent) .accent else .border,
        .border_width = tk.border,
        .radius = w.corners(tk.radius),
        .flags = .{ .clip = true },
        .shadows = if (d.flags.flat) null else @ptrCast(&card_shadow),
        .shadows_count = if (d.flags.flat) 0 else 1,
    });
    setCardLabel(txn, st, label);
    w.setInterface(txn, root, Card, st, .{ .set_label = setCardLabel });
    return root;
}

const card_shadow = [1]siv.Shadow{.{ .offset_y = 8, .blur = 24, .color_token = .shadow }};

fn setCardLabel(txn: Txn, st: *Card, label: []const u8) void {
    _ = c.siv_set_semantics(txn, st.root, &.{ .role = if (label.len == 0) .default else .group, .label = label.ptr, .label_len = label.len });
}
