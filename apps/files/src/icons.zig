//! File and place icons: names in the icon theme (D19), which image
//! nodes look up, load, and recolor with the theme.

const model = @import("model.zig");

pub const Icon = enum(u8) {
    folder,
    file,
    text,
    image,
    audio,
    video,
    archive,
    document,
    code,
    executable,
    home,
    desktop,
    trash,
    computer,
    bookmark,
    download,

    pub fn of(cat: model.Category) Icon {
        return switch (cat) {
            .folder => .folder,
            .text => .text,
            .image => .image,
            .audio => .audio,
            .video => .video,
            .archive => .archive,
            .document => .document,
            .code => .code,
            .executable => .executable,
            .other => .file,
        };
    }
};

/// The themed icon names for `icon` (D19), one per line, the first the
/// theme has winning; the application's own icons (apps/files/icons,
/// installed as share/siv-files/icons) have each first name, so a theme
/// without one falls back to them.
pub fn names(icon: Icon) []const u8 {
    return switch (icon) {
        .folder => "folder",
        .file => "application-x-generic\ntext-x-generic",
        .text => "text-x-generic",
        .image => "image-x-generic",
        .audio => "audio-x-generic",
        .video => "video-x-generic",
        .archive => "package-x-generic\napplication-x-archive",
        .document => "x-office-document",
        .code => "text-x-script\ntext-x-generic",
        .executable => "application-x-executable",
        .home => "user-home\nfolder",
        .desktop => "user-desktop\nfolder",
        .trash => "user-trash",
        .computer => "computer",
        .bookmark => "user-bookmarks\nfolder",
        .download => "folder-download\nfolder",
    };
}
