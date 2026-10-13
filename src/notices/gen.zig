//! Writes NOTICES (D25) and checks that it covers everything libsiv
//! ships; src/notices/build_steps.zig builds the arguments:
//!
//!   siv-notices <out> <siv-src-dir> {-e <title> <package|-> <url> {-f <file>}}
//!       {-p <package> <dir> {-s <sub-path>}}
//!
//! `-e` starts a NOTICES section and `-f` adds a licence file to it. `-p`
//! names a package compiled into libsiv, with the files and include
//! directories compiled from it (`-s`). It fails, writing nothing, when:
//!
//! - a package has no section;
//! - a section misses the licence nearest to one of its package's compiled
//!   files: the first directory, going up from the file to the package's
//!   root, with a LICENSE, LICENCE, or COPYING file must have one of them
//!   in the section, and every NOTICE file there (Apache-2.0 4(d));
//! - a licence file in siv's tree (LICENSE*, COPYING*, NOTICE*, *.lic.txt,
//!   outside testdata/ directories, which hold test-only data) is in no
//!   section.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Section = struct {
    title: []const u8,
    package: ?[]const u8,
    url: []const u8,
    files: std.ArrayList([]const u8) = .empty,
};

pub const Package = struct {
    name: []const u8,
    dir: []const u8,
    sources: std.ArrayList([]const u8) = .empty,
};

pub const Input = struct {
    src_dir: []const u8,
    sections: []const Section,
    packages: []const Package,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) usage(args[0]);
    var sections: std.ArrayList(Section) = .empty;
    var packages: std.ArrayList(Package) = .empty;
    var i: usize = 3;
    while (i < args.len) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "-e") and i + 3 < args.len) {
            const pkg = args[i + 2];
            try sections.append(arena, .{ .title = args[i + 1], .package = if (std.mem.eql(u8, pkg, "-")) null else pkg, .url = args[i + 3] });
            i += 4;
        } else if (std.mem.eql(u8, flag, "-f") and i + 1 < args.len and sections.items.len > 0) {
            try sections.items[sections.items.len - 1].files.append(arena, args[i + 1]);
            i += 2;
        } else if (std.mem.eql(u8, flag, "-p") and i + 2 < args.len) {
            try packages.append(arena, .{ .name = args[i + 1], .dir = args[i + 2] });
            i += 3;
        } else if (std.mem.eql(u8, flag, "-s") and i + 1 < args.len and packages.items.len > 0) {
            try packages.items[packages.items.len - 1].sources.append(arena, args[i + 1]);
            i += 2;
        } else usage(args[0]);
    }
    const input: Input = .{ .src_dir = args[2], .sections = sections.items, .packages = packages.items };

    const problems = try check(io, arena, input);
    if (problems.len > 0) {
        for (problems) |p| std.log.err("{s}", .{p});
        std.log.err("NOTICES is incomplete: add the licence to `entries` in src/notices/build_steps.zig (D25)", .{});
        std.process.exit(1);
    }
    var w: Io.Writer.Allocating = .init(arena);
    try write(io, arena, &w.writer, input);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = w.written() });
}

fn usage(arg0: []const u8) noreturn {
    std.log.err("usage: {s} <out> <siv-src-dir> {{-e <title> <package|-> <url> {{-f <file>}}}} {{-p <package> <dir> {{-s <sub-path>}}}}", .{arg0});
    std.process.exit(2);
}

const rule = "==============================================================================\n";

pub fn write(io: Io, gpa: Allocator, w: *Io.Writer, input: Input) !void {
    try w.writeAll(
        \\Notices for libsiv
        \\
        \\The licences of siv and of the software and data libsiv contains as
        \\built. Libraries linked from the system instead (-fsys) are not part
        \\of it and carry their own notices.
        \\
        \\
    );
    for (input.sections) |s| {
        try w.print(rule ++ "{s}\n", .{s.title});
        if (s.url.len > 0) try w.print("{s}\n", .{s.url});
        try w.writeAll(rule ++ "\n");
        for (s.files.items) |f| {
            const text = try Io.Dir.cwd().readFileAlloc(io, f, gpa, .limited(1 << 20));
            defer gpa.free(text);
            try w.writeAll(text);
            if (text.len > 0 and text[text.len - 1] != '\n') try w.writeByte('\n');
            try w.writeByte('\n');
        }
    }
}

