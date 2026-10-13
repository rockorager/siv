//! Headless integration tests (D20, D24): run the real event loop on the
//! headless platform backend and compare CPU renderer output with golden
//! images. Unlike module tests, these may import every internal module.
//!
//! Add tests here, or in files under test/ referenced from this file.

const std = @import("std");
const abi = @import("abi");
const loop = @import("loop");
const platform = @import("platform");
const render_cpu = @import("render_cpu");
const scene = @import("scene");
const text = @import("text");

// test/c/canvas_scene.c, linked into this binary, calls the exports, so
// they must be emitted even when a test filter skips every test that
// uses them.
comptime {
    _ = abi;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("render/golden.zig");
    _ = @import("render/vulkan.zig");
    _ = @import("ui/golden.zig");
    _ = @import("ui/dnd.zig");
    _ = @import("ui/cursor.zig");
    _ = @import("ui/image.zig");
    _ = @import("compositor/golden.zig");
    _ = @import("compositor/latency.zig");
    _ = @import("abi/golden.zig");
    _ = @import("abi/canvas.zig");
    _ = @import("abi/external.zig");
    _ = @import("abi/dnd.zig");
    _ = @import("abi/clipboard.zig");
    _ = @import("abi/teardown.zig");
    _ = @import("abi/primitives.zig");
    _ = @import("widgets/widgets.zig");
    _ = @import("abi/cursor.zig");
    _ = @import("abi/portal.zig");
    _ = @import("widgets/popups.zig");
    _ = @import("widgets/views.zig");
    _ = @import("widgets/icons.zig");
    _ = @import("abi/print.zig");
    _ = @import("abi/image.zig");
    _ = @import("abi/fonts.zig");
    _ = @import("abi/rich_text.zig");
    _ = @import("abi/input.zig");
    _ = @import("lua/lua.zig");
}
