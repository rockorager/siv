-- An image viewer: Open asks the desktop's file chooser for an image,
-- decodes it on a worker thread, and shows it. Each step is asynchronous,
-- and the code reads top to bottom: in a coroutine (siv.spawn), a call
-- given no callback waits for its result.
--
--     zig build && ./zig-out/bin/siv-lua examples/viewer.lua [image]
local siv = require("siv")

local app = siv.app_create{ app_id = "dev.siv.examples.viewer" }
local win = app:window_create{ title = "Viewer", app_id = "dev.siv.examples.viewer", width = 640, height = 480 }

local view, status
local image -- the image shown; the node holds its own reference

local function show(path)
	win:update(function(txn)
		txn:set_text(status, "Loading " .. path)
	end)
	local ok, loaded = pcall(app.image_load, app, { path = path, max_width = 1920, max_height = 1920 })
	win:update(function(txn)
		if ok then
			image = loaded
			txn:set_image_view(view, { image = image, fit = "contain" })
			local size = image:get_size()
			txn:set_text(status, ("%s, %d by %d"):format(path, size.width, size.height))
		else
			txn:set_text(status, ("Cannot open %s: %s"):format(path, tostring(loaded)))
		end
	end)
end

local function open()
	local chooser <close> = app:file_chooser_create{ title = "Open an image" }
	chooser:add_filter("Images")
	chooser:add_pattern("mime", "image/*")
	local result = chooser:show(win)
	if result.response == "success" and result.count > 0 then
		show(chooser:get_path(0))
	elseif result.response ~= "cancelled" then
		win:update(function(txn)
			txn:set_text(status, "No file chooser: " .. result.response)
		end)
	end
end

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
	local column = txn:flex(root, { axis = "column", gap = 8 }, {
		layout = { padding = 12, height = { "fraction", 1 } },
	})
	local bar = txn:flex(column, { gap = 8, align_items = "center" })
	txn:push_button(bar, { label = "Open…", style = "primary" }, {
		on = { activate = function()
			siv.spawn(open)
			return true
		end },
	})
	status = txn:text(bar, "Open an image", { text_style = { color_token = "muted_fg" } })
	view = txn:image_view(column, nil, {
		layout = { grow = 1, basis = 0 },
		visual = { background_token = "view_bg", radius = 6 },
		semantics = { label = "Image" },
	})
end)

local path = ...
if path then
	siv.spawn(show, path)
end

app:run()
