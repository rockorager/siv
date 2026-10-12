//! Test harness for compositor_tests.zig: a compositor from compositors.zig
//! running headless in a private runtime directory, sway's IPC for scripted
//! input, outputs, and windows, and a virtual pointer. Tests skip when the
//! compositor is not installed (.agents/compositors.nix pins them).

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wayland").client.wl;
const compositors = @import("compositors.zig");

pub const Compositor = struct {
    entry: compositors.Entry,
    dir_buf: [64]u8 = undefined,
    dir: [:0]const u8 = "",
    display_buf: [96]u8 = undefined,
    /// Absolute path of the Wayland socket, for wl_display_connect.
    display: [:0]const u8 = "",
    pid: linux.pid_t = 0,

    var counter: u32 = 0;

    /// Starts the compositor and waits for its socket (and sway's IPC).
    pub fn start(s: *Compositor) !void {
        const e = s.entry;
        const exe = findExecutable(e.argv[0]) orelse return error.SkipZigTest;
        counter += 1;
        s.dir = try std.fmt.bufPrintSentinel(&s.dir_buf, "/tmp/siv-{s}-{d}-{d}", .{ e.name, linux.getpid(), counter }, 0);
        _ = linux.mkdir(s.dir, 0o700);
        if (e.config) |text| {
            var config_buf: [128]u8 = undefined;
            try writeFile(try std.fmt.bufPrintSentinel(&config_buf, "{s}/config", .{s.dir}, 0), text);
        }

        // argv with {dir} substituted.
        var arg_bufs: [16][256]u8 = undefined;
        var argv: [16:null]?[*:0]const u8 = @splat(null);
        std.debug.assert(e.argv.len < argv.len);
        argv[0] = exe;
        for (e.argv[1..], 1..) |arg, i| {
            const n = std.mem.replacementSize(u8, arg, "{dir}", s.dir);
            _ = std.mem.replace(u8, arg, "{dir}", s.dir, &arg_bufs[i]);
            arg_bufs[i][n] = 0;
            argv[i] = arg_bufs[i][0..n :0];
        }
        var env: Env = .{};
        try env.init(s.dir);
        var log_buf: [128]u8 = undefined;
        const log = try std.fmt.bufPrintSentinel(&log_buf, "{s}/log", .{s.dir}, 0);
        s.pid = try spawn(exe, &argv, &env.ptrs, log);
        errdefer s.stop();

        s.display = try std.fmt.bufPrintSentinel(&s.display_buf, "{s}/wayland-1", .{s.dir}, 0);
        var waited: u32 = 0;
        while (linux.access(s.display, 0) != 0) : (waited += 1) {
            if (waited > 500) return error.CompositorDidNotStart;
            sleepMs(10);
        }
        if (!std.mem.eql(u8, e.name, "sway")) return;
        // IPC may accept connections slightly after the socket file appears.
        while (true) : (waited += 1) {
            _ = s.command("nop") catch {
                if (waited > 500) return error.CompositorDidNotStart;
                sleepMs(10);
                continue;
            };
            break;
        }
    }

    pub fn stop(s: *Compositor) void {
        if (s.pid != 0) {
            // The compositor leads its own process group, which includes
            // helpers such as mutter's session bus.
            _ = std.c.kill(-s.pid, .TERM);
            var status: c_int = 0;
            _ = std.c.waitpid(s.pid, &status, 0);
            _ = std.c.kill(-s.pid, .KILL);
            s.pid = 0;
        }
        // Remove the runtime directory.
        var env: Env = .{};
        env.init(s.dir) catch return;
        const argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", s.dir };
        const pid = spawn("/bin/rm", &argv, &env.ptrs, null) catch return;
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
    }

    fn ipcPath(s: *const Compositor) [:0]const u8 {
        const S = struct {
            var buf: [128]u8 = undefined;
        };
        const path = std.fmt.bufPrintSentinel(&S.buf, "{s}/ipc.sock", .{s.dir}, 0) catch unreachable;
        return if (linux.access(path, 0) == 0) path else "";
    }

    /// Runs a sway command (RUN_COMMAND) and fails unless it succeeded.
    pub fn command(s: *const Compositor, cmd: []const u8) !void {
        std.debug.assert(std.mem.eql(u8, s.entry.name, "sway"));
        const fd_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return error.IpcFailed;
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        const path = s.ipcPath();
        if (path.len == 0) return error.IpcFailed;
        @memcpy(addr.path[0..path.len], path);
        if (linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un)) != 0) return error.IpcFailed;

        var header: [14]u8 = undefined;
        @memcpy(header[0..6], "i3-ipc");
        std.mem.writeInt(u32, header[6..10], @intCast(cmd.len), .little);
        std.mem.writeInt(u32, header[10..14], 0, .little); // RUN_COMMAND
        try writeAll(fd, &header);
        try writeAll(fd, cmd);

        try readAll(fd, &header);
        const len = std.mem.readInt(u32, header[6..10], .little);
        var reply: [4096]u8 = undefined;
        if (len > reply.len) return error.IpcFailed;
        try readAll(fd, reply[0..len]);
        if (std.mem.indexOf(u8, reply[0..len], "\"success\": false") != null) {
            std.log.err("sway command '{s}' failed: {s}", .{ cmd, reply[0..len] });
            return error.CommandFailed;
        }
    }

    /// Starts a Wayland client (such as wtype) against this compositor.
    pub fn spawnClient(s: *const Compositor, argv: [*:null]const ?[*:0]const u8) !linux.pid_t {
        const exe = findExecutable(std.mem.span(argv[0].?)) orelse return error.SkipZigTest;
        var env: Env = .{};
        try env.init(s.dir);
        return spawn(exe, argv, &env.ptrs, null);
    }

    pub fn wait(_: *const Compositor, pid: linux.pid_t) !void {
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
        if (status != 0) return error.ClientFailed;
    }
};

