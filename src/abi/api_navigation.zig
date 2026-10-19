//! The navigation widgets' part of the API schema (D22, D40): header
//! bars, navigation stacks, and sidebars, written in src/widgets like
//! every stock widget. api.zig appends these declarations and functions
//! to its own; the conventions are schema.zig's.

const schema = @import("schema.zig");
const ref = schema.ref;
const Decl = schema.Decl;
const Param = schema.Param;
const Function = schema.Function;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

fn flags(comptime name: []const u8, comptime doc: []const u8, comptime bits: []const schema.Flag) Decl {
    return .{ .flags = .{ .name = name, .doc = doc, .since = v0_1, .bits = bits } };
}

fn descriptor(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .descriptor, .fields = fields } };
}

fn f(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) schema.Field {
    return .{ .name = name, .type = t, .doc = doc };
}

fn reserved(comptime name: []const u8) schema.Field {
    return .{ .name = name, .type = .u32, .doc = "Reserved; must be zero (SIV_ERROR_UNSUPPORTED otherwise).", .reserved = true };
}

const txn_param: Param = .{ .name = "txn", .type = ref("siv_txn"), .doc = "An open transaction." };

const returns = " Returns the node, or 0 if the transaction has failed (see siv_txn_commit).";

/// A builder appended to a parent, like api.zig's.
fn builder(comptime name: []const u8, comptime doc: []const u8, comptime desc: []const u8) Function {
    return .{
        .name = name,
        .doc = doc ++ " Appended as the parent's last child." ++ returns,
        .since = v0_1,
        .params = &.{
            txn_param,
            .{ .name = "parent", .type = ref("siv_node"), .doc = "A container node of the transaction's window." },
            .{ .name = "desc", .type = .{ .desc = desc }, .doc = "Options; NULL for defaults." },
        },
        .ret = ref("siv_node"),
    };
}

/// A child builder: a node added to a widget.
fn child(comptime name: []const u8, comptime doc: []const u8, comptime owner: []const u8, comptime owner_doc: []const u8, comptime desc: []const u8) Function {
    return .{
        .name = name,
        .doc = doc ++ returns,
        .since = v0_1,
        .params = &.{
            txn_param,
            .{ .name = owner, .type = ref("siv_node"), .doc = owner_doc },
            .{ .name = "desc", .type = .{ .desc = desc }, .doc = "Options; NULL for defaults." },
        },
        .ret = ref("siv_node"),
    };
}

pub const decls = [_]Decl{
    flags("siv_header_bar_flags", "Header bar options.", &.{
        .{ .name = "no_window_controls", .bit = 0, .doc = "Never show the window controls, for a header bar that is not at the window's top end edge (a sidebar's)." },
        .{ .name = "expand_content", .bit = 1, .doc = "The content part takes the width the start and end boxes leave, which size to their controls, instead of a title centered between sides that share the rest equally: for a path bar or a search field in place of the title." },
    }),
    descriptor("siv_header_bar_desc", "A header bar: a title between start and end boxes for controls (siv_header_bar).", &.{
        f("title", .string, "The title, copied, centered and the header bar's accessible name; empty in a navigation page shows the page's title."),
        f("flags", ref("siv_header_bar_flags"), "Options."),
        reserved("reserved0"),
    }),
    flags("siv_navigation_flags", "Navigation stack options.", &.{
        .{ .name = "no_escape", .bit = 0, .doc = "Escape does not go back, for pages where it means something else." },
    }),
    descriptor("siv_navigation_stack_desc", "A navigation stack of pages (siv_navigation_stack).", &.{
        f("flags", ref("siv_navigation_flags"), "Options."),
        reserved("reserved0"),
    }),
    descriptor("siv_navigation_page_desc", "A page pushed onto a navigation stack (siv_navigation_page).", &.{
        f("title", .string, "The page's title, copied: its accessible name, and the title of a header bar inside it that has none of its own."),
    }),
    descriptor("siv_sidebar_desc", "A sidebar of destinations (siv_sidebar).", &.{
        f("label", .string, "The navigation landmark's accessible name, copied."),
    }),
    descriptor("siv_sidebar_section_desc", "A titled section of a sidebar (siv_sidebar_section).", &.{
        f("title", .string, "The title shown above its items and the name of their list, copied; empty for none."),
    }),
    descriptor("siv_sidebar_item_desc", "A destination of a sidebar (siv_sidebar_item).", &.{
        f("label", .string, "The label, copied; also the accessible name."),
        f("icon", .string, "A themed icon before the label (D19), as siv_image_view_desc.icon names it; empty for none."),
        f("flags", ref("siv_widget_flags"), "SIV_WIDGET_DISABLED: it cannot be chosen; keys skip it."),
        reserved("reserved0"),
    }),
};

