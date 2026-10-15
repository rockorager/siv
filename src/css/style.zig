//! Computed styles: the values layout and painting read, one compact
//! struct per distinct style (documents share them between elements,
//! `Store.intern`). Inherited properties are a struct of their own, so an
//! element starts as its parent's `inh` plus the initial `box`.

const std = @import("std");
const color_mod = @import("color.zig");
const values = @import("values.zig");

pub const Color = color_mod.Color;

pub const LenTag = enum(u8) { length, auto, none, normal, min_content, max_content, fit_content, stretch, content };

/// A computed length-percentage: `px + pct × basis`, or a keyword.
pub const Len = struct {
    px: f32 = 0,
    pct: f32 = 0,
    tag: LenTag = .length,
    /// A min()/max()/clamp() mixing pixels and percentages, resolved
    /// against the basis at layout.
    nl: ?*const NonLinear = null,

    pub const auto: Len = .{ .tag = .auto };
    pub const none: Len = .{ .tag = .none };
    pub const normal: Len = .{ .tag = .normal };
    pub const zero: Len = .{};

    pub fn fixed(px: f32) Len {
        return .{ .px = px };
    }

    pub fn isAuto(l: Len) bool {
        return l.tag == .auto;
    }

    pub fn isLength(l: Len) bool {
        return l.tag == .length;
    }

    pub fn hasPercent(l: Len) bool {
        return l.tag == .length and (l.pct != 0 or l.nl != null);
    }

    /// Resolves against a percentage basis (null when indefinite:
    /// percentages then count as zero, or the result is null if `strict`).
    pub fn resolve(l: Len, basis: ?f32) f32 {
        if (l.tag != .length) return 0;
        if (l.nl) |n| return n.calc.eval(&n.ctx, basis orelse 0);
        return l.px + l.pct * (basis orelse 0);
    }

    /// Null when the value depends on an indefinite basis.
    pub fn definite(l: Len, basis: ?f32) ?f32 {
        if (l.tag != .length) return null;
        if ((l.pct != 0 or l.nl != null) and basis == null) return null;
        return l.resolve(basis);
    }

    pub fn eql(a: Len, b: Len) bool {
        return a.px == b.px and a.pct == b.pct and a.tag == b.tag and a.nl == b.nl;
    }
};

pub const NonLinear = struct { calc: values.Calc, ctx: values.Context };

pub const FontStyle = enum(u8) { normal, italic, oblique };
pub const FontVariantCaps = enum(u8) { normal, small_caps, all_small_caps, petite_caps, all_petite_caps, unicase, titling_caps };
/// `legacy_*`: HTML's align attribute (`-webkit-center` and its kin),
/// which also aligns block-level children narrower than their parent.
pub const TextAlign = enum(u8) { start, end, left, right, center, justify, match_parent, legacy_left, legacy_right, legacy_center };
pub const TextAlignLast = enum(u8) { auto, start, end, left, right, center, justify };
pub const TextTransform = enum(u8) { none, uppercase, lowercase, capitalize, full_width };
pub const WhiteSpaceCollapse = enum(u8) { collapse, preserve, preserve_breaks, preserve_spaces, break_spaces };
pub const TextWrapMode = enum(u8) { wrap, nowrap };
pub const TextWrapStyle = enum(u8) { auto, balance, pretty, stable };
pub const WordBreak = enum(u8) { normal, break_all, keep_all, break_word };
pub const OverflowWrap = enum(u8) { normal, break_word, anywhere };
pub const Hyphens = enum(u8) { manual, none, auto };
pub const Direction = enum(u8) { ltr, rtl };
pub const ListStylePosition = enum(u8) { outside, inside };
pub const Visibility = enum(u8) { visible, hidden, collapse };
pub const BorderCollapse = enum(u8) { separate, collapse };
pub const CaptionSide = enum(u8) { top, bottom };
pub const EmptyCells = enum(u8) { show, hide };
pub const Cursor = enum(u8) { auto, default, pointer, text, none, help, wait, move, not_allowed, crosshair, grab, progress };
pub const ColorScheme = enum(u8) { normal, light, dark, light_dark };

