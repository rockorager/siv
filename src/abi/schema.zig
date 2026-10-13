//! The API schema format (D3). A `Schema` describes every type and function
//! of a C ABI; generators (gen.zig) turn it into the C header, the Zig
//! wrapper, the JSON description, the reference documentation, and the
//! linker version script. The product schema is api.zig.
//!
//! Plain data only, so the generator can import it on the build host.
//!
//! Conventions every schema follows (D2; checked by `validate`):
//!
//! - Objects are `handle`s: generation-checked `uint64_t` values, 0 is null.
//! - Descriptor structs (`Struct.kind == .descriptor`) begin with an implicit
//!   `size_t size` field and are passed by pointer (`Type.desc`), NULL meaning
//!   all defaults. Zero means default in every field. Fields are only ever
//!   appended. Descriptors have no padding (checked against the target in
//!   runtime.zig), so that bytes past a reader's known size can be required
//!   to be zero.
//! - Value structs (`.value`) are frozen forever and may be embedded by value.
//! - Strings are `Type.string`: a `const char *` and a `size_t` length, so
//!   embedded NUL is allowed. The library never keeps the caller's pointer.
//! - Arrays are `Type.array`: a const pointer and a `size_t` count.
//! - Callbacks take `void *user_data` as their first parameter. In a
//!   parameter list a callback is followed by its `user_data` parameter,
//!   or a run of callbacks (a callback and its destroy-notify) by their
//!   shared `user_data`; a struct with callback fields has one `user_data`
//!   field.
//! - Fallible functions return the schema's result enum and write their
//!   outputs through trailing `Type.out` parameters.

const std = @import("std");

pub const Version = struct {
    major: u16,
    minor: u16,

    pub fn order(a: Version, b: Version) std.math.Order {
        return switch (std.math.order(a.major, b.major)) {
            .eq => std.math.order(a.minor, b.minor),
            else => |o| o,
        };
    }
};

pub const Schema = struct {
    /// Library name. Upper-cased, it prefixes macros and version nodes.
    name: []const u8,
    /// Prefix of every function name, for example "siv_".
    prefix: []const u8,
    /// Path of the schema source, quoted in generated files.
    source: []const u8,
    doc: []const u8,
    /// Name of the enum that fallible functions return. Its value 0 is
    /// success; values whose name starts with "error_" are errors.
    result: []const u8,
    /// Declarations in dependency order.
    decls: []const Decl,
    functions: []const Function,

    pub fn find(s: Schema, name: []const u8) ?Decl {
        for (s.decls) |d| if (std.mem.eql(u8, d.name(), name)) return d;
        return null;
    }

    pub fn get(s: Schema, name: []const u8) Decl {
        return s.find(name) orelse std.debug.panic("unknown schema type: {s}", .{name});
    }

    /// The handle type tag: the 1-based position of the handle among the
    /// schema's handle declarations. Tags only need to be stable within
    /// one build, because handles are never persisted.
    pub fn handleTag(s: Schema, name: []const u8) u8 {
        var tag: u8 = 0;
        for (s.decls) |d| switch (d) {
            .handle => |h| {
                tag += 1;
                if (std.mem.eql(u8, h.name, name)) return tag;
            },
            else => {},
        };
        std.debug.panic("not a handle: {s}", .{name});
    }

    pub fn isResult(s: Schema, t: Type) bool {
        return t == .ref and std.mem.eql(u8, t.ref, s.result);
    }
};

pub const Decl = union(enum) {
    handle: Handle,
    @"enum": Enum,
    flags: Flags,
    @"struct": Struct,
    callback: Callback,

    pub fn name(d: Decl) []const u8 {
        return switch (d) {
            inline else => |x| x.name,
        };
    }

    pub fn doc(d: Decl) []const u8 {
        return switch (d) {
            inline else => |x| x.doc,
        };
    }

    pub fn since(d: Decl) Version {
        return switch (d) {
            inline else => |x| x.since,
        };
    }
};

