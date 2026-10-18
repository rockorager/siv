//! The widget interface (D22): `siv_set_widget` gives a node callbacks that
//! answer the generic `siv_widget_*` calls and `siv_node_focus`. Stock
//! widgets (src/widgets) set one on their root like any application's
//! widget, so these exports know nothing about widget kinds: they check
//! the arguments every widget would check, then call the node's interface.
//! The interfaces live in `tree.Nodes.widgets` and follow the transaction
//! like handlers (tree.zig).

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");

const Window = application.Window;
const Error = application.Error;
const NodeId = ui.NodeId;

pub export fn siv_set_widget(txn: t.Txn, node: t.Node, desc: ?*const t.WidgetDesc) void {
    const r = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, ptr: ?*const t.WidgetDesc) Error!void {
            const id = try tree.nodeIn(w, n);
            const d = try runtime.readDesc(t.WidgetDesc, ptr);
            const gpa = w.owner.gpa();
            try w.txn.widget_undo.ensureUnusedCapacity(gpa, 1);
            try w.nodes.widgets.ensureUnusedCapacity(gpa, 1);
            const old = w.nodes.widgets.fetchRemove(id.index());
            w.txn.widget_undo.appendAssumeCapacity(.{ .node = id, .old = if (old) |kv| kv.value else null });
            if (ptr != null) w.nodes.widgets.putAssumeCapacity(id.index(), d);
        }
    }.f, .{ node, desc });
    // A failed call that took a destroy-notify runs it (D2).
    if (r != .ok) if (desc) |d| if (d.destroy) |f| {
        if (application.App.window(@backingInt(txn), application.txn_tag)) |w| w.owner.release(f, d.user_data) else |_| f(d.user_data);
    };
    return;
}

/// The interface of a node of the transaction's window.
fn interface(w: *Window, n: t.Node) Error!t.WidgetDesc {
    const id = try tree.nodeIn(w, n);
    return w.nodes.widgets.get(id.index()) orelse error.InvalidArgument;
}

/// Runs one of a widget's setters in the caller's transaction, under the
/// sticky-error rule; the widget reports what it refuses with
/// siv_txn_fail.
fn set(txn: t.Txn, comptime field: []const u8, args: anytype) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, tx: t.Txn, a: @TypeOf(args)) Error!void {
            const iface = try interface(w, a[0]);
            const cb = @field(iface, field) orelse return error.InvalidArgument;
            w.owner.enter();
            defer w.owner.leave();
            @call(.auto, cb, .{ iface.user_data, tx } ++ a);
        }
    }.f, .{ txn, args });
}

pub export fn siv_widget_set_label(txn: t.Txn, node: t.Node, label: ?[*]const u8, label_len: usize) void {
    _ = runtime.string(label, label_len) catch return tree.siv_txn_fail(txn, .error_invalid_argument);
    return set(txn, "set_label", .{ node, label, label_len });
}

pub export fn siv_widget_set_icon(txn: t.Txn, node: t.Node, icon: ?[*]const u8, icon_len: usize) void {
    _ = runtime.string(icon, icon_len) catch return tree.siv_txn_fail(txn, .error_invalid_argument);
    return set(txn, "set_icon", .{ node, icon, icon_len });
}

pub export fn siv_widget_set_disabled(txn: t.Txn, node: t.Node, disabled: bool) void {
    return set(txn, "set_disabled", .{ node, disabled });
}

pub export fn siv_widget_set_value(txn: t.Txn, node: t.Node, value: f64) void {
    if (!std.math.isFinite(value)) return tree.siv_txn_fail(txn, .error_invalid_argument);
    return set(txn, "set_value", .{ node, value });
}

pub export fn siv_widget_set_range(txn: t.Txn, node: t.Node, min: f64, max: f64, step: f64) void {
    if (!std.math.isFinite(min) or !std.math.isFinite(max) or !std.math.isFinite(step) or step < 0 or min > max)
        return tree.siv_txn_fail(txn, .error_invalid_argument);
    return set(txn, "set_range", .{ node, min, max, step });
}

/// Hands a node bound to an action the action's state (D34, actions.zig)
/// in a transaction on its window: set_disabled, and set_value when the
/// action has a value, as far as its interface has them. A node without
/// an interface keeps its own state.
pub fn follow(w: *Window, txn: t.Txn, id: NodeId, disabled: bool, value: ?f64) void {
    const iface = w.nodes.widgets.get(id.index()) orelse return;
    const n: t.Node = @fromBackingInt(w.nodes.handle(id));
    w.owner.enter();
    defer w.owner.leave();
    if (iface.set_disabled) |cb| cb(iface.user_data, txn, n, disabled);
    if (value) |v| if (iface.set_value) |cb| cb(iface.user_data, txn, n, v);
}

/// The interface of any node, outside a transaction.
fn query(n: t.Node) Error!struct { *Window, t.WidgetDesc } {
    const w, const id = try tree.lookup(n);
    return .{ w, w.nodes.widgets.get(id.index()) orelse return error.InvalidArgument };
}

pub export fn siv_widget_get_value(node: t.Node, value: ?*f64) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, out: ?*f64) Error!void {
            const dest = try runtime.out(f64, out);
            const w, const iface = try query(n);
            const cb = iface.get_value orelse return error.InvalidArgument;
            w.owner.enter();
            const v = cb(iface.user_data, n);
            w.owner.leave();
            dest.* = v;
        }
    }.f(node, value));
}

pub export fn siv_widget_get_part(node: t.Node, part: t.WidgetPart, index: u32) t.Node {
    const w, const iface = query(node) catch return .null;
    const cb = iface.get_part orelse return .null;
    w.owner.enter();
    defer w.owner.leave();
    return cb(iface.user_data, node, part, index);
}

/// The node that takes focus for `n` as its interface's focus chooses, or
/// null when it has no choice to make. Asking runs application code, so
/// the caller looks the result up again.
pub fn focusTarget(w: *Window, id: NodeId, n: t.Node) Error!?t.Node {
    const iface = w.nodes.widgets.get(id.index()) orelse return null;
    const cb = iface.focus orelse return null;
    w.owner.enter();
    defer w.owner.leave();
    const target = cb(iface.user_data, n);
    return if (target == .null) error.InvalidArgument else target;
}
