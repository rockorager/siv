//! The trash in temporary directories: one file system, with directories
//! named as mounts of their own (`Trash.mounts`) for the topdir trashes.

const std = @import("std");
const linux = std.os.linux;
const trash = @import("trash.zig");

const testing = std.testing;
const gpa = testing.allocator;

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

const Dir = struct {
    root_buf: [64]u8 = undefined,
    root: []const u8 = "",
    home_buf: [128]u8 = undefined,
    vol_buf: [128]u8 = undefined,
    t: trash.Trash = undefined,
    mounts: [1][]const u8 = undefined,

    fn init(d: *Dir) !void {
        @memcpy(d.root_buf[0..21], "/tmp/siv-trash-XXXXXX");
        d.root_buf[21] = 0;
        d.root = std.mem.span(mkdtemp(d.root_buf[0..21 :0]) orelse return error.SkipZigTest);
        const home = try std.fmt.bufPrint(&d.home_buf, "{s}/home/.local/share/Trash", .{d.root});
        const vol = try std.fmt.bufPrint(&d.vol_buf, "{s}/vol", .{d.root});
        d.mounts = .{vol};
        d.t = .{ .home = home, .uid = linux.getuid(), .mounts = &d.mounts };
        try d.mkdir("vol");
        try d.mkdir("docs");
    }

    fn deinit(d: *Dir) void {
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(gpa);
        p.appendSlice(gpa, d.root) catch return;
        removeTree(&p);
    }

    fn removeTree(tree: *std.ArrayList(u8)) void {
        var zbuf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{tree.items}, 0) catch return;
        if (linux.errno(linux.unlinkat(linux.AT.FDCWD, z, 0)) == .SUCCESS) return;
        const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return;
        const fd: i32 = @intCast(rc);
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(gpa);
        var buf: [4096]u8 align(8) = undefined;
        while (true) {
            const n = linux.getdents64(fd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var off: usize = 0;
            while (off < n) {
                const de: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
                const nm = std.mem.span(@as([*:0]const u8, @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")])));
                off += de.reclen;
                if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
                names.appendSlice(gpa, nm) catch return;
                names.append(gpa, 0) catch return;
            }
        }
        _ = linux.close(fd);
        const len = tree.items.len;
        var it = std.mem.splitScalar(u8, names.items, 0);
        while (it.next()) |nm| {
            if (nm.len == 0) continue;
            tree.append(gpa, '/') catch return;
            tree.appendSlice(gpa, nm) catch return;
            removeTree(tree);
            tree.shrinkRetainingCapacity(len);
        }
        _ = linux.unlinkat(linux.AT.FDCWD, std.fmt.bufPrintSentinel(&zbuf, "{s}", .{tree.items}, 0) catch return, linux.AT.REMOVEDIR);
    }

    fn path(d: *const Dir, buf: []u8, rel: []const u8) [:0]u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ d.root, rel }, 0) catch unreachable;
    }

    fn mkdir(d: *const Dir, rel: []const u8) !void {
        var buf: [4096]u8 = undefined;
        if (linux.errno(linux.mkdirat(linux.AT.FDCWD, d.path(&buf, rel), 0o755)) != .SUCCESS) return error.Unexpected;
    }

    fn write(d: *const Dir, rel: []const u8, data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const rc = linux.openat(linux.AT.FDCWD, d.path(&buf, rel), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        _ = linux.write(fd, data.ptr, data.len);
    }

    fn read(d: *const Dir, rel: []const u8, buf: []u8) ![]const u8 {
        var pbuf: [4096]u8 = undefined;
        return readAbs(d.path(&pbuf, rel), buf);
    }

    fn exists(d: *const Dir, rel: []const u8) bool {
        var buf: [4096]u8 = undefined;
        return existsAbs(d.path(&buf, rel));
    }
};

fn readAbs(p: [:0]const u8, buf: []u8) ![]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.FileNotFound;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    return buf[0..n];
}

