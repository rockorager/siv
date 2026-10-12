//! Per-surface frame clock (D12). It decides when a surface may produce a
//! frame and predicts when that frame will be presented. Backends feed it
//! frame callbacks and presentation feedback; the state machine itself is
//! independent of Wayland so that the headless backend shares it.
//!
//! A frame runs when the surface is configured and either a configure must
//! be answered, or the application wants a frame and no frame callback is
//! outstanding. Suspended surfaces produce no frames except to answer a
//! configure; occluded surfaces never get their frame callback, so they stop
//! producing frames on their own.

const std = @import("std");
const FrameClock = @This();

configured: bool = false,
suspended: bool = false,
/// The application asked for a frame.
wanted: bool = false,
/// A configure must be answered with a commit, regardless of callbacks.
forced: bool = false,
/// A frame callback is outstanding: the compositor has not asked for the
/// next frame yet.
waiting: bool = false,
refresh_ns: u64 = default_refresh_ns,
/// CLOCK_MONOTONIC time of the most recent presentation, if known.
last_present_ns: ?u64 = null,

pub const default_refresh_ns: u64 = 16_666_667;

/// When to render a frame for and how long frames last.
pub const Time = struct {
    /// Predicted CLOCK_MONOTONIC presentation time of the frame. Animations
    /// sample at this time.
    present_ns: u64,
    interval_ns: u64,
};

pub fn request(c: *FrameClock) void {
    c.wanted = true;
}

pub fn force(c: *FrameClock) void {
    c.forced = true;
}

pub fn ready(c: *const FrameClock) bool {
    if (!c.configured) return false;
    if (c.forced) return true;
    return c.wanted and !c.waiting and !c.suspended;
}

/// Starts a frame. Call only when `ready`.
pub fn begin(c: *FrameClock, now_ns: u64) Time {
    std.debug.assert(c.ready());
    c.wanted = false;
    c.forced = false;
    return .{ .present_ns = c.predict(now_ns), .interval_ns = c.refresh_ns };
}

/// The frame was committed with a frame callback.
pub fn committed(c: *FrameClock) void {
    c.waiting = true;
}

/// The frame callback fired: the compositor wants the next frame.
pub fn done(c: *FrameClock) void {
    c.waiting = false;
}

/// Presentation feedback for a committed frame. `refresh_ns` of 0 means
/// unknown (variable refresh) and keeps the current estimate.
pub fn presented(c: *FrameClock, time_ns: u64, refresh_ns: u64) void {
    if (c.last_present_ns) |last| if (time_ns < last) return; // out of order
    c.last_present_ns = time_ns;
    if (refresh_ns != 0) c.refresh_ns = refresh_ns;
}

/// The next presentation time after `now_ns`: the first refresh cycle after
/// the last presentation that is still in the future.
pub fn predict(c: *const FrameClock, now_ns: u64) u64 {
    const last = c.last_present_ns orelse return now_ns + c.refresh_ns;
    if (last > now_ns) return last;
    const cycles = (now_ns - last) / c.refresh_ns + 1;
    return last + cycles * c.refresh_ns;
}

const testing = std.testing;

test "frames wait for the frame callback unless a configure forces one" {
    var c: FrameClock = .{};
    c.request();
    try testing.expect(!c.ready()); // not configured yet
    c.configured = true;
    try testing.expect(c.ready());
    _ = c.begin(0);
    c.committed();
    try testing.expect(!c.ready()); // nothing wanted

    c.request();
    try testing.expect(!c.ready()); // callback outstanding
    c.force();
    try testing.expect(c.ready()); // configure overrides the callback
    _ = c.begin(0);
    try testing.expect(!c.ready());
    c.request();
    c.done();
    try testing.expect(c.ready());
}

test "suspended surfaces only answer configures" {
    var c: FrameClock = .{ .configured = true, .suspended = true };
    c.request();
    try testing.expect(!c.ready());
    c.force();
    try testing.expect(c.ready());
    _ = c.begin(0);
    c.request();
    try testing.expect(!c.ready());
    c.suspended = false;
    try testing.expect(c.ready());
}

test "prediction follows presentation feedback" {
    var c: FrameClock = .{ .configured = true };
    try testing.expectEqual(@as(u64, 1000 + default_refresh_ns), c.predict(1000));

    c.presented(10_000_000, 8_000_000); // 125 Hz
    // Just after a presentation the next vblank is one cycle later.
    try testing.expectEqual(@as(u64, 18_000_000), c.predict(10_000_001));
    // Exactly on a vblank, the frame can only make the following one.
    try testing.expectEqual(@as(u64, 26_000_000), c.predict(18_000_000));
    try testing.expectEqual(@as(u64, 34_000_000), c.predict(27_000_000));
    // Stale feedback is ignored; unknown refresh keeps the estimate.
    c.presented(9_000_000, 1);
    c.presented(12_000_000, 0);
    try testing.expectEqual(@as(u64, 8_000_000), c.refresh_ns);
    c.request();
    try testing.expectEqual(@as(u64, 20_000_000), c.begin(13_000_000).present_ns);
}
