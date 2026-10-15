//! Node kinds and properties of the retained tree (D4). Every node has the
//! common groups (layout, visual, semantics, handlers) and the data of its
//! kind. Horizontal positions and edges are logical: `start` and `end`
//! follow the node's resolved direction, so an RTL window mirrors (D21).

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const text = @import("text");
const compositor = @import("compositor");
const Window = @import("Window.zig");
const Image = @import("image.zig").Image;
const theme = @import("theme.zig");

pub const ColorToken = theme.ColorToken;
pub const TextRole = theme.TextRole;

pub const Point = raster.Point;
pub const Rect = raster.Rect;
pub const Affine = raster.Affine;
pub const Color = scene.Color;
pub const Transform = compositor.Transform;

/// A node: a plain index into its window's tree (D20).
pub const NodeId = enum(u32) {
    root = 0,
    none = std.math.maxInt(u32),
    _,

    pub fn index(id: NodeId) u32 {
        return @intFromEnum(id);
    }
};

/// The closed set of primitives (D4).
pub const Kind = enum(u8) {
    /// Block flow: children stacked vertically, stretched to its width.
    box,
    /// Children along an axis with gap, grow and shrink, and wrapping.
    flex,
    /// Children in column and row tracks.
    grid,
    /// Children on top of each other, aligned or inset.
    stack,
    /// A paragraph of text. A leaf.
    text,
    /// Editable text with a caret and selection (D15). A leaf.
    editor,
    /// A viewport over block-flow children that scroll on the compositor
    /// thread.
    scroll,
    /// A caller-owned bitmap. A leaf.
    image,
    /// Content the application draws into a display list. A leaf.
    canvas,
    /// Content rendered elsewhere, such as video (D17): frames go to the
    /// compositor, which shows them on a subsurface or composites them.
    /// A leaf.
    external,

    pub fn isLeaf(k: Kind) bool {
        return switch (k) {
            .text, .editor, .image, .canvas, .external => true,
            else => false,
        };
    }

    pub fn defaultRole(k: Kind) Role {
        return switch (k) {
            .box, .flex, .grid, .stack, .canvas => .generic,
            .external => .image,
            .text => .label,
            .editor => .text_input,
            .scroll => .scroll_area,
            .image => .image,
        };
    }
};

/// A preferred size on one axis.
pub const Dimension = union(enum) {
    /// From the content.
    auto,
    /// Logical pixels.
    px: f32,
    /// A fraction of the space the parent offers (its maximum constraint);
    /// auto when that is unbounded.
    fraction: f32,
};

/// Insets on each side. `start` and `end` are logical.
pub const Edges = struct {
    start: f32 = 0,
    end: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    pub fn all(v: f32) Edges {
        return .{ .start = v, .end = v, .top = v, .bottom = v };
    }

    pub fn symmetric(h: f32, v: f32) Edges {
        return .{ .start = h, .end = h, .top = v, .bottom = v };
    }

    pub fn horizontal(e: Edges) f32 {
        return e.start + e.end;
    }

    pub fn vertical(e: Edges) f32 {
        return e.top + e.bottom;
    }

    /// Physical left inset.
    pub fn left(e: Edges, rtl: bool) f32 {
        return if (rtl) e.end else e.start;
    }
};

/// Alignment of a child on one axis. `start` and `end` are logical on the
/// horizontal axis.
pub const Align = enum(u8) {
    /// The container's default.
    auto,
    start,
    center,
    end,
    /// Fill the space on this axis.
    stretch,
};

pub const Direction = enum(u8) { inherit, ltr, rtl };

/// Insets of a positioned stack child; null leaves that side free.
pub const Insets = struct {
    start: ?f32 = null,
    end: ?f32 = null,
    top: ?f32 = null,
    bottom: ?f32 = null,

    pub fn any(i: Insets) bool {
        return i.start != null or i.end != null or i.top != null or i.bottom != null;
    }
};

/// Sizing and placement. Changing it relayouts the node.
pub const Layout = struct {
    width: Dimension = .auto,
    height: Dimension = .auto,
    min_width: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = 0,
    max_height: f32 = std.math.inf(f32),
    padding: Edges = .{},
    direction: Direction = .inherit,
    /// Horizontal alignment in the parent (box, flex column, grid, stack).
    align_x: Align = .auto,
    /// Vertical alignment in the parent (flex row, grid, stack).
    align_y: Align = .auto,
    /// Flex: share of free space to take.
    grow: f32 = 0,
    /// Flex: share of overflow to give up, weighted by the base size.
    shrink: f32 = 1,
    /// Flex: size before growing or shrinking; auto measures the content.
    basis: Dimension = .auto,
    /// Grid: zero-based column and row; null places automatically.
    column: ?u16 = null,
    row: ?u16 = null,
    column_span: u16 = 1,
    row_span: u16 = 1,
    /// Stack: positioned insets from the stack's content box.
    inset: Insets = .{},
};

