//! File operations: copy, move, delete, and creating and renaming; the
//! trash is siv's (D42). `Op.run` blocks and runs on a worker thread of
//! siv's pool (siv_job_start); the UI thread reads its progress from
//! atomics and asks it to stop with `cancel`, which it checks between
//! files and between chunks of a large file.
//!
//! Names that already exist in the destination are not overwritten: the
//! copy gets " (2)", " (3)", ... before its extension, as GNOME Files
//! names duplicates.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

pub const Kind = enum { copy, move, delete };

pub const Error = error{
    Canceled,
    FileNotFound,
    AccessDenied,
    NoSpace,
    Exists,
    InvalidName,
    IntoItself,
    NameTooLong,
    OutOfMemory,
    Unexpected,
};

pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.Canceled => "Canceled",
        error.FileNotFound => "No such file or folder",
        error.AccessDenied => "Permission denied",
        error.NoSpace => "No space left on the device",
        error.Exists => "A file with that name already exists",
        error.InvalidName => "Names cannot be empty or contain “/”",
        error.IntoItself => "A folder cannot be copied or moved into itself",
        error.NameTooLong => "The name is too long",
        error.OutOfMemory => "Out of memory",
        error.Unexpected => "Unexpected error",
    };
}

pub const Op = struct {
    gpa: Allocator,
    kind: Kind,
    /// Absolute paths (owned).
    sources: [][]u8,
    /// The destination folder for copy and move (owned), else empty.
    dest: []u8,

    cancel: std.atomic.Value(bool) = .init(false),
    total_bytes: std.atomic.Value(u64) = .init(0),
    done_bytes: std.atomic.Value(u64) = .init(0),
    total_items: std.atomic.Value(u32) = .init(0),
    done_items: std.atomic.Value(u32) = .init(0),
    /// Counting what to do before doing it.
    scanning: std.atomic.Value(bool) = .init(true),
    /// Set once by the worker when it finishes.
    result: ?Error = null,
    /// The file the error was about.
    err_path: [256]u8 = undefined,
    err_path_len: usize = 0,
    /// Names the operation created in `dest`, newline-separated, so the
    /// view can select them.
    created: std.ArrayList(u8) = .empty,

    pub fn create(gpa: Allocator, kind: Kind, sources: []const []const u8, dest: []const u8) !*Op {
        const op = try gpa.create(Op);
        errdefer gpa.destroy(op);
        const srcs = try gpa.alloc([]u8, sources.len);
        var n: usize = 0;
        errdefer {
            for (srcs[0..n]) |s| gpa.free(s);
            gpa.free(srcs);
        }
        while (n < sources.len) : (n += 1) srcs[n] = try gpa.dupe(u8, sources[n]);
        const d = try gpa.dupe(u8, dest);
        op.* = .{ .gpa = gpa, .kind = kind, .sources = srcs, .dest = d };
        return op;
    }

    pub fn destroy(op: *Op) void {
        const gpa = op.gpa;
        for (op.sources) |s| gpa.free(s);
        gpa.free(op.sources);
        gpa.free(op.dest);
        op.created.deinit(gpa);
        gpa.destroy(op);
    }

    /// Does the work. Blocking; on a worker thread.
    pub fn run(op: *Op) void {
        op.result = null;
        op.scan();
        op.scanning.store(false, .release);
        for (op.sources) |src| {
            op.one(src) catch |err| {
                op.result = err;
                return;
            };
        }
    }

    fn fail(op: *Op, path: []const u8, err: Error) Error {
        const n = @min(path.len, op.err_path.len);
        @memcpy(op.err_path[0..n], path[0..n]);
        op.err_path_len = n;
        return err;
    }

    pub fn errPath(op: *const Op) []const u8 {
        return op.err_path[0..op.err_path_len];
    }

    fn checkCancel(op: *Op) Error!void {
        if (op.cancel.load(.acquire)) return error.Canceled;
    }

    /// Counts files and bytes, for progress. Moves within one file system
    /// and deletes count items only.
    fn scan(op: *Op) void {
        for (op.sources) |src| {
            if (op.cancel.load(.acquire)) return;
            var buf: [linux.PATH_MAX]u8 = undefined;
            const z = zpath(&buf, src) catch continue;
            op.scanTree(z, op.kind == .copy);
        }
    }

    fn scanTree(op: *Op, path: [:0]const u8, bytes: bool) void {
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true }, &st)) != .SUCCESS) return;
        _ = op.total_items.fetchAdd(1, .monotonic);
        if (st.mode & linux.S.IFMT == linux.S.IFREG and bytes) _ = op.total_bytes.fetchAdd(st.size, .monotonic);
        if (st.mode & linux.S.IFMT != linux.S.IFDIR or op.kind == .move) return;
        var it = DirIter.open(path) catch return;
        defer it.close();
        while (it.next()) |nm| {
            if (op.cancel.load(.acquire)) return;
            var buf: [linux.PATH_MAX]u8 = undefined;
            const child = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ path, nm }, 0) catch continue;
            op.scanTree(child, bytes);
        }
    }

    fn one(op: *Op, src: []const u8) Error!void {
        try op.checkCancel();
        switch (op.kind) {
            .copy, .move => {
                // A folder into itself or below itself.
                if (std.mem.startsWith(u8, op.dest, src) and (op.dest.len == src.len or op.dest[src.len] == '/'))
                    return op.fail(src, error.IntoItself);
                const same_dir = std.mem.eql(u8, model.parent(src), op.dest);
                if (op.kind == .move and same_dir) return; // nothing to do
                var buf: [linux.PATH_MAX]u8 = undefined;
                const target = try op.freeName(&buf, op.dest, model.basename(src));
                if (op.kind == .move) {
                    try op.move(src, target);
                } else {
                    try op.copyTree(src, target);
                }
                try op.created.appendSlice(op.gpa, model.basename(target));
                try op.created.append(op.gpa, '\n');
            },
            .delete => try op.deleteTree(src),
        }
    }

    /// `dir/name`, or with " (2)", " (3)", ... before the extension if
    /// that exists.
    fn freeName(op: *Op, buf: *[linux.PATH_MAX]u8, dir: []const u8, nm: []const u8) Error![:0]u8 {
        const first = std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ trimSlash(dir), nm }, 0) catch return op.fail(nm, error.NameTooLong);
        if (!exists(first)) return first;
        const dot = std.mem.lastIndexOfScalar(u8, nm, '.');
        const stem, const ext = if (dot) |d| (if (d == 0) .{ nm, "" } else .{ nm[0..d], nm[d..] }) else .{ nm, "" };
        var k: u32 = 2;
        while (k < 10000) : (k += 1) {
            const p = std.fmt.bufPrintSentinel(buf, "{s}/{s} ({d}){s}", .{ trimSlash(dir), stem, k, ext }, 0) catch return op.fail(nm, error.NameTooLong);
            if (!exists(p)) return p;
        }
        return op.fail(nm, error.Exists);
    }

    fn move(op: *Op, src: []const u8, target: [:0]const u8) Error!void {
        var sbuf: [linux.PATH_MAX]u8 = undefined;
        const zs = zpath(&sbuf, src) catch return op.fail(src, error.NameTooLong);
        const rc = linux.renameat2(linux.AT.FDCWD, zs, linux.AT.FDCWD, target, .{ .NOREPLACE = true });
        switch (linux.errno(rc)) {
            .SUCCESS => {
                _ = op.done_items.fetchAdd(1, .monotonic);
                return;
            },
            // Another file system: copy, then delete the original.
            .XDEV => {},
            else => |e| return op.fail(src, mapErrno(e)),
        }
        // Count the bytes now that they must be copied.
        op.scanTree(zs, true);
        try op.copyTree(src, target);
        try op.deleteTree(src);
    }

    fn copyTree(op: *Op, src: []const u8, target: [:0]const u8) Error!void {
        try op.checkCancel();
        var sbuf: [linux.PATH_MAX]u8 = undefined;
        const zs = zpath(&sbuf, src) catch return op.fail(src, error.NameTooLong);
        var st: linux.Statx = undefined;
        const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true, .ATIME = true };
        switch (linux.errno(linux.statx(linux.AT.FDCWD, zs, linux.AT.SYMLINK_NOFOLLOW, mask, &st))) {
            .SUCCESS => {},
            else => |e| return op.fail(src, mapErrno(e)),
        }
        const mode = st.mode & 0o7777;
        switch (st.mode & linux.S.IFMT) {
            linux.S.IFDIR => {
                switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, target, mode | 0o700))) {
                    .SUCCESS => {},
                    else => |e| return op.fail(target, mapErrno(e)),
                }
                _ = op.done_items.fetchAdd(1, .monotonic);
                var it = DirIter.open(zs) catch |err| return op.fail(src, err);
                defer it.close();
                while (it.next()) |nm| {
                    var cs: [linux.PATH_MAX]u8 = undefined;
                    var ct: [linux.PATH_MAX]u8 = undefined;
                    const child_src = std.fmt.bufPrint(&cs, "{s}/{s}", .{ src, nm }) catch return op.fail(src, error.NameTooLong);
                    const child_target = std.fmt.bufPrintSentinel(&ct, "{s}/{s}", .{ target, nm }, 0) catch return op.fail(src, error.NameTooLong);
                    try op.copyTree(child_src, child_target);
                }
                _ = linux.fchmodat(linux.AT.FDCWD, target, mode);
            },
            linux.S.IFLNK => {
                var lbuf: [linux.PATH_MAX]u8 = undefined;
                const n = linux.readlinkat(linux.AT.FDCWD, zs, &lbuf, lbuf.len - 1);
                switch (linux.errno(n)) {
                    .SUCCESS => {},
                    else => |e| return op.fail(src, mapErrno(e)),
                }
                lbuf[n] = 0;
                switch (linux.errno(linux.symlinkat(lbuf[0..n :0], linux.AT.FDCWD, target))) {
                    .SUCCESS => {},
                    else => |e| return op.fail(target, mapErrno(e)),
                }
                _ = op.done_items.fetchAdd(1, .monotonic);
            },
            linux.S.IFREG => try op.copyFile(src, zs, target, mode, st),
            // Devices, sockets, and pipes are not copied.
            else => _ = op.done_items.fetchAdd(1, .monotonic),
        }
    }

    fn copyFile(op: *Op, src: []const u8, zs: [:0]const u8, target: [:0]const u8, mode: u32, st: linux.Statx) Error!void {
        const in_rc = linux.openat(linux.AT.FDCWD, zs, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        const in: i32 = switch (linux.errno(in_rc)) {
            .SUCCESS => @intCast(in_rc),
            else => |e| return op.fail(src, mapErrno(e)),
        };
        defer _ = linux.close(in);
        const out_rc = linux.openat(linux.AT.FDCWD, target, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, mode);
        const out: i32 = switch (linux.errno(out_rc)) {
            .SUCCESS => @intCast(out_rc),
            else => |e| return op.fail(target, mapErrno(e)),
        };
        var ok = false;
        defer {
            _ = linux.close(out);
            if (!ok) _ = linux.unlinkat(linux.AT.FDCWD, target, 0);
        }
        // copy_file_range in chunks, so that cancelling and progress work
        // for large files (and reflinks or server-side copies happen where
        // the file system offers them); read and write where it is refused.
        const chunk: usize = 4 << 20;
        var use_read = false;
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            try op.checkCancel();
            var n: usize = 0;
            if (!use_read) {
                const rc = linux.copy_file_range(in, null, out, null, chunk, 0);
                switch (linux.errno(rc)) {
                    .SUCCESS => n = rc,
                    .INTR => continue,
                    .XDEV, .INVAL, .OPNOTSUPP, .NOSYS => {
                        use_read = true;
                        continue;
                    },
                    else => |e| return op.fail(target, mapErrno(e)),
                }
            } else {
                const rc = linux.read(in, &buf, buf.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => n = rc,
                    .INTR => continue,
                    else => |e| return op.fail(src, mapErrno(e)),
                }
                var off: usize = 0;
                while (off < n) {
                    const w = linux.write(out, buf[off..n].ptr, n - off);
                    switch (linux.errno(w)) {
                        .SUCCESS => off += w,
                        .INTR => {},
                        else => |e| return op.fail(target, mapErrno(e)),
                    }
                }
            }
            if (n == 0) break;
            _ = op.done_bytes.fetchAdd(n, .monotonic);
        }
        const times = [2]linux.timespec{
            .{ .sec = st.atime.sec, .nsec = st.atime.nsec },
            .{ .sec = st.mtime.sec, .nsec = st.mtime.nsec },
        };
        _ = linux.utimensat(out, null, &times, 0);
        ok = true;
        _ = op.done_items.fetchAdd(1, .monotonic);
    }

    fn deleteTree(op: *Op, path: []const u8) Error!void {
        try op.checkCancel();
        var buf: [linux.PATH_MAX]u8 = undefined;
        const z = zpath(&buf, path) catch return op.fail(path, error.NameTooLong);
        switch (linux.errno(linux.unlinkat(linux.AT.FDCWD, z, 0))) {
            .SUCCESS => {
                _ = op.done_items.fetchAdd(1, .monotonic);
                return;
            },
            .ISDIR, .PERM => {},
            else => |e| return op.fail(path, mapErrno(e)),
        }
        var it = DirIter.open(z) catch |err| return op.fail(path, err);
        while (it.next()) |nm| {
            var cbuf: [linux.PATH_MAX]u8 = undefined;
            const child = std.fmt.bufPrint(&cbuf, "{s}/{s}", .{ path, nm }) catch {
                it.close();
                return op.fail(path, error.NameTooLong);
            };
            op.deleteTree(child) catch |err| {
                it.close();
                return err;
            };
        }
        it.close();
        switch (linux.errno(linux.unlinkat(linux.AT.FDCWD, z, linux.AT.REMOVEDIR))) {
            .SUCCESS => _ = op.done_items.fetchAdd(1, .monotonic),
            else => |e| return op.fail(path, mapErrno(e)),
        }
    }
};

