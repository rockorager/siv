//! Portable Text (portabletext.org) for the rich text editor
//! (rich_text.zig, D22): JSON to and from a plain model of a document
//! that knows nothing about siv.
//!
//!   text    the blocks' text joined by "\n"; a line break inside a block
//!           ("\n" in a span, Shift+Enter) is U+2028 LINE SEPARATOR, which
//!           breaks the line without ending the paragraph. A code block is
//!           one paragraph per line of its code; a block the editor does
//!           not edit (an image, a table) is one U+00A0 NO-BREAK SPACE,
//!           over which the editor draws a placeholder (U+FFFC OBJECT
//!           REPLACEMENT CHARACTER would draw as a box in fonts without
//!           it).
//!   blocks  per paragraph: start and stop (byte offsets, stop before the
//!           "\n") and its definition in the registry: text, code, or
//!           object, the style, the list and its level, and the JSON it
//!           was read from (its _key, fields the editor does not edit, an
//!           object whole). Consecutive code lines of one definition are
//!           one code block.
//!   runs    marked stretches of text blocks: start, stop, the decorators
//!           (strong, em, underline, strike-through, code, superscript,
//!           subscript), and an
//!           annotation (a markDef such as a link, kept whole), as an
//!           index into the registry plus one.
//!
//! The registry owns the JSON read with set_document and is append-only
//! until the next one, so the indices in models (and undo steps) stay
//! valid.
//!
//! Imports: std only.

const std = @import("std");
const json = std.json;
const Value = json.Value;
const Allocator = std.mem.Allocator;

pub const line_separator = "\u{2028}";
pub const object_char = "\u{a0}";

/// Decorators, in the order export lists them.
pub const Marks = packed struct(u8) {
    strong: bool = false,
    em: bool = false,
    underline: bool = false,
    strike_through: bool = false,
    code: bool = false,
    superscript: bool = false,
    subscript: bool = false,
    _pad: u1 = 0,

    pub const names = [_][]const u8{ "strong", "em", "underline", "strike-through", "code", "superscript", "subscript" };
    pub const all: Marks = .{ .strong = true, .em = true, .underline = true, .strike_through = true, .code = true, .superscript = true, .subscript = true };

    pub fn bits(m: Marks) u8 {
        return @bitCast(m);
    }
    pub fn of(b: u8) Marks {
        return @bitCast(b & 0x7f);
    }
    pub fn any(m: Marks) bool {
        return m.bits() != 0;
    }
    pub fn eql(a: Marks, b: Marks) bool {
        return a.bits() == b.bits();
    }
    pub fn byName(name: []const u8) ?Marks {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return of(@as(u8, 1) << @intCast(i));
        return null;
    }
};

/// Block styles; the values are siv_rich_text_style's.
pub const Style = enum(u8) {
    normal,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    blockquote,

    pub fn name(s: Style) []const u8 {
        return @tagName(s);
    }
    pub fn byName(n: []const u8) ?Style {
        return std.meta.stringToEnum(Style, n);
    }
    pub fn heading(s: Style) u8 {
        return switch (s) {
            .h1, .h2, .h3, .h4, .h5, .h6 => @intFromEnum(s),
            else => 0,
        };
    }
};

pub const List = enum(u8) { none, bullet, number };
pub const Kind = enum(u8) { text, code, object };
pub const max_level = 8;

/// What a paragraph is. Definition 0 is plain normal text.
pub const Def = struct {
    kind: Kind = .text,
    style: Style = .normal,
    list: List = .none,
    level: u8 = 0,
    /// The JSON it was read from; null for blocks the user made.
    raw: ?*const Value = null,

    pub fn eql(a: Def, b: Def) bool {
        return a.kind == b.kind and a.style == b.style and a.list == b.list and a.level == b.level and a.raw == b.raw;
    }
};

pub const Block = struct { start: u32, stop: u32, def: u32 = 0 };
pub const Run = struct { start: u32, stop: u32, marks: Marks = .{}, ann: u32 = 0 };

