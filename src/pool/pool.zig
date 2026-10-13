//! The application's one worker pool (D6, D8, D10): file I/O, image decode,
//! and raster tiles share its threads so they never oversubscribe the CPU.
//!
//! Two modes on the same threads and queue:
//!
//! - Async jobs (`submit`): `Job.run` executes on a worker, then
//!   `Job.complete` on the same worker. The loop wraps this to deliver
//!   completions on its thread (loop.Pool).
//! - Fork-join (`forkJoin`, or `executor()` for code that should not know
//!   about the pool): runs one function on up to `max_threads + 1` workers
//!   at once, the calling thread included, and returns when all are done.
//!   Work distribution happens inside the function (see `Counter`), so
//!   nothing is allocated or queued per item.
//!
//! Threads start on demand, up to `max_threads`, and idle workers block on a
//! condition variable, so an idle pool costs nothing. Jobs are intrusive and
//! submitting one does not allocate.
//!
//! Jobs have a class. Compute jobs (decoding, tiles, the default) run on
//! those workers, highest `priority` first and in submission order within a
//! priority; fork-join helpers go before every queued job. Blocking jobs
//! (file I/O that may wait on a disk or a network file system, copying a
//! tree) run on a lane of threads of their own, up to `max_blocking`, so a
//! long copy never takes a worker that decoding or rendering needs.
//!
//! Imports: none.

const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;

