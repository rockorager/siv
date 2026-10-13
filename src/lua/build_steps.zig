//! Lua binding part of the build graph (D23), called from build.zig:
//! Lua 5.5 from the pinned release, libsiv-lua.so on top of libsiv.so,
//! the `siv-lua` runner, the Lua language server annotations generated
//! from the schema, and the binding's tests. The Lua binding workstream
//! owns this file.
//!
//! Installed:
//!   lib/libsiv-lua.so            the binding and the Lua it embeds
//!   lib/lua/5.5/siv.so           the binding as a Lua C module, without
//!                                Lua, for hosts with a Lua 5.5 of their own
//!   include/siv-lua/siv_lua.h    embedding API (and lua.h, lauxlib.h,
//!                                lualib.h, luaconf.h unless -fsys=lua)
//!   lib/pkgconfig/siv-lua.pc
//!   bin/siv-lua                  runs a Lua application, with --watch for
//!                                hot reload
//!   share/siv/lua/siv.lua        annotations for lua-language-server
//!   share/licenses/siv-lua/NOTICES
//!
//! Lua is compiled from its core and an explicit allowlist of standard
//! libraries (`allowed_libs`); linit.c, which references every library,
//! is not compiled, and loadlib.c is built without dlopen, so `require`
//! loads only Lua source. `-fsys=lua` links the system liblua5.5 instead.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    test_filters: []const []const u8,
    /// libsiv.so, which libsiv-lua links.
    shared: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    integration_step: *std.Build.Step,
    /// The headless tests (test/headless.zig), which drive Lua
    /// applications against the exports compiled into that binary.
    headless: *std.Build.Step.Compile,
};

/// Lua's core: the virtual machine, compiler, and auxiliary library.
const core = [_][]const u8{
    "lapi.c",   "lcode.c",   "lctype.c",  "ldebug.c",   "ldo.c",    "ldump.c",
    "lfunc.c",  "lgc.c",     "llex.c",    "lmem.c",     "lobject.c", "lopcodes.c",
    "lparser.c", "lstate.c", "lstring.c", "ltable.c",   "ltm.c",    "lundump.c",
    "lvm.c",    "lzio.c",    "lauxlib.c",
};

/// The standard libraries compiled in. Left out: the debug library (it
/// reads and writes any function's upvalues and the registry, where the
/// binding keeps its state) and linit.c. siv_lua_new opens these by the
/// same names (src/lua/lua.zig).
const allowed_libs = [_][]const u8{
    "lbaselib.c", // base
    "loadlib.c", // package (require); built without dlopen
    "lcorolib.c", // coroutine
    "ltablib.c", // table
    "lstrlib.c", // string
    "lmathlib.c", // math
    "lutf8lib.c", // utf8
    "loslib.c", // os
    "liolib.c", // io
};

const lua_headers = [_][]const u8{ "lua.h", "luaconf.h", "lualib.h", "lauxlib.h" };

