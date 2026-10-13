//! Exports for drag and drop (D19): drop targets, drags from nodes, `ask`
//! drops, and the transfer limit. Drop and drag events reach C through
//! the node handlers in tree.zig.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");
const canvas = @import("canvas.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;

pub fn actionOf(a: t.DragAction) Error!ui.DragAction {
    return switch (try runtime.enumValue(t.DragAction, a)) {
        .none => .none,
        .copy => .copy,
        .move => .move,
        .ask => .ask,
        _ => unreachable,
    };
}

pub fn actionTo(a: ui.DragAction) t.DragAction {
    return switch (a) {
        .none => .none,
        .copy => .copy,
        .move => .move,
        .ask => .ask,
    };
}

/// 0 is copy.
fn actionsOf(f: t.DragActionFlags) Error!ui.DragActions {
    const a = try runtime.flags(t.DragActionFlags, f);
    if (!a.copy and !a.move and !a.ask) return .{ .copy = true };
    return .{ .copy = a.copy, .move = a.move, .ask = a.ask };
}

pub fn actionsTo(a: ui.DragActions) t.DragActionFlags {
    return .{ .copy = a.copy, .move = a.move, .ask = a.ask };
}

pub export fn siv_set_drop_target(txn: t.Txn, node: t.Node, desc: ?*const t.DropTargetDesc) t.Result {
    return tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, d_ptr: ?*const t.DropTargetDesc) Error!void {
            const id = try tree.nodeIn(w, n);
            const d = try runtime.readDesc(t.DropTargetDesc, d_ptr);
            w.txn.ut.setDropTarget(id, .{
                .mimes = try runtime.string(d.mimes, d.mimes_len),
                .actions = try actionsOf(d.actions),
                .preferred = try actionOf(d.preferred),
            }) catch |err| return tree.mapTxn(err);
        }
    }.f, .{ node, desc });
}

pub export fn siv_drag_start(node: t.Node, desc: ?*const t.DragDesc) t.Result {
    return application.wrap(dragStart(node, desc));
}

fn dragStart(node: t.Node, d_ptr: ?*const t.DragDesc) Error!void {
    const w, const id = try tree.lookup(node);
    const self = w.owner;
    if (self.painting != 0) return error.Busy;
    const d = try runtime.readDesc(t.DragDesc, d_ptr);
    const fl = try runtime.flags(t.DragFlags, d.flags);
    const mimes = try runtime.string(d.mimes, d.mimes_len);
    const data = try runtime.array(u8, d.data, d.data_count);
    const lengths = try runtime.array(usize, d.lengths, d.lengths_count);
    if (!std.math.isFinite(d.hotspot_x) or !std.math.isFinite(d.hotspot_y)) return error.InvalidArgument;
    const shown = if (d.icon == .null) null else try canvas.imageOf(self, d.icon);
    // Vector images become pixels, one per logical pixel.
    const icon = if (shown) |img| try @import("icon.zig").rasterize(self, img, 1) else null;
    defer if (icon) |img| img.release();

    // One item per MIME type, with its share of the data.
    var items: std.ArrayList(ui.Clipboard.DragItem) = .empty;
    defer items.deinit(self.gpa());
    var it = std.mem.tokenizeScalar(u8, mimes, '\n');
    var offset: usize = 0;
    while (it.next()) |m| {
        const i = items.items.len;
        const bytes = if (lengths.len == 0) data else blk: {
            if (i >= lengths.len or lengths[i] > data.len - offset) return error.InvalidArgument;
            defer offset += lengths[i];
            break :blk data[offset..][0..lengths[i]];
        };
        try items.append(self.gpa(), .{ .mime = m, .data = bytes });
    }
    if (lengths.len != 0 and (lengths.len != items.items.len or offset != data.len)) return error.InvalidArgument;

    const uw = w.uiWin();
    uw.startDrag(id, .{
        .items = items.items,
        .actions = try actionsOf(d.actions),
        .in_app = fl.in_app,
        .icon = icon,
        .hotspot_x = d.hotspot_x,
        .hotspot_y = d.hotspot_y,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArgument => error.InvalidArgument,
        error.Unavailable => error.Unavailable,
    };
}

pub export fn siv_drop_finish(window: t.Window, action: t.DragAction) t.Result {
    return application.wrap(struct {
        fn f(wh: t.Window, a: t.DragAction) Error!void {
            const w = try App.window(@backingInt(wh), application.window_tag);
            w.uiWin().finishDrop(try actionOf(a));
        }
    }.f(window, action));
}

pub export fn siv_app_set_transfer_limit(app: t.App, bytes: usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, n: usize) Error!void {
            const self = try App.get(@backingInt(a));
            self.app.clipboard.limit = n;
        }
    }.f(app, bytes));
}
