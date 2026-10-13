//! Hit testing, pointer and keyboard routing, and focus.
//!
//! Pointer events go to the topmost hit-testable node under the pointer
//! (or the node that captured the pointer with a button press) and bubble
//! to its ancestors until a handler returns true. Keyboard events go to the
//! focused node and bubble the same way. Default actions run for events
//! nobody handled: a primary press focuses the nearest focusable ancestor,
//! a release over the pressed node activates it, Tab and Shift+Tab move
//! focus in tree order, Enter and Space activate the focused node, and
//! scroll input scrolls the nearest scroll node the compositor left to the
//! UI (D8).

const std = @import("std");
const raster = @import("raster");
const platform = @import("platform");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const paint = @import("paint.zig");
const editor = @import("editor.zig");
const ime = @import("ime.zig");

const NodeId = node_mod.NodeId;
const Event = node_mod.Event;
const Result = node_mod.Result;
const Point = raster.Point;

/// XKB keysyms the defaults use.
pub const keysym = struct {
    pub const tab: u32 = 0xff09;
    pub const iso_left_tab: u32 = 0xfe20;
    pub const @"return": u32 = 0xff0d;
    pub const kp_enter: u32 = 0xff8d;
    pub const space: u32 = 0x0020;
    pub const home: u32 = 0xff50;
    pub const left: u32 = 0xff51;
    pub const up: u32 = 0xff52;
    pub const right: u32 = 0xff53;
    pub const down: u32 = 0xff54;
    pub const page_up: u32 = 0xff55;
    pub const page_down: u32 = 0xff56;
    pub const end: u32 = 0xff57;
};

const btn_left = 0x110;
const btn_right = 0x111;
const btn_middle = 0x112;

/// Pixels per arrow key when the UI scrolls.
pub const line_step: f32 = 40;

/// Presses this close in time and space count as one multi-click. Fixed
/// until the desktop settings portal supplies them (D19).
/// How far the pointer may travel between the presses of a multi-click.
/// No desktop exposes this through the portal, so it is a toolkit
/// default; the time comes from `Window.desktop`.
pub const multi_click_px: f32 = 4;

pub const State = struct {
    focus: NodeId = .none,
    /// Focus came from the keyboard, so it shows a ring.
    focus_visible: bool = false,
    /// The window has keyboard focus.
    keyboard: bool = false,
    /// Nodes under the pointer, root first.
    hover: std.ArrayList(NodeId) = .empty,
    pointer: ?Point = null,
    /// Content moved under the pointer since the hover was last found.
    hover_stale: bool = false,
    /// The node a press went to; it receives the pointer until release.
    capture: NodeId = .none,
    /// The activatable node a primary press went to.
    pressed: NodeId = .none,
    /// An editor whose selection follows the pointer while the primary
    /// button is held.
    selecting: NodeId = .none,
    /// Multi-click detection: the last primary press and the count so far.
    last_press_ms: u32 = 0,
    last_press_at: Point = .zero,
    clicks: u8 = 0,
    /// Timestamp of the latest button or key input.
    time: u32 = 0,
    /// The editor selection gesture of the current press.
    gesture: editor.Gesture = .{},
    /// Seat and serial of the last key or button press, for requests the
    /// compositor ties to user input (selections).
    seat: platform.SeatId = 0,
    serial: u32 = 0,
    /// Serial of the last button or touch press, which starts drags.
    press_serial: u32 = 0,
    mods: platform.Mods = .{},
    /// Modal nodes focus entered, innermost last, each with the node that
    /// had focus before it, which gets it back when the modal goes.
    modals: std.ArrayList(ModalEntry) = .empty,
    /// The node a touchpad gesture began on, which gets its later events,
    /// per gesture kind; and the pinch scale last passed on as a zoom.
    gesture_target: [3]NodeId = @splat(.none),
    pinch_scale: f32 = 1,
    /// Tablet tool motion not delivered yet: it goes out once per frame
    /// (`flushTablet`), as one move event per tool carrying every sample.
    tablet_pending: std.ArrayList(platform.TabletTool) = .empty,
    /// Scratch for samples in a node's coordinates.
    tablet_samples: std.ArrayList(node_mod.TabletSample) = .empty,
    /// The node each tool's tip is pressed on, which gets its events
    /// until the tip lifts.
    tools: [max_tools]ToolState = @splat(.{}),

    pub const ModalEntry = struct { modal: NodeId, opener: NodeId, visible: bool };

    pub const max_tools = 8;
    pub const ToolState = struct { active: bool = false, seat: platform.SeatId = 0, tool: u32 = 0, capture: NodeId = .none };

    pub fn deinit(st: *State, gpa: std.mem.Allocator) void {
        st.hover.deinit(gpa);
        st.modals.deinit(gpa);
        st.tablet_pending.deinit(gpa);
        st.tablet_samples.deinit(gpa);
    }

    /// A node was removed.
    pub fn forget(st: *State, win: *Window, id: NodeId) void {
        if (st.focus == id) {
            st.focus = .none;
            win.dirty.semantics = true;
        }
        if (st.capture == id) st.capture = .none;
        if (st.pressed == id) st.pressed = .none;
        if (st.selecting == id) st.selecting = .none;
        for (&st.gesture_target) |*g| if (g.* == id) {
            g.* = .none;
        };
        for (&st.tools) |*t| if (t.capture == id) {
            t.capture = .none;
        };
        for (st.hover.items, 0..) |h, i| if (h == id) {
            st.hover.shrinkRetainingCapacity(i);
            break;
        };
    }

    /// After a commit: focus returns from modal nodes that went away to
    /// where it was before them, moves into a modal node that appeared,
    /// and leaves nodes that can no longer take it.
    pub fn afterCommit(st: *State, win: *Window) void {
        var k: usize = 0;
        while (k < win.modals.items.len) {
            if (win.isLive(win.modals.items[k])) k += 1 else _ = win.modals.orderedRemove(k);
        }
        var back: ?ModalEntry = null;
        while (st.modals.items.len != 0) {
            const top = st.modals.items[st.modals.items.len - 1];
            if (modalActive(win, top.modal)) break;
            back = st.modals.pop();
        }
        if (back) |b| {
            const lost = st.focus == .none or !canFocus(win, st.focus);
            if (lost) setFocus(win, if (canFocus(win, b.opener)) b.opener else .none, b.visible);
        }
        const m = modalRoot(win);
        if (m != .root and (st.focus == .none or !win.isAncestor(m, st.focus))) {
            // A modal node appeared without focus inside it: it takes focus,
            // and gives it back when it goes.
            setFocus(win, firstFocusable(win, m), st.focus_visible);
        }
        if (st.focus != .none and !canFocus(win, st.focus)) setFocus(win, .none, false);
        // Cursors change without a frame; layout changes update it after
        // the next one.
        updateCursor(win);
    }
};

