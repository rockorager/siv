//! Event loop (D5, D6): one epoll loop per application with eventfd wakeups,
//! timerfd deadlines from a userspace timer heap, and safe-point callback
//! dispatch. Embeddable through siv_app_fd() and siv_app_dispatch().
//!
//! One call to `dispatch` runs these phases in order:
//!
//!   poll     epoll_wait on sources, the wakeup eventfd, and the timerfd
//!   io       source handlers for ready fds; they only read, update state,
//!            and schedule tasks (they never call application code)
//!   timers   callbacks of expired timers
//!   dispatch closures posted from other threads (`post`), worker-pool
//!            completions, then tasks scheduled for the dispatch phase
//!   frame    tasks scheduled for the frame phase (layout, paint, present)
//!   prepare  hooks that run before the loop sleeps (flushing Wayland)
//!
//! Timers, tasks, and hooks are the safe points where application code
//! runs. Work scheduled for a phase that already ran in this iteration runs
//! in the next one; the loop writes its eventfd so that the next poll returns
//! immediately, which keeps `fd()` readable for embedders while work is
//! pending. An idle loop with no armed timers blocks indefinitely.
//!
//! Every function is for the loop thread only, except `post`, `postRemote`,
//! and `wake`, which are safe from any thread.
//!
//! Imports: none.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const TimerHeap = @import("TimerHeap.zig");
pub const Timer = TimerHeap.Timer;
pub const Pool = @import("Pool.zig");

