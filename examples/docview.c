/* A Markdown and HTML viewer: a document node (D32) in a scroll node, with
 * find, copy, and links between local files.
 *
 *     zig build examples && ./zig-out/bin/docview README.md
 *
 * Ctrl+F finds (Enter for the next match, Shift+Enter for the previous),
 * Ctrl+C copies the selection, Ctrl+A selects everything; Page Up, Page
 * Down, Home, End, and the arrows scroll. Links to local
 * Markdown and HTML files open here; others are printed. The loader reads
 * only local files: siv never fetches anything, so the application decides
 * (remote images stay blocked). */
#define _XOPEN_SOURCE 700 /* realpath */
#include <siv.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct viewer {
	siv_app app;
	siv_window window;
	siv_node scroll;
	siv_node doc;
	siv_node find;
	siv_node status;
	char path[4096];
	float scroll_y, view_h; /* the scroll node's offset and viewport */
	float doc_h;            /* the document's height */
};

static char *read_file(const char *path, size_t *len) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	size_t cap = 1 << 16, n = 0;
	char *buf = malloc(cap);
	while (buf) {
		size_t got = fread(buf + n, 1, cap - n, f);
		n += got;
		if (n < cap) break;
		char *bigger = realloc(buf, cap *= 2);
		if (!bigger) free(buf);
		buf = bigger;
	}
	fclose(f);
	*len = n;
	return buf;
}

static int ends_with(const char *s, size_t len, const char *suffix) {
	size_t n = strlen(suffix);
	return len >= n && strncmp(s + len - n, suffix, n) == 0;
}

static void set_status(struct viewer *v, const char *text) {
	siv_txn txn;
	if (siv_txn_begin(v->window, &txn) != SIV_OK) return;
	siv_set_text(txn, v->status, text, strlen(text));
	(void)siv_txn_commit(txn);
}

/* Resources: local files only. */
static void on_load(void *user_data, siv_node node, uint32_t request, const char *url, size_t url_len, siv_resource_kind kind) {
	(void)user_data;
	(void)kind;
	char path[4096];
	size_t len = 0;
	char *bytes = NULL;
	if (url_len > 7 && strncmp(url, "file://", 7) == 0 && url_len - 7 < sizeof path) {
		memcpy(path, url + 7, url_len - 7);
		path[url_len - 7] = 0;
		bytes = read_file(path, &len);
	}
	(void)siv_docview_supply(node, request, (const uint8_t *)bytes, bytes ? len : 0);
	free(bytes);
}

static int open_file(struct viewer *v, const char *path);

static void on_doc_event(void *user_data, siv_node node, const siv_docview_event *e) {
	(void)node;
	struct viewer *v = user_data;
	char text[128];
	switch (e->type) {
	case SIV_DOCVIEW_EVENT_TYPE_LINK: {
		/* A local document opens here, after this event. */
		size_t n = e->url_len;
		const char *hash = memchr(e->url, '#', n);
		if (hash) n = (size_t)(hash - e->url);
		if (n > 7 && n - 7 < sizeof v->path && strncmp(e->url, "file://", 7) == 0 &&
		    (ends_with(e->url, n, ".md") || ends_with(e->url, n, ".html") || ends_with(e->url, n, ".htm") || ends_with(e->url, n, ".txt"))) {
			char path[4096];
			memcpy(path, e->url + 7, n - 7);
			path[n - 7] = 0;
			open_file(v, path);
		} else {
			printf("link: %.*s\n", (int)e->url_len, e->url);
		}
		break;
	}
	case SIV_DOCVIEW_EVENT_TYPE_FIND:
		if (e->count == 0) snprintf(text, sizeof text, "No matches");
		else snprintf(text, sizeof text, "%u of %u", e->current, e->count);
		set_status(v, text);
		break;
	case SIV_DOCVIEW_EVENT_TYPE_SIZE:
		v->doc_h = e->height;
		break;
	case SIV_DOCVIEW_EVENT_TYPE_BLOCKED_IMAGES:
		snprintf(text, sizeof text, "%u remote images blocked", e->count);
		set_status(v, text);
		break;
	default:
		break;
	}
}

/* Shows a file in a new document node, replacing the old one. */
static int open_file(struct viewer *v, const char *path) {
	size_t len = 0;
	char *bytes = read_file(path, &len);
	if (!bytes) {
		fprintf(stderr, "cannot read %s\n", path);
		return -1;
	}
	char resolved[4096];
	if (!realpath(path, resolved)) snprintf(resolved, sizeof resolved, "%s", path);
	char base[4200];
	int base_len = snprintf(base, sizeof base, "file://%s", resolved);
	size_t plen = strlen(path);
	siv_docview_kind kind = SIV_DOCVIEW_KIND_HTML;
	if (ends_with(path, plen, ".md") || ends_with(path, plen, ".markdown")) kind = SIV_DOCVIEW_KIND_MARKDOWN;
	else if (ends_with(path, plen, ".txt")) kind = SIV_DOCVIEW_KIND_TEXT;
	snprintf(v->path, sizeof v->path, "%s", resolved);

	siv_txn txn;
	siv_result r = siv_txn_begin(v->window, &txn);
	if (r == SIV_OK) {
		if (v->doc) siv_remove(txn, v->doc);
		v->doc = siv_docview(txn, v->scroll, SIV_DESC(siv_docview_desc,
			.source = (const uint8_t *)bytes, .source_count = len,
			.base_url = base, .base_url_len = (size_t)base_len,
			.kind = kind, .color_scheme = SIV_DOCVIEW_COLOR_SCHEME_THEME,
			.user_data = v, .load = on_load, .on_event = on_doc_event));
		siv_set_layout(txn, v->doc, SIV_DESC(siv_layout_desc, .padding = {16, 16, 8, 8}));
		(void)siv_window_set_title(v->window, resolved, strlen(resolved));
		r = siv_txn_commit(txn);
	}
	free(bytes);
	if (r != SIV_OK) fprintf(stderr, "opening %s failed: %s\n", path, siv_result_name(r));
	return r == SIV_OK ? 0 : -1;
}

