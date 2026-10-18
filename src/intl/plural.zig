//! CLDR plural rules (D21): which category, of zero, one, two, few, many,
//! and other, a number takes in a language, for cardinals ("1 file", "2
//! files") and ordinals ("1st", "2nd"). The rules of plurals.json and
//! ordinals.json are compiled into functions at build time (gen.zig); this
//! file computes their operands (TR35's n, i, v, w, f, t, and c) from a
//! number as it is written, and finds a language's rules.

const std = @import("std");
const data = @import("cldr_data");
const cldr = @import("cldr.zig");
const Decimal = @import("number.zig").Decimal;

pub const Category = enum(u8) { zero, one, two, few, many, other };

pub const Kind = enum(u8) {
    /// Counting: "1 file", "2 files".
    cardinal,
    /// Ranking: "1st", "2nd", "3rd", "4th".
    ordinal,
};

/// The operands of a number as written (TR35): "1.50" is n 1.5, i 1, v 2,
/// w 1, f 50, t 5; "1.2c3" (1.2 thousand, compact) is n 1200, i 1200,
/// v 0, c 3.
pub const Operands = struct {
    /// The integer digits, at most the last 18 of them.
    i: u64 = 0,
    /// More than 18 integer digits: i is only good modulo a power of ten.
    i_big: bool = false,
    /// Visible fraction digits, with trailing zeros and without.
    v: u32 = 0,
    w: u32 = 0,
    /// The visible fraction digits as a number, with and without trailing
    /// zeros.
    f: u64 = 0,
    t: u64 = 0,
    /// The compact decimal exponent.
    c: u32 = 0,

    /// The operands of `dec` written with `shown` fraction digits and,
    /// when compact, times 10^`exponent`: `dec` is the number shown
    /// ("1.2" of "1.2K"), already rounded to `shown` digits. At most 15
    /// fraction digits count.
    pub fn init(dec: Decimal, shown: u32, exponent: u32) Operands {
        var x = dec;
        x.shift(@intCast(exponent));
        var o: Operands = .{ .c = exponent, .v = @min(shown -| exponent, 15) };
        const int_len = x.intDigits();
        o.i_big = int_len > 18;
        var e: i32 = @intCast(@min(int_len, 18));
        while (e > 0) {
            e -= 1;
            o.i = o.i * 10 + x.digitAt(e);
        }
        var k: i32 = 1;
        while (k <= o.v) : (k += 1) o.f = o.f * 10 + x.digitAt(-k);
        o.t = o.f;
        o.w = o.v;
        while (o.w > 0 and o.t % 10 == 0) {
            o.t /= 10;
            o.w -= 1;
        }
        return o;
    }

    /// Whether operand `op`, modulo `m` unless it is 0, is one of the
    /// values of `ranges` (inclusive). n is in a range only if it is an
    /// integer. Called by the generated rules.
    pub fn in(o: Operands, comptime op: u8, m: u64, ranges: []const [2]u64) bool {
        const x: u64 = switch (op) {
            'n', 'i' => blk: {
                if (op == 'n' and o.t != 0) return false;
                if (o.i_big and m == 0) return false;
                break :blk o.i;
            },
            'v' => o.v,
            'w' => o.w,
            'f' => o.f,
            't' => o.t,
            'c', 'e' => o.c,
            else => @compileError("unknown operand"),
        };
        const y = if (m == 0) x else x % m;
        for (ranges) |r| if (y >= r[0] and y <= r[1]) return true;
        return false;
    }
};

