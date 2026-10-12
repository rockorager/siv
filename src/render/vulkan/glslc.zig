//! siv-glslc: compiles GLSL to SPIR-V for Vulkan 1.3 with glslang, at build
//! time (see build_steps.zig).
//!
//!     siv-glslc <vert|frag|comp> <source>... <output.spv>
//!
//! The sources are concatenated in order (shared declarations first), so
//! shaders need no include mechanism.

const std = @import("std");
const c = @import("glslang");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.log.err("usage: {s} <vert|frag|comp> <source>... <output.spv>", .{args[0]});
        std.process.exit(2);
    }
    const stage: c.glslang_stage_t = if (std.mem.eql(u8, args[1], "vert"))
        c.GLSLANG_STAGE_VERTEX
    else if (std.mem.eql(u8, args[1], "frag"))
        c.GLSLANG_STAGE_FRAGMENT
    else if (std.mem.eql(u8, args[1], "comp"))
        c.GLSLANG_STAGE_COMPUTE
    else {
        std.log.err("unknown stage {s}", .{args[1]});
        std.process.exit(2);
    };

    var source: std.ArrayList(u8) = .empty;
    for (args[2 .. args.len - 1]) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        try source.appendSlice(arena, bytes);
        try source.append(arena, '\n');
    }
    try source.append(arena, 0);
    const name = args[args.len - 2];

    _ = c.glslang_initialize_process();
    defer c.glslang_finalize_process();
    const messages = c.GLSLANG_MSG_SPV_RULES_BIT | c.GLSLANG_MSG_VULKAN_RULES_BIT;
    const input: c.glslang_input_t = .{
        .language = c.GLSLANG_SOURCE_GLSL,
        .stage = stage,
        .client = c.GLSLANG_CLIENT_VULKAN,
        .client_version = c.GLSLANG_TARGET_VULKAN_1_3,
        .target_language = c.GLSLANG_TARGET_SPV,
        .target_language_version = c.GLSLANG_TARGET_SPV_1_6,
        .code = @ptrCast(source.items.ptr),
        .default_version = 460,
        .default_profile = c.GLSLANG_NO_PROFILE,
        .force_default_version_and_profile = 0,
        .forward_compatible = 0,
        .messages = messages,
        .resource = c.glslang_default_resource(),
    };
    const shader = c.glslang_shader_create(&input) orelse return error.OutOfMemory;
    defer c.glslang_shader_delete(shader);
    if (c.glslang_shader_preprocess(shader, &input) == 0) fail(name, "preprocessing", c.glslang_shader_get_info_log(shader));
    if (c.glslang_shader_parse(shader, &input) == 0) fail(name, "compilation", c.glslang_shader_get_info_log(shader));
    const program = c.glslang_program_create() orelse return error.OutOfMemory;
    defer c.glslang_program_delete(program);
    c.glslang_program_add_shader(program, shader);
    if (c.glslang_program_link(program, messages) == 0) fail(name, "linking", c.glslang_program_get_info_log(program));
    c.glslang_program_SPIRV_generate(program, stage);
    if (c.glslang_program_SPIRV_get_messages(program)) |m| if (m[0] != 0) std.log.warn("{s}: {s}", .{ name, m });

    const words = try arena.alloc(u32, c.glslang_program_SPIRV_get_size(program));
    c.glslang_program_SPIRV_get(program, words.ptr);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[args.len - 1], .data = std.mem.sliceAsBytes(words) });
}

fn fail(name: []const u8, what: []const u8, log: [*c]const u8) noreturn {
    std.log.err("{s}: {s} failed:\n{s}", .{ name, what, if (log) |l| std.mem.span(l) else "" });
    std.process.exit(1);
}
