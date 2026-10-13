/* The siv side of bench/gpui-compare: one program, one scenario per run.
 *
 *     siv-bench idle|gallery|list|text|grid|typing
 *
 * Every scenario is mirrored by gpui/src/main.rs; README.md lists what
 * each shows and the differences that remain. */
#include <siv.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../common/doc.h"

#define S(str) str, strlen(str)

static siv_color rgb(uint32_t v) {
	return (siv_color){((v >> 16) & 0xff) / 255.0f, ((v >> 8) & 0xff) / 255.0f, (v & 0xff) / 255.0f, 1};
}

static siv_node column(siv_txn txn, siv_node parent, float gap, float pad) {
	siv_node c = siv_flex(txn, parent, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = gap, .align_items = SIV_ALIGN_START));
	siv_set_layout(txn, c, SIV_DESC(siv_layout_desc, .padding = {pad, pad, pad, pad}, .align_y = SIV_ALIGN_START));
	return c;
}

/* Idle ------------------------------------------------------------------------ */

static void build_idle(siv_txn txn, siv_node root) {
	siv_node c = column(txn, root, 0, 24);
	siv_text(txn, c, S("Idle window"));
}

/* Gallery --------------------------------------------------------------------- */

static siv_node status;

static void set_status(siv_window window, const char *what) {
	char text[96];
	int len = snprintf(text, sizeof text, "Last action: %s", what);
	siv_txn txn;
	if (siv_txn_begin(window, &txn) != SIV_OK) return;
	siv_set_text(txn, status, text, (size_t)len);
	if (siv_txn_commit(txn) != SIV_OK) fprintf(stderr, "status update failed\n");
}

static siv_event_result on_button(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	set_status(event->window, user_data);
	return SIV_EVENT_RESULT_HANDLED;
}

static const char *menu_items[] = {"New", "Open", "Save", "Save As", "Close", "Quit"};

static siv_event_result on_menu(void *user_data, siv_node node, const siv_event *event) {
	(void)user_data, (void)node;
	set_status(event->window, menu_items[event->index % 6]);
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_list_select(void *user_data, siv_node node, const siv_event *event) {
	(void)user_data, (void)node;
	char what[32];
	snprintf(what, sizeof what, "Item %u", event->index + 1);
	set_status(event->window, what);
	return SIV_EVENT_RESULT_HANDLED;
}

static void bind_item(void *user_data, siv_txn txn, siv_node row, uint64_t item, uint32_t index, uint32_t depth, bool recycled) {
	(void)user_data, (void)item, (void)depth;
	char text[32];
	int len = snprintf(text, sizeof text, "Item %u", index + 1);
	siv_node label = 0;
	if (recycled && siv_node_get_related(row, SIV_RELATION_FIRST_CHILD, &label) == SIV_OK && label) {
		siv_set_text(txn, label, text, (size_t)len);
		return;
	}
	siv_text(txn, row, text, (size_t)len);
}

static siv_node build_gallery(siv_txn txn, siv_node root) {
	siv_node c = column(txn, root, 14, 24);
	siv_node title = siv_text(txn, c, S("Widget gallery"));
	siv_set_text_style(txn, title, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_WINDOW_FG, .size_role = SIV_SIZE_ROLE_TITLE, .weight = SIV_FONT_WEIGHT_BOLD));

	siv_node buttons = siv_flex(txn, c, SIV_DESC(siv_flex_desc, .gap = 8));
	siv_node b = siv_push_button(txn, buttons, SIV_DESC(siv_button_desc, .label = S("Default")));
	siv_on(txn, b, SIV_EVENT_TYPE_ACTIVATE, on_button, NULL, "Default");
	b = siv_push_button(txn, buttons, SIV_DESC(siv_button_desc, .label = S("Primary"), .style = SIV_BUTTON_STYLE_PRIMARY));
	siv_on(txn, b, SIV_EVENT_TYPE_ACTIVATE, on_button, NULL, "Primary");
	siv_push_button(txn, buttons, SIV_DESC(siv_button_desc, .label = S("Disabled"), .flags = SIV_WIDGET_DISABLED));
	siv_node menu = siv_menu_button(txn, buttons, SIV_DESC(siv_button_desc, .label = S("Menu")));
	for (int i = 0; i < 6; i++) siv_menu_item(txn, menu, SIV_DESC(siv_menu_item_desc, .label = S(menu_items[i])));
	siv_on(txn, menu, SIV_EVENT_TYPE_SELECT, on_menu, NULL, NULL);

	siv_node field = siv_text_field(txn, c, SIV_DESC(siv_text_field_desc, .placeholder = S("Type here")));
	siv_set_layout(txn, field, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 320}));

	siv_node check = siv_check_box(txn, c, SIV_DESC(siv_toggle_desc, .label = S("Enable feature")));
	siv_on(txn, check, SIV_EVENT_TYPE_CHANGE, on_button, NULL, "Toggled");

	/* Views draw their own frame: view background, border, radius 6. */
	siv_node list = siv_list_view(txn, c, SIV_DESC(siv_view_desc, .label = S("Items"), .bind = bind_item, .count = 50, .item_height = 32,
	                                               .selection = SIV_SELECTION_MODE_SINGLE));
	siv_set_layout(txn, list, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 320}, .height = {SIV_UNIT_PX, 320}, .max_height = 320));
	siv_on(txn, list, SIV_EVENT_TYPE_SELECT, on_list_select, NULL, NULL);

	status = siv_text(txn, c, S("Last action: none"));
	siv_set_text_style(txn, status, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG, .size_role = SIV_SIZE_ROLE_BODY));
	return field;
}

