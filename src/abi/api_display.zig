//! Spinners, chips, avatars, cards, and suggestion lists: the part of the
//! API schema for the stock widgets that show status, labels, people,
//! and surfaces, and the list of suggestions under a text field (D22),
//! written in src/widgets like every stock widget. api.zig appends these
//! declarations and functions to its own; the conventions are
//! schema.zig's.

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

pub const decls = [_]Decl{
    descriptor("siv_spinner_desc", "A spinner: progress of unknown length (siv_spinner).", &.{
        f("label", .string, "The accessible name, copied; empty is \"Loading\"."),
        f("diameter", .f32, "Its width and height in logical pixels; 0 is 16."),
        reserved("reserved0"),
    }),
    flags("siv_chip_flags", "Chip options.", &.{
        .{ .name = "clickable", .bit = 0, .doc = "A button: a click, Enter, or Space reports SIV_EVENT_ACTIVATE on the chip." },
        .{ .name = "removable", .bit = 1, .doc = "A remove button at its end. It, or Delete or BackSpace while the chip has focus, reports SIV_EVENT_CLOSE on the chip, whose default handler removes it (return true from siv_on to keep it). Without clickable, activating the chip (a click, Enter, Space) removes it too." },
        .{ .name = "disabled", .bit = 2, .doc = "Shown dimmed; neither focusable nor operable." },
    }),
    descriptor("siv_chip_desc", "A chip: a label in a pill (siv_chip).", &.{
        f("label", .string, "The label, copied; also the accessible name."),
        f("icon", .string, "A themed icon before the label (D19), as siv_image_view_desc.icon names it; empty for none."),
        f("color", ref("siv_color_token"), "Its color: a hue (SIV_COLOR_TOKEN_RED to SIV_COLOR_TOKEN_MAGENTA) fills it with the hue's tint (red_bg ...), any other token fills it as it is; none is the neutral chip, outlined on control_bg."),
        f("flags", ref("siv_chip_flags"), "Options."),
    }),
    descriptor("siv_avatar_desc", "An avatar: a person's initials in a circle (siv_avatar).", &.{
        f("name", .string, "The person's name, copied: the initials (of its first and last words) and the color come from it, and it is the accessible name. Empty shows no initials, in a neutral circle."),
        f("diameter", .f32, "Its width and height in logical pixels; 0 is 32."),
        f("color", ref("siv_color_token"), "Its color, as for siv_chip_desc.color (a hue tints it); none derives one of the six hues from the name, the same for the same name everywhere."),
    }),
    flags("siv_card_flags", "Card options.", &.{
        .{ .name = "accent", .bit = 0, .doc = "Framed in the accent rather than the border color, as Omarchy's compositor frames the focused window." },
        .{ .name = "flat", .bit = 1, .doc = "No shadow." },
    }),
    descriptor("siv_card_desc", "A card: a framed, raised surface (siv_card).", &.{
        f("label", .string, "The accessible name of the group it forms, copied; empty for none (it is then no group of its own)."),
        f("background", ref("siv_color_token"), "Its surface; none is card_bg. Text on it should use the matching text token (card_fg, view_fg)."),
        f("flags", ref("siv_card_flags"), "Options."),
    }),
    descriptor("siv_suggestion_list_desc", "A list of suggestions under a node (siv_suggestion_list).", &.{
        f("anchor", ref("siv_node"), "What it belongs to and shows under: a text field (siv_text_field) or another node with keyboard focus, inside an earlier child of the list's parent stack."),
        f("label", .string, "The list's accessible name, copied; empty is \"Suggestions\"."),
    }),
    descriptor("siv_suggestion_list_item_desc", "A suggestion (siv_suggestion_list_item).", &.{
        f("label", .string, "The suggestion, copied: a name, a word, a command."),
        f("detail", .string, "More about it after the label, in the muted color, copied: an address, a path. Empty for none."),
        f("icon", .string, "A themed icon before the label (D19); empty for none."),
        f("flags", ref("siv_widget_flags"), "SIV_WIDGET_DISABLED: shown dimmed; keys skip it and it cannot be chosen."),
        reserved("reserved0"),
    }),
};