/// Logical corner radii.
pub const Corners = struct {
    top_start: f32 = 0,
    top_end: f32 = 0,
    bottom_end: f32 = 0,
    bottom_start: f32 = 0,

    pub fn all(r: f32) Corners {
        return .{ .top_start = r, .top_end = r, .bottom_end = r, .bottom_start = r };
    }

    pub fn isZero(c: Corners) bool {
        return c.top_start == 0 and c.top_end == 0 and c.bottom_end == 0 and c.bottom_start == 0;
    }

    pub fn physical(c: Corners, rtl: bool) raster.Radii {
        const tl = if (rtl) c.top_end else c.top_start;
        const tr = if (rtl) c.top_start else c.top_end;
        const br = if (rtl) c.bottom_start else c.bottom_end;
        const bl = if (rtl) c.bottom_end else c.bottom_start;
        return .{ .tl = .{ .x = tl, .y = tl }, .tr = .{ .x = tr, .y = tr }, .br = .{ .x = br, .y = br }, .bl = .{ .x = bl, .y = bl } };
    }
};

/// Appearance. Changing it repaints without layout; changing opacity or
/// transform of a node that already has its own layer only updates that
/// layer's properties.
pub const Visual = struct {
    background: Color = .transparent,
    border_width: f32 = 0,
    border_color: Color = .transparent,
    radius: Corners = .{},
    /// Below 1 gives the node its own compositor layer (D8).
    opacity: f32 = 1,
    /// In components (D8), so the compositor can animate it; the origin is
    /// in the node's coordinates (its top-left corner is 0, 0). A
    /// non-identity transform gives the node its own layer.
    transform: Transform = .identity,
    /// Clip descendants to the node's rounded border box. A clipping node
    /// with layers below it gets its own layer, so its clip applies to them.
    clip: bool = false,
    /// Give the node its own layer, e.g. before animating it.
    layer: bool = false,
    /// Whether pointer events can target the node.
    hit_test: bool = true,
    /// Ask the Wayland compositor to blur what is behind the window under
    /// the node's rounded border box (D31), for a translucent background.
    /// Gives the node its own layer, whose transforms, clips, scrolling,
    /// and animations the blur region follows.
    window_blur: bool = false,
    /// Draw the focus ring when the node has visible keyboard focus.
    focus_ring: bool = true,
    /// Themed colors (D29) that replace `background` and `border_color`
    /// when set, resolved at paint time.
    background_token: ColorToken = .none,
    border_token: ColorToken = .none,
    /// The node and its subtree are not laid out, painted, hit, focused,
    /// or in the semantics tree.
    hidden: bool = false,
    /// Changes to opacity and transform animate over this long on the
    /// compositor (ease-out), unless motion is reduced.
    transition_ms: u32 = 0,
    /// A running animation of one property on the compositor; one that
    /// runs gives the node its own layer.
    animation: Animation = .{},
};

/// An animation the compositor runs on a node's layer (D29): repeating
/// ones such as indeterminate progress cost the UI thread nothing. It
/// runs while the node has a layer and motion is not reduced: hiding the
/// node stops it and showing it starts it again; with reduced motion the
/// node shows its own value.
pub const Animation = struct {
    property: Property = .none,
    /// Values at the start and end of an iteration: opacity, a translation
    /// in pixels (or, if `relative`, in multiples of the node's width or
    /// height), a scale factor, or a clockwise rotation in radians. They
    /// apply on top of the node's own opacity (multiplying it) and
    /// transform; scale and rotation keep the node's center fixed.
    from: f32 = 0,
    to: f32 = 0,
    duration_ms: u32 = 0,
    delay_ms: u32 = 0,
    /// 0 repeats until the animation is replaced or stopped.
    iterations: u32 = 0,
    easing: Easing = .ease,
    /// Every other iteration runs backwards.
    alternate: bool = false,
    relative: bool = false,
    /// Translations along x and rotations flip in right-to-left layouts
    /// (D21).
    mirror: bool = false,

    pub const Property = enum(u8) { none, opacity, translate_x, translate_y, scale, rotate };
    pub const Easing = enum(u8) { ease, linear, ease_in, ease_out, ease_in_out };
};

/// Accessibility roles (D18). Every node has one; primitives default to
/// `Kind.defaultRole`.
pub const Role = enum(u8) {
    /// Purely presentational: left out of the semantics tree, with its
    /// children promoted.
    none,
    /// A container without meaning of its own. Left out of the semantics
    /// tree, with its children promoted, unless it is focusable or labelled.
    generic,
    window,
    group,
    label,
    paragraph,
    heading,
    link,
    button,
    toggle_button,
    checkbox,
    radio,
    @"switch",
    text_input,
    image,
    scroll_area,
    list,
    list_item,
    tree,
    tree_item,
    table,
    row,
    cell,
    column_header,
    tab_list,
    tab,
    tab_panel,
    menu,
    menu_bar,
    menu_item,
    toolbar,
    dialog,
    alert,
    status,
    tooltip,
    slider,
    spin_button,
    progress_bar,
    separator,
    combo_box,
    canvas,
    document,
};

pub const Toggle = enum(u8) { unset, off, on, mixed };

pub const Live = enum(u8) { off, polite, assertive };

/// A numeric value (sliders, progress). `step` is the smallest change
/// the widget makes, or 0 for any.
pub const Range = struct { min: f64 = 0, max: f64 = 1, now: f64 = 0, step: f64 = 0 };