/// Whether a node takes focus: focusable, enabled, shown, and inside the
/// active modal node, if there is one.
pub fn canFocus(win: *const Window, id: NodeId) bool {
    if (!(win.isLive(id) and win.node(id).canFocus() and win.isShown(id))) return false;
    const m = modalRoot(win);
    return m == .root or win.isAncestor(m, id);
}

fn modalActive(win: *const Window, id: NodeId) bool {
    return win.isLive(id) and win.node(id).semantics.modal and win.isShown(id);
}

/// The active modal node input stays inside, or the root: the shown modal
/// node made modal last.
pub fn modalRoot(win: *const Window) NodeId {
    var i = win.modals.items.len;
    while (i > 0) {
        i -= 1;
        const m = win.modals.items[i];
        if (modalActive(win, m)) return m;
    }
    return .root;
}

/// The first node in tree order under `id` (itself included) that takes
/// focus, or none.
pub fn firstFocusable(win: *const Window, id: NodeId) NodeId {
    if (canFocus(win, id)) return id;
    var it = win.shown(id);
    while (it.next()) |c| {
        const f = firstFocusable(win, c);
        if (f != .none) return f;
    }
    return .none;
}

fn activatable(win: *const Window, id: NodeId) bool {
    const n = win.node(id);
    return n.handler(.activate) != null and !n.semantics.disabled;
}

// Hit testing ----------------------------------------------------------------

/// The topmost hit-testable node at a window point, or none.
pub fn hitTest(win: *const Window, p: Point) NodeId {
    const h = hit(win, .root, p) orelse return .none;
    // Outside a modal node, the pointer reaches nothing.
    const m = modalRoot(win);
    if (m != .root and !win.isAncestor(m, h)) return .none;
    return h;
}

fn hit(win: *const Window, id: NodeId, parent_p: Point) ?NodeId {
    const n = win.node(id);
    if (n.visual.hidden) return null;
    const s = win.state(id);
    var p: Point = .{ .x = parent_p.x - s.pos.x, .y = parent_p.y - s.pos.y };
    if (!n.visual.transform.eql(.identity)) {
        const inv = n.visual.transform.affine().invert() orelse return null;
        p = inv.apply(p);
    }
    const inside = p.x >= 0 and p.y >= 0 and p.x < s.size.w and p.y < s.size.h;
    if ((n.visual.clip or n.kind == .scroll) and !inside) return null;
    var cp = p;
    if (n.kind == .scroll) {
        const pad = n.layout.padding;
        if (p.x < pad.left(s.rtl) or p.x >= s.size.w - (if (s.rtl) pad.start else pad.end) or p.y < pad.top or p.y >= s.size.h - pad.bottom) {
            return if (n.visual.hit_test) id else null;
        }
        cp = paint.toContent(win, id, p);
    }
    var c = n.last;
    while (c != .none) : (c = win.node(c).prev) {
        if (hit(win, c, cp)) |h| return h;
    }
    if (inside and n.visual.hit_test) return id;
    return null;
}

