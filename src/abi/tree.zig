//! Exports for transactions, nodes, and node events (D4, D5, D18). The tree
//! itself is `ui.Window`; this file keeps what only the ABI knows about:
//! node handles, C callbacks, and the transaction's sticky error.
//!
//! Sticky errors: the first operation that fails in a transaction records
//! its error. Every later operation in that transaction does nothing and
//! returns the error (builders return 0), and `siv_txn_commit` aborts the
//! transaction and returns it. So a C program can build a subtree without
//! checking each call and still never commit half of it.
//!
//! A node handle's payload is the window index (top 10 bits) and the node's
//! index in the window (low 22 bits). Handles are made when a node is
//! created and removed when a committed transaction destroys it or the
//! transaction that created it is aborted.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const scene = @import("scene");
const platform = @import("platform");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const dnd = @import("dnd.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;
const NodeId = ui.NodeId;
const EditorData = @FieldType(@FieldType(ui.Node, "data"), "editor");
const node_tag = application.node_tag;
const txn_tag = application.txn_tag;

const node_bits = 22;
pub const max_nodes = 1 << node_bits;
const handler_count = @typeInfo(ui.HandlerKind).@"enum".field_names.len;

pub const Callback = struct {
    func: t.EventFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
};

const Slots = [handler_count]?Callback;

/// A canvas's C callbacks (canvas.zig).
pub const CanvasCb = struct {
    draw: ?t.DrawFn,
    measure: ?t.MeasureFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
};

/// Memory siv_set_data gave a node: a header, then the caller's bytes at
/// a 16-byte boundary. A node's entries form a list.
pub const Data = struct {
    key: usize,
    size: usize,
    next: ?*Data = null,

    const header = 32;
    comptime {
        std.debug.assert(@sizeOf(Data) <= header);
    }

    fn create(gpa: std.mem.Allocator, key: usize, size: usize) Error!*Data {
        const mem = try gpa.alignedAlloc(u8, .@"16", header + size);
        @memset(mem, 0);
        const d: *Data = @ptrCast(mem.ptr);
        d.* = .{ .key = key, .size = size };
        return d;
    }

    fn destroy(d: *Data, gpa: std.mem.Allocator) void {
        const mem: [*]align(16) u8 = @ptrCast(@alignCast(d));
        gpa.free(mem[0 .. header + d.size]);
    }

    pub fn bytes(d: *Data) *anyopaque {
        const mem: [*]align(16) u8 = @ptrCast(@alignCast(d));
        return mem + header;
    }
};

/// Per-node ABI state of one window, indexed by node index.
pub const Nodes = struct {
    handles: std.ArrayList(u64) = .empty,
    callbacks: std.ArrayList(Slots) = .empty,
    /// siv_on_default handlers.
    defaults: std.ArrayList(Slots) = .empty,
    canvases: std.ArrayList(?CanvasCb) = .empty,
    data: std.ArrayList(?*Data) = .empty,
    /// Nodes with a siv_set_default_layout, by index: the application's
    /// and the default layout, merged into the node's layout.
    layouts: std.AutoHashMapUnmanaged(u32, LayoutPair) = .empty,

    pub fn deinit(n: *Nodes, gpa: std.mem.Allocator) void {
        n.layouts.deinit(gpa);
        n.handles.deinit(gpa);
        n.callbacks.deinit(gpa);
        n.defaults.deinit(gpa);
        n.canvases.deinit(gpa);
        n.data.deinit(gpa);
    }

    /// Room for `total` nodes, so that `adopt` cannot fail.
    pub fn reserve(n: *Nodes, gpa: std.mem.Allocator, total: usize) Error!void {
        try n.handles.ensureTotalCapacity(gpa, total);
        try n.callbacks.ensureTotalCapacity(gpa, total);
        try n.defaults.ensureTotalCapacity(gpa, total);
        try n.canvases.ensureTotalCapacity(gpa, total);
        try n.data.ensureTotalCapacity(gpa, total);
    }

    /// Gives a new node a handle. The caller reserved room here and in the
    /// handle table.
    pub fn adopt(n: *Nodes, self: *App, w: *Window, id: NodeId) Error!void {
        const i = id.index();
        while (n.handles.items.len <= i) {
            n.handles.appendAssumeCapacity(0);
            n.callbacks.appendAssumeCapacity(@splat(null));
            n.defaults.appendAssumeCapacity(@splat(null));
            n.canvases.appendAssumeCapacity(null);
            n.data.appendAssumeCapacity(null);
        }
        n.handles.items[i] = try self.root.handles.insert(self.gpa(), node_tag, w.index << node_bits | i);
    }

    pub fn handle(n: *const Nodes, id: NodeId) u64 {
        const i = id.index();
        return if (i < n.handles.items.len) n.handles.items[i] else 0;
    }

    pub fn slot(n: *Nodes, id: NodeId, kind: ui.HandlerKind) *?Callback {
        return &n.callbacks.items[id.index()][@intFromEnum(kind)];
    }

    pub fn defaultSlot(n: *Nodes, id: NodeId, kind: ui.HandlerKind) *?Callback {
        return &n.defaults.items[id.index()][@intFromEnum(kind)];
    }

    pub fn findData(n: *const Nodes, id: NodeId, key: usize) ?*Data {
        const i = id.index();
        if (i >= n.data.items.len) return null;
        var cur = n.data.items[i];
        while (cur) |d| : (cur = d.next) if (d.key == key) return d;
        return null;
    }

    pub fn canvas(n: *Nodes, id: NodeId) *?CanvasCb {
        return &n.canvases.items[id.index()];
    }

    /// The node is gone: its handle and callbacks too.
    fn forget(n: *Nodes, w: *Window, id: NodeId) void {
        const i = id.index();
        if (i >= n.handles.items.len) return;
        if (n.handles.items[i] != 0) {
            _ = w.owner.root.handles.remove(n.handles.items[i], node_tag) catch unreachable;
            n.handles.items[i] = 0;
        }
        for ([_]*Slots{ &n.callbacks.items[i], &n.defaults.items[i] }) |slots| for (slots) |*cb| if (cb.*) |c| {
            cb.* = null;
            w.owner.release(c.destroy, c.user_data);
        };
        _ = n.layouts.remove(i);
        var data = n.data.items[i];
        n.data.items[i] = null;
        while (data) |d| {
            data = d.next;
            d.destroy(w.owner.gpa());
        }
        if (n.canvases.items[i]) |c| {
            n.canvases.items[i] = null;
            w.owner.release(c.destroy, c.user_data);
        }
    }

    pub fn releaseAll(n: *Nodes, w: *Window) void {
        for (0..n.handles.items.len) |i| n.forget(w, @enumFromInt(i));
    }
};

const Undo = struct { node: NodeId, kind: ui.HandlerKind, default: bool, old: ?Callback };

/// The ABI side of a window's open transaction.
pub const TxnState = struct {
    /// The siv_txn handle, or 0 when none is open.
    handle: u64 = 0,
    err: ?Error = null,
    ut: *ui.Txn = undefined,
    /// Nodes created: their handles go on abort.
    created: std.ArrayList(NodeId) = .empty,
    /// Roots of removed subtrees: their handles go on commit.
    removed: std.ArrayList(NodeId) = .empty,
    /// Handler changes, to restore on abort and release on commit.
    undo: std.ArrayList(Undo) = .empty,
    /// Canvas callback changes, likewise.
    canvas_undo: std.ArrayList(CanvasUndo) = .empty,
    /// Node data made: freed on abort.
    data_created: std.ArrayList(struct { node: NodeId, data: *Data }) = .empty,
    /// Layout pairs changed, to restore on abort.
    layout_undo: std.ArrayList(LayoutUndo) = .empty,

    pub fn deinit(s: *TxnState, gpa: std.mem.Allocator) void {
        s.layout_undo.deinit(gpa);
        s.created.deinit(gpa);
        s.removed.deinit(gpa);
        s.undo.deinit(gpa);
        s.canvas_undo.deinit(gpa);
        s.data_created.deinit(gpa);
    }

    fn finish(s: *TxnState, w: *Window) void {
        _ = w.owner.root.handles.remove(s.handle, txn_tag) catch unreachable;
        s.handle = 0;
        s.err = null;
        s.created.clearRetainingCapacity();
        s.removed.clearRetainingCapacity();
        s.undo.clearRetainingCapacity();
        s.canvas_undo.clearRetainingCapacity();
        s.data_created.clearRetainingCapacity();
        s.layout_undo.clearRetainingCapacity();
    }
};

pub const CanvasUndo = struct { node: NodeId, old: ?CanvasCb };

pub const LayoutPair = struct { app: t.LayoutDesc = .{}, default: t.LayoutDesc = .{} };
pub const LayoutUndo = struct { node: NodeId, old: ?LayoutPair };

/// Aborts the window's open transaction, if any (also after the tree's
/// own transaction was aborted, as when the window is destroyed).
pub fn abortState(w: *Window) void {
    const s = &w.txn;
    if (s.handle == 0) return;
    var i = s.undo.items.len;
    while (i > 0) {
        i -= 1;
        const u = s.undo.items[i];
        const cur = if (u.default) w.nodes.defaultSlot(u.node, u.kind) else w.nodes.slot(u.node, u.kind);
        if (cur.*) |c| w.owner.release(c.destroy, c.user_data);
        cur.* = u.old;
    }
    i = s.layout_undo.items.len;
    while (i > 0) {
        i -= 1;
        const u = s.layout_undo.items[i];
        if (u.old) |old| {
            w.nodes.layouts.putAssumeCapacity(u.node.index(), old);
        } else _ = w.nodes.layouts.remove(u.node.index());
    }
    // Data made by this transaction is first in its node's list.
    i = s.data_created.items.len;
    while (i > 0) {
        i -= 1;
        const e = s.data_created.items[i];
        const head = &w.nodes.data.items[e.node.index()];
        std.debug.assert(head.* == e.data);
        head.* = e.data.next;
        e.data.destroy(w.owner.gpa());
    }
    i = s.canvas_undo.items.len;
    while (i > 0) {
        i -= 1;
        const u = s.canvas_undo.items[i];
        const cur = w.nodes.canvas(u.node);
        if (cur.*) |c| w.owner.release(c.destroy, c.user_data);
        cur.* = u.old;
    }
    if (w.uiWin().txn.open) s.ut.abort();
    for (s.created.items) |id| w.nodes.forget(w, id);
    s.finish(w);
}

fn commitState(w: *Window) void {
    const s = &w.txn;
    for (s.removed.items) |id| forgetSubtree(w, id);
    for (s.undo.items) |u| if (u.old) |c| w.owner.release(c.destroy, c.user_data);
    for (s.canvas_undo.items) |u| if (u.old) |c| w.owner.release(c.destroy, c.user_data);
    s.ut.commit();
    s.finish(w);
}

fn forgetSubtree(w: *Window, id: NodeId) void {
    var it = w.uiWin().children(id);
    while (it.next()) |c| forgetSubtree(w, c);
    w.nodes.forget(w, id);
}

pub fn mapTxn(err: ui.TxnError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidNode, error.InvalidArgument => error.InvalidArgument,
    };
}