pub const ListStyleType = enum(u8) {
    disc,
    circle,
    square,
    disclosure_open,
    disclosure_closed,
    decimal,
    decimal_leading_zero,
    lower_roman,
    upper_roman,
    lower_alpha,
    upper_alpha,
    lower_greek,
    none,
    /// A string marker (`list-style-type: "→ "`), in `list_style_string`.
    string,
};

pub const Display = struct {
    outer: Outer = .@"inline",
    inner: Inner = .flow,
    list_item: bool = false,

    pub const Outer = enum(u8) { block, @"inline", run_in, none, contents };
    pub const Inner = enum(u8) {
        flow,
        flow_root,
        flex,
        grid,
        table,
        table_row_group,
        table_header_group,
        table_footer_group,
        table_row,
        table_cell,
        table_column_group,
        table_column,
        table_caption,
        ruby,
    };

    pub const none: Display = .{ .outer = .none };
    pub const block: Display = .{ .outer = .block };
    pub const @"inline": Display = .{};

    pub fn isNone(d: Display) bool {
        return d.outer == .none;
    }

    pub fn isBlockLevel(d: Display) bool {
        return d.outer == .block or switch (d.inner) {
            .table_row_group, .table_header_group, .table_footer_group, .table_row, .table_cell, .table_column_group, .table_column, .table_caption => true,
            else => false,
        };
    }

    pub fn isInlineLevel(d: Display) bool {
        return d.outer == .@"inline" and !d.isBlockLevel();
    }

    pub fn eql(a: Display, b: Display) bool {
        return a.outer == b.outer and a.inner == b.inner and a.list_item == b.list_item;
    }
};

pub const Position = enum(u8) { static, relative, absolute, fixed, sticky };
pub const Float = enum(u8) { none, left, right, inline_start, inline_end };
pub const Clear = enum(u8) { none, left, right, both, inline_start, inline_end };
pub const BoxSizing = enum(u8) { content_box, border_box };
pub const BorderStyle = enum(u8) { none, hidden, dotted, dashed, solid, double, groove, ridge, inset, outset };
pub const Repeat = enum(u8) { repeat, repeat_x, repeat_y, no_repeat, space, round };
pub const Box = enum(u8) { border_box, padding_box, content_box, text };
pub const Overflow = enum(u8) { visible, hidden, clip, scroll, auto };
pub const VerticalAlign = enum(u8) { baseline, sub, super, text_top, text_bottom, middle, top, bottom, length };
pub const DecorationStyle = enum(u8) { solid, double, dotted, dashed, wavy };
pub const TextOverflow = enum(u8) { clip, ellipsis };
pub const FlexDirection = enum(u8) { row, row_reverse, column, column_reverse };
pub const FlexWrap = enum(u8) { nowrap, wrap, wrap_reverse };
pub const Align = enum(u8) {
    normal,
    auto,
    stretch,
    start,
    end,
    flex_start,
    flex_end,
    self_start,
    self_end,
    center,
    left,
    right,
    baseline,
    last_baseline,
    space_between,
    space_around,
    space_evenly,
    legacy,
};
pub const ObjectFit = enum(u8) { fill, contain, cover, none, scale_down };
pub const TableLayout = enum(u8) { auto, fixed };
pub const Break = enum(u8) { auto, avoid, avoid_page, avoid_column, page, left, right, recto, verso, column, always };
pub const UnicodeBidi = enum(u8) { normal, embed, isolate, bidi_override, isolate_override, plaintext };
pub const GridAutoFlow = struct { column: bool = false, dense: bool = false };
pub const BackgroundSize = struct {
    kind: enum(u8) { explicit, cover, contain } = .explicit,
    w: Len = .auto,
    h: Len = .auto,
};

pub const Decoration = packed struct(u8) {
    underline: bool = false,
    overline: bool = false,
    line_through: bool = false,
    blink: bool = false,
    _: u4 = 0,

    pub fn any(d: Decoration) bool {
        return d.underline or d.overline or d.line_through;
    }
};

