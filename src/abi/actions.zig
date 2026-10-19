//! Exports for actions (D34, api_actions.zig): named commands with an
//! enabled state and a value, their accelerators, and the nodes bound to
//! them.
//!
//! An action belongs to the application or to one window. The tree
//! names a bound node's action by its handle (`ui.Node.action`), which it
//! does not interpret; the window's `ui.Window.Actions` hooks come here
//! for keys, activations, and the shortcuts that semantics expose.
//!
//! Bound nodes follow their action through the widget interface (D22,
//! widget.zig): when the action changes, each window with nodes bound to
//! it gets a transaction of its own in which their interfaces'
//! set_disabled and set_value run, at once, or when the transaction the
//! application holds open on that window ends.
//!
//! The application's actions are also the coordinator's named actions
//! (app/portals.zig), which notification buttons and
//! org.freedesktop.Application's ActivateAction invoke (D19).

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const api = @import("api.zig");
const tree = @import("tree.zig");
const widget = @import("widget.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;
const NodeId = ui.NodeId;

pub const action_tag = api.spec.handleTag("siv_action");

/// An accelerator and the target it passes.
const Key = struct { accel: ui.Accel, target: f64 };

pub const Action = struct {
    self: *App,
    handle: u64 = 0,
    index: u32,
    name: []u8,
    label: []u8,
    /// The window it belongs to, or null for the application.
    window: ?*Window,
    kind: t.ActionKind,
    disabled: bool,
    value: f64,
    keys: []Key,
    callback: ?t.ActionFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    /// Whether a node bound to it with `target` shows it on.
    fn on(a: *const Action, target: f64) bool {
        return switch (a.kind) {
            .toggle => a.value >= 0.5,
            .choice => a.value == target,
            else => false,
        };
    }
};

/// What the application keeps for actions.
pub const State = struct {
    /// By index (handle payload); null slots are reused.
    slots: std.ArrayList(?*Action) = .empty,
    /// In the order they were created: keys and enumeration go by it.
    list: std.ArrayList(*Action) = .empty,
    /// Actions whose bound nodes in a window wait for the transaction the
    /// application holds open there to end.
    pending: std.ArrayList(struct { window: *Window, action: u64 }) = .empty,
};

fn get(action: t.Action) Error!*Action {
    const self, const index = try runtime.Root.owner(App, application.app_tag, @backingInt(action), action_tag);
    return self.actions.slots.items[index] orelse error.InvalidHandle;
}

fn failed(self: ?*App, destroy: ?t.DestroyFn, user_data: ?*anyopaque, err: Error) t.Result {
    if (destroy) |d| if (self) |s| s.release(d, user_data) else d(user_data);
    return t.resultOf(err);
}

/// An accelerator from the caller: a key, and only the four modifiers.
fn readAccel(a: t.Accel) Error!Key {
    const mods = try runtime.flags(t.Modifiers, a.modifiers);
    const key: u32 = @bitCast(@intFromEnum(a.key));
    if (key == 0 or mods.caps_lock or mods.num_lock or !std.math.isFinite(a.target)) return error.InvalidArgument;
    return .{ .accel = .of(key, .{ .shift = mods.shift, .ctrl = mods.ctrl, .alt = mods.alt, .super = mods.super }), .target = a.target };
}

/// A shortcut for semantics (siv_set_shortcut): key 0 for none, the
/// target ignored.
pub fn shortcutOf(a: t.Accel) Error!ui.Accel {
    if (a.key == .none) return .{};
    var probe = a;
    probe.target = 0;
    return (try readAccel(probe)).accel;
}

fn readKeys(gpa: std.mem.Allocator, ptr: ?[*]const t.Accel, count: usize) Error![]Key {
    const raw = try runtime.array(t.Accel, ptr, count);
    const keys = try gpa.alloc(Key, raw.len);
    errdefer gpa.free(keys);
    for (raw, keys) |r, *k| k.* = try readAccel(r);
    return keys;
}

fn checkValue(kind: t.ActionKind, v: f64) Error!void {
    if (!std.math.isFinite(v)) return error.InvalidArgument;
    if (kind == .toggle and v != 0 and v != 1) return error.InvalidArgument;
}

/// The action named `name` in a scope.
fn find(self: *App, window: ?*Window, name: []const u8) ?*Action {
    for (self.actions.list.items) |a| if (a.window == window and std.mem.eql(u8, a.name, name)) return a;
    return null;
}

pub export fn siv_action_create(app: t.App, desc: ?*const t.ActionDesc, callback: ?t.ActionFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, action: ?*t.Action) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return failed(null, destroy, user_data, err);
    create(self, desc, callback, destroy, user_data, action) catch |err| return failed(self, destroy, user_data, err);
    return .ok;
}

