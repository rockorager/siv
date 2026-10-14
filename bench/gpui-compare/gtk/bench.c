/* The GTK side of bench/gpui-compare: one program, one scenario per run.
 *
 *     gtk-bench idle|gallery|list|text|grid|typing
 *
 * Mirrors siv/bench.c with GTK 4's stock widgets, written as a GTK
 * application would be: GtkButton, a GtkMenuButton with a GMenu (a
 * GtkPopoverMenu, an xdg_popup on Wayland), GtkEntry, GtkCheckButton,
 * GtkListView over a list model for the 50 items and the 100,000 rows,
 * GtkTextView for the documents, and CSS animations for the grid.
 * README.md lists the differences that remain. */
#include <gtk/gtk.h>

#include "../common/doc.h"

static void set_margins(GtkWidget *w, int m) {
	gtk_widget_set_margin_start(w, m);
	gtk_widget_set_margin_end(w, m);
	gtk_widget_set_margin_top(w, m);
	gtk_widget_set_margin_bottom(w, m);
}

/* Idle ------------------------------------------------------------------------ */

static GtkWidget *build_idle(void) {
	GtkWidget *label = gtk_label_new("Idle window");
	gtk_widget_set_halign(label, GTK_ALIGN_START);
	gtk_widget_set_valign(label, GTK_ALIGN_START);
	set_margins(label, 24);
	return label;
}

/* Gallery --------------------------------------------------------------------- */

static GtkWidget *status;

static void set_status(const char *what) {
	char text[96];
	snprintf(text, sizeof text, "Last action: %s", what);
	gtk_label_set_text(GTK_LABEL(status), text);
}

static void on_button(GtkWidget *w, gpointer what) {
	(void)w;
	set_status(what);
}

static const char *menu_items[] = {"New", "Open", "Save", "Save As", "Close", "Quit"};

static void on_menu(GSimpleAction *action, GVariant *param, gpointer data) {
	(void)action, (void)param;
	set_status(data);
}

static void setup_label(GtkSignalListItemFactory *f, GtkListItem *item, gpointer data) {
	(void)f, (void)data;
	GtkWidget *label = gtk_label_new(NULL);
	gtk_label_set_xalign(GTK_LABEL(label), 0);
	gtk_widget_set_size_request(label, -1, 32);
	gtk_list_item_set_child(item, label);
}

static void bind_label(GtkSignalListItemFactory *f, GtkListItem *item, gpointer data) {
	(void)f, (void)data;
	gtk_label_set_text(GTK_LABEL(gtk_list_item_get_child(item)), gtk_string_object_get_string(gtk_list_item_get_item(item)));
}

static void on_selected(GtkSingleSelection *sel, GParamSpec *pspec, gpointer data) {
	(void)pspec, (void)data;
	char what[32];
	snprintf(what, sizeof what, "Item %u", gtk_single_selection_get_selected(sel) + 1);
	set_status(what);
}

