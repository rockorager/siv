//! The application's language and direction (D21): by default the process
//! locale's, as gettext reads it, and the direction its language is
//! written in.

const std = @import("std");

/// The BCP 47 tag of the process locale ($LC_ALL, $LC_MESSAGES, $LANG):
/// "ar_EG.UTF-8@x" is "ar-EG"; "" for C and POSIX.
pub fn processLanguage(buf: []u8) []const u8 {
    for ([_][*:0]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
        const v = std.mem.span(std.c.getenv(name) orelse continue);
        if (v.len == 0) continue;
        return tag(buf, v);
    }
    return "";
}

fn tag(buf: []u8, locale: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, locale, ".@") orelse locale.len;
    const base = locale[0..end];
    if (std.mem.eql(u8, base, "C") or std.mem.eql(u8, base, "POSIX") or base.len > buf.len) return "";
    for (base, buf[0..base.len]) |c, *o| o.* = if (c == '_') '-' else c;
    return buf[0..base.len];
}

/// Whether text in a language is written right to left: by its script
/// subtag if it has one, else by the languages whose usual script is.
pub fn isRtl(language: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, language, "-_");
    const lang = it.next() orelse return false;
    while (it.next()) |sub| if (sub.len == 4) {
        for ([_][]const u8{ "Arab", "Hebr", "Thaa", "Syrc", "Nkoo", "Adlm", "Rohg", "Mand", "Samr" }) |s| {
            if (std.ascii.eqlIgnoreCase(sub, s)) return true;
        }
        return false;
    };
    for ([_][]const u8{ "ar", "arc", "ckb", "dv", "fa", "he", "iw", "ks", "lrc", "mzn", "nqo", "pnb", "ps", "sd", "syr", "ug", "ur", "yi" }) |l| {
        if (std.ascii.eqlIgnoreCase(lang, l)) return true;
    }
    return false;
}

test "locale languages and their direction" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ar-EG", tag(&buf, "ar_EG.UTF-8@x"));
    try std.testing.expectEqualStrings("", tag(&buf, "C.UTF-8"));
    try std.testing.expectEqualStrings("he", tag(&buf, "he"));
    try std.testing.expect(isRtl("ar-EG"));
    try std.testing.expect(isRtl("he"));
    try std.testing.expect(!isRtl("en-US"));
    try std.testing.expect(!isRtl(""));
    // The script decides: Azerbaijani in Arabic script, Uyghur in Latin.
    try std.testing.expect(isRtl("az-Arab-IR"));
    try std.testing.expect(!isRtl("ug-Latn"));
}
