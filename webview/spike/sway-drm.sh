#!/bin/sh
# Starts sway 1.12 on the panel (DRM backend on /dev/dri/card1: eDP 1280x800
# at 60 Hz, Vulkan renderer, scale ${SCALE:-1}) in its own runtime dir, and
# prints the environment to source.  Stop it with: kill $(cat $DIR/sway.pid)
DIR=${DIR:-/tmp/swv-drm}
mkdir -p -m 700 "$DIR"
cat > "$DIR/config" <<EOF
output * mode 1280x800@60Hz position 0 0 scale ${SCALE:-1}
default_border none
default_floating_border none
focus_follows_mouse no
EOF
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$DIR" WLR_BACKENDS=drm WLR_DRM_DEVICES=/dev/dri/card1 LIBSEAT_BACKEND=noop WLR_RENDERER=${RENDERER:-vulkan} \
	WLR_LIBINPUT_NO_DEVICES=1 ${SWAY_EXTRA_ENV} WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 \
	setsid nice -n 5 sway ${SWAY_ARGS} -c "$DIR/config" > "$DIR/sway.log" 2>&1 &
echo $! > "$DIR/sway.pid"
for i in $(seq 200); do
	[ -S "$DIR/wayland-1" ] && ls "$DIR"/sway-ipc.*.sock >/dev/null 2>&1 && break
	sleep 0.05
done
echo "export XDG_RUNTIME_DIR=$DIR WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$DIR"/sway-ipc.*.sock)"