fn txnWindow(txn: t.Txn) Error!*Window {
    return App.window(@backingInt(txn), txn_tag);
}

/// The node a handle names in `w`.
pub fn nodeIn(w: *Window, node: t.Node) Error!NodeId {
    const payload = try w.owner.root.handles.get(@backingInt(node), node_tag);
    if (payload >> node_bits != w.index) return error.InvalidHandle;
    return @enumFromInt(payload & (max_nodes - 1));
}

/// Runs a transaction operation under the sticky-error rule.
pub fn run(txn: t.Txn, comptime f: anytype, args: anytype) t.Result {
    const w = txnWindow(txn) catch |err| return t.resultOf(err);
    if (w.txn.err) |e| return t.resultOf(e);
    @call(.auto, f, .{w} ++ args) catch |err| {
        w.txn.err = err;
        return t.resultOf(err);
    };
    return .ok;
}

/// Runs a builder under the sticky-error rule.
pub fn build(txn: t.Txn, comptime f: anytype, args: anytype) t.Node {
    const w = txnWindow(txn) catch return .null;
    if (w.txn.err != null) return .null;
    const id = @call(.auto, f, .{w} ++ args) catch |err| {
        w.txn.err = err;
        return .null;
    };
    return @fromBackingInt(w.nodes.handle(id));
}

// Transactions ----------------------------------------------------------------

pub export fn siv_txn_begin(window: t.Window, txn: ?*t.Txn) t.Result {
    return application.wrap(txnBegin(window, txn));
}

fn txnBegin(window: t.Window, out: ?*t.Txn) Error!void {
    const w = try App.window(@backingInt(window), application.window_tag);
    const dest = try runtime.out(t.Txn, out);
    if (w.txn.handle != 0 or w.owner.painting != 0) return error.Busy;
    const self = w.owner;
    try self.root.handles.ensureUnusedCapacity(self.gpa());
    const ut = w.uiWin().begin() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TransactionOpen => error.Busy,
    };
    w.txn.ut = ut;
    w.txn.handle = self.root.handles.insert(self.gpa(), txn_tag, w.index) catch unreachable;
    dest.* = @fromBackingInt(w.txn.handle);
}

