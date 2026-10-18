//! Settings and state (D36): typed values an application keeps between
//! runs, in a TOML file of its own that people can read and edit.
//!
//! - Preferences go in `$XDG_CONFIG_HOME/<app_id>/<name>.toml`, state
//!   (window sizes, the last folder) in `$XDG_STATE_HOME/<app_id>/`, or a
//!   directory the application names. Under Flatpak those variables
//!   already point into the application's own directory.
//! - The file holds only values the application set: its defaults stay
//!   in its code, so a new default reaches everyone who never changed it.
//! - Reads are from memory. The file is read once at `open`, on the
//!   application's thread (the first window's size depends on it), and
//!   again on the worker pool whenever inotify sees it change.
//! - Changes apply in memory at once and reach the file `write_delay_ns`
//!   after the first unsaved one, one write for a burst, on the pool's
//!   blocking lane. A write locks the directory (flock), reads the file,
//!   applies this store's changes key by key, and renames a new file into
//!   place, so another instance's changes to other keys survive and a
//!   crash leaves the old file or the new one. `App.destroy` writes what
//!   is left on its own thread, after the pool has stopped.
//! - Listeners hear of every key whose value changed, whoever changed
//!   it, at the next dispatch (D5).

const std = @import("std");
const linux = std.os.linux;
const ui = @import("ui");
const loop_mod = @import("loop");
const watch = @import("watch.zig");
const app_mod = @import("app.zig");

const Allocator = std.mem.Allocator;
const Loop = loop_mod.Loop;
const Timer = loop_mod.Timer;
const Pool = loop_mod.Pool;
const App = app_mod.App;

pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    float: f64,
    /// UTF-8; owned by the map that holds it.
    string: []const u8,

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .boolean => |v| v == b.boolean,
            .integer => |v| v == b.integer,
            .float => |v| v == b.float,
            .string => |v| std.mem.eql(u8, v, b.string),
        };
    }

    fn dupe(v: Value, gpa: Allocator) Allocator.Error!Value {
        return switch (v) {
            .string => |s| .{ .string = try gpa.dupe(u8, s) },
            else => v,
        };
    }

    fn free(v: Value, gpa: Allocator) void {
        if (v == .string) gpa.free(v.string);
    }
};

pub const Kind = enum { config, state };

/// Who changed a value.
pub const Origin = enum {
    /// This store.
    application,
    /// Another process, or someone editing the file.
    outside,
};

/// Longest key; keys are dot-separated names of ASCII letters, digits,
/// `_`, and `-`.
pub const max_key = 255;
/// Longest string value, in bytes.
pub const max_string = 4096;
/// A larger file is not read, and not replaced.
pub const max_bytes = 1 << 20;
/// Changes reach the file this long after the first unsaved one.
pub const write_delay_ns: u64 = 500 * std.time.ns_per_ms;

/// Values by key; keys and strings owned.
pub const Map = std.StringArrayHashMapUnmanaged(Value);
/// Changes not yet in the file by key, null for a reset; owned.
const Changes = std.StringArrayHashMapUnmanaged(?Value);

pub const Listener = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (ctx: ?*anyopaque, key: []const u8, origin: Origin) void = null,
};

pub const Options = struct {
    kind: Kind = .config,
    /// The file's name without `.toml`; empty is "settings" for
    /// preferences and "state" for state.
    name: []const u8 = "",
    /// The file's directory instead of the XDG one.
    directory: []const u8 = "",
    /// No file: values live in memory only (the headless backend without
    /// a directory, so tests never touch the user's files).
    memory: bool = false,
    listener: Listener = .{},
};

pub const OpenError = error{
    OutOfMemory,
    /// A bad name or directory, or no application id to find the
    /// directory by.
    InvalidArgument,
    /// The application has that file open already.
    Busy,
    /// Neither the XDG variable nor $HOME says where the file goes.
    Unavailable,
};

const Note = struct { key: []u8, origin: Origin };

