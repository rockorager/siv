//! The gpui side of bench/gpui-compare: one program, one scenario per run.
//!
//!     gpui-compare idle|gallery|list|text|grid|typing|logs
//!
//! Mirrors siv/bench.c. gpui has no stock widgets, so the gallery's
//! buttons, text field, checkbox, list, and menu are written here with
//! gpui's elements, styled after siv's light theme (src/ui/theme.zig) and
//! widget tokens (src/widgets/tokens.zig). README.md lists the differences.

mod spec;

use std::ops::Range;
use std::time::Instant;

use gpui::{
    AnyElement, App, Bounds, Context, CursorStyle, ElementId, ElementInputHandler, Entity, EntityInputHandler, FocusHandle,
    Focusable, GlobalElementId, Hsla, KeyBinding, LayoutId, ListAlignment, ListState, MouseButton, MouseDownEvent, PaintQuad,
    PathBuilder, Pixels, ShapedLine, SharedString, Style, StyledText, TextRun, UTF16Selection, Window, WindowBounds,
    WindowOptions, actions, anchored, canvas, deferred, div, fill, list, point, prelude::*, px, relative, rgb, size,
    uniform_list,
};
use gpui_platform::application;
use spec::*;

// siv's light theme.
const WINDOW_BG: u32 = 0xfafafa;
const WINDOW_FG: u32 = 0x18181b;
const VIEW_BG: u32 = 0xffffff;
const MUTED_FG: u32 = 0x71717a;
const DISABLED_FG: u32 = 0xa1a1aa;
const BORDER: u32 = 0xc4c4cc;
const CONTROL_BG: u32 = 0xf4f4f5;
const CONTROL_HOVER: u32 = 0xe4e4e7;
const CONTROL_ACTIVE: u32 = 0xd4d4d8;
const ACCENT: u32 = 0x2563eb;
const ACCENT_HOVER: u32 = 0x1d4ed8;
const ACCENT_ACTIVE: u32 = 0x1e40af;
const SELECTION_BG: u32 = 0xbfdbfe;

actions!(bench, [Backspace, Enter, Left, Right, Escape, JumpEnd, JumpHome, Search]);

fn color(v: u32) -> Hsla {
    rgb(v).into()
}

// Idle ----------------------------------------------------------------------------

struct Idle;

impl Render for Idle {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().bg(color(WINDOW_BG)).p(px(24.)).child("Idle window")
    }
}

// Text field ------------------------------------------------------------------------------
//
// Adapted from gpui's examples/input.rs (zed, Apache-2.0), trimmed to a caret
// without selection.

struct TextField {
    focus: FocusHandle,
    content: SharedString,
    placeholder: SharedString,
    caret: usize,
    marked: Option<Range<usize>>,
    last_layout: Option<ShapedLine>,
}

impl TextField {
    fn new(cx: &mut Context<Self>, placeholder: &str) -> Self {
        Self { focus: cx.focus_handle(), content: "".into(), placeholder: placeholder.to_string().into(), caret: 0, marked: None, last_layout: None }
    }

    fn backspace(&mut self, _: &Backspace, _: &mut Window, cx: &mut Context<Self>) {
        if let Some((ix, _)) = self.content[..self.caret].char_indices().next_back() {
            self.content = (self.content[..ix].to_owned() + &self.content[self.caret..]).into();
            self.caret = ix;
            cx.notify();
        }
    }

    fn left(&mut self, _: &Left, _: &mut Window, cx: &mut Context<Self>) {
        if let Some((ix, _)) = self.content[..self.caret].char_indices().next_back() {
            self.caret = ix;
            cx.notify();
        }
    }

    fn right(&mut self, _: &Right, _: &mut Window, cx: &mut Context<Self>) {
        if let Some(c) = self.content[self.caret..].chars().next() {
            self.caret += c.len_utf8();
            cx.notify();
        }
    }
}

fn utf16_to_utf8(s: &str, offset: usize) -> usize {
    let mut u16s = 0;
    for (i, c) in s.char_indices() {
        if u16s >= offset {
            return i;
        }
        u16s += c.len_utf16();
    }
    s.len()
}

