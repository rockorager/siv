-- siv.so from the stock lua interpreter (src/lua/build_steps.zig):
--
--     lua src/lua/testdata/module.lua path/to/siv.so
--
-- require("siv") finds the module through package.cpath, and the binding
-- runs on the interpreter's own Lua. Run from the repository root.

local module_path = assert(arg[1], "usage: lua module.lua path/to/siv.so")

-- package.cpath finds it as siv.so.
local dir = os.tmpname()
os.remove(dir)
assert(os.execute(("mkdir -p '%s' && ln -s \"$(realpath '%s')\" '%s/siv.so'"):format(dir, module_path, dir)))
package.cpath = dir .. "/?.so"

local before = {}
for k in pairs(_G) do
	before[k] = true
end
local siv = require("siv")
for k in pairs(_G) do
	assert(before[k], "new global " .. tostring(k))
end
assert(package.loaded.siv == siv and siv.version() > 0)
-- The host's libraries, debug included: this is the interpreter's Lua.
assert(debug and debug.traceback)

local app <close> = siv.app_create{ backend = "headless", flags = { "no_system_fonts", "reduced_motion" } }
local font = assert(io.open("src/text/testdata/DroidSans.ttf", "rb"))
app:add_font("Droid", font:read("a"))
font:close()
app:set_default_font("Droid")
local win = app:window_create{ width = 120, height = 80 }

-- Builders, properties, and a handler run through emit.
local activated = 0
local button = win:update(function(txn, root)
	return txn:box(root, {
		semantics = { role = "button", flags = "focusable" },
		visual = { background = "#2563eb", radius = 4 },
		on = { activate = function(node, ev)
			assert(ev.type == "activate" and ev.window == win)
			activated = activated + 1
			return true
		end },
	})
end)
assert(button:emit{ type = "activate" } and activated == 1)

-- Errors with result codes.
local ok, err = pcall(function()
	local txn <close> = win:txn_begin()
	return win:txn_begin()
end)
assert(not ok and siv.is_error(err) and err.code == "busy", tostring(err))

-- Coroutines: an image load and a clipboard round trip.
local size, pasted
siv.spawn(function()
	size = app:image_load{ path = "test/abi/testdata/rgba.png" }:get_size()
	win:clipboard_write("clipboard", "via siv.so")
	pasted = win:clipboard_read("clipboard")
end)
for _ = 1, 500 do
	if pasted then
		break
	end
	app:dispatch(10)
end
assert(size and size.width > 0, "the image did not load")
assert(pasted == "via siv.so", tostring(pasted))

-- The reactive layer (D45), from require and from the module's export.
local view = require("siv.view")
local open_view = assert(package.loadlib(dir .. "/siv.so", "luaopen_siv_view"))
assert(open_view() == view)
local count, set_count = view.signal(1)
local label
view.mount(win, function()
	label = view.ui.text(function()
		return "count " .. count()
	end)
end)
set_count(2)
assert(label:get_text() == "count 2", label:get_text())

-- Hot reload belongs to siv-lua, which owns the main chunk.
ok, err = pcall(siv.reload)
assert(not ok and tostring(err):find("siv%-lua"), tostring(err))

os.execute(("rm -rf '%s'"):format(dir))
print("siv.so: ok")