pub const Store = struct {
    gpa: Allocator,
    app: *App,
    /// Absolute, without a trailing slash; empty for a memory store.
    dir: [:0]u8,
    /// "<name>.toml".
    file: [:0]u8,
    values: Map = .empty,
    /// Changes since the last write started.
    pending: Changes = .empty,
    /// Changes the running write applies; the worker's while it runs.
    writing: Changes = .empty,
    listener: Listener,
    notes: std.ArrayList(Note) = .empty,
    task: Loop.Task = .{ .func = onTask },
    /// Delivering notes: a listener's `close` frees the store afterwards.
    delivering: bool = false,
    timer: Timer = .{ .func = onTimer },
    watch: watch.Watch = .{ .on_change = onChange },
    job: Pool.Job = .{ .run = run, .done = done, .cancel = cancel, .class = .blocking },
    running: bool = false,
    /// The file changed while a job ran: read it again.
    again: bool = false,
    /// Closed by the application: goes once its changes are written.
    closing: bool = false,
    /// Closing: a failed write was tried again.
    retried: bool = false,
    // The job's results, for `done`.
    result: ?Map = null,
    entries: []const watch.Entry = &.{},

    pub fn open(app: *App, options: Options) OpenError!*Store {
        const gpa = app.gpa;
        const name = if (options.name.len != 0) options.name else switch (options.kind) {
            .config => "settings",
            .state => "state",
        };
        if (!validName(name)) return error.InvalidArgument;
        const dir: [:0]u8 = if (options.memory) try gpa.dupeSentinel(u8, "", 0) else try directory(gpa, app.app_id.slice(), options, .get());
        errdefer gpa.free(dir);
        const file = try std.fmt.allocPrintSentinel(gpa, "{s}.toml", .{name}, 0);
        errdefer gpa.free(file);
        if (!options.memory) for (app.settings.items) |o| {
            if (!o.closing and std.mem.eql(u8, o.dir, dir) and std.mem.eql(u8, o.file, file)) return error.Busy;
        };
        try app.settings.ensureUnusedCapacity(gpa, 1);
        const s = try gpa.create(Store);
        s.* = .{ .gpa = gpa, .app = app, .dir = dir, .file = file, .listener = options.listener };
        if (!options.memory) {
            // Watches first, so that a change after them is seen and one
            // before them is read.
            s.watch.init(&app.loop, gpa) catch {};
            if (s.watch.fd >= 0) if (armWatch(gpa, s.watch.fd, dir, file)) |entries| s.watch.setEntries(entries) else |_| {};
            if (readMap(gpa, dir, file)) |m| {
                s.values = m;
            } else |_| {}
        }
        app.settings.appendAssumeCapacity(s);
        return s;
    }

    pub fn get(s: *const Store, key: []const u8) ?Value {
        return s.values.get(key);
    }

    /// Sets a key; a value equal to the current one changes nothing.
    pub fn set(s: *Store, key: []const u8, value: Value) Allocator.Error!void {
        std.debug.assert(validKey(key) and validValue(value));
        if (s.values.get(key)) |old| if (old.eql(value)) return;
        try s.change(key, value);
    }

    /// Removes a key's value, so the application's default applies.
    pub fn reset(s: *Store, key: []const u8) Allocator.Error!void {
        std.debug.assert(validKey(key));
        if (!s.values.contains(key)) return;
        try s.change(key, null);
    }

    fn change(s: *Store, key: []const u8, value: ?Value) Allocator.Error!void {
        const gpa = s.gpa;
        // Allocate everything first, so a failure changes nothing.
        try s.values.ensureUnusedCapacity(gpa, 1);
        try s.notes.ensureUnusedCapacity(gpa, 1);
        const persist = s.dir.len != 0;
        if (persist) try s.pending.ensureUnusedCapacity(gpa, 1);
        const nkey = try gpa.dupe(u8, key);
        errdefer gpa.free(nkey);
        if (persist) {
            const pkey = try gpa.dupe(u8, key);
            errdefer gpa.free(pkey);
            const pv = if (value) |x| try x.dupe(gpa) else null;
            errdefer if (pv) |x| x.free(gpa);
            try applyChange(gpa, &s.values, key, value);
            // Nothing fails below.
            putChange(gpa, &s.pending, pkey, pv);
            if (!s.timer.armed() and !s.running) s.app.loop.startTimer(&s.timer, Loop.now() + write_delay_ns, 0) catch s.submit();
        } else try applyChange(gpa, &s.values, key, value);
        s.note(nkey, .application);
    }

    /// Queues a note, or merges it with one queued for the key.
    fn note(s: *Store, key: []u8, origin: Origin) void {
        for (s.notes.items) |*n| if (std.mem.eql(u8, n.key, key)) {
            s.gpa.free(key);
            n.origin = origin;
            return;
        };
        s.notes.appendAssumeCapacity(.{ .key = key, .origin = origin });
        s.app.loop.schedule(&s.task, .dispatch);
    }

    /// The application is done with the store: no more notes. It goes
    /// once its changes are written (at once if there are none).
    pub fn close(s: *Store) void {
        s.listener = .{};
        s.freeNotes();
        s.app.loop.unschedule(&s.task);
        // A running job reads the watch's descriptor: it goes with the
        // store then.
        if (!s.running) s.watch.deinit();
        s.closing = true;
        s.again = false;
        if (s.pending.count() != 0 and !s.running) {
            s.app.loop.cancelTimer(&s.timer);
            s.submit();
        }
        if (!s.running and !s.delivering) s.destroy();
    }

    fn destroy(s: *Store) void {
        const app = s.app;
        for (app.settings.items, 0..) |o, i| if (o == s) {
            _ = app.settings.swapRemove(i);
            break;
        };
        s.app.loop.cancelTimer(&s.timer);
        s.free();
    }

    /// `App.destroy`, after the pool stopped (no job runs): writes what is
    /// left on this thread and leaves the loop.
    pub fn finish(s: *Store) void {
        s.app.loop.cancelTimer(&s.timer);
        s.app.loop.unschedule(&s.task);
        s.watch.deinit();
        if (s.dir.len == 0) return;
        // A write that ran but was not delivered applied `writing`
        // already; applying it again changes nothing.
        var it = s.pending.iterator();
        while (it.next()) |e| {
            const k = s.gpa.dupe(u8, e.key_ptr.*) catch continue;
            const v = if (e.value_ptr.*) |x| x.dupe(s.gpa) catch {
                s.gpa.free(k);
                continue;
            } else null;
            s.writing.ensureUnusedCapacity(s.gpa, 1) catch {
                s.gpa.free(k);
                if (v) |x| x.free(s.gpa);
                continue;
            };
            putChange(s.gpa, &s.writing, k, v);
        }
        if (s.writing.count() == 0) return;
        if (writeFile(s.gpa, s.dir, s.file, &s.writing)) |m| {
            var map = m;
            freeMap(s.gpa, &map);
        } else |_| {}
    }

    /// Frees everything; the loop must hold nothing of it.
    pub fn free(s: *Store) void {
        const gpa = s.gpa;
        s.watch.deinit();
        s.freeNotes();
        s.notes.deinit(gpa);
        freeMap(gpa, &s.values);
        freeChanges(gpa, &s.pending);
        freeChanges(gpa, &s.writing);
        if (s.result) |*m| freeMap(gpa, m);
        watch.free(gpa, s.entries);
        gpa.free(s.dir);
        gpa.free(s.file);
        gpa.destroy(s);
    }

    fn freeNotes(s: *Store) void {
        for (s.notes.items) |n| s.gpa.free(n.key);
        s.notes.clearRetainingCapacity();
    }

    /// Starts a job: a write of the pending changes, or a read.
    fn submit(s: *Store) void {
        if (s.running) {
            s.again = true;
            return;
        }
        std.debug.assert(s.writing.count() == 0);
        s.writing = s.pending;
        s.pending = .empty;
        s.app.pool.submit(&s.job) catch {
            s.pending = s.writing;
            s.writing = .empty;
            return;
        };
        s.running = true;
    }

    fn onTask(task: *Loop.Task) void {
        const s: *Store = @fieldParentPtr("task", task);
        s.delivering = true;
        // Notes queued by listeners wait for the next dispatch.
        var notes = s.notes;
        s.notes = .empty;
        for (notes.items) |n| {
            const l = s.listener;
            if (l.func) |f| f(l.ctx, n.key, n.origin);
        }
        for (notes.items) |n| s.gpa.free(n.key);
        notes.deinit(s.gpa);
        s.delivering = false;
        if (s.closing and !s.running) s.destroy();
    }

    fn onTimer(timer: *Timer) void {
        const s: *Store = @fieldParentPtr("timer", timer);
        s.submit();
    }

    fn onChange(w: *watch.Watch) void {
        const s: *Store = @fieldParentPtr("watch", w);
        if (!s.closing) s.submit();
    }

    /// Adopts what the file holds now under the pending changes, and
    /// notes every key whose value changed.
    fn adopt(s: *Store, file: *Map) void {
        const gpa = s.gpa;
        var it = s.pending.iterator();
        while (it.next()) |e| applyChange(gpa, file, e.key_ptr.*, e.value_ptr.*) catch {
            // Without memory to merge, keep what is shown.
            freeMap(gpa, file);
            return;
        };
        if (s.closing) {
            freeMap(gpa, &s.values);
            s.values = file.*;
            return;
        }
        var old = s.values;
        s.values = file.*;
        for (old.keys(), old.values()) |k, v| {
            const now = s.values.get(k);
            if (now == null or !now.?.eql(v)) s.noteOutside(k);
        }
        for (s.values.keys()) |k| if (!old.contains(k)) s.noteOutside(k);
        freeMap(gpa, &old);
    }

    fn noteOutside(s: *Store, key: []const u8) void {
        s.notes.ensureUnusedCapacity(s.gpa, 1) catch return;
        s.note(s.gpa.dupe(u8, key) catch return, .outside);
    }
};