fn utf8_to_utf16(s: &str, offset: usize) -> usize {
    s[..offset].chars().map(char::len_utf16).sum()
}

impl EntityInputHandler for TextField {
    fn text_for_range(&mut self, r: Range<usize>, actual: &mut Option<Range<usize>>, _: &mut Window, _: &mut Context<Self>) -> Option<String> {
        let range = utf16_to_utf8(&self.content, r.start)..utf16_to_utf8(&self.content, r.end);
        actual.replace(r);
        Some(self.content[range].to_string())
    }
    fn selected_text_range(&mut self, _: bool, _: &mut Window, _: &mut Context<Self>) -> Option<UTF16Selection> {
        let c = utf8_to_utf16(&self.content, self.caret);
        Some(UTF16Selection { range: c..c, reversed: false })
    }
    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        self.marked.as_ref().map(|r| utf8_to_utf16(&self.content, r.start)..utf8_to_utf16(&self.content, r.end))
    }
    fn unmark_text(&mut self, _: &mut Window, _: &mut Context<Self>) {
        self.marked = None;
    }
    fn replace_text_in_range(&mut self, r: Option<Range<usize>>, text: &str, _: &mut Window, cx: &mut Context<Self>) {
        let range = r
            .map(|r| utf16_to_utf8(&self.content, r.start)..utf16_to_utf8(&self.content, r.end))
            .or(self.marked.clone())
            .unwrap_or(self.caret..self.caret);
        self.content = (self.content[..range.start].to_owned() + text + &self.content[range.end..]).into();
        self.caret = range.start + text.len();
        self.marked = None;
        cx.notify();
    }
    fn replace_and_mark_text_in_range(&mut self, r: Option<Range<usize>>, text: &str, _: Option<Range<usize>>, w: &mut Window, cx: &mut Context<Self>) {
        let start = r.as_ref().map(|r| utf16_to_utf8(&self.content, r.start)).unwrap_or(self.caret);
        self.replace_text_in_range(r, text, w, cx);
        self.marked = (!text.is_empty()).then(|| start..start + text.len());
    }
    fn bounds_for_range(&mut self, _: Range<usize>, bounds: Bounds<Pixels>, _: &mut Window, _: &mut Context<Self>) -> Option<Bounds<Pixels>> {
        Some(bounds)
    }
    fn character_index_for_point(&mut self, _: gpui::Point<Pixels>, _: &mut Window, _: &mut Context<Self>) -> Option<usize> {
        None
    }
}

struct TextFieldElement {
    input: Entity<TextField>,
}

impl IntoElement for TextFieldElement {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}

impl Element for TextFieldElement {
    type RequestLayoutState = ();
    type PrepaintState = (Option<ShapedLine>, Option<PaintQuad>);

    fn id(&self) -> Option<ElementId> {
        None
    }
    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }
    fn request_layout(&mut self, _: Option<&GlobalElementId>, _: Option<&gpui::InspectorElementId>, window: &mut Window, cx: &mut App) -> (LayoutId, ()) {
        let mut style = Style::default();
        style.size.width = relative(1.).into();
        style.size.height = window.line_height().into();
        (window.request_layout(style, [], cx), ())
    }
    fn prepaint(&mut self, _: Option<&GlobalElementId>, _: Option<&gpui::InspectorElementId>, bounds: Bounds<Pixels>, _: &mut (), window: &mut Window, cx: &mut App) -> Self::PrepaintState {
        let input = self.input.read(cx);
        let style = window.text_style();
        let (text, text_color) =
            if input.content.is_empty() { (input.placeholder.clone(), color(MUTED_FG)) } else { (input.content.clone(), style.color) };
        let run = TextRun { len: text.len(), font: style.font(), color: text_color, background_color: None, underline: None, strikethrough: None };
        let font_size = style.font_size.to_pixels(window.rem_size());
        let line = window.text_system().shape_line(text, font_size, &[run], None);
        let x = if input.content.is_empty() { px(0.) } else { line.x_for_index(input.caret) };
        let caret = fill(Bounds::new(point(bounds.left() + x, bounds.top()), size(px(1.5), bounds.size.height)), color(WINDOW_FG));
        (Some(line), Some(caret))
    }
    fn paint(&mut self, _: Option<&GlobalElementId>, _: Option<&gpui::InspectorElementId>, bounds: Bounds<Pixels>, _: &mut (), prepaint: &mut Self::PrepaintState, window: &mut Window, cx: &mut App) {
        let focus = self.input.read(cx).focus.clone();
        window.handle_input(&focus, ElementInputHandler::new(bounds, self.input.clone()), cx);
        let line = prepaint.0.take().unwrap();
        line.paint(bounds.origin, window.line_height(), gpui::TextAlign::Left, None, window, cx).ok();
        if focus.is_focused(window) {
            if let Some(caret) = prepaint.1.take() {
                window.paint_quad(caret);
            }
        }
        self.input.update(cx, |input, _| input.last_layout = Some(line));
    }
}