pub const functions = [_]Function{
    builder("siv_spinner", "Creates a spinner (D22): a bead of the accent circling a ring in the track color, for work of unknown length. It turns on the compositor (D8) while it is shown, at no cost to the application's thread, and holds still with the bead at the top under reduced motion (D29). Its role is progress_bar with no value and the busy state (AT-SPI's busy), named by its label; siv_widget_set_label renames it. Hide it with siv_set_hidden when the work is done.", "siv_spinner_desc"),
    builder("siv_chip", "Creates a chip (D22): a label, optionally after an icon, in a pill, neutral or tinted with a hue, for labels, tags, and filters. A clickable chip is a button (SIV_EVENT_ACTIVATE); a removable one has a remove button and reports SIV_EVENT_CLOSE (removed unless a handler keeps it). Both are focusable and show hover, press, and focus. siv_widget_set_label, siv_widget_set_icon, and siv_widget_set_disabled change it. A chip that is neither is not focusable.", "siv_chip_desc"),
    builder("siv_avatar", "Creates an avatar (D22): the initials of a name in a circle tinted with a hue derived from the name, an image named by the person's name for assistive technology. siv_widget_get_part's image part is an image node over the initials, clipped to the circle and empty until the application shows a picture in it (siv_set_image_view, fit cover); siv_widget_set_label changes the name, its initials, and its color.", "siv_avatar_desc"),
    builder("siv_card", "Creates a card (D22): a column with a rounded border and a shadow on a raised surface, framed in the border color or the accent, which clips its content to its corners; the application adds the content and its padding (siv_set_layout). A label makes it a group named by it.", "siv_card_desc"),
    builder("siv_suggestion_list", "Creates a list of suggestions (D22) for a node, typically a text field: a card in the parent, which must be a stack holding the anchor in an earlier child (the window's root, or an overlay layer), placed under the anchor as wide as it (siv_set_anchor), above it when only that fits, inside the stack. It starts hidden; adding an item (siv_suggestion_list_item) shows it with the first enabled item highlighted, and siv_suggestion_list_clear removes every item and hides it. The anchor keeps the keyboard focus while it shows: on the anchor, Down and Up move the highlight (wrapping), Enter and Tab choose the highlighted item, and Escape closes the list; moving the pointer over an item highlights it and a click chooses it, without taking the focus. Choosing reports SIV_EVENT_SELECT with index on the list and hides it. Escape, and the anchor losing focus, report SIV_EVENT_CLOSE on the list, whose default handler hides it (return true from siv_on to keep it). Its value is the highlighted item's index, or -1 for none (siv_widget_set_value, siv_widget_get_value), and siv_widget_get_part's item part finds an item by index. The list is a list of list_items with selected on the highlighted one, which a live region announces since the focus stays in the anchor; a stock text field anchor is expanded while the list shows. siv_node_is_shown says whether it shows.", "siv_suggestion_list_desc"),
    .{
        .name = "siv_suggestion_list_item",
        .doc = "Appends a suggestion to a suggestion list and shows the list (if any item is enabled), highlighting the first enabled item when none is: a row with an optional icon, the label, and the detail after it. It is a widget whose label siv_widget_set_label sets and whose disabled state siv_widget_set_disabled sets." ++ returns,
        .since = v0_1,
        .params = &.{
            txn_param,
            .{ .name = "list", .type = ref("siv_node"), .doc = "A suggestion list." },
            .{ .name = "desc", .type = .{ .desc = "siv_suggestion_list_item_desc" }, .doc = "The suggestion." },
        },
        .ret = ref("siv_node"),
    },
    .{
        .name = "siv_suggestion_list_clear",
        .doc = "Removes every item of a suggestion list and hides it, as before new suggestions for what the user typed.",
        .since = v0_1,
        .params = &.{
            txn_param,
            .{ .name = "list", .type = ref("siv_node"), .doc = "A suggestion list." },
        },
    },
};