/// A window point in a node's coordinates (translations and transforms).
pub fn toLocal(win: *const Window, id: NodeId, p: Point) Point {
    const parent = win.node(id).parent;
    var q = if (parent == .none) p else blk: {
        var pp = toLocal(win, parent, p);
        const pn = win.node(parent);
        if (pn.kind == .scroll) pp = paint.toContent(win, parent, pp);
        break :blk pp;
    };
    const s = win.state(id);
    q = .{ .x = q.x - s.pos.x, .y = q.y - s.pos.y };
    const t = win.node(id).visual.transform;
    if (!t.eql(.identity)) if (t.affine().invert()) |inv| {
        q = inv.apply(q);
    };
    return q;
}

// Dispatch -------------------------------------------------------------------

/// Calls a node's handler for one kind, if it has one.
pub fn callHandler(win: *Window, id: NodeId, kind: node_mod.HandlerKind, event: *const Event) void {
    _ = call(win, id, kind, event);
}

fn call(win: *Window, id: NodeId, kind: node_mod.HandlerKind, event: *const Event) Result {
    const h = win.node(id).handler(kind) orelse return .pass;
    return h.func(h.user, win, id, event);
}

/// Bubbles a pointer event from `target`; coordinates are made local to
/// each node. Returns whether a handler stopped it and whether one
/// prevented the default action.
pub fn bubblePointer(win: *Window, target: NodeId, phase: node_mod.PointerPhase, button: node_mod.Button) Result {
    const p = win.input.pointer orelse return .pass;
    const clicks: u8 = if (button == .primary and (phase == .down or phase == .up)) @max(win.input.clicks, 1) else 1;
    var prevented = false;
    var cur = target;
    while (cur != .none and win.isLive(cur)) {
        const local = toLocal(win, cur, p);
        const ev: Event = .{ .pointer = .{ .phase = phase, .x = local.x, .y = local.y, .button = button, .mods = win.input.mods, .clicks = clicks, .time = win.input.time, .target = target, .prevented = prevented } };
        const r = call(win, cur, .pointer, &ev);
        prevented = prevented or r.prevents();
        if (r.stops() or !win.isLive(cur)) return .of(r.stops(), prevented);
        cur = win.node(cur).parent;
    }
    return .of(false, prevented);
}

/// Bubbles a key or scroll event from `target`. Once a handler prevents
/// the default action, the nodes above see the event marked prevented.
fn bubble(win: *Window, target: NodeId, kind: node_mod.HandlerKind, event: Event) Result {
    var ev = event;
    var prevented = false;
    var cur = target;
    while (cur != .none and win.isLive(cur)) {
        const r = call(win, cur, kind, &ev);
        if (r.prevents() and !prevented) {
            prevented = true;
            switch (ev) {
                .key => |*k| k.prevented = true,
                .scroll => |*s| s.prevented = true,
                else => {},
            }
        }
        if (r.stops() or !win.isLive(cur)) return .of(r.stops(), prevented);
        cur = win.node(cur).parent;
    }
    return .of(false, prevented);
}

/// Sends `activate` to a node.
pub fn activate(win: *Window, id: NodeId) void {
    if (!win.isLive(id) or !activatable(win, id)) return;
    _ = call(win, id, .activate, &.activate);
}

/// Asks a node with a range for a new value, as assistive technology
/// does (D18). Returns whether a handler took it.
pub fn setValue(win: *Window, id: NodeId, value: f64) bool {
    if (!win.isLive(id) or !std.math.isFinite(value)) return false;
    const n = win.node(id);
    if (n.semantics.value == null or n.semantics.disabled) return false;
    return call(win, id, .set_value, &.{ .set_value = value }) != .pass;
}

/// Moves keyboard focus (none clears it).
pub fn setFocus(win: *Window, id: NodeId, visible: bool) void {
    const st = &win.input;
    const old = st.focus;
    if (old == id and st.focus_visible == visible) return;
    // Focus entering a modal node from outside remembers where it was.
    const m = modalRoot(win);
    if (m != .root and id != .none and win.isAncestor(m, id) and (old == .none or !win.isLive(old) or !win.isAncestor(m, old))) {
        const known = st.modals.items.len != 0 and st.modals.items[st.modals.items.len - 1].modal == m;
        if (!known) st.modals.append(win.gpa, .{ .modal = m, .opener = old, .visible = st.focus_visible }) catch {};
    }
    st.focus = id;
    st.focus_visible = visible;
    win.dirty.semantics = true;
    // A focused editor's caret is a layer.
    if ((old != .none and win.isLive(old) and win.node(old).kind == .editor) or (id != .none and win.node(id).kind == .editor)) win.markLayers();
    if (old != .none and win.isLive(old)) {
        win.markPaint(old);
        if (old != id) _ = call(win, old, .focus, &.{ .focus = .{ .gained = false, .visible = visible } });
    }
    if (id != .none and win.isLive(id) and win.input.focus == id) {
        win.markPaint(id);
        if (old != id) _ = call(win, id, .focus, &.{ .focus = .{ .gained = true, .visible = visible } });
    }
    ime.focusChanged(win);
    win.requestFrame();
}