pub const Handle = struct {
    name: []const u8,
    doc: []const u8,
    since: Version,
    /// Root objects (the application) own the handle tables of every other
    /// object. Their handles are checked against a process-wide registry.
    root: bool = false,
};

pub const Enum = struct {
    name: []const u8,
    doc: []const u8,
    since: Version,
    /// Prefix of the C constant names. Default: upper-cased name and "_".
    value_prefix: ?[]const u8 = null,
    /// Value 0 must exist: it is what a zeroed field means.
    values: []const EnumValue,
    /// Closed enums (the default) are exactly their values: a value from
    /// the caller that this version does not define is unsupported (D2).
    /// Open enums name some values of a larger set, such as keysyms, and
    /// pass every other value through.
    open: bool = false,
};

pub const EnumValue = struct {
    name: []const u8,
    value: i32,
    doc: []const u8,
    since: ?Version = null,
};

/// A set of bits in a uint32_t. Zero is the default.
pub const Flags = struct {
    name: []const u8,
    doc: []const u8,
    since: Version,
    /// Prefix of the C constant names. Default: the upper-cased name
    /// without its "_flags" suffix, and "_".
    value_prefix: ?[]const u8 = null,
    bits: []const Flag,
};

pub const Flag = struct {
    name: []const u8,
    bit: u5,
    doc: []const u8,
    since: ?Version = null,
};

pub const Struct = struct {
    name: []const u8,
    doc: []const u8,
    since: Version,
    kind: Kind,
    fields: []const Field,

    pub const Kind = enum {
        /// Size-prefixed and extensible; passed by pointer.
        descriptor,
        /// Frozen; may be passed and embedded by value.
        value,
    };
};

pub const Field = struct {
    name: []const u8,
    type: Type,
    doc: []const u8,
    /// Version that appended the field. Default: the struct's.
    since: ?Version = null,
    /// Reserved (D2): an unsigned integer that must be zero, rejected as
    /// unsupported otherwise (and written as zero when siv fills the
    /// struct), so that a later version can give it a meaning. In a
    /// descriptor it fills what would be padding; in a frozen value
    /// struct it is room to grow. Reserved fields come after the others.
    reserved: bool = false,
};

pub const Callback = struct {
    name: []const u8,
    doc: []const u8,
    since: Version,
    /// Parameters after the implicit leading `void *user_data`.
    params: []const Param = &.{},
    ret: Type = .void,
    /// The thread it runs on.
    thread: Thread = .app,
};

pub const Function = struct {
    name: []const u8,
    doc: []const u8,
    since: Version,
    params: []const Param = &.{},
    ret: Type = .void,
    /// For functions returning the result enum: whether ignoring the result
    /// warns. Turn off for teardown functions, where the only error is an
    /// invalid handle.
    must_use: bool = true,
    /// Which threads may call it (D2, D5).
    thread: Thread = .app,
    /// Set when a better function replaces it (D2's deprecation rules):
    /// it keeps working until the next major release.
    deprecated: ?Deprecation = null,
};

pub const Thread = enum {
    /// The thread that created the root (the application's thread); for
    /// callbacks, at a safe point on it (D5).
    app,
    /// Any thread.
    any,
    /// Callbacks only: a worker thread of the root's pool.
    worker,
    /// Callbacks only: siv's compositor thread (D8).
    compositor,
};

pub const Deprecation = struct {
    /// The release that deprecated it.
    since: Version,
    /// The function to use instead, which must exist.
    replacement: []const u8,
};

pub const Param = struct {
    name: []const u8,
    type: Type,
    doc: []const u8,
};

