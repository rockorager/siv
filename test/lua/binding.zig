//! The binding on the headless backend: Lua scripts run in a state from
//! siv_lua_new, as an embedding host would make one. The binding is
//! linked into the headless test binary as an object, over the exports
//! compiled into it (test/lua/api.zig); siv.so from the stock lua
//! interpreter covers it against libsiv.so (src/lua/build_steps.zig).

const std = @import("std");
const root = @import("lua");
const lua = root.helpers;
const c = lua.c;
const siv = @import("siv");
const dbus = @import("dbus");
const Loop = @import("loop").Loop;

const testing = std.testing;

fn newState() !*lua.State {
    return root.siv_lua_new(~@as(c_int, 0)) orelse error.OutOfMemory;
}

/// Runs `script` and returns its first result as an integer (0 if none).
fn runIn(L: *lua.State, script: []const u8) !i64 {
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    _ = c.lua_getfield(L, lua.registry, "siv.module");
    lua.pop(L, 1);
    lua.pushcfunction(L, struct {
        fn tb(Lq: ?*lua.State) callconv(.c) c_int {
            const Ls = Lq.?;
            if (c.lua_type(Ls, 1) == lua.ttable) {
                _ = c.lua_getfield(Ls, 1, "message");
                c.luaL_traceback(Ls, Ls, c.lua_tolstring(Ls, -1, null), 1);
                return 1;
            }
            c.luaL_traceback(Ls, Ls, c.luaL_tolstring(Ls, 1, null), 1);
            return 1;
        }
    }.tb);
    if (c.luaL_loadbufferx(L, script.ptr, script.len, "=test", "t") != lua.ok) {
        std.debug.print("{s}\n", .{lua.toString(L, -1).?});
        return error.LuaSyntax;
    }
    if (lua.pcall(L, 0, 1, top + 1) != lua.ok) {
        std.debug.print("{s}\n", .{lua.toString(L, -1) orelse "(error)"});
        return error.LuaError;
    }
    return c.lua_tointegerx(L, -1, null);
}

fn run(script: []const u8) !i64 {
    const L = try newState();
    defer c.lua_close(L);
    return runIn(L, script);
}

const prologue =
    \\local siv = require("siv")
    \\local app <close> = siv.app_create{ backend = "headless", flags = { "no_system_fonts", "reduced_motion" } }
    \\local font = assert(io.open("src/text/testdata/DroidSans.ttf", "rb"))
    \\app:add_font("Droid", font:read("a"))
    \\font:close()
    \\app:set_default_font("Droid")
    \\local win = app:window_create{ width = 120, height = 80 }
    \\
;

test "require adds no globals and the allowlist holds" {
    _ = try run(
        \\local before = {}
        \\for k in pairs(_G) do before[k] = true end
        \\local siv = require("siv")
        \\assert(type(siv) == "table" and siv == require("siv"))
        \\for k in pairs(_G) do assert(before[k], "new global " .. tostring(k)) end
        \\assert(_G.siv == nil and debug == nil)
        \\for _, lib in ipairs{ "coroutine", "table", "string", "math", "utf8", "os", "io", "package" } do
        \\  assert(_G[lib], lib)
        \\end
    );
    if (root.system_lua) return;
    _ = try run(
        \\local ok, err = package.loadlib("libc.so.6", "printf")
        \\assert(not ok and err:find("dynamic libraries not enabled"))
    );
}

test "a state can leave out libraries" {
    const L = root.siv_lua_new(1 | 2) orelse return error.OutOfMemory;
    defer c.lua_close(L);
    _ = try runIn(L,
        \\assert(io == nil and os == nil and string == nil)
        \\assert(require("siv").version() > 0)
    );
}

test "failed calls raise errors with the result code" {
    _ = try run(prologue ++
        \\local ok, err = pcall(function() return win:set_title(nil) end)
        \\assert(ok)
        \\ok, err = pcall(siv.window_set_title, nil, "x")
        \\assert(not ok and siv.is_error(err), tostring(err))
        \\assert(err.code == "invalid_handle" and err.result == -2 and err.func == "siv_window_set_title")
        \\assert(tostring(err):find("SIV_ERROR_INVALID_HANDLE"))
        \\-- A second transaction on one window is busy.
        \\local t1 <close> = win:txn_begin()
        \\ok, err = pcall(function() return win:txn_begin() end)
        \\assert(not ok and err.code == "busy")
        \\assert(tostring(err):find("^test:%d+: siv_txn_begin"), tostring(err))
        \\t1:abort()
        \\-- Type errors are Lua's.
        \\ok, err = pcall(win.set_title, win, 42)
        \\assert(not ok and type(err) == "string" and err:find("string expected, got number"), err)
        \\ok, err = pcall(siv.window_set_title, app, "x")
        \\assert(not ok and err:find("siv.window expected"), err)
    );
}

