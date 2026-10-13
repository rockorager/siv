//! The binding against libsiv.so on the headless backend: Lua scripts run
//! in a state from siv_lua_new, as an embedding host would make one.

const std = @import("std");
const lua = @import("c.zig");
const c = lua.c;
const root = @import("lua.zig");
const siv = @import("siv");

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
        \\local root = win:root()
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
        \\assert(win:root() == win:root())
        \\assert(tostring(win):find("^siv.window: 0x"))
        \\assert(siv.methods.window.root == siv.window_root)
        \\local seen = {}
        \\seen[win:root()] = true
        \\assert(seen[win:root()])
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
    try testing.expectEqual(siv.Result.ok, siv.c.siv_app_fd(app, &fd));
}

test "callbacks run at safe points and their errors reach the caller" {
    _ = try run(prologue ++
        \\local root = win:root()
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
        \\  local root = win:root()
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
        \\local root = win:root()
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
