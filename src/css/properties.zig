//! Properties: names, parsing declarations into specified values
//! (shorthands expanded into longhands at parse time), and computing them
//! into a `Style`. A declaration with var() keeps its tokens and is parsed
//! after substitution, per element (CSS Variables Level 1).

const std = @import("std");
const tk = @import("tokenizer.zig");
const values = @import("values.zig");
const color_mod = @import("color.zig");
const style = @import("style.zig");

const Token = tk.Token;
const Color = color_mod.Color;
const Unit = values.Unit;
const Len = style.Len;
const LenTag = style.LenTag;
const Allocator = std.mem.Allocator;
const Error = error{OutOfMemory};

pub const Id = enum(u8) {
    // Inherited.
    color,
    font_family,
    font_size,
    font_weight,
    font_style,
    font_stretch,
    font_variant_caps,
    font_variation_settings,
    line_height,
    text_align,
    text_align_last,
    text_indent,
    text_transform,
    white_space_collapse,
    text_wrap_mode,
    text_wrap_style,
    word_break,
    overflow_wrap,
    hyphens,
    letter_spacing,
    word_spacing,
    direction,
    list_style_type,
    list_style_position,
    list_style_image,
    visibility,
    border_collapse,
    border_spacing,
    caption_side,
    empty_cells,
    tab_size,
    cursor,
    color_scheme,
    orphans,
    widows,
    // Not inherited.
    display,
    position,
    top,
    right,
    bottom,
    left,
    float,
    clear,
    width,
    height,
    min_width,
    min_height,
    max_width,
    max_height,
    box_sizing,
    margin_top,
    margin_right,
    margin_bottom,
    margin_left,
    padding_top,
    padding_right,
    padding_bottom,
    padding_left,
    border_top_width,
    border_right_width,
    border_bottom_width,
    border_left_width,
    border_top_style,
    border_right_style,
    border_bottom_style,
    border_left_style,
    border_top_color,
    border_right_color,
    border_bottom_color,
    border_left_color,
    border_top_left_radius,
    border_top_right_radius,
    border_bottom_right_radius,
    border_bottom_left_radius,
    background_color,
    background_image,
    background_repeat,
    background_position,
    background_size,
    background_clip,
    background_origin,
    mask_image,
    mask_repeat,
    mask_position,
    mask_size,
    box_shadow,
    opacity,
    overflow_x,
    overflow_y,
    z_index,
    vertical_align,
    text_decoration_line,
    text_decoration_style,
    text_decoration_color,
    text_decoration_thickness,
    text_underline_offset,
    text_overflow,
    flex_direction,
    flex_wrap,
    flex_grow,
    flex_shrink,
    flex_basis,
    order,
    justify_content,
    align_items,
    align_self,
    align_content,
    justify_items,
    justify_self,
    row_gap,
    column_gap,
    grid_template_columns,
    grid_template_rows,
    grid_template_areas,
    grid_auto_flow,
    grid_auto_columns,
    grid_auto_rows,
    grid_row_start,
    grid_row_end,
    grid_column_start,
    grid_column_end,
    object_fit,
    object_position,
    aspect_ratio,
    content,
    counter_reset,
    counter_increment,
    counter_set,
    table_layout,
    break_before,
    break_after,
    break_inside,
    column_count,
    column_width,
    column_span,
    outline_width,
    outline_style,
    outline_color,
    outline_offset,
    unicode_bidi,

    pub fn inherited(id: Id) bool {
        return @intFromEnum(id) < @intFromEnum(Id.display);
    }
};

pub const count = @typeInfo(Id).@"enum".field_names.len;

pub const Wide = enum(u8) { inherit, initial, unset, revert };

/// A specified length-percentage.
pub const SLen = struct {
    v: f32 = 0,
    unit: Unit = .px,
    tag: LenTag = .length,
    calc: ?*const values.Calc = null,

    pub const auto: SLen = .{ .tag = .auto };
    pub const none: SLen = .{ .tag = .none };
    pub const zero: SLen = .{};

    pub fn compute(s: SLen, a: Allocator, ctx: *const values.Context) Error!Len {
        if (s.tag != .length) return .{ .tag = s.tag };
        if (s.calc) |c| {
            const l = c.linear(ctx);
            if (l.nonlinear) {
                const nl = try a.create(style.NonLinear);
                nl.* = .{ .calc = c.*, .ctx = ctx.* };
                return .{ .nl = nl };
            }
            return .{ .px = l.px + l.number, .pct = l.pct };
        }
        if (s.unit == .percent) return .{ .pct = s.v / 100 };
        return .{ .px = values.toPx(s.v, s.unit, ctx) };
    }

    /// Lengths without percentages, as pixels.
    pub fn px(s: SLen, ctx: *const values.Context) f32 {
        if (s.calc) |c| return c.eval(ctx, 0);
        if (s.unit == .percent) return 0;
        return values.toPx(s.v, s.unit, ctx);
    }
};

pub const SLineHeight = struct { kind: enum(u8) { normal, number, length } = .normal, number: f32 = 0, len: SLen = .{} };

pub const Unparsed = struct {
    /// The declaration's value tokens, var() unresolved.
    text: []const u8,
    /// The shorthand the value was written for, if any.
    shorthand: ?Shorthand = null,
};

pub const Value = union(enum) {
    wide: Wide,
    keyword: u8,
    len: SLen,
    pair: [2]SLen,
    number: f32,
    integer: i32,
    color: Color,
    families: *const style.Families,
    image: ?*const style.Image,
    shadows: ?*const style.Shadows,
    tracks: ?*const style.Tracks,
    areas: ?*const style.Areas,
    line: style.GridLine,
    content: ?*const style.Content,
    content_none,
    counters: ?*const style.Counters,
    display: style.Display,
    decoration: style.Decoration,
    line_height: SLineHeight,
    bg_size: struct { kind: @TypeOf(@as(style.BackgroundSize, .{}).kind), w: SLen, h: SLen },
    variations: ?*const []const [2]u32,
    list_style_string: []const u8,
    flow: style.GridAutoFlow,
    font_size_keyword: f32,
    weight_relative: enum(u8) { bolder, lighter },
    unparsed: *const Unparsed,
};

pub const Declaration = struct {
    id: Id,
    important: bool = false,
    value: Value,
};

pub const Shorthand = enum(u8) {
    margin,
    padding,
    border,
    border_top,
    border_right,
    border_bottom,
    border_left,
    border_width,
    border_style,
    border_color,
    border_radius,
    background,
    mask,
    font,
    flex,
    flex_flow,
    gap,
    grid_area,
    grid_row,
    grid_column,
    grid_template,
    list_style,
    overflow,
    text_decoration,
    outline,
    place_items,
    place_content,
    place_self,
    inset,
    columns,
    white_space,
    text_wrap,
    border_block,
    border_inline,
    margin_block,
    margin_inline,
    padding_block,
    padding_inline,

    pub fn longhands(s: Shorthand) []const Id {
        return switch (s) {
            .margin => &.{ .margin_top, .margin_right, .margin_bottom, .margin_left },
            .padding => &.{ .padding_top, .padding_right, .padding_bottom, .padding_left },
            .border => &.{ .border_top_width, .border_right_width, .border_bottom_width, .border_left_width, .border_top_style, .border_right_style, .border_bottom_style, .border_left_style, .border_top_color, .border_right_color, .border_bottom_color, .border_left_color },
            .border_top => &.{ .border_top_width, .border_top_style, .border_top_color },
            .border_right => &.{ .border_right_width, .border_right_style, .border_right_color },
            .border_bottom => &.{ .border_bottom_width, .border_bottom_style, .border_bottom_color },
            .border_left => &.{ .border_left_width, .border_left_style, .border_left_color },
            .border_block => &.{ .border_top_width, .border_top_style, .border_top_color, .border_bottom_width, .border_bottom_style, .border_bottom_color },
            .border_inline => &.{ .border_left_width, .border_left_style, .border_left_color, .border_right_width, .border_right_style, .border_right_color },
            .border_width => &.{ .border_top_width, .border_right_width, .border_bottom_width, .border_left_width },
            .border_style => &.{ .border_top_style, .border_right_style, .border_bottom_style, .border_left_style },
            .border_color => &.{ .border_top_color, .border_right_color, .border_bottom_color, .border_left_color },
            .border_radius => &.{ .border_top_left_radius, .border_top_right_radius, .border_bottom_right_radius, .border_bottom_left_radius },
            .background => &.{ .background_color, .background_image, .background_repeat, .background_position, .background_size, .background_clip, .background_origin },
            .mask => &.{ .mask_image, .mask_repeat, .mask_position, .mask_size },
            .font => &.{ .font_style, .font_variant_caps, .font_weight, .font_stretch, .font_size, .line_height, .font_family },
            .flex => &.{ .flex_grow, .flex_shrink, .flex_basis },
            .flex_flow => &.{ .flex_direction, .flex_wrap },
            .gap => &.{ .row_gap, .column_gap },
            .grid_area => &.{ .grid_row_start, .grid_column_start, .grid_row_end, .grid_column_end },
            .grid_row => &.{ .grid_row_start, .grid_row_end },
            .grid_column => &.{ .grid_column_start, .grid_column_end },
            .grid_template => &.{ .grid_template_rows, .grid_template_columns, .grid_template_areas },
            .list_style => &.{ .list_style_type, .list_style_position, .list_style_image },
            .overflow => &.{ .overflow_x, .overflow_y },
            .text_decoration => &.{ .text_decoration_line, .text_decoration_style, .text_decoration_color, .text_decoration_thickness },
            .outline => &.{ .outline_width, .outline_style, .outline_color },
            .place_items => &.{ .align_items, .justify_items },
            .place_content => &.{ .align_content, .justify_content },
            .place_self => &.{ .align_self, .justify_self },
            .inset => &.{ .top, .right, .bottom, .left },
            .columns => &.{ .column_width, .column_count },
            .white_space => &.{ .white_space_collapse, .text_wrap_mode },
            .text_wrap => &.{ .text_wrap_mode, .text_wrap_style },
            .margin_block => &.{ .margin_top, .margin_bottom },
            .margin_inline => &.{ .margin_left, .margin_right },
            .padding_block => &.{ .padding_top, .padding_bottom },
            .padding_inline => &.{ .padding_left, .padding_right },
        };
    }
};

pub const Prop = union(enum) { longhand: Id, shorthand: Shorthand };