fn existsAbs(p: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{p}, 0) catch return false;
    var st: linux.Statx = undefined;
    return linux.errno(linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) == .SUCCESS;
}

fn nowSec() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

test "trashing writes an info file with the percent-encoded path and the local date, and restoring undoes it" {
    var d: Dir = .{};
    try d.init();
    defer d.deinit();
    try d.write("docs/a b%é.txt", "hello");
    var pbuf: [4096]u8 = undefined;
    const src = d.path(&pbuf, "docs/a b%é.txt");

    const before = nowSec();
    const id = try d.t.trash(gpa, src);
    defer gpa.free(id);
    try testing.expect(!d.exists("docs/a b%é.txt"));
    var ebuf: [4096]u8 = undefined;
    try testing.expectEqualStrings(d.path(&ebuf, "home/.local/share/Trash/files/a b%é.txt"), id);

    var ibuf: [4096]u8 = undefined;
    const info = try d.read("home/.local/share/Trash/info/a b%é.txt.trashinfo", &ibuf);
    var want: [4096]u8 = undefined;
    const want_path = try std.fmt.bufPrint(&want, "[Trash Info]\nPath={s}/docs/a%20b%25%C3%A9.txt\nDeletionDate=", .{d.root});
    try testing.expectStringStartsWith(info, want_path);
    var obuf: [linux.PATH_MAX]u8 = undefined;
    const parsed = trash.parseInfo(info, null, &obuf);
    try testing.expectEqualStrings(src, parsed.path);
    // The date is local time, to the second.
    try testing.expect(parsed.deleted >= before and parsed.deleted <= nowSec());

    const back = try d.t.restore(gpa, id, null);
    defer gpa.free(back);
    try testing.expectEqualStrings(src, back);
    var cbuf: [16]u8 = undefined;
    try testing.expectEqualStrings("hello", try d.read("docs/a b%é.txt", &cbuf));
    try testing.expect(!d.exists("home/.local/share/Trash/info/a b%é.txt.trashinfo"));
    try testing.expect(!d.exists("home/.local/share/Trash/files/a b%é.txt"));
}

test "names stay unique: a second file of the same name, and a file without an info file, take the next" {
    var d: Dir = .{};
    try d.init();
    defer d.deinit();
    try d.mkdir("other");
    try d.write("docs/n.txt", "1");
    try d.write("other/n.txt", "2");
    try d.write("vol/n.txt", "3");
    var pbuf: [4096]u8 = undefined;
    const a = try d.t.trash(gpa, d.path(&pbuf, "docs/n.txt"));
    defer gpa.free(a);
    // An orphan in files/ holds "n.txt.2".
    try d.write("home/.local/share/Trash/files/n.txt.2", "orphan");
    const b = try d.t.trash(gpa, d.path(&pbuf, "other/n.txt"));
    defer gpa.free(b);
    try testing.expectStringEndsWith(a, "/files/n.txt");
    try testing.expectStringEndsWith(b, "/files/n.txt.3");
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("orphan", try d.read("home/.local/share/Trash/files/n.txt.2", &buf));
    try testing.expect(!d.exists("home/.local/share/Trash/info/n.txt.2.trashinfo"));

    // Each restores to its own place.
    gpa.free(try d.t.restore(gpa, b, null));
    try testing.expectEqualStrings("2", try d.read("other/n.txt", &buf));
    try testing.expect(!d.exists("docs/n.txt"));
}

