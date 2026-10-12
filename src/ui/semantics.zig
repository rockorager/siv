//! The semantics tree (D18): what assistive technology sees. Every node has
//! a role; nodes with role `none`, and `generic` nodes that are neither
//! labelled nor focusable, are left out and their children promoted. The
//! tree is rebuilt after frames that changed structure, layout, semantics,
//! text, or focus, and tests query it. The AT-SPI bridge will read it.

const std = @import("std");
const raster = @import("raster");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");

const NodeId = node_mod.NodeId;
const Role = node_mod.Role;
const Rect = raster.Rect;

pub const none: u32 = std.math.maxInt(u32);

pub const Node = struct {
    node: NodeId,
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
    live: node_mod.Live,
    /// Has an activate handler: AT can invoke its action.
    actionable: bool,
    /// An editor's text, caret, and selection anchor (byte offsets).
    value_text: []const u8 = "",
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
};

pub const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    names: std.ArrayList(u8) = .empty,
    /// Counts rebuilds: an unchanged count means an unchanged tree.
    generation: u64 = 0,

    pub fn deinit(t: *Tree, gpa: std.mem.Allocator) void {
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
        t.generation += 1;
        win.modal = .none;
        try t.visit(win, .root, none);
    }

    fn visit(t: *Tree, win: *Window, id: NodeId, parent: u32) Window.Error!void {
        const n = win.node(id);
        const sem = n.semantics;
        const role = n.role();
        if (sem.modal) win.modal = id;
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
                try t.names.appendSlice(win.gpa, n.data.text.content);
            } else if (namedFromContent(role)) {
                try t.contentText(win, id, start);
            }
            const editor = n.kind == .editor and !n.data.editor.editor.masked;
            try t.nodes.append(win.gpa, .{
                .node = id,
                .role = role,
                .parent = parent,
                .end = 0,
                .name_start = start,
                .name_len = @intCast(t.names.items.len - start),
                .description = sem.description,
                .bounds = win.windowRect(id),
                .focusable = n.canFocus(),
                .focused = win.input.focus == id,
                .disabled = sem.disabled,
                .checked = sem.checked,
                .pressed = sem.pressed,
                .selected = sem.selected,
                .expanded = sem.expanded,
                .value = sem.value,
                .live = sem.live,
                .actionable = n.handler(.activate) != null and !sem.disabled,
                // A masked editor exposes neither its text nor, through
                // caret offsets, its length.
                .value_text = if (editor) n.data.editor.text.content else "",
                .caret = if (editor) n.data.editor.caret else null,
                .anchor = if (editor) n.data.editor.anchor else null,
                .masked = n.kind == .editor and n.data.editor.editor.masked,
                .level = sem.level,
                .modal = sem.modal,
                .position = sem.position,
                .set_size = sem.set_size,
                .row = sem.row,
                .placeholder = if (n.kind == .editor) n.data.editor.placeholder else "",
            });
        }
        var it = win.shown(id);
        while (it.next()) |c| try t.visit(win, c, me);
        if (included) t.nodes.items[me].end = @intCast(t.nodes.items.len);
    }

    /// Descendant text, space-separated: the name of a button or link.
    fn contentText(t: *Tree, win: *Window, id: NodeId, name_start: usize) Window.Error!void {
        var it = win.shown(id);
        while (it.next()) |c| {
            const n = win.node(c);
            if (n.role() == .none) continue;
            if (n.semantics.label.len != 0 or n.kind == .text) {
                const s = if (n.semantics.label.len != 0) n.semantics.label else n.data.text.content;
                if (s.len == 0) continue;
                if (t.names.items.len > name_start) try t.names.append(win.gpa, ' ');
                try t.names.appendSlice(win.gpa, s);
            } else try t.contentText(win, c, name_start);
        }
    }
};

fn namedFromContent(role: Role) bool {
    return switch (role) {
        .button, .toggle_button, .link, .checkbox, .radio, .@"switch", .menu_item, .tab, .list_item, .tree_item, .cell, .column_header, .heading, .tooltip, .label, .paragraph, .status, .alert => true,
        else => false,
    };
}