pub export fn siv_txn_commit(txn: t.Txn) t.Result {
    const w = txnWindow(txn) catch |err| return t.resultOf(err);
    if (w.txn.err) |err| {
        abortState(w);
        return t.resultOf(err);
    }
    commitState(w);
    return .ok;
}

pub export fn siv_txn_abort(txn: t.Txn) t.Result {
    const w = txnWindow(txn) catch |err| return t.resultOf(err);
    abortState(w);
    return .ok;
}

pub export fn siv_txn_fail(txn: t.Txn, err: t.Result) t.Result {
    const w = txnWindow(txn) catch |e| return t.resultOf(e);
    if (w.txn.err) |e| return t.resultOf(e);
    if (@backingInt(err) >= 0) {
        w.txn.err = error.InvalidArgument;
    } else {
        w.txn.err = switch (err) {
            .error_out_of_memory => error.OutOfMemory,
            .error_invalid_handle => error.InvalidHandle,
            .error_unsupported => error.Unsupported,
            .error_limit_exceeded => error.LimitExceeded,
            .error_busy => error.Busy,
            .error_unavailable => error.Unavailable,
            else => error.InvalidArgument,
        };
    }
    return t.resultOf(w.txn.err.?);
}

pub export fn siv_txn_status(txn: t.Txn) t.Result {
    const w = txnWindow(txn) catch |err| return t.resultOf(err);
    return if (w.txn.err) |err| t.resultOf(err) else .ok;
}

// Builders --------------------------------------------------------------------

pub fn create(w: *Window, parent: t.Node, kind: ui.Kind) Error!NodeId {
    const p = try nodeIn(w, parent);
    const uw = w.uiWin();
    if (uw.free_head == .none and uw.nodes.items.len >= max_nodes) return error.LimitExceeded;
    const self = w.owner;
    const gpa = self.gpa();
    try w.nodes.reserve(gpa, uw.nodes.items.len + 1);
    try self.root.handles.ensureUnusedCapacity(gpa);
    try w.txn.created.ensureUnusedCapacity(gpa, 1);
    const id = w.txn.ut.create(p, kind, .none) catch |err| return mapTxn(err);
    w.nodes.adopt(self, w, id) catch unreachable;
    w.txn.created.appendAssumeCapacity(id);
    return id;
}

pub export fn siv_box(txn: t.Txn, parent: t.Node) t.Node {
    return build(txn, create, .{ parent, ui.Kind.box });
}

pub export fn siv_flex(txn: t.Txn, parent: t.Node, desc: ?*const t.FlexDesc) t.Node {
    return build(txn, struct {
        fn f(w: *Window, p: t.Node, d: ?*const t.FlexDesc) Error!NodeId {
            const flex = try flexOf(d);
            const id = try create(w, p, .flex);
            w.txn.ut.setFlex(id, flex) catch |err| return mapTxn(err);
            return id;
        }
    }.f, .{ parent, desc });
}

pub export fn siv_grid(txn: t.Txn, parent: t.Node, desc: ?*const t.GridDesc) t.Node {
    return build(txn, struct {
        fn f(w: *Window, p: t.Node, d: ?*const t.GridDesc) Error!NodeId {
            const id = try create(w, p, .grid);
            try setGrid(w, id, d);
            return id;
        }
    }.f, .{ parent, desc });
}

pub export fn siv_stack(txn: t.Txn, parent: t.Node, desc: ?*const t.StackDesc) t.Node {
    return build(txn, struct {
        fn f(w: *Window, p: t.Node, d: ?*const t.StackDesc) Error!NodeId {
            const stack = try stackOf(d);
            const id = try create(w, p, .stack);
            w.txn.ut.setStack(id, stack) catch |err| return mapTxn(err);
            return id;
        }
    }.f, .{ parent, desc });
}

pub export fn siv_text(txn: t.Txn, parent: t.Node, text: ?[*]const u8, text_len: usize) t.Node {
    return build(txn, struct {
        fn f(w: *Window, p: t.Node, ptr: ?[*]const u8, len: usize) Error!NodeId {
            const s = try runtime.string(ptr, len);
            const id = try create(w, p, .text);
            w.txn.ut.setText(id, s) catch |err| return mapTxn(err);
            return id;
        }
    }.f, .{ parent, text, text_len });
}

pub export fn siv_editor(txn: t.Txn, parent: t.Node, flags: t.EditorFlags) t.Node {
    return build(txn, struct {
        fn f(w: *Window, p: t.Node, fl: t.EditorFlags) Error!NodeId {
            const e = try runtime.flags(t.EditorFlags, fl);
            const id = try create(w, p, .editor);
            w.txn.ut.setEditor(id, .{ .multiline = e.multiline, .masked = e.masked }) catch |err| return mapTxn(err);
            return id;
        }
    }.f, .{ parent, flags });
}

pub export fn siv_scroll(txn: t.Txn, parent: t.Node, axis: t.ScrollAxis) t.Node {
    return build(txn, struct {
        fn f(w: *Window, p: t.Node, a: t.ScrollAxis) Error!NodeId {
            const ax = try scrollAxis(a);
            const id = try create(w, p, .scroll);
            w.txn.ut.setScroll(id, .{ .axis = ax }) catch |err| return mapTxn(err);
            return id;
        }
    }.f, .{ parent, axis });
}

// Structure and properties ----------------------------------------------------

pub export fn siv_move(txn: t.Txn, node: t.Node, parent: t.Node, before: t.Node) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, p: t.Node, b: t.Node) Error!void {
            const id = try nodeIn(w, n);
            const pid = try nodeIn(w, p);
            const bid: NodeId = if (b == .null) .none else try nodeIn(w, b);
            w.txn.ut.move(id, pid, bid) catch |err| return mapTxn(err);
        }
    }.f, .{ node, parent, before });
}

pub export fn siv_remove(txn: t.Txn, node: t.Node) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node) Error!void {
            const id = try nodeIn(w, n);
            try w.txn.removed.ensureUnusedCapacity(w.owner.gpa(), 1);
            w.txn.ut.remove(id) catch |err| return mapTxn(err);
            w.txn.removed.appendAssumeCapacity(id);
        }
    }.f, .{node});
}

pub export fn siv_set_layout(txn: t.Txn, node: t.Node, desc: ?*const t.LayoutDesc) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, d_ptr: ?*const t.LayoutDesc) Error!void {
            const id = try nodeIn(w, n);
            const d = try runtime.readDesc(t.LayoutDesc, d_ptr);
            const pair = w.nodes.layouts.get(id.index()) orelse {
                w.txn.ut.setLayout(id, try layoutOf(&d)) catch |err| return mapTxn(err);
                return;
            };
            try setLayoutPair(w, id, .{ .app = d, .default = pair.default });
        }
    }.f, .{ node, desc });
}

