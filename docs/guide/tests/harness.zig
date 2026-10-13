//! Runs the guide's samples on the headless backend (D24) and drives
//! them: the C and Zig samples call guide_app_create, guide_window_create,
//! guide_app_run, and guide_app_dispatch in place of siv's (see
//! ../build_steps.zig), which pick the headless backend and the test
//! fonts, record the sample's windows, and run the test's scenario when
//! the sample hands control to siv. Scenarios inject input and compare
//! windows with the guide's screenshots in docs/guide/images.

const std = @import("std");
const abi = @import("abi");
const text = @import("text");
const platform = @import("platform");
const compositor = @import("compositor");
const ui = @import("ui");
const lua = @import("lua");
const png = @import("png");
const Loop = @import("loop").Loop;

const testing = std.testing;
const t = abi.types;
const A = abi.application;

pub const images = "docs/guide/images";
const failure_dir = ".zig-cache/golden-failures";

pub fn ok(r: t.Result) !void {
    if (r == .ok) return;
    std.debug.print("unexpected {s}\n", .{abi.siv_result_name(r)});
    return error.Unexpected;
}

/// What a test does once the sample has built its window and handed
/// control to siv.
pub const Scenario = *const fn (g: *Guide) anyerror!void;

pub const Guide = struct {
    app: t.App = .null,
    windows: [8]t.Window = @splat(.null),
    window_count: usize = 0,
    scenario: ?Scenario = null,
    ran: bool = false,
    err: ?anyerror = null,
    /// Size of the last capture.
    last_w: u32 = 0,
    last_h: u32 = 0,

    /// The first window the sample created.
    pub fn window(g: *Guide) t.Window {
        return g.windows[0];
    }

    fn internal(g: *Guide) !*A.App {
        return A.App.get(@backingInt(g.app));
    }

    fn win(_: *Guide, w: t.Window) !*A.Window {
        return A.App.window(@backingInt(w), A.window_tag);
    }

    fn runScenario(g: *Guide) void {
        if (g.ran) return;
        g.ran = true;
        const s = g.scenario orelse return;
        g.settle() catch |e| {
            g.err = e;
            return;
        };
        s(g) catch |e| {
            g.err = e;
        };
    }

    /// Dispatches until every shown window presented what it committed
    /// and nothing is loading, pasting, or dropping.
    pub fn settle(g: *Guide) !void {
        const self = try g.internal();
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        var idle: usize = 0;
        while (idle < 3) {
            if (Loop.now() > deadline) return error.Timeout;
            try ok(A.siv_app_dispatch(g.app, 2));
            const cb = &self.app.clipboard;
            var busy = self.app.fonts.loading() or self.app.icons.loading() or cb.transfers.items.len != 0 or cb.ready.items.len != 0;
            for (self.windows.items) |slot| if (slot) |w| {
                if (w.dead or !w.win.shown) continue;
                busy = busy or w.win.presented_seq == 0 or !w.win.settled();
            };
            idle = if (busy) 0 else idle + 1;
        }
    }

    /// Dispatches until `done` holds or `ms` milliseconds pass, for work
    /// on other threads (jobs, image loads).
    pub fn until(g: *Guide, ms: u64, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
        const deadline = Loop.now() + ms * std.time.ns_per_ms;
        while (!done(ctx)) {
            if (Loop.now() > deadline) return error.Timeout;
            try ok(A.siv_app_dispatch(g.app, 5));
        }
        try g.settle();
    }

    pub fn inject(g: *Guide, events: []const platform.Event) !void {
        const self = try g.internal();
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

    /// Runs `func(headless, ctx)` on the compositor thread, which owns
    /// the headless platform.
    pub fn onHeadless(g: *Guide, ctx: anytype, comptime func: fn (*platform.Headless, @TypeOf(ctx)) void) !void {
        const self = try g.internal();
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

    var serial: u32 = 10;

    pub fn pointer(g: *Guide, w: t.Window, x: f64, y: f64, button: ?bool) !void {
        const id = (try g.win(w)).win.id;
        serial += 1;
        if (button) |pressed| {
            try g.inject(&.{
                .{ .pointer_motion = .{ .window = id, .seat = 0, .x = x, .y = y } },
                .{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = pressed, .time = serial, .serial = serial } },
            });
        } else try g.inject(&.{.{ .pointer_motion = .{ .window = id, .seat = 0, .x = x, .y = y } }});
        try g.settle();
    }

    pub fn clickIn(g: *Guide, w: t.Window, x: f64, y: f64) !void {
        try g.pointer(w, x, y, true);
        try g.pointer(w, x, y, false);
    }

    pub fn click(g: *Guide, x: f64, y: f64) !void {
        try g.clickIn(g.window(), x, y);
    }

    pub fn keyIn(g: *Guide, w: t.Window, keysym: u32, chars: []const u8, mods: platform.Mods) !void {
        const id = (try g.win(w)).win.id;
        serial += 1;
        var k: platform.Key = .{ .window = id, .seat = 0, .keycode = 0, .keysym = keysym, .state = .pressed, .mods = mods, .time = serial, .serial = serial };
        @memcpy(k.text_buf[0..chars.len], chars);
        k.text_len = @intCast(chars.len);
        var up = k;
        up.state = .released;
        up.text_len = 0;
        try g.inject(&.{ .{ .key = k }, .{ .key = up } });
        try g.settle();
    }

    pub fn key(g: *Guide, keysym: u32, chars: []const u8, mods: platform.Mods) !void {
        try g.keyIn(g.window(), keysym, chars, mods);
    }

    pub fn typeText(g: *Guide, s: []const u8) !void {
        for (s) |ch| try g.key(ch, &.{ch}, .{});
    }

    /// Asks to close a window, as a click on its close button does.
    pub fn close(g: *Guide, w: t.Window) !void {
        try g.inject(&.{.{ .close_requested = (try g.win(w)).win.id }});
        try g.settle();
    }

    /// The newest popup that is shown (a menu, a popover), if any.
    pub fn popup(g: *Guide) !?t.Window {
        const self = try g.internal();
        var found: ?t.Window = null;
        for (self.windows.items) |slot| if (slot) |w| {
            if (!w.dead and w.parent != null and w.win.shown) found = @fromBackingInt(w.handle);
        };
        return found;
    }

    /// A secondary (right) click.
    pub fn rightClick(g: *Guide, x: f64, y: f64) !void {
        const id = (try g.win(g.window())).win.id;
        serial += 1;
        try g.inject(&.{
            .{ .pointer_motion = .{ .window = id, .seat = 0, .x = x, .y = y } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x111, .pressed = true, .time = serial, .serial = serial } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x111, .pressed = false, .time = serial, .serial = serial + 1 } },
        });
        serial += 1;
        try g.settle();
    }

    /// The middle of the node with `role` and `name`.
    pub fn center(g: *Guide, role: Role, name: []const u8) ![2]f64 {
        const b = (try g.find(role, name)).bounds;
        return .{ (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2 };
    }

    /// Dispatches until a node of the main window reads `want`, for work
    /// that finishes on other threads.
    pub fn waitText(g: *Guide, want: []const u8) !void {
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        while (true) {
            try ok(A.siv_app_dispatch(g.app, 5));
            const tree = try g.semantics(g.window());
            for (tree.nodes.items) |n| if (std.mem.eql(u8, tree.name(n), want)) return g.settle();
            if (Loop.now() > deadline) return g.expectText(want);
        }
    }

    /// Another client drags `data` in `mimes` over the main window to
    /// (x, y) and drops it there.
    pub fn dropFromElsewhere(g: *Guide, mimes: []const []const u8, data: []const u8, x: f64, y: f64) !void {
        const D = struct {
            wid: platform.WindowId,
            mimes: []const []const u8,
            data: []const u8,
            x: f64,
            y: f64,
            fn offer(hl: *platform.Headless, d: *const @This()) void {
                hl.offerDrag(0, d.wid, d.mimes, d.data, .{ .copy = true }, d.x, d.y) catch unreachable;
            }
            fn drop(hl: *platform.Headless, _: *const @This()) void {
                hl.dropDrag(0);
            }
        };
        const d: D = .{ .wid = (try g.win(g.window())).win.id, .mimes = mimes, .data = data, .x = x, .y = y };
        try g.onHeadless(&d, D.offer);
        try g.settle();
        try g.onHeadless(&d, D.drop);
        try g.settle();
    }

    /// What assistive technology sees of a window.
    pub fn semantics(g: *Guide, w: t.Window) !*const ui.semantics.Tree {
        return (try g.win(w)).uiWin().semanticsTree();
    }

    pub const Role = @FieldType(ui.semantics.Node, "role");

    /// The first node of the main window with `role` and `name`, as
    /// assistive technology sees it.
    pub fn find(g: *Guide, role: Role, name: []const u8) !*const ui.semantics.Node {
        const tree = try g.semantics(g.window());
        return tree.find(role, name) orelse {
            std.debug.print("no {s} named \"{s}\"\n", .{ @tagName(role), name });
            return error.NotFound;
        };
    }

    /// The `n`th node (from 0) of the main window with `role`.
    pub fn nth(g: *Guide, role: Role, n: usize) !*const ui.semantics.Node {
        const tree = try g.semantics(g.window());
        var i: usize = 0;
        for (tree.nodes.items) |*node| if (node.role == role) {
            if (i == n) return node;
            i += 1;
        };
        return error.NotFound;
    }

    /// Clicks the middle of a node.
    pub fn clickNode(g: *Guide, node: *const ui.semantics.Node) !void {
        const b = node.bounds;
        try g.click((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2);
    }

    /// Clicks the middle of the node with `role` and `name`.
    pub fn clickOn(g: *Guide, role: Role, name: []const u8) !void {
        const b = (try g.find(role, name)).bounds;
        try g.click((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2);
    }

    /// The accessible name of the focused node.
    pub fn focusedName(g: *Guide) ![]const u8 {
        const tree = try g.semantics(g.window());
        const n = tree.focused() orelse return "";
        return tree.name(n.*);
    }

    /// The text of the first text node of the main window that starts
    /// with `prefix` (as a screen reader reads it).
    pub fn expectText(g: *Guide, want: []const u8) !void {
        const tree = try g.semantics(g.window());
        for (tree.nodes.items) |n| if (std.mem.eql(u8, tree.name(n), want)) return;
        std.debug.print("no node reads \"{s}\"; the window reads:\n", .{want});
        for (tree.nodes.items) |n| std.debug.print("  {s} \"{s}\"\n", .{ @tagName(n.role), tree.name(n) });
        return error.NotFound;
    }

    /// What a window presented last, as RGBA rows.
    pub fn capture(g: *Guide, w: t.Window) ![]u8 {
        const self = try g.internal();
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
        var ctx: Ctx = .{ .id = (try g.win(w)).win.id };
        try self.app.comp.call(&ctx, Ctx.run);
        g.last_w = ctx.w;
        g.last_h = ctx.h;
        return ctx.out;
    }

    /// Compares the main window with docs/guide/images/<name>.png.
    pub fn expectImage(g: *Guide, name: []const u8) !void {
        return g.expectImageOf(g.window(), name);
    }

    pub fn expectImageOf(g: *Guide, w: t.Window, name: []const u8) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        const got = try g.capture(w);
        defer gpa.free(got);
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ images, name });
        defer gpa.free(path);
        if (testing.environ.getPosix("SIV_UPDATE_GOLDEN") != null) {
            const bytes = try png.encode(gpa, g.last_w, g.last_h, got);
            defer gpa.free(bytes);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
            return;
        }
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |e| {
            std.debug.print("cannot read {s}: {t} (SIV_UPDATE_GOLDEN=1 writes it)\n", .{ path, e });
            return e;
        };
        defer gpa.free(bytes);
        const want = try png.decode(gpa, bytes);
        defer want.deinit(gpa);
        try testing.expectEqual(want.width, g.last_w);
        try testing.expectEqual(want.height, g.last_h);
        // Every channel within 3, at most 0.5% of pixels off by more than 1.
        var worst: u8 = 0;
        var off: usize = 0;
        for (want.pixels, got) |a, b| {
            const d = if (a > b) a - b else b - a;
            worst = @max(worst, d);
            if (d > 1) off += 1;
        }
        if (worst <= 3 and off * 200 <= got.len / 4) return;
        std.debug.print("screenshot {s}: max channel difference {d}, {d} channels off by more than 1\n", .{ name, worst, off });
        try std.Io.Dir.cwd().createDirPath(io, failure_dir);
        const actual = try png.encode(gpa, g.last_w, g.last_h, got);
        defer gpa.free(actual);
        const out = try std.fmt.allocPrint(gpa, "{s}/guide-{s}-actual.png", .{ failure_dir, name });
        defer gpa.free(out);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = actual });
        return error.GoldenMismatch;
    }
};