/// What assistive technology sees, and keyboard behavior. Strings are
/// copied.
pub const Semantics = struct {
    role: ?Role = null,
    /// Accessible name. Empty derives it: text nodes use their text, and
    /// buttons, links, and other named roles use their descendants' text.
    label: []const u8 = "",
    description: []const u8 = "",
    /// Takes keyboard focus (Tab order is tree order).
    focusable: bool = false,
    /// Not focusable or activatable.
    disabled: bool = false,
    checked: Toggle = .unset,
    pressed: Toggle = .unset,
    selected: Toggle = .unset,
    expanded: Toggle = .unset,
    value: ?Range = null,
    live: Live = .off,
    /// Heading level, or a tree item's depth (1 is the top); 0 for none.
    level: u8 = 0,
    /// While shown, input and focus stay inside it (dialogs).
    modal: bool = false,
    /// An item's 1-based position among its set and the set's size, for
    /// items whose siblings are not all in the tree (virtualized views);
    /// 0 for none.
    position: u32 = 0,
    set_size: u32 = 0,
    /// A table row's 1-based index among all rows; 0 for none.
    row: u32 = 0,
    /// A column header's sort order.
    sort: Sort = .none,
    /// A cell's or column header's 1-based column; 0 for none.
    column: u32 = 0,
};

pub const Sort = enum(u8) { none, ascending, descending };

pub const Axis = enum(u8) { row, column };

pub const Justify = enum(u8) { start, center, end, space_between, space_around, space_evenly };

pub const Flex = struct {
    axis: Axis = .row,
    gap: f32 = 0,
    /// Gap between wrapped lines; null uses `gap`.
    line_gap: ?f32 = null,
    justify: Justify = .start,
    /// Cross-axis alignment of children whose own alignment is auto.
    align_items: Align = .stretch,
    wrap: bool = false,
};

pub const Track = union(enum) {
    /// Logical pixels.
    px: f32,
    /// A share of the remaining space.
    fr: f32,
    /// The largest content of its items.
    auto,
};

pub const Grid = struct {
    /// Tracks are copied. Items beyond them get auto tracks.
    columns: []const Track = &.{},
    rows: []const Track = &.{},
    column_gap: f32 = 0,
    row_gap: f32 = 0,
    /// Defaults for children whose alignment is auto.
    align_x: Align = .stretch,
    align_y: Align = .stretch,
};

pub const Stack = struct {
    align_x: Align = .start,
    align_y: Align = .start,
};

pub const ScrollAxis = enum(u8) { vertical, horizontal, both };

pub const Scroll = struct {
    axis: ScrollAxis = .vertical,
    /// Distance scrolled from the start (logical: in RTL, x grows to the
    /// left), in zoomed pixels. Clamped to the content at layout.
    offset: Point = .zero,
    /// Zoom range for pinches and Ctrl+wheel (D16); equal values (the
    /// default) never zoom.
    min_zoom: f32 = 1,
    max_zoom: f32 = 1,
    /// Scale of the content about the viewport's top-left corner, within
    /// the range. The compositor changes it for pinches (D8).
    zoom: f32 = 1,

    pub fn zoomable(s: Scroll) bool {
        return s.max_zoom > s.min_zoom;
    }
};

pub const TextAlign = text.layout.Alignment;

pub const Weight = text.fontconfig.Weight;
pub const Slant = text.fontconfig.Slant;
pub const Width = text.fontconfig.Width;

/// The CSS weight a style and its span's weight ask for.
pub fn cssWeight(style: TextStyle, span: ?Weight) u16 {
    if (span) |w| return @intFromFloat(w.css());
    return if (style.weight_value != 0) style.weight_value else @intFromFloat(style.weight.css());
}

pub const TextStyle = struct {
    /// Family name or generic family; empty uses the window default.
    family: []const u8 = "",
    size: f32 = 14,
    weight: Weight = .regular,
    /// A CSS weight (1..1000) replacing `weight`, for variable fonts; 0
    /// uses `weight`.
    weight_value: u16 = 0,
    slant: Slant = .roman,
    width: Width = .normal,
    color: Color = .black,
    /// BCP 47 language for shaping and font fallback (D21); empty uses the
    /// window's.
    language: []const u8 = "",
    /// A themed color (D29) replacing `color` when set.
    color_token: ColorToken = .none,
    /// A themed size relative to the desktop font, replacing `size` unless
    /// `fixed`.
    size_role: TextRole = .fixed,
};

pub const ParagraphStyle = text.layout.ParagraphStyle;

pub const Text = struct {
    style: TextStyle = .{},
    alignment: TextAlign = .start,
    /// Wrap at the available width.
    wrap: bool = true,
    /// Break inside a word too wide for a line of its own.
    break_words: bool = false,
    /// Paragraph defaults (D13); paragraph spans override them. Its
    /// alignment stays null: `alignment` is the node's.
    paragraph: ParagraphStyle = .{},
    /// Tab stops from the start margin, increasing. Owned by the tree.
    tab_stops: []const TabStop = &.{},
    /// Break words at their language's hyphenation points (D13).
    hyphenate: bool = false,
    /// Knuth and Plass's total-fit line breaking, for document views.
    optimal: bool = false,
    /// At most this many lines show; 0 is unlimited (text nodes only).
    max_lines: u32 = 0,
    /// A line cut short (past `max_lines`, or too wide without wrapping)
    /// ends with an ellipsis (text nodes only).
    ellipsize: bool = false,
    /// The base direction of the text's paragraphs: from their first
    /// strong character (falling back to the node's direction), or set,
    /// which isolates the text from the node's direction without marks
    /// in the text. Alignment still follows the node (D21).
    direction: TextDirection = .auto,

    /// Whether lines depend on the exact width they were laid out at, so
    /// a layout built for another width cannot serve.
    pub fn exactWidth(t: Text, paragraphs: []const ParagraphSpan) bool {
        if (t.alignment == .justify or t.optimal) return true;
        for (paragraphs) |sp| if (sp.style.alignment == .justify) return true;
        return false;
    }
};