test "restoring refuses to replace, recreates missing folders, and can go elsewhere" {
    var d: Dir = .{};
    try d.init();
    defer d.deinit();
    try d.mkdir("docs/deep");
    try d.write("docs/deep/f", "x");
    var pbuf: [4096]u8 = undefined;
    const id = try d.t.trash(gpa, d.path(&pbuf, "docs/deep/f"));
    defer gpa.free(id);

    try d.write("docs/deep/f", "new");
    try testing.expectError(error.Exists, d.t.restore(gpa, id, null));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("new", try d.read("docs/deep/f", &buf));
    try testing.expect(existsAbs(id));

    // The folder it was in is gone: made again.
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.unlinkat(linux.AT.FDCWD, d.path(&pbuf, "docs/deep/f"), 0)));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.unlinkat(linux.AT.FDCWD, d.path(&pbuf, "docs/deep"), linux.AT.REMOVEDIR)));
    var list = try d.t.list(gpa);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    list.deinit();
    var dbuf: [4096]u8 = undefined;
    const dest = d.path(&dbuf, "docs/elsewhere/g");
    const back = try d.t.restore(gpa, id, dest);
    defer gpa.free(back);
    try testing.expectEqualStrings(dest, back);
    try testing.expectEqualStrings("x", try d.read("docs/elsewhere/g", &buf));
    try testing.expectError(error.FileNotFound, d.t.restore(gpa, id, null));
}

test "files on other mounts go to the trash at their top, with relative paths" {
    var d: Dir = .{};
    try d.init();
    defer d.deinit();
    try d.mkdir("vol/sub");
    try d.write("vol/sub/a", "a");
    var pbuf: [4096]u8 = undefined;
    const id = try d.t.trash(gpa, d.path(&pbuf, "vol/sub/a"));
    defer gpa.free(id);
    var want: [4096]u8 = undefined;
    const uid = linux.getuid();
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}/vol/.Trash-{d}/files/a", .{ d.root, uid }), id);
    var ibuf: [512]u8 = undefined;
    var rel: [64]u8 = undefined;
    const info = try d.read(try std.fmt.bufPrint(&rel, "vol/.Trash-{d}/info/a.trashinfo", .{uid}), &ibuf);
    try testing.expectStringStartsWith(info, "[Trash Info]\nPath=sub/a\n");
    try testing.expect(!d.exists("home/.local/share/Trash"));

    // A sticky .Trash takes precedence; one without the bit is not used.
    try d.mkdir("vol/.Trash");
    try d.write("vol/sub/b", "b");
    const plain = try d.t.trash(gpa, d.path(&pbuf, "vol/sub/b"));
    defer gpa.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "/.Trash-") != null);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmodat(linux.AT.FDCWD, d.path(&pbuf, "vol/.Trash"), 0o1777)));
    try d.write("vol/sub/c", "c");
    const admin = try d.t.trash(gpa, d.path(&pbuf, "vol/sub/c"));
    defer gpa.free(admin);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}/vol/.Trash/{d}/files/c", .{ d.root, uid }), admin);

    // Listed with absolute paths, from both trashes.
    var list = try d.t.list(gpa);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 3), list.items.len);
    var found: u32 = 0;
    for (list.items) |it| {
        if (std.mem.eql(u8, it.id, admin)) {
            try testing.expectEqualStrings(d.path(&want, "vol/sub/c"), it.path);
            try testing.expectEqual(@as(u64, 1), it.size);
            found += 1;
        }
        if (std.mem.eql(u8, it.id, id)) found += 1;
    }
    try testing.expectEqual(@as(u32, 2), found);
    gpa.free(try d.t.restore(gpa, admin, null));
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("c", try d.read("vol/sub/c", &buf));

    // Inside Flatpak only the home trash is used.
    var home_only = d.t;
    home_only.home_only = true;
    try testing.expectError(error.Unsupported, home_only.trash(gpa, d.path(&pbuf, "vol/sub/c")));
}

