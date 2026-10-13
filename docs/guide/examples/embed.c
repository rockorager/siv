/* siv inside a program that owns its event loop: the host polls siv's
 * file descriptor next to its own (here a timerfd that ticks once a
 * second) and calls siv_app_dispatch(app, 0) whenever it is readable.
 *
 *     zig build guide && ./zig-out/bin/guide-embed
 */
#include <siv.h>

#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/timerfd.h>
#include <unistd.h>


struct host {
	siv_window window;
	siv_node ticks;
	unsigned count;
	bool open;
};

static bool on_window_event(void *user_data, siv_window window, const siv_window_event *event) {
	(void)window;
	struct host *host = user_data;
	if (event->type == SIV_WINDOW_EVENT_TYPE_CLOSE_REQUESTED) host->open = false;
	return false;
}

/* The host's own work. It may call siv freely: it runs on the thread that
 * created the application, between dispatches. */
static void tick(struct host *host) {
	char text[32];
	snprintf(text, sizeof text, "Host ticks: %u", ++host->count);
	siv_txn txn;
	if (siv_txn_begin(host->window, &txn) != SIV_OK) return;
	siv_set_text(txn, host->ticks, text, strlen(text));
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "embed: %s\n", siv_result_name(r));
}

int main(void) {
	struct host host = {.open = true};
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "embed: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = SIV_STR("Embedded"), .width = 280, .height = 120, .on_event = on_window_event, .user_data = &host), &host.window);
	siv_txn txn;
	if (r == SIV_OK) r = siv_txn_begin(host.window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_get_root(host.window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
		host.ticks = siv_text(txn, root, SIV_STR("Host ticks: 0"));
		siv_set_layout(txn, host.ticks, SIV_DESC(siv_layout_desc, .align_x = SIV_ALIGN_CENTER, .align_y = SIV_ALIGN_CENTER));
		siv_set_text_style(txn, host.ticks, SIV_DESC(siv_text_style_desc, .size_role = SIV_SIZE_ROLE_HEADING, .color_token = SIV_COLOR_TOKEN_WINDOW_FG));
		r = siv_txn_commit(txn);
	}
	int siv_fd = -1;
	if (r == SIV_OK) r = siv_app_get_fd(app, &siv_fd);
	if (r != SIV_OK) {
		fprintf(stderr, "embed: %s\n", siv_result_name(r));
		siv_app_destroy(app);
		return 1;
	}

	int timer = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
	timerfd_settime(timer, 0, &(struct itimerspec){.it_interval = {1, 0}, .it_value = {1, 0}}, NULL);

	/* The host's loop. siv's descriptor stays readable while siv has work
	 * pending, so dispatching with a timeout of 0 when it is readable is
	 * all siv needs. */
	struct pollfd fds[] = {{.fd = siv_fd, .events = POLLIN}, {.fd = timer, .events = POLLIN}};
	while (host.open) {
		if (poll(fds, 2, -1) < 0) break;
		if (fds[0].revents & POLLIN) {
			r = siv_app_dispatch(app, 0);
			if (r != SIV_OK) break;
		}
		if (fds[1].revents & POLLIN) {
			uint64_t expirations;
			if (read(timer, &expirations, sizeof expirations) == sizeof expirations) tick(&host);
		}
	}
	if (r != SIV_OK) fprintf(stderr, "embed: %s\n", siv_result_name(r));
	close(timer);
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