test "descriptors are tables: defaults, enums, flags, colors, typos" {
    _ = try run(prologue ++
        \\local root = win:get_root()
        \\win:update(function(txn)
        \\  local col = txn:flex(root, { axis = "column", gap = 4, flags = { "wrap" } })
        \\  txn:set_layout(col, { padding = 8, width = 100, height = { "fraction", 1 }, flags = "no_shrink" })
        \\  txn:set_visual(col, { background = "#336699", border_color = { 1, 0, 0 }, radius = 4 })
        \\  txn:set_visual(col, { background = { r = 1, g = 1, b = 1, a = 0.5 }, flags = { clip = true } })
        \\  txn:set_layout(col, nil)
        \\  local ok, err = pcall(txn.flex, txn, root, { axis = "diagonal" })
        \\  assert(not ok and err:find("unknown siv_axis 'diagonal'"), err)
        \\  -- Closed enums take only the integers they name; open ones any.
        \\  txn:flex(root, { axis = 1 })
        \\  ok, err = pcall(txn.flex, txn, root, { axis = 7 })
        \\  assert(not ok and err:find("unknown siv_axis 7"), err)
        \\  root:emit({ type = "key", keysym = 0x61 })
        \\  -- Reserved fields are not part of the table.
        \\  ok, err = pcall(app.image_load, app, { path = "x", reserved0 = 1 }, function() end)
        \\  assert(not ok and err:find("unknown field"), err)
        \\end)
        \\local ok, err = pcall(win.update, win, function(txn, r) txn:set_layout(r, { padd = 1 }) end)
        \\assert(not ok and err:find("siv_layout_desc.padd: unknown field"), err)
        \\ok, err = pcall(win.update, win, function(txn, r) txn:set_visual(r, { background = "#12345" }) end)
        \\assert(not ok and err:find("invalid color"), err)
        \\ok, err = pcall(win.update, win, function(txn, r) txn:set_layout(r, { flags = "sideways" }) end)
        \\assert(not ok and err:find("unknown siv_layout_flags flag 'sideways'"), err)
        \\-- The failed transactions were aborted: a new one opens.
        \\win:update(function() end)
        \\local size = win:get_size()
        \\assert(size.width == 120 and size.height == 80)
        \\local m = app:measure_text("Hi", 0, { font_size = 20 })
        \\assert(type(m.width) == "number")
    );
}

test "handles are userdata: identity, methods, ownership" {
    const L = try newState();
    defer c.lua_close(L);
    _ = try runIn(L,
        \\local siv = require("siv")
        \\app = siv.app_create{ backend = "headless", flags = { "no_system_fonts" } }
        \\local win = app:window_create{ width = 120, height = 80 }
        \\assert(win:get_root() == win:get_root())
        \\assert(tostring(win):find("^siv.window: 0x"))
        \\assert(siv.methods.window.root == siv.window_root)
        \\local seen = {}
        \\seen[win:get_root()] = true
        \\assert(seen[win:get_root()])
        \\local function value(h) return math.tointeger(tonumber(tostring(h):match("0x(%x+)"), 16)) end
        \\local img = app:image_create{ pixels = string.rep("\\255", 16), width = 2, height = 2, stride = 8 }
        \\local s = img:get_size()
        \\assert(s.width == 2 and s.height == 2)
        \\img:destroy()
        \\assert(tostring(img):find("destroyed"))
        \\local ok, err = pcall(img.get_size, img)
        \\assert(not ok and err.code == "invalid_handle")
        \\-- Collecting an owned handle destroys its object; a kept one lives.
        \\collected = value(app:image_create{ pixels = string.rep("\\255", 16), width = 2, height = 2, stride = 8 })
        \\kept = app:image_create{ pixels = string.rep("\\255", 16), width = 2, height = 2, stride = 8 }
        \\kept_value = value(kept)
        \\collectgarbage()
        \\collectgarbage()
    );
    var size: siv.Size = undefined;
    _ = c.lua_getglobal(L, "collected");
    const collected: u64 = @bitCast(c.lua_tointegerx(L, -1, null));
    _ = c.lua_getglobal(L, "kept_value");
    const kept: u64 = @bitCast(c.lua_tointegerx(L, -1, null));
    lua.pop(L, 2);
    try testing.expect(collected != 0 and kept != 0);
    try testing.expectEqual(siv.Result.error_invalid_handle, siv.c.siv_image_get_size(@enumFromInt(collected), &size));
    try testing.expectEqual(siv.Result.ok, siv.c.siv_image_get_size(@enumFromInt(kept), &size));
    // Closing the state destroys the application it holds.
    _ = c.lua_getglobal(L, "app");
    const app: siv.App = @enumFromInt(root.toHandle(L, -1));
    lua.pop(L, 1);
    var fd: i32 = 0;
    try testing.expectEqual(siv.Result.ok, siv.c.siv_app_get_fd(app, &fd));
}

