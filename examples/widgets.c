/* A settings form built from stock widgets (D22), in the desktop's theme.
 *
 *     zig build examples && ./zig-out/bin/widgets
 *
 * Widgets are created with builders inside a transaction like any node,
 * driven with siv_widget_set_value and friends, and report what the user
 * did through siv_on handlers on the node the builder returned. */
#include <siv.h>

#include <stdio.h>
#include <string.h>

#define S(str) str, strlen(str)

struct form {
	siv_node volume_label;
	siv_node progress;
};

/* Every widget with a value reports it in event->value; choices also put
 * the chosen index in event->index. */
static siv_event_result on_volume(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	struct form *f = user_data;
	char text[32];
	int len = snprintf(text, sizeof text, "Volume: %.0f", event->value);
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_set_text(txn, f->volume_label, text, (size_t)len);
	/* Setting a value from the application does not report a change. */
	siv_widget_set_value(txn, f->progress, event->value);
	return siv_txn_commit(txn) == SIV_OK;
}

static siv_event_result on_change(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	printf("%s: %g (index %u)\n", (const char *)user_data, event->value, event->index);
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_dark(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	siv_app app = *(siv_app *)user_data;
	/* The theme follows the desktop unless the application chooses. */
	return siv_app_set_theme(app, SIV_DESC(siv_theme_desc, .scheme = event->value != 0 ? SIV_COLOR_SCHEME_DARK : SIV_COLOR_SCHEME_FOLLOW)) == SIV_OK;
}

static siv_event_result on_save(void *user_data, siv_node node, const siv_event *event) {
	(void)user_data;
	(void)node;
	(void)event;
	puts("saved");
	return SIV_EVENT_RESULT_HANDLED;
}

int main(void) {
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_app_create: %s\n", siv_result_name(r));
		return 1;
	}
	siv_window window;
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = S("Settings"), .width = 420, .height = 520), &window);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_window_create: %s\n", siv_result_name(r));
		siv_app_destroy(app);
		return 1;
	}

	struct form form = {0};
	siv_txn txn;
	r = siv_txn_begin(window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_root(window);
		/* Themed colors follow the desktop's scheme, contrast, and accent. */
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
		siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 14, .align_items = SIV_ALIGN_START));
		siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {24, 24, 24, 24}));

		siv_node title = siv_text(txn, column, S("Settings"));
		siv_set_text_style(txn, title, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_WINDOW_FG, .size_role = SIV_TEXT_ROLE_TITLE, .weight = SIV_FONT_WEIGHT_BOLD));
		siv_set_semantics(txn, title, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_HEADING));

		siv_node name = siv_text_field(txn, column, SIV_DESC(siv_text_field_desc, .placeholder = S("Your name")));
		siv_on(txn, name, SIV_EVENT_TYPE_CHANGE, on_change, NULL, "name");

		siv_node dark = siv_switch(txn, column, SIV_DESC(siv_toggle_desc, .label = S("Dark theme")));
		siv_on(txn, dark, SIV_EVENT_TYPE_CHANGE, on_dark, NULL, &app);
		siv_node updates = siv_check_box(txn, column, SIV_DESC(siv_toggle_desc, .label = S("Install updates automatically"), .checked = SIV_TOGGLE_ON));
		siv_on(txn, updates, SIV_EVENT_TYPE_CHANGE, on_change, NULL, "updates");

		siv_node quality = siv_radio_group(txn, column, SIV_DESC(siv_radio_group_desc, .label = S("Quality"), .axis = SIV_AXIS_COLUMN));
		siv_radio(txn, quality, SIV_DESC(siv_radio_desc, .label = "Low", .label_len = 3));
		siv_radio(txn, quality, SIV_DESC(siv_radio_desc, .label = "Balanced", .label_len = 8));
		siv_radio(txn, quality, SIV_DESC(siv_radio_desc, .label = "High", .label_len = 4));
		siv_widget_set_value(txn, quality, 1);
		siv_on(txn, quality, SIV_EVENT_TYPE_CHANGE, on_change, NULL, "quality");

		form.volume_label = siv_text(txn, column, S("Volume: 40"));
		siv_set_text_style(txn, form.volume_label, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG, .size_role = SIV_TEXT_ROLE_CAPTION));
		siv_node volume = siv_slider(txn, column, SIV_DESC(siv_range_desc, .label = S("Volume"), .value = 40, .step = 1));
		siv_set_layout(txn, volume, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 260}));
		siv_on(txn, volume, SIV_EVENT_TYPE_CHANGE, on_volume, NULL, &form);
		form.progress = siv_progress_bar(txn, column, SIV_DESC(siv_range_desc, .label = S("Level"), .value = 40));
		siv_set_layout(txn, form.progress, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 260}));

		siv_node copies = siv_spin_button(txn, column, SIV_DESC(siv_range_desc, .label = S("Copies"), .min = 1, .max = 10, .value = 1));
		siv_on(txn, copies, SIV_EVENT_TYPE_CHANGE, on_change, NULL, "copies");

		siv_node buttons = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .gap = 8));
		siv_push_button(txn, buttons, SIV_DESC(siv_button_desc, .label = S("Cancel")));
		siv_node save = siv_push_button(txn, buttons, SIV_DESC(siv_button_desc, .label = S("Save"), .style = SIV_BUTTON_STYLE_PRIMARY));
		siv_on(txn, save, SIV_EVENT_TYPE_ACTIVATE, on_save, NULL, NULL);
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
