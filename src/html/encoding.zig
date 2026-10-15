//! Character encodings (WHATWG Encoding, the part documents use): a byte
//! order mark, the caller's label (an email part's charset), or a
//! `<meta charset>` in the first 1024 bytes picks UTF-8, UTF-16, or
//! windows-1252 (which the standard maps ISO-8859-1 and ASCII to). Other
//! labels decode as UTF-8 with replacement characters. Without any of
//! them, input that is not valid UTF-8 is taken as windows-1252, which is
//! what legacy mail without a charset nearly always is.

const std = @import("std");

pub const Encoding = enum { utf8, utf16le, utf16be, windows1252 };

/// The encoding a label names, or null for labels siv does not decode.
pub fn fromLabel(label_: []const u8) ?Encoding {
    const label = std.mem.trim(u8, label_, " \t\n\r\x0C\"'");
    const utf8 = [_][]const u8{ "utf-8", "utf8", "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "x-unicode20utf8" };
    const latin = [_][]const u8{ "windows-1252", "cp1252", "x-cp1252", "iso-8859-1", "iso8859-1", "iso_8859-1", "iso88591", "latin1", "l1", "us-ascii", "ascii", "ansi_x3.4-1968", "cp819", "csisolatin1", "ibm819", "iso-ir-100", "iso_8859-1:1987" };
    for (utf8) |l| if (std.ascii.eqlIgnoreCase(label, l)) return .utf8;
    for (latin) |l| if (std.ascii.eqlIgnoreCase(label, l)) return .windows1252;
    if (std.ascii.eqlIgnoreCase(label, "utf-16le") or std.ascii.eqlIgnoreCase(label, "utf-16")) return .utf16le;
    if (std.ascii.eqlIgnoreCase(label, "utf-16be")) return .utf16be;
    return null;
}

/// Picks the encoding of `bytes`.
pub fn sniff(bytes: []const u8, label: []const u8) Encoding {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) return .utf8;
    if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return .utf16le;
    if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return .utf16be;
    if (label.len != 0) if (fromLabel(label)) |e| return e;
    if (prescan(bytes[0..@min(bytes.len, 1024)])) |e| {
        // A meta claiming UTF-16 in an ASCII-compatible file is UTF-8.
        if (e == .utf16le or e == .utf16be) return .utf8;
        if (e == .windows1252 and std.unicode.utf8ValidateSlice(bytes)) return .windows1252;
        return e;
    }
    return if (std.unicode.utf8ValidateSlice(bytes)) .utf8 else .windows1252;
}

/// The charset of a `<meta charset>` or `<meta http-equiv content>`.
fn prescan(bytes: []const u8) ?Encoding {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "<")) |lt| {
        i = lt + 1;
        if (bytes.len - lt < 5 or !std.ascii.eqlIgnoreCase(bytes[lt + 1 .. lt + 5], "meta")) continue;
        const end = std.mem.indexOfScalarPos(u8, bytes, lt, '>') orelse bytes.len;
        const tag = bytes[lt..end];
        var at: usize = 0;
        while (indexOfIgnoreCase(tag[at..], "charset")) |k| {
            var j = at + k + 7;
            at = j;
            while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t')) j += 1;
            if (j >= tag.len or tag[j] != '=') continue;
            j += 1;
            while (j < tag.len and (tag[j] == ' ' or tag[j] == '"' or tag[j] == '\'')) j += 1;
            var e = j;
            while (e < tag.len and !(tag[e] == '"' or tag[e] == '\'' or tag[e] == ';' or tag[e] == ' ' or tag[e] == '/' or tag[e] == '>')) e += 1;
            if (fromLabel(tag[j..e])) |enc| return enc;
            return .utf8;
        }
        i = end;
    }
    return null;
}

fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (hay.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return i;
    return null;
}

const cp1252 = [32]u21{ 0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178 };

/// `bytes` as UTF-8: returned as is when it already is (without a BOM),
/// otherwise decoded into memory the caller frees. Invalid sequences
/// become U+FFFD.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, enc: Encoding) error{OutOfMemory}![]const u8 {
    switch (enc) {
        .utf8 => {
            const b = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
            if (std.unicode.utf8ValidateSlice(b)) return b;
            var out = try std.ArrayList(u8).initCapacity(gpa, b.len + b.len / 8);
            errdefer out.deinit(gpa);
            var i: usize = 0;
            while (i < b.len) {
                const l = std.unicode.utf8ByteSequenceLength(b[i]) catch {
                    try out.appendSlice(gpa, "\u{FFFD}");
                    i += 1;
                    continue;
                };
                if (i + l <= b.len) if (std.unicode.utf8Decode(b[i..][0..l])) |_| {
                    try out.appendSlice(gpa, b[i..][0..l]);
                    i += l;
                    continue;
                } else |_| {};
                try out.appendSlice(gpa, "\u{FFFD}");
                i += 1;
            }
            return out.toOwnedSlice(gpa);
        },
        .windows1252 => {
            var out = try std.ArrayList(u8).initCapacity(gpa, bytes.len + bytes.len / 4);
            errdefer out.deinit(gpa);
            for (bytes) |c| {
                const cp: u21 = if (c >= 0x80 and c <= 0x9F) cp1252[c - 0x80] else c;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                try out.appendSlice(gpa, buf[0..n]);
            }
            return out.toOwnedSlice(gpa);
        },
        .utf16le, .utf16be => {
            var b = bytes;
            if (b.len >= 2 and ((b[0] == 0xFF and b[1] == 0xFE) or (b[0] == 0xFE and b[1] == 0xFF))) b = b[2..];
            var out = try std.ArrayList(u8).initCapacity(gpa, b.len);
            errdefer out.deinit(gpa);
            var i: usize = 0;
            while (i + 1 < b.len) : (i += 2) {
                const u: u16 = if (enc == .utf16le) @as(u16, b[i]) | @as(u16, b[i + 1]) << 8 else @as(u16, b[i]) << 8 | b[i + 1];
                var cp: u21 = u;
                if (u >= 0xD800 and u <= 0xDBFF and i + 3 < b.len) {
                    const lo: u16 = if (enc == .utf16le) @as(u16, b[i + 2]) | @as(u16, b[i + 3]) << 8 else @as(u16, b[i + 2]) << 8 | b[i + 3];
                    if (lo >= 0xDC00 and lo <= 0xDFFF) {
                        cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (lo - 0xDC00);
                        i += 2;
                    } else cp = 0xFFFD;
                } else if (u >= 0xD800 and u <= 0xDFFF) cp = 0xFFFD;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                try out.appendSlice(gpa, buf[0..n]);
            }
            return out.toOwnedSlice(gpa);
        },
    }
}

test "sniffing and decoding" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(Encoding.utf8, sniff("<p>caf\xC3\xA9", ""));
    try std.testing.expectEqual(Encoding.windows1252, sniff("<p>caf\xE9", ""));
    try std.testing.expectEqual(Encoding.windows1252, sniff("<meta charset=\"iso-8859-1\"><p>x", ""));
    try std.testing.expectEqual(Encoding.utf8, sniff("<meta http-equiv=Content-Type content=\"text/html; charset=utf-8\">", ""));
    const s = try decode(gpa, "caf\xE9 \x93q\x94", .windows1252);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("café \u{201C}q\u{201D}", s);
}
