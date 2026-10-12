//! Generation-checked handles (D2, D20). Handles exist only at the ABI
//! boundary; a handle resolves to the plain index the owning subsystem uses
//! internally.
//!
//! A handle is a uint64_t:
//!
//!     63      56 55      46 45          24 23         0
//!     | type: 8 | root: 10 | generation: 22 | index: 24 |
//!
//! - type: the schema's handle tag (Schema.handleTag), never 0, so no valid
//!   handle is 0 and a handle of the wrong type is rejected.
//! - root: the slot of the owning root in the process-wide `registry`.
//! - generation and index: a slot in the root's `Table`, or for a root
//!   handle the registry slot's generation (index 0).
//!
//! The registry is the only process-wide state in libsiv: a fixed array of
//! slots, claimed and released atomically, so that any handle can be checked
//! without knowing its root and without a global lock. It holds no
//! configuration and needs no initialization.
//!
//! Generations detect stale handles until a slot has been reused 2^22
//! times. Tables reuse a slot only once `min_free` slots are free, so a
//! create-destroy loop walks the whole free list instead of wearing one slot
//! out. A table's generations start from a value derived from its root's
//! registry slot and generation, so a handle presented to the wrong root
//! (a corrupted root field, or a root that reused a destroyed root's slot)
//! matches an object there only by a 1 in 2^22 coincidence.

const std = @import("std");

pub const Error = error{ InvalidHandle, OutOfMemory, LimitExceeded };

pub const index_bits = 24;
pub const generation_bits = 22;
pub const root_bits = 10;
pub const type_bits = 8;

pub const max_index = (1 << index_bits) - 1;
pub const max_roots = 1 << root_bits;
const generation_mask = (1 << generation_bits) - 1;

pub const Fields = struct {
    type: u8,
    root: u10,
    generation: u22,
    index: u24,

    pub fn encode(f: Fields) u64 {
        return @as(u64, f.type) << 56 | @as(u64, f.root) << 46 | @as(u64, f.generation) << 24 | f.index;
    }

    pub fn decode(h: u64) Fields {
        return .{
            .type = @truncate(h >> 56),
            .root = @truncate(h >> 46),
            .generation = @truncate(h >> 24),
            .index = @truncate(h),
        };
    }
};

