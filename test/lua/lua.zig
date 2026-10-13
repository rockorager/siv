//! Lua applications on the headless backend (D23, D24): the examples in
//! examples/*.lua run unchanged through libsiv-lua's binding, against the
//! exports in this binary, and their frames are compared with PNGs under
//! test/golden/lua/. siv.app_create is wrapped to pick the headless
//! backend and the test font, and app:run to return at once, so the test
//! drives the loop and injects input itself.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const lua = @import("lua");
const text = @import("text");
const harness = @import("../abi/harness.zig");

const c = lua.c_api;
const testing = std.testing;
const Harness = harness.Harness;

const golden_dir = "test/golden/lua";

const setup =
    \\local font, dark = ...
    \\local siv = require("siv")
    \\captured = {}
    \\local create = siv.app_create
    \\siv.app_create = function(desc)
    \\  if captured.app then return captured.app end
    \\  desc = desc or {}
    \\  desc.backend = "headless"
    \\  desc.flags = { "no_system_fonts", "reduced_motion" }
    \\  local app = create(desc)
    \\  app:add_font("Droid", font)
    \\  app:set_default_font("Droid")
    \\  app:set_theme{ scheme = dark and "dark" or "light" }
    \\  captured.app = app
    \\  return app
    \\end
    \\local window_create = siv.methods.app.window_create
    \\siv.methods.app.window_create = function(app, desc)
    \\  local w = window_create(app, desc)
    \\  captured.window = captured.window or w
    \\  return w
    \\end
    \\siv.window_create = siv.methods.app.window_create
    \\local function run() end
    \\siv.methods.app.run = run
    \\siv.run = run
    \\-- Image loads report when they finish, for tests to wait on.
    \\captured.loads = 0
    \\local image_load = siv.methods.app.image_load
    \\siv.methods.app.image_load = function(...)
    \\  local results = table.pack(pcall(image_load, ...))
    \\  captured.loads = captured.loads + 1
    \\  if not results[1] then error(results[2], 0) end
    \\  return table.unpack(results, 2, results.n)
    \\end
;

const LuaApp = struct {
    L: *c.lua_State,
    h: Harness,

    const Options = struct { dark: bool = false, arg: ?[:0]const u8 = null };

    fn start(path: [:0]const u8, o: Options) !LuaApp {
        const L = lua.siv_lua_new(~@as(c_int, 0)) orelse return error.OutOfMemory;
        errdefer c.lua_close(L);
        try load(L, setup, "=setup");
        _ = c.lua_pushlstring(L, text.font.test_fonts.latin.ptr, text.font.test_fonts.latin.len);
        c.lua_pushboolean(L, @intFromBool(o.dark));
        try call(L, 2);
        // The example, as siv-lua runs a main chunk.
        _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "siv.internal");
        _ = c.lua_getfield(L, -1, "run_main");
        c.lua_rotate(L, -2, -1);
        c.lua_settop(L, -2);
        _ = c.lua_pushstring(L, path.ptr);
        c.lua_pushboolean(L, 0);
        if (o.arg) |a| _ = c.lua_pushstring(L, a.ptr);
        try call(L, if (o.arg != null) 3 else 2);
        var self: LuaApp = .{ .L = L, .h = .{ .golden = golden_dir } };
        _ = c.lua_getglobal(L, "captured");
        _ = c.lua_getfield(L, -1, "app");
        self.h.app = @enumFromInt(lua.toHandle(L, -1));
        _ = c.lua_getfield(L, -2, "window");
        self.h.window = @enumFromInt(lua.toHandle(L, -1));
        c.lua_settop(L, 0);
        try testing.expect(@intFromEnum(self.h.app) != 0 and @intFromEnum(self.h.window) != 0);
        try self.h.settle();
        return self;
    }

    fn stop(self: *LuaApp) void {
        c.lua_close(self.L);
    }

    /// Runs a Lua snippet in the application's state.
    fn run(self: *LuaApp, script: []const u8) !void {
        try load(self.L, script, "=test");
        try call(self.L, 0);
    }

    fn load(L: *c.lua_State, script: []const u8, name: [*:0]const u8) !void {
        if (c.luaL_loadbufferx(L, script.ptr, script.len, name, "t") != 0) {
            std.debug.print("{s}\n", .{c.lua_tolstring(L, -1, null)});
            return error.LuaSyntax;
        }
    }

    fn call(L: *c.lua_State, nargs: c_int) !void {
        if (c.lua_pcallk(L, nargs, 0, 0, 0, null) != 0) {
            lua.printError(L, -1);
            c.lua_settop(L, -2);
            return error.LuaError;
        }
    }

    fn key(self: *LuaApp, keysym: u32, chars: []const u8) !void {
        try self.h.typeKey(keysym, chars, .{});
        try self.h.settle();
    }

    fn typeText(self: *LuaApp, s: []const u8) !void {
        for (s) |ch| try self.h.typeKey(ch, &.{ch}, .{});
        try self.h.settle();
    }
};

const key_return = 0xff0d;
const key_tab = 0xff09;
const key_right = 0xff53;

test "lua: hello.lua, clicked from the keyboard" {
    var app = try LuaApp.start("examples/hello.lua", .{});
    defer app.stop();
    try app.h.expectGolden("hello", 320, 200);
    // Tab reaches the button; Enter activates it.
    try app.key(key_tab, "");
    try app.key(key_return, "\r");
    try app.h.expectGolden("hello-clicked", 320, 200);
}

