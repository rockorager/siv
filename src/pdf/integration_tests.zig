//! PDF output checked by independent parsers (`zig build test-integration`):
//! the sample page of every construct (test_sample.zig) passes qpdf's
//! structural check, poppler extracts its text and reports its font as an
//! embedded subset with a ToUnicode map, and poppler's rendering shows the
//! sample's solid regions in their colors.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const scene = @import("scene");
const text = @import("text");
const Writer = @import("Writer.zig");
const sample = @import("test_sample.zig");

const gpa = testing.allocator;

/// Runs `argv` to completion and returns its exit status and its stdout
/// and stderr, which the caller frees.
fn run(argv: []const [*:0]const u8) !struct { status: u32, output: []u8 } {
    const out_rc = linux.memfd_create("siv-pdf-test", 0);
    if (linux.errno(out_rc) != .SUCCESS) return error.SpawnFailed;
    const out: i32 = @intCast(out_rc);
    defer _ = linux.close(out);
    var args: [8:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |a, i| args[i] = a;
    const exe = findExecutable(std.mem.span(argv[0])) orelse return error.SkipZigTest;
    const env = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", "LC_ALL=C.UTF-8" };
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.SpawnFailed;
    if (rc == 0) {
        _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
        _ = linux.dup2(out, 1);
        _ = linux.dup2(out, 2);
        _ = linux.execve(exe, &args, &env);
        linux.exit_group(127);
    }
    var status: i32 = 0;
    while (true) {
        const w = linux.waitpid(@intCast(rc), &status, 0);
        if (linux.errno(w) != .INTR) break;
    }
    const size = linux.lseek(out, 0, linux.SEEK.END);
    const output = try gpa.alloc(u8, size);
    errdefer gpa.free(output);
    if (size > 0 and linux.pread(out, output.ptr, output.len, 0) != size) return error.ReadFailed;
    return .{ .status = linux.W.EXITSTATUS(@bitCast(status)), .output = output };
}

fn findExecutable(name: []const u8) ?[*:0]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    for ([_][]const u8{ "/usr/bin", "/bin", "/usr/local/bin" }) |dir| {
        const full = std.fmt.bufPrintSentinel(&S.buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
        if (linux.access(full, 1) == 0) return full;
    }
    return null;
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.write(fd, data.ptr, data.len) != data.len) return error.WriteFailed;
}

fn readFile(path: [*:0]const u8) ![]u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    const data = try gpa.alloc(u8, size);
    errdefer gpa.free(data);
    if (linux.pread(fd, data.ptr, data.len, 0) != size) return error.ReadFailed;
    return data;
}

/// Writes the sample PDF to `path`.
fn writeSample(path: [*:0]const u8) !void {
    var fonts: text.FontCache = .init(gpa);
    defer fonts.deinit();
    const id = try fonts.add(text.font.test_fonts.latin, 0, .borrowed);
    var b: scene.Builder = .init(gpa);
    defer b.deinit();
    try sample.build(&b, fonts.face(id).?);
    var w = try Writer.init(gpa, .{ .title = "Every construct", .author = "siv" });
    defer w.deinit();
    try w.addPage(sample.width, sample.height, try b.finish(0));
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try w.finish(&aw.writer);
    try writeFile(path, aw.written());
}

/// A unique path under /tmp ending in `suffix`.
fn tmpPath(buf: []u8, comptime suffix: []const u8) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "/tmp/siv-pdf-test-{d}" ++ suffix, .{linux.getpid()}, 0);
}

test "qpdf finds no structural or stream errors" {
    var buf: [64]u8 = undefined;
    const path = try tmpPath(&buf, ".pdf");
    try writeSample(path);
    defer _ = linux.unlink(path);
    const r = try run(&.{ "qpdf", "--check", path });
    defer gpa.free(r.output);
    if (r.status != 0) std.debug.print("{s}\n", .{r.output});
    try testing.expectEqual(@as(u32, 0), r.status);
    try testing.expect(std.mem.indexOf(u8, r.output, "No syntax or stream encoding errors found") != null);
}

test "poppler extracts the text and finds an embedded subset with ToUnicode" {
    var buf: [64]u8 = undefined;
    const path = try tmpPath(&buf, ".pdf");
    try writeSample(path);
    defer _ = linux.unlink(path);

    const t = try run(&.{ "pdftotext", path, "-" });
    defer gpa.free(t.output);
    try testing.expectEqual(@as(u32, 0), t.status);
    try testing.expect(std.mem.indexOf(u8, t.output, sample.words) != null);

    const f = try run(&.{ "pdffonts", path });
    defer gpa.free(f.output);
    try testing.expectEqual(@as(u32, 0), f.status);
    // name type encoding emb sub uni object ID
    var lines = std.mem.splitScalar(u8, f.output, '\n');
    var found = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "CID TrueType") == null) continue;
        found = true;
        try testing.expect(std.mem.indexOf(u8, line, "Identity-H") != null);
        try testing.expect(std.mem.indexOf(u8, line, "yes yes yes") != null);
        try testing.expectEqual(@as(u8, '+'), line[6]);
    }
    if (!found) std.debug.print("{s}\n", .{f.output});
    try testing.expect(found);

    const i = try run(&.{ "pdfinfo", path });
    defer gpa.free(i.output);
    try testing.expect(std.mem.indexOf(u8, i.output, "Every construct") != null);
    try testing.expect(std.mem.indexOf(u8, i.output, "300 x 400 pts") != null);
}

test "poppler renders the solid regions in their colors" {
    var buf: [64]u8 = undefined;
    const path = try tmpPath(&buf, ".pdf");
    try writeSample(path);
    defer _ = linux.unlink(path);
    var root_buf: [64]u8 = undefined;
    const root = try tmpPath(&root_buf, "");
    // At 72 dpi a point is a pixel.
    const r = try run(&.{ "pdftoppm", "-r", "72", "-singlefile", path, root });
    defer gpa.free(r.output);
    try testing.expectEqual(@as(u32, 0), r.status);
    var ppm_buf: [64]u8 = undefined;
    const ppm_path = try tmpPath(&ppm_buf, ".ppm");
    defer _ = linux.unlink(ppm_path);
    const ppm = try readFile(ppm_path);
    defer gpa.free(ppm);

    // P6 <width> <height> 255 <rgb...>
    var it = std.mem.tokenizeAny(u8, ppm, " \n");
    try testing.expectEqualStrings("P6", it.next().?);
    const w = try std.fmt.parseInt(usize, it.next().?, 10);
    const h = try std.fmt.parseInt(usize, it.next().?, 10);
    try testing.expectEqualStrings("255", it.next().?);
    try testing.expectEqual(@as(usize, 300), w);
    try testing.expectEqual(@as(usize, 400), h);
    const pixels = ppm[it.index + 1 ..];
    try testing.expectEqual(w * h * 3, pixels.len);
    for (sample.probes) |p| {
        const at = (@as(usize, @intFromFloat(p.y)) * w + @as(usize, @intFromFloat(p.x))) * 3;
        for (p.rgb, pixels[at..][0..3]) |want, got| {
            if (@abs(@as(i32, want) - @as(i32, got)) > 3) {
                std.debug.print("probe ({d}, {d}): want {any}, got {any}\n", .{ p.x, p.y, p.rgb, pixels[at..][0..3] });
                return error.TestUnexpectedResult;
            }
        }
    }
}
