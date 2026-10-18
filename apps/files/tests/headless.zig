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
    // The window reported its frames: the first, then one with the rows
    // (the same one when the listing arrives while the first frame waits
    // for its icons, D19).
    const f = h.f();
    try testing.expect(f.frames >= 1);
    try testing.expect(f.first_frame_ns != 0 and f.rows_frame_ns >= f.first_frame_ns);
    // The window's actions (D34): Ctrl+H flips Show Hidden Files, Ctrl+2
    // and Ctrl+1 choose the view.
    try h.key('h', "h", .{ .ctrl = true });
    try testing.expectEqual(want.len + 1, names(&h, &buf));
    try h.key('2', "2", .{ .ctrl = true });
    try testing.expectEqual(.grid, f.mode);
    try h.key('1', "1", .{ .ctrl = true });
    try testing.expectEqual(.list, f.mode);
    try h.key('h', "h", .{ .ctrl = true });
    try testing.expectEqual(want.len, names(&h, &buf));
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

test "the window's size, the view's mode, and hidden files are kept in a state store" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    const c = harness.t.c;
    var h: Harness = .{};
    try h.start(.{ .path = fx.path, .width = 700, .height = 500, .state = true });
    defer h.stop();
    var i: i64 = 0;
    try harness.ok(c.siv_settings_get_int(h.state, "window.width", 12, 0, &i));
    try testing.expectEqual(@as(i64, 700), i);
    h.f().setMode(.grid);
    h.f().setShowHidden(true);
    try h.settle();
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    try harness.ok(c.siv_settings_get_string(h.state, "view.mode", 9, "list", 4, &buf, buf.len, &len));
    try testing.expectEqualStrings("grid", buf[0..len]);
    var hidden = false;
    try harness.ok(c.siv_settings_get_bool(h.state, "view.show-hidden", 16, false, &hidden));
    try testing.expect(hidden);
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

test "copy and paste files: within the app, to other apps, and from them" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    var buf: [16][]const u8 = undefined;
    // Select two files and copy them.
    try h.clickItem("build.zig");
    try h.clickItemWith("notes.txt", 0x110, .{ .ctrl = true });
    try h.key('c', "c", .{ .ctrl = true });
    // Other applications get the URIs, GNOME's copy marker, and paths.
    var out: [1024]u8 = undefined;
    const want_uris = try std.fmt.bufPrint(&out, "file://{s}/build.zig\r\nfile://{s}/notes.txt\r\n", .{ fx.path, fx.path });
    var got_buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(want_uris, try h.pasteElsewhere("text/uri-list", &got_buf));
    try testing.expect(std.mem.startsWith(u8, try h.pasteElsewhere("x-special/gnome-copied-files", &got_buf), "copy\nfile://"));
    // Paste into Documents.
    try h.clickItem("Documents");
    try h.key(ks.@"return", "", .{});
    try h.key('v', "v", .{ .ctrl = true });
    try testing.expect(fx.exists("Documents/build.zig"));
    try testing.expect(fx.exists("Documents/notes.txt"));
    try testing.expect(fx.exists("build.zig"));
    // The pasted files are selected.
    try expectNames(&.{ "build.zig", "notes.txt" }, try h.selected(&buf));
    // Pasting again names the copies apart. The copy runs on a worker,
    // which a loaded machine can start after the harness has settled.
    try h.key('v', "v", .{ .ctrl = true });
    const deadline = @import("loop").Loop.now() + 10 * std.time.ns_per_s;
    while (!fx.exists("Documents/build (2).zig")) {
        if (@import("loop").Loop.now() > deadline) return error.Timeout;
        try h.settle();
    }
    // Cut moves.
    try h.clickItem("notes.txt");
    try h.key('x', "x", .{ .ctrl = true });
    try h.key(ks.backspace, "", .{});
    try h.clickItem("Pictures");
    try h.key(ks.@"return", "", .{});
    try h.key('v', "v", .{ .ctrl = true });
    try testing.expect(fx.exists("Pictures/notes.txt"));
    try testing.expect(!fx.exists("Documents/notes.txt"));
    // Files another application copied.
    var ubuf: [512]u8 = undefined;
    const theirs = try std.fmt.bufPrint(&ubuf, "file://{s}/song.flac\r\n", .{fx.path});
    try h.copyElsewhere(&.{ "text/plain", "text/uri-list" }, theirs);
    try h.key('v', "v", .{ .ctrl = true });
    try testing.expect(fx.exists("Pictures/song.flac"));
    try testing.expect(fx.exists("song.flac"));
}

