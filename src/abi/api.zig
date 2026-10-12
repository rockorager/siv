//! The siv API schema (D3): every type and function of libsiv's C ABI.
//! See schema.zig for the format and conventions. Each function listed here
//! is exported by abi.zig with the signature the schema implies.
//!
//! The application, its loop, and windows are implemented in
//! application.zig; transactions, nodes, and events in tree.zig.

const std = @import("std");
const schema = @import("schema.zig");
const ref = schema.ref;
const out = schema.out;
const array = schema.array;
const Decl = schema.Decl;
const Param = schema.Param;
const Function = schema.Function;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

pub const result: schema.Decl = .{ .@"enum" = .{
    .name = "siv_result",
    .doc = "Result of a fallible call. Every function that can fail returns it; outputs are written only on SIV_OK.",
    .since = v0_1,
    .value_prefix = "SIV_",
    .values = &.{
        .{ .name = "ok", .value = 0, .doc = "Success." },
        .{ .name = "error_out_of_memory", .value = -1, .doc = "An allocation failed. The call had no effect." },
        .{ .name = "error_invalid_handle", .value = -2, .doc = "A handle is null, was destroyed, belongs to a destroyed root, or has the wrong type." },
        .{ .name = "error_invalid_argument", .value = -3, .doc = "An argument breaks the call's contract: a NULL out pointer, a malformed descriptor size, a NULL string with a nonzero length." },
        .{ .name = "error_unsupported", .value = -4, .doc = "The caller asked for something this version of the library does not know: an unknown enum value or flag bit, or nonzero descriptor fields past the end this version knows." },
        .{ .name = "error_limit_exceeded", .value = -5, .doc = "A fixed limit was reached, such as the number of live objects per root or roots per process." },
        .{ .name = "error_busy", .value = -6, .doc = "The object is in a state that does not allow the call: a transaction is already open on the window, the loop is already dispatching, or the call is not allowed from a callback." },
        .{ .name = "error_unavailable", .value = -7, .doc = "The system failed the request: no Wayland display could be reached, it lacks a required protocol, the connection was lost, or a system call failed." },
    },
} };

pub const alloc_fn: schema.Decl = .{ .callback = .{
    .name = "siv_alloc_fn",
    .doc = "Allocates size bytes aligned to alignment (a power of two). Returns NULL on failure.",
    .since = v0_1,
    .params = &.{
        .{ .name = "size", .type = .usize, .doc = "Bytes to allocate; never 0." },
        .{ .name = "alignment", .type = .usize, .doc = "Required alignment in bytes." },
    },
    .ret = .pointer,
} };

pub const free_fn: schema.Decl = .{ .callback = .{
    .name = "siv_free_fn",
    .doc = "Frees memory returned by the matching siv_alloc_fn. size and alignment are the values it was allocated with.",
    .since = v0_1,
    .params = &.{
        .{ .name = "ptr", .type = .pointer, .doc = "Memory to free; never NULL." },
        .{ .name = "size", .type = .usize, .doc = "Size passed to the allocation." },
        .{ .name = "alignment", .type = .usize, .doc = "Alignment passed to the allocation." },
    },
} };

pub const allocator: schema.Decl = .{ .@"struct" = .{
    .name = "siv_allocator",
    .doc = "Allocator hooks for a root object and everything it owns. Set both functions or neither; with neither, siv uses the C library allocator. The struct is copied; user_data must stay valid until the root is destroyed.",
    .since = v0_1,
    .kind = .descriptor,
    .fields = &.{
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to alloc and free." },
        .{ .name = "alloc", .type = ref("siv_alloc_fn"), .doc = "Allocation hook." },
        .{ .name = "free", .type = ref("siv_free_fn"), .doc = "Deallocation hook." },
    },
} };

// Shorthands for the declarations below.

fn handle(comptime name: []const u8, comptime doc: []const u8, comptime root: bool) Decl {
    return .{ .handle = .{ .name = name, .doc = doc, .since = v0_1, .root = root } };
}

fn enumeration(comptime name: []const u8, comptime doc: []const u8, comptime values: []const schema.EnumValue) Decl {
    return .{ .@"enum" = .{ .name = name, .doc = doc, .since = v0_1, .values = values } };
}

fn flags(comptime name: []const u8, comptime doc: []const u8, comptime bits: []const schema.Flag) Decl {
    return .{ .flags = .{ .name = name, .doc = doc, .since = v0_1, .bits = bits } };
}

fn value(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .value, .fields = fields } };
}

fn descriptor(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .descriptor, .fields = fields } };
}

fn callback(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param, comptime ret: schema.Type) Decl {
    return .{ .callback = .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = ret } };
}

fn f32Field(comptime name: []const u8, comptime doc: []const u8) schema.Field {
    return .{ .name = name, .type = .f32, .doc = doc };
}

const result_ref = ref("siv_result");

/// A fallible function.
fn call(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = result_ref };
}

/// A fallible function whose result callers may ignore: teardown, and
/// transaction operations, whose errors commit reports.
fn op(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = result_ref, .must_use = false };
}

/// A transaction operation that creates a node.
fn builder(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{
        .name = name,
        .doc = doc ++ " Appended as the parent's last child. Returns the node, or 0 if the transaction has failed (see siv_txn_commit).",
        .since = v0_1,
        .params = &([_]Param{ txn_param, .{ .name = "parent", .type = ref("siv_node"), .doc = "A container node of the transaction's window." } } ++ params[0..params.len].*),
        .ret = ref("siv_node"),
    };
}

const txn_param: Param = .{ .name = "txn", .type = ref("siv_txn"), .doc = "An open transaction." };
const node_param: Param = .{ .name = "node", .type = ref("siv_node"), .doc = "A node of the transaction's window." };

/// A transaction operation on one node.
fn setter(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return op(name, doc ++ " Returns the transaction's status (see siv_txn_commit).", &([_]Param{ txn_param, node_param } ++ params[0..params.len].*));
}

const app_param: Param = .{ .name = "app", .type = ref("siv_app"), .doc = "The application." };
const window_param: Param = .{ .name = "window", .type = ref("siv_window"), .doc = "The window." };

const align_values: []const schema.EnumValue = &.{
    .{ .name = "auto", .value = 0, .doc = "The container's default." },
    .{ .name = "start", .value = 1, .doc = "The start edge (logical: right in right-to-left layouts) or top." },
    .{ .name = "center", .value = 2, .doc = "Centered." },
    .{ .name = "end", .value = 3, .doc = "The end edge or bottom." },
    .{ .name = "stretch", .value = 4, .doc = "Fill the space on this axis." },
};

const roles = [_][]const u8{
    "none",      "generic",       "window",      "group",      "label",     "paragraph", "heading",     "link",
    "button",    "toggle_button", "checkbox",    "radio",      "switch",    "text_input", "image",      "scroll_area",
    "list",      "list_item",     "tree",        "tree_item",  "table",     "row",       "cell",        "column_header",
    "tab_list",  "tab",           "tab_panel",   "menu",       "menu_bar",  "menu_item", "toolbar",     "dialog",
    "alert",     "status",        "tooltip",     "slider",     "spin_button", "progress_bar", "separator", "combo_box",
    "canvas",    "document",
};

const role_values: [roles.len + 1]schema.EnumValue = blk: {
    var vs: [roles.len + 1]schema.EnumValue = undefined;
    vs[0] = .{ .name = "default", .value = 0, .doc = "The node kind's default: generic for containers, label for text, text_input for editors, scroll_area for scroll nodes." };
    for (roles, 1..) |r, i| vs[i] = .{ .name = r, .value = i, .doc = if (std.mem.eql(u8, r, "none"))
        "Presentational: left out of the semantics tree, with its children promoted."
    else if (std.mem.eql(u8, r, "generic"))
        "A container without meaning of its own; left out of the semantics tree unless focusable or labelled."
    else
        "The " ++ r ++ " role." };
    break :blk vs;
};

const cursor_names = [_][]const u8{
    "default",     "context_menu", "help",        "pointer",     "progress",    "wait",        "cell",        "crosshair",
    "text",        "vertical_text", "alias",      "copy",        "move",        "no_drop",     "not_allowed", "grab",
    "grabbing",    "e_resize",    "n_resize",    "ne_resize",   "nw_resize",   "s_resize",    "se_resize",   "sw_resize",
    "w_resize",    "ew_resize",   "ns_resize",   "nesw_resize", "nwse_resize", "col_resize",  "row_resize",  "all_scroll",
    "zoom_in",     "zoom_out",    "dnd_ask",     "all_resize",
};

const cursor_values: [cursor_names.len + 2]schema.EnumValue = blk: {
    var vs: [cursor_names.len + 2]schema.EnumValue = undefined;
    vs[0] = .{ .name = "auto", .value = 0, .doc = "Nodes: the parent's cursor (editors show text). Windows: no override." };
    for (cursor_names, 1..) |n, i| vs[i] = .{ .name = n, .value = i, .doc = "The CSS " ++ n ++ " cursor." };
    vs[cursor_names.len + 1] = .{ .name = "hidden", .value = cursor_names.len + 1, .doc = "No cursor." };
    break :blk vs;
};

const toggle_values: []const schema.EnumValue = &.{
    .{ .name = "unset", .value = 0, .doc = "The state does not apply." },
    .{ .name = "off", .value = 1, .doc = "Off." },
    .{ .name = "on", .value = 2, .doc = "On." },
    .{ .name = "mixed", .value = 3, .doc = "Partly on." },
};

const color_token_values = [_]schema.EnumValue{
    .{ .name = "none", .value = 0, .doc = "Not themed: the literal color applies." },
    .{ .name = "window_bg", .value = 1, .doc = "Window background." },
    .{ .name = "window_fg", .value = 2, .doc = "Text on the window background." },
    .{ .name = "view_bg", .value = 3, .doc = "Background of content views: text fields, lists." },
    .{ .name = "view_fg", .value = 4, .doc = "Text in views." },
    .{ .name = "card_bg", .value = 5, .doc = "Raised surfaces: menus, popovers, dialogs." },
    .{ .name = "card_fg", .value = 6, .doc = "Text on cards." },
    .{ .name = "muted_fg", .value = 7, .doc = "Secondary text and placeholders." },
    .{ .name = "disabled_fg", .value = 8, .doc = "Text of disabled controls." },
    .{ .name = "border", .value = 9, .doc = "Control outlines." },
    .{ .name = "separator", .value = 10, .doc = "Separators and dividers." },
    .{ .name = "control_bg", .value = 11, .doc = "Buttons and other controls at rest." },
    .{ .name = "control_hover", .value = 12, .doc = "Controls under the pointer." },
    .{ .name = "control_active", .value = 13, .doc = "Pressed controls." },
    .{ .name = "control_fg", .value = 14, .doc = "Text on controls." },
    .{ .name = "accent", .value = 15, .doc = "The accent: default buttons, checked controls, progress. Follows the desktop's accent." },
    .{ .name = "accent_hover", .value = 16, .doc = "The accent under the pointer." },
    .{ .name = "accent_active", .value = 17, .doc = "The accent pressed." },
    .{ .name = "accent_fg", .value = 18, .doc = "Text and marks on the accent." },
    .{ .name = "selection_bg", .value = 19, .doc = "Selected items and text." },
    .{ .name = "selection_fg", .value = 20, .doc = "Text of selected items." },
    .{ .name = "focus_ring", .value = 21, .doc = "Keyboard focus rings." },
    .{ .name = "track", .value = 22, .doc = "Slider, progress, and switch tracks." },
    .{ .name = "knob", .value = 23, .doc = "Slider thumbs and switch knobs." },
    .{ .name = "destructive", .value = 24, .doc = "Destructive actions." },
    .{ .name = "destructive_fg", .value = 25, .doc = "Text on destructive actions." },
    .{ .name = "scrim", .value = 26, .doc = "The translucent cover behind modal dialogs." },
    .{ .name = "inverse_bg", .value = 27, .doc = "Toasts and tooltips." },
    .{ .name = "inverse_fg", .value = 28, .doc = "Text on inverse_bg." },
};

