/* A test of a window, run without a display: the headless backend renders
 * into memory, and the siv_test_* calls drive the window as a user would
 * and read what it shows, as a screen reader reads it.
 *
 *     cc counter_test.c $(pkg-config --cflags --libs siv) -o counter_test
 *     ./counter_test /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
 */
#include <siv.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The code under test: hello.c's counter. */
struct counter {
	siv_node label;
	int clicks;
};

static siv_event_result on_click(void *user_data, siv_node button, const siv_event *event) {
	(void)button;
	struct counter *counter = user_data;
	counter->clicks++;
	char text[32];
	snprintf(text, sizeof text, "Clicked %d time%s", counter->clicks, counter->clicks == 1 ? "" : "s");
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_set_text(txn, counter->label, text, strlen(text));
	return siv_txn_commit(txn) == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
}

static siv_result build(siv_window window, struct counter *counter) {
	siv_txn txn;
	siv_result r = siv_txn_begin(window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_get_root(window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 12, .align_items = SIV_ALIGN_START));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {24, 24, 24, 24}));
	siv_node button = siv_push_button(txn, column, SIV_DESC(siv_button_desc, .label = SIV_STR("Click me"), .style = SIV_BUTTON_STYLE_PRIMARY));
	siv_on(txn, button, SIV_EVENT_TYPE_ACTIVATE, on_click, NULL, counter);
	counter->label = siv_text(txn, column, SIV_STR("Not clicked yet"));
	return siv_txn_commit(txn);
}

/* The test. */
static int failures;

#define CHECK(cond) \
	do { \
		if (!(cond)) { \
			fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #cond); \
			failures++; \
		} \
	} while (0)

/* Delivers the input so far and waits until every frame is presented and
 * nothing is loading. */
static void settle(siv_app app) {
	bool settled = false;
	CHECK(siv_test_settle(app, 5000, &settled) == SIV_OK && settled);
}

/* Whether some node reads `text`. */
static bool reads(siv_window window, const char *text) {
	bool found = false;
	siv_test_node node;
	return siv_test_find(window, SIV_DESC(siv_test_query, .name = text, .name_len = strlen(text)), &found, &node) == SIV_OK && found;
}

/* The application's own font, so that text measures the same everywhere. */
static siv_result add_font(siv_app app, const char *path) {
	FILE *f = fopen(path, "rb");
	if (!f) return SIV_ERROR_UNAVAILABLE;
	static uint8_t data[4 << 20];
	size_t len = fread(data, 1, sizeof data, f);
	fclose(f);
	siv_result r = siv_app_add_font(app, SIV_STR("Test"), data, len);
	if (r == SIV_OK) r = siv_app_set_default_font(app, SIV_STR("Test"));
	return r;
}

int main(int argc, char **argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: counter_test FONT\n");
		return 2;
	}
	siv_app app;
	/* No system fonts, icons, or desktop settings, and no motion: the same
	 * pixels on every machine. */
	siv_result r = siv_app_create(SIV_DESC(siv_app_desc, .backend = SIV_BACKEND_HEADLESS,
		.flags = SIV_APP_NO_SYSTEM_FONTS | SIV_APP_NO_SYSTEM_ICONS | SIV_APP_REDUCED_MOTION), &app);
	if (r != SIV_OK) {
		fprintf(stderr, "counter_test: %s\n", siv_result_name(r));
		return 1;
	}
	CHECK(add_font(app, argv[1]) == SIV_OK);
	siv_window window = 0;
	struct counter counter = {0};
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = SIV_STR("Counter"), .width = 320, .height = 160), &window);
	if (r == SIV_OK) r = build(window, &counter);
	CHECK(r == SIV_OK);
	settle(app);
	CHECK(reads(window, "Not clicked yet"));

	/* A click in the middle of the button, where a user sees it. */
	bool found = false;
	siv_test_node button;
	CHECK(siv_test_find(window, SIV_DESC(siv_test_query, .role = SIV_ROLE_BUTTON, .name = SIV_STR("Click me")), &found, &button) == SIV_OK && found);
	siv_rect b = button.bounds;
	CHECK(siv_test_click(window, b.x + b.width / 2, b.y + b.height / 2, SIV_POINTER_BUTTON_PRIMARY) == SIV_OK);
	settle(app);
	CHECK(reads(window, "Clicked 1 time"));

	/* The keyboard: Tab to the button, then Enter. */
	CHECK(siv_test_key(window, SIV_KEY_TAB, 0, SIV_STR("")) == SIV_OK);
	CHECK(siv_test_key(window, SIV_KEY_RETURN, 0, SIV_STR("\r")) == SIV_OK);
	settle(app);
	CHECK(reads(window, "Clicked 2 times"));
	CHECK(siv_test_find(window, SIV_DESC(siv_test_query, .flags = SIV_TEST_QUERY_FOCUSED), &found, &button) == SIV_OK && found && button.role == SIV_ROLE_BUTTON);

	/* What the window shows: RGBA rows, here the opaque background. */
	size_t len = 0;
	uint32_t width = 0, height = 0;
	CHECK(siv_test_capture(window, NULL, 0, &len, &width, &height) == SIV_OK);
	CHECK(width == 320 && height == 160 && len == (size_t)width * height * 4);
	char *pixels = malloc(len);
	CHECK(pixels && siv_test_capture(window, pixels, len, &len, &width, &height) == SIV_OK);
	CHECK(pixels && (unsigned char)pixels[3] == 255);
	free(pixels);

	if (failures) {
		/* What a screen reader would read, to see why. */
		char tree[4096];
		if (siv_test_dump(window, tree, sizeof tree, &len) == SIV_OK) fprintf(stderr, "%.*s", (int)(len < sizeof tree ? len : sizeof tree), tree);
	}
	siv_app_destroy(app);
	return failures ? 1 : 0;
}