fn done(job: *Pool.Job) void {
    const s: *Store = @fieldParentPtr("job", job);
    const gpa = s.gpa;
    s.running = false;
    if (s.watch.fd >= 0) s.watch.setEntries(s.entries) else watch.free(gpa, s.entries);
    s.entries = &.{};
    // A write that failed waits for the next change rather than trying
    // again on a timer (a read-only file system would write forever).
    const failed = s.result == null and s.writing.count() != 0;
    if (s.result) |r| {
        var m = r;
        s.result = null;
        freeChanges(gpa, &s.writing);
        s.adopt(&m);
    } else {
        // Not written: the changes wait for the next write, under any
        // made since.
        var it = s.writing.iterator();
        while (it.next()) |e| {
            if (s.pending.contains(e.key_ptr.*) or s.pending.ensureUnusedCapacity(gpa, 1) == error.OutOfMemory) {
                gpa.free(e.key_ptr.*);
                if (e.value_ptr.*) |v| v.free(gpa);
                continue;
            }
            s.pending.putAssumeCapacity(e.key_ptr.*, e.value_ptr.*);
        }
        s.writing.clearAndFree(gpa);
    }
    if (s.closing) {
        // One more try for what is left, then gone.
        if (s.pending.count() != 0 and !s.retried) {
            s.retried = true;
            s.submit();
            if (s.running) return;
        }
        if (!s.delivering) s.destroy();
        return;
    }
    if (s.again) {
        s.again = false;
        s.submit();
    } else if (!failed and s.pending.count() != 0 and !s.timer.armed()) {
        s.app.loop.startTimer(&s.timer, Loop.now() + write_delay_ns, 0) catch s.submit();
    }
}

fn cancel(job: *Pool.Job) void {
    const s: *Store = @fieldParentPtr("job", job);
    s.running = false;
    if (s.result) |*m| freeMap(s.gpa, m);
    s.result = null;
    watch.free(s.gpa, s.entries);
    s.entries = &.{};
}

// On a worker ---------------------------------------------------------------

