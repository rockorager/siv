//! siv_job_start for Lua (D23): CPU-bound or blocking work on siv's worker
//! pool, though a Lua state runs on the application's thread only. The
//! work is a Lua function that runs in a fresh Lua state of its own on the
//! worker: its bytecode, without upvalues, and copies of its arguments go
//! there, copies of its results come back, and the callback runs with them
//! at a safe point on the application's thread (D5).
//!
//! internal.job_start(app, compute, work, args, callback): the prelude's
//! app:job_start wraps it, waiting in a coroutine when given no callback.
//! callback(true, results...) or callback(false, message).

const std = @import("std");
const lua = @import("c.zig");
const c = lua.c;
const bind = @import("bind.zig");
const siv = @import("siv");

const State = bind.State;
const gpa = std.heap.c_allocator;

const Job = struct {
    st: *State,
    /// The callback in the registry of the application's Lua state.
    callback: c_int,
    code: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,
    /// The index of the function's _ENV upvalue, 0 for none.
    env_upvalue: c_int = 0,
    /// Filled on the worker: the results, or the error message.
    results: std.ArrayList(u8) = .empty,
    ok: bool = false,
};

/// Values that cross between Lua states.
const Tag = enum(u8) { nil, false, true, int, float, string, table, end };

/// The deepest nesting of tables copied; deeper is taken for a cycle.
const max_depth = 64;

pub fn start(Lq: ?*lua.State) callconv(.c) c_int {
    const L = Lq.?;
    const st = State.get(L);
    const app = bind.toHandleUd(L, 1) orelse lua.argError(L, 1, "siv.app expected", .{});
    const compute = c.lua_toboolean(L, 2) != 0;
    c.luaL_checktype(L, 3, lua.tfunction);
    c.luaL_checktype(L, 5, lua.tfunction);
    const job = gpa.create(Job) catch lua.raise(L, "out of memory", .{});
    job.* = .{ .st = st, .callback = lua.noref };
    // Upvalues are values of this state: the work sees its arguments and
    // the standard libraries only.
    var i: c_int = 1;
    while (c.lua_getupvalue(L, 3, i)) |name| : (i += 1) {
        lua.pop(L, 1);
        const n = std.mem.span(name);
        if (std.mem.eql(u8, n, "_ENV")) {
            job.env_upvalue = i;
            continue;
        }
        free(job);
        lua.argError(L, 3, "a job's function runs in a Lua state of its own and cannot use the local '{s}' from outside it: pass it in args", .{n});
    }
    c.lua_pushvalue(L, 3);
    if (c.lua_dump(L, writer, job, 0) != 0) {
        free(job);
        lua.raise(L, "out of memory", .{});
    }
    lua.pop(L, 1);
    if (!lua.isnoneornil(L, 4)) {
        c.luaL_checktype(L, 4, lua.ttable);
        encodeArgs(L, 4, &job.args) catch |e| {
            free(job);
            raiseCopy(L, e);
        };
    } else {
        job.args.append(gpa, @intFromEnum(Tag.end)) catch {
            free(job);
            lua.raise(L, "out of memory", .{});
        };
    }
    c.lua_pushvalue(L, 5);
    job.callback = c.luaL_ref(L, lua.registry);
    const flags: siv.JobFlags = .{ .compute = compute };
    const r = siv.c.siv_job_start(@enumFromInt(app.value), flags, work, done, destroy, job);
    // A failed start ran destroy, which freed the job.
    if (r != .ok) lua.raise(L, "siv_job_start: {s}", .{std.mem.span(siv.c.siv_result_name(r))});
    return 0;
}

fn writer(_: ?*lua.State, p: ?*const anyopaque, sz: usize, ud: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(ud.?));
    const bytes: [*]const u8 = @ptrCast(p orelse return 0);
    job.code.appendSlice(gpa, bytes[0..sz]) catch return 1;
    return 0;
}

fn free(job: *Job) void {
    job.code.deinit(gpa);
    job.args.deinit(gpa);
    job.results.deinit(gpa);
    gpa.destroy(job);
}

const CopyError = error{ OutOfMemory, Unsupported, TooDeep };

