//! The sidebar's places: home, the XDG user directories that exist
//! ($XDG_CONFIG_HOME/user-dirs.dirs), GTK bookmarks, the trash, and the
//! root of the file system.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const icons = @import("icons.zig");
const uri = @import("uri.zig");

pub const Place = struct {
    label: []u8,
    path: []u8,
    icon: icons.Icon,
};

pub const Places = struct {
    gpa: Allocator,
    items: std.ArrayList(Place) = .empty,
    /// $XDG_DATA_HOME/Trash.
    trash_dir: []u8 = &.{},

    pub fn deinit(p: *Places) void {
        for (p.items.items) |it| {
            p.gpa.free(it.label);
            p.gpa.free(it.path);
        }
        p.items.deinit(p.gpa);
        p.gpa.free(p.trash_dir);
    }

    fn add(p: *Places, label: []const u8, path: []const u8, icon: icons.Icon) !void {
        for (p.items.items) |it| if (std.mem.eql(u8, it.path, path)) return;
        const l = try p.gpa.dupe(u8, label);
        errdefer p.gpa.free(l);
        const pa = try p.gpa.dupe(u8, path);
        errdefer p.gpa.free(pa);
        try p.items.append(p.gpa, .{ .label = l, .path = pa, .icon = icon });
    }

    /// The place whose path is `path`, if any.
    pub fn find(p: *const Places, path: []const u8) ?usize {
        for (p.items.items, 0..) |it, i| if (std.mem.eql(u8, it.path, path)) return i;
        return null;
    }
};

pub const Env = struct {
    home: []const u8,
    config_home: ?[]const u8 = null,
    data_home: ?[]const u8 = null,
};

/// Builds the list for `env`. Directories that do not exist are left out.
pub fn load(gpa: Allocator, env: Env) !Places {
    var p: Places = .{ .gpa = gpa };
    errdefer p.deinit();
    var buf: [linux.PATH_MAX]u8 = undefined;
    try p.add("Home", env.home, .home);

    const config = env.config_home orelse (std.fmt.bufPrint(&buf, "{s}/.config", .{env.home}) catch env.home);
    var cfg_buf: [linux.PATH_MAX]u8 = undefined;
    const cfg = try gpa.dupe(u8, config);
    defer gpa.free(cfg);
    const dirs_path = std.fmt.bufPrint(&cfg_buf, "{s}/user-dirs.dirs", .{cfg}) catch "";
    const wanted = [_]struct { []const u8, []const u8, icons.Icon, []const u8 }{
        .{ "XDG_DESKTOP_DIR", "Desktop", .desktop, "Desktop" },
        .{ "XDG_DOCUMENTS_DIR", "Documents", .folder, "Documents" },
        .{ "XDG_DOWNLOAD_DIR", "Downloads", .download, "Downloads" },
        .{ "XDG_MUSIC_DIR", "Music", .folder, "Music" },
        .{ "XDG_PICTURES_DIR", "Pictures", .folder, "Pictures" },
        .{ "XDG_VIDEOS_DIR", "Videos", .folder, "Videos" },
    };
    var contents_buf: [8192]u8 = undefined;
    const contents = readSmall(dirs_path, &contents_buf);
    for (wanted) |wd| {
        const key, const label, const icon, const default = wd;
        var pbuf: [linux.PATH_MAX]u8 = undefined;
        const path = userDir(contents, key, env.home, &pbuf) orelse (std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ env.home, default }) catch continue);
        // XDG says a user directory equal to $HOME is disabled.
        if (std.mem.eql(u8, path, env.home)) continue;
        if (isDir(path)) try p.add(label, path, icon);
    }

    // GTK bookmarks: "file:///path optional label" per line.
    const bm_path = std.fmt.bufPrint(&cfg_buf, "{s}/gtk-3.0/bookmarks", .{cfg}) catch "";
    const bm = readSmall(bm_path, &contents_buf);
    var lines = std.mem.splitScalar(u8, bm, '\n');
    while (lines.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ');
        const u = if (sp) |i| line[0..i] else line;
        var pbuf: [linux.PATH_MAX]u8 = undefined;
        const path = uri.filePath(&pbuf, u) orelse continue;
        const label = if (sp) |i| std.mem.trim(u8, line[i + 1 ..], " ") else basename(path);
        if (isDir(path)) try p.add(if (label.len == 0) basename(path) else label, path, .bookmark);
    }

    const data = env.data_home orelse (std.fmt.bufPrint(&buf, "{s}/.local/share", .{env.home}) catch env.home);
    p.trash_dir = try std.fmt.allocPrint(gpa, "{s}/Trash", .{data});
    var tbuf: [linux.PATH_MAX]u8 = undefined;
    const trash_files = std.fmt.bufPrint(&tbuf, "{s}/files", .{p.trash_dir}) catch "";
    try p.add("Trash", trash_files, .trash);
    try p.add("Computer", "/", .computer);
    return p;
}

fn basename(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return if (i + 1 == path.len) path else path[i + 1 ..];
}

/// `KEY="$HOME/Pictures"` from user-dirs.dirs, with $HOME expanded.
fn userDir(contents: []const u8, key: []const u8, home: []const u8, out: []u8) ?[]u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key) or line.len <= key.len or line[key.len] != '=') continue;
        var v = std.mem.trim(u8, line[key.len + 1 ..], " ");
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        if (std.mem.startsWith(u8, v, "$HOME")) {
            return std.fmt.bufPrint(out, "{s}{s}", .{ home, v["$HOME".len..] }) catch null;
        }
        if (v.len > 0 and v[0] == '/') return std.fmt.bufPrint(out, "{s}", .{v}) catch null;
        return null;
    }
    return null;
}

fn readSmall(path: []const u8, buf: []u8) []const u8 {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return "";
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return "";
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    return buf[0..n];
}

pub fn isDir(path: []const u8) bool {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return false;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return false;
    return st.mode & linux.S.IFMT == linux.S.IFDIR;
}

test "user dirs" {
    var out: [256]u8 = undefined;
    const contents = "# comment\nXDG_PICTURES_DIR=\"$HOME/Bilder\"\nXDG_MUSIC_DIR=\"/srv/music\"\n";
    try std.testing.expectEqualStrings("/home/me/Bilder", userDir(contents, "XDG_PICTURES_DIR", "/home/me", &out).?);
    try std.testing.expectEqualStrings("/srv/music", userDir(contents, "XDG_MUSIC_DIR", "/home/me", &out).?);
    try std.testing.expect(userDir(contents, "XDG_VIDEOS_DIR", "/home/me", &out) == null);
}
