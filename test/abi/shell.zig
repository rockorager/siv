//! The desktop shell through the exports on the headless backend (D31):
//! outputs and hotplug, layer windows and their popups, the session lock,
//! toplevel and workspace lists, idle watches, and the blur region.

const std = @import("std");
const abi = @import("abi");
const platform = @import("platform");
const compositor = @import("compositor");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const ok = harness.ok;
const Harness = harness.Harness;
const A = abi.application;

fn onHeadless(h: *Harness, comptime func: anytype, args: anytype) !@typeInfo(@TypeOf(func)).@"fn".return_type.? {
    const self = try h.internal();
    const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    const Ctx = struct {
        args: @TypeOf(args),
        out: R = undefined,
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const x: *@This() = @ptrCast(@alignCast(ctx));
            x.out = @call(.auto, func, .{comp.platform.headless} ++ x.args);
        }
    };
    var ctx: Ctx = .{ .args = args };
    try self.app.comp.call(&ctx, Ctx.run);
    return ctx.out;
}

/// Waits until the application and the compositor are idle: every frame
/// owed is presented, blur regions included.
fn settle(h: *Harness) !void {
    var settled = false;
    try ok(c.siv_test_settle(h.app, 5000, &settled));
    try testing.expect(settled);
}

fn idOf(window: t.Window) !platform.WindowId {
    return (try A.App.window(@backingInt(window), A.window_tag)).win.id;
}

fn alive(window: t.Window) bool {
    const w = A.App.window(@backingInt(window), A.window_tag) catch return false;
    return !w.dead;
}

/// Window events of the windows a test made.
const Events = struct {
    resized: u32 = 0,
    closed: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    fn onEvent(ud: ?*anyopaque, _: t.Window, e: *const t.WindowEvent) callconv(.c) bool {
        const self: *Events = @ptrCast(@alignCast(ud.?));
        switch (e.type) {
            .resized => {
                self.resized += 1;
                self.width = e.width;
                self.height = e.height;
            },
            .closed => self.closed += 1,
            else => {},
        }
        return false;
    }
};

/// Outputs as the output callback reported them.
const Outputs = struct {
    names: [4][16]u8 = undefined,
    lens: [4]usize = @splat(0),
    handles: [4]t.Output = @splat(.null),
    scales: [4]u32 = @splat(0),
    removed: u32 = 0,

    fn onOutput(ud: ?*anyopaque, e: *const t.OutputEvent) callconv(.c) void {
        const self: *Outputs = @ptrCast(@alignCast(ud.?));
        const name = e.name.?[0..e.name_len];
        switch (e.type) {
            .added => for (&self.handles, 0..) |*slot, i| if (slot.* == .null) {
                slot.* = e.output;
                @memcpy(self.names[i][0..name.len], name);
                self.lens[i] = name.len;
                self.scales[i] = e.scale;
                return;
            },
            .removed => {
                self.removed += 1;
                for (&self.handles) |*slot| if (slot.* == e.output) {
                    slot.* = .null;
                };
            },
            else => {},
        }
    }

    fn find(self: *const Outputs, name: []const u8) t.Output {
        for (self.handles, 0..) |h, i| if (h != .null and std.mem.eql(u8, self.names[i][0..self.lens[i]], name)) return h;
        return .null;
    }
};

fn bar(height: u32, ev: *Events) t.LayerDesc {
    return .{ .namespace = "bar", .namespace_len = 3, .anchor = .{ .top = true, .left = true, .right = true }, .height = height, .flags = .{ .auto_exclusive = true }, .on_event = Events.onEvent, .user_data = ev };
}

