//! The dictionary reader against small dictionaries written for each
//! feature (D37). Expected answers are Hunspell's for the same input.

const std = @import("std");
const spell = @import("spell.zig");
const Dictionary = spell.Dictionary;
const testing = std.testing;
const gpa = testing.allocator;

fn expectWords(d: *const Dictionary, right: []const []const u8, wrong: []const []const u8) !void {
    for (right) |w| if (!d.check(w)) {
        std.debug.print("expected right: {s}\n", .{w});
        return error.TestUnexpectedResult;
    };
    for (wrong) |w| if (d.check(w)) {
        std.debug.print("expected wrong: {s}\n", .{w});
        return error.TestUnexpectedResult;
    };
}

fn expectSuggestion(d: *const Dictionary, word: []const u8, want: []const u8, rank: usize) !void {
    const sugs = try d.suggest(gpa, word);
    defer {
        for (sugs) |s| gpa.free(s);
        gpa.free(sugs);
    }
    for (sugs[0..@min(sugs.len, rank)]) |s| if (std.mem.eql(u8, s, want)) return;
    std.debug.print("{s}: wanted {s} in the first {d} of:", .{ word, want, rank });
    for (sugs) |s| std.debug.print(" {s}", .{s});
    std.debug.print("\n", .{});
    return error.TestUnexpectedResult;
}

test "affixes: conditions, strip strings, cross products, case" {
    var d = try Dictionary.parse(gpa, spell.test_dictionary.aff, spell.test_dictionary.dic);
    defer d.deinit();
    try expectWords(&d, &.{
        "word", "words", "worded", "wording", "cry", "cries", "cried", "crying", "play", "plays", "played",
        "type", "typed", "typing", "fox", "foxes", "recheck", "unchecked", "rechecking", "dog's", "Paris's",
        // Capitalized and all-caps forms of lowercase words; all-caps forms
        // of capitalized and mixed-case words; ICONV's apostrophe.
        "Word", "WORDS", "PARIS", "OPENOFFICE", "NASA", "iPhone", "IPHONE", "don’t", "can't",
        // Abbreviation dots and numbers.
        "word.", "1,234.5", "3-4",
    }, &.{
        "wordd", "crys", "cryed", "plaies", "typeing", "foxs", "unword", "reword's",
        // Lowercase forms of capitalized words, wrongly capitalized ones,
        // a KEEPCASE word in other cases, a forbidden word.
        "paris", "nasa", "Iphone", "Openoffice", "MACOS", "Macos", "teh", "Teh", "TEH",
        "1..2",
    });
    try testing.expect(d.check("macOS"));
}

test "suggestions: edits, keyboard, REP, two words, case" {
    var d = try Dictionary.parse(gpa, spell.test_dictionary.aff, spell.test_dictionary.dic);
    defer d.deinit();
    try expectSuggestion(&d, "wrod", "word", 1); // swapped
    try expectSuggestion(&d, "worf", "word", 2); // a keyboard neighbor
    try expectSuggestion(&d, "wordd", "word", 2); // an extra letter
    try expectSuggestion(&d, "wrd", "word", 2); // a forgotten letter
    try expectSuggestion(&d, "fone", "phone", 1); // REP f ph
    try expectSuggestion(&d, "alot", "a lot", 1); // REP alot a_lot
    try expectSuggestion(&d, "helloworld", "hello world", 3); // two words
    try expectSuggestion(&d, "Wrod", "Word", 1); // the word's capitalization
    try expectSuggestion(&d, "WROD", "WORD", 1);
    try expectSuggestion(&d, "paris", "Paris", 1);
    try expectSuggestion(&d, "nasa", "NASA", 2);
    try expectSuggestion(&d, "dictonary", "dictionary", 1);
    try expectSuggestion(&d, "sugestion", "suggestion", 1);
    // Far from any edit: n-grams find it.
    try expectSuggestion(&d, "dikshunary", "dictionary", 4);
    // NOSUGGEST and forbidden words are never offered.
    const sugs = try d.suggest(gpa, "dammn");
    defer {
        for (sugs) |s| gpa.free(s);
        gpa.free(sugs);
    }
    for (sugs) |s| try testing.expect(!std.mem.eql(u8, s, "damn"));
    try testing.expect(d.check("damn"));
    const teh = try d.suggest(gpa, "tehh");
    defer {
        for (teh) |s| gpa.free(s);
        gpa.free(teh);
    }
    for (teh) |s| try testing.expect(!std.mem.eql(u8, s, "teh"));
}