fn run(job: *Pool.Job) void {
    const s: *Store = @fieldParentPtr("job", job);
    if (s.watch.fd >= 0) s.entries = armWatch(s.gpa, s.watch.fd, s.dir, s.file) catch &.{};
    s.result = if (s.writing.count() != 0)
        writeFile(s.gpa, s.dir, s.file, &s.writing) catch null
    else
        readMap(s.gpa, s.dir, s.file) catch null;
}

/// Watches the file through its directory and the directory's parent,
/// which may not exist yet either.
fn armWatch(gpa: Allocator, fd: i32, dir: [:0]const u8, file: []const u8) Allocator.Error![]const watch.Entry {
    var names = [_][]const u8{file};
    var dirs: [2]watch.Dir = undefined;
    var n: usize = 0;
    dirs[n] = .{ .path = dir, .names = &names };
    n += 1;
    var parent_buf: [linux.PATH_MAX]u8 = undefined;
    var child = [_][]const u8{std.fs.path.basename(dir)};
    if (std.fs.path.dirname(dir)) |parent| if (parent.len < parent_buf.len) {
        @memcpy(parent_buf[0..parent.len], parent);
        parent_buf[parent.len] = 0;
        dirs[n] = .{ .path = parent_buf[0..parent.len :0], .names = &child, .files = false };
        n += 1;
    };
    return watch.arm(fd, gpa, dirs[0..n]);
}

// Files -----------------------------------------------------------------------

/// The environment `directory` reads.
const Env = struct {
    config_home: []const u8,
    state_home: []const u8,
    home: []const u8,

    fn get() Env {
        return .{ .config_home = env("XDG_CONFIG_HOME"), .state_home = env("XDG_STATE_HOME"), .home = env("HOME") };
    }
};

/// Where the file goes: the directory option, else the XDG directory
/// for the kind under the application id.
fn directory(gpa: Allocator, app_id: []const u8, options: Options, e: Env) OpenError![:0]u8 {
    if (options.directory.len != 0) {
        const d = std.mem.trimEnd(u8, options.directory, "/");
        if (d.len == 0 or options.directory[0] != '/' or std.mem.indexOfScalar(u8, d, 0) != null) return error.InvalidArgument;
        return gpa.dupeSentinel(u8, d, 0);
    }
    if (!validName(app_id)) return error.InvalidArgument;
    const base, const fallback = switch (options.kind) {
        .config => .{ e.config_home, ".config" },
        .state => .{ e.state_home, ".local/state" },
    };
    // Relative values are invalid by the XDG spec, and ignored.
    if (base.len != 0 and base[0] == '/') return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), app_id }, 0);
    if (e.home.len == 0 or e.home[0] != '/') return error.Unavailable;
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}/{s}", .{ std.mem.trimEnd(u8, e.home, "/"), fallback, app_id }, 0);
}

fn env(name: [*:0]const u8) []const u8 {
    return std.mem.span(std.c.getenv(name) orelse return "");
}

const ReadError = error{ OutOfMemory, Unreadable };

/// The file's values; empty when it does not exist.
fn readMap(gpa: Allocator, dir: [:0]const u8, file: [:0]const u8) ReadError!Map {
    const dfd = openDir(dir) catch return .empty;
    defer _ = linux.close(dfd);
    return readAt(gpa, dfd, file);
}

fn readAt(gpa: Allocator, dfd: i32, file: [:0]const u8) ReadError!Map {
    const rc = linux.openat(dfd, file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT => return .empty,
        else => return error.Unreadable,
    }
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    // Sized from statx, and grown if the file grows while it is read.
    var stx: linux.Statx = undefined;
    const size: usize = if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx)) == .SUCCESS) @intCast(@min(stx.size, max_bytes)) else 4096;
    var buf = try gpa.alloc(u8, size + 1);
    defer gpa.free(buf);
    var n: usize = 0;
    while (true) {
        if (n == buf.len) {
            if (buf.len > max_bytes) break;
            buf = try gpa.realloc(buf, @min(buf.len * 2, max_bytes + 1));
        }
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        switch (linux.errno(r)) {
            .SUCCESS => if (r == 0) break else {
                n += r;
            },
            .INTR => {},
            else => return error.Unreadable,
        }
    }
    if (n > max_bytes) return error.Unreadable;
    return parse(gpa, buf[0..n]);
}

