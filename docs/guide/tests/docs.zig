//! Checks of the guide's text against its samples and screenshots:
//!
//! - Every code block (other than shell commands, plain text, and
//!   diagrams) is quoted from a file under docs/guide/examples, so code
//!   the guide shows is code the guide's tests build and run. A block may
//!   drop the indentation its lines share in the file.
//! - Every image a chapter shows exists, and every image in
//!   docs/guide/images is shown somewhere.

const std = @import("std");

const testing = std.testing;
const guide_dir = "docs/guide";

const exempt = [_][]const u8{ "sh", "text", "diagram" };

const Doc = struct { name: []const u8, text: []const u8 };

fn readDir(gpa: std.mem.Allocator, sub: []const u8, recursive: bool, list: *std.ArrayList(Doc)) !void {
    return readDirSkipping(gpa, sub, recursive, list, ".png");
}

/// Reads the files of `sub`, leaving out names ending in `skip`.
fn readDirSkipping(gpa: std.mem.Allocator, sub: []const u8, recursive: bool, list: *std.ArrayList(Doc), skip: []const u8) !void {
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, sub, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        if (!recursive and e.depth() > 1) continue;
        // Build output of the Zig package sample, and images.
        if (std.mem.indexOf(u8, e.path, ".zig-cache") != null or std.mem.indexOf(u8, e.path, "zig-out") != null or std.mem.indexOf(u8, e.path, "zig-pkg") != null) continue;
        if (std.mem.endsWith(u8, e.path, skip)) continue;
        const name = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, e.path });
        const data = try dir.readFileAlloc(io, e.path, gpa, .limited(4 << 20));
        try list.append(gpa, .{ .name = name, .text = data });
    }
}

/// The lines of `s` without the indentation they all share.
fn dedent(gpa: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    var common: ?[]const u8 = null;
    for (lines) |l| {
        if (std.mem.trim(u8, l, " \t").len == 0) continue;
        const ws = l[0 .. l.len - std.mem.trimStart(u8, l, " \t").len];
        if (common) |cm| {
            var n: usize = 0;
            while (n < cm.len and n < ws.len and cm[n] == ws[n]) n += 1;
            common = cm[0..n];
        } else common = ws;
    }
    const cut = if (common) |cm| cm.len else 0;
    var out: std.ArrayList(u8) = .empty;
    for (lines, 0..) |l, i| {
        if (i > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, if (l.len >= cut) l[cut..] else std.mem.trimStart(u8, l, " \t"));
    }
    return out.items;
}

fn splitLines(gpa: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try lines.append(gpa, l);
    return lines.items;
}

/// Whether `block` is a run of consecutive lines of `file`, give or take
/// the indentation they share.
fn quoted(gpa: std.mem.Allocator, block: []const []const u8, file: []const []const u8) !bool {
    const want = try dedent(gpa, block);
    if (block.len > file.len) return false;
    var i: usize = 0;
    while (i + block.len <= file.len) : (i += 1) {
        if (!std.mem.eql(u8, std.mem.trimStart(u8, file[i], " \t"), std.mem.trimStart(u8, block[0], " \t"))) continue;
        if (std.mem.eql(u8, try dedent(gpa, file[i .. i + block.len]), want)) return true;
    }
    return false;
}

test "guide: every code block is quoted from a sample" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var chapters: std.ArrayList(Doc) = .empty;
    try readDir(gpa, guide_dir, false, &chapters);
    var samples: std.ArrayList(Doc) = .empty;
    try readDir(gpa, guide_dir ++ "/examples", true, &samples);
    var sample_lines: std.ArrayList([]const []const u8) = .empty;
    for (samples.items) |s| try sample_lines.append(gpa, try splitLines(gpa, s.text));

    var failures: usize = 0;
    var blocks: usize = 0;
    for (chapters.items) |doc| {
        if (!std.mem.endsWith(u8, doc.name, ".md")) continue;
        const lines = try splitLines(gpa, doc.text);
        var i: usize = 0;
        while (i < lines.len) : (i += 1) {
            const open = std.mem.trimStart(u8, lines[i], " ");
            if (!std.mem.startsWith(u8, open, "```")) continue;
            const info = std.mem.trim(u8, open[3..], " ");
            const start = i + 1;
            var end = start;
            while (end < lines.len and !std.mem.startsWith(u8, std.mem.trimStart(u8, lines[end], " "), "```")) end += 1;
            i = end;
            if (info.len == 0) {
                std.debug.print("{s}:{d}: code block without a language\n", .{ doc.name, start });
                failures += 1;
                continue;
            }
            const lang = std.mem.sliceTo(info, ' ');
            var skip = false;
            for (exempt) |e| skip = skip or std.mem.eql(u8, e, lang);
            if (skip) continue;
            blocks += 1;
            const block = lines[start..end];
            var found = false;
            for (sample_lines.items) |file| {
                if (try quoted(gpa, block, file)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.debug.print("{s}:{d}: this {s} block is not quoted from docs/guide/examples:\n{s}\n", .{ doc.name, start, lang, try dedent(gpa, block) });
                failures += 1;
            }
        }
    }
    try testing.expect(blocks > 0);
    try testing.expectEqual(@as(usize, 0), failures);
}

test "guide: every image is shown, and every image shown exists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var chapters: std.ArrayList(Doc) = .empty;
    try readDir(gpa, guide_dir, false, &chapters);
    var images: std.ArrayList(Doc) = .empty;
    try readDirSkipping(gpa, guide_dir ++ "/images", false, &images, ".none");
    var failures: usize = 0;
    for (images.items) |img| {
        const base = std.fs.path.basename(img.name);
        const ref = try std.fmt.allocPrint(gpa, "](images/{s})", .{base});
        var shown = false;
        for (chapters.items) |doc| shown = shown or std.mem.indexOf(u8, doc.text, ref) != null;
        if (!shown) {
            std.debug.print("{s} is not shown in any chapter\n", .{img.name});
            failures += 1;
        }
    }
    for (chapters.items) |doc| {
        var rest = doc.text;
        while (std.mem.indexOf(u8, rest, "](images/")) |at| {
            rest = rest[at + 9 ..];
            const end = std.mem.indexOfScalar(u8, rest, ')') orelse break;
            const name = rest[0..end];
            var exists = false;
            for (images.items) |img| exists = exists or std.mem.eql(u8, std.fs.path.basename(img.name), name);
            if (!exists) {
                std.debug.print("{s} shows images/{s}, which does not exist\n", .{ doc.name, name });
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
