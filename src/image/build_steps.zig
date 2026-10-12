//! Image decoding part of the build graph, called from build.zig: the
//! `image` module and the C decoders behind it (D19). Owned by the image
//! decoding workstream.
//!
//! Every library is vendored from build.zig.zon and fetched lazily, or
//! linked from the system with `-fsys=<name>`: lcms2, libwebp, dav1d,
//! libavif, libjxl. wuffs is a single C file without a system library.
//! siv reaches them only through its own small C interfaces in
//! src/image/*.h, compiled into the `image_c` module, so `-fsys` builds and
//! vendored builds share every line of siv's code.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    scene: *std.Build.Module,
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

const webp_sources = [_][]const u8{
    "dec/alpha_dec.c",                "dec/buffer_dec.c",                "dec/frame_dec.c",              "dec/idec_dec.c",
    "dec/io_dec.c",                   "dec/quant_dec.c",                 "dec/tree_dec.c",               "dec/vp8_dec.c",
    "dec/vp8l_dec.c",                 "dec/webp_dec.c",                  "demux/anim_decode.c",          "demux/demux.c",
    "dsp/alpha_processing.c",         "dsp/alpha_processing_mips_dsp_r2.c", "dsp/alpha_processing_neon.c", "dsp/alpha_processing_sse2.c",
    "dsp/alpha_processing_sse41.c",   "dsp/cpu.c",                       "dsp/dec.c",                    "dsp/dec_clip_tables.c",
    "dsp/dec_mips32.c",               "dsp/dec_mips_dsp_r2.c",           "dsp/dec_msa.c",                "dsp/dec_neon.c",
    "dsp/dec_sse2.c",                 "dsp/dec_sse41.c",                 "dsp/filters.c",                "dsp/filters_mips_dsp_r2.c",
    "dsp/filters_msa.c",              "dsp/filters_neon.c",              "dsp/filters_sse2.c",           "dsp/lossless.c",
    "dsp/lossless_mips_dsp_r2.c",     "dsp/lossless_msa.c",              "dsp/lossless_neon.c",          "dsp/lossless_sse2.c",
    "dsp/lossless_sse41.c",           "dsp/rescaler.c",                  "dsp/rescaler_mips32.c",        "dsp/rescaler_mips_dsp_r2.c",
    "dsp/rescaler_msa.c",             "dsp/rescaler_neon.c",             "dsp/rescaler_sse2.c",          "dsp/upsampling.c",
    "dsp/upsampling_mips_dsp_r2.c",   "dsp/upsampling_msa.c",            "dsp/upsampling_neon.c",        "dsp/upsampling_sse2.c",
    "dsp/upsampling_sse41.c",         "dsp/yuv.c",                       "dsp/yuv_mips32.c",             "dsp/yuv_mips_dsp_r2.c",
    "dsp/yuv_neon.c",                 "dsp/yuv_sse2.c",                  "dsp/yuv_sse41.c",              "utils/bit_reader_utils.c",
    "utils/color_cache_utils.c",      "utils/filters_utils.c",           "utils/huffman_utils.c",        "utils/palette.c",
    "utils/quant_levels_dec_utils.c", "utils/random_utils.c",            "utils/rescaler_utils.c",       "utils/thread_utils.c",
    "utils/utils.c",
};