impl Render for TextField {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let focused = self.focus.is_focused(window);
        div()
            .key_context("TextField")
            .track_focus(&self.focus)
            .cursor(CursorStyle::IBeam)
            .on_action(cx.listener(Self::backspace))
            .on_action(cx.listener(Self::left))
            .on_action(cx.listener(Self::right))
            .on_mouse_down(MouseButton::Left, cx.listener(|this, _: &MouseDownEvent, window, cx| {
                window.focus(&this.focus, cx);
            }))
            .w(px(320.))
            .h(px(32.))
            .px(px(8.))
            .flex()
            .items_center()
            .bg(color(VIEW_BG))
            .rounded(px(6.))
            .border_1()
            .border_color(color(if focused { ACCENT } else { BORDER }))
            .child(TextFieldElement { input: cx.entity() })
    }
}

impl Focusable for TextField {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

// Gallery ---------------------------------------------------------------------------------

const MENU_ITEMS: [&str; 6] = ["New", "Open", "Save", "Save As", "Close", "Quit"];

struct Gallery {
    field: Entity<TextField>,
    focus: FocusHandle,
    checked: bool,
    menu_open: bool,
    selected: Option<usize>,
    status: SharedString,
}

fn button(id: &'static str, label: &'static str, primary: bool, disabled: bool) -> gpui::Stateful<gpui::Div> {
    let (bg, hover, active, fg, border) = if disabled {
        (CONTROL_BG, CONTROL_BG, CONTROL_BG, DISABLED_FG, CONTROL_HOVER)
    } else if primary {
        (ACCENT, ACCENT_HOVER, ACCENT_ACTIVE, 0xffffff, ACCENT)
    } else {
        (CONTROL_BG, CONTROL_HOVER, CONTROL_ACTIVE, WINDOW_FG, BORDER)
    };
    let b = div()
        .id(id)
        .h(px(32.))
        .px(px(12.))
        .flex()
        .items_center()
        .rounded(px(6.))
        .border_1()
        .border_color(color(border))
        .bg(color(bg))
        .text_color(color(fg))
        .child(label);
    if disabled { b } else { b.hover(move |s| s.bg(color(hover))).active(move |s| s.bg(color(active))) }
}

fn check_mark() -> impl IntoElement {
    canvas(
        |_, _, _| {},
        |bounds, _, window, _| {
            let o = bounds.origin;
            let mut path = PathBuilder::stroke(px(2.));
            path.move_to(point(o.x + px(4.5), o.y + px(9.)));
            path.line_to(point(o.x + px(7.5), o.y + px(12.)));
            path.line_to(point(o.x + px(13.5), o.y + px(6.)));
            if let Ok(path) = path.build() {
                window.paint_path(path, color(0xffffff));
            }
        },
    )
    .size_full()
}

impl Gallery {
    fn set_status(&mut self, what: impl std::fmt::Display, cx: &mut Context<Self>) {
        self.status = format!("Last action: {what}").into();
        cx.notify();
    }
}

impl Render for Gallery {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let selected = self.selected;
        let menu = div()
            .relative()
            .child(button("menu", "Menu", false, false).on_click(cx.listener(|this, _, _, cx| {
                this.menu_open = !this.menu_open;
                cx.notify();
            })))
            .when(self.menu_open, |d| {
                d.child(div().absolute().top(px(34.)).left_0().child(deferred(
                    anchored().child(
                        div()
                            .id("menu-card")
                            .occlude()
                            .w(px(180.))
                            .p(px(4.))
                            .bg(color(VIEW_BG))
                            .border_1()
                            .border_color(color(BORDER))
                            .rounded(px(10.))
                            .shadow_md()
                            .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                                this.menu_open = false;
                                cx.notify();
                            }))
                            .children(MENU_ITEMS.iter().enumerate().map(|(i, label)| {
                                div()
                                    .id(i)
                                    .h(px(28.))
                                    .px(px(10.))
                                    .flex()
                                    .items_center()
                                    .rounded(px(6.))
                                    .hover(|s| s.bg(color(SELECTION_BG)))
                                    .child(*label)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.menu_open = false;
                                        this.set_status(MENU_ITEMS[i], cx);
                                    }))
                            })),
                    ),
                )))
            });
        div()
            .key_context("Gallery")
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &Escape, _, cx| {
                this.menu_open = false;
                cx.notify();
            }))
            .size_full()
            .bg(color(WINDOW_BG))
            .p(px(24.))
            .flex()
            .flex_col()
            .gap(px(14.))
            .items_start()
            .child(div().text_size(px(BODY_PX * 1.5)).font_weight(gpui::FontWeight::BOLD).child("Widget gallery"))
            .child(
                div()
                    .flex()
                    .gap(px(8.))
                    .child(button("default", "Default", false, false).on_click(cx.listener(|this, _, _, cx| this.set_status("Default", cx))))
                    .child(button("primary", "Primary", true, false).on_click(cx.listener(|this, _, _, cx| this.set_status("Primary", cx))))
                    .child(button("disabled", "Disabled", false, true))
                    .child(menu),
            )
            .child(self.field.clone())
            .child(
                div()
                    .id("check")
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.checked = !this.checked;
                        this.set_status("Toggled", cx);
                    }))
                    .child(
                        div()
                            .size(px(18.))
                            .rounded(px(4.))
                            .border_1()
                            .border_color(color(if self.checked { ACCENT } else { BORDER }))
                            .bg(color(if self.checked { ACCENT } else { VIEW_BG }))
                            .when(self.checked, |d| d.child(check_mark())),
                    )
                    .child("Enable feature"),
            )
            .child(
                div().w(px(320.)).h(px(320.)).bg(color(VIEW_BG)).border_1().border_color(color(BORDER)).rounded(px(6.)).overflow_hidden().child(
                    uniform_list(
                        "items",
                        50,
                        cx.processor(move |_this, range: Range<usize>, _window, cx| {
                            range
                                .map(|ix| {
                                    div()
                                        .id(ix)
                                        .h(px(32.))
                                        .px(px(8.))
                                        .flex()
                                        .items_center()
                                        .when(selected == Some(ix), |d| d.bg(color(SELECTION_BG)))
                                        .when(selected != Some(ix), |d| d.hover(|s| s.bg(color(CONTROL_HOVER))))
                                        .child(format!("Item {}", ix + 1))
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            this.selected = Some(ix);
                                            this.set_status(format!("Item {}", ix + 1), cx);
                                        }))
                                })
                                .collect()
                        }),
                    )
                    .size_full(),
                ),
            )
            .child(div().text_color(color(MUTED_FG)).child(self.status.clone()))
    }
}