fn openDir(dir: [:0]const u8) error{Unavailable}!i32 {
    const rc = linux.openat(linux.AT.FDCWD, dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Unavailable;
    return @intCast(rc);
}

const WriteError = error{ OutOfMemory, Unreadable, Unavailable };

/// Applies `changes` to the file under the directory's lock and returns
/// what it holds now. Creates the directory (0700, as XDG asks).
fn writeFile(gpa: Allocator, dir: [:0]const u8, file: [:0]const u8, changes: *const Changes) WriteError!Map {
    try makeDirs(dir);
    const dfd = try openDir(dir);
    defer _ = linux.close(dfd); // and unlocks
    while (true) switch (linux.errno(linux.flock(dfd, std.posix.LOCK.EX))) {
        .SUCCESS => break,
        .INTR => {},
        else => return error.Unavailable,
    };
    var map = try readAt(gpa, dfd, file);
    errdefer freeMap(gpa, &map);
    var it = changes.iterator();
    while (it.next()) |e| try applyChange(gpa, &map, e.key_ptr.*, e.value_ptr.*);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try serialize(gpa, &out, &map);

    var tmp_buf: [300]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tmp_buf, ".{s}.new", .{file}, 0) catch return error.Unavailable;
    // The new file keeps the old one's permissions.
    var mode: linux.mode_t = 0o600;
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(dfd, file, 0, .{ .MODE = true }, &stx)) == .SUCCESS) mode = stx.mode & 0o777;
    const rc = linux.openat(dfd, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, mode);
    if (linux.errno(rc) != .SUCCESS) return error.Unavailable;
    const fd: i32 = @intCast(rc);
    const written = writeAll(fd, out.items) and linux.errno(linux.fchmod(fd, mode)) == .SUCCESS and linux.errno(linux.fsync(fd)) == .SUCCESS;
    _ = linux.close(fd);
    if (!written or linux.errno(linux.renameat(dfd, tmp, dfd, file)) != .SUCCESS) {
        _ = linux.unlinkat(dfd, tmp, 0);
        return error.Unavailable;
    }
    _ = linux.fsync(dfd);
    return map;
}

fn writeAll(fd: i32, bytes: []const u8) bool {
    var n: usize = 0;
    while (n < bytes.len) {
        const r = linux.write(fd, bytes[n..].ptr, bytes.len - n);
        switch (linux.errno(r)) {
            .SUCCESS => n += r,
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

/// `mkdir -p` with mode 0700 for what it creates.
fn makeDirs(dir: [:0]const u8) error{Unavailable}!void {
    var buf: [linux.PATH_MAX]u8 = undefined;
    if (dir.len >= buf.len) return error.Unavailable;
    @memcpy(buf[0..dir.len], dir);
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i != dir.len and dir[i] != '/') continue;
        buf[i] = 0;
        switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, @ptrCast(&buf), 0o700))) {
            .SUCCESS, .EXIST => {},
            else => return error.Unavailable,
        }
        if (i != dir.len) buf[i] = '/';
    }
}

// The format ------------------------------------------------------------------

/// Keys: one or more names joined by dots, each of ASCII letters,
/// digits, `_`, and `-`, at most `max_key` bytes in all.
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key) return false;
    var start: usize = 0;
    for (key, 0..) |ch, i| {
        if (ch == '.') {
            if (i == start) return false;
            start = i + 1;
        } else if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return false;
    }
    return start < key.len;
}

/// File names and application ids: no slashes, not hidden.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255 or name[0] == '.') return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return false;
    return true;
}

pub fn validValue(v: Value) bool {
    return switch (v) {
        .float => |f| std.math.isFinite(f),
        .string => |s| s.len <= max_string and std.unicode.utf8ValidateSlice(s),
        else => true,
    };
}

/// The entries of a TOML file (ui.user_theme.Parser's subset) whose key
/// and value are valid; later ones win. Arrays and inline tables are
/// not settings, and are skipped.
pub fn parse(gpa: Allocator, src: []const u8) Allocator.Error!Map {
    var map: Map = .empty;
    errdefer freeMap(gpa, &map);
    var long: [max_string]u8 = undefined;
    var p: ui.user_theme.Parser = .init(src);
    p.long = &long;
    var key_buf: [max_key + 1]u8 = undefined;
    while (p.next()) |e| {
        // `[a.b]` and `c . d = 1` make "a.b.c.d".
        var n: usize = 0;
        var ok = true;
        for ([_][]const u8{ e.table, if (e.table.len != 0) "." else "", e.key }) |part| for (part) |ch| {
            if (ch == ' ' or ch == '\t') continue;
            if (n == key_buf.len) {
                ok = false;
                break;
            }
            key_buf[n] = ch;
            n += 1;
        };
        const key = key_buf[0..n];
        if (!ok or !validKey(key)) continue;
        const v: Value = switch (e.value) {
            .string => |s| .{ .string = s },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .boolean => |b| .{ .boolean = b },
        };
        if (!validValue(v)) continue;
        try applyChange(gpa, &map, key, v);
    }
    return map;
}

/// Writes the values as TOML: top-level keys, then a table per prefix,
/// sorted, so the file diffs well and reads like one written by hand.
pub fn serialize(gpa: Allocator, out: *std.ArrayList(u8), map: *const Map) Allocator.Error!void {
    const keys = try gpa.dupe([]const u8, map.keys());
    defer gpa.free(keys);
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            const ta = table(a);
            const tb = table(b);
            if (!std.mem.eql(u8, ta, tb)) return std.mem.lessThan(u8, ta, tb);
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    try out.appendSlice(gpa, "# Kept by the application through siv. Edits apply while it runs;\n# comments are not kept.\n");
    var current: ?[]const u8 = null;
    for (keys) |k| {
        const t = table(k);
        if (current == null or !std.mem.eql(u8, current.?, t)) {
            if (t.len != 0) try out.print(gpa, "\n[{s}]\n", .{t});
            current = t;
        }
        try out.print(gpa, "{s} = ", .{if (t.len == 0) k else k[t.len + 1 ..]});
        switch (map.get(k).?) {
            .boolean => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
            .integer => |i| try out.print(gpa, "{d}", .{i}),
            .float => |f| try writeFloat(gpa, out, f),
            .string => |s| try writeString(gpa, out, s),
        }
        try out.append(gpa, '\n');
    }
}

