//! Generates the intl module's tables at build time (D21, D41), run by
//! src/intl/build_steps.zig:
//!
//!   siv-intl-gen <cldr.zig> <emoji.zig> <cldr-core> <cldr-dates> <cldr-numbers> <cldr-units> <emoji-test.txt>
//!
//! From CLDR's JSON (the cldr-core, cldr-dates-full, cldr-numbers-full,
//! and cldr-units-full packages): for every locale whose language CLDR
//! covers at the modern or moderate level, the Gregorian calendar's
//! month, weekday, day period, and era names, its date and time
//! patterns, its digits, and its first day of the week; its number
//! symbols, decimal, percent, and short compact patterns, and the byte
//! units' patterns. Strings are pooled and each distinct locale record
//! is written once. For every language CLDR has plural rules for, its
//! cardinal and ordinal rules, compiled into Zig functions, with the
//! rules' samples for the tests. From UTS #51's emoji-test.txt: every
//! fully-qualified emoji in CLDR order with its group and name, and the
//! skin tone variants of those that take one tone.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 8) {
        std.log.err("usage: {s} <cldr.zig> <emoji.zig> <cldr-core> <cldr-dates> <cldr-numbers> <cldr-units> <emoji-test.txt>", .{args[0]});
        std.process.exit(2);
    }
    const cldr_out = try cldr(io, arena, args[3], args[4], args[5], args[6]);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = cldr_out });
    const text = try Io.Dir.cwd().readFileAlloc(io, args[7], arena, .limited(16 << 20));
    const emoji_out = try emoji(arena, text);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = emoji_out });
}

// CLDR ------------------------------------------------------------------------

/// The order of a locale record's strings; src/intl/cldr.zig names them.
const day_keys = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
const month_sets = [_][2][]const u8{ .{ "format", "wide" }, .{ "format", "abbreviated" }, .{ "stand-alone", "wide" }, .{ "stand-alone", "abbreviated" } };
const day_sets = [_][2][]const u8{ .{ "format", "wide" }, .{ "format", "abbreviated" }, .{ "stand-alone", "wide" }, .{ "stand-alone", "abbreviated" }, .{ "stand-alone", "short" }, .{ "stand-alone", "narrow" } };
const date_formats = [_][]const u8{ "full", "long", "medium", "short" };
const time_formats = [_][]const u8{ "medium", "short" };
pub const field_count = month_sets.len * 12 + day_sets.len * 7 + 2 + 2 + date_formats.len + time_formats.len + 1;

/// The order of a number record's fields; src/intl/number.zig names them.
/// Symbols, then the decimal and percent patterns, then the minimum
/// grouping digits (a number, not a string), then the short compact
/// patterns for 10^3 to 10^14 by plural category, then the byte units'
/// patterns (byte in the long form, kB to PB in the short) by category.
/// Absent patterns are `none`.
const symbol_keys = [_][]const u8{ "decimal", "group", "percentSign", "minusSign", "plusSign", "infinity", "nan" };
const plural_categories = [_][]const u8{ "zero", "one", "two", "few", "many", "other" };
const compact_magnitudes = 12;
const byte_units = [_][2][]const u8{ .{ "long", "digital-byte" }, .{ "short", "digital-kilobyte" }, .{ "short", "digital-megabyte" }, .{ "short", "digital-gigabyte" }, .{ "short", "digital-terabyte" }, .{ "short", "digital-petabyte" } };
const compact_at = symbol_keys.len + 3;
const bytes_at = compact_at + compact_magnitudes * plural_categories.len;
pub const number_field_count = bytes_at + byte_units.len * plural_categories.len;
const none: u16 = 0xffff;

fn readJson(io: Io, arena: Allocator, path: []const u8) !json.Value {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20));
    return json.parseFromSliceLeaky(json.Value, arena, bytes, .{});
}

fn get(v: json.Value, keys: []const []const u8) ?json.Value {
    var cur = v;
    for (keys) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return cur;
}

fn getStr(v: json.Value, keys: []const []const u8) []const u8 {
    const x = get(v, keys) orelse std.debug.panic("missing {s}", .{keys[keys.len - 1]});
    return switch (x) {
        .string => |s| s,
        // A pattern with numbering overrides.
        .object => |o| o.get("_value").?.string,
        else => std.debug.panic("not a string: {s}", .{keys[keys.len - 1]}),
    };
}