static GtkWidget *build_gallery(GtkWindow *window, GtkWidget **focus) {
	GtkWidget *c = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
	set_margins(c, 24);
	gtk_widget_set_halign(c, GTK_ALIGN_START);
	gtk_widget_set_valign(c, GTK_ALIGN_START);

	GtkWidget *title = gtk_label_new(NULL);
	gtk_label_set_markup(GTK_LABEL(title), "<span size='150%' weight='bold'>Widget gallery</span>");
	gtk_widget_set_halign(title, GTK_ALIGN_START);
	gtk_box_append(GTK_BOX(c), title);

	GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
	GtkWidget *b = gtk_button_new_with_label("Default");
	g_signal_connect(b, "clicked", G_CALLBACK(on_button), "Default");
	gtk_box_append(GTK_BOX(buttons), b);
	b = gtk_button_new_with_label("Primary");
	gtk_widget_add_css_class(b, "suggested-action");
	g_signal_connect(b, "clicked", G_CALLBACK(on_button), "Primary");
	gtk_box_append(GTK_BOX(buttons), b);
	b = gtk_button_new_with_label("Disabled");
	gtk_widget_set_sensitive(b, FALSE);
	gtk_box_append(GTK_BOX(buttons), b);
	GMenu *menu = g_menu_new();
	GSimpleActionGroup *actions = g_simple_action_group_new();
	for (int i = 0; i < 6; i++) {
		char name[16], detailed[24];
		snprintf(name, sizeof name, "item%d", i);
		snprintf(detailed, sizeof detailed, "menu.item%d", i);
		GSimpleAction *a = g_simple_action_new(name, NULL);
		g_signal_connect(a, "activate", G_CALLBACK(on_menu), (gpointer)menu_items[i]);
		g_action_map_add_action(G_ACTION_MAP(actions), G_ACTION(a));
		g_menu_append(menu, menu_items[i], detailed);
	}
	gtk_widget_insert_action_group(GTK_WIDGET(window), "menu", G_ACTION_GROUP(actions));
	b = gtk_menu_button_new();
	gtk_menu_button_set_label(GTK_MENU_BUTTON(b), "Menu");
	gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(b), G_MENU_MODEL(menu));
	gtk_box_append(GTK_BOX(buttons), b);
	gtk_box_append(GTK_BOX(c), buttons);

	GtkWidget *field = gtk_entry_new();
	gtk_entry_set_placeholder_text(GTK_ENTRY(field), "Type here");
	gtk_widget_set_size_request(field, 320, -1);
	gtk_widget_set_halign(field, GTK_ALIGN_START);
	gtk_box_append(GTK_BOX(c), field);

	GtkWidget *check = gtk_check_button_new_with_label("Enable feature");
	g_signal_connect(check, "toggled", G_CALLBACK(on_button), "Toggled");
	gtk_box_append(GTK_BOX(c), check);

	GtkStringList *items = gtk_string_list_new(NULL);
	for (int i = 0; i < 50; i++) {
		char text[32];
		snprintf(text, sizeof text, "Item %d", i + 1);
		gtk_string_list_append(items, text);
	}
	GtkSingleSelection *sel = gtk_single_selection_new(G_LIST_MODEL(items));
	gtk_single_selection_set_autoselect(sel, FALSE);
	gtk_single_selection_set_can_unselect(sel, TRUE);
	gtk_single_selection_set_selected(sel, GTK_INVALID_LIST_POSITION);
	g_signal_connect(sel, "notify::selected", G_CALLBACK(on_selected), NULL);
	GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
	g_signal_connect(factory, "setup", G_CALLBACK(setup_label), NULL);
	g_signal_connect(factory, "bind", G_CALLBACK(bind_label), NULL);
	GtkWidget *list = gtk_list_view_new(GTK_SELECTION_MODEL(sel), factory);
	GtkWidget *scroll = gtk_scrolled_window_new();
	gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list);
	gtk_scrolled_window_set_has_frame(GTK_SCROLLED_WINDOW(scroll), TRUE);
	gtk_widget_set_size_request(scroll, 320, 320);
	gtk_widget_set_halign(scroll, GTK_ALIGN_START);
	gtk_box_append(GTK_BOX(c), scroll);

	status = gtk_label_new("Last action: none");
	gtk_widget_add_css_class(status, "dim-label");
	gtk_widget_set_halign(status, GTK_ALIGN_START);
	gtk_box_append(GTK_BOX(c), status);
	*focus = field;
	return c;
}

/* 100k-row list: a list model that makes its items when asked ------------------- */

#define ROWS_TYPE (rows_get_type())
G_DECLARE_FINAL_TYPE(Rows, rows, BENCH, ROWS, GObject)
struct _Rows {
	GObject parent;
};

static GType rows_item_type(GListModel *m) {
	(void)m;
	return GTK_TYPE_STRING_OBJECT;
}
static guint rows_n_items(GListModel *m) {
	(void)m;
	return 100000;
}
static gpointer rows_item(GListModel *m, guint i) {
	(void)m;
	if (i >= 100000) return NULL;
	char text[32];
	snprintf(text, sizeof text, "Row %u", i + 1);
	return gtk_string_object_new(text);
}
static void rows_iface_init(GListModelInterface *iface) {
	iface->get_item_type = rows_item_type;
	iface->get_n_items = rows_n_items;
	iface->get_item = rows_item;
}
G_DEFINE_TYPE_WITH_CODE(Rows, rows, G_TYPE_OBJECT, G_IMPLEMENT_INTERFACE(G_TYPE_LIST_MODEL, rows_iface_init))
static void rows_class_init(RowsClass *c) { (void)c; }
static void rows_init(Rows *r) { (void)r; }

