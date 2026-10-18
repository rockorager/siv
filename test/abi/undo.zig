//! Undo stacks through the exports on the headless backend (D35): steps,
//! groups, merging, the limit, the clean mark, change notifications,
//! callbacks that touch the stack, and the undo keys' routing between
//! editors and the stacks attached to nodes.

const std = @import("std");
const abi = @import("abi");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const ok = harness.ok;
const Harness = harness.Harness;

const ctrl: @import("platform").Mods = .{ .ctrl = true };
const ctrl_shift: @import("platform").Mods = .{ .ctrl = true, .shift = true };

/// What the steps did, as text: "-a" for a's undo, "+a" for its redo,
/// and which user data was released.
const Log = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    freed: [256]u8 = undefined,
    freed_len: usize = 0,
    /// Called from a step's undo: what siv_undo_push answered.
    push_in_callback: ?t.Result = null,
    destroy_in_callback: bool = false,
    stack: t.Undo = .null,
    changes: u32 = 0,
    event: t.UndoEvent = .{},
    labels: [2][32]u8 = undefined,
    stack_freed: u32 = 0,

    fn text(l: *const Log) []const u8 {
        return l.buf[0..l.len];
    }

    fn freedText(l: *const Log) []const u8 {
        return l.freed[0..l.freed_len];
    }

    fn reset(l: *Log) void {
        l.len = 0;
        l.freed_len = 0;
    }

    fn onChange(ud: ?*anyopaque, _: t.Undo, ev: *const t.UndoEvent) callconv(.c) void {
        const l: *Log = @ptrCast(@alignCast(ud.?));
        l.changes += 1;
        l.event = ev.*;
        const u = ev.undo_label.?[0..ev.undo_label_len];
        const r = ev.redo_label.?[0..ev.redo_label_len];
        @memcpy(l.labels[0][0..u.len], u);
        @memcpy(l.labels[1][0..r.len], r);
        l.event.undo_label = &l.labels[0];
        l.event.redo_label = &l.labels[1];
    }

    fn onStackFreed(ud: ?*anyopaque) callconv(.c) void {
        const l: *Log = @ptrCast(@alignCast(ud.?));
        l.stack_freed += 1;
    }
};

/// One step's user data.
const Rec = struct {
    log: *Log,
    name: u8,

    fn note(r: *Rec, sign: u8) void {
        r.log.buf[r.log.len] = sign;
        r.log.buf[r.log.len + 1] = r.name;
        r.log.len += 2;
    }

    fn undo(ud: ?*anyopaque, u: t.Undo) callconv(.c) void {
        const r: *Rec = @ptrCast(@alignCast(ud.?));
        r.note('-');
        const l = r.log;
        if (l.push_in_callback != null) l.push_in_callback = c.siv_undo_push(u, &.{ .undo = undo, .redo = redo, .destroy = free, .user_data = ud });
        if (l.destroy_in_callback) c.siv_undo_destroy(u);
    }

    fn redo(ud: ?*anyopaque, _: t.Undo) callconv(.c) void {
        const r: *Rec = @ptrCast(@alignCast(ud.?));
        r.note('+');
    }

    fn free(ud: ?*anyopaque) callconv(.c) void {
        const r: *Rec = @ptrCast(@alignCast(ud.?));
        r.log.freed[r.log.freed_len] = r.name;
        r.log.freed_len += 1;
    }
};

fn push(u: t.Undo, rec: *Rec, text: []const u8, merge: u64) !void {
    try ok(c.siv_undo_push(u, &.{ .undo = Rec.undo, .redo = Rec.redo, .destroy = Rec.free, .user_data = rec, .label = text.ptr, .label_len = text.len, .merge = merge }));
}

fn count(u: t.Undo, redo: bool) !u32 {
    var n: u32 = 0;
    try ok(c.siv_undo_get_count(u, redo, &n));
    return n;
}

fn isClean(u: t.Undo) !bool {
    var v = false;
    try ok(c.siv_undo_is_clean(u, &v));
    return v;
}

fn label(u: t.Undo, redo: bool, buf: []u8) ![]const u8 {
    var len: usize = 0;
    try ok(c.siv_undo_get_label(u, redo, buf.ptr, buf.len, &len));
    return buf[0..len];
}

fn recs(log: *Log, comptime names: []const u8) [names.len]Rec {
    var r: [names.len]Rec = undefined;
    for (names, 0..) |n, i| r[i] = .{ .log = log, .name = n };
    return r;
}