fn create(self: *App, desc: ?*const t.ActionDesc, callback: ?t.ActionFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, out: ?*t.Action) Error!void {
    const d = try runtime.readDesc(t.ActionDesc, desc);
    var unused: t.Action = .null;
    const dest = runtime.optOut(t.Action, out, &unused);
    const name = try runtime.string(d.name, d.name_len);
    const label = try runtime.string(d.label, d.label_len);
    const kind = try runtime.enumValue(t.ActionKind, d.kind);
    const fl = try runtime.flags(t.ActionFlags, d.flags);
    try checkValue(kind, d.value);
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(label)) return error.InvalidArgument;
    const window: ?*Window = if (d.window == .null) null else blk: {
        const w = try App.window(@backingInt(d.window), application.window_tag);
        if (w.owner != self) return error.InvalidArgument;
        break :blk w;
    };
    if (find(self, window, name) != null) return error.InvalidArgument;
    const gpa = self.gpa();
    const st = &self.actions;
    const keys = try readKeys(gpa, d.accels, d.accels_count);
    errdefer gpa.free(keys);
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    const owned_label = try gpa.dupe(u8, label);
    errdefer gpa.free(owned_label);
    const index: u32 = for (st.slots.items, 0..) |s, i| {
        if (s == null) break @intCast(i);
    } else blk: {
        try st.slots.append(gpa, null);
        break :blk @intCast(st.slots.items.len - 1);
    };
    try st.list.ensureUnusedCapacity(gpa, 1);
    try self.root.handles.ensureUnusedCapacity(gpa);
    const a = try gpa.create(Action);
    errdefer gpa.destroy(a);
    a.* = .{
        .self = self,
        .index = index,
        .name = owned_name,
        .label = owned_label,
        .window = window,
        .kind = kind,
        .disabled = fl.disabled,
        .value = d.value,
        .keys = keys,
        .callback = callback,
        .destroy = destroy,
        .user_data = user_data,
    };
    // The desktop invokes the application's actions by name.
    if (window == null) try self.app.addAction(owned_name, .{ .ctx = a, .func = fromDesktop });
    a.handle = self.root.handles.insert(gpa, action_tag, index) catch unreachable;
    st.slots.items[index] = a;
    st.list.appendAssumeCapacity(a);
    dest.* = @fromBackingInt(a.handle);
}

fn destroyAction(a: *Action) void {
    const self = a.self;
    const st = &self.actions;
    const gpa = self.gpa();
    if (a.window == null) self.app.removeAction(a.name);
    _ = self.root.handles.remove(a.handle, action_tag) catch unreachable;
    st.slots.items[a.index] = null;
    if (std.mem.indexOfScalar(*Action, st.list.items, a)) |i| _ = st.list.orderedRemove(i);
    var i: usize = 0;
    while (i < st.pending.items.len) {
        if (st.pending.items[i].action == a.handle) _ = st.pending.swapRemove(i) else i += 1;
    }
    self.release(a.destroy, a.user_data);
    gpa.free(a.name);
    gpa.free(a.label);
    gpa.free(a.keys);
    gpa.destroy(a);
}