const Pool = struct {
    bytes: std.ArrayList(u8) = .empty,
    offsets: std.ArrayList(u32) = .empty,
    index: std.StringHashMapUnmanaged(u16) = .empty,

    fn add(p: *Pool, a: Allocator, s: []const u8) !u16 {
        if (p.index.get(s)) |i| return i;
        const i: u16 = @intCast(p.offsets.items.len);
        try p.offsets.append(a, @intCast(p.bytes.items.len));
        try p.bytes.appendSlice(a, s);
        try p.index.put(a, s, i);
        return i;
    }
};

fn dayIndex(name: []const u8) u8 {
    for (day_keys, 0..) |k, i| if (std.mem.eql(u8, k, name)) return @intCast(i);
    std.debug.panic("unknown day {s}", .{name});
}

fn isRegion(sub: []const u8) bool {
    return (sub.len == 2 and std.ascii.isAlphabetic(sub[0])) or (sub.len == 3 and std.ascii.isDigit(sub[0]));
}

/// The region of a tag, from the tag itself or its likely subtags.
fn regionOf(likely: json.ObjectMap, tag: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, tag, '-');
    _ = it.next();
    while (it.next()) |sub| if (isRegion(sub)) return sub;
    var t = tag;
    while (true) {
        if (likely.get(t)) |full| {
            var fit = std.mem.splitBackwardsScalar(u8, full.string, '-');
            return fit.first();
        }
        const cut = std.mem.lastIndexOfScalar(u8, t, '-') orelse return null;
        t = t[0..cut];
    }
}