/// Process-wide root registry.
pub const Registry = struct {
    slots: [max_roots]Slot = @splat(.{}),
    /// Where the next search for a free slot starts, so that a released slot
    /// is reused as late as possible.
    cursor: std.atomic.Value(u32) = .init(0),

    const Slot = struct {
        root: std.atomic.Value(?*anyopaque) = .init(null),
        generation: std.atomic.Value(u32) = .init(0),
        /// Handle type of the root, so that a library with several root
        /// types never casts a root to the wrong one.
        tag: std.atomic.Value(u8) = .init(0),
        /// Threads between `pin` and `unpin` on this slot; `retire` waits
        /// for them to leave.
        pins: std.atomic.Value(u32) = .init(0),
    };

    /// Claims a slot for the root at `ptr` and returns its handle.
    pub fn register(r: *Registry, tag: u8, ptr: *anyopaque) Error!u64 {
        const start = r.cursor.fetchAdd(1, .monotonic);
        for (0..max_roots) |i| {
            const index: u10 = @truncate(start +% i);
            const slot = &r.slots[index];
            if (slot.root.cmpxchgStrong(null, ptr, .acquire, .monotonic) == null) {
                const gen: u22 = @truncate(slot.generation.load(.monotonic) +% 1);
                slot.tag.store(tag, .monotonic);
                slot.generation.store(gen, .release);
                return Fields.encode(.{ .type = tag, .root = index, .generation = gen, .index = 0 });
            }
        }
        return error.LimitExceeded;
    }

    /// Releases a root's slot. Its handle and every handle of its objects
    /// become invalid.
    pub fn unregister(r: *Registry, handle: u64) void {
        r.retire(handle);
        r.release(handle);
    }

    /// Invalidates a root's handle (and every handle of its objects), then
    /// waits until no thread holds a `pin` on it. Afterwards no other
    /// thread can reach the root, so it can be torn down; `release` frees
    /// the slot once it is gone. Calling it twice is harmless.
    pub fn retire(r: *Registry, handle: u64) void {
        const slot = &r.slots[Fields.decode(handle).root];
        // A stale generation makes concurrent lookups and pins fail before
        // the slot is reused. Sequentially consistent with the pin count,
        // so that either a pinning thread sees the new generation or this
        // thread sees its pin.
        _ = slot.generation.fetchAdd(1, .seq_cst);
        while (slot.pins.load(.seq_cst) != 0) std.Thread.yield() catch {};
    }

    /// Frees a retired root's slot for reuse.
    pub fn release(r: *Registry, handle: u64) void {
        r.slots[Fields.decode(handle).root].root.store(null, .release);
    }

    /// The root a root handle names, kept from being retired until
    /// `unpin`. Safe from any thread while the root is being destroyed on
    /// another: either this fails or the destruction waits. Hold a pin
    /// only briefly (`retire` spins).
    pub fn pin(r: *Registry, handle: u64, tag: u8) Error!*anyopaque {
        const f = Fields.decode(handle);
        if (f.type != tag or f.index != 0) return error.InvalidHandle;
        const slot = &r.slots[f.root];
        _ = slot.pins.fetchAdd(1, .seq_cst);
        errdefer _ = slot.pins.fetchSub(1, .release);
        if (@as(u22, @truncate(slot.generation.load(.seq_cst))) != f.generation) return error.InvalidHandle;
        const p = slot.root.load(.acquire) orelse return error.InvalidHandle;
        if (slot.tag.load(.monotonic) != tag) return error.InvalidHandle;
        return p;
    }

    /// The root of type `root_tag` that owns an object handle, kept from
    /// being retired until `unpin(handle)`. Object handles do not carry
    /// the root's generation, so the caller must check that the root is
    /// not being destroyed (a flag it sets before `retire`) and check the
    /// handle against the root's own records.
    pub fn pinOwner(r: *Registry, handle: u64, root_tag: u8) Error!*anyopaque {
        if (handle == 0) return error.InvalidHandle;
        const slot = &r.slots[Fields.decode(handle).root];
        _ = slot.pins.fetchAdd(1, .seq_cst);
        errdefer _ = slot.pins.fetchSub(1, .release);
        const p = slot.root.load(.acquire) orelse return error.InvalidHandle;
        if (slot.tag.load(.monotonic) != root_tag) return error.InvalidHandle;
        return p;
    }

    pub fn unpin(r: *Registry, handle: u64) void {
        _ = r.slots[Fields.decode(handle).root].pins.fetchSub(1, .release);
    }

    /// The root a root handle names.
    pub fn root(r: *Registry, handle: u64, tag: u8) Error!*anyopaque {
        const f = Fields.decode(handle);
        if (f.type != tag or f.index != 0) return error.InvalidHandle;
        const slot = &r.slots[f.root];
        const p = slot.root.load(.acquire) orelse return error.InvalidHandle;
        if (@as(u22, @truncate(slot.generation.load(.acquire))) != f.generation) return error.InvalidHandle;
        if (slot.tag.load(.monotonic) != tag) return error.InvalidHandle;
        return p;
    }

    /// The root of type `root_tag` that owns an object handle. The caller
    /// checks the handle against that root's table.
    pub fn owner(r: *Registry, handle: u64, root_tag: u8) Error!*anyopaque {
        if (handle == 0) return error.InvalidHandle;
        const slot = &r.slots[Fields.decode(handle).root];
        const p = slot.root.load(.acquire) orelse return error.InvalidHandle;
        if (slot.tag.load(.monotonic) != root_tag) return error.InvalidHandle;
        return p;
    }
};

/// The process-wide registry.
pub var registry: Registry = .{};