pub const Pool = struct {
    allocator: Allocator,
    max_threads: u32,
    max_blocking: u32 = default_max_blocking,

    mutex: c.pthread_mutex_t = .{},
    stopping: bool = false,
    threads: std.ArrayList(std.Thread) = .empty,
    lanes: [2]Lane = .{ .{}, .{} },

    /// Serializes fork-join calls; helpers live in `helpers`.
    fork_mutex: c.pthread_mutex_t = .{},
    fork_done: c.pthread_cond_t = .{},
    helpers: []Helper = &.{},
    helpers_pending: u32 = 0,

    pub fn init(allocator: Allocator, max_threads: u32) Pool {
        std.debug.assert(max_threads > 0);
        return .{ .allocator = allocator, .max_threads = max_threads };
    }

    /// Blocking jobs that may run at once. They mostly wait, so the lane
    /// may be wider than the CPU.
    pub const default_max_blocking = 8;

    /// One queue and its threads: compute or blocking.
    const Lane = struct {
        cond: c.pthread_cond_t = .{},
        head: ?*Job = null,
        tail: ?*Job = null,
        queued: u32 = 0,
        idle: u32 = 0,
        threads: u32 = 0,

        /// Inserts after the last job of at least its priority.
        fn insert(lane: *Lane, job: *Job) void {
            job.next = null;
            if (lane.tail == null or lane.tail.?.priority >= job.priority) {
                if (lane.tail) |t| t.next = job else lane.head = job;
                lane.tail = job;
            } else if (lane.head.?.priority < job.priority) {
                job.next = lane.head;
                lane.head = job;
            } else {
                var it = lane.head.?;
                while (it.next.?.priority >= job.priority) it = it.next.?;
                job.next = it.next;
                it.next = job;
            }
            lane.queued += 1;
        }

        fn remove(lane: *Lane, job: *Job) bool {
            var prev: ?*Job = null;
            var it = lane.head;
            while (it) |j| : ({
                prev = j;
                it = j.next;
            }) {
                if (j != job) continue;
                if (prev) |p| p.next = j.next else lane.head = j.next;
                if (lane.tail == j) lane.tail = prev;
                lane.queued -= 1;
                job.next = null;
                return true;
            }
            return false;
        }
    };

    fn laneOf(pool: *Pool, job: *const Job) *Lane {
        return &pool.lanes[@intFromEnum(job.class)];
    }

    /// Cancels queued jobs (see `Job.cancel`), waits for running jobs, and
    /// joins the workers. Not to be called while a fork-join is running.
    pub fn deinit(pool: *Pool) void {
        pool.lock();
        pool.stopping = true;
        var dropped: [2]?*Job = undefined;
        for (&pool.lanes, &dropped) |*lane, *d| {
            d.* = lane.head;
            lane.head = null;
            lane.tail = null;
            lane.queued = 0;
            _ = c.pthread_cond_broadcast(&lane.cond);
        }
        pool.unlock();
        for (dropped) |first| {
            var it = first;
            while (it) |job| {
                it = job.next;
                job.state = .idle;
                job.next = null;
                if (job.cancel) |f| f(job);
            }
        }
        for (pool.threads.items) |t| t.join();
        pool.threads.deinit(pool.allocator);
        pool.allocator.free(pool.helpers);
        for (&pool.lanes) |*lane| _ = c.pthread_cond_destroy(&lane.cond);
        _ = c.pthread_mutex_destroy(&pool.mutex);
        _ = c.pthread_cond_destroy(&pool.fork_done);
        _ = c.pthread_mutex_destroy(&pool.fork_mutex);
        pool.* = undefined;
    }

    pub const SubmitError = error{SystemResources} || Allocator.Error;

    /// Queues `job`. It must not be queued or running already.
    pub fn submit(pool: *Pool, job: *Job) SubmitError!void {
        pool.lock();
        defer pool.unlock();
        return pool.submitLocked(job);
    }

    fn submitLocked(pool: *Pool, job: *Job) SubmitError!void {
        std.debug.assert(job.state == .idle);
        std.debug.assert(!pool.stopping);
        const lane = pool.laneOf(job);
        job.state = .queued;
        lane.insert(job);

        const max = if (job.class == .compute) pool.max_threads else pool.max_blocking;
        if (lane.queued > lane.idle and lane.threads < max) {
            pool.spawnLocked(job.class) catch |err| {
                // Existing workers will get to it eventually; without any,
                // the job could never run.
                if (lane.threads == 0) {
                    pool.removeLocked(job);
                    return err;
                }
            };
        }
        _ = c.pthread_cond_signal(&lane.cond);
    }

    /// Removes a queued job before it starts. Returns false if it is
    /// running or already finished, in which case `complete` still runs.
    pub fn cancel(pool: *Pool, job: *Job) bool {
        pool.lock();
        defer pool.unlock();
        if (job.state != .queued) return false;
        pool.removeLocked(job);
        return true;
    }

    /// Changes a job's priority; a queued job moves to its new place.
    pub fn setPriority(pool: *Pool, job: *Job, priority: i64) void {
        pool.lock();
        defer pool.unlock();
        if (job.state == .queued) {
            const lane = pool.laneOf(job);
            _ = lane.remove(job);
            job.priority = priority;
            lane.insert(job);
        } else job.priority = priority;
    }

    /// Runs `func(ctx, worker)` on the calling thread (worker 0) and on up
    /// to `max_threads` pool threads (workers 1..), concurrently, and
    /// returns when every call has returned. Pool threads that are busy
    /// with other jobs join late or not at all, so `func` must pull work
    /// from shared state rather than assume a worker count. Allocates only
    /// the first time (helper slots).
    pub fn forkJoin(pool: *Pool, ctx: *anyopaque, func: *const fn (ctx: *anyopaque, worker: u32) void) void {
        _ = c.pthread_mutex_lock(&pool.fork_mutex);
        defer _ = c.pthread_mutex_unlock(&pool.fork_mutex);
        if (pool.helpers.len == 0) {
            pool.helpers = pool.allocator.alloc(Helper, pool.max_threads) catch &.{};
            for (pool.helpers, 0..) |*h, i| h.* = .{ .pool = pool, .worker = @intCast(i + 1) };
        }

        pool.lock();
        var submitted: u32 = 0;
        for (pool.helpers) |*h| {
            h.ctx = ctx;
            h.func = func;
            h.job.priority = std.math.maxInt(i64);
            pool.submitLocked(&h.job) catch break;
            submitted += 1;
        }
        pool.helpers_pending = submitted;
        pool.unlock();

        func(ctx, 0);

        // Helpers that have not started are not needed any more.
        pool.lock();
        for (pool.helpers[0..submitted]) |*h| {
            if (h.job.state == .queued) {
                pool.removeLocked(&h.job);
                pool.helpers_pending -= 1;
            }
        }
        while (pool.helpers_pending != 0) _ = c.pthread_cond_wait(&pool.fork_done, &pool.mutex);
        pool.unlock();
    }

    /// The fork-join mode as an `Executor`.
    pub fn executor(pool: *Pool) Executor {
        return .{ .ctx = pool, .workers = pool.max_threads + 1, .run = runExecutor };
    }

    fn runExecutor(ctx: ?*anyopaque, task: Executor.Task) void {
        const pool: *Pool = @ptrCast(@alignCast(ctx.?));
        pool.forkJoin(task.ctx, task.func);
    }

    fn removeLocked(pool: *Pool, job: *Job) void {
        if (pool.laneOf(job).remove(job)) job.state = .idle;
    }

    fn spawnLocked(pool: *Pool, class: Job.Class) SubmitError!void {
        try pool.threads.ensureUnusedCapacity(pool.allocator, 1);
        const t = std.Thread.spawn(.{}, worker, .{ pool, &pool.lanes[@intFromEnum(class)] }) catch return error.SystemResources;
        pool.threads.appendAssumeCapacity(t);
        pool.lanes[@intFromEnum(class)].threads += 1;
    }

    fn worker(pool: *Pool, lane: *Lane) void {
        pool.lock();
        while (true) {
            while (lane.head == null and !pool.stopping) {
                lane.idle += 1;
                _ = c.pthread_cond_wait(&lane.cond, &pool.mutex);
                lane.idle -= 1;
            }
            if (pool.stopping) break;
            const job = lane.head.?;
            lane.head = job.next;
            if (lane.head == null) lane.tail = null;
            lane.queued -= 1;
            job.state = .running;
            pool.unlock();

            job.run(job);
            // `complete` may free or resubmit the job; mark it idle first.
            pool.lock();
            job.state = .idle;
            pool.unlock();
            job.complete(job);

            pool.lock();
        }
        pool.unlock();
    }

    fn lock(pool: *Pool) void {
        _ = c.pthread_mutex_lock(&pool.mutex);
    }

    fn unlock(pool: *Pool) void {
        _ = c.pthread_mutex_unlock(&pool.mutex);
    }

    const Helper = struct {
        job: Job = .{ .run = helperRun, .complete = helperComplete },
        pool: *Pool,
        worker: u32,
        ctx: *anyopaque = undefined,
        func: *const fn (*anyopaque, u32) void = undefined,

        fn helperRun(job: *Job) void {
            const h: *Helper = @fieldParentPtr("job", job);
            h.func(h.ctx, h.worker);
        }

        fn helperComplete(job: *Job) void {
            const h: *Helper = @fieldParentPtr("job", job);
            const pool = h.pool;
            pool.lock();
            pool.helpers_pending -= 1;
            if (pool.helpers_pending == 0) _ = c.pthread_cond_signal(&pool.fork_done);
            pool.unlock();
        }
    };
};