fn cldr(io: Io, a: Allocator, core: []const u8, dates: []const u8, numbers: []const u8, units: []const u8) ![]const u8 {
    const coverage = (try readJson(io, a, try std.fs.path.join(a, &.{ core, "coverageLevels.json" }))).object.get("effectiveCoverageLevels").?.object;
    const likely = (try readJson(io, a, try std.fs.path.join(a, &.{ core, "supplemental", "likelySubtags.json" }))).object.get("supplemental").?.object.get("likelySubtags").?.object;
    const week = (try readJson(io, a, try std.fs.path.join(a, &.{ core, "supplemental", "weekData.json" }))).object.get("supplemental").?.object.get("weekData").?.object.get("firstDay").?.object;
    const systems = (try readJson(io, a, try std.fs.path.join(a, &.{ core, "supplemental", "numberingSystems.json" }))).object.get("supplemental").?.object.get("numberingSystems").?.object;
    const version = (try readJson(io, a, try std.fs.path.join(a, &.{ core, "package.json" }))).object.get("version").?.string;

    var tags: std.ArrayList([]const u8) = .empty;
    {
        const main_dir = try std.fs.path.join(a, &.{ dates, "main" });
        var d = try Io.Dir.cwd().openDir(io, main_dir, .{ .iterate = true });
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .directory) continue;
            const lang = e.name[0 .. std.mem.indexOfScalar(u8, e.name, '-') orelse e.name.len];
            const cov: ?json.Value = coverage.get(e.name) orelse coverage.get(lang);
            const level = (cov orelse continue).string;
            if (!std.mem.eql(u8, level, "modern") and !std.mem.eql(u8, level, "moderate")) continue;
            try tags.append(a, try a.dupe(u8, e.name));
        }
    }
    std.mem.sort([]const u8, tags.items, {}, lessIgnoreCase);

    var pool: Pool = .{};
    var digit_sets: std.ArrayList([]const u8) = .empty;
    var records: std.ArrayList([field_count]u16) = .empty;
    var record_index: std.AutoHashMapUnmanaged([field_count]u16, u16) = .empty;
    var number_records: std.ArrayList([number_field_count]u16) = .empty;
    var number_index: std.AutoHashMapUnmanaged([number_field_count]u16, u16) = .empty;
    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    var locales: Io.Writer.Allocating = .init(a);
    const lw = &locales.writer;

    for (tags.items) |tag| {
        const doc = try readJson(io, a, try std.fs.path.join(a, &.{ dates, "main", tag, "ca-gregorian.json" }));
        const g = get(doc, &.{ "main", tag, "dates", "calendars", "gregorian" }).?;
        var rec: [field_count]u16 = undefined;
        var n: usize = 0;
        for (month_sets) |set| for (1..13) |m| {
            var buf: [2]u8 = undefined;
            rec[n] = try pool.add(a, getStr(g, &.{ "months", set[0], set[1], std.fmt.bufPrint(&buf, "{d}", .{m}) catch unreachable }));
            n += 1;
        };
        for (day_sets) |set| for (day_keys) |k| {
            rec[n] = try pool.add(a, getStr(g, &.{ "days", set[0], set[1], k }));
            n += 1;
        };
        for ([_][]const u8{ "am", "pm" }) |k| {
            rec[n] = try pool.add(a, getStr(g, &.{ "dayPeriods", "format", "abbreviated", k }));
            n += 1;
        }
        for ([_][]const u8{ "0", "1" }) |k| {
            rec[n] = try pool.add(a, getStr(g, &.{ "eras", "eraAbbr", k }));
            n += 1;
        }
        for (date_formats) |k| {
            rec[n] = try pool.add(a, getStr(g, &.{ "dateFormats", k }));
            n += 1;
        }
        for (time_formats) |k| {
            rec[n] = try pool.add(a, getStr(g, &.{ "timeFormats", k }));
            n += 1;
        }
        rec[n] = try pool.add(a, getStr(g, &.{ "dateTimeFormats", "availableFormats", "yMMMM" }));
        n += 1;
        std.debug.assert(n == field_count);
        const gop = try record_index.getOrPut(a, rec);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(records.items.len);
            try records.append(a, rec);
        }

        const ndoc = try readJson(io, a, try std.fs.path.join(a, &.{ numbers, "main", tag, "numbers.json" }));
        const system = getStr(ndoc, &.{ "main", tag, "numbers", "defaultNumberingSystem" });
        const digits = systems.get(system).?.object.get("_digits").?.string;
        const di = for (digit_sets.items, 0..) |d, i| {
            if (std.mem.eql(u8, d, digits)) break i;
        } else blk: {
            try digit_sets.append(a, digits);
            break :blk digit_sets.items.len - 1;
        };
        const nrec = try numberRecord(io, a, &pool, ndoc, units, tag, system);
        const ngop = try number_index.getOrPut(a, nrec);
        if (!ngop.found_existing) {
            ngop.value_ptr.* = @intCast(number_records.items.len);
            try number_records.append(a, nrec);
        }
        const region = regionOf(likely, tag) orelse "001";
        const first = dayIndex((week.get(region) orelse week.get("001").?).string);
        try lw.print("    .{{ .tag = \"{f}\", .record = {d}, .first_day = {d}, .digits = {d}, .numbers = {d} }},\n", .{ std.zig.fmtString(tag), gop.value_ptr.*, first, di, ngop.value_ptr.* });
    }

    try w.print(
        \\//! Generated by src/intl/gen.zig from CLDR {s} (Unicode License v3): the
        \\//! Gregorian calendar and number data of {d} locales, and the plural
        \\//! rules of every language CLDR has them for. Do not edit.
        \\
        \\pub const version = "{s}";
        \\pub const field_count = {d};
        \\pub const number_field_count = {d};
        \\pub const Locale = struct {{ tag: []const u8, record: u16, first_day: u8, digits: u8, numbers: u16 }};
        \\pub const Alias = struct {{ from: []const u8, to: []const u8 }};
        \\pub const Region = struct {{ region: []const u8, first_day: u8 }};
        \\
    , .{ version, tags.items.len, version, field_count, number_field_count });
    try w.print("pub const pool = \"{f}\";\n", .{std.zig.fmtString(pool.bytes.items)});
    try w.writeAll("pub const offsets = [_]u32{");
    for (pool.offsets.items) |o| try w.print("{d},", .{o});
    try w.print("{d}}};\n", .{pool.bytes.items.len});
    try w.writeAll("pub const records = [_][field_count]u16{\n");
    for (records.items) |r| {
        try w.writeAll("    .{");
        for (r) |x| try w.print("{d},", .{x});
        try w.writeAll("},\n");
    }
    try w.writeAll("};\npub const number_records = [_][number_field_count]u16{\n");
    for (number_records.items) |r| {
        try w.writeAll("    .{");
        for (r) |x| try w.print("{d},", .{x});
        try w.writeAll("},\n");
    }
    try w.writeAll("};\npub const digits = [_][]const u8{");
    for (digit_sets.items) |d| try w.print("\"{f}\",", .{std.zig.fmtString(d)});
    try w.writeAll("};\n/// Sorted by tag, ignoring case.\npub const locales = [_]Locale{\n");
    try w.writeAll(locales.written());
    try w.writeAll("};\n");

    // Tags whose likely script is not their language's, which the locale
    // list names with the script: zh-TW is zh-Hant-TW.
    try w.writeAll("/// Sorted by from, ignoring case.\npub const aliases = [_]Alias{\n");
    var alias_keys: std.ArrayList([]const u8) = .empty;
    for (likely.keys()) |k| {
        var it = std.mem.tokenizeScalar(u8, k, '-');
        const lang = it.next().?;
        const sub = it.next() orelse continue;
        if (it.next() != null or !isRegion(sub) or std.mem.eql(u8, lang, "und")) continue;
        if (!hasTag(tags.items, lang)) continue;
        const target = likely.get(k).?.string;
        const base = (likely.get(lang) orelse continue).string;
        if (std.mem.eql(u8, scriptOf(target), scriptOf(base))) continue;
        try alias_keys.append(a, k);
    }
    std.mem.sort([]const u8, alias_keys.items, {}, lessIgnoreCase);
    for (alias_keys.items) |k| try w.print("    .{{ .from = \"{f}\", .to = \"{f}\" }},\n", .{ std.zig.fmtString(k), std.zig.fmtString(likely.get(k).?.string) });
    try w.writeAll("};\n/// Sorted by region.\npub const regions = [_]Region{\n");
    var regions: std.ArrayList([]const u8) = .empty;
    for (week.keys()) |k| if (std.mem.indexOfScalar(u8, k, '-') == null) try regions.append(a, k);
    std.mem.sort([]const u8, regions.items, {}, lessIgnoreCase);
    for (regions.items) |k| try w.print("    .{{ .region = \"{f}\", .first_day = {d} }},\n", .{ std.zig.fmtString(k), dayIndex(week.get(k).?.string) });
    try w.writeAll("};\n");
    try plurals(io, a, core, w);
    return out.written();
}

