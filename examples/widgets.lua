-- A settings form built from stock widgets (D22), in the desktop's theme.
-- The Lua version of widgets.c.
--
--     zig build && ./zig-out/bin/siv-lua examples/widgets.lua
--
-- Widgets are built like any node, driven with widget_set_value and
-- friends, and report what the user did through handlers on the node the
-- builder returned.
local siv = require("siv")

local app = siv.app_create()
local win = app:window_create{ title = "Settings", width = 420, height = 520 }

-- Every widget with a value reports it in ev.value; choices also put the
-- chosen index in ev.index.
local function report(name)
	return function(_, ev)
		print(("%s: %g (index %d)"):format(name, ev.value, ev.index))
		return true
	end
end

win:update(function(txn, root)
	-- Themed colors follow the desktop's scheme, contrast, and accent.
	txn:set_visual(root, { background_token = "window_bg" })
	local column = txn:flex(root, { axis = "column", gap = 14, align_items = "start" }, {
		layout = { padding = 24 },
	})

	txn:text(column, "Settings", {
		text_style = { color_token = "window_fg", size_role = "title", weight = "bold" },
		semantics = { role = "heading" },
	})

	txn:text_field(column, { placeholder = "Your name" }, { on = { change = report("name") } })

	txn:switch(column, { label = "Dark theme" }, {
		on = {
			-- The theme follows the desktop unless the application chooses.
			change = function(_, ev)
				app:set_theme{ scheme = ev.value ~= 0 and "dark" or "follow" }
				return true
			end,
		},
	})
	txn:check_box(column, { label = "Install updates automatically", checked = "on" }, {
		on = { change = report("updates") },
	})

	local quality = txn:radio_group(column, { label = "Quality", axis = "column" }, {
		on = { change = report("quality") },
	})
	for _, label in ipairs{ "Low", "Balanced", "High" } do
		txn:radio(quality, label)
	end
	txn:widget_set_value(quality, 1)

	local volume_label = txn:text(column, "Volume: 40", {
		text_style = { color_token = "muted_fg", size_role = "caption" },
	})
	local progress
	txn:slider(column, { label = "Volume", value = 40, step = 1 }, {
		layout = { width = 260 },
		on = {
			change = function(_, ev)
				ev.window:update(function(t)
					t:set_text(volume_label, ("Volume: %.0f"):format(ev.value))
					-- Setting a value from the application does not report a
					-- change.
					t:widget_set_value(progress, ev.value)
				end)
				return true
			end,
		},
	})
	progress = txn:progress_bar(column, { label = "Level", value = 40 }, { layout = { width = 260 } })

	txn:spin_button(column, { label = "Copies", min = 1, max = 10, value = 1 }, {
		on = { change = report("copies") },
	})

	local buttons = txn:flex(column, { gap = 8 })
	txn:push_button(buttons, { label = "Cancel" })
	txn:push_button(buttons, { label = "Save", style = "primary" }, {
		on = { activate = function()
			print("saved")
			return true
		end },
	})
end)

app:run()
