//! Vim's keys for the rich text editor (rich_text.zig, D22): normal,
//! insert, visual, and visual line modes, counts, operators with motions
//! and text objects, a register that keeps marks and blocks, undo by
//! command, dot repeat, search, and a command line.
//!
//! A "line" is a block (a paragraph): 0, $, dd, yy, and o work on blocks,
//! while j and k move by displayed lines, as gj and gk do, since a block
//! usually wraps. { and } go to the previous and next block.
//!
//! Keys reach the editor's key handler before siv's editing; in every
//! mode but insert, the handler takes every key that would type.

const std = @import("std");
const w = @import("widgets.zig");
const pt = @import("portable_text.zig");
const rt = @import("rich_text.zig");
const siv = w.siv;
const State = rt.State;

const gpa = std.heap.c_allocator;

pub const Mode = enum { normal, insert, visual, vline, cmdline };

/// A key as Vim names it: "w", "<Esc>", "<C-r>", or two joined ("gg").
const Tok = struct {
    buf: [8]u8 = undefined,
    len: u8 = 0,

    fn of(s: []const u8) ?Tok {
        if (s.len == 0 or s.len > 8) return null;
        var t: Tok = .{ .len = @intCast(s.len) };
        @memcpy(t.buf[0..s.len], s);
        return t;
    }
    fn str(t: *const Tok) []const u8 {
        return t.buf[0..t.len];
    }
    fn join(a: Tok, b: Tok) ?Tok {
        var buf: [16]u8 = undefined;
        @memcpy(buf[0..a.len], a.str());
        @memcpy(buf[a.len..][0..b.len], b.str());
        return of(buf[0 .. a.len + b.len]);
    }
    fn is(t: Tok, x: []const u8) bool {
        return std.mem.eql(u8, t.str(), x);
    }
};

const max_keys = 16;
const Keys = struct {
    toks: [max_keys]Tok = undefined,
    n: u8 = 0,

    fn slice(k: *const Keys) []const Tok {
        return k.toks[0..k.n];
    }
};

const Kind = enum { exclusive, inclusive, linewise };
const Target = struct { pos: u32, kind: Kind = .exclusive, keep_goal: bool = false };

const Cmd = struct {
    count: ?u32 = null,
    op: ?Tok = null,
    line: bool = false,
    motion: ?Tok = null,
    marg: ?Tok = null,
    object: ?Tok = null,
    inner: bool = false,
    cmd: ?Tok = null,
    arg: ?Tok = null,
};

const Parse = union(enum) { pending, invalid, cmd: Cmd };

const Change = struct {
    keys: Keys = .{},
    insert: []u8 = &.{},
};

const Register = struct { frag: pt.Model, linewise: bool };

fn inList(t: Tok, comptime list: []const []const u8) bool {
    inline for (list) |x| if (t.is(x)) return true;
    return false;
}

const motions = [_][]const u8{ "h", "<Left>", "<BS>", "l", "<Right>", " ", "w", "W", "e", "E", "b", "B", "0", "<Home>", "^", "$", "<End>", "gg", "G", "}", "{", "f", "t", "F", "T", ";", ",", "j", "k", "gj", "gk", "<Down>", "<Up>", "<C-d>", "<C-u>", "n", "N", "<CR>" };
const needs_char = [_][]const u8{ "f", "t", "F", "T" };
const objects = [_][]const u8{ "w", "W", "s", "p", "\"", "'", "(", ")", "b", "[", "]", "{", "}", "“", "”" };
const operators = [_][]const u8{ "d", "c", "y", ">", "<", "g~", "gu", "gU" };
const commands = [_][]const u8{ "x", "X", "D", "C", "s", "S", "Y", "p", "P", "J", "r", "~", "u", "<C-r>", ".", "i", "a", "I", "A", "o", "O", "v", "V", ":", "/", "?", "<Esc>", "zz", "zt", "zb", "<Insert>", "<Del>" };
/// Commands that change the text, for dot repeat.
const changes = [_][]const u8{ "x", "X", "D", "C", "s", "S", "p", "P", "J", "r", "~", "i", "a", "I", "A", "o", "O", "<Del>" };

// Text helpers. Offsets are bytes; a character is a code point. --------------

fn clen(s: []const u8, p: u32) u32 {
    if (p >= s.len) return 0;
    const n = std.unicode.utf8ByteSequenceLength(s[p]) catch 1;
    return @min(n, @as(u32, @intCast(s.len)) - p);
}

fn nextc(s: []const u8, p: u32) u32 {
    return @min(@as(u32, @intCast(s.len)), p + @max(1, clen(s, p)));
}

fn prevc(s: []const u8, p: u32) u32 {
    if (p == 0) return 0;
    var q = p - 1;
    while (q > 0 and s[q] & 0xc0 == 0x80) q -= 1;
    return q;
}

fn char(s: []const u8, p: u32) []const u8 {
    return s[@min(p, s.len)..@min(p + clen(s, p), s.len)];
}

fn bol(s: []const u8, p: u32) u32 {
    var q = @min(p, @as(u32, @intCast(s.len)));
    while (q > 0 and s[q - 1] != '\n') q -= 1;
    return q;
}

fn eol(s: []const u8, p: u32) u32 {
    return @intCast(std.mem.indexOfScalarPos(u8, s, @min(p, s.len), '\n') orelse s.len);
}

fn isSpace(ch: []const u8) bool {
    return ch.len == 0 or std.mem.eql(u8, ch, " ") or std.mem.eql(u8, ch, "\t") or std.mem.eql(u8, ch, "\n") or
        std.mem.eql(u8, ch, pt.line_separator) or std.mem.eql(u8, ch, "\u{a0}");
}

/// 0 space, 1 word, 2 punctuation.
fn cls(ch: []const u8, big: bool) u2 {
    if (isSpace(ch)) return 0;
    if (big or ch.len > 1 or std.ascii.isAlphanumeric(ch[0]) or ch[0] == '_') return 1;
    return 2;
}

fn firstNonblank(s: []const u8, p: u32) u32 {
    const e = eol(s, p);
    var q = bol(s, p);
    while (q < e and (s[q] == ' ' or s[q] == '\t')) q += 1;
    return q;
}

/// The block (line) of an offset, from 1.
fn lineOf(s: []const u8, p: u32) u32 {
    return @intCast(std.mem.count(u8, s[0..@min(p, s.len)], "\n") + 1);
}

fn lineStart(s: []const u8, n: u32) u32 {
    var p: u32 = 0;
    var i: u32 = 2;
    while (i <= n) : (i += 1) {
        const e = std.mem.indexOfScalarPos(u8, s, p, '\n') orelse break;
        p = @intCast(e + 1);
    }
    return p;
}

fn len32(s: []const u8) u32 {
    return @intCast(s.len);
}