pub const TabStop = text.layout.TabStop;

pub const TextDirection = enum(u8) { auto, ltr, rtl };

pub const Fit = enum(u8) { fill, contain, cover, none };

/// How an image node shows its image.
pub const ImageView = struct {
    /// The node holds a reference while it shows the image.
    image: ?*Image = null,
    fit: Fit = .contain,
    filter: scene.Filter = .linear,
    /// Mirror horizontally in right-to-left layouts (directional icons).
    mirror: bool = false,
    /// A themed icon shown instead of `image` (D19): its name, or several
    /// names one per line, the first the theme has winning. Owned by the
    /// tree; empty for none. The icon follows the theme and the window's
    /// scale and direction, and is looked up and loaded on the worker
    /// pool: until it arrives the node takes its space and shows nothing.
    icon: []const u8 = "",
    /// The icon's logical size (it is square); 0 is 16.
    icon_size: f32 = 0,
    /// The foreground of symbolic icons and of vector images whose colors
    /// follow the theme (D19, D29): the token if set, else the literal
    /// color, else (transparent) the window's text color.
    color: scene.Color = .transparent,
    color_token: ColorToken = .none,

    /// The node's intrinsic size, before an icon or image arrives.
    pub fn intrinsic(v: ImageView) ?[2]f32 {
        if (v.icon.len != 0) {
            const s = if (v.icon_size > 0) v.icon_size else 16;
            return .{ s, s };
        }
        return if (v.image) |img| img.logicalSize() else null;
    }
};

pub const Canvas = struct {
    /// Draws the content in the node's coordinates (0, 0)–(width, height).
    /// Runs on the UI thread in the frame phase while the node's layer
    /// repaints, so it must not change the tree. On error the node draws
    /// nothing.
    draw: ?*const fn (user: ?*anyopaque, win: *Window, node: NodeId, b: *scene.Builder, width: f32, height: f32) scene.Error!void = null,
    /// Sizes the content within the constraints during layout (maxima may
    /// be infinite); the result is clamped to them. Null uses `width` and
    /// `height`. Must not change the tree. `Txn.remeasure` asks again.
    measure: ?*const fn (user: ?*anyopaque, win: *Window, node: NodeId, min_w: f32, max_w: f32, min_h: f32, max_h: f32) CanvasSize = null,
    user: ?*anyopaque = null,
    /// Intrinsic size without `measure`.
    width: f32 = 0,
    height: f32 = 0,
    /// A canvas taller than four viewports of its scroll container draws
    /// only around what shows, as long texts paint (D8): `draw` reads the
    /// band from `State.painted_band` (null: everything), and scrolling
    /// out of it draws again. For content much taller than the screen,
    /// such as documents (D32).
    banded: bool = false,
    /// Adds the content's own accessible objects below the node (D18,
    /// D32), in node coordinates.
    semantics: ?*const fn (user: ?*anyopaque, win: *Window, node: NodeId, out: *@import("semantics.zig").Virtual) error{OutOfMemory}!void = null,
};

pub const CanvasSize = struct { width: f32 = 0, height: f32 = 0 };

/// Kind-specific data. Text content and grid tracks are owned by the tree.
pub const Data = union(Kind) {
    box: void,
    flex: Flex,
    grid: Grid,
    stack: Stack,
    text: TextData,
    editor: EditorData,
    scroll: Scroll,
    image: ImageView,
    canvas: Canvas,
    external: External,

    pub fn default(kind: Kind) Data {
        return switch (kind) {
            inline else => |k| @unionInit(Data, @tagName(k), if (@FieldType(Data, @tagName(k)) == void) {} else .{}),
        };
    }
};

pub const External = struct {
    /// From `compositor.Compositor.createExternal` for this window; 0
    /// shows nothing.
    id: u32 = 0,
    /// Intrinsic size (the content's aspect ratio).
    width: f32 = 0,
    height: f32 = 0,
    fit: Fit = .contain,
    /// Fills the content box behind the content (D17).
    background: scene.Color = .transparent,
};

pub const Editor = struct {
    /// Enter inserts a line break and lines wrap; otherwise one line that
    /// scrolls horizontally to keep the caret visible.
    multiline: bool = false,
    /// A password field: the text lives in locked memory excluded from
    /// core dumps (`Window.secretOf`), shows as one bullet per code point,
    /// has no undo or input method, and is hidden from assistive
    /// technology.
    masked: bool = false,
    /// The application keeps the undo history: no steps are recorded,
    /// and the undo keys bubble on.
    no_undo: bool = false,
    /// The caret covers the character after it.
    block_caret: bool = false,
    /// The input method stays disabled while the editor has focus.
    no_input_method: bool = false,
};

/// An editor's text, settings, and selection (byte offsets at grapheme
/// boundaries; the caret is `caret`, the selection runs to `anchor`).
pub const EditorData = struct {
    text: TextData = .{},
    editor: Editor = .{},
    caret: u32 = 0,
    anchor: u32 = 0,
    /// Which side of a bidi or wrap boundary the caret is drawn on.
    affinity: text.layout.Affinity = .downstream,
    /// Counts text changes, so undo history knows when the application
    /// replaced the text underneath it.
    revision: u32 = 0,
    /// Masked: the real text, in locked memory. `text.content` holds the
    /// bullets that are shaped and displayed, and offsets index those.
    secret: []const u8 = "",
    /// Shown, in the muted color, while the text is empty.
    placeholder: []const u8 = "",
    /// The style typed text takes (a formatting command with nothing
    /// selected), until the caret moves; null takes the style of the
    /// character before the caret.
    typing: ?SpanStyle = null,
};