test "layer windows: placed by their anchors, resized by the compositor, with popups and a frameless role" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var caps: t.Capabilities = .{};
    try ok(c.siv_app_get_capabilities(h.app, &caps));
    try testing.expect(caps.layers and caps.lock and caps.toplevels and caps.workspaces and caps.idle and !caps.blur);

    // A zero size needs both anchors of its axis.
    var window: t.Window = .null;
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_layer_create(h.app, &.{ .anchor = .{ .top = true, .left = true }, .height = 30 }, &window));

    var ev: Events = .{};
    var desc = bar(30, &ev);
    try ok(c.siv_layer_create(h.app, &desc, &window));
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(window, &txn));
    const root = c.siv_window_get_root(window);
    c.siv_set_visual(txn, root, &.{ .background = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1 } });
    c.siv_set_semantics(txn, root, &.{ .role = .toolbar, .label = "Panel", .label_len = 5 });
    try ok(c.siv_txn_commit(txn));
    try settle(&h);
    // It spans the 1920 px output along the top edge and reserves its height.
    var size: t.Size = undefined;
    try ok(c.siv_window_get_size(window, &size));
    try testing.expectEqual(t.Size{ .width = 1920, .height = 30 }, size);
    const placed = (try onHeadless(&h, platform.Headless.layerOf, .{try idOf(window)})).?;
    try testing.expectEqual(@as(i32, 0), placed.y);
    try testing.expectEqualStrings("bar", placed.namespace);
    try testing.expectEqual(@as(i32, 30), placed.state.zone(1920, 30));
    try testing.expect(placed.state.layer == .top);
    // Not a frame: assistive technology sees a window, with the role the
    // application gave its root.
    const w = try A.App.window(@backingInt(window), A.window_tag);
    try testing.expect(w.win.ui.frameless);
    var node: t.TestNode = undefined;
    var found = false;
    try ok(c.siv_test_find(window, &.{ .role = .toolbar, .name = "Panel", .name_len = 5 }, &found, &node));
    try testing.expect(found);
    // Window calls about toplevels do not apply; layer calls do not apply
    // to toplevels.
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_window_set_layer(h.window, &desc));

    // Moved to the bottom edge and made taller: the compositor resizes it.
    desc.anchor = .{ .bottom = true, .left = true, .right = true };
    desc.height = 40;
    desc.layer = .overlay;
    try ok(c.siv_window_set_layer(window, &desc));
    try settle(&h);
    try testing.expectEqual(@as(u32, 40), ev.height);
    const moved = (try onHeadless(&h, platform.Headless.layerOf, .{try idOf(window)})).?;
    try testing.expectEqual(@as(i32, 1080 - 40), moved.y);
    try testing.expect(moved.state.layer == .overlay);

    // A menu from the bar: a popup of the layer window, kept on the output
    // (it flips above the bar at the bottom edge).
    var popup: t.Window = .null;
    try ok(c.siv_popup_create(window, &.{ .width = 120, .height = 80 }, &popup));
    try ok(c.siv_popup_show(popup));
    try settle(&h);
    try testing.expectEqual(popup, c.siv_test_get_popup(h.app));
    const ps = (try A.App.window(@backingInt(popup), A.window_tag)).win.state;
    try testing.expectEqual(@as(i32, -80), ps.popup.?.y);
    c.siv_window_destroy(popup);

    // Layer windows do not keep the application running, nor end it.
    c.siv_window_destroy(h.window);
    h.window = .null;
    try settle(&h);
    try testing.expect(alive(window));
    c.siv_window_destroy(window);
}

test "outputs are reported and hotplugged; a layer window on a removed output is closed" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var outs: Outputs = .{};
    try ok(c.siv_app_watch_outputs(h.app, Outputs.onOutput, null, &outs));
    try settle(&h);
    try testing.expect(outs.find("HEADLESS-1") != .null);

    try ok(c.siv_test_add_output(h.app, "HEADLESS-2", 10, 2560, 1440, 2));
    try settle(&h);
    const second = outs.find("HEADLESS-2");
    try testing.expect(second != .null);
    try testing.expectEqual(@as(u32, 2), outs.scales[1]);

    // A dock on the second output's right edge, in its logical pixels.
    var ev: Events = .{};
    var window: t.Window = .null;
    try ok(c.siv_layer_create(h.app, &.{ .output = second, .anchor = .{ .right = true, .top = true, .bottom = true }, .width = 64, .margin_right = 8, .on_event = Events.onEvent, .user_data = &ev }, &window));
    try settle(&h);
    var size: t.Size = undefined;
    try ok(c.siv_window_get_size(window, &size));
    try testing.expectEqual(t.Size{ .width = 64, .height = 720 }, size);
    var scale: f64 = 0;
    try ok(c.siv_window_get_scale(window, &scale));
    try testing.expectEqual(@as(f64, 2), scale);
    const placed = (try onHeadless(&h, platform.Headless.layerOf, .{try idOf(window)})).?;
    // The second output is right of the first (1920 logical pixels).
    try testing.expectEqual(@as(i32, 1920 + 1280 - 8 - 64), placed.x);

    try ok(c.siv_test_remove_output(h.app, "HEADLESS-2", 10));
    try settle(&h);
    try testing.expectEqual(@as(u32, 1), outs.removed);
    try testing.expect(outs.find("HEADLESS-2") == .null);
    try testing.expectEqual(@as(u32, 1), ev.closed);
    try testing.expect(!alive(window));
    // The handle is invalid now.
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_layer_create(h.app, &.{ .output = second, .width = 10, .height = 10 }, &window));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_test_remove_output(h.app, "HEADLESS-2", 10));
}

