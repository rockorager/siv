//! The file manager on the headless backend: listings, sorting, search,
//! selection, keyboard use, renaming, file operations, and golden images
//! of the window in light, dark, grid, and right-to-left layouts.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-files

const std = @import("std");
const harness = @import("harness.zig");

const testing = std.testing;
const Harness = harness.Harness;
const Fixture = harness.Fixture;
const ks = harness.ks;

test {
    _ = @import("files");
    _ = @import("units.zig");
}

const sample = [_]Fixture.Item{
    .{ .name = "Documents", .dir = true },
    .{ .name = "Pictures", .dir = true },
    .{ .name = "notes.txt", .size = 1_234 },
    .{ .name = "report-10.pdf", .size = 2_400_000, .mtime = 1_791_000_000 },
    .{ .name = "report-9.pdf", .size = 1_100_000, .mtime = 1_790_000_000 },
    .{ .name = "build.zig", .size = 18_000 },
    .{ .name = "photo.png", .size = 52_000 },
    .{ .name = "song.flac", .size = 31_000_000 },
    .{ .name = "archive.tar.gz", .size = 640_000 },
    .{ .name = ".hidden", .size = 10 },
};

fn names(h: *Harness, out: [][]const u8) usize {
    const f = h.f();
    var n: usize = 0;
    for (f.visible.items) |e| {
        if (n == out.len) break;
        out[n] = f.listing.?.name(f.listing.?.entries[e]);
        n += 1;
    }
    return n;
}

test "lists a folder, folders first in natural order, hidden files hidden" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    var buf: [16][]const u8 = undefined;
    const got = buf[0..names(&h, &buf)];
    const want = [_][]const u8{ "Documents", "Pictures", "archive.tar.gz", "build.zig", "notes.txt", "photo.png", "report-9.pdf", "report-10.pdf", "song.flac" };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| try testing.expectEqualStrings(a, b);
    try h.expectGolden("list-light");
}

fn expectNames(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("want {d} names, got {d}:", .{ want.len, got.len });
        for (got) |g| std.debug.print(" {s}", .{g});
        std.debug.print("\n", .{});
        return error.TestExpectedEqual;
    }
    for (want, got) |a, b| try testing.expectEqualStrings(a, b);
}

test "a column header sorts, then reverses, keeping the selection" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    var buf: [16][]const u8 = undefined;
    try h.clickItem("notes.txt");
    try h.clickOn(.column_header, "Size");
    try expectNames(&.{ "Documents", "Pictures", "notes.txt", "build.zig", "photo.png", "archive.tar.gz", "report-9.pdf", "report-10.pdf", "song.flac" }, h.shown(&buf));
    try h.clickOn(.column_header, "Size");
    try expectNames(&.{ "Pictures", "Documents", "song.flac", "report-10.pdf", "report-9.pdf", "archive.tar.gz", "photo.png", "build.zig", "notes.txt" }, h.shown(&buf));
    try expectNames(&.{"notes.txt"}, try h.selected(&buf));
    const tree = try h.semantics();
    try testing.expectEqual(.descending, tree.find(.column_header, "Size").?.sort);
}

test "typing in the view searches the folder; Escape clears the search" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    var buf: [16][]const u8 = undefined;
    try h.clickItem("notes.txt");
    try h.typeText("rep");
    try expectNames(&.{ "report-9.pdf", "report-10.pdf" }, h.shown(&buf));
    try testing.expectEqualStrings("Search", try h.focusedName());
    try h.typeText("ort-1");
    try expectNames(&.{"report-10.pdf"}, h.shown(&buf));
    try h.key(ks.escape, "", .{});
    try testing.expectEqual(@as(usize, 9), h.shown(&buf).len);
    try testing.expectEqualStrings("", h.f().query.items);
}

test "keyboard: arrows move, Enter opens a folder, Backspace returns and selects it" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    try fx.add(.{ .name = "Pictures/cat.png", .size = 10 });
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    var buf: [16][]const u8 = undefined;
    try h.clickItem("Documents");
    try h.key(ks.down, "", .{});
    try expectNames(&.{"Pictures"}, try h.selected(&buf));
    try h.key(ks.@"return", "", .{});
    try expectNames(&.{"cat.png"}, h.shown(&buf));
    try testing.expect(std.mem.endsWith(u8, h.f().path, "/Pictures"));
    try h.key(ks.backspace, "", .{});
    try testing.expectEqualStrings(fx.path, h.f().path);
    try expectNames(&.{"Pictures"}, try h.selected(&buf));
    // Alt+Left and Alt+Right walk the history.
    try h.key(ks.left, "", .{ .alt = true });
    try testing.expect(std.mem.endsWith(u8, h.f().path, "/Pictures"));
    try h.key(ks.right, "", .{ .alt = true });
    try testing.expectEqualStrings(fx.path, h.f().path);
}

test "F2 renames in place; Enter applies, Escape cancels" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    var buf: [16][]const u8 = undefined;
    try h.clickItem("notes.txt");
    try h.key(0xffbf, "", .{}); // F2
    try testing.expectEqualStrings("New name", try h.focusedName());
    try h.expectGolden("rename");
    // The stem is selected: typing replaces it, keeping ".txt". Space and
    // arrows are the editor's, not the list's.
    try h.typeText("my");
    try h.key(ks.space, " ", .{});
    try h.typeText("list");
    try h.key(ks.@"return", "", .{});
    try testing.expect(fx.exists("my list.txt"));
    try testing.expect(!fx.exists("notes.txt"));
    try expectNames(&.{"my list.txt"}, try h.selected(&buf));
    try h.key(0xffbf, "", .{});
    try h.typeText("zzz");
    try h.key(ks.escape, "", .{});
    try testing.expect(fx.exists("my list.txt"));
}

test "new folder, then into the trash with Delete" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    var buf: [16][]const u8 = undefined;
    try h.clickItem("notes.txt");
    try h.key('N', "N", .{ .ctrl = true, .shift = true });
    try testing.expect(fx.exists("New Folder"));
    // It is selected and being renamed.
    try testing.expectEqualStrings("New name", try h.focusedName());
    try h.typeText("Inbox");
    try h.key(ks.@"return", "", .{});
    try testing.expect(fx.exists("Inbox"));
    try expectNames(&.{"Inbox"}, try h.selected(&buf));
    try h.key(ks.delete, "", .{});
    try testing.expect(!fx.exists("Inbox"));
    try testing.expect(fx.exists("Trash/files/Inbox"));
    try testing.expect(fx.exists("Trash/info/Inbox.trashinfo"));
}

test "Shift+Delete asks before deleting for good" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    try h.clickItem("song.flac");
    try h.key(ks.delete, "", .{ .shift = true });
    const tree = try h.semantics();
    try testing.expect(tree.find(.dialog, "Permanently delete “song.flac”?") != null);
    try h.expectGolden("delete-dialog");
    // Escape keeps it.
    try h.key(ks.escape, "", .{});
    try testing.expect(fx.exists("song.flac"));
    try h.key(ks.delete, "", .{ .shift = true });
    try h.clickOn(.button, "Delete");
    try testing.expect(!fx.exists("song.flac"));
}
