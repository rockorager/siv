//! DRM synchronization object timelines, for linux-drm-syncobj-v1
//! explicit synchronization of the dma-buf frames siv attaches to
//! subsurfaces itself (D17). Plain ioctls on a DRM render node, as
//! libdrm's drmSyncobj* calls make them (no libdrm dependency).
//!
//! A release point is watched with DRM_IOCTL_SYNCOBJ_EVENTFD (Linux 6.6):
//! the kernel increments an eventfd once the point signals, so the
//! platform's loop waits for it like any other fd. A kernel without it,
//! or a device without timelines, keeps implicit synchronization.

const std = @import("std");
const linux = std.os.linux;

/// An open DRM node with timeline syncobjs and eventfd waits.
pub const Device = struct {
    fd: i32,

    /// Opens the render node of `dev` (a dev_t naming a primary or render
    /// node, from linux-dmabuf feedback's main device) and checks what
    /// explicit synchronization needs. Null if it cannot.
    pub fn open(dev: u64) ?Device {
        const fd = openRenderNode(dev) orelse return null;
        const d: Device = .{ .fd = fd };
        if (!d.supported()) {
            d.close();
            return null;
        }
        return d;
    }

    pub fn close(d: Device) void {
        _ = linux.close(d.fd);
    }

    /// Timelines and eventfd waits, which a probe syncobj shows.
    fn supported(d: Device) bool {
        var cap: extern struct { capability: u64, value: u64 = 0 } = .{ .capability = cap_syncobj_timeline };
        if (!ok(linux.ioctl(d.fd, ioctl_get_cap, @intFromPtr(&cap))) or cap.value == 0) return false;
        const handle = d.create() catch return false;
        defer d.destroy(handle);
        const efd = eventFd() catch return false;
        defer _ = linux.close(efd);
        d.watch(handle, 1, efd) catch return false;
        return true;
    }

    /// A new, unsignaled syncobj.
    pub fn create(d: Device) !u32 {
        var arg: extern struct { handle: u32 = 0, flags: u32 = 0 } = .{};
        if (!ok(linux.ioctl(d.fd, ioctl_create, @intFromPtr(&arg)))) return error.SyncobjFailed;
        return arg.handle;
    }

    pub fn destroy(d: Device, handle: u32) void {
        var arg: extern struct { handle: u32, pad: u32 = 0 } = .{ .handle = handle };
        _ = linux.ioctl(d.fd, ioctl_destroy, @intFromPtr(&arg));
    }

    /// A file descriptor for the syncobj, to import into the compositor
    /// (wp_linux_drm_syncobj_manager_v1.import_timeline). The caller
    /// closes it.
    pub fn exportFd(d: Device, handle: u32) !i32 {
        var arg: extern struct { handle: u32, flags: u32 = 0, fd: i32 = -1, pad: u32 = 0, point: u64 = 0 } = .{ .handle = handle };
        if (!ok(linux.ioctl(d.fd, ioctl_handle_to_fd, @intFromPtr(&arg)))) return error.SyncobjFailed;
        return arg.fd;
    }

    /// Signals a timeline point from the CPU, for content that is
    /// already complete.
    pub fn signal(d: Device, handle: u32, point: u64) !void {
        var h = handle;
        var p = point;
        var arg: TimelineArray = .{ .handles = @intFromPtr(&h), .points = @intFromPtr(&p), .count_handles = 1 };
        if (!ok(linux.ioctl(d.fd, ioctl_timeline_signal, @intFromPtr(&arg)))) return error.SyncobjFailed;
    }

    /// Has the kernel increment `efd` once the point signals.
    pub fn watch(d: Device, handle: u32, point: u64, efd: i32) !void {
        var arg: extern struct { handle: u32, flags: u32 = 0, point: u64, fd: i32, pad: u32 = 0 } = .{ .handle = handle, .point = point, .fd = efd };
        if (!ok(linux.ioctl(d.fd, ioctl_eventfd, @intFromPtr(&arg)))) return error.SyncobjFailed;
    }
};

/// A non-blocking eventfd for `Device.watch`.
pub fn eventFd() !i32 {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (!ok(rc)) return error.SystemResources;
    return @intCast(rc);
}

fn ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

const TimelineArray = extern struct { handles: u64, points: u64, count_handles: u32, flags: u32 = 0 };

