//! Follows changes to the shown folder with inotify. The descriptor is
//! watched in siv's loop (siv_app_watch_fd), so changes arrive on the UI
//! thread at a safe point; the UI thread coalesces bursts with a timer.

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;

const Watcher = @This();

gpa: std.mem.Allocator,
on_change: *const fn (ctx: ?*anyopaque) void,
ctx: ?*anyopaque,
inotify: i32,
watch: siv.Watch = .null,
/// The inotify watch of the current folder, or -1.
wd: i32 = -1,
path: [linux.PATH_MAX]u8 = undefined,
path_len: usize = 0,

pub fn create(gpa: std.mem.Allocator, app: siv.App, on_change: *const fn (?*anyopaque) void, ctx: ?*anyopaque) !*Watcher {
    const ino = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
    if (linux.errno(ino) != .SUCCESS) return error.Unavailable;
    errdefer _ = linux.close(@intCast(ino));
    const w = try gpa.create(Watcher);
    errdefer gpa.destroy(w);
    w.* = .{ .gpa = gpa, .on_change = on_change, .ctx = ctx, .inotify = @intCast(ino) };
    try siv.check(c.siv_app_watch_fd(app, w.inotify, .{ .readable = true }, ready, null, w, &w.watch));
    return w;
}

pub fn destroy(w: *Watcher) void {
    _ = c.siv_watch_destroy(w.watch);
    _ = linux.close(w.inotify);
    w.gpa.destroy(w);
}

/// Watches `path` from now on instead of the previous folder.
pub fn setPath(w: *Watcher, path: []const u8) void {
    if (w.wd >= 0 and std.mem.eql(u8, path, w.path[0..w.path_len])) return;
    if (w.wd >= 0) _ = linux.inotify_rm_watch(w.inotify, w.wd);
    w.wd = -1;
    if (path.len > w.path.len) return;
    @memcpy(w.path[0..path.len], path);
    w.path_len = path.len;
    var buf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return;
    const mask = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
        linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR;
    const r = linux.inotify_add_watch(w.inotify, z, mask);
    if (linux.errno(r) == .SUCCESS) w.wd = @intCast(r);
}

fn ready(ud: ?*anyopaque, _: siv.Watch, _: siv.WatchFlags) callconv(.c) void {
    const w: *Watcher = @ptrCast(@alignCast(ud.?));
    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    var changed = false;
    while (true) {
        const n = linux.read(w.inotify, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
            // Removing the previous folder's watch reports IN_IGNORED:
            // not a change.
            if (ev.mask & linux.IN.IGNORED == 0) changed = true;
            off += @sizeOf(linux.inotify_event) + ev.len;
        }
    }
    if (changed) w.on_change(w.ctx);
}
