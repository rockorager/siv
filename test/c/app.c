/* The public API from C against libsiv.so on the headless backend:
 * applications with allocator hooks, the embeddable loop, siv_post from
 * another thread, windows, transactions with sticky errors, handles, and
 * destroy-notify. Input is covered by test/abi (it needs the headless
 * backend's injection, which is not public).
 *
 * Usage: app <font.ttf> */
#include <siv.h>

#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define CHECK(cond)                                                                  \
	do {                                                                             \
		if (!(cond)) {                                                               \
			fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #cond); \
			failures++;                                                              \
		}                                                                            \
	} while (0)

#define EXPECT(call, want)                                                                \
	do {                                                                                  \
		siv_result r_ = (call);                                                           \
		if (r_ != (want)) {                                                               \
			fprintf(stderr, "%s:%d: %s returned %s, expected %s\n", __FILE__, __LINE__, \
			        #call, siv_result_name(r_), siv_result_name(want));                  \
			failures++;                                                                   \
		}                                                                                 \
	} while (0)

/* Thread-safe allocator hooks that count live bytes. */
static atomic_long live_bytes;
static atomic_long allocations;

static void *count_alloc(void *user_data, size_t size, size_t alignment) {
	(void)user_data;
	void *p = aligned_alloc(alignment < sizeof(void *) ? sizeof(void *) : alignment,
	                        (size + alignment - 1) / alignment * alignment);
	if (p) {
		atomic_fetch_add(&live_bytes, (long)size);
		atomic_fetch_add(&allocations, 1);
	}
	return p;
}

static void count_free(void *user_data, void *ptr, size_t size, size_t alignment) {
	(void)user_data;
	(void)alignment;
	atomic_fetch_sub(&live_bytes, (long)size);
	free(ptr);
}

static unsigned char *read_file(const char *path, size_t *len) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	unsigned char *buf = malloc((size_t)n);
	if (buf && fread(buf, 1, (size_t)n, f) != (size_t)n) {
		free(buf);
		buf = NULL;
	}
	fclose(f);
	*len = (size_t)n;
	return buf;
}

struct counts {
	atomic_int runs;
	atomic_int destroys;
};

static void on_post(void *user_data) { atomic_fetch_add(&((struct counts *)user_data)->runs, 1); }
static void on_destroy(void *user_data) { atomic_fetch_add(&((struct counts *)user_data)->destroys, 1); }

struct poster {
	siv_app app;
	struct counts *counts;
};

static void *post_from_thread(void *arg) {
	struct poster *p = arg;
	for (int i = 0; i < 50; i++) {
		if (siv_post(p->app, on_post, on_destroy, p->counts) != SIV_OK) return (void *)1;
	}
	return NULL;
}

static bool on_activate(void *user_data, siv_node node, const siv_event *event) {
	(void)user_data;
	(void)node;
	(void)event;
	return true;
}

struct window_log {
	int resized;
	unsigned width;
	int destroyed;
};

static void on_window_destroy(void *user_data) { ((struct window_log *)user_data)->destroyed++; }

static bool on_window(void *user_data, siv_window window, const siv_window_event *event) {
	(void)window;
	struct window_log *log = user_data;
	if (event->type == SIV_WINDOW_EVENT_TYPE_RESIZED) {
		log->resized++;
		log->width = event->width;
	}
	return false;
}

/* Dispatches until the node has been laid out (a frame ran). */
static bool wait_for_layout(siv_app app, siv_node node) {
	for (int i = 0; i < 2000; i++) {
		siv_rect r;
		if (siv_node_get_rect(node, &r) == SIV_OK && r.width > 0) return true;
		if (siv_app_dispatch(app, 5) != SIV_OK) return false;
	}
	return false;
}