test "two suffix levels, prefixes with continuation, NEEDAFFIX, CIRCUMFIX" {
    const aff =
        \\SET UTF-8
        \\NEEDAFFIX N
        \\CIRCUMFIX X
        \\SFX A Y 1
        \\SFX A 0 able/B .
        \\SFX B Y 1
        \\SFX B 0 s .
        \\SFX C Y 1
        \\SFX C 0 ize .
        \\PFX P Y 1
        \\PFX P 0 pre/C .
        \\PFX G Y 1
        \\PFX G 0 ge/X .
        \\SFX T Y 1
        \\SFX T 0 t/X .
        \\SFX E Y 1
        \\SFX E 0 en .
    ;
    const dic =
        \\4
        \\drink/A
        \\fertil/NC
        \\mach/GTE
        \\custom/P
    ;
    var d = try Dictionary.parse(gpa, aff, dic);
    defer d.deinit();
    // A prefix whose continuation class allows a suffix the root lacks.
    try expectWords(&d, &.{ "drink", "drinkable", "drinkables", "fertilize", "precustom", "precustomize", "gemacht", "gemach", "machen" }, &.{
        "drinks", "fertil", "customize", "macht", "gemachen",
    });
}

test "compounds by flags, as German dictionaries make them" {
    // Like igerman98: lowercase compound-only entries, compound flags
    // given by empty suffixes, permitted affixes inside compounds,
    // CHECKSHARPS, KEEPCASE, and forbidden compounds.
    const aff =
        \\SET UTF-8
        \\TRY esijanrtolcdugmphbyfvkwqxzäüößáéêàâñESIJANRTOLCDUGMPHBYFVKWQXZÄÜÖÉ-.
        \\CHECKSHARPS
        \\COMPOUNDBEGIN x
        \\COMPOUNDMIDDLE y
        \\COMPOUNDEND z
        \\FORBIDDENWORD d
        \\COMPOUNDPERMITFLAG c
        \\ONLYINCOMPOUND o
        \\NEEDAFFIX h
        \\KEEPCASE w
        \\COMPOUNDMIN 2
        \\SFX j Y 1
        \\SFX j 0 0/xoc .
        \\SFX S Y 1
        \\SFX S 0 es .
        \\SFX e Y 1
        \\SFX e 0 0/yoc .
        \\SFX N Y 1
        \\SFX N 0 en .
    ;
    const dic =
        \\12
        \\Haus/Sj
        \\haus/Soz
        \\Tür/N
        \\tür/Noz
        \\Verwaltungs/hje
        \\verwaltungs/hoe
        \\Gesellschaft/j
        \\gesellschaft/oz
        \\Straße/w
        \\Türhaus/d
        \\Kinder/j
        \\wagen/oz
    ;
    var d = try Dictionary.parse(gpa, aff, dic);
    defer d.deinit();
    try expectWords(&d, &.{
        "Haus", "Hauses", "Tür", "Türen", "Haustür", "Haustüren", "Verwaltungsgesellschaft", "Hausverwaltungsgesellschaft",
        "Kinderwagen", "HAUSTÜR", "STRASSE", "Straße",
    }, &.{
        "haus", "tür", "Verwaltungs", "verwaltungs", "Türhaus", "Hausgesellschafts", "haustür",
        "Strasse", "STRASSEN", "straße", "Kinderwagenx",
    });
    try expectSuggestion(&d, "Haustühr", "Haustür", 4);
}

