//! The adaptive layout part of the API schema (D39): variants, values a
//! node takes instead of its own while the space its parent offers is in
//! a range, so one tree arranges itself for narrow and wide windows.
//! api.zig appends these declarations and functions to its own; the
//! conventions are schema.zig's. Implemented in adaptive.zig.

const schema = @import("schema.zig");
const ref = schema.ref;
const Decl = schema.Decl;
const Param = schema.Param;
const Function = schema.Function;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

fn f32Field(comptime name: []const u8, comptime doc: []const u8) schema.Field {
    return .{ .name = name, .type = .f32, .doc = doc };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

fn setter(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{
        .name = name,
        .doc = doc ++ " A failure is the transaction's (see siv_txn_commit).",
        .since = v0_1,
        .params = &([_]Param{
            p("txn", ref("siv_txn"), "An open transaction."),
            p("node", ref("siv_node"), "A node of the transaction's window."),
        } ++ params[0..params.len].*),
    };
}

const when_param = p("when", .{ .desc = "siv_condition_desc" }, "When the value applies; NULL always.");

const variants = " A node's variants apply in the order they were first set, later ones over earlier ones where several hold; one set again with an equal condition is changed in place. They are part of the transaction, and the node's parent decides which hold each time it lays out, before laying out its children, so a resize shows the new arrangement in its own frame. Nodes with motion (siv_set_motion) animate the change, even in a frame that resized the window. At most 32 conditions per node: one more is SIV_ERROR_LIMIT_EXCEEDED.";

pub const decls = [_]Decl{
    .{ .flags = .{ .name = "siv_condition_flags", .doc = "Options of a variant's condition (D39).", .since = v0_1, .bits = &.{
        .{ .name = "overflow", .bit = 0, .doc = "Holds only while the node's max-content width, the widest it gets without wrapping when every variant in its subtree is as at unbounded space, is wider than the space offered: a row of buttons turns into a column when it would not fit, without a width written down. Combines with the bounds." },
        .{ .name = "window", .bit = 1, .doc = "The bounds (and overflow) are on the window's size rather than the space the parent offers, wherever the node is: for a node deep in rows sized to their content, which offer little, or a choice that follows the window as a whole (a sidebar that goes on a narrow window)." },
    } } },
    .{ .@"struct" = .{ .name = "siv_condition_desc", .doc = "When a variant applies (D39): a range of the space the node's parent offers its children, which is the parent's content box under its constraints (unbounded along the axes a scroll node scrolls; the root's is the window), or with SIV_CONDITION_WINDOW the window's size. The space offered is a container query: a widget's variants follow the pane it is in, not the window. Widths hold from min_width up to but not including max_width, so one value splits narrow from wide (max_width 600 below it, min_width 600 from it on); heights likewise. Unbounded space is wider than any bound. All zero always holds.", .since = v0_1, .kind = .descriptor, .fields = &.{
        f32Field("min_width", "Smallest width that holds."),
        f32Field("max_width", "Width from which it no longer holds; 0 is unbounded."),
        f32Field("min_height", "Smallest height that holds."),
        f32Field("max_height", "Height from which it no longer holds; 0 is unbounded."),
        .{ .name = "flags", .type = ref("siv_condition_flags"), .doc = "Options." },
        .{ .name = "reserved0", .type = .u32, .doc = "Reserved; zero.", .reserved = true },
    } } },
};

pub const functions = [_]Function{
    setter("siv_set_layout_when", "Gives the node a layout (D26) to take instead of its own while a condition holds, made from desc as siv_set_layout makes it, with the node's default layout (siv_set_default_layout) as it is now. siv_set_layout keeps setting the node's own layout, which shows again when no layout variant holds." ++ variants, &.{
        when_param,
        p("desc", .{ .desc = "siv_layout_desc" }, "The layout; NULL for defaults."),
    }),
    setter("siv_set_flex_when", "Gives a flex container options to take instead of its own while a condition holds: a row that becomes a column on narrow windows. siv_set_flex keeps setting its own." ++ variants ++ " SIV_ERROR_INVALID_ARGUMENT for a node that is not a flex container.", &.{
        when_param,
        p("desc", .{ .desc = "siv_flex_desc" }, "The options; NULL for defaults."),
    }),
    setter("siv_set_hidden_when", "Hides or shows the node instead of what siv_set_hidden says while a condition holds: a sidebar that goes on narrow windows, or one of two arrangements of the same content. A hidden node keeps its state and takes no space, as with siv_set_hidden; focus leaves it, and with SIV_MOTION_EXIT or SIV_MOTION_ENTER it leaves or arrives as it would." ++ variants, &.{
        when_param,
        p("hidden", .bool, "Hidden while the condition holds."),
    }),
    setter("siv_clear_variants", "Removes the node's variants (siv_set_layout_when, siv_set_flex_when, siv_set_hidden_when): it shows its own layout, flex options, and visibility.", &.{}),
};
