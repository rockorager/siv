//! Knuth and Plass's total-fit line breaking (D13), over break candidates
//! with running totals, shared by paragraph layout (`layout.zig`) and the
//! document renderer's inline layout (D32, `text-wrap: pretty`).

const std = @import("std");

/// A place a line may end: the end of a segment, or a hyphenation point.
pub const Candidate = struct {
    at: u32,
    /// Totals from the text's start: natural width, stretch, and shrink,
    /// up to the end of a line ending here (without its hanging
    /// whitespace) and up to where the next line starts.
    w_end: f64,
    w_next: f64,
    s_end: f64,
    s_next: f64,
    z_end: f64 = 0,
    z_next: f64 = 0,
    /// The width of a hyphen that ends a line broken here, if hyphenated.
    hyphen: ?f64 = null,
    forced: bool = false,
    unsafe: bool = false,
    penalty: f64 = 0,
};

/// The breaks minimizing the paragraph's demerits, by dynamic programming
/// over every candidate (forced breaks split the text): indices into
/// `c`, increasing, ending with the last candidate; `c[0]` is the start.
/// `limit(ctx, at)` is the width of a line starting at byte `at`.
///
/// Interword spaces stretch by half their width and never shrink
/// (justification only widens them, and ragged lines must fit); a
/// paragraph's last line may fall short freely. The adjustment ratio r
/// is the room left over the stretch plus 3% of the width (so lines
/// without spaces are not all equally bad, as with TeX's capped
/// badness); badness is 100 |r|³, demerits (10 + badness)² plus the
/// square of a hyphen's penalty and 3000 for consecutive hyphenated
/// lines. A line no break can make fit overflows, with demerits growing
/// with the overflow.
pub fn breaks(scratch: std.mem.Allocator, c: []const Candidate, ctx: anytype, comptime limit: fn (@TypeOf(ctx), u32) f64) error{OutOfMemory}![]u32 {
    const best = try scratch.alloc(f64, c.len);
    const prev = try scratch.alloc(u32, c.len);
    best[0] = 0;
    var floor: usize = 0;
    for (1..c.len) |k| {
        best[k] = std.math.inf(f64);
        prev[k] = @intCast(k - 1);
        var a = k;
        while (a > floor) {
            a -= 1;
            const lim = limit(ctx, c[a].at);
            const natural = c[k].w_end - c[a].w_next + (c[k].hyphen orelse 0);
            const stretch = c[k].s_end - c[a].s_next;
            const shrink = c[k].z_end - c[a].z_next;
            var d: f64 = undefined;
            if (natural > lim + shrink + 0.001) {
                // Overfull: only as the one way out.
                if (a + 1 != k and best[k] < std.math.inf(f64)) break;
                d = 1e12 + (natural - lim) * 1e6;
            } else {
                const give = stretch + 0.03 * lim;
                const r: f64 = if (natural <= lim)
                    (if (c[k].forced) 0 else (lim - natural) / give)
                else
                    (lim - natural) / @max(shrink, 1e-9);
                const badness = @min(1e10, 100 * @abs(r) * @abs(r) * @abs(r));
                d = (10 + badness) * (10 + badness) + c[k].penalty * c[k].penalty;
                if (c[k].hyphen != null and c[a].hyphen != null) d += 3000;
            }
            if (best[a] + d < best[k]) {
                best[k] = best[a] + d;
                prev[k] = @intCast(a);
            }
        }
        if (c[k].forced) floor = k;
    }
    var chain: std.ArrayList(u32) = .empty;
    var k: u32 = @intCast(c.len - 1);
    while (k != 0) : (k = prev[k]) try chain.append(scratch, k);
    std.mem.reverse(u32, chain.items);
    return chain.items;
}

test "an even paragraph beats a greedy one" {
    // Words of widths 3, 3, 3, 3, 6 with spaces of 1 at width 8: greedy
    // takes "3 3" (7), "3 3" (7), "6"; total fit gives the same here, and
    // a forced last line is free.
    var c: std.ArrayList(Candidate) = .empty;
    defer c.deinit(std.testing.allocator);
    try c.append(std.testing.allocator, .{ .at = 0, .w_end = 0, .w_next = 0, .s_end = 0, .s_next = 0 });
    const words = [_]f64{ 3, 3, 3, 3, 6 };
    var w: f64 = 0;
    var s: f64 = 0;
    for (words, 0..) |word, i| {
        const last = i + 1 == words.len;
        try c.append(std.testing.allocator, .{ .at = @intCast(i + 1), .w_end = w + word, .w_next = w + word + 1, .s_end = s, .s_next = s + 0.5, .forced = last });
        w += word + 1;
        s += 0.5;
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try breaks(arena.allocator(), c.items, {}, struct {
        fn f(_: void, _: u32) f64 {
            return 8;
        }
    }.f);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 5 }, r);
}