test "listing skips info files without their file and caches directory sizes" {
    var d: Dir = .{};
    try d.init();
    defer d.deinit();
    try d.mkdir("docs/tree");
    try d.mkdir("docs/tree/inner");
    const big: [10_000]u8 = @splat('7');
    try d.write("docs/tree/inner/f", &big);
    try d.write("docs/file", "12345");
    var pbuf: [4096]u8 = undefined;
    const tree_id = try d.t.trash(gpa, d.path(&pbuf, "docs/tree"));
    defer gpa.free(tree_id);
    const file_id = try d.t.trash(gpa, d.path(&pbuf, "docs/file"));
    defer gpa.free(file_id);
    try d.write("home/.local/share/Trash/info/ghost.trashinfo", "[Trash Info]\nPath=/nowhere\nDeletionDate=2020-01-02T03:04:05\n");

    var list = try d.t.list(gpa);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 2), list.items.len);
    var tree_size: u64 = 0;
    for (list.items) |it| {
        if (std.mem.eql(u8, it.id, file_id)) {
            try testing.expect(!it.directory);
            try testing.expectEqual(@as(u64, 5), it.size);
        } else {
            try testing.expect(it.directory);
            try testing.expectEqualStrings(d.path(&pbuf, "docs/tree"), it.path);
            tree_size = it.size;
        }
    }
    // Disk usage, at least the 10 000 bytes of the one file.
    try testing.expect(tree_size >= 10_000);
    var sbuf: [256]u8 = undefined;
    const sizes = try d.read("home/.local/share/Trash/directorysizes", &sbuf);
    var want: [64]u8 = undefined;
    try testing.expectStringStartsWith(sizes, try std.fmt.bufPrint(&want, "{d} ", .{tree_size}));
    try testing.expectStringEndsWith(sizes, " tree\n");

    // The cache answers, so a size written into it with the right mtime
    // is what listing reports.
    const mtime = std.mem.trim(u8, sizes[std.mem.indexOfScalar(u8, sizes, ' ').? + 1 .. std.mem.lastIndexOfScalar(u8, sizes, ' ').?], " ");
    var fake: [64]u8 = undefined;
    try d.write("home/.local/share/Trash/directorysizes", try std.fmt.bufPrint(&fake, "42 {s} tree\n99 1 gone%20dir\n", .{mtime}));
    var again = try d.t.list(gpa);
    defer again.deinit();
    for (again.items) |it| if (it.directory) try testing.expectEqual(@as(u64, 42), it.size);
    // The stale entry was dropped when it wrote the cache back.
    try testing.expect(std.mem.indexOf(u8, try d.read("home/.local/share/Trash/directorysizes", &sbuf), "gone") == null);

    // Restoring drops the directory's entry.
    gpa.free(try d.t.restore(gpa, tree_id, null));
    try testing.expectEqualStrings("", try d.read("home/.local/share/Trash/directorysizes", &sbuf));
}

test "ids must name trash entries; deleting one and emptying remove everything" {
    var d: Dir = .{};
    try d.init();
    defer d.deinit();
    try d.write("docs/keep", "k");
    try d.mkdir("docs/files");
    try d.write("docs/files/x", "x");
    var pbuf: [4096]u8 = undefined;
    try testing.expectError(error.InvalidId, d.t.delete(gpa, d.path(&pbuf, "docs/keep")));
    try testing.expectError(error.InvalidId, d.t.delete(gpa, d.path(&pbuf, "docs/files/x")));
    try testing.expectError(error.InvalidId, d.t.restore(gpa, d.path(&pbuf, "home/.local/share/Trash/files/../../keep"), null));
    try testing.expect(d.exists("docs/files/x"));

    try d.mkdir("docs/dir");
    try d.write("docs/dir/f", "f");
    try d.write("vol/v", "v");
    try d.write("docs/one", "1");
    const dir_id = try d.t.trash(gpa, d.path(&pbuf, "docs/dir"));
    defer gpa.free(dir_id);
    const vol_id = try d.t.trash(gpa, d.path(&pbuf, "vol/v"));
    defer gpa.free(vol_id);
    const one_id = try d.t.trash(gpa, d.path(&pbuf, "docs/one"));
    defer gpa.free(one_id);

    try d.t.delete(gpa, dir_id);
    try testing.expect(!existsAbs(dir_id));
    try testing.expect(!d.exists("home/.local/share/Trash/info/dir.trashinfo"));
    try testing.expectError(error.FileNotFound, d.t.delete(gpa, dir_id));

    try d.t.empty(gpa);
    var list = try d.t.list(gpa);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.items.len);
    try testing.expect(!existsAbs(vol_id));
    try testing.expect(!existsAbs(one_id));
    try testing.expect(d.exists("home/.local/share/Trash/files"));
    try testing.expect(d.exists("docs/keep"));
}

