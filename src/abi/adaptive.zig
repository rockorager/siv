//! Exports for variants (D39, api_adaptive.zig): values a node takes
//! instead of its own while the space its parent offers is in a range.
//! The tree keeps them (`ui.Txn.setVariant`) and layout applies them.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");

const Window = application.Window;
const Error = application.Error;
const NodeId = ui.NodeId;

fn conditionOf(ptr: ?*const t.ConditionDesc) Error!ui.Condition {
    const d = try runtime.readDesc(t.ConditionDesc, ptr);
    const fl = try runtime.flags(t.ConditionFlags, d.flags);
    for ([_]f32{ d.min_width, d.max_width, d.min_height, d.max_height }) |v| if (!(v >= 0) or !std.math.isFinite(v)) return error.InvalidArgument;
    return .{
        .min_width = d.min_width,
        .max_width = if (d.max_width == 0) std.math.inf(f32) else d.max_width,
        .min_height = d.min_height,
        .max_height = if (d.max_height == 0) std.math.inf(f32) else d.max_height,
        .overflow = fl.overflow,
        .window = fl.window,
    };
}

/// Sets one part of the variant of `when`, reporting the limit first.
fn setVariant(w: *Window, id: NodeId, when: ui.Condition, part: ui.Txn.Part) Error!void {
    if (w.uiWin().node(id).adaptive) |a| if (a.variants.len == ui.Variant.max) {
        for (a.variants) |v| {
            if (std.meta.eql(v.when, when)) break;
        } else return error.LimitExceeded;
    };
    w.txn.ut.setVariant(id, when, part) catch |err| return tree.mapTxn(err);
}

pub export fn siv_set_layout_when(txn: t.Txn, node: t.Node, when: ?*const t.ConditionDesc, desc: ?*const t.LayoutDesc) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, c: ?*const t.ConditionDesc, d_ptr: ?*const t.LayoutDesc) Error!void {
            const id = try tree.nodeIn(w, n);
            const cond = try conditionOf(c);
            var d = try runtime.readDesc(t.LayoutDesc, d_ptr);
            if (w.nodes.layouts.get(id.index())) |pair| d = tree.mergeLayout(d, pair.default);
            try setVariant(w, id, cond, .{ .layout = try tree.layoutOf(&d) });
        }
    }.f, .{ node, when, desc });
}

pub export fn siv_set_flex_when(txn: t.Txn, node: t.Node, when: ?*const t.ConditionDesc, desc: ?*const t.FlexDesc) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, c: ?*const t.ConditionDesc, d: ?*const t.FlexDesc) Error!void {
            const id = try tree.nodeIn(w, n);
            try setVariant(w, id, try conditionOf(c), .{ .flex = try tree.flexOf(d) });
        }
    }.f, .{ node, when, desc });
}

pub export fn siv_set_hidden_when(txn: t.Txn, node: t.Node, when: ?*const t.ConditionDesc, hidden: bool) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, c: ?*const t.ConditionDesc, h: bool) Error!void {
            const id = try tree.nodeIn(w, n);
            try setVariant(w, id, try conditionOf(c), .{ .hidden = h });
        }
    }.f, .{ node, when, hidden });
}

pub export fn siv_clear_variants(txn: t.Txn, node: t.Node) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node) Error!void {
            const id = try tree.nodeIn(w, n);
            w.txn.ut.clearVariants(id) catch |err| return tree.mapTxn(err);
        }
    }.f, .{node});
}
