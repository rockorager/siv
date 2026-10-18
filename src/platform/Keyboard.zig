//! One seat's keyboard translation (D15, D16): the compositor's XKB keymap
//! and state, compose sequences without an input method, and modifiers.
//! Independent of Wayland so that it can be tested with local keymaps.

const std = @import("std");
const xkb = @import("xkbcommon");
const platform = @import("platform.zig");
const Keyboard = @This();

context: *xkb.struct_xkb_context,
keymap: ?*xkb.struct_xkb_keymap = null,
state: ?*xkb.struct_xkb_state = null,
compose: ?*xkb.struct_xkb_compose_state = null,
/// Keymap indices of shift, ctrl, alt, super, caps lock, num lock.
mod_index: [6]u32 = @splat(invalid_mod),
/// The Latin-1 characters each of the first layouts types without Shift
/// (its first level) on some key, in lower case: a key's Latin
/// equivalent is never one of the active layout's own (D44).
unshifted: [max_layouts]std.StaticBitSet(256) = @splat(.empty),

const invalid_mod: u32 = 0xffffffff;
/// XKB's limit on groups in a keymap.
const max_layouts = 4;
const mod_names = [_][*:0]const u8{ "Shift", "Control", "Mod1", "Mod4", "Lock", "Mod2" };

pub fn deinit(k: *Keyboard) void {
    xkb.xkb_state_unref(k.state);
    xkb.xkb_keymap_unref(k.keymap);
    xkb.xkb_compose_state_unref(k.compose);
    k.* = undefined;
}

