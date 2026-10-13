//! libsiv root module. It only references the ABI so that its exports are
//! emitted; subsystems are reached through their own modules (see
//! build.zig and AGENTS.md).

const std = @import("std");

/// A library installs no crash handler, so it keeps no per-thread
/// alternative signal stack: Zig's default is 256 KiB of thread-local
/// storage, which every thread of the host process then carries, and
/// which makes threads created with stacks under about 512 KiB fail to
/// start (EINVAL) in any program that loads libsiv.so.
pub const std_options: std.Options = .{ .signal_stack_size = null };

comptime {
    _ = @import("abi");
}