/// A locale's number symbols and patterns in its default numbering
/// system, and its byte units (the order of `number_field_count`).
fn numberRecord(io: Io, a: Allocator, pool: *Pool, ndoc: json.Value, units: []const u8, tag: []const u8, system: []const u8) ![number_field_count]u16 {
    var rec: [number_field_count]u16 = @splat(none);
    const nums = get(ndoc, &.{ "main", tag, "numbers" }).?;
    const sym = get(nums, &.{try std.fmt.allocPrint(a, "symbols-numberSystem-{s}", .{system})}).?;
    for (symbol_keys, 0..) |k, i| rec[i] = try pool.add(a, getStr(sym, &.{k}));
    const dec = get(nums, &.{try std.fmt.allocPrint(a, "decimalFormats-numberSystem-{s}", .{system})}).?;
    rec[symbol_keys.len] = try pool.add(a, getStr(dec, &.{"standard"}));
    rec[symbol_keys.len + 1] = try pool.add(a, getStr(nums, &.{ try std.fmt.allocPrint(a, "percentFormats-numberSystem-{s}", .{system}), "standard" }));
    rec[symbol_keys.len + 2] = try std.fmt.parseInt(u16, getStr(nums, &.{"minimumGroupingDigits"}), 10);
    const short = get(dec, &.{ "short", "decimalFormat" }).?;
    for (0..compact_magnitudes) |m| for (plural_categories, 0..) |cat, ci| {
        var key: std.ArrayList(u8) = .empty;
        try key.append(a, '1');
        try key.appendNTimes(a, '0', m + 3);
        try key.print(a, "-count-{s}", .{cat});
        if (short.object.get(key.items)) |v| rec[compact_at + m * plural_categories.len + ci] = try pool.add(a, v.string);
    };
    const udoc = try readJson(io, a, try std.fs.path.join(a, &.{ units, "main", tag, "units.json" }));
    const u = get(udoc, &.{ "main", tag, "units" }).?;
    for (byte_units, 0..) |unit, ui| {
        const e = get(u, &.{ unit[0], unit[1] }).?;
        for (plural_categories, 0..) |cat, ci| {
            const key = try std.fmt.allocPrint(a, "unitPattern-count-{s}", .{cat});
            if (e.object.get(key)) |v| rec[bytes_at + ui * plural_categories.len + ci] = try pool.add(a, v.string);
        }
        if (rec[bytes_at + ui * plural_categories.len + 5] == none) std.debug.panic("{s}: {s} has no other", .{ tag, unit[1] });
    }
    return rec;
}

