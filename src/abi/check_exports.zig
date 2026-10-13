//! Build-time check (D2): a shared library exports exactly its schema's
//! functions, each under the version node the version script assigns, and
//! has the expected SONAME. Catches a linker that ignores the version
//! script and runtime symbols (UBSan, compiler-rt) leaking into the ABI.
//! Also checks that its thread-local storage stays small, since every
//! thread of a host process carries it.
//!
//! Usage: siv-abi-check-exports <lib.so> <siv|sivtest> <soname>

const std = @import("std");
const elf = std.elf;
const build_options = @import("build_options");
const schema = @import("schema.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.log.err("usage: {s} <lib.so> <siv|sivtest> <soname>", .{args[0]});
        std.process.exit(2);
    }
    const s = if (std.mem.eql(u8, args[2], "siv")) @import("api.zig").spec else @import("test_api.zig").spec;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .unlimited);
    const lib = try Library.parse(arena, data);

    var failed = false;
    if (!std.mem.eql(u8, lib.soname orelse "", args[3])) {
        std.log.err("{s}: SONAME is {s}, expected {s}", .{ args[1], lib.soname orelse "(none)", args[3] });
        failed = true;
    }
    if (lib.tls > max_tls) {
        std.log.err("{s}: {d} bytes of thread-local storage, more than {d}; every thread of the host process carries it (std_options in src/siv.zig)", .{ args[1], lib.tls, max_tls });
        failed = true;
    }
    var buf: [64]u8 = undefined;
    for (s.functions) |f| {
        const want = schema.versionNode(&buf, s, build_options.version, f);
        const got = lib.exports.get(f.name) orelse {
            std.log.err("{s}: {s} is not exported", .{ args[1], f.name });
            failed = true;
            continue;
        };
        if (!std.mem.eql(u8, got, want)) {
            std.log.err("{s}: {s} has version {s}, expected {s}", .{ args[1], f.name, got, want });
            failed = true;
        }
    }
    var it = lib.exports.iterator();
    while (it.next()) |e| {
        for (s.functions) |f| {
            if (std.mem.eql(u8, f.name, e.key_ptr.*)) break;
        } else {
            std.log.err("{s}: exports {s}@{s}, which is not in {s}", .{ args[1], e.key_ptr.*, e.value_ptr.*, s.source });
            failed = true;
        }
    }
    if (failed) std.process.exit(1);
}

/// Thread-local storage libsiv may have (D2).
const max_tls = 4096;

const Library = struct {
    soname: ?[]const u8,
    /// Size of the thread-local storage segment (PT_TLS), 0 without one.
    tls: u64,
    /// Defined dynamic symbols and their version names ("" if unversioned).
    exports: std.StringArrayHashMapUnmanaged([]const u8),

    fn parse(arena: std.mem.Allocator, data: []const u8) !Library {
        const eh = read(elf.Elf64_Ehdr, data, 0);
        if (!std.mem.eql(u8, eh.e_ident[0..4], elf.MAGIC) or eh.e_ident[elf.EI.CLASS] != elf.ELFCLASS64) return error.NotElf64;
        const shdrs = try arena.alloc(elf.Elf64_Shdr, eh.e_shnum);
        for (shdrs, 0..) |*sh, i| sh.* = read(elf.Elf64_Shdr, data, eh.e_shoff + i * eh.e_shentsize);

        var dynsym: ?elf.Elf64_Shdr = null;
        var versym: ?elf.Elf64_Shdr = null;
        var verdef: ?elf.Elf64_Shdr = null;
        var dynamic: ?elf.Elf64_Shdr = null;
        for (shdrs) |sh| switch (sh.sh_type) {
            elf.SHT_DYNSYM => dynsym = sh,
            elf.SHT_GNU_VERSYM => versym = sh,
            elf.SHT_GNU_VERDEF => verdef = sh,
            elf.SHT_DYNAMIC => dynamic = sh,
            else => {},
        };
        const syms = dynsym orelse return error.NoDynsym;
        const strtab = shdrs[syms.sh_link];
        const str = struct {
            fn at(d: []const u8, tab: elf.Elf64_Shdr, off: usize) []const u8 {
                return std.mem.sliceTo(d[tab.sh_offset + off ..], 0);
            }
        }.at;

        // Version index -> name, from the version definitions.
        var names: std.AutoHashMapUnmanaged(u16, []const u8) = .empty;
        if (verdef) |vd| {
            var off: usize = vd.sh_offset;
            for (0..vd.sh_info) |_| {
                const d = read(elf.Verdef, data, off);
                const aux = read(elf.Verdaux, data, off + d.aux);
                try names.put(arena, @backingInt(d.ndx), str(data, shdrs[vd.sh_link], aux.name));
                if (d.next == 0) break;
                off += d.next;
            }
        }

        var exports: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        const count = syms.sh_size / @sizeOf(elf.Elf64_Sym);
        for (1..count) |i| {
            const sym = read(elf.Elf64_Sym, data, syms.sh_offset + i * @sizeOf(elf.Elf64_Sym));
            if (sym.st_shndx == elf.SHN_UNDEF) continue;
            if (sym.st_bind() == elf.STB_LOCAL) continue;
            const name = str(data, strtab, sym.st_name);
            var version: []const u8 = "";
            if (versym) |vs| {
                const v: elf.Versym = @bitCast(read(u16, data, vs.sh_offset + i * 2));
                version = names.get(v.VERSION) orelse "";
            }
            // The definition symbol of a version node, emitted by some
            // linkers as an absolute symbol named after the node.
            if (sym.st_shndx == elf.SHN_ABS and std.mem.eql(u8, name, version)) continue;
            try exports.put(arena, name, version);
        }

        var soname: ?[]const u8 = null;
        if (dynamic) |dy| {
            const n = dy.sh_size / @sizeOf(elf.Elf64_Dyn);
            for (0..n) |i| {
                const d = read(elf.Elf64_Dyn, data, dy.sh_offset + i * @sizeOf(elf.Elf64_Dyn));
                if (d.d_tag == elf.DT_SONAME) soname = str(data, shdrs[dy.sh_link], d.d_val);
            }
        }
        var tls: u64 = 0;
        for (0..eh.e_phnum) |i| {
            const ph = read(elf.Elf64.Phdr, data, eh.e_phoff + i * eh.e_phentsize);
            if (ph.type == .TLS) tls = ph.memsz;
        }
        return .{ .soname = soname, .exports = exports, .tls = tls };
    }
};

fn read(comptime T: type, data: []const u8, off: usize) T {
    return std.mem.bytesToValue(T, data[off..][0..@sizeOf(T)]);
}
