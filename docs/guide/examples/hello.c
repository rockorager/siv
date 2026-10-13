/* The guide's first program: a window with a title, a button, and a label
 * that counts the button's clicks.
 *
 *     cc hello.c $(pkg-config --cflags --libs siv) -o hello && ./hello
 */
#include <siv.h>

#include <stdio.h>
#include <string.h>

/* A string literal or other C string as the pointer and length siv takes. */
#define S(str) (str), strlen(str)

struct counter {
	siv_node label;
	int clicks;
};

/* Runs on the application's thread when the button is clicked, or
 * activated with Enter, Space, or a screen reader. */
static siv_event_result on_click(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	struct counter *counter = user_data;
	counter->clicks++;
	char text[32];
	snprintf(text, sizeof text, "Clicked %d time%s", counter->clicks, counter->clicks == 1 ? "" : "s");
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_set_text(txn, counter->label, S(text));
	return siv_txn_commit(txn) == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
}

int main(void) {
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "hello: %s\n", siv_result_name(r));
		return 1;
	}
	siv_window window = 0;
	struct counter counter = {0};
	siv_txn txn = 0;
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = S("Hello"), .width = 320, .height = 160), &window);
	if (r == SIV_OK) r = siv_txn_begin(window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_root(window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
		siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 12, .align_items = SIV_ALIGN_START));
		siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {24, 24, 24, 24}));

		siv_node title = siv_text(txn, column, S("Hello, siv"));
		siv_set_text_style(txn, title, SIV_DESC(siv_text_style_desc, .size_role = SIV_SIZE_ROLE_TITLE, .weight = SIV_FONT_WEIGHT_BOLD, .color_token = SIV_COLOR_TOKEN_WINDOW_FG));
		siv_set_semantics(txn, title, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_HEADING, .level = 1));

		siv_node button = siv_push_button(txn, column, SIV_DESC(siv_button_desc, .label = S("Click me"), .style = SIV_BUTTON_STYLE_PRIMARY));
		siv_on(txn, button, SIV_EVENT_TYPE_ACTIVATE, on_click, NULL, &counter);

		counter.label = siv_text(txn, column, S("Not clicked yet"));
		siv_set_text_style(txn, counter.label, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_WINDOW_FG));
		/* Nothing above was checked: the first failure would have made
		 * the rest do nothing, and commit reports it. */
		r = siv_txn_commit(txn);
	}
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "hello: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
