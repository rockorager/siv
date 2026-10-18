//! Keyboard accelerators (D34): a keysym with the modifiers held, how a
//! key event matches one, and the three ways one is written: the label
//! menus show ("Ctrl+Shift+N"), ARIA's aria-keyshortcuts ("Control+Shift+N",
//! AT-SPI's keyshortcuts attribute), and GTK's accelerator names
//! ("<Control><Shift>n", the shortcut part of AT-SPI's key binding, which
//! Orca reads).

const std = @import("std");
const platform = @import("platform");

pub const Mods = platform.Mods;

/// A key and the modifiers that must be held with it. Letters are kept
/// lower case: Shift is part of `mods`, not of the keysym.
pub const Accel = struct {
    /// An XKB keysym; 0 for none.
    keysym: u32 = 0,
    /// Shift, Ctrl, Alt, and Super only.
    mods: Mods = .{},

    pub fn of(keysym: u32, mods: Mods) Accel {
        return .{ .keysym = normalize(keysym), .mods = significant(mods) };
    }

    pub fn eql(a: Accel, b: Accel) bool {
        return a.keysym == b.keysym and @as(u8, @bitCast(a.mods)) == @as(u8, @bitCast(b.mods));
    }
};

/// The modifiers accelerators compare: not Caps Lock or Num Lock.
pub fn significant(m: Mods) Mods {
    return .{ .shift = m.shift, .ctrl = m.ctrl, .alt = m.alt, .super = m.super };
}

const iso_left_tab = 0xfe20;
const tab = 0xff09;

/// Letters lower case, so that Ctrl+Shift+N (which reports N) and the
/// accelerator written with n match; Shift+Tab's ISO_Left_Tab is Tab.
pub fn normalize(keysym: u32) u32 {
    if (keysym == iso_left_tab) return tab;
    return switch (keysym) {
        'A'...'Z' => keysym + 0x20,
        0xc0...0xd6, 0xd8...0xde => keysym + 0x20,
        else => keysym,
    };
}

/// A letter, whose case Shift chooses, rather than a symbol Shift may
/// have made (Shift+= is + on a US layout).
fn isLetter(keysym: u32) bool {
    return switch (keysym) {
        'a'...'z', 0xdf...0xf6, 0xf8...0xff => true,
        else => false,
    };
}

/// How well an accelerator matches a key event: exactly, or with the
/// event's Shift ignored because it made the symbol (Ctrl and + typed
/// as Ctrl+Shift+= on a US layout). Exact matches win.
pub const Match = enum { none, shifted, exact };

pub fn match(a: Accel, keysym: u32, mods: Mods) Match {
    const ev = Accel.of(keysym, mods);
    if (a.keysym == 0 or a.keysym != ev.keysym) return .none;
    if (a.eql(ev)) return .exact;
    // ISO_Left_Tab already says Shift.
    if (ev.mods.shift and !a.mods.shift and !isLetter(ev.keysym) and keysym != iso_left_tab) {
        var m = ev.mods;
        m.shift = false;
        if (@as(u8, @bitCast(m)) == @as(u8, @bitCast(a.mods))) return .shifted;
    }
    return .none;
}

/// A named key's spellings: label, ARIA key value, XKB keysym name.
const Named = struct { keysym: u32, label: []const u8, aria: []const u8, xkb: []const u8 };

