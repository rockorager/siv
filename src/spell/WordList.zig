//! A list of words outside the dictionary (D37): the personal
//! dictionary, words ignored for the session, and words excluded from the
//! dictionary. Matching follows Enchant's personal word lists, so a list
//! shared with GNOME applications means the same in siv: a lowercase word
//! also allows its capitalized and all-caps forms, a capitalized one its
//! all-caps form, and other words only themselves.
//!
//! The file format is Enchant's (`~/.config/enchant/<name>.dic`): UTF-8,
//! one word per line; lines starting with # are comments.

const std = @import("std");
const case = @import("case.zig");
const Allocator = std.mem.Allocator;

const WordList = @This();

words: std.StringHashMapUnmanaged(void) = .empty,

pub fn deinit(l: *WordList, gpa: Allocator) void {
    var it = l.words.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    l.words.deinit(gpa);
    l.* = undefined;
}

/// Adds a word (trimmed; empty words and words with line breaks are
/// refused). Returns whether it was new.
pub fn add(l: *WordList, gpa: Allocator, word_in: []const u8) error{OutOfMemory}!bool {
    const word = std.mem.trim(u8, word_in, " \t\r");
    if (!valid(word)) return false;
    if (l.words.contains(word)) return false;
    const owned = try gpa.dupe(u8, word);
    l.words.put(gpa, owned, {}) catch |err| {
        gpa.free(owned);
        return err;
    };
    return true;
}

/// A word a list can hold: non-empty UTF-8 without line breaks.
pub fn valid(word: []const u8) bool {
    return word.len != 0 and word.len <= 256 and std.mem.indexOfAny(u8, word, "\n\r") == null and std.unicode.utf8ValidateSlice(word);
}

/// Adds every word of a word list file.
pub fn parse(l: *WordList, gpa: Allocator, bytes: []const u8) error{OutOfMemory}!void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        _ = try l.add(gpa, line);
    }
}

pub fn contains(l: *const WordList, word: []const u8) bool {
    if (l.words.count() == 0) return false;
    if (l.words.contains(word)) return true;
    const ct = case.captype(word);
    if (ct != .initial and ct != .all) return false;
    var buf: [512]u8 = undefined;
    const lower = case.convertBuf(&buf, word, .lower) orelse return false;
    if (l.words.contains(lower)) return true;
    if (ct != .all) return false;
    var buf2: [512]u8 = undefined;
    const capital = case.convertBuf(&buf2, lower, .capitalize) orelse return false;
    return l.words.contains(capital);
}

test "word lists match like Enchant's" {
    const gpa = std.testing.allocator;
    var l: WordList = .{};
    defer l.deinit(gpa);
    try l.parse(gpa, "# comment\nsiv\nZig\n\niPhone\r\n");
    try std.testing.expect(l.contains("siv") and l.contains("Siv") and l.contains("SIV"));
    try std.testing.expect(l.contains("Zig") and l.contains("ZIG") and !l.contains("zig"));
    try std.testing.expect(l.contains("iPhone") and !l.contains("Iphone") and !l.contains("IPHONE"));
    try std.testing.expect(!l.contains("comment"));
    try std.testing.expect(try l.add(gpa, "wörd"));
    try std.testing.expect(!try l.add(gpa, "wörd"));
    try std.testing.expect(!try l.add(gpa, "two\nlines"));
    try std.testing.expect(l.contains("WÖRD"));
}