pub export fn siv_action_destroy(action: t.Action) void {
    destroyAction(get(action) catch return);
}

/// The window's actions go with it, and what waits for its transaction.
pub fn forgetWindow(w: *Window) void {
    const st = &w.owner.actions;
    var i: usize = st.list.items.len;
    while (i > 0) {
        i -= 1;
        if (i < st.list.items.len and st.list.items[i].window == w) destroyAction(st.list.items[i]);
    }
    i = 0;
    while (i < st.pending.items.len) {
        if (st.pending.items[i].window == w) _ = st.pending.swapRemove(i) else i += 1;
    }
}

/// Destroys every action, with the application.
pub fn teardown(self: *App) void {
    const st = &self.actions;
    while (st.list.items.len > 0) destroyAction(st.list.items[st.list.items.len - 1]);
    const gpa = self.gpa();
    st.slots.deinit(gpa);
    st.list.deinit(gpa);
    st.pending.deinit(gpa);
    // The windows go next, and look for their actions.
    st.* = .{};
}

pub export fn siv_action_set_enabled(action: t.Action, enabled: bool) t.Result {
    const a = get(action) catch |err| return t.resultOf(err);
    if (a.disabled == !enabled) return .ok;
    a.disabled = !enabled;
    follow(a);
    return .ok;
}

pub export fn siv_action_set_value(action: t.Action, value: f64) t.Result {
    const a = get(action) catch |err| return t.resultOf(err);
    if (a.kind == .plain) return .error_invalid_argument;
    checkValue(a.kind, value) catch |err| return t.resultOf(err);
    if (a.value == value) return .ok;
    a.value = value;
    follow(a);
    return .ok;
}

pub export fn siv_action_set_accels(action: t.Action, accels: ?[*]const t.Accel, accels_count: usize) t.Result {
    const a = get(action) catch |err| return t.resultOf(err);
    const gpa = a.self.gpa();
    const keys = readKeys(gpa, accels, accels_count) catch |err| return t.resultOf(err);
    gpa.free(a.keys);
    a.keys = keys;
    // Bound nodes expose the new shortcut with the next frame.
    for (a.self.windows.items) |slot| if (slot) |w| {
        const uw = w.uiWin();
        for (uw.bound.items) |id| if (uw.isLive(id) and uw.node(id).action == a.handle) {
            uw.dirty.semantics = true;
            uw.dirty.props = true;
            uw.requestFrame();
            break;
        };
    };
    return .ok;
}

pub export fn siv_action_activate(action: t.Action, window: t.Window, target: f64) t.Result {
    const a = get(action) catch |err| return t.resultOf(err);
    if (!std.math.isFinite(target)) return .error_invalid_argument;
    if (window != .null) {
        const w = App.window(@backingInt(window), application.window_tag) catch |err| return t.resultOf(err);
        if (w.owner != a.self) return .error_invalid_argument;
    }
    if (a.disabled) return .error_busy;
    const shown = if (a.window) |w| @as(t.Window, @fromBackingInt(w.handle)) else window;
    run(a, shown, target, .{});
    return .ok;
}

/// What the desktop adds to an invocation.
const FromDesktop = struct { target: []const u8 = "", token: []const u8 = "" };

/// Runs an action: a toggle flips and a choice takes the target, bound
/// nodes follow (also when the value stayed: a toggle bound to a choice
/// flipped itself off), then the callback runs.
fn run(a: *Action, window: t.Window, target: f64, desktop: FromDesktop) void {
    switch (a.kind) {
        .toggle => a.value = if (a.value >= 0.5) 0 else 1,
        .choice => a.value = target,
        else => {},
    }
    if (a.kind != .plain) follow(a);
    const cb = a.callback orelse return;
    const self = a.self;
    var ev: t.ActionEvent = .{
        .name = a.name.ptr,
        .name_len = a.name.len,
        .target = desktop.target.ptr,
        .target_len = desktop.target.len,
        .activation_token = desktop.token.ptr,
        .activation_token_len = desktop.token.len,
        .action = @fromBackingInt(a.handle),
        .window = window,
        .value = if (a.kind == .plain) target else a.value,
    };
    // The callback may destroy the action: nothing of it is used after.
    self.enter();
    defer self.leave();
    cb(a.user_data, &ev);
}