const name_list = blk: {
    @setEvalBranchQuota(100000);
    var list: []const struct { []const u8, Prop } = &.{};
    for (@typeInfo(Id).@"enum".field_names) |f| {
        var buf: [f.len]u8 = undefined;
        for (f, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
        const final = buf;
        list = list ++ .{.{ &final, Prop{ .longhand = @field(Id, f) } }};
    }
    for (@typeInfo(Shorthand).@"enum".field_names) |f| {
        var buf: [f.len]u8 = undefined;
        for (f, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
        const final = buf;
        list = list ++ .{.{ &final, Prop{ .shorthand = @field(Shorthand, f) } }};
    }
    // Aliases and logical properties (mapped to physical ones for
    // horizontal left-to-right text, which is what documents nearly
    // always are).
    list = list ++ .{
        .{ "grid-gap", Prop{ .shorthand = .gap } },
        .{ "grid-row-gap", Prop{ .longhand = .row_gap } },
        .{ "grid-column-gap", Prop{ .longhand = .column_gap } },
        .{ "word-wrap", Prop{ .longhand = .overflow_wrap } },
        // The caps part of the shorthand (other values are dropped).
        .{ "font-variant", Prop{ .longhand = .font_variant_caps } },
        .{ "page-break-before", Prop{ .longhand = .break_before } },
        .{ "page-break-after", Prop{ .longhand = .break_after } },
        .{ "page-break-inside", Prop{ .longhand = .break_inside } },
        .{ "-webkit-hyphens", Prop{ .longhand = .hyphens } },
        .{ "-ms-hyphens", Prop{ .longhand = .hyphens } },
        .{ "-epub-hyphens", Prop{ .longhand = .hyphens } },
        .{ "-webkit-box-shadow", Prop{ .longhand = .box_shadow } },
        .{ "-webkit-mask", Prop{ .shorthand = .mask } },
        .{ "-webkit-mask-image", Prop{ .longhand = .mask_image } },
        .{ "-webkit-mask-repeat", Prop{ .longhand = .mask_repeat } },
        .{ "-webkit-mask-position", Prop{ .longhand = .mask_position } },
        .{ "-webkit-mask-size", Prop{ .longhand = .mask_size } },
        .{ "-webkit-text-decoration-line", Prop{ .longhand = .text_decoration_line } },
        .{ "margin-block-start", Prop{ .longhand = .margin_top } },
        .{ "margin-block-end", Prop{ .longhand = .margin_bottom } },
        .{ "margin-inline-start", Prop{ .longhand = .margin_left } },
        .{ "margin-inline-end", Prop{ .longhand = .margin_right } },
        .{ "padding-block-start", Prop{ .longhand = .padding_top } },
        .{ "padding-block-end", Prop{ .longhand = .padding_bottom } },
        .{ "padding-inline-start", Prop{ .longhand = .padding_left } },
        .{ "padding-inline-end", Prop{ .longhand = .padding_right } },
        .{ "inline-size", Prop{ .longhand = .width } },
        .{ "block-size", Prop{ .longhand = .height } },
        .{ "min-inline-size", Prop{ .longhand = .min_width } },
        .{ "max-inline-size", Prop{ .longhand = .max_width } },
        .{ "min-block-size", Prop{ .longhand = .min_height } },
        .{ "max-block-size", Prop{ .longhand = .max_height } },
        .{ "inset-block-start", Prop{ .longhand = .top } },
        .{ "inset-block-end", Prop{ .longhand = .bottom } },
        .{ "inset-inline-start", Prop{ .longhand = .left } },
        .{ "inset-inline-end", Prop{ .longhand = .right } },
        .{ "border-block-start", Prop{ .shorthand = .border_top } },
        .{ "border-block-end", Prop{ .shorthand = .border_bottom } },
        .{ "border-inline-start", Prop{ .shorthand = .border_left } },
        .{ "border-inline-end", Prop{ .shorthand = .border_right } },
        .{ "border-start-start-radius", Prop{ .longhand = .border_top_left_radius } },
        .{ "border-start-end-radius", Prop{ .longhand = .border_top_right_radius } },
        .{ "border-end-start-radius", Prop{ .longhand = .border_bottom_left_radius } },
        .{ "border-end-end-radius", Prop{ .longhand = .border_bottom_right_radius } },
        .{ "overflow-block", Prop{ .longhand = .overflow_y } },
        .{ "overflow-inline", Prop{ .longhand = .overflow_x } },
        .{ "-webkit-column-count", Prop{ .longhand = .column_count } },
        .{ "-webkit-columns", Prop{ .shorthand = .columns } },
        .{ "text-decoration-skip-ink", Prop{ .longhand = .text_decoration_style } },
    };
    break :blk list;
};

const name_map = std.StaticStringMap(Prop).initComptime(name_list);

pub fn lookup(name: []const u8) ?Prop {
    var buf: [48]u8 = undefined;
    if (name.len > buf.len) return null;
    return name_map.get(std.ascii.lowerString(&buf, name));
}

// Parsing.

/// A cursor over a declaration's value tokens (whitespace skipped).
pub const Cursor = struct {
    t: []const Token,
    i: usize = 0,
    a: Allocator,

    pub fn peek(c: *Cursor) Token {
        while (c.i < c.t.len and c.t[c.i].kind == .whitespace) c.i += 1;
        return if (c.i < c.t.len) c.t[c.i] else .{ .kind = .eof };
    }

    pub fn take(c: *Cursor) Token {
        const t = c.peek();
        if (c.i < c.t.len) c.i += 1;
        return t;
    }

    pub fn done(c: *Cursor) bool {
        return c.peek().kind == .eof;
    }

    pub fn ident(c: *Cursor, name: []const u8) bool {
        if (c.peek().isIdent(name)) {
            c.i += 1;
            return true;
        }
        return false;
    }

    /// The tokens up to the matching `)` of a function just taken.
    pub fn args(c: *Cursor) []const Token {
        var depth: usize = 1;
        const start = c.i;
        while (c.i < c.t.len) : (c.i += 1) switch (c.t[c.i].kind) {
            .lparen, .function => depth += 1,
            .rparen => {
                depth -= 1;
                if (depth == 0) {
                    const r = c.t[start..c.i];
                    c.i += 1;
                    return r;
                }
            },
            else => {},
        };
        return c.t[start..];
    }

    pub fn sub(c: *Cursor, t: []const Token) Cursor {
        return .{ .t = t, .a = c.a };
    }

    fn save(c: *const Cursor) usize {
        return c.i;
    }
};

pub const LenFlags = struct {
    percent: bool = true,
    negative: bool = true,
    auto: bool = false,
    none: bool = false,
    normal: bool = false,
    sizing: bool = false,
    /// Unitless numbers as pixels (presentational hints, quirks).
    quirk: bool = false,
};

pub fn parseLen(c: *Cursor, f: LenFlags) Error!?SLen {
    const save = c.i;
    const t = c.take();
    switch (t.kind) {
        .dimension => {
            const u = values.unitOf(t.text) orelse {
                c.i = save;
                return null;
            };
            if (!f.negative and t.number < 0) {
                c.i = save;
                return null;
            }
            return .{ .v = @floatCast(t.number), .unit = u };
        },
        .percentage => if (f.percent and (f.negative or t.number >= 0)) return .{ .v = @floatCast(t.number), .unit = .percent },
        .number => if (t.number == 0 or f.quirk) return .{ .v = @floatCast(t.number), .unit = .px },
        .ident => {
            if (f.auto and t.isIdent("auto")) return SLen.auto;
            if (f.none and t.isIdent("none")) return SLen.none;
            if (f.normal and t.isIdent("normal")) return .{ .tag = .normal };
            if (f.sizing) {
                if (t.isIdent("min-content") or t.isIdent("-webkit-min-content")) return .{ .tag = .min_content };
                if (t.isIdent("max-content") or t.isIdent("-webkit-max-content")) return .{ .tag = .max_content };
                if (t.isIdent("fit-content") or t.isIdent("-moz-fit-content") or t.isIdent("-webkit-fit-content")) return .{ .tag = .fit_content };
                if (t.isIdent("stretch") or t.isIdent("-webkit-fill-available") or t.isIdent("-moz-available")) return .{ .tag = .stretch };
            }
        },
        .function => if (values.isMathFunction(t.text)) {
            const name = if (std.mem.indexOfScalar(u8, t.text, '-') != null and !std.ascii.eqlIgnoreCase(t.text, "clamp")) "calc" else t.text;
            if (try values.parseCalc(c.a, c.t, &c.i, name)) |calc| {
                const p = try c.a.create(values.Calc);
                p.* = calc;
                return .{ .calc = p };
            }
        },
        else => {},
    }
    c.i = save;
    return null;
}

fn parseNumber(c: *Cursor) ?f32 {
    const t = c.peek();
    if (t.kind == .number) {
        c.i += 1;
        return @floatCast(t.number);
    }
    if (t.kind == .function and values.isMathFunction(t.text)) {
        const save = c.i;
        c.i += 1;
        const calc = (values.parseCalc(c.a, c.t, &c.i, t.text) catch return null) orelse {
            c.i = save;
            return null;
        };
        return calc.eval(&.{}, 0);
    }
    return null;
}

fn parseInteger(c: *Cursor) ?i32 {
    const t = c.peek();
    if (t.kind == .number and t.flag) {
        c.i += 1;
        return @intFromFloat(std.math.clamp(t.number, -1e9, 1e9));
    }
    return null;
}

fn keywordOf(comptime E: type, t: Token) ?E {
    if (t.kind != .ident) return null;
    var buf: [32]u8 = undefined;
    if (t.text.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, t.text);
    inline for (@typeInfo(E).@"enum".field_names) |f| {
        const name = comptime blk: {
            var n: [f.len]u8 = undefined;
            for (f, 0..) |ch, i| n[i] = if (ch == '_') '-' else ch;
            break :blk n;
        };
        if (std.mem.eql(u8, lower, &name)) return @field(E, f);
    }
    return null;
}

fn parseKeyword(comptime E: type, c: *Cursor) ?E {
    const k = keywordOf(E, c.peek()) orelse return null;
    c.i += 1;
    return k;
}

fn kw(v: anytype) Value {
    return .{ .keyword = @intFromEnum(v) };
}

fn parseColor(c: *Cursor) ?Color {
    _ = c.peek();
    var pos = c.i;
    const col = color_mod.parse(c.t, &pos) orelse return null;
    c.i = pos;
    return col;
}

/// Adds the declarations a property's value makes. Invalid values add
/// nothing (the declaration is dropped).
pub fn parse(a: Allocator, prop: Prop, tokens_: []const Token, important: bool, out: *std.ArrayList(Declaration)) Error!void {
    // Trim whitespace.
    var tokens = tokens_;
    while (tokens.len > 0 and tokens[0].kind == .whitespace) tokens = tokens[1..];
    while (tokens.len > 0 and tokens[tokens.len - 1].kind == .whitespace) tokens = tokens[0 .. tokens.len - 1];
    if (tokens.len == 0) return;
    // CSS-wide keywords.
    if (tokens.len == 1 and tokens[0].kind == .ident) {
        const w: ?Wide = if (tokens[0].isIdent("inherit")) .inherit else if (tokens[0].isIdent("initial")) .initial else if (tokens[0].isIdent("unset")) .unset else if (tokens[0].isIdent("revert") or tokens[0].isIdent("revert-layer")) .revert else null;
        if (w) |wide| {
            switch (prop) {
                .longhand => |id| try out.append(a, .{ .id = id, .important = important, .value = .{ .wide = wide } }),
                .shorthand => |s| for (s.longhands()) |id| try out.append(a, .{ .id = id, .important = important, .value = .{ .wide = wide } }),
            }
            return;
        }
    }
    // var() anywhere: keep the tokens for later.
    if (hasVar(tokens)) {
        const u = try a.create(Unparsed);
        u.* = .{ .text = try tokenText(a, tokens), .shorthand = if (prop == .shorthand) prop.shorthand else null };
        switch (prop) {
            .longhand => |id| try out.append(a, .{ .id = id, .important = important, .value = .{ .unparsed = u } }),
            .shorthand => |s| for (s.longhands()) |id| try out.append(a, .{ .id = id, .important = important, .value = .{ .unparsed = u } }),
        }
        return;
    }
    var c: Cursor = .{ .t = tokens, .a = a };
    const mark = out.items.len;
    const ok = switch (prop) {
        .longhand => |id| blk: {
            const v = (try parseLonghand(&c, id)) orelse break :blk false;
            if (!c.done()) break :blk false;
            try out.append(a, .{ .id = id, .important = important, .value = v });
            break :blk true;
        },
        .shorthand => |s| (try parseShorthand(&c, s, important, out)) and c.done(),
    };
    if (!ok) out.shrinkRetainingCapacity(mark);
}

fn hasVar(tokens: []const Token) bool {
    for (tokens) |t| if (t.kind == .function and (std.ascii.eqlIgnoreCase(t.text, "var") or std.ascii.eqlIgnoreCase(t.text, "env"))) return true;
    return false;
}

/// Serializes tokens back to text (for var() substitution, which works on
/// token streams; re-tokenizing the text gives the same tokens).
pub fn tokenText(a: Allocator, tokens: []const Token) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (tokens) |t| try writeToken(a, &out, t);
    return out.items;
}

fn writeToken(a: Allocator, out: *std.ArrayList(u8), t: Token) Error!void {
    switch (t.kind) {
        .ident => try writeIdent(a, out, t.text),
        .function => {
            try writeIdent(a, out, t.text);
            try out.append(a, '(');
        },
        .at_keyword => {
            try out.append(a, '@');
            try writeIdent(a, out, t.text);
        },
        .hash => {
            try out.append(a, '#');
            try out.appendSlice(a, t.text);
        },
        .string => {
            try out.append(a, '"');
            for (t.text) |ch| {
                if (ch == '"' or ch == '\\') try out.append(a, '\\');
                if (ch == '\n') {
                    try out.appendSlice(a, "\\a ");
                    continue;
                }
                try out.append(a, ch);
            }
            try out.append(a, '"');
        },
        .url => {
            try out.appendSlice(a, "url(\"");
            for (t.text) |ch| {
                if (ch == '"' or ch == '\\') try out.append(a, '\\');
                try out.append(a, ch);
            }
            try out.appendSlice(a, "\")");
        },
        .bad_string, .bad_url => try out.appendSlice(a, " "),
        .delim => {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(t.delim, &buf) catch 1;
            try out.appendSlice(a, buf[0..n]);
        },
        .number, .percentage, .dimension => {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{t.number}) catch "0";
            try out.appendSlice(a, s);
            if (t.kind == .percentage) try out.append(a, '%');
            if (t.kind == .dimension) {
                // A unit that starts like an exponent would be misread.
                if (t.text.len > 0 and (t.text[0] == 'e' or t.text[0] == 'E')) {
                    try out.appendSlice(a, "\\65 ");
                    try out.appendSlice(a, t.text[1..]);
                } else try out.appendSlice(a, t.text);
            }
        },
        .whitespace => try out.append(a, ' '),
        .cdo => try out.appendSlice(a, "<!--"),
        .cdc => try out.appendSlice(a, "-->"),
        .colon => try out.append(a, ':'),
        .semicolon => try out.append(a, ';'),
        .comma => try out.append(a, ','),
        .lbracket => try out.append(a, '['),
        .rbracket => try out.append(a, ']'),
        .lparen => try out.append(a, '('),
        .rparen => try out.append(a, ')'),
        .lbrace => try out.append(a, '{'),
        .rbrace => try out.append(a, '}'),
        .eof => {},
    }
    // Keep adjacent tokens apart where they would merge.
    switch (t.kind) {
        .ident, .number, .percentage, .dimension, .at_keyword, .hash => try out.append(a, ' '),
        else => {},
    }
}

fn writeIdent(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Error!void {
    for (s, 0..) |ch, i| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch >= 0x80;
        if (!ok or (i == 0 and std.ascii.isDigit(ch))) {
            var buf: [8]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&buf, "\\{x} ", .{ch}) catch "");
        } else try out.append(a, ch);
    }
}

