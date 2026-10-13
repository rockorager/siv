//! Build graph of the user guide's samples (docs/guide), called from
//! build.zig after the ABI and Lua steps.
//!
//!   zig build guide       builds every sample as a program against
//!                         libsiv.so (installed as zig-out/bin/guide-*),
//!                         runs them all on the headless backend, compares
//!                         their windows with the guide's screenshots in
//!                         docs/guide/images, and checks that every code
//!                         block in the guide is quoted from a sample
//!
//! `zig build test` runs the same, without installing. To accept new
//! screenshots: SIV_UPDATE_GOLDEN=1 zig build guide
//!
//! Samples are ordinary programs. To run them in the test binary, the C
//! ones are compiled a second time with their main renamed and four
//! functions (siv_app_create, siv_window_create, siv_app_run,
//! siv_app_dispatch) renamed to the harness's guide_* versions, which
//! pick the headless backend and drive the scenario; the Zig ones import
//! a copy of the generated wrapper with the same four functions renamed
//! (tests/shim.zig); the Lua ones run through the binding with
//! app_create wrapped, as the Lua examples' tests do.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_filters: []const []const u8,
    /// The abi module: its exports are compiled into the test binary.
    abi: *std.Build.Module,
    /// libsiv.so, which the sample programs link.
    shared: *std.Build.Step.Compile,
    /// The headless tests, whose `lua` import is the binding compiled
    /// against the exports in a test binary.
    headless: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
};

/// C samples (examples/<name>.c), each `int main(void)` or
/// `int main(int argc, char **argv)`.
pub const c_samples = [_][]const u8{
    "hello",  "model", "layout", "menus",     "events", "segmented", "images",
    "table",  "jobs",  "watch",  "clipboard", "embed",  "video",     "print",
    "launch",
};

/// Zig samples (examples/<name>.zig), each `pub fn main() !void`.
pub const zig_samples = [_][]const u8{
    "hello", "settings", "chart",
};

pub fn add(b: *std.Build, o: Options) void {
    const guide = b.step("guide", "Build the user guide's samples and check them and its screenshots (docs/guide)");
    const checks = b.step("guide-check", "Build and check the user guide's samples without installing them");
    guide.dependOn(checks);
    o.test_step.dependOn(checks);

    const wrapper = b.modules.get("siv") orelse @panic("src/abi/build_steps.zig must run first");
    // The generated headers: <prefix>/include, next to share/siv/siv.zig.
    const include = wrapper.root_source_file.?.dirname().dirname().dirname().path(b, "include");
    const c_flags = [_][]const u8{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" };

    // The samples as programs against libsiv.so.
    for (c_samples) |name| {
        const exe = b.addExecutable(.{
            .name = b.fmt("guide-{s}", .{name}),
            .root_module = b.createModule(.{ .target = o.target, .optimize = o.optimize, .link_libc = true }),
        });
        exe.root_module.addCSourceFile(.{ .file = b.path(b.fmt("docs/guide/examples/{s}.c", .{name})), .flags = &c_flags });
        exe.root_module.addIncludePath(include);
        exe.root_module.linkLibrary(o.shared);
        exe.root_module.linkSystemLibrary("m", .{});
        exe.root_module.addRPathSpecial("$ORIGIN/../lib");
        checks.dependOn(&exe.step);
        guide.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    for (zig_samples) |name| {
        const exe = b.addExecutable(.{
            .name = b.fmt("guide-{s}-zig", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("docs/guide/examples/{s}.zig", .{name})),
                .target = o.target,
                .optimize = o.optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "siv", .module = wrapper }},
            }),
        });
        exe.root_module.addRPathSpecial("$ORIGIN/../lib");
        checks.dependOn(&exe.step);
        guide.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    // The testing chapter's test, a program against libsiv.so that drives
    // its window through the public test API with no harness around it.
    const test_exe = b.addExecutable(.{
        .name = "guide-counter_test",
        .root_module = b.createModule(.{ .target = o.target, .optimize = o.optimize, .link_libc = true }),
    });
    test_exe.root_module.addCSourceFile(.{ .file = b.path("docs/guide/examples/counter_test.c"), .flags = &c_flags });
    test_exe.root_module.addIncludePath(include);
    test_exe.root_module.linkLibrary(o.shared);
    test_exe.root_module.addRPathSpecial("$ORIGIN/../lib");
    guide.dependOn(&b.addInstallArtifact(test_exe, .{}).step);
    const run_test = b.addRunArtifact(test_exe);
    run_test.addFileArg(b.path("src/text/testdata/DroidSans.ttf"));
    run_test.expectExitCode(0);
    checks.dependOn(&run_test.step);

    // The Zig package sample's program, against the `siv` module as the
    // package gets it. Its build script is not run here: building siv as
    // a dependency fetches and compiles siv's dependencies again.
    const package_exe = b.addExecutable(.{
        .name = "guide-zig-package",
        .root_module = b.createModule(.{
            .root_source_file = b.path("docs/guide/examples/zig-package/src/main.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "siv", .module = wrapper }},
        }),
    });
    checks.dependOn(&package_exe.step);

    // The test binary: the exports, the harness, and every sample.
    const get = struct {
        fn f(m: *std.Build.Module, name: []const u8) *std.Build.Module {
            return m.import_table.get(name) orelse std.debug.panic("no import {s}", .{name});
        }
    }.f;
    const unlinked = get(o.abi, "siv");
    const shim_tool = b.addExecutable(.{
        .name = "guide-shim",
        .root_module = b.createModule(.{ .root_source_file = b.path("docs/guide/tests/shim.zig"), .target = b.graph.host }),
    });
    const shim_run = b.addRunArtifact(shim_tool);
    shim_run.addFileArg(unlinked.root_source_file.?);
    const shim = b.createModule(.{ .root_source_file = shim_run.addOutputFileArg("siv.zig") });

    const root = b.createModule(.{
        .root_source_file = b.path("docs/guide/tests/guide.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "abi", .module = o.abi },
            .{ .name = "siv", .module = unlinked },
            .{ .name = "lua", .module = get(o.headless.root_module, "lua") },
            .{ .name = "png", .module = b.createModule(.{ .root_source_file = b.path("test/render/png.zig") }) },
            // The test fonts' bytes.
            .{ .name = "text", .module = get(o.abi, "text") },
        },
    });
    for (c_samples) |name| {
        const main = b.fmt("-Dmain=guide_main_{s}", .{name});
        root.addCSourceFile(.{
            .file = b.path(b.fmt("docs/guide/examples/{s}.c", .{name})),
            .flags = &(c_flags ++ [_][]const u8{
                main,
                "-Dsiv_app_create=guide_app_create",
                "-Dsiv_window_create=guide_window_create",
                "-Dsiv_app_run=guide_app_run",
                "-Dsiv_app_dispatch=guide_app_dispatch",
            }),
        });
    }
    root.addIncludePath(include);
    for (zig_samples) |name| {
        root.addImport(b.fmt("zig_{s}", .{name}), b.createModule(.{
            .root_source_file = b.path(b.fmt("docs/guide/examples/{s}.zig", .{name})),
            .imports = &.{.{ .name = "siv", .module = shim }},
        }));
    }
    const tests = b.addTest(.{ .name = "guide", .root_module = root, .filters = o.test_filters });
    const run = b.addRunArtifact(tests);
    run.setCwd(b.path("."));
    // It reads the chapters, samples, and screenshots, which the build
    // does not track as inputs.
    run.has_side_effects = true;
    checks.dependOn(&run.step);
}
