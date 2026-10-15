//! A zip reader for EPUB containers (D32): the central directory, stored
//! and deflated entries (std.compress.flate), no ZIP64, no encryption.
//! Untrusted input: every offset and size is checked, and an entry
//! inflates to at most its recorded size and a hard limit.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, InvalidZip, Unsupported, TooLarge };

/// The most an entry may inflate to.
pub const max_entry = 256 << 20;

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
                var in: std.Io.Reader = .fixed(data);
                var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, e.size);
                errdefer aw.deinit();
                var buf: [std.compress.flate.max_window_len]u8 = undefined;
                var d: std.compress.flate.Decompress = .init(&in, .raw, &buf);
                _ = d.reader.streamRemaining(&aw.writer) catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                    else => return error.InvalidZip,
                };
                if (aw.written().len != e.size) return error.InvalidZip;
                return aw.toOwnedSlice() catch error.OutOfMemory;
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