fn parseLonghand(c: *Cursor, id: Id) Error!?Value {
    return switch (id) {
        .color, .background_color, .border_top_color, .border_right_color, .border_bottom_color, .border_left_color, .text_decoration_color, .outline_color => if (parseColor(c)) |col| .{ .color = col } else null,
        .font_family => if (try parseFamilies(c)) |f| .{ .families = f } else null,
        .font_size => try parseFontSize(c),
        .font_weight => parseFontWeight(c),
        .font_style => blk: {
            const k = parseKeyword(style.FontStyle, c) orelse break :blk null;
            // An oblique angle is accepted and dropped.
            if (k == .oblique and c.peek().kind == .dimension) _ = c.take();
            break :blk kw(k);
        },
        .font_stretch => blk: {
            const t = c.peek();
            if (t.kind == .percentage) {
                _ = c.take();
                break :blk .{ .number = @floatCast(t.number) };
            }
            const map = [_]struct { []const u8, f32 }{ .{ "ultra-condensed", 50 }, .{ "extra-condensed", 62.5 }, .{ "condensed", 75 }, .{ "semi-condensed", 87.5 }, .{ "normal", 100 }, .{ "semi-expanded", 112.5 }, .{ "expanded", 125 }, .{ "extra-expanded", 150 }, .{ "ultra-expanded", 200 } };
            for (map) |m| if (c.ident(m[0])) break :blk .{ .number = m[1] };
            break :blk null;
        },
        .font_variant_caps => if (parseKeyword(style.FontVariantCaps, c)) |k| kw(k) else null,
        .font_variation_settings => try parseVariations(c),
        .line_height => blk: {
            if (c.ident("normal")) break :blk .{ .line_height = .{ .kind = .normal } };
            if (parseNumber(c)) |n| {
                if (n < 0) break :blk null;
                break :blk .{ .line_height = .{ .kind = .number, .number = n } };
            }
            const l = (try parseLen(c, .{ .negative = false })) orelse break :blk null;
            break :blk .{ .line_height = .{ .kind = .length, .len = l } };
        },
        .text_align => blk: {
            if (c.ident("-webkit-center") or c.ident("-moz-center")) break :blk kw(style.TextAlign.legacy_center);
            if (c.ident("-webkit-left") or c.ident("-moz-left")) break :blk kw(style.TextAlign.legacy_left);
            if (c.ident("-webkit-right") or c.ident("-moz-right")) break :blk kw(style.TextAlign.legacy_right);
            break :blk if (parseKeyword(style.TextAlign, c)) |k| kw(k) else null;
        },
        .text_align_last => if (parseKeyword(style.TextAlignLast, c)) |k| kw(k) else null,
        .text_indent => blk: {
            const l = (try parseLen(c, .{})) orelse break :blk null;
            _ = c.ident("hanging");
            _ = c.ident("each-line");
            break :blk .{ .len = l };
        },
        .text_transform => if (parseKeyword(style.TextTransform, c)) |k| kw(k) else null,
        .white_space_collapse => if (parseKeyword(style.WhiteSpaceCollapse, c)) |k| kw(k) else null,
        .text_wrap_mode => if (parseKeyword(style.TextWrapMode, c)) |k| kw(k) else null,
        .text_wrap_style => if (parseKeyword(style.TextWrapStyle, c)) |k| kw(k) else null,
        .word_break => if (parseKeyword(style.WordBreak, c)) |k| kw(k) else null,
        .overflow_wrap => if (parseKeyword(style.OverflowWrap, c)) |k| kw(k) else null,
        .hyphens => if (parseKeyword(style.Hyphens, c)) |k| kw(k) else null,
        .letter_spacing, .word_spacing => if (try parseLen(c, .{ .normal = true, .percent = id == .word_spacing })) |l| .{ .len = l } else null,
        .direction => if (parseKeyword(style.Direction, c)) |k| kw(k) else null,
        .list_style_type => parseListStyleType(c),
        .list_style_position => if (parseKeyword(style.ListStylePosition, c)) |k| kw(k) else null,
        .list_style_image => if (c.ident("none")) Value{ .image = null } else if (try parseImage(c)) |img| .{ .image = img } else null,
        .visibility => if (parseKeyword(style.Visibility, c)) |k| kw(k) else null,
        .border_collapse => if (parseKeyword(style.BorderCollapse, c)) |k| kw(k) else null,
        .border_spacing => blk: {
            const h = (try parseLen(c, .{ .percent = false, .negative = false })) orelse break :blk null;
            const v = (try parseLen(c, .{ .percent = false, .negative = false })) orelse h;
            break :blk .{ .pair = .{ h, v } };
        },
        .caption_side => if (parseKeyword(style.CaptionSide, c)) |k| kw(k) else null,
        .empty_cells => if (parseKeyword(style.EmptyCells, c)) |k| kw(k) else null,
        .tab_size => if (parseNumber(c)) |n| .{ .number = n } else if (try parseLen(c, .{ .percent = false, .negative = false })) |l| .{ .len = l } else null,
        .cursor => blk: {
            // Skip url() fallbacks.
            while (c.peek().kind == .url) {
                _ = c.take();
                if (c.peek().kind == .comma) _ = c.take();
            }
            const k = parseKeyword(style.Cursor, c) orelse {
                if (c.peek().kind == .ident) {
                    _ = c.take();
                    break :blk kw(style.Cursor.auto);
                }
                break :blk null;
            };
            break :blk kw(k);
        },
        .color_scheme => blk: {
            var light = false;
            var dark = false;
            var any = false;
            while (c.peek().kind == .ident) {
                const t = c.take();
                any = true;
                if (t.isIdent("light")) light = true else if (t.isIdent("dark")) dark = true;
            }
            if (!any) break :blk null;
            break :blk kw(if (light and dark) style.ColorScheme.light_dark else if (dark) style.ColorScheme.dark else if (light) style.ColorScheme.light else style.ColorScheme.normal);
        },
        .orphans, .widows, .column_count => if (id == .column_count and c.ident("auto")) Value{ .integer = 0 } else if (parseInteger(c)) |n| (if (n < 1) null else Value{ .integer = n }) else null,
        .display => parseDisplay(c),
        .position => blk: {
            if (c.ident("-webkit-sticky")) break :blk kw(style.Position.sticky);
            break :blk if (parseKeyword(style.Position, c)) |k| kw(k) else null;
        },
        .top, .right, .bottom, .left => if (try parseLen(c, .{ .auto = true })) |l| .{ .len = l } else null,
        .float => if (parseKeyword(style.Float, c)) |k| kw(k) else null,
        .clear => if (parseKeyword(style.Clear, c)) |k| kw(k) else null,
        .width, .height => if (try parseLen(c, .{ .auto = true, .negative = false, .sizing = true })) |l| .{ .len = l } else null,
        .min_width, .min_height => if (try parseLen(c, .{ .auto = true, .negative = false, .sizing = true })) |l| .{ .len = l } else null,
        .max_width, .max_height => if (try parseLen(c, .{ .none = true, .negative = false, .sizing = true })) |l| .{ .len = l } else null,
        .box_sizing => if (parseKeyword(style.BoxSizing, c)) |k| kw(k) else null,
        .margin_top, .margin_right, .margin_bottom, .margin_left => if (try parseLen(c, .{ .auto = true })) |l| .{ .len = l } else null,
        .padding_top, .padding_right, .padding_bottom, .padding_left => if (try parseLen(c, .{ .negative = false })) |l| .{ .len = l } else null,
        .border_top_width, .border_right_width, .border_bottom_width, .border_left_width, .outline_width => try parseLineWidth(c),
        .border_top_style, .border_right_style, .border_bottom_style, .border_left_style, .outline_style => blk: {
            if (id == .outline_style and c.ident("auto")) break :blk kw(style.BorderStyle.solid);
            break :blk if (parseKeyword(style.BorderStyle, c)) |k| kw(k) else null;
        },
        .border_top_left_radius, .border_top_right_radius, .border_bottom_right_radius, .border_bottom_left_radius => blk: {
            const x = (try parseLen(c, .{ .negative = false })) orelse break :blk null;
            const y = (try parseLen(c, .{ .negative = false })) orelse x;
            break :blk .{ .pair = .{ x, y } };
        },
        .background_image, .mask_image => if (c.ident("none")) Value{ .image = null } else if (try parseImage(c)) |img| .{ .image = img } else null,
        .background_repeat, .mask_repeat => parseRepeat(c),
        .background_position, .object_position, .mask_position => if (try parsePosition(c)) |p| .{ .pair = p } else null,
        .background_size, .mask_size => try parseBgSize(c),
        .background_clip, .background_origin => blk: {
            if (c.ident("border-box")) break :blk kw(style.Box.border_box);
            if (c.ident("padding-box")) break :blk kw(style.Box.padding_box);
            if (c.ident("content-box")) break :blk kw(style.Box.content_box);
            if (c.ident("text")) break :blk kw(style.Box.text);
            break :blk null;
        },
        .box_shadow => if (c.ident("none")) Value{ .shadows = null } else if (try parseShadows(c)) |s| .{ .shadows = s } else null,
        .opacity => blk: {
            const t = c.peek();
            if (t.kind == .percentage) {
                _ = c.take();
                break :blk .{ .number = @floatCast(std.math.clamp(t.number / 100, 0, 1)) };
            }
            const n = parseNumber(c) orelse break :blk null;
            break :blk .{ .number = std.math.clamp(n, 0, 1) };
        },
        .overflow_x, .overflow_y => blk: {
            if (c.ident("overlay")) break :blk kw(style.Overflow.auto);
            break :blk if (parseKeyword(style.Overflow, c)) |k| kw(k) else null;
        },
        .z_index => if (c.ident("auto")) Value{ .keyword = 0 } else if (parseInteger(c)) |n| .{ .integer = n } else null,
        .vertical_align => blk: {
            if (parseKeyword(style.VerticalAlign, c)) |k| if (k != .length) break :blk kw(k);
            const l = (try parseLen(c, .{})) orelse break :blk null;
            break :blk .{ .len = l };
        },
        .text_decoration_line => parseDecoration(c),
        .text_decoration_style => if (parseKeyword(style.DecorationStyle, c)) |k| kw(k) else blk: {
            // text-decoration-skip-ink is accepted and ignored.
            if (c.ident("auto") or c.ident("none") or c.ident("all")) break :blk kw(style.DecorationStyle.solid);
            break :blk null;
        },
        .text_decoration_thickness, .text_underline_offset => blk: {
            if (c.ident("from-font")) break :blk Value{ .len = SLen.auto };
            break :blk if (try parseLen(c, .{ .auto = true })) |l| .{ .len = l } else null;
        },
        .text_overflow => if (parseKeyword(style.TextOverflow, c)) |k| kw(k) else null,
        .flex_direction => if (parseKeyword(style.FlexDirection, c)) |k| kw(k) else null,
        .flex_wrap => if (parseKeyword(style.FlexWrap, c)) |k| kw(k) else null,
        .flex_grow, .flex_shrink => if (parseNumber(c)) |n| (if (n < 0) null else Value{ .number = n }) else null,
        .flex_basis => blk: {
            if (c.ident("content")) break :blk Value{ .len = .{ .tag = .content } };
            break :blk if (try parseLen(c, .{ .auto = true, .negative = false, .sizing = true })) |l| .{ .len = l } else null;
        },
        .order => if (parseInteger(c)) |n| .{ .integer = n } else null,
        .justify_content, .align_items, .align_self, .align_content, .justify_items, .justify_self => parseAlign(c),
        .row_gap, .column_gap => if (try parseLen(c, .{ .normal = true, .negative = false })) |l| .{ .len = l } else null,
        .grid_template_columns, .grid_template_rows => if (c.ident("none")) Value{ .tracks = null } else if (try parseTracks(c, true)) |t| .{ .tracks = t } else null,
        .grid_auto_columns, .grid_auto_rows => if (try parseTracks(c, false)) |t| .{ .tracks = t } else null,
        .grid_template_areas => if (c.ident("none")) Value{ .areas = null } else if (try parseAreas(c)) |ar| .{ .areas = ar } else null,
        .grid_auto_flow => blk: {
            var f: style.GridAutoFlow = .{};
            var any = false;
            while (true) {
                if (c.ident("row")) {
                    any = true;
                } else if (c.ident("column")) {
                    f.column = true;
                    any = true;
                } else if (c.ident("dense")) {
                    f.dense = true;
                    any = true;
                } else break;
            }
            break :blk if (any) .{ .flow = f } else null;
        },
        .grid_row_start, .grid_row_end, .grid_column_start, .grid_column_end => if (parseGridLine(c)) |l| .{ .line = l } else null,
        .object_fit => if (parseKeyword(style.ObjectFit, c)) |k| kw(k) else null,
        .aspect_ratio => blk: {
            var auto = false;
            if (c.ident("auto")) auto = true;
            var ratio: f32 = 0;
            if (parseNumber(c)) |w| {
                ratio = w;
                if (c.peek().isDelim('/')) {
                    _ = c.take();
                    const h = parseNumber(c) orelse break :blk null;
                    ratio = if (h > 0) w / h else 0;
                }
            }
            if (!auto and c.ident("auto")) auto = true;
            if (!auto and ratio == 0) break :blk null;
            break :blk .{ .pair = .{ .{ .v = ratio }, .{ .v = if (auto) 1 else 0 } } };
        },
        .content => try parseContent(c),
        .counter_reset, .counter_increment, .counter_set => if (c.ident("none")) Value{ .counters = null } else try parseCounters(c, if (id == .counter_increment) 1 else 0),
        .table_layout => if (parseKeyword(style.TableLayout, c)) |k| kw(k) else null,
        .break_before, .break_after, .break_inside => if (parseKeyword(style.Break, c)) |k| kw(k) else null,
        .column_width => if (try parseLen(c, .{ .auto = true, .percent = false, .negative = false })) |l| .{ .len = l } else null,
        .column_span => blk: {
            if (c.ident("all")) break :blk Value{ .keyword = 1 };
            if (c.ident("none")) break :blk Value{ .keyword = 0 };
            break :blk null;
        },
        .outline_offset => if (try parseLen(c, .{ .percent = false })) |l| .{ .len = l } else null,
        .unicode_bidi => if (parseKeyword(style.UnicodeBidi, c)) |k| kw(k) else null,
    };
}

fn parseLineWidth(c: *Cursor) Error!?Value {
    if (c.ident("thin")) return .{ .len = .{ .v = 1 } };
    if (c.ident("medium")) return .{ .len = .{ .v = 3 } };
    if (c.ident("thick")) return .{ .len = .{ .v = 5 } };
    const l = (try parseLen(c, .{ .percent = false, .negative = false })) orelse return null;
    return .{ .len = l };
}

fn parseFamilies(c: *Cursor) Error!?*const style.Families {
    var items: std.ArrayList(style.Families.Family) = .empty;
    while (true) {
        const t = c.peek();
        if (t.kind == .string) {
            _ = c.take();
            try items.append(c.a, .{ .name = try c.a.dupe(u8, t.text) });
        } else if (t.kind == .ident) {
            // Unquoted names: identifiers joined by single spaces.
            var name: std.ArrayList(u8) = .empty;
            var words: usize = 0;
            while (c.peek().kind == .ident) : (words += 1) {
                if (name.items.len > 0) try name.append(c.a, ' ');
                try name.appendSlice(c.a, c.take().text);
            }
            const generic = if (words == 1) genericOf(name.items) else .none;
            try items.append(c.a, .{ .name = if (generic == .none) name.items else "", .generic = generic });
        } else return null;
        if (c.peek().kind == .comma) {
            _ = c.take();
            continue;
        }
        break;
    }
    if (items.items.len == 0) return null;
    const f = try c.a.create(style.Families);
    f.* = .{ .items = items.items };
    return f;
}

fn genericOf(s: []const u8) style.Generic {
    const map = [_]struct { []const u8, style.Generic }{
        .{ "serif", .serif },             .{ "sans-serif", .sans_serif },     .{ "monospace", .monospace },
        .{ "cursive", .cursive },         .{ "fantasy", .fantasy },           .{ "system-ui", .system_ui },
        .{ "ui-serif", .ui_serif },       .{ "ui-sans-serif", .ui_sans_serif }, .{ "ui-monospace", .ui_monospace },
        .{ "ui-rounded", .ui_rounded },   .{ "math", .math },                 .{ "emoji", .emoji },
        .{ "fangsong", .fangsong },       .{ "-apple-system", .system_ui },   .{ "blinkmacsystemfont", .system_ui },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(s, m[0])) return m[1];
    return .none;
}

