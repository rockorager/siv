//! A minimal reader of the PDFs the writer makes, for tests: objects by
//! the xref table (every offset must name its object), exact stream
//! lengths, and Flate-decoded streams. Not part of libsiv.

const std = @import("std");

const gpa = std.testing.allocator;

/// The objects of a PDF, by number, checked against its xref table.
pub const Parsed = struct {
    bytes: []const u8,
    /// Object bodies by number - 1.
    objects: std.ArrayList([]const u8) = .empty,

    pub fn deinit(p: *Parsed) void {
        p.objects.deinit(gpa);
    }

    pub fn object(p: *const Parsed, n: u32) []const u8 {
        return p.objects.items[n - 1];
    }

    /// The decompressed data of stream object `n`.
    pub fn stream(p: *const Parsed, n: u32) ![]u8 {
        const body = p.object(n);
        const start = (std.mem.indexOf(u8, body, "stream\n") orelse return error.NotAStream) + 7;
        const end = std.mem.lastIndexOf(u8, body, "\nendstream") orelse return error.NotAStream;
        const len = try dictInt(body, "/Length");
        if (end - start != len) return error.BadLength;
        var in: std.Io.Reader = .fixed(body[start..end]);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        var buf: [std.compress.flate.max_window_len]u8 = undefined;
        var d: std.compress.flate.Decompress = .init(&in, .zlib, &buf);
        _ = try d.reader.streamRemaining(&aw.writer);
        return aw.toOwnedSlice();
    }

    pub fn parse(bytes: []const u8) !Parsed {
        var p: Parsed = .{ .bytes = bytes };
        errdefer p.deinit();
        if (!std.mem.startsWith(u8, bytes, "%PDF-1.7\n")) return error.BadHeader;
        const sx = std.mem.lastIndexOf(u8, bytes, "startxref\n") orelse return error.NoStartxref;
        const xref_off = try std.fmt.parseInt(usize, std.mem.trim(u8, bytes[sx + 10 ..][0..std.mem.indexOfScalar(u8, bytes[sx + 10 ..], '\n').?], " "), 10);
        if (!std.mem.startsWith(u8, bytes[xref_off..], "xref\n0 ")) return error.BadXref;
        var lines = std.mem.splitScalar(u8, bytes[xref_off..], '\n');
        _ = lines.next();
        const head = lines.next().?;
        const count = try std.fmt.parseInt(usize, head[2..], 10);
        _ = lines.next(); // the free entry
        for (1..count) |n| {
            const line = lines.next().?;
            const off = try std.fmt.parseInt(usize, line[0..10], 10);
            var prefix: [24]u8 = undefined;
            const want = std.fmt.bufPrint(&prefix, "{d} 0 obj\n", .{n}) catch unreachable;
            if (!std.mem.startsWith(u8, bytes[off..], want)) return error.BadOffset;
            const end = std.mem.indexOf(u8, bytes[off..], "\nendobj\n") orelse return error.NoEndobj;
            try p.objects.append(gpa, bytes[off + want.len ..][0 .. end - want.len]);
        }
        const trailer = bytes[std.mem.lastIndexOf(u8, bytes, "trailer").?..];
        if (try dictInt(trailer, "/Size") != count) return error.BadSize;
        if (std.mem.indexOf(u8, trailer, "/Root ") == null or std.mem.indexOf(u8, trailer, "/ID [") == null) return error.BadTrailer;
        return p;
    }
};

pub fn dictInt(body: []const u8, key_arg: []const u8) !usize {
    const key = std.mem.trimEnd(u8, key_arg, " ");
    // The key itself, not a longer name it prefixes (/Length1).
    var i: usize = 0;
    while (true) : (i += key.len) {
        i += std.mem.indexOf(u8, body[i..], key) orelse return error.NoKey;
        const after = body[i + key.len ..];
        if (after.len == 0 or !std.ascii.isAlphanumeric(key[key.len - 1]) or !std.ascii.isAlphanumeric(after[0])) break;
    }
    const rest = std.mem.trimStart(u8, body[i + key.len ..], " ");
    var n: usize = 0;
    while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
    return std.fmt.parseInt(usize, rest[0..n], 10);
}

/// The object number referenced as `key N 0 R` in `body`.
pub fn ref(body: []const u8, key: []const u8) !u32 {
    return @intCast(try dictInt(body, key));
}