/// Replaces the keymap with one in XKB text format.
pub fn setKeymap(k: *Keyboard, text: [*:0]const u8) error{InvalidKeymap}!void {
    const keymap = xkb.xkb_keymap_new_from_string(k.context, text, xkb.XKB_KEYMAP_FORMAT_TEXT_V1, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse
        return error.InvalidKeymap;
    k.useKeymap(keymap) catch {
        xkb.xkb_keymap_unref(keymap);
        return error.InvalidKeymap;
    };
}

/// Takes ownership of `keymap`.
pub fn useKeymap(k: *Keyboard, keymap: *xkb.struct_xkb_keymap) error{OutOfMemory}!void {
    const state = xkb.xkb_state_new(keymap) orelse return error.OutOfMemory;
    xkb.xkb_state_unref(k.state);
    xkb.xkb_keymap_unref(k.keymap);
    k.keymap = keymap;
    k.state = state;
    for (&k.mod_index, mod_names) |*index, name| index.* = xkb.xkb_keymap_mod_get_index(keymap, name);
    k.unshifted = @splat(.empty);
    const layouts = @min(xkb.xkb_keymap_num_layouts(keymap), max_layouts);
    var code = xkb.xkb_keymap_min_keycode(keymap);
    while (code <= xkb.xkb_keymap_max_keycode(keymap)) : (code += 1) {
        for (k.unshifted[0..layouts], 0..) |*set, layout| {
            var syms: [*c]const xkb.xkb_keysym_t = null;
            if (xkb.xkb_keymap_key_get_syms_by_level(keymap, code, @intCast(layout), 0, &syms) != 1) continue;
            const cp = xkb.xkb_keysym_to_utf32(syms[0]);
            if (cp > 0x20 and cp <= 0xff) set.set(lower(cp));
        }
    }
    k.resetCompose();
}

/// Compiles a keymap from XKB layout and variant names ("ru,us", ",dvorak")
/// with the evdev rules, the pc105 model, and no options. `context` should
/// ignore the environment's names (XKB_CONTEXT_NO_ENVIRONMENT_NAMES), so
/// that XKB_DEFAULT_OPTIONS cannot change the result.
pub fn keymapFromNames(context: *xkb.struct_xkb_context, layout: [*:0]const u8, variant: [*:0]const u8) ?*xkb.struct_xkb_keymap {
    const names: xkb.struct_xkb_rule_names = .{ .rules = "evdev", .model = "pc105", .layout = layout, .variant = variant, .options = "" };
    return xkb.xkb_keymap_new_from_names(context, &names, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS);
}

/// Sets the state to the modifiers held (Shift, Ctrl, Alt, and Super
/// depressed, Caps Lock and Num Lock locked) and the active layout, as a
/// compositor's modifiers event would.
pub fn setMods(k: *Keyboard, m: platform.Mods, layout: u32) void {
    var depressed: u32 = 0;
    var locked: u32 = 0;
    const held = [_]bool{ m.shift, m.ctrl, m.alt, m.super, m.caps_lock, m.num_lock };
    for (held, k.mod_index, 0..) |on, index, i| {
        if (!on or index == invalid_mod) continue;
        if (i < 4) depressed |= @as(u32, 1) << @intCast(index) else locked |= @as(u32, 1) << @intCast(index);
    }
    k.updateMask(depressed, 0, locked, layout);
}

/// Enables compose sequences from `table`; null disables them.
pub fn setComposeTable(k: *Keyboard, table: ?*xkb.struct_xkb_compose_table) void {
    xkb.xkb_compose_state_unref(k.compose);
    k.compose = if (table) |t| xkb.xkb_compose_state_new(t, xkb.XKB_COMPOSE_STATE_NO_FLAGS) else null;
}

pub fn resetCompose(k: *Keyboard) void {
    if (k.compose) |c| xkb.xkb_compose_state_reset(c);
}

pub fn updateMask(k: *Keyboard, depressed: u32, latched: u32, locked: u32, group: u32) void {
    _ = xkb.xkb_state_update_mask(k.state orelse return, depressed, latched, locked, 0, 0, group);
}

pub fn mods(k: *const Keyboard) platform.Mods {
    const state = k.state orelse return .{};
    var bits: u8 = 0;
    for (k.mod_index, 0..) |index, i| {
        if (index == invalid_mod) continue;
        if (xkb.xkb_state_mod_index_is_active(state, index, xkb.XKB_STATE_MODS_EFFECTIVE) > 0) bits |= @as(u8, 1) << @intCast(i);
    }
    return @bitCast(bits);
}

/// The keysym of a key without feeding compose, for releases.
pub fn keysym(k: *const Keyboard, keycode: u32) u32 {
    return xkb.xkb_state_key_get_one_sym(k.state orelse return 0, keycode);
}

/// The Latin equivalent of a key whose keysym is a character other than
/// an ASCII letter or digit, which shortcuts match besides the keysym
/// (D44); 0 for none. It is the first allowed of: what the same key
/// types at the same shift level in the other layouts of the keymap, in
/// their order (ru,us: С is c), and the US QWERTY character at the key's
/// position (ru alone: С is c; AZERTY's & is 1; Hebrew's / is q). A key
/// that types Latin-1 itself (/, &, é) allows only ASCII letters and
/// digits, so punctuation and the letters of Latin layouts keep their
/// own labels; and no character the active layout types without Shift
/// on some key is allowed, so Ctrl+Z follows the label on AZERTY and
/// Dvorak and the Turkish ı is not a second I.
pub fn latin(k: *const Keyboard, keycode: u32, sym: u32) u32 {
    const state = k.state orelse return 0;
    const keymap = k.keymap orelse return 0;
    const cp = xkb.xkb_keysym_to_utf32(sym);
    if (cp <= 0x20 or (cp >= 0x7f and cp <= 0xa0) or std.ascii.isAlphanumeric(std.math.cast(u8, cp) orelse 0)) return 0;
    const own = cp <= 0xff;
    const active = xkb.xkb_state_key_get_layout(state, keycode);
    const layouts = xkb.xkb_keymap_num_layouts_for_key(keymap, keycode);
    var layout: u32 = 0;
    while (layout < layouts) : (layout += 1) {
        if (layout == active) continue;
        const level = xkb.xkb_state_key_get_level(state, keycode, layout);
        var syms: [*c]const xkb.xkb_keysym_t = null;
        if (xkb.xkb_keymap_key_get_syms_by_level(keymap, keycode, layout, level, &syms) != 1) continue;
        if (k.equivalent(xkb.xkb_keysym_to_utf32(syms[0]), own, active)) |c| return c;
    }
    const code = keycode -% 8;
    for (us_rows) |row| if (code >= row[0] and code - row[0] < row[1].len) {
        const c = (if (k.mods().shift) row[2] else row[1])[code - row[0]];
        return k.equivalent(c, own, active) orelse 0;
    };
    return 0;
}

/// The US QWERTY layout's main block by evdev code: the first code of a
/// run of keys, their characters, and with Shift.
const us_rows = [_]struct { u32, []const u8, []const u8 }{
    .{ 2, "1234567890-=", "!@#$%^&*()_+" },
    .{ 16, "qwertyuiop[]", "QWERTYUIOP{}" },
    .{ 30, "asdfghjkl;'`", "ASDFGHJKL:\"~" },
    .{ 43, "\\zxcvbnm,./", "|ZXCVBNM<>?" },
};

/// `c` as a key's Latin equivalent, if it may be one: a printable
/// Latin-1 character, only a letter or digit for a key that types
/// Latin-1 itself (`own`), and not one the active layout types unshifted.
/// Latin-1 keysyms are their code points.
fn equivalent(k: *const Keyboard, c: u32, own: bool, active: u32) ?u32 {
    if (c <= 0x20 or (c >= 0x7f and c <= 0xa0) or c > 0xff) return null;
    if (own and !std.ascii.isAlphanumeric(@intCast(c))) return null;
    if (active < max_layouts and k.unshifted[active].isSet(lower(c))) return null;
    return c;
}

/// A Latin-1 character in lower case.
fn lower(c: u32) u32 {
    return switch (c) {
        'A'...'Z', 0xc0...0xd6, 0xd8...0xde => c + 0x20,
        else => c,
    };
}

pub fn repeats(k: *const Keyboard, keycode: u32) bool {
    return xkb.xkb_keymap_key_repeats(k.keymap orelse return false, keycode) != 0;
}

/// What a key press produces.
pub const Press = struct {
    keysym: u32 = 0,
    /// The key's Latin equivalent (`latin`); 0 for none, and for
    /// composed keys.
    latin: u32 = 0,
    text_buf: [platform.Key.max_text]u8 = undefined,
    text_len: u8 = 0,
    composing: bool = false,

    pub fn text(p: *const Press) []const u8 {
        return p.text_buf[0..p.text_len];
    }
};

/// Translates a key press with the current state, feeding the compose
/// sequence. Control characters produce no text; the keysym identifies them.
pub fn press(k: *Keyboard, keycode: u32) Press {
    const state = k.state orelse return .{};
    var p: Press = .{ .keysym = xkb.xkb_state_key_get_one_sym(state, keycode) };
    var len: c_int = 0;
    composed: {
        const c = k.compose orelse break :composed;
        if (xkb.xkb_compose_state_feed(c, p.keysym) != xkb.XKB_COMPOSE_FEED_ACCEPTED) break :composed;
        switch (xkb.xkb_compose_state_get_status(c)) {
            xkb.XKB_COMPOSE_COMPOSING => {
                p.composing = true;
                return p;
            },
            xkb.XKB_COMPOSE_COMPOSED => {
                len = xkb.xkb_compose_state_get_utf8(c, &p.text_buf, p.text_buf.len);
                const sym = xkb.xkb_compose_state_get_one_sym(c);
                if (sym != 0) p.keysym = sym;
                xkb.xkb_compose_state_reset(c);
                p.text_len = clampLen(len, p.text_buf.len);
                return p;
            },
            xkb.XKB_COMPOSE_CANCELLED => {
                // The key ended an invalid sequence and is consumed.
                xkb.xkb_compose_state_reset(c);
                p.composing = true;
                return p;
            },
            else => {},
        }
    }
    p.latin = k.latin(keycode, p.keysym);
    len = xkb.xkb_state_key_get_utf8(state, keycode, &p.text_buf, p.text_buf.len);
    p.text_len = clampLen(len, p.text_buf.len);
    if (p.text_len == 1 and (p.text_buf[0] < 0x20 or p.text_buf[0] == 0x7f)) p.text_len = 0;
    return p;
}

/// xkb returns the untruncated length; the buffer holds at most size - 1
/// bytes plus a NUL.
fn clampLen(len: c_int, size: usize) u8 {
    if (len <= 0) return 0;
    return @intCast(@min(@as(usize, @intCast(len)), size - 1));
}

const testing = std.testing;

fn testKeyboard() !Keyboard {
    return testLayout("us", "");
}

/// A keyboard with a keymap compiled from XKB names, as the headless
/// backend makes one, or the test skipped where xkeyboard-config
/// (xkb-data) is not installed.
fn testLayout(layout: [*:0]const u8, variant: [*:0]const u8) !Keyboard {
    const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_ENVIRONMENT_NAMES) orelse return error.SkipZigTest;
    var k: Keyboard = .{ .context = ctx };
    const keymap = keymapFromNames(ctx, layout, variant) orelse {
        xkb.xkb_context_unref(ctx);
        return error.SkipZigTest;
    };
    try k.useKeymap(keymap);
    return k;
}

