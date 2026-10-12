//! A set of byte offsets in `0...len`, stored as one bit per offset. Used for
//! grapheme and word boundaries, which the editor queries in both directions.

const std = @import("std");

const Boundaries = @This();

const Mask = usize;
const bits = @bitSizeOf(Mask);

masks: []Mask,
/// Largest offset the set can hold (the text length).
len: u32,

pub const empty: Boundaries = .{ .masks = &.{}, .len = 0 };

/// Every offset starts unset.
pub fn init(allocator: std.mem.Allocator, len: u32) !Boundaries {
    const masks = try allocator.alloc(Mask, @as(usize, len) / bits + 1);
    @memset(masks, 0);
    return .{ .masks = masks, .len = len };
}

pub fn deinit(self: *Boundaries, allocator: std.mem.Allocator) void {
    allocator.free(self.masks);
    self.* = undefined;
}

pub fn set(self: *Boundaries, offset: u32) void {
    std.debug.assert(offset <= self.len);
    self.masks[offset / bits] |= @as(Mask, 1) << @intCast(offset % bits);
}

pub fn isSet(self: Boundaries, offset: u32) bool {
    if (offset > self.len) return false;
    return self.masks[offset / bits] & (@as(Mask, 1) << @intCast(offset % bits)) != 0;
}

/// The smallest member greater than `offset`, or null.
pub fn after(self: Boundaries, offset: u32) ?u32 {
    if (offset >= self.len) return null;
    var word = (offset + 1) / bits;
    var mask = self.masks[word] & (~@as(Mask, 0) << @intCast((offset + 1) % bits));
    while (true) {
        if (mask != 0) {
            const found: u32 = @intCast(word * bits + @ctz(mask));
            return if (found <= self.len) found else null;
        }
        word += 1;
        if (word == self.masks.len) return null;
        mask = self.masks[word];
    }
}

/// The largest member smaller than `offset`, or null.
pub fn before(self: Boundaries, offset: u32) ?u32 {
    if (offset == 0) return null;
    const last = @min(offset, self.len + 1) - 1;
    var word = last / bits;
    const shift: std.math.Log2Int(Mask) = @intCast(bits - 1 - last % bits);
    var mask = self.masks[word] & (~@as(Mask, 0) >> shift);
    while (true) {
        if (mask != 0) return @intCast(word * bits + (bits - 1 - @clz(mask)));
        if (word == 0) return null;
        word -= 1;
        mask = self.masks[word];
    }
}

/// The member at or before `offset` (0 is always a member of segmentations).
pub fn atOrBefore(self: Boundaries, offset: u32) ?u32 {
    return if (self.isSet(offset)) offset else self.before(offset);
}

test "neighbors across mask words" {
    var set_: Boundaries = try .init(std.testing.allocator, 200);
    defer set_.deinit(std.testing.allocator);
    for ([_]u32{ 0, 3, 63, 64, 130, 200 }) |offset| set_.set(offset);
    try std.testing.expectEqual(3, set_.after(0));
    try std.testing.expectEqual(63, set_.after(3));
    try std.testing.expectEqual(64, set_.after(63));
    try std.testing.expectEqual(130, set_.after(64));
    try std.testing.expectEqual(200, set_.after(131));
    try std.testing.expectEqual(null, set_.after(200));
    try std.testing.expectEqual(130, set_.before(200));
    try std.testing.expectEqual(64, set_.before(130));
    try std.testing.expectEqual(63, set_.before(64));
    try std.testing.expectEqual(0, set_.before(3));
    try std.testing.expectEqual(null, set_.before(0));
    try std.testing.expectEqual(64, set_.atOrBefore(100));
    try std.testing.expect(set_.isSet(63) and !set_.isSet(62));
}
