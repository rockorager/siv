//! Exports for the desktop shell (D31, api_shell.zig): outputs, layer
//! windows, the session lock, the desktop's toplevels and workspaces, idle
//! watches, and the compositor's capabilities. The coordinator forwards
//! the platform's shell events here (`onShellEvent`); this file keeps the
//! handles and runs the C callbacks, always at safe points (D5).
//!
//! Policy that lives here: a lock has one lock window per output, made
//! when it is requested and when an output appears, and destroyed with the
//! lock (D31).

const std = @import("std");
const t = @import("siv");
const app_mod = @import("app");
const platform = @import("platform");
const compositor = @import("compositor");
const loop_mod = @import("loop");
const api = @import("api.zig");
const runtime = @import("runtime.zig");
const application = @import("application.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;
const Root = runtime.Root;
const wrap = application.wrap;
const Allocator = std.mem.Allocator;
const OutputId = platform.OutputId;

pub const output_tag = api.spec.handleTag("siv_output");
pub const lock_tag = api.spec.handleTag("siv_lock");
pub const toplevel_list_tag = api.spec.handleTag("siv_toplevel_list");
pub const toplevel_tag = api.spec.handleTag("siv_toplevel");
pub const workspace_list_tag = api.spec.handleTag("siv_workspace_list");
pub const workspace_tag = api.spec.handleTag("siv_workspace");
pub const idle_watch_tag = api.spec.handleTag("siv_idle_watch");

/// What the application keeps for the shell.
pub const State = struct {
    /// By platform output id: the handle (0 while it has none) and what
    /// the compositor said of it.
    outputs: std.ArrayList(Output) = .empty,
    output_cb: ?OutputCallback = null,
    /// Delivers `added` for every output to a new output callback.
    replay: loop_mod.Loop.Task = .{ .func = replayOutputs },
    lock: ?*Lock = null,
    toplevel_lists: Slots(ToplevelList) = .{},
    toplevels: Slots(Entry(ToplevelList)) = .{},
    workspace_lists: Slots(WorkspaceList) = .{},
    workspaces: Slots(Entry(WorkspaceList)) = .{},
    idle_watches: Slots(IdleWatch) = .{},
};

const OutputCallback = struct { callback: t.OutputFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque };

const Output = struct {
    handle: u64 = 0,
    info: platform.OutputInfo = .{},
    /// The output callback heard of it (added), so it is not added twice
    /// when a new callback's replay and the compositor's event cross.
    told: bool = false,
};

fn Slots(comptime T: type) type {
    return struct {
        items: std.ArrayList(?*T) = .empty,

        fn reserve(s: *@This(), gpa: Allocator) Error!u32 {
            for (s.items.items, 0..) |slot, i| if (slot == null) return @intCast(i);
            try s.items.append(gpa, null);
            return @intCast(s.items.items.len - 1);
        }
    };
}

fn stateOf(self: *App) *State {
    return &self.shell;
}

/// Starts following the shell's events; called once the coordinator
/// exists.
pub fn start(self: *App) void {
    self.app.shell_listener = .{ .ctx = self, .func = onShellEvent };
}

/// Ends everything at the application's destruction, after its windows:
/// lock windows are gone, so only callbacks and protocol objects remain.
pub fn teardown(self: *App) void {
    const st = stateOf(self);
    const gpa = self.gpa();
    self.app.loop.unschedule(&st.replay);
    if (st.lock) |l| destroyLock(self, l, true);
    for (st.toplevel_lists.items.items) |slot| if (slot) |l| destroyToplevelList(self, l);
    for (st.workspace_lists.items.items) |slot| if (slot) |l| destroyWorkspaceList(self, l);
    for (st.idle_watches.items.items) |slot| if (slot) |w| destroyIdleWatch(self, w);
    if (st.output_cb) |cb| self.release(cb.destroy, cb.user_data);
    st.output_cb = null;
    st.outputs.deinit(gpa);
    st.toplevel_lists.items.deinit(gpa);
    st.toplevels.items.deinit(gpa);
    st.workspace_lists.items.deinit(gpa);
    st.workspaces.items.deinit(gpa);
    st.idle_watches.items.deinit(gpa);
}

/// Runs `func(platform, ctx)` on the compositor thread and waits.
fn onPlatform(self: *App, ctx: anytype, comptime func: fn (platform.Platform, @TypeOf(ctx)) void) Allocator.Error!void {
    const C = struct {
        inner: @TypeOf(ctx),
        fn run(p: ?*anyopaque, comp: *compositor.Compositor) void {
            const s: *@This() = @ptrCast(@alignCast(p));
            func(comp.platform, s.inner);
        }
    };
    var cx: C = .{ .inner = ctx };
    try self.app.comp.call(&cx, C.run);
}

fn onShellEvent(ctx: ?*anyopaque, ev: *const platform.Event) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    handleEvent(self, ev) catch |err| self.app.fail(if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable);
}

fn handleEvent(self: *App, ev: *const platform.Event) Error!void {
    switch (ev.*) {
        .output_added, .output_changed => |id| try outputChanged(self, id),
        .output_removed => |id| outputRemoved(self, id),
        .lock => |e| lockEvent(self, e),
        .toplevel => |c| try toplevelChanged(self, c),
        .workspace => |c| try workspaceChanged(self, c),
        .idle => |c| idleChanged(self, c),
        else => {},
    }
}