/* 100k-row list ------------------------------------------------------------------- */

static void bind_row(void *user_data, siv_txn txn, siv_node row, uint64_t item, uint32_t index, uint32_t depth, bool recycled) {
	(void)user_data, (void)item, (void)depth;
	char name[32], desc[96];
	int nlen = snprintf(name, sizeof name, "Row %u", index + 1);
	int dlen = snprintf(desc, sizeof desc, "Description of row %u with a few more words", index + 1);
	siv_node flex = 0, first = 0, second = 0;
	if (recycled && siv_node_get_related(row, SIV_RELATION_FIRST_CHILD, &flex) == SIV_OK && flex &&
	    siv_node_get_related(flex, SIV_RELATION_FIRST_CHILD, &first) == SIV_OK && first &&
	    siv_node_get_related(first, SIV_RELATION_NEXT, &second) == SIV_OK && second) {
		siv_set_text(txn, first, name, (size_t)nlen);
		siv_set_text(txn, second, desc, (size_t)dlen);
		return;
	}
	/* The view pads each row by 8 at both ends; rows are boxes. */
	flex = siv_flex(txn, row, SIV_DESC(siv_flex_desc, .gap = 12, .align_items = SIV_ALIGN_CENTER));
	siv_node a = siv_text(txn, flex, name, (size_t)nlen);
	siv_set_layout(txn, a, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 100}));
	siv_node b = siv_text(txn, flex, desc, (size_t)dlen);
	siv_set_text_style(txn, b, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG, .size_role = SIV_SIZE_ROLE_BODY));
}

