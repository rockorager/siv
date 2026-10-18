//! A Hunspell-format dictionary (D37): an affix file (.aff) and a word
//! list (.dic), read by siv's own reader, since Hunspell itself (MPL, GPL,
//! LGPL), Enchant (LGPL), and Nuspell (LGPL) are copyleft (D25).
//!
//! The reader covers what real dictionaries use: SET (UTF-8 and the
//! 8-bit sets of encoding.zig), the four flag types (FLAG long, num,
//! UTF-8, and single characters), flag aliases (AF; AM and morphological
//! fields are skipped), prefixes and suffixes with strip strings,
//! conditions, continuation classes (two suffix levels, a prefix with
//! either), and cross products, NEEDAFFIX, FORBIDDENWORD, KEEPCASE,
//! NOSUGGEST, CIRCUMFIX, ONLYINCOMPOUND, compounding by flags
//! (COMPOUNDFLAG, COMPOUNDBEGIN, COMPOUNDMIDDLE, COMPOUNDEND,
//! COMPOUNDPERMITFLAG, COMPOUNDFORBIDFLAG, COMPOUNDMIN, COMPOUNDWORDMAX,
//! CHECKCOMPOUNDDUP, CHECKCOMPOUNDCASE, CHECKCOMPOUNDTRIPLE,
//! CHECKCOMPOUNDREP, CHECKCOMPOUNDPATTERN without replacements) and by
//! rules (COMPOUNDRULE), CHECKSHARPS, FULLSTRIP, IGNORE, ICONV, OCONV,
//! BREAK, and for suggestions REP, MAP, KEY, TRY, NOSPLITSUGS, and
//! MAXNGRAMSUGS. Capitalization follows Hunspell: "Word" and "WORD" are
//! right when "word" is, "WORD" when "Word" is, mixed-case words in all
//! capitals, and KEEPCASE words only as written.
//!
//! Not supported: COMPLEXPREFIXES (two prefix levels, for right-to-left
//! languages), FORCEUCASE, Hungarian's syllable rules (COMPOUNDSYLLABLE,
//! SYLLABLENUM), LANG's Turkish and Azeri dotted i, PHONE, and morphology.
//!
//! A dictionary is immutable once parsed, so worker threads check words
//! with it while the UI thread does (D6).

const std = @import("std");
const case = @import("case.zig");
const encoding = @import("encoding.zig");
const Allocator = std.mem.Allocator;

const Dictionary = @This();

pub const Flag = u16;
pub const Error = error{ OutOfMemory, InvalidDictionary, UnknownEncoding };

const none = std.math.maxInt(u32);
/// Hidden capitalized homonyms of mixed-case words, matched only by
/// words in all capitals (Hunspell's ONLYUPCASE).
const only_upcase: Flag = 65511;
/// Words longer than this many bytes are not checked.
pub const max_word = 200;
/// Most suggestions `suggest` returns.
pub const max_suggestions = 10;

gpa: Allocator,
arena: std.heap.ArenaAllocator,
/// Every word's bytes; entries index into it.
words: []const u8 = &.{},
entries: []const Entry = &.{},
/// Open addressing by word: the first entry of each word (its homonyms
/// follow through `Entry.next`), `none` for empty slots.
slots: []const u32 = &.{},
/// Sorted flag sets; set 0 is empty.
flags: []const Flag = &.{},
sets: []const Set = &.{},
prefixes: []const Affix = &.{},
suffixes: []const Affix = &.{},
/// Affixes by the first (prefixes) or last (suffixes) byte of what they
/// add; index 256 holds those that add nothing.
prefix_index: [257][]const u16 = @splat(&.{}),
suffix_index: [257][]const u16 = @splat(&.{}),
/// Suffix flags that appear in some suffix's continuation class, which
/// a second suffix level needs.
two_level: std.StaticBitSet(1 << 16) = .empty,
cond_elems: []const CondElem = &.{},
cond_chars: []const u21 = &.{},
opts: Options = .{},

pub const Entry = struct {
    off: u32,
    len: u32,
    set: u32,
    next: u32 = none,
};

const Set = struct { start: u32, len: u32 };

const Affix = struct {
    flag: Flag,
    cross: bool,
    strip: []const u8,
    add: []const u8,
    /// Continuation class: flags the affixed form carries.
    cont: u32,
    cond_start: u32,
    cond_len: u16,
};

const CondElem = struct {
    kind: enum(u8) { any, set, not },
    start: u32 = 0,
    len: u32 = 0,
};

const Rep = struct {
    from: []const u8,
    to: []const u8,
    start: bool,
    end: bool,
};

const Pattern = struct { end: []const u8, begin: []const u8 };

const RuleElem = struct {
    flag: Flag,
    quant: enum(u8) { one, star, optional },
};

const Options = struct {
    forbidden: Flag = 65510,
    nosuggest: ?Flag = null,
    keepcase: ?Flag = null,
    needaffix: ?Flag = null,
    onlyincompound: ?Flag = null,
    circumfix: ?Flag = null,
    compound: ?Flag = null,
    compound_begin: ?Flag = null,
    compound_middle: ?Flag = null,
    compound_end: ?Flag = null,
    compound_permit: ?Flag = null,
    compound_forbid: ?Flag = null,
    compound_min: u32 = 3,
    compound_max: u32 = 0,
    check_dup: bool = false,
    check_case: bool = false,
    check_triple: bool = false,
    check_rep: bool = false,
    check_sharps: bool = false,
    full_strip: bool = false,
    no_split_sugs: bool = false,
    max_ngram: u32 = 4,
    try_chars: []const u21 = &.{},
    key: []const u8 = "qwertyuiop|asdfghjkl|zxcvbnm",
    rep: []const Rep = &.{},
    /// MAP groups: each a list of related characters or strings.
    map: []const []const []const u8 = &.{},
    iconv: []const Rep = &.{},
    oconv: []const Rep = &.{},
    breaks: []const []const u8 = &.{ "-", "^-", "-$" },
    ignore: []const u21 = &.{},
    patterns: []const Pattern = &.{},
    rules: []const []const RuleElem = &.{},
};

pub fn deinit(d: *Dictionary) void {
    d.gpa.free(d.words);
    d.gpa.free(d.entries);
    d.gpa.free(d.slots);
    d.gpa.free(d.flags);
    d.gpa.free(d.sets);
    d.arena.deinit();
    d.* = undefined;
}

// Parsing -------------------------------------------------------------------

const FlagType = enum { char, long, num, utf8 };

const Parser = struct {
    gpa: Allocator,
    a: Allocator,
    flag_type: FlagType = .char,
    flags: std.ArrayList(Flag) = .empty,
    sets: std.ArrayList(Set) = .empty,
    set_ids: std.StringHashMapUnmanaged(u32) = .empty,
    aliases: std.ArrayList(u32) = .empty,
    upcase_sets: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    scratch: std.ArrayList(Flag) = .empty,
    cond_elems: std.ArrayList(CondElem) = .empty,
    cond_chars: std.ArrayList(u21) = .empty,

    fn deinit(p: *Parser) void {
        p.flags.deinit(p.gpa);
        p.sets.deinit(p.gpa);
        p.set_ids.deinit(p.gpa);
        p.aliases.deinit(p.gpa);
        p.upcase_sets.deinit(p.gpa);
        p.scratch.deinit(p.gpa);
    }

    /// The flags a flag field spells, in the dictionary's flag type.
    fn decodeFlags(p: *Parser, s: []const u8) Error![]Flag {
        p.scratch.clearRetainingCapacity();
        switch (p.flag_type) {
            .char => for (s) |b| try p.scratch.append(p.gpa, b),
            .long => {
                var i: usize = 0;
                while (i + 1 < s.len) : (i += 2) try p.scratch.append(p.gpa, @as(Flag, s[i]) << 8 | s[i + 1]);
                if (i < s.len) try p.scratch.append(p.gpa, @as(Flag, s[i]) << 8);
            },
            .num => {
                var it = std.mem.tokenizeScalar(u8, s, ',');
                while (it.next()) |n| {
                    const v = std.fmt.parseInt(u32, std.mem.trim(u8, n, " "), 10) catch continue;
                    if (v == 0 or v > 65535) continue;
                    try p.scratch.append(p.gpa, @intCast(v));
                }
            },
            .utf8 => {
                var i: usize = 0;
                while (i < s.len) {
                    const cp, const n = case.decode(s, i);
                    i += n;
                    if (cp <= 0xffff) try p.scratch.append(p.gpa, @intCast(cp));
                }
            },
        }
        return p.scratch.items;
    }

    fn flag(p: *Parser, s: []const u8) Error!?Flag {
        const fl = try p.decodeFlags(s);
        return if (fl.len == 0) null else fl[0];
    }

    /// The set a flag field names: an alias number when AF is in use,
    /// else the flags themselves.
    fn set(p: *Parser, s: []const u8) Error!u32 {
        if (s.len == 0) return 0;
        if (p.aliases.items.len != 0) {
            if (std.fmt.parseInt(u32, s, 10)) |n| {
                return if (n >= 1 and n <= p.aliases.items.len) p.aliases.items[n - 1] else 0;
            } else |_| {}
        }
        if (p.set_ids.get(s)) |id| return id;
        const fl = try p.decodeFlags(s);
        std.mem.sort(Flag, fl, {}, std.sort.asc(Flag));
        const id = try p.intern(fl);
        try p.set_ids.put(p.gpa, try p.a.dupe(u8, s), id);
        return id;
    }

    fn intern(p: *Parser, fl: []const Flag) Error!u32 {
        if (fl.len == 0) return 0;
        const start: u32 = @intCast(p.flags.items.len);
        try p.flags.appendSlice(p.gpa, fl);
        try p.sets.append(p.gpa, .{ .start = start, .len = @intCast(fl.len) });
        return @intCast(p.sets.items.len - 1);
    }

    /// A set plus ONLYUPCASE, made once per set.
    fn withUpcase(p: *Parser, base: u32) Error!u32 {
        if (p.upcase_sets.get(base)) |id| return id;
        p.scratch.clearRetainingCapacity();
        const s = p.sets.items[base];
        try p.scratch.appendSlice(p.gpa, p.flags.items[s.start..][0..s.len]);
        try p.scratch.append(p.gpa, only_upcase);
        std.mem.sort(Flag, p.scratch.items, {}, std.sort.asc(Flag));
        const id = try p.intern(p.scratch.items);
        try p.upcase_sets.put(p.gpa, base, id);
        return id;
    }

    fn condition(p: *Parser, s: []const u8) Error!struct { u32, u16 } {
        const start: u32 = @intCast(p.cond_elems.items.len);
        if (std.mem.eql(u8, s, ".")) return .{ start, 0 };
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '[') {
                const close = std.mem.indexOfScalarPos(u8, s, i, ']') orelse return error.InvalidDictionary;
                var body = s[i + 1 .. close];
                var kind: @TypeOf(@as(CondElem, undefined).kind) = .set;
                if (body.len > 0 and body[0] == '^') {
                    kind = .not;
                    body = body[1..];
                }
                const cs: u32 = @intCast(p.cond_chars.items.len);
                var j: usize = 0;
                while (j < body.len) {
                    const cp, const n = case.decode(body, j);
                    j += n;
                    try p.cond_chars.append(p.gpa, cp);
                }
                try p.cond_elems.append(p.gpa, .{ .kind = kind, .start = cs, .len = @intCast(p.cond_chars.items.len - cs) });
                i = close + 1;
            } else if (s[i] == '.') {
                try p.cond_elems.append(p.gpa, .{ .kind = .any });
                i += 1;
            } else {
                const cp, const n = case.decode(s, i);
                i += n;
                const cs: u32 = @intCast(p.cond_chars.items.len);
                try p.cond_chars.append(p.gpa, cp);
                try p.cond_elems.append(p.gpa, .{ .kind = .set, .start = cs, .len = 1 });
            }
        }
        return .{ start, @intCast(p.cond_elems.items.len - start) };
    }
};