test "a host's handles pushed into Lua: the same userdata, never owned" {
    var app: siv.App = .null;
    try testing.expectEqual(siv.Result.ok, siv.c.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true } }, &app));
    defer siv.c.siv_app_destroy(app);
    var win: siv.Window = .null;
    try testing.expectEqual(siv.Result.ok, siv.c.siv_window_create(app, &.{ .width = 120, .height = 80 }, &win));
    const L = try newState();
    {
        defer c.lua_close(L);
        try testing.expectEqual(@as(c_int, 0), root.siv_lua_push_handle(L, "app", @intFromEnum(app)));
        c.lua_setglobal(L, "host_app");
        try testing.expectEqual(@as(c_int, 0), root.siv_lua_push_handle(L, "window", @intFromEnum(win)));
        c.lua_setglobal(L, "host_win");
        try testing.expectEqual(@as(c_int, 0), root.siv_lua_push_handle(L, "node", @intFromEnum(siv.c.siv_window_get_root(win))));
        c.lua_setglobal(L, "host_root");
        // An unknown type or a zero handle pushes nil.
        try testing.expectEqual(@as(c_int, -1), root.siv_lua_push_handle(L, "nonsense", @intFromEnum(app)));
        try testing.expectEqual(lua.tnil, c.lua_type(L, -1));
        try testing.expectEqual(@as(c_int, -1), root.siv_lua_push_handle(L, "window", 0));
        try testing.expectEqual(lua.tnil, c.lua_type(L, -1));
        lua.pop(L, 2);
        _ = try runIn(L,
            \\local siv = require("siv")
            \\assert(host_win:get_root() == host_root)
            \\assert(host_win:get_app() == host_app)
            \\local text
            \\host_win:update(function(txn, root)
            \\  assert(root == host_root)
            \\  text = txn:text(root, "From Lua")
            \\end)
            \\host_text = text
            \\local fired = false
            \\host_app:timer_start(0, function() fired = true end)
            \\host_app:dispatch(0)
            \\assert(fired)
            \\host_app, host_win, host_root = nil, nil, nil
            \\collectgarbage()
            \\collectgarbage()
        );
        _ = c.lua_getglobal(L, "host_text");
        const text: siv.Node = @enumFromInt(root.toHandle(L, -1));
        lua.pop(L, 1);
        var buf: [16]u8 = undefined;
        var len: usize = 0;
        try testing.expectEqual(siv.Result.ok, siv.c.siv_node_get_text(text, &buf, buf.len, &len));
        try testing.expectEqualStrings("From Lua", buf[0..len]);
    }
    // Closing the state destroyed neither the application nor its window.
    var fd: i32 = 0;
    try testing.expectEqual(siv.Result.ok, siv.c.siv_app_get_fd(app, &fd));
    try testing.expect(siv.c.siv_window_get_root(win) != .null);
}

