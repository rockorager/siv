//! gettext message catalogs (D21): siv's own reader of GNU `.mo` files,
//! since libintl is LGPL (D25). A catalog maps a message, with an
//! optional context (msgctxt), to its translation and plural forms;
//! `Domains` finds each text domain's catalog for a language under the
//! directory the application gave, as bindtextdomain does:
//! <dir>/<ll_CC>/LC_MESSAGES/<domain>.mo, then <ll>.
//!
//! The plural form comes from the catalog's Plural-Forms expression (a C
//! expression of n, evaluated here) when it has one. Without one, the
//! catalog's language's CLDR cardinal rules choose: the forms are taken
//! to be the categories integers take, in CLDR's order (zero, one, two,
//! few, many, other), the last form standing for any beyond them.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const plural = @import("plural.zig");

/// A .mo file in memory.
pub const Catalog = struct {
    bytes: []const u8,
    endian: std.builtin.Endian,
    count: u32,
    originals: u32,
    translations: u32,
    /// Entries in the order of their keys, for binary search; msgfmt
    /// sorts them, but nothing requires it.
    order: []u32,
    /// From Plural-Forms; 0 without one.
    nplurals: u32 = 0,
    expr: ?Expr = null,
    /// The CLDR rules of the catalog's language, without Plural-Forms.
    rules: plural.Rules,

    pub const Error = error{ OutOfMemory, InvalidCatalog, UnsupportedCharset };

    /// Reads `bytes`, which the catalog owns from then on (freed by
    /// deinit with `gpa`); on an error the caller still owns them.
    /// `language` is the catalog's ("pt_BR").
    pub fn init(gpa: Allocator, bytes: []const u8, language: []const u8) Error!Catalog {
        if (bytes.len < 28) return error.InvalidCatalog;
        const endian: std.builtin.Endian = switch (std.mem.readInt(u32, bytes[0..4], .little)) {
            0x950412de => .little,
            0xde120495 => .big,
            else => return error.InvalidCatalog,
        };
        var c: Catalog = .{
            .bytes = bytes,
            .endian = endian,
            .count = 0,
            .originals = 0,
            .translations = 0,
            .order = &.{},
            .rules = plural.Rules.find(language),
        };
        // Major revisions 0 and 1 (1 adds system-dependent strings,
        // which are ignored).
        if (c.word(4) >> 16 > 1) return error.InvalidCatalog;
        c.count = c.word(8);
        c.originals = c.word(12);
        c.translations = c.word(16);
        const table_len = @as(u64, c.count) * 8;
        if (c.originals + table_len > bytes.len or c.translations + table_len > bytes.len) return error.InvalidCatalog;
        for (0..c.count) |i| {
            _ = c.string(c.originals, @intCast(i)) orelse return error.InvalidCatalog;
            _ = c.string(c.translations, @intCast(i)) orelse return error.InvalidCatalog;
        }
        c.order = try gpa.alloc(u32, c.count);
        errdefer gpa.free(c.order);
        for (c.order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, c.order, &c, lessKey);
        try c.readHeader();
        return c;
    }

    pub fn deinit(c: *Catalog, gpa: Allocator) void {
        gpa.free(c.order);
        gpa.free(c.bytes);
        c.* = undefined;
    }

    fn word(c: *const Catalog, at: u64) u32 {
        return std.mem.readInt(u32, c.bytes[@intCast(at)..][0..4], c.endian);
    }

    /// String `i` of a table, or null if it lies outside the file.
    fn string(c: *const Catalog, table: u32, i: u32) ?[]const u8 {
        const at = @as(u64, table) + @as(u64, i) * 8;
        const len = c.word(at);
        const off = c.word(at + 4);
        if (@as(u64, off) + len > c.bytes.len) return null;
        return c.bytes[off..][0..len];
    }

    /// An entry's key: its context, EOT, and msgid, without msgid_plural.
    fn key(c: *const Catalog, i: u32) []const u8 {
        const s = c.string(c.originals, i).?;
        return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
    }

    fn lessKey(c: *const Catalog, x: u32, y: u32) bool {
        return std.mem.order(u8, c.key(x), c.key(y)) == .lt;
    }

    /// Orders `stored` against the key of `context` and `text` (context,
    /// EOT, text; text alone without a context).
    fn orderKey(stored: []const u8, context: []const u8, text: []const u8) std.math.Order {
        var i: usize = 0;
        const parts = [_][]const u8{ context, if (context.len > 0) "\x04" else "", text };
        for (parts) |part| for (part) |ch| {
            if (i == stored.len) return .gt;
            if (stored[i] != ch) return std.math.order(ch, stored[i]);
            i += 1;
        };
        return if (i == stored.len) .eq else .lt;
    }

    /// The translation of a message: its forms separated by NULs.
    pub fn find(c: *const Catalog, context: []const u8, text: []const u8) ?[]const u8 {
        var lo: usize = 0;
        var hi: usize = c.order.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const e = c.order[mid];
            switch (orderKey(c.key(e), context, text)) {
                .eq => return c.string(c.translations, e).?,
                .lt => hi = mid,
                .gt => lo = mid + 1,
            }
        }
        return null;
    }

    /// The form of a translation for count `n`, or null if the catalog
    /// has none or it is empty. `plural_message` says whether the message
    /// has plural forms; without, `n` is ignored.
    pub fn translate(c: *const Catalog, context: []const u8, text: []const u8, plural_message: bool, n: u64) ?[]const u8 {
        if (text.len == 0) return null;
        const tr = c.find(context, text) orelse return null;
        const index = if (plural_message) c.pluralIndex(n) else 0;
        var forms = std.mem.splitScalar(u8, tr, 0);
        var form = forms.first();
        var k: u64 = 0;
        // Past the last form, the last.
        while (k < index) : (k += 1) form = forms.next() orelse break;
        return if (form.len == 0) null else form;
    }

    /// Which plural form count `n` takes.
    pub fn pluralIndex(c: *const Catalog, n: u64) u64 {
        if (c.expr) |e| {
            const i = e.eval(n);
            // As GNU gettext: an index out of range is the first form.
            return if (i < c.nplurals) i else 0;
        }
        const big = std.math.pow(u64, 10, 18);
        const cat = c.rules.category(.cardinal, .{ .i = n % big, .i_big = n >= big });
        return c.rules.integerIndex(cat);
    }

    /// The header (msgid ""): the charset, which must be UTF-8 or ASCII
    /// (siv converts none), and Plural-Forms.
    fn readHeader(c: *Catalog) Error!void {
        const header = c.find("", "") orelse return;
        var lines = std.mem.splitScalar(u8, header, '\n');
        while (lines.next()) |line| {
            if (fieldValue(line, "Content-Type:")) |v| {
                const at = std.mem.indexOf(u8, v, "charset=") orelse continue;
                const cs = std.mem.trim(u8, v[at + "charset=".len ..], " ;\r");
                const ok = for ([_][]const u8{ "UTF-8", "UTF8", "ASCII", "US-ASCII", "ANSI_X3.4-1968" }) |name| {
                    if (std.ascii.eqlIgnoreCase(cs, name)) break true;
                } else false;
                if (!ok) return error.UnsupportedCharset;
            } else if (fieldValue(line, "Plural-Forms:")) |v| {
                // "nplurals=3; plural=(n%10==1 ? 0 : 1);". A malformed
                // expression leaves the CLDR rules in charge.
                const np_at = std.mem.indexOf(u8, v, "nplurals=") orelse continue;
                const pl_at = std.mem.indexOf(u8, v, "plural=") orelse continue;
                var np_end = np_at + "nplurals=".len;
                while (np_end < v.len and std.ascii.isDigit(v[np_end])) np_end += 1;
                const nplurals = std.fmt.parseInt(u32, v[np_at + "nplurals=".len .. np_end], 10) catch continue;
                const src = v[pl_at + "plural=".len ..];
                const expr = Expr.parse(src[0 .. std.mem.indexOfScalar(u8, src, ';') orelse src.len]) orelse continue;
                if (nplurals == 0) continue;
                c.nplurals = nplurals;
                c.expr = expr;
            }
        }
    }

    fn fieldValue(line: []const u8, name: []const u8) ?[]const u8 {
        if (line.len < name.len or !std.ascii.eqlIgnoreCase(line[0..name.len], name)) return null;
        return std.mem.trim(u8, line[name.len..], " \t\r");
    }
};

