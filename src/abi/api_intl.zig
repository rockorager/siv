//! The internationalization part of the API schema (D21): numbers as the
//! application's language writes them, its plural rules, and gettext
//! message catalogs. api.zig appends these declarations and functions to
//! its own; the conventions are schema.zig's. Implemented in intl.zig.

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

fn descriptor(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .descriptor, .fields = fields } };
}

fn call(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = ref("siv_result") };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

const app_param = p("app", ref("siv_app"), "The application.");
const buffer_out = [_]Param{
    p("buffer", schema.text_buffer, "Receives at most buffer_cap bytes; may be NULL with buffer_cap 0."),
    p("len", out(.usize), "The full length in bytes."),
};
const format_param = p("format", .{ .desc = "siv_number_format_desc" }, "How the number is written; NULL for a decimal with the locale's defaults.");

pub const decls = [_]Decl{
    enumeration("siv_number_style", "How siv_app_format_number writes a number, after CLDR's patterns for the locale (D21).", &.{
        .{ .name = "decimal", .value = 0, .doc = "Grouped, with up to three fraction digits by default: \"1,234.5\", \"1.234,5\" (de), \"١٬٢٣٤٫٥\" (ar-EG), \"12,34,567\" (hi)." },
        .{ .name = "percent", .value = 1, .doc = "The value times 100 with the locale's percent sign, no fraction digits by default: 0.25 is \"25%\", \"25 %\" (de), \"%25\" (tr)." },
        .{ .name = "compact", .value = 2, .doc = "Short compact: \"1.2K\", \"12M\", \"1,2 Mio.\" (de), \"1万\" (ja); two significant digits below 10 and whole numbers above by default. Magnitudes the locale writes in full stay so (German thousands: \"1234\")." },
        .{ .name = "bytes", .value = 3, .doc = "A size in bytes, in decimal units of 1000: \"512 bytes\" (the unit's long form, by plural category), \"1.5 kB\", \"2.0 GB\", \"1,5 ko\" (fr); one fraction digit from kB up by default. Bytes are whole." },
    }),
    flags("siv_number_flags", "Number formatting options.", &.{
        .{ .name = "fraction_digits", .bit = 0, .doc = "min_fraction_digits and max_fraction_digits apply; without it the style's defaults do." },
        .{ .name = "no_grouping", .bit = 1, .doc = "No group separators: \"1234567.5\"." },
    }),
    descriptor("siv_number_format_desc", "How siv_app_format_number writes a number and siv_app_get_plural_category counts it (D21). Rounding is half to even, on the shortest decimal that reads back as the double (2.675 is \"2.68\").", &.{
        .{ .name = "style", .type = ref("siv_number_style"), .doc = "Decimal, percent, compact, or bytes." },
        .{ .name = "flags", .type = ref("siv_number_flags"), .doc = "Options." },
        .{ .name = "min_fraction_digits", .type = .u32, .doc = "With SIV_NUMBER_FRACTION_DIGITS: the fewest fraction digits, padded with zeros." },
        .{ .name = "max_fraction_digits", .type = .u32, .doc = "With SIV_NUMBER_FRACTION_DIGITS: the most, at most 15 and at least min_fraction_digits (SIV_ERROR_INVALID_ARGUMENT otherwise)." },
    }),
    enumeration("siv_plural_type", "Which plural rules count a number (D21).", &.{
        .{ .name = "cardinal", .value = 0, .doc = "Counting: \"1 file\", \"2 files\"." },
        .{ .name = "ordinal", .value = 1, .doc = "Ranking: \"1st\", \"2nd\", \"3rd\", \"4th\"." },
    }),
    enumeration("siv_plural_category", "CLDR's plural categories (D21). English has one and other; Arabic all six; Japanese only other.", &.{
        .{ .name = "zero", .value = 0, .doc = "Zero (Arabic 0, Latvian 10)." },
        .{ .name = "one", .value = 1, .doc = "One (English 1, French 0 and 1, Russian 21)." },
        .{ .name = "two", .value = 2, .doc = "Two (Arabic and Hebrew 2, English ordinal 2nd and 22nd)." },
        .{ .name = "few", .value = 3, .doc = "Few (Russian 2 to 4 and 22, Polish 2 to 4, English ordinal 3rd)." },
        .{ .name = "many", .value = 4, .doc = "Many (Russian 5 to 20, Arabic 11 to 99, French 1000000)." },
        .{ .name = "other", .value = 5, .doc = "Everything else (English 0, 2, and 1.0)." },
    }),
    descriptor("siv_translation_desc", "A message for siv_app_translate (D21): gettext's msgctxt, msgid, msgid_plural, and count.", &.{
        .{ .name = "domain", .type = .string, .doc = "The text domain (siv_app_bind_text_domain); empty is the first one bound." },
        .{ .name = "context", .type = .string, .doc = "The context that tells identical messages apart (msgctxt): \"verb\" for \"Close\"; empty for none." },
        .{ .name = "text", .type = .string, .doc = "The message in the source language (msgid)." },
        .{ .name = "plural", .type = .string, .doc = "Its plural (msgid_plural) for a message that counts: \"%d files\" for \"%d file\"; empty for one that does not." },
        .{ .name = "count", .type = .u64, .doc = "With a plural: the number that picks the plural form." },
    }),
};

