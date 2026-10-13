//! siv's SVG renderer against librsvg on real icon themes (`zig build
//! test-integration-icons`, opt in: what it finds depends on the theme
//! releases installed, D19): every SVG of the installed Adwaita and
//! Breeze themes is drawn by siv (svg lowered to a display list, CPU
//! renderer) and by rsvg-convert at 32 × 32, and the two are compared. The themes are LGPL and CC-BY-SA, so neither the
//! icons nor images of them are in the repository (D25); the reference is
//! made from the installed files when the test runs. Debian packages:
//! adwaita-icon-theme, breeze-icon-theme, librsvg2-bin (.agents/setup).
//!
//! siv composites an SVG's content in sRGB, as librsvg does, and the
//! result onto what is below it in linear light (D11, D19). Two
//! comparisons:
//!
//! - Geometry: the icon drawn over white inside one sRGB layer, so that
//!   the composite onto white blends as librsvg's does too, against the
//!   reference over white in sRGB. Only the lowering and coverage differ
//!   here, so this is the strict check of the SVG renderer.
//! - As drawn: siv's output as an application gets it, against the
//!   reference composited over white in linear light.
//!
//! An icon differs when more than 2% of its pixels are off by more than
//! 24 of 255 in some channel. With SIV_ICON_DIFFS=DIR, the renderings
//! of the icons that differ most in geometry go to DIR (siv left).
//! SIV_ICON_ONLY=TEXT compares only the files whose paths contain TEXT.

const std = @import("std");
const linux = std.os.linux;
const svg = @import("svg");
const scene = @import("scene");
const raster = @import("raster");
const render_cpu = @import("render_cpu");
const pool = @import("pool");
const png = @import("png");

const gpa = std.testing.allocator;
const size = 32;

/// `env` names a variable that points the comparison at another copy of
/// the theme (an unpacked release, say).
const Theme = struct { name: []const u8, dir: []const u8, env: [:0]const u8, max_geometry: f32, max_drawn: f32 };

/// Measured on Debian 12's adwaita-icon-theme 43 and breeze-icon-theme
/// 5.103, and Adwaita 48.1 and 51.0 (October 2026; D19 has the numbers).
/// A newer release may use what siv leaves out: that is why the test is
/// opt in.
const themes = [_]Theme{
    .{ .name = "Adwaita", .dir = "/usr/share/icons/Adwaita", .env = "SIV_ICON_ADWAITA", .max_geometry = 0.01, .max_drawn = 0.01 },
    .{ .name = "Breeze", .dir = "/usr/share/icons/breeze", .env = "SIV_ICON_BREEZE", .max_geometry = 0.01, .max_drawn = 0.01 },
};