test "drag and drop: files from other apps, onto folders, and out to other apps" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    try fx.add(.{ .name = "Documents/letter.odt", .size = 300 });
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    // Another application drops a file on empty space: it is copied here.
    var ubuf: [512]u8 = undefined;
    const letter = try std.fmt.bufPrint(&ubuf, "file://{s}/Documents/letter.odt\r\n", .{fx.path});
    try h.dropFromElsewhere(&.{"text/uri-list"}, letter, .{ .copy = true }, 600, 450);
    try testing.expect(fx.exists("letter.odt"));
    try testing.expect(fx.exists("Documents/letter.odt"));
    // Dropped on a folder's row, with move, it moves into the folder.
    const pb = (try h.item("Pictures")).bounds;
    const p = [2]f64{ (pb.x0 + pb.x1) / 2, (pb.y0 + pb.y1) / 2 };
    const song = try std.fmt.bufPrint(&ubuf, "file://{s}/song.flac\r\n", .{fx.path});
    try h.dropFromElsewhere(&.{"text/uri-list"}, song, .{ .move = true }, p[0], p[1]);
    try testing.expect(fx.exists("Pictures/song.flac"));
    try testing.expect(!fx.exists("song.flac"));
    // Dragging an item out offers its URI.
    var out: [512]u8 = undefined;
    const got = try h.dragOut("photo.png", "text/uri-list", &out);
    var wbuf: [512]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&wbuf, "file://{s}/photo.png\r\n", .{fx.path}), got);
    // Two selected: the status line totals them as the selection changes,
    // and a press on one of them keeps both, so the drag carries both.
    try h.clickItem("photo.png");
    try h.clickItemWith("notes.txt", 0x110, .{ .ctrl = true });
    var sbuf: [128]u8 = undefined;
    try testing.expectEqualStrings("2 of 9 items selected (53.2 kB)", h.status(&sbuf));
    const both = try h.dragOut("photo.png", "text/uri-list", &out);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&wbuf, "file://{s}/notes.txt\r\nfile://{s}/photo.png\r\n", .{ fx.path, fx.path }), both);
    // Without a drag, the release selects only the item pressed.
    try h.clickItem("notes.txt");
    try testing.expectEqualStrings("“notes.txt” selected (1.2 kB)", h.status(&sbuf));
}

fn writePng(fx: *Fixture, name: []const u8, w: u32, h: u32, rgb: [3]u8) !void {
    const gpa = testing.allocator;
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(px);
    for (0..h) |y| for (0..w) |x| {
        // A diagonal band so that orientation and scaling show.
        const band = (x + y) % 16 < 8;
        const p = px[(y * w + x) * 4 ..][0..4];
        p.* = if (band) .{ rgb[0], rgb[1], rgb[2], 255 } else .{ rgb[0] / 2, rgb[1] / 2, rgb[2] / 2, 255 };
    };
    const bytes = try @import("png").encode(gpa, w, h, px);
    defer gpa.free(bytes);
    var pbuf: [512]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pbuf, "{s}/{s}", .{ fx.path, name }, 0);
    const linux = std.os.linux;
    const fd: i32 = @intCast(linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644));
    defer _ = linux.close(fd);
    _ = linux.write(fd, bytes.ptr, bytes.len);
    const ts = [2]linux.timespec{ .{ .sec = 1_791_900_300, .nsec = 0 }, .{ .sec = 1_791_900_300, .nsec = 0 } };
    _ = linux.utimensat(linux.AT.FDCWD, path, &ts, 0);
}

test "changes made elsewhere show up: the folder is watched in siv's loop" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path, .watch = true });
    defer h.stop();
    try fx.add(.{ .name = "new-from-elsewhere.txt", .size = 5 });
    try h.until(3000, struct {
        fn f(hh: *Harness) bool {
            if (hh.f().listing == null) return false;
            var buf: [16][]const u8 = undefined;
            for (buf[0..names(hh, &buf)]) |n| if (std.mem.eql(u8, n, "new-from-elsewhere.txt")) return true;
            return false;
        }
    }.f);
    var sbuf: [128]u8 = undefined;
    try testing.expectEqualStrings("10 items", h.status(&sbuf));
}

