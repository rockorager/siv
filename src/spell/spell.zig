//! Spell checking (D37): siv's own reader of Hunspell-format
//! dictionaries, the system's dictionaries and Enchant's personal word
//! lists found and read, and which words of a text are checked.
//!
//!     var d = try spell.Dictionary.parse(gpa, aff_bytes, dic_bytes);
//!     defer d.deinit();
//!     if (!d.check("wrod")) {
//!         const suggestions = try d.suggest(gpa, "wrod"); // "word", ...
//!     }
//!
//! Word boundaries are the text engine's (D13); the UI segments text and
//! asks `checkable` which segments to check. Everything here is plain
//! data and blocking file I/O: `src/ui` runs it on the worker pool.
//!
//! Imports: uucode.

const std = @import("std");

pub const Dictionary = @import("Dictionary.zig");
pub const WordList = @import("WordList.zig");
pub const case = @import("case.zig");
pub const encoding = @import("encoding.zig");
pub const files = @import("files.zig");

/// A dictionary written for tests (english-like, with affixes, REP,
/// KEY, TRY, ICONV, NOSUGGEST, FORBIDDENWORD, and KEEPCASE), so that
/// tests depend on no installed dictionary.
pub const test_dictionary = struct {
    pub const aff = @embedFile("testdata/en_TEST.aff");
    pub const dic = @embedFile("testdata/en_TEST.dic");
};

pub const LoadError = Dictionary.Error || files.ReadError || error{NotFound};

/// Reads and parses dictionary `name` from the first of `dirs` that has
/// it. Blocks: run it on a worker.
pub fn load(gpa: std.mem.Allocator, dirs: []const []const u8, name: []const u8) LoadError!Dictionary {
    const dir = files.findDictionary(dirs, name) orelse return error.NotFound;
    var buf: [4096]u8 = undefined;
    const aff_path = std.fmt.bufPrint(&buf, "{s}/{s}.aff", .{ dir, name }) catch return error.NotFound;
    const aff = try files.readFile(gpa, aff_path);
    defer gpa.free(aff);
    const dic_path = std.fmt.bufPrint(&buf, "{s}/{s}.dic", .{ dir, name }) catch return error.NotFound;
    const dic = try files.readFile(gpa, dic_path);
    defer gpa.free(dic);
    return Dictionary.parse(gpa, aff, dic);
}

/// Whether the word segment `text[start..end]` (a UAX #29 word) is
/// checked: it has a letter and no digit ("mp3", "x86_64", and ordinals
/// are left alone, as LibreOffice and Chromium leave them), and it is not
/// part of a URL, an e-mail address, or a path (the run of non-space text
/// around it holds "://" or "@", starts with "www." or "/", or is "~/...").
pub fn checkable(text: []const u8, start: usize, end: usize) bool {
    var letter = false;
    var i = start;
    while (i < end) {
        const cp, const n = case.decode(text, i);
        i += n;
        if (cp < 0x80 and std.ascii.isDigit(@intCast(cp))) return false;
        if (case.isLetter(cp)) letter = true;
    }
    if (!letter) return false;
    var a = start;
    while (a > 0 and !std.ascii.isWhitespace(text[a - 1])) a -= 1;
    var b = end;
    while (b < text.len and !std.ascii.isWhitespace(text[b])) b += 1;
    const token = text[a..b];
    if (std.mem.indexOf(u8, token, "://") != null or std.mem.indexOfScalar(u8, token, '@') != null) return false;
    if (std.mem.startsWith(u8, token, "www.") or std.mem.startsWith(u8, token, "/") or std.mem.startsWith(u8, token, "~/")) return false;
    return true;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}

test "which segments are checked" {
    const t = "see mp3 at https://example.com/page or mail me@example.com, ~/notes and/or 42";
    const find = struct {
        fn f(s: []const u8, w: []const u8) bool {
            const i = std.mem.indexOf(u8, s, w).?;
            return checkable(s, i, i + w.len);
        }
    }.f;
    try std.testing.expect(find(t, "see"));
    try std.testing.expect(!find(t, "mp3"));
    try std.testing.expect(!find(t, "example.com/page"));
    try std.testing.expect(!find(t, "me"));
    try std.testing.expect(!find(t, "notes"));
    try std.testing.expect(find(t, "and"));
    try std.testing.expect(find(t, "or "[0..2]));
    try std.testing.expect(!find(t, "42"));
}