/// Creates a folder `name` in `dir`.
pub fn makeDir(dir: []const u8, nm: []const u8) Error!void {
    if (!model.validName(nm)) return error.InvalidName;
    var buf: [linux.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ trimSlash(dir), nm }, 0) catch return error.NameTooLong;
    switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, p, 0o755))) {
        .SUCCESS => {},
        else => |e| return mapErrno(e),
    }
}

/// Renames `old` to `new` in `dir`, refusing to replace an existing file.
pub fn rename(dir: []const u8, old: []const u8, new: []const u8) Error!void {
    if (!model.validName(new)) return error.InvalidName;
    if (std.mem.eql(u8, old, new)) return;
    var a: [linux.PATH_MAX]u8 = undefined;
    var b: [linux.PATH_MAX]u8 = undefined;
    const pa = std.fmt.bufPrintSentinel(&a, "{s}/{s}", .{ trimSlash(dir), old }, 0) catch return error.NameTooLong;
    const pb = std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ trimSlash(dir), new }, 0) catch return error.NameTooLong;
    switch (linux.errno(linux.renameat2(linux.AT.FDCWD, pa, linux.AT.FDCWD, pb, .{ .NOREPLACE = true }))) {
        .SUCCESS => {},
        else => |e| return mapErrno(e),
    }
}