fn parseFontSize(c: *Cursor) Error!?Value {
    const map = [_]struct { []const u8, f32 }{
        .{ "xx-small", 9 }, .{ "x-small", 10 }, .{ "small", 13 }, .{ "medium", 16 }, .{ "large", 18 }, .{ "x-large", 24 }, .{ "xx-large", 32 }, .{ "xxx-large", 48 },
    };
    for (map) |m| if (c.ident(m[0])) return .{ .font_size_keyword = m[1] };
    if (c.ident("larger")) return .{ .len = .{ .v = 120, .unit = .percent } };
    if (c.ident("smaller")) return .{ .len = .{ .v = 1.0 / 1.2 * 100, .unit = .percent } };
    const l = (try parseLen(c, .{ .negative = false })) orelse return null;
    return .{ .len = l };
}

fn parseFontWeight(c: *Cursor) ?Value {
    if (c.ident("normal")) return .{ .number = 400 };
    if (c.ident("bold")) return .{ .number = 700 };
    if (c.ident("bolder")) return .{ .weight_relative = .bolder };
    if (c.ident("lighter")) return .{ .weight_relative = .lighter };
    const n = parseNumber(c) orelse return null;
    if (n < 1 or n > 1000) return null;
    return .{ .number = n };
}

fn parseVariations(c: *Cursor) Error!?Value {
    if (c.ident("normal")) return .{ .variations = null };
    var list: std.ArrayList([2]u32) = .empty;
    while (true) {
        const t = c.take();
        if (t.kind != .string or t.text.len != 4) return null;
        const v = parseNumber(c) orelse return null;
        try list.append(c.a, .{ std.mem.readInt(u32, t.text[0..4], .big), @bitCast(v) });
        if (c.peek().kind != .comma) break;
        _ = c.take();
    }
    const p = try c.a.create([]const [2]u32);
    p.* = list.items;
    return .{ .variations = p };
}

fn parseListStyleType(c: *Cursor) ?Value {
    const t = c.peek();
    if (t.kind == .string) {
        _ = c.take();
        return .{ .list_style_string = c.a.dupe(u8, t.text) catch return null };
    }
    if (parseKeyword(style.ListStyleType, c)) |k| return kw(k);
    if (c.ident("lower-latin")) return kw(style.ListStyleType.lower_alpha);
    if (c.ident("upper-latin")) return kw(style.ListStyleType.upper_alpha);
    // Other counter styles fall back to decimal (CSS Counter Styles).
    if (t.kind == .ident) {
        _ = c.take();
        return kw(style.ListStyleType.decimal);
    }
    return null;
}

pub fn parseDisplay(c: *Cursor) ?Value {
    const D = style.Display;
    var d: D = .{ .outer = .@"inline", .inner = .flow };
    var outer: ?D.Outer = null;
    var inner: ?D.Inner = null;
    var list_item = false;
    var any = false;
    while (c.peek().kind == .ident) {
        const t = c.take();
        any = true;
        const eq = std.ascii.eqlIgnoreCase;
        const s = t.text;
        if (eq(s, "none")) return .{ .display = D.none };
        if (eq(s, "contents")) return .{ .display = .{ .outer = .contents } };
        if (eq(s, "block")) {
            outer = .block;
        } else if (eq(s, "inline")) {
            outer = .@"inline";
        } else if (eq(s, "run-in")) {
            outer = .block;
        } else if (eq(s, "flow")) {
            inner = .flow;
        } else if (eq(s, "flow-root")) {
            inner = .flow_root;
        } else if (eq(s, "flex") or eq(s, "-webkit-flex") or eq(s, "-webkit-box") or eq(s, "-ms-flexbox")) {
            inner = .flex;
        } else if (eq(s, "grid") or eq(s, "-ms-grid")) {
            inner = .grid;
        } else if (eq(s, "table")) {
            inner = .table;
        } else if (eq(s, "list-item")) {
            list_item = true;
        } else if (eq(s, "inline-block")) {
            outer = .@"inline";
            inner = .flow_root;
        } else if (eq(s, "inline-flex") or eq(s, "-webkit-inline-flex") or eq(s, "-webkit-inline-box")) {
            outer = .@"inline";
            inner = .flex;
        } else if (eq(s, "inline-grid")) {
            outer = .@"inline";
            inner = .grid;
        } else if (eq(s, "inline-table")) {
            outer = .@"inline";
            inner = .table;
        } else if (eq(s, "table-row-group")) {
            inner = .table_row_group;
        } else if (eq(s, "table-header-group")) {
            inner = .table_header_group;
        } else if (eq(s, "table-footer-group")) {
            inner = .table_footer_group;
        } else if (eq(s, "table-row")) {
            inner = .table_row;
        } else if (eq(s, "table-cell")) {
            inner = .table_cell;
        } else if (eq(s, "table-column-group")) {
            inner = .table_column_group;
        } else if (eq(s, "table-column")) {
            inner = .table_column;
        } else if (eq(s, "table-caption")) {
            inner = .table_caption;
        } else if (eq(s, "ruby") or eq(s, "ruby-base") or eq(s, "ruby-text")) {
            outer = .@"inline";
        } else return null;
    }
    if (!any) return null;
    if (inner) |i| {
        d.inner = i;
        // A lone inner type is block-level (flex, grid, table, flow-root).
        d.outer = outer orelse .block;
    } else d.outer = outer orelse .block;
    if (list_item) {
        d.list_item = true;
        if (outer == null) d.outer = .block;
    }
    return .{ .display = d };
}

fn parseRepeat(c: *Cursor) ?Value {
    const R = style.Repeat;
    if (c.ident("repeat-x")) return kw(R.repeat_x);
    if (c.ident("repeat-y")) return kw(R.repeat_y);
    const first = parseKeyword(R, c) orelse return null;
    const second = parseKeyword(R, c) orelse first;
    if (first == .repeat and second == .no_repeat) return kw(R.repeat_x);
    if (first == .no_repeat and second == .repeat) return kw(R.repeat_y);
    return kw(first);
}

fn parsePosition(c: *Cursor) Error!?[2]SLen {
    var x: ?SLen = null;
    var y: ?SLen = null;
    var n: usize = 0;
    while (n < 4) : (n += 1) {
        if (c.ident("left")) {
            x = .{ .v = 0, .unit = .percent };
        } else if (c.ident("right")) {
            x = .{ .v = 100, .unit = .percent };
        } else if (c.ident("top")) {
            y = .{ .v = 0, .unit = .percent };
        } else if (c.ident("bottom")) {
            y = .{ .v = 100, .unit = .percent };
        } else if (c.ident("center")) {
            if (x == null) x = .{ .v = 50, .unit = .percent } else y = .{ .v = 50, .unit = .percent };
        } else if (try parseLen(c, .{})) |l| {
            if (x == null) x = l else if (y == null) y = l else return null;
        } else break;
    }
    if (n == 0) return null;
    return .{ x orelse .{ .v = 50, .unit = .percent }, y orelse .{ .v = 50, .unit = .percent } };
}

fn parseBgSize(c: *Cursor) Error!?Value {
    if (c.ident("cover")) return .{ .bg_size = .{ .kind = .cover, .w = SLen.auto, .h = SLen.auto } };
    if (c.ident("contain")) return .{ .bg_size = .{ .kind = .contain, .w = SLen.auto, .h = SLen.auto } };
    const w = (try parseLen(c, .{ .auto = true, .negative = false })) orelse return null;
    const h = (try parseLen(c, .{ .auto = true, .negative = false })) orelse SLen.auto;
    return .{ .bg_size = .{ .kind = .explicit, .w = w, .h = h } };
}

const parse_ctx: values.Context = .{};

fn parseShadows(c: *Cursor) Error!?*const style.Shadows {
    var items: std.ArrayList(style.Shadow) = .empty;
    while (true) {
        var s: style.Shadow = .{};
        var lens: [4]f32 = .{ 0, 0, 0, 0 };
        var nlen: usize = 0;
        var have_color = false;
        while (!c.done() and c.peek().kind != .comma) {
            if (c.ident("inset")) {
                s.inset = true;
            } else if (try parseLen(c, .{ .percent = false })) |l| {
                if (nlen >= 4) return null;
                lens[nlen] = l.px(&parse_ctx);
                nlen += 1;
            } else if (!have_color and blk: {
                const col = parseColor(c) orelse break :blk false;
                s.color = col;
                break :blk true;
            }) {
                have_color = true;
            } else return null;
        }
        if (nlen < 2) return null;
        s.x = lens[0];
        s.y = lens[1];
        s.blur = @max(0, lens[2]);
        s.spread = lens[3];
        try items.append(c.a, s);
        if (c.peek().kind == .comma) {
            _ = c.take();
            continue;
        }
        break;
    }
    const out = try c.a.create(style.Shadows);
    out.* = .{ .items = items.items };
    return out;
}

pub fn parseImage(c: *Cursor) Error!?*const style.Image {
    const t = c.peek();
    if (t.kind == .url) {
        _ = c.take();
        const img = try c.a.create(style.Image);
        img.* = .{ .url = try c.a.dupe(u8, t.text) };
        return img;
    }
    if (t.kind != .function) return null;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(t.text, "url")) {
        _ = c.take();
        const args = c.args();
        var s = c.sub(args);
        const st = s.take();
        if (st.kind != .string) return null;
        const img = try c.a.create(style.Image);
        img.* = .{ .url = try c.a.dupe(u8, st.text) };
        return img;
    }
    var name = t.text;
    if (std.mem.startsWith(u8, name, "-webkit-") or std.mem.startsWith(u8, name, "-moz-")) name = name[std.mem.indexOfScalarPos(u8, name, 1, '-').? + 1 ..];
    const repeating = std.ascii.startsWithIgnoreCase(name, "repeating-");
    if (repeating) name = name[10..];
    const kind: @TypeOf(@as(style.Gradient, .{ .stops = &.{} }).kind) = if (eq(name, "linear-gradient")) .linear else if (eq(name, "radial-gradient")) .radial else if (eq(name, "conic-gradient")) .conic else return null;
    _ = c.take();
    const args = c.args();
    var s = c.sub(args);
    var g: style.Gradient = .{ .kind = kind, .repeating = repeating, .stops = &.{} };
    // The gradient line.
    switch (kind) {
        .linear => {
            if (color_mod.angle(s.peek())) |deg| {
                _ = s.take();
                g.angle = @floatCast(deg);
                if (s.take().kind != .comma) return null;
            } else if (s.ident("to")) {
                var corner: [2]i8 = .{ 0, 0 };
                while (s.peek().kind == .ident) {
                    if (s.ident("left")) corner[0] = -1 else if (s.ident("right")) corner[0] = 1 else if (s.ident("top")) corner[1] = -1 else if (s.ident("bottom")) corner[1] = 1 else return null;
                }
                if (corner[0] != 0 and corner[1] != 0) {
                    g.corner = corner;
                } else g.angle = if (corner[0] == -1) 270 else if (corner[0] == 1) 90 else if (corner[1] == -1) 0 else 180;
                if (s.take().kind != .comma) return null;
            }
        },
        .radial => {
            var any = false;
            while (s.peek().kind != .comma and !s.done()) {
                any = true;
                if (s.ident("circle")) {
                    g.circle = true;
                } else if (s.ident("ellipse")) {
                    g.circle = false;
                } else if (s.ident("closest-side")) {
                    g.extent = .closest_side;
                } else if (s.ident("closest-corner")) {
                    g.extent = .closest_corner;
                } else if (s.ident("farthest-side")) {
                    g.extent = .farthest_side;
                } else if (s.ident("farthest-corner")) {
                    g.extent = .farthest_corner;
                } else if (s.ident("at")) {
                    const p = (try parsePosition(&s)) orelse return null;
                    g.cx = try p[0].compute(c.a, &parse_ctx);
                    g.cy = try p[1].compute(c.a, &parse_ctx);
                } else if (try parseLen(&s, .{ .negative = false })) |l| {
                    g.extent = .explicit;
                    g.rx = try l.compute(c.a, &parse_ctx);
                    g.ry = if (try parseLen(&s, .{ .negative = false })) |l2| try l2.compute(c.a, &parse_ctx) else blk: {
                        g.circle = true;
                        break :blk g.rx;
                    };
                } else {
                    any = false;
                    break;
                }
            }
            if (any) {
                if (s.take().kind != .comma) return null;
            }
        },
        .conic => {
            if (s.ident("from")) {
                const deg = color_mod.angle(s.take()) orelse return null;
                g.angle = @floatCast(deg);
            }
            if (s.ident("at")) {
                const p = (try parsePosition(&s)) orelse return null;
                g.cx = try p[0].compute(c.a, &parse_ctx);
                g.cy = try p[1].compute(c.a, &parse_ctx);
            }
            if (s.peek().kind == .comma) _ = s.take() else if (g.angle != 180) return null;
            if (kind == .conic and g.angle == 180) g.angle = 0;
        },
    }
    var stops: std.ArrayList(style.Stop) = .empty;
    while (!s.done()) {
        const col = parseColor(&s) orelse {
            // A color hint (a lone position) is dropped.
            if ((try parseLen(&s, .{})) != null or color_mod.angle(s.peek()) != null) {
                if (s.peek().kind == .comma) _ = s.take();
                continue;
            }
            return null;
        };
        var stop: style.Stop = .{ .color = col };
        if (kind == .conic) {
            if (color_mod.angle(s.peek())) |deg| {
                _ = s.take();
                stop.pos = .{ .pct = @floatCast(deg / 360) };
            } else if (try parseLen(&s, .{})) |l| stop.pos = try l.compute(c.a, &parse_ctx);
        } else if (try parseLen(&s, .{})) |l| stop.pos = try l.compute(c.a, &parse_ctx);
        try stops.append(c.a, stop);
        // A second position repeats the stop.
        if (try parseLen(&s, .{})) |l2| try stops.append(c.a, .{ .color = col, .pos = try l2.compute(c.a, &parse_ctx) });
        if (s.peek().kind == .comma) _ = s.take() else break;
    }
    if (!s.done() or stops.items.len == 0) return null;
    g.stops = stops.items;
    const img = try c.a.create(style.Image);
    img.* = .{ .gradient = g };
    return img;
}

fn parseDecoration(c: *Cursor) ?Value {
    var d: style.Decoration = .{};
    if (c.ident("none")) return .{ .decoration = d };
    var any = false;
    while (true) {
        if (c.ident("underline")) {
            d.underline = true;
        } else if (c.ident("overline")) {
            d.overline = true;
        } else if (c.ident("line-through")) {
            d.line_through = true;
        } else if (c.ident("blink")) {
            d.blink = true;
        } else break;
        any = true;
    }
    return if (any) .{ .decoration = d } else null;
}

