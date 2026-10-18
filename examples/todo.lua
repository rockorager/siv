-- A to-do list: an editor whose Enter key adds an item to a scrolling
-- list, a live count of the editor's text, and items that remove
-- themselves when clicked. The Lua version of todo.c, written with
-- siv.view: the items, the draft, and the status line are signals, and
-- the tree follows them.
--
--     zig build && ./zig-out/bin/siv-lua examples/todo.lua
--
-- Run it with --watch and edit this file: the window, the items, and what
-- the editor holds survive the reload (siv.keep, and the editor's key);
-- the rest is built again from them.
local siv = require("siv")
local view = require("siv.view")
local ui = view.ui

local ink = "#17171c"
local muted = "#70707a"

local app = siv.app_create()

-- State kept across hot reloads.
local win = siv.keep("window", function()
	return app:window_create{ title = "To do", app_id = "dev.siv.examples.todo", width = 360, height = 420 }
end)
local items, set_items = siv.keep("items", function()
	return view.signal({ { text = "Click an item to remove it" } })
end)
local draft, set_draft = siv.keep("draft", function()
	return view.signal("")
end)
local status, set_status = view.signal("Type and press Enter")

-- A row for `item`; clicking it removes the item, and view.each removes
-- the row.
local function Row(item)
	ui.box({
		layout = { padding = { 8, 8, 6, 6 } },
		visual = { background = "#f4f4f6", radius = 4 },
		semantics = { role = "list_item", flags = "focusable" },
		on = {
			activate = function()
				local rest = {}
				for _, other in ipairs(items()) do
					if other ~= item then
						rest[#rest + 1] = other
					end
				end
				set_items(rest)
				return true
			end,
		},
	}, function()
		ui.text(item.text, { text_style = { color = ink } })
	end)
end

local function App()
	ui.flex({ axis = "column", gap = 10 }, { layout = { padding = 16, height = { "fraction", 1 } } }, function()
		ui.text("To do", {
			text_style = { font_size = 22, weight = "semibold", color = ink },
			semantics = { role = "heading" },
		})

		-- The editor owns its text; the draft follows it, and setting the
		-- draft to something else (clearing it) sets the editor's text.
		local editor = ui.editor(nil, {
			key = "editor",
			layout = { padding = { 6, 6, 4, 4 } },
			visual = { border_color = "#a1a1ab", border_width = 1, radius = 4 },
			semantics = { label = "New item" },
			text = draft,
			on = {
				-- Enter adds the editor's text as an item and clears it.
				key = function(_, ev)
					if ev.keysym ~= "return" or not ev.flags.pressed then
						return false
					end
					if draft() == "" then
						return true
					end
					local more = { table.unpack(items()) }
					more[#more + 1] = { text = draft() }
					set_items(more)
					set_draft("")
					set_status("")
					return true
				end,
				-- The change event carries the editor's new text.
				change = function(_, ev)
					set_draft(ev.text or "")
					set_status(#draft() .. " bytes typed")
					return true
				end,
			},
		})
		view.on_mount(function()
			editor:focus()
		end)

		ui.text(status, { text_style = { font_size = 12, color = muted } })

		-- The list scrolls on the compositor thread; it takes the space the
		-- column has left.
		ui.scroll("vertical", { layout = { grow = 1, basis = 0 } }, function()
			ui.flex({ axis = "column", gap = 4 }, { semantics = { role = "list" } }, function()
				view.each(items, Row)
			end)
		end)
	end)
end

win:update(function(txn, root)
	txn:set_visual(root, { background = "#ffffff" })
end)
view.mount(win, App)

app:run()