/// A lock as its callbacks saw it.
const LockLog = struct {
    windows: [4]t.Window = @splat(.null),
    outputs: [4]t.Output = @splat(.null),
    count: usize = 0,
    locked: u32 = 0,
    denied: u32 = 0,
    finished: u32 = 0,
    /// Window events of the lock windows.
    window_events: Events = .{},

    fn onLock(ud: ?*anyopaque, _: t.Lock, e: *const t.LockEvent) callconv(.c) void {
        const self: *LockLog = @ptrCast(@alignCast(ud.?));
        switch (e.type) {
            .window => {
                self.windows[self.count] = e.window;
                self.outputs[self.count] = e.output;
                self.count += 1;
                // A password field, as a lock screen has.
                var txn: t.Txn = .null;
                _ = c.siv_txn_begin(e.window, &txn);
                _ = c.siv_editor(txn, c.siv_window_get_root(e.window), .{ .masked = true });
                _ = c.siv_txn_commit(txn);
            },
            .locked => self.locked += 1,
            .denied => self.denied += 1,
            .finished => self.finished += 1,
            _ => {},
        }
    }

    fn onWindow(ud: ?*anyopaque, w: t.Window, e: *const t.WindowEvent) callconv(.c) bool {
        const self: *LockLog = @ptrCast(@alignCast(ud.?));
        return Events.onEvent(&self.window_events, w, e);
    }
};

test "the session lock: a window per output that follows hotplug, locked, unlocked" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var outs: Outputs = .{};
    try ok(c.siv_app_watch_outputs(h.app, Outputs.onOutput, null, &outs));
    try settle(&h);

    var log: LockLog = .{};
    var lock: t.Lock = .null;
    try ok(c.siv_lock_create(h.app, &.{ .on_event = LockLog.onLock, .on_window_event = LockLog.onWindow, .user_data = &log }, &lock));
    var second: t.Lock = .null;
    try testing.expectEqual(t.Result.error_busy, c.siv_lock_create(h.app, null, &second));
    try settle(&h);
    try testing.expectEqual(@as(usize, 1), log.count);
    try testing.expectEqual(outs.find("HEADLESS-1"), log.outputs[0]);
    try testing.expectEqual(@as(u32, 1), log.locked);
    var locked = false;
    try ok(c.siv_test_is_locked(h.app, &locked));
    try testing.expect(locked);
    // It covers its output.
    var size: t.Size = undefined;
    try ok(c.siv_window_get_size(log.windows[0], &size));
    try testing.expectEqual(t.Size{ .width = 1920, .height = 1080 }, size);
    try testing.expect(try onHeadless(&h, platform.Headless.isLockWindow, .{try idOf(log.windows[0])}));
    var node: t.TestNode = undefined;
    var found = false;
    try ok(c.siv_test_find(log.windows[0], &.{ .role = .text_input }, &found, &node));
    try testing.expect(found);

    // A new output gets a lock window; when it goes, the window goes.
    try ok(c.siv_test_add_output(h.app, "HEADLESS-2", 10, 1280, 720, 1));
    try settle(&h);
    try testing.expectEqual(@as(usize, 2), log.count);
    try testing.expectEqual(outs.find("HEADLESS-2"), log.outputs[1]);
    try ok(c.siv_test_remove_output(h.app, "HEADLESS-2", 10));
    try settle(&h);
    try testing.expectEqual(@as(u32, 1), log.window_events.closed);
    try testing.expect(!alive(log.windows[1]));
    try testing.expect(alive(log.windows[0]));

    // Unlocking ends it: its windows and handle go.
    try ok(c.siv_lock_unlock(lock));
    try testing.expect(!alive(log.windows[0]));
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_lock_unlock(lock));
    try settle(&h);
    try ok(c.siv_test_is_locked(h.app, &locked));
    try testing.expect(!locked);
}

