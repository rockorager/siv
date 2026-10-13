/* A window with a heading and a button that counts its clicks.
 *
 *     zig build examples && ./zig-out/bin/hello
 *
 * Closing the window ends siv_run: an unhandled close request destroys the
 * window, and siv_run returns once no window is left. */
#include <siv.h>

#include <stdio.h>

struct counter {
	siv_node label;
	int clicks;
};

/* Runs on the application's thread when the button is clicked or
 * activated from the keyboard. Changes to the tree go through a
 * transaction; they are shown at the next frame. */
static siv_event_result on_click(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	struct counter *c = user_data;
	char text[32];
	int len = snprintf(text, sizeof text, "Clicked %d time%s", ++c->clicks, c->clicks == 1 ? "" : "s");
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_set_text(txn, c->label, text, (size_t)len);
	return siv_txn_commit(txn) == SIV_OK;
}

int main(void) {
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_app_create: %s\n", siv_result_name(r));
		return 1;
	}
	siv_window window;
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = "Hello", .title_len = 5, .width = 320, .height = 200), &window);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_window_create: %s\n", siv_result_name(r));
		siv_app_destroy(app);
		return 1;
	}

	/* Build the tree in one transaction. Operations are not checked one
	 * by one: the first failure makes the rest do nothing, and commit
	 * reports it and discards the whole transaction. */
	struct counter counter = {0};
	siv_txn txn;
	r = siv_txn_begin(window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_root(window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background = {1, 1, 1, 1}));
		siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 16, .align_items = SIV_ALIGN_START));
		siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {24, 24, 24, 24}));

		siv_node heading = siv_text(txn, column, "Hello from C", 12);
		siv_set_text_style(txn, heading, SIV_DESC(siv_text_style_desc, .font_size = 24, .weight = SIV_FONT_WEIGHT_BOLD));
		siv_set_semantics(txn, heading, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_HEADING));

		siv_node button = siv_box(txn, column);
		siv_set_layout(txn, button, SIV_DESC(siv_layout_desc, .padding = {16, 16, 8, 8}));
		siv_set_visual(txn, button, SIV_DESC(siv_visual_desc, .background = {0.15f, 0.39f, 0.92f, 1}, .radius = {8, 8, 8, 8}));
		/* A focusable button: Tab reaches it, Enter and Space activate it. */
		siv_set_semantics(txn, button, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_BUTTON, .flags = SIV_SEMANTICS_FOCUSABLE));
		siv_on(txn, button, SIV_EVENT_TYPE_ACTIVATE, on_click, NULL, &counter);
		siv_node caption = siv_text(txn, button, "Click me", 8);
		siv_set_text_style(txn, caption, SIV_DESC(siv_text_style_desc, .color = {1, 1, 1, 1}));

		counter.label = siv_text(txn, column, "Not clicked yet", 15);
		r = siv_txn_commit(txn);
	}
	if (r != SIV_OK) {
		fprintf(stderr, "building the window failed: %s\n", siv_result_name(r));
		siv_app_destroy(app);
		return 1;
	}

	r = siv_run(app);
	if (r != SIV_OK) fprintf(stderr, "siv_run: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
