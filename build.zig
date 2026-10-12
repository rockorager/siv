//! Build graph for libsiv. See AGENTS.md for module ownership.
//!
//! Steps:
//!   zig build                 libsiv.so, libsiv.a, include/siv.h, siv.pc
//!   zig build test            every module's tests, the headless tests, and
//!                             the C ABI smoke test
//!   zig build test-<module>   one module's tests (e.g. test-text)
//!   zig build test-headless   the headless integration tests
//!
//! Options:
//!   -Dtest-filter=<text>      only run tests whose name contains <text>
//!   -fsys=harfbuzz            link the system HarfBuzz instead of building it
//!   -fsys=sheenbidi           link the system SheenBidi instead of building it
//!
//! libwayland-client, xkbcommon, and Fontconfig are always system libraries.

const std = @import("std");
const Scanner = @import("wayland").Scanner;
const zon = @import("build.zig.zon");
const wayland_protocols = @import("src/platform/protocols.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests whose name does not contain this text") orelse &.{};
    const version = std.SemanticVersion.parse(zon.version) catch @panic("bad version in build.zig.zon");

    const ctx: Ctx = .{ .b = b, .target = target, .optimize = optimize };

    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "version", version);
    const build_options = options.createModule();

    // C and external dependencies. Each C library is a module that carries
    // both its translated header and, when vendored, its compiled sources, so
    // that it lands in every artifact that imports it, including libsiv.a.
    const harfbuzz = harfbuzzModule(ctx);
    const sheenbidi = sheenbidiModule(ctx);
    const fontconfig = systemCModule(ctx, "fontconfig", "#include <fontconfig/fontconfig.h>\n");
    const xkbcommon = systemCModule(ctx, "xkbcommon",
        \\#include <xkbcommon/xkbcommon.h>
        \\#include <xkbcommon/xkbcommon-compose.h>
        \\
    );
    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = b.path("src/text/uucode_config.zig"),
    });
    const uucode = uucode_dep.module("uucode");
    const wayland = waylandModule(ctx);
    const ucd = b.dependency("ucd", .{});

    // siv modules. Imports between them are the allowed dependency edges;
    // see AGENTS.md before adding one.
    const raster = ctx.module("src/raster/raster.zig", &.{});
    const scene = ctx.module("src/scene/scene.zig", &.{
        .{ .name = "raster", .module = raster },
    });
    const text = ctx.module("src/text/text.zig", &.{
        .{ .name = "raster", .module = raster },
        .{ .name = "harfbuzz", .module = harfbuzz },
        .{ .name = "sheenbidi", .module = sheenbidi },
        .{ .name = "fontconfig", .module = fontconfig },
        .{ .name = "uucode", .module = uucode },
    });
    const render_cpu = ctx.module("src/render/cpu/cpu.zig", &.{
        .{ .name = "scene", .module = scene },
        .{ .name = "raster", .module = raster },
        .{ .name = "text", .module = text },
        .{ .name = "harfbuzz", .module = harfbuzz },
    });
    const loop = ctx.module("src/loop/loop.zig", &.{});
    const platform = ctx.module("src/platform/platform.zig", &.{
        .{ .name = "loop", .module = loop },
        .{ .name = "wayland", .module = wayland },
        .{ .name = "xkbcommon", .module = xkbcommon },
    });
    const internal = [_]std.Build.Module.Import{
        .{ .name = "scene", .module = scene },
        .{ .name = "raster", .module = raster },
        .{ .name = "text", .module = text },
        .{ .name = "render_cpu", .module = render_cpu },
        .{ .name = "loop", .module = loop },
        .{ .name = "platform", .module = platform },
    };
    const abi = ctx.module("src/abi/abi.zig", &internal);
    abi.addImport("build_options", build_options);

    // Unicode conformance data for the text tests, embedded with
    // @embedFile("<name>"). Property files can be added the same way.
    for ([_][]const u8{
        "auxiliary/GraphemeBreakTest.txt",
        "auxiliary/WordBreakTest.txt",
        "auxiliary/LineBreakTest.txt",
        "BidiTest.txt",
        "BidiCharacterTest.txt",
    }) |sub_path| {
        text.addAnonymousImport(std.fs.path.basename(sub_path), .{ .root_source_file = ucd.path(sub_path) });
    }
    // Property files that src/text/uucode_config.zig compiles into uucode's
    // tables (Line_Break, Word_Break, Script, Script_Extensions). The table
    // generator embeds them by the same basename.
    for ([_][]const u8{
        "LineBreak.txt",
        "auxiliary/WordBreakProperty.txt",
        "Scripts.txt",
        "ScriptExtensions.txt",
        "PropertyValueAliases.txt",
    }) |sub_path| {
        uucode_dep.module("uucode_gen_build_config").addAnonymousImport(std.fs.path.basename(sub_path), .{ .root_source_file = ucd.path(sub_path) });
    }

    // libsiv. The root module only pulls in the ABI exports.
    const root = ctx.module("src/siv.zig", &.{.{ .name = "abi", .module = abi }});
    const shared = b.addLibrary(.{ .name = "siv", .linkage = .dynamic, .version = version, .root_module = root });
    const static = b.addLibrary(.{ .name = "siv", .linkage = .static, .root_module = root });
    // Vendored C code is built with UBSan in safe modes; carry its runtime so
    // that C programs can link libsiv.a without Zig.
    static.bundle_ubsan_rt = true;
    b.installArtifact(shared);
    b.installArtifact(static);

    const pc = b.addWriteFiles().add("siv.pc", b.fmt(
        \\prefix=${{pcfiledir}}/../..
        \\libdir=${{prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: siv
        \\Description: GUI toolkit for Wayland
        \\Version: {f}
        \\Requires.private: wayland-client xkbcommon fontconfig{s}{s}
        \\Libs: -L${{libdir}} -lsiv
        \\Libs.private: -lm -lpthread
        \\Cflags: -I${{includedir}}
        \\
    , .{
        version,
        if (ctx.systemHarfbuzz()) " harfbuzz" else "",
        if (ctx.systemSheenbidi()) " sheenbidi" else "",
    }));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(pc, .lib, "pkgconfig/siv.pc").step);

    // Tests.
    const test_step = b.step("test", "Run all tests");
    const module_tests = [_]struct { []const u8, *std.Build.Module }{
        .{ "text", text },
        .{ "raster", raster },
        .{ "scene", scene },
        .{ "render-cpu", render_cpu },
        .{ "loop", loop },
        .{ "platform", platform },
    };
    for (module_tests) |entry| {
        const name, const module = entry;
        const t = b.addTest(.{ .name = name, .root_module = module, .filters = test_filters });
        const run = b.addRunArtifact(t);
        b.step(b.fmt("test-{s}", .{name}), b.fmt("Run the {s} tests", .{name})).dependOn(&run.step);
        test_step.dependOn(&run.step);
    }

    // Headless integration tests (D24): the real loop on the headless
    // backend, CPU golden images. Extend test/headless.zig.
    const headless = b.addTest(.{
        .name = "headless",
        .root_module = ctx.module("test/headless.zig", &(internal ++ [_]std.Build.Module.Import{
            .{ .name = "abi", .module = abi },
        })),
        .filters = test_filters,
    });
    const headless_run = b.addRunArtifact(headless);
    b.step("test-headless", "Run the headless integration tests").dependOn(&headless_run.step);
    test_step.dependOn(&headless_run.step);

    // Headless text engine benchmarks. Not part of `test`; build with
    // -Doptimize=ReleaseFast for meaningful numbers.
    const bench_text = b.addExecutable(.{
        .name = "bench-text",
        .root_module = ctx.module("src/text/bench.zig", &.{.{ .name = "text", .module = text }}),
    });
    b.step("bench-text", "Run the text engine benchmarks").dependOn(&b.addRunArtifact(bench_text).step);

    // CPU renderer benchmarks, likewise not part of `test`.
    const bench_render_cpu = b.addExecutable(.{
        .name = "bench-render-cpu",
        .root_module = ctx.module("src/render/cpu/bench.zig", &.{
            .{ .name = "raster", .module = raster },
            .{ .name = "scene", .module = scene },
            .{ .name = "text", .module = text },
            .{ .name = "render_cpu", .module = render_cpu },
        }),
    });
    b.step("bench-render-cpu", "Run the CPU renderer benchmarks").dependOn(&b.addRunArtifact(bench_render_cpu).step);

    // Generated headers and bindings, libsiv.so link setup (SONAME, symbol
    // versions), the `siv` Zig module, and the abi, ABI library, and C
    // tests (D2, D3). Owned by the ABI workstream.
    @import("src/abi/build_steps.zig").add(b, .{
        .target = target,
        .optimize = optimize,
        .version = version,
        .build_options = build_options,
        .test_filters = test_filters,
        .abi = abi,
        .shared = shared,
        .test_step = test_step,
    });
}