/// The table a key is written under: everything before its last dot.
fn table(key: []const u8) []const u8 {
    return key[0 .. std.mem.lastIndexOfScalar(u8, key, '.') orelse 0];
}

/// Always reads back as a float: with a point or an exponent.
fn writeFloat(gpa: Allocator, out: *std.ArrayList(u8), f: f64) Allocator.Error!void {
    const a = @abs(f);
    const start = out.items.len;
    if (a != 0 and (a < 1e-5 or a >= 1e15)) try out.print(gpa, "{e}", .{f}) else try out.print(gpa, "{d}", .{f});
    if (std.mem.indexOfAny(u8, out.items[start..], ".e") == null) try out.appendSlice(gpa, ".0");
}

/// A TOML basic string.
fn writeString(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        0...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => try out.print(gpa, "\\u{X:0>4}", .{ch}),
        else => try out.append(gpa, ch),
    };
    try out.append(gpa, '"');
}

fn applyChange(gpa: Allocator, map: *Map, key: []const u8, value: ?Value) Allocator.Error!void {
    const v = value orelse {
        if (map.fetchSwapRemove(key)) |kv| {
            gpa.free(kv.key);
            kv.value.free(gpa);
        }
        return;
    };
    try map.ensureUnusedCapacity(gpa, 1);
    const copy = try v.dupe(gpa);
    errdefer copy.free(gpa);
    const gop = map.getOrPutAssumeCapacity(key);
    if (gop.found_existing) {
        gop.value_ptr.free(gpa);
    } else {
        gop.key_ptr.* = gpa.dupe(u8, key) catch |err| {
            map.swapRemoveAt(gop.index);
            return err;
        };
    }
    gop.value_ptr.* = copy;
}

/// Takes `key` and `value`; capacity must be reserved.
fn putChange(gpa: Allocator, changes: *Changes, key: []u8, value: ?Value) void {
    const gop = changes.getOrPutAssumeCapacity(key);
    if (gop.found_existing) {
        gpa.free(key);
        if (gop.value_ptr.*) |old| old.free(gpa);
    }
    gop.value_ptr.* = value;
}

fn freeMap(gpa: Allocator, map: *Map) void {
    for (map.keys(), map.values()) |k, v| {
        gpa.free(k);
        v.free(gpa);
    }
    map.deinit(gpa);
    map.* = .empty;
}

fn freeChanges(gpa: Allocator, changes: *Changes) void {
    for (changes.keys(), changes.values()) |k, v| {
        gpa.free(k);
        if (v) |x| x.free(gpa);
    }
    changes.deinit(gpa);
    changes.* = .empty;
}

// Tests -----------------------------------------------------------------------

const testing = std.testing;

test "keys: dotted names of letters, digits, _ and -" {
    try testing.expect(validKey("width"));
    try testing.expect(validKey("window.main.width"));
    try testing.expect(validKey("view-mode_2"));
    for ([_][]const u8{ "", ".a", "a.", "a..b", "a b", "a/b", "é", "a=b", "\"a\"" }) |k| try testing.expect(!validKey(k));
    try testing.expect(validKey(&@as([255]u8, @splat('a'))));
    try testing.expect(!validKey(&@as([256]u8, @splat('a'))));
}

test "files go under the XDG directory for their kind, else under $HOME" {
    const gpa = testing.allocator;
    const e: Env = .{ .config_home = "/c/", .state_home = "relative/state", .home = "/home/u" };
    for ([_]struct { Kind, []const u8, Env, []const u8 }{
        .{ .config, "", e, "/c/org.example.App" },
        // A relative XDG value is ignored.
        .{ .state, "", e, "/home/u/.local/state/org.example.App" },
        .{ .config, "", .{ .config_home = "", .state_home = "", .home = "/home/u/" }, "/home/u/.config/org.example.App" },
        .{ .state, "/srv/app//", e, "/srv/app" },
    }) |case| {
        const d = try directory(gpa, "org.example.App", .{ .kind = case[0], .directory = case[1] }, case[2]);
        defer gpa.free(d);
        try testing.expectEqualStrings(case[3], d);
    }
    try testing.expectError(error.Unavailable, directory(gpa, "org.example.App", .{}, .{ .config_home = "", .state_home = "", .home = "" }));
    try testing.expectError(error.InvalidArgument, directory(gpa, "", .{}, e));
    try testing.expectError(error.InvalidArgument, directory(gpa, "../evil", .{}, e));
    try testing.expectError(error.InvalidArgument, directory(gpa, "a", .{ .directory = "rel" }, e));
}

test "the file round-trips every type, tables sorted after top-level keys" {
    const gpa = testing.allocator;
    var map: Map = .empty;
    defer freeMap(gpa, &map);
    try applyChange(gpa, &map, "window.main.width", .{ .integer = 1100 });
    try applyChange(gpa, &map, "zoom", .{ .float = 1.0 });
    try applyChange(gpa, &map, "scale", .{ .float = 2.5e-7 });
    try applyChange(gpa, &map, "big", .{ .float = -3e300 });
    try applyChange(gpa, &map, "window.main.maximized", .{ .boolean = true });
    try applyChange(gpa, &map, "last-folder", .{ .string = "/home/a \"b\"\\c\n\x01é" });
    try applyChange(gpa, &map, "aaa.x", .{ .integer = -9223372036854775808 });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try serialize(gpa, &out, &map);
    try testing.expectEqualStrings(
        \\# Kept by the application through siv. Edits apply while it runs;
        \\# comments are not kept.
        \\big = -3e300
        \\last-folder = "/home/a \"b\"\\c\n\u0001é"
        \\scale = 2.5e-7
        \\zoom = 1.0
        \\
        \\[aaa]
        \\x = -9223372036854775808
        \\
        \\[window.main]
        \\maximized = true
        \\width = 1100
        \\
    , out.items);
    var back = try parse(gpa, out.items);
    defer freeMap(gpa, &back);
    try testing.expectEqual(map.count(), back.count());
    for (map.keys(), map.values()) |k, v| try testing.expect(back.get(k).?.eql(v));
}