/// dav1d's sources in C only: its assembly needs nasm, which siv's build
/// does without (the C paths are slower, not wrong). The `_tmpl` files
/// build once per bit depth, and meson's generated headers are written
/// here.
fn addDav1d(b: *std.Build, m: *std.Build.Module, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget) void {
    const arch = target.result.cpu.arch;
    const x86 = arch == .x86_64 or arch == .x86;
    const gen = b.addWriteFiles();
    _ = gen.add("config.h", b.fmt(
        \\#define ARCH_AARCH64 {d}
        \\#define ARCH_ARM {d}
        \\#define ARCH_LOONGARCH 0
        \\#define ARCH_LOONGARCH32 0
        \\#define ARCH_LOONGARCH64 0
        \\#define ARCH_PPC64LE 0
        \\#define ARCH_RISCV 0
        \\#define ARCH_RV32 0
        \\#define ARCH_RV64 0
        \\#define ARCH_X86 {d}
        \\#define ARCH_X86_32 {d}
        \\#define ARCH_X86_64 {d}
        \\#define CONFIG_8BPC 1
        \\#define CONFIG_16BPC 1
        \\#define CONFIG_LOG 0
        \\#define CONFIG_MACOS_KPERF 0
        \\#define ENDIANNESS_BIG {d}
        \\#define HAVE_ASM 0
        \\#define HAVE_C11_GENERIC 1
        \\#define HAVE_CLOCK_GETTIME 1
        \\#define HAVE_DLSYM 0
        \\#define HAVE_POSIX_MEMALIGN 1
        \\#define HAVE_MEMALIGN 1
        \\#define HAVE_ALIGNED_ALLOC 1
        \\#define HAVE_SYS_TYPES_H 1
        \\#define HAVE_UNISTD_H 1
        \\#define HAVE_IO_H 0
        \\#define HAVE_PTHREAD_NP_H 0
        \\#define HAVE_GETAUXVAL 1
        \\#define HAVE_ELF_AUX_INFO 0
        \\#define HAVE_PTHREAD_GETAFFINITY_NP 0
        \\#define HAVE_PTHREAD_SETAFFINITY_NP 0
        \\#define HAVE_PTHREAD_SETNAME_NP 0
        \\#define HAVE_PTHREAD_SET_NAME_NP 0
        \\#define TRIM_DSP_FUNCTIONS 0
        \\
    , .{
        @intFromBool(arch == .aarch64),
        @intFromBool(arch == .arm or arch == .thumb),
        @intFromBool(x86),
        @intFromBool(arch == .x86),
        @intFromBool(arch == .x86_64),
        @intFromBool(arch.endian() == .big),
    }));
    _ = gen.add("vcs_version.h", "#define DAV1D_VERSION \"1.5.1\"\n");
    m.addIncludePath(gen.getDirectory());
    m.addIncludePath(dep.path(""));
    m.addIncludePath(dep.path("include"));
    const flags = c_flags ++ &[_][]const u8{ "-std=c99", "-D_GNU_SOURCE" };
    // clang crashes on qm.c's tables with optimization and array-bounds
    // checks (ReleaseSafe, --fuzz).
    m.addCSourceFile(.{ .file = dep.path("src/qm.c"), .flags = flags ++ &[_][]const u8{"-fno-sanitize=array-bounds"} });
    m.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &.{
            "cdf.c",         "cpu.c",    "ctx.c",    "data.c",      "decode.c",  "dequant_tables.c", "getbits.c",
            "intra_edge.c",  "itx_1d.c", "lf_mask.c", "lib.c",      "log.c",     "mem.c",            "msac.c",
            "obu.c",         "pal.c",    "picture.c",              "ref.c",     "refmvs.c",         "scan.c",
            "tables.c",      "thread_task.c", "warpmv.c", "wedge.c",
        },
        .flags = flags,
    });
    const tmpl = [_][]const u8{
        "cdef_apply_tmpl.c", "cdef_tmpl.c",   "fg_apply_tmpl.c", "filmgrain_tmpl.c",       "ipred_prepare_tmpl.c",
        "ipred_tmpl.c",      "itx_tmpl.c",    "lf_apply_tmpl.c", "loopfilter_tmpl.c",      "looprestoration_tmpl.c",
        "lr_apply_tmpl.c",   "mc_tmpl.c",     "recon_tmpl.c",
    };
    m.addCSourceFiles(.{ .root = dep.path("src"), .files = &tmpl, .flags = flags ++ &[_][]const u8{"-DBITDEPTH=8"} });
    m.addCSourceFiles(.{ .root = dep.path("src"), .files = &tmpl, .flags = flags ++ &[_][]const u8{"-DBITDEPTH=16"} });
}

