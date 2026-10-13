//! Follows changes to the shown folder with inotify and tells the UI
//! thread through siv_post.
//!
//! siv's loop cannot watch a file descriptor of the application's
//! (FRICTION.md), so the inotify descriptor gets a thread of its own that
//! blocks in poll(2) with an eventfd to wake it for a new folder or to
//! stop. At most one post is in flight; the UI thread coalesces bursts
//! with a timer.

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;

const Watcher = @This();

gpa: std.mem.Allocator,
app: siv.App,
on_change: *const fn (ctx: ?*anyopaque) void,
ctx: ?*anyopaque,
inotify: i32,
wake: i32,
thread: std.Thread = undefined,
/// The folder to watch next (owned, NUL-terminated), set by the UI thread
/// and taken by the watcher's.
next_path: std.atomic.Value(?[*:0]u8) = .init(null),
quit: std.atomic.Value(bool) = .init(false),
/// A post is queued and has not run.
posted: std.atomic.Value(bool) = .init(false),
/// UI thread: false once destroyed; a queued post then frees it.
alive: bool = true,

pub fn create(gpa: std.mem.Allocator, app: siv.App, on_change: *const fn (?*anyopaque) void, ctx: ?*anyopaque) !*Watcher {
    const ino = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
    if (linux.errno(ino) != .SUCCESS) return error.Unavailable;
    errdefer _ = linux.close(@intCast(ino));
    const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(efd) != .SUCCESS) return error.Unavailable;
    errdefer _ = linux.close(@intCast(efd));
    const w = try gpa.create(Watcher);
    errdefer gpa.destroy(w);
    w.* = .{ .gpa = gpa, .app = app, .on_change = on_change, .ctx = ctx, .inotify = @intCast(ino), .wake = @intCast(efd) };
    w.thread = try std.Thread.spawn(.{}, run, .{w});
    return w;
}

/// Stops the thread. Called on the UI thread.
pub fn destroy(w: *Watcher) void {
    w.quit.store(true, .release);
    w.poke();
    w.thread.join();
    _ = linux.close(w.inotify);
    _ = linux.close(w.wake);
    if (w.next_path.swap(null, .acq_rel)) |p| w.gpa.free(std.mem.span(p));
    w.alive = false;
    // A queued post frees it when it runs (or is dropped).
    if (!w.posted.load(.acquire)) w.gpa.destroy(w);
}

/// Watches `path` from now on instead of the previous folder.
pub fn setPath(w: *Watcher, path: []const u8) void {
    const copy = w.gpa.dupeSentinel(u8, path, 0) catch return;
    if (w.next_path.swap(copy.ptr, .acq_rel)) |p| w.gpa.free(std.mem.span(p));
    w.poke();
}

fn poke(w: *Watcher) void {
    const one: u64 = 1;
    _ = linux.write(w.wake, std.mem.asBytes(&one), 8);
}

fn run(w: *Watcher) void {
    var wd: i32 = -1;
    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (!w.quit.load(.acquire)) {
        var fds = [_]linux.pollfd{
            .{ .fd = w.inotify, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = w.wake, .events = linux.POLL.IN, .revents = 0 },
        };
        const rc = linux.poll(&fds, fds.len, -1);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) return;
        if (fds[1].revents != 0) {
            var v: u64 = 0;
            _ = linux.read(w.wake, std.mem.asBytes(&v), 8);
            if (w.next_path.swap(null, .acq_rel)) |z| {
                defer w.gpa.free(std.mem.span(z));
                if (wd >= 0) _ = linux.inotify_rm_watch(w.inotify, wd);
                wd = -1;
                const mask = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
                    linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR;
                const r = linux.inotify_add_watch(w.inotify, z, mask);
                if (linux.errno(r) == .SUCCESS) wd = @intCast(r);
            }
        }
        if (fds[0].revents != 0) {
            var changed = false;
            while (true) {
                const n = linux.read(w.inotify, &buf, buf.len);
                if (linux.errno(n) != .SUCCESS or n == 0) break;
                changed = true;
            }
            if (changed and !w.posted.swap(true, .acq_rel)) {
                if (c.siv_post(w.app, delivered, dropped, w) != .ok) w.posted.store(false, .release);
            }
        }
    }
}

fn delivered(ud: ?*anyopaque) callconv(.c) void {
    const w: *Watcher = @ptrCast(@alignCast(ud.?));
    if (w.alive) w.on_change(w.ctx);
}

fn dropped(ud: ?*anyopaque) callconv(.c) void {
    const w: *Watcher = @ptrCast(@alignCast(ud.?));
    w.posted.store(false, .release);
    if (!w.alive) w.gpa.destroy(w);
}
