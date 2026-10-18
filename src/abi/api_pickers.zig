//! The pickers part of the API schema (D41): dates and times as the
//! application's locale writes them (D21), the installed font families,
//! and the emoji catalogue. api.zig appends these declarations and
//! functions to its own; the conventions are schema.zig's. Implemented in
//! intl.zig.

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
const buffer_out = [_]Param{
    p("buffer", schema.text_buffer, "Receives at most buffer_cap bytes; may be NULL with buffer_cap 0."),
    p("len", out(.usize), "The full length in bytes."),
};

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
};