test "a second client's lock is denied; a lock left behind is taken over" {
    var a: Harness = .{};
    try a.start(200, 100, null, null);
    defer a.stop();
    var b: Harness = .{};
    try b.start(200, 100, null, null);
    defer b.stop();

    var log_a: LockLog = .{};
    var lock_a: t.Lock = .null;
    try ok(c.siv_lock_create(a.app, &.{ .on_event = LockLog.onLock, .user_data = &log_a }, &lock_a));
    try settle(&a);
    try testing.expectEqual(@as(u32, 1), log_a.locked);

    var log_b: LockLog = .{};
    var lock_b: t.Lock = .null;
    try ok(c.siv_lock_create(b.app, &.{ .on_event = LockLog.onLock, .user_data = &log_b }, &lock_b));
    try settle(&b);
    try testing.expectEqual(@as(u32, 1), log_b.denied);
    try testing.expectEqual(@as(u32, 0), log_b.locked);
    c.siv_lock_destroy(lock_b);

    // The first locker goes away without unlocking: still locked.
    c.siv_lock_destroy(lock_a);
    try settle(&a);
    var locked = false;
    try ok(c.siv_test_is_locked(a.app, &locked));
    try testing.expect(locked);

    // A new locker takes over, and unlocks.
    log_b = .{};
    try ok(c.siv_lock_create(b.app, &.{ .on_event = LockLog.onLock, .user_data = &log_b }, &lock_b));
    try settle(&b);
    try testing.expectEqual(@as(u32, 1), log_b.locked);
    try ok(c.siv_lock_unlock(lock_b));
    try ok(c.siv_test_is_locked(b.app, &locked));
    try testing.expect(!locked);
}

/// What toplevel and workspace lists reported.
const ListLog = struct {
    added: u32 = 0,
    changed: u32 = 0,
    removed: u32 = 0,
    last: [32]u8 = undefined,
    last_len: usize = 0,
    handles: [8]u64 = @splat(0),
    states: [8]u32 = @splat(0),
    outputs: [8]usize = @splat(0),

    fn slot(self: *ListLog, handle: u64) usize {
        for (self.handles, 0..) |x, i| if (x == handle) return i;
        for (&self.handles, 0..) |*x, i| if (x.* == 0) {
            x.* = handle;
            return i;
        };
        unreachable;
    }

    fn count(self: *ListLog, kind: u32, text: []const u8) void {
        switch (kind) {
            0 => self.added += 1,
            1 => self.changed += 1,
            else => self.removed += 1,
        }
        self.last_len = @min(text.len, self.last.len);
        @memcpy(self.last[0..self.last_len], text[0..self.last_len]);
    }

    fn onToplevel(ud: ?*anyopaque, _: t.ToplevelList, e: *const t.ToplevelEvent) callconv(.c) void {
        const self: *ListLog = @ptrCast(@alignCast(ud.?));
        self.count(@intCast(@backingInt(e.type)), e.title.?[0..e.title_len]);
        const i = self.slot(@backingInt(e.toplevel));
        self.states[i] = @bitCast(e.states);
        self.outputs[i] = e.outputs_count;
    }

    fn onWorkspace(ud: ?*anyopaque, _: t.WorkspaceList, e: *const t.WorkspaceEvent) callconv(.c) void {
        const self: *ListLog = @ptrCast(@alignCast(ud.?));
        self.count(@intCast(@backingInt(e.type)), e.name.?[0..e.name_len]);
        const i = self.slot(@backingInt(e.workspace));
        self.states[i] = @bitCast(e.states);
        self.outputs[i] = e.outputs_count;
    }
};