/// A document, or a fragment of one (the text a register keeps). Owns
/// its slices.
pub const Model = struct {
    text: []const u8 = "",
    blocks: []const Block = &.{},
    runs: []const Run = &.{},

    pub fn deinit(m: Model, gpa: Allocator) void {
        gpa.free(m.text);
        gpa.free(m.blocks);
        gpa.free(m.runs);
    }

    pub fn clone(m: Model, gpa: Allocator) !Model {
        const text = try gpa.dupe(u8, m.text);
        errdefer gpa.free(text);
        const blocks = try gpa.dupe(Block, m.blocks);
        errdefer gpa.free(blocks);
        return .{ .text = text, .blocks = blocks, .runs = try gpa.dupe(Run, m.runs) };
    }

    pub fn empty(gpa: Allocator) !Model {
        const blocks = try gpa.alloc(Block, 1);
        blocks[0] = .{ .start = 0, .stop = 0 };
        return .{ .text = try gpa.dupe(u8, ""), .blocks = blocks, .runs = try gpa.dupe(Run, &.{}) };
    }

    pub fn eql(a: Model, b: Model) bool {
        if (!std.mem.eql(u8, a.text, b.text) or a.blocks.len != b.blocks.len or a.runs.len != b.runs.len) return false;
        for (a.blocks, b.blocks) |x, y| if (x.start != y.start or x.stop != y.stop or x.def != y.def) return false;
        for (a.runs, b.runs) |x, y| if (x.start != y.start or x.stop != y.stop or !x.marks.eql(y.marks) or x.ann != y.ann) return false;
        return true;
    }
};

/// What documents may contain (siv_rich_text_schema and its flags).
pub const Allow = struct {
    /// Bits: h1 to h6, blockquote.
    styles: u8 = 0x7f,
    marks: Marks = Marks.all,
    link: bool = true,
    bullet: bool = true,
    number: bool = true,
    code: bool = true,
    /// Blocks of other types are kept as objects (EmDash) or dropped.
    objects: bool = true,

    pub fn style(a: Allow, s: Style) bool {
        return s == .normal or a.styles & (@as(u8, 1) << @intCast(@intFromEnum(s) - 1)) != 0;
    }
    pub fn list(a: Allow, l: List) bool {
        return switch (l) {
            .none => true,
            .bullet => a.bullet,
            .number => a.number,
        };
    }
};

pub const Registry = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    defs: std.ArrayList(Def) = .empty,
    annotations: std.ArrayList(*const Value) = .empty,
    seed: u64 = 0x5eed,

    pub fn init(gpa: Allocator) !Registry {
        var r: Registry = .{ .gpa = gpa, .arena = .init(gpa) };
        try r.defs.append(gpa, .{});
        r.seed ^= @intFromPtr(&r);
        return r;
    }

    pub fn deinit(r: *Registry) void {
        r.defs.deinit(r.gpa);
        r.annotations.deinit(r.gpa);
        r.arena.deinit();
    }

    pub fn def(r: *const Registry, i: u32) Def {
        return if (i < r.defs.items.len) r.defs.items[i] else .{};
    }

    pub fn intern(r: *Registry, d: Def) !u32 {
        for (r.defs.items, 0..) |e, i| if (e.eql(d)) return @intCast(i);
        try r.defs.append(r.gpa, d);
        return @intCast(r.defs.items.len - 1);
    }

    /// An annotation's index plus one.
    pub fn annotation(r: *Registry, v: *const Value) !u32 {
        for (r.annotations.items, 0..) |e, i| if (e == v) return @intCast(i + 1);
        try r.annotations.append(r.gpa, v);
        return @intCast(r.annotations.items.len);
    }

    pub fn annotationValue(r: *const Registry, ann: u32) ?*const Value {
        return if (ann > 0 and ann <= r.annotations.items.len) r.annotations.items[ann - 1] else null;
    }

    /// A new link annotation to url, and its index plus one: a copy of
    /// `base` with its href replaced, so an edited link keeps its _key
    /// and fields such as blank, or { _type: "link", _key, href }.
    pub fn link(r: *Registry, url: []const u8, base: ?*const Value) !u32 {
        const a = r.arena.allocator();
        var o: json.ObjectMap = .empty;
        if (base != null and base.?.* == .object) {
            var it = base.?.object.iterator();
            while (it.next()) |e| try o.put(a, e.key_ptr.*, e.value_ptr.*);
        } else {
            var used: std.StringHashMap(void) = .init(r.gpa);
            defer used.deinit();
            try o.put(a, "_type", .{ .string = "link" });
            try o.put(a, "_key", .{ .string = try r.newKey(a, &used) });
        }
        try o.put(a, "href", .{ .string = try a.dupe(u8, url) });
        const v = try a.create(Value);
        v.* = .{ .object = o };
        return r.annotation(v);
    }

    /// The href of an annotation, or "" for none.
    pub fn href(r: *const Registry, ann: u32) []const u8 {
        const v = r.annotationValue(ann) orelse return "";
        return string(v.*, "href") orelse "";
    }

    fn newKey(r: *Registry, a: Allocator, used: *std.StringHashMap(void)) ![]const u8 {
        while (true) {
            r.seed +%= 0x9e3779b97f4a7c15;
            var z = r.seed;
            z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
            z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
            z ^= z >> 31;
            const k = try std.fmt.allocPrint(a, "{x:0>12}", .{z & 0xffff_ffff_ffff});
            if (!used.contains(k)) {
                try used.put(k, {});
                return k;
            }
        }
    }
};

