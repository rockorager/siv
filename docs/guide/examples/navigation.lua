-- Navigation: a sidebar of destinations in sections, and a navigation
-- stack whose pages have header bars. Choosing a destination starts the
-- stack over at its page; Advanced pushes a page with a back button,
-- and Escape, Alt+Left, or the mouse's back button go back.
--
--     ./zig-out/bin/siv-lua docs/guide/examples/navigation.lua
local siv = require("siv")

local app = siv.app_create()
-- Client-side decorations: the content's header bar is the title bar.
local win = app:window_create{ title = "Settings", width = 560, height = 300, flags = "client_decorations" }

local panels = { "Wi-Fi", "Bluetooth", "Displays", "Sound" }
local stack

local function push_advanced(t, name)
	local page = t:navigation_page(stack, { title = name .. " Advanced" })
	t:header_bar(page)
	local body = t:flex(page, { axis = "column", gap = 12, align_items = "start" }, { layout = { padding = 20 } })
	t:switch(body, { label = "Show in the panel" })
	t:switch(body, { label = "Turn off when idle", checked = "on" })
end

-- A destination's page, alone on the stack.
local function show(t, index)
	local name = panels[index]
	t:widget_set_value(stack, 0)
	local page = t:navigation_page(stack, { title = name })
	t:header_bar(page)
	local body = t:flex(page, { axis = "column", gap = 12, align_items = "start" }, { layout = { padding = 20 } })
	t:switch(body, { label = name, checked = "on" })
	t:push_button(body, { label = "Advanced" }, {
		on = {
			activate = function(_, ev)
				ev.window:update(function(u)
					push_advanced(u, name)
				end)
				return true
			end,
		},
	})
end

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
	local row = txn:flex(root, { align_items = "stretch" }, {
		layout = { width = { "fraction", 1 }, height = { "fraction", 1 } },
	})
	local sidebar = txn:sidebar(row, { label = "Settings" }, {
		layout = { width = 180 },
		on = {
			change = function(_, ev)
				ev.window:update(function(t)
					show(t, ev.index + 1)
				end)
				return true
			end,
		},
	})
	-- The sidebar's own header bar sits above its items, without the
	-- window controls, which belong to the content's.
	txn:header_bar(sidebar:widget_get_part("start", 0), { title = "Settings", flags = "no_window_controls" })
	local connect = txn:sidebar_section(sidebar, { title = "Connections" })
	txn:sidebar_item(connect, { label = panels[1] })
	txn:sidebar_item(connect, { label = panels[2] })
	local device = txn:sidebar_section(sidebar, { title = "Device" })
	txn:sidebar_item(device, { label = panels[3] })
	txn:sidebar_item(device, { label = panels[4] })
	txn:widget_set_value(sidebar, 0)
	stack = txn:navigation_stack(row)
	show(txn, 1)
end)

app:run()
