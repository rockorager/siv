//! Binary min-heap of timers ordered by deadline. Each timer stores its heap
//! position so that cancellation is O(log n).

const std = @import("std");
const Allocator = std.mem.Allocator;
const TimerHeap = @This();

items: std.ArrayList(*Timer) = .empty,

pub const Timer = struct {
    /// Runs on the loop thread in the timers phase.
    func: *const fn (*Timer) void,
    /// Absolute CLOCK_MONOTONIC deadline in nanoseconds.
    deadline: u64 = 0,
    /// Repeat interval in nanoseconds, or 0 for a one-shot timer.
    interval: u64 = 0,
    /// Position in the heap while the timer is armed.
    index: ?u32 = null,

    pub fn armed(t: *const Timer) bool {
        return t.index != null;
    }
};

pub fn deinit(h: *TimerHeap, gpa: Allocator) void {
    for (h.items.items) |t| t.index = null;
    h.items.deinit(gpa);
}

pub fn peek(h: *const TimerHeap) ?*Timer {
    return if (h.items.items.len == 0) null else h.items.items[0];
}

pub fn insert(h: *TimerHeap, gpa: Allocator, t: *Timer) Allocator.Error!void {
    std.debug.assert(t.index == null);
    try h.items.ensureUnusedCapacity(gpa, 1);
    h.insertAssumeCapacity(t);
}

/// Inserts without allocating. Valid right after `remove` or `pop`.
pub fn insertAssumeCapacity(h: *TimerHeap, t: *Timer) void {
    std.debug.assert(t.index == null);
    const i: u32 = @intCast(h.items.items.len);
    h.items.appendAssumeCapacity(t);
    t.index = i;
    h.siftUp(i);
}

pub fn remove(h: *TimerHeap, t: *Timer) void {
    const i = t.index orelse return;
    const last = h.items.pop().?;
    t.index = null;
    if (last == t) return;
    h.items.items[i] = last;
    last.index = i;
    h.siftDown(i);
    h.siftUp(last.index.?);
}

pub fn pop(h: *TimerHeap) ?*Timer {
    const t = h.peek() orelse return null;
    h.remove(t);
    return t;
}

fn less(a: *const Timer, b: *const Timer) bool {
    return a.deadline < b.deadline;
}

fn swap(h: *TimerHeap, i: u32, j: u32) void {
    const items = h.items.items;
    std.mem.swap(*Timer, &items[i], &items[j]);
    items[i].index = i;
    items[j].index = j;
}

fn siftUp(h: *TimerHeap, start: u32) void {
    var i = start;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (!less(h.items.items[i], h.items.items[parent])) break;
        h.swap(i, parent);
        i = parent;
    }
}

fn siftDown(h: *TimerHeap, start: u32) void {
    const n: u32 = @intCast(h.items.items.len);
    var i = start;
    while (true) {
        var smallest = i;
        const l = 2 * i + 1;
        const r = l + 1;
        if (l < n and less(h.items.items[l], h.items.items[smallest])) smallest = l;
        if (r < n and less(h.items.items[r], h.items.items[smallest])) smallest = r;
        if (smallest == i) return;
        h.swap(i, smallest);
        i = smallest;
    }
}

fn noop(_: *Timer) void {}

test "pops in deadline order with removals from the middle" {
    const gpa = std.testing.allocator;
    var heap: TimerHeap = .{};
    defer heap.deinit(gpa);

    // Deadlines chosen so that removing index 1 and 4 forces both a sift
    // down and a sift up of the replacement element.
    const deadlines = [_]u64{ 50, 10, 40, 30, 20, 70, 60, 5, 45 };
    var timers: [deadlines.len]Timer = undefined;
    for (&timers, deadlines) |*t, d| {
        t.* = .{ .func = noop, .deadline = d };
        try heap.insert(gpa, t);
    }
    heap.remove(&timers[1]); // 10
    heap.remove(&timers[4]); // 20
    heap.remove(&timers[1]); // already removed: no-op
    try std.testing.expect(!timers[1].armed());

    var out: std.ArrayList(u64) = .empty;
    defer out.deinit(gpa);
    while (heap.pop()) |t| try out.append(gpa, t.deadline);
    try std.testing.expectEqualSlices(u64, &.{ 5, 30, 40, 45, 50, 60, 70 }, out.items);
}
