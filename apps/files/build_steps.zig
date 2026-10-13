//! Build graph of the file manager (apps/files), called from build.zig
//! after the ABI steps, whose `siv` wrapper module it uses.
//!
//!   zig build files           zig-out/bin/siv-files
//!   zig build run-files -- [FOLDER] [options]
//!   zig build test-files      unit and headless tests (also in `zig build test`)
//!   zig build test-integration-files  on headless sway with AT-SPI (also in
//!                             `zig build test-integration`)
//!   zig build bench-files     startup, memory, idle wakeups, and scrolling
//!                             a 100 000-entry folder (-Doptimize=ReleaseFast)
//!
//! The application imports only `siv`, the generated wrapper of the C ABI,
//! as src/widgets does (D22). Its tests also import siv's internals, for
//! the headless backend's input injection and frame capture.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_filters: []const []const u8,
    /// The abi module: its exports are compiled into the test binaries.
    abi: *std.Build.Module,
    test_step: *std.Build.Step,
    integration_step: *std.Build.Step,
};

pub fn add(b: *std.Build, o: Options) void {
    // The wrapper that src/abi/build_steps.zig registers, linked against
    // libsiv.so.
    const wrapper = b.modules.get("siv").?;
    const exe = b.addExecutable(.{
        .name = "siv-files",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/files/src/main.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "siv", .module = wrapper }},
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    b.step("files", "Build the file manager (apps/files)").dependOn(&install.step);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run-files", "Run the file manager").dependOn(&run.step);

    // For tests: the wrapper module the abi module uses, not linked, so
    // that its declarations resolve to the exports compiled into the test
    // binary (a file belongs to one module per compilation).
    const unlinked = o.abi.import_table.get("siv").?;
    const files = b.createModule(.{
        .root_source_file = b.path("apps/files/src/Files.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "siv", .module = unlinked }},
    });
    const png = b.createModule(.{ .root_source_file = b.path("test/render/png.zig") });
    const get = struct {
        fn f(abi: *std.Build.Module, name: []const u8) *std.Build.Module {
            return abi.import_table.get(name).?;
        }
    }.f;
    const test_imports = [_]std.Build.Module.Import{
        .{ .name = "abi", .module = o.abi },
        .{ .name = "files", .module = files },
        .{ .name = "siv", .module = unlinked },
        .{ .name = "png", .module = png },
        .{ .name = "platform", .module = get(o.abi, "platform") },
        .{ .name = "compositor", .module = get(o.abi, "compositor") },
        .{ .name = "loop", .module = get(o.abi, "loop") },
        .{ .name = "text", .module = get(o.abi, "text") },
        .{ .name = "ui", .module = get(o.abi, "ui") },
    };
    const test_files = b.step("test-files", "Run the file manager's tests");
    const headless = b.addTest(.{
        .name = "files-headless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/files/tests/headless.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .imports = &test_imports,
        }),
        .filters = o.test_filters,
    });
    test_files.dependOn(&b.addRunArtifact(headless).step);

    // On headless sway with AT-SPI: part of test-integration.
    var integration_imports: [test_imports.len + 1]std.Build.Module.Import = undefined;
    @memcpy(integration_imports[0..test_imports.len], &test_imports);
    integration_imports[test_imports.len] = .{ .name = "dbus", .module = get(get(o.abi, "app"), "dbus") };
    const integration = b.addTest(.{
        .name = "files-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/files/tests/integration.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .imports = &integration_imports,
        }),
        .filters = o.test_filters,
    });
    const integration_run = b.addRunArtifact(integration);
    integration_run.has_side_effects = true; // depends on the installed sway, dbus-daemon, at-spi2-core
    b.step("test-integration-files", "Run the file manager on headless sway with AT-SPI").dependOn(&integration_run.step);
    o.integration_step.dependOn(&integration_run.step);

    // Measurements: not part of any test step.
    const bench = b.addExecutable(.{
        .name = "files-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/files/tests/bench.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .imports = &test_imports,
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    bench_run.has_side_effects = true;
    b.step("bench-files", "Measure the file manager (startup, memory, idle, scrolling 100k entries)").dependOn(&bench_run.step);
    o.test_step.dependOn(test_files);
    // The executable compiles with every `zig build test`, so it keeps up
    // with the API.
    o.test_step.dependOn(&exe.step);
}
