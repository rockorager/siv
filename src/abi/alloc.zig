//! Allocator hooks (D2): a `std.mem.Allocator` that calls the application's
//! siv_allocator functions. Every allocation a root makes goes through its
//! allocator, so hook failures surface as SIV_ERROR_OUT_OF_MEMORY.

const std = @import("std");
const Alignment = std.mem.Alignment;

pub const AllocFn = *const fn (user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque;
pub const FreeFn = *const fn (user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void;

pub const Hooks = struct {
    user_data: ?*anyopaque,
    alloc: AllocFn,
    free: FreeFn,

    /// The allocator to use: the hooks, or the C library allocator when
    /// `hooks` is null. The returned allocator points at `hooks`.
    pub fn allocator(hooks: ?*const Hooks) std.mem.Allocator {
        const h = hooks orelse return std.heap.c_allocator;
        return .{ .ptr = @constCast(h), .vtable = &vtable };
    }
};

/// Reads a siv_allocator descriptor that runtime.readDesc already copied.
/// Returns null for "use the default".
pub fn fromDesc(desc: anytype) error{InvalidArgument}!?Hooks {
    const alloc_fn = desc.alloc orelse {
        if (desc.free != null) return error.InvalidArgument;
        return null;
    };
    return .{ .user_data = desc.user_data, .alloc = alloc_fn, .free = desc.free orelse return error.InvalidArgument };
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = free,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const h: *const Hooks = @ptrCast(@alignCast(ctx));
    const p = h.alloc(h.user_data, len, alignment.toByteUnits()) orelse return null;
    // A misaligned block would be undefined behavior for the caller. Give
    // it back and report failure instead.
    if (!alignment.check(@intFromPtr(p))) {
        h.free(h.user_data, p, len, alignment.toByteUnits());
        return null;
    }
    return @ptrCast(p);
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    const h: *const Hooks = @ptrCast(@alignCast(ctx));
    h.free(h.user_data, memory.ptr, memory.len, alignment.toByteUnits());
}

test "hooks see sizes and alignments, and misaligned blocks fail" {
    // A bump allocator over a static buffer that can be told to misalign.
    const Counter = struct {
        live: isize = 0,
        misalign: bool = false,
        used: usize = 0,
        buf: [1024]u8 align(64) = undefined,

        fn allocHook(ud: ?*anyopaque, size: usize, a: usize) callconv(.c) ?*anyopaque {
            const self: *@This() = @ptrCast(@alignCast(ud));
            const start = std.mem.alignForward(usize, self.used, a) + @intFromBool(self.misalign);
            if (start + size > self.buf.len) return null;
            self.used = start + size;
            self.live += @intCast(size);
            return &self.buf[start];
        }
        fn freeHook(ud: ?*anyopaque, _: ?*anyopaque, size: usize, _: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ud));
            self.live -= @intCast(size);
        }
    };
    var counter: Counter = .{};
    const hooks: Hooks = .{ .user_data = &counter, .alloc = Counter.allocHook, .free = Counter.freeHook };
    const a = Hooks.allocator(&hooks);

    const xs = try a.alignedAlloc(u8, .@"32", 100);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(xs.ptr), 32));
    try std.testing.expectEqual(100, counter.live);
    // No resize hook: growing reallocates through alloc and free.
    const ys = try a.realloc(xs, 300);
    try std.testing.expectEqual(300, counter.live);
    a.free(ys);
    try std.testing.expectEqual(0, counter.live);

    counter.misalign = true;
    try std.testing.expectError(error.OutOfMemory, a.alignedAlloc(u8, .@"16", 8));
    try std.testing.expectEqual(0, counter.live);
}

test "fromDesc requires both functions or neither" {
    const D = struct { user_data: ?*anyopaque = null, alloc: ?AllocFn = null, free: ?FreeFn = null };
    try std.testing.expectEqual(null, try fromDesc(D{}));
    const f = struct {
        fn a(_: ?*anyopaque, _: usize, _: usize) callconv(.c) ?*anyopaque {
            return null;
        }
    }.a;
    try std.testing.expectError(error.InvalidArgument, fromDesc(D{ .alloc = f }));
}
