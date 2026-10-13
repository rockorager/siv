/* Printing and PDF: one function draws a page with the canvas drawing
 * calls, for an on-screen preview, a PDF file, and the system's print
 * dialog alike.
 *
 *     zig build guide && ./zig-out/bin/guide-print
 */
#include <siv.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>


static void commit(siv_txn txn) {
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "siv_txn_commit: %s\n", siv_result_name(r));
}

#define A4_WIDTH 595.0f
#define A4_HEIGHT 842.0f

struct doc {
	siv_app app;
	siv_window window;
	siv_node status;
	char path[256];
};

static const char *const items[][2] = {{"Design review", "$1,200.00"}, {"Illustrations (12)", "$2,400.00"}, {"Printing", "$310.00"}};

/* Draws one page in points, y down from the top-left corner. Page 0 is
 * the invoice, page 1 its terms. */
static void draw_page(void *user_data, siv_draw d, uint32_t page, const siv_page_setup *setup) {
	(void)user_data;
	float x = setup->margin_left, y = setup->margin_top;
	float w = setup->width - setup->margin_left - setup->margin_right;
	siv_color ink = {0.1f, 0.1f, 0.12f, 1}, muted = {0.45f, 0.45f, 0.5f, 1}, accent = {0.15f, 0.39f, 0.92f, 1};
	if (page == 1) {
		siv_draw_text(d, x, y, w, SIV_STR("Terms"), SIV_DESC(siv_text_style_desc, .font_size = 20, .weight = SIV_FONT_WEIGHT_BOLD, .color = ink));
		siv_draw_text(d, x, y + 36, w, SIV_STR("Payment is due within 30 days. Thank you for your business."), SIV_DESC(siv_text_style_desc, .font_size = 12, .color = ink));
		return;
	}
	siv_draw_rect(d, (siv_rect){x, y, w, 6});
	siv_draw_fill(d, SIV_DESC(siv_paint_desc, .color = accent), 0);
	siv_draw_text(d, x, y + 20, w, SIV_STR("Invoice 2026-041"), SIV_DESC(siv_text_style_desc, .font_size = 28, .weight = SIV_FONT_WEIGHT_BOLD, .color = ink));
	siv_draw_text(d, x, y + 60, w, SIV_STR("Northwind Studio, for Example Press"), SIV_DESC(siv_text_style_desc, .font_size = 12, .color = muted));
	float row = y + 110;
	for (size_t i = 0; i < 3; i++, row += 28) {
		siv_draw_text(d, x, row, w, items[i][0], strlen(items[i][0]), SIV_DESC(siv_text_style_desc, .font_size = 13, .color = ink));
		siv_draw_text(d, x, row, w, items[i][1], strlen(items[i][1]), SIV_DESC(siv_text_style_desc, .font_size = 13, .color = ink, .align = SIV_TEXT_ALIGN_END));
	}
	siv_draw_move_to(d, x, row + 4);
	siv_draw_line_to(d, x + w, row + 4);
	siv_draw_stroke(d, SIV_DESC(siv_stroke_desc, .width = 1), SIV_DESC(siv_paint_desc, .color = muted));
	siv_draw_text(d, x, row + 16, w, SIV_STR("Total  $3,910.00"), SIV_DESC(siv_text_style_desc, .font_size = 16, .weight = SIV_FONT_WEIGHT_BOLD, .color = ink, .align = SIV_TEXT_ALIGN_END));
}

/* The preview: the same page, scaled to the canvas. */
static void draw_preview(void *user_data, siv_node node, siv_draw d, float width, float height) {
	(void)node;
	(void)height;
	float scale = width / A4_WIDTH;
	siv_draw_rect(d, (siv_rect){0, 0, width, A4_HEIGHT * scale});
	siv_draw_fill(d, SIV_DESC(siv_paint_desc, .color = {1, 1, 1, 1}), 0);
	siv_draw_push_transform(d, (siv_affine){.a = scale, .d = scale});
	siv_page_setup a4 = {.size = sizeof a4, .width = A4_WIDTH, .height = A4_HEIGHT, .margin_top = 56, .margin_right = 56, .margin_bottom = 56, .margin_left = 56};
	draw_page(user_data, d, 0, &a4);
	siv_draw_pop(d);
}

static siv_size measure_preview(void *user_data, siv_node node, const siv_constraints *c) {
	(void)user_data;
	(void)node;
	float width = c->max_width < 240 ? c->max_width : 240;
	return (siv_size){width, width * A4_HEIGHT / A4_WIDTH};
}

static void set_status(struct doc *doc, const char *text) {
	siv_txn txn;
	if (siv_txn_begin(doc->window, &txn) != SIV_OK) return;
	siv_set_text(txn, doc->status, text, strlen(text));
	commit(txn);
}