static void test_app(const unsigned char *font, size_t font_len) {
	siv_app app = 0;
	siv_allocator hooks = {.size = sizeof hooks, .alloc = count_alloc, .free = count_free};
	EXPECT(siv_app_create(SIV_DESC(siv_app_desc, .allocator = &hooks, .backend = SIV_BACKEND_HEADLESS,
	                               .flags = SIV_APP_NO_SYSTEM_FONTS),
	                      &app),
	       SIV_OK);
	CHECK(atomic_load(&allocations) > 0);
	EXPECT(siv_app_create(SIV_DESC(siv_app_desc, .backend = (siv_backend)9), &app), SIV_ERROR_UNSUPPORTED);
	EXPECT(siv_app_add_font(app, "Droid", 5, font, font_len), SIV_OK);
	EXPECT(siv_app_add_font(app, "Bad", 3, (const uint8_t *)"nope", 4), SIV_ERROR_INVALID_ARGUMENT);
	EXPECT(siv_app_set_default_font(app, "Droid", 5), SIV_OK);

	int fd = -1;
	EXPECT(siv_app_fd(app, &fd), SIV_OK);
	CHECK(fd >= 0);

	/* Posting from another thread: each closure runs, then its destroy. */
	struct counts counts = {0};
	struct poster poster = {app, &counts};
	pthread_t thread;
	pthread_create(&thread, NULL, post_from_thread, &poster);
	void *ret = NULL;
	pthread_join(thread, &ret);
	CHECK(ret == NULL);
	/* The loop fd is readable while posted work waits (D6). */
	struct pollfd pfd = {.fd = fd, .events = POLLIN};
	CHECK(poll(&pfd, 1, 1000) == 1);
	for (int i = 0; i < 100 && atomic_load(&counts.runs) < 50; i++) EXPECT(siv_app_dispatch(app, 0), SIV_OK);
	CHECK(atomic_load(&counts.runs) == 50 && atomic_load(&counts.destroys) == 50);
	EXPECT(siv_post(app, NULL, on_destroy, &counts), SIV_ERROR_INVALID_ARGUMENT);

	struct window_log log = {0};
	siv_window window = 0;
	EXPECT(siv_window_create(app, SIV_DESC(siv_window_desc, .title = "Test", .title_len = 4, .width = 200, .height = 120,
	                                       .on_event = on_window, .destroy = on_window_destroy, .user_data = &log),
	                         &window),
	       SIV_OK);
	EXPECT(siv_window_set_title(window, "Renamed", 7), SIV_OK);
	siv_node root = siv_window_root(window);
	CHECK(root != 0);
	CHECK(siv_window_root(0) == 0);

	/* A transaction that builds a small form. */
	siv_txn txn = 0;
	EXPECT(siv_txn_begin(window, &txn), SIV_OK);
	siv_txn other = 0;
	EXPECT(siv_txn_begin(window, &other), SIV_ERROR_BUSY);
	EXPECT(siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background = {1, 1, 1, 1})), SIV_OK);
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 8));
	EXPECT(siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {12, 12, 12, 12})), SIV_OK);
	siv_node label = siv_text(txn, column, "Hello", 5);
	EXPECT(siv_set_text_style(txn, label, SIV_DESC(siv_text_style_desc, .font_size = 18, .weight = SIV_FONT_WEIGHT_BOLD)), SIV_OK);
	siv_node button = siv_box(txn, column);
	EXPECT(siv_set_semantics(txn, button, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_BUTTON, .flags = SIV_SEMANTICS_FOCUSABLE)), SIV_OK);
	EXPECT(siv_set_visual(txn, button, SIV_DESC(siv_visual_desc, .background = {0.15f, 0.39f, 0.92f, 1}, .radius = {6, 6, 6, 6})), SIV_OK);
	EXPECT(siv_set_layout(txn, button, SIV_DESC(siv_layout_desc, .padding = {12, 12, 6, 6})), SIV_OK);
	siv_node caption = siv_text(txn, button, "Save", 4);
	struct counts handler_counts = {0};
	EXPECT(siv_on(txn, button, SIV_EVENT_TYPE_ACTIVATE, on_activate, on_destroy, &handler_counts), SIV_OK);
	siv_node editor = siv_editor(txn, column, 0);
	EXPECT(siv_set_text(txn, editor, "edit me", 7), SIV_OK);
	EXPECT(siv_set_selection(txn, editor, 2, 4), SIV_OK);
	siv_track tracks[] = {{SIV_TRACK_UNIT_PX, 40}, {SIV_TRACK_UNIT_FR, 1}};
	siv_node grid = siv_grid(txn, column, SIV_DESC(siv_grid_desc, .columns = tracks, .columns_count = 2, .column_gap = 4));
	siv_node scroll = siv_scroll(txn, column, SIV_SCROLL_AXIS_VERTICAL);
	siv_node stack = siv_stack(txn, scroll, SIV_DESC(siv_stack_desc, .align_x = SIV_ALIGN_CENTER));
	EXPECT(siv_set_opacity(txn, stack, 0.5f), SIV_OK);
	EXPECT(siv_set_transform(txn, stack, (siv_transform){.scale_x = 1, .scale_y = 1, .translate_x = 2}), SIV_OK);
	CHECK(column && label && button && caption && editor && grid && scroll && stack);
	EXPECT(siv_txn_status(txn), SIV_OK);
	EXPECT(siv_txn_commit(txn), SIV_OK);
	EXPECT(siv_txn_commit(txn), SIV_ERROR_INVALID_HANDLE);

	/* Queries see the committed tree. */
	char buf[16];
	size_t len = 0;
	EXPECT(siv_node_get_text(label, buf, sizeof buf, &len), SIV_OK);
	CHECK(len == 5 && memcmp(buf, "Hello", 5) == 0);
	EXPECT(siv_node_get_text(editor, buf, 3, &len), SIV_OK);
	CHECK(len == 7 && memcmp(buf, "edi", 3) == 0);
	EXPECT(siv_node_get_text(button, buf, sizeof buf, &len), SIV_ERROR_INVALID_ARGUMENT);
	uint32_t caret = 0, anchor = 0;
	EXPECT(siv_node_get_selection(editor, &caret, &anchor), SIV_OK);
	CHECK(caret == 2 && anchor == 4);
	EXPECT(siv_node_focus(editor), SIV_OK);
	EXPECT(siv_node_focus(label), SIV_ERROR_INVALID_ARGUMENT);

	CHECK(wait_for_layout(app, button));
	siv_rect rect;
	EXPECT(siv_node_get_rect(button, &rect), SIV_OK);
	CHECK(rect.x == 12 && rect.width > 24 && rect.height > 12);
	siv_size size;
	EXPECT(siv_window_get_size(window, &size), SIV_OK);
	CHECK(size.width == 200 && size.height == 120);
	CHECK(log.resized == 0 || log.width == 200);

	/* Sticky errors: after the first failure nothing applies, builders
	 * return 0, and commit discards the whole transaction. */
	EXPECT(siv_txn_begin(window, &txn), SIV_OK);
	EXPECT(siv_set_text(txn, label, "Changed", 7), SIV_OK);
	siv_node extra = siv_box(txn, column);
	CHECK(extra != 0);
	EXPECT(siv_set_text(txn, button, "not text", 8), SIV_ERROR_INVALID_ARGUMENT);
	CHECK(siv_box(txn, column) == 0);
	EXPECT(siv_set_text(txn, label, "Later", 5), SIV_ERROR_INVALID_ARGUMENT);
	EXPECT(siv_txn_status(txn), SIV_ERROR_INVALID_ARGUMENT);
	EXPECT(siv_txn_commit(txn), SIV_ERROR_INVALID_ARGUMENT);
	EXPECT(siv_node_get_text(label, buf, sizeof buf, &len), SIV_OK);
	CHECK(len == 5 && memcmp(buf, "Hello", 5) == 0);
	EXPECT(siv_node_get_rect(extra, &rect), SIV_ERROR_INVALID_HANDLE);

	/* Invalid descriptors and handles are errors too. */
	EXPECT(siv_txn_begin(window, &txn), SIV_OK);
	EXPECT(siv_set_layout(txn, label, SIV_DESC(siv_layout_desc, .align_x = (siv_align)42)), SIV_ERROR_UNSUPPORTED);
	EXPECT(siv_txn_abort(txn), SIV_OK);
	EXPECT(siv_txn_begin(window, &txn), SIV_OK);
	EXPECT(siv_set_layout(txn, (siv_node)window, NULL), SIV_ERROR_INVALID_HANDLE);
	EXPECT(siv_txn_abort(txn), SIV_OK);

	/* Removing a node invalidates its handle at commit and releases its
	 * handlers. Replacing a handler releases the old one at commit. */
	EXPECT(siv_txn_begin(window, &txn), SIV_OK);
	EXPECT(siv_on(txn, button, SIV_EVENT_TYPE_ACTIVATE, on_activate, on_destroy, &handler_counts), SIV_OK);
	CHECK(atomic_load(&handler_counts.destroys) == 0);
	EXPECT(siv_txn_commit(txn), SIV_OK);
	CHECK(atomic_load(&handler_counts.destroys) == 1);
	EXPECT(siv_txn_begin(window, &txn), SIV_OK);
	EXPECT(siv_on(txn, button, SIV_EVENT_TYPE_KEY, on_activate, on_destroy, &handler_counts), SIV_OK);
	EXPECT(siv_txn_abort(txn), SIV_OK);
	CHECK(atomic_load(&handler_counts.destroys) == 2);
	EXPECT(siv_txn_begin(window, &txn), SIV_OK);
	EXPECT(siv_remove(txn, button), SIV_OK);
	EXPECT(siv_node_get_text(caption, buf, sizeof buf, &len), SIV_OK);
	EXPECT(siv_txn_commit(txn), SIV_OK);
	CHECK(atomic_load(&handler_counts.destroys) == 3);
	EXPECT(siv_node_get_text(caption, buf, sizeof buf, &len), SIV_ERROR_INVALID_HANDLE);

	/* An open transaction and the window's handlers go with the window. */
	EXPECT(siv_txn_begin(window, &txn), SIV_OK);
	EXPECT(siv_on(txn, label, SIV_EVENT_TYPE_POINTER, on_activate, on_destroy, &handler_counts), SIV_OK);
	CHECK(log.destroyed == 0);
	EXPECT(siv_window_destroy(window), SIV_OK);
	CHECK(log.destroyed == 1);
	CHECK(atomic_load(&handler_counts.destroys) == 4);
	CHECK(atomic_load(&counts.destroys) == 50);
	EXPECT(siv_txn_commit(txn), SIV_ERROR_INVALID_HANDLE);
	EXPECT(siv_window_destroy(window), SIV_ERROR_INVALID_HANDLE);
	EXPECT(siv_node_get_text(label, buf, sizeof buf, &len), SIV_ERROR_INVALID_HANDLE);

	/* Work posted but never dispatched is released with the application. */
	EXPECT(siv_post(app, on_post, on_destroy, &counts), SIV_OK);
	EXPECT(siv_app_destroy(app), SIV_OK);
	CHECK(atomic_load(&counts.runs) == 50 && atomic_load(&counts.destroys) == 51);
	EXPECT(siv_app_destroy(app), SIV_ERROR_INVALID_HANDLE);
	EXPECT(siv_post(app, on_post, on_destroy, &counts), SIV_ERROR_INVALID_HANDLE);
	CHECK(atomic_load(&live_bytes) == 0);
}

int main(int argc, char **argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: %s <font.ttf>\n", argv[0]);
		return 2;
	}
	size_t font_len = 0;
	unsigned char *font = read_file(argv[1], &font_len);
	if (!font) {
		fprintf(stderr, "cannot read %s\n", argv[1]);
		return 2;
	}
	test_app(font, font_len);
	free(font);
	if (failures) {
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	return 0;
}
