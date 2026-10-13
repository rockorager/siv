//! Desktop shell data for the Wayland backend (D31): the foreign toplevel
//! list, workspaces, and idle notification. Nothing here owns a surface,
//! so it only needs the connection; each protocol is bound when the
//! application asks for it and released when it stops, so an ordinary
//! application never receives the desktop's window list.
//!
//! - Toplevels: wlr-foreign-toplevel-management when the compositor
//!   offers it, since it carries states, outputs, parents, and the
//!   requests a task list needs (activate, close, minimize, maximize,
//!   fullscreen); otherwise ext-foreign-toplevel-list-v1, which lists
//!   titles, app ids, and stable identifiers only. The two protocols
//!   share no key, so siv never mixes them (D31).
//! - Workspaces: ext-workspace-v1. Changes arrive atomically at the
//!   manager's done; requests are committed at once.
//! - Idle: ext-idle-notify-v1 notifications on the first seat.
//!
//! Every toplevel and workspace has an id that is never reused, so an
//! event the UI thread handles late can never name a newer object. Changes
//! are reported as `platform.Event.toplevel` and `.workspace` with the
//! id; the UI reads the details with `toplevel` and `workspace` on this
//! thread (the compositor's), valid until the next platform event.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const zwlr = wayland.client.zwlr;
const platform = @import("platform.zig");
const Wayland = @import("Wayland.zig");
const Foreign = @This();

const OutputId = platform.OutputId;
const Error = platform.Error;

backend: *Wayland,
/// Globals seen at registration: name and version, bound on demand.
list_global: ?Global = null,
wlr_global: ?Global = null,
workspace_global: ?Global = null,
idle_global: ?Global = null,
/// Tests: use the ext list even when wlr management is offered.
force_ext_list: bool = false,

ext_list: ?*ext.ForeignToplevelListV1 = null,
wlr_manager: ?*zwlr.ForeignToplevelManagerV1 = null,
toplevels: std.ArrayList(*Toplevel) = .empty,
workspace_manager: ?*ext.WorkspaceManagerV1 = null,
groups: std.ArrayList(*Group) = .empty,
workspaces: std.ArrayList(*Workspace) = .empty,
idle_notifier: ?*ext.IdleNotifierV1 = null,
idle_watches: std.ArrayList(*IdleWatch) = .empty,
next_id: u32 = 1,

pub const Global = struct { name: u32, version: u32 };

const max_outputs = 8;

/// Text the compositor sends, copied.
const Text = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn set(t: *Text, gpa: Allocator, s: [*:0]const u8) void {
        t.bytes.clearRetainingCapacity();
        t.bytes.appendSlice(gpa, std.mem.span(s)) catch {};
    }

    fn deinit(t: *Text, gpa: Allocator) void {
        t.bytes.deinit(gpa);
    }
};

const Outputs = struct {
    ids: [max_outputs]OutputId = undefined,
    len: u8 = 0,

    fn add(o: *Outputs, id: OutputId) void {
        if (std.mem.indexOfScalar(OutputId, o.ids[0..o.len], id) != null or o.len == max_outputs) return;
        o.ids[o.len] = id;
        o.len += 1;
    }

    fn remove(o: *Outputs, id: OutputId) bool {
        const i = std.mem.indexOfScalar(OutputId, o.ids[0..o.len], id) orelse return false;
        o.ids[i] = o.ids[o.len - 1];
        o.len -= 1;
        return true;
    }

    fn slice(o: *const Outputs) []const OutputId {
        return o.ids[0..o.len];
    }
};

const Toplevel = struct {
    foreign: *Foreign,
    id: u32,
    ext: ?*ext.ForeignToplevelHandleV1 = null,
    wlr: ?*zwlr.ForeignToplevelHandleV1 = null,
    title: Text = .{},
    app_id: Text = .{},
    identifier: Text = .{},
    states: platform.ToplevelStates = .{},
    parent: u32 = 0,
    outputs: Outputs = .{},
    /// Its added event went out (at its first done).
    announced: bool = false,

    fn info(t: *const Toplevel) platform.ToplevelInfo {
        return .{
            .title = t.title.bytes.items,
            .app_id = t.app_id.bytes.items,
            .identifier = t.identifier.bytes.items,
            .states = t.states,
            .parent = t.parent,
            .outputs = t.outputs.slice(),
            .managed = t.wlr != null,
        };
    }

    fn destroy(t: *Toplevel, gpa: Allocator) void {
        if (t.ext) |h| h.destroy();
        if (t.wlr) |h| h.destroy();
        t.title.deinit(gpa);
        t.app_id.deinit(gpa);
        t.identifier.deinit(gpa);
        gpa.destroy(t);
    }
};