/// Moves focus to the next (or previous) focusable node in tree order,
/// wrapping around.
pub fn traverse(win: *Window, forward: bool) void {
    const a = win.scratch.allocator();
    defer _ = win.scratch.reset(.retain_capacity);
    var list: std.ArrayList(NodeId) = .empty;
    collectFocusable(win, modalRoot(win), a, &list) catch return;
    if (list.items.len == 0) return;
    const cur = std.mem.indexOfScalar(NodeId, list.items, win.input.focus);
    const next: usize = if (cur) |i|
        (if (forward) (i + 1) % list.items.len else (i + list.items.len - 1) % list.items.len)
    else if (forward) 0 else list.items.len - 1;
    setFocus(win, list.items[next], true);
}

fn collectFocusable(win: *const Window, id: NodeId, a: std.mem.Allocator, out: *std.ArrayList(NodeId)) !void {
    if (canFocus(win, id)) try out.append(a, id);
    var it = win.shown(id);
    while (it.next()) |c| try collectFocusable(win, c, a, out);
}

/// Content moved under a pointer that did not (the compositor scrolled
/// it, D8): the hover goes to what is under the pointer now, as if it had
/// moved. A captured pointer keeps its target.
pub fn refreshHover(win: *Window) void {
    const st = &win.input;
    st.hover_stale = false;
    const p = st.pointer orelse return;
    if (st.capture != .none) return;
    updateHover(win, hitTest(win, p));
    updateCursor(win);
}

fn updateHover(win: *Window, target: NodeId) void {
    const st = &win.input;
    const a = win.scratch.allocator();
    defer _ = win.scratch.reset(.retain_capacity);
    var path: std.ArrayList(NodeId) = .empty;
    var cur = target;
    while (cur != .none) : (cur = win.node(cur).parent) path.append(a, cur) catch return;
    std.mem.reverse(NodeId, path.items);
    var common: usize = 0;
    while (common < st.hover.items.len and common < path.items.len and st.hover.items[common] == path.items[common]) common += 1;
    // Leave the old path innermost first, then enter outermost first.
    var i = st.hover.items.len;
    while (i > common) {
        i -= 1;
        const id = st.hover.items[i];
        if (win.isLive(id)) callPointer(win, id, .leave);
    }
    st.hover.shrinkRetainingCapacity(common);
    for (path.items[common..]) |id| {
        st.hover.append(win.gpa, id) catch return;
        if (win.isLive(id)) callPointer(win, id, .enter);
    }
}

/// Sends the platform the cursor for the pointer's place: the window's
/// override, else that of the node the pointer is captured by or over,
/// or of its nearest ancestor that sets one. Enabled editors show the text
/// cursor by default.
pub fn updateCursor(win: *Window) void {
    const st = &win.input;
    const p = st.pointer orelse return;
    const shape = win.cursor_override orelse blk: {
        var cur = if (st.capture != .none and win.isLive(st.capture)) st.capture else hitTest(win, p);
        while (cur != .none) : (cur = win.node(cur).parent) {
            const n = win.node(cur);
            if (n.cursor) |c| break :blk c;
            if (n.kind == .editor and n.canFocus()) break :blk .text;
        }
        break :blk .default;
    };
    if (shape == win.cursor_shown) return;
    win.cursor_shown = shape;
    win.host.set_cursor(win.host.ctx, shape);
}

fn callPointer(win: *Window, id: NodeId, phase: node_mod.PointerPhase) void {
    const p = win.input.pointer orelse Point.zero;
    const local = toLocal(win, id, p);
    _ = call(win, id, .pointer, &.{ .pointer = .{ .phase = phase, .x = local.x, .y = local.y, .mods = win.input.mods } });
}

// Platform events ------------------------------------------------------------

