//! Lua applications on sway running headless (`zig build
//! test-integration`, D24). Two clients: one in this process through the
//! binding over libsiv.so, and the installed siv-lua runner as another
//! process. A key typed into the runner's window makes it copy; the
//! in-process client, focused next, pastes the text from a coroutine
//! through a real Wayland data offer; sway's kill reaches the runner as a
//! close request that ends its app:run(), and it exits cleanly.
//!
//! Imports: lua, platform, helpers.

const std = @import("std");
const linux = std.os.linux;
const lua = @import("lua");
const platform = @import("platform");
const helpers = @import("helpers");

const c = lua.c_api;
const testing = std.testing;
const Sway = platform.test_sway.Sway;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn sway(L: ?*c.lua_State) *Sway {
    return @ptrCast(@alignCast(c.lua_touserdata(L, c.LUA_REGISTRYINDEX - 1)));
}

/// T.command(cmd): runs a sway command.
fn command(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const cmd = c.luaL_checklstring(L, 1, &len);
    sway(L).command(cmd[0..len]) catch return c.luaL_error(L, "sway command failed: %s", cmd);
    return 0;
}

/// T.spawn(argv...): starts a Wayland client of this sway; returns its pid.
fn spawn(L: ?*c.lua_State) callconv(.c) c_int {
    const n: usize = @intCast(c.lua_gettop(L));
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    for (0..@min(n, 15)) |i| argv[i] = c.luaL_checklstring(L, @intCast(i + 1), null);
    const pid = sway(L).spawnClient(&argv) catch |err| return c.luaL_error(L, "cannot start %s: %s", argv[0].?, @errorName(err).ptr);
    c.lua_pushinteger(L, pid);
    return 1;
}

/// T.exited(pid): its exit status once it exited, else nil.
fn exited(L: ?*c.lua_State) callconv(.c) c_int {
    const pid: linux.pid_t = @intCast(c.luaL_checkinteger(L, 1));
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, std.c.W.NOHANG) == 0) return 0;
    c.lua_pushinteger(L, status);
    return 1;
}

fn kill(L: ?*c.lua_State) callconv(.c) c_int {
    const pid: linux.pid_t = @intCast(c.luaL_checkinteger(L, 1));
    _ = std.c.kill(pid, std.c.SIG.TERM);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    return 0;
}

/// The runner's script: a window whose key handler copies.
const copy_script =
    \\local dir = ...
    \\local siv = require("siv")
    \\local function touch(name)
    \\  local f = assert(io.open(dir .. "/" .. name, "w"))
    \\  f:close()
    \\end
    \\local app = siv.app_create{ flags = { "no_system_fonts" } }
    \\-- Sway activates a window once it maps.
    \\local win = app:window_create{ title = "lua-b", on_event = function(_, ev)
    \\  if ev.type == "states_changed" and ev.states.activated then touch("ready") end
    \\end }
    \\local box = win:update(function(txn, root)
    \\  txn:set_visual(root, { background = "#ffffff" })
    \\  return txn:box(root, {
    \\    layout = { grow = 1, width = { "fraction", 1 }, height = { "fraction", 1 } },
    \\    semantics = { role = "button", flags = "focusable" },
    \\    on = { key = function(_, ev)
    \\      if ev.flags.pressed then
    \\        win:clipboard_write("clipboard", "copied by siv-lua")
    \\        touch("copied")
    \\      end
    \\      return true
    \\    end },
    \\  })
    \\end)
    \\box:focus()
    \\app:run()
    \\touch("closed")
;

/// The in-process client.
const paste_script =
    \\local T, display, dir = ...
    \\local siv = require("siv")
    \\local app <close> = siv.app_create{ display = display, flags = { "no_system_fonts" } }
    \\local size
    \\local win = app:window_create{ title = "lua-a", on_event = function(_, ev)
    \\  if ev.type == "resized" then size = { ev.width, ev.height } end
    \\end }
    \\win:update(function(txn, root) txn:set_visual(root, { background = "#ffffff" }) end)
    \\local function exists(name)
    \\  local f = io.open(dir .. "/" .. name, "r")
    \\  if f then f:close() end
    \\  return f ~= nil
    \\end
    \\local function wait(what, cond)
    \\  for _ = 1, 1000 do
    \\    if cond() then return end
    \\    app:dispatch(10)
    \\  end
    \\  error("timed out waiting for " .. what)
    \\end
    \\-- Sway tiles the only window over its 1280x720 output.
    \\wait("the window to fill the output", function() return size and size[1] == 1280 and size[2] == 720 end)
    \\-- An idle virtual keyboard first, so that the runner's keyboard is
    \\-- there before its keys.
    \\local keyboard = T.spawn("wtype", "-s", "60000")
    \\local runner = T.spawn("siv-lua", dir .. "/copy.lua", dir)
    \\wait("siv-lua's window", function() return exists("ready") end)
    \\T.command('[title="lua-b"] focus')
    \\local typer = T.spawn("wtype", "x")
    \\wait("the copy", function() return exists("copied") end)
    \\local typed
    \\wait("wtype to exit", function() typed = T.exited(typer); return typed ~= nil end)
    \\assert(typed == 0, "wtype exited with " .. tostring(typed))
    \\-- Focused, this client gets the runner's selection and pastes it.
    \\T.command('[title="lua-a"] focus')
    \\local got
    \\siv.spawn(function()
    \\  for _ = 1, 100 do
    \\    got = win:clipboard_read("clipboard")
    \\    if got == "copied by siv-lua" then return end
    \\    app:sleep(50)
    \\  end
    \\end)
    \\wait("the paste", function() return got == "copied by siv-lua" end)
    \\-- Sway's kill is a close request: the runner's run returns.
    \\T.command('[title="lua-b"] kill')
    \\local status
    \\wait("siv-lua to exit", function() status = T.exited(runner); return status ~= nil end)
    \\assert(status == 0, "siv-lua exited with " .. tostring(status))
    \\assert(exists("closed"))
    \\T.kill(keyboard)