/// The sample being run. One at a time: tests run in sequence.
pub var guide: Guide = .{};

/// The same setup for every application a sample makes, whatever the
/// language: the headless backend, the test fonts and icon theme instead
/// of the system's, no motion, and the light theme.
fn prepare(app: t.App) !void {
    const tf = text.font.test_fonts;
    for ([_][]const u8{ tf.latin, tf.arabic, tf.hebrew }) |font| try ok(A.siv_app_add_font(app, "Droid", 5, font.ptr, font.len));
    try ok(A.siv_app_set_default_font(app, "Droid", 5));
    try ok(abi.icon.siv_app_add_icon_path(app, "test/icons/themes", 17));
    try ok(abi.icon.siv_app_set_icon_theme(app, "SivTest", 7));
    try ok(abi.theme.siv_app_set_theme(app, &.{ .scheme = .light }));
}

pub export fn guide_app_create(desc: ?*const t.AppDesc, app: ?*t.App) t.Result {
    var d: t.AppDesc = if (desc) |p| p.* else .{};
    d.backend = .headless;
    d.flags.no_system_fonts = true;
    d.flags.no_system_icons = true;
    d.flags.reduced_motion = true;
    // No session bus: an application id would connect to the test
    // machine's.
    d.app_id = null;
    d.app_id_len = 0;
    const out = app orelse return .error_invalid_argument;
    const r = A.siv_app_create(&d, out);
    if (r != .ok) return r;
    prepare(out.*) catch return .error_unavailable;
    guide.app = out.*;
    return .ok;
}

