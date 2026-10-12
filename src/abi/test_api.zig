//! Schema of libsiv-abitest, a test-only shared library that exercises every
//! ABI convention through the same generators, runtime, and link setup as
//! libsiv (test/c/abi.c, abi_test.zig). It is never installed.
//!
//! A context is a root object with allocator hooks; items are objects it
//! owns. The API is deliberately small but uses each schema construct.

const schema = @import("schema.zig");
const api = @import("api.zig");
const ref = schema.ref;
const out = schema.out;
const array = schema.array;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

pub const spec: schema.Schema = .{
    .name = "sivtest",
    .prefix = "sivtest_",
    .source = "src/abi/test_api.zig",
    .doc = "Test library for the siv ABI conventions.",
    .result = "siv_result",
    .decls = &.{
        api.result,
        api.alloc_fn,
        api.free_fn,
        api.allocator,
        .{ .handle = .{ .name = "sivtest_context", .doc = "Root object owning items.", .since = v0_1, .root = true } },
        .{ .handle = .{ .name = "sivtest_item", .doc = "An item in a context.", .since = v0_1 } },
        .{ .@"enum" = .{ .name = "sivtest_shape", .doc = "Shape of an item.", .since = v0_1, .values = &.{
            .{ .name = "square", .value = 0, .doc = "The default." },
            .{ .name = "circle", .value = 1, .doc = "Round." },
            .{ .name = "star", .value = 7, .doc = "A sparse value." },
        } } },
        .{ .flags = .{ .name = "sivtest_item_flags", .doc = "Item options.", .since = v0_1, .bits = &.{
            .{ .name = "hidden", .bit = 0, .doc = "Skipped by sivtest_context_visit." },
            .{ .name = "pinned", .bit = 3, .doc = "A sparse bit." },
        } } },
        .{ .@"struct" = .{ .name = "sivtest_point", .doc = "A frozen value struct.", .since = v0_1, .kind = .value, .fields = &.{
            .{ .name = "x", .type = .f32, .doc = "Horizontal." },
            .{ .name = "y", .type = .f32, .doc = "Vertical." },
        } } },
        .{ .@"struct" = .{ .name = "sivtest_context_desc", .doc = "Context options.", .since = v0_1, .kind = .descriptor, .fields = &.{
            .{ .name = "allocator", .type = .{ .desc = "siv_allocator" }, .doc = "Allocator hooks; NULL for the C library allocator." },
        } } },
        .{
            .@"struct" = .{
                .name = "sivtest_item_desc",
                .doc = "Item options.",
                .since = v0_1,
                .kind = .descriptor,
                .fields = &.{
                    .{ .name = "name", .type = .string, .doc = "Copied; embedded NUL allowed." },
                    .{ .name = "shape", .type = ref("sivtest_shape"), .doc = "Default square." },
                    .{ .name = "flags", .type = ref("sivtest_item_flags"), .doc = "Default none." },
                    .{ .name = "origin", .type = ref("sivtest_point"), .doc = "Embedded value struct." },
                    // Appended later: callers built against the older, shorter
                    // struct get the default.
                    .{ .name = "weight", .type = .i64, .doc = "Zero means 1.", .since = v0_1 },
                    .{ .name = "tags", .type = array(.u32), .doc = "Copied.", .since = v0_1 },
                },
            },
        },
        .{ .@"struct" = .{ .name = "sivtest_item_info", .doc = "What sivtest_item_get reports.", .since = v0_1, .kind = .value, .fields = &.{
            .{ .name = "shape", .type = ref("sivtest_shape"), .doc = "Resolved shape." },
            .{ .name = "flags", .type = ref("sivtest_item_flags"), .doc = "Flags." },
            .{ .name = "origin", .type = ref("sivtest_point"), .doc = "Origin." },
            .{ .name = "weight", .type = .i64, .doc = "Resolved weight." },
            .{ .name = "name_len", .type = .usize, .doc = "Length of the name." },
        } } },
        .{ .callback = .{ .name = "sivtest_visit_fn", .doc = "Called for each visible item, in creation order.", .since = v0_1, .params = &.{
            .{ .name = "item", .type = ref("sivtest_item"), .doc = "The item." },
            .{ .name = "name", .type = .string, .doc = "Its name, valid during the call." },
        }, .ret = .bool } },
        .{ .callback = .{ .name = "sivtest_hook_fn", .doc = "A context's hook.", .since = v0_1 } },
        .{ .callback = .{ .name = "sivtest_destroy_fn", .doc = "Releases a hook's user_data.", .since = v0_1 } },
    },
    .functions = &.{
        .{ .name = "sivtest_context_create", .doc = "Creates a context.", .since = v0_1, .ret = ref("siv_result"), .params = &.{
            .{ .name = "desc", .type = .{ .desc = "sivtest_context_desc" }, .doc = "Options; NULL for defaults." },
            .{ .name = "context", .type = out(ref("sivtest_context")), .doc = "The new context." },
        } },
        .{ .name = "sivtest_context_destroy", .doc = "Destroys a context and every item in it.", .since = v0_1, .ret = ref("siv_result"), .must_use = false, .params = &.{
            .{ .name = "context", .type = ref("sivtest_context"), .doc = "The context." },
        } },
        .{ .name = "sivtest_item_create", .doc = "Creates an item.", .since = v0_1, .ret = ref("siv_result"), .params = &.{
            .{ .name = "context", .type = ref("sivtest_context"), .doc = "Owner." },
            .{ .name = "desc", .type = .{ .desc = "sivtest_item_desc" }, .doc = "Options; NULL for defaults." },
            .{ .name = "item", .type = out(ref("sivtest_item")), .doc = "The new item." },
        } },
        .{ .name = "sivtest_item_destroy", .doc = "Destroys an item.", .since = v0_1, .ret = ref("siv_result"), .must_use = false, .params = &.{
            .{ .name = "item", .type = ref("sivtest_item"), .doc = "The item." },
        } },
        .{ .name = "sivtest_item_get", .doc = "Reports an item's state.", .since = v0_1, .ret = ref("siv_result"), .params = &.{
            .{ .name = "item", .type = ref("sivtest_item"), .doc = "The item." },
            .{ .name = "info", .type = out(ref("sivtest_item_info")), .doc = "Its state." },
        } },
        .{ .name = "sivtest_item_set_name", .doc = "Replaces an item's name.", .since = v0_1, .ret = ref("siv_result"), .params = &.{
            .{ .name = "item", .type = ref("sivtest_item"), .doc = "The item." },
            .{ .name = "name", .type = .string, .doc = "Copied; embedded NUL allowed." },
        } },
        .{ .name = "sivtest_context_visit", .doc = "Calls callback for each visible item until it returns false.", .since = v0_1, .ret = ref("siv_result"), .params = &.{
            .{ .name = "context", .type = ref("sivtest_context"), .doc = "The context." },
            .{ .name = "callback", .type = ref("sivtest_visit_fn"), .doc = "Called once per item." },
            .{ .name = "user_data", .type = .user_data, .doc = "Passed to callback." },
            .{ .name = "visited", .type = out(.u32), .doc = "How many items callback saw." },
        } },
        .{ .name = "sivtest_item_get_name", .doc = "Copies an item's name.", .since = v0_1, .ret = ref("siv_result"), .params = &.{
            .{ .name = "item", .type = ref("sivtest_item"), .doc = "The item." },
            .{ .name = "name", .type = .buffer, .doc = "Receives at most name_cap bytes." },
            .{ .name = "len", .type = out(.usize), .doc = "The full length of the name." },
        } },
        .{ .name = "sivtest_item_tag_sum", .doc = "Sums an item's tags.", .since = v0_1, .ret = ref("siv_result"), .params = &.{
            .{ .name = "item", .type = ref("sivtest_item"), .doc = "The item." },
            .{ .name = "sum", .type = out(.u64), .doc = "The sum." },
        } },
        .{ .name = "sivtest_context_set_hook", .doc = "Replaces the context's hook. The previous hook's destroy runs; so does this one's when it is replaced or the context is destroyed.", .since = v0_1, .ret = ref("siv_result"), .params = &.{
            .{ .name = "context", .type = ref("sivtest_context"), .doc = "The context." },
            .{ .name = "hook", .type = ref("sivtest_hook_fn"), .doc = "The hook; NULL clears it." },
            .{ .name = "destroy", .type = ref("sivtest_destroy_fn"), .doc = "Releases user_data; may be NULL." },
            .{ .name = "user_data", .type = .user_data, .doc = "Passed to hook and destroy." },
        } },
        .{ .name = "sivtest_context_run_hook", .doc = "Calls the context's hook, if any.", .since = v0_1, .ret = ref("siv_result"), .params = &.{
            .{ .name = "context", .type = ref("sivtest_context"), .doc = "The context." },
        } },
        .{ .name = "sivtest_context_item_count", .doc = "Number of live items; 0 for an invalid handle.", .since = v0_1, .ret = .u32, .params = &.{
            .{ .name = "context", .type = ref("sivtest_context"), .doc = "The context." },
        } },
    },
};