// Capabilities ----------------------------------------------------------------

pub export fn siv_app_get_capabilities(app: t.App, capabilities: ?*t.Capabilities) t.Result {
    return wrap(struct {
        fn f(a: t.App, o: ?*t.Capabilities) Error!void {
            const self = try App.get(@backingInt(a));
            const dest = try runtime.out(t.Capabilities, o);
            var caps: platform.ShellCapabilities = .{};
            try onPlatform(self, &caps, struct {
                fn g(p: platform.Platform, out: *platform.ShellCapabilities) void {
                    out.* = p.shellCapabilities();
                }
            }.g);
            dest.* = .{
                .layers = caps.layers,
                .lock = caps.lock,
                .toplevels = caps.toplevels,
                .toplevel_management = caps.toplevel_management,
                .workspaces = caps.workspaces,
                .idle = caps.idle,
                .blur = caps.blur,
            };
        }
    }.f(app, capabilities));
}

// Outputs ---------------------------------------------------------------------

fn outputSlot(self: *App, id: OutputId) Allocator.Error!*Output {
    const st = stateOf(self);
    if (id >= st.outputs.items.len) try st.outputs.appendNTimes(self.gpa(), .{}, id + 1 - st.outputs.items.len);
    return &st.outputs.items[id];
}

/// The platform output a handle names (0 is null).
pub fn outputOf(self: *App, handle: t.Output) Error!?OutputId {
    if (handle == .null) return null;
    const owner, const index = try Root.owner(App, application.app_tag, @backingInt(handle), output_tag);
    if (owner != self) return error.InvalidArgument;
    return index;
}

/// The handle of a platform output, or 0.
fn outputHandle(self: *App, id: OutputId) t.Output {
    const st = stateOf(self);
    if (id >= st.outputs.items.len) return .null;
    return @fromBackingInt(st.outputs.items[id].handle);
}

fn outputChanged(self: *App, id: OutputId) Error!void {
    const Read = struct {
        id: OutputId,
        info: ?platform.OutputInfo = null,
        fn g(p: platform.Platform, r: *@This()) void {
            if (p.output(r.id)) |i| r.info = i.*;
        }
    };
    var r: Read = .{ .id = id };
    try onPlatform(self, &r, Read.g);
    // Gone already: its removal follows.
    const info = r.info orelse return;
    const gpa = self.gpa();
    const o = try outputSlot(self, id);
    const added = o.handle == 0;
    if (added) {
        try self.root.handles.ensureUnusedCapacity(gpa);
        o.handle = self.root.handles.insert(gpa, output_tag, id) catch unreachable;
    }
    o.info = info;
    notifyOutput(self, id, if (added) .added else .changed);
    if (added) if (stateOf(self).lock) |l| lockWindowsForOutputs(self, l);
}

fn outputRemoved(self: *App, id: OutputId) void {
    const st = stateOf(self);
    if (id >= st.outputs.items.len or st.outputs.items[id].handle == 0) return;
    notifyOutput(self, id, .removed);
    const o = &st.outputs.items[id];
    _ = self.root.handles.remove(o.handle, output_tag) catch {};
    o.* = .{};
}

fn notifyOutput(self: *App, id: OutputId, event: t.OutputEventType) void {
    const cb = stateOf(self).output_cb orelse return;
    const slot = &stateOf(self).outputs.items[id];
    // A callback hears of an output once as added before anything else.
    var kind = event;
    switch (kind) {
        .removed => if (!slot.told) return,
        else => {
            if (kind == .added and slot.told) return;
            if (!slot.told) kind = .added;
            slot.told = true;
        },
        _ => unreachable,
    }
    const o = slot.*;
    const i = &o.info;
    var e: t.OutputEvent = .{
        .type = kind,
        .scale = @intCast(@max(i.scale, 1)),
        .output = @fromBackingInt(o.handle),
        .name = i.name.slice().ptr,
        .name_len = i.name.len,
        .description = i.description.slice().ptr,
        .description_len = i.description.len,
        .make = i.make.slice().ptr,
        .make_len = i.make.len,
        .model = i.model.slice().ptr,
        .model_len = i.model.len,
        .x = i.x,
        .y = i.y,
        .pixel_width = i.width,
        .pixel_height = i.height,
        .refresh_mhz = i.refresh_mhz,
        .transform = i.transform,
        .physical_width_mm = i.physical_width_mm,
        .physical_height_mm = i.physical_height_mm,
    };
    self.enter();
    defer self.leave();
    cb.callback(cb.user_data, &e);
}

pub export fn siv_app_watch_outputs(app: t.App, callback: ?t.OutputFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const self = App.get(@backingInt(app)) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    const st = stateOf(self);
    if (st.output_cb) |old| self.release(old.destroy, old.user_data);
    st.output_cb = null;
    for (st.outputs.items) |*o| o.told = false;
    if (callback) |cb| {
        st.output_cb = .{ .callback = cb, .destroy = destroy, .user_data = user_data };
        self.app.loop.schedule(&st.replay, .dispatch);
    } else self.release(destroy, user_data);
    return .ok;
}

