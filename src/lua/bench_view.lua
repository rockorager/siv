-- siv.view against the same work written imperatively (D45), on the
-- headless backend: the Lua side of each update, transaction and commit
-- included; the frame that follows does the same work either way. The
-- imperative reorder is the generic one a program writes by hand: every
-- row moved, in the new order.
--
--     zig build -Doptimize=ReleaseFast && ./zig-out/bin/siv-lua src/lua/bench_view.lua
local siv = require("siv")
local view = require("siv.view")
local ui = view.ui

local app = siv.app_create{ backend = "headless", flags = { "no_system_fonts", "reduced_motion" } }
local font = assert(io.open("src/text/testdata/DroidSans.ttf", "rb"))
app:add_font("Droid", font:read("a"))
font:close()
app:set_default_font("Droid")

local function median(t)
	table.sort(t)
	return t[(#t + 1) // 2]
end

-- Lua has no wall clock finer than a second, and os.clock() is the
-- process's CPU time, worker threads included: so every run starts and
-- ends with the application settled (frames presented, the pool idle),
-- and the time is the application thread's.
local function settle()
	assert(app:test_settle(20000), "did not settle")
end

-- Runs fn() n times (prepare() untimed before each) and returns the
-- median in microseconds.
local function time(n, fn, prepare)
	local samples = {}
	for i = 1, n do
		if prepare then
			prepare(i)
		end
		settle()
		local t0 = os.clock()
		fn(i)
		samples[i] = (os.clock() - t0) * 1e6
	end
	settle()
	return median(samples)
end

local function report(name, imperative, reactive)
	print(("%-44s %10.1f µs %10.1f µs %6.2fx"):format(name, imperative, reactive, reactive / imperative))
end

print(("%-44s %13s %13s %7s"):format("", "imperative", "siv.view", "ratio"))

-- A tree of 10,000 nodes: 1,000 rows of a box, a flex, and 8 texts, the
-- view's with a binding on every 2nd text (5,000 bindings).
local ROWS = 1000

local function build_imperative()
	local win = app:window_create{ width = 400, height = 300 }
	local labels = {}
	local t0 = os.clock()
	win:update(function(t, root)
		local scroll = t:scroll(root, "vertical")
		for r = 1, ROWS do
			local box = t:box(scroll)
			local row = t:flex(box, { gap = 4 })
			for k = 1, 8 do
				labels[(r - 1) * 8 + k] = t:text(row, "cell " .. k)
			end
		end
	end)
	return win, labels, (os.clock() - t0) * 1e6
end

local function build_reactive()
	local win = app:window_create{ width = 400, height = 300 }
	local setters = {}
	local t0 = os.clock()
	local dispose = view.mount(win, function()
		ui.scroll("vertical", function()
			for r = 1, ROWS do
				ui.box(function()
					ui.flex({ gap = 4 }, function()
						for k = 1, 8 do
							if k % 2 == 0 then
								local get, set = view.signal("cell " .. k)
								setters[(r - 1) * 8 + k] = set
								ui.text(get)
							else
								ui.text("cell " .. k)
							end
						end
					end)
				end)
			end
		end)
	end)
	return win, setters, (os.clock() - t0) * 1e6, dispose
end

settle()
local iwin, labels, ibuild = build_imperative()
settle()
local rwin, setters, rbuild, rdispose = build_reactive()
settle()
report("build 10k nodes (one transaction)", ibuild, rbuild)

local N = 200
local i_update = time(N, function(i)
	iwin:update(function(t)
		t:set_text(labels[4000], "updated " .. i)
	end)
end)
local r_update = time(N, function(i)
	setters[4000]("updated " .. i)
end)
report("update 1 label of 10k nodes (5k bindings)", i_update, r_update)

local i_many = time(N, function(i)
	iwin:update(function(t)
		for k = 2, 80, 2 do
			t:set_text(labels[k], "u" .. i)
		end
	end)
end)
local r_many = time(N, function(i)
	view.batch(function()
		for k = 2, 80, 2 do
			setters[k]("u" .. i)
		end
	end)
end)
report("update 40 labels in one batch", i_many, r_many)
iwin:destroy()
rdispose()
rwin:destroy()

-- A keyed list of 1,000 rows (a box with a text each), reordered.
local KEYS = 1000
local base = {}
for i = 1, KEYS do
	base[i] = { name = "row " .. i }
end

local function reversed(list)
	local out = {}
	for i = #list, 1, -1 do
		out[#out + 1] = list[i]
	end
	return out
end

local function shuffled(list, seed)
	local out = { table.unpack(list) }
	local x = seed
	for i = #out, 2, -1 do
		x = (x * 1103515245 + 12345) % 2147483648
		local j = x % i + 1
		out[i], out[j] = out[j], out[i]
	end
	return out
end

local function moved_one(list)
	local out = { table.unpack(list, 2) }
	out[#out + 1] = list[1]
	return out
end

local orders = {
	{ "reverse 1k keyed rows", reversed },
	{ "shuffle 1k keyed rows", function(l, i)
		return shuffled(l, i)
	end },
	{ "move 1 of 1k keyed rows", moved_one },
}

-- Imperative, by hand: the rows by item, and moves that put them in the
-- new order (each row moved to the end, in order: as many moves as rows,
-- the cheapest code to write by hand that is correct for any order).
local function imperative_list()
	local win = app:window_create{ width = 300, height = 300 }
	local rows, list, order = {}, nil, base
	win:update(function(t, root)
		list = t:flex(root, { axis = "column" })
		for _, item in ipairs(base) do
			local row = t:box(list)
			t:text(row, item.name)
			rows[item] = row
		end
	end)
	return win, function(new)
		win:update(function(t)
			for _, item in ipairs(new) do
				t:move(rows[item], list, nil)
			end
		end)
		order = new
	end, function()
		return order
	end, function(new)
		-- Rebuilding every row: what a layer without keys does.
		win:update(function(t)
			t:clear(list)
			for _, item in ipairs(new) do
				local row = t:box(list)
				t:text(row, item.name)
				rows[item] = row
			end
		end)
		order = new
	end
end

local function reactive_list()
	local win = app:window_create{ width = 300, height = 300 }
	local items, set_items = view.signal(base)
	local dispose = view.mount(win, function()
		ui.flex({ axis = "column" }, function()
			view.each(items, function(item)
				ui.box(function()
					ui.text(item.name)
				end)
			end)
		end)
	end)
	return win, set_items, function()
		return view.peek(items)
	end, dispose
end

local M = 50
for _, o in ipairs(orders) do
	local name, reorder = o[1], o[2]
	local iw, ireorder, iorder = imperative_list()
	local rw, rset, rorder, rdispose_list = reactive_list()
	local inext, rnext
	local it = time(M, function()
		ireorder(inext)
	end, function(i)
		inext = reorder(iorder(), i)
	end)
	local rt = time(M, function()
		rset(rnext)
	end, function(i)
		rnext = reorder(rorder(), i)
	end)
	report(name, it, rt)
	iw:destroy()
	rdispose_list()
	rw:destroy()
end

do
	local iw, _, iorder, rebuild = imperative_list()
	local inext
	local it = time(M, function()
		rebuild(inext)
	end, function(i)
		inext = shuffled(iorder(), i)
	end)
	print(("%-44s %10.1f µs"):format("shuffle 1k rows by rebuilding them", it))
	iw:destroy()
end

print(("live computations after the windows went: %d"):format(view.stats().computations))