/// Stored text: content and style with interned family and language.
pub const TextData = struct {
    /// The text's bytes, a rope shared with the texts edits made from it
    /// (D15): an edit costs the edit, not the text.
    content: text.Rope = .{},
    props: Text = .{},
    /// Interned `props.style.family` and `language` (Fonts names).
    family: u32 = 0,
    language: u32 = 0,
    /// Styled ranges over `props.style` (D22's styled text): sorted, not
    /// overlapping, not empty, at character boundaries, none with the
    /// default style, and neighbors with equal styles merged.
    spans: []const Span = &.{},
    /// Paragraph styles over `props.paragraph`, kept like `spans` and
    /// covering whole paragraphs (each separator with the paragraph it
    /// ends).
    paragraphs: []const ParagraphSpan = &.{},
};

/// What a span changes in its node's style; null and false keep the
/// node's.
pub const SpanStyle = struct {
    /// An interned family name (`Fonts.intern`); 0 is the default family.
    family: ?u32 = null,
    weight: ?Weight = null,
    slant: ?Slant = null,
    width: ?Width = null,
    /// Logical pixels, scaled like the node's size by the desktop's text
    /// scale.
    size: ?f32 = null,
    color: ?Color = null,
    /// A themed color (D29), replacing `color`.
    color_token: ColorToken = .none,
    underline: bool = false,
    strikethrough: bool = false,

    pub fn isDefault(s: SpanStyle) bool {
        return std.meta.eql(s, SpanStyle{});
    }

    pub fn eql(a: SpanStyle, b: SpanStyle) bool {
        return std.meta.eql(a, b);
    }

    /// Which attributes a style change sets.
    pub const Mask = packed struct(u8) {
        weight: bool = false,
        slant: bool = false,
        size: bool = false,
        color: bool = false,
        underline: bool = false,
        strikethrough: bool = false,
        family: bool = false,
        width: bool = false,
    };

    /// `s` with the attributes in `mask` taken from `values`.
    pub fn patched(s: SpanStyle, values: SpanStyle, mask: Mask) SpanStyle {
        var out = s;
        if (mask.weight) out.weight = values.weight;
        if (mask.slant) out.slant = values.slant;
        if (mask.size) out.size = values.size;
        if (mask.color) {
            out.color = values.color;
            out.color_token = values.color_token;
        }
        if (mask.underline) out.underline = values.underline;
        if (mask.strikethrough) out.strikethrough = values.strikethrough;
        if (mask.family) out.family = values.family;
        if (mask.width) out.width = values.width;
        return out;
    }
};

/// What a paragraph span changes in its node's paragraph style (D13);
/// null keeps the node's.
pub const ParagraphPatch = struct {
    alignment: ?TextAlign = null,
    indent: ?Indent = null,
    spacing: ?Spacing = null,
    gaps: ?Gaps = null,
    tab_width: ?f32 = null,

    pub const Indent = struct { start: f32 = 0, end: f32 = 0, first_line: f32 = 0 };
    pub const Spacing = struct { line_spacing: f32 = 1, line_height: f32 = 0 };
    pub const Gaps = struct { before: f32 = 0, after: f32 = 0 };

    pub fn isDefault(s: ParagraphPatch) bool {
        return std.meta.eql(s, ParagraphPatch{});
    }

    pub fn eql(a: ParagraphPatch, b: ParagraphPatch) bool {
        return std.meta.eql(a, b);
    }

    pub const Mask = packed struct(u8) {
        alignment: bool = false,
        indent: bool = false,
        spacing: bool = false,
        gaps: bool = false,
        tab_width: bool = false,
        _: u3 = 0,
    };

    pub fn patched(s: ParagraphPatch, values: ParagraphPatch, mask: Mask) ParagraphPatch {
        var out = s;
        inline for (.{ "alignment", "indent", "spacing", "gaps", "tab_width" }) |name| {
            if (@field(mask, name)) @field(out, name) = @field(values, name);
        }
        return out;
    }

    /// `base` with the patch's attributes.
    pub fn apply(s: ParagraphPatch, base: ParagraphStyle) ParagraphStyle {
        var out = base;
        if (s.alignment) |a| out.alignment = a;
        if (s.indent) |i| {
            out.indent_start = i.start;
            out.indent_end = i.end;
            out.first_line_indent = i.first_line;
        }
        if (s.spacing) |sp| {
            out.line_spacing = sp.line_spacing;
            out.line_height = sp.line_height;
        }
        if (s.gaps) |g| {
            out.space_before = g.before;
            out.space_after = g.after;
        }
        if (s.tab_width) |w| out.tab_width = w;
        return out;
    }
};

pub const ParagraphSpan = struct {
    start: u32,
    end: u32,
    style: ParagraphPatch,
};

pub const Span = struct {
    start: u32,
    end: u32,
    style: SpanStyle,
};

// Events --------------------------------------------------------------------

/// Back and forward are the side buttons of a mouse (evdev BTN_SIDE or
/// BTN_BACK, and BTN_EXTRA or BTN_FORWARD).
pub const Button = enum(u8) { primary, secondary, middle, other, back, forward };