test "toplevel lists report other clients' windows and act on them" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var outs: Outputs = .{};
    try ok(c.siv_app_watch_outputs(h.app, Outputs.onOutput, null, &outs));
    try settle(&h);
    var term: u32 = 0;
    var editor: u32 = 0;
    try ok(c.siv_test_add_toplevel(h.app, "foot", 4, "foot", 4, outs.find("HEADLESS-1"), &term));
    try ok(c.siv_test_add_toplevel(h.app, "notes.txt", 9, "org.siv.Editor", 14, .null, &editor));

    var log: ListLog = .{};
    var list: t.ToplevelList = .null;
    try ok(c.siv_toplevel_list_create(h.app, &.{ .on_event = ListLog.onToplevel, .user_data = &log }, &list));
    var other: t.ToplevelList = .null;
    try testing.expectEqual(t.Result.error_busy, c.siv_toplevel_list_create(h.app, null, &other));
    try settle(&h);
    try testing.expectEqual(@as(u32, 2), log.added);
    const term_h: t.Toplevel = @fromBackingInt(log.handles[0]);
    const editor_h: t.Toplevel = @fromBackingInt(log.handles[1]);
    try testing.expectEqual(@as(usize, 1), log.outputs[0]);
    const managed: t.ToplevelStates = .{ .managed = true };
    try testing.expectEqual(@as(u32, @bitCast(managed)), log.states[0]);

    // The compositor changes one; then the user activates the other from
    // the task list, which deactivates the first.
    try ok(c.siv_test_set_toplevel(h.app, term, "vim", 3, .{ .activated = true }));
    try settle(&h);
    try testing.expectEqualStrings("vim", log.last[0..log.last_len]);
    try ok(c.siv_toplevel_activate(editor_h));
    try settle(&h);
    const activated: t.ToplevelStates = .{ .activated = true, .managed = true };
    try testing.expectEqual(@as(u32, @bitCast(activated)), log.states[1]);
    try testing.expectEqual(@as(u32, @bitCast(managed)), log.states[0]);
    try ok(c.siv_toplevel_set_minimized(editor_h, true));
    try settle(&h);
    const minimized: t.ToplevelStates = .{ .minimized = true, .managed = true };
    try testing.expectEqual(@as(u32, @bitCast(minimized)), log.states[1]);

    // Closing it removes it, and its handle goes with it.
    try ok(c.siv_toplevel_close(term_h));
    try settle(&h);
    try testing.expectEqual(@as(u32, 1), log.removed);
    try testing.expectEqualStrings("vim", log.last[0..log.last_len]);
    try testing.expectEqual(t.Result.error_invalid_handle, c.siv_toplevel_activate(term_h));
    try ok(c.siv_test_remove_toplevel(h.app, editor));
    try settle(&h);
    try testing.expectEqual(@as(u32, 2), log.removed);
    c.siv_toplevel_list_destroy(list);
}

test "workspace lists report workspaces per output and activate them" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var outs: Outputs = .{};
    try ok(c.siv_app_watch_outputs(h.app, Outputs.onOutput, null, &outs));
    try settle(&h);
    const out = outs.find("HEADLESS-1");
    var ids: [3]u32 = undefined;
    for (&ids, [_][]const u8{ "1", "2", "3" }) |*id, name| try ok(c.siv_test_add_workspace(h.app, name.ptr, name.len, out, id));

    var log: ListLog = .{};
    var list: t.WorkspaceList = .null;
    try ok(c.siv_workspace_list_create(h.app, &.{ .on_event = ListLog.onWorkspace, .user_data = &log }, &list));
    try settle(&h);
    try testing.expectEqual(@as(u32, 3), log.added);
    try testing.expectEqual(@as(usize, 1), log.outputs[0]);
    const active: t.WorkspaceStates = .{ .active = true };
    try testing.expectEqual(@as(u32, @bitCast(active)), log.states[0]);
    try testing.expectEqual(@as(u32, 0), log.states[1]);

    try ok(c.siv_workspace_activate(@fromBackingInt(log.handles[1])));
    try settle(&h);
    try testing.expectEqual(@as(u32, 0), log.states[0]);
    try testing.expectEqual(@as(u32, @bitCast(active)), log.states[1]);

    try ok(c.siv_test_remove_workspace(h.app, ids[2]));
    try settle(&h);
    try testing.expectEqual(@as(u32, 1), log.removed);
    try testing.expectEqualStrings("3", log.last[0..log.last_len]);
    c.siv_workspace_list_destroy(list);
}