fn parseAlign(c: *Cursor) ?Value {
    _ = c.ident("safe");
    _ = c.ident("unsafe");
    if (c.ident("first")) {
        if (!c.ident("baseline")) return null;
        return kw(style.Align.baseline);
    }
    if (c.ident("last")) {
        if (!c.ident("baseline")) return null;
        return kw(style.Align.last_baseline);
    }
    const k = parseKeyword(style.Align, c) orelse return null;
    // "legacy center" and the like.
    if (k == .legacy) _ = parseKeyword(style.Align, c);
    return kw(k);
}

fn parseBreadth(c: *Cursor, allow_fr: bool) Error!?style.Breadth {
    const t = c.peek();
    if (allow_fr and t.kind == .dimension and std.ascii.eqlIgnoreCase(t.text, "fr") and t.number >= 0) {
        _ = c.take();
        return .{ .fr = @floatCast(t.number) };
    }
    if (c.ident("auto")) return .auto;
    if (c.ident("min-content")) return .min_content;
    if (c.ident("max-content")) return .max_content;
    const l = (try parseLen(c, .{ .negative = false })) orelse return null;
    return .{ .len = try l.compute(c.a, &parse_ctx) };
}

fn parseTrackSize(c: *Cursor) Error!?style.TrackSize {
    const t = c.peek();
    if (t.isFunction("minmax")) {
        _ = c.take();
        var s = c.sub(c.args());
        const lo = (try parseBreadth(&s, false)) orelse return null;
        if (s.take().kind != .comma) return null;
        const hi = (try parseBreadth(&s, true)) orelse return null;
        if (!s.done()) return null;
        return .{ .min = lo, .max = hi };
    }
    if (t.isFunction("fit-content")) {
        _ = c.take();
        var s = c.sub(c.args());
        const l = (try parseLen(&s, .{ .negative = false })) orelse return null;
        return .{ .min = .auto, .max = .max_content, .fit_content = try l.compute(c.a, &parse_ctx) };
    }
    const b = (try parseBreadth(c, true)) orelse return null;
    return style.TrackSize.single(b);
}

fn parseLineNames(c: *Cursor) Error!?[]const []const u8 {
    if (c.peek().kind != .lbracket) return null;
    _ = c.take();
    var names: std.ArrayList([]const u8) = .empty;
    while (true) {
        const t = c.take();
        if (t.kind == .rbracket) break;
        if (t.kind != .ident) return null;
        try names.append(c.a, try c.a.dupe(u8, t.text));
    }
    return names.items;
}

fn parseTracks(c: *Cursor, template: bool) Error!?*const style.Tracks {
    var items: std.ArrayList(style.Track) = .empty;
    while (!c.done()) {
        if (template) if (try parseLineNames(c)) |names| {
            try items.append(c.a, .{ .names = names });
            continue;
        };
        const t = c.peek();
        if (template and t.isFunction("repeat")) {
            _ = c.take();
            var s = c.sub(c.args());
            var count_: u32 = 0;
            var auto: @TypeOf(@as(style.Track, .{ .names = &.{} }).names.len) = 0;
            _ = &auto;
            var mode: enum { none, fill, fit } = .none;
            if (s.ident("auto-fill")) {
                mode = .fill;
            } else if (s.ident("auto-fit")) {
                mode = .fit;
            } else {
                const n = parseInteger(&s) orelse return null;
                if (n < 1) return null;
                count_ = @intCast(@min(n, 10000));
            }
            if (s.take().kind != .comma) return null;
            var sizes: std.ArrayList(style.TrackSize) = .empty;
            while (!s.done()) {
                if ((try parseLineNames(&s)) != null) continue;
                try sizes.append(c.a, (try parseTrackSize(&s)) orelse return null);
            }
            if (sizes.items.len == 0) return null;
            try items.append(c.a, .{ .repeat = .{ .count = count_, .auto = switch (mode) {
                .none => .none,
                .fill => .fill,
                .fit => .fit,
            }, .sizes = sizes.items } });
            continue;
        }
        try items.append(c.a, .{ .size = (try parseTrackSize(c)) orelse return null });
    }
    if (items.items.len == 0) return null;
    const out = try c.a.create(style.Tracks);
    out.* = .{ .items = items.items };
    return out;
}

fn parseAreas(c: *Cursor) Error!?*const style.Areas {
    var cells: std.ArrayList([]const u8) = .empty;
    var rows: u32 = 0;
    var columns: u32 = 0;
    while (c.peek().kind == .string) {
        const row = c.take().text;
        var n: u32 = 0;
        var it = std.mem.tokenizeAny(u8, row, " \t\n");
        while (it.next()) |w| {
            // A run of dots is one null cell.
            const all_dots = std.mem.indexOfNone(u8, w, ".") == null;
            try cells.append(c.a, if (all_dots) "" else try c.a.dupe(u8, w));
            n += 1;
        }
        if (rows == 0) columns = n else if (n != columns) return null;
        rows += 1;
    }
    if (rows == 0 or columns == 0) return null;
    const out = try c.a.create(style.Areas);
    out.* = .{ .rows = rows, .columns = columns, .cells = cells.items };
    return out;
}

fn parseGridLine(c: *Cursor) ?style.GridLine {
    if (c.ident("auto")) return .{};
    var l: style.GridLine = .{ .kind = .line };
    var any = false;
    while (!c.done() and c.peek().kind != .delim) {
        if (c.ident("span")) {
            l.kind = .span;
            if (l.n == 0) l.n = 1;
        } else if (parseInteger(c)) |n| {
            if (n == 0) return null;
            l.n = n;
        } else if (c.peek().kind == .ident) {
            l.name = c.a.dupe(u8, c.take().text) catch return null;
            if (l.n == 0) l.n = 1;
        } else break;
        any = true;
    }
    if (!any) return null;
    return l;
}

fn parseContent(c: *Cursor) Error!?Value {
    if (c.ident("normal")) return .{ .content = null };
    if (c.ident("none")) return .content_none;
    var items: std.ArrayList(style.ContentItem) = .empty;
    while (!c.done()) {
        const t = c.take();
        switch (t.kind) {
            .string => try items.append(c.a, .{ .string = try c.a.dupe(u8, t.text) }),
            .url => try items.append(c.a, .{ .url = try c.a.dupe(u8, t.text) }),
            .ident => {
                if (t.isIdent("open-quote")) try items.append(c.a, .open_quote) else if (t.isIdent("close-quote")) try items.append(c.a, .close_quote) else if (t.isIdent("no-open-quote")) try items.append(c.a, .no_open_quote) else if (t.isIdent("no-close-quote")) try items.append(c.a, .no_close_quote) else return null;
            },
            .function => {
                var s = c.sub(c.args());
                if (t.isFunction("attr")) {
                    const n = s.take();
                    if (n.kind != .ident) return null;
                    try items.append(c.a, .{ .attr = try std.ascii.allocLowerString(c.a, n.text) });
                } else if (t.isFunction("counter") or t.isFunction("counters")) {
                    const n = s.take();
                    if (n.kind != .ident) return null;
                    var sep: []const u8 = "";
                    if (t.isFunction("counters")) {
                        if (s.take().kind != .comma) return null;
                        const st = s.take();
                        if (st.kind != .string) return null;
                        sep = try c.a.dupe(u8, st.text);
                    }
                    var ls: style.ListStyleType = .decimal;
                    if (s.peek().kind == .comma) {
                        _ = s.take();
                        if (parseListStyleType(&s)) |v| ls = if (v == .keyword) @enumFromInt(v.keyword) else .decimal;
                    }
                    const name = try c.a.dupe(u8, n.text);
                    if (t.isFunction("counter")) try items.append(c.a, .{ .counter = .{ .name = name, .style = ls } }) else try items.append(c.a, .{ .counters = .{ .name = name, .sep = sep, .style = ls } });
                } else if (t.isFunction("url")) {
                    const st = s.take();
                    if (st.kind != .string) return null;
                    try items.append(c.a, .{ .url = try c.a.dupe(u8, st.text) });
                } else return null;
            },
            .delim => if (t.delim == '/') {
                // Alternative text after a slash is dropped.
                break;
            } else return null,
            else => return null,
        }
    }
    if (items.items.len == 0) return null;
    const out = try c.a.create(style.Content);
    out.* = .{ .items = items.items };
    return .{ .content = out };
}

fn parseCounters(c: *Cursor, default: i32) Error!?Value {
    var items: std.ArrayList(style.Counter) = .empty;
    while (!c.done()) {
        const n = c.take();
        if (n.kind != .ident) return null;
        const v = parseInteger(c) orelse default;
        try items.append(c.a, .{ .name = try c.a.dupe(u8, n.text), .value = v });
    }
    if (items.items.len == 0) return null;
    const out = try c.a.create(style.Counters);
    out.* = .{ .items = items.items };
    return .{ .counters = out };
}

fn add(a: Allocator, out: *std.ArrayList(Declaration), id: Id, important: bool, v: Value) Error!void {
    try out.append(a, .{ .id = id, .important = important, .value = v });
}

/// Box shorthands: one to four values, top right bottom left.
fn four(c: *Cursor, ids: []const Id, important: bool, out: *std.ArrayList(Declaration), comptime one: fn (*Cursor, Id) Error!?Value) Error!bool {
    var vals: [4]Value = undefined;
    var n: usize = 0;
    while (n < 4 and !c.done()) : (n += 1) vals[n] = (try one(c, ids[0])) orelse return false;
    if (n == 0) return false;
    const map: [4]usize = switch (n) {
        1 => .{ 0, 0, 0, 0 },
        2 => .{ 0, 1, 0, 1 },
        3 => .{ 0, 1, 2, 1 },
        else => .{ 0, 1, 2, 3 },
    };
    for (ids, 0..) |id, i| try add(c.a, out, id, important, vals[map[i]]);
    return true;
}

fn two(c: *Cursor, ids: []const Id, important: bool, out: *std.ArrayList(Declaration), comptime one: fn (*Cursor, Id) Error!?Value) Error!bool {
    const first = (try one(c, ids[0])) orelse return false;
    const second = if (!c.done()) ((try one(c, ids[1])) orelse return false) else first;
    try add(c.a, out, ids[0], important, first);
    try add(c.a, out, ids[1], important, second);
    return true;
}

fn borderSide(c: *Cursor, w: Id, s: Id, col: Id, important: bool, out: *std.ArrayList(Declaration)) Error!bool {
    var width: ?Value = null;
    var st: ?Value = null;
    var color: ?Value = null;
    var n: usize = 0;
    while (!c.done() and n < 3) : (n += 1) {
        if (width == null) if (try parseLineWidth(c)) |v| {
            width = v;
            continue;
        };
        if (st == null) if (parseKeyword(style.BorderStyle, c)) |k| {
            st = kw(k);
            continue;
        };
        if (color == null) if (parseColor(c)) |cc| {
            color = .{ .color = cc };
            continue;
        };
        return false;
    }
    if (n == 0) return false;
    try add(c.a, out, w, important, width orelse Value{ .len = .{ .v = 3 } });
    try add(c.a, out, s, important, st orelse kw(style.BorderStyle.none));
    try add(c.a, out, col, important, color orelse Value{ .color = Color.current });
    return true;
}