fn replayOutputs(task: *loop_mod.Loop.Task) void {
    const st: *State = @fieldParentPtr("replay", task);
    const self: *App = @fieldParentPtr("shell", st);
    var id: OutputId = 0;
    while (id < st.outputs.items.len) : (id += 1) {
        if (st.outputs.items[id].handle != 0 and !st.outputs.items[id].told) notifyOutput(self, id, .added);
    }
}

// Layer windows ------------------------------------------------------------------

/// The layer state a descriptor asks for.
fn layerState(d: *const t.LayerDesc) Error!platform.LayerState {
    const layer = try runtime.enumValue(t.Layer, d.layer);
    const anchor = try runtime.flags(t.LayerAnchor, d.anchor);
    const keyboard = try runtime.enumValue(t.LayerKeyboard, d.keyboard);
    const fl = try runtime.flags(t.LayerFlags, d.flags);
    const st: platform.LayerState = .{
        .layer = switch (layer) {
            .top => .top,
            .bottom => .bottom,
            .background => .background,
            .overlay => .overlay,
            _ => unreachable,
        },
        .anchor = .{ .top = anchor.top, .bottom = anchor.bottom, .left = anchor.left, .right = anchor.right },
        .margin = .{ .top = d.margin_top, .right = d.margin_right, .bottom = d.margin_bottom, .left = d.margin_left },
        .exclusive_zone = d.exclusive_zone,
        .auto_exclusive = fl.auto_exclusive,
        .keyboard = switch (keyboard) {
            .none => .none,
            .exclusive => .exclusive,
            .on_demand => .on_demand,
            _ => unreachable,
        },
        .width = d.width,
        .height = d.height,
    };
    if (!st.valid() or d.exclusive_zone < -1) return error.InvalidArgument;
    return st;
}

pub export fn siv_layer_create(app: t.App, desc: ?*const t.LayerDesc, window: ?*t.Window) t.Result {
    return wrap(struct {
        fn f(a: t.App, dp: ?*const t.LayerDesc, o: ?*t.Window) Error!void {
            const self = try App.get(@backingInt(a));
            if (self.painting != 0) return error.Busy;
            const d = try runtime.readDesc(t.LayerDesc, dp);
            const state = try layerState(&d);
            const output = try outputOf(self, d.output);
            const namespace = try runtime.string(d.namespace, d.namespace_len);
            const language = try runtime.string(d.language, d.language_len);
            const wf = try runtime.flags(t.WindowFlags, d.window_flags);
            if ((wf.ltr and wf.rtl) or wf.client_decorations or wf.modal) return error.InvalidArgument;
            const dest = try runtime.out(t.Window, o);
            const w = try application.newWindow(self, .{
                .role = .{ .layer = .{ .state = state, .output = output, .namespace = namespace } },
                .rtl = if (wf.rtl) true else if (wf.ltr) false else null,
                .language = language,
            }, .{ .on_event = d.on_event, .destroy = d.destroy, .user_data = d.user_data });
            dest.* = @fromBackingInt(w.handle);
        }
    }.f(app, desc, window));
}

pub export fn siv_window_set_layer(window: t.Window, desc: ?*const t.LayerDesc) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, dp: ?*const t.LayerDesc) Error!void {
            const w = try App.window(@backingInt(wh), application.window_tag);
            if (w.dead or w.win.role != .layer) return error.InvalidArgument;
            const d = try runtime.readDesc(t.LayerDesc, dp);
            try w.win.setLayer(try layerState(&d));
        }
    }.f(window, desc));
}

// The session lock ---------------------------------------------------------------

const Lock = struct {
    handle: u64,
    on_event: ?t.LockFn,
    on_window_event: ?t.WindowEventFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    locked: bool = false,
    /// Its windows by output; a window handle goes stale when its output
    /// goes.
    windows: std.ArrayList(struct { output: OutputId, window: u64, announced: bool = false }) = .empty,
    /// Delivers window events at a safe point after siv_lock_create.
    task: loop_mod.Loop.Task = .{ .func = runLockTask },
    owner: *App,
};

fn lockFrom(handle: t.Lock) Error!struct { *App, *Lock } {
    const self, _ = try Root.owner(App, application.app_tag, @backingInt(handle), lock_tag);
    const l = stateOf(self).lock orelse return error.InvalidHandle;
    if (l.handle != @backingInt(handle)) return error.InvalidHandle;
    return .{ self, l };
}

pub export fn siv_lock_create(app: t.App, desc: ?*const t.LockDesc, lock: ?*t.Lock) t.Result {
    return wrap(struct {
        fn f(a: t.App, dp: ?*const t.LockDesc, o: ?*t.Lock) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.LockDesc, dp);
            const dest = try runtime.out(t.Lock, o);
            const st = stateOf(self);
            if (st.lock != null) return error.Busy;
            const gpa = self.gpa();
            try self.root.handles.ensureUnusedCapacity(gpa);
            const l = try gpa.create(Lock);
            errdefer gpa.destroy(l);
            self.app.lockSession() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Unsupported => error.Unsupported,
                else => error.Unavailable,
            };
            l.* = .{ .handle = 0, .on_event = d.on_event, .on_window_event = d.on_window_event, .destroy = d.destroy, .user_data = d.user_data, .owner = self };
            l.handle = self.root.handles.insert(gpa, lock_tag, 0) catch unreachable;
            st.lock = l;
            // The windows are made now, so that they can present before
            // the compositor locks; they are reported at a safe point.
            lockWindowsForOutputs(self, l);
            self.app.loop.schedule(&l.task, .dispatch);
            dest.* = @fromBackingInt(l.handle);
        }
    }.f(app, desc, lock));
}

