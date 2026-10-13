-- A window with a heading and a button that counts its clicks. The Lua
-- version of hello.c.
--
--     zig build && ./zig-out/bin/siv-lua examples/hello.lua
--
-- Closing the window ends app:run(): an unhandled close request destroys
-- the window, and run returns once no window is left.
local siv = require("siv")

local app = siv.app_create()
local win = app:window_create{ title = "Hello", width = 320, height = 200 }

local clicks = 0
local label

-- Build the tree in one transaction. If anything in the function raises,
-- the transaction is aborted and nothing of it shows.
win:update(function(txn, root)
	txn:set_visual(root, { background = "#ffffff" })
	local column = txn:flex(root, { axis = "column", gap = 16, align_items = "start" }, {
		layout = { padding = 24 },
	})
	txn:text(column, "Hello from Lua", {
		text_style = { font_size = 24, weight = "bold" },
		semantics = { role = "heading" },
	})
	-- A focusable button: Tab reaches it, Enter and Space activate it.
	local button = txn:box(column, {
		layout = { padding = { 16, 16, 8, 8 } },
		visual = { background = "#2563eb", radius = 8 },
		semantics = { role = "button", flags = "focusable" },
		on = {
			-- Runs on the application's thread when the button is clicked
			-- or activated from the keyboard.
			activate = function(_, ev)
				clicks = clicks + 1
				ev.window:update(function(t)
					t:set_text(label, ("Clicked %d time%s"):format(clicks, clicks == 1 and "" or "s"))
				end)
				return true
			end,
		},
	})
	txn:text(button, "Click me", { text_style = { color = "#ffffff" } })
	label = txn:text(column, "Not clicked yet")
end)

app:run()