fn fields(line: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, line, " \t");
}

fn zero(s: []const u8) []const u8 {
    return if (std.mem.eql(u8, s, "0")) "" else s;
}

fn removeIgnored(a: Allocator, s: []const u8, ignore: []const u21) Error![]const u8 {
    if (ignore.len == 0) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const cp, const n = case.decode(s, i);
        if (std.mem.indexOfScalar(u21, ignore, cp) == null) try out.appendSlice(a, s[i..][0..n]);
        i += n;
    }
    return out.items;
}

fn codepoints(a: Allocator, s: []const u8) Error![]const u21 {
    var out: std.ArrayList(u21) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const cp, const n = case.decode(s, i);
        try out.append(a, cp);
        i += n;
    }
    return out.items;
}

/// A REP, ICONV, or OCONV pattern: `^` and `$` anchor it, and `_` in
/// REP's replacement stands for a space.
fn rep(a: Allocator, from_raw: []const u8, to_raw: []const u8, underscores: bool) Error!Rep {
    var from = from_raw;
    var r: Rep = .{ .from = "", .to = "", .start = false, .end = false };
    if (from.len > 1 and from[0] == '^') {
        r.start = true;
        from = from[1..];
    }
    if (from.len > 1 and from[from.len - 1] == '$') {
        r.end = true;
        from = from[0 .. from.len - 1];
    }
    r.from = try a.dupe(u8, from);
    const to = try a.dupe(u8, to_raw);
    if (underscores) for (to) |*c| {
        if (c.* == '_') c.* = ' ';
    };
    r.to = to;
    return r;
}