/// Makes a lock window for every output that has none, reported at the
/// next safe point.
fn lockWindowsForOutputs(self: *App, l: *Lock) void {
    const st = stateOf(self);
    for (st.outputs.items, 0..) |o, i| {
        if (o.handle == 0) continue;
        const id: OutputId = @intCast(i);
        const has = for (l.windows.items) |x| {
            if (x.output == id and liveWindow(x.window) != null) break true;
        } else false;
        if (has) continue;
        l.windows.ensureUnusedCapacity(self.gpa(), 1) catch return self.app.fail(error.OutOfMemory);
        const w = application.newWindow(self, .{ .role = .{ .lock = id } }, .{ .on_event = l.on_window_event, .user_data = l.user_data }) catch |err| switch (err) {
            // The lock was refused or has ended: its finished event follows.
            error.Unsupported => continue,
            else => return self.app.fail(if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable),
        };
        l.windows.appendAssumeCapacity(.{ .output = id, .window = w.handle });
    }
    self.app.loop.schedule(&l.task, .dispatch);
}

fn liveWindow(handle: u64) ?*Window {
    const w = App.window(handle, application.window_tag) catch return null;
    return if (w.dead) null else w;
}

fn runLockTask(task: *loop_mod.Loop.Task) void {
    const l: *Lock = @fieldParentPtr("task", task);
    announceLockWindows(l.owner, l);
}

/// Reports lock windows not reported yet. Stops if a callback ends the
/// lock.
fn announceLockWindows(self: *App, l: *Lock) void {
    const handle = l.handle;
    var i: usize = 0;
    while (i < l.windows.items.len) : (i += 1) {
        const x = &l.windows.items[i];
        if (x.announced or liveWindow(x.window) == null) continue;
        x.announced = true;
        var e: t.LockEvent = .{ .type = .window, .window = @fromBackingInt(x.window), .output = outputHandle(self, x.output) };
        if (!deliverLock(self, l, &e)) return;
        if (stateOf(self).lock != l or l.handle != handle) return;
    }
}

/// Runs the lock's callback; false if the lock is gone after it.
fn deliverLock(self: *App, l: *Lock, e: *const t.LockEvent) bool {
    const handle = l.handle;
    if (l.on_event) |cb| {
        self.enter();
        defer self.leave();
        cb(l.user_data, @fromBackingInt(handle), e);
    }
    const now = stateOf(self).lock orelse return false;
    return now == l and now.handle == handle;
}

fn lockEvent(self: *App, ev: platform.LockEvent) void {
    const l = stateOf(self).lock orelse return;
    switch (ev) {
        .locked => {
            // Windows first, so the application has built them.
            announceLockWindows(self, l);
            if (stateOf(self).lock != l) return;
            l.locked = true;
            const e: t.LockEvent = .{ .type = .locked };
            _ = deliverLock(self, l, &e);
        },
        .finished => {
            // Its windows are gone with it.
            destroyLockWindows(l);
            const e: t.LockEvent = .{ .type = if (l.locked) .finished else .denied };
            if (!deliverLock(self, l, &e)) return;
            l.locked = false;
        },
    }
}

fn destroyLockWindows(l: *Lock) void {
    for (l.windows.items) |x| if (liveWindow(x.window)) |w| {
        w.destroyTree() catch {};
    };
    l.windows.clearRetainingCapacity();
}

/// Ends the lock: unlocks, or with `abandon` leaves a locked session
/// locked; destroys its windows and its handle.
fn destroyLock(self: *App, l: *Lock, abandon: bool) void {
    self.app.loop.unschedule(&l.task);
    self.app.unlockSession(abandon) catch self.app.fail(error.OutOfMemory);
    destroyLockWindows(l);
    stateOf(self).lock = null;
    _ = self.root.handles.remove(l.handle, lock_tag) catch {};
    l.windows.deinit(self.gpa());
    self.release(l.destroy, l.user_data);
    self.gpa().destroy(l);
}

pub export fn siv_lock_unlock(lock: t.Lock) t.Result {
    const self, const l = lockFrom(lock) catch |err| return t.resultOf(err);
    destroyLock(self, l, false);
    return .ok;
}

pub export fn siv_lock_destroy(lock: t.Lock) void {
    const self, const l = lockFrom(lock) catch return;
    destroyLock(self, l, true);
}

// Toplevels and workspaces -------------------------------------------------------

/// A copy of a toplevel's or workspace's details, owned.
const Info = struct {
    title: []u8 = &.{},
    app_id: []u8 = &.{},
    identifier: []u8 = &.{},
    toplevel_states: platform.ToplevelStates = .{},
    workspace_states: platform.WorkspaceStates = .{},
    capabilities: platform.WorkspaceCapabilities = .{},
    parent: u32 = 0,
    managed: bool = false,
    outputs: [8]OutputId = undefined,
    output_count: u8 = 0,

    fn deinit(i: *Info, gpa: Allocator) void {
        gpa.free(i.title);
        gpa.free(i.app_id);
        gpa.free(i.identifier);
        i.* = .{};
    }

    fn setOutputs(i: *Info, outs: []const OutputId) void {
        const n = @min(outs.len, i.outputs.len);
        @memcpy(i.outputs[0..n], outs[0..n]);
        i.output_count = @intCast(n);
    }
};

