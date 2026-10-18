//! Exports for undo stacks (D35, api_undo.zig): the application's steps,
//! each a pair of C callbacks it pushed after making a change, the
//! position between done and undone steps, groups, merging, a limit, a
//! clean mark, and a change notification. Nodes name a stack by its
//! handle (`ui.Node.undo`); the tree's key routing calls `onKey` for the
//! undo keys no editor took.
//!
//! Callbacks run with `App.depth` raised and the stack marked running:
//! its calls that change it fail with SIV_ERROR_BUSY, and destroying it
//! waits until the callback returns.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const loop_mod = @import("loop");
const api = @import("api.zig");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;
const Root = runtime.Root;

pub const undo_tag = api.spec.handleTag("siv_undo");

/// User data a step owns, released once when the step goes.
const Owned = struct {
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
};

/// A callback and the user data it gets.
const Call = struct {
    func: t.UndoStepFn,
    user_data: ?*anyopaque,
};

const Step = struct {
    /// Owned.
    label: []u8,
    kind: union(enum) {
        leaf: Leaf,
        /// Undone newest first, redone oldest first.
        group: std.ArrayList(Step),
    },

    const Leaf = struct {
        undo: Call,
        redo: Call,
        merge: u64,
        /// The step pushed first, and the last one merged into it.
        first: Owned,
        last: ?Owned = null,
    };

    fn deinit(s: *Step, self: *App) void {
        const gpa = self.gpa();
        switch (s.kind) {
            .leaf => |l| {
                self.release(l.first.destroy, l.first.user_data);
                if (l.last) |o| self.release(o.destroy, o.user_data);
            },
            .group => |*g| {
                for (g.items) |*c| c.deinit(self);
                g.deinit(gpa);
            },
        }
        gpa.free(s.label);
    }

    fn run(s: *const Step, stack: *Stack, redo: bool) void {
        switch (s.kind) {
            .leaf => |l| {
                const c = if (redo) l.redo else l.undo;
                c.func(c.user_data, @fromBackingInt(stack.handle));
            },
            .group => |g| {
                var i: usize = 0;
                while (i < g.items.len) : (i += 1) {
                    if (stack.doomed) return;
                    g.items[if (redo) i else g.items.len - 1 - i].run(stack, redo);
                }
            },
        }
    }
};

