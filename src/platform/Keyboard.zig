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

const invalid_mod: u32 = 0xffffffff;
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
    k.resetCompose();
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

pub fn repeats(k: *const Keyboard, keycode: u32) bool {
    return xkb.xkb_keymap_key_repeats(k.keymap orelse return false, keycode) != 0;
}

/// What a key press produces.
pub const Press = struct {
    keysym: u32 = 0,
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
    const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.SkipZigTest;
    var k: Keyboard = .{ .context = ctx };
    const names: xkb.struct_xkb_rule_names = .{ .rules = null, .model = null, .layout = "us", .variant = null, .options = null };
    // Needs xkeyboard-config (xkb-data); skip where it is not installed.
    const keymap = xkb.xkb_keymap_new_from_names(ctx, &names, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
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
