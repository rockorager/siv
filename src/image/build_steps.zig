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

/// dav1d with its assembly on x86-64 (NASM syntax, assembled by `nasm`
/// built from source, see `addNasm`) and aarch64 (GNU syntax, assembled
/// by clang); other targets use its C paths. The `_tmpl` files build once
/// per bit depth, and meson's generated headers are written here.
fn addDav1d(b: *std.Build, m: *std.Build.Module, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget) void {
    const arch = target.result.cpu.arch;
    const x86 = arch == .x86_64 or arch == .x86;
    const nasm: ?*std.Build.Step.Compile = if (arch == .x86_64)
        if (b.lazyDependency("nasm", .{})) |n| addNasm(b, n) else return
    else
        null;
    const asm_on = nasm != null or arch == .aarch64;
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
        \\#define HAVE_ASM {d}
        \\#define PIC 3
        \\#define HAVE_AS_FUNC 0
        \\#define HAVE_AS_ARCH_DIRECTIVE 1
        \\#define AS_ARCH_LEVEL armv8.6-a+crc
        \\#define HAVE_AS_ARCHEXT_DOTPROD_DIRECTIVE 1
        \\#define HAVE_AS_ARCHEXT_I8MM_DIRECTIVE 1
        \\#define HAVE_AS_ARCHEXT_SVE_DIRECTIVE 1
        \\#define HAVE_AS_ARCHEXT_SVE2_DIRECTIVE 1
        \\#define HAVE_DOTPROD 1
        \\#define HAVE_I8MM 1
        \\#define HAVE_SVE 1
        \\#define HAVE_SVE2 1
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
        @intFromBool(asm_on),
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

    if (nasm) |exe| {
        m.addCSourceFile(.{ .file = dep.path("src/x86/cpu.c"), .flags = flags });
        const config_asm = gen.add("config.asm",
            \\%define ARCH_X86_32 0
            \\%define ARCH_X86_64 1
            \\%define PIC 1
            \\%define STACK_ALIGNMENT 16
            \\%define private_prefix dav1d
            \\%define FORCE_VEX_ENCODING 0
            \\
        );
        for (dav1d_x86_asm) |file| {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{ "-f", "elf64" });
            run.addPrefixedDirectoryArg("-I", dep.path("src/"));
            run.addPrefixedDirectoryArg("-I", gen.getDirectory());
            run.addFileInput(config_asm);
            run.addFileArg(dep.path(b.fmt("src/x86/{s}.asm", .{file})));
            run.addArg("-o");
            m.addObjectFile(run.addOutputFileArg(b.fmt("{s}.o", .{file})));
        }
    } else if (arch == .aarch64) {
        m.addCSourceFile(.{ .file = dep.path("src/arm/cpu.c"), .flags = flags });
        m.addCSourceFiles(.{ .root = dep.path("src/arm/64"), .files = &dav1d_arm64_asm, .flags = &.{"-D_GNU_SOURCE"} });
    }
}

/// dav1d's x86 assembly for 8 and 16 bits per component (src/meson.build).
const dav1d_x86_asm = [_][]const u8{
    "cpuid",                "msac",                    "pal",                   "refmvs",                   "itx_avx512",
    "cdef_avx2",            "itx_avx2",                "cdef_sse",              "itx_sse",                  "cdef_avx512",
    "filmgrain_avx512",     "ipred_avx512",            "loopfilter_avx512",     "looprestoration_avx512",   "mc_avx512",
    "filmgrain_avx2",       "ipred_avx2",              "loopfilter_avx2",       "looprestoration_avx2",     "mc_avx2",
    "filmgrain_sse",        "ipred_sse",               "loopfilter_sse",        "looprestoration_sse",      "mc_sse",
    "cdef16_avx512",        "filmgrain16_avx512",      "ipred16_avx512",        "itx16_avx512",             "loopfilter16_avx512",
    "looprestoration16_avx512", "mc16_avx512",         "cdef16_avx2",           "filmgrain16_avx2",         "ipred16_avx2",
    "itx16_avx2",           "loopfilter16_avx2",       "looprestoration16_avx2", "mc16_avx2",               "cdef16_sse",
    "filmgrain16_sse",      "ipred16_sse",             "itx16_sse",             "loopfilter16_sse",         "looprestoration16_sse",
    "mc16_sse",
};

/// dav1d's aarch64 assembly for 8 and 16 bits per component.
const dav1d_arm64_asm = [_][]const u8{
    "itx.S",       "looprestoration_common.S", "msac.S",          "refmvs.S",   "cdef.S",
    "filmgrain.S", "ipred.S",                  "loopfilter.S",    "looprestoration.S", "mc.S",
    "mc_dotprod.S", "cdef16.S",                "filmgrain16.S",   "ipred16.S",  "itx16.S",
    "loopfilter16.S", "looprestoration16.S",   "mc16.S",          "mc16_sve.S",
};

