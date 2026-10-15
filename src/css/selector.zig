//! Selectors Level 4, the part documents use: type, universal, class, id,
//! and attribute selectors (all operators, with the i and s flags);
//! structural pseudo-classes (:root, :empty, :first-child and friends,
//! :nth-child(An+B [of S]) and the -of-type forms); :not(), :is(),
//! :where(), :has() (descendant and child arguments); :link and
//! :any-link, :lang(), :dir(), the form states, and the user-action
//! pseudo-classes (never matching, since documents are static but for
//! :focus-visible, which links take); ::before, ::after, ::marker,
//! ::first-line, and ::first-letter (and their CSS 2 one-colon forms);
//! all four combinators. Names refer to the store's `names`, which the
//! document binds to its atoms before matching.

const std = @import("std");
const tk = @import("tokenizer.zig");
const Token = tk.Token;

pub const Combinator = enum(u8) { none, descendant, child, next_sibling, subsequent_sibling };

pub const Pseudo = enum(u8) {
    root,
    empty,
    first_child,
    last_child,
    only_child,
    first_of_type,
    last_of_type,
    only_of_type,
    link,
    any_link,
    visited,
    hover,
    active,
    focus,
    focus_visible,
    focus_within,
    target,
    checked,
    disabled,
    enabled,
    required,
    optional,
    read_only,
    read_write,
    placeholder_shown,
    defined,
    scope,
    /// Never matches (an unknown pseudo-class in a forgiving list).
    never,
};

pub const PseudoElement = enum(u8) { none, before, after, marker, first_line, first_letter, placeholder, selection };

pub const AttrOp = enum(u8) { exists, eq, includes, dash, prefix, suffix, substring };

pub const Kind = enum(u8) {
    universal,
    type,
    id,
    class,
    attr,
    pseudo,
    nth_child,
    nth_last_child,
    nth_of_type,
    nth_last_of_type,
    not,
    is,
    where,
    has,
    lang,
    dir,
};

pub const Simple = struct {
    kind: Kind,
    /// type/id/class/attr: index into `names`; lang/dir: the value.
    name: u32 = 0,
    /// attr: the value's index into `names`.
    value: u32 = 0,
    op: AttrOp = .exists,
    case_insensitive: bool = false,
    pseudo: Pseudo = .root,
    /// nth-*: a·n + b.
    a: i32 = 0,
    b: i32 = 0,
    /// not/is/where/has/nth-*(of S): a range of `selectors`.
    list_start: u32 = 0,
    list_len: u32 = 0,
};

/// A compound selector and the combinator to its left.
pub const Compound = struct {
    start: u32,
    len: u32,
    combinator: Combinator,
};

/// A complex selector, compounds stored right to left.
pub const Selector = struct {
    start: u32,
    len: u32,
    specificity: u32,
    pseudo: PseudoElement = .none,
    /// :has() arguments are relative selectors; their leftmost combinator.
    relative: Combinator = .none,
};

pub const Store = struct {
    names: std.ArrayList([]const u8) = .empty,
    name_map: std.StringHashMapUnmanaged(u32) = .empty,
    simples: std.ArrayList(Simple) = .empty,
    compounds: std.ArrayList(Compound) = .empty,
    selectors: std.ArrayList(Selector) = .empty,

    pub fn name(s: *Store, a: std.mem.Allocator, n: []const u8) error{OutOfMemory}!u32 {
        if (s.name_map.get(n)) |i| return i;
        const copy = try a.dupe(u8, n);
        const i: u32 = @intCast(s.names.items.len);
        try s.names.append(a, copy);
        try s.name_map.put(a, copy, i);
        return i;
    }

    pub fn compoundsOf(s: *const Store, sel: Selector) []const Compound {
        return s.compounds.items[sel.start..][0..sel.len];
    }

    pub fn simplesOf(s: *const Store, c: Compound) []const Simple {
        return s.simples.items[c.start..][0..c.len];
    }

    pub fn listOf(s: *const Store, simple: Simple) []const Selector {
        return s.selectors.items[simple.list_start..][0..simple.list_len];
    }
};

