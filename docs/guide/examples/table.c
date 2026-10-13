/* A virtualized table of 100 000 rows: only the rows in view exist as
 * nodes, bound as they scroll in. Columns sort and resize; rows select
 * with the keyboard and pointer, Ctrl and Shift included.
 *
 *     zig build guide && ./zig-out/bin/guide-table
 */
#include <siv.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define S(str) (str), strlen(str)
#define COUNT 100000

/* Commits a transaction made in a handler. There is nothing to undo when
 * one fails (siv discarded it), so report it and go on. */
static void commit(siv_txn txn) {
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "siv_txn_commit: %s\n", siv_result_name(r));
}

/* A node's neighbor, or 0. */
static siv_node related(siv_node node, siv_relation which) {
	siv_node out = 0;
	return siv_node_get_related(node, which, &out) == SIV_OK ? out : 0;
}

static const char *const kinds[] = {"Document", "Image", "Audio", "Archive"};

struct file {
	uint32_t number;
	uint32_t size;
	uint8_t kind;
};

struct model {
	siv_window window;
	siv_node table;
	siv_node status;
	struct file *files;
	/* The rows' order: row i shows files[order[i]]. */
	uint32_t *order;
};

/* Fills a row with its cells the first time, then only updates them: a
 * recycled row still holds the cells an earlier bind made. Rows of a
 * table are grids with the columns' tracks, one cell per column. */
static void bind(void *user_data, siv_txn txn, siv_node row, uint64_t item, uint32_t index, uint32_t depth, bool recycled) {
	(void)index;
	(void)depth;
	struct model *m = user_data;
	const struct file *f = &m->files[m->order[item]];
	if (!recycled) {
		for (uint32_t column = 1; column <= 3; column++) {
			siv_node text = siv_text(txn, row, NULL, 0);
			siv_set_text_style(txn, text, SIV_DESC(siv_text_style_desc, .color_token = column == 1 ? SIV_COLOR_TOKEN_VIEW_FG : SIV_COLOR_TOKEN_MUTED_FG, .align = column == 2 ? SIV_TEXT_ALIGN_END : SIV_TEXT_ALIGN_START, .flags = SIV_TEXT_NO_WRAP | SIV_TEXT_ELLIPSIZE));
			siv_set_semantics(txn, text, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_CELL, .column = column));
		}
	}
	siv_node cell = related(row, SIV_RELATION_FIRST_CHILD);
	char name[32], size[32];
	snprintf(name, sizeof name, "File %05u", (unsigned)f->number);
	if (f->size < 1000) snprintf(size, sizeof size, "%u bytes", (unsigned)f->size);
	else snprintf(size, sizeof size, "%u.%u kB", (unsigned)(f->size / 1000), (unsigned)(f->size % 1000 / 100));
	const char *texts[] = {name, size, kinds[f->kind]};
	for (int i = 0; i < 3 && cell; i++, cell = related(cell, SIV_RELATION_NEXT)) siv_set_text(txn, cell, S(texts[i]));
}

/* Sorting: the view only shows the order. The handler sorts the items,
 * returns handled so the header shows the column sorted, and rebinds. */
static const struct file *sort_files;
static int sort_column, sort_sign;

static int compare(const void *a, const void *b) {
	const struct file *x = &sort_files[*(const uint32_t *)a], *y = &sort_files[*(const uint32_t *)b];
	int64_t d = sort_column == 1 ? (int64_t)x->size - y->size : sort_column == 2 ? x->kind - y->kind : 0;
	if (d == 0) d = (int64_t)x->number - y->number;
	return sort_sign * (d < 0 ? -1 : d > 0);
}

static siv_event_result on_sort(void *user_data, siv_node table, const siv_event *event) {
	struct model *m = user_data;
	sort_files = m->files;
	sort_column = (int)event->index;
	sort_sign = event->value > 0 ? 1 : -1;
	qsort(m->order, COUNT, sizeof *m->order, compare);
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_view_refresh(txn, table);
	return siv_txn_commit(txn) == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
}