pub const functions = [_]Function{
    builder("siv_header_bar", "Creates a header bar (D17, D22): a bar with a centered title between a start box and an end box for controls (siv_widget_get_part's start, end, and content, the title's box). While the window draws its own decorations (siv_window_get_controls) it shows the window controls at its end and is the title bar: dragging it moves the window, a double click maximizes or restores it, and a secondary click shows the window menu. Inside a navigation page other than the first, it shows a back button at its start that asks the page to close (SIV_EVENT_CLOSE). Its role is toolbar, named by its title; siv_widget_set_label sets the title.", "siv_header_bar_desc"),
    builder("siv_navigation_stack", "Creates a navigation stack (D40): pages pushed with siv_navigation_page, of which only the last shows, sliding in from the end edge over the one below and out again (D38; jumps under reduced motion). Its value is the number of pages: siv_widget_set_value with fewer removes the pages above, without a report. Going back (a header bar's back button, Alt+Left (Alt+Right in RTL), the Back key, the mouse's back button, or Escape, while focus or the pointer is in the stack) reports SIV_EVENT_CLOSE on the last page; unless a handler keeps it, it is removed and the stack reports SIV_EVENT_CHANGE with the number of pages left (value) and the index of the one now shown. siv_widget_get_part's panel part finds a page by index.", "siv_navigation_stack_desc"),
    child("siv_navigation_page", "Pushes a page onto a navigation stack and returns it: a column, with the window's background, for its content (typically a header bar and the page's body). The page below is hidden and keeps its state. If focus was in the stack, it moves to the new page, which is then a Tab stop of its own (a group named by the title); going back returns it to where it was in the page below.", "stack", "A navigation stack.", "siv_navigation_page_desc"),
    builder("siv_sidebar", "Creates a sidebar (D22): a navigation landmark of destinations (siv_sidebar_item) in sections (siv_sidebar_section), on the sidebar color, with boxes above and below them (siv_widget_get_part's start and end) for a header bar or a footer, and a separator at its end edge (the divider part, which a sidebar in a split pane hides in favor of the pane's). Its value is the current item's index, counting every item in order, or -1 for none: choosing one (a click, Enter, Space, or Up, Down, Home, and End, which move between enabled items) makes it current and reports SIV_EVENT_CHANGE with value and index. Only the current item is in the Tab order. The current item is a list_item with current page (aria-current); siv_widget_get_part's item part finds one by index. Hide it with siv_set_hidden to collapse it.", "siv_sidebar_desc"),
    child("siv_sidebar_section", "Appends a section to a sidebar and returns it: a title over a list of items. Items added to the sidebar itself go to a first section without a title.", "sidebar", "A sidebar.", "siv_sidebar_section_desc"),
    child("siv_sidebar_item", "Appends a destination to a sidebar or one of its sections and returns it: a row with an icon and a label, and a box at its end (siv_widget_get_part's end part) for a count or a button. It is a widget whose label, icon, and disabled state the siv_widget_* calls set.", "parent", "A sidebar, or a section of one.", "siv_sidebar_item_desc"),
};