pub const Generic = enum(u8) { none, serif, sans_serif, monospace, cursive, fantasy, system_ui, ui_serif, ui_sans_serif, ui_monospace, ui_rounded, math, emoji, fangsong };

pub const Families = struct {
    /// Names in order; a generic family has an empty name and its kind.
    items: []const Family,

    pub const Family = struct { name: []const u8, generic: Generic = .none };
};

pub const Stop = struct { color: Color, pos: ?Len = null };

pub const Gradient = struct {
    kind: enum(u8) { linear, radial, conic } = .linear,
    repeating: bool = false,
    /// Linear: the angle in degrees (180 is to bottom); conic: from angle.
    angle: f32 = 180,
    /// Linear `to <corner>`: the sides it points to (x: -1 left, 1 right).
    corner: ?[2]i8 = null,
    /// Radial: circle or ellipse, and the size keyword or explicit radii.
    circle: bool = false,
    extent: enum(u8) { farthest_corner, closest_side, closest_corner, farthest_side, explicit } = .farthest_corner,
    rx: Len = .zero,
    ry: Len = .zero,
    cx: Len = .{ .pct = 0.5 },
    cy: Len = .{ .pct = 0.5 },
    stops: []const Stop,
};

pub const Image = union(enum) {
    url: []const u8,
    gradient: Gradient,
};

pub const Shadow = struct {
    x: f32 = 0,
    y: f32 = 0,
    blur: f32 = 0,
    spread: f32 = 0,
    color: Color = Color.current,
    inset: bool = false,
};

pub const Shadows = struct { items: []const Shadow };

pub const Breadth = union(enum) {
    len: Len,
    fr: f32,
    auto,
    min_content,
    max_content,
};

pub const TrackSize = struct {
    min: Breadth,
    max: Breadth,
    /// fit-content(len): max is the length, used as a limit.
    fit_content: ?Len = null,

    pub fn single(b: Breadth) TrackSize {
        return switch (b) {
            .fr => .{ .min = .auto, .max = b },
            else => .{ .min = b, .max = b },
        };
    }
};

pub const Track = union(enum) {
    size: TrackSize,
    /// repeat(n, ...), repeat(auto-fill, ...), repeat(auto-fit, ...).
    repeat: struct { count: u32, auto: enum(u8) { none, fill, fit } = .none, sizes: []const TrackSize, names: []const []const []const u8 = &.{} },
    /// [name name]
    names: []const []const u8,
};

pub const Tracks = struct { items: []const Track };

pub const Areas = struct {
    rows: u32,
    columns: u32,
    /// Row-major; each cell's area name ("" for `.`).
    cells: []const []const u8,
};

pub const GridLine = struct {
    kind: enum(u8) { auto, line, span } = .auto,
    n: i32 = 0,
    name: []const u8 = "",

    pub fn eql(a: GridLine, b: GridLine) bool {
        return a.kind == b.kind and a.n == b.n and std.mem.eql(u8, a.name, b.name);
    }
};

pub const ContentItem = union(enum) {
    string: []const u8,
    attr: []const u8,
    counter: struct { name: []const u8, style: ListStyleType = .decimal },
    counters: struct { name: []const u8, sep: []const u8, style: ListStyleType = .decimal },
    open_quote,
    close_quote,
    no_open_quote,
    no_close_quote,
    url: []const u8,
};

pub const Content = struct { items: []const ContentItem };

pub const Counters = struct { items: []const Counter };
pub const Counter = struct { name: []const u8, value: i32 };

pub const LineHeight = struct {
    kind: enum(u8) { normal, number, length } = .normal,
    value: f32 = 0,

    pub fn eql(a: LineHeight, b: LineHeight) bool {
        return a.kind == b.kind and a.value == b.value;
    }
};

pub const Custom = struct {
    /// Sorted by name; values are token text as written (trimmed).
    names: []const []const u8,
    values: []const []const u8,

    pub fn get(c: *const Custom, name: []const u8) ?[]const u8 {
        var lo: usize = 0;
        var hi: usize = c.names.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, c.names[mid], name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return c.values[mid],
            }
        }
        return null;
    }
};

