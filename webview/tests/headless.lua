-- siv.webview on siv's headless backend: run by `zig build test-webview` through
-- siv-webview-lua, with the engine rendering in software.
local siv = require("siv")
local webview = require("siv.webview")

if not webview.available() then
	print("siv.webview: no engine available; skipped")
	return
end

local app = siv.app_create{ backend = "headless" }
local win = app:window_create{ width = 300, height = 200 }

local seen = { titles = {}, messages = {} }
local wv = webview.create(win, {
	flags = "ephemeral",
	on = {
		title = function(_, ev)
			seen.title = ev.text
		end,
		message = function(_, ev)
			seen.messages[#seen.messages + 1] = ev.name .. " " .. ev.text
		end,
		navigate = function(_, ev)
			return ev.uri:find("blocked", 1, true) ~= nil
		end,
	},
})

local page
win:update(function(txn, root)
	page = wv:view(txn, root)
	txn:set_layout(page, { width = { "fraction", 1 }, height = { "fraction", 1 } })
end)
assert(page and wv:node() == page, "the view is the web view's node")

local function wait(cond, what)
	for _ = 1, 1500 do
		if cond() then
			return
		end
		app:dispatch(20)
	end
	error("timed out waiting for " .. what, 2)
end

-- The app's own scheme serves the page.
local requests = 0
webview.register_scheme(app, "app", function(req, uri, method)
	requests = requests + 1
	if uri == "app://lua/index.html" and method == "GET" then
		req:finish("<title>from Lua</title><script>siv.postMessage({n: 1})</script>", "text/html")
	else
		req:fail()
	end
end)
wv:load_uri("app://lua/index.html")
wait(function() return seen.title == "from Lua" end, "the title")
assert(wv:title() == "from Lua")
assert(wv:uri() == "app://lua/index.html")
wait(function() return #seen.messages == 1 end, "a message")
assert(seen.messages[1] == 'siv {"n":1}', seen.messages[1])
assert(requests == 1)

-- Scripts and messages both ways.
local result, err
wv:run_script("[6 * 7, document.title]", function(json, e) result, err = json, e end)
wait(function() return result or err end, "the script")
assert(result == '[42,"from Lua"]', result or err)
result, err = nil, nil
wv:run_script("throw new Error('lua')", function(json, e) result, err = json, e end)
wait(function() return result or err end, "the failing script")
assert(result == nil and err:find("lua", 1, true), tostring(err))

wv:add_message_handler("back")
wv:run_script("siv.onmessage = e => webkit.messageHandlers.back.postMessage(e.data.s + '!')")
wv:post_message('{"s": "hi"}')
wait(function() return #seen.messages == 2 end, "the reply")
assert(seen.messages[2] == 'back "hi!"', seen.messages[2])
assert(not pcall(wv.post_message, wv, "not json"))

-- Navigation policy: the page cannot leave for a blocked URL.
wv:run_script("location.href = 'app://lua/blocked'")
for _ = 1, 20 do app:dispatch(10) end
assert(wv:uri() == "app://lua/index.html", wv:uri())

-- State, zoom, and history.
wv:set_zoom(1.5)
local st = wv:state()
assert(st.zoom == 1.5 and not st.can_go_back)
assert(wv:go_back() == false)

wv:destroy()
assert(not pcall(wv.load_uri, wv, "about:blank"), "a destroyed web view refuses calls")
print("siv.webview: ok")
