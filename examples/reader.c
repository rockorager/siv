/* An e-reader: an EPUB publication (D32) shown a page or a two-page spread
 * at a time with siv's reading defaults (serif, justified, hyphenated,
 * margins and a comfortable measure; the publisher's CSS can override them).
 *
 *     zig build examples && ./zig-out/bin/reader BOOK.epub [LOCATOR]
 *
 * Right, Page Down, and Space turn the page, Left and Page Up turn back;
 * both cross into the next or previous chapter. T shows the table of
 * contents, + and - change the text size, and a footnote reference opens
 * the note in a popup (Escape closes it). On exit the reader prints the
 * reading position, which it takes as its second argument to resume. */
#include <siv.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct reader {
	siv_app app;
	siv_window window;
	siv_epub epub;
	uint32_t spine_count, toc_count;
	siv_node column, page_host, doc;
	siv_node status;
	siv_node toc_scroll, toc;
	siv_node note_box, note_scroll, note;
	uint32_t spine, page, pages;
	int size_percent;
	/* What to do once the chapter loads: go to its last page, or a target. */
	int go_last;
	char pending[512];
	char note_target[512];
	char title[256];
};

static char *read_file(const char *path, size_t *len) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	size_t cap = 1 << 20, n = 0;
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

static void update_status(struct reader *r) {
	char text[384];
	int n = snprintf(text, sizeof text, "%s  ·  chapter %u of %u  ·  page %u of %u", r->title, r->spine + 1, r->spine_count, r->page + 1, r->pages ? r->pages : 1);
	siv_txn txn;
	if (siv_txn_begin(r->window, &txn) != SIV_OK) return;
	siv_set_text(txn, r->status, text, (size_t)n);
	(void)siv_txn_commit(txn);
}

static void user_css(struct reader *r, char *css, size_t cap) {
	snprintf(css, cap, "html { font-size: %d%% }", r->size_percent);
}

static void on_doc_event(void *user_data, siv_node node, const siv_docview_event *e);