fn freeKeyboard(k: *Keyboard) void {
    const ctx = k.context;
    k.deinit();
    xkb.xkb_context_unref(ctx);
}

// evdev codes + 8
const key_a = 30 + 8;
const key_e = 18 + 8;
const key_apostrophe = 40 + 8;
const key_c = 46 + 8;
const key_return = 28 + 8;

test "text, modifiers, and control keys" {
    var k = try testKeyboard();
    defer freeKeyboard(&k);

    try testing.expectEqualStrings("a", k.press(key_a).text());
    try testing.expect(k.repeats(key_a));

    // Shift (mask from the keymap, as a compositor would send).
    const shift: u32 = @as(u32, 1) << @intCast(k.mod_index[0]);
    k.updateMask(shift, 0, 0, 0);
    try testing.expect(k.mods().shift);
    try testing.expect(!k.mods().ctrl);
    try testing.expectEqualStrings("A", k.press(key_a).text());

    // Ctrl+C produces ETX from xkb; siv reports only the keysym.
    const ctrl: u32 = @as(u32, 1) << @intCast(k.mod_index[1]);
    k.updateMask(ctrl, 0, 0, 0);
    const p = k.press(key_c);
    try testing.expectEqual(@as(u8, 0), p.text_len);
    try testing.expectEqual(@as(u32, 'c'), p.keysym);
    k.updateMask(0, 0, 0, 0);
    try testing.expectEqual(@as(u8, 0), k.press(key_return).text_len);
}

