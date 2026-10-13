/* Tooltips and a combo box: icon-only buttons that show their label in a
 * tooltip, a button with a tooltip of its own, and a combo box that picks
 * an export format.
 *
 *     zig build guide && ./zig-out/bin/guide-export
 */
#include <siv.h>

#include <stdio.h>
#include <string.h>

struct app_state {
	siv_window window;
	siv_node status;
};

/* The combo box reports the chosen option's index as value and index. */
static siv_event_result on_format(void *user_data, siv_node combo, const siv_event *event) {
	(void)combo;
	static const char *const formats[] = {"PNG", "JPEG", "WebP", "AVIF"};
	struct app_state *s = user_data;
	char text[64];
	snprintf(text, sizeof text, "Format: %s", event->index < 4 ? formats[event->index] : "?");
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_set_text(txn, s->status, text, strlen(text));
	if (siv_txn_commit(txn) != SIV_OK) fprintf(stderr, "export: the status did not change\n");
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_result build(struct app_state *s) {
	siv_txn txn;
	siv_result r = siv_txn_begin(s->window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_get_root(s->window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 16, .align_items = SIV_ALIGN_START));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {16, 16, 16, 16}));

	/* An icon-only button's label names it for screen readers and shows
	 * in its tooltip; any node can have a tooltip of its own. */
	siv_node toolbar = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .gap = 8));
	siv_set_semantics(txn, toolbar, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_TOOLBAR, .label = SIV_STR("Export")));
	siv_push_button(txn, toolbar, SIV_DESC(siv_button_desc, .label = SIV_STR("Copy"), .icon = SIV_STR("edit-copy-symbolic"), .style = SIV_BUTTON_STYLE_FLAT, .flags = SIV_WIDGET_ICON_ONLY));
	siv_push_button(txn, toolbar, SIV_DESC(siv_button_desc, .label = SIV_STR("Next page"), .icon = SIV_STR("go-next-symbolic"), .style = SIV_BUTTON_STYLE_FLAT, .flags = SIV_WIDGET_ICON_ONLY));
	siv_node save = siv_push_button(txn, toolbar, SIV_DESC(siv_button_desc, .label = SIV_STR("Export"), .style = SIV_BUTTON_STYLE_PRIMARY));
	siv_set_tooltip(txn, save, SIV_STR("Saves a copy in the chosen format"));

	/* A combo box's options are nodes added one by one; its value is the
	 * selected option's index. */
	siv_node format = siv_combo_box(txn, column, SIV_DESC(siv_combo_box_desc, .label = SIV_STR("Format")));
	siv_combo_box_item(txn, format, SIV_DESC(siv_combo_box_item_desc, .label = SIV_STR("PNG")));
	siv_combo_box_item(txn, format, SIV_DESC(siv_combo_box_item_desc, .label = SIV_STR("JPEG")));
	siv_combo_box_item(txn, format, SIV_DESC(siv_combo_box_item_desc, .label = SIV_STR("WebP")));
	siv_combo_box_item(txn, format, SIV_DESC(siv_combo_box_item_desc, .label = SIV_STR("AVIF"), .flags = SIV_WIDGET_DISABLED));
	siv_on(txn, format, SIV_EVENT_TYPE_CHANGE, on_format, NULL, s);

	s->status = siv_text(txn, column, SIV_STR("Format: PNG"));
	siv_set_text_style(txn, s->status, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG));
	return siv_txn_commit(txn);
}

int main(void) {
	struct app_state s = {0};
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "export: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = SIV_STR("Export"), .width = 360, .height = 240), &s.window);
	if (r == SIV_OK) r = build(&s);
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "export: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