// 100k-row list -------------------------------------------------------------------------

struct RowList;

impl Render for RowList {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().bg(color(WINDOW_BG)).child(
            div().size_full().bg(color(VIEW_BG)).border_1().border_color(color(BORDER)).rounded(px(6.)).overflow_hidden().child(
                uniform_list("rows", 100_000, |range: Range<usize>, _, _| {
                    range
                        .map(|ix| {
                            div()
                                .id(ix)
                                .h(px(28.))
                                .px(px(8.))
                                .flex()
                                .items_center()
                                .gap(px(12.))
                                .child(div().w(px(100.)).child(format!("Row {}", ix + 1)))
                                .child(div().text_color(color(MUTED_FG)).child(format!("Description of row {} with a few more words", ix + 1)))
                        })
                        .collect()
                })
                .size_full(),
            ),
        )
    }
}

// Editable document ----------------------------------------------------------------------

/// A multi-line editor over paragraphs, as gpui applications build one:
/// a `list` measures and paints only the paragraphs in view, each a
/// wrapped `StyledText`.
struct Editor {
    focus: FocusHandle,
    paras: Vec<SharedString>,
    /// Paragraph and byte offset of the caret.
    caret: (usize, usize),
    list: ListState,
}

impl Editor {
    fn new(cx: &mut Context<Self>, paras: Vec<String>) -> Self {
        let paras: Vec<SharedString> = paras.into_iter().map(Into::into).collect();
        let list = ListState::new(paras.len(), ListAlignment::Top, px(200.));
        Self { focus: cx.focus_handle(), paras, caret: (0, 0), list }
    }

