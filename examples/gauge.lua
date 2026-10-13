-- A custom widget on a canvas: a dial that shows a value as an arc with a
-- gradient and a centered label, and changes it by dragging, with the
-- arrow keys, or from assistive technology. Only the canvas redraws when
-- the value changes. The Lua version of gauge.c: a widget like the stock
-- ones, whose widget interface makes widget_set_value, widget_get_value,
-- widget_set_label, and widget_set_disabled work on it as on a slider.
--
--     zig build && ./zig-out/bin/siv-lua examples/gauge.lua
local siv = require("siv")

local pi = math.pi
local start, sweep = 0.75 * pi, 1.5 * pi

local app = siv.app_create()
local win = app:window_create{ title = "Gauge", width = 260, height = 260 }

local value = 0 -- 0 to 1
local label = ""
local disabled = false
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

-- Shows the state in the caller's transaction: what assistive technology
-- sees, and a redraw.
local function apply(txn)
	txn:set_semantics(canvas, {
		role = "slider", label = label,
		flags = { disabled and "disabled" or "focusable", "has_value" },
		value_max = 1, value_step = 0.05, value_now = value,
	})
	txn:invalidate(canvas)
end

-- The user changed the value: commit it in a transaction of the widget's
-- own, then report it, as stock widgets do.
local function user_set(v)
	v = math.max(0, math.min(1, v))
	if v == value or disabled then
		return
	end
	value = v
	win:update(apply)
	canvas:emit{ type = "change", value = v }
end

win:update(function(txn, root)
	txn:set_visual(root, { background = "#ffffff" })
	txn:set_stack(root, { align_x = "center", align_y = "center" })
	canvas = txn:canvas(root, { draw = draw, width = 220, height = 220 }, {
		-- The widget interface: what the generic widget_* calls do on the
		-- dial, inside the caller's transaction.
		widget = {
			set_value = function(t, _, v)
				value = math.max(0, math.min(1, v))
				apply(t)
			end,
			get_value = function()
				return value
			end,
			set_label = function(t, _, text)
				label = text
				apply(t)
			end,
			set_disabled = function(t, _, yes)
				disabled = yes
				dragging = false
				apply(t)
			end,
		},
	})
	-- Behavior goes in the default slots, so the application's handlers
	-- (txn:on) can override it.
	-- The angle of the pointer around the center sets the value.
	txn:on_default(canvas, "pointer", function(node, e)
		if e.phase == "down" and not disabled then
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
		user_set(a / sweep)
		return true
	end)
	txn:on_default(canvas, "key", function(_, e)
		if not e.flags.pressed then
			return false
		end
		if e.keysym == "left" then
			user_set(value - 0.05)
		elseif e.keysym == "right" then
			user_set(value + 0.05)
		else
			return false
		end
		return true
	end)
	-- Assistive technology sets the value through AT-SPI's Value interface.
	txn:on_default(canvas, "set_value", function(_, e)
		user_set(e.value)
		return true
	end)
	apply(txn)

	-- From here on it is driven like any stock widget.
	txn:widget_set_label(canvas, "Volume")
	txn:widget_set_value(canvas, 0.4)
	txn:on(canvas, "change", function(_, e)
		win:set_title(("Gauge: %d%%"):format(math.floor(e.value * 100 + 0.5)))
		return true
	end)
end)
canvas:focus()

app:run()