test "compose sequences produce composed text" {
    var k = try testKeyboard();
    defer freeKeyboard(&k);

    // <apostrophe> <e> : é, with apostrophe standing in for a dead key.
    const rules = "<apostrophe> <e> : \"é\" eacute\n";
    const table = xkb.xkb_compose_table_new_from_buffer(k.context, rules, rules.len, "C", xkb.XKB_COMPOSE_FORMAT_TEXT_V1, xkb.XKB_COMPOSE_COMPILE_NO_FLAGS) orelse
        return error.SkipZigTest;
    defer xkb.xkb_compose_table_unref(table);
    k.setComposeTable(table);

    const first = k.press(key_apostrophe);
    try testing.expect(first.composing);
    try testing.expectEqual(@as(u8, 0), first.text_len);
    const second = k.press(key_e);
    try testing.expect(!second.composing);
    try testing.expectEqualStrings("é", second.text());
    try testing.expectEqual(@as(u32, 0xe9), second.keysym); // XKB_KEY_eacute

    // An invalid continuation cancels and consumes the key.
    _ = k.press(key_apostrophe);
    const cancelled = k.press(key_a);
    try testing.expect(cancelled.composing);
    try testing.expectEqual(@as(u8, 0), cancelled.text_len);
    try testing.expectEqualStrings("a", k.press(key_a).text());
}