/// What NOTICES misses, one line each.
pub fn check(io: Io, arena: Allocator, input: Input) ![]const []const u8 {
    const cwd = Io.Dir.cwd();
    var problems: std.ArrayList([]const u8) = .empty;
    var listed: std.array_hash_map.String(void) = .empty;
    for (input.sections) |s| for (s.files.items) |f| {
        const real = cwd.realPathFileAlloc(io, f, arena) catch |err| {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}: {t}", .{ s.title, f, err }));
            continue;
        };
        try listed.put(arena, real, {});
    };

    for (input.packages) |p| {
        const section = for (input.sections) |s| {
            if (s.package) |name| if (std.mem.eql(u8, name, p.name)) break s;
        } else {
            try problems.append(arena, try std.fmt.allocPrint(arena, "package {s} is compiled into libsiv but has no licence entry", .{p.name}));
            continue;
        };
        const root = try cwd.realPathFileAlloc(io, p.dir, arena);
        var seen: std.array_hash_map.String(void) = .empty;
        for (p.sources.items) |sub| {
            const full = try std.fs.path.join(arena, &.{ root, sub });
            const start = if (isDir(io, full)) full else std.fs.path.dirname(full).?;
            var dir: []const u8 = start;
            while (true) {
                if ((try seen.getOrPut(arena, dir)).found_existing) break;
                const found = try licencesIn(io, arena, dir);
                if (found.licences.len > 0) {
                    for (found.notices) |n| if (listed.get(n) == null)
                        try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s} is not in NOTICES (needed for {s})", .{ p.name, n, sub }));
                    for (found.licences) |l| {
                        if (listed.get(l) != null) break;
                    } else try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: none of {s}'s licence files is in NOTICES (needed for {s})", .{ p.name, dir, sub }));
                    break;
                }
                if (std.mem.eql(u8, dir, root)) {
                    if (section.files.items.len == 0)
                        try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: no licence file found or listed (needed for {s})", .{ p.name, sub }));
                    break;
                }
                dir = std.fs.path.dirname(dir) orelse break;
            }
        }
    }

    var src = try cwd.openDir(io, input.src_dir, .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind == .directory and std.mem.eql(u8, e.basename, "testdata")) {
            walker.leave(io);
            continue;
        }
        if (e.kind != .file or !(isLicence(e.basename) or isNotice(e.basename) or std.mem.endsWith(u8, e.basename, ".lic.txt"))) continue;
        const real = try e.dir.realPathFileAlloc(io, e.basename, arena);
        if (listed.get(real) == null)
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}/{s} is in siv's tree but not in NOTICES", .{ input.src_dir, e.path }));
    }
    return problems.items;
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn hasPrefixIgnoreCase(name: []const u8, prefix: []const u8) bool {
    return name.len >= prefix.len and std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix);
}

fn isLicence(name: []const u8) bool {
    return hasPrefixIgnoreCase(name, "LICENSE") or hasPrefixIgnoreCase(name, "LICENCE") or hasPrefixIgnoreCase(name, "COPYING");
}

fn isNotice(name: []const u8) bool {
    return hasPrefixIgnoreCase(name, "NOTICE");
}

const Found = struct { licences: []const []const u8, notices: []const []const u8 };

/// The licence and NOTICE files directly in `dir`, as real paths.
fn licencesIn(io: Io, arena: Allocator, dir: []const u8) !Found {
    var licences: std.ArrayList([]const u8) = .empty;
    var notices: std.ArrayList([]const u8) = .empty;
    var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        const list = if (isLicence(e.name)) &licences else if (isNotice(e.name)) &notices else continue;
        try list.append(arena, try d.realPathFileAlloc(io, e.name, arena));
    }
    return .{ .licences = licences.items, .notices = notices.items };
}

