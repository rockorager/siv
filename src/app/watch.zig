//! Configuration the application follows live (D29, D19): directories
//! watched with inotify on the loop. Nothing runs while nothing changes:
//! the descriptor waits in epoll, and the quiet timer is armed only after
//! an event. Events that matter restart the timer, so a burst (a theme
//! swapped in by renaming a staging directory, an editor's save through a
//! temporary file) becomes one change, `quiet_ns` after the last event.
//!
//! Each file is watched through its directory and that directory's
//! parent, so replacing the directory itself (Omarchy renames its staged
//! theme into place) or creating it later is seen too. `arm` adds the
//! watches again after every change, from a worker, since a replaced
//! directory is a new inode.

const std = @import("std");
const linux = std.os.linux;
const loop_mod = @import("loop");

const Loop = loop_mod.Loop;
const Timer = loop_mod.Timer;
const Allocator = std.mem.Allocator;

pub const quiet_ns: u64 = 50 * std.time.ns_per_ms;

/// A directory to watch, and which events in it matter.
pub const Dir = struct {
    path: [:0]const u8,
    /// Entries whose events matter; with `suffix` empty and no names,
    /// every entry's do.
    names: []const []const u8 = &.{},
    /// And entries ending in this.
    suffix: []const u8 = "",
    /// Writes to files matter, not only entries coming and going.
    files: bool = true,
};

/// A watch descriptor from `arm`, with its directory's filter (owned).
pub const Entry = struct {
    wd: i32,
    names: []const []const u8,
    suffix: []const u8,

    fn matches(e: Entry, name: []const u8) bool {
        if (e.names.len == 0 and e.suffix.len == 0) return true;
        for (e.names) |n| if (std.mem.eql(u8, n, name)) return true;
        return e.suffix.len != 0 and std.mem.endsWith(u8, name, e.suffix);
    }
};

pub const Watch = struct {
    fd: i32 = -1,
    loop: *Loop = undefined,
    gpa: Allocator = undefined,
    source: Loop.Source = .{ .fd = -1, .events = linux.EPOLL.IN, .func = onReadable },
    timer: Timer = .{ .func = onQuiet },
    /// From the last `arm`. Events on descriptors not in it count: they
    /// come from watches added since, or replaced.
    entries: []const Entry = &.{},
    on_change: *const fn (*Watch) void,

    pub fn init(w: *Watch, loop: *Loop, gpa: Allocator) error{SystemResources}!void {
        const rc = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
        w.fd = @intCast(rc);
        w.loop = loop;
        w.gpa = gpa;
        w.source.fd = w.fd;
        loop.addSource(&w.source) catch {
            _ = linux.close(w.fd);
            w.fd = -1;
            return error.SystemResources;
        };
    }

    pub fn deinit(w: *Watch) void {
        if (w.fd < 0) return;
        w.loop.cancelTimer(&w.timer);
        w.loop.removeSource(&w.source);
        _ = linux.close(w.fd);
        w.fd = -1;
        free(w.gpa, w.entries);
        w.entries = &.{};
    }

    /// Takes the entries of an `arm` (on the loop thread).
    pub fn setEntries(w: *Watch, entries: []const Entry) void {
        free(w.gpa, w.entries);
        w.entries = entries;
    }

    fn onReadable(source: *Loop.Source, _: u32) void {
        const w: *Watch = @fieldParentPtr("source", source);
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var changed = false;
        while (true) {
            const len = linux.read(w.fd, &buf, buf.len);
            if (linux.errno(len) != .SUCCESS or len == 0) break;
            var off: usize = 0;
            while (off < len) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                off += @sizeOf(linux.inotify_event) + ev.len;
                if (!changed and w.matters(ev)) changed = true;
            }
        }
        if (!changed) return;
        w.loop.startTimer(&w.timer, Loop.now() + quiet_ns, 0) catch w.on_change(w);
    }

    fn matters(w: *const Watch, ev: *const linux.inotify_event) bool {
        if (ev.mask & (linux.IN.Q_OVERFLOW | linux.IN.IGNORED | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) return true;
        const name = ev.getName() orelse return true;
        var known = false;
        for (w.entries) |e| if (e.wd == ev.wd) {
            known = true;
            if (e.matches(name)) return true;
        };
        return !known;
    }

    fn onQuiet(timer: *Timer) void {
        const w: *Watch = @fieldParentPtr("timer", timer);
        w.on_change(w);
    }
};

/// Adds a watch on each of `dirs` that exists, from any thread. Watching
/// a directory watched already keeps its descriptor.
pub fn arm(fd: i32, gpa: Allocator, dirs: []const Dir) Allocator.Error![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        free(gpa, out.items);
        out.deinit(gpa);
    }
    for (dirs) |d| {
        const entries: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO;
        const files: u32 = if (d.files) linux.IN.CLOSE_WRITE else 0;
        const rc = linux.inotify_add_watch(fd, d.path.ptr, entries | files | linux.IN.ONLYDIR | linux.IN.MASK_ADD | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF);
        if (linux.errno(rc) != .SUCCESS) continue;
        try out.ensureUnusedCapacity(gpa, 1);
        const suffix = try gpa.dupe(u8, d.suffix);
        errdefer gpa.free(suffix);
        const names = try gpa.alloc([]const u8, d.names.len);
        var n: usize = 0;
        errdefer {
            for (names[0..n]) |x| gpa.free(x);
            gpa.free(names);
        }
        while (n < names.len) : (n += 1) names[n] = try gpa.dupe(u8, d.names[n]);
        out.appendAssumeCapacity(.{ .wd = @intCast(rc), .names = names, .suffix = suffix });
    }
    return out.toOwnedSlice(gpa);
}

/// Frees what `arm` returned.
pub fn free(gpa: Allocator, entries: []const Entry) void {
    for (entries) |e| {
        for (e.names) |n| gpa.free(n);
        gpa.free(e.names);
        gpa.free(e.suffix);
    }
    gpa.free(entries);
}