test "undo stacks: steps, redo dropped by a push, the limit, labels, and the clean mark" {
    var h: Harness = .{};
    try h.start(50, 50, null, null);
    defer h.stop();
    var log: Log = .{};
    var r = recs(&log, "abcde");
    var u: t.Undo = .null;
    try ok(c.siv_undo_create(h.app, &.{ .limit = 3, .destroy = Log.onStackFreed, .user_data = &log }, &u));
    var buf: [32]u8 = undefined;

    // Nothing to undo or redo does nothing.
    try ok(c.siv_undo_undo(u));
    try ok(c.siv_undo_redo(u));
    try testing.expect(try isClean(u));
    try testing.expectEqualStrings("", try label(u, false, &buf));

    try push(u, &r[0], "Rename", 0);
    try push(u, &r[1], "Delete", 0);
    try testing.expect(!try isClean(u));
    try testing.expectEqual(2, try count(u, false));
    try testing.expectEqualStrings("Delete", try label(u, false, &buf));
    // A short buffer gets the start and the full length.
    var len: usize = 0;
    try ok(c.siv_undo_get_label(u, false, &buf, 3, &len));
    try testing.expectEqual(6, len);
    try testing.expectEqualStrings("Del", buf[0..3]);

    try ok(c.siv_undo_set_clean(u));
    try ok(c.siv_undo_undo(u));
    try testing.expectEqualStrings("-b", log.text());
    try testing.expect(!try isClean(u));
    try testing.expectEqual(1, try count(u, false));
    try testing.expectEqual(1, try count(u, true));
    try testing.expectEqualStrings("Rename", try label(u, false, &buf));
    try testing.expectEqualStrings("Delete", try label(u, true, &buf));
    try ok(c.siv_undo_redo(u));
    try testing.expectEqualStrings("-b+b", log.text());
    try testing.expect(try isClean(u));

    // Undone steps go when a step is pushed, and with them the clean
    // position they held.
    try ok(c.siv_undo_undo(u));
    try ok(c.siv_undo_undo(u));
    try testing.expectEqualStrings("-b+b-b-a", log.text());
    try push(u, &r[2], "Move", 0);
    try testing.expectEqualStrings("ab", log.freedText());
    try testing.expectEqual(0, try count(u, true));
    try testing.expect(!try isClean(u));
    try ok(c.siv_undo_undo(u));
    try testing.expect(!try isClean(u));
    try ok(c.siv_undo_redo(u));

    // Past the limit the oldest goes, with the clean mark it held.
    log.reset();
    try ok(c.siv_undo_set_clean(u));
    try push(u, &r[3], "D", 0);
    try push(u, &r[0], "E", 0);
    try testing.expectEqualStrings("", log.freedText());
    try push(u, &r[1], "F", 0);
    try testing.expectEqualStrings("c", log.freedText());
    try testing.expectEqual(3, try count(u, false));
    for (0..3) |_| try ok(c.siv_undo_undo(u));
    try testing.expectEqualStrings("-b-a-d", log.text());
    // The clean state, after c, is where the oldest step left starts.
    try testing.expect(try isClean(u));
    for (0..3) |_| try ok(c.siv_undo_redo(u));
    try push(u, &r[2], "G", 0);
    try testing.expectEqualStrings("cd", log.freedText());
    for (0..3) |_| try ok(c.siv_undo_undo(u));
    try testing.expect(!try isClean(u));

    // Clearing keeps a stack clean only if it was.
    try ok(c.siv_undo_clear(u));
    try testing.expectEqualStrings("cdabc", log.freedText());
    try testing.expectEqual(0, try count(u, true));
    try testing.expect(!try isClean(u));
    try ok(c.siv_undo_set_clean(u));
    try ok(c.siv_undo_clear(u));
    try testing.expect(try isClean(u));

    // A step without its callbacks is refused and released at once.
    log.reset();
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_undo_push(u, &.{ .undo = Rec.undo, .destroy = Rec.free, .user_data = &r[4] }));
    try testing.expectEqualStrings("e", log.freedText());

    // Destroying releases the steps, then the stack's own user data.
    try push(u, &r[0], "", 0);
    c.siv_undo_destroy(u);
    try testing.expectEqualStrings("ea", log.freedText());
    try testing.expectEqual(1, log.stack_freed);
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_undo_undo(u));
    c.siv_undo_destroy(u);
    try testing.expectEqual(1, log.stack_freed);
}

