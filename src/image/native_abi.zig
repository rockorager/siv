//! What src/image/image.zig and the object compiled from
//! src/image/native.zig share: the `siv_native_*` functions' types.

/// Results.
pub const ok = 0;
pub const end = 1;
pub const unsupported = -1;
pub const invalid = -2;
pub const too_large = -3;
pub const no_memory = -4;

pub const Format = enum(u8) { png, jpeg, gif, webp, jxl };

/// What `siv_native_open` reads from the headers.
pub const Info = extern struct {
    ctx: ?*anyopaque = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Frames are RGBA16 (native endian) rather than RGBA8.
    deep: bool = false,
    /// 0 sRGB, 1 ICC profile (`icc`, valid until `siv_native_close`), 2
    /// CICP (`primaries`, `transfer`), 3 linear light with sRGB primaries.
    color: u8 = 0,
    primaries: u16 = 1,
    transfer: u16 = 13,
    icc: ?[*]const u8 = null,
    icc_len: usize = 0,
    /// How many times an animation plays; 0 forever.
    loops: u32 = 0,
    /// Frames in the file; 0 if unknown.
    frames: u32 = 0,
};

/// Reads the headers into `info`, whose `ctx` is then the decoder. With
/// `count`, frames that the headers do not count are counted from the
/// file: GIF and WebP by their containers, JPEG XL by decoding them.
pub const Open = fn (format: Format, data: [*]const u8, len: usize, max_pixels: u64, count: bool, info: *Info) callconv(.c) c_int;
/// Draws the next frame onto the canvas, `len` bytes of packed rows that
/// hold the previous frame. `end` after the last frame, and after a damaged
/// frame that follows good ones.
pub const Next = fn (ctx: *anyopaque, rgba: [*]u8, len: usize, delay_ms: *u32) callconv(.c) c_int;
pub const Close = fn (ctx: *anyopaque) callconv(.c) void;