    fn edited(&mut self, para: usize, cx: &mut Context<Self>) {
        self.list.splice(para..para + 1, 1);
        cx.notify();
    }

    fn backspace(&mut self, _: &Backspace, _: &mut Window, cx: &mut Context<Self>) {
        let (p, off) = self.caret;
        if off > 0 {
            let text = &self.paras[p];
            let ix = text[..off].char_indices().next_back().map(|(i, _)| i).unwrap_or(0);
            self.paras[p] = (text[..ix].to_owned() + &text[off..]).into();
            self.caret = (p, ix);
            self.edited(p, cx);
        } else if p > 0 {
            let prev_len = self.paras[p - 1].len();
            self.paras[p - 1] = (self.paras[p - 1].to_string() + &self.paras[p]).into();
            self.paras.remove(p);
            self.list.splice(p - 1..p + 1, 1);
            self.caret = (p - 1, prev_len);
            cx.notify();
        }
    }

    fn enter(&mut self, _: &Enter, _: &mut Window, cx: &mut Context<Self>) {
        let (p, off) = self.caret;
        let text = self.paras[p].clone();
        self.paras[p] = text[..off].to_string().into();
        self.paras.insert(p + 1, text[off..].to_string().into());
        self.list.splice(p..p + 1, 2);
        self.caret = (p + 1, 0);
        cx.notify();
    }

    fn left(&mut self, _: &Left, _: &mut Window, cx: &mut Context<Self>) {
        let (p, off) = self.caret;
        if let Some((ix, _)) = self.paras[p][..off].char_indices().next_back() {
            self.caret = (p, ix);
            cx.notify();
        }
    }

    fn right(&mut self, _: &Right, _: &mut Window, cx: &mut Context<Self>) {
        let (p, off) = self.caret;
        if let Some(c) = self.paras[p][off..].chars().next() {
            self.caret = (p, off + c.len_utf8());
            cx.notify();
        }
    }

    fn jump_end(&mut self, _: &JumpEnd, _: &mut Window, cx: &mut Context<Self>) {
        let last = self.paras.len() - 1;
        self.caret = (last, self.paras[last].len());
        self.list.scroll_to_reveal_item(last);
        cx.notify();
    }

    fn jump_home(&mut self, _: &JumpHome, _: &mut Window, cx: &mut Context<Self>) {
        self.caret = (0, 0);
        self.list.scroll_to_reveal_item(0);
        cx.notify();
    }

    /// F3: the next paragraph holding the needle after the caret's,
    /// wrapping around; the caret goes after it and its paragraph into
    /// view.
    fn search(&mut self, _: &Search, _: &mut Window, cx: &mut Context<Self>) {
        let n = self.paras.len();
        for k in 1..=n {
            let p = (self.caret.0 + k) % n;
            if let Some(off) = self.paras[p].find(DOC_NEEDLE) {
                self.caret = (p, off + DOC_NEEDLE.len());
                self.list.scroll_to_reveal_item(p);
                cx.notify();
                return;
            }
        }
    }
}