pub export fn guide_window_create(app: t.App, desc: ?*const t.WindowDesc, window: ?*t.Window) t.Result {
    const r = A.siv_window_create(app, desc, window);
    if (r == .ok and guide.window_count < guide.windows.len) {
        guide.windows[guide.window_count] = window.?.*;
        guide.window_count += 1;
    }
    return r;
}

pub export fn guide_app_run(app: t.App) t.Result {
    _ = app;
    guide.runScenario();
    return if (guide.err == null) .ok else .error_unavailable;
}

pub export fn guide_app_dispatch(app: t.App, timeout_ms: i32) t.Result {
    guide.runScenario();
    return A.siv_app_dispatch(app, timeout_ms);
}

fn begin(scenario: Scenario) void {
    guide = .{ .scenario = scenario };
}

fn finish() !void {
    if (guide.err) |e| return e;
    if (!guide.ran) return error.ScenarioNotRun;
}

/// Runs a C sample's main with `scenario`.
pub fn runC(main: *const fn () callconv(.c) c_int, scenario: Scenario) !void {
    begin(scenario);
    const code = main();
    try finish();
    try testing.expectEqual(@as(c_int, 0), code);
}

/// Runs a C sample's main with arguments.
pub fn runCArgs(main: *const fn (c_int, [*]const ?[*:0]const u8) callconv(.c) c_int, args: []const ?[*:0]const u8, scenario: Scenario) !void {
    begin(scenario);
    const code = main(@intCast(args.len), args.ptr);
    try finish();
    try testing.expectEqual(@as(c_int, 0), code);
}

