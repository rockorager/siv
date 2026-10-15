//! The document part of the API schema (D32): a node showing an HTML,
//! Markdown, or plain text document, the application's resource loader,
//! and the document's events. api.zig appends these declarations and
//! functions to its own; the conventions are schema.zig's. Implemented in
//! document.zig. Built out with -Ddocument=false, where every function
//! returns SIV_ERROR_UNSUPPORTED (siv_docview returns 0 and fails its
//! transaction with it).

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

fn callback(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Decl {
    return .{ .callback = .{ .name = name, .doc = doc, .since = v0_1, .params = params } };
}

fn call(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc ++ unsupported, .since = v0_1, .params = &([_]Param{node_param} ++ params[0..params.len].*), .ret = ref("siv_result") };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

fn f(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) schema.Field {
    return .{ .name = name, .type = t, .doc = doc };
}

const node_param = p("node", ref("siv_node"), "A document node (siv_docview); SIV_ERROR_INVALID_ARGUMENT for another node.");
const unsupported = " SIV_ERROR_UNSUPPORTED when siv was built without documents (-Ddocument=false).";
const busy = " SIV_ERROR_BUSY while the document is being parsed, styled, or laid out on the worker pool; the load event tells when it is ready.";

fn handle(comptime name: []const u8, comptime doc: []const u8) Decl {
    return .{ .handle = .{ .name = name, .doc = doc, .since = v0_1 } };
}

pub const decls = [_]Decl{
    handle("siv_epub", "An EPUB 2 or 3 publication (D32): its zip container, package, spine, and table of contents. Valid until siv_epub_destroy; document nodes showing it keep it open."),
    enumeration("siv_epub_field", "Metadata of a publication.", &.{
        .{ .name = "title", .value = 0, .doc = "dc:title." },
        .{ .name = "author", .value = 1, .doc = "The first dc:creator." },
        .{ .name = "language", .value = 2, .doc = "dc:language." },
        .{ .name = "identifier", .value = 3, .doc = "dc:identifier." },
    }),
    enumeration("siv_docview_kind", "What a document's bytes are.", &.{
        .{ .name = "html", .value = 0, .doc = "HTML, parsed as browsers parse it (WHATWG), with its style sheets. The charset comes from a byte order mark or <meta charset>, else UTF-8 (windows-1252 where UTF-8 is invalid)." },
        .{ .name = "markdown", .value = 1, .doc = "CommonMark with GitHub's tables, task lists, strikethrough, and autolinks; raw HTML in it is HTML." },
        .{ .name = "text", .value = 2, .doc = "Plain text, shown preformatted." },
    }),
    enumeration("siv_docview_color_scheme", "The colors a document takes where it sets none, and what prefers-color-scheme says.", &.{
        .{ .name = "theme", .value = 0, .doc = "The window's theme (D29): its background and text colors, and its light or dark scheme, following changes." },
        .{ .name = "light", .value = 1, .doc = "Black on white, as browsers show documents." },
        .{ .name = "dark", .value = 2, .doc = "Light text on a dark background, and prefers-color-scheme: dark." },
    }),
    flags("siv_docview_flags", "Document options.", &.{
        .{ .name = "remote_images", .bit = 0, .doc = "Ask the loader for remote (http, https) images, style sheets, and fonts. Without it they are blocked, a blocked_images event counts them, and siv_docview_load_images asks for them later: the policy for email." },
        .{ .name = "no_author_styles", .bit = 1, .doc = "Ignore the document's own style sheets and style attributes." },
        .{ .name = "untrusted", .bit = 2, .doc = "The HTML comes from a stranger (email): scripts, embedded frames and objects, links with schemes other than http, https, mailto, tel, cid, mid, news, and ftp, <base>, and <meta http-equiv> are dropped, and nothing is positioned over the page." },
        .{ .name = "paged", .bit = 4, .doc = "Pages instead of scrolling: the node fills the space its parent gives it and shows one page, turned with siv_docview_set_page; breaks fall between blocks, rows, and lines, keeping widows and orphans and honoring break-before and break-after." },
        .{ .name = "spread", .bit = 5, .doc = "Paged: two pages side by side when the node is wider than tall." },
        .{ .name = "reading", .bit = 6, .doc = "A book's reading defaults: page margins, a measure of about 66 characters, and a serif face, 1.45 leading, justified text broken with Knuth and Plass, and hyphenation, which the publisher's CSS overrides where it sets them (user style sheet origin)." },
        .{ .name = "collapse_quotes", .bit = 3, .doc = "Collapse quoted replies (blockquote type=cite, Gmail's, Yahoo's, Proton's, and Outlook's quote markers) behind a toggle that shows and hides them." },
    }),
    enumeration("siv_resource_kind", "What a document asks its loader for.", &.{
        .{ .name = "stylesheet", .value = 0, .doc = "A style sheet (<link rel=stylesheet>, @import)." },
        .{ .name = "image", .value = 1, .doc = "An image (<img>, background-image): any format siv decodes (D19), SVG too." },
        .{ .name = "font", .value = 2, .doc = "A font file for @font-face (TrueType or OpenType; WOFF2 sources are skipped)." },
    }),
    callback("siv_docview_load_fn", "Asks the application for a resource of a document: it decides what may be fetched (files of an e-book, an email's cid: parts, remote images under its policy) and answers with siv_docview_supply (empty data fails the request), now or later. siv never fetches anything itself.", &.{
        p("node", ref("siv_node"), "The document."),
        p("request", .u32, "Identifies the request in siv_docview_supply."),
        p("url", .string, "The resource's URL, resolved against the document's base URL. Valid during the call."),
        p("kind", ref("siv_resource_kind"), "What it is for."),
    }),
    enumeration("siv_docview_event_type", "What a siv_docview_event reports.", &.{
        .{ .name = "link", .value = 0, .doc = "A link was clicked: url holds its resolved URL. Links to fragments of the document itself scroll there instead." },
        .{ .name = "loaded", .value = 1, .doc = "The document is laid out to its end: its height is exact. Again after it changes (a style sheet or image arrived, the width changed)." },
        .{ .name = "size", .value = 2, .doc = "The document's height changed: height holds it." },
        .{ .name = "find", .value = 3, .doc = "siv_docview_find found count matches (at most 10000); current is the 1-based index of the current one, 0 when there is none." },
        .{ .name = "selection", .value = 4, .doc = "The selection changed (siv_docview_get_selection reads it)." },
        .{ .name = "blocked_images", .value = 5, .doc = "count remote images were blocked by the policy (siv_docview_flags.remote_images)." },
        .{ .name = "page", .value = 6, .doc = "Paged: current is the page shown (0-based) and count how many there are." },
    }),
    descriptor("siv_docview_event", "An event of a document. Filled by siv; strings are valid during the call.", &.{
        f("url", .string, "Link: the URL."),
        f("rel", .string, "Link: its role, the anchor's epub:type or rel (\"noteref\" for a footnote reference, whose target siv_docview_get_element_html gives for a popup)."),
        f("type", ref("siv_docview_event_type"), "What happened."),
        f("height", .f32, "Size: the height in logical pixels."),
        f("count", .u32, "Find: matches; blocked_images: images."),
        f("current", .u32, "Find: the current match, 1-based."),
    }),
    callback("siv_docview_event_fn", "Receives a document's events at safe points on the application's thread.", &.{
        p("node", ref("siv_node"), "The document."),
        p("event", .{ .desc = "siv_docview_event" }, "The event, valid during the call."),
    }),
    descriptor("siv_docview_desc", "What a document node shows, and its callbacks.", &.{
        f("source", schema.array(.u8), "The document's bytes (copied)."),
        f("base_url", .string, "Where relative URLs resolve from (an e-book chapter's path in its container, say); <base href> overrides it."),
        f("user_css", .string, "A style sheet of the application's, after the user agent's and before the document's."),
        f("epub", ref("siv_epub"), "A publication to show a chapter of: without a source the chapter comes from epub_path (with one, source is a fragment of that chapter, such as a footnote's siv_docview_get_element_html), and the chapter's style sheets, fonts, and images come from the publication without the loader. The node keeps the publication open."),
        f("epub_path", .string, "The chapter's path in the publication (siv_epub_get_spine_path)."),
        f("user_data", .user_data, "Passed to load, on_event, and destroy."),
        f("load", ref("siv_docview_load_fn"), "Loads resources; NULL loads none."),
        f("on_event", ref("siv_docview_event_fn"), "Receives events; may be NULL."),
        f("destroy", ref("siv_destroy_fn"), "Releases user_data when the node is destroyed."),
        f("kind", ref("siv_docview_kind"), "What source holds."),
        f("color_scheme", ref("siv_docview_color_scheme"), "Default theme."),
        f("flags", ref("siv_docview_flags"), "Options."),
        f("font_size", .f32, "The size of CSS medium, in logical pixels; 0 follows the window's text size."),
    }),
};

fn epubCall(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc ++ unsupported, .since = v0_1, .params = &([_]Param{p("epub", ref("siv_epub"), "The publication.")} ++ params[0..params.len].*), .ret = ref("siv_result") };
}