test "grid view with thumbnails decoded on the worker pool" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    try writePng(&fx, "photo.png", 320, 200, .{ 220, 120, 40 });
    try writePng(&fx, "tall.png", 90, 240, .{ 40, 140, 220 });
    // Two lines at most under a cell, the second ending in an ellipsis.
    try fx.add(.{ .name = "minutes of the annual general meeting.txt", .size = 900 });
    var h: Harness = .{};
    try h.start(.{ .path = fx.path, .mode = .grid, .thumbnails = true });
    defer h.stop();
    try testing.expectEqual(@as(u32, 2), h.f().thumbs.loaded);
    try h.expectGolden("grid-light");
    // Grid cells are list items named by the file.
    try h.clickItem("tall.png");
    var buf: [4][]const u8 = undefined;
    try expectNames(&.{"tall.png"}, try h.selected(&buf));
}

test "thumbnail requests past the limit cancel the oldest" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path, .mode = .grid, .thumbnails = true });
    defer h.stop();
    const t = &h.f().thumbs;
    const before = t.loaded;
    // Asked for faster than they decode: 300 cells scrolled past.
    var buf: [32]u8 = undefined;
    for (0..300) |i| {
        const name = try std.fmt.bufPrint(&buf, "img-{d}.png", .{i});
        try testing.expect(t.get(fx.path, name, 1) == null);
    }
    try testing.expectEqual(@as(u32, 256), t.pending);
    try h.settle();
    // The 44 asked for first were cancelled, never decoded.
    try testing.expectEqual(before + 256, t.loaded);
    try testing.expectEqual(@as(u32, 0), t.pending);
}

test "dark style, and the context menu" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    // A name too long for its column ends in an ellipsis.
    try fx.add(.{ .name = "Quarterly report for the board meeting, final version (2).pdf", .size = 1_500_000 });
    var h: Harness = .{};
    try h.start(.{ .path = fx.path, .scheme = .dark });
    defer h.stop();
    try h.clickItem("report-10.pdf");
    try h.expectGolden("list-dark");
    try h.clickItemWith("report-10.pdf", 0x111, .{});
    var ps: [4]@import("abi").types.Window = undefined;
    try testing.expectEqual(@as(usize, 1), try h.popups(&ps));
    // It opened at the click, the middle of the row.
    const b = (try h.item("report-10.pdf")).bounds;
    const at = try h.popupAt(ps[0]);
    try testing.expectApproxEqAbs((b.x0 + b.x1) / 2, @as(f32, @floatFromInt(at[0])), 1.5);
    try testing.expectApproxEqAbs((b.y0 + b.y1) / 2, @as(f32, @floatFromInt(at[1])), 1.5);
    try h.expectGoldenOf(ps[0], "context-menu");
    // Choosing Rename from the keyboard starts renaming.
    try h.keyIn(ps[0], ks.down, "", .{});
    try h.keyIn(ps[0], 'r', "r", .{});
    try testing.expectEqual(@as(usize, 0), try h.popups(&ps));
    try testing.expectEqualStrings("New name", try h.focusedName());
}

test "right to left" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    try fx.add(.{ .name = "מסמכים", .dir = true });
    try fx.add(.{ .name = "تقرير.txt", .size = 4096 });
    var h: Harness = .{};
    try h.start(.{ .path = fx.path, .rtl = true });
    defer h.stop();
    try h.clickItem("build.zig");
    try h.expectGolden("list-rtl");
}

test "a narrow window leaves out the places, and a wider one brings them back" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path, .width = 480 });
    defer h.stop();
    try testing.expect((try h.semantics()).find(.list, "Places") == null);
    try h.expectGolden("narrow");
    try harness.ok(@import("abi").testing.siv_test_resize(h.window(), 900, 560));
    try h.settle();
    _ = try h.center(.list, "Places");
}