static siv_event_result on_find_key(void *user_data, siv_node node, const siv_event *event) {
	struct viewer *v = user_data;
	if (event->keysym != SIV_KEY_RETURN || !(event->flags & SIV_EVENT_PRESSED)) return SIV_EVENT_RESULT_PASS;
	char text[256];
	size_t len = 0;
	if (siv_node_get_text(node, text, sizeof text, &len) != SIV_OK) return SIV_EVENT_RESULT_HANDLED;
	if (len > sizeof text) len = sizeof text;
	(void)siv_docview_find(v->doc, text, len, (event->modifiers & SIV_MODIFIERS_SHIFT) != 0);
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_viewport(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	struct viewer *v = user_data;
	v->scroll_y = event->y;
	v->view_h = event->height;
	return SIV_EVENT_RESULT_PASS;
}

/* Keys that scroll the document, unless the find field has them. */
static siv_event_result scroll_key(struct viewer *v, const siv_event *event) {
	if (event->target == v->find || (event->modifiers & (SIV_MODIFIERS_SHIFT | SIV_MODIFIERS_ALT | SIV_MODIFIERS_SUPER))) return SIV_EVENT_RESULT_PASS;
	float y = v->scroll_y;
	switch (event->keysym) {
	case SIV_KEY_PAGE_DOWN: y += v->view_h * 0.9f; break;
	case SIV_KEY_PAGE_UP: y -= v->view_h * 0.9f; break;
	case SIV_KEY_DOWN: y += 40; break;
	case SIV_KEY_UP: y -= 40; break;
	case SIV_KEY_HOME: y = 0; break;
	case SIV_KEY_END: y = v->doc_h; break;
	default: return SIV_EVENT_RESULT_PASS;
	}
	float end = v->doc_h + 16 - v->view_h; /* with the node's padding */
	if (y > end) y = end;
	siv_txn txn;
	if (siv_txn_begin(v->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_scroll_to(txn, v->scroll, 0, y < 0 ? 0 : y);
	(void)siv_txn_commit(txn);
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_key(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	struct viewer *v = user_data;
	if (!(event->flags & SIV_EVENT_PRESSED)) return SIV_EVENT_RESULT_PASS;
	if (!(event->modifiers & SIV_MODIFIERS_CTRL)) return scroll_key(v, event);
	int key = (int)event->keysym;
	if (key == 'f') {
		(void)siv_node_focus(v->find);
		return SIV_EVENT_RESULT_HANDLED;
	}
	if (key == 'a') {
		(void)siv_docview_select_all(v->doc);
		return SIV_EVENT_RESULT_HANDLED;
	}
	if (key == 'c') {
		size_t len = 0;
		if (siv_docview_get_selection(v->doc, NULL, 0, &len) != SIV_OK || len == 0) return SIV_EVENT_RESULT_PASS;
		char *text = malloc(len);
		if (text && siv_docview_get_selection(v->doc, text, len, &len) == SIV_OK) (void)siv_clipboard_write(v->window, SIV_SELECTION_CLIPBOARD, text, len);
		free(text);
		return SIV_EVENT_RESULT_HANDLED;
	}
	return SIV_EVENT_RESULT_PASS;
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s FILE.md|FILE.html\n", argv[0]);
		return 2;
	}
	struct viewer v = {0};
	siv_result r = siv_app_create(NULL, &v.app);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_app_create: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(v.app, SIV_DESC(siv_window_desc, .title = "Document", .title_len = 8, .width = 800, .height = 900), &v.window);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_window_create: %s\n", siv_result_name(r));
		siv_app_destroy(v.app);
		return 1;
	}
	siv_txn txn;
	r = siv_txn_begin(v.window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_get_root(v.window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
		siv_on(txn, root, SIV_EVENT_TYPE_KEY, on_key, NULL, &v);
		siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN));
		siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
		siv_node bar = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_ROW, .gap = 8, .align_items = SIV_ALIGN_CENTER));
		siv_set_layout(txn, bar, SIV_DESC(siv_layout_desc, .padding = {8, 8, 6, 6}));
		v.find = siv_editor(txn, bar, 0);
		siv_set_layout(txn, v.find, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 240}));
		siv_set_placeholder(txn, v.find, "Find", 4);
		siv_on(txn, v.find, SIV_EVENT_TYPE_KEY, on_find_key, NULL, &v);
		v.status = siv_text(txn, bar, "", 0);
		v.scroll = siv_scroll(txn, column, SIV_SCROLL_AXIS_VERTICAL);
		siv_set_layout(txn, v.scroll, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .grow = 1));
		siv_on(txn, v.scroll, SIV_EVENT_TYPE_VIEWPORT, on_viewport, NULL, &v);
		r = siv_txn_commit(txn);
	}
	if (r != SIV_OK || open_file(&v, argv[1]) != 0) {
		fprintf(stderr, "building the window failed: %s\n", siv_result_name(r));
		siv_app_destroy(v.app);
		return 1;
	}
	r = siv_app_run(v.app);
	if (r != SIV_OK) fprintf(stderr, "siv_app_run: %s\n", siv_result_name(r));
	siv_app_destroy(v.app);
	return r == SIV_OK ? 0 : 1;
}