test "undo stacks: merging keeps the first undo and the last redo, groups undo as one" {
    var h: Harness = .{};
    try h.start(50, 50, null, null);
    defer h.stop();
    var log: Log = .{};
    var r = recs(&log, "abcdefgh");
    var u: t.Undo = .null;
    try ok(c.siv_undo_create(h.app, null, &u));
    var buf: [32]u8 = undefined;

    // A run with one key is one step: undo with the first step's data,
    // redo with the last one's; the ones between are released as they
    // are replaced.
    try push(u, &r[0], "Volume", 7);
    try push(u, &r[1], "Volume", 7);
    try push(u, &r[2], "Volume 3", 7);
    try testing.expectEqualStrings("b", log.freedText());
    try testing.expectEqual(1, try count(u, false));
    try testing.expectEqualStrings("Volume 3", try label(u, false, &buf));
    try ok(c.siv_undo_undo(u));
    try ok(c.siv_undo_redo(u));
    try testing.expectEqualStrings("-a+c", log.text());

    // Another key, or the clean state, starts a new step.
    try push(u, &r[3], "Other", 8);
    try ok(c.siv_undo_set_clean(u));
    try push(u, &r[4], "Other", 8);
    try testing.expectEqual(3, try count(u, false));

    // A group is one step: undone newest first, redone oldest first.
    // Its steps merge among themselves, not with the step before.
    log.reset();
    try ok(c.siv_undo_begin_group(u, "Move 3 Files", 12));
    try push(u, &r[5], "f", 8);
    try ok(c.siv_undo_begin_group(u, "Inner", 5));
    try push(u, &r[6], "g", 0);
    try ok(c.siv_undo_end_group(u));
    try push(u, &r[7], "h", 0);
    try testing.expectEqual(t.Result.error_busy, c.siv_undo_undo(u));
    try testing.expectEqual(t.Result.error_busy, c.siv_undo_set_clean(u));
    try testing.expect(!try isClean(u));
    try testing.expectEqual(3, try count(u, false));
    try ok(c.siv_undo_end_group(u));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_undo_end_group(u));
    try testing.expectEqual(4, try count(u, false));
    try testing.expectEqualStrings("Move 3 Files", try label(u, false, &buf));
    try ok(c.siv_undo_undo(u));
    try ok(c.siv_undo_undo(u));
    try testing.expectEqualStrings("-h-g-f-e", log.text());
    try testing.expect(try isClean(u));
    try ok(c.siv_undo_redo(u));
    try ok(c.siv_undo_redo(u));
    try testing.expectEqualStrings("-h-g-f-e+e+f+g+h", log.text());

    // An empty group leaves no step.
    try ok(c.siv_undo_begin_group(u, "Nothing", 7));
    try ok(c.siv_undo_end_group(u));
    try testing.expectEqual(4, try count(u, false));
    try testing.expectEqualStrings("", log.freedText());

    // Every user data is released once with the application, an open
    // group's too.
    try ok(c.siv_undo_begin_group(u, "Open", 4));
    var x: Rec = .{ .log = &log, .name = 'x' };
    try push(u, &x, "", 0);
    h.stop();
    h.app = .null;
    std.mem.sort(u8, log.freed[0..log.freed_len], {}, std.sort.asc(u8));
    try testing.expectEqualStrings("acdefghx", log.freedText());
}

test "undo stacks: callbacks cannot change their stack, may destroy it, and on_change runs once per change burst" {
    var h: Harness = .{};
    try h.start(50, 50, null, null);
    defer h.stop();
    var log: Log = .{};
    var r = recs(&log, "ab");
    var u: t.Undo = .null;
    try ok(c.siv_undo_create(h.app, &.{ .on_change = Log.onChange, .destroy = Log.onStackFreed, .user_data = &log }, &u));

    try push(u, &r[0], "Rename", 0);
    try push(u, &r[1], "Delete", 0);
    try testing.expectEqual(0, log.changes);
    try ok(c.siv_app_dispatch(h.app, 0));
    try testing.expectEqual(1, log.changes);
    try testing.expectEqual(2, log.event.undo_count);
    try testing.expectEqual(0, log.event.redo_count);
    try testing.expectEqualStrings("Delete", log.event.undo_label.?[0..log.event.undo_label_len]);
    try testing.expectEqual(0, log.event.redo_label_len);
    try testing.expect(!log.event.flags.clean);
    try ok(c.siv_app_dispatch(h.app, 0));
    try testing.expectEqual(1, log.changes);

    // The stack refuses changes from a step's callback, and the step's
    // data pushed again is released once.
    log.push_in_callback = .ok;
    try ok(c.siv_undo_undo(u));
    try testing.expectEqual(t.Result.error_busy, log.push_in_callback.?);
    log.push_in_callback = null;
    try testing.expectEqualStrings("b", log.freedText());
    try ok(c.siv_app_dispatch(h.app, 0));
    try testing.expectEqual(2, log.changes);
    try testing.expectEqual(1, log.event.undo_count);
    try testing.expectEqual(1, log.event.redo_count);
    try testing.expectEqualStrings("Rename", log.event.undo_label.?[0..log.event.undo_label_len]);
    try testing.expectEqualStrings("Delete", log.event.redo_label.?[0..log.event.redo_label_len]);
    try ok(c.siv_undo_set_clean(u));
    try ok(c.siv_app_dispatch(h.app, 0));
    try testing.expect(log.event.flags.clean);

    // Destroyed from its own step's undo, the stack goes when the
    // callback returns; nothing is released twice, and no change is told.
    log.reset();
    log.destroy_in_callback = true;
    try ok(c.siv_undo_undo(u));
    try testing.expectEqualStrings("-a", log.text());
    try testing.expectEqual(2, log.freed_len);
    try testing.expectEqual(1, log.stack_freed);
    try ok(c.siv_app_dispatch(h.app, 0));
    try testing.expectEqual(3, log.changes);
}