pub const Type = union(enum) {
    void,
    bool,
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    usize,
    /// A declared handle, enum, flags, value struct (by value), or callback.
    ref: []const u8,
    /// Pointer and length, as two C parameters or fields `<name>` and
    /// `<name>_len`. NULL with length 0 is the empty string.
    string,
    /// Return type only: a NUL-terminated string with static lifetime.
    static_string,
    /// `void *`, passed back to callbacks unchanged.
    user_data,
    /// `void *` to memory or to a foreign object, as in the allocator hooks
    /// or a `wl_surface *` handed to an embedder (an out parameter).
    pointer,
    /// A descriptor, by const pointer. NULL means all defaults.
    desc: []const u8,
    /// Parameter only: a pointer the function writes on success. NULL is an
    /// invalid argument.
    out: *const Type,
    /// A caller-owned array, as two C parameters or fields `<name>` (a
    /// const pointer to the elements) and `<name>_count`. NULL with count 0
    /// is empty. Elements are primitives, handles, enums, flags, or value
    /// structs. The library never keeps the caller's pointer.
    array: *const Type,
    /// Function parameter only: memory the function fills, as two C
    /// parameters `char *<name>` and `size_t <name>_cap`. The function
    /// writes at most `<name>_cap` bytes and reports the full length
    /// through an out parameter, so a caller can size a second call.
    buffer,

    pub fn eql(a: Type, b: Type) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .ref => std.mem.eql(u8, a.ref, b.ref),
            .desc => std.mem.eql(u8, a.desc, b.desc),
            .out => a.out.eql(b.out.*),
            .array => a.array.eql(b.array.*),
            else => true,
        };
    }
};

pub fn ref(comptime name: []const u8) Type {
    return .{ .ref = name };
}

pub fn out(comptime t: Type) Type {
    const T = struct {
        const value = t;
    };
    return .{ .out = &T.value };
}

pub fn array(comptime t: Type) Type {
    const T = struct {
        const value = t;
    };
    return .{ .array = &T.value };
}

// Naming. Generators and the runtime derive every name from the schema with
// these functions, so the C header, the Zig wrapper, and the JSON agree.

/// Upper snake case: "siv_item_desc" -> "SIV_ITEM_DESC".
pub fn upper(buf: []u8, s: []const u8) []const u8 {
    for (s, buf[0..s.len]) |c, *b| b.* = std.ascii.toUpper(c);
    return buf[0..s.len];
}

/// The name without its namespace segment: "siv_item_desc" -> "item_desc".
pub fn stem(name: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, name, '_') orelse return name;
    return name[i + 1 ..];
}

/// Zig type name: "siv_item_desc" -> "ItemDesc".
pub fn zigTypeName(buf: []u8, name: []const u8) []const u8 {
    return pascal(buf, stem(name));
}

/// Zig function name: "siv_item_create" -> "itemCreate".
pub fn zigFnName(buf: []u8, name: []const u8) []const u8 {
    const p = pascal(buf, stem(name));
    buf[0] = std.ascii.toLower(buf[0]);
    return p;
}

/// "out_of_memory" -> "OutOfMemory".
pub fn pascal(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var up = true;
    for (s) |c| {
        if (c == '_') {
            up = true;
            continue;
        }
        buf[n] = if (up) std.ascii.toUpper(c) else c;
        up = false;
        n += 1;
    }
    return buf[0..n];
}

pub fn enumValuePrefix(buf: []u8, e: Enum) []const u8 {
    if (e.value_prefix) |p| return p;
    const u = upper(buf, e.name);
    buf[u.len] = '_';
    return buf[0 .. u.len + 1];
}

pub fn flagsValuePrefix(buf: []u8, f: Flags) []const u8 {
    if (f.value_prefix) |p| return p;
    const base = if (std.mem.endsWith(u8, f.name, "_flags")) f.name[0 .. f.name.len - "_flags".len] else f.name;
    const u = upper(buf, base);
    buf[u.len] = '_';
    return buf[0 .. u.len + 1];
}

/// Linker version node of a function: "SIV_0.1". Before 1.0 every minor
/// release may break the ABI, so every symbol carries the current minor
/// version and a binary linked against 0.1 refuses to load 0.2. From 1.0 on,
/// a symbol keeps the node of the release that added it.
pub fn versionNode(buf: []u8, s: Schema, lib: std.SemanticVersion, f: Function) []const u8 {
    var ubuf: [64]u8 = undefined;
    const v: Version = if (lib.major == 0) .{ .major = 0, .minor = @intCast(lib.minor) } else f.since;
    return std.fmt.bufPrint(buf, "{s}_{d}.{d}", .{ upper(&ubuf, s.name), v.major, v.minor }) catch unreachable;
}

