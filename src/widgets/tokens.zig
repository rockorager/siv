//! Compiled design tokens of the stock widgets (D29): spacing, radii, and
//! control sizes in logical pixels. Colors and text sizes are themed at
//! run time (siv_color_token, siv_size_role) and are not here.

/// Least height of buttons, fields, and spin buttons.
pub const control_height: f32 = 32;
/// Corner radius of controls and fields.
pub const radius: f32 = 6;
/// Corner radius of cards: menus, popovers, dialogs.
pub const card_radius: f32 = 10;
pub const border: f32 = 1;
/// Horizontal and vertical padding inside buttons and fields.
pub const pad_x: f32 = 12;
pub const pad_y: f32 = 5;
pub const field_pad_x: f32 = 8;
/// Space between a control and its label, and between related controls.
pub const gap: f32 = 8;
/// Icons in buttons and menu items (D19), and the space after them.
pub const icon_size: f32 = 16;
pub const icon_gap: f32 = 6;

pub const check_size: f32 = 18;
pub const check_radius: f32 = 4;
pub const check_stroke: f32 = 2;
pub const radio_dot: f32 = 8;

pub const switch_width: f32 = 36;
pub const switch_height: f32 = 20;
pub const switch_pad: f32 = 2;
pub const knob: f32 = switch_height - 2 * switch_pad;

pub const slider_height: f32 = 24;
pub const slider_min_width: f32 = 120;
pub const track: f32 = 4;
pub const thumb: f32 = 18;

pub const progress_height: f32 = 6;
pub const progress_min_width: f32 = 120;
/// Indeterminate progress: the share of the track the bar fills.
pub const indeterminate_share: f32 = 0.3;
/// One sweep of indeterminate progress across the track.
pub const indeterminate_ms: u32 = 1500;

pub const field_min_width: f32 = 160;
pub const spin_field_width: f32 = 64;
/// Text areas: height of one line, before padding.
pub const line_height: f32 = 20;

/// Transitions (D29), turned off by reduced motion.
pub const motion_ms: u32 = 150;
/// Springs of layout motion, enters, and exits (D38): their response.
pub const spring_ms: u32 = 300;

/// Header bars (D17): padding around their controls, and their least
/// height.
pub const bar_pad: f32 = 6;
pub const bar_height: f32 = 46;
/// Glyphs siv draws in buttons (a header bar's back and window
/// controls): their stroke.
pub const glyph_stroke: f32 = 1.5;
/// Sidebars: their width, the padding around their items, and the space
/// above a section's title.
pub const sidebar_width: f32 = 220;
pub const sidebar_pad: f32 = 6;
pub const section_gap: f32 = 12;
/// Navigation stacks: how far the page below moves while a page slides
/// over it or off it, in its widths (D38).
pub const parallax: f32 = 0.3;
