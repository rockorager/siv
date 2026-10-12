//! Compositors that `zig build test-compositor` runs the platform's
//! compositor tests (compositor_tests.zig) against, each on its headless
//! backend. build.zig imports this file, so it must only use plain data.
//! Owned by the platform workstream: add a compositor with one entry here
//! and its package in .agents/compositors.nix.
//!
//! Tests that need a capability the compositor lacks skip; tests that
//! script the compositor (IPC, virtual input) name the compositor they need.

pub const Entry = struct {
    /// Step name (test-compositor-<name>) and the name tests check.
    name: []const u8,
    /// Command line, run from $PATH. "{dir}" is a private XDG_RUNTIME_DIR in
    /// which the compositor must create the socket "wayland-1".
    argv: []const []const u8,
    /// Written to {dir}/config before launch, if set.
    config: ?[]const u8 = null,
};

pub const matrix = [_]Entry{
    .{
        .name = "sway",
        .argv = &.{ "sway", "-c", "{dir}/config" },
        .config =
        \\output HEADLESS-1 mode 1280x720@60Hz position 0 0
        \\default_border none
        \\
        ,
    },
};
