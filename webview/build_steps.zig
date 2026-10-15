//! siv-webview's part of the build graph (D33), called from build.zig when
//! `-Dwebview` is true, or auto (the default) and `missing` finds every
//! system library: libsiv-webview (shared and static) on top of
//! libsiv.so, its header and pkg-config file, the `siv_webview` Zig
//! module, the Lua module (lib/lua/5.5/siv/webview.so) and the
//! siv-webview-lua runner, the example browsers, and the headless tests
//! (`zig build test-webview`, also part of `test`).
//!
//! The library uses only siv's public C ABI and links WPE WebKit 2.50 or
//! later with WPEPlatform from the system (wpe-webkit-2.0 and
//! wpe-platform-2.0), dynamically, with GBM, EGL, and GLib. Nothing else
//! in siv's build depends on it.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    /// libsiv.so.
    shared: *std.Build.Step.Compile,
    /// siv's generated headers (siv.h).
    siv_include: std.Build.LazyPath,
    /// The `siv` Zig module.
    siv_module: *std.Build.Module,
    /// libsiv-lua.so and Lua's headers (null: the system's).
    lua_lib: *std.Build.Step.Compile,
    lua_include: ?std.Build.LazyPath,
    test_step: *std.Build.Step,
};

const system_libs = [_][]const u8{ "wpe-webkit-2.0", "wpe-platform-2.0", "gbm", "egl", "glib-2.0", "gio-2.0" };
/// What pkg-config must find, as it takes them.
const required = [_][]const u8{ "wpe-webkit-2.0 >= 2.50", "wpe-platform-2.0", "gbm", "egl", "glib-2.0", "gio-2.0" };

/// The system libraries pkg-config does not find, comma-separated, or
/// null when every one is there: `-Dwebview=auto` builds siv-webview only
/// then. Asked at configure time, one package at a time, to name them.
/// Zig caches the configure phase, so its result depends on the entries
/// of pkg-config's search directories: installing or removing a package
/// configures again.
pub fn missing(b: *std.Build) ?[]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    switch (b.runFallible(&.{ "pkg-config", "--variable=pc_path", "pkg-config" }, .{ .stderr_behavior = .ignore })) {
        .success => |out| {
            var it = std.mem.tokenizeAny(u8, out, ":\n");
            while (it.next()) |d| dirs.append(b.allocator, d) catch @panic("OOM");
        },
        else => {},
    }
    if (b.graph.environ_map.get("PKG_CONFIG_PATH")) |extra| {
        var it = std.mem.tokenizeScalar(u8, extra, ':');
        while (it.next()) |d| dirs.append(b.allocator, d) catch @panic("OOM");
    }
    for (dirs.items) |d| if (std.fs.path.isAbsolute(d)) b.dependOnDirectoryContents(.{ .cwd_relative = d });
    var list: std.ArrayList(u8) = .empty;
    for (required) |spec| {
        const found = switch (b.runFallible(&.{ "pkg-config", "--exists", spec }, .{ .stderr_behavior = .ignore })) {
            .success => true,
            else => false,
        };
        if (found) continue;
        if (list.items.len > 0) list.appendSlice(b.allocator, ", ") catch @panic("OOM");
        list.appendSlice(b.allocator, spec) catch @panic("OOM");
    }
    return if (list.items.len == 0) null else list.items;
}
const cflags = [_][]const u8{ "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-Wno-missing-field-initializers" };

