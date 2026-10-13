/* The application's own file descriptors in siv's loop: a child process's
 * output read from a pipe as it arrives, at safe points, without a thread
 * of the application's blocking on it.
 *
 *     zig build guide && ./zig-out/bin/guide-watch
 */
#include <siv.h>

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define S(str) (str), strlen(str)

/* Commits a transaction made in a handler. There is nothing to undo when
 * one fails (siv discarded it), so report it and go on. */
static void commit(siv_txn txn) {
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "siv_txn_commit: %s\n", siv_result_name(r));
}

extern char **environ;

struct log {
	siv_window window;
	siv_node text;
	siv_node status;
	int fd;
	pid_t child;
	char buf[4096];
	size_t len;
	unsigned lines;
};

static void update(struct log *log, const char *status) {
	siv_txn txn;
	if (siv_txn_begin(log->window, &txn) != SIV_OK) return;
	size_t len = log->len;
	if (len > 0 && log->buf[len - 1] == '\n') len--;
	siv_set_text(txn, log->text, log->buf, len);
	if (status) siv_set_text(txn, log->status, S(status));
	commit(txn);
}

/* Level-triggered: read until the pipe would block, or this runs again in
 * the next loop iteration. */
static void on_readable(void *user_data, siv_watch watch, siv_watch_flags events) {
	struct log *log = user_data;
	for (;;) {
		char chunk[512];
		ssize_t n = read(log->fd, chunk, sizeof chunk);
		if (n > 0) {
			for (ssize_t i = 0; i < n; i++) log->lines += chunk[i] == '\n';
			size_t room = sizeof log->buf - log->len;
			size_t take = (size_t)n < room ? (size_t)n : room;
			memcpy(log->buf + log->len, chunk, take);
			log->len += take;
			continue;
		}
		if (n < 0 && errno == EAGAIN && !(events & SIV_WATCH_HANGUP)) break;
		/* End of output: stop watching before closing the descriptor. */
		siv_watch_destroy(watch);
		close(log->fd);
		waitpid(log->child, NULL, 0);
		char status[64];
		snprintf(status, sizeof status, "Done: %u lines", log->lines);
		update(log, status);
		return;
	}
	update(log, NULL);
}

static int spawn(struct log *log) {
	int pipefd[2];
	if (pipe(pipefd) != 0) return -1;
	fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
	fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
	char *argv[] = {"sh", "-c", "for i in 1 2 3 4 5; do echo \"step $i of 5\"; done", NULL};
	int err = posix_spawnp(&log->child, "sh", &actions, NULL, argv, environ);
	posix_spawn_file_actions_destroy(&actions);
	close(pipefd[1]);
	if (err != 0) {
		close(pipefd[0]);
		return -1;
	}
	fcntl(pipefd[0], F_SETFL, O_NONBLOCK);
	return log->fd = pipefd[0];
}

int main(void) {
	struct log log = {0};
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "watch: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = S("Output"), .width = 320, .height = 200), &log.window);
	siv_txn txn;
	if (r == SIV_OK) r = siv_txn_begin(log.window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_root(log.window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
		siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 8));
		siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {16, 16, 16, 16}));
		log.text = siv_text(txn, column, NULL, 0);
		siv_set_text_style(txn, log.text, SIV_DESC(siv_text_style_desc, .family = S("monospace"), .color_token = SIV_COLOR_TOKEN_WINDOW_FG));
		log.status = siv_text(txn, column, S("Running…"));
		siv_set_text_style(txn, log.status, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG));
		r = siv_txn_commit(txn);
	}
	siv_watch watch;
	if (r == SIV_OK && spawn(&log) < 0) r = SIV_ERROR_UNAVAILABLE;
	if (r == SIV_OK) r = siv_app_watch_fd(app, log.fd, SIV_WATCH_READABLE, on_readable, NULL, &log, &watch);
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "watch: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