pub const Inherited = struct {
    color: Color = Color.black,
    font_family: ?*const Families = null,
    font_size: f32 = 16,
    font_weight: u16 = 400,
    font_style: FontStyle = .normal,
    font_stretch: f32 = 100,
    font_variant_caps: FontVariantCaps = .normal,
    /// Variation axis settings (font-variation-settings), tag and value.
    font_variations: ?*const []const [2]u32 = null,
    line_height: LineHeight = .{},
    text_align: TextAlign = .start,
    text_align_last: TextAlignLast = .auto,
    text_indent: Len = .zero,
    text_transform: TextTransform = .none,
    white_space_collapse: WhiteSpaceCollapse = .collapse,
    text_wrap_mode: TextWrapMode = .wrap,
    text_wrap_style: TextWrapStyle = .auto,
    word_break: WordBreak = .normal,
    overflow_wrap: OverflowWrap = .normal,
    hyphens: Hyphens = .manual,
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    direction: Direction = .ltr,
    list_style_type: ListStyleType = .disc,
    list_style_string: []const u8 = "",
    list_style_position: ListStylePosition = .outside,
    list_style_image: ?*const Image = null,
    visibility: Visibility = .visible,
    border_collapse: BorderCollapse = .separate,
    border_spacing: [2]f32 = .{ 0, 0 },
    caption_side: CaptionSide = .top,
    empty_cells: EmptyCells = .show,
    tab_size: f32 = 8,
    cursor: Cursor = .auto,
    color_scheme: ColorScheme = .normal,
    orphans: u8 = 2,
    widows: u8 = 2,
    /// The content language (from `lang`), interned by the document; 0 is
    /// unknown.
    lang: u32 = 0,
    /// Underline and the others propagate to descendants' text (CSS Text
    /// Decoration 3): the decorations in effect and their color.
    decorations: Decoration = .{},
    decoration_color: Color = Color.current,
    decoration_style: DecorationStyle = .solid,
};

pub const BoxProps = struct {
    display: Display = .{},
    position: Position = .static,
    inset: [4]Len = .{ .auto, .auto, .auto, .auto },
    float: Float = .none,
    clear: Clear = .none,
    width: Len = .auto,
    height: Len = .auto,
    min_width: Len = .auto,
    min_height: Len = .auto,
    max_width: Len = .none,
    max_height: Len = .none,
    box_sizing: BoxSizing = .content_box,
    /// Top, right, bottom, left (physical).
    margin: [4]Len = .{ .zero, .zero, .zero, .zero },
    padding: [4]Len = .{ .zero, .zero, .zero, .zero },
    border_width: [4]f32 = .{ 0, 0, 0, 0 },
    border_style: [4]BorderStyle = .{ .none, .none, .none, .none },
    border_color: [4]Color = .{ Color.current, Color.current, Color.current, Color.current },
    /// Top-left, top-right, bottom-right, bottom-left; each x and y.
    border_radius: [4][2]Len = .{ .{ .zero, .zero }, .{ .zero, .zero }, .{ .zero, .zero }, .{ .zero, .zero } },
    background_color: Color = Color.transparent,
    background_image: ?*const Image = null,
    background_repeat: Repeat = .repeat,
    background_position: [2]Len = .{ .zero, .zero },
    background_size: BackgroundSize = .{},
    background_clip: Box = .border_box,
    background_origin: Box = .padding_box,
    /// One mask layer (CSS Masking 1): an image's alpha, positioned and
    /// sized as a background is in the border box.
    mask_image: ?*const Image = null,
    mask_repeat: Repeat = .repeat,
    mask_position: [2]Len = .{ .zero, .zero },
    mask_size: BackgroundSize = .{},
    box_shadow: ?*const Shadows = null,
    opacity: f32 = 1,
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,
    z_index: ?i32 = null,
    vertical_align: VerticalAlign = .baseline,
    vertical_align_len: Len = .zero,
    text_decoration_line: Decoration = .{},
    text_decoration_style: DecorationStyle = .solid,
    text_decoration_color: Color = Color.current,
    text_decoration_thickness: Len = .auto,
    text_underline_offset: Len = .auto,
    text_overflow: TextOverflow = .clip,
    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Len = .auto,
    order: i32 = 0,
    justify_content: Align = .normal,
    align_items: Align = .normal,
    align_self: Align = .auto,
    align_content: Align = .normal,
    justify_items: Align = .legacy,
    justify_self: Align = .auto,
    row_gap: Len = .normal,
    column_gap: Len = .normal,
    grid_template_columns: ?*const Tracks = null,
    grid_template_rows: ?*const Tracks = null,
    grid_template_areas: ?*const Areas = null,
    grid_auto_flow: GridAutoFlow = .{},
    grid_auto_columns: ?*const Tracks = null,
    grid_auto_rows: ?*const Tracks = null,
    grid_row_start: GridLine = .{},
    grid_row_end: GridLine = .{},
    grid_column_start: GridLine = .{},
    grid_column_end: GridLine = .{},
    object_fit: ObjectFit = .fill,
    object_position: [2]Len = .{ .{ .pct = 0.5 }, .{ .pct = 0.5 } },
    /// 0 is auto.
    aspect_ratio: f32 = 0,
    aspect_ratio_auto: bool = true,
    content: ?*const Content = null,
    content_none: bool = false,
    counter_reset: ?*const Counters = null,
    counter_increment: ?*const Counters = null,
    counter_set: ?*const Counters = null,
    table_layout: TableLayout = .auto,
    break_before: Break = .auto,
    break_after: Break = .auto,
    break_inside: Break = .auto,
    column_count: u32 = 0,
    column_width: Len = .auto,
    column_span_all: bool = false,
    outline_width: f32 = 0,
    outline_style: BorderStyle = .none,
    outline_color: Color = Color.current,
    outline_offset: f32 = 0,
    unicode_bidi: UnicodeBidi = .normal,
};