pub fn specificity(ids: u32, classes: u32, types: u32) u32 {
    return @as(u32, @min(ids, 255)) << 16 | @as(u32, @min(classes, 255)) << 8 | @min(types, 255);
}

pub const Parser = struct {
    a: std.mem.Allocator,
    store: *Store,
    tokens: []const Token,
    pos: usize = 0,
    depth: u32 = 0,
    /// Lowercase type and attribute names (HTML documents).
    html: bool = true,

    fn peekRaw(p: *const Parser) Token {
        return if (p.pos < p.tokens.len) p.tokens[p.pos] else .{ .kind = .eof };
    }

    fn skipWs(p: *Parser) bool {
        var any = false;
        while (p.pos < p.tokens.len and p.tokens[p.pos].kind == .whitespace) {
            p.pos += 1;
            any = true;
        }
        return any;
    }

    fn lowerName(p: *Parser, s: []const u8) error{OutOfMemory}!u32 {
        if (!p.html) return p.store.name(p.a, s);
        var buf: [64]u8 = undefined;
        if (s.len <= buf.len) return p.store.name(p.a, std.ascii.lowerString(&buf, s));
        const l = try std.ascii.allocLowerString(p.a, s);
        return p.store.name(p.a, l);
    }

    /// A selector list up to the end of the tokens. Returns the range of
    /// `store.selectors`, or null when any selector is invalid (the whole
    /// rule is dropped, except in forgiving lists).
    pub fn list(p: *Parser, forgiving: bool, relative: bool) error{OutOfMemory}!?[2]u32 {
        // Parse each complex selector into a temporary list first, since
        // nested lists append their own selectors as they go.
        var tmp: std.ArrayList(Selector) = .empty;
        defer tmp.deinit(p.a);
        while (true) {
            _ = p.skipWs();
            const start = p.pos;
            const sel = try p.complex(relative);
            _ = p.skipWs();
            const t = p.peekRaw();
            if (sel == null or (t.kind != .comma and t.kind != .eof and t.kind != .rparen)) {
                if (!forgiving) return null;
                // Skip to the next comma at this level.
                p.pos = start;
                var depth: usize = 0;
                while (p.pos < p.tokens.len) : (p.pos += 1) {
                    const k = p.tokens[p.pos].kind;
                    if (depth == 0 and (k == .comma or k == .eof or k == .rparen)) break;
                    if (k == .lparen or k == .function or k == .lbracket) depth += 1;
                    if ((k == .rparen or k == .rbracket) and depth > 0) depth -= 1;
                }
            } else try tmp.append(p.a, sel.?);
            const t2 = p.peekRaw();
            if (t2.kind == .comma) {
                p.pos += 1;
                continue;
            }
            break;
        }
        const start: u32 = @intCast(p.store.selectors.items.len);
        try p.store.selectors.appendSlice(p.a, tmp.items);
        return .{ start, @intCast(tmp.items.len) };
    }

    fn complex(p: *Parser, relative: bool) error{OutOfMemory}!?Selector {
        // Compounds left to right first, then stored reversed.
        var parts: std.ArrayList(struct { Compound, Combinator }) = .empty;
        defer parts.deinit(p.a);
        var ids: u32 = 0;
        var classes: u32 = 0;
        var types: u32 = 0;
        var pseudo: PseudoElement = .none;
        var lead: Combinator = .none;
        var comb: Combinator = .none;
        if (relative) {
            _ = p.skipWs();
            const t = p.peekRaw();
            if (t.isDelim('>')) {
                lead = .child;
                p.pos += 1;
            } else if (t.isDelim('+')) {
                lead = .next_sibling;
                p.pos += 1;
            } else if (t.isDelim('~')) {
                lead = .subsequent_sibling;
                p.pos += 1;
            } else lead = .descendant;
            _ = p.skipWs();
        }
        while (true) {
            const c = (try p.compound(&ids, &classes, &types, &pseudo)) orelse return null;
            try parts.append(p.a, .{ c, comb });
            const ws = p.skipWs();
            const t = p.peekRaw();
            if (t.isDelim('>')) {
                comb = .child;
            } else if (t.isDelim('+')) {
                comb = .next_sibling;
            } else if (t.isDelim('~')) {
                comb = .subsequent_sibling;
            } else if (ws and t.kind != .comma and t.kind != .eof and t.kind != .rparen and t.kind != .lbrace) {
                comb = .descendant;
                // A pseudo-element ends the selector.
                if (pseudo != .none) return null;
                continue;
            } else break;
            if (pseudo != .none) return null;
            p.pos += 1;
            _ = p.skipWs();
        }
        const start: u32 = @intCast(p.store.compounds.items.len);
        var i = parts.items.len;
        while (i > 0) {
            i -= 1;
            var c = parts.items[i][0];
            // The combinator to the left of compound i is the one recorded
            // with it.
            c.combinator = parts.items[i][1];
            try p.store.compounds.append(p.a, c);
        }
        return .{ .start = start, .len = @intCast(parts.items.len), .specificity = specificity(ids, classes, types), .pseudo = pseudo, .relative = lead };
    }

    fn compound(p: *Parser, ids: *u32, classes: *u32, types: *u32, pseudo: *PseudoElement) error{OutOfMemory}!?Compound {
        var simples: std.ArrayList(Simple) = .empty;
        defer simples.deinit(p.a);
        var first = true;
        while (true) : (first = false) {
            const t = p.peekRaw();
            if (pseudo.* != .none and !(t.kind == .colon)) break;
            switch (t.kind) {
                .ident => {
                    if (!first) return null;
                    p.pos += 1;
                    try simples.append(p.a, .{ .kind = .type, .name = try p.lowerName(t.text) });
                    types.* += 1;
                },
                .delim => {
                    if (t.delim == '*' and first) {
                        p.pos += 1;
                        try simples.append(p.a, .{ .kind = .universal });
                    } else if (t.delim == '.') {
                        p.pos += 1;
                        const n = p.peekRaw();
                        if (n.kind != .ident) return null;
                        p.pos += 1;
                        try simples.append(p.a, .{ .kind = .class, .name = try p.store.name(p.a, n.text) });
                        classes.* += 1;
                    } else if (t.delim == '&') {
                        // Nesting selector outside nesting: :scope.
                        p.pos += 1;
                        try simples.append(p.a, .{ .kind = .pseudo, .pseudo = .scope });
                        classes.* += 1;
                    } else break;
                },
                .hash => {
                    if (!t.flag) return null;
                    p.pos += 1;
                    try simples.append(p.a, .{ .kind = .id, .name = try p.store.name(p.a, t.text) });
                    ids.* += 1;
                },
                .lbracket => {
                    p.pos += 1;
                    try simples.append(p.a, (try p.attribute()) orelse return null);
                    classes.* += 1;
                },
                .colon => {
                    p.pos += 1;
                    var element = false;
                    if (p.peekRaw().kind == .colon) {
                        p.pos += 1;
                        element = true;
                    }
                    const n = p.peekRaw();
                    p.pos += 1;
                    if (n.kind == .ident) {
                        if (pseudoElementOf(n.text, element)) |pe| {
                            if (pseudo.* != .none) return null;
                            pseudo.* = pe;
                            types.* += 1;
                            continue;
                        }
                        if (element) return null;
                        const pc = pseudoClassOf(n.text) orelse return null;
                        try simples.append(p.a, .{ .kind = .pseudo, .pseudo = pc });
                        classes.* += 1;
                    } else if (n.kind == .function) {
                        if (element) {
                            // ::part(), ::slotted(), ::highlight() and the like.
                            return null;
                        }
                        const s = (try p.functional(n.text, ids, classes, types)) orelse return null;
                        try simples.append(p.a, s);
                    } else return null;
                },
                else => break,
            }
        }
        if (simples.items.len == 0 and pseudo.* == .none) return null;
        if (simples.items.len == 0) try simples.append(p.a, .{ .kind = .universal });
        const start: u32 = @intCast(p.store.simples.items.len);
        try p.store.simples.appendSlice(p.a, simples.items);
        return .{ .start = start, .len = @intCast(simples.items.len), .combinator = .none };
    }

    fn attribute(p: *Parser) error{OutOfMemory}!?Simple {
        _ = p.skipWs();
        var t = p.peekRaw();
        // Namespaces: [*|name] and [|name] are taken as plain names.
        if (t.isDelim('*') or t.isDelim('|')) {
            p.pos += 1;
            if (p.peekRaw().isDelim('|')) p.pos += 1;
            t = p.peekRaw();
        }
        if (t.kind != .ident) return null;
        p.pos += 1;
        var s: Simple = .{ .kind = .attr, .name = try p.lowerName(t.text) };
        _ = p.skipWs();
        t = p.peekRaw();
        if (t.kind == .rbracket) {
            p.pos += 1;
            return s;
        }
        if (t.kind != .delim) return null;
        p.pos += 1;
        s.op = switch (t.delim) {
            '=' => .eq,
            '~' => .includes,
            '|' => .dash,
            '^' => .prefix,
            '$' => .suffix,
            '*' => .substring,
            else => return null,
        };
        if (s.op != .eq) {
            if (!p.peekRaw().isDelim('=')) return null;
            p.pos += 1;
        }
        _ = p.skipWs();
        t = p.peekRaw();
        if (t.kind != .ident and t.kind != .string) return null;
        p.pos += 1;
        s.value = try p.store.name(p.a, t.text);
        _ = p.skipWs();
        t = p.peekRaw();
        if (t.kind == .ident) {
            if (t.isIdent("i")) s.case_insensitive = true else if (!t.isIdent("s")) return null;
            p.pos += 1;
            _ = p.skipWs();
        }
        if (p.peekRaw().kind != .rbracket) return null;
        p.pos += 1;
        return s;
    }

    /// The tokens up to the `)` closing the function at `pos`.
    fn argument(p: *Parser) ?[]const Token {
        var depth: usize = 1;
        const start = p.pos;
        while (p.pos < p.tokens.len) : (p.pos += 1) switch (p.tokens[p.pos].kind) {
            .lparen, .function => depth += 1,
            .rparen => {
                depth -= 1;
                if (depth == 0) {
                    const arg = p.tokens[start..p.pos];
                    p.pos += 1;
                    return arg;
                }
            },
            .eof => return null,
            else => {},
        };
        return null;
    }

    fn sub(p: *Parser, arg: []const Token, forgiving: bool, relative: bool) error{OutOfMemory}!?[2]u32 {
        if (p.depth > 16) return null;
        var inner: Parser = .{ .a = p.a, .store = p.store, .tokens = arg, .depth = p.depth + 1, .html = p.html };
        const r = (try inner.list(forgiving, relative)) orelse return null;
        _ = inner.skipWs();
        if (inner.pos < arg.len) return null;
        return r;
    }

    fn maxSpecificity(p: *Parser, r: [2]u32) u32 {
        var m: u32 = 0;
        for (p.store.selectors.items[r[0]..][0..r[1]]) |s| m = @max(m, s.specificity);
        return m;
    }

    fn addSpecificity(ids: *u32, classes: *u32, types: *u32, spec: u32) void {
        ids.* += spec >> 16;
        classes.* += (spec >> 8) & 0xff;
        types.* += spec & 0xff;
    }

    fn functional(p: *Parser, name: []const u8, ids: *u32, classes: *u32, types: *u32) error{OutOfMemory}!?Simple {
        const arg = p.argument() orelse return null;
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(name, "not") or eq(name, "is") or eq(name, "where") or eq(name, "matches") or eq(name, "-webkit-any") or eq(name, "has")) {
            const kind: Kind = if (eq(name, "not")) .not else if (eq(name, "where")) .where else if (eq(name, "has")) .has else .is;
            const r = (try p.sub(arg, kind == .is or kind == .where, kind == .has)) orelse return null;
            if (kind != .where) addSpecificity(ids, classes, types, p.maxSpecificity(r));
            return .{ .kind = kind, .list_start = r[0], .list_len = r[1] };
        }
        if (eq(name, "nth-child") or eq(name, "nth-last-child") or eq(name, "nth-of-type") or eq(name, "nth-last-of-type")) {
            const kind: Kind = if (eq(name, "nth-child")) .nth_child else if (eq(name, "nth-last-child")) .nth_last_child else if (eq(name, "nth-of-type")) .nth_of_type else .nth_last_of_type;
            var i: usize = 0;
            const ab = anB(arg, &i) orelse return null;
            var s: Simple = .{ .kind = kind, .a = ab[0], .b = ab[1] };
            classes.* += 1;
            while (i < arg.len and arg[i].kind == .whitespace) i += 1;
            if (i < arg.len and (kind == .nth_child or kind == .nth_last_child) and arg[i].isIdent("of")) {
                const r = (try p.sub(arg[i + 1 ..], false, false)) orelse return null;
                addSpecificity(ids, classes, types, p.maxSpecificity(r));
                s.list_start = r[0];
                s.list_len = r[1];
            } else if (i < arg.len) return null;
            return s;
        }
        if (eq(name, "lang") or eq(name, "dir")) {
            var i: usize = 0;
            while (i < arg.len and arg[i].kind == .whitespace) i += 1;
            if (i >= arg.len or (arg[i].kind != .ident and arg[i].kind != .string)) return null;
            classes.* += 1;
            return .{ .kind = if (eq(name, "lang")) .lang else .dir, .name = try p.store.name(p.a, arg[i].text) };
        }
        if (eq(name, "host") or eq(name, "host-context") or eq(name, "state")) return .{ .kind = .pseudo, .pseudo = .never };
        return null;
    }
};