const Group = struct {
    foreign: *Foreign,
    proxy: *ext.WorkspaceGroupHandleV1,
    outputs: Outputs = .{},
    can_create: bool = false,
};

const Workspace = struct {
    foreign: *Foreign,
    id: u32,
    proxy: *ext.WorkspaceHandleV1,
    group: ?*Group = null,
    name: Text = .{},
    identifier: Text = .{},
    states: platform.WorkspaceStates = .{},
    capabilities: platform.WorkspaceCapabilities = .{},
    announced: bool = false,
    dirty: bool = true,
    removed: bool = false,

    fn info(w: *const Workspace) platform.WorkspaceInfo {
        return .{
            .name = w.name.bytes.items,
            .identifier = w.identifier.bytes.items,
            .states = w.states,
            .capabilities = w.capabilities,
            .outputs = if (w.group) |g| g.outputs.slice() else &.{},
        };
    }

    fn destroy(w: *Workspace, gpa: Allocator) void {
        w.proxy.destroy();
        w.name.deinit(gpa);
        w.identifier.deinit(gpa);
        gpa.destroy(w);
    }
};

const IdleWatch = struct {
    foreign: *Foreign,
    id: u32,
    proxy: *ext.IdleNotificationV1,
};

pub fn deinit(f: *Foreign) void {
    f.stopToplevels();
    f.stopWorkspaces();
    for (f.idle_watches.items) |w| {
        w.proxy.destroy();
        f.backend.allocator.destroy(w);
    }
    f.idle_watches.deinit(f.backend.allocator);
    if (f.idle_notifier) |n| n.destroy();
    f.toplevels.deinit(f.backend.allocator);
    f.workspaces.deinit(f.backend.allocator);
    f.groups.deinit(f.backend.allocator);
}

fn allocator(f: *Foreign) Allocator {
    return f.backend.allocator;
}

fn nextId(f: *Foreign) u32 {
    const id = f.next_id;
    f.next_id +%= 1;
    if (f.next_id == 0) f.next_id = 1;
    return id;
}

/// An output was removed: nothing is on it any more.
pub fn outputRemoved(f: *Foreign, id: OutputId) void {
    for (f.toplevels.items) |t| if (t.outputs.remove(id) and t.announced) f.push(.toplevel, t.id, .changed);
    for (f.groups.items) |g| if (g.outputs.remove(id)) {
        for (f.workspaces.items) |w| if (w.group == g and w.announced) f.push(.workspace, w.id, .changed);
    };
}

fn push(f: *Foreign, comptime what: enum { toplevel, workspace }, id: u32, kind: platform.ForeignChange.Kind) void {
    const change: platform.ForeignChange = .{ .id = id, .kind = kind };
    f.backend.queue.push(switch (what) {
        .toplevel => .{ .toplevel = change },
        .workspace => .{ .workspace = change },
    });
}

// Toplevels -------------------------------------------------------------------

pub fn startToplevels(f: *Foreign) Error!void {
    if (f.ext_list != null or f.wlr_manager != null) return;
    const registry = f.backend.registry;
    if (f.wlr_global != null and !f.force_ext_list) {
        const g = f.wlr_global.?;
        const m = registry.bind(g.name, zwlr.ForeignToplevelManagerV1, @min(g.version, 3)) catch return error.OutOfMemory;
        m.setListener(*Foreign, onWlrManager, f);
        f.wlr_manager = m;
    } else if (f.list_global) |g| {
        const l = registry.bind(g.name, ext.ForeignToplevelListV1, 1) catch return error.OutOfMemory;
        l.setListener(*Foreign, onExtList, f);
        f.ext_list = l;
    } else return error.Unsupported;
}

pub fn stopToplevels(f: *Foreign) void {
    if (f.ext_list) |l| l.destroy();
    f.ext_list = null;
    if (f.wlr_manager) |m| {
        // The manager is destroyed by its finished event; until then its
        // listener sees it is no longer `wlr_manager`.
        m.stop();
    }
    f.wlr_manager = null;
    for (f.toplevels.items) |t| t.destroy(f.allocator());
    f.toplevels.clearRetainingCapacity();
}


fn addToplevel(f: *Foreign) ?*Toplevel {
    f.toplevels.ensureUnusedCapacity(f.allocator(), 1) catch return null;
    const t = f.allocator().create(Toplevel) catch return null;
    t.* = .{ .foreign = f, .id = f.nextId() };
    f.toplevels.appendAssumeCapacity(t);
    return t;
}