/// libjxl's decoder, without the boxes and JPEG reconstruction that need
/// Brotli and without a CMS of its own: siv converts ICC profiles with
/// Little CMS, and libjxl renders XYB to linear sRGB by itself.
fn addJxl(b: *std.Build, m: *std.Build.Module, jxl: *std.Build.Dependency, hwy: *std.Build.Dependency) void {
    const gen = b.addWriteFiles();
    _ = gen.add("jxl/version.h",
        \\#ifndef JXL_VERSION_H_
        \\#define JXL_VERSION_H_
        \\#define JPEGXL_MAJOR_VERSION 0
        \\#define JPEGXL_MINOR_VERSION 11
        \\#define JPEGXL_PATCH_VERSION 1
        \\#define JPEGXL_COMPUTE_NUMERIC_VERSION(major, minor, patch) (((major) << 24) | ((minor) << 16) | ((patch) << 8) | 0)
        \\#define JPEGXL_NUMERIC_VERSION JPEGXL_COMPUTE_NUMERIC_VERSION(0, 11, 1)
        \\#endif
        \\
    );
    const export_h =
        \\#define JXL_EXPORT
        \\#define JXL_NO_EXPORT
        \\#define JXL_DEPRECATED __attribute__((__deprecated__))
        \\#define JXL_CMS_EXPORT
        \\#define JXL_THREADS_EXPORT
        \\
    ;
    _ = gen.add("jxl/jxl_export.h", export_h);
    _ = gen.add("jxl/jxl_cms_export.h", export_h);
    _ = gen.add("jxl/jxl_threads_export.h", export_h);
    m.addIncludePath(gen.getDirectory());
    m.addIncludePath(jxl.path("lib/include"));
    m.addIncludePath(jxl.path(""));
    m.addIncludePath(hwy.path(""));
    m.link_libcpp = true;
    m.addCSourceFile(.{ .file = b.path("src/image/jxl.c"), .flags = c_flags ++ &[_][]const u8{"-std=c99"} });
    const cxx = c_flags ++ &[_][]const u8{
        "-std=c++17",
        "-fno-exceptions",
        "-fno-rtti",
        "-DJPEGXL_ENABLE_BOXES=0",
        "-DJPEGXL_ENABLE_TRANSCODE_JPEG=0",
        "-DJPEGXL_ENABLE_SKCMS=0",
        "-DJXL_INTERNAL_LIBRARY_BUILD",
        "-DHWY_DISABLE_FUTEX",
    };
    m.addCSourceFiles(.{
        .root = hwy.path("hwy"),
        .files = &.{ "abort.cc", "aligned_allocator.cc", "per_target.cc", "print.cc", "targets.cc", "timer.cc" },
        .flags = cxx,
    });
    m.addCSourceFiles(.{ .root = jxl.path("lib"), .files = &jxl_sources, .flags = cxx });
}

