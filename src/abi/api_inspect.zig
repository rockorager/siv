//! The inspector part of the API schema (D46): introspection of a
//! window's tree (each node's kind, boxes, properties as text, accessible
//! name), its frame and presentation counters, the overlays and picking
//! a window shows for an inspector, and the stock inspector built on
//! them (D22). api.zig appends these declarations and functions to its
//! own; the conventions are schema.zig's. Implemented in inspect.zig and
//! src/widgets/inspector.zig.

const std = @import("std");
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

fn reserved(comptime name: []const u8) schema.Field {
    return .{ .name = name, .type = .u32, .doc = "Reserved; zero.", .reserved = true };
}

fn value(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .value, .fields = fields } };
}

fn descriptor(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .descriptor, .fields = fields } };
}

fn call(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = ref("siv_result") };
}

fn f(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) schema.Field {
    return .{ .name = name, .type = t, .doc = doc };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

const node_param = p("node", ref("siv_node"), "The node.");
const window_param = p("window", ref("siv_window"), "The window.");
const txn_param = p("txn", ref("siv_txn"), "An open transaction.");
const index_param = p("index", .u32, "Which property, from 0; SIV_ERROR_INVALID_ARGUMENT from siv_node_info.properties on.");

pub const decls = [_]Decl{
    enumeration("siv_node_kind", "Which primitive a node is (D4).", &.{
        .{ .name = "box", .value = 0, .doc = "siv_box: block flow." },
        .{ .name = "flex", .value = 1, .doc = "siv_flex." },
        .{ .name = "grid", .value = 2, .doc = "siv_grid." },
        .{ .name = "stack", .value = 3, .doc = "siv_stack, and the window's root." },
        .{ .name = "text", .value = 4, .doc = "siv_text." },
        .{ .name = "editor", .value = 5, .doc = "siv_editor." },
        .{ .name = "scroll", .value = 6, .doc = "siv_scroll." },
        .{ .name = "image", .value = 7, .doc = "siv_image_view." },
        .{ .name = "canvas", .value = 8, .doc = "siv_canvas." },
        .{ .name = "external", .value = 9, .doc = "siv_external_view." },
    }),
    flags("siv_node_info_flags", "What siv_node_get_info reports of a node's state.", &.{
        .{ .name = "hidden", .bit = 0, .doc = "Hidden itself: siv_set_hidden, its visual, or a variant." },
        .{ .name = "shown", .bit = 1, .doc = "Laid out and drawn: neither it nor an ancestor is hidden." },
        .{ .name = "focusable", .bit = 2, .doc = "Takes keyboard focus." },
        .{ .name = "focused", .bit = 3, .doc = "Has keyboard focus." },
        .{ .name = "disabled", .bit = 4, .doc = "Disabled." },
        .{ .name = "layer", .bit = 5, .doc = "Roots a compositor layer of its own (D8)." },
        .{ .name = "theme", .bit = 6, .doc = "Has a theme for its subtree (siv_set_theme, siv_set_theme_color; D43)." },
        .{ .name = "widget", .bit = 7, .doc = "Has a widget interface (siv_set_widget): a stock widget's root, or an application's widget." },
        .{ .name = "accessible", .bit = 8, .doc = "Is in the semantics tree assistive technology sees (D18), rather than left out with its children promoted." },
        .{ .name = "rtl", .bit = 9, .doc = "Lays out right to left (D21)." },
    }),
    value("siv_node_info", "What a node is and where, for inspectors (D46): siv_node_get_info.", &.{
        f("kind", ref("siv_node_kind"), "Its primitive."),
        f("role", ref("siv_role"), "Its role as assistive technology sees it: the one siv_set_semantics set, else its kind's; never default."),
        f("flags", ref("siv_node_info_flags"), "Its state."),
        f("variant", ref("siv_theme_variant"), "The theme variant its colors resolve in (D29, D43); never all."),
        f("rect", ref("siv_rect"), "Its border box in window coordinates, as of the last frame (siv_node_get_rect)."),
        f("content", ref("siv_rect"), "Its content box, the border box less its padding, in window coordinates."),
        f("children", .u32, "How many children it has, hidden ones too."),
        f("properties", .u32, "How many properties siv_node_get_property lists for it."),
        reserved("reserved0"),
        reserved("reserved1"),
        reserved("reserved2"),
        reserved("reserved3"),
    }),
    enumeration("siv_property_group", "Which part of a node a property belongs to.", &.{
        .{ .name = "layout", .value = 0, .doc = "Sizing and placement (siv_set_layout), with the properties its parent's kind reads." },
        .{ .name = "container", .value = 1, .doc = "What its kind lays out or shows: a flex's, grid's, stack's, or scroll's arrangement, an image's or canvas's content, an editor's state." },
        .{ .name = "visual", .value = 2, .doc = "Appearance (siv_set_visual), its cursor and tooltip." },
        .{ .name = "text", .value = 3, .doc = "A text or editor node's text and style (siv_set_text_style)." },
        .{ .name = "semantics", .value = 4, .doc = "What assistive technology sees (siv_set_semantics)." },
        .{ .name = "theme", .value = 5, .doc = "The theme of its subtree (siv_set_theme, D43)." },
    }),
    enumeration("siv_property_type", "How a property's value reads, so an inspector can show it.", &.{
        .{ .name = "text", .value = 0, .doc = "Free text." },
        .{ .name = "number", .value = 1, .doc = "A number, or several separated by spaces (edges: top, end, bottom, start)." },
        .{ .name = "bool", .value = 2, .doc = "true or false." },
        .{ .name = "choice", .value = 3, .doc = "One of a set of names (center, stretch)." },
        .{ .name = "length", .value = 4, .doc = "auto, a number of logical pixels, or a percentage of the space the parent offers." },
        .{ .name = "color", .value = 5, .doc = "A color: #rrggbbaa, or a theme token's name followed by the color it resolves to (\"accent #3584e4ff\"), or none." },
    }),
    flags("siv_property_flags", "A property's options.", &.{
        .{ .name = "editable", .bit = 0, .doc = "siv_set_property changes it." },
        .{ .name = "set", .bit = 1, .doc = "It differs from a new node's of the same kind: the application or a widget set it." },
    }),
    value("siv_property", "A property of a node as siv_node_get_property describes it; its name and value are read as text.", &.{
        f("group", ref("siv_property_group"), "Which part of the node."),
        f("type", ref("siv_property_type"), "How its value reads."),
        f("flags", ref("siv_property_flags"), "Options."),
        reserved("reserved0"),
        reserved("reserved1"),
        reserved("reserved2"),
    }),
    value("siv_window_stats", "A window's frame and presentation counters (D12, D24), since it was created: siv_window_get_stats.", &.{
        f("frames", .u64, "Frames the window built: layout, painting, and a commit of what changed."),
        f("layouts", .u64, "Nodes laid out (misses of the layout cache)."),
        f("shapes", .u64, "Texts shaped."),
        f("text_layouts", .u64, "Texts broken into lines."),
        f("layer_builds", .u64, "Layer contents repainted."),
        f("tree_changes", .u64, "Nodes created, moved, or removed: when it grows the tree may have changed."),
        f("commits", .u64, "Layer tree commits sent to the compositor thread."),
        f("presented", .u64, "Frames the compositor presented, counting those it made without a commit (scrolling and animations on the compositor, D8)."),
        f("commit_ns", .u64, "When the latest presented commit was made (CLOCK_MONOTONIC), or 0."),
        f("present_ns", .u64, "When it reached the display server, or 0; present_ns - commit_ns is its latency."),
        f("nodes", .u32, "Nodes in the tree."),
        f("layers", .u32, "Compositor layers the tree is drawn in."),
        reserved("reserved0"),
        reserved("reserved1"),
        reserved("reserved2"),
        reserved("reserved3"),
    }),
    flags("siv_inspect_flags", "Overlays a window shows for an inspector (siv_window_set_inspect_overlay).", &.{
        .{ .name = "bounds", .bit = 0, .doc = "Outline every shown node's border box." },
        .{ .name = "repaints", .bit = 1, .doc = "Flash the boxes of the nodes each frame repaints, fading on the compositor." },
        .{ .name = "pick", .bit = 2, .doc = "Pick a node by pointing: pointer motion and presses no longer reach the tree; the node under the pointer is highlighted and reported as hovered, and a press reports it as picked and ends picking, as Escape does, reporting 0. Scrolling and keys still reach the tree." },
    }),
    enumeration("siv_inspect_event_type", "What a siv_inspect_fn reports.", &.{
        .{ .name = "presented", .value = 0, .doc = "The window presented a frame (SIV_WINDOW_EVENT_TYPE_PRESENTED): its tree, properties, and counters may have changed." },
        .{ .name = "hovered", .value = 1, .doc = "Picking: the pointer moved onto another node, which node names." },
        .{ .name = "picked", .value = 2, .doc = "Picking ended with a press on node, which is highlighted now, or with Escape (node 0)." },
    }),
    .{ .callback = .{ .name = "siv_inspect_fn", .doc = "An inspector's hook into the window it inspects (siv_window_set_inspect_hook).", .since = v0_1, .params = &.{
        p("window", ref("siv_window"), "The inspected window."),
        p("type", ref("siv_inspect_event_type"), "What happened."),
        p("node", ref("siv_node"), "Hovered and picked: the node; otherwise 0."),
    } } },
    descriptor("siv_inspector_desc", "The stock inspector (siv_inspector).", &.{
        f("window", ref("siv_window"), "The window it inspects; 0 for none yet (siv_inspector_inspect)."),
        f("node", ref("siv_node"), "The node it selects in that window; 0 selects the root."),
    }),
};

const buffer_out = [_]Param{
    p("buffer", schema.text_buffer, "Receives at most buffer_cap bytes; may be NULL with buffer_cap 0."),
    p("len", out(.usize), "The full length in bytes."),
};

pub const functions = [_]Function{
    call("siv_node_get_info", "What a node is and where: its kind, role, state, boxes, and how many children and properties it has (D46).", &.{
        node_param,
        p("info", out(ref("siv_node_info")), "The information."),
    }),
    call("siv_node_get_property", "Describes one of a node's properties (D46): its layout, its kind's arrangement or content, its visual, text, semantics, and subtree theme, those that apply to it, in that order. siv_node_get_property_name and siv_node_get_property_value read it as text. The list follows the node: it changes with its kind's and its parent's kind.", &.{
        node_param,
        index_param,
        p("property", out(ref("siv_property")), "The description."),
    }),
    call("siv_node_get_property_name", "Copies a property's name, as siv_set_property takes it: width, padding, background, role.", &([_]Param{ node_param, index_param } ++ buffer_out)),
    call("siv_node_get_property_value", "Copies a property's value as text, as of the latest operation, in the form siv_set_property reads (siv_property_type).", &([_]Param{ node_param, index_param } ++ buffer_out)),
    .{
        .name = "siv_set_property",
        .doc = "Sets a node's property from text, in the form siv_node_get_property_value writes, for inspectors (D46): width \"120\", \"50%\", or \"auto\"; padding \"4 8\" (as CSS orders edges: top, end, bottom, start); background \"#ff000080\" or \"accent\"; role \"button\". Unknown or read-only properties are SIV_ERROR_UNSUPPORTED, malformed values SIV_ERROR_INVALID_ARGUMENT. A failure is the transaction's (see siv_txn_commit).",
        .since = v0_1,
        .params = &.{ txn_param, p("node", ref("siv_node"), "A node of the transaction's window."), p("name", .string, "The property's name."), p("value", .string, "Its new value.") },
    },
    call("siv_node_get_name", "Copies a node's accessible name as assistive technology reads it after the last frame (D18): its label, or for text and named roles the text of its content; empty when it is left out of the semantics tree.", &([_]Param{node_param} ++ buffer_out)),
    .{
        .name = "siv_window_get_node_at",
        .doc = "The deepest shown node whose border box holds a window point, the topmost of siblings, as of the last frame, whether or not it takes pointer input (siv_visual_flags.no_hit_test) and even outside a modal node: the node an inspector picks there (D46). The root when no other holds it; 0 for an invalid window.",
        .since = v0_1,
        .params = &.{ window_param, p("x", .f32, "Window coordinates."), p("y", .f32, "Window coordinates.") },
        .ret = ref("siv_node"),
    },
    call("siv_window_get_stats", "A window's frame and presentation counters (D46).", &.{
        window_param,
        p("stats", out(ref("siv_window_stats")), "The counters."),
    }),
    call("siv_window_get_frame_time", "When one of the frames the window presented most recently reached the display, as the compositor predicted it (CLOCK_MONOTONIC nanoseconds): index 0 is the latest. The last 128 are kept; SIV_ERROR_INVALID_ARGUMENT past them or past siv_window_stats.presented.", &.{
        window_param,
        p("index", .u32, "From 0, the latest."),
        p("time_ns", out(.u64), "The time."),
    }),
    call("siv_window_set_inspect_hook", "Hooks an inspector into a window (D46): callback hears when the window presents a frame and what picking finds (siv_window_set_inspect_overlay). A window has one hook: another replaces it, and the old one's destroy runs, as it does when the window is destroyed. NULL callback removes it.", &.{
        window_param,
        p("callback", ref("siv_inspect_fn"), "The hook; NULL for none."),
        p("destroy", ref("siv_destroy_fn"), "Releases user_data when the hook is replaced or the window destroyed; may be NULL."),
        p("user_data", .user_data, "Passed to callback and destroy."),
    }),
    call("siv_window_set_inspect_overlay", "Shows an inspector's overlays over a window's content, above everything it draws (D46): the highlighted node's border box with its padding and content boxes tinted, and the overlays flags turn on. 0 and no flags show none.", &.{
        window_param,
        p("flags", ref("siv_inspect_flags"), "The overlays, and picking."),
        p("highlight", ref("siv_node"), "A node of the window to highlight, or 0."),
    }),
    .{
        .name = "siv_inspector",
        .doc = "Creates the stock inspector (D22, D46) for a window of the application: its node tree, where selecting a node highlights it in the window; the selected node's boxes and properties (siv_node_get_property), editable with siv_set_property as typed; its theme's colors and subtree theme (D43); and the window's frame and presentation counters, kept current as it presents. Its toolbar picks a node by pointing at it in the window and turns the bounds and repaint overlays on (siv_window_set_inspect_overlay). It hooks into the window (siv_window_set_inspect_hook), replacing any other hook, and it cannot inspect its own window. Appended as the parent's last child. Returns the node, or 0 if the transaction has failed (see siv_txn_commit).",
        .since = v0_1,
        .params = &.{ txn_param, p("parent", ref("siv_node"), "A container node of the transaction's window."), p("desc", .{ .desc = "siv_inspector_desc" }, "The window and node; NULL for none.") },
        .ret = ref("siv_node"),
    },
    .{
        .name = "siv_inspector_inspect",
        .doc = "Points an inspector at another window, or the same one, and selects a node there (0 selects the root). A failure is the transaction's (see siv_txn_commit).",
        .since = v0_1,
        .params = &.{ txn_param, p("inspector", ref("siv_node"), "An inspector (siv_inspector) of the transaction's window."), p("window", ref("siv_window"), "The window to inspect: not the inspector's own."), p("node", ref("siv_node"), "A node of it to select, or 0.") },
    },
    call("siv_inspector_open", "Opens siv's inspector window (D46) on a window, selecting a node (0 selects the root), or points the open one at it: what Ctrl+Shift+I does with SIV_APP_INSPECTOR or the SIV_INSPECTOR environment variable. The inspector window closes with the window it inspects. SIV_ERROR_INVALID_ARGUMENT for the inspector's own window.", &.{
        window_param,
        p("node", ref("siv_node"), "A node of the window to select, or 0."),
    }),
};