/// A window with an editor and a focusable box under a container, each
/// stack counting its undos and redos.
const Keys = struct {
    log: Log = .{},
    recs: [2]Rec = undefined,
    outer: t.Undo = .null,
    inner: t.Undo = .null,
    container: t.Node = .null,
    editor: t.Node = .null,
    plain: t.Node = .null,
    box: t.Node = .null,
    prevent: bool = false,

    fn onKey(ud: ?*anyopaque, _: t.Node, ev: *const t.Event) callconv(.c) t.EventResult {
        const k: *Keys = @ptrCast(@alignCast(ud.?));
        const z = @backingInt(ev.keysym) == 'z' or @backingInt(ev.keysym) == 'Z';
        return if (k.prevent and z) .prevent else .pass;
    }
};

fn editorText(n: t.Node, buf: []u8) ![]const u8 {
    var len: usize = 0;
    try ok(c.siv_node_get_text(n, buf.ptr, buf.len, &len));
    return buf[0..len];
}

test "undo keys: a focused editor keeps them; elsewhere the nearest attached stack, not past a modal node" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var k: Keys = .{};
    k.recs = .{ .{ .log = &k.log, .name = 'o' }, .{ .log = &k.log, .name = 'i' } };
    try ok(c.siv_undo_create(h.app, null, &k.outer));
    try ok(c.siv_undo_create(h.app, null, &k.inner));
    try push(k.outer, &k.recs[0], "", 0);
    try push(k.inner, &k.recs[1], "", 0);
    const root = c.siv_window_get_root(h.window);
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_undo(txn, root, k.outer);
    k.container = c.siv_box(txn, root);
    c.siv_set_undo(txn, k.container, k.inner);
    k.editor = c.siv_editor(txn, k.container, .{});
    k.plain = c.siv_editor(txn, k.container, .{ .no_undo = true });
    k.box = c.siv_box(txn, k.container);
    _ = c.siv_set_semantics(txn, k.box, &.{ .role = .button, .flags = .{ .focusable = true } });
    c.siv_on(txn, root, .key, Keys.onKey, null, &k);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    var buf: [32]u8 = undefined;

    // Nothing focused: the root's stack.
    try h.typeKey('z', "z", ctrl);
    try h.settle();
    try testing.expectEqualStrings("-o", k.log.text());

    // A focused node: the stack nearest it; Ctrl+Shift+Z and Ctrl+Y redo.
    try ok(c.siv_node_focus(k.box));
    try h.typeKey('z', "z", ctrl);
    try h.typeKey('Z', "Z", ctrl_shift);
    try h.typeKey('z', "z", ctrl);
    try h.typeKey('y', "y", ctrl);
    try h.settle();
    try testing.expectEqualStrings("-o-i+i-i+i", k.log.text());

    // An editor keeps the keys for its own text, even with nothing left
    // to undo.
    try ok(c.siv_node_focus(k.editor));
    try h.typeKey('a', "a", .{});
    try h.typeKey('z', "z", ctrl);
    try h.settle();
    try testing.expectEqualStrings("", try editorText(k.editor, &buf));
    try h.typeKey('z', "z", ctrl);
    try h.settle();
    try testing.expectEqualStrings("-o-i+i-i+i", k.log.text());
    try h.typeKey('y', "y", ctrl);
    try h.settle();
    try testing.expectEqualStrings("a", try editorText(k.editor, &buf));
    try testing.expectEqualStrings("-o-i+i-i+i", k.log.text());

    // One whose application keeps the history lets them through.
    try ok(c.siv_node_focus(k.plain));
    try h.typeKey('z', "z", ctrl);
    try h.settle();
    try testing.expectEqualStrings("-o-i+i-i+i-i", k.log.text());

    // A handler that prevents the key keeps it from every stack.
    k.prevent = true;
    try ok(c.siv_node_focus(k.box));
    try h.typeKey('Z', "Z", ctrl_shift);
    try h.settle();
    try testing.expectEqualStrings("-o-i+i-i+i-i", k.log.text());
    k.prevent = false;

    // A destroyed stack no longer takes them: the next one up does.
    c.siv_undo_destroy(k.inner);
    try h.typeKey('y', "y", ctrl);
    try h.settle();
    try testing.expectEqualStrings("-o-i+i-i+i-i+o", k.log.text());

    // A modal node keeps them from the stacks above it, and detaching
    // leaves the window with none.
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_set_semantics(txn, k.container, &.{ .flags = .{ .modal = true } });
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.typeKey('z', "z", ctrl);
    try h.settle();
    try testing.expectEqualStrings("-o-i+i-i+i-i+o", k.log.text());
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_set_semantics(txn, k.container, &.{});
    c.siv_set_undo(txn, root, .null);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try h.typeKey('z', "z", ctrl);
    try h.settle();
    try testing.expectEqualStrings("-o-i+i-i+i-i+o", k.log.text());

    // A stack of another application is refused.
    var other: Harness = .{};
    try other.start(10, 10, null, null);
    defer other.stop();
    var foreign: t.Undo = .null;
    try ok(c.siv_undo_create(other.app, null, &foreign));
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_undo(txn, root, foreign);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_txn_commit(txn));
}