pub const Loop = struct {
    /// Must be thread-safe if `post` is called from other threads.
    allocator: Allocator,
    epfd: i32,
    wake_fd: i32,
    timer_fd: i32,

    timers: TimerHeap = .{},
    /// Deadline the timerfd is armed for, or null when disarmed.
    armed_deadline: ?u64 = null,

    queues: [phase_count]Queue = @splat(.{}),
    hooks: ?*Hook = null,
    remote_head: std.atomic.Value(?*Remote) = .init(null),
    wake_pending: std.atomic.Value(bool) = .init(false),

    /// Current position in `dispatch`, used to avoid redundant wakeups.
    stage: Stage = .idle,
    /// Ready events of the current io phase. Removing a source clears its
    /// entries so that a handler never runs for a source freed earlier in
    /// the same phase.
    events: [max_events]linux.epoll_event = undefined,
    ready: usize = 0,
    stopped: bool = false,

    const max_events = 64;
    const wake_tag: usize = 1;
    const timer_tag: usize = 2;

    pub const Error = error{ SystemResources, Unexpected };

    pub fn init(allocator: Allocator) Error!Loop {
        const epfd = try fdResult(linux.epoll_create1(linux.EPOLL.CLOEXEC));
        errdefer closeFd(epfd);
        const wake_fd = try fdResult(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        errdefer closeFd(wake_fd);
        const timer_fd = try fdResult(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true }));
        errdefer closeFd(timer_fd);
        try epollCtl(epfd, linux.EPOLL.CTL_ADD, wake_fd, linux.EPOLL.IN, wake_tag);
        try epollCtl(epfd, linux.EPOLL.CTL_ADD, timer_fd, linux.EPOLL.IN, timer_tag);
        return .{ .allocator = allocator, .epfd = epfd, .wake_fd = wake_fd, .timer_fd = timer_fd };
    }

    /// Closes the loop. Work posted but not yet dispatched never runs; its
    /// `cancel` function, if any, releases what it owns. Worker pools must be
    /// deinitialized first.
    pub fn deinit(loop: *Loop) void {
        var fifo = loop.takeRemote();
        while (fifo) |r| {
            fifo = r.next;
            if (r.cancel) |cancel| cancel(r);
        }
        loop.timers.deinit(loop.allocator);
        closeFd(loop.timer_fd);
        closeFd(loop.wake_fd);
        closeFd(loop.epfd);
        loop.* = undefined;
    }

    /// The epoll fd. It is readable whenever `dispatch(0)` has work to do.
    pub fn fd(loop: *const Loop) i32 {
        return loop.epfd;
    }

    /// Runs one iteration. `timeout_ms` bounds the poll: -1 blocks until
    /// work arrives, 0 never blocks.
    pub fn dispatch(loop: *Loop, timeout_ms: i32) Error!void {
        std.debug.assert(loop.stage == .idle); // no re-entrant dispatch
        loop.stage = .poll;
        defer loop.stage = .idle;

        const rc = linux.epoll_wait(loop.epfd, &loop.events, max_events, timeout_ms);
        loop.ready = switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .INTR => 0,
            else => |e| return unexpected(e),
        };

        loop.stage = .io;
        for (0..loop.ready) |i| {
            const ev = loop.events[i];
            switch (ev.data.ptr) {
                0 => {}, // source removed earlier in this phase
                wake_tag => {
                    loop.wake_pending.store(false, .seq_cst);
                    drainFd(loop.wake_fd);
                },
                timer_tag => drainFd(loop.timer_fd),
                else => |ptr| {
                    const source: *Source = @ptrFromInt(ptr);
                    source.func(source, ev.events);
                },
            }
        }
        loop.ready = 0;

        loop.stage = .timers;
        loop.runTimers();

        loop.stage = .dispatch;
        loop.runRemote();
        loop.runQueue(.dispatch);

        loop.stage = .frame;
        loop.runQueue(.frame);

        loop.stage = .prepare;
        var hook = loop.hooks;
        while (hook) |h| {
            hook = h.next; // a hook may remove itself
            h.func(h);
        }
        loop.armTimerFd();
    }

    /// Dispatches until `stop` is called.
    pub fn run(loop: *Loop) Error!void {
        loop.stopped = false;
        while (!loop.stopped) try loop.dispatch(-1);
    }

    /// Makes `run` return after the current iteration.
    pub fn stop(loop: *Loop) void {
        loop.stopped = true;
        loop.wake();
    }

    /// Whether `dispatch` is running (any phase). Work queued outside an
    /// iteration needs `wake` (or a scheduled task) to be noticed before
    /// the loop sleeps; work queued inside one can rely on the prepare
    /// hooks that end it.
    pub fn isDispatching(loop: *const Loop) bool {
        return loop.stage != .idle;
    }

    /// CLOCK_MONOTONIC in nanoseconds, the clock of every loop deadline.
    pub fn now() u64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    /// Makes the next poll return immediately. Safe from any thread.
    pub fn wake(loop: *Loop) void {
        if (loop.wake_pending.swap(true, .seq_cst)) return;
        const one: u64 = 1;
        _ = linux.write(loop.wake_fd, std.mem.asBytes(&one), 8);
    }

    // Sources --------------------------------------------------------------

    /// A file descriptor watched by the loop. `func` runs in the io phase
    /// and must not call application code; it reads, updates state, and
    /// schedules tasks.
    pub const Source = struct {
        fd: i32,
        /// EPOLL.IN, EPOLL.OUT, ...
        events: u32,
        func: *const fn (source: *Source, events: u32) void,
    };

    pub fn addSource(loop: *Loop, source: *Source) Error!void {
        try epollCtl(loop.epfd, linux.EPOLL.CTL_ADD, source.fd, source.events, @intFromPtr(source));
    }

    pub fn modifySource(loop: *Loop, source: *Source, events: u32) Error!void {
        if (source.events == events) return;
        try epollCtl(loop.epfd, linux.EPOLL.CTL_MOD, source.fd, events, @intFromPtr(source));
        source.events = events;
    }

    /// Stops watching the source. Its memory may be freed right after,
    /// even from inside an io handler.
    pub fn removeSource(loop: *Loop, source: *Source) void {
        _ = linux.epoll_ctl(loop.epfd, linux.EPOLL.CTL_DEL, source.fd, null);
        for (loop.events[0..loop.ready]) |*ev| {
            if (ev.data.ptr == @intFromPtr(source)) ev.data.ptr = 0;
        }
    }

    // Timers ---------------------------------------------------------------

    /// Arms `timer` for the absolute CLOCK_MONOTONIC `deadline`, repeating
    /// every `interval` nanoseconds if nonzero. Rearms an armed timer.
    pub fn startTimer(loop: *Loop, timer: *Timer, deadline: u64, interval: u64) Allocator.Error!void {
        loop.timers.remove(timer);
        timer.deadline = deadline;
        timer.interval = interval;
        try loop.timers.insert(loop.allocator, timer);
        if (loop.stage != .timers) loop.armTimerFd();
    }

    pub fn cancelTimer(loop: *Loop, timer: *Timer) void {
        if (!timer.armed()) return;
        loop.timers.remove(timer);
        if (loop.stage != .timers) loop.armTimerFd();
    }

    fn runTimers(loop: *Loop) void {
        const t_now = now();
        while (loop.timers.peek()) |t| {
            if (t.deadline > t_now) break;
            _ = loop.timers.pop();
            if (t.interval != 0) {
                // Skip missed periods rather than firing a burst.
                const missed = (t_now - t.deadline) / t.interval;
                t.deadline += (missed + 1) * t.interval;
                loop.timers.insertAssumeCapacity(t);
            }
            t.func(t);
        }
    }

    fn armTimerFd(loop: *Loop) void {
        const deadline: ?u64 = if (loop.timers.peek()) |t| t.deadline else null;
        if (deadline == loop.armed_deadline) return;
        // An absolute time of 0 would disarm, so a past deadline uses 1 ns.
        const ns = if (deadline) |d| @max(d, 1) else 0;
        const spec: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) },
        };
        _ = linux.timerfd_settime(loop.timer_fd, .{ .ABSTIME = true }, &spec, null);
        loop.armed_deadline = deadline;
    }

    // Tasks ----------------------------------------------------------------

    pub const Phase = enum { dispatch, frame };
    const phase_count = std.meta.fieldNames(Phase).len;

    const Stage = enum { idle, poll, io, timers, dispatch, frame, prepare };

    fn stageOf(phase: Phase) Stage {
        return switch (phase) {
            .dispatch => .dispatch,
            .frame => .frame,
        };
    }

    /// One-shot work for a safe-point phase, embedded in its owner.
    pub const Task = struct {
        func: *const fn (*Task) void,
        prev: ?*Task = null,
        next: ?*Task = null,
        queue: ?*Queue = null,

        pub fn scheduled(t: *const Task) bool {
            return t.queue != null;
        }
    };

    const Queue = struct {
        head: ?*Task = null,
        tail: ?*Task = null,

        fn push(q: *Queue, t: *Task) void {
            t.prev = q.tail;
            t.next = null;
            if (q.tail) |tail| tail.next = t else q.head = t;
            q.tail = t;
            t.queue = q;
        }

        fn unlink(q: *Queue, t: *Task) void {
            if (t.prev) |p| p.next = t.next else q.head = t.next;
            if (t.next) |n| n.prev = t.prev else q.tail = t.prev;
            t.prev = null;
            t.next = null;
            t.queue = null;
        }
    };

    /// Runs `task` once in `phase`. Scheduling an already scheduled task
    /// does nothing.
    pub fn schedule(loop: *Loop, task: *Task, phase: Phase) void {
        if (task.queue != null) return;
        loop.queues[@intFromEnum(phase)].push(task);
        // A phase still ahead in the current iteration picks it up;
        // otherwise make the next poll return immediately.
        const ahead = @intFromEnum(loop.stage) < @intFromEnum(stageOf(phase)) and loop.stage != .idle;
        if (!ahead) loop.wake();
    }

    pub fn unschedule(_: *Loop, task: *Task) void {
        if (task.queue) |q| q.unlink(task);
    }

    fn runQueue(loop: *Loop, phase: Phase) void {
        // Tasks scheduled while this phase runs go to the next iteration.
        var batch = loop.queues[@intFromEnum(phase)];
        loop.queues[@intFromEnum(phase)] = .{};
        var it = batch.head;
        while (it) |t| : (it = t.next) t.queue = &batch;
        while (batch.head) |t| {
            batch.unlink(t);
            t.func(t);
        }
    }

    // Hooks ----------------------------------------------------------------

    /// Runs at the end of every iteration, before the loop sleeps.
    pub const Hook = struct {
        func: *const fn (*Hook) void,
        next: ?*Hook = null,
    };

    pub fn addHook(loop: *Loop, hook: *Hook) void {
        hook.next = loop.hooks;
        loop.hooks = hook;
    }

    pub fn removeHook(loop: *Loop, hook: *Hook) void {
        var link = &loop.hooks;
        while (link.*) |h| : (link = &h.next) {
            if (h == hook) {
                link.* = h.next;
                return;
            }
        }
    }

    // Cross-thread work ----------------------------------------------------

    /// Work handed to the loop from any thread, embedded in its owner. `func`
    /// runs in the dispatch phase, in posting order. If the loop is
    /// deinitialized first, `cancel` runs instead so that the owner can
    /// release resources; application code must not run from it.
    pub const Remote = struct {
        func: *const fn (*Remote) void,
        cancel: ?*const fn (*Remote) void = null,
        next: ?*Remote = null,
    };

    /// Queues `remote` without allocating. Safe from any thread.
    pub fn postRemote(loop: *Loop, remote: *Remote) void {
        var head = loop.remote_head.load(.monotonic);
        while (true) {
            remote.next = head;
            head = loop.remote_head.cmpxchgWeak(head, remote, .release, .monotonic) orelse break;
        }
        // The first item after a drain wakes the loop; later ones ride along.
        if (head == null) loop.wake();
    }

    const Posted = struct {
        remote: Remote = .{ .func = invoke, .cancel = drop },
        func: *const fn (?*anyopaque) void,
        destroy: ?*const fn (?*anyopaque) void,
        ctx: ?*anyopaque,
        allocator: Allocator,

        fn invoke(r: *Remote) void {
            const p: *Posted = @fieldParentPtr("remote", r);
            const func, const ctx, const allocator = .{ p.func, p.ctx, p.allocator };
            allocator.destroy(p);
            func(ctx);
        }

        fn drop(r: *Remote) void {
            const p: *Posted = @fieldParentPtr("remote", r);
            const destroy, const ctx, const allocator = .{ p.destroy, p.ctx, p.allocator };
            allocator.destroy(p);
            if (destroy) |d| d(ctx);
        }
    };

    /// Runs `func(ctx)` on the loop thread in the dispatch phase. If the loop
    /// is deinitialized before that, `destroy(ctx)` runs instead. Safe from
    /// any thread; the loop's allocator must then be thread-safe.
    pub fn post(
        loop: *Loop,
        func: *const fn (?*anyopaque) void,
        destroy: ?*const fn (?*anyopaque) void,
        ctx: ?*anyopaque,
    ) Allocator.Error!void {
        const p = try loop.allocator.create(Posted);
        p.* = .{ .func = func, .destroy = destroy, .ctx = ctx, .allocator = loop.allocator };
        loop.postRemote(&p.remote);
    }

    /// Takes every posted item, oldest first.
    fn takeRemote(loop: *Loop) ?*Remote {
        var list = loop.remote_head.swap(null, .acquire);
        // The stack is newest first; reverse it into posting order.
        var fifo: ?*Remote = null;
        while (list) |r| {
            list = r.next;
            r.next = fifo;
            fifo = r;
        }
        return fifo;
    }

    fn runRemote(loop: *Loop) void {
        var fifo = loop.takeRemote();
        while (fifo) |r| {
            fifo = r.next;
            r.func(r);
        }
    }
};