/// org.freedesktop.Application's ActivateAction and notification buttons
/// (app/portals.zig): enabled application actions only. A choice takes
/// the target when it is a number.
fn fromDesktop(ctx: ?*anyopaque, _: []const u8, target: []const u8, token: []const u8) void {
    const a: *Action = @ptrCast(@alignCast(ctx));
    if (a.disabled) return;
    var v: f64 = 0;
    if (a.kind == .choice) {
        v = std.fmt.parseFloat(f64, target) catch return;
        if (!std.math.isFinite(v)) return;
    }
    run(a, .null, v, .{ .target = target, .token = token });
}

// Bound nodes -------------------------------------------------------------------

/// Brings every node bound to `a` up to date, in each window that has
/// one.
fn follow(a: *Action) void {
    for (a.self.windows.items) |slot| if (slot) |w| followIn(w, a.handle);
}

fn hasBound(w: *Window, action: u64) bool {
    const uw = w.uiWin();
    for (uw.bound.items) |id| if (uw.isLive(id) and uw.node(id).action == action) return true;
    return false;
}

/// Updates the nodes of `w` bound to the action in a transaction of their
/// own, or once the open one ends.
fn followIn(w: *Window, action: u64) void {
    if (w.dead or !hasBound(w, action)) return;
    var txn: t.Txn = .null;
    if (tree.siv_txn_begin(@fromBackingInt(w.handle), &txn) != .ok) {
        const st = &w.owner.actions;
        for (st.pending.items) |p| if (p.window == w and p.action == action) return;
        st.pending.append(w.owner.gpa(), .{ .window = w, .action = action }) catch {};
        return;
    }
    const uw = w.uiWin();
    var i: usize = 0;
    // The interfaces run application code, which may bind more nodes.
    while (i < uw.bound.items.len) : (i += 1) {
        const id = uw.bound.items[i];
        if (uw.isLive(id) and uw.node(id).action == action) apply(w, txn, id);
    }
    _ = tree.siv_txn_commit(txn);
}

/// Hands a bound node its action's state through its widget interface.
pub fn apply(w: *Window, txn: t.Txn, id: NodeId) void {
    const n = w.uiWin().node(id);
    const a = get(@fromBackingInt(n.action)) catch return;
    const value: ?f64 = if (a.kind == .plain) null else if (a.on(n.action_target)) 1 else 0;
    widget.follow(w, txn, id, a.disabled, value);
}

/// A transaction on `w` ended: the bound nodes that waited for it.
pub fn txnEnded(w: *Window) void {
    if (w.dead) return;
    const st = &w.owner.actions;
    var i: usize = 0;
    while (i < st.pending.items.len) {
        const p = st.pending.items[i];
        if (p.window != w) {
            i += 1;
            continue;
        }
        _ = st.pending.swapRemove(i);
        followIn(w, p.action);
    }
}

pub export fn siv_set_action(txn: t.Txn, node: t.Node, action: t.Action, target: f64) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, tx: t.Txn, n: t.Node, act: t.Action, tg: f64) Error!void {
            const id = try tree.nodeIn(w, n);
            if (act != .null) {
                const a = try get(act);
                if (a.self != w.owner) return error.InvalidArgument;
            }
            w.txn.ut.setAction(id, @backingInt(act), tg) catch |err| return tree.mapTxn(err);
            if (act != .null) apply(w, tx, id);
        }
    }.f, .{ txn, node, action, target });
}

