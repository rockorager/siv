//! Transactions (D4): every change to the tree is made inside one and
//! becomes visible atomically when it is committed.
//!
//! Operations apply to the tree immediately, so later operations and
//! queries in the same transaction see them, but frames do not run while a
//! transaction is open. Before a node changes for the first time in a
//! transaction its committed state is copied; `abort` restores the copies.
//! Every allocation an operation needs happens before it changes anything,
//! so a failed operation has no effect and the transaction stays usable;
//! `commit` cannot fail. Memory that committed nodes stop referring to is
//! freed at commit, and removed nodes are destroyed then.

const std = @import("std");
const node_mod = @import("node.zig");
const Window = @import("Window.zig");
const secret = @import("secret.zig");
const Image = @import("image.zig").Image;

const NodeId = node_mod.NodeId;
const Node = node_mod.Node;
const Kind = node_mod.Kind;

pub const Error = error{
    OutOfMemory,
    /// A node does not exist, has the wrong kind for the operation, or the
    /// operation would break the tree (a cycle, children under a leaf,
    /// removing the root).
    InvalidNode,
    /// A value is out of range (NaN, negative sizes, invalid UTF-8).
    InvalidArgument,
};

/// The most nodes one operation touches (a move: the node, both parents,
/// and up to three siblings).
const max_touched = 8;

const Snapshot = struct { id: NodeId, node: Node };

const Alloc = struct {
    bytes: []u8 = &.{},
    alignment: std.mem.Alignment = .@"1",
    /// Locked memory from secret.zig.
    secret: bool = false,
    /// A reference to drop instead of memory to free.
    image: ?*Image = null,

    fn of(comptime T: type, slice: []const T) Alloc {
        return .{ .bytes = @constCast(std.mem.sliceAsBytes(slice)), .alignment = .of(T) };
    }

    fn free(a: Alloc, gpa: std.mem.Allocator) void {
        if (a.image) |img| return img.release();
        if (a.secret) return secret.free(a.bytes);
        if (a.bytes.len != 0) gpa.rawFree(a.bytes, a.alignment, @returnAddress());
    }
};

