//! Vulkan renderer part of the build graph, called from build.zig: the
//! Vulkan headers as a C module, the compiled shaders, and the step that
//! compiles them. The Vulkan renderer workstream owns this file.
//!
//! Shaders are GLSL under src/render/vulkan/shaders. Their SPIR-V is
//! committed beside them (`*.spv`, with `glsl.sha256`, the hashes of the
//! GLSL it was compiled from), so builds need no shader compiler (D10).
//! `zig build shaders` compiles them again with glslang built from the
//! pinned source in build.zig.zon and rewrites those files;
//! `-fsys=glslang` runs the system `glslangValidator` instead. The
//! render_vulkan tests fail when the GLSL no longer matches the hashes.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// GLSLang version string for the generated build_info.h; keep in step
/// with build.zig.zon.
const glslang_version = .{ 16, 6, 0 };

/// Each output is the concatenation of common.glsl and its stage file.
const shaders = [_]struct { name: []const u8, stage: []const u8 }{
    .{ .name = "quad.vert", .stage = "vert" },
    .{ .name = "draw.frag", .stage = "frag" },
    .{ .name = "blur.frag", .stage = "frag" },
    .{ .name = "encode.frag", .stage = "frag" },
};

/// The `vulkan` C module (headers only: libvulkan is loaded at run time,
/// so libsiv runs on machines without it) and the `shaders` module, which
/// embeds the committed SPIR-V (src/render/vulkan/shaders/shaders.zig).
pub fn add(b: *std.Build, o: Options) struct { vulkan: *std.Build.Module, shaders: *std.Build.Module } {
    const tc = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("vulkan.h",
            \\#define VK_NO_PROTOTYPES
            \\#define VK_USE_PLATFORM_WAYLAND_KHR
            \\#include <vulkan/vulkan.h>
            \\
        ),
        .target = o.target,
        .optimize = o.optimize,
    });
    const vulkan = tc.createModule();
    vulkan.pic = true;
    const module = b.createModule(.{ .root_source_file = b.path("src/render/vulkan/shaders/shaders.zig") });
    addCompileStep(b);
    return .{ .vulkan = vulkan, .shaders = module };
}

/// `zig build shaders`: compiles the GLSL and writes the SPIR-V and the
/// GLSL's hashes into the source tree.
fn addCompileStep(b: *std.Build) void {
    const step = b.step("shaders", "Compile the Vulkan shaders and update the committed SPIR-V");
    const dir = "src/render/vulkan/shaders";
    const update = b.addUpdateSourceFiles();
    step.dependOn(&update.step);
    const system = b.systemIntegrationOption("glslang", .{});
    const compiler: ?*std.Build.Step.Compile = if (system) null else glslangCompiler(b) orelse return;
    const common = b.path(dir ++ "/common.glsl");
    for (shaders) |s| {
        const source = b.path(b.fmt("{s}/{s}", .{ dir, s.name }));
        const out = if (compiler) |exe| blk: {
            const run = b.addRunArtifact(exe);
            run.addArg(s.stage);
            run.addFileArg(common);
            run.addFileArg(source);
            break :blk run.addOutputFileArg(b.fmt("{s}.spv", .{s.name}));
        } else blk: {
            // glslangValidator takes one file: concatenate first.
            const cat = b.addSystemCommand(&.{"cat"});
            cat.addFileArg(common);
            cat.addFileArg(source);
            const glsl = cat.captureStdOut(.{ .basename = b.fmt("{s}.glsl", .{s.name}) });
            const run = b.addSystemCommand(&.{ "glslangValidator", "-V", "--target-env", "vulkan1.3", "-S", s.stage, "-o" });
            const spv = run.addOutputFileArg(b.fmt("{s}.spv", .{s.name}));
            run.addFileArg(glsl);
            break :blk spv;
        };
        update.addCopyFileToSource(out, b.fmt("{s}/{s}.spv", .{ dir, s.name }));
    }
    // The hashes the tests compare with the GLSL, by file name.
    const sum = b.addSystemCommand(&.{ "sha256sum", "common.glsl" });
    sum.setCwd(b.path(dir));
    sum.addFileInput(common);
    for (shaders) |s| {
        sum.addArg(s.name);
        sum.addFileInput(b.path(b.fmt("{s}/{s}", .{ dir, s.name })));
    }
    update.addCopyFileToSource(sum.captureStdOut(.{ .basename = "glsl.sha256" }), dir ++ "/glsl.sha256");
}