pub fn add(b: *std.Build, o: Options) void {
    const Mod = struct {
        b: *std.Build,
        o: Options,

        /// A C module that sees siv.h and siv-webview.h and links libsiv.
        fn c(m: @This(), files: []const []const u8) *std.Build.Module {
            const mod = m.b.createModule(.{ .target = m.o.target, .optimize = m.o.optimize, .link_libc = true });
            mod.addIncludePath(m.b.path("webview"));
            mod.addIncludePath(m.o.siv_include);
            mod.addCSourceFiles(.{ .files = files, .flags = &cflags });
            mod.linkLibrary(m.o.shared);
            return mod;
        }
    };
    const mod: Mod = .{ .b = b, .o = o };

    // The library. Only the siv_webview_ ABI is exported (the version
    // script needs LLD, as libsiv's does).
    const lib_module = mod.c(&.{ "webview/webview.c", "webview/glib_loop.c", "webview/wpe.c" });
    for (system_libs) |l| lib_module.linkSystemLibrary(l, .{});
    const lib = b.addLibrary(.{ .name = "siv-webview", .linkage = .dynamic, .version = o.version, .root_module = lib_module });
    lib.use_llvm = true;
    lib.use_lld = true;
    lib.setVersionScript(b.path("webview/siv-webview.map"));
    lib.root_module.addRPathSpecial("$ORIGIN");
    b.installArtifact(lib);
    const static = b.addLibrary(.{ .name = "siv-webview-static", .linkage = .static, .root_module = lib_module });
    b.getInstallStep().dependOn(&b.addInstallArtifact(static, .{ .dest_sub_path = "libsiv-webview.a" }).step);
    b.installFile("webview/siv-webview.h", "include/siv-webview.h");
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
    , .{o.version}));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(pc, .lib, "pkgconfig/siv-webview.pc").step);
    // Its NOTICES: siv's licence; WPE WebKit and the rest are the system's,
    // linked dynamically, and none of their code is in the library (D33).
    const notices = b.addWriteFiles().add("NOTICES", b.fmt("{s}\n{s}", .{
        \\libsiv-webview contains only siv's own code, under siv's licence
        \\below. It links WPE WebKit (LGPL-2.1-or-later and BSD-2-Clause),
        \\GLib (LGPL-2.1-or-later), Mesa's GBM and EGL (MIT), and libsiv
        \\dynamically from the system; their licences come with them.
        \\
        \\siv (MIT)
        \\---------
        \\
    ,
        @embedFile("../LICENSE"),
    }));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(notices, .prefix, "share/licenses/siv-webview/NOTICES").step);

    // The Zig module for dependents: siv's types, linking libsiv-webview.
    const zig_module = b.addModule("siv_webview", .{
        .root_source_file = b.path("webview/siv_webview.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .imports = &.{.{ .name = "siv", .module = o.siv_module }},
    });
    zig_module.linkLibrary(lib);

    // The Lua module: siv/webview.so for hosts with their own Lua 5.5 (lua_*
    // resolve from the process), where package.cpath looks under a prefix,
    // and siv-webview-lua, siv-lua with the module preloaded.
    const lua_module = mod.c(&.{"webview/lua.c"});
    if (o.lua_include) |inc| lua_module.addIncludePath(inc);
    lua_module.linkLibrary(lib);
    const lua_lib = b.addLibrary(.{ .name = "siv-webview-lua-module", .linkage = .dynamic, .root_module = lua_module });
    lua_lib.linker_allow_shlib_undefined = true;
    lua_lib.root_module.addRPathSpecial("$ORIGIN/../../..");
    b.getInstallStep().dependOn(&b.addInstallArtifact(lua_lib, .{ .dest_dir = .{ .override = .{ .custom = "lib/lua/5.5/siv" } }, .dest_sub_path = "webview.so" }).step);
    const runner_module = mod.c(&.{ "webview/lua.c", "webview/lua_main.c" });
    if (o.lua_include) |inc| runner_module.addIncludePath(inc);
    runner_module.addIncludePath(b.path("src/lua"));
    runner_module.linkLibrary(lib);
    runner_module.linkLibrary(o.lua_lib);
    // libsiv-lua exports Lua's C API only when it embeds Lua (as siv-lua).
    if (o.lua_include == null) runner_module.linkSystemLibrary("lua5.5", .{});
    runner_module.addRPathSpecial("$ORIGIN/../lib");
    const runner = b.addExecutable(.{ .name = "siv-webview-lua", .root_module = runner_module });
    b.installArtifact(runner);

    // The example browser (examples/webview-browser.lua runs in the runner).
    const browser_module = mod.c(&.{"examples/webview-browser.c"});
    browser_module.linkLibrary(lib);
    browser_module.addRPathSpecial("$ORIGIN/../lib");
    const browser = b.addExecutable(.{ .name = "siv-webview-browser", .root_module = browser_module });
    b.installArtifact(browser);
    const run_browser = b.addRunArtifact(browser);
    run_browser.addPassthruArgs();
    b.step("webview-browser", "Run the example web browser").dependOn(&run_browser.step);

    // Headless tests: siv's headless backend, the engine in software, no
    // compositor or GPU (webview/tests).
    const test_webview = b.step("test-webview", "Run siv-webview's headless tests");
    const c_test = b.addExecutable(.{ .name = "siv-webview-test", .root_module = mod.c(&.{"webview/tests/headless.c"}) });
    c_test.root_module.linkLibrary(lib);
    const run_c_test = b.addRunArtifact(c_test);
    run_c_test.addPassthruArgs();
    run_c_test.expectExitCode(0);
    test_webview.dependOn(&run_c_test.step);

    const header = b.addTranslateC(.{ .root_source_file = b.path("webview/siv-webview.h"), .target = o.target, .optimize = o.optimize });
    header.addIncludePath(o.siv_include);
    const zig_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("webview/tests/zig.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "siv", .module = o.siv_module },
            .{ .name = "siv_webview", .module = zig_module },
            .{ .name = "c_header", .module = header.createModule() },
        },
    }) });
    test_webview.dependOn(&b.addRunArtifact(zig_test).step);

    const run_lua_test = b.addRunArtifact(runner);
    run_lua_test.addFileArg(b.path("webview/tests/headless.lua"));
    run_lua_test.setEnvironmentVariable("LIBGL_ALWAYS_SOFTWARE", "1");
    run_lua_test.expectExitCode(0);
    test_webview.dependOn(&run_lua_test.step);

    o.test_step.dependOn(test_webview);
}