pub export fn siv_set_default_layout(txn: t.Txn, node: t.Node, desc: ?*const t.LayoutDesc) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, d_ptr: ?*const t.LayoutDesc) Error!void {
            const id = try nodeIn(w, n);
            const d = try runtime.readDesc(t.LayoutDesc, d_ptr);
            const app = if (w.nodes.layouts.get(id.index())) |p| p.app else t.LayoutDesc{};
            try setLayoutPair(w, id, .{ .app = app, .default = d });
        }
    }.f, .{ node, desc });
}

/// Lays the node out with the application's layout over the default one,
/// remembering both for later changes to either.
fn setLayoutPair(w: *Window, id: NodeId, pair: LayoutPair) Error!void {
    const gpa = w.owner.gpa();
    const merged = mergeLayout(pair.app, pair.default);
    const layout = try layoutOf(&merged);
    try w.txn.layout_undo.ensureUnusedCapacity(gpa, 1);
    try w.nodes.layouts.ensureUnusedCapacity(gpa, 1);
    w.txn.ut.setLayout(id, layout) catch |err| return mapTxn(err);
    w.txn.layout_undo.appendAssumeCapacity(.{ .node = id, .old = w.nodes.layouts.get(id.index()) });
    w.nodes.layouts.putAssumeCapacity(id.index(), pair);
}

/// Each field the application left zero takes the default's value; a
/// dimension counts as one field, edges side by side, flags combine.
fn mergeLayout(app: t.LayoutDesc, default: t.LayoutDesc) t.LayoutDesc {
    var out = app;
    const info = @typeInfo(t.LayoutDesc).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (comptime std.mem.eql(u8, name, "size")) continue;
        const a = @field(app, name);
        const d = @field(default, name);
        @field(out, name) = if (T == t.Edges) .{
            .start = if (a.start != 0) a.start else d.start,
            .end = if (a.end != 0) a.end else d.end,
            .top = if (a.top != 0) a.top else d.top,
            .bottom = if (a.bottom != 0) a.bottom else d.bottom,
        } else if (T == t.LayoutFlags)
            @bitCast(@as(u32, @bitCast(a)) | @as(u32, @bitCast(d)))
        else if (std.mem.allEqual(u8, std.mem.asBytes(&a), 0)) d else a;
    }
    return out;
}

pub export fn siv_set_visual(txn: t.Txn, node: t.Node, desc: ?*const t.VisualDesc) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, d_ptr: ?*const t.VisualDesc) Error!void {
            const id = try nodeIn(w, n);
            const d = try runtime.readDesc(t.VisualDesc, d_ptr);
            const fl = try runtime.flags(t.VisualFlags, d.flags);
            var v = w.uiWin().node(id).visual;
            v.background = try color(d.background, .transparent);
            v.border_color = try color(d.border_color, .transparent);
            v.border_width = d.border_width;
            v.radius = .{ .top_start = d.radius.top_start, .top_end = d.radius.top_end, .bottom_end = d.radius.bottom_end, .bottom_start = d.radius.bottom_start };
            for ([_]f32{ v.radius.top_start, v.radius.top_end, v.radius.bottom_end, v.radius.bottom_start }) |r| if (!(r >= 0) or !std.math.isFinite(r)) return error.InvalidArgument;
            v.clip = fl.clip;
            // A canvas keeps its own layer, so redrawing it repaints
            // nothing else (D28).
            v.layer = fl.layer or w.uiWin().node(id).kind == .canvas;
            v.hit_test = !fl.no_hit_test;
            v.hidden = fl.hidden;
            v.background_token = try colorToken(d.background_token, true);
            v.border_token = try colorToken(d.border_token, true);
            w.txn.ut.setVisual(id, v) catch |err| return mapTxn(err);
        }
    }.f, .{ node, desc });
}

pub export fn siv_set_opacity(txn: t.Txn, node: t.Node, opacity: f32) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, o: f32) Error!void {
            const id = try nodeIn(w, n);
            var v = w.uiWin().node(id).visual;
            v.opacity = o;
            w.txn.ut.setVisual(id, v) catch |err| return mapTxn(err);
        }
    }.f, .{ node, opacity });
}

pub export fn siv_set_transform(txn: t.Txn, node: t.Node, transform: t.Transform) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, tr: t.Transform) Error!void {
            const id = try nodeIn(w, n);
            var v = w.uiWin().node(id).visual;
            v.transform = .{
                .translate = .{ .x = tr.translate_x, .y = tr.translate_y },
                .scale = .{ .x = tr.scale_x, .y = tr.scale_y },
                .rotate = tr.rotate,
                .origin = .{ .x = tr.origin_x, .y = tr.origin_y },
            };
            w.txn.ut.setVisual(id, v) catch |err| return mapTxn(err);
        }
    }.f, .{ node, transform });
}

pub export fn siv_set_semantics(txn: t.Txn, node: t.Node, desc: ?*const t.SemanticsDesc) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, d_ptr: ?*const t.SemanticsDesc) Error!void {
            const id = try nodeIn(w, n);
            const d = try runtime.readDesc(t.SemanticsDesc, d_ptr);
            const fl = try runtime.flags(t.SemanticsFlags, d.flags);
            if (fl.live_polite and fl.live_assertive) return error.InvalidArgument;
            const role = try runtime.enumValue(t.Role, d.role);
            w.txn.ut.setSemantics(id, .{
                .role = if (role == .default) null else @enumFromInt(@backingInt(role) - 1),
                .label = try runtime.string(d.label, d.label_len),
                .description = try runtime.string(d.description, d.description_len),
                .focusable = fl.focusable,
                .disabled = fl.disabled,
                .checked = try toggle(d.checked),
                .pressed = try toggle(d.pressed),
                .selected = try toggle(d.selected),
                .expanded = try toggle(d.expanded),
                .value = if (fl.has_value) .{ .min = d.value_min, .max = d.value_max, .now = d.value_now, .step = d.value_step } else null,
                .live = if (fl.live_assertive) .assertive else if (fl.live_polite) .polite else .off,
                .modal = fl.modal,
            }) catch |err| return mapTxn(err);
        }
    }.f, .{ node, desc });
}

pub export fn siv_set_text(txn: t.Txn, node: t.Node, text: ?[*]const u8, text_len: usize) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, ptr: ?[*]const u8, len: usize) Error!void {
            const id = try nodeIn(w, n);
            w.txn.ut.setText(id, try runtime.string(ptr, len)) catch |err| return mapTxn(err);
        }
    }.f, .{ node, text, text_len });
}

pub export fn siv_set_text_style(txn: t.Txn, node: t.Node, desc: ?*const t.TextStyleDesc) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, d: ?*const t.TextStyleDesc) Error!void {
            const id = try nodeIn(w, n);
            w.txn.ut.setTextProps(id, try textPropsOf(d)) catch |err| return mapTxn(err);
        }
    }.f, .{ node, desc });
}

