-- A settings form built from stock widgets (D22), in the desktop's theme.
-- The Lua version of widgets.c, written with siv.view.
--
--     zig build && ./zig-out/bin/siv-lua examples/widgets.lua
--
-- Widgets are built like any node, report what the user did through
-- handlers, and take their label, value, and disabled state from
-- properties, which follow signals when given as functions.
local siv = require("siv")
local view = require("siv.view")
local ui = view.ui

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

local volume, set_volume = view.signal(40)

local function Settings()
	ui.flex({ axis = "column", gap = 14, align_items = "start" }, { layout = { padding = 24 } }, function()
		ui.text("Settings", {
			text_style = { color_token = "window_fg", size_role = "title", weight = "bold" },
			semantics = { role = "heading" },
		})

		ui.text_field({ placeholder = "Your name" }, { on = { change = report("name") } })

		ui.switch({ label = "Dark theme" }, {
			on = {
				-- The theme follows the desktop unless the application chooses.
				change = function(_, ev)
					app:set_theme{ scheme = ev.value ~= 0 and "dark" or "follow" }
					return true
				end,
			},
		})
		ui.check_box({ label = "Install updates automatically", checked = "on" }, {
			on = { change = report("updates") },
		})

		-- A widget's value is a property, set once its radios exist.
		ui.radio_group({ label = "Quality", axis = "column" }, { value = 1, on = { change = report("quality") } }, function()
			for _, label in ipairs{ "Low", "Balanced", "High" } do
				ui.radio{ label = label }
			end
		end)

		ui.combo_box({ label = "Format" }, { on = { change = report("format") } }, function()
			for _, label in ipairs{ "PNG", "JPEG", "WebP" } do
				ui.combo_box_item{ label = label }
			end
		end)

		-- The slider sets the volume; the label and the level follow it.
		-- Setting a value from the application does not report a change.
		ui.text(function()
			return ("Volume: %.0f"):format(volume())
		end, { text_style = { color_token = "muted_fg", size_role = "caption" } })
		ui.slider({ label = "Volume", value = 40, step = 1 }, {
			layout = { width = 260 },
			on = {
				change = function(_, ev)
					set_volume(ev.value)
					return true
				end,
			},
		})
		ui.progress_bar({ label = "Level" }, { layout = { width = 260 }, value = volume })

		ui.spin_button({ label = "Copies", min = 1, max = 10, value = 1 }, {
			on = { change = report("copies") },
		})

		ui.flex({ gap = 8 }, function()
			ui.push_button{ label = "Cancel" }
			ui.push_button({ label = "Save", style = "primary" }, {
				tooltip = "Saves the settings",
				on = { activate = function()
					print("saved")
					return true
				end },
			})
		end)
	end)
end

win:update(function(txn, root)
	-- Themed colors follow the desktop's scheme, contrast, and accent.
	txn:set_visual(root, { background_token = "window_bg" })
end)
view.mount(win, Settings)

app:run()