/// A Plural-Forms expression: C's ?:, ||, &&, ==, !=, <, >, <=, >=, +,
/// -, *, /, %, !, parentheses, decimal numbers, and n, on unsigned
/// integers, as GNU gettext evaluates it (division by zero is 0).
pub const Expr = struct {
    nodes: [max_nodes]Node = undefined,
    len: u8 = 0,
    root: u8 = 0,

    const max_nodes = 96;
    const max_depth = 32;

    const Op = enum(u8) { num, n, not, mul, div, mod, add, sub, lt, gt, le, ge, eq, ne, @"and", @"or", cond };
    const Node = struct { op: Op, a: u8 = 0, b: u8 = 0, c: u8 = 0, value: u64 = 0 };

    pub fn parse(src: []const u8) ?Expr {
        var p: Parser = .{ .src = src };
        var e: Expr = .{};
        e.root = p.ternary(&e) orelse return null;
        p.skip();
        if (p.i != src.len) return null;
        return e;
    }

    pub fn eval(e: *const Expr, n: u64) u64 {
        return e.at(e.root, n);
    }

    fn at(e: *const Expr, i: u8, n: u64) u64 {
        const node = e.nodes[i];
        return switch (node.op) {
            .num => node.value,
            .n => n,
            .not => @intFromBool(e.at(node.a, n) == 0),
            .cond => if (e.at(node.a, n) != 0) e.at(node.b, n) else e.at(node.c, n),
            .@"and" => @intFromBool(e.at(node.a, n) != 0 and e.at(node.b, n) != 0),
            .@"or" => @intFromBool(e.at(node.a, n) != 0 or e.at(node.b, n) != 0),
            else => {
                const x = e.at(node.a, n);
                const y = e.at(node.b, n);
                return switch (node.op) {
                    .mul => x *% y,
                    .div => if (y == 0) 0 else x / y,
                    .mod => if (y == 0) 0 else x % y,
                    .add => x +% y,
                    .sub => x -% y,
                    .lt => @intFromBool(x < y),
                    .gt => @intFromBool(x > y),
                    .le => @intFromBool(x <= y),
                    .ge => @intFromBool(x >= y),
                    .eq => @intFromBool(x == y),
                    .ne => @intFromBool(x != y),
                    else => unreachable,
                };
            },
        };
    }

    fn add(e: *Expr, node: Node) ?u8 {
        if (e.len == max_nodes) return null;
        e.nodes[e.len] = node;
        e.len += 1;
        return e.len - 1;
    }

    const Parser = struct {
        src: []const u8,
        i: usize = 0,
        depth: u32 = 0,

        fn skip(p: *Parser) void {
            while (p.i < p.src.len and std.ascii.isWhitespace(p.src[p.i])) p.i += 1;
        }

        fn eat(p: *Parser, tok: []const u8) bool {
            p.skip();
            if (!std.mem.startsWith(u8, p.src[p.i..], tok)) return false;
            p.i += tok.len;
            return true;
        }

        fn ternary(p: *Parser, e: *Expr) ?u8 {
            p.depth += 1;
            defer p.depth -= 1;
            if (p.depth > max_depth) return null;
            const c = p.binary(e, 0) orelse return null;
            if (!p.eat("?")) return c;
            const x = p.ternary(e) orelse return null;
            if (!p.eat(":")) return null;
            const y = p.ternary(e) orelse return null;
            return e.add(.{ .op = .cond, .a = c, .b = x, .c = y });
        }

        /// Binary operators by precedence, loosest first; within a level,
        /// longer tokens before their prefixes.
        const levels = [_][]const struct { []const u8, Op }{
            &.{.{ "||", .@"or" }},
            &.{.{ "&&", .@"and" }},
            &.{ .{ "==", .eq }, .{ "!=", .ne } },
            &.{ .{ "<=", .le }, .{ ">=", .ge }, .{ "<", .lt }, .{ ">", .gt } },
            &.{ .{ "+", .add }, .{ "-", .sub } },
            &.{ .{ "*", .mul }, .{ "/", .div }, .{ "%", .mod } },
        };

        fn binary(p: *Parser, e: *Expr, comptime level: usize) ?u8 {
            if (level == levels.len) return p.unary(e);
            var left = p.binary(e, level + 1) orelse return null;
            outer: while (true) {
                inline for (levels[level]) |op| {
                    // "!" alone is not "!=", nor "|" "||".
                    if (p.eat(op[0])) {
                        const right = p.binary(e, level + 1) orelse return null;
                        left = e.add(.{ .op = op[1], .a = left, .b = right }) orelse return null;
                        continue :outer;
                    }
                }
                return left;
            }
        }

        fn unary(p: *Parser, e: *Expr) ?u8 {
            p.skip();
            if (p.i < p.src.len and p.src[p.i] == '!' and !(p.i + 1 < p.src.len and p.src[p.i + 1] == '=')) {
                p.i += 1;
                p.depth += 1;
                defer p.depth -= 1;
                if (p.depth > max_depth) return null;
                const x = p.unary(e) orelse return null;
                return e.add(.{ .op = .not, .a = x });
            }
            if (p.eat("(")) {
                const x = p.ternary(e) orelse return null;
                if (!p.eat(")")) return null;
                return x;
            }
            if (p.eat("n")) return e.add(.{ .op = .n });
            const start = p.i;
            while (p.i < p.src.len and std.ascii.isDigit(p.src[p.i])) p.i += 1;
            if (p.i == start) return null;
            const v = std.fmt.parseInt(u64, p.src[start..p.i], 10) catch return null;
            return e.add(.{ .op = .num, .value = v });
        }
    };
};

