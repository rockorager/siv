//! Exports for the trash (D42, api_system.zig): each operation is a job
//! on the worker pool's blocking lane (D6) running the `trash` module,
//! whose result reaches the C callback at a safe point (D5). Inside
//! Flatpak a file the sandbox cannot trash itself goes to the Trash
//! portal instead.
//!
//! Like siv_job_start, operations count in `App.jobs`; destroying the
//! application drops queued ones and waits for running ones, and then
//! only their destroy-notify runs. Portal calls in flight are cancelled
//! in `teardown`.

const std = @import("std");
const linux = std.os.linux;
const t = @import("siv");
const trash_mod = @import("trash");
const portal = @import("portal");
const loop_mod = @import("loop");
const runtime = @import("runtime.zig");
const application = @import("application.zig");

const App = application.App;
const Error = application.Error;
const List = std.DoublyLinkedList;

/// Operations waiting for the Trash portal.
pub const State = struct {
    portal_ops: List = .{},
};

pub fn teardown(self: *App) void {
    while (self.trash.portal_ops.popFirst()) |n| {
        const o: *Op = @fieldParentPtr("node", n);
        o.call.cancel();
        o.free();
    }
}

const Kind = enum { trash, restore, delete, list, empty };

const Op = struct {
    job: loop_mod.Pool.Job = .{ .run = run, .done = done, .cancel = dropped },
    owner: *App,
    kind: Kind,
    callback: ?t.TrashFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    /// The path or id given, and the destination (owned).
    arg: []u8,
    dest: []u8,
    /// Inside Flatpak: only the home trash, then the portal.
    flatpak: bool,
    home_buf: [linux.PATH_MAX]u8 = undefined,
    home: ?[]const u8 = null,
    uid: u32,
    // Results, written by the worker.
    status: t.TrashStatus = .ok,
    id: []u8 = &.{},
    path: []u8 = &.{},
    list: ?trash_mod.List = null,
    // The portal path.
    call: portal.trash.Call = .{ .func = onPortal },
    node: List.Node = .{},

    fn trash(o: *const Op) ?trash_mod.Trash {
        return .{ .home = o.home orelse return null, .uid = o.uid, .home_only = o.flatpak };
    }

    fn run(pj: *loop_mod.Pool.Job) void {
        const o: *Op = @fieldParentPtr("job", pj);
        o.work() catch |err| {
            o.status = statusOf(err);
        };
    }

    fn work(o: *Op) trash_mod.Error!void {
        const gpa = o.owner.gpa();
        const tr = o.trash() orelse {
            o.status = .unavailable;
            return;
        };
        // The sandbox may not see the home trash at all.
        if (o.flatpak and o.kind != .trash and !reachable(tr.home)) {
            o.status = .unavailable;
            return;
        }
        switch (o.kind) {
            .trash => o.id = try tr.trash(gpa, o.arg),
            .restore => o.path = try tr.restore(gpa, o.arg, if (o.dest.len == 0) null else o.dest),
            .delete => try tr.delete(gpa, o.arg),
            .list => o.list = try tr.list(gpa),
            .empty => try tr.empty(gpa),
        }
    }

    fn done(pj: *loop_mod.Pool.Job) void {
        const o: *Op = @fieldParentPtr("job", pj);
        const self = o.owner;
        // Out of the sandbox's reach: the portal trashes it.
        if (o.kind == .trash and o.flatpak and o.status != .ok and o.status != .not_found) {
            if (self.app.portals.get()) |client| {
                var buf: [linux.PATH_MAX]u8 = undefined;
                if (std.fmt.bufPrintSentinel(&buf, "{s}", .{o.arg}, 0)) |z| {
                    if (o.call.start(client, z)) {
                        self.trash.portal_ops.append(&o.node);
                        return;
                    } else |_| {}
                } else |_| {}
            }
            o.status = .unavailable;
        }
        o.finish();
    }

    fn onPortal(c: *portal.trash.Call, result: portal.trash.Result) void {
        const o: *Op = @fieldParentPtr("call", c);
        o.owner.trash.portal_ops.remove(&o.node);
        o.status = switch (result) {
            .trashed => .ok,
            .refused => .failed,
            .failed => |f| if (f == .unavailable) .unavailable else .failed,
        };
        o.finish();
    }

    /// Runs the callback with the results, then frees.
    fn finish(o: *Op) void {
        const self = o.owner;
        if (o.callback) |cb| {
            var r: t.TrashResult = .{ .status = o.status };
            var items: []t.TrashItem = &.{};
            defer self.gpa().free(items);
            if (o.status == .ok) {
                switch (o.kind) {
                    .trash => {
                        r.id = o.id.ptr;
                        r.id_len = o.id.len;
                        r.path = o.arg.ptr;
                        r.path_len = o.arg.len;
                    },
                    .restore, .delete => {
                        r.id = o.arg.ptr;
                        r.id_len = o.arg.len;
                        r.path = o.path.ptr;
                        r.path_len = o.path.len;
                    },
                    .list => if (o.list) |l| {
                        if (self.gpa().alloc(t.TrashItem, l.items.len)) |a| {
                            items = a;
                            for (l.items, a) |it, *x| x.* = .{
                                .id = it.id.ptr,
                                .id_len = it.id.len,
                                .path = it.path.ptr,
                                .path_len = it.path.len,
                                .deletion_time = it.deleted,
                                .bytes = it.size,
                                .flags = .{ .directory = it.directory },
                            };
                            r.items = a.ptr;
                            r.items_count = a.len;
                        } else |_| r.status = .failed;
                    },
                    .empty => {},
                }
            }
            self.enter();
            cb(o.user_data, &r);
            self.leave();
        }
        o.free();
    }

    /// Queued at teardown, or done: only the destroy-notify runs.
    fn dropped(pj: *loop_mod.Pool.Job) void {
        const o: *Op = @fieldParentPtr("job", pj);
        o.free();
    }

    fn free(o: *Op) void {
        const self = o.owner;
        const gpa = self.gpa();
        const destroy, const user_data = .{ o.destroy, o.user_data };
        gpa.free(o.arg);
        gpa.free(o.dest);
        gpa.free(o.id);
        gpa.free(o.path);
        if (o.list) |*l| l.deinit();
        gpa.destroy(o);
        self.jobs -= 1;
        self.release(destroy, user_data);
    }
};

