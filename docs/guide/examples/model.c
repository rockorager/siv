/* siv's model in one program: a tree built and changed in transactions,
 * handlers that run at safe points on the application's thread, a worker
 * thread that hands its result over with siv_post, and a close request
 * the application answers with a dialog.
 *
 *     zig build guide && ./zig-out/bin/guide-model
 */
#include <siv.h>

#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define S(str) (str), strlen(str)

/* Commits a transaction made in a handler. There is nothing to undo when
 * one fails (siv discarded it), so report it and go on. */
static void commit(siv_txn txn) {
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "siv_txn_commit: %s\n", siv_result_name(r));
}

struct notes {
	siv_app app;
	siv_window window;
	siv_node root;
	siv_node status;
	siv_node dialog;
	bool dirty;
};

static void set_status(struct notes *notes, const char *text) {
	siv_txn txn;
	if (siv_txn_begin(notes->window, &txn) != SIV_OK) return;
	siv_set_text(txn, notes->status, S(text));
	commit(txn);
}

/* A worker thread ----------------------------------------------------- */

/* What the worker hands over. siv_post's destroy-notify frees it whether
 * or not the callback ran: if the application is destroyed first, only
 * free runs. */
struct loaded {
	struct notes *notes;
	char text[64];
};

static void on_loaded(void *user_data) {
	struct loaded *loaded = user_data;
	set_status(loaded->notes, loaded->text);
}

static void *load_notes(void *arg) {
	struct notes *notes = arg;
	struct loaded *loaded = malloc(sizeof *loaded);
	if (!loaded) return NULL;
	loaded->notes = notes;
	snprintf(loaded->text, sizeof loaded->text, "Loaded %d notes on a worker thread", 3);
	/* The one siv call that is safe from any thread. */
	if (siv_post(notes->app, on_loaded, free, loaded) != SIV_OK) free(loaded);
	return NULL;
}

/* Handlers ------------------------------------------------------------- */

static siv_event_result on_edit(void *user_data, siv_node editor, const siv_event *event) {
	(void)editor;
	(void)event;
	struct notes *notes = user_data;
	notes->dirty = true;
	set_status(notes, "Edited");
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_discard(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	(void)event;
	struct notes *notes = user_data;
	/* The last window going ends siv_app_run. */
	siv_window_destroy(notes->window);
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_keep(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	struct notes *notes = user_data;
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_remove(txn, notes->dialog);
	commit(txn);
	return SIV_EVENT_RESULT_HANDLED;
}

/* Escape or a click on the scrim: the dialog's default handler removes
 * it, since this handler passes. */
static siv_event_result on_dialog_close(void *user_data, siv_node dialog, const siv_event *event) {
	(void)dialog;
	(void)event;
	struct notes *notes = user_data;
	notes->dialog = 0;
	return SIV_EVENT_RESULT_PASS;
}

static void ask_to_discard(struct notes *notes) {
	siv_txn txn;
	if (notes->dialog || siv_txn_begin(notes->window, &txn) != SIV_OK) return;
	notes->dialog = siv_dialog(txn, notes->root, SIV_DESC(siv_dialog_desc, .title = S("Discard the note?"), .text = S("Your changes have not been saved.")));
	siv_node actions = 0;
	if (siv_widget_get_part(notes->dialog, SIV_WIDGET_PART_ACTIONS, 0, &actions) != SIV_OK) siv_txn_fail(txn, SIV_ERROR_INVALID_ARGUMENT);
	siv_node keep = siv_push_button(txn, actions, SIV_DESC(siv_button_desc, .label = S("Keep editing")));
	siv_node discard = siv_push_button(txn, actions, SIV_DESC(siv_button_desc, .label = S("Discard"), .style = SIV_BUTTON_STYLE_DESTRUCTIVE));
	siv_on(txn, keep, SIV_EVENT_TYPE_ACTIVATE, on_keep, NULL, notes);
	siv_on(txn, discard, SIV_EVENT_TYPE_ACTIVATE, on_discard, NULL, notes);
	siv_on(txn, notes->dialog, SIV_EVENT_TYPE_CLOSE, on_dialog_close, NULL, notes);
	if (siv_txn_commit(txn) != SIV_OK) notes->dialog = 0;
}

/* Window events: returning true from a close request keeps the window. */
static bool on_window_event(void *user_data, siv_window window, const siv_window_event *event) {
	(void)window;
	struct notes *notes = user_data;
	if (event->type == SIV_WINDOW_EVENT_TYPE_CLOSE_REQUESTED && notes->dirty) {
		ask_to_discard(notes);
		return true;
	}
	return false;
}

/* Building the window --------------------------------------------------- */

static siv_result build(struct notes *notes) {
	siv_txn txn;
	siv_result r = siv_txn_begin(notes->window, &txn);
	if (r != SIV_OK) return r;
	notes->root = siv_window_root(notes->window);
	siv_set_visual(txn, notes->root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, notes->root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 8));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}, .padding = {16, 16, 16, 16}));
	siv_node editor = siv_text_field(txn, column, SIV_DESC(siv_text_field_desc, .label = S("Note"), .placeholder = S("Write something"), .flags = SIV_TEXT_FIELD_MULTILINE));
	siv_set_layout(txn, editor, SIV_DESC(siv_layout_desc, .grow = 1));
	siv_on(txn, editor, SIV_EVENT_TYPE_CHANGE, on_edit, NULL, notes);
	notes->status = siv_text(txn, column, S("Loading…"));
	siv_set_text_style(txn, notes->status, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG, .size_role = SIV_SIZE_ROLE_CAPTION));
	r = siv_txn_commit(txn);
	/* Focus is not part of a transaction: the editor exists once the
	 * commit returns. */
	if (r == SIV_OK) r = siv_node_focus(editor);
	return r;
}

int main(void) {
	struct notes notes = {0};
	siv_result r = siv_app_create(NULL, &notes.app);
	if (r != SIV_OK) {
		fprintf(stderr, "model: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(notes.app, SIV_DESC(siv_window_desc, .title = S("Notes"), .width = 360, .height = 240, .on_event = on_window_event, .user_data = &notes), &notes.window);
	if (r == SIV_OK) r = build(&notes);
	pthread_t worker;
	bool started = r == SIV_OK && pthread_create(&worker, NULL, load_notes, &notes) == 0;
	if (r == SIV_OK) r = siv_app_run(notes.app);
	if (started) pthread_join(worker, NULL);
	if (r != SIV_OK) fprintf(stderr, "model: %s\n", siv_result_name(r));
	siv_app_destroy(notes.app);
	return r == SIV_OK ? 0 : 1;
}
