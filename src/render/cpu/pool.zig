//! Parallel execution for tiles.
//!
//! The renderer needs one primitive: run a function on N workers at once
//! and wait for all of them. `Executor` is that contract, so the
//! application's worker pool (owned by the loop) can drive rendering
//! without render_cpu importing it. Work distribution happens inside the
//! job (workers pull tile indices from an atomic counter), so the executor
//! never allocates or queues per item. `ThreadPool` is a standalone
//! implementation for tests, benchmarks, and embedders without a pool.

const std = @import("std");
const c = std.c;

pub const Job = struct {
    ctx: *anyopaque,
    /// Called once per worker, concurrently, with worker in [0, workers).
    func: *const fn (ctx: *anyopaque, worker: u32) void,
};

pub const Executor = struct {
    ctx: ?*anyopaque,
    /// Workers that run each job concurrently, including the caller.
    workers: u32,
    /// Runs job.func on every worker index and returns when all returned.
    /// Must not allocate. Called from one thread at a time per executor.
    run: *const fn (ctx: ?*anyopaque, job: Job) void,

    /// Runs everything on the calling thread.
    pub const serial: Executor = .{ .ctx = null, .workers = 1, .run = runSerial };

    fn runSerial(_: ?*anyopaque, job: Job) void {
        job.func(job.ctx, 0);
    }
};

/// Persistent worker threads. The caller of `run` acts as worker 0.
pub const ThreadPool = struct {
    gpa: std.mem.Allocator,
    threads: []std.Thread,
    mutex: c.pthread_mutex_t = .{},
    start_cond: c.pthread_cond_t = .{},
    done_cond: c.pthread_cond_t = .{},
    generation: u64 = 0,
    pending: u32 = 0,
    job: ?Job = null,
    shutdown: bool = false,

    /// Starts `workers - 1` threads (workers >= 1). Zero means one per CPU.
    pub fn create(gpa: std.mem.Allocator, workers: u32) !*ThreadPool {
        const n: u32 = if (workers == 0) @intCast(@max(1, std.Thread.getCpuCount() catch 1)) else workers;
        const pool = try gpa.create(ThreadPool);
        errdefer gpa.destroy(pool);
        pool.* = .{ .gpa = gpa, .threads = try gpa.alloc(std.Thread, n - 1) };
        errdefer gpa.free(pool.threads);
        var started: usize = 0;
        errdefer {
            pool.stop();
            for (pool.threads[0..started]) |t| t.join();
        }
        for (pool.threads, 0..) |*t, i| {
            t.* = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, workerMain, .{ pool, @as(u32, @intCast(i + 1)) });
            started += 1;
        }
        return pool;
    }

    pub fn destroy(pool: *ThreadPool) void {
        pool.stop();
        for (pool.threads) |t| t.join();
        const gpa = pool.gpa;
        gpa.free(pool.threads);
        gpa.destroy(pool);
    }

    pub fn executor(pool: *ThreadPool) Executor {
        return .{ .ctx = pool, .workers = @intCast(pool.threads.len + 1), .run = runPool };
    }

    fn stop(pool: *ThreadPool) void {
        _ = c.pthread_mutex_lock(&pool.mutex);
        pool.shutdown = true;
        _ = c.pthread_cond_broadcast(&pool.start_cond);
        _ = c.pthread_mutex_unlock(&pool.mutex);
    }

    fn runPool(ctx: ?*anyopaque, job: Job) void {
        const pool: *ThreadPool = @ptrCast(@alignCast(ctx.?));
        if (pool.threads.len == 0) return job.func(job.ctx, 0);
        _ = c.pthread_mutex_lock(&pool.mutex);
        pool.job = job;
        pool.pending = @intCast(pool.threads.len);
        pool.generation +%= 1;
        _ = c.pthread_cond_broadcast(&pool.start_cond);
        _ = c.pthread_mutex_unlock(&pool.mutex);

        job.func(job.ctx, 0);

        _ = c.pthread_mutex_lock(&pool.mutex);
        while (pool.pending != 0) _ = c.pthread_cond_wait(&pool.done_cond, &pool.mutex);
        pool.job = null;
        _ = c.pthread_mutex_unlock(&pool.mutex);
    }

    fn workerMain(pool: *ThreadPool, index: u32) void {
        var seen: u64 = 0;
        _ = c.pthread_mutex_lock(&pool.mutex);
        while (true) {
            while (!pool.shutdown and pool.generation == seen) _ = c.pthread_cond_wait(&pool.start_cond, &pool.mutex);
            if (pool.shutdown) break;
            seen = pool.generation;
            const job = pool.job.?;
            _ = c.pthread_mutex_unlock(&pool.mutex);
            job.func(job.ctx, index);
            _ = c.pthread_mutex_lock(&pool.mutex);
            pool.pending -= 1;
            if (pool.pending == 0) _ = c.pthread_cond_signal(&pool.done_cond);
        }
        _ = c.pthread_mutex_unlock(&pool.mutex);
    }
};

/// Hands out indices [0, count) to workers; use inside a Job.
pub const Counter = struct {
    next: std.atomic.Value(u32) = .init(0),
    count: u32,

    pub fn take(self: *Counter) ?u32 {
        const i = self.next.fetchAdd(1, .monotonic);
        return if (i < self.count) i else null;
    }
};

test "thread pool runs every worker and every item once" {
    const pool = try ThreadPool.create(std.testing.allocator, 4);
    defer pool.destroy();
    const ex = pool.executor();
    try std.testing.expectEqual(@as(u32, 4), ex.workers);

    const Ctx = struct {
        counter: Counter,
        hits: [1000]std.atomic.Value(u32),
        workers_seen: std.atomic.Value(u32) = .init(0),

        fn func(p: *anyopaque, worker: u32) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            _ = self.workers_seen.fetchOr(@as(u32, 1) << @intCast(worker), .monotonic);
            while (self.counter.take()) |i| _ = self.hits[i].fetchAdd(1, .monotonic);
        }
    };
    for (0..20) |_| {
        var ctx: Ctx = .{ .counter = .{ .count = 1000 }, .hits = @splat(.init(0)) };
        ex.run(ex.ctx, .{ .ctx = &ctx, .func = Ctx.func });
        for (&ctx.hits) |*h| try std.testing.expectEqual(@as(u32, 1), h.load(.monotonic));
        try std.testing.expectEqual(@as(u32, 0b1111), ctx.workers_seen.load(.monotonic));
    }
}