fn pseudoClassOf(s: []const u8) ?Pseudo {
    const map = [_]struct { []const u8, Pseudo }{
        .{ "root", .root },                       .{ "empty", .empty },                 .{ "first-child", .first_child },
        .{ "last-child", .last_child },           .{ "only-child", .only_child },       .{ "first-of-type", .first_of_type },
        .{ "last-of-type", .last_of_type },       .{ "only-of-type", .only_of_type },   .{ "link", .link },
        .{ "any-link", .any_link },               .{ "-webkit-any-link", .any_link },   .{ "visited", .visited },
        .{ "hover", .hover },                     .{ "active", .active },               .{ "focus", .focus },
        .{ "focus-visible", .focus_visible },     .{ "focus-within", .focus_within },   .{ "target", .target },
        .{ "checked", .checked },                 .{ "disabled", .disabled },           .{ "enabled", .enabled },
        .{ "required", .required },               .{ "optional", .optional },           .{ "read-only", .read_only },
        .{ "read-write", .read_write },           .{ "placeholder-shown", .placeholder_shown }, .{ "defined", .defined },
        .{ "scope", .scope },                     .{ "indeterminate", .never },         .{ "default", .never },
        .{ "valid", .never },                     .{ "invalid", .never },               .{ "in-range", .never },
        .{ "out-of-range", .never },              .{ "target-within", .never },         .{ "playing", .never },
        .{ "paused", .never },                    .{ "autofill", .never },              .{ "open", .never },
        .{ "popover-open", .never },              .{ "modal", .never },                 .{ "fullscreen", .never },
        .{ "user-invalid", .never },              .{ "user-valid", .never },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(s, m[0])) return m[1];
    if (std.mem.startsWith(u8, s, "-")) return .never;
    return null;
}

