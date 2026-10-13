//! NOTICES part of the build graph (D25), called from build.zig: the
//! licence texts of everything compiled into libsiv for the chosen build
//! options, installed as share/licenses/siv/NOTICES.
//!
//! What ships is found, not listed: the build walks libsiv's module graph
//! (root sources, C and assembly sources, include directories of modules
//! that compile C, imports, and the steps that generate any of those,
//! including the tools those steps run) and records which packages of
//! build.zig.zon it reaches and which of their files are compiled.
//! `-fsys` libraries are linked, not compiled, so they drop out by
//! themselves. `entries` below gives each package's licence files;
//! src/notices/gen.zig writes NOTICES from them and fails when a reached
//! package has no entry, when an entry misses the licence file nearest to
//! a compiled file (a bundled library with its own licence), or when a
//! licence file in siv's own tree (outside testdata/) is in no entry.

const std = @import("std");
const zon = @import("../../build.zig.zon");

pub const Options = struct {
    /// libsiv's root module.
    root: *std.Build.Module,
    test_step: *std.Build.Step,
};

/// One section of NOTICES. Files are relative to the package's root, siv's
/// root (`siv_files`), or Zig's lib directory (`zig_files`).
const Entry = struct {
    title: []const u8,
    /// The build.zig.zon dependency; null for siv itself, data in siv's
    /// tree, and Zig's runtime, which always ship.
    package: ?[]const u8 = null,
    files: []const []const u8 = &.{},
    siv_files: []const []const u8 = &.{},
    zig_files: []const []const u8 = &.{},
    /// Only when a module compiled into libsiv links libc++.
    libcpp: bool = false,
};

const hyphenation = [_][]const u8{
    "src/text/hyphenation/README.md",
    "src/text/hyphenation/hyph-en-us.lic.txt",
    "src/text/hyphenation/hyph-en-gb.lic.txt",
    "src/text/hyphenation/hyph-de-1996.lic.txt",
    "src/text/hyphenation/hyph-fr.lic.txt",
    "src/text/hyphenation/hyph-es.lic.txt",
    "src/text/hyphenation/hyph-nl.lic.txt",
    "src/text/hyphenation/hyph-pt.lic.txt",
    "src/text/hyphenation/hyph-pl.lic.txt",
    "src/text/hyphenation/hyph-uk.lic.txt",
    "src/text/hyphenation/hyph-sk.lic.txt",
    "src/text/hyphenation/LICENSE-MIT.txt",
};

const entries = [_]Entry{
    .{ .title = "siv (MIT)", .siv_files = &.{"LICENSE"} },
    .{ .title = "Zig standard library, compiler-rt, and UBSan runtime (MIT)", .siv_files = &.{"src/notices/zig-LICENSE.txt"} },
    .{ .title = "LLVM libc++ (Apache-2.0 WITH LLVM-exception)", .zig_files = &.{"libcxx/LICENSE.TXT"}, .libcpp = true },
    .{ .title = "LLVM libc++abi (Apache-2.0 WITH LLVM-exception)", .zig_files = &.{"libcxxabi/LICENSE.TXT"}, .libcpp = true },
    .{ .title = "LLVM libunwind (Apache-2.0 WITH LLVM-exception)", .zig_files = &.{"libunwind/LICENSE.TXT"}, .libcpp = true },
    .{ .title = "HarfBuzz (MIT)", .package = "harfbuzz", .files = &.{"COPYING"} },
    .{ .title = "SheenBidi (Apache-2.0)", .package = "sheenbidi", .files = &.{"LICENSE"} },
    .{ .title = "uucode (MIT)", .package = "uucode", .files = &.{"LICENSE.md"} },
    .{ .title = "Unicode Character Database (Unicode License v3)", .package = "ucd", .siv_files = &.{"src/notices/unicode-LICENSE.txt"} },
    .{ .title = "Wuffs (MIT and Apache-2.0)", .package = "wuffs", .files = &.{"LICENSE"} },
    .{ .title = "Little CMS (MIT)", .package = "lcms2", .files = &.{"LICENSE"} },
    .{ .title = "libwebp (BSD-3-Clause, with a patent grant)", .package = "libwebp", .files = &.{ "COPYING", "PATENTS" } },
    .{ .title = "dav1d (BSD-2-Clause)", .package = "dav1d", .files = &.{"COPYING"} },
    .{ .title = "libavif and the libyuv it bundles (BSD-2-Clause, BSD-3-Clause)", .package = "libavif", .files = &.{"LICENSE"} },
    .{ .title = "libjxl (BSD-3-Clause, with a patent grant)", .package = "libjxl", .files = &.{ "LICENSE", "PATENTS" } },
    .{ .title = "Highway (BSD-3-Clause, chosen of Apache-2.0 or BSD-3-Clause)", .package = "highway", .files = &.{"LICENSE-BSD3"} },
    .{ .title = "zig-wayland (MIT)", .package = "wayland", .files = &.{"LICENSE"} },
    .{ .title = "Wayland protocol (MIT)", .package = "wayland_core", .files = &.{"COPYING"} },
    .{ .title = "wayland-protocols (MIT)", .package = "wayland_protocols", .files = &.{"COPYING"} },
    .{ .title = "Hyphenation patterns from hyph-utf8 (MIT, BSD-3-Clause, FSF all-permissive)", .siv_files = &hyphenation },
};

