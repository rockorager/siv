//! Image decoding part of the build graph, called from build.zig: the
//! `image` module, baskingspot's image package (PNG, APNG, JPEG, GIF,
//! WebP, and JPEG XL in Zig), and Little CMS for their color (D19).
//! Owned by the image decoding workstream.
//!
//! Little CMS, the one C library, is vendored from build.zig.zon and
//! fetched lazily, or linked from the system with `-fsys=lcms2`. siv
//! reaches it only through its own small C interface in
//! src/image/color.h, compiled into the `image_c` module, so `-fsys`
//! builds and vendored builds share every line of siv's code.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    scene: *std.Build.Module,
    /// Set by `add`: the module the C objects are linked through.
    image_c: *std.Build.Module = undefined,
};

pub const Result = struct {
    image: *std.Build.Module,
    /// pkg-config names of the system libraries linked with -fsys, each
    /// with a leading space, for siv.pc's Requires.private.
    requires: []const u8,
};

/// Vendored C stays hidden: libsiv.so exports only the siv ABI. Under
/// `--fuzz`, C is not instrumented for coverage: Zig's fuzzer reads only
/// the PC table its own backend writes, and clang's does not match it.
const c_flags: []const []const u8 = &.{ "-fvisibility=hidden", "-fno-sanitize=fuzzer-no-link" };

/// A C object, compiled once and linked into every
/// artifact that imports `image`, libsiv.a included. C sources on a module
/// are compiled again for each artifact (their cache entries are not
/// shared between compilations), so every C file here is in one of these.
fn object(b: *std.Build, o: Options, name: []const u8, cpp: bool) *std.Build.Module {
    const obj = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .link_libcpp = cpp,
            .pic = true,
            // No debug info: it is most of what linking a test binary
            // reads and writes (D25).
            .strip = true,
        }),
    });
    o.image_c.addObject(obj);
    return obj.root_module;
}

pub fn add(b: *std.Build, o_: Options) Result {
    var o = o_;
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/image/color.h"),
        .target = o.target,
        .optimize = o.optimize,
    });
    const c = tc.createModule();
    c.pic = true;
    c.link_libc = true;
    o.image_c = c;
    var requires: std.ArrayList(u8) = .empty;
    const shim_flags = c_flags ++ &[_][]const u8{"-std=c99"};

    // Little CMS: ICC profiles.
    if (b.systemIntegrationOption("lcms2", .{})) {
        c.linkSystemLibrary("lcms2", .{});
        requires.appendSlice(b.allocator, " lcms2") catch @panic("OOM");
        const m = object(b, o, "color", false);
        m.linkSystemLibrary("lcms2", .{});
        m.addCSourceFile(.{ .file = b.path("src/image/color.c"), .flags = shim_flags });
    } else if (b.lazyDependency("lcms2", .{})) |dep| {
        const m = object(b, o, "lcms2", false);
        m.addIncludePath(dep.path("include"));
        m.addCSourceFile(.{ .file = b.path("src/image/color.c"), .flags = shim_flags });
        m.addCSourceFiles(.{
            .root = dep.path("src"),
            .files = &.{
                "cmsalpha.c", "cmscam02.c", "cmscgats.c", "cmscnvrt.c", "cmserr.c",   "cmsgamma.c",
                "cmsgmt.c",   "cmshalf.c",  "cmsintrp.c", "cmsio0.c",   "cmsio1.c",   "cmslut.c",
                "cmsmd5.c",   "cmsmtrx.c",  "cmsnamed.c", "cmsopt.c",   "cmspack.c",  "cmspcs.c",
                "cmsplugin.c", "cmsps2.c",  "cmssamp.c",  "cmssm.c",    "cmstypes.c", "cmsvirt.c",
                "cmswtpnt.c", "cmsxform.c",
            },
            .flags = shim_flags,
        });
    }

    // baskingspot's image package: PNG, APNG, JPEG, GIF, WebP, and JPEG
    // XL. An object, like the C libraries, so that the decoders compile
    // once per build rather than in every compilation that imports
    // `image` (D25).
    const native = b.addObject(.{
        .name = "image-native",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/image/native.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .pic = true,
            .strip = true,
            .imports = &.{.{ .name = "baskingspot_image", .module = b.dependency("baskingspot_image", .{
                .target = o.target,
                .optimize = o.optimize,
            }).module("image") }},
        }),
    });
    // LLVM writes it: the self-hosted backend's copy had its ELF header
    // zeroed in an orb, after the checkout was copied (D19).
    native.use_llvm = true;
    c.addObject(native);

    const image = b.createModule(.{
        .root_source_file = b.path("src/image/image.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .imports = &.{
            .{ .name = "scene", .module = o.scene },
            .{ .name = "image_c", .module = c },
        },
        .link_libc = true,
        .pic = true,
    });
    return .{ .image = image, .requires = requires.items };
}