test "real icon themes match librsvg" {
    const exe = findExecutable("rsvg-convert") orelse return error.SkipZigTest;
    var workers = pool.Pool.init(gpa, 3);
    defer workers.deinit();
    const r = try render_cpu.Renderer.create(gpa, workers.executor());
    defer r.destroy();
    try r.resize(size, size);
    var b = scene.Builder.init(gpa);
    defer b.deinit();
    const diffs_dir = std.testing.environ.getPosix("SIV_ICON_DIFFS");

    var any = false;
    for (themes) |theme| {
        var files: std.ArrayList([]u8) = .empty;
        defer {
            for (files.items) |f| gpa.free(f);
            files.deinit(gpa);
        }
        try listSvgs(std.testing.environ.getPosix(theme.env) orelse theme.dir, &files, 0);
        if (files.items.len == 0) continue;
        any = true;
        std.mem.sort([]u8, files.items, {}, struct {
            fn lt(_: void, a: []u8, c: []u8) bool {
                return std.mem.lessThan(u8, a, c);
            }
        }.lt);

        var drawn: usize = 0;
        var different: usize = 0;
        var geometry: usize = 0;
        var unparsed: usize = 0;
        var worst: [8]struct { score: f32 = 0, file: []const u8 = "" } = @splat(.{});
        const only = std.testing.environ.getPosix("SIV_ICON_ONLY");
        for (files.items) |file| {
            if (only) |o| if (std.mem.indexOf(u8, file, o) == null) continue;
            const bytes = readFile(file) catch continue;
            defer gpa.free(bytes);
            const doc = svg.parse(gpa, bytes, .{}) catch {
                unparsed += 1;
                continue;
            };
            defer doc.deinit();
            const reference = try rsvg(exe, file) orelse continue;
            defer gpa.free(reference);

            // rsvg-convert's viewport for -w and -h with
            // --keep-aspect-ratio: the intrinsic size scaled to fit, at the
            // top left of the canvas.
            const fit = @min(size / doc.width, size / doc.height);
            const dst: raster.Rect = .xywh(0, 0, doc.width * fit, doc.height * fit);
            b.reset();
            doc.draw(&b, dst, null) catch |e| {
                std.debug.print("{s}: drawing failed: {t}\n", .{ file, e });
                return e;
            };
            const list = try b.finish(0);
            var out: [size * size * 4]u8 = undefined;
            try r.render(list, .{ .background = .white, .target = .{ .pixels = &out, .stride = size * 4, .format = .abgr8888 } });
            drawn += 1;

            const want = overWhite(reference, true);
            if (differing(&out, &want) > 0.02) different += 1;

            // Blending in sRGB throughout, onto white too.
            b.reset();
            try b.pushLayer(.{ .srgb = true });
            try b.fillRect(.xywh(0, 0, size, size), .color(.white));
            try doc.draw(&b, dst, null);
            try b.popLayer();
            try r.render(try b.finish(0), .{ .background = .white, .target = .{ .pixels = &out, .stride = size * 4, .format = .abgr8888 } });
            const flat = overWhite(reference, false);
            const score = differing(&out, &flat);
            if (score > 0.02) geometry += 1;
            // Keep the worst few.
            var k: usize = worst.len;
            while (k > 0 and worst[k - 1].score < score) k -= 1;
            if (k < worst.len) {
                std.mem.copyBackwards(@TypeOf(worst[0]), worst[k + 1 ..], worst[k .. worst.len - 1]);
                worst[k] = .{ .score = score, .file = file };
                if (diffs_dir) |dir| try writePair(dir, k, theme.name, &out, &flat);
            }
        }
        const n: f32 = @floatFromInt(@max(drawn, 1));
        const share_geometry = @as(f32, @floatFromInt(geometry)) / n;
        const share_drawn = @as(f32, @floatFromInt(different)) / n;
        std.debug.print("{s}: {d} icons drawn, {d} not parsed; {d} differ in geometry ({d:.2}%), {d} as drawn ({d:.2}%)\n", .{ theme.name, drawn, unparsed, geometry, share_geometry * 100, different, share_drawn * 100 });
        for (worst) |w| if (w.score > 0) std.debug.print("  {d:.1}% {s}\n", .{ w.score * 100, w.file });
        try std.testing.expectEqual(@as(usize, 0), unparsed);
        try std.testing.expect(share_geometry <= theme.max_geometry);
        try std.testing.expect(share_drawn <= theme.max_drawn);
    }
    if (!any) return error.SkipZigTest;
}

/// The reference's straight-alpha sRGB pixels over white, blended in
/// linear light (as siv blends) or in sRGB.
fn overWhite(rgba: []const u8, linear: bool) [size * size * 4]u8 {
    var out: [size * size * 4]u8 = undefined;
    for (0..size * size) |i| {
        const a = @as(f32, @floatFromInt(rgba[i * 4 + 3])) / 255;
        for (0..3) |ch| {
            const v = @as(f32, @floatFromInt(rgba[i * 4 + ch])) / 255;
            const blended = if (linear) scene.linearToSrgb(scene.srgbToLinear(v) * a + (1 - a)) else v * a + (1 - a);
            out[i * 4 + ch] = @intFromFloat(@round(blended * 255));
        }
        out[i * 4 + 3] = 255;
    }
    return out;
}