/// A language's rule sets.
pub const Rules = struct {
    cardinal: u16,
    ordinal: u16,
    /// The tag CLDR has the rules under.
    tag: []const u8,

    /// The rules for a BCP 47 tag or POSIX locale name, falling back to
    /// shorter tags and then English ("C" and the empty tag are
    /// English). Languages without ordinal rules count every ordinal as
    /// other.
    pub fn find(language: []const u8) Rules {
        var buf: [64]u8 = undefined;
        var tag = cldr.normalize(&buf, language);
        const entry: *const data.PluralLang = while (tag.len > 0) {
            if (lookup(tag)) |e| break e;
            if (cldr.alias(tag)) |to| {
                tag = to;
                continue;
            }
            tag = tag[0 .. std.mem.lastIndexOfScalar(u8, tag, '-') orelse 0];
        } else lookup("en").?;
        return .{ .cardinal = entry.cardinal, .ordinal = entry.ordinal, .tag = entry.tag };
    }

    pub fn category(r: Rules, kind: Kind, o: Operands) Category {
        return @enumFromInt(data.plural(if (kind == .cardinal) r.cardinal else r.ordinal, o));
    }

    /// The place of an integer's category among the categories integers
    /// take in the language, in the order of Category: in Russian one is
    /// 0, few 1, many 2 (other is for fractions). gettext catalogs without
    /// a Plural-Forms expression number their forms so (gettext.zig).
    pub fn integerIndex(r: Rules, cat: Category) u8 {
        const mask = data.plural_integer[r.cardinal];
        const below = mask & ((@as(u8, 1) << @intCast(@intFromEnum(cat))) - 1);
        return @popCount(below);
    }
};

fn lookup(tag: []const u8) ?*const data.PluralLang {
    var lo: usize = 0;
    var hi: usize = data.plural_langs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.ascii.orderIgnoreCase(tag, data.plural_langs[mid].tag)) {
            .eq => return &data.plural_langs[mid],
            .lt => hi = mid,
            .gt => lo = mid + 1,
        }
    }
    return null;
}

// Tests ------------------------------------------------------------------------

const testing = std.testing;

/// Calls `f(ctx, sample)` for each number of a sample list of the rules
/// ("0, 2~16, 100, …", "0.0~1.5, 1.0000001c6"): ranges step by the unit
/// of their last digit; the ellipsis is skipped.
fn eachSample(list: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8) anyerror!void) !void {
    var items = std.mem.tokenizeSequence(u8, list, ", ");
    while (items.next()) |raw| {
        const item = std.mem.trim(u8, raw, " ");
        if (std.mem.eql(u8, item, "…")) continue;
        const tilde = std.mem.indexOfScalar(u8, item, '~') orelse {
            try f(ctx, item);
            continue;
        };
        const lo = item[0..tilde];
        const hi = item[tilde + 1 ..];
        // Same number of fraction digits at both ends, and no exponent.
        const dot = std.mem.indexOfScalar(u8, lo, '.');
        const frac = if (dot) |d| lo.len - d - 1 else 0;
        const scale = std.math.pow(u64, 10, frac);
        const a = try scaled(lo, frac);
        const b = try scaled(hi, frac);
        var x = a;
        while (x <= b) : (x += 1) {
            var buf: [32]u8 = undefined;
            const s = if (frac == 0)
                try std.fmt.bufPrint(&buf, "{d}", .{x})
            else
                try std.fmt.bufPrint(&buf, "{d}.{d:0>[2]}", .{ x / scale, x % scale, frac });
            try f(ctx, s);
        }
    }
}

fn scaled(s: []const u8, frac: usize) !u64 {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (s) |ch| if (ch != '.') {
        buf[n] = ch;
        n += 1;
    };
    _ = frac;
    return std.fmt.parseInt(u64, buf[0..n], 10);
}

/// "1.50" or "1.1c6": the number as written, its fraction digits, and
/// its exponent.
const Sample = struct {
    mantissa: []const u8,
    fraction: u32,
    exponent: u32,

    fn parse(s: []const u8) !Sample {
        const c_at = std.mem.indexOfScalar(u8, s, 'c');
        const m = s[0 .. c_at orelse s.len];
        const dot = std.mem.indexOfScalar(u8, m, '.');
        return .{
            .mantissa = m,
            .fraction = if (dot) |d| @intCast(m.len - d - 1) else 0,
            .exponent = if (c_at) |c| try std.fmt.parseInt(u32, s[c + 1 ..], 10) else 0,
        };
    }
};

const Check = struct {
    set: u16,
    expected: Category,
    count: *usize,
};

fn checkSample(ck: Check, s: []const u8) !void {
    const sample = try Sample.parse(s);
    // As written: the digits of the sample itself.
    const dec = Decimal.parse(sample.mantissa).?;
    const got = data.plural(ck.set, Operands.init(dec, sample.fraction, sample.exponent));
    if (got != @intFromEnum(ck.expected)) {
        std.debug.print("rule set {d}: {s} is {t}, expected {t}\n", .{ ck.set, s, @as(Category, @enumFromInt(got)), ck.expected });
        return error.TestUnexpectedResult;
    }
    // As a double rounded to the sample's fraction digits, as the
    // number formatter writes it.
    var from_float = Decimal.fromFloat(try std.fmt.parseFloat(f64, sample.mantissa));
    from_float.round(@intCast(sample.fraction));
    try testing.expectEqual(got, data.plural(ck.set, Operands.init(from_float, sample.fraction, sample.exponent)));
    ck.count.* += 1;
}

