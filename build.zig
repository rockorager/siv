//! Build graph for libsiv. See AGENTS.md for module ownership.
//!
//! Steps:
//!   zig build                 libsiv.so, libsiv.a, include/siv.h, siv.pc,
//!                             share/licenses/siv/NOTICES, libsiv-lua.so,
//!                             bin/siv-lua (src/lua/build_steps.zig)
//!   zig build test            every module's tests, the headless tests, and
//!                             the C ABI smoke test
//!   zig build test-<module>   one module's tests (e.g. test-text)
//!   zig build test-headless   the headless integration tests
//!   zig build shaders         compile the Vulkan shaders and update the
//!                             committed SPIR-V (src/render/vulkan)
//!   zig build test-integration  opt in, by hand (D24): the Wayland backend
//!                             against headless sway, D-Bus against
//!                             dbus-daemon; .agents/setup-integration
//!                             installs what it needs
//!   zig build bench-pacing    frame pacing on sway end to end, against
//!                             D12's thresholds (on a quiet machine)
//!   zig build bench-latency   input-to-photon on the headless backend,
//!                             against D25's budget (on a quiet machine)
//!
//! Options:
//!   -Dtest-filter=<text>      only run tests whose name contains <text>
//!   -fsys=harfbuzz            link the system HarfBuzz instead of building it
//!   -fsys=sheenbidi           link the system SheenBidi instead of building it
//!   -fsys=lua                 link the system Lua 5.5 into libsiv-lua
//!   -fsys=lcms2, libwebp, libavif, dav1d, libjxl
//!                             link the system image decoders and Little CMS
//!                             (src/image/build_steps.zig)
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
    // its translated header and, when vendored, an object with its compiled
    // sources (`Ctx.cObject`), so that it lands in every artifact that
    // imports it, including libsiv.a.
    const harfbuzz = harfbuzzModule(ctx);
    const harfbuzz_subset = harfbuzzSubsetModule(ctx, harfbuzz);
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
    const pool = ctx.module("src/pool/pool.zig", &.{});
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
    const icon = ctx.module("src/icon/icon.zig", &.{});
    // Documents (D32): HTML parsing.
    const html = ctx.module("src/html/html.zig", &.{});
    const css = ctx.module("src/css/css.zig", &.{});
    const images = @import("src/image/build_steps.zig").add(b, .{ .target = target, .optimize = optimize, .scene = scene });
    const image = images.image;
    const svg = ctx.module("src/svg/svg.zig", &.{
        .{ .name = "scene", .module = scene },
        .{ .name = "raster", .module = raster },
        .{ .name = "image", .module = image },
    });
    const render_cpu = ctx.module("src/render/cpu/cpu.zig", &.{
        .{ .name = "scene", .module = scene },
        .{ .name = "raster", .module = raster },
        .{ .name = "text", .module = text },
        .{ .name = "harfbuzz", .module = harfbuzz },
        .{ .name = "pool", .module = pool },
        .{ .name = "image", .module = image },
    });
    const vk = @import("src/render/vulkan/build_steps.zig").add(b, .{ .target = target, .optimize = optimize });
    const render_vulkan = ctx.module("src/render/vulkan/vulkan.zig", &.{
        .{ .name = "scene", .module = scene },
        .{ .name = "raster", .module = raster },
        .{ .name = "render_cpu", .module = render_cpu },
        .{ .name = "pool", .module = pool },
        .{ .name = "vulkan", .module = vk.vulkan },
        .{ .name = "shaders", .module = vk.shaders },
    });
    const pdf_imports = [_]std.Build.Module.Import{
        .{ .name = "scene", .module = scene },
        .{ .name = "raster", .module = raster },
        .{ .name = "render_cpu", .module = render_cpu },
        .{ .name = "text", .module = text },
        .{ .name = "harfbuzz_subset", .module = harfbuzz_subset },
    };
    const pdf = ctx.module("src/pdf/pdf.zig", &pdf_imports);
    const loop = ctx.module("src/loop/loop.zig", &.{
        .{ .name = "pool", .module = pool },
    });
    const platform_imports = [_]std.Build.Module.Import{
        .{ .name = "loop", .module = loop },
        .{ .name = "wayland", .module = wayland },
        .{ .name = "xkbcommon", .module = xkbcommon },
    };
    const dbus_imports = [_]std.Build.Module.Import{
        .{ .name = "loop", .module = loop },
    };
    const dbus = ctx.module("src/dbus/dbus.zig", &dbus_imports);
    const portal_imports = [_]std.Build.Module.Import{
        .{ .name = "dbus", .module = dbus },
        .{ .name = "loop", .module = loop },
    };
    const portal = ctx.module("src/portal/portal.zig", &portal_imports);
    // The tray imports what the portals do.
    const tray = ctx.module("src/tray/tray.zig", &portal_imports);
    const platform = ctx.module("src/platform/platform.zig", &platform_imports);
    const not_integration = integrationOption(b, false);
    platform.addImport("integration", not_integration);
    dbus.addImport("integration", not_integration);
    portal.addImport("integration", not_integration);
    pdf.addImport("integration", not_integration);
    tray.addImport("integration", not_integration);
    const compositor_imports = [_]std.Build.Module.Import{
        .{ .name = "scene", .module = scene },
        .{ .name = "raster", .module = raster },
        .{ .name = "render_cpu", .module = render_cpu },
        .{ .name = "render_vulkan", .module = render_vulkan },
        .{ .name = "pool", .module = pool },
        .{ .name = "loop", .module = loop },
        .{ .name = "platform", .module = platform },
    };
    const compositor = ctx.module("src/compositor/compositor.zig", &compositor_imports);
    compositor.addImport("integration", not_integration);
    const ui = ctx.module("src/ui/ui.zig", &.{
        .{ .name = "scene", .module = scene },
        .{ .name = "svg", .module = svg },
        .{ .name = "icon", .module = icon },
        .{ .name = "image", .module = image },
        .{ .name = "raster", .module = raster },
        .{ .name = "text", .module = text },
        .{ .name = "loop", .module = loop },
        .{ .name = "platform", .module = platform },
        .{ .name = "compositor", .module = compositor },
    });
    const a11y_imports = [_]std.Build.Module.Import{
        .{ .name = "dbus", .module = dbus },
        .{ .name = "ui", .module = ui },
        .{ .name = "loop", .module = loop },
        .{ .name = "raster", .module = raster },
        .{ .name = "text", .module = text },
    };
    const a11y = ctx.module("src/a11y/a11y.zig", &a11y_imports);
    a11y.addImport("integration", not_integration);
    const app_imports = [_]std.Build.Module.Import{
        .{ .name = "text", .module = text },
        .{ .name = "loop", .module = loop },
        .{ .name = "platform", .module = platform },
        .{ .name = "compositor", .module = compositor },
        .{ .name = "ui", .module = ui },
        .{ .name = "dbus", .module = dbus },
        .{ .name = "a11y", .module = a11y },
        .{ .name = "portal", .module = portal },
    };
    const app = ctx.module("src/app/app.zig", &app_imports);
    app.addImport("integration", not_integration);
    const internal = [_]std.Build.Module.Import{
        .{ .name = "pool", .module = pool },
        .{ .name = "scene", .module = scene },
        .{ .name = "svg", .module = svg },
        .{ .name = "icon", .module = icon },
        .{ .name = "raster", .module = raster },
        .{ .name = "text", .module = text },
        .{ .name = "image", .module = image },
        .{ .name = "render_cpu", .module = render_cpu },
        .{ .name = "render_vulkan", .module = render_vulkan },
        .{ .name = "loop", .module = loop },
        .{ .name = "platform", .module = platform },
        .{ .name = "compositor", .module = compositor },
        .{ .name = "ui", .module = ui },
        .{ .name = "app", .module = app },
        .{ .name = "portal", .module = portal },
        .{ .name = "pdf", .module = pdf },
        .{ .name = "tray", .module = tray },
        .{ .name = "dbus", .module = dbus },
    };
    // Stock widgets (D22) import only the generated C API wrapper, which
    // src/abi/build_steps.zig adds as `siv`.
    const widgets = ctx.module("src/widgets/widgets.zig", &.{});
    const abi = ctx.module("src/abi/abi.zig", &internal);
    abi.addImport("build_options", build_options);
    abi.addImport("widgets", widgets);

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
    // Distinct artifact names, so that a package depending on siv can
    // pick one with dependency.artifact; the archive is still libsiv.a.
    const static = b.addLibrary(.{ .name = "siv-static", .linkage = .static, .root_module = root });
    // Vendored C code is built with UBSan in safe modes; carry its runtime so
    // that C programs can link libsiv.a without Zig.
    static.bundle_ubsan_rt = true;
    b.installArtifact(shared);
    b.getInstallStep().dependOn(&b.addInstallArtifact(static, .{ .dest_sub_path = "libsiv.a" }).step);

    const pc = b.addWriteFiles().add("siv.pc", b.fmt(
        \\prefix=${{pcfiledir}}/../..
        \\libdir=${{prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: siv
        \\Description: GUI toolkit for Wayland
        \\Version: {f}
        \\Requires.private: wayland-client xkbcommon fontconfig{s}{s}{s}
        \\Libs: -L${{libdir}} -lsiv
        \\Libs.private: -lm -lpthread
        \\Cflags: -I${{includedir}}
        \\
    , .{
        version,
        if (ctx.systemHarfbuzz()) " harfbuzz" else "",
        if (ctx.systemSheenbidi()) " sheenbidi" else "",
        images.requires,
    }));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(pc, .lib, "pkgconfig/siv.pc").step);

    // Tests.
    const test_step = b.step("test", "Run all tests");
    // Zig's test runner with `--shard=I/N` (test/runner.zig).
    const test_runner: std.Build.Step.Compile.TestRunner = .{ .path = b.path("test/runner.zig"), .mode = .server };
    const module_tests = [_]struct { []const u8, *std.Build.Module }{
        .{ "pool", pool },
        .{ "text", text },
        .{ "raster", raster },
        .{ "scene", scene },
        .{ "svg", svg },
        .{ "icon", icon },
        .{ "html", html },
        .{ "css", css },
        .{ "image", image },
        .{ "render-cpu", render_cpu },
        .{ "render-vulkan", render_vulkan },
        .{ "loop", loop },
        .{ "dbus", dbus },
        .{ "portal", portal },
        .{ "pdf", pdf },
        .{ "tray", tray },
        .{ "platform", platform },
        .{ "compositor", compositor },
        .{ "ui", ui },
        .{ "a11y", a11y },
        .{ "app", app },
    };
    for (module_tests) |entry| {
        const name, const module = entry;
        const t = b.addTest(.{ .name = name, .root_module = module, .filters = test_filters, .test_runner = test_runner });
        const step = b.step(b.fmt("test-{s}", .{name}), b.fmt("Run the {s} tests", .{name}));
        // The text tests' conformance and equivalence tests take seconds
        // each; the others take less than a second in all.
        addShardedRuns(b, t, step, if (std.mem.eql(u8, name, "text")) 4 else 1, false);
        test_step.dependOn(step);
    }

    // The headless test binary (D24): the real loop on the headless
    // backend, CPU golden images, the C API, the Lua binding in process,
    // the guide's samples, and the files app, in one compilation of siv
    // (tests.zig). Extend test/headless.zig. The build steps below add
    // their C sources and imports. It runs as `headless_shards` processes
    // at once, each with every Nth test (test/runner.zig).
    const headless = b.addTest(.{
        .name = "headless",
        .root_module = ctx.module("tests.zig", &(internal ++ [_]std.Build.Module.Import{
            .{ .name = "abi", .module = abi },
            .{ .name = "png", .module = b.createModule(.{ .root_source_file = b.path("test/render/png.zig") }) },
        })),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    const test_headless = b.step("test-headless", "Run the headless test binary (C API, guide, files app, Lua)");
    // The guide's tests read its chapters, samples, and screenshots, which
    // the build does not track as inputs, so the runs are never cached.
    addShardedRuns(b, headless, test_headless, 8, true);
    test_step.dependOn(test_headless);

    // Integration tests: the Wayland backend against sway running headless
    // (src/platform/integration_tests.zig). Opt in and by hand, never part
    // of `test` or a gate (D24).
    const integration = ctx.module("src/platform/platform.zig", &platform_imports);
    integration.addImport("integration", integrationOption(b, true));
    const integration_run = b.addRunArtifact(b.addTest(.{ .name = "integration", .root_module = integration, .filters = test_filters }));
    integration_run.has_side_effects = true; // depends on the installed sway
    const integration_step = b.step("test-integration", "Run the integration tests against headless sway and dbus-daemon");
    integration_step.dependOn(&integration_run.step);
    // The compositor thread against sway, through platform.test_sway.
    const compositor_integration = ctx.module("src/compositor/compositor.zig", &compositor_imports);
    compositor_integration.addImport("integration", integrationOption(b, true));
    const compositor_integration_run = b.addRunArtifact(b.addTest(.{ .name = "compositor-integration", .root_module = compositor_integration, .filters = test_filters }));
    compositor_integration_run.has_side_effects = true;
    integration_step.dependOn(&compositor_integration_run.step);
    // D-Bus against a private dbus-daemon (src/dbus/integration_tests.zig).
    const dbus_integration = ctx.module("src/dbus/dbus.zig", &dbus_imports);
    dbus_integration.addImport("integration", integrationOption(b, true));
    const dbus_integration_run = b.addRunArtifact(b.addTest(.{ .name = "dbus-integration", .root_module = dbus_integration, .filters = test_filters }));
    dbus_integration_run.has_side_effects = true; // depends on the installed dbus-daemon
    integration_step.dependOn(&dbus_integration_run.step);
    b.step("test-integration-dbus", "Run the D-Bus integration tests against dbus-daemon").dependOn(&dbus_integration_run.step);
    // Portal clients against xdg-desktop-portal (src/portal/integration_tests.zig).
    const portal_integration = ctx.module("src/portal/portal.zig", &portal_imports);
    portal_integration.addImport("integration", integrationOption(b, true));
    const portal_integration_run = b.addRunArtifact(b.addTest(.{ .name = "portal-integration", .root_module = portal_integration, .filters = test_filters }));
    portal_integration_run.has_side_effects = true; // depends on the installed xdg-desktop-portal
    integration_step.dependOn(&portal_integration_run.step);
    b.step("test-integration-portal", "Run the portal integration tests against xdg-desktop-portal").dependOn(&portal_integration_run.step);
    // PDF output checked by qpdf and poppler (src/pdf/integration_tests.zig).
    const pdf_integration = ctx.module("src/pdf/pdf.zig", &pdf_imports);
    pdf_integration.addImport("integration", integrationOption(b, true));
    const pdf_integration_run = b.addRunArtifact(b.addTest(.{ .name = "pdf-integration", .root_module = pdf_integration, .filters = test_filters }));
    pdf_integration_run.has_side_effects = true; // depends on the installed qpdf and poppler-utils
    integration_step.dependOn(&pdf_integration_run.step);
    b.step("test-integration-pdf", "Run the PDF integration tests against qpdf and poppler").dependOn(&pdf_integration_run.step);
    // The tray against dbus-daemon and gdbus (src/tray/integration_tests.zig).
    const tray_integration = ctx.module("src/tray/tray.zig", &portal_imports);
    tray_integration.addImport("integration", integrationOption(b, true));
    const tray_integration_run = b.addRunArtifact(b.addTest(.{ .name = "tray-integration", .root_module = tray_integration, .filters = test_filters }));
    tray_integration_run.has_side_effects = true; // depends on the installed dbus-daemon and gdbus
    integration_step.dependOn(&tray_integration_run.step);
    b.step("test-integration-tray", "Run the tray integration tests against dbus-daemon").dependOn(&tray_integration_run.step);
    // The application's desktop settings against dbus-daemon.
    const app_integration = ctx.module("src/app/app.zig", &app_imports);
    app_integration.addImport("integration", integrationOption(b, true));
    const app_integration_run = b.addRunArtifact(b.addTest(.{ .name = "app-integration", .root_module = app_integration, .filters = test_filters }));
    app_integration_run.has_side_effects = true; // depends on the installed dbus-daemon
    integration_step.dependOn(&app_integration_run.step);
    // AT-SPI against the real registry and libatspi (src/a11y/integration_tests.zig).
    const a11y_integration = ctx.module("src/a11y/a11y.zig", &a11y_imports);
    a11y_integration.addImport("integration", integrationOption(b, true));
    const a11y_integration_run = b.addRunArtifact(b.addTest(.{ .name = "a11y-integration", .root_module = a11y_integration, .filters = test_filters }));
    a11y_integration_run.has_side_effects = true; // depends on the installed at-spi2-core
    integration_step.dependOn(&a11y_integration_run.step);
    // Real icon themes (Adwaita, Breeze) drawn by siv's SVG renderer
    // against librsvg's rsvg-convert (test/icons/integration.zig). Opt in:
    // what it finds depends on the installed theme releases, which use new
    // SVG features at their own pace (D19).
    const icons_integration_run = b.addRunArtifact(b.addTest(.{
        .name = "icons-integration",
        .root_module = ctx.module("test/icons/integration.zig", &.{
            .{ .name = "svg", .module = svg },
            .{ .name = "scene", .module = scene },
            .{ .name = "raster", .module = raster },
            .{ .name = "render_cpu", .module = render_cpu },
            .{ .name = "pool", .module = pool },
            .{ .name = "png", .module = ctx.module("test/render/png.zig", &.{}) },
        }),
        .filters = test_filters,
    }));
    icons_integration_run.has_side_effects = true; // depends on the installed themes and librsvg
    b.step("test-integration-icons", "Draw the installed Adwaita and Breeze icons against rsvg-convert").dependOn(&icons_integration_run.step);
    // Frame pacing measured end to end (src/compositor/integration_tests.zig,
    // "pacing: ..."): dropped frames on lavapipe and pixman sway are CPU
    // work that other processes delay, so they are checked against D12's
    // thresholds only here, for a quiet machine or real hardware. Not part
    // of `test-integration`, which asserts only what siv controls.
    const pacing = ctx.module("src/compositor/compositor.zig", &compositor_imports);
    pacing.addImport("integration", integrationOptions(b, true, true));
    const pacing_run = b.addRunArtifact(b.addTest(.{ .name = "bench-pacing", .root_module = pacing, .filters = if (test_filters.len > 0) test_filters else &.{"pacing: "} }));
    pacing_run.has_side_effects = true;
    b.step("bench-pacing", "Measure frame pacing on sway against D12's thresholds (quiet machine)").dependOn(&pacing_run.step);
    b.step("test-integration-a11y", "Run the AT-SPI integration tests against the registry").dependOn(&a11y_integration_run.step);

    // Input-to-photon latency and animation smoothness on the headless
    // backend against D25's budget (test/compositor/latency.zig): timings,
    // so run by hand on a quiet machine like the other benchmarks.
    const bench_latency = b.addTest(.{
        .name = "bench-latency",
        .root_module = ctx.module("test/compositor/latency.zig", &.{
            .{ .name = "scene", .module = scene },
            .{ .name = "pool", .module = pool },
            .{ .name = "loop", .module = loop },
            .{ .name = "platform", .module = platform },
            .{ .name = "compositor", .module = compositor },
        }),
        .filters = test_filters,
    });
    const bench_latency_run = b.addRunArtifact(bench_latency);
    bench_latency_run.has_side_effects = true;
    bench_latency_run.setEnvironmentVariable("SIV_MEASURE", "1");
    b.step("bench-latency", "Measure input-to-photon latency and smoothness on the headless backend (quiet machine)").dependOn(&bench_latency_run.step);

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
            .{ .name = "pool", .module = pool },
        }),
    });
    b.step("bench-render-cpu", "Run the CPU renderer benchmarks").dependOn(&b.addRunArtifact(bench_render_cpu).step);

    // Image decoding benchmarks, likewise; `-- FILE...` decodes those files.
    const bench_image = b.addExecutable(.{
        .name = "bench-image",
        .root_module = ctx.module("src/image/bench.zig", &.{.{ .name = "image", .module = image }}),
    });
    const bench_image_run = b.addRunArtifact(bench_image);
    bench_image_run.addPassthruArgs();
    b.step("bench-image", "Run the image decoding benchmarks").dependOn(&bench_image_run.step);

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
        .widgets = widgets,
        .shared = shared,
        .static = static,
        .test_step = test_step,
        .integration_step = integration_step,
        .headless = headless,
        .test_headless = test_headless,
    });

    // libsiv-lua on top of libsiv.so, the siv-lua runner, its annotations,
    // and the Lua binding's tests (D23). Owned by the Lua binding
    // workstream.
    @import("src/lua/build_steps.zig").add(b, .{
        .target = target,
        .optimize = optimize,
        .version = version,
        .test_filters = test_filters,
        .shared = shared,
        .test_step = test_step,
        .integration_step = integration_step,
        .headless = headless,
        .test_headless = test_headless,
    });

    // The file manager (apps/files), built on the `siv` wrapper above.
    @import("apps/files/build_steps.zig").add(b, .{
        .target = target,
        .optimize = optimize,
        .test_filters = test_filters,
        .abi = abi,
        .headless = headless,
        .test_headless = test_headless,
        .test_step = test_step,
        .integration_step = integration_step,
    });

    // The user guide's samples and screenshots (docs/guide), after the
    // ABI and Lua steps, whose wrapper and binding they use.
    @import("docs/guide/build_steps.zig").add(b, .{
        .target = target,
        .optimize = optimize,
        .test_filters = test_filters,
        .abi = abi,
        .shared = shared,
        .headless = headless,
        .test_headless = test_headless,
        .test_step = test_step,
    });

    // NOTICES (D25): the licences of what libsiv contains for these
    // options, installed as share/licenses/siv/NOTICES and checked by
    // `test`.
    @import("src/notices/build_steps.zig").add(b, .{ .root = root, .test_step = test_step });
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

    /// An object for vendored C, linked through `into`. C sources on a
    /// module are compiled again for every artifact that includes it,
    /// since their cache entries are not shared between compilations; an
    /// object is compiled once and linked into each (D25).
    fn cObject(ctx: Ctx, into: *std.Build.Module, name: []const u8, cpp: bool, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        const obj = ctx.b.addObject(.{
            .name = name,
            .root_module = ctx.b.createModule(.{
                .target = ctx.target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = cpp,
                .pic = true,
                // No debug info: it is most of what linking a test binary
                // reads and writes (D25).
                .strip = true,
            }),
        });
        into.addObject(obj);
        return obj.root_module;
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

/// Whether the platform module's tests are the integration tests.
fn integrationOption(b: *std.Build, enabled: bool) *std.Build.Module {
    return integrationOptions(b, enabled, false);
}

/// `bench` makes the compositor's "pacing: ..." integration tests measure
/// end to end (`zig build bench-pacing`).
fn integrationOptions(b: *std.Build, enabled: bool, bench: bool) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "enabled", enabled);
    options.addOption(bool, "bench", bench);
    return options.createModule();
}