fn parseShorthand(c: *Cursor, s: Shorthand, important: bool, out: *std.ArrayList(Declaration)) Error!bool {
    const lh = s.longhands();
    switch (s) {
        .margin, .padding, .border_width, .border_style, .border_color, .inset => return four(c, lh, important, out, parseLonghand),
        .margin_block, .margin_inline, .padding_block, .padding_inline => return two(c, lh, important, out, parseLonghand),
        .border_top => return borderSide(c, .border_top_width, .border_top_style, .border_top_color, important, out),
        .border_right => return borderSide(c, .border_right_width, .border_right_style, .border_right_color, important, out),
        .border_bottom => return borderSide(c, .border_bottom_width, .border_bottom_style, .border_bottom_color, important, out),
        .border_left => return borderSide(c, .border_left_width, .border_left_style, .border_left_color, important, out),
        .outline => return borderSide(c, .outline_width, .outline_style, .outline_color, important, out),
        .border, .border_block, .border_inline => {
            const mark = out.items.len;
            if (!try borderSide(c, .border_top_width, .border_top_style, .border_top_color, important, out)) return false;
            const w = out.items[mark].value;
            const st = out.items[mark + 1].value;
            const col = out.items[mark + 2].value;
            out.shrinkRetainingCapacity(mark);
            var i: usize = 0;
            while (i < lh.len) : (i += 1) {
                const id = lh[i];
                const name = @tagName(id);
                const v = if (std.mem.endsWith(u8, name, "_width")) w else if (std.mem.endsWith(u8, name, "_style")) st else col;
                try add(c.a, out, id, important, v);
            }
            return true;
        },
        .border_radius => {
            var xs: [4]SLen = undefined;
            var nx: usize = 0;
            while (nx < 4) : (nx += 1) xs[nx] = (try parseLen(c, .{ .negative = false })) orelse break;
            if (nx == 0) return false;
            var ys: [4]SLen = undefined;
            var ny: usize = 0;
            if (c.peek().isDelim('/')) {
                _ = c.take();
                while (ny < 4) : (ny += 1) ys[ny] = (try parseLen(c, .{ .negative = false })) orelse break;
                if (ny == 0) return false;
            }
            const expand = struct {
                fn f(v: []const SLen, n: usize) [4]SLen {
                    return switch (n) {
                        1 => .{ v[0], v[0], v[0], v[0] },
                        2 => .{ v[0], v[1], v[0], v[1] },
                        3 => .{ v[0], v[1], v[2], v[1] },
                        else => .{ v[0], v[1], v[2], v[3] },
                    };
                }
            }.f;
            const x4 = expand(&xs, nx);
            const y4 = if (ny > 0) expand(&ys, ny) else x4;
            for (lh, 0..) |id, i| try add(c.a, out, id, important, .{ .pair = .{ x4[i], y4[i] } });
            return true;
        },
        .background => {
            var color: ?Color = null;
            var image: ?*const style.Image = null;
            var have_image = false;
            var repeat: ?Value = null;
            var pos: ?[2]SLen = null;
            var size: ?Value = null;
            var boxes: [2]?Value = .{ null, null };
            var nbox: usize = 0;
            var layers: usize = 0;
            while (!c.done()) {
                if (c.peek().kind == .comma) {
                    // Multiple layers: the last one's color, the first image.
                    _ = c.take();
                    layers += 1;
                    continue;
                }
                if (!have_image) {
                    if (c.ident("none")) {
                        have_image = true;
                        continue;
                    }
                    if (try parseImage(c)) |img| {
                        if (layers == 0) image = img;
                        have_image = layers == 0;
                        continue;
                    }
                } else if (layers > 0) if (try parseImage(c)) |_| continue;
                if (pos == null) if (try parsePosition(c)) |p| {
                    pos = p;
                    if (c.peek().isDelim('/')) {
                        _ = c.take();
                        size = (try parseBgSize(c)) orelse return false;
                    }
                    continue;
                };
                if (repeat == null) if (parseRepeat(c)) |r| {
                    repeat = r;
                    continue;
                };
                if (c.ident("scroll") or c.ident("fixed") or c.ident("local")) continue;
                if (nbox < 2) {
                    const save = c.i;
                    if (parseLonghand(c, .background_clip) catch null) |b| {
                        boxes[nbox] = b;
                        nbox += 1;
                        continue;
                    }
                    c.i = save;
                }
                if (color == null) if (parseColor(c)) |col| {
                    color = col;
                    continue;
                };
                return false;
            }
            try add(c.a, out, .background_color, important, .{ .color = color orelse Color.transparent });
            try add(c.a, out, .background_image, important, .{ .image = image });
            try add(c.a, out, .background_repeat, important, repeat orelse kw(style.Repeat.repeat));
            try add(c.a, out, .background_position, important, .{ .pair = pos orelse .{ SLen.zero, SLen.zero } });
            try add(c.a, out, .background_size, important, size orelse Value{ .bg_size = .{ .kind = .explicit, .w = SLen.auto, .h = SLen.auto } });
            try add(c.a, out, .background_origin, important, boxes[0] orelse kw(style.Box.padding_box));
            try add(c.a, out, .background_clip, important, boxes[1] orelse boxes[0] orelse kw(style.Box.border_box));
            return true;
        },
        .mask => {
            // One layer (more are dropped): an image, its position and
            // size, its repeat; mode, composite, and box keywords pass.
            var image: ?*const style.Image = null;
            var have_image = false;
            var repeat: ?Value = null;
            var pos: ?[2]SLen = null;
            var size: ?Value = null;
            while (!c.done()) {
                if (c.peek().kind == .comma) break;
                if (!have_image) {
                    if (c.ident("none")) {
                        have_image = true;
                        continue;
                    }
                    if (try parseImage(c)) |img| {
                        image = img;
                        have_image = true;
                        continue;
                    }
                }
                if (pos == null) if (try parsePosition(c)) |p| {
                    pos = p;
                    if (c.peek().isDelim('/')) {
                        _ = c.take();
                        size = (try parseBgSize(c)) orelse return false;
                    }
                    continue;
                };
                if (repeat == null) if (parseRepeat(c)) |r| {
                    repeat = r;
                    continue;
                };
                const passes = [_][]const u8{ "alpha", "luminance", "match-source", "add", "subtract", "intersect", "exclude", "border-box", "padding-box", "content-box", "margin-box", "fill-box", "stroke-box", "view-box", "no-clip" };
                const skipped = for (passes) |k| {
                    if (c.ident(k)) break true;
                } else false;
                if (skipped) continue;
                return false;
            }
            try add(c.a, out, .mask_image, important, .{ .image = image });
            try add(c.a, out, .mask_repeat, important, repeat orelse kw(style.Repeat.repeat));
            try add(c.a, out, .mask_position, important, .{ .pair = pos orelse .{ SLen.zero, SLen.zero } });
            try add(c.a, out, .mask_size, important, size orelse Value{ .bg_size = .{ .kind = .explicit, .w = SLen.auto, .h = SLen.auto } });
            return true;
        },
        .font => {
            var st: ?Value = null;
            var variant: ?Value = null;
            var weight: ?Value = null;
            var stretch: ?Value = null;
            // System fonts.
            const t0 = c.peek();
            if (t0.kind == .ident and c.t.len == 1) {
                const sys = [_][]const u8{ "caption", "icon", "menu", "message-box", "small-caption", "status-bar" };
                for (sys) |n| if (t0.isIdent(n)) {
                    _ = c.take();
                    try add(c.a, out, .font_family, important, .{ .families = try systemFamily(c.a) });
                    return true;
                };
            }
            var n: usize = 0;
            while (n < 4) : (n += 1) {
                if (c.ident("normal")) continue;
                if (st == null) if (parseKeyword(style.FontStyle, c)) |k| {
                    st = kw(k);
                    continue;
                };
                if (variant == null and c.ident("small-caps")) {
                    variant = kw(style.FontVariantCaps.small_caps);
                    continue;
                }
                if (weight == null) {
                    const t = c.peek();
                    if (t.kind == .number or t.isIdent("bold") or t.isIdent("bolder") or t.isIdent("lighter")) {
                        weight = parseFontWeight(c) orelse return false;
                        continue;
                    }
                }
                if (stretch == null) if (try parseLonghandOpt(c, .font_stretch)) |v| {
                    stretch = v;
                    continue;
                };
                break;
            }
            const size = (try parseFontSize(c)) orelse return false;
            var lh_v: Value = .{ .line_height = .{ .kind = .normal } };
            if (c.peek().isDelim('/')) {
                _ = c.take();
                lh_v = (try parseLonghand(c, .line_height)) orelse return false;
            }
            const fam = (try parseFamilies(c)) orelse return false;
            try add(c.a, out, .font_style, important, st orelse kw(style.FontStyle.normal));
            try add(c.a, out, .font_variant_caps, important, variant orelse kw(style.FontVariantCaps.normal));
            try add(c.a, out, .font_weight, important, weight orelse Value{ .number = 400 });
            try add(c.a, out, .font_stretch, important, stretch orelse Value{ .number = 100 });
            try add(c.a, out, .font_size, important, size);
            try add(c.a, out, .line_height, important, lh_v);
            try add(c.a, out, .font_family, important, .{ .families = fam });
            return true;
        },
        .flex => {
            if (c.ident("none")) {
                try add(c.a, out, .flex_grow, important, .{ .number = 0 });
                try add(c.a, out, .flex_shrink, important, .{ .number = 0 });
                try add(c.a, out, .flex_basis, important, .{ .len = SLen.auto });
                return true;
            }
            if (c.ident("auto")) {
                try add(c.a, out, .flex_grow, important, .{ .number = 1 });
                try add(c.a, out, .flex_shrink, important, .{ .number = 1 });
                try add(c.a, out, .flex_basis, important, .{ .len = SLen.auto });
                return true;
            }
            var grow: ?f32 = null;
            var shrink: ?f32 = null;
            var basis: ?Value = null;
            while (!c.done()) {
                const t = c.peek();
                if (t.kind == .number and grow == null) {
                    grow = parseNumber(c);
                    if (c.peek().kind == .number) shrink = parseNumber(c);
                    continue;
                }
                if (basis == null) if (try parseLonghandOpt(c, .flex_basis)) |b| {
                    basis = b;
                    continue;
                };
                return false;
            }
            if (grow == null and basis == null) return false;
            try add(c.a, out, .flex_grow, important, .{ .number = grow orelse 1 });
            try add(c.a, out, .flex_shrink, important, .{ .number = shrink orelse 1 });
            try add(c.a, out, .flex_basis, important, basis orelse Value{ .len = .{ .v = 0, .unit = .percent } });
            return true;
        },
        .flex_flow => {
            var dir: ?Value = null;
            var wrap: ?Value = null;
            while (!c.done()) {
                if (dir == null) if (parseKeyword(style.FlexDirection, c)) |k| {
                    dir = kw(k);
                    continue;
                };
                if (wrap == null) if (parseKeyword(style.FlexWrap, c)) |k| {
                    wrap = kw(k);
                    continue;
                };
                return false;
            }
            if (dir == null and wrap == null) return false;
            try add(c.a, out, .flex_direction, important, dir orelse kw(style.FlexDirection.row));
            try add(c.a, out, .flex_wrap, important, wrap orelse kw(style.FlexWrap.nowrap));
            return true;
        },
        .gap, .place_items, .place_content, .place_self => return two(c, lh, important, out, parseLonghand),
        .overflow => return two(c, lh, important, out, parseLonghand),
        .grid_row, .grid_column => {
            const a = parseGridLine(c) orelse return false;
            var b: style.GridLine = if (a.name.len > 0 and a.kind == .line) a else .{};
            if (c.peek().isDelim('/')) {
                _ = c.take();
                b = parseGridLine(c) orelse return false;
            }
            try add(c.a, out, lh[0], important, .{ .line = a });
            try add(c.a, out, lh[1], important, .{ .line = b });
            return true;
        },
        .grid_area => {
            var lines: [4]style.GridLine = .{ .{}, .{}, .{}, .{} };
            var n: usize = 0;
            while (n < 4) {
                lines[n] = parseGridLine(c) orelse return false;
                n += 1;
                if (!c.peek().isDelim('/')) break;
                _ = c.take();
            }
            // Missing lines copy a named first line, else auto.
            const named = lines[0].name.len > 0 and lines[0].kind == .line;
            if (n < 2) lines[1] = if (named) lines[0] else .{};
            if (n < 3) lines[2] = if (named) lines[0] else .{};
            if (n < 4) lines[3] = if (lines[1].name.len > 0 and lines[1].kind == .line) lines[1] else .{};
            for (lh, 0..) |id, i| try add(c.a, out, id, important, .{ .line = lines[i] });
            return true;
        },
        .grid_template => {
            if (c.ident("none")) {
                for (lh) |id| try add(c.a, out, id, important, if (id == .grid_template_areas) Value{ .areas = null } else Value{ .tracks = null });
                return true;
            }
            // rows / columns (areas form not supported beyond strings).
            const save = c.i;
            if (c.peek().kind == .string) {
                const areas = (try parseAreas(c)) orelse return false;
                var cols: ?*const style.Tracks = null;
                if (c.peek().isDelim('/')) {
                    _ = c.take();
                    cols = (try parseTracks(c, true)) orelse return false;
                }
                try add(c.a, out, .grid_template_rows, important, .{ .tracks = null });
                try add(c.a, out, .grid_template_columns, important, .{ .tracks = cols });
                try add(c.a, out, .grid_template_areas, important, .{ .areas = areas });
                return true;
            }
            c.i = save;
            var rows_toks: []const Token = c.t[c.i..];
            var slash: ?usize = null;
            for (c.t[c.i..], c.i..) |t, i| if (t.isDelim('/')) {
                slash = i;
                break;
            };
            const sl = slash orelse return false;
            rows_toks = c.t[c.i..sl];
            var rc = c.sub(rows_toks);
            var cc = c.sub(c.t[sl + 1 ..]);
            const rows = (try parseTracks(&rc, true)) orelse return false;
            const cols = (try parseTracks(&cc, true)) orelse return false;
            c.i = c.t.len;
            try add(c.a, out, .grid_template_rows, important, .{ .tracks = rows });
            try add(c.a, out, .grid_template_columns, important, .{ .tracks = cols });
            try add(c.a, out, .grid_template_areas, important, .{ .areas = null });
            return true;
        },
        .list_style => {
            var typ: ?Value = null;
            var pos: ?Value = null;
            var img: ?Value = null;
            var nones: usize = 0;
            while (!c.done()) {
                if (c.ident("none")) {
                    nones += 1;
                    continue;
                }
                if (pos == null) if (parseKeyword(style.ListStylePosition, c)) |k| {
                    pos = kw(k);
                    continue;
                };
                if (img == null) if (try parseImage(c)) |im| {
                    img = .{ .image = im };
                    continue;
                };
                if (typ == null) if (parseListStyleType(c)) |v| {
                    typ = v;
                    continue;
                };
                return false;
            }
            if (nones > 0 and typ == null) typ = kw(style.ListStyleType.none);
            try add(c.a, out, .list_style_type, important, typ orelse kw(style.ListStyleType.disc));
            try add(c.a, out, .list_style_position, important, pos orelse kw(style.ListStylePosition.outside));
            try add(c.a, out, .list_style_image, important, img orelse Value{ .image = null });
            return true;
        },
        .text_decoration => {
            var line: ?Value = null;
            var st: ?Value = null;
            var col: ?Value = null;
            var thick: ?Value = null;
            while (!c.done()) {
                if (line == null) if (parseDecoration(c)) |d| {
                    line = d;
                    continue;
                };
                if (st == null) if (parseKeyword(style.DecorationStyle, c)) |k| {
                    st = kw(k);
                    continue;
                };
                if (thick == null) if (try parseLen(c, .{ .auto = true })) |l| {
                    thick = .{ .len = l };
                    continue;
                };
                if (col == null) if (parseColor(c)) |cc| {
                    col = .{ .color = cc };
                    continue;
                };
                return false;
            }
            try add(c.a, out, .text_decoration_line, important, line orelse Value{ .decoration = .{} });
            try add(c.a, out, .text_decoration_style, important, st orelse kw(style.DecorationStyle.solid));
            try add(c.a, out, .text_decoration_color, important, col orelse Value{ .color = Color.current });
            try add(c.a, out, .text_decoration_thickness, important, thick orelse Value{ .len = SLen.auto });
            return true;
        },
        .columns => {
            var width: ?Value = null;
            var cnt: ?Value = null;
            while (!c.done()) {
                if (c.ident("auto")) continue;
                if (cnt == null) if (parseInteger(c)) |n| {
                    cnt = .{ .integer = n };
                    continue;
                };
                if (width == null) if (try parseLen(c, .{ .percent = false, .negative = false })) |l| {
                    width = .{ .len = l };
                    continue;
                };
                return false;
            }
            try add(c.a, out, .column_width, important, width orelse Value{ .len = SLen.auto });
            try add(c.a, out, .column_count, important, cnt orelse Value{ .integer = 0 });
            return true;
        },
        .white_space => {
            const W = style.WhiteSpaceCollapse;
            const M = style.TextWrapMode;
            const pair: struct { W, M } = if (c.ident("normal")) .{ .collapse, .wrap } else if (c.ident("pre")) .{ .preserve, .nowrap } else if (c.ident("nowrap")) .{ .collapse, .nowrap } else if (c.ident("pre-wrap")) .{ .preserve, .wrap } else if (c.ident("pre-line")) .{ .preserve_breaks, .wrap } else if (c.ident("break-spaces")) .{ .break_spaces, .wrap } else return false;
            try add(c.a, out, .white_space_collapse, important, kw(pair[0]));
            try add(c.a, out, .text_wrap_mode, important, kw(pair[1]));
            return true;
        },
        .text_wrap => {
            var mode: ?Value = null;
            var st: ?Value = null;
            while (!c.done()) {
                if (mode == null) if (parseKeyword(style.TextWrapMode, c)) |k| {
                    mode = kw(k);
                    continue;
                };
                if (st == null) if (parseKeyword(style.TextWrapStyle, c)) |k| {
                    st = kw(k);
                    continue;
                };
                return false;
            }
            try add(c.a, out, .text_wrap_mode, important, mode orelse kw(style.TextWrapMode.wrap));
            try add(c.a, out, .text_wrap_style, important, st orelse kw(style.TextWrapStyle.auto));
            return true;
        },
    }
}

