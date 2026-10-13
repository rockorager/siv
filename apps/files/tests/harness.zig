//! The file manager on siv's headless backend: the real loop, input
//! injected as the compositor would deliver it, and frames compared with
//! golden images (D24). Mirrors test/abi/harness.zig, which lives outside
//! this module's tree.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-files

const std = @import("std");
const linux = std.os.linux;
const abi = @import("abi");
const text = @import("text");
const platform = @import("platform");
const compositor = @import("compositor");
const Loop = @import("loop").Loop;
const png = @import("png");
pub const Files = @import("files");

const testing = std.testing;
const t = abi.types;
const A = abi.application;

pub const golden_dir = "apps/files/tests/golden";
const failure_dir = ".zig-cache/golden-failures";

pub fn ok(r: t.Result) !void {
    if (r == .ok) return;
    std.debug.print("unexpected {s}\n", .{abi.siv_result_name(r)});
    return error.Unexpected;
}

pub const ks = struct {
    pub const backspace: u32 = 0xff08;
    pub const tab: u32 = 0xff09;
    pub const @"return": u32 = 0xff0d;
    pub const escape: u32 = 0xff1b;
    pub const home: u32 = 0xff50;
    pub const left: u32 = 0xff51;
    pub const up: u32 = 0xff52;
    pub const right: u32 = 0xff53;
    pub const down: u32 = 0xff54;
    pub const end: u32 = 0xff57;
    pub const menu: u32 = 0xff67;
    pub const f2: u32 = 0xffbf;
    pub const delete: u32 = 0xffff;
    pub const space: u32 = 0x20;
};

/// A folder of files with fixed sizes and times, removed afterwards.
pub const Fixture = struct {
    buf: [128]u8 = undefined,
    path: [:0]const u8 = "",

    pub const Item = struct { name: []const u8, size: usize = 0, dir: bool = false, mtime: i64 = 1_791_900_300 };

    pub fn create(f: *Fixture, items: []const Item) !void {
        const S = struct {
            extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
        };
        const tmpl = try std.fmt.bufPrintSentinel(&f.buf, "/tmp/siv-files-XXXXXX", .{}, 0);
        _ = S.mkdtemp(tmpl.ptr) orelse return error.Unexpected;
        f.path = tmpl;
        for (items) |it| try f.add(it);
    }

    pub fn add(f: *Fixture, it: Item) !void {
        var buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ f.path, it.name }, 0);
        if (it.dir) {
            if (linux.errno(linux.mkdirat(linux.AT.FDCWD, p, 0o755)) != .SUCCESS) return error.Unexpected;
        } else {
            const rc = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
            if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
            const fd: i32 = @intCast(rc);
            defer _ = linux.close(fd);
            var chunk: [4096]u8 = @splat('x');
            var left = it.size;
            while (left > 0) {
                const n = @min(left, chunk.len);
                _ = linux.write(fd, &chunk, n);
                left -= n;
            }
        }
        const ts = [2]linux.timespec{ .{ .sec = it.mtime, .nsec = 0 }, .{ .sec = it.mtime, .nsec = 0 } };
        _ = linux.utimensat(linux.AT.FDCWD, p, &ts, 0);
    }

    pub fn exists(f: *const Fixture, name: []const u8) bool {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ f.path, name }, 0) catch return false;
        var st: linux.Statx = undefined;
        return linux.errno(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) == .SUCCESS;
    }

    pub fn remove(f: *Fixture) void {
        if (f.path.len == 0) return;
        var buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintSentinel(&buf, "rm -rf '{s}'", .{f.path}, 0) catch return;
        const S = struct {
            extern "c" fn system(cmd: [*:0]const u8) c_int;
        };
        _ = S.system(cmd.ptr);
    }
};

