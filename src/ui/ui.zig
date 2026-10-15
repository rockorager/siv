//! The retained UI on the UI thread (D4, D8, D18, D21): a tree of the
//! closed primitive set changed through atomic transactions, one-way
//! constraint layout with per-node caches, text nodes on the text engine,
//! hit testing, pointer and keyboard routing, focus, a mandatory semantics
//! tree, RTL mirroring, and lowering into layers for the compositor thread.
//!
//!     var win = try ui.Window.init(gpa, .{ .fonts = &fonts, .sink = sink });
//!     const t = try win.begin();
//!     const row = try t.create(.root, .flex, .none);
//!     try t.setFlex(row, .{ .gap = 8 });
//!     const label = try t.create(row, .text, .none);
//!     try t.setText(label, "Hello");
//!     t.commit();
//!
//! Nodes are plain indices (D20); ABI handles wrap them in src/abi.
//!
//! Imports: scene, svg, icon, raster, text, image, loop, platform,
//! compositor.

const std = @import("std");

const node = @import("node.zig");
pub const NodeId = node.NodeId;
pub const Kind = node.Kind;
pub const Node = node.Node;
pub const Dimension = node.Dimension;
pub const Edges = node.Edges;
pub const Align = node.Align;
pub const Direction = node.Direction;
pub const Insets = node.Insets;
pub const TabletSample = node.TabletSample;
pub const ToolKind = node.ToolKind;
pub const PadControl = node.PadControl;
pub const Layout = node.Layout;
pub const Corners = node.Corners;
pub const Visual = node.Visual;
pub const Animation = node.Animation;
pub const Span = node.Span;
pub const SpanStyle = node.SpanStyle;
pub const ParagraphSpan = node.ParagraphSpan;
pub const ParagraphPatch = node.ParagraphPatch;
pub const ParagraphStyle = node.ParagraphStyle;
pub const TextData = node.TextData;
pub const Transform = node.Transform;
pub const Role = node.Role;
pub const Toggle = node.Toggle;
pub const Live = node.Live;
pub const Sort = node.Sort;
pub const Range = node.Range;
pub const Semantics = node.Semantics;
pub const TextInput = node.TextInput;
pub const Axis = node.Axis;
pub const Justify = node.Justify;
pub const Flex = node.Flex;
pub const Track = node.Track;
pub const Grid = node.Grid;
pub const Stack = node.Stack;
pub const ScrollAxis = node.ScrollAxis;
pub const Scroll = node.Scroll;
pub const TextAlign = node.TextAlign;
pub const TextStyle = node.TextStyle;
pub const FontWidth = node.Width;
pub const TabStop = node.TabStop;
pub const cssWeight = node.cssWeight;
pub const Text = node.Text;
pub const Fit = node.Fit;
pub const Image = @import("image.zig").Image;
pub const Icons = @import("icons.zig");
/// The colors symbolic icons take from a palette (D19).
pub const iconColors = @import("paint.zig").iconColors;
pub const Player = @import("image.zig").Player;
pub const ImageView = node.ImageView;
pub const Canvas = node.Canvas;
pub const CanvasSize = node.CanvasSize;
pub const Editor = node.Editor;
pub const External = node.External;
pub const Event = node.Event;
pub const HandlerKind = node.HandlerKind;
pub const Handler = node.Handler;
pub const HandlerResult = node.Result;
pub const Pointer = node.Pointer;
pub const Key = node.Key;
pub const CursorShape = node.CursorShape;
pub const DropTarget = node.DropTarget;
pub const Drop = node.Drop;
pub const DropPhase = node.DropPhase;
pub const Drag = node.Drag;
pub const DragPhase = node.DragPhase;
pub const DragAction = node.DragAction;
pub const DragActions = node.DragActions;

pub const Window = @import("Window.zig");
pub const Desktop = Window.Desktop;
pub const theme = @import("theme.zig");
pub const user_theme = @import("user_theme.zig");
pub const ColorToken = theme.ColorToken;
pub const TextRole = theme.TextRole;
pub const Theme = theme.Theme;
pub const Txn = @import("txn.zig").Txn;
pub const TxnError = @import("txn.zig").Error;
pub const Fonts = @import("fonts.zig");
pub const Clipboard = @import("clipboard.zig");
pub const dnd = @import("dnd.zig");
pub const layers = @import("layers.zig");
pub const Sink = layers.Sink;
pub const semantics = @import("semantics.zig");
pub const input = @import("input.zig");
pub const access = @import("access.zig");
/// Text nodes' shaped paragraphs and layouts, for tests that check lines.
pub const text_node = @import("text_node.zig");
pub const keysym = input.keysym;

test {
    std.testing.refAllDecls(@This());
    _ = node;
    _ = @import("layout.zig");
    _ = @import("paint.zig");
    _ = @import("text_node.zig");
    _ = @import("editor.zig");
    _ = @import("spans.zig");
    _ = @import("secret.zig");
    _ = @import("ime.zig");
    _ = @import("tests.zig");
    _ = @import("icons.zig");
}
