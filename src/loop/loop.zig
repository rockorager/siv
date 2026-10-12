//! Event loop (D5, D6): one epoll loop per application with eventfd wakeups,
//! timerfd deadlines from a userspace timer heap, and safe-point callback
//! dispatch. Embeddable through siv_app_fd() and siv_app_dispatch().
//!
//! Imports: none.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
