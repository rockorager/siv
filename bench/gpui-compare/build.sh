#!/bin/sh
# Builds everything the comparison runs: libsiv (ReleaseFast) and the siv
# program, the measurement tools, the Qt and GTK programs against the
# system's Qt 6 and GTK 4, and, when cargo is installed, the gpui program
# (gpui/setup.sh fetches zed first).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
mkdir -p "$here/out"
(cd "$root" && ${ZIG:-zig} build -Doptimize=ReleaseFast)
${CC:-cc} -O2 -Wall -Wextra -o "$here/out/siv-bench" "$here/siv/bench.c" \
	-I"$root/zig-out/include" -L"$root/zig-out/lib" -lsiv -Wl,-rpath,"$root/zig-out/lib"
make -C "$here/harness" OUT="$here/out"
# Qt Quick and GTK 4 from the system (pkg-config), so that they load the
# same Mesa Vulkan driver as siv and gpui.
if pkg-config --exists Qt6Quick Qt6QuickControls2; then
	${CXX:-c++} -O2 -std=c++17 -fPIC -Wall -Wextra -o "$here/out/qt-bench" "$here/qt/bench.cpp" \
		$(pkg-config --cflags --libs Qt6Quick Qt6QuickControls2 Qt6Qml Qt6Gui)
	cp "$here/qt/bench.qml" "$here/out/qt-bench.qml"
else
	echo "Qt 6 Quick not found by pkg-config: skipping the Qt program" >&2
fi
if pkg-config --exists gtk4; then
	${CC:-cc} -O2 -Wall -Wextra -o "$here/out/gtk-bench" "$here/gtk/bench.c" $(pkg-config --cflags --libs gtk4)
else
	echo "GTK 4 not found by pkg-config: skipping the GTK program" >&2
fi
if command -v cargo >/dev/null 2>&1; then
	[ -d "$here/gpui/zed" ] || "$here/gpui/setup.sh"
	(cd "$here/gpui" && cargo build --release)
else
	echo "cargo not found: skipping the gpui program" >&2
fi
