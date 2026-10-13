/* siv inside a program that owns its event loop (D6): the program polls
 * siv's file descriptor next to its own (here, standard input) and calls
 * siv_app_dispatch(app, 0) when it is readable. A worker thread hands the
 * time to the UI with siv_post, the one call that is safe from any thread.
 *
 *     zig build examples && ./zig-out/bin/embed
 *
 * Lines typed on standard input replace the window's message; end of
 * input or closing the window quits. */
#include <siv.h>

#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct ui {
	siv_window window;
	siv_node clock;
	siv_node message;
	bool open;
};

static void set_text(struct ui *ui, siv_node node, const char *text, size_t len) {
	siv_txn txn;
	if (siv_txn_begin(ui->window, &txn) != SIV_OK) return;
	siv_set_text(txn, node, text, len);
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "embed: %s\n", siv_result_name(r));
}

/* Posted work owns a heap copy of the time; destroy frees it whether or
 * not the work ran. */
struct tick {
	struct ui *ui;
	char text[32];
};

static void on_tick(void *user_data) {
	struct tick *t = user_data;
	if (t->ui->open) set_text(t->ui, t->ui->clock, t->text, strlen(t->text));
}

static void free_tick(void *user_data) { free(user_data); }

struct worker {
	siv_app app;
	struct ui *ui;
	atomic_bool stop;
};

static void *clock_thread(void *arg) {
	struct worker *w = arg;
	while (!atomic_load(&w->stop)) {
		struct tick *t = malloc(sizeof *t);
		if (t) {
			time_t now = time(NULL);
			t->ui = w->ui;
			strftime(t->text, sizeof t->text, "%H:%M:%S", localtime(&now));
			if (siv_post(w->app, on_tick, free_tick, t) != SIV_OK) free(t);
		}
		sleep(1);
	}
	return NULL;
}

static bool on_window_event(void *user_data, siv_window window, const siv_window_event *event) {
	(void)window;
	struct ui *ui = user_data;
	if (event->type == SIV_WINDOW_EVENT_TYPE_CLOSE_REQUESTED) ui->open = false;
	return false;
}

int main(void) {
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_app_create: %s\n", siv_result_name(r));
		return 1;
	}
	struct ui ui = {.open = true};
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = "Embedded", .title_len = 8, .width = 300, .height = 140, .on_event = on_window_event, .user_data = &ui), &ui.window);
	siv_txn txn;
	if (r == SIV_OK) r = siv_txn_begin(ui.window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_root(ui.window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background = {0.1f, 0.1f, 0.12f, 1}));
		siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 8, .align_items = SIV_ALIGN_CENTER, .justify = SIV_JUSTIFY_CENTER));
		siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
		ui.clock = siv_text(txn, column, "--:--:--", 8);
		siv_set_text_style(txn, ui.clock, SIV_DESC(siv_text_style_desc, .font_size = 32, .color = {1, 1, 1, 1}, .family = "monospace", .family_len = 9));
		siv_set_semantics(txn, ui.clock, SIV_DESC(siv_semantics_desc, .flags = SIV_SEMANTICS_LIVE_POLITE));
		ui.message = siv_text(txn, column, "Type a line in the terminal", 27);
		siv_set_text_style(txn, ui.message, SIV_DESC(siv_text_style_desc, .color = {0.7f, 0.7f, 0.75f, 1}));
		r = siv_txn_commit(txn);
	}
	if (r != SIV_OK) {
		fprintf(stderr, "embed: %s\n", siv_result_name(r));
		siv_app_destroy(app);
		return 1;
	}

	struct worker worker = {.app = app, .ui = &ui};
	pthread_t thread;
	pthread_create(&thread, NULL, clock_thread, &worker);

	int fd;
	if (siv_app_get_fd(app, &fd) != SIV_OK) return 1;
	struct pollfd fds[2] = {{.fd = fd, .events = POLLIN}, {.fd = STDIN_FILENO, .events = POLLIN}};
	while (ui.open) {
		if (poll(fds, 2, -1) < 0) break;
		if (fds[0].revents & POLLIN) {
			r = siv_app_dispatch(app, 0);
			if (r != SIV_OK) {
				fprintf(stderr, "siv_app_dispatch: %s\n", siv_result_name(r));
				break;
			}
		}
		if (fds[1].revents & (POLLIN | POLLHUP)) {
			char line[256];
			if (!fgets(line, sizeof line, stdin)) break;
			set_text(&ui, ui.message, line, strcspn(line, "\n"));
		}
	}

	atomic_store(&worker.stop, true);
	pthread_join(thread, NULL);
	/* Ticks posted but not yet run are freed by their destroy-notify. */
	siv_app_destroy(app);
	return 0;
}
