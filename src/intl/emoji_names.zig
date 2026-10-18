//! Names shared by the generator (gen.zig, on the build host) and the
//! emoji catalogue (emoji.zig): UTS #51's groups and CLDR's skin tones.

const std = @import("std");

/// emoji-test.txt's groups in order, without Component.
pub const groups = [_][]const u8{ "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink", "Travel & Places", "Activities", "Objects", "Symbols", "Flags" };

/// The five Fitzpatrick modifiers, U+1F3FB to U+1F3FF, as CLDR names them.
pub const tones = [_][]const u8{ "light skin tone", "medium-light skin tone", "medium skin tone", "medium-dark skin tone", "dark skin tone" };

/// A toned variant's name from its base's, as CLDR forms them: "thumbs
/// up: medium skin tone", "woman: light skin tone, blond hair". The
/// generator checks every variant against it, so the catalogue keeps
/// base names only.
pub fn toned(buf: []u8, base: []const u8, tone: u8) []const u8 {
    if (std.mem.indexOf(u8, base, ": ")) |i|
        return std.fmt.bufPrint(buf, "{s}: {s}, {s}", .{ base[0..i], tones[tone], base[i + 2 ..] }) catch base;
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ base, tones[tone] }) catch base;
}
