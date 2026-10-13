# Accessibility

Every siv window has a semantics tree that screen readers (Orca),
magnifiers, and other assistive technology read through AT-SPI (D18). siv
builds it from your nodes and publishes it only while the desktop has
accessibility turned on, so it costs nothing otherwise. Stock widgets fill
it in completely. Nodes of your own need a few things from you.

## What siv does

- Every node has a role by its kind: containers are generic (and left out
  of the tree unless they have a name or take focus), text nodes are
  labels, editors are text inputs, scroll nodes scroll areas, images
  images.
- Buttons, list items, rows, cells, and similar roles without a label take
  their name from the text inside them, so a row reads "notes.txt 1.2 kB
  Text".
- Text, editing, caret and selection movement, and text attributes (spans
  and paragraph styles) are exposed for text nodes and editors. Masked
  editors expose neither their text nor their caret.
- Focus moves and the focused node reach the screen reader; Tab order is
  tree order; modal nodes hold focus.
- Views report each row's position and the set's size, tree items their
  level, and table rows and cells their indices, though most rows have no
  node.
- Nodes with an activate handler get an action (click, toggle, jump), and
  nodes with a value can be set through the Value interface.

## What you do

**Give interactive nodes a role, a name, and focus.** A box you make
clickable is generic to a screen reader until you say otherwise. Set the
role of what it acts like, and make it focusable, which siv allows only
together with semantics, so keyboard users and screen reader users get the
same thing. From [examples/events.c](examples/events.c):

```c
/* Focusable with a role and a name: Tab reaches it, Enter and
 * Space activate it, and a screen reader announces it. */
siv_set_semantics(txn, tile, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_BUTTON, .label = names[i], strlen(names[i]), .flags = SIV_SEMANTICS_FOCUSABLE));
```

**Name things that have no text.** An icon-only button, an image that
means something, a canvas, a text field without a visible label: set
`label` in the semantics (or the widget's label, which becomes its name).
Decorative images get `SIV_ROLE_NONE`, which leaves them out.

**Expose state.** `checked`, `pressed`, `selected`, and `expanded` for
toggles, selections, and disclosures; `level` for headings;
`SIV_SEMANTICS_HAS_VALUE` with `value_min`, `value_max`, `value_now`, and
`value_step` for anything with a value. Update them in the same
transaction as what they describe. A node with a value can be set by
assistive technology: handle `SIV_EVENT_TYPE_SET_VALUE`, clamping and
stepping the value as a key press would. The segmented control in
[Custom widgets](06-custom-widgets.md) exposes each option's checked state,
position, and set size:

```c
siv_set_semantics(txn, seg, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_RADIO, .checked = on ? SIV_TOGGLE_ON : SIV_TOGGLE_OFF, .position = (uint32_t)i + 1, .set_size = s->count, .flags = on ? SIV_SEMANTICS_FOCUSABLE : 0));
```

**Announce what changes without focus.** A status line, a finished job,
an error that appears: mark the node as a live region
(`SIV_SEMANTICS_LIVE_POLITE`, or `SIV_SEMANTICS_LIVE_ASSERTIVE` for what
cannot wait), and its changes are announced. Toasts do this by themselves.
From [examples/jobs.c](examples/jobs.c):

```c
/* A live region: screen readers announce the result when it comes. */
ui->result = siv_text(txn, column, SIV_STR("Count the primes below 200000"));
siv_set_text_style(txn, ui->result, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_WINDOW_FG));
siv_set_semantics(txn, ui->result, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_STATUS, .flags = SIV_SEMANTICS_LIVE_POLITE));
```

**Mark structure.** Headings (`SIV_ROLE_HEADING` with a `level`) let
screen reader users jump through a window; groups with a label (a
toolbar, a set of filters) name a region.

**Describe drawings.** A canvas is an image with no name. Name it and put
what it shows in its description, as the chart in
[Custom widgets](06-custom-widgets.md#on-a-canvas) does, or put a list of
the data in nodes beside it.

**Support the keyboard.** Everything the pointer does needs a key:
activation comes free with a role and an activate handler; arrow keys in
composite widgets follow the WAI-ARIA patterns, mirrored right to left.
siv draws the focus ring for keyboard focus; do not draw your own instead.

**Follow the desktop.** Use themed colors and text sizes, so high
contrast, dark themes, and larger text apply to your nodes, and leave
motion to transitions and animations, which stop when the user asks for
reduced motion.

## Checking

Read your application's tree with Accerciser, or turn on Orca and use the
application with the screen off: every action should be reachable, and
everything announced should make sense without seeing it. siv's own tests
read semantics trees on the headless backend, but there is no public API
for that yet.
