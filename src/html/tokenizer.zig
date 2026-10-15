//! The HTML tokenizer (WHATWG HTML, 13.2.5), state for state, with the
//! standard's error recovery (errors themselves are not reported: a
//! document renderer has nobody to tell). Input is UTF-8 with newlines
//! already normalized (`preprocess`). Tokens go to a sink as they are
//! made, so the tree builder can switch the tokenizer's state for the
//! next character (RCDATA after `<title>`, and so on).

const std = @import("std");
const entities = @import("entities.zig");

pub const State = enum {
    data,
    rcdata,
    rawtext,
    script_data,
    plaintext,
    tag_open,
    end_tag_open,
    tag_name,
    rcdata_lt,
    rcdata_end_tag_open,
    rcdata_end_tag_name,
    rawtext_lt,
    rawtext_end_tag_open,
    rawtext_end_tag_name,
    script_lt,
    script_end_tag_open,
    script_end_tag_name,
    script_escape_start,
    script_escape_start_dash,
    script_escaped,
    script_escaped_dash,
    script_escaped_dash_dash,
    script_escaped_lt,
    script_escaped_end_tag_open,
    script_escaped_end_tag_name,
    script_double_escape_start,
    script_double_escaped,
    script_double_escaped_dash,
    script_double_escaped_dash_dash,
    script_double_escaped_lt,
    script_double_escape_end,
    before_attr_name,
    attr_name,
    after_attr_name,
    before_attr_value,
    attr_value_double,
    attr_value_single,
    attr_value_unquoted,
    after_attr_value_quoted,
    self_closing_start_tag,
    bogus_comment,
    markup_declaration_open,
    comment_start,
    comment_start_dash,
    comment,
    comment_lt,
    comment_lt_bang,
    comment_lt_bang_dash,
    comment_lt_bang_dash_dash,
    comment_end_dash,
    comment_end,
    comment_end_bang,
    doctype,
    before_doctype_name,
    doctype_name,
    after_doctype_name,
    after_doctype_public_keyword,
    before_doctype_public_id,
    doctype_public_id_double,
    doctype_public_id_single,
    after_doctype_public_id,
    between_doctype_ids,
    after_doctype_system_keyword,
    before_doctype_system_id,
    doctype_system_id_double,
    doctype_system_id_single,
    after_doctype_system_id,
    bogus_doctype,
    cdata_section,
    cdata_section_bracket,
    cdata_section_end,
};

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Tag = struct {
    /// ASCII-lowercased.
    name: []const u8,
    attrs: []const Attr,
    self_closing: bool,
};

pub const Doctype = struct {
    name: ?[]const u8,
    public_id: ?[]const u8,
    system_id: ?[]const u8,
    force_quirks: bool,
};

pub const Token = union(enum) {
    doctype: Doctype,
    start_tag: Tag,
    end_tag: Tag,
    comment: []const u8,
    /// A run of characters (NUL kept in data, where the tree builder
    /// decides).
    chars: []const u8,
    eof,
};

pub const Error = error{OutOfMemory};

/// Replaces CR LF and lone CR with LF (13.2.3.5). Returns `input` when it
/// has no CR.
pub fn preprocess(gpa: std.mem.Allocator, input: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '\r') == null) return input;
    var out = try std.ArrayList(u8).initCapacity(gpa, input.len);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\r') {
            out.appendAssumeCapacity('\n');
            if (i + 1 < input.len and input[i + 1] == '\n') i += 1;
        } else out.appendAssumeCapacity(input[i]);
    }
    return out.toOwnedSlice(gpa);
}