/// A siv_text_style_desc as the tree's text properties. Strings point
/// into the caller's memory.
pub fn textPropsOf(d_ptr: ?*const t.TextStyleDesc) Error!ui.Text {
    const d = try runtime.readDesc(t.TextStyleDesc, d_ptr);
    const fl = try runtime.flags(t.TextFlags, d.flags);
    if (!(d.font_size >= 0) or d.font_size > 1 << 16) return error.InvalidArgument;
    return .{
        .style = .{
            .family = try runtime.string(d.family, d.family_len),
            .language = try runtime.string(d.language, d.language_len),
            .size = if (d.font_size == 0) 14 else @floatCast(d.font_size),
            .weight = switch (try runtime.enumValue(t.FontWeight, d.weight)) {
                .regular => .regular,
                .thin => .thin,
                .light => .light,
                .medium => .medium,
                .semibold => .semibold,
                .bold => .bold,
                .black => .black,
                _ => unreachable,
            },
            .slant = switch (try runtime.enumValue(t.FontSlant, d.slant)) {
                .roman => .roman,
                .italic => .italic,
                .oblique => .oblique,
                _ => unreachable,
            },
            .color = try color(d.color, .black),
            .color_token = try colorToken(d.color_token, true),
            .size_role = @enumFromInt(@backingInt(try runtime.enumValue(t.TextRole, d.size_role))),
        },
        .alignment = switch (try runtime.enumValue(t.TextAlign, d.@"align")) {
            .start => .start,
            .end => .end,
            .center => .center,
            _ => unreachable,
        },
        .wrap = !fl.no_wrap,
    };
}

pub export fn siv_set_flex(txn: t.Txn, node: t.Node, desc: ?*const t.FlexDesc) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, d: ?*const t.FlexDesc) Error!void {
            const id = try nodeIn(w, n);
            w.txn.ut.setFlex(id, try flexOf(d)) catch |err| return mapTxn(err);
        }
    }.f, .{ node, desc });
}

pub export fn siv_set_grid(txn: t.Txn, node: t.Node, desc: ?*const t.GridDesc) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, d: ?*const t.GridDesc) Error!void {
            try setGrid(w, try nodeIn(w, n), d);
        }
    }.f, .{ node, desc });
}

pub export fn siv_set_stack(txn: t.Txn, node: t.Node, desc: ?*const t.StackDesc) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, d: ?*const t.StackDesc) Error!void {
            const id = try nodeIn(w, n);
            w.txn.ut.setStack(id, try stackOf(d)) catch |err| return mapTxn(err);
        }
    }.f, .{ node, desc });
}

pub export fn siv_set_scroll_axis(txn: t.Txn, node: t.Node, axis: t.ScrollAxis) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, a: t.ScrollAxis) Error!void {
            const id = try nodeIn(w, n);
            const un = w.uiWin().node(id);
            if (un.kind != .scroll) return error.InvalidArgument;
            var s = un.data.scroll;
            s.axis = try scrollAxis(a);
            w.txn.ut.setScroll(id, s) catch |err| return mapTxn(err);
        }
    }.f, .{ node, axis });
}

pub export fn siv_scroll_to(txn: t.Txn, node: t.Node, x: f32, y: f32) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, sx: f32, sy: f32) Error!void {
            const id = try nodeIn(w, n);
            const un = w.uiWin().node(id);
            if (un.kind != .scroll) return error.InvalidArgument;
            var s = un.data.scroll;
            s.offset = .{ .x = sx, .y = sy };
            w.txn.ut.setScroll(id, s) catch |err| return mapTxn(err);
        }
    }.f, .{ node, x, y });
}

pub export fn siv_set_editor_flags(txn: t.Txn, node: t.Node, flags: t.EditorFlags) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, fl: t.EditorFlags) Error!void {
            const id = try nodeIn(w, n);
            const e = try runtime.flags(t.EditorFlags, fl);
            w.txn.ut.setEditor(id, .{ .multiline = e.multiline, .masked = e.masked }) catch |err| return mapTxn(err);
        }
    }.f, .{ node, flags });
}

pub export fn siv_set_selection(txn: t.Txn, node: t.Node, caret: u32, anchor: u32) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, c: u32, a: u32) Error!void {
            const id = try nodeIn(w, n);
            const un = w.uiWin().node(id);
            if (un.kind != .editor) return error.InvalidArgument;
            const e = &un.data.editor;
            const masked = e.editor.masked;
            w.txn.ut.setSelection(
                id,
                if (masked) maskedOffset(e.secret, e.text.content, c) else c,
                if (masked) maskedOffset(e.secret, e.text.content, a) else a,
                .downstream,
            ) catch |err| return mapTxn(err);
        }
    }.f, .{ node, caret, anchor });
}

pub export fn siv_set_transition(txn: t.Txn, node: t.Node, duration_ms: u32) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, ms: u32) Error!void {
            const id = try nodeIn(w, n);
            var v = w.uiWin().node(id).visual;
            v.transition_ms = ms;
            w.txn.ut.setVisual(id, v) catch |err| return mapTxn(err);
        }
    }.f, .{ node, duration_ms });
}

pub export fn siv_set_placeholder(txn: t.Txn, node: t.Node, text: ?[*]const u8, text_len: usize) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, ptr: ?[*]const u8, len: usize) Error!void {
            const id = try nodeIn(w, n);
            if (w.uiWin().node(id).kind != .editor) return error.InvalidArgument;
            w.txn.ut.setPlaceholder(id, try runtime.string(ptr, len)) catch |err| return mapTxn(err);
        }
    }.f, .{ node, text, text_len });
}

pub export fn siv_set_data(txn: t.Txn, node: t.Node, key: ?*anyopaque, size: usize, data: ?*?*anyopaque) t.Result {
    return run(txn, struct {
        fn f(w: *Window, n: t.Node, k: ?*anyopaque, sz: usize, out: ?*?*anyopaque) Error!void {
            const id = try nodeIn(w, n);
            const dest = try runtime.out(?*anyopaque, out);
            const kv = @intFromPtr(k orelse return error.InvalidArgument);
            if (sz == 0 or sz > 1 << 30) return error.InvalidArgument;
            if (w.nodes.findData(id, kv)) |d| {
                if (d.size != sz) return error.InvalidArgument;
                dest.* = d.bytes();
                return;
            }
            const gpa = w.owner.gpa();
            try w.txn.data_created.ensureUnusedCapacity(gpa, 1);
            const d = try Data.create(gpa, kv, sz);
            const head = &w.nodes.data.items[id.index()];
            d.next = head.*;
            head.* = d;
            w.txn.data_created.appendAssumeCapacity(.{ .node = id, .data = d });
            dest.* = d.bytes();
        }
    }.f, .{ node, key, size, data });
}

