//! Runs the guide's samples on the headless backend (D24) and drives
//! them: the C and Zig samples call guide_app_create, guide_window_create,
//! guide_app_run, and guide_app_dispatch in place of siv's (see
//! ../build_steps.zig), which pick the headless backend and the test
//! fonts, record the sample's windows, and run the test's scenario when
//! the sample hands control to siv. Scenarios drive the sample through
//! siv's public test API (siv_test_*, D27), as an application's own tests
//! would, and compare windows with the guide's screenshots in
//! docs/guide/images.

const std = @import("std");
const siv = @import("siv");
const text = @import("text");
const lua = @import("lua");
const png = @import("png");

const testing = std.testing;
const t = siv;

pub const images = "docs/guide/images";
const failure_dir = ".zig-cache/golden-failures";

pub fn ok(r: t.Result) !void {
    if (r == .ok) return;
    std.debug.print("unexpected {s}\n", .{siv.c.siv_result_name(r)});
    return error.Unexpected;
}

/// What a test does once the sample has built its window and handed
/// control to siv.
pub const Scenario = *const fn (g: *Guide) anyerror!void;

pub const Role = siv.Role;
pub const Node = siv.TestNode;

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
    name_buf: [256]u8 = undefined,

    /// The first window the sample created.
    pub fn window(g: *Guide) t.Window {
        return g.windows[0];
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

    /// Dispatches until the application is idle: frames presented,
    /// nothing loading, no job, paste, or drop in flight.
    pub fn settle(g: *Guide) !void {
        if (!try siv.testSettle(g.app, 10_000)) return error.Timeout;
    }

    pub fn pointer(g: *Guide, w: t.Window, x: f32, y: f32, button: ?bool) !void {
        try siv.testPointerMove(w, x, y);
        if (button) |pressed| try siv.testPointerButton(w, .primary, pressed);
        try g.settle();
    }

    pub fn clickIn(g: *Guide, w: t.Window, x: f32, y: f32) !void {
        try siv.testClick(w, x, y, .primary);
        try g.settle();
    }

    pub fn click(g: *Guide, x: f32, y: f32) !void {
        try g.clickIn(g.window(), x, y);
    }

    /// A secondary (right) click.
    pub fn rightClick(g: *Guide, x: f32, y: f32) !void {
        try siv.testClick(g.window(), x, y, .secondary);
        try g.settle();
    }

    pub fn keyIn(g: *Guide, w: t.Window, keysym: u32, chars: []const u8, mods: siv.Modifiers) !void {
        try siv.testKey(w, @enumFromInt(@as(i32, @intCast(keysym))), mods, chars);
        try g.settle();
    }

    pub fn key(g: *Guide, keysym: u32, chars: []const u8, mods: siv.Modifiers) !void {
        try g.keyIn(g.window(), keysym, chars, mods);
    }

    pub fn typeText(g: *Guide, s: []const u8) !void {
        try siv.testType(g.window(), s);
        try g.settle();
    }

    /// Asks to close a window, as a click on its close button does.
    pub fn close(g: *Guide, w: t.Window) !void {
        try siv.testClose(w);
        try g.settle();
    }

    /// The newest popup that is shown (a menu, a popover), if any.
    pub fn popup(g: *Guide) !?t.Window {
        const w = siv.testGetPopup(g.app);
        return if (w == .null) null else w;
    }

    /// Another application drags `data` over the main window to (x, y)
    /// and drops it there.
    pub fn dropFromElsewhere(g: *Guide, mime: []const u8, data: []const u8, x: f32, y: f32) !void {
        try siv.testDrop(g.window(), x, y, mime, data);
        try g.settle();
    }

    fn query(g: *Guide, q: siv.TestQuery.Options) !?Node {
        var found = false;
        var node: Node = .{};
        try siv.testFind(g.window(), q, &found, &node);
        return if (found) node else null;
    }

    /// The first node of the main window with `role` and `name`, as
    /// assistive technology sees it.
    pub fn find(g: *Guide, role: Role, name: []const u8) !Node {
        return try g.query(.{ .role = role, .name = name }) orelse {
            std.debug.print("no {t} named \"{s}\"\n", .{ role, name });
            try g.printTree();
            return error.NotFound;
        };
    }

    /// The `n`th node (from 0) of the main window with `role`.
    pub fn nth(g: *Guide, role: Role, n: u32) !Node {
        return try g.query(.{ .role = role, .index = n }) orelse error.NotFound;
    }

    /// The middle of a node.
    pub fn middle(node: Node) [2]f32 {
        const b = node.bounds;
        return .{ b.x + b.width / 2, b.y + b.height / 2 };
    }

    /// The middle of the node with `role` and `name`.
    pub fn center(g: *Guide, role: Role, name: []const u8) ![2]f32 {
        return middle(try g.find(role, name));
    }

    /// Clicks the middle of a node.
    pub fn clickNode(g: *Guide, node: Node) !void {
        const p = middle(node);
        try g.click(p[0], p[1]);
    }

    /// Rests the pointer on the middle of the node with `role` and `name`;
    /// settling waits for its tooltip, if it has one.
    pub fn hover(g: *Guide, role: Role, name: []const u8) !void {
        const p = try g.center(role, name);
        try g.pointer(g.window(), p[0], p[1], null);
    }

    /// Clicks the middle of the node with `role` and `name`.
    pub fn clickOn(g: *Guide, role: Role, name: []const u8) !void {
        try g.clickNode(try g.find(role, name));
    }

    /// The accessible name of the focused node.
    pub fn focusedName(g: *Guide) ![]const u8 {
        const len = try siv.testGetName(g.window(), .{ .flags = .{ .focused = true } }, &g.name_buf);
        return g.name_buf[0..@min(len, g.name_buf.len)];
    }

    fn reads(g: *Guide, want: []const u8) !bool {
        return try g.query(.{ .name = want }) != null;
    }

    fn printTree(g: *Guide) !void {
        var buf: [16 << 10]u8 = undefined;
        const len = try siv.testDump(g.window(), &buf);
        std.debug.print("the window reads:\n{s}\n", .{buf[0..@min(len, buf.len)]});
    }

    /// Checks that a node of the main window reads `want`, as a screen
    /// reader reads it.
    pub fn expectText(g: *Guide, want: []const u8) !void {
        if (try g.reads(want)) return;
        std.debug.print("no node reads \"{s}\"; ", .{want});
        try g.printTree();
        return error.NotFound;
    }

    /// Dispatches until a node of the main window reads `want`, for work
    /// that finishes on other threads.
    pub fn waitText(g: *Guide, want: []const u8) !void {
        // Settling waits for siv's own work; the samples' threads finish
        // when they finish. About ten seconds at most.
        var tries: u32 = 0;
        while (!try g.reads(want)) : (tries += 1) {
            if (tries == 2000) return g.expectText(want);
            try ok(siv.c.siv_app_dispatch(g.app, 5));
        }
        try g.settle();
    }

    /// What a window presented last, as RGBA rows.
    pub fn capture(g: *Guide, w: t.Window) ![]u8 {
        var len: usize = 0;
        try siv.testCapture(w, &.{}, &len, &g.last_w, &g.last_h);
        const out = try testing.allocator.alloc(u8, len);
        errdefer testing.allocator.free(out);
        try siv.testCapture(w, out, &len, &g.last_w, &g.last_h);
        return out;
    }

    /// Compares the main window with docs/guide/images/<name>.png.
    pub fn expectImage(g: *Guide, name: []const u8) !void {
        return g.expectImageOf(g.window(), name);
    }

    pub fn expectImageOf(g: *Guide, w: t.Window, name: []const u8) !void {
        const got = try g.capture(w);
        defer testing.allocator.free(got);
        return g.expectPixels(got, name);
    }

    /// Compares the main window's tooltip with docs/guide/images/<name>.png.
    pub fn expectTooltip(g: *Guide, name: []const u8) !void {
        var len: usize = 0;
        try siv.testCaptureTooltip(g.window(), &.{}, &len, &g.last_w, &g.last_h);
        const got = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(got);
        try siv.testCaptureTooltip(g.window(), got, &len, &g.last_w, &g.last_h);
        return g.expectPixels(got, name);
    }

    fn expectPixels(g: *Guide, got: []const u8, name: []const u8) !void {
        const gpa = testing.allocator;
        const io = testing.io;
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
    for ([_][]const u8{ tf.latin, tf.arabic, tf.hebrew }) |font| try ok(siv.c.siv_app_add_font(app, "Droid", 5, font.ptr, font.len));
    try ok(siv.c.siv_app_set_default_font(app, "Droid", 5));
    try ok(siv.c.siv_app_add_icon_path(app, "test/icons/themes", 17));
    try ok(siv.c.siv_app_set_icon_theme(app, "SivTest", 7));
    try ok(siv.c.siv_app_set_theme(app, &.{ .scheme = .light }));
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
    const r = siv.c.siv_app_create(&d, out);
    if (r != .ok) return r;
    prepare(out.*) catch return .error_unavailable;
    guide.app = out.*;
    return .ok;
}

pub export fn guide_window_create(app: t.App, desc: ?*const t.WindowDesc, window: ?*t.Window) t.Result {
    const r = siv.c.siv_window_create(app, desc, window);
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
    return siv.c.siv_app_dispatch(app, timeout_ms);
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