pub const Harness = struct {
    app: t.App = .null,
    files: ?*Files = null,
    golden: []const u8 = golden_dir,
    closed: bool = false,
    /// Settle without waiting for file operations (a test holding one).
    ignore_ops: bool = false,
    last_w: u32 = 0,
    last_h: u32 = 0,

    pub const Start = struct {
        path: []const u8,
        /// Empty: the folder itself, so breadcrumbs read "Home" whatever the
        /// temporary path.
        home: []const u8 = "",
        width: u32 = 900,
        height: u32 = 560,
        mode: Files.ViewMode = .list,
        rtl: bool = false,
        scheme: t.ColorScheme = .light,
        thumbnails: bool = false,
        config_home: ?[]const u8 = "/nonexistent-config",
        data_home: ?[]const u8 = null,
        watch: bool = false,
    };

    fn onClosed(files: *Files) void {
        _ = files;
    }

    pub fn start(h: *Harness, s: Start) !void {
        try ok(A.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true, .reduced_motion = true, .rtl = s.rtl } }, &h.app));
        const tf = text.font.test_fonts;
        for ([_][]const u8{ tf.latin, tf.arabic, tf.hebrew }) |font| try ok(A.siv_app_add_font(h.app, "Droid", 5, font.ptr, font.len));
        try ok(A.siv_app_set_default_font(h.app, "Droid", 5));
        try ok(abi.theme.siv_app_set_theme(h.app, &.{ .scheme = s.scheme }));
        h.files = try Files.create(@enumFromInt(@intFromEnum(h.app)), .{
            .gpa = std.heap.c_allocator,
            .path = s.path,
            .home = if (s.home.len == 0) s.path else s.home,
            .config_home = s.config_home,
            .data_home = s.data_home orelse s.path,
            .width = s.width,
            .height = s.height,
            .mode = s.mode,
            .thumbnails = s.thumbnails,
            .watch = s.watch,
            .on_closed = onClosed,
        });
        try h.settle();
    }

    /// Runs the loop until `done(h)` or the deadline.
    pub fn until(h: *Harness, ms: u64, comptime done: fn (*Harness) bool) !void {
        const deadline = Loop.now() + ms * std.time.ns_per_ms;
        while (!done(h)) {
            if (Loop.now() > deadline) return error.Timeout;
            try ok(A.siv_app_dispatch(h.app, 10));
        }
        try h.settle();
    }

    pub fn stop(h: *Harness) void {
        _ = A.siv_app_destroy(h.app);
        h.app = .null;
        h.files = null;
    }

    pub fn f(h: *Harness) *Files {
        return h.files.?;
    }

    fn internal(h: *Harness) !*A.App {
        return A.App.get(@backingInt(h.app));
    }

    pub fn window(h: *Harness) t.Window {
        return @enumFromInt(@intFromEnum(h.f().window));
    }

    fn win(h: *Harness) !*A.Window {
        return A.App.window(@backingInt(h.window()), A.window_tag);
    }

    /// Dispatches until listings, jobs, thumbnails, pastes, and frames
    /// are all done.
    pub fn settle(h: *Harness) !void {
        const self = try h.internal();
        const deadline = Loop.now() + 20 * std.time.ns_per_s;
        var idle: usize = 0;
        while (idle < 3) {
            if (Loop.now() > deadline) return error.Timeout;
            try ok(A.siv_app_dispatch(h.app, 2));
            const cb = &self.app.clipboard;
            var busy = self.app.fonts.loading() or cb.transfers.items.len != 0 or cb.ready.items.len != 0;
            if (h.files) |fl| busy = busy or fl.loading != null or (fl.ops.items.len != 0 and !h.ignore_ops) or fl.thumbs.busy() or fl.reload_timer != .null or fl.thumbs.notify_timer != .null;
            for (self.windows.items) |slot| if (slot) |w| {
                if (w.dead or !w.win.shown) continue;
                busy = busy or w.win.presented_seq == 0 or !w.win.settled();
            };
            idle = if (busy) 0 else idle + 1;
        }
    }

    pub fn inject(h: *Harness, events: []const platform.Event) !void {
        const self = try h.internal();
        const Ctx = struct {
            events: []const platform.Event,
            pub fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                for (c.events) |ev| comp.platform.headless.inject(ev);
            }
        };
        var ctx: Ctx = .{ .events = events };
        try self.app.comp.call(&ctx, Ctx.run);
    }

    var serial: u32 = 100;

    pub fn click(h: *Harness, x: f64, y: f64) !void {
        try h.clickButton(x, y, 0x110, .{});
    }

    pub fn clickButton(h: *Harness, x: f64, y: f64, button: u32, mods: platform.Mods) !void {
        const id = (try h.win()).win.id;
        if (@as(u8, @bitCast(mods)) != 0) try h.inject(&.{.{ .modifiers = .{ .window = id, .seat = 0, .mods = mods } }});
        serial += 2;
        try h.inject(&.{
            .{ .pointer_motion = .{ .window = id, .seat = 0, .x = x, .y = y } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = button, .pressed = true, .time = serial, .serial = serial } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = button, .pressed = false, .time = serial + 1, .serial = serial + 1 } },
        });
        if (@as(u8, @bitCast(mods)) != 0) try h.inject(&.{.{ .modifiers = .{ .window = id, .seat = 0, .mods = .{} } }});
        try h.settle();
    }

    pub fn key(h: *Harness, keysym: u32, chars: []const u8, mods: platform.Mods) !void {
        try h.keyIn(h.window(), keysym, chars, mods);
    }

    pub fn keyIn(h: *Harness, window_h: t.Window, keysym: u32, chars: []const u8, mods: platform.Mods) !void {
        const id = (try A.App.window(@backingInt(window_h), A.window_tag)).win.id;
        serial += 2;
        var k: platform.Key = .{ .window = id, .seat = 0, .keycode = 0, .keysym = keysym, .state = .pressed, .mods = mods, .time = serial, .serial = serial };
        @memcpy(k.text_buf[0..chars.len], chars);
        k.text_len = @intCast(chars.len);
        var up = k;
        up.state = .released;
        up.text_len = 0;
        try h.inject(&.{ .{ .modifiers = .{ .window = id, .seat = 0, .mods = mods } }, .{ .key = k }, .{ .key = up }, .{ .modifiers = .{ .window = id, .seat = 0, .mods = .{} } } });
        try h.settle();
    }

    pub fn typeText(h: *Harness, s: []const u8) !void {
        for (s) |ch| try h.key(ch, &.{ch}, .{});
    }

    /// The popups shown, newest last.
    pub fn popups(h: *Harness, out: []t.Window) !usize {
        const self = try h.internal();
        var n: usize = 0;
        for (self.windows.items) |slot| if (slot) |w| {
            if (w.dead or !w.win.shown or w.win.state.popup == null) continue;
            if (n < out.len) {
                out[n] = @enumFromInt(w.handle);
                n += 1;
            }
        };
        return n;
    }

    /// Where the compositor placed a popup, in window coordinates.
    pub fn popupAt(h: *Harness, popup: t.Window) ![2]i32 {
        _ = h;
        const p = (try A.App.window(@backingInt(popup), A.window_tag)).win.state.popup orelse return error.NotAPopup;
        return .{ p.x, p.y };
    }

    /// The semantics tree of the main window, for assertions about what a
    /// screen reader is told.
    pub fn semantics(h: *Harness) !*const @import("ui").semantics.Tree {
        return (try h.win()).uiWin().semanticsTree();
    }

    /// Runs `func(headless, ctx)` on the compositor thread, which owns the
    /// headless platform.
    pub fn onHeadless(h: *Harness, ctx: anytype, comptime func: fn (*platform.Headless, @TypeOf(ctx)) void) !void {
        const self = try h.internal();
        const C = struct {
            inner: @TypeOf(ctx),
            fn run(p: ?*anyopaque, comp: *compositor.Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(p));
                func(comp.platform.headless, s.inner);
            }
        };
        var cx: C = .{ .inner = ctx };
        try self.app.comp.call(&cx, C.run);
    }

    /// Reads a pipe another client got, dispatching meanwhile so that the
    /// application writes it.
    pub fn readPipe(h: *Harness, fd: i32, out: []u8) ![]u8 {
        defer _ = linux.close(fd);
        const flags = linux.fcntl(fd, linux.F.GETFL, 0);
        _ = linux.fcntl(fd, linux.F.SETFL, flags | @as(usize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
        var n: usize = 0;
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        while (true) {
            try ok(A.siv_app_dispatch(h.app, 5));
            const rc = linux.read(fd, out[n..].ptr, out.len - n);
            switch (linux.errno(rc)) {
                .SUCCESS => if (rc == 0) break else {
                    n += rc;
                },
                .AGAIN => {},
                else => return error.ReadFailed,
            }
            if (Loop.now() > deadline) return error.Timeout;
        }
        return out[0..n];
    }

    /// What another client pasting the clipboard in `mime` reads.
    pub fn pasteElsewhere(h: *Harness, mime: []const u8, out: []u8) ![]u8 {
        const R = struct {
            mime: []const u8,
            fd: i32 = -1,
            fn f(hl: *platform.Headless, r: *@This()) void {
                r.fd = hl.requestSelection(0, .clipboard, r.mime) catch -1;
            }
        };
        var r: R = .{ .mime = mime };
        try h.onHeadless(&r, R.f);
        if (r.fd < 0) return error.NoSelection;
        return h.readPipe(r.fd, out);
    }

    /// Another client copies `data` in `mimes`.
    pub fn copyElsewhere(h: *Harness, mimes: []const []const u8, data: []const u8) !void {
        const O = struct {
            mimes: []const []const u8,
            data: []const u8,
            fn f(hl: *platform.Headless, o: *const @This()) void {
                hl.offerSelection(0, .clipboard, o.mimes, o.data) catch unreachable;
            }
        };
        try h.onHeadless(&O{ .mimes = mimes, .data = data }, O.f);
        try h.settle();
    }

    /// Another client drags `data` in `mimes` over the window to (x, y)
    /// and drops it there.
    pub fn dropFromElsewhere(h: *Harness, mimes: []const []const u8, data: []const u8, actions: platform.DragActions, x: f64, y: f64) !void {
        const D = struct {
            wid: platform.WindowId,
            mimes: []const []const u8,
            data: []const u8,
            actions: platform.DragActions,
            x: f64,
            y: f64,
            fn offer(hl: *platform.Headless, d: *const @This()) void {
                hl.offerDrag(0, d.wid, d.mimes, d.data, d.actions, d.x, d.y) catch unreachable;
            }
            fn drop(hl: *platform.Headless, _: *const @This()) void {
                hl.dropDrag(0);
            }
        };
        const d: D = .{ .wid = (try h.win()).win.id, .mimes = mimes, .data = data, .actions = actions, .x = x, .y = y };
        try h.onHeadless(&d, D.offer);
        try h.settle();
        try h.onHeadless(&d, D.drop);
        try h.settle();
    }

    /// Presses on the item named `name`, moves the pointer out of the
    /// window as a drag does, and lets another client take it in `mime`:
    /// returns what that client reads.
    pub fn dragOut(h: *Harness, name: []const u8, mime: []const u8, out: []u8) ![]u8 {
        const n = try h.item(name);
        const b = n.bounds;
        const id = (try h.win()).win.id;
        const x = (b.x0 + b.x1) / 2;
        const y = (b.y0 + b.y1) / 2;
        serial += 2;
        try h.inject(&.{
            .{ .pointer_motion = .{ .window = id, .seat = 0, .x = x, .y = y } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = true, .time = serial, .serial = serial } },
            .{ .pointer_motion = .{ .window = id, .seat = 0, .x = x + 20, .y = y + 12 } },
        });
        try h.settle();
        const O = struct {
            mime: []const u8,
            fd: i32 = -1,
            fn run(hl: *platform.Headless, o: *@This()) void {
                hl.leaveDrag(0);
                o.fd = (hl.dropOutside(0, o.mime, .copy) catch null) orelse -1;
            }
            fn finish(hl: *platform.Headless, _: *@This()) void {
                hl.finishOutside(0, .copy);
            }
        };
        var o: O = .{ .mime = mime };
        try h.onHeadless(&o, O.run);
        if (o.fd < 0) return error.NoDrag;
        const got = try h.readPipe(o.fd, out);
        try h.onHeadless(&o, O.finish);
        try h.settle();
        return got;
    }

    pub const Role = @FieldType(@import("ui").semantics.Node, "role");

    /// The center of the first node with `role` and `name`, in window
    /// coordinates, as assistive technology sees it.
    pub fn center(h: *Harness, role: Role, name: []const u8) ![2]f64 {
        const tree = try h.semantics();
        const n = tree.find(role, name) orelse {
            std.debug.print("no {s} named \"{s}\"\n", .{ @tagName(role), name });
            return error.NotFound;
        };
        const b = n.bounds;
        return .{ (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2 };
    }

    /// The file view's item named `name` (a table row's name starts with
    /// it, followed by its other cells).
    pub fn item(h: *Harness, name: []const u8) !*const @import("ui").semantics.Node {
        const tree = try h.semantics();
        for (tree.nodes.items, 0..) |*v, vi| {
            if (!((v.role == .table or v.role == .list) and std.mem.eql(u8, tree.name(v.*), "Files"))) continue;
            var i: u32 = @intCast(vi + 1);
            while (i < v.end) : (i += 1) {
                const n = &tree.nodes.items[i];
                if (n.role != .row and n.role != .list_item) continue;
                const nm = tree.name(n.*);
                if (std.mem.eql(u8, nm, name) or (std.mem.startsWith(u8, nm, name) and nm.len > name.len and nm[name.len] == ' ')) return n;
            }
        }
        std.debug.print("no item named \"{s}\"\n", .{name});
        return error.NotFound;
    }

    pub fn clickItem(h: *Harness, name: []const u8) !void {
        try h.clickItemWith(name, 0x110, .{});
    }

    pub fn clickItemWith(h: *Harness, name: []const u8, button: u32, mods: platform.Mods) !void {
        const n = try h.item(name);
        const b = n.bounds;
        try h.clickButton((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, button, mods);
    }

    pub fn clickOn(h: *Harness, role: Role, name: []const u8) !void {
        const p = try h.center(role, name);
        try h.click(p[0], p[1]);
    }

    /// The accessible name of the focused node.
    pub fn focusedName(h: *Harness) ![]const u8 {
        const tree = try h.semantics();
        const n = tree.focused() orelse return "";
        return tree.name(n.*);
    }

    /// The status line's text.
    pub fn status(h: *Harness, buf: []u8) []const u8 {
        var len: usize = 0;
        _ = t.c.siv_node_get_text(h.f().status, buf.ptr, buf.len, &len);
        return buf[0..@min(len, buf.len)];
    }

    /// The names of the view's items as shown, in order.
    pub fn shown(h: *Harness, out: [][]const u8) [][]const u8 {
        const fl = h.f();
        var n: usize = 0;
        for (fl.visible.items) |e| {
            if (n == out.len) break;
            out[n] = fl.listing.?.name(fl.listing.?.entries[e]);
            n += 1;
        }
        return out[0..n];
    }

    /// The names of the selected items.
    pub fn selected(h: *Harness, out: [][]const u8) ![][]const u8 {
        const fl = h.f();
        const sel = try fl.selectedIndices();
        defer fl.gpa.free(sel);
        var n: usize = 0;
        for (sel) |vi| {
            if (n == out.len) break;
            out[n] = fl.listing.?.name(fl.listing.?.entries[fl.visible.items[vi]]);
            n += 1;
        }
        return out[0..n];
    }

    pub fn capture(h: *Harness, window_h: t.Window) ![]u8 {
        const self = try h.internal();
        const Ctx = struct {
            id: platform.WindowId,
            out: anyerror![]u8 = error.NothingPresented,
            w: u32 = 0,
            h: u32 = 0,
            pub fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                const img = comp.platform.headless.presented(c.id) orelse return;
                const out = testing.allocator.alloc(u8, @as(usize, img.width) * img.height * 4) catch |e| {
                    c.out = e;
                    return;
                };
                for (0..img.height) |y| for (0..img.width) |x| {
                    const p = img.pixels[y * img.stride + x * 4 ..][0..4];
                    out[(y * img.width + x) * 4 ..][0..4].* = .{ p[2], p[1], p[0], p[3] };
                };
                c.w = img.width;
                c.h = img.height;
                c.out = out;
            }
        };
        var ctx: Ctx = .{ .id = (try A.App.window(@backingInt(window_h), A.window_tag)).win.id };
        try self.app.comp.call(&ctx, Ctx.run);
        h.last_w = ctx.w;
        h.last_h = ctx.h;
        return ctx.out;
    }

    pub fn expectGolden(h: *Harness, name: []const u8) !void {
        return h.expectGoldenOf(h.window(), name);
    }

    pub fn expectGoldenOf(h: *Harness, window_h: t.Window, name: []const u8) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        const got = try h.capture(window_h);
        defer gpa.free(got);
        const width = h.last_w;
        const height = h.last_h;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ h.golden, name });
        defer gpa.free(path);
        if (testing.environ.getPosix("SIV_UPDATE_GOLDEN") != null) {
            const bytes = try png.encode(gpa, width, height, got);
            defer gpa.free(bytes);
            try std.Io.Dir.cwd().createDirPath(io, h.golden);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
            return;
        }
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
        defer gpa.free(bytes);
        const want = try png.decode(gpa, bytes);
        defer want.deinit(gpa);
        try testing.expectEqual(width, want.width);
        try testing.expectEqual(height, want.height);
        var worst: u8 = 0;
        var off: usize = 0;
        for (want.pixels, got) |a, b| {
            const d = if (a > b) a - b else b - a;
            worst = @max(worst, d);
            if (d > 1) off += 1;
        }
        if (worst <= 3 and off * 200 <= got.len / 4) return;
        std.debug.print("golden {s}: max channel difference {d}, {d} channels off by more than 1\n", .{ name, worst, off });
        try std.Io.Dir.cwd().createDirPath(io, failure_dir);
        const actual = try png.encode(gpa, width, height, got);
        defer gpa.free(actual);
        const out = try std.fmt.allocPrint(gpa, "{s}/files-{s}-actual.png", .{ failure_dir, name });
        defer gpa.free(out);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = actual });
        return error.GoldenMismatch;
    }
};