test "every rule set takes the categories of CLDR's own samples" {
    var count: usize = 0;
    for (data.plural_samples) |s| {
        const ck: Check = .{ .set = s.set, .expected = @enumFromInt(s.category), .count = &count };
        try eachSample(s.integer, ck, checkSample);
        try eachSample(s.decimal, ck, checkSample);
    }
    // Thousands of samples, so a broken parser cannot pass by testing
    // nothing.
    try testing.expect(count > 3000);
}

test "operands of numbers as written" {
    const o = Operands.init(Decimal.parse("1.50").?, 2, 0);
    try testing.expectEqual(Operands{ .i = 1, .v = 2, .w = 1, .f = 50, .t = 5 }, o);
    // TR35's compact examples: 1.2c3 is 1200 with no visible fraction.
    try testing.expectEqual(Operands{ .i = 1200, .c = 3 }, Operands.init(Decimal.parse("1.2").?, 1, 3));
    try testing.expectEqual(Operands{ .i = 1000000, .v = 1, .w = 1, .f = 1, .t = 1, .c = 6 }, Operands.init(Decimal.parse("1.0000001").?, 7, 6));
    try testing.expectEqual(Operands{ .i = 0, .v = 3, .w = 0 }, Operands.init(Decimal.parse("0.000").?, 3, 0));
    // More than 18 integer digits: only the low digits, for modulus.
    const big = Operands.init(Decimal.parse("1000000000000000000001").?, 0, 0);
    try testing.expect(big.i_big and big.i == 1);
    try testing.expect(!big.in('n', 0, &.{.{ 1, 1 }}));
    try testing.expect(big.in('n', 10, &.{.{ 1, 1 }}));
}

test "languages: fallbacks and ordinals" {
    const one = Operands.init(Decimal.parse("1").?, 0, 0);
    const one_point_zero = Operands.init(Decimal.parse("1.0").?, 1, 0);
    const en = Rules.find("en_US.UTF-8");
    try testing.expectEqual(Category.one, en.category(.cardinal, one));
    try testing.expectEqual(Category.other, en.category(.cardinal, one_point_zero));
    // Portugal and Brazil differ for 0; Portuguese has its own rules.
    const zero = Operands.init(Decimal.parse("0").?, 0, 0);
    try testing.expectEqual(Category.one, Rules.find("pt-BR").category(.cardinal, zero));
    try testing.expectEqual(Category.other, Rules.find("pt-PT").category(.cardinal, zero));
    try testing.expectEqualStrings("en", Rules.find("").tag);
    try testing.expectEqualStrings("en", Rules.find("C").tag);
    try testing.expectEqualStrings("en", Rules.find("tlh").tag);
    try testing.expectEqualStrings("sr", Rules.find("sr-Latn-RS").tag);
    // Languages without ordinal rules: every ordinal is other.
    const de = Rules.find("de");
    try testing.expectEqual(Category.other, de.category(.ordinal, one));
    const two = Operands.init(Decimal.parse("2").?, 0, 0);
    try testing.expectEqual(Category.two, en.category(.ordinal, two));
}

test "integer categories for catalogs without Plural-Forms" {
    const ru = Rules.find("ru");
    try testing.expectEqual(@as(u8, 0), ru.integerIndex(.one));
    try testing.expectEqual(@as(u8, 1), ru.integerIndex(.few));
    try testing.expectEqual(@as(u8, 2), ru.integerIndex(.many));
    // Czech: many is for fractions only, so integers' other is third.
    const cs = Rules.find("cs");
    try testing.expectEqual(@as(u8, 2), cs.integerIndex(.other));
    const ar = Rules.find("ar");
    try testing.expectEqual(@as(u8, 5), ar.integerIndex(.other));
    try testing.expectEqual(@as(u8, 1), Rules.find("en").integerIndex(.other));
}