// Validation.

pub const Problem = struct {
    where: []const u8,
    what: []const u8,
};

/// Checks the schema conventions. Returns the first problem found. Layout
/// rules that depend on the target (no padding in descriptors) are checked
/// by runtime.zig on the generated Zig types.
pub fn validate(s: Schema, lib: std.SemanticVersion) ?Problem {
    const current: Version = .{ .major = @intCast(lib.major), .minor = @intCast(lib.minor) };
    for (s.decls, 0..) |d, i| {
        const n = d.name();
        if (std.mem.indexOfScalar(u8, n, '_') == null) return .{ .where = n, .what = "type names need a namespace prefix such as siv_" };
        for (s.decls[0..i]) |prev| if (std.mem.eql(u8, prev.name(), n)) return .{ .where = n, .what = "declared twice" };
        if (d.since().order(current) == .gt) return .{ .where = n, .what = "since is newer than the library version" };
        switch (d) {
            .handle => {},
            .@"enum" => |e| {
                var has_zero = false;
                for (e.values, 0..) |v, j| {
                    if (v.value == 0) has_zero = true;
                    for (e.values[0..j]) |w| {
                        if (w.value == v.value) return .{ .where = n, .what = "duplicate enum value" };
                        if (std.mem.eql(u8, w.name, v.name)) return .{ .where = n, .what = "duplicate enum value name" };
                    }
                }
                if (!has_zero) return .{ .where = n, .what = "enums need a value 0, the default" };
                if (std.mem.eql(u8, n, s.result)) {
                    for (e.values) |v| {
                        const is_error = std.mem.startsWith(u8, v.name, "error_");
                        if ((v.value == 0) == is_error) return .{ .where = n, .what = "result value 0 is success and every other value is named error_*" };
                    }
                }
            },
            .flags => |f| for (f.bits, 0..) |b, j| for (f.bits[0..j]) |c| {
                if (c.bit == b.bit) return .{ .where = n, .what = "duplicate flag bit" };
                if (std.mem.eql(u8, c.name, b.name)) return .{ .where = n, .what = "duplicate flag name" };
            },
            .@"struct" => |st| {
                var user_data: usize = 0;
                var callbacks: usize = 0;
                for (st.fields, 0..) |f, j| {
                    if (std.mem.eql(u8, f.name, "size")) return .{ .where = n, .what = "the size field is implicit" };
                    for (st.fields[0..j]) |g| if (std.mem.eql(u8, g.name, f.name)) return .{ .where = n, .what = "duplicate field" };
                    switch (f.type) {
                        .void, .static_string, .out, .buffer => return .{ .where = n, .what = "invalid field type" },
                        .array => |e| if (st.kind == .value) return .{ .where = n, .what = "value structs cannot point to arrays" } else if (checkElement(s, e.*)) |p| return .{ .where = n, .what = p },
                        .user_data => user_data += 1,
                        .desc => |dn| if (st.kind == .value) return .{ .where = n, .what = "value structs cannot point to descriptors" } else if (checkKind(s, dn, .desc)) |p| return p,
                        .ref => |rn| {
                            const r = s.find(rn) orelse return .{ .where = n, .what = "unknown field type" };
                            switch (r) {
                                .callback => callbacks += 1,
                                .@"struct" => |rs| if (rs.kind == .descriptor) return .{ .where = n, .what = "descriptors are referenced by pointer (Type.desc), never embedded" },
                                else => {},
                            }
                        },
                        else => {},
                    }
                    if (f.since) |v| if (v.order(st.since) == .lt or v.order(current) == .gt) return .{ .where = n, .what = "field since outside the struct's lifetime" };
                    if (f.reserved) {
                        // Descriptors fill what would be padding with
                        // them; value structs, which never grow, keep room
                        // for fields to come (D2).
                        switch (f.type) {
                            .u8, .u16, .u32, .u64 => {},
                            else => return .{ .where = n, .what = "reserved fields are unsigned integers" },
                        }
                    } else if (st.kind == .value and j > 0 and st.fields[j - 1].reserved) {
                        return .{ .where = n, .what = "a value struct's reserved fields come last" };
                    }
                }
                if (callbacks > 0 and user_data != 1) return .{ .where = n, .what = "a struct with callbacks has exactly one user_data field" };
                if (callbacks == 0 and user_data > 0) return .{ .where = n, .what = "user_data without callbacks" };
                if (st.kind == .value and user_data > 0) return .{ .where = n, .what = "value structs cannot hold callbacks" };
            },
            .callback => |cb| {
                if (checkParams(s, n, cb.params, false)) |p| return p;
                if (checkRet(s, n, cb.ret)) |p| return p;
                if (cb.ret == .static_string) return .{ .where = n, .what = "callbacks cannot return strings" };
            },
        }
    }
    for (s.functions, 0..) |f, i| {
        if (!std.mem.startsWith(u8, f.name, s.prefix)) return .{ .where = f.name, .what = "function name lacks the schema prefix" };
        for (s.functions[0..i]) |g| if (std.mem.eql(u8, g.name, f.name)) return .{ .where = f.name, .what = "declared twice" };
        if (f.since.order(current) == .gt) return .{ .where = f.name, .what = "since is newer than the library version" };
        if (checkParams(s, f.name, f.params, true)) |p| return p;
        if (checkRet(s, f.name, f.ret)) |p| return p;
        switch (f.thread) {
            .app, .any => {},
            .worker, .compositor => return .{ .where = f.name, .what = "functions are called on the application's thread or any thread" },
        }
        if (f.deprecated) |d| {
            if (d.since.order(f.since) == .lt or d.since.order(current) == .gt) return .{ .where = f.name, .what = "deprecated outside the function's lifetime" };
            if (std.mem.eql(u8, d.replacement, f.name)) return .{ .where = f.name, .what = "a deprecated function replaces itself" };
            for (s.functions) |g| {
                if (!std.mem.eql(u8, g.name, d.replacement)) continue;
                if (g.deprecated != null) return .{ .where = f.name, .what = "a deprecated function's replacement is deprecated" };
                break;
            } else return .{ .where = f.name, .what = "a deprecated function's replacement does not exist" };
        }
        var seen_out = false;
        for (f.params) |p| {
            if (p.type == .out) {
                seen_out = true;
                if (!s.isResult(f.ret)) return .{ .where = f.name, .what = "functions with out parameters return the result enum" };
            } else if (seen_out) return .{ .where = f.name, .what = "out parameters come last" };
        }
    }
    return null;
}