/// Runs a Zig sample's main with `scenario`.
pub fn runZig(comptime sample: type, scenario: Scenario) !void {
    begin(scenario);
    try sample.main();
    try finish();
}

// Lua ---------------------------------------------------------------------

const lc = lua.c_api;

const lua_setup =
    \\local siv = require("siv")
    \\captured = {}
    \\local create = siv.app_create
    \\siv.app_create = function(desc)
    \\  if captured.app then return captured.app end
    \\  desc = desc or {}
    \\  desc.backend = "headless"
    \\  desc.flags = { "no_system_fonts", "no_system_icons", "reduced_motion" }
    \\  desc.app_id = nil
    \\  local app = create(desc)
    \\  captured.app = app
    \\  guide_prepare(app)
    \\  return app
    \\end
    \\local window_create = siv.methods.app.window_create
    \\siv.methods.app.window_create = function(app, desc)
    \\  local w = window_create(app, desc)
    \\  captured.windows = captured.windows or {}
    \\  table.insert(captured.windows, w)
    \\  return w
    \\end
    \\siv.window_create = siv.methods.app.window_create
    \\local function run() end
    \\siv.methods.app.run = run
    \\siv.run = run
;

fn luaPrepare(L: ?*lc.lua_State) callconv(.c) c_int {
    const app: t.App = @fromBackingInt(@intCast(lua.toHandle(L.?, 1)));
    prepare(app) catch return lc.luaL_error(L, "guide: cannot prepare the application");
    return 0;
}

