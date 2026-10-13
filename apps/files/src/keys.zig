//! XKB keysyms the file manager binds. siv.h has none (FRICTION.md), so
//! every application writes these out.

pub const backspace: u32 = 0xff08;
pub const tab: u32 = 0xff09;
pub const @"return": u32 = 0xff0d;
pub const escape: u32 = 0xff1b;
pub const home: u32 = 0xff50;
pub const left: u32 = 0xff51;
pub const up: u32 = 0xff52;
pub const right: u32 = 0xff53;
pub const down: u32 = 0xff54;
pub const page_up: u32 = 0xff55;
pub const page_down: u32 = 0xff56;
pub const end: u32 = 0xff57;
pub const menu: u32 = 0xff67;
pub const kp_enter: u32 = 0xff8d;
pub const f2: u32 = 0xffbf;
pub const f5: u32 = 0xffc2;
pub const f6: u32 = 0xffc3;
pub const f10: u32 = 0xffc7;
pub const delete: u32 = 0xffff;
pub const space: u32 = 0x20;
pub const back: u32 = 0x1008ff26; // XF86Back
pub const forward: u32 = 0x1008ff27; // XF86Forward
