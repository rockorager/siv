//! The user's theme (D29) for every window: `$XDG_CONFIG_HOME/siv/theme.toml`
//! or Omarchy's current theme (ui.user_theme), read on the worker pool at
//! startup and again whenever the watch (watch.zig) sees the files change.
//!
//! - theme.toml decides when it exists; `base = "omarchy"` lays it over
//!   Omarchy's theme. Without it, Omarchy's theme applies when there is
//!   one: `~/.local/state/omarchy/current/theme/colors.toml` (Omarchy 4),
//!   else `~/.config/omarchy/current/theme/colors.toml` (Omarchy 3.3).
//! - `SIV_THEME=none` turns user themes off; `SIV_THEME=PATH` reads that
//!   file instead, a theme.toml or, by its name, an Omarchy colors.toml,
//!   on any backend (the headless backend looks for nothing else, so
//!   tests do not depend on the user's files).
//! - Omarchy swaps themes by deleting the current one and renaming a
//!   staged `next-theme` into place. A read between the two finds no
//!   colors but a `next-theme`, and keeps the theme it has until the
//!   rename, so nothing flashes the compiled colors.
//!
//! First frames wait for the first read like they wait for the desktop
//! settings (desktop.zig), at most `first_frame_wait_ns`.

const std = @import("std");
const linux = std.os.linux;
const ui = @import("ui");
const loop_mod = @import("loop");
const watch = @import("watch.zig");
const app_mod = @import("app.zig");
const desktop = @import("desktop.zig");

const Allocator = std.mem.Allocator;
const Loop = loop_mod.Loop;
const Timer = loop_mod.Timer;
const Pool = loop_mod.Pool;
const App = app_mod.App;
const user_theme = ui.user_theme;

pub const Options = struct {
    /// Look for theme.toml and Omarchy's theme. Without it only a file
    /// SIV_THEME names applies.
    lookup: bool = true,
    /// $HOME and $XDG_CONFIG_HOME, or null for the environment's.
    home: ?[]const u8 = null,
    config_home: ?[]const u8 = null,
    /// The theme file, instead of $SIV_THEME (tests).
    file: ?[]const u8 = null,
};

pub const UserTheme = struct {
    /// What windows follow.
    value: ui.theme.User = .{},
    /// First frames are held until the first read.
    first: bool = false,
    timer: Timer = .{ .func = onTimeout },
    watch: watch.Watch = .{ .on_change = onChange },
    job: Pool.Job = .{ .run = run, .done = done, .cancel = cancel, .class = .blocking },
    running: bool = false,
    /// Files changed while a read ran: read again.
    again: bool = false,
    gpa: Allocator = undefined,
    lookup: bool = false,
    home: []u8 = &.{},
    config: []u8 = &.{},
    file: []u8 = &.{},
    // The read's results, for `done`.
    result: ui.theme.User = .{},
    /// Omarchy is between deleting a theme and renaming the next one in.
    swapping: bool = false,
    entries: []const watch.Entry = &.{},

    pub fn start(ut: *UserTheme, app: *App, options: Options) void {
        const env_theme = env("SIV_THEME");
        const file = options.file orelse env_theme;
        if (options.file == null and std.mem.eql(u8, env_theme, "none")) return;
        if (file.len == 0 and !options.lookup) return;
        const home = options.home orelse env("HOME");
        const xdg = options.config_home orelse env("XDG_CONFIG_HOME");
        const gpa = app.gpa;
        ut.gpa = gpa;
        ut.lookup = options.lookup;
        ut.home = gpa.dupe(u8, home) catch return;
        ut.config = (if (xdg.len != 0) gpa.dupe(u8, xdg) else std.fmt.allocPrint(gpa, "{s}/.config", .{home})) catch return ut.free();
        ut.file = gpa.dupe(u8, file) catch return ut.free();
        // Without a watch the theme is read once.
        ut.watch.init(&app.loop, gpa) catch {};
        ut.submit(app);
        if (!ut.running) return;
        app.loop.startTimer(&ut.timer, Loop.now() + desktop.first_frame_wait_ns, 0) catch return;
        ut.first = true;
    }

    pub fn deinit(ut: *UserTheme, app: *App) void {
        app.loop.cancelTimer(&ut.timer);
        ut.watch.deinit();
        ut.freeEntries();
        ut.free();
    }

    fn free(ut: *UserTheme) void {
        if (ut.home.len == 0 and ut.config.len == 0 and ut.file.len == 0) return;
        ut.gpa.free(ut.home);
        ut.gpa.free(ut.config);
        ut.gpa.free(ut.file);
        ut.home = &.{};
        ut.config = &.{};
        ut.file = &.{};
    }

    fn freeEntries(ut: *UserTheme) void {
        watch.free(ut.gpa, ut.entries);
        ut.entries = &.{};
    }

    fn submit(ut: *UserTheme, app: *App) void {
        if (ut.running) {
            ut.again = true;
            return;
        }
        app.pool.submit(&ut.job) catch return;
        ut.running = true;
    }

    fn appOf(ut: *UserTheme) *App {
        return @fieldParentPtr("user_theme", ut);
    }
};

fn env(name: [*:0]const u8) []const u8 {
    return std.mem.span(std.c.getenv(name) orelse return "");
}

fn onChange(w: *watch.Watch) void {
    const ut: *UserTheme = @fieldParentPtr("watch", w);
    ut.submit(ut.appOf());
}

