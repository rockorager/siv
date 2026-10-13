-- Drawing with a tablet (D16): strokes follow the pen's pressure, sample
-- by sample, though motion arrives once a frame; the eraser end erases,
-- a mouse draws at half pressure, and the sheet zooms with a touchpad
-- pinch or Ctrl+wheel. A pad's first button clears the sheet and its
-- ring sets the brush size.
--
--     zig build && ./zig-out/bin/siv-lua examples/sketch.lua
local siv = require("siv")

local app = siv.app_create()
local win = app:window_create{ title = "Sketch", width = 640, height = 480 }

local strokes = {} -- each { eraser = bool, points = { {x, y, pressure}, ... } }
local current
local brush = 8
local canvas

local function draw(_, d, w, h)
	d:rect(0, 0, w, h)
	d:fill({ color = "#ffffff" })
	for _, s in ipairs(strokes) do
		local color = s.eraser and "#ffffff" or "#1e293b"
		local pts = s.points
		for i = 2, #pts do
			local a, b = pts[i - 1], pts[i]
			d:move_to(a[1], a[2])
			d:line_to(b[1], b[2])
			d:stroke({ width = 1 + brush * b[3], cap = "round" }, { color = color })
		end
	end
end

local function redraw()
	win:update(function(txn)
		txn:invalidate(canvas)
	end)
end

local function add(samples)
	for _, p in ipairs(samples) do
		table.insert(current.points, { p.x, p.y, p.pressure })
	end
end

local function begin(eraser, x, y, pressure)
	current = { eraser = eraser, points = { { x, y, pressure } } }
	table.insert(strokes, current)
end

win:update(function(txn, root)
	txn:set_visual(root, { background = "#e2e8f0" })
	local sheet = txn:scroll(root, "both", { layout = { width = { unit = "fraction", value = 1 }, height = { unit = "fraction", value = 1 } } })
	txn:set_scroll_zoom_range(sheet, 0.5, 4)
	canvas = txn:canvas(sheet, { draw = draw, width = 600, height = 440 }, {
		on = {
			tablet = function(_, e)
				if e.phase == "down" and e.button == "primary" then
					begin(e.tool == "eraser", e.x, e.y, e.pressure)
				elseif e.phase == "move" and current and e.flags.tip then
					add(e.samples)
				elseif e.phase == "up" and e.button == "primary" then
					current = nil
				else
					return true
				end
				redraw()
				return true
			end,
			pointer = function(_, e)
				if e.phase == "down" and e.button == "primary" then
					begin(false, e.x, e.y, 0.5)
				elseif e.phase == "move" and current then
					table.insert(current.points, { e.x, e.y, 0.5 })
				elseif e.phase == "up" or e.phase == "cancel" then
					current = nil
					return false
				else
					return false
				end
				redraw()
				return true
			end,
		},
	})
	txn:on(root, "pad", function(_, e)
		if e.pad_control == "button" and e.index == 0 and e.flags.pressed then
			strokes = {}
			redraw()
		elseif e.pad_control == "ring" and not e.flags.lifted then
			brush = 2 + 14 * e.value / 360
			redraw()
		end
		return true
	end)
end)

app:run()