pub fn handle(win: *Window, event: *const platform.Event) void {
    const st = &win.input;
    switch (event.*) {
        .pointer_enter, .pointer_motion => |m| {
            st.pointer = .{ .x = @floatCast(m.x), .y = @floatCast(m.y) };
            const target = if (st.capture != .none) st.capture else hitTest(win, st.pointer.?);
            updateHover(win, if (st.capture != .none) hitTest(win, st.pointer.?) else target);
            if (target != .none) _ = bubblePointer(win, target, .move, .primary);
            if (st.selecting != .none and win.isLive(st.selecting)) editor.pointerDrag(win, st.selecting, st.pointer.?);
            updateCursor(win);
        },
        .pointer_leave => {
            updateHover(win, .none);
            st.pointer = null;
        },
        .pointer_button => |b| {
            if (b.pressed) {
                st.seat = b.seat;
                st.serial = b.serial;
                st.press_serial = b.serial;
            }
            pointerButton(win, b.button, b.pressed, b.time);
            // A release ends the capture that chose the cursor.
            updateCursor(win);
        },
        .touch_down => |t| {
            st.seat = t.seat;
            st.press_serial = t.serial;
            st.pointer = .{ .x = @floatCast(t.x), .y = @floatCast(t.y) };
            pointerButton(win, btn_left, true, t.time);
        },
        .touch_motion => |t| {
            st.pointer = .{ .x = @floatCast(t.x), .y = @floatCast(t.y) };
            if (st.capture != .none) _ = bubblePointer(win, st.capture, .move, .primary);
        },
        .touch_up => |t| pointerButton(win, btn_left, false, t.time),
        .touch_cancel => {
            if (st.capture != .none) _ = bubblePointer(win, st.capture, .cancel, .primary);
            st.capture = .none;
            st.pressed = .none;
        },
        .scroll => |s| scroll(win, @floatCast(s.dx), @floatCast(s.dy), s.v120_x, s.v120_y),
        .gesture => |g| gesture(win, &g),
        .tablet_tool => |t| tabletTool(win, &t),
        .tablet_pad => |p| {
            flushTablet(win);
            padEvent(win, &p);
        },
        .key => |k| key(win, &k),
        .modifiers => |m| st.mods = m.mods,
        .text_input_enter, .text_input_leave, .text_input => ime.handle(win, event),
        .drag_enter, .drag_motion, .drag_leave, .drag_drop, .drag_actions => @import("dnd.zig").handle(win, event),
        .keyboard_enter => {
            st.keyboard = true;
            if (st.focus != .none) win.markPaint(st.focus);
            win.requestFrame();
        },
        .keyboard_leave => {
            st.keyboard = false;
            if (st.focus != .none) win.markPaint(st.focus);
            win.requestFrame();
        },
        else => {},
    }
}

fn pointerButton(win: *Window, code: u32, pressed: bool, time: u32) void {
    win.input.time = time;
    const st = &win.input;
    const p = st.pointer orelse return;
    const button: node_mod.Button = switch (code) {
        btn_left => .primary,
        btn_right => .secondary,
        btn_middle => .middle,
        else => .other,
    };
    if (pressed and button == .primary) {
        const near = @abs(p.x - st.last_press_at.x) <= multi_click_px and @abs(p.y - st.last_press_at.y) <= multi_click_px;
        const soon = st.clicks != 0 and time -% st.last_press_ms <= win.desktop.double_click_ms;
        st.clicks = if (near and soon) @min(st.clicks, 2) + 1 else 1;
        st.last_press_ms = time;
        st.last_press_at = p;
    }
    if (pressed) {
        const target = hitTest(win, p);
        if (target == .none) return;
        st.capture = target;
        const handled = bubblePointer(win, target, .down, button).prevents();
        // The middle button pastes the primary selection at the pointer.
        if (!handled and button == .middle and win.isLive(target) and win.node(target).kind == .editor and canFocus(win, target)) {
            setFocus(win, target, false);
            editor.pointerDown(win, target, p, false, 1);
            editor.paste(win, target, .primary);
            return;
        }
        if (handled or button != .primary or !win.isLive(target)) return;
        var cur = target;
        while (cur != .none and !canFocus(win, cur)) cur = win.node(cur).parent;
        if (cur != .none) setFocus(win, cur, false);
        if (win.node(target).kind == .editor and canFocus(win, target)) {
            editor.pointerDown(win, target, p, st.mods.shift, st.clicks);
            st.selecting = target;
            // The press is the editor's: its release activates no
            // ancestor (a list row holding an editor that renames it).
            st.pressed = .none;
            return;
        }
        cur = target;
        while (cur != .none and win.isLive(cur) and !activatable(win, cur)) cur = win.node(cur).parent;
        st.pressed = cur;
    } else {
        const target = if (st.capture != .none) st.capture else hitTest(win, p);
        st.capture = .none;
        if (button == .primary) st.selecting = .none;
        const pressed_node = st.pressed;
        st.pressed = .none;
        if (target == .none) return;
        const handled = bubblePointer(win, target, .up, button).prevents();
        if (handled or button != .primary or pressed_node == .none) return;
        // Activate only when released over the pressed node.
        const over = hitTest(win, p);
        if (over != .none and win.isLive(pressed_node) and win.isAncestor(pressed_node, over)) activate(win, pressed_node);
    }
}

