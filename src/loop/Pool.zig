//! The loop's view of the application worker pool (D5, D6): async jobs
//! whose `done` runs on the loop thread in the dispatch phase, so
//! completions are safe points like every other callback. The threads and
//! queue are the shared `pool` module's, which the renderer also uses for
//! fork-join tiles through `executor()` (D10), so the application has one
//! pool and never oversubscribes the CPU.
//!
//! Jobs are intrusive and submitting one does not allocate.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const shared = @import("pool");
const Loop = @import("loop.zig").Loop;
const Pool = @This();

loop: *Loop,
workers: shared.Pool,

pub const Job = struct {
    /// Runs on a worker thread.
    run: *const fn (*Job) void,
    /// Runs on the loop thread after `run` returns. The job may be freed or
    /// resubmitted from here.
    done: *const fn (*Job) void,
    /// Runs instead of `done` when the job will never complete: `Pool.deinit`
    /// dropped it while queued, or the loop was deinitialized before
    /// delivering its completion. Must only release resources.
    cancel: ?*const fn (*Job) void = null,
    /// The threads that run it (see the pool module): compute workers,
    /// or the blocking lane for work that waits on I/O.
    class: shared.Job.Class = .compute,
    /// Compute jobs: higher runs first (`setPriority` while queued).
    priority: i64 = 0,
    /// Loop-thread view: queued from `submit` until `done` or `cancel`.
    state: State = .idle,
    loop: *Loop = undefined,
    inner: shared.Job = .{ .run = innerRun, .complete = innerComplete, .cancel = innerCancel },
    remote: Loop.Remote = .{ .func = complete, .cancel = drop },

    pub const State = enum { idle, queued, running };

    fn innerRun(inner: *shared.Job) void {
        const job: *Job = @fieldParentPtr("inner", inner);
        job.run(job);
    }

    fn innerComplete(inner: *shared.Job) void {
        const job: *Job = @fieldParentPtr("inner", inner);
        // The loop thread may free the job as soon as it is posted.
        job.loop.postRemote(&job.remote);
    }

    fn innerCancel(inner: *shared.Job) void {
        const job: *Job = @fieldParentPtr("inner", inner);
        drop(&job.remote);
    }

    fn complete(r: *Loop.Remote) void {
        const job: *Job = @fieldParentPtr("remote", r);
        job.state = .idle;
        job.done(job);
    }

    fn drop(r: *Loop.Remote) void {
        const job: *Job = @fieldParentPtr("remote", r);
        job.state = .idle;
        if (job.cancel) |f| f(job);
    }
};

pub fn init(loop: *Loop, allocator: Allocator, max_threads: u32) Pool {
    return .{ .loop = loop, .workers = .init(allocator, max_threads) };
}

/// The number of online CPUs, a reasonable `max_threads`.
pub const defaultThreadCount = shared.defaultThreadCount;

/// Cancels queued jobs (see `Job.cancel`), waits for running jobs, and
/// joins the workers. Completions of jobs that finished are still delivered
/// by the loop, or cancelled when it is deinitialized.
pub fn deinit(pool: *Pool) void {
    pool.workers.deinit();
    pool.* = undefined;
}

pub const SubmitError = shared.Pool.SubmitError;

/// Queues `job`. It must not be queued or running already.
pub fn submit(pool: *Pool, job: *Job) SubmitError!void {
    std.debug.assert(job.state == .idle);
    job.loop = pool.loop;
    job.state = .queued;
    job.inner.class = job.class;
    job.inner.priority = job.priority;
    pool.workers.submit(&job.inner) catch |err| {
        job.state = .idle;
        return err;
    };
}

/// Removes a queued job before it starts. Returns false if it is running or
/// already finished, in which case `done` is still delivered.
pub fn cancel(pool: *Pool, job: *Job) bool {
    if (!pool.workers.cancel(&job.inner)) return false;
    job.state = .idle;
    return true;
}

/// Changes a job's priority; a queued job moves to its new place.
pub fn setPriority(pool: *Pool, job: *Job, priority: i64) void {
    job.priority = priority;
    pool.workers.setPriority(&job.inner, priority);
}