/// The handle table of one root: maps object handles to the internal
/// indices (payloads) of their objects. Not thread-safe; it belongs to the
/// root's thread.
pub const Table = struct {
    entries: std.ArrayList(Entry) = .empty,
    root: u10,
    /// Generation that new entries start with.
    seed: u22,
    /// FIFO free list threaded through `Entry.payload`.
    free_head: u32 = none,
    free_tail: u32 = none,
    free_len: u32 = 0,
    live: u32 = 0,

    pub const min_free = 1024;
    const none = std.math.maxInt(u32);

    const Entry = struct {
        generation: u22,
        /// 0 when free.
        type: u8,
        payload: u32,
    };

    /// `root_handle` is the handle of the root that owns the table.
    pub fn init(root_handle: u64) Table {
        const f = Fields.decode(root_handle);
        // Different roots, and successive roots in one registry slot, start
        // at unrelated generations, so a handle presented to the wrong table
        // is very unlikely to match.
        const key = @as(u64, f.root) << 32 | f.generation;
        const seed: u22 = @truncate((key *% 0x9E3779B97F4A7C15) >> 42);
        return .{ .root = f.root, .seed = seed };
    }

    pub fn deinit(t: *Table, gpa: std.mem.Allocator) void {
        t.entries.deinit(gpa);
        t.* = undefined;
    }

    /// Reserves capacity so that the next `insert` cannot fail with
    /// OutOfMemory. Lets callers allocate the object first and the handle
    /// last without a failure path between them.
    pub fn ensureUnusedCapacity(t: *Table, gpa: std.mem.Allocator) Error!void {
        if (t.free_len >= min_free) return;
        if (t.entries.items.len > max_index) return error.LimitExceeded;
        try t.entries.ensureUnusedCapacity(gpa, 1);
    }

    pub fn insert(t: *Table, gpa: std.mem.Allocator, tag: u8, payload: u32) Error!u64 {
        std.debug.assert(tag != 0);
        var index: u32 = undefined;
        if (t.free_len >= min_free) {
            index = t.free_head;
            const e = &t.entries.items[index];
            t.free_head = e.payload;
            t.free_len -= 1;
            if (t.free_len == 0) t.free_tail = none;
        } else {
            try t.ensureUnusedCapacity(gpa);
            index = @intCast(t.entries.items.len);
            t.entries.appendAssumeCapacity(.{ .generation = t.seed, .type = 0, .payload = 0 });
        }
        const e = &t.entries.items[index];
        e.type = tag;
        e.payload = payload;
        t.live += 1;
        return Fields.encode(.{ .type = tag, .root = t.root, .generation = e.generation, .index = @intCast(index) });
    }

    pub fn get(t: *const Table, handle: u64, tag: u8) Error!u32 {
        return (try t.entry(handle, tag)).payload;
    }

    /// Points the handle at a new payload, for objects that move.
    pub fn set(t: *Table, handle: u64, tag: u8, payload: u32) Error!void {
        (try t.entry(handle, tag)).payload = payload;
    }

    /// Invalidates the handle and returns its payload.
    pub fn remove(t: *Table, handle: u64, tag: u8) Error!u32 {
        const e = try t.entry(handle, tag);
        const payload = e.payload;
        const index: u32 = Fields.decode(handle).index;
        e.generation +%= 1;
        e.type = 0;
        e.payload = none;
        if (t.free_tail == none) {
            t.free_head = index;
        } else {
            t.entries.items[t.free_tail].payload = index;
        }
        t.free_tail = index;
        t.free_len += 1;
        t.live -= 1;
        return payload;
    }

    fn entry(t: *const Table, handle: u64, tag: u8) Error!*Entry {
        const f = Fields.decode(handle);
        if (tag == 0 or f.type != tag or f.root != t.root or f.index >= t.entries.items.len) return error.InvalidHandle;
        const e = &t.entries.items[f.index];
        if (e.type != tag or e.generation != f.generation) return error.InvalidHandle;
        return e;
    }
};

test "handle fields round-trip" {
    const f: Fields = .{ .type = 0xab, .root = 0x3ff, .generation = 0x2aaaaa, .index = 0x123456 };
    try std.testing.expectEqual(f, Fields.decode(f.encode()));
    try std.testing.expectEqual(@as(u64, 0xab), f.encode() >> 56);
}

test "table detects stale, foreign, and mistyped handles" {
    const gpa = std.testing.allocator;
    var t: Table = .init(Fields.encode(.{ .type = 1, .root = 5, .generation = 1, .index = 0 }));
    defer t.deinit(gpa);

    const a = try t.insert(gpa, 2, 10);
    const b = try t.insert(gpa, 3, 20);
    try std.testing.expectEqual(10, try t.get(a, 2));
    try std.testing.expectEqual(20, try t.get(b, 3));
    try std.testing.expectError(error.InvalidHandle, t.get(a, 3)); // wrong type
    try std.testing.expectError(error.InvalidHandle, t.get(0, 2));

    var other = Fields.decode(a);
    other.root = 6;
    try std.testing.expectError(error.InvalidHandle, t.get(other.encode(), 2)); // other root

    try std.testing.expectEqual(10, try t.remove(a, 2));
    try std.testing.expectError(error.InvalidHandle, t.get(a, 2));
    try std.testing.expectError(error.InvalidHandle, t.remove(a, 2));
    try std.testing.expectEqual(1, t.live);

    try t.set(b, 3, 21);
    try std.testing.expectEqual(21, try t.get(b, 3));
}