pub export fn siv_on(txn: t.Txn, node: t.Node, kind: t.EventType, callback: ?t.EventFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    return on(txn, node, kind, callback, destroy, user_data, false);
}

pub export fn siv_on_default(txn: t.Txn, node: t.Node, kind: t.EventType, callback: ?t.EventFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    return on(txn, node, kind, callback, destroy, user_data, true);
}

fn on(txn: t.Txn, node: t.Node, kind: t.EventType, callback: ?t.EventFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, default: bool) t.Result {
    const w = txnWindow(txn) catch |err| return t.resultOf(err);
    const result = run(txn, setHandler, .{ node, kind, callback, destroy, user_data, default });
    // With no handler to own it, user_data is released at once; also when
    // the call failed, since the caller handed it over.
    if (callback == null or result != .ok) w.owner.release(destroy, user_data);
    return result;
}

/// The tree's handler kind for an event type; the C enum lists the same
/// kinds in the same order.
fn handlerKind(kind: t.EventType) Error!ui.HandlerKind {
    _ = try runtime.enumValue(t.EventType, kind);
    return @enumFromInt(@backingInt(kind));
}

comptime {
    for (@typeInfo(ui.HandlerKind).@"enum".field_names, 0..) |name, i| {
        if (@backingInt(@field(t.EventType, name)) != i) @compileError("siv_event_type does not match ui.HandlerKind at " ++ name);
    }
}

fn setHandler(w: *Window, node: t.Node, kind: t.EventType, callback: ?t.EventFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, default: bool) Error!void {
    const id = try nodeIn(w, node);
    const k = try handlerKind(kind);
    try w.txn.undo.ensureUnusedCapacity(w.owner.gpa(), 1);
    const s = if (default) w.nodes.defaultSlot(id, k) else w.nodes.slot(id, k);
    // The tree calls `dispatch` while either slot has a callback.
    const other = if (default) w.nodes.slot(id, k).* else w.nodes.defaultSlot(id, k).*;
    const handler: ?ui.Handler = if (callback != null or other != null) .{ .func = dispatch, .user = w } else null;
    w.txn.ut.on(id, k, handler) catch |err| return mapTxn(err);
    w.txn.undo.appendAssumeCapacity(.{ .node = id, .kind = k, .default = default, .old = s.* });
    s.* = if (callback) |cb| .{ .func = cb, .destroy = destroy, .user_data = user_data } else null;
}

/// Every node handler set through the ABI: finds the C callback and calls
/// it with the event in C form.
fn dispatch(user: ?*anyopaque, uw: *ui.Window, id: NodeId, event: *const ui.Event) bool {
    const w: *Window = @ptrCast(@alignCast(user));
    if (w.dead) return false;
    const hk: ui.HandlerKind = switch (event.*) {
        inline else => |_, tag| @field(ui.HandlerKind, @tagName(tag)),
    };
    var ev: t.Event = .{ .window = @fromBackingInt(w.handle), .type = @fromBackingInt(@intFromEnum(hk)) };
    switch (event.*) {
        .activate => {},
        .pointer => |p| {
            ev.phase = switch (p.phase) {
                .down => .down,
                .up => .up,
                .move => .move,
                .enter => .enter,
                .leave => .leave,
                .cancel => .cancel,
            };
            ev.button = switch (p.button) {
                .primary => .primary,
                .secondary => .secondary,
                .middle => .middle,
                .other => .other,
            };
            ev.modifiers = modifiers(p.mods);
            ev.x = p.x;
            ev.y = p.y;
        },
        .key => |k| {
            ev.keysym = k.keysym;
            ev.modifiers = modifiers(k.mods);
            ev.flags = .{ .pressed = k.pressed, .repeat = k.repeat };
            ev.text = k.text.ptr;
            ev.text_len = k.text.len;
        },
        .focus => |f| ev.flags = .{ .gained = f.gained, .visible = f.visible },
        .scroll => |s| {
            ev.dx = s.dx;
            ev.dy = s.dy;
        },
        .change => {
            const e = &uw.node(id).data.editor;
            const s = editorText(e);
            ev.text = s.text.ptr;
            ev.text_len = s.text.len;
            ev.caret = s.caret;
            ev.anchor = s.anchor;
        },
        .drop => |d| {
            ev.phase = switch (d.phase) {
                .enter => .enter,
                .move => .move,
                .leave => .leave,
                .drop => .drop,
            };
            ev.x = d.x;
            ev.y = d.y;
            ev.mime = d.mime.ptr;
            ev.mime_len = d.mime.len;
            ev.data = d.data.ptr;
            ev.data_count = d.data.len;
            ev.action = dnd.actionTo(d.action);
            ev.actions = dnd.actionsTo(d.source_actions);
        },
        .drag => |d| {
            ev.phase = switch (d.phase) {
                .move => .move,
                .drop => .drop,
                .end => .end,
            };
            ev.action = dnd.actionTo(d.action);
            ev.flags = .{ .accepted = d.accepted };
        },
        .set_value => |v| ev.value = v,
    }
    return deliver(w, id, hk, &ev);
}

/// Calls the node's siv_on handler for the kind, then, unless it returned
/// true, its siv_on_default handler.
fn deliver(w: *Window, id: NodeId, hk: ui.HandlerKind, ev: *const t.Event) bool {
    const self = w.owner;
    self.enter();
    defer self.leave();
    const handle: t.Node = @fromBackingInt(w.nodes.handle(id));
    if (w.nodes.slot(id, hk).*) |cb| {
        if (cb.func(cb.user_data, handle, ev)) return true;
        // The handler may have removed the node or destroyed the window.
        if (w.dead or w.nodes.handle(id) != @backingInt(handle)) return false;
    }
    const d = w.nodes.defaultSlot(id, hk).* orelse return false;
    return d.func(d.user_data, handle, ev);
}

/// An editor's text and selection as the application sees them: a masked
/// editor's real text, with offsets into it rather than into its bullets.
fn editorText(e: *const EditorData) struct { text: []const u8, caret: u32, anchor: u32 } {
    if (!e.editor.masked) return .{ .text = e.text.content, .caret = e.caret, .anchor = e.anchor };
    return .{
        .text = e.secret,
        .caret = maskedOffset(e.text.content, e.secret, e.caret),
        .anchor = maskedOffset(e.text.content, e.secret, e.anchor),
    };
}

/// The offset in `to` after as many code points as `from` has before
/// `offset`. A masked editor's bullets and real text have the same count.
fn maskedOffset(from: []const u8, to: []const u8, offset: u32) u32 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < @min(offset, from.len)) : (n += 1) i += std.unicode.utf8ByteSequenceLength(from[i]) catch 1;
    var j: usize = 0;
    while (n > 0 and j < to.len) : (n -= 1) j += std.unicode.utf8ByteSequenceLength(to[j]) catch 1;
    return @intCast(@min(j, to.len));
}

