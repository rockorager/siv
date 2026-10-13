-- Asynchronous work in Lua: in a coroutine (siv.spawn), calls that would
-- take a callback (image loads, portals, clipboard reads, jobs) wait for their
-- result instead, so each step reads in order. The application's thread
-- keeps running meanwhile.
--
--     ./zig-out/bin/siv-lua docs/guide/examples/async.lua
local siv = require("siv")

local app = siv.app_create()
local win = app:window_create{ title = "Async", width = 360, height = 300 }

local status, view

local function say(text)
	win:update(function(txn)
		txn:set_text(status, text)
	end)
end

-- Decodes on a worker thread; a failed load raises, so pcall catches it.
local function show(path)
	say("Loading " .. path:match("[^/]*$"))
	local ok, image = pcall(app.image_load, app, { path = path, max_width = 320, max_height = 180 })
	if not ok then
		say("Cannot load it: " .. tostring(image))
		return
	end
	local size = image:get_size()
	win:update(function(txn)
		txn:set_image_view(view, { image = image, fit = "contain" })
		txn:set_text(status, ("%s, %d × %d"):format(path:match("[^/]*$"), size.width, size.height))
	end)
end

-- The desktop's file chooser, through the portal: show waits until the
-- user answers.
local function open()
	local chooser <close> = app:file_chooser_create{ title = "Open an image" }
	chooser:add_filter("Images")
	chooser:add_pattern("mime", "image/*")
	local result = chooser:show(win)
	if result.response == "success" then
		show(chooser:get_path(0))
	else
		say("No image chosen (" .. result.response .. ")")
	end
end

-- CPU-bound work runs on the worker pool, in a Lua state of its own: it
-- sees its arguments and the standard libraries, not this file's locals,
-- and its results come back as copies.
local function count_primes(limit)
	local n = 0
	for i = 2, limit - 1 do
		local prime = true
		for d = 2, math.floor(math.sqrt(i)) do
			if i % d == 0 then
				prime = false
				break
			end
		end
		if prime then n = n + 1 end
	end
	return n
end

local function count()
	say("Counting…")
	local n = app:job_start("compute", count_primes, { 50000 })
	say(("%d primes below 50000"):format(n))
end

local function paste()
	local text = win:clipboard_read("clipboard")
	say(text and ("Pasted: " .. text) or "Nothing to paste")
end

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
	local column = txn:flex(root, { axis = "column", gap = 10 }, {
		layout = { padding = 16, width = { "fraction", 1 } },
	})
	local bar = txn:flex(column, { gap = 8 })
	-- Handlers return at once; the coroutine runs until it waits.
	txn:push_button(bar, { label = "Open…", style = "primary" }, {
		on = { activate = function()
			siv.spawn(open)
			return true
		end },
	})
	txn:push_button(bar, { label = "Paste" }, {
		on = { activate = function()
			siv.spawn(paste)
			return true
		end },
	})
	txn:push_button(bar, { label = "Count primes" }, {
		on = { activate = function()
			siv.spawn(count)
			return true
		end },
	})
	view = txn:image_view(column, nil, {
		layout = { height = 180 },
		visual = { background_token = "view_bg", radius = 6 },
		semantics = { label = "Image" },
	})
	status = txn:text(column, "Starting", { text_style = { color_token = "muted_fg" } })
end)

-- A sequence with waits in it: a timer, then a decode.
siv.spawn(function()
	app:sleep(100)
	show("docs/guide/examples/data/landscape.png")
end)

app:run()