const named = [_]Named{
    .{ .keysym = 0x20, .label = "Space", .aria = "Space", .xkb = "space" },
    .{ .keysym = 0xff08, .label = "Backspace", .aria = "Backspace", .xkb = "BackSpace" },
    .{ .keysym = 0xff09, .label = "Tab", .aria = "Tab", .xkb = "Tab" },
    .{ .keysym = 0xff0d, .label = "Enter", .aria = "Enter", .xkb = "Return" },
    .{ .keysym = 0xff13, .label = "Pause", .aria = "Pause", .xkb = "Pause" },
    .{ .keysym = 0xff14, .label = "Scroll Lock", .aria = "ScrollLock", .xkb = "Scroll_Lock" },
    .{ .keysym = 0xff1b, .label = "Esc", .aria = "Escape", .xkb = "Escape" },
    .{ .keysym = 0xff50, .label = "Home", .aria = "Home", .xkb = "Home" },
    .{ .keysym = 0xff51, .label = "Left", .aria = "ArrowLeft", .xkb = "Left" },
    .{ .keysym = 0xff52, .label = "Up", .aria = "ArrowUp", .xkb = "Up" },
    .{ .keysym = 0xff53, .label = "Right", .aria = "ArrowRight", .xkb = "Right" },
    .{ .keysym = 0xff54, .label = "Down", .aria = "ArrowDown", .xkb = "Down" },
    .{ .keysym = 0xff55, .label = "Page Up", .aria = "PageUp", .xkb = "Page_Up" },
    .{ .keysym = 0xff56, .label = "Page Down", .aria = "PageDown", .xkb = "Page_Down" },
    .{ .keysym = 0xff57, .label = "End", .aria = "End", .xkb = "End" },
    .{ .keysym = 0xff61, .label = "Print", .aria = "PrintScreen", .xkb = "Print" },
    .{ .keysym = 0xff63, .label = "Insert", .aria = "Insert", .xkb = "Insert" },
    .{ .keysym = 0xff67, .label = "Menu", .aria = "ContextMenu", .xkb = "Menu" },
    .{ .keysym = 0xff8d, .label = "Enter", .aria = "Enter", .xkb = "KP_Enter" },
    .{ .keysym = 0xffff, .label = "Delete", .aria = "Delete", .xkb = "Delete" },
    .{ .keysym = 0x1008ff1b, .label = "Search", .aria = "BrowserSearch", .xkb = "XF86Search" },
    .{ .keysym = 0x1008ff26, .label = "Back", .aria = "BrowserBack", .xkb = "XF86Back" },
    .{ .keysym = 0x1008ff27, .label = "Forward", .aria = "BrowserForward", .xkb = "XF86Forward" },
    .{ .keysym = 0x1008ff29, .label = "Refresh", .aria = "BrowserRefresh", .xkb = "XF86Refresh" },
    .{ .keysym = 0x1008ff57, .label = "Copy", .aria = "Copy", .xkb = "XF86Copy" },
    .{ .keysym = 0x1008ff58, .label = "Cut", .aria = "Cut", .xkb = "XF86Cut" },
    .{ .keysym = 0x1008ff6d, .label = "Paste", .aria = "Paste", .xkb = "XF86Paste" },
};

/// XKB's names for ASCII punctuation, by character.
fn punctuation(c: u32) []const u8 {
    const names = [_]struct { u8, []const u8 }{
        .{ '!', "exclam" },        .{ '"', "quotedbl" },     .{ '#', "numbersign" },   .{ '$', "dollar" },
        .{ '%', "percent" },       .{ '&', "ampersand" },    .{ '\'', "apostrophe" }, .{ '(', "parenleft" },
        .{ ')', "parenright" },    .{ '*', "asterisk" },     .{ '+', "plus" },         .{ ',', "comma" },
        .{ '-', "minus" },         .{ '.', "period" },       .{ '/', "slash" },        .{ ':', "colon" },
        .{ ';', "semicolon" },     .{ '<', "less" },         .{ '=', "equal" },        .{ '>', "greater" },
        .{ '?', "question" },      .{ '@', "at" },           .{ '[', "bracketleft" },  .{ '\\', "backslash" },
        .{ ']', "bracketright" },  .{ '^', "asciicircum" },  .{ '_', "underscore" },   .{ '`', "grave" },
        .{ '{', "braceleft" },     .{ '|', "bar" },          .{ '}', "braceright" },   .{ '~', "asciitilde" },
    };
    for (names) |n| if (n[0] == c) return n[1];
    return "";
}

pub const Style = enum {
    /// "Ctrl+Shift+N", for people.
    label,
    /// "Control+Shift+N", ARIA's aria-keyshortcuts.
    aria,
    /// "<Control><Shift>n", GTK's accelerator names.
    gtk,
};