fn field(v: Value, name: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn string(v: Value, name: []const u8) ?[]const u8 {
    const f = field(v, name) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn array(v: Value, name: []const u8) []const Value {
    const f = field(v, name) orelse return &.{};
    return switch (f) {
        .array => |a| a.items,
        else => &.{},
    };
}

/// Appends a warning once.
fn warn(warnings: *std.ArrayList(u8), gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    if (std.mem.indexOf(u8, warnings.items, msg) != null) return;
    if (warnings.items.len > 0) try warnings.appendSlice(gpa, "; ");
    try warnings.appendSlice(gpa, msg);
}

/// Appends text with "\n" as U+2028.
fn appendText(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    for (s) |ch| {
        if (ch == '\n') try out.appendSlice(gpa, line_separator) else if (ch != '\r') try out.append(gpa, ch);
    }
}

pub const ImportError = error{ OutOfMemory, InvalidDocument };

/// Portable Text JSON (an array of blocks) to a model; empty source is an
/// empty document. What the schema does not allow is dropped, with a
/// message in `warnings`.
pub fn import(r: *Registry, gpa: Allocator, source: []const u8, allow: Allow, warnings: *std.ArrayList(u8)) ImportError!Model {
    if (std.mem.trim(u8, source, " \t\r\n").len == 0) return Model.empty(gpa);
    const a = r.arena.allocator();
    const root = try a.create(Value);
    root.* = json.parseFromSliceLeaky(Value, a, source, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDocument,
    };
    const items = switch (root.*) {
        .array => |arr| arr.items,
        else => return error.InvalidDocument,
    };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(gpa);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);

    for (items) |*block| {
        const ty = string(block.*, "_type") orelse "";
        const is_text = std.mem.eql(u8, ty, "block");
        const is_code = std.mem.eql(u8, ty, "code");
        if (!is_text and !is_code and !allow.objects) {
            try warn(warnings, gpa, "{s} blocks are dropped", .{ty});
            continue;
        }
        if (blocks.items.len > 0) try text.append(gpa, '\n');
        const start: u32 = @intCast(text.items.len);
        if (is_code) {
            const code = string(block.*, "code") orelse "";
            const d: Def = if (allow.code) .{ .kind = .code, .raw = block } else .{};
            if (!allow.code) try warn(warnings, gpa, "code blocks show as text", .{});
            const id = try r.intern(d);
            var lines = std.mem.splitScalar(u8, code, '\n');
            var first = true;
            while (lines.next()) |line| {
                if (!first) try text.append(gpa, '\n');
                first = false;
                const s: u32 = @intCast(text.items.len);
                for (line) |ch| if (ch != '\r') try text.append(gpa, ch);
                try blocks.append(gpa, .{ .start = s, .stop = @intCast(text.items.len), .def = id });
            }
            continue;
        }
        if (!is_text) {
            try text.appendSlice(gpa, object_char);
            try blocks.append(gpa, .{ .start = start, .stop = @intCast(text.items.len), .def = try r.intern(.{ .kind = .object, .raw = block }) });
            continue;
        }
        const defs = array(block.*, "markDefs");
        for (array(block.*, "children")) |child| {
            const cty = string(child, "_type") orelse "span";
            if (!std.mem.eql(u8, cty, "span")) {
                try warn(warnings, gpa, "inline {s} objects are dropped", .{cty});
                continue;
            }
            const s: u32 = @intCast(text.items.len);
            try appendText(&text, gpa, string(child, "text") orelse "");
            const e: u32 = @intCast(text.items.len);
            if (e == s) continue;
            var marks: Marks = .{};
            var ann: u32 = 0;
            for (array(child, "marks")) |m| {
                const name = switch (m) {
                    .string => |str| str,
                    else => continue,
                };
                if (Marks.byName(name)) |bit| {
                    if (allow.marks.bits() & bit.bits() != 0) marks = Marks.of(marks.bits() | bit.bits()) else try warn(warnings, gpa, "the {s} decorator is dropped", .{name});
                    continue;
                }
                const def = for (defs) |*d| {
                    if (std.mem.eql(u8, string(d.*, "_key") orelse "", name)) break d;
                } else null;
                if (def) |d| {
                    if (!allow.link) {
                        try warn(warnings, gpa, "annotations are dropped", .{});
                    } else if (ann != 0) {
                        try warn(warnings, gpa, "only one annotation per span is kept", .{});
                    } else ann = try r.annotation(d);
                } else try warn(warnings, gpa, "the {s} decorator is dropped", .{name});
            }
            if (marks.any() or ann != 0) try runs.append(gpa, .{ .start = s, .stop = e, .marks = marks, .ann = ann });
        }
        var style = Style.byName(string(block.*, "style") orelse "normal") orelse blk: {
            try warn(warnings, gpa, "the {s} style shows as normal", .{string(block.*, "style").?});
            break :blk .normal;
        };
        if (!allow.style(style)) {
            try warn(warnings, gpa, "the {s} style shows as normal", .{style.name()});
            style = .normal;
        }
        var list: List = .none;
        if (string(block.*, "listItem")) |li| {
            list = std.meta.stringToEnum(List, li) orelse .bullet;
            if (list == .none) list = .bullet;
            if (!allow.list(list)) {
                try warn(warnings, gpa, "{s} lists show as text", .{li});
                list = .none;
            }
        }
        var level: u8 = 0;
        if (list != .none) {
            level = 1;
            if (field(block.*, "level")) |l| switch (l) {
                .integer => |n| level = @intCast(std.math.clamp(n, 1, max_level)),
                else => {},
            };
            style = .normal;
        }
        try blocks.append(gpa, .{ .start = start, .stop = @intCast(text.items.len), .def = try r.intern(.{ .style = style, .list = list, .level = level, .raw = block }) });
    }
    if (blocks.items.len == 0) return Model.empty(gpa);
    const t = try text.toOwnedSlice(gpa);
    errdefer gpa.free(t);
    const b = try blocks.toOwnedSlice(gpa);
    errdefer gpa.free(b);
    return .{ .text = t, .blocks = b, .runs = try runs.toOwnedSlice(gpa) };
}

/// Text from the model with U+2028 as "\n".
fn exportText(a: Allocator, s: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, s, line_separator, "\n");
}