static void setup_row(GtkSignalListItemFactory *f, GtkListItem *item, gpointer data) {
	(void)f, (void)data;
	GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
	gtk_widget_set_size_request(row, -1, 28);
	GtkWidget *name = gtk_label_new(NULL);
	gtk_label_set_xalign(GTK_LABEL(name), 0);
	gtk_widget_set_size_request(name, 100, -1);
	GtkWidget *desc = gtk_label_new(NULL);
	gtk_label_set_xalign(GTK_LABEL(desc), 0);
	gtk_widget_add_css_class(desc, "dim-label");
	gtk_box_append(GTK_BOX(row), name);
	gtk_box_append(GTK_BOX(row), desc);
	gtk_list_item_set_child(item, row);
}

static void bind_row(GtkSignalListItemFactory *f, GtkListItem *item, gpointer data) {
	(void)f, (void)data;
	GtkWidget *name = gtk_widget_get_first_child(gtk_list_item_get_child(item));
	gtk_label_set_text(GTK_LABEL(name), gtk_string_object_get_string(gtk_list_item_get_item(item)));
	char desc[96];
	snprintf(desc, sizeof desc, "Description of row %u with a few more words", gtk_list_item_get_position(item) + 1);
	gtk_label_set_text(GTK_LABEL(gtk_widget_get_next_sibling(name)), desc);
}

static GtkWidget *build_list(void) {
	GtkNoSelection *sel = gtk_no_selection_new(G_LIST_MODEL(g_object_new(ROWS_TYPE, NULL)));
	GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
	g_signal_connect(factory, "setup", G_CALLBACK(setup_row), NULL);
	g_signal_connect(factory, "bind", G_CALLBACK(bind_row), NULL);
	GtkWidget *list = gtk_list_view_new(GTK_SELECTION_MODEL(sel), factory);
	GtkWidget *scroll = gtk_scrolled_window_new();
	gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list);
	return scroll;
}

/* Text: an editable document -------------------------------------------------------- */

/* F3 finds the needle after the caret (from the start again past the
 * last), selects it, and scrolls to show it. */
static gboolean on_search(GtkWidget *widget, GVariant *args, gpointer data) {
	(void)args, (void)data;
	GtkTextView *view = GTK_TEXT_VIEW(widget);
	GtkTextBuffer *buf = gtk_text_view_get_buffer(view);
	GtkTextIter at, start, end;
	gtk_text_buffer_get_iter_at_mark(buf, &at, gtk_text_buffer_get_insert(buf));
	if (!gtk_text_iter_forward_search(&at, DOC_NEEDLE, 0, &start, &end, NULL)) {
		gtk_text_buffer_get_start_iter(buf, &at);
		if (!gtk_text_iter_forward_search(&at, DOC_NEEDLE, 0, &start, &end, NULL)) return TRUE;
	}
	gtk_text_buffer_select_range(buf, &end, &start);
	gtk_text_view_scroll_mark_onscreen(view, gtk_text_buffer_get_insert(buf));
	return TRUE;
}

static GtkWidget *build_editor(char *doc, size_t len, GtkWidget **focus) {
	GtkWidget *view = gtk_text_view_new();
	gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD_CHAR);
	gtk_text_view_set_left_margin(GTK_TEXT_VIEW(view), 24);
	gtk_text_view_set_right_margin(GTK_TEXT_VIEW(view), 24);
	gtk_text_view_set_top_margin(GTK_TEXT_VIEW(view), 24);
	gtk_text_view_set_bottom_margin(GTK_TEXT_VIEW(view), 24);
	GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
	gtk_text_buffer_set_text(buf, doc, (int)len);
	free(doc);
	GtkTextIter start;
	gtk_text_buffer_get_start_iter(buf, &start);
	gtk_text_buffer_place_cursor(buf, &start);
	GtkEventController *keys = gtk_shortcut_controller_new();
	gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(keys),
	                                     gtk_shortcut_new(gtk_keyval_trigger_new(GDK_KEY_F3, 0), gtk_callback_action_new(on_search, NULL, NULL)));
	gtk_widget_add_controller(view, keys);
	GtkWidget *scroll = gtk_scrolled_window_new();
	gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), view);
	*focus = view;
	return scroll;
}

/* Grid: 2,560 boxes, each fading by a CSS animation with its own delay ---------- */

