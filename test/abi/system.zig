//! The trash and system signals through the exports (D42) on the headless
//! backend: trash jobs against a home trash in a temporary directory
//! ($XDG_DATA_HOME), their results at a later dispatch with D2's
//! destroy-notifies, and system signals injected with
//! siv_test_system_signal.

const std = @import("std");
const linux = std.os.linux;
const abi = @import("abi");
const harness = @import("harness.zig");
const Loop = @import("loop").Loop;

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const T = abi.trash;
const S = abi.system;
const ok = harness.ok;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

/// A temporary directory as $XDG_DATA_HOME, restored afterwards.
const Data = struct {
    buf: [64]u8 = undefined,
    dir: []const u8 = "",
    old: ?[]u8 = null,

    fn init(d: *Data) !void {
        const template = "/tmp/siv-abi-trash-XXXXXX";
        @memcpy(d.buf[0..template.len], template);
        d.buf[template.len] = 0;
        d.dir = std.mem.span(mkdtemp(d.buf[0..template.len :0]) orelse return error.Unexpected);
        if (std.c.getenv("XDG_DATA_HOME")) |v| d.old = try testing.allocator.dupe(u8, std.mem.span(v));
        _ = setenv("XDG_DATA_HOME", d.buf[0..d.dir.len :0], 1);
    }

    fn deinit(d: *Data) void {
        if (d.old) |o| {
            var b: [4096]u8 = undefined;
            _ = setenv("XDG_DATA_HOME", std.fmt.bufPrintSentinel(&b, "{s}", .{o}, 0) catch unreachable, 1);
            testing.allocator.free(o);
        } else _ = unsetenv("XDG_DATA_HOME");
        removeTree(d.dir);
    }

    fn path(d: *const Data, buf: []u8, rel: []const u8) [:0]u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ d.dir, rel }, 0) catch unreachable;
    }

    fn write(d: *const Data, rel: []const u8) !void {
        var buf: [256]u8 = undefined;
        const rc = linux.openat(linux.AT.FDCWD, d.path(&buf, rel), .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
        _ = linux.write(@intCast(rc), "data", 4);
        _ = linux.close(@intCast(rc));
    }

    fn exists(d: *const Data, rel: []const u8) bool {
        var buf: [256]u8 = undefined;
        return existsAbs(d.path(&buf, rel));
    }
};

fn existsAbs(p: [:0]const u8) bool {
    var st: linux.Statx = undefined;
    return linux.errno(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) == .SUCCESS;
}

/// Removes a directory tree the tests made (no links out of it).
fn removeTree(dir: []const u8) void {
    var zbuf: [512]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{dir}, 0) catch return;
    if (linux.errno(linux.unlinkat(linux.AT.FDCWD, z, 0)) == .SUCCESS) return;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    var names: [4096]u8 = undefined;
    var n_len: usize = 0;
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const de: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
            const nm = std.mem.span(@as([*:0]const u8, @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")])));
            off += de.reclen;
            if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..") or n_len + nm.len + 1 > names.len) continue;
            @memcpy(names[n_len..][0..nm.len], nm);
            names[n_len + nm.len] = 0;
            n_len += nm.len + 1;
        }
    }
    _ = linux.close(fd);
    var it = std.mem.splitScalar(u8, names[0..n_len], 0);
    while (it.next()) |nm| {
        if (nm.len == 0) continue;
        var cbuf: [512]u8 = undefined;
        removeTree(std.fmt.bufPrint(&cbuf, "{s}/{s}", .{ dir, nm }) catch continue);
    }
    _ = linux.unlinkat(linux.AT.FDCWD, z, linux.AT.REMOVEDIR);
}

const Log = struct {
    results: u32 = 0,
    destroys: u32 = 0,
    status: t.TrashStatus = .failed,
    id: [256]u8 = undefined,
    id_len: usize = 0,
    path: [256]u8 = undefined,
    path_len: usize = 0,
    items: u32 = 0,
    /// The item of `want` in a list, if any.
    want: []const u8 = "",
    found: ?struct { path_len: usize, deleted: i64, bytes: u64, directory: bool } = null,

    fn onResult(user_data: ?*anyopaque, r: *const t.TrashResult) callconv(.c) void {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.results += 1;
        log.status = r.status;
        log.id_len = r.id_len;
        if (r.id_len > 0) @memcpy(log.id[0..r.id_len], r.id.?[0..r.id_len]);
        log.path_len = r.path_len;
        if (r.path_len > 0) @memcpy(log.path[0..r.path_len], r.path.?[0..r.path_len]);
        log.items = @intCast(r.items_count);
        if (r.items) |items| for (items[0..r.items_count]) |it| {
            if (std.mem.eql(u8, it.id.?[0..it.id_len], log.want)) log.found = .{ .path_len = it.path_len, .deleted = it.deletion_time, .bytes = it.bytes, .directory = it.flags.directory };
        };
    }

    fn onDestroy(user_data: ?*anyopaque) callconv(.c) void {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.destroys += 1;
    }

    fn idSlice(log: *const Log) []const u8 {
        return log.id[0..log.id_len];
    }
};