/// Parses an affix file and its word list (both read whole by the
/// caller), converting 8-bit encodings to UTF-8.
pub fn parse(gpa: Allocator, aff_bytes: []const u8, dic_bytes: []const u8) Error!Dictionary {
    var d: Dictionary = .{ .gpa = gpa, .arena = .init(gpa) };
    errdefer d.deinit();
    const a = d.arena.allocator();
    // SET comes first; everything else is read in its encoding.
    var set_name: []const u8 = "";
    {
        var lines = std.mem.splitScalar(u8, aff_bytes, '\n');
        while (lines.next()) |raw| {
            var f = fields(raw);
            const key = f.next() orelse continue;
            if (std.mem.eql(u8, key, "SET")) {
                set_name = std.mem.trimEnd(u8, f.next() orelse "", "\r");
                break;
            }
        }
    }
    const aff, const aff_owned = try encoding.toUtf8(gpa, aff_bytes, set_name);
    defer if (aff_owned) gpa.free(aff);
    const dic, const dic_owned = try encoding.toUtf8(gpa, dic_bytes, set_name);
    defer if (dic_owned) gpa.free(dic);

    var p: Parser = .{ .gpa = gpa, .a = a };
    defer p.deinit();
    try p.sets.append(gpa, .{ .start = 0, .len = 0 });
    var prefixes: std.ArrayList(Affix) = .empty;
    var suffixes: std.ArrayList(Affix) = .empty;
    var reps: std.ArrayList(Rep) = .empty;
    var iconv: std.ArrayList(Rep) = .empty;
    var oconv: std.ArrayList(Rep) = .empty;
    var maps: std.ArrayList([]const []const u8) = .empty;
    var breaks: std.ArrayList([]const u8) = .empty;
    var breaks_given = false;
    var patterns: std.ArrayList(Pattern) = .empty;
    var rules: std.ArrayList([]const RuleElem) = .empty;
    const o = &d.opts;

    // FLAG may follow lines that use flags; find it first.
    {
        var lines = std.mem.splitScalar(u8, aff, '\n');
        while (lines.next()) |raw| {
            var f = fields(std.mem.trimEnd(u8, raw, "\r"));
            const key = f.next() orelse continue;
            if (!std.mem.eql(u8, key, "FLAG")) continue;
            const v = f.next() orelse continue;
            p.flag_type = if (std.mem.eql(u8, v, "long")) .long else if (std.mem.eql(u8, v, "num")) .num else if (std.ascii.eqlIgnoreCase(v, "UTF-8")) .utf8 else .char;
        }
    }

    var lines = std.mem.splitScalar(u8, aff, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var f = fields(line);
        const key = f.next() orelse continue;
        if (key[0] == '#') continue;
        const v = f.next() orelse "";
        const eql = std.mem.eql;
        if (eql(u8, key, "PFX") or eql(u8, key, "SFX")) {
            const prefix = key[0] == 'P';
            const cross_s = f.next() orelse continue;
            const count_s = f.next() orelse continue;
            const fl = try p.flag(v) orelse continue;
            const cross = cross_s.len > 0 and cross_s[0] == 'Y';
            const n = std.fmt.parseInt(u32, count_s, 10) catch continue;
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const entry = std.mem.trimEnd(u8, lines.next() orelse break, "\r");
                var ef = fields(entry);
                _ = ef.next(); // PFX or SFX
                _ = ef.next(); // the flag
                const strip_s = ef.next() orelse continue;
                const add_field = ef.next() orelse continue;
                const cond_s = ef.next() orelse ".";
                const slash = std.mem.indexOfScalar(u8, add_field, '/');
                const add_s = zero(if (slash) |s| add_field[0..s] else add_field);
                const cont = if (slash) |s| try p.set(add_field[s + 1 ..]) else 0;
                const cond_start, const cond_len = p.condition(cond_s) catch continue;
                const affix: Affix = .{
                    .flag = fl,
                    .cross = cross,
                    .strip = try removeIgnored(a, try a.dupe(u8, zero(strip_s)), o.ignore),
                    .add = try removeIgnored(a, try a.dupe(u8, add_s), o.ignore),
                    .cont = cont,
                    .cond_start = cond_start,
                    .cond_len = cond_len,
                };
                if (prefix) try prefixes.append(a, affix) else try suffixes.append(a, affix);
            }
        } else if (eql(u8, key, "AF")) {
            // "AF n", then n lines "AF flags".
            if (std.fmt.parseInt(u32, v, 10)) |n| {
                var k: u32 = 0;
                while (k < n) : (k += 1) {
                    var af = fields(std.mem.trimEnd(u8, lines.next() orelse break, "\r"));
                    _ = af.next();
                    const s = af.next() orelse "";
                    // Aliases are themselves flags, not alias numbers.
                    const saved = p.aliases.items.len;
                    p.aliases.items.len = 0;
                    const id = try p.set(s);
                    p.aliases.items.len = saved;
                    try p.aliases.append(gpa, id);
                }
            } else |_| {}
        } else if (eql(u8, key, "AM")) {
            if (std.fmt.parseInt(u32, v, 10)) |n| {
                var k: u32 = 0;
                while (k < n) : (k += 1) _ = lines.next() orelse break;
            } else |_| {}
        } else if (eql(u8, key, "REP") or eql(u8, key, "ICONV") or eql(u8, key, "OCONV")) {
            const to = f.next() orelse continue; // the count line has no second field
            const list = if (key[0] == 'R') &reps else if (key[0] == 'I') &iconv else &oconv;
            try list.append(a, try rep(a, v, to, key[0] == 'R'));
        } else if (eql(u8, key, "MAP")) {
            if (f.next() != null or std.fmt.parseInt(u32, v, 10) catch null != null) continue;
            var group: std.ArrayList([]const u8) = .empty;
            var i: usize = 0;
            while (i < v.len) {
                if (v[i] == '(') {
                    const close = std.mem.indexOfScalarPos(u8, v, i, ')') orelse break;
                    try group.append(a, try a.dupe(u8, v[i + 1 .. close]));
                    i = close + 1;
                } else {
                    const n = case.decode(v, i)[1];
                    try group.append(a, try a.dupe(u8, v[i..][0..n]));
                    i += n;
                }
            }
            try maps.append(a, group.items);
        } else if (eql(u8, key, "BREAK")) {
            breaks_given = true;
            if (std.fmt.parseInt(u32, v, 10) catch null == null and v.len > 0) try breaks.append(a, try a.dupe(u8, v));
        } else if (eql(u8, key, "CHECKCOMPOUNDPATTERN")) {
            const begin = f.next() orelse continue;
            const end_s = if (std.mem.indexOfScalar(u8, v, '/')) |s| v[0..s] else v;
            const begin_s = if (std.mem.indexOfScalar(u8, begin, '/')) |s| begin[0..s] else begin;
            try patterns.append(a, .{ .end = try a.dupe(u8, zero(end_s)), .begin = try a.dupe(u8, zero(begin_s)) });
        } else if (eql(u8, key, "COMPOUNDRULE")) {
            if (std.fmt.parseInt(u32, v, 10) catch null != null) continue;
            var elems: std.ArrayList(RuleElem) = .empty;
            var i: usize = 0;
            while (i < v.len) {
                var fl: Flag = 0;
                if (v[i] == '(') {
                    const close = std.mem.indexOfScalarPos(u8, v, i, ')') orelse break;
                    fl = try p.flag(v[i + 1 .. close]) orelse break;
                    i = close + 1;
                } else {
                    const n: usize = if (p.flag_type == .long) 2 else case.decode(v, i)[1];
                    fl = try p.flag(v[i..@min(v.len, i + n)]) orelse break;
                    i += n;
                }
                var q: @TypeOf(@as(RuleElem, undefined).quant) = .one;
                if (i < v.len and v[i] == '*') {
                    q = .star;
                    i += 1;
                } else if (i < v.len and v[i] == '?') {
                    q = .optional;
                    i += 1;
                }
                try elems.append(a, .{ .flag = fl, .quant = q });
            }
            try rules.append(a, elems.items);
        } else if (eql(u8, key, "TRY")) {
            o.try_chars = try codepoints(a, v);
        } else if (eql(u8, key, "KEY")) {
            o.key = try a.dupe(u8, v);
        } else if (eql(u8, key, "IGNORE")) {
            o.ignore = try codepoints(a, v);
        } else if (eql(u8, key, "FORBIDDENWORD")) {
            if (try p.flag(v)) |fl| o.forbidden = fl;
        } else if (eql(u8, key, "NOSUGGEST")) {
            o.nosuggest = try p.flag(v);
        } else if (eql(u8, key, "KEEPCASE")) {
            o.keepcase = try p.flag(v);
        } else if (eql(u8, key, "NEEDAFFIX") or eql(u8, key, "PSEUDOROOT")) {
            o.needaffix = try p.flag(v);
        } else if (eql(u8, key, "ONLYINCOMPOUND")) {
            o.onlyincompound = try p.flag(v);
        } else if (eql(u8, key, "CIRCUMFIX")) {
            o.circumfix = try p.flag(v);
        } else if (eql(u8, key, "COMPOUNDFLAG")) {
            o.compound = try p.flag(v);
        } else if (eql(u8, key, "COMPOUNDBEGIN")) {
            o.compound_begin = try p.flag(v);
        } else if (eql(u8, key, "COMPOUNDMIDDLE")) {
            o.compound_middle = try p.flag(v);
        } else if (eql(u8, key, "COMPOUNDEND") or eql(u8, key, "COMPOUNDLAST")) {
            o.compound_end = try p.flag(v);
        } else if (eql(u8, key, "COMPOUNDPERMITFLAG")) {
            o.compound_permit = try p.flag(v);
        } else if (eql(u8, key, "COMPOUNDFORBIDFLAG")) {
            o.compound_forbid = try p.flag(v);
        } else if (eql(u8, key, "COMPOUNDMIN")) {
            o.compound_min = @max(1, std.fmt.parseInt(u32, v, 10) catch 3);
        } else if (eql(u8, key, "COMPOUNDWORDMAX")) {
            o.compound_max = std.fmt.parseInt(u32, v, 10) catch 0;
        } else if (eql(u8, key, "CHECKCOMPOUNDDUP")) {
            o.check_dup = true;
        } else if (eql(u8, key, "CHECKCOMPOUNDCASE")) {
            o.check_case = true;
        } else if (eql(u8, key, "CHECKCOMPOUNDTRIPLE")) {
            o.check_triple = true;
        } else if (eql(u8, key, "CHECKCOMPOUNDREP")) {
            o.check_rep = true;
        } else if (eql(u8, key, "CHECKSHARPS")) {
            o.check_sharps = true;
        } else if (eql(u8, key, "FULLSTRIP")) {
            o.full_strip = true;
        } else if (eql(u8, key, "NOSPLITSUGS")) {
            o.no_split_sugs = true;
        } else if (eql(u8, key, "MAXNGRAMSUGS")) {
            o.max_ngram = std.fmt.parseInt(u32, v, 10) catch 4;
        }
    }
    o.rep = reps.items;
    o.iconv = iconv.items;
    o.oconv = oconv.items;
    o.map = maps.items;
    if (breaks_given) o.breaks = breaks.items;
    o.patterns = patterns.items;
    o.rules = rules.items;
    d.prefixes = prefixes.items;
    d.suffixes = suffixes.items;
    if (prefixes.items.len > 65535 or suffixes.items.len > 65535) return error.InvalidDictionary;

    try d.readWords(&p, dic);
    d.flags = try p.flags.toOwnedSlice(gpa);
    d.sets = try p.sets.toOwnedSlice(gpa);
    d.cond_elems = try a.dupe(CondElem, p.cond_elems.items);
    d.cond_chars = try a.dupe(u21, p.cond_chars.items);
    p.cond_elems.deinit(gpa);
    p.cond_chars.deinit(gpa);
    try d.index();
    return d;
}

fn readWords(d: *Dictionary, p: *Parser, dic: []const u8) Error!void {
    const gpa = d.gpa;
    var words: std.ArrayList(u8) = try .initCapacity(gpa, dic.len);
    defer words.deinit(gpa);
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    var lines = std.mem.splitScalar(u8, dic, '\n');
    var first = true;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, "\r");
        if (first and std.mem.startsWith(u8, line, "\xef\xbb\xbf")) line = line[3..];
        // Lines that start with a tab are comments, and so are empty ones.
        if (line.len == 0 or line[0] == '\t') continue;
        if (first) {
            first = false;
            if (std.fmt.parseInt(u32, std.mem.trim(u8, line, " "), 10)) |_| continue else |_| {}
        }
        // The word, then "/flags", then morphological fields after a tab
        // or a space before "xx:"; the first unescaped slash after the
        // word's first character starts the flags.
        var word_end = line.len;
        var slash: ?usize = null;
        var i: usize = 1;
        while (i < line.len) : (i += 1) {
            const ch = line[i];
            if (ch == '\\' and i + 1 < line.len and line[i + 1] == '/') {
                i += 1;
                continue;
            }
            if (ch == '/' and slash == null) {
                slash = i;
                continue;
            }
            if (ch == '\t' or (ch == ' ' and (slash != null or (i + 3 < line.len and line[i + 3] == ':')))) {
                word_end = i;
                break;
            }
        }
        const word_raw = std.mem.trimEnd(u8, line[0..(slash orelse word_end)], " ");
        const flags_s = if (slash) |s| line[s + 1 .. word_end] else "";
        buf.clearRetainingCapacity();
        var j: usize = 0;
        while (j < word_raw.len) : (j += 1) {
            if (word_raw[j] == '\\' and j + 1 < word_raw.len and word_raw[j + 1] == '/') continue;
            try buf.append(gpa, word_raw[j]);
        }
        const word = try removeIgnored(d.arena.allocator(), buf.items, d.opts.ignore);
        if (word.len == 0 or word.len > max_word) continue;
        const set = try p.set(flags_s);
        try addEntry(&words, &entries, gpa, word, set);
        // Mixed-case words, and all-caps words with affixes, get a hidden
        // capitalized homonym that only all-caps text matches, so
        // "OpenOffice" allows "OPENOFFICE" and "CIA/S" allows "CIA'S".
        const ct = case.captype(word);
        const has_flags = p.sets.items[set].len != 0;
        if ((ct == .mixed or ct == .mixed_initial or (ct == .all and has_flags)) and !setHas(p, set, d.opts.forbidden)) {
            var lowered: std.ArrayList(u8) = .empty;
            defer lowered.deinit(gpa);
            try case.convert(&lowered, gpa, word, .lower);
            var capital: std.ArrayList(u8) = .empty;
            defer capital.deinit(gpa);
            try case.convert(&capital, gpa, lowered.items, .capitalize);
            try addEntry(&words, &entries, gpa, capital.items, try p.withUpcase(set));
        }
    }
    d.words = try words.toOwnedSlice(gpa);
    d.entries = try entries.toOwnedSlice(gpa);
}