fn pseudoElementOf(s: []const u8, double_colon: bool) ?PseudoElement {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(s, "before")) return .before;
    if (eq(s, "after")) return .after;
    if (eq(s, "first-line")) return .first_line;
    if (eq(s, "first-letter")) return .first_letter;
    if (!double_colon) return null;
    if (eq(s, "marker")) return .marker;
    if (eq(s, "placeholder")) return .placeholder;
    if (eq(s, "selection")) return .selection;
    return null;
}

/// Parses An+B (Syntax 3, 6.2) from `toks[i.*..]`.
pub fn anB(toks: []const Token, i: *usize) ?[2]i32 {
    while (i.* < toks.len and toks[i.*].kind == .whitespace) i.* += 1;
    if (i.* >= toks.len) return null;
    const t = toks[i.*];
    i.* += 1;
    var a: i32 = 0;
    var b: i32 = 0;
    var rest: []const u8 = "";
    switch (t.kind) {
        .number => {
            if (!t.flag) return null;
            return .{ 0, @intFromFloat(t.number) };
        },
        .ident => {
            if (t.isIdent("odd")) return .{ 2, 1 };
            if (t.isIdent("even")) return .{ 2, 0 };
            var s = t.text;
            if (s.len > 0 and s[0] == '-') {
                a = -1;
                s = s[1..];
            } else a = 1;
            if (s.len == 0 or (s[0] != 'n' and s[0] != 'N')) return null;
            rest = s[1..];
        },
        .delim => {
            if (t.delim != '+' or i.* >= toks.len or toks[i.*].kind != .ident) return null;
            const s = toks[i.*].text;
            i.* += 1;
            if (s.len == 0 or (s[0] != 'n' and s[0] != 'N')) return null;
            a = 1;
            rest = s[1..];
        },
        .dimension => {
            if (!t.flag) return null;
            a = @intFromFloat(t.number);
            const s = t.text;
            if (s.len == 0 or (s[0] != 'n' and s[0] != 'N')) return null;
            rest = s[1..];
        },
        else => return null,
    }
    // rest: "", "-", or "-<digits>".
    if (rest.len > 0) {
        if (rest[0] != '-') return null;
        if (rest.len == 1) {
            while (i.* < toks.len and toks[i.*].kind == .whitespace) i.* += 1;
            if (i.* >= toks.len or toks[i.*].kind != .number or !toks[i.*].flag) return null;
            b = -@as(i32, @intFromFloat(@abs(toks[i.*].number)));
            i.* += 1;
            return .{ a, b };
        }
        b = -(std.fmt.parseInt(i32, rest[1..], 10) catch return null);
        return .{ a, b };
    }
    // Optional " + B" / " - B" / " +B" / " -B".
    var j = i.*;
    while (j < toks.len and toks[j].kind == .whitespace) j += 1;
    if (j >= toks.len) return .{ a, b };
    const s = toks[j];
    if (s.kind == .number and s.flag and (s.number < 0 or s.number > 0) and (j == i.* or true)) {
        // A signed number: "+5" or "-5".
        i.* = j + 1;
        return .{ a, @intFromFloat(s.number) };
    }
    if (s.isDelim('+') or s.isDelim('-')) {
        var k = j + 1;
        while (k < toks.len and toks[k].kind == .whitespace) k += 1;
        if (k < toks.len and toks[k].kind == .number and toks[k].flag) {
            const v: i32 = @intFromFloat(toks[k].number);
            i.* = k + 1;
            return .{ a, if (s.delim == '-') -v else v };
        }
    }
    return .{ a, b };
}