fn removeToplevel(f: *Foreign, t: *Toplevel) void {
    if (t.announced) f.push(.toplevel, t.id, .removed);
    for (f.toplevels.items) |o| if (o.parent == t.id) {
        o.parent = 0;
    };
    const i = std.mem.indexOfScalar(*Toplevel, f.toplevels.items, t).?;
    _ = f.toplevels.orderedRemove(i);
    t.destroy(f.allocator());
}

fn done(t: *Toplevel) void {
    t.foreign.push(.toplevel, t.id, if (t.announced) .changed else .added);
    t.announced = true;
}

fn onExtList(_: *ext.ForeignToplevelListV1, event: ext.ForeignToplevelListV1.Event, f: *Foreign) void {
    switch (event) {
        .toplevel => |e| {
            const t = f.addToplevel() orelse {
                e.toplevel.destroy();
                return f.backend.queue.fail(error.OutOfMemory);
            };
            t.ext = e.toplevel;
            e.toplevel.setListener(*Toplevel, onExtToplevel, t);
        },
        .finished => {},
    }
}

fn onExtToplevel(_: *ext.ForeignToplevelHandleV1, event: ext.ForeignToplevelHandleV1.Event, t: *Toplevel) void {
    const g = t.foreign.allocator();
    switch (event) {
        .title => |e| t.title.set(g, e.title),
        .app_id => |e| t.app_id.set(g, e.app_id),
        .identifier => |e| t.identifier.set(g, e.identifier),
        .done => done(t),
        .closed => t.foreign.removeToplevel(t),
    }
}

fn onWlrManager(m: *zwlr.ForeignToplevelManagerV1, event: zwlr.ForeignToplevelManagerV1.Event, f: *Foreign) void {
    if (f.wlr_manager != m) return switch (event) {
        // Stopped: handles announced before the stop arrived, then the end.
        .toplevel => |e| e.toplevel.destroy(),
        .finished => m.destroy(),
    };
    switch (event) {
        .toplevel => |e| {
            const t = f.addToplevel() orelse {
                e.toplevel.destroy();
                return f.backend.queue.fail(error.OutOfMemory);
            };
            t.wlr = e.toplevel;
            e.toplevel.setListener(*Toplevel, onWlrToplevel, t);
        },
        // Only after a stop, which replaces this listener.
        .finished => {},
    }
}

fn onWlrToplevel(_: *zwlr.ForeignToplevelHandleV1, event: zwlr.ForeignToplevelHandleV1.Event, t: *Toplevel) void {
    const g = t.foreign.allocator();
    switch (event) {
        .title => |e| t.title.set(g, e.title),
        .app_id => |e| t.app_id.set(g, e.app_id),
        .output_enter => |e| if (Wayland.outputOf(e.output)) |o| t.outputs.add(o.id),
        .output_leave => |e| if (Wayland.outputOf(e.output)) |o| {
            _ = t.outputs.remove(o.id);
        },
        .state => |e| {
            var s: platform.ToplevelStates = .{};
            for (e.state.slice(zwlr.ForeignToplevelHandleV1.State)) |st| switch (st) {
                .maximized => s.maximized = true,
                .minimized => s.minimized = true,
                .activated => s.activated = true,
                .fullscreen => s.fullscreen = true,
                _ => {},
            };
            t.states = s;
        },
        .parent => |e| t.parent = if (e.parent) |p| blk: {
            const other: *Toplevel = @ptrCast(@alignCast(@as(*wl.Proxy, @ptrCast(p)).getUserData() orelse break :blk 0));
            break :blk other.id;
        } else 0,
        .done => done(t),
        .closed => t.foreign.removeToplevel(t),
    }
}

fn findToplevel(f: *Foreign, id: u32) ?*Toplevel {
    for (f.toplevels.items) |t| if (t.id == id) return t;
    return null;
}

pub fn toplevel(f: *Foreign, id: u32) ?platform.ToplevelInfo {
    const t = f.findToplevel(id) orelse return null;
    if (!t.announced) return null;
    return t.info();
}

/// Sends a window management request. False when the toplevel is gone or
/// the compositor does not let this client manage toplevels.
pub fn toplevelRequest(f: *Foreign, id: u32, request: platform.ToplevelRequest) bool {
    const t = f.findToplevel(id) orelse return false;
    const h = t.wlr orelse return false;
    switch (request) {
        .activate => {
            const seat = f.backend.firstSeat() orelse return false;
            h.activate(seat);
        },
        .close => h.close(),
        .minimized => |on| if (on) h.setMinimized() else h.unsetMinimized(),
        .maximized => |on| if (on) h.setMaximized() else h.unsetMaximized(),
        .fullscreen => |fs| {
            if (h.getVersion() < 2) return false;
            if (fs.on) h.setFullscreen(if (fs.output) |o| f.backend.outputProxy(o) else null) else h.unsetFullscreen();
        },
    }
    return true;
}

