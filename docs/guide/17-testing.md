# Testing

siv runs your application without a display on its headless backend:
windows render into memory, through the same layout, painting, and input
handling as on Wayland. The `siv_test_*` calls (D27) drive it from a test
as a user would and read what it shows: they inject pointer, keyboard, and
drop input, wait until it is idle, capture what a window presented, and
query the semantics tree a screen reader reads. Every sample in this guide
is tested this way. They work on the headless backend only and fail with
`SIV_ERROR_UNSUPPORTED` on Wayland.

## A headless application

Create the application with `SIV_BACKEND_HEADLESS`. A test should also
leave the machine out of it: no system fonts or icon themes, no desktop
settings (the headless backend never follows them), and no motion, so the
same test sees the same pixels on every machine. It then adds its own font,
here from a path the test is given. [examples/counter_test.c](examples/counter_test.c)
tests hello.c's counter:

```c
siv_app app;
/* No system fonts, icons, or desktop settings, and no motion: the same
 * pixels on every machine. */
siv_result r = siv_app_create(SIV_DESC(siv_app_desc, .backend = SIV_BACKEND_HEADLESS,
	.flags = SIV_APP_NO_SYSTEM_FONTS | SIV_APP_NO_SYSTEM_ICONS | SIV_APP_REDUCED_MOTION), &app);
```

```c
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
```

Without any font, text has nothing to lay out with; always add one.

## Settling

A test does not call `siv_app_run`. Input it injects is queued like a
compositor's, and `siv_test_settle` dispatches until the application is
idle: every shown window has presented what it committed and wants no
frame, the compositor has presented every frame it owes (for the input,
for a scroll or fling it runs itself, for a transition), and no font,
icon, image load, job, paste, or drop is in flight. It waits for the
events that end this work, however long the frames take, rather than
for a moment of quiet. It gives up after a timeout and says whether it
settled. It does not wait for timers, portal requests, or threads of
your own; wait for what they show instead, dispatching with
`siv_app_dispatch` until it appears.

```c
/* Delivers the input so far and waits until every frame is presented and
 * nothing is loading. */
static void settle(siv_app app) {
	bool settled = false;
	CHECK(siv_test_settle(app, 5000, &settled) == SIV_OK && settled);
}
```

Animations that repeat, such as a caret's blink or a spinner, never end,
so settling does not wait for them, and a capture can catch them in any
phase; reduced motion stops them. A window your code redraws on every
frame without end never settles.

## Finding and driving

`siv_test_find` returns a node of the semantics tree that matches a
`siv_test_query` (a role, an exact accessible name, the focused node, and
which match), with its bounds in window coordinates and its states
(checked, selected, expanded, value, focus). Finding nodes the way a screen
reader does keeps tests independent of your tree's shape, and fails when
a control has no accessible name:

```c
/* Whether some node reads `text`. */
static bool reads(siv_window window, const char *text) {
	bool found = false;
	siv_test_node node;
	return siv_test_find(window, SIV_DESC(siv_test_query, .name = text, .name_len = strlen(text)), &found, &node) == SIV_OK && found;
}
```

`siv_test_click`, `siv_test_pointer_move`, `siv_test_pointer_button`, and
`siv_test_scroll` are the pointer; `siv_test_key` presses and releases one
key with modifiers and the text it produces, and `siv_test_type` types a
string; `siv_test_close` asks to close a window; `siv_test_drop` drags data
in from another application and drops it. Popups (menus, popovers) are
windows too: `siv_test_get_popup` returns the newest one shown, to find
nodes and send keys in it.

```c
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
```

When a check fails, `siv_test_dump` gives the whole tree as text, a line
per node with its role, name, states, and bounds, which is also usable as
a snapshot:

```c
if (failures) {
	/* What a screen reader would read, to see why. */
	char tree[4096];
	if (siv_test_dump(window, tree, sizeof tree, &len) == SIV_OK) fprintf(stderr, "%.*s", (int)(len < sizeof tree ? len : sizeof tree), tree);
}
```

## Captures

`siv_test_capture` copies what a window presented: RGBA rows with
premultiplied alpha, at the window's buffer scale. Pass no buffer to ask
for the size. Compare captures with images you keep beside the tests,
allowing a channel or two of difference, since a later siv may antialias
differently.

```c
/* What the window shows: RGBA rows, here the opaque background. */
size_t len = 0;
uint32_t width = 0, height = 0;
CHECK(siv_test_capture(window, NULL, 0, &len, &width, &height) == SIV_OK);
CHECK(width == 320 && height == 160 && len == (size_t)width * height * 4);
uint8_t *pixels = malloc(len);
CHECK(pixels && siv_test_capture(window, pixels, len, &len, &width, &height) == SIV_OK);
CHECK(pixels && pixels[3] == 255);
free(pixels);
```

## Zig and Lua

The Zig API has the same calls (`siv.testSettle`, `siv.testFind`,
`siv.testClick`, ...), with Zig errors. In Lua they are methods of the
application and windows, out values are return values, and a query is a
table. [examples/counter_test.lua](examples/counter_test.lua) is the same
test, as a script that raises on the first failure:

```lua
local function settle()
	assert(app:test_settle(5000), "the window did not settle")
end

local function expect_text(text)
	if not win:test_find{ name = text } then
		error(("nothing reads %q; the window reads:\n%s"):format(text, win:test_dump()), 2)
	end
end
```

```lua
local found, button = win:test_find{ role = "button", name = "Click me" }
assert(found)
local b = button.bounds
win:test_click(b.x + b.width / 2, b.y + b.height / 2, "primary")
settle()
expect_text("Clicked 1 time")

win:test_key("tab", {}, "")
win:test_key("return", {}, "\r")
settle()
expect_text("Clicked 2 times")
assert(win:test_get_name{ flags = "focused" } == "Click me")
```

Run it with `siv-lua` from any test runner; it exits with an error and the
tree when a check fails.