pub const Job = struct {
    /// Runs on a worker thread.
    run: *const fn (*Job) void,
    /// Runs on the same worker after `run`. The job may be freed or
    /// resubmitted from here.
    complete: *const fn (*Job) void,
    /// Runs instead of `run` and `complete` when `Pool.deinit` drops the
    /// job while queued. Must only release resources.
    cancel: ?*const fn (*Job) void = null,
    /// Which threads run it. Set before submitting.
    class: Class = .compute,
    /// Compute jobs: higher runs first. Change it while queued with
    /// `Pool.setPriority`.
    priority: i64 = 0,
    state: State = .idle,
    next: ?*Job = null,

    pub const State = enum { idle, queued, running };

    pub const Class = enum(u1) {
        /// CPU work: decoding, tiles, the default.
        compute,
        /// Work that waits: file I/O, copying, network file systems.
        blocking,
    };
};

/// Run one function on N workers and wait: the contract renderers use, so
/// they work with the application pool or without one.
pub const Executor = struct {
    ctx: ?*anyopaque,
    /// Most workers that may run a job concurrently, including the caller.
    workers: u32,
    /// Runs task.func on worker indices in [0, workers), concurrently, and
    /// returns when all calls returned. Some indices may not run at all.
    run: *const fn (ctx: ?*anyopaque, task: Task) void,

    pub const Task = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, worker: u32) void,
    };

    /// Runs everything on the calling thread.
    pub const serial: Executor = .{ .ctx = null, .workers = 1, .run = runSerial };

    fn runSerial(_: ?*anyopaque, task: Executor.Task) void {
        task.func(task.ctx, 0);
    }
};

/// Hands out indices [0, count) to workers inside a fork-join.
pub const Counter = struct {
    next: std.atomic.Value(u32) = .init(0),
    count: u32,

    pub fn take(self: *Counter) ?u32 {
        const i = self.next.fetchAdd(1, .monotonic);
        return if (i < self.count) i else null;
    }
};

