/* Work off the UI thread: a job on siv's worker pool counts primes,
 * reports progress with siv_post, can be cancelled, and delivers its
 * result in done, at a safe point on the application's thread.
 *
 *     zig build guide && ./zig-out/bin/guide-jobs
 */
#include <siv.h>

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIMIT 200000

/* Commits a transaction made in a handler. There is nothing to undo when
 * one fails (siv discarded it), so report it and go on. */
static void commit(siv_txn txn) {
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "siv_txn_commit: %s\n", siv_result_name(r));
}

struct ui {
	siv_app app;
	siv_window window;
	siv_node progress;
	siv_node result;
	siv_node start;
	siv_node cancel;
};

/* One job: what the worker reads and writes. It belongs to the job until
 * destroy runs; the UI reaches it only from done and posted callbacks. */
struct count_job {
	struct ui *ui;
	atomic_bool cancelled;
	uint32_t found;
};

static struct count_job *running;

struct progress {
	struct ui *ui;
	double fraction;
};

static void show_progress(void *user_data) {
	struct progress *p = user_data;
	siv_txn txn;
	if (siv_txn_begin(p->ui->window, &txn) != SIV_OK) return;
	siv_widget_set_value(txn, p->ui->progress, p->fraction * 100);
	commit(txn);
}

static bool is_prime(uint32_t n) {
	if (n < 2) return false;
	for (uint32_t d = 2; d * d <= n; d++)
		if (n % d == 0) return false;
	return true;
}

/* On a worker thread: it may call siv_post and nothing else of siv's. */
static void count_primes(void *user_data) {
	struct count_job *job = user_data;
	for (uint32_t n = 0; n < LIMIT; n++) {
		if (n % (LIMIT / 20) == 0) {
			if (atomic_load(&job->cancelled)) return;
			struct progress *p = malloc(sizeof *p);
			if (p) {
				*p = (struct progress){job->ui, (double)n / LIMIT};
				if (siv_post(job->ui->app, show_progress, free, p) != SIV_OK) free(p);
			}
		}
		if (is_prime(n)) job->found++;
	}
}

static void set_running(struct ui *ui, siv_txn txn, bool on) {
	siv_widget_set_disabled(txn, ui->start, on);
	siv_widget_set_disabled(txn, ui->cancel, !on);
}

/* Back on the application's thread, after the work returned. */
static void count_done(void *user_data) {
	struct count_job *job = user_data;
	struct ui *ui = job->ui;
	char text[64];
	if (atomic_load(&job->cancelled)) snprintf(text, sizeof text, "Cancelled");
	else snprintf(text, sizeof text, "%u primes below %u", (unsigned)job->found, LIMIT);
	siv_txn txn;
	if (siv_txn_begin(ui->window, &txn) != SIV_OK) return;
	siv_set_text(txn, ui->result, text, strlen(text));
	siv_widget_set_value(txn, ui->progress, atomic_load(&job->cancelled) ? 0 : 100);
	set_running(ui, txn, false);
	commit(txn);
}

/* Runs last, whether or not the job ran: the application may be
 * destroyed while it waits in the queue. */
static void count_destroy(void *user_data) {
	if (running == user_data) running = NULL;
	free(user_data);
}

static siv_event_result on_start(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	struct ui *ui = user_data;
	if (running) return SIV_EVENT_RESULT_HANDLED;
	struct count_job *job = calloc(1, sizeof *job);
	if (!job) return SIV_EVENT_RESULT_HANDLED;
	job->ui = ui;
	/* CPU-bound work goes to the compute workers; blocking work (files,
	 * the network) leaves the flag off. */
	if (siv_job_start(ui->app, SIV_JOB_COMPUTE, count_primes, count_done, count_destroy, job) != SIV_OK) return SIV_EVENT_RESULT_HANDLED;
	running = job;
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_HANDLED;
	siv_set_text(txn, ui->result, SIV_STR("Counting…"));
	set_running(ui, txn, true);
	commit(txn);
	return SIV_EVENT_RESULT_HANDLED;
}

/* A running job cannot be stopped from outside: it checks a flag. */
static siv_event_result on_cancel(void *user_data, siv_node button, const siv_event *event) {
	(void)user_data;
	(void)button;
	(void)event;
	if (running) atomic_store(&running->cancelled, true);
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_result build(struct ui *ui) {
	siv_txn txn;
	siv_result r = siv_txn_begin(ui->window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_get_root(ui->window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 12, .align_items = SIV_ALIGN_START));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {20, 20, 20, 20}));
	ui->progress = siv_progress_bar(txn, column, SIV_DESC(siv_range_desc, .label = SIV_STR("Progress")));
	siv_set_layout(txn, ui->progress, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 280}));
	/* A live region: screen readers announce the result when it comes. */
	ui->result = siv_text(txn, column, SIV_STR("Count the primes below 200000"));
	siv_set_text_style(txn, ui->result, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_WINDOW_FG));
	siv_set_semantics(txn, ui->result, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_STATUS, .flags = SIV_SEMANTICS_LIVE_POLITE));
	siv_node buttons = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .gap = 8));
	ui->start = siv_push_button(txn, buttons, SIV_DESC(siv_button_desc, .label = SIV_STR("Start"), .style = SIV_BUTTON_STYLE_PRIMARY));
	ui->cancel = siv_push_button(txn, buttons, SIV_DESC(siv_button_desc, .label = SIV_STR("Cancel"), .flags = SIV_WIDGET_DISABLED));
	siv_on(txn, ui->start, SIV_EVENT_TYPE_ACTIVATE, on_start, NULL, ui);
	siv_on(txn, ui->cancel, SIV_EVENT_TYPE_ACTIVATE, on_cancel, NULL, ui);
	return siv_txn_commit(txn);
}

int main(void) {
	struct ui ui = {0};
	siv_result r = siv_app_create(NULL, &ui.app);
	if (r != SIV_OK) {
		fprintf(stderr, "jobs: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(ui.app, SIV_DESC(siv_window_desc, .title = SIV_STR("Primes"), .width = 340, .height = 150), &ui.window);
	if (r == SIV_OK) r = build(&ui);
	if (r == SIV_OK) r = siv_app_run(ui.app);
	if (r != SIV_OK) fprintf(stderr, "jobs: %s\n", siv_result_name(r));
	/* Waits for a running job; drops queued ones (only destroy runs). */
	siv_app_destroy(ui.app);
	return r == SIV_OK ? 0 : 1;
}