/// Writes an accelerator in a style. A keysym without a name or a
/// character is written as its number.
pub fn format(a: Accel, style: Style, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const mods = [_]struct { bool, []const u8, []const u8, []const u8 }{
        .{ a.mods.ctrl, "Ctrl", "Control", "Control" },
        .{ a.mods.alt, "Alt", "Alt", "Alt" },
        .{ a.mods.shift, "Shift", "Shift", "Shift" },
        .{ a.mods.super, "Super", "Meta", "Super" },
    };
    for (mods) |m| if (m[0]) switch (style) {
        .label => try w.print("{s}+", .{m[1]}),
        .aria => try w.print("{s}+", .{m[2]}),
        .gtk => try w.print("<{s}>", .{m[3]}),
    };
    const k = a.keysym;
    for (named) |n| if (n.keysym == k) return w.writeAll(switch (style) {
        .label => n.label,
        .aria => n.aria,
        .gtk => n.xkb,
    });
    if (k >= 0xffbe and k <= 0xffe0) return w.print("F{d}", .{k - 0xffbe + 1});
    if (style == .gtk and punctuation(k).len != 0) return w.writeAll(punctuation(k));
    const cp: u21 = if (k >= 0x20 and k <= 0xff and k != 0x7f) @intCast(k) else if (k >= 0x01000100 and k <= 0x0110ffff) @intCast(k - 0x01000000) else return w.print("0x{x}", .{k});
    // Letters show in capitals, as on the keys; GTK names them in lower
    // case, as the keysym is stored.
    const shown: u21 = if (style != .gtk and isLetter(cp) and cp != 0xdf and cp != 0xff) cp - 0x20 else cp;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(shown, &buf) catch return w.print("0x{x}", .{k});
    try w.writeAll(buf[0..n]);
}

test "letters match in either case with Shift exact; symbols ignore the Shift that made them" {
    const ctrl_n = Accel.of('n', .{ .ctrl = true });
    try std.testing.expectEqual(Match.exact, match(ctrl_n, 'n', .{ .ctrl = true, .num_lock = true }));
    try std.testing.expectEqual(Match.none, match(ctrl_n, 'N', .{ .ctrl = true, .shift = true }));
    const ctrl_shift_n = Accel.of('N', .{ .ctrl = true, .shift = true });
    try std.testing.expectEqual(@as(u32, 'n'), ctrl_shift_n.keysym);
    try std.testing.expectEqual(Match.exact, match(ctrl_shift_n, 'N', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Match.none, match(ctrl_shift_n, 'n', .{ .ctrl = true }));
    // Ctrl and + is Ctrl+Shift+= on a US layout, reporting +.
    const ctrl_plus = Accel.of('+', .{ .ctrl = true });
    try std.testing.expectEqual(Match.shifted, match(ctrl_plus, '+', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Match.none, match(ctrl_plus, '+', .{ .ctrl = true, .alt = true }));
    // Shift+Tab reports ISO_Left_Tab; Tab alone does not match it.
    const shift_tab = Accel.of(tab, .{ .shift = true });
    try std.testing.expectEqual(Match.exact, match(shift_tab, iso_left_tab, .{ .shift = true }));
    try std.testing.expectEqual(Match.none, match(Accel.of(tab, .{}), iso_left_tab, .{ .shift = true }));
}

test "accelerators are written for people, ARIA, and GTK" {
    const cases = [_]struct { Accel, []const u8, []const u8, []const u8 }{
        .{ Accel.of('n', .{ .ctrl = true, .shift = true }), "Ctrl+Shift+N", "Control+Shift+N", "<Control><Shift>n" },
        .{ Accel.of(0xffff, .{ .shift = true }), "Shift+Delete", "Shift+Delete", "<Shift>Delete" },
        .{ Accel.of(0xff51, .{ .alt = true }), "Alt+Left", "Alt+ArrowLeft", "<Alt>Left" },
        .{ Accel.of(0xffbf, .{}), "F2", "F2", "F2" },
        .{ Accel.of('+', .{ .ctrl = true }), "Ctrl++", "Control++", "<Control>plus" },
        .{ Accel.of('1', .{ .ctrl = true, .super = true }), "Ctrl+Super+1", "Control+Meta+1", "<Control><Super>1" },
        .{ Accel.of(0xe9, .{ .ctrl = true }), "Ctrl+É", "Control+É", "<Control>é" },
    };
    for (cases) |c| {
        inline for (.{ Style.label, Style.aria, Style.gtk }, 1..) |style, i| {
            var buf: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try format(c[0], style, &w);
            try std.testing.expectEqualStrings(c[i], w.buffered());
        }
    }
}