/// NASM, for dav1d's x86 assembly, built from its release tarball (which
/// carries the files its perl scripts generate) for the build machine, a
/// pinned build tool like the shader compiler. The configuration is what
/// its configure script finds on Linux with glibc or musl, without the
/// glibc-only functions it has fallbacks for.
fn addNasm(b: *std.Build, dep: *std.Build.Dependency) *std.Build.Step.Compile {
    const gen = b.addWriteFiles();
    _ = gen.add("config/config.h",
        \\#define HAVE_ACCESS 1
        \\#define HAVE_DECL_STRCASECMP 1
        \\#define HAVE_DECL_STRICMP 0
        \\#define HAVE_DECL_STRLCPY 0
        \\#define HAVE_DECL_STRNCASECMP 1
        \\#define HAVE_DECL_STRNICMP 0
        \\#define HAVE_DECL_STRNLEN 1
        \\#define HAVE_DECL_STRRCHRNUL 0
        \\#define HAVE_DECL_STRSEP 1
        \\#define HAVE_ENDIAN_H 1
        \\#define HAVE_FACCESSAT 1
        \\#define HAVE_FCNTL_H 1
        \\#define HAVE_FILENO 1
        \\#define HAVE_FSEEKO 1
        \\#define HAVE_FSTAT 1
        \\#define HAVE_FTRUNCATE 1
        \\#define HAVE_FUNC_ATTRIBUTE1_ALLOC_SIZE 1
        \\#define HAVE_FUNC_ATTRIBUTE2_ALLOC_SIZE 1
        \\#define HAVE_FUNC_ATTRIBUTE3_FORMAT 1
        \\#define HAVE_FUNC_ATTRIBUTE_COLD 1
        \\#define HAVE_FUNC_ATTRIBUTE_CONST 1
        \\#define HAVE_FUNC_ATTRIBUTE_ERROR 1
        \\#define HAVE_FUNC_ATTRIBUTE_MALLOC 1
        \\#define HAVE_FUNC_ATTRIBUTE_NORETURN 1
        \\#define HAVE_FUNC_ATTRIBUTE_PURE 1
        \\#define HAVE_FUNC_ATTRIBUTE_RETURNS_NONNULL 1
        \\#define HAVE_FUNC_ATTRIBUTE_SENTINEL 1
        \\#define HAVE_FUNC_ATTRIBUTE_UNUSED 1
        \\#define HAVE_FUNC_PTR_ATTRIBUTE1_ALLOC_SIZE 1
        \\#define HAVE_FUNC_PTR_ATTRIBUTE2_ALLOC_SIZE 1
        \\#define HAVE_FUNC_PTR_ATTRIBUTE3_FORMAT 1
        \\#define HAVE_FUNC_PTR_ATTRIBUTE_CONST 1
        \\#define HAVE_FUNC_PTR_ATTRIBUTE_NORETURN 1
        \\#define HAVE_FUNC_PTR_ATTRIBUTE_PURE 1
        \\#define HAVE_FUNC_PTR_ATTRIBUTE_UNUSED 1
        \\#define HAVE_GETGID 1
        \\#define HAVE_GETPAGESIZE 1
        \\#define HAVE_GETRLIMIT 1
        \\#define HAVE_GETUID 1
        \\#define HAVE_HTOLE16 1
        \\#define HAVE_HTOLE32 1
        \\#define HAVE_HTOLE64 1
        \\#define HAVE_INTTYPES_H 1
        \\#define HAVE_ISASCII 1
        \\#define HAVE_ISCNTRL 1
        \\#define HAVE_MMAP 1
        \\#define HAVE_PATHCONF 1
        \\#define HAVE_REALPATH 1
        \\#define HAVE_SNPRINTF 1
        \\#define HAVE_STAT 1
        \\#define HAVE_STDARG_H 1
        \\#define HAVE_STDBOOL_H 1
        \\#define HAVE_STDC_INLINE 1
        \\#define HAVE_STDINT_H 1
        \\#define HAVE_STDIO_H 1
        \\#define HAVE_STDLIB_H 1
        \\#define HAVE_STDNORETURN_H 1
        \\#define HAVE_STRCASECMP 1
        \\#define HAVE_STRINGS_H 1
        \\#define HAVE_STRING_H 1
        \\#define HAVE_STRNCASECMP 1
        \\#define HAVE_STRNLEN 1
        \\#define HAVE_STRSEP 1
        \\#define HAVE_STRUCT_STAT 1
        \\#define HAVE_SYSCONF 1
        \\#define HAVE_SYS_MMAN_H 1
        \\#define HAVE_SYS_PARAM_H 1
        \\#define HAVE_SYS_RESOURCE_H 1
        \\#define HAVE_SYS_STAT_H 1
        \\#define HAVE_SYS_TYPES_H 1
        \\#define HAVE_TYPEOF 1
        \\#define HAVE_UINTPTR_T 1
        \\#define HAVE_UNISTD_H 1
        \\#define HAVE_VARIADIC_MACROS 1
        \\#define HAVE_VSNPRINTF 1
        \\#define HAVE_WCHAR_H 1
        \\#define HAVE__BOOL 1
        \\#define HAVE___BSWAP_16 1
        \\#define HAVE___BSWAP_32 1
        \\#define HAVE___BSWAP_64 1
        \\#define HAVE___BUILTIN_BSWAP16 1
        \\#define HAVE___BUILTIN_BSWAP32 1
        \\#define HAVE___BUILTIN_BSWAP64 1
        \\#define HAVE___BUILTIN_CHOOSE_EXPR 1
        \\#define HAVE___BUILTIN_CLZ 1
        \\#define HAVE___BUILTIN_CLZL 1
        \\#define HAVE___BUILTIN_CLZLL 1
        \\#define HAVE___BUILTIN_CONSTANT_P 1
        \\#define HAVE___BUILTIN_EXPECT 1
        \\#define STDC_HEADERS 1
        \\#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
        \\#define WORDS_BIGENDIAN 1
        \\#else
        \\#define WORDS_LITTLEENDIAN 1
        \\#endif
        \\#define typeof __typeof
        \\#include "config/unconfig.h"
        \\
    );
    const mod = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true });
    mod.addIncludePath(gen.getDirectory());
    for ([_][]const u8{ "", "include", "x86", "asm", "output", "disasm", "nasmlib" }) |dir| mod.addIncludePath(dep.path(dir));
    const flags: []const []const u8 = &.{ "-DHAVE_CONFIG_H", "-std=c17", "-w" };
    mod.addCSourceFiles(.{ .root = dep.path(""), .files = &nasm_sources, .flags = flags });
    // `nasm -v` prints a build date; the release's keeps builds reproducible.
    mod.addCSourceFile(.{ .file = dep.path("nasmlib/ver.c"), .flags = flags ++ &[_][]const u8{ "-Wno-builtin-macro-redefined", "-D__DATE__=\"Apr 17 2024\"" } });
    return b.addExecutable(.{ .name = "nasm", .root_module = mod });
}

