-- A to-do list: an editor whose Enter key adds an item to a scrolling
-- list, a live count of the editor's text, and items that remove
-- themselves when clicked. The Lua version of todo.c.
--
--     zig build && ./zig-out/bin/siv-lua examples/todo.lua
--
-- Run it with --watch and edit this file: the window, the items, and what
-- the editor holds survive the reload (siv.keep); the rest is built again
-- from them.
local siv = require("siv")

local ink = "#17171c"
local muted = "#70707a"

local app = siv.app_create()

-- State kept across hot reloads.
local win = siv.keep("window", function()
	return app:window_create{ title = "To do", app_id = "dev.siv.examples.todo", width = 360, height = 420 }
end)
local state = siv.keep("state", function()
	return { items = { "Click an item to remove it" }, draft = "" }
end)

local list, status

-- A row for item `text`; clicking it removes the row and the item.
local function add_row(txn, text)
	local row
	row = txn:box(list, {
		layout = { padding = { 8, 8, 6, 6 } },
		visual = { background = "#f4f4f6", radius = 4 },
		semantics = { role = "list_item", flags = "focusable" },
		on = {
			activate = function(_, ev)
				ev.window:update(function(t)
					t:remove(row)
					for i, item in ipairs(state.items) do
						if item == text then
							table.remove(state.items, i)
							break
						end
					end
				end)
				return true
			end,
		},
	})
	txn:text(row, text, { text_style = { color = ink } })
end

win:update(function(txn, root)
	txn:clear(root)
	txn:set_visual(root, { background = "#ffffff" })
	local column = txn:flex(root, { axis = "column", gap = 10 }, {
		layout = { padding = 16, height = { "fraction", 1 } },
	})

	txn:text(column, "To do", {
		text_style = { font_size = 22, weight = "semibold", color = ink },
		semantics = { role = "heading" },
	})

	local editor = txn:editor(column, nil, {
		layout = { padding = { 6, 6, 4, 4 } },
		visual = { border_color = "#a1a1ab", border_width = 1, radius = 4 },
		semantics = { label = "New item" },
		text = state.draft,
	})
	txn:set_selection(editor, #state.draft, #state.draft)
	-- Enter adds the editor's text as an item and clears it.
	txn:on(editor, "key", function(node, ev)
		if ev.keysym ~= siv.keysym.Return or not ev.flags.pressed then
			return false
		end
		local text = node:get_text()
		if text == "" then
			return true
		end
		win:update(function(t)
			add_row(t, text)
			state.items[#state.items + 1] = text
			state.draft = ""
			t:set_text(node, "")
			t:set_text(status, "")
		end)
		return true
	end)
	-- The change event carries the editor's new text.
	txn:on(editor, "change", function(_, ev)
		state.draft = ev.text or ""
		win:update(function(t)
			t:set_text(status, #state.draft .. " bytes typed")
		end)
		return true
	end)

	status = txn:text(column, "Type and press Enter", { text_style = { font_size = 12, color = muted } })

	-- The list scrolls on the compositor thread; it takes the space the
	-- column has left.
	local scroll = txn:scroll(column, "vertical", { layout = { grow = 1, basis = 0 } })
	list = txn:flex(scroll, { axis = "column", gap = 4 }, { semantics = { role = "list" } })
	for _, item in ipairs(state.items) do
		add_row(txn, item)
	end
	return editor
end):focus()

app:run()