pub const Stack = struct {
    owner: *App,
    index: u32,
    handle: u64 = 0,
    /// steps[0..done] are done, the rest undone.
    steps: std.ArrayList(Step) = .empty,
    done: usize = 0,
    /// The position siv_undo_set_clean marked; null once it is dropped.
    clean: ?usize = 0,
    limit: u32,
    /// Open groups, their steps, and the outermost group's label (owned).
    depth: u32 = 0,
    group: std.ArrayList(Step) = .empty,
    group_label: []u8 = &.{},
    /// One of its callbacks is running.
    running: bool = false,
    /// Destroyed while running: freed when the callback returns.
    doomed: bool = false,
    on_change: ?t.UndoChangeFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    notify: loop_mod.Loop.Task = .{ .func = onNotify },

    fn mutable(s: *Stack) Error!void {
        if (s.running) return error.Busy;
    }

    fn settled(s: *Stack) Error!void {
        try s.mutable();
        if (s.depth != 0) return error.Busy;
    }

    fn isClean(s: *const Stack) bool {
        return s.clean == s.done and s.group.items.len == 0;
    }

    /// The step undo (or redo) would run.
    fn next(s: *Stack, redo: bool) ?*Step {
        if (redo) return if (s.done < s.steps.items.len) &s.steps.items[s.done] else null;
        return if (s.done > 0) &s.steps.items[s.done - 1] else null;
    }

    /// Tells on_change in the next dispatch phase, once for any number of
    /// changes.
    fn changed(s: *Stack) void {
        if (s.on_change != null) s.owner.app.loop.schedule(&s.notify, .dispatch);
    }

    fn onNotify(task: *loop_mod.Loop.Task) void {
        const s: *Stack = @fieldParentPtr("notify", task);
        const cb = s.on_change orelse return;
        const u = if (s.next(false)) |st| st.label else "";
        const r = if (s.next(true)) |st| st.label else "";
        const ev: t.UndoEvent = .{
            .undo_label = u.ptr,
            .undo_label_len = u.len,
            .redo_label = r.ptr,
            .redo_label_len = r.len,
            .flags = .{ .clean = s.isClean() },
            .undo_count = @intCast(s.done),
            .redo_count = @intCast(s.steps.items.len - s.done),
        };
        s.enter();
        cb(s.user_data, @fromBackingInt(s.handle), &ev);
        s.leave();
    }

    fn enter(s: *Stack) void {
        s.running = true;
        s.owner.enter();
    }

    /// After a callback: the stack goes now if it was destroyed meanwhile.
    fn leave(s: *Stack) void {
        const self = s.owner;
        s.running = false;
        if (s.doomed) s.free();
        self.leave();
    }

    /// Drops the undone steps.
    fn truncate(s: *Stack) void {
        if (s.clean) |c| if (c > s.done) {
            s.clean = null;
        };
        for (s.steps.items[s.done..]) |*st| st.deinit(s.owner);
        s.steps.shrinkRetainingCapacity(s.done);
    }

    /// Appends a done step, with room reserved, after the redo list is
    /// dropped, and drops the oldest past the limit.
    fn append(s: *Stack, step: Step) void {
        s.truncate();
        s.steps.appendAssumeCapacity(step);
        s.done += 1;
        if (s.limit != 0 and s.steps.items.len > s.limit) {
            var old = s.steps.orderedRemove(0);
            old.deinit(s.owner);
            s.done -= 1;
            s.clean = if (s.clean) |c| (if (c == 0) null else c - 1) else null;
        }
        s.changed();
    }

    fn apply(s: *Stack, redo: bool) Error!void {
        try s.settled();
        const step = s.next(redo) orelse return;
        if (redo) s.done += 1 else s.done -= 1;
        s.changed();
        // Nothing changes the steps while it runs (the stack is busy).
        s.enter();
        step.run(s, redo);
        s.leave();
    }

    fn push(s: *Stack, d: *const t.UndoStepDesc) Error!void {
        try s.mutable();
        const undo_fn = d.undo orelse return error.InvalidArgument;
        const redo_fn = d.redo orelse return error.InvalidArgument;
        const label_in = try runtime.string(d.label, d.label_len);
        const gpa = s.owner.gpa();
        const label = try gpa.dupe(u8, label_in);
        errdefer gpa.free(label);
        const in_group = s.depth != 0;
        const list = if (in_group) &s.group else &s.steps;
        const owned: Owned = .{ .destroy = d.destroy, .user_data = d.user_data };
        if (d.merge != 0) merge: {
            // The last step, done, and not the clean state.
            const last = if (in_group) (if (s.group.items.len != 0) &s.group.items[s.group.items.len - 1] else break :merge) else blk: {
                if (s.done == 0 or s.clean == s.done) break :merge;
                break :blk &s.steps.items[s.done - 1];
            };
            if (last.kind != .leaf or last.kind.leaf.merge != d.merge) break :merge;
            if (!in_group) s.truncate();
            const l = &last.kind.leaf;
            if (l.last) |o| s.owner.release(o.destroy, o.user_data);
            l.last = owned;
            l.redo = .{ .func = redo_fn, .user_data = d.user_data };
            gpa.free(last.label);
            last.label = label;
            s.changed();
            return;
        }
        try list.ensureUnusedCapacity(gpa, 1);
        const step: Step = .{ .label = label, .kind = .{ .leaf = .{
            .undo = .{ .func = undo_fn, .user_data = d.user_data },
            .redo = .{ .func = redo_fn, .user_data = d.user_data },
            .merge = d.merge,
            .first = owned,
        } } };
        if (in_group) {
            s.group.appendAssumeCapacity(step);
            // No longer clean.
            s.changed();
        } else s.append(step);
    }

    fn endGroup(s: *Stack) Error!void {
        try s.mutable();
        if (s.depth == 0) return error.InvalidArgument;
        const gpa = s.owner.gpa();
        if (s.depth == 1 and s.group.items.len != 0) {
            try s.steps.ensureUnusedCapacity(gpa, 1);
            s.append(.{ .label = s.group_label, .kind = .{ .group = s.group } });
            s.group = .empty;
            s.group_label = &.{};
        } else if (s.depth == 1) {
            gpa.free(s.group_label);
            s.group_label = &.{};
        }
        s.depth -= 1;
    }

    fn clear(s: *Stack) void {
        const was_clean = s.isClean();
        for (s.steps.items) |*st| st.deinit(s.owner);
        s.steps.clearRetainingCapacity();
        s.done = 0;
        s.clean = if (was_clean) 0 else null;
        s.changed();
    }

    /// Destroyed, or dropped with the application: the handle goes now,
    /// the rest once no callback of the stack runs.
    fn remove(s: *Stack) void {
        const self = s.owner;
        _ = self.root.handles.remove(s.handle, undo_tag) catch unreachable;
        self.undos.items[s.index] = null;
        self.app.loop.unschedule(&s.notify);
        if (s.running) {
            s.doomed = true;
            return;
        }
        s.free();
    }

    fn free(s: *Stack) void {
        const self = s.owner;
        const gpa = self.gpa();
        for (s.steps.items) |*st| st.deinit(self);
        s.steps.deinit(gpa);
        for (s.group.items) |*st| st.deinit(self);
        s.group.deinit(gpa);
        gpa.free(s.group_label);
        self.release(s.destroy, s.user_data);
        gpa.destroy(s);
    }
};