fn parseLonghandOpt(c: *Cursor, id: Id) Error!?Value {
    const save = c.i;
    const v = try parseLonghand(c, id);
    if (v == null) c.i = save;
    return v;
}

fn systemFamily(a: Allocator) Error!*const style.Families {
    const f = try a.create(style.Families);
    const items = try a.alloc(style.Families.Family, 1);
    items[0] = .{ .name = "", .generic = .system_ui };
    f.* = .{ .items = items };
    return f;
}

// Computing.

/// What computing an element's values needs.
pub const Ctx = struct {
    a: Allocator,
    parent: *const style.Style,
    /// The root element's font size and line height (rem, rlh).
    root_font_size: f32 = 16,
    root_line_height: f32 = 19.2,
    viewport_width: f32 = 800,
    viewport_height: f32 = 600,
    /// The default font size for `medium` (user preference).
    medium: f32 = 16,

    pub fn unitContext(cx: *const Ctx, s: *const style.Style) values.Context {
        return .{
            .font_size = s.inh.font_size,
            .root_font_size = cx.root_font_size,
            .line_height = s.lineHeightPx(s.inh.font_size * 1.2),
            .root_line_height = cx.root_line_height,
            .viewport_width = cx.viewport_width,
            .viewport_height = cx.viewport_height,
        };
    }
};

/// Sets property `id` of `s` from a specified value. `s.inh.font_size`
/// must already be computed (callers apply font-size first).
pub fn apply(s: *style.Style, id: Id, v: Value, cx: *const Ctx) Error!void {
    switch (v) {
        .wide => |w| {
            const inherit = switch (w) {
                .inherit => true,
                .initial => false,
                .unset, .revert => id.inherited(),
            };
            copyFrom(s, id, if (inherit) cx.parent else &initial_style, cx);
            return;
        },
        .unparsed => return, // substituted by the cascade before this
        else => {},
    }
    const vc = cx.unitContext(s);
    const S = struct {
        fn len(x: Value, a: Allocator, ctx: *const values.Context) Error!Len {
            return switch (x) {
                .len => |l| l.compute(a, ctx),
                else => Len.zero,
            };
        }
        fn k(comptime E: type, x: Value) E {
            return switch (x) {
                .keyword => |n| @enumFromInt(n),
                else => @enumFromInt(0),
            };
        }
        fn color(x: Value) Color {
            return switch (x) {
                .color => |c| c,
                else => Color.current,
            };
        }
        fn pair(x: Value, a: Allocator, ctx: *const values.Context) Error![2]Len {
            return switch (x) {
                .pair => |p| .{ try p[0].compute(a, ctx), try p[1].compute(a, ctx) },
                else => .{ Len.zero, Len.zero },
            };
        }
    };
    const a = cx.a;
    switch (id) {
        .color => s.inh.color = resolveCurrent(S.color(v), cx.parent.inh.color),
        .font_family => s.inh.font_family = if (v == .families) v.families else null,
        .font_size => {}, // computeFontSize
        .font_weight => s.inh.font_weight = switch (v) {
            .number => |n| @intFromFloat(n),
            .weight_relative => |r| relativeWeight(cx.parent.inh.font_weight, r == .bolder),
            else => 400,
        },
        .font_style => s.inh.font_style = S.k(style.FontStyle, v),
        .font_stretch => s.inh.font_stretch = if (v == .number) v.number else 100,
        .font_variant_caps => s.inh.font_variant_caps = S.k(style.FontVariantCaps, v),
        .font_variation_settings => s.inh.font_variations = if (v == .variations) v.variations else null,
        .line_height => s.inh.line_height = switch (v) {
            .line_height => |l| switch (l.kind) {
                .normal => .{ .kind = .normal },
                .number => .{ .kind = .number, .value = l.number },
                .length => .{ .kind = .length, .value = blk: {
                    const r = try l.len.compute(a, &vc);
                    break :blk r.px + r.pct * s.inh.font_size;
                } },
            },
            else => .{},
        },
        .text_align => s.inh.text_align = S.k(style.TextAlign, v),
        .text_align_last => s.inh.text_align_last = S.k(style.TextAlignLast, v),
        .text_indent => s.inh.text_indent = try S.len(v, a, &vc),
        .text_transform => s.inh.text_transform = S.k(style.TextTransform, v),
        .white_space_collapse => s.inh.white_space_collapse = S.k(style.WhiteSpaceCollapse, v),
        .text_wrap_mode => s.inh.text_wrap_mode = S.k(style.TextWrapMode, v),
        .text_wrap_style => s.inh.text_wrap_style = S.k(style.TextWrapStyle, v),
        .word_break => s.inh.word_break = S.k(style.WordBreak, v),
        .overflow_wrap => s.inh.overflow_wrap = S.k(style.OverflowWrap, v),
        .hyphens => s.inh.hyphens = S.k(style.Hyphens, v),
        .letter_spacing => s.inh.letter_spacing = if (v == .len and v.len.tag == .length) v.len.px(&vc) else 0,
        .word_spacing => s.inh.word_spacing = if (v == .len and v.len.tag == .length) blk: {
            const l = try v.len.compute(a, &vc);
            break :blk l.px + l.pct * s.inh.font_size * 0.25;
        } else 0,
        .direction => s.inh.direction = S.k(style.Direction, v),
        .list_style_type => switch (v) {
            .list_style_string => |str| {
                s.inh.list_style_type = .string;
                s.inh.list_style_string = str;
            },
            else => s.inh.list_style_type = S.k(style.ListStyleType, v),
        },
        .list_style_position => s.inh.list_style_position = S.k(style.ListStylePosition, v),
        .list_style_image => s.inh.list_style_image = if (v == .image) v.image else null,
        .visibility => s.inh.visibility = S.k(style.Visibility, v),
        .border_collapse => s.inh.border_collapse = S.k(style.BorderCollapse, v),
        .border_spacing => if (v == .pair) {
            s.inh.border_spacing = .{ v.pair[0].px(&vc), v.pair[1].px(&vc) };
        },
        .caption_side => s.inh.caption_side = S.k(style.CaptionSide, v),
        .empty_cells => s.inh.empty_cells = S.k(style.EmptyCells, v),
        .tab_size => s.inh.tab_size = switch (v) {
            .number => |n| n,
            // A length: in spaces of a quarter em.
            .len => |l| l.px(&vc) / (s.inh.font_size * 0.25),
            else => 8,
        },
        .cursor => s.inh.cursor = S.k(style.Cursor, v),
        .color_scheme => s.inh.color_scheme = S.k(style.ColorScheme, v),
        .orphans => s.inh.orphans = if (v == .integer) @intCast(@min(255, v.integer)) else 2,
        .widows => s.inh.widows = if (v == .integer) @intCast(@min(255, v.integer)) else 2,
        .display => s.box.display = if (v == .display) v.display else .{},
        .position => s.box.position = S.k(style.Position, v),
        .top => s.box.inset[0] = try S.len(v, a, &vc),
        .right => s.box.inset[1] = try S.len(v, a, &vc),
        .bottom => s.box.inset[2] = try S.len(v, a, &vc),
        .left => s.box.inset[3] = try S.len(v, a, &vc),
        .float => s.box.float = S.k(style.Float, v),
        .clear => s.box.clear = S.k(style.Clear, v),
        .width => s.box.width = try S.len(v, a, &vc),
        .height => s.box.height = try S.len(v, a, &vc),
        .min_width => s.box.min_width = try S.len(v, a, &vc),
        .min_height => s.box.min_height = try S.len(v, a, &vc),
        .max_width => s.box.max_width = try S.len(v, a, &vc),
        .max_height => s.box.max_height = try S.len(v, a, &vc),
        .box_sizing => s.box.box_sizing = S.k(style.BoxSizing, v),
        .margin_top => s.box.margin[0] = try S.len(v, a, &vc),
        .margin_right => s.box.margin[1] = try S.len(v, a, &vc),
        .margin_bottom => s.box.margin[2] = try S.len(v, a, &vc),
        .margin_left => s.box.margin[3] = try S.len(v, a, &vc),
        .padding_top => s.box.padding[0] = try S.len(v, a, &vc),
        .padding_right => s.box.padding[1] = try S.len(v, a, &vc),
        .padding_bottom => s.box.padding[2] = try S.len(v, a, &vc),
        .padding_left => s.box.padding[3] = try S.len(v, a, &vc),
        .border_top_width, .border_right_width, .border_bottom_width, .border_left_width => {
            const i = @intFromEnum(id) - @intFromEnum(Id.border_top_width);
            var w = if (v == .len) v.len.px(&vc) else 3;
            // Widths of at least one pixel snap to whole pixels.
            if (w >= 1) w = @floor(w) else if (w > 0) w = 1;
            s.box.border_width[i] = w;
        },
        .border_top_style, .border_right_style, .border_bottom_style, .border_left_style => s.box.border_style[@intFromEnum(id) - @intFromEnum(Id.border_top_style)] = S.k(style.BorderStyle, v),
        .border_top_color, .border_right_color, .border_bottom_color, .border_left_color => s.box.border_color[@intFromEnum(id) - @intFromEnum(Id.border_top_color)] = S.color(v),
        .border_top_left_radius, .border_top_right_radius, .border_bottom_right_radius, .border_bottom_left_radius => s.box.border_radius[@intFromEnum(id) - @intFromEnum(Id.border_top_left_radius)] = try S.pair(v, a, &vc),
        .background_color => s.box.background_color = S.color(v),
        .background_image => s.box.background_image = if (v == .image) v.image else null,
        .background_repeat => s.box.background_repeat = S.k(style.Repeat, v),
        .background_position => s.box.background_position = try S.pair(v, a, &vc),
        .background_size => s.box.background_size = if (v == .bg_size) .{ .kind = v.bg_size.kind, .w = try v.bg_size.w.compute(a, &vc), .h = try v.bg_size.h.compute(a, &vc) } else .{},
        .background_clip => s.box.background_clip = S.k(style.Box, v),
        .background_origin => s.box.background_origin = S.k(style.Box, v),
        .mask_image => s.box.mask_image = if (v == .image) v.image else null,
        .mask_repeat => s.box.mask_repeat = S.k(style.Repeat, v),
        .mask_position => s.box.mask_position = try S.pair(v, a, &vc),
        .mask_size => s.box.mask_size = if (v == .bg_size) .{ .kind = v.bg_size.kind, .w = try v.bg_size.w.compute(a, &vc), .h = try v.bg_size.h.compute(a, &vc) } else .{},
        .box_shadow => s.box.box_shadow = if (v == .shadows) v.shadows else null,
        .opacity => s.box.opacity = if (v == .number) v.number else 1,
        .overflow_x => s.box.overflow_x = S.k(style.Overflow, v),
        .overflow_y => s.box.overflow_y = S.k(style.Overflow, v),
        .z_index => s.box.z_index = if (v == .integer) v.integer else null,
        .vertical_align => switch (v) {
            .len => |l| {
                s.box.vertical_align = .length;
                s.box.vertical_align_len = try l.compute(a, &vc);
            },
            else => s.box.vertical_align = S.k(style.VerticalAlign, v),
        },
        .text_decoration_line => s.box.text_decoration_line = if (v == .decoration) v.decoration else .{},
        .text_decoration_style => s.box.text_decoration_style = S.k(style.DecorationStyle, v),
        .text_decoration_color => s.box.text_decoration_color = S.color(v),
        .text_decoration_thickness => s.box.text_decoration_thickness = try S.len(v, a, &vc),
        .text_underline_offset => s.box.text_underline_offset = try S.len(v, a, &vc),
        .text_overflow => s.box.text_overflow = S.k(style.TextOverflow, v),
        .flex_direction => s.box.flex_direction = S.k(style.FlexDirection, v),
        .flex_wrap => s.box.flex_wrap = S.k(style.FlexWrap, v),
        .flex_grow => s.box.flex_grow = if (v == .number) v.number else 0,
        .flex_shrink => s.box.flex_shrink = if (v == .number) v.number else 1,
        .flex_basis => s.box.flex_basis = try S.len(v, a, &vc),
        .order => s.box.order = if (v == .integer) v.integer else 0,
        .justify_content => s.box.justify_content = S.k(style.Align, v),
        .align_items => s.box.align_items = S.k(style.Align, v),
        .align_self => s.box.align_self = S.k(style.Align, v),
        .align_content => s.box.align_content = S.k(style.Align, v),
        .justify_items => s.box.justify_items = S.k(style.Align, v),
        .justify_self => s.box.justify_self = S.k(style.Align, v),
        .row_gap => s.box.row_gap = try S.len(v, a, &vc),
        .column_gap => s.box.column_gap = try S.len(v, a, &vc),
        .grid_template_columns => s.box.grid_template_columns = if (v == .tracks) v.tracks else null,
        .grid_template_rows => s.box.grid_template_rows = if (v == .tracks) v.tracks else null,
        .grid_template_areas => s.box.grid_template_areas = if (v == .areas) v.areas else null,
        .grid_auto_flow => s.box.grid_auto_flow = if (v == .flow) v.flow else .{},
        .grid_auto_columns => s.box.grid_auto_columns = if (v == .tracks) v.tracks else null,
        .grid_auto_rows => s.box.grid_auto_rows = if (v == .tracks) v.tracks else null,
        .grid_row_start => s.box.grid_row_start = if (v == .line) v.line else .{},
        .grid_row_end => s.box.grid_row_end = if (v == .line) v.line else .{},
        .grid_column_start => s.box.grid_column_start = if (v == .line) v.line else .{},
        .grid_column_end => s.box.grid_column_end = if (v == .line) v.line else .{},
        .object_fit => s.box.object_fit = S.k(style.ObjectFit, v),
        .object_position => s.box.object_position = try S.pair(v, a, &vc),
        .aspect_ratio => if (v == .pair) {
            s.box.aspect_ratio = v.pair[0].v;
            s.box.aspect_ratio_auto = v.pair[1].v != 0;
        },
        .content => switch (v) {
            .content => |c| {
                s.box.content = c;
                s.box.content_none = false;
            },
            .content_none => {
                s.box.content = null;
                s.box.content_none = true;
            },
            else => {},
        },
        .counter_reset => s.box.counter_reset = if (v == .counters) v.counters else null,
        .counter_increment => s.box.counter_increment = if (v == .counters) v.counters else null,
        .counter_set => s.box.counter_set = if (v == .counters) v.counters else null,
        .table_layout => s.box.table_layout = S.k(style.TableLayout, v),
        .break_before => s.box.break_before = S.k(style.Break, v),
        .break_after => s.box.break_after = S.k(style.Break, v),
        .break_inside => s.box.break_inside = S.k(style.Break, v),
        .column_count => s.box.column_count = if (v == .integer) @intCast(@max(0, v.integer)) else 0,
        .column_width => s.box.column_width = try S.len(v, a, &vc),
        .column_span => s.box.column_span_all = v == .keyword and v.keyword == 1,
        .outline_width => s.box.outline_width = if (v == .len) v.len.px(&vc) else 3,
        .outline_style => s.box.outline_style = S.k(style.BorderStyle, v),
        .outline_color => s.box.outline_color = S.color(v),
        .outline_offset => s.box.outline_offset = if (v == .len) v.len.px(&vc) else 0,
        .unicode_bidi => s.box.unicode_bidi = S.k(style.UnicodeBidi, v),
    }
}