pub const PointerPhase = enum(u8) { down, up, move, enter, leave, cancel };

pub const Mods = @import("platform").Mods;

pub const Pointer = struct {
    phase: PointerPhase,
    /// In the target node's coordinates.
    x: f32,
    y: f32,
    button: Button = .primary,
    /// Down and up: the button's evdev code (BTN_LEFT is 0x110), for
    /// buttons beyond those named.
    code: u32 = 0,
    mods: Mods = .{},
    /// Presses in quick succession at about the same place: 2 for a double
    /// click, 3 for a triple click (on `down` and `up`).
    clicks: u8 = 1,
    /// Timestamp of the latest pointer button or key input, in
    /// milliseconds (the platform's clock).
    time: u32 = 0,
    /// The node the event was delivered to first, before bubbling.
    target: NodeId = .none,
    /// A handler on the way here prevented the default action.
    prevented: bool = false,
    /// Relative motion (D16), from the device rather than the pointer's
    /// position, also while the pointer is locked: `dx` and `dy`
    /// accelerated, `raw_dx` and `raw_dy` as the device reported them.
    relative: bool = false,
    dx: f32 = 0,
    dy: f32 = 0,
    raw_dx: f32 = 0,
    raw_dy: f32 = 0,
};

pub const Key = struct {
    /// The input's timestamp in milliseconds.
    time: u32 = 0,
    keysym: u32,
    /// The XKB keycode (evdev code + 8) of the physical key, in the
    /// compositor's keymap; 0 for keys siv makes up (siv_test_key).
    keycode: u32 = 0,
    pressed: bool,
    repeat: bool = false,
    mods: Mods = .{},
    text: []const u8 = "",
    /// The node the event was delivered to first (the focused node).
    target: NodeId = .none,
    /// A handler on the way here prevented the default action.
    prevented: bool = false,
    /// Delivered to a `key_capture` handler, on the way down.
    capture: bool = false,
    /// A capture handler stopped the key's propagation: the nodes on the
    /// way up run only their default handlers.
    stopped: bool = false,
};

pub const FocusChange = struct {
    gained: bool,
    /// Focus moved by keyboard, so it should be visible.
    visible: bool,
};

pub const ScrollDelta = struct {
    /// The distance siv scrolls for it (`platform.Scroll.delta`, D16).
    dx: f32,
    dy: f32,
    target: NodeId = .none,
    prevented: bool = false,
    /// The input as the compositor sent it, for widgets that scroll by
    /// their own rules (a web engine's line steps and kinetic scrolling):
    /// the distance in logical pixels, wheel steps (1 a detent, fractions
    /// for high-resolution wheels), the device, and whether the fingers
    /// left the touchpad or the wheel stopped (kinetic scrolling starts).
    raw_dx: f32 = 0,
    raw_dy: f32 = 0,
    steps_x: f32 = 0,
    steps_y: f32 = 0,
    source: @import("platform").ScrollSource = .unknown,
    stop: bool = false,
};

/// An input method's edit of a custom text widget (D15): delete around
/// the cursor, then insert `commit`, then show `preedit` (with its cursor
/// range in bytes; both -1 hide it). The widget applies it.
pub const ImeEdit = struct {
    commit: []const u8 = "",
    preedit: []const u8 = "",
    cursor_begin: i32 = 0,
    cursor_end: i32 = 0,
    delete_before: u32 = 0,
    delete_after: u32 = 0,
};

/// A custom widget's text as the input method should see it while the
/// node has focus (`siv_set_text_input`, D15).
pub const TextInput = struct {
    enabled: bool = false,
    /// Text around the cursor (owned); byte offsets into it.
    surrounding: []const u8 = "",
    cursor: u32 = 0,
    anchor: u32 = 0,
    hint: @import("platform").ContentHint = .{},
    purpose: @import("platform").ContentPurpose = .normal,
    /// The caret in the node's coordinates.
    cursor_rect: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
};

pub const TouchPhase = enum { down, move, up, cancel };

/// One touch point of a sequence that began on a node with a touch
/// handler (D16), in that node's coordinates.
pub const Touch = struct {
    phase: TouchPhase,
    /// Tells the sequences of simultaneous touches apart.
    id: i32,
    x: f32 = 0,
    y: f32 = 0,
    time: u32 = 0,
    mods: Mods = .{},
};

pub const ToolKind = @import("platform").ToolKind;
pub const ToolAxes = @import("platform").ToolAxes;
pub const PadControl = @import("platform").PadControl;

/// One position of a tablet tool, in the node's coordinates. Laid out as
/// `siv_tablet_sample`, so the C API passes samples without a copy.
pub const TabletSample = extern struct {
    x: f32,
    y: f32,
    /// 0 to 1.
    pressure: f32 = 0,
    /// 0 (touching) to 1.
    distance: f32 = 0,
    /// Degrees from the perpendicular.
    tilt_x: f32 = 0,
    tilt_y: f32 = 0,
    /// Degrees clockwise.
    rotation: f32 = 0,
    /// -1 to 1.
    slider: f32 = 0,
    /// Degrees the wheel turned since the previous sample.
    wheel: f32 = 0,
    time: u32 = 0,
    /// `siv_tablet_sample`'s reserved fields: zero.
    reserved: [4]u32 = @splat(0),
};

