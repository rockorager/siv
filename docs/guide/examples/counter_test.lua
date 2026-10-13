-- A test of hello.lua's window, run without a display: the headless
-- backend renders into memory, and the test_* methods drive the window as
-- a user would and read what it shows, as a screen reader reads it.
--
--     ./zig-out/bin/siv-lua docs/guide/examples/counter_test.lua
local siv = require("siv")

local app = siv.app_create{
	backend = "headless",
	flags = { "no_system_fonts", "no_system_icons", "reduced_motion" },
}
local f = assert(io.open("src/text/testdata/DroidSans.ttf", "rb"))
app:add_font("Test", f:read("a"))
f:close()
app:set_default_font("Test")

-- The code under test.
local win = app:window_create{ title = "Counter", width = 320, height = 160 }
local clicks, label = 0, nil
win:update(function(txn, root)
	local column = txn:flex(root, { axis = "column", gap = 12, align_items = "start" }, {
		layout = { padding = 24 },
	})
	txn:push_button(column, { label = "Click me" }, {
		on = { activate = function(_, ev)
			clicks = clicks + 1
			ev.window:update(function(t)
				t:set_text(label, ("Clicked %d time%s"):format(clicks, clicks == 1 and "" or "s"))
			end)
			return true
		end },
	})
	label = txn:text(column, "Not clicked yet")
end)

-- The test.
local function settle()
	assert(app:test_settle(5000), "the window did not settle")
end

local function expect_text(text)
	if not win:test_find{ name = text } then
		error(("nothing reads %q; the window reads:\n%s"):format(text, win:test_dump()), 2)
	end
end

settle()
expect_text("Not clicked yet")

local found, button = win:test_find{ role = "button", name = "Click me" }
assert(found)
local b = button.bounds
win:test_click(b.x + b.width / 2, b.y + b.height / 2, "primary")
settle()
expect_text("Clicked 1 time")

win:test_key("tab", {}, "")
win:test_key("return", {}, "\r")
settle()
expect_text("Clicked 2 times")
assert(win:test_get_name{ flags = "focused" } == "Click me")

local pixels, width, height = win:test_capture()
assert(width == 320 and height == 160 and #pixels == width * height * 4)
