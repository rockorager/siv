//! A private dbus-daemon for integration tests, and process helpers. Not
//! part of libsiv.

const std = @import("std");
const linux = std.os.linux;

/// dbus-daemon with a private configuration: every name and message
/// allowed, and service activation only from `service_dir`.
pub const Daemon = struct {
    /// A directory of D-Bus service files to activate services from.
    service_dir: ?[]const u8 = null,
    dir_buf: [64]u8 = undefined,
    dir: [:0]const u8 = "",
    addr_buf: [96]u8 = undefined,
    address: [:0]const u8 = "",
    pid: linux.pid_t = 0,

    var counter: u32 = 0;

    pub fn start(d: *Daemon) !void {
        const exe = findExecutable("dbus-daemon") orelse {
            std.log.err("dbus-daemon is not installed; run .agents/setup", .{});
            return error.DbusDaemonNotInstalled;
        };
        counter += 1;
        d.dir = try std.fmt.bufPrintSentinel(&d.dir_buf, "/tmp/siv-dbus-{d}-{d}", .{ linux.getpid(), counter }, 0);
        _ = linux.mkdir(d.dir, 0o700);
        var config_buf: [128]u8 = undefined;
        const config = try std.fmt.bufPrintSentinel(&config_buf, "{s}/bus.conf", .{d.dir}, 0);
        var service_buf: [192]u8 = undefined;
        const services = if (d.service_dir) |dir| try std.fmt.bufPrint(&service_buf, "<servicedir>{s}</servicedir>", .{dir}) else "";
        var text_buf: [1024]u8 = undefined;
        try writeFile(config, try std.fmt.bufPrint(&text_buf,
            \\<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
            \\ "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
            \\<busconfig>
            \\  <type>session</type>
            \\  <listen>unix:path={s}/bus</listen>
            \\  <auth>EXTERNAL</auth>
            \\  {s}
            \\  <policy context="default">
            \\    <allow send_destination="*" eavesdrop="true"/>
            \\    <allow eavesdrop="true"/>
            \\    <allow own="*"/>
            \\  </policy>
            \\</busconfig>
            \\
        , .{ d.dir, services }));
        d.address = try std.fmt.bufPrintSentinel(&d.addr_buf, "unix:path={s}/bus", .{d.dir}, 0);
        var config_arg_buf: [160]u8 = undefined;
        const config_arg = try std.fmt.bufPrintSentinel(&config_arg_buf, "--config-file={s}", .{config}, 0);
        const argv = [_:null]?[*:0]const u8{ exe, "--nofork", "--nopidfile", config_arg };
        const envp = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
        d.pid = try spawn(exe, &argv, &envp, null);
        errdefer d.stop();
        // The socket file appears when the daemon binds it, a moment
        // before it listens; connect only once it accepts connections.
        const sock = d.address["unix:path=".len..];
        var waited: u32 = 0;
        while (!accepting(sock)) : (waited += 1) {
            if (waited > 500) return error.DbusDaemonDidNotStart;
            sleepMs(10);
        }
    }

    pub fn stop(d: *Daemon) void {
        if (d.pid != 0) {
            kill(d.pid);
            d.pid = 0;
        }
        // With whatever the tests put there (client scripts, an
        // accessibility bus's socket, Orca's home).
        removeTree(d.dir);
    }
};

/// Whether something accepts connections on the unix socket at `path`.
fn accepting(path: []const u8) bool {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return false;
    @memcpy(addr.path[0..path.len], path);
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    return linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) == .SUCCESS;
}

/// Removes a test's private directory and everything in it.
pub fn removeTree(dir: []const u8) void {
    if (dir.len == 0) return;
    var buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&buf, "rm -rf -- '{s}'", .{dir}, 0) catch return;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd };
    const envp = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
    const pid = spawn("/bin/sh", &argv, &envp, null) catch return;
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
}

/// Forks and execs `exe` as the leader of a new process group, dying with
/// the test. `output` becomes the child's stdout and stderr; without it
/// they go to /dev/null, since the test runner's stdout is its protocol
/// pipe to the build runner and must not carry a child's chatter.
pub fn spawn(exe: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, output: ?i32) !linux.pid_t {
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.SpawnFailed;
    if (rc != 0) return @intCast(rc);
    _ = linux.setsid();
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.KILL), 0, 0, 0);
    const fd: i32 = output orelse @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0));
    _ = linux.dup2(fd, 0);
    _ = linux.dup2(fd, 1);
    _ = linux.dup2(fd, 2);
    _ = linux.execve(exe, argv, envp);
    linux.exit_group(127);
}

/// Terminates a spawned process with its whole group and reaps it,
/// killing it outright if it is still alive after a second.
pub fn kill(pid: linux.pid_t) void {
    _ = std.c.kill(-pid, .TERM);
    var status: c_int = 0;
    var waited: u32 = 0;
    while (std.c.waitpid(pid, &status, std.c.W.NOHANG) == 0) : (waited += 1) {
        if (waited == 100) {
            _ = std.c.kill(-pid, .KILL);
            _ = std.c.waitpid(pid, &status, 0);
            break;
        }
        sleepMs(10);
    }
    _ = std.c.kill(-pid, .KILL);
}

pub fn findExecutable(name: []const u8) ?[*:0]const u8 {
    // Longer paths cannot be executed.
    const S = struct {
        var buf: [linux.PATH_MAX]u8 = undefined;
    };
    const path = std.mem.span(std.c.getenv("PATH") orelse "/usr/bin:/bin");
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = std.fmt.bufPrintSentinel(&S.buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
        if (linux.access(full, 1) == 0) return full;
    }
    return null;
}

/// A helper program that distributions install outside PATH, in
/// /usr/libexec (Debian, Fedora) or /usr/lib (Arch), written into `buf`.
pub fn findLibexec(buf: []u8, name: []const u8) ?[:0]const u8 {
    for ([_][]const u8{ "/usr/libexec", "/usr/lib" }) |dir| {
        const full = std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch return null;
        if (linux.access(full, 1) == 0) return full;
    }
    return null;
}

pub fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.write(fd, data.ptr, data.len)) != .SUCCESS) return error.WriteFailed;
}

pub fn sleepMs(ms: u64) void {
    const ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}