test "keys that type no Latin letter or digit stand for one (D44)" {
    const Case = struct {
        layout: [*:0]const u8,
        variant: [*:0]const u8 = "",
        group: u32 = 0,
        /// evdev code
        code: u32,
        shift: bool = false,
        keysym: u32,
        latin: u32,
    };
    const cases = [_]Case{
        // A Latin layout keeps its labels, punctuation included.
        .{ .layout = "us", .code = 46, .keysym = 'c', .latin = 0 },
        .{ .layout = "us", .code = 39, .keysym = ';', .latin = 0 },
        // Russian alone: the US position, at the shift level held.
        .{ .layout = "ru", .code = 46, .keysym = 0x6d3, .latin = 'c' }, // Cyrillic_es
        .{ .layout = "ru", .code = 46, .shift = true, .keysym = 0x6f3, .latin = 'C' },
        .{ .layout = "ru", .code = 4, .shift = true, .keysym = 0x6b0, .latin = '#' }, // numerosign
        .{ .layout = "ru", .code = 26, .keysym = 0x6c8, .latin = '[' }, // Cyrillic_ha
        // Б stands for the comma Russian types only with Shift; Ю not for
        // the period it types unshifted on the slash key, whose period
        // keeps its label.
        .{ .layout = "ru", .code = 51, .keysym = 0x6c2, .latin = ',' },
        .{ .layout = "ru", .code = 52, .keysym = 0x6c0, .latin = 0 },
        .{ .layout = "ru", .code = 53, .keysym = '.', .latin = 0 },
        // Greek: the semicolon and final sigma on Q and W.
        .{ .layout = "gr", .code = 46, .keysym = 0x7f8, .latin = 'c' }, // Greek_psi
        .{ .layout = "gr", .code = 16, .keysym = ';', .latin = 'q' },
        .{ .layout = "gr", .code = 17, .keysym = 0x7f3, .latin = 'w' }, // Greek_finalsmallsigma
        // Hebrew: slash on Q; Shift types Latin capitals; ת not a comma,
        // which Hebrew types on the apostrophe key.
        .{ .layout = "il", .code = 16, .keysym = '/', .latin = 'q' },
        .{ .layout = "il", .code = 46, .keysym = 0xce1, .latin = 'c' }, // hebrew_bet
        .{ .layout = "il", .code = 46, .shift = true, .keysym = 'C', .latin = 0 },
        .{ .layout = "il", .code = 51, .keysym = 0xcfa, .latin = 0 }, // hebrew_taw
        // AZERTY: letters follow the label, the number row is its digits.
        .{ .layout = "fr", .variant = "azerty", .code = 16, .keysym = 'a', .latin = 0 },
        .{ .layout = "fr", .variant = "azerty", .code = 17, .keysym = 'z', .latin = 0 },
        .{ .layout = "fr", .variant = "azerty", .code = 2, .keysym = '&', .latin = '1' },
        .{ .layout = "fr", .variant = "azerty", .code = 3, .keysym = 0xe9, .latin = '2' }, // eacute
        .{ .layout = "fr", .variant = "azerty", .code = 50, .keysym = ',', .latin = 0 },
        // Dvorak: C is on I; the apostrophe on Q is not a second q.
        .{ .layout = "us", .variant = "dvorak", .code = 23, .keysym = 'c', .latin = 0 },
        .{ .layout = "us", .variant = "dvorak", .code = 46, .keysym = 'j', .latin = 0 },
        .{ .layout = "us", .variant = "dvorak", .code = 16, .keysym = '\'', .latin = 0 },
        // A Latin second group: its key, at the shift level held.
        .{ .layout = "ru,us", .code = 46, .keysym = 0x6d3, .latin = 'c' },
        .{ .layout = "ru,us", .code = 46, .shift = true, .keysym = 0x6f3, .latin = 'C' },
        .{ .layout = "ru,us", .group = 1, .code = 46, .keysym = 'c', .latin = 0 },
        // The first Latin group in the keymap's order: Dvorak's q on the
        // X key, not the second US group's x (Qt's example).
        .{ .layout = "us,ru,us", .variant = "dvorak,,", .group = 1, .code = 45, .keysym = 0x6de, .latin = 'q' }, // Cyrillic_che
        .{ .layout = "us,ru,us", .variant = "dvorak,,", .group = 1, .code = 46, .keysym = 0x6d3, .latin = 'j' },
        // Turkish: ı is not a second i, which Turkish types elsewhere.
        .{ .layout = "tr", .code = 23, .keysym = 0x2b9, .latin = 0 }, // idotless
    };
    for (cases) |c| {
        var k = try testLayout(c.layout, c.variant);
        defer freeKeyboard(&k);
        k.setMods(.{ .shift = c.shift, .ctrl = true }, c.group);
        const p = k.press(c.code + 8);
        errdefer std.debug.print("{s}({s}) group {d}, key {d}, shift {}: keysym 0x{x}, latin 0x{x}\n", .{ c.layout, c.variant, c.group, c.code, c.shift, p.keysym, p.latin });
        try testing.expectEqual(c.keysym, p.keysym);
        try testing.expectEqual(c.latin, p.latin);
        try testing.expectEqual(c.latin, k.latin(c.code + 8, k.keysym(c.code + 8)));
    }
}
