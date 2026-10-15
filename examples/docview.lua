-- A Markdown and HTML viewer in Lua: a document node (D32) in a scroll
-- node, with find. Links to local files open here; resources come from
-- local files only (siv never fetches anything).
--
--     zig build && ./zig-out/bin/siv-lua examples/docview.lua README.md
local siv = require("siv")

local path = ... or "README.md"
local app = siv.app_create{ app_id = "dev.siv.examples.docview" }
local win = app:window_create{ title = path, app_id = "dev.siv.examples.docview", width = 800, height = 900 }

local scroll, doc, status

local function read(file)
	local f = io.open(file, "rb")
	if not f then return nil end
	local bytes = f:read("a")
	f:close()
	return bytes
end

local open

local function show(file)
	local bytes = read(file)
	if not bytes then
		win:update(function(txn) txn:set_text(status, "Cannot read " .. file) end)
		return
	end
	local kind = file:match("%.md$") and "markdown" or file:match("%.txt$") and "text" or "html"
	win:update(function(txn)
		if doc then txn:remove(doc) end
		doc = txn:docview(scroll, {
			source = bytes,
			base_url = "file://" .. file,
			kind = kind,
			load = function(node, request, url)
				local local_path = url:match("^file://(.*)$")
				node:docview_supply(request, local_path and read(local_path) or "")
			end,
			on_event = function(_, event)
				if event.type == "link" then
					local target = event.url:match("^file://([^#]*)")
					if target and (target:match("%.md$") or target:match("%.html?$")) then
						siv.post(app, function() open(target) end)
					else
						print("link: " .. event.url)
					end
				elseif event.type == "find" then
					win:update(function(t)
						t:set_text(status, event.count == 0 and "No matches" or ("%d of %d"):format(event.current, event.count))
					end)
				end
			end,
		}, { layout = { padding = { 16, 16, 8, 8 } } })
	end)
end
open = show

win:update(function(txn, root)
	local column = txn:flex(root, { axis = "column" }, { layout = { width = { "fraction", 1 }, height = { "fraction", 1 } } })
	local bar = txn:flex(column, { axis = "row", gap = 8, align_items = "center" }, { layout = { padding = { 8, 8, 6, 6 } } })
	local find = txn:editor(bar)
	txn:set_layout(find, { width = 240 })
	txn:set_placeholder(find, "Find")
	txn:on(find, "key", function(node, event)
		if event.keysym ~= siv.key.RETURN or not event.flags.pressed then return "pass" end
		doc:docview_find(node:get_text(), event.modifiers.shift)
		return "handled"
	end)
	status = txn:text(bar, "")
	scroll = txn:scroll(column, "vertical", { layout = { width = { "fraction", 1 }, grow = 1 } })
end)
show(path)
app:run()