/* done runs at a safe point once the document went out, or did not. */
static void on_exported(void *user_data, const siv_portal_result *result) {
	struct doc *doc = user_data;
	char text[320];
	if (result->response == SIV_PORTAL_RESPONSE_SUCCESS) snprintf(text, sizeof text, "Wrote %u pages to %s", (unsigned)result->count, doc->path);
	else snprintf(text, sizeof text, "Could not write %s", doc->path);
	set_status(doc, text);
}

static void on_printed(void *user_data, const siv_portal_result *result) {
	struct doc *doc = user_data;
	switch (result->response) {
	case SIV_PORTAL_RESPONSE_SUCCESS: set_status(doc, "Sent to the printer"); break;
	case SIV_PORTAL_RESPONSE_CANCELLED: set_status(doc, "Printing cancelled"); break;
	case SIV_PORTAL_RESPONSE_UNAVAILABLE: set_status(doc, "No print portal on this system"); break;
	default: set_status(doc, "Printing failed"); break;
	}
}

static siv_event_result on_export(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	(void)event;
	struct doc *doc = user_data;
	const char *dir = getenv("TMPDIR");
	snprintf(doc->path, sizeof doc->path, "%s/invoice.pdf", dir && *dir ? dir : "/tmp");
	int fd = open(doc->path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0) return SIV_EVENT_RESULT_PASS;
	/* siv duplicates the descriptor; pages are drawn at the next dispatch. */
	siv_result r = siv_pdf_write(doc->app, SIV_DESC(siv_print_desc, .title = SIV_STR("Invoice 2026-041"), .user_data = doc, .draw_page = draw_page, .done = on_exported, .page_count = 2, .margin = 56), fd);
	close(fd);
	return r == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
}

/* The system's dialog chooses the printer and the paper; the document is
 * laid out for its page setup and handed over as PDF. */
static siv_event_result on_print(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	struct doc *doc = user_data;
	siv_result r = siv_print(doc->app, event->window, SIV_DESC(siv_print_desc, .title = SIV_STR("Invoice 2026-041"), .user_data = doc, .draw_page = draw_page, .done = on_printed, .page_count = 2));
	return r == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
}

static siv_result build(struct doc *doc) {
	siv_txn txn;
	siv_result r = siv_txn_begin(doc->window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_get_root(doc->window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node row = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .gap = 16, .align_items = SIV_ALIGN_START));
	siv_set_layout(txn, row, SIV_DESC(siv_layout_desc, .padding = {16, 16, 16, 16}));
	siv_node preview = siv_canvas(txn, row, SIV_DESC(siv_canvas_desc, .user_data = doc, .draw = draw_preview, .measure = measure_preview));
	siv_set_semantics(txn, preview, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_IMAGE, .label = SIV_STR("Preview of the first page")));
	siv_set_visual(txn, preview, SIV_DESC(siv_visual_desc, .border_token = SIV_COLOR_TOKEN_BORDER, .border_width = 1));
	siv_node actions = siv_flex(txn, row, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 8, .align_items = SIV_ALIGN_START));
	siv_node export = siv_push_button(txn, actions, SIV_DESC(siv_button_desc, .label = SIV_STR("Export PDF"), .style = SIV_BUTTON_STYLE_PRIMARY));
	siv_node print = siv_push_button(txn, actions, SIV_DESC(siv_button_desc, .label = SIV_STR("Print…")));
	siv_on(txn, export, SIV_EVENT_TYPE_ACTIVATE, on_export, NULL, doc);
	siv_on(txn, print, SIV_EVENT_TYPE_ACTIVATE, on_print, NULL, doc);
	doc->status = siv_text(txn, actions, SIV_STR("Two pages, A4"));
	siv_set_layout(txn, doc->status, SIV_DESC(siv_layout_desc, .max_width = 160));
	siv_set_text_style(txn, doc->status, SIV_DESC(siv_text_style_desc, .size_role = SIV_SIZE_ROLE_CAPTION, .color_token = SIV_COLOR_TOKEN_MUTED_FG));
	return siv_txn_commit(txn);
}

int main(void) {
	struct doc doc = {0};
	siv_result r = siv_app_create(NULL, &doc.app);
	if (r != SIV_OK) {
		fprintf(stderr, "print: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(doc.app, SIV_DESC(siv_window_desc, .title = SIV_STR("Invoice"), .width = 440, .height = 372), &doc.window);
	if (r == SIV_OK) r = build(&doc);
	if (r == SIV_OK) r = siv_app_run(doc.app);
	if (r != SIV_OK) fprintf(stderr, "print: %s\n", siv_result_name(r));
	siv_app_destroy(doc.app);
	return r == SIV_OK ? 0 : 1;
}
