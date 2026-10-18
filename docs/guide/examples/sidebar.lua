-- Themes for part of a window: a sidebar that stays dark in a light
-- window, a banner in the scheme opposite the window's, and a section
-- with an accent of its own. Stock widgets in them, and menus opened
-- from them, follow; so do the desktop's accent and the user's theme.
--
--     ./zig-out/bin/siv-lua docs/guide/examples/sidebar.lua
local siv = require("siv")

local app = siv.app_create()
local win = app:window_create{ title = "Notes", width = 560, height = 320 }

local places = { "All notes", "Favorites", "Shared", "Trash" }

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
	local row = txn:flex(root, {}, { layout = { width = { "fraction", 1 }, height = { "fraction", 1 } } })

	-- Dark whatever the desktop's scheme: every themed color in the
	-- sidebar resolves in the dark variant of the theme.
	local sidebar = txn:flex(row, { axis = "column", gap = 8 }, {
		theme = { scheme = "dark" },
		layout = { width = 170, padding = { 8, 8, 12, 12 } },
		visual = { background_token = "sidebar_bg" },
	})
	txn:text(sidebar, "Notes", {
		layout = { padding = { 8, 0, 0, 0 } },
		text_style = { size_role = "heading", weight = "bold", color_token = "view_fg" },
	})
	local list = txn:list_view(sidebar, {
		label = "Places",
		count = #places,
		item_height = 30,
		selection = "single",
		flags = "flat",
		bind = function(t, row_node, item, _, _, recycled)
			if not recycled then
				t:text(row_node, "", { text_style = { color_token = "view_fg" } })
			end
			t:set_text(row_node:get_related("first_child"), places[item + 1])
		end,
	}, {
		-- On the sidebar's own surface rather than a view's.
		layout = { grow = 1 },
		visual = { background_token = "sidebar_bg", flags = "clip" },
	})
	txn:view_set_selection(list, "\1")
	local more = txn:menu_button(sidebar, { label = "More" })
	txn:menu_item(more, { label = "New folder" })
	txn:menu_item(more, { label = "Show counts", flags = "checked" })
	txn:menu_item(more, { label = "Empty trash", flags = "disabled" })

	-- The rest follows the window.
	local main = txn:flex(row, { axis = "column", gap = 12, align_items = "start" }, {
		layout = { grow = 1, padding = 20 },
		visual = { background_token = "view_bg" },
	})
	txn:text(main, "Groceries", {
		text_style = { size_role = "title", weight = "bold", color_token = "view_fg" },
		semantics = { role = "heading", level = 1 },
	})
	txn:check_box(main, { label = "Milk", checked = "on" })
	txn:check_box(main, { label = "Bread" })

	-- The opposite of the window's scheme, so it stands out in either.
	local banner = txn:flex(main, { gap = 12, align_items = "center" }, {
		theme = { scheme = "inverse" },
		layout = { padding = { 12, 6, 6, 6 } },
		visual = { background_token = "card_bg", radius = 6 },
	})
	txn:text(banner, "Shared with Ana", { text_style = { color_token = "card_fg" } })
	txn:push_button(banner, { label = "Stop sharing" })

	-- An accent for one section: what derives from it (hover and pressed
	-- shades, focus rings, selections) follows, in every variant.
	local section = txn:flex(main, { gap = 12, align_items = "center" })
	txn:set_theme_color(section, "all", "accent", { r = 0.05, g = 0.58, b = 0.53, a = 1 })
	txn:push_button(section, { label = "Add item", style = "primary" })
	txn:switch(section, { label = "Remind me", checked = "on" })
end)

app:run()