/// The home trash's parent is visible: inside Flatpak only with access
/// to the host's data folder (`--filesystem=xdg-data/Trash` or wider).
fn reachable(home: []const u8) bool {
    var buf: [linux.PATH_MAX]u8 = undefined;
    const parent = std.fs.path.dirname(home) orelse return false;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{parent}, 0) catch return false;
    return linux.errno(linux.access(z, linux.X_OK)) == .SUCCESS;
}

fn statusOf(err: trash_mod.Error) t.TrashStatus {
    return switch (err) {
        error.FileNotFound, error.InvalidId => .not_found,
        error.AccessDenied => .access_denied,
        error.Exists => .exists,
        error.Unsupported => .unsupported,
        error.NoSpace => .no_space,
        error.NameTooLong, error.OutOfMemory, error.Unexpected => .failed,
    };
}

/// A call that took a destroy-notify and failed runs it (D2).
fn failed(self: ?*App, destroy: ?t.DestroyFn, user_data: ?*anyopaque, err: Error) t.Result {
    if (destroy) |d| if (self) |s| s.release(d, user_data) else d(user_data);
    return t.resultOf(err);
}

fn start(app: t.App, kind: Kind, arg_ptr: ?[*]const u8, arg_len: usize, dest_ptr: ?[*]const u8, dest_len: usize, callback: ?t.TrashFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return failed(null, destroy, user_data, err);
    const arg = runtime.string(arg_ptr, arg_len) catch |err| return failed(self, destroy, user_data, err);
    const dest = runtime.string(dest_ptr, dest_len) catch |err| return failed(self, destroy, user_data, err);
    const needs_arg = kind != .list and kind != .empty;
    if (needs_arg and (arg.len == 0 or arg[0] != '/')) return failed(self, destroy, user_data, error.InvalidArgument);
    if (dest.len > 0 and dest[0] != '/') return failed(self, destroy, user_data, error.InvalidArgument);
    if (std.mem.indexOfScalar(u8, arg, 0) != null or std.mem.indexOfScalar(u8, dest, 0) != null) return failed(self, destroy, user_data, error.InvalidArgument);
    const gpa = self.gpa();
    const o = gpa.create(Op) catch return failed(self, destroy, user_data, error.OutOfMemory);
    const flatpak = linux.access("/.flatpak-info", 0) == 0;
    o.* = .{ .owner = self, .kind = kind, .callback = callback, .destroy = destroy, .user_data = user_data, .arg = &.{}, .dest = &.{}, .flatpak = flatpak, .uid = linux.getuid() };
    o.arg = gpa.dupe(u8, arg) catch {
        gpa.destroy(o);
        return failed(self, destroy, user_data, error.OutOfMemory);
    };
    o.dest = gpa.dupe(u8, dest) catch {
        gpa.free(o.arg);
        gpa.destroy(o);
        return failed(self, destroy, user_data, error.OutOfMemory);
    };
    // The environment is read here, on the application's thread.
    o.home = trash_mod.homeTrash(&o.home_buf, flatpak);
    o.job.class = .blocking;
    self.jobs += 1;
    self.app.pool.submit(&o.job) catch |err| {
        self.jobs -= 1;
        gpa.free(o.arg);
        gpa.free(o.dest);
        gpa.destroy(o);
        return failed(self, destroy, user_data, switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SystemResources => error.Unavailable,
        });
    };
    return .ok;
}

pub export fn siv_trash_file(app: t.App, path: ?[*]const u8, path_len: usize, callback: ?t.TrashFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    return start(app, .trash, path, path_len, null, 0, callback, destroy, user_data);
}

pub export fn siv_trash_restore(app: t.App, id: ?[*]const u8, id_len: usize, dest: ?[*]const u8, dest_len: usize, callback: ?t.TrashFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    return start(app, .restore, id, id_len, dest, dest_len, callback, destroy, user_data);
}

pub export fn siv_trash_delete(app: t.App, id: ?[*]const u8, id_len: usize, callback: ?t.TrashFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    return start(app, .delete, id, id_len, null, 0, callback, destroy, user_data);
}

pub export fn siv_trash_list(app: t.App, callback: ?t.TrashFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    return start(app, .list, null, 0, null, 0, callback, destroy, user_data);
}

pub export fn siv_trash_empty(app: t.App, callback: ?t.TrashFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    return start(app, .empty, null, 0, null, 0, callback, destroy, user_data);
}