/// The share of pixels off by more than 24 of 255 in some channel.
fn differing(got: []const u8, want: []const u8) f32 {
    var off: usize = 0;
    for (0..size * size) |i| {
        var d: u8 = 0;
        for (0..3) |ch| d = @max(d, absDiff(got[i * 4 + ch], want[i * 4 + ch]));
        if (d > 24) off += 1;
    }
    return @as(f32, @floatFromInt(off)) / (size * size);
}

fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

fn writePair(dir: []const u8, rank: usize, theme: []const u8, got: []const u8, want: []const u8) !void {
    var both: [size * 2 * size * 4]u8 = undefined;
    for (0..size) |y| {
        @memcpy(both[y * size * 8 ..][0 .. size * 4], got[y * size * 4 ..][0 .. size * 4]);
        @memcpy(both[y * size * 8 + size * 4 ..][0 .. size * 4], want[y * size * 4 ..][0 .. size * 4]);
    }
    const bytes = try png.encode(gpa, size * 2, size, &both);
    defer gpa.free(bytes);
    var name: [512]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&name, "{s}/{s}-{d}.png", .{ dir, theme, rank }, 0);
    try writeFile(path, bytes);
}

/// rsvg-convert's rendering of `file` at the test size, straight-alpha
/// RGBA, or null when it fails.
fn rsvg(exe: [*:0]const u8, file: []const u8) !?[]u8 {
    var path: [4096]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&path, "{s}", .{file}, 0);
    const out_rc = linux.memfd_create("siv-icon-test", 0);
    if (linux.errno(out_rc) != .SUCCESS) return error.SpawnFailed;
    const out: i32 = @intCast(out_rc);
    defer _ = linux.close(out);
    const args = [_:null]?[*:0]const u8{ exe, "-w", "32", "-h", "32", "--keep-aspect-ratio", z, null };
    const env = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", "LC_ALL=C.UTF-8" };
    const devnull_rc = linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.SpawnFailed;
    if (rc == 0) {
        _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
        _ = linux.dup2(out, 1);
        if (linux.errno(devnull_rc) == .SUCCESS) _ = linux.dup2(@intCast(devnull_rc), 2);
        _ = linux.execve(exe, &args, &env);
        linux.exit_group(127);
    }
    if (linux.errno(devnull_rc) == .SUCCESS) _ = linux.close(@intCast(devnull_rc));
    var status: i32 = 0;
    while (true) {
        const w = linux.waitpid(@intCast(rc), &status, 0);
        if (linux.errno(w) != .INTR) break;
    }
    if (linux.W.EXITSTATUS(@bitCast(status)) != 0) return null;
    const len = linux.lseek(out, 0, linux.SEEK.END);
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    if (linux.pread(out, bytes.ptr, bytes.len, 0) != len) return null;
    const img = png.decode(gpa, bytes) catch return null;
    if (img.width != size or img.height != size) {
        img.deinit(gpa);
        return null;
    }
    return img.pixels;
}

fn listSvgs(dir: []const u8, out: *std.ArrayList([]u8), depth: u32) !void {
    if (depth > 4) return;
    var path: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&path, "{s}", .{dir}, 0) catch return;
    const rc = linux.open(z, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            off += ent.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (name[0] == '.') continue;
            const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
            // Symbolic links duplicate icons under other names.
            if (ent.type == linux.DT.DIR) {
                defer gpa.free(full);
                try listSvgs(full, out, depth + 1);
            } else if (ent.type == linux.DT.REG and std.mem.endsWith(u8, name, ".svg")) {
                try out.append(gpa, full);
            } else gpa.free(full);
        }
    }
}

fn readFile(path: []const u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0);
    const rc = linux.open(z, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const len = linux.lseek(fd, 0, linux.SEEK.END);
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    if (linux.pread(fd, out.ptr, out.len, 0) != len) return error.ReadFailed;
    return out;
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.write(fd, data.ptr, data.len) != data.len) return error.WriteFailed;
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