/// Environment for children: a headless wlroots in the private directory.
const Env = struct {
    bufs: [4][160]u8 = undefined,
    ptrs: [8:null]?[*:0]const u8 = @splat(null),

    fn init(env: *Env, dir: []const u8) !void {
        const vars = [_][]const u8{ "XDG_RUNTIME_DIR={s}", "SWAYSOCK={s}/ipc.sock", "WAYLAND_DISPLAY={s}/wayland-1" };
        inline for (vars, 0..) |fmt, i| env.ptrs[i] = try std.fmt.bufPrintSentinel(&env.bufs[i], fmt, .{dir}, 0);
        const path = std.c.getenv("PATH") orelse "/usr/bin:/bin";
        env.ptrs[3] = try std.fmt.bufPrintSentinel(&env.bufs[3], "PATH={s}", .{path}, 0);
        env.ptrs[4] = "WLR_BACKENDS=headless";
        env.ptrs[5] = "WLR_RENDERER=pixman";
        env.ptrs[6] = "WLR_LIBINPUT_NO_DEVICES=1";
        // wtype decodes its arguments as UTF-8.
        env.ptrs[7] = "LC_ALL=C.UTF-8";
    }
};

fn spawn(exe: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, log: ?[*:0]const u8) !linux.pid_t {
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.SpawnFailed;
    if (rc != 0) return @intCast(rc);
    // Child: only async-signal-safe system calls until exec.
    _ = linux.setsid();
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.KILL), 0, 0, 0);
    if (log) |l| {
        const fd = linux.openat(linux.AT.FDCWD, l, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        if (linux.errno(fd) == .SUCCESS) {
            _ = linux.dup2(@intCast(fd), 1);
            _ = linux.dup2(@intCast(fd), 2);
        }
    }
    _ = linux.execve(exe, argv, envp);
    linux.exit_group(127);
}

fn findExecutable(name: []const u8) ?[*:0]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    const path = std.mem.span(std.c.getenv("PATH") orelse "/usr/bin:/bin");
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = std.fmt.bufPrintSentinel(&S.buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
        if (linux.access(full, 1) == 0) return full;
    }
    return null;
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    try writeAll(fd, data);
}

fn writeAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
        off += n;
    }
}

fn readAll(fd: i32, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = linux.read(fd, buf[off..].ptr, buf.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return error.ReadFailed;
        off += n;
    }
}

