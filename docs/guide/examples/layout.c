/* Layout: an application window built from flex, grid, scroll, and stack
 * containers. A header bar, a sidebar of fixed width beside content that
 * takes the rest, a wrapping set of cards that scrolls, and a status line.
 *
 *     zig build guide && ./zig-out/bin/guide-layout
 */
#include <siv.h>

#include <stdio.h>
#include <string.h>


static siv_node label(siv_txn txn, siv_node parent, const char *text, siv_size_role role, siv_color_token color) {
	siv_node node = siv_text(txn, parent, text, strlen(text));
	siv_set_text_style(txn, node, SIV_DESC(siv_text_style_desc, .size_role = role, .color_token = color));
	return node;
}

/* The header: a title that grows to push the buttons to the end edge. */
static void header(siv_txn txn, siv_node parent) {
	siv_node bar = siv_flex(txn, parent, SIV_DESC(siv_flex_desc, .gap = 8, .align_items = SIV_ALIGN_CENTER));
	siv_set_layout(txn, bar, SIV_DESC(siv_layout_desc, .padding = {16, 12, 10, 10}));
	siv_set_visual(txn, bar, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_CARD_BG));
	siv_node title = label(txn, bar, "Projects", SIV_SIZE_ROLE_HEADING, SIV_COLOR_TOKEN_CARD_FG);
	siv_set_layout(txn, title, SIV_DESC(siv_layout_desc, .grow = 1));
	siv_set_semantics(txn, title, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_HEADING, .level = 1));
	siv_push_button(txn, bar, SIV_DESC(siv_button_desc, .label = SIV_STR("Share"), .style = SIV_BUTTON_STYLE_FLAT));
	siv_push_button(txn, bar, SIV_DESC(siv_button_desc, .label = SIV_STR("New project"), .style = SIV_BUTTON_STYLE_PRIMARY));
}

/* A card: a box with a background, a border, rounded corners, and
 * padding. Boxes stack their children and stretch them to their width. */
static void card(siv_txn txn, siv_node parent, const char *title, const char *detail) {
	siv_node box = siv_box(txn, parent);
	siv_set_layout(txn, box, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 180}, .padding = {12, 12, 10, 10}));
	siv_set_visual(txn, box, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_VIEW_BG, .border_token = SIV_COLOR_TOKEN_BORDER, .border_width = 1, .radius = {8, 8, 8, 8}));
	siv_set_semantics(txn, box, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_GROUP));
	label(txn, box, title, SIV_SIZE_ROLE_BODY, SIV_COLOR_TOKEN_VIEW_FG);
	label(txn, box, detail, SIV_SIZE_ROLE_CAPTION, SIV_COLOR_TOKEN_MUTED_FG);
}

static siv_result build(siv_window window) {
	siv_txn txn;
	siv_result r = siv_txn_begin(window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_get_root(window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));

	/* The window's root is a stack: its children overlay each other.
	 * One column fills it. */
	siv_node page = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN));
	siv_set_layout(txn, page, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
	header(txn, page);

	/* Two columns: 160 logical pixels, then the rest (1 fr). The grid
	 * grows to fill the column's height. */
	siv_track columns[] = {{SIV_TRACK_UNIT_PX, 160}, {SIV_TRACK_UNIT_FR, 1}};
	siv_node body = siv_grid(txn, page, SIV_DESC(siv_grid_desc, .columns = columns, .columns_count = 2));
	siv_set_layout(txn, body, SIV_DESC(siv_layout_desc, .grow = 1, .basis = {SIV_UNIT_PX, 0}));

	siv_node sidebar = siv_flex(txn, body, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 6));
	siv_set_layout(txn, sidebar, SIV_DESC(siv_layout_desc, .padding = {16, 16, 12, 12}));
	siv_set_semantics(txn, sidebar, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_GROUP, .label = SIV_STR("Filters")));
	const char *filters[] = {"All projects", "Starred", "Shared with me", "Archived"};
	for (size_t i = 0; i < 4; i++) label(txn, sidebar, filters[i], SIV_SIZE_ROLE_BODY, i == 0 ? SIV_COLOR_TOKEN_ACCENT : SIV_COLOR_TOKEN_WINDOW_FG);

	/* The content scrolls vertically; inside, cards wrap onto as many
	 * lines as the width allows. */
	siv_node scroll = siv_scroll(txn, body, SIV_SCROLL_AXIS_VERTICAL);
	siv_node cards = siv_flex(txn, scroll, SIV_DESC(siv_flex_desc, .gap = 12, .flags = SIV_FLEX_WRAP));
	siv_set_layout(txn, cards, SIV_DESC(siv_layout_desc, .padding = {12, 16, 12, 16}));
	card(txn, cards, "Website", "Updated today");
	card(txn, cards, "Mobile app", "3 open tasks");
	card(txn, cards, "Annual report", "Due Friday");
	card(txn, cards, "Onboarding", "Shared by Ana");
	card(txn, cards, "Brand refresh", "12 files");

	siv_node status = label(txn, page, "5 projects", SIV_SIZE_ROLE_CAPTION, SIV_COLOR_TOKEN_MUTED_FG);
	siv_set_layout(txn, status, SIV_DESC(siv_layout_desc, .padding = {16, 16, 6, 8}));

	/* A badge pinned near the window's bottom end corner, over the rest:
	 * a second child of the root stack, placed with insets. The root
	 * stretches its children, so the badge aligns to the end to keep its
	 * own size. */
	siv_node badge = label(txn, root, "Beta", SIV_SIZE_ROLE_CAPTION, SIV_COLOR_TOKEN_ACCENT_FG);
	siv_set_layout(txn, badge, SIV_DESC(siv_layout_desc, .padding = {8, 8, 2, 2}, .align_x = SIV_ALIGN_END, .align_y = SIV_ALIGN_END, .inset_end = 12, .inset_bottom = 8, .flags = SIV_LAYOUT_INSET_END | SIV_LAYOUT_INSET_BOTTOM));
	siv_set_visual(txn, badge, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_ACCENT, .radius = {6, 6, 6, 6}));
	return siv_txn_commit(txn);
}

int main(void) {
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "layout: %s\n", siv_result_name(r));
		return 1;
	}
	siv_window window;
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = SIV_STR("Projects"), .width = 640, .height = 360), &window);
	if (r == SIV_OK) r = build(window);
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "layout: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