impl EntityInputHandler for Editor {
    fn text_for_range(&mut self, r: Range<usize>, actual: &mut Option<Range<usize>>, _: &mut Window, _: &mut Context<Self>) -> Option<String> {
        let text = &self.paras[self.caret.0];
        let range = utf16_to_utf8(text, r.start)..utf16_to_utf8(text, r.end);
        actual.replace(r);
        Some(text[range].to_string())
    }
    fn selected_text_range(&mut self, _: bool, _: &mut Window, _: &mut Context<Self>) -> Option<UTF16Selection> {
        let c = utf8_to_utf16(&self.paras[self.caret.0], self.caret.1);
        Some(UTF16Selection { range: c..c, reversed: false })
    }
    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        None
    }
    fn unmark_text(&mut self, _: &mut Window, _: &mut Context<Self>) {}
    fn replace_text_in_range(&mut self, r: Option<Range<usize>>, new: &str, _: &mut Window, cx: &mut Context<Self>) {
        let (p, off) = self.caret;
        let text = &self.paras[p];
        let range = r.map(|r| utf16_to_utf8(text, r.start)..utf16_to_utf8(text, r.end)).unwrap_or(off..off);
        self.paras[p] = (text[..range.start].to_owned() + new + &text[range.end..]).into();
        self.caret = (p, range.start + new.len());
        self.edited(p, cx);
    }
    fn replace_and_mark_text_in_range(&mut self, r: Option<Range<usize>>, new: &str, _: Option<Range<usize>>, w: &mut Window, cx: &mut Context<Self>) {
        self.replace_text_in_range(r, new, w, cx);
    }
    fn bounds_for_range(&mut self, _: Range<usize>, bounds: Bounds<Pixels>, _: &mut Window, _: &mut Context<Self>) -> Option<Bounds<Pixels>> {
        Some(bounds)
    }
    fn character_index_for_point(&mut self, _: gpui::Point<Pixels>, _: &mut Window, _: &mut Context<Self>) -> Option<usize> {
        None
    }
}

impl Render for Editor {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let entity = cx.entity();
        let focus = self.focus.clone();
        let count = self.paras.len();
        div()
            .key_context("Editor")
            .track_focus(&self.focus)
            .cursor(CursorStyle::IBeam)
            .on_action(cx.listener(Self::backspace))
            .on_action(cx.listener(Self::enter))
            .on_action(cx.listener(Self::left))
            .on_action(cx.listener(Self::right))
            .on_action(cx.listener(Self::jump_end))
            .on_action(cx.listener(Self::jump_home))
            .on_action(cx.listener(Self::search))
            .size_full()
            .relative()
            .bg(color(WINDOW_BG))
            .line_height(px(DOC_LINE_HEIGHT))
            .child(
                list(self.list.clone(), {
                    let entity = entity.clone();
                    move |ix, _window, cx| -> AnyElement {
                        let editor = entity.read(cx);
                        let text = editor.paras[ix].clone();
                        let caret = (editor.caret.0 == ix).then_some(editor.caret.1);
                        let styled = StyledText::new(if text.is_empty() { SharedString::from(" ") } else { text });
                        let layout = styled.layout().clone();
                        div()
                            .px(px(24.))
                            .when(ix == 0, |d| d.pt(px(24.)))
                            .when(ix + 1 == count, |d| d.pb(px(24.)))
                            .child(div().relative().child(styled).when_some(caret, |d, off| {
                                d.child(
                                    canvas(
                                        |_, _, _| {},
                                        move |_, _, window, _| {
                                            if let Some(p) = layout.position_for_index(off) {
                                                window.paint_quad(fill(Bounds::new(p, size(px(1.5), px(DOC_LINE_HEIGHT))), color(WINDOW_FG)));
                                            }
                                        },
                                    )
                                    .absolute()
                                    .size_full(),
                                )
                            }))
                            .into_any_element()
                    }
                })
                .size_full(),
            )
            .child(
                canvas(
                    |_, _, _| {},
                    move |bounds, _, window, cx| {
                        window.handle_input(&focus, ElementInputHandler::new(bounds, entity.clone()), cx);
                    },
                )
                .absolute()
                .size_full(),
            )
    }
}