/// Packages whose tools run at build time and whose output is not derived
/// from them: NASM assembles dav1d, glslang compiles siv's shaders.
const build_only = [_][]const u8{ "nasm", "glslang" };

pub fn add(b: *std.Build, o: Options) void {
    var walk: Walk = .{ .b = b };
    walk.module(o.root);

    const gen = b.addExecutable(.{
        .name = "siv-notices",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/notices/gen.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(gen);
    // It also reads siv's tree for licence files, which Run does not hash.
    run.has_side_effects = true;
    const notices = run.addOutputFileArg("NOTICES");
    run.addDirectoryArg(b.path("src"));
    for (entries) |e| {
        if (e.libcpp and !walk.libcpp) continue;
        if (e.package) |p| if (walk.packages.get(p) == null) continue;
        const url = if (e.package) |p| urlOf(p) else "";
        run.addArgs(&.{ "-e", e.title, e.package orelse "-", url });
        for (e.siv_files) |f| addFile(run, b.path(f));
        for (e.zig_files) |f| addFile(run, std.Build.LazyPath.zig_lib.path(b, f));
        if (e.package) |p| for (e.files) |f| addFile(run, walk.packages.get(p).?.builder.path(f));
    }
    for (walk.packages.keys(), walk.packages.values()) |name, pkg| {
        if (isBuildOnly(name)) continue;
        run.addArgs(&.{ "-p", name });
        run.addDirectoryArg(pkg.builder.path(""));
        for (pkg.sources.keys()) |s| run.addArgs(&.{ "-s", s });
    }
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(notices, .prefix, "share/licenses/siv/NOTICES").step);
    // For packages that depend on siv and ship libsiv.so.
    b.addNamedLazyPath("notices", notices);
    o.test_step.dependOn(&run.step);

    const t = b.addTest(.{ .name = "notices", .root_module = gen.root_module });
    const t_run = b.addRunArtifact(t);
    const step = b.step("test-notices", "Check NOTICES and run its generator's tests");
    step.dependOn(&t_run.step);
    step.dependOn(&run.step);
    o.test_step.dependOn(&t_run.step);
}

fn addFile(run: *std.Build.Step.Run, path: std.Build.LazyPath) void {
    run.addArg("-f");
    run.addFileArg(path);
}

fn isBuildOnly(name: []const u8) bool {
    for (build_only) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn urlOf(name: []const u8) []const u8 {
    inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".field_names) |f| {
        if (std.mem.eql(u8, f, name)) return @field(zon.dependencies, f).url;
    }
    return "";
}

/// A package's name in build.zig.zon, else its place among dependencies'
/// dependencies.
fn nameOf(owner: *std.Build) []const u8 {
    inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".field_names) |f| {
        if (std.mem.eql(u8, @field(zon.dependencies, f).hash, owner.pkg_hash)) return f;
    }
    return std.mem.trimEnd(u8, owner.dep_prefix, ".");
}