const managed_block_fields = [_][]const u8{ "_type", "_key", "style", "listItem", "level", "markDefs", "children" };

fn isManaged(name: []const u8, fields: []const []const u8) bool {
    for (fields) |f| if (std.mem.eql(u8, f, name)) return true;
    return false;
}

/// A copy of an object with its _key replaced.
fn rekeyed(a: Allocator, v: *const Value, key: []const u8) !Value {
    var o: json.ObjectMap = .empty;
    if (v.* == .object) {
        var it = v.object.iterator();
        while (it.next()) |e| try o.put(a, e.key_ptr.*, if (std.mem.eql(u8, e.key_ptr.*, "_key")) .{ .string = key } else e.value_ptr.*);
    }
    if (o.get("_key") == null) try o.put(a, "_key", .{ .string = key });
    return .{ .object = o };
}

/// Claims `want` as a key in `used`, or a new one when it is taken or
/// missing.
fn claimKey(r: *Registry, a: Allocator, used: *std.StringHashMap(void), want: ?[]const u8) ![]const u8 {
    if (want) |k| if (k.len > 0 and !used.contains(k)) {
        try used.put(k, {});
        return k;
    };
    return r.newKey(a, used);
}

/// The model to Portable Text JSON, indented with two spaces. Caller
/// frees.
pub fn exportJson(r: *Registry, gpa: Allocator, m: Model) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var doc: json.Array = .init(a);
    var block_keys: std.StringHashMap(void) = .init(a);
    var ri: usize = 0;
    var bi: usize = 0;
    while (bi < m.blocks.len) {
        const b = m.blocks[bi];
        const d = r.def(b.def);
        switch (d.kind) {
            .object => {
                const raw = d.raw.?;
                const want = string(raw.*, "_key");
                const key = try claimKey(r, a, &block_keys, want);
                try doc.append(if (want != null and std.mem.eql(u8, want.?, key)) raw.* else try rekeyed(a, raw, key));
                bi += 1;
            },
            .code => {
                var code: std.ArrayList(u8) = .empty;
                var j = bi;
                while (j < m.blocks.len and m.blocks[j].def == b.def) : (j += 1) {
                    if (j > bi) try code.append(a, '\n');
                    try code.appendSlice(a, m.text[m.blocks[j].start..m.blocks[j].stop]);
                }
                const code_text = try exportText(a, code.items);
                var o: json.ObjectMap = .empty;
                try o.put(a, "_type", .{ .string = "code" });
                try o.put(a, "_key", .{ .string = try claimKey(r, a, &block_keys, if (d.raw) |raw| string(raw.*, "_key") else null) });
                if (d.raw) |raw| if (raw.* == .object) {
                    var it = raw.object.iterator();
                    while (it.next()) |e| {
                        const k = e.key_ptr.*;
                        if (std.mem.eql(u8, k, "_type") or std.mem.eql(u8, k, "_key")) continue;
                        try o.put(a, k, if (std.mem.eql(u8, k, "code")) .{ .string = code_text } else e.value_ptr.*);
                    }
                };
                if (o.get("code") == null) try o.put(a, "code", .{ .string = code_text });
                try doc.append(.{ .object = o });
                bi = j;
            },
            .text => {
                try doc.append(try exportTextBlock(r, a, m, b, d, &ri, &block_keys));
                bi += 1;
            },
        }
    }
    return json.Stringify.valueAlloc(gpa, Value{ .array = doc }, .{ .whitespace = .indent_2 });
}

