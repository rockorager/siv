//! The semantics tree (D18): what assistive technology sees. Every node has
//! a role; nodes with role `none`, and `generic` nodes that are neither
//! labelled nor focusable, are left out and their children promoted. The
//! tree is rebuilt after frames that changed structure, layout, semantics,
//! text, or focus, and tests query it. The AT-SPI bridge will read it.

const std = @import("std");
const text = @import("text");
const raster = @import("raster");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");

const NodeId = node_mod.NodeId;
const Role = node_mod.Role;
const Rect = raster.Rect;

pub const none: u32 = std.math.maxInt(u32);

pub const Node = struct {
    node: NodeId,
    /// One of a canvas's own objects (`Canvas.semantics`), 1-based in
    /// the order it listed them; 0 for the node itself.
    virtual: u32 = 0,
    role: Role,
    /// Index of the parent in `Tree.nodes`, or `none` for the window.
    parent: u32,
    /// Nodes are in tree order; this one's descendants follow it up to
    /// (not including) `end`.
    end: u32,
    name_start: u32,
    name_len: u32,
    description: []const u8,
    /// Window coordinates.
    bounds: Rect,
    focusable: bool,
    focused: bool,
    disabled: bool,
    checked: node_mod.Toggle,
    pressed: node_mod.Toggle,
    selected: node_mod.Toggle,
    expanded: node_mod.Toggle,
    value: ?node_mod.Range,
    /// The value as text (`Semantics.value_text`).
    value_label: []const u8 = "",
    live: node_mod.Live,
    /// Has an activate handler or an action (D34): AT can invoke it.
    actionable: bool,
    /// The key that does the same (D34); keysym 0 for none.
    shortcut: @import("accel.zig").Accel = .{},
    /// An editor's text, caret, and selection anchor (byte offsets).
    value_text: text.Rope = .{},
    caret: ?u32 = null,
    anchor: ?u32 = null,
    /// A password field: its value is never exposed.
    masked: bool = false,
    /// Heading level, or a tree item's depth (1 is the top); 0 for none.
    level: u8 = 0,
    /// Input stays inside it while it is shown (dialogs).
    modal: bool = false,
    /// An empty editor's placeholder text.
    placeholder: []const u8 = "",
    /// Position in a set and its size, and a table row's index, 1-based;
    /// 0 for none.
    position: u32 = 0,
    set_size: u32 = 0,
    row: u32 = 0,
    /// A column header's sort order.
    sort: node_mod.Sort = .none,
    column: u32 = 0,
    /// The current item of its set (aria-current).
    current: node_mod.Current = .none,
    /// Another process's object shown as the last child (D18):
    /// "BUS_NAME:/object/path", or empty.
    embed: []const u8 = "",
};

/// What a canvas lists of its content (`Canvas.semantics`): objects in
/// tree order, each with its parent's index in `nodes` (or `none` for
/// the canvas) and the end of its descendants, bounds in the canvas's
/// coordinates. Names may be allocated with `arena`, which lives until
/// the next rebuild.
pub const Virtual = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    nodes: std.ArrayList(VirtualNode) = .empty,
};

pub const VirtualNode = struct {
    role: Role,
    name: []const u8 = "",
    parent: u32 = none,
    end: u32 = 0,
    bounds: Rect = .empty,
    level: u8 = 0,
    position: u32 = 0,
    set_size: u32 = 0,
};