fn waitFor(h: *harness.Harness, log: *const Log, n: u32) !void {
    const deadline = Loop.now() + 10 * std.time.ns_per_s;
    while (log.destroys < n) {
        if (Loop.now() > deadline) return error.Timeout;
        try ok(A.siv_app_dispatch(h.app, 5));
    }
}

fn nowSec() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

test "a trashed file restores to where it was; results come at a later dispatch" {
    var d: Data = .{};
    try d.init();
    defer d.deinit();
    var h: harness.Harness = .{};
    try h.start(32, 32, null, null);
    defer h.stop();
    try d.write("note.txt");
    var pbuf: [256]u8 = undefined;
    const src = d.path(&pbuf, "note.txt");

    var log: Log = .{};
    const before = nowSec();
    try ok(T.siv_trash_file(h.app, src.ptr, src.len, Log.onResult, Log.onDestroy, &log));
    try testing.expectEqual(@as(u32, 0), log.results);
    try waitFor(&h, &log, 1);
    try testing.expectEqual(@as(u32, 1), log.results);
    try testing.expectEqual(t.TrashStatus.ok, log.status);
    var want: [256]u8 = undefined;
    try testing.expectEqualStrings(d.path(&want, "Trash/files/note.txt"), log.idSlice());
    try testing.expectEqualStrings(src, log.path[0..log.path_len]);
    try testing.expect(!d.exists("note.txt"));
    try testing.expect(d.exists("Trash/info/note.txt.trashinfo"));

    // Listed with where it was and when.
    var id_buf: [256]u8 = undefined;
    const id = id_buf[0..log.id_len];
    @memcpy(id, log.idSlice());
    var list: Log = .{ .want = id };
    try ok(T.siv_trash_list(h.app, Log.onResult, Log.onDestroy, &list));
    try waitFor(&h, &list, 1);
    try testing.expectEqual(t.TrashStatus.ok, list.status);
    const found = list.found orelse return error.TestUnexpectedResult;
    try testing.expectEqual(src.len, found.path_len);
    try testing.expectEqual(@as(u64, 4), found.bytes);
    try testing.expect(!found.directory);
    try testing.expect(found.deleted >= before and found.deleted <= nowSec());

    var back: Log = .{};
    try ok(T.siv_trash_restore(h.app, id.ptr, id.len, null, 0, Log.onResult, Log.onDestroy, &back));
    try waitFor(&h, &back, 1);
    try testing.expectEqual(t.TrashStatus.ok, back.status);
    try testing.expectEqualStrings(src, back.path[0..back.path_len]);
    try testing.expectEqualStrings(id, back.idSlice());
    try testing.expect(d.exists("note.txt"));
    try testing.expect(!d.exists("Trash/info/note.txt.trashinfo"));

    // Gone from the trash: a second restore finds nothing.
    var again: Log = .{};
    try ok(T.siv_trash_restore(h.app, id.ptr, id.len, null, 0, Log.onResult, Log.onDestroy, &again));
    try waitFor(&h, &again, 1);
    try testing.expectEqual(t.TrashStatus.not_found, again.status);
}

