//! libsiv root module. It only references the ABI so that its exports are
//! emitted; subsystems are reached through their own modules (see
//! build.zig and AGENTS.md).

comptime {
    _ = @import("abi");
}