fn addEntry(words: *std.ArrayList(u8), entries: *std.ArrayList(Entry), gpa: Allocator, word: []const u8, set: u32) Error!void {
    const off: u32 = @intCast(words.items.len);
    try words.appendSlice(gpa, word);
    try entries.append(gpa, .{ .off = off, .len = @intCast(word.len), .set = set });
}

fn hash(word: []const u8) u64 {
    return std.hash.Wyhash.hash(0, word);
}

/// Builds the word table and the affix indexes.
fn index(d: *Dictionary) Error!void {
    const gpa = d.gpa;
    var cap: usize = 16;
    while (cap < d.entries.len * 2) cap *= 2;
    const slots = try gpa.alloc(u32, cap);
    @memset(slots, none);
    d.slots = slots;
    const entries: []Entry = @constCast(d.entries);
    // Homonyms keep the order of the word list: each word's last entry.
    const tails = try gpa.alloc(u32, entries.len);
    defer gpa.free(tails);
    for (entries, 0..) |e, ei| {
        const w = d.words[e.off..][0..e.len];
        var s = hash(w) & (cap - 1);
        while (true) : (s = (s + 1) & (cap - 1)) {
            if (slots[s] == none) {
                slots[s] = @intCast(ei);
                tails[ei] = @intCast(ei);
                break;
            }
            const head = slots[s];
            const hw = d.words[entries[head].off..][0..entries[head].len];
            if (std.mem.eql(u8, hw, w)) {
                entries[tails[head]].next = @intCast(ei);
                tails[head] = @intCast(ei);
                break;
            }
        }
    }
    const a = d.arena.allocator();
    for ([_]bool{ true, false }) |prefix| {
        const list = if (prefix) d.prefixes else d.suffixes;
        var buckets: [257]std.ArrayList(u16) = @splat(.empty);
        for (list, 0..) |af, i| {
            const b: usize = if (af.add.len == 0) 256 else if (prefix) af.add[0] else af.add[af.add.len - 1];
            try buckets[b].append(a, @intCast(i));
            if (!prefix) {
                const cs = d.sets[af.cont];
                for (d.flags[cs.start..][0..cs.len]) |fl| d.two_level.set(fl);
            }
        }
        for (&buckets, 0..) |*b, i| {
            if (prefix) d.prefix_index[i] = b.items else d.suffix_index[i] = b.items;
        }
    }
}

fn setHasIn(flags: []const Flag, sets: []const Set, set: u32, flag: Flag) bool {
    const s = sets[set];
    for (flags[s.start..][0..s.len]) |f| {
        if (f == flag) return true;
        if (f > flag) return false;
    }
    return false;
}

fn setHas(p: *const Parser, set: u32, flag: Flag) bool {
    return setHasIn(p.flags.items, p.sets.items, set, flag);
}

// Lookup and affixes --------------------------------------------------------

pub fn wordOf(d: *const Dictionary, e: u32) []const u8 {
    const en = d.entries[e];
    return d.words[en.off..][0..en.len];
}

/// The first entry spelled `word`, or `none`.
fn lookup(d: *const Dictionary, word: []const u8) u32 {
    if (d.slots.len == 0) return none;
    const mask = d.slots.len - 1;
    var s = hash(word) & mask;
    while (true) : (s = (s + 1) & mask) {
        const e = d.slots[s];
        if (e == none) return none;
        if (std.mem.eql(u8, d.wordOf(e), word)) return e;
    }
}

fn has(d: *const Dictionary, set: u32, flag: ?Flag) bool {
    const f = flag orelse return false;
    return setHasIn(d.flags, d.sets, set, f);
}

fn entryHas(d: *const Dictionary, e: u32, flag: ?Flag) bool {
    return d.has(d.entries[e].set, flag);
}

fn condMatches(d: *const Dictionary, af: *const Affix, stem: []const u8, suffix: bool) bool {
    if (af.cond_len == 0) return true;
    const elems = d.cond_elems[af.cond_start..][0..af.cond_len];
    // The code points the condition covers: the stem's last ones for a
    // suffix, its first ones for a prefix.
    var cps: [32]u21 = undefined;
    if (elems.len > cps.len) return false;
    if (suffix) {
        var i = stem.len;
        var k = elems.len;
        while (k > 0) {
            if (i == 0) return false;
            var start = i - 1;
            while (start > 0 and stem[start] & 0xc0 == 0x80) start -= 1;
            k -= 1;
            cps[k] = case.decode(stem, start)[0];
            i = start;
        }
    } else {
        var i: usize = 0;
        for (0..elems.len) |k| {
            if (i >= stem.len) return false;
            const cp, const n = case.decode(stem, i);
            cps[k] = cp;
            i += n;
        }
    }
    for (elems, cps[0..elems.len]) |el, cp| {
        const ok = switch (el.kind) {
            .any => true,
            .set => std.mem.indexOfScalar(u21, d.cond_chars[el.start..][0..el.len], cp) != null,
            .not => std.mem.indexOfScalar(u21, d.cond_chars[el.start..][0..el.len], cp) == null,
        };
        if (!ok) return false;
    }
    return true;
}

/// A way to read a word as a dictionary entry with affixes.
pub const Form = struct {
    root: u32,
    prefix: ?u16 = null,
    /// The suffix applied last.
    suffix: ?u16 = null,
    /// With two suffixes, the one applied first.
    inner: ?u16 = null,
};

/// Calls `v.visit(form)` for every reading of `word` as an entry with up
/// to one prefix and two suffixes, until it returns true.
fn forms(d: *const Dictionary, word: []const u8, v: anytype) bool {
    var e = d.lookup(word);
    while (e != none) : (e = d.entries[e].next) if (v.visit(.{ .root = e })) return true;
    if (word.len == 0) return false;
    var stem_buf: [max_word + 64]u8 = undefined;
    var stem2_buf: [max_word + 64]u8 = undefined;
    var root_buf: [max_word + 64]u8 = undefined;
    // Suffixes, alone, two deep, or with a prefix.
    for ([_]usize{ word[word.len - 1], 256 }) |bucket| for (d.suffix_index[bucket]) |si| {
        const s = &d.suffixes[si];
        if (!std.mem.endsWith(u8, word, s.add)) continue;
        if (word.len == s.add.len and !d.opts.full_strip) continue;
        const stem = joinSuffix(&stem_buf, word[0 .. word.len - s.add.len], s.strip) orelse continue;
        if (stem.len == 0 or !d.condMatches(s, stem, true)) continue;
        e = d.lookup(stem);
        while (e != none) : (e = d.entries[e].next) {
            if (d.entryHas(e, s.flag) and v.visit(.{ .root = e, .suffix = si })) return true;
        }
        if (d.two_level.isSet(s.flag)) {
            for ([_]usize{ stem[stem.len - 1], 256 }) |bucket2| for (d.suffix_index[bucket2]) |s1i| {
                const s1 = &d.suffixes[s1i];
                if (!d.has(s1.cont, s.flag) or !std.mem.endsWith(u8, stem, s1.add)) continue;
                if (stem.len == s1.add.len and !d.opts.full_strip) continue;
                const root = joinSuffix(&stem2_buf, stem[0 .. stem.len - s1.add.len], s1.strip) orelse continue;
                if (root.len == 0 or !d.condMatches(s1, root, true)) continue;
                e = d.lookup(root);
                while (e != none) : (e = d.entries[e].next) {
                    if (d.entryHas(e, s1.flag) and v.visit(.{ .root = e, .suffix = si, .inner = s1i })) return true;
                }
                if (s1.cross) if (d.prefixed(root, &root_buf, v, .{ .root = 0, .suffix = si, .inner = s1i })) return true;
            };
        }
        if (s.cross) if (d.prefixed(stem, &root_buf, v, .{ .root = 0, .suffix = si })) return true;
    };
    // Prefixes alone.
    return d.prefixed(word, &root_buf, v, .{ .root = 0 });
}

/// Readings of `word` (already stripped of `with`'s suffixes) with a
/// prefix: cross products need both affixes to allow them.
fn prefixed(d: *const Dictionary, word: []const u8, buf: []u8, v: anytype, with: Form) bool {
    if (word.len == 0) return false;
    const outer: ?*const Affix = if (with.inner) |i| &d.suffixes[i] else if (with.suffix) |i| &d.suffixes[i] else null;
    for ([_]usize{ word[0], 256 }) |bucket| for (d.prefix_index[bucket]) |pi| {
        const p = &d.prefixes[pi];
        if (outer != null and !p.cross) continue;
        if (!std.mem.startsWith(u8, word, p.add)) continue;
        if (word.len == p.add.len and !d.opts.full_strip) continue;
        const rest = word[p.add.len..];
        if (p.strip.len + rest.len > buf.len) continue;
        @memcpy(buf[0..p.strip.len], p.strip);
        @memcpy(buf[p.strip.len..][0..rest.len], rest);
        const root = buf[0 .. p.strip.len + rest.len];
        if (root.len == 0 or !d.condMatches(p, root, false)) continue;
        var e = d.lookup(root);
        while (e != none) : (e = d.entries[e].next) {
            const has_p = d.entryHas(e, p.flag) or (outer != null and d.has(outer.?.cont, p.flag));
            const has_s = if (outer) |s| d.entryHas(e, s.flag) or d.has(p.cont, s.flag) else true;
            if (!has_p or !has_s) continue;
            var f = with;
            f.root = e;
            f.prefix = pi;
            if (v.visit(f)) return true;
        }
    };
    return false;
}