/// Drops every stack with the application.
pub fn teardown(self: *App) void {
    for (self.undos.items) |slot| if (slot) |s| s.remove();
    self.undos.deinit(self.gpa());
}

fn lookup(handle: u64) Error!*Stack {
    const self, const index = try Root.owner(App, application.app_tag, handle, undo_tag);
    return self.undos.items[index] orelse error.InvalidHandle;
}

/// The tree's undo keys (`ui.Window.undo_host`): false when the stack is
/// gone, so the key goes on to a stack further up.
fn onKey(_: ?*anyopaque, handle: u64, redo: bool) bool {
    const s = lookup(handle) catch return false;
    s.apply(redo) catch {};
    return true;
}

pub export fn siv_undo_create(app: t.App, desc: ?*const t.UndoDesc, undo: ?*t.Undo) t.Result {
    const d = runtime.readDesc(t.UndoDesc, desc) catch |err| return t.resultOf(err);
    const self = App.get(@backingInt(app)) catch |err| {
        if (d.destroy) |f| f(d.user_data);
        return t.resultOf(err);
    };
    const r = application.wrap(create(self, &d, undo));
    // The call failed: the caller handed user_data over anyway (D2).
    if (r != .ok) self.release(d.destroy, d.user_data);
    return r;
}

fn create(self: *App, d: *const t.UndoDesc, out: ?*t.Undo) Error!void {
    const dest = try runtime.out(t.Undo, out);
    const gpa = self.gpa();
    const index: u32 = for (self.undos.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        try self.undos.append(gpa, null);
        break :blk @intCast(self.undos.items.len - 1);
    };
    const s = try gpa.create(Stack);
    errdefer gpa.destroy(s);
    s.* = .{ .owner = self, .index = index, .limit = d.limit, .on_change = d.on_change, .destroy = d.destroy, .user_data = d.user_data };
    try self.root.handles.ensureUnusedCapacity(gpa);
    s.handle = self.root.handles.insert(gpa, undo_tag, index) catch unreachable;
    self.undos.items[index] = s;
    dest.* = @fromBackingInt(s.handle);
}

pub export fn siv_undo_destroy(undo: t.Undo) void {
    const s = lookup(@backingInt(undo)) catch return;
    s.remove();
}