fn key(win: *Window, k: *const platform.Key) void {
    const st = &win.input;
    if (k.state == .pressed) {
        st.seat = k.seat;
        st.serial = k.serial;
    }
    // Without focus, keys go to the active modal node (Escape closes a
    // dialog), or the root.
    const target = if (st.focus != .none and win.isLive(st.focus)) st.focus else modalRoot(win);
    st.time = k.time;
    const ev: Event = .{ .key = .{
        .time = k.time,
        .keysym = k.keysym,
        .pressed = k.state != .released,
        .repeat = k.state == .repeated,
        .mods = k.mods,
        .text = k.text(),
        .target = target,
    } };
    if (bubble(win, target, .key, ev).prevents()) return;
    if (target != .root and win.isLive(target) and win.node(target).kind == .editor and editor.key(win, target, k)) return;
    if (k.state == .released or k.composing) return;
    switch (k.keysym) {
        keysym.tab, keysym.iso_left_tab => traverse(win, k.keysym == keysym.tab and !k.mods.shift),
        keysym.@"return", keysym.kp_enter, keysym.space => if (st.focus != .none and k.state == .pressed) activate(win, st.focus),
        keysym.up, keysym.down, keysym.page_up, keysym.page_down, keysym.home, keysym.end, keysym.left, keysym.right => {
            const s = nearestScroll(win, target) orelse return;
            const view_h = win.state(s).size.h;
            const max = paint.maxScroll(win, s);
            const off = paint.scrollTranslation(win, s);
            const delta: Point = switch (k.keysym) {
                keysym.up => .{ .x = 0, .y = -line_step },
                keysym.down => .{ .x = 0, .y = line_step },
                keysym.page_up => .{ .x = 0, .y = -view_h * 0.9 },
                keysym.page_down => .{ .x = 0, .y = view_h * 0.9 },
                keysym.home => .{ .x = 0, .y = -off.y },
                keysym.end => .{ .x = 0, .y = max.y - off.y },
                keysym.left => .{ .x = -line_step, .y = 0 },
                keysym.right => .{ .x = line_step, .y = 0 },
                else => unreachable,
            };
            scrollBy(win, s, delta);
        },
        else => {},
    }
}

fn nearestScroll(win: *const Window, from: NodeId) ?NodeId {
    var cur = from;
    while (cur != .none) : (cur = win.node(cur).parent) if (win.node(cur).kind == .scroll) return cur;
    return null;
}

/// Passes scroll input on to the compositor as `scroll_by` (physical
/// pixels): relative, so it cannot race the compositor's own scrolling.
/// The offset changes when the compositor reports it.
pub fn scrollBy(win: *Window, id: NodeId, delta: Point) void {
    win.paint.scroll_by.append(win.gpa, .{ .node = id, .delta = delta }) catch return;
    win.dirty.props = true;
    win.requestFrame();
}

/// Scroll input the compositor forwarded: over a wheel region, with a
/// modifier held, or with nothing for it to scroll. Scroll handlers see it
/// first, from the node under the pointer up; otherwise, without ctrl,
/// alt, or super, the nearest scroll node with room scrolls.
fn scroll(win: *Window, dx_px: f32, dy_px: f32, v120_x: i32, v120_y: i32) void {
    const p = win.input.pointer orelse return;
    const target = hitTest(win, p);
    if (target == .none) return;
    const d = (platform.Scroll{ .window = 0, .seat = 0, .dx = dx_px, .dy = dy_px, .v120_x = v120_x, .v120_y = v120_y }).delta();
    var dx: f32 = @floatCast(d.x);
    var dy: f32 = @floatCast(d.y);
    const ev: Event = .{ .scroll = .{ .dx = dx, .dy = dy, .target = target } };
    if (bubble(win, target, .scroll, ev).prevents()) return;
    const mods = win.input.mods;
    // Ctrl+wheel zooms the nearest zoomable scroll node: 10% per detent.
    if (mods.ctrl and !mods.alt and !mods.super and dy != 0) {
        if (win.isLive(target)) zoomNearest(win, target, std.math.pow(f32, 1.1, -dy / @as(f32, platform.Scroll.detent_px)));
        return;
    }
    if (mods.ctrl or mods.alt or mods.super) return;
    // Shift turns a vertical wheel horizontal, as in the compositor.
    if (mods.shift and dx == 0) {
        dx = dy;
        dy = 0;
    }
    var cur: NodeId = if (win.isLive(target)) target else return;
    while (cur != .none) : (cur = win.node(cur).parent) {
        const n = win.node(cur);
        if (n.kind != .scroll) continue;
        const max = paint.maxScroll(win, cur);
        const off = paint.scrollTranslation(win, cur);
        const can_x = n.data.scroll.axis != .vertical and ((dx > 0 and off.x < max.x) or (dx < 0 and off.x > 0));
        const can_y = n.data.scroll.axis != .horizontal and ((dy > 0 and off.y < max.y) or (dy < 0 and off.y > 0));
        if (!can_x and !can_y) continue;
        scrollBy(win, cur, .{ .x = if (can_x) dx else 0, .y = if (can_y) dy else 0 });
        return;
    }
}

