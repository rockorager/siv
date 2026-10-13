//! What every exported function goes through: reading descriptors, strings,
//! enums, flags, and out pointers from C; roots with their allocator and
//! handle table; and the Zig error set that maps onto the result enum.
//!
//! An export is a thin shell around a Zig function returning `Error!T`:
//!
//!     export fn siv_thing_create(app: t.App, desc: ?*const t.ThingDesc, thing: ?*t.Thing) t.Result {
//!         thingCreate(app, desc, thing) catch |err| return t.resultOf(err);
//!         return .ok;
//!     }
//!
//! where `t` is the generated Zig wrapper, whose types match the header.
//! The function validates every input before changing any state, so that a
//! failed call has no effect, and writes outputs last.

const std = @import("std");
const handles = @import("handles.zig");
const alloc = @import("alloc.zig");

/// Errors an export can return; a subset of the generated `AbiError`.
pub const Error = error{ OutOfMemory, InvalidHandle, InvalidArgument, Unsupported, LimitExceeded };

/// Copies a descriptor from C (D2). NULL gives all defaults. A descriptor
/// from older headers (smaller size) gets defaults for the fields it lacks;
/// one from newer headers (larger size) is accepted only if every byte this
/// version does not know is zero, since a nonzero field asks for behavior
/// this version cannot provide. A size that is not the end of some field is
/// an invalid argument.
pub fn readDesc(comptime T: type, ptr: ?*const T) Error!T {
    comptime checkDescriptor(T);
    var result: T = std.mem.zeroes(T);
    result.size = @sizeOf(T);
    const p = ptr orelse return result;
    const bytes: [*]const u8 = @ptrCast(p);
    const size = p.size;
    if (size > @sizeOf(T)) {
        if (!std.mem.allEqual(u8, bytes[@sizeOf(T)..size], 0)) return error.Unsupported;
    } else if (!isFieldEnd(T, size)) {
        return error.InvalidArgument;
    }
    const n = @min(size, @sizeOf(T));
    @memcpy(std.mem.asBytes(&result)[@sizeOf(usize)..n], bytes[@sizeOf(usize)..n]);
    try reservedZero(result);
    return result;
}

/// Reserved fields (D2) are zero until a version gives them a meaning:
/// checked for descriptors by readDesc, and for value structs from C (a
/// span, a tab stop) by the code that reads them.
pub fn reservedZero(v: anytype) Error!void {
    const T = @TypeOf(v);
    if (@hasDecl(T, "reserved")) inline for (T.reserved) |name| {
        if (@field(v, name) != 0) return error.Unsupported;
    };
}

/// Whether an older version of descriptor T can have this size: fields are
/// only appended, so every older size is the end of some field.
fn isFieldEnd(comptime T: type, size: usize) bool {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (size == @offsetOf(T, name) + @sizeOf(F)) return true;
    }
    return false;
}

/// Runs the descriptor layout check on every descriptor of a generated
/// wrapper, used or not.
pub fn checkDescriptors(comptime W: type) void {
    for (@typeInfo(W).@"struct".decl_names) |name| {
        const T = @field(W, name);
        if (@TypeOf(T) == type and @typeInfo(T) == .@"struct" and @hasDecl(T, "descriptor")) checkDescriptor(T);
    }
}

/// Descriptors start with `size: usize` and have no padding, so that bytes
/// past the known end are either fields or zero.
fn checkDescriptor(comptime T: type) void {
    const info = @typeInfo(T).@"struct";
    if (info.layout != .@"extern") @compileError(@typeName(T) ++ " is not extern");
    if (!std.mem.eql(u8, info.field_names[0], "size") or info.field_types[0] != usize) @compileError(@typeName(T) ++ " does not start with size");
    var end: usize = 0;
    for (info.field_names, info.field_types) |name, F| {
        if (@offsetOf(T, name) != end) @compileError(@typeName(T) ++ " has padding before " ++ name ++ "; reorder its fields");
        end += @sizeOf(F);
    }
    if (end != @sizeOf(T)) @compileError(@typeName(T) ++ " has trailing padding; append a field");
}

