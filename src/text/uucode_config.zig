//! uucode build configuration: which Unicode properties are compiled into
//! lookup tables. build.zig passes this file to uucode, so the text
//! workstream can change fields and tables without editing build.zig. See
//! uucode's README ("Advanced configuration") for the format.

const config = @import("config.zig");

pub const fields = config.fields;
pub const build_components = config.build_components;
pub const get_components = config.get_components;

pub const tables: []const config.Table = &.{
    .{ .fields = &.{ "general_category", "grapheme_break" } },
};