/// A toplevel or workspace as one list sees it.
fn Entry(comptime List: type) type {
    return struct {
        list: *List,
        /// The platform's id.
        id: u32,
        handle: u64,
        info: Info = .{},
    };
}

/// Reads a toplevel or workspace from the platform, copying it.
fn readInfo(self: *App, comptime what: enum { toplevel, workspace }, id: u32) Error!?Info {
    const Read = struct {
        gpa: Allocator,
        id: u32,
        out: ?Info = null,
        failed: bool = false,
        fn g(p: platform.Platform, r: *@This()) void {
            var info: Info = .{};
            switch (what) {
                .toplevel => {
                    const x = p.toplevelInfo(r.id) orelse return;
                    info.title = r.gpa.dupe(u8, x.title) catch return r.fail(&info);
                    info.app_id = r.gpa.dupe(u8, x.app_id) catch return r.fail(&info);
                    info.identifier = r.gpa.dupe(u8, x.identifier) catch return r.fail(&info);
                    info.toplevel_states = x.states;
                    info.parent = x.parent;
                    info.managed = x.managed;
                    info.setOutputs(x.outputs);
                },
                .workspace => {
                    const x = p.workspaceInfo(r.id) orelse return;
                    info.title = r.gpa.dupe(u8, x.name) catch return r.fail(&info);
                    info.identifier = r.gpa.dupe(u8, x.identifier) catch return r.fail(&info);
                    info.workspace_states = x.states;
                    info.capabilities = x.capabilities;
                    info.setOutputs(x.outputs);
                },
            }
            r.out = info;
        }
        fn fail(r: *@This(), info: *Info) void {
            info.deinit(r.gpa);
            r.failed = true;
        }
    };
    var r: Read = .{ .gpa = self.gpa(), .id = id };
    try onPlatform(self, &r, Read.g);
    if (r.failed) return error.OutOfMemory;
    return r.out;
}

/// The handles of the outputs in `info`, for an event (at most eight).
fn outputHandles(self: *App, info: *const Info, buf: *[8]t.Output) []const t.Output {
    var n: usize = 0;
    for (info.outputs[0..info.output_count]) |id| {
        const h = outputHandle(self, id);
        if (h == .null) continue;
        buf[n] = h;
        n += 1;
    }
    return buf[0..n];
}

const ToplevelList = struct {
    handle: u64,
    on_event: ?t.ToplevelListFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
};

pub export fn siv_toplevel_list_create(app: t.App, desc: ?*const t.ToplevelListDesc, list: ?*t.ToplevelList) t.Result {
    return wrap(struct {
        fn f(a: t.App, dp: ?*const t.ToplevelListDesc, o: ?*t.ToplevelList) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.ToplevelListDesc, dp);
            const dest = try runtime.out(t.ToplevelList, o);
            const st = stateOf(self);
            const gpa = self.gpa();
            const index = try st.toplevel_lists.reserve(gpa);
            try self.root.handles.ensureUnusedCapacity(gpa);
            const l = try gpa.create(ToplevelList);
            errdefer gpa.destroy(l);
            // One per application: the platform has one subscription.
            for (st.toplevel_lists.items.items) |x| if (x != null) return error.Busy;
            try startForeign(self, .toplevel);
            l.* = .{ .handle = self.root.handles.insert(gpa, toplevel_list_tag, index) catch unreachable, .on_event = d.on_event, .destroy = d.destroy, .user_data = d.user_data };
            st.toplevel_lists.items.items[index] = l;
            dest.* = @fromBackingInt(l.handle);
        }
    }.f(app, desc, list));
}

/// Starts the platform's toplevels or workspaces: every one there is
/// arrives as added.
fn startForeign(self: *App, comptime what: enum { toplevel, workspace }) Error!void {
    const R = struct {
        result: platform.Error!void = {},
        fn g(p: platform.Platform, r: *@This()) void {
            r.result = switch (what) {
                .toplevel => p.startToplevels(),
                .workspace => p.startWorkspaces(),
            };
        }
    };
    var r: R = .{};
    try onPlatform(self, &r, R.g);
    r.result catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        else => error.Unavailable,
    };
}

/// Forgets an entry, telling its list it was removed.
fn removeEntry(self: *App, slots: anytype, tag: u8, index: u32, e: anytype, comptime what: enum { toplevel, workspace }) void {
    switch (what) {
        .toplevel => notifyToplevel(self, e, .removed),
        .workspace => notifyWorkspace(self, e, .removed),
    }
    _ = self.root.handles.remove(e.handle, tag) catch {};
    slots.items.items[index] = null;
    e.info.deinit(self.gpa());
    self.gpa().destroy(e);
}

fn stopForeignIfUnused(self: *App, comptime what: enum { toplevel, workspace }) void {
    const st = stateOf(self);
    const lists = switch (what) {
        .toplevel => st.toplevel_lists.items.items,
        .workspace => st.workspace_lists.items.items,
    };
    for (lists) |slot| if (slot != null) return;
    onPlatform(self, {}, struct {
        fn g(p: platform.Platform, _: void) void {
            switch (what) {
                .toplevel => p.stopToplevels(),
                .workspace => p.stopWorkspaces(),
            }
        }
    }.g) catch {};
}

