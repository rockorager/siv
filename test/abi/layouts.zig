//! Shortcuts on any keyboard layout (D44) through the exports on the
//! headless backend, with keymaps compiled from XKB names
//! (siv_test_set_keymap) and physical keys pressed through them
//! (siv_test_press_key): accelerators, the editor's keys, the undo keys,
//! and dialog mnemonics on Latin layouts whose letters sit elsewhere
//! (AZERTY, Dvorak: the label counts), on layouts without Latin letters
//! (Russian, Greek, Hebrew: the US position counts), and with a Latin
//! second group (ru,us: its letters count).

const std = @import("std");
const abi = @import("abi");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const ok = harness.ok;
const Harness = harness.Harness;

/// A layout and the evdev codes of the keys that type, or stand for,
/// the letters the tests press.
const Layout = struct {
    layout: []const u8,
    variant: []const u8 = "",
    group: u32 = 0,
    a: u32 = 30,
    c: u32 = 46,
    o: u32 = 24,
    q: u32 = 16,
    v: u32 = 47,
    x: u32 = 45,
    y: u32 = 21,
    z: u32 = 44,
    /// A key that must not undo: where Z sits on a US keyboard, when the
    /// layout's label there is another letter.
    not_z: ?u32 = null,
};

const layouts = [_]Layout{
    .{ .layout = "us" },
    .{ .layout = "ru" },
    .{ .layout = "gr" },
    .{ .layout = "il" },
    .{ .layout = "fr", .variant = "azerty", .a = 16, .q = 30, .z = 17, .not_z = 44 },
    .{ .layout = "us", .variant = "dvorak", .c = 23, .o = 31, .q = 45, .v = 52, .x = 48, .y = 20, .z = 53, .not_z = 44 },
    .{ .layout = "ru,us" },
    .{ .layout = "ru,us", .group = 1 },
};

const ctrl: t.Modifiers = .{ .ctrl = true };

/// One action's invocations.
const Ran = struct {
    count: u32 = 0,

    fn on(ud: ?*anyopaque, _: *const t.ActionEvent) callconv(.c) void {
        const r: *Ran = @ptrCast(@alignCast(ud.?));
        r.count += 1;
    }
};

/// What the undo step did: undos and redos.
const Steps = struct {
    undone: u32 = 0,
    redone: u32 = 0,

    fn undo(ud: ?*anyopaque, _: t.Undo) callconv(.c) void {
        const s: *Steps = @ptrCast(@alignCast(ud.?));
        s.undone += 1;
    }

    fn redo(ud: ?*anyopaque, _: t.Undo) callconv(.c) void {
        const s: *Steps = @ptrCast(@alignCast(ud.?));
        s.redone += 1;
    }
};

/// The last key press the root saw, as an application's handler gets it.
const Seen = struct {
    keysym: t.Key = .none,
    shortcut_key: t.Key = .none,
    copy_match: t.AccelMatch = .none,
    activates: u32 = 0,

    fn onKey(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const s: *Seen = @ptrCast(@alignCast(ud.?));
        if (!ev.flags.pressed) return .pass;
        s.keysym = ev.keysym;
        s.shortcut_key = ev.shortcut_key;
        s.copy_match = c.siv_accel_matches(accel('c', ctrl), ev);
        return .pass;
    }

    fn onActivate(ud: ?*anyopaque, _: t.Node, _: *const t.Event) callconv(.c) t.EventResult {
        const s: *Seen = @ptrCast(@alignCast(ud.?));
        s.activates += 1;
        return .pass;
    }
};

fn accel(key: u32, mods: t.Modifiers) t.Accel {
    return .{ .key = @enumFromInt(@as(i32, @bitCast(key))), .modifiers = mods };
}

fn begin(window: t.Window) !t.Txn {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(window, &txn));
    return txn;
}

/// Starts a window with a keymap, or skips where xkeyboard-config is
/// not installed.
fn start(h: *Harness, l: Layout) !void {
    try h.start(320, 200, null, null);
    switch (c.siv_test_set_keymap(h.app, l.layout.ptr, l.layout.len, l.variant.ptr, l.variant.len)) {
        .ok => {},
        .error_unavailable => {
            h.stop();
            return error.SkipZigTest;
        },
        else => |r| return ok(r),
    }
}