pub export fn siv_set_shortcut(txn: t.Txn, node: t.Node, accel: t.Accel) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, a: t.Accel) Error!void {
            const id = try tree.nodeIn(w, n);
            w.txn.ut.setShortcut(id, try shortcutOf(a)) catch |err| return tree.mapTxn(err);
        }
    }.f, .{ node, accel });
}

pub export fn siv_node_get_action(node: t.Node, action: ?*t.Action, target: ?*f64) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, out: ?*t.Action, out_target: ?*f64) Error!void {
            const w, const id = try tree.lookup(n);
            const dest = try runtime.out(t.Action, out);
            var unused: f64 = 0;
            const dest_target = runtime.optOut(f64, out_target, &unused);
            const un = w.uiWin().node(id);
            // A destroyed action binds nothing.
            const bound = if (un.action != 0 and (if (get(@fromBackingInt(un.action))) |_| true else |_| false)) un.action else 0;
            dest.* = @fromBackingInt(bound);
            dest_target.* = if (bound != 0) un.action_target else 0;
        }
    }.f(node, action, target));
}

// The window's hooks ---------------------------------------------------------------

/// Gives a new window (or popup) its actions hooks.
pub fn attach(w: *Window) void {
    w.uiWin().actions = .{ .ctx = w, .key = onKey, .invoke = onInvoke, .shortcut = onShortcut };
}

/// The window whose actions a window's keys reach: a popup's toplevel.
fn scopeOf(w: *Window) *Window {
    var cur = w;
    while (cur.parent) |p| cur = p;
    return cur;
}

/// Whether a window has an action that shadows the application's `a`.
fn shadowed(self: *App, scope: *Window, a: *const Action) bool {
    return find(self, scope, a.name) != null;
}

fn onKey(ctx: ?*anyopaque, _: *ui.Window, keysym: u32, latin: u32, mods: ui.accel.Mods, modal: bool) bool {
    const w: *Window = @ptrCast(@alignCast(ctx));
    if (w.dead) return false;
    // The inspector's keys, when enabled, before the application's (D46).
    if (@import("inspect.zig").key(w, if (latin != 0) latin else keysym, mods)) return true;
    const self = w.owner;
    const scope = scopeOf(w);
    // Exact matches first, then those through the key's Latin equivalent
    // (D44), the window's before the application's, each in the order
    // they were created.
    for ([_]ui.accel.Match{ .exact, .shifted, .latin, .latin_shifted }) |want| {
        for ([_]bool{ true, false }) |own| {
            if (own and modal) continue;
            for (self.actions.list.items) |a| {
                if (a.disabled) continue;
                if (own) {
                    if (a.window != scope) continue;
                } else if (a.window != null or shadowed(self, scope, a)) continue;
                for (a.keys) |k| if (ui.accel.match(k.accel, keysym, latin, mods) == want) {
                    run(a, @fromBackingInt(scope.handle), k.target, .{});
                    return true;
                };
            }
        }
    }
    return false;
}

fn onInvoke(ctx: ?*anyopaque, uw: *ui.Window, id: NodeId) void {
    const w: *Window = @ptrCast(@alignCast(ctx));
    if (w.dead) return;
    const n = uw.node(id);
    const a = get(@fromBackingInt(n.action)) catch return;
    if (a.disabled) return;
    run(a, @fromBackingInt(scopeOf(w).handle), n.action_target, .{});
}

fn onShortcut(ctx: ?*anyopaque, action: u64, target: f64) ui.Accel {
    _ = ctx;
    const a = get(@fromBackingInt(action)) catch return .{};
    for (a.keys) |k| if (a.kind != .choice or k.target == target) return k.accel;
    return .{};
}

// Queries --------------------------------------------------------------------------

pub export fn siv_action_get_state(action: t.Action, state: ?*t.ActionState) t.Result {
    const a = get(action) catch |err| return t.resultOf(err);
    const dest = runtime.out(t.ActionState, state) catch |err| return t.resultOf(err);
    dest.* = .{
        .window = if (a.window) |w| @fromBackingInt(w.handle) else .null,
        .value = a.value,
        .kind = a.kind,
        .flags = .{ .disabled = a.disabled },
        .accel_count = @intCast(a.keys.len),
    };
    return .ok;
}