/// Normal mode keeps the cursor on a character: not on a line's break
/// unless the line is empty.
fn clamp(s: []const u8, p: u32) u32 {
    const q = @min(p, len32(s));
    if ((q == s.len or s[q] == '\n') and q > bol(s, q)) return prevc(s, q);
    return q;
}

fn wordForward(s: []const u8, p0: u32, big: bool) u32 {
    var p = p0;
    const k = cls(char(s, p), big);
    if (k != 0) while (p < s.len and cls(char(s, p), big) == k) {
        p = nextc(s, p);
    };
    while (p < s.len and cls(char(s, p), big) == 0) {
        // An empty line is a word.
        if (s[p] == '\n' and p > 0 and s[p - 1] == '\n') break;
        p = nextc(s, p);
    }
    return p;
}

fn wordEnd(s: []const u8, p0: u32, big: bool) u32 {
    var p = nextc(s, p0);
    while (p < s.len and cls(char(s, p), big) == 0) p = nextc(s, p);
    const k = cls(char(s, p), big);
    while (p < s.len) {
        const n = nextc(s, p);
        if (n >= s.len or cls(char(s, n), big) != k) break;
        p = n;
    }
    return p;
}

fn wordBack(s: []const u8, p0: u32, big: bool) u32 {
    var p = prevc(s, p0);
    while (p > 0 and cls(char(s, p), big) == 0) p = prevc(s, p);
    const k = cls(char(s, p), big);
    while (p > 0) {
        const q = prevc(s, p);
        if (cls(char(s, q), big) != k) break;
        p = q;
    }
    return p;
}

fn findChar(s: []const u8, p: u32, count: u32, arg: []const u8, forward: bool, till: bool) ?u32 {
    const b = bol(s, p);
    const e = eol(s, p);
    var q = p;
    for (0..count) |_| {
        var r = q;
        while (true) {
            if (forward) {
                r = nextc(s, r);
                if (r >= e) return null;
            } else {
                if (r <= b) return null;
                r = prevc(s, r);
            }
            if (std.mem.eql(u8, char(s, r), arg)) break;
        }
        q = r;
    }
    if (till) return if (forward) prevc(s, q) else nextc(s, q);
    return q;
}

/// The range of whole blocks from p to q, with the break that joins them
/// to the document.
fn lineRange(s: []const u8, p: u32, q: u32) [4]u32 {
    const b = bol(s, @min(p, q));
    const e = eol(s, @max(p, q));
    var del_lo = b;
    var del_hi = e;
    if (e < s.len) del_hi = e + 1 else if (b > 0) del_lo = b - 1;
    return .{ b, e, del_lo, del_hi };
}

fn caseMap(s: []u8, how: u8) void {
    for (s) |*ch| ch.* = switch (how) {
        'u' => std.ascii.toLower(ch.*),
        'U' => std.ascii.toUpper(ch.*),
        else => if (std.ascii.isLower(ch.*)) std.ascii.toUpper(ch.*) else std.ascii.toLower(ch.*),
    };
}

/// A fragment shifted by `by` bytes, with text before it.
fn shifted(f: pt.Model, prefix: []const u8, text: []const u8) !pt.Model {
    const by: u32 = len32(prefix);
    const t = try std.mem.concat(gpa, u8, &.{ prefix, text });
    errdefer gpa.free(t);
    const blocks = try gpa.dupe(pt.Block, f.blocks);
    errdefer gpa.free(blocks);
    for (blocks) |*b| {
        b.start += by;
        b.stop += by;
    }
    const runs = try gpa.dupe(pt.Run, f.runs);
    for (runs) |*r| {
        r.start += by;
        r.stop += by;
    }
    return .{ .text = t, .blocks = blocks, .runs = runs };
}

/// A fragment repeated `count` times.
fn repeated(f: pt.Model, count: u32) !pt.Model {
    var t: std.ArrayList(u8) = .empty;
    errdefer t.deinit(gpa);
    var blocks: std.ArrayList(pt.Block) = .empty;
    errdefer blocks.deinit(gpa);
    var runs: std.ArrayList(pt.Run) = .empty;
    errdefer runs.deinit(gpa);
    for (0..count) |k| {
        const off: u32 = @intCast(k * f.text.len);
        try t.appendSlice(gpa, f.text);
        for (f.blocks) |b| try blocks.append(gpa, .{ .start = b.start + off, .stop = b.stop + off, .def = b.def });
        for (f.runs) |r| try runs.append(gpa, .{ .start = r.start + off, .stop = r.stop + off, .marks = r.marks, .ann = r.ann });
    }
    const tt = try t.toOwnedSlice(gpa);
    errdefer gpa.free(tt);
    const bb = try blocks.toOwnedSlice(gpa);
    errdefer gpa.free(bb);
    return .{ .text = tt, .blocks = bb, .runs = try runs.toOwnedSlice(gpa) };
}

