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

const toggle_values: []const schema.EnumValue = &.{
    .{ .name = "unset", .value = 0, .doc = "The state does not apply." },
    .{ .name = "off", .value = 1, .doc = "Off." },
    .{ .name = "on", .value = 2, .doc = "On." },
    .{ .name = "mixed", .value = 3, .doc = "Partly on." },
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
    }),
    descriptor("siv_app_desc", "Options for siv_app_create.", &.{
        .{ .name = "allocator", .type = .{ .desc = "siv_allocator" }, .doc = "Allocator hooks for everything the application allocates, on any thread; NULL for the C library allocator." },
        .{ .name = "display", .type = .string, .doc = "Wayland socket name or path; empty uses $WAYLAND_DISPLAY." },
        .{ .name = "backend", .type = ref("siv_backend"), .doc = "Default Wayland." },
        .{ .name = "flags", .type = ref("siv_app_flags"), .doc = "Options." },
        .{ .name = "name", .type = .string, .doc = "The application's name, as assistive technology shows it (D18)." },
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
        .{ .name = "rtl", .bit = 1, .doc = "Lay out right to left; nodes inherit the direction (D21)." },
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
        .{ .name = "language", .type = .string, .doc = "BCP 47 language of the window's text, for shaping and font fallback." },
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
    flags("siv_visual_flags", "Appearance options.", &.{
        .{ .name = "clip", .bit = 0, .doc = "Clip descendants to the rounded border box." },
        .{ .name = "layer", .bit = 1, .doc = "Give the node its own compositor layer (D8), for example before animating it." },
        .{ .name = "no_hit_test", .bit = 2, .doc = "Pointer events pass through the node to what is below." },
    }),
    descriptor("siv_visual_desc", "A node's appearance. Repaints without layout; does not change opacity or transform.", &.{
        .{ .name = "background", .type = ref("siv_color"), .doc = "Fill of the border box; default transparent." },
        .{ .name = "border_color", .type = ref("siv_color"), .doc = "Border color." },
        .{ .name = "radius", .type = ref("siv_corners"), .doc = "Corner radii." },
        f32Field("border_width", "Border width, drawn over the padding."),
        .{ .name = "flags", .type = ref("siv_visual_flags"), .doc = "Options." },
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

    enumeration("siv_role", "Accessibility roles (D18).", &role_values),
    enumeration("siv_toggle", "A tri-state semantic property.", toggle_values),
    flags("siv_semantics_flags", "Semantic options.", &.{
        .{ .name = "focusable", .bit = 0, .doc = "Takes keyboard focus; Tab order is tree order." },
        .{ .name = "disabled", .bit = 1, .doc = "Neither focusable nor activatable." },
        .{ .name = "has_value", .bit = 2, .doc = "value_min, value_max, and value_now apply (sliders, progress)." },
        .{ .name = "live_polite", .bit = 3, .doc = "A live region: changes are announced when the user is idle." },
        .{ .name = "live_assertive", .bit = 4, .doc = "A live region: changes are announced at once. Not with SIV_SEMANTICS_LIVE_POLITE." },
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
    }),
    flags("siv_editor_flags", "Editor options.", &.{
        .{ .name = "multiline", .bit = 0, .doc = "Enter inserts a line break and lines wrap; otherwise one line that scrolls to keep the caret visible." },
        .{ .name = "masked", .bit = 1, .doc = "A password field (D15): the text lives in locked memory excluded from core dumps, shows one bullet per character, has no undo or input method, and is hidden from assistive technology. Offsets still index the real text." },
    }),

    // Events.
    enumeration("siv_event_type", "Kinds of node events, and the kind a siv_on handler receives.", &.{
        .{ .name = "activate", .value = 0, .doc = "Clicked, or Enter or Space while focused. A node with an activate handler can be pressed." },
        .{ .name = "pointer", .value = 1, .doc = "Pointer motion, buttons, and hover; bubbles from the node under the pointer." },
        .{ .name = "key", .value = 2, .doc = "A key, from the focused node up." },
        .{ .name = "focus", .value = 3, .doc = "The node gained or lost keyboard focus." },
        .{ .name = "scroll", .value = 4, .doc = "Scroll input; bubbles from the node under the pointer. A node with a scroll handler sees scroll input before the compositor scrolls (D8)." },
        .{ .name = "change", .value = 5, .doc = "The user edited an editor's text; text, caret, and anchor have the new state." },
    }),
    enumeration("siv_pointer_phase", "What a pointer event reports.", &.{
        .{ .name = "down", .value = 0, .doc = "A button was pressed." },
        .{ .name = "up", .value = 1, .doc = "A button was released." },
        .{ .name = "move", .value = 2, .doc = "The pointer moved." },
        .{ .name = "enter", .value = 3, .doc = "The pointer entered the node." },
        .{ .name = "leave", .value = 4, .doc = "The pointer left the node." },
        .{ .name = "cancel", .value = 5, .doc = "The press was taken away (a touch sequence the compositor claimed)." },
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
    }),
    callback("siv_event_fn", "Handles a node event at a safe point on the application's thread (D5). Return true when handled: the event stops bubbling and the default action is skipped.", &.{
        .{ .name = "node", .type = ref("siv_node"), .doc = "The node the handler was set on." },
        .{ .name = "event", .type = .{ .desc = "siv_event" }, .doc = "The event, valid during the call." },
    }, .bool),
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
    descriptor("siv_external_frame_desc", "One frame of external content in shared memory.", &.{
        .{ .name = "key", .type = .u64, .doc = "Identifies the pixels; change it whenever they change. Released frames are reported by key." },
        .{ .name = "fd", .type = .i32, .doc = "Shared memory the compositor can map, such as a memfd. siv duplicates it; the caller keeps its own." },
        .{ .name = "offset", .type = .u32, .doc = "Byte offset of the first row." },
        .{ .name = "width", .type = .u32, .doc = "Width in pixels." },
        .{ .name = "height", .type = .u32, .doc = "Height in pixels." },
        .{ .name = "stride", .type = .u32, .doc = "Bytes per row; 0 is width * 4." },
        .{ .name = "format", .type = ref("siv_external_format"), .doc = "Default xrgb8888." },
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
    setter("siv_set_layout", "Sets a node's layout.", &.{.{ .name = "desc", .type = .{ .desc = "siv_layout_desc" }, .doc = "The layout; NULL for defaults." }}),
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
    .decls = &decls,
    .functions = &functions,
};

/// Encodes a version as (major << 16) | (minor << 8) | patch.
pub fn makeVersion(major: usize, minor: usize, patch: usize) u32 {
    return @intCast(major << 16 | minor << 8 | patch);
}
