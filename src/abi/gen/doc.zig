//! Reference documentation generator (Markdown).

const std = @import("std");
const schema = @import("../schema.zig");
const cgen = @import("c.zig");
const Schema = schema.Schema;
const Writer = std.Io.Writer;

pub fn write(arena: std.mem.Allocator, w: *Writer, s: Schema, version: std.SemanticVersion) !void {
    var ubuf: [128]u8 = undefined;
    var pbuf: [128]u8 = undefined;
    const up = try arena.dupe(u8, schema.upper(&ubuf, s.name));

    try w.print(
        \\<!-- Generated from {[source]s} by src/abi/gen.zig. Do not edit. -->
        \\# {[name]s} {[version]f} C API reference
        \\
        \\{[doc]s}
        \\
        \\## Conventions
        \\
        \\- **Handles.** Objects are `uint64_t` handles, never pointers. 0 is the
        \\  null handle. A handle that was destroyed, whose root was destroyed, or
        \\  that names an object of another type is rejected with
        \\  `SIV_ERROR_INVALID_HANDLE`. Root handles (the application) own the
        \\  objects created from them; destroying a root invalidates them all.
        \\- **Results.** A function that can fail returns `siv_result`. Outputs go
        \\  through trailing pointer parameters and are written only on `SIV_OK`; a
        \\  failed call has no effect. Allocation failure is
        \\  `SIV_ERROR_OUT_OF_MEMORY`, never an abort.
        \\- **Descriptors.** Options are passed as a pointer to a descriptor struct
        \\  whose first field, `size`, is `sizeof` the struct; NULL means all
        \\  defaults. Zero means default in every field, so set only what you need:
        \\  `{[up]s}_DESC(type, .field = value)`. Fields are only appended. A
        \\  library older than your headers accepts a larger descriptor if the
        \\  fields it does not know are zero and returns `SIV_ERROR_UNSUPPORTED`
        \\  otherwise; a newer library treats the fields your headers lack as zero.
        \\  Fields named `reserved*` must be zero, `SIV_ERROR_UNSUPPORTED`
        \\  otherwise, until a version gives them a meaning. Unknown values of
        \\  closed enums and unknown flag bits are `SIV_ERROR_UNSUPPORTED` too;
        \\  open enums (marked so) pass every value.
        \\- **Strings** are a `const char *` and a `size_t` length; embedded NUL is
        \\  allowed and no terminator is read. NULL with length 0 is the empty
        \\  string. siv copies what it keeps. Strings siv returns with static
        \\  lifetime are NUL-terminated.
        \\- **Arrays** are a const pointer and a `size_t` count (`<name>_count`);
        \\  NULL with count 0 is empty. siv copies what it keeps. Functions that
        \\  fill caller memory take a `char *` and its capacity (`<name>_cap`),
        \\  write at most that many bytes, and report the full length.
        \\- **Callbacks** take `void *user_data` as their first parameter, passed
        \\  back unchanged from where the callback was registered. A
        \\  destroy-notify registered with a callback runs exactly once, when
        \\  siv no longer needs `user_data`.
        \\- **Allocation.** Each root may supply `siv_allocator` hooks, used for
        \\  every allocation made on its behalf.
        \\- **Threads.** Call a function only from the thread that created the
        \\  root, unless it is marked *Any thread*. Callbacks run on that thread at
        \\  safe points of its loop, unless marked *Runs on a worker thread* or
        \\  *Runs on the compositor thread*. The JSON description gives the same as
        \\  each function's and callback's `thread`.
        \\- **Versions.** The SONAME is `lib{[name]s}.so.<major>`. Every symbol is
        \\  versioned; before 1.0 each minor release has its own version node, so a
        \\  program linked against 0.1 fails to load against 0.2 instead of
        \\  misbehaving. From 1.0 nothing is removed within a major version;
        \\  deprecated functions (marked so, with their replacement) keep working
        \\  until the next one.
        \\
        \\## Types
        \\
    , .{ .source = s.source, .name = s.name, .version = version, .doc = s.doc, .up = up });

    for (s.decls) |d| {
        try w.print("\n### `{s}`\n\n{s} *Since {d}.{d}.*\n\n```c\n", .{ d.name(), d.doc(), d.since().major, d.since().minor });
        switch (d) {
            .handle => |h| try w.print("typedef uint64_t {s};\n```\n", .{h.name}),
            .@"enum" => |e| {
                const prefix = schema.enumValuePrefix(&pbuf, e);
                try w.print("typedef enum {s} {{ ... }} {s};\n```\n\n", .{ e.name, e.name });
                try w.writeAll(if (e.open) "An open enum: values other than those named are valid.\n\n" else "A closed enum: functions reject values other than those named (`SIV_ERROR_UNSUPPORTED`).\n\n");
                try w.writeAll("| Value | | |\n| --- | --- | --- |\n");
                for (e.values) |v| try w.print("| `{s}{s}` | {d} | {s} |\n", .{ prefix, schema.upper(&ubuf, v.name), v.value, v.doc });
            },
            .flags => |f| {
                const prefix = schema.flagsValuePrefix(&pbuf, f);
                try w.print("typedef uint32_t {s};\n```\n\n| Flag | Bit | |\n| --- | --- | --- |\n", .{f.name});
                for (f.bits) |b| try w.print("| `{s}{s}` | {d} | {s} |\n", .{ prefix, schema.upper(&ubuf, b.name), b.bit, b.doc });
            },
            .@"struct" => |st| {
                try w.print("typedef struct {s} {{\n", .{st.name});
                if (st.kind == .descriptor) try w.writeAll("    size_t size;\n");
                for (st.fields) |f| for (try cgen.decls(arena, f.type, f.name)) |cd| try w.print("    {f};\n", .{cd});
                try w.print("}} {s};\n```\n\n| Field | |\n| --- | --- |\n", .{st.name});
                if (st.kind == .descriptor) try w.print("| `size` | `sizeof({s})`. |\n", .{st.name});
                for (st.fields) |f| {
                    try w.print("| `{s}` | {s}", .{ f.name, f.doc });
                    if (f.since) |v| if (v.order(st.since) != .eq) try w.print(" *Since {d}.{d}.*", .{ v.major, v.minor });
                    try w.writeAll(" |\n");
                }
            },
            .callback => |cb| {
                try w.print("typedef {s} (*{s})(", .{ try cgen.typeName(arena, cb.ret), cb.name });
                try cgen.paramList(arena, w, true, cb.params);
                try w.writeAll(");\n```\n");
                if (cgen.threadNote(cb.thread)) |note| try w.print("\n*{s}*\n", .{note[0 .. note.len - 1]});
                if (cb.params.len > 0) {
                    try w.writeAll("\n| Parameter | |\n| --- | --- |\n");
                    for (cb.params) |p| try w.print("| `{s}` | {s} |\n", .{ p.name, p.doc });
                }
            },
        }
    }

    try w.writeAll("\n## Functions\n");
    for (s.functions) |f| {
        try w.print("\n### `{s}`\n\n{s} *Since {d}.{d}.*", .{ f.name, f.doc, f.since.major, f.since.minor });
        if (cgen.threadNote(f.thread)) |note| try w.print(" *{s}*", .{note[0 .. note.len - 1]});
        if (f.deprecated) |d| try w.print(" **Deprecated since {d}.{d}:** use `{s}`.", .{ d.since.major, d.since.minor, d.replacement });
        try w.writeAll("\n\n```c\n");
        try cgen.prototype(arena, w, f);
        try w.writeAll(";\n```\n");
        if (f.params.len > 0) {
            try w.writeAll("\n| Parameter | |\n| --- | --- |\n");
            for (f.params) |p| try w.print("| `{s}` | {s} |\n", .{ p.name, p.doc });
        }
    }
}