pub fn Tokenizer(comptime Sink: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        input: []const u8,
        pos: usize = 0,
        state: State = .data,
        return_state: State = .data,
        sink: Sink,
        /// The name of the last start tag emitted, for appropriate end tags.
        last_start_tag: std.ArrayList(u8) = .empty,
        chars: std.ArrayList(u8) = .empty,
        tag_name: std.ArrayList(u8) = .empty,
        is_end_tag: bool = false,
        self_closing: bool = false,
        attr_bytes: std.ArrayList(u8) = .empty,
        /// Ranges into `attr_bytes`: name start, name end, value end.
        attr_ranges: std.ArrayList([3]u32) = .empty,
        attrs_out: std.ArrayList(Attr) = .empty,
        temp: std.ArrayList(u8) = .empty,
        comment_buf: std.ArrayList(u8) = .empty,
        dt_name: std.ArrayList(u8) = .empty,
        dt_public: std.ArrayList(u8) = .empty,
        dt_system: std.ArrayList(u8) = .empty,
        dt_has_name: bool = false,
        dt_has_public: bool = false,
        dt_has_system: bool = false,
        dt_quirks: bool = false,
        last_len: usize = 0,
        done: bool = false,

        pub fn init(gpa: std.mem.Allocator, input: []const u8, sink: Sink) Self {
            return .{ .gpa = gpa, .input = input, .sink = sink };
        }

        pub fn deinit(t: *Self) void {
            inline for (.{ &t.last_start_tag, &t.chars, &t.tag_name, &t.attr_bytes, &t.temp, &t.comment_buf, &t.dt_name, &t.dt_public, &t.dt_system }) |l| l.deinit(t.gpa);
            t.attr_ranges.deinit(t.gpa);
            t.attrs_out.deinit(t.gpa);
        }

        /// Runs to the end of the input, sending every token to the sink.
        pub fn run(t: *Self) Error!void {
            while (!t.done) try t.step();
        }

        fn peekByte(t: *const Self) ?u8 {
            return if (t.pos < t.input.len) t.input[t.pos] else null;
        }

        /// The next code point, or null at the end of the input. Invalid
        /// UTF-8 decodes as U+FFFD a byte at a time.
        fn next(t: *Self) ?u21 {
            if (t.pos >= t.input.len) {
                t.pos += 1; // so that reconsuming at EOF stays at EOF
                t.last_len = 1;
                return null;
            }
            const b = t.input[t.pos];
            t.last_len = 1;
            if (b < 0x80) {
                t.pos += 1;
                return b;
            }
            const l = std.unicode.utf8ByteSequenceLength(b) catch {
                t.pos += 1;
                return 0xFFFD;
            };
            if (t.pos + l > t.input.len) {
                t.pos += 1;
                return 0xFFFD;
            }
            const cp = std.unicode.utf8Decode(t.input[t.pos..][0..l]) catch {
                t.pos += 1;
                return 0xFFFD;
            };
            t.pos += l;
            t.last_len = l;
            return cp;
        }

        /// Steps back over the code point `next` just returned (reconsume).
        fn back(t: *Self, c: ?u21) void {
            _ = c;
            t.pos -= t.last_len;
        }

        fn appendCp(t: *Self, list: *std.ArrayList(u8), cp: u21) Error!void {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch {
                try list.appendSlice(t.gpa, "\u{FFFD}");
                return;
            };
            try list.appendSlice(t.gpa, buf[0..n]);
        }

        fn emitChar(t: *Self, cp: u21) Error!void {
            try t.appendCp(&t.chars, cp);
        }

        fn emitStr(t: *Self, s: []const u8) Error!void {
            try t.chars.appendSlice(t.gpa, s);
        }

        fn flushChars(t: *Self) Error!void {
            if (t.chars.items.len == 0) return;
            try t.sink.token(.{ .chars = t.chars.items });
            t.chars.clearRetainingCapacity();
        }

        fn emit(t: *Self, tok: Token) Error!void {
            try t.flushChars();
            try t.sink.token(tok);
        }

        fn startTag(t: *Self, end: bool) void {
            t.is_end_tag = end;
            t.self_closing = false;
            t.tag_name.clearRetainingCapacity();
            t.attr_bytes.clearRetainingCapacity();
            t.attr_ranges.clearRetainingCapacity();
        }

        fn startAttr(t: *Self) Error!void {
            const at: u32 = @intCast(t.attr_bytes.items.len);
            try t.attr_ranges.append(t.gpa, .{ at, at, at });
        }

        fn attrNameChar(t: *Self, cp: u21) Error!void {
            try t.appendCp(&t.attr_bytes, cp);
            const r = &t.attr_ranges.items[t.attr_ranges.items.len - 1];
            r[1] = @intCast(t.attr_bytes.items.len);
            r[2] = r[1];
        }

        fn attrValueChar(t: *Self, cp: u21) Error!void {
            try t.appendCp(&t.attr_bytes, cp);
            t.attr_ranges.items[t.attr_ranges.items.len - 1][2] = @intCast(t.attr_bytes.items.len);
        }

        fn attrValueStr(t: *Self, s: []const u8) Error!void {
            try t.attr_bytes.appendSlice(t.gpa, s);
            t.attr_ranges.items[t.attr_ranges.items.len - 1][2] = @intCast(t.attr_bytes.items.len);
        }

        fn emitTag(t: *Self) Error!void {
            t.attrs_out.clearRetainingCapacity();
            const bytes = t.attr_bytes.items;
            outer: for (t.attr_ranges.items) |r| {
                const n = bytes[r[0]..r[1]];
                // Duplicate attributes are dropped (parse error).
                for (t.attrs_out.items) |prev| if (std.mem.eql(u8, prev.name, n)) continue :outer;
                try t.attrs_out.append(t.gpa, .{ .name = n, .value = bytes[r[1]..r[2]] });
            }
            const tag: Tag = .{ .name = t.tag_name.items, .attrs = t.attrs_out.items, .self_closing = t.self_closing };
            if (t.is_end_tag) {
                try t.emit(.{ .end_tag = tag });
            } else {
                t.last_start_tag.clearRetainingCapacity();
                try t.last_start_tag.appendSlice(t.gpa, t.tag_name.items);
                try t.emit(.{ .start_tag = tag });
            }
        }

        fn appropriateEndTag(t: *const Self) bool {
            return t.is_end_tag and std.mem.eql(u8, t.tag_name.items, t.last_start_tag.items);
        }

        fn emitDoctype(t: *Self) Error!void {
            try t.emit(.{ .doctype = .{
                .name = if (t.dt_has_name) t.dt_name.items else null,
                .public_id = if (t.dt_has_public) t.dt_public.items else null,
                .system_id = if (t.dt_has_system) t.dt_system.items else null,
                .force_quirks = t.dt_quirks,
            } });
        }

        fn newDoctype(t: *Self) void {
            t.dt_name.clearRetainingCapacity();
            t.dt_public.clearRetainingCapacity();
            t.dt_system.clearRetainingCapacity();
            t.dt_has_name = false;
            t.dt_has_public = false;
            t.dt_has_system = false;
            t.dt_quirks = false;
        }

        fn emitComment(t: *Self) Error!void {
            try t.emit(.{ .comment = t.comment_buf.items });
        }

        fn eof(t: *Self) Error!void {
            try t.emit(.eof);
            t.done = true;
        }

        fn lower(cp: u21) u21 {
            return if (cp >= 'A' and cp <= 'Z') cp + 0x20 else cp;
        }

        fn isAlpha(cp: u21) bool {
            return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z');
        }

        fn isWs(cp: u21) bool {
            return cp == '\t' or cp == '\n' or cp == 0x0C or cp == ' ';
        }

        /// Matches `s` (ASCII) at the input position, case-insensitively
        /// when asked, and consumes it.
        fn matchAhead(t: *Self, s: []const u8, insensitive: bool) bool {
            if (t.pos + s.len > t.input.len) return false;
            const got = t.input[t.pos..][0..s.len];
            const ok = if (insensitive) std.ascii.eqlIgnoreCase(got, s) else std.mem.eql(u8, got, s);
            if (ok) t.pos += s.len;
            return ok;
        }

        fn inAttribute(t: *const Self) bool {
            return switch (t.return_state) {
                .attr_value_double, .attr_value_single, .attr_value_unquoted => true,
                else => false,
            };
        }

        /// Flushes code points consumed as a character reference (13.2.5.72).
        fn flushRef(t: *Self, s: []const u8) Error!void {
            if (t.inAttribute()) try t.attrValueStr(s) else try t.emitStr(s);
        }

        fn flushRefCp(t: *Self, cp: u21) Error!void {
            if (t.inAttribute()) try t.attrValueChar(cp) else try t.emitChar(cp);
        }

        /// The character reference state and its sub-states, run to the
        /// end at once since they never emit tags.
        fn charRef(t: *Self) Error!void {
            // After '&'.
            const c = t.peekByte();
            if (c != null and std.ascii.isAlphanumeric(c.?)) return t.namedRef();
            if (c == '#') {
                t.pos += 1;
                return t.numericRef();
            }
            try t.flushRef("&");
        }

        fn namedRef(t: *Self) Error!void {
            const list = &entities.list;
            var lo: usize = 0;
            var hi: usize = list.len;
            var best: ?usize = null;
            var best_len: usize = 0;
            var k: usize = 0;
            while (t.pos + k < t.input.len and lo < hi) : (k += 1) {
                const ch = t.input[t.pos + k];
                // Narrow to names whose byte k is ch.
                var nlo = lo;
                while (nlo < hi and (list[nlo].name.len <= k or list[nlo].name[k] < ch)) nlo += 1;
                var nhi = nlo;
                while (nhi < hi and list[nhi].name.len > k and list[nhi].name[k] == ch) nhi += 1;
                lo = nlo;
                hi = nhi;
                if (lo < hi and list[lo].name.len == k + 1) {
                    best = lo;
                    best_len = k + 1;
                }
                if (ch == ';') break;
            }
            if (best) |i| {
                const e = list[i];
                const semi = e.name[e.name.len - 1] == ';';
                if (t.inAttribute() and !semi) {
                    const after = t.peekAt(best_len);
                    if (after != null and (after.? == '=' or std.ascii.isAlphanumeric(after.?))) {
                        // Historical: flush as written.
                        try t.flushRef("&");
                        try t.flushRef(t.input[t.pos..][0..best_len]);
                        t.pos += best_len;
                        return;
                    }
                }
                t.pos += best_len;
                try t.flushRefCp(e.cp[0]);
                if (e.cp[1] != 0) try t.flushRefCp(e.cp[1]);
                return;
            }
            // Ambiguous ampersand: flush '&' and the alphanumerics after it.
            try t.flushRef("&");
            while (t.peekByte()) |b| {
                if (!std.ascii.isAlphanumeric(b)) break;
                try t.flushRefCp(b);
                t.pos += 1;
            }
        }

        fn peekAt(t: *const Self, k: usize) ?u8 {
            return if (t.pos + k < t.input.len) t.input[t.pos + k] else null;
        }

        fn numericRef(t: *Self) Error!void {
            var hex = false;
            const start = t.pos;
            if (t.peekByte()) |b| if (b == 'x' or b == 'X') {
                hex = true;
                t.pos += 1;
            };
            var code: u32 = 0;
            var digits: usize = 0;
            while (t.peekByte()) |b| {
                const v: ?u32 = if (b >= '0' and b <= '9') b - '0' else if (hex and b >= 'a' and b <= 'f') b - 'a' + 10 else if (hex and b >= 'A' and b <= 'F') b - 'A' + 10 else null;
                const d = v orelse break;
                code = if (code > 0x10FFFF) code else code * (if (hex) @as(u32, 16) else 10) + d;
                digits += 1;
                t.pos += 1;
            }
            if (digits == 0) {
                // Absence of digits: flush "&#" (and the x).
                t.pos = start;
                try t.flushRef("&#");
                return;
            }
            if (t.peekByte() == ';') t.pos += 1;
            try t.flushRefCp(numericValue(code));
        }

        fn step(t: *Self) Error!void {
            switch (t.state) {
                .data => {
                    // Fast path: a run of ordinary bytes.
                    const start = t.pos;
                    while (t.pos < t.input.len) : (t.pos += 1) switch (t.input[t.pos]) {
                        '<', '&' => break,
                        else => {},
                    };
                    if (t.pos > start) try t.emitStr(t.input[start..t.pos]);
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        '&' => {
                            t.return_state = .data;
                            try t.charRef();
                        },
                        '<' => t.state = .tag_open,
                        else => unreachable,
                    }
                },
                .rcdata => {
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        '&' => {
                            t.return_state = .rcdata;
                            try t.charRef();
                        },
                        '<' => t.state = .rcdata_lt,
                        0 => try t.emitStr("\u{FFFD}"),
                        else => try t.emitChar(c),
                    }
                },
                .rawtext, .script_data, .plaintext => {
                    const start = t.pos;
                    const lt = t.state != .plaintext;
                    while (t.pos < t.input.len) : (t.pos += 1) {
                        const b = t.input[t.pos];
                        if (b == 0 or (lt and b == '<')) break;
                    }
                    if (t.pos > start) try t.emitStr(t.input[start..t.pos]);
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        0 => try t.emitStr("\u{FFFD}"),
                        '<' => t.state = if (t.state == .rawtext) .rawtext_lt else .script_lt,
                        else => unreachable,
                    }
                },
                .tag_open => {
                    const c = t.next();
                    if (c == null) {
                        try t.emitStr("<");
                        return t.eof();
                    }
                    switch (c.?) {
                        '!' => t.state = .markup_declaration_open,
                        '/' => t.state = .end_tag_open,
                        '?' => {
                            t.comment_buf.clearRetainingCapacity();
                            t.back(c);
                            t.state = .bogus_comment;
                        },
                        else => if (isAlpha(c.?)) {
                            t.startTag(false);
                            t.back(c);
                            t.state = .tag_name;
                        } else {
                            try t.emitStr("<");
                            t.back(c);
                            t.state = .data;
                        },
                    }
                },
                .end_tag_open => {
                    const c = t.next();
                    if (c == null) {
                        try t.emitStr("</");
                        return t.eof();
                    }
                    if (isAlpha(c.?)) {
                        t.startTag(true);
                        t.back(c);
                        t.state = .tag_name;
                    } else if (c.? == '>') {
                        t.state = .data;
                    } else {
                        t.comment_buf.clearRetainingCapacity();
                        t.back(c);
                        t.state = .bogus_comment;
                    }
                },
                .tag_name => {
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        '\t', '\n', 0x0C, ' ' => t.state = .before_attr_name,
                        '/' => t.state = .self_closing_start_tag,
                        '>' => {
                            t.state = .data;
                            try t.emitTag();
                        },
                        0 => try t.tag_name.appendSlice(t.gpa, "\u{FFFD}"),
                        else => try t.appendCp(&t.tag_name, lower(c)),
                    }
                },
                .rcdata_lt, .rawtext_lt, .script_lt => {
                    const c = t.next();
                    if (c == '/') {
                        t.temp.clearRetainingCapacity();
                        t.state = switch (t.state) {
                            .rcdata_lt => .rcdata_end_tag_open,
                            .rawtext_lt => .rawtext_end_tag_open,
                            else => .script_end_tag_open,
                        };
                    } else if (t.state == .script_lt and c == '!') {
                        t.state = .script_escape_start;
                        try t.emitStr("<!");
                    } else {
                        try t.emitStr("<");
                        t.back(c);
                        t.state = switch (t.state) {
                            .rcdata_lt => .rcdata,
                            .rawtext_lt => .rawtext,
                            else => .script_data,
                        };
                    }
                },
                .rcdata_end_tag_open, .rawtext_end_tag_open, .script_end_tag_open, .script_escaped_end_tag_open => {
                    const c = t.next();
                    const base: State = switch (t.state) {
                        .rcdata_end_tag_open => .rcdata,
                        .rawtext_end_tag_open => .rawtext,
                        .script_end_tag_open => .script_data,
                        else => .script_escaped,
                    };
                    if (c != null and isAlpha(c.?)) {
                        t.startTag(true);
                        t.back(c);
                        t.state = switch (base) {
                            .rcdata => .rcdata_end_tag_name,
                            .rawtext => .rawtext_end_tag_name,
                            .script_data => .script_end_tag_name,
                            else => .script_escaped_end_tag_name,
                        };
                    } else {
                        try t.emitStr("</");
                        t.back(c);
                        t.state = base;
                    }
                },
                .rcdata_end_tag_name, .rawtext_end_tag_name, .script_end_tag_name, .script_escaped_end_tag_name => {
                    const base: State = switch (t.state) {
                        .rcdata_end_tag_name => .rcdata,
                        .rawtext_end_tag_name => .rawtext,
                        .script_end_tag_name => .script_data,
                        else => .script_escaped,
                    };
                    const c = t.next();
                    if (c) |cp| {
                        if (isWs(cp) and t.appropriateEndTag()) {
                            t.state = .before_attr_name;
                            return;
                        }
                        if (cp == '/' and t.appropriateEndTag()) {
                            t.state = .self_closing_start_tag;
                            return;
                        }
                        if (cp == '>' and t.appropriateEndTag()) {
                            t.state = .data;
                            try t.emitTag();
                            return;
                        }
                        if (isAlpha(cp)) {
                            try t.appendCp(&t.tag_name, lower(cp));
                            try t.appendCp(&t.temp, cp);
                            return;
                        }
                    }
                    try t.emitStr("</");
                    try t.emitStr(t.temp.items);
                    t.back(c);
                    t.state = base;
                },
                .script_escape_start, .script_escape_start_dash => {
                    const c = t.next();
                    if (c == '-') {
                        try t.emitStr("-");
                        t.state = if (t.state == .script_escape_start) .script_escape_start_dash else .script_escaped_dash_dash;
                    } else {
                        t.back(c);
                        t.state = .script_data;
                    }
                },
                .script_escaped => {
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        '-' => {
                            t.state = .script_escaped_dash;
                            try t.emitStr("-");
                        },
                        '<' => t.state = .script_escaped_lt,
                        0 => try t.emitStr("\u{FFFD}"),
                        else => try t.emitChar(c),
                    }
                },
                .script_escaped_dash, .script_escaped_dash_dash => {
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        '-' => {
                            t.state = .script_escaped_dash_dash;
                            try t.emitStr("-");
                        },
                        '<' => t.state = .script_escaped_lt,
                        '>' => {
                            if (t.state == .script_escaped_dash_dash) {
                                t.state = .script_data;
                                try t.emitStr(">");
                            } else {
                                t.state = .script_escaped;
                                try t.emitStr(">");
                            }
                        },
                        0 => {
                            t.state = .script_escaped;
                            try t.emitStr("\u{FFFD}");
                        },
                        else => {
                            t.state = .script_escaped;
                            try t.emitChar(c);
                        },
                    }
                },
                .script_escaped_lt => {
                    const c = t.next();
                    if (c == '/') {
                        t.temp.clearRetainingCapacity();
                        t.state = .script_escaped_end_tag_open;
                    } else if (c != null and isAlpha(c.?)) {
                        t.temp.clearRetainingCapacity();
                        try t.emitStr("<");
                        t.back(c);
                        t.state = .script_double_escape_start;
                    } else {
                        try t.emitStr("<");
                        t.back(c);
                        t.state = .script_escaped;
                    }
                },
                .script_double_escape_start, .script_double_escape_end => {
                    const c = t.next();
                    const starting = t.state == .script_double_escape_start;
                    if (c) |cp| {
                        if (isWs(cp) or cp == '/' or cp == '>') {
                            const is_script = std.mem.eql(u8, t.temp.items, "script");
                            t.state = if (starting)
                                (if (is_script) .script_double_escaped else .script_escaped)
                            else
                                (if (is_script) .script_escaped else .script_double_escaped);
                            try t.emitChar(cp);
                            return;
                        }
                        if (isAlpha(cp)) {
                            try t.appendCp(&t.temp, lower(cp));
                            try t.emitChar(cp);
                            return;
                        }
                    }
                    t.back(c);
                    t.state = if (starting) .script_escaped else .script_double_escaped;
                },
                .script_double_escaped => {
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        '-' => {
                            t.state = .script_double_escaped_dash;
                            try t.emitStr("-");
                        },
                        '<' => {
                            t.state = .script_double_escaped_lt;
                            try t.emitStr("<");
                        },
                        0 => try t.emitStr("\u{FFFD}"),
                        else => try t.emitChar(c),
                    }
                },
                .script_double_escaped_dash, .script_double_escaped_dash_dash => {
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        '-' => {
                            t.state = .script_double_escaped_dash_dash;
                            try t.emitStr("-");
                        },
                        '<' => {
                            t.state = .script_double_escaped_lt;
                            try t.emitStr("<");
                        },
                        '>' => {
                            if (t.state == .script_double_escaped_dash_dash) {
                                t.state = .script_data;
                            } else t.state = .script_double_escaped;
                            try t.emitStr(">");
                        },
                        0 => {
                            t.state = .script_double_escaped;
                            try t.emitStr("\u{FFFD}");
                        },
                        else => {
                            t.state = .script_double_escaped;
                            try t.emitChar(c);
                        },
                    }
                },
                .script_double_escaped_lt => {
                    const c = t.next();
                    if (c == '/') {
                        t.temp.clearRetainingCapacity();
                        t.state = .script_double_escape_end;
                        try t.emitStr("/");
                    } else {
                        t.back(c);
                        t.state = .script_double_escaped;
                    }
                },
                .before_attr_name => {
                    const c = t.next();
                    if (c) |cp| switch (cp) {
                        '\t', '\n', 0x0C, ' ' => return,
                        '/', '>' => {},
                        '=' => {
                            try t.startAttr();
                            try t.attrNameChar(cp);
                            t.state = .attr_name;
                            return;
                        },
                        else => {
                            try t.startAttr();
                            t.back(c);
                            t.state = .attr_name;
                            return;
                        },
                    };
                    t.back(c);
                    t.state = .after_attr_name;
                },
                .attr_name => {
                    const c = t.next();
                    if (c) |cp| switch (cp) {
                        '\t', '\n', 0x0C, ' ', '/', '>' => {},
                        '=' => {
                            t.state = .before_attr_value;
                            return;
                        },
                        0 => {
                            try t.attrNameChar(0xFFFD);
                            return;
                        },
                        else => {
                            try t.attrNameChar(lower(cp));
                            return;
                        },
                    };
                    t.back(c);
                    t.state = .after_attr_name;
                },
                .after_attr_name => {
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        '\t', '\n', 0x0C, ' ' => {},
                        '/' => t.state = .self_closing_start_tag,
                        '=' => t.state = .before_attr_value,
                        '>' => {
                            t.state = .data;
                            try t.emitTag();
                        },
                        else => {
                            try t.startAttr();
                            t.back(c);
                            t.state = .attr_name;
                        },
                    }
                },
                .before_attr_value => {
                    const c = t.next();
                    if (c) |cp| switch (cp) {
                        '\t', '\n', 0x0C, ' ' => return,
                        '"' => {
                            t.state = .attr_value_double;
                            return;
                        },
                        '\'' => {
                            t.state = .attr_value_single;
                            return;
                        },
                        '>' => {
                            t.state = .data;
                            try t.emitTag();
                            return;
                        },
                        else => {},
                    };
                    t.back(c);
                    t.state = .attr_value_unquoted;
                },
                .attr_value_double, .attr_value_single => {
                    const quote: u8 = if (t.state == .attr_value_double) '"' else '\'';
                    const start = t.pos;
                    while (t.pos < t.input.len) : (t.pos += 1) {
                        const b = t.input[t.pos];
                        if (b == quote or b == '&' or b == 0) break;
                    }
                    if (t.pos > start) try t.attrValueStr(t.input[start..t.pos]);
                    const c = t.next() orelse return t.eof();
                    if (c == quote) {
                        t.state = .after_attr_value_quoted;
                    } else if (c == '&') {
                        t.return_state = t.state;
                        try t.charRef();
                    } else try t.attrValueChar(0xFFFD);
                },
                .attr_value_unquoted => {
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        '\t', '\n', 0x0C, ' ' => t.state = .before_attr_name,
                        '&' => {
                            t.return_state = .attr_value_unquoted;
                            try t.charRef();
                        },
                        '>' => {
                            t.state = .data;
                            try t.emitTag();
                        },
                        0 => try t.attrValueChar(0xFFFD),
                        else => try t.attrValueChar(c),
                    }
                },
                .after_attr_value_quoted => {
                    const c = t.next() orelse return t.eof();
                    switch (c) {
                        '\t', '\n', 0x0C, ' ' => t.state = .before_attr_name,
                        '/' => t.state = .self_closing_start_tag,
                        '>' => {
                            t.state = .data;
                            try t.emitTag();
                        },
                        else => {
                            t.back(c);
                            t.state = .before_attr_name;
                        },
                    }
                },
                .self_closing_start_tag => {
                    const c = t.next() orelse return t.eof();
                    if (c == '>') {
                        t.self_closing = true;
                        t.state = .data;
                        try t.emitTag();
                    } else {
                        t.back(c);
                        t.state = .before_attr_name;
                    }
                },
                .bogus_comment => {
                    const c = t.next();
                    if (c == null) {
                        try t.emitComment();
                        return t.eof();
                    }
                    switch (c.?) {
                        '>' => {
                            t.state = .data;
                            try t.emitComment();
                        },
                        0 => try t.comment_buf.appendSlice(t.gpa, "\u{FFFD}"),
                        else => try t.appendCp(&t.comment_buf, c.?),
                    }
                },
                .markup_declaration_open => {
                    if (t.matchAhead("--", false)) {
                        t.comment_buf.clearRetainingCapacity();
                        t.state = .comment_start;
                    } else if (t.matchAhead("DOCTYPE", true)) {
                        t.state = .doctype;
                    } else if (t.matchAhead("[CDATA[", false)) {
                        if (t.sink.cdataAllowed()) {
                            t.state = .cdata_section;
                        } else {
                            t.comment_buf.clearRetainingCapacity();
                            try t.comment_buf.appendSlice(t.gpa, "[CDATA[");
                            t.state = .bogus_comment;
                        }
                    } else {
                        t.comment_buf.clearRetainingCapacity();
                        t.state = .bogus_comment;
                    }
                },
                .comment_start => {
                    const c = t.next();
                    if (c == '-') {
                        t.state = .comment_start_dash;
                    } else if (c == '>') {
                        t.state = .data;
                        try t.emitComment();
                    } else {
                        t.back(c);
                        t.state = .comment;
                    }
                },
                .comment_start_dash => {
                    const c = t.next();
                    if (c == null) {
                        try t.emitComment();
                        return t.eof();
                    }
                    if (c.? == '-') {
                        t.state = .comment_end;
                    } else if (c.? == '>') {
                        t.state = .data;
                        try t.emitComment();
                    } else {
                        try t.comment_buf.append(t.gpa, '-');
                        t.back(c);
                        t.state = .comment;
                    }
                },
                .comment => {
                    const start = t.pos;
                    while (t.pos < t.input.len) : (t.pos += 1) switch (t.input[t.pos]) {
                        '<', '-', 0 => break,
                        else => {},
                    };
                    if (t.pos > start) try t.comment_buf.appendSlice(t.gpa, t.input[start..t.pos]);
                    const c = t.next();
                    if (c == null) {
                        try t.emitComment();
                        return t.eof();
                    }
                    switch (c.?) {
                        '<' => {
                            try t.comment_buf.append(t.gpa, '<');
                            t.state = .comment_lt;
                        },
                        '-' => t.state = .comment_end_dash,
                        0 => try t.comment_buf.appendSlice(t.gpa, "\u{FFFD}"),
                        else => unreachable,
                    }
                },
                .comment_lt => {
                    const c = t.next();
                    if (c == '!') {
                        try t.comment_buf.append(t.gpa, '!');
                        t.state = .comment_lt_bang;
                    } else if (c == '<') {
                        try t.comment_buf.append(t.gpa, '<');
                    } else {
                        t.back(c);
                        t.state = .comment;
                    }
                },
                .comment_lt_bang => {
                    const c = t.next();
                    if (c == '-') t.state = .comment_lt_bang_dash else {
                        t.back(c);
                        t.state = .comment;
                    }
                },
                .comment_lt_bang_dash => {
                    const c = t.next();
                    if (c == '-') t.state = .comment_lt_bang_dash_dash else {
                        t.back(c);
                        t.state = .comment_end_dash;
                    }
                },
                .comment_lt_bang_dash_dash => {
                    const c = t.next();
                    t.back(c);
                    t.state = .comment_end;
                },
                .comment_end_dash => {
                    const c = t.next();
                    if (c == null) {
                        try t.emitComment();
                        return t.eof();
                    }
                    if (c.? == '-') t.state = .comment_end else {
                        try t.comment_buf.append(t.gpa, '-');
                        t.back(c);
                        t.state = .comment;
                    }
                },
                .comment_end => {
                    const c = t.next();
                    if (c == null) {
                        try t.emitComment();
                        return t.eof();
                    }
                    switch (c.?) {
                        '>' => {
                            t.state = .data;
                            try t.emitComment();
                        },
                        '!' => t.state = .comment_end_bang,
                        '-' => try t.comment_buf.append(t.gpa, '-'),
                        else => {
                            try t.comment_buf.appendSlice(t.gpa, "--");
                            t.back(c);
                            t.state = .comment;
                        },
                    }
                },
                .comment_end_bang => {
                    const c = t.next();
                    if (c == null) {
                        try t.emitComment();
                        return t.eof();
                    }
                    switch (c.?) {
                        '-' => {
                            try t.comment_buf.appendSlice(t.gpa, "--!");
                            t.state = .comment_end_dash;
                        },
                        '>' => {
                            t.state = .data;
                            try t.emitComment();
                        },
                        else => {
                            try t.comment_buf.appendSlice(t.gpa, "--!");
                            t.back(c);
                            t.state = .comment;
                        },
                    }
                },
                .doctype => {
                    t.newDoctype();
                    const c = t.next();
                    if (c == null) {
                        t.dt_quirks = true;
                        try t.emitDoctype();
                        return t.eof();
                    }
                    if (isWs(c.?)) {
                        t.state = .before_doctype_name;
                    } else {
                        t.back(c);
                        t.state = .before_doctype_name;
                    }
                },
                .before_doctype_name => {
                    const c = t.next();
                    if (c == null) {
                        t.dt_quirks = true;
                        try t.emitDoctype();
                        return t.eof();
                    }
                    switch (c.?) {
                        '\t', '\n', 0x0C, ' ' => {},
                        '>' => {
                            t.dt_quirks = true;
                            t.state = .data;
                            try t.emitDoctype();
                        },
                        0 => {
                            t.dt_has_name = true;
                            try t.dt_name.appendSlice(t.gpa, "\u{FFFD}");
                            t.state = .doctype_name;
                        },
                        else => {
                            t.dt_has_name = true;
                            try t.appendCp(&t.dt_name, lower(c.?));
                            t.state = .doctype_name;
                        },
                    }
                },
                .doctype_name => {
                    const c = t.next();
                    if (c == null) {
                        t.dt_quirks = true;
                        try t.emitDoctype();
                        return t.eof();
                    }
                    switch (c.?) {
                        '\t', '\n', 0x0C, ' ' => t.state = .after_doctype_name,
                        '>' => {
                            t.state = .data;
                            try t.emitDoctype();
                        },
                        0 => try t.dt_name.appendSlice(t.gpa, "\u{FFFD}"),
                        else => try t.appendCp(&t.dt_name, lower(c.?)),
                    }
                },
                .after_doctype_name => {
                    const c = t.next();
                    if (c == null) {
                        t.dt_quirks = true;
                        try t.emitDoctype();
                        return t.eof();
                    }
                    switch (c.?) {
                        '\t', '\n', 0x0C, ' ' => {},
                        '>' => {
                            t.state = .data;
                            try t.emitDoctype();
                        },
                        else => {
                            t.back(c);
                            if (t.matchAhead("PUBLIC", true)) {
                                t.state = .after_doctype_public_keyword;
                            } else if (t.matchAhead("SYSTEM", true)) {
                                t.state = .after_doctype_system_keyword;
                            } else {
                                t.dt_quirks = true;
                                t.state = .bogus_doctype;
                            }
                        },
                    }
                },
                .after_doctype_public_keyword, .before_doctype_public_id, .after_doctype_system_keyword, .before_doctype_system_id => {
                    const public = t.state == .after_doctype_public_keyword or t.state == .before_doctype_public_id;
                    const keyword = t.state == .after_doctype_public_keyword or t.state == .after_doctype_system_keyword;
                    const c = t.next();
                    if (c == null) {
                        t.dt_quirks = true;
                        try t.emitDoctype();
                        return t.eof();
                    }
                    switch (c.?) {
                        '\t', '\n', 0x0C, ' ' => {
                            if (keyword) t.state = if (public) .before_doctype_public_id else .before_doctype_system_id;
                        },
                        '"', '\'' => {
                            if (public) {
                                t.dt_has_public = true;
                                t.state = if (c.? == '"') .doctype_public_id_double else .doctype_public_id_single;
                            } else {
                                t.dt_has_system = true;
                                t.state = if (c.? == '"') .doctype_system_id_double else .doctype_system_id_single;
                            }
                        },
                        '>' => {
                            t.dt_quirks = true;
                            t.state = .data;
                            try t.emitDoctype();
                        },
                        else => {
                            t.dt_quirks = true;
                            t.back(c);
                            t.state = .bogus_doctype;
                        },
                    }
                },
                .doctype_public_id_double, .doctype_public_id_single, .doctype_system_id_double, .doctype_system_id_single => {
                    const public = t.state == .doctype_public_id_double or t.state == .doctype_public_id_single;
                    const quote: u21 = if (t.state == .doctype_public_id_double or t.state == .doctype_system_id_double) '"' else '\'';
                    const buf = if (public) &t.dt_public else &t.dt_system;
                    const c = t.next();
                    if (c == null) {
                        t.dt_quirks = true;
                        try t.emitDoctype();
                        return t.eof();
                    }
                    if (c.? == quote) {
                        t.state = if (public) .after_doctype_public_id else .after_doctype_system_id;
                    } else if (c.? == '>') {
                        t.dt_quirks = true;
                        t.state = .data;
                        try t.emitDoctype();
                    } else if (c.? == 0) {
                        try buf.appendSlice(t.gpa, "\u{FFFD}");
                    } else try t.appendCp(buf, c.?);
                },
                .after_doctype_public_id, .between_doctype_ids => {
                    const between = t.state == .between_doctype_ids;
                    const c = t.next();
                    if (c == null) {
                        t.dt_quirks = true;
                        try t.emitDoctype();
                        return t.eof();
                    }
                    switch (c.?) {
                        '\t', '\n', 0x0C, ' ' => t.state = .between_doctype_ids,
                        '>' => {
                            t.state = .data;
                            try t.emitDoctype();
                        },
                        '"', '\'' => {
                            t.dt_has_system = true;
                            t.state = if (c.? == '"') .doctype_system_id_double else .doctype_system_id_single;
                        },
                        else => {
                            _ = between;
                            t.dt_quirks = true;
                            t.back(c);
                            t.state = .bogus_doctype;
                        },
                    }
                },
                .after_doctype_system_id => {
                    const c = t.next();
                    if (c == null) {
                        t.dt_quirks = true;
                        try t.emitDoctype();
                        return t.eof();
                    }
                    switch (c.?) {
                        '\t', '\n', 0x0C, ' ' => {},
                        '>' => {
                            t.state = .data;
                            try t.emitDoctype();
                        },
                        else => {
                            // Not force-quirks (parse error only).
                            t.back(c);
                            t.state = .bogus_doctype;
                        },
                    }
                },
                .bogus_doctype => {
                    const c = t.next();
                    if (c == null) {
                        try t.emitDoctype();
                        return t.eof();
                    }
                    if (c.? == '>') {
                        t.state = .data;
                        try t.emitDoctype();
                    }
                },
                .cdata_section => {
                    const start = t.pos;
                    while (t.pos < t.input.len and t.input[t.pos] != ']') t.pos += 1;
                    if (t.pos > start) try t.emitStr(t.input[start..t.pos]);
                    const c = t.next() orelse return t.eof();
                    _ = c;
                    t.state = .cdata_section_bracket;
                },
                .cdata_section_bracket => {
                    const c = t.next();
                    if (c == ']') t.state = .cdata_section_end else {
                        try t.emitStr("]");
                        t.back(c);
                        t.state = .cdata_section;
                    }
                },
                .cdata_section_end => {
                    const c = t.next();
                    if (c == ']') {
                        try t.emitStr("]");
                    } else if (c == '>') {
                        t.state = .data;
                    } else {
                        try t.emitStr("]]");
                        t.back(c);
                        t.state = .cdata_section;
                    }
                },
            }
        }
    };
}

/// A numeric character reference's code point (13.2.5.80).
pub fn numericValue(code: u32) u21 {
    if (code == 0 or code > 0x10FFFF) return 0xFFFD;
    if (code >= 0xD800 and code <= 0xDFFF) return 0xFFFD;
    if (code >= 0x80 and code <= 0x9F) {
        const table = [32]u21{ 0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178 };
        return table[code - 0x80];
    }
    return @intCast(code);
}

/// Decodes character references in an attribute-like string, for
/// callers outside the tokenizer (the Markdown parser's entities).
pub fn lookupEntity(name: []const u8) ?[2]u21 {
    const list = &entities.list;
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, list[mid].name, name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return list[mid].cp,
        }
    }
    return null;
}