fn joinSuffix(buf: []u8, base: []const u8, strip: []const u8) ?[]const u8 {
    if (base.len + strip.len > buf.len) return null;
    @memcpy(buf[0..base.len], base);
    @memcpy(buf[base.len..][0..strip.len], strip);
    return buf[0 .. base.len + strip.len];
}

/// Whether the form, its root, or any of its affixes' continuation
/// classes has `flag`.
fn formHas(d: *const Dictionary, f: Form, flag: ?Flag) bool {
    const fl = flag orelse return false;
    if (d.entryHas(f.root, fl)) return true;
    if (f.prefix) |i| if (d.has(d.prefixes[i].cont, fl)) return true;
    if (f.suffix) |i| if (d.has(d.suffixes[i].cont, fl)) return true;
    if (f.inner) |i| if (d.has(d.suffixes[i].cont, fl)) return true;
    return false;
}

fn affixCount(f: Form) u32 {
    return @as(u32, @intFromBool(f.prefix != null)) + @intFromBool(f.suffix != null) + @intFromBool(f.inner != null);
}

/// NEEDAFFIX and CIRCUMFIX, which hold for a form wherever it stands.
fn affixesValid(d: *const Dictionary, f: Form) bool {
    const o = &d.opts;
    const n = affixCount(f);
    if (o.needaffix) |na| {
        // Affixes that need another affix are not the only one, and a
        // root that needs one gets one that does not.
        var standalone: u32 = 0;
        inline for (.{ "prefix", "suffix", "inner" }) |field| if (@field(f, field)) |i| {
            const af = if (comptime std.mem.eql(u8, field, "prefix")) &d.prefixes[i] else &d.suffixes[i];
            if (d.has(af.cont, na)) {
                if (n < 2) return false;
            } else standalone += 1;
        };
        if (d.entryHas(f.root, na) and standalone == 0) return false;
    }
    // A suffix and a prefix both have CIRCUMFIX or neither; a prefix
    // alone may have it, as in Hunspell.
    if (o.circumfix) |cf| if (f.suffix != null) {
        const p = if (f.prefix) |i| d.has(d.prefixes[i].cont, cf) else false;
        var s = d.has(d.suffixes[f.suffix.?].cont, cf);
        if (f.inner) |i| s = s or d.has(d.suffixes[i].cont, cf);
        if (p != s) return false;
    };
    return true;
}

// Checking ------------------------------------------------------------------

const Mode = struct {
    /// Suggesting for a word in capitals, so capitalized candidates
    /// stand for all-caps ones.
    upcase: bool = false,
    /// Capitalized input: hidden capitalized homonyms of mixed-case
    /// words do not match it (only all-caps input should).
    initcap: bool = false,
    /// Suggesting: NOSUGGEST words are not offered.
    suggest: bool = false,
    /// Try compounds.
    compounds: bool = true,
};

const Outcome = enum { no, yes, forbidden };

/// Standalone readings: the first valid or forbidden one decides.
const Standalone = struct {
    d: *const Dictionary,
    mode: Mode,
    outcome: Outcome = .no,
    keepcase: bool = false,

    fn visit(s: *Standalone, f: Form) bool {
        const d = s.d;
        const o = &d.opts;
        if (!d.affixesValid(f)) return false;
        if (d.entryHas(f.root, o.forbidden)) {
            s.outcome = .forbidden;
            return true;
        }
        if (d.formHas(f, o.onlyincompound)) return false;
        if (affixCount(f) == 0 and d.entryHas(f.root, o.needaffix)) return false;
        if (d.entryHas(f.root, only_upcase) and s.mode.initcap) return false;
        if (s.mode.suggest and d.formHas(f, o.nosuggest)) return false;
        s.outcome = .yes;
        s.keepcase = d.entryHas(f.root, o.keepcase);
        return true;
    }
};

const Position = enum { begin, middle, end };

/// Readings valid as a part of a compound at `pos`.
const Part = struct {
    d: *const Dictionary,
    pos: Position,
    suggest: bool,
    found: bool = false,

    fn visit(s: *Part, f: Form) bool {
        const d = s.d;
        const o = &d.opts;
        if (d.entryHas(f.root, o.forbidden) or d.entryHas(f.root, only_upcase)) return false;
        if (!d.affixesValid(f)) return false;
        if (affixCount(f) == 0 and d.entryHas(f.root, o.needaffix)) return false;
        if (s.suggest and d.formHas(f, o.nosuggest)) return false;
        const pos_flag = switch (s.pos) {
            .begin => o.compound_begin,
            .middle => o.compound_middle,
            .end => o.compound_end,
        };
        if (!d.formHas(f, o.compound) and !d.formHas(f, pos_flag)) return false;
        if (f.prefix) |i| {
            const p = &d.prefixes[i];
            if (s.pos != .begin and !d.has(p.cont, o.compound_permit)) return false;
            if (d.has(p.cont, o.compound_forbid)) return false;
        }
        inline for (.{ "suffix", "inner" }) |field| if (@field(f, field)) |i| {
            const sf = &d.suffixes[i];
            if (s.pos != .end and !d.has(sf.cont, o.compound_permit)) return false;
            if (d.has(sf.cont, o.compound_forbid)) return false;
        };
        s.found = true;
        return true;
    }
};

fn checkStandalone(d: *const Dictionary, word: []const u8, mode: Mode) struct { Outcome, bool } {
    var v: Standalone = .{ .d = d, .mode = mode };
    _ = d.forms(word, &v);
    return .{ v.outcome, v.keepcase };
}

fn hasCompounding(d: *const Dictionary) bool {
    const o = &d.opts;
    return o.compound != null or o.compound_begin != null or o.rules.len != 0;
}

/// A word, its case as given: a dictionary form, or a compound.
fn checkWord(d: *const Dictionary, word: []const u8, mode: Mode) struct { Outcome, bool } {
    const r = d.checkStandalone(word, mode);
    if (r[0] != .no or !mode.compounds or !d.hasCompounding()) return r;
    if (d.compound(word, mode)) return .{ .yes, false };
    return r;
}

fn compound(d: *const Dictionary, word: []const u8, mode: Mode) bool {
    const o = &d.opts;
    if (o.compound != null or o.compound_begin != null) {
        if (d.compoundParts(word, 0, "", mode.suggest)) {
            if (!o.check_rep or !d.repMakesWord(word)) return true;
        }
    }
    if (o.rules.len != 0) for (o.rules) |rule| {
        if (d.matchRule(word, rule, 0, 0)) return true;
    };
    return false;
}

/// Whether `word` splits into parts valid at their positions, the first
/// at `depth` parts in, after `prev`.
fn compoundParts(d: *const Dictionary, word: []const u8, depth: u32, prev: []const u8, suggesting: bool) bool {
    const o = &d.opts;
    const limit: u32 = if (o.compound_max != 0) o.compound_max else 12;
    if (depth + 2 > limit) return false;
    var i: usize = 0;
    var chars: u32 = 0;
    while (i < word.len) {
        i += case.decode(word, i)[1];
        chars += 1;
        if (i >= word.len) break;
        if (chars < o.compound_min) continue;
        const first = word[0..i];
        const rest = word[i..];
        if (case.count(rest) < o.compound_min) break;
        if (o.check_dup and std.mem.eql(u8, first, prev)) continue;
        var part: Part = .{ .d = d, .pos = if (depth == 0) .begin else .middle, .suggest = suggesting };
        _ = d.forms(first, &part);
        if (!part.found) continue;
        if (!d.boundaryOk(first, rest)) continue;
        var end: Part = .{ .d = d, .pos = .end, .suggest = suggesting };
        _ = d.forms(rest, &end);
        if (end.found and !(o.check_dup and std.mem.eql(u8, first, rest))) return true;
        if (d.compoundParts(rest, depth + 1, first, suggesting)) return true;
    }
    return false;
}

/// CHECKCOMPOUNDCASE, CHECKCOMPOUNDTRIPLE, and CHECKCOMPOUNDPATTERN at
/// the boundary between two parts.
fn boundaryOk(d: *const Dictionary, first: []const u8, rest: []const u8) bool {
    const o = &d.opts;
    if (o.check_case) {
        var start = first.len - 1;
        while (start > 0 and first[start] & 0xc0 == 0x80) start -= 1;
        const last = case.decode(first, start)[0];
        const next = case.decode(rest, 0)[0];
        if ((case.isUpper(last) or case.isUpper(next)) and last != '-' and next != '-') return false;
    }
    if (o.check_triple and first.len >= 1 and rest.len >= 1) {
        const a = first[first.len - 1];
        if (a == rest[0] and ((first.len >= 2 and first[first.len - 2] == a) or (rest.len >= 2 and rest[1] == a))) return false;
    }
    for (o.patterns) |pat| {
        if (std.mem.endsWith(u8, first, pat.end) and std.mem.startsWith(u8, rest, pat.begin)) return false;
    }
    return true;
}