fn destroyToplevelList(self: *App, l: *ToplevelList) void {
    const st = stateOf(self);
    const gpa = self.gpa();
    for (st.toplevels.items.items, 0..) |slot, i| if (slot) |e| if (e.list == l) {
        _ = self.root.handles.remove(e.handle, toplevel_tag) catch {};
        st.toplevels.items.items[i] = null;
        e.info.deinit(gpa);
        gpa.destroy(e);
    };
    const index = self.root.handles.remove(l.handle, toplevel_list_tag) catch unreachable;
    st.toplevel_lists.items.items[index] = null;
    self.release(l.destroy, l.user_data);
    gpa.destroy(l);
    stopForeignIfUnused(self, .toplevel);
}

pub export fn siv_toplevel_list_destroy(list: t.ToplevelList) void {
    const self, const index = Root.owner(App, application.app_tag, @backingInt(list), toplevel_list_tag) catch return;
    destroyToplevelList(self, stateOf(self).toplevel_lists.items.items[index].?);
}

fn toplevelChanged(self: *App, c: platform.ForeignChange) Error!void {
    const st = stateOf(self);
    const gpa = self.gpa();
    // Each list in turn; a callback may destroy lists or end the list.
    const lists = try gpa.dupe(?*ToplevelList, st.toplevel_lists.items.items);
    defer gpa.free(lists);
    var info: ?Info = if (c.kind == .removed) null else try readInfo(self, .toplevel, c.id);
    defer if (info) |*i| i.deinit(gpa);
    for (lists) |slot| {
        const l = slot orelse continue;
        if (!listAlive(self, ToplevelList, &st.toplevel_lists, l)) continue;
        const found = findEntry(&st.toplevels, l, c.id);
        switch (c.kind) {
            .removed => if (found) |f| removeEntry(self, &st.toplevels, toplevel_tag, f.index, f.entry, .toplevel),
            .added, .changed => {
                const fresh = info orelse continue; // gone already
                const e = if (found) |f| f.entry else blk: {
                    const index = try st.toplevels.reserve(gpa);
                    try self.root.handles.ensureUnusedCapacity(gpa);
                    const e = try gpa.create(Entry(ToplevelList));
                    e.* = .{ .list = l, .id = c.id, .handle = self.root.handles.insert(gpa, toplevel_tag, index) catch unreachable };
                    st.toplevels.items.items[index] = e;
                    break :blk e;
                };
                e.info.deinit(gpa);
                e.info = try dupeInfo(gpa, &fresh);
                notifyToplevel(self, e, if (found == null) .added else .changed);
            },
        }
    }
}

fn listAlive(self: *App, comptime L: type, slots: *Slots(L), l: *L) bool {
    _ = self;
    for (slots.items.items) |slot| if (slot == l) return true;
    return false;
}

fn findEntry(slots: anytype, list: anytype, id: u32) ?struct { index: u32, entry: @TypeOf(slots.items.items[0].?) } {
    for (slots.items.items, 0..) |slot, i| if (slot) |e| if (e.list == list and e.id == id) return .{ .index = @intCast(i), .entry = e };
    return null;
}

fn dupeInfo(gpa: Allocator, i: *const Info) Allocator.Error!Info {
    var out = i.*;
    out.title = &.{};
    out.app_id = &.{};
    out.identifier = &.{};
    errdefer out.deinit(gpa);
    out.title = try gpa.dupe(u8, i.title);
    out.app_id = try gpa.dupe(u8, i.app_id);
    out.identifier = try gpa.dupe(u8, i.identifier);
    return out;
}

fn notifyToplevel(self: *App, e: *Entry(ToplevelList), kind: t.ToplevelEventType) void {
    const l = e.list;
    const cb = l.on_event orelse return;
    var buf: [8]t.Output = undefined;
    const outs = outputHandles(self, &e.info, &buf);
    const s = e.info.toplevel_states;
    var ev: t.ToplevelEvent = .{
        .type = kind,
        .states = .{ .maximized = s.maximized, .minimized = s.minimized, .activated = s.activated, .fullscreen = s.fullscreen, .managed = e.info.managed },
        .toplevel = @fromBackingInt(e.handle),
        .parent = if (e.info.parent != 0) if (findEntry(&stateOf(self).toplevels, l, e.info.parent)) |p| @fromBackingInt(p.entry.handle) else .null else .null,
        .title = e.info.title.ptr,
        .title_len = e.info.title.len,
        .app_id = e.info.app_id.ptr,
        .app_id_len = e.info.app_id.len,
        .identifier = e.info.identifier.ptr,
        .identifier_len = e.info.identifier.len,
        .outputs = outs.ptr,
        .outputs_count = outs.len,
    };
    self.enter();
    defer self.leave();
    cb(l.user_data, @fromBackingInt(l.handle), &ev);
}

