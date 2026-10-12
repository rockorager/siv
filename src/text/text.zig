//! Text engine (D13, D14, D15): font discovery and fallback, shaping, bidi,
//! line breaking, and paragraph layout.
//!
//! Imports: raster, harfbuzz, sheenbidi, fontconfig, uucode. Unicode test
//! data is available through @embedFile, e.g. @embedFile("LineBreakTest.txt");
//! see build.zig for the list.

const std = @import("std");
const hb = @import("harfbuzz");
const sb = @import("sheenbidi");
const fc = @import("fontconfig");
const uucode = @import("uucode");

test {
    std.testing.refAllDecls(@This());
}

test "C dependencies link" {
    try std.testing.expect(hb.hb_version_atleast(1, 0, 0) != 0);
    try std.testing.expect(fc.FcGetVersion() > 0);

    // A single right-to-left code point resolves to an odd embedding level.
    const hebrew_alef = [_]u32{0x05D0};
    const seq: sb.SBCodepointSequence = .{
        .stringEncoding = sb.SBStringEncodingUTF32,
        .stringBuffer = @ptrCast(&hebrew_alef),
        .stringLength = hebrew_alef.len,
    };
    const algorithm = sb.SBAlgorithmCreate(&seq) orelse return error.OutOfMemory;
    defer sb.SBAlgorithmRelease(algorithm);
    const paragraph = sb.SBAlgorithmCreateParagraph(algorithm, 0, hebrew_alef.len, sb.SBLevelDefaultLTR) orelse return error.OutOfMemory;
    defer sb.SBParagraphRelease(paragraph);
    try std.testing.expectEqual(1, sb.SBParagraphGetBaseLevel(paragraph));

    try std.testing.expectEqual(.letter_uppercase, uucode.get(.general_category, 'A'));
}

test "Unicode conformance data is embedded" {
    try std.testing.expect(std.mem.startsWith(u8, @embedFile("LineBreakTest.txt"), "# LineBreakTest-18.0.0.txt"));
}