/// CHECKCOMPOUNDREP: a compound that a REP replacement turns into a
/// dictionary word is probably that word misspelled.
fn repMakesWord(d: *const Dictionary, word: []const u8) bool {
    var buf: [max_word * 2]u8 = undefined;
    for (d.opts.rep) |r| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, word, at, r.from)) |i| : (at = i + 1) {
            if (r.start and i != 0) break;
            if (r.end and i + r.from.len != word.len) continue;
            const n = i + r.to.len + word.len - i - r.from.len;
            if (n > buf.len) continue;
            @memcpy(buf[0..i], word[0..i]);
            @memcpy(buf[i..][0..r.to.len], r.to);
            @memcpy(buf[i + r.to.len ..][0 .. word.len - i - r.from.len], word[i + r.from.len ..]);
            if (d.checkStandalone(buf[0..n], .{})[0] == .yes) return true;
        }
    }
    return false;
}

/// COMPOUNDRULE: `word` from `at` matches `rule` from element `ri`, each
/// part a dictionary word (no affixes) with the element's flag.
fn matchRule(d: *const Dictionary, word: []const u8, rule: []const RuleElem, ri: usize, at: usize) bool {
    if (ri == rule.len) return at == word.len;
    const el = rule[ri];
    if (el.quant != .one and d.matchRule(word, rule, ri + 1, at)) return true;
    if (at == word.len) return false;
    var i = at;
    var chars: u32 = 0;
    while (i < word.len) {
        i += case.decode(word, i)[1];
        chars += 1;
        if (chars < d.opts.compound_min and i < word.len) continue;
        var e = d.lookup(word[at..i]);
        var ok = false;
        while (e != none) : (e = d.entries[e].next) {
            if (d.entryHas(e, el.flag) and !d.entryHas(e, d.opts.forbidden)) {
                ok = true;
                break;
            }
        }
        if (!ok) continue;
        const next = if (el.quant == .star) ri else ri + 1;
        if (d.matchRule(word, rule, next, i)) return true;
        if (el.quant == .star and d.matchRule(word, rule, ri + 1, i)) return true;
    }
    return false;
}

fn convert(buf: []u8, word: []const u8, table: []const Rep) ?[]const u8 {
    if (table.len == 0) return word;
    var n: usize = 0;
    var i: usize = 0;
    while (i < word.len) {
        // The longest pattern that matches here.
        var best: ?*const Rep = null;
        for (table) |*r| {
            if (r.from.len == 0 or !std.mem.startsWith(u8, word[i..], r.from)) continue;
            if (r.start and i != 0) continue;
            if (r.end and i + r.from.len != word.len) continue;
            if (best == null or r.from.len > best.?.from.len) best = r;
        }
        if (best) |r| {
            if (n + r.to.len > buf.len) return null;
            @memcpy(buf[n..][0..r.to.len], r.to);
            n += r.to.len;
            i += r.from.len;
        } else {
            if (n == buf.len) return null;
            buf[n] = word[i];
            n += 1;
            i += 1;
        }
    }
    return buf[0..n];
}

fn isNumber(w: []const u8) bool {
    if (w.len == 0 or !std.ascii.isDigit(w[0])) return false;
    var prev_sep = false;
    for (w) |ch| {
        if (std.ascii.isDigit(ch)) {
            prev_sep = false;
        } else if (ch == '.' or ch == ',' or ch == '-') {
            if (prev_sep) return false;
            prev_sep = true;
        } else return false;
    }
    return !prev_sep;
}

/// Whether `word` is spelled right.
pub fn check(d: *const Dictionary, word: []const u8) bool {
    return d.checkMode(word, .{}, 0);
}

fn checkMode(d: *const Dictionary, word_in: []const u8, mode: Mode, depth: u32) bool {
    if (word_in.len == 0 or word_in.len > max_word) return true;
    if (!std.unicode.utf8ValidateSlice(word_in)) return false;
    var conv_buf: [max_word * 2]u8 = undefined;
    var ign_buf: [max_word * 2]u8 = undefined;
    var word = convert(&conv_buf, word_in, d.opts.iconv) orelse return true;
    if (d.opts.ignore.len != 0) {
        var n: usize = 0;
        var i: usize = 0;
        while (i < word.len) {
            const cp, const len = case.decode(word, i);
            if (std.mem.indexOfScalar(u21, d.opts.ignore, cp) == null) {
                @memcpy(ign_buf[n..][0..len], word[i..][0..len]);
                n += len;
            }
            i += len;
        }
        word = ign_buf[0..n];
    }
    // Trailing dots: an abbreviation is right with one dot or none.
    var base = word;
    while (base.len > 0 and base[base.len - 1] == '.') base = base[0 .. base.len - 1];
    if (base.len == 0) return true;
    if (isNumber(base)) return true;
    const ct = case.captype(base);
    if (d.checkCased(base, ct, mode)) return true;
    if (base.len < word.len) {
        var dot_buf: [max_word + 1]u8 = undefined;
        @memcpy(dot_buf[0..base.len], base);
        dot_buf[base.len] = '.';
        if (d.checkCased(dot_buf[0 .. base.len + 1], ct, mode)) return true;
    }
    // BREAK: parts on either side of a break pattern each right. Not
    // for suggestions, which would offer "Us-a" for "Usa".
    if (depth < 8 and !mode.suggest) for (d.opts.breaks) |pat| {
        if (pat.len > 1 and pat[0] == '^') {
            if (std.mem.startsWith(u8, base, pat[1..]) and base.len > pat.len - 1)
                if (d.checkMode(base[pat.len - 1 ..], mode, depth + 1)) return true;
        } else if (pat.len > 1 and pat[pat.len - 1] == '$') {
            if (std.mem.endsWith(u8, base, pat[0 .. pat.len - 1]) and base.len > pat.len - 1)
                if (d.checkMode(base[0 .. base.len - (pat.len - 1)], mode, depth + 1)) return true;
        } else if (std.mem.indexOf(u8, base, pat)) |i| {
            if (i > 0 and i + pat.len < base.len and
                d.checkMode(base[0..i], mode, depth + 1) and d.checkMode(base[i + pat.len ..], mode, depth + 1)) return true;
        }
    };
    return false;
}

fn checkCased(d: *const Dictionary, word: []const u8, ct: case.Captype, mode: Mode) bool {
    var buf: [max_word * 2]u8 = undefined;
    var buf2: [max_word * 2]u8 = undefined;
    switch (ct) {
        .none, .mixed, .mixed_initial => return d.checkWord(word, mode)[0] == .yes,
        .initial => {
            var m = mode;
            // Suggestions for a word in capitals are capitalized here and
            // shown in capitals.
            m.initcap = !mode.upcase;
            const r = d.checkWord(word, m);
            if (r[0] != .no) return r[0] == .yes;
            const lower = case.convertBuf(&buf, word, .lower) orelse return false;
            const l = d.checkWord(lower, m);
            return l[0] == .yes and !l[1];
        },
        .all => {
            const m = mode;
            const r = d.checkWord(word, m);
            if (r[0] != .no) return r[0] == .yes;
            const lower = case.convertBuf(&buf, word, .lower) orelse return false;
            // Elided articles in capitals, as in French and Italian:
            // "D'ORANGE" is "d'Orange" or "D'Orange".
            if (std.mem.indexOfScalar(u8, lower, '\'')) |apos| if (apos + 1 < lower.len) {
                var ebuf: [max_word * 2]u8 = undefined;
                const rest = case.convertBuf(ebuf[apos + 1 ..], lower[apos + 1 ..], .capitalize) orelse return false;
                @memcpy(ebuf[0 .. apos + 1], lower[0 .. apos + 1]);
                const elided = ebuf[0 .. apos + 1 + rest.len];
                if (d.checkWord(elided, m)[0] == .yes) return true;
                var cbuf: [max_word * 2]u8 = undefined;
                const both = case.convertBuf(&cbuf, elided, .capitalize) orelse return false;
                if (d.checkWord(both, m)[0] == .yes) return true;
            };
            if (d.opts.check_sharps and std.mem.indexOf(u8, lower, "ss") != null) {
                if (d.sharps(lower, 0, false, m)) return true;
            }
            const capital = case.convertBuf(&buf2, lower, .capitalize) orelse return false;
            const c = d.checkWord(capital, m);
            if (c[0] == .yes and !c[1]) return true;
            if (c[0] == .forbidden) return false;
            const l = d.checkWord(lower, m);
            return l[0] == .yes and !l[1];
        },
    }
}

/// CHECKSHARPS: "STRASSE" is "Straße" in capitals, so each "ss" of the
/// lowered word may stand for ß (KEEPCASE words included).
fn sharps(d: *const Dictionary, word: []const u8, from: usize, changed: bool, mode: Mode) bool {
    const i = std.mem.indexOfPos(u8, word, from, "ss") orelse {
        if (!changed) return false;
        if (d.checkWord(word, mode)[0] == .yes) return true;
        var buf: [max_word * 2]u8 = undefined;
        const capital = case.convertBuf(&buf, word, .capitalize) orelse return false;
        return d.checkWord(capital, mode)[0] == .yes;
    };
    var buf: [max_word * 2]u8 = undefined;
    if (word.len > buf.len) return false;
    // With ß here (two bytes, like "ss"), then without.
    @memcpy(buf[0..word.len], word);
    buf[i] = 0xc3;
    buf[i + 1] = 0x9f;
    if (d.sharps(buf[0..word.len], i + 2, true, mode)) return true;
    return d.sharps(word, i + 2, changed, mode);
}