const testing = std.testing;

fn fixture(tmp: *testing.TmpDir) !void {
    const io = testing.io;
    try tmp.dir.createDirPath(io, "src/text/testdata");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/text/testdata/LICENSE-Font.txt", .data = "test only" });
    try tmp.dir.createDirPath(io, "pkg/src");
    try tmp.dir.createDirPath(io, "pkg/third_party/yuv/source");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/LICENSE", .data = "pkg licence" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/NOTICE", .data = "pkg notice" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/a.c", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/third_party/yuv/LICENSE", .data = "yuv licence" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/third_party/yuv/source/scale.c", .data = "" });
}

fn sources(arena: Allocator, items: []const []const u8) !std.ArrayList([]const u8) {
    var l: std.ArrayList([]const u8) = .empty;
    try l.appendSlice(arena, items);
    return l;
}

test "a compiled package without a licence entry fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try fixture(&tmp);
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const src = try std.fs.path.join(arena, &.{ root, "src" });
    const pkg = try std.fs.path.join(arena, &.{ root, "pkg" });
    const packages = [_]Package{.{ .name = "pkg", .dir = pkg, .sources = try sources(arena, &.{"src/a.c"}) }};

    const none = try check(testing.io, arena, .{ .src_dir = src, .sections = &.{}, .packages = &packages });
    try testing.expectEqual(1, none.len);
    try testing.expect(std.mem.indexOf(u8, none[0], "package pkg") != null);

    // With its licence and NOTICE, it passes; test data needs no entry.
    var section: Section = .{ .title = "pkg", .package = "pkg", .url = "" };
    try section.files.append(arena, try std.fs.path.join(arena, &.{ pkg, "LICENSE" }));
    const no_notice = try check(testing.io, arena, .{ .src_dir = src, .sections = &.{section}, .packages = &packages });
    try testing.expectEqual(1, no_notice.len);
    try testing.expect(std.mem.indexOf(u8, no_notice[0], "NOTICE") != null);
    try section.files.append(arena, try std.fs.path.join(arena, &.{ pkg, "NOTICE" }));
    try testing.expectEqual(0, (try check(testing.io, arena, .{ .src_dir = src, .sections = &.{section}, .packages = &packages })).len);

    // A library bundled with a licence of its own needs that licence too.
    const bundled = [_]Package{.{ .name = "pkg", .dir = pkg, .sources = try sources(arena, &.{ "src/a.c", "third_party/yuv/source/scale.c" }) }};
    const yuv = try check(testing.io, arena, .{ .src_dir = src, .sections = &.{section}, .packages = &bundled });
    try testing.expectEqual(1, yuv.len);
    try testing.expect(std.mem.indexOf(u8, yuv[0], "yuv") != null);
}

test "licence files in siv's tree must be listed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try fixture(&tmp);
    try tmp.dir.createDirPath(testing.io, "src/text/hyphenation");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/text/hyphenation/hyph-xx.lic.txt", .data = "patterns licence" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const src = try std.fs.path.join(arena, &.{ root, "src" });

    const missing = try check(testing.io, arena, .{ .src_dir = src, .sections = &.{}, .packages = &.{} });
    try testing.expectEqual(1, missing.len);
    try testing.expect(std.mem.indexOf(u8, missing[0], "hyph-xx.lic.txt") != null);

    var section: Section = .{ .title = "patterns", .package = null, .url = "" };
    try section.files.append(arena, try std.fs.path.join(arena, &.{ src, "text/hyphenation/hyph-xx.lic.txt" }));
    try testing.expectEqual(0, (try check(testing.io, arena, .{ .src_dir = src, .sections = &.{section}, .packages = &.{} })).len);

    var out: Io.Writer.Allocating = .init(arena);
    try write(testing.io, arena, &out.writer, .{ .src_dir = src, .sections = &.{section}, .packages = &.{} });
    try testing.expect(std.mem.indexOf(u8, out.written(), "patterns\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "patterns licence\n") != null);
}
