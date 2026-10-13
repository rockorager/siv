//! The file manager's plain modules, without siv.

test {
    _ = @import("files").model;
    _ = @import("files").uri;
    _ = @import("files").places_mod;
}
