//! Runs web-platform-tests reftests through the document renderer (D32)
//! and prints each result: a development tool for triage, not a gate.
//!
//!     zig build doc-wpt -- [FILTER...] [--manifest FILE] [--root DIR]
//!                          [--dump DIR] [--failures]
//!
//! FILTER is a suite name or a substring of a test's path; without one,
//! every test of the manifest runs (test/wpt/MANIFEST by default).
//! `--dump DIR` writes the test's and reference's renders of failures as
//! PNGs, `--failures` prints only failures, and totals per suite end
//! the output.

const std = @import("std");
const png = @import("png");
const Runner = @import("render.zig").Runner;

const W = 800;
const H = 600;

fn isSuite(manifest: []const u8, name: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        const end = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (std.mem.eql(u8, line[0..end], name)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var manifest_path: []const u8 = "test/wpt/MANIFEST";
    var root: []const u8 = "test/wpt";
    var dump: ?[]const u8 = null;
    var failures_only = false;
    var filters: std.ArrayList([]const u8) = .empty;
    defer filters.deinit(gpa);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--manifest")) {
            i += 1;
            manifest_path = argv[i];
        } else if (std.mem.eql(u8, a, "--root")) {
            i += 1;
            root = argv[i];
        } else if (std.mem.eql(u8, a, "--dump")) {
            i += 1;
            dump = argv[i];
        } else if (std.mem.eql(u8, a, "--failures")) {
            failures_only = true;
        } else try filters.append(gpa, a);
    }
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(16 << 20));
    defer gpa.free(manifest);
    const skip_path = try std.fmt.allocPrint(gpa, "{s}/SKIP", .{root});
    defer gpa.free(skip_path);
    const skip = std.Io.Dir.cwd().readFileAlloc(io, skip_path, gpa, .limited(1 << 20)) catch try gpa.dupe(u8, "");
    defer gpa.free(skip);
    const r = try Runner.init(gpa, io, root, "http://wpt", W, H);
    defer r.deinit();
    const filter_is_suite = try gpa.alloc(bool, filters.items.len);
    defer gpa.free(filter_is_suite);
    for (filters.items, filter_is_suite) |f, *is| is.* = isSuite(manifest, f);
    var totals: std.StringArrayHashMapUnmanaged([2]usize) = .empty;
    defer totals.deinit(gpa);
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const suite = parts.next() orelse continue;
        const test_path = parts.next() orelse continue;
        const ref_path = parts.next() orelse continue;
        if (filters.items.len > 0) {
            var hit = false;
            // A suite's name selects that suite; other filters, paths.
            for (filters.items, filter_is_suite) |f, is_suite| hit = hit or
                (if (is_suite) std.mem.eql(u8, f, suite) else std.mem.indexOf(u8, test_path, f) != null);
            if (!hit) continue;
        }
        if (@import("wpt.zig").skipped(skip, test_path)) {
            if (!failures_only) try w.print("SKIP {s}\n", .{test_path});
            continue;
        }
        const gop = try totals.getOrPut(gpa, suite);
        if (!gop.found_existing) gop.value_ptr.* = .{ 0, 0 };
        gop.value_ptr[1] += 1;
        const ok = blk: {
            r.render(test_path, .html, 0, r.pixels[0]) catch break :blk false;
            r.render(ref_path, .html, 0, r.pixels[1]) catch break :blk false;
            break :blk r.sameAs(test_path);
        };
        if (ok) gop.value_ptr[0] += 1;
        if (!ok or !failures_only) try w.print("{s} {s}\n", .{ if (ok) "PASS" else "FAIL", test_path });
        if (!ok) if (dump) |dir| {
            for (r.pixels, [_][]const u8{ "test", "ref" }) |px, which| {
                const enc = try png.encode(gpa, W, H, px);
                defer gpa.free(enc);
                const name = try std.fmt.allocPrint(gpa, "{s}/{s}.{s}.png", .{ dir, std.fs.path.basename(test_path), which });
                defer gpa.free(name);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = enc }) catch {};
            }
        };
        try w.flush();
    }
    var it = totals.iterator();
    while (it.next()) |kv| try w.print("WPT {s}: {d}/{d}\n", .{ kv.key_ptr.*, kv.value_ptr[0], kv.value_ptr[1] });
    try w.flush();
}