fn raiseCopy(L: *lua.State, e: CopyError) noreturn {
    switch (e) {
        error.OutOfMemory => lua.raise(L, "out of memory", .{}),
        error.Unsupported => lua.raise(L, "a job takes and returns nil, booleans, numbers, strings, and tables of them", .{}),
        error.TooDeep => lua.raise(L, "a job's tables nest more than {d} deep (or hold a cycle)", .{max_depth}),
    }
}

/// The array part of the table at `idx`, 1 to its length, as values.
fn encodeArgs(L: *lua.State, idx: c_int, out: *std.ArrayList(u8)) CopyError!void {
    const n = c.luaL_len(L, idx);
    var k: c.lua_Integer = 1;
    while (k <= n) : (k += 1) {
        _ = c.lua_geti(L, idx, k);
        defer lua.pop(L, 1);
        try encode(L, c.lua_gettop(L), out, 0);
    }
    try out.append(gpa, @intFromEnum(Tag.end));
}

fn encode(L: *lua.State, idx: c_int, out: *std.ArrayList(u8), depth: u32) CopyError!void {
    switch (c.lua_type(L, idx)) {
        lua.tnil => try out.append(gpa, @intFromEnum(Tag.nil)),
        lua.tboolean => try out.append(gpa, @intFromEnum(if (c.lua_toboolean(L, idx) != 0) Tag.true else Tag.false)),
        lua.tnumber => if (c.lua_isinteger(L, idx) != 0) {
            try out.append(gpa, @intFromEnum(Tag.int));
            try out.appendSlice(gpa, std.mem.asBytes(&c.lua_tointegerx(L, idx, null)));
        } else {
            try out.append(gpa, @intFromEnum(Tag.float));
            try out.appendSlice(gpa, std.mem.asBytes(&c.lua_tonumberx(L, idx, null)));
        },
        lua.tstring => {
            const s = lua.toString(L, idx).?;
            try out.append(gpa, @intFromEnum(Tag.string));
            try out.appendSlice(gpa, std.mem.asBytes(&s.len));
            try out.appendSlice(gpa, s);
        },
        lua.ttable => {
            if (depth >= max_depth) return error.TooDeep;
            if (c.lua_checkstack(L, 4) == 0) return error.OutOfMemory;
            try out.append(gpa, @intFromEnum(Tag.table));
            c.lua_pushnil(L);
            while (c.lua_next(L, idx) != 0) {
                const top = c.lua_gettop(L);
                try encode(L, top - 1, out, depth + 1);
                try encode(L, top, out, depth + 1);
                lua.pop(L, 1);
            }
            try out.append(gpa, @intFromEnum(Tag.end));
        },
        else => return error.Unsupported,
    }
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn tag(r: *Reader) Tag {
        defer r.pos += 1;
        return @enumFromInt(r.bytes[r.pos]);
    }

    fn take(r: *Reader, comptime T: type) T {
        defer r.pos += @sizeOf(T);
        return std.mem.bytesToValue(T, r.bytes[r.pos..][0..@sizeOf(T)]);
    }
};

/// Pushes values until the end tag; returns how many.
fn decodeAll(L: *lua.State, r: *Reader) c_int {
    var n: c_int = 0;
    while (r.bytes[r.pos] != @intFromEnum(Tag.end)) : (n += 1) {
        c.luaL_checkstack(L, 2, "siv job results");
        decode(L, r, r.tag());
    }
    r.pos += 1;
    return n;
}

fn decode(L: *lua.State, r: *Reader, t: Tag) void {
    switch (t) {
        .nil => c.lua_pushnil(L),
        .false => c.lua_pushboolean(L, 0),
        .true => c.lua_pushboolean(L, 1),
        .int => c.lua_pushinteger(L, r.take(c.lua_Integer)),
        .float => c.lua_pushnumber(L, r.take(c.lua_Number)),
        .string => {
            const len = r.take(usize);
            _ = c.lua_pushlstring(L, r.bytes[r.pos..].ptr, len);
            r.pos += len;
        },
        .table => {
            c.luaL_checkstack(L, 3, "siv job results");
            lua.newtable(L);
            while (true) {
                const kt = r.tag();
                if (kt == .end) break;
                decode(L, r, kt);
                decode(L, r, r.tag());
                c.lua_settable(L, -3);
            }
        },
        .end => unreachable,
    }
}