test "callbacks run at safe points and their errors reach the caller" {
    _ = try run(prologue ++
        \\local root = win:get_root()
        \\local log = {}
        \\local button
        \\win:update(function(txn)
        \\  button = txn:box(root, {
        \\    semantics = { role = "button", flags = "focusable" },
        \\    on = { activate = function(node, ev)
        \\      log[#log + 1] = ev.type
        \\      assert(node == button and ev.window == win)
        \\      return true
        \\    end },
        \\  })
        \\end)
        \\assert(button:emit{ type = "activate" } == true)
        \\assert(#log == 1 and log[1] == "activate")
        \\-- A handler that raises: the error comes out of the call that ran it.
        \\win:update(function(txn) txn:on(button, "activate", function() error("boom") end) end)
        \\local ok, err = pcall(button.emit, button, { type = "activate" })
        \\assert(not ok and tostring(err):find("boom"), tostring(err))
        \\-- An error handler hears it instead.
        \\local heard
        \\siv.set_error_handler(function(e) heard = e end)
        \\assert(button:emit{ type = "activate" } == false)
        \\assert(tostring(heard):find("boom"))
        \\siv.set_error_handler(nil)
        \\-- Replacing a handler releases the old one.
        \\win:update(function(txn) txn:on(button, "activate", nil) end)
        \\assert(button:emit{ type = "activate" } == false)
    );
}

test "asynchronous calls: callbacks, or a coroutine that waits" {
    _ = try run(prologue ++
        \\local f = assert(io.open("test/abi/testdata/rgba.png", "rb"))
        \\local png = f:read("a")
        \\f:close()
        \\local got
        \\app:image_load({ data = png }, function(image, err)
        \\  assert(err == nil)
        \\  got = image
        \\end)
        \\local done, size
        \\siv.spawn(function()
        \\  local image = app:image_load{ path = "test/abi/testdata/rgba.png" }
        \\  size = image:get_size()
        \\  local ok, err = pcall(app.image_load, app, { data = "not an image" })
        \\  assert(not ok and siv.is_error(err), tostring(err))
        \\  app:sleep(1)
        \\  done = true
        \\end)
        \\for _ = 1, 500 do
        \\  if done and got then break end
        \\  app:dispatch(10)
        \\end
        \\assert(done and got and size.width > 0, "loads did not finish")
        \\assert(got:get_size().width == size.width)
        \\local ok, err = pcall(app.image_load, app, { data = png })
        \\assert(not ok and err:find("coroutine"), err)
    );
}

test "jobs from Lua: work in a state of its own, results at a safe point" {
    _ = try run(prologue ++
        \\local function sum(n, t)
        \\  local s = 0
        \\  for i = 1, n do s = s + i end
        \\  return s, { label = string.format("%d", s), list = { t.x, 2.5 } }, nil, true
        \\end
        \\local got, info, flag, failed, waited
        \\app:job_start("compute", sum, { 100, { x = "y" } }, function(ok, s, t, none, yes)
        \\  assert(ok, tostring(s))
        \\  got, info, flag = s, t, yes
        \\  assert(none == nil)
        \\end)
        \\app:job_start(nil, function() error("boom") end, nil, function(ok, msg)
        \\  failed = not ok and msg:find("boom")
        \\end)
        \\siv.spawn(function()
        \\  waited = app:job_start({ "compute" }, function(a, b) return a * b end, { 6, 7 })
        \\  local ok, err = pcall(app.job_start, app, nil, function() error("inside") end)
        \\  assert(not ok and err:find("inside"), tostring(err))
        \\end)
        \\for _ = 1, 500 do
        \\  if got and failed and waited then break end
        \\  app:dispatch(10)
        \\end
        \\assert(got == 5050 and info.label == "5050" and info.list[1] == "y" and info.list[2] == 2.5)
        \\assert(flag == true and failed and waited == 42)
        \\local up = 3
        \\local ok, err = pcall(app.job_start, app, nil, function() return up end, nil, function() end)
        \\assert(not ok and err:find("'up'"), tostring(err))
        \\ok, err = pcall(app.job_start, app, nil, function(f) return f end, { print }, function() end)
        \\assert(not ok and err:find("numbers, strings"), tostring(err))
        \\ok, err = pcall(app.job_start, app, nil, function() return 1 end)
        \\assert(not ok and err:find("coroutine"), tostring(err))
        \\-- Values of this state stay here: the job sees no siv.
        \\local saw
        \\app:job_start(nil, function() return require == nil and io == nil and os == nil end, nil, function(ok, v) saw = v end)
        \\for _ = 1, 500 do
        \\  if saw ~= nil then break end
        \\  app:dispatch(10)
        \\end
        \\assert(saw == true)
    );
}

test "the test API: scrolling, typing, queries, captures" {
    _ = try run(prologue ++
        \\local editor, scroll, last
        \\win:update(function(txn, root)
        \\  local column = txn:flex(root, { axis = "column" })
        \\  editor = txn:editor(column, nil, { semantics = { label = "Field" } })
        \\  txn:push_button(column, { label = "X" })
        \\  txn:push_button(column, { label = "X" })
        \\  scroll = txn:scroll(column, "vertical", { layout = { height = 30 } })
        \\  local inner = txn:flex(scroll, { axis = "column" })
        \\  for i = 1, 10 do last = txn:text(inner, "Row " .. i) end
        \\end)
        \\assert(app:test_settle(5000))
        \\-- Queries: the index-th match, and none.
        \\local found, first = win:test_find{ role = "button", name = "X" }
        \\local found2, second = win:test_find{ role = "button", name = "X", index = 1 }
        \\assert(found and found2 and second.bounds.y > first.bounds.y)
        \\assert(not win:test_find{ role = "button", name = "X", index = 2 })
        \\assert(not win:test_find{ name = "nothing" })
        \\assert(win:test_get_name{ name = "nothing" } == "")
        \\assert(win:test_dump():find('button "X"', 1, true), win:test_dump())
        \\assert(app:test_get_popup() == nil)
        \\-- Typing: Latin-1 and other characters.
        \\local _, field = win:test_find{ role = "text_input" }
        \\win:test_click(field.bounds.x + 2, field.bounds.y + 2, "primary")
        \\win:test_type("aé€")
        \\assert(app:test_settle(5000))
        \\assert(editor:get_text() == "aé€", editor:get_text())
        \\assert(win:test_get_name{ flags = "focused" } == "Field")
        \\-- The wheel over the scroll area moves its rows up, queued with
        \\-- the motion there: the frame the motion's hover change presents
        \\-- puts the compositor's scroll frame a refresh later, which
        \\-- settling waits for.
        \\local _, row = win:test_find{ name = "Row 1" }
        \\local before = win:test_capture()
        \\win:test_pointer_move(row.bounds.x + 2, row.bounds.y + 2)
        \\win:test_scroll(0, 30)
        \\assert(app:test_settle(5000))
        \\assert(before ~= win:test_capture(), "the capture did not change")
        \\local _, moved = win:test_find{ name = "Row 1" }
        \\assert(moved.bounds.y < row.bounds.y, moved.bounds.y .. " " .. row.bounds.y)
        \\-- Captures, at the window's size.
        \\local pixels, w, h = win:test_capture()
        \\assert(w == 120 and h == 80 and #pixels == w * h * 4)
        \\assert(not pcall(win.test_key, win, "a", {}, string.rep("x", 33)))
    );
}

test "the desktop shell from Lua: outputs, a layer window, a lock, toplevels, workspaces, idle, capabilities" {
    _ = try run(prologue ++
        \\local caps = app:get_capabilities()
        \\assert(caps.layers and caps.lock and not caps.blur)
        \\local outputs = {}
        \\app:watch_outputs(function(ev)
        \\  if ev.type == "added" then outputs[ev.name] = ev.output else outputs[ev.name] = nil end
        \\end)
        \\assert(app:test_settle(5000))
        \\assert(outputs["HEADLESS-1"])
        \\-- A frosted bar on the output.
        \\local resized
        \\local bar = app:layer_create{
        \\  output = outputs["HEADLESS-1"], namespace = "bar",
        \\  anchor = { "top", "left", "right" }, height = 24, flags = "auto_exclusive",
        \\  on_event = function(_, ev) if ev.type == "resized" then resized = ev.width end end,
        \\}
        \\bar:update(function(txn, root)
        \\  txn:set_visual(root, { background = "#00000080", flags = "window_blur" })
        \\  txn:set_semantics(root, { role = "toolbar", label = "Bar" })
        \\  txn:text(root, "12:00")
        \\end)
        \\assert(app:test_settle(5000))
        \\assert(resized == 1920, tostring(resized))
        \\assert(bar:test_find{ role = "toolbar", name = "Bar" })
        \\bar:set_layer{ anchor = { "bottom", "left", "right" }, height = 30 }
        \\assert(app:test_settle(5000))
        \\assert(resized == 1920 and bar:get_size().height == 30)
        \\-- Toplevels and workspaces arrive as events.
        \\app:test_add_toplevel("foot", "foot", outputs["HEADLESS-1"])
        \\local titles = {}
        \\local list <close> = app:toplevel_list_create{ on_event = function(_, ev)
        \\  titles[ev.title] = ev.type ~= "removed" and ev.toplevel or nil
        \\end }
        \\app:test_add_workspace("1", outputs["HEADLESS-1"])
        \\local active
        \\local spaces <close> = app:workspace_list_create{ on_event = function(_, ev)
        \\  if ev.states.active then active = ev.name end
        \\end }
        \\assert(app:test_settle(5000))
        \\assert(titles.foot and active == "1")
        \\titles.foot:close()
        \\assert(app:test_settle(5000))
        \\assert(titles.foot == nil)
        \\-- Idle.
        \\local idle
        \\local watch <close> = app:idle_watch_create{ timeout_ms = 1000, on_event = function(_, on) idle = on end }
        \\app:test_set_idle(true)
        \\assert(app:test_settle(5000))
        \\assert(idle == true)
        \\-- The lock: a window per output, then locked; unlocked.
        \\local events = {}
        \\local lock = app:lock_create{ on_event = function(_, ev)
        \\  events[#events + 1] = ev.type
        \\  if ev.type == "window" then
        \\    ev.window:update(function(txn, root) txn:editor(root, { "masked" }) end)
        \\  end
        \\end }
        \\assert(app:test_settle(5000))
        \\assert(events[1] == "window" and events[2] == "locked", table.concat(events, " "))
        \\assert(app:test_is_locked())
        \\lock:unlock()
        \\assert(not app:test_is_locked())
    );
}

test "span ends: stop, or end, which is a keyword" {
    _ = try run(prologue ++
        \\local a, b
        \\win:update(function(txn, root)
        \\  a = txn:text(root, "bold words")
        \\  txn:set_text_spans(a, { spans = { { start = 0, stop = 4, flags = "weight", weight = "bold" } } })
        \\  b = txn:text(root, "bold words")
        \\  txn:set_text_spans(b, { spans = { { start = 0, ["end"] = 4, flags = "weight", weight = "bold" } } })
        \\end)
        \\for _, n in ipairs{ a, b } do
        \\  local run = n:get_text_run(1)
        \\  assert(run.start == 0 and run.stop == 4 and run["end"] == 4, tostring(run.stop))
        \\  assert(n:get_text_run(5).stop == 10)
        \\end
    );
}

test "themed icons from Lua: loads, image nodes, buttons, and canvases" {
    _ = try run(prologue ++
        \\app:add_icon_path("test/icons/themes")
        \\app:set_icon_theme("SivTest")
        \\local size, missing
        \\local done = false
        \\siv.spawn(function()
        \\  local icon = app:icon_load{ name = "edit-copy-symbolic", logical_size = 24 }
        \\  size = icon:get_size()
        \\  local ok, err = pcall(app.icon_load, app, { name = "no-such-icon", flags = { "no_fallbacks" } })
        \\  missing = not ok and siv.is_error(err)
        \\  done = true
        \\end)
        \\local drew = 0
        \\win:update(function(txn)
        \\  local root = win:get_root()
        \\  txn:image_view(root, { icon = "folder", icon_size = 48, color_token = "accent" })
        \\  txn:push_button(root, { label = "Copy", icon = "edit-copy-symbolic", flags = { "icon_only" } })
        \\  txn:canvas(root, { width = 32, height = 32, draw = function(node, d, w, h)
        \\    d:icon("emblem-ok-symbolic", { x = 0, y = 0, width = w, height = h }, "#ff0000", {})
        \\    drew = drew + 1
        \\  end })
        \\end)
        \\for _ = 1, 500 do
        \\  if done and drew >= 2 then break end
        \\  app:dispatch(10)
        \\end
        \\assert(done and size.width == 24 and size.height == 24, "icon did not load")
        \\assert(missing, "a missing icon raises")
        \\-- The canvas drew again once its icon loaded.
        \\assert(drew >= 2, "canvas drew " .. drew .. " times")
    );
}

test "canvases draw from Lua" {
    _ = try run(prologue ++
        \\local root = win:get_root()
        \\local draws, measured = 0, 0
        \\win:update(function(txn)
        \\  txn:canvas(root, {
        \\    measure = function(node, c) measured = measured + 1; return 40, 30 end,
        \\    draw = function(node, d, w, h)
        \\      draws = draws + 1
        \\      assert(w == 40 and h == 30, w .. "x" .. h)
        \\      d:rect(0, 0, w, h)
        \\      d:fill({ color = "#ff0000" })
        \\      d:rounded_rect({ x = 2, y = 2, width = 10, height = 10 }, 3)
        \\      d:stroke({ width = 2 }, { color = { 0, 0, 1 } })
        \\      d:push_opacity(0.5)
        \\      d:text(4, 4, 0, "Hi", { font_size = 10 })
        \\      d:pop()
        \\    end,
        \\  }, { layout = { align_x = "start", align_y = "start" } })
        \\end)
        \\for _ = 1, 50 do
        \\  app:dispatch(5)
        \\  if draws > 0 then break end
        \\end
        \\assert(draws > 0 and measured > 0)
    );
}

test "the clipboard from a coroutine" {
    _ = try run(prologue ++
        \\local text, done
        \\siv.spawn(function()
        \\  win:clipboard_write("clipboard", "from Lua")
        \\  text = win:clipboard_read("clipboard")
        \\  assert(win:clipboard_read("primary") == nil)
        \\  done = true
        \\end)
        \\assert(not done)
        \\for _ = 1, 200 do
        \\  if done then break end
        \\  app:dispatch(5)
        \\end
        \\assert(done and text == "from Lua", tostring(text))
    );
}

test "hot reload: a changed module runs again, kept values stay" {
    const io = testing.io;
    const dir = ".zig-cache/lua-watch-test";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    // The main chunk counts its runs in a kept table, makes one kept and
    // one ordinary window per run, and reads its label from a module.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/label.lua", .data = "return 'first'\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/main.lua", .data = 
        \\local label_path = ...
        \\local siv = require("siv")
        \\local app = siv.app_create{ backend = "headless", flags = { "no_system_fonts" } }
        \\local state = siv.keep("state", function() return { runs = 0, labels = {} } end)
        \\local kept = siv.keep("window", function() return app:window_create{ width = 50, height = 50 } end)
        \\local other = app:window_create{ width = 40, height = 40 }
        \\state.runs = state.runs + 1
        \\state.labels[state.runs] = require("label")
        \\state.windows = state.windows or {}
        \\state.windows[state.runs] = other
        \\if state.runs == 1 then
        \\  state.kept = kept
        \\  -- Change the module once the watcher runs, then wait for the
        \\  -- reload, with a deadline.
        \\  app:timer_start(100, function()
        \\    local f = assert(io.open(label_path, "w"))
        \\    f:write("return 'second'\n")
        \\    f:close()
        \\  end)
        \\  app:timer_start(5000, function() app:quit() end)
        \\  app:run()
        \\  assert(state.runs == 2, "no reload")
        \\  assert(state.labels[2] == "second", tostring(state.labels[2]))
        \\  assert(state.kept == kept)
        \\  -- The first run's ordinary window went; the second's stays.
        \\  assert(not pcall(state.windows[1].get_size, state.windows[1]))
        \\  assert(state.windows[2]:get_size().width == 40)
        \\elseif state.runs == 2 then
        \\  app:quit()
        \\end
    });
    const L = try newState();
    defer c.lua_close(L);
    const args = [_:null]?[*:0]const u8{dir ++ "/label.lua"};
    try testing.expectEqual(0, root.siv_lua_run(L, dir ++ "/main.lua", 1, &args, 1));
}

test "portal requests from a coroutine: the file chooser without a bus" {
    _ = try run(prologue ++
        \\local result
        \\siv.spawn(function()
        \\  local chooser <close> = app:file_chooser_create{ title = "Open" }
        \\  chooser:add_filter("Images")
        \\  chooser:add_pattern("mime", "image/*")
        \\  result = chooser:show(win)
        \\end)
        \\for _ = 1, 200 do
        \\  if result then break end
        \\  app:dispatch(5)
        \\end
        \\-- The headless backend has no session bus.
        \\assert(result and result.response == "unavailable", result and result.response)
    );
}

/// A test bus on a loop of its own in a thread, listening on an abstract
/// socket, for scripts that connect by address.
const ThreadBus = struct {
    loop: Loop,
    bus: dbus.testing.TestBus,
    source: Loop.Source,
    stop: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    address: [64]u8 = undefined,
    address_len: usize = 0,

    fn start(tb: *ThreadBus) !void {
        const linux = std.os.linux;
        tb.* = .{ .loop = try Loop.init(testing.allocator), .bus = undefined, .source = undefined };
        tb.bus = .init(testing.allocator, &tb.loop);
        const fd: i32 = @intCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0));
        var sa: linux.sockaddr.un = .{ .path = @splat(0) };
        const name = try std.fmt.bufPrint(sa.path[1..], "siv-lua-dbus-{d}", .{linux.getpid()});
        if (linux.errno(linux.bind(fd, @ptrCast(&sa), @intCast(@offsetOf(linux.sockaddr.un, "path") + 1 + name.len))) != .SUCCESS) return error.Bind;
        if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.Listen;
        tb.address_len = (try std.fmt.bufPrint(&tb.address, "unix:abstract={s}", .{name})).len;
        tb.source = .{ .fd = fd, .events = linux.EPOLL.IN, .func = onAccept };
        try tb.loop.addSource(&tb.source);
        tb.thread = try std.Thread.spawn(.{}, serve, .{tb});
    }

    fn serve(tb: *ThreadBus) void {
        while (!tb.stop.load(.acquire)) tb.loop.dispatch(20) catch {};
    }

    fn onAccept(s: *Loop.Source, _: u32) void {
        const linux = std.os.linux;
        const tb: *ThreadBus = @fieldParentPtr("source", s);
        const rc = linux.accept4(s.fd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return;
        tb.bus.adopt(@intCast(rc)) catch {};
    }

    fn finish(tb: *ThreadBus) void {
        tb.stop.store(true, .release);
        tb.loop.wake();
        tb.thread.join();
        tb.bus.deinit();
        tb.loop.removeSource(&tb.source);
        _ = std.os.linux.close(tb.source.fd);
        tb.loop.deinit();
    }
};

test "D-Bus from Lua: a service and a client on one bus" {
    var tb: ThreadBus = undefined;
    try tb.start();
    defer tb.finish();
    const body =
        \\local function pump(cond)
        \\  for _ = 1, 400 do
        \\    if cond() then return end
        \\    app:dispatch(5)
        \\  end
        \\  error("timed out")
        \\end
        \\local S, I, U = ("s"):byte(), ("i"):byte(), ("u"):byte()
        \\local server <close> = app:dbus_connect{ bus = "address", address = A }
        \\local client <close> = app:dbus_connect{ bus = "address", address = A }
        \\pump(function() return server:get_unique_name() ~= "" and client:get_unique_name() ~= "" end)
        \\local state
        \\local name <close> = server:own_name("org.siv.Lua", {}, function(_, s) state = s end)
        \\local obj <close> = server:export{
        \\  path = "/org/siv/Lua", interface = "org.siv.Lua",
        \\  methods = { { name = "Add", in_signature = "ii", out_signature = "s" } },
        \\  properties = { { name = "Count", signature = "u", access = "read" } },
        \\  on_call = function(info, args, inv)
        \\    assert(info.member == "Add")
        \\    local a, b = args:read_int(), args:read_int()
        \\    local reply = inv:new_reply()
        \\    reply:write_string(S, tostring(a + b))
        \\    reply:send()
        \\  end,
        \\  get_property = function(prop, msg) msg:write_int(U, 3) end,
        \\}
        \\pump(function() return state == "primary" end)
        \\local owner
        \\local watch <close> = client:watch_name("org.siv.Lua", function(_, o) owner = o end)
        \\pump(function() return owner == server:get_unique_name() end)
        \\local function call(desc, write)
        \\  desc.destination = desc.destination or "org.siv.Lua"
        \\  desc.path = "/org/siv/Lua"
        \\  local m = client:new_call(desc)
        \\  if write then write(m) end
        \\  local result
        \\  m:call(0, function(info, r) result = { info = info, r = r and r:read_type() }; if info.type == "method_return" and result.r ~= 0 then
        \\    if result.r == ("v"):byte() then r:read_enter() end
        \\    result.value = (r:read_type() == S) and r:read_string() or r:read_int()
        \\  end end)
        \\  pump(function() return result end)
        \\  return result
        \\end
        \\local res = call({ interface = "org.siv.Lua", member = "Add" }, function(m) m:write_int(I, 40); m:write_int(I, 2) end)
        \\assert(res.info.type == "method_return" and res.value == "42", res.info.error_name)
        \\res = call({ interface = "org.freedesktop.DBus.Properties", member = "Get" }, function(m)
        \\  m:write_string(S, "org.siv.Lua"); m:write_string(S, "Count")
        \\end)
        \\assert(res.value == 3)
        \\res = call({ interface = "org.siv.Lua", member = "Nope" })
        \\assert(res.info.type == "error" and res.info.error_name == "org.freedesktop.DBus.Error.UnknownMethod")
        \\local heard
        \\local sub <close> = client:subscribe({ interface = "org.siv.Lua", member = "Changed" }, function(info, r) heard = r:read_string() end)
        \\call({ interface = "org.siv.Lua", member = "Nope" }) -- the match is in place
        \\local sig = server:new_signal{ path = "/org/siv/Lua", interface = "org.siv.Lua", member = "Changed" }
        \\sig:write_string(S, "yes")
        \\sig:send()
        \\pump(function() return heard end)
        \\assert(heard == "yes")
    ;
    const script = try std.mem.concat(testing.allocator, u8, &.{ prologue, "local A = \"", tb.address[0..tb.address_len], "\"\n", body });
    defer testing.allocator.free(script);
    _ = try run(script);
}