fn toplevelRequest(handle: t.Toplevel, request: platform.ToplevelRequest) Error!void {
    const self, const index = try Root.owner(App, application.app_tag, @backingInt(handle), toplevel_tag);
    const e = stateOf(self).toplevels.items.items[index].?;
    if (!e.info.managed) return error.Unsupported;
    const R = struct {
        id: u32,
        request: platform.ToplevelRequest,
        ok: bool = false,
        fn g(p: platform.Platform, r: *@This()) void {
            r.ok = p.toplevelRequest(r.id, r.request);
        }
    };
    var r: R = .{ .id = e.id, .request = request };
    try onPlatform(self, &r, R.g);
    if (!r.ok) return error.Unsupported;
}

pub export fn siv_toplevel_activate(toplevel: t.Toplevel) t.Result {
    return wrap(toplevelRequest(toplevel, .activate));
}

pub export fn siv_toplevel_close(toplevel: t.Toplevel) t.Result {
    return wrap(toplevelRequest(toplevel, .close));
}

pub export fn siv_toplevel_set_minimized(toplevel: t.Toplevel, minimized: bool) t.Result {
    return wrap(toplevelRequest(toplevel, .{ .minimized = minimized }));
}

pub export fn siv_toplevel_set_maximized(toplevel: t.Toplevel, maximized: bool) t.Result {
    return wrap(toplevelRequest(toplevel, .{ .maximized = maximized }));
}

pub export fn siv_toplevel_set_fullscreen(toplevel: t.Toplevel, fullscreen: bool, output: t.Output) t.Result {
    return wrap(struct {
        fn f(h: t.Toplevel, on: bool, o: t.Output) Error!void {
            const self, _ = try Root.owner(App, application.app_tag, @backingInt(h), toplevel_tag);
            try toplevelRequest(h, .{ .fullscreen = .{ .on = on, .output = try outputOf(self, o) } });
        }
    }.f(toplevel, fullscreen, output));
}

const WorkspaceList = struct {
    handle: u64,
    on_event: ?t.WorkspaceListFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
};

pub export fn siv_workspace_list_create(app: t.App, desc: ?*const t.WorkspaceListDesc, list: ?*t.WorkspaceList) t.Result {
    return wrap(struct {
        fn f(a: t.App, dp: ?*const t.WorkspaceListDesc, o: ?*t.WorkspaceList) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.WorkspaceListDesc, dp);
            const dest = try runtime.out(t.WorkspaceList, o);
            const st = stateOf(self);
            const gpa = self.gpa();
            const index = try st.workspace_lists.reserve(gpa);
            try self.root.handles.ensureUnusedCapacity(gpa);
            const l = try gpa.create(WorkspaceList);
            errdefer gpa.destroy(l);
            for (st.workspace_lists.items.items) |x| if (x != null) return error.Busy;
            try startForeign(self, .workspace);
            l.* = .{ .handle = self.root.handles.insert(gpa, workspace_list_tag, index) catch unreachable, .on_event = d.on_event, .destroy = d.destroy, .user_data = d.user_data };
            st.workspace_lists.items.items[index] = l;
            dest.* = @fromBackingInt(l.handle);
        }
    }.f(app, desc, list));
}

fn destroyWorkspaceList(self: *App, l: *WorkspaceList) void {
    const st = stateOf(self);
    const gpa = self.gpa();
    for (st.workspaces.items.items, 0..) |slot, i| if (slot) |e| if (e.list == l) {
        _ = self.root.handles.remove(e.handle, workspace_tag) catch {};
        st.workspaces.items.items[i] = null;
        e.info.deinit(gpa);
        gpa.destroy(e);
    };
    const index = self.root.handles.remove(l.handle, workspace_list_tag) catch unreachable;
    st.workspace_lists.items.items[index] = null;
    self.release(l.destroy, l.user_data);
    gpa.destroy(l);
    stopForeignIfUnused(self, .workspace);
}

pub export fn siv_workspace_list_destroy(list: t.WorkspaceList) void {
    const self, const index = Root.owner(App, application.app_tag, @backingInt(list), workspace_list_tag) catch return;
    destroyWorkspaceList(self, stateOf(self).workspace_lists.items.items[index].?);
}

fn workspaceChanged(self: *App, c: platform.ForeignChange) Error!void {
    const st = stateOf(self);
    const gpa = self.gpa();
    const lists = try gpa.dupe(?*WorkspaceList, st.workspace_lists.items.items);
    defer gpa.free(lists);
    var info: ?Info = if (c.kind == .removed) null else try readInfo(self, .workspace, c.id);
    defer if (info) |*i| i.deinit(gpa);
    for (lists) |slot| {
        const l = slot orelse continue;
        if (!listAlive(self, WorkspaceList, &st.workspace_lists, l)) continue;
        const found = findEntry(&st.workspaces, l, c.id);
        switch (c.kind) {
            .removed => if (found) |f| removeEntry(self, &st.workspaces, workspace_tag, f.index, f.entry, .workspace),
            .added, .changed => {
                const fresh = info orelse continue;
                const e = if (found) |f| f.entry else blk: {
                    const index = try st.workspaces.reserve(gpa);
                    try self.root.handles.ensureUnusedCapacity(gpa);
                    const e = try gpa.create(Entry(WorkspaceList));
                    e.* = .{ .list = l, .id = c.id, .handle = self.root.handles.insert(gpa, workspace_tag, index) catch unreachable };
                    st.workspaces.items.items[index] = e;
                    break :blk e;
                };
                e.info.deinit(gpa);
                e.info = try dupeInfo(gpa, &fresh);
                notifyWorkspace(self, e, if (found == null) .added else .changed);
            },
        }
    }
}

