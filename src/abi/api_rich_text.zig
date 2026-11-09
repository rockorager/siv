//! The rich text editor's part of the API schema (D22): a stock widget
//! that edits a Portable Text document (portabletext.org) WYSIWYG, with
//! the usual keys and the mouse or with Vim's keys. api.zig appends these
//! declarations and functions to its own; the conventions are
//! schema.zig's. Implemented in src/widgets/rich_text.zig.

const schema = @import("schema.zig");
const ref = schema.ref;
const out = schema.out;
const Decl = schema.Decl;
const Param = schema.Param;
const Function = schema.Function;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

fn enumeration(comptime name: []const u8, comptime doc: []const u8, comptime values: []const schema.EnumValue) Decl {
    return .{ .@"enum" = .{ .name = name, .doc = doc, .since = v0_1, .values = values } };
}

fn flags(comptime name: []const u8, comptime doc: []const u8, comptime bits: []const schema.Flag) Decl {
    return .{ .flags = .{ .name = name, .doc = doc, .since = v0_1, .bits = bits } };
}

fn descriptor(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .descriptor, .fields = fields } };
}

fn value(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .value, .fields = fields } };
}

fn f(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) schema.Field {
    return .{ .name = name, .type = t, .doc = doc };
}

fn reserved(comptime name: []const u8) schema.Field {
    return .{ .name = name, .type = .u32, .doc = "Reserved; must be zero (SIV_ERROR_UNSUPPORTED otherwise).", .reserved = true };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

fn call(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = ref("siv_result") };
}

fn txnOp(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc ++ " A failure is the transaction's (see siv_txn_commit).", .since = v0_1, .params = params };
}

const txn_param = p("txn", ref("siv_txn"), "An open transaction.");
const node_param = p("node", ref("siv_node"), "A rich text editor (siv_rich_text).");
const offsets_doc = "Byte offsets count in the editor's text: the blocks' text joined by \"\\n\", a line break inside a block as U+2028, and a block the editor does not edit as one U+00A0.";
const buffer_out = [_]Param{
    p("buffer", schema.text_buffer, "Receives at most buffer_cap bytes; may be NULL with buffer_cap 0."),
    p("len", out(.usize), "The full length in bytes."),
};