pub fn sleepMs(ms: u64) void {
    const ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

/// A wlr-virtual-pointer-unstable-v1 client on its own connection, for
/// scripted pointer input on sway. The protocol is not in wayland-protocols,
/// so its two interfaces are described here by hand.
pub const VirtualPointer = struct {
    display: *wl.Display,
    pointer: *wl.Proxy,
    time: u32 = 0,

    const manager_interface: wl.Interface = .{
        .name = "zwlr_virtual_pointer_manager_v1",
        .version = 1,
        .method_count = 2,
        .methods = &[_]wl.Message{
            .{ .name = "create_virtual_pointer", .signature = "?on", .types = &[_]?*const wl.Interface{ wl.Seat.interface, &pointer_interface } },
            .{ .name = "destroy", .signature = "", .types = null },
        },
        .event_count = 0,
        .events = null,
    };
    const pointer_interface: wl.Interface = .{
        .name = "zwlr_virtual_pointer_v1",
        .version = 1,
        .method_count = 9,
        .methods = &[_]wl.Message{
            .{ .name = "motion", .signature = "uff", .types = &[_]?*const wl.Interface{ null, null, null } },
            .{ .name = "motion_absolute", .signature = "uuuuu", .types = &[_]?*const wl.Interface{ null, null, null, null, null } },
            .{ .name = "button", .signature = "uuu", .types = &[_]?*const wl.Interface{ null, null, null } },
            .{ .name = "axis", .signature = "uuf", .types = &[_]?*const wl.Interface{ null, null, null } },
            .{ .name = "frame", .signature = "", .types = null },
            .{ .name = "axis_source", .signature = "u", .types = &[_]?*const wl.Interface{null} },
            .{ .name = "axis_stop", .signature = "uu", .types = &[_]?*const wl.Interface{ null, null } },
            .{ .name = "axis_discrete", .signature = "uufi", .types = &[_]?*const wl.Interface{ null, null, null, null } },
            .{ .name = "destroy", .signature = "", .types = null },
        },
        .event_count = 0,
        .events = null,
    };
    const Manager = opaque {
        pub const interface = &manager_interface;
        pub const generated_version = 1;
    };

    pub fn connect(c: *const Compositor) !VirtualPointer {
        const display = try wl.Display.connect(c.display);
        errdefer display.disconnect();
        const registry = try display.getRegistry();
        defer registry.destroy();
        const Found = struct {
            manager: u32 = 0,
            fn onGlobal(_: *wl.Registry, event: wl.Registry.Event, found: *@This()) void {
                switch (event) {
                    .global => |g| if (std.mem.eql(u8, std.mem.span(g.interface), "zwlr_virtual_pointer_manager_v1")) {
                        found.manager = g.name;
                    },
                    .global_remove => {},
                }
            }
        };
        var found: Found = .{};
        registry.setListener(*Found, Found.onGlobal, &found);
        if (display.roundtrip() != .SUCCESS or found.manager == 0) return error.SkipZigTest;
        const manager: *wl.Proxy = @ptrCast(try registry.bind(found.manager, Manager, 1));
        var args = [_]wl.Argument{ .{ .o = null }, .{ .o = null } };
        const pointer = manager.marshal(0, &pointer_interface, 1, .{}, &args) orelse return error.OutOfMemory;
        manager.destroy();
        return .{ .display = display, .pointer = pointer };
    }

    pub fn deinit(vp: *VirtualPointer) void {
        _ = vp.pointer.marshal(8, null, 1, .{ .destroy = true }, null);
        _ = vp.display.roundtrip();
        vp.display.disconnect();
    }

    fn send(vp: *VirtualPointer, opcode: u32, args: []wl.Argument) void {
        _ = vp.pointer.marshal(opcode, null, 1, .{}, args.ptr);
    }

    /// Moves to (x, y) on a 1280x720 layout, then ends the frame.
    pub fn moveTo(vp: *VirtualPointer, x: u32, y: u32) void {
        vp.time += 10;
        var args = [_]wl.Argument{ .{ .u = vp.time }, .{ .u = x }, .{ .u = y }, .{ .u = 1280 }, .{ .u = 720 } };
        vp.send(1, &args);
        vp.send(4, &.{});
    }

    pub fn button(vp: *VirtualPointer, code: u32, pressed: bool) void {
        vp.time += 10;
        var args = [_]wl.Argument{ .{ .u = vp.time }, .{ .u = code }, .{ .u = @intFromBool(pressed) } };
        vp.send(2, &args);
        vp.send(4, &.{});
    }

    /// One frame of wheel scrolling on the vertical axis.
    pub fn wheel(vp: *VirtualPointer, value: f64, discrete: i32) void {
        vp.time += 10;
        var source = [_]wl.Argument{.{ .u = 0 }}; // wheel
        vp.send(5, &source);
        var args = [_]wl.Argument{ .{ .u = vp.time }, .{ .u = 0 }, .{ .f = .fromDouble(value) }, .{ .i = discrete } };
        vp.send(7, &args);
        vp.send(4, &.{});
    }

    /// Waits until the compositor processed everything sent.
    pub fn sync(vp: *VirtualPointer) !void {
        if (vp.display.roundtrip() != .SUCCESS) return error.ConnectionLost;
    }
};
