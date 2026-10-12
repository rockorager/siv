//! uucode build configuration: which Unicode properties are compiled into
//! lookup tables. build.zig passes this file to uucode, so the text
//! workstream can change fields and tables without editing build.zig. See
//! uucode's README ("Advanced configuration") for the format.
//!
//! uucode does not ship Line_Break, Word_Break, or Script_Extensions, so
//! this file adds them as extension fields built from the pinned UCD 18.0.0
//! files (build.zig embeds them into the table generator by basename):
//!
//!   line_break         LineBreak.txt
//!   word_break         auxiliary/WordBreakProperty.txt
//!   iso_script         Scripts.txt, as an ISO 15924 tag (HarfBuzz's
//!                      hb_script_t) via PropertyValueAliases.txt
//!   script_extensions  ScriptExtensions.txt, concatenated ISO 15924 codes;
//!                      empty when the code point has no explicit value
//!                      (then Script_Extensions = {Script})

const std = @import("std");
const config = @import("config.zig");

/// UAX #14 Line_Break values, named after their short aliases.
pub const LineBreak = enum(u8) {
    xx, ai, ak, al, ap, as, b2, ba, bb, bk, cb, cj, cl, cm, cp, cr, eb, em,
    ex, gl, h2, h3, hh, hl, hy, id, in, is, jl, jt, jv, lf, nl, ns, nu, op,
    po, pr, qu, ri, sa, sg, sp, sy, vf, vi, wj, zw, zwj,
};

/// UAX #29 Word_Break values, lowercased.
pub const WordBreak = enum(u8) {
    other, cr, lf, newline, extend, zwj, regional_indicator, format, katakana,
    hebrew_letter, aletter, single_quote, double_quote, midnumlet, midletter,
    midnum, numeric, extendnumlet, wsegspace,
};

pub const fields = &config.mergeFields(config.fields, &.{
    .{ .name = "line_break", .type = LineBreak },
    .{ .name = "word_break", .type = WordBreak },
    .{ .name = "iso_script", .type = u32 },
    .{
        .name = "script_extensions",
        .type = []const u8,
        .max_len = 92,
        .max_offset = 2168,
        .embedded_len = 0,
    },
});

pub const build_components = &config.mergeComponents(config.build_components, &.{
    .{ .Impl = LineBreakComponent, .fields = &.{"line_break"} },
    .{ .Impl = WordBreakComponent, .fields = &.{"word_break"} },
    .{ .Impl = ScriptComponent, .fields = &.{ "iso_script", "script_extensions" } },
});

pub const get_components = config.get_components;

pub const tables: []const config.Table = &.{
    .{ .fields = &.{
        "general_category",
        "grapheme_break",
        "line_break",
        "word_break",
        "east_asian_width",
        "is_extended_pictographic",
        "is_emoji",
        "is_emoji_presentation",
        "is_emoji_vs_base",
        "is_emoji_modifier",
        "is_emoji_modifier_base",
        "bidi_paired_bracket",
    } },
    .{ .fields = &.{ "iso_script", "script_extensions" } },
};

const Range = struct { start: usize, end: usize, value: []const u8 };

/// Iterates `<range> ; <value>` records of a UCD property file. The value is
/// the second field with surrounding space removed.
const Records = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn init(content: []const u8) Records {
        return .{ .lines = std.mem.splitScalar(u8, content, '\n') };
    }

    fn next(self: *Records) !?Range {
        while (self.lines.next()) |line| {
            const body = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
            if (body.len == 0) continue;
            var parts = std.mem.splitScalar(u8, body, ';');
            const range_text = std.mem.trim(u8, parts.next().?, " \t");
            const value = std.mem.trim(u8, parts.next() orelse return error.InvalidUcdLine, " \t");
            const start, const last = if (std.mem.indexOf(u8, range_text, "..")) |dots| .{
                try std.fmt.parseInt(u21, range_text[0..dots], 16),
                try std.fmt.parseInt(u21, range_text[dots + 2 ..], 16),
            } else blk: {
                const cp = try std.fmt.parseInt(u21, range_text, 16);
                break :blk .{ cp, cp };
            };
            return .{ .start = start, .end = @as(usize, last) + 1, .value = value };
        }
        return null;
    }
};