/// Runs test binary `t` for `step` as `shards` processes at once, each
/// with every Nth test (test/runner.zig), from the build root.
fn addShardedRuns(b: *std.Build, t: *std.Build.Step.Compile, step: *std.Build.Step, shards: usize, side_effects: bool) void {
    for (0..shards) |i| {
        const run = b.addRunArtifact(t);
        if (shards > 1) run.addArg(b.fmt("--shard={d}/{d}", .{ i, shards }));
        run.has_side_effects = side_effects;
        run.setCwd(b.path("."));
        step.dependOn(&run.step);
    }
}

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
        // needs C++ headers but not the C++ runtime, so only its object
        // has libc++ (for the headers), and nothing links libc++ for it.
        // Optimized in Debug builds too: shaping is most of the text and
        // headless tests' run time, which this halves (D25).
        const optimize: std.builtin.OptimizeMode = if (ctx.optimize == .debug) .fast else ctx.optimize;
        ctx.cObject(m, "harfbuzz", true, optimize).addCSourceFile(.{
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

/// HarfBuzz's subsetter, for embedding font subsets in PDF (D9, D19). Its
/// translated header includes hb.h too, so the PDF writer needs only this
/// module. The vendored build compiles the subsetter's own sources next to
/// the amalgamated core in the `harfbuzz` module, which it imports so that
/// the core is linked too. -fsys=harfbuzz links the system
/// libharfbuzz-subset.
fn harfbuzzSubsetModule(ctx: Ctx, harfbuzz: *std.Build.Module) *std.Build.Module {
    const b = ctx.b;
    const tc = ctx.translate("harfbuzz_subset",
        \\#include <hb.h>
        \\#include <hb-ot.h>
        \\#include <hb-subset.h>
        \\
    );
    if (ctx.systemHarfbuzz()) {
        tc.linkSystemLibrary("harfbuzz-subset", .{});
        return tc.createModule();
    }
    const m = if (b.lazyDependency("harfbuzz", .{})) |dep| blk: {
        tc.addIncludePath(dep.path("src"));
        const m = tc.createModule();
        m.addImport("harfbuzz", harfbuzz);
        // The files harfbuzz-subset.cc adds to harfbuzz.cc, compiled as one
        // file: they share HarfBuzz's heavy headers, which then compile
        // once (a quarter of the time of compiling each file).
        var unity: std.ArrayList(u8) = .empty;
        for ([_][]const u8{
            "graph/gsubgpos-context.cc",
            "hb-depend.cc",
            "hb-subset-cff-common.cc",
            "hb-subset-cff1.cc",
            "hb-subset-cff2.cc",
            "hb-subset-input.cc",
            "hb-subset-instancer-iup.cc",
            "hb-subset-instancer-solver.cc",
            "hb-subset-plan-layout.cc",
            "hb-subset-plan-var.cc",
            "hb-subset-plan.cc",
            "hb-subset-serialize.cc",
            "hb-subset-table-cff.cc",
            "hb-subset-table-color.cc",
            "hb-subset-table-layout.cc",
            "hb-subset-table-other.cc",
            "hb-subset-table-var.cc",
            "hb-subset.cc",
        }) |file| unity.print(b.allocator, "#include \"{s}\"\n", .{file}) catch @panic("OOM");
        const obj = ctx.cObject(m, "harfbuzz-subset", true, ctx.optimize);
        obj.addIncludePath(dep.path("src"));
        obj.addCSourceFile(.{
            .file = b.addWriteFiles().add("harfbuzz-subset-files.cc", unity.items),
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
        const obj = ctx.cObject(m, "sheenbidi", false, ctx.optimize);
        obj.addIncludePath(dep.path("Headers"));
        obj.addIncludePath(dep.path("Source"));
        obj.addCSourceFile(.{
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
    const wlr = b.dependency("wlr_protocols", .{});
    for (wayland_protocols.wlr_xml) |path| scanner.addCustomProtocol(wlr.path(path));
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
