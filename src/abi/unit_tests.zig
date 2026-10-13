//! The abi module's unit tests that need nothing of siv: the schema and
//! its generators, handles, descriptors, and allocation hooks (D2, D3).
//! The exports are tested through the C API in the headless test binary
//! (test/abi), and their layout against the headers by wrapper_test.zig.

test {
    _ = @import("gen.zig");
    _ = @import("schema.zig");
    _ = @import("handles.zig");
    _ = @import("runtime.zig");
    _ = @import("alloc.zig");
}