/// Text domains and their catalogs for the language last asked for.
pub const Domains = struct {
    list: std.ArrayList(Domain) = .empty,

    const Domain = struct {
        name: []u8,
        dir: []u8,
        catalog: ?Catalog = null,
        /// The language the catalog was looked for in (found or not);
        /// null before the first lookup.
        language: ?[]u8 = null,

        fn drop(d: *Domain, gpa: Allocator) void {
            if (d.catalog) |*c| c.deinit(gpa);
            d.catalog = null;
            if (d.language) |l| gpa.free(l);
            d.language = null;
        }
    };

    pub fn deinit(ds: *Domains, gpa: Allocator) void {
        for (ds.list.items) |*d| {
            d.drop(gpa);
            gpa.free(d.name);
            gpa.free(d.dir);
        }
        ds.list.deinit(gpa);
        ds.* = undefined;
    }

    fn get(ds: *Domains, name: []const u8) ?*Domain {
        if (name.len == 0) return if (ds.list.items.len > 0) &ds.list.items[0] else null;
        for (ds.list.items) |*d| if (std.mem.eql(u8, d.name, name)) return d;
        return null;
    }

    /// Where `name`'s catalogs are (`name` is not empty); an empty `dir`
    /// forgets the domain.
    pub fn bind(ds: *Domains, gpa: Allocator, name: []const u8, dir: []const u8) Allocator.Error!void {
        for (ds.list.items, 0..) |*d, i| if (std.mem.eql(u8, d.name, name)) {
            if (dir.len == 0) {
                d.drop(gpa);
                gpa.free(d.name);
                gpa.free(d.dir);
                _ = ds.list.orderedRemove(i);
                return;
            }
            const new_dir = try gpa.dupe(u8, dir);
            d.drop(gpa);
            gpa.free(d.dir);
            d.dir = new_dir;
            return;
        };
        if (dir.len == 0) return;
        try ds.list.ensureUnusedCapacity(gpa, 1);
        const n = try gpa.dupe(u8, name);
        errdefer gpa.free(n);
        const dd = try gpa.dupe(u8, dir);
        ds.list.appendAssumeCapacity(.{ .name = n, .dir = dd });
    }

    /// The translation of `text` (and `plural_text` for counts other than
    /// one, when `plural_message`) in domain `name` (the first bound when
    /// empty) for `language`, loading its catalog when the language
    /// changed. Untranslated, the text itself: `text` when n is 1 or the
    /// message has no plural, `plural_text` otherwise, as gettext.
    pub fn translate(ds: *Domains, gpa: Allocator, language: []const u8, name: []const u8, context: []const u8, text: []const u8, plural_message: bool, plural_text: []const u8, n: u64) Allocator.Error![]const u8 {
        const fallback = if (plural_message and n != 1) plural_text else text;
        const d = ds.get(name) orelse return fallback;
        if (d.language == null or !std.mem.eql(u8, d.language.?, language)) {
            d.drop(gpa);
            const l = try gpa.dupe(u8, language);
            errdefer gpa.free(l);
            d.catalog = try load(gpa, d.dir, d.name, language);
            d.language = l;
        }
        const c = &(d.catalog orelse return fallback);
        return c.translate(context, text, plural_message, n) orelse fallback;
    }
};