fn notifyWorkspace(self: *App, e: *Entry(WorkspaceList), kind: t.WorkspaceEventType) void {
    const l = e.list;
    const cb = l.on_event orelse return;
    var buf: [8]t.Output = undefined;
    const outs = outputHandles(self, &e.info, &buf);
    const s = e.info.workspace_states;
    const c = e.info.capabilities;
    var ev: t.WorkspaceEvent = .{
        .type = kind,
        .states = .{ .active = s.active, .urgent = s.urgent, .hidden = s.hidden },
        .workspace = @fromBackingInt(e.handle),
        .name = e.info.title.ptr,
        .name_len = e.info.title.len,
        .identifier = e.info.identifier.ptr,
        .identifier_len = e.info.identifier.len,
        .outputs = outs.ptr,
        .outputs_count = outs.len,
        .capabilities = .{ .activate = c.activate, .deactivate = c.deactivate, .remove = c.remove },
    };
    self.enter();
    defer self.leave();
    cb(l.user_data, @fromBackingInt(l.handle), &ev);
}

fn workspaceRequest(handle: t.Workspace, request: platform.WorkspaceRequest) Error!void {
    const self, const index = try Root.owner(App, application.app_tag, @backingInt(handle), workspace_tag);
    const e = stateOf(self).workspaces.items.items[index].?;
    const R = struct {
        id: u32,
        request: platform.WorkspaceRequest,
        ok: bool = false,
        fn g(p: platform.Platform, r: *@This()) void {
            r.ok = p.workspaceRequest(r.id, r.request);
        }
    };
    var r: R = .{ .id = e.id, .request = request };
    try onPlatform(self, &r, R.g);
    if (!r.ok) return error.Unsupported;
}

pub export fn siv_workspace_activate(workspace: t.Workspace) t.Result {
    return wrap(workspaceRequest(workspace, .activate));
}

pub export fn siv_workspace_deactivate(workspace: t.Workspace) t.Result {
    return wrap(workspaceRequest(workspace, .deactivate));
}

pub export fn siv_workspace_remove(workspace: t.Workspace) t.Result {
    return wrap(workspaceRequest(workspace, .remove));
}

// Idle watches -------------------------------------------------------------------

const IdleWatch = struct {
    handle: u64,
    /// The platform's watch.
    id: u32,
    on_event: ?t.IdleFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
};

pub export fn siv_idle_watch_create(app: t.App, desc: ?*const t.IdleWatchDesc, watch: ?*t.IdleWatch) t.Result {
    return wrap(struct {
        fn f(a: t.App, dp: ?*const t.IdleWatchDesc, o: ?*t.IdleWatch) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.IdleWatchDesc, dp);
            const fl = try runtime.flags(t.IdleFlags, d.flags);
            const dest = try runtime.out(t.IdleWatch, o);
            const st = stateOf(self);
            const gpa = self.gpa();
            const index = try st.idle_watches.reserve(gpa);
            try self.root.handles.ensureUnusedCapacity(gpa);
            const w = try gpa.create(IdleWatch);
            errdefer gpa.destroy(w);
            const R = struct {
                timeout: u32,
                ignore: bool,
                result: platform.Error!u32 = 0,
                fn g(p: platform.Platform, r: *@This()) void {
                    r.result = p.createIdleWatch(r.timeout, r.ignore);
                }
            };
            var r: R = .{ .timeout = d.timeout_ms, .ignore = fl.ignore_inhibitors };
            try onPlatform(self, &r, R.g);
            const id = r.result catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Unsupported => error.Unsupported,
                else => error.Unavailable,
            };
            w.* = .{ .handle = self.root.handles.insert(gpa, idle_watch_tag, index) catch unreachable, .id = id, .on_event = d.on_event, .destroy = d.destroy, .user_data = d.user_data };
            st.idle_watches.items.items[index] = w;
            dest.* = @fromBackingInt(w.handle);
        }
    }.f(app, desc, watch));
}

fn destroyIdleWatch(self: *App, w: *IdleWatch) void {
    const st = stateOf(self);
    onPlatform(self, w.id, struct {
        fn g(p: platform.Platform, id: u32) void {
            p.destroyIdleWatch(id);
        }
    }.g) catch {};
    const index = self.root.handles.remove(w.handle, idle_watch_tag) catch unreachable;
    st.idle_watches.items.items[index] = null;
    self.release(w.destroy, w.user_data);
    self.gpa().destroy(w);
}

pub export fn siv_idle_watch_destroy(watch: t.IdleWatch) void {
    const self, const index = Root.owner(App, application.app_tag, @backingInt(watch), idle_watch_tag) catch return;
    destroyIdleWatch(self, stateOf(self).idle_watches.items.items[index].?);
}

fn idleChanged(self: *App, c: platform.IdleChange) void {
    for (stateOf(self).idle_watches.items.items) |slot| if (slot) |w| if (w.id == c.watch) {
        const cb = w.on_event orelse return;
        self.enter();
        defer self.leave();
        cb(w.user_data, @fromBackingInt(w.handle), c.idle);
        return;
    };
}