test "compound rules, as en_US's ordinals" {
    const aff =
        \\SET UTF-8
        \\COMPOUNDMIN 1
        \\ONLYINCOMPOUND c
        \\COMPOUNDRULE 2
        \\COMPOUNDRULE n*1t
        \\COMPOUNDRULE n*mp
    ;
    const dic =
        \\6
        \\0/nm
        \\1/n1
        \\2/nm
        \\1st/p
        \\2nd/p
        \\1th/tc
        \\2th/tc
    ;
    var d = try Dictionary.parse(gpa, aff, dic);
    defer d.deinit();
    try expectWords(&d, &.{ "1st", "21st", "11th", "102nd", "2nd", "201st" }, &.{ "1th", "21th", "11st", "2th" });
}

test "flag types and aliases: long, numeric, UTF-8, AF" {
    const long_aff =
        \\FLAG long
        \\SFX Aa Y 1
        \\SFX Aa 0 s .
        \\SFX Bb Y 1
        \\SFX Bb 0 ed .
    ;
    var long = try Dictionary.parse(gpa, long_aff, "1\nwalk/AaBb\ntalk/Bb\n");
    defer long.deinit();
    try expectWords(&long, &.{ "walks", "walked", "talked" }, &.{"talks"});

    const num_aff =
        \\FLAG num
        \\SFX 101 Y 1
        \\SFX 101 0 s .
        \\SFX 7 Y 1
        \\SFX 7 0 ing .
    ;
    var num = try Dictionary.parse(gpa, num_aff, "2\nwalk/101,7\ntalk/7 po:verb\n");
    defer num.deinit();
    try expectWords(&num, &.{ "walks", "walking", "talking", "talk" }, &.{"talks"});

    const utf8_aff =
        \\SET UTF-8
        \\FLAG UTF-8
        \\SFX Ŝ Y 1
        \\SFX Ŝ 0 s .
    ;
    var utf8 = try Dictionary.parse(gpa, utf8_aff, "1\nwalk/Ŝ\n");
    defer utf8.deinit();
    try expectWords(&utf8, &.{"walks"}, &.{"walkŜ"});

    const af_aff =
        \\AF 2
        \\AF AB
        \\AF B
        \\SFX A Y 1
        \\SFX A 0 s .
        \\SFX B Y 1
        \\SFX B 0 ed .
        \\AM 1
        \\AM po:verb
    ;
    var af = try Dictionary.parse(gpa, af_aff, "2\nwalk/1 1\ntalk/2\n");
    defer af.deinit();
    try expectWords(&af, &.{ "walks", "walked", "talked" }, &.{"talks"});
}

test "8-bit sets, IGNORE, BREAK, OCONV, MAP, comments and escapes" {
    var latin1 = try Dictionary.parse(gpa, "SET ISO8859-1\nSFX A Y 1\nSFX A 0 n .\n", "2\nStra\xdfe/A\n\tThis is a comment\ncaf\xe9\n");
    defer latin1.deinit();
    try expectWords(&latin1, &.{ "Straße", "Straßen", "café", "CAFÉ" }, &.{ "This", "cafe" });

    const aff =
        \\SET UTF-8
        \\IGNORE ـ
        \\BREAK 2
        \\BREAK -
        \\BREAK ^'
        \\OCONV 1
        \\OCONV ' ’
        \\MAP 1
        \\MAP eéè
        \\TRY e
    ;
    var d = try Dictionary.parse(gpa, aff, "4\ncafé\nwell\nknown\nl'eau\na\\/b\n");
    defer d.deinit();
    try expectWords(&d, &.{ "well-known", "café", "'well", "cafـé", "a/b", "l'eau" }, &.{ "well-", "unknown", "a\\/b" });
    try expectSuggestion(&d, "cafe", "café", 1);
    try expectSuggestion(&d, "l'au", "l’eau", 2);
}

test "words beyond the dictionary: personal lists and parse failures" {
    try testing.expectError(error.UnknownEncoding, Dictionary.parse(gpa, "SET EBCDIC\n", "1\nword\n"));
    var empty = try Dictionary.parse(gpa, "", "");
    defer empty.deinit();
    try testing.expect(!empty.check("word"));
    try testing.expect(empty.check(""));
    const s = try empty.suggest(gpa, "word");
    defer gpa.free(s);
    try testing.expectEqual(@as(usize, 0), s.len);
}
