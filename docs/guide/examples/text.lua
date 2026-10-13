-- Text: styles, themed sizes, styled ranges (spans), justified and
-- hyphenated paragraphs, truncation, mixed-direction text, and an editor.
--
--     ./zig-out/bin/siv-lua docs/guide/examples/text.lua
local siv = require("siv")

local app = siv.app_create()
local win = app:window_create{ title = "Text", width = 520, height = 500 }

local story = "Typography is the craft of arranging type to make written language "
	.. "legible, readable, and appealing when displayed. siv shapes every paragraph "
	.. "with HarfBuzz, breaks lines by the Unicode rules, and hyphenates words in "
	.. "the text's language."

-- A styled range over the first occurrence of `word` in `text`.
local function span(text, word, style)
	local first, last = text:find(word, 1, true)
	style.start, style["end"] = first - 1, last
	return style
end

win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
	local column = txn:flex(root, { axis = "column", gap = 14 }, {
		layout = { padding = 20, width = { "fraction", 1 } },
	})
	local function text(s, style, props)
		props = props or {}
		style.color_token = style.color_token or "window_fg"
		props.text_style = style
		return txn:text(column, s, props)
	end

	text("Typography", { size_role = "title", weight = "bold" }, { semantics = { role = "heading", level = 1 } })

	-- One paragraph, justified and hyphenated in its language.
	text(story, { language = "en", align = "justify", flags = "hyphenate", line_spacing = 1.2 })

	-- Spans restyle ranges of a text node's text.
	local mixed = "Spans make words bold, italic, colored, or underlined."
	local node = text(mixed, {})
	txn:set_text_spans(node, { spans = {
		span(mixed, "bold", { flags = "weight", weight = "bold" }),
		span(mixed, "italic", { flags = "slant", slant = "italic" }),
		span(mixed, "colored", { flags = "color", color_token = "accent" }),
		span(mixed, "underlined", { flags = "underline" }),
	} })

	-- Truncation: one line cut with an ellipsis, and two lines at most.
	text("quarterly-report-final-version-2-reviewed-by-everyone.pdf",
		{ flags = { "no_wrap", "ellipsize" } }, { layout = { max_width = 300, align_x = "start" } })
	text(story, { max_lines = 2, flags = "ellipsize", color_token = "muted_fg" })

	-- Mixed directions: each paragraph's direction comes from its text.
	text("Hebrew: שלום עולם, and Arabic: مرحبا بالعالم.", {})
	text("שלום עולם — a paragraph that starts in Hebrew runs right to left.", {})

	-- An editor, with a placeholder shown while it is empty.
	txn:editor(column, nil, {
		layout = { padding = { 8, 8, 6, 6 } },
		visual = { background_token = "view_bg", border_token = "border", border_width = 1, radius = 6 },
		semantics = { label = "Comment" },
		placeholder = "Add a comment",
		text_style = { color_token = "view_fg" },
	})
end)

app:run()