fn param(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

const draw_param: Param = .{ .name = "draw", .type = ref("siv_draw"), .doc = "The drawing context of the running siv_draw_fn." };

/// A drawing operation: errors are sticky like a transaction's.
fn drawOp(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return op(name, doc ++ " Returns the drawing's status (see siv_draw_status).", &([_]Param{draw_param} ++ params[0..params.len].*));
}

const blend_names = [_][]const u8{
    "normal",   "multiply", "screen", "overlay", "darken",  "lighten",    "color_dodge", "color_burn",
    "hard_light", "soft_light", "difference", "exclusion", "hue", "saturation", "color",   "luminosity",
    "clear",    "src",      "dst",    "dst_over", "src_in", "dst_in",     "src_out",     "dst_out",
    "src_atop", "dst_atop", "xor",    "plus",
};

const blend_values: [blend_names.len]schema.EnumValue = blk: {
    var vs: [blend_names.len]schema.EnumValue = undefined;
    for (blend_names, 0..) |n, i| vs[i] = .{ .name = n, .value = i, .doc = if (i == 0) "Source over: the default." else "The " ++ n ++ " operator." };
    break :blk vs;
};

const desktop = @import("api_desktop.zig");

pub const decls = [_]Decl{
    result,
    alloc_fn,
    free_fn,
    allocator,

    handle("siv_app", "An application: the root object (D2). It owns an event loop, a worker pool, fonts, the compositor thread, and every window.", true),
    handle("siv_window", "A top-level window.", false),
    handle("siv_txn", "An open transaction on a window's tree (D4). Valid until it is committed or aborted.", false),
    handle("siv_node", "A node of a window's tree. Valid until a committed transaction removes it or its window is destroyed.", false),

    enumeration("siv_backend", "Where windows are shown.", &.{
        .{ .name = "wayland", .value = 0, .doc = "A Wayland compositor (the default)." },
        .{ .name = "headless", .value = 1, .doc = "No display server: windows render into memory, for tests (D24)." },
    }),
    flags("siv_app_flags", "Application options.", &.{
        .{ .name = "no_system_fonts", .bit = 0, .doc = "Do not use Fontconfig; only families added with siv_app_add_font resolve." },
        .{ .name = "reduced_motion", .bit = 1, .doc = "No caret blinking or other motion, whatever the desktop settings say." },
        .{ .name = "no_desktop_settings", .bit = 2, .doc = "Do not follow the desktop's settings (D19); use the built-in defaults. The headless backend never follows them, and never publishes to assistive technology, so tests do not depend on the desktop." },
        .{ .name = "ltr", .bit = 3, .doc = "Lay out left to right whatever the language (D21). Without ltr or rtl, the direction is the language's." },
        .{ .name = "rtl", .bit = 4, .doc = "Lay out right to left whatever the language (D21)." },
    }),
    descriptor("siv_app_desc", "Options for siv_app_create.", &.{
        .{ .name = "allocator", .type = .{ .desc = "siv_allocator" }, .doc = "Allocator hooks for everything the application allocates, on any thread; NULL for the C library allocator." },
        .{ .name = "display", .type = .string, .doc = "Wayland socket name or path; empty uses $WAYLAND_DISPLAY." },
        .{ .name = "backend", .type = ref("siv_backend"), .doc = "Default Wayland." },
        .{ .name = "flags", .type = ref("siv_app_flags"), .doc = "Options." },
        .{ .name = "name", .type = .string, .doc = "The application's name, as assistive technology shows it (D18)." },
        .{ .name = "app_id", .type = .string, .doc = "The application id: reverse DNS, the name of its .desktop file without the extension. Windows default to it, and portals and D-Bus activation use it (D19)." },
        .{ .name = "language", .type = .string, .doc = "BCP 47 language of the application's text (D21), for shaping, font fallback, and the default direction; windows and printed documents follow it unless they set their own. Empty is the process locale's ($LC_ALL, $LC_MESSAGES, $LANG); the headless backend has none, so tests do not depend on the environment." },
    }),
    callback("siv_post_fn", "Work posted with siv_post; runs on the application's thread.", &.{}, .void),
    callback("siv_destroy_fn", "Releases user_data once siv no longer needs it. Runs exactly once, on the application's thread, never while a siv callback is running.", &.{}, .void),

    value("siv_size", "A logical size.", &.{ f32Field("width", "Width in logical pixels."), f32Field("height", "Height in logical pixels.") }),
    value("siv_rect", "A logical rectangle.", &.{
        f32Field("x", "Left edge."),
        f32Field("y", "Top edge."),
        f32Field("width", "Width."),
        f32Field("height", "Height."),
    }),
    value("siv_color", "A color as sRGB-encoded components in [0, 1] with straight alpha, as in CSS.", &.{
        f32Field("r", "Red."),
        f32Field("g", "Green."),
        f32Field("b", "Blue."),
        f32Field("a", "Alpha; 0 is transparent."),
    }),

    flags("siv_window_states", "Window states the compositor set.", &.{
        .{ .name = "maximized", .bit = 0, .doc = "Maximized." },
        .{ .name = "fullscreen", .bit = 1, .doc = "Fullscreen." },
        .{ .name = "resizing", .bit = 2, .doc = "Being resized interactively." },
        .{ .name = "activated", .bit = 3, .doc = "Has the user's attention (focused)." },
        .{ .name = "tiled_left", .bit = 4, .doc = "Tiled against the left edge." },
        .{ .name = "tiled_right", .bit = 5, .doc = "Tiled against the right edge." },
        .{ .name = "tiled_top", .bit = 6, .doc = "Tiled against the top edge." },
        .{ .name = "tiled_bottom", .bit = 7, .doc = "Tiled against the bottom edge." },
        .{ .name = "suspended", .bit = 8, .doc = "Not visible; no frames are drawn." },
    }),
    flags("siv_window_flags", "Window options.", &.{
        .{ .name = "client_decorations", .bit = 0, .doc = "Prefer drawing decorations in the application (header bars) over the compositor's." },
        .{ .name = "rtl", .bit = 1, .doc = "Lay out right to left; nodes inherit the direction (D21). Without rtl or ltr, the window follows the application's direction, also when it changes." },
        .{ .name = "ltr", .bit = 2, .doc = "Lay out left to right." },
    }),
    enumeration("siv_window_event_type", "What a siv_window_event reports.", &.{
        .{ .name = "close_requested", .value = 0, .doc = "The user asked to close the window. Return true to keep it; otherwise siv destroys it." },
        .{ .name = "resized", .value = 1, .doc = "The logical size changed; width and height have the new size." },
        .{ .name = "scale_changed", .value = 2, .doc = "The buffer scale changed." },
        .{ .name = "states_changed", .value = 3, .doc = "The window states changed." },
    }),
    descriptor("siv_window_event", "A window event. Filled by siv; fields past a caller's size are absent.", &.{
        .{ .name = "type", .type = ref("siv_window_event_type"), .doc = "What happened." },
        .{ .name = "width", .type = .u32, .doc = "Logical width." },
        .{ .name = "height", .type = .u32, .doc = "Logical height." },
        .{ .name = "states", .type = ref("siv_window_states"), .doc = "Current states." },
        .{ .name = "scale", .type = .f64, .doc = "Buffer scale (1.25 for 125%)." },
    }),
    callback("siv_window_event_fn", "Receives a window's events at safe points on the application's thread (D5).", &.{
        .{ .name = "window", .type = ref("siv_window"), .doc = "The window." },
        .{ .name = "event", .type = .{ .desc = "siv_window_event" }, .doc = "The event, valid during the call." },
    }, .bool),
    descriptor("siv_window_desc", "Options for siv_window_create.", &.{
        .{ .name = "title", .type = .string, .doc = "Title." },
        .{ .name = "app_id", .type = .string, .doc = "Application id for the desktop (reverse DNS, matching the .desktop file)." },
        .{ .name = "language", .type = .string, .doc = "BCP 47 language of the window's text, for shaping and font fallback; empty follows the application's language, also when it changes." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to on_event and destroy." },
        .{ .name = "on_event", .type = ref("siv_window_event_fn"), .doc = "Receives the window's events; NULL destroys the window on a close request." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data when the window is destroyed." },
        .{ .name = "width", .type = .u32, .doc = "Logical width when the compositor lets the application choose; 0 is 640." },
        .{ .name = "height", .type = .u32, .doc = "Logical height; 0 is 480." },
        .{ .name = "min_width", .type = .u32, .doc = "Smallest width; 0 is none." },
        .{ .name = "min_height", .type = .u32, .doc = "Smallest height; 0 is none." },
        .{ .name = "max_width", .type = .u32, .doc = "Largest width; 0 is none." },
        .{ .name = "max_height", .type = .u32, .doc = "Largest height; 0 is none." },
        .{ .name = "flags", .type = ref("siv_window_flags"), .doc = "Options." },
        .{ .name = "states", .type = ref("siv_window_states"), .doc = "Ask for these states at once; only maximized and fullscreen apply." },
    }),

    enumeration("siv_popup_placement", "Where a popup goes relative to its anchor (D17). Horizontal sides are logical: they mirror in right-to-left layouts.", &.{
        .{ .name = "below", .value = 0, .doc = "Menus and combo boxes: below the anchor at its start edge; flips above and slides sideways to stay on the output." },
        .{ .name = "beside", .value = 1, .doc = "Submenus: beside the anchor's end edge, top-aligned; flips to the start side." },
        .{ .name = "tooltip", .value = 2, .doc = "Tooltips: centered below the anchor." },
    }),
    flags("siv_popup_flags", "Popup options.", &.{
        .{ .name = "no_grab", .bit = 0, .doc = "A passive popup (a tooltip): it takes no keyboard focus and clicks outside do not dismiss it." },
    }),
    descriptor("siv_popup_desc", "Options for siv_popup_create.", &.{
        .{ .name = "anchor", .type = ref("siv_node"), .doc = "A node of the parent window the popup is placed against; 0 is its root." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to on_event and destroy." },
        .{ .name = "on_event", .type = ref("siv_window_event_fn"), .doc = "Receives the popup's events: close_requested when the compositor dismissed it (a click outside); NULL destroys it then." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data when the popup is destroyed." },
        .{ .name = "width", .type = .u32, .doc = "Logical width; 0 sizes it to its content when shown." },
        .{ .name = "height", .type = .u32, .doc = "Logical height; 0 sizes it to its content when shown." },
        .{ .name = "placement", .type = ref("siv_popup_placement"), .doc = "Default below." },
        .{ .name = "flags", .type = ref("siv_popup_flags"), .doc = "Options." },
    }),

    // Layout and style.
    enumeration("siv_unit", "The unit of a siv_dimension.", &.{
        .{ .name = "auto", .value = 0, .doc = "From the content; the value is ignored." },
        .{ .name = "px", .value = 1, .doc = "Logical pixels." },
        .{ .name = "fraction", .value = 2, .doc = "A fraction of the space the parent offers (1 is all of it); auto when that space is unbounded." },
    }),
    value("siv_dimension", "A preferred size on one axis. All zero is auto.", &.{
        .{ .name = "unit", .type = ref("siv_unit"), .doc = "Unit." },
        f32Field("value", "Amount in the unit."),
    }),
    value("siv_edges", "Insets on each side. start and end are logical: they swap in right-to-left layouts.", &.{
        f32Field("start", "Start side."),
        f32Field("end", "End side."),
        f32Field("top", "Top."),
        f32Field("bottom", "Bottom."),
    }),
    value("siv_corners", "Logical corner radii.", &.{
        f32Field("top_start", "Top start corner."),
        f32Field("top_end", "Top end corner."),
        f32Field("bottom_end", "Bottom end corner."),
        f32Field("bottom_start", "Bottom start corner."),
    }),
    enumeration("siv_align", "Alignment of a child on one axis.", align_values),
    enumeration("siv_direction", "Text and layout direction (D21).", &.{
        .{ .name = "inherit", .value = 0, .doc = "The parent's direction." },
        .{ .name = "ltr", .value = 1, .doc = "Left to right." },
        .{ .name = "rtl", .value = 2, .doc = "Right to left." },
    }),
    flags("siv_layout_flags", "Layout options.", &.{
        .{ .name = "no_shrink", .bit = 0, .doc = "Flex: never shrink below the base size (shrink weight 0)." },
        .{ .name = "inset_start", .bit = 1, .doc = "Stack: inset_start positions the child." },
        .{ .name = "inset_end", .bit = 2, .doc = "Stack: inset_end positions the child." },
        .{ .name = "inset_top", .bit = 3, .doc = "Stack: inset_top positions the child." },
        .{ .name = "inset_bottom", .bit = 4, .doc = "Stack: inset_bottom positions the child." },
    }),
    descriptor("siv_layout_desc", "How a node is sized and placed (D26). Replaces the node's whole layout; zero fields are defaults.", &.{
        .{ .name = "width", .type = ref("siv_dimension"), .doc = "Preferred width; default auto." },
        .{ .name = "height", .type = ref("siv_dimension"), .doc = "Preferred height; default auto." },
        .{ .name = "basis", .type = ref("siv_dimension"), .doc = "Flex: size before growing or shrinking; default auto (the content)." },
        f32Field("min_width", "Smallest width."),
        f32Field("max_width", "Largest width; 0 is unbounded."),
        f32Field("min_height", "Smallest height."),
        f32Field("max_height", "Largest height; 0 is unbounded."),
        .{ .name = "padding", .type = ref("siv_edges"), .doc = "Space between the border box and the content." },
        f32Field("grow", "Flex: share of free space to take."),
        f32Field("shrink", "Flex: share of overflow to give up, weighted by the base size; 0 means 1 (see SIV_LAYOUT_NO_SHRINK)."),
        .{ .name = "direction", .type = ref("siv_direction"), .doc = "Default inherit." },
        .{ .name = "align_x", .type = ref("siv_align"), .doc = "Horizontal alignment in the parent." },
        .{ .name = "align_y", .type = ref("siv_align"), .doc = "Vertical alignment in the parent." },
        .{ .name = "column", .type = .u32, .doc = "Grid: column, counting from 1; 0 places automatically." },
        .{ .name = "row", .type = .u32, .doc = "Grid: row, counting from 1; 0 places automatically." },
        .{ .name = "column_span", .type = .u32, .doc = "Grid: columns covered; 0 is 1." },
        .{ .name = "row_span", .type = .u32, .doc = "Grid: rows covered; 0 is 1." },
        f32Field("inset_start", "Stack: distance from the start edge, with SIV_LAYOUT_INSET_START."),
        f32Field("inset_end", "Stack: distance from the end edge, with SIV_LAYOUT_INSET_END."),
        f32Field("inset_top", "Stack: distance from the top, with SIV_LAYOUT_INSET_TOP."),
        f32Field("inset_bottom", "Stack: distance from the bottom, with SIV_LAYOUT_INSET_BOTTOM."),
        .{ .name = "flags", .type = ref("siv_layout_flags"), .doc = "Options." },
    }),
    enumeration("siv_color_token", "A themed color (D29): resolved from the window's theme when painted, so it follows the desktop's color scheme, contrast, and accent and the application's overrides without the tree changing. none uses the literal color.", &color_token_values),
    enumeration("siv_text_role", "A themed text size (D29), relative to the desktop's UI font size; follows it live.", &.{
        .{ .name = "fixed", .value = 0, .doc = "The style's own font_size." },
        .{ .name = "body", .value = 1, .doc = "The desktop's UI font size (11 pt by default)." },
        .{ .name = "caption", .value = 2, .doc = "0.85 times body." },
        .{ .name = "heading", .value = 3, .doc = "1.2 times body." },
        .{ .name = "title", .value = 4, .doc = "1.5 times body." },
    }),
    flags("siv_visual_flags", "Appearance options.", &.{
        .{ .name = "clip", .bit = 0, .doc = "Clip descendants to the rounded border box." },
        .{ .name = "layer", .bit = 1, .doc = "Give the node its own compositor layer (D8), for example before animating it." },
        .{ .name = "no_hit_test", .bit = 2, .doc = "Pointer events pass through the node to what is below." },
        .{ .name = "hidden", .bit = 3, .doc = "The node and its subtree take no space and are not painted, hit, focusable, or in the semantics tree; its state is kept." },
    }),
    descriptor("siv_visual_desc", "A node's appearance. Repaints without layout; does not change opacity or transform.", &.{
        .{ .name = "background", .type = ref("siv_color"), .doc = "Fill of the border box; default transparent." },
        .{ .name = "border_color", .type = ref("siv_color"), .doc = "Border color." },
        .{ .name = "radius", .type = ref("siv_corners"), .doc = "Corner radii." },
        f32Field("border_width", "Border width, drawn over the padding."),
        .{ .name = "flags", .type = ref("siv_visual_flags"), .doc = "Options." },
        .{ .name = "background_token", .type = ref("siv_color_token"), .doc = "A themed background that replaces background." },
        .{ .name = "border_token", .type = ref("siv_color_token"), .doc = "A themed border color that replaces border_color." },
    }),
    value("siv_transform", "A transform in components (D8), so the compositor can animate it. Maps p to translate + origin + rotate(scale * (p - origin)); the identity has scale 1, not 0.", &.{
        f32Field("translate_x", "Horizontal translation."),
        f32Field("translate_y", "Vertical translation."),
        f32Field("scale_x", "Horizontal scale; 1 is the identity."),
        f32Field("scale_y", "Vertical scale; 1 is the identity."),
        f32Field("rotate", "Clockwise rotation in radians."),
        f32Field("origin_x", "Fixed point of scale and rotation, from the node's left edge."),
        f32Field("origin_y", "Fixed point of scale and rotation, from the node's top edge."),
    }),
    enumeration("siv_animation_property", "What a node animation changes.", &.{
        .{ .name = "none", .value = 0, .doc = "Nothing: stops the animation." },
        .{ .name = "opacity", .value = 1, .doc = "Multiplies the node's opacity." },
        .{ .name = "translate_x", .value = 2, .doc = "Adds a horizontal translation (physical: positive is rightward)." },
        .{ .name = "translate_y", .value = 3, .doc = "Adds a vertical translation." },
        .{ .name = "scale", .value = 4, .doc = "Scales both axes about the node's center." },
        .{ .name = "rotate", .value = 5, .doc = "Rotates clockwise, in radians, about the node's center." },
    }),
    enumeration("siv_easing", "A timing curve (the CSS ones).", &.{
        .{ .name = "ease", .value = 0, .doc = "CSS ease." },
        .{ .name = "linear", .value = 1, .doc = "Constant speed." },
        .{ .name = "ease_in", .value = 2, .doc = "CSS ease-in." },
        .{ .name = "ease_out", .value = 3, .doc = "CSS ease-out." },
        .{ .name = "ease_in_out", .value = 4, .doc = "CSS ease-in-out." },
    }),
    flags("siv_animation_flags", "Animation options.", &.{
        .{ .name = "alternate", .bit = 0, .doc = "Every other iteration runs backwards." },
        .{ .name = "relative", .bit = 1, .doc = "Translations are multiples of the node's width (translate_x) or height (translate_y), and follow its size." },
        .{ .name = "mirror_rtl", .bit = 2, .doc = "translate_x and rotate flip in right-to-left layouts (D21), so motion runs from the start edge to the end edge." },
    }),
    descriptor("siv_animation_desc", "An animation of one property of a node, run by the compositor (D8, D29).", &.{
        .{ .name = "property", .type = ref("siv_animation_property"), .doc = "What it changes; none stops it." },
        .{ .name = "easing", .type = ref("siv_easing"), .doc = "Timing curve of each iteration; default ease." },
        f32Field("from", "Value at the start of an iteration, applied on top of the node's own opacity or transform."),
        f32Field("to", "Value at the end of an iteration."),
        .{ .name = "duration_ms", .type = .u32, .doc = "Length of one iteration." },
        .{ .name = "delay_ms", .type = .u32, .doc = "Wait before the first iteration, counted from when the animation (re)starts." },
        .{ .name = "iterations", .type = .u32, .doc = "Number of iterations; 0 repeats until stopped." },
        .{ .name = "flags", .type = ref("siv_animation_flags"), .doc = "Options." },
    }),

    enumeration("siv_role", "Accessibility roles (D18).", &role_values),
    enumeration("siv_toggle", "A tri-state semantic property.", toggle_values),
    flags("siv_semantics_flags", "Semantic options.", &.{
        .{ .name = "focusable", .bit = 0, .doc = "Takes keyboard focus; Tab order is tree order." },
        .{ .name = "disabled", .bit = 1, .doc = "Neither focusable nor activatable." },
        .{ .name = "has_value", .bit = 2, .doc = "value_min, value_max, and value_now apply (sliders, progress)." },
        .{ .name = "live_polite", .bit = 3, .doc = "A live region: changes are announced when the user is idle." },
        .{ .name = "live_assertive", .bit = 4, .doc = "A live region: changes are announced at once. Not with SIV_SEMANTICS_LIVE_POLITE." },
        .{ .name = "modal", .bit = 5, .doc = "While shown, the pointer reaches only this subtree and Tab stays in it (dialogs)." },
    }),
    descriptor("siv_semantics_desc", "What assistive technology sees, and keyboard behavior (D18). Replaces the node's semantics.", &.{
        .{ .name = "label", .type = .string, .doc = "Accessible name; empty derives it from the text below." },
        .{ .name = "description", .type = .string, .doc = "Longer description." },
        .{ .name = "value_min", .type = .f64, .doc = "Smallest value." },
        .{ .name = "value_max", .type = .f64, .doc = "Largest value." },
        .{ .name = "value_now", .type = .f64, .doc = "Current value." },
        .{ .name = "role", .type = ref("siv_role"), .doc = "Default: the kind's role." },
        .{ .name = "checked", .type = ref("siv_toggle"), .doc = "Checkboxes, radios, switches." },
        .{ .name = "pressed", .type = ref("siv_toggle"), .doc = "Toggle buttons." },
        .{ .name = "selected", .type = ref("siv_toggle"), .doc = "Items in a selection." },
        .{ .name = "expanded", .type = ref("siv_toggle"), .doc = "Disclosures, tree items, menus." },
        .{ .name = "flags", .type = ref("siv_semantics_flags"), .doc = "Options." },
        .{ .name = "value_step", .type = .f64, .doc = "The smallest change of the value, for assistive technology; 0 for any." },
        .{ .name = "level", .type = .u32, .doc = "A heading's level or a tree item's depth, from 1 (at most 255); 0 for none." },
        .{ .name = "position", .type = .u32, .doc = "An item's position in its set, from 1, for sets not all in the tree (virtualized views); 0 for none." },
        .{ .name = "set_size", .type = .u32, .doc = "The size of that set; 0 for none." },
        .{ .name = "row", .type = .u32, .doc = "A table row's index among all rows, from 1; 0 for none." },
    }),

    enumeration("siv_axis", "A flex main axis.", &.{
        .{ .name = "row", .value = 0, .doc = "Children side by side, in reading order." },
        .{ .name = "column", .value = 1, .doc = "Children top to bottom." },
    }),
    enumeration("siv_justify", "Distribution of free space along a flex axis.", &.{
        .{ .name = "start", .value = 0, .doc = "Packed at the start." },
        .{ .name = "center", .value = 1, .doc = "Centered." },
        .{ .name = "end", .value = 2, .doc = "Packed at the end." },
        .{ .name = "space_between", .value = 3, .doc = "Equal space between children." },
        .{ .name = "space_around", .value = 4, .doc = "Equal space around each child." },
        .{ .name = "space_evenly", .value = 5, .doc = "Equal space between and at the ends." },
    }),
    flags("siv_flex_flags", "Flex options.", &.{
        .{ .name = "wrap", .bit = 0, .doc = "Wrap children onto more lines." },
        .{ .name = "line_gap", .bit = 1, .doc = "Use line_gap between wrapped lines instead of gap." },
    }),
    descriptor("siv_flex_desc", "A flex container: children along an axis.", &.{
        .{ .name = "axis", .type = ref("siv_axis"), .doc = "Default row." },
        .{ .name = "justify", .type = ref("siv_justify"), .doc = "Default start." },
        .{ .name = "align_items", .type = ref("siv_align"), .doc = "Cross-axis alignment of children whose own is auto; auto is stretch." },
        .{ .name = "flags", .type = ref("siv_flex_flags"), .doc = "Options." },
        f32Field("gap", "Space between children."),
        f32Field("line_gap", "Space between wrapped lines, with SIV_FLEX_LINE_GAP."),
    }),
    enumeration("siv_track_unit", "The unit of a grid track.", &.{
        .{ .name = "auto", .value = 0, .doc = "The largest content of its items." },
        .{ .name = "px", .value = 1, .doc = "Logical pixels." },
        .{ .name = "fr", .value = 2, .doc = "A share of the remaining space." },
    }),
    value("siv_track", "A grid column or row.", &.{
        .{ .name = "unit", .type = ref("siv_track_unit"), .doc = "Unit." },
        f32Field("value", "Amount in the unit."),
    }),
    descriptor("siv_grid_desc", "A grid container: children in column and row tracks.", &.{
        .{ .name = "columns", .type = array(ref("siv_track")), .doc = "Column tracks (copied); items beyond them get auto tracks." },
        .{ .name = "rows", .type = array(ref("siv_track")), .doc = "Row tracks (copied)." },
        f32Field("column_gap", "Space between columns."),
        f32Field("row_gap", "Space between rows."),
        .{ .name = "align_x", .type = ref("siv_align"), .doc = "Default horizontal alignment of items; auto is stretch." },
        .{ .name = "align_y", .type = ref("siv_align"), .doc = "Default vertical alignment of items; auto is stretch." },
    }),
    descriptor("siv_stack_desc", "A stack container: children on top of each other.", &.{
        .{ .name = "align_x", .type = ref("siv_align"), .doc = "Default horizontal alignment; auto is start." },
        .{ .name = "align_y", .type = ref("siv_align"), .doc = "Default vertical alignment; auto is start." },
    }),
    enumeration("siv_scroll_axis", "The axes a scroll node scrolls.", &.{
        .{ .name = "vertical", .value = 0, .doc = "Vertically." },
        .{ .name = "horizontal", .value = 1, .doc = "Horizontally." },
        .{ .name = "both", .value = 2, .doc = "Both." },
    }),

    enumeration("siv_font_weight", "Font weight.", &.{
        .{ .name = "regular", .value = 0, .doc = "Regular (400)." },
        .{ .name = "thin", .value = 1, .doc = "Thin (100)." },
        .{ .name = "light", .value = 2, .doc = "Light (300)." },
        .{ .name = "medium", .value = 3, .doc = "Medium (500)." },
        .{ .name = "semibold", .value = 4, .doc = "Semibold (600)." },
        .{ .name = "bold", .value = 5, .doc = "Bold (700)." },
        .{ .name = "black", .value = 6, .doc = "Black (900)." },
    }),
    enumeration("siv_font_slant", "Font slant.", &.{
        .{ .name = "roman", .value = 0, .doc = "Upright." },
        .{ .name = "italic", .value = 1, .doc = "Italic." },
        .{ .name = "oblique", .value = 2, .doc = "Oblique." },
    }),
    enumeration("siv_text_align", "Alignment of lines in a text node.", &.{
        .{ .name = "start", .value = 0, .doc = "The start edge of the node's direction." },
        .{ .name = "end", .value = 1, .doc = "The end edge." },
        .{ .name = "center", .value = 2, .doc = "Centered." },
    }),
    flags("siv_text_flags", "Text options.", &.{
        .{ .name = "no_wrap", .bit = 0, .doc = "Keep each paragraph on one line." },
    }),
    descriptor("siv_text_style_desc", "The style of a text or editor node (one style per node). Replaces the node's style.", &.{
        .{ .name = "family", .type = .string, .doc = "Family name or generic family; empty uses the application default." },
        .{ .name = "language", .type = .string, .doc = "BCP 47 language; empty uses the window's." },
        .{ .name = "color", .type = ref("siv_color"), .doc = "Text color; all zero is opaque black." },
        .{ .name = "font_size", .type = .f64, .doc = "Size in logical pixels; 0 is 14." },
        .{ .name = "weight", .type = ref("siv_font_weight"), .doc = "Default regular." },
        .{ .name = "slant", .type = ref("siv_font_slant"), .doc = "Default roman." },
        .{ .name = "align", .type = ref("siv_text_align"), .doc = "Default start." },
        .{ .name = "flags", .type = ref("siv_text_flags"), .doc = "Options." },
        .{ .name = "color_token", .type = ref("siv_color_token"), .doc = "A themed color that replaces color." },
        .{ .name = "size_role", .type = ref("siv_text_role"), .doc = "A themed size that replaces font_size." },
    }),
    flags("siv_editor_flags", "Editor options.", &.{
        .{ .name = "multiline", .bit = 0, .doc = "Enter inserts a line break and lines wrap; otherwise one line that scrolls to keep the caret visible." },
        .{ .name = "masked", .bit = 1, .doc = "A password field (D15): the text lives in locked memory excluded from core dumps, shows one bullet per character, has no undo or input method, and is hidden from assistive technology. Offsets still index the real text." },
    }),

    // Pointer cursors (D16).
    enumeration("siv_cursor", "A pointer cursor shape, named as in CSS. Shown through the compositor's cursor-shape-v1 when it offers it, else from the desktop's cursor theme at its size and the window's scale.", &cursor_values),
    enumeration("siv_window_edge", "A window edge or corner, for resizing from client-side decorations.", &.{
        .{ .name = "none", .value = 0, .doc = "No edge." },
        .{ .name = "top", .value = 1, .doc = "Top." },
        .{ .name = "bottom", .value = 2, .doc = "Bottom." },
        .{ .name = "left", .value = 4, .doc = "Left." },
        .{ .name = "top_left", .value = 5, .doc = "Top left." },
        .{ .name = "bottom_left", .value = 6, .doc = "Bottom left." },
        .{ .name = "right", .value = 8, .doc = "Right." },
        .{ .name = "top_right", .value = 9, .doc = "Top right." },
        .{ .name = "bottom_right", .value = 10, .doc = "Bottom right." },
    }),

    // Drag and drop (D19).
    enumeration("siv_drag_action", "What a drop does with the data.", &.{
        .{ .name = "none", .value = 0, .doc = "Nothing: no target takes it, or the drag was cancelled." },
        .{ .name = "copy", .value = 1, .doc = "The target copies the data." },
        .{ .name = "move", .value = 2, .doc = "The target takes the data and the source deletes it." },
        .{ .name = "ask", .value = 3, .doc = "The target asks the user after the drop (siv_drop_finish)." },
    }),
    .{ .flags = .{ .name = "siv_drag_action_flags", .doc = "A set of drag actions.", .since = v0_1, .value_prefix = "SIV_DRAG_ALLOW_", .bits = &.{
        .{ .name = "copy", .bit = 0, .doc = "Copy." },
        .{ .name = "move", .bit = 1, .doc = "Move." },
        .{ .name = "ask", .bit = 2, .doc = "Ask the user after the drop." },
    } } },

    // Events.
    enumeration("siv_event_type", "Kinds of node events, and the kind a siv_on handler receives.", &.{
        .{ .name = "activate", .value = 0, .doc = "Clicked, or Enter or Space while focused. A node with an activate handler can be pressed." },
        .{ .name = "pointer", .value = 1, .doc = "Pointer motion, buttons, and hover; bubbles from the node under the pointer." },
        .{ .name = "key", .value = 2, .doc = "A key, from the focused node up." },
        .{ .name = "focus", .value = 3, .doc = "The node gained or lost keyboard focus." },
        .{ .name = "scroll", .value = 4, .doc = "Scroll input; bubbles from the node under the pointer. A node with a scroll handler sees scroll input before the compositor scrolls (D8)." },
        .{ .name = "change", .value = 5, .doc = "The user changed a value: an editor's text (text, caret, and anchor have the new state), or a widget's value (value; for choices such as radio groups and tabs, index too). Delivered to the node only." },
        .{ .name = "drop", .value = 6, .doc = "A drag over a drop target (siv_set_drop_target), not bubbled: phase enter or move (return true to take the drag here), leave, or drop (data holds the data; return true if the node took it). x and y give the position, mime the type the node gets, action the negotiated action, and actions what the source offers." },
        .{ .name = "drag", .value = 7, .doc = "A drag the node started (siv_drag_start) progressed, not bubbled: phase move (the target under the pointer changed, SIV_EVENT_ACCEPTED if it takes the data, action the chosen action), drop (dropped on a target that takes it), or end (action is what the target did, none if cancelled; after a move, delete the data)." },
        .{ .name = "set_value", .value = 8, .doc = "Assistive technology asks a node with a value (SIV_SEMANTICS_HAS_VALUE) to take value. The handler applies it, clamped and stepped, or ignores it. Delivered to the node only." },
        .{ .name = "select", .value = 9, .doc = "Widgets: an item was chosen (a menu item) or a view's selection changed; index names the item, count how many are selected. Delivered to the node only." },
        .{ .name = "close", .value = 10, .doc = "Widgets: a dialog, popover, or toast asks to close (Escape, a click outside it, its timeout). Its default handler closes it; return true from siv_on to keep it. Delivered to the node only." },
        .{ .name = "viewport", .value = 11, .doc = "A scroll node's visible region changed: x and y are its scroll offset (logical, D21), width and height the size of its viewport. Delivered to the scroll node only, at a safe point: after the compositor scrolled it (D8), or at the start of the frame after its offset or size changed, before layout, so nodes a handler adds show in that frame. Virtualized views build the rows they show from it." },
    }),
    enumeration("siv_pointer_phase", "What a pointer event reports.", &.{
        .{ .name = "down", .value = 0, .doc = "A button was pressed." },
        .{ .name = "up", .value = 1, .doc = "A button was released." },
        .{ .name = "move", .value = 2, .doc = "The pointer moved." },
        .{ .name = "enter", .value = 3, .doc = "The pointer entered the node." },
        .{ .name = "leave", .value = 4, .doc = "The pointer left the node." },
        .{ .name = "cancel", .value = 5, .doc = "The press was taken away (a touch sequence the compositor claimed, or a drag started)." },
        .{ .name = "drop", .value = 6, .doc = "Drop and drag events: the data was dropped." },
        .{ .name = "end", .value = 7, .doc = "Drag events: the drag ended." },
    }),
    enumeration("siv_button", "A pointer button.", &.{
        .{ .name = "primary", .value = 0, .doc = "Primary (left)." },
        .{ .name = "secondary", .value = 1, .doc = "Secondary (right)." },
        .{ .name = "middle", .value = 2, .doc = "Middle." },
        .{ .name = "other", .value = 3, .doc = "Any other button." },
    }),
    flags("siv_modifiers", "Keyboard modifiers held.", &.{
        .{ .name = "shift", .bit = 0, .doc = "Shift." },
        .{ .name = "ctrl", .bit = 1, .doc = "Control." },
        .{ .name = "alt", .bit = 2, .doc = "Alt." },
        .{ .name = "super", .bit = 3, .doc = "Super (logo)." },
        .{ .name = "caps_lock", .bit = 4, .doc = "Caps Lock is on." },
        .{ .name = "num_lock", .bit = 5, .doc = "Num Lock is on." },
    }),
    flags("siv_event_flags", "Event details.", &.{
        .{ .name = "pressed", .bit = 0, .doc = "Key: pressed or repeated rather than released." },
        .{ .name = "repeat", .bit = 1, .doc = "Key: an automatic repeat." },
        .{ .name = "gained", .bit = 2, .doc = "Focus: the node gained focus rather than lost it." },
        .{ .name = "visible", .bit = 3, .doc = "Focus: moved by the keyboard, so it should be visible." },
        .{ .name = "accepted", .bit = 4, .doc = "Drag: the target under the pointer takes the data." },
    }),
    descriptor("siv_event", "A node event. Filled by siv; fields that do not apply to the type are zero.", &.{
        .{ .name = "window", .type = ref("siv_window"), .doc = "The node's window." },
        .{ .name = "text", .type = .string, .doc = "Key: the text the key produced. Change: the editor's text. Valid during the call." },
        .{ .name = "type", .type = ref("siv_event_type"), .doc = "What happened." },
        .{ .name = "phase", .type = ref("siv_pointer_phase"), .doc = "Pointer: what happened." },
        .{ .name = "button", .type = ref("siv_button"), .doc = "Pointer: the button pressed or released." },
        .{ .name = "modifiers", .type = ref("siv_modifiers"), .doc = "Pointer and key: modifiers held." },
        .{ .name = "flags", .type = ref("siv_event_flags"), .doc = "Details." },
        .{ .name = "keysym", .type = .u32, .doc = "Key: the XKB keysym." },
        f32Field("x", "Pointer: position in the node's coordinates."),
        f32Field("y", "Pointer: position in the node's coordinates."),
        f32Field("dx", "Scroll: horizontal distance in logical pixels."),
        f32Field("dy", "Scroll: vertical distance in logical pixels."),
        .{ .name = "caret", .type = .u32, .doc = "Change: caret byte offset." },
        .{ .name = "anchor", .type = .u32, .doc = "Change: selection anchor byte offset." },
        .{ .name = "mime", .type = .string, .doc = "Drop: the MIME type the node gets. Valid during the call." },
        .{ .name = "data", .type = array(.u8), .doc = "Drop, phase drop: the dropped data. Valid during the call." },
        .{ .name = "action", .type = ref("siv_drag_action"), .doc = "Drop and drag: the negotiated action." },
        .{ .name = "actions", .type = ref("siv_drag_action_flags"), .doc = "Drop: the actions the source offers." },
        .{ .name = "value", .type = .f64, .doc = "Change and set_value: the value." },
        .{ .name = "index", .type = .u32, .doc = "Change: the chosen option of a choice widget. Select: the item." },
        .{ .name = "count", .type = .u32, .doc = "Select: how many items are selected." },
        f32Field("width", "Viewport: the viewport's width."),
        f32Field("height", "Viewport: the viewport's height."),
        .{ .name = "clicks", .type = .u32, .doc = "Pointer, phase down or up of the primary button: 1 for a click, 2 for a double click, 3 for a triple click, within the desktop's double-click time and a few pixels (D15)." },
        .{ .name = "time", .type = .u32, .doc = "Pointer and key: the input's timestamp in milliseconds, on the compositor's clock." },
    }),
    callback("siv_event_fn", "Handles a node event at a safe point on the application's thread (D5). Return true when handled: the event stops bubbling and the default action is skipped.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node the handler was set on." },
        .{ .name = "event", .type = .{ .desc = "siv_event" }, .doc = "The event, valid during the call." },
    }, .bool),
    enumeration("siv_relation", "A node's neighbor in the tree, for siv_node_get_related.", &.{
        .{ .name = "parent", .value = 0, .doc = "Its parent." },
        .{ .name = "first_child", .value = 1, .doc = "Its first child." },
        .{ .name = "last_child", .value = 2, .doc = "Its last child." },
        .{ .name = "next", .value = 3, .doc = "The sibling after it." },
        .{ .name = "previous", .value = 4, .doc = "The sibling before it." },
    }),
    // Theming (D29).
    enumeration("siv_color_scheme", "The light or dark variant of the theme.", &.{
        .{ .name = "follow", .value = 0, .doc = "The desktop's preference (light without one)." },
        .{ .name = "light", .value = 1, .doc = "Light." },
        .{ .name = "dark", .value = 2, .doc = "Dark." },
    }),
    enumeration("siv_contrast", "The normal or high contrast variant of the theme.", &.{
        .{ .name = "follow", .value = 0, .doc = "The desktop's preference." },
        .{ .name = "normal", .value = 1, .doc = "Normal contrast." },
        .{ .name = "high", .value = 2, .doc = "High contrast." },
    }),
    descriptor("siv_theme_desc", "The application's theme choices. Replaces earlier choices; color overrides stay.", &.{
        .{ .name = "scheme", .type = ref("siv_color_scheme"), .doc = "Default follow." },
        .{ .name = "contrast", .type = ref("siv_contrast"), .doc = "Default follow." },
    }),
    enumeration("siv_theme_variant", "Which of the theme's compiled variants a color override applies to.", &.{
        .{ .name = "all", .value = 0, .doc = "Every variant." },
        .{ .name = "light", .value = 1, .doc = "Light, normal contrast." },
        .{ .name = "dark", .value = 2, .doc = "Dark, normal contrast." },
        .{ .name = "light_high_contrast", .value = 3, .doc = "Light, high contrast." },
        .{ .name = "dark_high_contrast", .value = 4, .doc = "Dark, high contrast." },
    }),
    handle("siv_timer", "A one-shot timer on the application's loop. Valid until it fires or is cancelled.", false),

    // Stock widgets (D22).
    flags("siv_widget_flags", "Widget options.", &.{
        .{ .name = "disabled", .bit = 0, .doc = "Shown dimmed; neither focusable nor operable." },
    }),
    enumeration("siv_button_style", "How a button looks.", &.{
        .{ .name = "default", .value = 0, .doc = "A bordered control." },
        .{ .name = "primary", .value = 1, .doc = "Filled with the accent: the suggested action." },
        .{ .name = "flat", .value = 2, .doc = "No border or fill until hovered (toolbars)." },
        .{ .name = "destructive", .value = 3, .doc = "Filled with the destructive color." },
    }),
    descriptor("siv_button_desc", "A push button.", &.{
        .{ .name = "label", .type = .string, .doc = "The label, copied; also the accessible name." },
        .{ .name = "style", .type = ref("siv_button_style"), .doc = "Default default." },
        .{ .name = "flags", .type = ref("siv_widget_flags"), .doc = "Options." },
    }),
    descriptor("siv_toggle_desc", "A toggle button, check box, or switch.", &.{
        .{ .name = "label", .type = .string, .doc = "The label, copied; also the accessible name." },
        .{ .name = "checked", .type = ref("siv_toggle"), .doc = "Initial state; unset is off. Mixed only for check boxes." },
        .{ .name = "flags", .type = ref("siv_widget_flags"), .doc = "Options." },
    }),
    descriptor("siv_radio_group_desc", "A group of radio buttons, added with siv_radio. The first one starts selected.", &.{
        .{ .name = "label", .type = .string, .doc = "The group's accessible name, copied." },
        .{ .name = "axis", .type = ref("siv_axis"), .doc = "How the radios are arranged; default row." },
        .{ .name = "flags", .type = ref("siv_widget_flags"), .doc = "Options." },
    }),
    flags("siv_text_field_flags", "Text field options.", &.{
        .{ .name = "multiline", .bit = 0, .doc = "A text area: Enter inserts a line break and lines wrap." },
        .{ .name = "masked", .bit = 1, .doc = "A password field (SIV_EDITOR_MASKED)." },
        .{ .name = "disabled", .bit = 2, .doc = "Shown dimmed; not focusable." },
    }),
    descriptor("siv_text_field_desc", "A framed editor: a text field, or with SIV_TEXT_FIELD_MULTILINE a text area.", &.{
        .{ .name = "text", .type = .string, .doc = "Initial text, copied." },
        .{ .name = "placeholder", .type = .string, .doc = "Shown while empty, copied." },
        .{ .name = "label", .type = .string, .doc = "Accessible name, copied; empty uses the placeholder." },
        .{ .name = "flags", .type = ref("siv_text_field_flags"), .doc = "Options." },
        .{ .name = "rows", .type = .u32, .doc = "Text areas: the least height in lines; 0 is 3." },
    }),
    flags("siv_range_flags", "Range widget options.", &.{
        .{ .name = "disabled", .bit = 0, .doc = "Shown dimmed; neither focusable nor operable." },
        .{ .name = "indeterminate", .bit = 1, .doc = "Progress bars: progress is unknown; the value is ignored." },
    }),
    enumeration("siv_widget_part", "A part of a stock widget that the application fills or handles, for siv_widget_get_part.", &.{
        .{ .name = "content", .value = 0, .doc = "Dialogs and popovers: the container for their content." },
        .{ .name = "actions", .value = 1, .doc = "Dialogs: the row for their buttons, at the end edge." },
        .{ .name = "tab", .value = 2, .doc = "Tabs: the tab at index." },
        .{ .name = "panel", .value = 3, .doc = "Tabs: the panel at index." },
        .{ .name = "start", .value = 4, .doc = "Split panes: the pane at the start (or top)." },
        .{ .name = "end", .value = 5, .doc = "Split panes: the pane at the end (or bottom)." },
        .{ .name = "menu", .value = 6, .doc = "Menu buttons: their menu, for siv_menu_item and siv_menu_open." },
    }),
    descriptor("siv_menu_desc", "A menu: items added with siv_menu_item and shown in a popup by siv_menu_open.", &.{
        .{ .name = "label", .type = .string, .doc = "The menu's accessible name, copied." },
    }),
    flags("siv_menu_item_flags", "Menu item options.", &.{
        .{ .name = "separator", .bit = 0, .doc = "A separator line instead of an item; the label is ignored." },
        .{ .name = "disabled", .bit = 1, .doc = "Shown dimmed and cannot be chosen." },
        .{ .name = "checkable", .bit = 2, .doc = "Shows a check mark when its value is 1 (siv_widget_set_value)." },
        .{ .name = "checked", .bit = 3, .doc = "Checkable and checked." },
    }),
    descriptor("siv_menu_item_desc", "A menu item.", &.{
        .{ .name = "label", .type = .string, .doc = "The label, copied." },
        .{ .name = "shortcut", .type = .string, .doc = "A key binding to show at the end edge, copied; siv does not bind it." },
        .{ .name = "flags", .type = ref("siv_menu_item_flags"), .doc = "Options." },
        .{ .name = "mnemonic", .type = .u32, .doc = "A keysym that chooses the item while its menu is open, letters in either case; 0 for none." },
        .{ .name = "submenu", .type = ref("siv_node"), .doc = "A menu (siv_menu) the item opens beside itself, instead of being chosen: on hover, Enter, Space, a click, or the arrow toward the end edge; the arrow toward the start edge and Escape close it again. Choosing in it reports SIV_EVENT_SELECT on the submenu and closes every menu of the chain; 0 for none." },
    }),
    descriptor("siv_popover_desc", "A popover: a card in a popup next to its anchor.", &.{
        .{ .name = "label", .type = .string, .doc = "Accessible name, copied." },
        .{ .name = "placement", .type = ref("siv_popup_placement"), .doc = "Default below." },
        .{ .name = "flags", .type = ref("siv_popup_flags"), .doc = "SIV_POPUP_NO_GRAB for a passive popover that neither takes the keyboard nor closes on clicks outside." },
    }),
    descriptor("siv_dialog_desc", "A modal dialog over its parent (a stack such as the window's root).", &.{
        .{ .name = "title", .type = .string, .doc = "The title, shown and used as the accessible name, copied." },
        .{ .name = "text", .type = .string, .doc = "A message under the title, copied; may be empty." },
    }),
    descriptor("siv_tabs_desc", "Tabs: a tab list over panels, added with siv_tab.", &.{
        .{ .name = "label", .type = .string, .doc = "The tab list's accessible name, copied." },
    }),
    descriptor("siv_split_desc", "A split pane: two panes and a divider the user drags.", &.{
        .{ .name = "axis", .type = ref("siv_axis"), .doc = "row puts the panes side by side, column one above the other." },
        f32Field("position", "The start pane's size in logical pixels; 0 is 200."),
        f32Field("min_start", "The start pane's least size."),
        f32Field("min_end", "The end pane's least size."),
        .{ .name = "label", .type = .string, .doc = "The divider's accessible name, copied." },
    }),
    flags("siv_toast_flags", "Toast options.", &.{
        .{ .name = "assertive", .bit = 0, .doc = "Announced at once (an alert) rather than when the user is idle." },
        .{ .name = "persistent", .bit = 1, .doc = "Never times out." },
    }),
    descriptor("siv_toast_desc", "A brief message at the bottom of its parent (a stack such as the window's root).", &.{
        .{ .name = "text", .type = .string, .doc = "The message, copied." },
        .{ .name = "timeout_ms", .type = .u32, .doc = "How long it shows; 0 is 4000." },
        .{ .name = "flags", .type = ref("siv_toast_flags"), .doc = "Options." },
    }),
    enumeration("siv_selection_mode", "How many items of a view can be selected.", &.{
        .{ .name = "none", .value = 0, .doc = "None: the view only has a cursor." },
        .{ .name = "single", .value = 1, .doc = "One at a time: the cursor's item." },
        .{ .name = "multiple", .value = 2, .doc = "Any number: Ctrl toggles one, Shift extends a range, Ctrl+A selects all." },
    }),
    callback("siv_bind_fn", "Fills a view's row for an item, inside the view's transaction: add and change nodes under row with txn, and do not begin another. Views call it only for the rows they show, as they come into view. A recycled row still holds what an earlier bind put in it, for another item, to update or replace.", &.{
        .{ .name = "txn", .type = ref("siv_txn"), .doc = "The view's open transaction." },
        .{ .name = "row", .type = ref("siv_node"), .doc = "The container to fill: a box, or for tables a grid with the columns' tracks." },
        .{ .name = "item", .type = .u64, .doc = "Lists, tables, and grids: the item's index. Trees: the item's id." },
        .{ .name = "index", .type = .u32, .doc = "The row's position among the view's rows." },
        .{ .name = "depth", .type = .u32, .doc = "Trees: the item's depth, 0 at the top." },
        .{ .name = "recycled", .type = .bool, .doc = "The row showed another item before." },
    }, .void),
    callback("siv_tree_count_fn", "The number of children of a tree view's item.", &.{
        .{ .name = "parent", .type = .u64, .doc = "An item's id, or 0 for the top level." },
    }, .u32),
    callback("siv_tree_child_fn", "The id of a child of a tree view's item: unique and nonzero.", &.{
        .{ .name = "parent", .type = .u64, .doc = "An item's id, or 0 for the top level." },
        .{ .name = "index", .type = .u32, .doc = "Which child, from 0." },
    }, .u64),
    descriptor("siv_view_desc", "A virtualized view: only the rows in view exist as nodes, filled by bind as they scroll in.", &.{
        .{ .name = "label", .type = .string, .doc = "The view's accessible name, copied." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to the callbacks and destroy." },
        .{ .name = "bind", .type = ref("siv_bind_fn"), .doc = "Fills rows." },
        .{ .name = "children", .type = ref("siv_tree_count_fn"), .doc = "Trees: counts an item's children." },
        .{ .name = "child", .type = ref("siv_tree_child_fn"), .doc = "Trees: an item's child." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data when the view is removed." },
        .{ .name = "count", .type = .u32, .doc = "Lists, tables, and grids: the number of items." },
        f32Field("item_height", "Every row's height, or every cell's in a grid; 0 is 32."),
        f32Field("item_width", "Grids: every cell's width; 0 is 96."),
        .{ .name = "selection", .type = ref("siv_selection_mode"), .doc = "Default none." },
    }),
    descriptor("siv_column_desc", "A table column.", &.{
        .{ .name = "title", .type = .string, .doc = "The header, copied." },
        .{ .name = "width", .type = ref("siv_track"), .doc = "The column's track; auto is 1 fr." },
    }),
    descriptor("siv_range_desc", "A slider, spin button, or progress bar. With min equal to max the range is 0 to 100.", &.{
        .{ .name = "label", .type = .string, .doc = "Accessible name, copied." },
        .{ .name = "min", .type = .f64, .doc = "Smallest value." },
        .{ .name = "max", .type = .f64, .doc = "Largest value." },
        .{ .name = "value", .type = .f64, .doc = "Initial value, clamped." },
        .{ .name = "step", .type = .f64, .doc = "Values are min plus multiples of step, and arrow keys move by it; 0 is continuous for sliders (arrows move a hundredth) and 1 for spin buttons." },
        .{ .name = "page", .type = .f64, .doc = "What Page Up and Page Down move; 0 is ten steps." },
        .{ .name = "digits", .type = .u32, .doc = "Spin buttons: decimals shown." },
        .{ .name = "flags", .type = ref("siv_range_flags"), .doc = "Options." },
    }),

    // Canvases (D28).
    handle("siv_draw", "A drawing context: valid only during the siv_draw_fn call it is passed to.", false),
    handle("siv_image", "Immutable pixels for image nodes and siv_draw_image. Destroying the handle drops the application's reference: nodes and frames that show the image keep it until they stop.", false),
    descriptor("siv_constraints", "The sizes a canvas may take, from layout. A maximum may be INFINITY.", &.{
        f32Field("min_width", "Smallest width."),
        f32Field("max_width", "Largest width, or INFINITY."),
        f32Field("min_height", "Smallest height."),
        f32Field("max_height", "Largest height, or INFINITY."),
    }),
    callback("siv_measure_fn", "Sizes a canvas during layout, in the frame phase (D5, D26). Asked with an unbounded width for the canvas's preferred width, then with its final constraints; the result is clamped to them. Must not change the tree: transactions, window changes, and focus return SIV_ERROR_BUSY.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The canvas." },
        .{ .name = "constraints", .type = .{ .desc = "siv_constraints" }, .doc = "The sizes allowed, valid during the call." },
    }, ref("siv_size")),
    callback("siv_draw_fn", "Draws a canvas's content in its coordinates, (0, 0) to (width, height), in the frame phase when the canvas was invalidated or resized (D5). Must not change the tree. The content is clipped to the canvas.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The canvas." },
        .{ .name = "draw", .type = ref("siv_draw"), .doc = "The drawing context, valid during the call." },
        .{ .name = "width", .type = .f32, .doc = "The canvas's width." },
        .{ .name = "height", .type = .f32, .doc = "The canvas's height." },
    }, .void),
    descriptor("siv_canvas_desc", "A canvas's callbacks and intrinsic size.", &.{
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to draw, measure, and destroy." },
        .{ .name = "draw", .type = ref("siv_draw_fn"), .doc = "Draws the content; NULL draws nothing." },
        .{ .name = "measure", .type = ref("siv_measure_fn"), .doc = "Sizes the canvas; NULL uses width and height." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data when the callbacks are replaced or the canvas is destroyed." },
        f32Field("width", "Intrinsic width without measure."),
        f32Field("height", "Intrinsic height without measure."),
    }),
    value("siv_radii", "Physical corner radii of a rounded rectangle in a canvas.", &.{
        f32Field("top_left", "Top left."),
        f32Field("top_right", "Top right."),
        f32Field("bottom_right", "Bottom right."),
        f32Field("bottom_left", "Bottom left."),
    }),
    value("siv_affine", "A 2D affine transform: x' = a x + c y + e, y' = b x + d y + f. The identity is a = d = 1.", &.{
        f32Field("a", "Row 1, column 1."),
        f32Field("b", "Row 2, column 1."),
        f32Field("c", "Row 1, column 2."),
        f32Field("d", "Row 2, column 2."),
        f32Field("e", "Horizontal translation."),
        f32Field("f", "Vertical translation."),
    }),
    enumeration("siv_paint_type", "What a siv_paint_desc paints with.", &.{
        .{ .name = "solid", .value = 0, .doc = "color." },
        .{ .name = "linear", .value = 1, .doc = "A linear gradient from (x0, y0) to (x1, y1)." },
        .{ .name = "radial", .value = 2, .doc = "A two-point conical gradient from the circle (x0, y0, r0) to (x1, y1, r1)." },
        .{ .name = "sweep", .value = 3, .doc = "A sweep gradient around (x0, y0), clockwise from start_angle to end_angle (radians from +x)." },
    }),
    enumeration("siv_extend", "How a gradient continues past its stops.", &.{
        .{ .name = "pad", .value = 0, .doc = "The end colors continue." },
        .{ .name = "repeat", .value = 1, .doc = "The stops repeat." },
        .{ .name = "reflect", .value = 2, .doc = "The stops repeat, mirrored every other time." },
    }),
    value("siv_gradient_stop", "A gradient color stop.", &.{
        f32Field("offset", "Position along the gradient, usually 0 to 1; non-decreasing."),
        .{ .name = "color", .type = ref("siv_color"), .doc = "Color." },
    }),
    descriptor("siv_paint_desc", "A fill or stroke paint, in the coordinates of the current layer. Gradients interpolate in linear light (D9). NULL, or all zero, is opaque black.", &.{
        .{ .name = "stops", .type = array(ref("siv_gradient_stop")), .doc = "Gradient stops (copied); at least one for gradients." },
        .{ .name = "color", .type = ref("siv_color"), .doc = "Solid color; all zero is opaque black." },
        f32Field("x0", "Gradient start point or sweep center."),
        f32Field("y0", "Gradient start point or sweep center."),
        f32Field("x1", "Gradient end point."),
        f32Field("y1", "Gradient end point."),
        f32Field("r0", "Radial: start radius."),
        f32Field("r1", "Radial: end radius."),
        f32Field("start_angle", "Sweep: angle of the first stop."),
        f32Field("end_angle", "Sweep: angle of the last stop."),
        .{ .name = "type", .type = ref("siv_paint_type"), .doc = "Default solid." },
        .{ .name = "extend", .type = ref("siv_extend"), .doc = "Default pad." },
    }),
    enumeration("siv_line_join", "How stroke segments join.", &.{
        .{ .name = "miter", .value = 0, .doc = "Sharp, up to the miter limit." },
        .{ .name = "round", .value = 1, .doc = "Rounded." },
        .{ .name = "bevel", .value = 2, .doc = "Cut off." },
    }),
    enumeration("siv_line_cap", "How open stroke ends look.", &.{
        .{ .name = "butt", .value = 0, .doc = "Flat at the end point." },
        .{ .name = "round", .value = 1, .doc = "Rounded past the end point." },
        .{ .name = "square", .value = 2, .doc = "Square past the end point." },
    }),
    flags("siv_fill_flags", "Options for filling or clipping to the current path.", &.{
        .{ .name = "even_odd", .bit = 0, .doc = "Use the even-odd rule instead of nonzero winding." },
        .{ .name = "keep_path", .bit = 1, .doc = "Keep the current path afterwards instead of clearing it." },
    }),
    flags("siv_stroke_flags", "Stroke options.", &.{
        .{ .name = "keep_path", .bit = 0, .doc = "Keep the current path afterwards instead of clearing it." },
    }),
    descriptor("siv_stroke_desc", "How the current path is stroked. NULL is a 1 px solid stroke.", &.{
        .{ .name = "dashes", .type = array(.f32), .doc = "Alternating on and off lengths (copied); empty is solid." },
        f32Field("width", "Line width; 0 is 1."),
        f32Field("miter_limit", "Ratio beyond which a miter join becomes a bevel; 0 is 4."),
        f32Field("dash_offset", "Distance into the dash pattern at the start."),
        .{ .name = "join", .type = ref("siv_line_join"), .doc = "Default miter." },
        .{ .name = "cap", .type = ref("siv_line_cap"), .doc = "Default butt." },
        .{ .name = "flags", .type = ref("siv_stroke_flags"), .doc = "Options." },
    }),
    enumeration("siv_blend_mode", "How a layer composites onto what is below it (the COLRv1 set, D9).", &blend_values),
    enumeration("siv_image_format", "Pixel layout of siv_image_desc.pixels.", &.{
        .{ .name = "rgba8", .value = 0, .doc = "8-bit sRGB-encoded R, G, B, A bytes, straight alpha." },
        .{ .name = "bgra8", .value = 1, .doc = "8-bit sRGB-encoded B, G, R, A bytes, straight alpha." },
        .{ .name = "bgrx8", .value = 2, .doc = "8-bit sRGB-encoded B, G, R bytes and an ignored byte: opaque." },
    }),
    flags("siv_image_flags", "How an image is shown.", &.{
        .{ .name = "nearest", .bit = 0, .doc = "Sample the nearest pixel (pixel art) instead of bilinear." },
        .{ .name = "mirror_rtl", .bit = 1, .doc = "Image nodes: mirror horizontally in right-to-left layouts (directional icons, D21)." },
    }),
    enumeration("siv_fit", "How an image node fits its image into its content box.", &.{
        .{ .name = "contain", .value = 0, .doc = "Scaled to fit inside, centered, keeping its aspect ratio." },
        .{ .name = "cover", .value = 1, .doc = "Scaled to cover, centered and cropped, keeping its aspect ratio." },
        .{ .name = "fill", .value = 2, .doc = "Stretched to the box." },
        .{ .name = "none", .value = 3, .doc = "At its size, centered and cropped." },
    }),
    descriptor("siv_image_view_desc", "What an image node shows.", &.{
        .{ .name = "image", .type = ref("siv_image"), .doc = "The image; 0 shows nothing. The node keeps it alive." },
        .{ .name = "fit", .type = ref("siv_fit"), .doc = "Default contain." },
        .{ .name = "flags", .type = ref("siv_image_flags"), .doc = "Options." },
    }),
    descriptor("siv_image_desc", "Pixels for siv_image_create.", &.{
        .{ .name = "pixels", .type = array(.u8), .doc = "Rows of pixels, copied; at least stride * (height - 1) + width * 4 bytes." },
        .{ .name = "width", .type = .u32, .doc = "Width in pixels; at least 1." },
        .{ .name = "height", .type = .u32, .doc = "Height in pixels; at least 1." },
        .{ .name = "stride", .type = .u32, .doc = "Bytes per row; 0 is width * 4." },
        .{ .name = "format", .type = ref("siv_image_format"), .doc = "Default rgba8." },
    }),
    descriptor("siv_drop_target_desc", "What a drop target takes (D19).", &.{
        .{ .name = "mimes", .type = .string, .doc = "MIME types, one per line, preferred first (copied); empty makes the node no drop target." },
        .{ .name = "actions", .type = ref("siv_drag_action_flags"), .doc = "Actions it takes; 0 is copy." },
        .{ .name = "preferred", .type = ref("siv_drag_action"), .doc = "The action to ask for when the source offers several; none takes the first of copy, move, and ask both sides allow." },
    }),
    flags("siv_drag_flags", "Drag options.", &.{
        .{ .name = "in_app", .bit = 0, .doc = "Only this application's windows can take the data: other clients see the drag with a private MIME type and never get the data." },
    }),
    descriptor("siv_drag_desc", "The data a drag offers, and how.", &.{
        .{ .name = "mimes", .type = .string, .doc = "MIME types, one per line, preferred first." },
        .{ .name = "data", .type = array(.u8), .doc = "The data (copied)." },
        .{ .name = "lengths", .type = array(.usize), .doc = "How many bytes of data each MIME type gets, in order, splitting data; empty gives every type all of data." },
        .{ .name = "icon", .type = ref("siv_image"), .doc = "Follows the pointer, one image pixel per logical pixel; 0 for none." },
        .{ .name = "actions", .type = ref("siv_drag_action_flags"), .doc = "Actions the source allows; 0 is copy." },
        .{ .name = "flags", .type = ref("siv_drag_flags"), .doc = "Options." },
        f32Field("hotspot_x", "The point of the icon under the pointer, in image pixels."),
        f32Field("hotspot_y", "The point of the icon under the pointer, in image pixels."),
    }),
    value("siv_text_metrics", "The size of laid-out text.", &.{
        f32Field("width", "Width of the widest line."),
        f32Field("height", "Height of all lines."),
        f32Field("baseline", "Distance from the top to the first line's baseline."),
    }),
    // External content (D17).
    handle("siv_external", "A slot in a window for content rendered outside siv: frames a producer submits, or a wl_surface an embedder renders into. External nodes (siv_external_view) show it.", false),
    enumeration("siv_external_event_type", "What a siv_external_event reports.", &.{
        .{ .name = "released", .value = 0, .doc = "Frames: no frame reads the frame with this key any more; its memory may be reused. Only for slots without a release callback." },
        .{ .name = "configure", .value = 1, .doc = "Surfaces: render frames of buffer_width x buffer_height pixels from now on, and one soon even if nothing else changed." },
    }),
    descriptor("siv_external_event", "An external slot's event. Filled by siv.", &.{
        .{ .name = "key", .type = .u64, .doc = "Released: the frame's key." },
        .{ .name = "type", .type = ref("siv_external_event_type"), .doc = "What happened." },
        .{ .name = "width", .type = .u32, .doc = "Configure: logical width." },
        .{ .name = "height", .type = .u32, .doc = "Configure: logical height." },
        .{ .name = "buffer_width", .type = .u32, .doc = "Configure: width in buffer pixels (the logical width times the window's scale)." },
        .{ .name = "buffer_height", .type = .u32, .doc = "Configure: height in buffer pixels." },
        f32Field("scale", "Configure: the window's buffer scale."),
    }),
    callback("siv_external_event_fn", "Receives an external slot's events at safe points on the application's thread (D5).", &.{
        .{ .name = "external", .type = ref("siv_external"), .doc = "The slot." },
        .{ .name = "event", .type = .{ .desc = "siv_external_event" }, .doc = "The event, valid during the call." },
    }, .void),
    callback("siv_external_release_fn", "Gets a frame slot's memory back: no frame reads the frame with this key any more. Runs on siv's compositor thread, not the application's, so that a producer recycles its buffers however busy the application's thread is (D8): it must return quickly and may call only siv_external_submit and siv_post.", &.{
        .{ .name = "external", .type = ref("siv_external"), .doc = "The slot." },
        .{ .name = "key", .type = .u64, .doc = "The released frame's key." },
    }, .void),
    descriptor("siv_external_desc", "Options for an external slot.", &.{
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to on_event, release, and destroy." },
        .{ .name = "on_event", .type = ref("siv_external_event_fn"), .doc = "Receives configures, and releases when release is NULL, on the application's thread; may be NULL." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data when the slot or its window is destroyed (later with release; see there), on the application's thread." },
        .{ .name = "release", .type = ref("siv_external_release_fn"), .doc = "Frame slots: receives releases on the compositor thread instead of on_event. Then destroy runs only after the slot is destroyed and its last frame released, and user_data must stay valid until then." },
    }),
    enumeration("siv_external_format", "Pixel layout of submitted external frames.", &.{
        .{ .name = "xrgb8888", .value = 0, .doc = "B, G, R, X bytes (XRGB8888 in memory), opaque, sRGB-encoded." },
    }),
    enumeration("siv_external_memory", "Where an external frame's pixels are.", &.{
        .{ .name = "shm", .value = 0, .doc = "Shared memory the compositor can map, such as a memfd." },
        .{ .name = "dmabuf", .value = 1, .doc = "A Linux dma-buf, for example from a video decoder or another GPU API. Shown once its implicit fences signal. The compositor promotes it to a subsurface when the Wayland compositor accepts its format and modifier; otherwise siv's Vulkan renderer imports it, and without Vulkan only a linear XRGB8888 dma-buf is drawn (read through a mapping), any other is not drawn but still released (D17)." },
    }),
    value("siv_external_plane", "A dma-buf plane after the first.", &.{
        .{ .name = "fd", .type = .i32, .doc = "The plane's dma-buf; siv duplicates it." },
        .{ .name = "offset", .type = .u32, .doc = "Byte offset of the plane." },
        .{ .name = "stride", .type = .u32, .doc = "Bytes per row." },
    }),
    descriptor("siv_external_frame_desc", "One frame of external content in shared memory or a dma-buf.", &.{
        .{ .name = "key", .type = .u64, .doc = "Identifies the pixels; change it whenever they change. Released frames are reported by key." },
        .{ .name = "fd", .type = .i32, .doc = "Shared memory the compositor can map, such as a memfd, or the dma-buf of the first plane. siv duplicates it; the caller keeps its own." },
        .{ .name = "offset", .type = .u32, .doc = "Byte offset of the first row." },
        .{ .name = "width", .type = .u32, .doc = "Width in pixels." },
        .{ .name = "height", .type = .u32, .doc = "Height in pixels." },
        .{ .name = "stride", .type = .u32, .doc = "Bytes per row; 0 is width * 4." },
        .{ .name = "format", .type = ref("siv_external_format"), .doc = "Default xrgb8888." },
        .{ .name = "modifier", .type = .u64, .doc = "dma-buf: the DRM format modifier (0 is linear)." },
        .{ .name = "memory", .type = ref("siv_external_memory"), .doc = "Default shm." },
        .{ .name = "drm_format", .type = .u32, .doc = "dma-buf: the DRM fourcc, for formats siv_external_format lacks (such as NV12 for promotion); 0 follows format." },
        .{ .name = "planes", .type = array(ref("siv_external_plane")), .doc = "dma-buf: planes after the first (fd, offset, stride), at most three; copied." },
    }),
};

pub const functions = [_]Function{
    .{
        .name = "siv_version",
        .doc = "Returns the version of the loaded library, encoded as SIV_MAKE_VERSION(major, minor, patch).",
        .since = v0_1,
        .ret = .u32,
    },
    .{
        .name = "siv_result_name",
        .doc = "Returns the name of a result code, such as \"SIV_ERROR_OUT_OF_MEMORY\", or \"SIV_RESULT_UNKNOWN\" for a value this version does not define.",
        .since = v0_1,
        .params = &.{.{ .name = "result", .type = ref("siv_result"), .doc = "Any value." }},
        .ret = .static_string,
    },

    // The application and its loop.
    call("siv_app_create", "Creates an application: its loop, worker pool, fonts, and compositor thread, connected to the display. Every other call on it must come from this thread, except siv_post.", &.{
        .{ .name = "desc", .type = .{ .desc = "siv_app_desc" }, .doc = "Options; NULL for defaults." },
        .{ .name = "app", .type = out(ref("siv_app")), .doc = "The new application." },
    }),
    op("siv_app_destroy", "Destroys the application, its windows, and every handle it issued. Posted work that has not run gets its destroy-notify instead (D5); so does every callback still registered. Not from a siv callback (SIV_ERROR_BUSY).", &.{app_param}),
    call("siv_app_fd", "The application's loop file descriptor, for embedding in another event loop (D6). It is readable whenever siv_app_dispatch has work; then call siv_app_dispatch(app, 0).", &.{
        app_param,
        .{ .name = "fd", .type = out(.i32), .doc = "The descriptor; siv owns it." },
    }),
    call("siv_app_dispatch", "Runs one loop iteration: input, timers, posted work, callbacks, and frames (D5). SIV_ERROR_UNAVAILABLE once the display connection is lost; SIV_ERROR_OUT_OF_MEMORY when events were lost.", &.{
        app_param,
        .{ .name = "timeout_ms", .type = .i32, .doc = "Longest wait for work: -1 blocks, 0 never waits." },
    }),
    call("siv_run", "Dispatches until siv_app_quit is called or the last window is destroyed.", &.{app_param}),
    op("siv_app_quit", "Makes the running siv_run return after the current iteration.", &.{app_param}),
    call("siv_post", "Runs callback(user_data) on the application's thread at its next dispatch, then destroy(user_data). Safe from any thread, even while the application is being destroyed: either the call fails with SIV_ERROR_INVALID_HANDLE and nothing runs, or destroy runs exactly once (alone, if the application is destroyed first). Allocates with the application's allocator on the calling thread.", &.{
        app_param,
        .{ .name = "callback", .type = ref("siv_post_fn"), .doc = "The work." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data; may be NULL." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to both." },
    }),
    call("siv_app_add_font", "Adds a font file's bytes (copied) to the end of a family's fallback chain. Registered families take precedence over Fontconfig.", &.{
        app_param,
        .{ .name = "family", .type = .string, .doc = "Family name." },
        .{ .name = "data", .type = array(.u8), .doc = "An OpenType or TrueType font." },
    }),
    call("siv_app_set_default_font", "Sets the family used by text styles that name none. By default it is the desktop's font (D19), else sans-serif; once set here, the desktop's no longer replaces it.", &.{
        app_param,
        .{ .name = "family", .type = .string, .doc = "Family name." },
    }),
    call("siv_app_set_language", "Changes the application's language and direction (D21). Windows that follow the application shape their text again and mirror their layout; documents printed later default to them.", &.{
        app_param,
        .{ .name = "language", .type = .string, .doc = "BCP 47 language; empty is the process locale's." },
        .{ .name = "direction", .type = ref("siv_direction"), .doc = "Left to right or right to left; inherit is the direction the language is written in." },
    }),
    call("siv_app_is_rtl", "Whether the application lays out right to left (D21).", &.{
        app_param,
        .{ .name = "rtl", .type = out(.bool), .doc = "Right to left." },
    }),

    // Windows.
    call("siv_window_create", "Creates a top-level window. It is shown once its first frame is ready.", &.{
        app_param,
        .{ .name = "desc", .type = .{ .desc = "siv_window_desc" }, .doc = "Options; NULL for defaults." },
        .{ .name = "window", .type = out(ref("siv_window")), .doc = "The new window." },
    }),
    op("siv_window_destroy", "Destroys a window, its open transaction, and its nodes. Their callbacks' destroy-notify runs, after the running callback returns if called from one.", &.{window_param}),
    op("siv_window_set_title", "Sets the title.", &.{ window_param, .{ .name = "title", .type = .string, .doc = "Copied." } }),
    call("siv_window_get_size", "The logical size from the last configure.", &.{ window_param, .{ .name = "size", .type = out(ref("siv_size")), .doc = "The size." } }),
    call("siv_window_get_scale", "The buffer scale from the last configure.", &.{ window_param, .{ .name = "scale", .type = out(.f64), .doc = "The scale." } }),
    call("siv_window_get_states", "The states from the last configure.", &.{ window_param, .{ .name = "states", .type = out(ref("siv_window_states")), .doc = "The states." } }),
    op("siv_window_set_maximized", "Asks the compositor to maximize or restore the window.", &.{ window_param, .{ .name = "maximized", .type = .bool, .doc = "Maximize." } }),
    op("siv_window_set_fullscreen", "Asks the compositor to make the window fullscreen or not.", &.{ window_param, .{ .name = "fullscreen", .type = .bool, .doc = "Fullscreen." } }),
    op("siv_window_minimize", "Asks the compositor to minimize the window.", &.{window_param}),
    op("siv_window_set_size_limits", "Sets the smallest and largest logical size; zero components are unlimited.", &.{
        window_param,
        .{ .name = "min", .type = ref("siv_size"), .doc = "Smallest size." },
        .{ .name = "max", .type = ref("siv_size"), .doc = "Largest size." },
    }),
    call("siv_popup_create", "Creates a popup of a window (an xdg_popup, D17): a window with its own tree that is mapped by siv_popup_show, once its content is built, so that it can size to it. Destroying the parent destroys its popups first.", &.{
        window_param,
        .{ .name = "desc", .type = .{ .desc = "siv_popup_desc" }, .doc = "Anchor, placement, size, and callbacks; NULL anchors below the parent's root." },
        .{ .name = "popup", .type = out(ref("siv_window")), .doc = "The popup: a window handle." },
    }),
    call("siv_popup_show", "Maps a popup made by siv_popup_create, placed against its anchor as it is now. Unless SIV_POPUP_NO_GRAB was given, it takes the keyboard for the parent's last press or key, so call it while handling one. SIV_ERROR_BUSY if it is shown already or its transaction is open.", &.{.{ .name = "popup", .type = ref("siv_window"), .doc = "The popup." }}),
    call("siv_app_get_key_repeat", "The desktop's key-repeat timing, which widgets that repeat while held (spin buttons, scroll arrows) follow too: the delay before the first repeat and the interval between repeats, from the compositor once it reports them (600 and 40 ms until then).", &.{
        app_param,
        .{ .name = "delay_ms", .type = out(.u32), .doc = "Delay before the first repeat." },
        .{ .name = "interval_ms", .type = out(.u32), .doc = "Interval between repeats; 0 when held keys do not repeat." },
    }),
    call("siv_window_get_app", "The application a window belongs to.", &.{
        window_param,
        .{ .name = "app", .type = out(ref("siv_app")), .doc = "The application." },
    }),
    .{
        .name = "siv_window_root",
        .doc = "The window's root node: a stack that fills the window. Returns 0 for an invalid handle.",
        .since = v0_1,
        .params = &.{window_param},
        .ret = ref("siv_node"),
    },

    // Transactions (D4).
    call("siv_txn_begin", "Opens a transaction on a window's tree. Changes apply at once to the tree (later calls see them) but are shown only after siv_txn_commit. One transaction per window can be open (SIV_ERROR_BUSY).", &.{
        window_param,
        .{ .name = "txn", .type = out(ref("siv_txn")), .doc = "The transaction." },
    }),
    call("siv_txn_commit", "Ends the transaction. If every operation succeeded, all of them take effect in the next frame and SIV_OK is returned. If one failed, the transaction stopped there: later operations did nothing, builders returned 0, and commit discards every change and returns the first error. Either way the handle is invalid afterwards.", &.{txn_param}),
    op("siv_txn_abort", "Ends the transaction and discards every change.", &.{txn_param}),
    op("siv_txn_status", "The transaction's first error, or SIV_OK while every operation has succeeded.", &.{txn_param}),
    op("siv_txn_fail", "Records an error in the transaction as if an operation had failed, unless one already has: later operations do nothing and siv_txn_commit discards everything. Code built on siv (widgets) reports its own invalid arguments this way. Returns the transaction's status.", &.{ txn_param, .{ .name = "error", .type = ref("siv_result"), .doc = "An error result; SIV_OK is an invalid argument." } }),

    builder("siv_box", "Creates a box: children stacked vertically and stretched to its width.", &.{}),
    builder("siv_flex", "Creates a flex container.", &.{.{ .name = "desc", .type = .{ .desc = "siv_flex_desc" }, .doc = "Options; NULL for defaults." }}),
    builder("siv_grid", "Creates a grid container.", &.{.{ .name = "desc", .type = .{ .desc = "siv_grid_desc" }, .doc = "Options; NULL for defaults." }}),
    builder("siv_stack", "Creates a stack container.", &.{.{ .name = "desc", .type = .{ .desc = "siv_stack_desc" }, .doc = "Options; NULL for defaults." }}),
    builder("siv_text", "Creates a text node: a wrapped paragraph in one style (see siv_set_text_style).", &.{.{ .name = "text", .type = .string, .doc = "UTF-8, copied." }}),
    builder("siv_editor", "Creates an editor: editable text with a caret and selection (D15). Its role is text_input and it is focusable.", &.{.{ .name = "flags", .type = ref("siv_editor_flags"), .doc = "Options." }}),
    builder("siv_scroll", "Creates a scroll node: a viewport over block-flow children that scroll on the compositor thread (D8).", &.{.{ .name = "axis", .type = ref("siv_scroll_axis"), .doc = "Axes that scroll." }}),

    op("siv_move", "Moves a node and its subtree under parent, before the child before (0 for last). Returns the transaction's status.", &.{
        txn_param,
        node_param,
        .{ .name = "parent", .type = ref("siv_node"), .doc = "The new parent, a container." },
        .{ .name = "before", .type = ref("siv_node"), .doc = "A child of parent, or 0." },
    }),
    setter("siv_remove", "Removes a node and its subtree; their handles stay valid until commit.", &.{}),
    setter("siv_set_layout", "Sets a node's layout. Fields left zero take the node's default layout (siv_set_default_layout), if it has one.", &.{.{ .name = "desc", .type = .{ .desc = "siv_layout_desc" }, .doc = "The layout; NULL for defaults." }}),
    setter("siv_set_default_layout", "Sets a node's default layout: fields that the node's siv_set_layout leaves zero take their values from it (a size counts as one field, padding side by side, flags combine). Widgets, stock or not, give their padding and least sizes here, so an application's siv_set_layout on a widget positions and sizes it without undoing them.", &.{.{ .name = "desc", .type = .{ .desc = "siv_layout_desc" }, .doc = "The defaults; NULL for none." }}),
    setter("siv_set_visual", "Sets a node's appearance.", &.{.{ .name = "desc", .type = .{ .desc = "siv_visual_desc" }, .doc = "The appearance; NULL for defaults." }}),
    setter("siv_set_opacity", "Sets a node's opacity. Below 1 the node gets its own layer, and changes only update it (D8).", &.{.{ .name = "opacity", .type = .f32, .doc = "From 0 (invisible) to 1." }}),
    setter("siv_set_transform", "Sets a node's transform. A non-identity transform gives the node its own layer.", &.{.{ .name = "transform", .type = ref("siv_transform"), .doc = "The transform." }}),
    setter("siv_set_semantics", "Sets a node's semantics.", &.{.{ .name = "desc", .type = .{ .desc = "siv_semantics_desc" }, .doc = "The semantics; NULL for defaults." }}),
    setter("siv_set_text", "Sets the text of a text or editor node. An editor keeps its selection where it still fits.", &.{.{ .name = "text", .type = .string, .doc = "UTF-8, copied." }}),
    setter("siv_set_text_style", "Sets the style of a text or editor node.", &.{.{ .name = "desc", .type = .{ .desc = "siv_text_style_desc" }, .doc = "The style; NULL for defaults." }}),
    setter("siv_set_flex", "Sets a flex container's options.", &.{.{ .name = "desc", .type = .{ .desc = "siv_flex_desc" }, .doc = "Options; NULL for defaults." }}),
    setter("siv_set_grid", "Sets a grid container's tracks and options.", &.{.{ .name = "desc", .type = .{ .desc = "siv_grid_desc" }, .doc = "Options; NULL for defaults." }}),
    setter("siv_set_stack", "Sets a stack container's options.", &.{.{ .name = "desc", .type = .{ .desc = "siv_stack_desc" }, .doc = "Options; NULL for defaults." }}),
    setter("siv_set_scroll_axis", "Sets the axes a scroll node scrolls.", &.{.{ .name = "axis", .type = ref("siv_scroll_axis"), .doc = "Axes." }}),
    setter("siv_scroll_to", "Scrolls a scroll node to an offset from the start (logical: in right-to-left layouts x grows leftward), clamped to the content.", &.{
        .{ .name = "x", .type = .f32, .doc = "Horizontal offset." },
        .{ .name = "y", .type = .f32, .doc = "Vertical offset." },
    }),
    setter("siv_set_editor_flags", "Sets an editor's options.", &.{.{ .name = "flags", .type = ref("siv_editor_flags"), .doc = "Options." }}),
    setter("siv_set_selection", "Moves an editor's caret and selection anchor (byte offsets, moved back to character boundaries and clamped to the text).", &.{
        .{ .name = "caret", .type = .u32, .doc = "Caret offset." },
        .{ .name = "anchor", .type = .u32, .doc = "Anchor offset; equal to caret for no selection." },
    }),
    setter("siv_set_transition", "Makes later changes of the node's opacity and transform animate on the compositor (D8) for duration_ms with an ease-out curve, instead of jumping; reduced motion turns it off (D29). The node needs its own layer for them to apply: give it SIV_VISUAL_LAYER.", &.{.{ .name = "duration_ms", .type = .u32, .doc = "Duration; 0 turns transitions off." }}),
    setter("siv_set_animation", "Runs an animation of one property of the node on the compositor (D8), which gives the node its own layer: repeating ones, such as an indeterminate progress bar, cost the application's thread nothing per frame. It runs while the node is shown and motion is not reduced (D29); otherwise, and once stopped, the node shows its own value. Hiding the node stops it and showing it starts it over, as do changes of the node's size (for relative translations), own opacity or transform, or the animation. A finite animation holds its last value until one of those changes.", &.{.{ .name = "desc", .type = .{ .desc = "siv_animation_desc" }, .doc = "The animation; NULL stops it." }}),
    setter("siv_set_placeholder", "Sets the text an editor shows, in the theme's muted color, while it is empty. Exposed to assistive technology as the placeholder.", &.{.{ .name = "text", .type = .string, .doc = "UTF-8 without line breaks, copied." }}),
    setter("siv_on_default", "Sets, or with a NULL callback clears, the node's default handler for one event type: it runs when the node has no siv_on handler for the type or that handler returns false, before siv's own default action, and returns true to stop both bubbling and that action. Widgets, stock or not, put their behavior here, so siv_on stays the application's and returning true from it overrides the widget. Destroy-notify rules as for siv_on.", &.{
        .{ .name = "type", .type = ref("siv_event_type"), .doc = "The event type." },
        .{ .name = "callback", .type = ref("siv_event_fn"), .doc = "The handler, or NULL." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data; may be NULL." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to callback and destroy." },
    }),
    setter("siv_set_data", "Gives the node size bytes of zeroed memory under key, allocated with the application's allocator and 16-byte aligned, for widget state. The node owns it: it is freed when the node is destroyed, or when the transaction that made it aborts. If the node already has data under key of the same size, that memory is returned; of another size, it is replaced by memory of the new size that keeps the bytes that fit (the old memory is freed at commit, or kept if the transaction aborts).", &.{
        .{ .name = "key", .type = .pointer, .doc = "Any unique address, such as that of a static variable of the caller's." },
        .{ .name = "size", .type = .usize, .doc = "Bytes; at least 1." },
        .{ .name = "data", .type = out(.pointer), .doc = "The memory." },
    }),
    setter("siv_on", "Sets, or with a NULL callback clears, the node's handler for one event type. The replaced handler's destroy-notify runs at commit; the new one's when it is replaced, its node is removed, the transaction is aborted, or the window or application is destroyed. If the call fails, or callback is NULL, destroy runs at once.", &.{
        .{ .name = "type", .type = ref("siv_event_type"), .doc = "The event type." },
        .{ .name = "callback", .type = ref("siv_event_fn"), .doc = "The handler, or NULL." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data; may be NULL." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to callback and destroy." },
    }),

    // Node queries, outside transactions.
    call("siv_node_get_text", "Copies the text of a text or editor node, as of the latest operation.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "A text or editor node." },
        .{ .name = "text", .type = .buffer, .doc = "Receives at most text_cap bytes; may be NULL with text_cap 0." },
        .{ .name = "len", .type = out(.usize), .doc = "The text's full length in bytes." },
    }),
    call("siv_node_get_selection", "An editor's caret and selection anchor (byte offsets).", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "An editor node." },
        .{ .name = "caret", .type = out(.u32), .doc = "Caret offset." },
        .{ .name = "anchor", .type = out(.u32), .doc = "Anchor offset." },
    }),
    call("siv_node_get_rect", "A node's border box in window coordinates, as of the last frame.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node." },
        .{ .name = "rect", .type = out(ref("siv_rect")), .doc = "The box." },
    }),
    call("siv_node_focus", "Moves keyboard focus to a node that can take it (SIV_SEMANTICS_FOCUSABLE, or an editor). Its focus handler runs before this returns.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node." },
    }),
    call("siv_node_get_data", "The memory siv_set_data gave the node under key, or NULL.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node." },
        .{ .name = "key", .type = .pointer, .doc = "The key." },
        .{ .name = "data", .type = out(.pointer), .doc = "The memory, or NULL." },
    }),
    call("siv_node_get_label", "Copies the node's accessible label as siv_set_semantics set it (empty when derived from content).", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node." },
        .{ .name = "label", .type = .buffer, .doc = "Receives at most label_cap bytes; may be NULL with label_cap 0." },
        .{ .name = "len", .type = out(.usize), .doc = "The label's full length in bytes." },
    }),
    call("siv_node_get_window", "The window a node belongs to.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node." },
        .{ .name = "window", .type = out(ref("siv_window")), .doc = "Its window." },
    }),
    call("siv_node_get_related", "A node's parent, first or last child, or next or previous sibling, as of the latest operation (inside an open transaction too), or 0 when there is none.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node." },
        .{ .name = "relation", .type = ref("siv_relation"), .doc = "Which neighbor." },
        .{ .name = "related", .type = out(ref("siv_node")), .doc = "The neighbor, or 0." },
    }),
    call("siv_node_is_rtl", "Whether the node lays out right to left (D21): the nearest direction set on it or an ancestor, else the window's, as of the latest operation.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node." },
        .{ .name = "rtl", .type = out(.bool), .doc = "Right to left." },
    }),
    call("siv_emit", "Sends an event to a node's handlers as siv sends input: the siv_on handler, then, unless it returned true, the siv_on_default handler. It does not bubble. This is how widgets report their own events (change, select). Not from a canvas callback (SIV_ERROR_BUSY).", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node." },
        .{ .name = "event", .type = .{ .desc = "siv_event" }, .doc = "The event; window is filled in." },
        .{ .name = "handled", .type = out(.bool), .doc = "Whether a handler returned true." },
    }),
    // Theming (D29).
    call("siv_app_set_theme", "Chooses the theme's scheme and contrast instead of following the desktop. Every window repaints if its colors change.", &.{
        app_param,
        .{ .name = "desc", .type = .{ .desc = "siv_theme_desc" }, .doc = "Choices; NULL follows the desktop." },
    }),
    call("siv_app_set_theme_color", "Overrides a themed color in one variant, or in all of them. Overriding accent also moves the colors derived from it (accent_hover, accent_active, accent_fg, focus_ring, selection), unless they are overridden too. A color of all zeros removes the override.", &.{
        app_param,
        .{ .name = "variant", .type = ref("siv_theme_variant"), .doc = "The variant." },
        .{ .name = "token", .type = ref("siv_color_token"), .doc = "The color; not none." },
        .{ .name = "color", .type = ref("siv_color"), .doc = "sRGB with straight alpha." },
    }),
    call("siv_window_get_color", "A themed color as the window resolves it now, for canvases; they are drawn again when the theme changes.", &.{
        window_param,
        .{ .name = "token", .type = ref("siv_color_token"), .doc = "The color; not none." },
        .{ .name = "color", .type = out(ref("siv_color")), .doc = "sRGB with straight alpha." },
    }),
    call("siv_timer_start", "Runs callback(user_data) once, at a safe point on the application's thread (D5) at least delay_ms from now, then destroy(user_data).", &.{
        app_param,
        .{ .name = "delay_ms", .type = .u32, .doc = "Delay." },
        .{ .name = "callback", .type = ref("siv_post_fn"), .doc = "The work." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data; may be NULL." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to both." },
        .{ .name = "timer", .type = out(ref("siv_timer")), .doc = "The timer." },
    }),
    op("siv_timer_cancel", "Cancels a timer that has not fired; its destroy-notify runs.", &.{.{ .name = "timer", .type = ref("siv_timer"), .doc = "The timer." }}),
    // Stock widgets (D22).
    builder("siv_push_button", "Creates a push button: siv_on SIV_EVENT_ACTIVATE runs when it is clicked or activated by Enter, Space, or assistive technology. Its role is button.", &.{.{ .name = "desc", .type = .{ .desc = "siv_button_desc" }, .doc = "Label and style; NULL for an empty default button." }}),
    builder("siv_toggle_button", "Creates a button that stays pressed: activating it flips its value (0 or 1) and reports SIV_EVENT_CHANGE. Its role is toggle_button.", &.{.{ .name = "desc", .type = .{ .desc = "siv_toggle_desc" }, .doc = "Label and state; NULL for defaults." }}),
    builder("siv_check_box", "Creates a check box with its label: activating it flips its value (0 or 1; 0.5 is mixed) and reports SIV_EVENT_CHANGE. Its role is checkbox.", &.{.{ .name = "desc", .type = .{ .desc = "siv_toggle_desc" }, .doc = "Label and state; NULL for defaults." }}),
    builder("siv_switch", "Creates a switch with its label: activating it flips its value (0 or 1) and reports SIV_EVENT_CHANGE. Its role is switch; the knob slides unless motion is reduced.", &.{.{ .name = "desc", .type = .{ .desc = "siv_toggle_desc" }, .doc = "Label and state; NULL for defaults." }}),
    builder("siv_radio_group", "Creates a radio group; add options with siv_radio. Its value is the selected option's index (-1 for none); choosing one reports SIV_EVENT_CHANGE with value and index on the group. Arrow keys move the selection; only the selected radio is in the Tab order. Its role is group.", &.{.{ .name = "desc", .type = .{ .desc = "siv_radio_group_desc" }, .doc = "Options; NULL for defaults." }}),
    .{
        .name = "siv_radio",
        .doc = "Appends an option to a radio group and returns it, or 0 if the transaction has failed. Its role is radio.",
        .since = v0_1,
        .params = &.{ txn_param, .{ .name = "group", .type = ref("siv_node"), .doc = "A radio group." }, .{ .name = "label", .type = .string, .doc = "The option's label, copied." } },
        .ret = ref("siv_node"),
    },
    builder("siv_text_field", "Creates a framed editor and returns the editor itself, so editor functions and SIV_EVENT_CHANGE apply. Its role is text_input.", &.{.{ .name = "desc", .type = .{ .desc = "siv_text_field_desc" }, .doc = "Text and options; NULL for an empty field." }}),
    builder("siv_slider", "Creates a horizontal slider: dragging, arrow, Page, Home, and End keys, and assistive technology change its value and report SIV_EVENT_CHANGE. Its role is slider.", &.{.{ .name = "desc", .type = .{ .desc = "siv_range_desc" }, .doc = "Range and value; NULL for 0 to 100." }}),
    builder("siv_spin_button", "Creates a spin button: a number field with decrement and increment buttons. Up and Down step, Page Up and Page Down page, typing a number and pressing Enter or leaving the field sets it; each change reports SIV_EVENT_CHANGE. Its field has the role spin_button.", &.{.{ .name = "desc", .type = .{ .desc = "siv_range_desc" }, .doc = "Range and value; NULL for 0 to 100." }}),
    builder("siv_progress_bar", "Creates a progress bar. Its role is progress_bar.", &.{.{ .name = "desc", .type = .{ .desc = "siv_range_desc" }, .doc = "Range and value; NULL for 0 to 100." }}),
    builder("siv_menu", "Creates a menu: a node that takes no space and holds the items added with siv_menu_item. siv_menu_open shows them in a popup; choosing one reports SIV_EVENT_SELECT with its index on the menu.", &.{.{ .name = "desc", .type = .{ .desc = "siv_menu_desc" }, .doc = "Options; NULL for defaults." }}),
    builder("siv_menu_button", "Creates a button that opens its menu (SIV_WIDGET_PART_MENU) below it. Add items with siv_menu_item on the button; choosing one reports SIV_EVENT_SELECT with its index on the button. Its role is button, expanded while the menu is open.", &.{.{ .name = "desc", .type = .{ .desc = "siv_button_desc" }, .doc = "Label and style; NULL for defaults." }}),
    .{
        .name = "siv_menu_item",
        .doc = "Appends an item to a menu or menu button and returns it, or 0 if the transaction has failed. siv_widget_set_label, siv_widget_set_disabled, and (for checkable items) siv_widget_set_value apply to it; siv_remove removes it.",
        .since = v0_1,
        .params = &.{ txn_param, .{ .name = "menu", .type = ref("siv_node"), .doc = "A menu or menu button." }, .{ .name = "desc", .type = .{ .desc = "siv_menu_item_desc" }, .doc = "The item." } },
        .ret = ref("siv_node"),
    },
    call("siv_menu_open", "Shows a menu in a popup below anchor, focused on its first enabled item. Up and Down move, Enter and Space choose, Escape and clicks outside close. Call it while handling the press or key that opens it; outside a transaction.", &.{
        .{ .name = "menu", .type = ref("siv_node"), .doc = "A menu or menu button." },
        .{ .name = "anchor", .type = ref("siv_node"), .doc = "The node to place it against; 0 is the menu's parent." },
    }),
    call("siv_popover_create", "Creates a popover against anchor: a popup with a themed card whose content the application builds in a transaction on the popup, then maps with siv_popup_show. Escape and clicks outside report SIV_EVENT_CLOSE on the content node; unless a handler keeps it, the popup is destroyed.", &.{
        .{ .name = "anchor", .type = ref("siv_node"), .doc = "The node to place it against." },
        .{ .name = "desc", .type = .{ .desc = "siv_popover_desc" }, .doc = "Options; NULL for defaults." },
        .{ .name = "popup", .type = out(ref("siv_window")), .doc = "The popup window." },
        .{ .name = "content", .type = out(ref("siv_node")), .doc = "The container for the content." },
    }),
    builder("siv_dialog", "Creates a modal dialog over parent: a scrim and a card with the title, the text, a content part, and an actions part (siv_widget_get_part). Input and Tab stay inside it and focus moves to it. Escape and clicks on the scrim report SIV_EVENT_CLOSE on the dialog; unless a handler keeps it, it is removed. Its role is dialog.", &.{.{ .name = "desc", .type = .{ .desc = "siv_dialog_desc" }, .doc = "Title and text." }}),
    builder("siv_tabs", "Creates tabs: a tab list over panels, added with siv_tab. The value is the selected tab's index; choosing one (click, arrow keys, Home, End) shows its panel and reports SIV_EVENT_CHANGE with value and index. Only the selected tab is in the Tab order.", &.{.{ .name = "desc", .type = .{ .desc = "siv_tabs_desc" }, .doc = "Options; NULL for defaults." }}),
    .{
        .name = "siv_tab",
        .doc = "Appends a tab and returns its panel, a box for its content, or 0 if the transaction has failed. The first tab starts selected.",
        .since = v0_1,
        .params = &.{ txn_param, .{ .name = "tabs", .type = ref("siv_node"), .doc = "Tabs." }, .{ .name = "label", .type = .string, .doc = "The tab's label, copied." } },
        .ret = ref("siv_node"),
    },
    builder("siv_split_pane", "Creates a split pane: start and end panes (siv_widget_get_part) with a divider between them. Dragging the divider or pressing arrow keys, Home, or End on it moves it; the value is the start pane's size, reported with SIV_EVENT_CHANGE. The divider's role is separator with that value.", &.{.{ .name = "desc", .type = .{ .desc = "siv_split_desc" }, .doc = "Axis and position; NULL for side by side at 200." }}),
    builder("siv_toast", "Shows a toast: a brief message in the inverse colors at the bottom of parent, announced to assistive technology. When it times out it reports SIV_EVENT_CLOSE; unless a handler keeps it, it fades out and is removed.", &.{.{ .name = "desc", .type = .{ .desc = "siv_toast_desc" }, .doc = "The message." }}),
    call("siv_widget_get_part", "A part of a stock widget, such as a dialog's content or a split pane's panes, as of the latest operation.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The widget." },
        .{ .name = "part", .type = ref("siv_widget_part"), .doc = "Which part." },
        .{ .name = "index", .type = .u32, .doc = "Tabs and panels: which one." },
        .{ .name = "result", .type = out(ref("siv_node")), .doc = "The part." },
    }),
    builder("siv_list_view", "Creates a virtualized list: a vertical scroll of rows of item_height, bound as they come into view, so a list of millions costs what is on screen. The cursor moves with Up, Down, Page Up, Page Down, Home, and End and keeps its row in view and focused; Space and clicks select (with Ctrl and Shift in multiple mode), reporting SIV_EVENT_SELECT with the cursor's index and the number selected; Enter reports SIV_EVENT_ACTIVATE with the index. Its role is list, its rows' list_item. siv_widget_get_value is the cursor's index, -1 for none.", &.{.{ .name = "desc", .type = .{ .desc = "siv_view_desc" }, .doc = "Items, callbacks, and selection." }}),
    builder("siv_tree_view", "Creates a virtualized tree: rows of the visible items, indented by depth, with the children and child callbacks walked as items expand. Keys as in a list, and Right (Left in RTL) expands an item or moves to its first child, Left collapses it or moves to its parent; clicking the disclosure toggles it. Its role is tree, its rows' tree_item with level and expanded state.", &.{.{ .name = "desc", .type = .{ .desc = "siv_view_desc" }, .doc = "Callbacks and selection." }}),
    builder("siv_table_view", "Creates a virtualized table: a header of columns (siv_table_column) over rows like a list's, each a grid with the columns' tracks that bind fills with one cell per column. Its role is table, its rows' row, header cells column_header.", &.{.{ .name = "desc", .type = .{ .desc = "siv_view_desc" }, .doc = "Items, callbacks, and selection." }}),
    builder("siv_grid_view", "Creates a virtualized grid of item_width by item_height cells, as many per row as fit, in reading order (mirrored in RTL). Arrow keys move in two dimensions. Its role is list.", &.{.{ .name = "desc", .type = .{ .desc = "siv_view_desc" }, .doc = "Items, callbacks, and selection." }}),
    .{
        .name = "siv_table_column",
        .doc = "Appends a column to a table view and returns its header cell, or 0 if the transaction has failed. Add columns before the rows are bound.",
        .since = v0_1,
        .params = &.{ txn_param, .{ .name = "table", .type = ref("siv_node"), .doc = "A table view." }, .{ .name = "desc", .type = .{ .desc = "siv_column_desc" }, .doc = "The column." } },
        .ret = ref("siv_node"),
    },
    setter("siv_view_set_count", "Sets the number of items of a list, table, or grid view; for a tree, reads the top level again. Rows in view are bound again; selection past the end is dropped.", &.{.{ .name = "count", .type = .u32, .doc = "Items." }}),
    setter("siv_view_refresh", "Binds the rows in view again, after their items changed.", &.{}),
    setter("siv_view_set_selected", "Selects or deselects the item at a row index, without reporting it. In single mode, selecting one deselects the rest and moves the cursor to it.", &.{
        .{ .name = "index", .type = .u32, .doc = "The row index." },
        .{ .name = "selected", .type = .bool, .doc = "Selected." },
    }),
    setter("siv_view_set_expanded", "Expands or collapses the tree item at a row index.", &.{
        .{ .name = "index", .type = .u32, .doc = "The row index." },
        .{ .name = "expanded", .type = .bool, .doc = "Expanded." },
    }),
    setter("siv_view_scroll_to", "Scrolls a view so that the row at index is in view.", &.{.{ .name = "index", .type = .u32, .doc = "The row index." }}),
    call("siv_view_is_selected", "Whether the item at a row index is selected.", &.{
        .{ .name = "view", .type = ref("siv_node"), .doc = "A view." },
        .{ .name = "index", .type = .u32, .doc = "The row index." },
        .{ .name = "selected", .type = out(.bool), .doc = "Selected." },
    }),
    call("siv_view_get_item", "The item at a row index: its index, or for trees its id.", &.{
        .{ .name = "view", .type = ref("siv_node"), .doc = "A view." },
        .{ .name = "index", .type = .u32, .doc = "The row index." },
        .{ .name = "item", .type = out(.u64), .doc = "The item." },
    }),
    setter("siv_widget_set_label", "Sets a stock widget's label: the text of buttons, toggles, check boxes, switches, and radios, and the accessible name of the others.", &.{.{ .name = "label", .type = .string, .doc = "Copied." }}),
    setter("siv_widget_set_disabled", "Enables or disables a stock widget: disabled widgets are dimmed, leave the Tab order, and ignore input.", &.{.{ .name = "disabled", .type = .bool, .doc = "Disabled." }}),
    setter("siv_widget_set_value", "Sets a stock widget's value without reporting SIV_EVENT_CHANGE: 0 or 1 for toggles (0.5 is a check box's mixed state), the selected index for choices (-1 for none), the number for ranges (clamped and stepped).", &.{.{ .name = "value", .type = .f64, .doc = "The value." }}),
    setter("siv_widget_set_range", "Sets the range of a slider, spin button, or progress bar; the value is clamped into it. With min equal to max the range is 0 to 100.", &.{
        .{ .name = "min", .type = .f64, .doc = "Smallest value." },
        .{ .name = "max", .type = .f64, .doc = "Largest value." },
        .{ .name = "step", .type = .f64, .doc = "Step, as in siv_range_desc." },
    }),
    call("siv_widget_get_value", "A stock widget's value, as siv_widget_set_value takes it.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "A stock widget's root (for text fields: the field)." },
        .{ .name = "value", .type = out(.f64), .doc = "The value." },
    }),
    // Canvases (D28).
    builder("siv_canvas", "Creates a canvas: content the application draws (siv_draw_fn) in its own compositor layer, so redrawing it repaints nothing else.", &.{.{ .name = "desc", .type = .{ .desc = "siv_canvas_desc" }, .doc = "Callbacks and size; NULL for an empty canvas." }}),
    builder("siv_image_view", "Creates an image node: an image fitted into its content box. Its intrinsic size is the image's size in pixels; its role is image.", &.{.{ .name = "desc", .type = .{ .desc = "siv_image_view_desc" }, .doc = "The image and fit; NULL shows nothing." }}),
    setter("siv_set_image_view", "Sets what an image node shows.", &.{.{ .name = "desc", .type = .{ .desc = "siv_image_view_desc" }, .doc = "The image and fit; NULL shows nothing." }}),
    setter("siv_set_canvas", "Replaces a canvas's callbacks and intrinsic size; it is measured and drawn again. The old destroy-notify runs at commit.", &.{.{ .name = "desc", .type = .{ .desc = "siv_canvas_desc" }, .doc = "Callbacks and size; NULL for none." }}),
    setter("siv_invalidate", "Draws a canvas again at the next frame. Only the canvas's layer is repainted and damaged.", &.{}),
    setter("siv_invalidate_size", "Measures a canvas again (its size depends on content that changed), lays out what depends on it, and draws it again.", &.{}),
    call("siv_image_create", "Copies pixels into an image for siv_draw_image.", &.{
        app_param,
        .{ .name = "desc", .type = .{ .desc = "siv_image_desc" }, .doc = "The pixels." },
        .{ .name = "image", .type = out(ref("siv_image")), .doc = "The new image." },
    }),
    op("siv_image_destroy", "Releases the application's reference to an image. Image nodes that show it, and every display list that drew it (from a node or siv_draw_image), hold references of their own until the compositor releases the list, so this affects only future draws: frames already drawn keep showing it. Canvases draw images by handle, so keep the handle while a canvas may draw it.", &.{.{ .name = "image", .type = ref("siv_image"), .doc = "The image." }}),
    call("siv_app_measure_text", "Lays out text as siv_draw_text would and reports its size. Fonts still loading count as missing (their glyphs come from fallback fonts); once they load, canvases that drew with them are drawn again.", &.{
        app_param,
        .{ .name = "text", .type = .string, .doc = "UTF-8." },
        .{ .name = "max_width", .type = .f32, .doc = "Width to wrap at; 0 for none." },
        .{ .name = "style", .type = .{ .desc = "siv_text_style_desc" }, .doc = "Style; NULL for defaults." },
        .{ .name = "metrics", .type = out(ref("siv_text_metrics")), .doc = "The size." },
    }),

    // Pointer cursors (D16).
    setter("siv_set_cursor", "Sets the pointer cursor over a node and its descendants that set none. While a press is held the cursor stays that of the node that got it.", &.{.{ .name = "cursor", .type = ref("siv_cursor"), .doc = "The cursor; auto inherits." }}),
    op("siv_window_set_cursor", "Shows a cursor over the whole window whatever its nodes set, such as SIV_CURSOR_PROGRESS while the application is busy; auto stops.", &.{
        window_param,
        .{ .name = "cursor", .type = ref("siv_cursor"), .doc = "The cursor." },
    }),
    call("siv_window_begin_move", "Starts moving the window interactively, for client-side decorations: call from a pointer down handler, while the press is held.", &.{window_param}),
    call("siv_window_begin_resize", "Starts resizing the window interactively from an edge, like siv_window_begin_move. Show the matching resize cursor on the edge's node (siv_set_cursor).", &.{
        window_param,
        .{ .name = "edge", .type = ref("siv_window_edge"), .doc = "The edge or corner; not none." },
    }),

    // Drag and drop (D19).
    setter("siv_set_drop_target", "Makes a node a drop target: drags carrying one of its MIME types with one of its actions go to its SIV_EVENT_DROP handler, from the topmost node under the pointer up to the nearest such target. Editors take text without one.", &.{.{ .name = "desc", .type = .{ .desc = "siv_drop_target_desc" }, .doc = "What it takes; NULL makes it no drop target." }}),
    call("siv_drag_start", "Starts a drag from a node while a button or touch press on its window is held, typically from a pointer move handler once the pointer moved far enough. The node gets SIV_EVENT_DRAG events as the drag goes; the node that had the press gets a pointer cancel before this returns. SIV_ERROR_UNAVAILABLE without a press held.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node the drag starts from." },
        .{ .name = "desc", .type = .{ .desc = "siv_drag_desc" }, .doc = "The data and options." },
    }),
    op("siv_drop_finish", "Ends a drop whose action was ask, once the user chose: copy or move, or none to refuse it. Does nothing if no such drop waits; a new drag over the window refuses a drop still waiting.", &.{
        window_param,
        .{ .name = "action", .type = ref("siv_drag_action"), .doc = "The action performed." },
    }),
    op("siv_app_set_transfer_limit", "Sets the largest paste or drop accepted, in bytes (16 MiB by default); larger transfers are dropped.", &.{
        app_param,
        .{ .name = "bytes", .type = .usize, .doc = "The limit." },
    }),

    drawOp("siv_draw_status", "The drawing's first error, or SIV_OK. After an error every drawing call does nothing and the canvas shows nothing this frame.", &.{}),
    drawOp("siv_draw_move_to", "Starts a new subpath of the current path at (x, y).", &.{ param("x", .f32, "X."), param("y", .f32, "Y.") }),
    drawOp("siv_draw_line_to", "Adds a line to (x, y).", &.{ param("x", .f32, "X."), param("y", .f32, "Y.") }),
    drawOp("siv_draw_quad_to", "Adds a quadratic Bézier curve through control point (cx, cy) to (x, y).", &.{ param("cx", .f32, "Control x."), param("cy", .f32, "Control y."), param("x", .f32, "X."), param("y", .f32, "Y.") }),
    drawOp("siv_draw_cubic_to", "Adds a cubic Bézier curve to (x, y).", &.{ param("c1x", .f32, "First control x."), param("c1y", .f32, "First control y."), param("c2x", .f32, "Second control x."), param("c2y", .f32, "Second control y."), param("x", .f32, "X."), param("y", .f32, "Y.") }),
    drawOp("siv_draw_arc", "Adds a circular arc around (cx, cy), clockwise on screen from start_angle to end_angle (counterclockwise if end_angle is smaller), joined to the current point by a line.", &.{ param("cx", .f32, "Center x."), param("cy", .f32, "Center y."), param("radius", .f32, "Radius."), param("start_angle", .f32, "Start, in radians from +x."), param("end_angle", .f32, "End, in radians from +x.") }),
    drawOp("siv_draw_close", "Closes the current subpath.", &.{}),
    drawOp("siv_draw_rect", "Adds a rectangle as a closed subpath.", &.{param("rect", ref("siv_rect"), "The rectangle.")}),
    drawOp("siv_draw_rounded_rect", "Adds a rounded rectangle as a closed subpath.", &.{ param("rect", ref("siv_rect"), "The rectangle."), param("radii", ref("siv_radii"), "Corner radii.") }),
    drawOp("siv_draw_ellipse", "Adds the ellipse inscribed in a rectangle as a closed subpath.", &.{param("rect", ref("siv_rect"), "The bounding rectangle.")}),
    drawOp("siv_draw_fill", "Fills the current path.", &.{ .{ .name = "paint", .type = .{ .desc = "siv_paint_desc" }, .doc = "Paint; NULL for black." }, param("flags", ref("siv_fill_flags"), "Options.") }),
    drawOp("siv_draw_stroke", "Strokes the current path.", &.{ .{ .name = "stroke", .type = .{ .desc = "siv_stroke_desc" }, .doc = "Stroke; NULL for 1 px solid." }, .{ .name = "paint", .type = .{ .desc = "siv_paint_desc" }, .doc = "Paint; NULL for black." } }),
    drawOp("siv_draw_image", "Draws part of an image into a rectangle. The canvas's display list holds a reference to the image until the compositor releases it, so destroying the image's handle later does not affect what is on screen.", &.{
        param("image", ref("siv_image"), "The image."),
        param("dst", ref("siv_rect"), "Where it goes."),
        param("src", ref("siv_rect"), "The part to draw, in image pixels; all zero is the whole image."),
        param("opacity", .f32, "From 0 to 1."),
        param("flags", ref("siv_image_flags"), "Options (nearest)."),
    }),
    drawOp("siv_draw_text", "Draws text with its layout box's top left at (x, y): shaped, bidi-ordered, with font fallback, one paragraph per line break (D13).", &.{
        param("x", .f32, "Left edge of the layout box."),
        param("y", .f32, "Top edge of the layout box."),
        param("width", .f32, "Width to wrap and align in; 0 for none."),
        .{ .name = "text", .type = .string, .doc = "UTF-8." },
        .{ .name = "style", .type = .{ .desc = "siv_text_style_desc" }, .doc = "Style; NULL for defaults." },
    }),
    drawOp("siv_draw_backdrop_blur", "Blurs what was drawn before under the current path, like CSS backdrop-filter (D9).", &.{ param("sigma", .f32, "Standard deviation, up to 64."), param("flags", ref("siv_fill_flags"), "Options (keep_path).") }),
    drawOp("siv_draw_push_transform", "Opens a layer whose content is transformed. Close it with siv_draw_pop.", &.{param("transform", ref("siv_affine"), "Maps the layer's coordinates into the enclosing ones.")}),
    drawOp("siv_draw_push_clip", "Opens a layer clipped to the current path.", &.{param("flags", ref("siv_fill_flags"), "Options.")}),
    drawOp("siv_draw_push_opacity", "Opens a layer composited with an opacity, as a group.", &.{param("opacity", .f32, "From 0 to 1.")}),
    drawOp("siv_draw_push_blend", "Opens a layer composited with a blend mode, as an isolated group.", &.{param("mode", ref("siv_blend_mode"), "The blend mode.")}),
    drawOp("siv_draw_pop", "Closes the innermost open layer. Layers still open when the draw callback returns are closed then.", &.{}),
    // External content (D17).
    call("siv_external_create", "Creates a slot for frames the application submits (siv_external_submit), such as decoded video. The compositor promotes it to a subsurface when nothing covers it (D17). Application's thread.", &.{
        window_param,
        .{ .name = "desc", .type = .{ .desc = "siv_external_desc" }, .doc = "Callbacks; NULL for none." },
        .{ .name = "external", .type = out(ref("siv_external")), .doc = "The slot." },
    }),
    call("siv_external_create_surface", "Creates a slot backed by a wl_surface that the application renders into with its own Vulkan, EGL, GStreamer, or libmpv (D17), on a synchronized subsurface of the window. The embedder contract: render frames of the size the configure event gives; after committing each frame, call siv_external_surface_committed, and the window's next commit shows it (frame callbacks on the surface fire only then, so a swap interval of 1 waits for it); never set a viewport, buffer scale, or listener on the surface; the wl_display is siv's connection, used by siv's compositor thread, so use it only through an event queue of one's own (wl_display_create_queue, a proxy wrapper of the display, wl_display_dispatch_queue), as Mesa's EGL and Vulkan do, and never dispatch or round-trip its default queue. Application's thread.", &.{
        window_param,
        .{ .name = "desc", .type = .{ .desc = "siv_external_desc" }, .doc = "Callbacks; on_event receives configures." },
        .{ .name = "external", .type = out(ref("siv_external")), .doc = "The slot." },
    }),
    call("siv_external_get_wayland", "The wl_display * and wl_surface * of a slot made with siv_external_create_surface. Both are NULL on the headless backend. Any thread.", &.{
        .{ .name = "external", .type = ref("siv_external"), .doc = "A surface slot." },
        .{ .name = "display", .type = out(.pointer), .doc = "The wl_display *." },
        .{ .name = "surface", .type = out(.pointer), .doc = "The wl_surface *." },
    }),
    call("siv_external_submit", "Shows a new frame in a frame slot. Any thread, even while the application's thread is busy: the frame goes straight to the compositor thread, in order with other frames of the slot. The previous frame is reported released once no frame reads it; until then its pixels must not change.", &.{
        .{ .name = "external", .type = ref("siv_external"), .doc = "A frame slot." },
        .{ .name = "frame", .type = .{ .desc = "siv_external_frame_desc" }, .doc = "The frame." },
    }),
    call("siv_external_surface_committed", "Tells siv that the embedder committed a frame of width x height buffer pixels to a surface slot. Any thread, like siv_external_submit.", &.{
        .{ .name = "external", .type = ref("siv_external"), .doc = "A surface slot." },
        .{ .name = "width", .type = .u32, .doc = "Buffer width." },
        .{ .name = "height", .type = .u32, .doc = "Buffer height." },
    }),
    op("siv_external_destroy", "Destroys a slot; its frame or surface goes after the next frame. Nodes that show it show nothing. Application's thread; other threads' calls with the handle fail with SIV_ERROR_INVALID_HANDLE from now on.", &.{.{ .name = "external", .type = ref("siv_external"), .doc = "The slot." }}),
    builder("siv_external_view", "Creates an external node: a slot's content fitted into its content box, in a layer of its own. Its role is image.", &.{
        .{ .name = "external", .type = ref("siv_external"), .doc = "A slot of the same window; 0 shows nothing." },
        .{ .name = "size", .type = ref("siv_size"), .doc = "Intrinsic size: the content's size or aspect ratio; zero sizes it by layout alone." },
        .{ .name = "fit", .type = ref("siv_fit"), .doc = "How the content fits the box." },
    }),
    setter("siv_set_external_view", "Sets what an external node shows.", &.{
        .{ .name = "external", .type = ref("siv_external"), .doc = "A slot of the same window; 0 shows nothing." },
        .{ .name = "size", .type = ref("siv_size"), .doc = "Intrinsic size." },
        .{ .name = "fit", .type = ref("siv_fit"), .doc = "How the content fits the box." },
    }),
};

pub const spec: schema.Schema = .{
    .name = "siv",
    .prefix = "siv_",
    .source = "src/abi/api.zig",
    .doc = "siv: a GUI toolkit for Wayland.",
    .result = "siv_result",
    .decls = &(decls ++ desktop.decls),
    .functions = &(functions ++ desktop.functions),
};

/// Encodes a version as (major << 16) | (minor << 8) | patch.
pub fn makeVersion(major: usize, minor: usize, patch: usize) u32 {
    return @intCast(major << 16 | minor << 8 | patch);
}
