//! Lookup against siv's test themes in test/icons/themes (run from the
//! repository root): SivColor inherits SivTest, which inherits hicolor.

const std = @import("std");
const icon = @import("icon.zig");

const testing = std.testing;
const root = "test/icons/themes";

fn themes() !icon.Themes {
    // Only the test themes: no home, and data directories without icons.
    var t = try icon.Themes.init(testing.allocator, .{ .xdg_data_dirs = "/nonexistent" });
    try t.addSearchPath(root);
    return t;
}

fn expectFound(t: *icon.Themes, theme: []const u8, name: []const u8, size: u32, scale: u32, options: icon.Options, want: ?[]const u8) !void {
    const found = try t.lookup(theme, &.{name}, size, scale, options);
    defer if (found) |f| testing.allocator.free(f.path);
    if (want) |w| {
        const f = found orelse {
            std.debug.print("{s} at {d}@{d}: not found, expected {s}\n", .{ name, size, scale, w });
            return error.TestExpectedEqual;
        };
        try testing.expectEqualStrings(w, f.path[root.len + 1 ..]);
    } else try testing.expect(found == null);
}

test "exact sizes, scales, and the closest directory" {
    var t = try themes();
    defer t.deinit();
    // A fixed 16 px directory, its scale-2 variant, and a 24 px SVG.
    try expectFound(&t, "SivTest", "document-new", 16, 1, .{}, "SivTest/16x16/actions/document-new.png");
    try expectFound(&t, "SivTest", "document-new", 16, 2, .{}, "SivTest/16x16@2/actions/document-new.png");
    try expectFound(&t, "SivTest", "document-new", 24, 1, .{}, "SivTest/24x24/actions/document-new.svg");
    // 20 px matches none: 16 is 4 away, 24 is 4 away; the first in
    // directory order wins ties.
    try expectFound(&t, "SivTest", "document-new", 20, 1, .{}, "SivTest/16x16/actions/document-new.png");
    // 32 px at scale 1 is closest to the scale-2 16 px directory (32 px).
    try expectFound(&t, "SivTest", "document-new", 32, 1, .{}, "SivTest/16x16@2/actions/document-new.png");
    const f = (try t.lookup("SivTest", &.{"document-new"}, 24, 1, .{})).?;
    defer testing.allocator.free(f.path);
    try testing.expectEqual(icon.Format.svg, f.format);
    try testing.expectEqual(@as(u32, 24), f.size);
}

test "inheritance, hicolor, fallbacks, and RTL variants" {
    var t = try themes();
    defer t.deinit();
    // SivColor has its own edit-copy; edit-copy-symbolic comes from SivTest.
    try expectFound(&t, "SivColor", "edit-copy", 16, 1, .{}, "SivColor/actions/16/edit-copy.svg");
    try expectFound(&t, "SivColor", "edit-copy-symbolic", 16, 1, .{}, "SivTest/scalable/actions/edit-copy-symbolic.svg");
    // hicolor last, even when no theme inherits it: SivColor inherits
    // SivTest, which names it; an unknown theme falls back to it too.
    try expectFound(&t, "SivColor", "siv-test-app", 48, 1, .{}, "hicolor/48x48/apps/siv-test-app.png");
    try expectFound(&t, "NoSuchTheme", "siv-test-app", 128, 1, .{}, "hicolor/scalable/apps/siv-test-app.svg");
    // Generic fallbacks shorten at dashes, keeping -symbolic.
    try expectFound(&t, "SivTest", "folder-music", 64, 1, .{}, "SivTest/scalable/places/folder.svg");
    try expectFound(&t, "SivTest", "folder-music", 64, 1, .{ .generic_fallbacks = false }, null);
    try expectFound(&t, "SivTest", "edit-copy-all-symbolic", 16, 1, .{}, "SivTest/scalable/actions/edit-copy-symbolic.svg");
    // A theme's own icon beats a more specific name in a parent: the
    // theme is searched with every fallback before its parents.
    try expectFound(&t, "SivColor", "folder-documents", 64, 1, .{}, "SivColor/places/64/folder.svg");
    try expectFound(&t, "SivTest", "folder-documents", 64, 1, .{}, "SivTest/scalable/places/folder-documents.svg");
    // RTL prefers the mirrored variant.
    try expectFound(&t, "SivTest", "go-next-symbolic", 16, 1, .{ .rtl = true }, "SivTest/scalable/actions/go-next-rtl-symbolic.svg");
    try expectFound(&t, "SivTest", "go-next-symbolic", 16, 1, .{}, "SivTest/scalable/actions/go-next-symbolic.svg");
    // Several names: the first any theme of the chain has.
    const f = (try t.lookup("SivTest", &.{ "no-such-icon", "emblem-ok-symbolic" }, 16, 1, .{ .generic_fallbacks = false })).?;
    defer testing.allocator.free(f.path);
    try testing.expect(std.mem.endsWith(u8, f.path, "emblem-ok-symbolic.svg"));
    try expectFound(&t, "SivTest", "no-such-icon", 16, 1, .{}, null);
    try expectFound(&t, "SivTest", "../SivTest/index", 16, 1, .{}, null);
    try testing.expect(try t.has("SivColor"));
    try testing.expect(!try t.has("NoSuchTheme"));
}

test "unthemed icons in base directories" {
    var t = try icon.Themes.init(testing.allocator, .{ .xdg_data_dirs = "/nonexistent" });
    defer t.deinit();
    try t.addSearchPath(root ++ "/hicolor/48x48/apps");
    try expectFound(&t, "hicolor", "siv-test-app", 48, 1, .{}, "hicolor/48x48/apps/siv-test-app.png");
}
