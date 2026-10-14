//! A window with a heading and a button that counts its clicks, the
//! Rust version of docs/guide/examples/hello.c, through siv's C ABI.
//!
//!     zig build    # from the repository root
//!     PKG_CONFIG_PATH=$PWD/zig-out/lib/pkgconfig cargo run --manifest-path examples/rust/Cargo.toml
//!
//! build.rs generates the declarations of siv.h with bindgen; this file
//! uses them as C would. A safe wrapper is the application's to write.

#![allow(non_camel_case_types, non_upper_case_globals, dead_code)]

mod siv {
    include!(concat!(env!("OUT_DIR"), "/siv.rs"));
}

use siv::*;
use std::ffi::{CStr, c_void};
use std::process::ExitCode;

/// SIV_DESC: a descriptor with its size set and every other field zero,
/// which always means the default.
macro_rules! desc {
    ($t:ident { $($field:ident: $value:expr),* $(,)? }) => {
        &$t { size: std::mem::size_of::<$t>(), $($field: $value,)* ..Default::default() }
    };
}

fn edges(all: f32) -> siv_edges {
    siv_edges { start: all, end: all, top: all, bottom: all }
}

fn name(r: siv_result) -> String {
    unsafe { CStr::from_ptr(siv_result_name(r)) }.to_string_lossy().into_owned()
}

struct Counter {
    label: siv_node,
    clicks: u32,
}

/// Runs on the application's thread when the button is clicked or
/// activated from the keyboard; changes the label in a transaction.
unsafe extern "C" fn on_click(user_data: *mut c_void, _button: siv_node, event: *const siv_event) -> siv_event_result {
    let counter = unsafe { &mut *user_data.cast::<Counter>() };
    counter.clicks += 1;
    let text = format!("Clicked {} time{}", counter.clicks, if counter.clicks == 1 { "" } else { "s" });
    unsafe {
        let mut txn: siv_txn = 0;
        if siv_txn_begin((*event).window, &mut txn) != SIV_OK {
            return SIV_EVENT_RESULT_PASS;
        }
        siv_set_text(txn, counter.label, text.as_ptr().cast(), text.len());
        if siv_txn_commit(txn) == SIV_OK { SIV_EVENT_RESULT_HANDLED } else { SIV_EVENT_RESULT_PASS }
    }
}

fn main() -> ExitCode {
    let mut counter = Counter { label: 0, clicks: 0 };
    unsafe {
        let mut app: siv_app = 0;
        let r = siv_app_create(std::ptr::null(), &mut app);
        if r != SIV_OK {
            eprintln!("siv_app_create: {}", name(r));
            return ExitCode::FAILURE;
        }
        let title = "Hello";
        let mut window: siv_window = 0;
        let mut r = siv_window_create(
            app,
            desc!(siv_window_desc { title: title.as_ptr().cast(), title_len: title.len(), width: 320, height: 160 }),
            &mut window,
        );
        let mut txn: siv_txn = 0;
        if r == SIV_OK {
            r = siv_txn_begin(window, &mut txn);
        }
        if r == SIV_OK {
            // As in C, builders and setters are not checked one by one: the
            // first failure makes the rest do nothing, and commit reports it.
            let root = siv_window_get_root(window);
            siv_set_visual(txn, root, desc!(siv_visual_desc { background_token: SIV_COLOR_TOKEN_WINDOW_BG }));
            let column = siv_flex(txn, root, desc!(siv_flex_desc { axis: SIV_AXIS_COLUMN, gap: 12.0, align_items: SIV_ALIGN_START }));
            siv_set_layout(txn, column, desc!(siv_layout_desc { padding: edges(24.0) }));

            let heading = "Hello from Rust";
            let title = siv_text(txn, column, heading.as_ptr().cast(), heading.len());
            siv_set_text_style(
                txn,
                title,
                desc!(siv_text_style_desc { size_role: SIV_SIZE_ROLE_TITLE, weight: SIV_FONT_WEIGHT_BOLD, color_token: SIV_COLOR_TOKEN_WINDOW_FG }),
            );
            siv_set_semantics(txn, title, desc!(siv_semantics_desc { role: SIV_ROLE_HEADING, level: 1 }));

            let label = "Click me";
            let button = siv_push_button(
                txn,
                column,
                desc!(siv_button_desc { label: label.as_ptr().cast(), label_len: label.len(), style: SIV_BUTTON_STYLE_PRIMARY }),
            );
            siv_on(txn, button, SIV_EVENT_TYPE_ACTIVATE, Some(on_click), None, (&raw mut counter).cast());

            let text = "Not clicked yet";
            counter.label = siv_text(txn, column, text.as_ptr().cast(), text.len());
            siv_set_text_style(txn, counter.label, desc!(siv_text_style_desc { color_token: SIV_COLOR_TOKEN_WINDOW_FG }));
            r = siv_txn_commit(txn);
        }
        // Dispatches events until the last window closes.
        if r == SIV_OK {
            r = siv_app_run(app);
        }
        if r != SIV_OK {
            eprintln!("hello: {}", name(r));
        }
        siv_app_destroy(app);
        if r == SIV_OK { ExitCode::SUCCESS } else { ExitCode::FAILURE }
    }
}