pub const Style = struct {
    /// A style interned in a `Store`.
    pub const Id = u32;

    inh: Inherited = .{},
    box: BoxProps = .{},
    custom: ?*const Custom = null,

    pub fn display(s: *const Style) Display {
        return s.box.display;
    }

    pub fn isPositioned(s: *const Style) bool {
        return s.box.position != .static;
    }

    pub fn isOutOfFlow(s: *const Style) bool {
        return s.box.position == .absolute or s.box.position == .fixed;
    }

    pub fn floats(s: *const Style) bool {
        return s.box.float != .none and !s.isOutOfFlow();
    }

    /// The used line height in pixels for a font with this ascent and
    /// descent.
    pub fn lineHeightPx(s: *const Style, natural: f32) f32 {
        return switch (s.inh.line_height.kind) {
            .normal => natural,
            .number => s.inh.line_height.value * s.inh.font_size,
            .length => s.inh.line_height.value,
        };
    }

    pub fn borderWidth(s: *const Style, side: usize) f32 {
        return switch (s.box.border_style[side]) {
            .none, .hidden => 0,
            else => s.box.border_width[side],
        };
    }

    pub fn establishesBfc(s: *const Style) bool {
        const d = s.box.display;
        return d.inner == .flow_root or s.floats() or s.isOutOfFlow() or
            (s.box.overflow_x != .visible and s.box.overflow_x != .clip) or
            d.inner == .table_cell or d.inner == .table_caption or (d.outer == .@"inline" and d.inner == .flow_root);
    }
};

/// Hashes and compares styles field by field (floats by bits, pointers
/// by address), so shared styles never depend on padding bytes.
pub fn hash(s: *const Style) u64 {
    var h: std.hash.Wyhash = .init(0);
    hashValue(&h, s.*);
    return h.final();
}