fn onTimeout(timer: *Timer) void {
    const ut: *UserTheme = @fieldParentPtr("timer", timer);
    ut.first = false;
    ut.appOf().releaseFrames();
}

fn done(job: *Pool.Job) void {
    const ut: *UserTheme = @fieldParentPtr("job", job);
    const app = ut.appOf();
    ut.running = false;
    if (ut.watch.fd >= 0) ut.watch.setEntries(ut.entries) else ut.freeEntries();
    ut.entries = &.{};
    if (!ut.swapping and !ut.result.eql(&ut.value)) app.setUserTheme(&ut.result);
    if (ut.again) {
        ut.again = false;
        ut.submit(app);
    }
    if (ut.first) {
        ut.first = false;
        app.loop.cancelTimer(&ut.timer);
        app.releaseFrames();
    }
}

fn cancel(job: *Pool.Job) void {
    const ut: *UserTheme = @fieldParentPtr("job", job);
    ut.running = false;
    ut.freeEntries();
}

// On a worker ---------------------------------------------------------------

fn run(job: *Pool.Job) void {
    const ut: *UserTheme = @fieldParentPtr("job", job);
    var arena: std.heap.ArenaAllocator = .init(ut.gpa);
    defer arena.deinit();
    read(ut, arena.allocator()) catch {
        // Out of memory: no theme rather than part of one.
        ut.result = .{};
        ut.swapping = false;
    };
}

fn read(ut: *UserTheme, a: Allocator) Allocator.Error!void {
    // Watches go on first, so that a change after them is seen and one
    // before them is read.
    const omarchy_roots = [_][]const u8{ "/.local/state/omarchy/current", "/.config/omarchy/current" };
    var dirs: std.ArrayList(watch.Dir) = .empty;
    const path: ?[:0]const u8 = if (ut.file.len != 0) try a.dupeSentinel(u8, ut.file, 0) else if (ut.lookup) try std.fmt.allocPrintSentinel(a, "{s}/siv/theme.toml", .{ut.config}, 0) else null;
    const colors_file = if (path) |p| std.mem.eql(u8, std.fs.path.basename(p), "colors.toml") else false;
    if (path) |p| try watchFile(a, &dirs, p);
    var roots: [omarchy_roots.len][]const u8 = undefined;
    for (&roots, omarchy_roots) |*r, suffix| {
        r.* = try std.fmt.allocPrint(a, "{s}{s}", .{ ut.home, suffix });
        if (!colors_file) try watchFile(a, &dirs, try std.fmt.allocPrint(a, "{s}/theme/colors.toml", .{r.*}));
    }
    if (ut.watch.fd >= 0) ut.entries = try watch.arm(ut.watch.fd, ut.gpa, dirs.items);

    ut.swapping = false;
    var file: ?user_theme.File = null;
    if (path) |p| if (try readFile(a, p)) |src| {
        if (colors_file) {
            ut.result = user_theme.omarchy(src, exists(try std.fmt.allocPrintSentinel(a, "{s}/light.mode", .{std.fs.path.dirname(p) orelse "."}, 0)));
            return;
        }
        file = user_theme.parseFile(src);
    };
    var result: ui.theme.User = .{};
    if (if (file) |f| f.omarchy else ut.lookup and ut.file.len == 0) {
        for (roots) |root| {
            if (try readFile(a, try std.fmt.allocPrintSentinel(a, "{s}/theme/colors.toml", .{root}, 0))) |src| {
                result = user_theme.omarchy(src, exists(try std.fmt.allocPrintSentinel(a, "{s}/theme/light.mode", .{root}, 0)));
                ut.swapping = false;
                break;
            }
            if (exists(try std.fmt.allocPrintSentinel(a, "{s}/next-theme", .{root}, 0))) ut.swapping = true;
        }
    }
    if (file) |f| result = if (f.omarchy) user_theme.overlay(result, f.theme) else f.theme;
    ut.result = result;
}

/// Watches `path` through its directory and the directory's parent.
fn watchFile(a: Allocator, dirs: *std.ArrayList(watch.Dir), path: []const u8) Allocator.Error!void {
    const dir = std.fs.path.dirname(path) orelse return;
    const names = try a.alloc([]const u8, 2);
    names[0] = try a.dupe(u8, std.fs.path.basename(path));
    names[1] = "light.mode";
    try dirs.append(a, .{ .path = try a.dupeSentinel(u8, dir, 0), .names = names });
    const parent = std.fs.path.dirname(dir) orelse return;
    const child = try a.alloc([]const u8, 1);
    child[0] = try a.dupe(u8, std.fs.path.basename(dir));
    try dirs.append(a, .{ .path = try a.dupeSentinel(u8, parent, 0), .names = child, .files = false });
}

fn exists(path: [:0]const u8) bool {
    return linux.errno(linux.faccessat(linux.AT.FDCWD, path, linux.F_OK, 0)) == .SUCCESS;
}

/// The file, or null if it cannot be read or is too large to be a theme.
fn readFile(a: Allocator, path: [:0]const u8) Allocator.Error!?[]u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const buf = try a.alloc(u8, user_theme.max_bytes + 1);
    var n: usize = 0;
    while (n < buf.len) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        switch (linux.errno(r)) {
            .SUCCESS => if (r == 0) break else {
                n += r;
            },
            .INTR => {},
            else => return null,
        }
    }
    return if (n > user_theme.max_bytes) null else buf[0..n];
}