fn checkParams(s: Schema, where: []const u8, params: []const Param, allow_out: bool) ?Problem {
    for (params, 0..) |p, j| {
        if (std.mem.eql(u8, p.name, "user_data") != (p.type == .user_data)) return .{ .where = where, .what = "the user_data parameter is named user_data" };
        for (params[0..j]) |q| if (std.mem.eql(u8, q.name, p.name)) return .{ .where = where, .what = "duplicate parameter" };
        switch (p.type) {
            .void, .static_string => return .{ .where = where, .what = "invalid parameter type" },
            .buffer => if (!allow_out) return .{ .where = where, .what = "callbacks have no buffer parameters" },
            .array => |e| if (checkElement(s, e.*)) |what| return .{ .where = where, .what = what },
            .out => |o| {
                if (!allow_out) return .{ .where = where, .what = "callbacks have no out parameters" };
                switch (o.*) {
                    .void, .static_string, .out, .desc, .string, .user_data, .array, .buffer => return .{ .where = where, .what = "invalid out parameter type" },
                    .ref => |rn| if (checkKind(s, rn, .any)) |pr| return pr,
                    else => {},
                }
            },
            .desc => |dn| if (checkKind(s, dn, .desc)) |pr| return pr,
            .ref => |rn| {
                const d = s.find(rn) orelse return .{ .where = where, .what = "unknown parameter type" };
                if (d == .@"struct" and d.@"struct".kind == .descriptor) return .{ .where = where, .what = "descriptors are passed by pointer (Type.desc)" };
                if (d == .callback) {
                    if (!allow_out) return .{ .where = where, .what = "callbacks cannot take callbacks" };
                    // A run of callbacks (a callback and its destroy-notify)
                    // shares the user_data that follows it.
                    var k = j + 1;
                    while (k < params.len and isCallback(s, params[k].type)) k += 1;
                    if (k >= params.len or params[k].type != .user_data) return .{ .where = where, .what = "a callback parameter is followed by user_data" };
                }
            },
            .user_data => if (allow_out and (j == 0 or !isCallback(s, params[j - 1].type))) return .{ .where = where, .what = "user_data follows a callback parameter" },
            else => {},
        }
    }
    return null;
}