static GtkWidget *build_grid(void) {
	GString *css = g_string_new(".cell { border-radius: 3px; animation: fade 1s cubic-bezier(0.42, 0, 0.58, 1) infinite alternate; }\n"
	                            "@keyframes fade { from { opacity: 1; } to { opacity: 0.2; } }\n");
	for (int i = 0; i < 6; i++) g_string_append_printf(css, ".k%d { background-color: #%06x; }\n", i, grid_color(i * 3));
	for (int i = 0; i < 20; i++) g_string_append_printf(css, ".d%d { animation-delay: %dms; }\n", i, i * 50);
	GtkCssProvider *provider = gtk_css_provider_new();
	gtk_css_provider_load_from_string(provider, css->str);
	gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
	g_string_free(css, TRUE);
	GtkWidget *grid = gtk_grid_new();
	gtk_grid_set_row_spacing(GTK_GRID(grid), 4);
	gtk_grid_set_column_spacing(GTK_GRID(grid), 4);
	set_margins(grid, 2);
	gtk_widget_set_halign(grid, GTK_ALIGN_START);
	gtk_widget_set_valign(grid, GTK_ALIGN_START);
	for (int i = 0; i < GRID_COLS * GRID_ROWS; i++) {
		GtkWidget *cell = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
		gtk_widget_set_size_request(cell, 16, 16);
		char color[8], delay[8];
		snprintf(color, sizeof color, "k%d", (i / 3) % 6);
		snprintf(delay, sizeof delay, "d%u", grid_delay_ms(i) / 50);
		gtk_widget_add_css_class(cell, "cell");
		gtk_widget_add_css_class(cell, color);
		gtk_widget_add_css_class(cell, delay);
		gtk_grid_attach(GTK_GRID(grid), cell, i % GRID_COLS, i / GRID_COLS, 1, 1);
	}
	return grid;
}

static const char *scenario;

static void activate(GtkApplication *app, gpointer data) {
	(void)data;
	GtkWidget *window = gtk_application_window_new(app);
	char title[64];
	snprintf(title, sizeof title, "bench %s", scenario);
	gtk_window_set_title(GTK_WINDOW(window), title);
	gtk_window_set_default_size(GTK_WINDOW(window), 1280, 800);
	/* List rows as high as their content asks (32 px in the gallery, 28 in
	 * the list), as in the other programs. */
	GtkCssProvider *css = gtk_css_provider_new();
	gtk_css_provider_load_from_string(css, "listview > row { padding-top: 0; padding-bottom: 0; }");
	gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
	GtkWidget *focus = NULL, *child;
	size_t len = 0;
	if (strcmp(scenario, "idle") == 0) child = build_idle();
	else if (strcmp(scenario, "gallery") == 0) child = build_gallery(GTK_WINDOW(window), &focus);
	else if (strcmp(scenario, "list") == 0) child = build_list();
	else if (strcmp(scenario, "text") == 0) {
		char *doc = doc_generate(DOC_LARGE_PARAGRAPHS, &len);
		child = build_editor(doc, len, &focus);
	} else if (strcmp(scenario, "typing") == 0) {
		char *doc = doc_generate(DOC_SMALL_PARAGRAPHS, &len);
		child = build_editor(doc, len, &focus);
	} else if (strcmp(scenario, "grid") == 0) child = build_grid();
	else {
		fprintf(stderr, "unknown scenario %s\n", scenario);
		exit(2);
	}
	gtk_window_set_child(GTK_WINDOW(window), child);
	if (focus) gtk_window_set_focus(GTK_WINDOW(window), focus);
	gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
	scenario = argc > 1 ? argv[1] : "idle";
	/* A steady caret and no transitions, as siv runs with reduced
	 * motion except in the grid; the font every toolkit uses. */
	gtk_init();
	g_object_set(gtk_settings_get_default(), "gtk-cursor-blink", FALSE, "gtk-enable-animations", strcmp(scenario, "grid") == 0,
	             "gtk-font-name", BENCH_FONT " 11", NULL);
	GtkApplication *app = gtk_application_new("org.siv.GtkBench", G_APPLICATION_NON_UNIQUE);
	g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
	int status = g_application_run(G_APPLICATION(app), 1, argv);
	g_object_unref(app);
	return status;
}
