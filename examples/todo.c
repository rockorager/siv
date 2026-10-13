/* A to-do list: an editor whose Enter key adds an item to a scrolling
 * list, a live count of the editor's text, and items that remove
 * themselves when clicked.
 *
 *     zig build examples && ./zig-out/bin/todo
 */
#include <siv.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>


struct app {
	siv_window window;
	siv_node editor;
	siv_node list;
	siv_node status;
	int items;
};

static const siv_color ink = {0.09f, 0.09f, 0.11f, 1};
static const siv_color muted = {0.44f, 0.44f, 0.48f, 1};

/* Clicking an item removes it. Its user data is freed by the
 * destroy-notify once the item's node is gone. */
static siv_event_result on_item_click(void *user_data, siv_node node, const siv_event *event) {
	struct app *a = *(struct app **)user_data;
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_remove(txn, node);
	a->items--;
	return siv_txn_commit(txn) == SIV_OK;
}

static void free_item(void *user_data) { free(user_data); }

static void add_item(struct app *a, siv_txn txn, const char *text, size_t len) {
	siv_node row = siv_box(txn, a->list);
	siv_set_layout(txn, row, SIV_DESC(siv_layout_desc, .padding = {8, 8, 6, 6}));
	siv_set_visual(txn, row, SIV_DESC(siv_visual_desc, .background = {0.96f, 0.96f, 0.97f, 1}, .radius = {4, 4, 4, 4}));
	siv_set_semantics(txn, row, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_LIST_ITEM, .flags = SIV_SEMANTICS_FOCUSABLE));
	struct app **ref = malloc(sizeof *ref);
	if (ref) {
		*ref = a;
		siv_on(txn, row, SIV_EVENT_TYPE_ACTIVATE, on_item_click, free_item, ref);
	}
	siv_node label = siv_text(txn, row, text, len);
	siv_set_text_style(txn, label, SIV_DESC(siv_text_style_desc, .color = ink));
	a->items++;
}

/* Enter in the editor adds its text as an item and clears it. */
static siv_event_result on_editor_key(void *user_data, siv_node node, const siv_event *event) {
	struct app *a = user_data;
	if (event->keysym != SIV_KEY_RETURN || !(event->flags & SIV_EVENT_PRESSED)) return SIV_EVENT_RESULT_PASS;
	char text[256];
	size_t len = 0;
	if (siv_node_get_text(node, text, sizeof text, &len) != SIV_OK || len == 0) return SIV_EVENT_RESULT_HANDLED;
	if (len > sizeof text) len = sizeof text;
	siv_txn txn;
	if (siv_txn_begin(a->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_HANDLED;
	add_item(a, txn, text, len);
	siv_set_text(txn, node, "", 0);
	siv_set_text(txn, a->status, "", 0);
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "adding an item failed: %s\n", siv_result_name(r));
	return SIV_EVENT_RESULT_HANDLED;
}

/* The editor's change event carries its new text. */
static siv_event_result on_editor_change(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	struct app *a = user_data;
	char status[64];
	int n = snprintf(status, sizeof status, "%zu bytes typed", event->text_len);
	siv_txn txn;
	if (siv_txn_begin(a->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_set_text(txn, a->status, status, (size_t)n);
	return siv_txn_commit(txn) == SIV_OK;
}

int main(void) {
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_app_create: %s\n", siv_result_name(r));
		return 1;
	}
	struct app a = {0};
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = "To do", .title_len = 5, .app_id = "dev.siv.examples.todo", .app_id_len = 21, .width = 360, .height = 420), &a.window);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_window_create: %s\n", siv_result_name(r));
		siv_app_destroy(app);
		return 1;
	}

	siv_txn txn;
	r = siv_txn_begin(a.window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_root(a.window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background = {1, 1, 1, 1}));
		siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 10));
		siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {16, 16, 16, 16}, .height = {SIV_UNIT_FRACTION, 1}));

		siv_node title = siv_text(txn, column, "To do", 5);
		siv_set_text_style(txn, title, SIV_DESC(siv_text_style_desc, .font_size = 22, .weight = SIV_FONT_WEIGHT_SEMIBOLD, .color = ink));
		siv_set_semantics(txn, title, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_HEADING));

		a.editor = siv_editor(txn, column, 0);
		siv_set_layout(txn, a.editor, SIV_DESC(siv_layout_desc, .padding = {6, 6, 4, 4}));
		siv_set_visual(txn, a.editor, SIV_DESC(siv_visual_desc, .border_color = {0.63f, 0.63f, 0.67f, 1}, .border_width = 1, .radius = {4, 4, 4, 4}));
		siv_set_semantics(txn, a.editor, SIV_DESC(siv_semantics_desc, .label = "New item", .label_len = 8));
		siv_on(txn, a.editor, SIV_EVENT_TYPE_KEY, on_editor_key, NULL, &a);
		siv_on(txn, a.editor, SIV_EVENT_TYPE_CHANGE, on_editor_change, NULL, &a);

		a.status = siv_text(txn, column, "Type and press Enter", 20);
		siv_set_text_style(txn, a.status, SIV_DESC(siv_text_style_desc, .font_size = 12, .color = muted));

		/* The list scrolls on the compositor thread; it takes the space
		 * the column has left. */
		siv_node scroll = siv_scroll(txn, column, SIV_SCROLL_AXIS_VERTICAL);
		siv_set_layout(txn, scroll, SIV_DESC(siv_layout_desc, .grow = 1, .basis = {SIV_UNIT_PX, 0}));
		a.list = siv_flex(txn, scroll, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 4));
		siv_set_semantics(txn, a.list, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_LIST));
		add_item(&a, txn, "Click an item to remove it", 26);
		r = siv_txn_commit(txn);
	}
	if (r == SIV_OK) r = siv_node_focus(a.editor);
	if (r == SIV_OK) r = siv_run(app);
	if (r != SIV_OK) fprintf(stderr, "todo: %s\n", siv_result_name(r));
	/* Destroying the application releases every remaining item. */
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