fn parseStr(store: *Store, a: std.mem.Allocator, s: []const u8) !?[2]u32 {
    var l = try tk.tokenize(std.testing.allocator, s);
    defer l.deinit();
    var p: Parser = .{ .a = a, .store = store, .tokens = l.tokens };
    return p.list(false, false);
}

test "selectors and specificity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: Store = .{};
    const r = (try parseStr(&store, a, "ul > li.item:nth-child(2n+1 of .x), #main a[href^='http' i]::before, :is(h1, .t #x) p")).?;
    try std.testing.expectEqual(@as(u32, 3), r[1]);
    const sels = store.selectors.items[r[0]..][0..3];
    // ul > li.item:nth-child(2n+1 of .x): (0, 3, 2).
    try std.testing.expectEqual(specificity(0, 3, 2), sels[0].specificity);
    try std.testing.expectEqual(specificity(1, 1, 2), sels[1].specificity);
    try std.testing.expectEqual(PseudoElement.before, sels[1].pseudo);
    try std.testing.expectEqual(specificity(1, 1, 1), sels[2].specificity);
    // Rightmost compound first.
    const c0 = store.compoundsOf(sels[0]);
    try std.testing.expectEqual(@as(usize, 2), c0.len);
    try std.testing.expectEqual(Combinator.child, c0[0].combinator);
    try std.testing.expect((try parseStr(&store, a, "a:unknown-thing")) == null);
    try std.testing.expect((try parseStr(&store, a, "a::before b")) == null);
    var i: usize = 0;
    var l = try tk.tokenize(std.testing.allocator, "-n + 3");
    defer l.deinit();
    try std.testing.expectEqual([2]i32{ -1, 3 }, anB(l.tokens, &i).?);
}