pub fn add(b: *std.Build, o: Options) void {
    const system_lua = b.systemIntegrationOption("lua", .{});
    const lua_dep = if (system_lua) null else b.lazyDependency("lua", .{});

    // The Lua C API: translated headers, plus the compiled sources when
    // vendored (`lua_c`), or the headers alone (`lua_h`) for siv.so, which
    // takes Lua from the process that loads it.
    const tc = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("lua_all.h",
            \\#include <lua.h>
            \\#include <lauxlib.h>
            \\#include <lualib.h>
            \\
        ),
        .target = o.target,
        .optimize = o.optimize,
    });
    if (lua_dep) |dep| tc.addIncludePath(dep.path("src"));
    const lua_h = tc.createModule();
    lua_h.pic = true;
    const lua_c = blk: {
        if (system_lua) {
            const m = tc.createModule();
            m.linkSystemLibrary("lua5.5", .{});
            break :blk m;
        }
        const m = tc.createModule();
        m.link_libc = true;
        m.pic = true;
        if (lua_dep) |dep| m.addCSourceFiles(.{
            .root = dep.path("src"),
            .files = &(core ++ allowed_libs),
            // POSIX for io.popen, os.tmpname, and the like; no
            // LUA_USE_DLOPEN, so package.loadlib and C searchers report
            // that dynamic libraries are disabled. Default visibility:
            // libsiv-lua exports the Lua API, limited by its version
            // script.
            .flags = &.{ "-std=gnu99", "-DLUA_USE_POSIX" },
        });
        m.linkSystemLibrary("m", .{});
        break :blk m;
    };

    const siv_wrapper = b.modules.get("siv") orelse @panic("src/abi/build_steps.zig must run first");
    const wrapper_source = siv_wrapper.root_source_file.?;

    // Generators and the binding read the schema as data (D3).
    const schema_for = struct {
        fn module(bb: *std.Build, target: ?std.Build.ResolvedTarget) *std.Build.Module {
            return bb.createModule(.{ .root_source_file = bb.path("src/abi/api.zig"), .target = target });
        }
    }.module;

    // One instance of the binding per artifact: libsiv-lua links libsiv.so,
    // the headless tests resolve the same calls to the exports in their
    // own binary.
    const Binding = struct {
        b: *std.Build,
        o: Options,
        lua_c: *std.Build.Module,
        wrapper_source: std.Build.LazyPath,
        fn module(self: @This()) *std.Build.Module {
            return self.moduleWith(
                self.b.createModule(.{ .root_source_file = self.wrapper_source }),
                self.b.createModule(.{ .root_source_file = self.b.path("src/abi/api.zig") }),
                self.lua_c,
                true,
            );
        }
        /// With the generated wrapper and the schema from `abi`, for a
        /// binary that already holds them, and the Lua headers with or
        /// without Lua (`bundled`: whether siv_lua_new and siv_lua_run,
        /// which need Lua's libraries, are exported).
        fn moduleWith(self: @This(), wrapper: *std.Build.Module, schema: *std.Build.Module, lua: *std.Build.Module, bundled: bool) *std.Build.Module {
            const options = self.b.addOptions();
            options.addOption(bool, "bundled", bundled);
            return self.b.createModule(.{
                .root_source_file = self.b.path("src/lua/lua.zig"),
                .target = self.o.target,
                .optimize = self.o.optimize,
                .link_libc = true,
                .pic = true,
                .imports = &.{
                    .{ .name = "siv", .module = wrapper },
                    .{ .name = "siv_schema", .module = schema },
                    .{ .name = "lua_c", .module = lua },
                    .{ .name = "lua_options", .module = options.createModule() },
                },
            });
        }
    };
    const binding: Binding = .{ .b = b, .o = o, .lua_c = lua_c, .wrapper_source = wrapper_source };

    // libsiv-lua.so: the binding and Lua, on top of libsiv.so (D23).
    const lib = b.addLibrary(.{
        .name = "siv-lua",
        .linkage = .dynamic,
        .version = o.version,
        .root_module = binding.module(),
    });
    lib.root_module.linkLibrary(o.shared);
    // Exports the Lua C API, luaopen_siv, and siv_lua_*, nothing else.
    lib.use_llvm = true;
    lib.use_lld = true;
    lib.setVersionScript(b.path("src/lua/siv-lua.map"));
    // Installed next to libsiv.so.
    lib.root_module.addRPathSpecial("$ORIGIN");
    b.installArtifact(lib);

    b.installFile("src/lua/siv_lua.h", "include/siv-lua/siv_lua.h");
    if (lua_dep) |dep| for (lua_headers) |h| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(dep.path(b.fmt("src/{s}", .{h})), .header, b.fmt("siv-lua/{s}", .{h})).step);
    };
    const pc = b.addWriteFiles().add("siv-lua.pc", b.fmt(
        \\prefix=${{pcfiledir}}/../..
        \\libdir=${{prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: siv-lua
        \\Description: Lua 5.5 binding for siv
        \\Version: {f}
        \\Requires: siv{s}
        \\Libs: -L${{libdir}} -lsiv-lua
        \\Cflags: -I${{includedir}}/siv-lua
        \\
    , .{ o.version, if (system_lua) " lua5.5" else "" }));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(pc, .lib, "pkgconfig/siv-lua.pc").step);

    // The runner.
    const runner = b.addExecutable(.{
        .name = "siv-lua",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/main.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
        }),
    });
    runner.root_module.linkLibrary(lib);
    runner.root_module.addRPathSpecial("$ORIGIN/../lib");
    b.installArtifact(runner);

    // siv.so: the same binding as a standard Lua C module for hosts that
    // embed Lua 5.5 themselves and for the stock interpreter. It contains
    // no Lua: lua_* resolve from the process that loads it. Installed where
    // Lua's default package.cpath looks under a prefix.
    const module_lib = b.addLibrary(.{
        .name = "siv-lua-module",
        .linkage = .dynamic,
        .root_module = binding.moduleWith(
            b.createModule(.{ .root_source_file = wrapper_source }),
            b.createModule(.{ .root_source_file = b.path("src/abi/api.zig") }),
            lua_h,
            false,
        ),
    });
    module_lib.root_module.linkLibrary(o.shared);
    module_lib.linker_allow_shlib_undefined = true;
    module_lib.use_llvm = true;
    module_lib.use_lld = true;
    module_lib.setVersionScript(b.path("src/lua/siv-module.map"));
    // lib/lua/5.5/siv.so finds lib/libsiv.so.
    module_lib.root_module.addRPathSpecial("$ORIGIN/../..");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(module_lib.getEmittedBin(), .lib, "lua/5.5/siv.so").step);

    // Annotations for lua-language-server, from the same mapping as the
    // binding (src/lua/mapping.zig).
    const gen = b.addExecutable(.{
        .name = "siv-lua-gen-types",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/gen_types.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "siv_schema", .module = schema_for(b, b.graph.host) }},
        }),
    });
    const gen_run = b.addRunArtifact(gen);
    const types = gen_run.addOutputFileArg("siv.lua");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(types, .prefix, "share/siv/lua/siv.lua").step);

    // NOTICES (D25): siv, the Zig runtime, and the Lua compiled in.
    const notices = b.addExecutable(.{
        .name = "siv-lua-notices",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/lua/gen_notices.zig"), .target = b.graph.host }),
    });
    const notices_run = b.addRunArtifact(notices);
    const notices_out = notices_run.addOutputFileArg("NOTICES");
    notices_run.addFileArg(b.path("LICENSE"));
    notices_run.addFileArg(b.path("src/notices/zig-LICENSE.txt"));
    if (lua_dep) |dep| notices_run.addFileArg(dep.path("src/lua.h"));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(notices_out, .prefix, "share/licenses/siv-lua/NOTICES").step);

    // Tests: the binding against libsiv.so on the headless backend, the
    // examples, and the generator.
    const test_lua = b.step("test-lua", "Run the Lua binding tests");
    const module_tests = b.addTest(.{ .name = "lua", .root_module = binding.module(), .filters = o.test_filters });
    module_tests.root_module.linkLibrary(o.shared);
    const module_run = b.addRunArtifact(module_tests);
    test_lua.dependOn(&module_run.step);
    const gen_tests = b.addTest(.{ .name = "lua-gen-types", .root_module = gen.root_module, .filters = o.test_filters });
    test_lua.dependOn(&b.addRunArtifact(gen_tests).step);
    const notices_tests = b.addTest(.{ .name = "lua-notices", .root_module = notices.root_module, .filters = o.test_filters });
    test_lua.dependOn(&b.addRunArtifact(notices_tests).step);
    test_lua.dependOn(&notices_run.step);
    // The runner and the installed annotations build in `test`.
    test_lua.dependOn(&runner.step);
    test_lua.dependOn(&gen_run.step);
    o.test_step.dependOn(test_lua);

    // siv.so from the stock lua interpreter, built from the pinned
    // release for the test only (with -fsys=lua the system's would be
    // needed, so the test is skipped): every library, linit.c, lua.c, and
    // dlopen, with its symbols exported for C modules, as distributions
    // build it.
    if (lua_dep) |dep| {
        const interp = b.addExecutable(.{
            .name = "lua",
            .root_module = b.createModule(.{ .target = o.target, .optimize = o.optimize, .link_libc = true }),
        });
        interp.root_module.addCSourceFiles(.{
            .root = dep.path("src"),
            .files = &(core ++ allowed_libs ++ [_][]const u8{ "ldblib.c", "linit.c", "lua.c" }),
            .flags = &.{ "-std=gnu99", "-DLUA_USE_LINUX" },
        });
        interp.root_module.linkSystemLibrary("m", .{});
        interp.root_module.linkSystemLibrary("dl", .{});
        interp.rdynamic = true;
        const run_module = b.addRunArtifact(interp);
        run_module.setCwd(b.path("."));
        run_module.addFileArg(b.path("src/lua/testdata/module.lua"));
        run_module.addFileArg(module_lib.getEmittedBin());
        run_module.expectExitCode(0);
        test_lua.dependOn(&run_module.step);
    }

    // Golden images of Lua applications (test/lua/), in test/headless.zig.
    // The binding compiled into that binary shares its wrapper and schema
    // with the abi module there.
    const abi = o.headless.root_module.import_table.get("abi").?;
    o.headless.root_module.addImport("lua", binding.moduleWith(abi.import_table.get("siv").?, abi, lua_c, true));

    // Lua applications on sway, in process and through the installed
    // runner (src/lua/integration_tests.zig). Not in `test`.
    const helpers = b.addOptions();
    helpers.addOptionPath("runner", runner.getEmittedBin());
    const integration_module = binding.module();
    const integration = b.addTest(.{
        .name = "lua-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/integration_tests.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "lua", .module = integration_module },
                .{ .name = "platform", .module = o.headless.root_module.import_table.get("platform").? },
                .{ .name = "helpers", .module = helpers.createModule() },
            },
        }),
        .filters = o.test_filters,
    });
    integration.root_module.linkLibrary(o.shared);
    const integration_run = b.addRunArtifact(integration);
    integration_run.has_side_effects = true; // depends on the installed sway
    // The runner finds libsiv-lua.so and libsiv.so next to each other.
    integration_run.step.dependOn(&runner.step);
    o.integration_step.dependOn(&integration_run.step);
    b.step("test-integration-lua", "Run the Lua binding against headless sway").dependOn(&integration_run.step);
}