/// Passes a zoom on to the nearest zoomable scroll node at or above
/// `from`, about the pointer, as `zoom_by` (relative, like `scroll_by`).
fn zoomNearest(win: *Window, from: NodeId, factor: f32) void {
    const p = win.input.pointer orelse return;
    var cur = from;
    while (cur != .none) : (cur = win.node(cur).parent) {
        const n = win.node(cur);
        if (n.kind != .scroll or !n.data.scroll.zoomable()) continue;
        win.paint.scroll_by.append(win.gpa, .{ .node = cur, .zoom = factor, .focus = toLocal(win, cur, p) }) catch return;
        win.dirty.props = true;
        win.requestFrame();
        return;
    }
}

/// A touchpad gesture the compositor forwarded (D8): it bubbles from the
/// node under the pointer when it began; a pinch nobody prevented zooms
/// the nearest zoomable scroll node.
fn gesture(win: *Window, g: *const platform.Gesture) void {
    const st = &win.input;
    const k = @intFromEnum(g.kind);
    const p = st.pointer orelse return;
    if (g.phase == .begin) {
        st.gesture_target[k] = hitTest(win, p);
        if (g.kind == .pinch) st.pinch_scale = 1;
    }
    const target = st.gesture_target[k];
    if (g.phase == .end) st.gesture_target[k] = .none;
    if (target == .none or !win.isLive(target)) return;
    st.time = g.time;
    var prevented = false;
    var cur = target;
    while (cur != .none and win.isLive(cur)) {
        const local = toLocal(win, cur, p);
        const ev: Event = .{ .gesture = .{
            .kind = g.kind,
            .phase = switch (g.phase) {
                .begin => .begin,
                .update => .update,
                .end => if (g.cancelled) .cancel else .end,
            },
            .fingers = g.fingers,
            .x = local.x,
            .y = local.y,
            .dx = @floatCast(g.dx),
            .dy = @floatCast(g.dy),
            .scale = @floatCast(g.scale),
            .rotation = @floatCast(g.rotation),
            .mods = st.mods,
            .time = g.time,
            .target = target,
            .prevented = prevented,
        } };
        const r = call(win, cur, .gesture, &ev);
        prevented = prevented or r.prevents();
        if (r.stops() or !win.isLive(cur)) break;
        cur = win.node(cur).parent;
    }
    if (prevented or g.kind != .pinch or g.phase != .update or !win.isLive(target)) return;
    const scale: f32 = @floatCast(g.scale);
    if (!(scale > 0) or !(st.pinch_scale > 0)) return;
    zoomNearest(win, target, scale / st.pinch_scale);
    st.pinch_scale = scale;
}

// Tablets --------------------------------------------------------------------

/// Pending samples past this are delivered at once, without waiting for a
/// frame (a window that draws no frames, or a stalled UI thread).
const max_pending_samples = 256;

fn tabletTool(win: *Window, t: *const platform.TabletTool) void {
    const st = &win.input;
    if (t.phase == .motion) {
        st.tablet_pending.append(win.gpa, t.*) catch return deliverTablet(win, t, &.{t.*});
        if (st.tablet_pending.items.len >= max_pending_samples) flushTablet(win) else win.requestFrame();
        return;
    }
    // Motion queued before it is delivered first, in order.
    flushTablet(win);
    deliverTablet(win, t, &.{t.*});
}

/// Delivers queued tablet motion: one move event per run of samples from
/// one tool. The window calls it at the start of each frame (D5: a safe
/// point), so a tool reporting at hundreds of hertz costs handlers one call
/// per frame, with every sample for drawing.
pub fn flushTablet(win: *Window) void {
    const st = &win.input;
    var i: usize = 0;
    while (i < st.tablet_pending.items.len) {
        var j = i + 1;
        const first = st.tablet_pending.items[i];
        while (j < st.tablet_pending.items.len and st.tablet_pending.items[j].tool == first.tool and st.tablet_pending.items[j].seat == first.seat) j += 1;
        const run = st.tablet_pending.items[i..j];
        deliverTablet(win, &run[run.len - 1], run);
        i = j;
    }
    st.tablet_pending.clearRetainingCapacity();
}

fn toolState(win: *Window, t: *const platform.TabletTool) *State.ToolState {
    const st = &win.input;
    var free: ?*State.ToolState = null;
    for (&st.tools) |*ts| {
        if (ts.active and ts.seat == t.seat and ts.tool == t.tool) return ts;
        if (!ts.active and free == null) free = ts;
    }
    const ts = free orelse &st.tools[0];
    ts.* = .{ .active = true, .seat = t.seat, .tool = t.tool };
    return ts;
}

fn sampleOf(t: *const platform.TabletTool, p: Point) node_mod.TabletSample {
    return .{
        .x = p.x,
        .y = p.y,
        .pressure = @floatCast(t.pressure),
        .distance = @floatCast(t.distance),
        .tilt_x = @floatCast(t.tilt_x),
        .tilt_y = @floatCast(t.tilt_y),
        .rotation = @floatCast(t.rotation),
        .slider = @floatCast(t.slider),
        .time = t.time,
    };
}