static void set_status(struct model *m, const char *text) {
	siv_txn txn;
	if (siv_txn_begin(m->window, &txn) != SIV_OK) return;
	siv_set_text(txn, m->status, S(text));
	commit(txn);
}

static siv_event_result on_select(void *user_data, siv_node table, const siv_event *event) {
	(void)table;
	char text[64];
	snprintf(text, sizeof text, "%u of %u selected", (unsigned)event->count, COUNT);
	set_status(user_data, text);
	return SIV_EVENT_RESULT_HANDLED;
}

/* Enter or a double click on a row. */
static siv_event_result on_activate(void *user_data, siv_node table, const siv_event *event) {
	(void)table;
	struct model *m = user_data;
	char text[64];
	snprintf(text, sizeof text, "Opened File %05u", (unsigned)m->files[m->order[event->index]].number);
	set_status(m, text);
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_result build(struct model *m) {
	siv_txn txn;
	siv_result r = siv_txn_begin(m->window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_root(m->window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 8));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}, .padding = {12, 12, 12, 12}));

	m->table = siv_table_view(txn, column, SIV_DESC(siv_view_desc, .label = S("Files"), .user_data = m, .bind = bind, .count = COUNT, .item_height = 28, .selection = SIV_SELECTION_MODE_MULTIPLE));
	siv_set_layout(txn, m->table, SIV_DESC(siv_layout_desc, .grow = 1, .basis = {SIV_UNIT_PX, 0}));
	siv_set_visual(txn, m->table, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_VIEW_BG, .border_token = SIV_COLOR_TOKEN_BORDER, .border_width = 1, .radius = {6, 6, 6, 6}, .flags = SIV_VISUAL_CLIP));
	siv_table_column(txn, m->table, SIV_DESC(siv_column_desc, .title = S("Name"), .width = {SIV_TRACK_UNIT_FR, 2}, .flags = SIV_COLUMN_SORTABLE));
	siv_table_column(txn, m->table, SIV_DESC(siv_column_desc, .title = S("Size"), .width = {SIV_TRACK_UNIT_PX, 100}, .flags = SIV_COLUMN_SORTABLE));
	siv_table_column(txn, m->table, SIV_DESC(siv_column_desc, .title = S("Kind"), .width = {SIV_TRACK_UNIT_FR, 1}, .flags = SIV_COLUMN_SORTABLE));
	siv_view_set_sort(txn, m->table, 0, SIV_SORT_ASCENDING);
	siv_on(txn, m->table, SIV_EVENT_TYPE_SORT, on_sort, NULL, m);
	siv_on(txn, m->table, SIV_EVENT_TYPE_SELECT, on_select, NULL, m);
	siv_on(txn, m->table, SIV_EVENT_TYPE_ACTIVATE, on_activate, NULL, m);

	m->status = siv_text(txn, column, S("100000 files"));
	siv_set_text_style(txn, m->status, SIV_DESC(siv_text_style_desc, .size_role = SIV_SIZE_ROLE_CAPTION, .color_token = SIV_COLOR_TOKEN_MUTED_FG));
	return siv_txn_commit(txn);
}

int main(void) {
	struct model m = {0};
	m.files = malloc(COUNT * sizeof *m.files);
	m.order = malloc(COUNT * sizeof *m.order);
	if (!m.files || !m.order) return 1;
	uint32_t seed = 1;
	for (uint32_t i = 0; i < COUNT; i++) {
		seed = seed * 1103515245u + 12345u;
		m.files[i] = (struct file){.number = i + 1, .size = (seed >> 8) % 500000, .kind = (uint8_t)(i % 4)};
		m.order[i] = i;
	}
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r == SIV_OK) {
		r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = S("Files"), .width = 440, .height = 320), &m.window);
		if (r == SIV_OK) r = build(&m);
		if (r == SIV_OK) r = siv_app_run(app);
		siv_app_destroy(app);
	}
	if (r != SIV_OK) fprintf(stderr, "table: %s\n", siv_result_name(r));
	free(m.files);
	free(m.order);
	return r == SIV_OK ? 0 : 1;
}
