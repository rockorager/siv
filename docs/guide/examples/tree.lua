-- A virtualized tree in Lua: the view asks for an item's children only
-- when it expands, and binds rows as they come into view.
--
--     ./zig-out/bin/siv-lua docs/guide/examples/tree.lua
local siv = require("siv")

local app = siv.app_create()
local win = app:window_create{ title = "Tree", width = 320, height = 300 }

local outline = {
	{ "Documents", { { "Letters", { { "To Ana" }, { "To Ben" } } }, { "Taxes 2026" }, { "Recipes" } } },
	{ "Music", { { "Albums" }, { "Playlists" } } },
	{ "Pictures", { { "Holidays" }, { "Screenshots" } } },
}

-- Trees name items by nonzero ids; 0 is the top level.
local items = {}
local function register(list)
	for _, entry in ipairs(list) do
		items[#items + 1] = entry
		entry.id = #items
		if entry[2] then
			register(entry[2])
		end
	end
end
register(outline)

local function children(id)
	if id == 0 then
		return outline
	end
	return items[id][2] or {}
end

local status

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
	local column = txn:flex(root, { axis = "column", gap = 8 }, {
		layout = { padding = 12, width = { "fraction", 1 }, height = { "fraction", 1 } },
	})
	local view = txn:tree_view(column, {
		label = "Folders",
		selection = "single",
		item_height = 28,
		children = function(id)
			return #children(id)
		end,
		child = function(id, index)
			return children(id)[index + 1].id
		end,
		-- A new row gets a text node; a recycled one already has it.
		bind = function(t, row, id, _, _, recycled)
			if not recycled then
				t:text(row, "", { text_style = { color_token = "view_fg" } })
			end
			t:set_text(row:get_related("first_child"), items[id][1])
		end,
	}, {
		layout = { grow = 1, basis = 0 },
		visual = { background_token = "view_bg", border_token = "border", border_width = 1, radius = 6 },
		on = {
			select = function(node, ev)
				local id = node:view_get_item(ev.index)
				win:update(function(t)
					t:set_text(status, "Selected " .. items[id][1])
				end)
				return true
			end,
		},
	})
	status = txn:text(column, "Right expands, Left collapses", {
		text_style = { size_role = "caption", color_token = "muted_fg" },
	})
	return view
end):focus()

app:run()