/// Array elements are single C values that need no ownership rules.
fn checkElement(s: Schema, t: Type) ?[]const u8 {
    return switch (t) {
        .bool, .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f32, .f64, .usize => null,
        .ref => |rn| if (s.find(rn)) |d| switch (d) {
            .handle, .@"enum", .flags => null,
            .@"struct" => |st| if (st.kind == .value) null else "array elements cannot be descriptors",
            .callback => "array elements cannot be callbacks",
        } else "unknown array element type",
        else => "invalid array element type",
    };
}

fn checkRet(s: Schema, where: []const u8, t: Type) ?Problem {
    return switch (t) {
        .string, .desc, .out, .user_data, .array, .buffer => .{ .where = where, .what = "invalid return type" },
        .pointer => if (s.find(where)) |_| null else .{ .where = where, .what = "only callbacks return pointers" },
        .ref => |rn| if (s.find(rn)) |d| switch (d) {
            .handle, .@"enum", .flags => null,
            .@"struct" => |st| if (st.kind == .value) null else .{ .where = where, .what = "descriptors cannot be returned" },
            .callback => .{ .where = where, .what = "callbacks cannot be returned" },
        } else .{ .where = where, .what = "unknown return type" },
        else => null,
    };
}

fn isCallback(s: Schema, t: Type) bool {
    if (t != .ref) return false;
    const d = s.find(t.ref) orelse return false;
    return d == .callback;
}

fn checkKind(s: Schema, name: []const u8, comptime kind: enum { desc, any }) ?Problem {
    const d = s.find(name) orelse return .{ .where = name, .what = "unknown type" };
    if (kind == .desc and !(d == .@"struct" and d.@"struct".kind == .descriptor)) return .{ .where = name, .what = "not a descriptor" };
    return null;
}

test "naming" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ItemDesc", zigTypeName(&buf, "siv_item_desc"));
    try std.testing.expectEqualStrings("itemCreate", zigFnName(&buf, "sivtest_item_create"));
    try std.testing.expectEqualStrings("SIV_RESULT", upper(&buf, "siv_result"));
    try std.testing.expectEqualStrings("SIVTEST_ITEM_", flagsValuePrefix(&buf, .{ .name = "sivtest_item_flags", .doc = "", .since = .{ .major = 0, .minor = 1 }, .bits = &.{} }));
}

