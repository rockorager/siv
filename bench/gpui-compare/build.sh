#!/bin/sh
# Builds everything the comparison runs: libsiv (ReleaseFast) and the siv
# program, the measurement tools, and, when cargo is installed, the gpui
# program (gpui/setup.sh fetches zed first).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
mkdir -p "$here/out"
(cd "$root" && ${ZIG:-zig} build -Doptimize=ReleaseFast)
${CC:-cc} -O2 -Wall -Wextra -o "$here/out/siv-bench" "$here/siv/bench.c" \
	-I"$root/zig-out/include" -L"$root/zig-out/lib" -lsiv -Wl,-rpath,"$root/zig-out/lib"
make -C "$here/harness" OUT="$here/out"
if command -v cargo >/dev/null 2>&1; then
	[ -d "$here/gpui/zed" ] || "$here/gpui/setup.sh"
	(cd "$here/gpui" && cargo build --release)
else
	echo "cargo not found: skipping the gpui program" >&2
fi