/// Whether a dictionary entry spelled `word` exists (any homonym).
pub fn contains(d: *const Dictionary, word: []const u8) bool {
    return d.lookup(word) != none;
}

// Suggestions ---------------------------------------------------------------

/// Up to `max_suggestions` corrections for `word`, best first, each
/// owned by the caller (free them and the list with `gpa`).
pub fn suggest(d: *const Dictionary, gpa: Allocator, word: []const u8) Error![][]u8 {
    var s: Suggester = .{ .d = d, .gpa = gpa };
    defer s.deinit();
    if (word.len == 0 or word.len > max_word or !std.unicode.utf8ValidateSlice(word)) return try gpa.alloc([]u8, 0);
    var conv_buf: [max_word * 2]u8 = undefined;
    const w = convert(&conv_buf, word, d.opts.iconv) orelse word;
    const ct = case.captype(w);
    s.captype = ct;
    var lower_buf: [max_word * 2]u8 = undefined;
    const lower = case.convertBuf(&lower_buf, w, .lower) orelse w;
    for ([_]bool{ false, true }) |compounds| {
        if (compounds and (s.out.items.len != 0 or !d.hasCompounding())) break;
        // Candidates tried without compounds are tried again with them.
        if (compounds) s.forget();
        s.mode = .{ .suggest = true, .compounds = compounds, .upcase = ct == .all };
        switch (ct) {
            .none => {
                // "paris" for "Paris", "nasa" for "NASA".
                var cb: [max_word * 2]u8 = undefined;
                if (case.convertBuf(&cb, w, .capitalize)) |cap| try s.tryAdd(cap);
                if (case.convertBuf(&cb, w, .upper)) |up| try s.tryAdd(up);
                try s.edits(w);
            },
            .initial => {
                // "Usa" for "USA".
                var cb: [max_word * 2]u8 = undefined;
                if (case.convertBuf(&cb, w, .upper)) |up| try s.tryAdd(up);
                try s.edits(w);
                try s.edits(lower);
            },
            .all => {
                try s.tryAdd(lower);
                var cb: [max_word * 2]u8 = undefined;
                if (case.convertBuf(&cb, lower, .capitalize)) |cap| {
                    try s.tryAdd(cap);
                    try s.edits(cap);
                }
                try s.edits(lower);
                try s.edits(w);
            },
            .mixed, .mixed_initial => {
                try s.tryAdd(lower);
                try s.edits(w);
                try s.edits(lower);
            },
        }
    }
    if (s.out.items.len < 3 and d.opts.max_ngram > 0) try s.ngram(lower);
    return s.finish();
}

