//! web-platform-tests CSS reftests (D32), imported by test/wpt/import.py:
//! each test and its reference are rendered at 800×600 through the
//! document renderer and siv's CPU renderer and compared; the pass rate
//! per suite must not fall below the one recorded here (and in DESIGN.md).
//! Fonts: Ahem from WPT for `font-family: Ahem`, siv's Droid test font for
//! everything else. Tests marked "img" use images; the floors count them. SIV_WPT_VERBOSE=1 prints the failures.

const std = @import("std");
const png = @import("png");

const testing = std.testing;
const Runner = @import("render.zig").Runner;
const W = 800;
const H = 600;
const root = "test/wpt";
const origin = "http://wpt";

/// Passing tests per suite, recorded: all of them, and those without
/// images; fewer fails the test.
const floors = .{
    .{ "css2", 441, 235 },
    .{ "css-flexbox", 428, 361 },
    .{ "css-grid", 188, 176 },
    .{ "css-values", 67, 65 },
    .{ "css-variables", 47, 47 },
    .{ "css-tables", 127, 125 },
    .{ "floats", 160, 96 },
    .{ "css-sizing", 239, 181 },
    .{ "css-display", 60, 60 },
    .{ "css-pseudo", 34, 33 },
    .{ "css-lists", 169, 167 },
    .{ "css-text", 122, 116 },
    .{ "css-backgrounds", 214, 113 },
    .{ "css-overflow", 73, 69 },
    .{ "css-position", 24, 23 },
    .{ "css-break", 45, 44 },
    .{ "css-multicol", 69, 63 },
    .{ "css-writing-modes", 73, 52 },
};

/// Whether test/wpt/SKIP lists a test as out of scope ("path reason"
/// lines): it is left out of the pass rate.
pub fn skipped(skip: []const u8, test_path: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, skip, '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        const end = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        if (std.mem.eql(u8, line[0..end], test_path)) return true;
    }
    return false;
}

fn runSuite(comptime suite: []const u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/MANIFEST", gpa, .limited(1 << 20));
    defer gpa.free(manifest);
    const skip = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/SKIP", gpa, .limited(1 << 20));
    defer gpa.free(skip);
    const r = try Runner.init(gpa, io, root, origin, W, H);
    defer r.deinit();
    const verbose = testing.environ.getPosix("SIV_WPT_VERBOSE") != null;
    const dump = testing.environ.getPosix("SIV_WPT_DUMP");
    var total: usize = 0;
    var passed: usize = 0;
    // Tests with images, apart: the rates before they were measured stay
    // comparable.
    var img_total: usize = 0;
    var img_passed: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, parts.next() orelse continue, suite)) continue;
        const test_path = parts.next() orelse continue;
        const ref_path = parts.next() orelse continue;
        if (skipped(skip, test_path)) continue;
        const with_images = if (parts.next()) |flag| std.mem.eql(u8, flag, "img") else false;
        total += 1;
        if (with_images) img_total += 1;
        const ok = blk: {
            r.render(test_path, .html, 0, r.pixels[0]) catch break :blk false;
            r.render(ref_path, .html, 0, r.pixels[1]) catch break :blk false;
            break :blk r.sameAs(test_path);
        };
        if (ok) {
            passed += 1;
            if (with_images) img_passed += 1;
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
    if (verbose or testing.environ.getPosix("SIV_WPT_RATES") != null) std.debug.print("WPT {s}: {d}/{d} (without images {d}/{d})\n", .{ suite, passed, total, passed - img_passed, total - img_total });
    inline for (floors) |f| if (comptime std.mem.eql(u8, f[0], suite)) {
        try testing.expect(passed >= f[1]);
        try testing.expect(passed - img_passed >= f[2]);
    };
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

test "WPT css-tables reftests" {
    try runSuite("css-tables");
}

test "WPT floats reftests" {
    try runSuite("floats");
}

test "WPT css-sizing reftests" {
    try runSuite("css-sizing");
}

test "WPT css-display reftests" {
    try runSuite("css-display");
}

test "WPT css-pseudo reftests" {
    try runSuite("css-pseudo");
}

test "WPT css-lists reftests" {
    try runSuite("css-lists");
}

test "WPT css-text reftests" {
    try runSuite("css-text");
}

test "WPT css-backgrounds reftests" {
    try runSuite("css-backgrounds");
}

test "WPT css-overflow reftests" {
    try runSuite("css-overflow");
}

test "WPT css-position reftests" {
    try runSuite("css-position");
}

test "WPT css-break reftests" {
    try runSuite("css-break");
}

test "WPT css-multicol reftests" {
    try runSuite("css-multicol");
}

test "WPT css-writing-modes reftests" {
    try runSuite("css-writing-modes");
}