fn press(h: *Harness, l: Layout, code: u32, mods: t.Modifiers) !void {
    try ok(c.siv_test_press_key(h.window, code + 8, l.group, mods));
    try h.settle();
}

fn text(n: t.Node, buf: []u8) ![]const u8 {
    var len: usize = 0;
    try ok(c.siv_node_get_text(n, buf.ptr, buf.len, &len));
    return buf[0..len];
}

test "accelerators, editor keys, undo keys, and mnemonics on any layout" {
    for (layouts) |l| {
        errdefer std.debug.print("layout {s}({s}), group {d}\n", .{ l.layout, l.variant, l.group });
        var h: Harness = .{};
        try start(&h, l);
        defer h.stop();
        var copy: Ran = .{};
        var quit: Ran = .{};
        var a: t.Action = .null;
        try ok(c.siv_action_create(h.app, &.{ .name = "copy", .name_len = 4, .accels = &.{accel('c', ctrl)}, .accels_count = 1 }, Ran.on, null, &copy, &a));
        try ok(c.siv_action_create(h.app, &.{ .name = "quit", .name_len = 4, .accels = &.{accel('q', ctrl)}, .accels_count = 1 }, Ran.on, null, &quit, &a));
        var stack: t.Undo = .null;
        try ok(c.siv_undo_create(h.app, null, &stack));
        defer c.siv_undo_destroy(stack);
        var steps: Steps = .{};
        var seen: Seen = .{};

        const root = c.siv_window_get_root(h.window);
        var txn = try begin(h.window);
        const col = c.siv_flex(txn, root, &.{ .axis = .column });
        const field = c.siv_text_field(txn, col, &.{});
        const button = c.siv_push_button(txn, col, &.{ .label = "Files", .label_len = 5 });
        c.siv_set_undo(txn, root, stack);
        c.siv_on(txn, root, .key, Seen.onKey, null, &seen);
        try ok(c.siv_txn_commit(txn));
        try h.settle();

        // The editor's keys: select all, cut, paste, undo, redo. Copy is
        // the editor's too, not the application's.
        try ok(c.siv_node_focus(field));
        try ok(c.siv_test_type(h.window, "hello", 5));
        try h.settle();
        var buf: [16]u8 = undefined;
        try press(&h, l, l.a, ctrl);
        var caret: u32 = 9;
        var anchor: u32 = 9;
        try ok(c.siv_node_get_selection(field, &caret, &anchor));
        try testing.expectEqual(@as(u32, 0), @min(caret, anchor));
        try testing.expectEqual(@as(u32, 5), @max(caret, anchor));
        try press(&h, l, l.c, ctrl);
        try testing.expectEqual(@as(u32, 0), copy.count);
        try press(&h, l, l.x, ctrl);
        try testing.expectEqualStrings("", try text(field, &buf));
        try press(&h, l, l.v, ctrl);
        try press(&h, l, l.v, ctrl);
        try testing.expectEqualStrings("hellohello", try text(field, &buf));
        try press(&h, l, l.z, ctrl);
        try testing.expectEqualStrings("hello", try text(field, &buf));
        try press(&h, l, l.y, ctrl);
        try testing.expectEqualStrings("hellohello", try text(field, &buf));
        try press(&h, l, l.z, ctrl);
        try press(&h, l, l.z, .{ .ctrl = true, .shift = true });
        try testing.expectEqualStrings("hellohello", try text(field, &buf));
        // Ctrl+Q is not an editor's key: it reaches the accelerator.
        try press(&h, l, l.q, ctrl);
        try testing.expectEqual(@as(u32, 1), quit.count);
        try testing.expectEqual(@as(u32, 0), steps.undone);

        // Elsewhere: the application's accelerators, and the undo stack
        // attached to the root.
        try ok(c.siv_node_focus(button));
        try press(&h, l, l.c, ctrl);
        try testing.expectEqual(@as(u32, 1), copy.count);
        try testing.expectEqual(@as(t.Key, @enumFromInt('c')), seen.shortcut_key);
        try testing.expect(seen.copy_match != .none);
        try testing.expectEqual(seen.keysym == @as(t.Key, @enumFromInt('c')), seen.copy_match == .exact);
        try press(&h, l, l.q, ctrl);
        try testing.expectEqual(@as(u32, 2), quit.count);
        try ok(c.siv_undo_push(stack, &.{ .undo = Steps.undo, .redo = Steps.redo, .user_data = &steps }));
        if (l.not_z) |code| {
            try press(&h, l, code, ctrl);
            try testing.expectEqual(@as(u32, 0), steps.undone);
        }
        try press(&h, l, l.z, ctrl);
        try testing.expectEqual(@as(u32, 1), steps.undone);
        try press(&h, l, l.z, .{ .ctrl = true, .shift = true });
        try testing.expectEqual(@as(u32, 1), steps.redone);
        try press(&h, l, l.z, ctrl);
        try press(&h, l, l.y, ctrl);
        try testing.expectEqual(@as(u32, 2), steps.undone);
        try testing.expectEqual(@as(u32, 2), steps.redone);

        // A dialog's mnemonic: the key alone.
        txn = try begin(h.window);
        const dialog = c.siv_dialog(txn, root, &.{ .title = "Replace?", .title_len = 8 });
        const ok_button = c.siv_push_button(txn, c.siv_widget_get_part(dialog, .actions, 0), &.{ .label = "OK", .label_len = 2, .mnemonic = 'o' });
        c.siv_on(txn, ok_button, .activate, Seen.onActivate, null, &seen);
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        try press(&h, l, l.c, .{});
        try testing.expectEqual(@as(u32, 0), seen.activates);
        try press(&h, l, l.o, .{});
        try testing.expectEqual(@as(u32, 1), seen.activates);
    }
}