fn copyOut(s: []const u8, ptr: ?[*]u8, cap: usize, len: ?*usize) t.Result {
    const buf = runtime.buffer(ptr, cap) catch |err| return t.resultOf(err);
    const dest = runtime.out(usize, len) catch |err| return t.resultOf(err);
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    dest.* = s.len;
    return .ok;
}

pub export fn siv_action_get_name(action: t.Action, name: ?[*]u8, name_cap: usize, len: ?*usize) t.Result {
    const a = get(action) catch |err| return t.resultOf(err);
    return copyOut(a.name, name, name_cap, len);
}

pub export fn siv_action_get_label(action: t.Action, label: ?[*]u8, label_cap: usize, len: ?*usize) t.Result {
    const a = get(action) catch |err| return t.resultOf(err);
    return copyOut(a.label, label, label_cap, len);
}

pub export fn siv_action_get_accel(action: t.Action, index: u32, accel: ?*t.Accel) t.Result {
    const a = get(action) catch |err| return t.resultOf(err);
    const dest = runtime.out(t.Accel, accel) catch |err| return t.resultOf(err);
    if (index >= a.keys.len) return .error_invalid_argument;
    const k = a.keys[index];
    const m = k.accel.mods;
    dest.* = .{
        .key = @enumFromInt(@as(i32, @bitCast(k.accel.keysym))),
        .modifiers = .{ .shift = m.shift, .ctrl = m.ctrl, .alt = m.alt, .super = m.super },
        .target = k.target,
    };
    return .ok;
}

pub export fn siv_app_get_action(app: t.App, window: t.Window, index: u32) t.Action {
    const self = App.get(@backingInt(app)) catch return .null;
    const scope: ?*Window = if (window == .null) null else blk: {
        const w = App.window(@backingInt(window), application.window_tag) catch return .null;
        if (w.owner != self) return .null;
        break :blk scopeOf(w);
    };
    var i: u32 = 0;
    if (scope) |s| for (self.actions.list.items) |a| if (a.window == s) {
        if (i == index) return @fromBackingInt(a.handle);
        i += 1;
    };
    for (self.actions.list.items) |a| if (a.window == null and (scope == null or !shadowed(self, scope.?, a))) {
        if (i == index) return @fromBackingInt(a.handle);
        i += 1;
    };
    return .null;
}

pub export fn siv_accel_matches(accel: t.Accel, event: ?*const t.Event) t.AccelMatch {
    const k = shortcutOf(accel) catch return .none;
    const ev = runtime.readDesc(t.Event, event) catch return .none;
    if (ev.type != .key or !ev.flags.pressed or k.keysym == 0) return .none;
    const mods = runtime.flags(t.Modifiers, ev.modifiers) catch return .none;
    const keysym: u32 = @bitCast(@intFromEnum(ev.keysym));
    const latin: u32 = @bitCast(@intFromEnum(ev.shortcut_key));
    return switch (ui.accel.match(k, keysym, latin, .{ .shift = mods.shift, .ctrl = mods.ctrl, .alt = mods.alt, .super = mods.super })) {
        .none => .none,
        .latin_shifted => .latin_shifted,
        .latin => .latin,
        .shifted => .shifted,
        .exact => .exact,
    };
}

pub export fn siv_accel_format(accel: t.Accel, text: ?[*]u8, text_cap: usize, len: ?*usize) t.Result {
    if (accel.key == .none) return .error_invalid_argument;
    const k = shortcutOf(accel) catch |err| return t.resultOf(err);
    var buf: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ui.accel.format(k, .label, &w) catch return .error_invalid_argument;
    return copyOut(w.buffered(), text, text_cap, len);
}
