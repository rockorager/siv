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

pub const decls = [_]Decl{
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
    }),
    descriptor("siv_docview_event", "An event of a document. Filled by siv; strings are valid during the call.", &.{
        f("url", .string, "Link: the URL."),
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

pub const functions = [_]Function{
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
    call("siv_docview_get_title", "The document's <title>, empty without one." ++ busy, &.{
        p("title", schema.text_buffer, "Receives at most title_cap bytes; may be NULL with title_cap 0."),
        p("len", out(.usize), "The title's full length."),
    }),
};