pub const functions = [_]Function{
    .{ .name = "siv_epub_open", .doc = "Opens a publication from its bytes (copied): the zip container, META-INF/container.xml, the OPF package, and the table of contents (the EPUB 3 navigation document, else the NCX). SIV_ERROR_INVALID_ARGUMENT for something that is not an EPUB." ++ unsupported, .since = v0_1, .params = &.{
        p("app", ref("siv_app"), "The application."),
        p("data", schema.array(.u8), "The .epub file's bytes."),
        p("epub", out(ref("siv_epub")), "The publication."),
    }, .ret = ref("siv_result") },
    .{ .name = "siv_epub_destroy", .doc = "Closes a publication; document nodes showing a chapter keep it until they go. A stale handle does nothing.", .since = v0_1, .params = &.{p("epub", ref("siv_epub"), "The publication.")} },
    epubCall("siv_epub_get_counts", "How many chapters the spine has and how many entries the table of contents.", &.{
        p("spine", out(.u32), "Spine items, in reading order."),
        p("toc", out(.u32), "Table of contents entries, in order."),
    }),
    epubCall("siv_epub_get_metadata", "A piece of the publication's metadata; empty when it has none.", &.{
        p("field", ref("siv_epub_field"), "Which."),
        p("text", schema.text_buffer, "Receives at most text_cap bytes; may be NULL with text_cap 0."),
        p("len", out(.usize), "The full length."),
    }),
    epubCall("siv_epub_get_spine_path", "The path of a spine item in the container, for siv_docview_desc.epub_path.", &.{
        p("index", .u32, "The spine index; SIV_ERROR_INVALID_ARGUMENT past the end."),
        p("path", schema.text_buffer, "Receives at most path_cap bytes; may be NULL with path_cap 0."),
        p("len", out(.usize), "The full length."),
    }),
    epubCall("siv_epub_get_toc_label", "A table of contents entry's label and depth.", &.{
        p("index", .u32, "The entry; SIV_ERROR_INVALID_ARGUMENT past the end."),
        p("label", schema.text_buffer, "Receives at most label_cap bytes; may be NULL with label_cap 0."),
        p("len", out(.usize), "The label's full length."),
        p("depth", out(.u32), "1 for the top level, 2 for entries under it, and so on."),
    }),
    epubCall("siv_epub_get_toc_target", "Where a table of contents entry points: a spine index and a fragment for siv_docview_go_to (\"#id\", or empty for the chapter's start).", &.{
        p("index", .u32, "The entry; SIV_ERROR_INVALID_ARGUMENT past the end."),
        p("fragment", schema.text_buffer, "Receives at most fragment_cap bytes; may be NULL with fragment_cap 0."),
        p("len", out(.usize), "The fragment's full length."),
        p("spine", out(.u32), "The chapter's spine index, or UINT32_MAX when it is not in the spine."),
    }),
    .{
        .name = "siv_docview",
        .doc = "Creates a document node: an HTML, Markdown, or plain text document laid out at the node's width, as tall as its content, so put it in a vertical scroll node (siv_scroll). Parsing, styling, and layout run on the worker pool (D32): the first screen shows before the rest of a long document is laid out, and only what is near the viewport is drawn. Clicks follow links, drags select text, and assistive technology sees its headings, links, lists, tables, and images. No JavaScript, no networking: resources come from desc.load. Appended as the parent's last child. Returns the node, or 0 if the transaction has failed (see siv_txn_commit); the transaction fails with SIV_ERROR_UNSUPPORTED when siv was built without documents (-Ddocument=false).",
        .since = v0_1,
        .params = &.{
            p("txn", ref("siv_txn"), "An open transaction."),
            p("parent", ref("siv_node"), "A container node of the transaction's window."),
            p("desc", .{ .desc = "siv_docview_desc" }, "The document and its callbacks."),
        },
        .ret = ref("siv_node"),
    },
    call("siv_docview_supply", "Answers a load request with the resource's bytes (copied), or with none when data is empty, which fails it. A request answered twice, or of a document since replaced, is ignored.", &.{
        p("request", .u32, "From siv_docview_load_fn."),
        p("data", schema.array(.u8), "The bytes; empty fails the request."),
    }),
    call("siv_docview_load_images", "Asks the loader for the remote images the policy blocked (siv_docview_flags.remote_images): after the user chose to load them.", &.{}),
    call("siv_docview_find", "Finds text, ignoring ASCII case, and highlights every match: a new text makes the first match at or below the top of what shows current, the same text again the next (or previous) one; the current match scrolls into view, and a find event reports the count. An empty text clears." ++ busy, &.{
        p("text", .string, "What to find."),
        p("backwards", .bool, "Move to the previous match instead of the next."),
    }),
    call("siv_docview_get_selection", "The selected text, with a line break between blocks." ++ busy, &.{
        p("text", schema.text_buffer, "Receives at most text_cap bytes; may be NULL with text_cap 0."),
        p("len", out(.usize), "The text's full length."),
    }),
    call("siv_docview_select_all", "Selects the whole document." ++ busy, &.{}),
    call("siv_docview_scroll_to", "Scrolls the element with an id (or <a name>) to the top of the nearest scroll node. SIV_ERROR_INVALID_ARGUMENT when there is none." ++ busy, &.{
        p("fragment", .string, "The id, without '#'."),
    }),
    call("siv_docview_get_locator", "A reading position that stays put across widths, fonts, and themes: the path of element indices from <body> to the innermost element at document y, such as \"/3/0/2\"." ++ busy, &.{
        p("y", .f32, "A document y in logical pixels (the scroll offset)."),
        p("locator", schema.text_buffer, "Receives at most locator_cap bytes; may be NULL with locator_cap 0."),
        p("len", out(.usize), "The locator's full length."),
    }),
    call("siv_docview_get_locator_y", "Where a locator (siv_docview_get_locator) is now, as a document y to scroll to. SIV_ERROR_INVALID_ARGUMENT when nothing of it is laid out." ++ busy, &.{
        p("locator", .string, "The locator."),
        p("y", out(.f32), "The document y."),
    }),
    call("siv_docview_set_page", "Paged: shows a page (the left one of a spread), clamped to the last; a page event reports it." ++ busy, &.{
        p("index", .u32, "The page, 0-based."),
    }),
    call("siv_docview_get_page", "Paged: the page shown and how many there are (1 and 0 before the first layout)." ++ busy, &.{
        p("index", out(.u32), "The page shown, 0-based."),
        p("count", out(.u32), "Pages."),
    }),
    call("siv_docview_go_to", "Goes to a fragment (\"#id\", a table of contents target) or a locator (siv_docview_get_position): the page holding it, or scrolled to the top. SIV_ERROR_INVALID_ARGUMENT when there is no such place." ++ busy, &.{
        p("target", .string, "The fragment or locator."),
    }),
    call("siv_docview_get_position", "The reading position: a locator of what shows at the top (the page's top, or the scroll position), to keep and give siv_docview_go_to later; it survives other widths, fonts, and themes." ++ busy, &.{
        p("locator", schema.text_buffer, "Receives at most locator_cap bytes; may be NULL with locator_cap 0."),
        p("len", out(.usize), "The full length."),
    }),
    call("siv_docview_set_user_css", "Replaces the application's style sheet (siv_docview_desc.user_css), as when the user picks another face, size, leading, or justification; the document is styled and laid out again at the same reading position. The reading defaults stay before it.", &.{
        p("css", .string, "The style sheet."),
    }),
    call("siv_docview_get_element_html", "The markup of the element with an id, such as a footnote a noteref link points to, to show in a popup. SIV_ERROR_INVALID_ARGUMENT when there is none." ++ busy, &.{
        p("id", .string, "The id, without '#'."),
        p("html", schema.text_buffer, "Receives at most html_cap bytes; may be NULL with html_cap 0."),
        p("len", out(.usize), "The full length."),
    }),
    call("siv_docview_get_title", "The document's <title>, empty without one." ++ busy, &.{
        p("title", schema.text_buffer, "Receives at most title_cap bytes; may be NULL with title_cap 0."),
        p("len", out(.usize), "The title's full length."),
    }),
};