const jxl_sources = [_][]const u8{
    "jxl/ac_strategy.cc",                              "jxl/alpha.cc",                                "jxl/ans_common.cc",
    "jxl/blending.cc",                                 "jxl/chroma_from_luma.cc",                     "jxl/coeff_order.cc",
    "jxl/color_encoding_internal.cc",                  "jxl/compressed_dc.cc",                        "jxl/convolve_separable5.cc",
    "jxl/convolve_slow.cc",                            "jxl/convolve_symmetric3.cc",                  "jxl/convolve_symmetric5.cc",
    "jxl/dct_scales.cc",                               "jxl/dec_ans.cc",                              "jxl/dec_cache.cc",
    "jxl/dec_context_map.cc",                          "jxl/dec_external_image.cc",                   "jxl/dec_frame.cc",
    "jxl/dec_group.cc",                                "jxl/dec_group_border.cc",                     "jxl/dec_huffman.cc",
    "jxl/dec_modular.cc",                              "jxl/dec_noise.cc",                            "jxl/dec_patch_dictionary.cc",
    "jxl/dec_xyb.cc",                                  "jxl/decode.cc",                               "jxl/entropy_coder.cc",
    "jxl/epf.cc",                                      "jxl/fields.cc",                               "jxl/frame_header.cc",
    "jxl/headers.cc",                                  "jxl/huffman_table.cc",                        "jxl/icc_codec.cc",
    "jxl/icc_codec_common.cc",                         "jxl/image.cc",                                "jxl/image_bundle.cc",
    "jxl/image_metadata.cc",                           "jxl/image_ops.cc",                            "jxl/loop_filter.cc",
    "jxl/luminance.cc",                                "jxl/memory_manager_internal.cc",              "jxl/modular/encoding/dec_ma.cc",
    "jxl/modular/encoding/encoding.cc",                "jxl/modular/modular_image.cc",                "jxl/modular/transform/palette.cc",
    "jxl/modular/transform/rct.cc",                    "jxl/modular/transform/squeeze.cc",            "jxl/modular/transform/transform.cc",
    "jxl/opsin_params.cc",                             "jxl/passes_state.cc",                         "jxl/quant_weights.cc",
    "jxl/quantizer.cc",                                "jxl/render_pipeline/low_memory_render_pipeline.cc", "jxl/render_pipeline/render_pipeline.cc",
    "jxl/render_pipeline/simple_render_pipeline.cc",   "jxl/render_pipeline/stage_blending.cc",       "jxl/render_pipeline/stage_chroma_upsampling.cc",
    "jxl/render_pipeline/stage_cms.cc",                "jxl/render_pipeline/stage_epf.cc",            "jxl/render_pipeline/stage_from_linear.cc",
    "jxl/render_pipeline/stage_gaborish.cc",           "jxl/render_pipeline/stage_noise.cc",          "jxl/render_pipeline/stage_patches.cc",
    "jxl/render_pipeline/stage_splines.cc",            "jxl/render_pipeline/stage_spot.cc",           "jxl/render_pipeline/stage_to_linear.cc",
    "jxl/render_pipeline/stage_tone_mapping.cc",       "jxl/render_pipeline/stage_upsampling.cc",     "jxl/render_pipeline/stage_write.cc",
    "jxl/render_pipeline/stage_xyb.cc",                "jxl/render_pipeline/stage_ycbcr.cc",          "jxl/simd_util.cc",
    "jxl/splines.cc",                                  "jxl/toc.cc",
};

