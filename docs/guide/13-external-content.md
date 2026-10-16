# External surfaces and video

Some content is rendered outside siv: video from a decoder, a 3D view in
Vulkan or OpenGL, frames from GStreamer or libmpv. siv shows it in an
external node, which sits in the tree, lays out, clips, and stacks like
any node (D17). The content comes from a slot (`siv_external`) of one of
two kinds:

- A **frame slot** (`siv_external_create`) takes frames you submit, in
  shared memory or as dma-bufs.
- A **surface slot** (`siv_external_create_surface`) gives you a
  `wl_surface` to render into with your own EGL, Vulkan, or GStreamer.

Either way siv lets the Wayland compositor show the content on a
subsurface of its own, without a copy, when it can: the node is
axis-aligned, opaque, and clipped only by rectangles. When it cannot (a
rounded clip, a rotation, translucency), siv draws the content into the
window instead, through Vulkan for dma-bufs.

## Frame slots

[examples/video.c](examples/video.c) plays a test pattern from a producer
thread, as a video decoder would:

![Color bars with a white bar across them, in a frame with rounded corners, above the text Played 60 frames](images/video.png)

The slot belongs to a window, and an external node shows it with an
intrinsic size (the content's size or aspect ratio) and a fit:

```c
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
```

Frames go straight to siv's compositor thread from any thread, so playback
never waits for your application's thread. A frame names its pixels by an
fd siv can map (a memfd here), an offset, a size, and a `key` that changes
whenever the pixels do:

```c
/* The key names the pixels: it comes back in on_release. */
siv_external_frame_desc frame = {.size = sizeof frame, .key = (uint64_t)n, .fd = p->fd, .offset = (uint32_t)(buffer * FRAME_BYTES), .width = WIDTH, .height = HEIGHT};
if (siv_external_submit(p->slot, &frame) != SIV_OK) break;
```

A submitted frame's memory must not change until siv releases it, which it
reports by key once no frame on screen reads it. With a `release`
callback, releases arrive on the compositor thread, so a producer recycles
its buffers however busy your thread is; the callback must be quick and
may call only `siv_external_submit` and `siv_post`:

```c
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
```

Without a `release` callback, releases arrive as
`SIV_EXTERNAL_EVENT_TYPE_RELEASED` events on your thread instead.

A frame slot starts hidden. `SIV_EXTERNAL_EVENT_TYPE_SHOWN` says it can be
seen: a node shows some of it in a window that draws.
`SIV_EXTERNAL_EVENT_TYPE_HIDDEN` says it cannot: no node shows it, the
window is suspended (minimized, on a hidden workspace), or the display
server has stopped drawing the window (a lock screen, an output turned
off). Stop rendering and pause what only runs to be seen until it is shown
again.

To pace yourself to the display rather than a timer of your own, call
`siv_external_request_frame` and render when
`SIV_EXTERNAL_EVENT_TYPE_FRAME` arrives, then ask again: one event per
request, at the window's next frame, none while the compositor does not
draw the window.

Dma-buf frames (`SIV_EXTERNAL_MEMORY_DMABUF`) take a DRM format and
modifier and up to four planes; a frame shows once its implicit fences
signal, so neither siv nor the compositor waits on your GPU. Drivers that
set no implicit fences, such as NVIDIA's, pass a sync_file instead
(`SIV_EXTERNAL_FRAME_FENCE` and `fence`, from an exported Vulkan semaphore
or EGL fence), and the frame shows once it signals. The Wayland
compositor shows YUV and tiled buffers directly when it supports their
format, with explicit synchronization where it offers linux-drm-syncobj-v1,
so a frame is released only once the compositor's GPU is done reading
it; otherwise siv's Vulkan renderer imports them.

## Surface slots

A surface slot hands you siv's `wl_display` and a `wl_surface`
(`siv_external_get_wayland`) to render into yourself. The contract, which
`siv_external_create_surface`'s reference spells out:

- Render frames of the buffer size each `SIV_EXTERNAL_EVENT_TYPE_CONFIGURE`
  event gives (the node's size times the window's scale), and one soon
  after each configure even if nothing else changed.
- After committing a frame, call `siv_external_surface_committed` with its
  size, from any thread; the window's next commit shows it, and only then
  does the surface's frame callback fire, so a swap interval of 1 paces
  itself to siv's frames.
- Use the display only through an event queue of your own
  (`wl_display_create_queue`), as Mesa's EGL and Vulkan do, and never
  dispatch its default queue: siv's compositor thread owns it.
- Never set a viewport, buffer scale, or listener on the surface; siv
  positions, scales, and clips it.

The headless backend has no Wayland objects, so surface slots return NULL
pointers there; test with frame slots.

## Translucency and backgrounds

A frame or surface slot on a subsurface stays there when the node is
translucent (an opacity below 1, or a fade) as long as nothing is painted
over it: the compositor applies the opacity itself (alpha-modifier-v1).
Covered and translucent, a frame is composited instead, and a surface
slot is shown at full opacity below a hole.

An external view's `background` fills its content box behind the
content, such as the bars around letterboxed video. While the content is
on a subsurface, an opaque background is a solid-color subsurface of its
own where the compositor offers single-pixel buffers, so the window
paints nothing under the video and the compositor can show both without
blending a window-sized buffer.

## Protocols siv does not support

siv binds the Wayland protocols it uses itself. For one it does not, such
as content-type-v1, you can extend a window yourself on siv's connection
(D17): `siv_app_get_wayland` returns siv's `wl_display`, and
`siv_window_get_wayland` a window's `wl_surface` and `xdg_toplevel`.
[examples/wayland.c](examples/wayland.c) tells the compositor that its
window shows video:

```c
/* Extra double-buffered state on siv's surface, never a commit of our
 * own: siv's next commit of the window applies it. */
static const char *mark_as_video(struct player *p, siv_app app) {
	void *display = NULL, *surface = NULL;
	if (siv_app_get_wayland(app, &display) != SIV_OK || display == NULL) return "No Wayland compositor to tell";
	if (siv_window_get_wayland(p->window, &surface, NULL) != SIV_OK) return "No surface";
	bind_globals(p, display);
	if (p->manager == NULL) return "The compositor has no content types";
	p->content_type = wp_content_type_manager_v1_get_surface_content_type(p->manager, surface);
	wp_content_type_v1_set_content_type(p->content_type, WP_CONTENT_TYPE_V1_TYPE_VIDEO);
	if (siv_window_request_commit(p->window) != SIV_OK) return "No commit";
	return "Told the compositor: video";
}
```

siv's compositor thread reads the connection and dispatches its default
queue, so everything you bind goes on a queue of your own, which you
dispatch from any thread you like, as Mesa's EGL and Vulkan do:

```c
/* siv's compositor thread dispatches the connection's default queue, so
 * the registry goes on a queue of our own, through a proxy wrapper of the
 * display, and only that queue is round-tripped. */
static void bind_globals(struct player *p, struct wl_display *display) {
	p->queue = wl_display_create_queue(display);
	struct wl_display *wrapper = wl_proxy_create_wrapper(display);
	wl_proxy_set_queue((struct wl_proxy *)wrapper, p->queue);
	struct wl_registry *registry = wl_display_get_registry(wrapper);
	wl_proxy_wrapper_destroy(wrapper);
	wl_registry_add_listener(registry, &registry_listener, p);
	wl_display_roundtrip_queue(display, p->queue);
	wl_registry_destroy(registry);
}
```

The surface and toplevel are siv's, and the rules keep them so:

- Never commit the surface, attach or damage a buffer, or change its
  size, scale, regions, or role; never set a listener or user data on
  either object; and never make an `xdg_toplevel` request siv makes
  (title, app id, parent, size limits, states, move, resize).
- Only create extension objects of interfaces siv and Mesa's Vulkan
  driver do not use on the surface (`siv_window_get_wayland`'s reference
  lists those they do), and set their double-buffered state. siv's next
  commit of the window applies it; `siv_window_request_commit` asks for
  one now.
- Requests may come from any thread. Never dispatch, read, or round-trip
  the default queue, and never disconnect the display.
- The objects live as long as the window. Destroy yours first, including
  when a close request destroys it:

```c
static bool on_window_event(void *user_data, siv_window window, const siv_window_event *event) {
	(void)window;
	if (event->type == SIV_WINDOW_EVENT_TYPE_CLOSE_REQUESTED) unbind(user_data);
	return false;
}
```

The sample builds with the headers `wayland-scanner client-header`
generates from the protocol's XML and links libwayland-client. On the
headless backend both calls return NULL, and the sample says so:

![A small window reading No Wayland compositor to tell](images/wayland.png)