// On the worker ----------------------------------------------------------------

fn work(ud: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(ud.?));
    const L = c.luaL_newstate() orelse return fail(job, "out of memory");
    defer c.lua_close(L);
    // The standard libraries a computation needs; nothing of siv's, the
    // file system's, or the process's.
    const libs = [_]struct { [*:0]const u8, lua.CFunction }{
        .{ "_G", c.luaopen_base },
        .{ "string", c.luaopen_string },
        .{ "table", c.luaopen_table },
        .{ "math", c.luaopen_math },
        .{ "utf8", c.luaopen_utf8 },
    };
    lua.pushcfunction(L, struct {
        fn run(Lq: ?*lua.State) callconv(.c) c_int {
            const Ls = Lq.?;
            const j: *Job = @ptrCast(@alignCast(c.lua_touserdata(Ls, 1)));
            for (libs) |lib| {
                c.luaL_requiref(Ls, lib[0], lib[1], 1);
                lua.pop(Ls, 1);
            }
            if (c.luaL_loadbufferx(Ls, j.code.items.ptr, j.code.items.len, "=job", "b") != lua.ok) _ = c.lua_error(Ls);
            if (j.env_upvalue != 0) {
                _ = c.lua_rawgeti(Ls, lua.registry, c.LUA_RIDX_GLOBALS);
                _ = c.lua_setupvalue(Ls, -2, j.env_upvalue);
            }
            const base = c.lua_gettop(Ls);
            var r: Reader = .{ .bytes = j.args.items };
            const nargs = decodeAll(Ls, &r);
            lua.call(Ls, nargs, lua.multret);
            const top = c.lua_gettop(Ls);
            var i = base;
            while (i <= top) : (i += 1) encode(Ls, i, &j.results, 0) catch |e| raiseCopy(Ls, e);
            j.results.append(gpa, @intFromEnum(Tag.end)) catch raiseCopy(Ls, error.OutOfMemory);
            return 0;
        }
    }.run);
    c.lua_pushlightuserdata(L, job);
    if (lua.pcall(L, 1, 0, 0) != lua.ok) {
        job.results.clearRetainingCapacity();
        return fail(job, lua.toString(L, -1) orelse "(error object is not a string)");
    }
    job.ok = true;
}

fn fail(job: *Job, msg: []const u8) void {
    job.ok = false;
    job.results.clearRetainingCapacity();
    job.results.append(gpa, @intFromEnum(Tag.string)) catch return;
    job.results.appendSlice(gpa, std.mem.asBytes(&msg.len)) catch return;
    job.results.appendSlice(gpa, msg) catch return;
    job.results.append(gpa, @intFromEnum(Tag.end)) catch return;
}

// Back on the application's thread ----------------------------------------------

fn done(ud: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(ud.?));
    const st = job.st;
    const L = st.L;
    if (c.lua_checkstack(L, 8) == 0) return;
    const top = c.lua_gettop(L);
    st.pushTraceback(L);
    lua.pushcfunction(L, struct {
        fn run(Lq: ?*lua.State) callconv(.c) c_int {
            const Ls = Lq.?;
            const j: *Job = @ptrCast(@alignCast(c.lua_touserdata(Ls, 1)));
            _ = c.lua_rawgeti(Ls, lua.registry, j.callback);
            c.lua_pushboolean(Ls, @intFromBool(j.ok));
            var nargs: c_int = 1;
            if (j.results.items.len == 0) {
                lua.pushString(Ls, "out of memory");
                nargs += 1;
            } else {
                var r: Reader = .{ .bytes = j.results.items };
                nargs += decodeAll(Ls, &r);
            }
            lua.call(Ls, nargs, 0);
            return 0;
        }
    }.run);
    c.lua_pushlightuserdata(L, job);
    st.depth += 1;
    if (lua.pcall(L, 1, 0, top + 1) != lua.ok) st.report(L);
    st.leave(L);
    c.lua_settop(L, top);
}

fn destroy(ud: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(ud.?));
    if (job.callback != lua.noref) c.luaL_unref(job.st.main, lua.registry, job.callback);
    free(job);
}