pub fn add(b: *std.Build, o: Options) Result {
    const tc = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("image_c.h",
            \\#include "wuffs.h"
            \\#include "color.h"
            \\#include "webp.h"
            \\#include "avif.h"
            \\#include "jxl.h"
            \\
        ),
        .target = o.target,
        .optimize = o.optimize,
    });
    tc.addIncludePath(b.path("src/image"));
    const c = tc.createModule();
    c.pic = true;
    c.link_libc = true;
    var requires: std.ArrayList(u8) = .empty;

    // wuffs: PNG, APNG, JPEG, GIF.
    if (b.lazyDependency("wuffs", .{})) |dep| {
        c.addIncludePath(dep.path("release/c"));
        // wuffs calls its codecs through vtables of type-erased function
        // pointers, which -fsanitize=function (ReleaseSafe) traps.
        c.addCSourceFile(.{ .file = b.path("src/image/wuffs.c"), .flags = c_flags ++ &[_][]const u8{ "-std=c99", "-fno-sanitize=function" } });
    }

    // Little CMS: ICC profiles.
    if (b.systemIntegrationOption("lcms2", .{})) {
        c.linkSystemLibrary("lcms2", .{});
        requires.appendSlice(b.allocator, " lcms2") catch @panic("OOM");
        c.addCSourceFile(.{ .file = b.path("src/image/color.c"), .flags = c_flags ++ &[_][]const u8{"-std=c99"} });
    } else if (b.lazyDependency("lcms2", .{})) |dep| {
        c.addIncludePath(dep.path("include"));
        c.addCSourceFile(.{ .file = b.path("src/image/color.c"), .flags = c_flags ++ &[_][]const u8{"-std=c99"} });
        c.addCSourceFiles(.{
            .root = dep.path("src"),
            .files = &.{
                "cmsalpha.c", "cmscam02.c", "cmscgats.c", "cmscnvrt.c", "cmserr.c",   "cmsgamma.c",
                "cmsgmt.c",   "cmshalf.c",  "cmsintrp.c", "cmsio0.c",   "cmsio1.c",   "cmslut.c",
                "cmsmd5.c",   "cmsmtrx.c",  "cmsnamed.c", "cmsopt.c",   "cmspack.c",  "cmspcs.c",
                "cmsplugin.c", "cmsps2.c",  "cmssamp.c",  "cmssm.c",    "cmstypes.c", "cmsvirt.c",
                "cmswtpnt.c", "cmsxform.c",
            },
            .flags = c_flags ++ &[_][]const u8{"-std=c99"},
        });
    }

    // libwebp: still and animated WebP.
    const shim_flags = c_flags ++ &[_][]const u8{"-std=c99"};
    if (b.systemIntegrationOption("libwebp", .{})) {
        c.linkSystemLibrary("libwebpdemux", .{});
        c.linkSystemLibrary("libwebp", .{});
        requires.appendSlice(b.allocator, " libwebpdemux libwebp") catch @panic("OOM");
        c.addCSourceFile(.{ .file = b.path("src/image/webp.c"), .flags = shim_flags });
    } else if (b.lazyDependency("libwebp", .{})) |dep| {
        c.addIncludePath(dep.path("src"));
        c.addIncludePath(dep.path(""));
        c.addCSourceFile(.{ .file = b.path("src/image/webp.c"), .flags = shim_flags });
        // The decoder and demuxer of libwebp's makefile.unix, without the
        // encoder.
        c.addCSourceFiles(.{
            .root = dep.path("src"),
            .files = &webp_sources,
            .flags = shim_flags,
        });
    }

    // libavif with dav1d: still and animated AVIF.
    if (b.systemIntegrationOption("libavif", .{})) {
        c.linkSystemLibrary("libavif", .{});
        requires.appendSlice(b.allocator, " libavif") catch @panic("OOM");
        c.addCSourceFile(.{ .file = b.path("src/image/avif.c"), .flags = shim_flags });
    } else if (b.lazyDependency("libavif", .{})) |avif| {
        c.addIncludePath(avif.path("include"));
        c.addIncludePath(avif.path("third_party/libyuv/include"));
        c.addCSourceFile(.{ .file = b.path("src/image/avif.c"), .flags = shim_flags });
        // The part of libyuv (BSD-3-Clause) libavif bundles for scaling.
        c.addCSourceFiles(.{
            .root = avif.path("third_party/libyuv/source"),
            .files = &.{ "scale.c", "scale_common.c", "scale_any.c", "row_common.c", "planar_functions.c" },
            .flags = c_flags ++ &[_][]const u8{"-std=c99"},
        });
        c.addCSourceFiles(.{
            .root = avif.path("src"),
            .files = &.{
                "alpha.c",      "avif.c",       "colr.c",      "colrconvert.c", "diag.c",           "exif.c",
                "gainmap.c",    "io.c",         "mem.c",       "obu.c",         "properties.c",     "rawdata.c",
                "read.c",       "reformat.c",   "reformat_libsharpyuv.c", "reformat_libyuv.c", "scale.c", "stream.c",
                "utils.c",      "write.c",      "codec_dav1d.c",
            },
            .flags = c_flags ++ &[_][]const u8{ "-std=c99", "-DAVIF_CODEC_DAV1D=1" },
        });
        // dav1d: -fsys=dav1d links the system copy under the vendored
        // libavif.
        if (b.systemIntegrationOption("dav1d", .{})) {
            c.linkSystemLibrary("dav1d", .{});
            requires.appendSlice(b.allocator, " dav1d") catch @panic("OOM");
        } else if (b.lazyDependency("dav1d", .{})) |dav1d| addDav1d(b, c, dav1d, o.target);
    }

    // libjxl with Highway: still and animated JPEG XL.
    if (b.systemIntegrationOption("libjxl", .{})) {
        c.linkSystemLibrary("libjxl", .{});
        requires.appendSlice(b.allocator, " libjxl") catch @panic("OOM");
        c.addCSourceFile(.{ .file = b.path("src/image/jxl.c"), .flags = shim_flags });
    } else if (b.lazyDependency("libjxl", .{})) |jxl| {
        if (b.lazyDependency("highway", .{})) |hwy| addJxl(b, c, jxl, hwy);
    }

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
