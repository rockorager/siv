# Packaging

A desktop application needs more than a binary: an application id, a
desktop file, an icon, and, to start fast and stay single, D-Bus
activation. [examples/launch.c](examples/launch.c) is such an application,
and [examples/packaging](examples/packaging/) holds its files.

![A window reading Opened 1 file](images/launch.png)

## The application id

The application id is reverse DNS (`org.example.Notes`) and names
everything: the desktop file (`org.example.Notes.desktop`), the icon, the
D-Bus name, the Flatpak, and the app id the compositor matches windows
against. Give it to siv in `siv_app_desc.app_id`; windows default to it,
and portals use it to know who is asking.

## One instance, activated

`siv_app_launch` makes the application single-instance (D19). The first
launch owns the application id on the session bus and gets its own
activation, at the next dispatch; a later launch forwards its activation,
or the files it was given, to the first and `siv_app_run` returns at once. The
desktop activates the running instance the same way over
`org.freedesktop.Application`. Create windows in `on_activate`, not in
`main`, so a forwarded launch never shows one:

```c
/* Every activation comes here, at a safe point: this launch's, another
 * instance's, or the desktop's. Show the window, then hand the
 * activation token to the compositor so that the window may take focus. */
static void on_activate(void *user_data, siv_app app, const siv_activation *activation) {
	(void)app;
	struct notes *n = user_data;
	if (!n->window && create_window(n) != SIV_OK) return;
	if (activation->type == SIV_ACTIVATION_TYPE_OPEN) {
		char text[64];
		snprintf(text, sizeof text, "Opened %zu file%s", activation->uris_count, activation->uris_count == 1 ? "" : "s");
		show_status(n, text);
	}
	siv_result r = siv_window_activate(n->window, activation->activation_token, activation->activation_token_len);
	if (r != SIV_OK) fprintf(stderr, "launch: %s\n", siv_result_name(r));
}
```

```c
siv_result r = siv_app_create(SIV_DESC(siv_app_desc, .app_id = SIV_STR("org.example.Notes"), .name = SIV_STR("Notes")), &n.app);
if (r != SIV_OK) {
	fprintf(stderr, "launch: %s\n", siv_result_name(r));
	return 1;
}
r = siv_app_add_action(n.app, SIV_STR("new-note"), on_new_note, NULL, &n);
if (r == SIV_OK) r = siv_app_launch(n.app, SIV_DESC(siv_launch_desc, .uris = uris, .uris_count = count, .on_activate = on_activate, .user_data = &n, .flags = service ? SIV_LAUNCH_SERVICE : 0, .idle_timeout_ms = 10000));
/* A second instance forwards its activation and returns at once. */
if (r == SIV_OK) r = siv_app_run(n.app);
```

The activation token the launcher passes lets the window take focus; hand
it to `siv_window_activate`, as above. Without an application id or a
session bus, every launch is primary, which is also how the guide's tests
run the sample.

Application actions, registered with `siv_app_add_action`, are invoked by
notification buttons and by the desktop's actions on the desktop file:

```c
/* An application action: a notification button or a desktop file action
 * named new-note invokes it. */
static void on_new_note(void *user_data, const siv_action_event *event) {
	(void)event;
	struct notes *n = user_data;
	if (n->window) show_status(n, "New note");
}
```

## The desktop file

Install `org.example.Notes.desktop` in `share/applications`.
`DBusActivatable=true` tells launchers to activate the application over
D-Bus instead of running `Exec` (keep `Exec` for those that do not), and
`StartupNotify=true` tells them to pass an activation token. Desktop file
actions are invoked as application actions of the same name:

```ini
[Desktop Entry]
Type=Application
Name=Notes
Comment=Write things down
Icon=org.example.Notes
Exec=notes %U
DBusActivatable=true
StartupNotify=true
Categories=Utility;TextEditor;
MimeType=text/plain;
Actions=new-note;

[Desktop Action new-note]
Name=New Note
Exec=notes --new-note
```

## D-Bus activation

For D-Bus activation, install a service file as
`share/dbus-1/services/org.example.Notes.service`. The bus starts the
program with its `Exec` line, here with `--service`, which the program
turns into `SIV_LAUNCH_SERVICE`: then it waits for the desktop's call
instead of activating itself, and `idle_timeout_ms` ends it if no window
opens:

```ini
[D-BUS Service]
Name=org.example.Notes
Exec=/usr/bin/notes --service
```

Install the icon as `share/icons/hicolor/scalable/apps/org.example.Notes.svg`,
and an AppStream file (`share/metainfo/org.example.Notes.metainfo.xml`)
for software centers:

```xml
<component type="desktop-application">
  <id>org.example.Notes</id>
  <name>Notes</name>
  <summary>Write things down</summary>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <launchable type="desktop-id">org.example.Notes.desktop</launchable>
  <description>
    <p>A small note-taking application built with siv.</p>
  </description>
</component>
```

## Flatpak

siv needs nothing special in a sandbox: it reads settings and opens
dialogs through portals, opens local files by descriptor so the portal
accepts them, and runs on Wayland. The manifest gives the Wayland socket
and the GPU, and builds siv with Zig, which the Freedesktop SDK does not
ship:

```yaml
app-id: org.example.Notes
runtime: org.freedesktop.Platform
runtime-version: '24.08'
sdk: org.freedesktop.Sdk
command: notes
finish-args:
  # Wayland only; siv has no X11 backend.
  - --socket=wayland
  # The GPU, for siv's Vulkan renderer (it falls back to the CPU without it).
  - --device=dri
  # Owning the application id on the session bus, for single instance and
  # D-Bus activation, is allowed by default; portals need nothing either.
modules:
  - name: siv
    buildsystem: simple
    build-commands:
      # siv builds with Zig 0.17, which the SDK lacks: the zig source below
      # unpacks it into the build directory.
      - ./zig/zig build -Doptimize=ReleaseSafe --prefix /app
    sources:
      - type: git
        url: https://github.com/rockorager/siv.git
        tag: v0.1.0
      - type: archive
        dest: zig
        url: https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
        sha256: 1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
  - name: notes
    buildsystem: simple
    build-commands:
      - cc launch.c -o notes $(pkg-config --cflags --libs siv)
      - install -Dm755 notes /app/bin/notes
      - install -Dm644 packaging/org.example.Notes.desktop /app/share/applications/org.example.Notes.desktop
      - install -Dm644 packaging/org.example.Notes.service /app/share/dbus-1/services/org.example.Notes.service
      - install -Dm644 packaging/org.example.Notes.metainfo.xml /app/share/metainfo/org.example.Notes.metainfo.xml
      - install -Dm644 packaging/org.example.Notes.svg /app/share/icons/hicolor/scalable/apps/org.example.Notes.svg
    sources:
      # docs/guide/examples: launch.c and this directory.
      - type: dir
        path: ..
```

The guide's tests do not run flatpak-builder; treat the manifest as a
starting point, and pin siv's real source and checksum.

## Licences

siv is MIT, and so is everything it contains, or BSD or Apache-2.0
(D25). Ship `share/licenses/siv/NOTICES`, which the build generates for
the options you built with; it lists every library compiled into libsiv
and their licence texts. libsiv-lua has its own.