const IdleLog = struct {
    idle: ?bool = null,
    changes: u32 = 0,
    fn onIdle(ud: ?*anyopaque, _: t.IdleWatch, idle: bool) callconv(.c) void {
        const self: *IdleLog = @ptrCast(@alignCast(ud.?));
        self.idle = idle;
        self.changes += 1;
    }
};

test "idle watches follow the user, held off by inhibitors unless they ignore them" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var plain: IdleLog = .{};
    var strict: IdleLog = .{};
    var w1: t.IdleWatch = .null;
    var w2: t.IdleWatch = .null;
    try ok(c.siv_idle_watch_create(h.app, &.{ .timeout_ms = 300_000, .on_event = IdleLog.onIdle, .user_data = &plain }, &w1));
    try ok(c.siv_idle_watch_create(h.app, &.{ .timeout_ms = 60_000, .flags = .{ .ignore_inhibitors = true }, .on_event = IdleLog.onIdle, .user_data = &strict }, &w2));
    defer c.siv_idle_watch_destroy(w2);

    // A video inhibits idling.
    var inhibition: t.Inhibition = .null;
    try ok(c.siv_inhibit(h.app, h.window, .{ .idle = true }, "video", 5, &inhibition));
    try ok(c.siv_test_set_idle(h.app, true));
    try settle(&h);
    try testing.expectEqual(@as(?bool, null), plain.idle);
    try testing.expectEqual(@as(?bool, true), strict.idle);
    // The video stops: idle now.
    c.siv_inhibition_destroy(inhibition);
    try settle(&h);
    try testing.expectEqual(@as(?bool, true), plain.idle);
    try ok(c.siv_test_set_idle(h.app, false));
    try settle(&h);
    try testing.expectEqual(@as(?bool, false), plain.idle);
    try testing.expectEqual(@as(?bool, false), strict.idle);
    // A destroyed watch hears nothing more.
    c.siv_idle_watch_destroy(w1);
    try ok(c.siv_test_set_idle(h.app, true));
    try settle(&h);
    try testing.expectEqual(@as(u32, 2), plain.changes);
    try testing.expectEqual(@as(u32, 3), strict.changes);
}

fn blurRects(window: t.Window, out: []t.Rect) ![]t.Rect {
    var n: usize = 0;
    try ok(c.siv_test_get_blur_region_count(window, &n));
    for (out[0..n], 0..) |*r, i| try ok(c.siv_test_get_blur_rect(window, i, r));
    return out[0..n];
}

