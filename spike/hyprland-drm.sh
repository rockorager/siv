#!/bin/sh
# Starts Hyprland on the panel (Aquamarine's DRM backend on /dev/dri/card1:
# eDP 1280x800 at 60 Hz, scale ${SCALE:-1}), with no gaps, borders,
# rounding, or animations, so a single window fills the screen as on sway,
# and prints the environment to source. (As root it needs Hyprland's
# --i-am-really-stupid; this is a test box.)
DIR=${DIR:-/tmp/swv-hypr}
mkdir -p -m 700 "$DIR"
cat > "$DIR/hyprland.conf" <<CONF
monitor = , 1280x800@60, 0x0, ${SCALE:-1}
general {
    gaps_in = 0
    gaps_out = 0
    border_size = 0
}
decoration {
    rounding = 0
    shadow {
        enabled = false
    }
    blur {
        enabled = false
    }
}
animations {
    enabled = false
}
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
ecosystem {
    no_update_news = true
    no_donation_nag = true
}
CONF
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$DIR" AQ_DRM_DEVICES=/dev/dri/card1 LIBSEAT_BACKEND=noop \
	setsid nice -n 5 Hyprland --i-am-really-stupid -c "$DIR/hyprland.conf" > "$DIR/hyprland.log" 2>&1 &
echo $! > "$DIR/hyprland.pid"
for i in $(seq 200); do
	[ -S "$DIR/wayland-1" ] && break
	sleep 0.05
done
echo "export XDG_RUNTIME_DIR=$DIR WAYLAND_DISPLAY=wayland-1"
