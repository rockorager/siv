//! Measurements of the file manager on the headless backend
//! (`zig build bench-files -Doptimize=ReleaseFast`): startup to the first
//! frame and to the first frame with the folder's rows, memory, idle
//! wakeups, and scrolling through a folder of 100 000 entries. Prints
//! numbers; the thresholds of D25 are checked by the integration test on
//! sway only where they do not depend on the machine.

const std = @import("std");
const linux = std.os.linux;
const builtin = @import("builtin");
const abi = @import("abi");
const platform = @import("platform");
const Loop = @import("loop").Loop;
const harness = @import("harness.zig");

const A = abi.application;
const Harness = harness.Harness;
const ok = harness.ok;

const entries = 100_000;

fn now() u64 {
    return Loop.now();
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// Thread CPU time of the calling (UI) thread.
fn threadCpu() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Resident memory of the process, in bytes.
fn rss() u64 {
    var buf: [256]u8 = undefined;
    const fd: i32 = @intCast(linux.openat(linux.AT.FDCWD, "/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0));
    defer _ = linux.close(fd);
    const n = linux.read(fd, &buf, buf.len);
    var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    _ = it.next();
    const pages = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    return pages * 4096;
}

/// Context switches of every thread of the process: each is a wakeup or
/// a preemption.
fn switches() u64 {
    var total: u64 = 0;
    const dfd_rc = linux.openat(linux.AT.FDCWD, "/proc/self/task", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const dfd: i32 = @intCast(dfd_rc);
    defer _ = linux.close(dfd);
    var dbuf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(dfd, &dbuf, dbuf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&dbuf[off]);
            const name: [*:0]const u8 = @ptrCast(&dbuf[off + @offsetOf(linux.dirent64, "name")]);
            off += d.reclen;
            const tid = std.mem.span(name);
            if (tid[0] == '.') continue;
            var pbuf: [64]u8 = undefined;
            const p = std.fmt.bufPrintSentinel(&pbuf, "/proc/self/task/{s}/status", .{tid}, 0) catch continue;
            const fd_rc = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(fd_rc) != .SUCCESS) continue;
            const fd: i32 = @intCast(fd_rc);
            defer _ = linux.close(fd);
            var sbuf: [4096]u8 = undefined;
            const sn = linux.read(fd, &sbuf, sbuf.len);
            var lines = std.mem.splitScalar(u8, sbuf[0..sn], '\n');
            while (lines.next()) |line| {
                for ([_][]const u8{ "voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:" }) |key| {
                    if (std.mem.startsWith(u8, line, key)) total += std.fmt.parseInt(u64, std.mem.trim(u8, line[key.len..], " \t"), 10) catch 0;
                }
            }
        }
    }
    return total;
}

fn threads() usize {
    var n: usize = 0;
    const dfd: i32 = @intCast(linux.openat(linux.AT.FDCWD, "/proc/self/task", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0));
    defer _ = linux.close(dfd);
    var dbuf: [8192]u8 align(8) = undefined;
    while (true) {
        const r = linux.getdents64(dfd, &dbuf, dbuf.len);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        var off: usize = 0;
        while (off < r) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&dbuf[off]);
            if (dbuf[off + @offsetOf(linux.dirent64, "name")] != '.') n += 1;
            off += d.reclen;
        }
    }
    return n;
}

fn makeFolder(path: [:0]const u8, n: usize) !void {
    if (linux.errno(linux.mkdirat(linux.AT.FDCWD, path, 0o755)) != .SUCCESS) return error.Mkdir;
    var buf: [256]u8 = undefined;
    for (0..n) |i| {
        // Varied names, sizes, and kinds, as in a real download folder.
        const ext = [_][]const u8{ "txt", "pdf", "png", "zig", "tar.gz", "flac", "md" };
        const p = try std.fmt.bufPrintSentinel(&buf, "{s}/file-{d}.{s}", .{ path, i, ext[i % ext.len] }, 0);
        const fd: i32 = @intCast(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644));
        if (i % 3 == 0) _ = linux.ftruncate(fd, @intCast(i * 37));
        _ = linux.close(fd);
    }
}

fn removeFolder(path: []const u8) void {
    var buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&buf, "rm -rf '{s}'", .{path}, 0) catch return;
    const S = struct {
        extern "c" fn system(cmd: [*:0]const u8) c_int;
    };
    _ = S.system(cmd.ptr);
}

fn report(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("files bench: " ++ fmt ++ "\n", args);
}