/// The number of online CPUs, a reasonable `max_threads`.
pub fn defaultThreadCount() u32 {
    return @intCast(std.math.clamp(std.Thread.getCpuCount() catch 1, 1, 64));
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

test "async jobs run and complete on workers" {
    var pool = Pool.init(testing.allocator, 3);
    defer pool.deinit();
    const Work = struct {
        job: Job = .{ .run = run, .complete = complete },
        input: u64,
        output: u64 = 0,
        done: std.atomic.Value(bool) = .init(false),
        fn run(job: *Job) void {
            const w: *@This() = @fieldParentPtr("job", job);
            w.output = w.input * w.input;
        }
        fn complete(job: *Job) void {
            const w: *@This() = @fieldParentPtr("job", job);
            w.done.store(true, .release);
        }
    };
    var work: [16]Work = undefined;
    for (&work, 0..) |*w, i| {
        w.* = .{ .input = i + 1 };
        try pool.submit(&w.job);
    }
    for (&work, 0..) |*w, i| {
        while (!w.done.load(.acquire)) std.atomic.spinLoopHint();
        try testing.expectEqual((i + 1) * (i + 1), w.output);
    }
    try testing.expect(pool.threads.items.len <= 3);
}

test "fork-join covers every item once, with the caller as worker 0" {
    var pool = Pool.init(testing.allocator, 3);
    defer pool.deinit();
    const ex = pool.executor();
    try testing.expectEqual(@as(u32, 4), ex.workers);
    const Ctx = struct {
        counter: Counter,
        hits: [1000]std.atomic.Value(u32),
        caller: std.Thread.Id,
        caller_ok: std.atomic.Value(bool) = .init(true),

        fn func(p: *anyopaque, w: u32) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            if ((w == 0) != (std.Thread.getCurrentId() == self.caller)) self.caller_ok.store(false, .monotonic);
            while (self.counter.take()) |i| _ = self.hits[i].fetchAdd(1, .monotonic);
        }
    };
    for (0..50) |_| {
        var ctx: Ctx = .{ .counter = .{ .count = 1000 }, .hits = @splat(.init(0)), .caller = std.Thread.getCurrentId() };
        ex.run(ex.ctx, .{ .ctx = &ctx, .func = Ctx.func });
        for (&ctx.hits) |*h| try testing.expectEqual(@as(u32, 1), h.load(.monotonic));
        try testing.expect(ctx.caller_ok.load(.monotonic));
    }
}

test "fork-join completes while async jobs occupy every thread" {
    var pool = Pool.init(testing.allocator, 2);
    defer pool.deinit();
    const Busy = struct {
        job: Job = .{ .run = run, .complete = complete },
        open: *std.atomic.Value(bool),
        fn run(job: *Job) void {
            const b: *@This() = @fieldParentPtr("job", job);
            while (!b.open.load(.acquire)) std.atomic.spinLoopHint();
        }
        fn complete(_: *Job) void {}
    };
    var open: std.atomic.Value(bool) = .init(false);
    var busy = [_]Busy{ .{ .open = &open }, .{ .open = &open } };
    for (&busy) |*b| try pool.submit(&b.job);
    // Both threads are blocked; the caller still does all the work.
    const Ctx = struct {
        counter: Counter = .{ .count = 100 },
        sum: std.atomic.Value(u32) = .init(0),
        fn func(p: *anyopaque, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            while (self.counter.take()) |_| _ = self.sum.fetchAdd(1, .monotonic);
        }
    };
    var ctx: Ctx = .{};
    pool.forkJoin(&ctx, Ctx.func);
    try testing.expectEqual(@as(u32, 100), ctx.sum.load(.monotonic));
    open.store(true, .release);
}

