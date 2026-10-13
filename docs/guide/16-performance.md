# Performance

siv is built so that the obvious program is fast: layout is incremental,
painting is per layer, scrolling and animation run on their own thread,
and an idle application wakes up for nothing (D25 sets the budgets: first
frame under 20 ms, input to screen within a frame, 120 Hz scrolling
through a 100 000-row list, no idle wakeups). A few habits keep it that
way.

**Keep your thread free.** Handlers, layout, and painting share it. Move
file and network access to blocking jobs and heavy computation to compute
jobs ([Work off the UI thread](09-async.md)); load images with
`siv_image_load`, never by decoding them yourself in a handler. A busy
thread does not stop scrolling or animations, but it delays input and new
content.

**Batch changes.** One transaction per event, not one per node: each
commit can cost a frame's worth of work, and a transaction is applied all
at once. Changes to unrelated nodes in one commit cost no more than their
own layout and repaint.

**Change little.** Setting a node's text relays that node and its
ancestors only; a subtree whose constraints did not change costs one
comparison. Moving, fading, transforming, and scrolling
a node with a layer of its own changes the layer, not its content. For a
node you will animate, set `SIV_VISUAL_LAYER` and use
`siv_set_transition` or `siv_set_animation`, which run on the compositor
without your thread.

**Virtualize long lists.** A view binds only what is on screen; a box of
10 000 rows makes 10 000 nodes. Give rows a fixed height or a height
callback, never sizes that depend on their bound content.

**Redraw canvases only when they change.** A canvas draws again only when
invalidated, and its own layer keeps a redraw from touching anything
else. Do not invalidate on every frame: for motion, transform the canvas
node, or split what moves into a canvas of its own.

**Size images to their display.** Pass `max_width`, `max_height`, and the
window's scale to `siv_image_load`; cancel loads that scrolled out of view
and raise the priority of what is on screen.

**Leave the idle loop idle.** Nothing in siv polls. Use timers instead of
sleeping threads, `siv_app_watch_fd` instead of a thread blocked in
`poll`, and one-shot timers rescheduled from their callback rather than a
fast tick. Carets blink for a limited time after input and animations stop
when hidden, so a window left alone draws nothing.

## Measuring

Each window reports `SIV_WINDOW_EVENT_TYPE_PRESENTED` when a frame with
everything committed so far reaches the compositor, with the commit count
it shows (`frame`), when it was committed (`commit_ns`), and when it is
predicted to be on screen (`present_ns`), on `CLOCK_MONOTONIC`. It costs
nothing and comes only after commits, so it measures startup to first
frame, or a change to the screen, without instrumenting siv. siv's
renderer runs on Vulkan when a device is present and on the CPU
otherwise; both draw the same pixels.

Build releases with `-Doptimize=ReleaseSafe` or `ReleaseFast`: debug
builds of siv are several times slower at rendering and text.