pub const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    names: std.ArrayList(u8) = .empty,
    /// Canvases' names (`Virtual.arena`).
    arena: ?std.heap.ArenaAllocator = null,
    /// Counts rebuilds: an unchanged count means an unchanged tree.
    generation: u64 = 0,

    pub fn deinit(t: *Tree, gpa: std.mem.Allocator) void {
        if (t.arena) |*a| a.deinit();
        t.nodes.deinit(gpa);
        t.names.deinit(gpa);
    }

    pub fn name(t: *const Tree, n: Node) []const u8 {
        return t.names.items[n.name_start..][0..n.name_len];
    }

    /// The first node in tree order with this role and accessible name.
    pub fn find(t: *const Tree, role: Role, accessible_name: []const u8) ?*const Node {
        for (t.nodes.items) |*n| if (n.role == role and std.mem.eql(u8, t.name(n.*), accessible_name)) return n;
        return null;
    }

    pub fn focused(t: *const Tree) ?*const Node {
        for (t.nodes.items) |*n| if (n.focused) return n;
        return null;
    }

    /// Indices of a node's children (`none` for the top level).
    pub fn children(t: *const Tree, parent: u32) ChildIterator {
        const start: u32 = if (parent == none) 0 else parent + 1;
        const end: u32 = if (parent == none) @intCast(t.nodes.items.len) else t.nodes.items[parent].end;
        return .{ .tree = t, .i = start, .end = end };
    }

    pub const ChildIterator = struct {
        tree: *const Tree,
        i: u32,
        end: u32,

        pub fn next(it: *ChildIterator) ?u32 {
            if (it.i >= it.end) return null;
            const r = it.i;
            it.i = it.tree.nodes.items[r].end;
            return r;
        }
    };

    pub fn rebuild(t: *Tree, win: *Window) Window.Error!void {
        t.nodes.clearRetainingCapacity();
        t.names.clearRetainingCapacity();
        if (t.arena) |*a| _ = a.reset(.retain_capacity);
        t.generation += 1;
        try t.visit(win, .root, none);
    }

    fn visit(t: *Tree, win: *Window, id: NodeId, parent: u32) Window.Error!void {
        const n = win.node(id);
        const sem = n.semantics;
        const role = n.role();
        const included = switch (role) {
            .none => false,
            .generic => sem.label.len != 0 or sem.focusable,
            else => true,
        };
        var me = parent;
        if (included) {
            me = @intCast(t.nodes.items.len);
            const start: u32 = @intCast(t.names.items.len);
            if (sem.label.len != 0) {
                try t.names.appendSlice(win.gpa, sem.label);
            } else if (n.kind == .text) {
                // An editor's text is its value, not its name.
                const c = n.data.text.content;
                try c.appendTo(win.gpa, &t.names, 0, c.len());
            } else if (namedFromContent(role)) {
                try t.contentText(win, id, start);
            }
            const editor = n.kind == .editor and !n.data.editor.editor.masked;
            // A tooltip describes the node, unless it only repeats the
            // name (an icon-only button's label).
            const own_name = t.names.items[start..];
            const description = if (sem.description.len != 0 or std.mem.eql(u8, n.tooltip, own_name)) sem.description else n.tooltip;
            try t.nodes.append(win.gpa, .{
                .node = id,
                .role = role,
                .parent = parent,
                .end = 0,
                .name_start = start,
                .name_len = @intCast(t.names.items.len - start),
                .description = description,
                .bounds = win.windowRect(id),
                .focusable = n.canFocus(),
                .focused = win.input.focus == id,
                .disabled = sem.disabled,
                .checked = sem.checked,
                .pressed = sem.pressed,
                .selected = sem.selected,
                .expanded = sem.expanded,
                .value = sem.value,
                .value_label = sem.value_text,
                .live = sem.live,
                .actionable = (n.handler(.activate) != null or n.action != 0) and !sem.disabled,
                .shortcut = if (n.shortcut.keysym != 0) n.shortcut else if (n.action != 0) win.actions.shortcut(win.actions.ctx, n.action, n.action_target) else .{},
                // A masked editor exposes neither its text nor, through
                // caret offsets, its length.
                .value_text = if (editor) n.data.editor.text.content else .{},
                .caret = if (editor) n.data.editor.caret else null,
                .anchor = if (editor) n.data.editor.anchor else null,
                .masked = n.kind == .editor and n.data.editor.editor.masked,
                .level = sem.level,
                .modal = sem.modal,
                .position = sem.position,
                .set_size = sem.set_size,
                .row = sem.row,
                .sort = sem.sort,
                .embed = n.a11y_embed,
                .column = sem.column,
                .current = sem.current,
                .placeholder = if (n.kind == .editor) n.data.editor.placeholder else "",
            });
        }
        var it = win.shown(id);
        while (it.next()) |c| try t.visit(win, c, me);
        if (n.kind == .canvas) if (n.data.canvas.semantics) |f| try t.virtualChildren(win, id, f, me);
        if (included) t.nodes.items[me].end = @intCast(t.nodes.items.len);
    }

    fn virtualChildren(t: *Tree, win: *Window, id: NodeId, f: anytype, parent: u32) Window.Error!void {
        if (t.arena == null) t.arena = .init(win.gpa);
        var v: Virtual = .{ .gpa = win.gpa, .arena = t.arena.?.allocator() };
        defer v.nodes.deinit(win.gpa);
        try f(win.node(id).data.canvas.user, win, id, &v);
        const base: u32 = @intCast(t.nodes.items.len);
        const origin = win.windowRect(id);
        try t.nodes.ensureUnusedCapacity(win.gpa, v.nodes.items.len);
        for (v.nodes.items, 0..) |vn, i| {
            const start: u32 = @intCast(t.names.items.len);
            try t.names.appendSlice(win.gpa, vn.name);
            t.nodes.appendAssumeCapacity(.{
                .node = id,
                .virtual = @intCast(i + 1),
                .role = vn.role,
                .parent = if (vn.parent == none) parent else base + vn.parent,
                .end = base + @max(vn.end, @as(u32, @intCast(i + 1))),
                .name_start = start,
                .name_len = @intCast(vn.name.len),
                .description = "",
                .bounds = .{ .x0 = vn.bounds.x0 + origin.x0, .y0 = vn.bounds.y0 + origin.y0, .x1 = vn.bounds.x1 + origin.x0, .y1 = vn.bounds.y1 + origin.y0 },
                .focusable = false,
                .focused = false,
                .disabled = false,
                .checked = .unset,
                .pressed = .unset,
                .selected = .unset,
                .expanded = .unset,
                .value = null,
                .live = .off,
                .actionable = false,
                .level = vn.level,
                .position = vn.position,
                .set_size = vn.set_size,
            });
        }
    }

    /// Descendant text, space-separated: the name of a button or link.
    fn contentText(t: *Tree, win: *Window, id: NodeId, name_start: usize) Window.Error!void {
        var it = win.shown(id);
        while (it.next()) |c| {
            const n = win.node(c);
            if (n.role() == .none) continue;
            if (n.semantics.label.len != 0) {
                if (t.names.items.len > name_start) try t.names.append(win.gpa, ' ');
                try t.names.appendSlice(win.gpa, n.semantics.label);
            } else if (n.kind == .text) {
                const s = n.data.text.content;
                if (s.len() == 0) continue;
                if (t.names.items.len > name_start) try t.names.append(win.gpa, ' ');
                try s.appendTo(win.gpa, &t.names, 0, s.len());
            } else try t.contentText(win, c, name_start);
        }
    }
};

fn namedFromContent(role: Role) bool {
    return switch (role) {
        .button, .toggle_button, .link, .checkbox, .radio, .@"switch", .menu_item, .tab, .list_item, .tree_item, .row, .cell, .column_header, .heading, .tooltip, .label, .paragraph, .status, .alert => true,
        else => false,
    };
}
