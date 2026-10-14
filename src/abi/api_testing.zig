//! The test part of the API schema (D27): what an application's own tests
//! use to drive it on the headless backend (siv_app_desc.backend) as a user
//! would and check what it shows: input injection, waiting until it is
//! idle, window captures, and the semantics tree assistive technology
//! sees. api.zig appends these declarations and functions to its own;
//! the conventions are schema.zig's. Implemented in testing.zig.

const schema = @import("schema.zig");
const ref = schema.ref;
const out = schema.out;
const array = schema.array;
const Decl = schema.Decl;
const Param = schema.Param;
const Function = schema.Function;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

fn call(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = ref("siv_result") };
}

const headless = " Headless backend only (SIV_ERROR_UNSUPPORTED otherwise).";
const queued = " The input is queued like a compositor's; siv_test_settle delivers it.";
const window_param = p("window", ref("siv_window"), "The window, a popup, or a dialog.");
const app_param = p("app", ref("siv_app"), "The application.");

pub const decls = [_]Decl{
    .{ .flags = .{ .name = "siv_test_query_flags", .doc = "What else a semantics query matches.", .since = v0_1, .bits = &.{
        .{ .name = "focused", .bit = 0, .doc = "Only the node with keyboard focus." },
    } } },
    .{ .@"struct" = .{ .name = "siv_test_query", .doc = "Which node of a window's semantics tree siv_test_find returns: the index-th, in tree order, of those that match.", .since = v0_1, .kind = .descriptor, .fields = &.{
        .{ .name = "name", .type = .string, .doc = "The accessible name, exactly; empty matches any." },
        .{ .name = "role", .type = ref("siv_role"), .doc = "The role; SIV_ROLE_DEFAULT matches any." },
        .{ .name = "flags", .type = ref("siv_test_query_flags"), .doc = "Further conditions." },
        .{ .name = "index", .type = .u32, .doc = "Which match, from 0." },
        .{ .name = "reserved0", .type = .u32, .doc = "Reserved; must be zero (SIV_ERROR_UNSUPPORTED otherwise).", .reserved = true },
    } } },
    .{ .flags = .{ .name = "siv_test_node_flags", .doc = "States of a semantics node.", .since = v0_1, .bits = &.{
        .{ .name = "focusable", .bit = 0, .doc = "Takes keyboard focus." },
        .{ .name = "focused", .bit = 1, .doc = "Has keyboard focus." },
        .{ .name = "disabled", .bit = 2, .doc = "Disabled." },
        .{ .name = "actionable", .bit = 3, .doc = "Has an action assistive technology can invoke." },
        .{ .name = "has_value", .bit = 4, .doc = "value_min, value_max, and value_now apply." },
        .{ .name = "modal", .bit = 5, .doc = "Modal (a dialog)." },
    } } },
    .{ .@"struct" = .{ .name = "siv_test_node", .doc = "A node of a window's semantics tree as assistive technology sees it (D18).", .since = v0_1, .kind = .value, .fields = &.{
        .{ .name = "bounds", .type = ref("siv_rect"), .doc = "Where it is, in window coordinates." },
        .{ .name = "role", .type = ref("siv_role"), .doc = "Its role." },
        .{ .name = "flags", .type = ref("siv_test_node_flags"), .doc = "Its states." },
        .{ .name = "checked", .type = ref("siv_toggle"), .doc = "Checkboxes, radios, switches." },
        .{ .name = "pressed", .type = ref("siv_toggle"), .doc = "Toggle buttons." },
        .{ .name = "selected", .type = ref("siv_toggle"), .doc = "Items in a selection." },
        .{ .name = "expanded", .type = ref("siv_toggle"), .doc = "Disclosures, tree items, menus." },
        .{ .name = "value_min", .type = .f64, .doc = "Smallest value, with SIV_TEST_NODE_HAS_VALUE." },
        .{ .name = "value_max", .type = .f64, .doc = "Largest value." },
        .{ .name = "value_now", .type = .f64, .doc = "Current value." },
        .{ .name = "level", .type = .u32, .doc = "Heading level or tree item depth from 1; 0 for none." },
        .{ .name = "position", .type = .u32, .doc = "Position in its set from 1; 0 for none." },
        .{ .name = "set_size", .type = .u32, .doc = "The size of that set; 0 for none." },
        .{ .name = "row", .type = .u32, .doc = "A table row's index from 1; 0 for none." },
        .{ .name = "column", .type = .u32, .doc = "A table cell's or column header's column from 1; 0 for none." },
        .{ .name = "sort", .type = ref("siv_sort"), .doc = "A column header's sort order." },
        .{ .name = "reserved0", .type = .u32, .doc = "Reserved; zero.", .reserved = true },
        .{ .name = "reserved1", .type = .u32, .doc = "Reserved; zero.", .reserved = true },
        .{ .name = "reserved2", .type = .u32, .doc = "Reserved; zero.", .reserved = true },
        .{ .name = "reserved3", .type = .u32, .doc = "Reserved; zero.", .reserved = true },
    } } },
};