/// The computed font size from a specified one (or the parent's for
/// none), against the parent's size.
pub fn computeFontSize(v: ?Value, cx: *const Ctx) Error!f32 {
    const parent = cx.parent.inh.font_size;
    const val = v orelse return parent;
    return switch (val) {
        .font_size_keyword => |k| k * cx.medium / 16,
        .len => |l| blk: {
            const ctx: values.Context = .{ .font_size = parent, .root_font_size = cx.root_font_size, .viewport_width = cx.viewport_width, .viewport_height = cx.viewport_height, .line_height = parent * 1.2, .root_line_height = cx.root_line_height };
            const r = try l.compute(cx.a, &ctx);
            break :blk @max(0, r.px + r.pct * parent + if (r.nl) |n| n.calc.eval(&n.ctx, parent) else 0);
        },
        .wide => |w| switch (w) {
            .initial => cx.medium,
            else => parent,
        },
        else => parent,
    };
}

fn relativeWeight(p: u16, bolder: bool) u16 {
    if (bolder) {
        if (p < 350) return 400;
        if (p < 550) return 700;
        return 900;
    }
    if (p < 550) return 100;
    if (p < 750) return 400;
    return 700;
}

fn resolveCurrent(c: Color, current: Color) Color {
    return if (c.kind == .current) current else c;
}

pub const initial_style: style.Style = .{};

/// Copies one property's computed value from another style (inherit,
/// initial).
fn copyFrom(s: *style.Style, id: Id, from: *const style.Style, cx: *const Ctx) void {
    _ = cx;
    switch (id) {
        .color => s.inh.color = from.inh.color,
        .font_family => s.inh.font_family = from.inh.font_family,
        .font_size => {},
        .font_weight => s.inh.font_weight = from.inh.font_weight,
        .font_style => s.inh.font_style = from.inh.font_style,
        .font_stretch => s.inh.font_stretch = from.inh.font_stretch,
        .font_variant_caps => s.inh.font_variant_caps = from.inh.font_variant_caps,
        .font_variation_settings => s.inh.font_variations = from.inh.font_variations,
        .line_height => s.inh.line_height = from.inh.line_height,
        .text_align => s.inh.text_align = from.inh.text_align,
        .text_align_last => s.inh.text_align_last = from.inh.text_align_last,
        .text_indent => s.inh.text_indent = from.inh.text_indent,
        .text_transform => s.inh.text_transform = from.inh.text_transform,
        .white_space_collapse => s.inh.white_space_collapse = from.inh.white_space_collapse,
        .text_wrap_mode => s.inh.text_wrap_mode = from.inh.text_wrap_mode,
        .text_wrap_style => s.inh.text_wrap_style = from.inh.text_wrap_style,
        .word_break => s.inh.word_break = from.inh.word_break,
        .overflow_wrap => s.inh.overflow_wrap = from.inh.overflow_wrap,
        .hyphens => s.inh.hyphens = from.inh.hyphens,
        .letter_spacing => s.inh.letter_spacing = from.inh.letter_spacing,
        .word_spacing => s.inh.word_spacing = from.inh.word_spacing,
        .direction => s.inh.direction = from.inh.direction,
        .list_style_type => {
            s.inh.list_style_type = from.inh.list_style_type;
            s.inh.list_style_string = from.inh.list_style_string;
        },
        .list_style_position => s.inh.list_style_position = from.inh.list_style_position,
        .list_style_image => s.inh.list_style_image = from.inh.list_style_image,
        .visibility => s.inh.visibility = from.inh.visibility,
        .border_collapse => s.inh.border_collapse = from.inh.border_collapse,
        .border_spacing => s.inh.border_spacing = from.inh.border_spacing,
        .caption_side => s.inh.caption_side = from.inh.caption_side,
        .empty_cells => s.inh.empty_cells = from.inh.empty_cells,
        .tab_size => s.inh.tab_size = from.inh.tab_size,
        .cursor => s.inh.cursor = from.inh.cursor,
        .color_scheme => s.inh.color_scheme = from.inh.color_scheme,
        .orphans => s.inh.orphans = from.inh.orphans,
        .widows => s.inh.widows = from.inh.widows,
        .display => s.box.display = from.box.display,
        .position => s.box.position = from.box.position,
        .top => s.box.inset[0] = from.box.inset[0],
        .right => s.box.inset[1] = from.box.inset[1],
        .bottom => s.box.inset[2] = from.box.inset[2],
        .left => s.box.inset[3] = from.box.inset[3],
        .float => s.box.float = from.box.float,
        .clear => s.box.clear = from.box.clear,
        .width => s.box.width = from.box.width,
        .height => s.box.height = from.box.height,
        .min_width => s.box.min_width = from.box.min_width,
        .min_height => s.box.min_height = from.box.min_height,
        .max_width => s.box.max_width = from.box.max_width,
        .max_height => s.box.max_height = from.box.max_height,
        .box_sizing => s.box.box_sizing = from.box.box_sizing,
        .margin_top, .margin_right, .margin_bottom, .margin_left => {
            const i = @intFromEnum(id) - @intFromEnum(Id.margin_top);
            s.box.margin[i] = from.box.margin[i];
        },
        .padding_top, .padding_right, .padding_bottom, .padding_left => {
            const i = @intFromEnum(id) - @intFromEnum(Id.padding_top);
            s.box.padding[i] = from.box.padding[i];
        },
        .border_top_width, .border_right_width, .border_bottom_width, .border_left_width => {
            const i = @intFromEnum(id) - @intFromEnum(Id.border_top_width);
            s.box.border_width[i] = if (from == &initial_style) 3 else from.box.border_width[i];
        },
        .border_top_style, .border_right_style, .border_bottom_style, .border_left_style => {
            const i = @intFromEnum(id) - @intFromEnum(Id.border_top_style);
            s.box.border_style[i] = from.box.border_style[i];
        },
        .border_top_color, .border_right_color, .border_bottom_color, .border_left_color => {
            const i = @intFromEnum(id) - @intFromEnum(Id.border_top_color);
            s.box.border_color[i] = from.box.border_color[i];
        },
        .border_top_left_radius, .border_top_right_radius, .border_bottom_right_radius, .border_bottom_left_radius => {
            const i = @intFromEnum(id) - @intFromEnum(Id.border_top_left_radius);
            s.box.border_radius[i] = from.box.border_radius[i];
        },
        .background_color => s.box.background_color = from.box.background_color,
        .background_image => s.box.background_image = from.box.background_image,
        .background_repeat => s.box.background_repeat = from.box.background_repeat,
        .background_position => s.box.background_position = from.box.background_position,
        .background_size => s.box.background_size = from.box.background_size,
        .background_clip => s.box.background_clip = from.box.background_clip,
        .background_origin => s.box.background_origin = from.box.background_origin,
        .mask_image => s.box.mask_image = from.box.mask_image,
        .mask_repeat => s.box.mask_repeat = from.box.mask_repeat,
        .mask_position => s.box.mask_position = from.box.mask_position,
        .mask_size => s.box.mask_size = from.box.mask_size,
        .box_shadow => s.box.box_shadow = from.box.box_shadow,
        .opacity => s.box.opacity = from.box.opacity,
        .overflow_x => s.box.overflow_x = from.box.overflow_x,
        .overflow_y => s.box.overflow_y = from.box.overflow_y,
        .z_index => s.box.z_index = from.box.z_index,
        .vertical_align => {
            s.box.vertical_align = from.box.vertical_align;
            s.box.vertical_align_len = from.box.vertical_align_len;
        },
        .text_decoration_line => s.box.text_decoration_line = from.box.text_decoration_line,
        .text_decoration_style => s.box.text_decoration_style = from.box.text_decoration_style,
        .text_decoration_color => s.box.text_decoration_color = from.box.text_decoration_color,
        .text_decoration_thickness => s.box.text_decoration_thickness = from.box.text_decoration_thickness,
        .text_underline_offset => s.box.text_underline_offset = from.box.text_underline_offset,
        .text_overflow => s.box.text_overflow = from.box.text_overflow,
        .flex_direction => s.box.flex_direction = from.box.flex_direction,
        .flex_wrap => s.box.flex_wrap = from.box.flex_wrap,
        .flex_grow => s.box.flex_grow = from.box.flex_grow,
        .flex_shrink => s.box.flex_shrink = from.box.flex_shrink,
        .flex_basis => s.box.flex_basis = from.box.flex_basis,
        .order => s.box.order = from.box.order,
        .justify_content => s.box.justify_content = from.box.justify_content,
        .align_items => s.box.align_items = from.box.align_items,
        .align_self => s.box.align_self = from.box.align_self,
        .align_content => s.box.align_content = from.box.align_content,
        .justify_items => s.box.justify_items = from.box.justify_items,
        .justify_self => s.box.justify_self = from.box.justify_self,
        .row_gap => s.box.row_gap = from.box.row_gap,
        .column_gap => s.box.column_gap = from.box.column_gap,
        .grid_template_columns => s.box.grid_template_columns = from.box.grid_template_columns,
        .grid_template_rows => s.box.grid_template_rows = from.box.grid_template_rows,
        .grid_template_areas => s.box.grid_template_areas = from.box.grid_template_areas,
        .grid_auto_flow => s.box.grid_auto_flow = from.box.grid_auto_flow,
        .grid_auto_columns => s.box.grid_auto_columns = from.box.grid_auto_columns,
        .grid_auto_rows => s.box.grid_auto_rows = from.box.grid_auto_rows,
        .grid_row_start => s.box.grid_row_start = from.box.grid_row_start,
        .grid_row_end => s.box.grid_row_end = from.box.grid_row_end,
        .grid_column_start => s.box.grid_column_start = from.box.grid_column_start,
        .grid_column_end => s.box.grid_column_end = from.box.grid_column_end,
        .object_fit => s.box.object_fit = from.box.object_fit,
        .object_position => s.box.object_position = from.box.object_position,
        .aspect_ratio => {
            s.box.aspect_ratio = from.box.aspect_ratio;
            s.box.aspect_ratio_auto = from.box.aspect_ratio_auto;
        },
        .content => {
            s.box.content = from.box.content;
            s.box.content_none = from.box.content_none;
        },
        .counter_reset => s.box.counter_reset = from.box.counter_reset,
        .counter_increment => s.box.counter_increment = from.box.counter_increment,
        .counter_set => s.box.counter_set = from.box.counter_set,
        .table_layout => s.box.table_layout = from.box.table_layout,
        .break_before => s.box.break_before = from.box.break_before,
        .break_after => s.box.break_after = from.box.break_after,
        .break_inside => s.box.break_inside = from.box.break_inside,
        .column_count => s.box.column_count = from.box.column_count,
        .column_width => s.box.column_width = from.box.column_width,
        .column_span => s.box.column_span_all = from.box.column_span_all,
        .outline_width => s.box.outline_width = if (from == &initial_style) 3 else from.box.outline_width,
        .outline_style => s.box.outline_style = from.box.outline_style,
        .outline_color => s.box.outline_color = from.box.outline_color,
        .outline_offset => s.box.outline_offset = from.box.outline_offset,
        .unicode_bidi => s.box.unicode_bidi = from.box.unicode_bidi,
    }
}

test "parsing shorthands and longhands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Declaration) = .empty;
    const cases = [_]struct { []const u8, []const u8, usize }{
        .{ "margin", "1px 2em auto", 4 },
        .{ "border", "1px solid red", 12 },
        .{ "font", "italic bold 12px/1.5 Georgia, 'Times New Roman', serif", 7 },
        .{ "background", "#fff url(a.png) no-repeat center / cover", 7 },
        .{ "flex", "1", 3 },
        .{ "grid-template-columns", "repeat(auto-fill, minmax(200px, 1fr)) [end] 2fr", 1 },
        .{ "border-radius", "4px 8px / 2px", 4 },
        .{ "color", "var(--fg, red)", 1 },
        .{ "margin", "var(--m)", 4 },
        .{ "display", "inline flex", 1 },
        .{ "width", "calc(100% - 2rem)", 1 },
        .{ "box-shadow", "0 1px 2px rgba(0,0,0,.2), inset 0 0 0 1px #ccc", 1 },
        .{ "white-space", "pre-wrap", 2 },
        .{ "text-decoration", "underline dotted red", 4 },
    };
    for (cases) |cs| {
        out.clearRetainingCapacity();
        var l = try tk.tokenize(a, cs[1]);
        _ = &l;
        try parse(a, lookup(cs[0]).?, l.tokens[0 .. l.tokens.len - 1], false, &out);
        std.testing.expectEqual(cs[2], out.items.len) catch |err| {
            std.debug.print("{s}: {s}\n", .{ cs[0], cs[1] });
            return err;
        };
    }
    // Invalid values add nothing.
    out.clearRetainingCapacity();
    var l = try tk.tokenize(a, "12 foo");
    try parse(a, lookup("width").?, l.tokens[0 .. l.tokens.len - 1], false, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