test "validate rejects convention violations" {
    const v01: Version = .{ .major = 0, .minor = 1 };
    const lib: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };
    const result: Decl = .{ .@"enum" = .{ .name = "x_result", .doc = "", .since = v01, .values = &.{
        .{ .name = "ok", .value = 0, .doc = "" },
        .{ .name = "error_bad", .value = -1, .doc = "" },
    } } };
    const cb: Decl = .{ .callback = .{ .name = "x_fn", .doc = "", .since = v01 } };
    const base: Schema = .{ .name = "x", .prefix = "x_", .source = "", .doc = "", .result = "x_result", .decls = &.{ result, cb }, .functions = &.{} };
    try std.testing.expectEqual(null, validate(base, lib));

    var s = base;
    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .params = &.{
        .{ .name = "callback", .type = ref("x_fn"), .doc = "" },
    } }};
    try std.testing.expectEqualStrings("a callback parameter is followed by user_data", validate(s, lib).?.what);

    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .params = &.{
        .{ .name = "n", .type = out(.u32), .doc = "" },
    } }};
    try std.testing.expectEqualStrings("functions with out parameters return the result enum", validate(s, lib).?.what);

    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .ret = ref("x_result"), .params = &.{
        .{ .name = "n", .type = out(.u32), .doc = "" },
        .{ .name = "m", .type = .u32, .doc = "" },
    } }};
    try std.testing.expectEqualStrings("out parameters come last", validate(s, lib).?.what);

    s.functions = &.{.{ .name = "y_f", .doc = "", .since = v01 }};
    try std.testing.expectEqualStrings("function name lacks the schema prefix", validate(s, lib).?.what);

    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .deprecated = .{ .since = v01, .replacement = "x_g" } }};
    try std.testing.expectEqualStrings("a deprecated function's replacement does not exist", validate(s, lib).?.what);
    s.functions = &.{ .{ .name = "x_f", .doc = "", .since = v01, .deprecated = .{ .since = v01, .replacement = "x_g" } }, .{ .name = "x_g", .doc = "", .since = v01 } };
    try std.testing.expectEqual(null, validate(s, lib));
    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .deprecated = .{ .since = .{ .major = 0, .minor = 2 }, .replacement = "x_f" } }};
    try std.testing.expectEqualStrings("deprecated outside the function's lifetime", validate(s, lib).?.what);
    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .thread = .worker }};
    try std.testing.expectEqualStrings("functions are called on the application's thread or any thread", validate(s, lib).?.what);

    s = base;
    s.decls = &.{ result, cb, .{ .@"struct" = .{ .name = "x_desc", .doc = "", .since = v01, .kind = .descriptor, .fields = &.{
        .{ .name = "callback", .type = ref("x_fn"), .doc = "" },
    } } } };
    try std.testing.expectEqualStrings("a struct with callbacks has exactly one user_data field", validate(s, lib).?.what);

    s.decls = &.{ result, .{ .@"enum" = .{ .name = "x_mode", .doc = "", .since = v01, .values = &.{.{ .name = "a", .value = 1, .doc = "" }} } } };
    try std.testing.expectEqualStrings("enums need a value 0, the default", validate(s, lib).?.what);

    // A callback and its destroy-notify share one user_data.
    s = base;
    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .params = &.{
        .{ .name = "callback", .type = ref("x_fn"), .doc = "" },
        .{ .name = "destroy", .type = ref("x_fn"), .doc = "" },
        .{ .name = "user_data", .type = .user_data, .doc = "" },
    } }};
    try std.testing.expectEqual(null, validate(s, lib));
    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .params = &.{
        .{ .name = "callback", .type = ref("x_fn"), .doc = "" },
        .{ .name = "destroy", .type = ref("x_fn"), .doc = "" },
    } }};
    try std.testing.expectEqualStrings("a callback parameter is followed by user_data", validate(s, lib).?.what);

    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .params = &.{
        .{ .name = "items", .type = array(.string), .doc = "" },
    } }};
    try std.testing.expectEqualStrings("invalid array element type", validate(s, lib).?.what);
    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .ret = .string }};
    try std.testing.expectEqualStrings("invalid return type", validate(s, lib).?.what);
    s.functions = &.{.{ .name = "x_f", .doc = "", .since = v01, .ret = ref("x_result"), .params = &.{
        .{ .name = "buf", .type = .buffer, .doc = "" },
        .{ .name = "len", .type = out(.usize), .doc = "" },
    } }};
    try std.testing.expectEqual(null, validate(s, lib));
}
