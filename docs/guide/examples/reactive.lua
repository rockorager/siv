-- A reactive view in Lua (siv.view): the state is signals, the tree is
-- built once from components, and each property given as a function
-- follows the signals it reads.
--
--     ./zig-out/bin/siv-lua docs/guide/examples/reactive.lua
local siv = require("siv")
local view = require("siv.view")
local ui = view.ui

local app = siv.app_create()
local win = app:window_create{ title = "Groceries", width = 300, height = 240 }

-- The state: signals, each a getter and a setter.
local items, set_items = view.signal({
	{ name = "Apples" }, { name = "Bread" }, { name = "Coffee" }, { name = "Dates" },
})
local filter, set_filter = view.signal("")

-- A derived value: runs again when items or the filter change.
local shown = view.memo(function()
	local out = {}
	for _, item in ipairs(items()) do
		if item.name:lower():find(filter():lower(), 1, true) then
			out[#out + 1] = item
		end
	end
	return out
end)

local function remove(gone)
	local rest = {}
	for _, item in ipairs(items()) do
		if item ~= gone then
			rest[#rest + 1] = item
		end
	end
	set_items(rest)
end

-- A row runs once per item; clicking it removes the item.
local function Row(item)
	ui.box({
		layout = { padding = { 10, 10, 6, 6 } },
		visual = { background_token = "card_bg", radius = 4 },
		semantics = { role = "list_item", label = item.name, flags = "focusable" },
		motion = { flags = { "layout", "exit" } },
		on = { activate = function()
			remove(item)
			return true
		end },
	}, function()
		ui.text(item.name, { text_style = { color_token = "card_fg" } })
	end)
end

local function Groceries()
	ui.flex({ axis = "column", gap = 8 }, { layout = { padding = 16 } }, function()
		-- The field owns its text; the filter follows it.
		ui.text_field({ placeholder = "Filter" }, {
			key = "filter",
			on = { change = function(_, ev)
				set_filter(ev.text)
				return true
			end },
		})
		ui.text(function()
			return ("%d of %d shown"):format(#shown(), #items())
		end, { text_style = { size_role = "caption", color_token = "muted_fg" } })
		view.each(shown, Row)
		view.show(function()
			return #shown() == 0
		end, function()
			ui.text("Nothing matches", { text_style = { color_token = "muted_fg" } })
		end)
	end)
end

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
end)
view.mount(win, Groceries)

app:run()
