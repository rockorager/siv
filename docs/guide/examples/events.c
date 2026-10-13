/* Events and focus: window-wide shortcuts on the root that typing in a
 * field does not trigger, tiles that move focus with the arrow keys
 * (mirrored right to left), hover feedback, a pointer cursor, and a
 * context menu at the click.
 *
 *     zig build guide && ./zig-out/bin/guide-events
 */
#include <siv.h>

#include <stdio.h>
#include <string.h>

#define S(str) (str), strlen(str)

/* Commits a transaction made in a handler. There is nothing to undo when
 * one fails (siv discarded it), so report it and go on. */
static void commit(siv_txn txn) {
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "siv_txn_commit: %s\n", siv_result_name(r));
}

/* A node's neighbor, or 0. */
static siv_node related(siv_node node, siv_relation which) {
	siv_node out = 0;
	return siv_node_get_related(node, which, &out) == SIV_OK ? out : 0;
}

/* Moves keyboard focus; a node that cannot take it is left alone. */
static void focus(siv_node node) {
	if (siv_node_focus(node) != SIV_OK) fprintf(stderr, "events: cannot focus that\n");
}

struct ui {
	siv_window window;
	siv_node search;
	siv_node tiles;
	siv_node menu;
	siv_node status;
};

static void set_status(struct ui *ui, const char *text) {
	siv_txn txn;
	if (siv_txn_begin(ui->window, &txn) != SIV_OK) return;
	siv_set_text(txn, ui->status, S(text));
	commit(txn);
}

/* Keys start at the focused node and bubble up to the root. "/" anywhere
 * focuses the search field; Escape leaves it. */
static siv_event_result on_root_key(void *user_data, siv_node root, const siv_event *event) {
	(void)root;
	struct ui *ui = user_data;
	if (!(event->flags & SIV_EVENT_PRESSED)) return SIV_EVENT_RESULT_PASS;
	if (event->keysym == '/') {
		focus(ui->search);
		return SIV_EVENT_RESULT_HANDLED;
	}
	if (event->keysym == SIV_KEY_ESCAPE) {
		focus(related(ui->tiles, SIV_RELATION_FIRST_CHILD));
		return SIV_EVENT_RESULT_HANDLED;
	}
	return SIV_EVENT_RESULT_PASS;
}

/* Keys typed into the search field stop there, so "/" types a slash
 * instead of reaching the shortcut above; the editor still types them,
 * since stopping does not prevent the default action. Escape goes on. */
static siv_event_result on_search_key(void *user_data, siv_node search, const siv_event *event) {
	(void)user_data;
	(void)search;
	return event->keysym == SIV_KEY_ESCAPE ? SIV_EVENT_RESULT_PASS : SIV_EVENT_RESULT_STOP;
}

