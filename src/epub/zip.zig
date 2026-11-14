//! A zip reader for EPUB containers (D32): the central directory, stored
//! and deflated entries (std.compress.flate), no ZIP64, no encryption.
//! Untrusted input: every offset and size is checked, and an entry
//! inflates to at most its recorded size and a hard limit.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, InvalidZip, Unsupported, TooLarge };

/// The most an entry may inflate to.
pub const max_entry = 256 << 20;

/// The most deflate expands its input by: a match of 258 bytes takes two
/// bits at least (a length code and a distance code of one bit each).
const max_ratio = 1032;

pub const Entry = struct {
    name: []const u8,
    method: u16,
    compressed: u32,
    size: u32,
    /// Offset of the local file header.
    local: u32,
};

pub const Archive = struct {
    bytes: []const u8,
    entries: []Entry,

    pub fn deinit(z: *Archive, gpa: Allocator) void {
        gpa.free(z.entries);
    }

    pub fn find(z: *const Archive, name: []const u8) ?*const Entry {
        for (z.entries) |*e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    /// An entry's bytes, allocated with `gpa`.
    pub fn read(z: *const Archive, gpa: Allocator, e: *const Entry) Error![]u8 {
        const b = z.bytes;
        if (e.local > b.len or b.len - e.local < 30) return error.InvalidZip;
        const h = b[e.local..];
        if (!std.mem.eql(u8, h[0..4], "PK\x03\x04")) return error.InvalidZip;
        if (u16At(h, 6) & 1 != 0) return error.Unsupported; // encrypted
        const data_start = @as(usize, e.local) + 30 + u16At(h, 26) + u16At(h, 28);
        if (data_start > b.len or b.len - data_start < e.compressed) return error.InvalidZip;
        const data = b[data_start..][0..e.compressed];
        if (e.size > max_entry) return error.TooLarge;
        switch (e.method) {
            0 => {
                if (e.compressed != e.size) return error.InvalidZip;
                return gpa.dupe(u8, data);
            },
            8 => {
                // The recorded size is the archive's word. Deflate
                // writes at most 258 bytes for two bits of input, 1032
                // to 1, so a size beyond that is wrong whatever the
                // stream holds, and is not allocated.
                if (e.size > @as(u64, e.compressed) * max_ratio) return error.InvalidZip;
                const out = try gpa.alloc(u8, e.size);
                errdefer gpa.free(out);
                var in: std.Io.Reader = .fixed(data);
                var buf: [std.compress.flate.max_window_len]u8 = undefined;
                var d: std.compress.flate.Decompress = .init(&in, .raw, &buf);
                // Exactly the recorded size: the stream ends short of
                // it, or has a byte more.
                const n = d.reader.readSliceShort(out) catch return error.InvalidZip;
                if (n != out.len) return error.InvalidZip;
                if (d.reader.peekByte()) |_| return error.InvalidZip else |err| switch (err) {
                    error.EndOfStream => {},
                    error.ReadFailed => return error.InvalidZip,
                }
                return out;
            },
            else => return error.Unsupported,
        }
    }
};

fn u16At(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// Reads the central directory. Names point into `bytes`, which must
/// outlive the archive.
pub fn open(gpa: Allocator, bytes: []const u8) Error!Archive {
    if (bytes.len < 22) return error.InvalidZip;
    // The end of central directory record, searched back over a comment.
    var eocd: usize = bytes.len - 22;
    const floor = if (bytes.len > 22 + 0xffff) bytes.len - 22 - 0xffff else 0;
    while (!std.mem.eql(u8, bytes[eocd..][0..4], "PK\x05\x06")) {
        if (eocd == floor) return error.InvalidZip;
        eocd -= 1;
    }
    const count = u16At(bytes, eocd + 10);
    const dir_size = u32At(bytes, eocd + 12);
    const dir_off = u32At(bytes, eocd + 16);
    if (count == 0xffff or dir_off == 0xffffffff) return error.Unsupported; // ZIP64
    if (dir_off > bytes.len or bytes.len - dir_off < dir_size) return error.InvalidZip;
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    var at: usize = dir_off;
    for (0..count) |_| {
        if (bytes.len - at < 46 or !std.mem.eql(u8, bytes[at..][0..4], "PK\x01\x02")) return error.InvalidZip;
        const name_len = u16At(bytes, at + 28);
        const extra_len = u16At(bytes, at + 30);
        const comment_len = u16At(bytes, at + 32);
        if (bytes.len - at - 46 < @as(usize, name_len) + extra_len + comment_len) return error.InvalidZip;
        try entries.append(gpa, .{
            .name = bytes[at + 46 ..][0..name_len],
            .method = u16At(bytes, at + 10),
            .compressed = u32At(bytes, at + 20),
            .size = u32At(bytes, at + 24),
            .local = u32At(bytes, at + 42),
        });
        at += 46 + @as(usize, name_len) + extra_len + comment_len;
    }
    return .{ .bytes = bytes, .entries = try entries.toOwnedSlice(gpa) };
}

test "stored and deflated entries" {
    const gpa = std.testing.allocator;
    // Python's zipfile: a.txt deflated, b.txt stored.
    const bytes = @embedFile("testdata/tiny.zip");
    var z = try open(gpa, bytes);
    defer z.deinit(gpa);
    try std.testing.expectEqual(2, z.entries.len);
    const a = try z.read(gpa, z.find("a.txt").?);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("hello hello hello hello", a);
    const b = try z.read(gpa, z.find("b.txt").?);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("xyz", b);
    try std.testing.expectError(error.InvalidZip, open(gpa, bytes[0 .. bytes.len - 30]));
}

/// A zip of one entry for tests: `data` is what the archive holds for
/// it, `size` what the headers say it inflates to.
fn oneEntry(gpa: Allocator, method: u16, data: []const u8, size: u32) ![]u8 {
    const name = "a";
    const put = std.mem.writeInt;
    var local: [30]u8 = @splat(0);
    local[0..4].* = "PK\x03\x04".*;
    put(u16, local[8..10], method, .little);
    put(u32, local[18..22], @intCast(data.len), .little);
    put(u32, local[22..26], size, .little);
    put(u16, local[26..28], name.len, .little);
    var dir: [46]u8 = @splat(0);
    dir[0..4].* = "PK\x01\x02".*;
    put(u16, dir[10..12], method, .little);
    put(u32, dir[20..24], @intCast(data.len), .little);
    put(u32, dir[24..28], size, .little);
    put(u16, dir[28..30], name.len, .little);
    var end: [22]u8 = @splat(0);
    end[0..4].* = "PK\x05\x06".*;
    put(u16, end[8..10], 1, .little);
    put(u16, end[10..12], 1, .little);
    put(u32, end[12..16], dir.len + name.len, .little);
    put(u32, end[16..20], @intCast(local.len + name.len + data.len), .little);
    return std.mem.concat(gpa, u8, &.{ &local, name, data, &dir, name, &end });
}

test "an entry does not inflate past its recorded size" {
    const gpa = std.testing.allocator;
    // A megabyte of zeros as deflate's stored blocks: a final-block bit
    // and type 0, the length, and its complement.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    const blocks = 16;
    for (0..blocks) |k| {
        try stream.appendSlice(gpa, &.{ @intFromBool(k + 1 == blocks), 0xff, 0xff, 0x00, 0x00 });
        try stream.appendNTimes(gpa, 0, 0xffff);
    }
    const total = blocks * 0xffff;
    // Reading may allocate what the entry records and no more: the
    // allocator has 64 KiB.
    const room = try gpa.alloc(u8, 64 << 10);
    defer gpa.free(room);
    for ([_]u32{ 0, 16, 40_000 }) |size| {
        const bytes = try oneEntry(gpa, 8, stream.items, size);
        defer gpa.free(bytes);
        var z = try open(gpa, bytes);
        defer z.deinit(gpa);
        var limited: std.heap.FixedBufferAllocator = .init(room);
        try std.testing.expectError(error.InvalidZip, z.read(limited.allocator(), &z.entries[0]));
    }
    // With room, the whole entry and nothing else is the entry.
    {
        const bytes = try oneEntry(gpa, 8, stream.items, total);
        defer gpa.free(bytes);
        var z = try open(gpa, bytes);
        defer z.deinit(gpa);
        const data = try z.read(gpa, &z.entries[0]);
        defer gpa.free(data);
        try std.testing.expectEqual(total, data.len);
        try std.testing.expect(std.mem.allEqual(u8, data, 0));
    }
    // An entry that ends short of its recorded size.
    {
        const bytes = try oneEntry(gpa, 8, stream.items, total + 1);
        defer gpa.free(bytes);
        var z = try open(gpa, bytes);
        defer z.deinit(gpa);
        try std.testing.expectError(error.InvalidZip, z.read(gpa, &z.entries[0]));
    }
}

test "an entry's recorded size is checked against what deflate can hold" {
    const gpa = std.testing.allocator;
    // An empty stored block, recorded as 200 MiB: no stream of 5 bytes
    // inflates to that, so nothing is allocated for it.
    const bytes = try oneEntry(gpa, 8, &.{ 1, 0, 0, 0xff, 0xff }, 200 << 20);
    defer gpa.free(bytes);
    var z = try open(gpa, bytes);
    defer z.deinit(gpa);
    var none: std.heap.FixedBufferAllocator = .init(&.{});
    try std.testing.expectError(error.InvalidZip, z.read(none.allocator(), &z.entries[0]));
}