// drm.h: DRM_IOWR(nr, type) on 'd'.
fn iowr(nr: u8, comptime T: type) u32 {
    return (3 << 30) | (@as(u32, @sizeOf(T)) << 16) | ('d' << 8) | nr;
}
const ioctl_get_cap = iowr(0x0c, [16]u8);
const ioctl_create = iowr(0xbf, [8]u8);
const ioctl_destroy = iowr(0xc0, [8]u8);
const ioctl_handle_to_fd = iowr(0xc1, [24]u8);
const ioctl_timeline_signal = iowr(0xcd, TimelineArray);
const ioctl_eventfd = iowr(0xcf, [24]u8);
const cap_syncobj_timeline: u64 = 0x14;

/// Opens the render node for `dev`, or for the device whose primary node
/// it is (they share a parent in sysfs); falls back to the node itself,
/// where syncobj ioctls work too.
fn openRenderNode(dev: u64) ?i32 {
    const major: u32 = @truncate(((dev >> 8) & 0xfff) | ((dev >> 32) & ~@as(u64, 0xfff)));
    const minor: u32 = @truncate((dev & 0xff) | ((dev >> 12) & ~@as(u64, 0xff)));
    var buf: [64]u8 = undefined;
    if (minor >= 128) return openNode(std.fmt.bufPrintSentinel(&buf, "/dev/dri/renderD{d}", .{minor}, 0) catch return null, major, minor);
    var link_buf: [256]u8 = undefined;
    const link = readlink(&link_buf, major, minor) orelse return null;
    const parent = link[0 .. std.mem.lastIndexOfScalar(u8, link, '/') orelse return null];
    var other_buf: [256]u8 = undefined;
    for (128..192) |n| {
        const other = readlink(&other_buf, major, @intCast(n)) orelse continue;
        if (!std.mem.eql(u8, other[0 .. std.mem.lastIndexOfScalar(u8, other, '/') orelse continue], parent)) continue;
        if (openNode(std.fmt.bufPrintSentinel(&buf, "/dev/dri/renderD{d}", .{n}, 0) catch return null, major, @intCast(n))) |fd| return fd;
    }
    return openNode(std.fmt.bufPrintSentinel(&buf, "/dev/dri/card{d}", .{minor}, 0) catch return null, major, minor);
}

/// sysfs's link for a character device: its path under /sys/devices.
fn readlink(buf: []u8, major: u32, minor: u32) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/sys/dev/char/{d}:{d}", .{ major, minor }, 0) catch return null;
    const rc = linux.readlink(path, buf.ptr, buf.len);
    if (!ok(rc)) return null;
    return buf[0..rc];
}

/// Opens a node and checks that it is the device `major`:`minor`.
fn openNode(path: [:0]const u8, major: u32, minor: u32) ?i32 {
    const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (!ok(rc)) return null;
    const fd: i32 = @intCast(rc);
    var st: linux.Statx = undefined;
    if (ok(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &st)) and
        st.rdev_major == major and st.rdev_minor == minor) return fd;
    _ = linux.close(fd);
    return null;
}

test "ioctl numbers match drm.h" {
    // Values from <drm/drm.h> (Linux 6.6) on x86_64 and aarch64.
    try std.testing.expectEqual(@as(u32, 0xc010640c), ioctl_get_cap);
    try std.testing.expectEqual(@as(u32, 0xc00864bf), ioctl_create);
    try std.testing.expectEqual(@as(u32, 0xc00864c0), ioctl_destroy);
    try std.testing.expectEqual(@as(u32, 0xc01864c1), ioctl_handle_to_fd);
    try std.testing.expectEqual(@as(u32, 0xc01864cd), ioctl_timeline_signal);
    try std.testing.expectEqual(@as(u32, 0xc01864cf), ioctl_eventfd);
}

test "a timeline point signaled on the CPU wakes its eventfd" {
    // Needs a GPU's render node and Linux 6.6; skipped elsewhere.
    const d = for (128..192) |n| {
        var buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buf, "/dev/dri/renderD{d}", .{n}, 0) catch unreachable;
        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (!ok(rc)) continue;
        const dev: Device = .{ .fd = @intCast(rc) };
        if (dev.supported()) break dev;
        dev.close();
    } else return error.SkipZigTest;
    defer d.close();
    const handle = try d.create();
    defer d.destroy(handle);
    const efd = try eventFd();
    defer _ = linux.close(efd);
    try d.watch(handle, 2, efd);
    var count: u64 = 0;
    try d.signal(handle, 1);
    try std.testing.expect(!ok(linux.read(efd, std.mem.asBytes(&count), 8))); // point 2 still unsignaled
    try d.signal(handle, 2);
    try std.testing.expectEqual(@as(usize, 8), linux.read(efd, std.mem.asBytes(&count), 8));
    const fd = try d.exportFd(handle);
    _ = linux.close(fd);
}
