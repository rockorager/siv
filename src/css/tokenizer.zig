//! The CSS tokenizer (CSS Syntax Level 3, section 4). A stylesheet is
//! tokenized once into an array; strings with escapes are decoded into the
//! token list's own buffer, others point into the source.

const std = @import("std");

pub const Kind = enum(u8) {
    ident,
    function,
    at_keyword,
    /// `#name`; `id` is set when the name would be a valid identifier.
    hash,
    string,
    bad_string,
    url,
    bad_url,
    delim,
    number,
    percentage,
    dimension,
    whitespace,
    cdo,
    cdc,
    colon,
    semicolon,
    comma,
    lbracket,
    rbracket,
    lparen,
    rparen,
    lbrace,
    rbrace,
    eof,
};

pub const Token = struct {
    kind: Kind,
    /// hash: a valid identifier; number: an integer literal.
    flag: bool = false,
    /// delim: the code point.
    delim: u21 = 0,
    /// Name, string value, or unit.
    text: []const u8 = "",
    number: f64 = 0,
    /// Where the token is in the source.
    start: u32 = 0,
    end: u32 = 0,

    pub fn is(t: Token, kind: Kind) bool {
        return t.kind == kind;
    }

    pub fn isDelim(t: Token, c: u21) bool {
        return t.kind == .delim and t.delim == c;
    }

    pub fn isIdent(t: Token, name: []const u8) bool {
        return t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, name);
    }

    pub fn isFunction(t: Token, name: []const u8) bool {
        return t.kind == .function and std.ascii.eqlIgnoreCase(t.text, name);
    }
};

/// Tokens of a source, with the memory their decoded strings live in.
pub const List = struct {
    tokens: []Token,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(l: *List) void {
        l.arena.deinit();
    }
};

pub fn tokenize(gpa: std.mem.Allocator, src: []const u8) error{OutOfMemory}!List {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const tokens = try tokenizeInto(arena.allocator(), arena.allocator(), src);
    return .{ .tokens = tokens, .arena = arena };
}

/// Tokens in memory from `list`, with decoded strings in `strings`; other
/// strings point into `src`, which must outlive them.
pub fn tokenizeInto(strings: std.mem.Allocator, list_alloc: std.mem.Allocator, src: []const u8) error{OutOfMemory}![]Token {
    var t: Tokenizer = .{ .src = src, .a = strings };
    var list: std.ArrayList(Token) = .empty;
    try list.ensureTotalCapacity(list_alloc, src.len / 4 + 4);
    while (true) {
        const start = t.pos;
        var tok = try t.next();
        tok.start = @intCast(@min(start, std.math.maxInt(u32)));
        tok.end = @intCast(@min(t.pos, std.math.maxInt(u32)));
        try list.append(list_alloc, tok);
        if (tok.kind == .eof) break;
    }
    return list.items;
}

