//! The siv API schema (D3): every type and function of libsiv's C ABI.
//! See schema.zig for the format and conventions. Each function listed here
//! is exported by abi.zig with the signature the schema implies.
//!
//! Subsystem functions (application, windows, the retained tree) are added
//! here as their implementations land.

const schema = @import("schema.zig");
const ref = schema.ref;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

pub const result: schema.Decl = .{ .@"enum" = .{
    .name = "siv_result",
    .doc = "Result of a fallible call. Every function that can fail returns it; outputs are written only on SIV_OK.",
    .since = v0_1,
    .value_prefix = "SIV_",
    .values = &.{
        .{ .name = "ok", .value = 0, .doc = "Success." },
        .{ .name = "error_out_of_memory", .value = -1, .doc = "An allocation failed. The call had no effect." },
        .{ .name = "error_invalid_handle", .value = -2, .doc = "A handle is null, was destroyed, belongs to a destroyed root, or has the wrong type." },
        .{ .name = "error_invalid_argument", .value = -3, .doc = "An argument breaks the call's contract: a NULL out pointer, a malformed descriptor size, a NULL string with a nonzero length." },
        .{ .name = "error_unsupported", .value = -4, .doc = "The caller asked for something this version of the library does not know: an unknown enum value or flag bit, or nonzero descriptor fields past the end this version knows." },
        .{ .name = "error_limit_exceeded", .value = -5, .doc = "A fixed limit was reached, such as the number of live objects per root or roots per process." },
    },
} };

pub const alloc_fn: schema.Decl = .{ .callback = .{
    .name = "siv_alloc_fn",
    .doc = "Allocates size bytes aligned to alignment (a power of two). Returns NULL on failure.",
    .since = v0_1,
    .params = &.{
        .{ .name = "size", .type = .usize, .doc = "Bytes to allocate; never 0." },
        .{ .name = "alignment", .type = .usize, .doc = "Required alignment in bytes." },
    },
    .ret = .pointer,
} };

pub const free_fn: schema.Decl = .{ .callback = .{
    .name = "siv_free_fn",
    .doc = "Frees memory returned by the matching siv_alloc_fn. size and alignment are the values it was allocated with.",
    .since = v0_1,
    .params = &.{
        .{ .name = "ptr", .type = .pointer, .doc = "Memory to free; never NULL." },
        .{ .name = "size", .type = .usize, .doc = "Size passed to the allocation." },
        .{ .name = "alignment", .type = .usize, .doc = "Alignment passed to the allocation." },
    },
} };

pub const allocator: schema.Decl = .{ .@"struct" = .{
    .name = "siv_allocator",
    .doc = "Allocator hooks for a root object and everything it owns. Set both functions or neither; with neither, siv uses the C library allocator. The struct is copied; user_data must stay valid until the root is destroyed.",
    .since = v0_1,
    .kind = .descriptor,
    .fields = &.{
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to alloc and free." },
        .{ .name = "alloc", .type = ref("siv_alloc_fn"), .doc = "Allocation hook." },
        .{ .name = "free", .type = ref("siv_free_fn"), .doc = "Deallocation hook." },
    },
} };

pub const spec: schema.Schema = .{
    .name = "siv",
    .prefix = "siv_",
    .source = "src/abi/api.zig",
    .doc = "siv: a GUI toolkit for Wayland.",
    .result = "siv_result",
    .decls = &.{ result, alloc_fn, free_fn, allocator },
    .functions = &.{
        .{
            .name = "siv_version",
            .doc = "Returns the version of the loaded library, encoded as SIV_MAKE_VERSION(major, minor, patch).",
            .since = v0_1,
            .ret = .u32,
        },
        .{
            .name = "siv_result_name",
            .doc = "Returns the name of a result code, such as \"SIV_ERROR_OUT_OF_MEMORY\", or \"SIV_RESULT_UNKNOWN\" for a value this version does not define.",
            .since = v0_1,
            .params = &.{.{ .name = "result", .type = ref("siv_result"), .doc = "Any value." }},
            .ret = .static_string,
        },
    },
};

/// Encodes a version as (major << 16) | (minor << 8) | patch.
pub fn makeVersion(major: usize, minor: usize, patch: usize) u32 {
    return @intCast(major << 16 | minor << 8 | patch);
}