;

test "lua on sway: siv-lua copies, the binding pastes from a coroutine, kill closes" {
    var s: Sway = .{};
    try s.start();
    defer s.stop();

    // The runner by name, as spawnClient finds clients on PATH, which it
    // keeps short: a link in sway's directory.
    var link_buf: [128]u8 = undefined;
    const bin = try std.fmt.bufPrintSentinel(&link_buf, "{s}/bin", .{s.dir}, 0);
    _ = linux.mkdir(bin, 0o700);
    var target_buf: [linux.PATH_MAX]u8 = undefined;
    const target = if (std.fs.path.isAbsolute(helpers.runner)) try std.fmt.bufPrintSentinel(&target_buf, "{s}", .{helpers.runner}, 0) else blk: {
        var cwd_buf: [linux.PATH_MAX]u8 = undefined;
        const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.Unexpected)), 0);
        break :blk try std.fmt.bufPrintSentinel(&target_buf, "{s}/{s}", .{ cwd, helpers.runner }, 0);
    };
    var name_buf: [160]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&name_buf, "{s}/siv-lua", .{bin}, 0);
    if (linux.errno(linux.symlink(target, name)) != .SUCCESS) return error.Unexpected;
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}:/usr/local/bin:/usr/bin:/bin", .{bin}, 0);
    _ = setenv("PATH", path.ptr, 1);

    const io = testing.io;
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/lua", .{s.dir});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var script_buf: [160]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&script_buf, "{s}/copy.lua", .{dir}), .data = copy_script });

    // libsiv.so's logs and the runner's go to a file, shown if the test
    // fails: the test runner shows any output on stderr as a failure.
    var log_buf: [160]u8 = undefined;
    const log_path = try std.fmt.bufPrintSentinel(&log_buf, "{s}/stderr.log", .{dir}, 0);
    const log_rc = linux.openat(linux.AT.FDCWD, log_path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(log_rc) != .SUCCESS) return error.Unexpected;
    const saved: i32 = @intCast(linux.dup(2));
    _ = linux.dup2(@intCast(log_rc), 2);
    _ = linux.close(@intCast(log_rc));
    var restored = false;
    const restore = struct {
        fn f(fd: i32, done: *bool) void {
            if (done.*) return;
            done.* = true;
            _ = linux.dup2(fd, 2);
            _ = linux.close(fd);
        }
    }.f;
    defer restore(saved, &restored);

    const L = lua.siv_lua_new(~@as(c_int, 0)) orelse return error.OutOfMemory;
    defer c.lua_close(L);
    if (c.luaL_loadbufferx(L, paste_script.ptr, paste_script.len, "=paste", "t") != 0) return error.LuaSyntax;
    c.lua_createtable(L, 0, 4);
    inline for (.{ .{ "command", command }, .{ "spawn", spawn }, .{ "exited", exited }, .{ "kill", kill } }) |entry| {
        c.lua_pushlightuserdata(L, &s);
        c.lua_pushcclosure(L, entry[1], 1);
        c.lua_setfield(L, -2, entry[0]);
    }
    _ = c.lua_pushlstring(L, s.display.ptr, s.display.len);
    _ = c.lua_pushlstring(L, dir.ptr, dir.len);
    if (c.lua_pcallk(L, 3, 0, 0, 0, null) != 0) {
        restore(saved, &restored);
        const logged = std.Io.Dir.cwd().readFileAlloc(io, log_path, testing.allocator, .limited(1 << 20)) catch "";
        defer if (logged.len > 0) testing.allocator.free(logged);
        std.debug.print("{s}", .{logged});
        lua.printError(L, -1);
        return error.LuaError;
    }
}