const Piece = struct { start: u32, stop: u32, marks: Marks = .{}, ann: u32 = 0 };

fn exportTextBlock(r: *Registry, a: Allocator, m: Model, b: Block, d: Def, ri: *usize, block_keys: *std.StringHashMap(void)) !Value {
    // The runs inside the block and the plain text between them, with
    // neighbors of the same marks merged.
    var pieces: std.ArrayList(Piece) = .empty;
    while (ri.* < m.runs.len and m.runs[ri.*].stop <= b.start) ri.* += 1;
    var at = b.start;
    var j = ri.*;
    while (at < b.stop) {
        var p: Piece = .{ .start = at, .stop = b.stop };
        if (j < m.runs.len and m.runs[j].start < b.stop) {
            const run = m.runs[j];
            if (run.start > at) {
                p.stop = run.start;
            } else {
                p = .{ .start = at, .stop = @min(run.stop, b.stop), .marks = run.marks, .ann = run.ann };
                j += 1;
            }
        }
        if (pieces.items.len > 0) {
            const last = &pieces.items[pieces.items.len - 1];
            if (last.stop == p.start and last.marks.eql(p.marks) and last.ann == p.ann) {
                last.stop = p.stop;
                at = p.stop;
                continue;
            }
        }
        try pieces.append(a, p);
        at = p.stop;
    }

    var o: json.ObjectMap = .empty;
    try o.put(a, "_type", .{ .string = "block" });
    try o.put(a, "_key", .{ .string = try claimKey(r, a, block_keys, if (d.raw) |raw| string(raw.*, "_key") else null) });
    try o.put(a, "style", .{ .string = d.style.name() });
    if (d.list != .none) {
        try o.put(a, "listItem", .{ .string = @tagName(d.list) });
        try o.put(a, "level", .{ .integer = d.level });
    }
    if (d.raw) |raw| if (raw.* == .object) {
        var it = raw.object.iterator();
        while (it.next()) |e| if (!isManaged(e.key_ptr.*, &managed_block_fields)) try o.put(a, e.key_ptr.*, e.value_ptr.*);
    };

    var defs: json.Array = .init(a);
    var def_keys: std.StringHashMap(void) = .init(a);
    var ann_keys: std.AutoHashMap(u32, []const u8) = .init(a);
    var children: json.Array = .init(a);
    var span_keys: std.StringHashMap(void) = .init(a);
    const old_children = if (d.raw) |raw| array(raw.*, "children") else &.{};
    for (pieces.items, 0..) |p, i| {
        var marks: json.Array = .init(a);
        for (Marks.names, 0..) |name, bit| if (p.marks.bits() & (@as(u8, 1) << @intCast(bit)) != 0) try marks.append(.{ .string = name });
        if (r.annotationValue(p.ann)) |def| {
            const key = ann_keys.get(p.ann) orelse blk: {
                const want = string(def.*, "_key");
                const k = try claimKey(r, a, &def_keys, want);
                try defs.append(if (want != null and std.mem.eql(u8, want.?, k)) def.* else try rekeyed(a, def, k));
                try ann_keys.put(p.ann, k);
                break :blk k;
            };
            try marks.append(.{ .string = key });
        }
        const text = try exportText(a, m.text[p.start..p.stop]);
        // A span keeps its key while its text stays the same.
        const old_key = if (i < old_children.len and std.mem.eql(u8, string(old_children[i], "text") orelse "", text)) string(old_children[i], "_key") else null;
        var span: json.ObjectMap = .empty;
        try span.put(a, "_type", .{ .string = "span" });
        try span.put(a, "_key", .{ .string = try claimKey(r, a, &span_keys, old_key) });
        try span.put(a, "text", .{ .string = text });
        try span.put(a, "marks", .{ .array = marks });
        try children.append(.{ .object = span });
    }
    if (children.items.len == 0) {
        var span: json.ObjectMap = .empty;
        try span.put(a, "_type", .{ .string = "span" });
        const old_key = if (old_children.len > 0) string(old_children[0], "_key") else null;
        try span.put(a, "_key", .{ .string = try claimKey(r, a, &span_keys, old_key) });
        try span.put(a, "text", .{ .string = "" });
        try span.put(a, "marks", .{ .array = .init(a) });
        try children.append(.{ .object = span });
    }
    try o.put(a, "markDefs", .{ .array = defs });
    try o.put(a, "children", .{ .array = children });
    return .{ .object = o };
}

/// A short description of an object block, for its placeholder.
pub fn describe(buf: []u8, raw: *const Value) []const u8 {
    const ty = string(raw.*, "_type") orelse "object";
    if (std.mem.eql(u8, ty, "image")) {
        const alt = string(raw.*, "alt") orelse string(raw.*, "caption") orelse "";
        return std.fmt.bufPrint(buf, "Image{s}{s}", .{ if (alt.len > 0) ": " else "", alt }) catch ty;
    }
    if (std.mem.eql(u8, ty, "table")) {
        const rows = array(raw.*, "rows").len;
        return std.fmt.bufPrint(buf, "Table, {d} rows", .{rows}) catch ty;
    }
    if (std.mem.eql(u8, ty, "htmlBlock")) return "HTML";
    if (std.mem.eql(u8, ty, "break")) return "Break";
    return std.fmt.bufPrint(buf, "{s}", .{ty}) catch ty;
}

/// A code block's language, or "".
pub fn language(raw: ?*const Value) []const u8 {
    return if (raw) |v| string(v.*, "language") orelse "" else "";
}
