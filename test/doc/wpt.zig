//! web-platform-tests CSS reftests (D32), imported by test/wpt/import.py:
//! each test and its reference are rendered at 800×600 through the
//! document renderer and siv's CPU renderer and compared; the pass rate
//! per suite must not fall below the one recorded here (and in DESIGN.md).
//! Fonts: Ahem from WPT for `font-family: Ahem`, siv's Droid test font for
//! everything else. SIV_WPT_VERBOSE=1 prints the failures.

const std = @import("std");
const png = @import("png");

const testing = std.testing;
const Runner = @import("render.zig").Runner;
const W = 800;
const H = 600;
const root = "test/wpt";
const origin = "http://wpt";

/// Passing tests per suite, recorded: fewer fails the test.
const floors = .{
    .{ "css2", 227 },
    .{ "css-flexbox", 210 },
    .{ "css-grid", 58 },
    .{ "css-values", 56 },
    .{ "css-variables", 46 },
};

fn runSuite(comptime suite: []const u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/MANIFEST", gpa, .limited(1 << 20));
    defer gpa.free(manifest);
    const r = try Runner.init(gpa, io, root, origin, W, H);
    defer r.deinit();
    const verbose = testing.environ.getPosix("SIV_WPT_VERBOSE") != null;
    const dump = testing.environ.getPosix("SIV_WPT_DUMP");
    var total: usize = 0;
    var passed: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, parts.next() orelse continue, suite)) continue;
        const test_path = parts.next() orelse continue;
        const ref_path = parts.next() orelse continue;
        total += 1;
        const ok = blk: {
            r.render(test_path, .html, 0, r.pixels[0]) catch break :blk false;
            r.render(ref_path, .html, 0, r.pixels[1]) catch break :blk false;
            break :blk r.same();
        };
        if (ok) {
            passed += 1;
        } else {
            if (verbose) std.debug.print("WPT FAIL {s}\n", .{test_path});
            if (dump) |dir| {
                for (r.pixels, [_][]const u8{ "test", "ref" }) |px, which| {
                    const enc = try png.encode(gpa, W, H, px);
                    defer gpa.free(enc);
                    const name = try std.fmt.allocPrint(gpa, "{s}/{s}.{s}.png", .{ dir, std.fs.path.basename(test_path), which });
                    defer gpa.free(name);
                    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = enc }) catch {};
                }
            }
        }
    }
    if (verbose or testing.environ.getPosix("SIV_WPT_RATES") != null) std.debug.print("WPT {s}: {d}/{d}\n", .{ suite, passed, total });
    inline for (floors) |f| if (comptime std.mem.eql(u8, f[0], suite)) try testing.expect(passed >= f[1]);
    try testing.expect(total > 0);
}

test "WPT css2 reftests" {
    try runSuite("css2");
}

test "WPT css-flexbox reftests" {
    try runSuite("css-flexbox");
}

test "WPT css-grid reftests" {
    try runSuite("css-grid");
}

test "WPT css-values reftests" {
    try runSuite("css-values");
}

test "WPT css-variables reftests" {
    try runSuite("css-variables");
}