/// NASM's program and library objects (Makefile.in), without ver.c (above)
/// and errfile.c, which only ndisasm links.
const nasm_sources = [_][]const u8{
    "asm/nasm.c",           "asm/warnings.c",       "stdlib/snprintf.c",    "stdlib/vsnprintf.c",   "stdlib/strlcpy.c",
    "stdlib/strnlen.c",     "stdlib/strrchrnul.c",  "nasmlib/alloc.c",      "nasmlib/asprintf.c",   "nasmlib/crc32.c",
    "nasmlib/crc64.c",      "nasmlib/md5c.c",       "nasmlib/string.c",     "nasmlib/nctype.c",     "nasmlib/file.c",
    "nasmlib/mmap.c",       "nasmlib/ilog2.c",      "nasmlib/realpath.c",   "nasmlib/path.c",       "nasmlib/filename.c",
    "nasmlib/rlimit.c",     "nasmlib/readnum.c",    "nasmlib/numstr.c",     "nasmlib/zerobuf.c",    "nasmlib/bsi.c",
    "nasmlib/rbtree.c",     "nasmlib/hashtbl.c",    "nasmlib/raa.c",        "nasmlib/saa.c",        "nasmlib/strlist.c",
    "nasmlib/perfhash.c",   "nasmlib/badenum.c",    "common/common.c",      "x86/insnsa.c",         "x86/insnsb.c",
    "x86/insnsd.c",         "x86/insnsn.c",         "x86/regs.c",           "x86/regvals.c",        "x86/regflags.c",
    "x86/regdis.c",         "x86/disp8.c",          "x86/iflag.c",          "asm/error.c",          "asm/floats.c",
    "asm/directiv.c",       "asm/directbl.c",       "asm/pragma.c",         "asm/assemble.c",       "asm/labels.c",
    "asm/parser.c",         "asm/preproc.c",        "asm/quote.c",          "asm/pptok.c",          "asm/listing.c",
    "asm/eval.c",           "asm/exprlib.c",        "asm/exprdump.c",       "asm/stdscan.c",        "asm/strfunc.c",
    "asm/tokhash.c",        "asm/segalloc.c",       "asm/rdstrnum.c",       "asm/srcfile.c",        "macros/macros.c",
    "output/outform.c",     "output/outlib.c",      "output/legacy.c",      "output/nulldbg.c",     "output/nullout.c",
    "output/outbin.c",      "output/outaout.c",     "output/outcoff.c",     "output/outelf.c",      "output/outobj.c",
    "output/outas86.c",     "output/outdbg.c",      "output/outieee.c",     "output/outmacho.c",    "output/codeview.c",
    "disasm/disasm.c",      "disasm/sync.c",
};

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