pub const Txn = struct {
    win: *Window = undefined,
    open: bool = false,
    epoch: u32 = 0,
    snapshots: std.ArrayList(Snapshot) = .empty,
    /// Made by this transaction: freed on abort.
    allocs: std.ArrayList(Alloc) = .empty,
    /// Replaced by this transaction: freed on commit.
    frees: std.ArrayList(Alloc) = .empty,
    /// Roots of removed subtrees, destroyed on commit.
    removed: std.ArrayList(NodeId) = .empty,
    /// Nodes in removed subtrees, for reserving `Window.dead`.
    removed_count: usize = 0,
    saved_free_head: NodeId = .none,
    saved_len: usize = 0,

    pub fn deinit(t: *Txn, gpa: std.mem.Allocator) void {
        t.snapshots.deinit(gpa);
        t.allocs.deinit(gpa);
        t.frees.deinit(gpa);
        t.removed.deinit(gpa);
    }

    pub fn start(t: *Txn, win: *Window) void {
        t.win = win;
        t.open = true;
        t.epoch +%= 1;
        if (t.epoch == 0) t.epoch = 1;
        t.saved_free_head = win.free_head;
        t.saved_len = win.nodes.items.len;
        t.removed_count = 0;
    }

    /// Applies the transaction. Cannot fail.
    pub fn commit(t: *Txn) void {
        std.debug.assert(t.open);
        const win = t.win;
        for (t.removed.items) |id| t.destroy(id);
        for (t.frees.items) |a| a.free(win.gpa);
        t.finish();
        win.input.afterCommit(win);
        win.requestFrame();
    }

    /// Discards every change since `begin`.
    pub fn abort(t: *Txn) void {
        std.debug.assert(t.open);
        const win = t.win;
        for (t.snapshots.items) |snap| {
            if (snap.id.index() < t.saved_len) win.node(snap.id).* = snap.node;
        }
        win.nodes.shrinkRetainingCapacity(t.saved_len);
        win.states.shrinkRetainingCapacity(t.saved_len);
        win.free_head = t.saved_free_head;
        for (t.allocs.items) |a| a.free(win.gpa);
        t.finish();
        win.requestFrame();
    }

    fn finish(t: *Txn) void {
        t.snapshots.clearRetainingCapacity();
        t.allocs.clearRetainingCapacity();
        t.frees.clearRetainingCapacity();
        t.removed.clearRetainingCapacity();
        t.open = false;
    }

    fn destroy(t: *Txn, id: NodeId) void {
        const win = t.win;
        var it = win.children(id);
        while (it.next()) |c| t.destroy(c);
        win.forget(id);
        const n = win.node(id);
        Window.freeNodeData(win.gpa, n);
        n.* = .{ .kind = .box, .status = .dead, .data = .{ .box = {} } };
        win.dead.appendAssumeCapacity(id);
    }

    // Bookkeeping -----------------------------------------------------------

    fn reserve(t: *Txn) Error!void {
        try t.snapshots.ensureUnusedCapacity(t.win.gpa, max_touched);
    }

    fn touch(t: *Txn, id: NodeId) void {
        if (id == .none) return;
        const s = t.win.state(id);
        if (s.touched == t.epoch) return;
        s.touched = t.epoch;
        t.snapshots.appendAssumeCapacity(.{ .id = id, .node = t.win.node(id).* });
    }

    /// Copies `slice` into memory the tree will own.
    fn own(t: *Txn, comptime T: type, slice: []const T) Error![]const T {
        try t.allocs.ensureUnusedCapacity(t.win.gpa, 1);
        try t.frees.ensureUnusedCapacity(t.win.gpa, 2);
        if (slice.len == 0) return &.{};
        const copy = try t.win.gpa.dupe(T, slice);
        t.allocs.appendAssumeCapacity(.of(T, copy));
        return copy;
    }

    /// Copies `bytes` into locked memory the tree will own.
    fn ownSecret(t: *Txn, bytes: []const u8) Error![]const u8 {
        try t.allocs.ensureUnusedCapacity(t.win.gpa, 1);
        try t.frees.ensureUnusedCapacity(t.win.gpa, 2);
        const copy = try secret.dupe(bytes);
        t.allocs.appendAssumeCapacity(.{ .bytes = @constCast(copy), .alignment = .@"1", .secret = true });
        return copy;
    }

    fn releaseSecret(t: *Txn, bytes: []const u8) void {
        if (bytes.len != 0) t.frees.appendAssumeCapacity(.{ .bytes = @constCast(bytes), .alignment = .@"1", .secret = true });
    }

    /// One bullet per code point of `s`.
    fn bullets(t: *Txn, s: []const u8) Error![]const u8 {
        const n = std.unicode.utf8CountCodepoints(s) catch unreachable;
        const a = t.win.scratch.allocator();
        const out = try a.alloc(u8, n * bullet.len);
        for (0..n) |i| @memcpy(out[i * bullet.len ..][0..bullet.len], bullet);
        return out;
    }

    /// `slice` is no longer referenced once the transaction commits.
    /// Capacity was reserved by `own`.
    fn release(t: *Txn, comptime T: type, slice: []const T) void {
        if (slice.len != 0) t.frees.appendAssumeCapacity(.of(T, slice));
    }

    fn live(t: *Txn, id: NodeId) Error!*Node {
        if (!t.win.isLive(id)) return error.InvalidNode;
        return t.win.node(id);
    }

    fn container(t: *Txn, id: NodeId) Error!*Node {
        const n = try t.live(id);
        if (n.kind.isLeaf()) return error.InvalidNode;
        return n;
    }

    fn link(t: *Txn, parent: NodeId, id: NodeId, before: NodeId) void {
        const win = t.win;
        const p = win.node(parent);
        const prev = if (before == .none) p.last else win.node(before).prev;
        t.touch(parent);
        t.touch(id);
        t.touch(prev);
        t.touch(before);
        const n = win.node(id);
        n.parent = parent;
        n.prev = prev;
        n.next = before;
        if (prev == .none) p.first = id else win.node(prev).next = id;
        if (before == .none) p.last = id else win.node(before).prev = id;
    }

    fn unlink(t: *Txn, id: NodeId) void {
        const win = t.win;
        const n = win.node(id);
        const parent = n.parent;
        if (parent == .none) return;
        t.touch(id);
        t.touch(parent);
        t.touch(n.prev);
        t.touch(n.next);
        const p = win.node(parent);
        if (n.prev == .none) p.first = n.next else win.node(n.prev).next = n.next;
        if (n.next == .none) p.last = n.prev else win.node(n.next).prev = n.prev;
        n.parent = .none;
        n.prev = .none;
        n.next = .none;
    }

    fn checkBefore(t: *Txn, parent: NodeId, before: NodeId) Error!void {
        if (before == .none) return;
        const b = try t.live(before);
        if (b.parent != parent) return error.InvalidNode;
    }

    // Structure -------------------------------------------------------------

    /// Creates a node of `kind` under `parent`, before the child `before`
    /// (or last).
    pub fn create(t: *Txn, parent: NodeId, kind: Kind, before: NodeId) Error!NodeId {
        std.debug.assert(t.open);
        _ = try t.container(parent);
        try t.checkBefore(parent, before);
        try t.reserve();
        const win = t.win;
        const id: NodeId = if (win.free_head != .none) blk: {
            const id = win.free_head;
            t.touch(id);
            win.free_head = win.node(id).next;
            break :blk id;
        } else blk: {
            try win.nodes.ensureUnusedCapacity(win.gpa, 1);
            try win.states.ensureUnusedCapacity(win.gpa, 1);
            win.nodes.appendAssumeCapacity(undefined);
            win.states.appendAssumeCapacity(.{});
            break :blk @enumFromInt(win.nodes.items.len - 1);
        };
        win.node(id).* = .{ .kind = kind, .data = .default(kind) };
        win.state(id).* = .{ .touched = t.epoch };
        t.link(parent, id, before);
        win.markLayout(id);
        win.markLayers();
        return id;
    }

    /// Moves a node (with its subtree) under `parent`, before `before`.
    pub fn move(t: *Txn, id: NodeId, parent: NodeId, before: NodeId) Error!void {
        _ = try t.live(id);
        if (id == .root or before == id) return error.InvalidNode;
        _ = try t.container(parent);
        if (t.win.isAncestor(id, parent)) return error.InvalidNode;
        try t.checkBefore(parent, before);
        try t.reserve();
        const win = t.win;
        win.markLayout(win.node(id).parent);
        t.unlink(id);
        t.link(parent, id, before);
        win.markSubtreeLayout(id);
        win.markLayers();
    }

    /// Removes a node and its subtree; they are destroyed at commit.
    pub fn remove(t: *Txn, id: NodeId) Error!void {
        _ = try t.live(id);
        if (id == .root) return error.InvalidNode;
        try t.reserve();
        const win = t.win;
        const count = subtreeSize(win, id);
        try t.removed.ensureUnusedCapacity(win.gpa, 1);
        try win.dead.ensureUnusedCapacity(win.gpa, t.removed_count + count);
        win.markLayout(win.node(id).parent);
        t.unlink(id);
        t.removed.appendAssumeCapacity(id);
        t.removed_count += count;
        win.markLayers();
    }

    fn subtreeSize(win: *const Window, id: NodeId) usize {
        var n: usize = 1;
        var it = win.children(id);
        while (it.next()) |c| n += subtreeSize(win, c);
        return n;
    }

    // Properties ------------------------------------------------------------

    pub fn setLayout(t: *Txn, id: NodeId, l: node_mod.Layout) Error!void {
        const n = try t.live(id);
        try checkLayout(l);
        if (std.meta.eql(n.layout, l)) return;
        try t.reserve();
        t.touch(id);
        const direction_changed = n.layout.direction != l.direction;
        n.layout = l;
        if (direction_changed) t.win.markSubtreeLayout(id) else t.win.markLayout(id);
    }

    pub fn setVisual(t: *Txn, id: NodeId, v: node_mod.Visual) Error!void {
        const n = try t.live(id);
        if (!finite(v.opacity) or !finite(v.border_width) or v.border_width < 0 or !finiteTransform(v.transform))
            return error.InvalidArgument;
        const old = n.visual;
        if (std.meta.eql(old, v)) return;
        try t.reserve();
        t.touch(id);
        n.visual = v;
        n.visual.opacity = std.math.clamp(v.opacity, 0, 1);
        const win = t.win;
        if (isLayerRoot(old) != isLayerRoot(n.visual) or old.clip != v.clip) win.markLayers();
        if (old.opacity != n.visual.opacity or !old.transform.eql(v.transform)) win.dirty.props = true;
        if (!std.meta.eql(old.background, v.background) or old.border_width != v.border_width or
            !std.meta.eql(old.border_color, v.border_color) or !std.meta.eql(old.radius, v.radius) or old.clip != v.clip or
            old.background_token != v.background_token or old.border_token != v.border_token)
            win.markPaint(id);
        if (old.hit_test != v.hit_test) win.markLayers();
        if (old.hidden != v.hidden) {
            // Hidden subtrees take no space and paint nothing; what they
            // painted is damaged now, since no layer visits them.
            if (v.hidden) hideSubtree(win, id);
            win.markLayout(id);
            win.markSubtreeLayout(id);
            win.markLayers();
        }
    }

    fn hideSubtree(win: *Window, id: NodeId) void {
        const s = win.state(id);
        win.paint.damage(s.layer, s.bounds);
        s.bounds = .empty;
        s.paint_dirty = true;
        var it = win.children(id);
        while (it.next()) |c| hideSubtree(win, c);
    }

    pub fn setSemantics(t: *Txn, id: NodeId, sem: node_mod.Semantics) Error!void {
        const n = try t.live(id);
        if (sem.value) |r| if (!(r.min <= r.max) or !std.math.isFinite(r.now) or !(r.step >= 0) or !std.math.isFinite(r.step)) return error.InvalidArgument;
        if (!std.unicode.utf8ValidateSlice(sem.label) or !std.unicode.utf8ValidateSlice(sem.description)) return error.InvalidArgument;
        try t.reserve();
        const label = try t.own(u8, sem.label);
        const description = try t.own(u8, sem.description);
        t.touch(id);
        t.release(u8, n.semantics.label);
        t.release(u8, n.semantics.description);
        n.semantics = sem;
        n.semantics.label = label;
        n.semantics.description = description;
        t.win.dirty.semantics = true;
        // Focus rings follow focusability.
        t.win.markPaint(id);
    }

    /// Sets (or with null clears) the handler for one kind of event.
    pub fn on(t: *Txn, id: NodeId, kind: node_mod.HandlerKind, handler: ?node_mod.Handler) Error!void {
        const n = try t.live(id);
        try t.reserve();
        t.touch(id);
        n.handlers[@intFromEnum(kind)] = handler;
        // Scroll handlers decide which scroll input the UI sees first.
        if (kind == .scroll) t.win.markLayers();
        t.win.dirty.semantics = true;
    }

    /// Makes the node a drop target (D19), or with no mime types stops it
    /// being one. Mime types are printable ASCII without spaces, one per
    /// line.
    pub fn setDropTarget(t: *Txn, id: NodeId, target: node_mod.DropTarget) Error!void {
        const n = try t.live(id);
        for (target.mimes) |c| if (c != '\n' and (c <= ' ' or c >= 0x7f)) return error.InvalidArgument;
        if (target.mimes.len != 0 and target.actions.none()) return error.InvalidArgument;
        try t.reserve();
        const mimes = try t.own(u8, target.mimes);
        t.touch(id);
        t.release(u8, n.drop.mimes);
        n.drop = target;
        n.drop.mimes = mimes;
    }

    /// Sets the pointer cursor over the node (D16), or with null inherits
    /// its parent's.
    pub fn setCursor(t: *Txn, id: NodeId, shape: ?node_mod.CursorShape) Error!void {
        const n = try t.live(id);
        try t.reserve();
        t.touch(id);
        n.cursor = shape;
    }

    fn data(t: *Txn, id: NodeId, kind: Kind) Error!*Node {
        const n = try t.live(id);
        if (n.kind != kind) return error.InvalidNode;
        return n;
    }

    fn textNode(t: *Txn, id: NodeId) Error!*Node {
        const n = try t.live(id);
        if (!n.isText()) return error.InvalidNode;
        return n;
    }

    /// Sets the text of a text or editor node. An editor's selection is
    /// kept where it still fits and otherwise moves to the end.
    pub fn setText(t: *Txn, id: NodeId, content: []const u8) Error!void {
        const n = try t.textNode(id);
        if (content.len >= std.math.maxInt(u32) or !std.unicode.utf8ValidateSlice(content)) return error.InvalidArgument;
        const d = n.textData();
        const masked = n.kind == .editor and n.data.editor.editor.masked;
        if (std.mem.eql(u8, if (masked) n.data.editor.secret else d.content, content)) return;
        try t.reserve();
        const shown = if (masked) try t.bullets(content) else content;
        const copy = try t.own(u8, shown);
        const hidden = if (masked) try t.ownSecret(content) else "";
        t.touch(id);
        t.release(u8, d.content);
        d.content = copy;
        if (n.kind == .editor) {
            const e = &n.data.editor;
            if (masked) {
                t.releaseSecret(e.secret);
                e.secret = hidden;
            }
            e.caret = charBoundary(copy, e.caret);
            e.anchor = charBoundary(copy, e.anchor);
            e.revision +%= 1;
        }
        t.win.markShape(id);
        t.win.dirty.semantics = true;
    }

    /// Masking moves the text into locked memory (and unmasking back) and
    /// counts as a text change.
    pub fn setEditor(t: *Txn, id: NodeId, e: node_mod.Editor) Error!void {
        const n = try t.data(id, .editor);
        const ed = &n.data.editor;
        if (std.meta.eql(ed.editor, e)) return;
        try t.reserve();
        if (ed.editor.masked != e.masked) {
            const plain = if (ed.editor.masked) ed.secret else ed.text.content;
            const shown = try t.own(u8, if (e.masked) try t.bullets(plain) else plain);
            const hidden = if (e.masked) try t.ownSecret(plain) else "";
            t.touch(id);
            t.release(u8, ed.text.content);
            t.releaseSecret(ed.secret);
            ed.text.content = shown;
            ed.secret = hidden;
            ed.caret = @intCast(shown.len);
            ed.anchor = ed.caret;
            ed.revision +%= 1;
            t.win.markShape(id);
            t.win.dirty.semantics = true;
        } else t.touch(id);
        ed.editor = e;
        t.win.markLayout(id);
    }

    /// Sets the text an empty editor shows in the muted color.
    pub fn setPlaceholder(t: *Txn, id: NodeId, text: []const u8) Error!void {
        const n = try t.data(id, .editor);
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfAny(u8, text, "\r\n") != null) return error.InvalidArgument;
        const e = &n.data.editor;
        if (std.mem.eql(u8, e.placeholder, text)) return;
        try t.reserve();
        const copy = try t.own(u8, text);
        t.touch(id);
        t.release(u8, e.placeholder);
        e.placeholder = copy;
        t.win.markShape(id);
        t.win.dirty.semantics = true;
    }

    /// Moves an editor's caret and selection anchor (byte offsets, snapped
    /// back to character boundaries). Repaints only.
    pub fn setSelection(t: *Txn, id: NodeId, caret: u32, anchor: u32, affinity: @import("text").layout.Affinity) Error!void {
        const n = try t.data(id, .editor);
        const e = &n.data.editor;
        const c = charBoundary(e.text.content, caret);
        const a = charBoundary(e.text.content, anchor);
        if (e.caret == c and e.anchor == a and e.affinity == affinity) return;
        try t.reserve();
        t.touch(id);
        e.caret = c;
        e.anchor = a;
        e.affinity = affinity;
        t.win.markPaint(id);
        t.win.dirty.semantics = true;
    }

    /// Text style, alignment, and wrapping. Color and alignment only
    /// repaint; wrapping relayouts; anything else reshapes.
    pub fn setTextProps(t: *Txn, id: NodeId, props: node_mod.Text) Error!void {
        const n = try t.textNode(id);
        if (!(props.style.size > 0) or !finite(props.style.size)) return error.InvalidArgument;
        try t.reserve();
        const fonts = t.win.fonts;
        const family = try fonts.intern(props.style.family);
        const language = try fonts.intern(props.style.language);
        const d = n.textData();
        const old = d.*;
        t.touch(id);
        d.props = props;
        d.props.style.family = fonts.name(family);
        d.props.style.language = fonts.name(language);
        d.family = family;
        d.language = language;
        const os = old.props.style;
        const ns = props.style;
        if (old.family != family or old.language != language or os.size != ns.size or os.weight != ns.weight or os.slant != ns.slant or os.size_role != ns.size_role) {
            t.win.markShape(id);
        } else if (old.props.wrap != props.wrap) {
            t.win.markLayout(id);
        }
        t.win.markPaint(id);
    }

    pub fn setFlex(t: *Txn, id: NodeId, f: node_mod.Flex) Error!void {
        const n = try t.data(id, .flex);
        if (!finite(f.gap) or f.gap < 0 or (f.line_gap != null and !(f.line_gap.? >= 0))) return error.InvalidArgument;
        if (std.meta.eql(n.data.flex, f)) return;
        try t.reserve();
        t.touch(id);
        n.data.flex = f;
        t.win.markLayout(id);
    }

    pub fn setGrid(t: *Txn, id: NodeId, g: node_mod.Grid) Error!void {
        const n = try t.data(id, .grid);
        if (!(g.column_gap >= 0) or !(g.row_gap >= 0) or !finite(g.column_gap) or !finite(g.row_gap)) return error.InvalidArgument;
        for ([_][]const node_mod.Track{ g.columns, g.rows }) |tracks| for (tracks) |tr| switch (tr) {
            .px, .fr => |v| if (!(v >= 0) or !finite(v)) return error.InvalidArgument,
            .auto => {},
        };
        try t.reserve();
        const columns = try t.own(node_mod.Track, g.columns);
        const rows = try t.own(node_mod.Track, g.rows);
        t.touch(id);
        t.release(node_mod.Track, n.data.grid.columns);
        t.release(node_mod.Track, n.data.grid.rows);
        n.data.grid = g;
        n.data.grid.columns = columns;
        n.data.grid.rows = rows;
        t.win.markLayout(id);
    }

    pub fn setStack(t: *Txn, id: NodeId, s: node_mod.Stack) Error!void {
        const n = try t.data(id, .stack);
        if (std.meta.eql(n.data.stack, s)) return;
        try t.reserve();
        t.touch(id);
        n.data.stack = s;
        t.win.markLayout(id);
    }

    /// Changing the offset scrolls on the compositor without layout or
    /// repainting.
    pub fn setScroll(t: *Txn, id: NodeId, s: node_mod.Scroll) Error!void {
        const n = try t.data(id, .scroll);
        if (!finite(s.offset.x) or !finite(s.offset.y)) return error.InvalidArgument;
        try t.reserve();
        t.touch(id);
        const old = n.data.scroll;
        n.data.scroll = s;
        if (old.axis != s.axis) t.win.markLayout(id);
        if (!old.offset.eql(s.offset)) {
            t.win.state(id).scroll_pending = true;
            t.win.dirty.props = true;
        }
    }

    /// The node takes a reference to `view.image`; the caller keeps its own.
    pub fn setImage(t: *Txn, id: NodeId, view: node_mod.ImageView) Error!void {
        const n = try t.data(id, .image);
        try t.reserve();
        try t.allocs.ensureUnusedCapacity(t.win.gpa, 1);
        try t.frees.ensureUnusedCapacity(t.win.gpa, 1);
        t.touch(id);
        const old = n.data.image;
        // The new reference is dropped if the transaction aborts, the old
        // one once it commits.
        if (view.image) |img| t.allocs.appendAssumeCapacity(.{ .image = img.retain() });
        if (old.image) |img| t.frees.appendAssumeCapacity(.{ .image = img });
        n.data.image = view;
        const ow, const oh = if (old.image) |r| .{ r.width, r.height } else .{ 0, 0 };
        const nw, const nh = if (view.image) |r| .{ r.width, r.height } else .{ 0, 0 };
        if (ow != nw or oh != nh or old.fit != view.fit) t.win.markLayout(id);
        t.win.markPaint(id);
    }

    pub fn setCanvas(t: *Txn, id: NodeId, c: node_mod.Canvas) Error!void {
        const n = try t.data(id, .canvas);
        if (!(c.width >= 0) or !(c.height >= 0) or !finite(c.width) or !finite(c.height)) return error.InvalidArgument;
        try t.reserve();
        t.touch(id);
        const old = n.data.canvas;
        n.data.canvas = c;
        if (old.width != c.width or old.height != c.height) t.win.markLayout(id);
        t.win.markPaint(id);
    }

    pub fn setExternal(t: *Txn, id: NodeId, x: node_mod.External) Error!void {
        const n = try t.data(id, .external);
        if (!(x.width >= 0) or !(x.height >= 0) or !finite(x.width) or !finite(x.height)) return error.InvalidArgument;
        try t.reserve();
        t.touch(id);
        const old = n.data.external;
        n.data.external = x;
        if (old.width != x.width or old.height != x.height or old.fit != x.fit) t.win.markLayout(id);
        t.win.dirty.props = true;
    }

    /// Repaints a canvas (its content changed).
    pub fn invalidate(t: *Txn, id: NodeId) Error!void {
        _ = try t.live(id);
        t.win.markPaint(id);
    }

    /// Lays a canvas out again, asking its measure callback, and repaints
    /// it (its size depends on content that changed).
    pub fn remeasure(t: *Txn, id: NodeId) Error!void {
        _ = try t.data(id, .canvas);
        t.win.markLayout(id);
        t.win.markPaint(id);
    }
};