/// Undo wired to an action (D34) the way an application does it: the
/// action runs the stack, and the stack's on_change enables the action.
const Wired = struct {
    log: Log = .{},
    stack: t.Undo = .null,
    action: t.Action = .null,
    runs: u32 = 0,

    fn onChange(ud: ?*anyopaque, _: t.Undo, ev: *const t.UndoEvent) callconv(.c) void {
        const w: *Wired = @ptrCast(@alignCast(ud.?));
        ok(c.siv_action_set_enabled(w.action, ev.undo_count != 0)) catch unreachable;
    }

    fn onAction(ud: ?*anyopaque, _: *const t.ActionEvent) callconv(.c) void {
        const w: *Wired = @ptrCast(@alignCast(ud.?));
        w.runs += 1;
        ok(c.siv_undo_undo(w.stack)) catch unreachable;
    }

    fn enabled(w: *const Wired) !bool {
        var st: t.ActionState = .{};
        try ok(c.siv_action_get_state(w.action, &st));
        return !st.flags.disabled;
    }
};

test "undo and actions: on_change enables an Undo action; an attached stack takes Ctrl+Z before its accelerator" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var w: Wired = .{};
    var rec: Rec = .{ .log = &w.log, .name = 'a' };
    try ok(c.siv_undo_create(h.app, &.{ .on_change = Wired.onChange, .user_data = &w }, &w.stack));
    const z: t.Accel = .{ .key = @enumFromInt('z'), .modifiers = .{ .ctrl = true } };
    try ok(c.siv_action_create(h.app, &.{ .name = "undo", .name_len = 4, .flags = .{ .disabled = true }, .accels = &.{z}, .accels_count = 1 }, Wired.onAction, null, &w, &w.action));
    try h.settle();

    // A step enables the action; its key runs it, which undoes the step
    // and disables it again, so the next Ctrl+Z does nothing.
    try push(w.stack, &rec, "Rename", 0);
    try h.settle();
    try testing.expect(try w.enabled());
    try h.typeKey('z', "z", ctrl);
    try h.settle();
    try testing.expectEqualStrings("-a", w.log.text());
    try testing.expectEqual(1, w.runs);
    try testing.expect(!try w.enabled());
    try h.typeKey('z', "z", ctrl);
    try h.settle();
    try testing.expectEqual(1, w.runs);

    // Attached to the root, the stack takes the key itself.
    try ok(c.siv_undo_redo(w.stack));
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_undo(txn, c.siv_window_get_root(h.window), w.stack);
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expect(try w.enabled());
    try h.typeKey('z', "z", ctrl);
    try h.settle();
    try testing.expectEqualStrings("-a+a-a", w.log.text());
    try testing.expectEqual(1, w.runs);
    try testing.expect(!try w.enabled());
}
