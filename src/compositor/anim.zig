//! Animation sampling: timing curves, property animations, and kinetic
//! scrolling. Everything is a pure function of the sample time, so frames
//! land where the frame clock predicts them (D12) however late they run.

const std = @import("std");
const update = @import("update.zig");
const Point = update.Point;
const Easing = update.Easing;
const Value = update.Value;
const Animation = update.Animation;

/// The timing curve at progress `x` in [0, 1].
pub fn ease(e: Easing, x: f32) f32 {
    return switch (e) {
        .linear => x,
        .cubic_bezier => |c| cubicBezier(c[0], c[1], c[2], c[3], x),
    };
}

/// y at the parameter where the curve's x is `x`. The curve runs from
/// (0, 0) to (1, 1) with control points (x1, y1) and (x2, y2); x1 and x2
/// in [0, 1] make x monotonic in the parameter.
fn cubicBezier(x1: f32, y1: f32, x2: f32, y2: f32, x: f32) f32 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    const bez = struct {
        fn at(p1: f32, p2: f32, t: f32) f32 {
            const u = 1 - t;
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t;
        }
        fn slope(p1: f32, p2: f32, t: f32) f32 {
            const u = 1 - t;
            return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2);
        }
    };
    // Newton's method from a linear guess, falling back to bisection.
    var t = x;
    for (0..8) |_| {
        const err = bez.at(x1, x2, t) - x;
        if (@abs(err) < 1e-6) return bez.at(y1, y2, t);
        const d = bez.slope(x1, x2, t);
        if (@abs(d) < 1e-6) break;
        t = std.math.clamp(t - err / d, 0, 1);
    }
    var lo: f32 = 0;
    var hi: f32 = 1;
    t = x;
    for (0..32) |_| {
        const v = bez.at(x1, x2, t);
        if (@abs(v - x) < 1e-6) break;
        if (v < x) lo = t else hi = t;
        t = (lo + hi) / 2;
    }
    return bez.at(y1, y2, t);
}

pub fn lerp(a: Value, b: Value, t: f32) Value {
    return switch (b) {
        .transform => |bt| .{ .transform = a.transform.lerp(bt, t) },
        .opacity => |bo| .{ .opacity = a.opacity + (bo - a.opacity) * t },
        .scroll => |bs| .{ .scroll = a.scroll.lerp(bs, t) },
    };
}

pub const Sample = struct {
    value: Value,
    done: bool,
};

/// A property animation in progress. `start_ns` and `from` resolve at the
/// first sample after the start.
pub const Running = struct {
    anim: Animation,
    from: ?Value,
    start_ns: u64,

    pub fn init(a: Animation) Running {
        return .{ .anim = a, .from = a.from, .start_ns = a.start_ns };
    }

    /// The value at `t_ns`, given the value shown now (`current`).
    pub fn sample(r: *Running, t_ns: u64, current: Value) Sample {
        if (r.start_ns == 0) r.start_ns = t_ns;
        if (t_ns < r.start_ns) return .{ .value = current, .done = false };
        const from = r.from orelse current;
        r.from = from;
        const a = r.anim;
        const elapsed = t_ns - r.start_ns;
        if (a.duration_ns == 0) return .{ .value = a.to, .done = true };
        const iteration = elapsed / a.duration_ns;
        if (a.iterations != 0 and iteration >= a.iterations) {
            const back = a.alternate and a.iterations % 2 == 0;
            return .{ .value = if (back) from else a.to, .done = true };
        }
        var x: f32 = @floatCast(@as(f64, @floatFromInt(elapsed % a.duration_ns)) / @as(f64, @floatFromInt(a.duration_ns)));
        if (a.alternate and iteration % 2 == 1) x = 1 - x;
        return .{ .value = lerp(from, a.to, ease(a.easing, x)), .done = false };
    }
};

/// Kinetic scrolling: velocity decays exponentially, so the offset
/// approaches `start + velocity * tau` and stops once the speed drops
/// below `min_speed`.
pub const Fling = struct {
    start: Point,
    velocity: Point,
    /// 0 until the first sample.
    start_ns: u64 = 0,

    /// Time constant of the decay, in seconds. A first guess, to be tuned
    /// against touchpad feel (D16).
    pub const tau: f32 = 0.325;
    /// Logical pixels per second.
    pub const min_speed: f32 = 20;
    /// Flings slower than this do not start.
    pub const min_start_speed: f32 = 100;

    pub fn sample(f: *Fling, t_ns: u64) struct { offset: Point, done: bool } {
        if (f.start_ns == 0) f.start_ns = t_ns;
        const t: f32 = @floatCast(@as(f64, @floatFromInt(t_ns -| f.start_ns)) / std.time.ns_per_s);
        const decay = @exp(-t / tau);
        const travel = (1 - decay) * tau;
        const offset: Point = .{ .x = f.start.x + f.velocity.x * travel, .y = f.start.y + f.velocity.y * travel };
        return .{ .offset = offset, .done = f.velocity.length() * decay < min_speed };
    }
};

