//! siv_app_watch_fd: application file descriptors in siv's loop (D5, D6).
//! The io phase only records readiness and schedules a dispatch task; the
//! callback runs in the dispatch phase, like every application callback.

const std = @import("std");
const linux = std.os.linux;
const t = @import("siv");
const loop_mod = @import("loop");
const api = @import("api.zig");
const runtime = @import("runtime.zig");
const application = @import("application.zig");

const App = application.App;
const Root = runtime.Root;
const EPOLL = linux.EPOLL;

pub const watch_tag = api.spec.handleTag("siv_watch");

pub const Watch = struct {
    source: loop_mod.Loop.Source,
    task: loop_mod.Loop.Task = .{ .func = run },
    owner: *App,
    index: u32,
    handle: u64,
    /// Readiness seen since the callback last ran.
    ready: u32 = 0,
    callback: t.WatchFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn onReady(source: *loop_mod.Loop.Source, events: u32) void {
        const w: *Watch = @fieldParentPtr("source", source);
        w.ready |= events;
        w.owner.app.loop.schedule(&w.task, .dispatch);
    }

    fn run(task: *loop_mod.Loop.Task) void {
        const w: *Watch = @fieldParentPtr("task", task);
        const events = flagsOf(w.ready);
        w.ready = 0;
        const self = w.owner;
        // The callback may destroy the watch: nothing touches it after.
        const cb = w.callback;
        const ud = w.user_data;
        const handle: t.Watch = @fromBackingInt(w.handle);
        self.enter();
        cb(ud, handle, events);
        self.leave();
    }

    /// Destroyed, or dropped with the application.
    pub fn remove(w: *Watch) void {
        const self = w.owner;
        self.app.loop.removeSource(&w.source);
        self.app.loop.unschedule(&w.task);
        _ = self.root.handles.remove(w.handle, watch_tag) catch unreachable;
        self.watches.items[w.index] = null;
        self.release(w.destroy, w.user_data);
        self.gpa().destroy(w);
    }
};

fn epollOf(f: t.WatchFlags) u32 {
    var e: u32 = EPOLL.RDHUP;
    if (f.readable) e |= EPOLL.IN;
    if (f.writable) e |= EPOLL.OUT;
    return e;
}

fn flagsOf(e: u32) t.WatchFlags {
    return .{
        .readable = e & EPOLL.IN != 0,
        .writable = e & EPOLL.OUT != 0,
        .hangup = e & (EPOLL.HUP | EPOLL.RDHUP) != 0,
        .@"error" = e & EPOLL.ERR != 0,
    };
}

/// An open descriptor epoll takes: not a regular file or a directory,
/// which are always ready (epoll refuses them).
fn pollable(fd: i32) bool {
    if (fd < 0) return false;
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stx)) != .SUCCESS) return false;
    const kind = stx.mode & linux.S.IFMT;
    return kind != linux.S.IFREG and kind != linux.S.IFDIR;
}

fn requested(f: t.WatchFlags) runtime.Error!t.WatchFlags {
    const v = try runtime.flags(t.WatchFlags, f);
    // Hangup and error are reported, never asked for.
    if (v.hangup or v.@"error") return error.InvalidArgument;
    return v;
}

pub export fn siv_app_watch_fd(app: t.App, fd: i32, events: t.WatchFlags, callback: ?t.WatchFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, watch: ?*t.Watch) t.Result {
    const self = App.get(@backingInt(app)) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    const r = start(self, fd, events, callback, destroy, user_data, watch) catch |err| t.resultOf(err);
    // The call failed: the caller handed user_data over anyway (D2).
    if (r != .ok) self.release(destroy, user_data);
    return r;
}

fn start(self: *App, fd: i32, events: t.WatchFlags, callback: ?t.WatchFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, out: ?*t.Watch) runtime.Error!t.Result {
    const cb = callback orelse return error.InvalidArgument;
    const dest = try runtime.out(t.Watch, out);
    const want = try requested(events);
    if (!pollable(fd)) return error.InvalidArgument;
    for (self.watches.items) |slot| if (slot) |o| if (o.source.fd == fd) return error.InvalidArgument;
    const gpa = self.gpa();
    const index: u32 = for (self.watches.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        try self.watches.append(gpa, null);
        break :blk @intCast(self.watches.items.len - 1);
    };
    const w = try gpa.create(Watch);
    errdefer gpa.destroy(w);
    w.* = .{
        .source = .{ .fd = fd, .events = epollOf(want), .func = Watch.onReady },
        .owner = self,
        .index = index,
        .handle = 0,
        .callback = cb,
        .destroy = destroy,
        .user_data = user_data,
    };
    try self.root.handles.ensureUnusedCapacity(gpa);
    self.app.loop.addSource(&w.source) catch return error.OutOfMemory;
    w.handle = self.root.handles.insert(gpa, watch_tag, index) catch unreachable;
    self.watches.items[index] = w;
    dest.* = @fromBackingInt(w.handle);
    return .ok;
}

fn lookup(watch: t.Watch) runtime.Error!*Watch {
    const self, const index = try Root.owner(App, application.app_tag, @backingInt(watch), watch_tag);
    return self.watches.items[index] orelse error.InvalidHandle;
}

pub export fn siv_watch_set_events(watch: t.Watch, events: t.WatchFlags) t.Result {
    const w = lookup(watch) catch |err| return t.resultOf(err);
    const want = requested(events) catch |err| return t.resultOf(err);
    w.owner.app.loop.modifySource(&w.source, epollOf(want)) catch return .error_unavailable;
    return .ok;
}

pub export fn siv_watch_destroy(watch: t.Watch) t.Result {
    const w = lookup(watch) catch |err| return t.resultOf(err);
    w.remove();
    return .ok;
}
