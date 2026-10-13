//! libsiv-abitest: implements test_api.zig with the same runtime as libsiv
//! so that test/c/abi.c can exercise every ABI convention through a real
//! shared library with a version script. Not installed.
//!
//! Imports: sivtest (generated), build_options.

const std = @import("std");
const build_options = @import("build_options");
const t = @import("sivtest");
const schema = @import("schema.zig");
const test_api = @import("test_api.zig");
const runtime = @import("runtime.zig");
const alloc = @import("alloc.zig");
const Error = runtime.Error;
const Root = runtime.Root;

/// As libsiv (src/siv.zig): no per-thread alternative signal stack.
pub const std_options: std.Options = .{ .signal_stack_size = null };

const spec = test_api.spec;
const context_tag = spec.handleTag("sivtest_context");
const item_tag = spec.handleTag("sivtest_item");

comptime {
    @setEvalBranchQuota(100_000);
    if (schema.validate(spec, build_options.version)) |p| @compileError(spec.source ++ ": " ++ p.where ++ ": " ++ p.what);
    for (spec.functions) |f| {
        if (!@hasDecl(@This(), f.name)) @compileError("schema function not exported: " ++ f.name);
        if (@TypeOf(@field(@This(), f.name)) != @field(t.signatures, f.name)) @compileError("export does not match its schema signature: " ++ f.name);
    }
    runtime.checkDescriptors(t);
}

const Context = struct {
    root: Root,
    /// In creation order; a handle's payload is its index here.
    items: std.ArrayList(Item),
    hook: ?t.HookFn = null,
    destroy: ?t.DestroyFn = null,
    user_data: ?*anyopaque = null,

    fn releaseHook(self: *Context) void {
        if (self.destroy) |d| d(self.user_data);
        self.hook = null;
        self.destroy = null;
        self.user_data = null;
    }
};

const Item = struct {
    handle: u64,
    name: []u8,
    shape: t.Shape,
    flags: t.ItemFlags,
    origin: t.Point,
    weight: i64,
    tags: []u32,
};

fn wrap(r: Error!void) t.Result {
    r catch |err| return t.resultOf(err);
    return .ok;
}

pub export fn sivtest_context_create(desc: ?*const t.ContextDesc, context: ?*t.Context) t.Result {
    return wrap(contextCreate(desc, context));
}

fn contextCreate(desc_ptr: ?*const t.ContextDesc, out: ?*t.Context) Error!void {
    const desc = try runtime.readDesc(t.ContextDesc, desc_ptr);
    const hooks = if (desc.allocator) |a| try alloc.fromDesc(try runtime.readDesc(t.Allocator, a)) else null;
    const dest = try runtime.out(t.Context, out);
    const self = try Root.create(Context, context_tag, hooks);
    self.items = .empty;
    self.hook = null;
    self.destroy = null;
    self.user_data = null;
    dest.* = @fromBackingInt(self.root.handle);
}

pub export fn sivtest_context_destroy(context: t.Context) t.Result {
    const self = Root.get(Context, context_tag, @backingInt(context)) catch |err| return t.resultOf(err);
    self.releaseHook();
    for (self.items.items) |item| {
        self.root.gpa.free(item.name);
        self.root.gpa.free(item.tags);
    }
    self.items.deinit(self.root.gpa);
    Root.destroy(Context, self);
    return .ok;
}

pub export fn sivtest_item_create(context: t.Context, desc: ?*const t.ItemDesc, item: ?*t.Item) t.Result {
    return wrap(itemCreate(context, desc, item));
}

fn itemCreate(context: t.Context, desc_ptr: ?*const t.ItemDesc, out: ?*t.Item) Error!void {
    const self = try Root.get(Context, context_tag, @backingInt(context));
    const desc = try runtime.readDesc(t.ItemDesc, desc_ptr);
    const name = try runtime.string(desc.name, desc.name_len);
    const shape = try runtime.enumValue(t.Shape, desc.shape);
    const flags = try runtime.flags(t.ItemFlags, desc.flags);
    const tags = try runtime.array(u32, desc.tags, desc.tags_count);
    const dest = try runtime.out(t.Item, out);

    const gpa = self.root.gpa;
    const copy = try gpa.dupe(u8, name);
    errdefer gpa.free(copy);
    const tags_copy = try gpa.dupe(u32, tags);
    errdefer gpa.free(tags_copy);
    try self.items.ensureUnusedCapacity(gpa, 1);
    try self.root.handles.ensureUnusedCapacity(gpa);
    // Nothing below can fail.
    const handle = self.root.handles.insert(gpa, item_tag, @intCast(self.items.items.len)) catch unreachable;
    self.items.appendAssumeCapacity(.{
        .handle = handle,
        .name = copy,
        .shape = shape,
        .flags = flags,
        .origin = desc.origin,
        .weight = if (desc.weight == 0) 1 else desc.weight,
        .tags = tags_copy,
    });
    dest.* = @fromBackingInt(handle);
}