const Ctx = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    fn module(ctx: Ctx, root: []const u8, imports: []const std.Build.Module.Import) *std.Build.Module {
        return ctx.b.createModule(.{
            .root_source_file = ctx.b.path(root),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = imports,
            .link_libc = true,
            .pic = true,
        });
    }

    fn systemHarfbuzz(ctx: Ctx) bool {
        return ctx.b.systemIntegrationOption("harfbuzz", .{});
    }

    fn systemSheenbidi(ctx: Ctx) bool {
        return ctx.b.systemIntegrationOption("sheenbidi", .{});
    }

    fn translate(ctx: Ctx, name: []const u8, header: []const u8) *std.Build.Step.TranslateC {
        return ctx.b.addTranslateC(.{
            .root_source_file = ctx.b.addWriteFiles().add(ctx.b.fmt("{s}.h", .{name}), header),
            .target = ctx.target,
            .optimize = ctx.optimize,
        });
    }
};

/// Flags for vendored C and C++ sources. Symbols stay hidden so libsiv.so
/// exports only the siv ABI.
const c_flags: []const []const u8 = &.{"-fvisibility=hidden"};

fn systemCModule(ctx: Ctx, pkg: []const u8, header: []const u8) *std.Build.Module {
    const tc = ctx.translate(pkg, header);
    tc.linkSystemLibrary(pkg, .{});
    const m = tc.createModule();
    m.pic = true;
    return m;
}

