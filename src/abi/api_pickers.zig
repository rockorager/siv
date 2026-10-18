//! The pickers part of the API schema (D41): dates and times as the
//! application's locale writes them (D21), the installed font families,
//! the emoji catalogue, and the stock date, time, color, font, and emoji
//! pickers built on them (D22). api.zig appends these declarations and
//! functions to its own; the conventions are schema.zig's. Implemented in
//! intl.zig and src/widgets/{date,time,color,font,emoji}.zig.

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
    return .{ .name = name, .type = .u32, .doc = "Reserved; must be zero (SIV_ERROR_UNSUPPORTED otherwise).", .reserved = true };
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

fn anyThread(comptime f: Function) Function {
    var g = f;
    g.thread = .any;
    return g;
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

const app_param = p("app", ref("siv_app"), "The application.");
const txn_param = p("txn", ref("siv_txn"), "An open transaction.");
const buffer_out = [_]Param{
    p("buffer", schema.text_buffer, "Receives at most buffer_cap bytes; may be NULL with buffer_cap 0."),
    p("len", out(.usize), "The full length in bytes."),
};

/// A picker's builder: a transaction operation that appends it.
fn builder(comptime name: []const u8, comptime desc: []const u8, comptime doc: []const u8) Function {
    return .{
        .name = name,
        .doc = doc ++ " Appended as the parent's last child. Returns the node, or 0 if the transaction has failed (see siv_txn_commit).",
        .since = v0_1,
        .params = &.{
            txn_param,
            p("parent", ref("siv_node"), "A container node of the transaction's window: any, or a popover's content (siv_popover_create)."),
            p("desc", .{ .desc = desc }, "Options; NULL for defaults."),
        },
        .ret = ref("siv_node"),
    };
}

const label_field: schema.Field = .{ .name = "label", .type = .string, .doc = "The accessible name, copied (a visible label beside it says the same); with SIV_PICKER_COMPACT the button's." };
const flags_field: schema.Field = .{ .name = "flags", .type = ref("siv_picker_flags"), .doc = "Options." };

pub const decls = [_]Decl{
    enumeration("siv_date_style", "How siv_app_format_date writes a date, after CLDR's patterns and names for the locale (D21).", &.{
        .{ .name = "full", .value = 0, .doc = "With the weekday: \"Sunday, October 18, 2026\", \"Sonntag, 18. Oktober 2026\"." },
        .{ .name = "long", .value = 1, .doc = "\"October 18, 2026\"." },
        .{ .name = "medium", .value = 2, .doc = "\"Oct 18, 2026\"." },
        .{ .name = "short", .value = 3, .doc = "\"10/18/26\"." },
        .{ .name = "month_year", .value = 4, .doc = "A calendar's heading: \"October 2026\", \"2026年10月\"." },
        .{ .name = "day", .value = 5, .doc = "The day of the month as a number in the locale's digits: \"18\", \"١٨\"." },
        .{ .name = "month", .value = 6, .doc = "The month's name on its own: \"October\"." },
        .{ .name = "weekday", .value = 7, .doc = "The weekday's name on its own: \"Sunday\"." },
        .{ .name = "weekday_short", .value = 8, .doc = "The weekday's short name, a calendar's column heading: \"Su\", \"So\"." },
        .{ .name = "year", .value = 9, .doc = "The year as a number in the locale's digits." },
        .{ .name = "weekday_narrow", .value = 10, .doc = "The weekday's narrowest name, for a calendar's column where the short one does not fit: \"S\", \"س\"." },
    }),
    enumeration("siv_time_style", "How siv_app_format_time writes a time of day (D21).", &.{
        .{ .name = "short", .value = 0, .doc = "Hours and minutes: \"10:30 PM\", \"22:30\", \"오후 10:30\"." },
        .{ .name = "medium", .value = 1, .doc = "With seconds: \"10:30:15 PM\"." },
        .{ .name = "hour", .value = 2, .doc = "The hour alone, as the short style writes it: \"10\" in a 12-hour locale, \"22\" or \"07\" in a 24-hour one." },
        .{ .name = "minute", .value = 3, .doc = "The minutes, two digits." },
        .{ .name = "second", .value = 4, .doc = "The seconds, two digits." },
        .{ .name = "period", .value = 5, .doc = "The day period: \"AM\", \"PM\", \"م\"." },
    }),
    enumeration("siv_hour_cycle", "How a locale counts hours.", &.{
        .{ .name = "h12", .value = 0, .doc = "1 to 12 with a day period (en-US)." },
        .{ .name = "h23", .value = 1, .doc = "0 to 23 (de)." },
        .{ .name = "h11", .value = 2, .doc = "0 to 11 with a day period (ja-JP's colloquial clock)." },
        .{ .name = "h24", .value = 3, .doc = "1 to 24." },
    }),
    flags("siv_locale_flags", "Facts about a locale's way of writing times.", &.{
        .{ .name = "period_first", .bit = 0, .doc = "The day period comes before the hour (\"오후 10:30\" in Korean)." },
    }),
    value("siv_locale_info", "What a calendar or time picker needs to know of the application's locale (D21), from CLDR. Filled by siv; reserved fields are zero.", &.{
        .{ .name = "first_weekday", .type = .u32, .doc = "The first day of the week: 0 is Sunday (en-US, he), 1 Monday (de, en-GB), 6 Saturday (ar-EG, fa)." },
        .{ .name = "hour_cycle", .type = ref("siv_hour_cycle"), .doc = "12 or 24 hours." },
        .{ .name = "flags", .type = ref("siv_locale_flags"), .doc = "Facts about its times." },
        .{ .name = "time_separator", .type = .u32, .doc = "The code point between hours and minutes: ':' mostly, '.' in Finnish." },
        reserved("reserved0"),
        reserved("reserved1"),
        reserved("reserved2"),
        reserved("reserved3"),
    }),
    enumeration("siv_emoji_group", "UTS #51's groups of emoji, in CLDR order.", &.{
        .{ .name = "smileys_emotion", .value = 0, .doc = "Smileys & Emotion." },
        .{ .name = "people_body", .value = 1, .doc = "People & Body." },
        .{ .name = "animals_nature", .value = 2, .doc = "Animals & Nature." },
        .{ .name = "food_drink", .value = 3, .doc = "Food & Drink." },
        .{ .name = "travel_places", .value = 4, .doc = "Travel & Places." },
        .{ .name = "activities", .value = 5, .doc = "Activities." },
        .{ .name = "objects", .value = 6, .doc = "Objects." },
        .{ .name = "symbols", .value = 7, .doc = "Symbols." },
        .{ .name = "flags", .value = 8, .doc = "Flags." },
    }),
    enumeration("siv_skin_tone", "A skin tone for emoji that take one (UTS #51's Fitzpatrick modifiers).", &.{
        .{ .name = "none", .value = 0, .doc = "The default yellow." },
        .{ .name = "light", .value = 1, .doc = "U+1F3FB." },
        .{ .name = "medium_light", .value = 2, .doc = "U+1F3FC." },
        .{ .name = "medium", .value = 3, .doc = "U+1F3FD." },
        .{ .name = "medium_dark", .value = 4, .doc = "U+1F3FE." },
        .{ .name = "dark", .value = 5, .doc = "U+1F3FF." },
    }),
    flags("siv_emoji_flags", "Facts about an emoji.", &.{
        .{ .name = "skin_tones", .bit = 0, .doc = "It takes a skin tone (siv_emoji_get with a tone gives the variant)." },
    }),
    value("siv_emoji_info", "An emoji of the catalogue. Filled by siv; reserved fields are zero.", &.{
        .{ .name = "group", .type = ref("siv_emoji_group"), .doc = "Its group." },
        .{ .name = "flags", .type = ref("siv_emoji_flags"), .doc = "Facts about it." },
        reserved("reserved0"),
        reserved("reserved1"),
    }),
    flags("siv_picker_flags", "Picker options. Bits for another kind of picker are ignored.", &.{
        .{ .name = "disabled", .bit = 0, .doc = "Shown dimmed; neither focusable nor operable." },
        .{ .name = "compact", .bit = 1, .doc = "A button showing the value, which opens the picker in a popover below it (D22); the value is the button's. Choosing a date or an emoji, or Enter, closes it; Escape and a click outside do too." },
        .{ .name = "seconds", .bit = 2, .doc = "Time pickers: a field for seconds too." },
        .{ .name = "alpha", .bit = 3, .doc = "Color choosers: a slider for opacity too." },
    }),
    descriptor("siv_date_picker_desc", "A date picker (siv_date_picker).", &.{ label_field, flags_field, reserved("reserved0") }),
    descriptor("siv_time_picker_desc", "A time picker (siv_time_picker).", &.{ label_field, flags_field, reserved("reserved0") }),
    descriptor("siv_color_chooser_desc", "A color chooser (siv_color_chooser).", &.{
        label_field,
        .{ .name = "color", .type = ref("siv_color"), .doc = "The color it starts with; all zero is opaque black." },
        flags_field,
        reserved("reserved0"),
    }),
    descriptor("siv_font_chooser_desc", "A font chooser (siv_font_chooser).", &.{
        label_field,
        .{ .name = "preview", .type = .string, .doc = "The text the preview shows in the chosen family, copied; empty shows a pangram and digits." },
        flags_field,
        reserved("reserved0"),
    }),
    descriptor("siv_emoji_chooser_desc", "An emoji chooser (siv_emoji_chooser).", &.{
        label_field,
        flags_field,
        .{ .name = "tone", .type = ref("siv_skin_tone"), .doc = "The skin tone it starts with, as a change event reported it last time." },
    }),
};

pub const functions = [_]Function{
    call("siv_app_get_locale_info", "The first day of the week, hour cycle, and time separator of the application's language (siv_app_set_language; English when it has none), from CLDR (D21). A region in the language tag picks the first day (\"en-DE\" starts on Monday).", &.{
        app_param,
        p("info", out(ref("siv_locale_info")), "The facts."),
    }),
    call("siv_app_format_date", "Writes a date as the application's language does, from CLDR's Gregorian calendar data (D21): month and weekday names, patterns, and digits (\"١٨\" in ar-EG). Languages CLDR covers at the modern or moderate level have their own; others fall back to a shorter tag (\"de\" for \"de-XX\") and then English.", &([_]Param{
        app_param,
        p("days", .i32, "The date, in days since 1970-01-01 (the proleptic Gregorian calendar, no time zone): its Unix time at midnight UTC divided by 86400."),
        p("style", ref("siv_date_style"), "What to write."),
    } ++ buffer_out)),
    call("siv_app_format_time", "Writes a time of day as the application's language does, in its hour cycle and digits, from CLDR (D21).", &([_]Param{
        app_param,
        p("seconds", .u32, "Seconds since midnight; whole days are dropped."),
        p("style", ref("siv_time_style"), "What to write."),
    } ++ buffer_out)),
    call("siv_app_get_font_family_count", "How many font families are installed (D13, D41): those added with siv_app_add_font and Fontconfig's, each once. siv_app_get_font_family_at reads them in order of their names. The list is kept until the families change: settings events with SIV_EVENT_FONTS_CHANGED say when.", &.{
        app_param,
        p("count", out(.u32), "The number of families."),
    }),
    call("siv_app_get_font_family_at", "An installed font family by its place in name order (ignoring ASCII case), as a family id for text spans and siv_app_get_font_family_name. SIV_ERROR_INVALID_ARGUMENT past the count.", &.{
        app_param,
        p("index", .u32, "From 0 to siv_app_get_font_family_count's count, exclusive."),
        p("id", out(.u32), "The family's id."),
    }),
    .{ .name = "siv_emoji_get_count", .doc = "The number of emoji in the catalogue (D41): every fully-qualified emoji of Emoji 18.0 (UTS #51's emoji-test.txt) without a skin tone, in CLDR order, which groups them (siv_emoji_get_info). Indices from 0 to the count, exclusive, name them. Any thread.", .since = v0_1, .thread = .any, .ret = .u32 },
    anyThread(call("siv_emoji_get", "Copies an emoji's characters (UTF-8), with a skin tone if it takes one: \"👍🏽\" for thumbs up with SIV_SKIN_TONE_MEDIUM. Emoji that take none ignore the tone. Any thread.", &([_]Param{
        p("index", .u32, "An index into the catalogue."),
        p("tone", ref("siv_skin_tone"), "The skin tone."),
    } ++ buffer_out))),
    anyThread(call("siv_emoji_get_name", "Copies an emoji's CLDR short name, in English, with the skin tone as siv_emoji_get applies it: \"thumbs up: medium skin tone\". Any thread.", &([_]Param{
        p("index", .u32, "An index into the catalogue."),
        p("tone", ref("siv_skin_tone"), "The skin tone."),
    } ++ buffer_out))),
    anyThread(call("siv_emoji_get_info", "An emoji's group and whether it takes a skin tone. Any thread.", &.{
        p("index", .u32, "An index into the catalogue."),
        p("info", out(ref("siv_emoji_info")), "The facts."),
    })),
    anyThread(call("siv_emoji_find", "Finds the first emoji at or after an index whose name matches a query: every word of the query starts a word of the name, ignoring ASCII case (\"smil cat\" finds \"grinning cat with smiling eyes\"). Any thread.", &.{
        p("query", .string, "Words separated by spaces; empty matches nothing."),
        p("start", .u32, "Where to start; the count finds nothing."),
        p("found", out(.bool), "Whether one matched."),
        p("index", out(.u32), "Its index; the count when none did."),
    })),
    builder("siv_date_picker", "siv_date_picker_desc", "Creates a date picker (D22, D41): a month's calendar in the application's locale (D21), with the month and year as its heading between previous- and next-month buttons, weekday columns from the locale's first day, and day numbers in its digits; mirrored in right-to-left layouts. Its value (siv_widget_get_value, siv_widget_set_value) is the selected date in days since 1970-01-01 (see siv_app_format_date), today's by default; siv_widget_set_range limits it, leaving other days disabled. Choosing a day (a click, Enter, or Space) reports SIV_EVENT_CHANGE with the date as value. The calendar is WAI-ARIA's date grid: a table of rows of cells named by their full date, one Tab stop at the selected day, which arrows move by a day (Left and Right mirrored in RTL) or a week, Home and End to the week's start and end, Page Up and Page Down by a month, and with Shift by a year, showing that month."),
    builder("siv_time_picker", "siv_time_picker_desc", "Creates a time picker (D22, D41): fields for the hour, minutes, optional seconds, and a day period where the locale counts 12 hours, in the locale's order, digits, and separator (D21); the numbers read left to right in right-to-left layouts too. Each field is a spin button: Up and Down step it (wrapping), digits type it, Home and End go to its ends, Left and Right move to the field beside it on screen, Enter reports SIV_EVENT_ACTIVATE; A and P, or the period's first letter, set the period. Its value is the time in seconds since midnight, 0 by default; siv_widget_set_range sets its bounds and step (60 by default, 1 with seconds). The user's changes report SIV_EVENT_CHANGE with the seconds as value. Its role is group; the fields' spin_button, the period's with its text as the value text."),
    builder("siv_color_chooser", "siv_color_chooser_desc", "Creates a color chooser (D22, D41): a saturation and value area over a hue slider, an optional opacity slider, a hexadecimal field, and a button that picks a color from the screen through the Screenshot portal (siv_pick_color), which disables itself where no portal provides it. Colors are sRGB (siv_color); the area and the sliders show what they choose exactly, as sRGB pixels, while siv composites in linear light (D11). It has no widget value, since a color is four numbers: siv_color_chooser_get_color and siv_color_chooser_set_color read and set it. The user's changes report SIV_EVENT_CHANGE (value 0). For assistive technology the area is a slider of saturation (Left and Right) whose brightness Up and Down change, and the hue and opacity are sliders, each with its values as text; all three stay left to right in right-to-left layouts."),
    builder("siv_font_chooser", "siv_font_chooser_desc", "Creates a font chooser (D22, D41): a search field over a list of the installed families (siv_app_get_font_family_at), each named in its own face, and a preview of the chosen family. Its value is the chosen family's id (siv_app_get_font_family), for text styles and spans; 0 (the default family) until one is chosen. Selecting a family reports SIV_EVENT_CHANGE with its id as value. Typing in the field filters the families by what their names contain, ignoring case; Down moves to the list, where Enter reports SIV_EVENT_ACTIVATE on the chooser."),
    builder("siv_emoji_chooser", "siv_emoji_chooser_desc", "Creates an emoji chooser (D22, D41): a search field, a skin tone menu, a tab per group of the catalogue (siv_emoji_get_info), and a grid of the group's emoji or of those whose names match the search (siv_emoji_find). Its value is the index of the emoji chosen last, -1 before one is (setting it shows that emoji's group). Choosing one (a click, Enter, or Space; arrows only move the selection) reports SIV_EVENT_CHANGE with its index as value and the skin tone as index; siv_emoji_get gives its characters. Emoji are named by their CLDR names (in English) for assistive technology; the grid's role is list, its arrows move in two dimensions."),
    call("siv_color_chooser_get_color", "A color chooser's color, sRGB with straight alpha.", &.{
        p("node", ref("siv_node"), "A color chooser."),
        p("color", out(ref("siv_color")), "The color."),
    }),
    .{
        .name = "siv_color_chooser_set_color",
        .doc = "Sets a color chooser's color without reporting it. Components are clamped to [0, 1]. A failure is the transaction's (see siv_txn_commit).",
        .since = v0_1,
        .params = &.{
            txn_param,
            p("node", ref("siv_node"), "A color chooser of the transaction's window."),
            p("color", ref("siv_color"), "sRGB with straight alpha."),
        },
    },
};