pub const functions = [_]Function{
    call("siv_app_format_number", "Writes a number as the application's language does (siv_app_set_language; English when it has none), from CLDR (D21): its digits, decimal and group separators and grouping sizes, minus and percent signs, compact patterns, and byte units. Languages CLDR covers at the modern or moderate level have their own data; others fall back to a shorter tag and then English, as siv_app_format_date does. NaN and infinities are written with the locale's symbols. A negative number that rounds to zero has no sign.", &([_]Param{
        app_param,
        p("value", .f64, "The number."),
        format_param,
    } ++ buffer_out)),
    call("siv_app_parse_number", "Reads a number typed in the application's language (D21): the locale's digits or ASCII ones, its decimal separator, its minus sign or '-', with group separators, spaces, and bidirectional marks ignored; where the group separator is not '.', '.' is a decimal separator too. \"1.234,5\" is 1234.5 in German. Exponents (\"1e3\") are accepted; infinities and NaN are not.", &.{
        app_param,
        p("text", .string, "The text."),
        p("valid", out(.bool), "Whether it is a finite number."),
        p("value", out(.f64), "The number; 0 when it is not one."),
    }),
    call("siv_app_get_plural_category", "The plural category of a number in the application's language, from CLDR's rules (D21), as siv_app_format_number writes it with the same format: in English 1 is one but \"1.0\" (one fraction digit) is other, and with SIV_NUMBER_STYLE_COMPACT a million in French is many. Picks the message for a count where the application keeps one per category. Languages without rules of a type count everything as other there; unknown languages fall back to a shorter tag and then English.", &.{
        app_param,
        p("value", .f64, "The number."),
        p("kind", ref("siv_plural_type"), "Cardinal or ordinal."),
        format_param,
        p("category", out(ref("siv_plural_category")), "Its category."),
    }),
    call("siv_app_bind_text_domain", "Says where a text domain's gettext message catalogs are (D21), as bindtextdomain does: siv_app_translate reads <directory>/<ll_CC>/LC_MESSAGES/<domain>.mo, else <ll>, for the application's language (\"pt-BR\" tries pt_BR, then pt; \"sr-Latn-RS\" sr_RS@latin, sr@latin, sr_RS, sr), when it first needs one and again after the language changes. Catalogs must be UTF-8. Binding a domain again changes its directory; an empty directory forgets it. The first domain bound is the default.", &.{
        app_param,
        p("domain", .string, "The domain, usually the application's name: \"siv-files\". Not empty, without '/' (SIV_ERROR_INVALID_ARGUMENT otherwise)."),
        p("directory", .string, "The directory with the language directories, such as \"/usr/share/locale\"; empty to forget the domain."),
    }),
    call("siv_app_translate", "Translates a message into the application's language with its domain's catalog (siv_app_bind_text_domain, D21), with gettext's lookup: by context and text, and for a message with a plural, the form the count takes. The form comes from the catalog's Plural-Forms expression, else from the CLDR cardinal rules of the catalog's language, its forms taken as the categories integers take in CLDR's order (zero, one, two, few, many, other). Without a translation (no catalog, no entry, an empty one, or no language) it writes the text itself, or the plural when there is one and the count is not 1. Formats nothing: \"%d\" stays for the caller. Settings events with SIV_EVENT_LOCALE_CHANGED say when to translate again.", &([_]Param{
        app_param,
        p("message", .{ .desc = "siv_translation_desc" }, "The message."),
    } ++ buffer_out)),
};