pub export fn sivtest_item_destroy(item: t.Item) t.Result {
    const self, const index = Root.owner(Context, context_tag, @backingInt(item), item_tag) catch |err| return t.resultOf(err);
    _ = self.root.handles.remove(@backingInt(item), item_tag) catch unreachable;
    const removed = self.items.orderedRemove(index);
    self.root.gpa.free(removed.name);
    self.root.gpa.free(removed.tags);
    // Later items moved down by one; repoint their handles.
    for (self.items.items[index..], index..) |moved, i| self.root.handles.set(moved.handle, item_tag, @intCast(i)) catch unreachable;
    return .ok;
}

pub export fn sivtest_item_get(item: t.Item, info: ?*t.ItemInfo) t.Result {
    const self, const index = Root.owner(Context, context_tag, @backingInt(item), item_tag) catch |err| return t.resultOf(err);
    const dest = runtime.out(t.ItemInfo, info) catch |err| return t.resultOf(err);
    const it = self.items.items[index];
    dest.* = .{ .shape = it.shape, .flags = it.flags, .origin = it.origin, .weight = it.weight, .name_len = it.name.len };
    return .ok;
}

pub export fn sivtest_item_set_name(item: t.Item, name: ?[*]const u8, name_len: usize) t.Result {
    return wrap(itemSetName(item, name, name_len));
}

fn itemSetName(item: t.Item, name_ptr: ?[*]const u8, name_len: usize) Error!void {
    const self, const index = try Root.owner(Context, context_tag, @backingInt(item), item_tag);
    const copy = try self.root.gpa.dupe(u8, try runtime.string(name_ptr, name_len));
    const it = &self.items.items[index];
    self.root.gpa.free(it.name);
    it.name = copy;
}

/// Deprecated in the schema: it still works (D2).
pub export fn sivtest_item_rename(item: t.Item, name: ?[*]const u8, name_len: usize) t.Result {
    return sivtest_item_set_name(item, name, name_len);
}

pub export fn sivtest_context_visit(context: t.Context, callback: ?t.VisitFn, user_data: ?*anyopaque, visited: ?*u32) t.Result {
    const self = Root.get(Context, context_tag, @backingInt(context)) catch |err| return t.resultOf(err);
    const cb = callback orelse return .error_invalid_argument;
    const dest = runtime.out(u32, visited) catch |err| return t.resultOf(err);
    var n: u32 = 0;
    for (self.items.items) |it| {
        if (it.flags.hidden) continue;
        n += 1;
        if (!cb(user_data, @fromBackingInt(it.handle), it.name.ptr, it.name.len)) break;
    }
    dest.* = n;
    return .ok;
}

pub export fn sivtest_context_item_count(context: t.Context) u32 {
    const self = Root.get(Context, context_tag, @backingInt(context)) catch return 0;
    return @intCast(self.items.items.len);
}

pub export fn sivtest_item_get_name(item: t.Item, name: ?[*]u8, name_cap: usize, len: ?*usize) t.Result {
    return wrap(itemGetName(item, name, name_cap, len));
}

fn itemGetName(item: t.Item, name_ptr: ?[*]u8, name_cap: usize, len: ?*usize) Error!void {
    const self, const index = try Root.owner(Context, context_tag, @backingInt(item), item_tag);
    const buf = try runtime.buffer(name_ptr, name_cap);
    const dest = try runtime.out(usize, len);
    const name = self.items.items[index].name;
    const n = @min(name.len, buf.len);
    @memcpy(buf[0..n], name[0..n]);
    dest.* = name.len;
}

pub export fn sivtest_item_tag_sum(item: t.Item, sum: ?*u64) t.Result {
    const self, const index = Root.owner(Context, context_tag, @backingInt(item), item_tag) catch |err| return t.resultOf(err);
    const dest = runtime.out(u64, sum) catch |err| return t.resultOf(err);
    var total: u64 = 0;
    for (self.items.items[index].tags) |tag| total += tag;
    dest.* = total;
    return .ok;
}

pub export fn sivtest_context_set_hook(context: t.Context, hook: ?t.HookFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const self = Root.get(Context, context_tag, @backingInt(context)) catch |err| return t.resultOf(err);
    self.releaseHook();
    self.hook = hook;
    self.destroy = destroy;
    self.user_data = user_data;
    return .ok;
}

pub export fn sivtest_context_run_hook(context: t.Context) t.Result {
    const self = Root.get(Context, context_tag, @backingInt(context)) catch |err| return t.resultOf(err);
    if (self.hook) |h| h(self.user_data);
    return .ok;
}
