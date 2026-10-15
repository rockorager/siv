-- A small browser in Lua: back, forward, reload, an address bar, and a web
-- view. The Lua version of browser.c.
--
--     zig build && ./zig-out/bin/siv-webview-lua examples/webview-browser.lua [URL]
--
-- Ctrl+L focuses the address bar; the page's title is the window's.
local siv = require("siv")
local webview = require("siv.webview")

local start = ... or "https://example.com"

local app = siv.app_create{ name = "Browser (Lua)", app_id = "dev.siv.WebviewBrowserLua" }
local win = app:window_create{ title = "Browser", app_id = "dev.siv.WebviewBrowserLua", width = 1280, height = 800 }

local back, forward, address, page

local wv = webview.create(win, {
	on = {
		title = function(_, ev)
			if ev.text ~= "" then
				win:set_title(ev.text)
			end
		end,
		uri = function(_, ev)
			win:update(function(txn)
				txn:set_text(address, ev.uri)
			end)
		end,
		history = function(_, ev)
			win:update(function(txn)
				txn:widget_set_disabled(back, not ev.can_go_back)
				txn:widget_set_disabled(forward, not ev.can_go_forward)
			end)
		end,
		load_failed = function(_, ev)
			io.stderr:write(("browser: %s: %s\n"):format(ev.uri, ev.text))
		end,
		-- A real browser would ask; this one says no.
		permission = function()
			return false
		end,
	},
})

-- What the user typed, as a URL.
local function go(text)
	if text == "" then
		return
	end
	local uri = text
	if text:sub(1, 1) == "/" then
		uri = "file://" .. text
	elseif not text:find("://", 1, true) and not text:find("^about:") then
		uri = "https://" .. text
	end
	wv:load_uri(uri)
	page:focus()
end

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
	-- Window-wide shortcuts, before the page or the field sees the key.
	txn:on_capture(root, "key", function(_, ev)
		if not ev.flags.pressed then
			return false
		end
		local ctrl, alt = ev.modifiers.ctrl, ev.modifiers.alt
		if ctrl and (ev.keysym == "l" or ev.keysym == "L") then
			-- Focused with its text selected, so typing replaces it.
			local text = address:get_text()
			win:update(function(t)
				t:set_selection(address, #text, 0)
			end)
			address:focus()
			return true
		elseif alt and ev.keysym == "left" then
			return wv:go_back()
		elseif alt and ev.keysym == "right" then
			return wv:go_forward()
		elseif (ctrl and (ev.keysym == "r" or ev.keysym == "R")) or ev.keysym == "f5" then
			wv:reload()
			return true
		end
		return false
	end)
	local column = txn:flex(root, { axis = "column" }, { layout = { width = { "fraction", 1 }, height = { "fraction", 1 } } })
	local bar = txn:flex(column, { axis = "row", gap = 6, align_items = "center" }, {
		layout = { width = { "fraction", 1 }, padding = 6 },
	})
	local function button(label, icon, flags, fn)
		return txn:push_button(bar, { label = label, icon = icon, flags = flags }, { on = { activate = fn } })
	end
	back = button("Back", "go-previous-symbolic", { "icon_only", "disabled" }, function()
		wv:go_back()
		return true
	end)
	forward = button("Forward", "go-next-symbolic", { "icon_only", "disabled" }, function()
		wv:go_forward()
		return true
	end)
	button("Reload", "view-refresh-symbolic", { "icon_only" }, function()
		wv:reload()
		return true
	end)
	address = txn:text_field(bar, { placeholder = "Search or enter address", label = "Address" }, { layout = { grow = 1 } })
	txn:on(address, "key", function(node, ev)
		if not ev.flags.pressed or (ev.keysym ~= "return" and ev.keysym ~= "kp_enter") then
			return false
		end
		go(node:get_text())
		return true
	end)
	page = wv:view(txn, column)
	txn:set_layout(page, { width = { "fraction", 1 }, basis = { "px", 0 }, grow = 1 })
end)

wv:load_uri(start)
page:focus()
app:run()