/// siv-glslc: glslang (GLSL front end and SPIR-V back end, no HLSL, no
/// optimizer) behind a small driver, built for the host. Null until the
/// lazy dependency is fetched.
fn glslangCompiler(b: *std.Build) ?*std.Build.Step.Compile {
    const dep = b.lazyDependency("glslang", .{}) orelse return null;
    const host = b.graph.host;
    const gen = b.addWriteFiles();
    _ = gen.add("glslang/build_info.h", b.fmt(
        \\#ifndef GLSLANG_BUILD_INFO
        \\#define GLSLANG_BUILD_INFO
        \\#define GLSLANG_VERSION_MAJOR {d}
        \\#define GLSLANG_VERSION_MINOR {d}
        \\#define GLSLANG_VERSION_PATCH {d}
        \\#define GLSLANG_VERSION_FLAVOR ""
        \\#define GLSLANG_VERSION_GREATER_THAN(major, minor, patch) ((GLSLANG_VERSION_MAJOR) > (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) > (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH) > (patch)))))
        \\#define GLSLANG_VERSION_GREATER_OR_EQUAL_TO(major, minor, patch) ((GLSLANG_VERSION_MAJOR) > (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) > (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH >= (patch))))))
        \\#define GLSLANG_VERSION_LESS_THAN(major, minor, patch) ((GLSLANG_VERSION_MAJOR) < (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) < (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH) < (patch)))))
        \\#define GLSLANG_VERSION_LESS_OR_EQUAL_TO(major, minor, patch) ((GLSLANG_VERSION_MAJOR) < (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) < (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH <= (patch))))))
        \\#endif
        \\
    , glslang_version));

    const tc = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("glslang.h",
            \\#include <glslang/Include/glslang_c_interface.h>
            \\#include <glslang/Public/resource_limits_c.h>
            \\
        ),
        .target = host,
        .optimize = .Debug,
    });
    tc.addIncludePath(dep.path(""));
    const glslang = tc.createModule();

    const exe = b.addExecutable(.{
        .name = "siv-glslc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render/vulkan/glslc.zig"),
            .target = host,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{.{ .name = "glslang", .module = glslang }},
        }),
    });
    const m = exe.root_module;
    m.link_libcpp = true;
    m.addIncludePath(dep.path(""));
    m.addIncludePath(gen.getDirectory());
    m.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &glslang_sources,
        .flags = &.{ "-std=c++17", "-DENABLE_SPIRV=1", "-DENABLE_OPT=0", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=undefined", "-w" },
    });
    return exe;
}

const glslang_sources = [_][]const u8{
    "glslang/CInterface/glslang_c_interface.cpp",
    "glslang/GenericCodeGen/CodeGen.cpp",
    "glslang/GenericCodeGen/Link.cpp",
    "glslang/MachineIndependent/Constant.cpp",
    "glslang/MachineIndependent/InfoSink.cpp",
    "glslang/MachineIndependent/Initialize.cpp",
    "glslang/MachineIndependent/IntermTraverse.cpp",
    "glslang/MachineIndependent/Intermediate.cpp",
    "glslang/MachineIndependent/ParseContextBase.cpp",
    "glslang/MachineIndependent/ParseHelper.cpp",
    "glslang/MachineIndependent/PoolAlloc.cpp",
    "glslang/MachineIndependent/RemoveTree.cpp",
    "glslang/MachineIndependent/Scan.cpp",
    "glslang/MachineIndependent/ShaderLang.cpp",
    "glslang/MachineIndependent/SpirvIntrinsics.cpp",
    "glslang/MachineIndependent/SymbolTable.cpp",
    "glslang/MachineIndependent/Versions.cpp",
    "glslang/MachineIndependent/attribute.cpp",
    "glslang/MachineIndependent/glslang_tab.cpp",
    "glslang/MachineIndependent/intermOut.cpp",
    "glslang/MachineIndependent/iomapper.cpp",
    "glslang/MachineIndependent/limits.cpp",
    "glslang/MachineIndependent/linkValidate.cpp",
    "glslang/MachineIndependent/parseConst.cpp",
    "glslang/MachineIndependent/preprocessor/Pp.cpp",
    "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
    "glslang/MachineIndependent/preprocessor/PpContext.cpp",
    "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
    "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
    "glslang/MachineIndependent/propagateNoContraction.cpp",
    "glslang/MachineIndependent/reflection.cpp",
    "glslang/OSDependent/Unix/ossource.cpp",
    "glslang/ResourceLimits/ResourceLimits.cpp",
    "glslang/ResourceLimits/resource_limits_c.cpp",
    "SPIRV/CInterface/spirv_c_interface.cpp",
    "SPIRV/GlslangToSpv.cpp",
    "SPIRV/InReadableOrder.cpp",
    "SPIRV/Logger.cpp",
    "SPIRV/SpvBuilder.cpp",
    "SPIRV/SpvPostProcess.cpp",
    "SPIRV/SpvTools.cpp",
    "SPIRV/disassemble.cpp",
    "SPIRV/doc.cpp",
};