// Workspaces ------------------------------------------------------------------

pub fn startWorkspaces(f: *Foreign) Error!void {
    if (f.workspace_manager != null) return;
    const g = f.workspace_global orelse return error.Unsupported;
    const m = f.backend.registry.bind(g.name, ext.WorkspaceManagerV1, 1) catch return error.OutOfMemory;
    m.setListener(*Foreign, onWorkspaceManager, f);
    f.workspace_manager = m;
}

pub fn stopWorkspaces(f: *Foreign) void {
    const m = f.workspace_manager orelse return;
    // Destroyed by its finished event (`onWorkspaceManager`).
    m.stop();
    f.workspace_manager = null;
    for (f.workspaces.items) |w| w.destroy(f.allocator());
    f.workspaces.clearRetainingCapacity();
    for (f.groups.items) |g| {
        g.proxy.destroy();
        f.allocator().destroy(g);
    }
    f.groups.clearRetainingCapacity();
}

fn onWorkspaceManager(m: *ext.WorkspaceManagerV1, event: ext.WorkspaceManagerV1.Event, f: *Foreign) void {
    if (f.workspace_manager != m) return switch (event) {
        // Stopped: objects announced before the stop arrived, then the end.
        .workspace_group => |e| e.workspace_group.destroy(),
        .workspace => |e| e.workspace.destroy(),
        .done => {},
        .finished => m.destroy(),
    };
    switch (event) {
        .workspace_group => |e| {
            f.groups.ensureUnusedCapacity(f.allocator(), 1) catch return f.dropGroup(e.workspace_group);
            const g = f.allocator().create(Group) catch return f.dropGroup(e.workspace_group);
            g.* = .{ .foreign = f, .proxy = e.workspace_group };
            f.groups.appendAssumeCapacity(g);
            e.workspace_group.setListener(*Group, onGroup, g);
        },
        .workspace => |e| {
            f.workspaces.ensureUnusedCapacity(f.allocator(), 1) catch return f.dropWorkspace(e.workspace);
            const w = f.allocator().create(Workspace) catch return f.dropWorkspace(e.workspace);
            w.* = .{ .foreign = f, .id = f.nextId(), .proxy = e.workspace };
            f.workspaces.appendAssumeCapacity(w);
            e.workspace.setListener(*Workspace, onWorkspace, w);
        },
        .done => f.workspacesDone(),
        .finished => {},
    }
}

fn dropGroup(f: *Foreign, g: *ext.WorkspaceGroupHandleV1) void {
    g.destroy();
    f.backend.queue.fail(error.OutOfMemory);
}

fn dropWorkspace(f: *Foreign, w: *ext.WorkspaceHandleV1) void {
    w.destroy();
    f.backend.queue.fail(error.OutOfMemory);
}

/// The compositor's changes are complete: report them, and forget what
/// it removed.
fn workspacesDone(f: *Foreign) void {
    var i: usize = 0;
    while (i < f.workspaces.items.len) {
        const w = f.workspaces.items[i];
        if (w.removed) {
            if (w.announced) f.push(.workspace, w.id, .removed);
            _ = f.workspaces.orderedRemove(i);
            w.destroy(f.allocator());
            continue;
        }
        if (w.dirty) f.push(.workspace, w.id, if (w.announced) .changed else .added);
        w.announced = true;
        w.dirty = false;
        i += 1;
    }
}

fn markGroup(g: *Group) void {
    for (g.foreign.workspaces.items) |w| if (w.group == g) {
        w.dirty = true;
    };
}

fn onGroup(proxy: *ext.WorkspaceGroupHandleV1, event: ext.WorkspaceGroupHandleV1.Event, g: *Group) void {
    const f = g.foreign;
    switch (event) {
        .capabilities => |e| g.can_create = @as(u32, @bitCast(e.capabilities)) & 1 != 0,
        .output_enter => |e| if (Wayland.outputOf(e.output)) |o| {
            g.outputs.add(o.id);
            markGroup(g);
        },
        .output_leave => |e| if (Wayland.outputOf(e.output)) |o| {
            if (g.outputs.remove(o.id)) markGroup(g);
        },
        .workspace_enter => |e| if (workspaceOf(e.workspace)) |w| {
            w.group = g;
            w.dirty = true;
        },
        .workspace_leave => |e| if (workspaceOf(e.workspace)) |w| if (w.group == g) {
            w.group = null;
            w.dirty = true;
        },
        .removed => {
            for (f.workspaces.items) |w| if (w.group == g) {
                w.group = null;
                w.dirty = true;
            };
            const i = std.mem.indexOfScalar(*Group, f.groups.items, g).?;
            _ = f.groups.orderedRemove(i);
            proxy.destroy();
            f.allocator().destroy(g);
        },
    }
}