test "hand-written files: dotted keys, literal strings, bad lines skipped, last wins" {
    const gpa = testing.allocator;
    var map = try parse(gpa,
        \\name = 'C:\literal'
        \\window . main.width = 800
        \\[window.main]
        \\height = 600
        \\height = 610
        \\"quoted" = 1
        \\list = [1, 2]
        \\bad key = 3
        \\bytes = "\xff"
        \\long = "
    ++ @as([max_string + 1]u8, @splat('x')) ++
        \\"
        \\path = "
    ++ @as([max_string]u8, @splat('p')) ++
        \\"
    );
    defer freeMap(gpa, &map);
    try testing.expectEqualStrings("C:\\literal", map.get("name").?.string);
    try testing.expectEqual(@as(i64, 800), map.get("window.main.width").?.integer);
    try testing.expectEqual(@as(i64, 610), map.get("window.main.height").?.integer);
    try testing.expectEqual(max_string, map.get("window.main.path").?.string.len);
    try testing.expectEqual(@as(usize, 4), map.count());
}

/// A directory of its own under /tmp, removed by `remove`.
const TempDir = struct {
    buf: [64]u8 = undefined,
    path: [:0]const u8 = "",

    var counter: std.atomic.Value(u32) = .init(0);

    fn init(d: *TempDir) void {
        d.path = std.fmt.bufPrintSentinel(&d.buf, "/tmp/siv-settings-{d}-{d}", .{ linux.getpid(), counter.fetchAdd(1, .monotonic) }, 0) catch unreachable;
    }

    fn remove(d: *const TempDir, names: []const [:0]const u8) void {
        for (names) |n| {
            var b: [128]u8 = undefined;
            _ = linux.unlink(std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ d.path, n }, 0) catch continue);
        }
        _ = linux.rmdir(d.path);
    }
};

fn readText(gpa: Allocator, path: [:0]const u8) ![]u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.NotFound;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const buf = try gpa.alloc(u8, 65536);
    const n = linux.read(fd, buf.ptr, buf.len);
    return gpa.realloc(buf, n);
}

fn writeText(path: [:0]const u8, bytes: []const u8) !void {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.Unwritable;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    if (!writeAll(fd, bytes)) return error.Unwritable;
}

test "a write merges key by key with what another process wrote" {
    const gpa = testing.allocator;
    var dir: TempDir = .{};
    dir.init();
    var sub_buf: [80]u8 = undefined;
    const sub = try std.fmt.bufPrintSentinel(&sub_buf, "{s}/org.example.App", .{dir.path}, 0);
    defer {
        var d: TempDir = .{};
        d.path = sub;
        d.remove(&.{"state.toml"});
        dir.remove(&.{});
    }
    var changes: Changes = .empty;
    defer freeChanges(gpa, &changes);
    try changes.ensureUnusedCapacity(gpa, 2);
    putChange(gpa, &changes, try gpa.dupe(u8, "a"), .{ .integer = 1 });
    putChange(gpa, &changes, try gpa.dupe(u8, "gone"), null);
    // Creates the directories.
    var m = try writeFile(gpa, sub, "state.toml", &changes);
    freeMap(gpa, &m);
    // Another process adds a key and one this store resets.
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/state.toml", .{sub}, 0);
    try writeText(path, "a = 1\nb = \"theirs\"\ngone = true\n");
    var stx: linux.Statx = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true }, &stx)));
    const mode = stx.mode & 0o777;
    m = try writeFile(gpa, sub, "state.toml", &changes);
    defer freeMap(gpa, &m);
    try testing.expectEqual(@as(usize, 2), m.count());
    try testing.expectEqualStrings("theirs", m.get("b").?.string);
    const text = try readText(gpa, path);
    defer gpa.free(text);
    try testing.expect(std.mem.endsWith(u8, text, "a = 1\nb = \"theirs\"\n"));
    // The directory is private, the file kept its mode.
    try testing.expectEqual(.SUCCESS, linux.errno(linux.statx(linux.AT.FDCWD, sub, 0, .{ .MODE = true }, &stx)));
    try testing.expectEqual(@as(u32, 0o700), stx.mode & 0o777);
    try testing.expectEqual(.SUCCESS, linux.errno(linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true }, &stx)));
    try testing.expectEqual(mode, stx.mode & 0o777);
    // A file too large to be settings is not replaced.
    const huge = try gpa.alloc(u8, max_bytes + 1);
    defer gpa.free(huge);
    @memset(huge, '#');
    try writeText(path, huge);
    try testing.expectError(error.Unreadable, writeFile(gpa, sub, "state.toml", &changes));
}