const Package = struct {
    builder: *std.Build,
    /// Compiled files and include directories, relative to its root.
    sources: std.array_hash_map.String(void) = .empty,
};

const Walk = struct {
    b: *std.Build,
    packages: std.array_hash_map.String(Package) = .empty,
    modules: std.AutoArrayHashMapUnmanaged(*std.Build.Module, void) = .empty,
    steps: std.AutoArrayHashMapUnmanaged(*std.Build.Step, void) = .empty,
    libcpp: bool = false,

    fn module(w: *Walk, m: *std.Build.Module) void {
        if ((w.modules.getOrPut(w.b.allocator, m) catch @panic("OOM")).found_existing) return;
        if (m.link_libcpp == true) w.libcpp = true;
        if (m.root_source_file) |p| w.path(p);
        var compiles_c = false;
        for (m.link_objects.items) |lo| switch (lo) {
            .c_source_file => |f| {
                compiles_c = true;
                w.path(f.file);
            },
            .c_source_files => |fs| {
                compiles_c = true;
                for (fs.files) |f| w.path(fs.root.path(w.b, f));
            },
            .assembly_file, .static_path => |p| w.path(p),
            .other_step => |c| w.module(c.root_module),
            .system_lib, .win32_resource_file => {},
        };
        // Headers of a package may carry its code (wuffs is one file).
        if (compiles_c) for (m.include_dirs.items) |d| switch (d) {
            .path, .path_system, .path_after, .embed_path => |p| w.path(p),
            .other_step => |c| w.module(c.root_module),
            else => {},
        };
        for (m.import_table.values()) |i| w.module(i);
    }

    fn path(w: *Walk, p: std.Build.LazyPath) void {
        switch (p) {
            .src_path => |s| w.file(s.owner, s.sub_path),
            .dependency => |d| w.file(d.dependency.builder, d.sub_path),
            .generated => |g| w.step(w.b.graph.generated_files.items[@backingInt(g.index)]),
            .cwd_relative, .relative => {},
        }
    }

    fn file(w: *Walk, owner: *std.Build, sub_path: []const u8) void {
        // siv's own, also when siv is a dependency of another package
        // (its builder then has a hash and a name in that package).
        if (owner == w.b) return;
        const gpa = w.b.allocator;
        const name = nameOf(owner);
        const entry = w.packages.getOrPut(gpa, name) catch @panic("OOM");
        if (!entry.found_existing) entry.value_ptr.* = .{ .builder = owner };
        entry.value_ptr.sources.put(gpa, sub_path, {}) catch @panic("OOM");
    }

    /// What a generated file is made from: a tool's sources (zig-wayland's
    /// scanner copies its own code into the bindings) and its inputs.
    fn step(w: *Walk, s: *std.Build.Step) void {
        if ((w.steps.getOrPut(w.b.allocator, s) catch @panic("OOM")).found_existing) return;
        if (s.cast(std.Build.Step.Run)) |run| {
            for (run.argv.items) |arg| switch (arg) {
                .artifact => |a| w.module(a.artifact.root_module),
                .lazy_path, .decorated_directory => |d| w.path(d.lazy_path),
                .file_content => |c| w.path(c.lazy_path),
                else => {},
            };
        } else if (s.cast(std.Build.Step.Compile)) |c| {
            w.module(c.root_module);
        } else if (s.cast(std.Build.Step.WriteFile)) |wf| {
            for (wf.copies.items) |c| w.path(c.src_file);
            for (wf.directories.items) |d| w.path(d.src_path);
        }
        // TranslateC: declarations of headers, whose code ships (or is
        // linked) through the module's C sources.
    }
};