/// A string from C. NULL with length 0 is empty.
pub fn string(ptr: ?[*]const u8, len: usize) Error![]const u8 {
    const p = ptr orelse return if (len == 0) "" else error.InvalidArgument;
    return p[0..len];
}

/// An array from C. NULL with count 0 is empty.
pub fn array(comptime T: type, ptr: ?[*]const T, count: usize) Error![]const T {
    const p = ptr orelse return if (count == 0) &.{} else error.InvalidArgument;
    return p[0..count];
}

/// Caller memory to fill. NULL with capacity 0 asks only for the length.
pub fn buffer(ptr: ?[*]u8, cap: usize) Error![]u8 {
    const p = ptr orelse return if (cap == 0) &.{} else error.InvalidArgument;
    return p[0..cap];
}

/// An enum value from C: unknown values of a closed enum are unsupported;
/// open enums pass every value.
pub fn enumValue(comptime E: type, v: E) Error!E {
    if (@hasDecl(E, "open")) return v;
    inline for (@typeInfo(E).@"enum".field_values) |value| {
        if (@backingInt(v) == value) return v;
    }
    return error.Unsupported;
}

/// Flags from C: unknown bits are unsupported.
pub fn flags(comptime F: type, v: F) Error!F {
    const bits: u32 = @bitCast(v);
    if (bits & ~F.known_bits != 0) return error.Unsupported;
    return v;
}

/// An out pointer from C: NULL is an invalid argument.
pub fn out(comptime T: type, p: ?*T) Error!*T {
    return p orelse error.InvalidArgument;
}

/// The ABI state every root object carries: its allocator and the handle
/// table of the objects it owns. A root type embeds it as a field named
/// `root` and is created with `create`.
pub const Root = struct {
    hooks: ?alloc.Hooks,
    /// Every allocation on behalf of this root.
    gpa: std.mem.Allocator,
    handles: handles.Table,
    handle: u64,

    /// Allocates a T with the given hooks (null for the default) and
    /// registers it. The caller initializes T's other fields and destroys
    /// it with `destroy` on any later failure.
    pub fn create(comptime T: type, tag: u8, hooks: ?alloc.Hooks) Error!*T {
        var tmp = hooks;
        const self = try alloc.Hooks.allocator(if (tmp) |*h| h else null).create(T);
        const handle = handles.registry.register(tag, self) catch |err| {
            alloc.Hooks.allocator(if (tmp) |*h| h else null).destroy(self);
            return err;
        };
        self.root = .{ .hooks = hooks, .gpa = undefined, .handles = .init(handle), .handle = handle };
        self.root.gpa = alloc.Hooks.allocator(if (self.root.hooks) |*h| h else null);
        return self;
    }

    /// Makes the root's handle and every handle it issued invalid, and
    /// waits for threads that pinned it (`pin`) to leave. Call before
    /// tearing down what pinned callers use; `destroy` does it too.
    pub fn retire(self: *Root) void {
        handles.registry.retire(self.handle);
    }

    /// Unregisters and frees a T made by `create`. Its handle and every
    /// object handle it issued become invalid. T's other resources must be
    /// freed first.
    pub fn destroy(comptime T: type, self: *T) void {
        handles.registry.unregister(self.root.handle);
        self.root.handles.deinit(self.root.gpa);
        var hooks = self.root.hooks;
        alloc.Hooks.allocator(if (hooks) |*h| h else null).destroy(self);
    }

    /// The T a root handle names.
    pub fn get(comptime T: type, tag: u8, handle: u64) Error!*T {
        return @ptrCast(@alignCast(try handles.registry.root(handle, tag)));
    }

    /// The T a root handle names, from any thread, kept alive until
    /// `unpin`: destroying it waits (see `retire`).
    pub fn pin(comptime T: type, tag: u8, handle: u64) Error!*T {
        return @ptrCast(@alignCast(try handles.registry.pin(handle, tag)));
    }

    /// The T that owns an object handle, from any thread, kept alive
    /// until `unpin(handle)` (see `Registry.pinOwner` for what the caller
    /// must check).
    pub fn pinOwner(comptime T: type, root_tag: u8, handle: u64) Error!*T {
        return @ptrCast(@alignCast(try handles.registry.pinOwner(handle, root_tag)));
    }

    pub fn unpin(handle: u64) void {
        handles.registry.unpin(handle);
    }

    /// The T that owns an object handle, and the object's payload.
    pub fn owner(comptime T: type, root_tag: u8, handle: u64, tag: u8) Error!struct { *T, u32 } {
        const self: *T = @ptrCast(@alignCast(try handles.registry.owner(handle, root_tag)));
        return .{ self, try self.root.handles.get(handle, tag) };
    }
};

