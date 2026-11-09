-- siv's rich text editor (siv_rich_text): a Portable Text document
-- (https://portabletext.org) as EmDash writes it, edited as it reads with
-- the mouse and the usual keys or with Vim's (the switch in the toolbar).
--
--     zig build && ./zig-out/bin/siv-lua examples/rich_text.lua [file.json]
--
-- Without a file it opens examples/rich_text.json (run it from siv's
-- directory), and saves to it. The
-- toolbar runs the editor's commands and follows its state; Ctrl+S and
-- Vim's :w save.
local siv = require("siv")

local path = ... or "examples/rich_text.json"

local app = siv.app_create{ app_id = "dev.siv.examples.rich_text" }
local win = app:window_create{ title = "Rich text", app_id = "dev.siv.examples.rich_text", width = 900, height = 720 }

local STYLES = {
	{ label = "Normal text", style = "normal", command = "normal" },
	{ label = "Heading 1", style = "h1", command = "h1" },
	{ label = "Heading 2", style = "h2", command = "h2" },
	{ label = "Heading 3", style = "h3", command = "h3" },
	{ label = "Quote", style = "blockquote", command = "blockquote" },
	{ label = "Code block", style = "code", command = "code_block" },
}
local MARKS = {
	{ mark = "strong", label = "Bold", icon = "format-text-bold-symbolic", key = "Ctrl+B" },
	{ mark = "em", label = "Italic", icon = "format-text-italic-symbolic", key = "Ctrl+I" },
	{ mark = "underline", label = "Underline", icon = "format-text-underline-symbolic", key = "Ctrl+U" },
	{ mark = "strike_through", label = "Strikethrough", icon = "format-text-strikethrough-symbolic", key = "Ctrl+Shift+X" },
	{ mark = "code", label = "Code", icon = "", key = "Ctrl+E" },
	{ mark = "superscript", label = "x²", icon = "", key = "Ctrl+." },
	{ mark = "subscript", label = "x₂", icon = "", key = "Ctrl+," },
}

local editor, style_combo, vim_switch, mode_text, info_text
local mark_toggles, list_toggles = {}, {}
local message = ""

local function read_file(p)
	local f = io.open(p, "rb")
	if not f then return nil end
	local data = f:read("a")
	f:close()
	return data
end

-- The toolbar and status line follow the editor.
local function refresh()
	local st = editor:rich_text_get_state()
	local status = editor:rich_text_get_status()
	local mode = st.mode == "edit" and "" or st.mode:upper():gsub("_", " ")
	local line = mode
	if status ~= "" then line = line .. (line ~= "" and "  " or "") .. status end
	if message ~= "" then line = line .. (line ~= "" and "  —  " or "") .. message end
	local info = path:match("[^/]*$") .. (st.modified and " (modified)" or "")
	win:update(function(t)
		t:set_text(mode_text, line)
		t:set_text(info_text, info)
		for i, s in ipairs(STYLES) do
			if s.style == st.style then t:widget_set_value(style_combo, i - 1) end
		end
		for i, m in ipairs(MARKS) do
			t:widget_set_value(mark_toggles[i], st.marks[m.mark] and 1 or 0)
		end
		t:widget_set_value(list_toggles.bullet, st.list == "bullet" and 1 or 0)
		t:widget_set_value(list_toggles.number, st.list == "number" and 1 or 0)
	end)
end

local function save()
	local f, err = io.open(path, "wb")
	if not f then
		message = "Cannot save: " .. tostring(err)
	else
		f:write(editor:rich_text_get_document(), "\n")
		f:close()
		editor:rich_text_mark_saved()
		message = "Saved " .. path
	end
	refresh()
end

local function command(cmd)
	if cmd == "w" or cmd == "write" then
		save()
	elseif cmd == "wq" or cmd == "x" then
		save()
		win:destroy()
	elseif cmd == "q" or cmd == "q!" then
		win:destroy()
	else
		message = "Not an editor command: " .. cmd
		refresh()
	end
end

-- Toolbar actions run a command and give the keyboard back to the text.
local function run(cmd)
	return function()
		editor:rich_text_run(cmd)
		editor:focus()
		return true
	end
end

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "view_bg" })
	txn:on(root, "key", function(_, ev)
		if ev.flags.pressed and ev.modifiers.ctrl and ev.shortcut_key == string.byte("s") then
			save()
			return true
		end
		return false
	end)
	local column = txn:flex(root, { axis = "column" }, { layout = { height = { "fraction", 1 } } })

	local bar = txn:flex(column, { gap = 4, align_items = "center" }, {
		layout = { padding = { 10, 10, 6, 6 } },
		visual = { background_token = "window_bg" },
		semantics = { role = "toolbar", label = "Formatting" },
	})
	style_combo = txn:combo_box(bar, { label = "Block style" }, {
		on = { change = function(_, ev) return run(STYLES[ev.index + 1].command)() end },
	})
	for _, s in ipairs(STYLES) do
		txn:combo_box_item(style_combo, { label = s.label })
	end
	txn:box(bar, { layout = { width = 8 } })
	for i, m in ipairs(MARKS) do
		mark_toggles[i] = txn:toggle_button(bar, { label = m.label, icon = m.icon, flags = m.icon ~= "" and "icon_only" or nil }, {
			tooltip = ("%s (%s)"):format(m.label, m.key),
			on = { change = run(m.mark) },
		})
	end
	txn:box(bar, { layout = { width = 8 } })
	list_toggles.bullet = txn:toggle_button(bar, { label = "Bullets", icon = "view-list-bullet-symbolic", flags = "icon_only" }, {
		tooltip = "Bulleted list (Ctrl+Shift+8)",
		on = { change = run("bullet_list") },
	})
	list_toggles.number = txn:toggle_button(bar, { label = "Numbers", icon = "view-list-ordered-symbolic", flags = "icon_only" }, {
		tooltip = "Numbered list (Ctrl+Shift+7)",
		on = { change = run("number_list") },
	})
	txn:box(bar, { layout = { grow = 1 } })
	vim_switch = txn:switch(bar, { label = "Vim keys" }, {
		on = {
			change = function(_, ev)
				win:update(function(t) t:rich_text_set_flags(editor, ev.value ~= 0 and "vim" or {}) end)
				editor:focus()
				return true
			end,
		},
	})
	txn:push_button(bar, { label = "Save" }, { tooltip = "Save as Portable Text (Ctrl+S)", on = { activate = function() save() return true end } })
	txn:box(column, { layout = { height = 1 }, visual = { background_token = "separator" } })

	-- The page: a column of readable width that scrolls.
	local scroll = txn:scroll(column, "vertical", { layout = { grow = 1, basis = 0 } })
	local page = txn:flex(scroll, { axis = "column", align_items = "center" }, { layout = { width = { "fraction", 1 }, padding = { 0, 0, 16, 96 } } })
	local sheet = txn:box(page, { layout = { width = { "fraction", 1 }, max_width = 820 } })
	editor = txn:rich_text(sheet, { document = read_file(path) or "", placeholder = "Write something…", label = "Document" }, {
		on = {
			select = function() refresh() return true end,
			change = function() message = "" return true end,
			activate = function(_, ev) command(ev.text) return true end,
		},
	})

	txn:box(column, { layout = { height = 1 }, visual = { background_token = "separator" } })
	local status = txn:flex(column, { gap = 12, align_items = "center" }, {
		layout = { padding = { 12, 12, 4, 4 } },
		visual = { background_token = "window_bg" },
	})
	mode_text = txn:text(status, "", {
		layout = { grow = 1 },
		text_style = { family = "monospace", font_size = 12, color_token = "window_fg" },
	})
	info_text = txn:text(status, "", { text_style = { font_size = 12, color_token = "muted_fg" } })
end)
editor:focus()
refresh()

app:run()
