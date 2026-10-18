//! The file watcher behind hot reload (D23). A thread blocks on inotify
//! for the directories of watched files and, when a Lua file in one of
//! them changes and then stays quiet for 50 ms, posts to the application
//! with siv_post, the one call that is safe from any thread (D5). The
//! posted callback runs the prelude's reload on the UI thread at a safe
//! point. An idle application pays nothing: the thread sleeps in poll.

const std = @import("std");
const linux = std.os.linux;
const lua = @import("c.zig");
const c = lua.c;
const bind = @import("bind.zig");
const siv = @import("siv");

const State = bind.State;

const Watcher = struct {
    st: *State,
    app: u64,
    inotify: i32,
    wake: i32,
    thread: std.Thread,
    /// A posted reload has not run yet.
    posted: std.atomic.Value(bool) = .init(false),
};

const quiet_ms = 50;

/// internal.watch_start(app): starts watching for `app`.
pub fn start(Lq: ?*lua.State) callconv(.c) c_int {
    const L = Lq.?;
    const st = State.get(L);
    if (st.watcher != null) return 0;
    const app = bind.toHandleUd(L, 1) orelse lua.raise(L, "watch_start: siv.app expected", .{});
    const w = std.heap.c_allocator.create(Watcher) catch lua.raise(L, "out of memory", .{});
    const ino = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
    const ev = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (linux.errno(ino) != .SUCCESS or linux.errno(ev) != .SUCCESS) {
        std.heap.c_allocator.destroy(w);
        lua.raise(L, "hot reload: inotify is unavailable", .{});
    }
    w.* = .{ .st = st, .app = app.value, .inotify = @intCast(ino), .wake = @intCast(ev), .thread = undefined };
    w.thread = std.Thread.spawn(.{}, run, .{w}) catch {
        _ = linux.close(w.inotify);
        _ = linux.close(w.wake);
        std.heap.c_allocator.destroy(w);
        lua.raise(L, "hot reload: cannot start the watcher thread", .{});
    };
    st.watcher = w;
    st.watcher_stop = stop;
    return 0;
}

/// internal.watch_add(path): watches the directory of `path`.
pub fn add(Lq: ?*lua.State) callconv(.c) c_int {
    const L = Lq.?;
    const st = State.get(L);
    const w: *Watcher = @ptrCast(@alignCast(st.watcher orelse return 0));
    const path = lua.toString(L, 1) orelse return 0;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.path.dirname(path) orelse ".";
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0) catch return 0;
    _ = linux.inotify_add_watch(w.inotify, z.ptr, linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE);
    return 0;
}

fn stop(ptr: *anyopaque) void {
    const w: *Watcher = @ptrCast(@alignCast(ptr));
    const one: u64 = 1;
    _ = linux.write(w.wake, std.mem.asBytes(&one), 8);
    w.thread.join();
    _ = linux.close(w.inotify);
    _ = linux.close(w.wake);
    std.heap.c_allocator.destroy(w);
}

fn run(w: *Watcher) void {
    var dirty = false;
    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        var fds = [_]linux.pollfd{
            .{ .fd = w.inotify, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = w.wake, .events = linux.POLL.IN, .revents = 0 },
        };
        const n = linux.poll(&fds, fds.len, if (dirty) quiet_ms else -1);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) return;
        if (fds[1].revents != 0) return;
        if (n == 0) {
            // Quiet since the last change: reload once.
            dirty = false;
            if (!w.posted.swap(true, .acq_rel)) {
                if (siv.c.siv_post(@enumFromInt(w.app), onChange, null, w) != .ok) w.posted.store(false, .release);
            }
            continue;
        }
        while (true) {
            const len = linux.read(w.inotify, &buf, buf.len);
            if (linux.errno(len) != .SUCCESS or len == 0) break;
            var off: usize = 0;
            while (off < len) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                if (ev.getName()) |name| {
                    if (std.mem.endsWith(u8, name, ".lua")) dirty = true;
                }
                off += @sizeOf(linux.inotify_event) + ev.len;
            }
        }
    }
}

/// On the UI thread: runs the prelude's reload.
fn onChange(ud: ?*anyopaque) callconv(.c) void {
    const w: *Watcher = @ptrCast(@alignCast(ud.?));
    w.posted.store(false, .release);
    const st = w.st;
    const L = st.L;
    if (c.lua_checkstack(L, 4) == 0) return;
    const top = c.lua_gettop(L);
    st.pushTraceback(L);
    _ = c.lua_getfield(L, lua.registry, "siv.internal");
    _ = c.lua_getfield(L, -1, "reload");
    lua.remove(L, -2);
    st.depth += 1;
    if (lua.pcall(L, 0, 0, top + 1) != lua.ok) st.report(L);
    st.leave(L);
    c.lua_settop(L, top);
}