pub const decls = [_]Decl{
    flags("siv_rich_text_flags", "Rich text editor options.", &.{
        .{ .name = "vim", .bit = 0, .doc = "Vim's keys (D22): normal, insert, visual, and visual line modes, counts, operators with motions and text objects, registers that keep marks and block styles, undo by command, dot repeat, search, and a command line. Without it, the usual keys and the mouse edit as in a word processor." },
    }),
    enumeration("siv_rich_text_schema", "What a rich text editor's documents may contain.", &.{
        .{ .name = "emdash", .value = 0, .doc = "EmDash's Portable Text (emdashcms.com): every style, mark, list, and code block below; other block types (image, table, htmlBlock) are kept as they are and shown as a placeholder." },
        .{ .name = "custom", .value = 1, .doc = "The styles, marks, and blocks siv_rich_text_desc names: on import other styles show as normal, other marks and block types are dropped, and code blocks show as text, with a message in siv_rich_text_get_status; commands and keys for them do nothing." },
    }),
    flags("siv_rich_text_styles", "Block styles a rich text document may use besides normal.", &.{
        .{ .name = "h1", .bit = 0, .doc = "Heading 1." },
        .{ .name = "h2", .bit = 1, .doc = "Heading 2." },
        .{ .name = "h3", .bit = 2, .doc = "Heading 3." },
        .{ .name = "h4", .bit = 3, .doc = "Heading 4." },
        .{ .name = "h5", .bit = 4, .doc = "Heading 5." },
        .{ .name = "h6", .bit = 5, .doc = "Heading 6." },
        .{ .name = "blockquote", .bit = 6, .doc = "A quotation." },
    }),
    flags("siv_rich_text_marks", "Marks on a rich text document's text: Portable Text's decorators, and links (an annotation).", &.{
        .{ .name = "strong", .bit = 0, .doc = "Bold (strong)." },
        .{ .name = "em", .bit = 1, .doc = "Italic (em)." },
        .{ .name = "underline", .bit = 2, .doc = "Underlined (underline)." },
        .{ .name = "strike_through", .bit = 3, .doc = "Struck through (strike-through)." },
        .{ .name = "code", .bit = 4, .doc = "Inline code (code), in the monospace family." },
        .{ .name = "link", .bit = 5, .doc = "Annotations such as links (markDefs), shown in a link color and kept whole." },
        .{ .name = "superscript", .bit = 6, .doc = "Superscript (superscript), smaller and raised (SIV_TEXT_BASELINE_SUPERSCRIPT)." },
        .{ .name = "subscript", .bit = 7, .doc = "Subscript (subscript), smaller and lowered; one replaces the other." },
    }),
    flags("siv_rich_text_blocks", "Lists and block types a rich text document may use besides text blocks.", &.{
        .{ .name = "bullet_list", .bit = 0, .doc = "Bulleted list items (listItem bullet), nested up to 8 levels." },
        .{ .name = "number_list", .bit = 1, .doc = "Numbered list items (listItem number)." },
        .{ .name = "code", .bit = 2, .doc = "Code blocks ({ _type: \"code\", code, language }), edited as lines of monospace text on a tinted ground." },
    }),
    descriptor("siv_rich_text_desc", "A rich text editor (siv_rich_text).", &.{
        f("flags", ref("siv_rich_text_flags"), "Options."),
        f("schema", ref("siv_rich_text_schema"), "What documents may contain."),
        f("styles", ref("siv_rich_text_styles"), "With SIV_RICH_TEXT_SCHEMA_CUSTOM, the block styles allowed; must be 0 otherwise."),
        f("marks", ref("siv_rich_text_marks"), "With SIV_RICH_TEXT_SCHEMA_CUSTOM, the marks allowed; must be 0 otherwise."),
        f("blocks", ref("siv_rich_text_blocks"), "With SIV_RICH_TEXT_SCHEMA_CUSTOM, the lists and block types allowed; must be 0 otherwise."),
        f("font_size", .f32, "The size of normal text in logical pixels, which headings scale; 0 is 16."),
        f("label", .string, "The accessible name, copied; empty is \"Document\"."),
        f("placeholder", .string, "Shown while the document is empty, copied; empty for none."),
        f("document", .string, "The Portable Text document it starts with, as JSON (an array of blocks), copied; empty starts empty. Invalid JSON fails the transaction (SIV_ERROR_INVALID_ARGUMENT)."),
        reserved("reserved0"),
        reserved("reserved1"),
    }),
    enumeration("siv_rich_text_command", "A formatting or editing command of a rich text editor (siv_rich_text_run), as its toolbar and menus give it.", &.{
        .{ .name = "strong", .value = 0, .doc = "Toggles bold over the selection, or for what is typed next." },
        .{ .name = "em", .value = 1, .doc = "Toggles italic." },
        .{ .name = "underline", .value = 2, .doc = "Toggles underline." },
        .{ .name = "strike_through", .value = 3, .doc = "Toggles strike-through." },
        .{ .name = "code", .value = 4, .doc = "Toggles inline code." },
        .{ .name = "normal", .value = 5, .doc = "Makes the selected blocks normal text: no heading, quote, list, or code block." },
        .{ .name = "h1", .value = 6, .doc = "Makes the selected blocks headings 1." },
        .{ .name = "h2", .value = 7, .doc = "Headings 2." },
        .{ .name = "h3", .value = 8, .doc = "Headings 3." },
        .{ .name = "h4", .value = 9, .doc = "Headings 4." },
        .{ .name = "h5", .value = 10, .doc = "Headings 5." },
        .{ .name = "h6", .value = 11, .doc = "Headings 6." },
        .{ .name = "blockquote", .value = 12, .doc = "Toggles the selected blocks between quotes and normal text." },
        .{ .name = "bullet_list", .value = 13, .doc = "Toggles the selected blocks between bulleted list items and normal text." },
        .{ .name = "number_list", .value = 14, .doc = "Toggles the selected blocks between numbered list items and normal text." },
        .{ .name = "code_block", .value = 15, .doc = "Toggles the selected blocks between one code block and normal text." },
        .{ .name = "indent", .value = 16, .doc = "Nests the selected list items one level deeper." },
        .{ .name = "outdent", .value = 17, .doc = "Moves the selected list items one level out." },
        .{ .name = "undo", .value = 18, .doc = "Undoes the last edit." },
        .{ .name = "redo", .value = 19, .doc = "Redoes the last edit undone." },
        .{ .name = "superscript", .value = 20, .doc = "Toggles superscript, which replaces subscript." },
        .{ .name = "subscript", .value = 21, .doc = "Toggles subscript, which replaces superscript." },
        .{ .name = "link", .value = 22, .doc = "Opens the link editor at the selection, as Ctrl+K does (siv_rich_text). Run it while handling a press or key, such as a toolbar button's activation, since its popover takes the keyboard." },
    }),
    enumeration("siv_rich_text_mode", "What a rich text editor's keys do now.", &.{
        .{ .name = "edit", .value = 0, .doc = "The usual keys: no Vim (SIV_RICH_TEXT_FLAGS_VIM off)." },
        .{ .name = "normal", .value = 1, .doc = "Vim's normal mode: keys are commands." },
        .{ .name = "insert", .value = 2, .doc = "Vim's insert mode: keys type." },
        .{ .name = "visual", .value = 3, .doc = "Vim's visual mode: motions extend a selection of characters." },
        .{ .name = "visual_line", .value = 4, .doc = "Vim's visual line mode: motions extend a selection of whole blocks." },
        .{ .name = "command", .value = 5, .doc = "Vim's command line (:) or search (/, ?): keys type into it (siv_rich_text_get_status)." },
    }),
    enumeration("siv_rich_text_style", "The kind of a rich text block.", &.{
        .{ .name = "normal", .value = 0, .doc = "Normal text." },
        .{ .name = "h1", .value = 1, .doc = "Heading 1." },
        .{ .name = "h2", .value = 2, .doc = "Heading 2." },
        .{ .name = "h3", .value = 3, .doc = "Heading 3." },
        .{ .name = "h4", .value = 4, .doc = "Heading 4." },
        .{ .name = "h5", .value = 5, .doc = "Heading 5." },
        .{ .name = "h6", .value = 6, .doc = "Heading 6." },
        .{ .name = "blockquote", .value = 7, .doc = "A quotation." },
        .{ .name = "code", .value = 8, .doc = "A line of a code block." },
        .{ .name = "object", .value = 9, .doc = "A block the editor keeps but does not edit (an image, a table)." },
    }),
    enumeration("siv_rich_text_list", "A rich text block's list.", &.{
        .{ .name = "none", .value = 0, .doc = "Not a list item." },
        .{ .name = "bullet", .value = 1, .doc = "A bulleted list item." },
        .{ .name = "number", .value = 2, .doc = "A numbered list item." },
    }),
    value("siv_rich_text_state", "What a rich text editor shows at its caret, for a toolbar and a status line (siv_rich_text_get_state).", &.{
        f("style", ref("siv_rich_text_style"), "The caret's block."),
        f("list", ref("siv_rich_text_list"), "The caret's block's list."),
        f("level", .u32, "The list item's nesting level, from 1; 0 outside lists."),
        f("marks", ref("siv_rich_text_marks"), "The marks typing would give, as siv_node_get_typing_style tells: the typing style, else that of the first selected character, else that of the character before the caret."),
        f("mode", ref("siv_rich_text_mode"), "What the keys do."),
        f("modified", .bool, "Whether the document changed since it was set or siv_rich_text_mark_saved."),
        f("can_undo", .bool, "Whether SIV_RICH_TEXT_COMMAND_UNDO would undo something."),
        f("can_redo", .bool, "Whether SIV_RICH_TEXT_COMMAND_REDO would redo something."),
        reserved("reserved0"),
        reserved("reserved1"),
    }),
};