fn fdResult(rc: usize) Loop.Error!i32 {
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE, .NFILE, .NOMEM, .NODEV => error.SystemResources,
        else => |e| unexpected(e),
    };
}

fn epollCtl(epfd: i32, op: u32, fd: i32, events: u32, data: usize) Loop.Error!void {
    var ev: linux.epoll_event = .{ .events = events, .data = .{ .ptr = data } };
    switch (linux.errno(linux.epoll_ctl(epfd, op, fd, &ev))) {
        .SUCCESS => {},
        .NOMEM, .NOSPC => return error.SystemResources,
        else => |e| return unexpected(e),
    }
}

fn drainFd(fd: i32) void {
    var buf: u64 = undefined;
    _ = linux.read(fd, std.mem.asBytes(&buf), 8);
}

fn closeFd(fd: i32) void {
    _ = linux.close(fd);
}

fn unexpected(e: linux.E) error{Unexpected} {
    std.log.scoped(.loop).err("unexpected errno {t}", .{e});
    return error.Unexpected;
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

/// Records the order in which safe-point callbacks run.
const Recorder = struct {
    log: [32]u8 = undefined,
    len: usize = 0,

    fn add(r: *Recorder, c: u8) void {
        r.log[r.len] = c;
        r.len += 1;
    }

    fn get(r: *const Recorder) []const u8 {
        return r.log[0..r.len];
    }
};

test "phases run in order and io handlers only schedule work" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();

    const Ctx = struct {
        rec: Recorder = .{},
        loop: *Loop,
        pipe: [2]i32 = undefined,
        source: Loop.Source = undefined,
        dispatch_task: Loop.Task = .{ .func = onDispatch },
        frame_task: Loop.Task = .{ .func = onFrame },
        late_task: Loop.Task = .{ .func = onLate },
        timer: Timer = .{ .func = onTimer },
        hook: Loop.Hook = .{ .func = onHook },

        fn onReadable(s: *Loop.Source, events: u32) void {
            const c: *@This() = @fieldParentPtr("source", s);
            testing.expect(events & linux.EPOLL.IN != 0) catch unreachable;
            drainFd(s.fd);
            c.rec.add('i');
            // Scheduled from io: runs later in this same iteration.
            c.loop.schedule(&c.frame_task, .frame);
            c.loop.schedule(&c.dispatch_task, .dispatch);
        }
        fn onTimer(t: *Timer) void {
            const c: *@This() = @fieldParentPtr("timer", t);
            c.rec.add('t');
        }
        fn onDispatch(t: *Loop.Task) void {
            const c: *@This() = @fieldParentPtr("dispatch_task", t);
            c.rec.add('d');
        }
        fn onFrame(t: *Loop.Task) void {
            const c: *@This() = @fieldParentPtr("frame_task", t);
            c.rec.add('f');
            // The dispatch phase already ran: this runs next iteration.
            c.loop.schedule(&c.late_task, .dispatch);
        }
        fn onLate(t: *Loop.Task) void {
            const c: *@This() = @fieldParentPtr("late_task", t);
            c.rec.add('l');
        }
        fn onHook(h: *Loop.Hook) void {
            const c: *@This() = @fieldParentPtr("hook", h);
            testing.expect(c.loop.isDispatching()) catch unreachable;
            c.rec.add('h');
        }
        fn onPost(ctx: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.rec.add('p');
        }
    };
    var c: Ctx = .{ .loop = &loop };
    _ = linux.pipe2(&c.pipe, .{ .CLOEXEC = true, .NONBLOCK = true });
    defer for (c.pipe) |p| closeFd(p);
    c.source = .{ .fd = c.pipe[0], .events = linux.EPOLL.IN, .func = Ctx.onReadable };
    try loop.addSource(&c.source);
    loop.addHook(&c.hook);

    try loop.startTimer(&c.timer, 0, 0); // already expired
    try loop.post(Ctx.onPost, null, &c);
    _ = linux.write(c.pipe[1], "x", 1);

    try testing.expect(!loop.isDispatching());
    try loop.dispatch(1000);
    try testing.expectEqualStrings("itpdfh", c.rec.get());
    try testing.expect(!loop.isDispatching());

    // The late task made the fd readable so an embedder polls again.
    var pfd = [_]linux.pollfd{.{ .fd = loop.fd(), .events = linux.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(usize, 1), linux.poll(&pfd, 1, 0));
    try loop.dispatch(0);
    try testing.expectEqualStrings("itpdfhlh", c.rec.get());

    // Nothing pending: the fd is not readable and dispatch(0) is a no-op
    // apart from hooks.
    pfd[0].revents = 0;
    try testing.expectEqual(@as(usize, 0), linux.poll(&pfd, 1, 0));
    loop.removeHook(&c.hook);
    loop.removeSource(&c.source);
    try loop.dispatch(0);
    try testing.expectEqualStrings("itpdfhlh", c.rec.get());
}

test "timers fire in deadline order, repeat, and cancel" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();

    const Ctx = struct {
        rec: Recorder = .{},
        loop: *Loop,
        a: Timer = .{ .func = onA },
        b: Timer = .{ .func = onB },
        c: Timer = .{ .func = onC },
        fn onA(t: *Timer) void {
            const c: *@This() = @fieldParentPtr("a", t);
            c.rec.add('a');
            // Cancelling another expired timer from a callback prevents it.
            c.loop.cancelTimer(&c.c);
        }
        fn onB(t: *Timer) void {
            const c: *@This() = @fieldParentPtr("b", t);
            c.rec.add('b');
            if (c.rec.len >= 4) c.loop.cancelTimer(t);
        }
        fn onC(t: *Timer) void {
            const c: *@This() = @fieldParentPtr("c", t);
            c.rec.add('c');
        }
    };
    var c: Ctx = .{ .loop = &loop };
    const start = Loop.now();
    const ms = std.time.ns_per_ms;
    try loop.startTimer(&c.b, start + 2 * ms, 3 * ms);
    try loop.startTimer(&c.a, start + 6 * ms, 0);
    try loop.startTimer(&c.c, start + 6 * ms + 1, 0);

    // b at 2 and 5 ms, a at 6 ms (cancelling c even if it is also due), b
    // at 8 ms. The order holds even if a slow dispatch makes several due.
    while (c.rec.len < 4) try loop.dispatch(-1);
    try testing.expectEqualStrings("bbab", c.rec.get());
    try testing.expect(Loop.now() - start >= 8 * ms);
    try testing.expect(!c.b.armed());
    try testing.expect(!c.c.armed());
    try testing.expectEqual(@as(?u64, null), loop.armed_deadline);
}

