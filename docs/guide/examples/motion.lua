-- Motion: a list whose rows grow in at the top, push the others down on
-- a spring, and slide out when clicked, all on the compositor thread.
--
--     ./zig-out/bin/siv-lua docs/guide/examples/motion.lua
local siv = require("siv")

local app = siv.app_create()
local win = app:window_create{ title = "Motion", width = 280, height = 220 }

local planets = { "Mercury", "Venus", "Earth", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune" }
local added = 0
local list
local rows = {}

-- Rows follow layout on a spring, grow in from 90%, and slide a width
-- toward the end edge as they leave.
local row_motion = {
	flags = { "layout", "enter", "exit", "relative", "mirror_rtl" },
	bounce = 0.15,
	enter_scale = 0.9,
	exit_x = 1,
}

local function add_row(txn)
	added = added + 1
	local name = planets[(added - 1) % #planets + 1]
	local row
	row = txn:box(list, {
		layout = { padding = { 12, 12, 8, 8 } },
		visual = { background_token = "card_bg", border_token = "border", border_width = 1, radius = 6 },
		semantics = { role = "list_item", label = name, flags = "focusable" },
		motion = row_motion,
		on = {
			activate = function(_, ev)
				for i, r in ipairs(rows) do
					if r == row then
						table.remove(rows, i)
						break
					end
				end
				ev.window:update(function(t)
					t:remove(row)
				end)
				return true
			end,
		},
	})
	txn:text(row, name, { text_style = { color_token = "card_fg" } })
	-- New rows go first; the others move down to make room.
	if rows[1] then
		txn:move(row, list, rows[1])
	end
	table.insert(rows, 1, row)
end

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
	local column = txn:flex(root, { axis = "column", gap = 12, align_items = "start" }, {
		layout = { padding = 20 },
	})
	txn:push_button(column, { label = "Add a planet", style = "primary" }, {
		on = {
			activate = function(_, ev)
				ev.window:update(add_row)
				return true
			end,
		},
	})
	list = txn:flex(column, { axis = "column", gap = 8 }, { layout = { width = 200 } })
	for _ = 1, 3 do
		add_row(txn)
	end
end)

app:run()
