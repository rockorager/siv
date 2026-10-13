//! The headless test binary (D24): every test that needs siv as a whole
//! on the headless backend, in one compilation of siv. build.zig runs it
//! as several processes at once, each with a shard of the tests
//! (test/runner.zig). It lives at the root of the tree so that it can
//! include the tests of the guide and of the files app, which stay beside
//! what they test.

test {
    _ = @import("test/headless.zig");
    _ = @import("docs/guide/tests/guide.zig");
    _ = @import("apps/files/tests/headless.zig");
}