// Plural rules ----------------------------------------------------------------

/// A rule set: each category's rule ("" where the language has none),
/// with its samples, in the order of `plural_categories`.
const RuleSet = [plural_categories.len][]const u8;

fn ruleSet(rules: json.ObjectMap) RuleSet {
    var set: RuleSet = @splat("");
    for (plural_categories, 0..) |cat, ci| {
        var buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "pluralRule-count-{s}", .{cat}) catch unreachable;
        if (rules.get(key)) |v| set[ci] = v.string;
    }
    return set;
}

/// "i = 1 and v = 0 @integer 1": the condition and the samples.
fn splitRule(rule: []const u8) struct { cond: []const u8, integer: []const u8, decimal: []const u8 } {
    const at = std.mem.indexOfScalar(u8, rule, '@') orelse rule.len;
    const int_at = std.mem.indexOf(u8, rule, "@integer");
    const dec_at = std.mem.indexOf(u8, rule, "@decimal");
    const int_end = dec_at orelse rule.len;
    return .{
        .cond = std.mem.trim(u8, rule[0..at], " "),
        .integer = if (int_at) |i| std.mem.trim(u8, rule[i + "@integer".len .. int_end], " ") else "",
        .decimal = if (dec_at) |i| std.mem.trim(u8, rule[i + "@decimal".len ..], " ") else "",
    };
}

/// Compiles a rule's condition (TR35's syntax: relations of an operand,
/// optionally modulo a number, = or != a list of values and ranges,
/// joined by and, which binds tighter, and or) into a Zig expression
/// on plural.zig's Operands.
fn condition(a: Allocator, cond: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var ors = std.mem.splitSequence(u8, cond, " or ");
    var first_or = true;
    while (ors.next()) |or_part| {
        if (!first_or) try out.appendSlice(a, " or ");
        first_or = false;
        try out.append(a, '(');
        var ands = std.mem.splitSequence(u8, or_part, " and ");
        var first_and = true;
        while (ands.next()) |rel_raw| {
            if (!first_and) try out.appendSlice(a, " and ");
            first_and = false;
            const rel = std.mem.trim(u8, rel_raw, " ");
            const neg = std.mem.indexOf(u8, rel, "!=");
            const op_at = neg orelse std.mem.indexOfScalar(u8, rel, '=') orelse std.debug.panic("no relation in {s}", .{rel});
            const lhs = std.mem.trim(u8, rel[0..op_at], " ");
            const rhs = std.mem.trim(u8, rel[op_at + @as(usize, if (neg != null) 2 else 1) ..], " ");
            const operand = lhs[0];
            if (std.mem.indexOfScalar(u8, "nivwftce", operand) == null) std.debug.panic("unknown operand in {s}", .{rel});
            var modulus: u64 = 0;
            if (std.mem.indexOfScalar(u8, lhs, '%')) |p| modulus = try std.fmt.parseInt(u64, std.mem.trim(u8, lhs[p + 1 ..], " "), 10);
            try out.print(a, "{s}o.in('{c}', {d}, &.{{", .{ if (neg != null) "!" else "", operand, modulus });
            var ranges = std.mem.splitScalar(u8, rhs, ',');
            while (ranges.next()) |r_raw| {
                const r = std.mem.trim(u8, r_raw, " ");
                const dots = std.mem.indexOf(u8, r, "..");
                const lo = try std.fmt.parseInt(u64, r[0 .. dots orelse r.len], 10);
                const hi = if (dots) |d| try std.fmt.parseInt(u64, r[d + 2 ..], 10) else lo;
                try out.print(a, " .{{ {d}, {d} }},", .{ lo, hi });
            }
            try out.appendSlice(a, " })");
        }
        try out.append(a, ')');
    }
    return out.items;
}