pub const functions = [_]Function{
    call("siv_test_settle", "Dispatches until the application is idle or timeout_ms pass, waiting for the events that end the work rather than for quiet time: no transaction is open; every shown window has presented what it committed and wants no frame; the compositor owes no frame (for injected input, a scroll or fling it runs itself, or a single-run animation) and has presented every frame it owed; no tooltip waits for its delay (D17); and no font, icon, image load, application job (siv_job_start), paste, or drop is in flight. Repeating animations (a caret's blink, a spinner) are not waited for, since they never end, and a capture may catch them in any phase (SIV_APP_REDUCED_MOTION stops them). Timers, portal requests, and the application's own threads are not waited for: wait for what they show. Not from a callback (SIV_ERROR_BUSY)." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("timeout_ms", .u32, "How long to wait at most."),
        p("settled", out(.bool), "Whether it settled in time."),
    }),
    call("siv_test_pointer_move", "Moves the pointer over a window to a point, entering it." ++ queued ++ headless, &.{
        window_param,
        p("x", .f32, "Window coordinates."),
        p("y", .f32, "Window coordinates."),
    }),
    call("siv_test_pointer_button", "Presses or releases a pointer button where the pointer is (siv_test_pointer_move). A press outside a grabbing popup dismisses it, as on a compositor." ++ queued ++ headless, &.{
        window_param,
        p("button", ref("siv_pointer_button"), "The button."),
        p("pressed", .bool, "Pressed rather than released."),
    }),
    call("siv_test_click", "Moves the pointer to a point and clicks a button there: siv_test_pointer_move, then a press and a release." ++ queued ++ headless, &.{
        window_param,
        p("x", .f32, "Window coordinates."),
        p("y", .f32, "Window coordinates."),
        p("button", ref("siv_pointer_button"), "The button."),
    }),
    call("siv_test_scroll", "Scrolls where the pointer is (siv_test_pointer_move) by exactly the distance given, as a mouse wheel that sends only a distance does (wheel detents and touchpads scroll by distances siv scales, D16)." ++ queued ++ headless, &.{
        window_param,
        p("dx", .f32, "Horizontal distance in logical pixels."),
        p("dy", .f32, "Vertical distance in logical pixels; positive scrolls down."),
    }),
    call("siv_test_key", "Presses and releases a key in a window." ++ queued ++ headless, &.{
        window_param,
        p("keysym", ref("siv_key"), "The XKB keysym."),
        p("modifiers", ref("siv_modifiers"), "Modifiers held."),
        p("text", .string, "The text the key produces, as a keymap would give it (\"a\" for SIV_KEY_A without Shift, \"\\r\" for Enter); empty for none. At most 32 bytes."),
    }),
    call("siv_test_type", "Types text into a window: a key press and release per character, its keysym the character's (Latin-1 as is, others 0x01000000 plus the code point), \\n as Enter and \\t as Tab." ++ queued ++ headless, &.{
        window_param,
        p("text", .string, "UTF-8 text."),
    }),
    call("siv_test_close", "Asks to close a window, as its close button does: the window gets SIV_WINDOW_EVENT_TYPE_CLOSE_REQUESTED." ++ queued ++ headless, &.{
        window_param,
    }),
    call("siv_test_resize", "The compositor resizes a window, as a user dragging its edge or a tiling layout does: the window gets SIV_WINDOW_EVENT_TYPE_RESIZED with the new size and lays out again." ++ queued ++ headless, &.{
        window_param,
        p("width", .u32, "Logical width; at least 1."),
        p("height", .u32, "Logical height; at least 1."),
    }),
    call("siv_test_drop", "Another application drags data over a window to a point and drops it there, offering copy and move: the drag enters, siv dispatches until the application answered it (so not from a callback, SIV_ERROR_BUSY), and the drop is queued for siv_test_settle to deliver." ++ headless, &.{
        window_param,
        p("x", .f32, "Window coordinates."),
        p("y", .f32, "Window coordinates."),
        p("mime_type", .string, "The data's MIME type."),
        p("data", array(.u8), "The data (copied)."),
    }),
    call("siv_test_modifiers", "Sets the keyboard modifiers held, as the compositor reports them when a modifier key goes down or up without a key event for the window: during a drag, say." ++ queued ++ headless, &.{
        window_param,
        p("modifiers", ref("siv_modifiers"), "Modifiers held."),
    }),
    call("siv_test_capture_drag_icon", "Copies the icon of the application's drag in progress, as the compositor shows it under the pointer, like siv_test_capture: rows of width * 4 bytes of 8-bit red, green, blue, and alpha, alpha premultiplied, at its buffer scale. SIV_ERROR_UNAVAILABLE without a drag with an icon." ++ headless, &.{
        app_param,
        p("pixels", schema.byte_buffer, "Receives at most pixels_cap bytes; may be NULL with pixels_cap 0 to ask for the size."),
        p("len", out(.usize), "The image's full length in bytes."),
        .{ .name = "width", .type = out(.u32), .doc = "Width in pixels.", .optional = true },
        .{ .name = "height", .type = out(.u32), .doc = "Height in pixels.", .optional = true },
    }),
    call("siv_test_capture", "Copies what a window presented last, as the compositor shows it: rows of width * 4 bytes, top to bottom, of 8-bit red, green, blue, and alpha, alpha premultiplied, at the window's buffer scale. SIV_ERROR_UNAVAILABLE if it has presented nothing yet (siv_test_settle first)." ++ headless, &.{
        window_param,
        p("pixels", schema.byte_buffer, "Receives at most pixels_cap bytes; may be NULL with pixels_cap 0 to ask for the size."),
        p("len", out(.usize), "The image's full length in bytes."),
        .{ .name = "width", .type = out(.u32), .doc = "Width in pixels.", .optional = true },
        .{ .name = "height", .type = out(.u32), .doc = "Height in pixels.", .optional = true },
    }),
    call("siv_test_capture_tooltip", "Copies what a window's tooltip (D17, siv_set_tooltip) presented last, like siv_test_capture. A tooltip shows half a second after the pointer rests on its node (siv_test_pointer_move) or keyboard focus reaches it, which siv_test_settle waits for. SIV_ERROR_UNAVAILABLE if none is shown." ++ headless, &.{
        window_param,
        p("pixels", schema.byte_buffer, "Receives at most pixels_cap bytes; may be NULL with pixels_cap 0 to ask for the size."),
        p("len", out(.usize), "The image's full length in bytes."),
        .{ .name = "width", .type = out(.u32), .doc = "Width in pixels.", .optional = true },
        .{ .name = "height", .type = out(.u32), .doc = "Height in pixels.", .optional = true },
    }),
    call("siv_test_find", "Finds a node of a window's semantics tree as assistive technology sees it after the last frame (siv_test_settle first): what it is, where, and its states.", &.{
        window_param,
        p("query", .{ .desc = "siv_test_query" }, "Which node; NULL is the first."),
        p("found", out(.bool), "Whether a node matched; node is zero otherwise."),
        .{ .name = "node", .type = out(ref("siv_test_node")), .doc = "The node.", .optional = true },
    }),
    call("siv_test_get_name", "Copies the accessible name of the node siv_test_find finds with the same query (what a screen reader reads, such as a label's text); empty when none matches.", &.{
        window_param,
        p("query", .{ .desc = "siv_test_query" }, "Which node; NULL is the first."),
        p("name", schema.text_buffer, "Receives at most name_cap bytes; may be NULL with name_cap 0."),
        p("len", out(.usize), "The name's full length in bytes."),
    }),
    call("siv_test_dump", "Copies a window's semantics tree as text, for test failures and snapshots: a line per node in tree order, indented two spaces per level, with its role, quoted name, states, and bounds.", &.{
        window_param,
        p("text", schema.text_buffer, "Receives at most text_cap bytes; may be NULL with text_cap 0."),
        p("len", out(.usize), "The text's full length in bytes."),
    }),
    // The simulated desktop shell (D31). The headless compositor offers
    // every shell protocol; these play the other clients and the user.
    call("siv_test_add_output", "Plugs in a simulated output: output events follow, and an active lock gets a lock window on it." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("name", .string, "Its connector name, such as HEADLESS-2."),
        p("pixel_width", .u32, "Its mode's width in pixels."),
        p("pixel_height", .u32, "Its mode's height in pixels."),
        p("scale", .u32, "Its integer scale; 0 is 1."),
    }),
    call("siv_test_remove_output", "Unplugs the simulated output with a name: layer and lock windows on it are closed, as on a compositor. SIV_ERROR_INVALID_ARGUMENT if there is none." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("name", .string, "Its connector name."),
    }),
    call("siv_test_add_toplevel", "Another application opens a toplevel window, which toplevel lists report (siv_toplevel_list_create). The simulated compositor applies requests to it: activating focuses it (unfocusing the others), closing removes it." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("title", .string, "Its title."),
        p("app_id", .string, "Its application id."),
        p("output", ref("siv_output"), "The output it is on; 0 for none."),
        p("id", out(.u32), "Its id for the other siv_test_*toplevel calls."),
    }),
    call("siv_test_set_toplevel", "Changes another application's toplevel: its title and states." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("id", .u32, "From siv_test_add_toplevel."),
        p("title", .string, "Its new title."),
        p("states", ref("siv_toplevel_states"), "Its new states; managed is ignored."),
    }),
    call("siv_test_remove_toplevel", "Another application closes its toplevel." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("id", .u32, "From siv_test_add_toplevel."),
    }),
    call("siv_test_add_workspace", "The compositor adds a workspace on an output, which workspace lists report (siv_workspace_list_create); the first on an output is active. It applies requests as sway does: activating one deactivates the others on its output." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("name", .string, "Its name."),
        p("output", ref("siv_output"), "Its output; 0 for none."),
        p("id", out(.u32), "Its id for siv_test_remove_workspace."),
    }),
    call("siv_test_remove_workspace", "The compositor removes a workspace." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("id", .u32, "From siv_test_add_workspace."),
    }),
    call("siv_test_set_idle", "The user stops using the seat (true), past every idle watch's timeout, or comes back (false); idle watches report it, held off by idle inhibitors unless they ignore them." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("idle", .bool, "Idle."),
    }),
    call("siv_test_set_blur", "Whether the simulated compositor blurs behind windows (SIV_CAPABILITIES_BLUR); it starts without." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("blur", .bool, "It can blur."),
    }),
    call("siv_test_get_blur_region_count", "How many rectangles make up the blur region (SIV_VISUAL_WINDOW_BLUR) the window's last commit set, in its logical coordinates; 0 without one or when the compositor cannot blur." ++ headless, &.{
        window_param,
        p("count", out(.usize), "The number of rectangles."),
    }),
    call("siv_test_get_blur_rect", "A rectangle of the blur region the window's last commit set. SIV_ERROR_INVALID_ARGUMENT past the count." ++ headless, &.{
        window_param,
        p("index", .usize, "From 0."),
        p("rect", out(ref("siv_rect")), "The rectangle."),
    }),
    call("siv_test_is_locked", "Whether the simulated session is locked, by this application or another one in the process, or left locked by a lock destroyed without unlocking." ++ headless, &.{
        p("app", ref("siv_app"), "The application."),
        p("locked", out(.bool), "Locked."),
    }),
    .{ .name = "siv_test_get_popup", .doc = "The popup shown most recently (a menu, a popover, a combo box's list) that is still shown, or 0 when none is or the handle is invalid.", .since = v0_1, .params = &.{
        p("app", ref("siv_app"), "The application."),
    }, .ret = ref("siv_window") },
};