test "readDesc: null, older, newer, and malformed sizes" {
    const D = extern struct {
        size: usize = @sizeOf(@This()),
        a: u32 = 0,
        b: u32 = 0,
        c: u64 = 0,
    };
    try std.testing.expectEqual(D{}, try readDesc(D, null));

    const full: D = .{ .a = 1, .b = 2, .c = 3 };
    try std.testing.expectEqual(full, try readDesc(D, &full));

    // Older headers: c did not exist yet.
    var old = full;
    old.size = @offsetOf(D, "c");
    try std.testing.expectEqual(D{ .a = 1, .b = 2 }, try readDesc(D, &old));

    // Mid-field size.
    var bad = full;
    bad.size = @offsetOf(D, "c") + 4;
    try std.testing.expectError(error.InvalidArgument, readDesc(D, &bad));
    bad.size = 0;
    try std.testing.expectError(error.InvalidArgument, readDesc(D, &bad));

    // Newer headers: a field this version does not know.
    const Newer = extern struct { d: D, extra: u64 };
    var newer: Newer = .{ .d = full, .extra = 0 };
    newer.d.size = @sizeOf(Newer);
    try std.testing.expectEqual(full, try readDesc(D, &newer.d));
    newer.extra = 1;
    try std.testing.expectError(error.Unsupported, readDesc(D, &newer.d));
}

test "readDesc rejects nonzero reserved fields" {
    const R = extern struct {
        size: usize = @sizeOf(@This()),
        value: i32 = 0,
        reserved0: u32 = 0,
        pub const descriptor = true;
        pub const reserved = .{"reserved0"};
    };
    try std.testing.expectEqual(@as(i32, 7), (try readDesc(R, &.{ .value = 7 })).value);
    try std.testing.expectError(error.Unsupported, readDesc(R, &.{ .reserved0 = 1 }));
}

test "string, enumValue, flags, out" {
    try std.testing.expectEqualStrings("", try string(null, 0));
    try std.testing.expectError(error.InvalidArgument, string(null, 1));
    try std.testing.expectEqualStrings("a\x00b", try string("a\x00b", 3));

    const E = enum(i32) { a = 0, b = 5, _ };
    try std.testing.expectEqual(E.b, try enumValue(E, .b));
    try std.testing.expectError(error.Unsupported, enumValue(E, @fromBackingInt(4)));
    // Open enums pass values they do not name.
    const O = enum(i32) {
        a = 0,
        _,
        pub const open = true;
    };
    try std.testing.expectEqual(@as(O, @fromBackingInt(4)), try enumValue(O, @fromBackingInt(4)));

    const F = packed struct(u32) {
        x: bool = false,
        _r: u31 = 0,
        pub const known_bits: u32 = 1;
    };
    _ = try flags(F, .{ .x = true });
    try std.testing.expectError(error.Unsupported, flags(F, @bitCast(@as(u32, 2))));

    try std.testing.expectError(error.InvalidArgument, out(u32, null));
}