pub const Vim = struct {
    mode: Mode = .normal,
    keys: Keys = .{},
    goal_x: ?f32 = null,
    anchor: u32 = 0,
    cur: u32 = 0,
    prompt: u8 = 0,
    cmdline: std.ArrayList(u8) = .empty,
    /// Vim's insert mode is one undo step with the command that began it.
    undo_held: bool = false,
    recording: ?Change = null,
    last_change: ?Change = null,
    replaying: bool = false,
    insert_start: u32 = 0,
    register: ?Register = null,
    search: std.ArrayList(u8) = .empty,
    search_back: bool = false,
    last_find: ?struct { name: Tok, arg: Tok } = null,

    pub fn deinit(v: *Vim) void {
        v.cmdline.deinit(gpa);
        v.search.deinit(gpa);
        if (v.recording) |r| gpa.free(r.insert);
        if (v.last_change) |r| gpa.free(r.insert);
        if (v.register) |r| r.frag.deinit(gpa);
    }

    pub fn reset(v: *Vim) void {
        v.mode = .normal;
        v.keys.n = 0;
        v.goal_x = null;
        v.anchor = 0;
        v.cmdline.clearRetainingCapacity();
        v.undo_held = false;
        if (v.recording) |r| gpa.free(r.insert);
        v.recording = null;
    }

    pub fn clearRegister(v: *Vim) void {
        if (v.register) |r| r.frag.deinit(gpa);
        v.register = null;
    }

    pub fn modal(v: *const Vim) bool {
        return v.mode != .insert;
    }

    pub fn modeOf(v: *const Vim) siv.RichTextMode {
        return switch (v.mode) {
            .normal => .normal,
            .insert => .insert,
            .visual => .visual,
            .vline => .visual_line,
            .cmdline => .command,
        };
    }

    /// The status line: the command line, or the keys typed so far.
    pub fn status(v: *const Vim, out: *std.ArrayList(u8)) bool {
        if (v.mode == .cmdline) {
            out.append(gpa, v.prompt) catch {};
            out.appendSlice(gpa, v.cmdline.items) catch {};
            return true;
        }
        for (v.keys.slice()) |t| out.appendSlice(gpa, t.str()) catch {};
        return v.keys.n > 0;
    }

    fn visual(v: *const Vim) bool {
        return v.mode == .visual or v.mode == .vline;
    }

    // Parsing ---------------------------------------------------------------

    fn parse(v: *const Vim, toks: []const Tok) Parse {
        var i: usize = 0;
        const P = struct {
            toks: []const Tok,
            i: *usize,
            fn take(p: @This()) ?Tok {
                if (p.i.* >= p.toks.len) return null;
                p.i.* += 1;
                return p.toks[p.i.* - 1];
            }
            fn count(p: @This()) ?u32 {
                var n: ?u32 = null;
                while (p.i.* < p.toks.len) {
                    const t = p.toks[p.i.*];
                    if (t.len != 1 or !std.ascii.isDigit(t.buf[0]) or (n == null and t.buf[0] == '0')) break;
                    n = (n orelse 0) *| 10 +| (t.buf[0] - '0');
                    p.i.* += 1;
                }
                return n;
            }
            /// A key, with g or z joined to the next.
            fn name(p: @This()) ??Tok {
                const t = p.take() orelse return null;
                if (t.is("g") or t.is("z")) {
                    const t2 = p.take() orelse return null;
                    return t.join(t2);
                }
                return t;
            }
            fn motion(p: @This(), m: Tok, cmd: *Cmd) Parse {
                if (inList(m, &needs_char)) {
                    cmd.marg = p.take() orelse return .pending;
                } else if (!inList(m, &motions)) return .invalid;
                cmd.motion = m;
                return .{ .cmd = cmd.* };
            }
        };
        const p: P = .{ .toks = toks, .i = &i };
        const c1 = p.count();
        const t = (p.name() orelse return .pending) orelse return .invalid;
        var cmd: Cmd = .{ .count = c1 };
        if (inList(t, &operators)) {
            cmd.op = t;
            if (v.visual()) return .{ .cmd = cmd };
            const c2 = p.count();
            const save = i;
            const m = (p.name() orelse return .pending) orelse return .invalid;
            if (std.mem.eql(u8, m.str(), t.str()) or std.mem.eql(u8, m.str(), t.str()[t.len - 1 ..])) {
                cmd.line = true;
                cmd.count = (c1 orelse 1) * (c2 orelse 1);
                return .{ .cmd = cmd };
            }
            if (c1 != null or c2 != null) cmd.count = (c1 orelse 1) * (c2 orelse 1);
            i = save;
            const m1 = p.take().?;
            if (m1.is("i") or m1.is("a")) {
                const o = p.take() orelse return .pending;
                if (!inList(o, &objects)) return .invalid;
                cmd.object = o;
                cmd.inner = m1.is("i");
                return .{ .cmd = cmd };
            }
            var mo = m1;
            if (m1.is("g")) mo = m1.join(p.take() orelse return .pending) orelse return .invalid;
            return p.motion(mo, &cmd);
        }
        if (v.visual() and (t.is("i") or t.is("a"))) {
            const o = p.take() orelse return .pending;
            if (!inList(o, &objects)) return .invalid;
            cmd.object = o;
            cmd.inner = t.is("i");
            return .{ .cmd = cmd };
        }
        if (t.is("r")) {
            cmd.arg = p.take() orelse return .pending;
            cmd.cmd = t;
            return .{ .cmd = cmd };
        }
        if (inList(t, &commands)) {
            cmd.cmd = t;
            return .{ .cmd = cmd };
        }
        return p.motion(t, &cmd);
    }

    // Keys -------------------------------------------------------------------

    fn token(ev: *const siv.Event) ?Tok {
        const k = ev.keysym;
        if (ev.modifiers.ctrl) {
            const sk: u32 = @bitCast(@intFromEnum(ev.shortcut_key));
            if (sk < 128 and std.ascii.isAlphabetic(@intCast(sk))) {
                var buf = "<C-x>".*;
                buf[3] = std.ascii.toLower(@intCast(sk));
                return Tok.of(&buf);
            }
            if (sk == '[') return Tok.of("<C-[>");
            return null;
        }
        const special: ?[]const u8 = switch (k) {
            w.keysym.escape => "<Esc>",
            w.keysym.@"return", w.keysym.kp_enter => "<CR>",
            w.keysym.backspace => "<BS>",
            w.keysym.tab => "<Tab>",
            w.keysym.iso_left_tab => "<S-Tab>",
            w.keysym.delete => "<Del>",
            w.keysym.left => "<Left>",
            w.keysym.right => "<Right>",
            w.keysym.up => "<Up>",
            w.keysym.down => "<Down>",
            w.keysym.home => "<Home>",
            w.keysym.end => "<End>",
            w.keysym.insert => "<Insert>",
            w.keysym.page_up => "<C-u>",
            w.keysym.page_down => "<C-d>",
            else => null,
        };
        if (special) |s| return Tok.of(s);
        const text = w.str(ev.text, ev.text_len) orelse return null;
        if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) return Tok.of(text);
        return null;
    }

    pub fn key(v: *Vim, st: *State, ev: *const siv.Event) bool {
        var tok = token(ev);
        const esc = if (tok) |t| t.is("<Esc>") or t.is("<C-[>") or t.is("<C-c>") else false;
        if (v.mode == .insert) {
            if (esc) {
                v.leaveInsert(st);
                return true;
            }
            return st.typingKey(ev);
        }
        if (v.mode == .cmdline) {
            if (tok) |t| v.cmdlineKey(st, if (esc) Tok.of("<Esc>").? else t);
            return true;
        }
        if (ev.modifiers.ctrl) {
            const own = if (tok) |t| t.is("<C-r>") or t.is("<C-d>") or t.is("<C-u>") or esc else false;
            if (!own) {
                // Formatting keys work on the visual selection; others
                // (Ctrl+S) are the application's.
                const took = st.formatKey(ev);
                if (took and v.visual()) v.draw(st, v.cur);
                return took;
            }
        }
        if (tok == null) return ev.text_len > 0;
        if (esc) tok = Tok.of("<Esc>");
        v.feed(st, tok.?);
        return true;
    }

    fn feed(v: *Vim, st: *State, tok: Tok) void {
        if (v.mode == .cmdline) return v.cmdlineKey(st, tok);
        if (v.keys.n == max_keys) v.keys.n = 0;
        v.keys.toks[v.keys.n] = tok;
        v.keys.n += 1;
        switch (v.parse(v.keys.slice())) {
            .pending => {},
            .invalid => {
                v.keys.n = 0;
                if (tok.is("<Esc>") and v.visual()) v.leaveVisual(st);
            },
            .cmd => |cmd| {
                const keys = v.keys;
                v.keys.n = 0;
                st.message.clearRetainingCapacity();
                v.run(st, cmd, keys);
            },
        }
        st.notifyLater();
    }

    // The cursor: the selection's caret, or in visual modes the end the
    // user moves.

    fn cursor(v: *const Vim, st: *const State) u32 {
        if (v.visual()) return v.cur;
        return st.selection()[0];
    }

    fn draw(v: *Vim, st: *State, p: u32) void {
        const s = st.text();
        switch (v.mode) {
            .visual => {
                v.cur = p;
                const a = v.anchor;
                if (p >= a) st.select(@max(nextc(s, p), p), a, null) else st.select(p, @max(nextc(s, a), a), null);
            },
            .vline => {
                v.cur = p;
                const lo = bol(s, @min(p, v.anchor));
                const hi = eol(s, @max(p, v.anchor));
                if (p >= v.anchor) st.select(hi, lo, p) else st.select(lo, hi, p);
            },
            else => {
                const q = clamp(s, p);
                st.select(q, q, null);
            },
        }
    }

    fn enterInsert(v: *Vim, st: *State, p: u32) void {
        v.mode = .insert;
        v.goal_x = null;
        v.insert_start = p;
        st.updateFlags(null);
        st.select(p, p, null);
    }

    fn leaveInsert(v: *Vim, st: *State) void {
        const s = st.text();
        const caret = st.selection()[0];
        if (v.recording) |*r| {
            if (caret >= v.insert_start and caret <= s.len) {
                gpa.free(r.insert);
                r.insert = gpa.dupe(u8, s[v.insert_start..caret]) catch &.{};
            }
            v.setLast(r.*);
            v.recording = null;
        }
        // An insert that typed nothing is no undo step.
        st.dropEmptyCheckpoint();
        v.mode = .normal;
        v.undo_held = false;
        st.group = null;
        st.updateFlags(null);
        var p = caret;
        if (p > bol(s, p)) p = prevc(s, p);
        const q = clamp(s, p);
        st.select(q, q, null);
        st.notifyLater();
    }

    fn leaveVisual(v: *Vim, st: *State) void {
        v.mode = .normal;
        v.draw(st, v.cur);
    }

    fn setLast(v: *Vim, ch: Change) void {
        if (v.last_change) |l| gpa.free(l.insert);
        v.last_change = ch;
    }

    /// Starts an undoable change at the cursor; keys are its keys for dot
    /// repeat.
    fn beginChange(v: *Vim, st: *State, keys: ?Keys, p: u32) void {
        st.checkpoint(p, p);
        if (!v.replaying) if (keys) |k| {
            if (v.recording) |r| gpa.free(r.insert);
            v.recording = .{ .keys = k };
        };
    }

    fn endChange(v: *Vim) void {
        if (v.mode == .insert) return;
        if (v.recording) |r| {
            v.setLast(r);
            v.recording = null;
        }
    }

    /// Records a change that did not go through beginChange.
    fn remember(v: *Vim, keys: ?Keys) void {
        if (v.replaying) return;
        if (keys) |k| v.setLast(.{ .keys = k });
    }

    fn yank(v: *Vim, st: *State, lo: u32, hi: u32, linewise: bool) void {
        var f = st.fragment(lo, hi) catch return;
        if (linewise) {
            const t = std.mem.concat(gpa, u8, &.{ f.text, "\n" }) catch {
                f.deinit(gpa);
                return;
            };
            gpa.free(f.text);
            f.text = t;
        }
        if (v.register) |r| r.frag.deinit(gpa);
        v.register = .{ .frag = f, .linewise = linewise };
    }

    /// Applies an operator to lo..hi (exclusive), whole blocks when
    /// linewise.
    fn operate(v: *Vim, st: *State, op: Tok, lo0: u32, hi0: u32, linewise: bool, keys: ?Keys, count: ?u32) void {
        var lo = lo0;
        var hi = hi0;
        const s = st.text();
        if (op.is("y")) {
            if (linewise) {
                const r = lineRange(s, lo, hi);
                v.yank(st, r[0], r[1], true);
                lo = r[0];
            } else v.yank(st, lo, hi, false);
            v.mode = .normal;
            v.draw(st, lo);
            return;
        }
        if (op.is(">") or op.is("<")) {
            v.mode = .normal;
            const n: i32 = @intCast(@min(count orelse 1, 8));
            _ = st.setBlock(.{ .indent = @intCast(if (op.is(">")) n else -n) }, lo, hi);
            st.edited();
            v.draw(st, lo);
            v.remember(keys);
            return;
        }
        v.beginChange(st, keys, lo);
        if (op.is("g~") or op.is("gu") or op.is("gU")) {
            if (linewise) {
                const r = lineRange(s, lo, hi);
                lo = r[0];
                hi = r[1];
            }
            const piece = gpa.dupe(u8, s[lo..hi]) catch return;
            defer gpa.free(piece);
            caseMap(piece, op.buf[1]);
            const f = st.fragment(lo, hi) catch return;
            defer f.deinit(gpa);
            st.replace(lo, hi, piece, &f);
            v.mode = .normal;
            v.draw(st, lo);
            v.endChange();
            return;
        }
        if (linewise) {
            const r = lineRange(s, lo, hi);
            v.yank(st, r[0], r[1], true);
            if (op.is("c")) {
                st.replace(r[0], r[1], "", null);
                v.undo_held = true;
                v.enterInsert(st, r[0]);
                return;
            }
            st.replace(r[2], r[3], "", null);
            v.mode = .normal;
            const t = st.text();
            v.draw(st, firstNonblank(t, @min(if (r[2] == r[0]) r[0] else r[2] + 1, len32(t))));
            v.endChange();
            return;
        }
        v.yank(st, lo, hi, false);
        st.replace(lo, hi, "", null);
        if (op.is("c")) {
            v.undo_held = true;
            v.enterInsert(st, lo);
            return;
        }
        v.mode = .normal;
        v.draw(st, lo);
        v.endChange();
    }

    fn put(v: *Vim, st: *State, before: bool, count: u32) void {
        const reg = v.register orelse {
            st.setMessage("Nothing in register");
            return;
        };
        const s = st.text();
        const p = v.cursor(st);
        v.beginChange(st, null, p);
        var frag = repeated(reg.frag, @max(count, 1)) catch return;
        defer frag.deinit(gpa);
        if (reg.linewise) {
            var at: u32 = undefined;
            var lead = false;
            if (before) {
                at = bol(s, p);
            } else {
                const e = eol(s, p);
                if (e < s.len) at = e + 1 else {
                    // After the last block: the break goes first.
                    at = len32(s);
                    const moved = shifted(frag, "\n", frag.text[0 .. frag.text.len - 1]) catch return;
                    frag.deinit(gpa);
                    frag = moved;
                    lead = true;
                }
            }
            st.replace(at, at, frag.text, &frag);
            v.draw(st, firstNonblank(st.text(), at + @intFromBool(lead)));
        } else {
            const at = if (before or p >= s.len or s[p] == '\n') p else nextc(s, p);
            st.replace(at, at, frag.text, &frag);
            v.draw(st, prevc(st.text(), at + len32(frag.text)));
        }
        v.endChange();
    }

    fn searchFrom(v: *Vim, st: *State, p: u32, count: u32, reverse: bool) ?u32 {
        const needle = v.search.items;
        if (needle.len == 0) return null;
        const s = st.text();
        var smart = true;
        for (needle) |ch| if (std.ascii.isUpper(ch)) {
            smart = false;
        };
        const findIn = struct {
            fn f(hay: []const u8, from: usize, n: []const u8, fold: bool) ?usize {
                if (from > hay.len) return null;
                return if (fold) std.ascii.findIgnoreCasePos(hay, from, n) else std.mem.indexOfPos(u8, hay, from, n);
            }
        }.f;
        const back = v.search_back != reverse;
        var q = p;
        for (0..count) |_| {
            var found: ?usize = null;
            if (!back) {
                found = findIn(s, q + 1, needle, smart) orelse findIn(s, 0, needle, smart);
            } else {
                // The last match before q, else wrap to the last one.
                var at: usize = 0;
                var before: ?usize = null;
                var last: ?usize = null;
                while (findIn(s, at, needle, smart)) |f| : (at = f + 1) {
                    if (f < q) before = f;
                    last = f;
                }
                found = before orelse last;
            }
            q = @intCast(found orelse {
                var buf: [256]u8 = undefined;
                st.setMessage(std.fmt.bufPrint(&buf, "Pattern not found: {s}", .{needle[0..@min(needle.len, 200)]}) catch "Pattern not found");
                return null;
            });
        }
        return q;
    }

    fn motion(v: *Vim, st: *State, cmd: Cmd, s: []const u8, p0: u32, count: u32) ?Target {
        const m = cmd.motion.?;
        const name = m.str();
        const operating = cmd.op != null;
        var p = p0;
        const eq = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.f;
        if (eq(name, "h") or eq(name, "<Left>")) {
            const b = bol(s, p);
            for (0..count) |_| if (p > b) {
                p = prevc(s, p);
            };
            return .{ .pos = p };
        }
        if (eq(name, "<BS>")) {
            for (0..count) |_| p = prevc(s, p);
            return .{ .pos = p };
        }
        if (eq(name, "l") or eq(name, "<Right>")) {
            const e = eol(s, p);
            for (0..count) |_| if (p < e) {
                p = nextc(s, p);
            };
            if (!operating and v.mode != .visual) p = clamp(s, p);
            return .{ .pos = p };
        }
        if (eq(name, " ")) {
            for (0..count) |_| p = nextc(s, p);
            return .{ .pos = p };
        }
        if (name.len == 1 and std.mem.indexOfScalar(u8, "wWeEbB", name[0]) != null) {
            const big = std.ascii.isUpper(name[0]);
            for (0..count) |_| {
                const q = switch (std.ascii.toLower(name[0])) {
                    'w' => wordForward(s, p, big),
                    'e' => wordEnd(s, p, big),
                    else => wordBack(s, p, big),
                };
                if (q == p) break;
                p = q;
            }
            return .{ .pos = p, .kind = if (std.ascii.toLower(name[0]) == 'e') .inclusive else .exclusive };
        }
        if (eq(name, "0") or eq(name, "<Home>")) return .{ .pos = bol(s, p) };
        if (eq(name, "^")) return .{ .pos = firstNonblank(s, p) };
        if (eq(name, "$") or eq(name, "<End>")) {
            for (1..count) |_| {
                const e = eol(s, p);
                if (e < s.len) p = e + 1;
            }
            const e = eol(s, p);
            return .{ .pos = if (operating or v.mode == .visual) e else clamp(s, e) };
        }
        if (eq(name, "gg") or eq(name, "G")) {
            const n = if (cmd.count != null) count else if (eq(name, "gg")) 1 else lineOf(s, len32(s));
            return .{ .pos = firstNonblank(s, lineStart(s, n)), .kind = .linewise };
        }
        if (eq(name, "}")) {
            for (0..count) |_| {
                const e = eol(s, p);
                if (e >= s.len) {
                    p = len32(s);
                    break;
                }
                p = e + 1;
            }
            return .{ .pos = p };
        }
        if (eq(name, "{")) {
            for (0..count) |_| {
                var b = bol(s, p);
                if (b == p and b > 0) b = bol(s, b - 1);
                p = b;
            }
            return .{ .pos = p };
        }
        if (inList(m, &needs_char)) {
            const arg = cmd.marg.?;
            v.last_find = .{ .name = m, .arg = arg };
            return v.find(s, p, count, m.buf[0], arg.str());
        }
        if (eq(name, ";") or eq(name, ",")) {
            const f = v.last_find orelse return null;
            var which = f.name.buf[0];
            if (eq(name, ",")) which = if (std.ascii.isUpper(which)) std.ascii.toLower(which) else std.ascii.toUpper(which);
            // Repeating t from just before its character skips it.
            const from = if (eq(name, ";") and which == 't') nextc(s, p) else if (eq(name, ";") and which == 'T') prevc(s, p) else p;
            return v.find(s, from, count, which, f.arg.str());
        }
        if (eq(name, "j") or eq(name, "k") or eq(name, "gj") or eq(name, "gk") or eq(name, "<Down>") or eq(name, "<Up>") or eq(name, "<C-d>") or eq(name, "<C-u>") or eq(name, "<CR>")) {
            const down = eq(name, "j") or eq(name, "gj") or eq(name, "<Down>") or eq(name, "<C-d>") or eq(name, "<CR>");
            const n = if (eq(name, "<C-d>") or eq(name, "<C-u>")) 12 * count else count;
            if (operating or eq(name, "<CR>")) {
                // With an operator, by blocks.
                var q = p;
                for (0..n) |_| {
                    if (down) {
                        const e = eol(s, q);
                        if (e >= s.len) break;
                        q = e + 1;
                    } else {
                        const b = bol(s, q);
                        if (b == 0) break;
                        q = bol(s, b - 1);
                    }
                }
                if (eq(name, "<CR>")) return .{ .pos = firstNonblank(s, q) };
                return .{ .pos = q, .kind = .linewise };
            }
            const x = v.goal_x orelse st.caretRect(p).x;
            v.goal_x = x;
            for (0..n) |_| p = st.vertical(p, if (down) 1 else -1, x) orelse break;
            return .{ .pos = p, .keep_goal = true };
        }
        if (eq(name, "n") or eq(name, "N")) return .{ .pos = v.searchFrom(st, p, count, eq(name, "N")) orelse return null };
        return null;
    }

    fn find(_: *Vim, s: []const u8, p: u32, count: u32, which: u8, arg: []const u8) ?Target {
        const forward = which == 'f' or which == 't';
        const till = which == 't' or which == 'T';
        const q = findChar(s, p, count, arg, forward, till) orelse return null;
        return .{ .pos = q, .kind = if (forward) .inclusive else .exclusive };
    }

    /// A text object around p: start, stop (exclusive), whole lines.
    fn object(_: *Vim, s: []const u8, p: u32, count: u32, o: Tok, inner: bool) ?struct { u32, u32, bool } {
        const b = bol(s, p);
        const e = eol(s, p);
        const ch = o.str();
        if (o.is("w") or o.is("W")) {
            const big = o.is("W");
            const k = cls(char(s, p), big);
            var lo = p;
            var hi = p;
            while (lo > b and cls(char(s, prevc(s, lo)), big) == k) lo = prevc(s, lo);
            while (hi < e and cls(char(s, hi), big) == k) hi = nextc(s, hi);
            for (1..count) |_| hi = wordForward(s, hi, big);
            if (!inner) {
                var h = hi;
                while (h < e and cls(char(s, h), big) == 0) h = nextc(s, h);
                if (h > hi) hi = h else while (lo > b and cls(char(s, prevc(s, lo)), big) == 0) {
                    lo = prevc(s, lo);
                }
            }
            return .{ lo, @min(hi, e), false };
        }
        if (o.is("p")) return .{ b, e, true };
        if (o.is("s")) {
            const ends = ".!?";
            var lo = b;
            var q = b;
            while (q < p) : (q += 1) {
                if (std.mem.indexOfScalar(u8, ends, s[q]) == null) continue;
                var r = q + 1;
                while (r < e and (s[r] == '"' or s[r] == '\'' or s[r] == ')' or s[r] == ']')) r += 1;
                if (r < e and s[r] == ' ') {
                    while (r < e and s[r] == ' ') r += 1;
                    if (r <= p) lo = r;
                }
            }
            var hi = e;
            q = p;
            while (q < e) : (q += 1) if (std.mem.indexOfScalar(u8, ends, s[q]) != null) {
                hi = q + 1;
                while (hi < e and (s[hi] == '"' or s[hi] == '\'' or s[hi] == ')' or s[hi] == ']')) hi += 1;
                break;
            };
            if (!inner) while (hi < e and s[hi] == ' ') {
                hi += 1;
            };
            return .{ lo, hi, false };
        }
        const open: []const u8, const close: []const u8 = if (o.is("\"")) .{ "\"", "\"" } else if (o.is("'")) .{ "'", "'" } else if (o.is("(") or o.is(")") or o.is("b")) .{ "(", ")" } else if (o.is("[") or o.is("]")) .{ "[", "]" } else if (o.is("{") or o.is("}")) .{ "{", "}" } else .{ "“", "”" };
        _ = ch;
        var lo: ?u32 = null;
        var hi: ?u32 = null;
        if (std.mem.eql(u8, open, close)) {
            // Quotes: the pair around p on its line, else the first after
            // it, as Vim does.
            var positions: [64]u32 = undefined;
            var n: usize = 0;
            var q = b;
            while (q < e and n < positions.len) : (q += 1) if (s[q] == open[0]) {
                positions[n] = q;
                n += 1;
            };
            var i: usize = 0;
            while (i + 1 < n) : (i += 2) {
                if ((positions[i] <= p and p <= positions[i + 1]) or (lo == null and positions[i] > p)) {
                    lo = positions[i];
                    hi = positions[i + 1];
                    if (positions[i] <= p) break;
                }
            }
        } else {
            var depth: u32 = 0;
            var q: i64 = p;
            while (q >= 0) : (q -= 1) {
                const at: u32 = @intCast(q);
                if (std.mem.startsWith(u8, s[at..], close) and at != p) depth += 1;
                if (std.mem.startsWith(u8, s[at..], open)) {
                    if (depth == 0) {
                        lo = at;
                        break;
                    }
                    depth -= 1;
                }
            }
            if (lo) |l| {
                depth = 0;
                var r = l + len32(open);
                while (r < s.len) : (r += 1) {
                    if (std.mem.startsWith(u8, s[r..], open)) depth += 1;
                    if (std.mem.startsWith(u8, s[r..], close)) {
                        if (depth == 0) {
                            hi = r;
                            break;
                        }
                        depth -= 1;
                    }
                }
            }
        }
        const l = lo orelse return null;
        const h = hi orelse return null;
        if (inner) return .{ l + len32(open), h, false };
        return .{ l, h + len32(close), false };
    }

    // Running commands -------------------------------------------------------

    fn run(v: *Vim, st: *State, cmd: Cmd, keys: ?Keys) void {
        const s = st.text();
        const p = v.cursor(st);
        const count = cmd.count orelse 1;
        const vis = v.visual();

        if (cmd.motion) |m| {
            const target = v.motion(st, cmd, s, p, count);
            if (!(target != null and target.?.keep_goal)) v.goal_x = null;
            const t = target orelse return;
            if (cmd.op) |op| {
                const lo = @min(p, t.pos);
                var hi = @max(p, t.pos);
                if (t.kind == .inclusive) hi = nextc(s, hi);
                if (m.is("w") or m.is("W")) {
                    if (op.is("c") and cls(char(s, p), false) != 0) {
                        // cw changes to the end of the word, as ce does.
                        var e = p;
                        for (0..count) |_| e = wordEnd(s, e, m.is("W"));
                        hi = nextc(s, e);
                        if (cls(char(s, p), m.is("W")) != cls(char(s, nextc(s, p)), m.is("W"))) hi = nextc(s, p);
                    }
                    // dw stops at the end of the line.
                    if (std.mem.indexOfScalarPos(u8, s, lo, '\n')) |brk| if (brk < hi and brk > lo) {
                        hi = @intCast(brk);
                    };
                }
                v.operate(st, op, lo, hi, t.kind == .linewise, keys, cmd.count);
                return;
            }
            v.draw(st, t.pos);
            return;
        }

        if (cmd.object) |o| {
            const r = v.object(s, p, count, o, cmd.inner) orelse return;
            if (cmd.op) |op| {
                v.operate(st, op, r[0], r[1], r[2], keys, cmd.count);
            } else if (vis) {
                v.anchor = r[0];
                if (v.mode == .vline or r[2]) v.draw(st, r[1]) else v.draw(st, @max(r[0], prevc(s, r[1])));
            }
            return;
        }

        if (cmd.op) |op| {
            // An operator on the visual selection, or a doubled one (dd).
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            var linewise = true;
            if (vis) {
                lo = @min(v.anchor, p);
                hi = @max(v.anchor, p);
                linewise = v.mode == .vline;
                if (!linewise) hi = nextc(s, hi);
                v.mode = .normal;
                st.updateFlags(null);
            } else {
                lo = p;
                hi = p;
                for (1..count) |_| {
                    const e = eol(s, hi);
                    if (e >= s.len) break;
                    hi = e + 1;
                }
            }
            v.operate(st, op, lo, hi, linewise, if (vis) null else keys, cmd.count);
            return;
        }

        const c = cmd.cmd orelse return;
        if (c.is("<Esc>")) {
            if (vis) v.leaveVisual(st);
            return;
        }
        if (vis) return v.runVisual(st, c, p);
        const change_keys = if (inList(c, &changes)) keys else null;
        if (c.is("i") or c.is("<Insert>") or c.is("a") or c.is("I") or c.is("A")) {
            v.beginChange(st, change_keys, p);
            v.undo_held = true;
            const at = if (c.is("a")) (if (p >= s.len or s[p] == '\n') p else nextc(s, p)) else if (c.is("I")) firstNonblank(s, p) else if (c.is("A")) eol(s, p) else p;
            v.enterInsert(st, at);
        } else if (c.is("o") or c.is("O")) {
            v.beginChange(st, change_keys, p);
            v.undo_held = true;
            const b, _ = st.blockAt(p);
            const d = st.def(b);
            const at = if (c.is("o")) eol(s, p) else bol(s, p);
            st.replace(at, at, "\n", null);
            const start = if (c.is("o")) at + 1 else at;
            // A new line below a heading is normal text, as Enter makes it.
            if (c.is("o") and d.kind == .text and d.style.heading() > 0) {
                if (st.setBlock(.{ .style = .normal }, start, start)) st.dropCheckpoint();
            }
            v.enterInsert(st, start);
        } else if (c.is("x") or c.is("<Del>") or c.is("X") or c.is("s")) {
            var lo = p;
            var hi = p;
            if (c.is("X")) {
                for (0..count) |_| if (lo > bol(s, p)) {
                    lo = prevc(s, lo);
                };
            } else {
                const e = eol(s, p);
                for (0..count) |_| if (hi < e) {
                    hi = nextc(s, hi);
                };
            }
            if (hi == lo and !c.is("s")) return;
            v.beginChange(st, change_keys, p);
            v.yank(st, lo, hi, false);
            st.replace(lo, hi, "", null);
            if (c.is("s")) {
                v.undo_held = true;
                v.enterInsert(st, lo);
            } else {
                v.draw(st, lo);
                v.endChange();
            }
        } else if (c.is("D") or c.is("C")) {
            var e = eol(s, p);
            for (1..count) |_| if (e < s.len) {
                e = eol(s, e + 1);
            };
            v.operate(st, Tok.of(if (c.is("D")) "d" else "c").?, p, e, false, keys, null);
        } else if (c.is("S")) {
            v.operate(st, Tok.of("c").?, p, p, true, keys, null);
        } else if (c.is("Y")) {
            v.operate(st, Tok.of("y").?, p, p, true, keys, null);
        } else if (c.is("p") or c.is("P")) {
            v.put(st, c.is("P"), count);
            v.remember(keys);
        } else if (c.is("J")) {
            v.beginChange(st, change_keys, p);
            var q = p;
            for (0..@max(1, count -| 1)) |_| {
                const t = st.text();
                const e = eol(t, q);
                if (e >= t.len) break;
                var n = e + 1;
                while (n < t.len and (t[n] == ' ' or t[n] == '\t')) n += 1;
                const sep: []const u8 = if (e > bol(t, e) and t[e - 1] != ' ' and n < t.len and t[n] != '\n') " " else "";
                st.replace(e, n, sep, null);
                q = e;
            }
            v.draw(st, q);
            v.endChange();
        } else if (c.is("r") or c.is("~")) {
            const e = eol(s, p);
            var hi = p;
            var n: usize = 0;
            for (0..count) |_| if (hi < e) {
                hi = nextc(s, hi);
                n += 1;
            };
            if (hi == p) return;
            v.beginChange(st, change_keys, p);
            const f = st.fragment(p, hi) catch return;
            defer f.deinit(gpa);
            var new: std.ArrayList(u8) = .empty;
            defer new.deinit(gpa);
            if (c.is("r")) {
                for (0..n) |_| new.appendSlice(gpa, cmd.arg.?.str()) catch return;
            } else {
                new.appendSlice(gpa, s[p..hi]) catch return;
                caseMap(new.items, '~');
            }
            // Marks stay when the length does.
            st.replace(p, hi, new.items, if (new.items.len == hi - p) &f else null);
            const t = st.text();
            if (c.is("r")) v.draw(st, prevc(t, p + len32(new.items))) else v.draw(st, @min(hi, clamp(t, hi)));
            v.endChange();
        } else if (c.is("u") or c.is("<C-r>")) {
            for (0..count) |_| if (!(if (c.is("u")) st.undo() else st.redo())) break;
            v.draw(st, st.selection()[0]);
        } else if (c.is(".")) {
            v.dot(st, cmd.count);
        } else if (c.is("v") or c.is("V")) {
            v.mode = if (c.is("v")) .visual else .vline;
            v.anchor = p;
            v.draw(st, p);
        } else if (c.is(":") or c.is("/") or c.is("?")) {
            v.prompt = c.buf[0];
            v.cmdline.clearRetainingCapacity();
            v.mode = .cmdline;
        }
        // zz, zt, zb: the scroll keeps the caret in view; nothing more yet.
    }

    fn runVisual(v: *Vim, st: *State, c: Tok, p: u32) void {
        const s = st.text();
        var lo = @min(v.anchor, p);
        var hi = @max(v.anchor, p);
        if (c.is("v") or c.is("V")) {
            const want: Mode = if (c.is("v")) .visual else .vline;
            if (v.mode == want) v.leaveVisual(st) else {
                v.mode = want;
                v.draw(st, p);
            }
        } else if (c.is("o")) {
            v.cur = v.anchor;
            v.anchor = p;
            v.draw(st, v.cur);
        } else if (inList(c, &.{ "x", "<Del>", "s", "S", "C", "D", "X", "Y" })) {
            const op = if (inList(c, &.{ "s", "S", "C" })) "c" else if (c.is("Y")) "y" else "d";
            const linewise = v.mode == .vline or inList(c, &.{ "S", "C", "D", "X", "Y" });
            if (!linewise) hi = nextc(s, hi);
            v.mode = .normal;
            st.updateFlags(null);
            v.operate(st, Tok.of(op).?, lo, hi, linewise, null, null);
        } else if (c.is("~") or c.is("u") or c.is("U")) {
            if (v.mode == .vline) {
                lo = bol(s, lo);
                hi = eol(s, hi);
            } else hi = nextc(s, hi);
            v.mode = .normal;
            v.operate(st, Tok.of(if (c.is("~")) "g~" else if (c.is("u")) "gu" else "gU").?, lo, hi, false, null, null);
        } else if (c.is("J")) {
            v.mode = .normal;
            v.draw(st, lo);
            v.run(st, .{ .cmd = Tok.of("J").?, .count = @max(2, lineOf(s, hi) - lineOf(s, lo) + 1) }, null);
        } else if (c.is("p") or c.is("P")) {
            const reg = v.register orelse return;
            if (v.mode == .vline) {
                lo = bol(s, lo);
                hi = eol(s, hi);
            } else hi = nextc(s, hi);
            v.mode = .normal;
            v.beginChange(st, null, lo);
            // Lines replace lines without their final break.
            const text = if (reg.linewise) reg.frag.text[0 .. reg.frag.text.len - 1] else reg.frag.text;
            const f = reg.frag.clone(gpa) catch return;
            defer f.deinit(gpa);
            st.replace(lo, hi, text, if (reg.linewise) null else &f);
            v.draw(st, lo);
            v.endChange();
        } else if (c.is(":")) {
            v.prompt = ':';
            v.cmdline.clearRetainingCapacity();
            v.cmdline.appendSlice(gpa, "'<,'>") catch {};
            v.mode = .cmdline;
        }
    }

    fn dot(v: *Vim, st: *State, count: ?u32) void {
        const last = v.last_change orelse return;
        const insert = gpa.dupe(u8, last.insert) catch return;
        defer gpa.free(insert);
        var keys = last.keys;
        if (count) |n| {
            // A count replaces the command's own.
            var out: Keys = .{};
            var buf: [10]u8 = undefined;
            for (std.fmt.bufPrint(&buf, "{d}", .{n}) catch "") |d| {
                out.toks[out.n] = Tok.of(&.{d}).?;
                out.n += 1;
            }
            var i: usize = 0;
            while (i < keys.n and keys.toks[i].len == 1 and std.ascii.isDigit(keys.toks[i].buf[0]) and !(i == 0 and keys.toks[i].buf[0] == '0')) i += 1;
            while (i < keys.n and out.n < max_keys) : (i += 1) {
                out.toks[out.n] = keys.toks[i];
                out.n += 1;
            }
            keys = out;
        }
        v.replaying = true;
        defer v.replaying = false;
        for (keys.slice()) |k| v.feed(st, k);
        if (v.mode == .insert) {
            if (insert.len > 0) {
                const caret = st.selection()[0];
                st.replace(caret, caret, insert, null);
            }
            v.leaveInsert(st);
        }
    }

    fn cmdlineKey(v: *Vim, st: *State, tok: Tok) void {
        if (tok.is("<Esc>")) {
            v.mode = .normal;
        } else if (tok.is("<BS>")) {
            if (v.cmdline.items.len == 0) v.mode = .normal else {
                var n = v.cmdline.items.len - 1;
                while (n > 0 and v.cmdline.items[n] & 0xc0 == 0x80) n -= 1;
                v.cmdline.shrinkRetainingCapacity(n);
            }
        } else if (tok.is("<CR>")) {
            v.mode = .normal;
            const text = gpa.dupe(u8, v.cmdline.items) catch return;
            defer gpa.free(text);
            v.cmdline.clearRetainingCapacity();
            v.execute(st, text);
        } else if (tok.len == 1 or tok.buf[0] != '<') {
            v.cmdline.appendSlice(gpa, tok.str()) catch {};
        }
        st.notifyLater();
    }

    fn execute(v: *Vim, st: *State, text: []const u8) void {
        const p = st.selection()[0];
        if (v.prompt == '/' or v.prompt == '?') {
            if (text.len > 0) {
                v.search.clearRetainingCapacity();
                v.search.appendSlice(gpa, text) catch {};
                v.search_back = v.prompt == '?';
            }
            v.draw(st, v.searchFrom(st, p, 1, false) orelse p);
            return;
        }
        if (v.linkCommand(st, text)) return;
        v.draw(st, p);
        if (std.fmt.parseInt(u32, text, 10)) |n| {
            const s = st.text();
            v.draw(st, firstNonblank(s, lineStart(s, n)));
            return;
        } else |_| {}
        st.command(text);
    }

    /// The link editor applied: a visual selection it linked ends.
    pub fn afterLink(v: *Vim, st: *State) void {
        if (v.visual()) v.leaveVisual(st) else v.afterChange(st);
    }

    /// :link URL, :link, and :unlink, on the visual selection (:'<,'>)
    /// or at the cursor; whether text was one of them.
    fn linkCommand(v: *Vim, st: *State, text: []const u8) bool {
        const ranged = std.mem.startsWith(u8, text, "'<,'>");
        const name = if (ranged) text[5..] else text;
        const unlink = std.mem.eql(u8, name, "unlink");
        if (!unlink and !std.mem.eql(u8, name, "link") and !std.mem.startsWith(u8, name, "link ")) return false;
        const s = st.text();
        const sel = st.selection();
        const p = sel[0];
        // The command line kept the visual selection.
        if (ranged) v.mode = .visual;
        const typed = if (unlink) "" else std.mem.trim(u8, name[4..], " ");
        if (!unlink and typed.len == 0) {
            st.openLink();
            return true;
        }
        var lo = @min(sel[0], sel[1]);
        var hi = @max(sel[0], sel[1]);
        if (!ranged) {
            if (st.caretLink(p, p)) |l| {
                lo = l.start;
                hi = l.stop;
            } else if (unlink or cls(char(s, p), false) == 0) {
                st.setMessage(if (unlink) "No link under the cursor" else "No word under the cursor");
                v.draw(st, p);
                return true;
            } else {
                const r = v.object(s, p, 1, Tok.of("w").?, true) orelse return true;
                lo = r[0];
                hi = r[1];
            }
        }
        const href = rt.hrefOf(typed);
        defer if (href) |h| gpa.free(h);
        _ = st.setLink(lo, hi, href orelse "");
        v.mode = .normal;
        v.draw(st, if (ranged) lo else p);
        return true;
    }

    /// The user typed (insert mode) or pasted.
    pub fn afterChange(v: *Vim, st: *State) void {
        if (v.mode == .normal) v.draw(st, st.selection()[0]);
    }

    /// A click or drag ended: a selection made with the pointer is visual
    /// mode, a click leaves it.
    pub fn afterPointer(v: *Vim, st: *State) void {
        if (v.mode == .insert or v.mode == .cmdline) return;
        const s = st.text();
        const sel = st.selection();
        if (sel[0] != sel[1]) {
            if (v.mode != .visual) {
                v.mode = .visual;
                st.updateFlags(null);
            }
            if (sel[0] > sel[1]) {
                v.anchor = sel[1];
                v.cur = prevc(s, sel[0]);
            } else {
                v.anchor = prevc(s, sel[1]);
                v.cur = sel[0];
            }
            v.draw(st, v.cur);
        } else {
            v.mode = .normal;
            v.goal_x = null;
            v.draw(st, sel[0]);
        }
        st.notify();
    }
};
