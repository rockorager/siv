//! siv-webview: libsiv-webview (shared and static), its header and
//! pkg-config file, the Zig module, the Lua module and runner, the
//! examples, and the tests.
//!
//!     zig build -Dsiv=/path/to/siv/prefix      # default: pkg-config's siv
//!     zig build test                           # headless: no compositor or GPU
//!
//! Needs WPE WebKit 2.50 or later with WPEPlatform (wpe-webkit-2.0 and
//! wpe-platform-2.0), GBM, EGL, and GLib.
const std = @import("std");

const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };
const system_libs = [_][]const u8{ "wpe-webkit-2.0", "wpe-platform-2.0", "gbm", "egl", "glib-2.0", "gio-2.0" };
const cflags = [_][]const u8{ "-std=gnu11", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-missing-field-initializers" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const siv_prefix = b.option([]const u8, "siv", "Prefix of an installed siv (include/siv.h, lib/libsiv.so, share/siv/siv.zig); default pkg-config's") orelse pkgConfigPrefix(b);
    const siv_include = b.pathJoin(&.{ siv_prefix, "include" });
    const siv_lib = b.pathJoin(&.{ siv_prefix, "lib" });

    const Ctx = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        include: []const u8,
        lib_dir: []const u8,

        fn module(ctx: @This()) *std.Build.Module {
            const m = ctx.b.createModule(.{ .target = ctx.target, .optimize = ctx.optimize, .link_libc = true });
            m.addIncludePath(ctx.b.path("include"));
            m.addIncludePath(.{ .cwd_relative = ctx.include });
            m.addLibraryPath(.{ .cwd_relative = ctx.lib_dir });
            m.addRPath(.{ .cwd_relative = ctx.lib_dir });
            m.linkSystemLibrary("siv", .{ .use_pkg_config = .no });
            return m;
        }
    };
    const ctx: Ctx = .{ .b = b, .target = target, .optimize = optimize, .include = siv_include, .lib_dir = siv_lib };

    // The library.
    const lib_module = ctx.module();
    lib_module.addCSourceFiles(.{ .files = &.{ "src/webview.c", "src/glib_loop.c", "src/wpe.c" }, .flags = &cflags });
    for (system_libs) |l| lib_module.linkSystemLibrary(l, .{});
    const lib = b.addLibrary(.{ .name = "siv-webview", .linkage = .dynamic, .version = version, .root_module = lib_module });
    // Only the siv_webview_ ABI is exported.
    lib.use_llvm = true;
    lib.use_lld = true;
    lib.setVersionScript(b.path("src/siv-webview.map"));
    b.installArtifact(lib);
    const static = b.addLibrary(.{ .name = "siv-webview-static", .linkage = .static, .root_module = lib_module });
    b.getInstallStep().dependOn(&b.addInstallArtifact(static, .{ .dest_sub_path = "libsiv-webview.a" }).step);
    b.installFile("include/siv-webview.h", "include/siv-webview.h");
    const pc = b.addWriteFiles().add("siv-webview.pc", b.fmt(
        \\prefix=${{pcfiledir}}/../..
        \\libdir=${{prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: siv-webview
        \\Description: A web view for siv, on WPE WebKit
        \\Version: {f}
        \\Requires: siv
        \\Requires.private: wpe-webkit-2.0 wpe-platform-2.0 gbm egl glib-2.0 gio-2.0
        \\Libs: -L${{libdir}} -lsiv-webview
        \\Cflags: -I${{includedir}}
        \\
    , .{version}));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(pc, .lib, "pkgconfig/siv-webview.pc").step);
    // The Zig module, installed beside siv's.
    b.installFile("zig/siv_webview.zig", "share/siv-webview/siv_webview.zig");

    // The Lua module: siv/webview.so for hosts with their own Lua 5.5 (lua_*
    // resolve from the process), where package.cpath looks under a prefix.
    const lua_include = b.pathJoin(&.{ siv_include, "siv-lua" });
    const lua_module = ctx.module();
    lua_module.addIncludePath(.{ .cwd_relative = lua_include });
    lua_module.addCSourceFiles(.{ .files = &.{"src/lua.c"}, .flags = &cflags });
    lua_module.linkLibrary(lib);
    const lua_lib = b.addLibrary(.{ .name = "siv-webview-lua-module", .linkage = .dynamic, .root_module = lua_module });
    lua_lib.linker_allow_shlib_undefined = true;
    lua_lib.root_module.addRPathSpecial("$ORIGIN/../../..");
    b.getInstallStep().dependOn(&b.addInstallArtifact(lua_lib, .{ .dest_dir = .{ .override = .{ .custom = "lib/lua/5.5/siv" } }, .dest_sub_path = "webview.so" }).step);
    // siv-webview-lua: siv-lua with the module preloaded.
    const runner_module = ctx.module();
    runner_module.addIncludePath(.{ .cwd_relative = lua_include });
    runner_module.addCSourceFiles(.{ .files = &.{ "src/lua.c", "src/lua_main.c" }, .flags = &cflags });
    runner_module.linkLibrary(lib);
    runner_module.linkSystemLibrary("siv-lua", .{ .use_pkg_config = .no });
    runner_module.addRPathSpecial("$ORIGIN/../lib");
    const runner = b.addExecutable(.{ .name = "siv-webview-lua", .root_module = runner_module });
    b.installArtifact(runner);

    // The example browser.
    const browser_module = ctx.module();
    browser_module.addCSourceFiles(.{ .files = &.{"examples/browser.c"}, .flags = &cflags });
    browser_module.linkLibrary(lib);
    browser_module.addRPathSpecial("$ORIGIN/../lib");
    const browser = b.addExecutable(.{ .name = "siv-webview-browser", .root_module = browser_module });
    b.installArtifact(browser);
    const run_browser = b.addRunArtifact(browser);
    run_browser.addPassthruArgs();
    b.step("browser", "Run the example browser").dependOn(&run_browser.step);

    // Tests: the C API, the Zig module, and the Lua module, on siv's
    // headless backend with the engine rendering in software.
    const test_step = b.step("test", "Run the headless tests");
    const c_test_module = ctx.module();
    c_test_module.addCSourceFiles(.{ .files = &.{"tests/headless.c"}, .flags = &cflags });
    c_test_module.linkLibrary(lib);
    const c_test = b.addExecutable(.{ .name = "siv-webview-test", .root_module = c_test_module });
    const run_c_test = b.addRunArtifact(c_test);
    run_c_test.addPassthruArgs();
    run_c_test.expectExitCode(0);
    test_step.dependOn(&run_c_test.step);

    const header = b.addTranslateC(.{ .root_source_file = b.path("include/siv-webview.h"), .target = target, .optimize = optimize });
    header.addIncludePath(.{ .cwd_relative = siv_include });
    const siv_zig = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ siv_prefix, "share/siv/siv.zig" }) } });
    const zig_module = b.addModule("siv_webview", .{
        .root_source_file = b.path("zig/siv_webview.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "siv", .module = siv_zig }},
    });
    const zig_test_module = ctx.module();
    zig_test_module.root_source_file = b.path("tests/zig.zig");
    zig_test_module.addImport("siv", siv_zig);
    zig_test_module.addImport("c_header", header.createModule());
    zig_test_module.linkLibrary(lib);
    zig_test_module.addImport("siv_webview", zig_module);
    const zig_test = b.addTest(.{ .root_module = zig_test_module });
    test_step.dependOn(&b.addRunArtifact(zig_test).step);

    const run_lua_test = b.addRunArtifact(runner);
    run_lua_test.addFileArg(b.path("tests/headless.lua"));
    run_lua_test.setEnvironmentVariable("LIBGL_ALWAYS_SOFTWARE", "1");
    run_lua_test.expectExitCode(0);
    test_step.dependOn(&run_lua_test.step);
}

/// The prefix pkg-config knows for siv.
fn pkgConfigPrefix(b: *std.Build) []const u8 {
    const out = b.run(&.{ "pkg-config", "--variable=prefix", "siv" });
    return std.mem.trim(u8, out, " \n");
}