/// The first catalog of `domain` found for `language` under `dir`, or
/// null; a file that is not a valid catalog counts as none.
fn load(gpa: Allocator, dir: []const u8, domain: []const u8, language: []const u8) Allocator.Error!?Catalog {
    var names: Candidates = .init(language);
    while (names.next()) |name| {
        var buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}/LC_MESSAGES/{s}.mo", .{ dir, name, domain }, 0) catch continue;
        if (std.mem.indexOfScalar(u8, path, 0) != null) continue;
        const bytes = readFile(gpa, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        return Catalog.init(gpa, bytes, name) catch |err| {
            gpa.free(bytes);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
    }
    return null;
}

/// The directory names gettext tries for a language, most specific
/// first: "sr-Latn-RS" is sr_RS@latin, sr@latin, sr_RS, sr; "zh-Hant" is
/// zh_TW, zh; "de_AT.UTF-8" is de_AT, de. "C", "POSIX", and the empty
/// language have none.
pub const Candidates = struct {
    lang: []const u8 = "",
    region: []const u8 = "",
    modifier: []const u8 = "",
    step: u8 = 0,
    buf: [96]u8 = undefined,

    pub fn init(language: []const u8) Candidates {
        var c: Candidates = .{};
        const base_end = std.mem.indexOfAny(u8, language, ".@") orelse language.len;
        if (std.mem.indexOfScalar(u8, language, '@')) |at| {
            const m = language[at + 1 ..];
            c.modifier = m[0 .. std.mem.indexOfScalar(u8, m, '.') orelse m.len];
        }
        const base = language[0..base_end];
        if (std.mem.eql(u8, base, "C") or std.mem.eql(u8, base, "POSIX")) return c;
        var it = std.mem.tokenizeAny(u8, base, "-_");
        c.lang = it.next() orelse return c;
        var script: []const u8 = "";
        while (it.next()) |sub| {
            if (sub.len == 4 and script.len == 0) script = sub;
            if ((sub.len == 2 and std.ascii.isAlphabetic(sub[0])) or (sub.len == 3 and std.ascii.isDigit(sub[0]))) c.region = sub;
        }
        if (c.modifier.len == 0) {
            if (std.ascii.eqlIgnoreCase(script, "Latn")) c.modifier = "latin";
            if (std.ascii.eqlIgnoreCase(script, "Cyrl")) c.modifier = "cyrillic";
        }
        if (c.region.len == 0 and std.mem.eql(u8, c.lang, "zh")) {
            if (std.ascii.eqlIgnoreCase(script, "Hant")) c.region = "TW";
            if (std.ascii.eqlIgnoreCase(script, "Hans")) c.region = "CN";
        }
        return c;
    }

    pub fn next(c: *Candidates) ?[]const u8 {
        if (c.lang.len == 0) return null;
        while (c.step < 4) {
            const s = c.step;
            c.step += 1;
            const with_region = s == 0 or s == 2;
            const with_modifier = s < 2;
            if (with_region and c.region.len == 0) continue;
            if (with_modifier and c.modifier.len == 0) continue;
            var region_buf: [8]u8 = undefined;
            const region = std.ascii.upperString(region_buf[0..@min(c.region.len, 8)], c.region[0..@min(c.region.len, 8)]);
            return std.fmt.bufPrint(&c.buf, "{s}{s}{s}{s}{s}", .{
                c.lang,
                if (with_region) "_" else "",
                if (with_region) region else "",
                if (with_modifier) "@" else "",
                if (with_modifier) c.modifier else "",
            }) catch continue;
        }
        return null;
    }
};

pub const ReadError = error{ OutOfMemory, ReadFailed };

/// Reads a whole regular file of at most 64 MiB.
pub fn readFile(gpa: Allocator, path: [:0]const u8) ReadError![]u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true, .TYPE = true }, &st)) != .SUCCESS) return error.ReadFailed;
    if (st.mode & linux.S.IFMT != linux.S.IFREG or st.size > 64 << 20) return error.ReadFailed;
    const out = try gpa.alloc(u8, @intCast(st.size));
    errdefer gpa.free(out);
    var n: usize = 0;
    while (n < out.len) {
        const r = linux.read(fd, out[n..].ptr, out.len - n);
        switch (linux.errno(r)) {
            .SUCCESS => if (r == 0) break else {
                n += r;
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
    if (n != out.len) return error.ReadFailed;
    return out;
}

// Tests ------------------------------------------------------------------------

const testing = std.testing;

/// A message for `build`: msgctxt, msgid, msgid_plural, and msgstr or
/// msgstr[i].
pub const Message = struct {
    context: ?[]const u8 = null,
    id: []const u8,
    plural: ?[]const u8 = null,
    strs: []const []const u8,
};

/// Writes a .mo file as msgfmt does (without a hash table), so that tests
/// need no gettext tools; `sorted` false keeps the messages' order.
pub fn build(gpa: Allocator, messages: []const Message, endian: std.builtin.Endian, sorted: bool) ![]u8 {
    const Item = struct { orig: []u8, trans: []u8 };
    const items = try gpa.alloc(Item, messages.len);
    defer {
        for (items) |it| {
            gpa.free(it.orig);
            gpa.free(it.trans);
        }
        gpa.free(items);
    }
    for (messages, items) |m, *it| {
        var o: std.ArrayList(u8) = .empty;
        if (m.context) |c| {
            try o.appendSlice(gpa, c);
            try o.append(gpa, 4);
        }
        try o.appendSlice(gpa, m.id);
        if (m.plural) |p| {
            try o.append(gpa, 0);
            try o.appendSlice(gpa, p);
        }
        it.orig = try o.toOwnedSlice(gpa);
        it.trans = try std.mem.join(gpa, "\x00", m.strs);
    }
    if (sorted) std.mem.sort(Item, items, {}, struct {
        fn less(_: void, x: Item, y: Item) bool {
            return std.mem.order(u8, x.orig, y.orig) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const n: u32 = @intCast(items.len);
    const header_len = 28;
    const strings_at: u32 = header_len + 16 * n;
    const W = struct {
        fn word(o: *std.ArrayList(u8), a: Allocator, v: u32, e: std.builtin.Endian) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, e);
            try o.appendSlice(a, &b);
        }
    };
    for ([_]u32{ 0x950412de, 0, n, header_len, header_len + 8 * n, 0, strings_at }) |v| try W.word(&out, gpa, v, endian);
    var at = strings_at;
    for (items) |it| {
        try W.word(&out, gpa, @intCast(it.orig.len), endian);
        try W.word(&out, gpa, at, endian);
        at += @intCast(it.orig.len + 1);
    }
    for (items) |it| {
        try W.word(&out, gpa, @intCast(it.trans.len), endian);
        try W.word(&out, gpa, at, endian);
        at += @intCast(it.trans.len + 1);
    }
    for (items) |it| {
        try out.appendSlice(gpa, it.orig);
        try out.append(gpa, 0);
    }
    for (items) |it| {
        try out.appendSlice(gpa, it.trans);
        try out.append(gpa, 0);
    }
    return out.toOwnedSlice(gpa);
}

const header_ru = "Project-Id-Version: test\nLanguage: ru\nContent-Type: text/plain; charset=UTF-8\nPlural-Forms: nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);\n";

const messages_ru = [_]Message{
    .{ .id = "", .strs = &.{header_ru} },
    .{ .id = "Open", .strs = &.{"Открыть"} },
    .{ .context = "verb", .id = "Close", .strs = &.{"Закрыть"} },
    .{ .context = "noun", .id = "Close", .strs = &.{"Конец"} },
    .{ .id = "%d file", .plural = "%d files", .strs = &.{ "%d файл", "%d файла", "%d файлов" } },
    .{ .id = "Untranslated", .strs = &.{""} },
};

test "catalogs: messages, contexts, and Plural-Forms, in either byte order and any order" {
    const gpa = testing.allocator;
    for ([_]std.builtin.Endian{ .little, .big }) |endian| for ([_]bool{ true, false }) |sorted| {
        const bytes = try build(gpa, &messages_ru, endian, sorted);
        var c = try Catalog.init(gpa, bytes, "ru");
        defer c.deinit(gpa);
        try testing.expectEqual(@as(u32, 3), c.nplurals);
        try testing.expectEqualStrings("Открыть", c.translate("", "Open", false, 0).?);
        try testing.expectEqualStrings("Закрыть", c.translate("verb", "Close", false, 0).?);
        try testing.expectEqualStrings("Конец", c.translate("noun", "Close", false, 0).?);
        // Without its context, a message with one is not found.
        try testing.expectEqual(@as(?[]const u8, null), c.translate("", "Close", false, 0));
        try testing.expectEqual(@as(?[]const u8, null), c.translate("", "Missing", false, 0));
        try testing.expectEqual(@as(?[]const u8, null), c.translate("", "Untranslated", false, 0));
        try testing.expectEqual(@as(?[]const u8, null), c.translate("", "", false, 0));
        for ([_]struct { u64, []const u8 }{ .{ 1, "%d файл" }, .{ 2, "%d файла" }, .{ 5, "%d файлов" }, .{ 11, "%d файлов" }, .{ 21, "%d файл" }, .{ 102, "%d файла" }, .{ 112, "%d файлов" } }) |case| {
            try testing.expectEqualStrings(case[1], c.translate("", "%d file", true, case[0]).?);
        }
    };
}

test "catalogs without Plural-Forms take the language's CLDR rules" {
    const gpa = testing.allocator;
    const msgs = [_]Message{
        .{ .id = "", .strs = &.{"Content-Type: text/plain; charset=UTF-8\n"} },
        .{ .id = "%d file", .plural = "%d files", .strs = &.{ "один", "несколько", "много" } },
    };
    var c = try Catalog.init(gpa, try build(gpa, &msgs, .little, true), "ru_RU");
    defer c.deinit(gpa);
    try testing.expect(c.expr == null);
    try testing.expectEqualStrings("один", c.translate("", "%d file", true, 21).?);
    try testing.expectEqualStrings("несколько", c.translate("", "%d file", true, 3).?);
    try testing.expectEqualStrings("много", c.translate("", "%d file", true, 0).?);
    // French: one is 0 and 1; a two-form catalog's second form stands for
    // many (a million) and other.
    const fr = [_]Message{.{ .id = "%d file", .plural = "%d files", .strs = &.{ "un", "plusieurs" } }};
    var cf = try Catalog.init(gpa, try build(gpa, &fr, .little, true), "fr");
    defer cf.deinit(gpa);
    try testing.expectEqualStrings("un", cf.translate("", "%d file", true, 0).?);
    try testing.expectEqualStrings("plusieurs", cf.translate("", "%d file", true, 2).?);
    try testing.expectEqualStrings("plusieurs", cf.translate("", "%d file", true, 1_000_000).?);
}

test "catalogs: charsets and broken files" {
    const gpa = testing.allocator;
    const latin1 = [_]Message{.{ .id = "", .strs = &.{"Content-Type: text/plain; charset=ISO-8859-1\n"} }};
    const bytes = try build(gpa, &latin1, .little, true);
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedCharset, Catalog.init(gpa, bytes, "de"));
    const good = try build(gpa, &messages_ru, .little, true);
    defer gpa.free(good);
    // Every truncation, and offsets past the end, are rejected cleanly.
    for (0..good.len) |len| {
        if (Catalog.init(gpa, good[0..len], "ru")) |c| {
            var cc = c;
            gpa.free(cc.order);
            cc.order = &.{};
        } else |_| {}
    }
    var bad = try gpa.dupe(u8, good);
    defer gpa.free(bad);
    std.mem.writeInt(u32, bad[28 + 4 ..][0..4], 0xfffffff0, .little);
    try testing.expectError(error.InvalidCatalog, Catalog.init(gpa, bad, "ru"));
    try testing.expectError(error.InvalidCatalog, Catalog.init(gpa, "not a catalog at all, no, not at all", "ru"));
}

/// GNU gettext's documented Plural-Forms for languages whose integer
/// categories match CLDR's, by CLDR's integer index.
const known_forms = [_]struct { lang: []const u8, nplurals: u32, expr: []const u8 }{
    .{ .lang = "en", .nplurals = 2, .expr = "n != 1" },
    .{ .lang = "ja", .nplurals = 1, .expr = "0" },
    .{ .lang = "ru", .nplurals = 3, .expr = "n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2" },
    .{ .lang = "pl", .nplurals = 3, .expr = "n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2" },
    .{ .lang = "cs", .nplurals = 3, .expr = "(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2" },
    .{ .lang = "lt", .nplurals = 3, .expr = "n%10==1 && n%100!=11 ? 0 : n%10>=2 && (n%100<10 || n%100>=20) ? 1 : 2" },
    .{ .lang = "ar", .nplurals = 6, .expr = "n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5" },
    .{ .lang = "ga", .nplurals = 5, .expr = "n==1 ? 0 : n==2 ? 1 : (n>2 && n<7) ? 2 :(n>6 && n<11) ? 3 : 4" },
    .{ .lang = "sl", .nplurals = 4, .expr = "n%100==1 ? 0 : n%100==2 ? 1 : n%100==3 || n%100==4 ? 2 : 3" },
};

test "Plural-Forms expressions agree with CLDR's rules for integers" {
    for (known_forms) |k| {
        const e = Expr.parse(k.expr) orelse return error.TestUnexpectedResult;
        const rules = plural.Rules.find(k.lang);
        var n: u64 = 0;
        while (n <= 2000) : (n += 1) {
            const cat = rules.category(.cardinal, .{ .i = n });
            const want = rules.integerIndex(cat);
            const got = e.eval(n);
            if (got != want or got >= k.nplurals) {
                std.debug.print("{s}: n={d}: expression {d}, CLDR {t} ({d})\n", .{ k.lang, n, got, cat, want });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "Plural-Forms: operators, precedence, and malformed expressions" {
    const cases = [_]struct { []const u8, u64, u64 }{
        .{ "1 + 2 * 3", 0, 7 },
        .{ "(1 + 2) * 3", 0, 9 },
        .{ "10 - 2 - 3", 0, 5 },
        .{ "n / 0 + n % 0", 9, 0 },
        .{ "!n", 0, 1 },
        .{ "!!n", 5, 1 },
        .{ "n > 1 ? n < 5 ? 1 : 2 : 0", 3, 1 },
        .{ "n > 1 ? n < 5 ? 1 : 2 : 0", 7, 2 },
        .{ "n >= 2 && n <= 4 || n == 0", 0, 1 },
        .{ "1 || 0 && 0", 0, 1 },
        .{ "n != 1", 1, 0 },
    };
    for (cases) |c| try testing.expectEqual(c[2], Expr.parse(c[0]).?.eval(c[1]));
    for ([_][]const u8{ "", "n +", "(n", "n ? 1", "x", "n | 1", "n = 1", "((((((((((((((((((((((((((((((((((n))))))))))))))))))))))))))))))))))" }) |bad| {
        try testing.expectEqual(@as(?Expr, null), Expr.parse(bad));
    }
}

test "candidate directories for a language" {
    const cases = [_]struct { []const u8, []const []const u8 }{
        .{ "pt-BR", &.{ "pt_BR", "pt" } },
        .{ "de_AT.UTF-8", &.{ "de_AT", "de" } },
        .{ "sr-Latn-RS", &.{ "sr_RS@latin", "sr@latin", "sr_RS", "sr" } },
        .{ "sr_RS.UTF-8@latin", &.{ "sr_RS@latin", "sr@latin", "sr_RS", "sr" } },
        .{ "zh-Hant", &.{ "zh_TW", "zh" } },
        .{ "en-us", &.{ "en_US", "en" } },
        .{ "es-419", &.{ "es_419", "es" } },
        .{ "fr", &.{"fr"} },
        .{ "C", &.{} },
        .{ "", &.{} },
    };
    for (cases) |c| {
        var it: Candidates = .init(c[0]);
        for (c[1]) |want| try testing.expectEqualStrings(want, it.next().?);
        try testing.expectEqual(@as(?[]const u8, null), it.next());
    }
}
