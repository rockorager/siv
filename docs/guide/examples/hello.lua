-- The guide's first program in Lua: a window with a title, a button, and
-- a label that counts the button's clicks.
--
--     ./zig-out/bin/siv-lua docs/guide/examples/hello.lua
local siv = require("siv")

local app = siv.app_create()
local win = app:window_create{ title = "Hello", width = 320, height = 160 }

local clicks = 0
local label

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
	local column = txn:flex(root, { axis = "column", gap = 12, align_items = "start" }, {
		layout = { padding = 24 },
	})
	txn:text(column, "Hello, siv", {
		text_style = { size_role = "title", weight = "bold", color_token = "window_fg" },
		semantics = { role = "heading", level = 1 },
	})
	txn:push_button(column, { label = "Click me", style = "primary" }, {
		on = {
			-- Runs on the application's thread when the button is clicked,
			-- or activated with Enter, Space, or a screen reader.
			activate = function(_, ev)
				clicks = clicks + 1
				ev.window:update(function(t)
					t:set_text(label, ("Clicked %d time%s"):format(clicks, clicks == 1 and "" or "s"))
				end)
				return true
			end,
		},
	})
	label = txn:text(column, "Not clicked yet", { text_style = { color_token = "window_fg" } })
end)

app:run()