fn workspaceOf(proxy: ?*ext.WorkspaceHandleV1) ?*Workspace {
    const p = proxy orelse return null;
    return @ptrCast(@alignCast(@as(*wl.Proxy, @ptrCast(p)).getUserData() orelse return null));
}

fn onWorkspace(_: *ext.WorkspaceHandleV1, event: ext.WorkspaceHandleV1.Event, w: *Workspace) void {
    const g = w.foreign.allocator();
    w.dirty = true;
    switch (event) {
        .id => |e| w.identifier.set(g, e.id),
        .name => |e| w.name.set(g, e.name),
        .coordinates => {},
        .state => |e| {
            const bits: u32 = @bitCast(e.state);
            w.states = .{ .active = bits & 1 != 0, .urgent = bits & 2 != 0, .hidden = bits & 4 != 0 };
        },
        .capabilities => |e| {
            const bits: u32 = @bitCast(e.capabilities);
            w.capabilities = .{ .activate = bits & 1 != 0, .deactivate = bits & 2 != 0, .remove = bits & 4 != 0, .assign = bits & 8 != 0 };
        },
        // Gone at the next done.
        .removed => w.removed = true,
    }
}

fn findWorkspace(f: *Foreign, id: u32) ?*Workspace {
    for (f.workspaces.items) |w| if (w.id == id) return w;
    return null;
}

pub fn workspace(f: *Foreign, id: u32) ?platform.WorkspaceInfo {
    const w = f.findWorkspace(id) orelse return null;
    if (!w.announced or w.removed) return null;
    return w.info();
}

/// Sends a workspace request and commits it. False when the workspace is
/// gone or the compositor does not allow the request for it.
pub fn workspaceRequest(f: *Foreign, id: u32, request: platform.WorkspaceRequest) bool {
    const w = f.findWorkspace(id) orelse return false;
    if (w.removed) return false;
    const m = f.workspace_manager orelse return false;
    switch (request) {
        .activate => if (w.capabilities.activate) w.proxy.activate() else return false,
        .deactivate => if (w.capabilities.deactivate) w.proxy.deactivate() else return false,
        .remove => if (w.capabilities.remove) w.proxy.remove() else return false,
    }
    m.commit();
    return true;
}

// Idle --------------------------------------------------------------------------

/// Reports `idle` events for watch `id` when the seat has had no input
/// for `timeout_ms`, and again when input resumes. Unless
/// `ignore_inhibitors`, idle inhibitors (a video playing) hold it off.
pub fn createIdleWatch(f: *Foreign, timeout_ms: u32, ignore_inhibitors: bool) Error!u32 {
    const notifier = f.idle_notifier orelse blk: {
        const g = f.idle_global orelse return error.Unsupported;
        const n = f.backend.registry.bind(g.name, ext.IdleNotifierV1, @min(g.version, 2)) catch return error.OutOfMemory;
        f.idle_notifier = n;
        break :blk n;
    };
    if (ignore_inhibitors and notifier.getVersion() < 2) return error.Unsupported;
    const seat = f.backend.firstSeat() orelse return error.MissingGlobal;
    try f.idle_watches.ensureUnusedCapacity(f.allocator(), 1);
    const w = try f.allocator().create(IdleWatch);
    errdefer f.allocator().destroy(w);
    const proxy = (if (ignore_inhibitors) notifier.getInputIdleNotification(timeout_ms, seat) else notifier.getIdleNotification(timeout_ms, seat)) catch return error.OutOfMemory;
    w.* = .{ .foreign = f, .id = f.nextId(), .proxy = proxy };
    proxy.setListener(*IdleWatch, onIdle, w);
    f.idle_watches.appendAssumeCapacity(w);
    return w.id;
}

pub fn destroyIdleWatch(f: *Foreign, id: u32) void {
    for (f.idle_watches.items, 0..) |w, i| if (w.id == id) {
        w.proxy.destroy();
        _ = f.idle_watches.swapRemove(i);
        f.allocator().destroy(w);
        return;
    };
}

fn onIdle(_: *ext.IdleNotificationV1, event: ext.IdleNotificationV1.Event, w: *IdleWatch) void {
    w.foreign.backend.queue.push(.{ .idle = .{ .watch = w.id, .idle = event == .idled } });
}