/// Fork-join on the same threads, for the renderer (D10).
pub fn executor(pool: *Pool) shared.Executor {
    return pool.workers.executor();
}

/// Reads a whole file on a worker. `path` must stay valid until `on_done`
/// runs on the loop thread; `allocator` must be thread-safe and owns
/// `result` afterwards.
pub const ReadFile = struct {
    job: Job = .{ .run = run, .done = done, .class = .blocking },
    path: [:0]const u8,
    allocator: Allocator,
    max_bytes: usize = std.math.maxInt(usize),
    on_done: *const fn (*ReadFile) void,
    result: Error![]u8 = error.Canceled,

    pub const Error = error{ FileNotFound, AccessDenied, IsDir, FileTooBig, InputOutput, Canceled, Unexpected } ||
        Allocator.Error;

    fn run(job: *Job) void {
        const rf: *ReadFile = @fieldParentPtr("job", job);
        rf.result = rf.read();
    }

    fn done(job: *Job) void {
        const rf: *ReadFile = @fieldParentPtr("job", job);
        rf.on_done(rf);
    }

    fn read(rf: *ReadFile) Error![]u8 {
        const rc = linux.openat(linux.AT.FDCWD, rf.path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        const fd: i32 = switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .NOENT, .NOTDIR => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            .NOMEM => return error.OutOfMemory,
            else => return error.Unexpected,
        };
        defer _ = linux.close(fd);

        // Sizes from fstat are unreliable for /proc and pipes; read to EOF.
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(rf.allocator);
        while (true) {
            if (buf.items.len >= rf.max_bytes) {
                var probe: [1]u8 = undefined;
                if (linux.read(fd, &probe, 1) == 0) break;
                return error.FileTooBig;
            }
            try buf.ensureUnusedCapacity(rf.allocator, 64 * 1024);
            const space = buf.unusedCapacitySlice();
            const want = @min(space.len, rf.max_bytes - buf.items.len);
            const n = linux.read(fd, space.ptr, want);
            switch (linux.errno(n)) {
                .SUCCESS => if (n == 0) break else {
                    buf.items.len += n;
                },
                .INTR => {},
                .ISDIR => return error.IsDir,
                .IO => return error.InputOutput,
                else => return error.Unexpected,
            }
        }
        return buf.toOwnedSlice(rf.allocator);
    }
};

const testing = std.testing;

test "jobs run on workers and complete on the loop thread" {
    var loop = try Loop.init(std.heap.smp_allocator);
    defer loop.deinit();
    var pool = Pool.init(&loop, testing.allocator, 3);
    defer pool.deinit();

    const Work = struct {
        job: Job = .{ .run = run, .done = done },
        input: u64,
        output: u64 = 0,
        worker_thread: std.Thread.Id = 0,
        completed: *usize,
        loop_thread: std.Thread.Id,

        fn run(job: *Job) void {
            const w: *@This() = @fieldParentPtr("job", job);
            w.worker_thread = std.Thread.getCurrentId();
            w.output = w.input * w.input;
        }
        fn done(job: *Job) void {
            const w: *@This() = @fieldParentPtr("job", job);
            testing.expectEqual(w.loop_thread, std.Thread.getCurrentId()) catch unreachable;
            w.completed.* += 1;
        }
    };
    var completed: usize = 0;
    var work: [16]Work = undefined;
    for (&work, 0..) |*w, i| {
        w.* = .{ .input = i + 1, .completed = &completed, .loop_thread = std.Thread.getCurrentId() };
        try pool.submit(&w.job);
    }
    while (completed < work.len) try loop.dispatch(-1);
    for (work, 0..) |w, i| {
        try testing.expectEqual((i + 1) * (i + 1), w.output);
        try testing.expect(w.worker_thread != std.Thread.getCurrentId());
        try testing.expectEqual(Job.State.idle, w.job.state);
    }
    try testing.expect(pool.workers.threads.items.len <= 3);
}

