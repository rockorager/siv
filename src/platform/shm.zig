//! wl_shm buffers for presentation (D10). Each window owns a swapchain of up
//! to three buffers backed by memfds. A buffer is busy from attach until the
//! compositor releases it; buffers of a stale size are destroyed once
//! released.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const wl = @import("wayland").client.wl;
const platform = @import("platform.zig");

pub const ShmBuffer = struct {
    allocator: Allocator,
    buffer: *wl.Buffer,
    data: []align(std.heap.page_size_min) u8,
    width: u32,
    height: u32,
    stride: u32,
    busy: bool = false,
    /// No longer in a swapchain: destroy when released.
    retired: bool = false,

    fn create(allocator: Allocator, shm: *wl.Shm, width: u32, height: u32) platform.Error!*ShmBuffer {
        const stride = width * 4;
        const size = @as(usize, stride) * height;
        if (size == 0 or size > std.math.maxInt(i32)) return error.SystemResources;

        const fd_rc = linux.memfd_create("siv-shm", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
        if (linux.errno(fd_rc) != .SUCCESS) return error.SystemResources;
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.SystemResources;
        const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(addr) != .SUCCESS) return error.SystemResources;
        const data: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(addr))[0..size];
        errdefer _ = linux.munmap(data.ptr, data.len);

        const pool = shm.createPool(fd, @intCast(size)) catch return error.OutOfMemory;
        defer pool.destroy();
        const buffer = pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), .argb8888) catch
            return error.OutOfMemory;
        errdefer buffer.destroy();

        const self = try allocator.create(ShmBuffer);
        self.* = .{ .allocator = allocator, .buffer = buffer, .data = data, .width = width, .height = height, .stride = stride };
        buffer.setListener(*ShmBuffer, onBufferEvent, self);
        return self;
    }

    fn destroy(self: *ShmBuffer) void {
        self.buffer.destroy();
        _ = linux.munmap(self.data.ptr, self.data.len);
        self.allocator.destroy(self);
    }

    fn onBufferEvent(_: *wl.Buffer, event: wl.Buffer.Event, self: *ShmBuffer) void {
        switch (event) {
            .release => {
                self.busy = false;
                if (self.retired) self.destroy();
            },
        }
    }
};

pub const Swapchain = struct {
    slots: [3]?*ShmBuffer = @splat(null),

    pub fn deinit(sc: *Swapchain) void {
        for (&sc.slots) |*slot| if (slot.*) |b| {
            b.destroy();
            slot.* = null;
        };
    }

    /// A free buffer of the given size, creating or replacing one if needed.
    pub fn acquire(sc: *Swapchain, allocator: Allocator, shm: *wl.Shm, width: u32, height: u32) platform.Error!platform.Buffer {
        // Retire buffers of a stale size; free ones go now.
        for (&sc.slots) |*slot| if (slot.*) |b| {
            if (b.width == width and b.height == height) continue;
            slot.* = null;
            if (b.busy) b.retired = true else b.destroy();
        };
        for (sc.slots, 0..) |slot, i| if (slot) |b| {
            if (!b.busy) return view(b, i);
        };
        for (&sc.slots, 0..) |*slot, i| if (slot.* == null) {
            const b = try ShmBuffer.create(allocator, shm, width, height);
            slot.* = b;
            return view(b, i);
        };
        return error.NoBufferAvailable;
    }

    pub fn get(sc: *Swapchain, slot: u8) *ShmBuffer {
        return sc.slots[slot].?;
    }

    fn view(b: *ShmBuffer, slot: usize) platform.Buffer {
        return .{ .pixels = b.data, .width = b.width, .height = b.height, .stride = b.stride, .slot = @intCast(slot) };
    }
};