fn trimSlash(dir: []const u8) []const u8 {
    return if (dir.len > 1 and dir[dir.len - 1] == '/') dir[0 .. dir.len - 1] else if (dir.len == 1) "" else dir;
}

fn zpath(buf: *[linux.PATH_MAX]u8, p: []const u8) error{NameTooLong}![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}", .{p}, 0) catch error.NameTooLong;
}

fn exists(p: [:0]const u8) bool {
    var st: linux.Statx = undefined;
    return linux.errno(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) == .SUCCESS;
}

fn mapErrno(e: linux.E) Error {
    return switch (e) {
        .NOENT, .NOTDIR => error.FileNotFound,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOSPC, .DQUOT => error.NoSpace,
        .EXIST, .NOTEMPTY => error.Exists,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.OutOfMemory,
        .INVAL => error.IntoItself,
        else => error.Unexpected,
    };
}

/// Names in a directory, without "." and "..".
const DirIter = struct {
    fd: i32,
    buf: [8192]u8 align(8) = undefined,
    len: usize = 0,
    off: usize = 0,

    fn open(path: [:0]const u8) Error!DirIter {
        const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .fd = @intCast(rc) },
            else => |e| mapErrno(e),
        };
    }

    fn close(it: *DirIter) void {
        _ = linux.close(it.fd);
    }

    fn next(it: *DirIter) ?[]const u8 {
        while (true) {
            if (it.off >= it.len) {
                const n = linux.getdents64(it.fd, &it.buf, it.buf.len);
                if (linux.errno(n) != .SUCCESS or n == 0) return null;
                it.len = n;
                it.off = 0;
            }
            const d: *align(1) const linux.dirent64 = @ptrCast(&it.buf[it.off]);
            const name_ptr: [*:0]const u8 = @ptrCast(&it.buf[it.off + @offsetOf(linux.dirent64, "name")]);
            it.off += d.reclen;
            const nm = std.mem.span(name_ptr);
            if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
            return nm;
        }
    }
};
