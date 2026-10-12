//! ABI part of the build graph, called from build.zig: generated outputs,
//! libsiv.so link setup, the `siv` Zig module for dependents, and the ABI
//! tests. The ABI workstream owns this file.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    build_options: *std.Build.Module,
    test_filters: []const []const u8,
    /// The abi module; gets the generated wrapper as its `siv` import.
    abi: *std.Build.Module,
    shared: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
};

pub fn add(b: *std.Build, o: Options) void {
    // Generators (D3).
    const gen = b.addExecutable(.{
        .name = "siv-abi-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi/gen.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "build_options", .module = o.build_options }},
        }),
    });
    const gen_run = b.addRunArtifact(gen);
    const installed = gen_run.addOutputDirectoryArg("install");
    const private = gen_run.addOutputDirectoryArg("build");
    b.installDirectory(.{ .source_dir = installed, .install_dir = .prefix, .install_subdir = "" });

    const wrapper = b.addModule("siv", .{
        .root_source_file = installed.path(b, "share/siv/siv.zig"),
        .target = o.target,
        .optimize = o.optimize,
    });
    wrapper.linkLibrary(o.shared);
    o.abi.addImport("siv", b.createModule(.{ .root_source_file = installed.path(b, "share/siv/siv.zig") }));

    // libsiv.so exports exactly the schema's functions (D2). Zig 0.16's
    // self-hosted ELF linker ignores version scripts, so link with LLD.
    linkAbi(o.shared, private.path(b, "siv.map"));

    // The ABI test library: the same runtime and link setup with a test
    // schema that uses every construct. Built for tests only.
    const test_lib = b.addLibrary(.{
        .name = "siv-abitest",
        .linkage = .dynamic,
        .version = o.version,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi/test_lib.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .pic = true,
            .imports = &.{
                .{ .name = "sivtest", .module = b.createModule(.{ .root_source_file = private.path(b, "sivtest.zig") }) },
                .{ .name = "build_options", .module = o.build_options },
            },
        }),
    });
    linkAbi(test_lib, private.path(b, "sivtest.map"));

    const test_abi = b.step("test-abi", "Run the abi tests");
    const test_c = b.step("test-c", "Run the C ABI tests");

    const abi_tests = b.addTest(.{ .name = "abi", .root_module = o.abi, .filters = o.test_filters });
    test_abi.dependOn(&b.addRunArtifact(abi_tests).step);

    // Generator tests.
    const gen_tests = b.addTest(.{ .name = "abi-gen", .root_module = gen.root_module, .filters = o.test_filters });
    test_abi.dependOn(&b.addRunArtifact(gen_tests).step);

    // Exported symbols, versions, and SONAMEs.
    const check = b.addExecutable(.{
        .name = "siv-abi-check-exports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi/check_exports.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "build_options", .module = o.build_options }},
        }),
    });
    for ([_]struct { *std.Build.Step.Compile, []const u8 }{ .{ o.shared, "siv" }, .{ test_lib, "sivtest" } }) |entry| {
        const lib, const name = entry;
        const run = b.addRunArtifact(check);
        run.addArtifactArg(lib);
        run.addArg(name);
        run.addArg(b.fmt("lib{s}.so.{d}", .{ lib.name, o.version.major }));
        run.expectExitCode(0);
        test_abi.dependOn(&run.step);
    }

    // The Zig wrappers against the shared libraries, and their layouts
    // against the C headers.
    const translate = struct {
        fn module(bb: *std.Build, oo: Options, header: std.Build.LazyPath) *std.Build.Module {
            return bb.addTranslateC(.{ .root_source_file = header, .target = oo.target, .optimize = oo.optimize }).createModule();
        }
    }.module;
    const test_wrapper = b.createModule(.{
        .root_source_file = private.path(b, "sivtest.zig"),
        .target = o.target,
        .optimize = o.optimize,
    });
    test_wrapper.linkLibrary(test_lib);
    const wrapper_tests = b.addTest(.{
        .name = "abi-wrapper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi/wrapper_test.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "siv", .module = wrapper },
                .{ .name = "sivtest", .module = test_wrapper },
                .{ .name = "siv_h", .module = translate(b, o, installed.path(b, "include/siv.h")) },
                .{ .name = "sivtest_h", .module = translate(b, o, private.path(b, "sivtest.h")) },
            },
        }),
        .filters = o.test_filters,
    });
    test_abi.dependOn(&b.addRunArtifact(wrapper_tests).step);

    // C programs against the generated headers and the shared libraries.
    for ([_]struct { []const u8, *std.Build.Step.Compile, std.Build.LazyPath, ?std.Build.LazyPath }{
        .{ "test/c/smoke.c", o.shared, installed.path(b, "include"), null },
        .{ "test/c/abi.c", test_lib, private, null },
        .{ "test/c/app.c", o.shared, installed.path(b, "include"), b.path("src/text/testdata/DroidSans.ttf") },
    }) |entry| {
        const src, const lib, const include, const arg = entry;
        const exe = b.addExecutable(.{
            .name = std.fs.path.stem(src),
            .root_module = b.createModule(.{ .target = o.target, .optimize = o.optimize, .link_libc = true }),
        });
        exe.root_module.addCSourceFile(.{ .file = b.path(src), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic" } });
        exe.root_module.addIncludePath(include);
        exe.root_module.linkLibrary(lib);
        const run = b.addRunArtifact(exe);
        if (arg) |a| run.addFileArg(a);
        run.expectExitCode(0);
        test_c.dependOn(&run.step);
    }

    o.test_step.dependOn(test_abi);
    o.test_step.dependOn(test_c);
}

fn linkAbi(lib: *std.Build.Step.Compile, version_script: std.Build.LazyPath) void {
    lib.use_llvm = true;
    lib.use_lld = true;
    lib.setVersionScript(version_script);
}
