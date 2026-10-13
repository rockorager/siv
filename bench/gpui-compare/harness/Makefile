# The measurement tools: presshim.so (presentation feedback for any client)
# and inject (virtual keyboard and pointer). Needs wayland-scanner,
# libwayland-client, and xkbcommon.
CC ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra
OUT ?= ../out
WP = $(shell pkg-config --variable=pkgdatadir wayland-protocols)

all: $(OUT)/presshim.so $(OUT)/inject

$(OUT)/gen:
	mkdir -p $@

$(OUT)/gen/%-client-protocol.h: protocols/%.xml | $(OUT)/gen
	wayland-scanner client-header $< $@
$(OUT)/gen/%-protocol.c: protocols/%.xml | $(OUT)/gen
	wayland-scanner private-code $< $@

$(OUT)/gen/presentation-time-client-protocol.h: $(WP)/stable/presentation-time/presentation-time.xml | $(OUT)/gen
	wayland-scanner client-header $< $@
$(OUT)/gen/presentation-time-protocol.c: $(WP)/stable/presentation-time/presentation-time.xml | $(OUT)/gen
	wayland-scanner private-code $< $@

$(OUT)/presshim.so: presshim.c $(OUT)/gen/presentation-time-client-protocol.h $(OUT)/gen/presentation-time-protocol.c
	$(CC) $(CFLAGS) -shared -fPIC -I$(OUT)/gen -o $@ presshim.c $(OUT)/gen/presentation-time-protocol.c -lwayland-client -ldl -lpthread

$(OUT)/inject: inject.c $(OUT)/gen/virtual-keyboard-unstable-v1-client-protocol.h $(OUT)/gen/virtual-keyboard-unstable-v1-protocol.c \
		$(OUT)/gen/wlr-virtual-pointer-unstable-v1-client-protocol.h $(OUT)/gen/wlr-virtual-pointer-unstable-v1-protocol.c
	$(CC) $(CFLAGS) -I$(OUT)/gen -o $@ inject.c $(OUT)/gen/virtual-keyboard-unstable-v1-protocol.c \
		$(OUT)/gen/wlr-virtual-pointer-unstable-v1-protocol.c -lwayland-client -lxkbcommon -lm

.PHONY: all