test "lua: todo.lua adds and removes items" {
    var app = try LuaApp.start("examples/todo.lua", .{});
    defer app.stop();
    try app.h.expectGolden("todo", 360, 420);
    try app.typeText("Milk");
    try app.h.expectGolden("todo-typed", 360, 420);
    try app.key(key_return, "\r");
    try app.h.expectGolden("todo-added", 360, 420);
    // Tab from the editor to the first item; Enter removes it.
    try app.key(key_tab, "");
    try app.key(key_return, "\r");
    try app.h.expectGolden("todo-removed", 360, 420);
}

test "lua: widgets.lua in the light and dark themes" {
    {
        var app = try LuaApp.start("examples/widgets.lua", .{});
        defer app.stop();
        try app.h.expectGolden("widgets", 420, 520);
    }
    var app = try LuaApp.start("examples/widgets.lua", .{ .dark = true });
    defer app.stop();
    try app.h.expectGolden("widgets-dark", 420, 520);
}

test "lua: gauge.lua draws on a canvas and takes keys" {
    var app = try LuaApp.start("examples/gauge.lua", .{});
    defer app.stop();
    try app.h.expectGolden("gauge", 260, 260);
    try app.key(key_right, "");
    try app.key(key_right, "");
    try app.h.expectGolden("gauge-50", 260, 260);
}

test "lua: viewer.lua loads an image from a coroutine" {
    var app = try LuaApp.start("examples/viewer.lua", .{ .arg = "test/abi/testdata/rgba.png" });
    defer app.stop();
    try app.run(
        \\for _ = 1, 500 do
        \\  if captured.loads > 0 then return end
        \\  captured.app:dispatch(10)
        \\end
        \\error("the image did not load")
    );
    try app.h.settle();
    try app.h.expectGolden("viewer", 640, 480);
}

test "lua: sketch.lua draws a pen's strokes from every sample, erases, and zooms" {
    var app = try LuaApp.start("examples/sketch.lua", .{});
    defer app.stop();
    const id = (try app.h.win()).win.id;
    // A pen stroke: down, then a wave of motions arriving between frames
    // with rising pressure, then up.
    var events: [42]@import("platform").Event = undefined;
    const pen: @import("platform").TabletTool = .{ .window = id, .seat = 0, .tool = 0, .axes = .{ .pressure = true }, .phase = .motion, .tip = true };
    for (&events, 0..) |*e, i| {
        var s = pen;
        const k: f64 = @floatFromInt(i);
        s.phase = if (i == 0) .down else if (i == events.len - 1) .up else .motion;
        s.x = 60 + k * 12;
        s.y = 120 + 40 * @sin(k / 4);
        s.pressure = k / @as(f64, events.len);
        s.tip = i != events.len - 1;
        e.* = .{ .tablet_tool = s };
    }
    try app.h.inject(&events);
    try app.h.settle();
    // The eraser end across the stroke.
    var eraser = pen;
    eraser.tool = 1;
    eraser.kind = .eraser;
    eraser.pressure = 1;
    var erase: [12]@import("platform").Event = undefined;
    for (&erase, 0..) |*e, i| {
        var s = eraser;
        s.phase = if (i == 0) .down else if (i == erase.len - 1) .up else .motion;
        s.x = 300;
        s.y = 60 + @as(f64, @floatFromInt(i)) * 12;
        s.tip = i != erase.len - 1;
        e.* = .{ .tablet_tool = s };
    }
    try app.h.inject(&erase);
    try app.h.settle();
    try app.h.expectGolden("sketch", 640, 480);
    // A pinch zooms the sheet about the pointer, on the compositor.
    const frames = try app.h.framesPresented();
    try app.h.inject(&.{
        .{ .pointer_motion = .{ .window = id, .seat = 0, .x = 60, .y = 120 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .begin, .fingers = 2 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .update, .fingers = 2, .scale = 2 } },
        .{ .gesture = .{ .window = id, .seat = 0, .kind = .pinch, .phase = .end, .fingers = 2 } },
    });
    try app.h.waitFrame(frames);
    try app.h.expectGolden("sketch-zoomed", 640, 480);
}

test "lua: hot reload of todo.lua keeps its window, items, and draft" {
    const io = testing.io;
    const dir = ".zig-cache/lua-hot-reload";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, "examples/todo.lua", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(source);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/todo.lua", .data = source });

    var app = try LuaApp.start(dir ++ "/todo.lua", .{});
    defer app.stop();
    try app.typeText("Milk");
    try app.key(key_return, "\r");
    try app.typeText("Eggs");
    // The new code: another heading. Reloading runs it in the running
    // application; the window is the same and shows the kept items and
    // the draft in the editor.
    const edited = try std.mem.replaceOwned(u8, testing.allocator, source, "txn:text(column, \"To do\"", "txn:text(column, \"Groceries\"");
    defer testing.allocator.free(edited);
    try testing.expect(!std.mem.eql(u8, edited, source));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/todo.lua", .data = edited });
    const window = app.h.window;
    try app.run(
        \\local siv = require("siv")
        \\siv.reload()
    );
    try app.h.settle();
    try testing.expectEqual(window, app.h.window);
    try app.h.expectGolden("todo-reloaded", 360, 420);
}