test "post from other threads runs every closure once in the dispatch phase" {
    var loop = try Loop.init(std.heap.smp_allocator);
    defer loop.deinit();

    const per_thread = 500;
    const Shared = struct {
        count: usize = 0,
        fn bump(ctx: ?*anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.count += 1; // loop thread only
        }
        fn producer(l: *Loop, s: *@This()) void {
            for (0..per_thread) |_| l.post(bump, null, s) catch unreachable;
        }
    };
    var shared: Shared = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.producer, .{ &loop, &shared });
    while (shared.count < threads.len * per_thread) try loop.dispatch(-1);
    for (threads) |t| t.join();
    try loop.dispatch(0);
    try testing.expectEqual(threads.len * per_thread, shared.count);
}

test "deinit cancels posted closures instead of running them" {
    var loop = try Loop.init(testing.allocator);
    const Counts = struct {
        ran: usize = 0,
        destroyed: usize = 0,
        fn run(ctx: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.ran += 1;
        }
        fn destroy(ctx: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.destroyed += 1;
        }
    };
    var counts: Counts = .{};
    try loop.post(Counts.run, Counts.destroy, &counts);
    try loop.post(Counts.run, null, &counts); // no destroy: just freed
    try loop.post(Counts.run, Counts.destroy, &counts);
    loop.deinit(); // the testing allocator checks the nodes were freed
    try testing.expectEqual(@as(usize, 0), counts.ran);
    try testing.expectEqual(@as(usize, 2), counts.destroyed);
}

test "unscheduling a task from an earlier task in the same batch" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();
    const Ctx = struct {
        loop: *Loop,
        rec: Recorder = .{},
        first: Loop.Task = .{ .func = onFirst },
        second: Loop.Task = .{ .func = onSecond },
        fn onFirst(t: *Loop.Task) void {
            const c: *@This() = @fieldParentPtr("first", t);
            c.rec.add('1');
            c.loop.unschedule(&c.second);
        }
        fn onSecond(t: *Loop.Task) void {
            const c: *@This() = @fieldParentPtr("second", t);
            c.rec.add('2');
        }
    };
    var c: Ctx = .{ .loop = &loop };
    loop.schedule(&c.first, .dispatch);
    loop.schedule(&c.second, .dispatch);
    loop.schedule(&c.second, .dispatch); // idempotent
    try loop.dispatch(0);
    try testing.expectEqualStrings("1", c.rec.get());
    try testing.expect(!c.second.scheduled());
}