pub fn main() !void {
    if (builtin.mode == .debug) report("warning: build with -Doptimize=ReleaseFast for meaningful numbers", .{});
    var dir_buf: [128]u8 = undefined;
    const S = struct {
        extern "c" fn getpid() c_int;
    };
    const root = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/siv-files-bench-{d}", .{S.getpid()}, 0);
    var small_buf: [160]u8 = undefined;
    const small = try std.fmt.bufPrintSentinel(&small_buf, "{s}-small", .{root}, 0);
    defer removeFolder(root);
    defer removeFolder(small);
    try makeFolder(small, 40);
    const t_make = now();
    try makeFolder(root, entries);
    report("created {d} files in {d:.0} ms", .{ entries, ms(now() - t_make) });

    // Startup of a small folder: application, window, first frame, and
    // the first frame that shows the folder's rows.
    {
        const rss0 = rss();
        var h: Harness = .{};
        const t0 = now();
        try ok(A.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true, .reduced_motion = true } }, &h.app));
        const tf = @import("text").font.test_fonts;
        try ok(A.siv_app_add_font(h.app, "Droid", 5, tf.latin.ptr, tf.latin.len));
        try ok(A.siv_app_set_default_font(h.app, "Droid", 5));
        const cpu0 = threadCpu();
        h.files = try harness.Files.create(@enumFromInt(@intFromEnum(h.app)), .{ .gpa = std.heap.c_allocator, .path = small, .home = small, .config_home = "/nonexistent", .data_home = small, .watch = true, .thumbnails = false });
        // The app's presented events (SIV_WINDOW_EVENT_PRESENTED) say
        // when each frame was committed.
        while (h.f().rows_frame_ns == 0) {
            try ok(A.siv_app_dispatch(h.app, 1));
            if (now() - t0 > 10 * std.time.ns_per_s) return error.Timeout;
        }
        const first = h.f().first_frame_ns;
        const rows = h.f().rows_frame_ns;
        const cpu = threadCpu() - cpu0;
        report("startup (40 entries): first frame {d:.1} ms, first frame with rows {d:.1} ms, UI thread CPU {d:.1} ms", .{ ms(first - t0), ms(rows - t0), ms(cpu) });
        try h.settle();
        report("memory: {d:.1} MiB resident with the window open (process grew {d:.1} MiB)", .{ @as(f64, @floatFromInt(rss())) / (1 << 20), @as(f64, @floatFromInt(rss() -| rss0)) / (1 << 20) });

        // Idle: nothing scheduled, so no thread should wake.
        const sw0 = switches();
        const t_idle = now();
        while (now() - t_idle < 2 * std.time.ns_per_s) try ok(A.siv_app_dispatch(h.app, 2000));
        const sw = switches() - sw0;
        // The one 2 s dispatch timeout wakes the bench's loop once.
        report("idle for 2 s: {d} context switches across all {d} threads, of which the bench's own 2 s timeout is one", .{ sw, threads() });
        h.stop();
    }

    // The big folder.
    var h: Harness = .{};
    try ok(A.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true, .reduced_motion = true } }, &h.app));
    defer h.stop();
    const tf = @import("text").font.test_fonts;
    try ok(A.siv_app_add_font(h.app, "Droid", 5, tf.latin.ptr, tf.latin.len));
    try ok(A.siv_app_set_default_font(h.app, "Droid", 5));
    const rss0 = rss();
    const t0 = now();
    h.files = try harness.Files.create(@enumFromInt(@intFromEnum(h.app)), .{ .gpa = std.heap.c_allocator, .path = root, .home = root, .config_home = "/nonexistent", .data_home = small, .watch = false, .thumbnails = false, .height = 720 });
    const self = try A.App.get(@backingInt(h.app));
    var loaded: u64 = 0;
    while (loaded == 0) {
        try ok(A.siv_app_dispatch(h.app, 1));
        if (h.f().listing != null and h.f().loading == null) loaded = now();
        if (now() - t0 > 60 * std.time.ns_per_s) return error.Timeout;
    }
    try h.settle();
    const first = h.f().first_frame_ns;
    const shown = h.f().rows_frame_ns;
    report("100 000 entries: first frame {d:.1} ms, read and sorted on the pool {d:.1} ms, rows shown {d:.1} ms", .{ ms(first - t0), ms(loaded - t0), ms(shown - t0) });
    report("memory: {d:.1} MiB more with 100 000 entries listed", .{@as(f64, @floatFromInt(rss() -| rss0)) / (1 << 20)});

    // Scrolling: wheel steps over the list, each settled (frame presented)
    // before the next; UI thread CPU per step is what limits the rate.
    const id = self.windows.items[0].?.win.id;
    try h.inject(&.{.{ .pointer_motion = .{ .window = id, .seat = 0, .x = 500, .y = 300 } }});
    try h.settle();
    const steps = 300;
    var worst: u64 = 0;
    var total_cpu: u64 = 0;
    const t_scroll = now();
    for (0..steps) |_| {
        const c0 = threadCpu();
        try h.inject(&.{.{ .scroll = .{ .window = id, .seat = 0, .dx = 0, .dy = 450, .v120_x = 0, .v120_y = 0 } }});
        try h.settle();
        const c = threadCpu() - c0;
        total_cpu += c;
        worst = @max(worst, c);
    }
    const wall = now() - t_scroll;
    var top: f64 = 0;
    _ = &top;
    report("scrolling {d} wheel steps of 450 px: UI thread CPU {d:.2} ms per step on average, {d:.2} ms worst; {d:.1} ms wall per settled step (includes the headless renderer)", .{ steps, ms(total_cpu / steps), ms(worst), ms(wall / steps) });

    // Keyboard: End jumps to the last entry, Home back.
    const c0 = threadCpu();
    try h.key(harness.ks.end, "", .{});
    try h.key(harness.ks.home, "", .{});
    report("End then Home over 100 000 entries: UI thread CPU {d:.2} ms", .{ms(threadCpu() - c0)});

    // Selection: Ctrl+A, then the status line counts it.
    const c1 = threadCpu();
    try h.key('a', "a", .{ .ctrl = true });
    report("Ctrl+A over 100 000 entries: UI thread CPU {d:.1} ms", .{ms(threadCpu() - c1)});
    // Sorting by size and back.
    const c2 = threadCpu();
    h.f().setSort(.{ .key = .size });
    try h.settle();
    report("sort 100 000 entries by size (keeping the selection): UI thread CPU {d:.1} ms", .{ms(threadCpu() - c2)});
    // Search as you type.
    const c3 = threadCpu();
    h.f().setQuery("file-99");
    try h.settle();
    report("search \"file-99\" over 100 000 entries: UI thread CPU {d:.1} ms, {d} results", .{ ms(threadCpu() - c3), h.f().visible.items.len });
}