fn plurals(io: Io, a: Allocator, core: []const u8, w: *Io.Writer) !void {
    const cardinal = (try readJson(io, a, try std.fs.path.join(a, &.{ core, "supplemental", "plurals.json" }))).object.get("supplemental").?.object.get("plurals-type-cardinal").?.object;
    const ordinal = (try readJson(io, a, try std.fs.path.join(a, &.{ core, "supplemental", "ordinals.json" }))).object.get("supplemental").?.object.get("plurals-type-ordinal").?.object;

    // Set 0 is "everything is other", for languages without ordinal rules.
    var sets: std.ArrayList(RuleSet) = .empty;
    var set_index: std.StringHashMapUnmanaged(u16) = .empty;
    try sets.append(a, @splat(""));
    try set_index.put(a, "", 0);
    const Lang = struct { cardinal: u16 = 0, ordinal: u16 = 0 };
    var langs: std.StringArrayHashMapUnmanaged(Lang) = .empty;
    for ([_]json.ObjectMap{ cardinal, ordinal }, 0..) |table, kind| {
        for (table.keys(), table.values()) |tag, rules| {
            const set = ruleSet(rules.object);
            const key = try std.mem.join(a, "\x00", &set);
            const gop = try set_index.getOrPut(a, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(sets.items.len);
                try sets.append(a, set);
            }
            const lang = try langs.getOrPut(a, tag);
            if (!lang.found_existing) lang.value_ptr.* = .{};
            if (kind == 0) lang.value_ptr.cardinal = gop.value_ptr.* else lang.value_ptr.ordinal = gop.value_ptr.*;
        }
    }

    try w.writeAll(
        \\
        \\// Plural rules (TR35), compiled from plurals.json and ordinals.json.
        \\// Categories: 0 zero, 1 one, 2 two, 3 few, 4 many, 5 other.
        \\
        \\pub const PluralLang = struct { tag: []const u8, cardinal: u16, ordinal: u16 };
        \\pub const PluralSample = struct { set: u16, category: u8, integer: []const u8, decimal: []const u8 };
        \\
        \\/// The category of operands `o` (plural.zig's Operands) in rule set
        \\/// `set`.
        \\pub fn plural(set: u16, o: anytype) u8 {
        \\    return switch (set) {
        \\
    );
    for (0..sets.items.len) |i| try w.print("        {d} => p{d}(o),\n", .{ i, i });
    try w.writeAll("        else => 5,\n    };\n}\n");
    var masks: std.ArrayList(u8) = .empty;
    var samples: Io.Writer.Allocating = .init(a);
    for (sets.items, 0..) |set, i| {
        try w.print("fn p{d}(o: anytype) u8 {{\n", .{i});
        var used = false;
        var mask: u8 = 0;
        for (set, 0..) |rule, ci| {
            if (rule.len == 0) continue;
            const parts = splitRule(rule);
            if (parts.integer.len > 0) mask |= @as(u8, 1) << @intCast(ci);
            try samples.writer.print("    .{{ .set = {d}, .category = {d}, .integer = \"{f}\", .decimal = \"{f}\" }},\n", .{ i, ci, std.zig.fmtString(parts.integer), std.zig.fmtString(parts.decimal) });
            if (ci == plural_categories.len - 1) {
                if (parts.cond.len != 0) std.debug.panic("other has a condition: {s}", .{rule});
                continue;
            }
            used = true;
            try w.print("    if ({s}) return {d};\n", .{ try condition(a, parts.cond), ci });
        }
        if (!used) try w.writeAll("    _ = o;\n");
        try w.writeAll("    return 5;\n}\n");
        try masks.append(a, if (mask == 0) 1 << 5 else mask);
    }
    try w.writeAll("/// By rule set: the categories that integers take, a bit each.\npub const plural_integer = [_]u8{");
    for (masks.items) |m| try w.print("{d},", .{m});
    try w.writeAll("};\n/// Each rule's samples, by rule set and category.\npub const plural_samples = [_]PluralSample{\n");
    try w.writeAll(samples.written());
    try w.writeAll("};\n/// Sorted by tag, ignoring case.\npub const plural_langs = [_]PluralLang{\n");
    const keys = try a.dupe([]const u8, langs.keys());
    std.mem.sort([]const u8, keys, {}, lessIgnoreCase);
    for (keys) |k| {
        const l = langs.get(k).?;
        try w.print("    .{{ .tag = \"{f}\", .cardinal = {d}, .ordinal = {d} }},\n", .{ std.zig.fmtString(k), l.cardinal, l.ordinal });
    }
    try w.writeAll("};\n");
}

fn hasTag(tags: []const []const u8, tag: []const u8) bool {
    for (tags) |t| if (std.ascii.eqlIgnoreCase(t, tag)) return true;
    return false;
}

fn scriptOf(tag: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, tag, '-');
    _ = it.next();
    while (it.next()) |sub| if (sub.len == 4) return sub;
    return "";
}

fn lessIgnoreCase(_: void, x: []const u8, y: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(x, y);
}

// Emoji -----------------------------------------------------------------------

const names = @import("emoji_names.zig");
const groups = names.groups;

const Entry = struct {
    seq: []const u21,
    name: []const u8,
    group: u8,
};

fn isTone(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

/// A sequence without skin tones and emoji presentation selectors, which
/// toned sequences drop: the key that finds a variant's base.
fn keyOf(a: Allocator, seq: []const u21) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (seq) |cp| {
        if (isTone(cp) or cp == 0xFE0F) continue;
        var buf: [4]u8 = undefined;
        try out.appendSlice(a, buf[0 .. std.unicode.utf8Encode(cp, &buf) catch unreachable]);
    }
    return out.items;
}

/// The one tone of a sequence (0 to 4), null with none, or 255 with
/// several different ones.
fn toneOf(seq: []const u21) ?u8 {
    var t: ?u8 = null;
    for (seq) |cp| if (isTone(cp)) {
        const x: u8 = @intCast(cp - 0x1F3FB);
        if (t != null and t.? != x) return 255;
        t = x;
    };
    return t;
}

fn utf8(a: Allocator, seq: []const u21) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (seq) |cp| {
        var buf: [4]u8 = undefined;
        try out.appendSlice(a, buf[0 .. std.unicode.utf8Encode(cp, &buf) catch unreachable]);
    }
    return out.items;
}