test "file operations: copy trees, name clashes, moves, the trash, deletion, cancelling" {
    const fsops = harness.Files.fsops;
    const gpa = std.heap.c_allocator;
    var fx: Fixture = .{};
    try fx.create(&.{
        .{ .name = "src", .dir = true },
        .{ .name = "src/a.txt", .size = 3000 },
        .{ .name = "src/deep", .dir = true },
        .{ .name = "src/deep/b.bin", .size = 70_000 },
        .{ .name = "dest", .dir = true },
        .{ .name = "dest/src", .dir = true },
    });
    defer fx.remove();
    var sbuf: [256]u8 = undefined;
    var tbuf: [256]u8 = undefined;
    var pbuf: [256]u8 = undefined;
    var dbuf: [256]u8 = undefined;
    const src = try std.fmt.bufPrint(&sbuf, "{s}/src", .{fx.path});
    const dest = try std.fmt.bufPrint(&tbuf, "{s}/dest", .{fx.path});

    // A copy into a folder that has the name already gets " (2)", with
    // progress counted in bytes and items.
    var op = try fsops.Op.create(gpa, .copy, &.{src}, dest);
    op.run();
    try testing.expect(op.result == null);
    try testing.expect(fx.exists("dest/src (2)/deep/b.bin"));
    try testing.expectEqual(@as(u64, 73_000), op.total_bytes.load(.monotonic));
    try testing.expectEqual(op.total_bytes.load(.monotonic), op.done_bytes.load(.monotonic));
    try testing.expectEqual(@as(u32, 4), op.done_items.load(.monotonic));
    try testing.expectEqualStrings("src (2)\n", op.created.items);
    op.destroy();

    // Not into itself.
    op = try fsops.Op.create(gpa, .copy, &.{src}, try std.fmt.bufPrint(&dbuf, "{s}/src/deep", .{fx.path}));
    op.run();
    try testing.expectEqual(fsops.Error.IntoItself, op.result.?);
    op.destroy();

    // Cancelled before it starts: nothing is copied.
    op = try fsops.Op.create(gpa, .copy, &.{src}, dest);
    op.cancel.store(true, .release);
    op.run();
    try testing.expectEqual(fsops.Error.Canceled, op.result.?);
    try testing.expect(!fx.exists("dest/src (3)"));
    op.destroy();

    // Move, then to the trash with its info file, then delete for good.
    op = try fsops.Op.create(gpa, .move, &.{try std.fmt.bufPrint(&pbuf, "{s}/src/a.txt", .{fx.path})}, try std.fmt.bufPrint(&dbuf, "{s}/dest", .{fx.path}));
    op.run();
    try testing.expect(op.result == null);
    try testing.expect(fx.exists("dest/a.txt") and !fx.exists("src/a.txt"));
    op.destroy();
    op = try fsops.Op.create(gpa, .trash, &.{try std.fmt.bufPrint(&pbuf, "{s}/dest/a.txt", .{fx.path})}, "");
    op.trash_dir = try std.fmt.allocPrint(gpa, "{s}/Trash", .{fx.path});
    op.run();
    try testing.expect(op.result == null);
    try testing.expect(fx.exists("Trash/files/a.txt") and fx.exists("Trash/info/a.txt.trashinfo"));
    op.destroy();
    op = try fsops.Op.create(gpa, .delete, &.{src}, "");
    op.run();
    try testing.expect(op.result == null);
    try testing.expect(!fx.exists("src"));
    op.destroy();

    // Names are checked before renaming and creating.
    try testing.expectError(error.InvalidName, fsops.rename(fx.path, "dest", "a/b"));
    try testing.expectError(error.Exists, fsops.makeDir(fx.path, "dest"));
}

test "opening a file asks the desktop's portal; without one the app says so" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    try h.clickItem("notes.txt");
    try h.key(ks.@"return", "", .{});
    const tree = try h.semantics();
    var found = false;
    for (tree.nodes.items) |n| {
        if (std.mem.indexOf(u8, tree.name(n), "No application could be asked") != null) found = true;
    }
    try testing.expect(found);
}

test "the operations bar shows progress, and Cancel asks the operation to stop" {
    var fx: Fixture = .{};
    try fx.create(&sample);
    defer fx.remove();
    var h: Harness = .{};
    try h.start(.{ .path = fx.path });
    defer h.stop();
    const f = h.f();
    // An operation as the worker reports it halfway, not running, so the
    // capture does not race it.
    const op = try harness.Files.fsops.Op.create(std.heap.c_allocator, .copy, &.{"/x/a"}, "/x/b");
    defer op.destroy();
    op.scanning.store(false, .release);
    op.total_items.store(40, .release);
    op.done_items.store(17, .release);
    op.total_bytes.store(800_000_000, .release);
    op.done_bytes.store(340_000_000, .release);
    try f.ops.append(f.gpa, op);
    h.ignore_ops = true;
    f.updateOps();
    try h.settle();
    try h.expectGolden("operations");
    const tree = try h.semantics();
    const bar = tree.find(.progress_bar, "Progress").?;
    try testing.expectApproxEqAbs(@as(f64, 42.5), bar.value.?.now, 0.01);
    try h.clickOn(.button, "Cancel");
    try testing.expect(op.cancel.load(.acquire));
    _ = f.ops.pop();
    f.updateOps();
    try h.settle();
}
