//! The spell checking part of the API schema (D37): editors checked as
//! the user types, and the application's dictionaries, word lists, and
//! checks. api.zig appends these declarations and functions to its own;
//! the conventions are schema.zig's. Implemented in spell.zig.

const schema = @import("schema.zig");
const ref = schema.ref;
const out = schema.out;
const array = schema.array;
const Decl = schema.Decl;
const Param = schema.Param;
const Function = schema.Function;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

fn enumeration(comptime name: []const u8, comptime doc: []const u8, comptime values: []const schema.EnumValue) Decl {
    return .{ .@"enum" = .{ .name = name, .doc = doc, .since = v0_1, .values = values } };
}

fn call(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = ref("siv_result") };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

const app_param = p("app", ref("siv_app"), "The application.");
const language_param = p("language", .string, "A BCP 47 tag or locale name (\"en-US\", \"de_DE.UTF-8\") or a dictionary's name; empty for the application's language. The dictionary for it is the one of that name, else of the language alone (\"fr\" for \"fr-CA\"), else of the language's own region (\"de_DE\" for \"de\"; en_US for English), else the first in the language. SIV_ERROR_UNAVAILABLE when there is none.");
const word_param = p("word", .string, "One word, UTF-8.");
const buffer_out = [_]Param{
    p("buffer", schema.text_buffer, "Receives at most buffer_cap bytes; may be NULL with buffer_cap 0."),
    p("len", out(.usize), "The full length in bytes."),
};

pub const decls = [_]Decl{
    enumeration("siv_spell_find", "Which misspelled word siv_node_find_misspelling finds.", &.{
        .{ .name = "at", .value = 0, .doc = "The one containing the offset, either end included." },
        .{ .name = "next", .value = 1, .doc = "The first starting after the offset." },
        .{ .name = "previous", .value = 2, .doc = "The last ending before the offset." },
    }),
};

pub const functions = [_]Function{
    .{
        .name = "siv_set_spell_check",
        .doc = "Turns spell checking of an editor on or off, and sets the language it checks (D37). Misspelled words get a wavy underline in the theme's destructive color, are the text attribute invalid:spelling to assistive technology, and siv_node_find_misspelling finds them; a word the user is typing is marked once the caret leaves it. Editors are off by default; the stock text areas and styled-text editors (siv_text_field with SIV_TEXT_FIELD_MULTILINE or SIV_TEXT_FIELD_STYLED) turn it on, and give a misspelled word a context menu with suggestions, Add to Dictionary, and Ignore. Masked editors are never checked. The dictionaries are the system's Hunspell dictionaries (none on the headless backend) and those added with siv_app_add_dictionary; checking runs in the frame for what an edit changed and on the worker pool for long texts (D6). A failure is the transaction's (see siv_txn_commit).",
        .since = v0_1,
        .params = &.{
            p("txn", ref("siv_txn"), "An open transaction."),
            p("node", ref("siv_node"), "An editor node of the transaction's window."),
            p("enabled", .bool, "Check its spelling."),
            p("language", .string, "A BCP 47 tag or dictionary name, copied; empty follows the editor's text style's language, else the window's, which follows the application's (D21)."),
        },
    },
    call("siv_node_find_misspelling", "Finds a misspelled word of a spell-checked editor as of the last frame (D37): for a context menu at a click, or to step through them. found is false when there is none, spell checking is off, or the text changed since the last frame.", &.{
        p("node", ref("siv_node"), "An editor node."),
        p("offset", .u32, "Byte offset."),
        p("find", ref("siv_spell_find"), "Which word."),
        p("found", out(.bool), "Whether there is one."),
        p("start", out(.u32), "Its start, a byte offset; 0 when there is none."),
        p("end", out(.u32), "Its end; 0 when there is none."),
    }),
    call("siv_node_get_spell_language", "The name of the dictionary a spell-checked editor uses (\"en_US\"), for siv_app_suggest_spelling and siv_app_add_spelling_word on its words; empty when spell checking is off, there is no dictionary for its language, or the dictionary is still loading.", &([_]Param{p("node", ref("siv_node"), "An editor node.")} ++ buffer_out)),
    call("siv_editor_replace", "A user's edit of an editor: replaces a byte range with text as one undo step, followed by a change event, and leaves the caret after it, as choosing a spelling suggestion does (single-line editors turn line breaks into spaces). Not inside an open transaction of the window (SIV_ERROR_BUSY); not for masked editors (SIV_ERROR_INVALID_ARGUMENT).", &.{
        p("node", ref("siv_node"), "An editor node."),
        p("start", .u32, "Byte offset of the range's start, at a character boundary."),
        p("end", .u32, "Byte offset of its end, at a character boundary."),
        p("text", .string, "UTF-8 that replaces it, copied."),
    }),
    call("siv_app_check_spelling", "Checks the spelling of a word with the dictionary for a language and the user's word lists (D37). Loads the dictionary first on this thread if no editor did yet.", &.{
        app_param,
        language_param,
        word_param,
        p("correct", out(.bool), "Whether it is spelled right."),
    }),
    call("siv_app_suggest_spelling", "Corrections for a misspelled word, best first, one per line (at most ten): from the dictionary's replacement table, keyboard neighbors, and edit distance, as Hunspell suggests. Empty when there are none. Loads the dictionary first on this thread if no editor did yet.", &([_]Param{ app_param, language_param, word_param } ++ buffer_out)),
    call("siv_app_add_spelling_word", "Adds a word to the user's personal dictionary for a language's dictionary, so that no editor marks it: saved to Enchant's word list (~/.config/enchant/<dictionary>.dic), which GNOME applications share, except on the headless backend, where it lasts for the run.", &.{ app_param, language_param, word_param }),
    call("siv_app_ignore_spelling_word", "Ignores a word in a language's dictionary for the rest of the run, in every editor.", &.{ app_param, language_param, word_param }),
    call("siv_app_add_dictionary", "Adds a Hunspell dictionary from the bytes of its .aff and .dic files (copied and parsed now): it takes precedence over a system dictionary of the same name, and languages pick it as they pick those. SIV_ERROR_INVALID_ARGUMENT when the files do not parse.", &.{
        app_param,
        p("name", .string, "Its name, as the files are named: a language and region (\"en_US\"), or a language (\"fr\")."),
        p("aff", array(.u8), "The affix file."),
        p("dic", array(.u8), "The word list."),
    }),
    call("siv_app_get_dictionaries", "The names of the dictionaries spell checking can use, sorted, one per line: those added and the system's. Lists the system's on this thread the first time.", &([_]Param{app_param} ++ buffer_out)),
};