test "the trash itself, and what is in it, cannot be trashed; links are trashed, not their targets" {
    var d: Dir = .{};
    try d.init();
    defer d.deinit();
    try d.write("docs/t", "t");
    var pbuf: [4096]u8 = undefined;
    const id = try d.t.trash(gpa, d.path(&pbuf, "docs/t"));
    defer gpa.free(id);
    try testing.expectError(error.Unsupported, d.t.trash(gpa, id));
    try testing.expectError(error.Unsupported, d.t.trash(gpa, d.t.home));
    try testing.expectError(error.Unsupported, d.t.trash(gpa, d.path(&pbuf, "home/.local")));
    try testing.expectError(error.FileNotFound, d.t.trash(gpa, d.path(&pbuf, "docs/missing")));

    var tbuf: [4096]u8 = undefined;
    try d.write("docs/target", "target");
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("target", linux.AT.FDCWD, d.path(&tbuf, "docs/link"))));
    const link_id = try d.t.trash(gpa, d.path(&pbuf, "docs/link"));
    defer gpa.free(link_id);
    try testing.expect(d.exists("docs/target"));
    var st: linux.Statx = undefined;
    const z = try std.fmt.bufPrintSentinel(&tbuf, "{s}", .{link_id}, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)));
    try testing.expectEqual(@as(u32, linux.S.IFLNK), st.mode & linux.S.IFMT);
}

test "long names are shortened at a character boundary to fit the info file's name" {
    var d: Dir = .{};
    try d.init();
    defer d.deinit();
    // 240 bytes: 2 + 119 two-byte characters; with ".trashinfo" over 255.
    var name: [241]u8 = undefined;
    @memcpy(name[0..2], "x_");
    var i: usize = 2;
    while (i + 2 <= name.len) : (i += 2) @memcpy(name[i..][0..2], "é");
    const n = i;
    var rel: [300]u8 = undefined;
    const r = try std.fmt.bufPrint(&rel, "docs/{s}", .{name[0..n]});
    try d.write(r, "z");
    var pbuf: [4096]u8 = undefined;
    const id = try d.t.trash(gpa, d.path(&pbuf, r));
    defer gpa.free(id);
    const base = std.fs.path.basename(id);
    try testing.expect(base.len + ".trashinfo".len <= 255);
    try testing.expect(std.unicode.utf8ValidateSlice(base));
    const back = try d.t.restore(gpa, id, null);
    defer gpa.free(back);
    try testing.expectStringEndsWith(back, name[0..n]);
}

test "percent decoding and dates" {
    var buf: [linux.PATH_MAX]u8 = undefined;
    try testing.expectEqualStrings("/a b/é", trash.percentDecode(&buf, "/a%20b/%C3%a9").?);
    try testing.expect(trash.percentDecode(&buf, "/a%2") == null);
    try testing.expect(trash.percentDecode(&buf, "/a%zz") == null);
    try testing.expect(trash.percentDecode(&buf, "/a%00b") == null);
    try testing.expect(trash.parseDate("2004-08-31 22:32:08") == null);
    const a = trash.parseDate("2004-08-31T22:32:08").?;
    const b = trash.parseDate("2004-09-01T22:32:08").?;
    try testing.expectEqual(@as(i64, 86400), b - a);
    // Relative paths resolve against the topdir.
    const info = trash.parseInfo("[Other]\nPath=/no\n[Trash Info]\nPath=x/y%20z\nDeletionDate=bad\n", "/mnt/usb", &buf);
    try testing.expectEqualStrings("/mnt/usb/x/y z", info.path);
    try testing.expectEqual(@as(i64, 0), info.deleted);
}
