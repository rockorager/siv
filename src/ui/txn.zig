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
const platform = @import("platform");
const node_mod = @import("node.zig");
const Window = @import("Window.zig");
const secret = @import("secret.zig");
const Image = @import("image.zig").Image;
const spans_mod = @import("spans.zig");
const Rope = @import("text").Rope;

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
    rope: ?Rope = null,

    fn of(comptime T: type, slice: []const T) Alloc {
        return .{ .bytes = @constCast(std.mem.sliceAsBytes(slice)), .alignment = .of(T) };
    }

    fn free(a: Alloc, gpa: std.mem.Allocator) void {
        if (a.image) |img| return img.release();
        if (a.rope) |r| return r.release(gpa);
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
    /// A rope of a copy of `bytes`, dropped on abort.
    fn ownRope(t: *Txn, bytes: []const u8) Error!Rope {
        try t.allocs.ensureUnusedCapacity(t.win.gpa, 1);
        try t.frees.ensureUnusedCapacity(t.win.gpa, 2);
        const r = try Rope.initBytes(t.win.gpa, bytes);
        t.allocs.appendAssumeCapacity(.{ .rope = r });
        return r;
    }

    /// `r` is no longer referenced once the transaction commits.
    fn releaseRope(t: *Txn, r: Rope) void {
        if (r.root != null) t.frees.appendAssumeCapacity(.{ .rope = r });
    }

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
        win.state(id).* = .{ .touched = t.epoch, .appear = true };
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
        if (!finite(v.opacity) or !finite(v.border_width) or v.border_width < 0 or !finiteTransform(v.transform) or
            !finite(v.animation.from) or !finite(v.animation.to))
            return error.InvalidArgument;
        if (v.shadow_count > node_mod.Visual.max_shadows) return error.InvalidArgument;
        for (v.shadowList()) |sh| if (!finite(sh.offset_x) or !finite(sh.offset_y) or !finite(sh.spread) or !finite(sh.sigma) or sh.sigma < 0)
            return error.InvalidArgument;
        const old = n.visual;
        if (std.meta.eql(old, v)) return;
        try t.reserve();
        t.touch(id);
        const was_hidden = n.isHidden();
        n.visual = v;
        n.visual.opacity = std.math.clamp(v.opacity, 0, 1);
        const win = t.win;
        if (isLayerRoot(old) != isLayerRoot(n.visual) or old.clip != v.clip or (old.shadow_count != 0) != (v.shadow_count != 0)) win.markLayers();
        if (old.opacity != n.visual.opacity or !old.transform.eql(v.transform) or !std.meta.eql(old.animation, v.animation) or
            !std.meta.eql(old.motion, v.motion))
            win.dirty.props = true;
        if (!std.meta.eql(old.background, v.background) or old.border_width != v.border_width or
            !std.meta.eql(old.border_color, v.border_color) or !std.meta.eql(old.radius, v.radius) or old.clip != v.clip or
            old.background_token != v.background_token or old.border_token != v.border_token or old.focus_ring != v.focus_ring or
            !std.meta.eql(old.shadows, v.shadows) or old.shadow_count != v.shadow_count)
            win.markPaint(id);
        if (old.hit_test != v.hit_test) win.markLayers();
        if (was_hidden != n.isHidden()) visibilityChanged(win, id, n.isHidden());
    }

    /// Hides or shows a node and its subtree as the application asks,
    /// apart from its visual (`Node.hidden`).
    pub fn setHidden(t: *Txn, id: NodeId, hidden: bool) Error!void {
        const n = try t.live(id);
        if (n.hidden == hidden) return;
        try t.reserve();
        t.touch(id);
        const was_hidden = n.isHidden();
        n.hidden = hidden;
        if (was_hidden != n.isHidden()) visibilityChanged(t.win, id, n.isHidden());
    }

    fn visibilityChanged(win: *Window, id: NodeId, hidden: bool) void {
        // Hidden subtrees take no space and paint nothing; what they
        // painted is damaged now, since no layer visits them.
        if (hidden) hideSubtree(win, id) else win.state(id).appear = true;
        win.markLayout(id);
        win.markSubtreeLayout(id);
        win.markLayers();
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
        if (sem.modal and !n.semantics.modal) {
            // Made modal last, it is the active modal while shown.
            const ms = &t.win.modals;
            if (std.mem.indexOfScalar(NodeId, ms.items, id)) |i| _ = ms.orderedRemove(i);
            try ms.append(t.win.gpa, id);
        }
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
        if (kind == .viewport and handler != null) {
            if (std.mem.indexOfScalar(NodeId, t.win.viewports.items, id) == null) try t.win.viewports.append(t.win.gpa, id);
            t.win.state(id).viewport = null;
        }
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

    /// Attaches an application undo stack to the node (D35), or with 0
    /// detaches it.
    pub fn setUndo(t: *Txn, id: NodeId, undo: u64) Error!void {
        const n = try t.live(id);
        try t.reserve();
        t.touch(id);
        n.undo = undo;
    }

    /// Sets a custom text widget's state for the input method (D15).
    pub fn setTextInput(t: *Txn, id: NodeId, ti: node_mod.TextInput) Error!void {
        const n = try t.live(id);
        if (!std.unicode.utf8ValidateSlice(ti.surrounding)) return error.InvalidArgument;
        if (ti.surrounding.len > platform.TextInputState.max_surrounding or ti.cursor > ti.surrounding.len or ti.anchor > ti.surrounding.len) return error.InvalidArgument;
        try t.reserve();
        var next = ti;
        next.surrounding = try t.own(u8, ti.surrounding);
        t.touch(id);
        t.release(u8, n.text_input.surrounding);
        n.text_input = next;
        t.win.ime.dirty = true;
    }

    /// Shows another process's accessible object under the node (D18):
    /// "BUS_NAME:/object/path"; empty removes it.
    pub fn setAccessibleEmbed(t: *Txn, id: NodeId, plug: []const u8) Error!void {
        const n = try t.live(id);
        if (plug.len != 0) {
            const sep = std.mem.indexOf(u8, plug, ":/") orelse return error.InvalidArgument;
            if (sep == 0 or plug.len - sep - 1 > 95 or !std.unicode.utf8ValidateSlice(plug)) return error.InvalidArgument;
            for (plug[sep + 1 ..]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '/')) return error.InvalidArgument;
        }
        try t.reserve();
        const owned = try t.own(u8, plug);
        t.touch(id);
        t.release(u8, n.a11y_embed);
        n.a11y_embed = owned;
        t.win.dirty.semantics = true;
    }

    /// Binds the node to an action (D34), or with 0 unbinds it: activating
    /// it invokes the action with `target` (`Window.actions`).
    pub fn setAction(t: *Txn, id: NodeId, action: u64, target: f64) Error!void {
        const n = try t.live(id);
        if (!std.math.isFinite(target)) return error.InvalidArgument;
        try t.reserve();
        if (action != 0 and std.mem.indexOfScalar(NodeId, t.win.bound.items, id) == null) try t.win.bound.append(t.win.gpa, id);
        t.touch(id);
        n.action = action;
        n.action_target = target;
        t.win.dirty.semantics = true;
    }

    /// Names the key that does what activating the node does (D34), for
    /// its semantics; keysym 0 for none.
    pub fn setShortcut(t: *Txn, id: NodeId, shortcut: @import("accel.zig").Accel) Error!void {
        const n = try t.live(id);
        try t.reserve();
        t.touch(id);
        n.shortcut = shortcut;
        t.win.dirty.semantics = true;
    }

    /// Sets the node's tooltip text; empty removes it.
    pub fn setTooltip(t: *Txn, id: NodeId, text: []const u8) Error!void {
        const n = try t.live(id);
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidArgument;
        try t.reserve();
        const owned = try t.own(u8, text);
        t.touch(id);
        t.release(u8, n.tooltip);
        n.tooltip = owned;
        t.win.dirty.semantics = true;
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
        if (if (masked) std.mem.eql(u8, n.data.editor.secret, content) else d.content.eqlBytes(content)) return;
        try t.reserve();
        const shown = if (masked) try t.bullets(content) else content;
        const copy = try t.ownRope(shown);
        const hidden = if (masked) try t.ownSecret(content) else "";
        try t.frees.ensureUnusedCapacity(t.win.gpa, 4);
        t.putText(id, n, copy, hidden);
    }

    /// Replaces `start..end` (character boundaries) of a text or editor
    /// node's text with `insert`, as `setText` with the spliced text
    /// would, but checks only what changes and copies only the leaves of
    /// the text's rope it touches: an editor's keystroke in a long
    /// document costs the keystroke (D15). Not for masked editors.
    pub fn replaceText(t: *Txn, id: NodeId, from: u32, to: u32, insert: []const u8) Error!void {
        const n = try t.textNode(id);
        if (n.kind == .editor and n.data.editor.editor.masked) return error.InvalidArgument;
        const old = n.textData().content;
        const old_len = old.len();
        if (from > to or to > old_len or old_len - (to - from) + insert.len >= std.math.maxInt(u32)) return error.InvalidArgument;
        if (charBoundary(old, from) != from or charBoundary(old, to) != to or !std.unicode.utf8ValidateSlice(insert)) return error.InvalidArgument;
        if (from == to and insert.len == 0) return;
        try t.reserve();
        try t.allocs.ensureUnusedCapacity(t.win.gpa, 1);
        try t.frees.ensureUnusedCapacity(t.win.gpa, 4);
        const copy = try old.replace(t.win.gpa, from, to, insert);
        t.allocs.appendAssumeCapacity(.{ .rope = copy });
        t.putText(id, n, copy, "");
    }

    /// Replaces `start..end` of a text or editor node's text with
    /// `insert` for the application (siv_replace_text), at the cost of
    /// the edit (D15): styled ranges and paragraph styles move with the
    /// text as they do for a user's edit, and an editor's caret and anchor
    /// move with the text after the range, or to its start from inside
    /// it. Not for masked editors.
    pub fn spliceText(t: *Txn, id: NodeId, from: u32, to: u32, insert: []const u8) Error!void {
        const n = try t.textNode(id);
        if (n.kind == .editor and n.data.editor.editor.masked) return error.InvalidArgument;
        const a = t.win.scratch.allocator();
        const d = n.textData();
        const old = d.content;
        const old_spans = try a.dupe(node_mod.Span, d.spans);
        const old_paragraphs = try a.dupe(node_mod.ParagraphSpan, d.paragraphs);
        const sel: [2]u32 = if (n.kind == .editor) .{ n.data.editor.caret, n.data.editor.anchor } else .{ 0, 0 };
        // The old text stays alive until the transaction ends.
        try t.replaceText(id, from, to, insert);
        const len: u32 = @intCast(insert.len);
        const style = if (from < to) spans_mod.styleAt(old_spans, from) else spans_mod.inherited(old_spans, from);
        try t.setSpans(id, try spans_mod.replaced(a, old_spans, from, to, len, style));
        if (old_paragraphs.len != 0) {
            const paragraph_style = spans_mod.styleAt(old_paragraphs, spans_mod.paragraphAt(old, from).start);
            const moved = try spans_mod.replaced(a, old_paragraphs, from, to, len, paragraph_style);
            try t.setParagraphSpans(id, moved);
        }
        if (n.kind == .editor) {
            const e = &t.win.node(id).data.editor;
            const map = struct {
                fn f(o: u32, s0: u32, e0: u32, l: u32) u32 {
                    if (o >= e0) return o - (e0 - s0) + l;
                    return @min(o, s0);
                }
            }.f;
            e.caret = map(sel[0], from, to, len);
            e.anchor = map(sel[1], from, to, len);
            e.shown_caret = null;
        }
    }

    /// Gives a text node new text (owned, `hidden` the secret of a masked
    /// editor); its spans go with the old text. Room for four frees and a
    /// snapshot is reserved.
    fn putText(t: *Txn, id: NodeId, n: *Node, copy: Rope, hidden: []const u8) void {
        const d = n.textData();
        const masked = n.kind == .editor and n.data.editor.editor.masked;
        t.touch(id);
        t.releaseRope(d.content);
        d.content = copy;
        // New text: the old ranges mean nothing in it.
        t.release(node_mod.Span, d.spans);
        d.spans = &.{};
        t.release(node_mod.ParagraphSpan, d.paragraphs);
        d.paragraphs = &.{};
        if (n.kind == .editor) {
            const e = &n.data.editor;
            e.typing = null;
            if (masked) {
                t.releaseSecret(e.secret);
                e.secret = hidden;
            }
            e.caret = charBoundary(copy, e.caret);
            e.anchor = charBoundary(copy, e.anchor);
            e.shown_caret = null;
            e.revision +%= 1;
        }
        t.win.markShape(id);
        t.win.dirty.semantics = true;
    }

    /// Replaces the styled ranges of a text or editor node (D22). They
    /// must be sorted, disjoint, and at character boundaries; empty and
    /// default ones are dropped and equal neighbors merged. Masked editors
    /// take none.
    pub fn setSpans(t: *Txn, id: NodeId, list: []const node_mod.Span) Error!void {
        const n = try t.textNode(id);
        const d = n.textData();
        if (n.kind == .editor and n.data.editor.editor.masked and list.len != 0) return error.InvalidArgument;
        if (!spans_mod.valid(d.content, list)) return error.InvalidArgument;
        for (list) |sp| if (sp.style.size) |sz| if (!(sz > 0) or !finite(sz)) return error.InvalidArgument;
        var norm: std.ArrayList(node_mod.Span) = .empty;
        try norm.appendSlice(t.win.scratch.allocator(), list);
        spans_mod.normalize(&norm);
        if (spansEql(d.spans, norm.items)) return;
        try t.reserve();
        const copy = try t.own(node_mod.Span, norm.items);
        t.touch(id);
        t.release(node_mod.Span, d.spans);
        d.spans = copy;
        t.win.markShape(id);
        t.win.dirty.semantics = true;
    }

    /// Replaces the paragraph styles of a text or editor node (D13). Like
    /// spans they must be sorted, disjoint, and at character boundaries;
    /// each paragraph takes the style at its first byte, so they are kept
    /// as whole paragraphs.
    pub fn setParagraphSpans(t: *Txn, id: NodeId, list: []const node_mod.ParagraphSpan) Error!void {
        const n = try t.textNode(id);
        const d = n.textData();
        if (!spans_mod.valid(d.content, list)) return error.InvalidArgument;
        for (list) |sp| try checkParagraph(sp.style);
        const norm = try spans_mod.snapped(t.win.scratch.allocator(), d.content, list);
        if (paragraphsEql(d.paragraphs, norm)) return;
        try t.reserve();
        const copy = try t.own(node_mod.ParagraphSpan, norm);
        t.touch(id);
        t.release(node_mod.ParagraphSpan, d.paragraphs);
        d.paragraphs = copy;
        t.win.markShape(id);
        t.win.dirty.semantics = true;
    }

    /// Sets the style an editor's typed text takes until the caret moves.
    pub fn setTypingStyle(t: *Txn, id: NodeId, style: ?node_mod.SpanStyle) Error!void {
        const n = try t.data(id, .editor);
        const e = &n.data.editor;
        if (std.meta.eql(e.typing, style)) return;
        try t.reserve();
        t.touch(id);
        e.typing = style;
    }

    /// Masking moves the text into locked memory (and unmasking back) and
    /// counts as a text change.
    pub fn setEditor(t: *Txn, id: NodeId, e: node_mod.Editor) Error!void {
        const n = try t.data(id, .editor);
        const ed = &n.data.editor;
        if (std.meta.eql(ed.editor, e)) return;
        try t.reserve();
        if (ed.editor.masked != e.masked) {
            const plain = if (ed.editor.masked) ed.secret else try ed.text.content.toOwned(t.win.scratch.allocator());
            const shown = try t.ownRope(if (e.masked) try t.bullets(plain) else plain);
            const hidden = if (e.masked) try t.ownSecret(plain) else "";
            try t.frees.ensureUnusedCapacity(t.win.gpa, 4);
            t.touch(id);
            t.releaseRope(ed.text.content);
            t.releaseSecret(ed.secret);
            ed.text.content = shown;
            ed.secret = hidden;
            if (e.masked) {
                t.release(node_mod.Span, ed.text.spans);
                ed.text.spans = &.{};
                t.release(node_mod.ParagraphSpan, ed.text.paragraphs);
                ed.text.paragraphs = &.{};
                ed.typing = null;
            }
            ed.caret = @intCast(shown.len());
            ed.anchor = ed.caret;
            ed.shown_caret = null;
            ed.revision +%= 1;
            t.win.markShape(id);
            t.win.dirty.semantics = true;
        } else t.touch(id);
        const ime_changed = ed.editor.no_input_method != e.no_input_method;
        ed.editor = e;
        t.win.markLayout(id);
        if (ime_changed and t.win.input.focus == id) @import("ime.zig").optionsChanged(t.win);
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

    /// Turns spell checking of an editor on or off (D37), in a language
    /// (a BCP 47 tag; empty for the text's, else the window's).
    pub fn setSpellCheck(t: *Txn, id: NodeId, enabled: bool, language: []const u8) Error!void {
        const n = try t.data(id, .editor);
        const e = &n.data.editor;
        const lang = try t.win.fonts.intern(language);
        if (e.spell == enabled and e.spell_language == lang) return;
        try t.reserve();
        t.touch(id);
        e.spell = enabled;
        e.spell_language = lang;
        t.win.spell_scan = true;
        t.win.markPaint(id);
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
        if (e.caret != c or e.anchor != a) {
            e.typing = null;
            e.shown_caret = null;
        }
        e.caret = c;
        e.anchor = a;
        e.affinity = affinity;
        // Its scroll container shows the caret (D15); pointer presses
        // take this back, being where they point already.
        t.win.reveal = id;
        t.win.markPaint(id);
        t.win.dirty.semantics = true;
    }

    /// Draws an editor's caret at `offset` (moved back to a character
    /// boundary and clamped to the text) instead of at the selection's
    /// caret, until the selection or the text next changes; null draws
    /// it at the selection's caret again. The selection is unchanged.
    pub fn showCaretAt(t: *Txn, id: NodeId, offset: ?u32) Error!void {
        const n = try t.data(id, .editor);
        const e = &n.data.editor;
        if (e.editor.masked and offset != null) return error.InvalidArgument;
        const at = if (offset) |o| charBoundary(e.text.content, o) else null;
        if (std.meta.eql(e.shown_caret, at)) return;
        try t.reserve();
        t.touch(id);
        e.shown_caret = at;
        t.win.markPaint(id);
    }

    /// Text style, alignment, wrapping, and paragraph defaults. Color and
    /// alignment only repaint; wrapping and paragraph defaults relayout;
    /// anything else reshapes.
    pub fn setTextProps(t: *Txn, id: NodeId, props: node_mod.Text) Error!void {
        const n = try t.textNode(id);
        if (!(props.style.size > 0) or !finite(props.style.size)) return error.InvalidArgument;
        try checkParagraph(.{ .indent = .{ .start = props.paragraph.indent_start, .end = props.paragraph.indent_end, .first_line = props.paragraph.first_line_indent }, .spacing = .{ .line_spacing = props.paragraph.line_spacing, .line_height = props.paragraph.line_height }, .gaps = .{ .before = props.paragraph.space_before, .after = props.paragraph.space_after }, .tab_width = props.paragraph.tab_width });
        var prev: f32 = -std.math.inf(f32);
        for (props.tab_stops) |stop| {
            if (!finite(stop.position) or stop.position <= prev) return error.InvalidArgument;
            prev = stop.position;
        }
        try t.reserve();
        const fonts = t.win.fonts;
        const family = try fonts.intern(props.style.family);
        const language = try fonts.intern(props.style.language);
        const d = n.textData();
        const old = d.*;
        const stops_changed = !std.meta.eql(old.props.tab_stops.len, props.tab_stops.len) or for (old.props.tab_stops, props.tab_stops) |a, b| {
            if (!std.meta.eql(a, b)) break true;
        } else false;
        const stops = if (stops_changed) try t.own(node_mod.TabStop, props.tab_stops) else old.props.tab_stops;
        t.touch(id);
        if (stops_changed) t.release(node_mod.TabStop, old.props.tab_stops);
        d.props = props;
        d.props.tab_stops = stops;
        d.props.style.family = fonts.name(family);
        d.props.style.language = fonts.name(language);
        d.family = family;
        d.language = language;
        const os = old.props.style;
        const ns = props.style;
        if (old.family != family or old.language != language or os.size != ns.size or os.weight != ns.weight or os.weight_value != ns.weight_value or os.slant != ns.slant or os.width != ns.width or os.size_role != ns.size_role or old.props.direction != props.direction) {
            t.win.markShape(id);
        } else if (old.props.wrap != props.wrap or old.props.break_words != props.break_words or stops_changed or
            !std.meta.eql(old.props.paragraph, props.paragraph) or old.props.hyphenate != props.hyphenate or
            old.props.optimal != props.optimal or (old.props.alignment == .justify) != (props.alignment == .justify) or
            old.props.max_lines != props.max_lines or old.props.ellipsize != props.ellipsize)
        {
            // The layout cache keys on the width only: shape again.
            t.win.markShape(id);
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
        if (!finite(s.min_zoom) or !finite(s.max_zoom) or !finite(s.zoom) or !(s.min_zoom > 0) or s.max_zoom < s.min_zoom) return error.InvalidArgument;
        try t.reserve();
        t.touch(id);
        const old = n.data.scroll;
        n.data.scroll = s;
        n.data.scroll.zoom = std.math.clamp(s.zoom, s.min_zoom, s.max_zoom);
        if (old.axis != s.axis) t.win.markLayout(id);
        // The zoom range is a layer property; a new zoom goes out with them.
        if (old.min_zoom != s.min_zoom or old.max_zoom != s.max_zoom or old.zoom != n.data.scroll.zoom) t.win.dirty.props = true;
        if (!old.offset.eql(s.offset)) {
            t.win.state(id).scroll_pending = true;
            t.win.app_scrolled = true;
            t.win.dirty.props = true;
        }
    }

    /// The node takes a reference to `view.image` and copies `view.icon`;
    /// the caller keeps its own.
    pub fn setImage(t: *Txn, id: NodeId, view: node_mod.ImageView) Error!void {
        const n = try t.data(id, .image);
        if (!(view.icon_size >= 0) or !finite(view.icon_size)) return error.InvalidArgument;
        if (view.icon.len > 4096 or !std.unicode.utf8ValidateSlice(view.icon)) return error.InvalidArgument;
        try t.reserve();
        try t.allocs.ensureUnusedCapacity(t.win.gpa, 1);
        try t.frees.ensureUnusedCapacity(t.win.gpa, 2);
        const old = n.data.image;
        const icon = if (std.mem.eql(u8, old.icon, view.icon)) old.icon else try t.own(u8, view.icon);
        t.touch(id);
        // The new reference is dropped if the transaction aborts, the old
        // one once it commits.
        if (view.image) |img| t.allocs.appendAssumeCapacity(.{ .image = img.retain() });
        if (old.image) |img| t.frees.appendAssumeCapacity(.{ .image = img });
        if (icon.ptr != old.icon.ptr) t.release(u8, old.icon);
        n.data.image = view;
        n.data.image.icon = icon;
        const os: [2]f32 = old.intrinsic() orelse .{ 0, 0 };
        const ns: [2]f32 = view.intrinsic() orelse .{ 0, 0 };
        if (os[0] != ns[0] or os[1] != ns[1] or old.fit != view.fit) t.win.markLayout(id);
        t.win.markPaint(id);
        if (view.image != old.image) t.win.animateImage(id);
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
fn charBoundary(s: Rope, offset: u32) u32 {
    var rd = s.reader();
    return @intCast(rd.charStart(offset));
}

/// What a masked editor shows for each code point.
pub const bullet = "\u{2022}";

pub fn isLayerRoot(v: node_mod.Visual) bool {
    return v.opacity < 1 or !v.transform.eql(.identity) or v.layer or v.animation.property != .none or v.window_blur or v.motion.needsLayer();
}

fn spansEql(a: []const node_mod.Span, b: []const node_mod.Span) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.start != y.start or x.end != y.end or !x.style.eql(y.style)) return false;
    return true;
}

fn paragraphsEql(a: []const node_mod.ParagraphSpan, b: []const node_mod.ParagraphSpan) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.start != y.start or x.end != y.end or !x.style.eql(y.style)) return false;
    return true;
}

/// Finite lengths, non-negative where negative means nothing (all but the
/// first-line indent), and a positive line spacing.
fn checkParagraph(p: node_mod.ParagraphPatch) Error!void {
    if (p.indent) |i| if (!finite(i.start) or !finite(i.end) or !finite(i.first_line) or i.start < 0 or i.end < 0) return error.InvalidArgument;
    if (p.spacing) |s| if (!(s.line_spacing > 0) or !finite(s.line_spacing) or !(s.line_height >= 0) or !finite(s.line_height)) return error.InvalidArgument;
    if (p.gaps) |g| if (!(g.before >= 0) or !(g.after >= 0) or !finite(g.before) or !finite(g.after)) return error.InvalidArgument;
    if (p.tab_width) |w| if (!(w >= 0) or !finite(w)) return error.InvalidArgument;
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