// Grid of animated cells -----------------------------------------------------------------

/// Every cell's opacity follows siv's compositor animation: 1 to 0.2 and
/// back (alternate) over GRID_PERIOD_MS with CSS ease-in-out, after a
/// per-cell delay. gpui animates by re-rendering every frame.
struct Grid {
    start: Instant,
}

impl Render for Grid {
    fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        window.request_animation_frame();
        let t = self.start.elapsed().as_secs_f32() * 1000.0;
        let period = GRID_PERIOD_MS as f32;
        div().size_full().bg(color(WINDOW_BG)).p(px(2.)).flex().flex_wrap().gap(px(4.)).content_start().children((0..GRID_COLS * GRID_ROWS).map(|i| {
            let since = t - grid_delay_ms(i) as f32;
            let opacity = if since < 0.0 {
                1.0
            } else {
                let k = (since / period).floor();
                let mut f = since / period - k;
                if k as i64 % 2 == 1 {
                    f = 1.0 - f;
                }
                1.0 - 0.8 * css_ease_in_out(f)
            };
            div().size(px(16.)).rounded(px(3.)).bg(color(grid_color(i))).opacity(opacity)
        }))
    }
}

// Main ---------------------------------------------------------------------------------

fn main() {
    let scenario = std::env::args().nth(1).unwrap_or_else(|| "idle".into());
    application().run(move |cx: &mut App| {
        cx.bind_keys([
            KeyBinding::new("backspace", Backspace, None),
            KeyBinding::new("enter", Enter, Some("Editor")),
            KeyBinding::new("left", Left, None),
            KeyBinding::new("right", Right, None),
            KeyBinding::new("escape", Escape, None),
            KeyBinding::new("ctrl-end", JumpEnd, Some("Editor")),
            KeyBinding::new("ctrl-home", JumpHome, Some("Editor")),
            KeyBinding::new("f3", Search, Some("Editor")),
        ]);
        let bounds = Bounds::centered(None, size(px(1280.), px(800.)), cx);
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            titlebar: Some(gpui::TitlebarOptions { title: Some(format!("bench {scenario}").into()), ..Default::default() }),
            app_id: Some("gpui-bench".into()),
            ..Default::default()
        };
        let scenario = scenario.clone();
        cx.open_window(options, move |window, cx| {
            window.set_rem_size(px(BODY_PX));
            let root: gpui::AnyView = match scenario.as_str() {
                "idle" => cx.new(|_| Idle).into(),
                "gallery" => {
                    let field = cx.new(|cx| TextField::new(cx, "Type here"));
                    window.focus(&field.focus_handle(cx), cx);
                    cx.new(|cx| Gallery { field, focus: cx.focus_handle(), checked: false, menu_open: false, selected: None, status: "Last action: none".into() }).into()
                }
                "list" => cx.new(|_| RowList).into(),
                "text" | "typing" | "logs" => {
                    let paras = match scenario.as_str() {
                        "text" => doc_paragraphs(DOC_LARGE_PARAGRAPHS),
                        "typing" => doc_paragraphs(DOC_SMALL_PARAGRAPHS),
                        _ => log_lines(),
                    };
                    let editor = cx.new(|cx| Editor::new(cx, paras));
                    window.focus(&editor.read(cx).focus.clone(), cx);
                    editor.into()
                }
                "grid" => cx.new(|_| Grid { start: Instant::now() }).into(),
                other => panic!("unknown scenario {other}"),
            };
            cx.new(|_| Root { child: root })
        })
        .unwrap();
        cx.activate(true);
    });
}

/// Sets the font every scenario uses, as siv's default font.
struct Root {
    child: gpui::AnyView,
}

impl Render for Root {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().font_family(BENCH_FONT).text_size(px(BODY_PX)).line_height(relative(1.21)).text_color(color(WINDOW_FG)).child(self.child.clone())
    }
}
