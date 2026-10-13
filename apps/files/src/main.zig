//! siv-files: a file manager built on siv's public API.
//!
//!     zig build files && ./zig-out/bin/siv-files [FOLDER] [--grid] [--hidden]
//!         [--dark | --light] [--rtl] [--no-thumbnails]

const std = @import("std");
const siv = @import("siv");
const c = siv.c;
const Files = @import("Files.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;
extern "c" fn free(ptr: ?*anyopaque) void;

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

fn quit(files: *Files) void {
    _ = c.siv_app_quit(files.app);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = std.heap.c_allocator;
    var path_arg: ?[]const u8 = null;
    var opts: Files.Options = .{ .gpa = gpa, .path = "", .home = "" };
    var flags: siv.AppFlags = .{};
    var theme: siv.ColorScheme = .follow;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--grid")) {
            opts.mode = .grid;
        } else if (std.mem.eql(u8, a, "--hidden")) {
            opts.show_hidden = true;
        } else if (std.mem.eql(u8, a, "--dark")) {
            theme = .dark;
        } else if (std.mem.eql(u8, a, "--light")) {
            theme = .light;
        } else if (std.mem.eql(u8, a, "--rtl")) {
            flags.rtl = true;
        } else if (std.mem.eql(u8, a, "--no-thumbnails")) {
            opts.thumbnails = false;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("usage: siv-files [FOLDER] [--grid] [--hidden] [--dark|--light] [--rtl] [--no-thumbnails]\n", .{});
            return 0;
        } else {
            path_arg = a;
        }
    }
    const home = env("HOME") orelse "/";
    opts.home = home;
    opts.config_home = env("XDG_CONFIG_HOME");
    opts.data_home = env("XDG_DATA_HOME");
    opts.tz_offset_s = localOffset();

    // Resolve the folder argument against the working directory.
    var resolved: ?[*:0]u8 = null;
    defer if (resolved) |r| free(r);
    if (path_arg) |p| {
        var zbuf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{p}, 0) catch return 1;
        resolved = realpath(z, null);
        opts.path = if (resolved) |r| std.mem.span(r) else p;
    } else opts.path = home;

    var app: siv.App = .null;
    var r = c.siv_app_create(&.{ .flags = flags, .name = "Files", .name_len = 5, .app_id = "org.siv.Files", .app_id_len = 13 }, &app);
    if (r != .ok) {
        std.debug.print("siv-files: cannot start: {s}\n", .{std.mem.span(c.siv_result_name(r))});
        return 1;
    }
    defer _ = c.siv_app_destroy(app);
    if (theme != .follow) _ = c.siv_app_set_theme(app, &.{ .scheme = theme });

    opts.on_closed = quit;
    // Installed with the executable: <prefix>/share/siv-files/icons.
    var icon_buf: [4096]u8 = undefined;
    opts.icon_dir = iconDir(&icon_buf);
    const files = Files.create(app, opts) catch |err| {
        std.debug.print("siv-files: cannot open a window: {s}\n", .{@errorName(err)});
        return 1;
    };
    files.theme = theme;
    if (env("XDG_CACHE_HOME")) |cache| {
        var buf: [4096]u8 = undefined;
        files.thumbs.setCacheDir(std.fmt.bufPrint(&buf, "{s}/thumbnails", .{cache}) catch "");
    } else {
        var buf: [4096]u8 = undefined;
        files.thumbs.setCacheDir(std.fmt.bufPrint(&buf, "{s}/.cache/thumbnails", .{home}) catch "");
    }
    r = c.siv_app_run(app);
    if (r != .ok) {
        std.debug.print("siv-files: {s}\n", .{std.mem.span(c.siv_result_name(r))});
        return 1;
    }
    return 0;
}

/// share/siv-files/icons beside the executable's bin directory.
fn iconDir(buf: []u8) ?[]const u8 {
    const linux = std.os.linux;
    var exe: [4096]u8 = undefined;
    const n = linux.readlink("/proc/self/exe", &exe, exe.len);
    if (linux.errno(n) != .SUCCESS) return null;
    const bin = std.fs.path.dirname(exe[0..n]) orelse return null;
    const prefix = std.fs.path.dirname(bin) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/share/siv-files/icons", .{prefix}) catch null;
}

/// The local time zone's offset from UTC now, in seconds, from libc.
fn localOffset() i64 {
    const tm = extern struct {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        gmtoff: c_long,
        zone: ?[*:0]const u8,
    };
    const S = struct {
        extern "c" fn time(t: ?*i64) i64;
        extern "c" fn localtime_r(t: *const i64, out: *tm) ?*tm;
    };
    var now = S.time(null);
    var out: tm = undefined;
    if (S.localtime_r(&now, &out) == null) return 0;
    return out.gmtoff;
}
