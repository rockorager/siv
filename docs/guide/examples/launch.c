/* A desktop application: one instance per session. The first launch
 * serves the application id on the session bus; later launches, the
 * launcher's D-Bus activation, and notification buttons reach it as
 * activations and actions. Install the files in packaging/ beside it.
 *
 *     zig build guide && ./zig-out/bin/guide-launch [FILE...]
 */
#include <siv.h>

#include <stdio.h>
#include <string.h>

#define S(str) (str), strlen(str)

struct notes {
	siv_app app;
	siv_window window;
	siv_node status;
};

static void show_status(struct notes *n, const char *text) {
	siv_txn txn;
	if (siv_txn_begin(n->window, &txn) != SIV_OK) return;
	siv_set_text(txn, n->status, S(text));
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "launch: %s\n", siv_result_name(r));
}

static siv_result create_window(struct notes *n) {
	/* Windows take the application id as their app id, which the
	 * compositor matches with the desktop file. */
	siv_result r = siv_window_create(n->app, SIV_DESC(siv_window_desc, .title = S("Notes"), .width = 320, .height = 120), &n->window);
	siv_txn txn;
	if (r == SIV_OK) r = siv_txn_begin(n->window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_root(n->window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	n->status = siv_text(txn, root, S("Ready"));
	siv_set_layout(txn, n->status, SIV_DESC(siv_layout_desc, .align_x = SIV_ALIGN_CENTER, .align_y = SIV_ALIGN_CENTER));
	siv_set_text_style(txn, n->status, SIV_DESC(siv_text_style_desc, .size_role = SIV_SIZE_ROLE_HEADING, .color_token = SIV_COLOR_TOKEN_WINDOW_FG));
	return siv_txn_commit(txn);
}

/* Every activation comes here, at a safe point: this launch's, another
 * instance's, or the desktop's. Show the window, then hand the
 * activation token to the compositor so that the window may take focus. */
static void on_activate(void *user_data, siv_app app, const siv_activation *activation) {
	(void)app;
	struct notes *n = user_data;
	if (!n->window && create_window(n) != SIV_OK) return;
	if (activation->type == SIV_ACTIVATION_TYPE_OPEN) {
		char text[64];
		snprintf(text, sizeof text, "Opened %zu file%s", activation->uris_count, activation->uris_count == 1 ? "" : "s");
		show_status(n, text);
	}
	siv_result r = siv_window_activate(n->window, activation->activation_token, activation->activation_token_len);
	if (r != SIV_OK) fprintf(stderr, "launch: %s\n", siv_result_name(r));
}

/* An application action: a notification button or a desktop file action
 * named new-note invokes it. */
static void on_new_note(void *user_data, const siv_action_event *event) {
	(void)event;
	struct notes *n = user_data;
	if (n->window) show_status(n, "New note");
}

int main(int argc, char **argv) {
	struct notes n = {0};
	/* The D-Bus service file starts the program with --service: then it
	 * waits for the desktop's call instead of activating itself. */
	bool service = argc > 1 && strcmp(argv[1], "--service") == 0;
	siv_uri uris[16];
	size_t count = 0;
	for (int i = service ? 2 : 1; i < argc && count < 16; i++) uris[count++] = (siv_uri){S(argv[i])};

	siv_result r = siv_app_create(SIV_DESC(siv_app_desc, .app_id = S("org.example.Notes"), .name = S("Notes")), &n.app);
	if (r != SIV_OK) {
		fprintf(stderr, "launch: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_app_add_action(n.app, S("new-note"), on_new_note, NULL, &n);
	if (r == SIV_OK) r = siv_app_launch(n.app, SIV_DESC(siv_launch_desc, .uris = uris, .uris_count = count, .on_activate = on_activate, .user_data = &n, .flags = service ? SIV_LAUNCH_SERVICE : 0, .idle_timeout_ms = 10000));
	/* A second instance forwards its activation and returns at once. */
	if (r == SIV_OK) r = siv_app_run(n.app);
	if (r != SIV_OK) fprintf(stderr, "launch: %s\n", siv_result_name(r));
	siv_app_destroy(n.app);
	return r == SIV_OK ? 0 : 1;
}