/// `offset` clamped to `s` and moved back to the start of a UTF-8 sequence.
fn charBoundary(s: []const u8, offset: u32) u32 {
    var o: usize = @min(offset, s.len);
    while (o > 0 and o < s.len and s[o] & 0xc0 == 0x80) o -= 1;
    return @intCast(o);
}

/// What a masked editor shows for each code point.
pub const bullet = "\u{2022}";

pub fn isLayerRoot(v: node_mod.Visual) bool {
    return v.opacity < 1 or !v.transform.eql(.identity) or v.layer;
}

fn finite(v: f32) bool {
    return std.math.isFinite(v);
}

fn finiteTransform(t: node_mod.Transform) bool {
    return finite(t.translate.x) and finite(t.translate.y) and finite(t.scale.x) and finite(t.scale.y) and
        finite(t.rotate) and finite(t.origin.x) and finite(t.origin.y);
}

fn checkLayout(l: node_mod.Layout) Error!void {
    for ([_]node_mod.Dimension{ l.width, l.height, l.basis }) |d| switch (d) {
        .auto => {},
        .px, .fraction => |v| if (!(v >= 0) or !finite(v)) return error.InvalidArgument,
    };
    if (!(l.min_width >= 0) or !(l.min_height >= 0) or !finite(l.min_width) or !finite(l.min_height)) return error.InvalidArgument;
    if (!(l.max_width >= 0) or !(l.max_height >= 0)) return error.InvalidArgument;
    const p = l.padding;
    for ([_]f32{ p.start, p.end, p.top, p.bottom }) |v| if (!(v >= 0) or !finite(v)) return error.InvalidArgument;
    if (!(l.grow >= 0) or !(l.shrink >= 0) or !finite(l.grow) or !finite(l.shrink)) return error.InvalidArgument;
    if (l.column_span == 0 or l.row_span == 0) return error.InvalidArgument;
    inline for (.{ "start", "end", "top", "bottom" }) |f| if (@field(l.inset, f)) |v| if (!finite(v)) return error.InvalidArgument;
}