pub export fn siv_undo_push(undo: t.Undo, desc: ?*const t.UndoStepDesc) t.Result {
    const d = runtime.readDesc(t.UndoStepDesc, desc) catch |err| return t.resultOf(err);
    const s = lookup(@backingInt(undo)) catch |err| {
        // Without the stack's application there is no safe point to wait
        // for: release at once.
        if (d.destroy) |f| f(d.user_data);
        return t.resultOf(err);
    };
    const r = application.wrap(s.push(&d));
    if (r != .ok) s.owner.release(d.destroy, d.user_data);
    return r;
}

pub export fn siv_undo_undo(undo: t.Undo) t.Result {
    const s = lookup(@backingInt(undo)) catch |err| return t.resultOf(err);
    return application.wrap(s.apply(false));
}

pub export fn siv_undo_redo(undo: t.Undo) t.Result {
    const s = lookup(@backingInt(undo)) catch |err| return t.resultOf(err);
    return application.wrap(s.apply(true));
}

pub export fn siv_undo_begin_group(undo: t.Undo, label: ?[*]const u8, label_len: usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.Undo, p: ?[*]const u8, n: usize) Error!void {
            const s = try lookup(@backingInt(h));
            try s.mutable();
            const text = try runtime.string(p, n);
            if (s.depth == 0) s.group_label = try s.owner.gpa().dupe(u8, text);
            s.depth += 1;
        }
    }.f(undo, label, label_len));
}

pub export fn siv_undo_end_group(undo: t.Undo) t.Result {
    const s = lookup(@backingInt(undo)) catch |err| return t.resultOf(err);
    return application.wrap(s.endGroup());
}

pub export fn siv_undo_set_clean(undo: t.Undo) t.Result {
    const s = lookup(@backingInt(undo)) catch |err| return t.resultOf(err);
    s.settled() catch |err| return t.resultOf(err);
    if (s.clean != s.done) {
        s.clean = s.done;
        s.changed();
    }
    return .ok;
}

pub export fn siv_undo_clear(undo: t.Undo) t.Result {
    const s = lookup(@backingInt(undo)) catch |err| return t.resultOf(err);
    s.settled() catch |err| return t.resultOf(err);
    s.clear();
    return .ok;
}

pub export fn siv_undo_get_count(undo: t.Undo, redo: bool, count: ?*u32) t.Result {
    const s = lookup(@backingInt(undo)) catch |err| return t.resultOf(err);
    const dest = runtime.out(u32, count) catch |err| return t.resultOf(err);
    dest.* = @intCast(if (redo) s.steps.items.len - s.done else s.done);
    return .ok;
}

pub export fn siv_undo_is_clean(undo: t.Undo, clean: ?*bool) t.Result {
    const s = lookup(@backingInt(undo)) catch |err| return t.resultOf(err);
    const dest = runtime.out(bool, clean) catch |err| return t.resultOf(err);
    dest.* = s.isClean();
    return .ok;
}

pub export fn siv_undo_get_label(undo: t.Undo, redo: bool, label: ?[*]u8, label_cap: usize, len: ?*usize) t.Result {
    const s = lookup(@backingInt(undo)) catch |err| return t.resultOf(err);
    const buf = runtime.buffer(label, label_cap) catch |err| return t.resultOf(err);
    const dest = runtime.out(usize, len) catch |err| return t.resultOf(err);
    const text = if (s.next(redo)) |st| st.label else "";
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    dest.* = text.len;
    return .ok;
}

pub export fn siv_set_undo(txn: t.Txn, node: t.Node, undo: t.Undo) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, u: t.Undo) Error!void {
            const id = try tree.nodeIn(w, n);
            const h = @backingInt(u);
            if (h != 0 and (try lookup(h)).owner != w.owner) return error.InvalidArgument;
            w.txn.ut.setUndo(id, h) catch |err| return tree.mapTxn(err);
            w.uiWin().undo_host = .{ .ctx = null, .func = onKey };
        }
    }.f, .{ node, undo });
}