test "restoring never replaces; deleting is for good; bad arguments fail at once" {
    var d: Data = .{};
    try d.init();
    defer d.deinit();
    var h: harness.Harness = .{};
    try h.start(32, 32, null, null);
    defer h.stop();
    try d.write("a");
    var pbuf: [256]u8 = undefined;
    const src = d.path(&pbuf, "a");
    var log: Log = .{};
    try ok(T.siv_trash_file(h.app, src.ptr, src.len, Log.onResult, Log.onDestroy, &log));
    try waitFor(&h, &log, 1);
    try d.write("a");

    var clash: Log = .{};
    try ok(T.siv_trash_restore(h.app, &log.id, log.id_len, null, 0, Log.onResult, Log.onDestroy, &clash));
    try waitFor(&h, &clash, 1);
    try testing.expectEqual(t.TrashStatus.exists, clash.status);

    // Somewhere else instead.
    var dbuf: [256]u8 = undefined;
    const dest = d.path(&dbuf, "sub/b");
    var moved: Log = .{};
    try ok(T.siv_trash_restore(h.app, &log.id, log.id_len, dest.ptr, dest.len, Log.onResult, Log.onDestroy, &moved));
    try waitFor(&h, &moved, 1);
    try testing.expectEqual(t.TrashStatus.ok, moved.status);
    try testing.expect(d.exists("sub/b"));

    var second: Log = .{};
    try ok(T.siv_trash_file(h.app, src.ptr, src.len, Log.onResult, Log.onDestroy, &second));
    try waitFor(&h, &second, 1);
    var gone: Log = .{};
    try ok(T.siv_trash_delete(h.app, &second.id, second.id_len, Log.onResult, Log.onDestroy, &gone));
    try waitFor(&h, &gone, 1);
    try testing.expectEqual(t.TrashStatus.ok, gone.status);
    try testing.expect(!existsAbs(try std.fmt.bufPrintSentinel(&dbuf, "{s}", .{second.idSlice()}, 0)));

    // A file that is not a trash item is never deleted.
    var not_item: Log = .{};
    try ok(T.siv_trash_delete(h.app, dest.ptr, dest.len, Log.onResult, Log.onDestroy, &not_item));
    try waitFor(&h, &not_item, 1);
    try testing.expectEqual(t.TrashStatus.not_found, not_item.status);
    try testing.expect(d.exists("sub/b"));

    var missing: Log = .{};
    const nope = d.path(&dbuf, "nope");
    try ok(T.siv_trash_file(h.app, nope.ptr, nope.len, Log.onResult, Log.onDestroy, &missing));
    try waitFor(&h, &missing, 1);
    try testing.expectEqual(t.TrashStatus.not_found, missing.status);

    var bad: Log = .{};
    try testing.expectEqual(t.Result.error_invalid_argument, T.siv_trash_file(h.app, "rel/x", 5, Log.onResult, Log.onDestroy, &bad));
    try testing.expectEqual(t.Result.error_invalid_argument, T.siv_trash_restore(h.app, &log.id, log.id_len, "rel", 3, Log.onResult, Log.onDestroy, &bad));
    try testing.expectEqual(t.Result.error_invalid_handle, T.siv_trash_list(.null, Log.onResult, Log.onDestroy, &bad));
    try testing.expectEqual(@as(u32, 3), bad.destroys);
    try testing.expectEqual(@as(u32, 0), bad.results);
}

test "operations pending when the application goes run only their destroy-notify" {
    var d: Data = .{};
    try d.init();
    defer d.deinit();
    var h: harness.Harness = .{};
    try h.start(32, 32, null, null);
    var log: Log = .{};
    for (0..4) |i| {
        var name: [8]u8 = undefined;
        const rel = try std.fmt.bufPrint(&name, "f{d}", .{i});
        try d.write(rel);
        var pbuf: [256]u8 = undefined;
        const p = d.path(&pbuf, rel);
        try ok(T.siv_trash_file(h.app, p.ptr, p.len, Log.onResult, Log.onDestroy, &log));
    }
    h.stop();
    try testing.expectEqual(@as(u32, 4), log.destroys);
    try testing.expectEqual(@as(u32, 0), log.results);
}

const Heard = struct {
    events: u32 = 0,
    destroys: u32 = 0,
    last: t.SystemEvent = .{},
    /// Destroys this monitor from its first event.
    self_destroy: bool = false,

    fn onEvent(user_data: ?*anyopaque, monitor: t.SystemMonitor, e: *const t.SystemEvent) callconv(.c) void {
        const x: *Heard = @ptrCast(@alignCast(user_data));
        x.events += 1;
        x.last = e.*;
        if (x.self_destroy) S.siv_system_monitor_destroy(monitor);
    }

    fn onDestroy(user_data: ?*anyopaque) callconv(.c) void {
        const x: *Heard = @ptrCast(@alignCast(user_data));
        x.destroys += 1;
    }
};