/// A tablet tool over the window (D16). Phases as for pointers: enter and
/// leave for proximity, down and up for the tip (button primary) and the
/// tool's buttons (secondary, middle, other), move for motion. Motion is
/// delivered once per frame with every sample since the last move.
pub const Tablet = struct {
    phase: PointerPhase,
    button: Button = .primary,
    tool: ToolKind = .pen,
    /// Distinguishes tools on a seat while they exist.
    tool_id: u32 = 0,
    /// The tool's hardware serial number; 0 if unknown.
    serial_number: u64 = 0,
    axes: ToolAxes = .{},
    /// The tool's state now, in the node's coordinates.
    sample: TabletSample,
    /// Move: every sample since the last move event, oldest first, the
    /// last being `sample`. Other phases: `sample` alone.
    samples: []const TabletSample = &.{},
    /// The wheel turned since the last event (its samples' sum): degrees
    /// and detents.
    wheel: f32 = 0,
    wheel_clicks: i32 = 0,
    /// The tip touches the tablet.
    tip: bool = false,
    mods: Mods = .{},
    time: u32 = 0,
    target: NodeId = .none,
    prevented: bool = false,
};

/// A tablet pad's button, ring, strip, dial, or mode switch (D16), from
/// the focused node up like a key.
pub const Pad = struct {
    control: PadControl,
    index: u32 = 0,
    group: u32 = 0,
    mode: u32 = 0,
    value: f64 = 0,
    pressed: bool = false,
    /// Rings and strips: the finger left the control.
    lifted: bool = false,
    time: u32 = 0,
    target: NodeId = .none,
    prevented: bool = false,
};

pub const GestureKind = @import("platform").GestureKind;
pub const GesturePhase = enum(u8) { begin, update, end, cancel };

/// A touchpad gesture the compositor left to the UI (D8, D16): over a
/// node with a gesture or scroll handler, with a modifier held, or with
/// nothing to zoom; swipes and holds always.
pub const Gesture = struct {
    kind: GestureKind,
    phase: GesturePhase,
    fingers: u32 = 0,
    /// The pointer, in the target node's coordinates.
    x: f32 = 0,
    y: f32 = 0,
    /// Swipe and pinch: motion of the fingers' center since the last
    /// event, in logical pixels.
    dx: f32 = 0,
    dy: f32 = 0,
    /// Pinch: the fingers' distance relative to the start.
    scale: f32 = 1,
    /// Pinch: rotation since the last event, degrees clockwise.
    rotation: f32 = 0,
    mods: Mods = .{},
    time: u32 = 0,
    target: NodeId = .none,
    prevented: bool = false,
};

/// A pointer cursor shape (D16).
pub const CursorShape = @import("platform").CursorShape;

pub const DragAction = @import("platform").DragAction;
pub const DragActions = @import("platform").DragActions;

/// Makes a node a drop target (D19): drags carrying one of its mime types
/// with one of its actions go to its `drop` handler.
pub const DropTarget = struct {
    /// Mime types it takes, one per line, preferred first (copied). Empty
    /// makes the node no drop target.
    mimes: []const u8 = "",
    actions: DragActions = .{ .copy = true },
    /// The action to ask for when the source offers several; none takes
    /// the first of copy, move, and ask that both sides allow.
    preferred: DragAction = .none,

    /// The first of the target's mime types that `offered` contains (the
    /// element of `offered`).
    pub fn match(t: DropTarget, offered: []const []const u8) ?[]const u8 {
        var it = std.mem.tokenizeScalar(u8, t.mimes, '\n');
        while (it.next()) |m| for (offered) |o| if (std.mem.eql(u8, o, m)) return o;
        return null;
    }
};

pub const DropPhase = enum(u8) {
    /// The drag moved onto the node. Return true to take it here.
    enter,
    /// The drag moved over the node, or its action changed. Return true
    /// to take it here.
    move,
    /// The drag left the node, was dropped elsewhere, or the data could
    /// not be read.
    leave,
    /// The data was dropped on the node: `data` holds it. Return true if
    /// the node took it.
    drop,
};

/// A drag over a drop target (`DropTarget`).
pub const Drop = struct {
    phase: DropPhase,
    /// In the node's coordinates.
    x: f32,
    y: f32,
    /// The action negotiated with the source; on `drop` with `ask` the
    /// application asks the user and calls `Window.finishDrop`.
    action: DragAction = .none,
    /// The actions the source offers.
    source_actions: DragActions = .{},
    /// The mime type the node gets, the first of its own the drag offers.
    mime: []const u8 = "",
    /// `drop`: the data, valid during the call.
    data: []const u8 = "",
    /// The keyboard modifiers held.
    mods: @import("platform").Mods = .{},
};

pub const DragPhase = enum(u8) {
    /// The target under the pointer took or refused the data, or the
    /// action changed.
    move,
    /// The user dropped the data on a target that takes it.
    drop,
    /// The drag ended: the target performed `action`; none if the drag was
    /// cancelled or refused. After a move, delete the data.
    end,
};

/// Progress of a drag a node started (`Window.startDrag`).
pub const Drag = struct {
    phase: DragPhase,
    action: DragAction = .none,
    /// `move`: the target under the pointer takes the data.
    accepted: bool = false,
};