fn createApp() !*App {
    return App.create(testing.allocator, .{
        .backend = .headless,
        .system_fonts = false,
        .system_icons = false,
        .threads = 2,
        .desktop_settings = false,
        .accessibility = false,
        .app_id = "org.example.App",
    });
}

const Heard = struct {
    keys: [8][32]u8 = undefined,
    lens: [8]usize = @splat(0),
    origins: [8]Origin = undefined,
    n: usize = 0,

    fn on(ctx: ?*anyopaque, key: []const u8, origin: Origin) void {
        const h: *Heard = @ptrCast(@alignCast(ctx));
        @memcpy(h.keys[h.n][0..key.len], key);
        h.lens[h.n] = key.len;
        h.origins[h.n] = origin;
        h.n += 1;
    }

    fn keyAt(h: *const Heard, i: usize) []const u8 {
        return h.keys[i][0..h.lens[i]];
    }
};

fn dispatchUntil(app: *App, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (!cond(ctx)) {
        if (Loop.now() > deadline) return error.Timeout;
        try app.dispatch(5);
    }
}

test "a store: coalesced writes, notes for its own and outside changes, a flush at teardown" {
    const gpa = testing.allocator;
    var dir: TempDir = .{};
    dir.init();
    defer dir.remove(&.{"prefs.toml"});
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/prefs.toml", .{dir.path}, 0);
    try makeDirs(dir.path);
    try writeText(path, "zoom = 2\n");

    const app = try createApp();
    var heard: Heard = .{};
    const s = try Store.open(app, .{ .name = "prefs", .directory = dir.path, .listener = .{ .ctx = &heard, .func = Heard.on } });
    try testing.expectError(error.Busy, Store.open(app, .{ .name = "prefs", .directory = dir.path }));
    try testing.expectEqual(@as(i64, 2), s.get("zoom").?.integer);

    // Changes show at once; the listener hears them at the next dispatch.
    try s.set("width", .{ .integer = 800 });
    try s.set("width", .{ .integer = 900 });
    try s.set("zoom", .{ .integer = 2 });
    try testing.expectEqual(@as(i64, 900), s.get("width").?.integer);
    try testing.expectEqual(@as(usize, 0), heard.n);
    try app.dispatch(0);
    try testing.expectEqual(@as(usize, 1), heard.n);
    try testing.expectEqualStrings("width", heard.keyAt(0));
    try testing.expectEqual(Origin.application, heard.origins[0]);
    // One write, after the delay.
    try dispatchUntil(app, s, struct {
        fn f(st: *Store) bool {
            return !st.running and !st.timer.armed() and st.pending.count() == 0;
        }
    }.f);
    {
        const text = try readText(gpa, path);
        defer gpa.free(text);
        try testing.expect(std.mem.endsWith(u8, text, "width = 900\nzoom = 2\n"));
    }

    // Someone edits the file: the store follows, and says which keys.
    heard.n = 0;
    try writeText(path, "width = 900\nzoom = 3\nnew = true\n");
    try dispatchUntil(app, &heard, struct {
        fn f(h: *Heard) bool {
            return h.n >= 2;
        }
    }.f);
    try testing.expectEqual(@as(i64, 3), s.get("zoom").?.integer);
    try testing.expect(s.get("new").?.boolean);
    for (0..heard.n) |i| try testing.expectEqual(Origin.outside, heard.origins[i]);

    // Unsaved changes are written when the application goes.
    try s.reset("new");
    try s.set("title", .{ .string = "Hello" });
    app.destroy();
    const text = try readText(gpa, path);
    defer gpa.free(text);
    try testing.expect(std.mem.endsWith(u8, text, "title = \"Hello\"\nwidth = 900\nzoom = 3\n"));
}

test "a write that fails keeps its changes and waits for the next one" {
    var dir: TempDir = .{};
    dir.init();
    defer dir.remove(&.{"blocker"});
    try makeDirs(dir.path);
    var path_buf: [96]u8 = undefined;
    // A file where the store's directory should be.
    try writeText(try std.fmt.bufPrintSentinel(&path_buf, "{s}/blocker", .{dir.path}, 0), "");
    const sub = try std.fmt.bufPrintSentinel(&path_buf, "{s}/blocker/app", .{dir.path}, 0);
    const app = try createApp();
    defer app.destroy();
    const s = try Store.open(app, .{ .directory = sub });
    try s.set("a", .{ .integer = 1 });
    try dispatchUntil(app, s, struct {
        fn f(st: *Store) bool {
            return !st.running and !st.timer.armed();
        }
    }.f);
    // Not written, still shown, and no timer tries again.
    try testing.expectEqual(@as(usize, 1), s.pending.count());
    try testing.expectEqual(@as(i64, 1), s.get("a").?.integer);
    try app.dispatch(0);
    try testing.expect(!s.timer.armed() and !s.running);
    // The next change starts a write again.
    try s.set("b", .{ .integer = 2 });
    try testing.expect(s.timer.armed());
}

test "a memory store keeps values without a file" {
    const app = try createApp();
    defer app.destroy();
    const s = try Store.open(app, .{ .kind = .state, .memory = true });
    try s.set("a", .{ .boolean = true });
    try testing.expect(s.get("a").?.boolean);
    // Closed while a note is queued.
    s.close();
    try app.dispatch(0);
}
