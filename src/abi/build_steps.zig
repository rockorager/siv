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
    /// The stock widgets (D22), which import only the generated wrapper.
    widgets: *std.Build.Module,
    shared: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    /// `zig build test-integration`: tests against headless sway.
    integration_step: *std.Build.Step,
    /// The headless test binary, which links C code that uses the
    /// generated header (test/abi/canvas.zig), and the step that runs it.
    headless: *std.Build.Step.Compile,
    test_headless: *std.Build.Step,
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
    const siv_module = b.createModule(.{ .root_source_file = installed.path(b, "share/siv/siv.zig") });
    o.abi.addImport("siv", siv_module);
    o.widgets.addImport("siv", siv_module);

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

    // The unit tests that need no siv (unit_tests.zig): the generators,
    // the schema, handles, descriptors, allocation hooks. The rest of the
    // abi module is tested through the C API in the headless test binary.
    const unit_tests = b.addTest(.{
        .name = "abi-unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi/unit_tests.zig"),
            .target = b.graph.host,
            .link_libc = true,
            .imports = &.{.{ .name = "build_options", .module = o.build_options }},
        }),
        .filters = o.test_filters,
    });
    test_abi.dependOn(&b.addRunArtifact(unit_tests).step);
    test_abi.dependOn(o.test_headless);

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

    // Example programs (examples/*.c): `zig build examples` installs them;
    // `zig build test` compiles them into the headless test binary with
    // main renamed, so they keep up with the API without a program each
    // (shell.c runs there too, below).
    const examples = b.step("examples", "Build the C example programs");
    for ([_][]const u8{ "hello", "todo", "embed", "gauge", "widgets", "shell" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{ .target = o.target, .optimize = o.optimize, .link_libc = true }),
        });
        exe.root_module.addCSourceFile(.{ .file = b.path(b.fmt("examples/{s}.c", .{name})), .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
        exe.root_module.addIncludePath(installed.path(b, "include"));
        exe.root_module.linkLibrary(o.shared);
        examples.dependOn(&b.addInstallArtifact(exe, .{}).step);
        if (!std.mem.eql(u8, name, "shell")) o.headless.root_module.addCSourceFile(.{
            .file = b.path(b.fmt("examples/{s}.c", .{name})),
            .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror", b.fmt("-Dmain=example_{s}_main", .{name}) },
        });
    }

    // C drawing code that the headless canvas tests call: it uses the
    // exports in the test binary itself.
    o.headless.root_module.addCSourceFile(.{ .file = b.path("test/c/canvas_scene.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    o.headless.root_module.addIncludePath(installed.path(b, "include"));
    // examples/shell.c, run unchanged on the headless backend by
    // test/abi/shell_example.zig (D31): main and the calls the test drives
    // or fakes (the backend, the run loop, the clock and its time zone, the
    // user, and libpam) renamed.
    o.headless.root_module.addCSourceFile(.{ .file = b.path("examples/shell.c"), .flags = &.{
        "-std=c11",                           "-D_POSIX_C_SOURCE=200809L",          "-Wall", "-Wextra", "-Werror",
        "-Dmain=shell_example_main",          "-Dsiv_app_create=shell_test_app_create", "-Dsiv_app_run=shell_test_app_run",
        "-Dtime=shell_test_time",             "-Dlocaltime_r=shell_test_localtime_r", "-Ddlopen=shell_test_dlopen",
        "-Ddlsym=shell_test_dlsym",           "-Ddlclose=shell_test_dlclose",       "-Dgetpwuid=shell_test_getpwuid",
    } });

    // A single-instance C application that the lifecycle integration test
    // launches, also through D-Bus activation (test/c/lifecycle.c).
    const lifecycle = b.addExecutable(.{
        .name = "lifecycle",
        .root_module = b.createModule(.{ .target = o.target, .optimize = o.optimize, .link_libc = true }),
    });
    lifecycle.root_module.addCSourceFile(.{ .file = b.path("test/c/lifecycle.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic" } });
    lifecycle.root_module.addIncludePath(installed.path(b, "include"));
    lifecycle.root_module.linkLibrary(o.shared);
    const helpers = b.addOptions();
    helpers.addOptionPath("lifecycle", lifecycle.getEmittedBin());
    helpers.addOptionPath("libsiv", o.shared.getEmittedBin());

    // The public API against sway (integration_tests.zig). Not in `test`.
    const integration = b.addTest(.{
        .name = "abi-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi/integration_tests.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "abi", .module = o.abi },
                .{ .name = "platform", .module = o.abi.import_table.get("platform").? },
                .{ .name = "compositor", .module = o.abi.import_table.get("compositor").? },
                .{ .name = "text", .module = o.abi.import_table.get("text").? },
                .{ .name = "loop", .module = o.abi.import_table.get("loop").? },
                .{ .name = "portal", .module = o.abi.import_table.get("portal").? },
                .{ .name = "helpers", .module = helpers.createModule() },
            },
        }),
        .filters = o.test_filters,
    });
    // examples/shell.c on sway (integration_shell.zig), renamed as for the
    // headless test above.
    integration.root_module.addCSourceFile(.{ .file = b.path("examples/shell.c"), .flags = &.{
        "-std=c11",                       "-D_POSIX_C_SOURCE=200809L",             "-Wall", "-Wextra", "-Werror",
        "-Dmain=shell_example_main",      "-Dsiv_app_create=shell_sway_app_create", "-Dsiv_app_run=shell_sway_app_run",
        "-Dtime=shell_sway_time",         "-Dlocaltime_r=shell_sway_localtime_r",  "-Ddlopen=shell_sway_dlopen",
        "-Ddlsym=shell_sway_dlsym",       "-Ddlclose=shell_sway_dlclose",          "-Dgetpwuid=shell_sway_getpwuid",
    } });
    integration.root_module.addIncludePath(installed.path(b, "include"));
    const integration_run = b.addRunArtifact(integration);
    integration_run.has_side_effects = true; // depends on the installed sway
    o.integration_step.dependOn(&integration_run.step);

    o.test_step.dependOn(test_abi);
    o.test_step.dependOn(test_c);
}

fn linkAbi(lib: *std.Build.Step.Compile, version_script: std.Build.LazyPath) void {
    lib.use_llvm = true;
    lib.use_lld = true;
    lib.setVersionScript(version_script);
}
