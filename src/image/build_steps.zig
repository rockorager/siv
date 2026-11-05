//! Image decoding part of the build graph, called from build.zig: the
//! `image` module, baskingspot's image package (PNG, APNG, JPEG, GIF,
//! WebP, and JPEG XL in Zig), and the C libraries behind the rest (D19).
//! Owned by the image decoding workstream.
//!
//! Every C library is vendored from build.zig.zon and fetched lazily, or
//! linked from the system with `-fsys=<name>`: lcms2, dav1d, libavif. siv
//! reaches them only through its own small C interfaces in
//! src/image/*.h, compiled into the `image_c` module, so `-fsys` builds and
//! vendored builds share every line of siv's code.

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

/// dav1d with its assembly on x86-64 (NASM syntax, assembled by `nasm`
/// built from source, see `addNasm`) and aarch64 (GNU syntax, assembled
/// by clang); other targets use its C paths. Debug builds use the C paths
/// too: the assembly only makes decoding faster, and building NASM and
/// assembling dav1d's x86-64 files cost more than the rest of dav1d (D25).
/// The `_tmpl` files build once per bit depth, and meson's generated
/// headers are written here.
fn addDav1d(b: *std.Build, m: *std.Build.Module, dep: *std.Build.Dependency, o: Options) void {
    const target = o.target;
    const arch = target.result.cpu.arch;
    const x86 = arch == .x86_64 or arch == .x86;
    const want_asm = o.optimize != .debug;
    const nasm: ?*std.Build.Step.Compile = if (want_asm and arch == .x86_64)
        if (b.lazyDependency("nasm", .{})) |n| addNasm(b, n) else return
    else
        null;
    const asm_on = nasm != null or (want_asm and arch == .aarch64);
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
    } else if (asm_on and arch == .aarch64) {
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
        \\#define HAVE_MEMPCPY 1
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
        \\#define _GNU_SOURCE 1
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
        .root_source_file = b.addWriteFiles().add("image_c.h",
            \\#include "color.h"
            \\#include "avif.h"
            \\
        ),
        .target = o.target,
        .optimize = o.optimize,
    });
    tc.addIncludePath(b.path("src/image"));
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

    // libavif with dav1d: still and animated AVIF.
    if (b.systemIntegrationOption("libavif", .{})) {
        c.linkSystemLibrary("libavif", .{});
        requires.appendSlice(b.allocator, " libavif") catch @panic("OOM");
        const m = object(b, o, "avif", false);
        m.linkSystemLibrary("libavif", .{});
        m.addCSourceFile(.{ .file = b.path("src/image/avif.c"), .flags = shim_flags });
    } else if (b.lazyDependency("libavif", .{})) |avif| {
        const m = object(b, o, "libavif", false);
        m.addIncludePath(avif.path("include"));
        m.addIncludePath(avif.path("third_party/libyuv/include"));
        m.addCSourceFile(.{ .file = b.path("src/image/avif.c"), .flags = shim_flags });
        // The part of libyuv (BSD-3-Clause) libavif bundles for scaling.
        m.addCSourceFiles(.{
            .root = avif.path("third_party/libyuv/source"),
            .files = &.{ "scale.c", "scale_common.c", "scale_any.c", "row_common.c", "planar_functions.c" },
            .flags = shim_flags,
        });
        m.addCSourceFiles(.{
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
            m.linkSystemLibrary("dav1d", .{});
            requires.appendSlice(b.allocator, " dav1d") catch @panic("OOM");
        } else if (b.lazyDependency("dav1d", .{})) |dav1d| {
            m.addIncludePath(dav1d.path("include"));
            addDav1d(b, object(b, o, "dav1d", false), dav1d, o);
        }
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