pub const functions = [_]Function{
    .{
        .name = "siv_rich_text",
        .doc = "Creates a rich text editor (D22): an editor showing a Portable Text document as it reads, headings, quotes, lists with their markers, code blocks, and marks, edited with the usual keys and the mouse or, with SIV_RICH_TEXT_FLAGS_VIM, with Vim's keys. Ctrl+B, Ctrl+I, Ctrl+U, Ctrl+E, Ctrl+Shift+X, Ctrl+., and Ctrl+, toggle bold, italic, underline, code, strike-through, superscript, and subscript; Ctrl+Alt+0 to 6 set normal text and headings; Ctrl+Shift+7, 8, and 9 numbered and bulleted lists and quotes, Ctrl+Alt+C a code block; Tab and Shift+Tab nest list items; Shift+Enter breaks a line inside a block; Markdown at the start of a paragraph (\"# \" to \"###### \", \"- \", \"1. \", \"> \", \"``` \") formats it; Ctrl+Z and Ctrl+Shift+Z undo and redo. Ctrl+K edits links in a popover at the selection, Enter applying (with the caret left at the end of the linked text) and Escape cancelling: with text selected it asks for a URL to link it to, on a link it shows the link's URL to change (or clear, or Remove, to unlink it), and at a caret elsewhere it asks for a URL and the text to show (the URL itself when empty); a URL typed without a scheme gets https:// (mailto: for an address). Typing a URL (http://, https://, mailto:, or www.) and then a space or Enter links it, an undo step of its own, and pasting a URL over selected text links that text instead of replacing it. Text typed at a link's end is not part of the link. Clicking a link places the caret; it never opens. With Vim's keys, Ctrl+K works in every mode, :link URL links the visual selection (:'<,'>link), else changes the link or links the word under the cursor, :link alone opens the popover, and :unlink removes the link under the cursor or the links in the visual selection. The user's edits report SIV_EVENT_CHANGE on it, changes of what siv_rich_text_get_state and siv_rich_text_get_status tell SIV_EVENT_SELECT, and a Vim command line (:w) SIV_EVENT_ACTIVATE with the command in text. The root is a stack the application lays out, as tall as its document (put it in a scroll); siv_node_focus on it gives its text the focus, and siv_widget_set_label and siv_widget_set_disabled apply. Appended as the parent's last child. Returns the node, or 0 if the transaction has failed (see siv_txn_commit).",
        .since = v0_1,
        .params = &.{
            txn_param,
            p("parent", ref("siv_node"), "A container node of the transaction's window."),
            p("desc", .{ .desc = "siv_rich_text_desc" }, "Options and the document; NULL for an empty EmDash document."),
        },
        .ret = ref("siv_node"),
    },
    txnOp("siv_rich_text_set_document", "Replaces a rich text editor's document with Portable Text JSON: an array of blocks. It drops the undo history, is not modified afterward, and reports no change. Invalid JSON, or JSON that is not an array, is SIV_ERROR_INVALID_ARGUMENT.", &.{
        txn_param,
        node_param,
        p("document", .string, "The document, copied; empty for an empty one."),
    }),
    txnOp("siv_rich_text_set_flags", "Sets a rich text editor's options: turning Vim's keys on starts in normal mode, and off returns to the usual keys.", &.{
        txn_param,
        node_param,
        p("flags", ref("siv_rich_text_flags"), "Options."),
    }),
    call("siv_rich_text_get_document", "Copies a rich text editor's document as Portable Text JSON, indented with two spaces. Blocks and mark definitions keep the _key they were read with, spans theirs while their text is the same, and new or duplicated ones get new keys; fields the editor does not edit (textAlign) are kept, and blocks of types it does not edit come back as they were read.", &([_]Param{node_param} ++ buffer_out)),
    call("siv_rich_text_run", "Runs a formatting or editing command on a rich text editor, as its keys do, as one undo step, followed by SIV_EVENT_CHANGE when the document changed. SIV_ERROR_UNSUPPORTED for what the editor's schema does not allow; not inside an open transaction of the window (SIV_ERROR_BUSY).", &.{
        node_param,
        p("command", ref("siv_rich_text_command"), "The command."),
    }),
    call("siv_rich_text_get_state", "What a rich text editor shows at its caret, and its mode.", &.{
        node_param,
        p("state", out(ref("siv_rich_text_state")), "The state."),
    }),
    call("siv_rich_text_get_status", "A rich text editor's status line: in Vim, the keys of a command typed so far (\"2d\"), the command line or search being typed (\":w\"), or its last message (\"Pattern not found\"); empty when there is none.", &([_]Param{node_param} ++ buffer_out)),
    call("siv_rich_text_get_selection", "A rich text editor's selection. " ++ offsets_doc, &.{
        node_param,
        p("caret", out(.u32), "Where the caret is, the end the user moves."),
        p("anchor", out(.u32), "The other end; the caret when nothing is selected."),
    }),
    call("siv_rich_text_get_link", "The link at a rich text editor's caret, for an application's own link UI: the one over the first selected character, else (nothing selected) the one over the character before the caret or, failing that, after it; in Vim's normal mode the one under the cursor. " ++ offsets_doc, &.{
        node_param,
        p("href", schema.text_buffer, "Receives at most href_cap bytes of the link's href; may be NULL with href_cap 0."),
        p("len", out(.usize), "The href's full length; 0 when there is no link there."),
        .{ .name = "start", .type = out(.u32), .doc = "Where the link's text starts; the caret when there is no link.", .optional = true },
        .{ .name = "end", .type = out(.u32), .doc = "Where the link's text ends; the caret when there is no link.", .optional = true },
    }),
    call("siv_rich_text_set_link", "Links a rich text editor's selection, as its link editor does: the selected text to href; with nothing selected, the link at the caret (siv_rich_text_get_link), whole, gets href, keeping its other fields and _key, or, when there is none, href is inserted at the caret as linked text. An empty href removes the links in the selection or the link at the caret. href is kept as given (no scheme is added). One undo step, followed by SIV_EVENT_CHANGE when the document changed. Code blocks and objects are not linked. SIV_ERROR_UNSUPPORTED when the editor's schema has no links (SIV_RICH_TEXT_MARKS_LINK); not inside an open transaction of the window (SIV_ERROR_BUSY).", &.{
        node_param,
        p("href", .string, "The URL, copied; empty to unlink."),
    }),
    call("siv_rich_text_set_link_range", "Links the text of a rich text editor between two offsets to href, as siv_rich_text_set_link does the selection; with start equal to end, the link at that offset (the one over the character before it, else after it) gets href or, with an empty href, is removed, and nothing is inserted. " ++ offsets_doc ++ " SIV_ERROR_INVALID_ARGUMENT for an offset past the text's end; an offset inside a character counts as its start.", &.{
        node_param,
        p("start", .u32, "One end of the text, in either order with end."),
        p("end", .u32, "The other end."),
        p("href", .string, "The URL, copied; empty to unlink."),
    }),
    call("siv_rich_text_mark_saved", "Marks a rich text editor's document as saved: siv_rich_text_state.modified is false until the user changes it again.", &.{node_param}),
};
