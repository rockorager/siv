-- A custom widget on a canvas: a dial that shows a value as an arc with a
-- gradient and a centered label, and changes it by dragging or with the
-- arrow keys. Only the canvas redraws when the value changes. The Lua
-- version of gauge.c.
--
--     zig build && ./zig-out/bin/siv-lua examples/gauge.lua
local siv = require("siv")

local pi = math.pi
local start, sweep = 0.75 * pi, 1.5 * pi

local app = siv.app_create()
local win = app:window_create{ title = "Gauge", width = 260, height = 260 }

local value = 0 -- 0 to 1
local dragging = false
local canvas

local function draw(_, d, w, h)
	local cx, cy, r = w / 2, h / 2, math.min(w, h) / 2 - 12
	-- The track.
	d:arc(cx, cy, r, start, start + sweep)
	d:stroke({ width = 14, cap = "round" }, { color = "#e3e3e8" })
	-- The value, with a sweep gradient around the dial.
	if value > 0 then
		d:arc(cx, cy, r, start, start + sweep * value)
		d:stroke({ width = 14, cap = "round" }, {
			type = "sweep",
			stops = { { 0, "#2563eb" }, { 1, "#db2777" } },
			x0 = cx, y0 = cy, start_angle = start, end_angle = start + sweep,
		})
	end
	d:text(0, cy - 18, w, ("%d%%"):format(math.floor(value * 100 + 0.5)), {
		font_size = 28, weight = "semibold", align = "center",
	})
end

local function set_value(v)
	v = math.max(0, math.min(1, v))
	if v == value then
		return
	end
	value = v
	win:update(function(txn)
		txn:set_semantics(canvas, {
			role = "slider", label = "Volume", flags = { "focusable", "has_value" },
			value_max = 1, value_now = v,
		})
		txn:invalidate(canvas)
	end)
end

win:update(function(txn, root)
	txn:set_visual(root, { background = "#ffffff" })
	txn:set_stack(root, { align_x = "center", align_y = "center" })
	canvas = txn:canvas(root, { draw = draw, width = 220, height = 220 }, {
		on = {
			-- The angle of the pointer around the center sets the value.
			pointer = function(node, e)
				if e.phase == "down" then
					dragging = true
				elseif e.phase == "up" or e.phase == "cancel" then
					dragging = false
				end
				if not dragging then
					return false
				end
				local box = node:get_rect()
				local a = math.atan(e.y - box.height / 2, e.x - box.width / 2) - start
				while a < 0 do
					a = a + 2 * pi
				end
				if a > sweep then
					a = a > 1.75 * pi and 0 or sweep
				end
				set_value(a / sweep)
				return true
			end,
			key = function(_, e)
				if not e.flags.pressed then
					return false
				end
				if e.keysym == siv.keysym.Left then
					set_value(value - 0.05)
				elseif e.keysym == siv.keysym.Right then
					set_value(value + 0.05)
				else
					return false
				end
				return true
			end,
		},
	})
end)
set_value(0.4)
canvas:focus()

app:run()