/// Parses an enum value from a UCD long or short name by lowercasing it.
fn enumValue(comptime E: type, name: []const u8) !E {
    var buffer: [64]u8 = undefined;
    if (name.len > buffer.len) return error.UnknownUcdValue;
    const lower = std.ascii.lowerString(&buffer, name);
    return std.meta.stringToEnum(E, lower) orelse {
        std.log.err("unknown {s} value: {s}", .{ @typeName(E), name });
        return error.UnknownUcdValue;
    };
}

fn fillEnum(comptime E: type, items: []E, default: E, content: []const u8) !void {
    @memset(items, default);
    var records = Records.init(content);
    while (try records.next()) |record| {
        const value = try enumValue(E, record.value);
        @memset(items[record.start..record.end], value);
    }
}

const LineBreakComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = .{ allocator, io, inputs, backing, tracking };
        rows.len = config.num_code_points;
        // The only @missing line in Unicode 18 is `0000..10FFFF; XX`.
        try fillEnum(LineBreak, rows.items(.line_break), .xx, @embedFile("LineBreak.txt"));
    }
};

const WordBreakComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = .{ allocator, io, inputs, backing, tracking };
        rows.len = config.num_code_points;
        try fillEnum(WordBreak, rows.items(.word_break), .other, @embedFile("WordBreakProperty.txt"));
    }
};

fn isoTag(code: []const u8) !u32 {
    if (code.len != 4) return error.InvalidScriptCode;
    return std.mem.readInt(u32, code[0..4], .big);
}

const ScriptComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = .{ io, inputs };

        // Long script names (Scripts.txt) to ISO 15924 codes.
        var codes: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer codes.deinit(allocator);
        var aliases = std.mem.splitScalar(u8, @embedFile("PropertyValueAliases.txt"), '\n');
        while (aliases.next()) |line| {
            if (!std.mem.startsWith(u8, line, "sc ")) continue;
            var parts = std.mem.splitScalar(u8, line, ';');
            _ = parts.next();
            const short = std.mem.trim(u8, parts.next() orelse continue, " \t\r");
            const long = std.mem.trim(u8, parts.next() orelse continue, " \t\r");
            try codes.put(allocator, long, short);
        }

        const scripts = try allocator.alloc(u32, config.num_code_points);
        defer allocator.free(scripts);
        @memset(scripts, try isoTag("Zzzz"));
        var records = Records.init(@embedFile("Scripts.txt"));
        while (try records.next()) |record| {
            const code = codes.get(record.value) orelse {
                std.log.err("unknown script: {s}", .{record.value});
                return error.UnknownUcdValue;
            };
            @memset(scripts[record.start..record.end], try isoTag(code));
        }

        const extensions = try allocator.alloc([]const u8, config.num_code_points);
        defer allocator.free(extensions);
        @memset(extensions, "");
        var concatenated: std.ArrayList(u8) = .empty;
        defer concatenated.deinit(allocator);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        records = Records.init(@embedFile("ScriptExtensions.txt"));
        while (try records.next()) |record| {
            concatenated.clearRetainingCapacity();
            var tokens = std.mem.tokenizeAny(u8, record.value, " \t");
            while (tokens.next()) |code| {
                _ = try isoTag(code);
                try concatenated.appendSlice(allocator, code);
            }
            const value = try arena.allocator().dupe(u8, concatenated.items);
            @memset(extensions[record.start..record.end], value);
        }

        for (0..config.num_code_points) |i| {
            const cp: u21 = @intCast(i);
            var row: Row = undefined;
            config.setBuiltField(&row, "iso_script", scripts[i]);
            try config.setAllocField(allocator, &row, "script_extensions", cp, extensions[i], tracking);
            rows.append(row);
        }
        _ = backing;
    }
};
