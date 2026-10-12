//! Where a window's layer updates go. A window commits `compositor.Op`
//! batches through a `Sink`; the application connects it to
//! `compositor.Compositor.commit` for the window and feeds the events that
//! come back (`compositor.Event`) to `Window.handleEvent`.

const compositor = @import("compositor");

pub const Sink = struct {
    ctx: ?*anyopaque,
    /// Commits a batch of ops atomically and returns its sequence number.
    /// The ops refer to builders the receiver now owns until it releases
    /// them; on error nothing was applied.
    commit: *const fn (ctx: ?*anyopaque, ops: []const compositor.Op) error{OutOfMemory}!u64,
};