const Suggester = struct {
    d: *const Dictionary,
    gpa: Allocator,
    out: std.ArrayList([]u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    captype: case.Captype = .none,
    mode: Mode = .{ .suggest = true },
    /// Candidates left to check, so a long word cannot take long.
    budget: u32 = 6000,

    fn deinit(s: *Suggester) void {
        var it = s.seen.keyIterator();
        while (it.next()) |k| s.gpa.free(k.*);
        s.seen.deinit(s.gpa);
        for (s.out.items) |o| s.gpa.free(o);
        s.out.deinit(s.gpa);
    }

    fn forget(s: *Suggester) void {
        var it = s.seen.keyIterator();
        while (it.next()) |k| s.gpa.free(k.*);
        s.seen.clearRetainingCapacity();
    }

    fn full(s: *const Suggester) bool {
        return s.out.items.len >= max_suggestions or s.budget == 0;
    }

    /// Adds `cand` if it is right and new.
    fn tryAdd(s: *Suggester, cand: []const u8) Error!void {
        if (s.full() or cand.len == 0) return;
        if (s.seen.contains(cand)) return;
        s.budget -= 1;
        const key = try s.gpa.dupe(u8, cand);
        s.seen.put(s.gpa, key, {}) catch |err| {
            s.gpa.free(key);
            return err;
        };
        const ok = if (std.mem.indexOfScalar(u8, cand, ' ')) |sp|
            s.d.checkMode(cand[0..sp], s.mode, 0) and s.d.checkMode(cand[sp + 1 ..], s.mode, 0)
        else
            s.d.checkMode(cand, s.mode, 0);
        if (!ok) return;
        try s.out.append(s.gpa, try s.gpa.dupe(u8, cand));
    }

    fn encode(buf: []u8, cps: []const u21) ?[]const u8 {
        var n: usize = 0;
        for (cps) |cp| {
            if (n + 4 > buf.len) return null;
            n += std.unicode.utf8Encode(cp, buf[n..][0..4]) catch return null;
        }
        return buf[0..n];
    }

    fn tryCps(s: *Suggester, cps: []const u21) Error!void {
        var buf: [max_word * 2]u8 = undefined;
        if (encode(&buf, cps)) |c| try s.tryAdd(c);
    }

    /// Hunspell's edits, in its order: replacement table, related
    /// characters, swapped characters, keyboard neighbors, an extra
    /// character, a forgotten one, a moved one, a wrong one, a doubled
    /// pair of characters, and two words.
    fn edits(s: *Suggester, word: []const u8) Error!void {
        const d = s.d;
        var cps_buf: [max_word]u21 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < word.len) : (n += 1) {
            if (n == cps_buf.len) return;
            const cp, const len = case.decode(word, i);
            cps_buf[n] = cp;
            i += len;
        }
        const w = cps_buf[0..n];
        var t: [max_word + 1]u21 = undefined;
        var buf: [max_word * 4]u8 = undefined;

        // REP.
        for (d.opts.rep) |r| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, word, at, r.from)) |pos| : (at = pos + 1) {
                if (r.start and pos != 0) break;
                if (r.end and pos + r.from.len != word.len) continue;
                const len = word.len - r.from.len + r.to.len;
                if (len > buf.len) continue;
                @memcpy(buf[0..pos], word[0..pos]);
                @memcpy(buf[pos..][0..r.to.len], r.to);
                @memcpy(buf[pos + r.to.len ..][0 .. word.len - pos - r.from.len], word[pos + r.from.len ..]);
                try s.tryAdd(buf[0..len]);
            }
        }
        // MAP: one character for a related one.
        for (d.opts.map) |group| for (group) |from| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, word, at, from)) |pos| : (at = pos + 1) {
                for (group) |to| {
                    if (std.mem.eql(u8, to, from)) continue;
                    const len = word.len - from.len + to.len;
                    if (len > buf.len) continue;
                    @memcpy(buf[0..pos], word[0..pos]);
                    @memcpy(buf[pos..][0..to.len], to);
                    @memcpy(buf[pos + to.len ..][0 .. word.len - pos - from.len], word[pos + from.len ..]);
                    try s.tryAdd(buf[0..len]);
                }
            }
        };
        // Swapped neighbors, then characters two to four apart.
        for (1..5) |dist| {
            var k: usize = 0;
            while (k + dist < n) : (k += 1) {
                if (w[k] == w[k + dist]) continue;
                @memcpy(t[0..n], w);
                std.mem.swap(u21, &t[k], &t[k + dist]);
                try s.tryCps(t[0..n]);
            }
        }
        // Keyboard neighbors and the capital of each character.
        for (0..n) |k| {
            @memcpy(t[0..n], w);
            const up = case.upper(w[k]);
            if (up != w[k]) {
                t[k] = up;
                try s.tryCps(t[0..n]);
            }
            var rows = std.mem.splitScalar(u8, d.opts.key, '|');
            while (rows.next()) |row| {
                var prev: ?u21 = null;
                var j: usize = 0;
                while (j < row.len) {
                    const cp, const len = case.decode(row, j);
                    j += len;
                    const next: ?u21 = if (j < row.len) case.decode(row, j)[0] else null;
                    if (cp == w[k]) for ([_]?u21{ prev, next }) |nb| if (nb) |c| {
                        t[k] = c;
                        try s.tryCps(t[0..n]);
                    };
                    prev = cp;
                }
            }
        }
        // An extra character.
        if (n > 1) for (0..n) |k| {
            @memcpy(t[0..k], w[0..k]);
            @memcpy(t[k .. n - 1], w[k + 1 ..]);
            try s.tryCps(t[0 .. n - 1]);
        };
        // A forgotten character.
        if (n < max_word) for (d.opts.try_chars) |c| for (0..n + 1) |k| {
            @memcpy(t[0..k], w[0..k]);
            t[k] = c;
            @memcpy(t[k + 1 .. n + 1], w[k..]);
            try s.tryCps(t[0 .. n + 1]);
        };
        // A character moved two to ten places.
        for (0..n) |from| for (0..n) |to| {
            const dist = if (from > to) from - to else to - from;
            if (dist < 2 or dist > 10) continue;
            var m: usize = 0;
            for (0..n) |k| {
                if (k == from) continue;
                if (to < from and k == to) {
                    t[m] = w[from];
                    m += 1;
                }
                t[m] = w[k];
                m += 1;
                if (to > from and k == to) {
                    t[m] = w[from];
                    m += 1;
                }
            }
            try s.tryCps(t[0..n]);
        };
        // A wrong character.
        for (0..n) |k| for (d.opts.try_chars) |c| {
            if (c == w[k]) continue;
            @memcpy(t[0..n], w);
            t[k] = c;
            try s.tryCps(t[0..n]);
        };
        // A pair typed twice: "vacacation".
        if (n >= 5) for (0..n - 3) |k| {
            if (w[k] == w[k + 2] and w[k + 1] == w[k + 3]) {
                @memcpy(t[0 .. k + 2], w[0 .. k + 2]);
                @memcpy(t[k + 2 .. n - 2], w[k + 4 ..]);
                try s.tryCps(t[0 .. n - 2]);
            }
        };
        // Two words.
        if (!d.opts.no_split_sugs and n >= 2) for (1..n) |k| {
            var len: usize = 0;
            const left = encode(buf[0..], w[0..k]) orelse continue;
            len = left.len;
            buf[len] = ' ';
            const right = encode(buf[len + 1 ..], w[k..]) orelse continue;
            try s.tryAdd(buf[0 .. len + 1 + right.len]);
        };
    }

    /// When edits found little: dictionary words most like `word` by
    /// shared character n-grams, then their affixed forms, ranked by
    /// edit distance.
    fn ngram(s: *Suggester, word: []const u8) Error!void {
        const d = s.d;
        const o = &d.opts;
        const gpa = s.gpa;
        var target_buf: [max_word]u21 = undefined;
        const target = toCps(&target_buf, word) orelse return;
        if (target.len < 2) return;
        const Scored = struct { score: i32, e: u32 };
        var best: [64]Scored = undefined;
        var nbest: usize = 0;
        var cand_buf: [max_word]u21 = undefined;
        var low_buf: [max_word * 2]u8 = undefined;
        for (d.entries, 0..) |en, ei| {
            // Roots much longer than the word are not its stem.
            if (en.len > word.len + 8) continue;
            const e: u32 = @intCast(ei);
            if (d.entryHas(e, o.forbidden) or d.entryHas(e, o.nosuggest) or d.entryHas(e, o.onlyincompound) or d.entryHas(e, only_upcase)) continue;
            const low = case.convertBuf(&low_buf, d.wordOf(e), .lower) orelse continue;
            const cand = toCps(&cand_buf, low) orelse continue;
            // Roots are scored as Hunspell scores them: shorter ones are
            // not penalized (affixes make up the difference), longer
            // ones are, and a common beginning counts.
            const longer: i32 = @intCast(cand.len -| (target.len + 2));
            const score = ngramShared(target, cand) - longer + @as(i32, @intCast(commonPrefix(target, cand)));
            if (score <= 0) continue;
            if (nbest < best.len) {
                best[nbest] = .{ .score = score, .e = e };
                nbest += 1;
            } else {
                var worst: usize = 0;
                for (best[1..], 1..) |b, k| if (b.score < best[worst].score) {
                    worst = k;
                };
                if (score > best[worst].score) best[worst] = .{ .score = score, .e = e };
            }
        }
        // Each root and its forms with one affix, by edit distance.
        const Cand = struct { dist: u32, score: i32, text: []u8 };
        var cands: std.ArrayList(Cand) = .empty;
        defer {
            for (cands.items) |c| gpa.free(c.text);
            cands.deinit(gpa);
        }
        var form_buf: [max_word * 2]u8 = undefined;
        for (best[0..nbest]) |b| {
            const root = d.wordOf(b.e);
            if (!d.entryHas(b.e, o.needaffix)) try s.consider(&cands, target, root);
            const set = d.entries[b.e].set;
            for (d.suffixes) |*sf| {
                if (!d.has(set, sf.flag) or !std.mem.endsWith(u8, root, sf.strip)) continue;
                const base = root[0 .. root.len - sf.strip.len];
                if (!d.condMatches(sf, root, true) or base.len + sf.add.len > form_buf.len) continue;
                @memcpy(form_buf[0..base.len], base);
                @memcpy(form_buf[base.len..][0..sf.add.len], sf.add);
                try s.consider(&cands, target, form_buf[0 .. base.len + sf.add.len]);
            }
            for (d.prefixes) |*pf| {
                if (!d.has(set, pf.flag) or !std.mem.startsWith(u8, root, pf.strip)) continue;
                const rest = root[pf.strip.len..];
                if (!d.condMatches(pf, root, false) or rest.len + pf.add.len > form_buf.len) continue;
                @memcpy(form_buf[0..pf.add.len], pf.add);
                @memcpy(form_buf[pf.add.len..][0..rest.len], rest);
                try s.consider(&cands, target, form_buf[0 .. pf.add.len + rest.len]);
            }
        }
        std.mem.sort(Cand, cands.items, {}, struct {
            fn lt(_: void, a: Cand, b: Cand) bool {
                if (a.dist != b.dist) return a.dist < b.dist;
                return a.score > b.score;
            }
        }.lt);
        const max_dist: u32 = @intCast(@max(2, target.len / 3 + 1));
        var added: u32 = 0;
        for (cands.items) |c| {
            if (added >= o.max_ngram or s.out.items.len >= max_suggestions) break;
            if (c.dist > max_dist) break;
            const before = s.out.items.len;
            s.budget = @max(s.budget, 1);
            try s.tryAdd(c.text);
            if (s.out.items.len > before) added += 1;
        }
    }

    fn consider(s: *Suggester, cands: anytype, target: []const u21, form: []const u8) Error!void {
        var low_buf: [max_word * 2]u8 = undefined;
        var cps_buf: [max_word]u21 = undefined;
        const low = case.convertBuf(&low_buf, form, .lower) orelse return;
        const cps = toCps(&cps_buf, low) orelse return;
        const dist = editDistance(target, cps);
        const text = try s.gpa.dupe(u8, form);
        cands.append(s.gpa, .{ .dist = dist, .score = ngramScore(target, cps), .text = text }) catch |err| {
            s.gpa.free(text);
            return err;
        };
    }

    /// The suggestions in the word's capitalization, through OCONV.
    fn finish(s: *Suggester) Error![][]u8 {
        const gpa = s.gpa;
        var result: std.ArrayList([]u8) = .empty;
        errdefer {
            for (result.items) |r| gpa.free(r);
            result.deinit(gpa);
        }
        for (s.out.items) |sug| {
            var cased: std.ArrayList(u8) = .empty;
            defer cased.deinit(gpa);
            const keep = s.d.keepsCase(sug);
            switch (s.captype) {
                .initial => if (keep) try cased.appendSlice(gpa, sug) else try case.convert(&cased, gpa, sug, .capitalize),
                .all => if (keep) try cased.appendSlice(gpa, sug) else try case.convert(&cased, gpa, sug, .upper),
                else => try cased.appendSlice(gpa, sug),
            }
            var conv_buf: [max_word * 4]u8 = undefined;
            const final = convert(&conv_buf, cased.items, s.d.opts.oconv) orelse cased.items;
            var dup = false;
            for (result.items) |r| if (std.mem.eql(u8, r, final)) {
                dup = true;
            };
            if (dup) continue;
            try result.append(gpa, try gpa.dupe(u8, final));
        }
        return result.toOwnedSlice(gpa);
    }
};

fn keepsCase(d: *const Dictionary, word: []const u8) bool {
    const kc = d.opts.keepcase orelse return false;
    var e = d.lookup(word);
    while (e != none) : (e = d.entries[e].next) if (d.entryHas(e, kc)) return true;
    return false;
}

fn toCps(buf: []u21, s: []const u8) ?[]const u21 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (n == buf.len) return null;
        const cp, const len = case.decode(s, i);
        buf[n] = cp;
        i += len;
    }
    return buf[0..n];
}

/// Shared 1-, 2-, and 3-grams of `a` in `b`, less the difference in
/// length, as Hunspell scores n-gram suggestions.
fn ngramScore(a: []const u21, b: []const u21) i32 {
    const diff: i32 = @intCast(if (a.len > b.len) a.len - b.len else b.len - a.len);
    return ngramShared(a, b) - 2 * diff;
}

fn commonPrefix(a: []const u21, b: []const u21) usize {
    var n: usize = 0;
    while (n < a.len and n < b.len and a[n] == b[n]) n += 1;
    return n;
}

/// The 1-, 2-, and 3-grams of `a` that occur in `b`.
fn ngramShared(a: []const u21, b: []const u21) i32 {
    var score: i32 = 0;
    for (1..4) |len| {
        if (a.len < len) break;
        var k: usize = 0;
        while (k + len <= a.len) : (k += 1) {
            if (std.mem.indexOf(u21, b, a[k..][0..len]) != null) score += 1;
        }
    }
    return score;
}

/// Damerau-Levenshtein distance (optimal string alignment).
fn editDistance(a: []const u21, b: []const u21) u32 {
    if (a.len > 64 or b.len > 64) return 1000;
    var rows: [3][65]u32 = undefined;
    for (0..b.len + 1) |j| rows[1][j] = @intCast(j);
    for (1..a.len + 1) |i| {
        const cur = &rows[(i + 1) % 3];
        const prev = &rows[i % 3];
        const prev2 = &rows[(i + 2) % 3];
        cur[0] = @intCast(i);
        for (1..b.len + 1) |j| {
            const cost: u32 = if (a[i - 1] == b[j - 1]) 0 else 1;
            var v = @min(@min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
            if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]) v = @min(v, prev2[j - 2] + 1);
            cur[j] = v;
        }
    }
    return rows[(a.len + 1) % 3][b.len];
}