const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    a: std.mem.Allocator,

    fn at(t: *const Tokenizer, k: usize) u8 {
        return if (t.pos + k < t.src.len) t.src[t.pos + k] else 0;
    }

    fn eofAt(t: *const Tokenizer, k: usize) bool {
        return t.pos + k >= t.src.len;
    }

    fn isNameStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80 or c == 0;
    }

    fn isName(c: u8) bool {
        return isNameStart(c) or std.ascii.isDigit(c) or c == '-';
    }

    fn isWs(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C;
    }

    fn validEscape(t: *const Tokenizer, k: usize) bool {
        return t.at(k) == '\\' and !t.eofAt(k) and t.at(k + 1) != '\n' and t.at(k + 1) != '\r' and t.at(k + 1) != 0x0C;
    }

    fn startsIdent(t: *const Tokenizer, k: usize) bool {
        const c = t.at(k);
        if (t.eofAt(k)) return false;
        if (c == '-') return (!t.eofAt(k + 1) and (isNameStart(t.at(k + 1)) or t.at(k + 1) == '-')) or t.validEscape(k + 1);
        if (isNameStart(c)) return true;
        return t.validEscape(k);
    }

    fn startsNumber(t: *const Tokenizer, k: usize) bool {
        const c = t.at(k);
        if (t.eofAt(k)) return false;
        if (c == '+' or c == '-') {
            if (std.ascii.isDigit(t.at(k + 1)) and !t.eofAt(k + 1)) return true;
            return t.at(k + 1) == '.' and std.ascii.isDigit(t.at(k + 2)) and !t.eofAt(k + 2);
        }
        if (c == '.') return std.ascii.isDigit(t.at(k + 1)) and !t.eofAt(k + 1);
        return std.ascii.isDigit(c);
    }

    /// Consumes an escape after the backslash, appending its UTF-8.
    fn escape(t: *Tokenizer, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
        if (t.pos >= t.src.len) return out.appendSlice(t.a, "\u{FFFD}");
        if (std.ascii.isHex(t.src[t.pos])) {
            var v: u32 = 0;
            var n: usize = 0;
            while (n < 6 and t.pos < t.src.len and std.ascii.isHex(t.src[t.pos])) : (n += 1) {
                v = v * 16 + (std.fmt.charToDigit(t.src[t.pos], 16) catch 0);
                t.pos += 1;
            }
            if (t.pos < t.src.len and isWs(t.src[t.pos])) {
                if (t.src[t.pos] == '\r' and t.at(1) == '\n') t.pos += 1;
                t.pos += 1;
            }
            const cp: u21 = if (v == 0 or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) 0xFFFD else @intCast(v);
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            return out.appendSlice(t.a, buf[0..len]);
        }
        const l = std.unicode.utf8ByteSequenceLength(t.src[t.pos]) catch 1;
        const end = @min(t.src.len, t.pos + l);
        try out.appendSlice(t.a, t.src[t.pos..end]);
        t.pos = end;
    }

    /// An identifier sequence; a slice of the source unless it has escapes
    /// or NULs.
    fn name(t: *Tokenizer) error{OutOfMemory}![]const u8 {
        const start = t.pos;
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (c == '\\' or c == 0) break;
            if (!isName(c)) return t.src[start..t.pos];
            t.pos += 1;
        }
        if (t.pos >= t.src.len) return t.src[start..t.pos];
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(t.a, t.src[start..t.pos]);
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (c == 0) {
                try out.appendSlice(t.a, "\u{FFFD}");
                t.pos += 1;
            } else if (isName(c)) {
                try out.append(t.a, c);
                t.pos += 1;
            } else if (t.validEscape(0)) {
                t.pos += 1;
                try t.escape(&out);
            } else break;
        }
        return out.items;
    }

    fn number(t: *Tokenizer) struct { f64, bool } {
        const start = t.pos;
        var integer = true;
        if (t.at(0) == '+' or t.at(0) == '-') t.pos += 1;
        while (t.pos < t.src.len and std.ascii.isDigit(t.src[t.pos])) t.pos += 1;
        if (t.at(0) == '.' and std.ascii.isDigit(t.at(1)) and !t.eofAt(1)) {
            integer = false;
            t.pos += 1;
            while (t.pos < t.src.len and std.ascii.isDigit(t.src[t.pos])) t.pos += 1;
        }
        if ((t.at(0) == 'e' or t.at(0) == 'E') and !t.eofAt(1) and (std.ascii.isDigit(t.at(1)) or ((t.at(1) == '+' or t.at(1) == '-') and std.ascii.isDigit(t.at(2)) and !t.eofAt(2)))) {
            integer = false;
            t.pos += 2;
            while (t.pos < t.src.len and std.ascii.isDigit(t.src[t.pos])) t.pos += 1;
        }
        const v = std.fmt.parseFloat(f64, t.src[start..t.pos]) catch 0;
        return .{ v, integer };
    }

    fn numeric(t: *Tokenizer) error{OutOfMemory}!Token {
        const v, const integer = t.number();
        if (t.startsIdent(0)) return .{ .kind = .dimension, .number = v, .flag = integer, .text = try t.name() };
        if (t.at(0) == '%' and !t.eofAt(0)) {
            t.pos += 1;
            return .{ .kind = .percentage, .number = v };
        }
        return .{ .kind = .number, .number = v, .flag = integer };
    }

    fn string(t: *Tokenizer, quote: u8) error{OutOfMemory}!Token {
        const start = t.pos;
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (c == quote) {
                const s = t.src[start..t.pos];
                t.pos += 1;
                return .{ .kind = .string, .text = s };
            }
            if (c == '\\' or c == '\n' or c == 0) break;
            t.pos += 1;
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(t.a, t.src[start..t.pos]);
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (c == quote) {
                t.pos += 1;
                return .{ .kind = .string, .text = out.items };
            }
            if (c == '\n') return .{ .kind = .bad_string };
            if (c == '\\') {
                if (t.pos + 1 >= t.src.len) {
                    t.pos += 1;
                    continue;
                }
                if (t.src[t.pos + 1] == '\n') {
                    t.pos += 2;
                    continue;
                }
                t.pos += 1;
                try t.escape(&out);
                continue;
            }
            if (c == 0) {
                try out.appendSlice(t.a, "\u{FFFD}");
            } else try out.append(t.a, c);
            t.pos += 1;
        }
        return .{ .kind = .string, .text = out.items };
    }

    fn url(t: *Tokenizer) error{OutOfMemory}!Token {
        while (t.pos < t.src.len and isWs(t.src[t.pos])) t.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            switch (c) {
                ')' => {
                    t.pos += 1;
                    return .{ .kind = .url, .text = out.items };
                },
                ' ', '\t', '\n', '\r', 0x0C => {
                    while (t.pos < t.src.len and isWs(t.src[t.pos])) t.pos += 1;
                    if (t.pos >= t.src.len) return .{ .kind = .url, .text = out.items };
                    if (t.src[t.pos] == ')') {
                        t.pos += 1;
                        return .{ .kind = .url, .text = out.items };
                    }
                    return t.badUrl();
                },
                '"', '\'', '(' => return t.badUrl(),
                '\\' => {
                    if (!t.validEscape(0)) return t.badUrl();
                    t.pos += 1;
                    try t.escape(&out);
                },
                else => {
                    try out.append(t.a, c);
                    t.pos += 1;
                },
            }
        }
        return .{ .kind = .url, .text = out.items };
    }

    fn badUrl(t: *Tokenizer) Token {
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (c == ')') {
                t.pos += 1;
                break;
            }
            if (t.validEscape(0)) t.pos += 2 else t.pos += 1;
        }
        return .{ .kind = .bad_url };
    }

    fn next(t: *Tokenizer) error{OutOfMemory}!Token {
        // Comments.
        while (t.at(0) == '/' and t.at(1) == '*' and !t.eofAt(1)) {
            const end = std.mem.indexOfPos(u8, t.src, t.pos + 2, "*/") orelse t.src.len;
            t.pos = @min(t.src.len, end + 2);
        }
        if (t.pos >= t.src.len) return .{ .kind = .eof };
        const c = t.src[t.pos];
        switch (c) {
            ' ', '\t', '\n', '\r', 0x0C => {
                while (t.pos < t.src.len and isWs(t.src[t.pos])) t.pos += 1;
                return .{ .kind = .whitespace };
            },
            '"', '\'' => {
                t.pos += 1;
                return t.string(c);
            },
            '#' => {
                if ((!t.eofAt(1) and isName(t.at(1))) or t.validEscape(1)) {
                    t.pos += 1;
                    const valid = t.startsIdent(0);
                    return .{ .kind = .hash, .flag = valid, .text = try t.name() };
                }
            },
            '(' => return t.single(.lparen),
            ')' => return t.single(.rparen),
            '[' => return t.single(.lbracket),
            ']' => return t.single(.rbracket),
            '{' => return t.single(.lbrace),
            '}' => return t.single(.rbrace),
            ',' => return t.single(.comma),
            ':' => return t.single(.colon),
            ';' => return t.single(.semicolon),
            '+', '.' => if (t.startsNumber(0)) return t.numeric(),
            '-' => {
                if (t.startsNumber(0)) return t.numeric();
                if (t.at(1) == '-' and t.at(2) == '>') {
                    t.pos += 3;
                    return .{ .kind = .cdc };
                }
                if (t.startsIdent(0)) return t.identLike();
            },
            '<' => if (t.pos + 4 <= t.src.len and std.mem.eql(u8, t.src[t.pos .. t.pos + 4], "<!--")) {
                t.pos += 4;
                return .{ .kind = .cdo };
            },
            '@' => if (t.startsIdent(1)) {
                t.pos += 1;
                return .{ .kind = .at_keyword, .text = try t.name() };
            },
            '\\' => if (t.validEscape(0)) return t.identLike(),
            '0'...'9' => return t.numeric(),
            else => if (isNameStart(c)) return t.identLike(),
        }
        // A delimiter: one code point.
        const l = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const end = @min(t.src.len, t.pos + l);
        const cp = std.unicode.utf8Decode(t.src[t.pos..end]) catch 0xFFFD;
        t.pos = end;
        return .{ .kind = .delim, .delim = cp };
    }

    fn single(t: *Tokenizer, kind: Kind) Token {
        t.pos += 1;
        return .{ .kind = kind };
    }

    fn identLike(t: *Tokenizer) error{OutOfMemory}!Token {
        const n = try t.name();
        if (t.at(0) == '(' and !t.eofAt(0)) {
            t.pos += 1;
            if (std.ascii.eqlIgnoreCase(n, "url")) {
                var k: usize = 0;
                while (isWs(t.at(k)) and !t.eofAt(k)) k += 1;
                if (t.at(k) != '"' and t.at(k) != '\'') return t.url();
            }
            return .{ .kind = .function, .text = n };
        }
        return .{ .kind = .ident, .text = n };
    }
};

test "tokens" {
    var l = try tokenize(std.testing.allocator, "a.b > #c:hover { color: rgb(1 2 3 / 50%); margin: -1.5em +2px; background: url( x.png ) } @media (min-width:600px){} /* c */ 'a\\62 c' \\31 x");
    defer l.deinit();
    const kinds = [_]Kind{ .ident, .delim, .ident, .whitespace, .delim, .whitespace, .hash, .colon, .ident, .whitespace, .lbrace };
    for (kinds, 0..) |k, i| try std.testing.expectEqual(k, l.tokens[i].kind);
    var found_url = false;
    var found_dim = false;
    var found_str = false;
    for (l.tokens) |t| {
        if (t.kind == .url) {
            found_url = true;
            try std.testing.expectEqualStrings("x.png", t.text);
        }
        if (t.kind == .dimension and std.mem.eql(u8, t.text, "em")) {
            found_dim = true;
            try std.testing.expectEqual(@as(f64, -1.5), t.number);
        }
        if (t.kind == .string) {
            found_str = true;
            try std.testing.expectEqualStrings("abc", t.text);
        }
    }
    try std.testing.expect(found_url and found_dim and found_str);
    try std.testing.expectEqualStrings("1x", l.tokens[l.tokens.len - 2].text);
}