fn modifiers(m: platform.Mods) t.Modifiers {
    return .{ .shift = m.shift, .ctrl = m.ctrl, .alt = m.alt, .super = m.super, .caps_lock = m.caps_lock, .num_lock = m.num_lock };
}

// Queries ---------------------------------------------------------------------

/// The window and node a handle names, outside any transaction.
pub fn lookup(node: t.Node) Error!struct { *Window, NodeId } {
    const self, const payload = try runtime.Root.owner(App, application.app_tag, @backingInt(node), node_tag);
    const w = self.windows.items[payload >> node_bits] orelse return error.InvalidHandle;
    return .{ w, @enumFromInt(payload & (max_nodes - 1)) };
}

pub export fn siv_node_get_text(node: t.Node, text: ?[*]u8, text_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const w, const id = try lookup(n);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const un = w.uiWin().node(id);
            if (!un.isText()) return error.InvalidArgument;
            const content = if (un.kind == .editor) editorText(&un.data.editor).text else un.textData().content;
            const k = @min(content.len, buf.len);
            @memcpy(buf[0..k], content[0..k]);
            dest.* = content.len;
        }
    }.f(node, text, text_cap, len));
}

pub export fn siv_node_get_selection(node: t.Node, caret: ?*u32, anchor: ?*u32) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, c: ?*u32, a: ?*u32) Error!void {
            const w, const id = try lookup(n);
            const dc = try runtime.out(u32, c);
            const da = try runtime.out(u32, a);
            const un = w.uiWin().node(id);
            if (un.kind != .editor) return error.InvalidArgument;
            const s = editorText(&un.data.editor);
            dc.* = s.caret;
            da.* = s.anchor;
        }
    }.f(node, caret, anchor));
}

pub export fn siv_node_get_rect(node: t.Node, rect: ?*t.Rect) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, out: ?*t.Rect) Error!void {
            const w, const id = try lookup(n);
            const dest = try runtime.out(t.Rect, out);
            const r = w.uiWin().windowRect(id);
            dest.* = .{ .x = r.x0, .y = r.y0, .width = r.x1 - r.x0, .height = r.y1 - r.y0 };
        }
    }.f(node, rect));
}

pub export fn siv_node_get_data(node: t.Node, key: ?*anyopaque, data: ?*?*anyopaque) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, k: ?*anyopaque, out: ?*?*anyopaque) Error!void {
            const w, const id = try lookup(n);
            const dest = try runtime.out(?*anyopaque, out);
            const d = w.nodes.findData(id, @intFromPtr(k orelse return error.InvalidArgument));
            dest.* = if (d) |x| x.bytes() else null;
        }
    }.f(node, key, data));
}

pub export fn siv_node_get_label(node: t.Node, label: ?[*]u8, label_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const w, const id = try lookup(n);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const s = w.uiWin().node(id).semantics.label;
            const k = @min(s.len, buf.len);
            @memcpy(buf[0..k], s[0..k]);
            dest.* = s.len;
        }
    }.f(node, label, label_cap, len));
}

pub export fn siv_node_get_window(node: t.Node, window: ?*t.Window) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, out: ?*t.Window) Error!void {
            const w, _ = try lookup(n);
            const dest = try runtime.out(t.Window, out);
            dest.* = @fromBackingInt(w.handle);
        }
    }.f(node, window));
}

pub export fn siv_node_get_related(node: t.Node, relation: t.Relation, related: ?*t.Node) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, rel: t.Relation, out: ?*t.Node) Error!void {
            const w, const id = try lookup(n);
            const dest = try runtime.out(t.Node, out);
            const un = w.uiWin().node(id);
            const r: NodeId = switch (try runtime.enumValue(t.Relation, rel)) {
                .parent => un.parent,
                .first_child => un.first,
                .last_child => un.last,
                .next => un.next,
                .previous => un.prev,
                _ => unreachable,
            };
            dest.* = if (r == .none) .null else @fromBackingInt(w.nodes.handle(r));
        }
    }.f(node, relation, related));
}

pub export fn siv_node_is_rtl(node: t.Node, rtl: ?*bool) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, out: ?*bool) Error!void {
            const w, const id = try lookup(n);
            const dest = try runtime.out(bool, out);
            const uw = w.uiWin();
            var cur = id;
            dest.* = while (cur != .none) : (cur = uw.node(cur).parent) {
                switch (uw.node(cur).layout.direction) {
                    .inherit => {},
                    .ltr => break false,
                    .rtl => break true,
                }
            } else uw.rtl;
        }
    }.f(node, rtl));
}

pub export fn siv_emit(node: t.Node, event: ?*const t.Event, handled: ?*bool) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, e_ptr: ?*const t.Event, out: ?*bool) Error!void {
            const w, const id = try lookup(n);
            const dest = try runtime.out(bool, out);
            var ev = try runtime.readDesc(t.Event, e_ptr);
            const hk = try handlerKind(ev.type);
            if (w.owner.painting != 0) return error.Busy;
            ev.size = @sizeOf(t.Event);
            ev.window = @fromBackingInt(w.handle);
            dest.* = deliver(w, id, hk, &ev);
        }
    }.f(node, event, handled));
}

pub export fn siv_node_focus(node: t.Node) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node) Error!void {
            const w, const id = try lookup(n);
            if (w.owner.painting != 0) return error.Busy;
            const uw = w.uiWin();
            if (!uw.node(id).canFocus()) return error.InvalidArgument;
            ui.input.setFocus(uw, id, false);
        }
    }.f(node));
}

// Conversions -----------------------------------------------------------------

pub fn color(c: t.Color, zero: scene.Color) Error!scene.Color {
    for ([_]f32{ c.r, c.g, c.b, c.a }) |v| if (!std.math.isFinite(v)) return error.InvalidArgument;
    if (c.r == 0 and c.g == 0 and c.b == 0 and c.a == 0) return zero;
    const cl = struct {
        fn f(v: f32) f32 {
            return std.math.clamp(v, 0, 1);
        }
    }.f;
    return .srgb(cl(c.r), cl(c.g), cl(c.b), cl(c.a));
}

/// A themed color; `none` only where a literal color is the alternative.
pub fn colorToken(tok: t.ColorToken, none_ok: bool) Error!ui.ColorToken {
    _ = try runtime.enumValue(t.ColorToken, tok);
    if (!none_ok and tok == .none) return error.InvalidArgument;
    return @enumFromInt(@backingInt(tok));
}

