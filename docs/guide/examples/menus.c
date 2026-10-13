/* Menus, popovers, and dialogs: a menu button with a check item and a
 * submenu, a popover with content of the application's own, and a modal
 * dialog that asks before deleting.
 *
 *     zig build guide && ./zig-out/bin/guide-menus
 */
#include <siv.h>

#include <stdio.h>
#include <string.h>


/* Commits a transaction made in a handler. There is nothing to undo when
 * one fails (siv discarded it), so report it and go on. */
static void commit(siv_txn txn) {
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "siv_txn_commit: %s\n", siv_result_name(r));
}

struct app_state {
	siv_window window;
	siv_node root;
	siv_node status;
	siv_node dialog;
};

static void set_status(struct app_state *s, const char *text) {
	siv_txn txn;
	if (siv_txn_begin(s->window, &txn) != SIV_OK) return;
	siv_set_text(txn, s->status, text, strlen(text));
	commit(txn);
}

/* Items report their position (separators count) on the menu button. */
static siv_event_result on_file(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	static const char *const chosen[] = {"New", "Open…", NULL, "Show hidden files"};
	char text[64];
	snprintf(text, sizeof text, "Chose %s", event->index < 4 && chosen[event->index] ? chosen[event->index] : "?");
	set_status(user_data, text);
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_sort(void *user_data, siv_node submenu, const siv_event *event) {
	(void)submenu;
	set_status(user_data, event->index == 0 ? "Sorted by name" : "Sorted by date");
	return SIV_EVENT_RESULT_HANDLED;
}

/* A popover is a popup window with a themed card: build its content in a
 * transaction on the popup, then show it while handling the click. */
static siv_event_result on_info(void *user_data, siv_node button, const siv_event *event) {
	(void)user_data;
	(void)event;
	siv_window popup;
	siv_node content;
	if (siv_popover_create(button, SIV_DESC(siv_popover_desc, .label = SIV_STR("Details")), &popup, &content) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_txn txn;
	if (siv_txn_begin(popup, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_node text = siv_text(txn, content, SIV_STR("Last saved 2 minutes ago"));
	siv_set_text_style(txn, text, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_CARD_FG));
	siv_check_box(txn, content, SIV_DESC(siv_toggle_desc, .label = SIV_STR("Save automatically"), .checked = SIV_TOGGLE_ON));
	siv_result r = siv_txn_commit(txn);
	if (r == SIV_OK) r = siv_popup_show(popup);
	if (r != SIV_OK) fprintf(stderr, "menus: %s\n", siv_result_name(r));
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_confirm(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	struct app_state *s = user_data;
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_remove(txn, s->dialog);
	siv_set_text(txn, s->status, SIV_STR("Deleted “Draft”"));
	commit(txn);
	s->dialog = 0;
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_cancel(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	struct app_state *s = user_data;
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_remove(txn, s->dialog);
	commit(txn);
	s->dialog = 0;
	return SIV_EVENT_RESULT_HANDLED;
}

/* Escape and clicks on the scrim: passing lets the default remove it. */
static siv_event_result on_dialog_close(void *user_data, siv_node dialog, const siv_event *event) {
	(void)dialog;
	(void)event;
	((struct app_state *)user_data)->dialog = 0;
	return SIV_EVENT_RESULT_PASS;
}

/* A dialog is an overlay in the window's own tree: a child of the root
 * stack, modal while it exists. */
static siv_event_result on_delete(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	struct app_state *s = user_data;
	siv_txn txn;
	if (s->dialog || siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	s->dialog = siv_dialog(txn, s->root, SIV_DESC(siv_dialog_desc, .title = SIV_STR("Delete “Draft”?"), .text = SIV_STR("It will be gone for good.")));
	siv_node actions = siv_widget_get_part(s->dialog, SIV_WIDGET_PART_ACTIONS, 0);
	siv_node cancel = siv_push_button(txn, actions, SIV_DESC(siv_button_desc, .label = SIV_STR("Cancel")));
	siv_node confirm = siv_push_button(txn, actions, SIV_DESC(siv_button_desc, .label = SIV_STR("Delete"), .style = SIV_BUTTON_STYLE_DESTRUCTIVE));
	siv_on(txn, cancel, SIV_EVENT_TYPE_ACTIVATE, on_cancel, NULL, s);
	siv_on(txn, confirm, SIV_EVENT_TYPE_ACTIVATE, on_confirm, NULL, s);
	siv_on(txn, s->dialog, SIV_EVENT_TYPE_CLOSE, on_dialog_close, NULL, s);
	if (siv_txn_commit(txn) != SIV_OK) s->dialog = 0;
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_result build(struct app_state *s) {
	siv_txn txn;
	siv_result r = siv_txn_begin(s->window, &txn);
	if (r != SIV_OK) return r;
	s->root = siv_window_get_root(s->window);
	siv_set_visual(txn, s->root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, s->root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 16));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {16, 16, 16, 16}));
	siv_node toolbar = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .gap = 8));
	siv_set_semantics(txn, toolbar, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_TOOLBAR, .label = SIV_STR("Document")));

	/* A menu button holds its items; a submenu is a menu of its own,
	 * placed anywhere in the tree (it takes no space). */
	siv_node file = siv_menu_button(txn, toolbar, SIV_DESC(siv_button_desc, .label = SIV_STR("File")));
	siv_node sort = siv_menu(txn, toolbar, SIV_DESC(siv_menu_desc, .label = SIV_STR("Sort by")));
	siv_menu_item(txn, sort, SIV_DESC(siv_menu_item_desc, .label = SIV_STR("Name")));
	siv_menu_item(txn, sort, SIV_DESC(siv_menu_item_desc, .label = SIV_STR("Date")));
	siv_on(txn, sort, SIV_EVENT_TYPE_SELECT, on_sort, NULL, s);
	siv_menu_item(txn, file, SIV_DESC(siv_menu_item_desc, .label = SIV_STR("New"), .shortcut = SIV_STR("Ctrl+N"), .icon = SIV_STR("document-new")));
	siv_menu_item(txn, file, SIV_DESC(siv_menu_item_desc, .label = SIV_STR("Open…"), .shortcut = SIV_STR("Ctrl+O"), .mnemonic = 'o'));
	siv_menu_item(txn, file, SIV_DESC(siv_menu_item_desc, .flags = SIV_MENU_ITEM_SEPARATOR));
	siv_menu_item(txn, file, SIV_DESC(siv_menu_item_desc, .label = SIV_STR("Show hidden files"), .flags = SIV_MENU_ITEM_CHECKABLE));
	siv_menu_item(txn, file, SIV_DESC(siv_menu_item_desc, .label = SIV_STR("Sort by"), .submenu = sort));
	siv_on(txn, file, SIV_EVENT_TYPE_SELECT, on_file, NULL, s);

	siv_node info = siv_push_button(txn, toolbar, SIV_DESC(siv_button_desc, .label = SIV_STR("Details")));
	siv_on(txn, info, SIV_EVENT_TYPE_ACTIVATE, on_info, NULL, s);
	siv_node del = siv_push_button(txn, toolbar, SIV_DESC(siv_button_desc, .label = SIV_STR("Delete…"), .style = SIV_BUTTON_STYLE_DESTRUCTIVE));
	siv_on(txn, del, SIV_EVENT_TYPE_ACTIVATE, on_delete, NULL, s);

	s->status = siv_text(txn, column, SIV_STR("Nothing chosen yet"));
	siv_set_text_style(txn, s->status, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG));
	return siv_txn_commit(txn);
}

int main(void) {
	struct app_state s = {0};
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "menus: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = SIV_STR("Menus"), .width = 420, .height = 280), &s.window);
	if (r == SIV_OK) r = build(&s);
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "menus: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