test "cancel and deinit drop queued jobs" {
    var pool = Pool.init(testing.allocator, 1);
    const Gate = struct {
        job: Job = .{ .run = run, .complete = complete, .cancel = cancelled },
        open: std.atomic.Value(bool) = .init(false),
        started: std.atomic.Value(bool) = .init(false),
        outcome: std.atomic.Value(u8) = .init(0), // 1 complete, 2 cancelled
        fn run(job: *Job) void {
            const g: *@This() = @fieldParentPtr("job", job);
            g.started.store(true, .release);
            while (!g.open.load(.acquire)) std.atomic.spinLoopHint();
        }
        fn complete(job: *Job) void {
            const g: *@This() = @fieldParentPtr("job", job);
            g.outcome.store(1, .release);
        }
        fn cancelled(job: *Job) void {
            const g: *@This() = @fieldParentPtr("job", job);
            g.outcome.store(2, .release);
        }
    };
    var first: Gate = .{};
    var second: Gate = .{};
    var third: Gate = .{};
    try pool.submit(&first.job);
    try pool.submit(&second.job);
    try pool.submit(&third.job);
    while (!first.started.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expect(!pool.cancel(&first.job));
    try testing.expect(pool.cancel(&second.job));
    try testing.expectEqual(Job.State.idle, second.job.state);
    first.open.store(true, .release);
    while (first.outcome.load(.acquire) == 0) std.atomic.spinLoopHint();
    // Deinit may race the worker for the third job: it either ran or was
    // cancelled, never neither.
    third.open.store(true, .release);
    pool.deinit();
    try testing.expectEqual(@as(u8, 0), second.outcome.load(.acquire));
    try testing.expect(third.outcome.load(.acquire) != 0);
}

test "compute jobs run by priority, in order within one" {
    var pool = Pool.init(testing.allocator, 1);
    defer pool.deinit();
    const Rec = struct {
        job: Job = .{ .run = run, .complete = complete },
        open: *std.atomic.Value(bool),
        order: *[8]u8,
        n: *std.atomic.Value(u32),
        tag: u8,
        done: std.atomic.Value(bool) = .init(false),
        fn run(job: *Job) void {
            const r: *@This() = @fieldParentPtr("job", job);
            while (!r.open.load(.acquire)) std.atomic.spinLoopHint();
            r.order[r.n.fetchAdd(1, .monotonic)] = r.tag;
        }
        fn complete(job: *Job) void {
            const r: *@This() = @fieldParentPtr("job", job);
            r.done.store(true, .release);
        }
    };
    var open: std.atomic.Value(bool) = .init(false);
    var order: [8]u8 = undefined;
    var n: std.atomic.Value(u32) = .init(0);
    // The first job holds the one worker while the rest queue.
    var gate: Rec = .{ .open = &open, .order = &order, .n = &n, .tag = 'g' };
    try pool.submit(&gate.job);
    while (pool.lanes[0].queued != 0) std.atomic.spinLoopHint();
    var jobs = [_]Rec{
        .{ .open = &open, .order = &order, .n = &n, .tag = 'a' },
        .{ .open = &open, .order = &order, .n = &n, .tag = 'b' },
        .{ .open = &open, .order = &order, .n = &n, .tag = 'c' },
        .{ .open = &open, .order = &order, .n = &n, .tag = 'd' },
        .{ .open = &open, .order = &order, .n = &n, .tag = 'e' },
    };
    const priorities = [_]i64{ 0, 5, 0, 9, -1 };
    for (&jobs, priorities) |*j, p| {
        j.job.priority = p;
        try pool.submit(&j.job);
    }
    // Raised while queued: 'e' goes before 'b'.
    pool.setPriority(&jobs[4].job, 7);
    open.store(true, .release);
    for (&jobs) |*j| while (!j.done.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expectEqualStrings("gdebac", order[0..6]);
}

test "blocking jobs never take the compute workers" {
    var pool = Pool.init(testing.allocator, 1);
    pool.max_blocking = 2;
    defer pool.deinit();
    const Gate = struct {
        job: Job = .{ .run = run, .complete = complete },
        open: *std.atomic.Value(bool),
        done: std.atomic.Value(bool) = .init(false),
        fn run(job: *Job) void {
            const g: *@This() = @fieldParentPtr("job", job);
            while (!g.open.load(.acquire)) std.atomic.spinLoopHint();
        }
        fn complete(job: *Job) void {
            const g: *@This() = @fieldParentPtr("job", job);
            g.done.store(true, .release);
        }
    };
    var open: std.atomic.Value(bool) = .init(false);
    var always: std.atomic.Value(bool) = .init(true);
    // Three copies waiting on a slow disk: two run, one queues.
    var slow = [_]Gate{ .{ .open = &open }, .{ .open = &open }, .{ .open = &open } };
    for (&slow) |*g| {
        g.job.class = .blocking;
        try pool.submit(&g.job);
    }
    // Decoding still gets its worker.
    var decode: Gate = .{ .open = &always };
    try pool.submit(&decode.job);
    while (!decode.done.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expectEqual(@as(u32, 2), pool.lanes[1].threads);
    try testing.expectEqual(@as(u32, 1), pool.lanes[0].threads);
    open.store(true, .release);
    for (&slow) |*g| while (!g.done.load(.acquire)) std.atomic.spinLoopHint();
}
