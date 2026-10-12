//! Memory for masked editor contents (D15): its own pages, locked so they
//! are never swapped, excluded from core dumps, wiped in forked children,
//! and zeroed before they are unmapped.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{OutOfMemory};

const page = std.heap.page_size_min;

fn mappedLen(len: usize) usize {
    return std.mem.alignForward(usize, len, page);
}

/// A locked copy of `bytes` (empty stays empty and maps nothing).
pub fn dupe(bytes: []const u8) Error![]const u8 {
    const buf = try alloc(bytes.len);
    @memcpy(buf, bytes);
    return buf;
}

/// Locked memory for `len` bytes, zeroed.
pub fn alloc(len: usize) Error![]u8 {
    if (len == 0) return &.{};
    const size = mappedLen(len);
    const rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OutOfMemory;
    const ptr: [*]u8 = @ptrFromInt(rc);
    errdefer _ = linux.munmap(ptr, size);
    // A memlock limit too small for a password is a resource failure.
    if (linux.errno(linux.mlock(ptr, size)) != .SUCCESS) return error.OutOfMemory;
    _ = linux.madvise(ptr, size, linux.MADV.DONTDUMP);
    _ = linux.madvise(ptr, size, linux.MADV.WIPEONFORK);
    return ptr[0..len];
}

/// Zeroes, unlocks, and unmaps memory from `alloc` or `dupe`.
pub fn free(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const size = mappedLen(bytes.len);
    const ptr: [*]u8 = @constCast(bytes.ptr);
    std.crypto.secureZero(u8, ptr[0..size]);
    _ = linux.munlock(ptr, size);
    _ = linux.munmap(ptr, size);
}

test "secrets live in locked pages" {
    const s = try dupe("hunter2");
    defer free(s);
    try std.testing.expectEqualStrings("hunter2", s);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(s.ptr) % page);
    // VmLck in /proc/self/status counts the page.
    var buf: [4096]u8 = undefined;
    const fd: i32 = @intCast(linux.open("/proc/self/status", .{ .ACCMODE = .RDONLY }, 0));
    defer _ = linux.close(fd);
    const n = linux.read(fd, &buf, buf.len);
    const status = buf[0..n];
    const at = std.mem.indexOf(u8, status, "VmLck:").?;
    const line = std.mem.sliceTo(status[at + 6 ..], '\n');
    const kb = try std.fmt.parseInt(usize, std.mem.trim(u8, line, " \tkB"), 10);
    try std.testing.expect(kb >= page / 1024);
    try std.testing.expectEqual(@as(usize, 0), (try dupe("")).len);
}
