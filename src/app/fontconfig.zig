//! Fontconfig's configuration followed live (D19): when fonts.conf, a
//! conf.d entry, or another file Fontconfig read changes (`omarchy font
//! set` rewrites ~/.config/fontconfig/fonts.conf), Fontconfig loads again
//! on the worker pool and every window resolves its families again, so
//! `monospace` and `sans-serif` follow the user's choice in open windows.
//!
//! The watch (watch.zig) covers the directories of every configuration
//! file the last load read, and `$XDG_CONFIG_HOME/fontconfig` with its
//! conf.d even before they exist. Loads arm the watches first and read
//! after, so a change during a load is read by the next.

const std = @import("std");
const text = @import("text");
const loop_mod = @import("loop");
const watch = @import("watch.zig");
const app_mod = @import("app.zig");

const Allocator = std.mem.Allocator;
const Pool = loop_mod.Pool;
const App = app_mod.App;
const Database = text.fontconfig.Database;

pub const Fontconfig = struct {
    watch: watch.Watch = .{ .on_change = onChange },
    job: Pool.Job = .{ .run = run, .done = done, .cancel = cancel, .class = .blocking },
    running: bool = false,
    again: bool = false,
    /// The first job only adds watches, for the database the application
    /// loaded at creation.
    load: bool = false,
    gpa: Allocator = undefined,
    config: []u8 = &.{},
    /// The directories of the configuration files the last load read.
    dirs: [][:0]u8 = &.{},
    // The job's results, for `done`.
    result: ?Database = null,
    result_dirs: [][:0]u8 = &.{},
    entries: []const watch.Entry = &.{},

    /// Follows the configuration behind `database`.
    pub fn start(fc: *Fontconfig, app: *App, database: *const Database, config_home: ?[]const u8) void {
        const gpa = app.gpa;
        fc.gpa = gpa;
        const xdg = config_home orelse std.mem.span(std.c.getenv("XDG_CONFIG_HOME") orelse "");
        const home = std.mem.span(std.c.getenv("HOME") orelse "");
        fc.config = (if (xdg.len != 0) gpa.dupe(u8, xdg) else std.fmt.allocPrint(gpa, "{s}/.config", .{home})) catch return;
        fc.dirs = database.configDirs(gpa) catch return fc.deinit();
        fc.watch.init(&app.loop, gpa) catch return fc.deinit();
        fc.submit(app);
    }

    pub fn deinit(fc: *Fontconfig) void {
        fc.watch.deinit();
        watch.free(fc.gpa, fc.entries);
        fc.entries = &.{};
        freeDirs(fc.gpa, fc.dirs);
        freeDirs(fc.gpa, fc.result_dirs);
        fc.dirs = &.{};
        fc.result_dirs = &.{};
        if (fc.result) |*db| db.deinit();
        fc.result = null;
        if (fc.config.len != 0) fc.gpa.free(fc.config);
        fc.config = &.{};
    }

    fn submit(fc: *Fontconfig, app: *App) void {
        if (fc.running) {
            fc.again = true;
            return;
        }
        app.pool.submit(&fc.job) catch return;
        fc.running = true;
    }
};

fn freeDirs(gpa: Allocator, dirs: [][:0]u8) void {
    for (dirs) |d| gpa.free(d);
    gpa.free(dirs);
}

fn appOf(fc: *Fontconfig) *App {
    return @fieldParentPtr("fontconfig", fc);
}

fn onChange(w: *watch.Watch) void {
    const fc: *Fontconfig = @fieldParentPtr("watch", w);
    fc.load = true;
    fc.submit(appOf(fc));
}

fn done(job: *Pool.Job) void {
    const fc: *Fontconfig = @fieldParentPtr("job", job);
    const app = appOf(fc);
    fc.running = false;
    fc.watch.setEntries(fc.entries);
    fc.entries = &.{};
    if (fc.result) |db| {
        fc.result = null;
        freeDirs(fc.gpa, fc.dirs);
        fc.dirs = fc.result_dirs;
        fc.result_dirs = &.{};
        app.fonts.setDatabase(db);
        app.refreshText();
    }
    if (fc.again) {
        fc.again = false;
        fc.submit(app);
    }
}

fn cancel(job: *Pool.Job) void {
    const fc: *Fontconfig = @fieldParentPtr("job", job);
    fc.running = false;
}

// On a worker ---------------------------------------------------------------

fn run(job: *Pool.Job) void {
    const fc: *Fontconfig = @fieldParentPtr("job", job);
    var arena: std.heap.ArenaAllocator = .init(fc.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var dirs: std.ArrayList(watch.Dir) = .empty;
    addDirs(fc, a, &dirs, fc.dirs) catch return;
    fc.entries = watch.arm(fc.watch.fd, fc.gpa, dirs.items) catch &.{};
    if (!fc.load) return;
    var db = Database.init() catch return;
    const new_dirs = db.configDirs(fc.gpa) catch {
        db.deinit();
        return;
    };
    // Directories the new configuration reads that the old did not.
    dirs.clearRetainingCapacity();
    addDirs(fc, a, &dirs, new_dirs) catch {};
    const more = watch.arm(fc.watch.fd, fc.gpa, dirs.items) catch &.{};
    if (more.len != 0) {
        const all = std.mem.concat(fc.gpa, watch.Entry, &.{ fc.entries, more }) catch &.{};
        fc.gpa.free(more);
        if (all.len != 0) {
            fc.gpa.free(fc.entries);
            fc.entries = all;
        }
    }
    fc.result = db;
    fc.result_dirs = new_dirs;
}

/// `$XDG_CONFIG_HOME/fontconfig`, its conf.d, and their parents, then
/// `config_dirs`, each watched for configuration files.
fn addDirs(fc: *const Fontconfig, a: Allocator, dirs: *std.ArrayList(watch.Dir), config_dirs: []const [:0]u8) Allocator.Error!void {
    const conf: watch.Dir = .{ .path = "", .names = &.{"conf.d"}, .suffix = ".conf" };
    var d = conf;
    d.path = try std.fmt.allocPrintSentinel(a, "{s}/fontconfig", .{fc.config}, 0);
    try dirs.append(a, d);
    d.path = try std.fmt.allocPrintSentinel(a, "{s}/fontconfig/conf.d", .{fc.config}, 0);
    try dirs.append(a, d);
    try dirs.append(a, .{ .path = try a.dupeSentinel(u8, fc.config, 0), .names = &.{"fontconfig"}, .files = false });
    for (config_dirs) |p| {
        d.path = p;
        try dirs.append(a, d);
    }
}
