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

test {
    std.testing.refAllDecls(@This());
    _ = @import("render/golden.zig");
}