fn emoji(a: Allocator, text: []const u8) ![]const u8 {
    var entries: std.ArrayList(Entry) = .empty;
    var toned: std.ArrayList(Entry) = .empty;
    var version: []const u8 = "";
    var group: ?u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# Version: ")) version = std.mem.trim(u8, line["# Version: ".len..], " \r");
        if (std.mem.startsWith(u8, line, "# group: ")) {
            const name = std.mem.trim(u8, line["# group: ".len..], " \r");
            group = for (groups, 0..) |gname, i| {
                if (std.mem.eql(u8, gname, name)) break @intCast(i);
            } else if (std.mem.eql(u8, name, "Component")) null else std.debug.panic("unknown emoji group {s}", .{name});
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue;
        const g = group orelse continue;
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const hash = std.mem.indexOfScalar(u8, line, '#') orelse continue;
        const status = std.mem.trim(u8, line[semi + 1 .. hash], " ");
        if (!std.mem.eql(u8, status, "fully-qualified")) continue;
        var seq: std.ArrayList(u21) = .empty;
        var cps = std.mem.tokenizeScalar(u8, line[0..semi], ' ');
        while (cps.next()) |h| try seq.append(a, try std.fmt.parseInt(u21, h, 16));
        // "# 😀 E1.0 grinning face": the name follows the version.
        const comment = line[hash + 1 ..];
        const e_at = std.mem.indexOf(u8, comment, " E").? + 2;
        const sp = std.mem.indexOfScalarPos(u8, comment, e_at, ' ').?;
        const entry: Entry = .{ .seq = seq.items, .name = std.mem.trim(u8, comment[sp + 1 ..], " \r"), .group = g };
        if (toneOf(seq.items) == null) try entries.append(a, entry) else try toned.append(a, entry);
    }

    // Each base's five single-tone variants, by its key.
    var by_key: std.StringHashMapUnmanaged(usize) = .empty;
    for (entries.items, 0..) |e, i| {
        const k = try keyOf(a, e.seq);
        if (!by_key.contains(k)) try by_key.put(a, k, i);
    }
    const variants = try a.alloc(?[5]?Entry, entries.items.len);
    @memset(variants, null);
    for (toned.items) |e| {
        const t = toneOf(e.seq).?;
        if (t == 255) continue;
        const base = by_key.get(try keyOf(a, e.seq)) orelse std.debug.panic("no base for {s}", .{e.name});
        if (variants[base] == null) variants[base] = @splat(null);
        variants[base].?[t] = e;
    }

    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    var pool: std.ArrayList(u8) = .empty;
    var table: Io.Writer.Allocating = .init(a);
    const tw = &table.writer;
    var tones: Io.Writer.Allocating = .init(a);
    const tnw = &tones.writer;
    var tone_count: usize = 0;
    var group_starts: [groups.len]usize = @splat(0);
    var last_group: ?u8 = null;
    for (entries.items, 0..) |e, i| {
        if (last_group != e.group) {
            if (last_group) |lg| if (e.group < lg) std.debug.panic("emoji groups out of order", .{});
            group_starts[e.group] = i;
            last_group = e.group;
        }
        const seq = try utf8(a, e.seq);
        const seq_at = pool.items.len;
        try pool.appendSlice(a, seq);
        const name_at = pool.items.len;
        try pool.appendSlice(a, e.name);
        var tone: u16 = 0xffff;
        if (variants[i]) |vs| {
            for (vs) |v| if (v == null) std.debug.panic("{s} lacks a tone", .{e.name});
            tone = @intCast(tone_count);
            tone_count += 1;
            try tnw.writeAll("    .{");
            for (vs, 0..) |v, t| {
                const s = try utf8(a, v.?.seq);
                try tnw.print(".{{ {d}, {d}, ", .{ pool.items.len, s.len });
                try pool.appendSlice(a, s);
                // Names CLDR forms otherwise ("kiss: light skin tone,
                // woman, man" for "kiss: woman, man") are kept.
                var buf: [256]u8 = undefined;
                if (std.mem.eql(u8, names.toned(&buf, e.name, @intCast(t)), v.?.name)) {
                    try tnw.writeAll("0, 0 },");
                } else {
                    try tnw.print("{d}, {d} }},", .{ pool.items.len, v.?.name.len });
                    try pool.appendSlice(a, v.?.name);
                }
            }
            try tnw.writeAll("},\n");
        }
        try tw.print("    .{{ .seq = {d}, .seq_len = {d}, .name = {d}, .name_len = {d}, .group = {d}, .tones = {d} }},\n", .{ seq_at, seq.len, name_at, e.name.len, e.group, tone });
    }
    try w.print(
        \\//! Generated by src/intl/gen.zig from emoji-test.txt, Emoji {s} (UTS #51,
        \\//! Unicode License v3): every fully-qualified emoji without a skin tone,
        \\//! in CLDR order, and the variants of those that take one tone. Do not edit.
        \\
        \\pub const version = "{s}";
        \\pub const Emoji = struct {{ seq: u32, seq_len: u8, name: u32, name_len: u8, group: u8, tones: u16 }};
        \\
    , .{ version, version });
    try w.print("pub const pool = \"{f}\";\n", .{std.zig.fmtString(pool.items)});
    try w.writeAll("pub const emoji = [_]Emoji{\n");
    try w.writeAll(table.written());
    try w.writeAll("};\n/// Offsets and lengths in pool of each tone's sequence and name; a name\n/// of length 0 is the base's with the tone (emoji_names.toned).\npub const tones = [_][5][4]u32{\n");
    try w.writeAll(tones.written());
    try w.writeAll("};\npub const group_starts = [_]u16{");
    for (group_starts) |s| try w.print("{d},", .{s});
    try w.writeAll("};\n");
    return out.written();
}