comptime {
    for (@typeInfo(ui.TextRole).@"enum".field_names, 0..) |name, i| {
        if (@backingInt(@field(t.TextRole, name)) != i) @compileError("siv_text_role does not match ui.TextRole at " ++ name);
    }
    for (@typeInfo(ui.ColorToken).@"enum".field_names, 0..) |name, i| {
        if (@backingInt(@field(t.ColorToken, name)) != i) @compileError("siv_color_token does not match ui.ColorToken at " ++ name);
    }
    if (@typeInfo(t.ColorToken).@"enum".field_names.len != @typeInfo(ui.ColorToken).@"enum".field_names.len) @compileError("siv_color_token has tokens ui.ColorToken lacks");
}

fn alignment(a: t.Align, auto: ui.Align) Error!ui.Align {
    return switch (try runtime.enumValue(t.Align, a)) {
        .auto => auto,
        .start => .start,
        .center => .center,
        .end => .end,
        .stretch => .stretch,
        _ => unreachable,
    };
}

fn dimension(d: t.Dimension) Error!ui.Dimension {
    return switch (try runtime.enumValue(t.Unit, d.unit)) {
        .auto => .auto,
        .px => .{ .px = d.value },
        .fraction => .{ .fraction = d.value },
        _ => unreachable,
    };
}

fn gridLine(v: u32) Error!?u16 {
    if (v == 0) return null;
    if (v > std.math.maxInt(u16)) return error.InvalidArgument;
    return @intCast(v - 1);
}

fn span(v: u32) Error!u16 {
    if (v > std.math.maxInt(u16)) return error.InvalidArgument;
    return if (v == 0) 1 else @intCast(v);
}

fn layoutOf(ptr: ?*const t.LayoutDesc) Error!ui.Layout {
    const d = try runtime.readDesc(t.LayoutDesc, ptr);
    const fl = try runtime.flags(t.LayoutFlags, d.flags);
    return .{
        .width = try dimension(d.width),
        .height = try dimension(d.height),
        .basis = try dimension(d.basis),
        .min_width = d.min_width,
        .max_width = if (d.max_width == 0) std.math.inf(f32) else d.max_width,
        .min_height = d.min_height,
        .max_height = if (d.max_height == 0) std.math.inf(f32) else d.max_height,
        .padding = .{ .start = d.padding.start, .end = d.padding.end, .top = d.padding.top, .bottom = d.padding.bottom },
        .direction = switch (try runtime.enumValue(t.Direction, d.direction)) {
            .inherit => .inherit,
            .ltr => .ltr,
            .rtl => .rtl,
            _ => unreachable,
        },
        .align_x = try alignment(d.align_x, .auto),
        .align_y = try alignment(d.align_y, .auto),
        .grow = d.grow,
        .shrink = if (fl.no_shrink) 0 else if (d.shrink == 0) 1 else d.shrink,
        .column = try gridLine(d.column),
        .row = try gridLine(d.row),
        .column_span = try span(d.column_span),
        .row_span = try span(d.row_span),
        .inset = .{
            .start = if (fl.inset_start) d.inset_start else null,
            .end = if (fl.inset_end) d.inset_end else null,
            .top = if (fl.inset_top) d.inset_top else null,
            .bottom = if (fl.inset_bottom) d.inset_bottom else null,
        },
    };
}

fn flexOf(ptr: ?*const t.FlexDesc) Error!ui.Flex {
    const d = try runtime.readDesc(t.FlexDesc, ptr);
    const fl = try runtime.flags(t.FlexFlags, d.flags);
    return .{
        .axis = switch (try runtime.enumValue(t.Axis, d.axis)) {
            .row => .row,
            .column => .column,
            _ => unreachable,
        },
        .gap = d.gap,
        .line_gap = if (fl.line_gap) d.line_gap else null,
        .justify = switch (try runtime.enumValue(t.Justify, d.justify)) {
            .start => .start,
            .center => .center,
            .end => .end,
            .space_between => .space_between,
            .space_around => .space_around,
            .space_evenly => .space_evenly,
            _ => unreachable,
        },
        .align_items = try alignment(d.align_items, .stretch),
        .wrap = fl.wrap,
    };
}

fn stackOf(ptr: ?*const t.StackDesc) Error!ui.Stack {
    const d = try runtime.readDesc(t.StackDesc, ptr);
    return .{ .align_x = try alignment(d.align_x, .start), .align_y = try alignment(d.align_y, .start) };
}

fn setGrid(w: *Window, id: NodeId, ptr: ?*const t.GridDesc) Error!void {
    const d = try runtime.readDesc(t.GridDesc, ptr);
    const columns = try runtime.array(t.Track, d.columns, d.columns_count);
    const rows = try runtime.array(t.Track, d.rows, d.rows_count);
    const gpa = w.owner.gpa();
    const tracks = try gpa.alloc(ui.Track, columns.len + rows.len);
    defer gpa.free(tracks);
    for (columns, tracks[0..columns.len]) |c, *o| o.* = try track(c);
    for (rows, tracks[columns.len..]) |r, *o| o.* = try track(r);
    w.txn.ut.setGrid(id, .{
        .columns = tracks[0..columns.len],
        .rows = tracks[columns.len..],
        .column_gap = d.column_gap,
        .row_gap = d.row_gap,
        .align_x = try alignment(d.align_x, .stretch),
        .align_y = try alignment(d.align_y, .stretch),
    }) catch |err| return mapTxn(err);
}

fn track(tr: t.Track) Error!ui.Track {
    return switch (try runtime.enumValue(t.TrackUnit, tr.unit)) {
        .auto => .auto,
        .px => .{ .px = tr.value },
        .fr => .{ .fr = tr.value },
        _ => unreachable,
    };
}

fn scrollAxis(a: t.ScrollAxis) Error!ui.ScrollAxis {
    return switch (try runtime.enumValue(t.ScrollAxis, a)) {
        .vertical => .vertical,
        .horizontal => .horizontal,
        .both => .both,
        _ => unreachable,
    };
}

fn toggle(v: t.Toggle) Error!ui.Toggle {
    return switch (try runtime.enumValue(t.Toggle, v)) {
        .unset => .unset,
        .off => .off,
        .on => .on,
        .mixed => .mixed,
        _ => unreachable,
    };
}

// siv_role is ui.Role shifted by one (0 is the kind's default).
comptime {
    for (@typeInfo(ui.Role).@"enum".field_names, @typeInfo(ui.Role).@"enum".field_values) |name, v| {
        if (@backingInt(@field(t.Role, name)) != v + 1) @compileError("siv_role does not match ui.Role at " ++ name);
    }
    if (@typeInfo(t.Role).@"enum".field_names.len != @typeInfo(ui.Role).@"enum".field_names.len + 1) @compileError("siv_role has roles ui.Role lacks");
}
