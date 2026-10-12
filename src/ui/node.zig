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
};

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
    /// left). Clamped to the content at layout.
    offset: Point = .zero,
};

pub const TextAlign = text.layout.Alignment;

pub const Weight = text.fontconfig.Weight;
pub const Slant = text.fontconfig.Slant;

pub const TextStyle = struct {
    /// Family name or generic family; empty uses the window default.
    family: []const u8 = "",
    size: f32 = 14,
    weight: Weight = .regular,
    slant: Slant = .roman,
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

pub const Text = struct {
    style: TextStyle = .{},
    alignment: TextAlign = .start,
    /// Wrap at the available width.
    wrap: bool = true,
};

pub const Fit = enum(u8) { fill, contain, cover, none };

/// How an image node shows its image.
pub const ImageView = struct {
    /// The node holds a reference while it shows the image.
    image: ?*Image = null,
    fit: Fit = .contain,
    filter: scene.Filter = .linear,
    /// Mirror horizontally in right-to-left layouts (directional icons).
    mirror: bool = false,
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
};

/// Stored text: content and style with interned family and language.
pub const TextData = struct {
    content: []const u8 = "",
    props: Text = .{},
    /// Interned `props.style.family` and `language` (Fonts names).
    family: u32 = 0,
    language: u32 = 0,
};

// Events --------------------------------------------------------------------

pub const Button = enum(u8) { primary, secondary, middle, other };

pub const PointerPhase = enum(u8) { down, up, move, enter, leave, cancel };

pub const Mods = @import("platform").Mods;

pub const Pointer = struct {
    phase: PointerPhase,
    /// In the target node's coordinates.
    x: f32,
    y: f32,
    button: Button = .primary,
    mods: Mods = .{},
    /// Presses in quick succession at about the same place: 2 for a double
    /// click, 3 for a triple click (on `down` and `up`).
    clicks: u8 = 1,
    /// Timestamp of the latest pointer button or key input, in
    /// milliseconds (the platform's clock).
    time: u32 = 0,
};

pub const Key = struct {
    /// The input's timestamp in milliseconds.
    time: u32 = 0,
    keysym: u32,
    pressed: bool,
    repeat: bool = false,
    mods: Mods = .{},
    text: []const u8 = "",
};

pub const FocusChange = struct {
    gained: bool,
    /// Focus moved by keyboard, so it should be visible.
    visible: bool,
};

pub const ScrollDelta = struct { dx: f32, dy: f32 };

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
    /// The user edited an editor's text (delivered to the editor only,
    /// after the edit is committed).
    change,
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

pub const Viewport = struct { x: f32, y: f32, width: f32, height: f32 };

/// `select` and `close` are never sent by the tree: widgets built on the C
/// API emit them (`siv_emit`).
pub const HandlerKind = enum(u8) { activate, pointer, key, focus, scroll, change, drop, drag, set_value, select, close, viewport };

/// Runs at a safe point on the UI thread (D5). Returns true when it handled
/// the event, which stops it bubbling and suppresses the default action.
pub const Handler = struct {
    func: *const fn (user: ?*anyopaque, win: *Window, node: NodeId, event: *const Event) bool,
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

    pub const Status = enum(u8) {
        /// On the free list (`next` links it).
        free,
        live,
        /// Removed; recycled after the next frame, so that indices held
        /// during event dispatch never see a reused slot.
        dead,
    };

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