fn luaCall(L: *lc.lua_State, nargs: c_int) !void {
    if (lc.lua_pcallk(L, nargs, 0, 0, 0, null) != 0) {
        lua.printError(L, -1);
        lc.lua_settop(L, -2);
        return error.LuaError;
    }
}

fn luaLoad(L: *lc.lua_State, script: []const u8, name: [*:0]const u8) !void {
    if (lc.luaL_loadbufferx(L, script.ptr, script.len, name, "t") != 0) {
        std.debug.print("{s}\n", .{lc.lua_tolstring(L, -1, null)});
        return error.LuaSyntax;
    }
}

/// Runs a Lua sample, as siv-lua runs a main chunk, then `scenario`.
pub fn runLua(path: [:0]const u8, scenario: Scenario) !void {
    begin(scenario);
    const L = lua.siv_lua_new(~@as(c_int, 0)) orelse return error.OutOfMemory;
    defer lc.lua_close(L);
    lc.lua_pushcclosure(L, luaPrepare, 0);
    lc.lua_setglobal(L, "guide_prepare");
    try luaLoad(L, lua_setup, "=setup");
    try luaCall(L, 0);
    _ = lc.lua_getfield(L, lc.LUA_REGISTRYINDEX, "siv.internal");
    _ = lc.lua_getfield(L, -1, "run_main");
    lc.lua_rotate(L, -2, -1);
    lc.lua_settop(L, -2);
    _ = lc.lua_pushstring(L, path.ptr);
    lc.lua_pushboolean(L, 0);
    try luaCall(L, 2);
    _ = lc.lua_getglobal(L, "captured");
    _ = lc.lua_getfield(L, -1, "app");
    guide.app = @fromBackingInt(@intCast(lua.toHandle(L, -1)));
    lc.lua_settop(L, -2);
    _ = lc.lua_getfield(L, -1, "windows");
    var i: c_int = 1;
    while (guide.window_count < guide.windows.len) : (i += 1) {
        if (lc.lua_geti(L, -1, i) == lc.LUA_TNIL) break;
        guide.windows[guide.window_count] = @fromBackingInt(@intCast(lua.toHandle(L, -1)));
        guide.window_count += 1;
        lc.lua_settop(L, -2);
    }
    lc.lua_settop(L, 0);
    guide.runScenario();
    try finish();
}