test "system signals: state, monitors, and what siv does itself" {
    var h: harness.Harness = .{ .reduced_motion = false };
    try h.start(32, 32, null, null);
    defer h.stop();
    var st: t.SystemState = undefined;
    try ok(S.siv_app_get_system_state(h.app, &st));
    try testing.expectEqual(t.SystemFlags{ .network_available = true }, st.flags);
    try testing.expectEqual(t.NetworkConnectivity.full, st.connectivity);

    var a: Heard = .{};
    var b: Heard = .{ .self_destroy = true };
    var ma: t.SystemMonitor = .null;
    var mb: t.SystemMonitor = .null;
    try ok(S.siv_system_monitor_create(h.app, &.{ .on_event = Heard.onEvent, .destroy = Heard.onDestroy, .user_data = &a }, &ma));
    try ok(S.siv_system_monitor_create(h.app, &.{ .on_event = Heard.onEvent, .destroy = Heard.onDestroy, .user_data = &b }, &mb));

    var blink: u32 = 0;
    try ok(A.siv_app_get_caret_blink(h.app, &blink));
    try testing.expect(blink > 0);
    try ok(S.siv_test_system_signal(h.app, &.{ .type = .power_saver, .state = .{ .flags = .{ .power_saver = true } } }));
    try testing.expectEqual(@as(u32, 1), a.events);
    try testing.expectEqual(t.SystemEventType.power_saver, a.last.type);
    try testing.expect(a.last.state.flags.power_saver);
    // The network did not change with it.
    try testing.expect(a.last.state.flags.network_available);
    try ok(S.siv_app_get_system_state(h.app, &st));
    try testing.expect(st.flags.power_saver);
    // Carets stop blinking; reduced motion is not power's.
    try ok(A.siv_app_get_caret_blink(h.app, &blink));
    try testing.expectEqual(@as(u32, 0), blink);
    var reduced = true;
    try ok(A.siv_app_get_reduced_motion(h.app, &reduced));
    try testing.expect(!reduced);
    // b destroyed itself from its event; its user data went once.
    try testing.expectEqual(@as(u32, 1), b.events);
    try testing.expectEqual(@as(u32, 1), b.destroys);
    S.siv_system_monitor_destroy(mb);
    try testing.expectEqual(@as(u32, 1), b.destroys);

    // The same state again is no change.
    try ok(S.siv_test_system_signal(h.app, &.{ .type = .power_saver, .state = .{ .flags = .{ .power_saver = true } } }));
    try testing.expectEqual(@as(u32, 1), a.events);

    const self = try h.internal();
    const trims = self.app.system.trims;
    try ok(S.siv_test_system_signal(h.app, &.{ .type = .memory, .memory_pressure = .critical }));
    try testing.expectEqual(@as(u32, 2), a.events);
    try testing.expectEqual(t.SystemEventType.memory, a.last.type);
    try testing.expectEqual(t.MemoryPressure.critical, a.last.memory_pressure);
    try testing.expectEqual(trims + 1, self.app.system.trims);
    // Memory warnings leave power saving as it was.
    try testing.expect(a.last.state.flags.power_saver);

    try ok(S.siv_test_system_signal(h.app, &.{ .type = .network, .state = .{ .flags = .{ .network_available = true, .network_metered = true }, .connectivity = .captive_portal } }));
    try testing.expectEqual(@as(u32, 3), a.events);
    try testing.expectEqual(t.NetworkConnectivity.captive_portal, a.last.state.connectivity);
    try testing.expect(a.last.state.flags.network_metered);

    try ok(S.siv_test_system_signal(h.app, &.{ .type = .power_saver }));
    try ok(A.siv_app_get_caret_blink(h.app, &blink));
    try testing.expect(blink > 0);
    try testing.expectEqual(@as(u32, 4), a.events);

    try testing.expectEqual(t.Result.error_unsupported, S.siv_test_system_signal(h.app, &.{ .type = @enumFromInt(9) }));
    try testing.expectEqual(t.Result.error_invalid_argument, S.siv_app_get_system_state(h.app, null));
    S.siv_system_monitor_destroy(ma);
    try testing.expectEqual(@as(u32, 1), a.destroys);
    S.siv_system_monitor_destroy(ma);
    try testing.expectEqual(@as(u32, 1), a.destroys);
}

test "monitors still alive when the application goes release their user data" {
    var h: harness.Harness = .{};
    try h.start(32, 32, null, null);
    var a: Heard = .{};
    var m: t.SystemMonitor = .null;
    try ok(S.siv_system_monitor_create(h.app, &.{ .on_event = Heard.onEvent, .destroy = Heard.onDestroy, .user_data = &a }, &m));
    h.stop();
    try testing.expectEqual(@as(u32, 1), a.destroys);
    S.siv_system_monitor_destroy(m);
    try testing.expectEqual(@as(u32, 1), a.destroys);
}