/* Shows spine item `index`, then `target` ("#id" or a locator) once it loads. */
static void open_chapter(struct reader *r, uint32_t index, const char *target, int go_last) {
	if (index >= r->spine_count) return;
	char path[1024];
	size_t len = 0;
	if (siv_epub_get_spine_path(r->epub, index, path, sizeof path, &len) != SIV_OK || len > sizeof path) return;
	r->spine = index;
	r->go_last = go_last;
	snprintf(r->pending, sizeof r->pending, "%s", target ? target : "");
	char css[64];
	user_css(r, css, sizeof css);
	siv_txn txn;
	if (siv_txn_begin(r->window, &txn) != SIV_OK) return;
	if (r->doc) siv_remove(txn, r->doc);
	r->doc = siv_docview(txn, r->page_host, SIV_DESC(siv_docview_desc,
		.epub = r->epub, .epub_path = path, .epub_path_len = len,
		.user_css = css, .user_css_len = strlen(css),
		.flags = SIV_DOCVIEW_PAGED | SIV_DOCVIEW_READING | SIV_DOCVIEW_SPREAD,
		.color_scheme = SIV_DOCVIEW_COLOR_SCHEME_THEME,
		.user_data = r, .on_event = on_doc_event));
	siv_set_layout(txn, r->doc, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
	(void)siv_txn_commit(txn);
}

/* Finds the spine item whose path ends the URL's path (epub:///PATH#id). */
static int spine_of(struct reader *r, const char *url, size_t url_len, const char **fragment) {
	const char *hash = memchr(url, '#', url_len);
	size_t n = hash ? (size_t)(hash - url) : url_len;
	*fragment = hash;
	if (n < 8 || strncmp(url, "epub:///", 8) != 0) return -1;
	for (uint32_t i = 0; i < r->spine_count; i++) {
		char path[1024];
		size_t len = 0;
		if (siv_epub_get_spine_path(r->epub, i, path, sizeof path, &len) != SIV_OK || len > sizeof path) continue;
		if (len == n - 8 && memcmp(path, url + 8, len) == 0) return (int)i;
	}
	return -1;
}

static void show_note(struct reader *r, bool show) {
	siv_txn txn;
	if (siv_txn_begin(r->window, &txn) != SIV_OK) return;
	siv_set_hidden(txn, r->note_box, !show);
	if (!show && r->note) {
		siv_remove(txn, r->note);
		r->note = 0;
	}
	(void)siv_txn_commit(txn);
}

/* A popup with the note: its HTML when this chapter holds it, otherwise
 * the chapter holding it, scrolled to the note. */
static void open_note(struct reader *r, int spine, const char *fragment, size_t fragment_len) {
	char *html = NULL;
	size_t len = 0;
	if (spine == (int)r->spine && fragment_len > 1 &&
	    siv_docview_get_element_html(r->doc, fragment + 1, fragment_len - 1, NULL, 0, &len) == SIV_OK && len > 0) {
		html = malloc(len);
		if (html && siv_docview_get_element_html(r->doc, fragment + 1, fragment_len - 1, html, len, &len) != SIV_OK) {
			free(html);
			html = NULL;
		}
	}
	char path[1024];
	size_t path_len = 0;
	if (siv_epub_get_spine_path(r->epub, (uint32_t)spine, path, sizeof path, &path_len) != SIV_OK || path_len > sizeof path) {
		free(html);
		return;
	}
	snprintf(r->note_target, sizeof r->note_target, "%.*s", (int)fragment_len, fragment);
	siv_txn txn;
	if (siv_txn_begin(r->window, &txn) != SIV_OK) {
		free(html);
		return;
	}
	if (r->note) siv_remove(txn, r->note);
	if (html) {
		r->note_target[0] = 0;
		r->note = siv_docview(txn, r->note_scroll, SIV_DESC(siv_docview_desc,
			.source = (const uint8_t *)html, .source_count = len,
			.epub = r->epub, .epub_path = path, .epub_path_len = path_len,
			.flags = SIV_DOCVIEW_READING, .user_data = r, .on_event = on_doc_event));
	} else {
		r->note = siv_docview(txn, r->note_scroll, SIV_DESC(siv_docview_desc,
			.epub = r->epub, .epub_path = path, .epub_path_len = path_len,
			.flags = SIV_DOCVIEW_READING, .user_data = r, .on_event = on_doc_event));
	}
	siv_set_layout(txn, r->note, SIV_DESC(siv_layout_desc, .padding = {16, 16, 12, 12}));
	siv_set_hidden(txn, r->note_box, false);
	(void)siv_txn_commit(txn);
	free(html);
}

static void toggle_toc(struct reader *r) {
	siv_txn txn;
	if (siv_txn_begin(r->window, &txn) != SIV_OK) return;
	bool hidden = false;
	(void)siv_node_is_hidden(r->toc_scroll, &hidden);
	siv_set_hidden(txn, r->toc_scroll, !hidden);
	(void)siv_txn_commit(txn);
}

/* Whether a space-separated list holds a word. */
static int has_word(const char *list, size_t len, const char *word) {
	size_t n = strlen(word);
	for (size_t i = 0; i + n <= len; i++)
		if ((i == 0 || list[i - 1] == ' ') && strncmp(list + i, word, n) == 0 && (i + n == len || list[i + n] == ' ')) return 1;
	return 0;
}

static void on_doc_event(void *user_data, siv_node node, const siv_docview_event *e) {
	struct reader *r = user_data;
	if (node == r->toc) {
		/* The table of contents is a document of toc:N links. */
		if (e->type == SIV_DOCVIEW_EVENT_TYPE_LINK && e->url_len > 4 && strncmp(e->url, "toc:", 4) == 0) {
			uint32_t index = (uint32_t)strtoul(e->url + 4, NULL, 10);
			char fragment[512];
			size_t len = 0;
			uint32_t spine = 0;
			if (siv_epub_get_toc_target(r->epub, index, fragment, sizeof fragment - 1, &len, &spine) == SIV_OK && len < sizeof fragment) {
				fragment[len] = 0;
				open_chapter(r, spine, fragment, 0);
				toggle_toc(r);
			}
		}
		return;
	}
	if (node == r->note) {
		if (e->type == SIV_DOCVIEW_EVENT_TYPE_LOADED && r->note_target[0]) (void)siv_docview_go_to(node, r->note_target, strlen(r->note_target));
		return;
	}
	if (node != r->doc) return;
	switch (e->type) {
	case SIV_DOCVIEW_EVENT_TYPE_LOADED:
		if (r->go_last) (void)siv_docview_set_page(node, UINT32_MAX);
		else if (r->pending[0]) (void)siv_docview_go_to(node, r->pending, strlen(r->pending));
		r->go_last = 0;
		r->pending[0] = 0;
		break;
	case SIV_DOCVIEW_EVENT_TYPE_PAGE:
		r->page = e->current;
		r->pages = e->count;
		update_status(r);
		break;
	case SIV_DOCVIEW_EVENT_TYPE_LINK: {
		const char *fragment = NULL;
		int spine = spine_of(r, e->url, e->url_len, &fragment);
		if (spine < 0) {
			printf("link: %.*s\n", (int)e->url_len, e->url);
			break;
		}
		size_t fragment_len = fragment ? e->url_len - (size_t)(fragment - e->url) : 0;
		if (has_word(e->rel, e->rel_len, "noteref")) {
			open_note(r, spine, fragment, fragment_len);
		} else {
			char target[512];
			snprintf(target, sizeof target, "%.*s", (int)fragment_len, fragment ? fragment : "");
			open_chapter(r, (uint32_t)spine, target, 0);
		}
		break;
	}
	default:
		break;
	}
}

/* Turns a page or a spread (set_page shows the spread holding a page),
 * crossing into the next or previous chapter at the ends. */
static void turn(struct reader *r, int forward) {
	uint32_t index = 0, count = 0, after = 0;
	if (siv_docview_get_page(r->doc, &index, &count) != SIV_OK) return;
	if (forward) {
		for (uint32_t step = 1; step <= 2 && after <= index; step++) {
			(void)siv_docview_set_page(r->doc, index + step);
			(void)siv_docview_get_page(r->doc, &after, &count);
		}
		if (after <= index && r->spine + 1 < r->spine_count) open_chapter(r, r->spine + 1, NULL, 0);
	} else if (index > 0) {
		(void)siv_docview_set_page(r->doc, index - 1);
	} else if (r->spine > 0) {
		open_chapter(r, r->spine - 1, NULL, 1);
	}
}

static void resize_text(struct reader *r, int delta) {
	int size = r->size_percent + delta;
	if (size < 60 || size > 250) return;
	r->size_percent = size;
	char css[64];
	user_css(r, css, sizeof css);
	(void)siv_docview_set_user_css(r->doc, css, strlen(css));
}

static siv_event_result on_key(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	struct reader *r = user_data;
	if (!(event->flags & SIV_EVENT_PRESSED)) return SIV_EVENT_RESULT_PASS;
	switch ((int)event->keysym) {
	case SIV_KEY_RIGHT:
	case SIV_KEY_PAGE_DOWN:
	case SIV_KEY_SPACE:
		turn(r, 1);
		return SIV_EVENT_RESULT_HANDLED;
	case SIV_KEY_LEFT:
	case SIV_KEY_PAGE_UP:
		turn(r, 0);
		return SIV_EVENT_RESULT_HANDLED;
	case SIV_KEY_ESCAPE:
		show_note(r, false);
		return SIV_EVENT_RESULT_HANDLED;
	case 't':
		toggle_toc(r);
		return SIV_EVENT_RESULT_HANDLED;
	case '+':
	case '=':
		resize_text(r, 10);
		return SIV_EVENT_RESULT_HANDLED;
	case '-':
		resize_text(r, -10);
		return SIV_EVENT_RESULT_HANDLED;
	default:
		return SIV_EVENT_RESULT_PASS;
	}
}

/* The table of contents as HTML: a list of toc:N links, nested by depth. */
static char *toc_html(struct reader *r, size_t *out_len) {
	size_t cap = 4096, len = 0;
	char *html = malloc(cap);
	if (!html) return NULL;
	len += (size_t)snprintf(html, cap, "<style>a{text-decoration:none;display:block;padding:3px 0}ul{list-style:none;padding-left:1em;margin:0}</style><h3>Contents</h3><ul>");
	for (uint32_t i = 0; i < r->toc_count; i++) {
		char label[512];
		size_t label_len = 0;
		uint32_t depth = 0;
		if (siv_epub_get_toc_label(r->epub, i, label, sizeof label, &label_len, &depth) != SIV_OK || label_len > sizeof label) continue;
		if (len + label_len * 6 + 64 > cap) {
			cap = (len + label_len * 6 + 64) * 2;
			char *bigger = realloc(html, cap);
			if (!bigger) {
				free(html);
				return NULL;
			}
			html = bigger;
		}
		len += (size_t)snprintf(html + len, cap - len, "<li style=\"padding-left:%uem\"><a href=\"toc:%u\">", depth, i);
		for (size_t k = 0; k < label_len; k++) {
			const char *esc = label[k] == '<' ? "&lt;" : label[k] == '&' ? "&amp;" : NULL;
			if (esc) len += (size_t)snprintf(html + len, cap - len, "%s", esc);
			else html[len++] = label[k];
		}
		len += (size_t)snprintf(html + len, cap - len, "</a></li>");
	}
	if (len + 8 > cap) {
		char *bigger = realloc(html, cap + 8);
		if (!bigger) {
			free(html);
			return NULL;
		}
		html = bigger;
	}
	memcpy(html + len, "</ul>", 5);
	*out_len = len + 5;
	return html;
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s BOOK.epub [LOCATOR]\n", argv[0]);
		return 2;
	}
	size_t len = 0;
	char *bytes = read_file(argv[1], &len);
	if (!bytes) {
		fprintf(stderr, "cannot read %s\n", argv[1]);
		return 1;
	}
	struct reader r = {.size_percent = 100};
	siv_result res = siv_app_create(NULL, &r.app);
	if (res == SIV_OK) res = siv_epub_open(r.app, (const uint8_t *)bytes, len, &r.epub);
	free(bytes); /* siv_epub_open copies the publication. */
	if (res != SIV_OK) {
		fprintf(stderr, "opening %s failed: %s\n", argv[1], siv_result_name(res));
		if (r.app) siv_app_destroy(r.app);
		return 1;
	}
	(void)siv_epub_get_counts(r.epub, &r.spine_count, &r.toc_count);
	size_t title_len = 0;
	if (siv_epub_get_metadata(r.epub, SIV_EPUB_FIELD_TITLE, r.title, sizeof r.title - 1, &title_len) != SIV_OK || title_len >= sizeof r.title) title_len = 0;
	r.title[title_len] = 0;

	res = siv_window_create(r.app, SIV_DESC(siv_window_desc, .title = r.title, .title_len = title_len, .width = 1200, .height = 860), &r.window);
	siv_txn txn;
	if (res == SIV_OK) res = siv_txn_begin(r.window, &txn);
	if (res == SIV_OK) {
		siv_node root = siv_window_get_root(r.window);
		siv_on(txn, root, SIV_EVENT_TYPE_KEY, on_key, NULL, &r);
		siv_set_stack(txn, root, SIV_DESC(siv_stack_desc, .align_x = SIV_ALIGN_CENTER, .align_y = SIV_ALIGN_END));
		r.column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN));
		siv_set_layout(txn, r.column, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
		siv_set_visual(txn, r.column, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_VIEW_BG));
		siv_node body = siv_flex(txn, r.column, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_ROW));
		siv_set_layout(txn, body, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .grow = 1));
		r.toc_scroll = siv_scroll(txn, body, SIV_SCROLL_AXIS_VERTICAL);
		siv_set_layout(txn, r.toc_scroll, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 300}, .height = {SIV_UNIT_FRACTION, 1}));
		siv_set_hidden(txn, r.toc_scroll, true);
		size_t html_len = 0;
		char *html = toc_html(&r, &html_len);
		r.toc = siv_docview(txn, r.toc_scroll, SIV_DESC(siv_docview_desc,
			.source = (const uint8_t *)html, .source_count = html ? html_len : 0,
			.user_data = &r, .on_event = on_doc_event));
		siv_set_layout(txn, r.toc, SIV_DESC(siv_layout_desc, .padding = {16, 16, 8, 8}));
		free(html);
		r.page_host = siv_flex(txn, body, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN));
		siv_set_layout(txn, r.page_host, SIV_DESC(siv_layout_desc, .height = {SIV_UNIT_FRACTION, 1}, .grow = 1, .basis = {SIV_UNIT_PX, 0}));
		r.status = siv_text(txn, r.column, "", 0);
		siv_set_layout(txn, r.status, SIV_DESC(siv_layout_desc, .padding = {12, 12, 6, 8}, .align_x = SIV_ALIGN_CENTER));
		siv_set_text_style(txn, r.status, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_MUTED_FG));
		/* The footnote popup, over the page at the bottom. */
		r.note_box = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN));
		siv_set_layout(txn, r.note_box, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 640}, .height = {SIV_UNIT_PX, 260}, .padding = {1, 1, 1, 1}, .align_y = SIV_ALIGN_END));
		siv_set_visual(txn, r.note_box, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_VIEW_BG, .border_token = SIV_COLOR_TOKEN_BORDER, .border_width = 1, .radius = {8, 8, 8, 8}));
		r.note_scroll = siv_scroll(txn, r.note_box, SIV_SCROLL_AXIS_VERTICAL);
		siv_set_layout(txn, r.note_scroll, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .grow = 1));
		siv_set_hidden(txn, r.note_box, true);
		res = siv_txn_commit(txn);
	}
	if (res != SIV_OK) {
		fprintf(stderr, "building the window failed: %s\n", siv_result_name(res));
		siv_epub_destroy(r.epub);
		siv_app_destroy(r.app);
		return 1;
	}
	/* LOCATOR is "SPINE:POSITION" as printed on exit. */
	uint32_t start = 0;
	const char *target = NULL;
	if (argc > 2) {
		char *colon = NULL;
		start = (uint32_t)strtoul(argv[2], &colon, 10);
		if (colon && *colon == ':') target = colon + 1;
	}
	open_chapter(&r, start, target, 0);
	res = siv_app_run(r.app);
	if (res != SIV_OK) fprintf(stderr, "siv_app_run: %s\n", siv_result_name(res));
	char position[256];
	size_t position_len = 0;
	if (siv_docview_get_position(r.doc, position, sizeof position, &position_len) == SIV_OK && position_len <= sizeof position)
		printf("position: %u:%.*s\n", r.spine, (int)position_len, position);
	siv_epub_destroy(r.epub);
	siv_app_destroy(r.app);
	return res == SIV_OK ? 0 : 1;
}
