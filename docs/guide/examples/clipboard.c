/* Clipboard and drag and drop: copy and paste text, a tile that drags a
 * note out, and a drop target that takes text from any application.
 *
 *     zig build guide && ./zig-out/bin/guide-clipboard
 */
#include <siv.h>

#include <math.h>
#include <stdio.h>
#include <string.h>


static void commit(siv_txn txn) {
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "siv_txn_commit: %s\n", siv_result_name(r));
}

#define TEXT_MIME "text/plain;charset=utf-8"

struct ui {
	siv_window window;
	siv_node field;
	siv_node pasted;
	siv_node target;
	siv_node dropped;
	float press_x, press_y;
	bool pressed;
};

static void set_text(struct ui *ui, siv_node node, const char *text, size_t len) {
	siv_txn txn;
	if (siv_txn_begin(ui->window, &txn) != SIV_OK) return;
	siv_set_text(txn, node, text, len);
	commit(txn);
}

/* Copy: Wayland hands out the clipboard only in answer to input, so this
 * runs from the button's activate handler. */
static siv_event_result on_copy(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	struct ui *ui = user_data;
	char text[256];
	size_t len = 0;
	if (siv_node_get_text(ui->field, text, sizeof text, &len) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	if (len > sizeof text) len = sizeof text;
	siv_result r = siv_clipboard_write(event->window, SIV_SELECTION_CLIPBOARD, text, len);
	return r == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
}

/* Paste: the text arrives later, in the dispatch phase, never inside
 * siv_clipboard_read. NULL means the clipboard held no text. */
static void on_pasted(void *user_data, const char *text, size_t len) {
	struct ui *ui = user_data;
	char line[300];
	int n = text ? snprintf(line, sizeof line, "Pasted: %.*s", (int)len, text) : snprintf(line, sizeof line, "Nothing to paste");
	set_text(ui, ui->pasted, line, (size_t)n < sizeof line ? (size_t)n : sizeof line - 1);
}

static siv_event_result on_paste(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	siv_result r = siv_clipboard_read(event->window, SIV_SELECTION_CLIPBOARD, on_pasted, NULL, user_data);
	return r == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
}

/* A drag starts once the pointer moved a few pixels with the button held. */
static siv_event_result on_tile_pointer(void *user_data, siv_node tile, const siv_event *event) {
	struct ui *ui = user_data;
	if (event->phase == SIV_POINTER_PHASE_DOWN && event->button == SIV_POINTER_BUTTON_PRIMARY) {
		ui->pressed = true;
		ui->press_x = event->x, ui->press_y = event->y;
	} else if (event->phase == SIV_POINTER_PHASE_UP || event->phase == SIV_POINTER_PHASE_CANCEL) {
		ui->pressed = false;
	} else if (event->phase == SIV_POINTER_PHASE_MOVE && ui->pressed && hypotf(event->x - ui->press_x, event->y - ui->press_y) > 4) {
		ui->pressed = false;
		const char *note = "A note dragged from siv";
		siv_result r = siv_drag_start(tile, SIV_DESC(siv_drag_desc, .mimes = TEXT_MIME, strlen(TEXT_MIME), .data = (const uint8_t *)note, .data_count = strlen(note), .actions = SIV_DRAG_ALLOW_COPY));
		return r == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
	}
	return SIV_EVENT_RESULT_PASS;
}

static void highlight(struct ui *ui, bool on) {
	siv_txn txn;
	if (siv_txn_begin(ui->window, &txn) != SIV_OK) return;
	siv_set_visual(txn, ui->target, SIV_DESC(siv_visual_desc, .background_token = on ? SIV_COLOR_TOKEN_SELECTION_BG : SIV_COLOR_TOKEN_VIEW_BG, .border_token = on ? SIV_COLOR_TOKEN_ACCENT : SIV_COLOR_TOKEN_BORDER, .border_width = 2, .radius = {8, 8, 8, 8}));
	commit(txn);
}

/* Drops do not bubble: the nearest target under the pointer decides.
 * Returning true from enter or move takes the drag; from drop, the data. */
static siv_event_result on_drop(void *user_data, siv_node target, const siv_event *event) {
	(void)target;
	struct ui *ui = user_data;
	switch (event->phase) {
	case SIV_POINTER_PHASE_ENTER:
		highlight(ui, true);
		return SIV_EVENT_RESULT_HANDLED;
	case SIV_POINTER_PHASE_MOVE:
		return SIV_EVENT_RESULT_HANDLED;
	case SIV_POINTER_PHASE_LEAVE:
		highlight(ui, false);
		return SIV_EVENT_RESULT_PASS;
	case SIV_POINTER_PHASE_DROP: {
		highlight(ui, false);
		char line[300];
		int n = snprintf(line, sizeof line, "Dropped: %.*s", (int)event->data_count, (const char *)event->data);
		set_text(ui, ui->dropped, line, (size_t)n < sizeof line ? (size_t)n : sizeof line - 1);
		return SIV_EVENT_RESULT_HANDLED;
	}
	default:
		return SIV_EVENT_RESULT_PASS;
	}
}

static siv_result build(struct ui *ui) {
	siv_txn txn;
	siv_result r = siv_txn_begin(ui->window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_get_root(ui->window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 12));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .padding = {16, 16, 16, 16}));

	siv_node row = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .gap = 8, .align_items = SIV_ALIGN_CENTER));
	ui->field = siv_text_field(txn, row, SIV_DESC(siv_text_field_desc, .label = SIV_STR("Text to copy"), .text = SIV_STR("Hello from siv")));
	siv_set_layout(txn, ui->field, SIV_DESC(siv_layout_desc, .grow = 1));
	siv_node copy = siv_push_button(txn, row, SIV_DESC(siv_button_desc, .label = SIV_STR("Copy")));
	siv_node paste = siv_push_button(txn, row, SIV_DESC(siv_button_desc, .label = SIV_STR("Paste")));
	siv_on(txn, copy, SIV_EVENT_TYPE_ACTIVATE, on_copy, NULL, ui);
	siv_on(txn, paste, SIV_EVENT_TYPE_ACTIVATE, on_paste, NULL, ui);
	ui->pasted = siv_text(txn, column, SIV_STR("Nothing pasted yet"));
	siv_set_text_style(txn, ui->pasted, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG));

	siv_node pair = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .gap = 12));
	siv_node tile = siv_box(txn, pair);
	siv_set_layout(txn, tile, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 120}, .padding = {12, 12, 24, 24}));
	siv_set_visual(txn, tile, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_CONTROL_BG, .border_token = SIV_COLOR_TOKEN_BORDER, .border_width = 1, .radius = {8, 8, 8, 8}));
	siv_set_cursor(txn, tile, SIV_CURSOR_GRAB);
	siv_on(txn, tile, SIV_EVENT_TYPE_POINTER, on_tile_pointer, NULL, ui);
	siv_node tile_text = siv_text(txn, tile, SIV_STR("Drag me"));
	siv_set_text_style(txn, tile_text, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_CONTROL_FG, .align = SIV_TEXT_ALIGN_CENTER));

	ui->target = siv_box(txn, pair);
	siv_set_layout(txn, ui->target, SIV_DESC(siv_layout_desc, .grow = 1, .padding = {12, 12, 24, 24}));
	siv_set_drop_target(txn, ui->target, SIV_DESC(siv_drop_target_desc, .mimes = TEXT_MIME "\ntext/plain", strlen(TEXT_MIME "\ntext/plain"), .actions = SIV_DRAG_ALLOW_COPY));
	siv_on(txn, ui->target, SIV_EVENT_TYPE_DROP, on_drop, NULL, ui);
	siv_set_semantics(txn, ui->target, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_GROUP, .label = SIV_STR("Drop area")));
	siv_node hint = siv_text(txn, ui->target, SIV_STR("Drop text here"));
	siv_set_text_style(txn, hint, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG, .align = SIV_TEXT_ALIGN_CENTER));
	ui->dropped = siv_text(txn, column, SIV_STR("Nothing dropped yet"));
	siv_set_text_style(txn, ui->dropped, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG));
	r = siv_txn_commit(txn);
	if (r == SIV_OK) highlight(ui, false);
	return r;
}

int main(void) {
	struct ui ui = {0};
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "clipboard: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = SIV_STR("Clipboard"), .width = 420, .height = 240), &ui.window);
	if (r == SIV_OK) r = build(&ui);
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "clipboard: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
