/* External content: a producer thread renders frames into shared memory,
 * as a video decoder would, and submits them to a slot that an external
 * node shows. Frames go straight to siv's compositor thread, and buffers
 * come back on it, so playback does not wait on the application's thread.
 *
 *     zig build guide && ./zig-out/bin/guide-video
 */
#define _GNU_SOURCE
#include <siv.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define WIDTH 320
#define HEIGHT 180
#define FRAME_BYTES (WIDTH * HEIGHT * 4)
#define FRAMES 60

struct player {
	siv_app app;
	siv_window window;
	siv_external slot;
	siv_node status;
	int fd;
	uint8_t *pixels; /* two frames, one shown while the other is drawn */
	pthread_mutex_t lock;
	pthread_cond_t released;
	bool busy[2];
	atomic_bool stop;
};

/* Runs on siv's compositor thread when no frame reads the buffer any
 * more: quick, and only siv_external_submit and siv_post are allowed. */
static void on_release(void *user_data, siv_external slot, uint64_t key) {
	(void)slot;
	struct player *p = user_data;
	pthread_mutex_lock(&p->lock);
	p->busy[key % 2] = false;
	pthread_cond_signal(&p->released);
	pthread_mutex_unlock(&p->lock);
}

/* Color bars with a white bar sweeping across, as B, G, R, X bytes. */
static void render(uint8_t *frame, int n) {
	static const uint8_t bars[7][3] = {{192, 192, 192}, {0, 192, 192}, {192, 192, 0}, {0, 192, 0}, {192, 0, 192}, {0, 0, 192}, {192, 0, 0}};
	int sweep = n * 8 % (WIDTH - 16);
	for (int y = 0; y < HEIGHT; y++)
		for (int x = 0; x < WIDTH; x++) {
			uint8_t *px = &frame[(y * WIDTH + x) * 4];
			const uint8_t *c = bars[x * 7 / WIDTH];
			bool white = x >= sweep && x < sweep + 16;
			px[0] = white ? 255 : c[0], px[1] = white ? 255 : c[1], px[2] = white ? 255 : c[2], px[3] = 0;
		}
}

static void on_finished(void *user_data) {
	struct player *p = user_data;
	siv_txn txn;
	if (siv_txn_begin(p->window, &txn) != SIV_OK) return;
	siv_set_text(txn, p->status, SIV_STR("Played 60 frames"));
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "video: %s\n", siv_result_name(r));
}

static void *produce(void *arg) {
	struct player *p = arg;
	for (int n = 0; n < FRAMES && !atomic_load(&p->stop); n++) {
		int buffer = n % 2;
		pthread_mutex_lock(&p->lock);
		while (p->busy[buffer] && !atomic_load(&p->stop)) {
			struct timespec until;
			clock_gettime(CLOCK_REALTIME, &until);
			until.tv_nsec += 50000000;
			if (until.tv_nsec >= 1000000000) until.tv_sec++, until.tv_nsec -= 1000000000;
			pthread_cond_timedwait(&p->released, &p->lock, &until);
		}
		p->busy[buffer] = true;
		pthread_mutex_unlock(&p->lock);
		render(p->pixels + buffer * FRAME_BYTES, n);
		/* The key names the pixels: it comes back in on_release. */
		siv_external_frame_desc frame = {.size = sizeof frame, .key = (uint64_t)n, .fd = p->fd, .offset = (uint32_t)(buffer * FRAME_BYTES), .width = WIDTH, .height = HEIGHT};
		if (siv_external_submit(p->slot, &frame) != SIV_OK) break;
		usleep(16000);
	}
	if (!atomic_load(&p->stop) && siv_post(p->app, on_finished, NULL, p) != SIV_OK) fprintf(stderr, "video: cannot post\n");
	return NULL;
}

static siv_result build(struct player *p) {
	/* The slot belongs to the window; the release callback makes buffers
	 * come back on the compositor thread rather than as events. */
	siv_result r = siv_external_create(p->window, SIV_DESC(siv_external_desc, .user_data = p, .release = on_release), &p->slot);
	siv_txn txn;
	if (r == SIV_OK) r = siv_txn_begin(p->window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_get_root(p->window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 8, .align_items = SIV_ALIGN_CENTER));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .padding = {16, 16, 16, 16}));
	/* Unclipped and uncovered, the frames go to a subsurface of their
	 * own, without a copy. Rounded corners need composition: siv draws
	 * the frame into the window instead. */
	siv_node frame = siv_box(txn, column);
	siv_set_visual(txn, frame, SIV_DESC(siv_visual_desc, .radius = {12, 12, 12, 12}, .flags = SIV_VISUAL_CLIP));
	siv_node view = siv_external_view(txn, frame, SIV_DESC(siv_external_view_desc, .external = p->slot, .content_size = {WIDTH, HEIGHT}, .fit = SIV_FIT_CONTAIN));
	siv_set_layout(txn, view, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, WIDTH}, .height = {SIV_UNIT_PX, HEIGHT}));
	siv_set_semantics(txn, view, SIV_DESC(siv_semantics_desc, .label = SIV_STR("Test pattern")));
	p->status = siv_text(txn, column, SIV_STR("Playing…"));
	siv_set_text_style(txn, p->status, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG));
	return siv_txn_commit(txn);
}

int main(void) {
	struct player p = {.lock = PTHREAD_MUTEX_INITIALIZER, .released = PTHREAD_COND_INITIALIZER};
	p.fd = memfd_create("frames", MFD_CLOEXEC);
	if (p.fd < 0 || ftruncate(p.fd, 2 * FRAME_BYTES) != 0) return 1;
	p.pixels = mmap(NULL, 2 * FRAME_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, p.fd, 0);
	if (p.pixels == MAP_FAILED) return 1;
	siv_result r = siv_app_create(NULL, &p.app);
	if (r != SIV_OK) {
		fprintf(stderr, "video: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(p.app, SIV_DESC(siv_window_desc, .title = SIV_STR("Video"), .width = 352, .height = 248), &p.window);
	if (r == SIV_OK) r = build(&p);
	pthread_t producer;
	bool started = r == SIV_OK && pthread_create(&producer, NULL, produce, &p) == 0;
	if (r == SIV_OK) r = siv_app_run(p.app);
	atomic_store(&p.stop, true);
	if (started) pthread_join(producer, NULL);
	if (r != SIV_OK) fprintf(stderr, "video: %s\n", siv_result_name(r));
	siv_app_destroy(p.app);
	munmap(p.pixels, 2 * FRAME_BYTES);
	close(p.fd);
	return r == SIV_OK ? 0 : 1;
}