test "cancel removes a queued job" {
    var loop = try Loop.init(std.heap.smp_allocator);
    defer loop.deinit();
    var pool = Pool.init(&loop, testing.allocator, 1);
    defer pool.deinit();

    // The first job blocks the only worker until released, so the second
    // stays queued.
    const Gate = struct {
        job: Job = .{ .run = run, .done = done },
        open: std.atomic.Value(bool) = .init(false),
        started: std.atomic.Value(bool) = .init(false),
        finished: bool = false,
        fn run(job: *Job) void {
            const g: *@This() = @fieldParentPtr("job", job);
            g.started.store(true, .release);
            while (!g.open.load(.acquire)) std.atomic.spinLoopHint();
        }
        fn done(job: *Job) void {
            const g: *@This() = @fieldParentPtr("job", job);
            g.finished = true;
        }
    };
    var first: Gate = .{};
    var second: Gate = .{};
    try pool.submit(&first.job);
    try pool.submit(&second.job);
    while (!first.started.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expect(!pool.cancel(&first.job));
    try testing.expect(pool.cancel(&second.job));
    try testing.expect(!pool.cancel(&second.job));
    first.open.store(true, .release);
    while (!first.finished) try loop.dispatch(-1);
    try testing.expect(!second.finished);
    try testing.expectEqual(Job.State.idle, second.job.state);
}

test "deinit cancels queued jobs and undelivered completions" {
    var loop = try Loop.init(std.heap.smp_allocator);
    var pool = Pool.init(&loop, testing.allocator, 1);

    const Gate = struct {
        job: Job = .{ .run = run, .done = done, .cancel = cancelled },
        open: std.atomic.Value(bool) = .init(false),
        started: std.atomic.Value(bool) = .init(false),
        outcome: enum { none, done, cancelled } = .none,
        fn run(job: *Job) void {
            const g: *@This() = @fieldParentPtr("job", job);
            g.started.store(true, .release);
            while (!g.open.load(.acquire)) std.atomic.spinLoopHint();
        }
        fn done(job: *Job) void {
            const g: *@This() = @fieldParentPtr("job", job);
            g.outcome = .done;
        }
        fn cancelled(job: *Job) void {
            const g: *@This() = @fieldParentPtr("job", job);
            g.outcome = .cancelled;
        }
        fn openLater(g: *@This()) void {
            var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
            _ = std.os.linux.nanosleep(&ts, null);
            g.open.store(true, .release);
        }
    };
    // The first job occupies the only worker; the second stays queued.
    var first: Gate = .{};
    var second: Gate = .{};
    try pool.submit(&first.job);
    try pool.submit(&second.job);
    while (!first.started.load(.acquire)) std.atomic.spinLoopHint();
    const opener = try std.Thread.spawn(.{}, Gate.openLater, .{&first});
    pool.deinit(); // waits for the first job, cancels the second
    opener.join();
    try testing.expectEqual(.cancelled, second.outcome);
    try testing.expectEqual(.none, first.outcome);
    loop.deinit(); // the first job's completion was never dispatched
    try testing.expectEqual(.cancelled, first.outcome);
}

test "ReadFile reads on a worker" {
    var loop = try Loop.init(std.heap.smp_allocator);
    defer loop.deinit();
    var pool = Pool.init(&loop, testing.allocator, 2);
    defer pool.deinit();

    const State = struct {
        var finished: usize = 0;
        fn onDone(_: *ReadFile) void {
            finished += 1;
        }
    };
    // /proc/self/maps reports size 0 but has content.
    var ok: ReadFile = .{ .path = "/proc/self/maps", .allocator = std.heap.smp_allocator, .on_done = State.onDone };
    var missing: ReadFile = .{ .path = "/nonexistent/siv", .allocator = std.heap.smp_allocator, .on_done = State.onDone };
    var limited: ReadFile = .{ .path = "/proc/self/maps", .allocator = std.heap.smp_allocator, .max_bytes = 8, .on_done = State.onDone };
    try pool.submit(&ok.job);
    try pool.submit(&missing.job);
    try pool.submit(&limited.job);
    while (State.finished < 3) try loop.dispatch(-1);

    const data = try ok.result;
    defer std.heap.smp_allocator.free(data);
    try testing.expect(data.len > 0);
    try testing.expect(std.mem.indexOf(u8, data, "[stack]") != null);
    try testing.expectError(error.FileNotFound, missing.result);
    try testing.expectError(error.FileTooBig, limited.result);
}