fn harfbuzzModule(ctx: Ctx) *std.Build.Module {
    const b = ctx.b;
    const tc = ctx.translate("harfbuzz",
        \\#include <hb.h>
        \\#include <hb-ot.h>
        \\
    );
    if (ctx.systemHarfbuzz()) {
        tc.linkSystemLibrary("harfbuzz", .{});
        return tc.createModule();
    }
    const m = if (b.lazyDependency("harfbuzz", .{})) |dep| blk: {
        tc.addIncludePath(dep.path("src"));
        const m = tc.createModule();
        // Amalgamated build without FreeType, GLib, or ICU (D13). HarfBuzz
        // needs C++ headers but not the C++ runtime.
        m.link_libcpp = true;
        m.addCSourceFile(.{
            .file = dep.path("src/harfbuzz.cc"),
            .flags = c_flags ++ &[_][]const u8{
                "-std=c++17",
                "-fno-exceptions",
                "-fno-rtti",
                "-fno-threadsafe-statics",
                "-DHAVE_PTHREAD=1",
            },
        });
        break :blk m;
    } else tc.createModule();
    m.pic = true;
    return m;
}

fn sheenbidiModule(ctx: Ctx) *std.Build.Module {
    const b = ctx.b;
    const tc = ctx.translate("sheenbidi", "#include <SheenBidi/SheenBidi.h>\n");
    if (ctx.systemSheenbidi()) {
        tc.linkSystemLibrary("sheenbidi", .{});
        return tc.createModule();
    }
    const m = if (b.lazyDependency("sheenbidi", .{})) |dep| blk: {
        tc.addIncludePath(dep.path("Headers"));
        const m = tc.createModule();
        m.addIncludePath(dep.path("Headers"));
        m.addIncludePath(dep.path("Source"));
        m.addCSourceFile(.{
            .file = dep.path("Source/SheenBidi.c"),
            // The native scratch allocator keeps a thread-local buffer that
            // is never freed; siv has no global state (D2).
            .flags = c_flags ++ &[_][]const u8{ "-std=c11", "-DSB_CONFIG_UNITY", "-DSB_CONFIG_DISABLE_SCRATCH_MEMORY" },
        });
        break :blk m;
    } else tc.createModule();
    m.pic = true;
    return m;
}

/// zig-wayland bindings over libwayland-client (D7), generated from the
/// pinned protocol XML. The protocol list lives in src/platform/protocols.zig.
fn waylandModule(ctx: Ctx) *std.Build.Module {
    const b = ctx.b;
    const scanner = Scanner.create(b, .{
        .wayland_xml = b.dependency("wayland_core", .{}).path("protocol/wayland.xml"),
        .wayland_protocols = b.dependency("wayland_protocols", .{}).path(""),
    });
    for (wayland_protocols.xml) |path| scanner.addSystemProtocol(path);
    for (wayland_protocols.globals) |global| scanner.generate(global[0], global[1]);
    const m = b.createModule(.{
        .root_source_file = scanner.result,
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
        .pic = true,
    });
    m.linkSystemLibrary("wayland-client", .{});
    return m;
}