/* Left and Right move focus between the tiles, swapped right to left. */
static siv_event_result on_tiles_key(void *user_data, siv_node tiles, const siv_event *event) {
	(void)user_data;
	if (!(event->flags & SIV_EVENT_PRESSED) || (event->keysym != SIV_KEY_LEFT && event->keysym != SIV_KEY_RIGHT)) return SIV_EVENT_RESULT_PASS;
	bool rtl = false;
	if (siv_node_is_rtl(tiles, &rtl) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	bool forward = (event->keysym == SIV_KEY_RIGHT) != rtl;
	siv_node next = related(event->target, forward ? SIV_RELATION_NEXT : SIV_RELATION_PREVIOUS);
	if (next) focus(next);
	return SIV_EVENT_RESULT_HANDLED;
}

/* Hover: pointer enter and leave arrive on the node itself. A secondary
 * press opens the context menu where it happened. */
static siv_event_result on_tile_pointer(void *user_data, siv_node tile, const siv_event *event) {
	struct ui *ui = user_data;
	if (event->phase == SIV_POINTER_PHASE_ENTER || event->phase == SIV_POINTER_PHASE_LEAVE) {
		siv_txn txn;
		if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
		bool over = event->phase == SIV_POINTER_PHASE_ENTER;
		siv_set_visual(txn, tile, SIV_DESC(siv_visual_desc, .background_token = over ? SIV_COLOR_TOKEN_CONTROL_HOVER : SIV_COLOR_TOKEN_CONTROL_BG, .border_token = SIV_COLOR_TOKEN_BORDER, .border_width = 1, .radius = {8, 8, 8, 8}));
		commit(txn);
		return SIV_EVENT_RESULT_PASS;
	}
	if (event->phase == SIV_POINTER_PHASE_DOWN && event->button == SIV_POINTER_BUTTON_SECONDARY) {
		return siv_menu_open_at(ui->menu, tile, event->x, event->y) == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
	}
	return SIV_EVENT_RESULT_PASS;
}

static siv_event_result on_tile_activate(void *user_data, siv_node tile, const siv_event *event) {
	(void)event;
	char label[32], text[64];
	size_t len = 0;
	if (siv_node_get_label(tile, label, sizeof label, &len) != SIV_OK) len = 0;
	snprintf(text, sizeof text, "Opened %.*s", (int)(len < sizeof label ? len : sizeof label), label);
	set_status(user_data, text);
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_menu(void *user_data, siv_node menu, const siv_event *event) {
	(void)menu;
	set_status(user_data, event->index == 0 ? "Rename chosen" : "Remove chosen");
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_result build(struct ui *ui) {
	siv_txn txn;
	siv_result r = siv_txn_begin(ui->window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_root(ui->window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_on(txn, root, SIV_EVENT_TYPE_KEY, on_root_key, NULL, ui);
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 14));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .padding = {16, 16, 16, 16}));

	ui->search = siv_text_field(txn, column, SIV_DESC(siv_text_field_desc, .label = S("Search"), .placeholder = S("Search (press /)")));
	siv_on(txn, ui->search, SIV_EVENT_TYPE_KEY, on_search_key, NULL, ui);

	ui->tiles = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .gap = 10));
	siv_on(txn, ui->tiles, SIV_EVENT_TYPE_KEY, on_tiles_key, NULL, ui);
	const char *names[] = {"Inbox", "Drafts", "Archive"};
	for (int i = 0; i < 3; i++) {
		siv_node tile = siv_box(txn, ui->tiles);
		siv_set_layout(txn, tile, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 120}, .padding = {12, 12, 18, 18}));
		siv_set_visual(txn, tile, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_CONTROL_BG, .border_token = SIV_COLOR_TOKEN_BORDER, .border_width = 1, .radius = {8, 8, 8, 8}));
		/* Focusable with a role and a name: Tab reaches it, Enter and
		 * Space activate it, and a screen reader announces it. */
		siv_set_semantics(txn, tile, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_BUTTON, .label = S(names[i]), .flags = SIV_SEMANTICS_FOCUSABLE));
		siv_set_cursor(txn, tile, SIV_CURSOR_POINTER);
		siv_on(txn, tile, SIV_EVENT_TYPE_POINTER, on_tile_pointer, NULL, ui);
		siv_on(txn, tile, SIV_EVENT_TYPE_ACTIVATE, on_tile_activate, NULL, ui);
		siv_node text = siv_text(txn, tile, S(names[i]));
		siv_set_text_style(txn, text, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_CONTROL_FG, .align = SIV_TEXT_ALIGN_CENTER));
	}

	ui->menu = siv_menu(txn, column, SIV_DESC(siv_menu_desc, .label = S("Folder")));
	siv_menu_item(txn, ui->menu, SIV_DESC(siv_menu_item_desc, .label = S("Rename"), .shortcut = S("F2")));
	siv_menu_item(txn, ui->menu, SIV_DESC(siv_menu_item_desc, .label = S("Remove"), .shortcut = S("Delete")));
	siv_on(txn, ui->menu, SIV_EVENT_TYPE_SELECT, on_menu, NULL, ui);

	ui->status = siv_text(txn, column, S("Press Tab, the arrow keys, or /"));
	siv_set_text_style(txn, ui->status, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG));
	siv_set_semantics(txn, ui->status, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_STATUS, .flags = SIV_SEMANTICS_LIVE_POLITE));
	return siv_txn_commit(txn);
}

int main(void) {
	struct ui ui = {0};
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "events: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = S("Events"), .width = 440, .height = 240), &ui.window);
	if (r == SIV_OK) r = build(&ui);
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "events: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