fn bounds(rects: []const t.Rect) t.Rect {
    var x0: f32 = std.math.inf(f32);
    var y0: f32 = std.math.inf(f32);
    var x1: f32 = -std.math.inf(f32);
    var y1: f32 = -std.math.inf(f32);
    for (rects) |r| {
        x0 = @min(x0, r.x);
        y0 = @min(y0, r.y);
        x1 = @max(x1, r.x + r.width);
        y1 = @max(y1, r.y + r.height);
    }
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

test "the blur region: marked nodes' rounded boxes, following transforms and compositor scrolling, only where the compositor blurs" {
    var h: Harness = .{};
    try h.start(300, 200, null, null);
    defer h.stop();
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_get_root(h.window);
    const column = c.siv_flex(txn, root, &.{ .axis = .column });
    // A frosted card with rounded corners, translucent.
    const card = c.siv_box(txn, column);
    c.siv_set_layout(txn, card, &.{ .width = .{ .unit = .px, .value = 120 }, .height = .{ .unit = .px, .value = 60 } });
    c.siv_set_visual(txn, card, &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 0.5 }, .radius = .{ .top_start = 12, .top_end = 12, .bottom_end = 12, .bottom_start = 12 }, .flags = .{ .window_blur = true } });
    // A scroll area below it with a frosted row in its content.
    const scroll = c.siv_scroll(txn, column, .vertical);
    c.siv_set_layout(txn, scroll, &.{ .width = .{ .unit = .px, .value = 200 }, .height = .{ .unit = .px, .value = 100 } });
    const content = c.siv_flex(txn, scroll, &.{ .axis = .column });
    const spacer = c.siv_box(txn, content);
    c.siv_set_layout(txn, spacer, &.{ .height = .{ .unit = .px, .value = 50 } });
    const row = c.siv_box(txn, content);
    c.siv_set_layout(txn, row, &.{ .width = .{ .unit = .px, .value = 200 }, .height = .{ .unit = .px, .value = 30 } });
    c.siv_set_visual(txn, row, &.{ .flags = .{ .window_blur = true } });
    const tail = c.siv_box(txn, content);
    c.siv_set_layout(txn, tail, &.{ .height = .{ .unit = .px, .value = 300 } });
    try ok(c.siv_txn_commit(txn));
    try settle(&h);
    var buf: [64]t.Rect = undefined;
    // The compositor cannot blur yet: no region, and the capability says so.
    try testing.expectEqual(@as(usize, 0), (try blurRects(h.window, &buf)).len);

    try ok(c.siv_test_set_blur(h.app, true));
    try settle(&h);
    var caps: t.Capabilities = .{};
    try ok(c.siv_app_get_capabilities(h.app, &caps));
    try testing.expect(caps.blur);
    var rects = try blurRects(h.window, &buf);
    // The card's rounded box (corners stepped inside the curve), and the
    // row at 60 + 50 = 110.
    try testing.expectEqual(t.Rect{ .x = 0, .y = 0, .width = 120, .height = 60 }, bounds(rects[0 .. rects.len - 1]));
    try testing.expectEqual(t.Rect{ .x = 0, .y = 12, .width = 120, .height = 36 }, rects[0]);
    for (rects[0 .. rects.len - 1]) |r| {
        // Nothing in the corner squares outside the curve's chord.
        try testing.expect(!(r.x < 2 and r.y < 2));
    }
    try testing.expectEqual(t.Rect{ .x = 0, .y = 110, .width = 200, .height = 30 }, rects[rects.len - 1]);

    // Scrolled by the compositor alone, the row moves up in the region.
    try ok(c.siv_test_pointer_move(h.window, 50, 120));
    try ok(c.siv_test_scroll(h.window, 0, 30));
    try settle(&h);
    rects = try blurRects(h.window, &buf);
    const moved = rects[rects.len - 1];
    try testing.expect(moved.y < 110 and moved.y >= 60);
    // Scrolled past it: clipped by the viewport, then gone.
    try ok(c.siv_test_scroll(h.window, 0, 300));
    try settle(&h);
    rects = try blurRects(h.window, &buf);
    try testing.expectEqual(t.Rect{ .x = 0, .y = 0, .width = 120, .height = 60 }, bounds(rects));

    // A transform moves the card's region with it.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_transform(txn, card, .{ .translate_x = 50, .translate_y = 10, .scale_x = 1, .scale_y = 1 });
    try ok(c.siv_txn_commit(txn));
    try settle(&h);
    rects = try blurRects(h.window, &buf);
    try testing.expectEqual(t.Rect{ .x = 50, .y = 10, .width = 120, .height = 60 }, bounds(rects));

    // Unmarked, nothing is blurred.
    try ok(c.siv_txn_begin(h.window, &txn));
    c.siv_set_visual(txn, card, &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 0.5 } });
    try ok(c.siv_txn_commit(txn));
    try settle(&h);
    try testing.expectEqual(@as(usize, 0), (try blurRects(h.window, &buf)).len);

    // Layer windows blur too: a frosted bar.
    var ev: Events = .{};
    var window: t.Window = .null;
    var desc = bar(32, &ev);
    try ok(c.siv_layer_create(h.app, &desc, &window));
    try ok(c.siv_txn_begin(window, &txn));
    c.siv_set_visual(txn, c.siv_window_get_root(window), &.{ .background = .{ .r = 0, .g = 0, .b = 0, .a = 0.4 }, .flags = .{ .window_blur = true } });
    try ok(c.siv_txn_commit(txn));
    try settle(&h);
    rects = try blurRects(window, &buf);
    try testing.expectEqualSlices(t.Rect, &.{.{ .x = 0, .y = 0, .width = 1920, .height = 32 }}, rects);
    // The compositor stops blurring: the region is dropped.
    try ok(c.siv_test_set_blur(h.app, false));
    try settle(&h);
    try ok(c.siv_app_get_capabilities(h.app, &caps));
    try testing.expect(!caps.blur);
}