static void build_list(siv_txn txn, siv_node root) {
	siv_node list = siv_list_view(txn, root, SIV_DESC(siv_view_desc, .label = S("Rows"), .bind = bind_row, .count = 100000, .item_height = 28));
	siv_set_layout(txn, list, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
}

/* Text: an editable document -------------------------------------------------------- */

static siv_node build_editor(siv_txn txn, siv_node root, size_t paragraphs) {
	size_t len = 0;
	char *doc = doc_generate(paragraphs, &len);
	siv_node scroll = siv_scroll(txn, root, SIV_SCROLL_AXIS_VERTICAL);
	siv_set_layout(txn, scroll, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
	siv_node editor = siv_editor(txn, scroll, SIV_EDITOR_MULTILINE);
	siv_set_layout(txn, editor, SIV_DESC(siv_layout_desc, .padding = {24, 24, 24, 24}, .width = {SIV_UNIT_FRACTION, 1}));
	siv_set_text_style(txn, editor, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_VIEW_FG, .size_role = SIV_SIZE_ROLE_BODY, .line_height = DOC_LINE_HEIGHT));
	siv_set_text(txn, editor, doc, len);
	siv_set_selection(txn, editor, 0, 0);
	free(doc);
	return editor;
}

/* Grid of animated cells ------------------------------------------------------------- */

static void build_grid(siv_txn txn, siv_node root) {
	siv_node wrap = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .gap = 4, .flags = SIV_FLEX_WRAP));
	siv_set_layout(txn, wrap, SIV_DESC(siv_layout_desc, .padding = {2, 2, 2, 2}, .grow = 1));
	for (int i = 0; i < GRID_COLS * GRID_ROWS; i++) {
		siv_node cell = siv_box(txn, wrap);
		siv_set_layout(txn, cell, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 16}, .height = {SIV_UNIT_PX, 16}));
		siv_set_visual(txn, cell, SIV_DESC(siv_visual_desc, .background = rgb(grid_color(i)), .radius = {3, 3, 3, 3}));
		siv_set_animation(txn, cell, SIV_DESC(siv_animation_desc, .property = SIV_ANIMATION_PROPERTY_OPACITY, .easing = SIV_EASING_EASE_IN_OUT,
		                                      .from = 1, .to = 0.2f, .duration_ms = GRID_PERIOD_MS, .delay_ms = grid_delay_ms(i),
		                                      .flags = SIV_ANIMATION_ALTERNATE));
	}
}

int main(int argc, char **argv) {
	const char *scenario = argc > 1 ? argv[1] : "idle";
	bool grid = strcmp(scenario, "grid") == 0;
	siv_app_flags flags = SIV_APP_NO_DESKTOP_SETTINGS | (grid ? 0 : SIV_APP_REDUCED_MOTION);
	siv_app app;
	siv_result r = siv_app_create(SIV_DESC(siv_app_desc, .flags = flags, .name = S("siv-bench"), .app_id = S("siv-bench")), &app);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_app_create: %s\n", siv_result_name(r));
		return 1;
	}
	if (siv_app_set_default_font(app, S(BENCH_FONT)) != SIV_OK) fprintf(stderr, "font %s not set\n", BENCH_FONT);
	char title[64];
	snprintf(title, sizeof title, "bench %s", scenario);
	siv_window window;
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = S(title), .width = 1280, .height = 800), &window);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_window_create: %s\n", siv_result_name(r));
		return 1;
	}
	siv_node focus = 0;
	siv_txn txn;
	r = siv_txn_begin(window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_root(window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
		if (strcmp(scenario, "idle") == 0) build_idle(txn, root);
		else if (strcmp(scenario, "gallery") == 0) focus = build_gallery(txn, root);
		else if (strcmp(scenario, "list") == 0) build_list(txn, root);
		else if (strcmp(scenario, "text") == 0) focus = build_editor(txn, root, DOC_LARGE_PARAGRAPHS);
		else if (strcmp(scenario, "typing") == 0) focus = build_editor(txn, root, DOC_SMALL_PARAGRAPHS);
		else if (grid) build_grid(txn, root);
		else {
			fprintf(stderr, "unknown scenario %s\n", scenario);
			return 2;
		}
		r = siv_txn_commit(txn);
	}
	if (r == SIV_OK && focus) r = siv_node_focus(focus);
	if (r != SIV_OK) {
		fprintf(stderr, "building the window failed: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_app_run(app);
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