fn hashValue(h: *std.hash.Wyhash, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.backing_integer) |B| {
                h.update(std.mem.asBytes(&@as(B, @bitCast(v))));
                return;
            }
            inline for (info.field_names) |f| hashValue(h, @field(v, f));
        },
        .float => h.update(std.mem.asBytes(&v)),
        .int => h.update(std.mem.asBytes(&v)),
        .bool => h.update(&.{@intFromBool(v)}),
        .@"enum" => h.update(std.mem.asBytes(&@intFromEnum(v))),
        .optional => if (v) |x| {
            h.update(&.{1});
            hashValue(h, x);
        } else h.update(&.{0}),
        .pointer => |p| switch (p.size) {
            .slice => {
                h.update(std.mem.asBytes(&@intFromPtr(v.ptr)));
                h.update(std.mem.asBytes(&v.len));
            },
            else => h.update(std.mem.asBytes(&@intFromPtr(v))),
        },
        .array => for (v) |x| hashValue(h, x),
        else => @compileError("cannot hash " ++ @typeName(T)),
    }
}

pub fn eql(a: *const Style, b: *const Style) bool {
    return eqlValue(a.*, b.*);
}

fn eqlValue(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.backing_integer) |B| return @as(B, @bitCast(a)) == @as(B, @bitCast(b));
            inline for (info.field_names) |f| if (!eqlValue(@field(a, f), @field(b, f))) return false;
            return true;
        },
        .float => return @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(a)) == @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(b)),
        .int, .bool, .@"enum" => return a == b,
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return eqlValue(a.?, b.?);
        },
        .pointer => |p| switch (p.size) {
            .slice => return a.ptr == b.ptr and a.len == b.len,
            else => return a == b,
        },
        .array => {
            for (a, b) |x, y| if (!eqlValue(x, y)) return false;
            return true;
        },
        else => @compileError("cannot compare " ++ @typeName(T)),
    }
}

/// Distinct computed styles of a document, by index. Index 0 is the
/// initial style.
pub const Store = struct {
    styles: std.ArrayList(Style) = .empty,
    map: std.HashMapUnmanaged(u32, void, MapCtx, 80) = .empty,

    pub const Id = u32;

    const MapCtx = struct {
        store: *const Store,
        pub fn hash(c: MapCtx, k: u32) u64 {
            return @import("style.zig").hash(&c.store.styles.items[k]);
        }
        pub fn eql(c: MapCtx, a: u32, b: u32) bool {
            return @import("style.zig").eql(&c.store.styles.items[a], &c.store.styles.items[b]);
        }
    };

    const Adapted = struct {
        store: *const Store,
        pub fn hash(_: Adapted, k: *const Style) u64 {
            return @import("style.zig").hash(k);
        }
        pub fn eql(c: Adapted, a: *const Style, b: u32) bool {
            return @import("style.zig").eql(a, &c.store.styles.items[b]);
        }
    };

    pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!Store {
        var s: Store = .{};
        _ = try s.intern(gpa, &.{});
        return s;
    }

    pub fn deinit(s: *Store, gpa: std.mem.Allocator) void {
        s.styles.deinit(gpa);
        s.map.deinit(gpa);
    }

    pub fn get(s: *const Store, id: Id) *const Style {
        return &s.styles.items[id];
    }

    pub fn intern(s: *Store, gpa: std.mem.Allocator, style: *const Style) error{OutOfMemory}!Id {
        const gop = try s.map.getOrPutContextAdapted(gpa, style, Adapted{ .store = s }, MapCtx{ .store = s });
        if (gop.found_existing) return gop.key_ptr.*;
        const id: u32 = @intCast(s.styles.items.len);
        s.styles.append(gpa, style.*) catch |err| {
            s.map.removeByPtr(gop.key_ptr);
            return err;
        };
        gop.key_ptr.* = id;
        return id;
    }

    pub fn count(s: *const Store) usize {
        return s.styles.items.len;
    }
};

test "interning shares equal styles" {
    const gpa = std.testing.allocator;
    var store = try Store.init(gpa);
    defer store.deinit(gpa);
    var a: Style = .{};
    a.inh.font_size = 20;
    var b: Style = .{};
    b.inh.font_size = 20;
    const ia = try store.intern(gpa, &a);
    const ib = try store.intern(gpa, &b);
    try std.testing.expectEqual(ia, ib);
    b.box.margin[0] = .fixed(3);
    try std.testing.expect(ia != try store.intern(gpa, &b));
    try std.testing.expectEqual(@as(u32, 0), try store.intern(gpa, &.{}));
}