const btn_stylus = 0x14b;
const btn_stylus2 = 0x14c;

/// Sends one tablet event, bubbling from the node the tip is pressed on
/// or the node under the tool; `samples` are the motion it sums up. Unless
/// a handler prevents it, the tool then acts as the pointer: its tip is
/// the primary button and its buttons the secondary and middle ones.
fn deliverTablet(win: *Window, t: *const platform.TabletTool, samples: []const platform.TabletTool) void {
    const st = &win.input;
    const ts = toolState(win, t);
    const p: Point = .{ .x = @floatCast(t.x), .y = @floatCast(t.y) };
    const target = if (ts.capture != .none and win.isLive(ts.capture)) ts.capture else hitTest(win, p);
    const phase: node_mod.PointerPhase = switch (t.phase) {
        .proximity_in => .enter,
        .proximity_out => .leave,
        .down => .down,
        .up => .up,
        .motion => .move,
        .button => if (t.pressed) .down else .up,
    };
    const button: node_mod.Button = if (t.phase != .button) .primary else switch (t.button) {
        btn_stylus => .secondary,
        btn_stylus2 => .middle,
        else => .other,
    };
    if (t.phase == .down) {
        ts.capture = target;
        st.seat = t.seat;
        st.serial = t.serial;
        st.press_serial = t.serial;
    }
    st.time = t.time;
    var prevented = false;
    var cur = target;
    while (cur != .none and win.isLive(cur)) {
        st.tablet_samples.clearRetainingCapacity();
        st.tablet_samples.ensureTotalCapacity(win.gpa, samples.len) catch break;
        for (samples) |*s| st.tablet_samples.appendAssumeCapacity(sampleOf(s, toLocal(win, cur, .{ .x = @floatCast(s.x), .y = @floatCast(s.y) })));
        const local = st.tablet_samples.items;
        const ev: Event = .{ .tablet = .{
            .phase = phase,
            .button = button,
            .tool = t.kind,
            .tool_id = t.tool,
            .serial_number = t.serial_number,
            .axes = t.axes,
            .sample = local[local.len - 1],
            .samples = local,
            .wheel = @floatCast(t.wheel),
            .wheel_clicks = t.wheel_clicks,
            .tip = t.tip,
            .mods = st.mods,
            .time = t.time,
            .target = target,
            .prevented = prevented,
        } };
        const r = call(win, cur, .tablet, &ev);
        prevented = prevented or r.prevents();
        if (r.stops() or !win.isLive(cur)) break;
        cur = win.node(cur).parent;
    }
    if (t.phase == .up) ts.capture = .none;
    if (t.phase == .proximity_out) ts.* = .{};
    if (prevented) return;
    // The tool as the pointer.
    const motion: platform.PointerMotion = .{ .window = t.window, .seat = t.seat, .x = t.x, .y = t.y, .time = t.time, .serial = t.serial };
    switch (t.phase) {
        .proximity_in => handle(win, &.{ .pointer_enter = motion }),
        .proximity_out => handle(win, &.{ .pointer_leave = .{ .window = t.window, .seat = t.seat, .serial = t.serial } }),
        .motion => handle(win, &.{ .pointer_motion = motion }),
        .down, .up => {
            handle(win, &.{ .pointer_motion = motion });
            handle(win, &.{ .pointer_button = .{ .window = t.window, .seat = t.seat, .button = btn_left, .pressed = t.phase == .down, .time = t.time, .serial = t.serial } });
        },
        .button => {
            const code: u32 = switch (t.button) {
                btn_stylus => btn_right,
                btn_stylus2 => btn_middle,
                else => return,
            };
            handle(win, &.{ .pointer_button = .{ .window = t.window, .seat = t.seat, .button = code, .pressed = t.pressed, .time = t.time, .serial = t.serial } });
        },
    }
}

/// A pad event goes from the focused node up, like a key; without focus,
/// to the active modal node or the root.
fn padEvent(win: *Window, p: *const platform.TabletPad) void {
    const st = &win.input;
    const target = if (st.focus != .none and win.isLive(st.focus)) st.focus else modalRoot(win);
    st.time = p.time;
    var ev: Event = .{ .pad = .{
        .control = p.control,
        .index = p.index,
        .group = p.group,
        .mode = p.mode,
        .value = p.value,
        .pressed = p.pressed,
        .lifted = p.stop,
        .time = p.time,
        .target = target,
    } };
    var cur = target;
    while (cur != .none and win.isLive(cur)) {
        const r = call(win, cur, .pad, &ev);
        if (r.prevents()) ev.pad.prevented = true;
        if (r.stops() or !win.isLive(cur)) return;
        cur = win.node(cur).parent;
    }
}