test "a key's own keysym wins over its Latin equivalent; AZERTY's number row is digits" {
    // Hebrew types / on the Q key: Ctrl+/ there, Ctrl+Q only without one.
    {
        var h: Harness = .{};
        try start(&h, .{ .layout = "il" });
        defer h.stop();
        var slash: Ran = .{};
        var quit: Ran = .{};
        var a: t.Action = .null;
        try ok(c.siv_action_create(h.app, &.{ .name = "quit", .name_len = 4, .accels = &.{accel('q', ctrl)}, .accels_count = 1 }, Ran.on, null, &quit, &a));
        try ok(c.siv_action_create(h.app, &.{ .name = "comment", .name_len = 7, .accels = &.{accel('/', ctrl)}, .accels_count = 1 }, Ran.on, null, &slash, &a));
        try h.settle();
        try press(&h, .{ .layout = "il" }, 16, ctrl);
        try testing.expectEqual(@as(u32, 1), slash.count);
        try testing.expectEqual(@as(u32, 0), quit.count);
        c.siv_action_destroy(a);
        try press(&h, .{ .layout = "il" }, 16, ctrl);
        try testing.expectEqual(@as(u32, 1), quit.count);
    }
    // AZERTY's & key is Ctrl+1, É Ctrl+2.
    {
        var h: Harness = .{};
        const fr: Layout = .{ .layout = "fr", .variant = "azerty" };
        try start(&h, fr);
        defer h.stop();
        var view: Ran = .{};
        var a: t.Action = .null;
        const keys = [_]t.Accel{ accel('1', ctrl), .{ .key = @enumFromInt('2'), .modifiers = ctrl, .target = 1 } };
        try ok(c.siv_action_create(h.app, &.{ .name = "view", .name_len = 4, .kind = .choice, .accels = &keys, .accels_count = 2 }, Ran.on, null, &view, &a));
        try h.settle();
        try press(&h, fr, 3, ctrl);
        var state: t.ActionState = undefined;
        try ok(c.siv_action_get_state(a, &state));
        try testing.expectEqual(@as(f64, 1), state.value);
        try press(&h, fr, 2, ctrl);
        try ok(c.siv_action_get_state(a, &state));
        try testing.expectEqual(@as(f64, 0), state.value);
        try testing.expectEqual(@as(u32, 2), view.count);
    }
}