pub const Event = union(enum) {
    /// Clicked, or Enter/Space while focused.
    activate,
    pointer: Pointer,
    key: Key,
    focus: FocusChange,
    scroll: ScrollDelta,
    gesture: Gesture,
    tablet: Tablet,
    pad: Pad,
    touch: Touch,
    text_input: ImeEdit,
    /// The user edited an editor's text (delivered to the editor only,
    /// after the edit is committed).
    change: Change,
    /// A drag over a drop target (not bubbled).
    drop: Drop,
    /// A drag the node started progressed (not bubbled).
    drag: Drag,
    /// Assistive technology asks for a new value of a node with a range
    /// (delivered to the node only). The handler applies it, or not.
    set_value: f64,
    /// A scroll node's visible region changed: its logical offset or its
    /// viewport's size (delivered to the node only, at a safe point after
    /// the compositor scrolled it or at the start of the frame after
    /// layout changed it).
    viewport: Viewport,
};

/// What an edit replaced: `start..end` of the old text by `length` bytes
/// of the new. All zero for a change of styles only, and in masked
/// editors.
pub const Change = struct { start: u32 = 0, end: u32 = 0, length: u32 = 0 };

/// The visible content is the rectangle (x, y, width, height) divided by
/// `zoom`.
pub const Viewport = struct { x: f32, y: f32, width: f32, height: f32, zoom: f32 = 1 };

/// `select`, `close`, and `sort` are never sent by the tree: widgets built
/// on the C API emit them (`siv_node_emit`).
/// The kinds of node handlers. The first eighteen match `siv_event_type`;
/// `key_capture` holds a node's capture-phase key handler (D16), which
/// sees keys on their way down to the focused node.
pub const HandlerKind = enum(u8) { activate, pointer, key, focus, scroll, change, drop, drag, set_value, select, close, viewport, sort, gesture, tablet, pad, touch, text_input, key_capture };

/// What a handler did with an event: whether it stops bubbling and
/// whether it prevents the default action (later default handlers and the
/// tree's own default actions). The values match `siv_event_result`.
pub const Result = enum(u2) {
    pass,
    handled,
    stop,
    prevent,

    pub fn stops(r: Result) bool {
        return r == .handled or r == .stop;
    }

    pub fn prevents(r: Result) bool {
        return r == .handled or r == .prevent;
    }

    pub fn of(stop: bool, prevent: bool) Result {
        if (stop) return if (prevent) .handled else .stop;
        return if (prevent) .prevent else .pass;
    }
};

/// Runs at a safe point on the UI thread (D5).
pub const Handler = struct {
    func: *const fn (user: ?*anyopaque, win: *Window, node: NodeId, event: *const Event) Result,
    user: ?*anyopaque = null,
};

pub const handler_count = @typeInfo(HandlerKind).@"enum".field_names.len;

/// A node's committed state.
pub const Node = struct {
    kind: Kind,
    status: Status = .live,
    parent: NodeId = .none,
    first: NodeId = .none,
    last: NodeId = .none,
    next: NodeId = .none,
    prev: NodeId = .none,
    layout: Layout = .{},
    visual: Visual = .{},
    semantics: Semantics = .{},
    data: Data,
    handlers: [handler_count]?Handler = @splat(null),
    drop: DropTarget = .{},
    /// The pointer cursor over the node and its descendants that set
    /// none; null inherits (editors show the text cursor).
    cursor: ?CursorShape = null,
    /// Text shown in a tooltip when the pointer rests on the node or the
    /// keyboard focuses it (D17), and its accessible description unless
    /// it repeats the name; empty for none. Owned.
    tooltip: []const u8 = "",
    /// Hidden by the application (`siv_set_hidden`), apart from the
    /// visual's own `hidden`, so that hiding a widget never replaces the
    /// visual it draws itself with. Either one hides the subtree.
    hidden: bool = false,
    /// A custom text widget's state for the input method.
    text_input: TextInput = .{},
    /// Another process's accessible object shown as the node's last
    /// accessible child (D18): "BUS_NAME:/object/path". Owned; empty for
    /// none.
    a11y_embed: []const u8 = "",

    pub const Status = enum(u8) {
        /// On the free list (`next` links it).
        free,
        live,
        /// Removed; recycled after the next frame, so that indices held
        /// during event dispatch never see a reused slot.
        dead,
    };

    /// Hidden by its visual or by the application: not laid out, painted,
    /// hit, focused, or in the semantics tree, with its subtree.
    pub fn isHidden(n: *const Node) bool {
        return n.visual.hidden or n.hidden;
    }

    pub fn role(n: *const Node) Role {
        return n.semantics.role orelse n.kind.defaultRole();
    }

    pub fn handler(n: *const Node, kind: HandlerKind) ?Handler {
        return n.handlers[@intFromEnum(kind)];
    }

    /// The text of a text or editor node.
    pub fn textData(n: anytype) switch (@TypeOf(n)) {
        *Node => *TextData,
        else => *const TextData,
    } {
        return switch (n.kind) {
            .text => &n.data.text,
            .editor => &n.data.editor.text,
            else => unreachable,
        };
    }

    pub fn isText(n: *const Node) bool {
        return n.kind == .text or n.kind == .editor;
    }

    /// Takes keyboard focus: focusable nodes and editors, unless disabled.
    pub fn canFocus(n: *const Node) bool {
        return (n.semantics.focusable or n.kind == .editor) and !n.semantics.disabled;
    }
};

test "default data matches kinds" {
    inline for (@typeInfo(Kind).@"enum".field_values) |v| {
        const k: Kind = @enumFromInt(v);
        try std.testing.expectEqual(k, std.meta.activeTag(Data.default(k)));
    }
}