/// Estimates scroll velocity from recent input deltas, for flings at the
/// end of a touchpad gesture.
pub const VelocityTracker = struct {
    samples: [8]Entry = undefined,
    len: usize = 0,
    head: usize = 0,

    const Entry = struct { time_ms: u32, delta: Point };
    /// Only motion this recent counts.
    const window_ms = 100;

    pub fn reset(v: *VelocityTracker) void {
        v.len = 0;
    }

    pub fn add(v: *VelocityTracker, time_ms: u32, delta: Point) void {
        v.samples[v.head] = .{ .time_ms = time_ms, .delta = delta };
        v.head = (v.head + 1) % v.samples.len;
        v.len = @min(v.len + 1, v.samples.len);
    }

    /// Pixels per second over the recent samples ending at `now_ms`.
    pub fn velocity(v: *const VelocityTracker, now_ms: u32) Point {
        var sum: Point = .zero;
        var oldest = now_ms;
        var n: usize = 0;
        for (0..v.len) |i| {
            const e = v.samples[(v.head + v.samples.len - 1 - i) % v.samples.len];
            if (now_ms -% e.time_ms > window_ms) break;
            sum = sum.add(e.delta);
            oldest = e.time_ms;
            n += 1;
        }
        // Deltas are motion since the previous event, so n events span the
        // time from the one before the oldest; assume one event interval.
        if (n < 2) return .zero;
        const span_ms: f32 = @floatFromInt(now_ms -% oldest);
        const per_event = span_ms / @as(f32, @floatFromInt(n - 1));
        return sum.scale(1000 / (span_ms + per_event));
    }
};

const testing = std.testing;

test "cubic bezier easing matches known values" {
    // CSS `ease` at 0.5 is about 0.8024.
    try testing.expectApproxEqAbs(@as(f32, 0.8024), ease(.ease, 0.5), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ease(.ease_in_out, 0.5), 1e-4);
    try testing.expectEqual(@as(f32, 0), ease(.ease_out, 0));
    try testing.expectEqual(@as(f32, 1), ease(.ease_out, 1));
    // Monotonic for a curve with overshoot in y.
    var prev: f32 = -1;
    for (0..101) |i| {
        const y = ease(.{ .cubic_bezier = .{ 0.3, -0.5, 0.7, 1.5 } }, @as(f32, @floatFromInt(i)) / 100);
        if (i > 0 and i < 100) try testing.expect(@abs(y - prev) < 0.1);
        prev = y;
    }
}

test "animations resolve their start, iterate, alternate, and finish" {
    var r = Running.init(.{ .to = .{ .opacity = 1 }, .duration_ns = 100, .easing = .linear, .iterations = 2, .alternate = true });
    const shown: Value = .{ .opacity = 0 };
    try testing.expectEqual(@as(f32, 0), r.sample(1000, shown).value.opacity); // starts here
    try testing.expectApproxEqAbs(@as(f32, 0.25), r.sample(1025, .{ .opacity = 0.9 }).value.opacity, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), r.sample(1125, shown).value.opacity, 1e-6); // backwards
    const end = r.sample(1200, shown);
    try testing.expect(end.done);
    try testing.expectEqual(@as(f32, 0), end.value.opacity); // even iterations end at `from`

    var later = Running.init(.{ .to = .{ .opacity = 1 }, .duration_ns = 100, .start_ns = 500, .easing = .linear });
    try testing.expectEqual(@as(f32, 0.3), later.sample(400, .{ .opacity = 0.3 }).value.opacity);
    try testing.expectApproxEqAbs(@as(f32, 0.65), later.sample(550, .{ .opacity = 0.3 }).value.opacity, 1e-6);
    try testing.expect(later.sample(600, .{ .opacity = 0.3 }).done);
}

test "flings decelerate and stop" {
    var f: Fling = .{ .start = .zero, .velocity = .{ .x = 0, .y = 2000 } };
    const a = f.sample(1_000_000_000);
    try testing.expectEqual(@as(f32, 0), a.offset.y);
    const b = f.sample(1_100_000_000);
    const c = f.sample(1_200_000_000);
    try testing.expect(b.offset.y > 0 and c.offset.y > b.offset.y);
    try testing.expect(c.offset.y - b.offset.y < b.offset.y); // slowing down
    const end = f.sample(3_000_000_000);
    try testing.expect(end.done);
    try testing.expectApproxEqAbs(2000 * Fling.tau, end.offset.y, 5);
}

test "velocity tracker averages recent deltas" {
    var v: VelocityTracker = .{};
    // 10 px every 10 ms: 1000 px/s.
    for (0..6) |i| v.add(@intCast(1000 + i * 10), .{ .x = 0, .y = 10 });
    try testing.expectApproxEqAbs(@as(f32, 1000), v.velocity(1050).y, 1);
    // Old motion does not count.
    try testing.expectEqual(@as(f32, 0), v.velocity(5000).y);
}