test "freed slots are reused only after min_free others, in FIFO order" {
    const gpa = std.testing.allocator;
    var t: Table = .init(Fields.encode(.{ .type = 1, .root = 0, .generation = 1, .index = 0 }));
    defer t.deinit(gpa);

    var handles: [Table.min_free + 1]u64 = undefined;
    for (&handles, 0..) |*h, i| h.* = try t.insert(gpa, 2, @intCast(i));
    for (handles) |h| _ = try t.remove(h, 2);
    // min_free + 1 free: the oldest free slot (index 0) comes back first,
    // with a new generation.
    const again = try t.insert(gpa, 2, 99);
    try std.testing.expectEqual(0, Fields.decode(again).index);
    try std.testing.expect(Fields.decode(again).generation != Fields.decode(handles[0]).generation);
    try std.testing.expectError(error.InvalidHandle, t.get(handles[0], 2));
    // Now exactly min_free are free; the next insert reuses index 1.
    try std.testing.expectEqual(1, Fields.decode(try t.insert(gpa, 2, 0)).index);
    // Below min_free: a fresh slot.
    try std.testing.expectEqual(Table.min_free + 1, Fields.decode(try t.insert(gpa, 2, 0)).index);
}

test "registry rejects released and mistyped root handles" {
    var r: Registry = .{};
    var a: u8 = 0;
    var b: u8 = 0;
    const ha = try r.register(1, &a);
    const hb = try r.register(1, &b);
    try std.testing.expect(ha != hb);
    try std.testing.expectEqual(@as(*anyopaque, &a), try r.root(ha, 1));
    try std.testing.expectError(error.InvalidHandle, r.root(ha, 2));
    r.unregister(ha);
    try std.testing.expectError(error.InvalidHandle, r.root(ha, 1));
    try std.testing.expectError(error.InvalidHandle, r.owner(ha, 1));
    try std.testing.expectError(error.InvalidHandle, r.owner(hb, 2));

    // Fill every slot: the next registration hits the limit.
    var held: [max_roots - 1]u64 = undefined;
    for (&held) |*h| h.* = try r.register(1, &a);
    try std.testing.expectError(error.LimitExceeded, r.register(1, &a));
    for (held) |h| r.unregister(h);
    r.unregister(hb);
}

test "a reused registry slot does not revive old handles" {
    var r: Registry = .{};
    var x: u8 = 0;
    // Exhaust the cursor so that the next registration lands in the same
    // slot again.
    const first = try r.register(1, &x);
    r.unregister(first);
    r.cursor.store(Fields.decode(first).root, .monotonic);
    const second = try r.register(1, &x);
    try std.testing.expectEqual(Fields.decode(first).root, Fields.decode(second).root);
    try std.testing.expectError(error.InvalidHandle, r.root(first, 1));
    try std.testing.expectEqual(@as(*anyopaque, &x), try r.root(second, 1));
    r.unregister(second);
}

test "retire waits for pins, and pins after retire fail" {
    var r: Registry = .{};
    var x: u8 = 0;
    const h = try r.register(1, &x);
    try std.testing.expectEqual(@as(*anyopaque, &x), try r.pin(h, 1));
    try std.testing.expectError(error.InvalidHandle, r.pin(h, 2));

    const Retirer = struct {
        fn run(reg: *Registry, handle: u64, done: *std.atomic.Value(bool)) void {
            reg.retire(handle);
            done.store(true, .seq_cst);
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Retirer.run, .{ &r, h, &done });
    // The retiring thread cannot finish while the pin is held.
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) std.Thread.yield() catch {};
    try std.testing.expect(!done.load(.seq_cst));
    r.unpin(h);
    thread.join();
    try std.testing.expect(done.load(.seq_cst));
    try std.testing.expectError(error.InvalidHandle, r.pin(h, 1));
    try std.testing.expectError(error.InvalidHandle, r.root(h, 1));
    r.release(h);
}
